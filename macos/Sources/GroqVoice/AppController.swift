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

/// Where a take's time went, for the log: "stop 12 · probe 3 · stt 118 · paste 9 ms".
/// Stages run on the main thread and on the take's task, sometimes at once.
final class TakeTiming {
    let released: Date
    private let lock = NSLock()
    private var stages: [(name: String, ms: Double)] = []

    init(released: Date) { self.released = released }

    func add(_ stage: String, since start: Date) {
        let ms = Date().timeIntervalSince(start) * 1000
        lock.lock(); defer { lock.unlock() }
        if let i = stages.firstIndex(where: { $0.name == stage }) { stages[i].ms += ms } else { stages.append((stage, ms)) }
    }

    func measure<T>(_ stage: String, _ work: () throws -> T) rethrows -> T {
        let start = Date()
        defer { add(stage, since: start) }
        return try work()
    }

    func measure<T>(_ stage: String, _ work: () async throws -> T) async rethrows -> T {
        let start = Date()
        defer { add(stage, since: start) }
        return try await work()
    }

    var summary: String {
        lock.lock(); defer { lock.unlock() }
        return stages.map { "\($0.name) \(Int($0.ms.rounded()))" }.joined(separator: " · ") + " ms"
    }
}

final class AppController: NSObject, NSApplicationDelegate {
    typealias Phase = PushToTalk.Phase

    enum IconState: Equatable {
        case inactive       // hotkey not running (permission missing)
        case ready, recording, translating, custom, editing, locked, processing
        case failed         // brief flash after an error
        case copied         // brief flash after copying from Recent
    }

    enum HotkeyStatus: Equatable {
        case active
        case needsAccessibility     // AXIsProcessTrusted() is false
        case needsInputMonitoring   // trusted, but the listen-only tap still failed
    }

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
    // Windows are built the first time they are shown.
    private(set) var settingsWindow: SettingsWindowController?
    private(set) var historyWindow: HistoryWindowController?
    private(set) var dictionaryWindow: DictionaryWindowController?

    var phase: Phase = .idle
    var hotkeyStatus: HotkeyStatus = .needsAccessibility
    /// Menu/settings text for the local model row ("downloading 42%", "compiling…").
    var localModelStatus: String?

    private var takeKind: TakeKind = .dictate
    /// Text that was selected in the focused app when the take started.
    private var pendingSelection: String?
    /// Accessibility couldn't tell; try a ⌘C probe once the key is released.
    private var selectionNeedsCopyProbe = false
    private var pushToTalk = PushToTalk()
    private var accessibilityRetryTimer: Timer?
    private var animationTimer: Timer?
    private var spinnerAngle: CGFloat = 90
    private var flashTimer: Timer?
    private var tailTimer: Timer?
    private var maxLengthTimer: Timer?
    private var releasedAt: Date?
    /// The take being processed, kept so Esc can abandon it.
    private var takeTask: Task<Void, Never>?
    private var sttTask: Task<String, Error>?
    private var processingSince: Date?
    /// Why the last take failed, for the menu; cleared by the next one that works.
    var lastError: (message: String, at: Date)?

    /// The push-to-talk key plus every key that has an action.
    var monitoredKeys: Set<HotkeyKey> {
        Set(config.activeKeyActions.map(\.key) + [config.hotkey])
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let actions = config.activeKeyActions.map { "\($0.key) = \($0.summary)" }.joined(separator: "; ")
        Log.write("=== GroqVoice for macOS started (engine: \(config.sttEngine), hotkey: \(config.hotkey), keys: \(actions.isEmpty ? "none" : actions)) ===")
        Log.write("Apple Intelligence: \(LocalLLM.statusDescription)")
        Config.protectSupportDir()
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

        history.onChange = { [weak self] in self?.historyWindow?.reloadIfVisible() }

        if config.usesLocalEngine && !localSTT.isModelDownloaded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.firstRunPrompt() }
        } else if config.usesLocalEngine {
            // Warm the model at launch so the very first dictation is instant.
            localSTT.warmUpInBackground()
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
        history.limit = config.historySize
        if !config.saveLastWav { try? FileManager.default.removeItem(at: Recorder.wavURL) }
        prepareRecorder()
        if config.usesLocalEngine { localSTT.warmUpInBackground() }
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
        Hold \(config.hotkey.title), speak, release — the text lands in whatever you're typing in.

        Speech is recognized on this Mac by Parakeet v3 (Russian, English, Latvian and 22 more), \
        no account needed. The model is a one-time download of about \(LocalSTT.approximateDownloadMB) MB.

        When macOS asks, allow Microphone and Accessibility — both are required for the hotkey and for pasting.
        """
        alert.addButton(withTitle: "Download Model")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { localSTT.warmUpInBackground() }
    }

    // MARK: - Hotkey state machine

    private func wireHotkey() {
        hotkey.onKeyDown = { [weak self] key in self?.keyDown(key) }
        hotkey.onKeyUp = { [weak self] key in self?.keyUp(key) }
        hotkey.onChordKey = { [weak self] in self?.chordKey() }
        hotkey.onEscape = { [weak self] in self?.escape() }
    }

    private func escape() {
        switch phase {
        case .recording:
            discardRecording(reason: "escape")
        case .processing:
            // Esc is an ordinary key in the app being typed into, and a take
            // is normally done within a fraction of a second — only one that
            // is visibly stuck is abandoned by it.
            guard let since = processingSince, Date().timeIntervalSince(since) >= 1 else { return }
            Log.write("processing cancelled (escape)")
            takeTask?.cancel()
            sttTask?.cancel()
            finishProcessing()
        case .idle:
            break
        }
    }

    private func keyDown(_ key: HotkeyKey) {
        perform(pushToTalk.keyDown(key, phase: phase, inTail: tailTimer != nil))
    }

    private func keyUp(_ key: HotkeyKey) {
        perform(pushToTalk.keyUp(key, phase: phase, cfg: config) { [self] in
            // The key is up now, so a ⌘C probe is safe if Accessibility couldn't tell.
            guard case .action = takeKind else { return false }
            resolveSelectionByCopyIfNeeded()
            return pendingSelection != nil
        })
    }

    private func perform(_ command: PushToTalk.Command?) {
        switch command {
        case .start(let key):
            takeKind = config.action(for: key).map { .action($0) } ?? .dictate
            startRecording(locked: false)
        case .resume:
            tailTimer?.invalidate()
            tailTimer = nil
        case .finish:
            scheduleFinish()
        case .lock:
            phase = .recording(locked: true)
            setIcon(.locked)
            Log.write("double-tap → recording locked on")
        case .discard(let reason):
            discardRecording(reason: reason)
        case nil:
            break
        }
    }

    /// Second half of the selection probe: ⌘C, allowed only once the hotkey is
    /// released (a chorded ⌘C would have been ⌥⌘C or ⌃⌘C for the app).
    private func resolveSelectionByCopyIfNeeded() {
        guard pendingSelection == nil, selectionNeedsCopyProbe else { return }
        selectionNeedsCopyProbe = false
        let probe = FocusedText.probeSelection(allowCopy: true)
        pendingSelection = probe.text
        Log.write(probe.description)
    }

    private func chordKey() { perform(pushToTalk.chord(phase: phase)) }

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
        recorder.preferBuiltInOverBluetooth = config.preferBuiltInMic
        recorder.prepare(deviceUID: config.inputDeviceUID)
    }

    // MARK: - Recording pipeline

    private func startRecording(locked: Bool) {
        do {
            try recorder.start(deviceUID: config.inputDeviceUID)
            phase = .recording(locked: locked)
            // A selection at key-down becomes the target: dictation edits it,
            // an action key applies its action to it.
            pendingSelection = nil
            selectionNeedsCopyProbe = false
            let wantsSelection = takeKind == .dictate ? config.editSelection : true
            if wantsSelection, config.llmConfigured || LocalLLM.isAvailable {
                let probe = FocusedText.probeSelection(allowCopy: false)
                pendingSelection = probe.text
                selectionNeedsCopyProbe = probe.copyWorthTrying
                Log.write(probe.description)
            }
            let icon: IconState
            let label: String
            switch takeKind {
            case .action(let action):
                icon = action.isTranslate ? .translating : .custom
                label = action.summary + (pendingSelection != nil ? " (selection, \(pendingSelection!.count) chars)" : "")
            case .dictate:
                icon = pendingSelection != nil ? .editing : .recording
                label = pendingSelection != nil ? "edit selection, \(pendingSelection!.count) chars" : "dictate"
            }
            setIcon(icon)
            playSound("Pop")
            Log.write("recording started (\(label))")
            startMaxLengthTimer()
        } catch {
            phase = .idle
            lastError = (AppController.shortError(error), Date())
            flashIcon(.failed)
            playSound("Basso")
            Log.write("mic error: \(error.localizedDescription)")
        }
    }

    /// Stops and processes a take that reached `maxRecordingMinutes`.
    private func startMaxLengthTimer() {
        maxLengthTimer?.invalidate()
        let minutes = config.maxRecordingMinutes
        guard minutes > 0 else { return }
        maxLengthTimer = Timer.scheduledTimer(withTimeInterval: minutes * 60, repeats: false) { [weak self] _ in
            guard let self, case .recording = self.phase else { return }
            Log.write("recording reached the \(minutes) min limit — stopping")
            self.finishRecording()
        }
    }

    private func discardRecording(reason: String) {
        tailTimer?.invalidate()
        tailTimer = nil
        maxLengthTimer?.invalidate()
        maxLengthTimer = nil
        recorder.discard()
        phase = .idle
        pendingSelection = nil
        selectionNeedsCopyProbe = false
        setIcon(.ready)
        Log.write("recording discarded (\(reason))")
        prepareRecorder()
    }

    private func finishRecording() {
        tailTimer?.invalidate()
        tailTimer = nil
        maxLengthTimer?.invalidate()
        maxLengthTimer = nil
        // Not every stop follows a key release (the length limit, a microphone
        // that went away): those are timed from now.
        let timing = TakeTiming(released: releasedAt ?? Date())
        releasedAt = nil
        guard let take = timing.measure("stop", { recorder.stop() }) else {
            phase = .idle
            setIcon(.ready)
            return
        }
        playSound("Tink")
        Log.write(String(format: "recording stopped: %.2fs, peak=%.2f%%", take.duration, take.peakPercent))

        let kind = takeKind
        let cfg = config
        let vocabPrompt = vocabulary.prompt()
        let chatProbe = CloudProbe(host: cfg.chatHost, port: cfg.chatPort)
        let tooShort = take.duration < cfg.minRecordingSeconds
        let silent = take.peakPercent < cfg.silencePeakPercent

        // Recognition starts right away, on its own thread: the ⌘C selection
        // probe below holds the main thread while it waits, and used to delay it.
        let sttTask: Task<String, Error>? = (tooShort || silent) ? nil : Task { [weak self] in
            guard let self else { return "" }
            return try await timing.measure("stt") {
                try await self.obtainTranscript(take: take, cfg: cfg, vocabPrompt: vocabPrompt,
                                                probe: CloudProbe(host: "api.groq.com"))
            }
        }

        timing.measure("probe") { resolveSelectionByCopyIfNeeded() }
        let selection = pendingSelection
        pendingSelection = nil
        selectionNeedsCopyProbe = false
        // An action key with a selection needs no speech at all; anything
        // else that is too short or silent was an accidental press.
        if sttTask == nil {
            var actionOnSelection = false
            if case .action = kind, selection != nil { actionOnSelection = true }
            guard actionOnSelection else {
                discardRecording(reason: tooShort ? "too short (< \(cfg.minRecordingSeconds)s)"
                                                 : "silence (peak < \(cfg.silencePeakPercent)%)")
                return
            }
        }
        if cfg.saveLastWav { take.saveForDebugging() }

        phase = .processing
        processingSince = Date()
        setIcon(.processing)
        self.sttTask = sttTask

        // On the main actor: the vocabulary, the snippets and the history are
        // main-thread state. Only the awaits (recognition, the model) leave it.
        takeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var transcript = ""
                if let sttTask {
                    transcript = try await sttTask.value
                    try Task.checkCancellation()
                    Log.write("STT result: \"\(transcript)\"")
                    let aliased = self.vocabulary.applyAliases(to: transcript)
                    if !aliased.changes.isEmpty {
                        transcript = aliased.text
                        Log.write("vocabulary aliases: \(aliased.changes.joined(separator: ", "))")
                    }
                    guard !transcript.isEmpty || selection != nil else {
                        throw AppError("Nothing recognized")
                    }
                }

                let plan = try TakePlan.make(transcript: transcript, selection: selection, take: kind, cfg: cfg,
                                             snippets: self.snippets, vocabularyPrompt: vocabPrompt)
                var answer: String?
                if let request = plan.request {
                    Log.write("\(plan.kind.rawValue) → language model")
                    answer = await timing.measure("llm") {
                        await self.obtainChatAnswer(query: request.user, system: request.system, cfg: cfg,
                                                    probe: chatProbe, temperature: request.temperature)
                    }
                    try Task.checkCancellation()
                }
                let result = try plan.result(answer: answer)
                if let note = result.note { Log.write(note) }
                if result.text != transcript {
                    Log.write("\(result.kind.rawValue) → \"\(result.text.prefix(200).replacingOccurrences(of: "\n", with: "⏎"))\"")
                }
                self.deliver(result, replacingSelection: selection != nil, cfg: cfg, timing: timing)
                self.lastError = nil
                self.finishProcessing()
            } catch {
                // Abandoned with Esc: the app has already moved on.
                guard !Task.isCancelled else { return }
                let short = AppController.shortError(error)
                Log.write("error: \(short) — \(error.localizedDescription)")
                self.lastError = (short, Date())
                self.playSound("Basso")
                self.finishProcessing()
                self.flashIcon(.failed)
            }
        }
    }

    /// Puts a take's text into the focused app — or, where there is nowhere
    /// to type, on the clipboard — and records it in the history.
    private func deliver(_ result: TakePlan.Result, replacingSelection: Bool, cfg: Config, timing: TakeTiming) {
        let text = result.text
        var toInsert = text
        let contextStarted = Date()
        // Replacing a selection: the text takes the selection's exact place.
        if cfg.smartSpacing, !replacingSelection, let context = FocusedText.current() {
            toInsert = context.adjust(text, knownTerms: Set(vocabulary.entries.map(\.term)))
            if toInsert != text { Log.write("smart spacing: adjusted for the caret context") }
        }
        let (target, role) = FocusedText.pasteTarget()
        timing.add("context", since: contextStarted)
        let pasteStarted = Date()
        switch target {
        case .editable:
            Paster.deliver(toInsert, mode: cfg.pasteMode, restoreClipboard: cfg.restoreClipboard)
        case .unknown:
            // Probably a text view we can't read; paste, but keep the
            // result on the clipboard in case nothing took it.
            Paster.deliver(toInsert, mode: cfg.pasteMode, restoreClipboard: false)
            Log.write("paste target \(role) is ambiguous — result left on the clipboard as well")
        case .nonEditable:
            // A web page, PDF, file list…: nowhere to type. Hand the
            // result over via the clipboard instead of losing it.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            flashIcon(.copied, for: 2.5)
            Log.write("nowhere to paste (focus: \(role)) — result copied to the clipboard")
        }
        timing.add("paste", since: pasteStarted)
        Log.write(String(format: "take: key released → delivered in %.2fs (tail %.0f · %@)",
                         Date().timeIntervalSince(timing.released), cfg.releaseTailMs, timing.summary))
        history.add(text, kind: result.kind, source: result.original)
    }

    private func finishProcessing() {
        takeTask = nil
        sttTask = nil
        processingSince = nil
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
        Paster.deliver(entry.text, mode: config.pasteMode, restoreClipboard: config.restoreClipboard)
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
            try await localSTT.transcribe(pcm16: take.pcm, language: cfg.language)
        }

        if cfg.usesLocalEngine {
            if !localSTT.isModelDownloaded, cfg.sttFallback, hasKey, await probe.reachable() {
                Log.write("STT: local model not downloaded yet → Groq for this take, model downloading in background")
                localSTT.warmUpInBackground()
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

    /// Chat routing for every `TakePlan.Request`. The configured
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
        if Task.isCancelled { return nil }
        if LocalLLM.isAvailable {
            do {
                Log.write("chat: using Apple on-device model")
                return try await LocalLLM.respond(system: system, user: query)
            } catch {
                Log.write("chat: local model failed: \(error.localizedDescription)")
            }
        }
        // The probe may have been a transient false negative — try anyway.
        if configured && !reachable && !Task.isCancelled {
            do {
                return try await groq.chat(userText: query, systemPrompt: system, temperature: temperature)
            } catch {
                Log.write("chat: \(cfg.chatHost) last-resort failed (\(error.localizedDescription.prefix(120)))")
            }
        }
        return nil
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

    @objc func menuShowSettings() { showSettings() }
    @objc func menuShowHistory() { showHistory() }
    @objc func menuShowDictionary() { showDictionary(.vocabulary) }
    @objc func menuShowSnippets() { showDictionary(.snippets) }

    @discardableResult
    func showSettings() -> SettingsWindowController {
        let controller = settingsWindow ?? SettingsWindowController(app: self)
        settingsWindow = controller
        controller.show()
        return controller
    }

    @discardableResult
    func showHistory() -> HistoryWindowController {
        let controller = historyWindow ?? HistoryWindowController(app: self)
        historyWindow = controller
        controller.show()
        return controller
    }

    @discardableResult
    func showDictionary(_ tab: DictionaryWindowController.Tab? = nil) -> DictionaryWindowController {
        let controller = dictionaryWindow ?? DictionaryWindowController(app: self)
        dictionaryWindow = controller
        controller.show(tab)
        return controller
    }

    @objc func menuQuickAddTerm() { QuickVocabularyAdd.run(app: self) }

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
        var state = state
        if state == .ready, hotkeyStatus != .active { state = .inactive }
        let (symbol, tint): (String, NSColor?) = {
            switch state {
            case .inactive: return ("mic.slash", .systemGray)
            case .ready: return ("mic", nil)
            case .recording: return ("mic.fill", .systemRed)
            case .translating: return ("mic.fill", .systemBlue)
            case .custom: return ("mic.fill", .systemIndigo)
            case .editing: return ("mic.fill", .systemPurple)
            case .locked: return ("mic.fill", .systemOrange)
            case .processing: return ("hourglass", .systemYellow)
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
        settingsWindow?.refreshIfVisible()
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
}
