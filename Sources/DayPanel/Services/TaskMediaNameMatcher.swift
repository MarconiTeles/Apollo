import Foundation

/// Descobre a qual tarefa um arquivo pertence, pelo nome.
///
/// A convenção de nome do time é `{H|B}{n}_{ASSUNTO}_{V##}`:
///
///     H4_REPLICA_BALDA_AIRTON_V02
///     B1_REPLICA_BALDA_AIRTON_V01
///
/// e o título da tarefa carrega o mesmo assunto em prosa:
///
///     Camiseta 1.0 - Réplica Airton 2 - B1 - H5
///
/// O casamento é entre o ASSUNTO dos dois lados. O papel (H/B) já é
/// resolvido por `TaskMediaRole.inferred` e aqui é descartado de
/// propósito: ele diz o que o arquivo é, nunca de quem ele é.
///
/// ## Por que peso por raridade em vez de lista de palavras ignoradas
///
/// Quase toda tarefa da lista começa com "Camiseta 1.0". Um token que
/// aparece em quase todas as candidatas não distingue nada, e manter uma
/// lista fixa de palavras a ignorar envelheceria mal — bastaria a
/// campanha do mês mudar de produto. Então o peso de cada token é medido
/// contra o próprio conjunto de tarefas da vez: quanto mais raro ali,
/// mais ele vale. Isso se ajusta sozinho quando a nomenclatura muda.
enum TaskMediaNameMatcher {

    struct Match: Equatable {
        let taskId: String
        /// 0…1. Fração do peso dos tokens do arquivo que a tarefa cobre.
        let score: Double
        /// O que os dois nomes têm em comum — é o que a interface mostra
        /// para a pessoa entender POR QUE o sistema sugeriu aquela tarefa.
        let sharedTokens: [String]
    }

    struct Resolution: Equatable {
        let best: Match?
        let runnerUp: Match?

        /// Abaixo disso a sugestão não é boa o bastante para ser oferecida.
        static let confidenceFloor = 0.34
        /// Quando a segunda colocada chega perto da primeira, o nome não
        /// separa as duas — e adivinhar mandaria o vídeo para a tarefa
        /// errada de um cliente real, sem desfazer (a API do ClickUp não
        /// apaga anexo). Nesse caso o sistema não escolhe: pergunta.
        static let ambiguityMargin = 0.82

        var isAmbiguous: Bool {
            guard let best, let runnerUp, best.score > 0 else { return false }
            return runnerUp.score >= best.score * Self.ambiguityMargin
        }

        var isConfident: Bool {
            guard let best else { return false }
            return best.score >= Self.confidenceFloor && !isAmbiguous
        }

        /// A tarefa a propor, ou `nil` quando o nome não decide sozinho.
        var suggestedTaskId: String? { isConfident ? best?.taskId : nil }
    }

    // MARK: - Tokenização

    /// Tokens que descrevem o PAPEL ou a VERSÃO, nunca o assunto.
    /// Aparecem dos dois lados e só atrapalhariam:
    ///   • `h5`, `b1`      — papel + índice no nome do arquivo
    ///   • `5h`, `12h`     — contagem esperada no título da tarefa
    ///   • `6h1b`, `5h1b`  — a mesma contagem colada
    ///   • `v01`, `v2`     — versão do arquivo
    private static func isStructuralToken(_ token: String) -> Bool {
        let patterns = [
            #"^[hb]\d+$"#,
            #"^\d+[hb]$"#,
            #"^\d+[hb]\d+[hb]$"#,
            #"^v\d+$"#
        ]
        if ["hook", "hooks", "body", "bodies", "corpo", "corpos"].contains(token) {
            return true
        }
        return patterns.contains {
            token.range(of: $0, options: .regularExpression) != nil
        }
    }

    static func tokens(of text: String) -> [String] {
        text.decomposedStringWithCanonicalMapping
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { token in
                guard !isStructuralToken(token) else { return false }
                // Número solto FICA, por mais curto que seja: é ele que
                // separa "TESTE LOTE 1" de "TESTE LOTE 2" e "Réplica
                // Airton" de "Réplica Airton 2". Descartá-lo fazia todas
                // as candidatas empatarem e nenhuma ser sugerida — os
                // vídeos acabavam indo para todas as tarefas.
                if token.allSatisfy(\.isNumber) { return true }
                // Letra solta (o "h"/"b" de papel) não identifica assunto.
                return token.count > 1
            }
    }

    // MARK: - Pontuação

    /// Ordena as tarefas pela semelhança do assunto com o nome do arquivo.
    static func rank(fileName: String, tasks: [CUTask]) -> [Match] {
        let fileTokens = Set(tokens(of: fileName))
        guard !fileTokens.isEmpty, !tasks.isEmpty else { return [] }

        let taskTokens = tasks.map { (task: $0, tokens: Set(tokens(of: $0.title))) }

        // Peso por raridade dentro do conjunto de candidatas: um token em
        // todas as tarefas vale quase nada; um que só aparece numa vale
        // muito. É o que faz "camiseta" pesar menos que "airton" sem
        // ninguém ter escrito uma lista.
        func weight(_ token: String) -> Double {
            let hits = taskTokens.filter { $0.tokens.contains(token) }.count
            guard hits > 0 else { return 0 }
            return log(Double(tasks.count + 1) / Double(hits))
        }

        let weights = Dictionary(uniqueKeysWithValues: fileTokens.map { ($0, weight($0)) })
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return [] }

        return taskTokens.compactMap { entry -> Match? in
            let shared = fileTokens.intersection(entry.tokens)
            guard !shared.isEmpty else { return nil }
            let covered = shared.reduce(0.0) { $0 + (weights[$1] ?? 0) }
            guard covered > 0 else { return nil }
            return Match(taskId: entry.task.id,
                         score: covered / total,
                         sharedTokens: shared.sorted())
        }
        .sorted { $0.score > $1.score }
    }

    static func resolve(fileName: String, tasks: [CUTask]) -> Resolution {
        let ranked = rank(fileName: fileName, tasks: tasks)
        return Resolution(best: ranked.first,
                          runnerUp: ranked.dropFirst().first)
    }
}
