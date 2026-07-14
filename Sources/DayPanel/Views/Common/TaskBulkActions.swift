import AppKit
import SwiftUI

/// Canonical multi-task command surface used by Minhas tarefas.
/// Every mutation fans out through AppState's existing optimistic/offline
/// pipeline, so a bulk edit has the same sync guarantees as a one-row edit.
enum TaskBulkActions {
    static func actions(for tasks: [CUTask], appState: AppState) -> [TaskContextAction] {
        guard !tasks.isEmpty else { return [] }
        var actions: [TaskContextAction] = []

        if tasks.count == 1, let task = tasks.first {
            actions.append(TaskContextAction(
                title: "Abrir",
                systemImage: "arrow.up.right.square",
                action: {
                    appState.detailTaskOrigin = .zero
                    appState.detailTask = task
                }
            ))
            actions.append(.separator)
        }

        if !appState.availableStatuses.isEmpty {
            actions.append(TaskContextAction(
                title: "Status",
                systemImage: "circle.dashed",
                children: appState.availableStatuses.map { status in
                    TaskContextAction(
                        title: status.status.uppercased(),
                        isSelected: tasks.allSatisfy {
                            $0.status.caseInsensitiveCompare(status.status) == .orderedSame
                        },
                        action: {
                            Task {
                                for task in tasks {
                                    await appState.updateTaskStatus(task, to: status)
                                }
                            }
                        }
                    )
                }
            ))
        }

        if !appState.availableMembers.isEmpty {
            let add = appState.availableMembers.map { member in
                TaskContextAction(
                    title: member.username,
                    isSelected: tasks.allSatisfy { task in
                        task.assignees.contains { $0.id == member.id }
                    },
                    action: {
                        Task {
                            for task in tasks {
                                var ids = Set(task.assignees.map(\.id))
                                ids.insert(member.id)
                                await appState.updateTaskAssignees(task, to: ids)
                            }
                        }
                    }
                )
            }
            let remove = appState.availableMembers.map { member in
                TaskContextAction(
                    title: member.username,
                    action: {
                        Task {
                            for task in tasks {
                                var ids = Set(task.assignees.map(\.id))
                                ids.remove(member.id)
                                await appState.updateTaskAssignees(task, to: ids)
                            }
                        }
                    }
                )
            }
            actions.append(TaskContextAction(
                title: "Responsáveis",
                systemImage: "person.2",
                children: [
                    TaskContextAction(title: "Adicionar", children: add),
                    TaskContextAction(title: "Remover", children: remove),
                    .separator,
                    TaskContextAction(
                        title: "Limpar responsáveis",
                        action: {
                            Task {
                                for task in tasks {
                                    await appState.updateTaskAssignees(task, to: [])
                                }
                            }
                        }
                    )
                ]
            ))
        }

        actions.append(TaskContextAction(
            title: "Datas",
            systemImage: "calendar",
            children: [
                dueAction("Hoje", tasks: tasks, daysAhead: 0, appState: appState),
                dueAction("Amanhã", tasks: tasks, daysAhead: 1, appState: appState),
                dueAction("Próxima semana", tasks: tasks, daysAhead: 7, appState: appState),
                .separator,
                TaskContextAction(
                    title: "Limpar vencimento",
                    action: {
                        Task {
                            for task in tasks {
                                await appState.updateTaskDueDate(task, to: nil)
                            }
                        }
                    }
                )
            ]
        ))

        let priorities: [(String, Int)] = [
            ("Urgente", 1), ("Alta", 2), ("Normal", 3), ("Baixa", 4),
            ("Sem prioridade", 0)
        ]
        actions.append(TaskContextAction(
            title: "Prioridade",
            systemImage: "flag",
            children: priorities.map { title, value in
                TaskContextAction(
                    title: title,
                    isSelected: tasks.allSatisfy { $0.priority == value },
                    action: {
                        Task {
                            for task in tasks {
                                await appState.updateTaskPriority(task, to: value)
                            }
                        }
                    }
                )
            }
        ))

        if !appState.availableTags.isEmpty {
            let tags = appState.availableTags.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            let add = tags.map { tag in
                TaskContextAction(
                    title: tag.name,
                    isSelected: tasks.allSatisfy { task in
                        task.tags.contains { $0.name == tag.name }
                    },
                    action: {
                        Task {
                            for task in tasks {
                                var names = Set(task.tags.map(\.name))
                                names.insert(tag.name)
                                await appState.updateTaskTags(task, to: names)
                            }
                        }
                    }
                )
            }
            let remove = tags.map { tag in
                TaskContextAction(
                    title: tag.name,
                    action: {
                        Task {
                            for task in tasks {
                                var names = Set(task.tags.map(\.name))
                                names.remove(tag.name)
                                await appState.updateTaskTags(task, to: names)
                            }
                        }
                    }
                )
            }
            actions.append(TaskContextAction(
                title: "Etiquetas",
                systemImage: "tag",
                children: [
                    TaskContextAction(title: "Adicionar", children: add),
                    TaskContextAction(title: "Remover", children: remove),
                    .separator,
                    TaskContextAction(
                        title: "Limpar etiquetas",
                        action: {
                            Task {
                                for task in tasks {
                                    await appState.updateTaskTags(task, to: [])
                                }
                            }
                        }
                    )
                ]
            ))
        }

        actions.append(.separator)
        actions.append(TaskContextAction(
            title: tasks.count == 1 ? "Copiar título" : "Copiar títulos",
            systemImage: "doc.on.clipboard",
            action: { copy(tasks.map(\.title).joined(separator: "\n")) }
        ))

        let links = tasks.compactMap { task -> String? in
            guard let url = task.url, !url.isEmpty else { return nil }
            return url
        }
        if !links.isEmpty {
            actions.append(TaskContextAction(
                title: links.count == 1 ? "Copiar link" : "Copiar links",
                systemImage: "link",
                action: { copy(links.joined(separator: "\n")) }
            ))
            actions.append(TaskContextAction(
                title: links.count == 1 ? "Abrir no ClickUp" : "Abrir no ClickUp (\(links.count))",
                systemImage: "arrow.up.right",
                action: {
                    links.compactMap(URL.init(string:)).forEach {
                        _ = NSWorkspace.shared.open($0)
                    }
                }
            ))
        }

        actions.append(.separator)
        actions.append(TaskContextAction(
            title: tasks.count == 1 ? "Duplicar" : "Duplicar \(tasks.count) tarefas",
            systemImage: "doc.on.doc",
            action: {
                Task {
                    for task in tasks { _ = await appState.duplicateTask(task) }
                }
            }
        ))
        actions.append(TaskContextAction(
            title: tasks.count == 1 ? "Arquivar" : "Arquivar \(tasks.count) tarefas",
            systemImage: "archivebox",
            action: {
                Task {
                    for task in tasks { await appState.archiveTask(task) }
                }
            }
        ))
        actions.append(TaskContextAction(
            title: tasks.count == 1 ? "Excluir" : "Excluir \(tasks.count) tarefas",
            systemImage: "trash",
            isDestructive: true,
            action: {
                Task {
                    for task in tasks { await appState.deleteTask(task) }
                }
            }
        ))
        return actions
    }

    private static func dueAction(_ title: String,
                                  tasks: [CUTask],
                                  daysAhead: Int,
                                  appState: AppState) -> TaskContextAction {
        TaskContextAction(title: title, action: {
            guard let date = endOfDay(daysAhead: daysAhead) else { return }
            Task {
                for task in tasks { await appState.updateTaskDueDate(task, to: date) }
            }
        })
    }

    private static func endOfDay(daysAhead: Int) -> Date? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        guard let day = calendar.date(byAdding: .day, value: daysAhead, to: start)
        else { return nil }
        return calendar.date(bySettingHour: 23, minute: 59, second: 0, of: day)
    }

    private static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// Shared floating command surface for every multi-select task canvas.
/// Keeping one implementation prevents Minhas tarefas and Quadro from
/// drifting in available commands, material, spacing or menu semantics.
struct TaskBulkToolbar: View {
    let tasks: [CUTask]
    @ObservedObject var appState: AppState
    let onClear: () -> Void

    private var actions: [TaskContextAction] {
        TaskBulkActions.actions(for: tasks, appState: appState)
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .foregroundStyle(Editorial.inkMute)

            Text("\(tasks.count) selecionada\(tasks.count == 1 ? "" : "s")")
                .font(Editorial.sans(11.5, .semibold))
                .foregroundStyle(Editorial.ink)
                .monospacedDigit()
                .frame(minWidth: 92, alignment: .leading)

            separator
            fieldMenu(title: "Status", icon: "circle.dashed")
            fieldMenu(title: "Responsáveis", icon: "person.2")
            fieldMenu(title: "Datas", icon: "calendar")
            fieldMenu(title: "Prioridade", icon: "flag")
            fieldMenu(title: "Etiquetas", icon: "tag")
            separator

            Menu {
                TaskContextMenuItems(actions: overflowActions)
            } label: {
                Label("Mais", systemImage: "ellipsis")
                    .font(Editorial.sans(11, .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .contentShape(Capsule(style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .fixedSize(horizontal: true, vertical: false)
        // Neutral Liquid Glass: selection is expressed by the selected rows
        // or cards, not by tinting the command surface with the app accent.
        .liquidGlass(in: Capsule(style: .continuous),
                     tint: .white,
                     tintOpacity: 0.018,
                     interactive: true)
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(Materials.tier == .solid ? 0 : 0.22),
                              lineWidth: 0.6)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
    }

    private var separator: some View {
        Rectangle()
            .fill(Editorial.rule.opacity(0.75))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 5)
    }

    @ViewBuilder
    private func fieldMenu(title: String, icon: String) -> some View {
        if let action = actions.first(where: { $0.title == title }),
           let children = action.children {
            Menu {
                TaskContextMenuItems(actions: children)
            } label: {
                Label(title, systemImage: icon)
                    .font(Editorial.sans(11, .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .contentShape(Capsule(style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var overflowActions: [TaskContextAction] {
        let fields: Set<String> = ["Status", "Responsáveis", "Datas", "Prioridade", "Etiquetas"]
        var result = actions.filter { !fields.contains($0.title) }
        while result.first?.isSeparator == true { result.removeFirst() }
        while result.last?.isSeparator == true { result.removeLast() }
        return result
    }
}
