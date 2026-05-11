import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence backend — runs Apple's on-device
/// Foundation Models language model via the `FoundationModels`
/// framework (macOS 26+). Requires:
///   • Apple Silicon Mac
///   • macOS 26.0 or later
///   • Apple Intelligence enabled in System Settings
///
/// Why this is Apollo's recommended backend:
///   • No rate limits (the per-minute Gemini cap and per-
///     request Groq TPM ceiling don't apply — those are the
///     two errors users hit most with the cloud providers when
///     Apollo's rich system prompt is bundled in).
///   • No API key.
///   • Privacy — prompt + reply never leave the device.
///   • Zero cost.
///
/// Trade-offs vs Gemini/Groq:
///   • Smaller context window (~4K tokens). Apollo's context
///     is heavy, so the long system prompt is trimmed to fit.
///   • Slightly slower first-token latency than Groq, but no
///     network round-trip overhead.
///
/// On macOS < 26 or Macs without Apple Intelligence, the
/// provider returns an `LLMError.providerMessage` explaining
/// the requirement so the user can switch back to Gemini.
final class AppleIntelligenceProvider: LLMProvider {

    var isConfigured: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        return false
        #else
        return false
        #endif
    }

    var displayName: String { "Apple Intelligence" }

    // MARK: - Non-streaming

    func complete(turns: [ChatTurn]) async throws -> ChatCompletion {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw LLMError.providerMessage(
                "Apple Intelligence requer macOS 26 ou posterior."
            )
        }
        guard SystemLanguageModel.default.isAvailable else {
            throw LLMError.providerMessage(
                "Apple Intelligence indisponível neste Mac. Verifique se está habilitado em Ajustes do Sistema → Apple Intelligence."
            )
        }

        let session = makeSession(turns: turns)
        let userText = userPrompt(from: turns)
        do {
            let response = try await session.respond(to: userText)
            return ChatCompletion(
                text: response.content,
                inputTokens: nil,
                outputTokens: nil
            )
        } catch {
            throw LLMError.providerMessage(
                "Apple Intelligence: \(error.localizedDescription)"
            )
        }
        #else
        throw LLMError.providerMessage(
            "Apple Intelligence não está disponível neste build."
        )
        #endif
    }

    // MARK: - Streaming

    func stream(turns: [ChatTurn]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                #if canImport(FoundationModels)
                guard #available(macOS 26.0, *) else {
                    continuation.finish(throwing: LLMError.providerMessage(
                        "Apple Intelligence requer macOS 26 ou posterior."
                    ))
                    return
                }
                guard SystemLanguageModel.default.isAvailable else {
                    continuation.finish(throwing: LLMError.providerMessage(
                        "Apple Intelligence indisponível neste Mac. Verifique se está habilitado em Ajustes do Sistema → Apple Intelligence."
                    ))
                    return
                }

                let session = makeSession(turns: turns)
                let userText = userPrompt(from: turns)

                do {
                    // FoundationModels emits the response as
                    // an `AsyncSequence` of cumulative snapshots
                    // (each event = the full text built so far,
                    // not just the new delta). Diff against the
                    // last snapshot to extract the delta and
                    // forward it as a `.partial` event.
                    var sentSoFar = ""
                    let snapshots = session.streamResponse(to: userText)
                    for try await snapshot in snapshots {
                        let full = snapshot.content
                        if full.count > sentSoFar.count {
                            let delta = String(full.dropFirst(sentSoFar.count))
                            if !delta.isEmpty {
                                continuation.yield(.partial(delta))
                            }
                            sentSoFar = full
                        }
                    }
                    continuation.yield(.finished(ChatCompletion(
                        text: "", inputTokens: nil, outputTokens: nil
                    )))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: LLMError.providerMessage(
                        "Apple Intelligence: \(error.localizedDescription)"
                    ))
                }
                #else
                continuation.finish(throwing: LLMError.providerMessage(
                    "Apple Intelligence não está disponível neste build."
                ))
                #endif
            }
        }
    }

    // MARK: - Helpers

    #if canImport(FoundationModels)
    /// Builds a fresh session with a TRIMMED system prompt
    /// that fits inside Apple Intelligence's on-device context
    /// window (~4K tokens). Apollo's full prompt routinely
    /// exceeds 25K tokens because it bundles every action's
    /// documentation, few-shot examples, the full member
    /// roster, etc. — content the small on-device model
    /// can't make use of anyway. We keep the live data (the
    /// dynamic snapshot of today's events, tasks, deadlines
    /// the chat layer prepended to the prompt) and drop the
    /// verbose framework docs so the model has room to
    /// actually answer.
    @available(macOS 26.0, *)
    private func makeSession(turns: [ChatTurn]) -> LanguageModelSession {
        let systemText = turns
            .filter { $0.role == .system }
            .map(\.text)
            .joined(separator: "\n\n")

        let trimmed = Self.trimForAppleIntelligence(systemText)
        if trimmed.isEmpty {
            return LanguageModelSession()
        }
        return LanguageModelSession(instructions: Instructions(trimmed))
    }
    #endif

    /// Builds the COMPLETE system prompt for Apollo IA
    /// (embedded). Replaces the previous fragmented prompt
    /// (10+ scattered sections, lots of emoji noise, repeated
    /// rules) with one coherent, structured document. The
    /// prompt teaches the model EVERYTHING it needs in one
    /// pass: identity, time, format, actions, constraints,
    /// few-shots, then the live workspace data.
    ///
    /// Structure:
    ///   §1  Identidade
    ///   §2  Ancoragem temporal (HOJE / AMANHÃ pré-computados)
    ///   §3  Estilo de resposta (brevidade, anti-alucinação)
    ///   §4  Formato de pílulas (regex que o parser exige)
    ///   §5  Ações executáveis (sintaxe exata + 2-turn flow)
    ///   §6  Few-shots (5 exemplos canônicos)
    ///   §7  Contexto live do workspace (do Apollo)
    static func trimForAppleIntelligence(_ source: String) -> String {
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let ptBR = Locale(identifier: "pt_BR")

        let dateLong = now.formatted(
            .dateTime.weekday(.wide).day().month(.wide).year()
                .locale(ptBR)
        )
        let timeShort = now.formatted(date: .omitted, time: .shortened)

        let dayFmt = Date.FormatStyle(date: .omitted, time: .omitted)
            .day().month(.wide).weekday(.abbreviated)
            .locale(ptBR)
        func rel(_ days: Int) -> String {
            let d = cal.date(byAdding: .day, value: days, to: now) ?? now
            return d.formatted(dayFmt)
        }
        let yyyyMMdd = ISO8601DateFormatter()
        yyyyMMdd.formatOptions = [.withFullDate]
        let todayISO = yyyyMMdd.string(from: now)
        let year = cal.component(.year, from: now)
        let tomorrowDay = cal.component(.day, from:
            cal.date(byAdding: .day, value: 1, to: now) ?? now)

        // Strip Apollo's encyclopedic / docs sections — we
        // replace them with concise § sections in the
        // prompt below. Live data sections stay.
        let dropHeadings = [
            "SOBRE O APOLLO",
            "AÇÕES DISPONÍVEIS", "ACTIONS DISPONÍVEIS",
            "FEW-SHOT", "EXEMPLOS DE INTERAÇÃO", "EXEMPLOS FEW-SHOT",
            "DICAS DE INTERPRETAÇÃO",
            "INSTRUÇÕES DETALHADAS",
        ]
        var liveContext = source
        for heading in dropHeadings {
            guard let headRange = liveContext.range(of: heading) else { continue }
            let lineStart = liveContext[..<headRange.lowerBound]
                .lastIndex(of: "\n")
                .map { liveContext.index(after: $0) } ?? liveContext.startIndex
            let after = liveContext[headRange.upperBound...]
            let sepRegex = #"\n[─━═]{3,}"#
            let nextSep = after.range(of: sepRegex, options: .regularExpression)
            let endIdx: String.Index = {
                if let nextSep {
                    let afterSep = liveContext[nextSep.upperBound...]
                    if let nextNextSep = afterSep.range(of: sepRegex, options: .regularExpression) {
                        return nextNextSep.upperBound
                    }
                    return nextSep.lowerBound
                }
                return liveContext.endIndex
            }()
            liveContext.removeSubrange(lineStart..<endIdx)
        }
        // Cap at 9000 chars, keep head + tail.
        let maxChars = 9000
        if liveContext.count > maxChars {
            let head = liveContext.prefix(1500)
            let tailStart = liveContext.index(liveContext.endIndex, offsetBy: -(maxChars - 1500))
            liveContext = head + "\n\n[…contexto resumido…]\n\n" + liveContext[tailStart...]
        }

        return """
        ═══════════════════════════════════════════════
                    APOLLO IA — SYSTEM PROMPT
        ═══════════════════════════════════════════════

        §1  IDENTIDADE
        Você é o Apollo IA, assistente embarcado no app Apollo
        (macOS) que ajuda o usuário a gerenciar agenda
        (Calendar) e tarefas (ClickUp). Responde em português
        brasileiro, com clareza e direto ao ponto.

        ACESSO A DADOS — você TEM acesso direto e completo a:
        • Todos os eventos do Google Calendar do usuário (§7)
        • Todas as tarefas, subtarefas, status, prioridades,
          datas, responsáveis do ClickUp (§7)
        • Lista completa de contatos (CONTATOS DO CLICKUP +
          CONTATOS DO CALENDÁRIO no §7)
        • Estado da interface, sincronização, notificações (§7)

        PROIBIDO dizer: "não tenho acesso direto", "não consigo
        ver sua lista", "como sou IA não posso…", "preciso que
        você me forneça a informação", "você precisa adicionar".
        Os dados ESTÃO no seu contexto §7 — USE eles.

        §2  ANCORAGEM TEMPORAL (use estas datas literalmente)
        AGORA       = \(dateLong), \(timeShort)
        HOJE        = \(rel(0))      (ISO: \(todayISO))
        AMANHÃ      = \(rel(1))      (dia \(tomorrowDay))
        DEPOIS      = \(rel(2))
        +7 DIAS     = \(rel(7))
        Ano atual   = \(year)

        Filtros temporais:
        • "Hoje"       → SÓ itens com data == HOJE.
        • "Amanhã"     → SÓ itens com data == AMANHÃ (dia \(tomorrowDay)).
        • "Essa semana"→ data entre HOJE e +7 DIAS.
        • Sem item na janela? → "Nada agendado para [janela]." e PARA.
        • NUNCA mostre item de outra data como se fosse da janela perguntada.

        §3  ESTILO DE RESPOSTA
        • Brevidade absoluta: máx 1-2 frases + a lista pedida.
        • PROIBIDO: "se quiser posso…", "também posso…", "quer que eu…",
          "verifique seu…", recapitulações, observações finais,
          sugestões de ação não solicitadas, status reports.
        • Pergunta = "X?" → resposta = "X" e PARA.
        • Anti-alucinação: só cite dados que aparecem LITERALMENTE
          no §7. Sem certeza → "Não tenho essa informação."
          Pessoa não associada ao item → "Não encontrei nada com X."
        • NUNCA pega item parecido (mesma palavra no título) e atribui
          à pessoa que o usuário perguntou.

        §4  FORMATO DE PÍLULAS (obrigatório — o app SÓ renderiza
            pílulas clicáveis quando o regex bate exato)

        TAREFA  →  • Título exato [STATUS]
        EVENTO  →  • Título exato (vence DD mês)

        Cada tarefa/evento em UMA linha começando com `• `.
        Status/prazo vai DENTRO dos `[…]` ou `(…)`. Nunca em sub-linha.

        Corretos:
        • Big Copies - Abril [DOING]
        • Camiseta Minimal — MOF Carteira [CHECAR EDITOR FREELA]
        • 1on1 - Ana <> Marconi (vence 29 mai)
        • Daily Receita Minimal (vence 30 abr)

        Errados (NUNCA emita assim):
        ✗ 1. **Big Copies** — DOING       (numerado, negrito, sem [])
        ✗ • 1on1 às 16:00                 (sem parênteses "vence")
        ✗ "Big Copies" está em DOING       (aspas, prosa)
        ✗ • Big Copies                    (sem status)
            • Status: DOING                (sub-bullet)
        ✗ ### Tarefas                     (header markdown)

        §5  AÇÕES EXECUTÁVEIS

        Fluxo de 2 turnos (NUNCA execute sem confirmar):

        Turno 1 (BRIEF):  resuma o que vai fazer e pergunte
                          "Confirma?". Nada de marker ainda.
        Turno 2 (EXECUTE): se o usuário confirmar (qualquer
                          forma: sim/ok/manda/pode/vai/pode por/
                          fechado/confirma/perfeito/isso/beleza),
                          emita UMA frase curta + o marker na
                          PRÓXIMA LINHA. Sem marker = nada
                          executa de verdade. Dizer "pronto"
                          sem o marker é mentir pro usuário.

        Disambiguação CRÍTICA:
        • REUNIÃO / call / agendar / marcar / encontro / 1on1 /
          horário específico ("19h", "amanhã 14h") → CREATE_EVENT
        • TAREFA / task / fazer / preciso / prazo / vence em →
          CREATE_TASK

        Sintaxe (exata, entre `[[ ]]`, valores entre aspas):
            [[CREATE_EVENT title="..." start="\(year)-MM-DDTHH:MM" durationMinutes="30" guests="email1,email2"]]
            [[CREATE_TASK title="..." priority="urgente|alta|normal|baixa" due="\(year)-MM-DD"]]
            [[UPDATE_TASK_STATUS taskRef="título exato" newStatus="DOING"]]
            [[UPDATE_TASK_PRIORITY taskRef="título exato" newPriority="urgente"]]
            [[UPDATE_TASK_DUE taskRef="título exato" due="\(year)-MM-DD"]]
            [[DELETE_TASK taskRef="título exato"]]

        Convidados — REGRAS ABSOLUTAS, NUNCA quebre:

        CASO 1 — Usuário deu email completo (`x@y.z`, ou
                 `@x@y.z` com @ extra do app):
          • É um email válido. Strip o `@` inicial se houver
            e USE direto no marker.
          • PROIBIDO recusar alegando "email não está em
            CONTATOS / não consta na lista". CONTATOS NÃO é
            whitelist.
          • PROIBIDO pedir pro usuário "fornecer email correto"
            quando ele JÁ FORNECEU.

        CASO 2 — Usuário deu só PRIMEIRO NOME ou @handle:
          • Faça MATCH PARCIAL (case-insensitive, substring)
            contra CONTATOS DO CLICKUP e CONTATOS DO CALENDÁRIO.
            Procure em NOMES e em EMAILS (parte antes do `@`).
            Ex: "Jonathan" deve casar com "Jonathan Dias",
                "jonathan.dias@minimalclub.com.br",
                "jonathan@gmail.com", etc.
          • SE 1 match → use esse email no marker, sem perguntar.
          • SE 2+ matches → liste TODOS e pergunte qual:
            "Achei estes Jonathan: jonathan.dias@minimalclub.com.br
             e jonathan.silva@outra.com. Qual você quer convidar?"
          • SE 0 matches → pergunte:
            "Não achei nenhum 'Jonathan' nos contatos. Qual o
             email dele?"

        PROIBIDO em qualquer caso: dizer "não aparece
        explicitamente" e parar. Sempre faça a busca substring
        ANTES de pedir mais informação.

        Datas em markers: SEMPRE use o ano atual (\(year)).
        NUNCA use 2024 ou 2025 chutando — use \(year).

        §6  EXEMPLOS CANÔNICOS

        --- Exemplo A: pergunta sobre hoje ---
        Usuário: O que tenho hoje?
        Você:    Hoje você tem 2 reuniões e 2 tarefas:
                 • Daily Receita Minimal (vence \(rel(0)))
                 • 1on1 - Ana <> Marconi (vence \(rel(0)))
                 • Minimal Closet - 0 [TO DO]
                 • Case Heineken [TO DO]

        --- Exemplo B: pergunta sobre amanhã sem dados ---
        Usuário: O que tenho amanhã?
        Você:    Nada agendado para amanhã.

        --- Exemplo C: pergunta sobre pessoa ausente ---
        Usuário: Quando é minha próxima reunião com @manuela?
        Você:    Não encontrei nada com @manuela.

        --- Exemplo D: criar evento (2 turnos) ---
        Usuário: marque uma reunião com jonathan.dias@minimalclub.com.br pra hoje 19h
        Você:    Posso agendar 'Reunião com Jonathan Dias' para hoje
                 às 19:00, duração 30min, convidando
                 jonathan.dias@minimalclub.com.br. Confirma?
        Usuário: ok
        Você:    Pronto.
                 [[CREATE_EVENT title="Reunião com Jonathan Dias" start="\(todayISO)T19:00" durationMinutes="30" guests="jonathan.dias@minimalclub.com.br"]]

        --- Exemplo E: criar tarefa (2 turnos) ---
        Usuário: cria uma tarefa pra revisar o briefing, prazo amanhã
        Você:    Posso criar 'Revisar briefing' como tarefa,
                 prioridade normal, vencimento amanhã. Confirma?
        Usuário: sim
        Você:    Pronto.
                 [[CREATE_TASK title="Revisar briefing" priority="normal" due="\(rel(1))"]]

        §7  CONTEXTO LIVE DO WORKSPACE
        ───────────────────────────────────────────────
        \(liveContext)
        """
    }

    /// Post-processing normalizer for embedded-model output.
    /// Qwen 3 ignores format instructions in the prompt and
    /// keeps emitting `### Headers` + `1. **Title**` numbered
    /// lists with `• Status:` / `• Vence:` sub-bullets, no
    /// matter how loud the rules are. We rewrite the response
    /// AFTER the model finishes — collapse each numbered item
    /// + its `Status:` and `Vence:` sub-bullets into the
    /// canonical `• Title [STATUS]` / `• Title (vence DATE)`
    /// pill format the chat parser recognises. Markdown
    /// headers, bold wrappers, and `Observação:` noise lines
    /// are stripped entirely.
    static func normalizePillFormat(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        var output: [String] = []
        var i = 0

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // Pass through agent action markers untouched —
            // `[[CREATE_EVENT …]]`, `[[UPDATE_TASK_STATUS …]]`,
            // etc. The parser downstream depends on the exact
            // syntax inside `[[ ]]`, so we never rewrite or
            // normalise these.
            if trimmed.hasPrefix("[[") {
                output.append(raw)
                i += 1; continue
            }

            // Strip `### …` markdown headers entirely.
            if trimmed.hasPrefix("###") || trimmed.hasPrefix("##") || trimmed.hasPrefix("# ") {
                i += 1; continue
            }

            // Detect "1. Title" / "2. Title" / "1) Title" etc.
            // Capture the title (stripping any **bold** wrapper)
            // and look ahead for `Status:` and `Vence:` indented
            // sub-bullets that belong to this item.
            if let m = numberedItemRegex.firstMatch(
                in: trimmed,
                range: NSRange(trimmed.startIndex..., in: trimmed)
            ),
               let titleRange = Range(m.range(at: 1), in: trimmed) {
                let rawTitle = String(trimmed[titleRange])
                let title = stripBold(rawTitle)
                    .trimmingCharacters(in: .whitespaces)

                // Look ahead at the next few lines for sub-items.
                var status: String?
                var due: String?
                var j = i + 1
                while j < lines.count {
                    let next = lines[j].trimmingCharacters(in: .whitespaces)
                    if next.isEmpty { j += 1; continue }
                    // Stop when next numbered item OR plain text
                    // line begins.
                    if numberedItemRegex.firstMatch(
                        in: next,
                        range: NSRange(next.startIndex..., in: next)
                    ) != nil { break }
                    if !(next.hasPrefix("•") || next.hasPrefix("-")
                         || next.hasPrefix("*")) { break }

                    let body = next.dropFirst()
                        .trimmingCharacters(in: .whitespaces)
                    if let st = extractAfter(label: "Status", in: body) {
                        status = bracketContent(st) ?? st
                            .trimmingCharacters(in: CharacterSet(charactersIn: " :[]\""))
                    } else if let v = extractAfter(label: "Vence", in: body)
                                ?? extractAfter(label: "Prazo", in: body) {
                        due = v.trimmingCharacters(in: CharacterSet(charactersIn: " :\"."))
                    }
                    // "Observação:" / other sub-fields are
                    // dropped silently.
                    j += 1
                }

                // Emit the canonical pill bullet.
                if let status, !status.isEmpty {
                    output.append("• \(title) [\(status.uppercased())]")
                } else if let due, !due.isEmpty {
                    output.append("• \(title) (vence \(due))")
                } else {
                    output.append("• \(title)")
                }
                i = j
                continue
            }

            // Drop standalone "Status:" / "Vence:" / "Observação:"
            // / "Tipo:" lines that may have escaped the
            // numbered-item collapse above.
            let lowered = trimmed.lowercased()
            if lowered.hasPrefix("status:") || lowered.hasPrefix("vence:")
                || lowered.hasPrefix("prazo:") || lowered.hasPrefix("observação:")
                || lowered.hasPrefix("tipo:") {
                i += 1; continue
            }

            // Convert bullet lines using em-dash separator
            // into the canonical pill format. The model often
            // writes `• Título — 29 de mai., 16:00` instead of
            // `• Título (vence 29 mai)` — same info, different
            // syntax. Catch and rewrite so the parser renders
            // pills.
            if (trimmed.hasPrefix("•") || trimmed.hasPrefix("-")
                || trimmed.hasPrefix("*"))
                && !trimmed.contains("[") && !trimmed.contains("(") {
                let body = String(trimmed.dropFirst())
                    .trimmingCharacters(in: .whitespaces)
                var rewrote = false
                for sep in [" — ", " – ", " - "] {
                    if let r = body.range(of: sep) {
                        let title = stripBold(String(body[..<r.lowerBound]))
                            .trimmingCharacters(in: .whitespaces)
                        let detail = String(body[r.upperBound...])
                            .trimmingCharacters(in: CharacterSet(charactersIn: " .,"))
                        if !title.isEmpty && !detail.isEmpty {
                            output.append("• \(title) (vence \(detail))")
                            rewrote = true
                            break
                        }
                    }
                }
                if rewrote { i += 1; continue }
            }

            // Strip residual **bold** wrappers in plain prose.
            output.append(stripBold(raw))
            i += 1
        }

        return output.joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

    /// Matches `1. …` / `2) …` / `1- …` style list openers.
    private static let numberedItemRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"^\d+[.\)\-]\s+(.+)$"#)
    }()

    private static func stripBold(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "")
         .replacingOccurrences(of: "__", with: "")
    }

    /// Returns the substring after the first `label:` in `s`,
    /// case-insensitive. Returns nil if the label isn't there.
    private static func extractAfter(label: String, in s: String) -> String? {
        let lower = s.lowercased()
        guard let r = lower.range(of: label.lowercased() + ":")
            ?? lower.range(of: label.lowercased() + " :")
        else { return nil }
        let endOffset = lower.distance(from: lower.startIndex, to: r.upperBound)
        let realStart = s.index(s.startIndex, offsetBy: endOffset)
        return String(s[realStart...]).trimmingCharacters(in: .whitespaces)
    }

    /// If `s` is `[FOO]` or `**[FOO]**`, return `FOO`. Else nil.
    private static func bracketContent(_ s: String) -> String? {
        let cleaned = s.replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard cleaned.hasPrefix("["), cleaned.hasSuffix("]") else { return nil }
        return String(cleaned.dropFirst().dropLast())
    }

    /// Builds the user-facing prompt sent to `respond(to:)` /
    /// `streamResponse(to:)`. We concatenate prior assistant +
    /// user turns into one final user prompt so the model has
    /// the full chat context inline (Apollo's chat is mostly
    /// single-turn Q&A so this stays compact).
    private func userPrompt(from turns: [ChatTurn]) -> String {
        let convo = turns.filter { $0.role != .system }
        if convo.count <= 1 {
            return convo.last?.text ?? ""
        }
        // Multi-turn: prefix prior assistant replies as "Apollo
        // disse: ..." so the model knows what was already said.
        var lines: [String] = []
        for turn in convo.dropLast() {
            switch turn.role {
            case .user:      lines.append("Usuário: \(turn.text)")
            case .assistant: lines.append("Apollo: \(turn.text)")
            case .system:    break
            }
        }
        if let last = convo.last {
            lines.append(last.text)
        }
        return lines.joined(separator: "\n\n")
    }
}
