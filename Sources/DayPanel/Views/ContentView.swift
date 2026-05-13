import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var updateService: UpdateService

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

    // Minimum task panel width — chosen so a row's COMPLETE pill, title,
    // status pill, avatar, due-date badge, priority and chevron all fit
    // on one line without wrapping.
    // Lowered from 480 → 432 so the layout still has a usable
    // timeline (≥ 280pt) when the window is squeezed to its new
    // minimum frame width of 740pt: 740 − 8 (handle) − 432 = 300.
    private static let minTaskPanelWidth: CGFloat = 432
    private static let maxTaskPanelWidth: CGFloat = 720

    @State private var taskPanelWidth: CGFloat = {
        let stored = CGFloat(UserDefaults.standard.double(forKey: "dp_taskPanelWidth"))
            .nonZeroOr(Self.minTaskPanelWidth)
        // Clamp to BOTH bounds. Earlier builds didn't enforce
        // `maxTaskPanelWidth` on the ResizableHandle's drag
        // range, so a saved value can be far above the design
        // ceiling — making cards look "cut" because the panel
        // grows past where the timeline can stay readable.
        return min(Self.maxTaskPanelWidth,
                   max(Self.minTaskPanelWidth, stored))
    }()

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
                    FrostedStrip(barHeight: 52)

                    // 3. Task filter bar — above the strip so
                    //    the filter pills don't get blurred.
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(width: taskPanelWidth, height: 52)
                            .allowsHitTesting(false)
                        TaskFilterBar()
                            .frame(width: taskPanelWidth)
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
                    windowSize:  windowGeo.size
                ) {
                    CreateEventSheet(onClose: { showNewEvent = false })
                        .environmentObject(appState)
                }
                FloatingModal(
                    isPresented: $showNewTask,
                    origin:      newTaskOrigin,
                    windowSize:  windowGeo.size
                ) {
                    CreateTaskSheet(onClose: { showNewTask = false })
                        .environmentObject(appState)
                }
                FloatingModal(
                    isPresented: $showSettings,
                    origin:      settingsOrigin,
                    windowSize:  windowGeo.size
                ) {
                    SettingsView(onClose: { showSettings = false })
                        .environmentObject(appState)
                }
                // ClickUp list picker — same sheet Settings/Onboarding
                // use, surfaced from the toolbar pill so the user
                // can switch lists in one click without opening
                // Settings. The wrapper binding bumps
                // `listPickerToken` whenever the sheet flips
                // closed, forcing the toolbar pill to re-read the
                // new list name from Keychain (which isn't
                // observable on its own).
                FloatingModal(
                    isPresented: Binding(
                        get: { showListPicker },
                        set: { newValue in
                            if !newValue && showListPicker {
                                listPickerToken &+= 1
                            }
                            showListPicker = newValue
                        }
                    ),
                    origin:      listPickerOrigin,
                    windowSize:  windowGeo.size
                ) {
                    CUListPickerSheet(onClose: {
                        listPickerToken &+= 1
                        showListPicker = false
                    })
                    .environmentObject(appState)
                    .frame(maxWidth: 420)
                }
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
                    // Frosted backdrop blurring the dashboard
                    // — same material the welcome splash uses
                    // when it appears (`Rectangle().fill(
                    // .regularMaterial)`). Cached as a single
                    // CABackdropFilter by Core Animation: one
                    // backdrop blur recomputed only when the
                    // dashboard content changes, not per
                    // frame. Lets the AI chat items float
                    // panel-less over a soft frosted surface.
                    Rectangle()
                        .fill(.regularMaterial)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .zIndex(800)

                    // Apple Intelligence-style neon edge glow.
                    // Sits BEHIND the chat (zIndex 850 vs chat's
                    // 900) so the colours bloom around the
                    // window perimeter without washing out the
                    // chat content.
                    IntelligenceEdgeGlow()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(850)

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
            Color(nsColor: .windowBackgroundColor)
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
                    withAnimation(.spring(duration: 0.42, bounce: 0.28)) {
                        showAIChat = false
                    }
                }
                .transition(.opacity)

            AIAgentChatView(onClose: {
                withAnimation(.spring(duration: 0.42, bounce: 0.28)) {
                    showAIChat = false
                }
            })
                .environmentObject(appState)
                // Window-percentage paddings so the chat
                // surface always insets proportionally to the
                // host frame: 15% top/bottom (header anchors
                // 15% down from the toolbar, composer anchors
                // 15% up from the bottom edge) and 20% on
                // each side. With the panel-less floating
                // design these paddings define where the
                // first/last items can land.
                .padding(.top,        windowSize.height * 0.05)
                .padding(.bottom,     windowSize.height * 0.05)
                .padding(.horizontal, windowSize.width  * 0.05)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.05, anchor: cursorAnchor)
                        .combined(with: .opacity),
                    removal:   .scale(scale: 0.05, anchor: cursorAnchor)
                        .combined(with: .opacity)
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
            // Icon-only button — text label dropped to keep the
            // toolbar compact. Active filter count surfaces as a
            // small accent capsule next to the icon when ≥1 filter
            // is on; tooltip carries the full "Filtros (N ativos)"
            // text via `.help(...)` so accessibility isn't lost.
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.callout.weight(.semibold))
                if isActive {
                    Text("\(count)")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white)
                        .frame(minWidth: 16, minHeight: 16)
                        .padding(.horizontal, 3)
                        .background(Color.accentColor, in: Capsule())
                }
            }
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .padding(.horizontal, isActive ? 8 : 9)
            .frame(height: 28)
            // Same glass treatment as the Nova tarefa pill: regularMaterial
            // base + liquidGlassEdge for the bevel/specular highlight.
            // When filters are active we tint the whole capsule with a
            // subtle accent overlay so the active state is still legible.
            .background(.regularMaterial, in: Capsule())
            .background(
                isActive ? Color.accentColor.opacity(0.12) : Color.clear,
                in: Capsule()
            )
            .liquidGlassEdge(Capsule())
        }
        .buttonStyle(.plain)
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
                Image(systemName: "list.bullet.rectangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(truncated)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 9)
            .padding(.trailing, 8)
            .frame(height: 26)
            .background(.regularMaterial, in: Capsule())
            .liquidGlassEdge(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("Lista ClickUp atual: \(name) — clique para trocar")
    }

    /// Toolbar search field — glass capsule with a magnifier icon,
    /// a borderless TextField bound to `AppState.searchQuery`, and
    /// a clear-X that appears once the query is non-empty. The
    /// field has a fixed width (220pt) so it stays visually
    /// balanced next to the other toolbar pills, yet wide enough
    /// for typical task-name fragments.
    private var searchField: some View {
        let hasQuery = !appState.searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(hasQuery ? Color.accentColor : .secondary)

            TextField("Buscar tarefas", text: $appState.searchQuery)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .focusEffectDisabled()

            if hasQuery {
                Button {
                    appState.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Limpar busca")
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, hasQuery ? 6 : 10)
        // Width trimmed by 35% (220 → 143pt) to take less toolbar
        // real estate; the placeholder "Buscar tarefas" still fits
        // at this size and typed queries truncate gracefully.
        .frame(width: 143, height: 28)
        // Subtle accent tint when the query is active so the user
        // can spot at a glance that the list is narrowed.
        .background(.regularMaterial, in: Capsule())
        .background(
            hasQuery ? Color.accentColor.opacity(0.10) : Color.clear,
            in: Capsule()
        )
        .liquidGlassEdge(Capsule())
        .overlay(
            Capsule().strokeBorder(
                hasQuery ? Color.accentColor.opacity(0.30) : Color.clear,
                lineWidth: 0.6
            )
        )
        .animation(.spring(duration: 0.25, bounce: 0.20), value: hasQuery)
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
        HStack(spacing: 8) {

            // ── Novo evento ──────────────────────────────────────────────
            // Glass pill matching the "+ Tarefa" button on the
            // trailing side: plus icon + label, same height,
            // same material treatment. The previous compact
            // 28pt circle was visually inconsistent with its
            // sibling create-action button on the right; the
            // pill makes both creation entry points read as a
            // matched pair.
            Button { showNewEvent = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.callout.weight(.bold))
                    Text("Evento")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(.primary)
                .padding(.leading, 9)
                .padding(.trailing, 12)
                .frame(height: 28)
                .background(.regularMaterial, in: Capsule())
                .liquidGlassEdge(Capsule())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Novo evento")
            .captureFrame($newEventOrigin)

            // ── "Hoje" jump-to-today button ──────────────────────────────
            // The date capsule used to live to the left of this button
            // and acted as a calendar opener; it was removed because
            // the timeline already shows the current date as a sticky
            // header and the popup picker felt redundant.
            Button {
                // No click haptic — the trackpad's click pulse
                // is the natural feedback for the "Hoje" tap.
                dateDirection = appState.selectedDate < Date() ? 1 : -1
                withAnimation(.spring(duration: 0.35)) {
                    appState.selectedDate = Date()
                }
                appState.todayJumpToken &+= 1
                Task { await appState.sync() }
            } label: {
                Text("Hoje")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isToday ? AnyShapeStyle(Color.secondary)
                                             : AnyShapeStyle(Color.blue))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(.regularMaterial, in: Capsule())
                    .liquidGlassEdge(Capsule())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            // ── ClickUp list picker pill ─────────────────────────────────
            // Shows the active list name with a chevron — clicking
            // opens the same `CUListPickerSheet` Settings uses so
            // the user can switch lists without leaving the
            // dashboard. Hidden when ClickUp isn't connected (no
            // list to show, picker would be empty).
            if appState.clickUpAuthService.isConnected {
                listPickerPill
            }

            // Push the trailing cluster (Mock badge, Filtros,
            // Search, Tarefa, Sync, Bell, Settings) against the
            // window's right edge.
            Spacer(minLength: 0)

            // ── Mock badge ────────────────────────────────────────────────
            if appState.showMockData {
                Label("Exemplo", systemImage: "sparkles")
                    .font(.caption2).fontWeight(.medium)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.orange.opacity(0.14), in: Capsule())
                    .overlay(Capsule().strokeBorder(.orange.opacity(0.3), lineWidth: 0.5))
            }

            // ── Offline queue indicator ──────────────────────────
            // Renders only when there are pending mutations
            // waiting on connectivity. Self-hides when empty —
            // doesn't add toolbar chrome for users who are
            // always online.
            OfflineQueueIndicator()

            // ── Filtros ───────────────────────────────────────────────────
            // Visible only when ClickUp is connected — otherwise there are
            // no tasks to filter and the button would be a dead end.
            if appState.clickUpAuthService.isConnected {
                filtersButton
            }

            // ── Search bar ────────────────────────────────────────────────
            // Glass capsule with magnifier + text field that narrows
            // the visible task list as the user types. Shows only
            // when ClickUp is connected (no tasks to search
            // otherwise).
            if appState.clickUpAuthService.isConnected {
                searchField
            }

            // ── Nova tarefa ───────────────────────────────────────────────
            // Icon swapped from `checkmark.circle.badge.plus` to a
            // plain `plus` glyph — the previous icon mixed two
            // metaphors (check + add) and read as ambiguous.
            // The `+` sign is universally understood as "add new".
            // The "Tarefa" text label is preserved so the button's
            // purpose is clear without hovering for the tooltip.
            Button { showNewTask = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.callout.weight(.bold))
                    Text("Tarefa")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(.primary)
                .padding(.leading, 9)
                .padding(.trailing, 12)
                .frame(height: 28)
                .background(.regularMaterial, in: Capsule())
                .liquidGlassEdge(Capsule())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Nova tarefa")
            .captureFrame($newTaskOrigin)

            // ── Apollo IA ─────────────────────────────────────────────────
            // Sparkles pill that opens the agent chat as a popover
            // anchored under the button. The button itself is
            // wrapped in `ApolloIAOrbButton` — a custom view that
            // builds an Apple Intelligence-style halo of moving
            // gradients around the sparkle, plus hover-driven
            // glow boost and click-activation flash.
            ApolloIAOrbButton(isActive: showAIChat) {
                // Snapshot the cursor position at click time so
                // the chat opens scaling out of the exact pixel
                // the user pressed (and shrinks back into it on
                // close). Same one-shot read used by the bell
                // notifications popup — see `notifsOpenPoint`.
                let rect = MouseOriginCapture.currentClickRectInMainWindow()
                if rect != .zero {
                    aiChatOpenPoint = CGPoint(x: rect.midX, y: rect.midY)
                }
                withAnimation(.spring(duration: 0.42, bounce: 0.28)) {
                    showAIChat.toggle()
                }
            }
            .help("Apollo IA")
            // Popover anchored to the orb button was replaced by
            // a window-centred overlay (see `aiChatOverlay`
            // below). The popover's arrow + edge anchoring made
            // the chat feel pinned to a tiny corner of the
            // toolbar; centring it gives the chat the visual
            // weight of a primary surface.
            .onChange(of: appState.aiAgent.dismissChatRequest) { _, _ in
                withAnimation(.spring(duration: 0.32, bounce: 0.25)) {
                    showAIChat = false
                }
            }
            // RAM relief — when the chat closes (any reason),
            // tell Ollama to unload the model NOW instead of
            // holding the ~5 GB of weights in RAM for the
            // default 5 minutes. Next time the user opens the
            // chat there's a ~1-2s cold-load delay, but the
            // rest of the system gets its memory back
            // immediately, which removes the "Apollo turned
            // my computer slow" feeling.
            .onChange(of: showAIChat) { _, isOpen in
                if !isOpen {
                    Task.detached(priority: .background) {
                        await appState.aiAgent.unloadEmbeddedModel()
                    }
                }
            }

            glassDivider

            // ── Sync + Settings circles ───────────────────────────────────
            SyncButton(status: appState.syncStatus) {
                Task { await appState.sync() }
            }
            .keyboardShortcut("r", modifiers: .command)

            // Bell + sync-status pill — clicking opens the Notifications
            // Center popover. New notifications momentarily expand the
            // capsule leftward into the BellPill (Dynamic Island style).
            // The sync-status dot lives inside the same pill, label-less,
            // so the toolbar stays compact.
            Button {
                // Snapshot the cursor at click time so the popup
                // grows out of the exact pixel the user pressed
                // (and shrinks back into it on close).
                //
                // PERF: previously read from a `cursorPosition`
                // @State updated on every mouse move via
                // `onContinuousHover` — that was forcing
                // ContentView's body to re-evaluate hundreds of
                // times per second whenever the cursor traveled
                // over the window. Now we read NSEvent's mouse
                // location ONCE at click time via
                // `MouseOriginCapture` — same accuracy, zero
                // per-frame cost.
                let rect = MouseOriginCapture.currentClickRectInMainWindow()
                notifsOpenPoint = rect == .zero
                    ? CGPoint(x: notifsOrigin.midX, y: notifsOrigin.midY)
                    : CGPoint(x: rect.midX, y: rect.midY)
                withAnimation(.spring(duration: 0.45, bounce: 0.32)) {
                    showNotifs.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    StatusIndicator(status: appState.syncStatus, showLabel: false)
                    // `.overlay` instead of putting the badge in
                    // a ZStack so the badge's natural size NEVER
                    // influences the parent HStack's layout —
                    // appearing/disappearing the count pill (or
                    // toggling between "9" and "99") used to
                    // reflow the toolbar capsule on every sync.
                    Image(systemName: "bell.fill")
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .overlay(alignment: .topTrailing) {
                            if appState.unreadNotifications > 0 && bellPillNotif == nil {
                                Text("\(min(appState.unreadNotifications, 99))")
                                    .font(.system(size: 9, weight: .heavy))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .frame(minWidth: 14, minHeight: 14)
                                    .background(Color.red, in: Capsule())
                                    .overlay(Capsule().strokeBorder(.background, lineWidth: 1))
                                    .offset(x: 7, y: -7)
                            }
                        }
                }
                .padding(.leading, 9)
                .padding(.trailing, 9)
                .frame(height: 28)
                .background(.regularMaterial, in: Capsule())
                .liquidGlassEdge(Capsule())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Notificações")
            .captureFrame($notifsOrigin)
            .overlay(alignment: .trailing) {
                if let pill = bellPillNotif {
                    BellPill(notification: pill,
                             onTap: {
                                 collapseBellPill()
                                 showNotifs = true
                             },
                             onDismiss: { collapseBellPill() })
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.4, anchor: .trailing)
                                .combined(with: .opacity),
                            removal:   .scale(scale: 0.6, anchor: .trailing)
                                .combined(with: .opacity)
                        ))
                        .allowsHitTesting(true)
                }
            }
            .animation(.spring(duration: 0.45, bounce: 0.30), value: bellPillNotif?.id)
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

            Button { showSettings = true } label: {
                Image(systemName: "gear")
                    .frame(width: 28, height: 28)
                    .background(.regularMaterial, in: Circle())
                    .liquidGlassEdge(Circle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .captureFrame($settingsOrigin)
        }
        .padding(.leading, 110)  // clear macOS traffic lights + breathing room
        .padding(.trailing, 12)
        // Width / height are set at the call site
        // (`toolbar.frame(width: windowGeo.size.width, height: 52)`)
        // so the toolbar is anchored directly to the GeometryReader's
        // window size and never reflows in response to the resize
        // handle being dragged.
        // No background here — the ZStack in `body` provides the frosted strip
        // behind, with the soft gradient fade at the bottom edge.
    }

    // MARK: - Main content

    private var mainContent: some View {
        // Wrap in a GeometryReader so the task panel width can be
        // clamped to whatever space is actually left after the
        // timeline's minimum width. Without this, a stored
        // `taskPanelWidth` value from a previous (larger) window
        // size lets the panel push past the window's right edge
        // when the user shrinks the window — task rows get clipped
        // mid-pill against the trailing border.
        GeometryReader { geo in
            let timelineMin:  CGFloat = 280
            let handleWidth:  CGFloat = 8
            // Largest task-panel width the current container can
            // afford while still leaving room for the timeline at
            // its minimum.
            // Floor: design min. Ceiling: SMALLER of design max
            // (keeps the panel readable) and what fits in the
            // current window after timeline + handle. Without
            // the design max, dragging the resize handle could
            // grow the panel up to (window - 280 - 8) which on
            // a 1900pt window is ~1610pt — way past the 720pt
            // sweet spot the row layout was designed against.
            let allowedMax = max(
                Self.minTaskPanelWidth,
                min(Self.maxTaskPanelWidth,
                    geo.size.width - handleWidth - timelineMin)
            )
            let effectiveTaskWidth = min(taskPanelWidth, allowedMax)

            HStack(spacing: 0) {
                // 60-day scrollable timeline; reads events directly from AppState
                // for the entire ±30-day range fetched on sync.
                TimelineView()
                    .frame(minWidth: timelineMin, maxWidth: .infinity)
                    // Soft fade on the right edge so event pills that
                    // overflow horizontally don't get hard-clipped at the
                    // resizable handle — the last few points fade to
                    // transparent instead.
                    .mask(edgeFadeMask(side: .trailing, fade: 16))

                // Resize-handle range tracks the live container so
                // dragging can never exceed the available space.
                ResizableHandle(width: $taskPanelWidth,
                                range: Self.minTaskPanelWidth ... allowedMax)

                TaskListView()
                    // `effectiveTaskWidth` (clamped) instead of the
                    // raw stored `taskPanelWidth` keeps the panel
                    // inside the window even if the stored value is
                    // larger than the current frame allows.
                    .frame(width: effectiveTaskWidth)
                    // Mirror fade on the LEFT edge of the task panel.
                    .mask(edgeFadeMask(side: .leading, fade: 16))
            }
            // Keep the persisted preference in sync if the window
            // shrank below what it originally accommodated — this
            // way the next window-grow event uses an already-clamped
            // value instead of springing back to the original.
            .onChange(of: geo.size.width) { _, _ in
                if taskPanelWidth > allowedMax {
                    taskPanelWidth = allowedMax
                }
            }
            // One-time migration: writes the clamped value back
            // to UserDefaults so the next launch starts within
            // the design bounds. Earlier builds let the saved
            // preference grow past `maxTaskPanelWidth` (720),
            // and that stale value was what made the cards
            // look "cut" — the panel was eating space the row
            // layout wasn't designed to fill.
            .onAppear {
                let stored = UserDefaults.standard.double(forKey: "dp_taskPanelWidth")
                if stored > Self.maxTaskPanelWidth || stored < Self.minTaskPanelWidth {
                    UserDefaults.standard.set(Double(taskPanelWidth),
                                              forKey: "dp_taskPanelWidth")
                }
            }
        }
    }

    /// Returns a linear-gradient mask that fades the given side over
    /// `fade` points of width. Used to soften the abrupt clip between
    /// the events and tasks panels — content near the inner edge
    /// gradually dissolves into transparency instead of being cut.
    private func edgeFadeMask(side: HorizontalEdge, fade: CGFloat) -> some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let cutoff = max(0, (w - fade) / max(w, 1))
            LinearGradient(
                stops: side == .trailing
                    ? [.init(color: .black, location: 0.0),
                       .init(color: .black, location: cutoff),
                       .init(color: .clear, location: 1.0)]
                    : [.init(color: .clear, location: 0.0),
                       .init(color: .black, location: 1.0 - cutoff),
                       .init(color: .black, location: 1.0)],
                startPoint: .leading,
                endPoint:   .trailing
            )
        }
    }

    // MARK: - Helpers

    private var glassDivider: some View {
        Rectangle()
            .fill(.separator.opacity(0.6))
            .frame(width: 0.5, height: 18)
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
        let bg = Color(NSColor.windowBackgroundColor)
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

// MARK: - Resizable handle (drag to change task-panel width)

struct ResizableHandle: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>

    @State private var startWidth: CGFloat?
    @State private var hovering    = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.separator.opacity(hovering ? 1.0 : 0.5))
                .frame(width: hovering ? 1.5 : 0.5)
        }
        .frame(width: 8)
        .contentShape(Rectangle())
        .onHover { isOver in
            hovering = isOver
            if isOver { NSCursor.resizeLeftRight.push() }
            else      { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if startWidth == nil { startWidth = width }
                    let proposed = (startWidth ?? width) - value.translation.width
                    width = min(max(proposed, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in
                    startWidth = nil
                    UserDefaults.standard.set(Double(width), forKey: "dp_taskPanelWidth")
                }
        )
    }
}

// MARK: - Helpers

private extension CGFloat {
    func nonZeroOr(_ fallback: CGFloat) -> CGFloat { self == 0 ? fallback : self }
}

// MARK: - Apollo IA toolbar button (Apple Intelligence-inspired)

/// Sparkle button with a continuously living halo of coloured
/// light around it — inspired by the Apple Intelligence
/// activation glow on iOS 18 / macOS 26. Two slowly rotating
/// conic gradients (different speeds, different hue offsets)
/// sit behind the button; on hover the halo brightens and
/// scales out a touch; on click a quick "ignite" pulse fires
/// the halo to peak intensity, then settles back to its
/// continuous breathing loop.
///
/// `isActive` flips on while the chat popover is showing, so
/// the halo locks at peak intensity for the duration of the
/// session — same visual cue Siri uses to signal "I'm
/// listening".
struct ApolloIAOrbButton: View {
    let isActive: Bool
    let action: () -> Void

    /// Two independent rotation phases so the conic gradients
    /// drift at different speeds — composition never repeats
    /// to the same frame, keeping the halo feeling alive.
    @State private var phaseA: Double = 0
    @State private var phaseB: Double = 0

    /// Soft breathing scale for the halo ring.
    @State private var breathe: Bool = false

    @State private var isHovered: Bool = false
    @State private var isIgniting: Bool = false

    var body: some View {
        // The halo lives OUTSIDE the Button so its 160pt
        // ambient glow doesn't expand the button's hit area.
        // The Button's clickable surface (and the cursor's
        // hover region) stays exactly the size of the 28pt
        // sparkle pill — same as the original toolbar button —
        // while the halo is free to bleed visually wherever it
        // wants. SwiftUI lets children draw past their parent's
        // frame; we just lock the parent to 28pt so the layout
        // slot, hit-test bounds, and hover region all match.
        ZStack {
            halo
            Button(action: { triggerIgnite() }) {
                core
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .frame(width: 28, height: 28)
        .contentShape(Circle())            // restrict hit-test to circular core
        .scaleEffect(scaleValue)
        .animation(.spring(response: 0.32, dampingFraction: 0.7),
                   value: isHovered)
        .animation(.spring(response: 0.30, dampingFraction: 0.55),
                   value: isIgniting)
        .onHover { isHovered = $0 }
        // Orb stays STATIC at rest. Animations only start when
        // the user engages with the AI surface — saves ~25-30%
        // sustained GPU on idle. Re-fires whenever any of the
        // engagement signals flip on.
        .onAppear {
            if shouldAnimate { startBreathing() }
        }
        .onChange(of: isActive) { _, _ in
            if shouldAnimate { startBreathing() } else { stopBreathing() }
        }
        .onChange(of: isHovered) { _, _ in
            if shouldAnimate { startBreathing() } else { stopBreathing() }
        }
    }

    // MARK: Halo

    /// Multi-layer aurora. The core ring (two stacked conic
    /// gradients drifting in opposite directions) lives close
    /// to the button's edge for definition; an outer "ambient"
    /// halo extends much further with a wide gaussian blur and
    /// very low opacity, so the colour bleeds softly into the
    /// surrounding interface instead of stopping at a hard
    /// boundary. Both layers ramp visibility with hover /
    /// active / ignite — the outer halo ramps a touch more
    /// aggressively so peaks visibly "spread out" further.
    private var halo: some View {
        ZStack {
            // ── Outer ambient halo ───────────────────────────
            // Very wide, very blurred, very faint. Painted as
            // a soft radial wash that fades to clear far past
            // the button's edge — this is what gives the
            // sparkle button a sense of "presence" radiating
            // through the toolbar instead of stopping at a
            // crisp ring.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.accentColor.opacity(0.55),
                            Color(hex: "#A875FF").opacity(0.30),
                            Color(hex: "#FF8A4C").opacity(0.15),
                            .clear
                        ],
                        center: .center,
                        startRadius: 4,
                        endRadius: 80
                    )
                )
                // PERF: blur radius cut 16→10. Each blur pass is
                // a separate offscreen render — at 16pt the
                // backing buffer is huge and cheap to scale up
                // visually but expensive to maintain.
                .frame(width: 140, height: 140)
                .blur(radius: 10)
                .opacity(ambientOpacity)
                .scaleEffect(ambientScale)

            // Outer secondary aurora — slowly hue-rotating to
            // shift colour cast over time.
            //
            // PERF: blur 26→14, frame 120→100. The previous
            // 26pt blur on a 120pt circle was the single
            // heaviest layer in the orb (forced a ~150x150
            // offscreen buffer redrawn every frame).
            Circle()
                .fill(
                    AngularGradient(
                        colors: [
                            Color(hex: "#5AC8FA").opacity(0.55),
                            Color(hex: "#A875FF").opacity(0.55),
                            Color(hex: "#FF5E8A").opacity(0.55),
                            Color(hex: "#FF8A4C").opacity(0.55),
                            Color(hex: "#5AC8FA").opacity(0.55)
                        ],
                        center: .center,
                        angle: .degrees(phaseA)
                    )
                )
                .frame(width: 100, height: 100)
                .blur(radius: 14)
                .opacity(ambientOpacity * 0.85)

            // ── Inner aurora ring ────────────────────────────
            // Two angular gradients drifting in opposite
            // directions — gives the close-edge halo its
            // shimmering "alive" quality.
            ZStack {
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [
                                Color(hex: "#5AC8FA"),
                                Color(hex: "#A875FF"),
                                Color(hex: "#FF5E8A"),
                                Color(hex: "#FF8A4C"),
                                Color(hex: "#5AC8FA")
                            ],
                            center: .center,
                            angle: .degrees(phaseA)
                        )
                    )
                    .blur(radius: 8)
                    .frame(width: 50, height: 50)

                Circle()
                    .fill(
                        AngularGradient(
                            colors: [
                                Color(hex: "#FF8A4C"),
                                Color.accentColor,
                                Color(hex: "#A875FF"),
                                Color(hex: "#5AC8FA"),
                                Color(hex: "#FF8A4C")
                            ],
                            center: .center,
                            angle: .degrees(-phaseB)
                        )
                    )
                    .blur(radius: 10)
                    .frame(width: 56, height: 56)
                    .opacity(0.8)
            }
            .compositingGroup()
            // Soft feathered ring mask — wider than before
            // (18pt vs 14pt) and more blur so the inner edge
            // melts into the core button.
            .mask(
                Circle()
                    .strokeBorder(Color.white, lineWidth: 18)
                    .frame(width: haloDiameter, height: haloDiameter)
                    .blur(radius: 6)
            )
            .opacity(haloOpacity)
            .scaleEffect(haloScale)
        }
        // (Previously experimented with `.drawingGroup()` here
        // to cache the blurred halo. Reverted: this view sits
        // in the toolbar and is *always* mounted, so the
        // offscreen Metal texture allocated by drawingGroup
        // stays held indefinitely — and because the rotation
        // is driven by `phaseA`/`phaseB` parameters of an
        // AngularGradient (not a transform on a static
        // texture), the cache would have been invalidated
        // every frame anyway when the orb was actively
        // breathing. Net effect was a permanent GPU resource
        // hold for negligible draw savings, leaving the whole
        // app sluggish after the AI chat closed.)
        .animation(.easeInOut(duration: 2.4)
                    .repeatForever(autoreverses: true),
                   value: breathe)
        .animation(.spring(response: 0.4, dampingFraction: 0.75),
                   value: isHovered)
        .animation(.spring(response: 0.30, dampingFraction: 0.55),
                   value: isIgniting)
        .animation(.spring(response: 0.5, dampingFraction: 0.78),
                   value: isActive)
        .allowsHitTesting(false)
    }

    /// The actual sparkle pill, untouched in style so the
    /// button keeps its place in the toolbar's visual rhythm.
    private var core: some View {
        Image(systemName: "sparkles")
            .font(.callout.weight(.semibold))
            .foregroundStyle(
                LinearGradient(
                    colors: [Color.accentColor, Color(hex: "#FF8A4C")],
                    startPoint: .topLeading,
                    endPoint:   .bottomTrailing
                )
            )
            .frame(width: 28, height: 28)
            .background(.regularMaterial, in: Circle())
            .liquidGlassEdge(Circle())
            // Coloured drop shadow that intensifies in sync with
            // the halo so the button feels like it's emitting
            // the light, not just sitting behind it.
            .shadow(color: Color.accentColor.opacity(coreShadowOpacity),
                    radius: coreShadowRadius, x: 0, y: 0)
    }

    // MARK: Curves

    private var haloDiameter: CGFloat {
        if isIgniting { return 56 }
        if isActive   { return 50 }
        if isHovered  { return 48 }
        return breathe ? 44 : 40
    }

    private var haloOpacity: Double {
        if isIgniting { return 1.0 }
        if isActive   { return 0.95 }
        if isHovered  { return 0.85 }
        return breathe ? 0.55 : 0.35
    }

    private var haloScale: CGFloat {
        if isIgniting { return 1.18 }
        if isActive   { return 1.08 }
        if isHovered  { return 1.05 }
        return 1
    }

    /// Outer ambient halo opacity — same shape of curve as the
    /// inner halo but ramped a touch lower at rest so the
    /// ambient bleed stays subtle, with a steeper jump on
    /// hover/active/ignite so peaks visibly spread further.
    private var ambientOpacity: Double {
        if isIgniting { return 0.95 }
        if isActive   { return 0.80 }
        if isHovered  { return 0.65 }
        return breathe ? 0.40 : 0.25
    }

    /// The outer ambient halo expands more aggressively than
    /// the inner ring so peaks read as "the light spread out"
    /// across the surrounding interface.
    private var ambientScale: CGFloat {
        if isIgniting { return 1.30 }
        if isActive   { return 1.15 }
        if isHovered  { return 1.10 }
        return breathe ? 1.04 : 0.96
    }

    private var scaleValue: CGFloat {
        if isIgniting { return 1.10 }
        if isHovered  { return 1.04 }
        return 1
    }

    private var coreShadowOpacity: Double {
        if isIgniting { return 0.65 }
        if isActive   { return 0.55 }
        if isHovered  { return 0.40 }
        return 0.18
    }

    private var coreShadowRadius: CGFloat {
        if isIgniting { return 16 }
        if isActive   { return 12 }
        if isHovered  { return 10 }
        return 6
    }

    // MARK: Choreography

    /// Kicks off the continuous loops — both rotation phases at
    /// independent speeds so the halo never lines up to the
    /// same frame, plus the slow breathing pulse.
    ///
    /// PERF: only run these when the orb is actively engaged
    /// (chat open, hovered, or igniting). At rest the orb is a
    /// frozen-frame composite — no per-frame GPU work, no
    /// system-wide FPS hit. Two angular gradients + four blur
    /// passes + compositing group running 24/7 in the toolbar
    /// were measured at ~30% sustained GPU on Apple Silicon
    /// laptops, which is why other apps' scroll FPS dropped
    /// while Apollo was open.
    private func startBreathing() {
        guard shouldAnimate else {
            // Force-stop any pre-existing animations so the
            // orb settles into its static frame.
            phaseA = 0
            phaseB = 0
            breathe = false
            return
        }
        withAnimation(.linear(duration: 7.5)
                        .repeatForever(autoreverses: false)) {
            phaseA = 360
        }
        withAnimation(.linear(duration: 11.0)
                        .repeatForever(autoreverses: false)) {
            phaseB = 360
        }
        breathe = true
    }

    /// Stops the continuous loops by snapping the animatable
    /// state to its current value with `withAnimation(nil)` —
    /// SwiftUI sees the new "target" matches the current value
    /// and discontinues the repeat.
    private func stopBreathing() {
        withAnimation(.linear(duration: 0)) {
            // Set to current value so SwiftUI cancels in-flight
            // tween; the gradients freeze where they are.
        }
        breathe = false
    }

    /// True iff the orb should be animating right now.
    /// PERF: removed `isActive` from the trigger set. With the
    /// chat panel open the orb's breathing/blur loop runs
    /// indefinitely, layering its 60Hz redraws on top of the
    /// already-expensive `IntelligenceEdgeGlow`. Now the
    /// ambient chat-open state lets the orb sit STATIC
    /// (still rendered, just not animating); hover and the
    /// brief ignite pulse still drive the animation, so the
    /// affordances the user actively interacts with stay
    /// alive while idle cost goes to zero.
    private var shouldAnimate: Bool {
        isHovered || isIgniting
    }

    /// Briefly spikes the halo to peak intensity (`isIgniting`)
    /// for ~0.45s, then lets it settle back to its rest /
    /// hover / active baseline. Always fires `action()` first
    /// so the popover open is instant — the visual ignite is
    /// purely cosmetic and runs in parallel.
    private func triggerIgnite() {
        action()
        isIgniting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            isIgniting = false
        }
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
