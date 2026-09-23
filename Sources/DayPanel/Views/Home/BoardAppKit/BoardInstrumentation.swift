import Foundation
import os

/// DEV instrumentation for the AppKit board. Signposts cost nothing unless
/// Instruments records the "Points of Interest"/custom log; counters are
/// logged at most every five seconds, never per scroll tick.
enum BoardInstrumentation {
    static let subsystem = "com.painellunar.app.board-appkit"
    static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
    static let log = Logger(subsystem: subsystem, category: "BoardAppKit")

    @inline(__always)
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    struct Counters {
        var applies = 0
        var columnUpdates = 0
        var tiles = 0
        var binds = 0
        var heightRecomputes = 0
    }

    @MainActor static var counters = Counters()
}

/// DEV-only render-cost isolation switches, read from the `BOARD_DIAG`
/// launch argument (`--board-diag=nocontent,nosurface`). They exist only to
/// attribute cost in traces; they are never an acceptable delivery state.
enum BoardDiag {
    static let flags: Set<String> = {
        #if APOLLO_DEV
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--board-diag=") })
        else { return [] }
        return Set(arg.dropFirst("--board-diag=".count).split(separator: ",").map(String.init))
        #else
        return []
        #endif
    }()
    static func has(_ flag: String) -> Bool { flags.contains(flag) }
}
