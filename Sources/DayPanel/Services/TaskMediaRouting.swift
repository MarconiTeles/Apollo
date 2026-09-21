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

        // Menos de duas tarefas: não há para onde rotear.
        guard tasks.count >= 2 else {
            return files.reduce(into: [:]) { result, file in
                let decision = decided[file.id].map(sanitized)
                result[file.id] = (decision?.taskId != nil) ? decision! : .all
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
        for file in undecided {
            if let taskId = TaskMediaNameMatcher.resolve(fileName: file.name,
                                                         tasks: tasks).suggestedTaskId {
                matched[file.id] = taskId
            }
        }

        let routed = !matched.isEmpty || resolved.values.contains { $0.taskId != nil }

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
