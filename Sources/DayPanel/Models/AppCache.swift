import Foundation

struct AppCache: Codable {
    var events: [CalendarEvent]
    var tasks: [CUTask]
    var lastSyncedAt: Date
    /// Cross-workspace "atribuídas a mim" snapshot. Persisted so a
    /// COLD start (app freshly launched, in-memory cache empty)
    /// can paint the Tarefas view instantly from disk while the
    /// background refresh streams fresh pages on top. Defaults to
    /// `[]` on legacy caches that pre-date the field — decoding
    /// keeps working without a migration step.
    var assignedToMeTasks: [CUTask] = []

    static var empty: AppCache {
        AppCache(events: [], tasks: [], lastSyncedAt: .distantPast,
                 assignedToMeTasks: [])
    }
}
