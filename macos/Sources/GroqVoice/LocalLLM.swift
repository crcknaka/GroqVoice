import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Offline task-mode answers via Apple's on-device Foundation Models
/// (macOS 26+, Apple Intelligence). No download, system-managed memory.
enum LocalLLM {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        #endif
        return false
    }

    /// Human-readable availability, e.g. "available" or "unavailable: Apple Intelligence is not enabled".
    static var statusDescription: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "available"
            case .unavailable(let reason): return "unavailable: \(reason)"
            }
        }
        #endif
        return "unavailable: needs macOS 26"
    }

    static func respond(system: String, user: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: system)
            let response = try await session.respond(to: user)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw NSError(domain: "GroqVoice", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence is not available on this Mac"])
    }
}
