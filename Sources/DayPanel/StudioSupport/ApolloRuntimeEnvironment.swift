import Foundation

/// Process-wide runtime boundary shared by Apollo and Apollo Studio.
///
/// Apollo Studio is intentionally an offline development host. It renders the
/// production view tree, but it must never inherit the production app's
/// Keychain, legacy secret snapshot, synchronization timers or local AI
/// daemons. The Studio executable activates this mode before constructing any
/// ApolloRuntime value.
public enum ApolloRuntimeEnvironment {
    private static let studioFlag = "APOLLO_STUDIO_OFFLINE"

    /// Activates the isolated Studio environment for the lifetime of this
    /// process. This is deliberately one-way: switching a live process back to
    /// production could expose objects that were constructed under different
    /// security assumptions.
    public static func activateStudio() {
        setenv(studioFlag, "1", 1)
        ApolloStudioNetworkBlocker.activate()
    }

    public static var isStudio: Bool {
        ProcessInfo.processInfo.environment[studioFlag] == "1"
    }

    /// Fails loudly in DEBUG if a Studio-only surface is accidentally mounted
    /// without activating the isolation boundary first.
    public static func assertStudioIsolation(
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        precondition(isStudio,
                     "Apollo Studio must activate its offline runtime before creating Apollo views.",
                     file: file,
                     line: line)
    }
}

/// Defense in depth for accidental URLSession use from an interactive Studio
/// fixture. The canvas selection overlay normally prevents production actions
/// from firing, and AppState preview mode never starts sync, but blocking HTTP
/// at the process boundary makes an accidental future call fail locally rather
/// than touching ClickUp, Google or an LLM endpoint.
private final class ApolloStudioOfflineURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard ApolloRuntimeEnvironment.isStudio,
              let scheme = request.url?.scheme?.lowercased()
        else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let error = NSError(
            domain: "ApolloStudio.Offline",
            code: NSURLErrorNotConnectedToInternet,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Apollo Studio is offline and blocked a network request.",
                NSURLErrorFailingURLErrorKey: request.url as Any,
            ]
        )
        client?.urlProtocol(self, didFailWithError: error)
    }

    override func stopLoading() {}
}

private enum ApolloStudioNetworkBlocker {
    private static let lock = NSLock()
    private static var active = false

    static func activate() {
        lock.lock()
        defer { lock.unlock() }
        guard !active else { return }
        URLProtocol.registerClass(ApolloStudioOfflineURLProtocol.self)
        active = true
    }
}
