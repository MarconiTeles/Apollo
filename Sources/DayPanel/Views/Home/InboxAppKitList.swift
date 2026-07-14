import AppKit
import SwiftUI

private enum InboxNotificationMetrics {
    static let rowHeight: CGFloat = 58
    static let rowSpacing: CGFloat = 9
}

/// Recycled native viewport for the Home Inbox.
///
/// The previous SwiftUI `LazyVStack` still created one hover modifier, two
/// global scroll subscriptions, a relative-time timeline and a live shadow
/// for every visible capsule. On a trackpad gesture those independent view
/// graphs competed with the scroll transaction. This collection view keeps
/// the same two-line capsule but reuses a small number of AppKit cells and
/// paints its shadow from a fixed `shadowPath`.
struct InboxAppKitList: NSViewRepresentable {
    let notifications: [AppNotification]
    let onDismiss: (UUID) -> Void
    let onTap: (AppNotification) -> Void
    var topInset: CGFloat = 14
    var bottomInset: CGFloat = 72
    var horizontalInset: CGFloat = 20

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = InboxNotificationMetrics.rowSpacing
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = NSEdgeInsets(top: topInset,
                                           left: horizontalInset,
                                           bottom: bottomInset,
                                           right: horizontalInset)
        layout.itemSize = NSSize(width: 600,
                                 height: InboxNotificationMetrics.rowHeight)

        let collection = InboxWidthTrackingCollectionView(frame: .zero)
        collection.collectionViewLayout = layout
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.isSelectable = false
        collection.backgroundColors = [.clear]
        collection.register(InboxNotificationItem.self,
                            forItemWithIdentifier: InboxNotificationItem.identifier)
        collection.onResize = { [weak collection] in
            guard let collection,
                  let flow = collection.collectionViewLayout as? NSCollectionViewFlowLayout
            else { return }
            let width = max(1, collection.bounds.width
                            - flow.sectionInset.left - flow.sectionInset.right)
            guard abs(flow.itemSize.width - width) > 0.5 else { return }
            flow.itemSize = NSSize(width: width,
                                   height: InboxNotificationMetrics.rowHeight)
            flow.invalidateLayout()
        }

        context.coordinator.collection = collection
        context.coordinator.horizontalInset = horizontalInset
        scroll.documentView = collection
        context.coordinator.update(parent: self, force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.horizontalInset = horizontalInset
        if let collection = scroll.documentView as? NSCollectionView,
           let flow = collection.collectionViewLayout as? NSCollectionViewFlowLayout {
            let next = NSEdgeInsets(top: topInset,
                                    left: horizontalInset,
                                    bottom: bottomInset,
                                    right: horizontalInset)
            let current = flow.sectionInset
            if current.top != next.top || current.left != next.left
                || current.bottom != next.bottom || current.right != next.right {
                flow.sectionInset = next
                flow.invalidateLayout()
            }
        }
        context.coordinator.update(parent: self)
    }

    final class Coordinator: NSObject,
                             NSCollectionViewDataSource,
                             NSCollectionViewDelegateFlowLayout {
        private var notifications: [AppNotification] = []
        private var onDismiss: (UUID) -> Void
        private var onTap: (AppNotification) -> Void
        weak var collection: NSCollectionView?
        var horizontalInset: CGFloat = 20

        init(parent: InboxAppKitList) {
            onDismiss = parent.onDismiss
            onTap = parent.onTap
        }

        func update(parent: InboxAppKitList, force: Bool = false) {
            onDismiss = parent.onDismiss
            onTap = parent.onTap
            guard force || notifications != parent.notifications else { return }

            let old = notifications
            let next = parent.notifications
            let oldIDs = old.map(\.id)
            let nextIDs = next.map(\.id)
            notifications = next

            guard !force, let collection else {
                collection?.reloadData()
                return
            }

            let oldSet = Set(oldIDs)
            let nextSet = Set(nextIDs)
            let survivingOld = oldIDs.filter(nextSet.contains)
            let survivingNew = nextIDs.filter(oldSet.contains)
            guard survivingOld == survivingNew else {
                collection.reloadData()
                return
            }

            let removed = Set(oldIDs.enumerated().compactMap { index, id in
                nextSet.contains(id) ? nil : IndexPath(item: index, section: 0)
            })
            let inserted = Set(nextIDs.enumerated().compactMap { index, id in
                oldSet.contains(id) ? nil : IndexPath(item: index, section: 0)
            })
            let changed: Set<IndexPath> = Set(next.enumerated().compactMap { index, value in
                guard let oldIndex = oldIDs.firstIndex(of: value.id),
                      old[oldIndex] != value else { return nil }
                return IndexPath(item: index, section: 0)
            })

            if removed.isEmpty && inserted.isEmpty {
                if !changed.isEmpty { collection.reloadItems(at: changed) }
            } else {
                collection.performBatchUpdates {
                    if !removed.isEmpty { collection.deleteItems(at: removed) }
                    if !inserted.isEmpty { collection.insertItems(at: inserted) }
                }
            }
        }

        func collectionView(_ collectionView: NSCollectionView,
                            numberOfItemsInSection section: Int) -> Int {
            notifications.count
        }

        func collectionView(_ collectionView: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath)
            -> NSCollectionViewItem {
            let item = collectionView.makeItem(
                withIdentifier: InboxNotificationItem.identifier,
                for: indexPath
            ) as! InboxNotificationItem
            let notification = notifications[indexPath.item]
            item.bind(notification: notification,
                      onTap: { [weak self] in self?.onTap(notification) },
                      onDismiss: { [weak self] in self?.onDismiss(notification.id) })
            return item
        }

        func collectionView(_ collectionView: NSCollectionView,
                            layout collectionViewLayout: NSCollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> NSSize {
            let inset = horizontalInset * 2
            return NSSize(width: max(1, collectionView.bounds.width - inset),
                          height: InboxNotificationMetrics.rowHeight)
        }
    }
}

private final class InboxWidthTrackingCollectionView: NSCollectionView {
    var onResize: (() -> Void)?
    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(frame.size.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if changed { onResize?() }
    }
}

private final class InboxNotificationItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("InboxNotificationItem")
    private let row = InboxNotificationCell()

    override func loadView() { view = row }

    override func prepareForReuse() {
        super.prepareForReuse()
        row.prepareForReuse()
    }

    func bind(notification: AppNotification,
              onTap: @escaping () -> Void,
              onDismiss: @escaping () -> Void) {
        row.bind(notification: notification,
                 onTap: onTap,
                 onDismiss: onDismiss)
    }
}

private final class InboxNotificationCell: NSView {
    override var isFlipped: Bool { true }

    private let surface = InboxFlippedSurface()
    private let source = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let secondary = NSTextField(labelWithString: "")
    private let openButton = NSButton()
    private let dismissButton = NSButton()

    private var notification: AppNotification?
    private var onTap: (() -> Void)?
    private var onDismiss: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var scrollObserver: NSObjectProtocol?
    private var tint = NSColor.systemBlue

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        surface.wantsLayer = true
        surface.layer?.cornerRadius = Editorial.notificationCapsuleRadius
        surface.layer?.cornerCurve = .continuous
        surface.layer?.masksToBounds = false
        surface.layer?.borderWidth = 0.6
        surface.layer?.shadowColor = NSColor.black.cgColor
        surface.layer?.shadowOpacity = 0.035
        surface.layer?.shadowRadius = 1.5
        surface.layer?.shadowOffset = CGSize(
            width: 0,
            height: Editorial.nativeCapsuleShadowRestY
        )
        addSubview(surface)

        configureLabel(source, size: 8.5, weight: .semibold)
        configureLabel(title, size: 13.5, weight: .semibold)
        configureLabel(time, size: 10.5, weight: .regular)
        configureLabel(secondary, size: 11.5, weight: .regular)
        source.maximumNumberOfLines = 1
        title.maximumNumberOfLines = 1
        secondary.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        secondary.lineBreakMode = .byTruncatingTail
        time.alignment = .right

        openButton.isBordered = false
        openButton.title = "abrir"
        openButton.font = .systemFont(ofSize: 10.5, weight: .medium)
        openButton.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: nil)
        openButton.imagePosition = .imageLeading
        openButton.target = self
        openButton.action = #selector(openPressed)
        openButton.focusRingType = .none

        dismissButton.isBordered = false
        dismissButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Descartar")
        dismissButton.imageScaling = .scaleProportionallyDown
        dismissButton.target = self
        dismissButton.action = #selector(dismissPressed)
        dismissButton.focusRingType = .none

        [source, title, time, secondary, openButton, dismissButton]
            .forEach(surface.addSubview)

        scrollObserver = NotificationCenter.default.addObserver(
            forName: .apolloScrollDidBegin,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.setHovered(false, animated: false) }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollDidBegin),
            name: NSScrollView.willStartLiveScrollNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    private func configureLabel(_ label: NSTextField,
                                size: CGFloat,
                                weight: NSFont.Weight) {
        label.font = .systemFont(ofSize: size, weight: weight)
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        notification = nil
        onTap = nil
        onDismiss = nil
        setHovered(false, animated: false)
    }

    func bind(notification: AppNotification,
              onTap: @escaping () -> Void,
              onDismiss: @escaping () -> Void) {
        self.notification = notification
        self.onTap = onTap
        self.onDismiss = onDismiss

        tint = resolvedTint(for: notification)
        source.stringValue = notification.targetKind == .task ? "CLICKUP" : "APOLLO"
        source.textColor = tint.withAlphaComponent(0.76)
        title.stringValue = notification.title
        title.textColor = notification.read
            ? NSColor.secondaryLabelColor
            : NSColor.labelColor
        time.stringValue = Self.relativeTime(notification.date)
        time.textColor = NSColor.tertiaryLabelColor
        secondary.stringValue = [notification.subtitle, notification.message]
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " · ")
        secondary.textColor = NSColor.secondaryLabelColor

        openButton.isHidden = !notification.hasTarget
        openButton.contentTintColor = NSColor.controlAccentColor
        dismissButton.contentTintColor = NSColor.tertiaryLabelColor
        surface.setAccessibilityElement(true)
        surface.setAccessibilityRole(.button)
        surface.setAccessibilityLabel(notification.title)
        surface.setAccessibilityHelp(secondary.stringValue)
        updateColors()
        needsLayout = true
    }

    private func resolvedTint(for notification: AppNotification) -> NSColor {
        if notification.targetKind == .task,
           let hex = notification.messageHighlights?.last?.hex {
            return NSColor(Color(statusHex: hex))
        }
        switch notification.kind {
        case .info: return .systemBlue
        case .success: return .systemGreen
        case .warning: return .systemOrange
        case .error: return .systemRed
        }
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let card = NSColor(Editorial.card)
            // A restrained semantic wash improves row-to-row scanning while
            // remaining one cheap, static fill (no extra blur/material pass).
            let tintedCard = card.blended(
                withFraction: notification?.read == true ? 0.025 : 0.045,
                of: tint
            ) ?? card
            surface.layer?.backgroundColor = tintedCard
                .withAlphaComponent(notification?.read == true ? 0.62 : 0.86)
                .cgColor
            // SwiftUI's `.opacity(0.72)` multiplies the dynamic rule alpha
            // (0.10 light / 0.07 dark). `withAlphaComponent(0.72)` would
            // replace it and make the AppKit outline almost ten times darker.
            let rule = NSColor(Editorial.rule)
            surface.layer?.borderColor = rule
                .withAlphaComponent(rule.alphaComponent * 0.72).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: bounds,
                                  options: [.activeInKeyWindow, .mouseEnteredAndExited],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(next)
        tracking = next
    }

    override func mouseEntered(with event: NSEvent) {
        guard !ScrollStateObserver.isScrollingNow,
              !ScrollGate.shared.active else {
            setHovered(false, animated: false)
            return
        }
        setHovered(true, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false, animated: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onTap?()
    }

    private func setHovered(_ value: Bool, animated: Bool) {
        if !animated && !value {
            // A scroll reset must win over any in-flight implicit hover
            // animation immediately; leaving its presentation layer alive is
            // what made a capsule appear hovered for a few frames mid-scroll.
            surface.layer?.removeAllAnimations()
        }
        guard hovered != value else {
            if !value { layer?.zPosition = 0 }
            return
        }
        hovered = value
        let changes = {
            if value {
                let scale = CATransform3DMakeScale(1.008, 1.025, 1)
                self.surface.layer?.transform = CATransform3DTranslate(scale, 0, -1, 0)
            } else {
                self.surface.layer?.transform = CATransform3DIdentity
            }
            self.surface.layer?.shadowOpacity = value ? 0.12 : 0.035
            self.surface.layer?.shadowRadius = value ? 4 : 1.5
            self.surface.layer?.shadowOffset = CGSize(width: 0,
                                                       height: value
                                                        ? Editorial.nativeCapsuleShadowHoverY
                                                        : Editorial.nativeCapsuleShadowRestY)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(animated ? 0.13 : 0)
        changes()
        CATransaction.commit()
        layer?.zPosition = value ? 10 : 0
    }

    @objc private func scrollDidBegin() {
        setHovered(false, animated: false)
    }

    @objc private func openPressed() { onTap?() }
    @objc private func dismissPressed() { onDismiss?() }

    override func layout() {
        super.layout()
        surface.frame = bounds
        let w = surface.bounds.width

        // Compact two-line rhythm. With the semantic dot removed the source
        // label owns the leading edge in both Home Inbox and Notifications.
        source.frame = CGRect(x: 20, y: 10, width: 48, height: 15)
        title.frame = CGRect(x: 76, y: 7,
                             width: max(80, w - 76 - 136), height: 20)
        time.frame = CGRect(x: max(0, w - 136), y: 8, width: 70, height: 17)
        dismissButton.frame = CGRect(x: max(0, w - 46), y: 5, width: 28, height: 22)
        secondary.frame = CGRect(x: 20, y: 29,
                                 width: max(80, w - 20 - 100), height: 18)
        openButton.frame = CGRect(x: max(0, w - 88), y: 26, width: 68, height: 22)

        surface.layer?.shadowPath = CGPath(
            roundedRect: surface.bounds,
            cornerWidth: Editorial.notificationCapsuleRadius,
            cornerHeight: Editorial.notificationCapsuleRadius,
            transform: nil
        )
    }

    private static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "há \(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "há \(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return "há \(hours) h" }
        let days = hours / 24
        if days == 1 { return "ontem" }
        if days < 30 { return "há \(days) dias" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: date)
    }
}

private final class InboxFlippedSurface: NSView {
    override var isFlipped: Bool { true }
}
