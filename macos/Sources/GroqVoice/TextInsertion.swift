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
        guard let element = focusedElement() else { return nil }

        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"].contains(role) else { return nil }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String else { return nil }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeAny = rangeRef else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeAny as! AXValue, .cfRange, &range) else { return nil }

        let ns = text as NSString
        guard range.location >= 0, range.location <= ns.length else { return nil }
        let before: Character? = range.location > 0
            ? Character(ns.substring(with: NSRange(location: range.location - 1, length: 1)))
            : nil
        let afterIndex = range.location + range.length
        let after: Character? = afterIndex < ns.length
            ? Character(ns.substring(with: NSRange(location: afterIndex, length: 1)))
            : nil
        return FocusedText(before: before, after: after, isEmpty: ns.length == 0)
    }

    /// What the focused app exposes about its selection, for the log.
    struct SelectionProbe {
        let app: String
        let role: String
        let text: String?
        let source: String   // "accessibility", "⌘C", "none"

        var description: String {
            let n = text.map { "\($0.count) chars via \(source)" } ?? "none"
            return "focus: \(app) / \(role), selection: \(n)"
        }
    }

    /// The element with keyboard focus: the system-wide attribute first, then
    /// the frontmost app's own (Electron apps answer only the latter, if at all).
    static func focusedElement() -> AXUIElement? {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &ref) == .success,
           let r = ref {
            return (r as! AXUIElement)
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        ref = nil
        if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                         kAXFocusedUIElementAttribute as CFString, &ref) == .success, let r = ref {
            return (r as! AXUIElement)
        }
        return nil
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
    static func probeSelection() -> SelectionProbe {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        guard let element = focusedElement() else {
            if let copied = copySelectionViaCommandC() {
                return SelectionProbe(app: app, role: "no focused element", text: copied, source: "⌘C")
            }
            return SelectionProbe(app: app, role: "no focused element", text: nil, source: "none")
        }
        let role = role(of: element)

        var selectedRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedRef)
        if status == .success, let selected = selectedRef as? String,
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SelectionProbe(app: app, role: role, text: selected, source: "accessibility")
        }
        if PasteTarget.nonEditableRoles.contains(role) && role != "AXWebArea" {
            return SelectionProbe(app: app, role: role, text: nil, source: "none")  // lists, buttons: nothing to edit
        }

        var rangeRef: CFTypeRef?
        var range = CFRange()
        let hasRange = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success
            && rangeRef != nil && AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) && range.length > 0
        let exposesSelection = status == .success || status == .noValue
        if hasRange || !exposesSelection || role == "AXWebArea" {
            if let copied = copySelectionViaCommandC() {
                return SelectionProbe(app: app, role: role, text: copied, source: "⌘C")
            }
        }
        return SelectionProbe(app: app, role: role, text: nil, source: "none")
    }

    static func selectedText() -> String? { probeSelection().text }

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
        guard let element = focusedElement() else { return (.unknown, "no focused element") }
        let role = role(of: element)
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return (PasteTarget.classify(role: role, valueSettable: settable.boolValue), role)
    }

    /// ⌘C into a scratch clipboard, read, restore. Returns nil when nothing
    /// arrived within 150 ms (no selection, or the app doesn't copy on ⌘C).
    private static func copySelectionViaCommandC() -> String? {
        let pb = NSPasteboard.general
        let snapshot = Paster.snapshotPasteboard(pb)
        let before = pb.changeCount
        Paster.pressCommandC()
        let deadline = Date().addingTimeInterval(0.15)
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
