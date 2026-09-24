import XCTest
@testable import ApolloRuntime

final class AgendaMonthTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
    private func event(_ start: Date, _ end: Date, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: "event-\(Int(start.timeIntervalSince1970))", title: "Evento", startDate: start, endDate: end,
                      colorHex: "#039BE5", calendarId: "primary", isAllDay: allDay)
    }
    func testSameMeetingInSharedCalendarsKeepsBothCopiesWithDistinctUIIdentity() {
        let original = event(date(2026, 9, 24, 9), date(2026, 9, 24, 10))
        var shared = original
        shared.calendarId = "coworker@example.com"
        shared.colorHex = "#33B679"
        let model = AgendaMonth(containing: original.startDate, calendar: calendar)
        let copies = model.eventsByDay([original, shared])[date(2026, 9, 24)]!
        XCTAssertEqual(copies.count, 2)
        XCTAssertEqual(Set(copies.map(\.calendarIdentity)).count, 2)
        // The original Google ID must still be sent to event mutation APIs.
        XCTAssertEqual(shared.id, original.id)
    }
    func testMonthGridIncludesLeadingAndTrailingDays() {
        let m = AgendaMonth(containing: date(2026, 9, 23), calendar: calendar)
        XCTAssertEqual(m.days.count, 35)
        XCTAssertEqual(m.days.first, date(2026, 8, 31))
        XCTAssertEqual(m.days.last, date(2026, 10, 4))
        XCTAssertEqual(m.interval.end, date(2026, 10, 5))
    }
    func testSixWeekMonthLeapYearAndYearBoundary() {
        XCTAssertEqual(AgendaMonth(containing: date(2026, 8, 1), calendar: calendar).days.count, 42)
        let leap = AgendaMonth(containing: date(2024, 2, 1), calendar: calendar)
        XCTAssertTrue(leap.days.contains(date(2024, 2, 29)))
        let january = AgendaMonth(containing: date(2027, 1, 1), calendar: calendar)
        XCTAssertEqual(january.days.first, date(2026, 12, 28))
    }
    func testAllDayExclusiveEndAndTimedOvernight() {
        let m = AgendaMonth(containing: date(2026, 9, 1), calendar: calendar)
        let allDay = m.eventsByDay([event(date(2026, 9, 3), date(2026, 9, 5), allDay: true)])
        XCTAssertEqual(allDay[date(2026, 9, 3)]?.count, 1)
        XCTAssertEqual(allDay[date(2026, 9, 4)]?.count, 1)
        XCTAssertEqual(allDay[date(2026, 9, 5)]?.count, 0)
        let overnight = m.eventsByDay([event(date(2026, 9, 3, 23), date(2026, 9, 4, 1))])
        XCTAssertEqual(overnight[date(2026, 9, 3)]?.count, 1)
        XCTAssertEqual(overnight[date(2026, 9, 4)]?.count, 1)
    }
    func testDSTDoesNotDuplicateOrSkipCalendarDays() {
        let m = AgendaMonth(containing: date(2026, 3, 8), calendar: calendar)
        XCTAssertEqual(Set(m.days).count, m.days.count)
        XCTAssertTrue(m.days.allSatisfy { calendar.component(.hour, from: $0) == 0 })
        let index = m.eventsByDay([event(date(2026, 3, 8), date(2026, 3, 9), allDay: true)])
        XCTAssertEqual(index[date(2026, 3, 8)]?.count, 1)
        XCTAssertEqual(index[date(2026, 3, 9)]?.count, 0)
    }
    func testEventsSortedWithAllDayFirstAndInstantEventsIncluded() {
        let m = AgendaMonth(containing: date(2026, 9, 1), calendar: calendar)
        let timed = event(date(2026, 9, 3, 10), date(2026, 9, 3, 11))
        let instant = event(date(2026, 9, 3, 9), date(2026, 9, 3, 9))
        let allDay = event(date(2026, 9, 3), date(2026, 9, 4), allDay: true)
        XCTAssertEqual(m.eventsByDay([timed, allDay, instant])[date(2026, 9, 3)], [allDay, instant, timed])
    }
    func testTitleAndMonthShiftAcrossYearBoundary() {
        let december = AgendaMonth(containing: date(2026, 12, 31, 18), calendar: calendar)
        XCTAssertEqual(december.title, "Dezembro de 2026")
        XCTAssertEqual(december.shifted(by: 1), date(2027, 1, 1))
        XCTAssertEqual(AgendaMonth(containing: date(2027, 1, 15), calendar: calendar).shifted(by: -1),
                       date(2026, 12, 1))
    }
    func testSummaryCountsOnlyDisplayedMonthAndLooksAhead() {
        let m = AgendaMonth(containing: date(2026, 9, 1), calendar: calendar)
        let events = [
            event(date(2026, 8, 31, 9), date(2026, 8, 31, 10)),          // padding day: ignored
            event(date(2026, 9, 23, 9, 30), date(2026, 9, 23, 10)),
            event(date(2026, 9, 23, 12), date(2026, 9, 23, 13)),
            event(date(2026, 9, 26), date(2026, 9, 28), allDay: true),   // Sat–Sun
        ]
        let summary = m.summary(m.eventsByDay(events), now: date(2026, 9, 23, 15))
        XCTAssertEqual(summary.eventCount, 3)
        XCTAssertEqual(summary.busyDays, 3)
        XCTAssertEqual(summary.scheduledMinutes, 90)
        XCTAssertEqual(summary.busiestDay, .init(day: date(2026, 9, 23), count: 2, minutes: 90))
        // From today: 24, 25 free; 26–27 busy; 28, 29, 30 free.
        XCTAssertEqual(summary.freeStretch, .init(start: date(2026, 9, 28), end: date(2026, 9, 30), days: 3))
        XCTAssertEqual(summary.freeWeekdays, 5)
        XCTAssertEqual(summary.daysLeft, 8)
        XCTAssertEqual(summary.allDayEvents.count, 1)
    }
    func testSummaryOfPastMonthHasNoLookAhead() {
        let m = AgendaMonth(containing: date(2026, 8, 1), calendar: calendar)
        let summary = m.summary([:], now: date(2026, 9, 23))
        XCTAssertEqual(summary.eventCount, 0)
        XCTAssertNil(summary.freeStretch)
        XCTAssertNil(summary.daysLeft)
        XCTAssertEqual(summary.freeWeekdays, 21)
    }
}
