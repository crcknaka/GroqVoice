import Foundation

struct GroqError: LocalizedError {
    let status: Int
    let body: String
    let retryAfter: TimeInterval?

    var errorDescription: String? { "HTTP \(status): \(body.prefix(400))" }

    /// 429 = rate limit, 404/400 = model not found / decommissioned,
    /// 498/503 = capacity — all worth trying the next model in the chain.
    var shouldFallback: Bool {
        status == 429 || status == 404 || status == 498 || status == 503
            || (status == 400 && body.contains("decommissioned"))
    }

    var suggestedCooldown: TimeInterval {
        if status == 404 || status == 400 { return 3600 }  // model gone — don't retry soon
        return retryAfter ?? 300
    }

    /// Parses "retry-after" header or Groq's "Please try again in 7m20.518s" body text.
    static func parseRetryAfter(response: HTTPURLResponse?, body: String) -> TimeInterval? {
        if let h = response?.value(forHTTPHeaderField: "retry-after"), let s = TimeInterval(h) {
            return s
        }
        let pattern = #"try again in (?:(\d+)m)?([\d.]+)(ms|s)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) else {
            return nil
        }
        func group(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: body) else { return nil }
            return String(body[r])
        }
        let minutes = Double(group(1) ?? "") ?? 0
        var value = Double(group(2) ?? "") ?? 0
        if group(3) == "ms" { value /= 1000 }
        return minutes * 60 + value + 1  // +1s of slack
    }
}

final class GroqClient {
    var apiKey: String
    /// Chat completions endpoint (OpenAI-compatible) and its key; STT always goes to Groq.
    var chatBaseURL: String
    var chatApiKey: String
    private var sttChain: ModelChain
    private var chatChain: ModelChain

    init(apiKey: String, transcriptionModels: [String], chatModels: [String],
         chatBaseURL: String = Config.groqBaseURL, chatApiKey: String = "") {
        self.apiKey = apiKey
        self.chatBaseURL = chatBaseURL
        self.chatApiKey = chatApiKey
        self.sttChain = ModelChain(transcriptionModels)
        self.chatChain = ModelChain(chatModels)
    }

    /// Re-reads everything network-related from a saved config.
    func apply(_ cfg: Config) {
        apiKey = cfg.groqApiKey
        chatBaseURL = cfg.chatBaseURL
        chatApiKey = cfg.effectiveChatApiKey
        sttChain = ModelChain(cfg.transcriptionModels)
        chatChain = ModelChain(cfg.chatModels)
    }

    func transcribe(wav: Data, language: String, prompt: String) async throws -> String {
        try await withFallback(chain: sttChain, kind: "STT") { model in
            try await self.transcribeOnce(wav: wav, model: model, language: language, prompt: prompt)
        }
    }

    func chat(userText: String, systemPrompt: String, temperature: Double = 0.3) async throws -> String {
        try await withFallback(chain: chatChain, kind: "chat") { model in
            try await self.chatOnce(userText: userText, model: model, systemPrompt: systemPrompt, temperature: temperature)
        }
    }

    /// Tries each candidate model in priority order. A model that rate-limits
    /// gets a cooldown and the next one is tried; once the cooldown expires the
    /// stronger model is automatically preferred again.
    private func withFallback<T>(chain: ModelChain, kind: String,
                                 _ op: (String) async throws -> T) async throws -> T {
        var lastError: Error?
        for model in chain.candidates() {
            do {
                let result = try await op(model)
                if lastError != nil { Log.write("\(kind): succeeded on fallback model \(model)") }
                return result
            } catch let e as GroqError where e.shouldFallback {
                chain.markUnavailable(model, for: e.suggestedCooldown)
                Log.write("\(kind): \(model) unavailable (HTTP \(e.status), cooldown \(Int(e.suggestedCooldown))s) → trying next model")
                lastError = e
            }
        }
        throw lastError ?? GroqError(status: 0, body: "no models configured", retryAfter: nil)
    }

    // MARK: - Networking with transient-error retry

    /// URLSession reuses pooled HTTP/2 connections; Groq closes idle ones, so a
    /// request can hit a dead socket and throw "network connection lost". These
    /// errors are spurious — a retry opens a fresh connection and succeeds.
    /// Retrying here avoids falling back to local Whisper on a healthy network.
    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost, .timedOut, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed,
             .resourceUnavailable, .badServerResponse:
            return true
        default:
            return false
        }
    }

    private func send(_ req: URLRequest, uploading body: Data? = nil, maxRetries: Int = 2) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            do {
                if let body { return try await URLSession.shared.upload(for: req, from: body) }
                return try await URLSession.shared.data(for: req)
            } catch let e as URLError where Self.isTransient(e) && attempt < maxRetries {
                attempt += 1
                Log.write("Groq: transient network error (\(e.code.rawValue)), retry \(attempt)/\(maxRetries)")
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 400_000_000)
            }
        }
    }

    // MARK: - Single-model calls

    private func transcribeOnce(wav: Data, model: String, language: String, prompt: String) async throws -> String {
        let url = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        req.timeoutInterval = 25  // backstop: don't hang if the link dies mid-upload
        let boundary = "GroqVoice-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func addField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        addField("model", model)
        addField("response_format", "json")
        if !language.isEmpty { addField("language", language) }
        if !prompt.isEmpty { addField("prompt", prompt) }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let (data, resp) = try await send(req, uploading: body)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard status == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw GroqError(status: status, body: bodyText,
                            retryAfter: GroqError.parseRetryAfter(response: http, body: bodyText))
        }
        struct R: Decodable { let text: String }
        let r = try JSONDecoder().decode(R.self, from: data)
        return r.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func chatOnce(userText: String, model: String, systemPrompt: String, temperature: Double) async throws -> String {
        let base = chatBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        guard let url = URL(string: (base.isEmpty ? Config.groqBaseURL : base) + "/chat/completions") else {
            throw GroqError(status: 0, body: "invalid chat endpoint URL: \(chatBaseURL)", retryAfter: nil)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let key = chatApiKey.isEmpty ? apiKey : chatApiKey
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 25  // backstop: don't hang if the link dies mid-request

        let payload: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await send(req)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard status == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw GroqError(status: status, body: bodyText,
                            retryAfter: GroqError.parseRetryAfter(response: http, body: bodyText))
        }
        struct R: Decodable {
            struct Choice: Decodable {
                struct Msg: Decodable { let content: String }
                let message: Msg
            }
            let choices: [Choice]
        }
        let r = try JSONDecoder().decode(R.self, from: data)
        return r.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
