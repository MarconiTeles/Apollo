import Foundation

/// The four surfaces that own a sync-aware loading scene.
enum SyncLoadingScene: String, Codable, CaseIterable {
    case tasks
    case board
    case comments
    case inbox
}

/// Everything a loading scene may say, gathered from `AppState` and
/// `SyncJournal` into plain values so `SyncLoadingSnapshot.make` stays pure
/// and testable.
struct SyncLoadingInputs: Equatable {
    struct Status: Equatable {
        var name: String
        var color: String
    }

    var journal: [SyncJournal.Stage: SyncJournal.State] = [:]
    var streamedTasks = 0
    var startedAt: Date?
    var hasCompletedSync = false
    var lastSyncedAt: Date?
    var online = true
    /// Connected, but the ClickUp user id is still being resolved.
    var resolvingIdentity = false
    var workspaceName: String?
    var listName: String?
    var statuses: [Status] = []
    var commentsLoading = false
    var commentsScanned = 0
    var commentsTotal = 0
    var commentsFound = 0
    var commentsScanCap = 90

    func state(_ stage: SyncJournal.Stage) -> SyncJournal.State {
        journal[stage] ?? .pending
    }
}

/// The JSON document a scene renders (`web/apollo-loading/src/lib/types.ts`).
/// Every string is final pt-BR copy decided here, on the native side, so the
/// web scene only presents facts — it never invents progress.
struct SyncLoadingSnapshot: Encodable, Equatable {
    enum StepState: String, Encodable {
        case pending, active, done, failed, skipped
    }

    struct Step: Encodable, Equatable {
        var id: String
        var label: String
        var detail: String?
        var state: StepState
    }

    struct Metric: Encodable, Equatable {
        var value: Int
        var label: String
    }

    struct Column: Encodable, Equatable {
        var name: String
        var color: String
    }

    /// Determinate scan (comments): how far through the task window.
    struct Scan: Encodable, Equatable {
        var done: Int
        var target: Int
        var found: Int
    }

    /// Native geometry the scene must line up with (points, relative to the
    /// web view). Only the board needs it: its ghost cards sit exactly where
    /// the native columns will draw the real ones.
    struct Geometry: Encodable, Equatable {
        var top: Double
        var leading: Double
        var columnX: Double
        var columnWidth: Double
        var columnGap: Double
        var cardWidth: Double
    }

    var scene: SyncLoadingScene
    var headline: String
    var context: String?
    var steps: [Step]
    /// Fraction of the work known to be finished, 0…1.
    var progress: Double
    /// Upper bound the scene may ease toward while the active step runs —
    /// the next step boundary. Equal to `progress` when nothing is running.
    var ceiling: Double
    var metric: Metric?
    var columns: [Column] = []
    var scan: Scan?
    /// Epoch milliseconds, so JS can run its own clock.
    var startedAt: Double?
    var lastSyncedAt: Double?
    var online: Bool
    var geometry: Geometry?
    var theme: String = "dark"
    var accent: String = "#0A84FF"

    static func make(_ scene: SyncLoadingScene, _ input: SyncLoadingInputs) -> SyncLoadingSnapshot {
        let steps: [Step]
        let headline: String
        var context: String?
        var metric: Metric?
        var columns: [Column] = []
        var scan: Scan?

        let accountStep = Step(id: "account",
                               label: "Conta ClickUp",
                               detail: input.resolvingIdentity
                                   ? "Confirmando identidade"
                                   : input.workspaceName,
                               state: input.resolvingIdentity ? .active : .done)
        let receivedTasks = taskCount(input)

        switch scene {
        case .tasks:
            steps = [
                accountStep,
                Step(id: "structure", label: "Status da lista",
                     detail: structureDetail(input.state(.structure), noun: ("status", "status")),
                     state: stepState(input.state(.structure))),
                Step(id: "tasks", label: "Tarefas",
                     detail: tasksDetail(input.state(.tasks), received: receivedTasks),
                     state: stepState(input.state(.tasks))),
            ]
            headline = input.resolvingIdentity ? "Confirmando sua conta"
                : input.state(.structure) == .active ? "Lendo a estrutura da lista"
                : "Sincronizando tarefas"
            context = joined(input.workspaceName, input.listName)
            if let receivedTasks { metric = Metric(value: receivedTasks, label: plural(receivedTasks, "tarefa", "tarefas")) }
            columns = input.statuses.map { Column(name: $0.name, color: $0.color) }

        case .board:
            steps = [
                accountStep,
                Step(id: "structure", label: "Colunas",
                     detail: structureDetail(input.state(.structure), noun: ("coluna", "colunas")),
                     state: stepState(input.state(.structure))),
                Step(id: "tasks", label: "Cartões",
                     detail: tasksDetail(input.state(.tasks), received: receivedTasks,
                                         noun: ("recebido", "recebidos")),
                     state: stepState(input.state(.tasks))),
            ]
            headline = input.resolvingIdentity ? "Confirmando sua conta" : "Montando o quadro"
            context = joined(input.workspaceName, input.listName)
            if let receivedTasks { metric = Metric(value: receivedTasks, label: plural(receivedTasks, "cartão", "cartões")) }
            columns = input.statuses.map { Column(name: $0.name, color: $0.color) }

        case .comments:
            let target = min(input.commentsTotal, input.commentsScanCap)
            let scanned = input.commentsScanned
            let indexing = input.resolvingIdentity || input.commentsTotal == 0
            steps = [
                Step(id: "window", label: "Tarefas com atividade",
                     detail: input.commentsTotal > 0
                         ? "\(input.commentsTotal) \(plural(input.commentsTotal, "tarefa", "tarefas"))"
                         : "Ordenando por atividade recente",
                     state: indexing ? .active : .done),
                Step(id: "read", label: "Lendo conversas",
                     detail: target > 0 ? "\(scanned) de \(target)" : nil,
                     state: indexing ? .pending
                         : (input.commentsLoading ? .active : .done)),
                Step(id: "match", label: "Separando o que é seu",
                     detail: indexing ? nil
                         : "\(input.commentsFound) \(plural(input.commentsFound, "comentário", "comentários"))",
                     state: indexing ? .pending
                         : (input.commentsLoading ? .active : .done)),
            ]
            headline = input.resolvingIdentity ? "Confirmando sua conta" : "Lendo comentários"
            context = "Mais recentes primeiro"
            if target > 0 {
                scan = Scan(done: scanned, target: target, found: input.commentsFound)
            }
            metric = Metric(value: input.commentsFound,
                            label: plural(input.commentsFound, "encontrado", "encontrados"))

        case .inbox:
            let clickUp = input.state(.tasks)
            let calendar = input.state(.calendar)
            let changes = input.state(.changes)
            steps = [
                Step(id: "clickup", label: "ClickUp",
                     detail: sourceDetail(clickUp, count: receivedTasks, noun: ("tarefa", "tarefas")),
                     state: stepState(clickUp)),
                Step(id: "calendar", label: "Google Agenda",
                     detail: sourceDetail(calendar, count: count(of: calendar), noun: ("evento", "eventos")),
                     state: stepState(calendar)),
                Step(id: "changes", label: "Comparando alterações",
                     detail: changesDetail(changes, firstRun: !input.hasCompletedSync),
                     state: stepState(changes)),
            ]
            headline = input.online ? "Buscando novidades" : "Sem conexão"
            if let last = input.lastSyncedAt, last > .distantPast {
                context = "Última sincronização às \(Self.clock.string(from: last))"
            } else {
                context = "Primeira sincronização desta sessão"
            }
        }

        let (progress, ceiling) = progress(of: steps, scan: scan)
        return SyncLoadingSnapshot(scene: scene,
                                   headline: headline,
                                   context: context,
                                   steps: steps,
                                   progress: progress,
                                   ceiling: ceiling,
                                   metric: metric,
                                   columns: columns,
                                   scan: scan,
                                   startedAt: input.startedAt.map { $0.timeIntervalSince1970 * 1000 },
                                   lastSyncedAt: input.lastSyncedAt
                                       .flatMap { $0 > .distantPast ? $0.timeIntervalSince1970 * 1000 : nil },
                                   online: input.online)
    }

    // MARK: - Progress

    /// Each step owns an equal slice. Finished slices count fully; the active
    /// one contributes nothing yet but opens the ceiling to its end, so the
    /// scene can ease forward without ever claiming unfinished work. A
    /// determinate scan fills its own slice exactly.
    static func progress(of steps: [Step], scan: Scan?) -> (Double, Double) {
        let counted = steps.filter { $0.state != .skipped }
        guard !counted.isEmpty else { return (1, 1) }
        let slice = 1 / Double(counted.count)
        var progress = 0.0
        var ceiling = 0.0
        for step in counted {
            switch step.state {
            case .done, .failed, .skipped:
                progress += slice
            case .active:
                let start = progress
                if step.id == "read", let scan, scan.target > 0 {
                    progress += slice * min(1, Double(scan.done) / Double(scan.target))
                }
                ceiling = max(ceiling, start + slice * 0.92)
            case .pending:
                break
            }
        }
        progress = min(1, progress)
        return (progress, min(1, max(progress, ceiling)))
    }

    // MARK: - Copy

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func stepState(_ state: SyncJournal.State) -> StepState {
        switch state {
        case .pending: .pending
        case .active: .active
        case .done, .cached: .done
        case .failed: .failed
        case .skipped: .skipped
        }
    }

    private static func count(of state: SyncJournal.State) -> Int? {
        switch state {
        case let .done(count), let .cached(count): count
        default: nil
        }
    }

    /// Streamed pages while the fetch runs, the final count once it landed.
    private static func taskCount(_ input: SyncLoadingInputs) -> Int? {
        switch input.state(.tasks) {
        case .active: input.streamedTasks > 0 ? input.streamedTasks : nil
        case let .done(count), let .cached(count): count
        default: nil
        }
    }

    private static func structureDetail(_ state: SyncJournal.State,
                                        noun: (String, String)) -> String? {
        switch state {
        case .active: "Solicitando ao ClickUp"
        case let .done(count?): "\(count) \(plural(count, noun.0, noun.1))"
        case let .cached(count?): "\(count) \(plural(count, noun.0, noun.1)) · em cache"
        case .failed: "Falhou — tentando de novo em breve"
        default: nil
        }
    }

    private static func tasksDetail(_ state: SyncJournal.State,
                                    received: Int?,
                                    noun: (String, String) = ("recebida", "recebidas")) -> String? {
        switch state {
        case .active:
            if let received { "\(received) \(plural(received, noun.0, noun.1))…" } else { "Solicitando ao ClickUp" }
        case .done, .cached:
            received.map { "\($0) \(plural($0, noun.0, noun.1))" }
        case .failed: "Falhou — tentando de novo em breve"
        default: nil
        }
    }

    private static func sourceDetail(_ state: SyncJournal.State,
                                     count: Int?,
                                     noun: (String, String)) -> String? {
        switch state {
        case .pending: "Na fila"
        case .active: count.map { "\($0) \(plural($0, noun.0, noun.1))…" } ?? "Lendo"
        case .done, .cached: count.map { "\($0) \(plural($0, noun.0, noun.1))" }
        case .failed: "Falhou"
        case .skipped: "Não conectado"
        }
    }

    private static func changesDetail(_ state: SyncJournal.State, firstRun: Bool) -> String? {
        switch state {
        case .pending: firstRun ? "Primeira leitura: sem alertas" : "Na fila"
        case .active: "Comparando com a última leitura"
        case let .done(count?) where !firstRun && count > 0:
            "\(count) \(plural(count, "novidade", "novidades"))"
        case .done: firstRun ? "Base registrada" : "Nada novo"
        case .failed: "Falhou"
        default: nil
        }
    }

    private static func plural(_ n: Int, _ one: String, _ many: String) -> String {
        n == 1 ? one : many
    }

    private static func joined(_ parts: String?...) -> String? {
        let values = parts.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }
}
