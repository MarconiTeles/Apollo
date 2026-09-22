import XCTest
@testable import ApolloRuntime

/// Regras de destino do envio em lote.
///
/// O defeito que originou estes testes: `nil` significava tanto "vale
/// para todas" quanto "sem destino", e um sinalizador decidia qual. Com
/// o roteamento ligado, um arquivo mostrado na tela como "Todas as
/// tarefas" era excluído de TODAS na hora de enviar. A tela prometia
/// uma coisa e o envio fazia outra.
final class TaskMediaRoutingTests: XCTestCase {

    private func task(_ id: String, _ title: String) -> CUTask {
        CUTask(id: id, title: title, status: "a editar", statusColor: "#F8AE00",
               priority: 3, priorityColor: "#9E9E9E", startDate: nil, dueDate: nil,
               listId: "L", listName: "Video", isCompleted: false)
    }

    private func file(_ name: String) -> TaskMediaRouting.File {
        .init(id: UUID(), name: name)
    }

    private var tasks: [CUTask] {
        [task("t1", "Camiseta 1.0 - Réplica Airton"),
         task("t2", "Balda - Camiseta 1.0 - Unboxing"),
         task("t3", "Calça Comfort - Black Friday - Galpão")]
    }

    // MARK: - "Todas" significa todas

    /// O caso central da regressão: um arquivo marcado como "todas"
    /// convivendo com outro roteado para uma tarefa específica. O
    /// primeiro tem que chegar em TODAS as três.
    func testAllReachesEveryTaskEvenWhenOtherFilesAreRouted() {
        let shared = file("ABERTURA_PADRAO - VIDEO.mp4")
        let routed = file("REPLICA_AIRTON - H1.mp4")
        let files = [shared, routed]

        let destinations = TaskMediaRouting.resolve(
            files: files, tasks: tasks, decided: [shared.id: .all])

        XCTAssertEqual(destinations[shared.id], .all)
        XCTAssertEqual(destinations[routed.id], .task("t1"))

        for id in tasks.map(\.id) {
            XCTAssertTrue(
                TaskMediaRouting.recipients(of: id, files: files,
                                            destinations: destinations).contains(shared.id),
                "o arquivo 'todas' tem que chegar em \(id)")
        }
    }

    /// E a tarefa roteada recebe os dois: o dela e o de todas.
    func testRoutedTaskAlsoReceivesTheAllFile() {
        let shared = file("ABERTURA_PADRAO - VIDEO.mp4")
        let routed = file("REPLICA_AIRTON - H1.mp4")
        let files = [shared, routed]
        let destinations = TaskMediaRouting.resolve(
            files: files, tasks: tasks, decided: [shared.id: .all])

        let received = TaskMediaRouting.recipients(of: "t1", files: files,
                                                   destinations: destinations)
        XCTAssertEqual(Set(received), Set([shared.id, routed.id]))
    }

    /// Sem nenhum arquivo identificado, a tela é a de sempre: tudo para
    /// todas. Esse é o fluxo original e não pode ter regredido.
    func testWithoutAnyMatchEverythingGoesToAllTasks() {
        let files = [file("WhatsApp Video 2026-09-19.mp4"), file("IMG_4821.mov")]
        let destinations = TaskMediaRouting.resolve(files: files, tasks: tasks, decided: [:])

        for file in files {
            XCTAssertEqual(destinations[file.id], .all)
            for id in tasks.map(\.id) {
                XCTAssertTrue((destinations[file.id] ?? .all).reaches(id))
            }
        }
    }

    // MARK: - Pendência

    /// Com o lote roteado, quem não casou vira pendência — e NÃO é
    /// empurrado para todas as tarefas.
    func testUnmatchedBecomesUnresolvedOnceSomethingIsRouted() {
        let routed = file("REPLICA_AIRTON - H1.mp4")
        let orphan = file("IMG_4821.mov")
        let destinations = TaskMediaRouting.resolve(
            files: [routed, orphan], tasks: tasks, decided: [:])

        XCTAssertEqual(destinations[routed.id], .task("t1"))
        XCTAssertEqual(destinations[orphan.id], .unresolved)
        for id in tasks.map(\.id) {
            XCTAssertFalse((destinations[orphan.id] ?? .all).reaches(id))
        }
    }

    /// Tirar um vídeo de um cartão é decisão da pessoa e o casamento
    /// automático não pode desfazê-la — mesmo que o nome continue
    /// apontando para aquela tarefa. Era o ✕ que parecia não funcionar.
    func testRemovalSurvivesTheAutomaticMatcher() {
        let removed = file("REPLICA_AIRTON - H1.mp4")
        let destinations = TaskMediaRouting.resolve(
            files: [removed], tasks: tasks, decided: [removed.id: .unresolved])
        XCTAssertEqual(destinations[removed.id], .unresolved)
    }

    /// Escolher "todas" à mão também sobrevive ao casador, mesmo com o
    /// nome batendo com uma tarefa.
    func testManualAllSurvivesTheAutomaticMatcher() {
        let chosen = file("REPLICA_AIRTON - H1.mp4")
        let destinations = TaskMediaRouting.resolve(
            files: [chosen], tasks: tasks, decided: [chosen.id: .all])
        XCTAssertEqual(destinations[chosen.id], .all)
    }

    // MARK: - Tarefa que sai da lista

    /// Remover a tarefa de destino não pode deixar o arquivo apontando
    /// para o vazio: vira pendência, visível e bloqueante.
    func testDestinationPointingToARemovedTaskBecomesUnresolved() {
        let orphan = file("REPLICA_AIRTON - H1.mp4")
        let remaining = [task("t2", "Balda - Camiseta 1.0 - Unboxing"),
                         task("t3", "Calça Comfort - Black Friday - Galpão")]
        let destinations = TaskMediaRouting.resolve(
            files: [orphan], tasks: remaining, decided: [orphan.id: .task("t1")])
        XCTAssertEqual(destinations[orphan.id], .unresolved)
    }

    // MARK: - Uma tarefa só

    /// Com menos de duas tarefas não há o que rotear: tudo vale para a
    /// única, e nada pode ficar pendente à toa.
    func testSingleTaskLeavesNothingPending() {
        let files = [file("IMG_4821.mov"), file("REPLICA_AIRTON - H1.mp4")]
        let destinations = TaskMediaRouting.resolve(
            files: files, tasks: [task("t1", "Camiseta 1.0 - Réplica Airton")], decided: [:])
        for file in files {
            XCTAssertFalse((destinations[file.id] ?? .all).isUnresolved)
            XCTAssertTrue((destinations[file.id] ?? .all).reaches("t1"))
        }
    }
    func testAmbiguousFileRequiresExplicitDestinationEvenWhenNothingElseMatches() {
        let ambiguousTasks = [task("a", "Camiseta 1.0 - Réplica Airton - B1 - H5"),
                              task("b", "Camiseta 1.0 - Réplica Airton 2 - B1 - H5")]
        let ambiguous = file("H4_REPLICA_BALDA_AIRTON_V02.mov")
        let unrelated = file("IMG_4821.mov")
        let result = TaskMediaRouting.resolve(files: [ambiguous, unrelated],
                                             tasks: ambiguousTasks, decided: [:])
        XCTAssertEqual(result[ambiguous.id], .unresolved)
        XCTAssertEqual(result[unrelated.id], .unresolved)
        for target in ambiguousTasks {
            XCTAssertTrue(TaskMediaRouting.recipients(of: target.id,
                files: [ambiguous, unrelated], destinations: result).isEmpty)
        }
        let manual = TaskMediaRouting.resolve(files: [ambiguous], tasks: ambiguousTasks,
                                             decided: [ambiguous.id: .all])
        XCTAssertEqual(manual[ambiguous.id], .all)
    }

    func testRemovingDestinationDoesNotRedirectToLastRemainingTask() {
        let dropped = file("REPLICA_AIRTON - H1.mp4")
        let result = TaskMediaRouting.resolve(files: [dropped], tasks: [tasks[2]],
                                             decided: [dropped.id: .task("t1")])
        XCTAssertEqual(result[dropped.id], .unresolved)
        XCTAssertTrue(TaskMediaRouting.recipients(of: "t3", files: [dropped],
                                                  destinations: result).isEmpty)
    }

    func testExplicitUnresolvedSurvivesWithOneTask() {
        let dropped = file("IMG_4821.mov")
        let result = TaskMediaRouting.resolve(files: [dropped], tasks: [tasks[0]],
                                             decided: [dropped.id: .unresolved])
        XCTAssertEqual(result[dropped.id], .unresolved)
    }

}
