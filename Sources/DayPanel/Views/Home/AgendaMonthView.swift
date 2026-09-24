import SwiftUI

struct AgendaMonthView: View {
    @EnvironmentObject var appState: AppState
    @Binding var month: Date
    @State private var fetchedEvents: [CalendarEvent]?
    @State private var loading = false
    @State private var error: String?
    @State private var revision = 0
    @State private var selectedDay: DaySelection?
    var topInset: CGFloat = 110

    private struct DaySelection: Identifiable { let id: Date }
    private struct Request: Equatable {
        let month: Date
        let revision: Int
        let connected: Bool
        let shared: [SharedCalendar]
    }
    private var request: Request {
        Request(month: month, revision: revision,
                connected: appState.googleAuth.isConnected, shared: appState.sharedCalendars)
    }
    private var localEvents: [CalendarEvent] {
        appState.events + appState.sharedEvents.values.flatMap { $0 }
    }
    @State private var summaryHeight: CGFloat = 220

    private static let weekdays = ["SEG", "TER", "QUA", "QUI", "SEX", "SÁB", "DOM"]
    private static let weekdayRowHeight: CGFloat = 28
    private static let sectionGap: CGFloat = 12
    private static let minimumRowHeight: CGFloat = 58

    var body: some View {
        let model = AgendaMonth(containing: month)
        let index = model.eventsByDay(fetchedEvents ?? localEvents)
        let weeks = model.days.count / 7
        GeometryReader { geometry in
            let banner: CGFloat = error == nil ? 0 : 38
            let available = geometry.size.height - topInset - 16 - banner
                - Self.weekdayRowHeight - Self.sectionGap - summaryHeight
            let rowHeight = max(Self.minimumRowHeight, (available - CGFloat(weeks)) / CGFloat(weeks))
            VStack(spacing: 0) {
                if let error { errorBanner(error) }
                ScrollView {
                    VStack(spacing: Self.sectionGap) {
                        monthGrid(model: model, index: index, weeks: weeks, rowHeight: rowHeight)
                        AgendaMonthSummaryCard(
                            month: model,
                            summary: model.summary(index),
                            wide: geometry.size.width - 32 >= 620,
                            onSelectDay: { selectedDay = DaySelection(id: $0) },
                            onOpen: open
                        )
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { summaryHeight = $0 }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.never)
            }
            .padding(.horizontal, 16)
            .padding(.top, topInset)
            .padding(.bottom, 16)
        }
        .background(Editorial.paper)
        .overlay(alignment: .bottomTrailing) {
            if loading { ProgressView().controlSize(.small).padding(.trailing, 24).padding(.bottom, 24) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.title)
        .task(id: request) { await loadMonth(model) }
        .onChange(of: appState.isSyncing) { old, new in
            if old && !new { revision += 1 }
        }
        .onChange(of: appState.events) { _, _ in revision += 1 }
        .onChange(of: appState.sharedEvents) { _, _ in revision += 1 }
    }

    /// Weekday row and weeks share one card; the 1pt gaps over `rule`
    /// draw the hairlines.
    private func monthGrid(model: AgendaMonth, index: [Date: [CalendarEvent]],
                           weeks: Int, rowHeight: CGFloat) -> some View {
        VStack(spacing: 1) {
            weekdayHeader
            ForEach(0..<weeks, id: \.self) { week in
                HStack(spacing: 1) {
                    ForEach(model.days[(week * 7)..<(week * 7 + 7)], id: \.self) { day in
                        AgendaDayCell(
                            day: day, calendar: model.calendar,
                            inMonth: model.calendar.isDate(day, equalTo: month, toGranularity: .month),
                            events: index[day] ?? [],
                            height: rowHeight,
                            isSelected: selectedDay?.id == day,
                            onSelect: { selectedDay = DaySelection(id: day) },
                            onOpen: open
                        )
                        .popover(isPresented: popoverBinding(for: day), arrowEdge: .trailing) {
                            AgendaDayPopover(day: day, events: index[day] ?? [], onOpen: open)
                        }
                    }
                }
            }
        }
        .background(Editorial.rule)
        .agendaCard()
    }

    private var weekdayHeader: some View {
        HStack(spacing: 1) {
            ForEach(Array(Self.weekdays.enumerated()), id: \.offset) { offset, day in
                Text(day)
                    .font(Editorial.sans(10, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(offset >= 5 ? Editorial.inkFaint : Editorial.inkMute)
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: Self.weekdayRowHeight)
        .background(Editorial.panelDeep)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .foregroundStyle(Editorial.inkSoft)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Tentar novamente") { revision += 1 }
                .buttonStyle(.link)
        }
        .font(Editorial.sans(11, .medium))
        .frame(height: 30)
        .padding(.bottom, 8)
    }

    private func popoverBinding(for day: Date) -> Binding<Bool> {
        Binding(
            get: { selectedDay?.id == day },
            set: { presented in
                if !presented, selectedDay?.id == day { selectedDay = nil }
            }
        )
    }

    private func open(_ event: CalendarEvent) {
        selectedDay = nil
        // Existing detail mutations update AppState's event cache. Seed only
        // the opened primary event when browsing beyond the sync window.
        if event.calendarId == "primary", !appState.events.contains(where: { $0.id == event.id }) {
            appState.events.append(event)
        }
        appState.detailEventOrigin = MouseOriginCapture.currentClickRectInMainWindow()
        withAnimation(.spring(duration: 0.45, bounce: 0.35)) { appState.detailEvent = event }
    }

    @MainActor private func loadMonth(_ model: AgendaMonth) async {
        fetchedEvents = nil
        error = nil
        loading = false
        guard !ApolloDevLaunchOptions.isFixtureMode, !ApolloRuntimeEnvironment.isStudio,
              !appState.showMockData, appState.googleAuth.isConnected else { return }
        loading = true
        do {
            var loaded = try await appState.googleCalendar.listEventsOnCalendar(
                calendarId: "primary", from: model.interval.start, to: model.interval.end)
            var sharedFailed = false
            for calendar in appState.sharedCalendars {
                try Task.checkCancellation()
                do {
                    let result = try await appState.googleCalendar.listSharedCalendar(
                        email: calendar.email, from: model.interval.start, to: model.interval.end,
                        contactColorHex: calendar.colorHex)
                    loaded += result.events
                } catch is CancellationError { throw CancellationError() }
                catch { sharedFailed = true }
            }
            try Task.checkCancellation()
            fetchedEvents = loaded
            error = sharedFailed ? "Algumas agendas compartilhadas não foram carregadas." : nil
            loading = false
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Não foi possível atualizar os eventos deste mês."
            loading = false
        }
    }
}

private extension CalendarEvent {
    var calendarIdentity: String { calendarId + "|" + id }
}

private enum AgendaFormat {
    static let locale = Locale(identifier: "pt_BR")

    static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = format
        return formatter
    }

    static let time = formatter("HH:mm")
    static let shortMonth = formatter("MMM")
    static let weekday = formatter("EEEE")
    static let monthYear = formatter("MMMM 'de' yyyy")

    static func timeRange(_ event: CalendarEvent) -> String {
        guard !event.isAllDay else { return "Dia inteiro" }
        return time.string(from: event.startDate) + " – " + time.string(from: event.endDate)
    }

    static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// One day of the month grid: number, as many chips as the row height
/// allows and a "+N" line that opens the day's full list.
private struct AgendaDayCell: View {
    let day: Date
    let calendar: Calendar
    let inMonth: Bool
    let events: [CalendarEvent]
    let height: CGFloat
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: (CalendarEvent) -> Void
    @State private var hovering = false

    private static let padding: CGFloat = 5
    private static let numberSize: CGFloat = 22
    private static let moreHeight: CGFloat = 12
    private static let spacing: CGFloat = 3

    private var isToday: Bool { calendar.isDateInToday(day) }
    private var number: Int { calendar.component(.day, from: day) }

    /// Every chip when they all fit below the number; otherwise as many as
    /// leave room for the "+N mais" line.
    private var visibleLimit: Int {
        let free = height - Self.padding * 2 - Self.numberSize
        let unit = AgendaEventChip.height + Self.spacing
        if CGFloat(events.count) * unit <= free { return events.count }
        return max(0, Int((free - Self.moreHeight - Self.spacing) / unit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            dayNumber
            ForEach(Array(events.prefix(visibleLimit)), id: \.calendarIdentity) { event in
                AgendaEventChip(event: event, onOpen: onOpen)
            }
            if events.count > visibleLimit {
                Button(action: onSelect) {
                    Text("+\(events.count - visibleLimit) mais")
                        .font(Editorial.sans(10, .semibold))
                        .foregroundStyle(Editorial.inkSoft)
                        .padding(.leading, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, Self.padding)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(background)
        .overlay {
            if isSelected {
                Rectangle().strokeBorder(Editorial.accent, lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction(named: "Ver compromissos", onSelect)
    }

    private var dayNumber: some View {
        HStack(spacing: 4) {
            Text("\(number)")
                .font(Editorial.sans(12.5, isToday ? .bold : .semibold))
                .monospacedDigit()
                .foregroundStyle(isToday ? Color.white : (inMonth ? Editorial.ink : Editorial.inkFaint))
                .frame(minWidth: Self.numberSize, minHeight: Self.numberSize)
                .background {
                    if isToday { Circle().fill(Editorial.accent) }
                }
            // Calendar.app convention: the 1st names its month, so the
            // adjacent-month days read unambiguously.
            if number == 1 {
                Text(AgendaFormat.shortMonth.string(from: day).replacingOccurrences(of: ".", with: ""))
                    .font(Editorial.sans(11, .medium))
                    .foregroundStyle(inMonth ? Editorial.inkSoft : Editorial.inkFaint)
            }
        }
    }

    private var background: some View {
        ZStack {
            inMonth ? Editorial.page : Editorial.paper
            if isToday { Editorial.accent.opacity(0.06) }
            if hovering { Editorial.ink.opacity(0.03) }
        }
    }

    private var accessibilityText: String {
        let date = day.formatted(date: .complete, time: .omitted)
        switch events.count {
        case 0: return date + ", sem compromissos"
        case 1: return date + ", 1 compromisso"
        default: return date + ", \(events.count) compromissos"
        }
    }
}

/// Timed events read as a tinted row (bar · title · time); all-day events
/// as a solid bar, like Calendar.app's month view.
private struct AgendaEventChip: View {
    static let height: CGFloat = 20
    let event: CalendarEvent
    let onOpen: (CalendarEvent) -> Void
    @State private var hovering = false

    var body: some View {
        let tint = Color(statusHex: event.colorHex)
        Button { onOpen(event) } label: {
            Group {
                if event.isAllDay {
                    title
                        .font(Editorial.sans(11, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
                        .background(tint.opacity(hovering ? 1 : 0.88),
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    HStack(spacing: 4) {
                        Capsule().fill(tint).frame(width: 2.5, height: 12)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 4) {
                                title.fixedSize()
                                Spacer(minLength: 2)
                                time
                            }
                            title
                        }
                    }
                    .padding(.leading, 3)
                    .padding(.trailing, 4)
                    .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
                    .background(tint.opacity(hovering ? 0.28 : 0.17),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(event.title + " · " + AgendaFormat.timeRange(event))
        .accessibilityLabel(event.title + ", " + AgendaFormat.timeRange(event))
    }

    private var title: some View {
        Text(event.title)
            .font(Editorial.sans(11, .medium))
            .foregroundStyle(Editorial.ink)
            .lineLimit(1)
    }

    private var time: some View {
        Text(AgendaFormat.time.string(from: event.startDate))
            .font(Editorial.sans(10, .medium))
            .monospacedDigit()
            .foregroundStyle(Editorial.inkSoft)
    }
}

/// Full list for one day, anchored to its cell.
private struct AgendaDayPopover: View {
    let day: Date
    let events: [CalendarEvent]
    let onOpen: (CalendarEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text("\(Calendar.current.component(.day, from: day))")
                    .font(Editorial.sans(30, .bold))
                    .monospacedDigit()
                    .foregroundStyle(Calendar.current.isDateInToday(day) ? Editorial.accent : Editorial.ink)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AgendaFormat.capitalized(AgendaFormat.weekday.string(from: day)))
                        .font(Editorial.sans(13, .semibold))
                        .foregroundStyle(Editorial.ink)
                    Text(AgendaFormat.monthYear.string(from: day))
                        .font(Editorial.sans(11, .medium))
                        .foregroundStyle(Editorial.inkSoft)
                }
                Spacer(minLength: 0)
            }
            Rectangle().fill(Editorial.rule).frame(height: 1)
            if events.isEmpty {
                Text("Nenhum compromisso neste dia.")
                    .font(Editorial.sans(12, .medium))
                    .foregroundStyle(Editorial.inkSoft)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(events, id: \.calendarIdentity) { event in
                            AgendaPopoverRow(event: event, onOpen: onOpen)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

private struct AgendaPopoverRow: View {
    let event: CalendarEvent
    let onOpen: (CalendarEvent) -> Void
    @State private var hovering = false

    private var detail: String {
        let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return AgendaFormat.timeRange(event) + (location.isEmpty ? "" : " · " + location)
    }

    var body: some View {
        Button { onOpen(event) } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(statusHex: event.colorHex))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(Editorial.sans(12.5, .semibold))
                        .foregroundStyle(Editorial.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(detail)
                        .font(Editorial.sans(11, .medium))
                        .foregroundStyle(Editorial.inkSoft)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .background(hovering ? Editorial.ink.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private extension View {
    /// Surface shared by the month grid and its summary.
    func agendaCard() -> some View {
        clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Editorial.rule, lineWidth: 1)
            }
    }
}

/// Month digest under the grid: four figures and up to three highlights
/// that point back into the calendar (select a day or open an event).
private struct AgendaMonthSummaryCard: View {
    let month: AgendaMonth
    let summary: AgendaMonthSummary
    let wide: Bool
    let onSelectDay: (Date) -> Void
    let onOpen: (CalendarEvent) -> Void

    private static let longDay = AgendaFormat.formatter("EEEE, d 'de' MMMM")
    private static let dayOnly = AgendaFormat.formatter("d")
    private static let dayMonth = AgendaFormat.formatter("d 'de' MMMM")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Folio("Resumo do mês")
                Spacer(minLength: 8)
                if let caption {
                    Text(caption)
                        .font(Editorial.sans(11, .medium))
                        .foregroundStyle(Editorial.inkMute)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if wide {
                HStack(alignment: .top, spacing: 0) {
                    figures.frame(maxWidth: .infinity)
                    Rectangle().fill(Editorial.rule).frame(width: 1)
                    highlights.frame(maxWidth: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                figures
                Rectangle().fill(Editorial.rule).frame(height: 1)
                highlights
            }
        }
        .background(Editorial.page)
        .agendaCard()
    }

    private var caption: String? {
        guard let left = summary.daysLeft else { return nil }
        return left == 1 ? "Último dia do mês" : "Faltam \(left) dias"
    }

    // MARK: Figures

    private var figures: some View {
        HStack(spacing: 0) {
            figure("\(summary.eventCount)", summary.eventCount == 1 ? "Compromisso" : "Compromissos")
            figure("\(summary.busyDays)", summary.busyDays == 1 ? "Dia ocupado" : "Dias ocupados")
            figure(Self.hours(summary.scheduledMinutes), "Horas marcadas")
            figure("\(summary.freeWeekdays)", summary.freeWeekdays == 1 ? "Dia útil livre" : "Dias úteis livres")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Editorial.sans(20, .semibold))
                .monospacedDigit()
                .foregroundStyle(Editorial.ink)
            Text(label)
                .font(Editorial.sans(10.5, .medium))
                .foregroundStyle(Editorial.inkMute)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    static func hours(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if m == 0 { return "\(h)h" }
        return h == 0 ? "\(m)min" : "\(h)h\(String(format: "%02d", m))"
    }

    // MARK: Highlights

    @ViewBuilder private var highlights: some View {
        VStack(spacing: 0) {
            if summary.eventCount == 0 {
                AgendaHighlightRow(symbol: "calendar.badge.checkmark",
                                   title: "Mês livre",
                                   detail: "Nenhum compromisso em " + month.title.lowercased(),
                                   action: nil)
            }
            if let busiest = summary.busiestDay {
                AgendaHighlightRow(
                    symbol: "chart.bar.fill",
                    title: "Dia mais cheio",
                    detail: AgendaFormat.capitalized(Self.longDay.string(from: busiest.day))
                        + " · \(busiest.count) " + (busiest.count == 1 ? "compromisso" : "compromissos")
                        + (busiest.minutes > 0 ? " · " + Self.hours(busiest.minutes) : ""),
                    action: { onSelectDay(busiest.day) })
            }
            if let stretch = summary.freeStretch {
                AgendaHighlightRow(
                    symbol: "sun.max",
                    title: "Maior janela livre",
                    detail: Self.dayOnly.string(from: stretch.start) + " a "
                        + Self.dayMonth.string(from: stretch.end) + " · \(stretch.days) dias sem compromissos",
                    action: { onSelectDay(stretch.start) })
            }
            if let allDay = summary.allDayEvents.first {
                AgendaHighlightRow(
                    symbol: "sun.horizon",
                    title: allDay.title,
                    detail: AgendaFormat.capitalized(Self.longDay.string(from: allDay.startDate))
                        + " · dia inteiro"
                        + (summary.allDayEvents.count > 1 ? " · +\(summary.allDayEvents.count - 1)" : ""),
                    action: { onOpen(allDay) })
            }
        }
        .padding(.vertical, 6)
    }
}

private struct AgendaHighlightRow: View {
    let symbol: String
    let title: String
    let detail: String
    let action: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Editorial.accent)
                    .frame(width: 26, height: 26)
                    .background(Editorial.accentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Editorial.sans(12, .semibold))
                        .foregroundStyle(Editorial.ink)
                        .lineLimit(1)
                    Text(detail)
                        .font(Editorial.sans(11, .medium))
                        .foregroundStyle(Editorial.inkSoft)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Editorial.inkFaint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(hovering && action != nil ? Editorial.ink.opacity(0.05) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .onHover { hovering = $0 }
        .padding(.horizontal, 6)
    }
}
