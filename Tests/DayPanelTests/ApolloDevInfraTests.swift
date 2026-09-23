import XCTest
@testable import ApolloRuntime

/// DEV build infrastructure: production identity invariants, launch-argument
/// parsing and the deterministic board fixture generator.
final class ApolloDevInfraTests: XCTestCase {

    // MARK: Keychain namespace

    func testProductionKeychainServiceIsUnchanged() {
        XCTAssertEqual(KeychainHelper.secretsService(forBundleIdentifier: "com.painellunar.app"),
                       "com.painellunar.app.secrets")
    }

    func testMissingBundleIdentifierFallsBackToProductionService() {
        XCTAssertEqual(KeychainHelper.secretsService(forBundleIdentifier: nil),
                       "com.painellunar.app.secrets")
        XCTAssertEqual(KeychainHelper.secretsService(forBundleIdentifier: ""),
                       "com.painellunar.app.secrets")
        XCTAssertEqual(KeychainHelper.secretsService(forBundleIdentifier: "  "),
                       "com.painellunar.app.secrets")
    }

    func testDevBundleGetsItsOwnKeychainService() {
        let dev = KeychainHelper.secretsService(
            forBundleIdentifier: "com.painellunar.app.dev.board-appkit")
        XCTAssertEqual(dev, "com.painellunar.app.dev.board-appkit.secrets")
        XCTAssertNotEqual(dev, KeychainHelper.productionSecretsService)
    }

    // MARK: Launch options

    func testParseAllOptions() {
        let parsed = ApolloDevLaunchOptions.parse([
            "/path/DayPanel", "--board-renderer=AppKit", "--board-fixtures=1000",
            "--route=board", "--appearance=dark", "-NSDocumentRevisionsDebugMode", "YES",
        ])
        XCTAssertEqual(parsed, .init(boardRenderer: "appkit", boardFixtureCount: 1000,
                                     route: "board", appearance: "dark"))
    }

    func testParseRejectsInvalidValues() {
        let parsed = ApolloDevLaunchOptions.parse([
            "--board-renderer=metal", "--board-fixtures=0", "--route=settings",
            "--appearance=sepia", "--board-fixtures", "board-fixtures=5",
        ])
        XCTAssertEqual(parsed, .init())
        XCTAssertNil(ApolloDevLaunchOptions.parse(["--board-fixtures=-3"]).boardFixtureCount)
        XCTAssertNil(ApolloDevLaunchOptions.parse(["--board-fixtures=abc"]).boardFixtureCount)
    }

    /// Tests are compiled without APOLLO_DEV: the options must be inert.
    func testOptionsAreInertOutsideDevBuild() {
        XCTAssertFalse(ApolloDevLaunchOptions.isDevBuild)
        XCTAssertNil(ApolloDevLaunchOptions.boardRenderer)
        XCTAssertNil(ApolloDevLaunchOptions.boardFixtureCount)
        XCTAssertNil(ApolloDevLaunchOptions.initialRoute)
        XCTAssertFalse(ApolloDevLaunchOptions.isFixtureMode)
    }

    // MARK: Fixtures

    private let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)

    func testFixturesAreDeterministic() {
        let a = ApolloBoardFixtureGenerator.tasks(count: 1000, now: fixedNow)
        let b = ApolloBoardFixtureGenerator.tasks(count: 1000, now: fixedNow)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 1000)
        XCTAssertEqual(Set(a.map(\.id)).count, 1000)
    }

    func testFixturesCoverTheBoardVariations() {
        let tasks = ApolloBoardFixtureGenerator.tasks(count: 5000, now: fixedNow)
        let statuses = ApolloPreviewFixtures.statuses.map(\.status)
        let perStatus = Dictionary(grouping: tasks, by: \.status).mapValues(\.count)
        XCTAssertEqual(Set(perStatus.keys), Set(statuses), "all 10 statuses used")
        let counts = statuses.map { perStatus[$0] ?? 0 }
        XCTAssertGreaterThan(counts.max()! , counts.min()! * 5, "unbalanced columns")

        XCTAssertEqual(Set(tasks.map(\.assignees.count)), Set(0...4))
        XCTAssertEqual(Set(tasks.map(\.priority)), Set(0...4))
        XCTAssertTrue(tasks.contains { $0.dueDate == nil })
        let cal = Calendar.current
        XCTAssertTrue(tasks.contains { $0.dueDate.map { cal.isDate($0, inSameDayAs: fixedNow) } == true })
        XCTAssertTrue(tasks.contains { ($0.dueDate ?? .distantPast) > fixedNow.addingTimeInterval(86_400) })
        XCTAssertTrue(tasks.contains { ($0.dueDate ?? .distantFuture) < fixedNow.addingTimeInterval(-86_400) })

        let ids = Set(tasks.map(\.id))
        let subtasks = tasks.filter(\.isSubtask)
        XCTAssertFalse(subtasks.isEmpty)
        XCTAssertTrue(subtasks.allSatisfy { ids.contains($0.parentId!) })

        XCTAssertTrue(tasks.contains { $0.title.count <= 16 })
        XCTAssertTrue(tasks.contains { $0.title.count >= 120 })
        XCTAssertTrue(tasks.contains { $0.title.unicodeScalars.contains { $0.properties.isEmojiPresentation } })
        XCTAssertTrue(tasks.contains { $0.title.contains("Â") || $0.title.contains("é") || $0.title.contains("à") })

        // Closed statuses follow production semantics (hidden from the board).
        let closed = Set(ApolloPreviewFixtures.statuses.filter { $0.type == "closed" }.map(\.status))
        XCTAssertTrue(tasks.allSatisfy { $0.isCompleted == closed.contains($0.status) })
        let visible = TaskSurfaceScope.openTasks(in: tasks, activeListId: ApolloPreviewFixtures.listId)
        XCTAssertGreaterThan(visible.count, 4500)
    }
}
