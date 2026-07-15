import XCTest
@testable import DayPanel

final class AssignedCommentsTests: XCTestCase {
    func testAssignedDelegatedAndMentionClassification() {
        let author = CUComment.Participant(id: 17,
                                           username: "Eduardo",
                                           email: nil,
                                           color: "#222222",
                                           initials: "E",
                                           profilePicture: nil)
        var comment = makeComment(text: "Pode validar, @Marconi Reis?")
        comment.assignee = CUComment.Participant(id: 42,
                                                 username: "Marconi Reis",
                                                 email: nil,
                                                 color: nil,
                                                 initials: "MR",
                                                 profilePicture: nil)
        comment.assignedBy = author
        let record = AssignedCommentRecord(task: makeTask(), comment: comment)

        XCTAssertTrue(record.isAssigned(to: 42))
        XCTAssertTrue(record.wasDelegated(by: 17))
        XCTAssertTrue(record.mentions(username: "marconi reis"))
        XCTAssertFalse(record.mentions(username: "Joana"))
    }

    func testPopupRadiusScaleMatchesDesignContract() {
        // Popups were bumped a further +50% over the original +35% pass:
        // 1.35 → 2.025. Callers still pass their pre-redesign radius.
        XCTAssertEqual(Editorial.popupRadiusScale, 2.025, accuracy: 0.0001)
        XCTAssertEqual(Editorial.popupRadius(20), 40.5, accuracy: 0.0001)
        XCTAssertEqual(Editorial.popupRadius(6), 12.15, accuracy: 0.0001)
    }

    func testAssignedCommentsPaginationIsBoundedToThirtyAndPreservesOrder() {
        let values = Array(0..<65)
        let first = AssignedCommentsPagination.split(values)
        XCTAssertEqual(first.page, Array(0..<30))
        XCTAssertEqual(first.remainder, Array(30..<65))

        let second = AssignedCommentsPagination.split(first.remainder)
        XCTAssertEqual(second.page, Array(30..<60))
        XCTAssertEqual(second.remainder, Array(60..<65))
    }

    func testNativeCapsuleShadowOffsetsAlwaysProjectDownward() {
        XCTAssertGreaterThan(Editorial.nativeCapsuleShadowRestY, 0)
        XCTAssertGreaterThan(Editorial.nativeCapsuleShadowHoverY, 0)
        XCTAssertGreaterThan(Editorial.nativeListShadowHoverY, 0)
    }

    private func makeTask() -> CUTask {
        CUTask(id: "task-1",
               title: "Tarefa",
               status: "review",
               statusColor: "#7A6597",
               priority: 0,
               priorityColor: "#000000",
               startDate: nil,
               dueDate: nil,
               listId: "list-1",
               listName: "Vídeo",
               isCompleted: false,
               description: nil)
    }

    private func makeComment(text: String) -> CUComment {
        CUComment(id: "comment-1",
                  text: text,
                  date: Date(timeIntervalSince1970: 100),
                  userId: 17,
                  userName: "Eduardo",
                  userEmail: nil,
                  userColor: nil,
                  initials: "E",
                  profilePic: nil,
                  resolved: false,
                  reactions: [],
                  replyCount: 0,
                  attachments: [])
    }
}
