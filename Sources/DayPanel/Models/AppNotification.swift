import Foundation
import SwiftUI

/// One in-app notification — surfaced both as a transient toast in the
/// upper-right corner AND as a persistent entry in the Notifications
/// Center (bell icon in the toolbar). Persisted via UserDefaults JSON.

struct AppNotification: Identifiable, Codable, Equatable, Hashable {
    let id:         UUID
    let date:       Date
    let kind:       Kind
    /// Bold headline — the entity name (task or event title) when
    /// the notification targets one. Falls back to a generic phrase
    /// for status/connection events that aren't tied to a record.
    let title:      String
    /// Action label rendered between the bold title and the details
    /// line ("Status mudou", "Começa em 7 min", "Vence em 30 min").
    /// Optional so untargeted notifications (sync errors, generic
    /// success messages) can render with just title + message.
    let subtitle:   String?
    let message:    String?
    /// Optional list of substrings inside `message` that should
    /// render in a per-segment accent colour. Used by the
    /// status-change diff to paint each status name in its own
    /// pill colour ("TO DO" green, "REVIEW" purple, etc.) so a
    /// quick glance at the row tells the user which transition
    /// happened. Substring match is the SIMPLEST stable
    /// reference (we'd need a fragile range-based scheme to
    /// survive Codable round-trips otherwise).
    let messageHighlights: [Highlight]?
    var read:       Bool
    /// Optional pointer back to the task/event that triggered this entry,
    /// so clicking the row in the Notifications Center can open it.
    let targetKind: TargetKind?
    let targetId:   String?

    struct Highlight: Codable, Equatable, Hashable {
        /// Exact substring to colour (case-sensitive). The
        /// renderer applies the colour to the FIRST occurrence
        /// — multiple instances of the same status name in one
        /// message are handled by emitting two `Highlight`
        /// entries with the same text and a `nthOccurrence`
        /// offset… but since the typical status-change
        /// message is "FROM → TO" with both names ALWAYS
        /// distinct (otherwise we wouldn't fire a
        /// notification), the single-occurrence path covers
        /// the realistic surface.
        let text: String
        /// Foreground colour as `#RRGGBB` (or `#AARRGGBB`).
        /// Uppercased, no validation — `Color(hex:)` handles
        /// malformed values by falling back to grey.
        let hex:  String
    }

    init(id: UUID = UUID(),
         date: Date = Date(),
         kind: Kind,
         title: String,
         subtitle: String? = nil,
         message: String? = nil,
         messageHighlights: [Highlight]? = nil,
         read: Bool = false,
         targetKind: TargetKind? = nil,
         targetId:   String?     = nil) {
        self.id                 = id
        self.date               = date
        self.kind               = kind
        self.title              = title
        self.subtitle           = subtitle
        self.message            = message
        self.messageHighlights  = messageHighlights
        self.read               = read
        self.targetKind         = targetKind
        self.targetId           = targetId
    }

    enum Kind: String, Codable {
        case info, success, warning, error
    }

    enum TargetKind: String, Codable {
        case task, event
        /// A review whose link was updated. `targetId` is the review's `att`
        /// key; the tap reopens the Apollo Review window on that review.
        case review
    }

    var hasTarget: Bool { targetKind != nil && targetId != nil }

    /// The Home Inbox is an action feed, not a network log. Connection
    /// and background-sync health remain available through the toolbar
    /// status/toasts, but do not occupy persistent Inbox rows.
    var isHomeInboxEligible: Bool {
        !Self.homeInboxOperationalTitles.contains(title)
    }

    private static let homeInboxOperationalTitles: Set<String> = [
        "Sem conexão",
        "De volta ao online",
        "Falha na sincronização"
    ]

    // MARK: - Rendered message

    /// Builds an `AttributedString` from `message` with each
    /// `Highlight` substring rendered in its accent colour +
    /// semibold weight. Returns nil when `message` is nil or
    /// empty so the renderer can fall through to its
    /// "subtitle-only" branch.
    ///
    /// Surrounding `.foregroundStyle(.secondary)` on the host
    /// `Text` colours the unhighlighted runs; the inline
    /// `foregroundColor` set per highlighted range overrides
    /// it for those ranges only.
    var attributedMessage: AttributedString? {
        guard let message, !message.isEmpty else { return nil }
        var attr = AttributedString(message)
        guard let highlights = messageHighlights, !highlights.isEmpty else {
            return attr
        }
        for h in highlights {
            // `range(of:)` returns the FIRST occurrence — fine
            // for the FROM → TO status pattern where each name
            // appears at most once.
            if let range = attr.range(of: h.text) {
                attr[range].foregroundColor = Color(hex: h.hex)
                attr[range].font = .caption.weight(.semibold)
            }
        }
        return attr
    }
}

extension AppNotification.Kind {
    var systemImage: String {
        switch self {
        case .info:    return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info:    return .blue
        case .success: return .green
        case .warning: return .orange
        case .error:   return .red
        }
    }
}
