import XCTest
@testable import ApolloRuntime

final class TaskMediaMixedPlanTests: XCTestCase {
    private func selection(_ name: String, _ role: TaskMediaRole, _ hash: String) -> TaskMediaSelection {
        .init(fileURL: URL(fileURLWithPath: "/tmp/\(name).mov"), role: role, contentHash: hash)
    }

    func testMixedDropKeepsReplacementAndAdditionInOnePreparedPlan() throws {
        let first = try TaskMediaPlanner.adding(selections: [selection("old", .video, "old")],
                                                to: .empty(taskId: "mixed"))
        let asset = try XCTUnwrap(first.catalog.assets.first)
        let result = try TaskMediaPlanner.changing(
            additions: [selection("new", .video, "new")],
            replacements: [asset.id: selection("replacement", .video, "replacement")],
            in: first.catalog)
        XCTAssertEqual(result.outputs.count, 2)
        XCTAssertEqual(result.newAssetIds.count, 1)
        XCTAssertEqual(result.pendingRevisionAssetIds, [asset.id])
        XCTAssertEqual(result.catalog.asset(id: asset.id)?.activeRevision?.contentHash, "replacement")
        XCTAssertEqual(Set(result.outputs.map(\.lineage.id)).count, 2)
    }

    func testNewBodyUsesReplacedHookAndExistingPairIsGeneratedOnlyOnce() throws {
        let initial = try TaskMediaPlanner.adding(
            selections: [selection("H1", .hook, "h1"), selection("B1", .body, "b1")],
            to: .empty(taskId: "mixed"))
        let hook = try XCTUnwrap(initial.catalog.assets.first { $0.role == .hook })
        let result = try TaskMediaPlanner.changing(additions: [selection("B2", .body, "b2")],
            replacements: [hook.id: selection("H1-v2", .hook, "h2")], in: initial.catalog)
        XCTAssertEqual(result.outputs.count, 2)
        XCTAssertEqual(Set(result.outputs.map(\.lineage.id)).count, 2)
        for output in result.outputs {
            XCTAssertEqual(output.hookAssetId, hook.id)
            XCTAssertEqual(result.catalog.asset(id: hook.id)?.activeRevision?.contentHash, "h2")
        }
    }

    func testDuplicateAcrossReplacementAndAdditionRejectsWholePlan() throws {
        let initial = try TaskMediaPlanner.adding(selections: [selection("old", .video, "old")],
                                                  to: .empty(taskId: "mixed"))
        let asset = try XCTUnwrap(initial.catalog.assets.first)
        XCTAssertThrowsError(try TaskMediaPlanner.changing(
            additions: [selection("same", .video, "same")],
            replacements: [asset.id: selection("same", .video, "same")], in: initial.catalog))
        XCTAssertEqual(initial.catalog.asset(id: asset.id)?.activeRevision?.contentHash, "old")
    }
}
