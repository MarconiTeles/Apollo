import XCTest
@testable import DayPanel

final class TaskMediaPlannerTests: XCTestCase {
    func testFiveHooksTimesTwoBodiesCreatesTenOutputs() throws {
        let inputs = (1...5).map { selection("hook-h\($0).mov", .hook, "h\($0)") }
            + (1...2).map { selection("body-b\($0).mov", .body, "b\($0)") }
        let plan = try TaskMediaPlanner.adding(selections: inputs,
                                               to: .empty(taskId: "task"))
        XCTAssertEqual(plan.outputs.count, 10)
        XCTAssertEqual(Set(plan.outputs.map(\.lineage.id)).count, 10)
        XCTAssertTrue(plan.outputs.allSatisfy { $0.version == 1 })
    }

    func testAddingOneBodyToFiveExistingHooksCreatesOnlyFiveNewOutputs() throws {
        var catalog = try committedInitialCatalog(hooks: 5, bodies: 2)
        let newBody = selection("body-b3.mov", .body, "b3")
        let plan = try TaskMediaPlanner.adding(selections: [newBody], to: catalog)
        XCTAssertEqual(plan.outputs.count, 5)
        XCTAssertTrue(plan.outputs.allSatisfy { $0.bodyAssetId.map(plan.newAssetIds.contains) == true })
        XCTAssertTrue(plan.outputs.allSatisfy { $0.version == 1 })
        catalog = plan.catalog
        XCTAssertEqual(catalog.assets.filter { $0.role == .body }.count, 3)
    }

    func testReplacingHookRegeneratesEveryBodyAsV2() throws {
        let catalog = try committedInitialCatalog(hooks: 5, bodies: 2)
        let hook = try XCTUnwrap(catalog.assets.first { $0.role == .hook })
        let replacement = selection("hook-h1-revisado.mov", .hook, "h1-r2")
        let plan = try TaskMediaPlanner.replacing(assetId: hook.id,
                                                  with: replacement,
                                                  in: catalog)
        XCTAssertEqual(plan.outputs.count, 2)
        XCTAssertTrue(plan.outputs.allSatisfy { $0.hookAssetId == hook.id })
        XCTAssertTrue(plan.outputs.allSatisfy { $0.version == 2 })
        XCTAssertEqual(plan.catalog.asset(id: hook.id)?.activeRevision?.number, 2)
    }

    func testSequentialHookThenBodyReplacementAdvancesSharedLineageToV3() throws {
        var catalog = try committedInitialCatalog(hooks: 2, bodies: 1)
        let hook = try XCTUnwrap(catalog.assets.first { $0.role == .hook })
        let body = try XCTUnwrap(catalog.assets.first { $0.role == .body })
        let hookPlan = try TaskMediaPlanner.replacing(
            assetId: hook.id,
            with: selection("hook-r2.mov", .hook, "hook-r2"),
            in: catalog
        )
        catalog = committing(hookPlan)
        let bodyPlan = try TaskMediaPlanner.replacing(
            assetId: body.id,
            with: selection("body-r2.mov", .body, "body-r2"),
            in: catalog
        )
        let shared = try XCTUnwrap(bodyPlan.outputs.first { $0.hookAssetId == hook.id })
        XCTAssertEqual(shared.version, 3)
        XCTAssertEqual(bodyPlan.outputs.count, 2)
    }

    func testSimultaneousHookAndBodyReplacementEmitsSharedLineageOnlyOnce() throws {
        let catalog = try committedInitialCatalog(hooks: 2, bodies: 2)
        let hook = try XCTUnwrap(catalog.assets.first { $0.role == .hook })
        let body = try XCTUnwrap(catalog.assets.first { $0.role == .body })
        let plan = try TaskMediaPlanner.replacing(
            replacements: [
                hook.id: selection("hook-r2.mov", .hook, "hook-r2"),
                body.id: selection("body-r2.mov", .body, "body-r2")
            ],
            in: catalog
        )

        XCTAssertEqual(plan.outputs.count, 3)
        XCTAssertEqual(Set(plan.outputs.map(\.lineage.id)).count, 3)
        XCTAssertEqual(plan.outputs.filter {
            $0.hookAssetId == hook.id && $0.bodyAssetId == body.id
        }.count, 1)
        XCTAssertTrue(plan.outputs.allSatisfy { $0.version == 2 })
        XCTAssertEqual(plan.catalog.asset(id: hook.id)?.activeRevision?.number, 2)
        XCTAssertEqual(plan.catalog.asset(id: body.id)?.activeRevision?.number, 2)
    }

    func testDirectVideoReplacementCreatesNextVersion() throws {
        var catalog = TaskMediaCatalog.empty(taskId: "task")
        let first = try TaskMediaPlanner.adding(
            selections: [selection("final.mov", .video, "video-v1")], to: catalog
        )
        catalog = committing(first)
        let video = try XCTUnwrap(catalog.assets.first)
        let second = try TaskMediaPlanner.replacing(
            assetId: video.id,
            with: selection("final-revisado.mov", .video, "video-v2"),
            in: catalog
        )
        XCTAssertEqual(second.outputs.count, 1)
        XCTAssertEqual(second.outputs[0].version, 2)
    }

    func testComposedOutputExposesHookAndBodyAsIndependentReplacementTargets() throws {
        let catalog = try committedInitialCatalog(hooks: 1, bodies: 1)
        let lineage = try XCTUnwrap(catalog.lineages.first)
        let components = catalog.replacementComponents(for: lineage)

        XCTAssertEqual(components.map(\.role), [.hook, .body])
        XCTAssertEqual(components.map(\.id),
                       [lineage.hookAssetId, lineage.bodyAssetId].compactMap { $0 })
    }

    func testLegacyDirectVideoDoesNotInventMissingHookOrBodySources() throws {
        var catalog = TaskMediaCatalog.empty(taskId: "task")
        let plan = try TaskMediaPlanner.adding(
            selections: [selection("resultado-legado.mov", .video, "legacy")],
            to: catalog
        )
        catalog = committing(plan)
        let lineage = try XCTUnwrap(catalog.lineages.first)

        XCTAssertFalse(lineage.isComposition)
        XCTAssertTrue(catalog.replacementComponents(for: lineage).isEmpty)
    }

    func testDuplicateWithinSameSelectionIsRejected() {
        XCTAssertThrowsError(try TaskMediaPlanner.adding(
            selections: [
                selection("hook-1.mov", .hook, "same"),
                selection("hook-copy.mov", .hook, "same"),
                selection("body.mov", .body, "body")
            ],
            to: .empty(taskId: "task")
        )) { error in
            guard case TaskMediaPlannerError.duplicateFiles = error else {
                return XCTFail("Erro inesperado: \(error)")
            }
        }
    }

    func testRoleInferenceUsesProductionTokens() {
        XCTAssertEqual(TaskMediaRole.inferred(from: "Campanha_HOOK_02.mov"), .hook)
        XCTAssertEqual(TaskMediaRole.inferred(from: "Camiseta-B3-final.mov"), .body)
        XCTAssertEqual(TaskMediaRole.inferred(from: "video completo.mov"), .video)
        XCTAssertNil(TaskMediaRole.inferred(from: "export-23.mov"))
    }

    func testLegacyVideoAttachmentBecomesReplaceableV1AndAdvancesToV2() throws {
        let attachment = CUTask.Attachment(
            id: "legacy-video-1",
            title: "Campanha escolhida pelo usuário · V1.mov",
            url: "https://files.example.com/campanha-v1.mov",
            ext: "mov",
            sizeString: "20 MB",
            totalComments: 0,
            resolvedComments: 0,
            uploaderId: 42
        )
        var catalog = TaskMediaCatalog.empty(taskId: "task")
        XCTAssertEqual(catalog.importLegacyVideoAttachments([attachment]), 1)
        XCTAssertEqual(catalog.assets.count, 1)
        XCTAssertEqual(catalog.assets.first?.role, .video)
        XCTAssertEqual(catalog.outputs.first?.version, 1)

        let asset = try XCTUnwrap(catalog.assets.first)
        let replacement = try TaskMediaPlanner.replacing(
            assetId: asset.id,
            with: selection("campanha-revisada.mov", .video, "legacy-v2"),
            in: catalog
        )
        XCTAssertEqual(replacement.outputs.first?.version, 2)
    }

    func testLegacyImportIsDeterministicAcrossMacsAndIdempotentOnReload() throws {
        let attachment = CUTask.Attachment(
            id: "shared-attachment",
            title: "Campanha · V3.mov",
            url: "https://files.example.com/campanha-v3.mov",
            ext: "mov",
            sizeString: "20 MB",
            totalComments: 0,
            resolvedComments: 0,
            uploaderId: 42
        )
        var firstMac = TaskMediaCatalog.empty(taskId: "task")
        var secondMac = TaskMediaCatalog.empty(taskId: "task")
        XCTAssertEqual(firstMac.importLegacyVideoAttachments([attachment]), 1)
        XCTAssertEqual(firstMac.importLegacyVideoAttachments([attachment]), 0)
        XCTAssertEqual(secondMac.importLegacyVideoAttachments([attachment]), 1)
        XCTAssertEqual(firstMac.assets.first?.id, secondMac.assets.first?.id)
        XCTAssertEqual(firstMac.assets.first?.activeRevisionId,
                       secondMac.assets.first?.activeRevisionId)
        XCTAssertEqual(firstMac.outputs.first?.version, 3)
    }

    func testLegacyImportIgnoresTechnicalSourceAttachments() {
        let attachment = CUTask.Attachment(
            id: "technical-source",
            title: "\(TaskMediaTechnicalName.sourcePrefix)HOOK__id__R1__hash.mov",
            url: "https://files.example.com/source.mov",
            ext: "mov",
            sizeString: "20 MB",
            totalComments: 0,
            resolvedComments: 0,
            uploaderId: 42
        )
        var catalog = TaskMediaCatalog.empty(taskId: "task")
        XCTAssertEqual(catalog.importLegacyVideoAttachments([attachment]), 0)
        XCTAssertTrue(catalog.assets.isEmpty)
    }

    func testOutputNamesUseTheSameCanonicalRuleBeforeAndAfterSending() {
        XCTAssertEqual(TaskMediaOutputName.normalized("  Campanha final.mov  "),
                       "Campanha final.mov")
        XCTAssertEqual(TaskMediaOutputName.normalized("Campanha: final?"),
                       "Campanha- final-.mov")
        XCTAssertEqual(TaskMediaOutputName.comparisonKey("Vídeo.mov"),
                       TaskMediaOutputName.comparisonKey("video"))
        XCTAssertNil(TaskMediaOutputName.normalized("   "))
    }

    private func committedInitialCatalog(hooks: Int, bodies: Int) throws -> TaskMediaCatalog {
        let inputs = (1...hooks).map { selection("hook-h\($0).mov", .hook, "h\($0)") }
            + (1...bodies).map { selection("body-b\($0).mov", .body, "b\($0)") }
        return committing(try TaskMediaPlanner.adding(selections: inputs,
                                                       to: .empty(taskId: "task")))
    }

    private func committing(_ plan: TaskMediaPlan) -> TaskMediaCatalog {
        var catalog = plan.catalog
        for output in plan.outputs {
            let revisionIds = [output.hookAssetId, output.bodyAssetId, output.videoAssetId]
                .compactMap { $0 }
                .compactMap { catalog.asset(id: $0)?.activeRevision?.id }
            catalog.outputs.append(.init(lineageId: output.lineage.id,
                                         version: output.version,
                                         fileName: output.displayFileName,
                                         sourceRevisionIds: revisionIds))
        }
        return catalog
    }

    private func selection(_ name: String, _ role: TaskMediaRole,
                           _ hash: String) -> TaskMediaSelection {
        TaskMediaSelection(fileURL: URL(fileURLWithPath: "/tmp/\(name)"),
                           role: role, contentHash: hash)
    }
}
