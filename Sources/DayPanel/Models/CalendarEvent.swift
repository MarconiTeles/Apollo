import Foundation

struct CalendarEvent: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var startDate: Date
    var endDate: Date
    var colorHex: String
    var calendarId: String
    var isAllDay: Bool

    // Rich details (populated by EventKit when available)
    var location:       String?
    var notes:          String?
    var meetingURL:     URL?
    var attendees:      [Attendee] = []
    var organizerName:  String?
    var alarmOffsets:   [TimeInterval] = []   // negative seconds before start
    var calendarName:   String?

    struct Attendee: Codable, Equatable, Hashable {
        let name:        String
        let email:       String?
        let status:      Status
        let isOrganizer: Bool
        /// True when EventKit's `EKParticipant.isCurrentUser`
        /// returned true for this row — i.e. this row IS the
        /// user themselves on their own calendar. The agent
        /// uses this to answer "fulano e eu temos reunião?"
        /// without needing to know the user's calendar email.
        var isCurrentUser: Bool = false

        enum Status: String, Codable {
            case accepted, declined, tentative, pending, unknown
        }
    }

    /// Friendly "Por <name>" suffix for notification bodies. Falls
    /// back to nil when there's no organizer name (e.g. solo events
    /// you created yourself, or EventKit didn't surface one) so
    /// callers can omit the trailing separator cleanly.
    var organizerSuffix: String? {
        guard let raw = organizerName else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return "Por \(name)"
    }

    static let googleColorMap: [String: String] = [
        "1": "#7986CB", "2": "#33B679", "3": "#8E24AA",
        "4": "#E67C73", "5": "#F6BF26", "6": "#F4511E",
        "7": "#039BE5", "8": "#616161", "9": "#3F51B5",
        "10": "#0B8043", "11": "#D50000"
    ]

    static func mock() -> [CalendarEvent] {
        let cal = Calendar.current
        let today = Date()
        func at(_ h: Int, _ m: Int = 0) -> Date {
            cal.date(bySettingHour: h, minute: m, second: 0, of: today)!
        }
        return [
            CalendarEvent(id: "m1", title: "Daily Standup",        startDate: at(9),    endDate: at(9, 30),  colorHex: "#039BE5", calendarId: "primary", isAllDay: false),
            CalendarEvent(id: "m2", title: "Revisão de Design",    startDate: at(11),   endDate: at(12),     colorHex: "#33B679", calendarId: "primary", isAllDay: false),
            CalendarEvent(id: "m3", title: "Almoço com equipe",    startDate: at(12),   endDate: at(13, 30), colorHex: "#F6BF26", calendarId: "primary", isAllDay: false),
            CalendarEvent(id: "m4", title: "Sprint Planning",      startDate: at(14),   endDate: at(15, 30), colorHex: "#8E24AA", calendarId: "primary", isAllDay: false),
            CalendarEvent(id: "m5", title: "1:1 com manager",      startDate: at(16),   endDate: at(16, 30), colorHex: "#E67C73", calendarId: "primary", isAllDay: false),
        ]
    }
}
