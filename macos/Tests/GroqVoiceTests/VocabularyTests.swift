import Foundation
import Testing
@testable import GroqVoice

private func vocabulary(_ text: String) throws -> Vocabulary {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-\(UUID().uuidString).txt")
    try text.write(to: url, atomically: true, encoding: .utf8)
    return Vocabulary(fileURL: url)
}

@Suite struct VocabularyTests {
    @Test func parsesTermsAndAliases() throws {
        let v = try vocabulary("""
        # comment
        Coolify: кулифай, кулифи
        gRPC

        Docker : докер
        """)
        #expect(v.termCount == 3)
        #expect(v.entries[0].term == "Coolify")
        #expect(v.entries[0].aliases == ["кулифай", "кулифи"])
        #expect(v.entries[1].aliases.isEmpty)
        #expect(v.entries[2].term == "Docker")
        #expect(v.prompt() == "Coolify, gRPC, Docker")
    }

    @Test func replacesWholeWordAliasesCaseInsensitively() throws {
        let v = try vocabulary("Coolify: кулифай\nDocker: докер, декер\n")
        let out = v.applyAliases(to: "Задеплой на Кулифай и проверь декер.")
        #expect(out.text == "Задеплой на Coolify и проверь Docker.")
        #expect(out.changes.count == 2)
    }

    @Test func fixesCasingOfTheTermItself() throws {
        let v = try vocabulary("GitHub\n")
        #expect(v.applyAliases(to: "залей на github").text == "залей на GitHub")
        #expect(v.applyAliases(to: "уже GitHub").changes.isEmpty)
    }

    @Test func cyrillicAliasesMatchInflectedForms() throws {
        let v = try vocabulary("Telegram: телеграм\nGitHub: гитхаб\n")
        let out = v.applyAliases(to: "Напиши в телеграмме и посмотри на гитхабе.")
        #expect(out.text == "Напиши в Telegram и посмотри на GitHub.")
    }

    @Test func shortAliasesStayExact() throws {
        let v = try vocabulary("git: гит\npush: пуш\n")
        // "гитара" must not become "gitара"; "пушка" must survive.
        #expect(v.applyAliases(to: "гитара и пушка, но гит и пуш").text == "гитара и пушка, но git и push")
    }

    @Test func doesNotTouchSubstringsInsideWords() throws {
        let v = try vocabulary("API: апи\n")
        #expect(v.applyAliases(to: "напиши апи и капитан").text == "напиши API и капитан")
    }
}
