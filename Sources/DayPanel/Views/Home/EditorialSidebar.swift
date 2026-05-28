import SwiftUI
import AppKit

// Apollo · Editorial+ sidebar (port of the navigable prototype's
// `EPSidebar`). Self-contained side panel; adding it to ContentView
// is one HStack-wrap away. The sidebar carries no navigation state
// for now — clicks on nav rows highlight them locally; routes wire
// up later when we replace toolbar + body.

// MARK: - Sidebar item identity

enum SidebarRoute: Hashable {
    case today, tasks, board, upcoming, done, ai
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
        // 220pt Liquid Glass column — the WHOLE sidebar is the
        // glass surface (no floating rounded pane, no paper
        // gutter). `.regularMaterial` carries the system blur;
        // a thin white wash on top warms it to the milk-glass
        // tint the rest of the Editorial palette expects, and a
        // hairline rule on the trailing edge separates the
        // column from the chrome behind / right of it.
        VStack(spacing: 0) {
            Color.clear.frame(height: 44)   // traffic-light inset
            searchBar
            navList
            userFooter
        }
        .frame(width: 220)
        .background(
            ZStack {
                // `.ultraThinMaterial` — the lightest blur on
                // macOS. `.regularMaterial` was reading too solid;
                // ultra-thin keeps the warmth (cream wash sits on
                // top) while letting the chrome / desktop behind
                // come through clearly.
                Rectangle().fill(.ultraThinMaterial)
                // Adaptive milk-glass tint:
                //   • Light: warm white at 70% → cream milk glass
                //     matching Editorial.paper.
                //   • Dark : near-black at 55% → tinted dark glass
                //     so the panel doesn't read pale/washed in
                //     dark mode (the hardcoded white was the
                //     dominant pixel and made the column glow).
                Rectangle().fill(
                    colorScheme == .dark
                    ? Color.black.opacity(0.55)
                    : Color.white.opacity(0.70)
                )
            }
        )
        .overlay(alignment: .trailing) {
            // Trailing hairline separator so the glass column
            // reads as a discrete surface against the chrome.
            Rectangle()
                .fill(Editorial.rule)
                .frame(width: 0.5)
        }
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
    // MARK: Search pill
    // ────────────────────────────────────────────────────────────────────

    private var searchBar: some View {
        Button(action: onOpenPalette) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Editorial.inkMute)
                Text("Buscar tarefas, listas…")
                    .font(Editorial.serif(13).italic())
                    .foregroundStyle(Editorial.inkMute)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                KbdTB(text: "⌘K")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Editorial.page)
                    .overlay(Capsule().strokeBorder(Editorial.rule, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
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
            navRow("Hoje",          count: todayCount,    route: .today)
            navRow("Minhas tarefas", count: tasksCount,   route: .tasks, italic: true)
            navRow("Quadro",        count: boardCount,    route: .board)
            navRow("Próximos",      count: upcomingCount, route: .upcoming, disabled: true)
            navRow("Concluídas",                          route: .done,  italic: true, disabled: true)
            navRow("Apollo",        mark: true,           route: .ai,    disabled: true)
        }
    }

    private var listasSection: some View {
        SidebarSection(label: "Listas") {
            ForEach(listEntries, id: \.id) { e in
                SidebarDotRow(
                    color: e.color,
                    label: e.name,
                    count: e.count,
                    isActive: activeListId == e.id
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
        let id = KeychainHelper.load(for: KeychainHelper.Keys.clickupListId)
        return (id?.isEmpty == false) ? id : nil
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
                        mark: Bool = false,
                        route: SidebarRoute,
                        italic: Bool = false,
                        disabled: Bool = false) -> some View {
        SidebarNavRow(label: label,
                      count: count,
                      isActive: active == route,
                      italic: italic,
                      mark: mark,
                      disabled: disabled) {
            guard !disabled else { return }
            active = route
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
    /// "Tarefas" sidebar item opens `EditorialMyTasksView` — every
    /// non-completed task across the workspace assigned to the
    /// connected user. Count mirrors that view's content so the
    /// badge in the sidebar matches the actual list inside.
    private var tasksCount: Int {
        guard let me = myUserId else { return 0 }
        return appState.tasks.filter { t in
            !t.isCompleted && !t.archived &&
            t.assignees.contains { $0.id == me }
        }.count
    }
    private var boardCount: Int { pool.count }
    private var upcomingCount: Int {
        pool.filter { ($0.dueDate ?? .distantPast) > .now }.count
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

// ────────────────────────────────────────────────────────────────────
// MARK: Section + rows
// ────────────────────────────────────────────────────────────────────

private struct SidebarSection<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Folio(label)
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 0) { content() }
        }
    }
}

private struct SidebarNavRow: View {
    let label: String
    var count: Int? = nil
    var isActive: Bool
    var italic: Bool = false
    var mark: Bool = false
    /// Render the row in a disabled state: muted text, no
    /// hover halo, no accent on active. Used for routes that
    /// aren't wired up yet (Próximos / Concluídas / Apollo).
    var disabled: Bool = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("↳")
                    .font(Editorial.serif(14).italic())
                    .foregroundStyle(disabled ? Editorial.inkFaint : Editorial.accent)
                    .opacity(isActive && !disabled ? 1 : 0)
                    .frame(width: 8, alignment: .leading)
                if mark {
                    Text("✦")
                        .font(Editorial.serif(13))
                        .foregroundStyle(disabled ? Editorial.inkFaint : Editorial.accent)
                }
                Text(label)
                    .font(italic
                          ? Editorial.sans(13.5, isActive ? .semibold : .medium).italic()
                          : Editorial.sans(13.5, isActive ? .semibold : .medium))
                    .tracking(-0.05)
                    .foregroundStyle(disabled
                                     ? Editorial.inkFaint
                                     : (isActive ? Editorial.accent : Editorial.ink))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)")
                        .font(Editorial.sans(11, .medium))
                        .foregroundStyle(disabled
                                         ? Editorial.inkFaint
                                         : (isActive ? Editorial.accent : Editorial.inkMute))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(hover && !isActive && !disabled
                          ? Editorial.ink.opacity(0.03)
                          : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { if !disabled { hover = $0 } }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

private struct SidebarDotRow: View {
    let color: Color
    let label: String
    var count: Int? = nil
    var accent: Bool = false
    var isActive: Bool = false
    var onTap: (() -> Void)? = nil
    @State private var hover = false

    var body: some View {
        Button { onTap?() } label: {
            HStack(spacing: 9) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label)
                    .font(accent
                          ? Editorial.sans(12.5, .semibold).italic()
                          : Editorial.sans(12.5, .medium))
                    .foregroundStyle(accent ? Editorial.accent : Editorial.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)")
                        .font(Editorial.sans(11, .medium))
                        .foregroundStyle(accent ? Editorial.accent : Editorial.inkMute)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isActive ? Editorial.accent.opacity(0.10)
                          : hover ? Editorial.ink.opacity(0.03)
                          : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}
