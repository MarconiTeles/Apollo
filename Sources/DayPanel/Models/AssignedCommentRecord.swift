import Foundation

/// Bounded work queue used by the Assigned Comments indexer. Kept separate
/// from the view model so the 30-item contract is deterministic and directly
/// regression-testable without network access.
enum AssignedCommentsPagination {
    static let pageSize = 30

    static func split<T>(_ values: [T]) -> (page: [T], remainder: [T]) {
        let boundary = min(pageSize, values.count)
        return (Array(values[..<boundary]), Array(values[boundary...]))
    }
}

/// A task comment plus the task context required by the global
/// "Comentários atribuídos" surface.
struct AssignedCommentRecord: Identifiable, Equatable {
    var id: String { comment.id }
    let task: CUTask
    var comment: CUComment

    func isAssigned(to userId: Int) -> Bool {
        comment.assignee?.id == userId
    }

    func wasDelegated(by userId: Int) -> Bool {
        comment.assignedBy?.id == userId
    }

    func mentions(username: String) -> Bool {
        guard !username.isEmpty else { return false }
        return comment.text.range(of: "@\(username)",
                                  options: .caseInsensitive) != nil
    }
}
