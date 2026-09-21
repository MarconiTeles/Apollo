import XCTest
@testable import ApolloRuntime

/// Leitura da cota declarada no título da tarefa.
///
/// Todos os títulos abaixo são reais, da lista Video (Marketing |
/// Minimal). Os formatos variam porque quem escreve varia — o parser
/// precisa aguentar todos.
final class TaskMediaQuotaTests: XCTestCase {

    func testLetterBeforeNumber() {
        let quota = TaskMediaQuota.parse(title: "Camiseta 1.0 - Réplica Airton 2 - B1 - H5")
        XCTAssertEqual(quota.bodies, 1)
        XCTAssertEqual(quota.hooks, 5)
    }

    func testNumberBeforeLetter() {
        let quota = TaskMediaQuota.parse(title: "Balda - Camiseta 1.0 - POV - 5H - B1")
        XCTAssertEqual(quota.bodies, 1)
        XCTAssertEqual(quota.hooks, 5)
    }

    func testGluedCounts() {
        let quota = TaskMediaQuota.parse(title: "Alexandre - Camiseta - Bom x Ruim - 6H1B")
        XCTAssertEqual(quota.hooks, 6)
        XCTAssertEqual(quota.bodies, 1)
    }

    func testHyphenatedCounts() {
        let quota = TaskMediaQuota.parse(title: "Camiseta 1.0 - Fernando - Comparativo - 5H-1B")
        XCTAssertEqual(quota.hooks, 5)
        XCTAssertEqual(quota.bodies, 1)
    }

    func testSpelledOutHooks() {
        let quota = TaskMediaQuota.parse(title: "Camiseta Minimal — TOF — Jumanji (4 hooks)")
        XCTAssertEqual(quota.hooks, 4)
        XCTAssertNil(quota.bodies)
    }

    func testLargerCount() {
        let quota = TaskMediaQuota.parse(title: "2 Camiseta 1.0 - Black Friday - Ofertas - Escritório - B1 - 12H")
        XCTAssertEqual(quota.hooks, 12)
        XCTAssertEqual(quota.bodies, 1)
    }

    /// Tarefa que não declara cota não ganha limite inventado.
    func testTaskWithoutQuotaDeclaresNothing() {
        let quota = TaskMediaQuota.parse(title: "TESTE LOTE 1")
        XCTAssertTrue(quota.isEmpty)
        XCTAssertNil(quota.warning(hooks: 9, bodies: 9))
    }

    // MARK: - Aviso

    func testWithinQuotaProducesNoWarning() {
        let quota = TaskMediaQuota.parse(title: "Camiseta 1.0 - Réplica Airton - B1 - H5")
        XCTAssertNil(quota.warning(hooks: 5, bodies: 1))
        XCTAssertNil(quota.warning(hooks: 3, bodies: 1), "trazer menos que o pedido não é erro")
    }

    func testExceedingQuotaWarns() {
        let quota = TaskMediaQuota.parse(title: "Camiseta 1.0 - Réplica Airton - B1 - H5")
        let warning = quota.warning(hooks: 7, bodies: 2)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("7 hooks para 5"))
        XCTAssertTrue(warning!.contains("2 bodies para 1"))
    }
}
