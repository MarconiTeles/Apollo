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
    var body: some View {
        let model = AgendaMonth(containing: month)
        let index = model.eventsByDay(fetchedEvents ?? localEvents)
        GeometryReader { geometry in
            let rows = CGFloat(model.days.count / 7)
            let cellHeight = max(80, (geometry.size.height - topInset - 34 - rows * 4 - (error == nil ? 0 : 40)) / rows)
            VStack(spacing: 12) {
                if let error {
                    HStack(spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(Editorial.inkSoft)
                        Spacer(minLength: 0)
                        Button("Tentar novamente") { revision += 1 }
                            .buttonStyle(.glass).buttonBorderShape(.capsule)
                    }
                }
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                        ForEach(["SEG", "TER", "QUA", "QUI", "SEX", "SÁB", "DOM"], id: \.self) { day in
                            Text(day).font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Editorial.inkMute)
                                .frame(maxWidth: .infinity).padding(.bottom, 4)
                        }
                        ForEach(model.days, id: \.self) { day in
                            dayCell(day, model: model, events: index[day] ?? [], visibleLimit: cellHeight >= 106 ? 2 : 1)
                                .frame(height: cellHeight)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, topInset)
            .padding(.bottom, 16)
        }
        .background(Editorial.paper)
        .overlay(alignment: .bottomTrailing) {
            if loading { ProgressView().controlSize(.small).padding(8) }
        }
        .task(id: request) { await loadMonth(model) }
        .onChange(of: appState.isSyncing) { old, new in
            if old && !new { revision += 1 }
        }
        .onChange(of: appState.events) { _, _ in revision += 1 }
        .onChange(of: appState.sharedEvents) { _, _ in revision += 1 }
        .popover(item: $selectedDay) { selection in
            let events = index[selection.id] ?? []
            VStack(alignment: .leading, spacing: 12) {
                Text(selection.id.formatted(date: .complete, time: .omitted))
                    .font(.system(size: 14, weight: .semibold))
                if events.isEmpty {
                    Text("Sem compromissos").foregroundStyle(Editorial.inkSoft)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(events, id: \.calendarIdentity) { event in
                                Button { open(event) } label: {
                                    HStack(spacing: 8) {
                                        Circle().fill(Color(statusHex: event.colorHex)).frame(width: 6, height: 6)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(event.title).font(.system(size: 12, weight: .medium))
                                            Text(event.isAllDay ? "Dia inteiro" : event.startDate.formatted(date: .omitted, time: .shortened))
                                                .font(.system(size: 11)).foregroundStyle(Editorial.inkSoft)
                                        }
                                        Spacer(minLength: 0)
                                    }.padding(8).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(maxHeight: 300)
                }
            }.padding(18).frame(width: 320)
        }
    }

    private func dayCell(_ day: Date, model: AgendaMonth, events: [CalendarEvent], visibleLimit: Int) -> some View {
        let today = model.calendar.isDateInToday(day)
        let inMonth = model.calendar.isDate(day, equalTo: month, toGranularity: .month)
        return VStack(alignment: .leading, spacing: 4) {
            Button { selectedDay = DaySelection(id: day) } label: {
                Text("\(model.calendar.component(.day, from: day))")
                    .font(.system(size: 12, weight: today ? .bold : .medium))
                    .foregroundStyle(today ? Editorial.accent : (inMonth ? Editorial.ink : Editorial.inkMute))
                    .frame(width: 24, height: 24)
                    .background(today ? Editorial.accentSoft : .clear, in: Circle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
            ForEach(Array(events.prefix(visibleLimit)), id: \.calendarIdentity) { event in
                Button { open(event) } label: {
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 1).fill(Color(statusHex: event.colorHex)).frame(width: 2)
                        Text(event.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Editorial.ink)
                    .padding(.horizontal, 4).padding(.vertical, 4)
                    .background(Color(statusHex: event.colorHex).opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help(event.title + " · " + (event.isAllDay ? "Dia inteiro" : event.startDate.formatted(date: .omitted, time: .shortened)))
            }
            if events.count > visibleLimit {
                Button("+\(events.count - visibleLimit) \(events.count - visibleLimit == 1 ? "evento" : "eventos")") { selectedDay = DaySelection(id: day) }
                    .font(.system(size: 9)).foregroundStyle(Editorial.inkSoft).buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(inMonth ? Editorial.card : Editorial.paper, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(Editorial.ruleSoft, lineWidth: 0.5)
        }
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

/// Fixed header controls share the displayed month with the calendar grid.
struct AgendaMonthControls: View {
    @Binding var month: Date
    private static let monthFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "MMMM 'de' yyyy"
        return f
    }()

    private var monthTitle: String {
        let title = Self.monthFormat.string(from: month)
        return title.prefix(1).uppercased() + title.dropFirst()
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(monthTitle)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            Button("Hoje") { month = Date() }
                .buttonStyle(.glass).buttonBorderShape(.capsule)
            Button("Mês anterior", systemImage: "chevron.left") { moveMonth(-1) }
                .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
                .help("Mês anterior")
            Button("Próximo mês", systemImage: "chevron.right") { moveMonth(1) }
                .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
                .help("Próximo mês")
        }
    }

    private func moveMonth(_ value: Int) {
        month = Calendar.current.date(byAdding: .month, value: value,
                                      to: AgendaMonth(containing: month).start)!
    }

}
