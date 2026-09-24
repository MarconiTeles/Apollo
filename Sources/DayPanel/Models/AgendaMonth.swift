import Foundation

/// Calendar arithmetic is independent of the UI and uses calendar days, not
/// 24-hour offsets, so DST and exclusive all-day end dates remain correct.
struct AgendaMonth {
    let calendar: Calendar
    let start: Date
    let days: [Date]
    let interval: DateInterval

    init(containing date: Date, calendar: Calendar = .current) {
        var calendar = calendar
        calendar.firstWeekday = 2 // Monday, matching the Agenda layout.
        self.calendar = calendar
        let month = calendar.dateInterval(of: .month, for: date)!
        start = month.start
        let offset = (calendar.component(.weekday, from: month.start) + 5) % 7
        let first = calendar.date(byAdding: .day, value: -offset, to: month.start)!
        let count = calendar.range(of: .day, in: .month, for: date)!.count
        let cellCount = ((offset + count + 6) / 7) * 7
        days = (0..<cellCount).map { calendar.date(byAdding: .day, value: $0, to: first)! }
        interval = DateInterval(start: first,
                                end: calendar.date(byAdding: .day, value: cellCount, to: first)!)
    }

    /// "Setembro de 2026" — shared by the header label and accessibility.
    var title: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.calendar = calendar
        formatter.dateFormat = "MMMM 'de' yyyy"
        let title = formatter.string(from: start)
        return title.prefix(1).uppercased() + title.dropFirst()
    }

    /// First day of the month `value` months away.
    func shifted(by value: Int) -> Date {
        calendar.date(byAdding: .month, value: value, to: start)!
    }

    func eventsByDay(_ events: [CalendarEvent]) -> [Date: [CalendarEvent]] {
        let sorted = events.sorted {
            if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        return Dictionary(uniqueKeysWithValues: days.map { day in
            let end = calendar.date(byAdding: .day, value: 1, to: day)!
            return (day, sorted.filter { event in
                event.startDate < end && (event.endDate > day ||
                    (event.endDate == event.startDate && event.startDate >= day))
            })
        })
    }
}

/// Month digest shown below the grid. Only days of the displayed month
/// count; the adjacent-month days that pad the grid are ignored.
struct AgendaMonthSummary: Equatable {
    struct DayCount: Equatable { let day: Date; let count: Int; let minutes: Int }
    struct FreeStretch: Equatable { let start: Date; let end: Date; let days: Int }

    let eventCount: Int
    let busyDays: Int
    let scheduledMinutes: Int
    /// Empty Monday–Friday days (from today on in the current month).
    let freeWeekdays: Int
    let busiestDay: DayCount?
    /// Longest run of empty days still ahead: from today in the current
    /// month, the whole month in the future, nil for past months.
    let freeStretch: FreeStretch?
    let allDayEvents: [CalendarEvent]
    /// Days left including today; nil outside the current month.
    let daysLeft: Int?
}

extension AgendaMonth {
    var monthDays: [Date] {
        days.filter { calendar.isDate($0, equalTo: start, toGranularity: .month) }
    }

    func summary(_ index: [Date: [CalendarEvent]], now: Date = Date()) -> AgendaMonthSummary {
        let monthDays = monthDays
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: start)!
        var unique: [String: CalendarEvent] = [:]
        var busiest: AgendaMonthSummary.DayCount?
        for day in monthDays {
            let events = index[day] ?? []
            for event in events { unique[event.calendarId + "|" + event.id] = event }
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: day)!
            let minutes = events.filter { !$0.isAllDay }.reduce(0) {
                $0 + Self.minutes($1, clippedTo: day, dayEnd)
            }
            if !events.isEmpty, events.count > (busiest?.count ?? 0) {
                busiest = .init(day: day, count: events.count, minutes: minutes)
            }
        }
        let scheduled = unique.values.filter { !$0.isAllDay }.reduce(0) {
            $0 + Self.minutes($1, clippedTo: start, monthEnd)
        }
        let empty = { (day: Date) in (index[day] ?? []).isEmpty }
        let today = calendar.startOfDay(for: now)
        let isCurrent = calendar.isDate(now, equalTo: start, toGranularity: .month)
        let horizon = isCurrent ? monthDays.filter { $0 >= today } : (today < start ? monthDays : [])

        var stretch: AgendaMonthSummary.FreeStretch?
        var runStart: Date?
        var runLength = 0
        for (offset, day) in horizon.enumerated() {
            if empty(day) {
                if runStart == nil { runStart = day; runLength = 0 }
                runLength += 1
            }
            let closes = !empty(day) || offset == horizon.count - 1
            if closes, let begin = runStart {
                if runLength > (stretch?.days ?? 0) {
                    stretch = .init(start: begin,
                                    end: calendar.date(byAdding: .day, value: runLength - 1, to: begin)!,
                                    days: runLength)
                }
                runStart = nil
            }
        }

        return AgendaMonthSummary(
            eventCount: unique.count,
            busyDays: monthDays.filter { !empty($0) }.count,
            scheduledMinutes: scheduled,
            freeWeekdays: (isCurrent ? horizon : monthDays)
                .filter { !calendar.isDateInWeekend($0) && empty($0) }.count,
            busiestDay: busiest,
            freeStretch: stretch.flatMap { $0.days >= 2 ? $0 : nil },
            allDayEvents: unique.values.filter(\.isAllDay).sorted { $0.startDate < $1.startDate },
            daysLeft: isCurrent ? horizon.count : nil
        )
    }

    private static func minutes(_ event: CalendarEvent, clippedTo lower: Date, _ upper: Date) -> Int {
        let begin = max(event.startDate, lower)
        let end = min(event.endDate, upper)
        return end > begin ? Int(end.timeIntervalSince(begin) / 60) : 0
    }
}

enum AgendaLayout {
    static func timelineWidth(_ width: CGFloat) -> CGFloat { min(440, width * 0.43) }
}
