import Foundation

/// Pure board rules shared by the SwiftUI reference renderer and the AppKit
/// renderer. They are a mechanical extraction of the former private methods of
/// `EditorialBoardView`; both renderers must produce the same scope, column
/// order, local card order and reorder/placement results.
enum BoardOrdering {
    /// Decodes the `dp_board_cardOrder_v1` AppStorage payload.
    static func decode(_ raw: String) -> [String: [String]] {
        (try? JSONDecoder().decode([String: [String]].self,
                                   from: Data(raw.utf8))) ?? [:]
    }

    static func encode(_ dict: [String: [String]]) -> String? {
        guard let data = try? JSONEncoder().encode(dict),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    /// Cards present in the saved list sort by their stored index; cards
    /// absent (newly synced) keep their natural relative order at the end.
    static func ordered(_ cards: [CUTask], saved: [String]) -> [CUTask] {
        let pos = Dictionary(saved.enumerated().map { ($1, $0) },
                             uniquingKeysWith: { a, _ in a })
        return cards.enumerated().sorted { a, b in
            switch (pos[a.element.id], pos[b.element.id]) {
            case let (.some(x), .some(y)): return x < y
            case (.some, .none):           return true
            case (.none, .some):           return false
            case (.none, .none):           return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Live same-column reorder: moves every dragged id present in `ids`
    /// immediately before `targetId`. Returns nil when the reference would
    /// not write a new order.
    static func reorder(ids current: [String],
                        dragging: [String],
                        before targetId: String) -> [String]? {
        var ids = current
        let moving = ids.filter { dragging.contains($0) }
        guard !moving.isEmpty, !moving.contains(targetId), ids.contains(targetId) else { return nil }
        ids.removeAll { moving.contains($0) }
        guard let insertAt = ids.firstIndex(of: targetId) else { return nil }
        ids.insert(contentsOf: moving, at: insertAt)
        return ids
    }

    /// Cross-column placement before `targetId` (or at the tail when the
    /// target is absent).
    static func place(ids current: [String],
                      dragIds: [String],
                      before targetId: String) -> [String] {
        var ids = current
        ids.removeAll { dragIds.contains($0) }
        let insertAt = ids.firstIndex(of: targetId) ?? ids.count
        ids.insert(contentsOf: dragIds, at: insertAt)
        return ids
    }

    /// Fallback status set used when the workspace has not synced yet.
    static let fallbackStatuses: [CUStatus] = [
        CUStatus(status: "to do",     color: "#54577E", type: "open"),
        CUStatus(status: "doing",     color: "#B0612E", type: "custom"),
        CUStatus(status: "review",    color: "#7A6597", type: "custom"),
        CUStatus(status: "liberado",  color: "#9A7B1F", type: "custom"),
        CUStatus(status: "concluído", color: "#1F7A3A", type: "done"),
        CUStatus(status: "cancelado", color: "#C7321B", type: "closed"),
    ]
}

/// Immutable column projection consumed by the AppKit renderer.
struct BoardColumnSnapshot: Equatable {
    let status: CUStatus
    let key: String
    /// Ordered cards (server scope + local order).
    let cards: [CUTask]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key
            && lhs.status.status == rhs.status.status
            && lhs.status.color == rhs.status.color
            && lhs.status.type == rhs.status.type
            && lhs.cards == rhs.cards
    }
}

/// Value snapshot of everything the AppKit board draws. Built once per
/// change of its inputs, never per scroll tick.
struct BoardRenderSnapshot: Equatable {
    var columns: [BoardColumnSnapshot]
    var workspaceName: String
    var isColdLoading: Bool

    static let empty = BoardRenderSnapshot(columns: [], workspaceName: "", isColdLoading: false)

    /// Left-to-right, top-to-bottom order used for Shift ranges and drags.
    var orderedTaskIds: [String] { columns.flatMap { $0.cards.map(\.id) } }
    var orderedTasks: [CUTask] { columns.flatMap(\.cards) }

    /// Same projection as `EditorialBoardView.boardTasks` +
    /// `columnCards` + `orderedCards`, computed in one pass.
    static func make(tasks: [CUTask],
                     activeListId: String,
                     statuses: [CUStatus],
                     showSubtasks: Bool,
                     filters: TaskFilters,
                     cardOrder: [String: [String]],
                     workspaceName: String,
                     isColdLoading: Bool) -> BoardRenderSnapshot {
        let open = TaskSurfaceScope.openTasks(in: tasks, activeListId: activeListId)
        let scoped = open.filter { showSubtasks || !$0.isSubtask }
        let boardTasks = filters.applying(to: scoped)
        var buckets: [String: [CUTask]] = [:]
        for task in boardTasks {
            buckets[task.status.lowercased(), default: []].append(task)
        }
        let columns = statuses.map { status -> BoardColumnSnapshot in
            let key = status.status.lowercased()
            let cards = BoardOrdering.ordered(buckets[key] ?? [], saved: cardOrder[key] ?? [])
            return BoardColumnSnapshot(status: status, key: key, cards: cards)
        }
        return BoardRenderSnapshot(columns: columns,
                                   workspaceName: workspaceName,
                                   isColdLoading: isColdLoading)
    }
}
