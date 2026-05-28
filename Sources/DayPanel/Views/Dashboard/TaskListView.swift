import SwiftUI

struct TaskListView: View {
    @EnvironmentObject var appState: AppState

    /// When true, the embedded scroll views skip the 52pt
    /// toolbar reserve + the 52pt filter-bar reserve at the
    /// top. Used by the Editorial+ Home view, which renders
    /// its own crumb/title block + inline status pills above
    /// the dashboard — so the legacy insets would stack on
    /// top of those and leave a huge empty band.
    var skipsLegacyHeaderInsets: Bool = false

    @State private var showCompleted = false

    // MARK: - Lazy-render caps
    //
    // Even with `LazyVStack`, scrolling through a large task list
    // accumulates row instances in memory: SwiftUI lazily creates
    // them as they enter the viewport but never destroys them on
    // exit. With 100+ tasks that means 100+ row views eventually
    // alive — each with its own @State, gesture trackers, focus
    // state, etc.
    //
    // To match the "only what the user is currently looking at"
    // pattern (same as the collapsed `concluídas` dropdown), we
    // cap initial render at `Self.pendingInitialCap` rows. A
    // "Mostrar mais X" button at the tail expands the cap by
    // `pendingExpandStep` per click. The cap is reset whenever
    // the underlying list shrinks (filter applied, tasks
    // completed) so it never gets stuck above the actual count.
    // Tightened from 50 / 30 to 20 / 20 by request — keeps the
    // initial mount cheap (smaller LazyVStack on first paint)
    // and the infinite-scroll loader picks up the next batch
    // automatically when the user reaches the tail (see
    // `loadMoreSentinel` below). The previous "Mostrar mais"
    // button still works as a manual fallback for users who
    // prefer to opt-in.
    private static let pendingInitialCap = 20
    private static let pendingExpandStep = 20
    @State private var pendingVisibleLimit: Int = pendingInitialCap

    @State private var filteredVisibleLimit: Int = pendingInitialCap

    /// Cached result of the filter chain. Was a computed `var
    /// filteredTasks` that ran on every body re-eval — and the
    /// parent `appState` fires unrelated `@Published` mutations
    /// at scroll-frame rate (eventsForToday updates, hover
    /// state propagation, etc.), so the chain was being re-run
    /// dozens of times per second even when no input had
    /// actually changed. Now we recompute only via the explicit
    /// `.onChange` handlers below.
    @State private var cachedFilteredTasks: [CUTask] = []

    private var selectedStatus: String? { appState.selectedTaskStatus }

    /// True when ANY filter is active (status pill OR multi-dim filters).
    /// When true the view collapses Pendentes/Concluídas into a single
    /// flat filtered list — matches the user's expectation that "filter"
    /// means "show me what matches" without category breakdown.
    private var hasActiveFilter: Bool {
        selectedStatus != nil
            || !appState.taskFilters.isEmpty
            || !trimmedSearch.isEmpty
    }

    private var trimmedSearch: String {
        appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Computes the filter chain on demand. Called only from the
    /// `.onChange` handlers below — the result is cached in
    /// `cachedFilteredTasks` so the body never re-runs this.
    private func computeFilteredTasks() -> [CUTask] {
        // Single universe for everything in the bar AND the
        // list: non-completed tasks (parents + subtasks) in the
        // active list. When the user picks a status, narrow to
        // that status; otherwise show the whole universe so the
        // TODOS pill's count matches the rows on screen.
        let universe = appState.tasks.filter {
            !$0.isCompleted && !$0.archived
        }
        let base: [CUTask] = {
            if let s = selectedStatus {
                return appState.sortByDeadlineThenPriority(
                    universe.filter { $0.status == s }
                )
            }
            return appState.sortByDeadlineThenPriority(universe)
        }()
        let dimensioned = appState.taskFilters.isEmpty
            ? base
            : base.filter { appState.taskFilters.matches($0) }
        return applySearch(to: dimensioned)
    }

    /// Read-only accessor for the rest of the file. Now backed
    /// by the cached array instead of recomputing per access.
    private var filteredTasks: [CUTask] { cachedFilteredTasks }

    /// Narrow `tasks` by the toolbar search query. Matches the
    /// query (case-insensitive) against task title, description,
    /// status, list name, every assignee username, and every tag
    /// name — so the user can search by any of those without
    /// thinking about which field they're typing into.
    private func applySearch(to tasks: [CUTask]) -> [CUTask] {
        let q = trimmedSearch
        guard !q.isEmpty else { return tasks }
        let needle = q.lowercased()
        return tasks.filter { task in
            if task.title.lowercased().contains(needle)        { return true }
            if let d = task.description,
               d.lowercased().contains(needle)                  { return true }
            if task.status.lowercased().contains(needle)        { return true }
            if task.listName.lowercased().contains(needle)      { return true }
            if task.assignees.contains(where: {
                $0.username.lowercased().contains(needle)
            })                                                  { return true }
            if task.tags.contains(where: {
                $0.name.lowercased().contains(needle)
            })                                                  { return true }
            return false
        }
    }

    private var hasFilters: Bool {
        appState.clickUpAuthService.isConnected && !appState.availableStatuses.isEmpty
    }

    private var filterBarHeight: CGFloat {
        // Suppress the 52pt reserve when the host (e.g.
        // EditorialHomeHeader) carries its own status pill row
        // above — otherwise both layers would stack and bloat
        // the top of the task column.
        skipsLegacyHeaderInsets ? 0 : (hasFilters ? 52 : 0)
    }

    /// The legacy 52pt toolbar reserve baked into the AppKit
    /// scroll views. Drops to 0 inside the home view (the home
    /// header already occupies that band above the dashboard).
    private var legacyTopBand: CGFloat {
        skipsLegacyHeaderInsets ? 0 : 52
    }

    var body: some View {
        rootBody
            // GLOBAL `expandedTaskId` → open-detail-popup handler.
            // Used to live inside each row as
            // `.onChange(of: appState.expandedTaskId)`, which
            // forced every visible row to subscribe to AppState's
            // `objectWillChange`. Hoisted here so a single
            // handler routes the external open request to the
            // matching task and rows stay free of `@Published`
            // reactivity. The legacy scroll path also has a
            // separate scroll-to handler inside `legacyScrollBody`
            // — both fire on the same change but do different
            // things (this opens the popup, the other centers
            // the row in the SwiftUI ScrollView).
            .onChange(of: appState.expandedTaskId) { _, new in
                guard let id = new,
                      let target = appState.tasks.first(where: { $0.id == id })
                else { return }
                appState.detailTaskOrigin = .zero
                appState.detailTask = target
                // Reset so a follow-up trigger fires fresh.
                DispatchQueue.main.async { appState.expandedTaskId = nil }
            }
            // Cache invalidation for `cachedFilteredTasks`. Hoisted
            // up here from `legacyScrollBody` because the spike
            // body ALSO reads `cachedFilteredTasks` when filters
            // are active — leaving the handlers buried inside the
            // legacy path meant tapping a filter pill from the
            // spike code path never recomputed the cache, so the
            // pill appeared to do nothing (or showed a stale
            // filtered list from a previous legacy session).
            // Putting them on `rootBody` ensures the cache stays
            // in sync regardless of which render path is active.
            .onAppear { cachedFilteredTasks = computeFilteredTasks() }
            .onChange(of: appState.tasks)        { _, _ in cachedFilteredTasks = computeFilteredTasks() }
            .onChange(of: appState.pendingTasks) { _, _ in cachedFilteredTasks = computeFilteredTasks() }
            .onChange(of: selectedStatus)        { _, _ in cachedFilteredTasks = computeFilteredTasks() }
            .onChange(of: appState.taskFilters)  { _, _ in cachedFilteredTasks = computeFilteredTasks() }
            .onChange(of: appState.searchQuery)  { _, _ in cachedFilteredTasks = computeFilteredTasks() }
            // Clear a stale status selection if the underlying
            // workflow changes and the selected status is no
            // longer valid.
            .onChange(of: appState.availableStatuses) { _, new in
                if let s = selectedStatus, !new.contains(where: { $0.status == s }) {
                    appState.selectedTaskStatus = nil
                }
            }
    }

    /// Original body content, wrapped so the global `onChange`
    /// modifier can attach uniformly across both paths.
    @ViewBuilder
    private var rootBody: some View {
        // SPIKE: when we have a flat list of rows to render (with
        // OR without active filters) and the user is connected,
        // hand the scroll surface to `NSCollectionListView` so
        // AppKit can recycle a small pool of NSHostingView cells
        // instead of SwiftUI rendering every row in a LazyVStack.
        //
        // Legacy SwiftUI ScrollView still owns the edge cases the
        // spike doesn't model: not-connected state, no-list state,
        // empty-state placeholder, "Mostrar mais" pagination
        // sentinel, and the showCompleted expandable header.
        if let items = spikeListItems {
            // PHASE 1 of the SwiftUI → AppKit migration. The
            // visual is being reconciled with the SwiftUI version
            // iteratively; if any detail looks off, flip
            // `useAppKitTaskCells` to false in UserDefaults to
            // fall back to the SwiftUI cell instantly without
            // recompiling — useful for side-by-side comparison.
            if useAppKitTaskCells {
                // Flatten the task list into a depth-aware
                // row sequence so subtasks of expanded tasks
                // appear inline below their parent (with
                // indentation). The flatten function reads
                // `appState.expandedSubtaskIds` to decide
                // which trees to expand.
                let rows = appState.flattenForList(items)
                TaskCollectionView(
                    items:           rows,
                    topContentInset: legacyTopBand + filterBarHeight,
                    onTapTask:       { task, frame in
                        appState.detailTaskOrigin = frame
                        appState.detailTask       = task
                    },
                    appState:        appState
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .top)
                // Hard-terminate the list at the category bar's
                // footer rule: mask out the toolbar + filter-bar
                // band so scrolled rows vanish exactly at that
                // line instead of bleeding up behind the bar.
                .mask(alignment: .top) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: legacyTopBand + filterBarHeight)
                        Rectangle()
                    }
                }
            } else {
                NSCollectionListView(
                    items: items,
                    topContentInset: legacyTopBand + filterBarHeight
                ) { task in
                    // Editorial: no status-tinted drop shadow —
                    // the row is a flat paper line with a hairline
                    // rule (handled inside TaskRowView).
                    TaskRowView(task: task, appState: appState)
                        .equatable()
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .top)
                .mask(alignment: .top) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: legacyTopBand + filterBarHeight)
                        Rectangle()
                    }
                }
            }
        } else {
            legacyScrollBody
        }
    }

    /// UserDefaults-backed flag to switch between the AppKit
    /// `TaskCollectionView` (perf-optimized cell recycling) and
    /// the SwiftUI `TaskRowView`.
    ///
    /// Both cells are now ported to the editorial language, so
    /// the AppKit path (cell recycling — smooth scroll on big
    /// lists) is the default again. Flip to the SwiftUI row via:
    ///     defaults write com.painellunar.app dp_useAppKitTaskCells -bool false
    private var useAppKitTaskCells: Bool {
        UserDefaults.standard.object(forKey: "dp_useAppKitTaskCells") as? Bool ?? true
    }

    /// Returns the array to feed the NSCollectionListView spike,
    /// or `nil` when we should fall back to the legacy SwiftUI
    /// ScrollView path. Centralises the gating logic — body just
    /// asks "do we have a spike list to render?".
    ///
    /// Returns `nil` for cases the spike can't model:
    ///   • user not connected to ClickUp / no list selected
    ///   • showCompleted toggle is open (needs the expandable
    ///     header + completed sub-section)
    ///   • the resolved list is empty (needs an empty-state
    ///     placeholder)
    ///
    /// Otherwise picks `cachedFilteredTasks` when filters are
    /// active, else `pendingTasks`. Both flow through the same
    /// recycled-cell path — typing in the search box just swaps
    /// the items array; NSCollectionListView's equality guard
    /// detects the change and re-binds visible cells without
    /// rebuilding the whole hosting tree.
    private var spikeListItems: [CUTask]? {
        guard appState.clickUpAuthService.isConnected,
              KeychainHelper.load(for: KeychainHelper.Keys.clickupListId) != nil,
              !showCompleted
        else { return nil }
        let list = hasActiveFilter ? cachedFilteredTasks : appState.pendingTasks
        return list.isEmpty ? nil : list
    }

    private var legacyScrollBody: some View {
        // ScrollViewReader gives us programmatic scrolling so the row
        // expanded by a "Nova tarefa" notification (or any future
        // deep-link) ends up centered in the viewport instead of
        // wherever the user happened to be scrolled.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2.8153125) {
                    if !appState.clickUpAuthService.isConnected {
                        notConnectedState
                    } else if KeychainHelper.load(for: KeychainHelper.Keys.clickupListId) == nil {
                        noListState
                    } else {
                        taskBody
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
            // Reserve space at the top for the TaskFilterBar that ContentView
            // renders in its top z-layer. Tasks scroll under that bar.
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: filterBarHeight)
            }
            // (Cache-invalidation `.onChange` handlers and the
            // availableStatuses guard moved to TaskListView.body
            // so they fire regardless of which render path is
            // active. Only the scroll-to handler stays here
            // because it depends on the local `proxy`.)
            .onChange(of: appState.expandedTaskId) { _, new in
                // A nil → id transition means a task was just told to
                // open. We center it twice:
                //   1. Right away — gets the compact row roughly into
                //      view so the expansion isn't happening off-screen.
                //   2. After 0.40s — the row's expand animation is
                //      ~0.32s long; once it settles we recenter on the
                //      now-larger row.
                guard let id = new else { return }
                let center = {
                    withAnimation(.spring(duration: 0.45, bounce: 0.20)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: center)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.40, execute: center)
            }
        }
    }

    // MARK: - Task body

    @ViewBuilder
    private var taskBody: some View {
        if hasActiveFilter {
            filteredView
        } else {
            unfilteredView
        }
    }

    private var unfilteredView: some View {
        Group {
            if appState.pendingTasks.isEmpty && !appState.showMockData {
                // Skeletons ONLY when we genuinely haven't loaded
                // any data yet — i.e. `appState.tasks` is empty
                // AND a sync is in flight (cold start). If
                // `tasks` has content but `pendingTasks` is empty
                // (e.g. all top-level rows completed, or this
                // list has only subtasks), the cache IS filled —
                // showing skeletons there falsely implies "still
                // loading" forever because background prefetches
                // keep `isSyncing` true. Empty placeholder is
                // the right answer in that case.
                if appState.tasks.isEmpty && appState.isSyncing {
                    EditorialSkeletonStack(count: 8)
                } else {
                    emptyState
                }
            } else {
                let visible = Array(appState.pendingTasks.prefix(pendingVisibleLimit))
                ForEach(Array(visible.enumerated()), id: \.element.id) { (i, task) in
                    TaskRowView(task: task, appState: appState)
                        .equatable()
                        .cascadeAppear(index: i)
                }
                if appState.pendingTasks.count > pendingVisibleLimit {
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            let remaining = appState.pendingTasks.count - pendingVisibleLimit
                            guard remaining > 0 else { return }
                            pendingVisibleLimit += min(Self.pendingExpandStep, remaining)
                        }
                    showMoreButton(
                        remaining: appState.pendingTasks.count - pendingVisibleLimit,
                        bumpBy: { Self.pendingExpandStep },
                        action: {
                            pendingVisibleLimit += Self.pendingExpandStep
                        }
                    )
                }
            }

            if !appState.completedTasks.isEmpty {
                Button {
                    withAnimation(.spring(duration: 0.3)) { showCompleted.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showCompleted ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                        Text("\(appState.completedTasks.count) concluída\(appState.completedTasks.count == 1 ? "" : "s")")
                            .font(.caption)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).focusEffectDisabled()
                .padding(.horizontal, 4).padding(.top, 6)

                if showCompleted {
                    ForEach(appState.completedTasks) { task in
                        TaskRowView(task: task, appState: appState)
                            .equatable()
                            .opacity(0.45)
                    }
                }
            }
        }
        // Reset the visible cap whenever the pending list shrinks
        // below the current cap (filter applied, task completed,
        // task deleted). Prevents the cap from getting stranded
        // above the real count and the "Mostrar mais" button from
        // appearing for a list that no longer needs it.
        .onChange(of: appState.pendingTasks.count) { _, new in
            if pendingVisibleLimit > Self.pendingInitialCap,
               new < pendingVisibleLimit {
                pendingVisibleLimit = max(Self.pendingInitialCap, new)
            }
        }
    }

    @ViewBuilder
    private var filteredView: some View {
        if filteredTasks.isEmpty {
            // Filtering is 100% client-side and instant. If the
            // chain returns nothing, the answer is "filter
            // excluded everything", NOT "still loading". Show
            // skeletons only on the cold-start case where we
            // have no source data yet at all — otherwise the
            // user sees skeletons forever (background prefetches
            // keep `isSyncing` true after first paint).
            if appState.tasks.isEmpty && appState.isSyncing {
                EditorialSkeletonStack(count: 6)
            } else {
                placeholderState(icon: "tray", message: "Nenhuma tarefa neste status")
            }
        } else {
            let visible = Array(filteredTasks.prefix(filteredVisibleLimit))
            ForEach(Array(visible.enumerated()), id: \.element.id) { (i, task) in
                TaskRowView(task: task, appState: appState)
                    .equatable()
                    .opacity(task.isCompleted ? 0.55 : 1.0)
                    .cascadeAppear(index: i)
            }
            if filteredTasks.count > filteredVisibleLimit {
                // Same auto-load sentinel pattern as the
                // unfiltered view — see comment there for the
                // mechanics. Filtered list uses the same
                // `pendingExpandStep` (20) so every code path
                // through the dashboard expands at the same
                // batch size.
                Color.clear
                    .frame(height: 1)
                    .onAppear {
                        let remaining = filteredTasks.count - filteredVisibleLimit
                        guard remaining > 0 else { return }
                        filteredVisibleLimit += min(Self.pendingExpandStep, remaining)
                    }
                showMoreButton(
                    remaining: filteredTasks.count - filteredVisibleLimit,
                    bumpBy: { Self.pendingExpandStep },
                    action: {
                        filteredVisibleLimit += Self.pendingExpandStep
                    }
                )
            }
        }
    }

    /// Reusable "Mostrar mais N" button used by both the
    /// unfiltered and filtered list views. Stays in the same
    /// visual lane as the "X concluídas" toggle so the row of
    /// expand controls reads consistently.
    private func showMoreButton(remaining: Int,
                                bumpBy: () -> Int,
                                action: @escaping () -> Void) -> some View {
        let step = bumpBy()
        let bump = min(step, remaining)
        return Button {
            withAnimation(.spring(duration: 0.3)) { action() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus.circle")
                    .font(.caption2.weight(.semibold))
                Text("Mostrar mais \(bump)")
                    .font(.caption.weight(.medium))
                Text("(\(remaining) restantes)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .foregroundStyle(Editorial.accent)
            .padding(.horizontal, 4)
            .padding(.top, 6)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    // MARK: - Placeholder states

    private var notConnectedState: some View {
        placeholderState(
            icon:    "link.badge.plus",
            message: "Conecte o ClickUp nas configurações para ver suas tarefas."
        )
    }

    private var noListState: some View {
        placeholderState(
            icon:    "list.bullet.clipboard",
            message: "Selecione uma lista do ClickUp nas configurações."
        )
    }

    private var emptyState: some View {
        placeholderState(icon: "checkmark.circle", message: "Nenhuma tarefa pendente")
    }

    private func placeholderState(icon: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.quaternary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 52)
    }
}

// MARK: - TaskFilterBar
//
// Standalone view rendered by ContentView at the highest z-layer of the
// window so the pills always sit above the toolbar's frosted strip.

struct TaskFilterBar: View {
    @EnvironmentObject var appState: AppState

    /// Same condition `TaskListView.hasFilters` uses — keeps the
    /// reserved-space height and the bar's actual rendering in lock
    /// step. Without this, when statuses are still loading we'd render
    /// a 44pt bar over a 0pt reserved area and visually clobber the
    /// first task row.
    var hasFilters: Bool {
        appState.clickUpAuthService.isConnected && !appState.availableStatuses.isEmpty
    }

    var body: some View {
        if hasFilters {
            ScrollView(.horizontal, showsIndicators: false) {
                // Prototype filter row: a baseline-aligned flex with
                // `gap: 24` between tabs. Status-only — the
                // dimension switcher was removed (this bar shows
                // categories/statuses exclusively).
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    pills
                }
                // Leading inset matches the task TITLE's x-offset
                // inside each row (`leadingPad 14 + checkSize 16.1 +
                // titleGroupSpacing 8 ≈ 38pt`) so the first pill
                // (e.g. "Todos") lines up vertically with the row
                // titles below, now that the rows render edge-to-
                // edge with no horizontal cell inset.
                .padding(.leading, 38)
                .padding(.trailing, 12)
                .padding(.vertical, 12)
            }
            .frame(height: 52)
            // Closing 1px rule, full-bleed — matches the new
            // edge-to-edge task hairlines so the bar's divider
            // and the inter-task separators read as one continuous
            // ruling system.
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Editorial.rule)
                    .frame(height: 1)
            }
            // Explicit clip — `.clipped()` forces the rendered
            // content to stay inside the bar's frame even if
            // the ScrollView's own clip is bypassed by some
            // ancestor (the pills row can be wider than the
            // task panel and was leaking leftward into the
            // events panel without this).
            .clipped()
        }
    }

    // MARK: - Dimension dropdown

    private var dimensionMenu: some View {
        Menu {
            ForEach(TaskPillDimension.allCases) { dim in
                Button {
                    switchDimension(to: dim)
                } label: {
                    if dim == appState.taskPillDimension {
                        Label(dim.label, systemImage: "checkmark")
                    } else {
                        Label(dim.label, systemImage: dim.systemImage)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: appState.taskPillDimension.systemImage)
                    .font(.system(size: 9, weight: .semibold))
                Text(appState.taskPillDimension.label.capitalized)
                    .font(Editorial.sans(12, .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Editorial.inkFaint)
            }
            .foregroundStyle(Editorial.inkSoft)
            .padding(.trailing, 10)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusEffectDisabled()
    }

    // MARK: - Pills (driven by current dimension)

    @ViewBuilder
    private var pills: some View {
        // "TODOS" is always present and clears the current dimension's
        // active selection. Counts always count over the FULL task list
        // (after pivoting dimension) so the bar still reads as "how many
        // tasks of each X are there".
        filterPill(
            label:    "TODOS",
            // Universe = every non-completed task (parents +
            // subtasks). Has to match `statusPills` below AND
            // the filter pipeline's base set — otherwise the
            // user sees TODOS=5 next to RECORRENTES=86 and the
            // bar reads as broken. Excludes completed tasks so
            // the closed lane doesn't inflate the badge.
            count:    boardUniverse.count,
            color:    Editorial.accent,
            isActive: !hasActiveSelection
        ) { clearSelection() }

        // Status-only bar — always render the status categories
        // (the dimension switcher was removed).
        statusPills
    }

    /// Single source of truth for the filter bar counts AND
    /// the list's default render: every non-completed task in
    /// the active list (parents + subtasks). Used by both
    /// `TODOS` and the per-status pills so the universes match.
    private var boardUniverse: [CUTask] {
        appState.tasks.filter { !$0.isCompleted && !$0.archived }
    }

    // — Status —
    //
    // Counts recomputed from `appState.tasks` on every
    // body re-eval. The prior optimization read from
    // `appState.taskStatusCounts` (a cached dict in
    // AppState rebuilt by `rebuildTaskIndex` whenever
    // `tasks` mutates) — but in practice the optimistic
    // status-update path didn't fire SwiftUI re-renders
    // for the cached dict reliably, so the pill counts
    // stayed stale until the next sync replaced `tasks`
    // wholesale. Reading `appState.tasks` directly
    // restores the synchronous update at the cost of an
    // O(n) groupBy on each render — acceptable given the
    // top-level task list is typically <100 entries.
    @ViewBuilder
    private var statusPills: some View {
        // Same universe as TODOS (boardUniverse) — non-completed
        // tasks, parents + subtasks. Aligning the groupBy source
        // here is the fix for "TODOS=5, RECORRENTES=86" — both
        // sides now count the same set.
        let counts = Dictionary(grouping: boardUniverse, by: \.status).mapValues(\.count)
        ForEach(appState.availableStatuses) { s in
            filterPill(
                label:    s.status.uppercased(),
                count:    counts[s.status] ?? 0,
                color:    Color(statusHex: s.displayHex),
                isActive: appState.selectedTaskStatus == s.status
            ) { selectStatus(s.status) }
        }
    }

    // — Priority —
    @ViewBuilder
    private var priorityPills: some View {
        let counts = Dictionary(grouping: appState.tasks, by: \.priority).mapValues(\.count)
        let order  = [1, 2, 3, 4, 0].filter { counts[$0] != nil }
        ForEach(order, id: \.self) { p in
            filterPill(
                label:    priorityLabel(p).uppercased(),
                count:    counts[p] ?? 0,
                color:    priorityColor(p),
                isActive: appState.taskFilters.priorities == [p]
            ) { selectPriority(p) }
        }
    }

    // — Tag —
    @ViewBuilder
    private var tagPills: some View {
        let counts = tagCounts
        let names  = counts.keys.sorted()
        ForEach(names, id: \.self) { name in
            filterPill(
                label:    name.uppercased(),
                count:    counts[name] ?? 0,
                color:    tagColor(name),
                isActive: appState.taskFilters.tagNames == [name]
            ) { selectTag(name) }
        }
    }

    // — Assignee —
    @ViewBuilder
    private var assigneePills: some View {
        let counts = assigneeCounts
        let active = appState.availableMembers.filter { (counts[$0.id] ?? 0) > 0 }
        ForEach(active) { m in
            filterPill(
                label:    m.username.uppercased(),
                count:    counts[m.id] ?? 0,
                color:    Color(hex: m.color ?? "#87909E"),
                isActive: appState.taskFilters.assigneeIds == [m.id]
            ) { selectAssignee(m.id) }
        }
    }

    /// Counts only over tasks that have ≥1 tag, grouped per tag name.
    private var tagCounts: [String: Int] {
        var c: [String: Int] = [:]
        for t in appState.tasks {
            for tag in t.tags { c[tag.name, default: 0] += 1 }
        }
        return c
    }

    /// Counts per member that actually appears on at least one task.
    /// Iterates the SAME base list the filter operates on
    /// (`pendingTasks` — top-level, non-completed) so the
    /// pill's count matches how many rows the user actually
    /// sees when they click that member's pill.
    private var assigneeCounts: [Int: Int] {
        var c: [Int: Int] = [:]
        for t in appState.pendingTasks {
            for a in t.assignees { c[a.id, default: 0] += 1 }
        }
        return c
    }

    // MARK: - Selection helpers

    private var hasActiveSelection: Bool {
        switch appState.taskPillDimension {
        case .status:   return appState.selectedTaskStatus != nil
        case .priority: return !appState.taskFilters.priorities.isEmpty
        case .tag:      return !appState.taskFilters.tagNames.isEmpty
        case .assignee: return !appState.taskFilters.assigneeIds.isEmpty
        }
    }

    /// Switching dimension clears the previous one's active selection
    /// and any other taskFilters entries the user might have set via
    /// the popover for those dims, so the pill bar reflects truth.
    private func switchDimension(to dim: TaskPillDimension) {
        withAnimation(.spring(duration: 0.25)) {
            clearSelection()  // clear the old dimension
            appState.taskPillDimension = dim
        }
    }

    private func clearSelection() {
        withAnimation(.spring(duration: 0.25)) {
            switch appState.taskPillDimension {
            case .status:   appState.selectedTaskStatus = nil
            case .priority: appState.taskFilters.priorities  = []
            case .tag:      appState.taskFilters.tagNames    = []
            case .assignee: appState.taskFilters.assigneeIds = []
            }
        }
    }

    private func selectStatus(_ s: String) {
        withAnimation(.spring(duration: 0.25)) {
            appState.selectedTaskStatus = (appState.selectedTaskStatus == s) ? nil : s
        }
    }

    private func selectPriority(_ p: Int) {
        withAnimation(.spring(duration: 0.25)) {
            appState.taskFilters.priorities = (appState.taskFilters.priorities == [p]) ? [] : [p]
        }
    }

    private func selectTag(_ name: String) {
        withAnimation(.spring(duration: 0.25)) {
            appState.taskFilters.tagNames = (appState.taskFilters.tagNames == [name]) ? [] : [name]
        }
    }

    private func selectAssignee(_ id: Int) {
        withAnimation(.spring(duration: 0.25)) {
            appState.taskFilters.assigneeIds = (appState.taskFilters.assigneeIds == [id]) ? [] : [id]
        }
    }

    // MARK: - Color/label helpers

    private func priorityLabel(_ p: Int) -> String {
        switch p {
        case 1: return "Urgente"
        case 2: return "Alta"
        case 3: return "Normal"
        case 4: return "Baixa"
        default: return "Sem prioridade"
        }
    }

    private func priorityColor(_ p: Int) -> Color {
        switch p {
        case 1: return Color(hex: "#F50000")
        case 2: return Color(hex: "#FFCC00")
        case 3: return Color(hex: "#6FDDFF")
        case 4: return Color(hex: "#87909E")
        default: return .gray
        }
    }

    private func tagColor(_ name: String) -> Color {
        if let tag = appState.availableTags.first(where: { $0.name == name }) {
            return Color(hex: tag.background)
        }
        // Fall back to whatever a task instance carries.
        if let tag = appState.tasks.lazy.compactMap({ $0.tags.first(where: { $0.name == name }) }).first {
            return Color(hex: tag.background)
        }
        return .accentColor
    }

    // MARK: - Pill view

    private func filterPill(label: String, count: Int, color: Color, isActive: Bool, action: @escaping () -> Void) -> some View {
        // Prototype `PFilter`: a type-only underline tab — NO
        // colour dot. Label is SF Pro 13 (w600 ink when active,
        // else w400 inkSoft); the count rides 5pt after it in
        // SF Pro 11 inkMute; active gets a 2pt ink underline.
        // `padding(.bottom, 4)` mirrors the prototype's
        // `padding: '0 0 4px'`.
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(label.capitalized)
                    .font(Editorial.sans(13, isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Editorial.ink : Editorial.inkSoft)
                if count > 0 {
                    Text("\(count)")
                        .font(Editorial.sans(11))
                        .foregroundStyle(Editorial.inkMute)
                        .monospacedDigit()
                }
            }
            .padding(.bottom, 4)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isActive ? Editorial.ink : Color.clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.15), value: isActive)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

// MARK: - Status-tinted shadow modifier

/// Adaptive coloured shadow for task rows. Reads `@Environment(\.colorScheme)`
/// internally so a light↔dark switch updates the halo without re-binding the
/// cell — NSHostingView propagates the environment change into the SwiftUI
/// tree, this modifier's body re-evaluates, and the new shadow colour
/// renders. The base hue comes from the status accent; `Color.shadowTint`
/// adjusts it (brighter in dark mode, denser in light) so the halo always
/// reads as energy off the card instead of fading into the window.
private struct StatusTintedShadow: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let baseHex: String

    func body(content: Content) -> some View {
        // Tight 3pt radius across both modes — wider blur was
        // reading as a smudge in light mode and as a fuzzy
        // halo in dark; the tighter falloff keeps the tint
        // crisp against either background. Light-mode opacity
        // dropped 0.32 → 0.24 (-25%) so the now-tighter blur
        // doesn't over-emphasise itself; dark-mode opacity
        // unchanged.
        content.shadow(
            color: Color.shadowTint(forBaseHex: baseHex, scheme: scheme)
                        .opacity(scheme == .dark ? 0.36 : 0.24),
            radius: 3,
            x: 0, y: 2
        )
    }
}

