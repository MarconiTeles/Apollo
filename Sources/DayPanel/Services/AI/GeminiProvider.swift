import Foundation

/// Concrete `LLMProvider` for Google's Gemini API (a.k.a. Google
/// AI Studio). Talks to the v1beta REST endpoint:
///
///     POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key=…
///
/// Model is configurable but defaults to `gemini-2.0-flash` —
/// generous free tier, sub-second latency, supports multi-turn
/// chat with role labels.
final class GeminiProvider: LLMProvider {

    let displayName = "Gemini 2.5 Flash"

    private let primaryModel: String
    private let session: URLSession
    private let endpoint = "https://generativelanguage.googleapis.com/v1beta/models"

    /// Daily-quota cascade. Starts at the user's preferred model
    /// and falls through to lower-tier siblings as each one's
    /// free-tier quota gets burned for the day. Models already
    /// marked exhausted in `GeminiQuotaTracker` are skipped at
    /// request time — no point spending a round-trip on a model
    /// we know is dead until midnight Pacific.
    ///
    /// Free-tier daily limits (May 2026):
    ///   • gemini-2.5-pro   → 100  req/day  (highest quality)
    ///   • gemini-2.5-flash → 250  req/day
    ///   • gemini-2.0-flash → 1500 req/day  (lowest quality)
    ///
    /// The chain is opportunistic: if the user's API key has
    /// `limit: 0` on a fallback model, we'll get a quota 429 on
    /// the first try, mark it exhausted for the day, and move on
    /// — same code path as a real exhaustion. Worst case we
    /// burn one wasted call per fallback per day to discover
    /// what the key actually has access to.
    private var fullChain: [String] {
        switch primaryModel {
        case "gemini-2.5-pro":
            return ["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.0-flash"]
        case "gemini-2.5-flash":
            return ["gemini-2.5-flash", "gemini-2.0-flash"]
        case "gemini-2.0-flash":
            return ["gemini-2.0-flash"]
        default:
            // Unknown / custom model: try it alone. We don't
            // assume a downgrade target for a model we don't
            // recognize since Google may add models that share
            // an unrelated quota bucket.
            return [primaryModel]
        }
    }

    /// Live chain with already-unavailable models filtered out
    /// (daily-quota AND per-minute throttle), so we don't waste
    /// API calls on models we know would bounce a 429 back.
    private var modelChain: [String] {
        let tracker = GeminiQuotaTracker.shared
        let live = fullChain.filter { !tracker.isUnavailable($0) }
        // If everything's unavailable, fall back to the primary
        // anyway — the resulting 429 will surface the right
        // error to the user instead of an empty-chain crash.
        return live.isEmpty ? [primaryModel] : live
    }

    init(model: String = "gemini-2.5-flash",
         session: URLSession = .shared) {
        // Default model: `gemini-2.5-flash` — Google's current
        // best free-tier balance of speed + quality for chat
        // workloads. Native 1M-token context (way more than we
        // need), strong multilingual including PT-BR, sub-2s
        // first-token latency on a typical home connection,
        // and the AI Studio free tier covers normal personal
        // use without billing setup.
        self.primaryModel = model
        self.session = session
    }

    // MARK: - Retry logic

    /// Maximum number of retries per model. Combined with the
    /// model fallback chain (3 models) this gives the user up
    /// to 12 attempts before surfacing a hard error.
    private static let maxRetriesPerModel = 3

    /// True iff the HTTP status code indicates a TRANSIENT
    /// failure that warrants an automatic retry. Distinguishes
    /// "service overloaded right now, try again in a sec" from
    /// "your request is fundamentally wrong, fix it".
    private static func isTransient(statusCode: Int) -> Bool {
        switch statusCode {
        case 408,             // request timeout
             425,             // too early
             429,             // rate-limited (caller checks for per-minute vs per-day)
             500, 502, 503, 504:
            return true
        default:
            return false
        }
    }

    /// Same idea for URLError — transient network failures get
    /// retried, hard ones (cancelled, bad URL, etc) propagate
    /// immediately.
    private static func isTransient(error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed,
             .cannotConnectToHost, .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    /// Reads the server's retry hint. Gemini sends it in TWO
    /// possible places:
    ///   • `Retry-After` header (RFC 7231) — sometimes set
    ///   • Inline in the JSON body: "Please retry in 58.83s"
    /// We prefer the body hint because Google often only sets
    /// that one. If neither is present, returns nil.
    private static func retryAfterSeconds(in response: URLResponse?,
                                          data: Data? = nil) -> TimeInterval? {
        if let http = response as? HTTPURLResponse,
           let value = http.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(value) {
            return seconds
        }
        // Body inspection fallback.
        if let data,
           let raw = errorMessage(in: data) {
            // Match "retry in 58.83s" or "retry in 60s".
            let pattern = #"retry in (\d+(?:\.\d+)?)s"#
            if let regex = try? NSRegularExpression(pattern: pattern,
                                                    options: .caseInsensitive),
               let m = regex.firstMatch(in: raw,
                                         range: NSRange(raw.startIndex..., in: raw)),
               m.numberOfRanges > 1,
               let r = Range(m.range(at: 1), in: raw),
               let seconds = TimeInterval(raw[r]) {
                return seconds
            }
        }
        return nil
    }

    /// True iff a 429 carries a "per day" / "daily quota" hint
    /// — those aren't worth retrying since the next attempt is
    /// guaranteed to fail until midnight Pacific.
    private static func isDailyQuotaExhausted(_ data: Data) -> Bool {
        guard let raw = errorMessage(in: data) else { return false }
        let lower = raw.lowercased()
        return lower.contains("per day") || lower.contains("daily")
    }

    /// Sleeps for `seconds` seconds in a Task-cancellation-aware
    /// way. Caps the actual sleep at 8s so a server returning
    /// `Retry-After: 60` doesn't freeze the chat for a minute.
    private static func sleep(seconds: TimeInterval) async throws {
        let capped = min(8, max(0.5, seconds))
        try await Task.sleep(nanoseconds: UInt64(capped * 1_000_000_000))
    }

    /// Performs the URLSession round-trip with built-in retry
    /// across the model fallback chain. The `buildBody` closure
    /// receives the model id so it can interpolate it into the
    /// URL or the JSON body. Returns the first 2xx response
    /// encountered, or throws the last terminal error.
    private func sendWithRetry(
        path: String,  // "generateContent" or "streamGenerateContent"
        extraQueryItems: [URLQueryItem] = [],
        buildBody: () throws -> [String: Any]
    ) async throws -> (Data, URLResponse, String) {
        guard let key = apiKey, !key.isEmpty else {
            throw LLMError.missingApiKey
        }

        var lastError: Error = LLMError.providerMessage("Tentativas esgotadas")

        for model in modelChain {
            for attempt in 0...Self.maxRetriesPerModel {
                guard !Task.isCancelled else { throw CancellationError() }

                guard var components = URLComponents(string: "\(endpoint)/\(model):\(path)") else {
                    throw LLMError.providerMessage("URL inválida")
                }
                components.queryItems = [URLQueryItem(name: "key", value: key)] + extraQueryItems
                guard let url = components.url else {
                    throw LLMError.providerMessage("URL inválida")
                }

                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if extraQueryItems.contains(where: { $0.name == "alt" && $0.value == "sse" }) {
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                }
                do {
                    req.httpBody = try JSONSerialization.data(
                        withJSONObject: try buildBody()
                    )
                } catch {
                    throw LLMError.network(error)
                }
                req.timeoutInterval = 60

                do {
                    let (data, response) = try await session.data(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.decoding("Sem resposta HTTP")
                    }
                    if (200..<300).contains(http.statusCode) {
                        GeminiQuotaTracker.shared.setActive(model, preferred: primaryModel)
                        return (data, response, model)
                    }
                    // Daily quota: mark this model dead for the
                    // rest of the Pacific day and let the outer
                    // loop fall through to the next model in the
                    // cascade. If we're already on the last
                    // model, the retry exits and we surface a
                    // user-visible error.
                    if http.statusCode == 429,
                       Self.isDailyQuotaExhausted(data) {
                        GeminiQuotaTracker.shared.markExhausted(model)
                        let isLast = (model == modelChain.last)
                        if isLast {
                            throw LLMError.providerMessage(
                                "Cota diária do Gemini esgotada em todos os modelos disponíveis. Volta amanhã (reset à 1h da manhã BRT) ou troque para o backend embutido nas Configurações."
                            )
                        }
                        lastError = LLMError.providerMessage(
                            "Cota diária esgotada em \(model)"
                        )
                        break  // try next model in chain
                    }
                    let serverHint = Self.retryAfterSeconds(in: response, data: data)
                    // 429 with a long server-side cooldown (e.g.
                    // "retry in 58s") means the user is hitting a
                    // per-minute window. Auto-waiting 58s would
                    // freeze the chat. Mark this model throttled
                    // for the hint duration and fall through to
                    // the next model in the cascade — same path
                    // as the daily-quota handler above. If we're
                    // already on the last model, throw
                    // `outputExhausted` so the chat layer swaps
                    // to a different provider altogether.
                    if http.statusCode == 429,
                       let hint = serverHint, hint > 10 {
                        GeminiQuotaTracker.shared.markThrottled(model, forSeconds: hint)
                        let isLast = (model == modelChain.last)
                        if isLast {
                            throw LLMError.outputExhausted(partial: "")
                        }
                        lastError = LLMError.providerMessage(
                            "Limite por minuto em \(model)"
                        )
                        break  // try next model in chain
                    }
                    if Self.isTransient(statusCode: http.statusCode),
                       attempt < Self.maxRetriesPerModel {
                        let backoff = serverHint ?? pow(2.0, Double(attempt))
                        try await Self.sleep(seconds: backoff)
                        continue
                    }
                    // Non-retriable or out of retries on this model.
                    let raw = Self.errorMessage(in: data) ?? "erro \(http.statusCode)"
                    lastError = LLMError.providerMessage("Gemini \(http.statusCode): \(raw)")
                    break  // try next model in chain
                } catch let urlError as URLError {
                    if Self.isTransient(error: urlError),
                       attempt < Self.maxRetriesPerModel {
                        let backoff = pow(2.0, Double(attempt))
                        try await Self.sleep(seconds: backoff)
                        continue
                    }
                    lastError = LLMError.network(urlError)
                    break
                } catch {
                    if error is CancellationError { throw error }
                    if let llm = error as? LLMError { throw llm }
                    lastError = error
                    break
                }
            }
        }
        throw lastError
    }

    var apiKey: String? {
        KeychainHelper.load(for: KeychainHelper.Keys.geminiApiKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    var isConfigured: Bool { (apiKey?.count ?? 0) >= 20 }

    // MARK: - Completion

    func complete(turns: [ChatTurn]) async throws -> ChatCompletion {
        // Build the JSON body once — same payload for every
        // attempt across the retry/fallback ladder.
        let systemText = turns
            .filter { $0.role == .system }
            .map(\.text)
            .joined(separator: "\n\n")
        let convoTurns = turns.filter { $0.role != .system }
        let contents = convoTurns.map { turn -> [String: Any] in
            [
                "role": turn.role == .assistant ? "model" : "user",
                "parts": [["text": turn.text]],
            ]
        }

        let (data, _, _) = try await sendWithRetry(path: "generateContent") {
            var body: [String: Any] = [
                "contents": contents,
                "generationConfig": [
                    "temperature": 0.4,
                    "maxOutputTokens": 8192,
                ],
            ]
            if !systemText.isEmpty {
                body["system_instruction"] = [
                    "parts": [["text": systemText]],
                ]
            }
            return body
        }

        // Decode happy-path response.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decoding("JSON malformado")
        }
        let candidates = json["candidates"] as? [[String: Any]] ?? []
        guard let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.compactMap({ $0["text"] as? String }).first
        else {
            // Sometimes Gemini returns no candidate when the prompt
            // is blocked by safety filters; surface that explicitly.
            if let promptFeedback = json["promptFeedback"] as? [String: Any],
               let blockReason = promptFeedback["blockReason"] as? String {
                throw LLMError.providerMessage("Bloqueado pelo filtro de segurança: \(blockReason)")
            }
            throw LLMError.decoding("Sem texto na resposta")
        }

        let usage = json["usageMetadata"] as? [String: Any]
        return ChatCompletion(
            text: text,
            inputTokens:  usage?["promptTokenCount"]      as? Int,
            outputTokens: usage?["candidatesTokenCount"]  as? Int
        )
    }

    // MARK: - Streaming (SSE via streamGenerateContent)

    /// Streams Gemini's `streamGenerateContent` endpoint as
    /// Server-Sent Events. Each `data: {...}` line carries a
    /// `candidates[0].content.parts[0].text` delta. The final
    /// `usageMetadata` arrives in the last event before stream
    /// closes.
    func stream(turns: [ChatTurn]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let key = apiKey, !key.isEmpty else {
                    continuation.finish(throwing: LLMError.missingApiKey)
                    return
                }

                let systemText = turns
                    .filter { $0.role == .system }
                    .map(\.text)
                    .joined(separator: "\n\n")

                let convoTurns = turns.filter { $0.role != .system }
                let contents = convoTurns.map { turn -> [String: Any] in
                    [
                        "role": turn.role == .assistant ? "model" : "user",
                        "parts": [["text": turn.text]],
                    ]
                }

                var bodyDict: [String: Any] = [
                    "contents": contents,
                    "generationConfig": [
                        "temperature": 0.4,
                        "maxOutputTokens": 8192,
                    ],
                ]
                if !systemText.isEmpty {
                    bodyDict["system_instruction"] = ["parts": [["text": systemText]]]
                }

                // Retry / fallback ladder for the INITIAL
                // connection. We can only retry up to the point
                // the server starts pushing tokens — once the
                // stream is open we'd need to discard partial
                // output to retry, which is worse UX than just
                // surfacing the error. The retry helper handles
                // 503 / 429-per-minute / network blips here so
                // a transient overload at one model triggers an
                // automatic fallthrough to gemini-2.0-flash and
                // then gemini-1.5-flash before giving up.
                let bytes: URLSession.AsyncBytes
                do {
                    bytes = try await self.openStream(
                        body: bodyDict,
                        key: key
                    )
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                var inputTokens:  Int? = nil
                var outputTokens: Int? = nil
                var finishReason: String? = nil
                var blockReason:  String? = nil

                do {
                    for try await line in bytes.lines {
                        // SSE format: "data: {...}". Empty lines
                        // separate events; `data: [DONE]` ends.
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }

                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let candidates = json["candidates"] as? [[String: Any]],
                           let first = candidates.first {
                            // Capture finishReason — non-STOP
                            // values mean the model abandoned
                            // the turn early (SAFETY filter,
                            // recitation block, MAX_TOKENS, OTHER).
                            // We previously ignored these, so
                            // truncated answers (the response
                            // ended with "A" because the next
                            // token was filtered) just looked
                            // like the model "stopped randomly".
                            if let reason = first["finishReason"] as? String,
                               reason != "STOP", reason != "FINISH_REASON_UNSPECIFIED" {
                                finishReason = reason
                            }
                            if let content = first["content"] as? [String: Any],
                               let parts = content["parts"] as? [[String: Any]] {
                                for part in parts {
                                    if let text = part["text"] as? String, !text.isEmpty {
                                        continuation.yield(.partial(text))
                                    }
                                }
                            }
                        }
                        // Top-level promptFeedback can also carry
                        // a hard block (the WHOLE prompt was
                        // rejected — usually means a system
                        // prompt content tripped a filter).
                        if let pf = json["promptFeedback"] as? [String: Any],
                           let reason = pf["blockReason"] as? String {
                            blockReason = reason
                        }
                        if let usage = json["usageMetadata"] as? [String: Any] {
                            inputTokens  = usage["promptTokenCount"]     as? Int
                            outputTokens = usage["candidatesTokenCount"] as? Int
                        }
                    }

                    // Surface abnormal stops to the user. Emit a
                    // tagged trailer chunk that the chat layer
                    // can render as a warning under the message.
                    if let blockReason {
                        continuation.yield(.partial(
                            "\n\n⚠ Gemini bloqueou a resposta: \(blockReason). Reformule a pergunta ou troque de modelo nas Configurações."
                        ))
                    } else if finishReason == "MAX_TOKENS" {
                        // Don't surface a "truncated answer"
                        // warning to the user — throw so the
                        // chat layer swaps to a higher-budget
                        // fallback model and re-runs the same
                        // payload BEFORE the bubble settles.
                        continuation.finish(throwing:
                            LLMError.outputExhausted(partial: "")
                        )
                        return
                    } else if let finishReason {
                        let human: String
                        switch finishReason {
                        case "SAFETY":
                            human = "filtro de segurança do Google — reformule ou troque para Groq nas Configurações"
                        case "RECITATION":
                            human = "filtro anti-plágio do Google interrompeu a resposta"
                        default:
                            human = "interrompido (\(finishReason))"
                        }
                        continuation.yield(.partial(
                            "\n\n⚠ Resposta truncada: \(human)."
                        ))
                    }

                    continuation.yield(.finished(ChatCompletion(
                        text: "",
                        inputTokens: inputTokens,
                        outputTokens: outputTokens
                    )))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: LLMError.network(error))
                }
            }
        }
    }

    // MARK: - Helpers

    /// Opens an SSE stream against the Gemini endpoint with the
    /// same retry + fallback ladder as `sendWithRetry`.
    /// Returns a live byte stream once the server commits to a
    /// successful response. On terminal failure throws the most
    /// recent error.
    private func openStream(body: [String: Any], key: String) async throws -> URLSession.AsyncBytes {
        var lastError: Error = LLMError.providerMessage("Tentativas esgotadas")

        for model in modelChain {
            for attempt in 0...Self.maxRetriesPerModel {
                guard !Task.isCancelled else { throw CancellationError() }

                guard var components = URLComponents(string: "\(endpoint)/\(model):streamGenerateContent") else {
                    throw LLMError.providerMessage("URL inválida")
                }
                components.queryItems = [
                    URLQueryItem(name: "key", value: key),
                    URLQueryItem(name: "alt", value: "sse"),
                ]
                guard let url = components.url else {
                    throw LLMError.providerMessage("URL inválida")
                }

                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                do {
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                } catch {
                    throw LLMError.network(error)
                }
                req.timeoutInterval = 60

                do {
                    let (bytes, response) = try await session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.decoding("Sem resposta HTTP")
                    }
                    if (200..<300).contains(http.statusCode) {
                        GeminiQuotaTracker.shared.setActive(model, preferred: primaryModel)
                        return bytes
                    }
                    // Drain to read the error body for diagnostics.
                    var data = Data()
                    for try await byte in bytes {
                        data.append(byte)
                        if data.count > 4096 { break }
                    }
                    if http.statusCode == 429,
                       Self.isDailyQuotaExhausted(data) {
                        GeminiQuotaTracker.shared.markExhausted(model)
                        let isLast = (model == modelChain.last)
                        if isLast {
                            throw LLMError.providerMessage(
                                "Cota diária do Gemini esgotada em todos os modelos disponíveis. Volta amanhã (reset à 1h da manhã BRT) ou troque para o backend embutido nas Configurações."
                            )
                        }
                        lastError = LLMError.providerMessage(
                            "Cota diária esgotada em \(model)"
                        )
                        break  // try next model in chain
                    }
                    let serverHint = Self.retryAfterSeconds(in: response, data: data)
                    // Per-minute rate limit (long server-side
                    // cooldown). Mark this model throttled for
                    // the hint duration and fall through to the
                    // next model in the cascade — same path as
                    // the daily-quota handler above. Only when
                    // we've exhausted the chain do we throw
                    // `outputExhausted` to let the chat layer
                    // swap to a different provider altogether.
                    // (Streaming-path twin of the identical
                    // handler in `sendWithRetry`.)
                    if http.statusCode == 429,
                       let hint = serverHint, hint > 10 {
                        GeminiQuotaTracker.shared.markThrottled(model, forSeconds: hint)
                        let isLast = (model == modelChain.last)
                        if isLast {
                            throw LLMError.outputExhausted(partial: "")
                        }
                        lastError = LLMError.providerMessage(
                            "Limite por minuto em \(model)"
                        )
                        break  // try next model in chain
                    }
                    if Self.isTransient(statusCode: http.statusCode),
                       attempt < Self.maxRetriesPerModel {
                        let backoff = serverHint ?? pow(2.0, Double(attempt))
                        try await Self.sleep(seconds: backoff)
                        continue
                    }
                    let raw = Self.errorMessage(in: data) ?? "erro \(http.statusCode)"
                    lastError = LLMError.providerMessage("Gemini \(http.statusCode): \(raw)")
                    break  // try next model in chain
                } catch let urlError as URLError {
                    if Self.isTransient(error: urlError),
                       attempt < Self.maxRetriesPerModel {
                        let backoff = pow(2.0, Double(attempt))
                        try await Self.sleep(seconds: backoff)
                        continue
                    }
                    lastError = LLMError.network(urlError)
                    break
                } catch {
                    if error is CancellationError { throw error }
                    if let llm = error as? LLMError { throw llm }
                    lastError = error
                    break
                }
            }
        }
        throw lastError
    }

    /// Pulls the first useful error message out of Gemini's
    /// `{"error":{"message":"…"}}` envelope, when present.
    private static func errorMessage(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let err = json["error"] as? [String: Any] {
            return err["message"] as? String
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
