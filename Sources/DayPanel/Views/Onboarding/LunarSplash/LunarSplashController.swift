import AppKit
import OSLog
import WebKit

/// Owns the transparent `WKWebView` that plays the React launch splash
/// (`web/apollo-splash`, shipped as `Contents/Resources/ApolloSplash`).
///
/// Lifecycle: `loading` (native backdrop covers the window while WebKit
/// spins up) → `playing` (web scene drew its first frame) → `exiting`
/// (reveal iris opening onto the dashboard) → `finished`. Any failure —
/// missing bundle resource, WebGL/JS error before the first frame, a crashed
/// WebContent process, or a slow start — drops to `fallback`, a quiet native
/// mark that still honours the 3 s minimum.
@MainActor
final class LunarSplashController: NSObject, ObservableObject {
    enum Stage: Equatable {
        case loading
        case playing
        case fallback
        case exiting
        case finished
    }

    @Published private(set) var stage: Stage = .loading
    /// True while the native fallback mark is fading out.
    @Published private(set) var fallbackExiting = false

    var onRevealStart: () -> Void = {}
    var onFinished: () -> Void = {}
    var dataReady = false {
        didSet { evaluate() }
    }

    private(set) var webView: WKWebView?
    private var usesWeb = false
    private var mountedAt: Date?
    private var introComplete = false
    private var ticker: Timer?
    private var revealWatchdog: Timer?

    private static let log = Logger(subsystem: "com.painellunar.app", category: "LunarSplash")

    override init() {
        super.init()
        guard let url = Self.splashURL() else {
            Self.log.error("ApolloSplash resource missing — using native fallback")
            return
        }
        let webView = Self.makeWebView(handler: WeakScriptHandler(target: self))
        webView.navigationDelegate = self
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
        self.webView = webView
        usesWeb = true
    }

    /// Starts the clock. Called once the splash view is on screen.
    func begin() {
        guard mountedAt == nil else { return }
        mountedAt = Date()
        if !usesWeb { enterFallback() }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
    }

    // MARK: - Timing

    private var elapsed: TimeInterval {
        mountedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    private func evaluate() {
        guard mountedAt != nil else { return }
        switch stage {
        case .loading:
            if elapsed >= LunarSplashPolicy.webReadyTimeout {
                Self.log.error("ApolloSplash did not report ready in time — using native fallback")
                enterFallback()
            }
        case .playing, .fallback:
            let decision = LunarSplashPolicy.decide(elapsed: elapsed,
                                                    introComplete: introComplete,
                                                    dataReady: dataReady)
            if decision == .exit { beginExit() }
        case .exiting, .finished:
            break
        }
    }

    private func enterFallback() {
        guard stage == .loading || stage == .playing else { return }
        tearDownWebView()
        introComplete = true
        stage = .fallback
    }

    private func beginExit() {
        let wasPlaying = stage == .playing
        stage = .exiting
        if wasPlaying, let webView {
            webView.evaluateJavaScript("window.apolloSplash && window.apolloSplash.exit()")
            revealWatchdog = Timer.scheduledTimer(withTimeInterval: LunarSplashPolicy.revealTimeout,
                                                  repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            }
        } else {
            onRevealStart()
            fallbackExiting = true
            Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            }
        }
    }

    private func finish() {
        guard stage != .finished else { return }
        stage = .finished
        ticker?.invalidate()
        revealWatchdog?.invalidate()
        tearDownWebView()
        onFinished()
    }

    private func tearDownWebView() {
        guard let webView else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "apollo")
        webView.removeFromSuperview()
        self.webView = nil
    }

    // MARK: - Bridge

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            guard stage == .loading else { return }
            stage = .playing
            webView?.evaluateJavaScript("window.apolloSplash.start()")
        case "introComplete":
            introComplete = true
            evaluate()
        case "revealStart":
            onRevealStart()
        case "finished":
            finish()
        case "error":
            let detail = message["message"] as? String ?? "unknown"
            Self.log.error("ApolloSplash script error: \(detail, privacy: .public)")
            if stage == .loading { enterFallback() }
        default:
            break
        }
    }

    // MARK: - Setup

    private static func splashURL() -> URL? {
        #if DEBUG
        // `APOLLO_SPLASH_URL=http://localhost:5317` points a debug build at the
        // Vite dev server for live iteration on the scene.
        if let override = ProcessInfo.processInfo.environment["APOLLO_SPLASH_URL"],
           let url = URL(string: override) {
            return url
        }
        #endif
        return Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "ApolloSplash")
    }

    private static func makeWebView(handler: WKScriptMessageHandler) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        configuration.websiteDataStore = .nonPersistent()
        let content = configuration.userContentController
        content.add(handler, name: "apollo")
        let bootstrap = "window.__APOLLO_SPLASH__ = { accent: \"\(accentHex())\", autostart: false };"
        content.addUserScript(WKUserScript(source: bootstrap,
                                           injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true))

        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Transparent: the reveal iris opens onto the SwiftUI dashboard below.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.setAccessibilityElement(false)
        return webView
    }

    private static func accentHex() -> String {
        let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let r = Int((color.redComponent * 255).rounded())
        let g = Int((color.greenComponent * 255).rounded())
        let b = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

extension LunarSplashController: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Self.log.error("ApolloSplash web process terminated")
        switch stage {
        case .loading, .playing: enterFallback()
        case .exiting: finish()
        case .fallback, .finished: break
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.log.error("ApolloSplash navigation failed: \(error.localizedDescription, privacy: .public)")
        if stage == .loading { enterFallback() }
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        Self.log.error("ApolloSplash load failed: \(error.localizedDescription, privacy: .public)")
        if stage == .loading { enterFallback() }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // The splash is a single self-contained document; nothing may navigate.
        decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
    }
}

/// `WKUserContentController` retains its handlers strongly; this proxy keeps
/// the controller (and its web view) free to deallocate with the splash.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: LunarSplashController?

    init(target: LunarSplashController) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.receive(message.body) }
    }
}
