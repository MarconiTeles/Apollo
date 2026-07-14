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

    /// ID of the card the user is actively dragging. Set on `.onDrag`,
    /// cleared on drop. Drives the live in-column reorder (which card is
    /// being slotted) and the source card's dimmed placeholder look.
    @State private var draggingTaskId: String? = nil

    /// Board selection mirrors Minhas tarefas: Command toggles individual
    /// cards, Shift selects the inclusive visible range, and dragging any
    /// selected card carries the complete ordered selection.
    @State private var selectedTaskIds: Set<String> = []
    @State private var selectionAnchorId: String? = nil
    @State private var draggingTaskIds: [String] = []

    /// LOCAL, per-status vertical ordering of cards — purely a viewing
    /// preference, never written back to ClickUp. JSON `[statusKey:
    /// [taskId]]` persisted in AppStorage so the user's hand-arranged
    /// order survives relaunches. Cards absent from the saved list fall
    /// to the end in their natural (server) order, so newly-synced tasks
    /// always appear without needing a migration.
    @AppStorage("dp_board_cardOrder_v1") private var cardOrderRaw: String = "{}"

    /// Show/hide subtask cards on the board. Subtasks are independent
    /// units of work here (their own card), but a busy list can drown in
    /// them — this toggle lets the user collapse the board down to just
    /// the top-level tasks. View-only preference, persisted across
    /// launches. Defaults to `true` so existing behaviour is unchanged.
    @AppStorage("dp_board_showSubtasks_v1") private var showSubtasks: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Editorial.rule).frame(height: 1)
            board
        }
        .overlay(alignment: .bottom) {
            if !selectedTasks.isEmpty {
                TaskBulkToolbar(tasks: selectedTasks,
                                appState: appState,
                                onClear: clearSelection)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 34)
                    .transition(.move(edge: .bottom)
                        .combined(with: .opacity)
                        .combined(with: .scale(scale: 0.96, anchor: .bottom)))
                    .zIndex(20)
            }
        }
        .background(Editorial.paper)
        .onChange(of: boardTasks.map(\.id)) { _, visibleIds in
            let visible = Set(visibleIds)
            selectedTaskIds.formIntersection(visible)
            if let anchor = selectionAnchorId, !visible.contains(anchor) {
                selectionAnchorId = nil
            }
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Header
    // ────────────────────────────────────────────────────────────────────

    private var header: some View {
        // Outer row centers the breadcrumb cluster, the tagline and the
        // subtask toggle vertically; the crumb+count keep their own
        // baseline alignment inside the leading group.
        HStack(alignment: .center, spacing: 16) {
            // QUADRO · <SPACE> · <LIST>  N cards
            HStack(alignment: .firstTextBaseline, spacing: 10) {
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

            // Editorial tagline (serif italic with pilcrow).
            Text("¶ arraste cards entre colunas — Apollo aprende sua rotina.")
                .font(Editorial.serif(12).italic())
                .foregroundStyle(Editorial.inkMute)
                .lineLimit(1)
                .truncationMode(.tail)

            // Subtarefas on/off — collapse the board to top-level cards.
            subtaskToggle
        }
        // O board é FULL-WIDTH agora (o pane da sidebar flutua por
        // cima); o header precisa do próprio recuo de 230pt pra não
        // ficar embaixo do vidro.
        .padding(.leading, 230)
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    /// Pill switch + label that flips `showSubtasks`. Matches the
    /// Editorial toggle look used in Settings (`SetToggle`), trimmed
    /// slightly to sit in the header rule.
    private var subtaskToggle: some View {
        Button { showSubtasks.toggle() } label: {
            HStack(spacing: 8) {
                Text("SUBTAREFAS")
                    .font(Editorial.sans(10, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(showSubtasks ? Editorial.inkSoft : Editorial.inkFaint)
                ZStack(alignment: showSubtasks ? .trailing : .leading) {
                    Capsule()
                        .fill(showSubtasks ? Editorial.ink : Editorial.rule)
                        .frame(width: 32, height: 18)
                    Circle()
                        .fill(Editorial.page)
                        .frame(width: 14, height: 14)
                        .padding(2)
                        .shadow(color: .black.opacity(0.20), radius: 1, y: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(showSubtasks ? "Ocultar subtarefas do quadro" : "Exibir subtarefas no quadro")
        .animation(.easeInOut(duration: 0.15), value: showSubtasks)
        .fixedSize()
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
        appState.activeListName
    }

    /// All non-completed tasks in the active list — scope mirrors the
    /// other Editorial+ counts so the header total agrees with the
    /// column totals.
    private var boardTasks: [CUTask] {
        let listId = appState.activeListId
        // By default include EVERY task in the active list (parents AND
        // subtasks) — subtasks render as their own card, the kanban view
        // treats them as independent units of work, and the column totals
        // match the sidebar's list count. When `showSubtasks` is off the
        // user has chosen to collapse the board to top-level cards only;
        // the header total then reflects exactly what's on screen.
        let open = TaskSurfaceScope.openTasks(in: appState.tasks,
                                              activeListId: listId)
        let scoped = open.filter { showSubtasks || !$0.isSubtask }
        return appState.taskFilters.applying(to: scoped)
    }

    private var cardsTotal: Int { boardTasks.count }

    /// Deterministic visible order spanning columns left-to-right and cards
    /// top-to-bottom. Shift selection and multi-drag use this same order.
    private var orderedVisibleBoardTasks: [CUTask] {
        visibleStatuses.flatMap { status in
            let key = status.status.lowercased()
            return orderedCards(columnCards(key), statusKey: key)
        }
    }

    private var selectedTasks: [CUTask] {
        orderedVisibleBoardTasks.filter { selectedTaskIds.contains($0.id) }
    }

    private func activate(_ task: CUTask,
                          modifiers: NSEvent.ModifierFlags,
                          rect: CGRect) {
        let intent: TaskSelectionIntent
        if modifiers.contains(.shift) {
            intent = .range
        } else if modifiers.contains(.command) {
            intent = .toggle
        } else {
            intent = .plain
        }
        let resolution = TaskSelectionResolver.resolve(
            current: selectedTaskIds,
            anchor: selectionAnchorId,
            clicked: task.id,
            ordered: orderedVisibleBoardTasks.map(\.id),
            intent: intent
        )
        if resolution.shouldOpen {
            appState.openTaskDetail(
                task,
                origin: rect,
                navigationTasks: orderedVisibleBoardTasks,
                style: .scaleFromOrigin
            )
            return
        }
        withAnimation(.easeOut(duration: 0.14)) {
            selectedTaskIds = resolution.selected
            selectionAnchorId = resolution.anchor
        }
    }

    private func clearSelection() {
        withAnimation(.easeOut(duration: 0.14)) {
            selectedTaskIds.removeAll()
            selectionAnchorId = nil
        }
    }

    private func dragProvider(for task: CUTask) -> NSItemProvider {
        let ids: [String]
        if selectedTaskIds.contains(task.id) {
            ids = selectedTasks.map(\.id)
        } else {
            ids = [task.id]
            selectedTaskIds = [task.id]
            selectionAnchorId = task.id
        }
        draggingTaskId = task.id
        draggingTaskIds = ids
        return NSItemProvider(object: MyTasksDragPayload.encode(ids) as NSString)
    }

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
            .padding(.top, 22)
            .padding(.bottom, 24)
        }
        // FULL-WIDTH + contentMargins (não padding): o viewport do
        // scroll alcança x=0, então colunas roladas pra esquerda
        // DESENHAM sob o pane de vidro flutuante da sidebar — o
        // efeito "cards passando por trás do vidro" do MINIMAL TP.
        // Em repouso o conteúdo começa depois do pane (230pt do
        // pane + 28 de respiro).
        .contentMargins(.leading, 258, for: .scrollContent)
        .contentMargins(.trailing, 28, for: .scrollContent)
        .frame(maxHeight: .infinity)
        // Catch-all: any drop that falls through the columns/cards (e.g.
        // released over board chrome) still clears the drag state so a
        // source card never stays stuck in its dimmed ghost look.
        .onDrop(of: [.text], delegate: BoardResetDropDelegate(
            draggingTaskId: $draggingTaskId,
            draggingTaskIds: $draggingTaskIds,
            dragOverStatus: $dragOverStatus
        ))
    }

    /// Render EVERY workspace status as a column, including the
    /// implicit `done` / `closed` lanes (Concluído, Cancelado).
    /// Earlier these were filtered out with `!$0.isClosed` —
    /// matched the convention of some kanban apps but bit the
    /// user here: ClickUp's own board view shows the closed
    /// columns and they expected the same. If the workspace
    /// hasn't sync'd yet, fall back to a sane PT-BR default set
    /// so the board still has columns to render.
    private var visibleStatuses: [CUStatus] {
        if !appState.availableStatuses.isEmpty {
            return appState.availableStatuses
        }
        return [
            CUStatus(status: "to do",     color: "#54577E", type: "open"),
            CUStatus(status: "doing",     color: "#B0612E", type: "custom"),
            CUStatus(status: "review",    color: "#7A6597", type: "custom"),
            CUStatus(status: "liberado",  color: "#9A7B1F", type: "custom"),
            CUStatus(status: "concluído", color: "#1F7A3A", type: "done"),
            CUStatus(status: "cancelado", color: "#C7321B", type: "closed"),
        ]
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Column
    // ────────────────────────────────────────────────────────────────────

    /// True when the board is in a cold-start state: no source
    /// tasks loaded yet AND a sync is in flight. Drives the
    /// skeleton placeholders. Once data lands, an empty column
    /// renders nothing (matches TaskListView / MyTasks gating).
    private var isColdLoading: Bool {
        appState.tasks.isEmpty && appState.isSyncing
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Local card ordering (view-only, never synced to ClickUp)
    // ────────────────────────────────────────────────────────────────────

    /// Decoded `[statusKey: [taskId]]` order map.
    private var cardOrder: [String: [String]] {
        (try? JSONDecoder().decode([String: [String]].self,
                                   from: Data(cardOrderRaw.utf8))) ?? [:]
    }

    /// Persist a new order map back into AppStorage.
    private func setCardOrder(_ dict: [String: [String]]) {
        guard let data = try? JSONEncoder().encode(dict),
              let str  = String(data: data, encoding: .utf8) else { return }
        cardOrderRaw = str
    }

    /// Raw (server-order) cards for a status key.
    private func columnCards(_ statusKey: String) -> [CUTask] {
        boardTasks.filter { $0.status.lowercased() == statusKey }
    }

    /// Apply the user's saved local order: cards present in the saved
    /// list sort by their stored index; cards absent (newly synced)
    /// keep their natural relative order and fall to the end.
    private func orderedCards(_ cards: [CUTask], statusKey: String) -> [CUTask] {
        let saved = cardOrder[statusKey] ?? []
        let pos = Dictionary(saved.enumerated().map { ($1, $0) },
                             uniquingKeysWith: { a, _ in a })
        return cards.enumerated().sorted { a, b in
            switch (pos[a.element.id], pos[b.element.id]) {
            case let (.some(x), .some(y)): return x < y
            case (.some, .none):           return true
            case (.none, .some):           return false
            case (.none, .none):           return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Move the dragged card to sit immediately BEFORE `targetId` in the
    /// given column's local order, then persist. Used live from the
    /// card-level drop delegate's `dropEntered` (wrapped in
    /// `withAnimation` so the surrounding cards reflow under the cursor).
    private func reorder(dragInFrontOf targetId: String, statusKey: String) {
        var ids = orderedCards(columnCards(statusKey), statusKey: statusKey).map(\.id)
        let moving = ids.filter { draggingTaskIds.contains($0) }
        guard !moving.isEmpty, !moving.contains(targetId), ids.contains(targetId) else { return }
        ids.removeAll { moving.contains($0) }
        guard let insertAt = ids.firstIndex(of: targetId) else { return }
        ids.insert(contentsOf: moving, at: insertAt)
        var dict = cardOrder
        dict[statusKey] = ids
        setCardOrder(dict)
    }

    /// Place `dragId` before `targetId` after a CROSS-column drop (the
    /// task's status was just changed to this column), so it lands where
    /// the user dropped it rather than at the column's tail.
    private func place(_ dragIds: [String], before targetId: String, statusKey: String) {
        var ids = orderedCards(columnCards(statusKey), statusKey: statusKey).map(\.id)
        ids.removeAll { dragIds.contains($0) }
        let insertAt = ids.firstIndex(of: targetId) ?? ids.count
        ids.insert(contentsOf: dragIds, at: insertAt)
        var dict = cardOrder
        dict[statusKey] = ids
        setCardOrder(dict)
    }

    private func column(for status: CUStatus) -> some View {
        let statusKey = status.status.lowercased()
        let cards = orderedCards(columnCards(statusKey), statusKey: statusKey)
        let isDropTarget = dragOverStatus == statusKey
        return VStack(alignment: .leading, spacing: 12) {
            // Header stays PINNED at the top of the column even
            // when its cards scroll — the column's own height is
            // the available chrome height, and only the inner
            // card list scrolls.
            columnHeader(status: status, count: cards.count)
                .padding(.horizontal, 10)   // align with the inset card list

            // Per-column vertical scroll. Each status column
            // scrolls independently; columns with few cards stay
            // tight at the top while a busy column can hold dozens
            // without pushing siblings out of view.
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if cards.isEmpty && isColdLoading {
                        // Cold-start placeholders — 3 skeleton
                        // cards per column give the user a
                        // sense of "stuff is loading", not
                        // "the board is empty". Replaced by
                        // real BoardCard rows as soon as tasks
                        // come in.
                        ForEach(0..<3, id: \.self) { i in
                            EditorialSkeletonCard()
                                .cascadeAppear(index: i)
                        }
                    }
                    ForEach(cards, id: \.id) { task in
                        let selected = selectedTaskIds.contains(task.id)
                        BoardCardRow(
                            task: task,
                            appState: appState,
                            status: status,
                            isSelected: selected,
                            draggingTaskId: $draggingTaskId,
                            draggingTaskIds: $draggingTaskIds,
                            dragOverStatus: $dragOverStatus,
                            contextActions: selected
                                ? TaskBulkActions.actions(for: selectedTasks,
                                                        appState: appState)
                                : nil,
                            onActivate: { modifiers, rect in
                                activate(task, modifiers: modifiers, rect: rect)
                            },
                            onBeginDrag: {
                                dragProvider(for: task)
                            },
                            onReorder: { targetId in
                                // Gentle bouncy reflow — the surrounding
                                // cards lightly overshoot and settle as
                                // they make room, so the rearrangement
                                // reads as physical without feeling springy.
                                withAnimation(.bouncy(duration: 0.40,
                                                      extraBounce: 0.12)) {
                                    reorder(dragInFrontOf: targetId,
                                            statusKey: statusKey)
                                }
                            },
                            onCrossColumnPlace: { dragIds, targetId in
                                place(dragIds, before: targetId,
                                      statusKey: statusKey)
                            }
                        )
                    }
                    addCardPlaceholder(for: status)
                        .padding(.top, 4)
                }
                // Horizontal + vertical breathing room INSIDE the scroll so the
                // cards' hover shadow (incl. its soft blur tail, wider than the
                // radius) isn't clipped by the ScrollView bounds.
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)
        }
        // Soft drop-target wash: tint the whole column when a card from
        // another status hovers it. Horizontal padding moved INSIDE (header +
        // card list) so the card shadow has room before the scroll clip.
        .padding(.vertical, 8)
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
            dragOverStatus: $dragOverStatus,
            draggingTaskId: $draggingTaskId,
            draggingTaskIds: $draggingTaskIds
        ))
    }

    private func columnHeader(status: CUStatus, count: Int) -> some View {
        // `statusHex` (not raw `hex`) so the colour gets the dark-mode
        // vibrancy/brightening like every other status surface.
        let color = Color(statusHex: status.displayHex)
        return HStack(spacing: 9) {
            // Status label sits in a Liquid Glass pill tinted with the
            // status accent colour — matches the prototype, where each
            // column heading read as a coloured glass chip.
            HStack(spacing: 7) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(status.status.uppercased())
                    .font(Editorial.sans(10.5, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(color)
                    .lineLimit(1)
                Text("\(count)")
                    .font(Editorial.sans(11, .semibold))
                    .foregroundStyle(color.opacity(0.6))
                    .monospacedDigit()
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .modifier(StatusGlassPill(color: color))

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
struct BoardCard: View {
    let task: CUTask
    @EnvironmentObject var appState: AppState

    /// Hover state — drives the subtle lift + drop shadow that
    /// signals the card is interactive. Local @State so it
    /// doesn't touch AppState (no observer cascade).
    @State private var hover: Bool = false

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
        // chrome paper / desktop don't bleed through.
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Editorial.page)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Editorial.rule, lineWidth: 0.5)
        )
        // Hover lift: a drop shadow tinted with the task's status accent
        // (no scale — the colour, not the size, signals "ready"). Fades to
        // zero opacity at rest so the card stays flat-Editorial-Calm.
        .shadow(color: hover ? Color(statusHex: task.statusDisplayHex).opacity(0.5) : .clear,
                radius: hover ? 4 : 0,
                x: 0,
                y: hover ? 2 : 0)
        .animation(.easeOut(duration: 0.16), value: hover)
        .onHover { entering in
            hover = entering && !appState.anyPopupOpen
        }
        .onChange(of: appState.anyPopupOpen) { _, open in
            if open { hover = false }
        }
    }

    // ── Top row: status dot + breadcrumb caps + priority chip ──────────

    private var topRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(statusHex: task.statusDisplayHex))
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

    @ViewBuilder
    private var avatar: some View {
        if task.assignees.isEmpty {
            // No assignee — neutral placeholder dot.
            Circle()
                .fill(Color(statusHex: assigneeColorHex))
                .frame(width: 18, height: 18)
                .overlay(Text("·").font(Editorial.sans(9, .bold)).foregroundStyle(.white))
        } else {
            // Stacked photos (initials fallback) for one-or-many responsáveis.
            AvatarStack(assignees: task.assignees, size: 18, maxShown: 3)
        }
    }

    private var firstName: String {
        let raw = task.assignees.first?.username ?? ""
        let token = raw.split(whereSeparator: { " ._-".contains($0) }).first ?? ""
        return token.isEmpty ? "Sem responsável" : token.prefix(1).uppercased() + token.dropFirst()
    }

    private var assigneeColorHex: String {
        // Studio Glass: o cinabre saiu da paleta de avatar (era a
        // cor de marca antiga). Entrou o teal dos role-tints do
        // Galileo — NÃO o roxo accent, que já tem um violeta
        // (#8B5CF6) aqui e criaria dois avatares quase iguais.
        let palette = ["#8B5CF6", "#2E6E6A", "#3F6B4A", "#4F8EF7",
                       "#9A7B1F", "#7A6597", "#B0612E", "#54577E"]
        let key = task.assignees.first?.username ?? task.id
        var h = 0
        for u in key.unicodeScalars { h = (h &* 31) &+ Int(u.value) }
        return palette[abs(h) % palette.count]
    }

    @ViewBuilder
    private var dateLabel: some View {
        if let due = task.dueDate {
            let today = Calendar.current.isDateInToday(due)
            let overdue = due < Calendar.current.startOfDay(for: Date())
                && !task.isCompleted
            let color = today ? Editorial.accent
                : (overdue ? Editorial.overdue : Editorial.inkMute)
            HStack(spacing: 3) {
                Text(relativeDate(due))
                    .font(Editorial.sans(11, .medium))
                    .foregroundStyle(color)
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(today || overdue ? color : Editorial.inkFaint)
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
        return SharedDateFormatters.dayOfMonthAbbrevPTBR.string(from: d)
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
// MARK: - Board card row (with frame capture for the morph)
// ────────────────────────────────────────────────────────────────────────

/// Wraps a `BoardCard` with frame tracking in the "appWindow"
/// coordinate space so the TaskDetail popup can morph OUT OF
/// (and back INTO) the card's actual rect — not the cursor
/// position. `MouseOriginCapture` returns a 2×2 rect at the
/// cursor, which makes the popup pop out of a pixel-sized
/// point rather than the card's footprint. This row owns its
/// own @State for the captured frame and re-publishes it via
/// `captureFrame` on every layout pass.
private struct BoardCardRow: View {
    let task: CUTask
    let appState: AppState
    /// The column this card lives in.
    let status: CUStatus
    let isSelected: Bool
    /// Shared "which card is being dragged" state, owned by the board.
    @Binding var draggingTaskId: String?
    @Binding var draggingTaskIds: [String]
    @Binding var dragOverStatus: String?
    let contextActions: [TaskContextAction]?
    let onActivate: (_ modifiers: NSEvent.ModifierFlags, _ rect: CGRect) -> Void
    let onBeginDrag: () -> NSItemProvider
    /// Live in-column reorder: move the dragged card before THIS card.
    let onReorder: (_ targetId: String) -> Void
    /// After a cross-column status change, place the dropped card before
    /// THIS card in the destination's local order.
    let onCrossColumnPlace: (_ dragIds: [String], _ targetId: String) -> Void

    @State private var cardFrame: CGRect = .zero

    private var isDragging: Bool { draggingTaskIds.contains(task.id) }

    var body: some View {
        BoardCard(task: task)
            .captureFrame($cardFrame)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Editorial.accent.opacity(0.055))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Editorial.accent.opacity(0.62), lineWidth: 1.2)
                        }
                        .allowsHitTesting(false)
                }
            }
            // The source card dims + shrinks slightly while it's the one
            // under the cursor, so the moving preview reads as "lifted
            // out" and the gap it leaves is obvious as siblings reflow.
            .opacity(isDragging ? 0.35 : 1)
            .scaleEffect(isDragging ? 0.98 : 1)
            // Gentle bouncy lift/settle so the source card softly springs
            // as it's picked up and eases back into the flow on drop.
            .animation(.bouncy(duration: 0.34, extraBounce: 0.12),
                       value: isDragging)
            .onDrag {
                onBeginDrag()
            } preview: {
                if draggingTaskIds.count > 1 {
                    HStack(spacing: 9) {
                        Image(systemName: "rectangle.stack")
                        Text("\(draggingTaskIds.count) tarefas")
                            .lineLimit(1)
                    }
                    .font(Editorial.sans(12.5, .semibold))
                    .foregroundStyle(Editorial.ink)
                    .padding(.horizontal, 14)
                    .frame(width: 260, height: 44, alignment: .leading)
                    .background(.regularMaterial,
                                in: RoundedRectangle(cornerRadius: 11,
                                                     style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
                } else {
                    BoardCard(task: task)
                        .frame(width: 260)
                        .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
                }
            }
            // Card-level drop target → live vertical reorder. As the
            // dragged card hovers this one, `dropEntered` slots it into
            // this position and the column reflows under the cursor
            // (animation supplied by the board's `onReorder` closure).
            .onDrop(of: [.text], delegate: CardReorderDropDelegate(
                targetId: task.id,
                status: status,
                appState: appState,
                draggingTaskId: $draggingTaskId,
                draggingTaskIds: $draggingTaskIds,
                dragOverStatus: $dragOverStatus,
                onReorder: onReorder,
                onCrossColumnPlace: onCrossColumnPlace
            ))
            .contextMenu {
                TaskContextMenuItems(actions: contextActions
                    ?? TaskContextMenu.actions(for: task, appState: appState))
            }
            .onTapGesture {
                let rect = cardFrame != .zero
                    ? cardFrame
                    : MouseOriginCapture.currentClickRectInMainWindow()
                onActivate(NSEvent.modifierFlags, rect)
            }
    }
}

// ────────────────────────────────────────────────────────────────────────
// MARK: - Card-level reorder drop delegate
// ────────────────────────────────────────────────────────────────────────

/// Drop target attached to EACH card so the user can reorder cards
/// vertically WITHIN a column (a local viewing preference — never
/// written to ClickUp) and, when a card is dragged in from another
/// column, drop it at a precise slot.
///
/// • Same-column drag → `dropEntered` calls `onReorder(targetId)` live,
///   so cards reflow to make room while the cursor is still moving.
/// • Cross-column drag → `performDrop` changes the task's status to this
///   column (the only ClickUp write), then places it locally at the drop
///   slot via `onCrossColumnPlace`.
private struct CardReorderDropDelegate: DropDelegate {
    let targetId: String
    let status: CUStatus
    let appState: AppState
    @Binding var draggingTaskId: String?
    @Binding var draggingTaskIds: [String]
    @Binding var dragOverStatus: String?
    let onReorder: (_ targetId: String) -> Void
    let onCrossColumnPlace: (_ dragIds: [String], _ targetId: String) -> Void

    private var statusKey: String { status.status.lowercased() }

    /// The status the dragged task currently belongs to.
    private var draggedStatusKey: String? {
        guard let id = draggingTaskId,
              let t = appState.tasks.first(where: { $0.id == id })
        else { return nil }
        return t.status.lowercased()
    }

    func dropEntered(info: DropInfo) {
        // Live reorder only when staying within the same column — a
        // cross-column drag just lights the destination column (handled
        // by the column-level delegate) until it's dropped.
        if draggedStatusKey == statusKey {
            onReorder(targetId)
        } else {
            dragOverStatus = statusKey
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func performDrop(info: DropInfo) -> Bool {
        let primaryId = draggingTaskId
        let ids = draggingTaskIds.isEmpty
            ? primaryId.map { [$0] } ?? []
            : draggingTaskIds
        draggingTaskId = nil
        draggingTaskIds.removeAll()
        dragOverStatus = nil
        guard !ids.isEmpty else { return false }

        let needsStatusChange = ids.contains { id in
            appState.tasks.first(where: { $0.id == id })?.status.lowercased() != statusKey
        }
        if needsStatusChange {
            Task { @MainActor in
                for id in ids {
                    guard let task = appState.tasks.first(where: { $0.id == id }),
                          task.status.lowercased() != statusKey else { continue }
                    await appState.updateTaskStatus(task, to: status, silent: true)
                }
                onCrossColumnPlace(ids, targetId)
            }
        }
        // Same-column reorder was already applied live in dropEntered;
        // the persisted order is current, nothing more to do.
        return true
    }
}

// ────────────────────────────────────────────────────────────────────────
// MARK: - Shared popup-size helper
// ────────────────────────────────────────────────────────────────────────

/// Mirrors `TaskDetailSheet.computeSize(for:)` — kept in sync by
/// hand so the BoardCard morph and the popup's
/// `MorphFromRectModifier` agree on the SAME target rect at
/// progress = 1. If TaskDetailSheet's formula changes this
/// helper must change with it.
func taskDetailNaturalSize(for window: CGSize) -> CGSize {
    let topReserved:  CGFloat = 64
    let sideReserved: CGFloat = 16
    let safeMaxH = max(280, window.height - 2 * topReserved)
    let safeMaxW = max(520, window.width  - 2 * sideReserved)
    let preferredH = min(1200, max(560, window.height * 0.90))
    let preferredW = min(1200, max(720, window.width  * 0.85))
    return CGSize(
        width:  min(preferredW, safeMaxW),
        height: min(preferredH, safeMaxH)
    )
}

// ────────────────────────────────────────────────────────────────────────
// MARK: - Status header glass pill
// ────────────────────────────────────────────────────────────────────────

/// Liquid Glass chip tinted with the status accent colour, used behind
/// each board column heading (dot + name + count). On macOS 26+ it's a
/// real Liquid Glass material with a coloured tint; older systems fall
/// back to a translucent accent fill. Both carry a faint accent border.
private struct StatusGlassPill: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        // NOTE: deliberately NOT `.glassEffect` here. The board's column
        // headers live inside a horizontal `ScrollView`, and the real
        // Liquid Glass material recomputes its adaptive shadow as the
        // pill moves — producing a transient shadow that flickered on
        // the LEFT of each status pill during a horizontal scroll. A
        // frosted `.ultraThinMaterial` capsule tinted with the status
        // colour keeps the glassy translucent look WITHOUT that
        // scroll-time shadow artifact.
        let shape = Capsule(style: .continuous)
        content
            .background(
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(color.opacity(0.16))
                }
            )
            .overlay(shape.strokeBorder(color.opacity(0.22), lineWidth: 0.6))
    }
}

// ────────────────────────────────────────────────────────────────────────
// MARK: - Board-level reset drop delegate (catch-all)
// ────────────────────────────────────────────────────────────────────────

/// Outermost drop target on the whole board. Inner column/card
/// delegates consume drops over them; this one only ever fires for a
/// drop that lands on board chrome (gutters, header gap). Its sole job
/// is to clear the transient drag state so a released card always
/// returns from its ghost placeholder to full opacity.
private struct BoardResetDropDelegate: DropDelegate {
    @Binding var draggingTaskId: String?
    @Binding var draggingTaskIds: [String]
    @Binding var dragOverStatus: String?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingTaskId = nil
        draggingTaskIds.removeAll()
        dragOverStatus = nil
        return false
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
    @Binding var draggingTaskId: String?
    @Binding var draggingTaskIds: [String]

    func dropEntered(info: DropInfo) {
        dragOverStatus = targetStatus.status.lowercased()
    }

    func dropExited(info: DropInfo) {
        if dragOverStatus == targetStatus.status.lowercased() {
            dragOverStatus = nil
        }
    }

    // Advertise MOVE (not the default COPY) so the cursor shows the
    // plain move indicator instead of a green "+" — the card already
    // belongs to the board, nothing is being added.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func performDrop(info: DropInfo) -> Bool {
        // Always clear the drag state so the source card un-dims even
        // when the drop lands in the column gutter (not on a card) —
        // otherwise it would stay stuck in its ghost placeholder look.
        draggingTaskId = nil
        draggingTaskIds.removeAll()
        guard let provider = info.itemProviders(for: [.text]).first
        else { dragOverStatus = nil; return false }
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let raw = obj as? String else { return }
            let ids = MyTasksDragPayload.decode(raw)
            Task { @MainActor in
                for id in ids {
                    guard let task = appState.tasks.first(where: { $0.id == id }),
                          task.status.lowercased() != targetStatus.status.lowercased()
                    else { continue }
                    // Every task uses AppState's own optimistic mutation and
                    // per-task rollback path; one failed request cannot leave
                    // a card stranded in an invented local status.
                    await appState.updateTaskStatus(task,
                                                    to: targetStatus,
                                                    silent: true)
                }
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
