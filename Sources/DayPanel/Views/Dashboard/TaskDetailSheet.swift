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
        RoundedRectangle(cornerRadius: 24, style: .continuous)
    }

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
        VStack(spacing: 0) {
            // Header has NO own background — the popup-level
            // material below shows through as the translucent
            // title bar.
            header

            // Body + footer share a single solid surface that
            // hides the popup-level material in their region.
            // Header is the only area that lets the material
            // through, so the title bar reads as glass while
            // the rest of the popup is opaque.
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    metadataColumn
                    Divider().opacity(0.4)
                    commentsColumn
                }
                // 20pt inset between the top of the body and
                // its first row. The earlier 10pt boundary
                // padding (between the title bar and the
                // body) was removed per design — body now
                // sits flush with the title bar — but the
                // inside breathing room before the first row
                // grew 15 → 20pt.
                .padding(.top, 20)

                Divider().opacity(0.5)
                footer
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: popoverSize.width, height: popoverSize.height)
        // Material painted IN the popup shape — fills the
        // rounded corners cleanly without the 1-pixel gap that
        // appeared when the material was rectangular and got
        // clipped against the rounded outer shape (visible as
        // the unfilled-pixel line at the top-right corner).
        .background(.ultraThinMaterial, in: shape)
        .clipShape(shape)
        // Specular top-bevel + ambient shadow stack — same chrome
        // `popupGlass` had, minus the body-wide material.
        .overlay {
            shape.strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.90), location: 0.00),
                        .init(color: .white.opacity(0.45), location: 0.10),
                        .init(color: .white.opacity(0.18), location: 0.35),
                        .init(color: .white.opacity(0.08), location: 0.65),
                        .init(color: .white.opacity(0.18), location: 1.00),
                    ],
                    startPoint: .top,
                    endPoint:   .bottom
                ),
                lineWidth: 1.0
            )
            .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.30), radius: 32, x: 0, y: 18)
        .shadow(color: .black.opacity(0.14), radius: 8,  x: 0, y: 4)
        .shadow(color: .black.opacity(0.08), radius: 1,  x: 0, y: 1)
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
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            // Back button — present whenever there's a
            // place to go back to. Three routes:
            //
            //  • Stacked overlay (sub-subtask, depth >= 2):
            //    pop the top of `detailSubtaskStack` so the
            //    user retraces their path one level at a
            //    time. The parent subtask underneath is
            //    already rendered + keyed by `.id`, so it
            //    snaps back instantly.
            //
            //  • Top of overlay stack (depth 1, this is the
            //    only subtask in the stack): pop empties the
            //    stack and dismisses the overlay, revealing
            //    the root `detailTask` underneath.
            //
            //  • Standalone subtask (no overlay involved,
            //    user opened the subtask directly from the
            //    main list): navigate `detailTask` to the
            //    parent task so the popup re-zooms into the
            //    parent via the `.id(t.id)`-keyed swap.
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
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .background(.regularMaterial, in: Circle())
                            .liquidGlassEdge(Circle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("Voltar para a tarefa-mãe")
                }
            }

            // Status stripe — thin vertical capsule painted in
            // the task's status colour, anchored at the leading
            // edge of the title block as a small accent.
            Capsule()
                .fill(Color(hex: liveTask.statusDisplayHex))
                .frame(width: 3, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                // Title — capped at 2 lines with tail truncation.
                // Letting the title wrap freely (`.fixedSize`)
                // was occasionally inflating the header so much
                // on long titles that the body section's safe
                // height ran out, and SwiftUI compressed the
                // header back — clipping the title against the
                // popup's top edge instead of letting the
                // overflow truncate visually. A 2-line cap +
                // `.help()` tooltip preserves the full text on
                // hover without ever blowing up the layout.
                Text(liveTask.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .help(liveTask.title)
                if !liveTask.listName.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.caption2)
                        Text(liveTask.listName)
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.regularMaterial, in: Circle())
                    .liquidGlassEdge(Circle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .keyboardShortcut(.cancelAction)
            .help("Fechar (Esc)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Force a sensible MIN height on the header so the title
        // text never gets crushed when the popup ends up shorter
        // than its content's natural height (e.g. a freshly-
        // animated popup whose lockedSize was captured before
        // the windowSize env propagated). Without this floor a
        // 2-line title can be compressed to 0pt and disappear
        // visually behind the popup's rounded clipShape.
        .frame(minHeight: 64)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Left column (metadata + description)

    private var metadataColumn: some View {
        // Description floor capped at 320pt. The previous formula
        // `max(280, bodyHeight - 240)` blew up to 500-600pt on tall
        // popups, forcing the description to occupy the full column
        // by itself and pushing the rest of the content (including
        // any subtasks section, links, and the editor's wrapped
        // continuation) off the visible scroll area while the
        // outer ScrollView's hit-test region was still anchored to
        // the top — visually clipping text that *was* present but
        // out of reach. A modest 320pt floor lets the editor breathe
        // without devouring the column.
        let descriptionFloor: CGFloat = 320

        // Scroll indicators are now visible (was `false`) — on
        // tasks with long description + 14 anexos + 8 subtarefas
        // the column overflows, but with the indicator hidden
        // users had no visual cue they could scroll. The result
        // looked like "anexos/subtarefas estão cortados" when
        // they were actually just below the fold.
        // `.vertical` axis + `scrollBounceBehavior(.basedOnSize,
        // axes: .horizontal)` together: the axis spec restricts
        // the scroll axis SwiftUI exposes to the user, and the
        // bounce-behavior fully disables the horizontal axis on
        // the underlying NSScrollView when the content fits the
        // viewport (which it always does — content is laid out
        // to the column's fixed width). This prevents the
        // residual side-pan feel from a diagonal trackpad
        // gesture without needing a custom NSScrollView wrapper.
        // ScrollViewReader so the subtask composer can ask
        // the parent ScrollView to scroll its inline form
        // into view when the user taps "Adicionar". Without
        // this the composer lands at the bottom of the
        // section, often outside the viewport on tasks with
        // many subtasks.
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                TaskDetailView(
                    task: liveTask,
                    appState: appState,
                    includesComments:    false,
                    descriptionMaxHeight: .greatestFiniteMagnitude,
                    descriptionMinHeight: descriptionFloor,
                    descriptionScrolls:   false,
                    scrollProxy:         proxy,
                    visibleSubtasks:     visibleSubtasks
                )
                .equatable()
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .defaultScrollAnchor(.top)
        }
        .frame(width: popoverSize.width * leftColumnRatio)
        // Fill the full body height so the ScrollView's
        // viewport bounds match the popup's body section.
        // Without this the column sized to its content, and
        // any overflow rendered below the popup edge instead
        // of becoming scrollable.
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Right column (activity timeline — chat layout)

    private var commentsColumn: some View {
        // TaskCommentsSection ships its own "Atividade" header,
        // unified comment+activity list, empty-state and composer.
        // `composerAtBottom: true` makes the composer hug the
        // bottom of the column (chat-style) instead of floating
        // directly under whatever last entry happens to render.
        TaskCommentsSection(task: liveTask, appState: appState, composerAtBottom: true)
            .equatable()
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()

            // Subtle keyboard hint — discoverability without a tooltip.
            HStack(spacing: 4) {
                Text("Esc")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(.secondary.opacity(0.20), lineWidth: 0.5)
                    )
                Text("para fechar")
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)
        }
        // Padding pushes the footer content INSIDE the popup's
        // 24pt rounded-corner curve. Earlier values (h:20, v:10)
        // left the "Abrir no ClickUp" link at x≈20, y≈popup-15
        // — squarely inside the bottom-left corner's clip zone,
        // so the icon visually intersected the curve and looked
        // cut. Bumping to h:28, v:16 keeps every element fully
        // clear of both bottom corners (24pt radius + 4pt safety).
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }
}
