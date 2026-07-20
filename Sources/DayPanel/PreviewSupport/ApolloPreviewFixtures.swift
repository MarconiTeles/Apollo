#if DEBUG
import Foundation

/// Deterministic, local-only data for Xcode's SwiftUI Canvas.
///
/// Nothing in this file contains a real ClickUp token, task id or review URL.
/// Keeping the fixtures in the app module lets previews render the production
/// views directly instead of maintaining a second, approximate UI hierarchy.
enum ApolloPreviewScenario {
    case populated
    case empty
    case loading
    case error
}

enum ApolloPreviewFixtures {
    static let listId = "apollo-preview-list-video"
    static let listName = "Listas / Video"
    static let currentUserId = 42

    static let defaults: UserDefaults = {
        let suite = "com.painellunar.apollo.preview-catalog"
        return UserDefaults(suiteName: suite) ?? .standard
    }()

    static let statuses: [CUStatus] = [
        CUStatus(status: "BACKLOG",   color: "#5E5786", type: "open"),
        CUStatus(status: "ARQUIVADO", color: "#EC3E91", type: "custom"),
        CUStatus(status: "A GRAVAR",  color: "#3864DA", type: "custom"),
        CUStatus(status: "CAPTADO",   color: "#A88C7B", type: "custom"),
        CUStatus(status: "A EDITAR",  color: "#F3A000", type: "custom"),
        CUStatus(status: "EDITANDO",  color: "#E96514", type: "custom"),
        CUStatus(status: "REVIEW",    color: "#7A6597", type: "custom"),
        CUStatus(status: "AJUSTES",   color: "#E67D82", type: "custom"),
        CUStatus(status: "CANCELADO", color: "#B0402C", type: "closed"),
        CUStatus(status: "COMPLETE",  color: "#3F6B4A", type: "closed"),
    ]

    static let members: [CUMember] = [
        CUMember(id: currentUserId, username: "Marconi Reis",
                 email: "marconi@moon.ventures", color: "#151A20",
                 profilePicture: nil, initials: "MR"),
        CUMember(id: 43, username: "Eduardo Jorge",
                 email: "eduardo@moon.ventures", color: "#1A73E8",
                 profilePicture: nil, initials: "EJ"),
        CUMember(id: 44, username: "Joana Rocha",
                 email: "joana@moon.ventures", color: "#673DE6",
                 profilePicture: nil, initials: "JR"),
        CUMember(id: 45, username: "Pedro Nasser",
                 email: "pedro@moon.ventures", color: "#D630E8",
                 profilePicture: nil, initials: "PN"),
    ]

    static let tags: [CUTask.Tag] = [
        CUTask.Tag(name: "UGC", foreground: "#FFFFFF", background: "#7257E8"),
        CUTask.Tag(name: "HOOK IA", foreground: "#7A4010", background: "#FFE3B2"),
        CUTask.Tag(name: "PERPÉTUO", foreground: "#1F5D38", background: "#D7F4E2"),
    ]

    private static var assignees: [Int: CUTask.Assignee] {
        Dictionary(uniqueKeysWithValues: members.map { member in
            (member.id, CUTask.Assignee(id: member.id,
                                        username: member.username,
                                        initials: member.initials,
                                        color: member.color,
                                        profilePicture: member.profilePicture))
        })
    }

    private static func date(dayOffset: Int = 0, hour: Int = 12, minute: Int = 0) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    private static func task(
        _ id: String,
        _ title: String,
        status: String,
        color: String,
        memberId: Int,
        dueDay: Int?,
        priority: Int = 0,
        tagNames: [String] = [],
        parentId: String? = nil,
        completed: Bool = false
    ) -> CUTask {
        let selectedTags = tags.filter { tagNames.contains($0.name) }
        return CUTask(
            id: id,
            title: title,
            status: status,
            statusColor: color,
            priority: priority,
            priorityColor: priority == 1 ? "#A8392A" : "#7C7E84",
            startDate: nil,
            dueDate: dueDay.map { date(dayOffset: $0, hour: 18) },
            listId: listId,
            listName: listName,
            isCompleted: completed,
            description: "Fixture local do catálogo de previews do Apollo.",
            commentCount: Int(id.hashValue.magnitude % 6),
            assignees: assignees[memberId].map { [$0] } ?? [],
            tags: selectedTags,
            url: "https://app.clickup.com/t/preview-\(id)",
            dateCreated: date(dayOffset: -7),
            dateUpdated: date(dayOffset: -1),
            parentId: parentId
        )
    }

    static var tasks: [CUTask] {
        [
            task("preview-backlog-1", "[PERPÉTUO] RAY - Camiseta - Lendo Comentário",
                 status: "BACKLOG", color: "#5E5786", memberId: currentUserId,
                 dueDay: 6, tagNames: ["PERPÉTUO"]),
            task("preview-backlog-2", "Camiseta Modal Tech - POV - B1 - H1",
                 status: "BACKLOG", color: "#5E5786", memberId: 43,
                 dueDay: 7, tagNames: ["UGC"]),
            task("preview-archive-1", "[Aumento de preço][Abner] Camiseta - Desenho",
                 status: "ARQUIVADO", color: "#EC3E91", memberId: currentUserId,
                 dueDay: -4, tagNames: ["HOOK IA"]),
            task("preview-record-1", "Calça Comfort - Ângulo 2 - Formato 2 - B1 - H5",
                 status: "A GRAVAR", color: "#3864DA", memberId: 44,
                 dueDay: 1, priority: 2),
            task("preview-captured-1", "Calça Comfort - Aumento de Preços - B2 - H4 [IA]",
                 status: "CAPTADO", color: "#A88C7B", memberId: currentUserId,
                 dueDay: 0, priority: 1, tagNames: ["HOOK IA"]),
            task("preview-edit-1", "[Nasser] Camiseta - Réplica 6 - Aviso Honesto [Hook IA]",
                 status: "A EDITAR", color: "#F3A000", memberId: 43,
                 dueDay: -1, priority: 1, tagNames: ["HOOK IA"]),
            task("preview-editing-1", "[PERPÉTUO] AMANDA - Camiseta - Frente a câmera - H1-B1",
                 status: "EDITANDO", color: "#E96514", memberId: 43,
                 dueDay: 0, tagNames: ["PERPÉTUO"]),
            task("preview-review-1", "Calça Jeans - Ângulo 1 - Formato 2 - B1 - H2",
                 status: "REVIEW", color: "#7A6597", memberId: 44,
                 dueDay: -1, tagNames: ["UGC"]),
            task("preview-review-2", "TESTE 3 · catálogo visual local",
                 status: "REVIEW", color: "#7A6597", memberId: currentUserId,
                 dueDay: nil, tagNames: ["HOOK IA"]),
            task("preview-adjust-1", "Compilado B2B - ajustes de timing e copy",
                 status: "AJUSTES", color: "#E67D82", memberId: 45,
                 dueDay: -4, priority: 1),
            task("preview-cancelled-1", "Campanha sazonal - variação cancelada",
                 status: "CANCELADO", color: "#B0402C", memberId: 45,
                 dueDay: -8, completed: true),
            task("preview-complete-1", "Camiseta Minimal - entrega final",
                 status: "COMPLETE", color: "#3F6B4A", memberId: currentUserId,
                 dueDay: -2, completed: true),
            task("preview-subtask-1", "Legenda e safe area da versão vertical",
                 status: "EDITANDO", color: "#E96514", memberId: 43,
                 dueDay: 0, parentId: "preview-editing-1"),
        ]
    }

    static var events: [CalendarEvent] {
        [
            CalendarEvent(id: "preview-event-1", title: "Daily Receita Minimal",
                          startDate: date(hour: 9, minute: 30),
                          endDate: date(hour: 10), colorHex: "#039BE5",
                          calendarId: "preview-primary", isAllDay: false,
                          location: "Boteco", calendarName: "Moon Ventures"),
            CalendarEvent(id: "preview-event-2", title: "Gravação Social Copa",
                          startDate: date(hour: 12), endDate: date(hour: 13),
                          colorHex: "#33B679", calendarId: "preview-primary",
                          isAllDay: false, location: "Estúdio",
                          calendarName: "Moon Ventures"),
            CalendarEvent(id: "preview-event-3", title: "Review criativa · Apollo",
                          startDate: date(hour: 15, minute: 30),
                          endDate: date(hour: 16), colorHex: "#8E24AA",
                          calendarId: "preview-primary", isAllDay: false,
                          location: "Sala 4", calendarName: "Moon Ventures"),
        ]
    }

    static var notifications: [AppNotification] {
        [
            AppNotification(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                            date: Date().addingTimeInterval(-180), kind: .info,
                            title: "Calça Jeans - Ângulo 1 - Formato 2",
                            subtitle: "Atribuição alterada",
                            message: "REVIEW",
                            read: false, targetKind: .task,
                            targetId: "preview-review-1"),
            AppNotification(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                            date: Date().addingTimeInterval(-840), kind: .warning,
                            title: "Camiseta - Aumento de preços",
                            subtitle: "Status alterado",
                            message: "EDITANDO → REVIEW · Urgente",
                            messageHighlights: [
                                .init(text: "EDITANDO", hex: "#E96514"),
                                .init(text: "REVIEW", hex: "#7A6597"),
                            ],
                            read: false, targetKind: .task,
                            targetId: "preview-editing-1"),
            AppNotification(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                            date: Date().addingTimeInterval(-2_400), kind: .success,
                            title: "Apollo Review atualizado",
                            subtitle: "2 comentários novos",
                            message: "Camiseta Modal Tech · V1",
                            read: true, targetKind: nil, targetId: nil),
        ]
    }

    static var assignedComments: [AssignedCommentRecord] {
        let me = CUComment.Participant(id: currentUserId,
                                       username: "Marconi Reis",
                                       email: "marconi@moon.ventures",
                                       color: "#151A20", initials: "MR",
                                       profilePicture: nil)
        let eduardo = CUComment.Participant(id: 43,
                                            username: "Eduardo Jorge",
                                            email: "eduardo@moon.ventures",
                                            color: "#1A73E8", initials: "EJ",
                                            profilePicture: nil)
        let sourceTasks = tasks
        let first = CUComment(id: "preview-comment-1",
                              text: "@Marconi Reis ajuste o corte aos 00:15 e confira a legenda.",
                              date: Date().addingTimeInterval(-2_400),
                              userId: eduardo.id, userName: eduardo.username,
                              userEmail: eduardo.email, userColor: eduardo.color,
                              initials: eduardo.initials, profilePic: nil,
                              resolved: false, reactions: [], replyCount: 2,
                              attachments: [], assignee: me, assignedBy: eduardo)
        let second = CUComment(id: "preview-comment-2",
                               text: "@Marconi Reis validar a nova versão antes da publicação.",
                               date: Date().addingTimeInterval(-8_400),
                               userId: eduardo.id, userName: eduardo.username,
                               userEmail: eduardo.email, userColor: eduardo.color,
                               initials: eduardo.initials, profilePic: nil,
                               resolved: false,
                               reactions: [.init(emoji: "👍", userIds: [currentUserId])],
                               replyCount: 0, attachments: [],
                               assignee: me, assignedBy: eduardo)
        return [
            AssignedCommentRecord(task: sourceTasks[7], comment: first),
            AssignedCommentRecord(task: sourceTasks[5], comment: second),
        ]
    }
}
#endif
