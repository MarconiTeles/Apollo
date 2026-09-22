import AppKit
import Combine
import Foundation

/// Shared, persisted horizontal geometry for the "Minhas Tarefas" list columns.
///
/// The SwiftUI column header AND the AppKit rows both derive every column's x
/// and width from `metrics(totalWidth:)`, so they can never drift. Only the
/// resizable columns (media/priority/assignee/date) carry an explicit width;
/// the title is elastic and absorbs the slack. Widths persist under
/// `dp_myTasks_columnWidths_v1` and apply to every status group.
final class MyTasksColumnLayout: ObservableObject {
    static let shared = MyTasksColumnLayout()

    enum Column: String, Codable, CaseIterable, Identifiable {
        case priority, assignee, date
        var id: String { rawValue }
    }

    struct Widths: Codable, Equatable {
        var priority: CGFloat
        var assignee: CGFloat
        var date: CGFloat

        /// == the constants the row layout used before this feature existed, so
        /// a fresh install is pixel-identical to the old fixed layout.
        static let defaults = Widths(priority: 112, assignee: 132, date: 92)

        subscript(_ column: Column) -> CGFloat {
            get {
                switch column {
                case .priority: return priority
                case .assignee: return assignee
                case .date: return date
                }
            }
            set {
                switch column {
                case .priority: priority = newValue
                case .assignee: assignee = newValue
                case .date: date = newValue
                }
            }
        }
    }

    // Fixed chrome — moved verbatim out of MyTasksNativeRowView.layout().
    static let edge: CGFloat = 44
    static let gap: CGFloat = 14
    static let moreWidth: CGFloat = 18
    /// ANEXAR is 30% narrower than the original 92pt capsule. The review slot
    /// is always reserved immediately to its left so a newly-arrived review
    /// can appear without making the title or data columns jump.
    static let mediaWidth: CGFloat = 92 * 0.70
    static let reviewWidth: CGFloat = 76
    static let reviewMediaGap: CGFloat = 6
    static let titleLeading: CGFloat = 22            // old titleX = edge + 10 + 12
    static let titleTrailingGap: CGFloat = gap * 1.5 // 21 — extra room title→ANEXAR
    static let titleMin: CGFloat = 140               // hard floor so columns can't overflow the row

    static let minW: [Column: CGFloat] = [.priority: 72, .assignee: 96, .date: 64]
    static let maxW: [Column: CGFloat] = [.priority: 220, .assignee: 300, .date: 160]

    @Published private(set) var widths: Widths

    private static let key = "dp_myTasks_columnWidths_v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Widths.self, from: data) {
            widths = decoded
        } else {
            widths = .defaults
        }
    }

    // MARK: Geometry — the single source of truth for header + rows

    struct Metrics {
        let totalWidth: CGFloat
        let doneX: CGFloat
        let titleX: CGFloat
        let titleWidth: CGFloat
        let reviewX: CGFloat
        let reviewWidth: CGFloat
        let mediaX: CGFloat
        let mediaWidth: CGFloat
        let priorityX: CGFloat
        let priorityWidth: CGFloat
        let assigneeX: CGFloat
        let assigneeWidth: CGFloat
        let dateX: CGFloat
        let dateWidth: CGFloat
        let moreX: CGFloat
        /// Leading edge (== resize-handle position) of each resizable column.
        let handleX: [Column: CGFloat]
    }

    /// Reproduces the exact right-to-left chain the old `layout()` used. Media
    /// is a fixed-width capsule; only priority/assignee/date resize.
    func metrics(totalWidth W: CGFloat) -> Metrics {
        let e = Self.edge, gap = Self.gap
        let moreX = W - e - Self.moreWidth
        let dateX = moreX - gap - widths.date
        let assigneeX = dateX - gap - widths.assignee
        let priorityX = assigneeX - gap - widths.priority
        let mediaX = priorityX - gap - Self.mediaWidth
        let reviewX = mediaX - Self.reviewMediaGap - Self.reviewWidth
        let titleX = e + Self.titleLeading
        let titleWidth = max(0, reviewX - Self.titleTrailingGap - titleX)
        return Metrics(
            totalWidth: W,
            doneX: e - 7,
            titleX: titleX, titleWidth: titleWidth,
            reviewX: reviewX, reviewWidth: Self.reviewWidth,
            mediaX: mediaX, mediaWidth: Self.mediaWidth,
            priorityX: priorityX, priorityWidth: widths.priority,
            assigneeX: assigneeX, assigneeWidth: widths.assignee,
            dateX: dateX, dateWidth: widths.date,
            moreX: moreX,
            // Handle/guide sit at the MIDDLE of the inter-column gap so the line
            // never touches the content — gap/2 (≈7pt) of breathing on each side.
            handleX: [.priority: priorityX - Self.gap / 2,
                      .assignee: assigneeX - Self.gap / 2,
                      .date: dateX - Self.gap / 2]
        )
    }

    // MARK: Live drag (absolute pointer-x mapping — drift-free)

    /// Move `column`'s LEFT edge (its handle) to `pointerX`. Because the layout
    /// chains from the trailing edge and the columns to the right of `column`
    /// are fixed, its width is simply `rightEdge − pointerX`. Only `column`
    /// changes; the others keep width and shift as a block; the title absorbs.
    func drag(_ column: Column, toX pointerX: CGFloat, totalWidth W: CGFloat) {
        let m = metrics(totalWidth: W)
        let rightEdge: CGFloat
        switch column {
        case .priority: rightEdge = m.assigneeX - Self.gap
        case .assignee: rightEdge = m.dateX - Self.gap
        case .date:     rightEdge = m.moreX - Self.gap
        }
        // pointerX is the boundary line (gap midpoint); the column's left edge is
        // gap/2 to its right, so width = rightEdge − (pointerX + gap/2).
        setWidth(column, to: rightEdge - pointerX - Self.gap / 2, totalWidth: W)
    }

    private func setWidth(_ column: Column, to proposed: CGFloat, totalWidth W: CGFloat) {
        var next = widths
        let minV = Self.minW[column] ?? 40
        let maxV = Self.maxW[column] ?? 400
        // Keep title ≥ titleMin given the other three columns fixed:
        //   titleWidth = W - 2*edge - moreWidth - 4*gap - Σwidths - titleTrailingGap - titleLeading
        let others = Column.allCases.filter { $0 != column }.reduce(0) { $0 + next[$1] }
        let cap = W - 2 * Self.edge - Self.moreWidth - 4 * Self.gap
            - Self.mediaWidth - Self.reviewMediaGap - Self.reviewWidth - others
            - Self.titleTrailingGap - Self.titleLeading - Self.titleMin
        let upper = max(minV, min(maxV, cap))
        next[column] = min(max(proposed, minV), upper)
        if next != widths { widths = next }
    }

    /// Persist current widths. Call on drag-end (not per tick).
    func commit() {
        if let data = try? JSONEncoder().encode(widths) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func resetToDefaults() {
        if widths != .defaults { widths = .defaults }
        commit()
    }
}
