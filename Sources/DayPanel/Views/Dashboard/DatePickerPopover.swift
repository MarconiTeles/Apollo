import SwiftUI

// Rich date picker popover modeled after ClickUp's date picker:
//   - Tabs to switch between "Início" and "Vencimento"
//   - Quick shortcuts (Hoje, Amanhã, Semana que vem, 2/4/8 semanas…)
//   - Graphical calendar
//   - Compact time picker
//   - Limpar / Aplicar actions
//
// Both date fields edit-able from the same popover; only the changed ones
// are committed to ClickUp.

struct UnifiedDatePickerPopover: View {
    enum Mode { case start, due }

    let task: CUTask
    let initialMode: Mode
    let onCommit: (Mode, Date?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode
    @State private var startDraft:  Date
    @State private var startOn:     Bool
    @State private var dueDraft:    Date
    @State private var dueOn:       Bool

    init(task: CUTask, initialMode: Mode, onCommit: @escaping (Mode, Date?) -> Void) {
        self.task        = task
        self.initialMode = initialMode
        self.onCommit    = onCommit
        _mode       = State(initialValue: initialMode)
        _startDraft = State(initialValue: task.startDate ?? Self.defaultStart())
        _startOn    = State(initialValue: task.startDate != nil)
        _dueDraft   = State(initialValue: task.dueDate   ?? Self.defaultDue())
        _dueOn      = State(initialValue: task.dueDate != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabs
            Rectangle().fill(Editorial.rule).frame(height: 1)

            HStack(spacing: 0) {
                shortcutsColumn.frame(width: 180)
                Rectangle().fill(Editorial.rule).frame(width: 1)
                calendarColumn
            }

            Rectangle().fill(Editorial.rule).frame(height: 1)
            actions
        }
        .frame(width: 500)
        .fixedSize(horizontal: true, vertical: true)
        .background(Editorial.paper)
    }

    // MARK: - Tabs

    private var tabs: some View {
        HStack(spacing: 20) {
            editorialDateTab(title: "Data inicial",       isActive: mode == .start, isOn: startOn) { mode = .start }
            editorialDateTab(title: "Data de vencimento", isActive: mode == .due,   isOn: dueOn)   { mode = .due }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    // MARK: - Shortcuts

    private var shortcutsColumn: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Shortcut.allCases) { sc in
                    Button {
                        applyShortcut(sc)
                    } label: {
                        HStack {
                            Text(sc.label)
                                .font(Editorial.serif(14))
                                .foregroundStyle(Editorial.ink)
                            Spacer()
                            Text(sc.dayLabel)
                                .font(Editorial.sans(11))
                                .foregroundStyle(Editorial.inkMute)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()

                    if sc != .eightWeeks {
                        Rectangle().fill(Editorial.ruleSoft).frame(height: 1)
                            .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func applyShortcut(_ sc: Shortcut) {
        let date = sc.date()
        if mode == .start { startDraft = date; startOn = true }
        else              { dueDraft   = date; dueOn   = true }
    }

    // MARK: - Calendar + time

    private var calendarColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Toggle("", isOn: currentEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(Editorial.accent)
                Text(currentEnabled.wrappedValue
                     ? currentDate.wrappedValue.formatted(.dateTime.day().month(.wide).year())
                     : "Sem data")
                    .font(Editorial.serif(15))
                    .foregroundStyle(currentEnabled.wrappedValue ? Editorial.ink : Editorial.inkMute)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Rectangle().fill(Editorial.rule).frame(height: 1)

            ClickUpStyleCalendar(date: currentDate, isEnabled: currentEnabled.wrappedValue)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Rectangle().fill(Editorial.rule).frame(height: 1)

            HStack {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(Editorial.inkMute)
                Text("Horário")
                    .font(Editorial.sans(10.5, .semibold))
                    .tracking(1.1)
                    .foregroundStyle(Editorial.inkMute)
                Spacer()
                DatePicker("", selection: currentDate, displayedComponents: [.hourAndMinute])
                    .labelsHidden()
                    .disabled(!currentEnabled.wrappedValue)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 300)
    }

    private var currentDate: Binding<Date> {
        Binding(
            get: { mode == .start ? startDraft : dueDraft },
            set: { new in if mode == .start { startDraft = new } else { dueDraft = new } }
        )
    }

    private var currentEnabled: Binding<Bool> {
        Binding(
            get: { mode == .start ? startOn : dueOn },
            set: { new in if mode == .start { startOn = new } else { dueOn = new } }
        )
    }

    // MARK: - Actions

    private var actions: some View {
        HStack {
            Button("Limpar") {
                if mode == .start { startOn = false } else { dueOn = false }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .font(Editorial.sans(12, .medium))
            .foregroundStyle(Editorial.accent)

            Spacer()

            Button {
                let newStart: Date? = startOn ? startDraft : nil
                let newDue:   Date? = dueOn   ? dueDraft   : nil
                if newStart != task.startDate { onCommit(.start, newStart) }
                if newDue   != task.dueDate   { onCommit(.due,   newDue) }
                dismiss()
            } label: {
                Text("Aplicar")
                    .font(Editorial.sans(12.5, .medium))
                    .foregroundStyle(Editorial.page)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Editorial.ink,
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Defaults

    private static func defaultStart() -> Date {
        let cal = Calendar.current
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    }

    private static func defaultDue() -> Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return cal.date(bySettingHour: 17, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}

// MARK: - Event variant (start + end, both required)
//
// Same look-and-feel as `UnifiedDatePickerPopover`, but adapted for
// CreateEventSheet — both dates are always present, the tabs are
// "Início" / "Fim", and end is auto-bumped to remain after start.

struct EventDatePickerPopover: View {
    enum Mode { case start, end }

    @Binding var startDate: Date
    @Binding var endDate:   Date
    let initialMode: Mode

    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode
    @State private var startDraft: Date
    @State private var endDraft:   Date

    init(startDate: Binding<Date>, endDate: Binding<Date>, initialMode: Mode = .start) {
        _startDate       = startDate
        _endDate         = endDate
        self.initialMode = initialMode
        _mode            = State(initialValue: initialMode)
        _startDraft      = State(initialValue: startDate.wrappedValue)
        _endDraft        = State(initialValue: endDate.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabs
            Rectangle().fill(Editorial.rule).frame(height: 1)
            HStack(spacing: 0) {
                shortcutsColumn.frame(width: 180)
                Rectangle().fill(Editorial.rule).frame(width: 1)
                calendarColumn
            }
            Rectangle().fill(Editorial.rule).frame(height: 1)
            actions
        }
        .frame(width: 500)
        .fixedSize(horizontal: true, vertical: true)
        .background(Editorial.paper)
    }

    // MARK: Tabs

    private var tabs: some View {
        HStack(spacing: 20) {
            editorialDateTab(title: "Início", isActive: mode == .start, isOn: true) { mode = .start }
            editorialDateTab(title: "Fim",    isActive: mode == .end,   isOn: true) { mode = .end }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    // MARK: Shortcuts

    private var shortcutsColumn: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Shortcut.allCases) { sc in
                    Button { applyShortcut(sc) } label: {
                        HStack {
                            Text(sc.label)
                                .font(Editorial.serif(14))
                                .foregroundStyle(Editorial.ink)
                            Spacer()
                            Text(sc.dayLabel)
                                .font(Editorial.sans(11))
                                .foregroundStyle(Editorial.inkMute)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).focusEffectDisabled()

                    if sc != .eightWeeks {
                        Rectangle().fill(Editorial.ruleSoft).frame(height: 1)
                            .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func applyShortcut(_ sc: Shortcut) {
        let target = sc.date()
        if mode == .start {
            let dur = max(60, endDraft.timeIntervalSince(startDraft))   // preserve duration
            startDraft = target
            endDraft   = target.addingTimeInterval(dur)
        } else {
            endDraft = max(target, startDraft.addingTimeInterval(60))
        }
    }

    // MARK: Calendar + time

    private var calendarColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(currentDate.wrappedValue
                     .formatted(.dateTime.day().month(.wide).year()))
                    .font(Editorial.serif(15))
                    .foregroundStyle(Editorial.ink)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            Rectangle().fill(Editorial.rule).frame(height: 1)

            ClickUpStyleCalendar(date: currentDate, isEnabled: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Rectangle().fill(Editorial.rule).frame(height: 1)

            HStack {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(Editorial.inkMute)
                Text("Horário")
                    .font(Editorial.sans(10.5, .semibold))
                    .tracking(1.1)
                    .foregroundStyle(Editorial.inkMute)
                Spacer()
                DatePicker("", selection: currentDate, displayedComponents: [.hourAndMinute])
                    .labelsHidden()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(width: 300)
    }

    private var currentDate: Binding<Date> {
        Binding(
            get: { mode == .start ? startDraft : endDraft },
            set: { new in
                if mode == .start {
                    let dur = max(60, endDraft.timeIntervalSince(startDraft))
                    startDraft = new
                    endDraft   = new.addingTimeInterval(dur)
                } else {
                    endDraft = max(new, startDraft.addingTimeInterval(60))
                }
            }
        )
    }

    // MARK: Actions

    private var actions: some View {
        HStack {
            Spacer()
            Button {
                startDate = startDraft
                endDate   = endDraft
                dismiss()
            } label: {
                Text("Aplicar")
                    .font(Editorial.sans(12.5, .medium))
                    .foregroundStyle(Editorial.page)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Editorial.ink,
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .buttonStyle(.plain).focusEffectDisabled()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

// MARK: - Editorial date tab

/// Shared tab control for the date/time popovers — prototype
/// `tabPT`: text-only, ink + 2px ink underline when active,
/// `inkSoft` when not. A small status dot (filled cinnabar when
/// the date is set, hollow ring otherwise) precedes the label.
private func editorialDateTab(
    title: String,
    isActive: Bool,
    isOn: Bool,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        HStack(spacing: 7) {
            Circle()
                .fill(isOn ? Editorial.accent : Color.clear)
                .frame(width: 6, height: 6)
                .overlay(
                    Circle().strokeBorder(
                        isOn ? Color.clear : Editorial.inkFaint,
                        lineWidth: 1.5
                    )
                )
            Text(title)
                .font(Editorial.sans(12.5, isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Editorial.ink : Editorial.inkSoft)
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isActive ? Editorial.ink : Color.clear)
                .frame(height: 2)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusEffectDisabled()
}

// MARK: - Shortcut definitions

private enum Shortcut: String, CaseIterable, Identifiable {
    case today, later, tomorrow, nextWeek, nextWeekend, twoWeeks, fourWeeks, eightWeeks

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today:       return "Hoje"
        case .later:       return "Mais tarde"
        case .tomorrow:    return "Amanhã"
        case .nextWeek:    return "Semana que vem"
        case .nextWeekend: return "Próximo fim de semana"
        case .twoWeeks:    return "2 semanas"
        case .fourWeeks:   return "4 semanas"
        case .eightWeeks:  return "8 semanas"
        }
    }

    var dayLabel: String {
        let d = date()
        switch self {
        case .today, .tomorrow, .nextWeek, .nextWeekend:
            return d.formatted(.dateTime.weekday(.abbreviated))
        case .later:
            return d.formatted(date: .omitted, time: .shortened)
        case .twoWeeks, .fourWeeks, .eightWeeks:
            return d.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    func date() -> Date {
        let cal = Calendar.current
        let now = Date()
        func at(_ hour: Int, _ d: Date) -> Date {
            cal.date(bySettingHour: hour, minute: 0, second: 0, of: d) ?? d
        }
        switch self {
        case .today:        return at(17, now)
        case .later:        return now.addingTimeInterval(3 * 3600)
        case .tomorrow:     return at(9, cal.date(byAdding: .day, value: 1, to: now)!)
        case .nextWeek:     return at(9, cal.nextWeekday(2, after: now))         // 2 = Monday
        case .nextWeekend:  return at(9, cal.nextWeekday(7, after: now))         // 7 = Saturday
        case .twoWeeks:     return at(9, cal.date(byAdding: .day, value: 14, to: now)!)
        case .fourWeeks:    return at(9, cal.date(byAdding: .day, value: 28, to: now)!)
        case .eightWeeks:   return at(9, cal.date(byAdding: .day, value: 56, to: now)!)
        }
    }
}

private extension Calendar {
    /// Returns the next occurrence of the given weekday (1=Sun … 7=Sat) strictly after `date`.
    func nextWeekday(_ target: Int, after date: Date) -> Date {
        let current = component(.weekday, from: date)
        var diff = (target - current + 7) % 7
        if diff == 0 { diff = 7 }
        return self.date(byAdding: .day, value: diff, to: startOfDay(for: date))!
    }
}

// MARK: - ClickUp-style calendar grid

struct ClickUpStyleCalendar: View {
    @Binding var date: Date
    let isEnabled: Bool

    @State private var displayMonth: Date = Date()

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 1   // Sunday — matches the hardcoded weekday labels below
        return c
    }
    private let weekdayLabels = ["dom", "2ª", "3ª", "4ª", "5ª", "6ª", "sáb"]

    var body: some View {
        VStack(spacing: 14) {
            header
            grid
        }
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled)
        .onAppear { syncDisplayMonth() }
        .onChange(of: date) { _, _ in syncDisplayMonth() }
    }

    private func syncDisplayMonth() {
        if !cal.isDate(date, equalTo: displayMonth, toGranularity: .month) {
            displayMonth = date
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Text(displayMonth.formatted(.dateTime.month(.wide).year()))
                .font(Editorial.serif(16))
                .foregroundStyle(Editorial.ink)
            Spacer()
            Button { goToToday() } label: {
                Text("Hoje")
                    .font(Editorial.sans(11, .medium))
                    .foregroundStyle(Editorial.inkSoft)
                    .padding(.horizontal, 8).frame(height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).focusEffectDisabled()
            navButton(systemImage: "chevron.up")   { changeMonth(-1) }
            navButton(systemImage: "chevron.down") { changeMonth(+1) }
        }
    }

    private func navButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Editorial.inkMute)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusEffectDisabled()
    }

    // MARK: Grid

    private var grid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(weekdayLabels, id: \.self) { label in
                Text(label)
                    .font(Editorial.sans(10, .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Editorial.inkMute)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 4)
            }
            ForEach(visibleDays, id: \.self) { dayDate in
                dayCell(dayDate)
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ d: Date) -> some View {
        let dayNum         = cal.component(.day, from: d)
        let isCurrentMonth = cal.isDate(d, equalTo: displayMonth, toGranularity: .month)
        let isToday        = cal.isDateInToday(d)
        let isSelected     = cal.isDate(d, inSameDayAs: date)
        let isPast         = cal.startOfDay(for: d) < cal.startOfDay(for: Date())

        Button { select(d) } label: {
            Text("\(dayNum)")
                .font(Editorial.sans(13, isSelected || isToday ? .semibold : .regular))
                .foregroundStyle(textColor(selected: isSelected, today: isToday, currentMonth: isCurrentMonth, past: isPast))
                .frame(width: 28, height: 28)
                .background {
                    if isSelected {
                        Circle().fill(Editorial.accent)
                    } else if isToday {
                        Circle().strokeBorder(Editorial.accent, lineWidth: 1.5)
                    }
                }
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain).focusEffectDisabled()
    }

    private func textColor(selected: Bool, today: Bool, currentMonth: Bool, past: Bool) -> Color {
        if selected      { return Editorial.page }
        if !currentMonth { return Editorial.inkFaint }
        if today         { return Editorial.accent }
        if past          { return Editorial.inkMute }
        return Editorial.ink
    }

    // MARK: Computations

    private var visibleDays: [Date] {
        guard let monthStart = cal.dateInterval(of: .month, for: displayMonth)?.start else { return [] }
        let firstWeekday = cal.component(.weekday, from: monthStart)   // 1 = Sunday
        let leading = (firstWeekday - cal.firstWeekday + 7) % 7
        let gridStart = cal.date(byAdding: .day, value: -leading, to: monthStart)!
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private func changeMonth(_ offset: Int) {
        if let new = cal.date(byAdding: .month, value: offset, to: displayMonth) {
            withAnimation(.easeInOut(duration: 0.18)) { displayMonth = new }
        }
    }

    private func goToToday() {
        let now = Date()
        withAnimation(.easeInOut(duration: 0.18)) { displayMonth = now }
        select(now)
    }

    private func select(_ d: Date) {
        var comps = cal.dateComponents([.hour, .minute], from: date)
        let dayComps = cal.dateComponents([.year, .month, .day], from: d)
        comps.year  = dayComps.year
        comps.month = dayComps.month
        comps.day   = dayComps.day
        if let newDate = cal.date(from: comps) { date = newDate }
    }
}
