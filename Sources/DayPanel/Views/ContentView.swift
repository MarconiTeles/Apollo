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
    /// Upload pills can be dismissed independently without cancelling the
    /// transfer. The id only lives for this ContentView session.
    @State private var dismissedUploadPillIDs: Set<UUID> = []
    /// Once the user closes the onboarding manually we don't reopen it
    /// during the same session — but a fresh launch re-evaluates the
    /// connections from scratch.
    @State private var onboardingDismissedThisSession = false

    // ── Editorial+ sidebar (Stage 1, isolated to the left)
    @State private var sidebarRoute:   SidebarRoute = .today
    @State private var sidebarListFilter: String? = nil

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
            || appState.commandPaletteOpen
            || showNewEvent
            || showNewTask
            || showSettings
            || showListPicker
            || showOnboarding
            || showWelcome
            || showNotifs
            || showFilters
            || showAIChat
            || reviewPresenter.request != nil
    }

    var body: some View {
        GeometryReader { windowGeo in
            ZStack(alignment: .topTrailing) {
                // Editorial canvas was painted full-window here
                // before — with the Editorial+ sidebar's Liquid
                // Glass pane we want the window genuinely
                // translucent under the sidebar column, so the
                // paper fill is moved down into the chrome side
                // (see the ZStack wrapping `Group` below) and
                // the sidebar gets `Color.clear` as its surface.
                Color.clear.ignoresSafeArea()

                // ── Paper backstop ──────────────────────────────
                // OUTERMOST paper layer, painted full-window edge-
                // to-edge (right of the 220pt sidebar column) so
                // it covers the macOS title-bar zone too. Lives
                // here — NOT nested inside the chrome ZStack —
                // because nested `.ignoresSafeArea` doesn't always
                // overflow when the parent ZStack's bounds are
                // already pinned by its own siblings. As a direct
                // child of the outermost ZStack with its own
                // `.ignoresSafeArea()`, the rectangle paints from
                // window y=0 down (covering the transparent title
                // bar) and prevents the desktop wallpaper from
                // bleeding through as a coloured aurora.
                // Keep the app canvas behind the sidebar. Native Liquid Glass
                // must refract Apollo's own content, not the desktop wallpaper:
                // exposing the window here pulled cyan/yellow scenery into the
                // pane and destroyed the neutral 1:1 sidebar design.
                Rectangle()
                    .fill(Editorial.paper)
                    .ignoresSafeArea()

                // Editorial+ redesign: the sidebar floats on TOP of
                // the chrome (ZStack overlay) instead of sharing an
                // HStack column with it. This lets the dashboard /
                // board content extend EDGE-TO-EDGE and pass behind
                // the Liquid Glass pane — through the translucent
                // material the user sees the page's actual content
                // (cards, paper, toolbar) instead of just the
                // desktop. The toolbar's pill cluster carries a
                // leading inset equal to the sidebar's column width
                // so the trailing buttons aren't hidden under it.
                ZStack(alignment: .topLeading) {

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
                ZStack(alignment: .top) {
                    // (Paper canvas now lives as a sibling of the
                    //  outer `Color.clear.ignoresSafeArea()` so it
                    //  covers the title-bar zone — see "Paper
                    //  backstop" comment above. Nothing painted
                    //  here on purpose.)
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
                    //    on top. Hidden on .board AND .tasks
                    //    (those surfaces carry their own
                    //    headers and don't want a blur band
                    //    cutting across their top).
                    if sidebarRoute != .board && sidebarRoute != .tasks
                        && sidebarRoute != .today && sidebarRoute != .assignedComments {
                        FrostedStrip(barHeight: 52, fadeExtent: 60)
                            .padding(.leading, 220)
                    }

                    // 3. Task filter bar — above the strip so
                    //    the filter pills don't get blurred.
                    //    Anchored to the SAME split `mainContent`
                    //    uses so the category bar is confined to
                    //    the task column and never bleeds over
                    //    the timeline. Suppressed on:
                    //      .board → the board has its own column
                    //               headers (clash with legacy
                    //               status pills)
                    //      .tasks → MyTasksView groups by status
                    //               itself + carries its own
                    //               crumb header
                    if sidebarRoute != .board && sidebarRoute != .tasks
                        && sidebarRoute != .today && sidebarRoute != .assignedComments {
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
                        // Match `dashboardSplit`'s 220pt leading
                        // inset so the GeometryReader sees the same
                        // rect the timeline+task split occupies —
                        // otherwise the filter bar's timelineW math
                        // (based on the full window) drifts and the
                        // pills land over the timeline column.
                        .padding(.leading, 220)
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
                        // Inset the toolbar's pill cluster by the
                        // sidebar's column width so "+ Evento" /
                        // "Hoje" / list picker etc. aren't hidden
                        // under the floating Liquid Glass pane.
                        // The WindowDragArea below spans the FULL
                        // toolbar width so the title-bar region
                        // over the sidebar still drags the window
                        // (and the macOS traffic lights stay
                        // clickable via the sidebar's 44pt inset).
                        .padding(.leading, 220)
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

                    // 5. Global sync indicator — a 2pt accent
                    //    stripe at the very top edge that lights
                    //    up whenever ANY async sync is in flight
                    //    (driven by `appState.activeSyncCount`).
                    //    Universal: any call wrapped in
                    //    `appState.tracked { … }` or that bumps
                    //    the counter directly surfaces here for
                    //    free. Sits ABOVE everything else, so
                    //    it's visible even over the toolbar.
                    VStack(spacing: 0) {
                        EditorialSyncBar()
                            .environmentObject(appState)
                        Spacer(minLength: 0)
                    }
                    .allowsHitTesting(false)
                }  // close inner ZStack(alignment: .top) — chrome

                    // Sidebar overlay — fixed 220pt column at the
                    // leading edge of the ZStack. Underneath the
                    // Liquid Glass material it pulls vibrancy from
                    // whatever paints behind in the chrome ZStack
                    // (Editorial.paper + toolbar + the active main
                    // view), so content visibly flows under it.
                    EditorialSidebar(
                        active: $sidebarRoute,
                        listFilter: $sidebarListFilter,
                        onOpenPalette: {
                            NSApp.sendAction(Selector(("toggleCommandPalette:")),
                                             to: nil, from: nil)
                        },
                        onOpenSettings: { showSettings = true }
                    )
                    .environmentObject(appState)
                    .allowsHitTesting(!anyPopupOpen)
                }  // close outer ZStack — chrome | sidebar overlay

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
                // List picker — full modal (same chrome as
                // Settings/Onboarding). Replaces the compact
                // anchored dropdown that lived under the
                // "Listas / Video ⌄" pill. `listPickerToken`
                // bumps when the sheet flips closed so the
                // toolbar pill re-reads the new list name from
                // Keychain (not observable on its own).
                FloatingModal(
                    isPresented: $showListPicker,
                    origin:      listPickerOrigin,
                    windowSize:  windowGeo.size,
                    fromBottom:  true
                ) {
                    CUListPickerSheet(onClose: {
                        listPickerToken &+= 1
                        showListPicker = false
                    })
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
                // ClickUp list picker — restored to the FULL modal
                // sheet the Settings/Onboarding flows use (was an
                // anchored dropdown). Per user request: clicking
                // the toolbar's "Listas / Video ⌄" should bring
                // back the legacy selector, not a compact pop.
                // The wrapper bumps `listPickerToken` when the
                // sheet flips closed so the toolbar pill re-reads
                // the new list name from Keychain (not observable
                // on its own).
                EmptyView()
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
                // Same concrete presentation path as EventDetailOverlay:
                // observer-backed conditional, identical full-window travel,
                // opening spring and explicit ease-in removal.
                TaskDetailOverlay(windowSize: windowGeo.size)
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
                    backdrop:    .none,
                    fromBottom:  true
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
                        // Backdrop fades — sliding the dim
                        // with the chat made the layer drag
                        // visibly during dismiss; a clean
                        // fade-to-clear reads much better.
                        .transition(.opacity)
                        // This is a real modal shield, not decoration. It must
                        // own the background hit region so the dashboard cannot
                        // receive clicks, scroll or hover while Apollo IA is up.
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeIn(duration: 0.30)) {
                                showAIChat = false
                            }
                        }
                        .onHover { _ in }
                        .zIndex(800)

                    // Transition attached HERE (not on a child
                    // inside aiChatCenteredOverlay) because the
                    // `if showAIChat` branch is what SwiftUI
                    // adds/removes — placing it on AIAgentChatView
                    // never fired since the chat view itself
                    // wasn't conditionally toggled inside its
                    // parent ZStack, and SwiftUI fell back to
                    // its default `.opacity` for the whole
                    // overlay.
                    //
                    // Explicit Y-offset (not `.move(edge:)`)
                    // because `.move` translates by the view's
                    // own height — for a window-tall chat
                    // column that left the top edge still on
                    // screen mid-spring. Window-height travel
                    // guarantees a clean slide-off.
                    aiChatCenteredOverlay(windowSize: windowGeo.size)
                        .transition(.asymmetric(
                            insertion: .modifier(
                                active:   OffsetYModifier(y: max(windowGeo.size.height, 900)),
                                identity: OffsetYModifier(y: 0)
                            ),
                            removal: .modifier(
                                active:   OffsetYModifier(y: max(windowGeo.size.height, 900)),
                                identity: OffsetYModifier(y: 0)
                            )
                        ))
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
                // Do not mount an empty, full-window aligned banner. Even
                // with no visible child, that wrapper kept a bottom band in
                // the hit-test tree and made the last rows of long task lists
                // impossible to click.
                if !showWelcome && !showOnboarding
                    && updateService.hasVisibleUpdateStatus {
                    UpdateAvailableBanner(updateService: updateService)
                        .padding(.trailing, 18)
                        .padding(.bottom, 18)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .bottomTrailing
                        )
                        .zIndex(1200)
                }

                // Toast — drops in just BELOW the 52pt head bar,
                // top-right, as its own surface (no longer painted
                // over the bell). Suppressed during welcome /
                // onboarding so the intro stays clean.
                if !showWelcome && !showOnboarding,
                   let upload = appState.uploadActivities.first(where: {
                       $0.state == .uploading && !dismissedUploadPillIDs.contains($0.id)
                   }) {
                    BellUploadPill(upload: upload,
                                   onTap: { showNotifs = true },
                                   onDismiss: {
                                       withAnimation(.spring(duration: 0.34, bounce: 0.14)) {
                                           _ = dismissedUploadPillIDs.insert(upload.id)
                                       }
                                   })
                        .padding(.top, 52 + 12)
                        .padding(.trailing, 18)
                        .transition(.asymmetric(
                            insertion: .offset(y: -8).combined(with: .opacity),
                            removal: .opacity
                        ))
                        .zIndex(1251)
                } else if !showWelcome && !showOnboarding, let pill = bellPillNotif {
                    BellPill(notification: pill,
                             onTap: {
                                 collapseBellPill()
                                 showNotifs = true
                             },
                             onDismiss: { collapseBellPill() })
                        .padding(.top, 52 + 12)
                        .padding(.trailing, 18)
                        // The outer ZStack is already top-trailing. Do not
                        // inflate this toast to a full-window hit-test layer.
                        // Only the visible capsule is interactive.
                        .transition(.asymmetric(
                            insertion: .offset(y: -8).combined(with: .opacity),
                            removal:   .opacity
                        ))
                        // Animation is driven ONLY by `withAnimation` at the
                        // mutation sites (insert in the toast handler, remove in
                        // collapseBellPill). A `.animation(value:)` modifier here
                        // too double-drives the change and makes the removal
                        // transition fail to complete — leaving an invisible
                        // (opacity-0) but hit-testable ghost over the bell/toolbar.
                        .zIndex(1250)
                }
            }
            .coordinateSpace(name: "appWindow")
            .environment(\.windowSize, windowGeo.size)
            // When the popup closes, defer-reset the openStyle
            // back to default so the next surface that opens a
            // task without setting its own style gets the
            // settings-style bottom slide. Deferred so a dismiss
            // animation in flight doesn't mid-frame swap to a
            // different transition.
            .onChange(of: appState.detailTask) { _, newValue in
                if newValue == nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
                        if appState.detailTask == nil {
                            appState.detailTaskOpenStyle = .bottomSlide
                            appState.detailTaskOrigin    = .zero
                        }
                    }
                }
            }
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
            // Editorial.paper used to paint the whole window here
            // — but the Editorial+ sidebar wants its column truly
            // transparent so the floating Liquid Glass pane can
            // pull from the desktop. The chrome side now owns its
            // own paper fill (ContentView body, inside the HStack);
            // this root background is just Color.clear so the
            // sidebar column stays see-through.
            Color.clear
                .ignoresSafeArea()
        )
        // Push the toolbar up into the macOS title bar (alongside traffic lights)
        .ignoresSafeArea(.container, edges: .top)
        // (Specular branco no topo REMOVIDO — era resquício do
        // Liquid Glass antigo e lia como uma "sombra branca" sobre
        // o canvas escuro do Studio Glass. Profundidade agora vem
        // de material e sombra, não de sheen pintado.)
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
        // Extracted to a method so its closures don't bloat the `body`
        // type-checker (keeps SwiftUI's inference within budget).
        .sheet(item: $reviewPresenter.request) { req in reviewSheet(req) }
    }

    /// The embedded review sheet content. A fresh native review (opened from the
    /// REVIEW button → params) reads & writes the SAME Cloudflare KV blob as the
    /// web (the single live `?att=` link): `liveLoad` pulls existing comments on
    /// open; `liveSave` autosaves on change; `onSubmit` does a final flush and
    /// posts the ClickUp comment.
    private func reviewSheet(_ req: ReviewRequest) -> some View {
        let liveLoad: (() async -> Data?)? = req.params.map { p in
            { await ReviewBackend.resolve(mediaUrl: p.mediaUrl, ext: p.ext,
                                          title: p.mediaTitle, taskId: p.taskId,
                                          listId: p.listId, uploaderId: p.uploaderId) }
        }
        let liveSave: ((Data) async -> Bool)? = (req.params != nil)
            ? { data in await ReviewBackend.save(payloadData: data) }
            : nil
        let onSubmit: (ReviewResult) -> Void = { result in
            // Final flush to KV (covers edits within the autosave debounce).
            Task { await ReviewBackend.save(payloadData: result.json) }
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
        }
        return ReviewView(
            params: req.params,
            savedJSON: req.savedJSON,
            // "Ver review" (saved JSON) opens view-only — the review was
            // already submitted; this is just for re-reading the markup.
            readOnly: req.savedJSON != nil,
            liveLoad: liveLoad,
            liveSave: liveSave,
            onClose: { reviewPresenter.request = nil },
            onSubmit: onSubmit
        )
        .frame(minWidth: 1040, minHeight: 660)
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
                    // Plain ease-in fall — sprung dismisses
                    // asymptote at the bottom and the panel
                    // never visibly clears the window edge.
                    withAnimation(.easeIn(duration: 0.30)) {
                        showAIChat = false
                    }
                }
                .transition(.opacity)

            AIAgentChatView(onClose: {
                withAnimation(.easeIn(duration: 0.30)) {
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
                // AGENT GLOW (Studio Glass): a borda multicolor
                // girando estilo Apple Intelligence enquanto o
                // agente pensa/trabalha — identidade de "IA viva".
                // Gate automático dentro do AgentGlow (Reduce
                // Motion / Tier C / Low Power → borda accent
                // estática). Fora do isThinking, nada é montado.
                .overlay {
                    if appState.aiAgent.isThinking {
                        AgentGlow(cornerRadius: 6)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(Motion.standard, value: appState.aiAgent.isThinking)
                .shadow(color: .black.opacity(0.22), radius: 50, y: 40)
                .shadow(color: .black.opacity(0.08), radius: 24, y: 8)
                .padding(.top,        max(28, windowSize.height * 0.05))
                .padding(.bottom,     max(28, windowSize.height * 0.05))
                .padding(.horizontal, max(48, windowSize.width  * 0.07))
                // (Transition lives on the outer
                // aiChatCenteredOverlay() call site — placing
                // it here is a no-op because AIAgentChatView is
                // not conditionally toggled inside this ZStack;
                // the parent `if showAIChat` is what SwiftUI
                // adds/removes.)
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
                withAnimation(.spring(duration: 0.55, bounce: 0.13)) {
                    showNotifs = false
                }
            }
            .transition(.opacity)

        // Side-panel layout — hangs from below the toolbar to
        // near the window bottom, pinned to the trailing edge
        // with a small visual gutter. The wrapper provides the
        // top reserve (toolbar band) + outer margins; the
        // panel itself fills the remaining vertical space.
        NotificationsCenterView(onClose: {
            withAnimation(.spring(duration: 0.55, bounce: 0.13)) {
                showNotifs = false
            }
        })
            .environmentObject(appState)
            .padding(.top,      62)   // clear toolbar
            .padding(.trailing, 16)
            .padding(.bottom,   24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            // Slide IN from the right with a spring bounce at
            // the end (per design intent — replaces the
            // cursor-anchored scale that read as "popping out"
            // from the bell). Out animation mirrors the slide
            // back to the trailing edge.
            .transition(.asymmetric(
                insertion: .move(edge: .trailing)
                    .combined(with: .opacity),
                removal:   .move(edge: .trailing)
                    .combined(with: .opacity)
            ))
            .animation(.spring(duration: 0.55, bounce: 0.13), value: showNotifs)
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
        // Type-led toolbar with no independent surface or divider. It
        // remains visually continuous with the page underneath instead
        // of reading as a detached header band.
        HStack(spacing: 26) {

            // (Apollo brand mark removed — leading slot is now
            //  empty so "+ Evento" sits right at the toolbar's
            //  leading edge.)

            // + Evento
            Button { showNewEvent = true } label: {
                Text("+ Evento")
            }
            .buttonStyle(TBButtonStyle())
            .focusEffectDisabled()
            .help("Novo evento")
            .captureFrame($newEventOrigin)
            .padding(.leading, 10)

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

            // (Filtros button removed from the toolbar — filters
            //  now live in the sidebar's FILTROS section,
            //  collapsibles per category. No need to surface a
            //  second entry point in the top bar.)

            // Buscar — opens the command palette. Stripped to a
            // plain text link to match the prototype (no glyph,
            // no ⌘K kbd badge). The ⌘K shortcut still works via
            // the responder chain.
            Button {
                NSApp.sendAction(Selector(("toggleCommandPalette:")), to: nil, from: nil)
            } label: {
                Text("Buscar")
            }
            .buttonStyle(TBButtonStyle())
            .focusEffectDisabled()
            .help("Buscar (⌘K)")

            // ✦ Apollo IA — cinnabar mark + word (prototype AIMark)
            Button {
                let rect = MouseOriginCapture.currentClickRectInMainWindow()
                if rect != .zero {
                    aiChatOpenPoint = CGPoint(x: rect.midX, y: rect.midY)
                }
                // Bouncy spring on open (matches the rest of
                // the Editorial overlays); clean ease on close
                // so the panel never hangs at the bottom edge.
                if showAIChat {
                    withAnimation(.easeIn(duration: 0.30)) {
                        showAIChat = false
                    }
                } else {
                    withAnimation(.spring(response: 0.34,
                                          dampingFraction: 0.86)) {
                        showAIChat = true
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    AIMark(size: 14)
                    Text("Apollo IA")
                }
            }
            .buttonStyle(TBButtonStyle(accent: true))
            .focusEffectDisabled()
            .help("Apollo IA")
            .onChange(of: appState.aiAgent.dismissChatRequest) { _, _ in
                // Plain ease-in fall — matches the rest of
                // the Editorial overlays.
                withAnimation(.easeIn(duration: 0.30)) {
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
                withAnimation(.spring(duration: 0.55, bounce: 0.13)) {
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
                withAnimation(.spring(duration: 0.4, bounce: 0.22)) {
                    bellPillNotif = next
                }
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

            // Vertical separator — divides the icon cluster (bell
            // + gear) from the primary CTA on the right, matching
            // the prototype's visual rhythm.
            Rectangle()
                .fill(Editorial.rule)
                .frame(width: 1, height: 22)
                .padding(.horizontal, -8)

            // + Nova tarefa — primary CTA. Cinnabar pill instead
            // of the text-link "+ Tarefa" the leading cluster
            // used to carry (now removed); this is the prototype's
            // emphasised "new task" affordance.
            Button { showNewTask = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                    Text("Nova tarefa")
                        .font(Editorial.sans(13.5, .semibold))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                // Liquid Glass material tinted with the cinnabar accent —
                // interactive glass carries its own hover/press feedback.
                .liquidGlassCapsule(tint: Editorial.accent, tintOpacity: 0.9)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Nova tarefa")
            // Pull the CTA ~11pt closer to the separator: the gap was
            // 18pt (HStack spacing 26 − the separator's −8 inset); −11
            // brings it to ~7pt, a 60% reduction.
            .padding(.leading, -11)
            .captureFrame($newTaskOrigin)
        }
        // Leading kept tight (14pt) so the Apollo brand mark sits
        // right next to the sidebar's trailing edge. The 220pt
        // sidebar-clear inset is applied OUTSIDE this HStack
        // (see `.padding(.leading, 220)` on the toolbar instance
        // in `body`), so we don't need the legacy 103pt traffic-
        // light gap here — the sidebar already covers that zone
        // with its own 44pt traffic-light inset.
        .padding(.leading, 14)
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
    }

    // MARK: - Main content

    private var mainContent: some View {
        // EditorialMainV2 dashboard / Editorial+ board router. The
        // sidebar's `sidebarRoute` selects which surface fills the
        // chrome's main rect:
        //   .board → kanban (EditorialBoardView)
        //   anything else → the legacy split (timeline | tasks)
        //
        // Both surfaces start with a 220pt leading inset so their
        // FIRST column / card lines up where it did in the
        // pre-overlay HStack era (right of the sidebar). Content
        // that scrolls past that inset slides UNDER the glass and
        // shows through the translucent material — i.e. the
        // sidebar reveals content as you scroll past it, but
        // nothing renders behind-the-glass at rest.
        Group {
            switch sidebarRoute {
            case .board:
                EditorialBoardView()
                    .environmentObject(appState)
                    // SEM leading inset: o board agora é full-width
                    // e o ScrollView horizontal desenha até x=0 —
                    // os cards arrastados/rolados pra esquerda
                    // passam POR TRÁS do pane flutuante de vidro
                    // da sidebar. O recuo visual do conteúdo em
                    // repouso vem do `contentMargins` interno do
                    // EditorialBoardView. Top inset mantém o
                    // header abaixo dos pills da toolbar.
                    .padding(.top, 52)
            case .tasks:
                EditorialMyTasksView()
                    .environmentObject(appState)
                    .padding(.top, 52)
                    .padding(.leading, 220)
            case .today:
                editorialHomeView
            case .assignedComments:
                AssignedCommentsView()
                    .environmentObject(appState)
                    .padding(.top, 52)
                    .padding(.leading, 220)
            default:
                dashboardSplit
            }
        }
    }

    /// Editorial+ Home — port of the prototype's top band
    /// (folio + serif "Home" title + date+stats row + next-event
    /// card + AGENDA/TAREFAS section labels) stacked above the
    /// legacy timeline | tasks split. The header lives in its
    /// own scroll-free band so the dashboard below keeps its
    /// independent scrolling.
    private var editorialHomeView: some View {
        VStack(spacing: 0) {
            EditorialHomeHeader()
                .environmentObject(appState)
                .padding(.top, 52)        // clear the toolbar pills
                .padding(.leading, 220)   // clear the glass sidebar
            // Home-specific split: forward agenda on the left and a
            // unified ClickUp + Apollo Inbox on the right.
            homeDashboardSplit
        }
    }

    @ViewBuilder
    private var homeDashboardSplit: some View {
        GeometryReader { geo in
            let total     = max(1, geo.size.width)
            let timelineW = (total - 1) * (1.0 / 2.05)
            HStack(spacing: 0) {
                TimelineView(forwardOnly: true)
                    .frame(width: timelineW)
                Rectangle()
                    .fill(Editorial.rule.opacity(0.65))
                    .frame(width: 1)
                    .edgeFadedVertical()
                EditorialHomeInboxColumn()
                    .environmentObject(appState)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.leading, 220)
    }

    /// The original two-column dashboard (timeline + task list).
    /// Extracted so `mainContent` can switch between this and the
    /// kanban without indenting the split layout under another
    /// branch. Carries a `220pt` leading inset because the sidebar
    /// now overlays the chrome — without the inset the timeline's
    /// event titles would slide BEHIND the Liquid Glass pane and
    /// the leading half of each title would be occluded.
    private var dashboardSplit: some View {
        dashboardSplitBody(skipsLegacyHeaderInsets: false)
    }

    /// Same split, but the embedded scroll views drop their
    /// legacy 52pt toolbar reserve + filter-bar reserve. Used
    /// by the `.today` route where `EditorialHomeHeader` already
    /// occupies that band above — without this the task column
    /// shows a huge empty gap between the inline status pills
    /// and the first row.
    private var dashboardSplitInsetless: some View {
        dashboardSplitBody(skipsLegacyHeaderInsets: true)
    }

    /// EditorialMainV2: a clean proportional split —
    /// `gridTemplateColumns: '1fr 1.05fr'` (timeline | tasks)
    /// with a single hairline rule between.
    @ViewBuilder
    private func dashboardSplitBody(skipsLegacyHeaderInsets: Bool) -> some View {
        GeometryReader { geo in
            let total     = max(1, geo.size.width)
            let timelineW = (total - 1) * (1.0 / 2.05)
            HStack(spacing: 0) {
                // Home/Hoje route drops past days from the
                // agenda — the user only cares about today
                // forward; the legacy ±30 window stays for
                // other surfaces.
                TimelineView(forwardOnly: skipsLegacyHeaderInsets)
                    .frame(width: timelineW)
                Rectangle()
                    .fill(Editorial.rule.opacity(0.65))
                    .frame(width: 1)
                    .edgeFadedVertical()
                TaskListView(skipsLegacyHeaderInsets: skipsLegacyHeaderInsets)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.leading, 220)
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

    /// Card flutuante Studio Glass — receita `floatingPanel` do
    /// Galileo (vidro espesso por tier + UMA sombra de elevação),
    /// substituindo o specular gradient pintado à mão + stack de 3
    /// sombras do Control Center antigo. Mantém o nome/assinatura
    /// pros 10 call sites.
    func popupGlass<S: InsettableShape>(_ shape: S) -> some View {
        Group {
            switch Materials.tier {
            case .solid:
                self.background(shape.fill(Editorial.popup))
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Editorial.rule, lineWidth: 1)
                        .allowsHitTesting(false))
                    .shadow(color: .black.opacity(0.30), radius: 26, y: 12)
            case .liquidGlass:
                self.glassControl(shape)
                    .clipShape(shape)
                    .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
            case .vibrancy:
                self.background(.regularMaterial, in: shape)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                        .allowsHitTesting(false))   // fio de luz
                    .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
            }
        }
    }

    /// Same chrome as `popupGlass` but **without** the outer
    /// `clipShape`. On macOS 26 the combination of `.clipShape(_)` +
    /// a nested `NSScrollView` (used by SwiftUI `ScrollView`) crashes
    /// inside `computed_effectiveCornerRadii` the moment the scroll
    /// view's host first joins the window — the corner-config lookup
    /// asserts. The backgrounds already paint in the rounded shape,
    /// so dropping the clip preserves the visual as long as the
    /// content respects its own padding (it does).
    func popupGlassUnclipped<S: InsettableShape>(_ shape: S) -> some View {
        Group {
            switch Materials.tier {
            case .solid:
                self.background(shape.fill(Editorial.popup))
                    .overlay(shape.strokeBorder(Editorial.rule, lineWidth: 1)
                        .allowsHitTesting(false))
                    .shadow(color: .black.opacity(0.30), radius: 26, y: 12)
            case .liquidGlass:
                self.glassControl(shape)
                    .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
            case .vibrancy:
                self.background(.regularMaterial, in: shape)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                        .allowsHitTesting(false))
                    .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
            }
        }
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

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // 3-stop linear gradient using the window's bg colour.
        // The TOOLBAR REGION (top ~barHeight of the strip) stays
        // fully opaque so content scrolling up disappears
        // completely under the pills, then the lower section
        // softly fades to clear so the body's first row reads
        // continuously.
        //
        // Color choice is RESOLVED HERE per render so it stays
        // accurate on Light↔Dark switches. `Editorial.paper` is
        // dynamic, but the previous version baked it into a
        // `.drawingGroup()` raster — the texture cached the
        // cream and stayed cream in dark mode. Reading
        // `colorScheme` directly + dropping `.drawingGroup()`
        // costs a hair more per frame but always matches the
        // active appearance.
        let bg: Color = colorScheme == .dark
            ? Color(hex: "#141415")   // matches Editorial.paper dark (Studio Glass)
            : Color(hex: "#F8F6F3")   // matches Editorial.paper light
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

#if DEBUG
// Live Canvas of the whole dashboard (toolbar + timeline + tasks),
// populated with mock data. Switch the canvas between light/dark with
// the two previews below.
#Preview("Dashboard — claro") {
    ContentView()
        .environmentObject(AppState.preview)
        .environmentObject(UpdateService())
        .frame(width: 1180, height: 760)
}

#Preview("Dashboard — escuro") {
    ContentView()
        .environmentObject(AppState.preview)
        .environmentObject(UpdateService())
        .frame(width: 1180, height: 760)
        .preferredColorScheme(.dark)
}
#endif
