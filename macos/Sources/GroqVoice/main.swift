import Cocoa

// Headless maintenance modes — handy for debugging without the menu bar UI.
//
//   GroqVoice --download-model          fetch + compile Parakeet v3; transcribe last.wav if present
if CommandLine.arguments.contains("--download-model") {
    let cfg = Config.load()
    let stt = LocalSTT(unloadAfterMinutes: 0)
    stt.onStage = { stage in
        switch stage {
        case .downloadingModel(let f): print(String(format: "\rdownloading %3d%%", Int(f * 100)), terminator: "")
        case .loadingModel: print("\ncompiling model…")
        case .transcribing: print("transcribing…")
        case .ready: print("model ready")
        case .failed(let m): print("FAILED: \(m)")
        }
        fflush(stdout)
    }
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            try await stt.ensureLoaded()
            if let wav = try? Data(contentsOf: Recorder.wavURL) {
                // Strip the 44-byte header our Recorder writes.
                let text = try await stt.transcribe(pcm16: wav.dropFirst(44), language: cfg.language)
                print("transcript of last.wav: \"\(text)\"")
            }
        } catch {
            print("FAILED: \(error.localizedDescription)")
        }
        sem.signal()
    }
    // Keep the main run loop alive for the stage callbacks while we wait.
    while sem.wait(timeout: .now()) == .timedOut {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    exit(0)
}

// GroqVoice --transcribe <file.wav> [--vocab <terms.txt>] [--boost]
//   transcribe a 16 kHz mono 16-bit WAV with the on-device engine; --vocab applies
//   the alias replacement from that file, --boost additionally runs the acoustic
//   CTC term spotter (downloads the helper model on first use)
if let flag = CommandLine.arguments.firstIndex(of: "--transcribe"), CommandLine.arguments.count > flag + 1 {
    let path = CommandLine.arguments[flag + 1]
    var vocabFile: URL?
    if let v = CommandLine.arguments.firstIndex(of: "--vocab"), CommandLine.arguments.count > v + 1 {
        vocabFile = URL(fileURLWithPath: CommandLine.arguments[v + 1])
    }
    let cfg = Config.load()
    let stt = LocalSTT(unloadAfterMinutes: 0)
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let wav = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let range = Recorder.dataChunkRange(in: wav) else { throw AppError("not a WAV file") }
            let t0 = Date()
            let boost = CommandLine.arguments.contains("--boost")
            let text = try await stt.transcribe(pcm16: wav.subdata(in: range), language: cfg.language, vocabularyFile: boost ? vocabFile : nil)
            print(String(format: "[%.2fs incl. model load] %@", Date().timeIntervalSince(t0), text))
            if let vocabFile {
                let aliased = Vocabulary(fileURL: vocabFile).applyAliases(to: text)
                print("with aliases: \(aliased.text)" + (aliased.changes.isEmpty ? "" : "   (\(aliased.changes.joined(separator: ", ")))"))
            }
        } catch {
            print("FAILED: \(error.localizedDescription)")
        }
        sem.signal()
    }
    while sem.wait(timeout: .now()) == .timedOut {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    exit(0)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
