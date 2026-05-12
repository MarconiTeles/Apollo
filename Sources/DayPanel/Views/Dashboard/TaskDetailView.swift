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

    /// Equatable conformance — `.equatable()` at the call site
    /// short-circuits re-renders when the surrounding sheet
    /// re-evaluates but the inputs that affect this view's
    /// output didn't change. AppState is a stable singleton,
    /// the description-knob params are stable for a given
    /// container, so comparing only `task` is enough.
    static func == (lhs: TaskDetailView, rhs: TaskDetailView) -> Bool {
        lhs.task == rhs.task
            && lhs.includesComments == rhs.includesComments
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
            // Removed the leading `Rectangle().fill(.separator)`
            // hairline that used to sit above the status row.
            // It belonged to the older popup design where the
            // header was a heavy band and the line acted as a
            // soft transition into the metadata grid. With the
            // current material-only-on-header look the line
            // visually competes with the header/body boundary
            // — the user explicitly asked for it gone.
            statusRow
            assigneesRow
            datesRow
            priorityRow
            tagsRow

            descriptionField

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
            attachmentsSection

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
                    .foregroundStyle(isAssigned ? Color.green : Color.accentColor)
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
        Button { show.wrappedValue.toggle() } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
                .padding(.horizontal, 6).padding(.vertical, 2)
                // Was `.regularMaterial`. Inside the popup's
                // ScrollView every backdrop-filter material
                // re-samples its blur every frame as the pill
                // moves on screen — multiplied across 5 detail
                // rows (start date, due date, status, priority,
                // tags), this was the dominant per-frame GPU
                // cost during scroll. Solid translucent fill
                // matches the AppKit row-cell pattern and
                // costs nothing to scroll.
                .background(Color.primary.opacity(0.06),
                            in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .popover(isPresented: show, arrowEdge: .bottom) { content() }
    }

    // MARK: - Status (same pill as compact row, but lives in the body)

    private var statusRow: some View {
        let color = Color(hex: task.statusDisplayHex)

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
                    renderAttachmentCards: true
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
                Image(systemName: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Anexos")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
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
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(task.attachments) { att in
                    AttachmentChip(attachment: att)
                        .equatable()
                }
            }
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
                Image(systemName: "list.bullet.indent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Subtarefas")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
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
                        .foregroundStyle(Color.accentColor)
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
                .foregroundStyle(Color.accentColor)

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
                    .background(Color.accentColor, in: Capsule())
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
                .strokeBorder(Color.accentColor.opacity(0.35),
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
        HStack(alignment: .center, spacing: 10) {
            Label {
                Text(label).font(.caption).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: icon).font(.caption2).foregroundStyle(.tertiary).frame(width: 14)
            }
            .labelStyle(.titleAndIcon)
            .frame(width: 110, alignment: .leading)

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

    private func tagPill(_ tag: CUTask.Tag) -> some View {
        // Use the macOS system accent colour instead of the
        // per-tag colour returned by ClickUp — matches the rest of
        // Apollo's accent-driven UI (TODOS pill, primary CTAs,
        // bell badge highlight, etc.) so tags read as "interactive
        // chips" instead of competing with the row's status hue.
        Text(tag.name)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.40), lineWidth: 0.5))
    }
}


// MARK: - Subtask row

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

    static func == (lhs: SubtaskRow, rhs: SubtaskRow) -> Bool {
        lhs.task == rhs.task
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
                    .font(.subheadline)
                    .strikethrough(task.isCompleted, color: .secondary)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                // Status pill — uppercase chip in the status's
                // colour. Hidden while the hover-pill (DONE
                // target) is showing, so the row doesn't get
                // visually crowded with two pills at once.
                if !hoveringCheckbox || task.isCompleted {
                    Text(task.status.uppercased())
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(0.4)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color(hex: task.statusDisplayHex))
                        )
                        .transition(.opacity)
                }

                if let due = task.dueDate {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(due, format: .dateTime.day().month(.abbreviated)
                        .locale(Locale(identifier: "pt_BR")))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
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
        let pillColor = cachedDoneColor
        let pillLabel = (doneTargetStatus?.status ?? "DONE").uppercased()

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
                    Text(pillLabel)
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(pillColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .overlay(Capsule().strokeBorder(pillColor, lineWidth: 1.5))
                        .overlay(
                            Capsule().strokeBorder(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.55),
                                        .white.opacity(0.18),
                                        .white.opacity(0.05),
                                    ],
                                    startPoint: .top,
                                    endPoint:   .bottom
                                ),
                                lineWidth: 0.6
                            )
                            .allowsHitTesting(false)
                        )
                        .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 2)
                        .shadow(color: .black.opacity(0.05), radius: 1, x: 0, y: 1)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.7, anchor: .leading)),
                            removal:   .opacity.combined(with: .scale(scale: 0.7, anchor: .leading))
                        ))
                } else {
                    Image(systemName: checkIcon)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(task.isCompleted ? pillColor : Color.secondary)
                        .symbolEffect(.bounce, value: task.isCompleted)
                        .frame(width: 14, height: 14)
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

    static func == (lhs: AttachmentChip, rhs: AttachmentChip) -> Bool {
        lhs.attachment == rhs.attachment
    }

    @State private var isHovered: Bool = false

    private var accent: Color { Color(hex: attachment.accentHex) }

    var body: some View {
        Button {
            guard let url = URL(string: attachment.url) else { return }
            NSWorkspace.shared.open(url)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                // Icon plate — coloured rounded square with the
                // file's typed glyph, white over an accent fill.
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    accent,
                                    accent.opacity(0.78)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 28, height: 28)
                        // Removed the accent-tinted shadow:
                        // each AttachmentChip in the scrollable
                        // anexos list was paying a per-frame
                        // shadow rasterisation. The icon plate
                        // already has its own coloured fill +
                        // gradient, which gives enough visual
                        // weight without the shadow.
                    Image(systemName: attachment.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 6) {
                        if !attachment.ext.isEmpty {
                            Text(attachment.ext.uppercased())
                                .font(.system(size: 9, weight: .heavy))
                                .tracking(0.5)
                                .foregroundStyle(accent)
                        }
                        if let size = attachment.sizeString {
                            if !attachment.ext.isEmpty {
                                Text("·")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(size)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right.square")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isHovered ? accent : Color.secondary.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent.opacity(isHovered ? 0.12 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(accent.opacity(isHovered ? 0.55 : 0.22),
                                  lineWidth: 0.7)
            )
            .scaleEffect(isHovered ? 1.012 : 1)
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
