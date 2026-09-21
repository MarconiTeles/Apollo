import XCTest
@testable import ApolloRuntime

/// Casamento de nome de arquivo com nome de tarefa.
///
/// As tarefas e os arquivos deste teste são REAIS, colhidos da lista
/// Video (Marketing | Minimal) em 20/09/2026. Não são exemplos
/// inventados: se a nomenclatura do time mudar, é aqui que a mudança
/// aparece primeiro, e é aqui que se decide o que fazer com ela.
final class TaskMediaNameMatcherTests: XCTestCase {

    private func task(_ id: String, _ title: String) -> CUTask {
        CUTask(id: id,
               title: title,
               status: "a editar",
               statusColor: "#F8AE00",
               priority: 3,
               priorityColor: "#9E9E9E",
               startDate: nil,
               dueDate: nil,
               listId: "901304003682",
               listName: "Video",
               isCompleted: false)
    }

    /// Recorte real da lista Video.
    private var realTasks: [CUTask] {
        [
            task("t1", "Camiseta 1.0 - Réplica Airton 2 - B1 - H5"),
            task("t2", "Balda - Camiseta 1.0 - POV - 5H - B1"),
            task("t3", "Balda - Camiseta 1.0 - Unboxing - B1 - H5"),
            task("t4", "Alexandre - Camiseta - Bom x Ruim - 6H1B"),
            task("t5", "Camiseta 1.0 - Fernando - Comparativo - 5H-1B"),
            task("t6", "Camisa Social Tech - Black Friday - Ofertas - Escritório - B1 - 7H"),
            task("t7", "Calça Comfort - Black Friday - Ofertas - Galpão - B1 - 6H")
        ]
    }

    // MARK: - O caso central

    /// Arquivo real (`H4_REPLICA_BALDA_AIRTON_V02`) tem que cair na
    /// tarefa da Réplica Airton, não em nenhuma das outras seis.
    func testRealHookFileLandsOnItsTask() {
        let resolution = TaskMediaNameMatcher.resolve(
            fileName: "H4_REPLICA_BALDA_AIRTON_V02.mov", tasks: realTasks)
        XCTAssertEqual(resolution.best?.taskId, "t1")
    }

    /// O BODY da mesma pauta cai na mesma tarefa que os HOOKs — o papel
    /// não pode influenciar o destino.
    func testBodyAndHookOfSamePautaAgreeOnTheTask() {
        let hook = TaskMediaNameMatcher.resolve(
            fileName: "H1_REPLICA_BALDA_AIRTON_V01.mov", tasks: realTasks)
        let body = TaskMediaNameMatcher.resolve(
            fileName: "B1_REPLICA_BALDA_AIRTON_V01.mov", tasks: realTasks)
        XCTAssertEqual(hook.best?.taskId, body.best?.taskId)
    }

    /// Índice e versão diferentes do mesmo assunto não mudam o destino.
    func testIndexAndVersionDoNotChangeTheDestination() {
        let ids = ["H1_REPLICA_BALDA_AIRTON_V01.mov",
                   "H5_REPLICA_BALDA_AIRTON_V01.mov",
                   "H4_REPLICA_BALDA_AIRTON_V02.mov",
                   "B1_REPLICA_BALDA_AIRTON_V02.mov"]
            .map { TaskMediaNameMatcher.resolve(fileName: $0, tasks: realTasks).best?.taskId }
        XCTAssertEqual(Set(ids.compactMap { $0 }).count, 1)
    }

    // MARK: - O que NÃO pode virar sinal

    /// `H5`, `5H`, `6H1B`, `B1`, `V02` descrevem papel/contagem/versão e
    /// aparecem em quase todo nome dos dois lados. Se virassem sinal, o
    /// casamento seria decidido por ruído.
    func testStructuralTokensAreDiscarded() {
        let tokens = TaskMediaNameMatcher.tokens(
            of: "H4_REPLICA_BALDA_AIRTON_V02.mov")
        XCTAssertEqual(tokens.sorted(), ["airton", "balda", "mov", "replica"])

        let taskTokens = TaskMediaNameMatcher.tokens(
            of: "Alexandre - Camiseta - Bom x Ruim - 6H1B")
        XCTAssertFalse(taskTokens.contains("6h1b"))
    }

    /// Acento no título e caixa alta no arquivo não podem separar o que
    /// é a mesma palavra: "Réplica" ≡ "REPLICA".
    func testAccentAndCaseDoNotSeparateTheSameWord() {
        XCTAssertEqual(TaskMediaNameMatcher.tokens(of: "Réplica"),
                       TaskMediaNameMatcher.tokens(of: "REPLICA"))
    }

    /// "Camiseta" aparece em quase toda a lista, então não pode carregar
    /// o casamento sozinha: um arquivo que só divide essa palavra com as
    /// tarefas não rende uma sugestão confiável.
    func testWordCommonToAlmostEveryTaskDoesNotCarryAMatch() {
        let resolution = TaskMediaNameMatcher.resolve(
            fileName: "H1_CAMISETA_V01.mov", tasks: realTasks)
        XCTAssertFalse(resolution.isConfident)
    }

    // MARK: - Ambiguidade real da base

    /// Existem de fato duas tarefas "Réplica Airton" que diferem só por
    /// um "2" que o nome do arquivo não carrega. A informação não existe
    /// no arquivo, então nenhum algoritmo resolve — e adivinhar mandaria
    /// o vídeo para a tarefa errada de um cliente, sem desfazer (a API
    /// do ClickUp não apaga anexo). O sistema tem que PERGUNTAR.
    func testTwoNearIdenticalTasksAreReportedAsAmbiguous() {
        let tasks = [
            task("t1", "Camiseta 1.0 - Réplica Airton 2 - B1 - H5"),
            task("t2", "Camiseta 1.0 - Réplica Airton - B1 - H5"),
            task("t3", "Balda - Camiseta 1.0 - Unboxing - B1 - H5")
        ]
        let resolution = TaskMediaNameMatcher.resolve(
            fileName: "H4_REPLICA_BALDA_AIRTON_V02.mov", tasks: tasks)
        XCTAssertTrue(resolution.isAmbiguous)
        XCTAssertNil(resolution.suggestedTaskId,
                     "ambíguo não pode virar sugestão automática")
    }

    // MARK: - Sem correspondência

    /// Arquivo de fora da pauta não pode ser empurrado para a tarefa
    /// "menos pior" — sem sinal, sem sugestão.
    func testUnrelatedFileProducesNoSuggestion() {
        let resolution = TaskMediaNameMatcher.resolve(
            fileName: "WhatsApp Video 2026-09-19 at 01.31.04.mp4",
            tasks: realTasks)
        XCTAssertNil(resolution.suggestedTaskId)
    }

    func testEmptyTaskListIsHandled() {
        XCTAssertTrue(TaskMediaNameMatcher.rank(
            fileName: "H1_REPLICA_BALDA_AIRTON_V01.mov", tasks: []).isEmpty)
    }

    // MARK: - Regressão: o caso que falhou no app

    /// Tarefas que só diferem pelo número no fim — exatamente as de
    /// teste do Gabriel, e também "Réplica Airton" vs "Réplica Airton 2"
    /// na lista real. O número É o único sinal que separa as duas, então
    /// descartá-lo por ser curto faz todas empatarem e nenhuma ser
    /// sugerida — foi por isso que os vídeos foram para todas as tarefas.
    func testTrailingNumberDistinguishesOtherwiseIdenticalTasks() {
        let tasks = [
            task("t1", "TESTE LOTE 1"),
            task("t2", "TESTE LOTE 2"),
            task("t3", "TESTE LOTE 3"),
            task("t4", "TESTE LOTE 4")
        ]
        let resolution = TaskMediaNameMatcher.resolve(
            fileName: "TESTE LOTE 2 - H1.mp4", tasks: tasks)
        XCTAssertEqual(resolution.suggestedTaskId, "t2")
    }

    /// Mesmo princípio na base real.
    func testReplicaAirtonTwoIsDistinguishedWhenTheFileCarriesTheNumber() {
        let tasks = [
            task("t1", "Camiseta 1.0 - Réplica Airton 2 - B1 - H5"),
            task("t2", "Camiseta 1.0 - Réplica Airton - B1 - H5")
        ]
        let resolution = TaskMediaNameMatcher.resolve(
            fileName: "Camiseta 1.0 - Réplica Airton 2 - H3.mp4", tasks: tasks)
        XCTAssertEqual(resolution.suggestedTaskId, "t1")
    }

    // MARK: - Transparência

    /// A interface precisa poder dizer POR QUE sugeriu aquela tarefa.
    func testSharedTokensExplainTheMatch() {
        let ranked = TaskMediaNameMatcher.rank(
            fileName: "H4_REPLICA_BALDA_AIRTON_V02.mov", tasks: realTasks)
        let top = ranked.first
        XCTAssertNotNil(top)
        XCTAssertTrue(top!.sharedTokens.contains("airton"))
        XCTAssertTrue(top!.sharedTokens.contains("replica"))
    }
}

/// Detecção de papel (HOOK / BODY) pelo nome do arquivo, na convenção
/// que o time usa: `[Nome da tarefa] - [H ou B].mp4`.
final class TaskMediaRoleInferenceTests: XCTestCase {

    func testHookWithIndex() {
        XCTAssertEqual(TaskMediaRole.inferred(from: "TESTE LOTE 2 - H1.mp4"), .hook)
    }

    func testBodyWithIndex() {
        XCTAssertEqual(TaskMediaRole.inferred(from: "TESTE LOTE 2 - B1.mp4"), .body)
    }

    func testSpelledOutRoles() {
        XCTAssertEqual(TaskMediaRole.inferred(from: "TESTE LOTE 2 - hook.mp4"), .hook)
        XCTAssertEqual(TaskMediaRole.inferred(from: "TESTE LOTE 2 - body.mp4"), .body)
    }

    /// A convenção também admite a letra sozinha, sem número.
    func testBareLetterRoles() {
        XCTAssertEqual(TaskMediaRole.inferred(from: "TESTE LOTE 2 - H.mp4"), .hook)
        XCTAssertEqual(TaskMediaRole.inferred(from: "TESTE LOTE 2 - B.mp4"), .body)
    }

    /// Sem marca nenhuma continua sendo vídeo completo — nunca pode
    /// virar hook ou body por acidente.
    func testNoMarkerStaysUnclassifiedOrFullVideo() {
        XCTAssertNil(TaskMediaRole.inferred(from: "TESTE LOTE 2.mp4"))
        XCTAssertEqual(TaskMediaRole.inferred(from: "TESTE LOTE 2 - video.mp4"), .video)
    }
}
