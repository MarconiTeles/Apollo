import Foundation

struct AppCache: Codable {
    var events: [CalendarEvent]
    var tasks: [CUTask]
    var lastSyncedAt: Date

    static var empty: AppCache {
        AppCache(events: [], tasks: [], lastSyncedAt: .distantPast)
    }
}
