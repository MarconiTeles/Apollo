import AppKit
import OSLog
import WebKit

/// Owns the transparent `WKWebView` that plays one React loading scene
/// (`web/apollo-loading`, shipped as `Contents/Resources/ApolloLoading`).
///
/// The native skeleton stays on screen until the scene reports `ready`
/// (its first frame is painted), so the hand-over is invisible. Any failure
/// — missing resource, script error, crashed WebContent process, slow start —
/// simply leaves the native skeleton in place.
@MainActor
final class SyncLoadingController: NSObject, ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var webView: WKWebView?
    private var lastPushed: SyncLoadingSnapshot?
    private var readyWatchdog: Timer?

    private static let log = Logger(subsystem: "com.painellunar.app", category: "SyncLoading")
    /// Past this the scene would appear after most loads already finished —
    /// better to stay on the native skeleton than to flash a late swap.
    private static let readyTimeout: TimeInterval = 1.5
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    /// Spins the scene up. Idempotent while a scene is alive.
    func start(_ initial: SyncLoadingSnapshot) {
        guard webView == nil else { return }
        guard let url = Self.sceneURL(),
              let json = Self.json(initial) else {
            Self.log.error("ApolloLoading resource missing — keeping native skeleton")
            return
        }
        let webView = Self.makeWebView(handler: WeakLoadingHandler(target: self), bootstrap: json)
        webView.navigationDelegate = self
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
        self.webView = webView
        isReady = false
        lastPushed = initial
        readyWatchdog = Timer.scheduledTimer(withTimeInterval: Self.readyTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isReady else { return }
                Self.log.error("ApolloLoading not ready in time — keeping native skeleton")
                self.tearDown()
            }
        }
    }

    /// Sends a new snapshot; identical snapshots are dropped.
    func push(_ snapshot: SyncLoadingSnapshot) {
        guard snapshot != lastPushed, let webView, let json = Self.json(snapshot) else { return }
        lastPushed = snapshot
        webView.evaluateJavaScript("window.apolloLoading && window.apolloLoading.update(\(json))")
    }

    func tearDown() {
        readyWatchdog?.invalidate()
        readyWatchdog = nil
        guard let webView else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "apollo")
        webView.removeFromSuperview()
        self.webView = nil
        lastPushed = nil
        isReady = false
    }

    // MARK: - Bridge

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            guard webView != nil else { return }
            readyWatchdog?.invalidate()
            isReady = true
        case "error":
            let detail = message["message"] as? String ?? "unknown"
            Self.log.error("ApolloLoading script error: \(detail, privacy: .public)")
            if !isReady { tearDown() }
        default:
            break
        }
    }

    // MARK: - Setup

    private static func json(_ snapshot: SyncLoadingSnapshot) -> String? {
        guard let data = try? encoder.encode(snapshot) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func sceneURL() -> URL? {
        #if DEBUG
        // `APOLLO_LOADING_URL=http://localhost:5318` points a debug build at
        // the Vite dev server for live iteration on the scenes.
        if let override = ProcessInfo.processInfo.environment["APOLLO_LOADING_URL"],
           let url = URL(string: override) {
            return url
        }
        #endif
        return Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "ApolloLoading")
    }

    private static func makeWebView(handler: WKScriptMessageHandler, bootstrap json: String) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        configuration.websiteDataStore = .nonPersistent()
        let content = configuration.userContentController
        content.add(handler, name: "apollo")
        // The first snapshot is in place before any script runs, so the very
        // first painted frame is already the truthful one.
        content.addUserScript(WKUserScript(source: "window.__APOLLO_LOADING__ = \(json);",
                                           injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true))

        let webView = PassthroughWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.setAccessibilityElement(false)
        return webView
    }
}

extension SyncLoadingController: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Self.log.error("ApolloLoading web process terminated")
        tearDown()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.log.error("ApolloLoading navigation failed: \(error.localizedDescription, privacy: .public)")
        tearDown()
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        Self.log.error("ApolloLoading load failed: \(error.localizedDescription, privacy: .public)")
        tearDown()
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // One self-contained document; nothing may navigate.
        decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
    }
}

/// A loading scene is pure presentation: clicks, scrolls and drags belong to
/// whatever sits underneath (the board's scroll view, the toolbar…).
private final class PassthroughWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

/// `WKUserContentController` retains its handlers strongly; this proxy lets
/// the controller (and its web view) deallocate with the surface.
private final class WeakLoadingHandler: NSObject, WKScriptMessageHandler {
    weak var target: SyncLoadingController?

    init(target: SyncLoadingController) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.receive(message.body) }
    }
}
