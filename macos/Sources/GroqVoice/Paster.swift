import Cocoa

enum PasteMode: String, CaseIterable {
    case paste  // clipboard + ⌘V (fast, default)
    case type   // synthesized keystrokes, for apps where ⌘V doesn't paste
}

/// Delivers text into the focused app.
///
/// Paste mode puts the text on the pasteboard, synthesizes ⌘V and then puts
/// back whatever the user had there — all items and types, not just plain
/// text — unless something else was copied in the meantime.
/// Type mode sends the text as Unicode keystrokes and leaves the clipboard alone.
enum Paster {
    private static let typingQueue = DispatchQueue(label: "groqvoice.typing", qos: .userInitiated)
    private static let restoreDelay: TimeInterval = 0.7

    static func deliver(_ text: String, mode: PasteMode, restoreClipboard: Bool) {
        guard !text.isEmpty else { return }
        switch mode {
        case .paste:
            paste(text, restoreClipboard: restoreClipboard)
        case .type:
            Log.write("paste: typing \(text.count) chars")
            waitForModifierRelease()
            typingQueue.async { typeText(text) }
        }
    }

    // MARK: - Paste

    private static func paste(_ text: String, restoreClipboard: Bool) {
        let pb = NSPasteboard.general
        let snapshot = restoreClipboard ? snapshotPasteboard(pb) : []

        pb.clearContents()
        pb.setString(text, forType: .string)
        let ourChange = pb.changeCount

        waitForModifierRelease()

        let src = CGEventSource(stateID: .combinedSessionState)
        let kVK_V: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: kVK_V, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: kVK_V, keyDown: false) else {
            Log.write("paste: failed to create CGEvent")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        mark(down); mark(up)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        guard restoreClipboard, !snapshot.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            // If the user copied something else already, leave it alone.
            guard pb.changeCount == ourChange else { return }
            restore(snapshot, to: pb)
        }
    }

    typealias PasteboardSnapshot = [[(NSPasteboard.PasteboardType, Data)]]

    static func snapshotPasteboard(_ pb: NSPasteboard) -> PasteboardSnapshot {
        (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            }
        }.filter { !$0.isEmpty }
    }

    static func restore(_ snapshot: PasteboardSnapshot, to pb: NSPasteboard) {
        pb.clearContents()
        guard !snapshot.isEmpty else { return }
        pb.writeObjects(snapshot.map { item in
            let copy = NSPasteboardItem()
            for (type, data) in item { copy.setData(data, forType: type) }
            return copy
        })
    }

    /// Synthesizes ⌘C in the focused app.
    static func pressCommandC() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let kVK_C: CGKeyCode = 8
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: kVK_C, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: kVK_C, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        mark(down); mark(up)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Tags an event as ours so the hotkey tap ignores it.
    private static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.syntheticMarker)
    }

    // MARK: - Type

    private static func typeText(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for ch in text {
            switch ch {
            case "\n", "\r", "\r\n": press(keyCode: 36, source: src)  // Return
            case "\t": press(keyCode: 48, source: src)                // Tab
            default:
                var units = Array(String(ch).utf16)
                guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { continue }
                down.flags = []
                up.flags = []
                mark(down); mark(up)
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
            usleep(2_000)
        }
    }

    private static func press(keyCode: CGKeyCode, source: CGEventSource?) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = []
        up.flags = []
        mark(down); mark(up)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Wait up to 300 ms for the user to release the hotkey/modifiers so they
    /// don't combine with the synthesized keystrokes.
    private static func waitForModifierRelease() {
        let blocked: NSEvent.ModifierFlags = [.function, .command, .option, .control, .shift]
        for _ in 0..<30 {
            if NSEvent.modifierFlags.intersection(blocked).isEmpty { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
