import AppKit

/// Native content can render under a SwiftUI header without receiving its clicks.
@MainActor
protocol HeaderOccludingViewport: AnyObject {
    var headerOcclusionHeight: CGFloat { get }
}

extension NSView {
    /// Tracking areas still receive events behind sibling SwiftUI surfaces,
    /// independently of hitTest. Use the same boundary for hover and clicks.
    func isBehindPageHeader(windowPoint: NSPoint) -> Bool {
        var ancestor: NSView? = self
        while let view = ancestor {
            if let viewport = view as? HeaderOccludingViewport {
                let point = view.convert(windowPoint, from: nil)
                let distanceFromTop = view.isFlipped
                    ? point.y - view.bounds.minY : view.bounds.maxY - point.y
                if distanceFromTop >= 0 && distanceFromTop < viewport.headerOcclusionHeight {
                    return true
                }
            }
            ancestor = view.superview
        }
        return false
    }
}
