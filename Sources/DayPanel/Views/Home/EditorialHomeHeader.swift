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
        // the next event; the numeric summary strip was removed to
        // keep the top of Today focused on actionable content.
        VStack(alignment: .leading, spacing: 0) {
            // Next-event highlight card removed — the agenda column already
            // carries the upcoming event; the header keeps only the labels.
            sectionLabels
                .padding(.top, 22)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 28)
        .apolloStudioNode("inbox.header",
                          title: "Header do Inbox",
                          kind: .header,
                          parent: "inbox.page",
                          properties: [
                            .init(kind: .horizontalPadding,
                                  title: "Padding horizontal", value: 28),
                            .init(kind: .verticalPadding,
                                  title: "Respiro superior", value: 22),
                          ])
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Next event card
    // ────────────────────────────────────────────────────────────────────

    private func nextEventCard(_ ev: CalendarEvent) -> some View {
        let mins = max(0, Int(ev.startDate.timeIntervalSinceNow / 60))
        let crumbText = (ev.calendarName ?? "Evento").uppercased()
        return VStack(alignment: .leading, spacing: 0) {
          // 10 = 28 × 0.35 — gap between the time column and the title
          // column cut ~65%.
          HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Folio(mins == 0 ? "Agora" : "Em \(mins) min", accent: true)
                Text(timeFmt(ev.startDate))
                    .font(Editorial.serif(22, .medium))
                    .foregroundStyle(Editorial.ink)
                    .monospacedDigit()
                Text("até \(timeFmt(ev.endDate))")
                    .font(Editorial.serif(11.5).italic())
                    .foregroundStyle(Editorial.inkMute)
            }
            // Trimmed 140 → 112 so the leftover whitespace after the time
            // doesn't re-introduce the wide gap before the title.
            .frame(width: 112, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                Text(crumbText)
                    .font(Editorial.sans(10.5, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Editorial.inkMute)
                Text(ev.title)
                    // Sans (no serif) for the event title in this card.
                    .font(Editorial.sans(20, .semibold))
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

          // RSVP — "Você vai?" Sim / Não / Talvez, shown only when the
          // connected user is actually an attendee of this event.
          rsvpRow(ev)
        }
        // Background removed — the event sits flush on the page. The inner
        // horizontal inset goes too, so the content lines up with the section
        // labels below instead of being indented by a phantom card.
        .padding(.vertical, 6)
        .padding(.leading, 60)
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: RSVP ("Você vai?")
    // ────────────────────────────────────────────────────────────────────

    /// Presence-confirmation row for the hero card — only rendered when
    /// the connected user is one of the event's attendees. Mirrors the
    /// RSVP control in `EventDetailView` and routes to the same
    /// `appState.updateRSVP` (optimistic local + Google push).
    @ViewBuilder
    private func rsvpRow(_ ev: CalendarEvent) -> some View {
        if let me = ev.attendees.first(where: { $0.isCurrentUser }) {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Editorial.rule.opacity(0.65))
                    .frame(height: 0.5)
                    .edgeFadedHorizontal()
                    .padding(.top, 10)
                HStack(spacing: 8) {
                    Text("VOCÊ VAI?")
                        .font(Editorial.sans(10.5, .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Editorial.inkMute)
                    rsvpPill("Sim",    status: .accepted,  ev: ev, me: me)
                    rsvpPill("Não",    status: .declined,  ev: ev, me: me)
                    rsvpPill("Talvez", status: .tentative, ev: ev, me: me)
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
            }
        }
    }

    private func rsvpPill(_ label: String,
                          status: CalendarEvent.Attendee.Status,
                          ev: CalendarEvent,
                          me: CalendarEvent.Attendee) -> some View {
        let isCurrent = me.status == status
        return Button {
            appState.updateRSVP(for: ev, attendeeEmail: me.email, to: status)
        } label: {
            Text(label)
                .font(Editorial.sans(12, .medium))
                .foregroundStyle(isCurrent ? Editorial.page : Editorial.ink)
                .padding(.horizontal, 13)
                .padding(.vertical, 5)
                // Liquid Glass pill — ink-tinted when selected, neutral
                // page glass at rest.
                .liquidGlassCapsule(tint: isCurrent ? Editorial.ink : Editorial.page,
                                    tintOpacity: isCurrent ? 0.85 : 0.55)
                .overlay(
                    Capsule().strokeBorder(
                        isCurrent ? Color.clear : Editorial.rule,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .glassHover()
        .animation(.easeOut(duration: 0.16), value: isCurrent)
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Section labels
    // ────────────────────────────────────────────────────────────────────

    private var sectionLabels: some View {
        // Two-column section header: agenda on the left and the
        // unified ClickUp + Apollo inbox on the right.
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            sectionLabel("Agenda", count: agendaCount)
                .frame(maxWidth: .infinity, alignment: .leading)
            sectionLabel(
                "Inbox",
                count: appState.notifications.filter {
                    !$0.read && $0.isHomeInboxEligible
                }.count
            )
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

    private var eventsCount: Int { todaysEvents.count }
    private var agendaCount: Int { eventsCount }

    private func timeFmt(_ d: Date) -> String {
        SharedDateFormatters.shortTime24h.string(from: d)
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
