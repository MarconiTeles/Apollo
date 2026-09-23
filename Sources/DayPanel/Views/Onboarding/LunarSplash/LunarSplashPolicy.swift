import Foundation

/// When the launch splash may leave. Pure so the timing contract is testable
/// without a web view:
///
/// - never before `minimumVisible` (3 s — the brand moment always plays);
/// - never before the web intro reports it finished, so the choreography is
///   not cut mid-letter;
/// - then as soon as the dashboard has something truthful to show;
/// - but never later than `maximumWait`, even offline or with a stuck web
///   process — the native skeletons take over from there.
enum LunarSplashPolicy {
    static let minimumVisible: TimeInterval = 3.0
    static let maximumWait: TimeInterval = 12.0
    /// How long the native backdrop waits for the web view's first frame
    /// before switching to the native fallback mark.
    static let webReadyTimeout: TimeInterval = 2.0
    /// Safety net if the web reveal never reports `finished`.
    static let revealTimeout: TimeInterval = 2.5

    enum Decision: Equatable {
        case hold
        case exit
    }

    static func decide(elapsed: TimeInterval,
                       introComplete: Bool,
                       dataReady: Bool) -> Decision {
        if elapsed >= maximumWait { return .exit }
        guard elapsed >= minimumVisible, introComplete, dataReady else { return .hold }
        return .exit
    }

    /// The dashboard is "ready" once real rows exist, or once nothing is in
    /// flight (signed-out, empty list, or offline with nothing cached).
    static func isDataReady(hasTasks: Bool, isSyncing: Bool) -> Bool {
        hasTasks || !isSyncing
    }
}
