import Foundation

struct HistoryEntry: Codable {
    let time: Date
    let kind: String  // "dictation" | "task"
    let text: String

    /// Single-line, shortened form for menus.
    var menuTitle: String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return oneLine.count > 60 ? String(oneLine.prefix(57)) + "…" : oneLine
    }
}

/// Keeps the last N outputs (dictations and task answers) in history.jsonl so
/// a paste that landed in the wrong window can be recovered from the menu.
final class History {
    static var fileURL: URL { Config.supportDir.appendingPathComponent("history.jsonl") }

    /// Oldest first.
    private(set) var entries: [HistoryEntry] = []
    private let limit: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(limit: Int) {
        self.limit = max(1, limit)
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    var latest: HistoryEntry? { entries.last }

    func add(_ text: String, kind: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.append(HistoryEntry(time: Date(), kind: kind, text: trimmed))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        save()
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: History.fileURL)
    }

    private func load() {
        guard let raw = try? String(contentsOf: History.fileURL, encoding: .utf8) else { return }
        entries = raw.split(separator: "\n").compactMap { line in
            try? decoder.decode(HistoryEntry.self, from: Data(line.utf8))
        }
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    private func save() {
        let lines = entries.compactMap { entry -> String? in
            guard let data = try? encoder.encode(entry) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: History.fileURL)
    }
}
