import SwiftUI
import AppKit

/// Transparent NSView wrapper that opts into AppKit's
/// drag-the-window-by-this-area behaviour. Apollo's main window
/// uses `.fullSizeContentView` + `titlebarAppearsTransparent` so
/// the SwiftUI toolbar can paint up to y=0 — but that means the
/// title-bar region is COVERED by SwiftUI views which catch
/// `mouseDown` first. The native title bar's drag handler never
/// gets a chance to fire, so the user can't grab the window
/// from the top to move it.
///
/// `NSView.mouseDownCanMoveWindow` is the documented AppKit
/// opt-in: when an `NSView` returns `true` from this property
/// AND the click lands inside its bounds (and no closer-to-front
/// view catches the click first), AppKit treats the click as a
/// window-move drag. Layering one of these as the BACKGROUND of
/// the toolbar means:
///
///   - clicks on actual buttons / pills hit them first (they're
///     above the drag area in the SwiftUI render order)
///   - clicks on empty toolbar space pass through to the drag
///     area → AppKit drags the window
///
/// This is the same trick most native-feeling macOS SwiftUI apps
/// use (Notion, Linear, Things 3, Tot, etc.). Lightweight — just
/// a clear NSView with one property override.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DraggableNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class DraggableNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}
