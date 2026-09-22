import XCTest
@testable import ApolloRuntime

/// Decisão ao soltar arquivos numa tarefa que já tem vídeo.
///
/// O caso misto (uns substituem, outros entram novos) é o mais frágil:
/// o store guarda UM lote por tarefa, então as duas coisas não cabem na
/// mesma preparação. O risco é o arquivo sem alvo ser descartado em
/// silêncio — exatamente o tipo de perda que ninguém percebe na hora.
final class TaskMediaDropDecisionTests: XCTestCase {

    private func dropped(_ name: String) -> TaskMediaDropDecision.Dropped {
        .init(id: UUID(), url: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    // MARK: - Os três formatos de decisão

    func testNoChoiceMeansEverythingIsNew() {
        let files = [dropped("a.mp4"), dropped("b.mp4")]
        let plan = TaskMediaDropDecision.plan(dropped: files, choices: [:])
        XCTAssertTrue(plan.isPureAddition)
        XCTAssertEqual(Set(plan.leftovers), Set(files.map(\.id)))
        XCTAssertEqual(TaskMediaDropDecision.actionTitle(for: plan), "ADICIONAR COMO NOVOS")
    }

    func testEveryFileReplacingSomething() {
        let a = dropped("a.mp4"), b = dropped("b.mp4")
        let assetA = UUID(), assetB = UUID()
        let plan = TaskMediaDropDecision.plan(
            dropped: [a, b], choices: [a.id: assetA, b.id: assetB])
        XCTAssertTrue(plan.leftovers.isEmpty)
        XCTAssertEqual(plan.replacements[assetA], a.url)
        XCTAssertEqual(plan.replacements[assetB], b.url)
        XCTAssertEqual(TaskMediaDropDecision.actionTitle(for: plan), "SUBSTITUIR 2")
    }

    /// O caso que me preocupava: nenhum arquivo pode sumir.
    func testMixedKeepsBothSides() {
        let replacing = dropped("substitui.mp4")
        let brandNew = dropped("novo.mp4")
        let asset = UUID()
        let plan = TaskMediaDropDecision.plan(
            dropped: [replacing, brandNew],
            choices: [replacing.id: asset, brandNew.id: nil])

        XCTAssertTrue(plan.isMixed)
        XCTAssertEqual(plan.replacements[asset], replacing.url)
        XCTAssertEqual(plan.leftovers, [brandNew.id],
                       "o arquivo sem alvo tem que sobreviver para a etapa seguinte")
        XCTAssertEqual(TaskMediaDropDecision.actionTitle(for: plan),
                       "SUBSTITUIR 1 E ADICIONAR 1")
    }

    /// Nenhum arquivo solto pode desaparecer do plano, em qualquer
    /// combinação de escolhas.
    func testNoDroppedFileIsEverLost() {
        let files = (0..<5).map { dropped("v\($0).mp4") }
        let asset = UUID()
        let choices: [UUID: UUID?] = [
            files[0].id: asset,
            files[1].id: nil,
            files[3].id: UUID()
        ]
        let plan = TaskMediaDropDecision.plan(dropped: files, choices: choices)
        let accounted = plan.replacements.count + plan.leftovers.count
        XCTAssertEqual(accounted, files.count)
    }

    // MARK: - Escolha explícita de "não substituir"

    /// `nil` explícito e ausência do mapa querem dizer a mesma coisa —
    /// entra como novo — e nenhum dos dois pode virar substituição.
    func testExplicitNilAndMissingKeyBehaveTheSame() {
        let a = dropped("a.mp4"), b = dropped("b.mp4")
        let explicit = TaskMediaDropDecision.plan(dropped: [a], choices: [a.id: nil])
        let missing = TaskMediaDropDecision.plan(dropped: [b], choices: [:])
        XCTAssertEqual(explicit.leftovers.count, missing.leftovers.count)
        XCTAssertTrue(explicit.isPureAddition)
        XCTAssertTrue(missing.isPureAddition)
    }

    /// Two files cannot overwrite the same target. Keep the extra file as an
    /// addition so every input remains represented in the transaction.
    func testTwoFilesTargetingTheSameAssetKeepTheExtraFileAsAnAddition() {
        let a = dropped("a.mp4"), b = dropped("b.mp4")
        let asset = UUID()
        let plan = TaskMediaDropDecision.plan(
            dropped: [a, b], choices: [a.id: asset, b.id: asset])
        XCTAssertEqual(plan.replacements.count, 1)
        XCTAssertEqual(plan.replacements[asset], a.url)
        XCTAssertEqual(plan.leftovers, [b.id])
    }

    func testEmptyDropProducesEmptyPlan() {
        let plan = TaskMediaDropDecision.plan(dropped: [], choices: [:])
        XCTAssertTrue(plan.isPureAddition)
        XCTAssertTrue(plan.leftovers.isEmpty)
    }
}
