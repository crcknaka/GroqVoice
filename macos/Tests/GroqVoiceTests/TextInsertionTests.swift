import Testing
@testable import GroqVoice

@Suite struct SpokenFormattingTests {
    @Test func replacesCommandsWithLineBreaks() {
        #expect(SpokenFormatting.apply("Привет. Новая строка. Как дела?") == "Привет.\nКак дела?")
        #expect(SpokenFormatting.apply("Первый пункт, абзац, второй пункт") == "Первый пункт\n\nвторой пункт")
        #expect(SpokenFormatting.apply("Done, new line. Next") == "Done\nNext")
    }

    @Test func keepsATrailingCommandAndDropsALeadingOne() {
        #expect(SpokenFormatting.apply("Спасибо. С новой строки.") == "Спасибо.\n")
        #expect(SpokenFormatting.apply("Новая строка привет") == "привет")
    }

    @Test func leavesOrdinaryWordsAlone() {
        #expect(SpokenFormatting.apply("Это строка кода в новой версии.") == "Это строка кода в новой версии.")
    }
}

@Suite struct FocusedTextAdjustTests {
    @Test func addsSpaceAndLowercasesWhenContinuingASentence() {
        let ctx = FocusedText(before: "а", after: nil, isEmpty: false)
        #expect(ctx.adjust("Мы пошли домой.") == " мы пошли домой.")
    }

    @Test func keepsCaseAfterSentenceEndAndAddsSpace() {
        let ctx = FocusedText(before: ".", after: nil, isEmpty: false)
        #expect(ctx.adjust("Мы пошли домой.") == " Мы пошли домой.")
    }

    @Test func noLeadingSpaceAfterWhitespaceOrOpeningBracket() {
        #expect(FocusedText(before: " ", after: nil, isEmpty: false).adjust("Привет") == "Привет")
        #expect(FocusedText(before: "(", after: nil, isEmpty: false).adjust("Привет") == "Привет")
        #expect(FocusedText(before: nil, after: nil, isEmpty: true).adjust("Привет") == "Привет")
    }

    @Test func protectsAcronymsAndVocabularyTerms() {
        let ctx = FocusedText(before: ",", after: nil, isEmpty: false)
        #expect(ctx.adjust("API готов") == " API готов")
        #expect(ctx.adjust("Coolify упал", knownTerms: ["Coolify"]) == " Coolify упал")
    }

    @Test func addsSpaceBeforeAFollowingWord() {
        let ctx = FocusedText(before: " ", after: "с", isEmpty: false)
        #expect(ctx.adjust("новое слово") == "новое слово ")
    }
}
