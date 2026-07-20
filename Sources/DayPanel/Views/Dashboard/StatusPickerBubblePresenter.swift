import AppKit
import SwiftUI

private enum StatusPickerBubbleMetrics {
    static let bodyWidth: CGFloat = 196
    /// The surface shadow reaches 8pt sideways and 12pt downward
    /// (`radius: 8, y: 4`). Keep a little extra breathing room so the
    /// NSPanel never clips the blur at a window edge or during the spring.
    static let shadowOutset: CGFloat = 14
}

/// Presents the shared status picker as one borderless, transparent surface.
/// The old NSPopover added AppKit chrome around a second SwiftUI card, which
/// produced the rejected "glass inside glass" look. This presenter owns only
/// a clear panel; the SwiftUI bubble is the single visual/material layer.
final class StatusPickerBubblePresenter: NSObject, NSWindowDelegate {
    private var panel: StatusPickerBubblePanel?
    private var model: StatusPickerBubbleModel?
    private var escapeMonitor: Any?
    private var clickOutsideMonitor: Any?
    private var dismissalCallback: (() -> Void)?
    private var isDismissing = false
    var isPresented: Bool { panel != nil }

    // O panel é uma janela própria: se o dono (Coordinator/anchor) morrer sem
    // fechar, o panel fica ÓRFÃO na tela ("grudado"). O deinit é a rede de
    // segurança; o dismantleNSView do anchor é o caminho normal.
    deinit {
        removeEscapeMonitor()
        removeClickOutsideMonitor()
        panel?.orderOut(nil)
    }

    func show(statuses: [CUStatus],
              currentStatusName: String?,
              anchoredTo anchor: NSView,
              onDismiss: (() -> Void)? = nil,
              onSelect: @escaping (CUStatus) -> Void) {
        dismiss(animated: false)
        guard !statuses.isEmpty,
              let window = anchor.window,
              let screen = window.screen ?? NSScreen.main else { return }

        let anchorInWindow = anchor.convert(anchor.bounds, to: nil)
        let anchorOnScreen = window.convertToScreen(anchorInWindow)
        let bodyWidth = StatusPickerBubbleMetrics.bodyWidth
        let shadowOutset = StatusPickerBubbleMetrics.shadowOutset
        // Exact intrinsic estimate: row text + 10pt vertical padding, one
        // hairline between rows, 6pt content inset and the 8pt notch. The old
        // 30pt-per-row estimate left a large empty lower quadrant.
        let rowHeight: CGFloat = 23.5
        let dividerHeight = CGFloat(max(0, statuses.count - 1))
        let contentInsets: CGFloat = 6 + 16
        let bodyHeight = min(ceil(CGFloat(statuses.count) * rowHeight
                                  + dividerHeight + contentInsets), 420)
        // A status bubble belongs to the app canvas, not to the desktop.
        // Constrain it to the owning window as well as the physical screen so
        // a bottom-row picker flips upward instead of sampling wallpaper.
        // Constrain the BODY to a rect already inset by the shadow outset.
        // The surrounding transparent panel may then carry the whole blur
        // without sampling outside the app canvas or exposing a clipped
        // rectangular edge.
        let visible = screen.visibleFrame.intersection(
            window.frame.insetBy(dx: 8 + shadowOutset,
                                 dy: 8 + shadowOutset)
        )
        let belowY = anchorOnScreen.minY - bodyHeight - 5
        let appearsAbove = belowY < visible.minY + 8
        let bodyY = appearsAbove
            ? min(anchorOnScreen.maxY + 5, visible.maxY - bodyHeight - 8)
            : belowY
        // The notch lives near the leading edge so the body expands rightward
        // into the list canvas instead of straddling the Done control.
        let preferredNotchX: CGFloat = 28
        let proposedX = anchorOnScreen.midX - preferredNotchX
        let bodyX = min(max(proposedX, visible.minX + 8),
                        visible.maxX - bodyWidth - 8)
        let localNotchX = max(22, min(bodyWidth - 22,
                                      anchorOnScreen.midX - bodyX))

        let panelRect = NSRect(
            x: bodyX - shadowOutset,
            y: bodyY - shadowOutset,
            width: bodyWidth + shadowOutset * 2,
            height: bodyHeight + shadowOutset * 2
        )

        let model = StatusPickerBubbleModel()
        let panel = StatusPickerBubblePanel(
            contentRect: panelRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none

        let root = StatusPickerBubbleView(
            statuses: statuses,
            currentStatusName: currentStatusName,
            appearsAbove: appearsAbove,
            notchX: localNotchX,
            bodySize: CGSize(width: bodyWidth, height: bodyHeight),
            shadowOutset: shadowOutset,
            model: model
        ) { [weak self] status in
            onSelect(status)
            self?.dismiss(animated: true)
        }
        let host = StatusPickerBubbleHostingView(rootView: root)
        host.shadowOutset = shadowOutset
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host

        self.panel = panel
        self.model = model
        dismissalCallback = onDismiss
        isDismissing = false
        panel.makeKeyAndOrderFront(nil)
        installEscapeMonitor()
        installClickOutsideMonitor()
        DispatchQueue.main.async {
            // Spring mais seco que o original (0.34/0.78) — o picker aparece
            // de imediato em vez de "demorar a abrir".
            withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                model.visible = true
            }
        }
    }

    func dismiss(animated: Bool = true) {
        // Fechamento FORÇADO (teardown/dealloc): mesmo no meio de um dismiss
        // animado, derruba o panel na hora — senão o asyncAfter pendente vira
        // a única chance de fechar e o panel pode ficar órfão.
        if !animated, isDismissing, let panel {
            panel.orderOut(nil)
            self.panel = nil
            model = nil
            isDismissing = false
            removeEscapeMonitor()
            removeClickOutsideMonitor()
            return
        }
        guard let panel, !isDismissing else { return }
        isDismissing = true
        removeEscapeMonitor()
        removeClickOutsideMonitor()
        let callback = dismissalCallback
        dismissalCallback = nil
        callback?()
        if animated, let model {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                model.visible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self, weak panel] in
                panel?.orderOut(nil)
                if self?.panel === panel {
                    self?.panel = nil
                    self?.model = nil
                    self?.isDismissing = false
                }
            }
        } else {
            panel.orderOut(nil)
            self.panel = nil
            model = nil
            isDismissing = false
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss(animated: true)
    }

    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.dismiss(animated: true)
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    /// Clique FORA do panel fecha o picker — não dependemos mais só do
    /// `windowDidResignKey` (que falha quando o panel borderless não chegou a
    /// virar key, deixando o bubble "grudado" na tela).
    private func installClickOutsideMonitor() {
        clickOutsideMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window !== panel {
                self.dismiss(animated: true)
            }
            return event
        }
    }

    private func removeClickOutsideMonitor() {
        if let clickOutsideMonitor { NSEvent.removeMonitor(clickOutsideMonitor) }
        clickOutsideMonitor = nil
    }
}

/// Zero-chrome anchor that lets pure SwiftUI buttons use the exact same
/// bubble presenter as the native task list. Attach it as the button's
/// background; it inherits the control's frame and anchors the notch there.
struct StatusPickerBubbleAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let statuses: [CUStatus]
    let currentStatusName: String?
    let onSelect: (CUStatus) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
        guard view.window != nil else { return }
        if isPresented, !context.coordinator.presenter.isPresented {
            let binding = $isPresented
            // Eco do fechamento, não intenção de abrir: quando o usuário FECHA
            // clicando no próprio seletor, o monitor de clique-fora fecha o
            // panel (mousedown) e a action do botão faz toggle() no mouseup —
            // regravando `true`. Sem esta guarda o binding ficava preso em
            // true e QUALQUER re-render posterior (ex.: trocar de aba na
            // tarefa) ressuscitava o picker do nada.
            if Date().timeIntervalSince(context.coordinator.lastDismissAt) < 0.35 {
                DispatchQueue.main.async { binding.wrappedValue = false }
                return
            }
            let coordinator = context.coordinator
            coordinator.presenter.show(
                statuses: statuses,
                currentStatusName: currentStatusName,
                anchoredTo: view,
                onDismiss: { [weak coordinator] in
                    coordinator?.lastDismissAt = Date()
                    DispatchQueue.main.async { binding.wrappedValue = false }
                },
                onSelect: onSelect
            )
        } else if !isPresented, context.coordinator.presenter.isPresented {
            context.coordinator.presenter.dismiss(animated: true)
        }
    }

    /// SwiftUI recria/destrói representables com o churn de render do popup;
    /// sem este teardown o panel do picker sobrevivia ao dono e ficava
    /// "grudado" na tela, sem nenhum caminho de fechamento.
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.presenter.dismiss(animated: false)
    }

    final class Coordinator {
        var parent: StatusPickerBubbleAnchor
        let presenter = StatusPickerBubblePresenter()
        /// Instante do último dismiss — usado pra distinguir "abrir de
        /// verdade" do eco do toggle() no fechamento pelo próprio seletor.
        var lastDismissAt = Date.distantPast
        init(parent: StatusPickerBubbleAnchor) { self.parent = parent }
    }
}

private final class StatusPickerBubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The enlarged transparent window exists only to carry the blur. Ignore
/// hits in that breathing room so the picker does not grow a mysterious
/// 14pt invisible interaction rectangle around the visible bubble.
private final class StatusPickerBubbleHostingView<Content: View>: NSHostingView<Content> {
    var shadowOutset: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.insetBy(dx: shadowOutset, dy: shadowOutset).contains(point)
        else { return nil }
        return super.hitTest(point)
    }
}

private final class StatusPickerBubbleModel: ObservableObject {
    @Published var visible = false
}

private struct StatusPickerBubbleView: View {
    let statuses: [CUStatus]
    let currentStatusName: String?
    let appearsAbove: Bool
    let notchX: CGFloat
    let bodySize: CGSize
    let shadowOutset: CGFloat
    @ObservedObject var model: StatusPickerBubbleModel
    let onSelect: (CUStatus) -> Void

    private var shape: StatusBubbleShape {
        StatusBubbleShape(notchEdge: appearsAbove ? .bottom : .top,
                          notchX: notchX)
    }

    var body: some View {
        ZStack {
            Color.clear
            if model.visible {
                materializedSurface
                    .frame(width: bodySize.width, height: bodySize.height)
                    .padding(shadowOutset)
                    .transition(
                        .scale(scale: 0.12,
                               anchor: appearsAbove ? .bottomLeading : .topLeading)
                        .combined(with: .opacity)
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var materializedSurface: some View {
        if #available(macOS 26.0, *), Materials.tier == .liquidGlass {
            GlassEffectContainer(spacing: 0) {
                pickerContent
                    .glassEffect(.regular.interactive(), in: shape)
                    .glassEffectTransition(.materialize)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            }
        } else if Materials.tier == .solid {
            pickerContent
                .background(shape.fill(Editorial.popup))
                .overlay(shape.strokeBorder(Editorial.rule, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        } else {
            pickerContent
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        }
    }

    private var pickerContent: some View {
        StatusPickerPopover(statuses: statuses,
                            currentStatusName: currentStatusName,
                            onSelect: onSelect)
            .frame(maxHeight: 408)
            .padding(.top, appearsAbove ? 5 : 11)
            .padding(.bottom, appearsAbove ? 11 : 5)
    }
}

private struct StatusBubbleShape: InsettableShape {
    enum NotchEdge { case top, bottom }
    let notchEdge: NotchEdge
    let notchX: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let notchHeight: CGFloat = 8
        let notchHalfWidth: CGFloat = 10
        let body = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let bodyRect = CGRect(x: body.minX,
                              y: body.minY + (notchEdge == .top ? notchHeight : 0),
                              width: body.width,
                              height: body.height - notchHeight)
        let radius: CGFloat = max(10, Editorial.popupRadius(12) - insetAmount)
        var path = Path(roundedRect: bodyRect,
                        cornerRadius: radius,
                        style: .continuous)
        let center = max(body.minX + notchHalfWidth + 6,
                         min(body.maxX - notchHalfWidth - 6,
                             body.minX + notchX))
        var notch = Path()
        if notchEdge == .top {
            notch.move(to: CGPoint(x: center - notchHalfWidth, y: bodyRect.minY + 1))
            notch.addQuadCurve(to: CGPoint(x: center, y: body.minY),
                               control: CGPoint(x: center - 4, y: body.minY))
            notch.addQuadCurve(to: CGPoint(x: center + notchHalfWidth, y: bodyRect.minY + 1),
                               control: CGPoint(x: center + 4, y: body.minY))
        } else {
            notch.move(to: CGPoint(x: center - notchHalfWidth, y: bodyRect.maxY - 1))
            notch.addQuadCurve(to: CGPoint(x: center, y: body.maxY),
                               control: CGPoint(x: center - 4, y: body.maxY))
            notch.addQuadCurve(to: CGPoint(x: center + notchHalfWidth, y: bodyRect.maxY - 1),
                               control: CGPoint(x: center + 4, y: body.maxY))
        }
        path.addPath(notch)
        return path
    }

    func inset(by amount: CGFloat) -> StatusBubbleShape {
        StatusBubbleShape(notchEdge: notchEdge,
                          notchX: notchX,
                          insetAmount: insetAmount + amount)
    }
}
