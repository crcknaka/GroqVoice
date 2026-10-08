import ApplicationServices
import Cocoa

/// What surrounds the insertion point in the focused text field, read through
/// the Accessibility API right before pasting. nil when the focused element
/// isn't a text field we can read (terminals, some web views, secure fields).
struct FocusedText {
    let before: Character?   // character right before the caret / selection
    let after: Character?    // character right after it
    let isEmpty: Bool

    /// The last non-whitespace character before the caret, if any.
    var lastVisibleBefore: Character? { before.flatMap { $0.isWhitespace ? nil : $0 } }

    static func current() -> FocusedText? {
        guard let element = focusedElement(), PasteTarget.editableRoles.contains(role(of: element)) else { return nil }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeAny = rangeRef else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeAny as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }
        let end = range.location + range.length

        // Ask for the two neighbouring characters only: a web text area's value
        // is its whole text, and fetching that was most of a take's latency.
        var countRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
           let count = countRef as? Int, end <= count,
           let before = range.location > 0 ? string(of: element, at: range.location - 1) : "",
           let after = end < count ? string(of: element, at: end) : "" {
            return FocusedText(before: before.last, after: after.first, isEmpty: count == 0)
        }

        // Apps without the ranged read: take the whole value.
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String else { return nil }
        let ns = text as NSString
        guard end <= ns.length else { return nil }
        let before = range.location > 0 ? ns.substring(with: NSRange(location: range.location - 1, length: 1)) : ""
        let after = end < ns.length ? ns.substring(with: NSRange(location: end, length: 1)) : ""
        return FocusedText(before: before.last, after: after.first, isEmpty: ns.length == 0)
    }

    /// One UTF-16 unit of the element's text; nil when the app can't answer.
    private static func string(of element: AXUIElement, at location: Int) -> String? {
        var range = CFRange(location: location, length: 1)
        guard let param = AXValueCreate(.cfRange, &range) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         param, &out) == .success else { return nil }
        return out as? String
    }

    /// What the focused app exposes about its selection, for the log.
    struct SelectionProbe {
        let app: String
        let role: String
        let text: String?
        let source: String   // "accessibility", "⌘C", "none"
        /// Accessibility gave no definitive answer; a ⌘C probe may still find a
        /// selection (deferred until the hotkey is released, to stay out of
        /// the way of shortcuts).
        let copyWorthTrying: Bool

        var description: String {
            let n = text.map { "\($0.count) chars via \(source)" } ?? (copyWorthTrying ? "none yet (⌘C probe at release)" : "none")
            return "focus: \(app) / \(role), selection: \(n)"
        }
    }

    /// Editors that copy the whole line when nothing is selected — a ⌘C probe
    /// would invent a selection there. (VS Code marks such copies and is handled.)
    private static let lineCopyingApps = ["com.jetbrains.", "com.sublimetext.", "dev.zed."]
    private static var frontmostCopiesLines: Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() else { return false }
        return lineCopyingApps.contains { id.hasPrefix($0) }
    }

    /// Editors built on VS Code. They expose no focused element, and must not
    /// be asked to (see `requestAccessibilityTree`) — but their focus is
    /// practically always an editor, a terminal or a chat box, so a paste lands.
    private static let monacoApps = ["com.microsoft.vscode", "com.vscodium", "com.todesktop.230313mzl4w4u92",
                                     "com.exafunction.windsurf"]
    static func isMonacoApp(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return monacoApps.contains { id.hasPrefix($0) }
    }

    private static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        // Accessibility calls block until the target app answers; a busy app
        // must not stall a take. On the system-wide element this is the
        // process-wide default.
        AXUIElementSetMessagingTimeout(element, 0.3)
        return element
    }()

    /// The element with keyboard focus: the system-wide attribute first, then
    /// the frontmost app's own (Electron apps answer only the latter, if at all).
    static func focusedElement() -> AXUIElement? {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
           let r = ref {
            return (r as! AXUIElement)
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        ref = nil
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &ref) == .success, let r = ref {
            return (r as! AXUIElement)
        }
        requestAccessibilityTree(of: app, element: appElement)
        return nil
    }

    private static var treeRequested: Set<pid_t> = []

    /// Electron apps (Claude, Slack, Discord…) build their accessibility tree
    /// only when asked through `AXManualAccessibility`. Asked once per process;
    /// the tree appears a moment later, so this take still sees nothing — it is
    /// requested at key-down and is there by the time the key is released.
    /// VS Code and its forks are left alone: for them the request means "a
    /// screen reader is attached" and turns off word wrap and turns on audio cues.
    private static func requestAccessibilityTree(of app: NSRunningApplication, element: AXUIElement) {
        let pid = app.processIdentifier
        guard !treeRequested.contains(pid), !isMonacoApp(app.bundleIdentifier) else { return }
        treeRequested.insert(pid)
        let status = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if status == .success {
            Log.write("accessibility: asked \(app.localizedName ?? "?") to build its tree (AXManualAccessibility)")
        }
    }

    static func role(of element: AXUIElement) -> String {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        return (roleRef as? String) ?? "?"
    }

    /// The text currently selected in the frontmost app. Accessibility first;
    /// where the app doesn't expose the selection at all (Word's document view,
    /// VS Code, terminals, web pages) a synthesized ⌘C fetches it and the
    /// clipboard is put back right away. Apps that do expose it but report it
    /// empty (JetBrains, Xcode) are trusted — their ⌘C would copy a whole line.
    /// `allowCopy: false` is side-effect free (Accessibility only) and is what
    /// runs at key-down; `allowCopy: true` may synthesize ⌘C and runs once the
    /// key is released, so a held modifier never turns it into ⌥⌘C. Chat apps
    /// (WhatsApp, Telegram) keep focus in the compose box while you select a
    /// message, so their selection is only ever reachable through ⌘C.
    static func probeSelection(allowCopy: Bool) -> SelectionProbe {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let copyAllowedHere = !frontmostCopiesLines

        func viaCopy(role: String) -> SelectionProbe {
            guard copyAllowedHere else { return SelectionProbe(app: app, role: role, text: nil, source: "none", copyWorthTrying: false) }
            guard allowCopy else { return SelectionProbe(app: app, role: role, text: nil, source: "none", copyWorthTrying: true) }
            if let copied = copySelectionViaCommandC() {
                return SelectionProbe(app: app, role: role, text: copied, source: "⌘C", copyWorthTrying: false)
            }
            return SelectionProbe(app: app, role: role, text: nil, source: "none", copyWorthTrying: false)
        }

        guard let element = focusedElement() else { return viaCopy(role: "no focused element") }
        let role = role(of: element)

        var selectedRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedRef)
        if status == .success, let selected = selectedRef as? String,
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SelectionProbe(app: app, role: role, text: selected, source: "accessibility", copyWorthTrying: false)
        }
        if PasteTarget.nonEditableRoles.contains(role) && role != "AXWebArea" {
            // Lists, buttons, images: nothing to edit and ⌘C would copy files or nothing.
            return SelectionProbe(app: app, role: role, text: nil, source: "none", copyWorthTrying: false)
        }
        return viaCopy(role: role)
    }

    /// Debug (`--probe-ax <bundle id> [--manual]`): what a running app exposes
    /// about its focused element, optionally after asking it for its tree.
    static func debugProbe(bundleID: String, manual: Bool) -> String {
        guard AXIsProcessTrusted() else { return "not trusted for Accessibility — launch through `open GroqVoice.app --args …`" }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return "\(bundleID) is not running"
        }
        _ = systemWide
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        func describe() -> String? {
            var ref: CFTypeRef?
            let t0 = Date()
            let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &ref)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            guard status == .success, let r = ref else { return nil }
            let element = r as! AXUIElement
            var settable = DarwinBoolean(false)
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
            var countRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countRef)
            var rangeRef: CFTypeRef?
            var range = CFRange(location: -1, length: 0)
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
               let v = rangeRef { AXValueGetValue(v as! AXValue, .cfRange, &range) }
            let ranged = range.location > 0 ? string(of: element, at: range.location - 1) : nil
            return "role \(role(of: element)), value settable \(settable.boolValue), characters \((countRef as? Int).map(String.init) ?? "n/a"), "
                + "caret \(range.location)+\(range.length), ranged read \(ranged == nil ? "n/a" : "ok") (\(ms) ms)"
        }

        var lines = ["\(app.localizedName ?? bundleID): " + (describe() ?? "no focused element")]
        if manual {
            let status = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            lines.append("AXManualAccessibility → \(status == .success ? "accepted" : "refused (\(status.rawValue))")")
            let t0 = Date()
            var found: String?
            while found == nil, Date().timeIntervalSince(t0) < 3 {
                Thread.sleep(forTimeInterval: 0.05)
                found = describe()
            }
            lines.append(found.map { String(format: "after %.2fs: ", Date().timeIntervalSince(t0)) + $0 } ?? "still no focused element after 3s")
        }
        // An app in the background has no focus to report; its tree still shows
        // whether text fields are exposed at all.
        var nodes = 0
        var textRoles: [String: Int] = [:]
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 40, nodes < 5000 else { return }
            nodes += 1
            let r = role(of: element)
            if PasteTarget.editableRoles.contains(r) { textRoles[r, default: 0] += 1 }
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
                  let children = ref as? [AXUIElement] else { return }
            for child in children { walk(child, depth: depth + 1) }
        }
        walk(appElement, depth: 0)
        lines.append("tree: \(nodes) elements, text fields: \(textRoles.isEmpty ? "none" : textRoles.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }

    /// Can the focused element take a paste?
    enum PasteTarget: Equatable {
        case editable      // a text field/area, or an element whose value is settable
        case nonEditable   // a web page, PDF, file list, button… nowhere to type
        case unknown       // an ambiguous role — assume it can, but keep the result safe

        static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        /// Only roles that can never take typed text. Containers like
        /// AXSplitGroup (Word's document) or "no element" (VS Code) stay
        /// unknown: the paste goes through and the result is also kept on the
        /// clipboard.
        static let nonEditableRoles: Set<String> = [
            "AXWebArea", "AXStaticText", "AXImage", "AXOutline", "AXTable", "AXBrowser", "AXList", "AXRow",
            "AXCell", "AXButton", "AXLink", "AXMenuItem", "AXMenu", "AXRadioButton", "AXCheckBox",
            "AXPopUpButton", "AXSlider",
        ]

        static func classify(role: String?, valueSettable: Bool) -> PasteTarget {
            guard let role else { return .unknown }
            if editableRoles.contains(role) || valueSettable { return .editable }
            if nonEditableRoles.contains(role) { return .nonEditable }
            return .unknown
        }
    }

    /// Looks at the focused element right before pasting.
    static func pasteTarget() -> (target: PasteTarget, role: String) {
        guard let element = focusedElement() else {
            let knownEditor = isMonacoApp(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            return (knownEditor ? .editable : .unknown, "no focused element")
        }
        let role = role(of: element)
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return (PasteTarget.classify(role: role, valueSettable: settable.boolValue), role)
    }

    /// ⌘C into a scratch clipboard, read, restore. Returns nil when nothing
    /// arrived in time (no selection, or the app doesn't copy on ⌘C). Most
    /// takes have no selection and sit out the whole wait, while a real copy
    /// lands within 40 ms — so the wait is kept short.
    private static let copyProbeTimeout: TimeInterval = 0.07

    private static func copySelectionViaCommandC() -> String? {
        let pb = NSPasteboard.general
        let snapshot = Paster.snapshotPasteboard(pb)
        let before = pb.changeCount
        Paster.pressCommandC()
        let deadline = Date().addingTimeInterval(copyProbeTimeout)
        while pb.changeCount == before && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { Paster.restore(snapshot, to: pb) }
        guard pb.changeCount != before else { return nil }
        // VS Code (and other Monaco editors) copy the whole line when nothing
        // is selected, and say so in their own pasteboard type.
        if let data = pb.data(forType: NSPasteboard.PasteboardType("vscode-editor-data")),
           let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           meta["isFromEmptySelection"] as? Bool == true {
            return nil
        }
        guard let text = pb.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Adjusts dictated text for where it lands: a space when glued to a word
    /// or sentence, lower-case first letter when continuing a sentence, a
    /// space before a following word. `knownTerms` (vocabulary) are never
    /// lower-cased — they are the names we went to lengths to spell right.
    func adjust(_ text: String, knownTerms: Set<String> = []) -> String {
        guard !text.isEmpty else { return text }
        var out = text
        let opening: Set<Character> = ["(", "[", "{", "\"", "'", "«", "„", "“", "‘", "/", "@", "#"]

        if let b = before, !b.isWhitespace, !opening.contains(b) {
            out = " " + out
        }
        if let b = lastVisibleBefore, b.isLetter || b.isNumber || ",;:—–-".contains(b) {
            // Mid-sentence: the recognizer capitalised a fresh utterance, undo that
            // unless the first word is an acronym or a vocabulary term.
            let trimmed = out.drop { $0 == " " }
            let firstWord = String(trimmed.prefix { $0.isLetter || $0.isNumber })
            let isAcronym = firstWord.count > 1 && firstWord == firstWord.uppercased()
            if let first = trimmed.first, first.isUppercase, !isAcronym, !knownTerms.contains(firstWord) {
                let lead = out.prefix { $0 == " " }
                out = lead + String(first).lowercased() + String(trimmed.dropFirst())
            }
        }
        if let a = after, a.isLetter || a.isNumber {
            out += " "
        }
        return out
    }
}

/// Spoken formatting commands: saying “новая строка” or “абзац” (or the
/// English equivalents) inserts a line break instead of the words.
enum SpokenFormatting {
    static let newline = ["новая строка", "с новой строки", "перенос строки", "new line", "newline", "line break"]
    static let paragraph = ["новый абзац", "с нового абзаца", "абзац", "new paragraph", "paragraph break"]

    // Before the command: swallow separators (space, comma, dash) but keep the
    // sentence's own ". ! ?". After it: swallow whatever the recognizer stuck on.
    private static let leading = #"[\s,;:—–-]*"#
    private static let trailing = #"[\s,.;:!?—–-]*"#
    private static func regex(_ phrases: [String]) -> NSRegularExpression {
        let alternatives = phrases
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"\s+"#) }
            .joined(separator: "|")
        let pattern = leading + #"(?<![\p{L}\p{N}])(?:"# + alternatives + #")(?![\p{L}\p{N}])"# + trailing
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
    private static let paragraphRegex = regex(paragraph)
    private static let newlineRegex = regex(newline)

    static func apply(_ text: String) -> String {
        var out = text
        for (re, replacement) in [(paragraphRegex, "\n\n"), (newlineRegex, "\n")] {
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: replacement)
        }
        // A command at the very start leaves a leading break nobody wants;
        // one at the end is intentional (start a new line for the next take).
        while out.hasPrefix("\n") { out.removeFirst() }
        return out
    }
}
