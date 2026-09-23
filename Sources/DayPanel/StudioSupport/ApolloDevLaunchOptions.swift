import Foundation

/// Launch arguments understood ONLY by the DEV build compiled with
/// `-Xswiftc -DAPOLLO_DEV` (see `script/build_dev_board_appkit.sh`).
///
/// The type is always compiled so call sites need no `#if`, but outside
/// `APOLLO_DEV` every accessor returns `nil`/`false`: production and DEBUG
/// builds ignore these arguments entirely.
///
///   --board-renderer=swiftui|appkit   renderer selector (read-only here)
///   --board-fixtures=<N>              offline AppState with N deterministic tasks
///   --route=inbox|tasks|board|comments initial sidebar route
///   --appearance=light|dark|system    appearance override for this launch
enum ApolloDevLaunchOptions {

    struct Parsed: Equatable {
        var boardRenderer: String?
        var boardFixtureCount: Int?
        var route: String?
        var appearance: String?
    }

    static let supportedRenderers: Set<String> = ["swiftui", "appkit"]
    static let supportedRoutes: Set<String> = ["inbox", "today", "tasks", "board", "comments"]
    static let supportedAppearances: Set<String> = ["light", "dark", "system"]
    static let maxFixtureCount = 100_000

    /// Pure parser (always compiled, unit-tested). Unknown or invalid values
    /// are dropped rather than guessed. Accepts `--key=value` only.
    static func parse(_ arguments: [String]) -> Parsed {
        var out = Parsed()
        for arg in arguments {
            guard arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") else { continue }
            let key = String(arg[arg.index(arg.startIndex, offsetBy: 2)..<eq])
            let value = String(arg[arg.index(after: eq)...]).lowercased()
            switch key {
            case "board-renderer":
                if supportedRenderers.contains(value) { out.boardRenderer = value }
            case "board-fixtures":
                if let n = Int(value), n > 0, n <= maxFixtureCount { out.boardFixtureCount = n }
            case "route":
                if supportedRoutes.contains(value) { out.route = value }
            case "appearance":
                if supportedAppearances.contains(value) { out.appearance = value }
            default:
                continue
            }
        }
        return out
    }

    /// True only in the DEV build.
    static var isDevBuild: Bool {
        #if APOLLO_DEV
        return true
        #else
        return false
        #endif
    }

    /// Parsed once per process; empty outside the DEV build.
    static let current: Parsed = {
        #if APOLLO_DEV
        return parse(ProcessInfo.processInfo.arguments)
        #else
        return Parsed()
        #endif
    }()

    /// `"swiftui"`, `"appkit"` or `nil` (not given / not a DEV build).
    static var boardRenderer: String? { current.boardRenderer }

    static var boardFixtureCount: Int? { current.boardFixtureCount }

    static var isFixtureMode: Bool { boardFixtureCount != nil }

    static var initialRoute: SidebarRoute? {
        switch current.route {
        case "inbox", "today": .today
        case "tasks": .tasks
        case "board": .board
        case "comments": .assignedComments
        default: nil
        }
    }

    static var appearanceOverride: AppearanceMode? {
        current.appearance.flatMap(AppearanceMode.init(rawValue:))
    }

    #if APOLLO_DEV
    /// Title used by the main window (the title bar text is hidden, so this
    /// only identifies the window in Mission Control, the Window menu,
    /// screenshots and accessibility — no layout change).
    static var windowTitle: String {
        isFixtureMode
            ? "Apollo DEV · DADOS DE TESTE (\(boardFixtureCount ?? 0) tarefas)"
            : "Apollo DEV Board AppKit"
    }

    /// Builds the offline fixture `AppState`, or `nil` when
    /// `--board-fixtures` was not given. Must run before any other
    /// ApolloRuntime state is constructed: it activates the offline runtime
    /// boundary (in-memory secret store, HTTP blocked for URLSession.shared,
    /// `initialize()` inert) exactly like Apollo Studio.
    static func makeFixtureAppState() -> AppState? {
        guard let count = boardFixtureCount else { return nil }
        ApolloRuntimeEnvironment.activateStudio()
        // Fresh, deterministic view preferences (card order, subtask toggle…)
        // in the separate fixtures suite on every fixture launch.
        ApolloPreviewFixtures.defaults.removePersistentDomain(
            forName: ApolloPreviewFixtures.defaultsSuiteName)
        let state = AppState.preview(.populated)
        state.tasks = ApolloBoardFixtureGenerator.tasks(count: count)
        if let appearance = appearanceOverride {
            // Assign directly: `setAppearanceMode` would persist the choice.
            state.appearanceMode = appearance
        }
        NSLog("[Apollo DEV] fixture mode: %d tasks, renderer=%@, route=%@",
              count, boardRenderer ?? "default", current.route ?? "default")
        return state
    }
    #endif
}
