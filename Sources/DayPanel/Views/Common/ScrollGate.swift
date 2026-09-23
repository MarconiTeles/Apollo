import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted on the first wheel/magnify event of a live gesture. AppKit
    /// cells use it to clear tracking-area hover state synchronously, even
    /// when NSScrollView omits/delays `willStartLiveScroll`.
    static let apolloScrollDidBegin = Notification.Name("ApolloScrollDidBegin")
}

// GATE GLOBAL DE SCROLL (portado do Galileo/EditKit): durante QUALQUER
// rolagem/pinça na interface, todo efeito de hover é SUSPENSO — rolar
// sob o ponteiro disparava hovers em série (chips acendendo, rows
// clareando) = churn e jank. Monitor local de NSEvent arma o gate;
// As fases do gesto/inércia mantêm o gate armado; 180ms de tolerância
// depois do fim (ou de eventos sem fase) evitam reativação entre gestos.
//
// Convive com o ScrollStateObserver existente (que escuta
// willStartLiveScroll/didEndLiveScroll de NSScrollViews específicas):
// o ScrollGate cobre TODO evento de scroll/magnify da janela — é o
// gate que os modifiers Studio Glass (hoverGlass/hoverBounce/hoverRow)
// consultam.
@MainActor
final class ScrollGate: ObservableObject {
    static let shared = ScrollGate()
    @Published private(set) var active = false
    private var resetWork: DispatchWorkItem?
    private var monitor: Any?
    private var deadline = ScrollActivityDeadline()

    private init() {}

    /// Instala o monitor (1× — chamado pelo AppDelegate no launch).
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] e in
            self?.bump(phase: e.phase, momentumPhase: e.momentumPhase)
            return e
        }
    }

    func bump(phase: NSEvent.Phase = [], momentumPhase: NSEvent.Phase = []) {
        deadline.record(at: ProcessInfo.processInfo.systemUptime,
                        phase: phase, momentumPhase: momentumPhase)
        if !active {
            active = true
            // One synchronous reset per scroll burst. Native cells also read
            // ScrollStateObserver for the whole live/momentum interval, so
            // repeating this notification on every wheel tick would add work
            // to the exact hot path we are protecting.
            NotificationCenter.default.post(name: .apolloScrollDidBegin,
                                            object: nil)
        }
        // One pending wake-up per burst. Events only extend the deadline;
        // they must not allocate/cancel a work item at trackpad frequency.
        if resetWork == nil { scheduleReset(after: ScrollActivityDeadline.grace) }
    }

    private func scheduleReset(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resetWork = nil
            let remaining = self.deadline.remaining(at: ProcessInfo.processInfo.systemUptime)
            if remaining > 0 {
                // Check at the grace cadence so an explicit end can shorten
                // the watchdog without scheduling a second callback.
                self.scheduleReset(after: min(remaining, ScrollActivityDeadline.grace))
            } else if self.active {
                self.active = false
            }
        }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// Phase-aware deadline, independent of the run loop. The watchdog covers an
/// interrupted sequence (lost end, window change); it is not the normal end
/// condition for a trackpad gesture. Legacy wheels retain the short debounce.
struct ScrollActivityDeadline {
    static let grace: TimeInterval = 0.18
    static let interruptedGestureTimeout: TimeInterval = 2
    private var expiresAt: TimeInterval = 0

    mutating func record(at now: TimeInterval,
                         phase: NSEvent.Phase,
                         momentumPhase: NSEvent.Phase) {
        let current = momentumPhase.isEmpty ? phase : momentumPhase
        let ended = !current.intersection([.ended, .cancelled]).isEmpty
        let ongoing = !current.intersection([.began, .changed, .stationary, .mayBegin]).isEmpty
        expiresAt = now + (ongoing && !ended ? Self.interruptedGestureTimeout : Self.grace)
    }

    func remaining(at now: TimeInterval) -> TimeInterval {
        max(0, expiresAt - now)
    }
}
