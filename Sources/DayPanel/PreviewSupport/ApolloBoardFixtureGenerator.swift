#if DEBUG || APOLLO_DEV
import Foundation

/// Deterministic, offline board dataset for the DEV build (`--board-fixtures=N`)
/// and tests. Same seed + same N + same "today" always produce the same tasks.
///
/// The distribution is intentionally unbalanced across the ten statuses of
/// `ApolloPreviewFixtures.statuses`, titles span one, two and three-or-more
/// lines at the 260pt card width (with emoji and accents), and every other
/// card attribute the board draws varies: 0–4 assignees, priority 0–4,
/// past/today/future/no due date, tags and subtasks.
///
/// Closed statuses keep production semantics (`isCompleted == true`, exactly
/// as `ClickUpService` maps `type == "closed"`), so those cards exist in the
/// dataset but are excluded from the board by `TaskSurfaceScope.openTasks`.
enum ApolloBoardFixtureGenerator {
    static let defaultSeed: UInt64 = 0xA9_0110_B0A2_D5EE

    /// Relative weights, same order as `ApolloPreviewFixtures.statuses`
    /// (BACKLOG, ARQUIVADO, A GRAVAR, CAPTADO, A EDITAR, EDITANDO, REVIEW,
    /// AJUSTES, CANCELADO, COMPLETE). Sum = 100.
    static let statusWeights: [Int] = [30, 2, 12, 5, 18, 9, 14, 6, 1, 3]

    static func tasks(count: Int,
                      seed: UInt64 = defaultSeed,
                      now: Date = Date(),
                      calendar: Calendar = .current) -> [CUTask] {
        guard count > 0 else { return [] }
        var rng = SplitMix64(seed: seed)
        let statuses = ApolloPreviewFixtures.statuses
        precondition(statuses.count == statusWeights.count)
        let members = ApolloPreviewFixtures.members
        let tags = ApolloPreviewFixtures.tags
        let today = calendar.startOfDay(for: now)
        let totalWeight = statusWeights.reduce(0, +)

        var result: [CUTask] = []
        result.reserveCapacity(count)
        var topLevelIndices: [Int] = []

        for index in 0..<count {
            // Status (weighted).
            var roll = Int(rng.next(upperBound: UInt64(totalWeight)))
            var statusIndex = 0
            for (i, w) in statusWeights.enumerated() {
                if roll < w { statusIndex = i; break }
                roll -= w
            }
            let status = statuses[statusIndex]

            // Subtask: ~8% after the first few, parent chosen among earlier
            // top-level tasks (deterministic).
            var parentId: String? = nil
            if topLevelIndices.count >= 3, rng.next(upperBound: 100) < 8 {
                let p = topLevelIndices[Int(rng.next(upperBound: UInt64(topLevelIndices.count)))]
                parentId = result[p].id
            }

            // Assignees 0...4 (distinct members, stable order).
            let assigneeCount = Int(rng.next(upperBound: UInt64(members.count + 1)))
            var pool = members
            var assignees: [CUTask.Assignee] = []
            for _ in 0..<assigneeCount {
                let m = pool.remove(at: Int(rng.next(upperBound: UInt64(pool.count))))
                assignees.append(CUTask.Assignee(id: m.id, username: m.username,
                                                 initials: m.initials, color: m.color,
                                                 profilePicture: m.profilePicture))
            }

            // Priority 0 (none) ... 4 (low), ClickUp encoding.
            let priority = Int(rng.next(upperBound: 5))

            // Due date: 20% none, 25% past, 15% today, 40% future.
            let dueRoll = rng.next(upperBound: 100)
            let dueDate: Date?
            switch dueRoll {
            case 0..<20: dueDate = nil
            case 20..<45: dueDate = at(today, days: -Int(1 + rng.next(upperBound: 30)), calendar)
            case 45..<60: dueDate = at(today, days: 0, calendar)
            default: dueDate = at(today, days: Int(1 + rng.next(upperBound: 45)), calendar)
            }

            // Tags 0...2.
            let tagCount = Int(rng.next(upperBound: 3))
            var tagPool = tags
            var chosenTags: [CUTask.Tag] = []
            for _ in 0..<tagCount {
                chosenTags.append(tagPool.remove(at: Int(rng.next(upperBound: UInt64(tagPool.count)))))
            }

            let title = makeTitle(index: index, rng: &rng)
            let id = String(format: "fx-%05d", index + 1)
            let closed = status.type == "closed"
            let task = CUTask(
                id: id,
                title: title,
                status: status.status,
                statusColor: status.color,
                priority: priority,
                priorityColor: priorityColor(priority),
                startDate: nil,
                dueDate: dueDate,
                listId: ApolloPreviewFixtures.listId,
                listName: ApolloPreviewFixtures.listName,
                isCompleted: closed,
                description: "Fixture DEV determinística (\(id)).",
                commentCount: Int(rng.next(upperBound: 7)),
                assignees: assignees,
                tags: chosenTags,
                url: "https://app.clickup.com/t/\(id)",
                dateCreated: at(today, days: -60, calendar),
                dateUpdated: at(today, days: -1, calendar),
                parentId: parentId
            )
            if parentId == nil { topLevelIndices.append(result.count) }
            result.append(task)
        }
        return result
    }

    // MARK: - Titles

    private static let shortTitles = [
        "Roteiro final", "Hook IA · B2", "Corte 9:16 ✂️", "Legenda PT-BR",
        "Thumb 🎯", "Áudio v2", "Revisão rápida", "Capa Reels", "Ângulo 3",
        "Fechamento 📦",
    ]
    private static let subjects = [
        "Camiseta Modal Tech", "Calça Comfort", "Jaqueta Corta-Vento",
        "Tênis Urbano", "Bermuda Linho", "Moletom Básico", "Camisa Oxford",
    ]
    private static let middles = [
        "Ângulo 2 - Formato 2", "POV - Frente à câmera", "Réplica 6 - Aviso Honesto",
        "Aumento de Preços", "Depoimento espontâneo 🎬", "Unboxing com ação ✨",
        "Comparativo lado a lado", "Tutorial de caimento",
    ]
    private static let tails = [
        "B1 - H1", "B2 - H4 [IA]", "H5 · versão vertical", "[PERPÉTUO]",
        "ajustes de timing e copy 🚀", "legenda e safe area revisadas",
        "cortes acelerados com música licenciada", "variação para público 25–34 anos",
    ]

    /// Mix: 35% one line, 35% two lines, 30% three or more lines at 260pt.
    private static func makeTitle(index: Int, rng: inout SplitMix64) -> String {
        func pick(_ a: [String]) -> String { a[Int(rng.next(upperBound: UInt64(a.count)))] }
        let kind = rng.next(upperBound: 100)
        switch kind {
        case 0..<35:
            return pick(shortTitles)
        case 35..<70:
            return "\(pick(subjects)) - \(pick(middles)) - \(pick(tails))"
        default:
            return "[\(pick(["Abner", "Nasser", "Amanda", "Joana", "Édson"]))] " +
                "\(pick(subjects)) - \(pick(middles)) - \(pick(tails)) · " +
                "\(pick(middles)) com observações de direção de arte, " +
                "revisão de cor e acessibilidade 👀 #\(index + 1)"
        }
    }

    // MARK: - Helpers

    private static func at(_ day: Date, days: Int, _ calendar: Calendar) -> Date {
        let d = calendar.date(byAdding: .day, value: days, to: day) ?? day
        return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: d) ?? d
    }

    private static func priorityColor(_ p: Int) -> String {
        switch p {
        case 1: "#F50000"
        case 2: "#FFCC00"
        case 3: "#6FDDFF"
        case 4: "#D8D8D8"
        default: "#7C7E84"
        }
    }
}

/// Small, fixed-algorithm PRNG so fixtures do not depend on the platform's
/// random source or on `hashValue` (which is seeded per process).
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `0..<upperBound` (modulo bias is irrelevant for fixtures).
    mutating func next(upperBound: UInt64) -> UInt64 {
        precondition(upperBound > 0)
        return next() % upperBound
    }
}
#endif
