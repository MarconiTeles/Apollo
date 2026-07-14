import AppKit
import SwiftUI

// GATE GLOBAL DE SCROLL (portado do Galileo/EditKit): durante QUALQUER
// rolagem/pinça na interface, todo efeito de hover é SUSPENSO — rolar
// sob o ponteiro disparava hovers em série (chips acendendo, rows
// clareando) = churn e jank. Monitor local de NSEvent arma o gate;
// debounce de 180ms o desarma.
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

    private init() {}

    /// Instala o monitor (1× — chamado pelo AppDelegate no launch).
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] e in
            self?.bump()
            return e
        }
    }

    func bump() {
        if !active { active = true }
        resetWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.active = false }
        resetWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: w)
    }
}
