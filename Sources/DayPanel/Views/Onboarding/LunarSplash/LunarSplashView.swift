import SwiftUI
import WebKit

/// Launch splash. The scene itself is React + WebGL inside a transparent
/// `WKWebView` (see `LunarSplashController`); this view layers the native
/// pieces around it:
///
/// - `LunarSplashBackdrop` covers the window from frame zero so the
///   dashboard never flashes while WebKit starts, and hands over invisibly
///   because it paints the exact gradient the web scene paints;
/// - `LunarSplashFallbackMark` stands in when the web scene can't run.
///
/// Once the web scene opens its reveal iris, nothing native sits behind it:
/// the dashboard itself shows through.
struct LunarSplashView: View {
    let dataReady: Bool
    let onRevealStart: () -> Void
    let onFinished: () -> Void

    @StateObject private var controller = LunarSplashController()

    var body: some View {
        ZStack {
            if controller.stage == .loading || controller.stage == .fallback || controller.fallbackExiting {
                LunarSplashBackdrop()
            }
            if let webView = controller.webView {
                LunarSplashWebView(webView: webView)
            }
            if controller.stage == .fallback || controller.fallbackExiting {
                LunarSplashFallbackMark()
            }
        }
        .opacity(controller.fallbackExiting ? 0 : 1)
        .animation(.easeOut(duration: 0.35), value: controller.fallbackExiting)
        .ignoresSafeArea()
        // Swallow stray clicks during the splash instead of letting them
        // reach toolbar buttons underneath.
        .contentShape(Rectangle())
        .onTapGesture {}
        .onAppear {
            controller.onRevealStart = onRevealStart
            controller.onFinished = onFinished
            controller.dataReady = dataReady
            controller.begin()
        }
        .onChange(of: dataReady) { _, ready in
            controller.dataReady = ready
        }
        .accessibilityElement()
        .accessibilityLabel("Apollo")
    }
}

private struct LunarSplashWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Mirrors `.splash { background }` in `web/apollo-splash/src/styles.css`:
/// `radial-gradient(circle at 50% 38%, #10151d 0, #0a0d12 45vmax, #060709 90vmax)`.
struct LunarSplashBackdrop: View {
    var body: some View {
        GeometryReader { geo in
            let vmax = max(geo.size.width, geo.size.height)
            RadialGradient(
                stops: [
                    .init(color: Color(red: 0x10 / 255, green: 0x15 / 255, blue: 0x1D / 255), location: 0),
                    .init(color: Color(red: 0x0A / 255, green: 0x0D / 255, blue: 0x12 / 255), location: 0.5),
                    .init(color: Color(red: 0x06 / 255, green: 0x07 / 255, blue: 0x09 / 255), location: 1),
                ],
                center: UnitPoint(x: 0.5, y: 0.38),
                startRadius: 0,
                endRadius: vmax * 0.9
            )
        }
    }
}

/// Quiet native stand-in for the web scene: wordmark and accent rule only.
private struct LunarSplashFallbackMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        VStack(spacing: 18) {
            Text("Apollo")
                .font(.system(size: 64, weight: .regular))
                .tracking(-1.5)
                .foregroundStyle(Color(red: 0xE8 / 255, green: 0xE8 / 255, blue: 0xEA / 255))
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 56, height: 2)
        }
        .opacity(shown ? 1 : 0)
        .offset(y: shown || reduceMotion ? 0 : 8)
        .onAppear {
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.6)) { shown = true }
        }
    }
}
