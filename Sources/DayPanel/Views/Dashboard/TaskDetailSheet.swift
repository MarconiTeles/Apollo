import SwiftUI

/// Floating popup version of `TaskDetailView` — opens from the small
/// "open in popup" icon on a compact task row. Optimised for focused
/// editing: takes ~80% of the host window and splits into two columns
/// so the description gets real estate AND comments live persistently
/// on the right (chat-style) instead of stacking below the metadata.
///
/// Layout:
///
///     ┌──────────────────────────────────────────────┐
///     │ Header: stripe | title \n list      [✕]      │
///     ├───────────────────────────┬──────────────────┤
///     │ Metadata (status/dates…)  │  Comentários     │
///     │ Descrição (large editor)  │  (chat scroll +  │
///     │                           │   compose box)   │
///     ├───────────────────────────┴──────────────────┤
///     │ Footer:  Abrir no ClickUp →    Esc = fechar  │
///     └──────────────────────────────────────────────┘
///
struct TaskDetailSheet: View, Equatable {
    /// AppState held as a plain reference, NOT `@EnvironmentObject`.
    /// Same reasoning as `TaskRowView.appState` — subscribing to
    /// `AppState.objectWillChange` made the popup re-render on
    /// every one of AppState's 41 `@Published` mutations
    /// (selectedDate, sync status, notification arrivals,
    /// attachmentHydration…), even though almost none of them
    /// affect the popup's content. With four nested views all
    /// individually subscribed (this sheet, `TaskDetailView`,
    /// `TaskCommentsSection`, `SubtaskRow`), one keystroke or
    /// hydration tick triggered four full re-renders — the user
    /// reported a "queda brutal de framerate" with the popup
    /// open and attachments flickering during scroll.
    ///
    /// Holding `appState` as a `let` cuts the subscription. The
    /// view's body only re-evaluates when:
    ///   • `task` changes — and ContentView, which holds the
    ///     `@EnvironmentObject`, computes the live task
    ///     (`appState.tasksById[t.id] ?? t`) on every render
    ///     and passes it down. So edits to status/title/dates
    ///     still propagate, just via the explicit prop instead
    ///     of an implicit subscription.
    ///   • internal `@State` changes (lockedSize, etc.).
    ///
    /// Reads of `appState.<property>` still see live values
    /// (reference access is uncached, just non-reactive). For
    /// the rare case a popup-resident value changes WITHOUT
    /// `task` itself changing (e.g. attachmentHydration during
    /// initial load), the affected child caches the value into
    /// `@State` on appear and refreshes via `.onChange(of:
    /// task.<field>)`.
    let appState: AppState
    @Environment(\.windowSize) private var windowSize
    let task: CUTask
    /// Snapshot of the subtask children visible inside the
    /// body. Supplied by `ContentView` so changes to any
    /// child propagate through Equatable — see the comment
    /// on `static func ==` for why this isn't computed
    /// inside the sheet itself.
    let visibleSubtasks: [CUTask]
    var onClose: () -> Void = {}

    init(task: CUTask,
         appState: AppState,
         visibleSubtasks: [CUTask] = [],
         onClose: @escaping () -> Void = {}) {
        self.task = task
        self.appState = appState
        self.visibleSubtasks = visibleSubtasks
        self.onClose = onClose
    }

    /// Equatable conformance — `.equatable()` at the call site
    /// short-circuits re-renders when ContentView re-runs but
    /// neither the live task nor its visible subtasks
    /// changed. The subtask list is read inside the body via
    /// `appState.subtasks(of:)`; without including it in the
    /// diff, edits to a child's status didn't bubble through
    /// (the popup's parent task was stable, so equatable said
    /// "unchanged" and the stale subtask snapshot stuck around
    /// until the popup was reopened).
    static func == (lhs: TaskDetailSheet, rhs: TaskDetailSheet) -> Bool {
        lhs.task == rhs.task
            && lhs.visibleSubtasks == rhs.visibleSubtasks
    }

    /// Frozen popup size, captured the first time the view
    /// appears for a given task. Once locked, every internal
    /// layout dimension (left-column width, description body
    /// height, etc.) reads from this value — so resizing the
    /// host window after the popup is open NEVER reflows the
    /// popup's contents. Reset to nil whenever the task
    /// identity changes so the next opening picks fresh
    /// dimensions appropriate to the (possibly new) window.
    @State private var lockedSize: CGSize? = nil

    /// Confirm before turning the task into a calendar event
    /// (the ClickUp task is removed afterwards).
    @State private var showConvertConfirm = false
    @State private var showStatusMenu = false

    /// Editorial layout: a single-column popup with the activity
    /// timeline and attachments behind tabs (matching the
    /// prototype's `DetailEditorial`) instead of a permanent
    /// right-hand comments rail.
    enum DetailTab: Hashable { case overview, subtasks, attachments, activity }
    @State private var detailTab: DetailTab = .overview

    /// Pull the live snapshot from AppState every render so edits to
    /// status / dates / priority repaint the header without dismissing.
    ///
    /// Note: with `let appState` (not `@EnvironmentObject`) the body
    /// no longer re-runs on every AppState mutation — but ContentView
    /// (which still holds `@EnvironmentObject`) re-renders and passes
    /// a fresh `task` value, so this lookup picks up edits via the
    /// `task` prop change rather than a sneaky live read.
    private var liveTask: CUTask {
        appState.tasksById[task.id] ?? task
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Editorial.popupRadius(4.5), style: .continuous)
    }

    private var headerShape: UnevenRoundedRectangle {
        let radius = Editorial.popupRadius(4.5)
        return UnevenRoundedRectangle(topLeadingRadius: radius,
                                      bottomLeadingRadius: 0,
                                      bottomTrailingRadius: 0,
                                      topTrailingRadius: radius,
                                      style: .continuous)
    }

    private let mastheadHeight: CGFloat = 68

    /// Compute a popup size from the host window. Used once on
    /// first appear; afterwards the cached `lockedSize` value
    /// is what every layout dimension reads. 80% of window
    /// width / height, clamped to readable bounds AND to a
    /// region that never overlaps the macOS title bar.
    private func computeSize(for window: CGSize) -> CGSize {
        let topReserved:  CGFloat = 64   // 52pt toolbar + 12pt breathing room
        let sideReserved: CGFloat = 16   // window-edge margin

        let safeMaxH = max(280, window.height - 2 * topReserved)
        let safeMaxW = max(520, window.width  - 2 * sideReserved)

        // Popup growth policy: fill 90% of the available window
        // (was 80%) and raise the absolute ceiling from 900 →
        // 1200pt. The previous 900pt cap was the source of the
        // "cortando em cima e embaixo" complaint on tasks with
        // a lot of content — long description + 14 anexos + 8
        // subtarefas couldn't fit even with scrolling, and the
        // ScrollView's hidden indicators meant users didn't
        // realize they could reveal anexos/subtarefas by
        // dragging.
        let preferredH = min(1200, max(560, window.height * 0.90))
        let preferredW = min(1200, max(720, window.width * 0.85))

        return CGSize(
            width:  min(preferredW, safeMaxW),
            height: min(preferredH, safeMaxH)
        )
    }

    /// Frozen size for layout reads. First read of a freshly-
    /// opened sheet returns the host-window-derived size; every
    /// subsequent read returns that same value, even if the host
    /// window resizes.
    private var popoverSize: CGSize {
        lockedSize ?? computeSize(for: windowSize)
    }

    /// Left column gets ~62% of the body width — wide enough for the
    /// description editor to feel spacious without crowding comments.
    private var leftColumnRatio: CGFloat { 0.62 }

    var body: some View {
        // EditorialDetailV2 — "task as a magazine spread":
        // masthead, then a 7fr/3fr grid (main column · marginalia).
        ZStack(alignment: .top) {
            Group {
                switch detailTab {
                case .overview:    overviewSpread
                case .subtasks:    subtasksTab
                case .attachments: attachmentsTab
                case .activity:    activityTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            masthead
                .frame(minHeight: mastheadHeight)
                .liquidGlass(in: headerShape,
                             tint: Editorial.ink,
                             tintOpacity: 0.01,
                             interactive: false)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Editorial.rule).frame(height: 1)
                }
                .zIndex(20)
        }
        .frame(width: popoverSize.width, height: popoverSize.height)
        .solidPopupSurface(in: shape)
        // Lock the size on first appear so subsequent host-
        // window resizes don't reflow the popup.
        //
        // No `.onChange(of: task.id)` reset needed: ContentView
        // applies `.id(t.id)` to this sheet, so a navigation
        // between tasks (e.g. parent → subtask) discards the
        // current view tree and creates a fresh one — every
        // @State (including this `lockedSize`) starts from
        // its default. That same identity reset is what fixes
        // the description-clipping bug that surfaced when the
        // sheet was reused across tasks.
        //
        // CRITICAL: only capture once we have a *real*
        // `windowSize`. The `\.windowSize` Environment value
        // defaults to `.zero` and propagates from ContentView's
        // GeometryReader on the first render pass. With the
        // `.id(t.id)` identity-recreation, `onAppear` can fire
        // *before* that env reaches us — and `computeSize(for:
        // .zero)` clamps to its safety floor (520×280),
        // locking the popup at that tiny size. The result is a
        // squashed header where `.fixedSize(vertical: true)`
        // crushes the title text into a sub-pixel slice while
        // the list-name row barely survives. The
        // `.onChange(of: windowSize)` watcher catches the env
        // value the moment it arrives and locks then, after
        // which `lockedSize` is set permanently and ignores
        // any future window resizes.
        .onAppear {
            if lockedSize == nil,
               windowSize.width > 0, windowSize.height > 0 {
                lockedSize = computeSize(for: windowSize)
            }
            // Attachment hydration is owned by `TaskDetailView`
            // itself now — it fires from THAT view's onAppear so
            // every surface (this popup, the inline expanded
            // pill in the task list, AI-chat snippets) gets
            // anexos consistently. Don't re-trigger here.
        }
        .onChange(of: windowSize) { _, new in
            if lockedSize == nil, new.width > 0, new.height > 0 {
                lockedSize = computeSize(for: new)
            }
        }
        .confirmationDialog(
            "Transformar em evento?",
            isPresented: $showConvertConfirm,
            titleVisibility: .visible
        ) {
            Button("Transformar", role: .destructive) {
                let t = liveTask
                Task {
                    if await appState.convertTaskToEvent(t) != nil {
                        onClose()
                    }
                }
            }
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text("Um evento será criado no calendário e a tarefa será excluída do ClickUp.")
        }
    }

    // MARK: - EditorialDetailV2 — masthead

    private func dayMonth(_ d: Date) -> String {
        SharedDateFormatters.shortDayMonthPTBR.string(from: d)
    }

    private var statusLabel: String { liveTask.status.capitalized }

    private var masthead: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            if !liveTask.isSubtask && !appState.detailNavigationTaskIds.isEmpty {
                HStack(spacing: 4) {
                    detailNavigationButton(.previous, systemName: "chevron.up",
                                           help: "Tarefa anterior")
                    detailNavigationButton(.next, systemName: "chevron.down",
                                           help: "Próxima tarefa")
                }
                .padding(.trailing, 2)
            }

            // Back (subtask navigation) — kept from the old header.
            if liveTask.isSubtask {
                let isOverlay = (appState.detailSubtaskOverlay?.id == liveTask.id)
                let parent: CUTask? = liveTask.parentId
                    .flatMap { appState.tasksById[$0] }
                if isOverlay || parent != nil {
                    Button {
                        if isOverlay {
                            withAnimation(.spring(duration: 0.45, bounce: 0.30)) {
                                appState.popDetailSubtask()
                            }
                        } else if let parent {
                            appState.detailTaskOrigin = .zero
                            withAnimation(.spring(duration: 0.45, bounce: 0.35)) {
                                appState.detailTask = parent
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Editorial.inkSoft)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("Voltar para a tarefa-mãe")
                }
            }

            Folio(liveTask.listName.isEmpty ? "Tarefa" : liveTask.listName)
            Text("Tarefa")
                .font(Editorial.serif(11).italic())
                .foregroundStyle(Editorial.inkMute)
            Circle().fill(Editorial.inkFaint).frame(width: 3, height: 3)
            let statusColor = Color(statusHex: liveTask.statusDisplayHex)
            Button { showStatusMenu.toggle() } label: {
                HStack(spacing: 6) {
                    Text(statusLabel.uppercased())
                        .font(Editorial.sans(10.5, .semibold))
                        .tracking(1.25)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7.5, weight: .bold))
                }
                .foregroundStyle(statusColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(appState.availableStatuses.isEmpty)
            .background {
                StatusPickerBubbleAnchor(
                    isPresented: $showStatusMenu,
                    statuses: appState.availableStatuses,
                    currentStatusName: liveTask.status
                ) { status in
                    Task { await appState.updateTaskStatus(liveTask, to: status) }
                    showStatusMenu = false
                }
            }

            Spacer(minLength: 12)

            mastheadTab(.overview,    "Visão geral", nil)
            mastheadTab(.subtasks,    "Subtarefas",
                        visibleSubtasks.isEmpty ? nil : visibleSubtasks.count)
            mastheadTab(.attachments, "Anexos",
                        liveTask.attachments.isEmpty ? nil : liveTask.attachments.count)
            mastheadTab(.activity,    "Atividade", nil)

            Rectangle().fill(Editorial.rule)
                .frame(width: 1, height: 14)
                .padding(.horizontal, 4)

            Button { showConvertConfirm = true } label: {
                Image(systemName: "arrow.2.squarepath")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Editorial.inkSoft)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Transformar em evento")

            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Editorial.inkSoft)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .keyboardShortcut(.cancelAction)
            .help("Fechar (Esc)")
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 14)
    }

    private func detailNavigationButton(
        _ direction: AppState.DetailNavigationDirection,
        systemName: String,
        help: String
    ) -> some View {
        let enabled = direction == .previous
            ? appState.canNavigateToPreviousDetailTask
            : appState.canNavigateToNextDetailTask
        return Button {
            appState.navigateDetailTask(direction)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 10.5, weight: .semibold))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .foregroundStyle(enabled ? Editorial.inkSoft : Editorial.inkFaint)
        .disabled(!enabled)
        .keyboardShortcut(direction == .previous ? .upArrow : .downArrow,
                          modifiers: .command)
        .help(help)
    }

    private func mastheadTab(_ t: DetailTab,
                             _ label: String,
                             _ count: Int?) -> some View {
        let active = detailTab == t
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { detailTab = t }
        } label: {
            HStack(spacing: 5) {
                Text(label)
                    .font(Editorial.sans(12.5, active ? .semibold : .regular))
                    .foregroundStyle(active ? Editorial.ink : Editorial.inkSoft)
                if let count {
                    Text("\(count)")
                        .font(Editorial.sans(11))
                        .foregroundStyle(Editorial.inkMute)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(active ? Editorial.ink : Color.clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    // MARK: - Overview — single column with an integrated
    // horizontal properties bar (no side marginalia). Mirrors
    // the prototype `detail.jsx` DetailEditorial.

    private var overviewSpread: some View {
        overviewMain
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Folio + serif headline + byline — shared by the
    /// overview and the Subtarefas tab.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Folio("↳ \(liveTask.listName.isEmpty ? "Tarefa" : liveTask.listName)")
                .padding(.bottom, 8)

            Text(liveTask.title)
                .textSelection(.enabled)
                .font(Editorial.serif(38))
                .foregroundStyle(Editorial.ink)
                .tracking(-1.2)
                .lineSpacing(0)
                .fixedSize(horizontal: false, vertical: true)
                .help(liveTask.title)

            HStack(alignment: .firstTextBaseline, spacing: 14) {
                if let who = liveTask.creator?.username
                    ?? liveTask.assignees.first?.username {
                    Caption("por \(who.split(separator: "@").first.map(String.init) ?? who)"
                            + (liveTask.dateCreated.map { " · \(dayMonth($0))" } ?? ""))
                }
                if !liveTask.listName.isEmpty {
                    Circle().fill(Editorial.inkFaint).frame(width: 3, height: 3)
                    Caption(liveTask.listName)
                }
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var overviewMain: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: mastheadHeight)
                titleBlock

                Spacer().frame(height: 24)
                Rectangle().fill(Editorial.rule).frame(height: 1)
                    .padding(.horizontal, -56)
                Spacer().frame(height: 22)

                // Body: the integrated (and fully interactive)
                // properties grid + description + checklists/
                // custom fields/dependencies/reminders/subtasks.
                // `propertiesAsGrid` renders the grid with its
                // real status/priority/date/tag/assignee editors
                // restored. Attachments + activity have own tabs.
                TaskDetailView(
                    task: liveTask,
                    appState: appState,
                    includesComments:    false,
                    showsAttachments:    false,
                    showsProperties:     true,
                    propertiesAsGrid:    true,
                    descriptionMaxHeight: .greatestFiniteMagnitude,
                    descriptionMinHeight: 120,
                    descriptionScrolls:   false,
                    visibleSubtasks:     visibleSubtasks
                )
                .equatable()
                .padding(.horizontal, -12)  // cancel TaskDetailView's own inset
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 56)
            .padding(.top, 44)
            .padding(.bottom, 32)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    // MARK: - Other tabs

    /// Subtarefas tab — ONLY the title block + the subtask
    /// list/composer. No properties bar, description, checklists,
    /// custom fields or reminders.
    private var subtasksTab: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: mastheadHeight)
                titleBlock

                Spacer().frame(height: 24)
                Rectangle().fill(Editorial.rule).frame(height: 1)
                    .padding(.horizontal, -56)
                Spacer().frame(height: 24)

                TaskDetailView(
                    task: liveTask,
                    appState: appState,
                    includesComments: false,
                    showsAttachments: false,
                    subtasksOnly:     true,
                    showsProperties:  false,
                    visibleSubtasks:  visibleSubtasks
                )
                .equatable()
                .padding(.horizontal, -12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 56)
            .padding(.top, 44)
            .padding(.bottom, 32)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private var attachmentsTab: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0) {
                Color.clear.frame(height: mastheadHeight)
                TaskDetailView(
                    task: liveTask,
                    appState: appState,
                    includesComments: false,
                    attachmentsOnly:  true,
                    visibleSubtasks:  visibleSubtasks
                )
                .equatable()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 56)
        .padding(.vertical, 32)
    }

    private var activityTab: some View {
        TaskCommentsSection(task: liveTask,
                            appState: appState,
                            composerAtBottom: true,
                            topContentInset: mastheadHeight + 8)
            .equatable()
            .padding(.horizontal, 56)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

}
