import AppKit
import SwiftUI

/// Callbacks from a recycled card to the board coordinator. Kept as one value
/// so rebinding a card never allocates per-card closures for every action.
@MainActor
protocol BoardCardViewDelegate: AnyObject {
    var isPopupOpen: Bool { get }
    func cardActivated(_ card: BoardCardView, modifiers: NSEvent.ModifierFlags)
    func cardDragPayload(_ card: BoardCardView) -> (payload: String, image: NSImage, frame: NSRect)?
    func cardDragEnded(_ card: BoardCardView, operation: NSDragOperation)
    func cardContextActions(_ card: BoardCardView) -> [TaskContextAction]
}

/// Native port of `BoardCardRow` + `BoardCard`. Layer tree (flipped view):
///
///   root (anchor centre) — drag dim/scale
///     selectionFill       — TaskSelectionSurface fill (unscaled)
///     body (anchor centre) — hover lift: scale, offset, semantic shadow
///       surface            — page fill + 0.5pt rule border, continuous corners
///       content            — CoreText + dots + chip + avatars (one bitmap)
///     selectionRing        — TaskSelectionSurface stroke + tinted glow
@MainActor
final class BoardCardView: NSView, NSDraggingSource {
    override var isFlipped: Bool { true }

    private(set) var task: CUTask?
    private(set) var cardLayout: BoardCardLayout?
    private var workspaceName = ""
    weak var delegate: BoardCardViewDelegate?

    private let root = CALayer()
    private let selectionFill = CALayer()
    private let body = CALayer()
    private let surface = CALayer()
    private let content = CALayer()
    private let selectionRing = CALayer()
    private let painter = BoardCardPainter()

    private(set) var isSelected = false
    private(set) var isDragSource = false
    private(set) var isHovered = false
    private var tracking: NSTrackingArea?
    private var pressed = false
    private var dragStarted = false
    private var mouseDownPoint: NSPoint?
    private var avatarGeneration = 0

    private static weak var activeHoverCard: BoardCardView?
    private static var observersInstalled = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let layer else { return }
        layer.masksToBounds = false

        for l in [root, body] {
            l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            l.masksToBounds = false
        }
        layer.addSublayer(root)
        root.addSublayer(selectionFill)
        root.addSublayer(body)
        root.addSublayer(selectionRing)
        body.addSublayer(surface)
        body.addSublayer(content)

        let radius = BoardCardLayout.radius
        for l in [selectionFill, surface, selectionRing] {
            l.cornerRadius = radius
            l.cornerCurve = .continuous
        }
        // Surface (page fill + 0.5pt rule border) is drawn into the content
        // bitmap with SwiftUI's own continuous path: one composited layer per
        // card instead of two.
        surface.isHidden = true
        selectionFill.isHidden = true
        // strokeBorder(lineWidth: 1.1): CALayer borders are drawn inside the
        // bounds with the same continuous corner curve.
        selectionRing.borderWidth = 1.1
        selectionRing.opacity = 0
        selectionRing.shadowRadius = 3.5
        selectionRing.shadowOffset = CGSize(width: 0, height: 1.5)
        selectionRing.shadowOpacity = 1
        body.shadowOpacity = 0
        body.shadowRadius = 0
        body.shadowOffset = .zero
        content.delegate = painter
        content.needsDisplayOnBoundsChange = false
        painter.card = self
        disableImplicitActions()
        Self.installObservers()
        if BoardDiag.has("nocontent") { content.isHidden = true }

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    private func disableImplicitActions() {
        let none: [String: CAAction] = [
            "position": NSNull(), "bounds": NSNull(), "transform": NSNull(),
            "opacity": NSNull(), "hidden": NSNull(), "contents": NSNull(),
            "shadowOpacity": NSNull(), "shadowRadius": NSNull(), "shadowOffset": NSNull(),
            "shadowColor": NSNull(), "shadowPath": NSNull(),
            "backgroundColor": NSNull(), "borderColor": NSNull(),
            "zPosition": NSNull(), "anchorPoint": NSNull(), "frame": NSNull(),
        ]
        for l in [root, selectionFill, body, surface, content, selectionRing] as [CALayer] {
            l.actions = none
        }
    }

    // MARK: Binding

    func bind(task: CUTask, workspaceName: String, layout: BoardCardLayout) {
        let contentChanged = self.task != task || self.workspaceName != workspaceName
        let identityChanged = self.task?.id != task.id
        self.task = task
        self.workspaceName = workspaceName
        self.cardLayout = layout
        if identityChanged {
            resetInteraction(animated: false)
            avatarGeneration += 1
        }
        if contentChanged {
            setAccessibilityLabel(task.title)
            requestAvatarImages()
            content.setNeedsDisplay()
        }
        applyColors()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        task = nil
        cardLayout = nil
        avatarGeneration += 1
        resetInteraction(animated: false)
        setSelected(false, animated: false)
        setDragSource(false, animated: false)
        content.contents = nil
    }

    // MARK: Geometry

    override func layout() {
        super.layout()
        applyGeometry()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { applyGeometry() }
    }

    private func applyGeometry() {
        let b = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.bounds = b
        root.position = CGPoint(x: b.midX, y: b.midY)
        selectionFill.frame = b
        body.bounds = b
        body.position = CGPoint(x: b.midX, y: b.midY)
        surface.frame = b
        let scale = window?.backingScaleFactor ?? 2
        if content.frame != b || content.contentsScale != scale {
            content.frame = b
            content.contentsScale = scale
            content.setNeedsDisplay()
        }
        body.shadowPath = BoardCardRenderer.surfacePath(b)
        selectionRing.frame = b
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyGeometry()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        content.setNeedsDisplay()
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionFill.backgroundColor = editorialCG(Editorial.accent.opacity(0.075))
        selectionRing.borderColor = editorialCG(Editorial.accent.opacity(0.58))
        if let task {
            let tint = Color(statusHex: task.statusDisplayHex)
            selectionRing.shadowColor = editorialCG(tint.opacity(0.16))
            body.shadowColor = editorialCG(tint)
        }
        CATransaction.commit()
    }

    // MARK: Interaction states

    func setSelected(_ selected: Bool, animated: Bool) {
        guard selected != isSelected else { return }
        isSelected = selected
        selectionFill.isHidden = !selected
        // `.animation(.spring(response: 0.24, dampingFraction: 0.78), value: selected)`
        // with the default opacity insertion/removal transition.
        BoardMotion.animate(selectionRing, key: "opacity", to: selected ? 1 : 0,
                            spring: animated ? BoardMotion.selection : nil)
    }

    func setDragSource(_ dragging: Bool, animated: Bool) {
        guard dragging != isDragSource else { return }
        isDragSource = dragging
        // `.opacity(0.35).scaleEffect(0.98)` with `.bouncy(duration: 0.34, extraBounce: 0.12)`.
        let spring = animated ? BoardMotion.dragSource : nil
        BoardMotion.animate(root, key: "opacity", to: dragging ? 0.35 : 1, spring: spring)
        BoardMotion.animate(root, key: "transform",
                            to: CATransform3DMakeScale(dragging ? 0.98 : 1, dragging ? 0.98 : 1, 1),
                            spring: spring)
    }

    private func setHover(_ hover: Bool, animated: Bool) {
        guard hover != isHovered else { return }
        isHovered = hover
        if hover {
            if let previous = Self.activeHoverCard, previous !== self {
                previous.setHover(false, animated: true)
            }
            Self.activeHoverCard = self
        } else if Self.activeHoverCard === self {
            Self.activeHoverCard = nil
        }
        // zIndex(hover ? 10 : 0) keeps the lifted card above its neighbours.
        layer?.zPosition = hover ? 10 : 0
        // scaleEffect(x: 1.018, y: 1.055) + offset(y: -1) + status shadow
        // (0.34 opacity, radius 3, y 1.5), spring(response: 0.30, damping: 0.73).
        var t = CATransform3DMakeTranslation(0, hover ? -1 : 0, 0)
        t = CATransform3DScale(t, hover ? 1.018 : 1, hover ? 1.055 : 1, 1)
        let spring = animated ? BoardMotion.hover : nil
        BoardMotion.animate(body, key: "transform", to: t, spring: spring)
        BoardMotion.animate(body, key: "shadowOpacity", to: hover ? 0.34 : 0, spring: spring)
        BoardMotion.animate(body, key: "shadowRadius", to: hover ? 3 : 0, spring: spring)
        BoardMotion.animate(body, key: "shadowOffset",
                            to: CGSize(width: 0, height: hover ? 1.5 : 0), spring: spring)
    }

    func resetInteraction(animated: Bool) {
        pressed = false
        dragStarted = false
        mouseDownPoint = nil
        setHover(false, animated: animated)
    }

    // MARK: Hover (scroll-aware)

    private static func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let reset: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { activeHoverCard?.setHover(false, animated: true) }
        }
        NotificationCenter.default.addObserver(forName: .apolloScrollDidBegin,
                                               object: nil, queue: .main, using: reset)
        NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification,
                                               object: nil, queue: .main, using: reset)
    }

    static func resetActiveHover() {
        activeHoverCard?.setHover(false, animated: true)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        let blocked = ScrollStateObserver.isScrollingNow || ScrollGate.shared.active
            || delegate?.isPopupOpen == true
        setHover(!blocked, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        setHover(false, animated: true)
    }

    // MARK: Click / drag / menu

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard delegate?.isPopupOpen != true else { return }
        pressed = true
        dragStarted = false
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed, !dragStarted, let start = mouseDownPoint,
              delegate?.isPopupOpen != true else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) >= 3 else { return }
        guard let drag = delegate?.cardDragPayload(self) else { return }
        dragStarted = true
        pressed = false
        let item = NSPasteboardItem()
        item.setString(drag.payload, forType: .string)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(drag.frame, contents: drag.image)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false; mouseDownPoint = nil }
        guard !dragStarted else { dragStarted = false; return }
        guard pressed, delegate?.isPopupOpen != true,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        delegate?.cardActivated(self, modifiers: event.modifierFlags)
    }

    override func accessibilityPerformPress() -> Bool {
        guard delegate?.isPopupOpen != true else { return false }
        delegate?.cardActivated(self, modifiers: [])
        return true
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        dragStarted = false
        mouseDownPoint = nil
        delegate?.cardDragEnded(self, operation: operation)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard delegate?.isPopupOpen != true, let delegate else { return nil }
        let actions = delegate.cardContextActions(self)
        return actions.isEmpty ? nil : TaskContextMenu.makeNSMenu(actions: actions)
    }

    // MARK: Avatars

    private func requestAvatarImages() {
        guard let task else { return }
        let generation = avatarGeneration
        let taskId = task.id
        for assignee in task.assignees.prefix(3) {
            guard let url = assignee.photoURL, AvatarStore.shared.image(for: url) == nil else { continue }
            Task { @MainActor [weak self] in
                let image = await AvatarStore.shared.load(url).value
                // Identity check: a recycled card must never show another task's photo.
                guard image != nil, let self, self.avatarGeneration == generation,
                      self.task?.id == taskId else { return }
                self.content.setNeedsDisplay()
            }
        }
    }

    // MARK: Drawing

    fileprivate func drawContent(in ctx: CGContext) {
        guard let task, let layout = cardLayout else { return }
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        effectiveAppearance.performAsCurrentDrawingAppearance {
            BoardCardRenderer.draw(task: task, layout: layout, in: ctx)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Snapshot used for the single-card drag image fallback.
    func snapshotImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }
}

/// CALayer delegate that forwards drawing without making the NSView the
/// delegate of a non-backing layer.
private final class BoardCardPainter: NSObject, CALayerDelegate {
    weak var card: BoardCardView?

    func draw(_ layer: CALayer, in ctx: CGContext) {
        ctx.saveGState()
        // Inside a flipped NSView the layer tree is geometry-flipped and the
        // context already arrives top-left; flip only when it does not.
        if !layer.contentsAreFlipped() {
            ctx.translateBy(x: 0, y: layer.bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        MainActor.assumeIsolated { card?.drawContent(in: ctx) }
        ctx.restoreGState()
    }

    func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
}

/// Stateless drawing of the card content (everything except surface,
/// selection and hover). Coordinates are flipped (top-left origin).
enum BoardCardRenderer {
    /// `RoundedRectangle(cornerRadius: BoardCardLayout.radius, style: .continuous)`.
    static func surfacePath(_ rect: CGRect) -> CGPath {
        RoundedRectangle(cornerRadius: BoardCardLayout.radius, style: .continuous).path(in: rect).cgPath
    }

    static func draw(task: CUTask, layout: BoardCardLayout, in ctx: CGContext) {
        let pad = BoardCardLayout.padding
        // .background(fill(Editorial.page)) + .overlay(strokeBorder(rule, 0.5))
        let bounds = CGRect(x: 0, y: 0, width: BoardCardLayout.width, height: layout.height)
        if !BoardDiag.has("nosurface") {
            ctx.addPath(surfacePath(bounds))
            ctx.setFillColor(NSColor(Editorial.page).cgColor)
            ctx.fillPath()
            ctx.addPath(surfacePath(bounds.insetBy(dx: 0.25, dy: 0.25)))
            ctx.setStrokeColor(NSColor(Editorial.rule).cgColor)
            ctx.setLineWidth(0.5)
            ctx.strokePath()
        }
        let right = pad + BoardCardLayout.contentWidth
        let statusColor = NSColor.vibrantStatus(hex: task.statusDisplayHex)

        // Top row — HStack(spacing: 8) { dot 6 · breadcrumb · Spacer(4) · chip }
        let topY = pad
        let topH = layout.topRowHeight
        fillCircle(ctx, CGRect(x: pad, y: topY + (topH - 6) / 2, width: 6, height: 6), statusColor)
        drawLine(ctx, layout.breadcrumb, x: pad + 6 + 8,
                 y: topY + (topH - layout.breadcrumb.height) / 2,
                 color: NSColor(Editorial.inkMute))
        if let chip = layout.chip {
            let hex = NSColor(Color(hex: task.priorityHex))
            let chipRect = CGRect(x: right - chip.width, y: topY + (topH - (chip.text.height + 4)) / 2,
                                  width: chip.width, height: chip.text.height + 4)
            ctx.setFillColor(hex.withAlphaComponent(0.10).cgColor)
            ctx.addPath(CGPath(roundedRect: chipRect, cornerWidth: chipRect.height / 2,
                               cornerHeight: chipRect.height / 2, transform: nil))
            ctx.fillPath()
            fillCircle(ctx, CGRect(x: chipRect.minX + 6, y: chipRect.minY + (chipRect.height - 5) / 2,
                                   width: 5, height: 5), hex)
            drawLine(ctx, chip.text, x: chipRect.minX + 6 + 5 + 4, y: chipRect.minY + 2, color: hex)
        }

        // Title — up to three lines.
        let ink = NSColor(Editorial.ink)
        for (i, line) in layout.titleLines.enumerated() {
            let y = layout.titleY + CGFloat(i) * BoardCardLayout.titleLineHeight
            drawCTLine(ctx, line, x: pad, baselineY: y + BoardCardLayout.titleBaseline, color: ink)
        }

        // Footer — HStack(spacing: 8) { avatars · name · Spacer(4) · date }
        let fy = layout.footerY
        let size = BoardCardLayout.avatarSize
        drawAvatars(ctx, task: task, layout: layout, origin: CGPoint(x: pad, y: fy))
        drawLine(ctx, layout.name, x: pad + layout.avatarStackWidth + 8,
                 y: fy + (size - layout.name.height) / 2, color: NSColor(Editorial.inkSoft))
        if let date = layout.date, let due = task.dueDate {
            let tone = BoardCardFormatting.dateTone(due: due, isCompleted: task.isCompleted)
            let color: NSColor
            switch tone {
            case .today:   color = NSColor(Editorial.accent)
            case .overdue: color = NSColor(Editorial.overdue)
            case .normal:  color = NSColor(Editorial.inkMute)
            }
            let arrowColor = tone == .normal ? NSColor(Editorial.inkFaint) : color
            let groupW = date.width + 3 + BoardCardArrow.frame.width
            let groupH = max(date.height, BoardCardArrow.frame.height)
            let gx = right - groupW
            let gy = fy + (size - groupH) / 2
            drawLine(ctx, date, x: gx, y: gy + (groupH - date.height) / 2, color: color)
            drawArrow(ctx, in: CGRect(x: gx + date.width + 3,
                                      y: gy + (groupH - BoardCardArrow.frame.height) / 2,
                                      width: BoardCardArrow.frame.width,
                                      height: BoardCardArrow.frame.height),
                      color: arrowColor)
        }
    }

    private static func drawAvatars(_ ctx: CGContext, task: CUTask, layout: BoardCardLayout,
                                    origin: CGPoint) {
        let size = BoardCardLayout.avatarSize
        if task.assignees.isEmpty {
            let rect = CGRect(origin: origin, size: CGSize(width: size, height: size))
            fillCircle(ctx, rect, NSColor.vibrantStatus(hex: BoardCardFormatting.assigneeColorHex(task)))
            drawCentered(ctx, "·", font: BoardCardFonts.emptyDot, in: rect, color: .white)
            return
        }
        let ring = NSColor(Editorial.page)
        let step = size - size * 0.34
        for (i, assignee) in task.assignees.prefix(3).enumerated() {
            let x = BoardCardLayout.pixelRound(origin.x + CGFloat(i) * step, 2)
            let rect = CGRect(x: x, y: origin.y, width: size, height: size)
            fillCircle(ctx, rect, NSColor(Color(hex: assignee.color ?? "#7A6597")))
            drawCentered(ctx, assignee.avatarInitials, font: BoardCardFonts.initials, in: rect, color: .white)
            if let url = assignee.photoURL, let image = AvatarStore.shared.image(for: url) {
                ctx.saveGState()
                ctx.addEllipse(in: rect)
                ctx.clip()
                drawAspectFill(image, in: rect)
                ctx.restoreGState()
            }
            strokeRing(ctx, rect, ring)
        }
        if layout.avatarOverflow > 0 {
            let x = BoardCardLayout.pixelRound(origin.x + 3 * step, 2)
            let rect = CGRect(x: x, y: origin.y, width: size, height: size)
            fillCircle(ctx, rect, NSColor(Editorial.card))
            drawCentered(ctx, "+\(layout.avatarOverflow)", font: BoardCardFonts.overflow,
                         in: rect, color: NSColor(Editorial.inkSoft))
            strokeRing(ctx, rect, ring)
        }
    }

    private static func strokeRing(_ ctx: CGContext, _ rect: CGRect, _ color: NSColor) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: rect)
    }

    private static func drawAspectFill(_ image: NSImage, in rect: CGRect) {
        let s = image.size
        guard s.width > 0, s.height > 0 else { return }
        let scale = max(rect.width / s.width, rect.height / s.height)
        let w = s.width * scale, h = s.height * scale
        image.draw(in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h),
                   from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    private static func drawArrow(_ ctx: CGContext, in rect: CGRect, color: NSColor) {
        guard let symbol = BoardCardArrow.image else { return }
        let tinted = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let s = symbol.size
        tinted.draw(in: CGRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2,
                               width: s.width, height: s.height),
                    from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
    }

    static func fillCircle(_ ctx: CGContext, _ rect: CGRect, _ color: NSColor) {
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: rect)
    }

    static func drawLine(_ ctx: CGContext, _ line: BoardTextLine, x: CGFloat, y: CGFloat, color: NSColor) {
        let py = BoardCardLayout.pixelRound(y, 2)
        drawCTLine(ctx, line.line, x: x, baselineY: py + line.baseline, color: color)
    }

    static func drawCTLine(_ ctx: CGContext, _ line: CTLine, x: CGFloat, baselineY: CGFloat, color: NSColor) {
        ctx.saveGState()
        ctx.setFillColor(color.cgColor)
        // CoreText draws in a y-up space: flip locally around the baseline.
        ctx.textMatrix = .identity
        ctx.translateBy(x: x, y: baselineY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func drawCentered(_ ctx: CGContext, _ string: String, font: NSFont,
                                     in rect: CGRect, color: NSColor) {
        let line = BoardTextLine.make(string, font: font, pixel: 2)
        let x = rect.midX - line.width / 2
        let y = rect.midY - line.height / 2
        drawLine(ctx, line, x: BoardCardLayout.pixelRound(x, 2), y: y, color: color)
    }
}

/// SwiftUI spring equivalents. `spring(response:dampingFraction:)` equals
/// `Spring(duration: response, bounce: 1 - dampingFraction)`; `.bouncy(duration:
/// extraBounce:)` has bounce 0.3 + extraBounce.
enum BoardMotion {
    struct Spring { let duration: Double; let bounce: Double }
    static let hover = Spring(duration: 0.30, bounce: 0.27)
    static let selection = Spring(duration: 0.24, bounce: 0.22)
    static let dragSource = Spring(duration: 0.34, bounce: 0.42)
    static let reorder = Spring(duration: 0.40, bounce: 0.42)

    static func animate(_ layer: CALayer, key: String, to value: Any, spring: Spring?) {
        let from = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: key)
        CATransaction.commit()
        guard let spring else {
            layer.removeAnimation(forKey: key)
            return
        }
        let anim = CASpringAnimation(perceptualDuration: spring.duration, bounce: spring.bounce)
        anim.keyPath = key
        anim.fromValue = from
        anim.toValue = value
        anim.duration = anim.settlingDuration
        anim.fillMode = .backwards
        layer.add(anim, forKey: key)
    }
}
