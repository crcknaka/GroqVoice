import Foundation
import Testing
@testable import GroqVoice

@Suite struct GroqClientTests {
    @Test func reasoningIsNotPartOfTheAnswer() {
        #expect(GroqClient.stripReasoning("<think>\nThe user wants Latvian.\n</think>\n\nLabdien") == "Labdien")
        #expect(GroqClient.stripReasoning("  Labdien \n") == "Labdien")
        #expect(GroqClient.stripReasoning("<think>cut off mid-thou") == "")
    }

    @Test func readsTheRetryDelayFromGroqsMessage() {
        #expect(GroqError.parseRetryAfter(response: nil, body: "Please try again in 7m20.5s.") == 441.5)
        #expect(GroqError.parseRetryAfter(response: nil, body: "Please try again in 250ms.") == 1.25)
        #expect(GroqError.parseRetryAfter(response: nil, body: "model not found") == nil)
    }
}
