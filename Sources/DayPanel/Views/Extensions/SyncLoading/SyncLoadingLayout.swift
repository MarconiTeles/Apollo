import CoreGraphics

/// Layout rule shared with `web/apollo-loading/src/lib/viewport.ts`: a
/// loading surface shows only items that fit *entirely* — down to the bottom
/// edge (or to whatever sits there, like the board's capsule), never one cut
/// by it. The native fallback and the web scene count the same way, so the
/// cross-fade between them never adds or removes a row.
enum SyncLoadingLayout {
    /// Items of `size` separated by `gap` that fit whole between `top` and
    /// `bottom`.
    static func fitting(bottom: CGFloat, top: CGFloat, size: CGFloat, gap: CGFloat) -> Int {
        max(1, Int(((bottom - top + gap) / (size + gap)).rounded(.down)))
    }

    static let taskHeader: CGFloat = 38
    static let taskRow: CGFloat = 44
    static let taskGroupGap: CGFloat = 16

    /// Rows per status group — 3, 6, then 5s — until the next row would be
    /// cut. A header is only placed when at least one row fits under it.
    static func taskGroups(height: CGFloat, top: CGFloat) -> [Int] {
        var groups: [Int] = []
        var y = top
        while true {
            let wanted = groups.isEmpty ? 3 : (groups.count == 1 ? 6 : 5)
            if y + taskHeader + taskRow > height { break }
            y += taskHeader
            let rows = min(wanted, Int(((height - y) / taskRow).rounded(.down)))
            groups.append(rows)
            y += CGFloat(rows) * taskRow
            if rows < wanted { break }
            y += taskGroupGap
        }
        return groups.isEmpty ? [1] : groups
    }

    // Item metrics of the scenes (see styles.css).
    static let boardCard: CGFloat = 106
    static let boardCardGap: CGFloat = 12
    /// Capsule (64) + bottom margin (28) + breathing room (16).
    static let boardCapsuleReserve: CGFloat = 108
    static let commentsTop: CGFloat = 112
    static let commentCard: CGFloat = 116
    static let commentGap: CGFloat = 12
    static let inboxTop: CGFloat = 166.5
    static let inboxCapsule: CGFloat = 58
    static let inboxGap: CGFloat = 9
}
