import Foundation
import Testing
@testable import ApolloRuntime

@MainActor
struct AgendaMonthProjectionTests {
    @Test func cacheTracksMetadataSourcesAndCalendar() throws {
        let cache = AgendaMonthProjectionCache()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24))!
        var event = CalendarEvent(id: "shared-id", title: "Original", startDate: day.addingTimeInterval(3600),
                                  endDate: day.addingTimeInterval(7200), colorHex: "#039BE5", calendarId: "primary", isAllDay: false)
        func value(_ primary: [CalendarEvent], shared: [String: [CalendarEvent]] = [:],
                   fetched: [CalendarEvent]? = nil) -> AgendaMonthProjectionCache.Projection {
            cache.resolve(month: day, calendar: calendar, primary: primary, shared: shared, fetched: fetched)
        }
        #expect(value([event]).index[day] == [event])
        event.notes = "Changed notes must reach the detail action"
        event.meetingURL = URL(string: "https://example.com/meeting")
        #expect(value([event]).index[day] == [event])
        var sharedEvent = event
        sharedEvent.calendarId = "person@example.com"
        #expect(value([event], shared: [sharedEvent.calendarId: [sharedEvent]]).index[day]?.count == 2)
        #expect(value([event], fetched: []).index[day]?.isEmpty == true)
        #expect(value([event]).index[day] == [event])
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        let changed = value([event])
        let localDay = calendar.startOfDay(for: event.startDate)
        #expect(changed.model.calendar.timeZone == calendar.timeZone)
        #expect(changed.index[localDay] == [event])
    }
}
