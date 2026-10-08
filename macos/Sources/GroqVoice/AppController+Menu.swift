import Cocoa

/// Status-bar menu: what the hotkeys do, recent dictations, the microphone
/// switch. Everything else lives in Settings. Rebuilt each time it opens
/// (NSMenuDelegate) so it is always current.
extension AppController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.autoenablesItems = false
        menu.removeAllItems()

        if hotkeyStatus == .active {
            menu.addItem(status("Hold \(config.hotkey.title) to talk · double-tap to lock"))
            for action in config.activeKeyActions {
                menu.addItem(status("Hold \(action.key.title): \(action.summary)"))
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
        if let lastError {
            let time = DateFormatter.localizedString(from: lastError.at, dateStyle: .none, timeStyle: .short)
            menu.addItem(status("Last take failed (\(time)): \(lastError.message)"))
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
        menu.addItem(microphoneMenuItem())
        if let text = localModelStatus { menu.addItem(status("Parakeet model: \(text)")) }
        menu.addItem(.separator())

        menu.addItem(item("Open Log", #selector(menuOpenLog)))
        menu.addItem(.separator())
        menu.addItem(item("Quit GroqVoice", #selector(menuQuit), key: "q"))
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        menu.addItem(status("GroqVoice \(version) · \(config.usesLocalEngine ? "Parakeet v3" : "Whisper via Groq")"))
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
                row.image = entry.kind.symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                sub.addItem(row)
            }
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

    /// Greyed-out informational row.
    private func status(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    // MARK: - Actions

    @objc func menuSetMicrophone(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        config.inputDeviceUID = uid
        settingsChanged()
        Log.write("microphone → \(uid.isEmpty ? "system default" : sender.title)")
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
