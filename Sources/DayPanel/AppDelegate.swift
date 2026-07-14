import AppKit
import SwiftUI
import Combine
import Sparkle
import UserNotifications
import CoreSpotlight
import ReviewKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Sparkle
    //
    // `SPUStandardUpdaterController` is the convenience layer
    // that owns an `SPUUpdater`, registers the standard menu
    // validation hooks, and shows Sparkle's built-in UI for
    // "checking for updates / found update / installing".
    // Initialised with `startingUpdater: true` so Sparkle wakes
    // up the scheduled-check timer on launch (interval set in
    // Info.plist via `SUScheduledCheckInterval`).
    //
    // `updaterDelegate` and `userDriverDelegate` are left as
    // `nil` for now — the defaults already do what we need.
    // If we ever want to gate updates by channel (beta vs
    // stable), reject downgrades, or customise the prompt
    // copy, those delegates are where the hooks live.
    /// Bridge between Sparkle and the rest of the app: publishes
    /// `availableUpdate` for the banner, fires UNUserNotifications,
    /// and pushes an entry into AppState's in-app notification log.
    /// Created BEFORE `updaterController` so we can hand it as the
    /// delegate during the controller's init.
    private lazy var updateService: UpdateService = {
        let s = UpdateService()
        s.appState = appState
        return s
    }()

    /// Our Editorial Calm replacement for Sparkle's stock update
    /// windows. Sparkle drives it through the `SPUUserDriver` protocol;
    /// it renders the SwiftUI `UpdaterCardView`. The silent-channel
    /// suppression that used to live in `SPUStandardUserDriverDelegate`
    /// now lives inside this driver's `showUpdateFound`.
    private lazy var updateDriver = MainActor.assumeIsolated { ApolloUpdateDriver() }

    /// Raw `SPUUpdater` (instead of `SPUStandardUpdaterController`) so we
    /// can plug in our custom user driver. Started manually on launch so
    /// the scheduled-check timer fires (interval via Info.plist
    /// `SUScheduledCheckInterval`).
    private lazy var updater: SPUUpdater = {
        let u = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: updateDriver,
            delegate: updateService
        )
        do {
            try u.start()
        } catch {
            NSLog("[Apollo] Sparkle updater failed to start: %@",
                  error.localizedDescription)
        }
        // The service exposes thin wrappers around `checkForUpdates` /
        // `checkForUpdatesInBackground`; hand it the updater so the
        // banner buttons can route through Sparkle.
        updateService.updater = u
        return u
    }()

    /// Spotlight-style ⌘K palette. Owns its own `NSPanel`
    /// and a key-down monitor; we hold a reference here so
    /// the menu item's selector + the lifecycle outlive a
    /// single open/close cycle.
    private lazy var commandPaletteController = CommandPaletteController(
        appState: appState
    )

    @objc private func toggleCommandPalette(_ sender: Any?) {
        commandPaletteController.toggle()
    }

    /// "Verificar Atualizações…" menu action. Routes a user-initiated
    /// check through the raw updater (which drives our custom UI).
    @objc private func checkForUpdatesMenu(_ sender: Any?) {
        updater.checkForUpdates()
    }

    /// Grey out the update menu item while a check can't be started
    /// (e.g. one is already in flight). Only consulted for items whose
    /// target is this AppDelegate.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdatesMenu(_:)) {
            return updater.canCheckForUpdates
        }
        return true
    }

    /// `Bundle.main.infoDictionary` lookup used by the About
    /// panel + the Sparkle menu validator. Helper avoids
    /// repeating the optional dance + the `as? String` cast
    /// at every call site.
    private static func infoString(_ key: String) -> String? {
        Bundle.main.infoDictionary?[key] as? String
    }


    /// Smallest frame the main window will resize to. Cited from
    /// `makeMainWindow` AND `windowWillResize` so the floor is the
    /// same value in every code path.
    ///
    /// Bumped from 740×599 → 880×680 after a UX review: at the
    /// older minimum the status filter bar had to truncate
    /// ("DOIN…" instead of "DOING"), the right-column task
    /// titles wrapped onto a second line, and the timeline's
    /// multi-event days felt cramped. The new floor gives every
    /// section enough room to render without truncation while
    /// still being well below the natural launch size, so users
    /// can still pull the window in for split-screen workflows.
    // Bumped by 220pt (sidebar width) when the Editorial+ sidebar
    // landed — at the old 880 minimum the right-side toolbar pills
    // (Apollo IA · bell · gear · Concluir) got clipped past the
    // window's right edge. 1100pt = 880 chrome floor + 220 sidebar.
    static let windowMinFrameSize = NSSize(width: 1100, height: 680)

    let appState = AppState()

    private var window:     NSWindow?
    private var statusItem: NSStatusItem?

    /// Held alive so its `preferredFrameRateRange` keeps
    /// influencing the window's compositing cadence. The
    /// callback intentionally does nothing — the display link
    /// just acts as a hint to ProMotion.
    private var promotionDisplayLink: CADisplayLink?

    @objc private func promotionTick(_ sender: CADisplayLink) {
        // No-op: the display link is just a refresh-rate hint
        // for the WindowServer. We don't actually need to do
        // anything per tick — Core Animation already drives
        // SwiftUI re-renders when state changes.
    }
    private var popover:    NSPopover?
    private var cancellables = Set<AnyCancellable>()

    /// Mirrors `AppState.tasksById` into the macOS Spotlight index
    /// so Cmd+Space hits surface tasks as first-class results.
    /// Attached on launch, debounces 600ms internally to coalesce
    /// optimistic-update bursts.
    private lazy var spotlightIndexer = SpotlightIndexer()

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ── Apply the user's appearance choice (Claro / Escuro /
        //    Sistema). Pinning `NSApp.appearance` cascades to every
        //    window, popover, NSPanel (command palette), the main
        //    menu, the About panel, and makes SwiftUI's
        //    `@Environment(\.colorScheme)` + our dynamic Editorial
        //    tokens resolve to the chosen mode. Default is `.system`
        //    (follow macOS); the `NSRequiresAquaSystemAppearance`
        //    opt-out was removed from Info.plist so `.dark` /
        //    `.system` can actually take effect.
        appState.applyAppearanceMode()

        // Studio Glass: gate global de scroll — suspende todo hover
        // durante rolagem/pinça (os modifiers hoverGlass/hoverBounce/
        // hoverRow consultam ScrollGate.shared.active).
        ScrollGate.shared.install()

        // Take ownership of UNUserNotificationCenter delivery + click
        // handling so foreground banners show up and notification
        // taps deep-link into the matching task / event popup.
        UNUserNotificationCenter.current().delegate = self

        // Poll watched reviews and fire a notification when someone updates one
        // (the active counterpart to the REVIEW button's dot). Route through
        // AppState.notify so it lands in the in-app Notifications panel AND as a
        // native banner.
        ReviewWatcher.shared.notify = { [weak appState] title, subtitle, att in
            appState?.notify(.info, title: title, subtitle: subtitle,
                             message: "Alguém atualizou este review.",
                             targetKind: .review, targetId: att)
        }
        ReviewWatcher.shared.start()

        // Receive `daypanel://` URL opens (the standalone review app's
        // review-done callback). The scheme is declared in Info.plist.
        registerURLHandler()

        // Install the standard macOS main menu so text-editing
        // shortcuts (Cmd+C / V / X / A / Z / Shift-Cmd+Z, etc.)
        // route to the focused TextField. SwiftUI's TextField
        // is backed by NSTextField which relies on the standard
        // Edit menu's first-responder actions (`copy:`, `paste:`,
        // `selectAll:`, `undo:`…) being present in the menu bar
        // for AppKit to dispatch the shortcuts. Without a main
        // menu (the app launched with none) those keystrokes
        // were being swallowed by the system.
        installMainMenu()

        buildPopover()

        if appState.menuBarMode {
            enableMenuBarMode()
        } else {
            enableWindowMode()
        }

        Task { await appState.initialize() }

        // Subscribe the Spotlight indexer to tasks. Has to happen
        // after AppState exists; the indexer debounces internally
        // so it's safe to attach before the first sync completes.
        spotlightIndexer.attach(to: appState)

        // Dev / "ative o onboarding" hook: when this
        // UserDefaults flag is set on the next launch, fire
        // the onboarding-open token after the dashboard has
        // settled. Pairs with a one-shot
        // `defaults write com.painellunar.app
        //  dp_forceOpenOnboarding -bool true` from the
        // shell so a connected user can revisit the
        // wizard without having to disconnect anything.
        if UserDefaults.standard.bool(forKey: "dp_forceOpenOnboarding") {
            UserDefaults.standard.removeObject(forKey: "dp_forceOpenOnboarding")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                self.appState.requestOpenOnboarding()
            }
        }

        // React to preference changes without restart
        appState.$menuBarMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                if enabled { self?.enableMenuBarMode() }
                else       { self?.enableWindowMode()  }
            }
            .store(in: &cancellables)

        // Fast polling when the window is in the foreground — surfaces
        // ClickUp-side task edits within ~30 seconds.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                // Refocusing counts as interaction so the fast
                // loop's activity gate opens immediately.
                self.appState.noteUserInteraction()
                Task { await self.appState.sync() }
                self.appState.enableFastSync()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in
                self?.appState.disableFastSync()
            }
            .store(in: &cancellables)

        // Activity signal for the fast-sync gate — any click,
        // keypress or scroll marks the session as actively used;
        // ticks while idle are skipped (see `enableFastSync`).
        // Local monitor = events delivered to THIS app only, on
        // the main thread; updating one timestamp is negligible.
        NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown,
                       .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            self?.appState.noteUserInteraction()
            return event
        }

        // Kick off the fast loop now if we launched into an active window.
        if NSApp.isActive { appState.enableFastSync() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.networkMonitor.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !appState.menuBarMode
    }

    // MARK: - Spotlight handoff

    /// Called when macOS hands off an `NSUserActivity` to Apollo —
    /// the path Spotlight uses when the user clicks a task in the
    /// Cmd+Space results, and the same channel Handoff /
    /// Continuity would use. We only act on
    /// `CSSearchableItemActionType`; the unique identifier is the
    /// task id, which we hand to `AppState.openTask(id:)` to pop
    /// the task detail.
    func application(_ application: NSApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void)
    -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let taskId = userActivity.userInfo?[CSSearchableItemActivityIdentifier]
                as? String
        else {
            return false
        }
        // Ensure the window is visible — if the user clicked the
        // Spotlight hit while Apollo was in menu-bar mode the
        // popup needs to actually appear. `enableWindowMode()` is
        // safe to call whether or not the window already exists.
        if appState.menuBarMode {
            popover?.performClose(nil)
        } else {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        appState.openTask(id: taskId)
        return true
    }

    // MARK: - Custom URL scheme (daypanel://)

    /// Installs the Apple Event handler that delivers `daypanel://…` URL opens.
    /// The scheme is declared in Info.plist; Google OAuth uses a localhost
    /// listener instead, so the only consumer here is the standalone review
    /// app's `daypanel://review-done` callback.
    private func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:replyEvent:)),
            forEventClass: AEEventClass(0x4755524C), // 'GURL' = kInternetEventClass
            andEventID:    AEEventID(0x4755524C)     // 'GURL' = kAEGetURL
        )
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor,
                                         replyEvent: NSAppleEventDescriptor) {
        guard let str = event
                .paramDescriptor(forKeyword: AEKeyword(0x2D2D2D2D)) // '----' = keyDirectObject
                .flatMap({ $0.stringValue }),
              let url = URL(string: str)
        else { return }
        handleDeepLink(url)
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "daypanel" else { return }
        switch url.host {
        case "review-done": handleReviewDone(url)
        default: break
        }
    }

    /// The standalone review app finished a review and handed the result back:
    /// unpack the embedded payload and post the summary comment to ClickUp
    /// (Apollo is the side that's logged in). Mirrors the embedded sheet's
    /// `onSubmit` path so both workflows produce identical comments.
    private func handleReviewDone(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? { items.first { $0.name == name }?.value }

        var data: Data?
        if let packed = q("data") {
            data = ReviewHandoff.decode(packed)          // inline payload (sandbox-safe)
        } else if let path = q("file") {
            data = try? Data(contentsOf: URL(fileURLWithPath: path)) // legacy / non-sandbox
        }
        guard let data,
              let r = ReviewResult.fromSavedJSON(data),
              let taskId = r.taskId
        else { return }

        // Bring Apollo (and the task) forward, then post — the existing
        // reviewPostTick auto-refresh updates the open comments section.
        if !appState.menuBarMode {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        appState.openTask(id: taskId)

        Task {
            await appState.postReviewComment(
                taskId: taskId,
                commentId: r.commentId,
                attachmentId: r.attachmentId,
                text: r.summaryText,
                mentionMemberIds: r.uploaderId.map { [$0] } ?? [],
                reviewJSON: r.json
            )
        }
    }

    // MARK: - Main menu

    /// Builds and installs the standard macOS main menu. This is
    /// what wires up text-editing keyboard shortcuts (Cmd+C/V/X/A,
    /// Cmd+Z/Shift-Cmd+Z, Cmd+F, etc.) — AppKit walks the menu's
    /// items to validate and dispatch each shortcut, so without
    /// these items installed the keys do nothing inside text
    /// fields. Each item points at a first-responder selector
    /// (`copy:`, `paste:`, `selectAll:`, `undo:`…) so the focused
    /// `NSTextField` / `NSTextView` (which SwiftUI's `TextField`
    /// and `TextEditor` wrap) receives them automatically.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // ── App menu (first menu — AppKit treats whichever menu
        //    is at index 0 as the application menu, regardless
        //    of its title string). Provides Quit + Hide.
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        // Use the human-facing bundle name ("Apollo") for menu
        // copy, NOT `ProcessInfo.processInfo.processName` which
        // returns the executable name ("DayPanel") — that was
        // leaking the internal codename into "Sobre DayPanel",
        // "Ocultar DayPanel", "Encerrar DayPanel". The bundle
        // already sets CFBundleName / CFBundleDisplayName to
        // "Apollo"; reading those is the canonical fix.
        let appName: String = AppDelegate.infoString("CFBundleDisplayName")
            ?? AppDelegate.infoString("CFBundleName")
            ?? "Apollo"

        // Custom "About" — the system's standard panel reads
        // CFBundleShortVersionString + CFBundleVersion from
        // Info.plist already, but the layout is plain. We
        // override the action to call our own handler that
        // injects a richer credits string (build number,
        // copyright, brief tagline). Selector name matches
        // the convention `showAboutPanel(_:)` so any other
        // code that wants the same panel can fire it via
        // `NSApp.sendAction(...)`.
        let aboutItem = NSMenuItem(
            title: "Sobre \(appName)",
            action: #selector(showAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)

        // ── Sparkle "Check for Updates…". With a raw `SPUUpdater` (so we
        // can use our custom user driver) there's no built-in menu
        // validator, so we route through an AppDelegate selector and
        // grey the item out via `validateMenuItem` while a check can't
        // run. Touching `updater` here also starts it on launch.
        appMenu.addItem(.separator())
        let updateItem = NSMenuItem(
            title: "Verificar Atualizações…",
            action: #selector(checkForUpdatesMenu(_:)),
            keyEquivalent: ""
        )
        updateItem.target = self
        appMenu.addItem(updateItem)
        _ = updater   // force lazy init → starts the scheduled-check timer

        appMenu.addItem(.separator())

        // Command palette — Spotlight-style ⌘K. Sits in the
        // App menu (instead of a "View" or "Tools" menu)
        // because Apollo doesn't have one yet, and ⌘K needs
        // to validate against the App menu so it works
        // regardless of which subview has focus. Action
        // routes to the AppDelegate's toggle handler so
        // pressing ⌘K twice closes the panel cleanly.
        let paletteItem = NSMenuItem(
            title: "Buscar…",
            action: #selector(toggleCommandPalette(_:)),
            keyEquivalent: "k"
        )
        paletteItem.target = self
        appMenu.addItem(paletteItem)
        appMenu.addItem(.separator())

        let hide = NSMenuItem(
            title: "Ocultar \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(hide)

        let hideOthers = NSMenuItem(
            title: "Ocultar outros",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)

        appMenu.addItem(NSMenuItem(
            title: "Mostrar tudo",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())

        appMenu.addItem(NSMenuItem(
            title: "Encerrar \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // ── Edit menu — the reason this whole helper exists.
        //    Each item targets the first-responder selector that
        //    NSTextField / NSTextView already handle natively; the
        //    `nil` action target = "send up the responder chain"
        //    which is what makes the selector dispatch correctly.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Editar")

        let undo = NSMenuItem(
            title: "Desfazer",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        undo.target = nil
        editMenu.addItem(undo)

        let redo = NSMenuItem(
            title: "Refazer",
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        redo.target = nil
        editMenu.addItem(redo)

        editMenu.addItem(.separator())

        editMenu.addItem(NSMenuItem(
            title: "Recortar",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Copiar",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Colar",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        ))

        let pastePlain = NSMenuItem(
            title: "Colar e ajustar estilo",
            action: Selector(("pasteAsPlainText:")),
            keyEquivalent: "v"
        )
        pastePlain.keyEquivalentModifierMask = [.command, .shift, .option]
        editMenu.addItem(pastePlain)

        editMenu.addItem(NSMenuItem(
            title: "Apagar",
            action: #selector(NSText.delete(_:)),
            keyEquivalent: ""
        ))
        editMenu.addItem(NSMenuItem(
            title: "Selecionar tudo",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        ))

        editMenu.addItem(.separator())

        // Find submenu — Cmd+F, Cmd+G, Shift-Cmd+G follow the
        // standard `performFindPanelAction:` pattern with tag
        // values that map to NSFindPanelAction enum cases.
        let findMenuItem = NSMenuItem(title: "Buscar", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Buscar")

        let find = NSMenuItem(
            title: "Buscar…",
            action: Selector(("performFindPanelAction:")),
            keyEquivalent: "f"
        )
        find.tag = 1     // NSFindPanelAction.showFindPanel.rawValue
        findMenu.addItem(find)

        let findNext = NSMenuItem(
            title: "Buscar próximo",
            action: Selector(("performFindPanelAction:")),
            keyEquivalent: "g"
        )
        findNext.tag = 2 // NSFindPanelAction.next.rawValue
        findMenu.addItem(findNext)

        let findPrev = NSMenuItem(
            title: "Buscar anterior",
            action: Selector(("performFindPanelAction:")),
            keyEquivalent: "g"
        )
        findPrev.tag = 3 // NSFindPanelAction.previous.rawValue
        findPrev.keyEquivalentModifierMask = [.command, .shift]
        findMenu.addItem(findPrev)

        findMenuItem.submenu = findMenu
        editMenu.addItem(findMenuItem)

        // Spelling submenu (gives the "Check Spelling While
        // Typing" toggle that NSTextView users expect).
        let spellingItem = NSMenuItem(title: "Ortografia e gramática", action: nil, keyEquivalent: "")
        let spellingMenu = NSMenu(title: "Ortografia e gramática")

        spellingMenu.addItem(NSMenuItem(
            title: "Mostrar ortografia e gramática",
            action: Selector(("showGuessPanel:")),
            keyEquivalent: ":"
        ))
        let checkNow = NSMenuItem(
            title: "Verificar agora",
            action: Selector(("checkSpelling:")),
            keyEquivalent: ";"
        )
        spellingMenu.addItem(checkNow)
        spellingMenu.addItem(.separator())
        spellingMenu.addItem(NSMenuItem(
            title: "Verificar enquanto digita",
            action: Selector(("toggleContinuousSpellChecking:")),
            keyEquivalent: ""
        ))
        spellingMenu.addItem(NSMenuItem(
            title: "Verificar gramática com ortografia",
            action: Selector(("toggleGrammarChecking:")),
            keyEquivalent: ""
        ))
        spellingMenu.addItem(NSMenuItem(
            title: "Corrigir ortografia automaticamente",
            action: Selector(("toggleAutomaticSpellingCorrection:")),
            keyEquivalent: ""
        ))
        spellingItem.submenu = spellingMenu
        editMenu.addItem(spellingItem)

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // ── Window menu — Minimize / Zoom / Close + Bring All
        //    to Front. Adding it lets `Cmd+W`, `Cmd+M`, etc.
        //    work as users expect on macOS.
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Janela")

        windowMenu.addItem(NSMenuItem(
            title: "Minimizar",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        ))
        windowMenu.addItem(NSMenuItem(
            title: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        ))
        windowMenu.addItem(NSMenuItem(
            title: "Fechar",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(
            title: "Trazer tudo para a frente",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        ))

        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Popover (shared content)

    private func buildPopover() {
        let p = NSPopover()
        p.contentSize = NSSize(width: 960, height: 620)
        p.behavior    = .semitransient
        p.contentViewController = NSHostingController(
            rootView: ContentView()
                .environmentObject(appState)
                .environmentObject(updateService)
        )
        popover = p
    }

    // MARK: - Window mode

    private func enableWindowMode() {
        NSApp.setActivationPolicy(.regular)

        // Remove menu bar item if present
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }

        if window == nil { makeMainWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeMainWindow() {
        // Standard titled NSWindow — corner rounding follows the
        // macOS default (matches the Claude.app window). Earlier
        // attempts to shrink the radius via CALayer masks were
        // ineffective on macOS 26 (the WindowServer paints the
        // outer silhouette outside the AppKit layer hierarchy)
        // and broke the system-supplied traffic lights when we
        // dropped `.titled` — so we accept the system radius.
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
            styleMask: [.titled, .closable, .miniaturizable,
                        .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title                        = "Apollo"
        // Minimum window size set to the dimensions the user
        // declared as the smallest comfortable layout — every
        // toolbar pill, the filter row and a usable portion of the
        // task list still fit at this size.
        // Both `minSize` (frame) and `contentMinSize` (content view)
        // are set so the floor holds whether the system measures
        // against the frame or the content view; the delegate
        // method `windowWillResize` is the third line of defence
        // (some resize gestures bypass AppKit's automatic minSize
        // enforcement).
        w.minSize                      = AppDelegate.windowMinFrameSize
        w.contentMinSize               = AppDelegate.windowMinFrameSize
        w.titlebarAppearsTransparent   = true
        w.titleVisibility              = .hidden
        // Remove the subtle separator line AppKit draws under
        // the title bar — without this the title-bar area still
        // reads as a distinct band even with isOpaque=false.
        w.titlebarSeparatorStyle       = .none
        // Translucent window so the Editorial+ sidebar's Liquid
        // Glass pane can pull vibrancy from whatever sits behind
        // the window. The chrome (toolbar + body) still paints
        // `Editorial.paper` over its own region in ContentView —
        // only the sidebar column actually shows through.
        w.backgroundColor              = .clear
        w.isOpaque                     = false

        // Performance hints — keep CoreAnimation in async-display mode and
        // let ProMotion screens drive the window at their full refresh
        // rate (up to 120 Hz). Without these, layer-backed SwiftUI views
        // can be capped to ~60 Hz on MacBook Pro / Studio Display.
        w.allowsConcurrentViewDrawing  = true
        w.displaysWhenScreenProfileChanges = true

        // Empty NSToolbar bumps the title-bar height to the
        // native ~52pt and lets macOS vertically centre the
        // traffic-light buttons inside it — lining them up with
        // the SwiftUI toolbar pills which also sit at 52pt.
        let toolbar = NSToolbar()
        toolbar.showsBaselineSeparator = false
        w.toolbar      = toolbar
        w.toolbarStyle = .unified

        w.center()
        w.setFrameAutosaveName("PainelLunarMain")

        // Hard clamp against the saved frame. macOS's
        // `setFrameAutosaveName` restores whatever size + origin
        // the user had last time, but the autosave plist can
        // hold values smaller than `minSize` (e.g. a previous
        // build with a lower floor, a corrupted preference, or
        // the user dragging the window with the cursor outside
        // the resize handle). When that happens AppKit silently
        // honors the saved size — task pills overflow the panel
        // and the cards look "cut" on the right.
        // Run the clamp AFTER the autosave restore: read the
        // resulting frame and grow it to the floor whenever a
        // dimension is below threshold. We also nudge the
        // origin onto the visible screen so a window restored
        // off-screen is recoverable.
        if let screen = w.screen ?? NSScreen.main {
            var f = w.frame
            let floor = AppDelegate.windowMinFrameSize
            if f.width  < floor.width  { f.size.width  = floor.width }
            if f.height < floor.height { f.size.height = floor.height }
            // Nudge back on-screen if autosave dropped us off.
            let visible = screen.visibleFrame
            if f.maxX > visible.maxX { f.origin.x = visible.maxX - f.width }
            if f.minX < visible.minX { f.origin.x = visible.minX }
            if f.maxY > visible.maxY { f.origin.y = visible.maxY - f.height }
            if f.minY < visible.minY { f.origin.y = visible.minY }
            if f != w.frame {
                w.setFrame(f, display: true, animate: false)
            }
        }
        let host = NSHostingController(
            rootView: ContentView()
                .environmentObject(appState)
                .environmentObject(updateService)
        )
        w.contentViewController = host
        w.delegate = self

        // Layer-backed compositing on the SwiftUI root — Core Animation
        // can hand the layer tree to Metal for compositing, which is the
        // fast path for any view with shadows / blur / clipping.
        if let cv = host.view as? NSView {
            cv.wantsLayer = true
            cv.layerContentsRedrawPolicy = .onSetNeedsDisplay
            cv.layer?.drawsAsynchronously = true
            // Clear, non-opaque host layer — the window itself
            // is opaque with `windowBackgroundColor`, so anywhere
            // the SwiftUI content doesn't paint reveals the OS
            // window background (which matches the paper canvas).
            cv.layer?.backgroundColor = NSColor.clear.cgColor
            cv.layer?.isOpaque        = false
        }

        // PERF: locked the foreground refresh rate at 60Hz
        // (was preferred 120Hz / range 80–120). At 120Hz the
        // per-frame budget is 8.3ms, but our SwiftUI scroll
        // work measures ~20ms mean — meaning the OS demanded
        // 120 frames/sec but the app could only deliver ~50,
        // and the WindowServer's ProMotion adaptive scaling
        // produced visible stutter as it kept jumping between
        // 80, 100, 120Hz looking for a sustainable rate. When
        // the window goes background, the OS falls back to a
        // calmer 60Hz (16.6ms budget) where our work fits, so
        // the user observed background scrolling looking
        // SMOOTHER than foreground — exactly the inversion of
        // what should happen.
        //
        // Locking the range to a single 60Hz value means:
        //   • Foreground and background now run at the same
        //     rate, equalising the perceived FPS gap.
        //   • Frame budget is 16.6ms — comfortable for the
        //     current SwiftUI workload; ~70% of frames already
        //     complete inside that window per our latest trace.
        //   • No more ProMotion adaptive jumps mid-scroll, so
        //     the few remaining slow frames don't get amplified
        //     into compounding stutter.
        //
        // If we get the per-frame work down to <8ms in a
        // future round, we can reopen the range to 120Hz —
        // but only after consistently hitting that budget.
        // PERF DATA (Animation Hitches traces):
        //   • 120Hz adaptive (orig 80-120 range):
        //       mean 20.6ms · 70% @ 60Hz · 10.6% severe
        //   • 60Hz LOCKED:
        //       mean 20.6ms · 72% @ 60Hz · 12.2% severe
        //   • 120Hz LOCKED (tried twice):
        //       mean 25-42ms · 0-67% @ 60Hz · 25-92% severe
        //
        // Forcing the displayLink to 120Hz when the per-frame
        // SwiftUI work measures ~20ms creates a runaway:
        // every 8.3ms tick demands a new frame, the OS misses
        // it, the queue backs up, and per-frame latency
        // BLOWS UP to 40+ms. The lock at 60Hz is the proven
        // sweet spot — frame budget (16.6ms) comfortably
        // accommodates the workload, foreground and
        // background render at the same cadence (closing the
        // gap the user reported), and the few remaining
        // slow frames degrade gracefully to 30Hz instead of
        // compounding into 5-FPS stutter.
        // Adaptive 60-120Hz: floor at 60Hz so frames that miss
        // a 120Hz tick degrade gracefully (16.6ms budget instead
        // of compounding stutter), ceiling at 120Hz so the
        // WindowServer can drive ProMotion at full rate when our
        // frame work fits the 8.3ms slot. Now that the task
        // list runs on `NSCollectionListView` (cell recycling
        // via NSHostingView pool), the per-frame SwiftUI work
        // for the visible rows dropped enough that 60-120Hz
        // adaptive is viable again — the previous hard-lock at
        // 120Hz created runaway because the work was 20+ms,
        // but with recycling we should fit inside 8.3ms most
        // of the time on the task column.
        if #available(macOS 14.0, *) {
            let displayLink = w.screen?.displayLink(
                target: self,
                selector: #selector(promotionTick(_:))
            )
            displayLink?.preferredFrameRateRange = CAFrameRateRange(
                minimum:    60,
                maximum:   120,
                preferred: 120
            )
            displayLink?.add(to: .main, forMode: .common)
            self.promotionDisplayLink = displayLink
        }

        // Override the green (zoom) traffic-light so a click
        // performs "Preencher" (Fill) — resize to the screen's
        // visibleFrame — instead of entering full-screen mode.
        // Strip `.fullScreenPrimary` so macOS doesn't bring up
        // the full-screen-tile dropdown on hover. Clicking
        // again toggles back to the previous frame.
        w.collectionBehavior.remove(.fullScreenPrimary)
        w.collectionBehavior.insert(.fullScreenAuxiliary)
        if let zoomButton = w.standardWindowButton(.zoomButton) {
            zoomButton.target = self
            zoomButton.action = #selector(toggleFillScreen(_:))
        }


        // Traffic-light buttons stay at macOS's natural
        // position. The earlier reposition attempt put
        // them inside the body (using the wrong coord
        // origin). Instead, we align the SwiftUI toolbar
        // pills DOWN to where the OS draws traffic lights
        // — see ContentView's toolbar `.frame(height:)`.

        w.makeKeyAndOrderFront(nil)
        window = w
    }

    /// Pre-fill window frame so the second click on the green button
    /// restores the user's previous size and position.
    private var preFillFrame: NSRect?

    @objc private func toggleFillScreen(_ sender: Any?) {
        guard let w = window else { return }
        guard let screen = w.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame

        if let saved = preFillFrame {
            // Already filled — restore previous size/position.
            preFillFrame = nil
            w.setFrame(saved, display: true, animate: true)
        } else {
            // Save current frame and snap to fill the visible screen
            // (visibleFrame excludes the macOS menu bar at the top and
            // the Dock when set to "always show").
            preFillFrame = w.frame
            w.setFrame(visible, display: true, animate: true)
        }
    }

    // MARK: - Menu bar mode

    private func enableMenuBarMode() {
        NSApp.setActivationPolicy(.accessory)

        // Close/release main window
        window?.close()
        window = nil

        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = item.button {
            btn.image = NSImage(systemSymbolName: "moon.stars.fill", accessibilityDescription: "Apollo")
            btn.action = #selector(togglePopover)
            btn.target = self
            btn.toolTip = "Apollo"
        }
        statusItem = item
    }

    @objc private func togglePopover() {
        guard let btn = statusItem?.button, let popover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - About panel

    /// Custom About panel handler. Backed by AppKit's
    /// `orderFrontStandardAboutPanel(options:)` — same chrome
    /// the system panel uses (icon + name + close button) but
    /// with our copy populated from `Info.plist` so the panel
    /// always reflects the shipping bundle, not whatever a
    /// developer typed once and forgot.
    ///
    ///   • `applicationName`     ← `CFBundleName`
    ///   • `applicationVersion`  ← `CFBundleShortVersionString`
    ///                              (the "marketing" version
    ///                              users see — e.g. "1.4.0")
    ///   • `version`             ← `CFBundleVersion`
    ///                              (the build number — shown
    ///                              in parentheses next to the
    ///                              marketing version)
    ///   • `credits`             ← attributed tagline + the
    ///                              copyright line; supports
    ///                              multi-line layout that
    ///                              the plain `String` slot
    ///                              for `.applicationVersion`
    ///                              does not.
    @objc func showAboutPanel(_ sender: Any?) {
        let appName = AppDelegate.infoString("CFBundleName")
            ?? ProcessInfo.processInfo.processName
        let marketingVersion = AppDelegate.infoString(
            "CFBundleShortVersionString") ?? "—"
        let buildNumber = AppDelegate.infoString("CFBundleVersion") ?? "—"
        let copyright = AppDelegate.infoString("NSHumanReadableCopyright")
            ?? "Apollo"

        // Multi-line credits: a brief tagline on top, the
        // copyright on the bottom. Centered + secondary-grey
        // to read like Apple's first-party panels.
        let creditsString = NSMutableAttributedString()
        creditsString.append(NSAttributedString(
            string: "Painel de produtividade — ClickUp + Calendário",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
        creditsString.append(NSAttributedString(string: "\n\n"))
        creditsString.append(NSAttributedString(
            string: copyright,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
        ))
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        creditsString.addAttribute(
            .paragraphStyle, value: para,
            range: NSRange(location: 0, length: creditsString.length)
        )

        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName:    appName,
            .applicationVersion: marketingVersion,
            .version:            buildNumber,
            .credits:            creditsString,
        ]
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // In menu bar mode, hide instead of close so the app stays alive
        if appState.menuBarMode {
            sender.orderOut(nil)
            return false
        }
        return true
    }

    /// Called by AppKit when the user double-clicks the window's title
    /// bar (assuming the system setting "Click in the window title bar
    /// to:" is set to **Zoom** — the macOS default). Routing the call
    /// through `toggleFillScreen` makes a title-bar double-click do the
    /// exact same Fill/restore toggle as the green traffic-light
    /// button. Returning `false` blocks AppKit's default zoom so we
    /// don't end up running both behaviors.
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        toggleFillScreen(nil)
        return false
    }

    /// Final clamp on every resize gesture. AppKit's `minSize` is
    /// honoured in the common case but skipped by some gestures
    /// (window-tiling drags, third-party resize tools, certain
    /// trackpad shortcuts) — returning a clamped size from the
    /// delegate is the only way to guarantee the floor in every
    /// path.
    func windowWillResize(_ sender: NSWindow,
                          to frameSize: NSSize) -> NSSize {
        let floor = AppDelegate.windowMinFrameSize
        return NSSize(
            width:  max(frameSize.width,  floor.width),
            height: max(frameSize.height, floor.height)
        )
    }
}

// MARK: - macOS Notification Center integration
//
// Routes click events from macOS notification banners back into the
// in-app deep-link handler. Also tells the system to keep showing
// banners while Apollo is the foreground app — by default macOS
// suppresses them, but our notifications are sync/event/task summaries
// where the user benefits from the consistent visibility.

extension AppDelegate: UNUserNotificationCenterDelegate {

    /// Decide what happens when a notification fires while Apollo is
    /// in the foreground. We opt in to banner + list (and sound for
    /// errors/warnings — set per-payload by `NativeNotifier`).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// Triggered when the user taps a banner, the "Abrir no Apollo"
    /// action, or the "Marcar como lida" action. Routes through
    /// AppState to re-use the same popup-opening / read-marking logic
    /// the bell-popup row uses.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let info = response.notification.request.content.userInfo
        let appNotifIdString = info[NativeNotifier.Key.appNotifId] as? String
        let appNotifId       = appNotifIdString.flatMap { UUID(uuidString: $0) }
        let targetKindRaw    = info[NativeNotifier.Key.targetKind] as? String
        let targetId         = info[NativeNotifier.Key.targetId]   as? String

        switch response.actionIdentifier {
        case "apollo.markRead":
            if let id = appNotifId {
                Task { @MainActor in appState.markNotificationRead(id) }
            }
        case "apollo.open", UNNotificationDefaultActionIdentifier:
            Task { @MainActor in
                appState.handleNativeNotificationTap(
                    appNotifId:    appNotifId,
                    targetKindRaw: targetKindRaw,
                    targetId:      targetId
                )
            }
        default:
            break
        }
    }
}
