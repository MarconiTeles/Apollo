import AppKit
import SwiftUI

private enum StatusPickerBubbleMetrics {
    static let bodyWidth: CGFloat = 200
    /// Transparent margin of the panel around the glass. Liquid Glass casts
    /// its own soft shadow well beyond our `radius: 10, y: 4` one; 16pt
    /// clipped it into a visible rectangle. Hits stay limited to the body.
    static let shadowOutset: CGFloat = 48
    /// Distance kept between the body and the owning window's edges.
    static let windowMargin: CGFloat = 24
    static let rowHeight: CGFloat = 28
    static let listInset: CGFloat = 6
    static let cornerRadius: CGFloat = 16
    /// Diameter of the glass drop that grows out of the status control.
    static let seedDiameter: CGFloat = 18
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
        // Exact intrinsic height: fixed-height rows plus the list inset.
        let bodyHeight = min(CGFloat(statuses.count) * StatusPickerBubbleMetrics.rowHeight
                             + StatusPickerBubbleMetrics.listInset * 2, 420)
        // A status bubble belongs to the app canvas, not to the desktop.
        // Constrain it to the owning window as well as the physical screen so
        // a bottom-row picker flips upward instead of sampling wallpaper.
        // Constrain the BODY to a rect already inset by the shadow outset.
        // The surrounding transparent panel may then carry the whole blur
        // without sampling outside the app canvas or exposing a clipped
        // rectangular edge.
        let margin = StatusPickerBubbleMetrics.windowMargin
        let visible = screen.visibleFrame.intersection(
            window.frame.insetBy(dx: margin, dy: margin)
        )
        let belowY = anchorOnScreen.minY - bodyHeight - 6
        let appearsAbove = belowY < visible.minY + 8
        let bodyY = appearsAbove
            ? min(anchorOnScreen.maxY + 6, visible.maxY - bodyHeight - 8)
            : belowY
        // The body opens rightward from the control, so the glass drop
        // that grows out of the control sits near its leading corner.
        let proposedX = anchorOnScreen.midX - 22
        let bodyX = min(max(proposedX, visible.minX + 8),
                        visible.maxX - bodyWidth - 8)
        let bodyOnScreen = NSRect(x: bodyX, y: bodyY, width: bodyWidth, height: bodyHeight)
        let seed = StatusPickerBubbleMetrics.seedDiameter
        let seedOnScreen = NSRect(x: anchorOnScreen.midX - seed / 2,
                                  y: anchorOnScreen.midY - seed / 2,
                                  width: seed, height: seed)
        // The panel covers the body AND the control: the glass morphs
        // from the control's own position into the list.
        let panelRect = bodyOnScreen.union(seedOnScreen)
            .insetBy(dx: -shadowOutset, dy: -shadowOutset)
        // SwiftUI lays out top-down from the panel's top-left corner.
        func local(_ rect: NSRect) -> CGRect {
            CGRect(x: rect.minX - panelRect.minX, y: panelRect.maxY - rect.maxY,
                   width: rect.width, height: rect.height)
        }
        let currentHex = statuses.first {
            $0.status.caseInsensitiveCompare(currentStatusName ?? "") == .orderedSame
        }?.displayHex

        let model = StatusPickerBubbleModel()
        model.seedTint = currentHex.map { Color(statusHex: $0) }
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
            bodyFrame: local(bodyOnScreen),
            seedFrame: local(seedOnScreen),
            model: model
        ) { [weak self, weak model] status in
            // The drop shrinks back into the control already wearing the
            // colour the control is about to show.
            model?.seedTint = Color(statusHex: status.displayHex)
            onSelect(status)
            self?.dismiss(animated: true)
        }
        let host = StatusPickerBubbleHostingView(rootView: root)
        host.interactiveRect = NSRect(x: bodyX - panelRect.minX, y: bodyY - panelRect.minY,
                                      width: bodyWidth, height: bodyHeight)
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
        // First frame: a glass drop over the control. Next runloop: it
        // morphs into the list while the rows cascade in behind it.
        DispatchQueue.main.async {
            model.expand()
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
            model.collapse()
            DispatchQueue.main.asyncAfter(deadline: .now() + StatusPickerBubbleModel.collapseDuration) {
                [weak self, weak panel] in
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

/// The enlarged transparent window exists only to carry the blur and the
/// morph from the control. Only the list body takes hits, so the picker
/// never grows an invisible interaction area over the row underneath.
private final class StatusPickerBubbleHostingView<Content: View>: NSHostingView<Content> {
    /// Body rect in unflipped (bottom-left origin) panel coordinates.
    var interactiveRect: NSRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let y = isFlipped ? bounds.height - local.y : local.y
        guard interactiveRect.contains(NSPoint(x: local.x, y: y)) else { return nil }
        return super.hitTest(point)
    }
}

/// Seed → list → seed → gone. The glass keeps one identity throughout, so
/// every step is a Liquid Glass morph rather than a scale/opacity fake.
private final class StatusPickerBubbleModel: ObservableObject {
    enum Phase { case seed, list, gone }
    @Published var phase: Phase = .seed
    /// Rows cascade in once the glass has started growing.
    @Published var revealed = false
    @Published var seedTint: Color?

    static let expand = Animation.spring(duration: 0.36, bounce: 0.24)
    static let shrink = Animation.spring(duration: 0.24, bounce: 0.05)
    static let collapseDuration: TimeInterval = 0.40

    func expand() {
        withAnimation(Self.expand) { phase = .list }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.revealed = true
        }
    }

    func collapse() {
        withAnimation(.easeOut(duration: 0.09)) { revealed = false }
        withAnimation(Self.shrink) { phase = .seed }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            withAnimation(.easeOut(duration: 0.16)) { self?.phase = .gone }
        }
    }
}

private struct StatusPickerBubbleView: View {
    let statuses: [CUStatus]
    let currentStatusName: String?
    let appearsAbove: Bool
    /// Body and seed frames in panel-local, top-left-origin coordinates.
    let bodyFrame: CGRect
    let seedFrame: CGRect
    @ObservedObject var model: StatusPickerBubbleModel
    let onSelect: (CUStatus) -> Void
    @Namespace private var glassNamespace

    private static let glassID = "status.picker.glass"
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: StatusPickerBubbleMetrics.cornerRadius, style: .continuous)
    }
    private var morphs: Bool {
        Materials.tier == .liquidGlass
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if morphs, #available(macOS 26.0, *) {
                glassMorph
            } else {
                fallbackSurface
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Liquid Glass

    @available(macOS 26.0, *)
    private var glassMorph: some View {
        GlassEffectContainer(spacing: 24) {
            ZStack(alignment: .topLeading) {
                switch model.phase {
                case .list:
                    pickerContent
                        .frame(width: bodyFrame.width, height: bodyFrame.height)
                        .glassEffect(.regular.interactive(), in: shape)
                        .glassEffectID(Self.glassID, in: glassNamespace)
                        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
                        .padding(.leading, bodyFrame.minX)
                        .padding(.top, bodyFrame.minY)
                case .seed:
                    Color.clear
                        .frame(width: seedFrame.width, height: seedFrame.height)
                        .glassEffect(.regular.tint(model.seedTint?.opacity(0.45)), in: .circle)
                        .glassEffectID(Self.glassID, in: glassNamespace)
                        .glassEffectTransition(.materialize)
                        .padding(.leading, seedFrame.minX)
                        .padding(.top, seedFrame.minY)
                case .gone:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Reduced transparency / motion

    @ViewBuilder
    private var fallbackSurface: some View {
        if model.phase == .list {
            Group {
                if Materials.tier == .solid {
                    pickerContent.background(shape.fill(Editorial.popup))
                } else {
                    pickerContent.background(.ultraThinMaterial, in: shape)
                }
            }
            .frame(width: bodyFrame.width, height: bodyFrame.height)
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
            .transition(.scale(scale: 0.96, anchor: appearsAbove ? .bottomLeading : .topLeading)
                .combined(with: .opacity))
            .padding(.leading, bodyFrame.minX)
            .padding(.top, bodyFrame.minY)
        }
    }

    private var pickerContent: some View {
        StatusPickerPopover(statuses: statuses,
                            currentStatusName: currentStatusName,
                            revealed: model.revealed || !morphs,
                            revealFromBottom: appearsAbove,
                            onSelect: onSelect)
    }
}
