import Foundation

/// One line of vocabulary.txt: a canonical spelling plus optional aliases —
/// the ways the recognizer tends to write it ("Coolify: кулифай, кулифи").
struct VocabularyEntry {
    let term: String
    let aliases: [String]
}

/// Loads vocabulary.txt (one term per line, `#` comments, optional
/// `Term: alias, alias`). Provides (1) a Whisper `prompt` string of canonical
/// terms for the Groq engine, (2) deterministic alias → term replacement for
/// any transcript, (3) the term count for the menu. Hot-reloads on mtime.
final class Vocabulary {
    static var fileURL: URL { Config.supportDir.appendingPathComponent("vocabulary.txt") }

    let fileURL: URL
    private var cachedEntries: [VocabularyEntry] = []
    private var cachedPrompt = ""
    private var cachedMtime: Date?
    private var loaded = false
    private let maxPromptChars = 700

    init(fileURL: URL = Vocabulary.fileURL) {
        self.fileURL = fileURL
        if fileURL == Vocabulary.fileURL, !FileManager.default.fileExists(atPath: fileURL.path) {
            try? DefaultVocabulary.text.data(using: .utf8)!.write(to: fileURL)
        }
    }

    var entries: [VocabularyEntry] {
        reloadIfNeeded()
        return cachedEntries
    }

    /// Number of real entries (ignores comments and blank lines).
    var termCount: Int { entries.count }

    /// Canonical terms joined for Whisper's `prompt` parameter (≤ ~700 chars).
    func prompt() -> String {
        reloadIfNeeded()
        return cachedPrompt
    }

    /// Replaces whole-word occurrences of any alias (and of the term itself in
    /// other casing) with the canonical term. Returns the text and the list of
    /// replacements made, for the log.
    func applyAliases(to text: String) -> (text: String, changes: [String]) {
        var result = text
        var changes: [String] = []
        for entry in entries {
            for alias in entry.aliases + [entry.term] {
                guard !alias.isEmpty else { continue }
                let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: alias) + "(?![\\p{L}\\p{N}])"
                guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                let range = NSRange(result.startIndex..., in: result)
                let matches = re.matches(in: result, range: range)
                guard !matches.isEmpty else { continue }
                // Skip matches that are already the canonical spelling.
                var replaced = false
                for m in matches.reversed() {
                    guard let r = Range(m.range, in: result), result[r] != entry.term else { continue }
                    changes.append("\(result[r]) → \(entry.term)")
                    result.replaceSubrange(r, with: entry.term)
                    replaced = true
                }
                _ = replaced
            }
        }
        return (result, changes)
    }

    private func reloadIfNeeded() {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date) ?? nil
        if loaded, mtime == cachedMtime { return }
        loaded = true
        cachedMtime = mtime

        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            cachedEntries = []
            cachedPrompt = ""
            return
        }
        cachedEntries = text.split(whereSeparator: { $0.isNewline }).compactMap { raw -> VocabularyEntry? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            guard let colon = line.firstIndex(of: ":") else { return VocabularyEntry(term: line, aliases: []) }
            let term = line[..<colon].trimmingCharacters(in: .whitespaces)
            let aliases = line[line.index(after: colon)...].split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return term.isEmpty ? nil : VocabularyEntry(term: term, aliases: aliases)
        }

        var joined = cachedEntries.map(\.term).joined(separator: ", ")
        if joined.count > maxPromptChars {
            let cut = joined.prefix(maxPromptChars)
            joined = cut.lastIndex(of: ",").map { String(cut[..<$0]) } ?? String(cut)
        }
        cachedPrompt = joined
        if !cachedEntries.isEmpty {
            let aliasCount = cachedEntries.reduce(0) { $0 + $1.aliases.count }
            Log.write("vocabulary loaded: \(cachedEntries.count) terms, \(aliasCount) aliases")
        }
    }
}
