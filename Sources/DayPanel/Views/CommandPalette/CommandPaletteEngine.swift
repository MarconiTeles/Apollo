import SwiftUI
import Foundation

// Stateless engine that turns a query string + the current
// AppState into a ranked `[CommandPaletteItem]`. Called on
// every keystroke from the model.
//
// Everything visible to the user is searchable:
//
//   • Tasks (incl. subtasks at every depth + completed
//     ones) — title, description, list, status, tags
//   • Calendar events — title, location, notes, organizer,
//     attendee names + emails, calendar name
//   • Shared-calendar events — same fields, treated like
//     own events but tagged with the calendar owner
//   • Static commands — sync, settings, today, etc.
//
// Matching strategy (highest-scoring tier wins; items only
// surface if SOMETHING matches — never as a fallback):
//
//   • Exact prefix on title           → 2000 (substring at
//                                        position 0 + bonus)
//   • Substring match on any field    → 1200 - position
//   • All tokens present (multi-word) → 900  - avg-position
//   • Fuzzy subsequence (chars in     → 400  - span ÷ 2
//     order, scattered)
//
// Strings are folded to drop diacritics + case (`ç` ↔ `c`,
// `á` ↔ `a`) so a query typed in plain ASCII finds tasks
// titled with accents, and any case-mix matches.
enum CommandPaletteEngine {

    static func match(
        query rawQuery: String,
        appState: AppState
    ) -> [CommandPaletteItem] {
        let query = rawQuery.fold()
        var scored: [(score: Double, item: CommandPaletteItem)] = []

        // ── Static commands ──────────────────────────────────
        let commands = staticCommands(appState: appState)
        for (idx, cmd) in commands.enumerated() {
            if query.isEmpty {
                // Empty query → show every command in
                // declaration order. Anchor at 100 plus a
                // descending tail so the array index
                // becomes the visible row index.
                scored.append((100.0 - Double(idx) * 0.01, cmd))
                continue
            }
            let titleHay = cmd.title.fold()
            let subHay   = (cmd.subtitle ?? "").fold()
            if let s = scoreField(titleHay, query: query) {
                scored.append((s, cmd))
            } else if let s = scoreField(subHay, query: query) {
                scored.append((s * 0.55, cmd))
            }
        }

        // The rest of the entities only appear when there's
        // something to match against — they'd flood the
        // empty-state otherwise.
        guard !query.isEmpty else {
            scored.sort { $0.score > $1.score }
            return scored.prefix(40).map(\.item)
        }

        // ── Tasks ────────────────────────────────────────────
        for task in appState.tasks {
            let titleHay = task.title.fold()
            let metaHay  = taskMetaHaystack(task)
            let titleScore = scoreField(titleHay, query: query)
            let metaScore  = scoreField(metaHay,  query: query)
            guard let bestRaw = bestOf(titleScore, metaScore)
            else { continue }
            // Pending tasks live higher than completed ones
            // at equal raw score; completed still surface,
            // just deprioritised — common to look up a task
            // you finished last week.
            let completionPenalty: Double = task.isCompleted ? 60 : 0
            // Bias tasks above commands at equal score so a
            // fragment of a task title surfaces the task,
            // not a coincidentally-similar command.
            let item = makeTaskItem(task, appState: appState)
            scored.append((bestRaw + 25 - completionPenalty, item))
        }

        // ── Calendar events ──────────────────────────────────
        // Own calendar (Google + EventKit-bridged).
        for event in appState.events {
            if let raw = scoreEvent(event, query: query) {
                let item = makeEventItem(event,
                                          source: nil,
                                          appState: appState)
                // Slightly above tasks-on-equal-score: events
                // are time-sensitive, more likely the
                // immediate target.
                scored.append((raw + 10, item))
            }
        }

        // Shared (overlay) calendars — same scoring, but
        // tagged with the owner in the subtitle so the user
        // can tell which calendar surfaced the hit.
        for cal in appState.sharedCalendars {
            for event in appState.sharedEvents[cal.id] ?? [] {
                if let raw = scoreEvent(event, query: query) {
                    let item = makeEventItem(
                        event,
                        source: cal.name,
                        appState: appState)
                    scored.append((raw - 15, item))
                }
            }
        }

        scored.sort { $0.score > $1.score }
        return scored.prefix(50).map(\.item)
    }

    // MARK: - Static commands

    private static func staticCommands(appState: AppState)
        -> [CommandPaletteItem]
    {
        let menuBarOn = appState.menuBarMode
        return [
            CommandPaletteItem(
                id: "cmd.sync",
                title: "Sincronizar agora",
                subtitle: "Buscar mudanças do ClickUp e calendários",
                icon: "arrow.triangle.2.circlepath",
                tint: .blue,
                kind: .command,
                perform: {
                    Task { await appState.sync() }
                }
            ),
            CommandPaletteItem(
                id: "cmd.openSettings",
                title: "Abrir configurações",
                subtitle: "Calendário, ClickUp, AI, App",
                icon: "gearshape",
                tint: .gray,
                kind: .command,
                perform: {
                    appState.requestOpenSettings()
                }
            ),
            CommandPaletteItem(
                id: "cmd.toggleMenuBar",
                title: menuBarOn
                    ? "Sair do modo menu bar"
                    : "Entrar no modo menu bar",
                subtitle: menuBarOn
                    ? "Volta para janela principal"
                    : "Esconde a janela e fica no ícone da menu bar",
                icon: menuBarOn ? "macwindow" : "menubar.rectangle",
                tint: .gray,
                kind: .command,
                perform: {
                    appState.menuBarMode.toggle()
                }
            ),
            CommandPaletteItem(
                id: "cmd.clearStatusFilter",
                title: "Limpar filtro de status",
                subtitle: "Mostrar tarefas em todos os status",
                icon: "line.3.horizontal.decrease.circle",
                tint: .orange,
                kind: .command,
                perform: {
                    appState.selectedTaskStatus = nil
                }
            ),
            CommandPaletteItem(
                id: "cmd.jumpToday",
                title: "Ir para hoje",
                subtitle: "Reposiciona a timeline + lista no dia atual",
                icon: "calendar",
                tint: .red,
                kind: .command,
                perform: {
                    appState.selectedDate = Date()
                    appState.todayJumpToken &+= 1
                }
            ),
            CommandPaletteItem(
                id: "cmd.openOnboarding",
                title: "Reabrir tutorial",
                subtitle: "Volta ao wizard de boas-vindas (gestos, ⌘K)",
                icon: "graduationcap.fill",
                tint: .indigo,
                kind: .command,
                perform: {
                    appState.requestOpenOnboarding()
                }
            ),
        ]
    }

    // MARK: - Item builders

    private static func makeTaskItem(
        _ task: CUTask,
        appState: AppState
    ) -> CommandPaletteItem {
        // Subtitle: STATUS · LISTA · due-date (when present).
        var parts: [String] = [task.status.uppercased()]
        if !task.listName.isEmpty { parts.append(task.listName) }
        if let due = task.dueDate {
            parts.append(formatDate(due))
        }
        // Subtask hint: "↳ Subtarefa" prefix on the subtitle
        // so the user knows the row isn't a top-level task —
        // helpful when the matching title is the subtask
        // alone (e.g. "Reels" buried under "Camiseta…").
        if task.parentId != nil {
            parts.insert("↳ Subtarefa", at: 0)
        }
        return CommandPaletteItem(
            id: "task.\(task.id)",
            title: task.title,
            subtitle: parts.joined(separator: " · "),
            icon: task.isCompleted ? "checkmark.circle.fill" : "circle",
            tint: Color(hex: task.statusDisplayHex),
            kind: .task,
            perform: {
                appState.detailTaskOrigin = .zero
                withAnimation(.spring(duration: 0.45, bounce: 0.35)) {
                    appState.detailTask = task
                }
            }
        )
    }

    private static func makeEventItem(
        _ event: CalendarEvent,
        source: String?,
        appState: AppState
    ) -> CommandPaletteItem {
        // Subtitle: DATA · HORA · CALENDÁRIO/ATTENDEE-COUNT.
        var parts: [String] = [formatDate(event.startDate)]
        if !event.isAllDay {
            let timeFmt = DateFormatter()
            timeFmt.locale = Locale(identifier: "pt_BR")
            timeFmt.dateFormat = "HH:mm"
            parts.append(timeFmt.string(from: event.startDate))
        } else {
            parts.append("dia inteiro")
        }
        if let source { parts.append(source) }
        else if let cal = event.calendarName, !cal.isEmpty {
            parts.append(cal)
        }
        if event.attendees.count > 1 {
            parts.append("\(event.attendees.count) convidados")
        }
        return CommandPaletteItem(
            id: "event.\(event.id)",
            title: event.title,
            subtitle: parts.joined(separator: " · "),
            icon: "calendar",
            tint: Color(hex: event.colorHex),
            kind: .event,
            perform: {
                appState.detailEventOrigin = .zero
                withAnimation(.spring(duration: 0.45, bounce: 0.35)) {
                    appState.detailEvent = event
                }
            }
        )
    }

    // MARK: - Haystacks

    /// Concatenate every searchable field on a task into a
    /// single space-separated haystack — title, listName,
    /// status, every tag, AND the description. Folded once
    /// per call so the per-keystroke scoring stays cheap.
    private static func taskMetaHaystack(_ task: CUTask) -> String {
        var parts: [String] = [
            task.title,
            task.listName,
            task.status,
        ]
        for tag in task.tags { parts.append(tag.name) }
        if let desc = task.description, !desc.isEmpty {
            parts.append(desc)
        }
        return parts.joined(separator: " ").fold()
    }

    /// Score an event by combining title hits + a single
    /// "everything else" haystack (location, notes,
    /// organizer, attendee names + emails, calendar name).
    /// Title hits weigh full; other-field hits weigh 80%.
    private static func scoreEvent(_ event: CalendarEvent,
                                   query: String) -> Double?
    {
        let titleHay = event.title.fold()
        let titleScore = scoreField(titleHay, query: query)

        var other: [String] = []
        if let loc  = event.location, !loc.isEmpty   { other.append(loc) }
        if let note = event.notes,    !note.isEmpty  { other.append(note) }
        if let org  = event.organizerName, !org.isEmpty { other.append(org) }
        if let cal  = event.calendarName,  !cal.isEmpty { other.append(cal) }
        for a in event.attendees {
            other.append(a.name)
            if let e = a.email { other.append(e) }
        }
        let otherHay = other.joined(separator: " ").fold()
        let otherScore = scoreField(otherHay, query: query)
            .map { $0 * 0.80 }

        return bestOf(titleScore, otherScore)
    }

    // MARK: - Scoring

    /// Returns the highest-scoring match for `query`
    /// against `haystack`, or nil if neither substring nor
    /// token nor subsequence matches. Inputs MUST already
    /// be folded (lowercased + diacritic-stripped).
    private static func scoreField(_ haystack: String,
                                   query: String) -> Double?
    {
        guard !query.isEmpty, !haystack.isEmpty else { return nil }

        // Tier 1 — exact substring. Best signal of intent.
        if let r = haystack.range(of: query) {
            let pos = haystack.distance(
                from: haystack.startIndex, to: r.lowerBound)
            // Earlier-in-string is better; at-start gets a
            // big prefix bonus on top.
            let prefixBonus: Double = pos == 0 ? 800 : 0
            return 1200 - Double(pos) + prefixBonus
        }

        // Tier 2 — token-by-token (every word in `query`
        // appears somewhere in `haystack`, in any order).
        let tokens = query.split(separator: " ")
            .filter { !$0.isEmpty }
        if tokens.count > 1 {
            var totalPos = 0
            var allFound = true
            for tok in tokens {
                if let r = haystack.range(of: tok) {
                    totalPos += haystack.distance(
                        from: haystack.startIndex,
                        to: r.lowerBound)
                } else {
                    allFound = false
                    break
                }
            }
            if allFound {
                let avg = Double(totalPos) / Double(tokens.count)
                return 900 - avg
            }
        }

        // Tier 3 — fuzzy subsequence. Every character of
        // the (whitespace-stripped) query appears in
        // `haystack` in order. Score rewards tight matches
        // (small span = chars cluster together).
        let needle = query.replacingOccurrences(of: " ", with: "")
        guard !needle.isEmpty else { return nil }
        if let span = subsequenceSpan(haystack, needle: needle) {
            let extra = max(0, span - needle.count)
            return 400 - Double(extra) * 8
        }
        return nil
    }

    /// Returns the span (character count from first to last
    /// matched index) of the FIRST occurrence of `needle` as
    /// a subsequence in `haystack`. Greedy from the left.
    private static func subsequenceSpan(_ haystack: String,
                                        needle: String) -> Int?
    {
        guard !needle.isEmpty else { return 0 }
        let h = Array(haystack)
        let n = Array(needle)
        var firstMatch = -1
        var lastMatch  = -1
        var ni = 0
        for hi in 0..<h.count {
            if ni < n.count && h[hi] == n[ni] {
                if firstMatch < 0 { firstMatch = hi }
                lastMatch = hi
                ni += 1
                if ni == n.count { break }
            }
        }
        guard ni == n.count else { return nil }
        return lastMatch - firstMatch + 1
    }

    /// `max` of two optional scores, treating nil as
    /// "no match". Returns nil only when BOTH are nil.
    private static func bestOf(_ a: Double?, _ b: Double?)
        -> Double?
    {
        switch (a, b) {
        case (nil, nil):       return nil
        case (let x?, nil):    return x
        case (nil, let y?):    return y
        case (let x?, let y?): return max(x, y)
        }
    }

    // MARK: - Date

    private static func formatDate(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d)     { return "hoje" }
        if cal.isDateInTomorrow(d)  { return "amanhã" }
        if cal.isDateInYesterday(d) { return "ontem" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "pt_BR")
        fmt.dateFormat = "d MMM"
        return fmt.string(from: d)
    }
}

// MARK: - String folding

private extension String {
    /// Lowercase + drop diacritics so `Ç` ↔ `c`, `Á` ↔ `a`.
    /// `nil` locale uses the system root locale, which is
    /// what we want for the multilingual content
    /// ClickUp/Calendar surfaces.
    func fold() -> String {
        folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: nil
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
