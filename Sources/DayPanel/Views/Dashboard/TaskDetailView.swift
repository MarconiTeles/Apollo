import SwiftUI
import AppKit

// Expanded task card — every field is editable inline.
// Changes are sent to ClickUp on commit (Enter / focus loss / picker dismiss)
// with optimistic local updates and rollback on failure.

struct TaskDetailView: View, Equatable {
    let task: CUTask
    /// AppState held as a plain reference, NOT `@EnvironmentObject`.
    /// See `TaskDetailSheet.appState` for the full rationale —
    /// in short, removing the implicit subscription stops the
    /// view from re-rendering on every unrelated `@Published`
    /// change in AppState (sync ticks, attachmentHydration
    /// updates, notification arrivals, etc.) which was the
    /// dominant cost behind the popup's frame-rate drop.
    let appState: AppState
    /// When false, the comments section and "Abrir no ClickUp" link
    /// at the bottom are suppressed — the surrounding container
    /// (e.g. `TaskDetailSheet`) renders those itself, typically
    /// on the right side of a two-column layout.
    var includesComments: Bool = true
    /// Editorial tabbed layout support. The redesigned popup
    /// splits content across tabs (Tarefa / Atividade / Anexos),
    /// so the "Tarefa" tab hides attachments (they get their own
    /// tab) and the "Anexos" tab renders ONLY the attachments
    /// section. Defaults keep every other caller (inline expand,
    /// AI snippets) rendering the full body unchanged.
    var showsAttachments: Bool = true
    var attachmentsOnly:  Bool = false
    /// When true, renders ONLY the subtasks section — used by
    /// the popup's "Subtarefas" tab (title block lives in the
    /// sheet; this view contributes just the subtask list +
    /// composer, nothing else).
    var subtasksOnly:     Bool = false
    /// `EditorialDetailV2` moves the property rows (status,
    /// assignees, dates, priority, tags, time) into the right
    /// "marginalia" column, so the main column suppresses them
    /// and shows only the body (description + structured
    /// sections + subtasks). Defaults true for every other
    /// caller.
    var showsProperties: Bool = true
    /// When true, the property block renders as the editorial
    /// 4-column integrated grid (the popup look) instead of
    /// stacked rows — but every cell keeps its real editing
    /// affordance (status/priority/date popovers, tag menu,
    /// assignee search). Default false → unchanged for callers
    /// that still want the row layout.
    var propertiesAsGrid: Bool = false
    /// Lets the popup version make the description editor much taller
    /// since it has the vertical real estate.
    var descriptionMaxHeight: CGFloat = 200
    /// Floor for the description editor — the popup raises this so the
    /// description block dominates the left column even before the user
    /// types anything.
    var descriptionMinHeight: CGFloat = 50
    /// When false, the description's TextEditor stops handling its own
    /// scrolling and just grows to fit content — the popup uses this so
    /// the metadata column gets a SINGLE outer scroll bar instead of
    /// two (TextEditor's + ScrollView's).
    var descriptionScrolls: Bool = true
    /// Optional handle to the parent ScrollView so we can
    /// programmatically scroll specific sub-sections into
    /// view (subtask composer when it opens, etc.). Nil
    /// when this view is rendered outside a ScrollViewReader.
    var scrollProxy: ScrollViewProxy? = nil

    /// The subtask snapshot for THIS task, supplied by the
    /// parent so changes to children propagate through the
    /// view-tree even when the parent task itself didn't
    /// change. Without this prop, `TaskDetailView`'s
    /// `.equatable()` would short-circuit any time
    /// `task` was unchanged — which masked subtask status
    /// updates: the user changed a child's status from
    /// DOING → REVIEW, AppState mutated, but the parent
    /// task was stable so the body didn't re-run and the
    /// child's pill stayed stale until the popup was
    /// reopened. Passing the list explicitly makes the
    /// dependency visible to `==`.
    var visibleSubtasks: [CUTask] = []

    @State private var descriptionDraft = ""
    // The new RichTextEditor manages NSTextView focus directly via
    // its delegate, so we track the focus state with @State (which
    // exposes a Binding) instead of @FocusState.
    @State private var descriptionFocused: Bool = false

    @State private var showStartPicker = false
    @State private var showDuePicker   = false
    @State private var showStatusMenu  = false
    @State private var showPriorityMenu = false

    // Subtasks composer — text the user is typing for the new
    // subtask inline form, plus a focus flag so we can clear /
    // submit on blur the same way the description editor works.
    @State private var newSubtaskTitle: String = ""
    @State private var subtaskComposerOpen: Bool = false
    @FocusState private var subtaskFieldFocused: Bool

    // Assignee search-bar state — replaced the dropdown
    // Menu with a live-filtering text field per design
    // tweak. The query feeds `filteredAssigneeCandidates`
    // below; tapping a result toggles that member's
    // membership on the task.
    @State private var assigneeQuery: String = ""
    @State private var assigneeSearchOpen: Bool = false
    @FocusState private var assigneeSearchFocused: Bool

    /// LISTAS picker (multi-list / "Tasks in Multiple Lists").
    /// Same UX as the assignee picker just above: chips for current
    /// memberships, an "Adicionar/Editar" button that reveals an
    /// inline search + filtered candidate list. Tapping a row
    /// toggles the task's membership in that list.
    @State private var listsQuery: String = ""
    @State private var listsSearchOpen: Bool = false
    @FocusState private var listsSearchFocused: Bool

    /// Base-name keys of attachment version groups the user has
    /// expanded to see older revisions. Collapsed by default —
    /// only the newest version of each `…v01/v02/v03` set shows
    /// until the user opts to see the history.
    @State private var expandedVersionGroups: Set<String> = []

    /// Local (Apollo-native) reminders for this task, mirrored
    /// from `TaskReminders` (UserDefaults-backed, not @Published)
    /// so add/delete refreshes the section. Reloaded on appear
    /// and when the view is reused for a different task.
    @State private var reminders: [TaskReminders.Entry] = []
    @State private var showReminderComposer = false
    @State private var newReminderDate = Date().addingTimeInterval(3600)
    @State private var newReminderNote = ""

    // Collapsible secondary sections — collapsed by default so
    // the popup opens focused on description + subtasks.
    @State private var checklistsCollapsed   = true
    @State private var customFieldsCollapsed = true
    @State private var remindersCollapsed    = true

    /// Editorial disclosure chevron for a collapsible section
    /// header. Rotates 0°→90° (right→down) when expanded.
    @ViewBuilder
    private func collapseChevron(_ collapsed: Bool) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Editorial.inkMute)
            .rotationEffect(.degrees(collapsed ? 0 : 90))
            .frame(width: 14, height: 14)
    }

    /// Equatable conformance — `.equatable()` at the call site
    /// short-circuits re-renders when the surrounding sheet
    /// re-evaluates but the inputs that affect this view's
    /// output didn't change. AppState is a stable singleton,
    /// the description-knob params are stable for a given
    /// container, so comparing only `task` is enough.
    static func == (lhs: TaskDetailView, rhs: TaskDetailView) -> Bool {
        lhs.task == rhs.task
            && lhs.includesComments == rhs.includesComments
            && lhs.showsAttachments == rhs.showsAttachments
            && lhs.attachmentsOnly  == rhs.attachmentsOnly
            && lhs.subtasksOnly     == rhs.subtasksOnly
            && lhs.showsProperties  == rhs.showsProperties
            && lhs.propertiesAsGrid == rhs.propertiesAsGrid
            && lhs.descriptionMaxHeight == rhs.descriptionMaxHeight
            && lhs.descriptionMinHeight == rhs.descriptionMinHeight
            && lhs.descriptionScrolls == rhs.descriptionScrolls
            // Compare the children too — without this a child's
            // status edit doesn't invalidate the cached
            // `TaskDetailView` and the row stays stale until the
            // popup is reopened.
            && lhs.visibleSubtasks == rhs.visibleSubtasks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if subtasksOnly {
                subtasksSection
            } else {
            // Removed the leading `Rectangle().fill(.separator)`
            // hairline that used to sit above the status row.
            // It belonged to the older popup design where the
            // header was a heavy band and the line acted as a
            // soft transition into the metadata grid. With the
            // current material-only-on-header look the line
            // visually competes with the header/body boundary
            // — the user explicitly asked for it gone.
            if !attachmentsOnly {
                if showsProperties {
                    if propertiesAsGrid {
                        propertiesGrid
                    } else {
                        statusRow
                        assigneesRow
                        datesRow
                        priorityRow
                        tagsRow
                        timeTrackingRow
                    }
                }

                descriptionField
            }

            // Attachment chips — one row per file linked to the
            // task. Pulled from BOTH ClickUp's structured
            // attachments array AND any markdown-style file
            // links scraped out of the description body, so the
            // user always sees every file regardless of how
            // the API surfaced it.
            //
            // The section is rendered ALWAYS now (was gated
            // behind a `shouldShow` boolean before). Earlier
            // gating could hide the section before hydration
            // even ran — when `attachmentHydration[task.id]`
            // was still nil and the list-endpoint task had
            // empty attachments, the user just saw nothing
            // and assumed the section was broken. Always
            // rendering means: empty taps still show the
            // header + a "Sem anexos" hint until the network
            // call confirms or fills it.
            if showsAttachments || attachmentsOnly {
                attachmentsSection
            }

            if !attachmentsOnly {

            // Checklists sit between attachments and subtasks —
            // they're task-scoped structured to-dos, conceptually
            // tighter to the task body than the subtask hierarchy.
            // Only rendered when the hydrated task actually has
            // checklists (the list endpoint omits them; they
            // arrive with the same getTask call that fills
            // attachments).
            checklistsSection

            // Custom fields sit between checklists and subtasks —
            // they're task-scoped metadata like checklists, but
            // free-form, so they read as "extra structured data"
            // before the subtask hierarchy. Hidden when the
            // hydrated task exposes nothing worth showing.
            customFieldsSection

            // Dependencies/links sit right after the metadata
            // block and before the subtask hierarchy — they're
            // cross-task relations, conceptually a peer of
            // subtasks. Hidden when the hydrated task has none.
            dependenciesSection

            // Local reminders — Apollo-native (ClickUp's API
            // can't expose readable reminders). Always shown so
            // the "+ Lembrete" affordance is available even when
            // none exist yet.
            remindersSection

            // Subtasks live above the comments separator so the
            // structural hierarchy of the parent (status/dates/
            // description/subtasks) reads as one block before the
            // social/conversation surface (comments) begins.
            // Rendered for ANY task / subtask depth so the
            // "Adicionar" button is always available — even
            // tasks that don't have any subtasks yet need a
            // way to add the FIRST one. The header still
            // shows "0/0" with the action button visible;
            // empty list below it disappears naturally.
            subtasksSection

            if includesComments {
                Rectangle()
                    .fill(.separator.opacity(0.4))
                    .frame(height: 0.5)
                    .padding(.horizontal, -12)

                TaskCommentsSection(task: task, appState: appState)
                    .equatable()

                if let urlStr = task.url, let url = URL(string: urlStr) {
                    Link(destination: url) {
                        HStack(spacing: 5) {
                            Text("Abrir no ClickUp").font(.caption.weight(.medium))
                            Image(systemName: "arrow.up.right.square").font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(.blue)
                    }
                    .focusEffectDisabled()
                }
            }

            } // end if !attachmentsOnly
            } // end if subtasksOnly / else
        }
        .padding(.horizontal, 12)
        // Asymmetric vertical padding: small top so the detail view
        // sits closer to the title (the compactRow already bottoms
        // out tight against this view), normal bottom so the comments
        // / description don't run into the card's edge.
        .padding(.top, 4)
        .padding(.bottom, 10)
        .onAppear {
            descriptionDraft = task.description ?? ""
            triggerAttachmentHydration()
            reminders = TaskReminders.forTask(task.id)
        }
        .onChange(of: task.description) { _, new in
            if !descriptionFocused { descriptionDraft = new ?? "" }
        }
        // Re-fire when the same view instance is reused for a
        // different task — happens in the inline expanded pill
        // when the user expands one row, collapses, and expands
        // a different one (SwiftUI may diff to the same view).
        .onChange(of: task.id) { _, _ in
            triggerAttachmentHydration()
            reminders = TaskReminders.forTask(task.id)
            showReminderComposer = false
        }
    }

    /// Idempotent attachment hydration. The detail view is
    /// hosted in three places (popup, inline expanded row, AI
    /// chat snippet) — running this from `TaskDetailView` itself
    /// instead of from each container guarantees the "Anexos"
    /// section stays consistent everywhere. The guard skips
    /// fetches when we already have a cached result so the
    /// expand→collapse→expand cycle doesn't spam the API.
    private func triggerAttachmentHydration() {
        let current = appState.attachmentHydration[task.id]
        switch current {
        case .loading:
            // Already in flight — do nothing. The original call
            // will publish the result to every observer.
            return
        case .loaded:
            // Already have a definitive answer cached for this
            // app session. Tasks rarely gain anexos behind the
            // user's back; skipping the refetch keeps the UI
            // snappy and avoids hitting ClickUp's rate limit
            // on every expansion toggle.
            return
        case .error, .none:
            // Either we've never tried, or the previous attempt
            // failed — either way, kick off a fresh fetch.
            Task { await appState.hydrateTaskAttachments(taskId: task.id) }
        }
    }

    // MARK: - Assignees (interactive search)

    /// Members in the workspace that match the current
    /// query, with already-assigned ones bubbled to the top
    /// (so the user can also UN-assign by clicking them).
    private var filteredAssigneeCandidates: [CUMember] {
        let q = assigneeQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let assignedIds = Set(task.assignees.map(\.id))
        let pool = appState.availableMembers
        let filtered: [CUMember]
        if q.isEmpty {
            filtered = pool
        } else {
            filtered = pool.filter {
                $0.username.lowercased().contains(q) ||
                ($0.email?.lowercased().contains(q) ?? false)
            }
        }
        return filtered.sorted { lhs, rhs in
            let l = assignedIds.contains(lhs.id) ? 0 : 1
            let r = assignedIds.contains(rhs.id) ? 0 : 1
            if l != r { return l < r }
            return lhs.username.localizedCaseInsensitiveCompare(rhs.username) == .orderedAscending
        }
    }

    private var assigneesRow: some View {
        detailRow(icon: "person.fill", label: "Responsáveis") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if !task.assignees.isEmpty {
                        HStack(spacing: -4) {
                            ForEach(task.assignees.prefix(3), id: \.id) { a in
                                assigneeChip(a)
                                    .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                            }
                            if task.assignees.count > 3 {
                                Text("+\(task.assignees.count - 3)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 6)
                            }
                        }
                    }
                    if !assigneeSearchOpen {
                        Button {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                                assigneeSearchOpen = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                assigneeSearchFocused = true
                            }
                        } label: {
                            Text(task.assignees.isEmpty ? "Adicionar" : "Editar")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                }

                if assigneeSearchOpen {
                    assigneeSearchBar
                }
            }
        }
    }

    /// Inline search bar + suggestions list. Replaces the
    /// previous popover Menu so the user can type to filter
    /// the workspace's member list and toggle assignment
    /// without closing/reopening anything.
    @ViewBuilder
    private var assigneeSearchBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("Buscar pessoa…", text: $assigneeQuery)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .focused($assigneeSearchFocused)
                if !assigneeQuery.isEmpty {
                    Button {
                        assigneeQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        assigneeSearchOpen = false
                        assigneeQuery = ""
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Fechar busca")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )

            // Filtered suggestions — capped at 6 visible at
            // a time. Already-assigned members rise to the
            // top so the same row toggles add ↔ remove.
            if appState.availableMembers.isEmpty {
                Text("Sem membros disponíveis no workspace")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
            } else {
                let candidates = filteredAssigneeCandidates
                if candidates.isEmpty {
                    Text("Nenhuma pessoa encontrada")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(candidates.prefix(6)) { m in
                            assigneeRow(m)
                            if m.id != candidates.prefix(6).last?.id {
                                Rectangle()
                                    .fill(.separator.opacity(0.3))
                                    .frame(height: 0.5)
                            }
                        }
                    }
                    .background(Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                    )
                }
            }
        }
    }

    /// One row in the assignee suggestions dropdown.
    /// Tapping toggles the member's membership on the task.
    private func assigneeRow(_ m: CUMember) -> some View {
        let isAssigned = task.assignees.contains(where: { $0.id == m.id })
        return Button {
            var ids = Set(task.assignees.map(\.id))
            if isAssigned { ids.remove(m.id) } else { ids.insert(m.id) }
            Task { await appState.updateTaskAssignees(task, to: ids) }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(m.color.flatMap { Color(hex: $0) } ?? .blue)
                    .frame(width: 18, height: 18)
                    .overlay(
                        Text(m.initials ?? String(m.username.prefix(2)).uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                    )
                VStack(alignment: .leading, spacing: 0) {
                    Text(m.username)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                    if let email = m.email {
                        Text(email)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: isAssigned ? "checkmark.circle.fill" : "plus.circle")
                    .font(.caption)
                    .foregroundStyle(isAssigned ? Color.green : Editorial.accent)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    // MARK: - Dates (start + due, popover with DatePicker)

    private var datesRow: some View {
        detailRow(icon: "calendar", label: "Datas") {
            HStack(spacing: 6) {
                dateButton(
                    label:  task.startDate.map { SharedDateFormatters.shortDayMonthPTBR.string(from: $0) } ?? "Início",
                    color:  task.startDate == nil ? .secondary : .primary,
                    show:   $showStartPicker
                ) {
                    UnifiedDatePickerPopover(task: task, initialMode: .start) { mode, date in
                        commitDate(mode: mode, date: date)
                    }
                }
                if task.startDate != nil || task.dueDate != nil {
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                }
                dateButton(
                    label:  task.dueDate.map { SharedDateFormatters.shortDayMonthPTBR.string(from: $0) } ?? "Vencimento",
                    color:  task.dueDate == nil ? .secondary
                            : (task.dueDate! < Date() && !task.isCompleted ? .red : .primary),
                    show:   $showDuePicker
                ) {
                    UnifiedDatePickerPopover(task: task, initialMode: .due) { mode, date in
                        commitDate(mode: mode, date: date)
                    }
                }
            }
        }
    }

    private func commitDate(mode: UnifiedDatePickerPopover.Mode, date: Date?) {
        switch mode {
        case .start: Task { await appState.updateTaskStartDate(task, to: date) }
        case .due:   Task { await appState.updateTaskDueDate(task,   to: date) }
        }
    }

    @ViewBuilder
    private func dateButton<Content: View>(
        label: String,
        color: Color,
        show: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        // Editorial date button — same clean card chrome the
        // "Nova Tarefa" sheet uses (Editorial.card fill + 1px
        // rule, radius 4). The `color` argument tints only the
        // text: ink when set, inkMute placeholder, cinnabar when
        // the due date is overdue — no separate red chip.
        Button { show.wrappedValue.toggle() } label: {
            Text(label)
                .font(Editorial.sans(11, .medium))
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Editorial.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Editorial.rule, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .popover(isPresented: show, arrowEdge: .bottom) { content() }
    }

    // MARK: - Status (same pill as compact row, but lives in the body)

    // MARK: - Integrated properties grid (editorial, interactive)

    /// Editorial 4-column properties bar. Each cell reuses the
    /// SAME editing affordance the stacked rows use (status /
    /// priority / date popovers, tag menu, assignee search) —
    /// only the layout differs.
    private var propertiesGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(),
                                               spacing: 28,
                                               alignment: .topLeading),
                            count: 4),
            alignment: .leading,
            spacing: 22
        ) {
            kvCell("Status") {
                let c = Color(statusHex: task.statusDisplayHex)
                Button { showStatusMenu.toggle() } label: {
                    HStack(spacing: 7) {
                        Circle().fill(c).frame(width: 8, height: 8)
                        // Editorial all-caps: word UPPERCASE, tinted with the
                        // status's own colour (matches the list pill + the dot).
                        Text(task.status.uppercased())
                            .font(Editorial.sans(10.5, .semibold))
                            .tracking(0.6)
                            .foregroundStyle(c)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Editorial.inkFaint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(appState.availableStatuses.isEmpty)
                .popover(isPresented: $showStatusMenu, arrowEdge: .bottom) {
                    StatusPickerPopover(
                        statuses:          appState.availableStatuses,
                        currentStatusName: task.status
                    ) { status in
                        Task { await appState.updateTaskStatus(task, to: status) }
                        showStatusMenu = false
                    }
                }
            }

            kvCell("Datas") {
                HStack(spacing: 6) {
                    dateButton(
                        label: task.startDate.map { SharedDateFormatters.shortDayMonthPTBR.string(from: $0) } ?? "Início",
                        color: task.startDate == nil ? Editorial.inkMute : Editorial.ink,
                        show:  $showStartPicker
                    ) {
                        UnifiedDatePickerPopover(task: task, initialMode: .start) { mode, date in
                            commitDate(mode: mode, date: date)
                        }
                    }
                    if task.startDate != nil || task.dueDate != nil {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10))
                            .foregroundStyle(Editorial.inkMute)
                    }
                    dateButton(
                        label: task.dueDate.map { SharedDateFormatters.shortDayMonthPTBR.string(from: $0) } ?? "Vencimento",
                        color: task.dueDate == nil ? Editorial.inkMute
                               : (task.dueDate! < Date() && !task.isCompleted ? Editorial.accent : Editorial.ink),
                        show:  $showDuePicker
                    ) {
                        UnifiedDatePickerPopover(task: task, initialMode: .due) { mode, date in
                            commitDate(mode: mode, date: date)
                        }
                    }
                }
            }

            kvCell("Prioridade") {
                Button { showPriorityMenu.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: task.priority == 0 ? "flag" : "flag.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color(hex: task.priorityHex))
                        Text(task.priorityLabel)
                            .font(Editorial.sans(12))
                            .foregroundStyle(Editorial.ink)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Editorial.inkFaint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .popover(isPresented: $showPriorityMenu, arrowEdge: .bottom) {
                    priorityMenuContent
                }
            }

            kvCell("Responsáveis") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if !task.assignees.isEmpty {
                            HStack(spacing: -4) {
                                ForEach(task.assignees.prefix(3), id: \.id) { a in
                                    assigneeChip(a)
                                        .overlay(Circle().strokeBorder(Editorial.paper, lineWidth: 1.5))
                                }
                            }
                        }
                        if !assigneeSearchOpen {
                            Button {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                                    assigneeSearchOpen = true
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    assigneeSearchFocused = true
                                }
                            } label: {
                                Text(task.assignees.isEmpty ? "Adicionar" : "Editar")
                                    .font(Editorial.sans(12, .medium))
                                    .foregroundStyle(Editorial.accent)
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                        }
                    }
                    if assigneeSearchOpen { assigneeSearchBar }
                }
            }

            kvCell("Etiquetas") {
                HStack(spacing: 4) {
                    if !task.tags.isEmpty {
                        ForEach(task.tags, id: \.name) { tag in tagPill(tag) }
                    }
                    Menu {
                        if appState.availableTags.isEmpty {
                            Text("Sem etiquetas")
                        } else {
                            ForEach(appState.availableTags, id: \.name) { t in
                                Button {
                                    var names = Set(task.tags.map(\.name))
                                    if names.contains(t.name) { names.remove(t.name) }
                                    else { names.insert(t.name) }
                                    Task { await appState.updateTaskTags(task, to: names) }
                                } label: {
                                    if task.tags.contains(where: { $0.name == t.name }) {
                                        Label(t.name, systemImage: "checkmark")
                                    } else { Text(t.name) }
                                }
                            }
                        }
                    } label: {
                        Text(task.tags.isEmpty ? "Adicionar" : "+")
                            .font(Editorial.sans(12, .medium))
                            .foregroundStyle(Editorial.accent)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .focusEffectDisabled()
                }
            }

            kvCell("Anexos") {
                Text(task.attachments.isEmpty
                     ? "—" : "\(task.attachments.count) arquivos")
                    .font(Editorial.sans(12))
                    .foregroundStyle(task.attachments.isEmpty
                                     ? Editorial.inkMute : Editorial.ink)
            }

            kvCell("Listas") { listsCellContent }

            kvCell("Criado por") {
                if let who = task.creator?.username
                    ?? task.assignees.first?.username {
                    let name = who.split(separator: "@").first.map(String.init) ?? who
                    Text(name + (task.dateCreated
                                 .map { " · \(relativeCreatedTDV($0))" } ?? ""))
                        .font(Editorial.sans(12))
                        .foregroundStyle(Editorial.ink)
                        .lineLimit(2)
                } else {
                    Text("—").font(Editorial.sans(12))
                        .foregroundStyle(Editorial.inkMute)
                }
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func kvCell<V: View>(_ label: String,
                                 @ViewBuilder _ value: () -> V) -> some View {
        // Label matches the "Nova Tarefa" marginalia spec exactly
        // (10.5 semibold, 1.1 tracking, inkMute) so the two
        // surfaces read as one design.
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased())
                .font(Editorial.sans(10.5, .semibold))
                .tracking(1.1)
                .foregroundStyle(Editorial.inkMute)
            value()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func relativeCreatedTDV(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private var statusRow: some View {
        let color = Color(statusHex: task.statusDisplayHex)

        let pill = HStack(spacing: 4) {
            Text(task.status.uppercased())
                .font(.system(size: 10, weight: .bold))
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .opacity(0.7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .foregroundStyle(color)
        // Was `.ultraThinMaterial` + `.liquidGlassEdge`. Both
        // recompute their backdrop blur every frame during
        // scroll. Replaced with a tinted translucent fill in
        // the status's own colour — preserves the visual
        // identity (the pill still reads as "this status's
        // colour") without the per-frame blur cost.
        .background(color.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.55), lineWidth: 1))

        return detailRow(icon: "circle.dashed", label: "Status") {
            Group {
                if appState.availableStatuses.isEmpty {
                    pill
                } else {
                    Button { showStatusMenu.toggle() } label: { pill }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .popover(isPresented: $showStatusMenu, arrowEdge: .top) {
                            StatusPickerPopover(
                                statuses:          appState.availableStatuses,
                                currentStatusName: task.status
                            ) { status in
                                Task { await appState.updateTaskStatus(task, to: status) }
                                showStatusMenu = false
                            }
                        }
                }
            }
        }
    }

    // MARK: - Priority (Menu with ClickUp-style coloured flag icons)

    private struct PriorityOption {
        let value: Int
        let label: String
        let hex:   String
    }

    /// Hex values match ClickUp's canonical priority palette (same as
    /// `CUTask.priorityHex`).
    private let priorityOptions: [PriorityOption] = [
        .init(value: 1, label: "Urgente", hex: "#F50000"),
        .init(value: 2, label: "Alta",    hex: "#FFCC00"),
        .init(value: 3, label: "Normal",  hex: "#6FDDFF"),
        .init(value: 4, label: "Baixa",   hex: "#87909E"),
        .init(value: 0, label: "Limpar",  hex: "#BFBFBF"),
    ]

    // Custom popover (not SwiftUI Menu) so coloured flag icons survive —
    // macOS Menu strips foregroundStyle from item icons.
    private var priorityRow: some View {
        detailRow(icon: "flag.fill", label: "Prioridade") {
            Button { showPriorityMenu.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: task.priority == 0 ? "flag" : "flag.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(hex: task.priorityHex))
                    Text(task.priorityLabel).font(.caption.weight(.medium))
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.7)
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .popover(isPresented: $showPriorityMenu, arrowEdge: .bottom) {
                priorityMenuContent
            }
        }
    }

    private var priorityMenuContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(priorityOptions, id: \.value) { p in
                Button {
                    // "Limpar" (value 0) resets the task back to unprioritised.
                    Task { await appState.updateTaskPriority(task, to: p.value) }
                    showPriorityMenu = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: p.value == 0 ? "eraser.fill" : "flag.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(p.value == 0 ? Color.secondary : Color(hex: p.hex))
                            .frame(width: 16)
                        Text(p.label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        if p.value == task.priority {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()

                if p.value != priorityOptions.last?.value {
                    Rectangle().fill(.separator.opacity(0.3)).frame(height: 0.5)
                }
            }
        }
        .frame(minWidth: 160)
    }

    // MARK: - Tags (multi-select Menu + chips)

    private var tagsRow: some View {
        detailRow(icon: "tag.fill", label: "Etiquetas") {
            HStack(spacing: 4) {
                if !task.tags.isEmpty {
                    ForEach(task.tags, id: \.name) { tag in
                        tagPill(tag)
                    }
                }
                Menu {
                    if appState.availableTags.isEmpty {
                        Text("Sem etiquetas")
                    } else {
                        ForEach(appState.availableTags, id: \.name) { t in
                            Button {
                                var names = Set(task.tags.map(\.name))
                                if names.contains(t.name) { names.remove(t.name) } else { names.insert(t.name) }
                                Task { await appState.updateTaskTags(task, to: names) }
                            } label: {
                                if task.tags.contains(where: { $0.name == t.name }) {
                                    Label(t.name, systemImage: "checkmark")
                                } else {
                                    Text(t.name)
                                }
                            }
                        }
                    }
                } label: {
                    Text(task.tags.isEmpty ? "Adicionar" : "+")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.blue)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .focusEffectDisabled()
            }
        }
    }

    // MARK: - Description (TextEditor — saves on blur)

    private var descriptionField: some View {
        // 12pt of breathing room between the separator and the
        // first line of the editor — without it the line's top
        // sits right under the separator and gets visually clipped.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(.separator.opacity(0.4))
                    .frame(height: 0.5)
                Spacer(minLength: 6)
                // Display / edit toggle. In display mode the
                // RichTextEditor renders ClickUp-attachment URLs
                // as inline pill cards; in edit mode it shows the
                // raw markdown so the user can rewrite the body.
                // Wired to the same `descriptionFocused` focus
                // state the rest of the system already tracks —
                // flipping it programmatically swaps the mode AND
                // routes a final commit through the existing
                // `onCommit` path when the user toggles back to
                // display.
                Button {
                    descriptionFocused.toggle()
                } label: {
                    Image(systemName: descriptionFocused
                          ? "eye.fill" : "pencil")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(
                                    descriptionFocused ? 0.10 : 0.05
                                ))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.10),
                                              lineWidth: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(descriptionFocused
                      ? "Voltar para o modo de leitura (anexos como cards)"
                      : "Editar texto da descrição (markdown bruto)")
            }
            .padding(.horizontal, -12)

            ZStack(alignment: .topLeading) {
                if descriptionDraft.isEmpty && !descriptionFocused {
                    // Match the placeholder offset to the
                    // RichTextEditor's NSTextView insets (top=8,
                    // left=5).
                    Text("Adicionar descrição…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
                // Single editor implementation for both modes —
                // `RichTextEditor` is a custom NSTextView wrapper
                // that handles inset / clipping / link detection
                // correctly in either layout. The inline (row)
                // version scrolls internally up to a cap; the
                // popup version sizes to content so the metadata
                // column's outer ScrollView owns the scrolling.
                RichTextEditor(
                    text:              $descriptionDraft,
                    minHeight:         descriptionMinHeight,
                    maxHeight:         descriptionScrolls ? descriptionMaxHeight : .greatestFiniteMagnitude,
                    scrollsInternally: descriptionScrolls,
                    fontSize:          12,
                    isFocused:         $descriptionFocused,
                    onCommit: {
                        if descriptionDraft != (task.description ?? "") {
                            Task { await appState.updateTaskDescription(task, to: descriptionDraft) }
                        }
                    },
                    renderAttachmentCards: true,
                    onFileDrop: { urls in
                        // Drop a file on the description → upload it
                        // as a real task attachment (it then renders
                        // as the editorial attachment card), instead
                        // of pasting the raw POSIX path into the
                        // prose. Sequential to respect rate limits;
                        // multi-file safe.
                        Task {
                            for u in urls {
                                _ = await appState.uploadCommentAttachment(
                                    for: task, fileURL: u
                                )
                            }
                            appState.attachmentHydration
                                .removeValue(forKey: task.id)
                            await appState.hydrateTaskAttachments(taskId: task.id)
                        }
                    }
                )
                // Frame: bounded min + max in both layout modes.
                // For the popup (`!scrollsInternally`) we let
                // `maxHeight: .infinity` allow the editor to grow
                // arbitrarily, and the outer ScrollView in
                // `TaskDetailSheet.metadataColumn` owns the
                // scrolling. Avoid `.fixedSize(vertical:)` here:
                // SwiftUI's interaction with NSViewRepresentable
                // intrinsic sizes is finicky, and forcing a fixed
                // size in either dimension can make the editor's
                // height collapse to its `minHeight` instead of
                // tracking the rendered text — the symptom is
                // wrapped lines being clipped just under the
                // visible bottom edge of the popup body.
                .frame(minHeight: descriptionMinHeight,
                       maxHeight: descriptionScrolls ? descriptionMaxHeight : .infinity)
            }
        }
    }

    // MARK: - Attachments

    /// Chips for every file attached to the task. Each chip
    /// shows the file's icon (typed by extension), title, and
    /// optional size, and opens the file's URL in the default
    /// browser on click. Layout uses a vertical stack rather
    /// than a flow layout so long titles can wrap inside the
    /// chip without being truncated by a row's width budget.
    @ViewBuilder
    private var attachmentsSection: some View {
        let hyd = appState.attachmentHydration[task.id]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("ANEXOS")
                    .font(Editorial.sans(10.5, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Editorial.inkMute)
                Text("\(task.attachments.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)

                // Inline diagnostic so the user knows whether
                // the list is empty because (a) ClickUp really
                // has no anexos for this task, (b) the request
                // is still loading, or (c) the API returned an
                // error. Without this it looks like the app
                // simply ignores the files.
                switch hyd {
                case .loading:
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Sincronizando…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                case .loaded(let n) where n == 0 && task.attachments.isEmpty:
                    Text("Nenhum anexo")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                case .error(let msg):
                    Text("Erro: \(msg)")
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.85))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .help(msg)
                case .none where task.attachments.isEmpty:
                    Text("Aguardando…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                default:
                    EmptyView()
                }

                // Manual refresh — covers the cases where the
                // first hydration came back empty (transient
                // network blip, rate limit, etc) and the
                // idempotency guard would otherwise skip the
                // re-fetch. Click forcibly clears the cached
                // state and re-runs the per-task GET.
                Button {
                    appState.attachmentHydration.removeValue(forKey: task.id)
                    Task { await appState.hydrateTaskAttachments(taskId: task.id) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Recarregar anexos")
            }

            // LazyVStack so a task with 14+ anexos doesn't pay
            // the full chip-mount cost (icon plate, gradient,
            // shadow, hover modifier, scaleEffect) on popup
            // open — the chips below the fold defer until the
            // user scrolls them into view.
            // Version-aware: files that look like revisions of
            // the same creative (`…v01/v02/V3` before the
            // extension) collapse into one chip showing the
            // NEWEST version, with the older ones tucked behind a
            // disclosure. Non-versioned files render exactly as
            // before, in their original position.
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(Self.versionGroupedAttachments(task.attachments)) { group in
                    if group.versions.count <= 1 {
                        AttachmentChip(attachment: group.newest,
                                       taskURL: task.url,
                                       taskId: task.id, listId: task.listId,
                                       actorId: reviewActorId, actorName: reviewActorName)
                            .equatable()
                    } else {
                        attachmentVersionGroup(group)
                    }
                }
            }
        }
    }

    // MARK: - Attachment version grouping

    /// One render unit in the attachment list: either a lone
    /// file (`versions.count == 1`) or a set of revisions of the
    /// same creative, newest first.
    struct AttachmentGroup: Identifiable {
        let id: String                 // normalized base name (or url)
        let versions: [CUTask.Attachment]   // sorted: newest → oldest
        var newest: CUTask.Attachment { versions[0] }
        var latestLabel: String        // "v3" etc.
    }

    /// Parses a trailing `v<n>` revision token off a filename.
    /// Returns the normalized base + version, or nil when the
    /// name isn't versioned (so it stays a singleton). Years like
    /// `v2024` are rejected (4+ digits) to avoid false groups.
    private static func versionToken(_ title: String)
        -> (base: String, version: Int)? {
        let stem = (title as NSString).deletingPathExtension
        let pattern = "^(.*?)[ _\\-.]?[vV](\\d{1,3})$"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let full = NSRange(stem.startIndex..., in: stem)
        guard let m = re.firstMatch(in: stem, range: full),
              m.numberOfRanges == 3,
              let baseR = Range(m.range(at: 1), in: stem),
              let verR  = Range(m.range(at: 2), in: stem),
              let v = Int(stem[verR]) else { return nil }
        let base = stem[baseR]
            .trimmingCharacters(in: CharacterSet(charactersIn: " _-."))
            .lowercased()
        guard !base.isEmpty else { return nil }
        return (base, v)
    }

    /// Groups attachments by version base, preserving the
    /// original list order: the group is emitted at the position
    /// of its first-seen member; non-versioned files stay as
    /// singletons exactly where they were.
    static func versionGroupedAttachments(
        _ allAtts: [CUTask.Attachment]
    ) -> [AttachmentGroup] {
        // Hide the review-JSON blobs Apollo uploads — they're internal plumbing
        // for "Ver review", not user-facing files.
        let atts = allAtts.filter { !$0.title.hasPrefix("apollo-review") }
        // base -> attachments (with parsed version)
        var buckets: [String: [(att: CUTask.Attachment, v: Int)]] = [:]
        for a in atts {
            if let (base, v) = versionToken(a.title) {
                buckets[base, default: []].append((a, v))
            }
        }
        var out: [AttachmentGroup] = []
        var emitted = Set<String>()
        for a in atts {
            if let (base, _) = versionToken(a.title),
               let bucket = buckets[base], bucket.count > 1 {
                if emitted.contains(base) { continue }
                emitted.insert(base)
                let sorted = bucket.sorted { $0.v > $1.v }
                out.append(AttachmentGroup(
                    id: base,
                    versions: sorted.map(\.att),
                    latestLabel: "v\(sorted[0].v)"))
            } else {
                out.append(AttachmentGroup(
                    id: a.id,
                    versions: [a],
                    latestLabel: ""))
            }
        }
        return out
    }

    /// Connected ClickUp user, for the REVIEW deep link's actor.
    private var reviewActorId: Int? { appState.clickUpAuthService.userId }
    private var reviewActorName: String {
        let id = appState.clickUpAuthService.userId
        return appState.availableMembers.first { $0.id == id }?.username ?? "Revisor"
    }

    @ViewBuilder
    private func attachmentVersionGroup(_ group: AttachmentGroup) -> some View {
        let expanded = expandedVersionGroups.contains(group.id)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                AttachmentChip(attachment: group.newest,
                               taskURL: task.url,
                               taskId: task.id, listId: task.listId,
                               actorId: reviewActorId, actorName: reviewActorName)
                    .equatable()
            }
            Button {
                if expanded { expandedVersionGroups.remove(group.id) }
                else        { expandedVersionGroups.insert(group.id) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded
                          ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9))
                    Text(expanded
                         ? "Ocultar versões anteriores"
                         : "\(group.latestLabel) · \(group.versions.count) versões")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .padding(.leading, 4)

            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(group.versions.dropFirst().map { $0 }) { old in
                        AttachmentChip(attachment: old,
                                       taskURL: task.url,
                                       taskId: task.id, listId: task.listId,
                                       actorId: reviewActorId, actorName: reviewActorName)
                            .equatable()
                            .opacity(0.72)
                    }
                }
                .padding(.leading, 14)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Checklists

    /// Renders every ClickUp checklist on the task as a
    /// collapsible-feeling block: a header with the checklist
    /// name + "resolved/total" progress, then a tight list of
    /// checkbox rows. Toggling a box flips it optimistically
    /// via `AppState.toggleChecklistItem` (PUT + rollback on
    /// failure). Hidden entirely when the hydrated task has no
    /// checklists so tasks that never use the feature don't
    /// carry dead chrome.
    @ViewBuilder
    private var checklistsSection: some View {
        if !task.checklists.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        checklistsCollapsed.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        collapseChevron(checklistsCollapsed)
                        Text("CHECKLIST")
                            .font(Editorial.sans(10.5, .semibold))
                            .tracking(1.2)
                            .foregroundStyle(Editorial.inkMute)
                        Text("\(task.checklists.reduce(0) { $0 + $1.resolvedCount })/\(task.checklists.reduce(0) { $0 + $1.items.count })")
                            .font(Editorial.sans(10.5).monospacedDigit())
                            .foregroundStyle(Editorial.inkMute)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()

                if !checklistsCollapsed {
                ForEach(task.checklists) { checklist in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(checklist.name.uppercased())
                                .font(Editorial.sans(10.5, .semibold))
                                .tracking(1.2)
                                .foregroundStyle(Editorial.inkMute)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text("\(checklist.resolvedCount)/\(checklist.items.count)")
                                .font(Editorial.sans(10.5).monospacedDigit())
                                .foregroundStyle(Editorial.inkMute)
                        }

                        // Thin progress bar — quick visual of
                        // how done the checklist is.
                        if !checklist.items.isEmpty {
                            GeometryReader { geo in
                                let frac = checklist.items.isEmpty ? 0
                                    : Double(checklist.resolvedCount)
                                        / Double(checklist.items.count)
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Editorial.rule)
                                    Capsule()
                                        .fill(Editorial.accent.opacity(0.55))
                                        .frame(width: geo.size.width * frac)
                                }
                            }
                            .frame(height: 3)
                        }

                        ForEach(checklist.items) { item in
                            checklistItemRow(checklist: checklist, item: item)
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Editorial.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Editorial.rule, lineWidth: 1)
                    )
                }
                }
            }
        }
    }

    private func checklistItemRow(checklist: CUTask.Checklist,
                                  item: CUTask.Checklist.Item) -> some View {
        Button {
            Task {
                await appState.toggleChecklistItem(
                    taskId:      task.id,
                    checklistId: checklist.id,
                    itemId:      item.id,
                    to:          !item.resolved
                )
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: item.resolved
                      ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(item.resolved
                                     ? Editorial.accent
                                     : Color.secondary.opacity(0.55))
                Text(item.name.isEmpty ? "(sem texto)" : item.name)
                    .font(.caption)
                    .foregroundStyle(item.resolved ? .secondary : .primary)
                    .strikethrough(item.resolved, color: .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if item.assigneeId != nil {
                    Image(systemName: "person.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .help("Item atribuído")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    // MARK: - Time tracking

    /// "2h 15m" / "45m" / "30s" / "—" for a millisecond total.
    private func formatDuration(_ ms: Int) -> String {
        guard ms > 0 else { return "—" }
        let totalSec = ms / 1000
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    /// Metadata-style row: tracked total + a start/stop control.
    /// Always shown (it's actionable even at zero) so the user
    /// can begin timing from the popup. The running label counts
    /// up live via a 1s TimelineView while this task's timer is
    /// the active one.
    @ViewBuilder
    private var timeTrackingRow: some View {
        let total   = appState.taskTrackedMs[task.id]
        let running = appState.runningTimer?.taskId == task.id
        let startedAt = appState.runningTimer?.startedAt

        detailRow(icon: "stopwatch", label: "Tempo") {
            HStack(spacing: 8) {
                Text(total.map(formatDuration) ?? "—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(total == nil ? .tertiary : .secondary)

                if running, let startedAt {
                    // Live session counter (HH:MM:SS) — updates
                    // itself without a timer; sits next to the
                    // stored total so the user sees both.
                    Text(timerInterval: startedAt...Date.distantFuture,
                         countsDown: false)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Editorial.accent)
                        .frame(minWidth: 52, alignment: .leading)
                }

                Button {
                    Task { await appState.toggleTimer(for: task.id) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: running
                              ? "stop.circle.fill" : "play.circle.fill")
                            .font(.caption)
                        Text(running ? "Parar" : "Iniciar")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(running ? Color.red : Editorial.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill((running ? Color.red
                                        : Editorial.accent).opacity(0.12))
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(running ? "Parar o timer" : "Iniciar timer nesta tarefa")

                if running {
                    Text("gravando…")
                        .font(.caption2)
                        .foregroundStyle(Color.red.opacity(0.7))
                }
            }
        }
    }

    // MARK: - Custom fields

    /// Fields worth surfacing: anything with a value, plus
    /// editable drop-downs even when empty (so the user can set
    /// "Próxima Etapa" etc. from here). Empty read-only fields
    /// (the many null BASELINE_* / blank text fields ClickUp
    /// returns) are filtered out so the section stays signal.
    private var visibleCustomFields: [CUTask.CustomField] {
        task.customFields.filter { $0.hasValue || $0.isEditable }
    }

    @ViewBuilder
    private var customFieldsSection: some View {
        let fields = visibleCustomFields
        if !fields.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        customFieldsCollapsed.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        collapseChevron(customFieldsCollapsed)
                        Text("CAMPOS")
                            .font(Editorial.sans(10.5, .semibold))
                            .tracking(1.2)
                            .foregroundStyle(Editorial.inkMute)
                        Text("\(fields.count)")
                            .font(Editorial.sans(10.5).monospacedDigit())
                            .foregroundStyle(Editorial.inkMute)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()

                if !customFieldsCollapsed {
                    VStack(spacing: 0) {
                        ForEach(fields) { field in
                            customFieldRow(field)
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Editorial.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Editorial.rule, lineWidth: 1)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func customFieldRow(_ field: CUTask.CustomField) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Label {
                Text(field.name)
                    .font(Editorial.sans(12))
                    .foregroundStyle(Editorial.inkSoft)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: field.icon)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Editorial.inkMute)
                    .frame(width: 14)
            }
            .labelStyle(.titleAndIcon)
            .frame(width: 130, alignment: .leading)

            if field.isEditable {
                Menu {
                    ForEach(field.options) { opt in
                        Button {
                            Task {
                                await appState.setTaskCustomField(
                                    taskId:  task.id,
                                    fieldId: field.id,
                                    option:  opt)
                            }
                        } label: {
                            if field.selectedOptionId == opt.id {
                                Label(opt.name, systemImage: "checkmark")
                            } else {
                                Text(opt.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(field.hasValue ? field.displayValue : "Definir…")
                            .font(Editorial.sans(12, .medium))
                            .foregroundStyle(field.hasValue
                                             ? Editorial.ink
                                             : Editorial.accent)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Editorial.inkFaint)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Editorial.page))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Editorial.rule, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Text(field.displayValue)
                    .font(Editorial.sans(12))
                    .foregroundStyle(Editorial.ink)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
    }

    // MARK: - Dependencies / linked tasks

    @ViewBuilder
    private var dependenciesSection: some View {
        let waiting  = task.dependencies.filter { $0.kind == .waitingOn }
        let blocking = task.dependencies.filter { $0.kind == .blocking }
        let linked   = task.linkedTaskIds

        if !waiting.isEmpty || !blocking.isEmpty || !linked.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("DEPENDÊNCIAS")
                        .font(Editorial.sans(10.5, .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Editorial.inkMute)
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 10) {
                    dependencyGroup(
                        title: "Aguardando",
                        icon: "hourglass",
                        tint: .orange,
                        ids: waiting.map(\.otherTaskId))
                    dependencyGroup(
                        title: "Bloqueando",
                        icon: "exclamationmark.octagon",
                        tint: .red,
                        ids: blocking.map(\.otherTaskId))
                    dependencyGroup(
                        title: "Relacionadas",
                        icon: "link",
                        tint: .blue,
                        ids: linked)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.05)))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08),
                                      lineWidth: 0.5))
            }
        }
    }

    @ViewBuilder
    private func dependencyGroup(title: String,
                                 icon: String,
                                 tint: Color,
                                 ids: [String]) -> some View {
        if !ids.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(ids.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                ForEach(ids, id: \.self) { id in
                    dependencyRow(id: id, tint: tint)
                }
            }
        }
    }

    @ViewBuilder
    private func dependencyRow(id: String, tint: Color) -> some View {
        let resolved = appState.depTaskCache[id]
        Button {
            guard let t = resolved else { return }
            appState.detailTaskOrigin = .zero
            withAnimation(.spring(duration: 0.45, bounce: 0.35)) {
                if appState.detailTask != nil {
                    appState.pushDetailSubtask(t)
                } else {
                    appState.detailTask = t
                }
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(statusHex: resolved?.statusDisplayHex ?? "#87909E"))
                    .frame(width: 7, height: 7)
                Text(resolved?.title ?? "Tarefa \(id.prefix(8))…")
                    .font(.caption)
                    .foregroundStyle(resolved == nil ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let st = resolved?.status, !st.isEmpty {
                    Text(st.uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                Spacer(minLength: 0)
                if resolved != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(resolved == nil)
    }

    // MARK: - Reminders (Apollo-native, local)

    private func reminderLabel(_ d: Date) -> String {
        let f = Calendar.current.isDateInToday(d)
            ? SharedDateFormatters.reminderTodayPTBR
            : (Calendar.current.isDateInTomorrow(d)
               ? SharedDateFormatters.reminderTomorrowPTBR
               : SharedDateFormatters.reminderFullPTBR)
        return f.string(from: d)
    }

    @ViewBuilder
    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        remindersCollapsed.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        collapseChevron(remindersCollapsed)
                        Text("LEMBRETES")
                            .font(Editorial.sans(10.5, .semibold))
                            .tracking(1.2)
                            .foregroundStyle(Editorial.inkMute)
                        if !reminders.isEmpty {
                            Text("\(reminders.count)")
                                .font(Editorial.sans(10.5).monospacedDigit())
                                .foregroundStyle(Editorial.inkMute)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()

                Spacer(minLength: 0)

                if !remindersCollapsed {
                    Button {
                        newReminderDate = Date().addingTimeInterval(3600)
                        newReminderNote = ""
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showReminderComposer.toggle()
                        }
                    } label: {
                        Image(systemName: showReminderComposer
                              ? "xmark" : "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Editorial.inkMute)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Editorial.ruleSoft))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help(showReminderComposer ? "Cancelar" : "Adicionar lembrete")
                }
            }

            if !remindersCollapsed {

            if reminders.isEmpty && !showReminderComposer {
                Text("Sem lembretes — toque em + para criar um aviso local.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !reminders.isEmpty {
                VStack(spacing: 0) {
                    ForEach(reminders) { r in
                        HStack(spacing: 8) {
                            Image(systemName: "bell.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Editorial.accent.opacity(0.8))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(reminderLabel(r.fireAt))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                if let note = r.note, !note.isEmpty {
                                    Text(note)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Button {
                                TaskReminders.remove(id: r.id)
                                reminders = TaskReminders.forTask(task.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 22, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .help("Remover lembrete")
                        }
                        .padding(.vertical, 5)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.05)))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08),
                                      lineWidth: 0.5))
            }

            if showReminderComposer {
                VStack(alignment: .leading, spacing: 8) {
                    DatePicker("Quando",
                               selection: $newReminderDate,
                               in: Date()...,
                               displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.compact)
                        .font(.caption)

                    TextField("Nota (opcional)", text: $newReminderNote)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.06)))

                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button("Cancelar") {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showReminderComposer = false
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .focusEffectDisabled()

                        Button {
                            guard newReminderDate > Date() else { return }
                            TaskReminders.add(taskId: task.id,
                                              title:  task.title,
                                              fireAt: newReminderDate,
                                              note:   newReminderNote)
                            reminders = TaskReminders.forTask(task.id)
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showReminderComposer = false
                            }
                        } label: {
                            Text("Salvar")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Editorial.accent))
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .disabled(newReminderDate <= Date())
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.05)))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08),
                                      lineWidth: 0.5))
            }

            } // end if !remindersCollapsed
        }
    }

    // MARK: - Subtasks (ClickUp parent/child structure)

    /// Renders the children of the current task as a tight
    /// vertical stack (checkbox, title, status pill) followed
    /// by an inline composer for adding a new one. Subtasks
    /// support the same status / priority / dates as a regular
    /// task, but inline we keep the row compact — clicking a
    /// subtask opens its full detail popup the same way a row
    /// in the main list does.
    @ViewBuilder
    private var subtasksSection: some View {
        // Use the snapshot supplied by the parent (kept in
        // `visibleSubtasks`) rather than reading
        // `appState.subtasks(of:)` here directly — the prop
        // is what feeds Equatable, so reading from it
        // guarantees the body re-renders with fresh data
        // when a child task changes.
        let subs = visibleSubtasks

        // Section divider above + label, matching the comments
        // section's visual rhythm.
        //
        // LazyVStack (not VStack) so the SubtaskRow children
        // only mount as the parent ScrollView scrolls them
        // into view. Tasks with 8+ subtasks were eagerly
        // mounting every row's hover modifier + status pill +
        // strikethrough on popup open — adds up because each
        // SubtaskRow is itself ~200 lines of SwiftUI chrome.
        LazyVStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(.separator.opacity(0.4))
                .frame(height: 0.5)
                .padding(.horizontal, -12)

            HStack(spacing: 6) {
                Text("SUBTAREFAS")
                    .font(Editorial.sans(10.5, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Editorial.inkMute)
                if !subs.isEmpty {
                    let done = subs.filter(\.isCompleted).count
                    Text("\(done)/\(subs.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if !subtaskComposerOpen {
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                            subtaskComposerOpen = true
                        }
                        // Scroll the parent ScrollView so the
                        // newly-opened composer is visible.
                        // Wrapped in a slight delay so the
                        // composer has a frame to scroll TO
                        // before the call fires.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            subtaskFieldFocused = true
                            withAnimation(.easeInOut(duration: 0.30)) {
                                scrollProxy?.scrollTo("subtaskComposer", anchor: .bottom)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("Adicionar")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Editorial.accent)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }

            // Existing subtask rows. Each row owns its own
            // hover/completing state so the hover-to-DONE pill
            // animation is per-row (not shared) — same model
            // as the parent task list.
            ForEach(subs) { sub in
                SubtaskRow(task: sub, appState: appState)
                    .equatable()
            }

            // Inline composer. Tagged with `.id` so
            // ScrollViewReader can target it when the user
            // taps "Adicionar".
            if subtaskComposerOpen {
                subtaskComposer
                    .id("subtaskComposer")
            }
        }
    }

    // (SubtaskRow is implemented as a private struct at the
    //  end of this file so it can carry its own per-row
    //  @State for hover/completing — same architecture the
    //  parent task list uses for its hover-to-DONE pill.)

    /// Inline "new subtask" composer. Submits on Enter, clears
    /// on blur / on a successful save. Same visual chrome as the
    /// description text editor so the form feels native.
    private var subtaskComposer: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .font(.callout)
                .foregroundStyle(Editorial.accent)

            TextField("Nova subtarefa…", text: $newSubtaskTitle)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .focused($subtaskFieldFocused)
                .onSubmit { commitSubtask() }

            if !newSubtaskTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Adicionar") { commitSubtask() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Editorial.accent, in: Capsule())
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
            }

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                    subtaskComposerOpen = false
                }
                newSubtaskTitle = ""
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Editorial.accent.opacity(0.35),
                              style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private func commitSubtask() {
        let trimmed = newSubtaskTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let parent = task
        newSubtaskTitle = ""
        Task {
            await appState.createSubtask(parent: parent, title: trimmed)
        }
        // Keep the composer open so the user can rapid-fire
        // multiple subtasks without re-clicking "Adicionar".
        subtaskFieldFocused = true
    }

    // MARK: - Layout helper

    @ViewBuilder
    private func detailRow<Content: View>(
        icon: String, label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        // `.center` (not `.firstTextBaseline`) — content that lives
        // inside a pill / button (status pill, tag pill, date
        // capsule) has padding-driven extra height; aligning by
        // baseline pinned the label to the very bottom of the row,
        // visually clipping its top edge against the row above.
        // Centring instead keeps the label vertically balanced
        // against any kind of content cell.
        // Editorial KEY · VALUE row: a small-caps folio label
        // in a fixed leading column, the value beside it. No
        // icon tint noise — the label IS the structure.
        HStack(alignment: .center, spacing: 14) {
            Text(label.uppercased())
                .font(Editorial.sans(10.5, .semibold))
                .tracking(1.2)
                .foregroundStyle(Editorial.inkMute)
                .frame(width: 104, alignment: .leading)

            content()
            Spacer(minLength: 0)
        }
    }

    private func assigneeChip(_ a: CUTask.Assignee) -> some View {
        let color = a.color.flatMap { Color(hex: $0) } ?? .blue
        return ZStack {
            Circle().fill(color)
            if let pic = a.profilePicture, let url = URL(string: pic) {
                // CachedAvatar (NSCache-backed, in-flight
                // dedup) instead of plain AsyncImage — same
                // reasoning as `TaskCommentsSection.avatarBubble`.
                CachedAvatar(url: url)
                    .clipShape(Circle())
            } else {
                Text(a.initials ?? String(a.username.prefix(2)).uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 18, height: 18)
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: LISTAS picker (multi-list)
    // ────────────────────────────────────────────────────────────────

    /// Filtered list of pickable lists. Already-membered lists rise
    /// to the top so tapping the same row toggles add ↔ remove —
    /// same pattern as `filteredAssigneeCandidates`.
    private var filteredListCandidates: [CUList] {
        let q = listsQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let memberIds = Set(task.allListMemberships.map(\.id))
        let pool = appState.availableLists
        let filtered = q.isEmpty
            ? pool
            : pool.filter { $0.name.lowercased().contains(q) }
        return filtered.sorted { lhs, rhs in
            let l = memberIds.contains(lhs.id) ? 0 : 1
            let r = memberIds.contains(rhs.id) ? 0 : 1
            if l != r { return l < r }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Contents of the LISTAS kvCell — chips for current
    /// memberships + an "Adicionar/Editar" trigger that reveals
    /// the inline picker. Wired to AppState.updateTaskLists when
    /// the user toggles a row.
    private var listsCellContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            let memberships = task.allListMemberships
            HStack(spacing: 6) {
                if !memberships.isEmpty {
                    listChip(memberships[0], isHome: true)
                    ForEach(memberships.dropFirst(), id: \.id) { loc in
                        listChip(loc, isHome: false)
                    }
                } else {
                    Text("—").font(Editorial.sans(12))
                        .foregroundStyle(Editorial.inkMute)
                }
                if !listsSearchOpen {
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                            listsSearchOpen = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            listsSearchFocused = true
                        }
                    } label: {
                        Text(memberships.isEmpty ? "Adicionar" : "Editar")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
            if listsSearchOpen {
                listsSearchBar
            }
        }
    }

    /// One LISTAS chip. The HOME list (the task's `listId`) wears
    /// a `★` so the user knows that one can't be removed via this
    /// picker — only via a true "move" operation. Other lists are
    /// removable on tap from the dropdown.
    private func listChip(_ loc: CUTask.TaskLocation, isHome: Bool) -> some View {
        HStack(spacing: 4) {
            if isHome {
                Image(systemName: "star.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Editorial.accent)
            } else {
                Circle()
                    .fill(Editorial.inkFaint)
                    .frame(width: 5, height: 5)
            }
            Text(loc.name)
                .font(Editorial.sans(11, .medium))
                .foregroundStyle(isHome ? Editorial.ink : Editorial.inkSoft)
                .lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isHome ? Editorial.accent.opacity(0.08) : Editorial.ink.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(isHome ? Editorial.accent.opacity(0.30) : Editorial.rule.opacity(0.6),
                              lineWidth: 1)
        )
    }

    /// Inline search bar + suggestions list. Mirrors
    /// `assigneeSearchBar`'s chrome so the two pickers feel like
    /// one family.
    @ViewBuilder
    private var listsSearchBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("Buscar lista…", text: $listsQuery)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .focused($listsSearchFocused)
                if !listsQuery.isEmpty {
                    Button {
                        listsQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        listsSearchOpen = false
                        listsQuery = ""
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Fechar busca")
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )

            if appState.availableLists.isEmpty {
                Text("Nenhuma lista disponível — fixe listas na sidebar primeiro.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4).padding(.vertical, 4)
            } else {
                let candidates = filteredListCandidates
                if candidates.isEmpty {
                    Text("Nenhuma lista encontrada")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4).padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(candidates.prefix(8), id: \.id) { l in
                            listsCandidateRow(l)
                            if l.id != candidates.prefix(8).last?.id {
                                Rectangle()
                                    .fill(.separator.opacity(0.3))
                                    .frame(height: 0.5)
                            }
                        }
                    }
                    .background(Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                    )
                }
            }
        }
    }

    /// One row in the lists picker dropdown — tapping toggles the
    /// list's membership on the task. The HOME list is shown but
    /// not togglable (you'd need to MOVE the task to swap homes).
    private func listsCandidateRow(_ l: CUList) -> some View {
        let isMember = task.allListMemberships.contains(where: { $0.id == l.id })
        let isHome   = (l.id == task.listId)
        return Button {
            guard !isHome else { return }
            var ids = Set(task.allListMemberships.map(\.id))
            if isMember { ids.remove(l.id) } else { ids.insert(l.id) }
            Task { await appState.updateTaskLists(task, to: ids) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isMember
                      ? (isHome ? "star.fill" : "checkmark.circle.fill")
                      : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(
                        isHome ? AnyShapeStyle(Editorial.accent) :
                        isMember ? AnyShapeStyle(Color.blue) :
                                   AnyShapeStyle(HierarchicalShapeStyle.tertiary)
                    )
                Text(l.name)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isHome {
                    Text("home")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Editorial.inkMute)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(isHome ? "Lista atual da tarefa (use MOVER para mudar)" :
              isMember ? "Remover desta lista" : "Adicionar a esta lista")
    }

    private func tagPill(_ tag: CUTask.Tag) -> some View {
        // Editorial chip: the tag keeps its own ClickUp hue but
        // densified/desaturated (`editorialMuted`) so it sits
        // with the cream/ink system instead of the raw vivid web
        // colour — a faint wash + hairline, not a saturated fill.
        let c = Color(hex: tag.background).editorialMuted
        return Text(tag.name)
            .font(Editorial.sans(11, .medium))
            .foregroundStyle(c)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(c.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(c.opacity(0.30), lineWidth: 1)
            )
    }
}


// MARK: - Subtask row

/// The subtask checkbox glyph, rendered through the EXACT same
/// `NSImageView` + `SymbolConfiguration` path the parent task's
/// AppKit `checkboxIcon` uses (`TaskRowContentView`). SwiftUI's
/// `Image(systemName:)` draws SF Symbols larger than AppKit's
/// `pointSize:16.1` + `.scaleProportionallyUpOrDown`, so the
/// only way to get a pixel-identical size is to reuse the same
/// AppKit rendering — not approximate it.
struct AppKitCheckboxIcon: NSViewRepresentable {
    let symbolName: String
    let color: NSColor
    var pointSize: CGFloat = 16.1

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    func updateNSView(_ v: NSImageView, context: Context) {
        v.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: pointSize, weight: .regular)
        v.image = NSImage(systemSymbolName: symbolName,
                          accessibilityDescription: nil)
        v.contentTintColor = color
    }
}

/// Compact row that renders one subtask inside its parent's
/// detail popup. The done-button (left side) mirrors
/// `TaskRowView.checkboxButton` exactly — same hover-expands-
/// to-status-pill behaviour, same `doneActionByStatus`
/// lookup for the next status, same bouncy completion icon —
/// so completing a subtask feels identical to completing a
/// top-level task. Tapping the body of the row opens the
/// subtask's own detail popup, same path as
/// `TaskRowView`'s "open in popup" button.
// Internal (was `private`) so the AppKit task list can host
// the same SwiftUI row inside the inline subtask stack — the
// expanded parent in the main list reuses this view via
// `NSHostingView` so the inline subtasks have IDENTICAL
// functionality (checkbox hover, status pill, due date,
// click-to-open) to the popup version.
struct SubtaskRow: View, Equatable {
    let task: CUTask
    /// Plain reference, NOT `@EnvironmentObject` — see
    /// `TaskRowView.appState` for the rationale. The popup
    /// previously had ONE row per visible subtask each
    /// subscribing to AppState, so a single status change
    /// somewhere unrelated invalidated every visible
    /// subtask's body. Holding `let appState` cuts that
    /// cascade; the parent (`TaskDetailView`) re-evaluates
    /// on `task` changes via the `subs` ForEach and passes
    /// fresh values down.
    let appState: AppState
    /// Leading indent for the row CONTENT (checkbox/title/etc),
    /// applied INSIDE the row so the category-colour wash still
    /// extends to the leading edge. The dashboard's
    /// `SubtaskCellItem` passes the per-depth nesting indent
    /// here; the popup uses the default 0.
    var leadingIndent: CGFloat = 0

    static func == (lhs: SubtaskRow, rhs: SubtaskRow) -> Bool {
        lhs.task == rhs.task && lhs.leadingIndent == rhs.leadingIndent
    }

    @State private var completing: Bool = false
    @State private var hoveringCheckbox: Bool = false
    /// Cached resolution of the DONE-target colour for this
    /// row's current status. Without the cache, `doneColor`
    /// runs `appState.doneTargetByStatus[...]` (a dictionary
    /// lookup that triggers AppState read-tracking) AND a
    /// `Color(hex:)` allocation on every body render — and
    /// since `@EnvironmentObject` re-evaluates the body for
    /// every unrelated `@Published` change in AppState, that
    /// was happening many times per second per visible
    /// subtask. The cache is populated on appear and
    /// refreshed whenever `task.status` actually changes,
    /// matching the pattern used in `TaskRowView`.
    @State private var cachedDoneColor: Color = .blue

    // MARK: Swipe-to-commit state
    //
    // SwiftUI mirror of the AppKit `TaskRowCellItem` swipe
    // pipeline — same threshold-armed haptic on the way in,
    // same slide-out commit on release. Subtask popup rows are
    // narrower than the main list cards, so the threshold is
    // tighter (160 vs 220) to keep the gesture comfortable
    // inside the popup width.
    @State private var swipeOffset: CGFloat = 0
    /// Hysteresis flag for the threshold-cross haptic. -1, 0, +1
    /// for "armed left", "neutral", "armed right". Pulses fire
    /// on transitions, never repeat while held at a side.
    @State private var swipeArmedSide: Int = 0
    /// Locks the gesture into a horizontal swipe vs a vertical
    /// scroll on the first frame that exceeds 6pt of movement
    /// in either axis. Vertical drags stay non-destructive (the
    /// row doesn't translate) so the parent ScrollView keeps
    /// owning vertical pans.
    @State private var swipeAxis: SwipeAxis = .undecided
    @State private var isCommittingSwipe: Bool = false

    private enum SwipeAxis { case undecided, horizontal, vertical }
    private static let swipeThreshold: CGFloat = 160

    /// Status one step earlier in the workflow ordering. nil if
    /// this is already the first status. Powers the left-swipe
    /// "go back one step" path, mirroring the parent rows.
    private var previousStatus: CUStatus? {
        let statuses = appState.availableStatuses
        guard let idx = statuses.firstIndex(where: { $0.status == task.status }),
              idx > 0
        else { return nil }
        return statuses[idx - 1]
    }

    /// O(1) lookup against AppState's pre-resolved index. See
    /// `TaskRowView.doneTargetStatus` for full rationale.
    private var doneTargetStatus: CUStatus? {
        appState.doneTargetByStatus[task.status]
            ?? appState.doneTargetFallback
    }

    /// Resolve the DONE-target colour from the latest status
    /// → status mapping. Called only on appear / status
    /// change — see `cachedDoneColor`'s rationale.
    private func resolveDoneColor() -> Color {
        if let hex = doneTargetStatus?.displayHex {
            return Color(hex: hex)
        }
        return .blue
    }

    /// Icon for the resting / completed / completing states.
    /// Identical to `TaskRowView.checkIcon`.
    private var checkIcon: String {
        if task.isCompleted { return "checkmark.circle.fill" }
        if completing       { return "circle.dotted" }
        return "circle"
    }

    var body: some View {
        Button {
            // Two routes depending on the surrounding context:
            //
            //  • If a parent task popup is already on screen
            //    (`detailTask != nil`), PUSH the subtask onto
            //    the navigation stack. Each tap drills one
            //    level deeper; the back button pops one level
            //    at a time, retracing the user's path through
            //    nested subtasks (ClickUp supports unlimited
            //    depth).
            //
            //  • If no popup is open (the user clicked a
            //    subtask from an inline-expanded row in the
            //    main list), open it as a regular task popup
            //    in `detailTask`. There's no parent on screen
            //    to preserve.
            appState.detailTaskOrigin = .zero
            withAnimation(.spring(duration: 0.45, bounce: 0.35)) {
                if appState.detailTask != nil {
                    appState.pushDetailSubtask(task)
                } else {
                    appState.detailTask = task
                }
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                checkboxButton

                Text(task.title)
                    .font(Editorial.sans(13, .medium))
                    .strikethrough(task.isCompleted, color: Editorial.inkMute)
                    .foregroundStyle(task.isCompleted ? Editorial.inkSoft : Editorial.ink)
                    .lineLimit(1)

                Spacer(minLength: 12)

                // Status as just the colour dot — no word label.
                // Hidden while the hover DONE pill is showing so
                // the row isn't crowded.
                if !hoveringCheckbox || task.isCompleted {
                    Circle()
                        .fill(Color(statusHex: task.statusDisplayHex))
                        .frame(width: 7, height: 7)
                        .opacity(task.isCompleted ? 0.55 : 1)
                        .transition(.opacity)
                }

                if let due = task.dueDate {
                    Text(due, format: .dateTime.day().month(.abbreviated)
                        .locale(Locale(identifier: "pt_BR")))
                        .font(Editorial.sans(11.5))
                        .foregroundStyle(Editorial.inkSoft)
                        .monospacedDigit()
                        .frame(minWidth: 64, alignment: .trailing)
                }
            }
            .padding(.vertical, 12)
            // Content paddings sit INSIDE the background so the
            // 3% accent wash spans the full leading-to-trailing
            // edge of the row, while the actual content (checkbox,
            // title, date) keeps the nesting indent + a 14pt
            // right gutter to match the parent rows' inner inset.
            .padding(.leading, leadingIndent)
            .padding(.trailing, 14)
            // Subtask row background — flat (no per-category
            // accent wash). The colour-by-status cue lives in the
            // status dot/pill itself; the row stays paper-clean
            // for parity with parent rows (which had their tint
            // layer disabled earlier per the same request).
            .background(Color.clear)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        // Right-click → full task context menu. Same actions
        // (status, vencimento, prioridade, copiar/abrir,
        // duplicar/arquivar/excluir) the main list rows
        // expose, so the gesture transfers without the user
        // having to think about which surface they're on.
        .taskContextMenu(task: task, appState: appState)
        // Slide the row horizontally as the user drags + fade
        // out as the commit fires. `simultaneousGesture` keeps
        // the underlying Button tap working: short clicks (no
        // movement past `minimumDistance`) still drill into the
        // subtask popup; only true horizontal drags translate
        // the row.
        .offset(x: swipeOffset)
        .opacity(isCommittingSwipe ? 0 : 1)
        .simultaneousGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .local)
                .onChanged { handleSwipeChange($0) }
                .onEnded   { handleSwipeEnd($0) }
        )
        // Populate / refresh `cachedDoneColor` so per-render
        // body evals don't recompute the colour. Only fires
        // when the row first appears or when this task's
        // status actually transitions — both rare events.
        .onAppear { cachedDoneColor = resolveDoneColor() }
        .onChange(of: task.status) { _, _ in
            cachedDoneColor = resolveDoneColor()
        }
    }

    // MARK: - Swipe gesture

    /// Live drag handler. Locks the axis on the first frame
    /// past 6pt, applies the horizontal translation, and emits
    /// the threshold-crossing haptic at ±160pt.
    private func handleSwipeChange(_ value: DragGesture.Value) {
        let dx = value.translation.width
        let dy = value.translation.height
        if swipeAxis == .undecided {
            // Don't commit to an axis until the user has clearly
            // dragged in one. Without this guard a tap-with-jitter
            // would lock to whichever axis won the first pixel.
            guard max(abs(dx), abs(dy)) > 6 else { return }
            swipeAxis = abs(dx) > abs(dy) ? .horizontal : .vertical
        }
        guard swipeAxis == .horizontal else { return }
        swipeOffset = dx
        updateSwipeArmFeedback(offset: dx)
    }

    /// Threshold-crossing haptic. Mirror of TaskRowCellView's
    /// `updateSwipeArmFeedback`. Strong double-thunk into an
    /// armed zone, soft single tick on the way back to neutral.
    private func updateSwipeArmFeedback(offset: CGFloat) {
        let side: Int
        if  offset >  Self.swipeThreshold, doneTargetStatus != nil { side =  1 }
        else if offset < -Self.swipeThreshold, previousStatus  != nil { side = -1 }
        else { side = 0 }
        guard side != swipeArmedSide else { return }
        if side != 0 { Haptics.taskAction() }
        else         { Haptics.toggle() }
        swipeArmedSide = side
    }

    /// Release handler. Commits if past the threshold (with a
    /// resolved target), otherwise springs back to 0.
    private func handleSwipeEnd(_ value: DragGesture.Value) {
        defer {
            swipeArmedSide = 0
            swipeAxis      = .undecided
        }
        guard swipeAxis == .horizontal else { return }
        let dx = value.translation.width
        if dx > Self.swipeThreshold, let target = doneTargetStatus {
            commitSwipe(direction: 1, target: target)
        } else if dx < -Self.swipeThreshold, let prev = previousStatus {
            commitSwipe(direction: -1, target: prev)
        } else {
            withAnimation(.spring(duration: 0.45, bounce: 0.45)) {
                swipeOffset = 0
            }
        }
    }

    /// Slide the row off-screen, then apply the status mutation.
    /// Same 850ms post-release haptic timing as the parent rows
    /// — the pulse lands long after the row has flown away, as
    /// a deliberate confirmation rather than a click echo.
    private func commitSwipe(direction: CGFloat, target: CUStatus) {
        Haptics.taskAction(after: 0.85)
        isCommittingSwipe = true
        withAnimation(.easeIn(duration: 0.18)) {
            swipeOffset = direction * 600
        }
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            await appState.updateTaskStatus(task, to: target)
        }
    }

    // MARK: - Hover-to-COMPLETE checkbox (clone of TaskRowView)

    /// Default state: small grey circle. On hover (when not
    /// completed), expands rightward into a pill labelled with
    /// the `doneTargetStatus`, painted in that status's colour
    /// over an ultraThinMaterial capsule with a bright top
    /// bevel and stacked drop shadows. Click flips the status
    /// to the target via `appState.updateTaskStatus`.
    ///
    /// Mirrors `TaskRowView.checkboxButton` 1:1 so a subtask's
    /// done UX is indistinguishable from the parent's.
    private var checkboxButton: some View {
        let isHover  = hoveringCheckbox && !task.isCompleted && !completing
        let pillLabel = (doneTargetStatus?.status ?? "DONE").uppercased()
        // The pill is coloured by the STATUS it commits to (the
        // done target), matching the parent task's DonePillView.
        let pillColor = cachedDoneColor

        return Button {
            guard !task.isCompleted, !completing else { return }
            guard let target = doneTargetStatus else { return }
            completing = true
            Task {
                await appState.updateTaskStatus(task, to: target)
                completing = false
            }
        } label: {
            Group {
                if isHover {
                    // Identical to the parent task's AppKit
                    // `DonePillView`: flat paper chip, cinnabar
                    // accent label, 1px hairline rule, 4pt
                    // near-rectangular corners — no material,
                    // gradient or shadow.
                    Text(pillLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(pillColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Editorial.page)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Editorial.rule, lineWidth: 1)
                        )
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.85, anchor: .leading)),
                            removal:   .opacity.combined(with: .scale(scale: 0.85, anchor: .leading))
                        ))
                } else {
                    // Same glyph metrics + colours as the parent
                    // task's AppKit checkbox: 16.1pt regular,
                    // Render through the SAME NSImageView +
                    // SymbolConfiguration the parent task uses, so
                    // the glyph is pixel-identical in size (SwiftUI
                    // `Image(systemName:)` — resizable or not —
                    // draws the symbol larger than AppKit's
                    // `pointSize:16.1` + `.scaleProportionally
                    // UpOrDown`, which is why it never matched).
                    // 15% smaller than the parent task checkbox
                    // (16.1 → 13.685), same AppKit render path.
                    AppKitCheckboxIcon(
                        symbolName: checkIcon,
                        color: task.isCompleted
                            ? NSColor(Editorial.statusColor("complete"))
                            : NSColor(Editorial.inkFaint),
                        pointSize: 13.685
                    )
                    .frame(width: 13.685, height: 13.685)
                    .transition(.opacity)
                }
            }
            .fixedSize(horizontal: true, vertical: true)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(task.isCompleted || completing || doneTargetStatus == nil)
        .scrollAwareOnHover { hover in
            // Mirror the parent task row's DONE-icon hover feel:
            // a strong double-thunk on entry announces an
            // actionable target. `scrollAwareOnHover` already
            // gates on scroll state and `.onHover` only fires on
            // transitions, so no debounce is needed here.
            // Skipped when the row is already completed / in
            // flight, since clicks are disabled in those states.
            if hover, !task.isCompleted, !completing,
               doneTargetStatus != nil {
                Haptics.taskAction()
            }
            withAnimation(.spring(duration: 0.28, bounce: 0.20)) {
                hoveringCheckbox = hover
            }
        }
    }
}

// MARK: - Attachment chip

/// Compact pill for one file attachment. Mirrors the
/// rounded-rect chip style used by ClickUp's web UI: a
/// coloured icon plate on the leading edge, filename + size
/// next to it, and a trailing arrow that visually telegraphs
/// "this opens externally". Hovering brightens the chip's
/// border and lifts it a hair; clicking opens the file URL
/// in the user's default browser.
private struct AttachmentChip: View, Equatable {
    let attachment: CUTask.Attachment
    /// Parent task's ClickUp URL (e.g.
    /// `https://app.clickup.com/t/86ahdjh3b`). Used as the
    /// destination of the "💬 N" annotation-count badge —
    /// clicking it opens the task in ClickUp's web client where
    /// the proofing/video annotations ARE visible (Apollo can't
    /// fetch the annotation bodies because they require a JWT
    /// session cookie, but at least the user has 1 click to
    /// reach them). Optional because some call paths (e.g.
    /// description-derived attachments outside a real task
    /// context) don't carry a task URL.
    var taskURL: String? = nil

    // Context for the "REVIEW" button (opens the Apollo Review app). Optional so
    // call paths without a task context still compile.
    var taskId: String? = nil
    var listId: String? = nil
    var actorId: Int? = nil
    var actorName: String = "Revisor"

    static func == (lhs: AttachmentChip, rhs: AttachmentChip) -> Bool {
        lhs.attachment == rhs.attachment && lhs.taskURL == rhs.taskURL
            && lhs.taskId == rhs.taskId && lhs.actorId == rhs.actorId
    }

    @State private var isHovered: Bool = false

    /// Count of unresolved annotation comments on this
    /// attachment, or `nil` when there are none / the field
    /// wasn't returned by the API. Computed once because the
    /// chip body references it three times.
    private var unresolvedAnnotations: Int? {
        guard let total = attachment.totalComments, total > 0 else { return nil }
        let resolved = attachment.resolvedComments ?? 0
        let unresolved = max(0, total - resolved)
        return unresolved > 0 ? unresolved : nil
    }

    /// Builds the URL that opens the attachment's proofing /
    /// annotation viewer directly — the video player with the
    /// commented timestamps + threaded annotations. Format is
    /// the raw attachment CDN URL with `?view=open` appended;
    /// ClickUp's web app recognises that query and renders the
    /// proofing UI instead of just streaming the file. Confirmed
    /// by inspecting what the address bar shows once the
    /// proofing pane is open.
    private func proofingDeepLink() -> URL? {
        guard var comps = URLComponents(string: attachment.url) else { return nil }
        var items = comps.queryItems ?? []
        // Don't duplicate `view=open` if the URL the API gave us
        // already had it.
        if !items.contains(where: { $0.name == "view" }) {
            items.append(URLQueryItem(name: "view", value: "open"))
        }
        comps.queryItems = items
        return comps.url
    }

    private var accent: Color { Color(hex: attachment.accentHex) }

    var body: some View {
        Button {
            guard let url = URL(string: attachment.url) else { return }
            NSWorkspace.shared.open(url)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                // Editorial: a small uppercase file-type tag in
                // the type colour over a faint tint — no glossy
                // gradient plate.
                Text(attachment.ext.isEmpty ? "FILE"
                     : attachment.ext.uppercased())
                    .font(Editorial.sans(9, .semibold))
                    .tracking(0.4)
                    .foregroundStyle(accent)
                    .frame(width: 38, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(accent.opacity(0.12)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.title)
                        .font(Editorial.serif(13))
                        .foregroundStyle(Editorial.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 6) {
                        if let size = attachment.sizeString {
                            Text(size)
                                .font(Editorial.sans(10.5))
                                .foregroundStyle(Editorial.inkMute)
                                .monospacedDigit()
                        }
                        // Annotation-comment badge. ClickUp keeps
                        // per-attachment proofing comments in a
                        // separate internal store we can't reach,
                        // but the COUNT comes back on the
                        // attachment payload — surface it so the
                        // user knows the annotations exist and
                        // can jump to them.
                        if let unresolved = unresolvedAnnotations {
                            Text("·")
                                .font(Editorial.sans(9))
                                .foregroundStyle(Editorial.inkFaint)
                            HStack(spacing: 3) {
                                Image(systemName: "bubble.left.and.bubble.right.fill")
                                    .font(.system(size: 8, weight: .semibold))
                                Text("\(unresolved)")
                                    .font(Editorial.sans(9, .bold))
                                    .monospacedDigit()
                            }
                            .foregroundStyle(Editorial.accent)
                            .help("\(unresolved) " +
                                  (unresolved == 1 ? "comentário de revisão"
                                                   : "comentários de revisão") +
                                  " neste anexo. Abra no ClickUp pra ver.")
                        }
                    }
                }

                Spacer(minLength: 0)

                // Apollo Review — primary affordance for reviewable media
                // (video/image/PDF). Opens the native review app via the
                // apolloreview:// scheme; bypasses the chip's download path.
                if ReviewLink.isReviewable(attachment.ext), let taskId, let actorId {
                    // Shared component → carries the "unseen update" badge and
                    // registers the review with the watcher on open.
                    ReviewButton(attachment: attachment, taskId: taskId, listId: listId,
                                 uploaderId: attachment.uploaderId, actorId: actorId,
                                 actorName: actorName)
                }

                // When the attachment has unresolved annotations
                // AND we know the parent task's ClickUp URL, show
                // a dedicated "Abrir no ClickUp" button as the
                // primary trailing affordance. Click bypasses the
                // outer chip's file-download path and routes
                // straight to the web UI where annotations are
                // visible.
                if unresolvedAnnotations != nil,
                   let proofingURL = proofingDeepLink() {
                    Button {
                        NSWorkspace.shared.open(proofingURL)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "bubble.left.fill")
                                .font(.system(size: 8, weight: .semibold))
                            Text("Ver no ClickUp")
                                .font(Editorial.sans(9.5, .semibold))
                        }
                        .foregroundStyle(Editorial.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Editorial.page))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Editorial.accentSoft, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("Abrir a interface de revisão deste anexo no ClickUp web (timestamps + anotações de vídeo).")
                }

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHovered ? Editorial.accent : Editorial.inkFaint)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 10)
            .background(isHovered ? Editorial.card : Color.clear)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Editorial.ruleSoft).frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(attachment.url)        // tooltip = full URL
        .scrollAwareOnHover { hovering in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                isHovered = hovering
            }
        }
    }
}
