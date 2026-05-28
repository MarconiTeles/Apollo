import SwiftUI

// Universal "items cascade into view" modifier.
//
// Pattern: instead of a spinner + "loading…" copy (which falsely
// implies "no data"), every canvas leaves its rows EMPTY while
// data is in flight (the global `EditorialSyncBar` carries the
// progress signal), and when rows mount they fade + lift in with
// a tiny per-index delay. The wave reads as "things are arriving"
// without claiming there's nothing to see.
//
// Caveats / design choices:
//
//   • Delay is CAPPED so far-down rows revealed by scrolling
//     don't wait absurdly long (a row at index 50 would otherwise
//     idle for 1.5s before fading in). After the first viewport's
//     worth of items, the delay flat-lines at the cap value.
//
//   • The animation lives on a per-row `@State` flag → independent
//     of parent re-renders. A LazyVStack mounting a new row
//     triggers its own onAppear → its own cascade start.
//
//   • Subsequent re-renders (data refresh) DON'T re-fire the
//     cascade — once `appeared` is true it stays true. Refreshes
//     swap in new data with a soft fade only (no replay).

extension View {
    /// Apply a staggered fade-in to a row at `index` in a list.
    /// First ~12 rows cascade at `step` per row (default 28ms);
    /// further rows appear instantly with just an opacity fade
    /// so scrolling-revealed items don't lag.
    func cascadeAppear(
        index: Int,
        step: Double = 0.028,
        cap: Double = 0.34
    ) -> some View {
        modifier(CascadeAppearModifier(index: index, step: step, cap: cap))
    }
}

private struct CascadeAppearModifier: ViewModifier {
    let index: Int
    let step: Double
    let cap: Double

    @State private var appeared: Bool = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 6)
            .onAppear {
                let delay = min(Double(index) * step, cap)
                withAnimation(
                    .spring(response: 0.45, dampingFraction: 0.86)
                        .delay(delay)
                ) {
                    appeared = true
                }
            }
    }
}
