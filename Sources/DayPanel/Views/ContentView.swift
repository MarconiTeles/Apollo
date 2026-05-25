import ReviewKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var updateService: UpdateService
    @ObservedObject private var reviewPresenter = ReviewPresenter.shared

    @State private var showSettings    = false
    @State private var showNewEvent    = false
    @State private var showNewTask     = false
    @State private var showOnboarding  = false
    @State private var showNotifs      = false
    @State private var showFilters     = false
    @State private var showAIChat      = false
    /// True when the in-toolbar ClickUp list picker is open. Same
    /// `CUListPickerSheet` reused from Settings/Onboarding so the
    /// user has one canonical picker across the app.
    @State private var showListPicker  = false
    /// Bumped after `showListPicker` dismisses so the toolbar pill
    /// re-reads `KeychainHelper.clickupListName`. The keychain
    /// load isn't observable, so without this the pill would keep
    /// showing the old list name until something else triggered
    /// a re-render.
    @State private var listPickerToken = 0
    /// Window-coordinate rect captured at the moment the list-
    /// picker pill is clicked. Drives the modal's scale anchor
    /// so it grows out of the exact pixel the user pressed
    /// (and shrinks back into it on close), matching the
    /// notifications popup, AI chat, and other overlays.
    @State private var listPickerOrigin: CGRect = .zero

    /// "Dynamic Island"–style expansion of the bell button when a new
    /// notification arrives. Auto-collapses after a few seconds.
    @State private var bellPillNotif:  AppNotification?
    @State private var bellPillTask:   Task<Void, Never>?
    /// Once the user closes the onboarding manually we don't reopen it
    /// during the same session — but a fresh launch re-evaluates the
    /// connections from scratch.
    @State private var onboardingDismissedThisSession = false

    /// Welcome splash. Plays the full cinematic sequence on
    /// EVERY app open — the splash is a deliberate part of the
    /// brand identity, so we always show it instead of the
    /// previous "first run only" behaviour. The
    /// `dp_hasSeenWelcome` UserDefaults key is still written so
    /// downstream code (onboarding gating, etc.) can tell
    /// whether the user has ever launched before, but it no
    /// longer shortens the splash.
    @State private var showWelcome:    Bool = true
    @State private var isFirstWelcome: Bool = true

    // Origin frames so popups can scale-up from where the user clicked
    @State private var settingsOrigin: CGRect = .zero
    @State private var newEventOrigin: CGRect = .zero
    @State private var newTaskOrigin:  CGRect = .zero
    @State private var filtersOrigin:  CGRect = .zero
    @State private var notifsOrigin:   CGRect = .zero

    @State private var dateDirection: Int = 0  // -1 = backward, +1 = forward

    /// Snapshot of the cursor location taken at the moment the
    /// bell was clicked. The same point drives both the
    /// insertion (popup grows from here) and removal (popup
    /// shrinks back into here). Captured once via
    /// `MouseOriginCapture` on click — no per-frame work.
    @State private var notifsOpenPoint: CGPoint = .zero
    /// Window-coordinate point captured at the moment the orb
    /// is clicked, used as the scale anchor for the AI chat
    /// overlay's open/close animation. Falls back to top-centre
    /// if zero (first paint, programmatic toggle).
    @State private var aiChatOpenPoint: CGPoint = .zero

    private var isToday: Bool {
        Calendar.current.isDateInToday(appState.selectedDate)
    }

    /// True iff any modal-class popup is currently presented over
    /// the dashboard. Used to gate hit testing on the layers behind
    /// the popup, so cursor sweeps over rows / pills / toolbar
    /// buttons don't fire hover halos, click ripples, or scroll
    /// reactions while the user is focused on the popup.
    private var anyPopupOpen: Bool {
        appState.detailTask != nil
            || appState.detailEvent != nil
            || !appState.detailSubtaskStack.isEmpty
            || showNewEvent
            || showNewTask
            || showSettings
            || showListPicker
            || showOnboarding
            || showWelcome
    }

    var body: some View {
        GeometryReader { windowGeo in
            ZStack(alignment: .topTrailing) {
                // Editorial canvas — warm cream paper behind
                // everything, replacing the system window
                // background. The whole redesign sits on this.
                Editorial.paper.ignoresSafeArea()

                // Layers 1–4 below are the "dashboard" — everything
                // sitting under the popup z-stack. We wrap them in
                // a Group so a single `.allowsHitTesting(!anyPopupOpen)`
                // gates clicks, hover, and scroll-wheel events for
                // all of them at once. SwiftUI's hit-test default
                // lets hover events pass to the topmost view in a
                // ZStack — but the FloatingModal's translucent
                // backdrop only catches TAPS, not hover. Without
                // this gate, scrolling/hovering rows behind an open
                // popup re-fires every row's hover halo and shadow
                // boost — visible noise + wasted GPU.
                Group {
                    // 1. Main content — extends to TRUE top of
                    // window (y=0). The previous `safeAreaInset`
                    // was reserving a 52pt empty strip at the
                    // top, which left the toolbar area
                    // unpainted by anything inside mainContent.
                    // Removing it lets the dashboard scrollable
                    // content reach y=0 — the AppKit scroll
                    // views inside (TaskCollectionView /
                    // TimelineView) carry their own
                    // `topContentInset = 52 + filterBarHeight`,
                    // so the first row still visually starts
                    // below the toolbar, but content scrolling
                    // upward now passes BEHIND the toolbar
                    // pills (matching the System Settings
                    // reference the user pointed at).
                    mainContent

                    // 2. FrostedStrip — sits ABOVE the
                    //    dashboard content but BELOW the
                    //    toolbar pills. Provides the soft
                    //    blur over the dashboard scrolling
                    //    behind, while the pills stay sharp
                    //    on top.
                    // Top fade over the events list halved
                    // (120 → 60) per request — the soft shadow
                    // reaches half as far down the timeline.
                    FrostedStrip(barHeight: 52, fadeExtent: 60)

                    // 3. Task filter bar — above the strip so
                    //    the filter pills don't get blurred.
                    //    Anchored to the SAME split `mainContent`
                    //    uses so the category bar is confined to
                    //    the task column and never bleeds over
                    //    the timeline.
                    GeometryReader { geo in
                        let total     = max(1, geo.size.width)
                        let timelineW = (total - 1) * (1.0 / 2.05)
                        // `.top` alignment is critical: the
                        // flexible Color.clear spacer makes the
                        // HStack full-height, so without it the
                        // bar would be vertically centred (mid-
                        // list) instead of pinned under the
                        // toolbar at the top of the task column.
                        HStack(alignment: .top, spacing: 0) {
                            // Spacer over the timeline column + the
                            // 1pt centre rule — keeps the filter
                            // bar off the events side.
                            Color.clear
                                .frame(width: timelineW + 1)
                                .allowsHitTesting(false)
                            VStack(spacing: 0) {
                                Color.clear
                                    .frame(height: 52)
                                    .allowsHitTesting(false)
                                TaskFilterBar()
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }

                    // 4. Toolbar — TOPMOST layer; pills stay
                    //    sharp / unblurred on top of the
                    //    FrostedStrip below them. Height
                    //    52pt — matches the title-bar
                    //    height bumped by the empty
                    //    NSToolbar in AppDelegate, so macOS
                    //    centres the traffic-light buttons
                    //    on the same Y as our pills.
                    toolbar
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 52, alignment: .center)
                        // Make the toolbar band drag the window.
                        // `WindowDragArea` is a transparent NSView
                        // whose `mouseDownCanMoveWindow = true`
                        // tells AppKit "treat clicks here as
                        // window drag." Sits as a background so
                        // the interactive pills (Evento / Hoje /
                        // ListPicker / Filtros / Search / …)
                        // catch their own clicks first; only the
                        // gaps between them — which were
                        // previously eating mouseDown into the
                        // dashboard or doing nothing — now drag
                        // the window. Fixes the symptom where
                        // only the right portion of the bar
                        // happened to drag (it had less SwiftUI
                        // chrome covering the title-bar region).
                        .background(WindowDragArea())
                }
                .allowsHitTesting(!anyPopupOpen)

                // 5. Event detail overlay — scales up from the tapped pill
                //    with a spring-bounce. Explicit `.zIndex(1000)` so
                //    it renders ABOVE the AI chat overlay (source-order
                //    later in this ZStack); without it, opening an
                //    event from inside the AI chat would tuck the
                //    detail behind the chat panel and the user
                //    couldn't see it.
                EventDetailOverlay(windowSize: windowGeo.size)
                    .zIndex(1000)

                // Persistent blur backdrop for the entire initial-
                // setup flow (welcome splash + onboarding wizard).
                // Inserted here — *before* any FloatingModal — so
                // SwiftUI's source-order layering puts it above the
                // dashboard / toolbar but below the onboarding popup
                // and below the welcome splash. No explicit zIndex:
                // bumping it above 0 (as we did before) accidentally
                // pushed it on top of the FloatingModal too. The
                // `.transition(.opacity)` makes it fade in alongside
                // the welcome animation and fade out cleanly once
                // setup is done.
                if showWelcome || showOnboarding {
                    Rectangle()
                        .fill(.regularMaterial)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }

                // 6. Create modals — same scale-bounce style, centered.
                FloatingModal(
                    isPresented: $showNewEvent,
                    origin:      newEventOrigin,
                    windowSize:  windowGeo.size,
                    fromBottom:  true
                ) {
                    CreateEventSheet(onClose: { showNewEvent = false })
                        .environmentObject(appState)
                }
                FloatingModal(
                    isPresented: $showNewTask,
                    origin:      newTaskOrigin,
                    windowSize:  windowGeo.size,
                    fromBottom:  true
                ) {
                    CreateTaskSheet(onClose: { showNewTask = false })
                        .environmentObject(appState)
                }
                FloatingModal(
                    isPresented: $showSettings,
                    origin:      settingsOrigin,
                    windowSize:  windowGeo.size,
                    fromBottom:  true
                ) {
                    SettingsView(onClose: { showSettings = false })
                        .environmentObject(appState)
                }
                // Global "transform event into task" overlay. Driven
                // by `appState.pendingConversion` so any surface
                // (event detail header, timeline right-click) can
                // open the same modal. Wrapped in `FloatingModal`
                // (not the system `.sheet`) so it picks up Apollo's
                // editorial chrome — no system rounded sheet corners
                // — and rides the bottom-rise animation that the
                // other create sheets use.
                FloatingModal(
                    isPresented: Binding(
                        get: { appState.pendingConversion != nil },
                        set: { if !$0 { appState.pendingConversion = nil } }
                    ),
                    windowSize: windowGeo.size,
                    fromBottom: true
                ) {
                    if let ev = appState.pendingConversion {
                        ConvertEventToTaskSheet(
                            event:   ev,
                            onClose: { appState.pendingConversion = nil },
                            onDone:  { appState.pendingConversion = nil }
                        )
                        .environmentObject(appState)
                    }
                }
                // Sits ABOVE the EventDetail (which uses zIndex 1000)
                // so the convert sheet always wins focus.
                .zIndex(2000)
                // ClickUp list picker — same sheet Settings/Onboarding
                // use, surfaced from the toolbar pill so the user
                // can switch lists in one click without opening
                // Settings. The wrapper binding bumps
                // `listPickerToken` whenever the sheet flips
                // closed, forcing the toolbar pill to re-read the
                // new list name from Keychain (which isn't
                // observable on its own).
                // List picker — anchored DROPDOWN under the
                // "Listas" toolbar pill (was a centered modal).
                Group {
                    if showListPicker {
                        listAnchoredOverlay(windowSize: windowGeo.size)
                    }
                }
                .zIndex(1100)
                FloatingModal(
                    isPresented: $showOnboarding,
                    windowSize:  windowGeo.size,
                    // The persistent setup backdrop drawn higher up
                    // in this ZStack already provides the blur, so
                    // `.none` keeps the onboarding from stacking a
                    // second material on top of it.
                    backdrop:    .none
                ) {
                    OnboardingView(onClose: { showOnboarding = false })
                        .environmentObject(appState)
                        // The redesigned onboarding is a full-bleed
                        // two-pane editorial spread (prototype
                        // `POnboarding`), so it must fill the window
                        // rather than sit centred like a small modal.
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // Task detail popup — opened from the small "open" icon
                // above the chevron on a task row. Origin is captured
                // from that button so the modal scales out of it.
                // `.zIndex(1000)` (matched on the wrapper below) keeps
                // the detail above the AI chat overlay so opening a
                // task from inside the chat doesn't tuck the popup
                // out of sight.
                FloatingModal(
                    isPresented: Binding(
                        get: { appState.detailTask != nil },
                        set: { if !$0 { appState.detailTask = nil } }
                    ),
                    origin:      appState.detailTaskOrigin,
                    windowSize:  windowGeo.size
                ) {
                    if let t = appState.detailTask {
                        // Read the live snapshot here — ContentView
                        // still observes AppState via @EnvironmentObject,
                        // so it re-evaluates whenever tasksById mutates.
                        // The popup itself holds `let appState` (no
                        // subscription) and reacts to edits via this
                        // `task` prop change instead of an implicit
                        // observer cascade.
                        let live = appState.tasksById[t.id] ?? t
                        TaskDetailSheet(task: live,
                                        appState: appState,
                                        visibleSubtasks: appState.subtasks(of: live.id),
                                        onClose: { appState.detailTask = nil })
                            .equatable()
                            // CRITICAL: keying the sheet on the task
                            // id forces SwiftUI to discard and rebuild
                            // the view tree (and every nested @State,
                            // @FocusState, NSViewRepresentable cache,
                            // RichTextEditor NSTextView etc.) when
                            // the user navigates parent → subtask.
                            //
                            // Without this, opening a subtask from
                            // inside an already-open parent popup
                            // reuses the same TaskDetailSheet
                            // instance: the parent's stored
                            // `lockedSize`, description draft, focus
                            // state, and the RichTextEditor's
                            // NSTextView (still sized for the parent's
                            // description content) all bleed into the
                            // subtask render, producing the visible
                            // layout breakage where the description
                            // text was clipped both vertically and
                            // horizontally. Opening a subtask from an
                            // expanded inline row didn't have the bug
                            // because no popup was on screen yet —
                            // SwiftUI would create a fresh
                            // TaskDetailSheet anyway. The `.id()`
                            // makes both flows behave identically.
                            .id(t.id)
                    }
                }
                .zIndex(1000)
                // Subtask overlay popup — mounts ON TOP of the
                // parent task popup when the user drills into a
                // subtask from inside the parent. The parent
                // stays rendered untouched behind, so popping
                // back (back button or tap outside) reveals it
                // exactly as the user left it without an
                // expensive re-mount + re-spring.
                //
                // `backdrop: .none` so we don't double-dim on top
                // of the parent's own backdrop. The TaskDetailSheet
                // itself owns enough visual chrome (popupGlass,
                // shadow stack) to read clearly over the parent
                // without a fresh dim layer.
                FloatingModal(
                    isPresented: Binding(
                        get: { !appState.detailSubtaskStack.isEmpty },
                        set: { if !$0 { appState.closeAllDetailSubtasks() } }
                    ),
                    origin:      .zero,
                    windowSize:  windowGeo.size,
                    backdrop:    .none
                ) {
                    // Render the topmost subtask in the stack —
                    // i.e. whichever depth the user has drilled
                    // into. Pushing onto / popping off the stack
                    // (via SubtaskRow / the back button) swaps
                    // which task is shown here. The `.id(sub.id)`
                    // forces SwiftUI to discard and rebuild the
                    // popup view tree on each level change so
                    // every nested @State / RichTextEditor /
                    // ScrollView starts fresh.
                    if let sub = appState.detailSubtaskOverlay {
                        let liveSub = appState.tasksById[sub.id] ?? sub
                        TaskDetailSheet(task: liveSub,
                                        appState: appState,
                                        visibleSubtasks: appState.subtasks(of: liveSub.id),
                                        onClose: {
                                            appState.closeAllDetailSubtasks()
                                        })
                            .equatable()
                            .id(sub.id)
                    }
                }
                .zIndex(1001)  // above the parent task detail
                // Notifications Center — custom anchored popup so the
                // open/close animation scales from the bell button (the
                // native .popover animation slides up from below, which
                // reads as "appearing from nowhere").
                //
                // `.zIndex(1100)` (higher than the detail-popup tier
                // at 1000-1001) keeps the popup ABOVE the task list
                // during the FULL close animation. Without an
                // explicit z-index, SwiftUI was tucking the
                // shrinking popup behind the task panel mid-
                // animation — the user saw it briefly disappear
                // before its scale-back transition finished.
                Group {
                    if showNotifs {
                        notificationsAnchoredOverlay(windowSize: windowGeo.size)
                    }
                }
                .zIndex(1100)

                Group {
                    if showFilters {
                        filtersAnchoredOverlay(windowSize: windowGeo.size)
                    }
                }
                .zIndex(1100)

                // Incoming toasts morph the bell button itself into a
                // Dynamic-Island-style pill — handled inside the toolbar.

                // Apollo IA chat — centred overlay above all
                // dashboard surfaces. Was a `.popover` anchored
                // to the orb button (anchor arrow, fixed corner);
                // moved here so the chat reads as a primary
                // window-centred panel instead of a small popup
                // attached to a toolbar pixel. Backdrop dimmer
                // catches outside-clicks for dismissal.
                if showAIChat {
                    // Editorial backdrop — a light dim, not a
                    // frosted wash. The redesigned Apollo IA is
                    // a calm paper "column", so it sits over a
                    // quiet darkened dashboard (matching the
                    // other editorial overlays) instead of the
                    // old Apple-Intelligence frosted material +
                    // neon edge glow, which were dropped with
                    // the rest of the Liquid Glass language.
                    Color.black.opacity(0.10)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .zIndex(800)

                    aiChatCenteredOverlay(windowSize: windowGeo.size)
                        .zIndex(900)
                }

                // Welcome splash — sits above every other overlay so
                // nothing distracts during the intro. Plays on every
                // launch; `isFirstLaunch` switches between the full
                // cinematic and the 1-second brand flash.
                if showWelcome {
                    WelcomeAnimationView(isFirstLaunch: isFirstWelcome,
                                         onComplete: welcomeFinished)
                        .transition(.opacity)
                        .zIndex(999)
                }

                // Sparkle "new version available" banner — sits at the
                // bottom-trailing corner, anchored ABOVE all dashboard
                // surfaces (zIndex 1200, higher than the
                // notifications/filters tier at 1100) but suppressed
                // while welcome / onboarding overlays own the screen
                // so the intro stays clean. Sparkle's modal still
                // fires through "Verificar Atualizações…"; this is a
                // persistent passive announcement that survives a
                // "Remind Me Later" click.
                if !showWelcome && !showOnboarding {
                    UpdateAvailableBanner(updateService: updateService)
                        .padding(.trailing, 18)
                        .padding(.bottom, 18)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .bottomTrailing
                        )
                        .allowsHitTesting(updateService.availableUpdate != nil)
                        .zIndex(1200)
                }

                // Toast — drops in just BELOW the 52pt head bar,
                // top-right, as its own surface (no longer painted
                // over the bell). Suppressed during welcome /
                // onboarding so the intro stays clean.
                if !showWelcome && !showOnboarding, let pill = bellPillNotif {
                    BellPill(notification: pill,
                             onTap: {
                                 collapseBellPill()
                                 showNotifs = true
                             },
                             onDismiss: { collapseBellPill() })
                        .padding(.top, 52 + 12)
                        .padding(.trailing, 18)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topTrailing
                        )
                        .transition(.asymmetric(
                            insertion: .offset(y: -8).combined(with: .opacity),
                            removal:   .opacity
                        ))
                        .animation(.spring(duration: 0.4, bounce: 0.22),
                                   value: bellPillNotif?.id)
                        .allowsHitTesting(true)
                        .zIndex(1250)
                }
            }
            .coordinateSpace(name: "appWindow")
            .environment(\.windowSize, windowGeo.size)
            // Cmd+Z handler — pops the most recent reversible
            // action off `AppState.undoStack` and runs its undo
            // closure. The button is invisible (zero frame +
            // zero opacity) and only exists to host the
            // keyboard shortcut, since SwiftUI on macOS doesn't
            // attach `.keyboardShortcut` to free-floating views
            // — it has to be on a Button (or a menu item).
            .background(
                Button {
                    Task { await appState.undoLastAction() }
                } label: { EmptyView() }
                .buttonStyle(.plain)
                .keyboardShortcut("z", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            )
            // PERF: we used to install an `onContinuousHover`
            // here that wrote the cursor position to a
            // @State on every mouse-move event, forcing the
            // entire ContentView body to re-evaluate at
            // ~60Hz while the cursor traveled across the
            // window. Removed in favor of one-shot reads
            // via `MouseOriginCapture.currentClickRectInMainWindow()`
            // at the moment a popup actually opens — same
            // accuracy, zero cost per frame.
        }
        // Liquid Glass window background — Dock-style frosted blur.
        // `.menu` is the heaviest-blur public material that doesn't add
        // a strong colour tint, matching the look of the macOS Dock.
        // PERF: window background was a `VisualEffectView(.menu,
        // .behindWindow)` that covered the ENTIRE window. The
        // `.behindWindow` blend mode tells macOS to sample +
        // gaussian-blur the desktop content behind us, recomputed
        // every time ANY layer in the Apollo window dirties.
        // With a populated task list (rows constantly settling
        // animations, hover states, status updates), this fired
        // ~60Hz and dragged WindowServer's desktop FPS down for
        // every other app sharing the same Space. Minimizing
        // Apollo recovered system FPS instantly because the
        // window stopped compositing — confirming the cause.
        //
        // Replaced by a flat adaptive color. The popups
        // (`.popupGlass(...)`) keep their own local vibrancy, so
        // the "frosted glass" feel survives where it actually
        // helps the design — without paying the system-wide tax
        // of a window-wide blur.
        .background(
            // Pinned to the Editorial cream canvas. Previously
            // `Color(nsColor: .windowBackgroundColor)`, which
            // resolves against the SYSTEM appearance and turned
            // the root backdrop BLACK under macOS Dark Mode
            // (visible through the timeline's bottom fade). The
            // app is hard-locked to the light Editorial theme,
            // so the backdrop is now an explicit constant.
            Editorial.paper
                .ignoresSafeArea()
        )
        // Push the toolbar up into the macOS title bar (alongside traffic lights)
        .ignoresSafeArea(.container, edges: .top)
        // Specular highlight: subtle white sheen at top (light hitting glass edge)
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [.white.opacity(0.12), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 80)
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
        // Onboarding: every time the app is opened (launch or window
        // reopen), check if any required connection is missing. If yes,
        // surface the wizard. The check also reruns whenever a connection
        // state actually changes during the session.
        // Command palette → "Abrir configurações" pumps the
        // token; ContentView mirrors it onto its local
        // `showSettings` so the existing FloatingModal flow
        // (origin animation, dismiss, etc.) handles the rest.
        // Token-based — opening from the palette while the
        // sheet is already up is a no-op.
        .onReceive(appState.$openSettingsToken.dropFirst()) { _ in
            showSettings = true
        }
        // "Reabrir tutorial" — same pattern, but force-open
        // bypasses `maybeShowOnboarding`'s connection-state
        // gating since the user is asking to revisit the
        // wizard explicitly, not because of a missing setup.
        .onReceive(appState.$openOnboardingToken.dropFirst()) { _ in
            onboardingDismissedThisSession = false
            showOnboarding = true
        }
        // Mirror the SwiftUI-side popup stack into
        // `appState.swiftUIPopupOpen`. AppState combines
        // this with the command-palette flag so AppKit
        // cells get one unified `anyPopupOpen` signal to
        // gate their hover effects on — without us needing
        // to know about each other's surface here.
        .onChange(of: anyPopupOpen) { _, new in
            appState.swiftUIPopupOpen = new
        }
        .onAppear {
            appState.swiftUIPopupOpen = anyPopupOpen
        }
        .onAppear {
            // Reset the session flag on a fresh appear so the popup CAN
            // fire if needed. The check itself runs after a delay to let
            // AppState.initialize() finish its first calendar/click-up
            // check (otherwise hasAccess reads the default `false` and
            // we'd open the wizard even with permissions already granted).
            onboardingDismissedThisSession = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                maybeShowOnboarding()
            }
        }
        .onChange(of: appState.clickUpAuthService.isConnected) { _, _ in maybeShowOnboarding() }
        .onChange(of: appState.googleAuth.isConnected)         { _, _ in maybeShowOnboarding() }
        .onChange(of: showOnboarding) { _, isShown in
            if !isShown { onboardingDismissedThisSession = true }
        }
        // Embedded review workflow: REVIEW on an attachment opens the shared
        // ReviewKit engine in-app; on submit Apollo posts the summary to ClickUp.
        .sheet(item: $reviewPresenter.request) { req in
            ReviewView(
                params: req.params,
                savedJSON: req.savedJSON,
                onClose: { reviewPresenter.request = nil },
                onSubmit: { result in
                    if let tid = result.taskId {
                        let mentions = [result.uploaderId].compactMap { $0 }
                        Task {
                            await appState.postReviewComment(
                                taskId: tid,
                                commentId: result.commentId,
                                attachmentId: result.attachmentId,
                                text: result.summaryText,
                                mentionMemberIds: mentions,
                                reviewJSON: result.json)
                        }
                    }
                    reviewPresenter.request = nil
                }
            )
            .frame(minWidth: 1040, minHeight: 660)
        }
    }

    /// Renders the Notifications Center as a top-trailing-anchored popup
    /// just below the bell button. The open/close animation scales out
    /// of (and back into) the exact cursor position captured when the
    /// bell was clicked — the transition's `.scale` anchor uses the
    /// click point translated into a window-relative UnitPoint, which
    /// only lines up because the transitioned view fills the entire
    /// window via `.frame(maxWidth: .infinity, maxHeight: .infinity)`.
    /// AI chat as a centred overlay. Replaces the previous
    /// `.popover` attached to the orb button — the popover's
    /// arrow + edge anchor made the chat feel pinned to a tiny
    /// toolbar pixel; centring it gives the chat the visual
    /// weight of a primary surface. A faint dimmed backdrop
    /// catches outside-clicks so the user can dismiss without
    /// hunting for the close button.
    @ViewBuilder
    private func aiChatCenteredOverlay(windowSize: CGSize) -> some View {
        // Translate the captured click point into a UnitPoint
        // (0…1 across the window) so the chat scales out of the
        // exact orb pixel the user pressed. Falls back to the
        // top-centre on the very first paint when windowSize is
        // still zero.
        let cursorAnchor = UnitPoint(
            x: windowSize.width  > 0 && aiChatOpenPoint != .zero
                ? aiChatOpenPoint.x / windowSize.width  : 0.5,
            y: windowSize.height > 0 && aiChatOpenPoint != .zero
                ? aiChatOpenPoint.y / windowSize.height : 0.05
        )

        ZStack {
            // PERF: window-wide dim backdrop removed. A full-
            // window `Color.black.opacity(0.18)` cost an alpha
            // blend pass over ~7M pixels every WindowServer
            // composite. Click-to-dismiss now lives on an
            // INVISIBLE hit-test layer (alpha ~0.001) — same
            // dismissal UX, ~0 cost since the compositor
            // skips fully-transparent layers.
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.52,
                                          dampingFraction: 0.82)) {
                        showAIChat = false
                    }
                }
                .transition(.opacity)

            AIAgentChatView(onClose: {
                withAnimation(.spring(response: 0.52,
                                      dampingFraction: 0.82)) {
                    showAIChat = false
                }
            })
                .environmentObject(appState)
                // Editorial "column" card — a calm paper surface
                // with a hairline rule and soft shadow (the
                // prototype `PPopup`/`PAIChat` chrome), inset
                // generously from the window edges so it reads
                // as a focused reading panel rather than a
                // panel-less float.
                .background(
                    Editorial.paper,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Editorial.rule, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.22), radius: 50, y: 40)
                .shadow(color: .black.opacity(0.08), radius: 24, y: 8)
                .padding(.top,        max(28, windowSize.height * 0.05))
                .padding(.bottom,     max(28, windowSize.height * 0.05))
                .padding(.horizontal, max(48, windowSize.width  * 0.07))
                // Window entrance/exit: the panel grows out of
                // the Apollo button (cursor anchor) but from a
                // readable 0.90 — not a speck — drifting up into
                // place with a soft blur clearing, and settles
                // out the same way. Reads as an elegant
                // "publication opening" rather than a UI pop.
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.90, anchor: cursorAnchor)
                        .combined(with: .opacity)
                        .combined(with: .offset(y: 14))
                        .combined(with: .modifier(
                            active:   BlurModifier(radius: 14),
                            identity: BlurModifier(radius: 0))),
                    removal: .scale(scale: 0.95, anchor: cursorAnchor)
                        .combined(with: .opacity)
                        .combined(with: .offset(y: 10))
                        .combined(with: .modifier(
                            active:   BlurModifier(radius: 10),
                            identity: BlurModifier(radius: 0)))
                ))
        }
    }

    @ViewBuilder
    private func notificationsAnchoredOverlay(windowSize: CGSize) -> some View {
        // Backdrop — invisible click-target so clicking outside closes
        Color.black.opacity(0.001)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture {
                // `withAnimation` is REQUIRED here so the
                // `.transition(...)` on the popup below
                // actually plays on close. Without it the
                // `if showNotifs` parent removes the view
                // synchronously before the transition runs,
                // making the popup vanish without animation.
                withAnimation(.spring(duration: 0.45, bounce: 0.32)) {
                    showNotifs = false
                }
            }
            .transition(.opacity)

        // Translate the captured click point into a UnitPoint
        // (0…1 across the window). With windowSize zero on the very
        // first layout pass, fall back to the bell's centre so the
        // popup never animates out of (0,0).
        let cursorAnchor = UnitPoint(
            x: windowSize.width  > 0 ? notifsOpenPoint.x / windowSize.width  : 1.0,
            y: windowSize.height > 0 ? notifsOpenPoint.y / windowSize.height : 0.05
        )

        // The popup itself, anchored under the bell. Padding has to be
        // applied *before* the infinity-alignment frame: when it goes
        // after, SwiftUI grows the already-infinite frame instead of
        // offsetting the content within it, which leaves the popup
        // floating in the middle of the window instead of under the
        // bell. With the padding inside, the popup's natural size gets
        // padded first and then the frame stretches the padded view
        // to the window's bounds with top-trailing alignment, so the
        // popup's right edge lands exactly at `notifsOrigin.maxX`.
        NotificationsCenterView(onClose: {
            withAnimation(.spring(duration: 0.45, bounce: 0.32)) {
                showNotifs = false
            }
        })
            .environmentObject(appState)
            .padding(.top,      max(notifsOrigin.maxY + 8, 60))
            .padding(.trailing, max(windowSize.width - notifsOrigin.maxX, 8))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .transition(.asymmetric(
                insertion: .scale(scale: 0.05, anchor: cursorAnchor)
                    .combined(with: .opacity),
                removal:   .scale(scale: 0.05, anchor: cursorAnchor)
                    .combined(with: .opacity)
            ))
            .animation(.spring(duration: 0.45, bounce: 0.32), value: showNotifs)
    }

    private func collapseBellPill() {
        bellPillTask?.cancel()
        withAnimation(.spring(duration: 0.40, bounce: 0.20)) {
            bellPillNotif = nil
        }
    }

    /// Filter popover — anchors under the "Filtros" toolbar button.
    ///
    /// Animation: the popover's transition uses a `scale(_, anchor:)`
    /// where `anchor` is the BUTTON's position expressed as a UnitPoint
    /// relative to the window (the transitioned view fills the window
    /// via `.frame(maxWidth: .infinity, maxHeight: .infinity)`, so its
    /// coordinate space matches the window). On open, the popover
    /// scales up from that exact point — visually "growing out of" the
    /// Filtros button. On close, it scales back into the same point.
    ///
    /// Position: `.topLeading` vs `.topTrailing` resting alignment so
    /// the popover never overflows the right edge.
    ///
    /// Notch: a small triangle in the popover's top edge points at the
    /// button (rendered inside `TaskFilterPopover` using the
    /// `NotchedRoundedRectangle` shape; we pass the button's X in the
    /// popover's local space).
    @ViewBuilder
    private func filtersAnchoredOverlay(windowSize: CGSize) -> some View {
        let popoverWidth: CGFloat = 320
        let safeMargin:   CGFloat = 12

        // Will the popover overflow the right edge if anchored at minX?
        let anchorTrailing = (filtersOrigin.minX + popoverWidth + safeMargin) > windowSize.width
        // Notch tip sits at the popover's top edge — bring the popover
        // up so the tip points exactly at the button's bottom edge
        // (with a 2pt sliver of breathing room).
        let topPad = max(filtersOrigin.maxY + 2, 54)

        // Notch X within the popover's local coordinate space (0..popoverWidth).
        // The popover's resting horizontal position depends on which side
        // it's anchored to:
        //   • anchorTrailing → popover's right edge sits at the button's
        //     right edge (clamped if that would push past the window's
        //     right safe margin), so popoverMinX = popoverMaxX - width.
        //   • anchorLeading  → popover's left edge sits at the button's
        //     left edge (clamped to the left safe margin).
        let popoverMaxX: CGFloat = anchorTrailing
            ? min(filtersOrigin.maxX, windowSize.width - safeMargin)
            : 0  // unused
        let popoverMinX: CGFloat = anchorTrailing
            ? popoverMaxX - popoverWidth
            : max(filtersOrigin.minX, safeMargin)
        let notchX = max(20, min(popoverWidth - 20, filtersOrigin.midX - popoverMinX))

        // UnitPoint of the button in WINDOW space — drives the scale
        // transition so the popover collapses/expands at the button.
        let buttonAnchor = UnitPoint(
            x: windowSize.width  > 0 ? filtersOrigin.midX / windowSize.width  : 0.5,
            y: windowSize.height > 0 ? filtersOrigin.midY / windowSize.height : 0.05
        )

        Color.black.opacity(0.001)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture {
                // `withAnimation` ensures the popover plays
                // its scale-back transition before being
                // removed by the parent `if showFilters`.
                // Without it the close is instantaneous.
                withAnimation(.spring(duration: 0.42, bounce: 0.28)) {
                    showFilters = false
                }
            }
            .transition(.opacity)

        // Same modifier-order trick as the notifications popup: padding
        // BEFORE the infinity-alignment frame so SwiftUI offsets the
        // content within the frame instead of growing the frame itself.
        TaskFilterPopover(notchX: notchX, onClose: {
            withAnimation(.spring(duration: 0.42, bounce: 0.28)) {
                showFilters = false
            }
        })
            .environmentObject(appState)
            .padding(.top, topPad)
            .padding(.leading,  anchorTrailing ? safeMargin : max(filtersOrigin.minX, safeMargin))
            .padding(.trailing, anchorTrailing ? max(windowSize.width - filtersOrigin.maxX, safeMargin) : safeMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: anchorTrailing ? .topTrailing : .topLeading)
            // Use a small starting scale (NOT 0) — `scale: 0` collapses
            // the view to a point during transition, which on macOS 26
            // makes the inner `HostingScrollView` crash inside
            // `NSViewGetTransformToDescendant` when its first
            // `viewDidMoveToWindow` runs against a degenerate transform.
            // 0.05 keeps the transform numerically stable while still
            // looking like a "growing from button" animation.
            .transition(.asymmetric(
                insertion: .scale(scale: 0.05, anchor: buttonAnchor).combined(with: .opacity),
                removal:   .scale(scale: 0.05, anchor: buttonAnchor).combined(with: .opacity)
            ))
            .animation(.spring(duration: 0.42, bounce: 0.28), value: showFilters)
    }

    /// List picker as an anchored DROPDOWN under the "Listas"
    /// toolbar pill — compact single-column variant, growing out
    /// of the click point. Same mechanics as the filter popover.
    @ViewBuilder
    private func listAnchoredOverlay(windowSize: CGSize) -> some View {
        let dropdownWidth: CGFloat = 380
        let safeMargin:    CGFloat = 12

        // Anchor the dropdown's left edge at the click X, clamped
        // so it never overflows the window's right safe margin.
        let rawMinX = listPickerOrigin.minX == 0
            ? safeMargin : listPickerOrigin.minX
        let minX = min(rawMinX, windowSize.width - dropdownWidth - safeMargin)
        let leftPad = max(minX, safeMargin)
        let topPad  = max(listPickerOrigin.maxY + 4, 54)

        let buttonAnchor = UnitPoint(
            x: windowSize.width  > 0 ? listPickerOrigin.midX / windowSize.width  : 0.2,
            y: windowSize.height > 0 ? listPickerOrigin.midY / windowSize.height : 0.05
        )

        Color.black.opacity(0.001)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(duration: 0.42, bounce: 0.28)) {
                    listPickerToken &+= 1
                    showListPicker = false
                }
            }
            .transition(.opacity)

        CUListPickerSheet(onClose: {
            withAnimation(.spring(duration: 0.42, bounce: 0.28)) {
                listPickerToken &+= 1
                showListPicker = false
            }
        }, compact: true)
            .environmentObject(appState)
            .padding(.top, topPad)
            .padding(.leading, leftPad)
            .padding(.trailing, safeMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: .topLeading)
            .transition(.asymmetric(
                insertion: .scale(scale: 0.05, anchor: buttonAnchor).combined(with: .opacity),
                removal:   .scale(scale: 0.05, anchor: buttonAnchor).combined(with: .opacity)
            ))
            .animation(.spring(duration: 0.42, bounce: 0.28), value: showListPicker)
    }

    /// Toolbar pill that opens the multi-dimensional filter popover.
    /// Shows a counter badge when one or more dimensions are active.
    private var filtersButton: some View {
        let count = appState.taskFilters.activeDimensionCount
        let isActive = count > 0
        return Button {
            withAnimation(.spring(duration: 0.45, bounce: 0.32)) {
                showFilters.toggle()
            }
        } label: {
            // Prototype: plain "Filtros" TBBtn text. The active
            // count is carried in the tooltip (not a capsule) so
            // the band stays type-only; the word turns cinnabar
            // while ≥1 dimension is active.
            Text("Filtros")
        }
        .buttonStyle(TBButtonStyle(accent: isActive))
        .focusEffectDisabled()
        .help(isActive ? "Filtros (\(count) ativos)" : "Filtros")
        .captureFrame($filtersOrigin)
    }

    /// In-toolbar shortcut to switch the active ClickUp list. Reads
    /// the current list name from Keychain (the canonical store
    /// used by every other code path) and re-reads on every render
    /// — `listPickerToken` is bumped after the picker sheet
    /// dismisses to force the refresh, since Keychain isn't
    /// observable on its own. Tapping reuses the same
    /// `CUListPickerSheet` the Settings/Onboarding flows use.
    /// Segmented-ish toggle between "Lista" (the picked ClickUp
    /// list) and "Meu" (cross-list tasks assigned to the
    /// connected user). Flipping it re-syncs immediately so the
    /// right column repopulates from the chosen source. The
    /// list-picker pill dims in My Work mode since the active
    /// list no longer scopes what's shown (the picked list is
    /// still remembered for when the user flips back).
    private var listPickerPill: some View {
        // `listPickerToken` is referenced inside the closure so the
        // view recomputes whenever it bumps; reading it here keeps
        // the dependency explicit.
        let _ = listPickerToken
        let name = KeychainHelper.load(for: KeychainHelper.Keys.clickupListName)
            ?? "Lista"
        let truncated = name.count > 18
            ? String(name.prefix(16)) + "…"
            : name
        return Button {
            // Snapshot the cursor position at click time so the
            // picker scales out of the exact pixel the user
            // pressed (and shrinks back into it on close) —
            // same one-shot read used by the bell + AI chat
            // popups for a consistent feel across overlays.
            let rect = MouseOriginCapture.currentClickRectInMainWindow()
            if rect != .zero { listPickerOrigin = rect }
            showListPicker = true
        } label: {
            HStack(spacing: 6) {
                Text(truncated)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .regular))
            }
        }
        .buttonStyle(TBButtonStyle())
        .focusEffectDisabled()
        .help("Lista ClickUp atual: \(name) — clique para trocar")
    }


    private func maybeShowOnboarding() {
        guard !onboardingDismissedThisSession else { return }
        // Note on the welcome interaction: we deliberately do
        // NOT bail out while `showWelcome` is true. The body's
        // persistent setup backdrop covers both overlays, so
        // raising `showOnboarding` while the splash is still
        // playing is safe — and `welcomeFinished()` relies on
        // exactly this behaviour: it sets `showOnboarding`
        // *before* dismissing the splash so the cross-fade has
        // both overlays mounted, avoiding a frame where the
        // dashboard pokes through. An earlier `guard
        // !showWelcome` check broke that hand-off and prevented
        // the wizard from ever opening on first launch.
        // Calendar onboarding step now means "connect Google" —
        // EventKit was removed, so OAuth is the only path.
        let needsCalendar = !appState.googleAuth.isConnected
        let needsClickUp  = !appState.clickUpAuthService.isConnected
        let needsList     = KeychainHelper.load(for: KeychainHelper.Keys.clickupListId) == nil
        guard needsCalendar || needsClickUp || needsList else { return }
        if !showOnboarding { showOnboarding = true }
    }

    /// Called by `WelcomeAnimationView` after its fade-out completes.
    /// Persists the "seen" flag, brings the onboarding wizard up
    /// *first* (so the persistent backdrop in `body` stays put while
    /// SwiftUI cross-fades the two overlays), then dismisses the
    /// splash. Doing it in this order avoids the brief moment where
    /// neither overlay is on screen and the dashboard would flash
    /// through.
    private func welcomeFinished() {
        UserDefaults.standard.set(true, forKey: "dp_hasSeenWelcome")
        maybeShowOnboarding()
        withAnimation(.easeInOut(duration: 0.25)) {
            showWelcome = false
        }
    }

    // MARK: - Glass Toolbar

    private var toolbar: some View {
        // Reproduces the prototype's `PToolbar` exactly: a type-led
        // band of `TBBtn` text buttons separated by a 26pt gap, the
        // active-list picker, a flexible gap, then the trailing
        // cluster (Filtros · Buscar ⌘K · + Tarefa · ✦ Apollo · 🔔 ·
        // ⚙). No glass, no capsules, no diagnostic chrome — the
        // hairline rule along the bottom IS the only divider.
        HStack(spacing: 26) {

            // + Evento
            Button { showNewEvent = true } label: {
                Text("+ Evento")
            }
            .buttonStyle(TBButtonStyle())
            .focusEffectDisabled()
            .help("Novo evento")
            .captureFrame($newEventOrigin)

            // Hoje — jump to today + resync
            Button {
                dateDirection = appState.selectedDate < Date() ? 1 : -1
                withAnimation(.spring(duration: 0.35)) {
                    appState.selectedDate = Date()
                }
                appState.todayJumpToken &+= 1
                Task { await appState.sync() }
            } label: {
                Text("Hoje")
            }
            .buttonStyle(TBButtonStyle())
            .focusEffectDisabled()

            // {Active list} ⌄ — opens the same picker Settings uses
            if appState.clickUpAuthService.isConnected {
                listPickerPill
            }

            Spacer(minLength: 0)

            // Filtros — accent-tinted while ≥1 dimension is active
            if appState.clickUpAuthService.isConnected {
                filtersButton
            }

            // Buscar ⌘K — opens the existing Spotlight-style palette
            // (same responder action ⌘K triggers from the menu).
            Button {
                NSApp.sendAction(Selector(("toggleCommandPalette:")), to: nil, from: nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .regular))
                    Text("Buscar")
                    KbdTB(text: "⌘K")
                }
            }
            .buttonStyle(TBButtonStyle())
            .focusEffectDisabled()
            .help("Buscar (⌘K)")

            // + Tarefa
            Button { showNewTask = true } label: {
                Text("+ Tarefa")
            }
            .buttonStyle(TBButtonStyle())
            .focusEffectDisabled()
            .help("Nova tarefa")
            .captureFrame($newTaskOrigin)

            // ✦ Apollo — cinnabar mark + word (prototype AIMark)
            Button {
                let rect = MouseOriginCapture.currentClickRectInMainWindow()
                if rect != .zero {
                    aiChatOpenPoint = CGPoint(x: rect.midX, y: rect.midY)
                }
                withAnimation(.spring(response: 0.52,
                                      dampingFraction: 0.82)) {
                    showAIChat.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    AIMark(size: 14)
                    Text("Apollo")
                }
            }
            .buttonStyle(TBButtonStyle(accent: true))
            .focusEffectDisabled()
            .help("Apollo IA")
            .onChange(of: appState.aiAgent.dismissChatRequest) { _, _ in
                withAnimation(.spring(response: 0.45,
                                      dampingFraction: 0.85)) {
                    showAIChat = false
                }
            }
            // RAM relief — unload the embedded model the moment the
            // chat closes instead of holding ~5 GB for 5 min.
            .onChange(of: showAIChat) { _, isOpen in
                if !isOpen {
                    Task.detached(priority: .background) {
                        await appState.aiAgent.unloadEmbeddedModel()
                    }
                }
            }

            // 🔔 — notifications; cinnabar count badge (prototype)
            Button {
                let rect = MouseOriginCapture.currentClickRectInMainWindow()
                notifsOpenPoint = rect == .zero
                    ? CGPoint(x: notifsOrigin.midX, y: notifsOrigin.midY)
                    : CGPoint(x: rect.midX, y: rect.midY)
                withAnimation(.spring(duration: 0.45, bounce: 0.32)) {
                    showNotifs.toggle()
                }
            } label: {
                Image(systemName: "bell")
                    .font(.system(size: 15, weight: .regular))
                    .overlay(alignment: .topTrailing) {
                        if appState.unreadNotifications > 0 {
                            TBBadge(count: appState.unreadNotifications)
                        }
                    }
            }
            .buttonStyle(TBIconButtonStyle())
            .focusEffectDisabled()
            .help("Notificações")
            .captureFrame($notifsOrigin)
            // The toast is no longer painted over the bell — it
            // drops in BELOW the head bar (see the top-trailing
            // overlay in `body`). This handler only feeds it.
            .onChange(of: appState.toastQueue) { _, queue in
                guard let next = queue.last else { return }
                bellPillTask?.cancel()
                bellPillNotif = next
                bellPillTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_500_000_000)
                    if !Task.isCancelled { collapseBellPill() }
                }
                Task { @MainActor in appState.toastQueue.removeAll() }
            }

            // ⚙ — settings
            Button { showSettings = true } label: {
                Image(systemName: "gear")
                    .font(.system(size: 15, weight: .regular))
            }
            .buttonStyle(TBIconButtonStyle())
            .focusEffectDisabled()
            .captureFrame($settingsOrigin)
        }
        // Leading clears the native macOS traffic lights with
        // 10px breathing room after them (was 93 → 103).
        // Trailing kept tight (12) so the gear sits near the
        // window edge.
        .padding(.leading, 103)
        .padding(.trailing, 12)
        // Invisible ⌘R sync trigger. Lives in a zero-impact
        // BACKGROUND (not as an HStack child) — as a sibling it
        // inherited the HStack's 26pt spacing, leaving a big
        // dead gap to the right of the gear.
        .background(
            Button { Task { await appState.sync() } } label: { EmptyView() }
                .buttonStyle(.plain)
                .opacity(0)
                .accessibilityHidden(true)
                .keyboardShortcut("r", modifiers: .command)
        )
        .frame(maxHeight: .infinity, alignment: .center)
        // The chrome IS the rule — a single hairline along the
        // band's bottom edge, no frosted material.
        .overlay(alignment: .bottom) {
            Rectangle().fill(Editorial.rule).frame(height: 1)
        }
    }

    // MARK: - Main content

    private var mainContent: some View {
        // EditorialMainV2: a clean proportional split —
        // `gridTemplateColumns: '1fr 1.05fr'` (timeline | tasks)
        // with a single hairline rule between. No resizable
        // handle, no edge-fade masks (those were Liquid-Glass
        // affordances); the redesign is a fixed two-column
        // spread that scales with the window.
        GeometryReader { geo in
            let total     = max(1, geo.size.width)
            let timelineW = (total - 1) * (1.0 / 2.05)
            HStack(spacing: 0) {
                TimelineView()
                    .frame(width: timelineW)
                Rectangle()
                    .fill(Editorial.rule)
                    .frame(width: 1)
                TaskListView()
                    .frame(maxWidth: .infinity)
            }
        }
    }

}

// MARK: - Glass Capsule container

struct GlassCapsule<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(.regularMaterial, in: Capsule())
            .liquidGlassEdge(Capsule())
    }
}

// MARK: - Liquid Glass edge modifier
//
// Adds a top-bright → bottom-dim white gradient stroke (specular highlight,
// like macOS Control Center) plus a soft layered drop shadow.

extension View {
    func liquidGlassEdge<S: InsettableShape>(_ shape: S) -> some View {
        self
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.55),
                            .white.opacity(0.18),
                            .white.opacity(0.05)
                        ],
                        startPoint: .top,
                        endPoint:   .bottom
                    ),
                    lineWidth: 0.6
                )
                .allowsHitTesting(false)   // decorative — let clicks pass through to button
            }
            .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
            .shadow(color: .black.opacity(0.04), radius: 1, x: 0, y: 1)
    }

    /// "Control Center"–style glass treatment, used for floating popups.
    /// Light blur lets ambient color bleed through, a pronounced specular
    /// top edge gives the bevel, and layered drop shadows add depth.
    func popupGlass<S: InsettableShape>(_ shape: S) -> some View {
        self
            // 1. Light frosted blur — like Control Center, mostly transparent
            .background(.ultraThinMaterial, in: shape)
            .clipShape(shape)
            // 2. Soft inner gradient — bright top → subtle darken at bottom
            .overlay {
                shape
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.06), location: 0.00),
                                .init(color: .clear,                location: 0.40),
                                .init(color: .clear,                location: 0.70),
                                .init(color: .black.opacity(0.03), location: 1.00),
                            ],
                            startPoint: .top,
                            endPoint:   .bottom
                        )
                    )
                    .allowsHitTesting(false)
            }
            // 3. Specular top highlight — bright bevel that catches light
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
            // 4. Layered drop shadows — close definition + deep ambient
            .shadow(color: .black.opacity(0.30), radius: 32, x: 0, y: 18)
            .shadow(color: .black.opacity(0.14), radius: 8,  x: 0, y: 4)
            .shadow(color: .black.opacity(0.08), radius: 1,  x: 0, y: 1)
    }

    /// Same chrome as `popupGlass` but **without** the outer
    /// `clipShape`. On macOS 26 the combination of `.clipShape(_)` +
    /// a nested `NSScrollView` (used by SwiftUI `ScrollView`) crashes
    /// inside `computed_effectiveCornerRadii` the moment the scroll
    /// view's host first joins the window — `NSViewGetTransformToDescendant`
    /// asserts because the corner-config lookup walks across views
    /// that aren't direct descendants in the rendering order it
    /// expects. The `.background(_, in: shape)` already paints the
    /// material in the rounded shape, so dropping the clip preserves
    /// the visual look as long as the popover's content respects its
    /// own padding (it does — header/footer/sections live inside the
    /// rounded area thanks to the inner padding).
    func popupGlassUnclipped<S: InsettableShape>(_ shape: S) -> some View {
        self
            .background(.ultraThinMaterial, in: shape)
            .overlay {
                shape
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.06), location: 0.00),
                                .init(color: .clear,                location: 0.40),
                                .init(color: .clear,                location: 0.70),
                                .init(color: .black.opacity(0.03), location: 1.00),
                            ],
                            startPoint: .top,
                            endPoint:   .bottom
                        )
                    )
                    .allowsHitTesting(false)
            }
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
    }
}

// MARK: - Frosted strip with soft bottom fade
//
// Shared between the top toolbar (ContentView) and the filter bar
// (TaskListView). Both pass their bar height; the fade extent below is
// always the same (30pt) so the soft transition looks identical.

struct FrostedStrip: View {
    let barHeight: CGFloat
    /// Total fade height. Mirrors the bottom-edge fade in
    /// `TimelineView`; same 2-stop gradient style so the
    /// two scrolling regions look related.
    var fadeExtent: CGFloat = 120

    var body: some View {
        // 3-stop linear gradient using the window's bg
        // colour. The TOOLBAR REGION (top ~barHeight of the
        // strip) stays fully opaque so content scrolling
        // up disappears completely under the pills, then
        // the lower section softly fades to clear so the
        // body's first row reads continuously.
        // Single GPU rasterisation, no per-frame backdrop
        // sampling.
        // Editorial: the chrome is paper, not a frosted/glass
        // blur. Solid cream over the toolbar band, then a short
        // soft fade so content scrolling up dissolves into the
        // paper instead of hard-clipping under a hairline.
        let bg = Editorial.paper
        let total = barHeight + fadeExtent
        let solidStop = barHeight / total
        LinearGradient(
            stops: [
                .init(color: bg.opacity(1.00), location: 0.00),
                .init(color: bg.opacity(1.00), location: solidStop),
                .init(color: bg.opacity(0.00), location: 1.00),
            ],
            startPoint: .top,
            endPoint:   .bottom
        )
        .frame(height: total)
        .allowsHitTesting(false)
        .drawingGroup()
    }
}

// MARK: - Apple Intelligence-style edge glow

/// Neon glow that hugs the window perimeter with a continuously
/// rotating Apple-Intelligence-style angular gradient. Used as
/// the back layer for the AI chat overlay so the user feels the
/// whole window "wake up" when Apollo IA opens — same vibe as
/// the iPhone Apple Intelligence activation moment.
///
/// Implementation: a thick rounded-rectangle stroke filled with
/// a rotating `AngularGradient`, blurred heavily and composited
/// with `.plusLighter` so the colours bloom instead of just
/// painting on. Two stacked layers (a sharper inner ring + a
/// softer outer halo) give the bloom depth without resorting to
/// a Metal shader.
/// Animatable Gaussian-blur modifier so a `.modifier` transition
/// can interpolate the radius — used for the AI window's
/// blur-in / blur-out entrance & exit.
private struct BlurModifier: ViewModifier, Animatable {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }
    func body(content: Content) -> some View {
        content.blur(radius: max(0, radius))
    }
}

private struct IntelligenceEdgeGlow: View {
    /// Drives the iPhone-Apple-Intelligence-style activation
    /// animation. 0 = pre-appear (invisible). 1 = settled
    /// ambient state.
    @State private var activation: CGFloat = 0
    /// Brief over-saturation pulse during the burst phase
    /// (0 → 1 → 0). Mirrors the bright "wake up" beat in
    /// iPhone's Apple Intelligence intro.
    @State private var burstPulse: CGFloat = 0

    /// Apple Intelligence palette — soft purple → magenta →
    /// orange → cyan → indigo. Wrapped to itself so the angular
    /// gradient seam disappears at the gradient boundary.
    private let palette: [Color] = [
        Color(red: 0.55, green: 0.35, blue: 0.95),
        Color(red: 0.95, green: 0.40, blue: 0.65),
        Color(red: 1.00, green: 0.65, blue: 0.30),
        Color(red: 0.40, green: 0.80, blue: 1.00),
        Color(red: 0.55, green: 0.35, blue: 0.95),
    ]

    var body: some View {
        GeometryReader { geo in
            // PERF — DEFINITIVE FIX: the previous TimelineView
            // re-rendered the AngularGradient + Gaussian blur
            // (window-sized: ~7M pixels, sin/cos per pixel +
            // O(radius²) blur per pixel) at 30Hz, saturating
            // the GPU and starving the WindowServer's budget
            // for compositing OTHER apps' windows — visible as
            // a system-wide framerate drop.
            //
            // Now: gradient + blur are rasterized exactly ONCE
            // via `.drawingGroup()`, which forces SwiftUI to
            // render the layer to a single Metal-backed
            // texture cached by Core Animation. Per-frame cost
            // = a textured quad composite, which is what the
            // GPU does for every static layer in the system.
            //
            // The continuous rotation was dropped — without
            // per-frame redraws, animating the AngularGradient
            // angle would invalidate the cache every tick.
            // The entrance scale/opacity/burst-pulse still
            // animate (those are CA transforms applied to the
            // cached texture, free) so the "Apple Intelligence
            // wakes up" beat is preserved.
            edgeRing(
                size: geo.size,
                strokeWidth: 16,
                blurRadius:  20
            )
            .drawingGroup()
            // Softer/thinner edge: stroke 28→16, blur 12→20,
            // resting opacity 0.85→0.55. The wider blur over a
            // narrower stroke produces a feather-soft halo
            // instead of a defined neon trim, while still
            // burst-pulsing brighter during the entrance beat.
            .opacity(0.55 + Double(burstPulse) * 0.30)
            .scaleEffect(1.0 + (1 - activation) * 0.04)
            .opacity(Double(activation))
            .onAppear {
                // Activation phase 1 — fast spring scale +
                // opacity entrance.
                withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
                    activation = 1
                }
                // Activation phase 2 — burst pulse.
                withAnimation(.easeOut(duration: 0.35)) {
                    burstPulse = 1
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(.easeIn(duration: 0.7)) {
                        burstPulse = 0
                    }
                }
            }
        }
    }

    private func edgeRing(size: CGSize,
                          strokeWidth: CGFloat,
                          blurRadius:  CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .inset(by: strokeWidth / 2)
            .stroke(
                AngularGradient(
                    colors: palette,
                    center: .center,
                    angle: .degrees(0)
                ),
                lineWidth: strokeWidth
            )
            .frame(width: size.width, height: size.height)
            .blur(radius: blurRadius)
    }
}
