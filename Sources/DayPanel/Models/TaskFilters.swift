import Foundation

/// Canonical operational universe shared by the list and kanban surfaces.
/// Keeping this separate from dimension filters prevents Quadro and Minhas
/// tarefas from silently disagreeing about totals (for example, one including
/// closed history while the other shows only actionable work).
enum TaskSurfaceScope {
    static func openTasks(in tasks: [CUTask], activeListId: String) -> [CUTask] {
        tasks.filter { task in
            !task.archived && !task.isCompleted &&
            (activeListId.isEmpty || task.listId == activeListId)
        }
    }
}

/// Which dimension drives the horizontal pill bar above the task list.
/// Lets the user pivot the same view between "filter by status",
/// "filter by priority", etc. without leaving the dashboard.
enum TaskPillDimension: String, CaseIterable, Identifiable {
    case status
    case priority
    case tag
    case assignee

    var id: String { rawValue }

    var label: String {
        switch self {
        case .status:   return "Status"
        case .priority: return "Prioridade"
        case .tag:      return "Etiquetas"
        case .assignee: return "Responsável"
        }
    }

    var systemImage: String {
        switch self {
        case .status:   return "circle.dashed"
        case .priority: return "flag"
        case .tag:      return "tag"
        case .assignee: return "person.2"
        }
    }
}


/// Multi-dimensional task filter set. Combines with the existing
/// `selectedTaskStatus` (single-select status) at the view layer:
/// status narrows the base list, then `TaskFilters.matches` narrows
/// further. All four dimensions combine with AND; values WITHIN a
/// dimension combine with OR (e.g. "Urgente OR Alta").
struct TaskFilters: Equatable {
    var priorities:    Set<Int>     = []   // 1=Urgente, 2=Alta, 3=Normal, 4=Baixa, 0=Sem prioridade
    var assigneeIds:   Set<Int>     = []
    var tagNames:      Set<String>  = []   // case-insensitive match below
    var dueWindow:     DueWindow?   = nil
    // Mirroring ClickUp's filter UI: the dimensions below come straight
    // from the same task fields the integration already returns
    // (creator, date_created, date_closed). Archived tasks would
    // require a second `archived=true` API call, so that's out of
    // scope for the client-side filter.
    var creatorIds:    Set<Int>     = []
    var createdRange:  DateRange?   = nil
    var closedRange:   DateRange?   = nil

    var isEmpty: Bool {
        priorities.isEmpty && assigneeIds.isEmpty && tagNames.isEmpty &&
        dueWindow == nil &&
        creatorIds.isEmpty && createdRange == nil && closedRange == nil
    }

    /// How many dimensions are currently constrained — drives the badge
    /// count on the toolbar button.
    var activeDimensionCount: Int {
        var n = 0
        if !priorities.isEmpty   { n += 1 }
        if !assigneeIds.isEmpty  { n += 1 }
        if !tagNames.isEmpty     { n += 1 }
        if dueWindow != nil      { n += 1 }
        if !creatorIds.isEmpty   { n += 1 }
        if createdRange != nil   { n += 1 }
        if closedRange != nil    { n += 1 }
        return n
    }

    func matches(_ task: CUTask) -> Bool {
        if !priorities.isEmpty {
            // Map priority 0 (none) explicitly so users can filter "no
            // priority set" — ClickUp returns 0 for unset.
            if !priorities.contains(task.priority) { return false }
        }
        if !assigneeIds.isEmpty {
            let ids = Set(task.assignees.map(\.id))
            if ids.isDisjoint(with: assigneeIds) { return false }
        }
        if !tagNames.isEmpty {
            let names = Set(task.tags.map { $0.name.lowercased() })
            let want  = Set(tagNames.map { $0.lowercased() })
            if names.isDisjoint(with: want) { return false }
        }
        if let w = dueWindow,    !w.contains(task.dueDate)    { return false }
        if !creatorIds.isEmpty {
            guard let cid = task.creator?.id, creatorIds.contains(cid) else { return false }
        }
        if let r = createdRange, !r.contains(task.dateCreated) { return false }
        if let r = closedRange,  !r.contains(task.dateClosed)  { return false }
        return true
    }

    /// Canonical dimension-filter stage shared by Hoje, Quadro and Minhas
    /// tarefas. Keeping the empty fast path here prevents the three surfaces
    /// from drifting into subtly different implementations as dimensions are
    /// added to the filter popover.
    func applying(to tasks: [CUTask]) -> [CUTask] {
        isEmpty ? tasks : tasks.filter(matches)
    }
}

/// Past-oriented date buckets used by Data criada and Data de
/// encerramento. Different from `DueWindow` which has future buckets
/// (Amanhã, Esta semana) — created/closed dates are always in the past.
enum DateRange: String, CaseIterable, Identifiable {
    case today
    case yesterday
    case thisWeek
    case lastWeek
    case thisMonth
    case lastMonth

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today:     return "Hoje"
        case .yesterday: return "Ontem"
        case .thisWeek:  return "Esta semana"
        case .lastWeek:  return "Semana passada"
        case .thisMonth: return "Este mês"
        case .lastMonth: return "Mês passado"
        }
    }

    func contains(_ date: Date?) -> Bool {
        guard let d = date else { return false }
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .today:
            return cal.isDateInToday(d)
        case .yesterday:
            return cal.isDateInYesterday(d)
        case .thisWeek:
            return cal.isDate(d, equalTo: now, toGranularity: .weekOfYear)
        case .lastWeek:
            guard let lastWeek = cal.date(byAdding: .weekOfYear, value: -1, to: now) else { return false }
            return cal.isDate(d, equalTo: lastWeek, toGranularity: .weekOfYear)
        case .thisMonth:
            return cal.isDate(d, equalTo: now, toGranularity: .month)
        case .lastMonth:
            guard let lastMonth = cal.date(byAdding: .month, value: -1, to: now) else { return false }
            return cal.isDate(d, equalTo: lastMonth, toGranularity: .month)
        }
    }
}

/// Coarse "when is it due" buckets matching the labels users tend to
/// reach for first. Mutually-exclusive (single-select).
enum DueWindow: String, CaseIterable, Identifiable {
    case overdue   // before today
    case today
    case tomorrow
    case thisWeek  // today through next 7 days
    case noDate    // no due date

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overdue:  return "Atrasada"
        case .today:    return "Hoje"
        case .tomorrow: return "Amanhã"
        case .thisWeek: return "Esta semana"
        case .noDate:   return "Sem data"
        }
    }

    var systemImage: String {
        switch self {
        case .overdue:  return "exclamationmark.circle"
        case .today:    return "sun.max"
        case .tomorrow: return "sunrise"
        case .thisWeek: return "calendar"
        case .noDate:   return "calendar.badge.minus"
        }
    }

    func contains(_ date: Date?) -> Bool {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        switch self {
        case .noDate:
            return date == nil
        case .overdue:
            guard let d = date else { return false }
            return d < today
        case .today:
            guard let d = date else { return false }
            return cal.isDateInToday(d)
        case .tomorrow:
            guard let d = date else { return false }
            return cal.isDateInTomorrow(d)
        case .thisWeek:
            guard let d = date else { return false }
            let weekEnd = cal.date(byAdding: .day, value: 7, to: today)!
            return d >= today && d < weekEnd
        }
    }
}
