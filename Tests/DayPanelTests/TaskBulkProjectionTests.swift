import XCTest
@testable import ApolloRuntime

/// Contrato da projeção do envio em lote.
///
/// A janela do lote promete ao usuário, ANTES de qualquer byte subir,
/// quantos vídeos cada tarefa vai gerar — ou por que ela ficou de fora.
/// Essa promessa é o planner rodando a seco contra o catálogo de cada
/// tarefa, e é fácil de quebrar sem perceber: o mesmo arquivo, com o
/// mesmo papel, tem efeito diferente em cada tarefa porque depende do
/// que ela já tem guardado.
///
/// Se algum destes testes cair, a janela passa a mentir para quem envia.
final class TaskBulkProjectionTests: XCTestCase {

    // MARK: - Fixtures

    private func selection(_ name: String, role: TaskMediaRole,
                           hash: String) -> TaskMediaSelection {
        TaskMediaSelection(fileURL: URL(fileURLWithPath: "/tmp/\(name)"),
                           role: role,
                           contentHash: hash)
    }

    private func asset(_ role: TaskMediaRole, name: String,
                       hash: String) -> TaskMediaAsset {
        let revision = TaskMediaRevision(number: 1,
                                         contentHash: hash,
                                         originalFileName: name)
        return TaskMediaAsset(role: role, displayName: name,
                              revisions: [revision],
                              activeRevisionId: revision.id)
    }

    private func catalog(taskId: String, assets: [TaskMediaAsset]) -> TaskMediaCatalog {
        var catalog = TaskMediaCatalog.empty(taskId: taskId)
        catalog.assets = assets
        return catalog
    }

    // MARK: - VIDEO direto

    /// O caso principal do lote: um vídeo pronto, sem composição. Ele não
    /// entra na matriz HOOK×BODY, então rende exatamente uma saída por
    /// tarefa — independente do que a tarefa já tenha.
    func testDirectVideoProducesExactlyOneOutputPerTask() throws {
        let file = selection("corte_final.mov", role: .video, hash: "hash-video")

        let emptyPlan = try TaskMediaPlanner.adding(
            selections: [file], to: .empty(taskId: "t1"))
        XCTAssertEqual(emptyPlan.outputs.count, 1)

        // Uma tarefa que já tem hook e body não muda o resultado de um
        // VIDEO direto — ele é uma linhagem própria, não combina com nada.
        let populated = catalog(taskId: "t2", assets: [
            asset(.hook, name: "hook antigo", hash: "hash-hook-antigo"),
            asset(.body, name: "body antigo", hash: "hash-body-antigo")
        ])
        let populatedPlan = try TaskMediaPlanner.adding(selections: [file], to: populated)
        XCTAssertEqual(populatedPlan.outputs.count, 1)
    }

    // MARK: - HOOK multiplica pelo que a tarefa já tem

    /// É por isso que a projeção existe. O MESMO hook, mandado para duas
    /// tarefas, gera quantidades diferentes: ele se combina com os BODYs
    /// que cada tarefa já tem. Quem envia não tem como saber isso de
    /// cabeça — a janela precisa dizer.
    func testHookMultipliesAgainstEachTaskExistingBodies() throws {
        let hook = selection("hook_novo.mp4", role: .hook, hash: "hash-hook-novo")

        let oneBody = catalog(taskId: "t1", assets: [
            asset(.body, name: "body A", hash: "hash-body-a")
        ])
        let threeBodies = catalog(taskId: "t2", assets: [
            asset(.body, name: "body A", hash: "hash-body-a"),
            asset(.body, name: "body B", hash: "hash-body-b"),
            asset(.body, name: "body C", hash: "hash-body-c")
        ])

        XCTAssertEqual(
            try TaskMediaPlanner.adding(selections: [hook], to: oneBody).outputs.count, 1)
        XCTAssertEqual(
            try TaskMediaPlanner.adding(selections: [hook], to: threeBodies).outputs.count, 3)
    }

    // MARK: - Tarefa que não pode receber

    /// Um HOOK numa tarefa sem nenhum BODY não tem com o que compor, e o
    /// planner recusa. No lote isso NÃO pode virar uma falha no meio do
    /// envio: tem que aparecer como "essa tarefa fica de fora" antes de
    /// começar, com as outras seguindo normalmente.
    func testHookIntoTaskWithoutBodyIsRejectedUpFront() {
        let hook = selection("hook_novo.mp4", role: .hook, hash: "hash-hook-novo")
        XCTAssertThrowsError(
            try TaskMediaPlanner.adding(selections: [hook], to: .empty(taskId: "t1"))
        ) { error in
            XCTAssertEqual(error as? TaskMediaPlannerError, .missingCounterpart(.body))
        }
    }

    /// Espelho do caso acima: BODY numa tarefa sem HOOK.
    func testBodyIntoTaskWithoutHookIsRejectedUpFront() {
        let body = selection("body_novo.mp4", role: .body, hash: "hash-body-novo")
        XCTAssertThrowsError(
            try TaskMediaPlanner.adding(selections: [body], to: .empty(taskId: "t1"))
        ) { error in
            XCTAssertEqual(error as? TaskMediaPlannerError, .missingCounterpart(.hook))
        }
    }

    /// Reenviar para uma tarefa que já recebeu aquele arquivo é recusado
    /// pelo SHA-256. No lote é um caso comum e legítimo — a pessoa
    /// seleciona cinco tarefas sem lembrar que duas já receberam o vídeo.
    /// Precisa sair como "já está nessa tarefa", não como erro de envio.
    func testFileAlreadyInTaskIsRejectedByHash() {
        let file = selection("corte_final.mov", role: .video, hash: "hash-video")
        let alreadyThere = catalog(taskId: "t1", assets: [
            asset(.video, name: "corte_final.mov", hash: "hash-video")
        ])
        XCTAssertThrowsError(
            try TaskMediaPlanner.adding(selections: [file], to: alreadyThere)
        ) { error in
            guard case .duplicateFiles = error as? TaskMediaPlannerError else {
                return XCTFail("esperado duplicateFiles, veio \(error)")
            }
        }
    }

    // MARK: - Vários arquivos de uma vez

    /// Dois VIDEOs diretos no mesmo envio rendem duas saídas por tarefa.
    /// O total do rodapé é a soma por tarefa, e é também o número de
    /// uploads — o ClickUp trata anexo como propriedade da tarefa, não
    /// existe compartilhar o mesmo anexo entre tarefas.
    func testMultipleDirectVideosSumPerTask() throws {
        let first = selection("um.mov", role: .video, hash: "hash-1")
        let second = selection("dois.mov", role: .video, hash: "hash-2")
        let plan = try TaskMediaPlanner.adding(selections: [first, second],
                                               to: .empty(taskId: "t1"))
        XCTAssertEqual(plan.outputs.count, 2)
    }

    /// Hook + body juntos, numa tarefa vazia: a matriz 1×1 fecha e sai um
    /// vídeo composto. Garante que mandar o par completo no mesmo lote não
    /// cai no `missingCounterpart`.
    func testHookAndBodyTogetherCloseTheMatrixOnAnEmptyTask() throws {
        let hook = selection("hook.mp4", role: .hook, hash: "hash-hook")
        let body = selection("body.mp4", role: .body, hash: "hash-body")
        let plan = try TaskMediaPlanner.adding(selections: [hook, body],
                                               to: .empty(taskId: "t1"))
        XCTAssertEqual(plan.outputs.count, 1)
    }
}
