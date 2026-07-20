import SwiftUI
import AppKit

// Apollo · Editorial+ sidebar (port of the navigable prototype's
// `EPSidebar`). Self-contained side panel; adding it to ContentView
// is one HStack-wrap away. The sidebar carries no navigation state
// for now — clicks on nav rows highlight them locally; routes wire
// up later when we replace toolbar + body.

// MARK: - Sidebar item identity

enum SidebarRoute: Hashable {
    case today, tasks, board, assignedComments, done, ai

    var studioKey: String {
        switch self {
        case .today: "inbox"
        case .tasks: "tasks"
        case .board: "board"
        case .assignedComments: "comments"
        case .done: "done"
        case .ai: "ai"
        }
    }
}

// MARK: - Sidebar view

struct EditorialSidebar: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    /// Local selection. The sidebar can drive routing once the
    /// dashboard body migrates; for now it's purely visual.
    @Binding var active: SidebarRoute
    /// Active list filter (nil = no filter). Sidebar rows in the
    /// "Listas" section toggle this; clearing happens via clicking
    /// the same row again.
    @Binding var listFilter: String?

    /// Closures the host passes in so we don't poke ContentView's
    /// private flags directly.
    var onOpenPalette:  () -> Void = {}
    var onOpenSettings: () -> Void = {}

    /// Live mirror of `PinnedLists.load()`. The store is
    /// UserDefaults-backed (not @Published), so we re-read it
    /// whenever UserDefaults posts a change notification —
    /// covers the user pinning/unpinning a list from the
    /// selector while the sidebar is on screen.
    @State private var pinnedLists: [PinnedLists.Entry] = PinnedLists.load()

    var body: some View {
        // PANE FLUTUANTE de Liquid Glass — a mesma implementação
        // do painel do MINIMAL TP: card arredondado inset das
        // bordas, vidro REAL (glassEffect) no macOS 26 sobre o
        // conteúdo vivo, e o conteúdo do quadro rola POR TRÁS
        // (o board ScrollView é full-width; os cards passam sob
        // o pane e refratam através do vidro). Tiers:
        //   A  glassEffect .regular tintado accent@0.08
        //   B  ultraThinMaterial + fio de luz
        //   C  panelDeep sólido + hairline (Reduce Transparency)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(spacing: 0) {
            // 44pt native traffic-light lane + 30pt breathing room before
            // the first section label.
            Color.clear
                .frame(height: 74)
                .overlay(alignment: .bottomLeading) {
                    Text("APOLLO")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(2.8)
                        .foregroundStyle(Editorial.inkSoft)
                        .padding(.leading, 20)
                        .padding(.bottom, 8)
                        .accessibilityLabel("Apollo")
                }
            navList
            userFooter
        }
        .frame(width: 220)
        // Keep the sidebar on its dedicated, direct glass path. Wrapping the
        // effect in the shared floating-panel builder inserted an additional
        // view-builder layer that weakened the live backdrop capture and made
        // this pane read like an opaque vibrancy sheet.
        .background {
            if Materials.tier == .solid {
                shape.fill(Editorial.panelDeep)
            }
        }
        .modifier(SidebarGlassSurface(shape: shape))
        .clipShape(shape)
        .overlay {
            if Materials.tier != .solid {
                shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                    .allowsHitTesting(false)
            } else {
                shape.strokeBorder(Editorial.rule, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        .padding(.leading, 10)
        .padding(.vertical, 10)
        .apolloStudioNode("shell.sidebar",
                          title: "Painel lateral",
                          kind: .sidebar,
                          parent: "app.root",
                          properties: [
                            .init(kind: .width, title: "Largura", value: 220),
                            .init(kind: .cornerRadius, title: "Raio", value: 16),
                            .init(kind: .shadowRadius, title: "Sombra", value: 18),
                            .init(kind: .material, title: "Material", token: "Materials.sidebar"),
                          ])
        // Re-read the pinned-lists store whenever any UserDefaults
        // key changes (cheap — ~5 entries, JSON-decoded). Covers
        // pin/unpin from the list selector or settings.
        .onReceive(NotificationCenter.default
                    .publisher(for: UserDefaults.didChangeNotification)) { _ in
            let fresh = PinnedLists.load()
            if fresh != pinnedLists { pinnedLists = fresh }
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Nav body
    // ────────────────────────────────────────────────────────────────────

    private var navList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                edicaoSection
                if !listEntries.isEmpty { listasSection }
                filtrosSection
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .scrollIndicators(.never)
    }

    private var edicaoSection: some View {
        SidebarSection(label: "Edição") {
            navRow("Inbox",          count: todayCount,    route: .today)
            navRow("Tarefas",        count: tasksCount,    route: .tasks)
            navRow("Quadro",         count: boardCount,    route: .board)
            navRow("Comentários",    count: assignedCommentsCount,
                   route: .assignedComments)
            navRow("Concluídas",                          route: .done, disabled: true)
            // "Apollo" (IA) removido desta build junto com o botão da toolbar.
        }
    }

    private var listasSection: some View {
        SidebarSection(label: "Listas") {
            ForEach(listEntries, id: \.id) { e in
                SidebarDotRow(
                    color: e.color,
                    label: e.name,
                    count: e.count,
                    isActive: activeListId == e.id,
                    targetListId: e.id
                ) {
                    // Picking a specific list implies leaving the
                    // cross-list "Atribuídas a mim" view — otherwise
                    // the user would tap a list and still see the
                    // workspace-wide assignee narrow.
                    if appState.taskFilters.assigneeIds.isEmpty == false {
                        appState.taskFilters.assigneeIds = []
                    }
                    // Pick this pinned list as the dashboard's
                    // active list — same path the selector's
                    // FIXADAS chips use (persists to keychain,
                    // sets taskViewMode = .activeList, syncs).
                    appState.activateList(id: e.id, name: e.name)
                    // Mirror to the local filter binding so the
                    // visual selection persists across
                    // pin/unpin notifications.
                    listFilter = e.name
                }
            }
        }
    }

    /// Currently-loaded ClickUp list id, read from keychain.
    /// Used to highlight the matching pinned-list row in the
    /// sidebar. Returns nil while the cross-list `.myWork`
    /// filter is active so the LISTAS section doesn't keep
    /// highlighting the user's previously-picked list while
    /// the canvas is actually showing a workspace-wide view.
    private var activeListId: String? {
        if appState.taskViewMode == .myWork { return nil }
        return appState.activeListId.isEmpty ? nil : appState.activeListId
    }

    private var filtrosSection: some View {
        SidebarSection(label: "Filtros") {
            // Embeds the SAME TaskFilterPopover content used by
            // the toolbar's "Filtros" button — `mode: .embedded`
            // strips the popover chrome (header/footer/shadow)
            // so the sections sit cleanly inside the sidebar's
            // FILTROS strip. Mutating chips here writes to
            // `appState.taskFilters` — exactly the path the rest
            // of the dashboard already observes — so changes
            // narrow the task list in real time.
            TaskFilterPopover(mode: .embedded)
                .environmentObject(appState)
                // Expanded search results must remain inside the 220pt pane.
                // Text fields and long member/tag chips otherwise keep their
                // intrinsic width and draw over the main canvas.
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: "Atribuídas a mim" filter
    // ────────────────────────────────────────────────────────────────────

    /// Numeric ClickUp id of the connected user — the same id
    /// `task.assignees[*].id` carries, so we can drive the
    /// shared `TaskFilters.assigneeIds` pipeline without
    /// touching display names.
    private var myUserId: Int? { appState.clickUpAuthService.userId }

    /// The "Atribuídas a mim" pill is active when we're in the
    /// cross-list `.myWork` mode AND the assignee filter is
    /// narrowed to { me }. Both bits matter: `.myWork` ensures
    /// the data source spans ALL lists (otherwise the count
    /// would be 0 for any list the user isn't currently on);
    /// the assignee narrow keeps belt-and-suspenders consistency
    /// with the rest of the filter UI.
    private var isAssignedToMeActive: Bool {
        guard let me = myUserId else { return false }
        return appState.taskViewMode == .myWork
            && appState.taskFilters.assigneeIds == [me]
    }

    /// Toggle the cross-list "tasks assigned to me" filter.
    /// Activating: switch to `.myWork` (cross-list endpoint),
    /// set the assignee filter, clear `listFilter`, and sync.
    /// Deactivating: revert to `.activeList` (the picked list)
    /// and clear the assignee filter so the user lands back on
    /// the list they had open.
    private func toggleAssignedToMe() {
        guard let me = myUserId else { return }
        if isAssignedToMeActive {
            appState.taskFilters.assigneeIds = []
            appState.taskViewMode = .activeList
            Task { await appState.sync() }
        } else {
            appState.taskFilters.assigneeIds = [me]
            appState.taskViewMode = .myWork
            listFilter = nil
            Task { await appState.sync() }
        }
    }

    @ViewBuilder
    private func navRow(_ label: String,
                        count: Int? = nil,
                        route: SidebarRoute,
                        disabled: Bool = false) -> some View {
        SidebarNavRow(label: label,
                      icon: icon(for: route),
                      count: count,
                      isActive: active == route,
                      disabled: disabled,
                      studioID: StudioNodeID(rawValue: "sidebar.route.\(route.studioKey)")) {
            guard !disabled else { return }
            active = route
        }
    }

    private func icon(for route: SidebarRoute) -> String {
        switch route {
        case .today:    return "tray"
        case .tasks:    return "checklist"
        case .board:    return "rectangle.grid.1x2"
        case .assignedComments: return "text.bubble"
        case .done:     return "checkmark.circle"
        case .ai:       return "sparkles"
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: User footer
    // ────────────────────────────────────────────────────────────────────

    private var userFooter: some View {
        Button(action: onOpenSettings) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color(statusHex: "#8B5CF6"))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Text(initial)
                            .font(Editorial.sans(13, .bold))
                            .foregroundStyle(Color.white)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName)
                        .font(Editorial.serif(14, .medium))
                        .tracking(-0.1)
                        .foregroundStyle(Editorial.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(role.uppercased())
                        .font(Editorial.sans(10.5, .semibold))
                        .tracking(0.4)
                        .foregroundStyle(Editorial.inkMute)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Editorial.inkMute)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .overlay(alignment: .top) {
                Rectangle().fill(Editorial.rule).frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: AppState derivations
    // ────────────────────────────────────────────────────────────────────

    private var displayName: String {
        appState.clickUpAuthService.userName ?? "Apollo"
    }
    private var initial: String {
        String(displayName.prefix(1)).uppercased()
    }
    private var role: String {
        // No designation field exposed on the user yet; show the
        // workspace name when we have one, otherwise the brand.
        "Editor · Apollo"
    }

    /// Non-completed tasks, optionally narrowed by the active list
    /// filter. Reused by every section count.
    private var pool: [CUTask] {
        let base = appState.tasks.filter { !$0.isCompleted }
        guard let list = listFilter else { return base }
        return base.filter { $0.listName == list }
    }

    private var todayCount: Int {
        appState.eventsForToday.count + pool.filter(isInToday).count
    }
    /// "Minhas tarefas" is now the single-line view of the currently
    /// selected list (the same universe as Quadro), so its count must
    /// follow `pool` instead of the former workspace-wide assignee count.
    private var tasksCount: Int {
        pool.filter { !$0.archived }.count
    }
    private var boardCount: Int { pool.count }
    private var upcomingCount: Int {
        pool.filter { ($0.dueDate ?? .distantPast) > .now }.count
    }
    private var assignedCommentsCount: Int {
        guard let me = myUserId else { return 0 }
        let username = appState.availableMembers.first { $0.id == me }?.username ?? ""
        return appState.assignedCommentRecords.filter {
            !$0.comment.resolved
                && ($0.isAssigned(to: me) || $0.mentions(username: username))
        }.count
    }
    private var overdueCount: Int {
        pool.filter { ($0.dueDate ?? .distantFuture) < .now }.count
    }
    private var reviewCount: Int {
        pool.filter { $0.status.lowercased().contains("review") }.count
    }
    /// Pending tasks assigned to the connected user — counted
    /// across ALL lists (not narrowed by `listFilter`), so the
    /// number reads as "everything on your plate" and matches
    /// the filter's behaviour when activated.
    private var assignedToMeCount: Int {
        guard let me = myUserId else { return 0 }
        return appState.tasks.filter { t in
            !t.isCompleted && t.assignees.contains { $0.id == me }
        }.count
    }
    private var doneTodayCount: Int {
        appState.tasks.filter { t in
            guard t.isCompleted, let d = t.dueDate else { return false }
            return Calendar.current.isDateInToday(d)
        }.count
    }
    private func isInToday(_ t: CUTask) -> Bool {
        guard let d = t.dueDate else { return false }
        return Calendar.current.isDateInToday(d)
    }

    /// Listas section data — drawn from the user's "Fixadas"
    /// (PinnedLists), which is the same set of lists shown in
    /// the selector's ★ FIXADAS strip. Each row's count is the
    /// number of non-completed tasks in that list. Order follows
    /// pin order from `PinnedLists.load()`.
    private struct ListEntry {
        let id: String
        let name: String
        let count: Int
        let color: Color
    }

    private var listEntries: [ListEntry] {
        pinnedLists.map { entry in
            let count = appState.tasks.filter {
                !$0.isCompleted && $0.listId == entry.id
            }.count
            return ListEntry(id: entry.id,
                             name: entry.name,
                             count: count,
                             color: paletteColor(for: entry.name))
        }
    }

    private func paletteColor(for name: String) -> Color {
        let palette = ["#C7621B", "#5B4FE9", "#7B4DD8", "#1F7A3A",
                       "#8B5CF6", "#9C7A12", "#3B82F6", "#B0402C"]
        var hash = 0
        for u in name.unicodeScalars { hash = (hash &* 31) &+ Int(u.value) }
        return Color(statusHex: palette[abs(hash) % palette.count])
    }
}

// ────────────────────────────────────────────────────────────────────────
// MARK: - Sidebar glass surface
// ────────────────────────────────────────────────────────────────────────

/// Dedicated direct material application for the sidebar. Liquid Glass must
/// remain attached to the pane content itself so the board/list beneath is
/// sampled and refracted instead of flattened into an opaque fallback layer.
private struct SidebarGlassSurface: ViewModifier {
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        if Materials.tier == .solid {
            content
        } else if #available(macOS 26.0, *), Materials.tier == .liquidGlass {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

// ────────────────────────────────────────────────────────────────────
// MARK: Section + rows
// ────────────────────────────────────────────────────────────────────

private struct SidebarSection<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Editorial.inkMute)
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 7)
            VStack(alignment: .leading, spacing: 0) { content() }
        }
    }
}

private struct SidebarNavRow: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let label: String
    let icon: String
    var count: Int? = nil
    var isActive: Bool
    /// Render the row in a disabled state: muted text, no
    /// hover halo, no accent on active. Used for routes that
    /// aren't wired up yet (Próximos / Concluídas / Apollo).
    var disabled: Bool = false
    var studioID: StudioNodeID
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .regular))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(disabled ? Editorial.inkFaint
                                              : (isActive ? Editorial.accent
                                                          : Editorial.inkMute))
                    .frame(width: 18, alignment: .center)
                Text(label)
                    .font(.system(size: 13, weight: isActive ? .medium : .regular))
                    .foregroundStyle(disabled
                                     ? Editorial.inkFaint
                                     : (isActive ? Editorial.accent : Editorial.ink))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(disabled
                                         ? Editorial.inkFaint
                                         : (isActive ? Editorial.accent : Editorial.inkMute))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Hover wash (non-active rows only).
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hover && !isActive && !disabled
                          ? Editorial.ink.opacity(0.03)
                          : Color.clear)
            )
            // Selected → NEUTRAL glass rectangle (Finder-style): the selection
            // colour lives on the icon + label, not on the fill.
            .liquidGlassSelected(isActive && !disabled,
                                 in: RoundedRectangle(cornerRadius: 8,
                                                      style: .continuous),
                                 tint: colorScheme == .light ? Editorial.ink : .white,
                                 tintOpacity: colorScheme == .light ? 0.035 : 0.025)
            .overlay {
                if isActive && !disabled {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Editorial.ink.opacity(0.09), lineWidth: 0.55)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                                .inset(by: 0.65)
                                .strokeBorder(Color.white.opacity(0.42), lineWidth: 0.55)
                        }
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: isActive && !disabled ? .black.opacity(0.12) : .clear,
                    radius: 5, y: 2.5)
            .contentShape(RoundedRectangle(cornerRadius: 8,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
        // The visual row already expands through its HStack, but SwiftUI can
        // preserve the Button's intrinsic hit region when the plain style is
        // used. Expand the control itself so every visible point in the row —
        // including the space between label and count — activates it.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 8,
                                       style: .continuous))
        .disabled(disabled)
        .scrollAwareOnHover { entering in
            if !disabled { hover = entering && !appState.anyPopupOpen }
        }
        .onChange(of: appState.anyPopupOpen) { _, open in
            if open { hover = false }
        }
        .animation(.easeOut(duration: 0.12), value: hover)
        .apolloStudioNode(
            studioID,
            title: label,
            kind: .button,
            parent: "app.sidebar",
            properties: [
                .init(kind: .horizontalPadding, title: "Padding H", value: 6),
                .init(kind: .verticalPadding, title: "Padding V", value: 6),
                .init(kind: .cornerRadius, title: "Raio", value: 8),
                .init(kind: .animationDuration, title: "Hover", value: 0.12),
            ]
        )
    }
}

private struct SidebarDotRow: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let color: Color
    let label: String
    var count: Int? = nil
    var accent: Bool = false
    var isActive: Bool = false
    var targetListId: String? = nil
    var onTap: (() -> Void)? = nil
    @State private var hover = false
    @State private var isDropTarget = false

    var body: some View {
        Button { onTap?() } label: {
            HStack(spacing: 9) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 14, weight: .regular))
                    // Ícones de lista SEM tint por cor de lista: neutros em
                    // repouso; só o item SELECIONADO usa a cor de realce do
                    // macOS (accentColor), padrão Finder.
                    .foregroundStyle(isActive ? Color.accentColor : Editorial.inkMute)
                    .frame(width: 18, alignment: .center)
                Text(label)
                    .font(.system(size: 13, weight: isActive ? .medium : .regular))
                    .foregroundStyle((accent || isActive) ? Editorial.accent : Editorial.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle((accent || isActive) ? Editorial.accent : Editorial.inkMute)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Hover wash (non-active rows only).
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isDropTarget ? color.opacity(0.16)
                          : (!isActive && hover ? Editorial.ink.opacity(0.03)
                          : Color.clear))
            )
            // Selected list → NEUTRAL glass rectangle (Finder-style): the
            // selection colour lives on the label, not on the fill.
            .liquidGlassSelected(isActive,
                                 in: RoundedRectangle(cornerRadius: 8,
                                                      style: .continuous),
                                 tint: colorScheme == .light ? Editorial.ink : .white,
                                 tintOpacity: colorScheme == .light ? 0.035 : 0.025)
            .overlay {
                if isActive {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Editorial.ink.opacity(0.09), lineWidth: 0.55)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                                .inset(by: 0.65)
                                .strokeBorder(Color.white.opacity(0.42), lineWidth: 0.55)
                        }
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: isActive ? .black.opacity(0.12) : .clear,
                    radius: 5, y: 2.5)
            .contentShape(RoundedRectangle(cornerRadius: 8,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 8,
                                       style: .continuous))
        .scrollAwareOnHover { entering in
            hover = entering && !appState.anyPopupOpen
        }
        .onChange(of: appState.anyPopupOpen) { _, open in
            if open { hover = false }
        }
        .onDrop(of: [.text], isTargeted: $isDropTarget) { providers in
            guard !appState.anyPopupOpen,
                  let targetListId,
                  let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                guard let raw = value as? String else { return }
                let ids = MyTasksDragPayload.decode(raw)
                Task { @MainActor in
                    let originals = ids.compactMap { appState.tasksById[$0] }.filter {
                        $0.listId != targetListId
                    }
                    for id in ids {
                        guard let task = appState.tasksById[id],
                              task.listId != targetListId else { continue }
                        await appState.moveTaskToList(task, toListId: targetListId)
                    }
                    appState.pushTaskListUndo(originals,
                        label: originals.count == 1
                            ? "Mover tarefa para \(label)"
                            : "Mover \(originals.count) tarefas para \(label)")
                    NotificationCenter.default.post(name: .apolloTaskDropCompleted,
                                                    object: nil)
                }
            }
            return true
        }
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.easeOut(duration: 0.12), value: isDropTarget)
    }
}
