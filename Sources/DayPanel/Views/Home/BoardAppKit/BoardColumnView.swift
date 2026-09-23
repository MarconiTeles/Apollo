import AppKit
import SwiftUI

/// Shared recycling pool for card views of every mounted column. The number
/// of live cards is bounded by the visible area, never by the task count.
@MainActor
final class BoardCardPool {
    private var free: [BoardCardView] = []
    private(set) var created = 0
    private(set) var reused = 0

    func dequeue() -> BoardCardView {
        if let card = free.popLast() {
            reused += 1
            return card
        }
        created += 1
        return BoardCardView(frame: .zero)
    }

    func enqueue(_ card: BoardCardView) {
        card.prepareForReuse()
        card.removeFromSuperview()
        if free.count < 64 { free.append(card) }
    }
}

/// Vertical metrics shared by every column (SwiftUI reference geometry).
struct BoardColumnMetrics: Equatable {
    /// `.padding(.vertical, 8)` around the per-column ScrollView. The scroll
    /// view is laid out full height here and the 8pt moves into the document so
    /// cards keep drawing to the window edge (`scrollClipDisabled`).
    static let outerVertical: CGFloat = 8
    static let cardSpacing: CGFloat = 12
    static let horizontalPadding: CGFloat = 10
    static let placeholderTopPadding: CGFloat = 4

    var headerChromeHeight: CGFloat

    /// contentMargins(.top, header + 20) + LazyVStack padding(.top, 6).
    var topInset: CGFloat { Self.outerVertical + headerChromeHeight + 20 + 6 }
    /// padding(.bottom, 8) + contentMargins(.bottom, 24).
    var bottomInset: CGFloat { 8 + 24 + Self.outerVertical }
}

/// Scroll view that keeps each gesture on one axis: horizontal-dominant
/// gestures (including their momentum) belong to the board's horizontal
/// scroll view, exactly like nested SwiftUI ScrollViews.
final class BoardVerticalScrollView: NSScrollView {
    private var forwardingGesture = false

    override func scrollWheel(with event: NSEvent) {
        let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        if event.phase == .mayBegin || event.phase == .began {
            forwardingGesture = horizontal
        } else if event.phase == [] && event.momentumPhase == [] {
            // Legacy wheel / Shift+wheel: decided per event.
            forwardingGesture = horizontal
        }
        // `.changed`, `.ended` and the momentum tail keep the axis chosen at
        // `.began`, so a gesture never switches scroll views halfway.
        if forwardingGesture {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Flipped document of one column. Hosts recycled cards, the SwiftUI
/// "Adicionar card" placeholder and cold-start skeletons.
@MainActor
final class BoardColumnDocumentView: NSView {
    override var isFlipped: Bool { true }
    weak var column: BoardColumnView?

    override func mouseDown(with event: NSEvent) {
        column?.backgroundClicked()
    }

    override func prepareContent(in rect: NSRect) {
        super.prepareContent(in: rect)
        column?.tile(prepared: rect)
    }

    override var isOpaque: Bool { false }
}

@MainActor
protocol BoardColumnViewDelegate: AnyObject {
    var cardDelegate: BoardCardViewDelegate? { get }
    var pool: BoardCardPool { get }
    var workspaceName: String { get }
    func isSelected(_ id: String) -> Bool
    func isDragSource(_ id: String) -> Bool
    func columnBackgroundClicked(_ column: BoardColumnView)
    func columnDidScroll(_ column: BoardColumnView)
    // Drag destination, same semantics as CardReorderDropDelegate / BoardDropDelegate.
    func columnDragUpdated(_ column: BoardColumnView, cardId: String?, payload: String?) -> NSDragOperation
    func columnDragExited(_ column: BoardColumnView)
    func columnPerformDrop(_ column: BoardColumnView, cardId: String?, payload: String?) -> Bool
}

/// One status column: drop wash + independent vertical scroll + virtualized
/// cards. Mounted only while near the horizontal viewport.
@MainActor
final class BoardColumnView: NSView {
    override var isFlipped: Bool { true }

    weak var delegate: BoardColumnViewDelegate?
    private(set) var snapshot: BoardColumnSnapshot
    private var metrics: BoardColumnMetrics
    private var isColdLoading: Bool

    let scrollView = BoardVerticalScrollView()
    private let document = BoardColumnDocumentView()
    private let wash = CALayer()
    private let washBorder = CALayer()
    private var isDropTarget = false

    private var heights: [CGFloat] = []
    private var tops: [CGFloat] = []
    private var indexById: [String: Int] = [:]
    private var cardsTop: CGFloat = 0
    private var skeletonHeight: CGFloat = 0
    private var visible: [String: BoardCardView] = [:]

    private let placeholder: BoardAddCardView
    private var skeletons: NSHostingView<BoardColumnSkeletons>?
    private var boundsObserver: NSObjectProtocol?

    init(snapshot: BoardColumnSnapshot, metrics: BoardColumnMetrics, isColdLoading: Bool) {
        self.snapshot = snapshot
        self.metrics = metrics
        self.isColdLoading = isColdLoading
        placeholder = BoardAddCardView(status: snapshot.status)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        // Drop-target wash: RoundedRectangle(8).fill(card × 0.65) +
        // stroke(accent × 0.35, 1pt) centred on the edge.
        wash.cornerRadius = 8
        wash.cornerCurve = .continuous
        wash.opacity = 0
        washBorder.cornerRadius = 8.5
        washBorder.cornerCurve = .continuous
        washBorder.borderWidth = 1
        washBorder.opacity = 0
        layer?.addSublayer(wash)
        layer?.addSublayer(washBorder)

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .allowed
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layer?.masksToBounds = true
        document.column = self
        document.wantsLayer = true
        document.layer?.masksToBounds = false
        scrollView.documentView = document
        addSubview(scrollView)
        document.addSubview(placeholder)

        registerForDraggedTypes([.string])
        document.registerForDraggedTypes([.string])

        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tile()
                self.delegate?.columnDidScroll(self)
            }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(snapshot.status.status)
        rebuildMetrics()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    // MARK: Updates

    var verticalOffset: CGFloat {
        get { scrollView.contentView.bounds.origin.y }
        set {
            let maxY = max(0, document.frame.height - scrollView.contentView.bounds.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, newValue), maxY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// Applies a new column snapshot. Only changed/visible cards are touched.
    func update(snapshot new: BoardColumnSnapshot, metrics newMetrics: BoardColumnMetrics,
                isColdLoading cold: Bool, animated: Bool) {
        let statusChanged = new.status != snapshot.status
        let cardsChanged = new.cards != snapshot.cards
        let metricsChanged = newMetrics != metrics || cold != isColdLoading
        guard statusChanged || cardsChanged || metricsChanged else { return }
        BoardInstrumentation.counters.columnUpdates += 1
        let oldFrames = visible.mapValues(\.frame)
        snapshot = new
        metrics = newMetrics
        isColdLoading = cold
        if statusChanged {
            placeholder.status = new.status
            setAccessibilityLabel(new.status.status)
        }
        rebuildMetrics()
        tile(forceRebind: cardsChanged)
        if animated {
            for (id, card) in visible {
                guard let from = oldFrames[id], from.origin != card.frame.origin else { continue }
                animateMove(card, from: from.origin)
            }
        }
    }

    func refreshInteractionStates(animated: Bool) {
        guard let delegate else { return }
        for (id, card) in visible {
            card.setSelected(delegate.isSelected(id), animated: animated)
            card.setDragSource(delegate.isDragSource(id), animated: animated)
        }
    }

    func setDropTarget(_ target: Bool) {
        guard target != isDropTarget else { return }
        isDropTarget = target
        // .animation(.easeOut(duration: 0.12), value: isDropTarget)
        for l in [wash, washBorder] {
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = l.presentation()?.opacity ?? l.opacity
            anim.toValue = target ? 1 : 0
            anim.duration = 0.12
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            l.opacity = target ? 1 : 0
            CATransaction.commit()
            l.add(anim, forKey: "opacity")
        }
    }

    private func animateMove(_ card: BoardCardView, from origin: CGPoint) {
        guard let layer = card.layer else { return }
        // Reflow with `.bouncy(duration: 0.40, extraBounce: 0.12)`.
        let dy = origin.y - card.frame.origin.y
        let anim = CASpringAnimation(perceptualDuration: BoardMotion.reorder.duration,
                                     bounce: BoardMotion.reorder.bounce)
        anim.keyPath = "position.y"
        anim.fromValue = layer.position.y + dy
        anim.toValue = layer.position.y
        anim.duration = anim.settlingDuration
        layer.add(anim, forKey: "boardReorder")
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wash.frame = bounds
        washBorder.frame = bounds.insetBy(dx: -0.5, dy: -0.5)
        CATransaction.commit()
        if scrollView.frame != bounds {
            scrollView.frame = bounds
            layoutDocument()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyWashColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyWashColors()
    }

    private func applyWashColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wash.backgroundColor = editorialCG(Editorial.card.opacity(0.65))
        washBorder.borderColor = editorialCG(Editorial.accent.opacity(0.35))
        CATransaction.commit()
    }

    private func rebuildMetrics() {
        BoardInstrumentation.counters.heightRecomputes += 1
        let cache = BoardTitleCache.shared
        heights = snapshot.cards.map { cache.height(for: $0) }
        indexById = Dictionary(snapshot.cards.enumerated().map { ($1.id, $0) },
                               uniquingKeysWith: { a, _ in a })
        let showSkeletons = snapshot.cards.isEmpty && isColdLoading
        if showSkeletons {
            if skeletons == nil {
                let host = NSHostingView(rootView: BoardColumnSkeletons())
                document.addSubview(host, positioned: .below, relativeTo: nil)
                skeletons = host
            }
            skeletonHeight = skeletons?.fittingSize.height ?? 0
        } else {
            skeletons?.removeFromSuperview()
            skeletons = nil
            skeletonHeight = 0
        }
        cardsTop = metrics.topInset + (showSkeletons ? skeletonHeight + BoardColumnMetrics.cardSpacing : 0)
        tops = []
        tops.reserveCapacity(heights.count)
        var y = cardsTop
        for h in heights {
            tops.append(y)
            y += h + BoardColumnMetrics.cardSpacing
        }
        layoutDocument()
    }

    private func layoutDocument() {
        let x = BoardColumnMetrics.horizontalPadding
        let width = BoardCardLayout.width
        let placeholderHeight = BoardAddCardView.height
        var y = cardsTop
        if let last = tops.last, let h = heights.last {
            y = last + h + BoardColumnMetrics.cardSpacing
        } else if skeletons != nil {
            y = cardsTop
        } else {
            y = metrics.topInset
        }
        let placeholderY = y + BoardColumnMetrics.placeholderTopPadding
        let placeholderFrame = NSRect(x: x, y: placeholderY, width: width, height: placeholderHeight)
        if placeholder.frame != placeholderFrame { placeholder.frame = placeholderFrame }
        if let skeletons {
            skeletons.frame = NSRect(x: x, y: metrics.topInset, width: width, height: skeletonHeight)
        }
        let contentHeight = placeholderFrame.maxY + metrics.bottomInset
        let size = NSSize(width: bounds.width, height: contentHeight)
        if document.frame.size != size { document.setFrameSize(size) }
        tile()
    }

    /// Mounts the cards intersecting the visible (or prepared) rect plus a
    /// small overscan; recycles the rest. O(log n + visible).
    func tile(prepared: NSRect? = nil, forceRebind: Bool = false) {
        guard let delegate else { return }
        BoardInstrumentation.counters.tiles += 1
        let clip = scrollView.contentView.bounds
        var rect = clip.insetBy(dx: 0, dy: -max(200, clip.height * 0.5))
        if let prepared { rect = rect.union(prepared) }
        var wanted = Set<String>()
        if !tops.isEmpty {
            var lo = 0, hi = tops.count - 1, first = tops.count
            while lo <= hi {
                let mid = (lo + hi) / 2
                if tops[mid] + heights[mid] >= rect.minY { first = mid; hi = mid - 1 } else { lo = mid + 1 }
            }
            var i = first
            while i < tops.count && tops[i] <= rect.maxY {
                wanted.insert(snapshot.cards[i].id)
                i += 1
            }
        }
        for (id, card) in visible where !wanted.contains(id) {
            visible[id] = nil
            delegate.pool.enqueue(card)
        }
        let pixel = window?.backingScaleFactor ?? 2
        for id in wanted {
            guard let index = indexById[id] else { continue }
            let task = snapshot.cards[index]
            let frame = NSRect(x: BoardColumnMetrics.horizontalPadding, y: tops[index],
                               width: BoardCardLayout.width, height: heights[index])
            if let card = visible[id] {
                if card.frame != frame { card.frame = frame }
                if forceRebind && card.task != task {
                    card.bind(task: task, workspaceName: delegate.workspaceName,
                              layout: layout(for: task, pixel: pixel))
                }
                continue
            }
            let card = delegate.pool.dequeue()
            card.delegate = delegate.cardDelegate
            card.frame = frame
            card.bind(task: task, workspaceName: delegate.workspaceName,
                      layout: layout(for: task, pixel: pixel))
            BoardInstrumentation.counters.binds += 1
            card.setSelected(delegate.isSelected(id), animated: false)
            card.setDragSource(delegate.isDragSource(id), animated: false)
            document.addSubview(card)
            visible[id] = card
        }
    }

    func rebindAll(workspaceChanged: Bool) {
        guard let delegate, workspaceChanged else { return }
        let pixel = window?.backingScaleFactor ?? 2
        for (_, card) in visible {
            guard let task = card.task else { continue }
            card.bind(task: task, workspaceName: delegate.workspaceName,
                      layout: layout(for: task, pixel: pixel))
        }
    }

    private func layout(for task: CUTask, pixel: CGFloat) -> BoardCardLayout {
        BoardCardLayout.make(task: task, workspaceName: delegate?.workspaceName ?? "",
                             pixel: pixel, titleLines: BoardTitleCache.shared.lines(for: task.title))
    }

    var liveCardCount: Int { visible.count }

    func cardView(for id: String) -> BoardCardView? { visible[id] }

    // MARK: Hit testing for drops

    /// Card whose model frame contains `point` (document coordinates).
    func cardId(atDocumentPoint point: NSPoint) -> String? {
        guard !tops.isEmpty else { return nil }
        let minX = BoardColumnMetrics.horizontalPadding
        guard point.x >= minX, point.x <= minX + BoardCardLayout.width else { return nil }
        var lo = 0, hi = tops.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if point.y < tops[mid] { hi = mid - 1 }
            else if point.y > tops[mid] + heights[mid] { lo = mid + 1 }
            else { return snapshot.cards[mid].id }
        }
        return nil
    }

    private func cardId(for info: NSDraggingInfo) -> String? {
        let point = document.convert(info.draggingLocation, from: nil)
        return cardId(atDocumentPoint: point)
    }

    func backgroundClicked() {
        delegate?.columnBackgroundClicked(self)
    }

    override func mouseDown(with event: NSEvent) {
        backgroundClicked()
    }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        delegate?.columnDragUpdated(self, cardId: cardId(for: sender),
                                    payload: sender.draggingPasteboard.string(forType: .string)) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        delegate?.columnDragUpdated(self, cardId: cardId(for: sender),
                                    payload: sender.draggingPasteboard.string(forType: .string)) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        delegate?.columnDragExited(self)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        delegate?.columnPerformDrop(self, cardId: cardId(for: sender),
                                    payload: sender.draggingPasteboard.string(forType: .string)) ?? false
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { false }
}

/// Cold-start placeholders, identical to the reference LazyVStack prefix.
struct BoardColumnSkeletons: View {
    var body: some View {
        VStack(alignment: .leading, spacing: BoardColumnMetrics.cardSpacing) {
            ForEach(0..<3, id: \.self) { i in
                EditorialSkeletonCard()
                    .cascadeAppear(index: i)
            }
        }
        .frame(width: BoardCardLayout.width, alignment: .leading)
    }
}

/// Native "¶ Adicionar card" (reference `addCardPlaceholder`): italic
/// `Editorial.serif(12)` in inkFaint, 14pt padding, dashed 1pt `rule` border
/// on a 6pt continuous rounded rectangle. Drawn once into its layer; moving
/// with the scroll costs nothing (an NSHostingView here re-entered SwiftUI
/// layout on every scroll tick).
@MainActor
final class BoardAddCardView: NSView {
    override var isFlipped: Bool { true }
    var status: CUStatus { didSet { setAccessibilityLabel("Adicionar card em \(status.status)") } }
    private var pressed = false { didSet { alphaValue = pressed ? 0.75 : 1 } }

    static let font: NSFont = {
        let base = NSFont.systemFont(ofSize: 12 * Editorial.typeScale)
        let italic = base.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: italic, size: base.pointSize) ?? base
    }()
    static let line = BoardTextLine.make("¶ Adicionar card", font: font, pixel: 2)
    static let height: CGFloat = line.height + 28

    init(status: CUStatus) {
        self.status = status
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Adicionar card em \(status.status)")
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let path = RoundedRectangle(cornerRadius: 6, style: .continuous)
            .path(in: bounds.insetBy(dx: 0.5, dy: 0.5)).cgPath
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor(Editorial.rule).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        BoardCardRenderer.drawLine(ctx, Self.line, x: 14, y: 14, color: NSColor(Editorial.inkFaint))
    }

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseDragged(with event: NSEvent) {
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { accessibilityPerformPress() }
    }

    override func accessibilityPerformPress() -> Bool {
        NotificationCenter.default.post(name: .editorialBoardCreateCard, object: nil,
                                        userInfo: ["status": status.status])
        return true
    }
}
