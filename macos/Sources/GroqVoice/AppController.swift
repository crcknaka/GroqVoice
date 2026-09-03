import AVFoundation
import Cocoa
import ServiceManagement

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Answers "is this server reachable?" once per take, lazily, so the probe
/// only costs time on the paths that actually need the network.
final class CloudProbe {
    private let host: String
    private let port: UInt16
    private var cached: Bool?

    init(host: String, port: UInt16 = 443) {
        self.host = host
        self.port = port
    }

    func reachable() async -> Bool {
        if let cached { return cached }
        let result = await Reachability.canReach(host: host, port: port)
        cached = result
        return result
    }
}

final class AppController: NSObject, NSApplicationDelegate {
    enum Phase {
        case idle
        case recording(locked: Bool)
        case processing
    }

    enum IconState: Equatable {
        case inactive       // hotkey not running (permission missing)
        case ready, recording, translating, locked, processing, screenRecording
        case failed         // brief flash after an error
        case copied         // brief flash after copying from Recent
    }

    enum HotkeyStatus: Equatable {
        case active
        case needsAccessibility     // AXIsProcessTrusted() is false
        case needsInputMonitoring   // trusted, but the listen-only tap still failed
    }

    enum TakeKind { case dictate, translate }

    var statusItem: NSStatusItem!
    var config = Config.load()
    let recorder = Recorder()
    let vocabulary = Vocabulary()
    let snippets = Snippets()
    lazy var history = History(limit: config.historySize)
    lazy var groq = GroqClient(apiKey: config.groqApiKey,
                               transcriptionModels: config.transcriptionModels,
                               chatModels: config.chatModels,
                               chatBaseURL: config.chatBaseURL,
                               chatApiKey: config.effectiveChatApiKey)
    lazy var localSTT = LocalSTT(unloadAfterMinutes: config.localUnloadAfterMinutes)
    lazy var hotkey = HotkeyMonitor(keys: monitoredKeys)
    let screenRecorder = ScreenRecorder()
    var screenRecording = false
    lazy var settingsWindow = SettingsWindowController(app: self)
    lazy var historyWindow = HistoryWindowController(app: self)

    var phase: Phase = .idle
    var hotkeyStatus: HotkeyStatus = .needsAccessibility
    /// Menu/settings text for the local model row ("downloading 42%", "compiling…").
    var localModelStatus: String?

    private var takeKind: TakeKind = .dictate
    private var activeKey: HotkeyKey?
    private var keyDownAt: Date?
    private var lastQuickTapAt: Date?
    private var chordCancelled = false
    private var ignoreNextKeyUp = false
    private var accessibilityRetryTimer: Timer?
    private var animationTimer: Timer?
    private var spinnerAngle: CGFloat = 90
    private var flashTimer: Timer?
    private var tailTimer: Timer?
    private var releasedAt: Date?
    private var settingsWindowLoaded = false
    private var historyWindowLoaded = false

    /// The push-to-talk key plus the translate key, when one is set.
    var monitoredKeys: Set<HotkeyKey> {
        var keys: Set<HotkeyKey> = [config.hotkeyKey]
        if let translate = config.translateHotkeyKey { keys.insert(translate) }
        return keys
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("=== GroqVoice for macOS started (engine: \(config.sttEngine), hotkey: \(config.hotkey), translate: \(config.translateHotkey.isEmpty ? "off" : config.translateHotkey)) ===")
        Log.write("Apple Intelligence: \(LocalLLM.statusDescription)")
        NSApp.mainMenu = MainMenu.build(app: self)
        setupStatusItem()
        setIcon(.inactive)

        requestMicAccess()
        startHotkeyWhenTrusted()
        syncLoginItem()

        localSTT.onStage = { [weak self] stage in self?.showLocalStage(stage) }

        recorder.onInterrupted = { [weak self] in
            guard let self, case .recording = self.phase else { return }
            self.finishRecording()
        }
        prepareRecorder()

        history.onChange = { [weak self] in
            guard let self, self.historyWindowLoaded else { return }
            self.historyWindow.reloadIfVisible()
        }

        screenRecorder.onFinish = { [weak self] url in
            guard let self else { return }
            self.screenRecording = false
            self.playSound("Tink")
            if case .idle = self.phase { self.setIcon(.ready) }
            if let url {
                Log.write("screen recording saved: \(url.path)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }

        if config.usesLocalEngine && !localSTT.isModelDownloaded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.firstRunPrompt() }
        } else if config.usesLocalEngine {
            // Warm the model (and vocabulary boosting) at launch so the very
            // first dictation is instant.
            localSTT.warmUpInBackground(vocabularyFile: config.vocabularyBoosting ? Vocabulary.fileURL : nil)
        }

        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot-ui") {
            let dir = CommandLine.arguments.count > flag + 1 ? CommandLine.arguments[flag + 1] : "."
            snapshotUI(to: URL(fileURLWithPath: dir))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
        Log.write("=== GroqVoice quit ===")
    }

    /// Called by the Settings window (and the quick-toggle menu) after they
    /// wrote to `config`: persists it and re-applies everything that has
    /// runtime state.
    func settingsChanged() {
        config.save()
        groq.apply(config)
        hotkey.keys = monitoredKeys
        localSTT.setUnloadAfterMinutes(config.localUnloadAfterMinutes)
        prepareRecorder()
        if config.usesLocalEngine {
            localSTT.warmUpInBackground(vocabularyFile: config.vocabularyBoosting ? Vocabulary.fileURL : nil)
        }
        syncLoginItem()
        if case .idle = phase { setIcon(.ready) }
    }

    // MARK: - Permissions & first run

    private func requestMicAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.write("microphone access \(granted ? "granted" : "denied")")
            }
        default:
            Log.write("microphone access denied — enable in System Settings → Privacy & Security → Microphone")
        }
    }

    private func startHotkeyWhenTrusted() {
        if tryStartHotkey(prompt: true) { return }

        Log.write("waiting for Accessibility permission… (status: \(hotkeyStatus))")
        accessibilityRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.tryStartHotkey(prompt: false) {
                timer.invalidate()
                self.accessibilityRetryTimer = nil
            }
        }
    }

    /// One attempt to bring the global hotkey up. Distinguishes "not trusted
    /// for Accessibility" from "trusted, but the tap still failed" (which on
    /// recent macOS means Input Monitoring is also needed) and logs
    /// transitions only, so the 2-second retry doesn't flood the log.
    @discardableResult
    private func tryStartHotkey(prompt: Bool) -> Bool {
        let previous = hotkeyStatus
        let trusted: Bool
        if prompt {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        } else {
            trusted = AXIsProcessTrusted()
        }

        if !trusted {
            hotkeyStatus = .needsAccessibility
        } else if hotkey.start() {
            hotkeyStatus = .active
            wireHotkey()
            if case .idle = phase { setIcon(.ready) }
            Log.write("event tap started (\(monitoredKeys.map(\.title).sorted().joined(separator: ", ")) monitor active)")
            return true
        } else {
            hotkeyStatus = .needsInputMonitoring
            if previous != .needsInputMonitoring {
                Log.write("Accessibility is granted but the event tap could not be created — requesting Input Monitoring")
                CGRequestListenEventAccess()
            }
        }
        if previous != hotkeyStatus { Log.write("hotkey status → \(hotkeyStatus)") }
        return false
    }

    /// Opens the relevant Privacy & Security pane.
    @objc func openPermissionSettings() {
        let pane = hotkeyStatus == .needsInputMonitoring ? "Privacy_ListenEvent" : "Privacy_Accessibility"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Starts a fresh copy of the app and quits this one — the quickest way to
    /// pick up a permission macOS only applies to newly launched processes.
    @objc func relaunch() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Makes the Login Items registration match `config.autostart`.
    func syncLoginItem() {
        let enabled = SMAppService.mainApp.status == .enabled
        guard enabled != config.autostart else { return }
        do {
            if config.autostart {
                try SMAppService.mainApp.register()
                Log.write("launch-at-login enabled")
            } else {
                try SMAppService.mainApp.unregister()
                Log.write("launch-at-login disabled")
            }
        } catch {
            Log.write("launch-at-login change failed: \(error.localizedDescription)")
            config.autostart = enabled
            config.save()
        }
    }

    private func firstRunPrompt() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Welcome to GroqVoice"
        alert.informativeText = """
        Hold \(config.hotkeyKey.title), speak, release — the text lands in whatever you're typing in.

        Speech is recognized on this Mac by Parakeet v3 (Russian, English, Latvian and 22 more), \
        no account needed. The model is a one-time download of about \(LocalSTT.approximateDownloadMB) MB.

        When macOS asks, allow Microphone and Accessibility — both are required for the hotkey and for pasting.
        """
        alert.addButton(withTitle: "Download Model")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            localSTT.warmUpInBackground(vocabularyFile: config.vocabularyBoosting ? Vocabulary.fileURL : nil)
        }
    }

    // MARK: - Hotkey state machine

    private func wireHotkey() {
        hotkey.onKeyDown = { [weak self] key in self?.keyDown(key) }
        hotkey.onKeyUp = { [weak self] key in self?.keyUp(key) }
        hotkey.onChordKey = { [weak self] in self?.chordKey() }
        hotkey.onScreenToggle = { [weak self] in self?.toggleScreenRecording() }
    }

    private func keyDown(_ key: HotkeyKey) {
        switch phase {
        case .recording(locked: true):
            // The key that started a locked recording also stops it.
            guard key == activeKey else { return }
            ignoreNextKeyUp = true
            scheduleFinish()
        case .idle:
            activeKey = key
            takeKind = key == config.translateHotkeyKey ? .translate : .dictate
            keyDownAt = Date()
            chordCancelled = false
            startRecording(locked: false)
        case .recording(locked: false):
            // Pressed again during the release tail: keep the same take going.
            guard key == activeKey, tailTimer != nil else { return }
            tailTimer?.invalidate()
            tailTimer = nil
            keyDownAt = Date()
            chordCancelled = false
        case .processing:
            break
        }
    }

    private func keyUp(_ key: HotkeyKey) {
        guard key == activeKey else { return }
        if ignoreNextKeyUp {
            ignoreNextKeyUp = false
            return
        }
        guard case .recording(locked: false) = phase, !chordCancelled, let t0 = keyDownAt else { return }

        let heldMs = Date().timeIntervalSince(t0) * 1000
        if heldMs >= config.pttHoldMs {
            scheduleFinish()
            return
        }

        // Quick tap: a second tap within the window locks the recording on.
        let now = Date()
        if let prev = lastQuickTapAt, now.timeIntervalSince(prev) * 1000 < config.doubleTapWindowMs {
            lastQuickTapAt = nil
            phase = .recording(locked: true)
            setIcon(.locked)
            Log.write("double-tap → recording locked on")
        } else {
            lastQuickTapAt = now
            discardRecording(reason: "single tap")
        }
    }

    private func chordKey() {
        // Hotkey + another key is an OS shortcut — drop the recording.
        if case .recording = phase, !chordCancelled {
            chordCancelled = true
            ignoreNextKeyUp = true
            discardRecording(reason: "chord with another key")
        }
    }

    /// Stops the take after `releaseTailMs` so a key released mid-word still
    /// captures the last syllable. A new press within the tail cancels it.
    private func scheduleFinish() {
        tailTimer?.invalidate()
        releasedAt = Date()
        let tail = max(0, config.releaseTailMs) / 1000
        guard tail > 0 else { finishRecording(); return }
        tailTimer = Timer.scheduledTimer(withTimeInterval: tail, repeats: false) { [weak self] _ in
            self?.tailTimer = nil
            self?.finishRecording()
        }
    }

    /// Keeps an engine for the configured microphone prepared while idle.
    func prepareRecorder() {
        recorder.prepare(deviceUID: config.inputDeviceUID)
    }

    // MARK: - Recording pipeline

    private func startRecording(locked: Bool) {
        do {
            try recorder.start(deviceUID: config.inputDeviceUID)
            phase = .recording(locked: locked)
            setIcon(takeKind == .translate ? .translating : .recording)
            playSound("Pop")
            Log.write("recording started (\(takeKind == .translate ? "translate" : "dictate"))")
        } catch {
            phase = .idle
            flashIcon(.failed)
            playSound("Basso")
            Log.write("mic error: \(error.localizedDescription)")
        }
    }

    private func discardRecording(reason: String) {
        tailTimer?.invalidate()
        tailTimer = nil
        recorder.discard()
        phase = .idle
        setIcon(.ready)
        Log.write("recording discarded (\(reason))")
        prepareRecorder()
    }

    private func finishRecording() {
        tailTimer?.invalidate()
        tailTimer = nil
        guard let take = recorder.stop() else {
            phase = .idle
            setIcon(.ready)
            return
        }
        playSound("Tink")
        Log.write(String(format: "recording stopped: %.2fs, peak=%.2f%%", take.duration, take.peakPercent))

        if take.duration < config.minRecordingSeconds {
            discardRecording(reason: "too short (< \(config.minRecordingSeconds)s)")
            return
        }
        if take.peakPercent < config.silencePeakPercent {
            discardRecording(reason: "silence (peak < \(config.silencePeakPercent)%)")
            return
        }

        phase = .processing
        setIcon(.processing)

        let cfg = config
        let kind = takeKind
        let released = releasedAt ?? Date()
        let vocabPrompt = vocabulary.prompt()
        let sttProbe = CloudProbe(host: "api.groq.com")
        let chatProbe = CloudProbe(host: cfg.chatHost, port: cfg.chatPort)

        Task { [weak self] in
            guard let self else { return }
            do {
                let sttStarted = Date()
                var transcript = try await self.obtainTranscript(take: take, cfg: cfg, vocabPrompt: vocabPrompt, probe: sttProbe)
                let sttSeconds = Date().timeIntervalSince(sttStarted)
                Log.write("STT result: \"\(transcript)\"")
                let aliased = self.vocabulary.applyAliases(to: transcript)
                if !aliased.changes.isEmpty {
                    transcript = aliased.text
                    Log.write("vocabulary aliases: \(aliased.changes.joined(separator: ", "))")
                }
                guard !transcript.isEmpty else {
                    throw AppError("Nothing recognized")
                }

                var output = transcript
                var historyKind = "dictation"
                if kind == .translate {
                    historyKind = "translate"
                    let system = TaskRouter.translateSystemPrompt(to: cfg.translateLanguageName)
                    guard let translated = await self.obtainChatAnswer(query: transcript, system: system, cfg: cfg,
                                                                       probe: chatProbe, temperature: 0),
                          !translated.isEmpty else {
                        throw AppError("No language model for translation — configure one in Settings → Groq & LLM")
                    }
                    output = translated
                    Log.write("translated → \(cfg.translateLanguage): \"\(output.prefix(200))\"")
                } else if let query = TaskRouter.taskQuery(from: transcript,
                                                           keywords: cfg.taskKeywords,
                                                           maxPosition: cfg.taskKeywordMaxWordPosition) {
                    historyKind = "task"
                    Log.write("task mode → chat: \"\(query)\"")
                    let base = cfg.taskSystemPrompt.isEmpty ? TaskRouter.defaultSystemPrompt : cfg.taskSystemPrompt
                    let system = base + self.snippets.systemPromptSection()
                    if let answer = await self.obtainChatAnswer(query: query, system: system, cfg: cfg, probe: chatProbe),
                       !answer.isEmpty {
                        output = answer
                        Log.write("chat result: \"\(output.prefix(200))\"")
                    } else {
                        // A task was recognized but no LLM could run it. Never paste
                        // the raw "задание …" transcript — that's just noise.
                        throw AppError("No language model available for task mode")
                    }
                } else if cfg.cleanupTranscript {
                    output = await self.cleanup(transcript, vocabulary: vocabPrompt, cfg: cfg, probe: chatProbe)
                }

                let finalText = output
                let finalKind = historyKind
                await MainActor.run {
                    Paster.deliver(finalText, mode: cfg.pasteModeValue, restoreClipboard: cfg.restoreClipboard)
                    Log.write(String(format: "take: key released → pasted in %.2fs (tail %.0f ms, stt %.2fs)",
                                     Date().timeIntervalSince(released), cfg.releaseTailMs, sttSeconds))
                    self.history.add(finalText, kind: finalKind)
                    self.finishProcessing(cfg: cfg)
                }
            } catch {
                Log.write("error: \(AppController.shortError(error)) — \(error.localizedDescription)")
                await MainActor.run {
                    self.playSound("Basso")
                    self.finishProcessing(cfg: cfg)
                    self.flashIcon(.failed)
                }
            }
        }
    }

    private func finishProcessing(cfg: Config) {
        if !cfg.saveLastWav {
            try? FileManager.default.removeItem(at: Recorder.wavURL)
        }
        phase = .idle
        setIcon(.ready)
        // Prepare the next take's engine only now — doing it before the
        // transcription started was adding ~100 ms to every dictation.
        prepareRecorder()
    }

    /// Pastes the most recent history entry into the focused app again.
    func pasteLastAgain() {
        guard let entry = history.latest else { return }
        Log.write("paste last again (\(entry.text.count) chars)")
        Paster.deliver(entry.text, mode: config.pasteModeValue, restoreClipboard: config.restoreClipboard)
    }

    /// STT routing between the on-device engine and Groq, honouring
    /// `sttEngine` and `sttFallback`. The first dictation on a fresh install
    /// goes to Groq (if a key is set) while Parakeet downloads in the
    /// background, so the user never waits for the model.
    private func obtainTranscript(take: Recorder.Result, cfg: Config, vocabPrompt: String, probe: CloudProbe) async throws -> String {
        let hasKey = !cfg.groqApiKey.isEmpty

        func cloud() async throws -> String {
            guard hasKey else { throw AppError("Groq API key is not set") }
            return try await groq.transcribe(wav: take.wav, language: cfg.language, prompt: vocabPrompt)
        }
        func local() async throws -> String {
            try await localSTT.transcribe(pcm16: take.pcm, language: cfg.language,
                                          vocabularyFile: cfg.vocabularyBoosting ? Vocabulary.fileURL : nil)
        }

        if cfg.usesLocalEngine {
            if !localSTT.isModelDownloaded, cfg.sttFallback, hasKey, await probe.reachable() {
                Log.write("STT: local model not downloaded yet → Groq for this take, model downloading in background")
                localSTT.warmUpInBackground(vocabularyFile: cfg.vocabularyBoosting ? Vocabulary.fileURL : nil)
                return try await cloud()
            }
            do {
                return try await local()
            } catch where cfg.sttFallback && hasKey {
                Log.write("STT: on-device engine failed (\(error.localizedDescription.prefix(120))) → Groq")
                return try await cloud()
            }
        } else {
            guard hasKey else {
                guard cfg.sttFallback else {
                    throw AppError("Groq API key is not set — add it in Settings or switch to the on-device engine")
                }
                return try await local()
            }
            if cfg.sttFallback, localSTT.isModelDownloaded, !(await probe.reachable()) {
                Log.write("STT: Groq not reachable → on-device engine")
                return try await local()
            }
            do {
                return try await cloud()
            } catch where cfg.sttFallback {
                Log.write("STT: Groq failed (\(error.localizedDescription.prefix(120))) → on-device engine")
                return try await local()
            }
        }
    }

    /// Chat routing for task mode, translation and clean-up. The configured
    /// endpoint (Groq or a custom OpenAI-compatible server) is preferred
    /// whenever reachable; Apple's on-device model is the fallback.
    /// Returns nil if no backend answered.
    private func obtainChatAnswer(query: String, system: String, cfg: Config, probe: CloudProbe,
                                  temperature: Double = 0.3) async -> String? {
        let configured = cfg.llmConfigured
        let reachable = configured ? await probe.reachable() : false
        if reachable {
            do {
                return try await groq.chat(userText: query, systemPrompt: system, temperature: temperature)
            } catch {
                Log.write("chat: \(cfg.chatHost) failed (\(error.localizedDescription.prefix(120)))")
            }
        }
        if LocalLLM.isAvailable {
            do {
                Log.write("chat: using Apple on-device model")
                return try await LocalLLM.respond(system: system, user: query)
            } catch {
                Log.write("chat: local model failed: \(error.localizedDescription)")
            }
        }
        // The probe may have been a transient false negative — try anyway.
        if configured && !reachable {
            do {
                return try await groq.chat(userText: query, systemPrompt: system, temperature: temperature)
            } catch {
                Log.write("chat: \(cfg.chatHost) last-resort failed (\(error.localizedDescription.prefix(120)))")
            }
        }
        return nil
    }

    /// Optional LLM pass over plain dictation: punctuation, casing, fillers,
    /// vocabulary spellings. Falls back to the raw transcript on any doubt.
    private func cleanup(_ transcript: String, vocabulary: String, cfg: Config, probe: CloudProbe) async -> String {
        let words = transcript.split(whereSeparator: { $0.isWhitespace }).count
        guard words >= 3 else { return transcript }
        let system = TaskRouter.cleanupSystemPrompt(vocabulary: vocabulary)
        guard let cleaned = await obtainChatAnswer(query: transcript, system: system, cfg: cfg, probe: probe, temperature: 0),
              !cleaned.isEmpty else {
            Log.write("cleanup: no LLM answer — using raw transcript")
            return transcript
        }
        // A reply that is much shorter or longer than the input is the model
        // answering or elaborating instead of editing — keep the original.
        let ratio = Double(cleaned.count) / Double(max(1, transcript.count))
        guard ratio > 0.5, ratio < 1.6 else {
            Log.write(String(format: "cleanup: rejected (length ratio %.2f)", ratio))
            return transcript
        }
        Log.write("cleanup: \"\(cleaned.prefix(200))\"")
        return cleaned
    }

    static func shortError(_ error: Error) -> String {
        let text = error.localizedDescription
        if let groq = error as? GroqError {
            switch groq.status {
            case 401: return "Invalid API key"
            case 429: return "Rate limit — try again in a moment"
            default: return "HTTP \(groq.status)"
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed:
                return "No network connection"
            case .timedOut: return "Network timeout"
            default: break
            }
        }
        return text.count > 90 ? String(text.prefix(87)) + "…" : text
    }

    func playSound(_ name: String) {
        guard config.playFeedbackSounds else { return }
        NSSound(named: name)?.play()
    }

    // MARK: - Windows

    @objc func menuShowSettings() {
        settingsWindowLoaded = true
        settingsWindow.show()
    }

    @objc func menuShowHistory() {
        historyWindowLoaded = true
        historyWindow.show()
    }

    /// Debug: `--snapshot-ui <dir>` renders the Settings tabs and the History
    /// window to PNGs and quits. Own windows can be captured without the
    /// Screen Recording permission.
    private func snapshotUI(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settingsWindowLoaded = true
        historyWindowLoaded = true
        settingsWindow.show()
        historyWindow.show()

        func capture(_ window: NSWindow?, _ name: String) {
            guard let window,
                  let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                   [.boundsIgnoreFraming, .bestResolution]) else {
                print("capture failed: \(name)")
                return
            }
            let rep = NSBitmapImageRep(cgImage: cg)
            if let png = rep.representation(using: .png, properties: [:]) {
                let url = dir.appendingPathComponent(name + ".png")
                try? png.write(to: url)
                print("wrote \(url.path) (\(cg.width)×\(cg.height))")
            }
        }

        var step = 0
        func next() {
            switch step {
            case 0..<3:
                settingsWindow.selectTab(step)
                settingsWindow.window?.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    capture(self.settingsWindow.window, "settings-\(step)")
                    step += 1
                    next()
                }
            case 3:
                historyWindow.window?.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    capture(self.historyWindow.window, "history")
                    exit(0)
                }
            default:
                exit(0)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { next() }
    }

    // MARK: - Status item icon

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.toolTip = "GroqVoice"
    }

    func setIcon(_ state: IconState) {
        stopSpinner()
        guard let button = statusItem.button else { return }
        // While screen-recording, keep the red video badge on the idle state so
        // an audio push-to-talk in the middle doesn't hide that we're recording.
        var state = state
        if state == .ready, hotkeyStatus != .active { state = .inactive }
        if screenRecording, state == .ready { state = .screenRecording }
        let (symbol, tint): (String, NSColor?) = {
            switch state {
            case .inactive: return ("mic.slash", .systemGray)
            case .ready: return ("mic", nil)
            case .recording: return ("mic.fill", .systemRed)
            case .translating: return ("mic.fill", .systemBlue)
            case .locked: return ("mic.fill", .systemOrange)
            case .processing: return ("hourglass", .systemYellow)
            case .screenRecording: return ("video.fill", .systemRed)
            case .failed: return ("exclamationmark.triangle.fill", .systemYellow)
            case .copied: return ("doc.on.clipboard.fill", nil)
            }
        }()
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "GroqVoice")
        image?.isTemplate = (tint == nil)
        button.image = image
        button.contentTintColor = tint
        button.title = ""
        button.imagePosition = .imageOnly
    }

    /// Shows a transient state in the menu bar for a moment, then returns to
    /// whatever the current phase calls for.
    func flashIcon(_ state: IconState, for seconds: TimeInterval = 2.5) {
        flashTimer?.invalidate()
        setIcon(state)
        flashTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, case .idle = self.phase else { return }
            self.setIcon(.ready)
        }
    }

    /// Reflects on-device model work in the menu bar: a filling ring while the
    /// model downloads, a spinner while CoreML compiles it.
    private func showLocalStage(_ stage: LocalSTT.Stage) {
        guard let button = statusItem.button else { return }
        let recording: Bool = { if case .recording = phase { return true } else { return false } }()

        switch stage {
        case .downloadingModel(let f):
            localModelStatus = "downloading… \(Int(f * 100))%"
            if !recording {
                stopSpinner()
                button.contentTintColor = nil
                button.image = ProgressIcon.ring(fraction: f, color: .controlAccentColor)
            }
        case .loadingModel:
            localModelStatus = "compiling for the Neural Engine…"
            if !recording { startSpinner() }
        case .transcribing:
            break
        case .ready:
            localModelStatus = nil
            if case .idle = phase { setIcon(.ready) }
        case .failed(let message):
            localModelStatus = "download failed: \(message.prefix(60))"
            if case .idle = phase {
                playSound("Basso")
                flashIcon(.failed)
            }
        }
        if settingsWindowLoaded { settingsWindow.refreshIfVisible() }
    }

    private func startSpinner() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            guard let self, let button = self.statusItem.button else { return }
            self.spinnerAngle -= 24
            button.contentTintColor = nil
            button.imagePosition = .imageOnly
            button.image = ProgressIcon.spinner(angle: self.spinnerAngle, color: .controlAccentColor)
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopSpinner() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    // MARK: - Screen recording (⌃⌥⌘R)

    @objc func toggleScreenRecording() {
        if screenRecorder.isRecording {
            screenRecorder.stop()  // onFinish updates icon + reveals file
            Log.write("screen recording stopped by hotkey/menu")
            return
        }

        guard ScreenRecorder.hasPermission else {
            ScreenRecorder.requestPermission()
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Screen Recording permission needed"
            alert.informativeText = "Enable GroqVoice in System Settings → Privacy & Security → Screen Recording, then press ⌃⌥⌘R again."
            alert.runModal()
            Log.write("screen recording blocked — permission not granted")
            return
        }

        let display = ScreenRecorder.activeDisplayID()
        if screenRecorder.start(displayID: display) {
            screenRecording = true
            playSound("Pop")
            setIcon(.screenRecording)
            Log.write("screen recording started (display \(display)) → \(screenRecorder.currentURL?.lastPathComponent ?? "?")")
        } else {
            playSound("Basso")
            Log.write("screen recording failed to start")
        }
    }
}
