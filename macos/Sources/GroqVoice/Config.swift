import Foundation

/// What an extra push-to-talk key does with what you say — or, when text was
/// selected as the key went down, with that text.
struct KeyAction: Codable, Equatable {
    var key: String          // HotkeyKey raw value
    var kind: String         // "translate" | "prompt"
    var language = "en"      // translate: target language code
    var prompt = ""          // prompt: the instruction applied to the text

    var hotkeyKey: HotkeyKey? { HotkeyKey(rawValue: key) }
    var isTranslate: Bool { kind == "translate" }
    var languageName: String { Config.translateLanguages.first { $0.code == language }?.name ?? language }

    /// Short description for menus and logs.
    var summary: String {
        if isTranslate { return "translate into \(languageName)" }
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return "custom prompt (not set)" }
        return p.count > 48 ? String(p.prefix(45)) + "…" : p
    }
}

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
    /// Earlier defaults, swapped for the current one on load.
    static let legacyChatModelLists = [
        ["llama-3.3-70b-versatile", "openai/gpt-oss-120b", "llama-3.1-8b-instant"],
        ["openai/gpt-oss-120b", "qwen/qwen3.8-27b", "openai/gpt-oss-20b"],
    ]
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
    /// Login item. Off by default — enable from the menu.
    var autostart = false

    /// "parakeet" — on-device Parakeet TDT v3 (default); "groq" — Whisper via the Groq API.
    var sttEngine = "parakeet"
    /// If the chosen engine can't serve a take (model still downloading, no
    /// network, API error), try the other one instead of failing.
    var sttFallback = true
    /// Minutes of idle before the local model is unloaded; 0 = keep it warm.
    var localUnloadAfterMinutes = 0.0
    /// Experimental: spot vocabulary terms acoustically with a second (English)
    /// CTC model and rescore the transcript. Off by default — with large
    /// vocabularies and Russian speech it produces false replacements; the
    /// deterministic alias replacement is always on regardless.
    var vocabularyBoosting = false

    /// Push-to-talk key: fn | rightCommand | rightOption | rightControl | leftControl.
    var hotkey = "fn"
    /// Extra push-to-talk keys, each with its own action (translate into a
    /// language, or a custom prompt). Needs an LLM backend.
    var keyActions: [KeyAction] = []
    /// CoreAudio device UID; "" = system default input.
    var inputDeviceUID = ""
    /// Run the transcript through the LLM to fix punctuation and drop filler
    /// words (wording is kept). Needs Groq or Apple Intelligence.
    var cleanupTranscript = false
    /// "paste" — clipboard + ⌘V; "type" — synthesized keystrokes.
    var pasteMode = "paste"
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

    var usesGroqForChat: Bool { chatBaseURL.trimmingCharacters(in: .whitespaces).isEmpty || chatBaseURL == Config.groqBaseURL }
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

    static var fileURL: URL { supportDir.appendingPathComponent("config.json") }

    var hotkeyKey: HotkeyKey { HotkeyKey(rawValue: hotkey) ?? .fn }

    /// The action bound to `key`, unless it is the main dictation key.
    func action(for key: HotkeyKey) -> KeyAction? {
        guard key != hotkeyKey else { return nil }
        return keyActions.first { $0.key == key.rawValue }
    }

    /// Actions with a valid key that isn't the main one.
    var activeKeyActions: [KeyAction] {
        keyActions.filter { $0.hotkeyKey != nil && $0.hotkeyKey != hotkeyKey }
    }

    /// Replaces (or with nil removes) the action for a key.
    mutating func setAction(_ action: KeyAction?, for key: HotkeyKey) {
        keyActions.removeAll { $0.key == key.rawValue }
        if var action { action.key = key.rawValue; keyActions.append(action) }
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
    var pasteModeValue: PasteMode { PasteMode(rawValue: pasteMode) ?? .paste }
    var usesLocalEngine: Bool { sttEngine != "groq" }

    enum CodingKeys: String, CodingKey {
        case groqApiKey, transcriptionModels, chatModels, chatBaseURL, chatApiKey, language
        case taskKeywords, taskKeywordMaxWordPosition
        case minRecordingSeconds, silencePeakPercent
        case saveLastWav, playFeedbackSounds, taskSystemPrompt
        case pttHoldMs, doubleTapWindowMs, releaseTailMs, autostart
        case sttEngine, sttFallback, localUnloadAfterMinutes, vocabularyBoosting
        case hotkey, keyActions, inputDeviceUID, cleanupTranscript
        case pasteMode, restoreClipboard, historySize, smartSpacing, spokenFormatting, preferBuiltInMic, editSelection
        // Legacy keys, migrated on load.
        case transcriptionModel, chatModel, localMode, translateHotkey, translateLanguage
    }

    init() {}

    // Tolerate missing keys in an existing config.json so upgrades don't reset settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }

        groqApiKey = get(.groqApiKey, d.groqApiKey)
        if let list = try c.decodeIfPresent([String].self, forKey: .transcriptionModels) {
            transcriptionModels = list
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .transcriptionModel) {
            transcriptionModels = [legacy] + d.transcriptionModels.filter { $0 != legacy }
        }
        if let list = try c.decodeIfPresent([String].self, forKey: .chatModels) {
            chatModels = list
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .chatModel) {
            chatModels = [legacy] + d.chatModels.filter { $0 != legacy }
        }

        chatBaseURL = get(.chatBaseURL, d.chatBaseURL)
        chatApiKey = get(.chatApiKey, d.chatApiKey)
        language = get(.language, d.language)
        taskKeywords = get(.taskKeywords, d.taskKeywords)
        taskKeywordMaxWordPosition = get(.taskKeywordMaxWordPosition, d.taskKeywordMaxWordPosition)
        minRecordingSeconds = get(.minRecordingSeconds, d.minRecordingSeconds)
        silencePeakPercent = get(.silencePeakPercent, d.silencePeakPercent)
        saveLastWav = get(.saveLastWav, d.saveLastWav)
        playFeedbackSounds = get(.playFeedbackSounds, d.playFeedbackSounds)
        taskSystemPrompt = get(.taskSystemPrompt, d.taskSystemPrompt)
        pttHoldMs = get(.pttHoldMs, d.pttHoldMs)
        doubleTapWindowMs = get(.doubleTapWindowMs, d.doubleTapWindowMs)
        releaseTailMs = get(.releaseTailMs, d.releaseTailMs)
        autostart = get(.autostart, d.autostart)

        if let engine = try c.decodeIfPresent(String.self, forKey: .sttEngine) {
            sttEngine = engine
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .localMode) {
            // Old WhisperKit-era setting: "off" meant cloud only.
            sttEngine = legacy == "off" ? "groq" : "parakeet"
        }
        sttFallback = get(.sttFallback, d.sttFallback)
        localUnloadAfterMinutes = get(.localUnloadAfterMinutes, d.localUnloadAfterMinutes)
        vocabularyBoosting = get(.vocabularyBoosting, d.vocabularyBoosting)

        hotkey = get(.hotkey, d.hotkey)
        keyActions = get(.keyActions, d.keyActions)
        if keyActions.isEmpty, let legacyKey = try c.decodeIfPresent(String.self, forKey: .translateHotkey), !legacyKey.isEmpty {
            // The single "translate key" became one of several key actions.
            keyActions = [KeyAction(key: legacyKey, kind: "translate",
                                    language: get(.translateLanguage, "en"))]
        }
        inputDeviceUID = get(.inputDeviceUID, d.inputDeviceUID)
        cleanupTranscript = get(.cleanupTranscript, d.cleanupTranscript)
        pasteMode = get(.pasteMode, d.pasteMode)
        restoreClipboard = get(.restoreClipboard, d.restoreClipboard)
        historySize = get(.historySize, d.historySize)
        smartSpacing = get(.smartSpacing, d.smartSpacing)
        spokenFormatting = get(.spokenFormatting, d.spokenFormatting)
        preferBuiltInMic = get(.preferBuiltInMic, d.preferBuiltInMic)
        editSelection = get(.editSelection, d.editSelection)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(groqApiKey, forKey: .groqApiKey)
        try c.encode(transcriptionModels, forKey: .transcriptionModels)
        try c.encode(chatModels, forKey: .chatModels)
        try c.encode(chatBaseURL, forKey: .chatBaseURL)
        try c.encode(chatApiKey, forKey: .chatApiKey)
        try c.encode(language, forKey: .language)
        try c.encode(taskKeywords, forKey: .taskKeywords)
        try c.encode(taskKeywordMaxWordPosition, forKey: .taskKeywordMaxWordPosition)
        try c.encode(minRecordingSeconds, forKey: .minRecordingSeconds)
        try c.encode(silencePeakPercent, forKey: .silencePeakPercent)
        try c.encode(saveLastWav, forKey: .saveLastWav)
        try c.encode(playFeedbackSounds, forKey: .playFeedbackSounds)
        try c.encode(taskSystemPrompt, forKey: .taskSystemPrompt)
        try c.encode(pttHoldMs, forKey: .pttHoldMs)
        try c.encode(doubleTapWindowMs, forKey: .doubleTapWindowMs)
        try c.encode(releaseTailMs, forKey: .releaseTailMs)
        try c.encode(autostart, forKey: .autostart)
        try c.encode(sttEngine, forKey: .sttEngine)
        try c.encode(sttFallback, forKey: .sttFallback)
        try c.encode(localUnloadAfterMinutes, forKey: .localUnloadAfterMinutes)
        try c.encode(vocabularyBoosting, forKey: .vocabularyBoosting)
        try c.encode(hotkey, forKey: .hotkey)
        try c.encode(keyActions, forKey: .keyActions)
        try c.encode(inputDeviceUID, forKey: .inputDeviceUID)
        try c.encode(cleanupTranscript, forKey: .cleanupTranscript)
        try c.encode(pasteMode, forKey: .pasteMode)
        try c.encode(restoreClipboard, forKey: .restoreClipboard)
        try c.encode(historySize, forKey: .historySize)
        try c.encode(smartSpacing, forKey: .smartSpacing)
        try c.encode(spokenFormatting, forKey: .spokenFormatting)
        try c.encode(preferBuiltInMic, forKey: .preferBuiltInMic)
        try c.encode(editSelection, forKey: .editSelection)
    }

    static func load() -> Config {
        if let data = try? Data(contentsOf: fileURL),
           var cfg = try? JSONDecoder().decode(Config.self, from: data) {
            // The old 1.0 s minimum silently swallowed one-word takes ("привет" ≈ 0.5 s).
            if cfg.minRecordingSeconds == 1.0 { cfg.minRecordingSeconds = Config().minRecordingSeconds }
            if cfg.releaseTailMs == 250 { cfg.releaseTailMs = Config().releaseTailMs }  // previous default, felt as lag
            if Config.legacyChatModelLists.contains(cfg.chatModels) { cfg.chatModels = Config().chatModels }
            cfg.save()  // rewrite in the current schema (migrates legacy keys)
            return cfg
        }
        let cfg = Config()
        cfg.save()
        return cfg
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: Config.fileURL)
        }
    }
}
