import AppKit
import SwiftUI

// Centralised context-menu action specs for a `CUTask`.
//
// The same action list feeds BOTH the AppKit `NSMenu` shown
// by `TaskRowCellItem` (right-click on the main task list)
// AND the SwiftUI `.contextMenu` shown by `SubtaskRow` and
// `TaskRowView` (right-click inside popups + the legacy
// SwiftUI list). Editing one source keeps both surfaces in
// sync, no per-call-site boilerplate.
//
// Action surface (v1):
//   • Abrir
//   • Status         → submenu of every status in the space
//   • Vencimento     → submenu (hoje, amanhã, próx. semana,
//                      limpar)
//   • Prioridade     → submenu (urgente/alta/normal/baixa
//                      + nenhuma)
//   • Copiar título
//   • Copiar link (when `task.url` exists)
//   • Abrir no ClickUp (when `task.url` exists)
//   • Duplicar
//   • Arquivar
//   • Excluir (destructive — red label)
//
// All mutating entries fan out to existing `AppState`
// methods so undo / sync / cache invalidation already work
// — `updateTaskStatus`, `updateTaskDueDate`,
// `updateTaskPriority`, `duplicateTask`, `archiveTask`,
// `deleteTask`.

// MARK: - Action spec

struct TaskContextAction {
    let title: String
    var systemImage: String? = nil
    /// Optional semantic swatch used by status entries. Keeping this in the
    /// canonical action spec guarantees that AppKit menus, SwiftUI menus and
    /// every bulk toolbar render the exact same status colour.
    var semanticColorHex: String? = nil
    /// `true` paints the entry red in both NSMenu and
    /// SwiftUI — used for "Excluir".
    var isDestructive: Bool = false
    /// `true` puts a ✓ next to the entry — used inside
    /// submenus (Status / Prioridade) to mark the current
    /// value.
    var isSelected: Bool = false
    /// `nil` means this entry is either a separator
    /// (when also `title == ""` and no children) or a
    /// section header carrying a submenu.
    var action: (() -> Void)? = nil
    var children: [TaskContextAction]? = nil

    /// Convenience for visually separating menu sections.
    static let separator = TaskContextAction(title: "")

    var isSeparator: Bool {
        action == nil && children == nil && title.isEmpty
    }
}

// MARK: - Builder

enum TaskContextMenu {

    /// Produces the canonical action list for `task`.
    /// Both NSMenu and SwiftUI menu builders below walk
    /// this list.
    static func actions(for task: CUTask,
                        appState: AppState) -> [TaskContextAction] {
        var out: [TaskContextAction] = []

        // ── Open ─────────────────────────────────────────
        out.append(TaskContextAction(
            title: "Abrir",
            systemImage: "arrow.up.right.square",
            action: {
                appState.openTaskDetail(task,
                                        origin: .zero,
                                        navigationTasks: appState.tasks,
                                        style: .bottomSlide)
            }
        ))
        out.append(.separator)

        // ── Status submenu ───────────────────────────────
        let statusChildren = appState.availableStatuses.map { st in
            TaskContextAction(
                title: st.status.uppercased(),
                semanticColorHex: st.displayHex,
                isSelected: st.status.lowercased()
                    == task.status.lowercased(),
                action: {
                    Task { await appState.updateTaskStatus(task, to: st) }
                }
            )
        }
        if !statusChildren.isEmpty {
            out.append(TaskContextAction(
                title: "Status",
                systemImage: "circle.dashed",
                children: statusChildren
            ))
        }

        // ── Due-date submenu ─────────────────────────────
        out.append(TaskContextAction(
            title: "Vencimento",
            systemImage: "calendar",
            children: [
                TaskContextAction(
                    title: "Hoje",
                    action: { setDue(task: task,
                                      appState: appState,
                                      daysAhead: 0) }),
                TaskContextAction(
                    title: "Amanhã",
                    action: { setDue(task: task,
                                      appState: appState,
                                      daysAhead: 1) }),
                TaskContextAction(
                    title: "Próxima semana",
                    action: { setDue(task: task,
                                      appState: appState,
                                      daysAhead: 7) }),
                .separator,
                TaskContextAction(
                    title: "Limpar data",
                    action: {
                        Task {
                            await appState.updateTaskDueDate(task,
                                                              to: nil)
                        }
                    }
                ),
            ]
        ))

        // ── Priority submenu ─────────────────────────────
        // ClickUp's priority levels: 1 = urgent, 2 = high,
        // 3 = normal, 4 = low, 0 = none. We preserve the
        // numeric mapping `updateTaskPriority` expects.
        out.append(TaskContextAction(
            title: "Prioridade",
            systemImage: "flag",
            children: [
                TaskContextAction(
                    title: "🔴  Urgente",
                    isSelected: task.priority == 1,
                    action: { Task {
                        await appState.updateTaskPriority(task, to: 1)
                    } }),
                TaskContextAction(
                    title: "🟠  Alta",
                    isSelected: task.priority == 2,
                    action: { Task {
                        await appState.updateTaskPriority(task, to: 2)
                    } }),
                TaskContextAction(
                    title: "🟡  Normal",
                    isSelected: task.priority == 3,
                    action: { Task {
                        await appState.updateTaskPriority(task, to: 3)
                    } }),
                TaskContextAction(
                    title: "🔵  Baixa",
                    isSelected: task.priority == 4,
                    action: { Task {
                        await appState.updateTaskPriority(task, to: 4)
                    } }),
                .separator,
                TaskContextAction(
                    title: "Sem prioridade",
                    isSelected: task.priority == 0,
                    action: { Task {
                        await appState.updateTaskPriority(task, to: 0)
                    } }),
            ]
        ))

        out.append(.separator)

        // ── Copy / external ─────────────────────────────
        out.append(TaskContextAction(
            title: "Copiar título",
            systemImage: "doc.on.clipboard",
            action: { copy(task.title) }
        ))
        if let url = task.url, !url.isEmpty {
            out.append(TaskContextAction(
                title: "Copiar link",
                systemImage: "link",
                action: { copy(url) }
            ))
            out.append(TaskContextAction(
                title: "Abrir no ClickUp",
                systemImage: "arrow.up.right",
                action: {
                    if let u = URL(string: url) {
                        NSWorkspace.shared.open(u)
                    }
                }
            ))
        }
        out.append(.separator)

        // ── Duplicate / archive / delete ─────────────────
        out.append(TaskContextAction(
            title: "Duplicar",
            systemImage: "doc.on.doc",
            action: { Task { _ = await appState.duplicateTask(task) } }
        ))
        out.append(TaskContextAction(
            title: "Arquivar",
            systemImage: "archivebox",
            action: { Task { await appState.archiveTask(task) } }
        ))
        out.append(TaskContextAction(
            title: "Excluir",
            systemImage: "trash",
            isDestructive: true,
            action: { Task { await appState.deleteTask(task) } }
        ))

        return out
    }

    // MARK: - Helpers

    /// End-of-day at the user's local time for "Hoje /
    /// Amanhã / Próxima semana" presets. End-of-day (23:59)
    /// is the convention the rest of the app uses for "due
    /// today" tasks.
    private static func setDue(task: CUTask,
                                appState: AppState,
                                daysAhead: Int) {
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date())
        guard let target = cal.date(byAdding: .day,
                                     value: daysAhead,
                                     to: base),
              let end = cal.date(bySettingHour: 23,
                                  minute: 59,
                                  second: 0,
                                  of: target)
        else { return }
        Task { await appState.updateTaskDueDate(task, to: end) }
    }

    private static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - NSMenu builder

    /// Build the AppKit `NSMenu` for `task`. Called by
    /// `TaskRowContentView.menu(for:)` per right-click —
    /// rebuilds every time so the ✓ marks + visibility of
    /// "Copiar link" reflect the latest task state.
    static func makeNSMenu(task: CUTask,
                            appState: AppState) -> NSMenu {
        makeNSMenu(actions: actions(for: task, appState: appState))
    }

    static func makeNSMenu(actions: [TaskContextAction]) -> NSMenu {
        let menu = NSMenu()
        // Disable autoenable so closure-driven items don't
        // get greyed out by AppKit's default validation
        // (which expects a target+selector on the
        // responder chain).
        menu.autoenablesItems = false
        for action in actions {
            menu.addItem(makeNSItem(from: action))
        }
        return menu
    }

    private static func makeNSItem(from a: TaskContextAction)
        -> NSMenuItem
    {
        if a.isSeparator { return .separator() }
        let item: NSMenuItem
        if let action = a.action {
            item = ClosureMenuItem(title: a.title, closure: action)
        } else {
            item = NSMenuItem(title: a.title, action: nil,
                              keyEquivalent: "")
            // Section header with submenu — enabled so
            // children become reachable.
            item.isEnabled = true
        }
        if let hex = a.semanticColorHex {
            item.image = semanticDotImage(hex: hex)
        } else if let symbol = a.systemImage {
            item.image = NSImage(
                systemSymbolName: symbol,
                accessibilityDescription: nil)
        }
        if a.isSelected { item.state = .on }
        if a.isDestructive {
            let attr = NSMutableAttributedString(string: a.title)
            attr.addAttribute(
                .foregroundColor,
                value: NSColor.systemRed,
                range: NSRange(location: 0, length: attr.length))
            item.attributedTitle = attr
        }
        if let kids = a.children {
            let sub = NSMenu()
            sub.autoenablesItems = false
            for c in kids { sub.addItem(makeNSItem(from: c)) }
            item.submenu = sub
        }
        return item
    }

    private static func semanticDotImage(hex: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let color = NSColor(Color(statusHex: hex))
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5)).fill()
            color.withAlphaComponent(0.24).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.8, dy: 1.8))
            ring.lineWidth = 0.7
            ring.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// `NSMenuItem` that fires a Swift closure instead of an
/// Obj-C selector on a responder chain target. Keeps the
/// menu independent of the responder chain so it works
/// regardless of which view is focused at right-click time.
private final class ClosureMenuItem: NSMenuItem {
    let closure: () -> Void
    init(title: String, closure: @escaping () -> Void) {
        self.closure = closure
        super.init(title: title,
                    action: #selector(invoke),
                    keyEquivalent: "")
        self.target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func invoke() { closure() }
}

// MARK: - SwiftUI builder

extension View {
    /// Attach the canonical task context menu to any
    /// SwiftUI surface. Used by `SubtaskRow` (in the task
    /// popup) and `TaskRowView` (legacy SwiftUI list path).
    func taskContextMenu(task: CUTask,
                         appState: AppState) -> some View {
        self.contextMenu {
            TaskContextMenuItems(
                actions: TaskContextMenu.actions(
                    for: task,
                    appState: appState)
            )
        }
    }
}

/// SwiftUI counterpart to the NSMenu builder. Walks the
/// same `[TaskContextAction]` spec and emits `Button` /
/// `Menu` / `Divider` per entry. Recursive for submenus.
struct TaskContextMenuItems: View {
    let actions: [TaskContextAction]

    var body: some View {
        ForEach(Array(actions.enumerated()), id: \.offset) {
            _, action in
            if action.isSeparator {
                Divider()
            } else if let kids = action.children {
                Menu {
                    TaskContextMenuItems(actions: kids)
                } label: {
                    if let icon = action.systemImage {
                        Label(action.title,
                              systemImage: icon)
                    } else {
                        Text(action.title)
                    }
                }
            } else if let perform = action.action {
                Button(
                    role: action.isDestructive ? .destructive : nil
                ) {
                    perform()
                } label: {
                    HStack {
                        if let hex = action.semanticColorHex {
                            Circle()
                                .fill(Color(statusHex: hex))
                                .frame(width: 7, height: 7)
                            Text(action.title)
                        } else if let icon = action.systemImage {
                            Label(action.title,
                                  systemImage: icon)
                        } else {
                            Text(action.title)
                        }
                        if action.isSelected {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
    }
}
