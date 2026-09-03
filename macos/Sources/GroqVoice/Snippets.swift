import Foundation

/// One line of snippets.txt.
///   phrase = text          — say the phrase alone, the text is pasted (no LLM)
///   phrase => instruction  — an instruction the LLM applies in task mode
struct SnippetEntry: Equatable {
    var phrase: String
    var text: String
    var isInstruction: Bool
    /// Line in the file (kept so edits preserve comments and order).
    var lineIndex: Int

    /// The text as stored on one line: real line breaks become `\n`.
    var fileLine: String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
        return "\(phrase) \(isInstruction ? "=>" : "=") \(escaped)"
    }
}

/// Spoken shortcuts. Literal ones expand instantly and offline when the whole
/// utterance matches the phrase; both kinds are also described to the LLM for
/// task mode ("задание напиши мою рабочую почту"). Hot-reloads on file mtime.
final class Snippets {
    static var fileURL: URL { Config.supportDir.appendingPathComponent("snippets.txt") }

    static let template = """
    # GroqVoice snippets — say the phrase on its own and the text is pasted, instantly, no LLM.
    #
    #   phrase = text to paste            (\\n makes a line break)
    #   phrase => instruction for the LLM (used when you start with «задание …» / "task …")
    #
    # Lines starting with # are ignored. Matching ignores case and punctuation.
    # Examples:
    # моя почта = ivan@example.com
    # подпись = С уважением,\\nИлья Коваленко\\nSitesPro
    # переведи => переведи текст на английский и выведи только перевод

    """

    let fileURL: URL
    private var lines: [String] = []
    private var cachedEntries: [SnippetEntry] = []
    private var cachedMtime: Date?
    private var loaded = false

    init(fileURL: URL = Snippets.fileURL) {
        self.fileURL = fileURL
        if fileURL == Snippets.fileURL, !FileManager.default.fileExists(atPath: fileURL.path) {
            try? Snippets.template.data(using: .utf8)!.write(to: fileURL)
        }
    }

    var entries: [SnippetEntry] {
        reloadIfNeeded()
        return cachedEntries
    }

    /// Lower-cased, punctuation stripped, whitespace collapsed — how spoken
    /// phrases are compared.
    static func normalize(_ s: String) -> String {
        let scalars = s.lowercased().unicodeScalars.map { scalar -> Character in
            (CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)) ? Character(scalar) : " "
        }
        return String(scalars).split(whereSeparator: { $0 == " " }).joined(separator: " ")
    }

    /// The literal text for an utterance that is exactly one snippet phrase.
    func expansion(for transcript: String) -> String? {
        let spoken = Snippets.normalize(transcript)
        guard !spoken.isEmpty else { return nil }
        return entries.first { !$0.isInstruction && Snippets.normalize($0.phrase) == spoken }?.text
    }

    /// Returns a system-prompt section describing the shortcuts, or "" if none defined.
    func systemPromptSection() -> String {
        let all = entries
        guard !all.isEmpty else { return "" }
        let listed = all.map { e in
            e.isInstruction ? "- when asked «\(e.phrase)»: \(e.text)"
                            : "- «\(e.phrase)» → output exactly: \(e.text.replacingOccurrences(of: "\n", with: "\\n"))"
        }
        return """

        The user defined these personal shortcuts. When the request matches one of them — even \
        approximately, in any language — use it: for a literal shortcut output its text EXACTLY as \
        written (with \\n as line breaks) and nothing else; for an instruction shortcut follow that \
        instruction for the rest of the request.
        Shortcuts:
        \(listed.joined(separator: "\n"))
        """
    }

    // MARK: - Editing (preserves comments and order)

    func add(phrase: String, text: String, isInstruction: Bool) {
        reloadIfNeeded()
        let entry = SnippetEntry(phrase: phrase.trimmingCharacters(in: .whitespaces), text: text,
                                 isInstruction: isInstruction, lineIndex: lines.count)
        lines.append(entry.fileLine)
        save()
    }

    func update(at index: Int, phrase: String, text: String, isInstruction: Bool) {
        reloadIfNeeded()
        guard cachedEntries.indices.contains(index) else { return }
        var entry = cachedEntries[index]
        entry.phrase = phrase.trimmingCharacters(in: .whitespaces)
        entry.text = text
        entry.isInstruction = isInstruction
        lines[entry.lineIndex] = entry.fileLine
        save()
    }

    func remove(at index: Int) {
        reloadIfNeeded()
        guard cachedEntries.indices.contains(index) else { return }
        lines.remove(at: cachedEntries[index].lineIndex)
        save()
    }

    // MARK: - File I/O

    private func reloadIfNeeded() {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date) ?? nil
        if loaded, mtime == cachedMtime { return }
        loaded = true
        cachedMtime = mtime
        lines = (try? String(contentsOf: fileURL, encoding: .utf8))?.components(separatedBy: "\n") ?? []
        if lines.last == "" { lines.removeLast() }
        cachedEntries = Snippets.parse(lines)
        if !cachedEntries.isEmpty {
            Log.write("snippets loaded: \(cachedEntries.count) entries")
        }
    }

    static func parse(_ lines: [String]) -> [SnippetEntry] {
        var out: [SnippetEntry] = []
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let isInstruction: Bool
            let separator: Range<String.Index>
            if let r = line.range(of: "=>") {
                isInstruction = true
                separator = r
            } else if let r = line.range(of: "=") {
                isInstruction = false
                separator = r
            } else {
                continue
            }
            let phrase = line[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
            let rawText = line[separator.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !phrase.isEmpty else { continue }
            out.append(SnippetEntry(phrase: phrase, text: unescape(rawText), isInstruction: isInstruction, lineIndex: i))
        }
        return out
    }

    private static func unescape(_ s: String) -> String {
        var out = ""
        var escaped = false
        for ch in s {
            if escaped {
                out.append(ch == "n" ? "\n" : ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        if escaped { out.append("\\") }
        return out
    }

    private func save() {
        try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: fileURL)
        loaded = false  // re-read: mtime changed, indices may have shifted
        reloadIfNeeded()
    }
}
