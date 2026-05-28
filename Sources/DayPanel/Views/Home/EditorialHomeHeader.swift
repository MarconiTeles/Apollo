import SwiftUI

// Apollo · Editorial+ "Home" header (port of the Claude-design
// prototype's top band). Sits above the legacy timeline + tasks
// split on the .today route. Carries:
//
//   • Crumb folio "EDIÇÃO DE HOJE"
//   • Serif headline "Home"
//   • Italic byline "— a edição de [dia da semana] · [d 'de' MMM]"
//   • Stats row: date + 4 counts (Atrasadas / Tarefas / Eventos /
//     Livres) typeset as big serif numbers + caps labels
//   • Hairline
//   • Next-event highlight card (when there is one upcoming today)
//   • AGENDA / TAREFAS section labels (counts only — the actual
//     content is rendered by `dashboardSplit` below)

struct EditorialHomeHeader: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        // Page title (crumb + serif "Home" + byline) used to
        // live here, but was moved up into the toolbar as a
        // single compact serif badge — see ContentView's
        // `toolbarPageTitle`. The header now starts directly at
        // the stats row.
        VStack(alignment: .leading, spacing: 0) {
            statsRow
                .padding(.top, 22)
            Rectangle().fill(Editorial.rule).frame(height: 1)
                .padding(.top, 18)
                .padding(.horizontal, -28)
            if let next = nextEvent {
                nextEventCard(next)
                    .padding(.top, 22)
            }
            sectionLabels
                .padding(.top, 22)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 28)
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Stats row
    // ────────────────────────────────────────────────────────────────────

    private var statsRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 36) {
            // Date — folio + giant serif day + small italic month
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Folio(weekdayShort)
                Text("\(dayOfMonth)")
                    .font(Editorial.serif(34, .medium))
                    .foregroundStyle(Editorial.ink)
                    .monospacedDigit()
                Text(monthShort)
                    .font(Editorial.serif(15).italic())
                    .foregroundStyle(Editorial.inkSoft)
            }
            stat(value: overdueCount,  label: "ATRASADAS", accent: true)
            stat(value: tasksCount,    label: "TAREFAS")
            stat(value: eventsCount,   label: "EVENTOS")
            stat(valueText: freeHoursLabel, label: "LIVRES")
            Spacer(minLength: 0)
        }
    }

    private func stat(value: Int, label: String, accent: Bool = false) -> some View {
        stat(valueText: "\(value)", label: label, accent: accent)
    }

    private func stat(valueText: String, label: String, accent: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(valueText)
                .font(Editorial.serif(34, .medium))
                .foregroundStyle(accent ? Editorial.accent : Editorial.ink)
                .monospacedDigit()
            Text(label)
                .font(Editorial.sans(10.5, .semibold))
                .tracking(1.2)
                .foregroundStyle(accent ? Editorial.accent : Editorial.inkMute)
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Next event card
    // ────────────────────────────────────────────────────────────────────

    private func nextEventCard(_ ev: CalendarEvent) -> some View {
        let mins = max(0, Int(ev.startDate.timeIntervalSinceNow / 60))
        let crumbText = (ev.calendarName ?? "Evento").uppercased()
        return HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Folio(mins == 0 ? "Agora" : "Em \(mins) min", accent: true)
                Text(timeFmt(ev.startDate))
                    .font(Editorial.serif(28, .medium))
                    .foregroundStyle(Editorial.ink)
                    .monospacedDigit()
                Text("até \(timeFmt(ev.endDate))")
                    .font(Editorial.serif(11.5).italic())
                    .foregroundStyle(Editorial.inkMute)
            }
            .frame(width: 140, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Text(crumbText)
                    .font(Editorial.sans(10.5, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Editorial.inkMute)
                Text(ev.title)
                    .font(Editorial.serif(24, .medium))
                    .foregroundStyle(Editorial.ink)
                    .tracking(-0.3)
                    .lineLimit(2)
                if let sub = subline(for: ev) {
                    Text("— \(sub)")
                        .font(Editorial.serif(13).italic())
                        .foregroundStyle(Editorial.inkSoft)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let url = meetingURL(ev) {
                Link(destination: url) {
                    HStack(spacing: 6) {
                        Text("Entrar")
                            .font(Editorial.sans(12.5, .semibold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(Editorial.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(Editorial.page)
                    )
                    .overlay(
                        Capsule().strokeBorder(Editorial.rule, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Editorial.accent.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Editorial.accent.opacity(0.18), lineWidth: 0.5)
        )
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Section labels
    // ────────────────────────────────────────────────────────────────────

    private var sectionLabels: some View {
        // Two-column section header: AGENDA on the left,
        // TAREFAS on the right. The horizontal status pills
        // strip that used to live under TAREFAS was removed —
        // the right column now renders tasks GROUPED by
        // status (see `EditorialHomeTasksColumn`), so the
        // pills became redundant.
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            sectionLabel("Agenda", count: agendaCount)
                .frame(maxWidth: .infinity, alignment: .leading)
            sectionLabel("Tarefas", count: tasksCount)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionLabel(_ label: String, count: Int) -> some View {
        HStack(spacing: 10) {
            Folio(label)
            Text("\(count)")
                .font(Editorial.sans(11, .medium))
                .foregroundStyle(Editorial.inkFaint)
                .monospacedDigit()
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Status pills row (TAREFAS column)
    // ────────────────────────────────────────────────────────────────────

    /// Universe for the pill counts — non-completed + non-archived
    /// across `appState.tasks`. Matches the legacy `boardUniverse`
    /// in TaskListView so the numbers agree wherever they appear.
    private var statusBoardUniverse: [CUTask] {
        appState.tasks.filter { !$0.isCompleted && !$0.archived }
    }

    private var statusPillsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                statusLink(
                    label: "Todos",
                    count: statusBoardUniverse.count,
                    isActive: appState.selectedTaskStatus == nil,
                    onTap: { appState.selectedTaskStatus = nil }
                )
                let counts = Dictionary(grouping: statusBoardUniverse,
                                        by: \.status).mapValues(\.count)
                ForEach(appState.availableStatuses) { s in
                    statusLink(
                        label: s.status.capitalized,
                        count: counts[s.status] ?? 0,
                        isActive: appState.selectedTaskStatus == s.status,
                        color: Color(hex: s.displayHex),
                        onTap: {
                            appState.selectedTaskStatus =
                                appState.selectedTaskStatus == s.status
                                ? nil : s.status
                        }
                    )
                }
                Spacer(minLength: 24)
                sortLink
            }
            .padding(.vertical, 2)
        }
    }

    private func statusLink(
        label: String,
        count: Int,
        isActive: Bool,
        color: Color? = nil,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(label)
                    .font(Editorial.sans(13, isActive ? .semibold : .medium))
                    .foregroundStyle(isActive
                                     ? Editorial.ink
                                     : Editorial.inkSoft)
                Text("\(count)")
                    .font(Editorial.sans(11, .medium))
                    .foregroundStyle(Editorial.inkFaint)
                    .monospacedDigit()
            }
            .padding(.bottom, 4)
            .overlay(alignment: .bottom) {
                // Underline marks the active status (matches the
                // prototype's flat text-link style — no capsule).
                Rectangle()
                    .fill(isActive ? Editorial.ink : Color.clear)
                    .frame(height: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        // Tiny dot in front when the status has its own color —
        // mirrors the kanban column header style. Skipped on
        // "Todos" which has no color.
        .overlay(alignment: .leading) { EmptyView() }
        .help(label)
        // Color hint (small dot) placed BEFORE the label.
        .modifier(StatusDotPrefix(color: color))
    }

    /// Right-aligned "Ordenar" link. Stub for now — hooks up to
    /// a sort menu in a follow-up. Matches the prototype's
    /// styling (subdued text-link, no underline at rest).
    private var sortLink: some View {
        Button {
            // Sort menu — wired up in a follow-up.
        } label: {
            Text("Ordenar")
                .font(Editorial.sans(13, .semibold))
                .foregroundStyle(Editorial.ink)
                .padding(.bottom, 4)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Editorial.inkFaint)
                        .frame(height: 1.5)
                }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Data helpers
    // ────────────────────────────────────────────────────────────────────

    private var todayStart: Date { Calendar.current.startOfDay(for: Date()) }
    private var todayEnd:   Date {
        Calendar.current.date(byAdding: .day, value: 1, to: todayStart)!
    }

    private var todaysEvents: [CalendarEvent] {
        appState.eventsForToday
    }

    /// Next upcoming event from NOW, regardless of how far out.
    /// Spans the full event index — was previously scoped to
    /// today's events only, which meant the card vanished at
    /// midnight even with meetings booked for tomorrow.
    private var nextEvent: CalendarEvent? {
        let now = Date()
        return appState.events
            .filter { $0.endDate > now }
            .sorted   { $0.startDate < $1.startDate }
            .first
    }

    private var overdueCount: Int {
        let now = Date()
        return appState.pendingTasks.filter { t in
            guard let d = t.dueDate else { return false }
            return d < now
        }.count
    }

    private var tasksCount: Int {
        appState.pendingTasks.filter { t in
            guard let d = t.dueDate else { return false }
            return d >= todayStart && d < todayEnd
        }.count
    }

    private var eventsCount: Int { todaysEvents.count }
    private var agendaCount: Int { eventsCount }

    /// Free hours = (work window 9–18 = 9h) − sum of event durations
    /// clamped to that window, rounded to hours. Rough but useful at
    /// a glance.
    private var freeHoursLabel: String {
        let cal = Calendar.current
        let dayStart = cal.date(bySettingHour: 9,  minute: 0, second: 0, of: todayStart)!
        let dayEnd   = cal.date(bySettingHour: 18, minute: 0, second: 0, of: todayStart)!
        let windowSecs = dayEnd.timeIntervalSince(dayStart)
        let busy = todaysEvents.reduce(0.0) { acc, ev in
            let s = max(ev.startDate, dayStart)
            let e = min(ev.endDate,   dayEnd)
            return acc + max(0, e.timeIntervalSince(s))
        }
        let freeHours = max(0, (windowSecs - busy) / 3600)
        return "\(Int(freeHours.rounded()))h"
    }

    // ── Date formatters ────────────────────────────────────────────────

    private var weekdayName: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "EEEE"
        return f.string(from: Date())
    }
    private var weekdayShort: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "EEE"
        return f.string(from: Date()).replacingOccurrences(of: ".", with: "")
    }
    private var dayMonth: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "d 'de' MMMM"
        return f.string(from: Date())
    }
    private var dayOfMonth: Int { Calendar.current.component(.day, from: Date()) }
    private var monthShort: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "MMM"
        return f.string(from: Date()).replacingOccurrences(of: ".", with: "")
    }
    private func timeFmt(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    // ── Event helpers ──────────────────────────────────────────────────

    private func subline(for ev: CalendarEvent) -> String? {
        var bits: [String] = []
        if let loc = ev.location, !loc.isEmpty { bits.append(loc) }
        let names = ev.attendees
            .filter { !$0.isCurrentUser }
            .map(\.name)
            .filter { !$0.isEmpty }
            .prefix(3)
        if !names.isEmpty {
            bits.append("com " + names.joined(separator: ", "))
        }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    private func meetingURL(_ ev: CalendarEvent) -> URL? {
        if let u = ev.meetingURL { return u }
        if let s = ev.location {
            for token in s.split(whereSeparator: { " \n\t".contains($0) }) {
                if let u = URL(string: String(token)), u.scheme?.hasPrefix("http") == true {
                    return u
                }
            }
        }
        return nil
    }
}

/// Prefixes a status-color dot before the label content. No-op
/// when `color` is nil ("Todos" link has no color).
private struct StatusDotPrefix: ViewModifier {
    let color: Color?
    func body(content: Content) -> some View {
        if let color {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 6, height: 6)
                content
            }
        } else {
            content
        }
    }
}
