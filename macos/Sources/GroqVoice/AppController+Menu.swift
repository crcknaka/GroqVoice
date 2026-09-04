import Cocoa

/// Status-bar menu: what the hotkeys do, recent dictations, quick switches
/// for the things you change while working (engine, key, microphone,
/// language, sounds). Everything else lives in Settings. Rebuilt each time it
/// opens (NSMenuDelegate) so it is always current.
extension AppController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.autoenablesItems = false
        menu.removeAllItems()

        if hotkeyStatus == .active {
            menu.addItem(status("Hold \(config.hotkeyKey.title) to talk · double-tap to lock"))
            for action in config.activeKeyActions {
                menu.addItem(status("Hold \(action.hotkeyKey?.title ?? action.key): \(action.summary)"))
            }
        } else {
            menu.addItem(status("Hotkey inactive — permission missing"))
            let fix = item(hotkeyStatus == .needsInputMonitoring
                               ? "Enable Input Monitoring for GroqVoice…"
                               : "Enable Accessibility for GroqVoice…", #selector(openPermissionSettings))
            fix.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(fix)
            menu.addItem(item("Relaunch GroqVoice (after granting)", #selector(relaunch)))
        }
        menu.addItem(.separator())

        menu.addItem(recentMenuItem())
        let pasteLast = item("Paste Last Again", #selector(menuPasteLast))
        pasteLast.isEnabled = history.latest != nil
        menu.addItem(pasteLast)
        menu.addItem(item("History…", #selector(menuShowHistory)))
        menu.addItem(.separator())

        menu.addItem(item("Settings…", #selector(menuShowSettings), key: ","))
        menu.addItem(item("Dictionary & Snippets…", #selector(menuShowDictionary)))
        menu.addItem(item("Add Vocabulary Term…", #selector(menuQuickAddTerm)))
        menu.addItem(engineMenuItem())
        menu.addItem(hotkeyMenuItem())
        menu.addItem(microphoneMenuItem())
        menu.addItem(languageMenuItem())
        menu.addItem(check("Sound Feedback", #selector(menuToggleSounds), config.playFeedbackSounds))
        menu.addItem(.separator())

        menu.addItem(item("Open Log", #selector(menuOpenLog)))
        menu.addItem(item(screenRecorder.isRecording ? "Stop Screen Recording  (⌃⌥⌘R)" : "Record Screen  (⌃⌥⌘R)",
                          #selector(toggleScreenRecording)))
        menu.addItem(.separator())
        menu.addItem(item("Quit GroqVoice", #selector(menuQuit), key: "q"))
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        menu.addItem(status("GroqVoice \(version) · Parakeet v3"))
    }

    // MARK: - Submenus

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
                switch entry.kind {
                case "task": row.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
                case "translate": row.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
                case "prompt": row.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
                case "edit": row.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
                case "snippet": row.image = NSImage(systemSymbolName: "text.badge.plus", accessibilityDescription: nil)
                default: break
                }
                sub.addItem(row)
            }
        }
        root.submenu = sub
        return root
    }

    private func engineMenuItem() -> NSMenuItem {
        let current = config.usesLocalEngine ? "Parakeet v3 (on this Mac)" : "Whisper via Groq (cloud)"
        let root = NSMenuItem(title: "Engine: \(current)", action: nil, keyEquivalent: "")
        let sub = submenu()
        for (title, engine) in [("Parakeet v3 — on this Mac, no account needed", "parakeet"),
                                ("Whisper via Groq — cloud, needs an API key", "groq")] {
            let row = item(title, #selector(menuSetEngine(_:)))
            row.representedObject = engine
            row.state = config.sttEngine == engine ? .on : .off
            sub.addItem(row)
        }
        if let text = localModelStatus {
            sub.addItem(.separator())
            sub.addItem(status("Parakeet model: \(text)"))
        }
        root.submenu = sub
        return root
    }

    private func hotkeyMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Hotkey: \(config.hotkeyKey.title)", action: nil, keyEquivalent: "")
        let sub = submenu()
        for key in HotkeyKey.allCases {
            let row = item(key.title, #selector(menuSetHotkey(_:)))
            row.representedObject = key.rawValue
            row.state = config.hotkeyKey == key ? .on : .off
            if let action = config.action(for: key) {
                row.isEnabled = false
                row.title = "\(key.title) — \(action.summary)"
            }
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

    private func languageMenuItem() -> NSMenuItem {
        let currentTitle = Config.recognitionLanguages.first { $0.code == config.language }?.name ?? config.language
        let root = NSMenuItem(title: "Language: \(currentTitle)", action: nil, keyEquivalent: "")
        let sub = submenu()
        sub.addItem(status(config.usesLocalEngine
                               ? "Parakeet: Auto keeps mixed RU/EN; a fixed language only filters the alphabet"
                               : "Whisper: Auto detects per phrase; a fixed language forces it"))
        for (code, name) in Config.recognitionLanguages {
            let row = item(name, #selector(menuSetLanguage(_:)))
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
        settingsChanged()
        Log.write("engine → \(engine)")
        if !config.usesLocalEngine && config.groqApiKey.isEmpty {
            menuShowSettings()
            settingsWindow.selectTab(2)
        }
    }

    @objc func menuSetHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = HotkeyKey(rawValue: raw) else { return }
        if case .recording = phase { recorder.discard(); phase = .idle; setIcon(.ready) }
        config.hotkey = key.rawValue
        settingsChanged()
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
        settingsChanged()
        Log.write("microphone → \(uid.isEmpty ? "system default" : sender.title)")
    }

    @objc func menuSetLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        config.language = code
        settingsChanged()
        Log.write("language → \(code.isEmpty ? "auto" : code)")
    }

    @objc func menuToggleSounds() {
        config.playFeedbackSounds.toggle()
        settingsChanged()
        Log.write("sound feedback → \(config.playFeedbackSounds)")
        if config.playFeedbackSounds { NSSound(named: "Pop")?.play() }
    }

    @objc func menuCopyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        flashIcon(.copied, for: 1.2)
    }

    @objc func menuPasteLast() { pasteLastAgain() }
    @objc func menuOpenLog() { NSWorkspace.shared.open(Log.fileURL) }
    @objc func menuQuit() { NSApp.terminate(nil) }
}
