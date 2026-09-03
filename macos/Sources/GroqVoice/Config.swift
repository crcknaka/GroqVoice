import Foundation

struct Config: Codable {
    var groqApiKey = ""
    /// Priority order: strongest first. On a rate limit the next model is used;
    /// the stronger one is retried automatically once its cooldown expires.
    var transcriptionModels = ["whisper-large-v3", "whisper-large-v3-turbo"]
    var chatModels = ["llama-3.3-70b-versatile", "openai/gpt-oss-120b", "llama-3.1-8b-instant"]
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
    /// isn't clipped when the key comes up mid-word.
    var releaseTailMs = 250.0
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
    /// CoreAudio device UID; "" = system default input.
    var inputDeviceUID = ""
    /// Run the transcript through the LLM to fix punctuation and drop filler
    /// words (wording is kept). Needs Groq or Apple Intelligence.
    var cleanupTranscript = false
    /// "paste" — clipboard + ⌘V; "type" — synthesized keystrokes.
    var pasteMode = "paste"
    var restoreClipboard = true
    var historySize = 50

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("GroqVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var fileURL: URL { supportDir.appendingPathComponent("config.json") }

    var hotkeyKey: HotkeyKey { HotkeyKey(rawValue: hotkey) ?? .fn }
    var pasteModeValue: PasteMode { PasteMode(rawValue: pasteMode) ?? .paste }
    var usesLocalEngine: Bool { sttEngine != "groq" }

    enum CodingKeys: String, CodingKey {
        case groqApiKey, transcriptionModels, chatModels, language
        case taskKeywords, taskKeywordMaxWordPosition
        case minRecordingSeconds, silencePeakPercent
        case saveLastWav, playFeedbackSounds, taskSystemPrompt
        case pttHoldMs, doubleTapWindowMs, releaseTailMs, autostart
        case sttEngine, sttFallback, localUnloadAfterMinutes, vocabularyBoosting
        case hotkey, inputDeviceUID, cleanupTranscript
        case pasteMode, restoreClipboard, historySize
        // Legacy keys, migrated on load.
        case transcriptionModel, chatModel, localMode
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
        inputDeviceUID = get(.inputDeviceUID, d.inputDeviceUID)
        cleanupTranscript = get(.cleanupTranscript, d.cleanupTranscript)
        pasteMode = get(.pasteMode, d.pasteMode)
        restoreClipboard = get(.restoreClipboard, d.restoreClipboard)
        historySize = get(.historySize, d.historySize)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(groqApiKey, forKey: .groqApiKey)
        try c.encode(transcriptionModels, forKey: .transcriptionModels)
        try c.encode(chatModels, forKey: .chatModels)
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
        try c.encode(inputDeviceUID, forKey: .inputDeviceUID)
        try c.encode(cleanupTranscript, forKey: .cleanupTranscript)
        try c.encode(pasteMode, forKey: .pasteMode)
        try c.encode(restoreClipboard, forKey: .restoreClipboard)
        try c.encode(historySize, forKey: .historySize)
    }

    static func load() -> Config {
        if let data = try? Data(contentsOf: fileURL),
           var cfg = try? JSONDecoder().decode(Config.self, from: data) {
            // The old 1.0 s minimum silently swallowed one-word takes ("привет" ≈ 0.5 s).
            if cfg.minRecordingSeconds == 1.0 { cfg.minRecordingSeconds = Config().minRecordingSeconds }
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
