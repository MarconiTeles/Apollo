import Foundation

/// Centralised, lazily-initialised `DateFormatter` instances for
/// hot-path date rendering.
///
/// Why this exists: SwiftUI's `Date.formatted(.dateTime...)` is
/// convenient but builds a fresh `Date.FormatStyle` AND resolves
/// the user's locale on every call. Inside `TaskRowView` and the
/// AI chat pills that's hundreds of allocations per second
/// during scroll, all redundant. A shared `DateFormatter`
/// instance hits the same locale once and stays warm for the
/// life of the app.
///
/// Why `DateFormatter` instead of `Date.FormatStyle`: Foundation
/// has memoised `DateFormatter` since macOS 10.10 and benchmarks
/// faster on repeated formatting of similar dates than
/// FormatStyle (which re-resolves its template every call).
///
/// All formatters are single-instance per template — store as
/// `static let` so the cost is paid exactly once at first
/// access.
enum SharedDateFormatters {

    /// "29 abr.", "1 mai." — short day + abbreviated month, no
    /// "de" preposition. Explicit `d MMM` format (not the
    /// localized template, which injects "de" in pt_BR).
    static let shortDayMonthPTBR: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "d MMM"
        return f
    }()

    /// "09:30" — 24-hour HH:mm. Used by the AI chat's event pill
    /// time-range rendering and the timeline event tooltips.
    static let shortTime24h: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// "terça-feira, 29 de abril de 2026 às 09:30" — verbose
    /// banner used in the AI chat's `humanNow` line.
    static let humanNowPTBR: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "EEEE, d 'de' MMMM 'de' yyyy 'às' HH:mm"
        return f
    }()

    /// "29 de abr." — due-date chip on Editorial task rows and
    /// board cards (was allocated per row per render).
    static let dayOfMonthAbbrevPTBR: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "d 'de' MMM."
        return f
    }()

    /// "terça-feira" — Editorial home header masthead.
    static let weekdayFullPTBR: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "EEEE"
        return f
    }()

    /// "ter." — compact weekday (header strips the trailing dot).
    static let weekdayShortPTBR: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "EEE"
        return f
    }()

    /// "29 de abril" — header day+full-month line.
    static let dayMonthFullPTBR: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "d 'de' MMMM"
        return f
    }()

    /// "abr." — month ticker (header strips the trailing dot).
    static let monthAbbrevPTBR: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "MMM"
        return f
    }()

    /// Reminder pill labels in the task detail.
    static let reminderTodayPTBR: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "'hoje' HH:mm"
        return f
    }()
    static let reminderTomorrowPTBR: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "'amanhã' HH:mm"
        return f
    }()
    static let reminderFullPTBR: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "d MMM · HH:mm"
        return f
    }()
}
