import Foundation

/// Para onde um vídeo vai, no envio em lote.
///
/// Três estados nomeados, sem sobrecarregar `nil`. A versão anterior
/// usava `taskId?` mais um sinalizador `routingActive` para decidir o
/// que a ausência significava: ora "vale para todas", ora "sem
/// destino". Quando o roteamento estava ligado, um arquivo que a
/// interface mostrava como "Todas as tarefas" era excluído de TODAS na
/// projeção — a tela prometia uma coisa e o envio fazia outra.
enum TaskMediaDestination: Equatable {
    /// Vale para todas as tarefas de destino.
    case all
    /// Uma tarefa específica.
    case task(String)
    /// Ainda não decidido. Bloqueia o envio até a pessoa escolher.
    case unresolved

    var taskId: String? {
        if case .task(let id) = self { return id }
        return nil
    }
    var isAll: Bool { self == .all }
    var isUnresolved: Bool { self == .unresolved }

    /// Esta tarefa recebe o arquivo com este destino?
    func reaches(_ taskId: String) -> Bool {
        switch self {
        case .all:           return true
        case .task(let id):  return id == taskId
        case .unresolved:    return false
        }
    }
}

enum TaskMediaRouting {

    struct File: Equatable {
        let id: UUID
        let name: String
    }

    /// Resolve o destino de cada arquivo.
    ///
    /// Ordem de precedência:
    ///   1. decisão explícita da pessoa (menu, arrasto, remoção);
    ///   2. casamento por nome, quando tem confiança;
    ///   3. o resto, conforme a regra abaixo.
    ///
    /// O que fazer com quem não casou depende do lote:
    ///   • ninguém foi endereçado a uma tarefa específica → todos ficam
    ///     `.all`, que é a tela de sempre (um vídeo para todas);
    ///   • alguém foi → os demais viram `.unresolved`. Num lote
    ///     claramente roteado por nome, mandar o arquivo órfão para
    ///     todas seria uma surpresa descoberta só depois de publicado.
    static func resolve(files: [File],
                        tasks: [CUTask],
                        decided: [UUID: TaskMediaDestination])
    -> [UUID: TaskMediaDestination] {
        let liveTasks = Set(tasks.map(\.id))

        // Decisão que aponta para uma tarefa que saiu da lista não pode
        // continuar valendo — vira pendência em vez de apontar ao vazio.
        func sanitized(_ destination: TaskMediaDestination) -> TaskMediaDestination {
            if let id = destination.taskId, !liveTasks.contains(id) { return .unresolved }
            return destination
        }

        // A single task needs no automatic matching, but an explicit pending
        // decision (including a removed destination) must remain pending.
        guard tasks.count >= 2 else {
            return files.reduce(into: [:]) { result, file in
                let decision = decided[file.id].map(sanitized)
                result[file.id] = decision ?? (tasks.isEmpty ? .unresolved : .all)
            }
        }

        var resolved: [UUID: TaskMediaDestination] = [:]
        var undecided: [File] = []

        for file in files {
            if let decision = decided[file.id] {
                resolved[file.id] = sanitized(decision)
            } else {
                undecided.append(file)
            }
        }

        var matched: [UUID: String] = [:]
        var hasAmbiguity = false
        for file in undecided {
            let resolution = TaskMediaNameMatcher.resolve(fileName: file.name, tasks: tasks)
            hasAmbiguity = hasAmbiguity || resolution.isAmbiguous
            if let taskId = resolution.suggestedTaskId { matched[file.id] = taskId }
        }

        // An ambiguous match is evidence of routing intent, never permission
        // to broadcast. An explicit manual `.all` remains authoritative.
        let routed = hasAmbiguity || !matched.isEmpty
            || resolved.values.contains { $0.taskId != nil || $0.isUnresolved }

        for file in undecided {
            if let taskId = matched[file.id] {
                resolved[file.id] = .task(taskId)
            } else {
                resolved[file.id] = routed ? .unresolved : .all
            }
        }

        return resolved
    }

    /// Os arquivos que esta tarefa recebe: os endereçados a ela mais os
    /// que valem para todas.
    static func recipients(of taskId: String,
                           files: [File],
                           destinations: [UUID: TaskMediaDestination]) -> [UUID] {
        files.compactMap { file in
            (destinations[file.id] ?? .all).reaches(taskId) ? file.id : nil
        }
    }
}

/// Sugestão de qual vídeo já publicado um arquivo novo substitui.
///
/// A regra é o NOME: só sugere quando o assunto dos dois é parecido de
/// verdade. O papel (hook/body/vídeo) não filtra — `REPLICA_AIRTON - B1`
/// pode trocar `REPLICA_AIRTON - H2` —, só desempata quando dois vídeos
/// são igualmente parecidos (o hook e o body da mesma pauta).
///
/// Não usa o peso por raridade do casamento de tarefa: lá, palavra do
/// arquivo que não aparece em candidata nenhuma pesa zero, e com um só
/// vídeo na tarefa bastava um "VIDEO" em comum para dar 100% —
/// `SEM_RELACAO_NENHUMA - VIDEO` trocava `CALCA_COMFORT_GALPAO - VIDEO`.
/// Aqui cada palavra do assunto conta, dos dois lados.
enum TaskMediaReplacementSuggestion {

    struct Asset: Equatable {
        let id: UUID
        let name: String
        let role: TaskMediaRole
    }

    /// Fração mínima do assunto em comum, medida contra o nome MAIS
    /// longo dos dois — assim um nome curto não casa com qualquer nome
    /// comprido que por acaso o contenha.
    static let similarityFloor = 0.5

    /// `nil` quando nada é parecido o bastante, ou quando dois vídeos
    /// empatam e o papel não separa. Nesses casos o arquivo fica para
    /// adicionar e a pessoa decide — trocar o vídeo errado numa tarefa
    /// de cliente não tem desfazer.
    static func suggest(fileName: String, among assets: [Asset]) -> UUID? {
        let fileTokens = subjectTokens(of: fileName)
        guard !fileTokens.isEmpty else { return nil }

        let scored: [(asset: Asset, score: Double)] = assets.compactMap { asset in
            let assetTokens = subjectTokens(of: asset.name)
            guard !assetTokens.isEmpty else { return nil }
            let shared = fileTokens.intersection(assetTokens).count
            let score = Double(shared) / Double(max(fileTokens.count, assetTokens.count))
            return score >= similarityFloor ? (asset, score) : nil
        }
        guard let top = scored.map(\.score).max() else { return nil }

        let best = scored.filter { $0.score == top }.map(\.asset)
        if best.count == 1 { return best[0].id }

        // Empate de nome: o papel do arquivo decide, se decidir sozinho.
        guard let role = TaskMediaRole.inferred(from: fileName) else { return nil }
        let sameRole = best.filter { effectiveRole(of: $0) == role }
        return sameRole.count == 1 ? sameRole[0].id : nil
    }

    /// O assunto do nome: sem papel, índice e versão (o que o
    /// `TaskMediaNameMatcher` já descarta) e sem "video", que aqui é
    /// papel e aparece em quase todo nome.
    static func subjectTokens(of name: String) -> Set<String> {
        let base = (name as NSString).deletingPathExtension
        return Set(TaskMediaNameMatcher.tokens(of: base))
            .subtracting(["video", "videos"])
    }

    /// Anexo antigo importado do ClickUp entra no catálogo como VIDEO
    /// genérico, mesmo chamado `REPLICA_AIRTON - H2`. Nesses casos o
    /// nome diz o papel melhor que o catálogo; papel explícito vence.
    private static func effectiveRole(of asset: Asset) -> TaskMediaRole {
        guard asset.role == .video else { return asset.role }
        return TaskMediaRole.inferred(from: asset.name) ?? .video
    }
}

/// O que fazer com arquivos soltos numa tarefa que já tem vídeo.
///
/// A pessoa escolhe, arquivo a arquivo, qual vídeo existente cada um
/// substitui — ou nenhum. O `TaskMediaTransferStore` guarda UM lote por
/// tarefa, então substituir e adicionar não cabem na mesma preparação:
/// quando a escolha mistura os dois, a substituição roda primeiro (é a
/// intenção explícita) e o resto segue para a classificação logo em
/// seguida, em vez de ser descartado em silêncio.
enum TaskMediaDropDecision {

    struct Dropped: Equatable {
        let id: UUID
        let url: URL
    }

    struct Plan: Equatable {
        /// assetId existente → arquivo novo que o substitui.
        let replacements: [UUID: URL]
        /// Arquivos sem alvo: entram como novos.
        let leftovers: [UUID]

        var replacesAnything: Bool { !replacements.isEmpty }
        var isPureAddition: Bool { replacements.isEmpty }
        var isMixed: Bool { !replacements.isEmpty && !leftovers.isEmpty }
    }

    /// `choices` mapeia arquivo solto → asset substituído. Valor `nil`
    /// (presente ou ausente) quer dizer "entra como novo" — é escolha
    /// legítima, não ausência de escolha.
    static func plan(dropped: [Dropped],
                     choices: [UUID: UUID?]) -> Plan {
        var replacements: [UUID: URL] = [:]
        var leftovers: [UUID] = []
        for file in dropped {
            if let assetId = choices[file.id] ?? nil, replacements[assetId] == nil {
                replacements[assetId] = file.url
            } else {
                leftovers.append(file.id)
            }
        }
        return Plan(replacements: replacements, leftovers: leftovers)
    }

    /// Rótulo do botão: diz exatamente o que vai acontecer, incluindo
    /// quando as duas coisas acontecem.
    static func actionTitle(for plan: Plan) -> String {
        guard plan.replacesAnything else { return "ADICIONAR COMO NOVOS" }
        return plan.leftovers.isEmpty
            ? "SUBSTITUIR \(plan.replacements.count)"
            : "SUBSTITUIR \(plan.replacements.count) E ADICIONAR \(plan.leftovers.count)"
    }
}
