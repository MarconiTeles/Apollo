import SwiftUI
import Combine

// Shared state between `CommandPaletteView` (renders) and
// `CommandPaletteController` (owns the NSPanel + a keyDown
// monitor for ↑↓⏎⎋ that bypass SwiftUI's text-field
// focus). The controller pushes navigation events into this
// model — `selectNext()`, `selectPrev()`, `performSelection()`
// — and the view simply observes `query`, `selectedIndex`,
// and `items`.
//
// Lives on the main actor: every published property is read
// from SwiftUI's main-thread body re-evaluations and
// mutated from the AppKit key-monitor callback (also main).
// Same reason as `CommandPaletteController` — kept off
// `@MainActor` so the AppDelegate's lazy property (which
// the compiler treats as nonisolated under Swift 5.9) can
// instantiate it synchronously. The model is only ever
// touched from the SwiftUI body + the controller's
// keyDown monitor, both of which run on main at runtime.
final class CommandPaletteModel: ObservableObject {
    @Published var query: String = "" {
        didSet { recompute() }
    }
    @Published private(set) var selectedIndex: Int = 0
    @Published private(set) var items: [CommandPaletteItem] = []
    /// Bumped every time `items` is replaced. The view
    /// observes this token to reset scroll position the
    /// moment the result set changes (otherwise a partial
    /// scroll from the previous query carries over and the
    /// LazyVStack jumps to a row that no longer exists at
    /// the same index).
    @Published private(set) var itemsVersion: Int = 0
    /// Bumped only by keyboard navigation (`selectNext` /
    /// `selectPrev`). The view uses this — NOT
    /// `selectedIndex` — as the scroll trigger so hovering
    /// a row updates the highlight without dragging the
    /// scroll viewport along with the cursor. Mouse hover
    /// changes `selectedIndex` directly (via `select(_:)`)
    /// but doesn't bump this token.
    @Published private(set) var keyboardNavToken: Int = 0
    /// True while the user is actively driving the result
    /// list with the keyboard. Set when `selectNext` /
    /// `selectPrev` fires, cleared when real cursor
    /// movement is detected (via `.onContinuousHover` in
    /// the view). The view reads this to suppress mouse-
    /// hover highlights while keyboard nav is in effect —
    /// otherwise the secondary "mouse hover" tint would
    /// keep showing on whatever row the cursor happens to
    /// be sitting over even though the user is driving
    /// with arrows.
    @Published private(set) var keyboardNavActive: Bool = false

    private let appState: AppState
    private var taskSubscription: AnyCancellable?

    init(appState: AppState) {
        self.appState = appState
        recompute()
        // Re-run matching whenever the underlying tasks list
        // changes — handy when a sync lands while the
        // palette is open and the user has typed a query
        // that suddenly has new matches.
        taskSubscription = appState.$tasks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
    }

    /// Resets the query + selection. Called by the
    /// controller right before the panel re-opens so a
    /// re-trigger of ⌘K starts fresh instead of resuming
    /// whatever the user typed last time.
    func reset() {
        query = ""
        selectedIndex = 0
        keyboardNavActive = false
    }

    /// Move the highlighted row down one. Stays clamped at
    /// the last item; doesn't wrap. Bumps
    /// `keyboardNavToken` so the view auto-scrolls the new
    /// selection into view, and flips `keyboardNavActive`
    /// so the view drops any mouse-hover tint until the
    /// user actually moves the cursor again.
    func selectNext() {
        guard !items.isEmpty else { return }
        selectedIndex = min(items.count - 1, selectedIndex + 1)
        keyboardNavToken &+= 1
        if !keyboardNavActive { keyboardNavActive = true }
    }

    /// Move up one — stays clamped at 0. Same side effects
    /// as `selectNext`.
    func selectPrev() {
        guard !items.isEmpty else { return }
        selectedIndex = max(0, selectedIndex - 1)
        keyboardNavToken &+= 1
        if !keyboardNavActive { keyboardNavActive = true }
    }

    /// Called from the view when real cursor movement is
    /// detected (`.onContinuousHover` reporting an `.active`
    /// phase with a changing location). Hands control back
    /// to the mouse so subsequent hovers paint the
    /// secondary highlight again.
    func resumeMouseMode() {
        if keyboardNavActive { keyboardNavActive = false }
    }

    /// Move selection to a specific row (hover + tap path).
    /// Does NOT bump `keyboardNavToken` — hovering must
    /// never drag the viewport along with the cursor, which
    /// would create a feedback loop the user can't escape
    /// (cursor lands on a row → row scrolls under cursor →
    /// cursor lands on the row that just took its place →
    /// repeat).
    func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
    }

    /// Fires the selected row's `perform` closure. Returns
    /// `true` if there was something to fire — the
    /// controller uses this to decide whether to close the
    /// panel (only on a real action, never on an empty
    /// list).
    @discardableResult
    func performSelection() -> Bool {
        guard items.indices.contains(selectedIndex) else { return false }
        items[selectedIndex].perform()
        return true
    }

    // MARK: - Private

    private func recompute() {
        items = CommandPaletteEngine.match(
            query: query,
            appState: appState)
        itemsVersion &+= 1
        // Reset highlight to the top whenever the result
        // set actually changes — previously we just
        // clamped, which left the cursor mid-list after a
        // query refresh and the auto-scroll jumped to a row
        // that bore no relation to where the user was
        // looking.
        selectedIndex = 0
    }
}
