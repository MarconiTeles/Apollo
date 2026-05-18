import Foundation

/// Apollo-native, per-task reminders.
///
/// ClickUp's public v2 API does NOT expose a readable
/// reminders endpoint for a personal token (`GET /reminder`
/// → 405, `/team/{id}/reminder` → 404), so mirroring the
/// user's ClickUp reminders is impossible. Instead Apollo
/// lets the user attach LOCAL reminders to a task: a one-shot
/// "ping me about this task at <time>" that fires through the
/// same notification path as the due-date/event reminders.
/// They are NOT synced back to ClickUp (there is no API for
/// it) — they live only on this device.
///
/// Storage: a JSON array under UserDefaults key
/// `dp_task_reminders_v1`. The task title is cached on the
/// entry so the notification (and the list row) can render
/// even if the task isn't currently loaded. One-shot: a fired
/// reminder is deleted, which doubles as the de-dupe.
enum TaskReminders {

    struct Entry: Codable, Hashable, Identifiable {
        let id: String          // UUID
        let taskId: String
        var taskTitle: String
        var fireAt: Date
        var note: String?
    }

    private static let key = "dp_task_reminders_v1"
    private static let cap = 200   // bounded; pathological safety valve

    static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return decoded
    }

    private static func save(_ entries: [Entry]) {
        if let data = try? JSONEncoder().encode(Array(entries.prefix(cap))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Reminders for one task, soonest first.
    static func forTask(_ taskId: String) -> [Entry] {
        load()
            .filter { $0.taskId == taskId }
            .sorted { $0.fireAt < $1.fireAt }
    }

    @discardableResult
    static func add(taskId: String,
                    title: String,
                    fireAt: Date,
                    note: String?) -> Entry {
        var entries = load()
        let e = Entry(id: UUID().uuidString,
                      taskId: taskId,
                      taskTitle: title,
                      fireAt: fireAt,
                      note: (note?.isEmpty == false) ? note : nil)
        entries.append(e)
        save(entries)
        return e
    }

    static func remove(id: String) {
        save(load().filter { $0.id != id })
    }

    /// Entries whose time has arrived. The caller fires each
    /// then calls `remove(id:)` — one-shot semantics, so the
    /// deletion is also what prevents a second fire.
    static func due(asOf now: Date) -> [Entry] {
        load().filter { $0.fireAt <= now }
    }
}
