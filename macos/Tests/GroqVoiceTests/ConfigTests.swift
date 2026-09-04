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
        #expect(cfg.releaseTailMs == 150)
    }

    @Test func migratesRetiredGroqModelList() throws {
        let json = """
        {"chatModels":["llama-3.3-70b-versatile","openai/gpt-oss-120b","llama-3.1-8b-instant"]}
        """
        let cfg = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        // Decoding keeps what the file says; Config.load() swaps the retired default.
        #expect(Config.legacyChatModelLists.contains(cfg.chatModels))
        #expect(Config().chatModels.first == "qwen/qwen3.8-27b")
    }

    @Test func keyActionsIgnoreTheMainKey() {
        var cfg = Config()
        cfg.hotkey = "rightCommand"
        cfg.setAction(KeyAction(key: "rightCommand", kind: "translate", language: "lv"), for: .rightCommand)
        #expect(cfg.action(for: .rightCommand) == nil)
        #expect(cfg.activeKeyActions.isEmpty)
        cfg.setAction(KeyAction(key: "rightOption", kind: "prompt", prompt: "Сделай формально"), for: .rightOption)
        #expect(cfg.action(for: .rightOption)?.summary == "Сделай формально")
        cfg.setAction(nil, for: .rightOption)
        #expect(cfg.action(for: .rightOption) == nil)
    }

    @Test func migratesTheOldTranslateKey() throws {
        let json = """
        {"translateHotkey":"leftControl","translateLanguage":"lv"}
        """
        let cfg = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(cfg.keyActions == [KeyAction(key: "leftControl", kind: "translate", language: "lv")])
        #expect(cfg.action(for: .leftControl)?.summary == "translate into Latvian")
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
