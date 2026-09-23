import AppKit
import SwiftUI
import Testing
@testable import ApolloRuntime

@Suite(.serialized)
@MainActor
struct MyTasksScrollTests {
    private func contentSubviews(of row: MyTasksNativeRowView) -> [NSView] {
        (row.subviews.first(where: \.canDrawSubviewsIntoLayer) ?? row).subviews
    }

    @Test(arguments: [169, 1_000, 5_000])
    func scrollingKeepsViewsBounded(taskCount: Int) throws {
        ApolloRuntimeEnvironment.activateStudio()
        let state = AppState(previewMode: true)
        let tasks = ApolloBoardFixtureGenerator.tasks(count: taskCount)
        state.tasks = tasks
        let list = MyTasksAppKitList(
            sections: [.init(status: ApolloPreviewFixtures.statuses[0], tasks: tasks, collapsed: false)],
            selectedTaskIds: [], appState: state,
            onActivate: { _, _, _ in }, onToggleStatus: { _ in },
            onBeginDrag: { [$0.id] }, onEndDrag: { _ in }, onClearSelection: {},
            onMediaAction: { _, _ in }, onBulkMediaAction: {}, onFileDrop: { _, _ in })
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1200, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: list)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func findViewport(_ view: NSView) -> MyTasksViewport? {
            if let viewport = view as? MyTasksViewport { return viewport }
            return view.subviews.lazy.compactMap(findViewport).first
        }
        let collection = try #require(findViewport(host))
        let scroll = try #require(collection.enclosingScrollView)
        collection.layoutSubtreeIfNeeded()
        #expect(collection.rowCount == taskCount + 1)
        var maximumSubviews = 0
        let start = CACurrentMediaTime()
        for step in 0..<120 {
            let fraction = CGFloat(step < 60 ? step : 119 - step) / 59
            let maxY = max(0, collection.bounds.height - scroll.contentSize.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: maxY * fraction))
            scroll.reflectScrolledClipView(scroll.contentView)
            collection.layoutSubtreeIfNeeded()
            maximumSubviews = max(maximumSubviews, collection.subviews.count)
            #expect(collection.indexPathsForVisibleItems().count < 100)
        }
        #expect(maximumSubviews < 100)
        #expect(collection.createdItemCount < 150)
        #expect(collection.attachmentCount == collection.createdItemCount)
        let binds = collection.bindCount
        for _ in 0..<100 { collection.layout() }
        #expect(collection.bindCount == binds)
        func containsCollection(_ view: NSView) -> Bool {
            view is NSCollectionView || view.subviews.contains(where: containsCollection)
        }
        #expect(!containsCollection(host))
        print("TASKS_VIEWPORT tasks=\(taskCount) maxSubviews=\(maximumSubviews) roundTripMS=\((CACurrentMediaTime()-start)*1000)")
        window.contentView = nil
        window.close()
    }

    @Test func viewportPreservesIdentityUpdatesAndCollapsePosition() throws {
        ApolloRuntimeEnvironment.activateStudio()
        let state = AppState(previewMode: true)
        var tasks = ApolloBoardFixtureGenerator.tasks(count: 1_000)
        state.tasks = tasks
        let status = ApolloPreviewFixtures.statuses[0]
        var toggled: String?
        func list(collapsed: Bool = false) -> MyTasksAppKitList {
            MyTasksAppKitList(
                sections: [.init(status: status, tasks: tasks, collapsed: collapsed)],
                selectedTaskIds: [], appState: state,
                onActivate: { _, _, _ in }, onToggleStatus: { toggled = $0 },
                onBeginDrag: { [$0.id] }, onEndDrag: { _ in }, onClearSelection: {},
                onMediaAction: { _, _ in }, onBulkMediaAction: {}, onFileDrop: { _, _ in })
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        let viewport = MyTasksViewport()
        let coordinator = list().makeCoordinator()
        viewport.coordinator = coordinator
        coordinator.viewport = viewport
        scroll.documentView = viewport
        viewport.attach(to: scroll)
        defer { viewport.detach() }
        coordinator.update(parent: list(), force: true)
        let first = try #require(viewport.subviews.compactMap { $0 as? MyTasksNativeRowView }
            .min { $0.frame.minY < $1.frame.minY })
        tasks[0].title = "Updated task keeps its native row"
        coordinator.update(parent: list())
        #expect(viewport.subviews.contains { $0 === first })
        let strings = contentSubviews(of: first).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(strings.contains(tasks[0].title))
        let header = try #require(viewport.subviews.first { !($0 is MyTasksNativeRowView) })
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        header.mouseDown(with: click)
        #expect(toggled == status.status.lowercased())
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 20_000))
        coordinator.update(parent: list(collapsed: true))
        #expect(viewport.rowCount == 1)
        #expect(viewport.subviews.filter { !$0.isHidden }.count == 1)
        #expect(scroll.contentView.bounds.minY == 0)
        coordinator.update(parent: list())
        #expect(viewport.rowCount == 1_001)
        #expect(viewport.subviews.count < 100)
        viewport.detach()
        #expect(viewport.subviews.isEmpty)
    }

    @Test func trackingSurvivesClippingResizeAndReuse() {
        let row = MyTasksNativeRowView(frame: NSRect(x: 0, y: 0, width: 1000, height: 36))
        let views = [row] + contentSubviews(of: row).filter {
            $0 is MyTasksMediaButton || $0 is MyTasksDoneCircle
        }
        for view in views {
            view.updateTrackingAreas()
            let original = view.trackingAreas.filter { $0.options.contains(.inVisibleRect) }
            #expect(!original.isEmpty)
            for n in 0..<100 {
                view.setFrameOrigin(NSPoint(x: n % 3, y: n))
                view.updateTrackingAreas()
            }
            view.setFrameSize(NSSize(width: view.frame.width + 20, height: 36))
            view.prepareForReuse()
            view.updateTrackingAreas()
            let current = view.trackingAreas.filter { $0.options.contains(.inVisibleRect) }
            #expect(current.count == original.count)
            #expect(zip(current, original).allSatisfy { $0 === $1 })
        }
    }

    @Test func repeatedLayoutDoesNotTemporarilyResizeText() {
        let row = MyTasksNativeRowView(frame: NSRect(x: 0, y: 0, width: 1000, height: 36))
        let fields = contentSubviews(of: row).compactMap { $0 as? NSTextField }
        for field in fields { field.stringValue = "Long text with emoji 👀 and a date" }
        row.layout()
        let frames = fields.map(\.frame)
        @MainActor final class Changes { var count = 0 }
        // Notifications are synchronous on the main thread in this test.
        let changes = Changes()
        let observers = fields.map { field in
            field.postsFrameChangedNotifications = true
            return NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: field, queue: nil
            ) { _ in MainActor.assumeIsolated { changes.count += 1 } }
        }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        for _ in 0..<100 { row.layout() }
        #expect(fields.map(\.frame) == frames)
        #expect(changes.count == 0)
    }

    @Test func identicalBindingIsANoOpAndReuseReplacesContent() {
        ApolloRuntimeEnvironment.activateStudio()
        let state = AppState(previewMode: true)
        let tasks = ApolloBoardFixtureGenerator.tasks(count: 2)
        let row = MyTasksNativeRowView(frame: NSRect(x: 0, y: 0, width: 1000, height: 36))
        row.bind(task: tasks[0], appState: state)
        row.layoutSubtreeIfNeeded()
        row.needsLayout = false
        for _ in 0..<100 { row.bind(task: tasks[0], appState: state) }
        #expect(!row.needsLayout)
        row.prepareForReuse()
        row.bind(task: tasks[1], appState: state)
        let strings = contentSubviews(of: row).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(strings.contains(tasks[1].title))
        row.prepareForReuse()
    }

    @Test func textGeometryMatchesOriginalSizeToFit() {
        ApolloRuntimeEnvironment.activateStudio()
        let state = AppState(previewMode: true)
        for task in ApolloBoardFixtureGenerator.tasks(count: 20) {
            let row = MyTasksNativeRowView(frame: NSRect(x: 0, y: 0, width: 1000, height: 36))
            row.bind(task: task, appState: state)
            row.layout()
            for field in contentSubviews(of: row).compactMap({ $0 as? NSTextField }).prefix(4) {
                let reference = NSTextField()
                reference.cell = field.cell?.copy() as? NSCell
                reference.sizeToFit()
                #expect(field.frame.height == reference.frame.height)
                #expect(field.frame.midY == 18)
            }
            row.prepareForReuse()
        }
    }
    @Test func statusArtworkIsReusedAndInvalidatedByVisualChanges() throws {
        let control = MyTasksDoneCircle(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        control.appearance = NSAppearance(named: .aqua)
        control.bind(statusColor: .systemOrange, completed: false)
        control.updateLayer()
        let first = try #require(control.layer?.contents as AnyObject?)
        for _ in 0..<100 {
            control.bind(statusColor: .systemOrange, completed: false)
            control.updateLayer()
            #expect((control.layer?.contents as AnyObject?) === first)
        }
        control.bind(statusColor: .systemOrange, completed: true)
        control.updateLayer()
        let completed = try #require(control.layer?.contents as AnyObject?)
        #expect(completed !== first)
        control.appearance = NSAppearance(named: .darkAqua)
        control.viewDidChangeEffectiveAppearance()
        control.updateLayer()
        #expect((control.layer?.contents as AnyObject?) !== completed)
        var activated = false
        control.bind(statusColor: .systemOrange, completed: false)
        control.onActivate = { activated = true }
        control.performClick(nil)
        #expect(activated)
    }

    @Test func rowKeepsNativeControlsInSingleContentBackingStore() {
        let row = MyTasksNativeRowView(frame: NSRect(x: 0, y: 0, width: 1000, height: 36))
        row.layoutSubtreeIfNeeded()
        let content = row.subviews.first(where: \.canDrawSubviewsIntoLayer)
        #expect(content != nil)
        #expect(content?.frame == row.bounds)
        let children = contentSubviews(of: row)
        #expect(children.filter { $0 is NSTextField }.count == 5)
        #expect(children.filter { $0 is NSButton }.count == 3)
        #expect(children.filter { $0 is MyTasksDoneCircle }.count == 1)
    }

    @Test func flatteningPreservesRenderedRowPixels() throws {
        ApolloRuntimeEnvironment.activateStudio()
        let state = AppState(previewMode: true)
        let task = ApolloBoardFixtureGenerator.tasks(count: 1)[0]
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 36),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let row = MyTasksNativeRowView(frame: NSRect(x: 0, y: 0, width: 1000, height: 36))
        window.contentView = row
        row.bind(task: task, appState: state)
        let candidate = row.subviews.first { $0.canDrawSubviewsIntoLayer }
        let content = try #require(candidate)
        func pixels() throws -> Data {
            row.layoutSubtreeIfNeeded()
            let rep = try #require(row.bitmapImageRepForCachingDisplay(in: row.bounds))
            row.cacheDisplay(in: row.bounds, to: rep)
            let bytes = try #require(rep.bitmapData)
            return Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            content.canDrawSubviewsIntoLayer = false
            let separate = try pixels()
            content.canDrawSubviewsIntoLayer = true
            let combined = try pixels()
            #expect(separate.contains(where: { $0 > 0 }))
            #expect(separate == combined)
        }
        row.prepareForReuse()
    }

}
