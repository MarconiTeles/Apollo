import Foundation

// MARK: - Provider-agnostic chat types

/// Single role in a chat exchange. Maps to whichever role-name the
/// concrete provider expects (`user` / `model` for Gemini,
/// `user` / `assistant` for OpenAI/Anthropic, etc.).
enum ChatRole: String, Codable {
    case system     // High-priority instructions (system prompt)
    case user       // User's typed message
    case assistant  // Model's reply
}

/// One turn in the conversation. The view model converts these to
/// whatever payload the provider needs.
struct ChatTurn: Codable, Identifiable, Equatable {
    let id: UUID
    let role: ChatRole
    var text: String
    let date: Date

    init(id: UUID = UUID(),
         role: ChatRole,
         text: String,
         date: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
    }
}

/// Result of one round-trip — the model's reply plus a usage
/// breakdown so we can show "tokens used" or budget alerts later.
struct ChatCompletion {
    let text: String
    let inputTokens:  Int?
    let outputTokens: Int?
}

/// Errors a provider can raise. Surfaced to the UI as a friendly
/// banner — concrete providers should map their HTTP / SDK errors
/// into one of these cases.
enum LLMError: LocalizedError {
    case missingApiKey
    case invalidApiKey
    case rateLimited
    case quotaExceeded
    case network(Error)
    case decoding(String)
    case providerMessage(String)
    /// Provider hit its output-token cap mid-stream (Gemini's
    /// `MAX_TOKENS` finishReason, Groq's 413 TPR ceiling). The
    /// chat layer catches this and re-runs the same payload on
    /// a higher-budget fallback model BEFORE the user ever
    /// sees the truncated answer. The associated string carries
    /// the partial text we got, in case the fallback ever wants
    /// to splice instead of restart.
    case outputExhausted(partial: String)

    var errorDescription: String? {
        switch self {
        case .missingApiKey:
            return "Configure a chave da API em Configurações → Apollo IA."
        case .invalidApiKey:
            return "Chave inválida. Verifique em Configurações → Apollo IA."
        case .rateLimited:
            return "Muitas requisições por minuto. Aguarde alguns segundos."
        case .quotaExceeded:
            return "Cota gratuita do dia esgotada. Tente novamente amanhã."
        case .network(let err):
            return "Erro de rede: \(err.localizedDescription)"
        case .decoding(let detail):
            return "Resposta inválida do servidor: \(detail)"
        case .providerMessage(let msg):
            return msg
        case .outputExhausted:
            return "O modelo atingiu o limite de tokens — trocando para um modelo com mais capacidade."
        }
    }
}

// MARK: - Protocol

/// One event in a streaming completion. Providers emit zero or
/// more `.thinking(...)` and `.partial(...)` deltas as the model
/// generates tokens, then exactly one `.finished(...)` carrying
/// the final usage tally.
///
/// Reasoning models (qwen3.5, o1, deepseek-r1, claude-with-thinking)
/// emit a long `.thinking` stream BEFORE the actual response —
/// without `.thinking`, the UI would sit silent for tens of
/// seconds while the model "thinks" with empty `.content`.
enum StreamEvent {
    case thinking(String)             // reasoning model's chain-of-thought delta
    case partial(String)              // incremental answer chunk
    case finished(ChatCompletion)     // last event with usage info
}

/// What every LLM backend must implement so we can swap Gemini for
/// Claude / OpenAI / Ollama later without touching `AIAgentService`.
protocol LLMProvider {
    /// Human-readable name shown in Settings ("Gemini 2.0 Flash").
    var displayName: String { get }
    /// Whether the provider has the credentials it needs to run.
    var isConfigured: Bool { get }

    /// Send `turns` (already containing any system prompt) to the
    /// model and return its reply. Throws an `LLMError` on failure.
    func complete(turns: [ChatTurn]) async throws -> ChatCompletion

    /// Streaming variant — yields `.partial` events for each token
    /// chunk the model emits and a final `.finished` event with
    /// the usage tally. Default implementation falls back to
    /// `complete` and yields the whole response in one go, so
    /// providers without real streaming still conform.
    func stream(turns: [ChatTurn]) -> AsyncThrowingStream<StreamEvent, Error>
}

extension LLMProvider {
    /// Fallback streaming: just calls `complete` once and emits
    /// the whole response as a single partial event.
    func stream(turns: [ChatTurn]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await complete(turns: turns)
                    continuation.yield(.partial(result.text))
                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Backend selection

/// Which provider implementation to use. Persisted in UserDefaults
/// under `dp_ai_backend` so the user's choice survives restart.
enum LLMBackend: String, CaseIterable, Identifiable {
    case embedded         // Apollo's bundled MLX model — disabled
    case groq             // Cloud — Groq (fast Llama inference)
    case gemini           // Cloud — Gemini Flash via Google AI Studio
    case ollama           // Local — Ollama daemon on localhost:11434
    case appleIntelligence  // On-device — Apple Foundation Models
    case openai           // Cloud — OpenAI (GPT-4o / GPT-5)

    var id: String { rawValue }

    var label: String {
        switch self {
        case .embedded:           return "Apollo IA (embutido, sem setup)"
        case .groq:               return "Groq (cloud, ultrarrápido)"
        case .gemini:             return "Gemini (cloud, free tier)"
        case .ollama:             return "Ollama (local, daemon próprio)"
        case .appleIntelligence:  return "Apple Intelligence (on-device, sem limites)"
        case .openai:             return "OpenAI GPT (cloud, pago)"
        }
    }

    var systemImage: String {
        switch self {
        case .embedded:           return "sparkles"
        case .groq:               return "bolt.fill"
        case .gemini:             return "cloud.fill"
        case .ollama:             return "desktopcomputer"
        case .appleIntelligence:  return "apple.logo"
        case .openai:             return "brain.head.profile"
        }
    }

    /// Constructs a fresh provider instance for the chosen backend.
    /// `embeddedRuntime` is required by the `.embedded` path —
    /// it's the lifecycle manager that owns the bundled daemon.
    func makeProvider(embeddedRuntime: EmbeddedRuntimeManager) -> LLMProvider {
        switch self {
        case .embedded:           return EmbeddedLLMProvider(manager: embeddedRuntime)
        case .groq:               return GroqProvider()
        case .gemini:             return GeminiProvider()
        case .ollama:             return OllamaProvider()
        case .appleIntelligence:  return AppleIntelligenceProvider()
        case .openai:             return OpenAIProvider()
        }
    }

    static let userDefaultsKey = "dp_ai_backend"

    /// User-selectable backends shown in the Settings picker.
    /// `.embedded` (the bundled Qwen GGUF) was removed at the
    /// user's request — the 5.5 GB local model was eating disk
    /// space they preferred to reclaim. Cloud-only options
    /// remain. Other backends (Apple Intelligence, Groq, Ollama)
    /// stay in the enum for backwards-compat with persisted
    /// prefs but are migrated to `.gemini` on launch.
    static var userSelectable: [LLMBackend] {
        [.gemini, .openai]
    }

    /// Reads the user's last choice from UserDefaults; defaults
    /// to `.gemini` (free tier, no setup beyond pasting a key).
    /// Migrates legacy preferences (`.embedded`, Apple
    /// Intelligence, Groq, Ollama — all removed from the
    /// user-selectable picker) onto `.gemini` so existing
    /// users transition cleanly without needing to touch
    /// Settings.
    static var current: LLMBackend {
        let stored = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
        let parsed = LLMBackend(rawValue: stored) ?? .gemini
        if !userSelectable.contains(parsed) {
            UserDefaults.standard.set(LLMBackend.gemini.rawValue,
                                      forKey: userDefaultsKey)
            return .gemini
        }
        return parsed
    }
}
