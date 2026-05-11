import AppKit

// Centralised haptic-feedback helpers. Wraps
// `NSHapticFeedbackManager` so the rest of the app can call
// semantically-named methods (`taskAction`, `toggle`, etc.)
// instead of remembering which `FeedbackPattern` constant to
// use at each call site.
//
// Hardware coverage: Force Touch trackpads on MacBooks
// (2015+) and external Magic Trackpads (2nd gen+). On
// machines without a haptic-capable input device the calls
// are no-ops by design — the system silently swallows them.
enum Haptics {

    /// Discrete commit feedback — task marked done, status
    /// transitioned, swipe slammed home. Equivalent to a
    /// "thunk into place" sensation.
    ///
    /// `after`: delay in seconds before firing. Use this to
    /// land the haptic at the END of a visual animation
    /// (e.g. when a row finishes its slide-out). Without
    /// the delay the system click + our haptic stack
    /// simultaneously and read as a single muddier event;
    /// landing the haptic when the animation completes
    /// gives a clean "click… …snap" perception instead.
    ///
    /// Internally this is a DOUBLE perform (two pulses
    /// 35ms apart). One pulse alone is barely perceptible
    /// over the natural Force Touch click; two stacked
    /// pulses produce a clearly stronger "double-thunk"
    /// the user can feel even on top of a heavy click.
    static func taskAction(after delay: TimeInterval = 0) {
        fire(pattern: .levelChange, doubleTap: true, after: delay)
    }

    /// Soft toggle feedback — chevron expand/collapse,
    /// status picker selection, picker dismissal. Single
    /// pulse, slightly less assertive than `taskAction`
    /// but still strong enough to feel through a click.
    static func toggle(after delay: TimeInterval = 0) {
        fire(pattern: .levelChange, doubleTap: false, after: delay)
    }

    /// Generic confirmation — popup open, jump to today,
    /// other low-stakes actions where a faint nudge is
    /// reassuring. Uses `.alignment` (the softest) so it
    /// doesn't compete with the click.
    static func generic(after delay: TimeInterval = 0) {
        fire(pattern: .alignment, doubleTap: false, after: delay)
    }

    // MARK: - Plumbing

    private static func fire(pattern: NSHapticFeedbackManager.FeedbackPattern,
                             doubleTap: Bool,
                             after delay: TimeInterval) {
        let body = {
            let perf = NSHapticFeedbackManager.defaultPerformer
            perf.perform(pattern, performanceTime: .now)
            if doubleTap {
                // ~35ms apart — far enough to register as
                // two pulses, close enough to be perceived
                // as one stronger event.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) {
                    perf.perform(pattern, performanceTime: .now)
                }
            }
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
        } else {
            body()
        }
    }
}
