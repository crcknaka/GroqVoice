import Foundation
import Testing
@testable import GroqVoice

@Suite struct ConfigTests {
    @Test func decodesLegacyKeysAndFillsMissingOnes() throws {
        let json = """
        {"groqApiKey":"k","transcriptionModel":"whisper-large-v3-turbo","chatModel":"llama-3.1-8b-instant",
         "localMode":"off","pttHoldMs":300}
        """
        let cfg = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(cfg.groqApiKey == "k")
        #expect(cfg.transcriptionModels.first == "whisper-large-v3-turbo")
        #expect(cfg.chatModels.first == "llama-3.1-8b-instant")
        #expect(cfg.sttEngine == "groq")      // legacy "off" meant cloud only
        #expect(cfg.pttHoldMs == 300)
        #expect(cfg.hotkey == "fn")            // default filled in
        #expect(cfg.releaseTailMs == 250)
    }

    @Test func translateKeyCannotCollideWithMainKey() {
        var cfg = Config()
        cfg.hotkey = "rightCommand"
        cfg.translateHotkey = "rightCommand"
        #expect(cfg.translateHotkeyKey == nil)
        cfg.translateHotkey = "rightOption"
        #expect(cfg.translateHotkeyKey == .rightOption)
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
}
