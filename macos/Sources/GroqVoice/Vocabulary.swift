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
    private var cachedMatchers: [(regex: NSRegularExpression, term: String)] = []
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
        reloadIfNeeded()
        var result = text
        var changes: [String] = []
        for matcher in cachedMatchers {
            let matches = matcher.regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            guard !matches.isEmpty else { continue }
            for m in matches.reversed() {
                // Skip matches that are already the canonical spelling.
                guard let r = Range(m.range, in: result), result[r] != matcher.term else { continue }
                changes.append("\(result[r]) → \(matcher.term)")
                result.replaceSubrange(r, with: matcher.term)
            }
        }
        return (result, changes)
    }

    /// One compiled pattern per alias (and per term, for casing). Russian
    /// inflects borrowed names ("в телеграмме", "на гитхабе"), so a Cyrillic
    /// alias of five letters or more also matches with up to three trailing
    /// letters; short aliases stay exact to avoid false hits.
    private static func matchers(for entries: [VocabularyEntry]) -> [(regex: NSRegularExpression, term: String)] {
        var out: [(NSRegularExpression, String)] = []
        for entry in entries {
            for alias in entry.aliases + [entry.term] where !alias.isEmpty {
                let isCyrillic = alias.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
                let suffix = (isCyrillic && alias.count >= 5) ? "[\\p{Cyrillic}]{0,3}" : ""
                let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: alias) + suffix + "(?![\\p{L}\\p{N}])"
                if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    out.append((re, entry.term))
                }
            }
        }
        return out
    }

    private func reloadIfNeeded() {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date) ?? nil
        if loaded, mtime == cachedMtime { return }
        loaded = true
        cachedMtime = mtime

        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            cachedEntries = []
            cachedMatchers = []
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

        cachedMatchers = Vocabulary.matchers(for: cachedEntries)
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
