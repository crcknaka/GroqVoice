import Foundation
import Testing
@testable import GroqVoice

private func snippets(_ text: String = "") throws -> Snippets {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString).txt")
    try text.write(to: url, atomically: true, encoding: .utf8)
    return Snippets(fileURL: url)
}

private func plan(_ transcript: String, selection: String? = nil, take: TakeKind = .dictate,
                  cfg: Config = Config(), snippets text: String = "") throws -> TakePlan {
    try TakePlan.make(transcript: transcript, selection: selection, take: take, cfg: cfg,
                      snippets: snippets(text), vocabularyPrompt: "Coolify")
}

@Suite struct TakePlanTests {
    @Test func plainDictationNeedsNoModel() throws {
        let p = try plan("Привет. Новая строка. Как дела?")
        #expect(p.request == nil)
        let r = try p.result(answer: nil)
        #expect(r == TakePlan.Result(text: "Привет.\nКак дела?", kind: .dictation))
    }

    @Test func spokenFormattingCanBeTurnedOff() throws {
        var cfg = Config()
        cfg.spokenFormatting = false
        #expect(try plan("Привет, новая строка", cfg: cfg).result(answer: nil).text == "Привет, новая строка")
    }

    @Test func nothingSaidIsAnError() {
        #expect(throws: AppError.self) { try plan("  ") }
        #expect(throws: AppError.self) { try plan("", selection: "выделенный текст") }
    }

    @Test func aSnippetPhraseExpandsWithoutTheModel() throws {
        let p = try plan("Моя почта.", snippets: "моя почта = ivan@example.com")
        #expect(p.request == nil)
        #expect(try p.result(answer: nil) == TakePlan.Result(text: "ivan@example.com", kind: .snippet))
    }

    @Test func taskModeAsksTheModelAndNeverPastesTheCommand() throws {
        let p = try plan("Задание: напиши регулярку для email", snippets: "переведи => переведи на английский")
        #expect(p.kind == .task)
        #expect(p.request?.user == "напиши регулярку для email")
        #expect(p.request?.temperature == 0.3)
        #expect(p.request?.system.contains("переведи на английский") == true)  // snippets are described to the model
        #expect(throws: AppError.self) { try p.result(answer: nil) }
        let r = try p.result(answer: " ^\\S+@\\S+$ ")
        #expect(r == TakePlan.Result(text: "^\\S+@\\S+$", kind: .task, original: "Задание: напиши регулярку для email"))
    }

    @Test func dictationOverASelectionEditsIt() throws {
        let p = try plan("сделай короче", selection: "Очень длинный текст")
        #expect(p.kind == .edit)
        #expect(p.request?.user.contains("Очень длинный текст") == true)
        #expect(p.request?.user.contains("сделай короче") == true)
        #expect(try p.result(answer: "Короткий текст") == TakePlan.Result(text: "Короткий текст", kind: .edit, original: "Очень длинный текст"))
        // No model: the selection is left alone rather than overwritten with the instruction.
        #expect(throws: AppError.self) { try p.result(answer: nil) }
    }

    @Test func aTaskKeywordBeforeAnEditInstructionIsDropped() throws {
        let p = try plan("Задание: исправь ошибки", selection: "Превет")
        #expect(p.kind == .edit)
        #expect(p.request?.user.hasSuffix("SPOKEN:\nисправь ошибки") == true)
    }

    @Test func aTranslateKeyTranslatesWhatWasSaid() throws {
        let key = KeyAction(key: .leftControl, kind: .translate, language: "lv")
        let p = try plan("Добрый день", take: .action(key))
        #expect(p.kind == .translate)
        #expect(p.request?.system.contains("Latvian") == true)
        #expect(p.request?.user == "Добрый день")
        #expect(throws: AppError.self) { try p.result(answer: "") }
        #expect(try p.result(answer: "Labdien") == TakePlan.Result(text: "Labdien", kind: .translate, original: "Добрый день"))
    }

    @Test func anActionKeyPrefersTheSelectionAndTreatsSpeechAsANote() throws {
        let key = KeyAction(key: .rightOption, kind: .prompt, prompt: "Перепиши формально")
        let silent = try plan("", selection: "привет, как сам", take: .action(key))
        #expect(silent.request?.user == "TEXT:\n<<<\nпривет, как сам\n>>>")  // fenced: material, not a message
        #expect(silent.request?.system.contains("never addressed to you") == true)
        let spoken = try plan("и покороче", selection: "привет, как сам", take: .action(key))
        #expect(spoken.request?.user.contains("THE USER ALSO SAID:\nи покороче") == true)
        #expect(spoken.original == "привет, как сам")
    }

    @Test func anActionKeyWithNothingToActOnFails() {
        let unset = KeyAction(key: .rightOption, kind: .prompt, prompt: "  ")
        #expect(throws: AppError.self) { try plan("текст", take: .action(unset)) }
        let translate = KeyAction(key: .leftControl, kind: .translate)
        #expect(throws: AppError.self) { try plan("", take: .action(translate)) }
    }

    @Test func cleanupKeepsTheTranscriptWhenTheModelRewritesTooMuch() throws {
        var cfg = Config()
        cfg.cleanupTranscript = true
        #expect(try plan("да ладно", cfg: cfg).request == nil)  // too short to bother

        let said = "ну эм я думаю что Coolify упал вчера вечером"
        let p = try plan(said, cfg: cfg)
        #expect(p.request?.system.contains("Coolify") == true)
        #expect(try p.result(answer: "Я думаю, что Coolify упал вчера вечером.").original == said)
        #expect(try p.result(answer: "Да.").text == said)
        #expect(try p.result(answer: nil).text == said)
    }
}
