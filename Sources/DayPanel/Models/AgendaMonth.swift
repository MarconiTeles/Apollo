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

enum AgendaLayout {
    static func timelineWidth(_ width: CGFloat) -> CGFloat { min(440, width * 0.43) }
}
