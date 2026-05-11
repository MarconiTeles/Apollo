import Foundation

/// Concrete `LLMProvider` that uses Apollo's **fully self-contained**
/// AI runtime — both the inference engine (Ollama binary, ~74 MB)
/// AND the model weights (GGUF, ~1.3 GB) ship inside the
/// `Apollo.app` bundle.
///
/// At runtime this provider:
///   • Spawns the bundled `ollama` daemon pointed at a local
///     models directory inside the user's `~/Library/Application
///     Support/Apollo/models/` (so multiple Apollo instances and
///     a system-wide Ollama don't fight over the same models dir).
///   • Imports the bundled GGUF on first launch via `ollama
///     create`, mapped to the model name `apollo-ia`.
///   • From then on, talks to `localhost` over Ollama's
///     OpenAI-compatible chat endpoint.
///
/// User experience: install Apollo → click sparkles → ask
/// question → receive answer. No keys, no console, no terminal,
/// no `brew install`. Privacy: 100% local, no network needed.
final class EmbeddedLLMProvider: LLMProvider {

    let displayName  = "Apollo IA (embutida)"
    var isConfigured: Bool { true }

    /// Forces the embedded model out of RAM right now. Sends a
    /// generate request with `keep_alive: 0`. Called when the
    /// chat popover closes so the ~5 GB Qwen 7B doesn't keep
    /// occupying memory long after the user is done. The next
    /// chat request will pay a ~1-2s cold-start, but in
    /// exchange the rest of the system gets responsive again
    /// immediately.
    func unloadModel() async {
        let body: [String: Any] = [
            "model": Self.modelAlias,
            "keep_alive": 0,
        ]
        var req = URLRequest(url: host.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 5
        _ = try? await session.data(for: req)
    }

    /// Internal model alias. Qwen 3 14B (dense) — bigger and
    /// more capable than the previous Qwen 3.5 9B, which was
    /// failing at multi-turn context retention and fuzzy
    /// matching. ~9 GB on disk, ~12 GB active RAM with
    /// num_ctx 8192. Pulled via `ollama pull qwen3:14b`.
    static let modelAlias = "qwen3:14b"

    private let manager: EmbeddedRuntimeManager
    private let session = URLSession.shared
    private let host = URL(string: "http://localhost:11434")!

    init(manager: EmbeddedRuntimeManager) {
        self.manager = manager
    }

    // MARK: - LLMProvider

    func complete(turns: [ChatTurn]) async throws -> ChatCompletion {
        var assembled = ""
        var inputTokens:  Int? = nil
        var outputTokens: Int? = nil
        for try await event in stream(turns: turns) {
            switch event {
            case .partial(let chunk):
                assembled += chunk
            case .finished(let result):
                inputTokens  = result.inputTokens
                outputTokens = result.outputTokens
            case .thinking:
                continue
            }
        }
        return ChatCompletion(text: assembled,
                              inputTokens: inputTokens,
                              outputTokens: outputTokens)
    }

    func stream(turns: [ChatTurn]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                // Make sure the bundled runtime is up — this is a
                // no-op once the daemon is running and the model
                // is imported.
                let ready = await manager.bootstrap()
                let statusMsg = await manager.statusMessage
                guard ready else {
                    continuation.finish(throwing: LLMError.providerMessage(
                        statusMsg.isEmpty
                            ? "Apollo IA não está pronta."
                            : statusMsg
                    ))
                    return
                }

                // Build the Ollama /api/chat request. The
                // bundled Qwen 2.5 7B has a 4096 context cap
                // (KV-cache footprint trade-off) — Apollo's
                // full system prompt is 25K+ tokens and gets
                // silently truncated by Ollama's middle-out
                // strategy, which corrupts the live data the
                // model needs to answer. We pre-trim the
                // system message ourselves using the same
                // helper built for Apple Intelligence — keeps
                // the live data sections (AGENDA, ATRASADAS,
                // URGENTES, etc.) intact and drops the
                // verbose persona/action documentation that
                // a 7B model can't follow anyway.
                // Inject `/no_think` into the LAST user message
                // — Qwen 3 default-emits a `<think>…</think>`
                // chain-of-thought block before the actual
                // answer, and Apollo wants short snappy
                // replies.
                //
                // System prompt is trimmed (contacts + subtasks
                // + live data KEPT, pure-doc sections dropped)
                // to fit in a smaller context window. Going
                // 32K-full made the model take 5-15s per
                // response because attention scales with
                // context size; an 8K trimmed prompt cuts
                // that to ~1-2s while keeping the directories
                // the model needs to cross-reference people
                // and tasks.
                // `/no_think` was injected for Qwen 3 but
                // Qwen 3.5 9B ignores it — model still emits
                // a `<think>` block. Removed since it's noise
                // for the current model. Pass 1 above handles
                // the think block properly (uses its content
                // when no real reply follows).
                let messages = turns.map { turn -> [String: Any] in
                    let content: String
                    if turn.role == .system {
                        content = AppleIntelligenceProvider
                            .trimForAppleIntelligence(turn.text)
                    } else {
                        content = turn.text
                    }
                    return [
                        "role":    Self.role(for: turn.role),
                        "content": content,
                    ]
                }
                // Resource caps per request — match the
                // env-var caps applied to the spawned daemon so
                // a custom Ollama install (where the user
                // started `ollama serve` themselves) still gets
                // the lighter footprint.
                let cores = ProcessInfo.processInfo.activeProcessorCount
                let body: [String: Any] = [
                    "model": Self.modelAlias,
                    "messages": messages,
                    "stream": true,
                    // Ollama 0.4+ supports `think: false` to
                    // bypass the model's chain-of-thought
                    // reasoning entirely on thinking-capable
                    // models (Qwen 3.5 / Qwen 3 / DeepSeek-R1).
                    // Without this Qwen 3.5 9B spent ~30s
                    // generating a `<think>` block before
                    // emitting the visible reply. Disabling
                    // skips that latency entirely.
                    "think": false,
                    // 5 minutes. Long enough to span a multi-
                    // question chat without paying the cold-
                    // load cost on every turn, short enough
                    // that idle sessions free RAM eventually.
                    "keep_alive": "5m",
                    "options": [
                        "temperature": 0.2,
                        // 400 — without thinking budget needed,
                        // a snappy short answer fits well in
                        // 400 tokens. Higher budgets encouraged
                        // verbose recaps.
                        "num_predict": 600,
                        // 8K — Qwen 3 14B Q4 (~9 GB) + 8K KV
                        // cache (~3 GB) ≈ 12 GB active. Fits
                        // 16 GB Macs comfortably. The trim
                        // function shrinks Apollo's prompt
                        // to fit easily within 8K.
                        "num_ctx": 8192,
                        // num_batch 256 → 512. Bigger batch
                        // halves the prompt-encoding time
                        // on Apple Silicon.
                        "num_batch": 512,
                        "repeat_penalty": 1.10,
                        // Half the physical cores — keeps the
                        // foreground UI responsive while
                        // generation runs in the background.
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
                req.timeoutInterval = 120

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
                    continuation.finish(throwing: LLMError.providerMessage(
                        "Apollo IA retornou \(http.statusCode)"
                    ))
                    return
                }

                var inputTokens:  Int? = nil
                var outputTokens: Int? = nil
                // Buffer the ENTIRE response. Two separate
                // accumulators because Ollama's API splits
                // thinking-mode output into `message.thinking`
                // (chain-of-thought) and `message.content`
                // (final answer). Qwen 3.5 9B sometimes
                // produces ONLY thinking and never emits a
                // final content — when that happens we fall
                // back to the thinking buffer as the visible
                // reply (still better than empty).
                var buffer = ""
                var thinkingBuffer = ""

                do {
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let message = json["message"] as? [String: Any] {
                            if let thinking = message["thinking"] as? String,
                               !thinking.isEmpty {
                                continuation.yield(.thinking(thinking))
                                thinkingBuffer += thinking
                            }
                            if let content = message["content"] as? String,
                               !content.isEmpty {
                                buffer += content
                            }
                        }

                        if (json["done"] as? Bool) == true {
                            inputTokens  = json["prompt_eval_count"] as? Int
                            outputTokens = json["eval_count"]        as? Int
                            break
                        }
                    }

                    // If Ollama produced ZERO content (all the
                    // model's tokens went into the thinking
                    // channel), promote the thinking buffer to
                    // be the visible response.
                    if buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !thinkingBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        buffer = thinkingBuffer
                    }

                    // Pass 1 — handle `<think>…</think>` blocks.
                    // Qwen 3.5 9B (current model) puts the
                    // actual answer INSIDE the think block
                    // and often runs out of `num_predict`
                    // tokens before emitting a "real" reply
                    // outside it. Strategy:
                    //   • If the model produced content
                    //     AFTER `</think>` (real reply),
                    //     strip the think block — that's the
                    //     intended behaviour.
                    //   • Otherwise (unterminated, OR closed
                    //     but nothing after), KEEP the think
                    //     content as the response — it's all
                    //     the answer the model produced and
                    //     it's better than empty.
                    var cleaned = buffer
                    if let open = cleaned.range(of: "<think>") {
                        if let close = cleaned.range(
                            of: "</think>",
                            range: open.upperBound..<cleaned.endIndex
                        ) {
                            // Closed think block. Check if
                            // there's content after the close
                            // tag.
                            let afterClose = cleaned[close.upperBound...]
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !afterClose.isEmpty {
                                // Real reply present — strip
                                // the whole think block.
                                cleaned.removeSubrange(open.lowerBound..<close.upperBound)
                            } else {
                                // Nothing after close — use the
                                // thinking content as the
                                // response. Strip just the tags.
                                let inner = String(cleaned[open.upperBound..<close.lowerBound])
                                cleaned = inner
                            }
                        } else {
                            // Unterminated. Use the thinking
                            // content (everything after the
                            // open tag) as the response.
                            cleaned = String(cleaned[open.upperBound...])
                        }
                    }
                    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

                    // Pass 2 — normalize numbered-list +
                    // sub-bullet output into the pill format.
                    var normalized = AppleIntelligenceProvider
                        .normalizePillFormat(cleaned)

                    // Phantom-action detector REMOVED — it was
                    // firing on legitimate brief responses
                    // ("Posso agendar X. Confirma?") and
                    // replacing them with a confusing error.
                    // The system prompt now strongly instructs
                    // the model to emit markers; if it skips
                    // the marker on a confirmation, that's a
                    // model-quality issue better surfaced as
                    // the model's actual reply (so the user
                    // can re-prompt) than masked with a fake
                    // error.

                    // Final safety net — if every cleanup pass
                    // collapsed the response to nothing,
                    // emit either the pre-normalize cleaned
                    // text OR the raw buffer OR a friendly
                    // fallback message. The user must always
                    // see SOMETHING — silent empty bubbles
                    // are the worst possible failure mode.
                    if normalized.isEmpty {
                        if !cleaned.isEmpty {
                            normalized = cleaned
                        } else if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            normalized = buffer
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        } else {
                            normalized = "Não recebi resposta do modelo. Tente reformular a pergunta."
                        }
                    }

                    continuation.yield(.partial(normalized))
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

    private static func role(for chatRole: ChatRole) -> String {
        switch chatRole {
        case .system:    return "system"
        case .user:      return "user"
        case .assistant: return "assistant"
        }
    }

    /// Detects when the model claims to have completed an
    /// action ("agendado", "criado", "feito", "marquei",
    /// "adicionado") but hasn't actually emitted the
    /// `[[ACTION …]]` marker that the executor needs to run.
    /// This is the model lying about a side effect that
    /// never happened.
    static func looksLikePhantomAction(_ text: String) -> Bool {
        let lower = text.lowercased()
        // If a marker is present, the action will run for real.
        if lower.contains("[[create_") || lower.contains("[[update_")
            || lower.contains("[[delete_") || lower.contains("[[batch_")
            || lower.contains("[[schedule_") {
            return false
        }
        // Heuristic: response sounds like a successful side
        // effect was performed.
        let phantomPhrases = [
            "agendado com sucesso", "agendei", "marquei",
            "criado com sucesso", "criei",
            "adicionado com sucesso", "adicionei",
            "feito", "pronto, agendei", "pronto, criei",
            "foi adicionado", "foi criado", "foi agendado",
            "foi marcado",
        ]
        return phantomPhrases.contains { lower.contains($0) }
    }

    /// Streaming-safe `<think>…</think>` filter. Returns:
    ///   • `emit` — text safe to forward to the user bubble
    ///   • `residual` — partial text held back because it
    ///     might be the start of a `<think>` opening tag (or
    ///     a partial closing `</think>` tag)
    ///   • `stillInThink` — whether we're inside a think
    ///     block as of the last processed chunk
    /// Handles tags that span multiple chunks by buffering
    /// any prefix that COULD be the start of `<think>` or
    /// `</think>`.
    static func stripThinkBlock(
        pending: String,
        inBlock: Bool
    ) -> (emit: String, residual: String, stillInThink: Bool) {
        var emit = ""
        var rest = pending
        var insideBlock = inBlock

        while !rest.isEmpty {
            if insideBlock {
                if let close = rest.range(of: "</think>") {
                    rest = String(rest[close.upperBound...])
                    insideBlock = false
                    continue
                }
                // Could be a partial `</think>` at the tail —
                // hold back up to 8 chars so we don't emit the
                // start of a closing tag.
                let holdback = min(8, rest.count)
                let _ = String(rest.suffix(holdback))
                // While inside a think block we emit nothing
                // either way; just keep buffering.
                return (emit, rest, true)
            } else {
                if let open = rest.range(of: "<think>") {
                    emit += rest[..<open.lowerBound]
                    rest = String(rest[open.upperBound...])
                    insideBlock = true
                    continue
                }
                // Hold back any tail that COULD be the start
                // of a `<think>` tag (up to 7 chars).
                let holdback = min(7, rest.count)
                let safeEnd = rest.index(rest.endIndex, offsetBy: -holdback)
                let safe = String(rest[..<safeEnd])
                let tail = String(rest[safeEnd...])
                emit += safe
                return (emit, tail, false)
            }
        }
        return (emit, "", insideBlock)
    }
}
