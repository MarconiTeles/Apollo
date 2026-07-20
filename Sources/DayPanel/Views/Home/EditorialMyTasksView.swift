import SwiftUI
import AppKit

// Apollo · Editorial+ "Minhas tarefas".
//
// List view counterpart to Quadro: every task in the currently
// selected ClickUp list, grouped by status and narrowed by the same
// global filters. This keeps list and board as two presentations of
// one identical data universe.
//
// Routes from `sidebarRoute == .tasks` in ContentView.

struct EditorialMyTasksView: View {
    @EnvironmentObject var appState: AppState

    /// Status names the user has collapsed manually. Empty by
    /// default → every group renders expanded. Stored in
    /// AppStorage so the layout persists between sessions.
    @AppStorage("dp_myTasks_collapsedStatuses_v1")
    private var collapsedRaw: String = ""

    @State private var selectedTaskIds: Set<String> = []
    @State private var selectionAnchorId: String?
    @State private var draggingTaskIds: Set<String> = []
    @State private var dragOverStatus: String?
    /// Gives SwiftUI one responsive frame to paint a truthful skeleton
    /// before constructing the recycled task rows on route/list changes.
    @State private var listMountReady = false
    @State private var mediaFlowRequest: TaskMediaFlowRequest?
    @ObservedObject private var reviewQueuePresenter = TaskReviewQueuePresenter.shared
    @ObservedObject private var columnLayout = MyTasksColumnLayout.shared
    /// The column boundary currently hovered or dragged — drives the accent guide.
    @State private var activeBoundary: MyTasksColumnLayout.Column?

    /// Sticky chrome height (52pt toolbar band + title row + column-header
    /// row) — one continuous glass element up to the window top. Rows start
    /// below it but scroll through underneath.
    // 132pt is the measured toolbar + route title + column-header chrome.
    // The additional 30pt is deliberate breathing room before the first
    // status group, while rows can still scroll back underneath the material.
    private let chromeInset: CGFloat = 162

    var body: some View {
        GeometryReader { geo in
            let m = columnLayout.metrics(totalWidth: geo.size.width)
            ZStack(alignment: .top) {
                // The table owns the full canvas. The chrome (title + column
                // header) is layered above it so rows stay visible while
                // scrolling, matching a native macOS titlebar.
                content
                // Full-height accent guide at the boundary being hovered/dragged.
                if let col = activeBoundary, let hx = m.handleX[col] {
                    Rectangle()
                        // Finder-style divider feedback: deliberately faint
                        // neutral gray, never the app accent.
                        .fill(Editorial.rule.opacity(0.7))
                        .frame(width: 1, height: geo.size.height)
                        .position(x: hx, y: geo.size.height / 2)
                        .allowsHitTesting(false)
                        .zIndex(1)
                }
                stickyChrome(totalWidth: geo.size.width)
                    .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if !selectedTasks.isEmpty {
                // ContentView already lays this route out to the right of the
                // 220pt sidebar. Adding another sidebar spacer here shifted the
                // capsule right and clipped it. Centre in the real route canvas.
                bulkToolbar
                    .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.bottom, 34)
                .transition(.move(edge: .bottom)
                    .combined(with: .opacity)
                    .combined(with: .scale(scale: 0.96, anchor: .bottom)))
                .zIndex(3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Editorial.paper)
        .background {
            EscapeSelectionMonitor(isActive: !selectedTaskIds.isEmpty,
                                   onEscape: clearSelection)
                .frame(width: 0, height: 0)
        }
        .onExitCommand(perform: clearSelection)
        .onReceive(NotificationCenter.default.publisher(for: .apolloTaskDropCompleted)) { _ in
            clearSelection()
        }
        .onChange(of: visibleTaskIds) { _, ids in
            selectedTaskIds.formIntersection(ids)
            if let anchor = selectionAnchorId, !ids.contains(anchor) {
                selectionAnchorId = nil
            }
        }
        .task(id: activeListId) {
            listMountReady = false
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                listMountReady = true
            }
        }
        .sheet(item: $mediaFlowRequest) { request in
            TaskMediaFlowSheet(store: appState.taskMediaTransfers, request: request)
                .environmentObject(appState)
        }
        .sheet(item: $reviewQueuePresenter.request) { request in
            TaskReviewsFlowSheet(request: request)
                .environmentObject(appState)
        }
        .apolloStudioNode("tasks.page",
                          title: "Página de tarefas",
                          kind: .page,
                          parent: "app.root",
                          properties: [
                            .init(kind: .verticalPadding,
                                  title: "Altura do chrome", value: chromeInset),
                            .init(kind: .backgroundColor,
                                  title: "Canvas", token: "Editorial.paper"),
                          ])
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Header
    // ────────────────────────────────────────────────────────────────────

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            HStack(spacing: 10) {
                Text(headerTitle)
                    .font(Editorial.sans(11, .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Editorial.inkSoft)
                Text("\(totalCount)")
                    .font(Editorial.sans(11, .medium))
                    .foregroundStyle(Editorial.inkFaint)
                    .monospacedDigit()
            }
            Spacer(minLength: 24)
            Text("¶ toda a lista selecionada, agrupada por status.")
                .font(Editorial.serif(12).italic())
                .foregroundStyle(Editorial.inkMute)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
    }

    /// Title row + the resizable column-header row, stacked as one sticky band
    /// above the list. Liquid Glass: the rows scroll through underneath (the
    /// NSScrollView's top contentInset starts them below, but scrolled content
    /// passes behind and refracts) — same recipe as the popup header bars.
    @ViewBuilder
    private func stickyChrome(totalWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Linha "MINHAS TAREFAS · LISTA · N | tagline" REMOVIDA (inútil,
            // só ocupava altura). Sobra a reserva da toolbar (52pt) + a linha
            // de colunas — o header enxuto.
            Color.clear.frame(height: 52)
            if showsColumnHeader {
                MyTasksColumnHeader(layout: columnLayout,
                                    totalWidth: totalWidth,
                                    activeBoundary: $activeBoundary)
                    .frame(height: 30)
            }
        }
        // ContentView keeps this route's usable table canvas 220pt to the
        // right of the floating sidebar. The material itself must not inherit
        // that inset: it is one continuous Finder-style band behind the pane.
        .finderHeaderMaterial(leadingExtension: 220)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Editorial.rule.opacity(0.6)).frame(height: 1)
                .padding(.leading, -220)
        }
    }

    /// The column header only makes sense once the real task list is on screen.
    private var showsColumnHeader: Bool {
        appState.clickUpAuthService.userId != nil
            && listMountReady
            && !appState.availableStatuses.isEmpty
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Body
    // ────────────────────────────────────────────────────────────────────

    @ViewBuilder
    private var content: some View {
        if appState.clickUpAuthService.userId == nil {
            emptyState(title: "Conecte sua conta ClickUp",
                       caption: "Faça login para ver suas tarefas atribuídas.")
        } else if !listMountReady || (allListTasks.isEmpty && appState.isSyncing) {
            MyTasksLoadingPlaceholder()
                .transition(.opacity)
        } else if appState.availableStatuses.isEmpty {
            emptyState(title: "Status indisponíveis",
                       caption: "Sincronize a lista para carregar suas categorias.")
        } else {
            MyTasksAppKitList(
                sections: nativeSections,
                selectedTaskIds: selectedTaskIds,
                appState: appState,
                topContentInset: chromeInset,
                // Reserve the bulk-action capsule only while it actually
                // exists. A permanent 112pt NSScrollView inset left visible
                // rows inside a non-interactive bottom band.
                bottomContentInset: selectedTasks.isEmpty ? 12 : 112,
                onActivate: { task, modifiers, rect in
                    activate(task, modifiers: modifiers, origin: rect)
                },
                onToggleStatus: { toggleCollapsed($0) },
                onBeginDrag: { beginDragIds(for: $0) },
                onEndDrag: { completed in
                    draggingTaskIds.removeAll()
                    if completed { clearSelection() }
                },
                onClearSelection: clearSelection,
                onMediaAction: { task, mode in
                    mediaFlowRequest = TaskMediaFlowRequest(task: task, mode: mode)
                }
            )
            .apolloStudioNode("tasks.list",
                              title: "Lista de tarefas",
                              kind: .list,
                              parent: "tasks.page",
                              properties: [
                                .init(kind: .verticalPadding,
                                      title: "Inset superior", value: chromeInset),
                                .init(kind: .height,
                                      title: "Altura da linha", value: 36),
                              ])
        }
    }

    private var nativeSections: [MyTasksAppKitSection] {
        groups.map { group in
            let key = group.status.status.lowercased()
            return MyTasksAppKitSection(status: group.status,
                                        tasks: group.tasks,
                                        collapsed: collapsedSet.contains(key))
        }
    }

    /// Linearised representation of the grouped list so the
    /// cascade modifier can index the whole canvas uniformly
    /// (headers + rows together).
    private enum FlatRow: Identifiable {
        case header(status: CUStatus, count: Int, collapsed: Bool)
        case task(CUTask, statusKey: String)
        var id: String {
            switch self {
            case .header(let s, _, _): return "h:\(s.id)"
            case .task(let t, let s):  return "t:\(s):\(t.id)"
            }
        }
    }
    private var flattenedRows: [FlatRow] {
        var out: [FlatRow] = []
        for g in groups {
            let key = g.status.status.lowercased()
            let coll = collapsedSet.contains(key)
            out.append(.header(status: g.status, count: g.tasks.count, collapsed: coll))
            if !coll {
                for t in g.tasks { out.append(.task(t, statusKey: key)) }
            }
        }
        return out
    }

    @ViewBuilder
    private func rowOrHeader(_ row: FlatRow, isFirst: Bool) -> some View {
        switch row {
        case .header(let s, let c, let collapsed):
            VStack(alignment: .leading, spacing: 0) {
                if !isFirst {
                    Color.clear.frame(height: 18)   // group spacer
                }
                groupHeader(status: s, count: c, collapsed: collapsed)
            }
            .onDrop(of: [.text], delegate: MyTasksStatusDropDelegate(
                targetStatus: s,
                appState: appState,
                draggingTaskIds: $draggingTaskIds,
                dragOverStatus: $dragOverStatus
            ))
        case .task(let t, let statusKey):
            // Reuse the dashboard cell — swipe actions + DONE button +
            // hover haptics — instead of the old static `taskRow`.
            // Wrapped in `SwipeCellHost` so the two-finger swipe wires
            // up in this pure-SwiftUI list (no NSCollectionListView host
            // here). The transition makes the row slide + fade when its
            // status section collapses/expands (driven by `toggleCollapsed`).
            SwipeCellHost {
                TaskRowView(
                    task: t,
                    appState: appState,
                    onActivate: { flags in
                        activate(t,
                                 modifiers: flags,
                                 origin: MouseOriginCapture.currentClickRectInMainWindow())
                    },
                    contextActions: selectedTaskIds.contains(t.id)
                        ? TaskBulkActions.actions(for: selectedTasks,
                                                  appState: appState)
                        : nil
                )
            }
                .frame(maxWidth: .infinity)
                .taskSelectionSurface(selectedTaskIds.contains(t.id), tint: .black)
                .opacity(draggingTaskIds.contains(t.id) ? 0.42 : 1)
                .onDrag {
                    dragProvider(for: t)
                } preview: {
                    dragPreview(for: t)
                }
                .onDrop(of: [.text], delegate: MyTasksStatusDropDelegate(
                    targetStatus: status(forKey: statusKey, fallbackTask: t),
                    appState: appState,
                    draggingTaskIds: $draggingTaskIds,
                    dragOverStatus: $dragOverStatus
                ))
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal:   .opacity.combined(with: .move(edge: .top))
                ))
        }
    }

    private func emptyState(title: String, caption: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(Editorial.serif(20, .medium))
                .foregroundStyle(Editorial.ink)
            Text(caption)
                .font(Editorial.serif(13).italic())
                .foregroundStyle(Editorial.inkMute)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 80)
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Multi-selection + bulk commands
    // ────────────────────────────────────────────────────────────────────

    private var bulkToolbar: some View {
        TaskBulkToolbar(tasks: selectedTasks,
                        appState: appState,
                        onClear: clearSelection)
    }

    private func activate(_ task: CUTask,
                          modifiers: NSEvent.ModifierFlags,
                          origin: CGRect) {
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
            ordered: orderedVisibleTasks.map(\.id),
            intent: intent
        )
        if resolution.shouldOpen {
            appState.openTaskDetail(
                task,
                origin: origin,
                navigationTasks: orderedVisibleTasks,
                style: .bottomSlide
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
        let ids = beginDragIds(for: task)
        return NSItemProvider(object: MyTasksDragPayload.encode(ids) as NSString)
    }

    private func beginDragIds(for task: CUTask) -> [String] {
        let ids = TaskDragSelectionResolver.draggedIDs(
            dragged: task.id,
            selected: selectedTaskIds,
            ordered: orderedVisibleTasks.map(\.id)
        )
        draggingTaskIds = Set(ids)
        return ids
    }

    private func dragPreview(for task: CUTask) -> some View {
        TaskDragStackPreview(
            tasks: selectedTaskIds.contains(task.id) ? selectedTasks : [task],
            primary: task,
            width: 280
        )
    }

    private func status(forKey key: String, fallbackTask: CUTask) -> CUStatus {
        appState.availableStatuses.first { $0.status.lowercased() == key }
            ?? CUStatus(status: fallbackTask.status,
                        color: fallbackTask.statusColor,
                        type: fallbackTask.isCompleted ? "closed" : "custom")
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Groups
    // ────────────────────────────────────────────────────────────────────

    private var activeListId: String {
        appState.activeListId
    }

    private var activeListName: String {
        appState.activeListName
    }

    private var headerTitle: String {
        let suffix = activeListName.isEmpty ? "LISTA SELECIONADA" : activeListName.uppercased()
        return "MINHAS TAREFAS · \(suffix)"
    }

    /// Exact active-list work universe shown by Quadro/sidebar: open
    /// tasks only. Closed history stays outside this operational list;
    /// including it inflated a 330-item list to 1,000 rows and could
    /// stall the SwiftUI canvas while mounting the first viewport.
    private var allListTasks: [CUTask] {
        TaskSurfaceScope.openTasks(in: appState.tasks,
                                   activeListId: activeListId)
    }

    private var visibleListTasks: [CUTask] {
        appState.taskFilters.applying(to: allListTasks)
    }

    private var visibleTaskIds: [String] { visibleListTasks.map(\.id) }

    /// Selection follows current on-screen order, not AppState storage
    /// order, so a Shift range always matches what is visibly between
    /// the first and last clicked rows.
    private var orderedVisibleTasks: [CUTask] {
        flattenedRows.compactMap { row in
            guard case .task(let task, _) = row else { return nil }
            return task
        }
    }

    private var selectedTasks: [CUTask] {
        guard !selectedTaskIds.isEmpty else { return [] }
        let byId = Dictionary(uniqueKeysWithValues: visibleListTasks.map { ($0.id, $0) })
        let ordered = orderedVisibleTasks.compactMap { task in
            selectedTaskIds.contains(task.id) ? byId[task.id] : nil
        }
        // A selected task may sit inside a status the user collapsed after
        // selecting it. Keep it actionable and append it deterministically.
        let orderedIds = Set(ordered.map(\.id))
        let hidden = selectedTaskIds.subtracting(orderedIds)
            .compactMap { byId[$0] }
            .sorted { $0.id < $1.id }
        return ordered + hidden
    }

    private var totalCount: Int { visibleListTasks.count }

    /// (status, tasks) tuples in workspace-status order. Every workspace
    /// status remains present even when its task array is empty: the header
    /// is a stable AppKit drop destination, so moving the last task out of a
    /// category never removes the path for dragging a task back into it.
    /// Tasks within each status are sorted by (overdue first → due date
    /// ascending → no-date last → priority).
    private var groups: [(status: CUStatus, tasks: [CUTask])] {
        let byStatus = Dictionary(grouping: visibleListTasks, by: { $0.status.lowercased() })
        // Same full status universe as Quadro, including closed lanes.
        let visible = appState.availableStatuses.reversed()
        return visible.map { s in
            let lc = s.status.lowercased()
            let ts = byStatus[lc] ?? []
            return (s, sorted(ts))
        }
    }

    private func sorted(_ tasks: [CUTask]) -> [CUTask] {
        // Clock snapshotted ONCE — a per-comparison `Date()`
        // violates strict-weak-ordering (the "overdue" flag can
        // flip mid-sort) and reshuffled near-tied rows on every
        // render. Same bug class fixed in AppState's main sort.
        let now = Date()
        return tasks.sorted { a, b in
            let aOver = (a.dueDate.map { $0 < now } ?? false)
            let bOver = (b.dueDate.map { $0 < now } ?? false)
            if aOver != bOver { return aOver }                  // overdue first
            switch (a.dueDate, b.dueDate) {
            case let (.some(ad), .some(bd)):
                if ad != bd { return ad < bd }                  // earlier date first
            case (.some, .none): return true                    // dated before undated
            case (.none, .some): return false
            case (.none, .none): break
            }
            if a.priority != b.priority {
                // ClickUp priority: 1 (Urgent) → 4 (Low), 0 = none
                let aP = a.priority == 0 ? 99 : a.priority
                let bP = b.priority == 0 ? 99 : b.priority
                return aP < bP
            }
            let t = a.title.localizedCaseInsensitiveCompare(b.title)
            if t != .orderedSame { return t == .orderedAscending }
            // Deterministic tie-break — Swift's sort isn't
            // stable; equal-title rows swapped between renders.
            return a.id < b.id
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Section + rows
    // ────────────────────────────────────────────────────────────────────

    private func groupSection(_ group: (status: CUStatus, tasks: [CUTask])) -> some View {
        let collapsed = collapsedSet.contains(group.status.status.lowercased())
        return VStack(alignment: .leading, spacing: 0) {
            groupHeader(status: group.status,
                        count: group.tasks.count,
                        collapsed: collapsed)
            if !collapsed {
                ForEach(group.tasks, id: \.id) { task in
                    taskRow(task)
                }
            }
            // Soft spacer between status groups.
            Color.clear.frame(height: 18)
        }
    }

    private func groupHeader(status: CUStatus, count: Int, collapsed: Bool) -> some View {
        Button {
            toggleCollapsed(status.status.lowercased())
        } label: {
            HStack(spacing: 10) {
                // Single chevron rotated 0°→90° so the open/close toggle
                // animates smoothly instead of snapping between symbols.
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Editorial.inkFaint)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 12)
                Circle()
                    .fill(Color(hex: status.displayHex))
                    .frame(width: 7, height: 7)
                Text(status.status.uppercased())
                    .font(Editorial.sans(10.5, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color(hex: status.displayHex))
                Text("\(count)")
                    .font(Editorial.sans(11, .semibold))
                    .foregroundStyle(Editorial.inkMute)
                    .monospacedDigit()
                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .background {
                if dragOverStatus == status.status.lowercased() {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(hex: status.displayHex).opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color(hex: status.displayHex).opacity(0.48),
                                              lineWidth: 1)
                        )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .overlay(alignment: .bottom) {
            // Category divider — same 0.65 opacity + soft lateral fade as
            // the task/event row dividers.
            Rectangle().fill(Editorial.rule.opacity(0.65))
                .frame(height: 0.5)
                .edgeFadedHorizontal()
        }
    }

    private func taskRow(_ task: CUTask) -> some View {
        Button {
            appState.openTaskDetail(task,
                                    origin: .zero,
                                    navigationTasks: orderedVisibleTasks,
                                    style: .bottomSlide)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                // Status dot — mirrors the row in the dashboard
                // so the user can scan by category from a row
                // alone without leaving the page.
                Circle()
                    .fill(Color(hex: task.statusDisplayHex))
                    .frame(width: 7, height: 7)

                // Title + breadcrumb (LIST · subtask?)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(Editorial.sans(13, .medium))
                        .foregroundStyle(Editorial.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(rowCrumb(task))
                        .font(Editorial.sans(10.5))
                        .tracking(0.6)
                        .foregroundStyle(Editorial.inkFaint)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Priority chip — only Urgent/Alta surface visually
                if task.priority > 0 && task.priority <= 2 {
                    HStack(spacing: 4) {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(hex: task.priorityHex))
                        Text(priorityLabel(task.priority))
                            .font(Editorial.sans(10, .semibold))
                            .tracking(0.6)
                            .foregroundStyle(Color(hex: task.priorityHex))
                    }
                    .frame(width: 80, alignment: .leading)
                } else {
                    Color.clear.frame(width: 80, height: 1)
                }

                // Due date — cinnabar when overdue, mute otherwise
                dueLabel(task)
                    .frame(width: 110, alignment: .trailing)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .overlay(alignment: .bottom) {
            Rectangle().fill(Editorial.rule.opacity(0.5)).frame(height: 0.5)
        }
    }

    private func rowCrumb(_ task: CUTask) -> String {
        var parts: [String] = []
        if !task.listName.isEmpty { parts.append(task.listName.uppercased()) }
        if task.isSubtask { parts.append("SUBTAREFA") }
        return parts.joined(separator: " · ")
    }

    private func priorityLabel(_ p: Int) -> String {
        switch p {
        case 1: return "URGENTE"
        case 2: return "ALTA"
        case 3: return "NORMAL"
        case 4: return "BAIXA"
        default: return ""
        }
    }

    @ViewBuilder
    private func dueLabel(_ task: CUTask) -> some View {
        if let d = task.dueDate {
            let today = Calendar.current.isDateInToday(d)
            let overdue = d < Calendar.current.startOfDay(for: Date())
            let color = today ? Editorial.accent
                : (overdue ? Editorial.overdue : Editorial.inkSoft)
            Text(relativeDate(d))
                .font(Editorial.sans(11.5, .medium))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
        } else {
            Text("—")
                .font(Editorial.sans(11.5))
                .foregroundStyle(Editorial.inkFaint)
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
        if days > 1 && days < 7   { return "em \(days) dias" }
        if days < -1 && days > -7 { return "\(-days) dias atrás" }
        return SharedDateFormatters.dayOfMonthAbbrevPTBR.string(from: d)
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Collapse state (UserDefaults-backed Set<String>)
    // ────────────────────────────────────────────────────────────────────

    /// Comma-joined to fit `@AppStorage`'s String API. Round-trip
    /// in `collapsedSet` getter / `toggleCollapsed` setter.
    private var collapsedSet: Set<String> {
        Set(collapsedRaw
            .split(separator: ",")
            .map(String.init)
            .filter { !$0.isEmpty })
    }

    private func toggleCollapsed(_ key: String) {
        var set = collapsedSet
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        // Animate the section open/close — rows ride the `.transition`
        // in `rowOrHeader` and the header chevron rotates.
        withAnimation(.easeInOut(duration: 0.26)) {
            collapsedRaw = set.sorted().joined(separator: ",")
        }
    }
}

/// Animated loading state shaped exactly like the single-line task list.
/// One shared pulse drives the whole viewport, avoiding a timer/state
/// machine per placeholder row.
private struct MyTasksLoadingPlaceholder: View {
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            skeletonHeader(width: 96)
            ForEach(0..<3, id: \.self) { _ in skeletonRow }
            Color.clear.frame(height: 16)
            skeletonHeader(width: 76)
            ForEach(0..<6, id: \.self) { _ in skeletonRow }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .opacity(pulse ? 1 : 0.38)
        .animation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true),
                   value: pulse)
        .onAppear { pulse = true }
        .allowsHitTesting(false)
        .accessibilityLabel("Carregando tarefas")
    }

    private func skeletonHeader(width: CGFloat) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Editorial.rule)
                .frame(width: 10, height: 6)
            Circle().fill(Editorial.rule).frame(width: 7, height: 7)
            RoundedRectangle(cornerRadius: 3)
                .fill(Editorial.rule)
                .frame(width: width, height: 9)
            RoundedRectangle(cornerRadius: 3)
                .fill(Editorial.ruleSoft)
                .frame(width: 20, height: 9)
            Spacer()
        }
        .frame(height: 38)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Editorial.ruleSoft).frame(height: 0.5)
        }
    }

    private var skeletonRow: some View {
        HStack(spacing: 14) {
            Circle().fill(Editorial.rule).frame(width: 14, height: 14)
            RoundedRectangle(cornerRadius: 4)
                .fill(Editorial.rule)
                .frame(height: 12)
                .frame(maxWidth: 390)
            Spacer(minLength: 12)
            RoundedRectangle(cornerRadius: 4)
                .fill(Editorial.ruleSoft)
                .frame(width: 74, height: 9)
            HStack(spacing: 7) {
                Circle().fill(Editorial.rule).frame(width: 20, height: 20)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Editorial.rule)
                    .frame(width: 66, height: 10)
            }
            .frame(width: 132, alignment: .leading)
            RoundedRectangle(cornerRadius: 4)
                .fill(Editorial.ruleSoft)
                .frame(width: 54, height: 9)
                .frame(width: 92, alignment: .trailing)
            Circle().fill(Editorial.rule).frame(width: 4, height: 4)
        }
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Editorial.ruleSoft).frame(height: 0.5)
        }
    }
}

// ────────────────────────────────────────────────────────────────────────
// MARK: - Deterministic Command / Shift selection
// ────────────────────────────────────────────────────────────────────────

enum TaskSelectionIntent {
    case plain
    case toggle
    case range
}

struct TaskSelectionResolution: Equatable {
    let selected: Set<String>
    let anchor: String?
    let shouldOpen: Bool
}

enum TaskSelectionResolver {
    static func resolve(current: Set<String>,
                        anchor: String?,
                        clicked: String,
                        ordered: [String],
                        intent: TaskSelectionIntent) -> TaskSelectionResolution {
        switch intent {
        case .plain:
            // With no active selection, a regular click preserves the
            // established open-detail behaviour. Once selection mode is
            // active, a plain click collapses it to one row like ClickUp.
            if current.isEmpty {
                return TaskSelectionResolution(selected: current,
                                               anchor: anchor,
                                               shouldOpen: true)
            }
            return TaskSelectionResolution(selected: [clicked],
                                           anchor: clicked,
                                           shouldOpen: false)

        case .toggle:
            var next = current
            if next.contains(clicked) { next.remove(clicked) }
            else { next.insert(clicked) }
            return TaskSelectionResolution(selected: next,
                                           anchor: clicked,
                                           shouldOpen: false)

        case .range:
            guard let anchor,
                  let first = ordered.firstIndex(of: anchor),
                  let last = ordered.firstIndex(of: clicked) else {
                return TaskSelectionResolution(selected: [clicked],
                                               anchor: clicked,
                                               shouldOpen: false)
            }
            let bounds = min(first, last)...max(first, last)
            return TaskSelectionResolution(selected: Set(bounds.map { ordered[$0] }),
                                           anchor: anchor,
                                           shouldOpen: false)
        }
    }
}

/// Dragging an unselected task is a transient one-object operation. It must
/// not silently enter persistent selection mode. A drag only carries multiple
/// tasks when it starts on a task already included in the Command/Shift set.
enum TaskDragSelectionResolver {
    static func draggedIDs(dragged: String,
                           selected: Set<String>,
                           ordered: [String]) -> [String] {
        guard selected.contains(dragged) else { return [dragged] }
        return ordered.filter(selected.contains)
    }
}

// ────────────────────────────────────────────────────────────────────────
// MARK: - Multi-task drag payload + status drop
// ────────────────────────────────────────────────────────────────────────

enum MyTasksDragPayload {
    private static let prefix = "apollo-task-ids:"
    private static let separator = "\u{1F}"

    static func encode(_ ids: [String]) -> String {
        prefix + ids.joined(separator: separator)
    }

    static func decode(_ raw: String) -> [String] {
        guard raw.hasPrefix(prefix) else {
            // Compatibility with one-card payloads produced by Quadro.
            return raw.isEmpty ? [] : [raw]
        }
        return raw.dropFirst(prefix.count)
            .split(separator: Character(separator), omittingEmptySubsequences: true)
            .map(String.init)
    }
}

private struct MyTasksStatusDropDelegate: DropDelegate {
    let targetStatus: CUStatus
    let appState: AppState
    @Binding var draggingTaskIds: Set<String>
    @Binding var dragOverStatus: String?

    private var statusKey: String { targetStatus.status.lowercased() }

    func dropEntered(info: DropInfo) {
        dragOverStatus = statusKey
    }

    func dropExited(info: DropInfo) {
        if dragOverStatus == statusKey { dragOverStatus = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else {
            draggingTaskIds.removeAll()
            dragOverStatus = nil
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            let raw = object as? String ?? ""
            let ids = MyTasksDragPayload.decode(raw)
            Task { @MainActor in
                let toMove = ids
                    .compactMap { id in appState.tasks.first(where: { $0.id == id }) }
                    .filter { $0.status.lowercased() != statusKey }
                let originals = toMove
                // Batched so every dropped row moves to the new group AT ONCE,
                // instead of one-per-network-round-trip (the ~1s/row cascade).
                await appState.updateTaskStatuses(toMove, to: targetStatus, silent: true)
                appState.pushTaskStatusUndo(originals,
                    label: originals.count == 1
                        ? "Mover tarefa para \(targetStatus.status.uppercased())"
                        : "Mover \(originals.count) tarefas para \(targetStatus.status.uppercased())")
                draggingTaskIds.removeAll()
                dragOverStatus = nil
                NotificationCenter.default.post(name: .apolloTaskDropCompleted,
                                                object: nil)
            }
        }
        return true
    }
}

// ────────────────────────────────────────────────────────────────────────────
// MARK: Column header (ClickUp-style, resizable)
// ────────────────────────────────────────────────────────────────────────────

/// The named column-header row. Labels + resize handles are positioned from the
/// SAME `MyTasksColumnLayout.metrics(totalWidth:)` the AppKit rows use, so header
/// and rows stay pixel-aligned. Dragging a handle resizes that column live and
/// persists on release; hovering shows the ↔ cursor and the accent guide line.
private struct MyTasksColumnHeader: View {
    @ObservedObject var layout: MyTasksColumnLayout
    let totalWidth: CGFloat
    @Binding var activeBoundary: MyTasksColumnLayout.Column?

    private static let space = "mtColumns"
    private let hit: CGFloat = 12

    var body: some View {
        let m = layout.metrics(totalWidth: totalWidth)
        ZStack(alignment: .topLeading) {
            // TAREFA stays left-aligned, with its leading inset trimmed 35%.
            columnLabel("TAREFA", x: m.titleX * 0.65)
            // Data columns: label centred over its own column span.
            centeredLabel("ANEXAR", x: m.mediaX, width: m.mediaWidth)
            centeredLabel("PRIORIDADE", x: m.priorityX, width: m.priorityWidth)
            centeredLabel("RESPONSÁVEL", x: m.assigneeX, width: m.assigneeWidth)
            centeredLabel("PRAZO", x: m.dateX, width: m.dateWidth)

            ForEach(MyTasksColumnLayout.Column.allCases) { column in
                handle(column, x: m.handleX[column] ?? 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Editorial.rule).frame(height: 1)
        }
    }

    private func columnLabel(_ text: String, x: CGFloat) -> some View {
        Text(text)
            .font(Editorial.sans(9, .semibold))
            .tracking(0.7)
            .foregroundStyle(Editorial.inkMute)
            .fixedSize()
            .offset(x: x, y: 10)
    }

    /// Label horizontally centred over its column's span.
    private func centeredLabel(_ text: String, x: CGFloat, width: CGFloat) -> some View {
        Text(text)
            .font(Editorial.sans(9, .semibold))
            .tracking(0.7)
            .foregroundStyle(Editorial.inkMute)
            .lineLimit(1)
            .frame(width: max(width, 10), alignment: .center)
            .offset(x: x, y: 10)
    }

    private func handle(_ column: MyTasksColumnLayout.Column, x: CGFloat) -> some View {
        Color.clear
            .frame(width: hit)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .offset(x: x - hit / 2)
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                    activeBoundary = column
                } else {
                    NSCursor.pop()
                    if activeBoundary == column { activeBoundary = nil }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        activeBoundary = column
                        layout.drag(column, toX: value.location.x, totalWidth: totalWidth)
                    }
                    .onEnded { _ in layout.commit() }
            )
    }
}
