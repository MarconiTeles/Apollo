import XCTest
@testable import ApolloRuntime

/// Sugestão de qual vídeo existente um arquivo arrastado substitui.
///
/// Clicando em ANEXAR numa tarefa que já tem vídeo, o app sempre
/// perguntou "adicionar ou substituir?". Arrastando, a pergunta era
/// pulada e o arquivo entrava sempre como novo — não havia como
/// substituir por arrasto. A sugestão abaixo alimenta essa pergunta.
final class TaskMediaReplacementSuggestionTests: XCTestCase {

    private let hookAirton = TaskMediaReplacementSuggestion.Asset(
        id: UUID(), name: "H1_REPLICA_BALDA_AIRTON_V01", role: .hook)
    private let bodyAirton = TaskMediaReplacementSuggestion.Asset(
        id: UUID(), name: "B1_REPLICA_BALDA_AIRTON_V01", role: .body)
    private let hookUnboxing = TaskMediaReplacementSuggestion.Asset(
        id: UUID(), name: "H1_UNBOXING_BALDA_V01", role: .hook)

    private var catalog: [TaskMediaReplacementSuggestion.Asset] {
        [hookAirton, bodyAirton, hookUnboxing]
    }

    /// Uma revisão nova do mesmo material aponta para o material antigo.
    func testNewRevisionSuggestsTheSameSource() {
        XCTAssertEqual(
            TaskMediaReplacementSuggestion.suggest(
                fileName: "H1_REPLICA_BALDA_AIRTON_V02.mov", among: catalog),
            hookAirton.id)
    }

    /// O papel é o primeiro filtro. Sem ele, o hook e o body da mesma
    /// pauta ficam com tokens idênticos (o H/B é descartado no
    /// casamento de assunto), empatam e a sugestão morreria num falso
    /// ambíguo — foi assim que este teste falhou da primeira vez.
    func testRoleDecidesBetweenHookAndBodyOfTheSameSubject() {
        XCTAssertEqual(
            TaskMediaReplacementSuggestion.suggest(
                fileName: "B1_REPLICA_BALDA_AIRTON_V02.mov", among: catalog),
            bodyAirton.id)
    }

    /// Assunto diferente não sugere substituição — o padrão é entrar
    /// como novo, nunca trocar algo por engano.
    func testUnrelatedSubjectSuggestsNothing() {
        XCTAssertNil(
            TaskMediaReplacementSuggestion.suggest(
                fileName: "H1_CALCA_COMFORT_GALPAO_V01.mov", among: catalog))
    }

    /// Papel sem candidato correspondente não inventa alvo: um vídeo
    /// completo não substitui um hook.
    func testRoleWithoutCounterpartSuggestsNothing() {
        XCTAssertNil(
            TaskMediaReplacementSuggestion.suggest(
                fileName: "REPLICA_BALDA_AIRTON - VIDEO.mov", among: catalog))
    }

    /// Arquivo sem marca de papel não tem como escolher alvo.
    func testFileWithoutRoleSuggestsNothing() {
        XCTAssertNil(
            TaskMediaReplacementSuggestion.suggest(
                fileName: "IMG_4821.mov", among: catalog))
    }

    /// Tarefa sem nada publicado não tem o que sugerir.
    func testEmptyCatalogSuggestsNothing() {
        XCTAssertNil(
            TaskMediaReplacementSuggestion.suggest(
                fileName: "H1_REPLICA_BALDA_AIRTON_V02.mov", among: []))
    }

    /// Dois candidatos do mesmo papel e igualmente parecidos: o app
    /// pergunta em vez de escolher um.
    func testEquallySimilarCandidatesStayUnsuggested() {
        let a = TaskMediaReplacementSuggestion.Asset(
            id: UUID(), name: "H1_REPLICA_AIRTON_CORTE_A", role: .hook)
        let b = TaskMediaReplacementSuggestion.Asset(
            id: UUID(), name: "H1_REPLICA_AIRTON_CORTE_B", role: .hook)
        XCTAssertNil(
            TaskMediaReplacementSuggestion.suggest(
                fileName: "H1_REPLICA_AIRTON_V02.mov", among: [a, b]))
    }

    /// Vídeo antigo importado do ClickUp vem como VIDEO genérico: o
    /// papel sai do nome, e o hook novo acha o hook da mesma pauta.
    func testLegacyGenericVideoTakesRoleFromItsName() {
        let airton = TaskMediaReplacementSuggestion.Asset(
            id: UUID(), name: "REPLICA_AIRTON - H2", role: .video)
        let calca = TaskMediaReplacementSuggestion.Asset(
            id: UUID(), name: "CALCA_COMFORT_GALPAO - VIDEO", role: .video)
        XCTAssertEqual(
            TaskMediaReplacementSuggestion.suggest(
                fileName: "REPLICA_AIRTON - H1.mp4", among: [calca, airton]),
            airton.id)
    }

    /// O caso que motivou a regra por nome: a única coisa em comum era
    /// a palavra VIDEO, e isso bastava para trocar o vídeo errado.
    func testSharingOnlyTheWordVideoSuggestsNothing() {
        let calca = TaskMediaReplacementSuggestion.Asset(
            id: UUID(), name: "CALCA_COMFORT_GALPAO - VIDEO", role: .video)
        XCTAssertNil(
            TaskMediaReplacementSuggestion.suggest(
                fileName: "SEM_RELACAO_NENHUMA - VIDEO.mp4", among: [calca]))
    }

    /// Nome parecido vence papel diferente: o body novo da pauta Airton
    /// troca o único vídeo da pauta Airton, mesmo ele sendo um hook.
    func testSimilarNameReplacesAcrossRoles() {
        let airton = TaskMediaReplacementSuggestion.Asset(
            id: UUID(), name: "REPLICA_AIRTON - H2", role: .video)
        let calca = TaskMediaReplacementSuggestion.Asset(
            id: UUID(), name: "CALCA_COMFORT_GALPAO - VIDEO", role: .video)
        XCTAssertEqual(
            TaskMediaReplacementSuggestion.suggest(
                fileName: "REPLICA_AIRTON - B1.mp4", among: [calca, airton]),
            airton.id)
    }

    /// Uma palavra em comum de três não é "parecido".
    func testPartialOverlapBelowHalfSuggestsNothing() {
        let unboxing = TaskMediaReplacementSuggestion.Asset(
            id: UUID(), name: "UNBOXING_BALDA_CAMISETA", role: .video)
        XCTAssertNil(
            TaskMediaReplacementSuggestion.suggest(
                fileName: "REPLICA_BALDA_AIRTON - VIDEO.mp4", among: [unboxing]))
    }
}
