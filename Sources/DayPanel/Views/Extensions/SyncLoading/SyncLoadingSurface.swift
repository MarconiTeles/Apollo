import AppKit
import SwiftUI
import WebKit

/// Sync-aware loading scene for one surface (tasks, board, comments, inbox).
///
/// Hybrid by design: the scene is React inside a transparent `WKWebView`
/// (`SyncLoadingController`), fed with live facts from `SyncJournal` and
/// `AppState` — which source is being read, what already landed, how much.
/// `fallback` is the native lunar skeleton: it paints from the first frame
/// and stays whenever the web scene can't run, so the surface is never blank.
struct SyncLoadingSurface<Fallback: View>: View {
    let scene: SyncLoadingScene
    /// Columns / groups the surface will render (board passes its visible
    /// statuses, fallback set included). Defaults to the list's statuses.
    var statuses: [CUStatus]?
    var geometry: SyncLoadingSnapshot.Geometry?
    /// Agenda only: where its cards and month grid rest.
    var agenda: SyncLoadingSnapshot.AgendaGeometry?
    /// Agenda only: the displayed month is being fetched.
    var monthLoading = false
    /// False keeps the surface native-only — for beats too short to be worth
    /// a web scene (e.g. the one-frame mount delay on a route switch).
    var isActive = true
    @ViewBuilder var fallback: Fallback

    @EnvironmentObject private var appState: AppState
    @ObservedObject private var journal = SyncJournal.shared
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var controller = SyncLoadingController()
    /// Half a second of tolerance before any loading animation shows: work
    /// that finishes sooner never flashes a scene (every surface uses this).
    @State private var graceElapsed = false
    static var grace: Duration { .milliseconds(500) }

    var body: some View {
        // The fallback keeps one identity for the surface's whole life, so
        // the web scene arriving (or failing) never restarts its fade-in. It
        // mounts when the tolerance ends: its cascade then plays on screen
        // instead of finishing while the surface is still transparent.
        ZStack {
            if graceElapsed {
                fallback
                    .opacity(controller.isReady ? 0 : 1)
            }
            if let webView = controller.webView {
                SyncLoadingWebView(webView: webView)
                    .opacity(controller.isReady ? 1 : 0)
            }
        }
        .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.32), value: controller.isReady)
        .opacity(graceElapsed ? 1 : 0)
        .task {
            try? await Task.sleep(for: Self.grace)
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.28)) { graceElapsed = true }
        }
        // The web scene's entry cascade starts only once it is on screen.
        .onChange(of: graceElapsed && controller.isReady) { _, shown in
            if shown { controller.play() }
        }
        .allowsHitTesting(false)
        .onAppear { if isActive { controller.start(snapshot) } }
        .onChange(of: isActive) { _, active in
            if active { controller.start(snapshot) } else { controller.tearDown() }
        }
        .onDisappear { controller.tearDown() }
        .onChange(of: snapshot) { _, next in controller.push(next) }
        .accessibilityElement()
        .accessibilityLabel(snapshot.headline)
        .accessibilityValue(snapshot.steps.first { $0.state == .active }?.label ?? "")
    }

    private var snapshot: SyncLoadingSnapshot {
        var snapshot = SyncLoadingSnapshot.make(scene, inputs)
        snapshot.geometry = geometry
        snapshot.agenda = agenda
        snapshot.theme = colorScheme == .dark ? "dark" : "light"
        snapshot.accent = Self.accentHex()
        return snapshot
    }

    private var inputs: SyncLoadingInputs {
        let auth = appState.clickUpAuthService
        let lastSynced: Date? = {
            if case let .success(date) = appState.syncStatus { return date }
            return nil
        }()
        return SyncLoadingInputs(
            journal: journal.states,
            streamedTasks: journal.streamedTasks,
            startedAt: journal.startedAt,
            hasCompletedSync: journal.hasCompletedSync,
            lastSyncedAt: lastSynced,
            online: appState.isOnline,
            resolvingIdentity: auth.isConnected && auth.userId == nil,
            workspaceName: auth.workspaceName,
            listName: appState.activeListName.isEmpty ? nil : appState.activeListName,
            statuses: (statuses ?? appState.availableStatuses).map {
                .init(name: $0.status, color: $0.displayHex)
            },
            commentsLoading: appState.assignedCommentsLoading,
            commentsScanned: appState.assignedCommentsScannedTasks,
            commentsTotal: appState.assignedCommentsTotalTasks,
            commentsFound: appState.assignedCommentRecords.count,
            commentsScanCap: AppState.assignedCommentsAutoScanCap,
            googleConnected: appState.googleAuth.isConnected,
            eventCount: appState.events.count,
            sharedCalendars: appState.sharedCalendars.count,
            monthLoading: monthLoading
        )
    }

    private static func accentHex() -> String {
        let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        return String(format: "#%02X%02X%02X",
                      Int((color.redComponent * 255).rounded()),
                      Int((color.greenComponent * 255).rounded()),
                      Int((color.blueComponent * 255).rounded()))
    }
}

private struct SyncLoadingWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
