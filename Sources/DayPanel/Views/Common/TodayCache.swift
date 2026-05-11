import Foundation

// `Calendar.current.startOfDay(for: Date())` is cheap on its own, but
// task rows call it inside their badge / due-date computations on every
// render — and during scroll that's hundreds of calls per frame. This
// shared cache materialises "today" once per real-world day.

enum TodayCache {
    static let calendar: Calendar = .current

    private static var cachedDay: Date = calendar.startOfDay(for: Date())
    private static var cachedAt:  TimeInterval = Date().timeIntervalSince1970

    /// startOfDay for "today" — refreshes lazily when more than 5 minutes
    /// have passed since the last read (so the value rolls over after
    /// midnight without us setting up a Timer).
    static var startOfToday: Date {
        let now = Date().timeIntervalSince1970
        if now - cachedAt > 300 {
            let fresh = calendar.startOfDay(for: Date(timeIntervalSince1970: now))
            cachedDay = fresh
            cachedAt  = now
        }
        return cachedDay
    }
}
