import XCTest
@testable import ApolloRuntime

/// Lixeira de vídeos já enviados: o que sai do catálogo, o que fica, e o
/// que impede o removido de voltar (a API do ClickUp não apaga o arquivo).
final class TaskMediaRemovalTests: XCTestCase {
    private func selection(_ name: String, _ role: TaskMediaRole) -> TaskMediaSelection {
        TaskMediaSelection(fileURL: URL(fileURLWithPath: "/tmp/\(name).mov"), role: role,
                           contentHash: "hash-\(name)")
    }

    /// Dois HOOKs × um BODY + um vídeo direto, todos publicados.
    private func publishedCatalog() throws -> TaskMediaCatalog {
        let plan = try TaskMediaPlanner.adding(selections: [
            selection("H1", .hook), selection("H2", .hook),
            selection("B1", .body), selection("POV", .video),
        ], to: .empty(taskId: "task"))
        var catalog = plan.catalog
        for (index, output) in plan.outputs.enumerated() {
            catalog.outputs.append(TaskMediaOutputVersion(
                lineageId: output.lineage.id, version: 1,
                fileName: output.displayFileName, sourceRevisionIds: [],
                attachmentId: "att-\(index).mov",
                remoteURL: URL(string: "https://files.test/\(index).mov")))
        }
        return catalog
    }

    private func asset(_ name: String, in catalog: TaskMediaCatalog) -> TaskMediaAsset {
        catalog.assets.first { $0.displayName == name }!
    }

    private func combo(_ hook: String, _ body: String, in catalog: TaskMediaCatalog) -> String {
        TaskMediaOutputLineage.combination(hook: asset(hook, in: catalog).id,
                                           body: asset(body, in: catalog).id).id
    }

    func testRemovingOneCombinationKeepsItsSources() throws {
        let catalog = try publishedCatalog()
        let lineage = combo("H1", "B1", in: catalog)
        let next = catalog.removing(lineageIds: [lineage])

        XCTAssertFalse(next.lineages.contains { $0.id == lineage })
        XCTAssertFalse(next.outputs.contains { $0.lineageId == lineage })
        // H1 ainda não tem outra combinação, então sai; B1 segue em H2+B1.
        XCTAssertNil(next.assets.first { $0.displayName == "H1" })
        XCTAssertNotNil(next.assets.first { $0.displayName == "B1" })
        XCTAssertEqual(next.outputs.count, catalog.outputs.count - 1)
        XCTAssertEqual(next.sequence, catalog.sequence + 1)
    }

    func testRemovingASourceTakesEveryCombinationWithIt() throws {
        let catalog = try publishedCatalog()
        let body = asset("B1", in: catalog)
        XCTAssertEqual(catalog.lineageIds(dependingOn: [body.id]).count, 2)

        let next = catalog.removing(lineageIds: [], assetIds: [body.id])

        XCTAssertTrue(next.lineages.allSatisfy { !$0.isComposition })
        // Sem BODY, os HOOKs ficaram sem vídeo nenhum e saem também.
        XCTAssertEqual(next.assets.map(\.displayName), ["POV"])
        XCTAssertEqual(next.outputs.count, 1)
    }

    func testRemovedAttachmentIsNotImportedBackAsLegacyVideo() throws {
        let catalog = try publishedCatalog()
        let pov = catalog.outputs.first { $0.fileName.hasPrefix("POV") }!
        var next = catalog.removing(
            lineageIds: catalog.lineageIds(forAttachmentIds: [pov.attachmentId!]))
        XCTAssertNil(next.outputs.first { $0.id == pov.id })
        XCTAssertNil(next.assets.first { $0.displayName == "POV" })
        XCTAssertTrue(next.isRemoved(attachmentId: pov.attachmentId!))

        // O arquivo continua na tarefa do ClickUp e volta na próxima leitura.
        let stillOnClickUp = CUTask.Attachment(
            id: pov.attachmentId!, title: pov.fileName, url: pov.remoteURL!.absoluteString,
            ext: "mov", sizeString: nil, totalComments: nil, resolvedComments: nil,
            uploaderId: nil)
        XCTAssertEqual(next.importLegacyVideoAttachments([stillOnClickUp]), 0)
        XCTAssertNil(next.outputs.first { $0.attachmentId == pov.attachmentId })
    }

    func testReplacingTheBodyDoesNotResurrectARemovedCombination() throws {
        let catalog = try publishedCatalog()
        let removed = combo("H1", "B1", in: catalog)
        // Mantém o H1 vivo com outra combinação, para o teste valer.
        var withH1 = catalog.removing(lineageIds: [removed])
        XCTAssertEqual(withH1.removedLineageIds, [removed])
        withH1.assets.append(asset("H1", in: catalog))

        let body = asset("B1", in: withH1)
        let plan = try TaskMediaPlanner.replacing(
            replacements: [body.id: selection("B1 nova", .body)], in: withH1)

        XCTAssertFalse(plan.outputs.contains { $0.lineage.id == removed })
        XCTAssertTrue(plan.outputs.contains { $0.lineage.id == combo("H2", "B1", in: withH1) })
    }

    func testLooseAttachmentIsOnlyHidden() throws {
        let catalog = try publishedCatalog()
        let next = catalog.removing(lineageIds: [], hiddenAttachmentIds: ["briefing.pdf"])
        XCTAssertEqual(next.outputs, catalog.outputs)
        XCTAssertTrue(next.isRemoved(attachmentId: "briefing"))
    }

    func testManifestFromEarlierBuildStillDecodes() throws {
        let catalog = try publishedCatalog()
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog)) as? [String: Any])
        json.removeValue(forKey: "removedAttachmentIds")
        json.removeValue(forKey: "removedLineageIds")
        let decoded = try JSONDecoder().decode(
            TaskMediaCatalog.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.removedAttachmentIds)
        XCTAssertFalse(decoded.isRemoved(attachmentId: "att-0"))
    }

    func testOldVersionAloneOnlyHidesThatVersion() throws {
        var catalog = try publishedCatalog()
        let pov = catalog.outputs.first { $0.fileName.hasPrefix("POV") }!
        catalog.outputs.append(TaskMediaOutputVersion(
            lineageId: pov.lineageId, version: 2, fileName: "POV · V2.mov",
            sourceRevisionIds: [], attachmentId: "pov-v2.mov",
            remoteURL: URL(string: "https://files.test/pov-v2.mov")))

        // A V1 sozinha não fala pela linhagem: só ela some.
        XCTAssertTrue(catalog.lineageIds(forAttachmentIds: [pov.attachmentId!]).isEmpty)
        let hidden = catalog.removing(lineageIds: [], hiddenAttachmentIds: [pov.attachmentId!])
        XCTAssertEqual(hidden.latestOutput(for: pov.lineageId)?.version, 2)
        XCTAssertTrue(hidden.isRemoved(attachmentId: pov.attachmentId!))

        // A mais nova leva a linhagem inteira, V1 incluída.
        let lineage = catalog.lineageIds(forAttachmentIds: ["pov-v2.mov"])
        XCTAssertEqual(lineage, [pov.lineageId])
        let gone = catalog.removing(lineageIds: lineage)
        XCTAssertTrue(gone.isRemoved(attachmentId: pov.attachmentId!))
        XCTAssertTrue(gone.isRemoved(attachmentId: "pov-v2"))
    }

    func testDisplayedAttachmentsDropRemovedOnes() throws {
        let catalog = try publishedCatalog()
        let pov = catalog.outputs.first { $0.fileName.hasPrefix("POV") }!
        let next = catalog.removing(lineageIds: [pov.lineageId])
        var task = CUTask(id: "task-\(UUID().uuidString)", title: "Tarefa",
                          status: "a editar", statusColor: "#F8AE00", priority: 3,
                          priorityColor: "#9E9E9E", startDate: nil, dueDate: nil,
                          listId: "lista", listName: "Video", isCompleted: false)
        task.attachments = catalog.outputs.map {
            CUTask.Attachment(id: $0.attachmentId!, title: $0.fileName,
                              url: $0.remoteURL!.absoluteString, ext: "mov", sizeString: nil,
                              totalComments: nil, resolvedComments: nil, uploaderId: nil)
        }
        XCTAssertEqual(task.displayedAttachments(catalog: catalog).count, 3)
        XCTAssertEqual(task.displayedAttachments(catalog: next).map(\.title),
                       catalog.outputs.filter { $0.id != pov.id }.map(\.fileName))
    }

    /// Lote preparado antes da lixeira: ao gravar, o que saiu continua fora
    /// e a sequência passa à frente, senão o manifest antigo venceria.
    func testSendPreparedBeforeARemovalKeepsItRemoved() throws {
        let base = try publishedCatalog()
        let pov = base.outputs.first { $0.fileName.hasPrefix("POV") }!
        let removedElsewhere = base.removing(lineageIds: [pov.lineageId])

        var staleCommit = base           // o plano copiou o catálogo de antes
        staleCommit.sequence += 1        // o envio sobe a sequência como sempre
        XCTAssertEqual(staleCommit.sequence, removedElsewhere.sequence)

        let merged = staleCommit.carryingRemovals(from: removedElsewhere)
        XCTAssertNil(merged.outputs.first { $0.lineageId == pov.lineageId })
        XCTAssertTrue(merged.isRemoved(attachmentId: pov.attachmentId!))
        XCTAssertEqual(merged.removedLineageIds, [pov.lineageId])
        XCTAssertGreaterThan(merged.sequence, removedElsewhere.sequence)
        // Combinações que não foram tocadas seguem lá.
        XCTAssertEqual(merged.outputs.count, base.outputs.count - 1)
    }

    func testSendWithoutRemovalsOnlyMovesSequenceAhead() throws {
        let base = try publishedCatalog()
        var newer = base
        newer.sequence = 9
        let merged = base.carryingRemovals(from: newer)
        XCTAssertEqual(merged.outputs, base.outputs)
        XCTAssertNil(merged.removedAttachmentIds)
        XCTAssertEqual(merged.sequence, 10)
    }

    /// HOOK removido por alguém enquanto outra pessoa preparava um BODY
    /// novo: a combinação nova não pode trazer o HOOK de volta.
    func testNewCombinationDoesNotBringBackARemovedSource() throws {
        let base = try publishedCatalog()
        let h1 = asset("H1", in: base)
        let removedElsewhere = base.removing(lineageIds: [], assetIds: [h1.id])
        XCTAssertTrue(removedElsewhere.removedAssetIds?.contains(h1.id) == true)

        let plan = try TaskMediaPlanner.adding(selections: [selection("B2", .body)], to: base)
        XCTAssertTrue(plan.outputs.contains { $0.lineage.hookAssetId == h1.id })
        var commit = plan.catalog
        for output in plan.outputs {
            commit.outputs.append(TaskMediaOutputVersion(
                lineageId: output.lineage.id, version: 1, fileName: output.displayFileName,
                sourceRevisionIds: [], attachmentId: "new-\(output.lineage.id)"))
        }
        let merged = commit.carryingRemovals(from: removedElsewhere)
        XCTAssertNil(merged.asset(id: h1.id))
        XCTAssertFalse(merged.lineages.contains { $0.hookAssetId == h1.id })
        XCTAssertTrue(merged.isRemoved(attachmentId: "new-" + TaskMediaOutputLineage
            .combination(hook: h1.id, body: asset("B2", in: plan.catalog).id).id))
    }
}
