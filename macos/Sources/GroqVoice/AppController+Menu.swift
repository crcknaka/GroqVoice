import Cocoa
import ServiceManagement

/// Status-bar menu. Rebuilt every time it opens (NSMenuDelegate), so device
/// lists, history and checkmarks are always current without bookkeeping.
///
/// Layout, top to bottom: what the hotkey does · Recent · which engine is
/// active and its own settings (the other engine's group is greyed out) ·
/// the LLM add-ons · settings shared by both engines · files · quit.
extension AppController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.autoenablesItems = false
        menu.removeAllItems()

        if hotkeyStatus == .active {
            menu.addItem(status("Hold \(config.hotkeyKey.title) to talk · double-tap to lock"))
        } else {
            menu.addItem(status("Hotkey inactive — permission missing"))
            let fix = item(hotkeyStatus == .needsInputMonitoring
                               ? "Enable Input Monitoring for GroqVoice…"
                               : "Enable Accessibility for GroqVoice…", #selector(openPermissionSettings))
            fix.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(fix)
            menu.addItem(item("Relaunch GroqVoice (after granting)", #selector(relaunch)))
        }
        menu.addItem(recentMenuItem())
        menu.addItem(.separator())

        let parakeetActive = config.usesLocalEngine
        menu.addItem(engineMenuItem())
        let parakeet = parakeetMenuItem()
        parakeet.isEnabled = parakeetActive
        menu.addItem(parakeet)
        let whisper = groqWhisperMenuItem()
        whisper.isEnabled = !parakeetActive
        menu.addItem(whisper)
        menu.addItem(llmMenuItem())
        menu.addItem(.separator())

        menu.addItem(hotkeyMenuItem())
        menu.addItem(microphoneMenuItem())
        menu.addItem(languageMenuItem())
        menu.addItem(.separator())

        menu.addItem(check("Sound Feedback", #selector(menuToggleSounds), config.playFeedbackSounds))
        menu.addItem(check("Type Instead of Paste", #selector(menuTogglePasteMode), config.pasteModeValue == .type))
        menu.addItem(check("Launch at Login", #selector(menuToggleLogin), SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())

        menu.addItem(item("Open Config File", #selector(menuOpenConfig)))
        menu.addItem(item("Open Log", #selector(menuOpenLog)))
        menu.addItem(item(screenRecorder.isRecording ? "Stop Screen Recording  (⌃⌥⌘R)" : "Record Screen  (⌃⌥⌘R)",
                          #selector(toggleScreenRecording)))
        menu.addItem(.separator())
        menu.addItem(item("Quit GroqVoice", #selector(menuQuit), key: "q"))
    }

    // MARK: - Recent

    private func recentMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let sub = submenu()
        let entries = Array(history.entries.suffix(10).reversed())
        if entries.isEmpty {
            sub.addItem(status("Nothing dictated yet"))
        } else {
            sub.addItem(status("Click to copy"))
            for entry in entries {
                let row = item(entry.menuTitle, #selector(menuCopyRecent(_:)))
                row.representedObject = entry.text
                if entry.kind == "task" {
                    row.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
                }
                sub.addItem(row)
            }
            sub.addItem(.separator())
            sub.addItem(item("Clear History", #selector(menuClearHistory)))
        }
        root.submenu = sub
        return root
    }

    // MARK: - Engine groups

    private func engineMenuItem() -> NSMenuItem {
        let current = config.usesLocalEngine ? "Parakeet v3 (on this Mac)" : "Whisper via Groq (cloud)"
        let root = NSMenuItem(title: "Engine: \(current)", action: nil, keyEquivalent: "")
        let sub = submenu()
        sub.addItem(status("Speech recognition runs with:"))
        for (title, engine) in [("Parakeet v3 — on this Mac, no account needed", "parakeet"),
                                ("Whisper via Groq — cloud, needs an API key", "groq")] {
            let row = item(title, #selector(menuSetEngine(_:)))
            row.representedObject = engine
            row.state = config.sttEngine == engine ? .on : .off
            sub.addItem(row)
        }
        root.submenu = sub
        return root
    }

    private func parakeetMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Parakeet Settings", action: nil, keyEquivalent: "")
        let sub = submenu()

        if let text = localModelStatus {
            sub.addItem(status("Model: \(text)"))
        } else if localSTT.isModelDownloaded {
            sub.addItem(status(localSTT.isLoaded ? "Model: ready, warm in memory" : "Model: ready, loads on first use"))
        } else {
            sub.addItem(status("Model: not downloaded"))
            sub.addItem(item("Download Model (~\(LocalSTT.approximateDownloadMB) MB)…", #selector(menuDownloadModel)))
        }

        let terms = vocabulary.termCount
        let aliases = vocabulary.entries.reduce(0) { $0 + $1.aliases.count }
        sub.addItem(status(terms == 0 ? "Vocabulary: empty" : "Vocabulary: \(terms) terms, \(aliases) aliases (replaced in text)"))
        sub.addItem(item("Edit Vocabulary…", #selector(menuOpenVocabulary)))
        sub.addItem(check("Acoustic Term Spotting (experimental)", #selector(menuToggleBoosting), config.vocabularyBoosting))
        if config.vocabularyBoosting {
            if localSTT.isBoostingReady {
                sub.addItem(status("   helper model loaded, ~0.1 s per phrase"))
            } else if localSTT.isCtcModelDownloaded {
                sub.addItem(status("   helper model loads on first use"))
            } else {
                sub.addItem(status("   downloads a ~\(LocalSTT.approximateCtcDownloadMB) MB helper model on first use"))
            }
        }
        sub.addItem(.separator())

        let fallback = check("Fall Back to Groq Whisper if Parakeet Fails", #selector(menuToggleFallback), config.sttFallback)
        sub.addItem(fallback)
        if config.sttFallback && config.groqApiKey.isEmpty {
            sub.addItem(status("   (inactive: no Groq API key)"))
        }
        root.submenu = sub
        return root
    }

    private func groqWhisperMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Groq Whisper Settings", action: nil, keyEquivalent: "")
        let sub = submenu()
        sub.addItem(status(config.groqApiKey.isEmpty ? "API key: not set" : "API key: set"))
        sub.addItem(item(config.groqApiKey.isEmpty ? "Set Groq API Key…" : "Change Groq API Key…", #selector(menuSetApiKey)))
        sub.addItem(.separator())
        sub.addItem(check("Fall Back to Parakeet When Offline or Rate-Limited", #selector(menuToggleFallback), config.sttFallback))
        sub.addItem(.separator())
        sub.addItem(status("Models: " + config.transcriptionModels.joined(separator: " → ")))
        sub.addItem(status("Vocabulary terms are sent as the Whisper prompt"))
        root.submenu = sub
        return root
    }

    private func llmMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Groq LLM: Task Mode & Clean-Up", action: nil, keyEquivalent: "")
        let sub = submenu()
        let backend: String
        if !config.groqApiKey.isEmpty {
            backend = "Backend: Groq (API key set)"
        } else if LocalLLM.isAvailable {
            backend = "Backend: Apple Intelligence (no Groq key)"
        } else {
            backend = "Backend: none — set a Groq API key to enable"
        }
        sub.addItem(status(backend))
        sub.addItem(item(config.groqApiKey.isEmpty ? "Set Groq API Key…" : "Change Groq API Key…", #selector(menuSetApiKey)))
        sub.addItem(.separator())
        sub.addItem(check("Clean Up Transcript (punctuation, fillers, spellings)", #selector(menuToggleCleanup), config.cleanupTranscript))
        sub.addItem(status("Task mode: start with «\(config.taskKeywords.first ?? "task") …» to get an answer instead of text"))
        sub.addItem(item("Edit Snippets…", #selector(menuOpenSnippets)))
        sub.addItem(.separator())
        sub.addItem(status("Models: " + config.chatModels.joined(separator: " → ")))
        root.submenu = sub
        return root
    }

    // MARK: - Shared settings

    private func hotkeyMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Hotkey: \(config.hotkeyKey.title)", action: nil, keyEquivalent: "")
        let sub = submenu()
        for key in HotkeyKey.allCases {
            let row = item(key.title, #selector(menuSetHotkey(_:)))
            row.representedObject = key.rawValue
            row.state = config.hotkeyKey == key ? .on : .off
            sub.addItem(row)
        }
        root.submenu = sub
        return root
    }

    private func microphoneMenuItem() -> NSMenuItem {
        let devices = AudioDevices.inputDevices()
        let defaultName = AudioDevices.defaultInputDeviceID().map(AudioDevices.name(of:))
        let currentName = config.inputDeviceUID.isEmpty
            ? "System Default"
            : (devices.first { $0.uid == config.inputDeviceUID }?.name ?? "not connected")
        let root = NSMenuItem(title: "Microphone: \(currentName)", action: nil, keyEquivalent: "")
        let sub = submenu()

        let def = item("System Default" + (defaultName.map { " (\($0))" } ?? ""), #selector(menuSetMicrophone(_:)))
        def.representedObject = ""
        def.state = config.inputDeviceUID.isEmpty ? .on : .off
        sub.addItem(def)
        sub.addItem(.separator())
        for device in devices {
            let row = item(device.name, #selector(menuSetMicrophone(_:)))
            row.representedObject = device.uid
            row.state = config.inputDeviceUID == device.uid ? .on : .off
            sub.addItem(row)
        }
        if !config.inputDeviceUID.isEmpty && !devices.contains(where: { $0.uid == config.inputDeviceUID }) {
            sub.addItem(status("Selected microphone not connected — using default"))
        }
        root.submenu = sub
        return root
    }

    private static let languages: [(String, String)] = [
        ("Auto-detect", ""), ("Русский", "ru"), ("English", "en"),
        ("Latviešu", "lv"), ("Українська", "uk"), ("Deutsch", "de"),
        ("Español", "es"), ("Français", "fr"), ("Italiano", "it"), ("Polski", "pl"),
    ]

    private func languageMenuItem() -> NSMenuItem {
        let currentTitle = AppController.languages.first { $0.1 == config.language }?.0 ?? config.language
        let root = NSMenuItem(title: "Language: \(currentTitle)", action: nil, keyEquivalent: "")
        let sub = submenu()
        sub.addItem(status(config.usesLocalEngine
                               ? "Parakeet: Auto keeps mixed RU/EN; a fixed language only filters the alphabet"
                               : "Whisper: Auto detects per phrase; fixed language forces it"))
        for (title, code) in AppController.languages {
            let row = item(title, #selector(menuSetLanguage(_:)))
            row.representedObject = code
            row.state = config.language == code ? .on : .off
            sub.addItem(row)
        }
        root.submenu = sub
        return root
    }

    // MARK: - Item helpers

    private func submenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        return m
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        it.isEnabled = true
        return it
    }

    private func check(_ title: String, _ action: Selector, _ on: Bool) -> NSMenuItem {
        let it = item(title, action)
        it.state = on ? .on : .off
        return it
    }

    /// Greyed-out informational row.
    private func status(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    // MARK: - Actions

    @objc func menuSetEngine(_ sender: NSMenuItem) {
        guard let engine = sender.representedObject as? String else { return }
        config.sttEngine = engine
        config.save()
        Log.write("engine → \(engine)")
        if config.usesLocalEngine {
            localSTT.warmUpInBackground(vocabularyFile: config.vocabularyBoosting ? Vocabulary.fileURL : nil)
        } else if config.groqApiKey.isEmpty {
            promptForApiKey()
        }
    }

    @objc func menuToggleFallback() {
        config.sttFallback.toggle()
        config.save()
        Log.write("engine fallback → \(config.sttFallback)")
    }

    @objc func menuToggleBoosting() {
        config.vocabularyBoosting.toggle()
        config.save()
        Log.write("vocabulary boosting → \(config.vocabularyBoosting)")
        if config.vocabularyBoosting {
            localSTT.warmUpInBackground(vocabularyFile: Vocabulary.fileURL)
        }
    }

    @objc func menuDownloadModel() {
        Log.write("local model download requested from menu")
        localSTT.warmUpInBackground(vocabularyFile: config.vocabularyBoosting ? Vocabulary.fileURL : nil)
    }

    @objc func menuSetHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = HotkeyKey(rawValue: raw) else { return }
        if case .recording = phase { recorder.discard(); phase = .idle; setIcon(.ready) }
        config.hotkey = key.rawValue
        config.save()
        hotkey.key = key
        Log.write("hotkey → \(key.rawValue)")
        if let caveat = key.caveat {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "\(key.title) is now the push-to-talk key"
            alert.informativeText = caveat
            alert.runModal()
        }
    }

    @objc func menuSetMicrophone(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        config.inputDeviceUID = uid
        config.save()
        Log.write("microphone → \(uid.isEmpty ? "system default" : sender.title)")
        prepareRecorder()
    }

    @objc func menuSetLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        config.language = code
        config.save()
        Log.write("language → \(code.isEmpty ? "auto" : code)")
    }

    @objc func menuToggleSounds() {
        config.playFeedbackSounds.toggle()
        config.save()
        Log.write("sound feedback → \(config.playFeedbackSounds)")
        if config.playFeedbackSounds { NSSound(named: "Pop")?.play() }
    }

    @objc func menuToggleCleanup() {
        config.cleanupTranscript.toggle()
        config.save()
        if config.cleanupTranscript && config.groqApiKey.isEmpty && !LocalLLM.isAvailable {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Clean-up needs a language model"
            alert.informativeText = "Add a Groq API key (free at console.groq.com) or enable Apple Intelligence. Until then transcripts are pasted as recognized."
            alert.runModal()
        }
    }

    @objc func menuTogglePasteMode() {
        config.pasteMode = config.pasteModeValue == .type ? PasteMode.paste.rawValue : PasteMode.type.rawValue
        config.save()
        Log.write("paste mode → \(config.pasteMode)")
    }

    @objc func menuToggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                config.autostart = false
                Log.write("launch-at-login disabled")
            } else {
                try SMAppService.mainApp.register()
                config.autostart = true
                Log.write("launch-at-login enabled")
            }
            config.save()
        } catch {
            Log.write("launch-at-login toggle failed: \(error.localizedDescription)")
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Launch at Login failed"
            alert.informativeText = "macOS rejected the Login Item change: \(error.localizedDescription)\n\nMake sure GroqVoice.app is in /Applications, or toggle it in System Settings → General → Login Items."
            alert.runModal()
        }
    }

    @objc func menuCopyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        flashIcon(.copied, for: 1.2)
    }

    @objc func menuClearHistory() {
        history.clear()
    }

    @objc func menuSetApiKey() { promptForApiKey() }

    @objc func menuOpenConfig() { NSWorkspace.shared.open(Config.fileURL) }
    @objc func menuOpenVocabulary() { NSWorkspace.shared.open(Vocabulary.fileURL) }
    @objc func menuOpenSnippets() { NSWorkspace.shared.open(Snippets.fileURL) }
    @objc func menuOpenLog() { NSWorkspace.shared.open(Log.fileURL) }
    @objc func menuQuit() { NSApp.terminate(nil) }

    func promptForApiKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Groq API Key"
        alert.informativeText = "Optional: used for the cloud Whisper engine, for task mode (\"задание: …\") and for transcript clean-up. Free at console.groq.com. Stored only in this Mac's config.json."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "gsk_…"
        field.stringValue = config.groqApiKey
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            config.groqApiKey = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            config.save()
            groq.apiKey = config.groqApiKey
            Log.write("API key updated (\(config.groqApiKey.isEmpty ? "empty" : "set"))")
        }
    }
}
