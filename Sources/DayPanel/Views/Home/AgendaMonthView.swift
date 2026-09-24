import SwiftUI

/// Keep the derived calendar stable when unrelated AppState publications or a
/// day selection redraw the view. Arrays retain their copy-on-write storage;
/// full event equality still invalidates changed titles, colours and actions.
@MainActor
final class AgendaMonthProjectionCache {
    struct Projection {
        let model: AgendaMonth
        let index: [Date: [CalendarEvent]]
    }
    private struct Input: Equatable {
        let month: Date
        let calendar: Calendar
        let primary: [CalendarEvent]
        let shared: [String: [CalendarEvent]]
        let fetched: [CalendarEvent]?
    }
    private var input: Input?
    private var projection: Projection?

    func resolve(month: Date, calendar: Calendar = .current,
                 primary: [CalendarEvent], shared: [String: [CalendarEvent]],
                 fetched: [CalendarEvent]?) -> Projection {
        let next = Input(month: month, calendar: calendar,
                         primary: fetched == nil ? primary : [],
                         shared: fetched == nil ? shared : [:], fetched: fetched)
        if input == next, let projection { return projection }
        let model = AgendaMonth(containing: month, calendar: calendar)
        let events = fetched ?? (primary + shared.values.flatMap { $0 })
        let value = Projection(model: model, index: model.eventsByDay(events))
        input = next
        projection = value
        return value
    }
}

struct AgendaMonthView: View {
    @EnvironmentObject var appState: AppState
    @Binding var month: Date
    @State private var fetchedEvents: [CalendarEvent]?
    @State private var loading = false
    @State private var error: String?
    @State private var revision = 0
    @State private var projectionCache = AgendaMonthProjectionCache()
    /// Day shown in the panel under the grid; nil means the default
    /// (today in the current month, otherwise the 1st).
    @State private var selectedDay: Date?
    var topInset: CGFloat = 110

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
    private func focusedDay(_ model: AgendaMonth) -> Date {
        if let selectedDay, model.days.contains(selectedDay) { return selectedDay }
        let today = model.calendar.startOfDay(for: Date())
        return model.monthDays.contains(today) ? today : model.start
    }

    private static let weekdays = ["SEG", "TER", "QUA", "QUI", "SEX", "SÁB", "DOM"]
    private static let weekdayRowHeight: CGFloat = 26
    private static let sectionGap: CGFloat = 20
    private static let cellGap: CGFloat = 6
    /// Number (20) + lettered disc (17) + gaps and padding.
    private static let minimumRowHeight: CGFloat = 50
    private static let minimumPanelHeight: CGFloat = 220
    /// Share of the page height given to the grid (weekday row included).
    /// With event chips the grid took ~68% of the default window; dots let it
    /// drop 25% to ~51%, and the selected day's panel takes the rest.
    private static let gridShare: CGFloat = 0.51

    var body: some View {
        let projection = projectionCache.resolve(month: month, primary: appState.events,
                                                  shared: appState.sharedEvents, fetched: fetchedEvents)
        let model = projection.model
        let index = projection.index
        let day = focusedDay(model)
        let weeks = model.days.count / 7
        GeometryReader { geometry in
            let banner: CGFloat = error == nil ? 0 : 38
            let page = geometry.size.height - topInset - 16 - banner
            let rows = page * Self.gridShare - Self.weekdayRowHeight - CGFloat(weeks - 1) * Self.cellGap
            let rowHeight = max(Self.minimumRowHeight, rows / CGFloat(weeks))
            let gridHeight = Self.weekdayRowHeight + CGFloat(weeks - 1) * Self.cellGap
                + rowHeight * CGFloat(weeks)
            let panelHeight = max(Self.minimumPanelHeight, page - gridHeight - Self.sectionGap)
            VStack(spacing: 0) {
                if let error { errorBanner(error) }
                ScrollView {
                    VStack(spacing: Self.sectionGap) {
                        monthGrid(model: model, index: index, weeks: weeks, rowHeight: rowHeight, selected: day)
                        AgendaDayPanel(day: day, calendar: model.calendar,
                                       events: index[day] ?? [], onOpen: open)
                            .frame(height: panelHeight)
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
        .onChange(of: appState.todayJumpToken) { _, _ in
            withAnimation(.spring(duration: 0.28, bounce: 0.15)) {
                selectedDay = Calendar.current.startOfDay(for: Date())
            }
        }
        .onChange(of: appState.sharedEvents) { _, _ in revision += 1 }
    }

    /// No rules anywhere: each day is a filled tile and the gaps between
    /// tiles carry the structure.
    private func monthGrid(model: AgendaMonth, index: [Date: [CalendarEvent]],
                           weeks: Int, rowHeight: CGFloat, selected: Date) -> some View {
        VStack(spacing: Self.cellGap) {
            weekdayHeader
            ForEach(0..<weeks, id: \.self) { week in
                HStack(spacing: Self.cellGap) {
                    ForEach(model.days[(week * 7)..<(week * 7 + 7)], id: \.self) { day in
                        AgendaDayCell(
                            day: day, calendar: model.calendar,
                            inMonth: model.calendar.isDate(day, equalTo: month, toGranularity: .month),
                            events: index[day] ?? [],
                            height: rowHeight,
                            isSelected: selected == day,
                            isToday: model.calendar.isDateInToday(day),
                            onSelect: {
                                withAnimation(.spring(duration: 0.28, bounce: 0.15)) { selectedDay = day }
                            }
                        )
                        .equatable()
                    }
                }
            }
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: Self.cellGap) {
            ForEach(Array(Self.weekdays.enumerated()), id: \.offset) { offset, day in
                Text(day)
                    .font(Editorial.sans(10, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(offset >= 5 ? Editorial.inkFaint : Editorial.inkMute)
                    .padding(.leading, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: Self.weekdayRowHeight - Self.cellGap, alignment: .bottom)
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

    private func open(_ event: CalendarEvent) {
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
    /// First letter or digit of the title ("[IA] Calça" → "I").
    var monogram: String {
        title.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "•"
    }

    /// Light calendar colours (yellow, pale green…) need dark ink.
    var prefersDarkInk: Bool {
        let hex = colorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return false }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        return 0.299 * r + 0.587 * g + 0.114 * b > 0.72
    }
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

/// One day of the month grid: the number and one coloured dot per event.
/// Titles live in the selected day's panel (and in the tooltip).
private struct AgendaDayCell: View, Equatable {
    let day: Date
    let calendar: Calendar
    let inMonth: Bool
    let events: [CalendarEvent]
    let height: CGFloat
    let isSelected: Bool
    let isToday: Bool
    let onSelect: () -> Void
    @State private var hovering = false
    @State private var visibleSlotCount = 1

    // The selection closure only writes this day's value to the same SwiftUI
    // state location. Unchanged inputs need no new dot/tooltip/layout graph.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.day == rhs.day && lhs.calendar == rhs.calendar
            && lhs.inMonth == rhs.inMonth && lhs.events == rhs.events
            && lhs.height == rhs.height && lhs.isSelected == rhs.isSelected
            && lhs.isToday == rhs.isToday
    }

    private static let padding: CGFloat = 5
    private static let numberSize: CGFloat = 20
    private static let dotSize: CGFloat = 14

    private static let overlap: CGFloat = 4
    /// Disc plus its 1.5pt ring on each side.
    private static let discWidth: CGFloat = dotSize + 3

    /// Discs that fit the tile with every letter readable. When the day
    /// has more events, the last slot becomes a "+N" disc instead of the
    /// stack collapsing into unreadable slivers.
    private var shownEvents: ArraySlice<CalendarEvent> {
        return events.count <= visibleSlotCount ? events[...] : events.prefix(max(0, visibleSlotCount - 1))
    }

    private var number: Int { calendar.component(.day, from: day) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            dayNumber
            if !events.isEmpty {
                let shown = shownEvents
                AgendaDotStack(preferredOverlap: Self.overlap) {
                    ForEach(Array(shown.enumerated()), id: \.element.calendarIdentity) { index, event in
                        AgendaEventDot(event: event, ring: ringColor, size: Self.dotSize)
                            // Earliest event on top, later ones tucked behind.
                            .zIndex(Double(events.count - index))
                    }
                    if events.count > shown.count {
                        AgendaMoreDot(count: events.count - shown.count,
                                      ring: ringColor, size: Self.dotSize)
                            .zIndex(Double(events.count + 1))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: Int.self) { geometry in
                    let step = Self.discWidth - Self.overlap
                    return max(1, Int((geometry.size.width - Self.discWidth) / step) + 1)
                } action: { visibleSlotCount = $0 }
                .padding(.horizontal, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, Self.padding)
        .opacity(inMonth ? 1 : 0.5)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(events.map { AgendaFormat.time.string(from: $0.startDate) + "  " + $0.title }
            .joined(separator: "\n"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction(named: "Ver compromissos", onSelect)
    }

    private var dayNumber: some View {
        HStack(spacing: 4) {
            Text("\(number)")
                .font(Editorial.sans(12.5, isToday ? .bold : .semibold))
                .monospacedDigit()
                .foregroundStyle(isToday ? Color.white : Editorial.ink)
                .frame(minWidth: Self.numberSize, minHeight: Self.numberSize)
                .background {
                    if isToday { Circle().fill(Editorial.accent) }
                }
            // Calendar.app convention: the 1st names its month, so the
            // adjacent-month days read unambiguously.
            if number == 1 {
                Text(AgendaFormat.shortMonth.string(from: day).replacingOccurrences(of: ".", with: ""))
                    .font(Editorial.sans(11, .medium))
                    .foregroundStyle(Editorial.inkMute)
            }
        }
    }

    /// The dots' separating ring matches the tile, so overlaps read as
    /// stacked discs rather than merged blobs.
    private var ringColor: Color {
        if isSelected || isToday || !inMonth { return Editorial.paper }
        return Editorial.page
    }

    /// Adjacent-month days have no tile, so the month's own shape reads
    /// without any border; selection and today tint the tile instead.
    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Editorial.accentSoft) }
        if isToday { return AnyShapeStyle(Editorial.accent.opacity(0.07)) }
        if hovering { return AnyShapeStyle(Editorial.ink.opacity(inMonth ? 0.05 : 0.03)) }
        return AnyShapeStyle(inMonth ? Editorial.page : .clear)
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

/// One event as a small raised disc in its Google colour, carrying the
/// title's first letter, with a ring in the tile colour that separates it
/// from the disc beneath.
private struct AgendaEventDot: View {
    let event: CalendarEvent
    let ring: Color
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(Color(statusHex: event.colorHex))
            .overlay {
                Circle().fill(LinearGradient(colors: [.white.opacity(0.28), .clear],
                                             startPoint: .top, endPoint: .center))
            }
            .overlay {
                Text(event.monogram)
                    .font(.system(size: size * 0.56, weight: .bold, design: .rounded))
                    .foregroundStyle(event.prefersDarkInk ? Color.black.opacity(0.72) : .white)
            }
            .frame(width: size, height: size)
            .padding(1.5)
            .background(Circle().fill(ring))
            .shadow(color: .black.opacity(0.16), radius: 0.8, y: 0.6)
            .accessibilityHidden(true)
    }
}

/// Neutral disc closing a full tile: how many events did not fit.
private struct AgendaMoreDot: View {
    let count: Int
    let ring: Color
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(Editorial.inkSoft)
            .overlay {
                Text("+\(count)")
                    .font(.system(size: count > 9 ? size * 0.42 : size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Editorial.page)
                    .minimumScaleFactor(0.6)
            }
            .frame(width: size, height: size)
            .padding(1.5)
            .background(Circle().fill(ring))
            .shadow(color: .black.opacity(0.16), radius: 0.8, y: 0.6)
    }
}

/// Single-row stack of discs, left to right, each overlapping the next.
/// The overlap grows with the event count so the row never leaves the tile.
private struct AgendaDotStack: Layout {
    /// Overlap between neighbours when there is room — small enough that
    /// every letter stays readable.
    var preferredOverlap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let first = subviews.first?.sizeThatFits(.unspecified) else { return .zero }
        let width = first.width + step(for: subviews.count, disc: first.width,
                                       width: proposal.width) * CGFloat(subviews.count - 1)
        return CGSize(width: min(width, proposal.width ?? width), height: first.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first?.sizeThatFits(.unspecified) else { return }
        let step = step(for: subviews.count, disc: first.width, width: bounds.width)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(index) * step, y: bounds.minY),
                          proposal: .unspecified)
        }
    }

    /// The preferred step, tighter when the row would not fit otherwise.
    private func step(for count: Int, disc: CGFloat, width: CGFloat?) -> CGFloat {
        let preferred = disc - preferredOverlap
        guard count > 1, let width, width.isFinite else { return preferred }
        return max(1, min(preferred, (width - disc) / CGFloat(count - 1)))
    }
}

private struct AgendaDayEventRow: View {
    let event: CalendarEvent
    let onOpen: (CalendarEvent) -> Void
    @State private var hovering = false

    private var detail: String {
        let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return AgendaFormat.timeRange(event) + (location.isEmpty ? "" : " · " + location)
    }

    var body: some View {
        Button { onOpen(event) } label: {
            HStack(alignment: .center, spacing: 10) {
                AgendaEventDot(event: event, ring: .clear, size: 22)
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
    /// Filled surface, same language as the day tiles: no border.
    func agendaSurface() -> some View {
        background(Editorial.page, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The day selected in the grid: its date and its events, each opening
/// its detail.
private struct AgendaDayPanel: View {
    let day: Date
    let calendar: Calendar
    let events: [CalendarEvent]
    let onOpen: (CalendarEvent) -> Void

    private static let title = AgendaFormat.formatter("EEEE, d 'de' MMMM")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Folio(AgendaFormat.capitalized(Self.title.string(from: day)))
                Spacer(minLength: 8)
                Text(relative)
                    .font(Editorial.sans(11, .medium))
                    .foregroundStyle(Editorial.inkMute)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            eventList
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .agendaSurface()
        .animation(.spring(duration: 0.3, bounce: 0.12), value: day)
    }

    /// "Hoje", "Amanhã", "Ontem", "Em 5 dias", "Há 3 dias".
    private var relative: String {
        let today = calendar.startOfDay(for: Date())
        let offset = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        switch offset {
        case 0: return "Hoje"
        case 1: return "Amanhã"
        case -1: return "Ontem"
        case let n where n > 1: return "Em \(n) dias"
        default: return "Há \(-offset) dias"
        }
    }

    // MARK: Events

    @ViewBuilder private var eventList: some View {
        if events.isEmpty {
            Text("Nenhum compromisso neste dia.")
                .font(Editorial.sans(12, .medium))
                .foregroundStyle(Editorial.inkSoft)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(events, id: \.calendarIdentity) { event in
                        AgendaDayEventRow(event: event, onOpen: onOpen)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.never)
            .id(day)
            .transition(.opacity)
        }
    }
}
