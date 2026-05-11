import Foundation

/// Concrete `LLMProvider` for Ollama running locally on
/// `http://localhost:11434`. Talks to the standard `/api/chat`
/// endpoint with `stream: false` so we get one response per
/// request — simpler than the streaming SSE protocol and
/// perfectly fine for a chat-style agent.
///
/// Setup the user does (one time):
///
///     brew install ollama
///     ollama serve              # runs as a launchd service
///     ollama pull llama3.1:8b   # ≈ 4.7 GB, ~30 t/s on M-series
///
/// Recommended models (all run locally, no network):
///   • `llama3.1:8b`    — balanced quality, solid PT-BR
///   • `llama3.2:3b`    — faster on lower-RAM Macs
///   • `qwen2.5:14b`    — best PT-BR + reasoning, needs 16GB+
///   • `phi4:14b`       — strong reasoning, similar footprint
///   • `mistral:7b`     — lightweight, decent multilingual
final class OllamaProvider: LLMProvider {

    private let session: URLSession
    private let host: URL
    /// Model identifier (Ollama's `model` field, e.g.
    /// `"llama3.1:8b"`). Read at call-time from UserDefaults so
    /// the user can swap models in Settings without rebuilding.
    private static let modelDefaultsKey = "dp_ollama_model"
    private static let defaultModel = "llama3.1:8b"

    init(host: URL = URL(string: "http://localhost:11434")!,
         session: URLSession = .shared) {
        self.host = host
        self.session = session
    }

    var displayName: String {
        "Ollama (\(currentModel))"
    }

    /// Current model identifier from UserDefaults, or the default
    /// if the user hasn't picked one yet.
    var currentModel: String {
        let stored = UserDefaults.standard.string(forKey: Self.modelDefaultsKey) ?? ""
        return stored.isEmpty ? Self.defaultModel : stored
    }

    /// Ollama running locally is the only "configuration" we need
    /// — there's no API key. The view model can choose to also
    /// gate `isConfigured` on whether the daemon is reachable, but
    /// that's a per-call concern; here we just say "yes, it's
    /// always usable, errors will surface at call time".
    var isConfigured: Bool { true }

    /// Forces the model out of RAM immediately. Sends a tiny
    /// generate request with `keep_alive: 0`, which is Ollama's
    /// idiomatic way to say "drop the loaded weights right now"
    /// — the next chat request will trigger a re-load (~1-2s
    /// cold-start), but in exchange the user gets ~5 GB of RAM
    /// back to the OS. Called when the chat popover closes so
    /// the AI doesn't keep occupying memory for the default 5
    /// minutes after the user is done.
    func unloadModel() async {
        let body: [String: Any] = [
            "model": currentModel,
            "keep_alive": 0,
        ]
        var req = URLRequest(url: host.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 5
        _ = try? await session.data(for: req)
    }

    // MARK: - Completion

    func complete(turns: [ChatTurn]) async throws -> ChatCompletion {
        let messages = turns.map { turn -> [String: Any] in
            [
                "role": Self.role(for: turn.role),
                "content": turn.text,
            ]
        }

        let cores = ProcessInfo.processInfo.activeProcessorCount
        let body: [String: Any] = [
            "model": currentModel,
            "messages": messages,
            "stream": false,
            "keep_alive": "30s",
            "options": [
                "temperature": 0.4,
                // Cap response length: 256 tokens ≈ 3-4 short
                // paragraphs, plenty for "what do I have
                // tomorrow" answers, and keeps total response
                // time under ~5s on a 3B model.
                "num_predict": 256,
                "num_thread": max(4, cores / 2),
            ],
        ]

        var req = URLRequest(url: host.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Local-LLM responses can take a while (especially first
        // call after cold-start when the model loads into memory),
        // so allow a generous timeout.
        req.timeoutInterval = 120

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
                                            || urlError.code == .timedOut {
            throw LLMError.providerMessage(
                "Não consegui falar com o Ollama em localhost:11434. Confira se o `ollama serve` está rodando."
            )
        } catch {
            throw LLMError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.decoding("Sem resposta HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Common Ollama error: "model not found" → 404 with
            // explanatory message. Surface as-is.
            let raw = Self.errorMessage(in: data) ?? "Erro \(http.statusCode)"
            if raw.lowercased().contains("model") &&
               (raw.lowercased().contains("not found") || raw.lowercased().contains("pull")) {
                throw LLMError.providerMessage(
                    "Modelo \"\(currentModel)\" não está instalado. Rode no terminal: `ollama pull \(currentModel)`"
                )
            }
            throw LLMError.providerMessage("Ollama \(http.statusCode): \(raw)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let text = message["content"] as? String
        else {
            throw LLMError.decoding("Resposta do Ollama em formato inesperado")
        }

        return ChatCompletion(
            text: text,
            inputTokens:  json["prompt_eval_count"] as? Int,
            outputTokens: json["eval_count"]        as? Int
        )
    }

    // MARK: - Streaming

    /// Real streaming via Ollama's NDJSON protocol. Each line is
    /// a JSON object — non-final lines carry a `message.content`
    /// fragment, the final line has `done: true` plus
    /// `prompt_eval_count` / `eval_count` for the usage tally.
    func stream(turns: [ChatTurn]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let messages = turns.map { turn -> [String: Any] in
                    [
                        "role": Self.role(for: turn.role),
                        "content": turn.text,
                    ]
                }

                // Per-request resource caps. These mirror the
                // env-var caps applied to the daemon — belt-
                // and-suspenders so a custom Ollama install
                // (where the user started `ollama serve`
                // themselves) still gets the lighter footprint.
                //   • num_thread: half the physical cores —
                //     keeps the rest of the system responsive
                //     while a token is being generated.
                //   • keep_alive: 30s — unload the model from
                //     RAM 30 seconds after the response
                //     finishes, instead of the default 5
                //     minutes. The few GB come back to the OS
                //     within seconds of the user stopping
                //     chatting.
                let cores = ProcessInfo.processInfo.activeProcessorCount
                let body: [String: Any] = [
                    "model": currentModel,
                    "messages": messages,
                    "stream": true,
                    "keep_alive": "30s",
                    "options": [
                        "temperature": 0.4,
                        "num_predict": 1024,
                        "num_thread": max(4, cores / 2),
                    ],
                ]

                var req = URLRequest(url: host.appendingPathComponent("api/chat"))
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                do {
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                } catch {
                    continuation.finish(throwing: LLMError.network(error))
                    return
                }
                req.timeoutInterval = 600  // generous: token-by-token can take a while

                let bytes: URLSession.AsyncBytes
                let response: URLResponse
                do {
                    (bytes, response) = try await session.bytes(for: req)
                } catch let urlError as URLError where urlError.code == .cannotConnectToHost
                                                    || urlError.code == .timedOut {
                    continuation.finish(throwing: LLMError.providerMessage(
                        "Não consegui falar com o Ollama em localhost:11434. Confira se o serviço está rodando."
                    ))
                    return
                } catch {
                    continuation.finish(throwing: LLMError.network(error))
                    return
                }

                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    continuation.finish(throwing: LLMError.providerMessage(
                        "Ollama \(http.statusCode)"
                    ))
                    return
                }

                var inputTokens:  Int? = nil
                var outputTokens: Int? = nil

                do {
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        // Reasoning models (qwen3.5, deepseek-r1)
                        // emit `message.thinking` chunks BEFORE
                        // any content. Forward those as
                        // `.thinking` so the UI can show the
                        // chain-of-thought streaming live —
                        // otherwise the user sits looking at a
                        // blank bubble for 30+ seconds while the
                        // model "thinks".
                        if let message = json["message"] as? [String: Any] {
                            if let thinking = message["thinking"] as? String,
                               !thinking.isEmpty {
                                continuation.yield(.thinking(thinking))
                            }
                            if let content = message["content"] as? String,
                               !content.isEmpty {
                                continuation.yield(.partial(content))
                            }
                        }

                        if (json["done"] as? Bool) == true {
                            inputTokens  = json["prompt_eval_count"] as? Int
                            outputTokens = json["eval_count"]        as? Int
                            break
                        }
                    }
                    continuation.yield(.finished(ChatCompletion(
                        text: "",  // empty — caller already assembled deltas
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

    // MARK: - Discovery

    /// Lists installed models via `/api/tags`. Used by Settings
    /// for the model picker. Returns an empty array if the daemon
    /// isn't reachable rather than throwing — it's a UI helper.
    func listInstalledModels() async -> [String] {
        var req = URLRequest(url: host.appendingPathComponent("api/tags"))
        req.httpMethod = "GET"
        req.timeoutInterval = 5
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { return [] }
        return models.compactMap { $0["name"] as? String }.sorted()
    }

    /// True iff the daemon answered any request within ~2s. Used
    /// by Settings to show a "running / not running" indicator.
    func isReachable() async -> Bool {
        var req = URLRequest(url: host.appendingPathComponent("api/tags"))
        req.httpMethod = "GET"
        req.timeoutInterval = 2
        do {
            let (_, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse {
                return (200..<300).contains(http.statusCode)
            }
            return false
        } catch {
            return false
        }
    }

    // MARK: - Helpers

    private static func role(for chatRole: ChatRole) -> String {
        switch chatRole {
        case .system:    return "system"
        case .user:      return "user"
        case .assistant: return "assistant"
        }
    }

    private static func errorMessage(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["error"] as? String
    }
}
