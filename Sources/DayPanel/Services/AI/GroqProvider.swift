import Foundation

/// Concrete `LLMProvider` for Groq. Talks to their
/// OpenAI-compatible Chat Completions endpoint:
///
///     POST https://api.groq.com/openai/v1/chat/completions
///     Authorization: Bearer <API_KEY>
///
/// Groq hosts open-source models (Llama 3.3 70B, Mixtral, etc.)
/// with extremely fast inference (300+ tokens/s in some
/// configurations) and a generous free tier — typically:
///   • 30 requests / minute
///   • 14,400 requests / day
///   • 500k tokens / day
///
/// Default model is `llama-3.3-70b-versatile` — strong quality
/// (≈ GPT-4 class on many benchmarks) at hundreds of tokens/sec.
/// For even faster latency on simple Q&A, consider switching the
/// model to `llama-3.1-8b-instant` (~750 t/s, lower quality).
final class GroqProvider: LLMProvider {

    private let endpoint = "https://api.groq.com/openai/v1/chat/completions"
    private let session:  URLSession

    /// Catalogue of models the picker exposes. Each entry
    /// carries the ID Groq expects in `body["model"]` plus a
    /// short label + a hint at its free-tier TPR (tokens-per-
    /// request) ceiling so the user can pick informed.
    struct ModelOption: Identifiable, Hashable {
        let id: String        // wire id, e.g. "llama-3.3-70b-versatile"
        let label: String     // pretty name for the UI
        let trpHint: String   // "TPR ~12K", "TPR ~30K", etc.
        let qualityHint: String // "Top quality", "Fast & light"
    }

    static let availableModels: [ModelOption] = [
        ModelOption(
            id: "llama-3.3-70b-versatile",
            label: "Llama 3.3 70B",
            trpHint: "TPR ~12K",
            qualityHint: "Top quality, ≈ GPT-4 class"
        ),
        ModelOption(
            id: "llama-3.1-8b-instant",
            label: "Llama 3.1 8B Instant",
            trpHint: "TPR ~30K",
            qualityHint: "Rápido, lida com prompt grande"
        ),
        ModelOption(
            id: "openai/gpt-oss-20b",
            label: "GPT-OSS 20B",
            trpHint: "TPR ~12K",
            qualityHint: "Boa qualidade, leitura+raciocínio"
        ),
    ]

    /// Default chosen specifically because most users will hit
    /// 413 on the 70B with Apollo's rich system prompt. The
    /// 8B-instant has the largest free-tier TPR ceiling and
    /// near-instant latency at the cost of some reasoning depth.
    static let defaultModelId = "llama-3.1-8b-instant"

    static let modelDefaultsKey = "dp_groq_model"

    /// Optional override — the auto-fallback path passes this
    /// to make a SECOND attempt with a smaller-TPR model when
    /// the user's chosen model returns 413. Otherwise we read
    /// from UserDefaults via `currentModel`.
    private let modelOverride: String?

    init(model: String? = nil,
         session: URLSession = .shared) {
        self.modelOverride = model
        self.session = session
    }

    /// User's chosen model from Settings → Apollo IA → Groq,
    /// falling back to `defaultModelId` if nothing was picked.
    var currentModel: String {
        if let modelOverride { return modelOverride }
        let stored = UserDefaults.standard.string(forKey: Self.modelDefaultsKey) ?? ""
        return stored.isEmpty ? Self.defaultModelId : stored
    }

    var displayName: String { "Groq (\(prettyModel))" }

    /// Strip the version-suffix noise from `llama-3.3-70b-versatile`
    /// so the user-facing string in Settings/chat is short.
    private var prettyModel: String {
        if let opt = Self.availableModels.first(where: { $0.id == currentModel }) {
            return opt.label
        }
        return currentModel
    }

    var apiKey: String? {
        KeychainHelper.load(for: KeychainHelper.Keys.groqApiKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    var isConfigured: Bool { (apiKey?.count ?? 0) >= 20 }

    // MARK: - Non-streaming completion

    func complete(turns: [ChatTurn]) async throws -> ChatCompletion {
        try await completeOnce(turns: turns, modelOverride: nil)
    }

    /// Inner attempt — `modelOverride: nil` means "use the
    /// user-selected model". On 413 (TPR exceeded) we recurse
    /// once with the safest small-TPR fallback.
    private func completeOnce(turns: [ChatTurn],
                              modelOverride: String?) async throws -> ChatCompletion {
        guard let key = apiKey else { throw LLMError.missingApiKey }

        var req = try makeRequest(turns: turns,
                                   stream: false,
                                   key: key,
                                   modelId: modelOverride ?? currentModel)
        req.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw LLMError.network(error)
        }

        if let http = response as? HTTPURLResponse,
           http.statusCode == 413,
           modelOverride == nil,
           currentModel != Self.tprFallbackModel {
            // Auto-retry ONCE with the smaller-TPR fallback.
            return try await completeOnce(
                turns: turns,
                modelOverride: Self.tprFallbackModel
            )
        }

        try Self.checkResponse(data: data, response: response)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw LLMError.decoding("Resposta do Groq em formato inesperado")
        }

        let usage = json["usage"] as? [String: Any]
        return ChatCompletion(
            text: content,
            inputTokens:  usage?["prompt_tokens"]      as? Int,
            outputTokens: usage?["completion_tokens"]  as? Int
        )
    }

    /// Fallback model used when the user-selected model returns
    /// 413 — pick the option with the largest TPR ceiling so
    /// Apollo's rich system prompt fits.
    static let tprFallbackModel = "llama-3.1-8b-instant"

    // MARK: - Streaming (SSE, OpenAI-style)

    /// Streams Groq's SSE response. Each `data: {...}` line carries
    /// a `choices[0].delta.content` fragment. Final event is
    /// `data: [DONE]`. Usage info comes in the last regular event
    /// when `stream_options.include_usage` is set.
    func stream(turns: [ChatTurn]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let key = apiKey else {
                    continuation.finish(throwing: LLMError.missingApiKey)
                    return
                }

                // Build the open-stream call as a closure so
                // we can repeat it for the 413 fallback path
                // without duplicating the SSE consumer below.
                func openStream(modelId: String)
                    async throws -> (URLSession.AsyncBytes, URLResponse)
                {
                    let req = try makeRequest(turns: turns,
                                               stream: true,
                                               key: key,
                                               modelId: modelId)
                    return try await session.bytes(for: req)
                }

                var bytes: URLSession.AsyncBytes
                var response: URLResponse
                do {
                    (bytes, response) = try await openStream(modelId: currentModel)
                } catch {
                    continuation.finish(throwing: LLMError.network(error))
                    return
                }
                // 413 auto-fallback. The first request used the
                // user-selected model and returned "Payload Too
                // Large" because Apollo's prompt exceeds that
                // model's TPR ceiling. Try once more with the
                // small-TPR fallback so the user gets an answer
                // instead of a hard error.
                if let http = response as? HTTPURLResponse,
                   http.statusCode == 413,
                   currentModel != Self.tprFallbackModel {
                    do {
                        (bytes, response) = try await openStream(
                            modelId: Self.tprFallbackModel
                        )
                    } catch {
                        continuation.finish(throwing: LLMError.network(error))
                        return
                    }
                }
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    // Drain a small chunk of the body so the
                    // error mapping can include the actual
                    // server message.
                    var data = Data()
                    for try await byte in bytes {
                        data.append(byte)
                        if data.count > 4096 { break }
                    }
                    do {
                        try Self.checkResponse(data: data, response: response)
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                    continuation.finish(throwing: Self.errorForStatus(http.statusCode))
                    return
                }

                var inputTokens:  Int? = nil
                var outputTokens: Int? = nil
                var hitLengthLimit = false

                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }

                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let choices = json["choices"] as? [[String: Any]],
                           let first = choices.first {
                            if let delta = first["delta"] as? [String: Any],
                               let content = delta["content"] as? String,
                               !content.isEmpty {
                                continuation.yield(.partial(content))
                            }
                            // OpenAI-compat finish_reason — "length"
                            // means the response hit `max_tokens`.
                            // Mirror Gemini's MAX_TOKENS path so the
                            // chat layer can swap models BEFORE the
                            // truncated bubble settles in front of
                            // the user.
                            if let reason = first["finish_reason"] as? String,
                               reason == "length" {
                                hitLengthLimit = true
                            }
                        }
                        if let usage = json["usage"] as? [String: Any] {
                            inputTokens  = usage["prompt_tokens"]      as? Int
                            outputTokens = usage["completion_tokens"]  as? Int
                        }
                    }
                    if hitLengthLimit {
                        continuation.finish(throwing:
                            LLMError.outputExhausted(partial: "")
                        )
                        return
                    }
                    continuation.yield(.finished(ChatCompletion(
                        text: "",
                        inputTokens:  inputTokens,
                        outputTokens: outputTokens
                    )))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: LLMError.network(error))
                }
            }
        }
    }

    // MARK: - Request helpers

    /// Shared request builder for both streaming and non-streaming
    /// modes — same body shape, only `stream` flag differs.
    private func makeRequest(turns: [ChatTurn],
                             stream: Bool,
                             key: String,
                             modelId: String? = nil) throws -> URLRequest {
        let messages = turns.map { turn -> [String: Any] in
            let role: String = {
                switch turn.role {
                case .system:    return "system"
                case .user:      return "user"
                case .assistant: return "assistant"
                }
            }()
            return ["role": role, "content": turn.text]
        }

        // `max_tokens: 256` was clipping every response after a
        // few sentences. 1024 matches what Gemini gets — plenty
        // of room for a 1-line summary + bulleted list without
        // running out mid-pill.
        var body: [String: Any] = [
            "model": modelId ?? currentModel,
            "messages": messages,
            "temperature": 0.4,
            "max_tokens": 1024,
            "stream": stream,
        ]
        if stream {
            // Ask Groq to include usage in the SSE stream so we
            // get token counts even when streaming.
            body["stream_options"] = ["include_usage": true]
        }

        guard let url = URL(string: endpoint) else {
            throw LLMError.providerMessage("URL inválida")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)",    forHTTPHeaderField: "Authorization")
        if stream {
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private static func checkResponse(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.decoding("Sem resposta HTTP")
        }
        guard !(200..<300).contains(http.statusCode) else { return }

        switch http.statusCode {
        case 401, 403: throw LLMError.invalidApiKey
        case 413:
            // Groq's per-request TPR (tokens per request) limit
            // — Apollo's rich system prompt (workspace data +
            // few-shots + action docs) typically lands at
            // 8-15K tokens, and the free tier of
            // `llama-3.3-70b-versatile` caps each request at
            // ~12K tokens. The error body usually contains the
            // exact "Limit X, Requested Y" — surface it so the
            // user knows whether to switch models or backends.
            let raw = Self.errorMessage(in: data) ?? "Prompt muito grande"
            throw LLMError.providerMessage(
                "Groq não aceitou o prompt — \(raw)\n\nO Apollo carrega muito contexto (tarefas + eventos + comentários). Soluções:\n• Volte para o Gemini (suporta 1M tokens) nas Configurações.\n• Ou troque o modelo Groq pra `llama-3.1-8b-instant` (TPR maior)."
            )
        case 429:
            // Groq returns 429 with body explaining whether it's
            // RPM, TPM, RPD or daily token quota. Surface raw.
            let raw = Self.errorMessage(in: data) ?? "Limite atingido"
            let lower = raw.lowercased()
            if lower.contains("per day") || lower.contains("daily") {
                throw LLMError.providerMessage("Cota diária esgotada — \(raw)")
            }
            if lower.contains("per minute") {
                throw LLMError.providerMessage("Limite por minuto atingido — espere 60s. (\(raw))")
            }
            throw LLMError.providerMessage("Groq 429: \(raw)")
        case 500..<600:
            throw LLMError.providerMessage("Groq retornou \(http.statusCode). Tente novamente.")
        default:
            let raw = Self.errorMessage(in: data) ?? "Erro \(http.statusCode)"
            throw LLMError.providerMessage("Groq \(http.statusCode): \(raw)")
        }
    }

    private static func errorForStatus(_ code: Int) -> LLMError {
        switch code {
        case 401, 403: return .invalidApiKey
        case 413:
            return .providerMessage(
                "Groq não aceitou o prompt (413). O contexto do Apollo excede o limite de tokens-por-requisição do free tier. Volte para o Gemini nas Configurações."
            )
        case 429:      return .rateLimited
        default:       return .providerMessage("Groq retornou \(code)")
        }
    }

    /// Pulls the first useful error message out of Groq's
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
