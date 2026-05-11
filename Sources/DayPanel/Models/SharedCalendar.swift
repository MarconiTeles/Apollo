import Foundation

/// A contact whose calendar Apollo overlays on top of the
/// user's own timeline. Stored as a simple email + assigned
/// colour pair; the actual event/free-busy data lives in
/// `AppState.sharedEvents` and is rebuilt every sync.
///
/// Persisted in `UserDefaults` so the user's overlay roster
/// survives restart without needing iCloud or a server.
struct SharedCalendar: Identifiable, Codable, Hashable {
    /// Email address is the canonical identifier — Google's
    /// `freebusy.query` and `events.list` both key on it.
    var id: String { email.lowercased() }
    var email: String
    /// Display name pulled from the most recent event the
    /// contact appeared in (or the local part of the email
    /// when no event match exists).
    var name: String
    /// Hex colour used to tint the contact's events on the
    /// timeline. Picked deterministically from a small
    /// palette so the same email always lands on the same
    /// shade across launches.
    var colorHex: String

    /// 8 visually-distinct hues for overlay rows. Picked
    /// deterministically from the email's hash so a given
    /// contact always renders in the same colour.
    static let palette: [String] = [
        "#7986CB", // Lavender
        "#33B679", // Sage
        "#8E24AA", // Grape
        "#E67C73", // Flamingo
        "#F6BF26", // Banana
        "#F4511E", // Tangerine
        "#0B8043", // Basil
        "#3F51B5", // Blueberry
    ]

    static func paletteColor(for email: String) -> String {
        // FNV-1a hash → palette index. Stable across launches
        // because no salt and no Swift `hashValue`
        // randomisation involved.
        var h: UInt32 = 2166136261
        for byte in email.lowercased().utf8 {
            h ^= UInt32(byte)
            h = h &* 16777619
        }
        return palette[Int(h % UInt32(palette.count))]
    }

    /// Pulls the persisted roster on init. Tolerant of
    /// missing/corrupt data — returns an empty list instead
    /// of crashing.
    static func loadFromDefaults() -> [SharedCalendar] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([SharedCalendar].self, from: data)
        else { return [] }
        return list
    }

    static func persist(_ list: [SharedCalendar]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private static let defaultsKey = "dp_sharedCalendars_v1"
}
