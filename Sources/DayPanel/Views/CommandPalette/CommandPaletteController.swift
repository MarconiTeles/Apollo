import AppKit
import SwiftUI

// Owns the NSPanel that hosts the command palette and the
// keyDown monitor that routes ↑↓⏎⎋ to the model regardless
// of which subview holds focus. SwiftUI's `.onKeyPress` is
// flaky inside text fields (the field claims arrow keys for
// caret movement, return for submit), so we keep navigation
// in AppKit-land where we have full control.
//
// Lifecycle:
//   • `toggle()` — public entry point bound to ⌘K. Opens
//     if hidden, closes if visible.
//   • `open()`   — lazy-builds the panel on first call,
//     resets the model so a fresh palette opens with an
//     empty query, installs the local key monitor, then
//     centers + activates the window.
//   • `close()`  — orders out + uninstalls the monitor so
//     keystrokes don't keep getting intercepted while the
//     panel is hidden.
//   • `windowDidResignKey` — auto-closes when the user
//     clicks somewhere else (typical Spotlight feel).
// `@MainActor` annotation removed: callers (the AppDelegate
// menu selector + the lazy property in AppDelegate) aren't
// formally main-isolated under Swift 5.9's checking rules,
// even though every NSApplication callback DOES run on the
// main thread. Dropping the annotation keeps the code
// compiling without resorting to `MainActor.assumeIsolated`
// at every entry point. All AppKit methods used here are
// already main-thread only at runtime.
final class CommandPaletteController: NSObject, NSWindowDelegate {
    private weak var appState: AppState?
    private var model: CommandPaletteModel?
    private var panel: KeyablePanel?
    /// Local NSEvent monitor for keyDown events. Held only
    /// while the panel is visible — installed in `open()`,
    /// removed in `close()`. Stored so we can pass the same
    /// reference to `removeMonitor`.
    private var keyMonitor: Any?

    init(appState: AppState) {
        self.appState = appState
    }

    deinit {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
        }
    }

    // MARK: - Public

    func toggle() {
        if let p = panel, p.isVisible {
            close()
        } else {
            open()
        }
    }

    func open() {
        guard let appState else { return }
        if model == nil {
            model = CommandPaletteModel(appState: appState)
        }
        guard let model else { return }

        // Always reset for a fresh open — typing ⌘K should
        // feel like launching the palette, not resuming it.
        model.reset()

        // Build the panel directly at its target frame. The
        // previous approach (init at (0,0,640,420) → then
        // setFrameOrigin) was racing borderless NSPanel's
        // first-display layout pass — the FIRST open of a
        // session kept showing up at the screen's bottom-
        // left (which on a wide multi-monitor setup reads
        // as "top-right of the work display"). Passing the
        // computed frame straight into the NSPanel
        // initializer skips that race entirely.
        if panel == nil {
            panel = makePanel(model: model,
                              frame: targetFrame())
        } else {
            panel?.setFrame(targetFrame(),
                            display: false,
                            animate: false)
        }

        installKeyMonitor()
        panel?.makeKeyAndOrderFront(nil)
        // Re-apply belt-and-braces in case ordering front
        // re-flowed the frame on first display (observed on
        // some macOS versions for borderless panels).
        panel?.setFrame(targetFrame(),
                        display: false,
                        animate: false)
        NSApp.activate(ignoringOtherApps: true)
        // Mirror visibility into AppState so hover-bearing
        // surfaces (AppKit cells, SwiftUI rows) can gate
        // their effects while the palette is up.
        appState.commandPaletteOpen = true
    }

    func close() {
        panel?.orderOut(nil)
        uninstallKeyMonitor()
        appState?.commandPaletteOpen = false
    }

    // MARK: - Build

    private static let panelSize = NSSize(width: 640, height: 420)

    private func makePanel(model: CommandPaletteModel,
                            frame: NSRect)
        -> KeyablePanel
    {
        // Borderless, transparent background, soft shadow.
        // We render the rounded card + material from inside
        // SwiftUI so the panel itself only carries the
        // window-server bookkeeping (level, key handling,
        // shadow).
        let p = KeyablePanel(
            contentRect: frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.backgroundColor          = .clear
        p.isOpaque                 = false
        p.hasShadow                = true
        p.isFloatingPanel          = true
        p.becomesKeyOnlyIfNeeded   = false
        p.hidesOnDeactivate        = false
        p.isMovableByWindowBackground = true
        p.level                    = .modalPanel
        p.collectionBehavior       = [
            .transient, .ignoresCycle, .fullScreenAuxiliary,
        ]
        p.delegate = self

        let view = CommandPaletteView(
            model: model,
            onDismiss: { [weak self] in self?.close() },
            onPick: { [weak self] idx in
                guard let self, let model = self.model else { return }
                model.select(idx)
                if model.performSelection() {
                    self.close()
                }
            }
        )
        let host = NSHostingController(rootView: view)
        // Transparent host so the SwiftUI rounded card sits
        // on top of the system shadow without a square
        // backing artifact behind the corners.
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentViewController = host
        return p
    }

    /// Computes the full target frame the palette should
    /// occupy, in global screen coordinates. Used both to
    /// initialise the `NSPanel` (so the FIRST display lands
    /// in the right place — borderless panels can race
    /// `setFrameOrigin` calls that come after init) AND to
    /// reposition on every subsequent open.
    ///
    /// Two-step anchor:
    ///   1. Pick the SCREEN the user is currently on, via
    ///      `NSEvent.mouseLocation`. This is the most
    ///      reliable signal in multi-monitor setups —
    ///      independent of focus, window state, or which
    ///      `NSApp.mainWindow` the framework happens to
    ///      report at this moment.
    ///   2. If Apollo's dashboard window is on that same
    ///      screen, centre the palette on the dashboard
    ///      (BOTH axes); otherwise fall back to the
    ///      screen's centre. Centred-on-window beats
    ///      "Spotlight 12% above midpoint" here because
    ///      the palette is bound to the app — when Apollo
    ///      is the visible surface, the palette belongs at
    ///      its centre, not floating near the screen edge.
    private func targetFrame() -> NSRect {
        let size = Self.panelSize

        // 1. Cursor screen — most stable reference.
        let mouse = NSEvent.mouseLocation
        let cursorScreen = NSScreen.screens.first {
            $0.frame.contains(mouse)
        } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = cursorScreen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // 2. Default to screen-centre, then override with
        //    the dashboard's centre when the Apollo window
        //    lives on the same screen as the cursor — both
        //    axes, so the palette sits squarely in the
        //    middle of the work surface (X AND Y), not
        //    floating up near the screen's top edge.
        var x = visible.midX - size.width / 2
        var y = visible.midY - size.height / 2

        if let dashboard = dashboardWindow(),
           dashboard.screen === cursorScreen {
            x = dashboard.frame.midX - size.width / 2
            y = dashboard.frame.midY - size.height / 2
        }

        // Clamp to the cursor screen so a tiny anchor or a
        // window dragged half off-screen doesn't push the
        // palette into invisible territory.
        x = max(visible.minX + 8,
                min(visible.maxX - size.width - 8, x))
        y = max(visible.minY + 8,
                min(visible.maxY - size.height - 8, y))

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The Apollo dashboard window, if one exists and is
    /// visible. Used as the horizontal anchor when the
    /// cursor is on the same screen. Excludes:
    ///   • the palette's own panel,
    ///   • Sparkle update prompts + other small helpers
    ///     (filtered by minimum size).
    private func dashboardWindow() -> NSWindow? {
        if let main = NSApp.mainWindow,
           main !== panel,
           main.isVisible,
           main.frame.width  >= 320,
           main.frame.height >= 320 {
            return main
        }
        for w in NSApp.windows {
            if w === panel { continue }
            guard w.isVisible else { continue }
            guard w.styleMask.contains(.titled) else { continue }
            guard w.frame.width  >= 320,
                  w.frame.height >= 320 else { continue }
            return w
        }
        return nil
    }

    // MARK: - Key monitor

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown)
            { [weak self] event in
                self?.handle(event) ?? event
            }
    }

    private func uninstallKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    /// Returns nil to swallow the event; returns `event` to
    /// let it propagate to the focused responder (the text
    /// field). We claim only navigation keys.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let panel, panel.isKeyWindow,
              let model else { return event }

        // Hardware key codes — same on every Apple keyboard
        // layout because they're position-based, not
        // character-based.
        switch event.keyCode {
        case 126: // ↑
            model.selectPrev()
            return nil
        case 125: // ↓
            model.selectNext()
            return nil
        case 53:  // esc
            close()
            return nil
        case 36, 76: // return / numpad enter
            if model.performSelection() { close() }
            return nil
        default:
            return event
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // The panel just lost key. Auto-dismiss so the user
        // doesn't have to press Esc whenever they click on
        // something else — Spotlight's behaviour.
        close()
    }
}

// MARK: - KeyablePanel
//
// `NSPanel` defaults to `canBecomeKey == false` for
// borderless windows, which would block the SwiftUI
// `TextField` from receiving keystrokes. Override both so
// the panel takes key focus when ordered front, but never
// claims main (we don't want it stealing the role from the
// dashboard window).
final class KeyablePanel: NSPanel {
    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { false }
}
