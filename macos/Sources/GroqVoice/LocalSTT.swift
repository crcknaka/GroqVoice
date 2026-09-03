import FluidAudio
import Foundation

/// On-device speech recognition: NVIDIA Parakeet TDT 0.6B v3 running on the
/// Neural Engine through FluidAudio. 25 European languages (RU, EN, LV, UK, …),
/// punctuation and casing built in, roughly 100× real time on Apple Silicon.
///
/// The model (~500 MB, fetched once from Hugging Face) is loaded lazily on
/// first use and then kept warm: its resident footprint is small enough for a
/// menu-bar app to hold on to it, so every utterance after the first is
/// transcribed in a fraction of a second with no network at all.
final class LocalSTT {
    enum Stage {
        case downloadingModel(Double)  // 0...1
        case loadingModel              // CoreML compile + warm-up, indeterminate
        case transcribing
        case ready                     // model loaded and warm
        case failed(String)            // download/compile failed
    }

    static var modelsDir: URL { Config.supportDir.appendingPathComponent("models", isDirectory: true) }
    /// FluidAudio places the repo *next to* the directory you pass, under the
    /// repo's folder name — so hand it a path that already ends with that name
    /// and everything lands in ~/Library/Application Support/GroqVoice/models/.
    static var parakeetDir: URL { modelsDir.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml", isDirectory: true) }
    static let approximateDownloadMB = 500

    /// Called on the main thread.
    var onStage: ((Stage) -> Void)?

    private var manager: AsrManager?
    private var loadTask: Task<AsrManager, Error>?
    private var unloadTimer: Timer?
    private let unloadAfterSeconds: TimeInterval  // 0 = keep warm forever

    // Vocabulary boosting: a second, small CTC model (Parakeet CTC 110M, ~106 MB,
    // English token set) spots the user's terms acoustically and a rescorer
    // swaps the mangled words in the transcript for them. Built lazily from
    // vocabulary.txt and rebuilt when the file changes.
    private var boosting: VocabularyBoostingSession?
    private var boostingFileMtime: Date?
    private var boostingTask: Task<VocabularyBoostingSession?, Never>?
    private var boostingRetryAfter = Date.distantPast
    private(set) var boostingTermCount = 0

    static var ctcModelsDir: URL { CtcModels.defaultCacheDirectory(for: .ctc110m) }
    static let approximateCtcDownloadMB = 106
    var isCtcModelDownloaded: Bool { CtcModels.modelsExist(at: LocalSTT.ctcModelsDir) }
    var isBoostingReady: Bool { boosting != nil }

    init(unloadAfterMinutes: Double) {
        unloadAfterSeconds = unloadAfterMinutes <= 0 ? 0 : max(60, unloadAfterMinutes * 60)
    }

    var isModelDownloaded: Bool {
        AsrModels.modelsExist(at: LocalSTT.parakeetDir, version: .v3)
    }

    var isLoaded: Bool { manager != nil }
    var isBusyLoading: Bool { loadTask != nil }

    private func emit(_ stage: Stage) {
        DispatchQueue.main.async { [weak self] in self?.onStage?(stage) }
    }

    /// Downloads (if needed) and loads the model. Safe to call concurrently;
    /// parallel callers share one load.
    @discardableResult
    func ensureLoaded() async throws -> AsrManager {
        if let manager { return manager }
        if let loadTask { return try await loadTask.value }

        let task = Task<AsrManager, Error> { [weak self] in
            let started = Date()
            let dir = LocalSTT.parakeetDir
            try FileManager.default.createDirectory(at: LocalSTT.modelsDir, withIntermediateDirectories: true)

            let wasDownloaded = AsrModels.modelsExist(at: dir, version: .v3)
            if !wasDownloaded {
                Log.write("local STT: downloading Parakeet v3 (~\(LocalSTT.approximateDownloadMB) MB)…")
                self?.emit(.downloadingModel(0))
            } else {
                self?.emit(.loadingModel)
            }

            let models = try await AsrModels.downloadAndLoad(to: dir, version: .v3) { [weak self] progress in
                // Download phases carry a real fraction; compilation has no
                // fine-grained progress, so that becomes the indeterminate spinner.
                switch progress.phase {
                case .listing, .downloading:
                    if progress.fractionCompleted.isFinite {
                        self?.emit(.downloadingModel(min(progress.fractionCompleted, 0.99)))
                    }
                case .compiling:
                    self?.emit(.loadingModel)
                }
            }
            if !wasDownloaded {
                Log.write(String(format: "local STT: model downloaded in %.0fs", Date().timeIntervalSince(started)))
            }
            self?.emit(.loadingModel)

            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            Log.write(String(format: "local STT: Parakeet v3 ready in %.1fs", Date().timeIntervalSince(started)))
            return manager
        }
        loadTask = task
        defer { loadTask = nil }

        do {
            let manager = try await task.value
            self.manager = manager
            emit(.ready)
            return manager
        } catch {
            Log.write("local STT: model load failed: \(error.localizedDescription)")
            emit(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Kicks off download + load without waiting for it (first run, or the
    /// first dictation served by the cloud while the model arrives). Also
    /// prepares vocabulary boosting so the first take pays no extra latency.
    func warmUpInBackground(vocabularyFile: URL? = nil) {
        guard manager == nil || (vocabularyFile != nil && boosting == nil) else { return }
        Task { [weak self] in
            guard let self else { return }
            guard (try? await self.ensureLoaded()) != nil else { return }
            if let vocabularyFile { _ = await self.boostingSession(for: vocabularyFile) }
        }
    }

    /// `pcm16` is raw 16 kHz mono little-endian Int16 — exactly what Recorder
    /// produces. When `vocabularyFile` has terms, the transcript is rescored
    /// against them.
    func transcribe(pcm16: Data, language: String, vocabularyFile: URL? = nil) async throws -> String {
        let manager = try await ensureLoaded()
        emit(.transcribing)

        let samples = LocalSTT.floats(from: pcm16)
        // A language hint only filters tokens by *script* (Latin vs Cyrillic),
        // so leave it off for mixed RU/EN speech — that's what "Auto-detect" means here.
        let hint = language.isEmpty ? nil : Language(rawValue: language)
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let started = Date()
        let result = try await manager.transcribe(samples, decoderState: &state, language: hint)
        Log.write(String(format: "local STT: %.2fs of audio in %.2fs (confidence %.2f)",
                         Double(samples.count) / Recorder.sampleRate,
                         Date().timeIntervalSince(started), result.confidence))

        var text = result.text
        if let vocabularyFile,
           let session = await boostingSession(for: vocabularyFile),
           let timings = result.tokenTimings, !timings.isEmpty {
            let t0 = Date()
            if let out = await session.rescore(text: result.text, tokenTimings: timings, audioSamples: samples),
               out.wasModified {
                let applied = out.replacements.filter(\.shouldReplace)
                    .map { "\($0.originalWord) → \($0.replacementWord ?? "?")" }
                Log.write(String(format: "vocabulary: %@ (%.2fs)", applied.joined(separator: ", "), Date().timeIntervalSince(t0)))
                text = out.text
            } else {
                Log.write(String(format: "vocabulary: no replacements (%.2fs)", Date().timeIntervalSince(t0)))
            }
        }

        scheduleUnload()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Boosting session for the current vocabulary file: cached by mtime,
    /// nil when the file has no usable terms. The CTC model is downloaded on
    /// first use only if there are terms to look for.
    private func boostingSession(for file: URL) async -> VocabularyBoostingSession? {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? nil
        if mtime == boostingFileMtime, Date() >= boostingRetryAfter || boosting != nil {
            return boosting
        }
        if let boostingTask { return await boostingTask.value }

        let task = Task<VocabularyBoostingSession?, Never> { [weak self] in
            do {
                let plain = try CustomVocabularyContext.loadFromSimpleFormat(from: file)
                guard !plain.terms.isEmpty else {
                    Log.write("vocabulary: no terms — boosting off")
                    return nil
                }
                if !(self?.isCtcModelDownloaded ?? true) {
                    Log.write("vocabulary: downloading Parakeet CTC 110M (~\(LocalSTT.approximateCtcDownloadMB) MB) for term spotting…")
                }
                self?.emit(.loadingModel)
                let started = Date()
                let (vocab, models) = try await CustomVocabularyContext.loadWithCtcTokens(from: file.path)
                // The CTC helper is an English model. Its acoustic-only "rescue"
                // pass fires on random Russian words, so only allow replacements
                // that also look like the term (or one of its aliases) in text.
                let session = try await VocabularyBoostingSession(
                    vocabulary: vocab, ctcModels: models,
                    config: VocabularyRescorer.Config(spotterRescueEnabled: false))
                Log.write(String(format: "vocabulary: boosting ready — %d terms in %.1fs", vocab.terms.count, Date().timeIntervalSince(started)))
                return session
            } catch {
                Log.write("vocabulary: boosting unavailable — \(error.localizedDescription)")
                return nil
            }
        }
        boostingTask = task
        let session = await task.value
        boostingTask = nil
        boosting = session
        boostingFileMtime = mtime
        boostingTermCount = session?.vocabulary.terms.count ?? 0
        boostingRetryAfter = session == nil ? Date().addingTimeInterval(300) : .distantPast
        emit(.ready)
        return session
    }

    private static func floats(from pcm16: Data) -> [Float] {
        let count = pcm16.count / 2
        var out = [Float](repeating: 0, count: count)
        pcm16.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<count { out[i] = Float(Int16(littleEndian: src[i])) / 32768.0 }
        }
        return out
    }

    private func scheduleUnload() {
        guard unloadAfterSeconds > 0 else { return }
        DispatchQueue.main.async { [self] in
            unloadTimer?.invalidate()
            unloadTimer = Timer.scheduledTimer(withTimeInterval: unloadAfterSeconds, repeats: false) { [weak self] _ in
                guard let self, let manager = self.manager else { return }
                Task { await manager.cleanup() }
                self.manager = nil
                Log.write("local STT: model unloaded after \(Int(self.unloadAfterSeconds / 60)) min idle")
            }
        }
    }
}
