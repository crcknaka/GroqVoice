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

    // `manager` and `loadTask` are reached from the main thread and from
    // whichever task is transcribing — always under `lock`.
    private let lock = NSLock()
    private var manager: AsrManager?
    private var loadTask: Task<AsrManager, Error>?
    private var unloadTimer: Timer?
    private var unloadAfterSeconds: TimeInterval  // 0 = keep warm forever

    init(unloadAfterMinutes: Double) {
        unloadAfterSeconds = unloadAfterMinutes <= 0 ? 0 : max(60, unloadAfterMinutes * 60)
    }

    /// Applies a new idle-unload setting; 0 keeps the model warm (and cancels a pending unload).
    func setUnloadAfterMinutes(_ minutes: Double) {
        unloadAfterSeconds = minutes <= 0 ? 0 : max(60, minutes * 60)
        if unloadAfterSeconds == 0 {
            unloadTimer?.invalidate()
            unloadTimer = nil
        }
    }

    var isModelDownloaded: Bool {
        AsrModels.modelsExist(at: LocalSTT.parakeetDir, version: .v3)
    }

    var isLoaded: Bool { lock.withLock { manager != nil } }

    private func emit(_ stage: Stage) {
        DispatchQueue.main.async { [weak self] in self?.onStage?(stage) }
    }

    /// Downloads (if needed) and loads the model. Safe to call concurrently;
    /// parallel callers share one load.
    @discardableResult
    func ensureLoaded() async throws -> AsrManager {
        let task: Task<AsrManager, Error> = lock.withLock {
            if let manager { return Task { manager } }
            if let loadTask { return loadTask }
            let task = Task<AsrManager, Error> { [weak self] in
                do {
                    let manager = try await LocalSTT.load { self?.emit($0) }
                    self?.lock.withLock {
                        self?.manager = manager
                        self?.loadTask = nil
                    }
                    self?.emit(.ready)
                    return manager
                } catch {
                    self?.lock.withLock { self?.loadTask = nil }
                    Log.write("local STT: model load failed: \(error.localizedDescription)")
                    self?.emit(.failed(error.localizedDescription))
                    throw error
                }
            }
            loadTask = task
            return task
        }
        return try await task.value
    }

    private static func load(emit: @escaping (Stage) -> Void) async throws -> AsrManager {
        let started = Date()
        let dir = LocalSTT.parakeetDir
        try FileManager.default.createDirectory(at: LocalSTT.modelsDir, withIntermediateDirectories: true)

        let wasDownloaded = AsrModels.modelsExist(at: dir, version: .v3)
        if !wasDownloaded {
            Log.write("local STT: downloading Parakeet v3 (~\(LocalSTT.approximateDownloadMB) MB)…")
            emit(.downloadingModel(0))
        } else {
            emit(.loadingModel)
        }

        let models = try await AsrModels.downloadAndLoad(to: dir, version: .v3) { progress in
            // Download phases carry a real fraction; compilation has no
            // fine-grained progress, so that becomes the indeterminate spinner.
            switch progress.phase {
            case .listing, .downloading:
                if progress.fractionCompleted.isFinite {
                    emit(.downloadingModel(min(progress.fractionCompleted, 0.99)))
                }
            case .compiling:
                emit(.loadingModel)
            }
        }
        if !wasDownloaded {
            Log.write(String(format: "local STT: model downloaded in %.0fs", Date().timeIntervalSince(started)))
        }
        emit(.loadingModel)

        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        Log.write(String(format: "local STT: Parakeet v3 ready in %.1fs", Date().timeIntervalSince(started)))
        return manager
    }

    /// Kicks off download + load without waiting for it (launch, first run, or
    /// the first dictation served by the cloud while the model arrives).
    func warmUpInBackground() {
        guard !isLoaded else { return }
        Task { [weak self] in _ = try? await self?.ensureLoaded() }
    }

    /// `pcm16` is raw 16 kHz mono little-endian Int16 — exactly what Recorder produces.
    func transcribe(pcm16: Data, language: String) async throws -> String {
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

        scheduleUnload()
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        DispatchQueue.main.async { [self] in
            guard unloadAfterSeconds > 0 else { return }
            unloadTimer?.invalidate()
            unloadTimer = Timer.scheduledTimer(withTimeInterval: unloadAfterSeconds, repeats: false) { [weak self] _ in
                guard let self, let manager = self.lock.withLock({ () -> AsrManager? in
                    defer { self.manager = nil }
                    return self.manager
                }) else { return }
                Task { await manager.cleanup() }
                Log.write("local STT: model unloaded after \(Int(self.unloadAfterSeconds / 60)) min idle")
            }
        }
    }
}
