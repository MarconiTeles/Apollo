import XCTest
@testable import ApolloRuntime

final class TaskFiltersTests: XCTestCase {
    private func task(
        id: String = UUID().uuidString,
        priority: Int = 0,
        assigneeId: Int? = nil,
        tag: String? = nil,
        dueDate: Date? = nil,
        creatorId: Int? = nil,
        created: Date? = nil,
        closed: Date? = nil
    ) -> CUTask {
        var value = CUTask(
            id: id,
            title: "Filtered task",
            status: "review",
            statusColor: "#7A6597",
            priority: priority,
            priorityColor: "#9E9E9E",
            startDate: nil,
            dueDate: dueDate,
            listId: "list",
            listName: "Video",
            isCompleted: false
        )
        if let assigneeId {
            value.assignees = [.init(id: assigneeId,
                                     username: "Member",
                                     initials: "M",
                                     color: nil,
                                     profilePicture: nil)]
        }
        if let tag {
            value.tags = [.init(name: tag,
                                foreground: "#FFFFFF",
                                background: "#000000")]
        }
        if let creatorId {
            value.creator = .init(id: creatorId,
                                  username: "Creator",
                                  initials: "C",
                                  color: nil,
                                  profilePicture: nil)
        }
        value.dateCreated = created
        value.dateClosed = closed
        return value
    }

    func testEmptyFilterAcceptsAnyTask() {
        XCTAssertTrue(TaskFilters().matches(task(priority: 4)))
    }

    func testDimensionsCombineWithAndAndValuesWithinDimensionUseOr() {
        var filters = TaskFilters()
        filters.priorities = [1, 2]
        filters.assigneeIds = [42]
        filters.tagNames = ["Video", "Copy"]

        XCTAssertTrue(filters.matches(task(priority: 2,
                                           assigneeId: 42,
                                           tag: "video")))
        XCTAssertFalse(filters.matches(task(priority: 3,
                                            assigneeId: 42,
                                            tag: "video")))
        XCTAssertFalse(filters.matches(task(priority: 2,
                                            assigneeId: 7,
                                            tag: "video")))
        XCTAssertFalse(filters.matches(task(priority: 2,
                                            assigneeId: 42,
                                            tag: "design")))
    }

    func testDueAndNoDateWindows() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var filters = TaskFilters()

        filters.dueWindow = .overdue
        XCTAssertTrue(filters.matches(task(dueDate: today.addingTimeInterval(-60))))
        XCTAssertFalse(filters.matches(task(dueDate: today.addingTimeInterval(60))))

        filters.dueWindow = .noDate
        XCTAssertTrue(filters.matches(task(dueDate: nil)))
        XCTAssertFalse(filters.matches(task(dueDate: today)))
    }

    func testEveryDueWindowAcceptsAndRejectsItsBoundaryCases() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let inSixDays = try XCTUnwrap(calendar.date(byAdding: .day, value: 6, to: today))
        let inSevenDays = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: today))

        XCTAssertTrue(DueWindow.overdue.contains(today.addingTimeInterval(-1)))
        XCTAssertFalse(DueWindow.overdue.contains(today))
        XCTAssertTrue(DueWindow.today.contains(today.addingTimeInterval(60)))
        XCTAssertFalse(DueWindow.today.contains(tomorrow))
        XCTAssertTrue(DueWindow.tomorrow.contains(tomorrow.addingTimeInterval(60)))
        XCTAssertFalse(DueWindow.tomorrow.contains(inSixDays))
        XCTAssertTrue(DueWindow.thisWeek.contains(today))
        XCTAssertTrue(DueWindow.thisWeek.contains(inSixDays))
        XCTAssertFalse(DueWindow.thisWeek.contains(inSevenDays))
        XCTAssertTrue(DueWindow.noDate.contains(nil))
        XCTAssertFalse(DueWindow.noDate.contains(today))
    }

    func testEveryCreatedAndClosedDateRangeUsesCalendarBuckets() throws {
        let calendar = Calendar.current
        let now = Date()
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now))
        let lastWeek = try XCTUnwrap(calendar.date(byAdding: .weekOfYear, value: -1, to: now))
        let lastMonth = try XCTUnwrap(calendar.date(byAdding: .month, value: -1, to: now))

        XCTAssertTrue(DateRange.today.contains(now))
        XCTAssertTrue(DateRange.yesterday.contains(yesterday))
        XCTAssertTrue(DateRange.thisWeek.contains(now))
        XCTAssertTrue(DateRange.lastWeek.contains(lastWeek))
        XCTAssertTrue(DateRange.thisMonth.contains(now))
        XCTAssertTrue(DateRange.lastMonth.contains(lastMonth))
        for range in DateRange.allCases {
            XCTAssertFalse(range.contains(nil), "\(range) must reject missing task metadata")
        }
    }

    func testAssigneeAndTagValuesUseOrAndTagMatchingIsCaseInsensitive() {
        var value = task(priority: 2, assigneeId: 42, tag: "Vídeo")
        value.assignees.append(.init(id: 7, username: "Second", initials: "S",
                                     color: nil, profilePicture: nil))
        value.tags.append(.init(name: "SOCIAL", foreground: "#fff",
                                background: "#000"))

        var filters = TaskFilters()
        filters.assigneeIds = [7, 99]
        filters.tagNames = ["social", "copy"]
        XCTAssertTrue(filters.matches(value))

        filters.assigneeIds = [99]
        XCTAssertFalse(filters.matches(value))
        filters.assigneeIds = [42]
        filters.tagNames = ["vÍdEo"]
        XCTAssertTrue(filters.matches(value))
    }

    func testActiveDimensionCountCoversAllSevenAndResetIsEmpty() {
        var filters = TaskFilters()
        filters.priorities = [1]
        filters.assigneeIds = [2]
        filters.tagNames = ["video"]
        filters.dueWindow = .today
        filters.creatorIds = [3]
        filters.createdRange = .thisWeek
        filters.closedRange = .lastMonth

        XCTAssertEqual(filters.activeDimensionCount, 7)
        XCTAssertFalse(filters.isEmpty)

        filters = TaskFilters()
        XCTAssertEqual(filters.activeDimensionCount, 0)
        XCTAssertTrue(filters.isEmpty)
    }

    func testCreatorAndDateRangesRejectMissingOrWrongMetadata() {
        var filters = TaskFilters()
        filters.creatorIds = [99]
        filters.createdRange = .today

        XCTAssertTrue(filters.matches(task(creatorId: 99, created: Date())))
        XCTAssertFalse(filters.matches(task(creatorId: 98, created: Date())))
        XCTAssertFalse(filters.matches(task(creatorId: 99, created: nil)))
    }

    func testCanonicalApplyingIsSharedOrderedAndNonDestructive() {
        let first = task(id: "first", priority: 2, assigneeId: 42, tag: "Video")
        let second = task(id: "second", priority: 1, assigneeId: 42, tag: "Video")
        let rejected = task(id: "rejected", priority: 3, assigneeId: 42, tag: "Video")
        let source = [first, rejected, second]

        var filters = TaskFilters()
        filters.priorities = [1, 2]
        filters.assigneeIds = [42]
        filters.tagNames = ["video"]

        XCTAssertEqual(filters.applying(to: source).map(\.id), ["first", "second"])
        XCTAssertEqual(source.map(\.id), ["first", "rejected", "second"],
                       "Applying filters must not reorder or mutate the shared source")
        XCTAssertEqual(TaskFilters().applying(to: source).map(\.id), source.map(\.id))
    }

    func testEveryExposedDimensionParticipatesInCanonicalApplying() {
        let now = Date()
        let matching = task(id: "matching", priority: 0, dueDate: nil,
                            creatorId: 99, created: now, closed: now)
        let wrongCreator = task(id: "wrong", priority: 0, dueDate: nil,
                                creatorId: 7, created: now, closed: now)

        var filters = TaskFilters()
        filters.priorities = [0]
        filters.dueWindow = .noDate
        filters.creatorIds = [99]
        filters.createdRange = .today
        filters.closedRange = .today

        XCTAssertEqual(filters.activeDimensionCount, 5)
        XCTAssertEqual(filters.applying(to: [wrongCreator, matching]).map(\.id), ["matching"])
    }

    func testBoardAndMyTasksShareTheSameOpenListUniverse() {
        var active = task(id: "active")
        active.listId = "active-list"

        var closed = task(id: "closed")
        closed.listId = "active-list"
        closed.isCompleted = true

        var archived = task(id: "archived")
        archived.listId = "active-list"
        archived.archived = true

        var otherList = task(id: "other")
        otherList.listId = "other-list"

        let source = [closed, otherList, active, archived]
        XCTAssertEqual(
            TaskSurfaceScope.openTasks(in: source,
                                       activeListId: "active-list").map(\.id),
            ["active"]
        )
        XCTAssertEqual(
            TaskSurfaceScope.openTasks(in: source,
                                       activeListId: "").map(\.id),
            ["other", "active"]
        )
    }
}
