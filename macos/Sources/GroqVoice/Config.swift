import Foundation

/// What an extra push-to-talk key does with what you say — or, when text was
/// selected as the key went down, with that text.
struct KeyAction: Codable, Equatable {
    enum Kind: String, Codable { case translate, prompt }

    var key: HotkeyKey
    var kind: Kind
    var language = "en"      // translate: target language code
    var prompt = ""          // prompt: the instruction applied to the text

    var isTranslate: Bool { kind == .translate }
    var languageName: String { Config.translateLanguages.first { $0.code == language }?.name ?? language }

    /// Short description for menus and logs.
    var summary: String {
        if isTranslate { return "translate into \(languageName)" }
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return "custom prompt (not set)" }
        return p.count > 48 ? String(p.prefix(45)) + "…" : p
    }
}

extension KeyAction {
    // `language` / `prompt` may be missing in a hand-written entry.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(HotkeyKey.self, forKey: .key)
        kind = try c.decode(Kind.self, forKey: .kind)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
    }
}

enum STTEngine: String, Codable {
    case parakeet   // on-device Parakeet TDT v3 (default)
    case groq       // Whisper via the Groq API
}

/// Everything in config.json. Codable is synthesized: a new setting is one
/// property with its default — `decode(from:)` fills in whatever a file lacks.
struct Config: Codable {
    var groqApiKey = ""
    /// Priority order: strongest first. On a rate limit the next model is used;
    /// the stronger one is retried automatically once its cooldown expires.
    var transcriptionModels = ["whisper-large-v3", "whisper-large-v3-turbo"]
    /// Checked against the live Groq API on 2026-09-03 (Llama 3.x is gone).
    /// Qwen 3.8 27B goes first: on a one-sentence translation it answered in
    /// 0.2 s using 130 tokens, where the gpt-oss models spend 0.5 s and
    /// 300–400 tokens on hidden reasoning — and the free tier meters tokens
    /// per minute. The stronger gpt-oss-120b stays as the fallback.
    var chatModels = ["qwen/qwen3.8-27b", "openai/gpt-oss-120b", "openai/gpt-oss-20b"]
    /// Where chat completions go (task mode, clean-up, translation). Any
    /// OpenAI-compatible server works: Groq (default), Ollama on this Mac
    /// (http://localhost:11434/v1), LM Studio, OpenAI, OpenRouter, …
    var chatBaseURL = Config.groqBaseURL
    /// Key for `chatBaseURL`; empty = reuse `groqApiKey` (Ollama needs none).
    var chatApiKey = ""
    /// ISO code ("ru", "en", "lv") or "" for auto-detect. For the on-device
    /// engine a fixed language only filters tokens by script, so leave it on
    /// auto for mixed Russian/English speech.
    var language = ""
    var taskKeywords = ["task", "задача", "задание"]
    var taskKeywordMaxWordPosition = 3
    /// Takes shorter than this are dropped as accidental. Measured on captured
    /// audio, so keep it well under a one-word utterance (~0.5 s).
    var minRecordingSeconds = 0.3
    /// A take that runs this long is stopped and processed — a locked
    /// recording that was forgotten must not hold the microphone for hours.
    var maxRecordingMinutes = 10.0
    var silencePeakPercent = 1.0
    var saveLastWav = true
    var playFeedbackSounds = true
    var taskSystemPrompt = ""
    var pttHoldMs = 250.0
    var doubleTapWindowMs = 400.0
    /// Keep recording this long after the key is released so the last syllable
    /// isn't clipped when the key comes up mid-word. Every millisecond here is
    /// felt as latency, so keep it just above the audio pipeline's buffer.
    var releaseTailMs = 150.0
    /// Login item. Off by default — enable in Settings.
    var autostart = false

    var sttEngine = STTEngine.parakeet
    /// If the chosen engine can't serve a take (model still downloading, no
    /// network, API error), try the other one instead of failing.
    var sttFallback = true
    /// Minutes of idle before the local model is unloaded; 0 = keep it warm.
    var localUnloadAfterMinutes = 0.0

    /// Push-to-talk key.
    var hotkey = HotkeyKey.fn
    /// Extra push-to-talk keys, each with its own action (translate into a
    /// language, or a custom prompt). Needs an LLM backend.
    var keyActions: [KeyAction] = []
    /// CoreAudio device UID; "" = system default input.
    var inputDeviceUID = ""
    /// Run the transcript through the LLM to fix punctuation and drop filler
    /// words (wording is kept). Needs Groq or Apple Intelligence.
    var cleanupTranscript = false
    var pasteMode = PasteMode.paste
    /// Look at the text around the caret (Accessibility) and add a space /
    /// fix the first letter's case when inserting mid-sentence.
    var smartSpacing = true
    /// "новая строка" / "абзац" / "new line" become line breaks.
    var spokenFormatting = true
    /// With text selected when the key goes down, what you say is treated as
    /// an instruction about it (or as its replacement). Needs an LLM.
    var editSelection = true
    /// Record from the built-in microphone when the system default is a
    /// Bluetooth headset (AirPods) — better audio, and the headset keeps
    /// its high-quality output profile.
    var preferBuiltInMic = true
    var restoreClipboard = true
    var historySize = 50

    static let groqBaseURL = "https://api.groq.com/openai/v1"

    var usesGroqForChat: Bool {
        let base = chatBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        return base.isEmpty || base == Config.groqBaseURL
    }
    var effectiveChatApiKey: String { chatApiKey.isEmpty ? groqApiKey : chatApiKey }
    var chatHost: String { URL(string: chatBaseURL)?.host ?? "api.groq.com" }
    var chatPort: UInt16 {
        let url = URL(string: chatBaseURL)
        if let port = url?.port { return UInt16(port) }
        return url?.scheme?.lowercased() == "http" ? 80 : 443
    }
    /// True when some chat backend is configured: a Groq key, or a custom
    /// endpoint (which may need no key at all).
    var llmConfigured: Bool { !usesGroqForChat || !groqApiKey.isEmpty }

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("GroqVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The folder holds the API key, the log and the history of everything
    /// dictated: owner-only. Closing the folder covers every file in it.
    static func protectSupportDir() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDir.path)
    }

    static var fileURL: URL { supportDir.appendingPathComponent("config.json") }

    var usesLocalEngine: Bool { sttEngine == .parakeet }

    /// The action bound to `key`, unless it is the main dictation key.
    func action(for key: HotkeyKey) -> KeyAction? {
        guard key != hotkey else { return nil }
        return keyActions.first { $0.key == key }
    }

    /// Actions on keys other than the main one.
    var activeKeyActions: [KeyAction] { keyActions.filter { $0.key != hotkey } }

    /// Replaces (or with nil removes) the action for a key.
    mutating func setAction(_ action: KeyAction?, for key: HotkeyKey) {
        keyActions.removeAll { $0.key == key }
        if var action { action.key = key; keyActions.append(action) }
    }

    static let translateLanguages: [(code: String, name: String)] = [
        ("en", "English"), ("lv", "Latvian"), ("ru", "Russian"), ("uk", "Ukrainian"),
        ("de", "German"), ("es", "Spanish"), ("fr", "French"), ("it", "Italian"), ("pl", "Polish"),
        ("et", "Estonian"), ("lt", "Lithuanian"), ("pt", "Portuguese"), ("nl", "Dutch"),
        ("sv", "Swedish"), ("tr", "Turkish"), ("zh", "Chinese"), ("ja", "Japanese"),
    ]
    static let recognitionLanguages: [(code: String, name: String)] = [
        ("", "Auto-detect"), ("ru", "Русский"), ("en", "English"), ("lv", "Latviešu"), ("uk", "Українська"),
        ("de", "Deutsch"), ("es", "Español"), ("fr", "Français"), ("it", "Italiano"), ("pl", "Polski"),
    ]

    // MARK: - Loading and saving

    /// Reads a config laid over the defaults, so a file written by an older
    /// version (or by hand) may lack keys. A value that doesn't fit — a typo in
    /// a hand edit — costs only that key, never the rest of the settings.
    static func decode(from data: Data) -> Config? {
        func object(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
        func config(_ dict: [String: Any]) -> Config? {
            (try? JSONSerialization.data(withJSONObject: dict)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
        }
        guard let file = object(data), let defaults = (try? JSONEncoder().encode(Config())).flatMap(object) else { return nil }

        let known = file.filter { defaults[$0.key] != nil }
        if let cfg = config(defaults.merging(known) { _, new in new }) { return cfg }

        var merged = defaults
        for (key, value) in known {
            var candidate = merged
            candidate[key] = value
            if config(candidate) != nil { merged = candidate } else { Log.write("config: ignoring the invalid value of \(key)") }
        }
        return config(merged)
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL) else {
            let cfg = Config()
            cfg.save()
            return cfg
        }
        guard let cfg = decode(from: data) else {
            // Not JSON at all: start from the defaults, but keep the file for its owner.
            let aside = supportDir.appendingPathComponent("config.broken.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            Log.write("config.json is unreadable — moved to config.broken.json, starting from defaults")
            let cfg = Config()
            cfg.save()
            return cfg
        }
        cfg.save()  // rewrite with the current set of keys
        return cfg
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: Config.fileURL, options: .atomic)
        }
    }
}
