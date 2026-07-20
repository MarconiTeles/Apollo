import AppKit
import SwiftUI

/// Universal visual language for a selected task. List rows and Board cards
/// intentionally use the same fill, stroke, spring and semantic glow so
/// selection never changes meaning when the user switches surface.
private struct TaskSelectionSurfaceModifier: ViewModifier {
    let selected: Bool
    let radius: CGFloat
    let tint: Color

    func body(content: Content) -> some View {
        content
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Editorial.accent.opacity(0.075))
                }
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Editorial.accent.opacity(0.58), lineWidth: 1.1)
                        .shadow(color: tint.opacity(0.16), radius: 3.5, y: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .animation(.spring(response: 0.24, dampingFraction: 0.78), value: selected)
    }
}

extension View {
    func taskSelectionSurface(_ selected: Bool,
                              radius: CGFloat = Editorial.notificationCapsuleRadius,
                              tint: Color = Editorial.accent) -> some View {
        modifier(TaskSelectionSurfaceModifier(selected: selected,
                                              radius: radius,
                                              tint: tint))
    }
}

/// Route-scoped Escape monitor for bulk selection. SwiftUI's
/// `onExitCommand` is not reached when an embedded NSCollectionView owns the
/// first-responder chain, so the task list could keep its selection toolbar
/// visible after Esc. A local key monitor observes the same window before the
/// responder chain, clears selection, and still returns the event so a task or
/// event overlay may perform its own Escape dismissal as well.
struct EscapeSelectionMonitor: NSViewRepresentable {
    let isActive: Bool
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isActive: isActive, onEscape: onEscape)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.isActive = isActive
        context.coordinator.onEscape = onEscape
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        weak var hostView: NSView?
        var isActive: Bool
        var onEscape: () -> Void
        private var monitor: Any?

        init(isActive: Bool, onEscape: @escaping () -> Void) {
            self.isActive = isActive
            self.onEscape = onEscape
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      self.isActive,
                      event.keyCode == 53,
                      let window = self.hostView?.window,
                      window.isKeyWindow else { return event }
                DispatchQueue.main.async { [weak self] in self?.onEscape() }
                return event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { uninstall() }
    }
}

/// One drag preview for every task surface. A multi-selection is represented
/// as a physical stack (up to three visible sheets) plus semantic status dots,
/// rather than pretending that only the card under the pointer is moving.
struct TaskDragStackPreview: View {
    let tasks: [CUTask]
    let primary: CUTask
    var width: CGFloat = 270

    private var represented: [CUTask] { tasks.isEmpty ? [primary] : tasks }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if represented.count > 1 {
                ForEach(0..<min(3, represented.count), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.regularMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color(statusHex: represented[index].statusDisplayHex)
                                    .opacity(0.38), lineWidth: 0.8)
                        }
                        .frame(width: width - CGFloat(index * 8), height: 46)
                        .offset(x: CGFloat(index * 4), y: CGFloat(index * 5))
                }
            }

            HStack(spacing: 9) {
                HStack(spacing: -2) {
                    ForEach(Array(represented.prefix(3)), id: \.id) { task in
                        Circle()
                            .fill(Color(statusHex: task.statusDisplayHex))
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Editorial.paper, lineWidth: 1))
                    }
                }
                Image(systemName: represented.count > 1 ? "rectangle.stack.fill" : "line.3.horizontal")
                    .foregroundStyle(Editorial.inkMute)
                Text(represented.count > 1 ? "\(represented.count) tarefas" : primary.title)
                    .font(Editorial.sans(12.5, .semibold))
                    .foregroundStyle(Editorial.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(width: width, height: 46, alignment: .leading)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.6)
            }
        }
        // A single-card drag preview must have the exact same bounds as the
        // capsule. The old unconditional +10pt transparent canvas was
        // flattened by AppKit into the drag image and produced a rectangular,
        // offset shadow around an otherwise rounded preview.
        .frame(width: represented.count > 1 ? width + 10 : width,
               height: represented.count > 1 ? 60 : 46,
               alignment: .topLeading)
        .contentShape(.dragPreview,
                      RoundedRectangle(cornerRadius: 12, style: .continuous))
        // NSDraggingSession already supplies the native lifted shadow. Adding
        // another SwiftUI shadow here doubled its footprint and made the
        // bitmap edge visible while moving between Board columns.
    }
}

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
                    appState.openTaskDetail(task,
                                            origin: .zero,
                                            navigationTasks: appState.tasks,
                                            style: .bottomSlide)
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
                        semanticColorHex: status.displayHex,
                        isSelected: tasks.allSatisfy {
                            $0.status.caseInsensitiveCompare(status.status) == .orderedSame
                        },
                        action: {
                            Task {
                                // Batched so all selected rows move to the new
                                // group at once, not one-per-network-round-trip.
                                await appState.updateTaskStatuses(tasks, to: status)
                                await registerSnapshotUndo(tasks,
                                    label: bulkLabel("Alterar status", count: tasks.count),
                                    appState: appState)
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
                            await registerSnapshotUndo(tasks,
                                label: bulkLabel("Alterar responsáveis", count: tasks.count),
                                appState: appState)
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
                            await registerSnapshotUndo(tasks,
                                label: bulkLabel("Alterar responsáveis", count: tasks.count),
                                appState: appState)
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
                                await registerSnapshotUndo(tasks,
                                    label: bulkLabel("Limpar responsáveis", count: tasks.count),
                                    appState: appState)
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
                            await registerSnapshotUndo(tasks,
                                label: bulkLabel("Limpar vencimento", count: tasks.count),
                                appState: appState)
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
                            await registerSnapshotUndo(tasks,
                                label: bulkLabel("Alterar prioridade", count: tasks.count),
                                appState: appState)
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
                            await registerSnapshotUndo(tasks,
                                label: bulkLabel("Alterar etiquetas", count: tasks.count),
                                appState: appState)
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
                            await registerSnapshotUndo(tasks,
                                label: bulkLabel("Alterar etiquetas", count: tasks.count),
                                appState: appState)
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
                                await registerSnapshotUndo(tasks,
                                    label: bulkLabel("Limpar etiquetas", count: tasks.count),
                                    appState: appState)
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
                    var created: [CUTask] = []
                    for task in tasks {
                        if let copy = await appState.duplicateTask(task) { created.append(copy) }
                    }
                    guard !created.isEmpty else { return }
                    let createdTasks = created
                    await MainActor.run {
                        appState.pushUndo(
                            label: bulkLabel("Duplicar", count: createdTasks.count)
                        ) {
                            for task in createdTasks { await appState.deleteTask(task) }
                        }
                    }
                }
            }
        ))
        actions.append(TaskContextAction(
            title: tasks.count == 1 ? "Arquivar" : "Arquivar \(tasks.count) tarefas",
            systemImage: "archivebox",
            action: {
                Task {
                    for task in tasks { await appState.archiveTask(task) }
                    await registerSnapshotUndo(tasks,
                        label: bulkLabel("Arquivar", count: tasks.count),
                        appState: appState)
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
                await registerSnapshotUndo(tasks,
                    label: bulkLabel("Alterar vencimento", count: tasks.count),
                    appState: appState)
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

    private static func registerSnapshotUndo(_ snapshots: [CUTask],
                                             label: String,
                                             appState: AppState) async {
        await MainActor.run {
            appState.pushTaskSnapshotUndo(snapshots, label: label)
        }
    }

    private static func bulkLabel(_ action: String, count: Int) -> String {
        count == 1 ? action : "\(action) em \(count) tarefas"
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
        .shadow(color: .black.opacity(0.22), radius: 11, y: 5)
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
