import AppKit
import SwiftUI
import Sparkle

/// A custom Sparkle `SPUUserDriver` so the whole update experience —
/// "new version", download progress, extracting, install & relaunch,
/// errors — renders in Apollo's Editorial Calm design language instead
/// of Sparkle's stock AppKit windows.
///
/// Sparkle drives this object: it calls the protocol methods (always on
/// the main thread) to tell us what to show. We translate each into a
/// `Phase` that a single SwiftUI card observes, and stash the reply /
/// cancellation / acknowledgement callbacks so the card's buttons can
/// answer Sparkle back.
///
/// The download/extract/install MECHANICS stay 100% Sparkle — we only
/// own the pixels. That keeps the risky part (code-signing checks,
/// atomic swap, relaunch) on Sparkle's battle-tested path.
@MainActor
final class ApolloUpdateDriver: NSObject, ObservableObject, SPUUserDriver {

    // MARK: - UI phase

    enum Phase: Equatable {
        case idle
        case checking
        case found(version: String, notes: String)
        case downloading(fraction: Double?)   // nil → indeterminate (no length yet)
        case extracting(fraction: Double)
        case installing
        case readyToRelaunch(version: String)
        case upToDate
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    // MARK: - Pending Sparkle callbacks

    /// Used by both `showUpdateFound` and `showReadyToInstallAndRelaunch`
    /// (both answer with an `SPUUserUpdateChoice`).
    private var choiceReply: ((SPUUserUpdateChoice) -> Void)?
    /// Cancellation for the user-initiated check and the download.
    private var cancelHandler: (() -> Void)?
    /// Resumes the async `showUpdateNotFound` / `showUpdaterError` /
    /// `showUpdateInstalledAndRelaunched` methods once the user clicks OK.
    private var ackContinuation: CheckedContinuation<Void, Never>?

    // Download byte accounting → a 0…1 fraction for the progress bar.
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0

    private var window: NSWindow?

    // MARK: - Button intents (called from the SwiftUI card)

    func choose(_ choice: SPUUserUpdateChoice) {
        let reply = choiceReply
        choiceReply = nil
        reply?(choice)
    }

    func cancel() {
        let handler = cancelHandler
        cancelHandler = nil
        handler?()
        finish()
    }

    func acknowledge() {
        // Resume any awaiting async method, then drop the card.
        ackContinuation?.resume()
        ackContinuation = nil
        finish()
    }

    /// Bring the update card to the front (the user re-checked while
    /// something was already on screen).
    func showUpdateInFocus() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Automatic checks are pre-enabled via Info.plist
        // (SUEnableAutomaticChecks=true), so this is rarely hit. Answer
        // with sensible defaults rather than surfacing an extra screen:
        // allow scheduled checks, decline anonymous system-profile send.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true,
                                         sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        cancelHandler = cancellation
        present(.checking)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem,
                         state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Silent-channel releases discovered by a SCHEDULED check stay
        // invisible (they're installable on demand via the menu). A
        // user-initiated check always shows them.
        if !state.userInitiated && appcastItem.channel == "silent" {
            reply(.dismiss)
            return
        }
        choiceReply = reply
        let notes = (appcastItem.itemDescription ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        present(.found(version: appcastItem.displayVersionString, notes: notes))
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // We embed release notes directly in the appcast <description>,
        // so they're already on screen via `itemDescription`. If a
        // separately-linked notes file arrives, fold it in.
        guard case let .found(version, existing) = phase, existing.isEmpty else { return }
        let text = String(data: downloadData.data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { present(.found(version: version, notes: text)) }
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        // Non-fatal: we still show the found card without notes.
    }

    func showUpdateNotFoundWithError(_ error: Error) async {
        present(.upToDate)
        await waitForAcknowledgement()
    }

    func showUpdaterError(_ error: Error) async {
        present(.failed(error.localizedDescription))
        await waitForAcknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        cancelHandler = cancellation
        expectedLength = 0
        receivedLength = 0
        present(.downloading(fraction: nil))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        receivedLength = 0
        present(.downloading(fraction: expectedContentLength > 0 ? 0 : nil))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        let fraction: Double? = expectedLength > 0
            ? min(1.0, Double(receivedLength) / Double(expectedLength))
            : nil
        present(.downloading(fraction: fraction))
    }

    func showDownloadDidStartExtractingUpdate() {
        cancelHandler = nil   // can't cancel past this point
        present(.extracting(fraction: 0))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        present(.extracting(fraction: max(0, min(1, progress))))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        choiceReply = reply
        let version: String = {
            if case let .found(v, _) = phase { return v }
            if case let .readyToRelaunch(v) = phase { return v }
            return ""
        }()
        present(.readyToRelaunch(version: version))
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        present(.installing)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {
        // Usually the app has already been relaunched by the time this
        // would matter; implement for completeness.
        await waitForAcknowledgement()
    }

    func dismissUpdateInstallation() {
        finish()
    }

    // MARK: - Plumbing

    private func waitForAcknowledgement() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.ackContinuation = cont
        }
    }

    private func present(_ newPhase: Phase) {
        phase = newPhase
        if window == nil { buildWindow() }
        guard let window else { return }
        if !window.isVisible {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func finish() {
        phase = .idle
        choiceReply = nil
        cancelHandler = nil
        ackContinuation = nil
        window?.orderOut(nil)
    }

    private func buildWindow() {
        let host = NSHostingController(rootView: UpdaterCardView(driver: self))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .fullSizeContentView]
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.isOpaque = false
        w.backgroundColor = .clear
        // The card draws its OWN soft shadow in SwiftUI. The native
        // window shadow on a transparent, padded window produces a
        // grainy rectangular halo — so turn it off.
        w.hasShadow = false
        w.level = .floating
        w.isReleasedWhenClosed = false
        window = w
    }
}
