import AppKit

/// Resolves the user's current cursor position into the
/// dashboard window's SwiftUI coordinate space. Used to anchor
/// spring-zoom popup transitions to the exact click point
/// without the cost of a `GeometryReader`.
///
/// Two callers today:
///
///   • The AI chat's task / event pills, which live inside an
///     `NSPopover` (its own NSWindow). Frames captured via
///     `.global` GeometryReader inside the popover belong to
///     the popover — NOT the main window where the detail
///     overlay actually paints. Translating through screen
///     coords keeps the spring anchored correctly.
///
///   • The dashboard's `TaskRowView` "open in popup" button.
///     Previously used `.captureFrame($openButtonOrigin)` which
///     forced a `GeometryReader` layout pass per row per render
///     (≈ 50 extra layout passes per scroll frame). Reading the
///     mouse position at click time is `O(1)` and adds zero
///     scroll-time work.
enum MouseOriginCapture {

    /// Returns a tiny rect (2×2) centred on the current cursor
    /// position, expressed in the dashboard window's SwiftUI
    /// coordinate space (top-left origin). `FloatingModal` and
    /// `EventDetailOverlay` both anchor their spring transition
    /// off `origin.midX/midY`, so a 2×2 rect is enough — its
    /// centre is the only thing they read.
    static func currentClickRectInMainWindow() -> CGRect {
        let screenPoint = NSEvent.mouseLocation
        guard let mainWindow = bestMainWindow() else { return .zero }

        // `screenPoint` and `window.frame` are both in screen
        // coordinates with a bottom-left origin. Subtract the
        // window's origin to get a window-local point (still
        // bottom-left).
        let frame = mainWindow.frame
        let xInWindow = screenPoint.x - frame.origin.x
        let yInWindowBottomLeft = screenPoint.y - frame.origin.y

        // Flip Y to match SwiftUI's top-left coord system —
        // `FloatingModal` does its math against `windowGeo.size`
        // which is also top-left.
        let topLeftY = frame.height - yInWindowBottomLeft

        return CGRect(x: xInWindow - 1,
                      y: topLeftY - 1,
                      width: 2,
                      height: 2)
    }

    /// Picks the dashboard window — the largest visible non-
    /// popover, non-panel window owned by the app. Filtering by
    /// `isVisible` and excluding `NSPanel` (popovers are hosted
    /// in `_NSPopoverWindow`, an `NSPanel` subclass) reliably
    /// returns ContentView's window even when an AI popover is
    /// on screen.
    private static func bestMainWindow() -> NSWindow? {
        let candidates = NSApp.windows.filter { win in
            win.isVisible
                && !(win is NSPanel)
                && win.contentView != nil
                && win.frame.width > 200
                && win.frame.height > 200
        }
        if let main = NSApp.mainWindow, candidates.contains(main) {
            return main
        }
        return candidates.max(by: {
            $0.frame.width * $0.frame.height
                < $1.frame.width * $1.frame.height
        })
    }
}
