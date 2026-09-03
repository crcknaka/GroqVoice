import Testing
@testable import GroqVoice

@Suite struct TaskRouterTests {
    let keywords = ["task", "задача", "задание"]

    @Test func keywordAtStartTriggersTaskMode() {
        #expect(TaskRouter.taskQuery(from: "Задание: переведи на английский привет", keywords: keywords, maxPosition: 3)
                == "переведи на английский привет")
        #expect(TaskRouter.taskQuery(from: "task write a regex", keywords: keywords, maxPosition: 3) == "write a regex")
    }

    @Test func leadInWordsAreAllowed() {
        #expect(TaskRouter.taskQuery(from: "выполни задание, нарисуй кошку", keywords: keywords, maxPosition: 3) == "нарисуй кошку")
    }

    @Test func keywordInsideOrdinarySpeechIsNotATask() {
        #expect(TaskRouter.taskQuery(from: "а если задание сложное, то отложим", keywords: keywords, maxPosition: 3) == nil)
        #expect(TaskRouter.taskQuery(from: "мне выдали задание на завтра", keywords: keywords, maxPosition: 3) == nil)
    }

    @Test func emptyCommandIsNotATask() {
        #expect(TaskRouter.taskQuery(from: "задание", keywords: keywords, maxPosition: 3) == nil)
    }
}
