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

    /// "29 de abr.", "1 de mai." — short day + abbreviated month.
    /// Locale `pt_BR` because that's our only target locale; if
    /// the app ever ships in additional locales each can have its
    /// own bucket.
    static let shortDayMonthPTBR: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.setLocalizedDateFormatFromTemplate("dMMM")
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
}
