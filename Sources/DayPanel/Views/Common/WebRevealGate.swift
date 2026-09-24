import AppKit

/// Reveal handshake shared by the React surfaces (Tarefas, Agenda, Quadro).
///
/// Each surface keeps its shared web view hidden until the page confirms it
/// painted the snapshot of THIS mount (`rendered` ≥ the snapshot's seq), so a
/// previous mount's rows never flash. The confirmation can be lost (the web
/// process was throttled while detached, relaunched, or a patch storm
/// starved an older page's acknowledgement), which left the surface blank
/// with no placeholder. The gate:
/// • reports readiness, so the SwiftUI loading scene covers the wait;
/// • resends the full snapshot when no confirmation arrives in time;
/// • reveals anyway after the last attempt rather than staying blank.
@MainActor
final class WebRevealGate {
    /// Called with `false` when a mount starts waiting, `true` when shown.
    var onReadyChange: ((Bool) -> Void)?
    /// Asks the coordinator for a fresh full snapshot (it re-arms the gate).
    var resend: (() -> Void)?

    private(set) var isRevealed = false
    private var pendingSeq: Int?
    private var watchdog: Task<Void, Never>?
    private var attempts = 0
    private weak var view: NSView?

    private let timeout: Duration
    private let maxResends: Int

    init(timeout: Duration = .milliseconds(900), maxResends: Int = 2) {
        self.timeout = timeout
        self.maxResends = maxResends
    }

    /// A new mount: hide `view` until its snapshot is confirmed.
    func begin(hiding view: NSView) {
        self.view = view
        attempts = 0
        pendingSeq = nil
        watchdog?.cancel()
        view.alphaValue = 0
        setRevealed(false)
    }

    /// The full snapshot `seq` was sent (or queued until the page boots).
    func armed(seq: Int) {
        guard !isRevealed else { return }
        pendingSeq = seq
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.timeout)
            guard !Task.isCancelled, !self.isRevealed else { return }
            if self.attempts < self.maxResends {
                self.attempts += 1
                self.resend?()
            } else {
                self.reveal()
            }
        }
    }

    /// Page acknowledgement: `rendered { seq }`.
    func acknowledge(seq: Int) {
        guard let pendingSeq, seq >= pendingSeq else { return }
        reveal()
    }

    func reveal() {
        watchdog?.cancel()
        watchdog = nil
        pendingSeq = nil
        view?.alphaValue = 1
        setRevealed(true)
    }

    func end() {
        watchdog?.cancel()
        watchdog = nil
        pendingSeq = nil
    }

    private func setRevealed(_ revealed: Bool) {
        guard revealed != isRevealed || !revealed else { return }
        isRevealed = revealed
        // SwiftUI state lives in the caller: never mutate it mid-update.
        let callback = onReadyChange
        DispatchQueue.main.async { callback?(revealed) }
    }
}
