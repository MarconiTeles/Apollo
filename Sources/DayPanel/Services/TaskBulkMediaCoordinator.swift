import Foundation

// Apollo · Envio de arquivo(s) para várias tarefas de uma vez.
//
// O trabalho pesado (upload, comentário final, REVISAR, versionamento,
// retry) já existe em `TaskMediaTransferStore`, e ele é indexado por
// tarefa — `batches: [String: BatchState]`. Então o lote NÃO é um motor
// de transferência novo: é um orquestrador que roda o fluxo de sempre,
// uma tarefa por vez, e agrega o estado das várias.
//
// Isso é deliberado. Qualquer caminho paralelo aqui significaria dois
// fluxos de publicação diferentes convivendo, e a primeira divergência
// entre eles seria um bug que o usuário sente e não sabe explicar.
//
// Duas regras do fluxo single que o lote herda por construção:
//
//   1. Publicação é SERIAL. Enviar em paralelo fez o ClickUp associar
//      dois arquivos ao mesmo comentário, deixando o outro sem anexo
//      (ver o comentário em `publishOutputs`). Serial entre tarefas
//      pela mesma razão.
//   2. Comentário só nasce depois do anexo existir e ser confirmado
//      relendo o servidor.
@MainActor
final class TaskBulkMediaCoordinator: ObservableObject {

    // MARK: - Projeção
    //
    // O mesmo arquivo, com o mesmo papel, NÃO tem o mesmo efeito em
    // todas as tarefas: o planner combina o que chega com o que a
    // tarefa já tem no catálogo. Um HOOK novo numa tarefa com 3 BODYs
    // gera 3 vídeos; na tarefa ao lado, que não tem BODY nenhum, o
    // planner LANÇA erro (`missingCounterpart`).
    //
    // Quem está enviando não tem como saber disso de cabeça, então a
    // projeção roda o planner a seco antes de qualquer byte subir e
    // diz, por tarefa, quantos vídeos saem — ou por que aquela tarefa
    // está de fora.

    struct Target: Identifiable {
        let task: CUTask
        /// Quantos vídeos esta tarefa vai produzir com o que foi escolhido.
        var projectedOutputs: Int = 0
        /// Preenchido quando o planner recusa esta tarefa. A tarefa
        /// continua listada (o usuário precisa VER que ficou de fora)
        /// mas não entra no envio.
        var blockedReason: String?
        /// Progresso 0…1 desta tarefa durante o envio.
        var progress: Double = 0
        var phase: TaskMediaTransferStore.Phase?
        var failureMessage: String?

        var id: String { task.id }
        var isSendable: Bool { blockedReason == nil && projectedOutputs > 0 }
    }

    enum Phase: Equatable {
        case idle
        case projecting
        case sending
        case done
        /// Pelo menos uma tarefa não completou. As que completaram ficam
        /// como estão — o retry só reprocessa as pendentes.
        case partialFailure
    }

    @Published private(set) var targets: [Target] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var errorMessage: String?

    /// Seleções já hasheadas, POR TAREFA.
    ///
    /// Deixou de ser uma lista única no momento em que cada tarefa passou
    /// a poder receber o arquivo com papel e corte próprios: o mesmo
    /// vídeo pode ser HOOK cortado de um jeito numa tarefa e BODY cortado
    /// de outro na vizinha. São arquivos diferentes para o planner, com
    /// hashes diferentes, e precisam ser resolvidos tarefa a tarefa.
    private(set) var resolvedSelections: [String: [TaskMediaSelection]] = [:]

    /// Cache de SHA-256 por caminho de arquivo. Sem ele, um vídeo usado
    /// sem alteração em oito tarefas seria lido do disco oito vezes.
    private var hashCache: [URL: String] = [:]

    private let store: TaskMediaTransferStore

    init(store: TaskMediaTransferStore) {
        self.store = store
    }

    // MARK: - Totais para o rodapé

    var sendableTargets: [Target] { targets.filter(\.isSendable) }
    var blockedTargets: [Target] { targets.filter { $0.blockedReason != nil } }
    /// Soma dos vídeos que serão produzidos. É também o número de
    /// renderizações E de uploads — cada saída é um arquivo próprio,
    /// porque o ClickUp trata anexo como propriedade da tarefa e não
    /// existe compartilhar o mesmo anexo entre tarefas.
    var totalOutputs: Int { sendableTargets.reduce(0) { $0 + $1.projectedOutputs } }

    var overallProgress: Double {
        let sendable = sendableTargets
        guard !sendable.isEmpty else { return 0 }
        return sendable.reduce(0) { $0 + $1.progress } / Double(sendable.count)
    }

    // MARK: - Montagem

    /// Carrega o catálogo de cada tarefa ANTES de existir arquivo.
    ///
    /// Roda enquanto a pessoa ainda está escolhendo o vídeo, para a tela
    /// seguinte abrir com as tarefas já listadas — em vez de aparecer
    /// vazia e só depois preencher. Sem seleções não há projeção: os
    /// alvos nascem só com a tarefa, e o `projectedOutputs` chega no
    /// `project(...)`.
    func warmUp(tasks: [CUTask], appState: AppState) async {
        phase = .projecting
        var built: [Target] = []
        for task in tasks {
            await store.loadCatalog(for: task, appState: appState)
            built.append(Target(task: task))
        }
        targets = built
        phase = .idle
    }

    /// Recalcula a projeção. `selectionsFor` devolve o que CADA tarefa
    /// vai receber de fato — já com o papel e o corte que aquela tarefa
    /// escolheu, ou o padrão quando ela não divergiu.
    ///
    /// Chamado ao abrir a folha e a cada mudança: trocar papel (global ou
    /// de uma tarefa), cortar, adicionar/remover vídeo ou tarefa.
    func project(tasks: [CUTask],
                 selectionsFor: (CUTask) -> [TaskMediaSelection],
                 appState: AppState) async {
        phase = .projecting
        errorMessage = nil

        var built: [Target] = []
        var resolved: [String: [TaskMediaSelection]] = [:]

        for task in tasks {
            await store.loadCatalog(for: task, appState: appState)
            var target = Target(task: task)
            let wanted = selectionsFor(task)
            do {
                let hashed = try await hashing(wanted)
                resolved[task.id] = hashed
                let plan = try TaskMediaPlanner.adding(selections: hashed,
                                                       to: store.catalog(for: task.id))
                target.projectedOutputs = plan.outputs.count
                if plan.outputs.isEmpty {
                    target.blockedReason = "Nada novo a gerar nesta tarefa."
                }
            } catch {
                target.blockedReason = error.localizedDescription
            }
            built.append(target)
        }

        resolvedSelections = resolved
        targets = built
        phase = .idle
    }

    /// Hasheia reaproveitando o cache por arquivo. Dois cortes diferentes
    /// do mesmo vídeo são arquivos diferentes e recebem hashes diferentes
    /// — é assim que o planner enxerga a variação de cada tarefa.
    private func hashing(_ selections: [TaskMediaSelection]) async throws
    -> [TaskMediaSelection] {
        let pending = selections.filter { hashCache[$0.fileURL] == nil }
        if !pending.isEmpty {
            for hashed in try await store.hash(pending) {
                hashCache[hashed.fileURL] = hashed.contentHash
            }
        }
        return selections.map { selection in
            var copy = selection
            copy.contentHash = hashCache[selection.fileURL]
            return copy
        }
    }

    // MARK: - Envio

    /// Roda o fluxo de sempre, tarefa por tarefa, em série.
    ///
    /// `extraMentionMemberIds` são as pessoas que o usuário escolheu
    /// mencionar em TODAS as tarefas. Além delas, cada tarefa menciona
    /// os próprios responsáveis — assim ninguém é notificado de tarefa
    /// que não é sua só porque entrou no mesmo lote.
    func sendAll(extraMentionMemberIds: [Int], appState: AppState) async {
        guard !sendableTargets.isEmpty else { return }
        phase = .sending
        errorMessage = nil

        for index in targets.indices where targets[index].isSendable {
            // Pula o que já concluiu — permite que "Tentar novamente"
            // reprocesse só as pendentes, sem reenviar o que deu certo.
            if targets[index].phase == .sent { continue }

            let task = targets[index].task
            let mentions = mentionIds(for: task, extra: extraMentionMemberIds)

            // Cada tarefa recebe a SUA variação — papel e corte próprios
            // quando ela divergiu do padrão.
            let taskSelections = resolvedSelections[task.id] ?? []
            guard !taskSelections.isEmpty else { continue }
            await store.prepareAdd(task: task, selections: taskSelections,
                                   appState: appState)
            if store.phase(for: task.id) == .failed {
                targets[index].phase = .failed
                targets[index].failureMessage = storeError(for: task.id)
                continue
            }

            await store.send(task: task, mentionMemberIds: mentions, appState: appState)

            let resulting = store.phase(for: task.id)
            targets[index].phase = resulting
            targets[index].progress = store.progress(for: task.id)
            targets[index].failureMessage = (resulting == .sent) ? nil : storeError(for: task.id)
        }

        let pending = sendableTargets.contains { $0.phase != .sent }
        phase = pending ? .partialFailure : .done
    }

    /// `Phase` não carrega valor associado — o motivo da falha fica em
    /// `BatchState.errorMessage`, que o store publica como leitura.
    private func storeError(for taskId: String) -> String? {
        store.batches[taskId]?.errorMessage
    }

    /// Menções desta tarefa: responsáveis dela + os escolhidos para todas.
    /// Deduplicado, porque mencionar a mesma pessoa duas vezes no mesmo
    /// comentário rende duas notificações.
    private func mentionIds(for task: CUTask, extra: [Int]) -> [Int] {
        var seen = Set<Int>()
        return (task.assignees.map(\.id) + extra).filter { seen.insert($0).inserted }
    }

    /// Descarta os lotes preparados em todas as tarefas de destino.
    func discardAll() {
        for target in targets { store.discard(taskId: target.task.id) }
        targets = targets.map { existing in
            var copy = existing
            copy.progress = 0
            copy.phase = nil
            copy.failureMessage = nil
            return copy
        }
        phase = .idle
    }
}
