import Cocoa

/// Retains a closure so plain AppKit controls can call back without a
/// selector per control.
final class ActionTarget: NSObject {
    private let handler: (Any?) -> Void
    init(_ handler: @escaping (Any?) -> Void) { self.handler = handler }
    @objc func fire(_ sender: Any?) { handler(sender) }
}

/// The application's main menu. Never shown (the app has no Dock presence)
/// but it is what routes ⌘C/⌘V/⌘A inside text fields and ⌘W/⌘, on windows.
enum MainMenu {
    static func build(app: AppController) -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        let settings = NSMenuItem(title: "Settings…", action: #selector(AppController.menuShowSettings), keyEquivalent: ",")
        settings.target = app
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit GroqVoice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        windowItem.submenu = window
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        return main
    }
}

/// Preferences window. Every control writes straight into `app.config` and
/// calls `settingsChanged()` — no OK/Cancel. Three tabs: General (keys, mic,
/// pasting, timing), Recognition (engine + the active engine's settings; the
/// other engine's group is greyed out), Groq & LLM (API key, endpoint, task
/// mode, clean-up).
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private unowned let app: AppController
    private var targets: [ActionTarget] = []
    private let tabs = NSTabView()
    private var refreshing = false

    // General
    private let hotkeyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let translateKeyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let translateLangPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let micPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let pastePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let restoreClipboardCheck = NSButton(checkboxWithTitle: "Restore the clipboard after pasting", target: nil, action: nil)
    private let soundsCheck = NSButton(checkboxWithTitle: "Sound feedback (start, stop, error)", target: nil, action: nil)
    private let loginCheck = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let saveWavCheck = NSButton(checkboxWithTitle: "Keep the last recording (last.wav) for debugging", target: nil, action: nil)
    private let smartSpacingCheck = NSButton(checkboxWithTitle: "Smart spacing and case when inserting mid-sentence", target: nil, action: nil)
    private let spokenFormattingCheck = NSButton(checkboxWithTitle: "“Новая строка” / “абзац” / “new line” insert line breaks", target: nil, action: nil)
    private let builtInMicCheck = NSButton(checkboxWithTitle: "Prefer the built-in microphone over Bluetooth headsets", target: nil, action: nil)
    private let holdField = NSTextField()
    private let doubleTapField = NSTextField()
    private let tailField = NSTextField()
    private let minTakeField = NSTextField()
    private let silenceField = NSTextField()
    private let historyField = NSTextField()
    private let languageHint = NSTextField(wrappingLabelWithString: "")

    // Recognition
    private let parakeetRadio = NSButton(radioButtonWithTitle: "Parakeet v3 — on this Mac, no account needed", target: nil, action: nil)
    private let groqRadio = NSButton(radioButtonWithTitle: "Whisper via Groq — cloud, needs an API key", target: nil, action: nil)
    private let fallbackCheck = NSButton(checkboxWithTitle: "Fall back to the other engine when this one can't", target: nil, action: nil)
    private let modelStatusLabel = NSTextField(labelWithString: "")
    private let downloadButton = NSButton(title: "Download Model…", target: nil, action: nil)
    private let vocabLabel = NSTextField(labelWithString: "")
    private let editVocabButton = NSButton(title: "Edit Vocabulary…", target: nil, action: nil)
    private let boostingCheck = NSButton(checkboxWithTitle: "Acoustic term spotting (experimental)", target: nil, action: nil)
    private let unloadField = NSTextField()
    private let parakeetBox = NSBox()
    private let groqKeyStatus = NSTextField(labelWithString: "")
    private let sttModelsField = NSTextField()
    private let groqBox = NSBox()

    // Groq & LLM
    private let apiKeyField = NSSecureTextField()
    private let endpointPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let baseURLField = NSTextField()
    private let chatKeyField = NSSecureTextField()
    private let chatModelsField = NSTextField()
    private let llmStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let cleanupCheck = NSButton(checkboxWithTitle: "Clean up dictation with the LLM", target: nil, action: nil)
    private let editSelectionCheck = NSButton(checkboxWithTitle: "Voice-edit selected text", target: nil, action: nil)
    private let keywordsField = NSTextField()
    private let keywordPosField = NSTextField()
    private let promptView = NSTextView()

    init(app: AppController) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "GroqVoice Settings"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(tab: Int? = nil) {
        refresh()
        if let tab { tabs.selectTabViewItem(at: tab) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func selectTab(_ index: Int) { tabs.selectTabViewItem(at: index) }

    func refreshIfVisible() {
        if window?.isVisible == true { refresh() }
    }

    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)  // commit any text field being edited
        savePrompt()
    }

    // MARK: - Building

    private func buildUI() {
        guard let content = window?.contentView else { return }
        tabs.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabs)
        NSLayoutConstraint.activate([
            // Fixed size: tab contents must fit, the window never grows to them.
            content.widthAnchor.constraint(equalToConstant: 640),
            content.heightAnchor.constraint(equalToConstant: 800),
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        addTab("General", buildGeneral())
        addTab("Recognition", buildRecognition())
        addTab("Groq & LLM", buildLLM())
    }

    private func addTab(_ title: String, _ stack: NSStackView) {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
        ])
        item.view = container
        tabs.addTabViewItem(item)
    }

    private func buildGeneral() -> NSStackView {
        hotkeyPopup.addItems(withTitles: HotkeyKey.allCases.map(\.title))
        bind(hotkeyPopup) { [unowned self] _ in
            self.app.config.hotkey = HotkeyKey.allCases[self.hotkeyPopup.indexOfSelectedItem].rawValue
            if self.app.config.translateHotkey == self.app.config.hotkey { self.app.config.translateHotkey = "" }
            self.commit()
        }
        translateKeyPopup.addItems(withTitles: ["Off"] + HotkeyKey.allCases.map(\.title))
        bind(translateKeyPopup) { [unowned self] _ in
            let i = self.translateKeyPopup.indexOfSelectedItem
            self.app.config.translateHotkey = i == 0 ? "" : HotkeyKey.allCases[i - 1].rawValue
            self.commit()
        }
        translateLangPopup.addItems(withTitles: Config.translateLanguages.map(\.name))
        bind(translateLangPopup) { [unowned self] _ in
            self.app.config.translateLanguage = Config.translateLanguages[self.translateLangPopup.indexOfSelectedItem].code
            self.commit()
        }
        bind(micPopup) { [unowned self] _ in
            self.app.config.inputDeviceUID = (self.micPopup.selectedItem?.representedObject as? String) ?? ""
            self.commit()
        }
        languagePopup.addItems(withTitles: Config.recognitionLanguages.map(\.name))
        bind(languagePopup) { [unowned self] _ in
            self.app.config.language = Config.recognitionLanguages[self.languagePopup.indexOfSelectedItem].code
            self.commit()
        }
        pastePopup.addItems(withTitles: ["Paste with ⌘V (fast)", "Type keystrokes (remote desktops, odd apps)"])
        bind(pastePopup) { [unowned self] _ in
            self.app.config.pasteMode = self.pastePopup.indexOfSelectedItem == 1 ? PasteMode.type.rawValue : PasteMode.paste.rawValue
            self.commit()
        }
        bindCheck(restoreClipboardCheck) { [unowned self] on in self.app.config.restoreClipboard = on }
        bindCheck(soundsCheck) { [unowned self] on in self.app.config.playFeedbackSounds = on }
        bindCheck(loginCheck) { [unowned self] on in self.app.config.autostart = on }
        bindCheck(saveWavCheck) { [unowned self] on in self.app.config.saveLastWav = on }
        bindCheck(smartSpacingCheck) { [unowned self] on in self.app.config.smartSpacing = on }
        bindCheck(spokenFormattingCheck) { [unowned self] on in self.app.config.spokenFormatting = on }
        bindCheck(builtInMicCheck) { [unowned self] on in self.app.config.preferBuiltInMic = on }

        bindNumber(holdField, min: 50, max: 2000) { [unowned self] v in self.app.config.pttHoldMs = v }
        bindNumber(doubleTapField, min: 100, max: 2000) { [unowned self] v in self.app.config.doubleTapWindowMs = v }
        bindNumber(tailField, min: 0, max: 2000) { [unowned self] v in self.app.config.releaseTailMs = v }
        bindNumber(minTakeField, min: 0, max: 10, decimals: 2) { [unowned self] v in self.app.config.minRecordingSeconds = v }
        bindNumber(silenceField, min: 0, max: 100, decimals: 2) { [unowned self] v in self.app.config.silencePeakPercent = v }
        bindNumber(historyField, min: 1, max: 1000) { [unowned self] v in self.app.config.historySize = Int(v) }

        languageHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        languageHint.textColor = .secondaryLabelColor
        languageHint.preferredMaxLayoutWidth = 420

        let keysGrid = grid([
            [label("Push-to-talk key:"), hotkeyPopup],
            [empty(), hint("Hold to record, release to paste. Double-tap locks the recording; the next tap stops it.")],
            [label("Translate key:"), row(translateKeyPopup, label("into"), translateLangPopup)],
            [empty(), hint("A second key: speak in any language, the translation is pasted. Needs a language model (Groq & LLM tab).")],
            [label("Microphone:"), micPopup],
            [empty(), builtInMicCheck],
            [label("Language:"), languagePopup],
            [empty(), languageHint],
        ])
        let pasteGrid = grid([
            [label("Insert text by:"), pastePopup],
            [empty(), smartSpacingCheck],
            [empty(), spokenFormattingCheck],
            [empty(), restoreClipboardCheck],
            [empty(), soundsCheck],
            [empty(), loginCheck],
            [empty(), saveWavCheck],
        ])
        let timingGrid = grid([
            [label("Hold threshold:"), row(holdField, unit("ms"), hint("shorter presses count as taps"))],
            [label("Double-tap window:"), row(doubleTapField, unit("ms"))],
            [label("Release tail:"), row(tailField, unit("ms"), hint("keep recording after the key is released"))],
            [label("Minimum take:"), row(minTakeField, unit("s"), hint("shorter takes are dropped as accidental"))],
            [label("Silence threshold:"), row(silenceField, unit("%"), hint("takes with a lower peak are dropped"))],
            [label("History size:"), row(historyField, unit("entries"))],
        ])
        let openLog = button("Open Log") { NSWorkspace.shared.open(Log.fileURL) }
        let openFolder = button("Open Data Folder") { NSWorkspace.shared.open(Config.supportDir) }
        let reset = button("Reset to Defaults…") { [unowned self] in self.resetToDefaults() }
        let buttons = NSStackView(views: [openLog, openFolder, reset])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        return column([keysGrid, box("Pasting", pasteGrid), box("Timing", timingGrid), buttons])
    }

    private func buildRecognition() -> NSStackView {
        let engineTarget = ActionTarget { [unowned self] sender in
            self.app.config.sttEngine = (sender as? NSButton) === self.groqRadio ? "groq" : "parakeet"
            self.commit()
        }
        targets.append(engineTarget)
        for radio in [parakeetRadio, groqRadio] {
            radio.target = engineTarget
            radio.action = #selector(ActionTarget.fire(_:))
        }
        bindCheck(fallbackCheck) { [unowned self] on in self.app.config.sttFallback = on }

        bindButton(downloadButton) { [unowned self] in
            self.app.localSTT.warmUpInBackground(vocabularyFile: self.app.config.vocabularyBoosting ? Vocabulary.fileURL : nil)
            self.refresh()
        }
        bindButton(editVocabButton) { NSWorkspace.shared.open(Vocabulary.fileURL) }
        bindCheck(boostingCheck) { [unowned self] on in self.app.config.vocabularyBoosting = on }
        bindNumber(unloadField, min: 0, max: 1440) { [unowned self] v in self.app.config.localUnloadAfterMinutes = v }
        bindText(sttModelsField) { [unowned self] text in
            let models = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !models.isEmpty { self.app.config.transcriptionModels = models }
        }

        let engineGrid = grid([
            [label("Engine:"), parakeetRadio],
            [empty(), groqRadio],
            [empty(), fallbackCheck],
        ])

        let parakeetGrid = grid([
            [label("Model:"), row(modelStatusLabel, downloadButton)],
            [label("Vocabulary:"), row(vocabLabel, editVocabButton)],
            [empty(), hint("One entry per line: Term: alias, alias. Aliases are replaced by the term in the text — write what the recognizer actually produces.")],
            [empty(), boostingCheck],
            [empty(), hint("Spots the terms in the audio with a second (English) model, ~106 MB. Off by default: with big vocabularies and Russian speech it makes false replacements.")],
            [label("Unload model after:"), row(unloadField, unit("min"), hint("0 = keep it warm in memory"))],
        ])
        configureBox(parakeetBox, title: "Parakeet v3 (on this Mac)", content: parakeetGrid)

        let groqGrid = grid([
            [label("API key:"), groqKeyStatus],
            [label("Models:"), sttModelsField],
            [empty(), hint("Priority order, comma-separated. On a rate limit the next model is used; the vocabulary terms are sent as the Whisper prompt.")],
        ])
        configureBox(groqBox, title: "Whisper via Groq (cloud)", content: groqGrid)

        return column([engineGrid, parakeetBox, groqBox])
    }

    private func buildLLM() -> NSStackView {
        bindText(apiKeyField) { [unowned self] text in self.app.config.groqApiKey = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let getKey = button("Get a key…") { NSWorkspace.shared.open(URL(string: "https://console.groq.com/keys")!) }

        endpointPopup.addItems(withTitles: ["Groq (default)", "Custom OpenAI-compatible server (Ollama, LM Studio, OpenAI, …)"])
        bind(endpointPopup) { [unowned self] _ in
            if self.endpointPopup.indexOfSelectedItem == 0 {
                self.app.config.chatBaseURL = Config.groqBaseURL
            } else if self.app.config.usesGroqForChat {
                self.app.config.chatBaseURL = "http://localhost:11434/v1"
            }
            self.commit()
        }
        bindText(baseURLField) { [unowned self] text in
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.app.config.chatBaseURL = t.isEmpty ? Config.groqBaseURL : t
        }
        bindText(chatKeyField) { [unowned self] text in self.app.config.chatApiKey = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        bindText(chatModelsField) { [unowned self] text in
            let models = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !models.isEmpty { self.app.config.chatModels = models }
        }
        bindCheck(cleanupCheck) { [unowned self] on in self.app.config.cleanupTranscript = on }
        bindCheck(editSelectionCheck) { [unowned self] on in self.app.config.editSelection = on }
        bindText(keywordsField, width: 190) { [unowned self] text in
            let words = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !words.isEmpty { self.app.config.taskKeywords = words }
        }
        bindNumber(keywordPosField, min: 1, max: 10) { [unowned self] v in self.app.config.taskKeywordMaxWordPosition = Int(v) }

        llmStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        llmStatusLabel.textColor = .secondaryLabelColor
        llmStatusLabel.preferredMaxLayoutWidth = 420

        promptView.isRichText = false
        promptView.font = .systemFont(ofSize: 12)
        promptView.isAutomaticQuoteSubstitutionEnabled = false
        promptView.delegate = self
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = promptView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 400).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 72).isActive = true
        promptView.minSize = NSSize(width: 0, height: 72)
        promptView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        promptView.isVerticallyResizable = true
        promptView.isHorizontallyResizable = false
        promptView.autoresizingMask = [.width]
        promptView.textContainer?.widthTracksTextView = true

        let editSnippets = button("Edit Snippets…") { NSWorkspace.shared.open(Snippets.fileURL) }

        let accountGrid = grid([
            [label("Groq API key:"), row(apiKeyField, getKey)],
            [empty(), hint("Used by the cloud Whisper engine and — unless a custom endpoint is set — by translation, task mode and clean-up. Free tier is plenty.")],
            [label("Chat endpoint:"), endpointPopup],
            [label("Base URL:"), baseURLField],
            [label("Endpoint key:"), chatKeyField],
            [empty(), hint("Ollama on this Mac: http://localhost:11434/v1, no key, models like qwen3:8b. Any OpenAI-compatible server works.")],
            [label("Models:"), chatModelsField],
            [empty(), hint("Priority order, comma-separated; on a rate limit the next one is tried.")],
            [empty(), llmStatusLabel],
        ])
        let featuresGrid = grid([
            [empty(), editSelectionCheck],
            [empty(), hint("Select text anywhere, hold the dictation key and say what to do with it — “сделай короче”, “переведи на латышский”, “исправь ошибки”. The result replaces the selection. Plain dictation with a selection still replaces it.")],
            [empty(), cleanupCheck],
            [empty(), hint("Punctuation, filler words and vocabulary spellings; wording is kept. Off = paste exactly what was recognized.")],
            [label("Task keywords:"), row(keywordsField, label("within the first"), keywordPosField, unit("words"))],
            [empty(), hint("Say “задание: переведи …” or “task: write a regex …” and the model's answer is pasted instead of the words.")],
            [label("Task prompt:"), scroll],
            [empty(), row(hint("Empty = built-in prompt."), editSnippets)],
        ])
        return column([box("Language model", accountGrid), box("Features", featuresGrid)])
    }

    // MARK: - Refresh (config → controls)

    func refresh() {
        refreshing = true
        defer { refreshing = false }
        let c = app.config

        hotkeyPopup.selectItem(at: HotkeyKey.allCases.firstIndex(of: c.hotkeyKey) ?? 0)
        translateKeyPopup.selectItem(at: c.translateHotkeyKey.flatMap { HotkeyKey.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        for (i, key) in HotkeyKey.allCases.enumerated() {
            translateKeyPopup.item(at: i + 1)?.isEnabled = key != c.hotkeyKey
        }
        translateLangPopup.selectItem(at: Config.translateLanguages.firstIndex { $0.code == c.translateLanguage } ?? 0)
        translateLangPopup.isEnabled = c.translateHotkeyKey != nil

        micPopup.removeAllItems()
        let defaultName = AudioDevices.defaultInputDeviceID().map(AudioDevices.name(of:))
        micPopup.addItem(withTitle: "System Default" + (defaultName.map { " (\($0))" } ?? ""))
        micPopup.lastItem?.representedObject = ""
        var selectedMic = 0
        for device in AudioDevices.inputDevices() {
            micPopup.addItem(withTitle: device.name)
            micPopup.lastItem?.representedObject = device.uid
            if device.uid == c.inputDeviceUID { selectedMic = micPopup.numberOfItems - 1 }
        }
        if !c.inputDeviceUID.isEmpty && selectedMic == 0 {
            micPopup.addItem(withTitle: "Selected microphone (not connected)")
            micPopup.lastItem?.representedObject = c.inputDeviceUID
            selectedMic = micPopup.numberOfItems - 1
        }
        micPopup.selectItem(at: selectedMic)

        languagePopup.selectItem(at: Config.recognitionLanguages.firstIndex { $0.code == c.language } ?? 0)
        languageHint.stringValue = c.usesLocalEngine
            ? "Parakeet: Auto keeps mixed Russian/English; a fixed language only filters the alphabet (Cyrillic vs Latin)."
            : "Whisper: Auto detects the language per phrase; a fixed language forces it."
        pastePopup.selectItem(at: c.pasteModeValue == .type ? 1 : 0)
        restoreClipboardCheck.state = c.restoreClipboard ? .on : .off
        soundsCheck.state = c.playFeedbackSounds ? .on : .off
        loginCheck.state = c.autostart ? .on : .off
        saveWavCheck.state = c.saveLastWav ? .on : .off
        smartSpacingCheck.state = c.smartSpacing ? .on : .off
        spokenFormattingCheck.state = c.spokenFormatting ? .on : .off
        builtInMicCheck.state = c.preferBuiltInMic ? .on : .off
        holdField.stringValue = format(c.pttHoldMs)
        doubleTapField.stringValue = format(c.doubleTapWindowMs)
        tailField.stringValue = format(c.releaseTailMs)
        minTakeField.stringValue = format(c.minRecordingSeconds)
        silenceField.stringValue = format(c.silencePeakPercent)
        historyField.stringValue = "\(c.historySize)"

        parakeetRadio.state = c.usesLocalEngine ? .on : .off
        groqRadio.state = c.usesLocalEngine ? .off : .on
        fallbackCheck.state = c.sttFallback ? .on : .off
        if let text = app.localModelStatus {
            modelStatusLabel.stringValue = text
            downloadButton.isHidden = true
        } else if app.localSTT.isModelDownloaded {
            modelStatusLabel.stringValue = app.localSTT.isLoaded ? "ready, warm in memory" : "ready, loads on first use"
            downloadButton.isHidden = true
        } else {
            modelStatusLabel.stringValue = "not downloaded (~\(LocalSTT.approximateDownloadMB) MB)"
            downloadButton.isHidden = false
        }
        let terms = app.vocabulary.termCount
        let aliases = app.vocabulary.entries.reduce(0) { $0 + $1.aliases.count }
        vocabLabel.stringValue = terms == 0 ? "empty" : "\(terms) terms, \(aliases) aliases"
        boostingCheck.state = c.vocabularyBoosting ? .on : .off
        unloadField.stringValue = format(c.localUnloadAfterMinutes)
        groqKeyStatus.stringValue = c.groqApiKey.isEmpty ? "not set — see the Groq & LLM tab" : "set"
        sttModelsField.stringValue = c.transcriptionModels.joined(separator: ", ")
        setEnabled(parakeetBox, c.usesLocalEngine)
        setEnabled(groqBox, !c.usesLocalEngine)

        apiKeyField.stringValue = c.groqApiKey
        endpointPopup.selectItem(at: c.usesGroqForChat ? 0 : 1)
        baseURLField.stringValue = c.usesGroqForChat ? Config.groqBaseURL : c.chatBaseURL
        baseURLField.isEnabled = !c.usesGroqForChat
        chatKeyField.stringValue = c.chatApiKey
        chatKeyField.isEnabled = !c.usesGroqForChat
        chatModelsField.stringValue = c.chatModels.joined(separator: ", ")
        var backend: String
        if !c.usesGroqForChat {
            backend = "Backend: \(c.chatHost)" + (c.effectiveChatApiKey.isEmpty ? " (no key)" : "")
        } else if !c.groqApiKey.isEmpty {
            backend = "Backend: Groq"
        } else {
            backend = "Backend: none — translation, task mode and clean-up are inactive"
        }
        backend += ". Apple Intelligence on this Mac: \(LocalLLM.statusDescription) (used as a fallback when available)."
        llmStatusLabel.stringValue = backend
        cleanupCheck.state = c.cleanupTranscript ? .on : .off
        editSelectionCheck.state = c.editSelection ? .on : .off
        keywordsField.stringValue = c.taskKeywords.joined(separator: ", ")
        keywordPosField.stringValue = "\(c.taskKeywordMaxWordPosition)"
        if promptView.string != c.taskSystemPrompt { promptView.string = c.taskSystemPrompt }
    }

    // MARK: - Commit (controls → config)

    /// Saves, applies, and re-reads so dependent controls update.
    private func commit() {
        guard !refreshing else { return }
        app.settingsChanged()
        refresh()
    }

    func textDidEndEditing(_ notification: Notification) {
        savePrompt()
    }

    private func savePrompt() {
        let text = promptView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != app.config.taskSystemPrompt else { return }
        app.config.taskSystemPrompt = text
        app.settingsChanged()
    }

    private func resetToDefaults() {
        let alert = NSAlert()
        alert.messageText = "Reset all settings to defaults?"
        alert.informativeText = "The Groq API key is kept. Vocabulary, snippets and history are not touched."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var fresh = Config()
        fresh.groqApiKey = app.config.groqApiKey
        app.config = fresh
        app.settingsChanged()
        refresh()
        Log.write("settings reset to defaults")
    }

    // MARK: - Control helpers

    private func bind(_ control: NSControl, _ handler: @escaping (Any?) -> Void) {
        let target = ActionTarget(handler)
        targets.append(target)
        control.target = target
        control.action = #selector(ActionTarget.fire(_:))
    }

    private func bindCheck(_ check: NSButton, _ handler: @escaping (Bool) -> Void) {
        bind(check) { [unowned self] _ in
            handler(check.state == .on)
            self.commit()
        }
    }

    private func bindButton(_ button: NSButton, _ handler: @escaping () -> Void) {
        button.bezelStyle = .rounded
        bind(button) { _ in handler() }
    }

    private func button(_ title: String, _ handler: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        bindButton(b, handler)
        return b
    }

    private func bindText(_ field: NSTextField, width: CGFloat = 300, _ handler: @escaping (String) -> Void) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        bind(field) { [unowned self] _ in
            handler(field.stringValue)
            self.app.settingsChanged()
            self.refresh()
        }
    }

    private func bindNumber(_ field: NSTextField, min: Double, max: Double, decimals: Int = 0,
                            _ handler: @escaping (Double) -> Void) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 70).isActive = true
        field.alignment = .right
        (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        bind(field) { [unowned self] _ in
            let raw = field.stringValue.replacingOccurrences(of: ",", with: ".")
            guard let value = Double(raw) else { self.refresh(); return }
            handler(Swift.min(max, Swift.max(min, value)))
            self.app.settingsChanged()
            self.refresh()
        }
        _ = decimals
    }

    private func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    private func unit(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func empty() -> NSView { NSView() }

    private func hint(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 420
        return l
    }

    private func row(_ views: NSView...) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 8
        s.alignment = .firstBaseline
        return s
    }

    private func column(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 12
        return s
    }

    private func grid(_ rows: [[NSView]]) -> NSGridView {
        let g = NSGridView(views: rows)
        g.rowSpacing = 6
        g.columnSpacing = 10
        g.rowAlignment = .firstBaseline
        g.column(at: 0).xPlacement = .trailing
        g.column(at: 0).width = 130
        return g
    }

    private func box(_ title: String, _ content: NSView) -> NSBox {
        let b = NSBox()
        configureBox(b, title: title, content: content)
        return b
    }

    private func configureBox(_ box: NSBox, title: String, content: NSView) {
        box.title = title
        box.titlePosition = .atTop
        box.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(content)
        if let cv = box.contentView {
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: cv.topAnchor, constant: 10),
                content.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 10),
                content.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -10),
                content.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -10),
            ])
        }
    }

    private func setEnabled(_ view: NSView, _ on: Bool) {
        if let control = view as? NSControl { control.isEnabled = on }
        if let text = view as? NSTextField, !(view is NSSecureTextField) { text.textColor = on ? .labelColor : .disabledControlTextColor }
        for sub in view.subviews { setEnabled(sub, on) }
        if let box = view as? NSBox { box.contentView.map { setEnabled($0, on) } }
    }
}
