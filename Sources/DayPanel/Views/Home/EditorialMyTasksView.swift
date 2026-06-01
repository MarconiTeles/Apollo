import SwiftUI
import AppKit

// Apollo · Editorial+ "Minhas tarefas" / "Atribuídas a mim".
//
// Mirrors ClickUp's per-user "Tasks assigned to me" page: every
// non-completed task across the workspace that has the connected
// user in its assignees array, grouped by status, sorted by due
// date within each group. Cross-list — does NOT obey the active
// list selection (the whole point is one place to see everything
// on your plate regardless of which list it lives in).
//
// Routes from `sidebarRoute == .tasks` in ContentView.

struct EditorialMyTasksView: View {
    @EnvironmentObject var appState: AppState

    /// Status names the user has collapsed manually. Empty by
    /// default → every group renders expanded. Stored in
    /// AppStorage so the layout persists between sessions.
    @AppStorage("dp_myTasks_collapsedStatuses_v1")
    private var collapsedRaw: String = ""

    /// Sourced from `appState.assignedToMeTasks` — a workspace-
    /// scoped cache populated by the STREAMING
    /// `syncAssignedToMeAcrossWorkspace`. Reading from AppState
    /// instead of a view-local `@State` means re-entering the
    /// view (dashboard → Tarefas → dashboard → Tarefas) shows
    /// the cached rows instantly while the background refresh
    /// streams updates.
    private var allMyTasks: [CUTask] { appState.assignedToMeTasks }
    private var didFirstLoad: Bool { appState.assignedToMeDidFirstLoad }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Editorial.rule).frame(height: 1)
            content
        }
        .background(Editorial.paper)
        .task { await refresh() }
        // Re-stream whenever a global sync touches the workspace
        // — best proxy for "data might have moved upstream".
        .onChange(of: appState.tasks.count) { _, _ in
            Task { await refresh() }
        }
    }

    /// Trigger the streaming refresh — pages land in
    /// `appState.assignedToMeTasks` one by one, so the canvas
    /// paints the first 100 rows in ~500ms instead of waiting
    /// for the entire paginated set.
    private func refresh() async {
        await appState.syncAssignedToMeAcrossWorkspace()
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Header
    // ────────────────────────────────────────────────────────────────────

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            HStack(spacing: 10) {
                Text("MINHAS TAREFAS · ATRIBUÍDAS A MIM")
                    .font(Editorial.sans(11, .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Editorial.inkSoft)
                Text("\(totalCount)")
                    .font(Editorial.sans(11, .medium))
                    .foregroundStyle(Editorial.inkFaint)
                    .monospacedDigit()
            }
            Spacer(minLength: 24)
            Text("¶ tudo o que está com você, agrupado por status.")
                .font(Editorial.serif(12).italic())
                .foregroundStyle(Editorial.inkMute)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Body
    // ────────────────────────────────────────────────────────────────────

    @ViewBuilder
    private var content: some View {
        if appState.clickUpAuthService.userId == nil {
            emptyState(title: "Conecte sua conta ClickUp",
                       caption: "Faça login para ver suas tarefas atribuídas.")
        } else if allMyTasks.isEmpty && !didFirstLoad {
            // Skeletons ONLY before the first sync has ever
            // finished. After that, an empty `allMyTasks` is a
            // real "you have nothing assigned" state — not a
            // loading state, regardless of whether a background
            // sync is currently running.
            EditorialSkeletonStack(count: 8)
        } else if allMyTasks.isEmpty {
            emptyState(title: "Tudo limpo",
                       caption: "Nenhuma tarefa pendente atribuída a você.")
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    // Flatten (status, taskIndex) pairs into a single
                    // index sequence so the cascade reads as ONE wave
                    // sweeping across the whole canvas instead of
                    // independent waves per group.
                    let flat = flattenedRows
                    ForEach(Array(flat.enumerated()), id: \.element.id) { (i, row) in
                        rowOrHeader(row)
                            .cascadeAppear(index: i)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 80)
                .animation(.easeOut(duration: 0.22), value: allMyTasks.count)
            }
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
    private func rowOrHeader(_ row: FlatRow) -> some View {
        switch row {
        case .header(let s, let c, let collapsed):
            VStack(alignment: .leading, spacing: 0) {
                if row.id != flattenedRows.first?.id {
                    Color.clear.frame(height: 18)   // group spacer
                }
                groupHeader(status: s, count: c, collapsed: collapsed)
            }
        case .task(let t, _):
            taskRow(t)
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
    // MARK: Groups
    // ────────────────────────────────────────────────────────────────────

    /// Pending tasks where the connected user is in the assignees
    /// array. Sourced from `allMyTasks` (the dedicated cross-
    /// workspace fetch) so this view shows EVERYTHING on the
    /// user's plate, not just the active list — earlier this was
    /// filtering `appState.tasks` and silently dropped tasks in
    /// other lists that hadn't been pulled into local state.
    private var assignedToMe: [CUTask] {
        allMyTasks.filter { t in
            !t.isCompleted && !t.archived
        }
    }

    private var totalCount: Int { assignedToMe.count }

    /// (status, tasks) tuples in workspace-status order. Drops empty
    /// statuses; sorts tasks within each by (overdue first → due
    /// date ascending → no-date last → priority).
    private var groups: [(status: CUStatus, tasks: [CUTask])] {
        let byStatus = Dictionary(grouping: assignedToMe, by: { $0.status.lowercased() })
        // Reversed status order — REVIEW first … BACKLOG last (pipeline end-first).
        let visible = appState.availableStatuses.filter { !$0.isClosed }.reversed()
        return visible.compactMap { s in
            let lc = s.status.lowercased()
            let ts = byStatus[lc] ?? []
            guard !ts.isEmpty else { return nil }
            return (s, sorted(ts))
        }
    }

    private func sorted(_ tasks: [CUTask]) -> [CUTask] {
        tasks.sorted { a, b in
            let now = Date()
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
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
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
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Editorial.inkFaint)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .overlay(alignment: .bottom) {
            Rectangle().fill(Editorial.rule).frame(height: 0.5)
        }
    }

    private func taskRow(_ task: CUTask) -> some View {
        Button {
            appState.detailTaskOrigin = .zero
            appState.detailTask       = task
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
            let overdue = d < Date()
            Text(relativeDate(d))
                .font(Editorial.sans(11.5, .medium))
                .foregroundStyle(overdue ? Editorial.accent : Editorial.inkSoft)
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
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "pt_BR")
        fmt.dateFormat = "d 'de' MMM."
        return fmt.string(from: d)
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
        collapsedRaw = set.sorted().joined(separator: ",")
    }
}
