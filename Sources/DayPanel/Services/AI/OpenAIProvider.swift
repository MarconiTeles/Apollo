import Foundation

/// Concrete `LLMProvider` for OpenAI's Chat Completions API.
///
///     POST https://api.openai.com/v1/chat/completions
///
/// Default model `gpt-4o-mini` — best price/quality balance for
/// Apollo's workload (~25K input tokens of context + ~500 output
/// tokens per chat ≈ $0.005 per request). Drop-in compatible with
/// any OpenAI-compatible endpoint (OpenRouter, Together, etc.) by
/// swapping the API key + endpoint in Settings.
final class OpenAIProvider: LLMProvider {

    let displayName: String

    private let primaryModel: String
    private let session: URLSession
    private let endpoint = "https://api.openai.com/v1/chat/completions"

    /// User's chosen OpenAI model from Settings, or the default.
    static let modelDefaultsKey = "dp_openai_model"
    static let defaultModelId   = "gpt-4o-mini"

    /// Catalogue surfaced in Settings as a radio-style picker.
    /// Pricing comments are May 2026 ballpark — update if the
    /// official price page changes.
    struct ModelOption: Identifiable, Equatable {
        let id: String
        let label: String
        let priceHint: String
        let qualityHint: String
    }
    static let availableModels: [ModelOption] = [
        ModelOption(id: "gpt-4o-mini",
                    label: "GPT-4o mini",
                    priceHint: "≈ $0.005/chat",
                    qualityHint: "Rápido, barato, qualidade muito boa"),
        ModelOption(id: "gpt-4o",
                    label: "GPT-4o",
                    priceHint: "≈ $0.13/chat",
                    qualityHint: "Top-tier, raciocínio mais forte"),
        ModelOption(id: "gpt-5",
                    label: "GPT-5",
                    priceHint: "≈ $0.20+/chat",
                    qualityHint: "Estado da arte. Mais lento."),
    ]

    init(model: String? = nil, session: URLSession = .shared) {
        let resolvedModel: String
        if let model {
            resolvedModel = model
        } else {
            let stored = UserDefaults.standard.string(forKey: Self.modelDefaultsKey) ?? ""
            resolvedModel = stored.isEmpty ? Self.defaultModelId : stored
        }
        self.primaryModel = resolvedModel
        let label = Self.availableModels
            .first(where: { $0.id == resolvedModel })?.label
            ?? resolvedModel
        self.displayName = label
        self.session = session
    }

    var isConfigured: Bool {
        let key = KeychainHelper.load(for: KeychainHelper.Keys.openaiApiKey) ?? ""
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Non-streaming

    func complete(turns: [ChatTurn]) async throws -> ChatCompletion {
        guard let key = KeychainHelper.load(for: KeychainHelper.Keys.openaiApiKey),
              !key.isEmpty
        else { throw LLMError.missingApiKey }

        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60

        let body: [String: Any] = [
            "model": primaryModel,
            "messages": Self.makeMessages(from: turns),
            "stream": false,
            "temperature": 0.4,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.decoding("Sem resposta HTTP")
        }
        if http.statusCode == 401 { throw LLMError.invalidApiKey }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.errorFromBody(data, status: http.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw LLMError.decoding("JSON malformado") }

        let usage = json["usage"] as? [String: Any]
        return ChatCompletion(
            text: content,
            inputTokens: usage?["prompt_tokens"] as? Int,
            outputTokens: usage?["completion_tokens"] as? Int
        )
    }

    // MARK: - Streaming (SSE)

    func stream(turns: [ChatTurn]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let key = KeychainHelper.load(for: KeychainHelper.Keys.openaiApiKey),
                      !key.isEmpty
                else {
                    continuation.finish(throwing: LLMError.missingApiKey)
                    return
                }

                var req = URLRequest(url: URL(string: endpoint)!)
                req.httpMethod = "POST"
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                req.timeoutInterval = 120

                let body: [String: Any] = [
                    "model": primaryModel,
                    "messages": Self.makeMessages(from: turns),
                    "stream": true,
                    "stream_options": ["include_usage": true],
                    "temperature": 0.4,
                ]
                do {
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                } catch {
                    continuation.finish(throwing: LLMError.network(error))
                    return
                }

                let bytes: URLSession.AsyncBytes
                let response: URLResponse
                do {
                    (bytes, response) = try await session.bytes(for: req)
                } catch {
                    continuation.finish(throwing: LLMError.network(error))
                    return
                }
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    if http.statusCode == 401 {
                        continuation.finish(throwing: LLMError.invalidApiKey)
                        return
                    }
                    var collected = Data()
                    if let drained = try? await Self.drain(bytes) {
                        collected = drained
                    }
                    continuation.finish(throwing: Self.errorFromBody(
                        collected, status: http.statusCode
                    ))
                    return
                }

                var inputTokens:  Int? = nil
                var outputTokens: Int? = nil
                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let choices = json["choices"] as? [[String: Any]],
                           let first = choices.first,
                           let delta = first["delta"] as? [String: Any],
                           let chunk = delta["content"] as? String,
                           !chunk.isEmpty {
                            continuation.yield(.partial(chunk))
                        }
                        if let usage = json["usage"] as? [String: Any] {
                            inputTokens  = usage["prompt_tokens"]      as? Int
                            outputTokens = usage["completion_tokens"]  as? Int
                        }
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

    // MARK: - Helpers

    /// Maps Apollo's `ChatTurn` array onto the OpenAI-compatible
    /// messages format. Roles map 1:1 (`system`, `user`,
    /// `assistant`).
    private static func makeMessages(from turns: [ChatTurn]) -> [[String: Any]] {
        turns.map { turn in
            [
                "role": Self.role(for: turn.role),
                "content": turn.text,
            ]
        }
    }

    private static func role(for chatRole: ChatRole) -> String {
        switch chatRole {
        case .system:    return "system"
        case .user:      return "user"
        case .assistant: return "assistant"
        }
    }

    /// Translates an OpenAI error response into the most accurate
    /// `LLMError` we can offer the user. OpenAI returns 429 for two
    /// completely different situations — actual throttling and
    /// `insufficient_quota` (chave válida mas conta sem créditos),
    /// and a generic "rate limited" string would be misleading for
    /// the latter, so we always surface the real message body.
    private static func errorFromBody(_ data: Data, status: Int) -> LLMError {
        let parsed = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
        let message = parsed?["message"] as? String
        let code    = parsed?["code"]    as? String
        let type    = parsed?["type"]    as? String

        if status == 429, code == "insufficient_quota" || type == "insufficient_quota" {
            return .providerMessage(
                "Conta OpenAI sem créditos. Adicione um método de pagamento em platform.openai.com/account/billing — a chave está OK, falta saldo."
            )
        }
        if status == 429 {
            if let message, !message.isEmpty {
                return .providerMessage("OpenAI: \(message)")
            }
            return .rateLimited
        }
        if status == 404, let message {
            return .providerMessage("Modelo indisponível: \(message)")
        }
        if let message, !message.isEmpty {
            return .providerMessage("OpenAI \(status): \(message)")
        }
        return .providerMessage("OpenAI retornou \(status)")
    }

    /// Drains a streaming `AsyncBytes` into a single `Data` buffer
    /// — used only in the error path so we can parse the JSON the
    /// server returned alongside its non-2xx status.
    private static func drain(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var out = Data()
        for try await byte in bytes {
            out.append(byte)
            if out.count > 16_384 { break }
        }
        return out
    }
}
