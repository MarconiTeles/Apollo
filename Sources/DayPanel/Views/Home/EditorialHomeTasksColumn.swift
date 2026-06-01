import SwiftUI

// Apollo · Editorial+ Home — TAREFAS column.
//
// Renders the active list's tasks GROUPED by status with
// collapsible section headers, mirroring the design of
// `EditorialMyTasksView`. Replaces the legacy flat
// `TaskListView` on the .today route so the home view shows
// one organisational language across the whole page (agenda
// is grouped by day → tasks are grouped by status).
//
// Data source: `appState.pendingTasks` narrowed by
// `appState.taskFilters` + `appState.selectedTaskStatus` —
// same filter pipeline the legacy `TaskListView` uses, so
// changes in the FILTROS sidebar narrow this view in real time.

struct EditorialHomeTasksColumn: View {
    @EnvironmentObject var appState: AppState

    /// Status names the user has collapsed. Persisted across
    /// sessions via @AppStorage (comma-joined string —
    /// AppStorage doesn't take Sets natively).
    @AppStorage("dp_home_collapsedStatuses_v1")
    private var collapsedRaw: String = ""

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if groups.isEmpty {
                    emptyOrSkeleton
                } else {
                    let flat = flattenedRows
                    ForEach(Array(flat.enumerated()), id: \.element.id) { (i, row) in
                        rowOrHeader(row)
                            .cascadeAppear(index: i)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 80)
            .animation(.easeOut(duration: 0.22), value: filteredPendingTasks.count)
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Data
    // ────────────────────────────────────────────────────────────────────

    /// Pending tasks for the active list narrowed by the global
    /// filter pipeline (taskFilters + selectedTaskStatus).
    /// Mirrors the universe `TaskListView` rendered before so the
    /// sidebar's FILTROS chips affect this view identically.
    private var filteredPendingTasks: [CUTask] {
        let universe = appState.tasks.filter {
            !$0.isCompleted && !$0.archived
        }
        let statused: [CUTask] = {
            if let s = appState.selectedTaskStatus {
                return universe.filter { $0.status == s }
            }
            return universe
        }()
        let dimensioned = appState.taskFilters.isEmpty
            ? statused
            : statused.filter { appState.taskFilters.matches($0) }
        return dimensioned
    }

    private var groups: [(status: CUStatus, tasks: [CUTask])] {
        let byStatus = Dictionary(grouping: filteredPendingTasks,
                                  by: { $0.status.lowercased() })
        // Reversed status order — REVIEW first, then EDITANDO, A EDITAR,
        // CAPTADO, BACKLOG (the pipeline read end-first).
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
            if aOver != bOver { return aOver }
            switch (a.dueDate, b.dueDate) {
            case let (.some(ad), .some(bd)):
                if ad != bd { return ad < bd }
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): break
            }
            if a.priority != b.priority {
                let aP = a.priority == 0 ? 99 : a.priority
                let bP = b.priority == 0 ? 99 : b.priority
                return aP < bP
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Flat row sequence (so cascade is one global wave)
    // ────────────────────────────────────────────────────────────────────

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
                    Color.clear.frame(height: 18)
                }
                groupHeader(status: s, count: c, collapsed: collapsed)
            }
        case .task(let t, _):
            taskRow(t)
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Section + rows
    // ────────────────────────────────────────────────────────────────────

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
                Circle()
                    .fill(Color(hex: task.statusDisplayHex))
                    .frame(width: 7, height: 7)

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
    // MARK: Empty / loading
    // ────────────────────────────────────────────────────────────────────

    @ViewBuilder
    private var emptyOrSkeleton: some View {
        if appState.tasks.isEmpty && appState.isSyncing {
            EditorialSkeletonStack(count: 6)
        } else {
            VStack(spacing: 6) {
                Text("Tudo limpo")
                    .font(Editorial.serif(18, .medium))
                    .foregroundStyle(Editorial.ink)
                Text("Nenhuma tarefa pendente nesta lista.")
                    .font(Editorial.serif(12).italic())
                    .foregroundStyle(Editorial.inkMute)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // MARK: Collapse state
    // ────────────────────────────────────────────────────────────────────

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
