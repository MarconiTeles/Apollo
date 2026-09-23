import AppKit

/// Positions AppKit's existing window buttons; AppKit retains their drawing,
/// dimensions, spacing, hover tracking and target/actions.
enum SidebarTrafficLights {
    static func align(in window: NSWindow) {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27,
              let close = window.standardWindowButton(.closeButton),
              let content = window.contentView else { return }

        // The sidebar is inset 10pt; its heading/content starts another 20pt in.
        // Use the same visible inset above and to the left of the controls.
        let inset: CGFloat = 10 + 20
        let contentFrame = content.convert(content.bounds, to: nil)
        let closeFrame = close.convert(close.bounds, to: nil)
        let nativeInsets = close.alignmentRectInsets
        let visibleDiameter = close.bounds.height - nativeInsets.top - nativeInsets.bottom
        let horizontalInset = max(0, (close.bounds.width - visibleDiameter) / 2)
        let delta = NSPoint(
            x: contentFrame.minX + inset - horizontalInset - closeFrame.minX,
            y: contentFrame.maxY - inset + nativeInsets.top - closeFrame.maxY
        )

        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind),
                  let parent = button.superview else { continue }
            let frame = button.convert(button.bounds, to: nil)
                .offsetBy(dx: delta.x, dy: delta.y)
            button.setFrameOrigin(parent.convert(frame, from: nil).origin)
        }
    }
}
