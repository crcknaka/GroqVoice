import Foundation
import Testing
@testable import GroqVoice

private func snippets(_ text: String) throws -> Snippets {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("snip-\(UUID().uuidString).txt")
    try text.write(to: url, atomically: true, encoding: .utf8)
    return Snippets(fileURL: url)
}

@Suite struct SnippetsTests {
    @Test func parsesLiteralAndInstructionEntries() throws {
        let s = try snippets("""
        # comment
        моя почта = ivan@example.com
        подпись = С уважением,\\nИлья
        переведи => переведи текст на английский
        """)
        #expect(s.entries.count == 3)
        #expect(s.entries[0].text == "ivan@example.com")
        #expect(s.entries[1].text == "С уважением,\nИлья")
        #expect(s.entries[2].isInstruction)
        #expect(s.entries[2].text == "переведи текст на английский")
    }

    @Test func expandsOnlyWhenTheWholeUtteranceMatchesALiteral() throws {
        let s = try snippets("моя почта = ivan@example.com\nпереведи => переведи на английский\n")
        #expect(s.expansion(for: "Моя почта.") == "ivan@example.com")
        #expect(s.expansion(for: "моя  почта") == "ivan@example.com")
        #expect(s.expansion(for: "напиши мою почту") == nil)
        #expect(s.expansion(for: "переведи") == nil)  // instructions are for the LLM only
    }

    @Test func editsPreserveCommentsAndOrder() throws {
        let s = try snippets("# header\nа = 1\n\n# section\nб = 2\n")
        s.update(at: 1, phrase: "бэ", text: "два\nстроки", isInstruction: false)
        s.add(phrase: "в", text: "3", isInstruction: true)
        s.remove(at: 0)
        let file = try String(contentsOf: s.fileURL, encoding: .utf8)
        #expect(file == "# header\n\n# section\nбэ = два\\nстроки\nв => 3\n")
        #expect(s.entries.map(\.phrase) == ["бэ", "в"])
        #expect(s.entries[0].text == "два\nстроки")
    }
}
