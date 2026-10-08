import Foundation
import Testing
@testable import GroqVoice

@Suite struct ConfigTests {
    @Test func fillsMissingKeysWithDefaults() throws {
        let json = """
        {"groqApiKey":"k","pttHoldMs":300,"sttEngine":"groq","hotkey":"rightCommand","someKeyFromTheFuture":1}
        """
        let cfg = try #require(Config.decode(from: Data(json.utf8)))
        #expect(cfg.groqApiKey == "k")
        #expect(cfg.pttHoldMs == 300)
        #expect(cfg.sttEngine == .groq)
        #expect(cfg.hotkey == .rightCommand)
        #expect(cfg.releaseTailMs == 150)       // default filled in
        #expect(cfg.chatModels == Config().chatModels)
    }

    @Test func anInvalidValueCostsOnlyThatKey() throws {
        let json = """
        {"hotkey":"capsLock","pasteMode":"type","historySize":"many","minRecordingSeconds":0.5,
         "keyActions":[{"key":"leftControl","kind":"translate"}]}
        """
        let cfg = try #require(Config.decode(from: Data(json.utf8)))
        #expect(cfg.hotkey == .fn)               // "capsLock" is not a key we know
        #expect(cfg.historySize == 50)           // wrong type
        #expect(cfg.pasteMode == .type)          // the rest survives
        #expect(cfg.minRecordingSeconds == 0.5)
        #expect(cfg.keyActions == [KeyAction(key: .leftControl, kind: .translate, language: "en")])
    }

    @Test func rejectsWhatIsNotJSON() {
        #expect(Config.decode(from: Data("groqApiKey = k".utf8)) == nil)
    }

    @Test func roundTrips() throws {
        var cfg = Config()
        cfg.hotkey = .rightOption
        cfg.keyActions = [KeyAction(key: .leftOption, kind: .prompt, prompt: "Сделай формально")]
        cfg.minRecordingSeconds = 0.3
        let data = try JSONEncoder().encode(cfg)
        let back = try #require(Config.decode(from: data))
        #expect(back.hotkey == .rightOption)
        #expect(back.keyActions == cfg.keyActions)
        #expect(back.minRecordingSeconds == 0.3)
    }

    @Test func keyActionsIgnoreTheMainKey() {
        var cfg = Config()
        cfg.hotkey = .rightCommand
        cfg.setAction(KeyAction(key: .rightCommand, kind: .translate, language: "lv"), for: .rightCommand)
        #expect(cfg.action(for: .rightCommand) == nil)
        #expect(cfg.activeKeyActions.isEmpty)
        cfg.setAction(KeyAction(key: .rightOption, kind: .prompt, prompt: "Сделай формально"), for: .rightOption)
        #expect(cfg.action(for: .rightOption)?.summary == "Сделай формально")
        cfg.setAction(nil, for: .rightOption)
        #expect(cfg.action(for: .rightOption) == nil)
    }

    @Test func chatEndpointHelpers() {
        var cfg = Config()
        #expect(cfg.usesGroqForChat)
        #expect(cfg.chatPort == 443)
        cfg.chatBaseURL = "http://localhost:11434/v1"
        #expect(!cfg.usesGroqForChat)
        #expect(cfg.chatHost == "localhost")
        #expect(cfg.chatPort == 11434)
        #expect(cfg.llmConfigured)  // custom endpoint needs no key
    }

    @Test func aTrailingSlashDoesNotMakeGroqACustomEndpoint() {
        var cfg = Config()
        cfg.chatBaseURL = Config.groqBaseURL + "/"
        #expect(cfg.usesGroqForChat)
        #expect(!cfg.llmConfigured)              // still needs the Groq key
        cfg.chatBaseURL = "http://localhost:11434/v1"
        #expect(!cfg.usesGroqForChat)
        #expect(cfg.llmConfigured)
    }
}
