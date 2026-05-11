import SwiftUI

// Wraps a popup body section in a ScrollView that sizes itself to its
// content up to `maxHeight`. Above that cap, the inner content scrolls
// while the popup chrome (header + footer) stays in place.
//
// Without this helper, popups with lots of inline content (e.g. Settings
// with one row per ClickUp status) grow off the bottom of the window.

struct ScrollablePopupContent<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content

    @State private var measured: CGFloat = 0

    var body: some View {
        ScrollView(showsIndicators: false) {
            content()
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ContentHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
        }
        .frame(height: min(max(measured, 1), maxHeight))
        // Without this the ScrollView's initial position can land
        // anywhere on macOS — the frame is recomputed after the
        // content height is measured, and SwiftUI sometimes preserves
        // the previous scroll offset (which corresponds to the OLD
        // smaller frame, leaving the top of the content visually
        // clipped above the viewport). Explicit `.top` anchor pins
        // every popup to its first row regardless of remeasure.
        .defaultScrollAnchor(.top)
        .onPreferenceChange(ContentHeightKey.self) { measured = $0 }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
