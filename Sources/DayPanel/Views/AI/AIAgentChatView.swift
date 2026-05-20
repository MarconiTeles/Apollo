import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Conversational UI for the in-app Apollo AI agent. Renders as
/// a popover anchored to the toolbar's sparkles button. Owns the
/// composer + a scrollable transcript of the current session.
struct AIAgentChatView: View {
    @EnvironmentObject var appState: AppState
    var onClose: () -> Void = {}

    @State private var draft: String = ""
    @FocusState private var composerFocused: Bool

    /// Files dropped / picked into the composer — identical UX to
    /// the task-comment box. Pushed into `appState.aiAgent` on
    /// send so the action executor turns them into real ClickUp
    /// attachments without a second native file panel.
    @State private var pendingAttachments: [URL] = []
    @State private var isDropTargeted: Bool = false

    /// Drives the staggered entrance of the home-screen
    /// (daily-summary) sections. Flips true once on appear so
    /// each block fades + rises in sequence; `@State` resets
    /// per open so the cascade replays every time the panel
    /// is launched.
    @State private var homeRevealed: Bool = false

    // MARK: - @-mention autocomplete
    //
    // When the user types `@` followed by characters (no
    // whitespace yet), `mentionQuery` becomes that suffix and
    // the contact picker appears above the composer. Selecting
    // a contact replaces `@<query>` in the draft with the
    // contact's full name and a trailing space, so the AI's
    // mention parser sees `@João Silva ` as one token.
    @State private var mentionQuery: String? = nil
    /// 0-based index of the currently-highlighted suggestion
    /// row, used by the picker for keyboard navigation.
    @State private var mentionSelectionIndex: Int = 0

    /// Live view of the Gemini cascade — when the user's
    /// preferred model has been bumped down to a lower-quality
    /// fallback because the daily quota ran out, the header
    /// reads `activeModel` to render a "degraded" badge.
    @StateObject private var geminiQuota = GeminiQuotaTracker.shared

    /// Live weather for the daily-summary masthead strip
    /// (IP-geolocated, 30-min cache; same source the old clock
    /// tile used).
    @StateObject private var weather = WeatherFetcher.shared

    var body: some View {
        // GlassEffectContainer (macOS 26+) groups every Liquid
        // Liquid-glass / popupGlass surface treatment was removed
        // by request: the AI panel reads cleaner as a flat,
        // opaque card now that the Apple-Intelligence-style
        // neon edge glow lives BEHIND it — the prior frosted
        // material muted the glow's colour bleed and added
        // double refraction with the dashboard surface.
        VStack(spacing: 0) {
            header
            // Embedded backend gates: if the user picked Apollo
            // IA (local) but never downloaded the model,
            // intercept the chat with a download CTA. Once the
            // model is on disk OR a download completes, the
            // normal transcript takes over.
            if appState.aiAgent.backend == .embedded
                && !appState.aiAgent.embeddedRuntime.isModelDownloaded
                && !isDownloadInFlight {
                modelMissingPanel
            } else if isDownloadInFlight {
                downloadingPanel
            } else {
                transcript
                if let err = appState.aiAgent.lastError {
                    errorBanner(err)
                }
            }
            composer
        }
        // Fill the entire host window — width AND height. The
        // header pins to the top edge, the composer pins to
        // the bottom edge, and the transcript ScrollView
        // (inside the body) absorbs the leftover vertical
        // space between them. The lack of a panel container
        // means each item naturally hugs its own intrinsic
        // width — header/tiles/composer already self-constrain
        // within their internal padding, so spreading the
        // host frame doesn't visually stretch any single
        // element edge-to-edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Hide the scroll indicators across the WHOLE Apollo-IA
        // panel — transcript, "diário do dia" columns, mention
        // picker. `.scrollIndicators(.hidden)` propagates via
        // the environment to any nested `ScrollView`, so we set
        // it once at the root instead of dotting it on each one.
        .scrollIndicators(.hidden)
        // No panel background, border, or shadow — the items
        // (header, suggestion tiles, composer) float directly
        // over the blurred dashboard backdrop installed at
        // ContentView level. Each item already carries its
        // own visual treatment (tile tints, capsule buttons,
        // composer field) so the lack of a containing surface
        // reads as "Apple Intelligence panel" instead of
        // "missing background".
        .onAppear {
            composerFocused = true
            weather.refreshIfStale()
            // Kick the staggered home-screen entrance on the
            // next runloop tick so the first frame is the
            // hidden state (otherwise the cascade is skipped).
            DispatchQueue.main.async { homeRevealed = true }
        }
    }

    /// Whether the runtime manager is currently streaming a
    /// download. Drives the in-chat progress bar.
    private var isDownloadInFlight: Bool {
        if case .downloading = appState.aiAgent.embeddedRuntime.status {
            return true
        }
        return false
    }

    // MARK: - Header

    /// The chat panel's top bar. With no conversation yet it is
    /// the newspaper masthead of the "diário do dia" summary;
    /// once a conversation starts it becomes the "— a coluna"
    /// chat header.
    @ViewBuilder
    private var header: some View {
        if appState.aiAgent.messages.isEmpty {
            dashboardMasthead
        } else {
            chatHeader
        }
    }

    /// Newspaper masthead for the daily-summary home screen
    /// (prototype `PAIDashboard`): wordmark + "— diário do dia",
    /// today's date in small-caps, a double ink rule.
    private var dashboardMasthead: some View {
        HStack(spacing: 12) {
            AIMark(size: 22)
            (
                Text("Apollo")
                    .font(Editorial.serif(17, .medium))
                    .foregroundColor(Editorial.ink)
                + Text("  — diário do dia")
                    .font(Editorial.serif(17).italic())
                    .foregroundColor(Editorial.inkSoft)
            )
            .tracking(-0.2)
            Spacer(minLength: 0)
            Text(Self.mastheadDate())
                .font(Editorial.sans(10.5, .semibold))
                .tracking(1.3)
                .foregroundStyle(Editorial.inkMute)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15))
                    .foregroundStyle(Editorial.inkSoft)
            }
            .buttonStyle(TBIconButtonStyle())
            .focusEffectDisabled()
            .help("Fechar")
        }
        .padding(.leading, 36)
        .padding(.trailing, 28)
        .frame(height: 64)
        .overlay(alignment: .bottom) {
            // Newspaper "2px double" bottom rule.
            VStack(spacing: 2) {
                Rectangle().fill(Editorial.ink.opacity(0.85))
                    .frame(height: 1)
                Rectangle().fill(Editorial.ink.opacity(0.85))
                    .frame(height: 1)
            }
        }
    }

    /// Abbreviated pt-BR date for the masthead, e.g.
    /// "SÁB, 16 MAI 2026".
    private static func mastheadDate(_ date: Date = Date()) -> String {
        let c = TodayCache.calendar.dateComponents(
            [.weekday, .day, .month, .year], from: date)
        let wd  = ["", "DOM", "SEG", "TER", "QUA",
                   "QUI", "SEX", "SÁB"]
        let mon = ["", "JAN", "FEV", "MAR", "ABR", "MAI", "JUN",
                   "JUL", "AGO", "SET", "OUT", "NOV", "DEZ"]
        let wi = c.weekday ?? 1
        let mi = c.month ?? 1
        let w = (1...7).contains(wi)  ? wd[wi]  : ""
        let m = (1...12).contains(mi) ? mon[mi] : ""
        return "\(w), \(c.day ?? 0) \(m) \(c.year ?? 0)"
    }

    private var chatHeader: some View {
        HStack(spacing: 12) {
            AIMark(size: 22)
            VStack(alignment: .leading, spacing: 2) {
                // "Apollo — a coluna" — the editorial masthead
                // (serif, with the italic inkSoft kicker).
                (
                    Text("Apollo")
                        .font(Editorial.serif(17, .medium))
                        .foregroundColor(Editorial.ink)
                    + Text("  — a coluna")
                        .font(Editorial.serif(17).italic())
                        .foregroundColor(Editorial.inkSoft)
                )
                .tracking(-0.2)
                providerLine
            }
            Spacer(minLength: 0)
            if !appState.aiAgent.messages.isEmpty {
                Button {
                    // Truly instant. The `transcript` view
                    // switches between `chatScroll` and
                    // `emptyState` via `.transition(...)`
                    // modifiers; SwiftUI would otherwise apply
                    // its default 0.35s branch animation.
                    // `withTransaction(disablesAnimations:true)`
                    // swaps the views in the SAME frame as the
                    // click so clearing feels instant.
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        appState.aiAgent.clearHistory()
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundStyle(Editorial.inkSoft)
                }
                .buttonStyle(TBIconButtonStyle())
                .focusEffectDisabled()
                .help("Limpar conversa")
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15))
                    .foregroundStyle(Editorial.inkSoft)
            }
            .buttonStyle(TBIconButtonStyle())
            .focusEffectDisabled()
            .help("Fechar")
        }
        .padding(.leading, 36)
        .padding(.trailing, 28)
        .frame(height: 64)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Editorial.rule).frame(height: 1)
        }
    }

    /// Sub-line under "Apollo IA" showing the active provider.
    /// For Gemini specifically, also shows a "cota diária esgotada"
    /// badge when the cascade has bumped the user down to a
    /// lower-quality fallback model — so the user knows the
    /// answer quality may have dropped vs. their preferred model.
    @ViewBuilder
    private var providerLine: some View {
        if appState.aiAgent.backend == .gemini,
           let active = geminiQuota.activeModel,
           let preferred = geminiQuota.preferredModel,
           active != preferred {
            // Why is the preferred model unavailable right now?
            // Daily quota = "esgotada hoje" (resets at midnight PT);
            // throttle = "limite por minuto" (resets in seconds).
            let isDaily = geminiQuota.isExhausted(preferred)
            let badgeText = isDaily ? "· cota diária esgotada"
                                    : "· limite por minuto"
            let helpText: String = {
                if isDaily {
                    return "Cota grátis diária do \(GeminiQuotaTracker.displayLabel(for: preferred)) acabou — usando \(GeminiQuotaTracker.displayLabel(for: active)) (qualidade menor) até a meia-noite Pacific (1h da manhã BRT)."
                } else {
                    return "Limite por minuto do \(GeminiQuotaTracker.displayLabel(for: preferred)) atingido — usando \(GeminiQuotaTracker.displayLabel(for: active)) por alguns segundos. Volta sozinho assim que a janela do Google libera."
                }
            }()
            HStack(spacing: 6) {
                Folio(GeminiQuotaTracker.displayLabel(for: active))
                Text(badgeText)
                    .font(Editorial.sans(9.5, .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Editorial.accent)
            }
            .help(helpText)
        } else {
            Folio(appState.aiAgent.providerName)
        }
    }

    // MARK: - Model-missing CTA

    /// Shown inside the chat when the user picked Apollo IA but
    /// never downloaded the GGUF (e.g. they skipped the
    /// onboarding step). Single button: "Baixar modelo (~4,6 GB)"
    /// kicks off `embeddedRuntime.downloadModel()`. Status flips
    /// to `.downloading` and the next render shows
    /// `downloadingPanel` instead.
    @ViewBuilder
    private var modelMissingPanel: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            AIMark(size: 34)
            VStack(spacing: 8) {
                Text("Apollo IA precisa de um modelo")
                    .font(Editorial.serif(24).italic())
                    .foregroundStyle(Editorial.ink)
                    .multilineTextAlignment(.center)
                Text("Modelo de ~4,6 GB, baixado uma vez. Roda 100% local depois — privacidade total.")
                    .font(Editorial.serif(14))
                    .foregroundStyle(Editorial.inkSoft)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            Button {
                Task { await appState.aiAgent.embeddedRuntime.downloadModel() }
            } label: {
                Text("Baixar modelo (~4,6 GB)")
            }
            .buttonStyle(PaperButtonStyle(active: true))
            .focusEffectDisabled()

            if case .failed(let msg) = appState.aiAgent.embeddedRuntime.status {
                Text(msg)
                    .font(Editorial.sans(11.5))
                    .foregroundStyle(Editorial.accent)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Live progress while the GGUF downloads — same layout as
    /// `modelMissingPanel` but the button is replaced by a
    /// progress bar with cancel.
    @ViewBuilder
    private var downloadingPanel: some View {
        let progress: (Double, Int64, Int64) = {
            if case .downloading(let f, let w, let t) = appState.aiAgent.embeddedRuntime.status {
                return (f, w, t)
            }
            return (0, 0, 0)
        }()
        let (fraction, written, total) = progress
        let pct = Int(round(fraction * 100))
        let writtenGB = Double(written) / 1_073_741_824
        let totalGB   = Double(total)   / 1_073_741_824

        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Text("\(pct)%")
                .font(Editorial.serif(48))
                .foregroundStyle(Editorial.accent)
                .monospacedDigit()
            VStack(spacing: 6) {
                Folio("Baixando modelo")
                Text(total > 0
                     ? String(format: "%.2f GB de %.2f GB", writtenGB, totalGB)
                     : String(format: "%.2f GB", writtenGB))
                    .font(Editorial.mono(12))
                    .foregroundStyle(Editorial.inkSoft)
            }
            ProgressView(value: max(0, min(1, fraction)))
                .progressViewStyle(.linear)
                .tint(Editorial.accent)
                .frame(maxWidth: 320)

            Button {
                appState.aiAgent.embeddedRuntime.cancelDownload()
            } label: {
                Text("Cancelar")
                    .font(Editorial.sans(12, .medium))
                    .foregroundStyle(Editorial.accent)
            }
            .buttonStyle(.plain).focusEffectDisabled()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcript: some View {
        if appState.aiAgent.messages.isEmpty {
            emptyState
                // Returning to the empty state (back button)
                // looks like a gentle "settle in" from above —
                // a soft scale-up + downward drift suggests
                // the suggestions card slid back into place.
                .transition(.asymmetric(
                    insertion: .opacity
                        .combined(with: .scale(scale: 0.97))
                        .combined(with: .offset(y: -8)),
                    removal: .opacity
                        .combined(with: .scale(scale: 0.96))
                ))
        } else {
            chatScroll
                // Entering the chat lifts up from the bottom,
                // matching the suggestion-tile launch motion.
                // Returning to suggestions slides it down and
                // away so the gesture has a clear back-vector.
                .transition(.asymmetric(
                    insertion: .opacity
                        .combined(with: .move(edge: .bottom)),
                    removal: .opacity
                        .combined(with: .offset(y: 12))
                ))
        }
    }

    private var chatScroll: some View {
        ScrollViewReader { proxy in
          // GeometryReader gives the scroll content a minimum
          // height equal to the viewport. WHY: the editorial
          // turns are far shorter than the old chat bubbles, so
          // a short conversation's total height is well under the
          // viewport. `proxy.scrollTo(bottomAnchor, anchor:.bottom)`
          // then aligned the 1pt sentinel to the viewport's
          // bottom edge and pushed the (short) content entirely
          // ABOVE the visible area — a blank white panel. Pinning
          // the content to `minHeight: viewport` + `.top` keeps
          // it visible when short, while still scrolling normally
          // (and honouring scroll-to-bottom) once it overflows.
          GeometryReader { geo in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(appState.aiAgent.messages) { msg in
                        messageBubble(msg)
                            .id(msg.id)
                    }
                    if !appState.aiAgent.liveThinking.isEmpty {
                        thinkingPreview(text: appState.aiAgent.liveThinking)
                    } else if appState.aiAgent.isThinking {
                        thinkingIndicator
                    }
                    // Sentinel anchor pinned at the very bottom
                    // of the scroll content. Used as the scroll
                    // target by every "stick to latest" trigger
                    // below — guaranteed to track the actual
                    // bottom edge regardless of what's there
                    // (last message, thinking dots, live
                    // chain-of-thought preview), unlike using
                    // the last message's id which falls behind
                    // when later content appends.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                }
                .padding(.horizontal, 80)
                .padding(.top, 32)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity,
                       minHeight: geo.size.height,
                       alignment: .top)
                .animation(.spring(response: 0.45, dampingFraction: 0.78),
                           value: appState.aiAgent.messages.count)
                .animation(.spring(response: 0.35, dampingFraction: 0.75),
                           value: appState.aiAgent.isThinking)
            }
            // Stick-to-bottom triggers — kept minimal on
            // purpose. Adding extra `.onChange` watchers (e.g.
            // for `isThinking`, `liveThinking`) layered render
            // work on top of every streamed token and could
            // freeze the app on long responses. Two signals
            // cover every real case:
            //
            //   • messages.count → new bubble inserted (user
            //     message OR first assistant token). Animated
            //     so the bubble visibly slides into view.
            //
            //   • messages.last?.text → tokens appending to
            //     the live assistant bubble. Not animated, so
            //     each token snaps the view down without a
            //     0.4s spring backlog piling up.
            //
            // The bottom-anchor sentinel below the LazyVStack
            // ensures these scrolls always land at the true
            // visual bottom (past any thinking-dots indicator
            // or live chain-of-thought preview that may render
            // after the last message).
            // Scroll on new-turn append (animated spring) AND
            // on streaming token append (snap, no animation —
            // the per-frame overhead of running the spring on
            // every token added measurable jitter to the
            // streaming feel). Two handlers are intentional —
            // they fire on different signals — but the cost per
            // fire is now low because MessageBody no longer
            // parses markdown / runs MessageParser during
            // streaming (see streamingTextView).
            .onChange(of: appState.aiAgent.messages.count) { _, _ in
                withAnimation(.spring(response: 0.35,
                                      dampingFraction: 0.85)) {
                    proxy.scrollTo(Self.bottomAnchorID,
                                   anchor: .bottom)
                }
            }
            .onChange(of: appState.aiAgent.messages.last?.text) { _, _ in
                proxy.scrollTo(Self.bottomAnchorID,
                               anchor: .bottom)
            }
          }
        }
    }

    /// Stable id for the bottom-of-scroll sentinel. Lifted out
    /// of the literal so the scroll handlers and the view that
    /// declares the anchor agree on a single value.
    private static let bottomAnchorID = "apollo-chat-bottom-anchor"

    // MARK: - Daily-summary home (prototype `PAIDashboard`)

    private struct DaySummary {
        var overdue: Int
        var oldestDays: Int
        var urgent: Int
        var todayEvents: Int
        // Meetings / agenda
        var meetingMinutes: Int
        var nextMeeting: CalendarEvent?
        var todaysMeetings: [CalendarEvent]
        var freeWindowMinutes: Int
        // Performance
        var completedWeek: Int
        var createdWeek: Int
        var onTimePct: Int?            // nil when no closed-with-due sample
        var completionsByDay: [Int]    // last 7 days, oldest → today
    }

    private struct DashRec: Identifiable {
        let id = UUID()
        let num: String
        let title: String
        let body: String
        let prompt: String
    }

    private var daySummary: DaySummary {
        let today = TodayCache.startOfToday
        let cal   = TodayCache.calendar
        let overdueTasks = appState.tasks.filter {
            !$0.isCompleted && ($0.dueDate.map { $0 < today } ?? false)
        }
        let oldest = overdueTasks.compactMap(\.dueDate).map {
            cal.dateComponents([.day],
                               from: cal.startOfDay(for: $0),
                               to: today).day ?? 0
        }.max() ?? 0
        let urgent = appState.tasks.filter {
            !$0.isCompleted && $0.priority == 1
        }.count
        let now = Date()
        let todays = appState.events
            .filter { !$0.isAllDay
                && cal.isDate($0.startDate, inSameDayAs: now) }
            .sorted { $0.startDate < $1.startDate }
        let meetMin = todays.reduce(0) {
            $0 + Int($1.endDate.timeIntervalSince($1.startDate) / 60)
        }
        let next = todays.first { $0.endDate > now }

        // Largest free gap inside today's 09:00–19:00 window.
        let dayStart = cal.date(bySettingHour: 9,  minute: 0,
                                second: 0, of: now) ?? now
        let dayEnd   = cal.date(bySettingHour: 19, minute: 0,
                                second: 0, of: now) ?? now
        var cursor = max(dayStart, now)
        var freeMax = 0
        for ev in todays where ev.endDate > cursor {
            if ev.startDate > cursor {
                freeMax = max(freeMax,
                    Int(ev.startDate.timeIntervalSince(cursor) / 60))
            }
            cursor = max(cursor, ev.endDate)
        }
        if dayEnd > cursor {
            freeMax = max(freeMax,
                Int(dayEnd.timeIntervalSince(cursor) / 60))
        }

        // Performance — last 7 days closed/created + on-time.
        let weekAgo = cal.date(byAdding: .day, value: -7, to: today)
            ?? today
        let closed = appState.completedTasksCached
        let completedWeek = closed.filter {
            ($0.dateClosed.map { $0 >= weekAgo }) ?? false
        }.count
        let createdWeek = appState.tasks.filter {
            ($0.dateCreated.map { $0 >= weekAgo }) ?? false
        }.count
        let closedWithDue = closed.filter {
            $0.dateClosed != nil && $0.dueDate != nil
        }
        let onTime: Int? = closedWithDue.isEmpty ? nil : {
            let ok = closedWithDue.filter {
                guard let c = $0.dateClosed, let d = $0.dueDate
                else { return false }
                return c <= cal.date(bySettingHour: 23, minute: 59,
                                     second: 59, of: d) ?? d
            }.count
            return Int((Double(ok) / Double(closedWithDue.count))
                       * 100.0 + 0.5)
        }()
        var byDay = [Int](repeating: 0, count: 7)
        for t in closed {
            guard let c = t.dateClosed else { continue }
            let d = cal.dateComponents([.day],
                from: cal.startOfDay(for: c), to: today).day ?? 99
            if d >= 0 && d <= 6 { byDay[6 - d] += 1 }
        }

        return DaySummary(overdue: overdueTasks.count,
                          oldestDays: oldest,
                          urgent: urgent,
                          todayEvents: todays.count,
                          meetingMinutes: meetMin,
                          nextMeeting: next,
                          todaysMeetings: todays,
                          freeWindowMinutes: freeMax,
                          completedWeek: completedWeek,
                          createdWeek: createdWeek,
                          onTimePct: onTime,
                          completionsByDay: byDay)
    }

    private func hhmm(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)min" }
        return m == 0 ? "\(h)h" : "\(h)h\(String(format: "%02d", m))"
    }

    private func timeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private func recommendations(_ s: DaySummary) -> [DashRec] {
        var r: [DashRec] = []
        func nn() -> String { String(format: "%02d", r.count + 1) }
        if s.overdue > 0 {
            r.append(DashRec(
                num: nn(),
                title: "Reagendar \(s.overdue) atrasada\(s.overdue == 1 ? "" : "s")",
                body: "Apollo distribui nos próximos dias úteis.",
                prompt: "Reagende as \(s.overdue) tarefas atrasadas distribuindo nos próximos dias úteis"))
        }
        if s.todayEvents == 0 {
            r.append(DashRec(
                num: nn(),
                title: "Bloquear janela de foco",
                body: "Dia livre — reserve um bloco de trabalho profundo.",
                prompt: "Bloqueie uma janela de foco de 3 horas hoje à tarde"))
        }
        if s.urgent > 0 {
            r.append(DashRec(
                num: nn(),
                title: "Priorizar \(s.urgent) urgente\(s.urgent == 1 ? "" : "s")",
                body: "Veja primeiro o que não pode esperar.",
                prompt: "Liste minhas tarefas urgentes e sugira a ordem de execução"))
        }
        if let m = s.nextMeeting, m.attendees.count >= 2 {
            r.append(DashRec(
                num: nn(),
                title: "Preparar p/ \(m.title)",
                body: "\(timeLabel(m.startDate)) · \(m.attendees.count) pessoas — quer um briefing?",
                prompt: "Me prepare para a reunião \"\(m.title)\" às \(timeLabel(m.startDate)): resuma o contexto, participantes e o que devo levar"))
        }
        if r.isEmpty {
            r.append(DashRec(
                num: "01",
                title: "Resumir meu dia",
                body: "Visão rápida do que importa hoje.",
                prompt: "Resuma meu dia"))
        }
        return Array(r.prefix(3))
    }

    private func headlineText(_ s: DaySummary) -> Text {
        let f = Editorial.serif(30)
        let fi = Editorial.serif(30).italic()
        if s.overdue > 0 {
            return Text("\(s.overdue) tarefas ")
                    .font(f).foregroundColor(Editorial.ink)
                + Text("atrasadas")
                    .font(fi).foregroundColor(Editorial.accent)
                + Text(" — a mais antiga há \(s.oldestDays) dia\(s.oldestDays == 1 ? "" : "s").")
                    .font(f).foregroundColor(Editorial.ink)
        }
        return Text("Nenhuma tarefa ")
                .font(f).foregroundColor(Editorial.ink)
            + Text("atrasada")
                .font(fi).foregroundColor(Editorial.accent)
            + Text(" — o dia está limpo.")
                .font(f).foregroundColor(Editorial.ink)
    }

    private func captionText(_ s: DaySummary) -> String {
        if s.todayEvents == 0 {
            return s.freeWindowMinutes >= 60
                ? "Dia livre, sem reuniões — \(hhmm(s.freeWindowMinutes)) de janela aberta pra trabalho profundo."
                : "Dia livre, sem reuniões. Boa janela pra adiantar o que importa."
        }
        let mt = hhmm(s.meetingMinutes)
        let fw = s.freeWindowMinutes >= 30
            ? " Maior janela livre: \(hhmm(s.freeWindowMinutes))."
            : ""
        return "\(s.todayEvents) reuni\(s.todayEvents == 1 ? "ão" : "ões") hoje · \(mt) no total.\(fw)"
    }

    /// The Apollo IA home screen — an elegant productivity
    /// magazine ("diário do dia"): a lead column with the
    /// headline, today's agenda and recommendations, and a
    /// number-led rail with weather, the day in figures and a
    /// weekly performance read. The composer footer stays put;
    /// sending (or accepting a recommendation) drops into chat.
    private var emptyState: some View {
        let s = daySummary
        return HStack(alignment: .top, spacing: 36) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Folio("Manchete do dia", accent: true)
                        headlineText(s)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 10)
                        Caption(captionText(s), size: 14)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 12)
                    }
                    .homeReveal(0, homeRevealed)
                    agendaSection(s).homeReveal(1, homeRevealed)
                    recommendationsSection(s).homeReveal(2, homeRevealed)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    weatherStrip.homeReveal(3, homeRevealed)
                    VStack(alignment: .leading, spacing: 0) {
                        Folio("Em números").padding(.bottom, 14)
                        dashStat(big: "\(s.overdue)", label: "atrasadas",
                                 sub: s.overdue > 0
                                    ? "a mais antiga há \(s.oldestDays) dia\(s.oldestDays == 1 ? "" : "s")"
                                    : "tudo em dia",
                                 accent: s.overdue > 0)
                        statDivider
                        dashStat(big: "\(s.urgent)", label: "urgentes",
                                 sub: nil, accent: false)
                        statDivider
                        dashStat(big: "\(s.todayEvents)", label: "reuniões hoje",
                                 sub: s.todayEvents == 0
                                    ? "nada agendado"
                                    : "\(hhmm(s.meetingMinutes)) no total",
                                 accent: false)
                    }
                    .homeReveal(4, homeRevealed)
                    performanceSection(s).homeReveal(5, homeRevealed)
                    Spacer(minLength: 0)
                }
            }
            .frame(width: 232)
            .padding(.leading, 30)
            .overlay(alignment: .leading) {
                Rectangle().fill(Editorial.rule).frame(width: 1)
            }
        }
        .padding(.top, 28)
        .padding(.leading, 40)
        .padding(.trailing, 36)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .topLeading)
    }

    // MARK: Magazine sections

    private func recommendationsSection(_ s: DaySummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Folio("Recomendações").padding(.bottom, 12)
            ForEach(recommendations(s)) { rec in
                dashRecRow(rec)
            }
        }
        .padding(.top, 26)
        .overlay(alignment: .top) {
            Rectangle().fill(Editorial.rule).frame(height: 1)
        }
    }

    @ViewBuilder
    private func agendaSection(_ s: DaySummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Folio("Agenda de hoje").padding(.bottom, 12)
            if s.todaysMeetings.isEmpty {
                Text("Sem reuniões hoje — a agenda está aberta.")
                    .font(Editorial.serif(14).italic())
                    .foregroundStyle(Editorial.inkSoft)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(s.todaysMeetings.prefix(5)),
                        id: \.id) { agendaRow($0) }
                if s.todaysMeetings.count > 5 {
                    Text("+ \(s.todaysMeetings.count - 5) mais")
                        .font(Editorial.sans(11))
                        .foregroundStyle(Editorial.inkMute)
                        .padding(.top, 8)
                }
            }
        }
        .padding(.top, 26)
        .overlay(alignment: .top) {
            Rectangle().fill(Editorial.rule).frame(height: 1)
        }
    }

    private func agendaRow(_ ev: CalendarEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(timeLabel(ev.startDate))
                .font(Editorial.sans(12, .medium))
                .foregroundStyle(Editorial.accent)
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 3) {
                Text(ev.title)
                    .font(Editorial.serif(15))
                    .foregroundStyle(Editorial.ink)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if !ev.attendees.isEmpty {
                        Text("\(ev.attendees.count) pessoas")
                            .font(Editorial.sans(11))
                            .foregroundStyle(Editorial.inkMute)
                    }
                    if ev.meetingURL != nil {
                        Text("· vídeo")
                            .font(Editorial.sans(11))
                            .foregroundStyle(Editorial.inkMute)
                    } else if let loc = ev.location,
                              !loc.isEmpty {
                        Text("· \(loc)")
                            .font(Editorial.sans(11))
                            .foregroundStyle(Editorial.inkMute)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            Text(hhmm(Int(ev.endDate
                .timeIntervalSince(ev.startDate) / 60)))
                .font(Editorial.sans(11))
                .foregroundStyle(Editorial.inkMute)
                .monospacedDigit()
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Editorial.ruleSoft).frame(height: 1)
        }
    }

    @ViewBuilder
    private var weatherStrip: some View {
        if let r = weather.current {
            VStack(alignment: .leading, spacing: 0) {
                Folio("O tempo")
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: r.icon)
                        .font(.system(size: 18))
                        .foregroundStyle(Editorial.inkSoft)
                    Text("\(r.tempC)°")
                        .font(Editorial.serif(28))
                        .foregroundStyle(Editorial.ink)
                        .tracking(-1)
                    Text(r.city)
                        .font(Editorial.sans(11))
                        .foregroundStyle(Editorial.inkMute)
                }
                .padding(.top, 6)
            }
            .padding(.bottom, 14)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Editorial.ruleSoft)
                    .frame(height: 1)
            }
            .padding(.bottom, 16)
        }
    }

    private func performanceSection(_ s: DaySummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Folio("Desempenho")
            weekBars(s.completionsByDay)
            Caption("fechadas nos últimos 7 dias", size: 11.5)
            HStack(alignment: .top, spacing: 22) {
                perfStat("\(s.completedWeek)", "fechadas · 7d")
                perfStat(s.onTimePct.map { "\($0)%" } ?? "—",
                         "no prazo")
            }
            .padding(.top, 4)
        }
        .padding(.top, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(Editorial.ruleSoft).frame(height: 1)
        }
        .padding(.top, 16)
    }

    private func perfStat(_ big: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(big)
                .font(Editorial.serif(22))
                .foregroundStyle(Editorial.ink)
                .monospacedDigit()
                .tracking(-0.8)
            Text(label)
                .font(Editorial.sans(10.5))
                .foregroundStyle(Editorial.inkMute)
        }
    }

    private func weekBars(_ counts: [Int]) -> some View {
        let peak = max(counts.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 7) {
            ForEach(Array(counts.enumerated()), id: \.offset) { i, c in
                VStack(spacing: 5) {
                    Text("\(c)")
                        .font(Editorial.sans(9))
                        .foregroundStyle(Editorial.inkMute)
                        .monospacedDigit()
                    RoundedRectangle(cornerRadius: 1,
                                     style: .continuous)
                        .fill(i == counts.count - 1
                              ? Editorial.accent
                              : Editorial.inkFaint)
                        .frame(width: 14,
                               height: max(3, CGFloat(c)
                                / CGFloat(peak) * 34))
                }
            }
        }
        .frame(height: 52, alignment: .bottom)
    }

    private var statDivider: some View {
        Rectangle().fill(Editorial.ruleSoft)
            .frame(height: 1)
            .padding(.vertical, 13)
    }

    private func dashStat(big: String, label: String,
                          sub: String?, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(big)
                .font(Editorial.serif(44))
                .foregroundStyle(accent ? Editorial.accent
                                        : Editorial.ink)
                .monospacedDigit()
                .tracking(-1.5)
            Text(label)
                .font(Editorial.sans(11.5))
                .foregroundStyle(Editorial.inkSoft)
            if let sub { Caption(sub, size: 11.5) }
        }
    }

    private func dashRecRow(_ rec: DashRec) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(rec.num)
                .font(Editorial.serif(24))
                .foregroundStyle(Editorial.inkFaint)
                .monospacedDigit()
                .tracking(-1)
            VStack(alignment: .leading, spacing: 4) {
                Text(rec.title)
                    .font(Editorial.serif(16, .medium))
                    .foregroundStyle(Editorial.ink)
                Text(rec.body)
                    .font(Editorial.serif(13.5))
                    .foregroundStyle(Editorial.inkSoft)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                draft = rec.prompt
                sendCurrentDraft()
            } label: {
                Text("Aceitar →")
            }
            .buttonStyle(PaperButtonStyle(active: true))
            .focusEffectDisabled()
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Editorial.ruleSoft).frame(height: 1)
        }
    }

    /// Editorial transcript turn — NO chat bubbles. A user turn
    /// is a pull-quote (ink left rule + italic serif + em-dash
    /// attribution); an assistant turn is a "Resposta" folio
    /// followed by the serif body.
    private func messageBubble(_ msg: ChatTurn) -> some View {
        let isStreaming = appState.aiAgent.streamingMessageId == msg.id
        return Group {
            if msg.role == .user {
                VStack(alignment: .leading, spacing: 5) {
                    Text("“\(msg.text)”")
                        .font(Editorial.serif(17).italic())
                        .foregroundStyle(Editorial.ink)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text("— Você")
                        .font(Editorial.sans(11))
                        .foregroundStyle(Editorial.inkMute)
                }
                .padding(.leading, 18)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Editorial.ink).frame(width: 2)
                }
                .frame(maxWidth: 720, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Folio("Resposta")
                    MessageBody(
                        text: msg.text,
                        isStreaming: isStreaming,
                        role: msg.role,
                        agendaIndex: appState.aiAgent.agendaIndex
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(msg.text, forType: .string)
            } label: {
                Label("Copiar", systemImage: "doc.on.doc")
            }
        }
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: 8)),
            removal:   .opacity
        ))
    }

    /// Bouncing-dots animation that conveys "still working" while
    /// the model hasn't streamed any token yet. Three dots that
    /// rise and fall in sequence with a shared phase loop.
    private var thinkingIndicator: some View {
        VStack(alignment: .leading, spacing: 10) {
            Folio("Resposta")
            HStack(spacing: 5) {
                BouncingDot(delay: 0.0)
                BouncingDot(delay: 0.15)
                BouncingDot(delay: 0.30)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }

    /// Live chain-of-thought preview shown while a reasoning
    /// model (qwen3.5, deepseek-r1) is in its `<thinking>` phase.
    /// Renders the thinking text in italic / faint colour above
    /// where the actual answer bubble will eventually appear, so
    /// the user has visual feedback that progress is happening.
    /// Only the LAST ~6 lines are visible — earlier reasoning is
    /// scrolled past as new chunks stream in.
    private func thinkingPreview(text: String) -> some View {
        let trimmed = text
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .suffix(6)
            .joined(separator: "\n")
        return VStack(alignment: .leading, spacing: 8) {
            Folio("Raciocínio", accent: true)
            Text(trimmed)
                .font(Editorial.serif(13.5).italic())
                .foregroundStyle(Editorial.inkMute)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(6)
                .truncationMode(.head)
        }
        .padding(.leading, 18)
        .overlay(alignment: .leading) {
            Rectangle().fill(Editorial.rule).frame(width: 2)
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Editorial.accent).frame(width: 6, height: 6)
            Text(message)
                .font(Editorial.serif(13.5))
                .foregroundStyle(Editorial.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 12)
        .background(Editorial.accentSoft)
        .overlay(alignment: .top) {
            Rectangle().fill(Editorial.rule).frame(height: 1)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 6) {
            // Contact picker — surfaces when the user types
            // `@` followed by zero-or-more non-space chars.
            // Filters by name/email substring as the user
            // types more after the `@`. Sits ABOVE the text
            // field so it doesn't collide with the system-
            // popover shadow at the bottom of the chat.
            if let query = mentionQuery {
                mentionPicker(query: query)
                    .padding(.horizontal, 36)
                    .padding(.top, 10)
                    .transition(.opacity.combined(
                        with: .move(edge: .bottom)))
            }

            VStack(alignment: .leading, spacing: 8) {
                // Queued attachments — drag-dropped or picked,
                // identical chips to the task-comment box.
                if !pendingAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(pendingAttachments, id: \.self) { url in
                                pendingAttachmentChip(url)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                HStack(alignment: .center, spacing: 14) {
                    AIMark(size: 16)
                    TextField("Pergunte algo, ou diga…  ·  arraste arquivos pra anexar",
                              text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Editorial.serif(15).italic())
                        .foregroundStyle(Editorial.ink)
                        .tint(Editorial.accent)
                        .lineLimit(1...4)
                        .focused($composerFocused)
                        .onSubmit { sendCurrentDraft() }
                        // Watch the draft so we can pop the picker
                        // open / close as `@`-tokens come and go.
                        .onChange(of: draft) { _, new in
                            recomputeMentionState(in: new)
                        }

                    // Paperclip — same affordance as the comment
                    // box; opens the sandbox file chooser.
                    Button { pickFilesIntoPending() } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(Editorial.inkSoft)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("Anexar arquivos")

                    Button(action: sendCurrentDraft) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(canSend ? Editorial.page
                                                     : Editorial.inkMute)
                            .frame(width: 32, height: 32)
                            .background(
                                (canSend ? Editorial.accent : Editorial.rule),
                                in: Circle()
                            )
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 14)
            .background(Editorial.accent.opacity(isDropTargeted ? 0.05 : 0))
            .overlay(alignment: .top) {
                // Accent + thicker top rule while a drag is over
                // the composer — mirrors the comment box's
                // accent drop-target border.
                Rectangle()
                    .fill(isDropTargeted ? Editorial.accent.opacity(0.55)
                                         : Editorial.rule)
                    .frame(height: isDropTargeted ? 2 : 1)
            }
            // Files dropped straight onto the composer (Finder,
            // Mail, Safari, iMessage) — identical to the task
            // comment box's `.onDrop(of: [.fileURL] …)`.
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) {
                handleDroppedProviders($0)
            }
        }
        // Pure white background to clearly delineate the composer
        // as a text input surface, separating it visually from the
        // cream paper canvas of the rest of the chat.
        .background(Editorial.page)
        .animation(.spring(response: 0.32, dampingFraction: 0.85),
                   value: pendingAttachments)
        .animation(.easeOut(duration: 0.16), value: isDropTargeted)
        .animation(.spring(response: 0.32, dampingFraction: 0.85),
                   value: mentionQuery)
    }

    // MARK: - Mention picker

    /// Floating list of contacts shown above the composer when
    /// `mentionQuery != nil`. Click selects a contact;
    /// otherwise typing more in the text field narrows the
    /// list further. Empty filter result → "Nenhum contato"
    /// state (still shown so the user knows the picker is
    /// active and isn't a hung UI).
    @ViewBuilder
    private func mentionPicker(query: String) -> some View {
        let matches = filteredContacts(for: query)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Folio(query.isEmpty
                      ? "Selecione um contato"
                      : "Buscando “\(query)”")
                Spacer(minLength: 0)
                Button {
                    mentionQuery = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Editorial.inkMute)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            if matches.isEmpty {
                Text("Nenhum contato encontrado")
                    .font(Editorial.serif(13).italic())
                    .foregroundStyle(Editorial.inkMute)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(matches.enumerated()),
                                id: \.element.id) { idx, contact in
                            mentionRow(contact, isHighlighted:
                                idx == mentionSelectionIndex)
                                .onTapGesture { selectMention(contact) }
                        }
                    }
                }
                .frame(maxHeight: 180)
                .padding(.bottom, 6)
            }
        }
        .background(
            Editorial.page,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Editorial.rule, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 20, y: 10)
    }

    private func mentionRow(_ contact: AIContact,
                            isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Editorial.accentSoft)
                    .frame(width: 24, height: 24)
                Image(systemName: contact.kind == .clickup
                      ? "person.fill"
                      : "envelope.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Editorial.accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(contact.name)
                    .font(Editorial.serif(14))
                    .foregroundStyle(Editorial.ink)
                    .lineLimit(1)
                if !contact.secondary.isEmpty {
                    Text(contact.secondary)
                        .font(Editorial.serif(11).italic())
                        .foregroundStyle(Editorial.inkSoft)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Folio(contact.kind == .clickup ? "ClickUp" : "Calendário")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            isHighlighted ? Editorial.accentSoft : Color.clear
        )
        .contentShape(Rectangle())
    }

    // MARK: - Mention state machine

    /// Walks the latest draft text to decide whether an `@`
    /// mention is currently being typed. Rule: the LAST `@`
    /// in the string, with NO whitespace between it and the
    /// end of the string, opens the picker. The text after
    /// `@` becomes the filter query. Anything else closes the
    /// picker.
    private func recomputeMentionState(in text: String) {
        guard let lastAt = text.lastIndex(of: "@") else {
            mentionQuery = nil; return
        }
        let after = text[text.index(after: lastAt)...]
        if after.contains(where: { $0.isWhitespace || $0.isNewline }) {
            mentionQuery = nil; return
        }
        mentionQuery = String(after)
        mentionSelectionIndex = 0
    }

    /// Replaces `@<query>` at the tail of `draft` with
    /// `@<contact name> ` and dismisses the picker. The
    /// trailing space tokenises the mention so the next `@`
    /// the user types opens a fresh picker for a different
    /// person.
    private func selectMention(_ contact: AIContact) {
        guard let lastAt = draft.lastIndex(of: "@") else {
            mentionQuery = nil; return
        }
        let prefix = draft[..<lastAt]
        draft = String(prefix) + "@" + contact.name + " "
        mentionQuery = nil
    }

    /// Builds a unified contact list (ClickUp + calendar) and
    /// filters by `query` (case-insensitive substring on name
    /// AND secondary field — username for ClickUp, e-mail for
    /// calendar). Top 8 results.
    private func filteredContacts(for query: String) -> [AIContact] {
        var roster: [AIContact] = []

        for member in appState.availableMembers {
            roster.append(AIContact(
                id:        "cu-\(member.id)",
                name:      member.username,
                secondary: member.email ?? "",
                kind:      .clickup
            ))
        }
        for contact in appState.calendarContacts {
            // Skip if a ClickUp member with same name already
            // covers this person — avoids two rows for the
            // same human.
            if roster.contains(where: {
                $0.name.lowercased() == contact.name.lowercased()
            }) { continue }
            roster.append(AIContact(
                id:        "cal-\(contact.email)",
                name:      contact.name,
                secondary: contact.email,
                kind:      .email
            ))
        }

        let q = query.lowercased()
        let filtered = q.isEmpty ? roster : roster.filter {
            $0.name.lowercased().contains(q)
                || $0.secondary.lowercased().contains(q)
        }
        return Array(filtered.prefix(8))
    }

    private var canSend: Bool {
        let hasText = !draft
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !pendingAttachments.isEmpty)
            && !appState.aiAgent.isThinking
            && appState.aiAgent.isConfigured
    }

    private func sendCurrentDraft() {
        guard canSend else { return }
        let trimmed = draft
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let files = pendingAttachments
        // Hand the dropped/picked files to the agent so the
        // action executor turns them into real ClickUp
        // attachments (one-shot, consumed by the emitted
        // create/comment/attach action — no second file panel).
        appState.aiAgent.pendingAttachments = files
        // Files but no instruction → give the model an explicit
        // attach request naming the files so it emits the right
        // action instead of just chatting.
        let text: String
        if trimmed.isEmpty, !files.isEmpty {
            let names = files.map(\.lastPathComponent)
                .joined(separator: ", ")
            text = files.count == 1
                ? "Anexe este arquivo (\(names))."
                : "Anexe estes \(files.count) arquivos (\(names))."
        } else {
            text = draft
        }
        draft = ""
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            pendingAttachments = []
        }
        // Synchronous submit — appends the user turn and flips
        // isThinking ON THE SAME runloop tick so the view
        // transitions out of the empty state immediately.
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            appState.aiAgent.submit(text)
        }
    }

    // MARK: - Composer attachments (drag-drop / paperclip)

    /// Sandbox-compatible chooser — same as the task-comment
    /// box's paperclip.
    private func pickFilesIntoPending() {
        let panel = NSOpenPanel()
        panel.title                   = "Anexar arquivos"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories    = false
        panel.canChooseFiles          = true
        guard panel.runModal() == .OK else { return }
        appendPending(panel.urls)
    }

    /// Files dropped straight onto the composer. Mirrors
    /// `TaskCommentsSection.handleDroppedProviders`.
    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { appendPending([url]) }
            }
        }
        return true
    }

    private func appendPending(_ urls: [URL]) {
        for url in urls where !pendingAttachments.contains(url) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                pendingAttachments.append(url)
            }
        }
        composerFocused = true
    }

    private func pendingAttachmentChip(_ url: URL) -> some View {
        let ext = url.pathExtension.lowercased()
        return HStack(spacing: 7) {
            Image(systemName: Self.chipIcon(ext))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Editorial.accent)
                .frame(width: 14)
            Text(url.lastPathComponent)
                .font(Editorial.sans(11.5))
                .foregroundStyle(Editorial.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                withAnimation(.spring(response: 0.3,
                                      dampingFraction: 0.85)) {
                    pendingAttachments.removeAll { $0 == url }
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Editorial.inkMute)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Remover anexo")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Editorial.page,
            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Editorial.rule, lineWidth: 1)
        )
    }

    private static func chipIcon(_ ext: String) -> String {
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff":
            return "photo"
        case "mp4", "mov", "m4v", "avi", "mkv":
            return "play.rectangle"
        case "mp3", "wav", "aac", "m4a", "flac":
            return "waveform"
        case "pdf":
            return "doc.richtext"
        case "zip", "rar", "7z", "tar", "gz":
            return "shippingbox"
        case "csv", "xls", "xlsx", "numbers":
            return "tablecells"
        case "key", "ppt", "pptx":
            return "rectangle.on.rectangle"
        case "doc", "docx", "pages", "txt", "md", "rtf":
            return "doc"
        default:
            return "paperclip"
        }
    }
}

// MARK: - Avatar (with optional pulse)

/// Apollo's gradient sparkle avatar. When `isPulsing` is true it
/// breathes gently (scale + accent halo) — used to highlight the
/// bubble currently being streamed into.
private struct AssistantAvatar: View {
    let isPulsing: Bool
    @State private var pulsePhase: Bool = false

    var body: some View {
        ZStack {
            // Animated halo — only visible while pulsing.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Editorial.accent.opacity(0.35), .clear],
                        center: .center,
                        startRadius: 2,
                        endRadius: 18
                    )
                )
                .frame(width: 36, height: 36)
                .opacity(isPulsing ? (pulsePhase ? 0.9 : 0.3) : 0)
                .scaleEffect(isPulsing && pulsePhase ? 1.15 : 0.8)
                .animation(
                    isPulsing
                    ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                    : .default,
                    value: pulsePhase
                )

            Circle()
                .fill(
                    LinearGradient(
                        colors: [Editorial.accent, Color(hex: "#FF8A4C")],
                        startPoint: .topLeading,
                        endPoint:   .bottomTrailing
                    )
                )
                .frame(width: 22, height: 22)
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 22, height: 22)
        .onAppear { if isPulsing { pulsePhase = true } }
        .onChange(of: isPulsing) { _, newValue in
            pulsePhase = newValue
        }
    }
}

// MARK: - Bouncing dot for the "thinking…" indicator

/// One of three dots that compose the bouncing-dots indicator.
/// Each dot is given an offset `delay` so the trio creates a
/// staggered wave rather than a synchronised pulse.
private struct BouncingDot: View {
    let delay: Double
    @State private var lifted: Bool = false

    var body: some View {
        Circle()
            .fill(Editorial.accent)
            .frame(width: 6, height: 6)
            .offset(y: lifted ? -3 : 3)
            .opacity(lifted ? 1 : 0.45)
            .animation(
                .easeInOut(duration: 0.55)
                    .repeatForever(autoreverses: true)
                    .delay(delay),
                value: lifted
            )
            .onAppear { lifted = true }
    }
}

// MARK: - Markdown-rendered message body with optional cursor

/// Renders a chat message's text:
///   • Light Markdown (bold, italic, code, links) parsed
///     inline so `**Daily Standup**` etc. show formatted.
///   • Leading `- ` and `* ` on lines turned into a Unicode
///     bullet ("•") for prettier list rendering.
///   • A blinking cursor "▋" appended while the bubble is
///     receiving streaming tokens — gives the feeling of the
///     model "typing".
///
/// User messages get the same treatment so a copy/paste with
/// markdown still renders well.
private struct MessageBody: View {
    let text: String
    let isStreaming: Bool
    let role: ChatRole
    /// Pass the current agenda index in via parameter rather
    /// than reading it via `@EnvironmentObject AppState`. With
    /// the EnvironmentObject dependency, EVERY `@Published`
    /// update anywhere in AppState (network status, sync
    /// progress, hover state, etc.) triggered a body
    /// re-evaluation of every visible message bubble — even
    /// when the bubble's own text and the agenda index were
    /// unchanged. With a value-typed parameter, the body
    /// re-runs only when one of `text`, `isStreaming`, `role`,
    /// or the index changes.
    let agendaIndex: AIAgentService.AgendaIndex

    var body: some View {
        // PERF: MessageParser still runs during streaming so the
        // user sees pills appear progressively as the model
        // emits each task / event line — that's the design the
        // app is built around. What we DON'T run during
        // streaming is `AttributedString(markdown:)` per text
        // block, which is the bigger of the two costs (full
        // markdown parser allocation + tokenization for every
        // token batch). Plain text blocks render with a simple
        // Text view while streaming and switch to the markdown
        // path once the message settles.
        let blocks = MessageParser.parse(
            text,
            agendaIndex: agendaIndex
        )

        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { idx, block in
                let isLast = (idx == blocks.count - 1)
                switch block {
                case .text(let s):
                    textBlock(s, withCursor: isLast && isStreaming)
                case .dayHeader(let s):
                    dayHeaderBlock(s)
                case .sectionHeader(let s):
                    sectionHeaderBlock(s)
                case .event(let e, let timeText):
                    EventChatPill(event: e, timeText: timeText)
                case .task(let t, let priorityText):
                    TaskChatPill(task: t, priorityText: priorityText)
                case .eventGhost(let title, let timeText):
                    EventChatPillGhost(title: title, timeText: timeText)
                case .taskGhost(let title, let status, let priority):
                    TaskChatPillGhost(title: title, statusText: status, priorityText: priority)
                }
            }
            // If the message ends on a non-text block while still
            // streaming, surface the cursor on its own line so the
            // user sees the model is still typing.
            if isStreaming, let last = blocks.last,
               !MessageParser.isText(last) {
                Text("▋")
                    .font(.subheadline)
                    .foregroundColor(.accentColor)
            }
        }
    }

    // MARK: Sub-views per block kind

    @ViewBuilder
    private func textBlock(_ raw: String, withCursor: Bool) -> some View {
        let prettified = raw
            .components(separatedBy: "\n")
            .map { line -> String in
                let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                let indent  = line.prefix(line.count - trimmed.count)
                if trimmed.hasPrefix("- ") {
                    return "\(indent)•\(trimmed.dropFirst(1))"
                }
                if trimmed.hasPrefix("* ") && !trimmed.hasPrefix("**") {
                    return "\(indent)•\(trimmed.dropFirst(1))"
                }
                return line
            }
            .joined(separator: "\n")

        let cursor: Text = withCursor
            ? Text(" ▋").foregroundColor(.accentColor)
            : Text("")

        // PERF: skip the markdown parser while the cursor is
        // still attached (i.e., this block is the live tail of
        // a streaming response). `AttributedString(markdown:)`
        // allocates a parser, tokenizes the input, and rewrites
        // the attribute graph — all expensive operations that
        // run on every flushed snapshot during streaming. Plain
        // Text rendering uses the same font / line spacing and
        // visually matches the markdown output for the common
        // case (bold/italic markers don't render until settled,
        // but the user prefers smooth streaming over progressive
        // styling). Once `withCursor` is false the message is
        // settled and we render the full markdown rendering.
        if withCursor {
            (Text(prettified) + cursor)
                .font(Editorial.serif(16))
                .lineSpacing(5)
                .foregroundStyle(Editorial.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let attributed: AttributedString = {
                let opts = AttributedString.MarkdownParsingOptions(
                    allowsExtendedAttributes: false,
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
                if let parsed = try? AttributedString(markdown: prettified,
                                                      options: opts) {
                    return parsed
                }
                return AttributedString(prettified)
            }()

            Text(attributed)
                .font(Editorial.serif(16))
                .lineSpacing(5)
                .foregroundStyle(Editorial.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func dayHeaderBlock(_ s: String) -> some View {
        Folio(s)
            .padding(.top, 6)
    }

    @ViewBuilder
    private func sectionHeaderBlock(_ s: String) -> some View {
        Folio(s, accent: true)
            .padding(.top, 4)
    }
}

// MARK: - Block parser

private enum MessageBlock {
    case text(String)
    case dayHeader(String)
    case sectionHeader(String)
    case event(CalendarEvent, timeText: String)
    case task(CUTask, priorityText: String?)
    case eventGhost(title: String, timeText: String)
    case taskGhost(title: String, status: String, priority: String?)
}

private enum MessageParser {

    static func isText(_ b: MessageBlock) -> Bool {
        if case .text = b { return true }
        return false
    }

    /// Split the AI response into a sequence of typed blocks so
    /// the chat can render rich pills (events/tasks) inline with
    /// the prose, instead of a wall of bullet text.
    static func parse(_ text: String,
                      agendaIndex: AIAgentService.AgendaIndex) -> [MessageBlock] {
        var blocks: [MessageBlock] = []
        var textBuffer: [String] = []

        func flushText() {
            let joined = textBuffer
                .joined(separator: "\n")
                .trimmingCharacters(in: CharacterSet(charactersIn: " \n"))
            if !joined.isEmpty {
                blocks.append(.text(joined))
            }
            textBuffer.removeAll(keepingCapacity: true)
        }

        // Index-based loop (vs `for in`) so we can lookahead and
        // skip the next line when we glue a wrapped task across
        // two lines.
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let rawLine = lines[i]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            // Day-header detector: "HOJE (29 de abr.):" /
            // "AMANHÃ (30 de abr.):" — also tolerates "Hoje:" /
            // "Amanhã:" with no parenthetical date.
            if let dh = matchDayHeader(trimmed) {
                flushText()
                blocks.append(.dayHeader(dh))
                i += 1; continue
            }

            // Section sub-header: "Eventos:" / "Tarefas
            // vencendo:" / "Tarefas:" — the model echoes these
            // straight from the system prompt.
            if matchSectionHeader(trimmed) {
                flushText()
                blocks.append(.sectionHeader(trimmed))
                i += 1; continue
            }

            // Event line: leading bullet + HH:MM-HH:MM + title.
            if let evt = matchEventLine(trimmed, index: agendaIndex) {
                flushText()
                blocks.append(evt)
                i += 1; continue
            }

            // Task line: leading bullet + title + [status] (· priority)?
            if let tsk = matchTaskLine(trimmed, index: agendaIndex) {
                flushText()
                blocks.append(tsk)
                i += 1; continue
            }

            // Two-line task (wrapped) — the model occasionally
            // breaks "• <title> [<status>] · <prio>" between
            // the title and the bracketed status. The first
            // half doesn't match `matchTaskLine` (no `[`) so
            // it'd otherwise fall through to plain text. Try
            // gluing this line to the next line and re-running
            // the matcher; if it succeeds we consume both
            // lines as a single task block.
            if looksLikeTaskTitleStart(trimmed),
               i + 1 < lines.count {
                let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if looksLikeTaskMetaContinuation(next) {
                    let glued = trimmed + " " + next
                    if let tsk = matchTaskLine(glued, index: agendaIndex) {
                        flushText()
                        blocks.append(tsk)
                        i += 2; continue
                    }
                }
            }

            // ── Last-resort title-only fallback ──────────────
            // Models sometimes emit malformed bullet lines that
            // skip the time/status portion ("• Daily Receita
            // Minimal |" with no time after the pipe, or just
            // "• Daily Receita Minimal" alone). When the title
            // cleanly matches a known event or task in the
            // agenda index, render as a real pill anyway —
            // visual consistency wins over format strictness.
            if let pill = looseLookupPill(trimmed, index: agendaIndex) {
                flushText()
                blocks.append(pill)
                // Swallow a dangling "[status..." continuation
                // that may follow on the next line — it was
                // the truncated meta of THIS task. Without
                // this we'd render "[review" as a stray text
                // block under the pill.
                if i + 1 < lines.count,
                   looksLikeTaskMetaContinuation(
                     lines[i + 1].trimmingCharacters(in: .whitespaces)
                   ) {
                    i += 2; continue
                }
                i += 1; continue
            }

            textBuffer.append(rawLine)
            i += 1
        }
        flushText()
        return blocks
    }

    /// Heuristic: this line looks like the START of a wrapped
    /// task (bullet + some text, but no `[<status>]` yet).
    /// Gives the lookahead path in `parse(...)` a chance to
    /// glue it with the next line and try matching the result
    /// as a task.
    private static func looksLikeTaskTitleStart(_ s: String) -> Bool {
        // Must lead with a bullet — or a subtask marker (`↳`) —
        // that we recognise. Subtasks wrap exactly like tasks,
        // so they get the same glue-and-retry treatment.
        let bulletPrefixes = ["• ", "•", "- ", "* ", "↳"]
        guard bulletPrefixes.contains(where: { s.hasPrefix($0) })
        else { return false }
        // Must NOT already contain a `[...]` block (otherwise
        // `matchTaskLine` would've matched on its own).
        if s.contains("[") && s.contains("]") { return false }
        // Must NOT be a time-range line (we'd hand that to the
        // event matcher instead).
        if let _ = try? NSRegularExpression(pattern: #"\d{1,2}:\d{2}\s*[-–]\s*\d{1,2}:\d{2}"#)
            .firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) {
            return false
        }
        // Must have actual content after the bullet.
        let after = s.drop { "•-* ".contains($0) }
        return !after.isEmpty
    }

    /// Looks up `s` (after stripping bullet + dangling
    /// formatting) against the agenda index. Progressive-
    /// fallback strategy: try the cleanest needle first, only
    /// strip more aggressively if no match yet. Critically we
    /// do NOT strip at `(` until everything else has failed —
    /// many real task titles have parentheticals like
    /// "(3 hooks)" or "(tarefas ainda serão destrinchadas)"
    /// that ARE part of the canonical title.
    private static func looseLookupPill(_ s: String,
                                        index: AIAgentService.AgendaIndex) -> MessageBlock? {
        var body = stripSubtaskMarker(s)
        for prefix in ["• ", "•", "- ", "* "] {
            if body.hasPrefix(prefix) {
                body = String(body.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }
        // Strip markdown emphasis up front — these never appear
        // in real ClickUp / Calendar titles, so it's safe to
        // remove unconditionally.
        body = body
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard body.count >= 3 else { return nil }

        // Build a list of progressively-cleaner candidates and
        // try each in order. First match wins — preserves
        // legitimate parentheticals when they're part of the
        // real title.
        let trimChars = CharacterSet(charactersIn: " \t·-–|│[(")

        // c0 — full body as-is. Catches lines that already
        // look like just the title ("• Daily Receita Minimal").
        let c0 = body.trimmingCharacters(in: trimChars)

        // c1 — strip everything from the first `[` onward.
        // Catches "• Title [status" half-emitted by the model.
        let c1 = body
            .components(separatedBy: "[")
            .first?
            .trimmingCharacters(in: trimChars)
            ?? c0

        // c2 — strip everything from the first `|` onward.
        // Catches "• Title | HH:MM-HH:MM" with garbage after.
        let c2 = body
            .components(separatedBy: "|")
            .first?
            .trimmingCharacters(in: trimChars)
            ?? c0

        // c3 — combined: strip at whichever of `[` or `|`
        // appears first (handles "• Title | HH:MM [status").
        let c3: String = {
            let a = body.firstIndex(of: "[")
            let b = body.firstIndex(of: "|")
            let cut: String.Index?
            switch (a, b) {
            case (let x?, let y?): cut = min(x, y)
            case (let x?, nil):    cut = x
            case (nil, let y?):    cut = y
            default:               cut = nil
            }
            guard let cut else { return c0 }
            return String(body[..<cut]).trimmingCharacters(in: trimChars)
        }()

        // c4 — last-resort: strip at first `(`. Only used when
        // every previous candidate has failed, because real
        // titles often include legit parentheticals.
        let c4 = body
            .components(separatedBy: "(")
            .first?
            .trimmingCharacters(in: trimChars)
            ?? c0

        let candidates = [c0, c1, c2, c3, c4]
        // De-dup while preserving order.
        var seen = Set<String>()
        let ordered = candidates.filter {
            !$0.isEmpty && $0.count >= 3 && seen.insert($0).inserted
        }

        for needle in ordered {
            if let event = index.event(matching: needle) {
                let f = DateFormatter()
                f.locale = Locale(identifier: "pt_BR")
                f.dateFormat = "HH:mm"
                let timeText = "\(f.string(from: event.startDate)) – \(f.string(from: event.endDate))"
                return .event(event, timeText: timeText)
            }
            if let task = index.task(matching: needle) {
                return .task(task, priorityText: nil)
            }
        }
        return nil
    }

    /// Heuristic: this line looks like the META portion of a
    /// task that wrapped from the previous line — i.e. starts
    /// with `[<status>] · <priority>` (no bullet of its own).
    private static func looksLikeTaskMetaContinuation(_ s: String) -> Bool {
        // Skip leading whitespace, must start with `[`.
        let trimmed = s.drop(while: { $0 == " " || $0 == "\t" })
        return trimmed.hasPrefix("[")
    }

    // MARK: - matchers

    /// Strips markdown decorations (`**bold**`, `*italic*`,
    /// `__bold__`, `_italic_`, leading `#` headers) from a line
    /// so the matchers and downstream pill renderers see the
    /// raw content. The current generation of models loves
    /// padding everything with markdown emphasis — without this
    /// the regex matchers see literal asterisks in titles and
    /// the pills end up displaying `**Minimal Closet - 0**`
    /// instead of `Minimal Closet - 0`.
    private static func stripMarkdown(_ s: String) -> String {
        var out = s
        // Leading `#` markdown headers (any depth).
        while out.hasPrefix("#") { out = String(out.dropFirst()) }
        out = out.trimmingCharacters(in: .whitespaces)
        // Bold + italic markers — repeat until stable so nested
        // markers like `**_text_**` collapse fully.
        var changed = true
        while changed {
            changed = false
            for pat in ["**", "__"] {
                if out.contains(pat) {
                    out = out.replacingOccurrences(of: pat, with: "")
                    changed = true
                }
            }
        }
        // Remaining single-underscore italics (avoid eating
        // intentional underscores in identifiers).
        if out.first == "*", out.last == "*" {
            out = String(out.dropFirst().dropLast())
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func matchDayHeader(_ s: String) -> String? {
        // Strip any leading markdown-header `#` markers and
        // bold/italic markers — models love wrapping headers
        // like `### **Hoje:**`.
        let cleaned = stripMarkdown(s)
        let lower = cleaned.lowercased()
        let keys = ["hoje", "amanhã", "amanha", "resto da semana"]
        guard keys.contains(where: { lower.hasPrefix($0) }) else { return nil }
        // Accept either ":" suffix or any header that's short
        // and starts with one of the keys (handles
        // "AMANHÃ (SEXTA-FEIRA, 1 DE MAIO) VOCÊ TEM").
        if cleaned.hasSuffix(":") {
            return String(cleaned.dropLast())
        }
        // Fallback: anything ≤ 80 chars starting with a key
        // is treated as a day header. Catches the markdown-
        // heavy headers the model emits like `### Amanhã
        // (Sexta-feira, 1/05)`.
        if cleaned.count <= 80 {
            return cleaned
        }
        return nil
    }

    private static func matchSectionHeader(_ s: String) -> Bool {
        // Strip markdown so `### **Eventos:**` is recognized
        // the same as plain `Eventos:`.
        let cleaned = stripMarkdown(s).lowercased()
        let candidates = ["eventos:", "tarefas:", "tarefas vencendo:",
                          "tarefas vencendo hoje:", "tarefas:",
                          "eventos", "tarefas", "tarefas vencendo",
                          "tarefas vencendo hoje"]
        return candidates.contains(cleaned)
    }

    /// Defensive event-line parser. Accepts every format the
    /// model has emitted in practice:
    ///   • "<title> | HH:MM-HH:MM"        (canonical, prompt-enforced)
    ///   • "<title> às HH:MM-HH:MM"       (PT-BR natural form)
    ///   • "HH:MM-HH:MM: <title>"         (legacy prompt format)
    ///   • "HH:MM-HH:MM <title>"          (em-dash / space variant)
    ///   • "HH:MM-HH:MM | <title>"        (reversed pipe)
    ///   • "<title> (HH:MM-HH:MM)"        (parenthetical)
    private static func matchEventLine(_ s: String,
                                       index: AIAgentService.AgendaIndex) -> MessageBlock? {
        var body = s
        for prefix in ["• ", "•", "- ", "* "] {
            if body.hasPrefix(prefix) {
                body = String(body.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        let timeRange = #"(\d{1,2}:\d{2})\s*[-–]\s*(\d{1,2}:\d{2})"#

        // Patterns to try in order. The first capture group
        // pair is always (title, start, end).  We use named
        // index lookups via tuple positions per pattern.
        let patterns: [(String, [String])] = [
            // "<title> | HH:MM-HH:MM"           groups: title, start, end
            (#"^(.+?)\s*[\|│]\s*"# + timeRange + "$",
             ["title", "start", "end"]),
            // "<title> às HH:MM-HH:MM"           groups: title, start, end
            (#"^(.+?)\s+às\s+"# + timeRange + "$",
             ["title", "start", "end"]),
            // "<title> (HH:MM-HH:MM)"            groups: title, start, end
            (#"^(.+?)\s*\("# + timeRange + #"\)$"#,
             ["title", "start", "end"]),
            // "HH:MM-HH:MM[:|–|space]<title>"   groups: start, end, title
            ("^" + timeRange + #"\s*[:\-–\|]?\s*(.+)$"#,
             ["start", "end", "title"])
        ]

        for (pattern, slots) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(
                    in: body,
                    range: NSRange(body.startIndex..., in: body)
                  ),
                  m.numberOfRanges == 4
            else { continue }

            var captures: [String: String] = [:]
            for i in 1...3 {
                guard let r = Range(m.range(at: i), in: body) else { continue }
                captures[slots[i - 1]] = String(body[r])
                    .trimmingCharacters(in: .whitespaces)
            }
            guard let titleRaw = captures["title"],
                  let start = captures["start"],
                  let end   = captures["end"]
            else { continue }

            // Strip markdown bold/italic from the captured
            // title — models commonly emit `**Daily Receita**`
            // and the agenda-index lookup fails on the literal
            // asterisks, falling back to a ghost pill that
            // still displays the asterisks. Cleaning up gives
            // both a real-event lookup match and a clean
            // visual.
            let title = stripMarkdown(titleRaw)

            let timeText = "\(start) – \(end)"
            if let event = index.event(matching: title) {
                return .event(event, timeText: timeText)
            }
            return .eventGhost(title: title, timeText: timeText)
        }
        return nil
    }

    /// Defensive task-line parser. Accepts:
    ///   • "<title> [<status>]"
    ///   • "<title> [<status>] · <priority>"
    ///   • "<title> [<status>] · vence <date>"
    ///   • "<title> (vence <date>)"          — RESTO DA SEMANA bullets
    ///   • "<title> (<status>, vence <date>)"— legacy fallback
    /// Strips a leading subtask marker so the CHILD title is what
    /// gets matched against the agenda index. The system prompt
    /// renders subtasks as `↳ subtarefa de "<Parent>": <Child> …`
    /// (see `AIAgentService`), so without this the needle would
    /// still carry the `↳ subtarefa de "…":` prefix and never
    /// resolve to the live `CUTask` — the subtask would fall
    /// through to the read-only ghost pill instead of a fully
    /// interactive `TaskChatPill`.
    private static func stripSubtaskMarker(_ s: String) -> String {
        // Tolerant of: an optional leading bullet, an optional
        // `↳` arrow, and either `subtarefa de "<Parent>":` or a
        // bare `subtarefa:` — the literal `subtarefa … :` is what
        // gates the strip, so plain (non-subtask) task lines pass
        // through untouched.
        let pattern =
            #"^\s*(?:[•·\-*]\s*)?(?:↳\s*)?subtarefa\s*(?:de\s+["“][^"”]*["”]\s*)?:\s*"#
        guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(
                in: s, range: NSRange(s.startIndex..., in: s)),
              m.range.length > 0,
              let r = Range(m.range, in: s)
        else { return s }
        return String(s[r.upperBound...])
            .trimmingCharacters(in: .whitespaces)
    }

    private static func matchTaskLine(_ s: String,
                                      index: AIAgentService.AgendaIndex) -> MessageBlock? {
        var body = stripSubtaskMarker(s)
        for prefix in ["• ", "•", "- ", "* "] {
            if body.hasPrefix(prefix) {
                body = String(body.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // 1) Canonical bracketed status form.
        let bracketed = #"^(.+?)\s*\[([^\]]+)\]\s*(?:·\s*(.+))?$"#
        if let regex = try? NSRegularExpression(pattern: bracketed),
           let m = regex.firstMatch(
            in: body,
            range: NSRange(body.startIndex..., in: body)
           ),
           m.numberOfRanges >= 3,
           let r1 = Range(m.range(at: 1), in: body),
           let r2 = Range(m.range(at: 2), in: body) {

            // Strip markdown emphasis from the title so models
            // emitting `**Minimal Closet - 0**` resolve to the
            // real task instead of falling through to a ghost
            // pill that displays the literal asterisks.
            let title  = stripMarkdown(String(body[r1]))
            let status = String(body[r2]).trimmingCharacters(in: .whitespaces)
            var priority: String?
            if m.numberOfRanges == 4, let r3 = Range(m.range(at: 3), in: body) {
                let p = String(body[r3]).trimmingCharacters(in: .whitespaces)
                if !p.isEmpty { priority = p }
            }
            if let task = index.task(matching: title) {
                return .task(task, priorityText: priority)
            }
            return .taskGhost(title: title, status: status, priority: priority)
        }

        // 2) Parenthetical "(vence X)" — RESTO DA SEMANA. Match
        //    the title against the index; only render a pill if
        //    we know the task (no ghost here, otherwise random
        //    parenthetical lines would all become pills).
        let parenthetical = #"^(.+?)\s*\(\s*(?:[^()]*?,\s*)?vence\s+([^)]+)\)\s*$"#
        if let regex = try? NSRegularExpression(pattern: parenthetical),
           let m = regex.firstMatch(
            in: body,
            range: NSRange(body.startIndex..., in: body)
           ),
           m.numberOfRanges >= 3,
           let r1 = Range(m.range(at: 1), in: body) {

            let title = stripMarkdown(String(body[r1]))
            if let task = index.task(matching: title) {
                return .task(task, priorityText: nil)
            }
        }
        return nil
    }
}

// MARK: - Inline pills

/// Compact event card sized for chat use. Mirrors the look of
/// `AgendaEventCard` (filled rounded rectangle in the calendar
/// colour, white title, time below) but at chat-bubble scale.
/// Tapping opens the same detail popup as the timeline card —
/// the popup zooms out of this pill's exact frame.
private struct EventChatPill: View {
    @EnvironmentObject var appState: AppState
    let event: CalendarEvent
    let timeText: String

    private var color: Color { Color(googleSnapHex: event.colorHex) }

    var body: some View {
        Button {
            // Anchor the detail popup to the user's click in
            // the MAIN window's coordinate space, then open
            // the detail ON TOP of the AI chat instead of
            // dismissing the chat first. The user wants the
            // chat to stay visible behind so closing the
            // detail returns them to the same chat context
            // (no need to reopen the AI panel and lose their
            // place in the conversation).
            let origin = MouseOriginCapture.currentClickRectInMainWindow()
            appState.detailEventOrigin = origin
            withAnimation(.spring(duration: 0.45, bounce: 0.35)) {
                appState.detailEvent = event
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Circle().fill(color).frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
                Text(event.title)
                    .font(Editorial.serif(15))
                    .foregroundStyle(Editorial.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(timeText)
                    .font(Editorial.sans(12, .medium))
                    .foregroundStyle(Editorial.inkSoft)
                    .monospacedDigit()
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Editorial.ruleSoft).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

/// Fallback pill when the AI mentions an event we don't have
/// indexed (paraphrased title, etc.). Same layout, accent colour.
/// Now interactive: tries to resolve the title against
/// `appState.events` at click-time and opens the matching
/// detail popup if found. The previous static-only ghost was
/// the source of "all chat-pill interactions are missing" —
/// any title with a leading markdown emphasis (`**foo**`) used
/// to fail the agendaIndex lookup, fall through to this ghost,
/// and lose its click handler.
private struct EventChatPillGhost: View {
    @EnvironmentObject var appState: AppState
    let title: String
    let timeText: String

    var body: some View {
        Button {
            tryOpen()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Circle().fill(Editorial.accent).frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
                Text(title)
                    .font(Editorial.serif(15))
                    .foregroundStyle(Editorial.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(timeText)
                    .font(Editorial.sans(12, .medium))
                    .foregroundStyle(Editorial.inkSoft)
                    .monospacedDigit()
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Editorial.ruleSoft).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func tryOpen() {
        // Live search through current events — handles cases
        // where the agendaIndex was stale or the title was
        // paraphrased. Substring fallback gated by needle
        // length so short titles ("Daily", "Teste") don't
        // accidentally open unrelated longer events.
        let needle = title.lowercased()
        let event = appState.events.first(where: { $0.title.lowercased() == needle })
            ?? (needle.count >= 8
                ? appState.events.first(where: { $0.title.lowercased().contains(needle) })
                : nil)
        guard let event else { return }
        // Keep the AI chat open behind the detail — see the
        // matching note in `EventChatPill`'s tap handler.
        let origin = MouseOriginCapture.currentClickRectInMainWindow()
        appState.detailEventOrigin = origin
        withAnimation(.spring(duration: 0.45, bounce: 0.35)) {
            appState.detailEvent = event
        }
    }
}

/// Compact task card for chat. Mirrors TaskRowView's design:
/// cream/secondary background, coloured status pill, title.
/// Tapping opens the task in the same detail popup used
/// elsewhere in the app, zooming out of this pill's frame.
private struct TaskChatPill: View {
    @EnvironmentObject var appState: AppState
    let task: CUTask
    let priorityText: String?

    @State private var completing: Bool = false
    @State private var hoveringCheckbox: Bool = false

    private var statusColor: Color { Color(hex: task.statusDisplayHex) }

    /// O(1) lookup against AppState's pre-resolved index. See
    /// `TaskRowView.doneTargetStatus` for full rationale.
    private var doneTargetStatus: CUStatus? {
        appState.doneTargetByStatus[task.status]
            ?? appState.doneTargetFallback
    }

    var body: some View {
        Button {
            // See `EventChatPill` for the same flow — detail
            // popup opens ON TOP of the AI chat without
            // dismissing it, so closing the detail returns
            // the user to the same chat context.
            let origin = MouseOriginCapture.currentClickRectInMainWindow()
            appState.detailTaskOrigin = origin
            withAnimation(.spring(duration: 0.45, bounce: 0.35)) {
                appState.detailTask = task
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                // Hover-to-DONE checkbox — 1:1 with the dashboard
                // row's `DonePillView` (editorial pill reveal),
                // not a bespoke chat affordance.
                checkboxButton

                VStack(alignment: .leading, spacing: 5) {
                    Text(task.title)
                        .font(Editorial.serif(15))
                        .foregroundStyle(task.isCompleted
                                         ? Editorial.inkMute : Editorial.ink)
                        .strikethrough(task.isCompleted,
                                       color: Editorial.inkMute)
                        .lineLimit(2)

                    // Status as editorial dot + word — same as
                    // the dashboard's `StatusPillView`.
                    HStack(spacing: 7) {
                        Circle().fill(statusColor)
                            .frame(width: 7, height: 7)
                        Text(task.status.capitalized)
                            .font(Editorial.sans(11.5, .medium))
                            .foregroundStyle(Editorial.inkSoft)
                            .tracking(0.2)
                    }
                }
                Spacer(minLength: 8)
                metaTrailing
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Editorial.ruleSoft).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    /// Right-aligned meta — relative date (cinnabar + "atrasada"
    /// when overdue) then the priority flag. Mirrors
    /// `TaskRowView.metaDateBadge` / `priorityBadge` exactly.
    @ViewBuilder
    private var metaTrailing: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let due = task.dueDate {
                let overdue = due < Date() && !task.isCompleted
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Self.relativeDateText(for: due))
                        .font(Editorial.sans(12, .medium))
                        .foregroundStyle(overdue ? Editorial.accent
                                                 : Editorial.inkSoft)
                        .monospacedDigit()
                    if overdue {
                        Text("atrasada")
                            .font(Editorial.serif(10.5).italic())
                            .foregroundStyle(Editorial.accent)
                    }
                }
            }
            if task.priority > 0 {
                Image(systemName: "flag.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: task.priorityHex))
                    .help(task.priorityLabel)
            }
        }
    }

    /// Hover-to-DONE checkbox — a quiet hairline circle that, on
    /// hover, reveals the editorial DONE pill (next status label
    /// in its own colour on a `page` chip with a `rule` hairline,
    /// scaling out from the leading edge), exactly like the
    /// dashboard `DonePillView`. Click advances the status via
    /// the same API and registers an undo, so completing a task
    /// from chat behaves identically to the list.
    private var checkboxButton: some View {
        let canAct  = !task.isCompleted && !completing
        let showPill = hoveringCheckbox && canAct && doneTargetStatus != nil
        let baseGlyph = task.isCompleted ? "checkmark.circle.fill"
                       : completing      ? "circle.dotted" : "circle"
        let baseTint: Color = task.isCompleted
            ? Editorial.statusColor("complete")
            : Editorial.inkFaint

        return Button {
            commitDone()
        } label: {
            ZStack(alignment: .leading) {
                Image(systemName: baseGlyph)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(baseTint)
                    .symbolEffect(.bounce, value: task.isCompleted)
                    .frame(width: 16, height: 16)
                    .opacity(showPill ? 0 : 1)

                if showPill, let target = doneTargetStatus {
                    Text(target.status.uppercased())
                        .font(Editorial.sans(10, .semibold))
                        .tracking(0.4)
                        .foregroundStyle(Color(hex: target.displayHex))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(
                            Editorial.page,
                            in: RoundedRectangle(cornerRadius: 4,
                                                 style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4,
                                             style: .continuous)
                                .strokeBorder(Editorial.rule, lineWidth: 1)
                        )
                        .fixedSize()
                        .transition(
                            .scale(scale: 0.85, anchor: .leading)
                                .combined(with: .opacity)
                        )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(task.isCompleted || completing || doneTargetStatus == nil)
        .animation(.spring(response: 0.30, dampingFraction: 0.62),
                   value: showPill)
        .scrollAwareOnHover { hover in
            hoveringCheckbox = hover
        }
    }

    /// Advance to the resolved DONE target and register an undo —
    /// the same pipeline `TaskRowCellView.commitDoneAction` uses
    /// so the list and the chat stay behaviourally identical.
    private func commitDone() {
        guard !task.isCompleted, !completing else { return }
        guard let target = doneTargetStatus else { return }
        let originalStatusName = task.status
        let snapshot = task
        completing = true
        Task {
            await appState.updateTaskStatus(snapshot, to: target)
            completing = false
            appState.pushUndo(
                label: "“\(snapshot.title)” → \(originalStatusName.uppercased())"
            ) {
                if let restore = appState.availableStatuses
                    .first(where: { $0.status == originalStatusName }) {
                    await appState.updateTaskStatus(snapshot, to: restore)
                }
            }
        }
    }

    /// Mirror of `TaskRowView.relativeDateText(for:)` so chat
    /// task rows read dates identically to the dashboard list.
    private static func relativeDateText(for date: Date) -> String {
        let now    = TodayCache.startOfToday
        let target = TodayCache.calendar.startOfDay(for: date)
        let days   = TodayCache.calendar
            .dateComponents([.day], from: now, to: target).day ?? 0
        switch days {
        case 0:         return "Hoje"
        case 1:         return "Amanhã"
        case -1:        return "Ontem"
        case 2...6:     return "em \(days) dias"
        case -6 ... -2: return "\(-days) dias atrás"
        default:
            return SharedDateFormatters.shortDayMonthPTBR.string(from: date)
        }
    }
}

/// Frame-capture preference for chat pills so the detail popup
/// can zoom out of the exact pill location.
private struct PillFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// Tiny press-state helper so tap-down/tap-up can drive a
/// scale animation. Kept (still used by the suggestion tile's
/// custom `triggerLaunch` flow) — not used by EventChatPill /
/// TaskChatPill which now use `interactivePillFeedback`.
private extension View {
    func pressEvents(onPress: @escaping () -> Void,
                     onRelease: @escaping () -> Void) -> some View {
        self.simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in onPress() }
                .onEnded { _ in onRelease() }
        )
    }

    /// Staggered home-screen entrance: each section fades up
    /// from +16pt with a per-index delay once `on` flips true.
    func homeReveal(_ index: Int, _ on: Bool) -> some View {
        self
            .opacity(on ? 1 : 0)
            .offset(y: on ? 0 : 16)
            .animation(
                .spring(response: 0.55, dampingFraction: 0.86)
                    .delay(0.05 + Double(index) * 0.07),
                value: on)
    }
}

/// Fallback task pill — same look but no live status colour
/// (we don't have the CUStatus, so we pick a neutral grey).
/// Now interactive: tries to resolve the title against
/// `appState.tasks` at click-time and opens the matching
/// detail popup if found.
private struct TaskChatPillGhost: View {
    @EnvironmentObject var appState: AppState
    let title: String
    let statusText: String
    let priorityText: String?

    /// Best-effort match against AppState's known statuses so the
    /// ghost pill can show the same accent border as the live
    /// `TaskChatPill`. Falls back to grey when no match exists
    /// (e.g. AI invented a status name we don't have).
    private var resolvedStatusColor: Color {
        let needle = statusText.lowercased()
        if let hit = appState.availableStatuses.first(
            where: { $0.status.lowercased() == needle }
        ) {
            return Color(hex: hit.displayHex)
        }
        return Color.gray
    }

    var body: some View {
        Button {
            tryOpen()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "circle")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Editorial.inkFaint)
                    .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(Editorial.serif(15))
                        .foregroundStyle(Editorial.ink)
                        .lineLimit(2)

                    HStack(spacing: 7) {
                        Circle().fill(resolvedStatusColor)
                            .frame(width: 7, height: 7)
                        Text(statusText.capitalized)
                            .font(Editorial.sans(11.5, .medium))
                            .foregroundStyle(Editorial.inkSoft)
                            .tracking(0.2)
                    }
                }
                Spacer(minLength: 8)
                if let prio = priorityText, !prio.isEmpty {
                    Text(prio)
                        .font(Editorial.sans(11))
                        .foregroundStyle(Editorial.inkMute)
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Editorial.ruleSoft).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func tryOpen() {
        let needle = title.lowercased()
        // Exact match first. Substring fallback only when the
        // needle is long enough (≥8 chars) — short titles like
        // "Teste" or "Daily" otherwise substring-matched a
        // bunch of unrelated tasks ("Reels Balda - Teste do
        // tecido", "Daily Receita Minimal", etc.) and clicking
        // the pill opened a random task.
        let task = appState.tasks.first(where: { $0.title.lowercased() == needle })
            ?? (needle.count >= 8
                ? appState.tasks.first(where: { $0.title.lowercased().contains(needle) })
                : nil)
        guard let task else { return }
        // Keep the AI chat open behind the detail — see the
        // matching note in `TaskChatPill`'s tap handler.
        let origin = MouseOriginCapture.currentClickRectInMainWindow()
        appState.detailTaskOrigin = origin
        withAnimation(.spring(duration: 0.45, bounce: 0.35)) {
            appState.detailTask = task
        }
    }
}

// MARK: - Empty state (Apollo IA hero)

/// First-impression hero shown the moment the chat opens with no
/// history. Inspired by Siri / Apple Intelligence: a breathing
/// orb of layered radial gradients fades in first, then the
/// title, the subtitle, and the suggestion chips cascade in
/// one-by-one. Continuous animations keep the orb feeling
/// "alive" even after the cascade settles.
private struct EmptyStateView: View {
    /// Live state — the `suggestions` computed property reads
    /// from this to surface counts, next-meeting times,
    /// overdue warnings, and progress bars right inside the
    /// tiles. Without this the panel would still work but
    /// every tile would show a generic static label.
    @EnvironmentObject var appState: AppState
    let isConfigured: Bool
    let onSuggestion: (String) -> Void
    /// Whether to play the staggered entrance cascade. The
    /// cascade is delightful on first popover-open but feels
    /// like lag when the user clicks the back button to
    /// return to suggestions: ~1s of animation between click
    /// and "I can interact again". Caller passes `true` only
    /// for the first appearance per popover session;
    /// subsequent appearances jump straight to the settled
    /// state.
    var playEntranceCascade: Bool = true
    /// Fired once the cascade has been requested (first
    /// appearance per session). The service uses this to flip
    /// its `hasShownEmptyEntrance` flag so subsequent renders
    /// skip the cascade and feel instant.
    var onCascadeShown: () -> Void = {}

    /// Cascade reveal: bumped from 0 (hidden) up through 5
    /// (everything visible) on appear, with a small delay
    /// between each step. SwiftUI animates each modifier that
    /// depends on `phase` automatically thanks to the
    /// per-element `.animation(_:value:)` modifiers below.
    @State private var phase: Int = 0

    /// Continuous loops — independent of the cascade phase.
    @State private var halo1Pulse: Bool = false
    @State private var halo2Pulse: Bool = false
    @State private var sparkleRotate: Double = 0
    @State private var hueShift: Double = 0

    var body: some View {
        // Wrap the hero stack in a ScrollView so users on
        // smaller windows (or with the chat resized down) can
        // still reach every suggestion tile + the API-key
        // disclaimer. `.scrollBounceBehavior(.basedOnSize)`
        // means the bounce only kicks in when content actually
        // overflows — taller windows still feel rigid.
        ScrollView(.vertical, showsIndicators: false) {
            // Tighter overall vertical rhythm — was 16pt
            // between sections + 8pt orb top padding + 12pt
            // outer vertical padding, which left a visible
            // gap above and below the orb's halo. Compressing
            // those numbers (and removing the orb's extra
            // top-padding entirely) makes the hero block
            // sit closer to the title without changing the
            // suggestion grid's density.
            // Hero block (orb + "O que você quer saber?" title +
            // subtitle) was removed by request — the AI chat
            // panel now opens straight into the suggestion grid
            // so the tiles get more vertical real estate and
            // the panel reads as content-first instead of
            // hero-first.
            VStack(spacing: 8) {
                // 2% of the panel's vertical area as breathing
                // room between the header bar and the start of
                // the suggestion grid. `containerRelativeFrame`
                // pulls the panel height from the nearest
                // scroll container so the spacer scales with
                // the popover instead of being a hard-coded pt
                // value that could feel cramped on a tall
                // window or oversized on a short one.
                Color.clear
                    .containerRelativeFrame(.vertical) { height, _ in
                        height * 0.02
                    }
                    .frame(maxWidth: .infinity)

                // Tiled suggestion grid — Apple-keynote-style
                // layout with mixed sizes, icons, gradient tints,
                // and Liquid Glass surfaces. Each tile cascades
                // in with its own staggered delay relative to
                // `phase`.
                //
                // `containerRelativeFrame` clamps the grid to
                // 90% of the chat panel's width so the row of
                // tiles takes up 10% less horizontal area than
                // the panel itself — the breathing room on
                // each side keeps the cluster from running
                // into the panel's edge frosted glass.
                suggestionGrid
                    .containerRelativeFrame(.horizontal) { width, _ in
                        width * 0.90
                    }

                if !isConfigured {
                    Label("Configure a API key em Configurações → Apollo IA",
                          systemImage: "key.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.top, 4)
                        .padding(.bottom, 12)
                        .opacity(phase >= 5 ? 1 : 0)
                        .animation(.easeOut(duration: 0.5).delay(0.65),
                                   value: phase)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear { startEntrance() }
    }

    // MARK: - Orb (Apple Intelligence-style aurora)

    /// Breathing orb made of three overlapping radial gradients
    /// in different hues, plus the central sparkle glyph that
    /// rotates extremely slowly (one full turn per ~28 s) and
    /// hue-shifts so the colours feel never quite the same.
    private var orb: some View {
        ZStack {
            // Outer halo — biggest, faintest, slowest pulse.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Editorial.accent.opacity(0.30),
                            Color(hex: "#A875FF").opacity(0.18),
                            .clear
                        ],
                        center: .center,
                        startRadius: 6,
                        endRadius: 80
                    )
                )
                .frame(width: 160, height: 160)
                .scaleEffect(halo1Pulse ? 1.08 : 0.92)
                .opacity(halo1Pulse ? 0.95 : 0.55)
                .blur(radius: 8)

            // Middle halo — orange/pink wash, faster pulse,
            // offset slightly to break the perfect symmetry.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(hex: "#FF8A4C").opacity(0.32),
                            Color(hex: "#FF5E8A").opacity(0.14),
                            .clear
                        ],
                        center: .center,
                        startRadius: 4,
                        endRadius: 56
                    )
                )
                .frame(width: 120, height: 120)
                .offset(x: halo2Pulse ? 6 : -6, y: halo2Pulse ? -4 : 4)
                .scaleEffect(halo2Pulse ? 1.12 : 0.88)
                .opacity(halo2Pulse ? 0.85 : 0.45)
                .blur(radius: 4)
                .rotationEffect(.degrees(hueShift))

            // Inner glow.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.55),
                            Editorial.accent.opacity(0.10),
                            .clear
                        ],
                        center: .center,
                        startRadius: 2,
                        endRadius: 30
                    )
                )
                .frame(width: 70, height: 70)
                .opacity(halo1Pulse ? 0.9 : 0.6)

            // Central sparkle glyph — gradient fill + slow
            // rotation + a gentle scale beat synced to the
            // outer halo so the whole composition feels like
            // it's breathing.
            Image(systemName: "sparkles")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Editorial.accent,
                            Color(hex: "#A875FF"),
                            Color(hex: "#FF8A4C")
                        ],
                        startPoint: .topLeading,
                        endPoint:   .bottomTrailing
                    )
                )
                .rotationEffect(.degrees(sparkleRotate))
                .scaleEffect(halo1Pulse ? 1.06 : 0.96)
                .shadow(color: Editorial.accent.opacity(0.55),
                        radius: 12, x: 0, y: 0)
        }
        .compositingGroup()
        // Subtle whole-orb hue rotation so the aurora never
        // looks identical from one frame to the next.
        .hueRotation(.degrees(hueShift * 0.08))
    }

    // MARK: - Suggestion grid (Apple keynote-style tiled layout)

    /// Catalog of starter prompts the user can tap. Mixed tile
    /// shapes (`.wide`, `.square`) so the grid feels like an
    /// Apple keynote moodboard rather than a vertical list.
    /// Suggestions are now COMPUTED from live `appState` data so
    /// each tile surfaces actual numbers + warnings instead of a
    /// generic label. Lets the panel be proactive — the user
    /// reads "3 reuniões hoje · 09:30, 14:00, 16:45" without
    /// even opening a chat.
    private var suggestions: [AISuggestion] {
        let cal       = Calendar.current
        let now       = Date()
        let startToday = cal.startOfDay(for: now)
        let endToday   = cal.date(byAdding: .day, value: 1, to: startToday) ?? now
        let endTomorrow = cal.date(byAdding: .day, value: 2, to: startToday) ?? now

        // Today — but ONLY items still pending right now.
        // Past events that already ended don't show up; tasks
        // due today that haven't been completed yet do. This
        // matches what `todayLayout` renders inside the Hoje
        // tile so the count never disagrees with the visible
        // pill list.
        let todayEvents = appState.events.filter { ev in
            let inToday = ev.startDate >= startToday && ev.startDate < endToday
            guard inToday else { return false }
            return ev.isAllDay || ev.endDate > now
        }
        let todayTasks = appState.pendingTasksCached.filter {
            guard let due = $0.dueDate else { return false }
            return due >= startToday && due < endToday
        }
        // Next event today (start time strictly in the future).
        let nextEventToday = todayEvents.first { $0.startDate > now }

        // Tomorrow.
        let tomorrowItemsCount = appState.events.filter {
            $0.startDate >= endToday && $0.startDate < endTomorrow
        }.count + appState.pendingTasksCached.filter {
            guard let due = $0.dueDate else { return false }
            return due >= endToday && due < endTomorrow
        }.count

        // Overdue.
        let overdue = appState.pendingTasksCached.filter {
            guard let due = $0.dueDate, !$0.isCompleted else { return false }
            return due < startToday
        }

        // Urgent / high priority. ClickUp priority: 1=Urgent,
        // 2=High, 3=Normal, 4=Low. Surface the top-2 by
        // soonest due date so the progress accessory shows
        // the most pressing one.
        let urgent = appState.pendingTasksCached
            .filter { (1...2).contains($0.priority) && !$0.isCompleted }
            .sorted { (a, b) in
                (a.dueDate ?? .distantFuture) < (b.dueDate ?? .distantFuture)
            }
        let topUrgent = urgent.first
        let urgentProgress: Double = {
            // Map "days until due" to a 0…1 fraction over a
            // 14-day horizon. 0 days left = 1.0 (bar full,
            // alarm); 14+ days = 0 (bar empty, plenty of
            // runway). Overdue clamps to 1.0.
            guard let due = topUrgent?.dueDate else { return 0 }
            let daysLeft = cal.dateComponents([.day], from: startToday, to: cal.startOfDay(for: due)).day ?? 0
            if daysLeft <= 0 { return 1.0 }
            return max(0, min(1.0, 1.0 - Double(daysLeft) / 14.0))
        }()
        let urgentLabel: String = {
            guard let due = topUrgent?.dueDate else { return "" }
            let daysLeft = cal.dateComponents([.day], from: startToday, to: cal.startOfDay(for: due)).day ?? 0
            if daysLeft < 0  { return "Atrasada \(abs(daysLeft))d" }
            if daysLeft == 0 { return "Vence hoje" }
            if daysLeft == 1 { return "Vence amanhã" }
            return "Vence em \(daysLeft)d"
        }()

        // Meetings today — anything that's not all-day.
        let meetingsToday = todayEvents
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
        let meetingTimes = meetingsToday.prefix(3).map {
            $0.startDate.formatted(date: .omitted, time: .shortened)
        }

        // Hero subtitle aggregates today's load.
        let heroSubtitle: String = {
            let parts: [String] = [
                "\(todayEvents.count) evento\(todayEvents.count == 1 ? "" : "s")",
                "\(todayTasks.count) tarefa\(todayTasks.count == 1 ? "" : "s")"
            ]
            return parts.joined(separator: " · ")
        }()
        let heroAccessory: TileAccessory? = {
            if let next = nextEventToday {
                let t = next.startDate.formatted(date: .omitted, time: .shortened)
                return .callout("Próximo: \(next.title) às \(t)")
            }
            return nil
        }()

        // Atrasadas accessory.
        let overdueAccessory: TileAccessory? = overdue.isEmpty
            ? nil
            : .callout("Resolva já")

        // Urgentes accessory — progress bar for top urgent.
        let urgentAccessory: TileAccessory? = topUrgent == nil
            ? nil
            : .progress(label: urgentLabel,
                        fraction: urgentProgress,
                        tint: Color(hex: "#A875FF"))

        // Reuniões accessory — inline times list.
        let meetingsAccessory: TileAccessory? = meetingTimes.isEmpty
            ? nil
            : .timesList(Array(meetingTimes))

        // Resumo subtitle counts pending across the week.
        let endOfWeek = cal.date(byAdding: .day, value: 7, to: startToday) ?? now
        let weekItems = appState.pendingTasksCached.filter {
            guard let due = $0.dueDate else { return false }
            return due < endOfWeek
        }.count
            + appState.events.filter {
                $0.startDate >= startToday && $0.startDate < endOfWeek
            }.count

        // Próxima janela livre — find the next ≥30min gap in
        // today's events starting from now. Walks the timed
        // events in order and returns the first interval where
        // (event.start - cursor) ≥ 30min, or "do agora até a
        // primeira reunião" if there's a gap before anything
        // is scheduled.
        let nextFreeWindow: (start: Date, end: Date)? = {
            let timedToday = todayEvents
                .filter { !$0.isAllDay }
                .sorted { $0.startDate < $1.startDate }
            var cursor = now
            for ev in timedToday {
                if ev.endDate <= cursor { continue }
                if ev.startDate > cursor {
                    let gap = ev.startDate.timeIntervalSince(cursor)
                    if gap >= 30 * 60 {
                        return (cursor, ev.startDate)
                    }
                }
                cursor = max(cursor, ev.endDate)
            }
            // Open-ended after last meeting until end of day.
            if cursor < endToday {
                let gap = endToday.timeIntervalSince(cursor)
                if gap >= 30 * 60 {
                    return (cursor, endToday)
                }
            }
            return nil
        }()
        let freeWindowSubtitle: String = {
            guard let w = nextFreeWindow else {
                return "Sem janelas hoje"
            }
            let s = w.start.formatted(date: .omitted, time: .shortened)
            let e = w.end == endToday
                ? "fim do dia"
                : w.end.formatted(date: .omitted, time: .shortened)
            return "\(s) – \(e)"
        }()
        let freeWindowMinutes: Int = {
            guard let w = nextFreeWindow else { return 0 }
            return Int(w.end.timeIntervalSince(w.start) / 60)
        }()
        // Compact duration label rendered as the top-right
        // BADGE (was a bottom CALLOUT accessory). Inside an
        // 87pt x1y1 tile the bottom-aligned callout was being
        // clipped by the tile's height limit, leaving only
        // the green rectangle visible. Promoting it to a
        // badge mirrors how every other count tile surfaces
        // its primary number — no clipping, instant glance.
        let freeWindowBadge: String? = {
            guard freeWindowMinutes > 0 else { return nil }
            let h = freeWindowMinutes / 60
            let m = freeWindowMinutes % 60
            // "8h", "8h23", or "23min" — always one short
            // token that fits the badge capsule comfortably.
            if h > 0 && m > 0 { return "\(h)h\(m)" }
            if h > 0          { return "\(h)h" }
            return "\(m)min"
        }()

        // Aguardando outros — pending tasks where SOMEONE ELSE
        // is the assignee. Lets the user see at a glance what
        // they're blocked on / need to chase down. Falls back
        // to "ninguém" if there's no current ClickUp user
        // identity to compare against.
        let myId = appState.clickUpAuthService.userId
        let waitingOnOthers = appState.pendingTasksCached.filter { task in
            guard !task.isCompleted else { return false }
            guard let me = myId else { return false }
            // Task counts as "blocked on others" if it has any
            // assignee AND the current user is NOT among them.
            if task.assignees.isEmpty { return false }
            return !task.assignees.contains(where: { $0.id == me })
        }

        // Concluídas hoje — completed tasks whose `dateClosed`
        // falls inside today. Positive feedback signal.
        let completedToday = appState.completedTasksCached.filter {
            guard let closed = $0.dateClosed else { return false }
            return closed >= startToday && closed < endToday
        }.count
        let completedAccessory: TileAccessory? = completedToday >= 3
            ? .callout("Bom ritmo")
            : nil

        return [
            // Date + clock widget — moved to position [0] so
            // the panel opens with the user's anchor (where am
            // I in time?) before any of the dynamic counts.
            // Custom widget-style layout in `clockLayout` —
            // sentinel `__clock__` triggers it. Sized x2y1 so
            // there's room to highlight the date alongside the
            // live time.
            .init(icon: "clock.fill",
                  title: "__clock__",
                  subtitle: "",
                  accent: Color(hex: "#7B61FF"),
                  prompt: "Que horas são? E qual a data de hoje?",
                  size: .x2y1),

            // Hero — combined today panel. Sentinel title
            // `__today__` switches the tile into a custom
            // layout (`todayLayout`) that renders the actual
            // event pills + task pills inline. Replaces what
            // used to be two separate tiles (Hoje summary +
            // Reuniões list) with a single richer surface.
            .init(icon: "calendar.badge.clock",
                  title: "__today__",
                  subtitle: heroSubtitle,
                  accent: Editorial.accent,
                  prompt: "O que eu tenho hoje?",
                  size: .x3y2,
                  badge: (todayEvents.count + todayTasks.count) == 0
                    ? nil
                    : "\(todayEvents.count + todayTasks.count)"),

            // Amanhã — count badge.
            .init(icon: "sun.max.fill",
                  title: "Amanhã",
                  subtitle: tomorrowItemsCount == 0
                    ? "Nada agendado"
                    : "\(tomorrowItemsCount) item\(tomorrowItemsCount == 1 ? "" : "s")",
                  accent: Color(hex: "#FF8A4C"),
                  prompt: "O que eu tenho amanhã?",
                  size: .x1y1,
                  badge: tomorrowItemsCount == 0 ? nil : "\(tomorrowItemsCount)"),

            // Atrasadas — count badge + warning callout if any.
            .init(icon: "exclamationmark.triangle.fill",
                  title: "Atrasadas",
                  subtitle: overdue.isEmpty
                    ? "Nenhuma vencida"
                    : "\(overdue.count) tarefa\(overdue.count == 1 ? "" : "s")",
                  accent: Color(hex: "#FF5E5E"),
                  prompt: "Quais tarefas estão atrasadas?",
                  size: .x1y1,
                  // Count badge in the top-right is the same
                  // glance-info the user wanted from the
                  // bottom "Resolva já" callout — same
                  // treatment as Janela livre, where the
                  // bottom accessory was promoted to a
                  // top-right badge to fit the 87pt x1y1
                  // height without clipping. The accessory
                  // is dropped entirely.
                  badge: overdue.isEmpty ? nil : "\(overdue.count)"),

            // Urgentes — count badge + progress bar to the
            // most pressing deadline.
            .init(icon: "flag.fill",
                  title: "Urgentes",
                  subtitle: urgent.isEmpty
                    ? "Nenhuma urgente"
                    : "\(urgent.count) ativa\(urgent.count == 1 ? "" : "s")",
                  accent: Color(hex: "#A875FF"),
                  prompt: "Quais minhas tarefas mais urgentes?",
                  size: .x2y1,
                  badge: urgent.isEmpty ? nil : "\(urgent.count)",
                  accessory: urgentAccessory),

            // (Reuniões standalone tile removed — its content
            // now lives inside the combined Hoje tile via
            // `todayLayout`, so the user gets the full meeting
            // list AND the day's tasks in one place instead of
            // having that information split across two tiles.)

            // Próxima janela livre — proactive scheduling
            // help: shows the next ≥30min open block today.
            .init(icon: "clock.badge.checkmark.fill",
                  title: "Janela livre",
                  subtitle: freeWindowSubtitle,
                  accent: Color(hex: "#3DD68C"),
                  prompt: "Me sugira o melhor horário livre hoje pra trabalhar foco.",
                  size: .x1y1,
                  badge: freeWindowBadge),

            // Aguardando outros — count of tasks blocked on
            // someone else.
            .init(icon: "person.crop.circle.badge.questionmark",
                  title: "Aguardando",
                  subtitle: waitingOnOthers.isEmpty
                    ? "Nada bloqueado"
                    : "\(waitingOnOthers.count) com terceiros",
                  accent: Color(hex: "#FFB23F"),
                  prompt: "Quais tarefas eu estou aguardando outras pessoas?",
                  size: .x1y1,
                  badge: waitingOnOthers.isEmpty ? nil : "\(waitingOnOthers.count)"),

            // Concluídas hoje — positive reinforcement.
            .init(icon: "checkmark.seal.fill",
                  title: "Concluídas",
                  subtitle: completedToday == 0
                    ? "Nada finalizado ainda"
                    : "\(completedToday) hoje",
                  accent: Color(hex: "#34C759"),
                  prompt: "Mostre o que eu concluí hoje.",
                  size: .x1y1,
                  badge: completedToday == 0 ? nil : "\(completedToday)",
                  accessory: completedAccessory),

            // (Clock tile moved to position [0] — first slot
            // — so the user lands on the date/time anchor
            // before any of the dynamic counts.)

            // Reagendar atrasadas — wide ACTION tile. Tapping
            // opens the chat with a pre-baked prompt the user
            // can send straight away.
            .init(icon: "calendar.badge.exclamationmark",
                  title: "Reagendar atrasadas",
                  subtitle: overdue.isEmpty
                    ? "Nada pra remarcar"
                    : "Apollo sugere novas datas pras \(overdue.count) vencidas",
                  accent: Color(hex: "#FF6B9A"),
                  prompt: "Tenho \(overdue.count) tarefas atrasadas. Liste cada uma com a data original e me sugira uma nova data realista pra cada, considerando minha agenda atual.",
                  size: .x3y1,
                  badge: overdue.isEmpty ? nil : "\(overdue.count)"),

            // Resumo — week count.
            .init(icon: "sparkles",
                  title: "Resumo da semana",
                  subtitle: weekItems == 0
                    ? "Semana tranquila"
                    : "\(weekItems) compromisso\(weekItems == 1 ? "" : "s") nos próximos 7 dias",
                  accent: Color(hex: "#FF5E8A"),
                  prompt: "Me dê um resumo da minha semana.",
                  size: .x3y1),
        ]
    }

    /// Hand-authored masonry grid built on `SwiftUI.Grid` /
    /// `GridRow`. Each row is a horizontal band; tall tiles
    /// (y2, y3) are paired with VStacks of shorter tiles in
    /// adjacent cells so the grid never wastes vertical space
    /// next to a tall tile. Column spans use `.gridCellColumns`;
    /// the implicit row height comes from the tile's
    /// `tileHeight` (rows × 92 + (rows-1) × 8).
    ///
    /// Suggestion array index → tile mapping (kept in sync
    /// with `suggestions` after the Reuniões merge):
    ///   [0] Hoje (combined)   x3y2 (custom todayLayout)
    ///   [1] Amanhã            x1y1
    ///   [2] Atrasadas         x1y1
    ///   [3] Urgentes          x2y1
    ///   [4] Janela livre      x1y1
    ///   [5] Aguardando        x1y1
    ///   [6] Concluídas        x1y1
    ///   [7] Relógio           x1y1
    ///   [8] Reagendar         x3y1
    ///   [9] Resumo            x3y1
    /// 3-column `SwiftUI.Grid` layout. CRITICAL fix vs the
    /// previous LazyVGrid attempt: `.gridCellColumns(N)` is a
    /// `Grid`-only modifier — LazyVGrid silently IGNORED it,
    /// so every "spanning" tile collapsed to a 1-column cell
    /// and the resulting layout looked broken (Hoje x3 squished
    /// into col 3 only, taller tiles stretching their entire
    /// row, etc.). With `SwiftUI.Grid + GridRow` the spans are
    /// honored properly. We deliberately avoid `Color.clear`
    /// placeholders for empty cells (which previously confused
    /// Grid into collapsing rows) — every GridRow has the
    /// exact number of cells the row needs.
    ///
    /// Suggestion array indices (kept in sync with `suggestions`):
    ///   [0] Relógio (widget)  x2y1
    ///   [1] Hoje (combined)   x3y2
    ///   [2] Amanhã            x1y1
    ///   [3] Atrasadas         x1y1
    ///   [4] Urgentes          x2y1
    ///   [5] Janela livre      x1y1
    ///   [6] Aguardando        x1y1
    ///   [7] Concluídas        x1y1
    ///   [8] Reagendar         x3y1
    ///   [9] Resumo            x3y1
    /// Hand-authored VStack of HStacks. Both `LazyVGrid` and
    /// `SwiftUI.Grid` were producing broken layouts in this
    /// context (LazyVGrid silently ignored `gridCellColumns`,
    /// Grid collapsed rows / pushed the hero off-screen).
    /// HStack with `.frame(maxWidth: .infinity)` on equal-
    /// weight siblings is the reliable path: every row's
    /// width math is dictated by the children explicitly,
    /// no grid heuristics involved.
    ///
    /// Tradeoff: the previous "Relógio takes 2/3 width" layout
    /// is now "Relógio + Amanhã share row 1 in 1:1". The hero
    /// (Hoje x3y2) and wide closers stay full-width on their
    /// own rows.
    @ViewBuilder
    private var suggestionGrid: some View {
        let s = suggestions
        // y2 tile total height in the new compressed scale
        // (2 × rowUnit + 1 × 8pt gap). Used to pin GeometryReader
        // rows that need to match a y2 sibling's height.
        let y2Height = SuggestionTile.rowUnit * 2 + 8
        let y1Height = SuggestionTile.rowUnit
        VStack(spacing: 8) {
            // Row 1 — Relógio (1/3) + Hoje hero (2/3).
            // We tried swapping the GeometryReader for
            // `.containerRelativeFrame(.horizontal)` to dodge
            // the per-render layout pass, but
            // `containerRelativeFrame` resolves against the
            // nearest scroll/window container — NOT the AI
            // panel's local width. Result: tiles ballooned
            // to a third / two-thirds of the WHOLE WINDOW
            // width, blowing the panel out. Reverted to
            // `GeometryReader` because it's the only
            // construct that honours the AI panel's own
            // proposed width.
            //
            // Cost is acceptable here because the suggestions
            // panel doesn't scroll itself — the GR's layout
            // pass fires on appear and on window resize, not
            // per scroll frame.
            GeometryReader { geo in
                let gap: CGFloat = 8
                let third = (geo.size.width - gap) / 3
                HStack(spacing: gap) {
                    suggestionTile(s[0], index: 0)
                        .frame(width: third)
                    suggestionTile(s[1], index: 1)
                        .frame(width: third * 2)
                }
            }
            .frame(height: y2Height)
            // Row 2 — Urgentes (2/3) + Atrasadas (1/3).
            // Same GR-only-works rationale as Row 1.
            GeometryReader { geo in
                let gap: CGFloat = 8
                let third = (geo.size.width - gap) / 3
                HStack(spacing: gap) {
                    suggestionTile(s[4], index: 4)
                        .frame(width: third * 2)
                    suggestionTile(s[3], index: 3)
                        .frame(width: third)
                }
            }
            .frame(height: y1Height)
            // Row 3 — four small tiles in equal width:
            // Amanhã + Janela livre + Aguardando + Concluídas.
            // All x1y1 so a 1:1:1:1 split reads cleanly.
            HStack(spacing: 8) {
                suggestionTile(s[2], index: 2)
                suggestionTile(s[5], index: 5)
                suggestionTile(s[6], index: 6)
                suggestionTile(s[7], index: 7)
            }
            // Row 4 — Reagendar + Resumo (1:1) side by side.
            // Both x3y1 tiles previously got their own row;
            // packing them together cuts panel height and
            // gives the closer-tile pair more visual rhythm.
            HStack(spacing: 8) {
                suggestionTile(s[8], index: 8)
                suggestionTile(s[9], index: 9)
            }
        }
    }

    private func suggestionTile(_ s: AISuggestion, index: Int) -> some View {
        // Cascade kicks in after the orb + title. Tile 0 starts
        // ~0.40s after appear, +0.06s per tile.
        let delay = 0.40 + Double(index) * 0.06
        // Phase gate: tile 0 needs phase ≥ 3, then each
        // additional tile bumps the threshold by 1 — but cap
        // at 5 (our final phase) so all tiles eventually show
        // even on a fast-tracked entrance.
        let visible = phase >= min(3 + index / 2, 5)

        return SuggestionTile(suggestion: s) {
            onSuggestion(s.prompt)
        }
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.88)
        .offset(y: visible ? 0 : 14)
        .animation(.spring(response: 0.55, dampingFraction: 0.78)
                    .delay(delay),
                   value: phase)
    }

    // MARK: - Entrance choreography

    private func startEntrance() {
        if playEntranceCascade {
            // First appearance per session — march `phase`
            // through 1…5 on a staggered schedule. Each bump
            // triggers the per-element animations above.
            phase = 0
            let bumps: [Double] = [0.0, 0.12, 0.30, 0.40, 0.50]
            for (i, t) in bumps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                    phase = i + 1
                }
            }
            onCascadeShown()
        } else {
            // Subsequent appearances (e.g. after the user
            // clicked the back button) jump straight to the
            // fully-revealed state with no animation. This is
            // what makes back-navigation feel instant.
            phase = 5
        }

        // PERF: ambient orb animations now run a FINITE number
        // of cycles instead of `.repeatForever`. The empty-
        // state hero is the most visible moment of "Apollo is
        // alive", so we keep the cascade + a few breathing
        // beats — but every continuous loop here re-renders
        // the orb's full radial-gradient stack at 60Hz, and
        // stacked under the `IntelligenceEdgeGlow` (also
        // window-sized, also blurred) the cumulative cost
        // visibly tanks the host system's FPS while the chat
        // is open. Capping each loop to 3-4 cycles lets the
        // orb settle within ~10-12s and the per-frame cost
        // drops to zero once they've finished.
        withAnimation(.easeInOut(duration: 2.6)
                        .repeatCount(4, autoreverses: true)) {
            halo1Pulse = true
        }
        withAnimation(.easeInOut(duration: 3.4)
                        .repeatCount(3, autoreverses: true)) {
            halo2Pulse = true
        }

        // Single rotation: 0 → 360 over 28s, then settles.
        // 28s is long enough to feel like a continuous spin
        // during the user's first impression of the chat;
        // after that it stops paying for itself.
        withAnimation(.linear(duration: 28)) {
            sparkleRotate = 360
        }

        // Hue drift — 2 round-trips (24s total) then quiet.
        withAnimation(.linear(duration: 12)
                        .repeatCount(2, autoreverses: true)) {
            hueShift = 360
        }
    }
}

// MARK: - Suggestion model

/// One tile in the empty-state grid. Holds the SF Symbol icon,
/// short title + subtitle, the accent colour that tints both
/// the icon halo and the optional Liquid Glass tint, and the
/// prompt that gets sent when the user taps the tile.
/// Inline weather strip used by the clock tile. Subscribes
/// to `WeatherFetcher.shared` and re-renders whenever a new
/// reading arrives. Triggers a fetch on appear (no-op if
/// the cached reading is fresh).
private struct WeatherStripView: View {
    @StateObject private var fetcher = WeatherFetcher.shared

    var body: some View {
        Group {
            if let r = fetcher.current {
                HStack(spacing: 4) {
                    Image(systemName: r.icon)
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(r.tempC)°C")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("· \(r.city)")
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(.secondary)
            } else {
                // Reserve approximate space so the tile
                // doesn't pop when the reading arrives.
                Text(" ").font(.system(size: 11))
            }
        }
        .onAppear { fetcher.refreshIfStale() }
    }
}

private struct AISuggestion: Identifiable {
    /// Tile dimensions in a 3-column grid. The first digit is
    /// columns (1, 2, or 3), the second is rows (1, 2, or 3).
    /// Each "row" is a base unit of 92pt + 8pt gap, so a `y2`
    /// tile is 192pt tall (= 92 + 8 + 92) and a `y3` tile is
    /// 292pt. The grid layout in `suggestionGrid` is hand-
    /// authored to pack tall tiles next to stacks of shorter
    /// ones (e.g. an `x2y2` next to a vertical stack of two
    /// `x1y1`s) so no cell wastes vertical space.
    enum Size {
        case x1y1, x2y1, x3y1, x2y2, x3y2, x2y3
        var cols: Int {
            switch self {
            case .x1y1:                  return 1
            case .x2y1, .x2y2, .x2y3:    return 2
            case .x3y1, .x3y2:           return 3
            }
        }
        var rows: Int {
            switch self {
            case .x1y1, .x2y1, .x3y1:    return 1
            case .x2y2, .x3y2:           return 2
            case .x2y3:                  return 3
            }
        }
    }

    let id = UUID()
    let icon: String
    let title: String
    let subtitle: String
    let accent: Color
    let prompt: String
    let size: Size
    /// Optional contextual badge in the top-right of the tile
    /// — typically a count ("3", "12") rendered as a small
    /// capsule tinted by the suggestion's accent.
    var badge: String? = nil
    /// Optional richer accessory rendered below the
    /// title/subtitle stack. Lets a tile show a progress bar,
    /// a times list, or a callout strip directly inline so the
    /// user gets the answer at a glance instead of having to
    /// open the chat.
    var accessory: TileAccessory? = nil
    /// Optional secondary action buttons rendered inline. When
    /// non-empty, the tile uses a custom layout (header + button
    /// row) and clicking each button dispatches its own
    /// `prompt` instead of the tile-level `prompt`. Lets a
    /// single tile expose multiple related quick-actions —
    /// e.g. the merged "Atrasadas" tile offers both a "Ver
    /// tarefas" and a "Reagendar" action at once.
    var actions: [TileButtonAction]? = nil
}

/// Inline quick-action button rendered inside a tile when
/// `AISuggestion.actions` is non-empty. Each button has a
/// short label, an SF Symbol icon, and the prompt that gets
/// dispatched to the AI when tapped.
private struct TileButtonAction: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let prompt: String
}

/// Inline content that can sit below a tile's title/subtitle.
/// Each case maps to a small dedicated SwiftUI view rendered
/// by `SuggestionTile`. Kept as an enum (instead of returning
/// `AnyView`) so the tile layout can branch on type without
/// type-erasure overhead.
private enum TileAccessory {
    /// Progress bar with a leading label. `fraction` is 0…1.
    /// Used by tiles that surface "how much time is left"
    /// info — e.g. days until the most-urgent task expires.
    case progress(label: String, fraction: Double, tint: Color)
    /// Compact list of times shown as small inline pills.
    /// Used by the meetings tile to surface today's start
    /// times at a glance.
    case timesList([String])
    /// Single line of callout text in the suggestion's accent
    /// colour. Used for important warnings ("3 reuniões em
    /// menos de 2h", "Você está atrasado em 5 tarefas").
    case callout(String)
}

// MARK: - Suggestion tile (Liquid Glass card)

/// Glass-clad tile inspired by the Apple silicon keynote slide:
/// each card features a coloured icon at the top-left, a bold
/// title, and a small caption. Taps trigger `action`. The card
/// uses Liquid Glass on macOS 26+ and gracefully falls back to
/// `.regularMaterial` on older systems.
private struct SuggestionTile: View {
    let suggestion: AISuggestion
    let action: () -> Void

    /// Read live for the `__today__` tile's combined event +
    /// task pill list. The other tile variants don't touch
    /// appState directly (their dynamic content comes pre-
    /// computed via the `AISuggestion` model from the parent).
    @EnvironmentObject var appState: AppState

    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false
    /// Brief "you tapped me" highlight: scales up + flashes
    /// the accent halo, then triggers `action`. Gives the
    /// tile->chat hand-off a satisfying physical beat.
    @State private var isLaunching: Bool = false

    /// "Wide" tiles use the horizontal-first layout (icon on
    /// the left, text stack to its right). Triggered for any
    /// tile that's at least 2 columns wide AND only 1 row tall
    /// — that's the band shape where horizontal flow reads
    /// best. Tall multi-column tiles (x2y2, x3y2, x2y3) use
    /// the vertical-first square layout because they have
    /// space for the icon on top and content beneath.
    private var isWide: Bool {
        suggestion.size.cols >= 2 && suggestion.size.rows == 1
    }

    /// Total tile height in points. Each row unit is 87pt
    /// (was 92pt — trimmed 5% by request to compress the
    /// vertical footprint of the suggestion grid) and rows
    /// are separated by an 8pt gap, so a y2 tile is
    /// 87+8+87 = 182pt and a y3 tile is 87+8+87+8+87 = 277pt.
    static let rowUnit: CGFloat = 87
    private var tileHeight: CGFloat {
        let rows = CGFloat(suggestion.size.rows)
        return rows * Self.rowUnit + (rows - 1) * 8
    }

    var body: some View {
        Button(action: { triggerLaunch() }) {
            content
                .overlay(launchFlash)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .scaleEffect(launchScale)
        .animation(.spring(response: 0.32, dampingFraction: 0.62),
                   value: isLaunching)
        .animation(.spring(response: 0.3, dampingFraction: 0.7),
                   value: isPressed)
        .animation(.spring(response: 0.4, dampingFraction: 0.75),
                   value: isHovered)
        .scrollAwareOnHover { isHovered = $0 }
        .pressEvents(onPress: { isPressed = true },
                     onRelease: { isPressed = false })
    }

    /// Combines the three pressure states into one scale value.
    /// Launching wins (1.06), then pressed (0.96), then
    /// hovered (1.02), else identity.
    private var launchScale: CGFloat {
        if isLaunching { return 1.06 }
        if isPressed   { return 0.96 }
        if isHovered   { return 1.02 }
        return 1
    }

    /// Quick accent-tinted flash overlay drawn over the tile
    /// for the duration of the launch animation. Fades out
    /// when `isLaunching` flips back off.
    private var launchFlash: some View {
        // Was using `.blendMode(.plusLighter)` — additive blend
        // works great on dark surfaces, but the suggestion tile
        // sits on `ApolloPalette.cream` (near-white). Plus-
        // lighter saturates cream to pure white, washing the
        // accent colour out entirely. We swap to the default
        // (normal) source-over blend at a stronger opacity so
        // the tile briefly tints toward the accent without
        // ever flashing pure white.
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        suggestion.accent.opacity(0.85),
                        suggestion.accent.opacity(0.40)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .opacity(isLaunching ? 0.55 : 0)
            .allowsHitTesting(false)
    }

    /// Two-step kickoff: flash & scale up (140ms), then fire
    /// `action`. The action itself synchronously appends the
    /// user message and flips the empty→chat transition with
    /// its own spring, so by the time the launch animation
    /// finishes the chat is already crossing in.
    private func triggerLaunch() {
        isLaunching = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            action()
            // Reset so a re-show of the empty state lands
            // neutral if the user clears history.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                isLaunching = false
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if suggestion.title == "__clock__" {
            clockLayout
        } else if suggestion.title == "__today__" {
            todayLayout
        } else if isWide {
            wideLayout
        } else {
            squareLayout
        }
    }

    /// Combined "Hoje" tile — header at the top, then a list
    /// of inline pills representing today's events and tasks
    /// merged in chronological order. Replaces the previous
    /// pair of (Hoje summary + Reuniões list) tiles with one
    /// surface that surfaces the actual calendar/task content
    /// instead of just counts. Capped at ~6 pills so the tile
    /// stays at its declared `tileHeight`; overflow rolls
    /// into a "+ N mais" hint at the bottom.
    private var todayLayout: some View {
        let cal       = Calendar.current
        let now       = Date()
        let startToday = cal.startOfDay(for: now)
        let endToday   = cal.date(byAdding: .day, value: 1, to: startToday) ?? now

        // Events that haven't ended yet today (or all-day
        // events). Past events that already finished get
        // filtered out — when it's 18:33 there's no point
        // surfacing the 9:30 daily that already happened.
        let events = appState.events
            .filter { ev in
                let inToday = ev.startDate >= startToday && ev.startDate < endToday
                guard inToday else { return false }
                // Keep all-day events all day; keep timed
                // events while they're still upcoming or
                // currently happening.
                return ev.isAllDay || ev.endDate > now
            }
            .sorted { $0.startDate < $1.startDate }
        // Tasks due today AND still pending — completed tasks
        // are already in `completedTasksCached`, so the
        // pending filter naturally excludes them.
        let tasks = appState.pendingTasksCached
            .filter { task -> Bool in
                guard let due = task.dueDate else { return false }
                return due >= startToday && due < endToday
            }
            .sorted { ($0.dueDate ?? now) < ($1.dueDate ?? now) }

        let totalRows = 4   // ~4 visible pill rows fit in y2 (192pt)
        let visibleEvents = Array(events.prefix(totalRows))
        let remainingSlots = max(0, totalRows - visibleEvents.count)
        let visibleTasks = Array(tasks.prefix(remainingSlots))
        let hiddenCount  = (events.count - visibleEvents.count)
            + (tasks.count - visibleTasks.count)

        return VStack(alignment: .leading, spacing: 6) {
            // Header.
            HStack(alignment: .center, spacing: 10) {
                iconBadge
                VStack(alignment: .leading, spacing: 1) {
                    Text("Hoje")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(suggestion.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let badge = suggestion.badge {
                    badgeCapsule(badge)
                }
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 2)

            if events.isEmpty && tasks.isEmpty {
                Text("Nada agendado pra hoje")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            } else {
                ForEach(visibleEvents) { ev in
                    todayEventPill(ev)
                }
                ForEach(visibleTasks) { task in
                    todayTaskPill(task)
                }
                if hiddenCount > 0 {
                    Text("+ \(hiddenCount) mais")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        // CAP the height: when the chat panel is given
        // unconstrained vertical space (full-window overlay
        // + ScrollView), `minHeight` alone lets each tile
        // grow to fill the available row, blowing the grid
        // out of proportion. Using `height:` (== min+max)
        // pins every tile to its declared `tileHeight` so
        // the LazyVGrid rows stay aligned at 92pt / 192pt /
        // 292pt regardless of the panel size.
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: tileHeight)
        .background(tileSurface)
        .overlay(tileBorder)
        .shadow(color: suggestion.accent.opacity(0.45),
                radius: 14, x: 0, y: 6)
        .shadow(color: suggestion.accent.opacity(0.25),
                radius: 4, x: 0, y: 1)
    }

    /// Compact pill for a calendar event inside the today
    /// tile. Time on the left + title on the right + small
    /// colour stripe matching the calendar.
    private func todayEventPill(_ ev: CalendarEvent) -> some View {
        let color = Color(googleSnapHex: ev.colorHex)
        let timeText: String = ev.isAllDay
            ? "Todo dia"
            : ev.startDate.formatted(date: .omitted, time: .shortened)
        return HStack(spacing: 8) {
            Capsule()
                .fill(color)
                .frame(width: 3, height: 16)
            Text(timeText)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 48, alignment: .leading)
            Text(ev.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.opacity(0.10))
        )
    }

    /// Compact pill for a pending task inside the today
    /// tile. Status badge + title.
    private func todayTaskPill(_ task: CUTask) -> some View {
        let statusColor = Color(hex: task.statusDisplayHex)
        return HStack(spacing: 8) {
            Capsule()
                .fill(statusColor)
                .frame(width: 3, height: 16)
            Text(task.status.uppercased())
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.4)
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(statusColor))
            Text(task.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(statusColor.opacity(0.08))
        )
    }

    /// Live date + clock tile — replaces the standard text
    /// stack with a TimelineView that ticks every second so
    /// the seconds digits update without a SwiftUI body
    /// re-evaluation on the parent. The `.periodic` schedule
    /// is the cheapest live-clock pattern available; only the
    /// clock label re-renders, not the whole tile.
    private var clockLayout: some View {
        // Portrait/square layout for the clock tile. Previous
        // implementation was a horizontal HStack (date stack
        // on the left, time + weather on the right) sized for
        // the old wide x2y1 footprint. After Row 1 was
        // restructured to a 1:2 split (Clock 1/3 + Hoje 2/3)
        // the clock became effectively a portrait tile, and
        // the horizontal layout left big empty whitespace in
        // the middle. Now stacked vertically — date row on top,
        // big time centred in the body, weather strip at the
        // bottom — using the available height instead of width.
        let now = Date()
        let weekday = now.formatted(
            .dateTime.weekday(.abbreviated)
                .locale(Locale(identifier: "pt_BR"))
        ).replacingOccurrences(of: ".", with: "").uppercased()
        let dayNum  = Calendar.current.component(.day, from: now)
        let month   = now.formatted(
            .dateTime.month(.abbreviated)
                .locale(Locale(identifier: "pt_BR"))
        ).replacingOccurrences(of: ".", with: "").uppercased()

        return VStack(alignment: .leading, spacing: 0) {
            // ── Date row (top) ─────────────────────────────
            // Inline weekday + day + month. Weekday in the
            // accent colour anchors the row visually; the day
            // number is the bold focal point; the month sits
            // alongside as a softer trailing token.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(weekday)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(suggestion.accent)
                Text("\(dayNum)")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(.primary)
                Text(month)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            // ── Live time (middle) ────────────────────────
            // Big bold clock — primary content of this tile.
            // Centred horizontally and vertically inside the
            // body so the digits sit visually anchored
            // regardless of the tile's exact height.
            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(ctx.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 36, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .minimumScaleFactor(0.6)
            }

            Spacer(minLength: 4)

            // ── Weather strip (bottom) ────────────────────
            // City + temperature + condition icon. Sits at
            // the bottom-leading edge as the supporting info.
            weatherStrip
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // `minHeight` keeps a sensible floor for standalone
        // usage; `maxHeight: .infinity` lets the clock STRETCH
        // to fill its parent slot when it's paired with a
        // taller sibling (Hoje x3y2 → 182pt). Previously a
        // hard `.frame(height: tileHeight)` capped the clock
        // at 87pt, leaving 95pt of empty halo below it inside
        // the Row 1 GeometryReader slot.
        .frame(minHeight: tileHeight)
        .background(tileSurface)
        .overlay(tileBorder)
        .shadow(color: suggestion.accent.opacity(0.45),
                radius: 14, x: 0, y: 6)
        .shadow(color: suggestion.accent.opacity(0.25),
                radius: 4, x: 0, y: 1)
    }

    /// Compact weather strip — `[icon] 24°C · São Paulo` —
    /// rendered under the live time inside the clock tile.
    /// Subscribes to `WeatherFetcher.shared` and triggers a
    /// fetch on appear; the fetcher caches for 30 min so
    /// reopening the chat reuses the previous reading.
    /// Renders nothing while no reading is available so the
    /// time digits don't shift between empty and populated
    /// states.
    @ViewBuilder
    private var weatherStrip: some View {
        WeatherStripView()
    }

    /// Wide hero tile — icon on the left, title + subtitle
    /// stacked to its right. Both text rows share the same
    /// leading alignment as the icon's leading edge so the
    /// composition reads as a tidy three-row grid (icon | title /
    /// subtitle | arrow).
    private var wideLayout: some View {
        let inner = VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                iconBadge

                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(suggestion.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxHeight: .infinity, alignment: .center)

                Spacer(minLength: 0)

                if let badge = suggestion.badge {
                    badgeCapsule(badge)
                }

                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            if let acc = suggestion.accessory {
                accessoryView(acc)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)

        // Color.clear-as-sizer pattern. `Color.clear` honors
        // any frame proposal exactly, so wrapping the actual
        // content in an overlay on top of a fixed-height
        // Color.clear forces the OUTER tile bounds to
        // tileHeight regardless of how tall the inner content
        // would render. Earlier `.frame(height:)` was being
        // ignored by SwiftUI when content exceeded the
        // proposed size.
        return Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: tileHeight)
            .overlay(alignment: .topLeading) { inner }
            .background(tileSurface)
            .overlay(tileBorder)
        .shadow(color: suggestion.accent.opacity(0.45),
                radius: 14, x: 0, y: 6)
        .shadow(color: suggestion.accent.opacity(0.25),
                radius: 4, x: 0, y: 1)
    }

    /// Compact square tile for the 2×2 mosaic. The icon sits at
    /// the top-leading corner; the title + subtitle stack hugs
    /// the bottom-leading corner. A small fixed gap keeps the
    /// text away from the rounded corner so nothing visually
    /// brushes against the border at any zoom level.
    private var squareLayout: some View {
        let inner = VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                iconBadge
                Spacer(minLength: 0)
                if let badge = suggestion.badge {
                    badgeCapsule(badge)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(suggestion.subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let acc = suggestion.accessory {
                    accessoryView(acc)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)

        // Color.clear-as-sizer pattern (same as `wideLayout`).
        // Without this, tiles with an accessory used a hard-
        // coded `minHeight: 116` and grew taller than their
        // declared `tileHeight` (87pt for x1y1), shoving the
        // grid row out of alignment with sibling tiles. Now
        // every square tile honours its declared size and
        // accessory content lives inside that fixed slot.
        return Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: tileHeight)
            .overlay(alignment: .topLeading) { inner }
            .background(tileSurface)
            .overlay(tileBorder)
            .shadow(color: suggestion.accent.opacity(0.45),
                    radius: 14, x: 0, y: 6)
            .shadow(color: suggestion.accent.opacity(0.25),
                    radius: 4, x: 0, y: 1)
    }

    /// Small tinted capsule rendered in the top-right of a tile.
    /// Used to surface counts ("3", "12") so the headline number
    /// is visible without parsing the subtitle text.
    private func badgeCapsule(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(suggestion.accent))
    }

    /// Renders the optional richer accessory (progress bar /
    /// times list / callout) that lives below the title and
    /// subtitle. Each variant maps to a small dedicated layout.
    @ViewBuilder
    private func accessoryView(_ accessory: TileAccessory) -> some View {
        switch accessory {
        case .progress(let label, let fraction, let tint):
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(tint.opacity(0.18))
                        Capsule()
                            .fill(tint)
                            .frame(width: max(4, geo.size.width * fraction))
                    }
                }
                .frame(height: 4)
            }
        case .timesList(let times):
            HStack(spacing: 4) {
                ForEach(times, id: \.self) { t in
                    Text(t)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(suggestion.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(suggestion.accent.opacity(0.18))
                        )
                }
            }
        case .callout(let text):
            Text(text)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(suggestion.accent)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(suggestion.accent.opacity(0.15))
                )
        }
    }

    /// Neutral surface used by every tile. The colour identity
    /// is delivered by the icon badge + colour-tinted drop
    /// shadows; the surface itself stays cream so all six tiles
    /// read as one family of cards rather than six different
    /// painted rectangles.
    private var tileSurface: some View {
        shape.fill(ApolloPalette.cream)
    }

    /// Subtle accent-tinted border so the silhouette of each
    /// tile carries the suggestion's hue without flooding the
    /// fill. Matches the hairline used by the task pills.
    private var tileBorder: some View {
        shape.strokeBorder(
            LinearGradient(
                colors: [
                    suggestion.accent.opacity(0.30),
                    suggestion.accent.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            lineWidth: 0.7
        )
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    /// The coloured rounded-square icon plate — iOS app-icon
    /// silhouette. Slight inner highlight + drop shadow tinted
    /// to the suggestion accent so each tile feels distinct.
    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            suggestion.accent,
                            suggestion.accent.opacity(0.78)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 30, height: 30)
                .shadow(color: suggestion.accent.opacity(0.4),
                        radius: 6, x: 0, y: 2)

            Image(systemName: suggestion.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Apollo IA palette
//
// Single source of truth for the colours that visually link
// the chat surfaces to the task / event pills the AI returns.
// The chat background, the assistant bubble and the composer
// all wear the same cream task-pill tone (`apolloCream`); user
// messages adopt the cool calendar-blue (`apolloEventBlue`).
// Anywhere a tinted accent is needed (status pills, hover
// flashes) we reach for these constants instead of hardcoding
// hex codes inline.
private enum ApolloPalette {
    /// Surface tone used for chat bubbles, task pills inside
    /// the chat, the composer field background, and the popup
    /// panel material tint.
    ///
    /// Light mode is now a NEUTRAL near-white (`#F8F8F8`) — the
    /// previous `#F4ECDF` cream had a yellow cast that read as
    /// dated against the rest of the app's chrome. Dark mode
    /// keeps a desaturated warm-tinted near-black so the chat
    /// surfaces feel one level "softer" than the system dark
    /// gray (which would otherwise blend into the popup glass).
    /// Multi-color drop shadows on bubbles supply the visual
    /// interest the cream tint used to provide.
    static let cream = Color(
        light: Color(hex: "#F8F8F8"),
        dark:  Color(hex: "#2B2620")
    )

    /// Slightly tinted variant — used for press / hover states
    /// and for subtle differentiation when one cream surface
    /// nests inside another.
    static let creamHover = Color(
        light: Color(hex: "#EFEFEF"),
        dark:  Color(hex: "#3A332B")
    )

    /// Hairline border. Flips white-ish in dark mode so the
    /// edge stays visible against the dark surface.
    static let creamBorder = Color(
        light: Color.black.opacity(0.06),
        dark:  Color.white.opacity(0.08)
    )

    // MARK: Multi-color halo (for chat bubbles)

    /// Three accent-family hues stacked as soft drop shadows
    /// behind chat bubbles. The composition gives the bubble a
    /// gentle aurora-like halo without committing the surface
    /// itself to any one colour. Tones are tuned for low chroma
    /// so the effect reads as "polished" not "rainbow".
    static let bubbleShadowAccent = Color(hex: "#4F8EF7")
                                        .opacity(0.18)
    static let bubbleShadowWarm   = Color(hex: "#FF8A4C")
                                        .opacity(0.14)
    static let bubbleShadowViolet = Color(hex: "#A875FF")
                                        .opacity(0.12)

    /// Default Google-calendar blue, used by event pills with
    /// no explicit colour. Drives the user-message bubble too.
    /// We brighten it slightly in dark mode so it lifts off
    /// the dark cream backdrop.
    static let eventBlue = Color(
        light: Color(hex: "#4F8EF7"),
        dark:  Color(hex: "#7AAEFF")
    )

    /// Faint blue background for the user message bubble.
    /// Higher opacity in dark mode so the tint stays legible.
    static let eventBlueSoft = Color(
        light: Color(hex: "#4F8EF7").opacity(0.16),
        dark:  Color(hex: "#7AAEFF").opacity(0.22)
    )
}

// MARK: - Light/Dark colour helper

/// Convenience initialiser that picks one of two colours based
/// on the current appearance. Mirrors UIKit's `UIColor(dynamicProvider:)`
/// for macOS — wraps `NSColor(name:dynamicProvider:)`.
private extension Color {
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            // Resolve which side of the appearance we're on.
            // `bestMatch(from:)` handles the High Contrast +
            // accessibility variants too — for our purposes we
            // collapse them to plain dark vs light.
            let isDark = appearance.bestMatch(from: [
                .aqua, .darkAqua,
                .accessibilityHighContrastAqua,
                .accessibilityHighContrastDarkAqua
            ]).map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua }
            ?? false
            return NSColor(isDark ? dark : light)
        })
    }
}

// MARK: - Liquid Glass helpers

/// Wraps `content` in a `GlassEffectContainer` on macOS 26+ so
/// every nested glass surface shares refraction + edge
/// highlights and morphs together. On older systems it's just a
/// transparent pass-through — the call site doesn't change.
@ViewBuilder
private func liquidGlassContainer<Content: View>(
    @ViewBuilder content: () -> Content
) -> some View {
    if #available(macOS 26.0, *) {
        GlassEffectContainer(spacing: 0) { content() }
    } else {
        content()
    }
}

/// Conditional Liquid Glass surfaces. We layer them as
/// extensions so the call-site reads cleanly and the
/// availability gate lives in one place.
private extension View {

    /// Top-level chat panel surface (the popover background).
    /// Layers a cream wash matching the task-pill background so
    /// the entire chat reads as part of the same visual family
    /// as the pills the AI returns. On macOS 26+ the cream is
    /// painted *under* a Liquid Glass tint so the colour pulls
    /// through the glass; older systems get a flat cream fill.
    @ViewBuilder
    func liquidGlassPanel<S: InsettableShape>(shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self
                .background(shape.fill(ApolloPalette.cream))
                .background(shape.fill(.thinMaterial))
                .glassEffect(.regular.tint(ApolloPalette.cream.opacity(0.45)),
                             in: shape)
                .clipShape(shape)
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.55),
                                ApolloPalette.cream.opacity(0.40),
                                ApolloPalette.eventBlue.opacity(0.20)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
                )
        } else {
            self
                .background(ApolloPalette.cream)
                .clipShape(shape)
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.40),
                                ApolloPalette.creamBorder
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.6
                    )
                )
        }
    }

    /// Composer text field background — cream tint so the
    /// composer reads as part of the same family as the
    /// task-pill cards in the chat above.
    @ViewBuilder
    func liquidGlassField<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self
                .background(shape.fill(ApolloPalette.cream))
                .glassEffect(.regular.tint(ApolloPalette.cream.opacity(0.55))
                                .interactive(),
                             in: shape)
        } else {
            self.background(ApolloPalette.cream, in: shape)
        }
    }

    /// Suggestion-tile surface — accent-tinted glass.
    @ViewBuilder
    func liquidGlassTile<S: Shape>(in shape: S, tint: Color) -> some View {
        if #available(macOS 26.0, *) {
            self
                .background(
                    shape.fill(tint.opacity(0.10))
                )
                .glassEffect(.regular.tint(tint.opacity(0.18)).interactive(),
                             in: shape)
        } else {
            self
                .background(tint.opacity(0.10), in: shape)
                .background(.ultraThinMaterial, in: shape)
        }
    }
}


// MARK: - Reusable interactive feedback (hover / press / launch)

/// View-modifier that gives any pill or card the same tactile
/// behaviour the AI suggestion tiles have:
///   • subtle scale-up on hover (1.02)
///   • subtle scale-down on press (0.96)
///   • brief scale-up + accent-light "flash" on click (1.06)
///
/// Designed so a single `.interactivePillFeedback(accent:)` call
/// upgrades any existing tappable pill — task pills, event
/// pills, suggestion tiles, dashboard rows — without needing to
/// restructure the surrounding view. The flash is rendered as a
/// `.plusLighter` overlay tinted to `accent`, so it lights up
/// against any background colour.
/// App-wide observer for "is any NSScrollView currently doing a
/// live scroll?". Subscribes once at process start to AppKit's
/// `willStartLiveScrollNotification` / `didEndLiveScrollNotification`
/// — those fire from every NSScrollView (including the ones
/// SwiftUI's `ScrollView` and `List` wrap), so a single shared
/// publisher covers every list and pill stack in the app.
///
/// `InteractivePillFeedback` reads this to silence hover effects
/// while the user is scrolling — without it, dragging through a
/// long task list re-renders each pill as the cursor sweeps past
/// (scale + colored shadow + halo), which is the hottest GPU
/// path on a Retina display.
@MainActor
final class ScrollStateObserver: ObservableObject {
    static let shared = ScrollStateObserver()

    @Published private(set) var isScrolling: Bool = false

    /// True iff a live NSScrollView scroll is currently in progress.
    /// Static accessor mirrors the published value but avoids
    /// registering a SwiftUI dependency, so callers (`onHover`
    /// closures, gesture handlers) can read it cheaply per event.
    static var isScrollingNow: Bool { shared.isScrolling }

    private var startToken: NSObjectProtocol?
    private var endToken:   NSObjectProtocol?
    private var stopWork:   DispatchWorkItem?

    private init() {
        startToken = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Cancel any pending "stop" so the flag stays true
            // through quick momentum-scroll sequences.
            self?.stopWork?.cancel()
            if self?.isScrolling == false {
                self?.isScrolling = true
            }
        }
        endToken = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Brief grace period so a momentum decay that
            // briefly stops then resumes doesn't cause a
            // spurious hover frame.
            let wi = DispatchWorkItem { [weak self] in
                self?.isScrolling = false
            }
            self?.stopWork = wi
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18,
                                          execute: wi)
        }
    }
}

// MARK: - Scroll-aware hover

extension View {
    /// Drop-in replacement for `.onHover { ... }` that suppresses
    /// hover updates while a live NSScrollView scroll is in
    /// progress. The wrapped closure is called with `false` the
    /// moment a scroll starts (so any active hover state resets),
    /// then ignored entirely until the scroll ends. Re-entry on
    /// hover is the normal behaviour once the scroll settles.
    ///
    /// This prevents the cursor sweeping past N rows during scroll
    /// from triggering N hover-enter / hover-exit transitions —
    /// each of which would re-render a row's hover halo, scale,
    /// and accent shadow on the GPU. Reading
    /// `ScrollStateObserver.isScrollingNow` directly (not via
    /// `@ObservedObject`) means this modifier doesn't register a
    /// body-level dependency, so it stays free at rest.
    func scrollAwareOnHover(_ perform: @escaping (Bool) -> Void) -> some View {
        modifier(ScrollAwareHoverModifier(perform: perform))
    }
}

private struct ScrollAwareHoverModifier: ViewModifier {
    let perform: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if ScrollStateObserver.isScrollingNow {
                    // Force-reset rather than ignoring: covers the
                    // case where the cursor was already inside a
                    // view when scroll started.
                    perform(false)
                    return
                }
                perform(hovering)
            }
            .onReceive(ScrollStateObserver.shared.$isScrolling) { scrolling in
                if scrolling { perform(false) }
            }
    }
}

struct InteractivePillFeedback: ViewModifier {
    let accent: Color
    /// Corner radius of the host pill — used so the flash
    /// overlay matches the pill silhouette exactly.
    let cornerRadius: CGFloat
    /// Whether to boost a coloured drop-shadow halo on hover
    /// and during the click-flash. Defaults to off because the
    /// AI suggestion tiles already render their own static
    /// halos; pills on the dashboard (TaskRowView,
    /// AgendaEventCard) opt in so the existing tinted shadow
    /// blooms when the cursor enters and pulses on click.
    let glow: Bool
    /// Subtle scale lift used on hover. Dashboard rows live in
    /// a tight stack so they tone the lift down (`1.012`); chat
    /// pills can afford the punchier `1.02`.
    let hoverScale: CGFloat
    /// Whether the click should briefly dip-scale to 0.96.
    /// Disabled for dashboard task pills: they already grow
    /// vertically when expanded, so a press-dip on top of that
    /// reads as jitter. The light flash alone is enough.
    let pressScales: Bool
    /// Master switch — when false the modifier becomes a
    /// transparent pass-through (no hover, no flash, no glow).
    /// Used by TaskRowView to silence the feedback while the
    /// row is expanded into its detail-edit form.
    let enabled: Bool
    /// When true, replaces the full-pill linear flash with a
    /// soft radial pulse that emanates from the click point.
    /// Used on the main dashboard pills so the click feedback
    /// reads as a single ripple of light from where the user
    /// pressed, rather than a uniform overlay across the row.
    let pulseFromClick: Bool
    /// Optional pre-tap callback (e.g. begin closing a popover)
    /// that runs the moment the gesture starts. Default is a
    /// no-op so most callers can ignore it.
    var onTrigger: (() -> Void)? = nil

    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false
    @State private var isFlashing: Bool = false

    // Click-pulse state. `pulseSeed` lets each click instance
    // identify itself so concurrent pulses don't stomp each
    // other; `pulseLocation` is captured in the host view's
    // local coords from the DragGesture's `value.location`.
    @State private var pulseLocation: CGPoint = .zero
    @State private var pulseProgress: CGFloat = 0
    @State private var pulseSeed: Int = 0

    // NOTE: no `@ObservedObject scrollState` here on purpose.
    // Earlier this modifier carried an
    // `@ObservedObject = ScrollStateObserver.shared`, which
    // meant every pill in a list (sometimes 100+ rows)
    // re-rendered the moment any scroll started anywhere in
    // the app — exactly the wrong moment to be paying for
    // re-renders. We now read `ScrollStateObserver.shared`
    // directly inside the `.onHover` and `.onReceive`
    // callbacks; neither path registers a body-level
    // dependency so the modifier is "free" during scroll
    // until the cursor actually enters its host view.

    func body(content: Content) -> some View {
        // Master gate: when disabled we bypass every effect so
        // the host view behaves as if the modifier wasn't
        // applied at all (no overlay, no shadow, no gesture
        // interception, no idle hover state). This is what
        // lets a TaskRowView silence its feedback while
        // expanded — and ensures any hover state captured
        // before expansion clears itself out.
        if enabled {
            content
                .overlay(flashOverlay.allowsHitTesting(false))
                // Coloured halo that intensifies on hover and
                // pulses brighter during the click flash.
                // Applied as an ADDITIONAL shadow stacked on
                // top of whatever the host already paints — so
                // e.g. TaskRowView's resting status-coloured
                // shadow stays visible and simply gets boosted.
                .shadow(
                    color: glow ? accent.opacity(glowOpacity) : .clear,
                    radius: glow ? glowRadius : 0,
                    x: 0, y: glow ? glowYOffset : 0
                )
                .scaleEffect(scaleValue)
                .animation(.spring(response: 0.32, dampingFraction: 0.62),
                           value: isFlashing)
                .animation(.spring(response: 0.3, dampingFraction: 0.7),
                           value: isPressed)
                .animation(.spring(response: 0.4, dampingFraction: 0.75),
                           value: isHovered)
                .onHover { hovering in
                    // Scrolling a long list sweeps the cursor
                    // across many pills in quick succession.
                    // Re-rendering each one (scale + halo +
                    // shadow boost) is the hottest path on a
                    // Retina display, so we ignore hover events
                    // while a live scroll is active. Reading
                    // the observer here (not via @ObservedObject)
                    // means the value access doesn't register
                    // as a body dependency.
                    if ScrollStateObserver.shared.isScrolling {
                        if isHovered { isHovered = false }
                        return
                    }
                    isHovered = hovering
                }
                // `.onReceive` watches the publisher without
                // creating a body-level dependency the way
                // `@ObservedObject` would. The closure only
                // touches @State (via `isHovered`) when scroll
                // actually starts AND we have an active hover —
                // which happens at most a few times per session,
                // not per scroll frame.
                .onReceive(ScrollStateObserver.shared.$isScrolling) { scrolling in
                    if scrolling, isHovered { isHovered = false }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isPressed {
                                isPressed = true
                                onTrigger?()
                                if pulseFromClick {
                                    triggerClickPulse(at: value.location)
                                } else {
                                    // Fire the linear flash
                                    // exactly once per gesture
                                    // start so a long-press
                                    // doesn't repeat it.
                                    isFlashing = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                                        isFlashing = false
                                    }
                                }
                            }
                        }
                        .onEnded { _ in
                            isPressed = false
                        }
                )
        } else {
            // Disabled — render the host as-is. Reset latent
            // state so re-enabling later starts from rest
            // instead of a stale hover/press state.
            content
                .onAppear {
                    isHovered = false
                    isPressed = false
                    isFlashing = false
                }
        }
    }

    /// Scale arbitration. `pressScales == false` skips the dip
    /// step entirely, so the only scale change is the brief
    /// flash beat. Used by dashboard task pills, where a
    /// press-dip on top of the row's expand animation would
    /// read as jitter.
    private var scaleValue: CGFloat {
        if isFlashing             { return 1.06 }
        if isPressed && pressScales { return 0.96 }
        if isHovered              { return hoverScale }
        return 1
    }

    /// The flash overlay — switches between two visual modes:
    ///   • `pulseFromClick == false`: full-pill linear gradient
    ///     wash (used by chat pills / suggestion tiles where a
    ///     uniform "you tapped me" reads cleanest).
    ///   • `pulseFromClick == true`: a single soft radial
    ///     ripple emanating from the click point, used by main-
    ///     dashboard rows so the click feedback originates
    ///     where the cursor actually was. The ripple grows from
    ///     a small disc to a generous radius (about 1.7× the
    ///     pill's longest side) while its opacity tail-decays
    ///     to zero over ~0.7s — long enough that the user reads
    ///     it as a soft dispersing wave rather than a flicker.
    @ViewBuilder
    private var flashOverlay: some View {
        if pulseFromClick {
            // PERF: only build the GeometryReader + Circle +
            // RadialGradient + mask chain when a pulse is
            // actually in progress. At rest (`pulseProgress
            // == 0`), the chain renders nothing visible
            // (scaleEffect 0, opacity ~0) but still costs a
            // full layout pass via `GeometryReader` plus the
            // gradient/mask construction — multiplied by
            // every visible pill on screen, that was the
            // single largest non-AppState scroll cost. Gating
            // on `pulseProgress > 0` means idle cards return
            // `EmptyView()` here (cost: zero), and the
            // ripple chain only spins up while a click is
            // mid-animation.
            if pulseProgress > 0 {
                GeometryReader { geo in
                    let maxDim = max(geo.size.width, geo.size.height)
                    // Pulse disc — sized so the disc at full
                    // progress dwarfs the pill, giving the ripple
                    // room to "spread past" the silhouette before
                    // the mask cuts it off. Larger base = more area
                    // covered at peak before the opacity decays.
                    let baseDiameter: CGFloat = maxDim * 1.7

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    accent.opacity(0.55),
                                    accent.opacity(0.28),
                                    accent.opacity(0.10),
                                    .clear
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: baseDiameter / 2
                            )
                        )
                        .frame(width: baseDiameter, height: baseDiameter)
                        .scaleEffect(pulseProgress)
                        // Late-decay opacity curve: stays close to
                        // peak through the first ~50% of growth and
                        // only really fades during the back half,
                        // so the ripple feels like it disperses
                        // outward instead of dissolving as it
                        // expands. `pow(1 - p, 1.6)` is gentler
                        // than the original `1 - p` linear curve.
                        .opacity(pow(Double(1 - pulseProgress), 1.6) * 0.6)
                        .position(pulseLocation)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                        // Confine the ripple to the pill silhouette
                        // so it doesn't bleed past the rounded
                        // corners.
                        .mask(
                            RoundedRectangle(cornerRadius: cornerRadius,
                                             style: .continuous)
                        )
                }
            }
        } else {
            // Linear-flash path used by chat pills (TaskChatPill,
            // EventChatPill). These sit on the cream popup
            // surface, so an additive `.plusLighter` blend
            // saturates the cream straight to white instead of
            // producing the intended accent tint. Switching to
            // the default source-over blend with a stronger
            // gradient opacity gives the same "you tapped me"
            // beat in unmistakable colour, regardless of how
            // light the underlying surface is.
            //
            // Same idle-skip pattern as the radial-pulse
            // path: `isFlashing` is false at rest, so we
            // render `EmptyView()` and avoid building the
            // RoundedRectangle + LinearGradient on every
            // re-eval.
            if isFlashing {
                RoundedRectangle(cornerRadius: cornerRadius,
                                 style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(0.85),
                                accent.opacity(0.35)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .opacity(0.55)
            }
        }
    }

    /// Kicks off a single ripple from `point`. Resets progress
    /// to 0 instantly, then animates up to 1 over 0.55s. Each
    /// click bumps `pulseSeed` so a tap during a fading ripple
    /// restarts cleanly without interpolating from the previous
    /// frame.
    ///
    /// CRITICAL: BOTH `pulseLocation` and `pulseProgress = 0`
    /// must live inside the SAME `disablesAnimations`
    /// transaction. The `.animation(_:value: isPressed)` modifier
    /// stacked further down the chain creates an ambient
    /// implicit-animation context whenever `isPressed` flips —
    /// and that context picks up *every* state change happening
    /// in the same render pass, including a bare
    /// `pulseLocation = point`. Without the explicit transaction
    /// wrap, the circle's `.position(pulseLocation)` interpolates
    /// from its previous value (initially `.zero` = top-left
    /// corner) to the click point over the spring duration —
    /// which is exactly the "ripple comes from the left edge"
    /// bug. Wrapping both writes together forces them to land
    /// instantly so the ripple always starts AT the click.
    private func triggerClickPulse(at point: CGPoint) {
        pulseSeed &+= 1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pulseLocation = point
            pulseProgress = 0
        }
        // Then ease the ripple outward in its own animated
        // transaction. 0.7s is long enough that the user reads
        // it as a soft dispersing wave; combined with the
        // late-decay opacity curve in `flashOverlay`, it lets
        // the ripple cover a generous area before fading out
        // instead of vanishing as soon as it reaches full
        // scale.
        withAnimation(.easeOut(duration: 0.7)) {
            pulseProgress = 1
        }
    }

    private var glowOpacity: Double {
        if isFlashing { return 0.65 }
        if isHovered  { return 0.50 }
        return 0
    }
    private var glowRadius: CGFloat {
        if isFlashing { return 14.3 }
        if isHovered  { return 10.4 }
        return 0
    }
    private var glowYOffset: CGFloat {
        if isFlashing { return 5.2 }
        if isHovered  { return 3.9 }
        return 0
    }
}

extension View {
    /// Applies the standard Apollo pill feedback (hover scale,
    /// press dip, click flash). Pass the dominant accent colour
    /// of the pill so the flash matches its identity. The
    /// `cornerRadius` should match the pill's actual rounding
    /// so the flash silhouette aligns pixel-perfectly. Set
    /// `glow: true` on dashboard pills so the existing tinted
    /// drop-shadow blooms on hover and pulses on click.
    func interactivePillFeedback(
        accent: Color,
        cornerRadius: CGFloat,
        glow: Bool = false,
        hoverScale: CGFloat = 1.02,
        pressScales: Bool = true,
        enabled: Bool = true,
        pulseFromClick: Bool = false,
        onTrigger: (() -> Void)? = nil
    ) -> some View {
        modifier(InteractivePillFeedback(
            accent: accent,
            cornerRadius: cornerRadius,
            glow: glow,
            hoverScale: hoverScale,
            pressScales: pressScales,
            enabled: enabled,
            pulseFromClick: pulseFromClick,
            onTrigger: onTrigger
        ))
    }
}

// MARK: - AI mention contact

/// Unified contact entry surfaced by the chat composer's `@`
/// autocomplete. Wraps both ClickUp roster members and
/// calendar attendees behind a single shape so the picker
/// renders them uniformly. The `kind` tag drives the secondary
/// metadata (username vs e-mail) and the source label
/// ("ClickUp" / "Calendário").
struct AIContact: Identifiable, Hashable {
    enum Kind { case clickup, email }
    let id:        String
    let name:      String
    let secondary: String
    let kind:      Kind
}
