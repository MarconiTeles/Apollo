import AppKit

/// Stable public entry point used by the tiny production executable target.
/// All of Apollo's implementation remains in `ApolloRuntime`, which is also
/// what the isolated Apollo Studio host renders.
public enum ApolloRuntimeLauncher {
    @MainActor private static var retainedDelegate: AppDelegate?

    public static func runProductionApp() {
        precondition(Thread.isMainThread, "Apollo must start on the main thread")
        MainActor.assumeIsolated {
            let application = NSApplication.shared
            let delegate = AppDelegate()
            retainedDelegate = delegate
            application.delegate = delegate
            application.run()
        }
    }
}
