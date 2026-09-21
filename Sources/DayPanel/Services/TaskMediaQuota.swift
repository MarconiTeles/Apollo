import Foundation

/// Quantos HOOKs e BODYs uma tarefa espera, lido do próprio título.
///
/// O time já escreve isso há tempo, em formatos que variam:
///
///     Camiseta 1.0 - Réplica Airton 2 - B1 - H5      → 1 body, 5 hooks
///     Balda - Camiseta 1.0 - POV - 5H - B1           → 1 body, 5 hooks
///     Alexandre - Camiseta - Bom x Ruim - 6H1B       → 1 body, 6 hooks
///     Camiseta 1.0 - Fernando - Comparativo - 5H-1B  → 1 body, 5 hooks
///     Camiseta Minimal — TOF — Jumanji (4 hooks)     → 4 hooks
///
/// A informação estava lá e ninguém usava. Com ela o app consegue dizer
/// "essa tarefa pede 1 body e 6 hooks; você trouxe 1 e 7" ANTES de
/// publicar — em vez de a pessoa descobrir o excesso relendo o ClickUp,
/// quando o anexo já não tem como ser apagado.
struct TaskMediaQuota: Equatable {
    var hooks: Int?
    var bodies: Int?

    var isEmpty: Bool { hooks == nil && bodies == nil }

    /// Lê a cota do título. `nil` em cada campo significa "a tarefa não
    /// declara" — e nesse caso o app não inventa limite nenhum.
    static func parse(title: String) -> TaskMediaQuota {
        let normalized = title
            .decomposedStringWithCanonicalMapping
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        var quota = TaskMediaQuota()

        // "6h1b" / "1b6h" — contagem colada, os dois papéis de uma vez.
        for pattern in [#"(\d+)h(\d+)b"#, #"(\d+)b(\d+)h"#] {
            if let match = firstGroups(in: normalized, pattern: pattern),
               match.count == 2,
               let first = Int(match[0]), let second = Int(match[1]) {
                if pattern.contains("h(") && pattern.hasPrefix(#"(\d+)h"#) {
                    quota.hooks = first; quota.bodies = second
                } else {
                    quota.bodies = first; quota.hooks = second
                }
                return quota
            }
        }

        let tokens = normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init)

        // "h5" / "b1" (letra antes) e "5h" / "1b" (número antes).
        for token in tokens {
            if let n = captured(token, #"^h(\d+)$"#) ?? captured(token, #"^(\d+)h$"#) {
                quota.hooks = n
            }
            if let n = captured(token, #"^b(\d+)$"#) ?? captured(token, #"^(\d+)b$"#) {
                quota.bodies = n
            }
        }

        // "(4 hooks)" — forma por extenso.
        if quota.hooks == nil,
           let groups = firstGroups(in: normalized, pattern: #"(\d+)\s*hooks?"#),
           let n = groups.first.flatMap(Int.init) {
            quota.hooks = n
        }
        if quota.bodies == nil,
           let groups = firstGroups(in: normalized, pattern: #"(\d+)\s*bod(?:y|ies)"#),
           let n = groups.first.flatMap(Int.init) {
            quota.bodies = n
        }

        return quota
    }

    /// Compara o que a tarefa pede com o que o lote está levando.
    /// Devolve o aviso a mostrar, ou `nil` quando está tudo certo (ou
    /// quando a tarefa não declara cota).
    func warning(hooks incomingHooks: Int, bodies incomingBodies: Int) -> String? {
        var parts: [String] = []
        if let hooks, incomingHooks > hooks {
            parts.append("\(incomingHooks) hooks para \(hooks) pedidos")
        }
        if let bodies, incomingBodies > bodies {
            parts.append("\(incomingBodies) bodies para \(bodies) pedidos")
        }
        guard !parts.isEmpty else { return nil }
        return "Acima do pedido: " + parts.joined(separator: " · ")
    }

    // MARK: - Regex

    private static func captured(_ token: String, _ pattern: String) -> Int? {
        firstGroups(in: token, pattern: pattern)?.first.flatMap(Int.init)
    }

    private static func firstGroups(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text,
                                           range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1 else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}
