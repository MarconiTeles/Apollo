import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Apollo · Editorial+ board ("Quadro"). Direct port of the Claude-design
// kanban prototype — header breadcrumb + N status columns + cards with
// status dot, breadcrumb caps, priority chip, title, avatar + date.
// Drag a card between columns to fire `appState.updateTaskStatus`; the
// server round-trip updates ClickUp and the local view diff snaps back
// if the API rejects the move.
//
// Routes from `sidebarRoute == .board` in ContentView.

struct EditorialBoardView: View {
    @EnvironmentObject var appState: AppState

    /// Task currently being dragged (uuid string in NSItemProvider). Kept
    /// here so columns can render a drop-target highlight when a card
    /// is over them.
    @State private var dragOverStatus: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Editorial.rule).frame(height: 1)
            board
        }
        .background(Editorial.paper)
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Header
    // ────────────────────────────────────────────────────────────────────

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            // QUADRO · <SPACE> · <LIST>  N cards
            HStack(spacing: 10) {
                Text(crumbText)
                    .font(Editorial.sans(11, .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Editorial.inkSoft)
                Text("\(cardsTotal) cards")
                    .font(Editorial.sans(11, .medium))
                    .foregroundStyle(Editorial.inkFaint)
                    .monospacedDigit()
            }

            Spacer(minLength: 24)

            // Editorial tagline (right aligned, serif italic with pilcrow).
            Text("¶ arraste cards entre colunas — Apollo aprende sua rotina.")
                .font(Editorial.serif(12).italic())
                .foregroundStyle(Editorial.inkMute)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    /// "QUADRO · MINIMAL · MARKETING" — uppercased breadcrumb.
    private var crumbText: String {
        var parts: [String] = ["QUADRO"]
        // Workspace name lives in clickUpAuthService when available;
        // fall back to brand-neutral "MINIMAL" only if nothing better.
        if let ws = appState.clickUpAuthService.workspaceName, !ws.isEmpty {
            parts.append(ws.uppercased())
        }
        if !currentListName.isEmpty {
            parts.append(currentListName.uppercased())
        }
        return parts.joined(separator: " · ")
    }

    private var currentListName: String {
        KeychainHelper.load(for: KeychainHelper.Keys.clickupListName) ?? ""
    }

    /// All non-completed tasks in the active list — scope mirrors the
    /// other Editorial+ counts so the header total agrees with the
    /// column totals.
    private var boardTasks: [CUTask] {
        let listId = KeychainHelper.load(for: KeychainHelper.Keys.clickupListId) ?? ""
        // Include EVERY task in the active list (parents AND
        // subtasks) so the column counts match the sidebar's
        // list count. Subtasks render as their own card — the
        // kanban view treats them as independent units of work.
        return appState.tasks.filter { t in
            !t.archived &&
            (listId.isEmpty || t.listId == listId)
        }
    }

    private var cardsTotal: Int { boardTasks.count }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Board body
    // ────────────────────────────────────────────────────────────────────

    /// Horizontal scroll of N status columns. Each column is
    /// fixed-width (260pt) and fills the available vertical
    /// space — the cards INSIDE each column carry their own
    /// vertical scroll so a column with 50 cards doesn't push
    /// neighbouring columns out of view.
    private var board: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 20) {
                ForEach(visibleStatuses, id: \.status) { st in
                    column(for: st)
                        .frame(width: 260)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 24)
        }
        .frame(maxHeight: .infinity)
    }

    /// Hide the implicit "closed" statuses (`done`/`closed`) — boards
    /// only need the open lanes. If the workspace has no statuses yet
    /// (first-load before sync), fall back to a sane PT-BR default so
    /// the board doesn't render empty.
    private var visibleStatuses: [CUStatus] {
        let open = appState.availableStatuses.filter { !$0.isClosed }
        if !open.isEmpty { return open }
        return [
            CUStatus(status: "to do",     color: "#54577E", type: "open"),
            CUStatus(status: "doing",     color: "#B0612E", type: "custom"),
            CUStatus(status: "review",    color: "#7A6597", type: "custom"),
            CUStatus(status: "liberado",  color: "#9A7B1F", type: "custom"),
        ]
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Column
    // ────────────────────────────────────────────────────────────────────

    private func column(for status: CUStatus) -> some View {
        let cards = boardTasks.filter { $0.status.lowercased() == status.status.lowercased() }
        let isDropTarget = dragOverStatus == status.status.lowercased()
        return VStack(alignment: .leading, spacing: 12) {
            // Header stays PINNED at the top of the column even
            // when its cards scroll — the column's own height is
            // the available chrome height, and only the inner
            // card list scrolls.
            columnHeader(status: status, count: cards.count)

            // Per-column vertical scroll. Each status column
            // scrolls independently; columns with few cards stay
            // tight at the top while a busy column can hold dozens
            // without pushing siblings out of view.
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(cards, id: \.id) { task in
                        BoardCard(task: task)
                            .onDrag {
                                // Carry the task id as plain text so any
                                // column's .onDrop can fetch it back via
                                // loadObject.
                                NSItemProvider(object: task.id as NSString)
                            } preview: {
                                BoardCard(task: task)
                                    .frame(width: 260)
                                    .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
                            }
                            .onTapGesture {
                                // Open the existing detail popup. Mirrors the
                                // list-view click path so the same UX surfaces.
                                appState.detailTaskOrigin = .zero
                                appState.detailTask       = task
                            }
                    }
                    addCardPlaceholder(for: status)
                        .padding(.top, 4)
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)
        }
        // Soft drop-target wash: tint the whole column when a card from
        // another status hovers it.
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isDropTarget ? Editorial.card.opacity(0.65) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isDropTarget ? Editorial.accent.opacity(0.35) : Color.clear,
                        lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.12), value: isDropTarget)
        .onDrop(of: [.text], delegate: BoardDropDelegate(
            targetStatus: status,
            appState: appState,
            dragOverStatus: $dragOverStatus
        ))
    }

    private func columnHeader(status: CUStatus, count: Int) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(Color(hex: status.displayHex))
                .frame(width: 7, height: 7)
            Text(status.status.uppercased())
                .font(Editorial.sans(10.5, .semibold))
                .tracking(1.2)
                .foregroundStyle(Color(hex: status.displayHex))
                .lineLimit(1)
            Text("\(count)")
                .font(Editorial.sans(11, .semibold))
                .foregroundStyle(Editorial.inkMute)
                .monospacedDigit()
            Spacer(minLength: 4)
            // "+" — opens the existing CreateTaskSheet pre-bound to this
            // status. Calls into the legacy create flow; no per-status
            // bypass yet, the sheet picks up the status from a hint via
            // userdefaults if/when we want it. For now it just opens
            // the sheet — the user can pick status manually.
            Button {
                NotificationCenter.default.post(
                    name: .editorialBoardCreateCard,
                    object: nil,
                    userInfo: ["status": status.status]
                )
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Editorial.inkMute)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            // "⋮" — reserved slot; menu wiring lands in a follow-up.
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Editorial.inkFaint)
                .frame(width: 18, height: 18)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    /// "¶ Adicionar card" — dashed dropzone placeholder at the bottom
    /// of every column. Tapping fires the same "+" intent as the
    /// column header.
    private func addCardPlaceholder(for status: CUStatus) -> some View {
        Button {
            NotificationCenter.default.post(
                name: .editorialBoardCreateCard,
                object: nil,
                userInfo: ["status": status.status]
            )
        } label: {
            HStack {
                Text("¶ Adicionar card")
                    .font(Editorial.serif(12).italic())
                    .foregroundStyle(Editorial.inkFaint)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Editorial.rule)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

// ────────────────────────────────────────────────────────────────────────
// MARK: - Card
// ────────────────────────────────────────────────────────────────────────

/// A single kanban card — exactly the layout from the prototype:
/// status-dot + breadcrumb caps + optional priority chip,
/// title (sans medium),
/// avatar + first-name (left) + relative date (right, cinnabar if overdue).
private struct BoardCard: View {
    let task: CUTask
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            topRow
            Text(task.title)
                .font(Editorial.sans(13, .semibold))
                .foregroundStyle(Editorial.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            footer
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Solid card surface — no material/translucency. Pure
        // white in light mode, charcoal in dark; opaque so the
        // chrome paper / desktop don't bleed through. Shadow
        // removed and the hairline rule restored to full
        // Editorial.rule opacity so the card reads flat-solid
        // rather than "glassy lifted".
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Editorial.page)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Editorial.rule, lineWidth: 0.5)
        )
    }

    // ── Top row: status dot + breadcrumb caps + priority chip ──────────

    private var topRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: task.statusDisplayHex))
                .frame(width: 6, height: 6)
            Text(breadcrumb)
                .font(Editorial.sans(9.5, .semibold))
                .tracking(1.0)
                .foregroundStyle(Editorial.inkMute)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if task.priority > 0 && task.priority <= 2 {
                PriorityChip(priority: task.priority,
                             hex: task.priorityHex)
            }
        }
    }

    /// "SPACE · LIST" — uses the workspace name as the parent crumb when
    /// available, otherwise just the list name. Stays under 1 line.
    private var breadcrumb: String {
        let ws  = appState.clickUpAuthService.workspaceName ?? ""
        let lst = task.listName
        if !ws.isEmpty && !lst.isEmpty { return "\(ws.uppercased()) · \(lst.uppercased())" }
        if !lst.isEmpty                { return lst.uppercased() }
        return ws.uppercased()
    }

    // ── Footer: avatar + first name + date ─────────────────────────────

    private var footer: some View {
        HStack(spacing: 8) {
            avatar
            Text(firstName)
                .font(Editorial.sans(11.5, .medium))
                .foregroundStyle(Editorial.inkSoft)
                .lineLimit(1)
            Spacer(minLength: 4)
            dateLabel
        }
    }

    private var avatar: some View {
        let initial = String(firstName.first ?? "·").uppercased()
        return Circle()
            .fill(Color(statusHex: assigneeColorHex))
            .frame(width: 18, height: 18)
            .overlay(
                Text(initial)
                    .font(Editorial.sans(9, .bold))
                    .foregroundStyle(.white)
            )
    }

    private var firstName: String {
        let raw = task.assignees.first?.username ?? ""
        let token = raw.split(whereSeparator: { " ._-".contains($0) }).first ?? ""
        return token.isEmpty ? "Sem responsável" : token.prefix(1).uppercased() + token.dropFirst()
    }

    private var assigneeColorHex: String {
        let palette = ["#8B5CF6", "#C7321B", "#3F6B4A", "#4F8EF7",
                       "#9A7B1F", "#7A6597", "#B0612E", "#54577E"]
        let key = task.assignees.first?.username ?? task.id
        var h = 0
        for u in key.unicodeScalars { h = (h &* 31) &+ Int(u.value) }
        return palette[abs(h) % palette.count]
    }

    @ViewBuilder
    private var dateLabel: some View {
        if let due = task.dueDate {
            let overdue = due < Date() && !task.isCompleted
            HStack(spacing: 3) {
                Text(relativeDate(due))
                    .font(Editorial.sans(11, .medium))
                    .foregroundStyle(overdue ? Editorial.accent : Editorial.inkMute)
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(overdue ? Editorial.accent : Editorial.inkFaint)
            }
        }
    }

    private func relativeDate(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d)     { return "Hoje" }
        if cal.isDateInYesterday(d) { return "Ontem" }
        if cal.isDateInTomorrow(d)  { return "Amanhã" }
        let now = Date()
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now),
                                              to:   cal.startOfDay(for: d)).day ?? 0
        if days > 1 && days < 7  { return "em \(days) dias" }
        if days < -1 && days > -7 { return "\(-days) dias atrás" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "pt_BR")
        fmt.dateFormat = "d 'de' MMM."
        return fmt.string(from: d)
    }
}

// ────────────────────────────────────────────────────────────────────────
// MARK: - Priority chip ("● ALTA")
// ────────────────────────────────────────────────────────────────────────

private struct PriorityChip: View {
    let priority: Int        // 1 = Urgente, 2 = Alta
    let hex: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color(hex: hex))
                .frame(width: 5, height: 5)
            Text(label)
                .font(Editorial.sans(9.5, .bold))
                .tracking(0.6)
                .foregroundStyle(Color(hex: hex))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(Color(hex: hex).opacity(0.10))
        )
    }

    private var label: String {
        switch priority {
        case 1: return "URGENTE"
        case 2: return "ALTA"
        case 3: return "NORMAL"
        case 4: return "BAIXA"
        default: return ""
        }
    }
}

// ────────────────────────────────────────────────────────────────────────
// MARK: - Drop delegate
// ────────────────────────────────────────────────────────────────────────

/// Receives a card dragged onto a column. Validates it actually changes
/// status (no-op for same-column drops), looks the task up in AppState,
/// and fires `updateTaskStatus`. The AppState pipeline already handles
/// the optimistic local update + remote round-trip.
private struct BoardDropDelegate: DropDelegate {
    let targetStatus: CUStatus
    let appState: AppState
    @Binding var dragOverStatus: String?

    func dropEntered(info: DropInfo) {
        dragOverStatus = targetStatus.status.lowercased()
    }

    func dropExited(info: DropInfo) {
        if dragOverStatus == targetStatus.status.lowercased() {
            dragOverStatus = nil
        }
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first
        else { return false }
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let taskId = obj as? String else { return }
            Task { @MainActor in
                guard let task = appState.tasks.first(where: { $0.id == taskId })
                else { return }
                if task.status.lowercased() == targetStatus.status.lowercased() {
                    dragOverStatus = nil
                    return
                }
                await appState.updateTaskStatus(task, to: targetStatus)
                dragOverStatus = nil
            }
        }
        return true
    }
}

// ────────────────────────────────────────────────────────────────────────
// MARK: - Notifications
// ────────────────────────────────────────────────────────────────────────

extension Notification.Name {
    /// Fired when the user clicks a column "+" or the "Adicionar card"
    /// placeholder. ContentView listens and opens the existing
    /// `CreateTaskSheet` (status hint in `userInfo["status"]`).
    static let editorialBoardCreateCard =
        Notification.Name("dp.editorial.board.createCard")
}
