import AppKit
import SwiftUI
import Testing
@testable import ApolloRuntime

@Suite(.serialized)
@MainActor
struct MyTasksScrollTests {
    @Test func nativeScrollPreparesUpcomingContent() throws {
        ApolloRuntimeEnvironment.activateStudio()
        let state = AppState(previewMode: true)
        let list = MyTasksAppKitList(
            sections: [.init(status: ApolloPreviewFixtures.statuses[0],
                             tasks: ApolloBoardFixtureGenerator.tasks(count: 1_000),
                             collapsed: false)],
            selectedTaskIds: [], appState: state,
            onActivate: { _, _, _ in }, onToggleStatus: { _ in },
            onBeginDrag: { [$0.id] }, onEndDrag: { _ in }, onClearSelection: {},
            onMediaAction: { _, _ in }, onBulkMediaAction: {}, onFileDrop: { _, _ in })
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1200, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: list)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> MyTasksViewport? {
            (view as? MyTasksViewport) ?? view.subviews.lazy.compactMap(find).first
        }
        let document = try #require(find(host))
        let scroll = try #require(document.enclosingScrollView)
        #expect(type(of: scroll).isCompatibleWithResponsiveScrolling)
        #expect(type(of: scroll.contentView).isCompatibleWithResponsiveScrolling)
        #expect(type(of: document).isCompatibleWithResponsiveScrolling)

        let visible = scroll.contentView.bounds
        let requested = visible.insetBy(dx: 0, dy: -visible.height)
        document.prepareContent(in: requested)
        let mounted = document.indexPathsForVisibleItems()
        let upcoming = (0..<document.rowCount).filter {
            guard let frame = document.frameForRow(at: $0) else { return false }
            return frame.intersects(requested)
        }
        #expect(upcoming.allSatisfy { mounted.contains(IndexPath(item: $0, section: 0)) },
                "AppKit must receive populated upcoming rows before it scrolls them onscreen")
        #expect(mounted.count < 100, "Preparation remains bounded by the requested area")
        let binds = document.bindCount
        let reconciliations = document.reconciliationCount
        document.prepareContent(in: requested)
        #expect(document.bindCount == binds, "Preparing the same area must not rebind rows")
        #expect(scroll.contentView.bounds == visible, "Preparation must not move the viewport")
        for _ in 0..<20 {
            document.layout()
            #expect(upcoming.allSatisfy {
                document.indexPathsForVisibleItems().contains(IndexPath(item: $0, section: 0))
            }, "Ordinary layout must retain the content AppKit has already prepared")
            document.prepareContent(in: requested)
        }
        #expect(document.reconciliationCount == reconciliations,
                "An unchanged prepared range must bypass native hierarchy reconciliation")
        print("TASKS_PREPARED_REBINDS=\(document.bindCount - binds)")
        #expect(document.bindCount == binds,
                "Alternating preparation and layout must not recycle and rebuild the same rows")

        // AppKit can request increasingly large overdraw at rest or after a
        // fast fling. Honour its contract by announcing a bounded prepared
        // region, rather than materializing thousands of offscreen controls.
        // A clip-view move can outlast live-scroll event flags. Background
        // preparation must wait for actual movement to settle as well.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1))
        #expect(!document.prepareOneReusableRowIfIdle())
        while document.prepareOneReusableRowIfIdle(at: .greatestFiniteMagnitude) {}
        let preparedItems = document.createdItemCount
        var maximumMounted = 0
        for y: CGFloat in [0, 10_000, 25_000, 2_000, 0] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            document.prepareContent(in: document.bounds)
            document.layout()
            let paths = document.indexPathsForVisibleItems()
            maximumMounted = max(maximumMounted, paths.count)
            let announced = document.preparedContentRect.intersection(document.bounds)
            #expect(announced.contains(scroll.contentView.bounds.intersection(document.bounds)))
            for index in 0..<document.rowCount {
                if let frame = document.frameForRow(at: index), frame.intersects(announced) {
                    #expect(paths.contains(IndexPath(item: index, section: 0)),
                            "Every row announced to AppKit must remain populated")
                }
            }
            #expect(paths.count < 100, "Long jumps must preserve bounded virtualization")
            #expect(document.createdItemCount == preparedItems,
                    "A prepared reserve must serve long jumps without creating native controls in the gesture")
        }
        #expect(document.createdItemCount < 100)
        print("TASKS_LONG_JUMP_MAX_MOUNTED=\(maximumMounted)")
    }

    @Test func idleReserveCoversJumpFromEmptyGroupsIntoTasks() throws {
        ApolloRuntimeEnvironment.activateStudio()
        let state = AppState(previewMode: true)
        let tasks = ApolloBoardFixtureGenerator.tasks(count: 1_000)
        var sections = (0..<40).map {
            MyTasksAppKitSection(status: CUStatus(status: "Empty \($0)", color: "#777777", type: "open"),
                                 tasks: [], collapsed: false)
        }
        sections.append(.init(status: ApolloPreviewFixtures.statuses[0], tasks: tasks, collapsed: false))
        let list = MyTasksAppKitList(
            sections: sections, selectedTaskIds: [], appState: state,
            onActivate: { _, _, _ in }, onToggleStatus: { _ in },
            onBeginDrag: { [$0.id] }, onEndDrag: { _ in }, onClearSelection: {},
            onMediaAction: { _, _ in }, onBulkMediaAction: {}, onFileDrop: { _, _ in })
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1200, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: list)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> MyTasksViewport? {
            (view as? MyTasksViewport) ?? view.subviews.lazy.compactMap(find).first
        }
        let document = try #require(find(host))
        let scroll = try #require(document.enclosingScrollView)
        #expect(document.subviews.compactMap { $0 as? MyTasksNativeRowView }.isEmpty)
        let binds = document.bindCount
        while document.prepareOneReusableRowIfIdle() {}
        let reserve = document.subviews.compactMap { $0 as? MyTasksNativeRowView }
        #expect(!reserve.isEmpty && reserve.count < 100)
        #expect(reserve.allSatisfy { $0.isHidden })
        #expect(document.bindCount == binds, "Blank reserve must not bind tasks or start review watches")
        let identities = Set(reserve.map(ObjectIdentifier.init))
        for y: CGFloat in [10_000, 25_000, 0, 10_000] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            document.prepareContent(in: document.bounds)
            host.layoutSubtreeIfNeeded()
            let current = document.subviews.compactMap { $0 as? MyTasksNativeRowView }
            #expect(current.allSatisfy { identities.contains(ObjectIdentifier($0)) },
                    "Sparse-to-dense jumps must reuse the idle reserve without constructing task controls")
        }
        document.detach()
        #expect(document.subviews.isEmpty)
        #expect(!document.prepareOneReusableRowIfIdle())
    }

    @Test func modestListKeepsHierarchyBoundedAfterIdleAndLongJumps() throws {
        ApolloRuntimeEnvironment.activateStudio()
        let state = AppState(previewMode: true)
        var tasks = ApolloBoardFixtureGenerator.tasks(count: 169)
        let status = ApolloPreviewFixtures.statuses[0]
        func list(collapsed: Bool = false) -> MyTasksAppKitList {
            MyTasksAppKitList(
                sections: [.init(status: status, tasks: tasks, collapsed: collapsed)],
                selectedTaskIds: [], appState: state,
                onActivate: { _, _, _ in }, onToggleStatus: { _ in },
                onBeginDrag: { [$0.id] }, onEndDrag: { _ in }, onClearSelection: {},
                onMediaAction: { _, _ in }, onBulkMediaAction: {}, onFileDrop: { _, _ in })
        }
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1200, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        window.contentView = scroll
        let document = MyTasksViewport()
        let coordinator = list().makeCoordinator()
        document.coordinator = coordinator
        coordinator.viewport = document
        scroll.documentView = document
        document.attach(to: scroll)
        defer { document.detach() }
        coordinator.update(parent: list(), force: true)
        let initialBinds = document.bindCount
        while document.prepareOneReusableRowIfIdle() {}
        print("TASKS_MODEST_IDLE mounted=\(document.indexPathsForVisibleItems().count) subviews=\(document.subviews.count)")
        #expect(document.bindCount == initialBinds, "Idle reserve must not bind offscreen tasks or start their review watchers")
        #expect(document.indexPathsForVisibleItems().count < 100)
        #expect(document.subviews.count < 100)
        let accessible = try #require(document.accessibilityChildren())
        #expect(!accessible.isEmpty && accessible.count < 500,
                "The native AX tree must keep visible controls available")
        let created = document.createdItemCount
        for y: CGFloat in [4_000, 0, 2_000, 5_000, 0, 3_000, 0] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            document.prepareContent(in: document.bounds)
            document.layoutSubtreeIfNeeded()
            #expect(document.indexPathsForVisibleItems().count < 100)
            #expect(document.subviews.count < 100)
            #expect(document.createdItemCount == created)
        }
        #expect(document.subviews.compactMap { $0 as? MyTasksNativeRowView }
            .allSatisfy { $0.mediaSubscriptionCount <= 1 },
                "Recycling must reuse subscriptions instead of allocating new observer chains per task")
        // An offscreen update must appear when its row enters the viewport.
        tasks[tasks.count - 1].title = "Changed while offscreen"
        coordinator.update(parent: list())
        let lastFrame = try #require(document.frameForRow(at: tasks.count))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, lastFrame.maxY - scroll.contentView.bounds.height)))
        document.layoutSubtreeIfNeeded()
        let row = try #require(document.subviews.compactMap { $0 as? MyTasksNativeRowView }
            .first { $0.frame == lastFrame })
        let visibleTitles = contentSubviews(of: row).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(visibleTitles.contains("Changed while offscreen"))
        scroll.setFrameSize(NSSize(width: 1000, height: 800))
        scroll.layoutSubtreeIfNeeded()
        document.layout()
        document.layoutSubtreeIfNeeded()
        #expect(row.frame.width == scroll.contentView.bounds.width)
        coordinator.update(parent: list(collapsed: true))
        #expect(document.subviews.filter { !$0.isHidden }.count == 1)
        // Growing the list must preserve bounded virtualization.
        tasks = ApolloBoardFixtureGenerator.tasks(count: 1_000)
        coordinator.update(parent: list())
        #expect(document.indexPathsForVisibleItems().count < 100)
        #expect(document.subviews.count < 150)
    }

    private func contentSubviews(of row: MyTasksNativeRowView) -> [NSView] {
        (row.subviews.first(where: \.canDrawSubviewsIntoLayer) ?? row).subviews
    }

    @Test func headerRejectsCoveredContentInteraction() throws {
        let state = AppState(previewMode: true)
        let tasks = ApolloBoardFixtureGenerator.tasks(count: 30)
        let list = MyTasksAppKitList(
            sections: [.init(status: ApolloPreviewFixtures.statuses[0], tasks: tasks, collapsed: false)],
            selectedTaskIds: [], appState: state, headerOcclusionHeight: 82,
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
        let document = try #require(findViewport(host))
        let scroll = try #require(document.enclosingScrollView)
        let covered = NSPoint(x: 350, y: scroll.isFlipped ? 40 : scroll.bounds.height - 40)
        let exposed = NSPoint(x: 350, y: scroll.isFlipped ? 160 : scroll.bounds.height - 160)
        #expect(scroll.hitTest(scroll.convert(covered, to: scroll.superview)) == nil)
        #expect(scroll.hitTest(scroll.convert(exposed, to: scroll.superview)) != nil)
        #expect(document.isBehindPageHeader(windowPoint: scroll.convert(covered, to: nil)))
        #expect(!document.isBehindPageHeader(windowPoint: scroll.convert(exposed, to: nil)))
        window.contentView = nil
        window.close()
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
            if step.isMultiple(of: 10) {
                let visibleRows = collection.subviews.compactMap { $0 as? MyTasksNativeRowView }
                    .filter { !$0.isHidden }
                for path in collection.indexPathsForVisibleItems() where path.item > 0 {
                    let frame = try #require(collection.frameForRow(at: path.item))
                    let row = try #require(visibleRows.first { $0.frame == frame })
                    let title = try #require(contentSubviews(of: row).compactMap { $0 as? NSTextField }.first)
                    #expect(title.stringValue == tasks[path.item - 1].title,
                            "Deferred layout must display the destination task, not recycled content")
                    #expect(title.frame.height > 0 && title.frame.midY == row.bounds.midY)
                    #expect(contentSubviews(of: row).compactMap { $0 as? NSButton }
                        .filter { !$0.isHidden }.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 })
                }
            }
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

    @Test func scrollingSuppressesCapsuleHoverBeforeCallbacks() async throws {
        let button = MyTasksMediaButton(frame: NSRect(x: 0, y: 0, width: 100, height: 26))
        var callbacks: [Bool] = []
        button.onHover = { callbacks.append($0) }
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        button.mouseEntered(with: event)
        button.mouseExited(with: event)
        #expect(callbacks == [true, false], "Normal pointer feedback must stay intact")
        callbacks.removeAll()
        _ = ScrollStateObserver.shared
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: nil)
        for _ in 0..<100 {
            button.mouseEntered(with: event)
            button.mouseExited(with: event)
        }
        #expect(callbacks.isEmpty, "Scroll-generated tracking events must not animate capsule layers or rewrite titles")
        #expect(!button.isPointerInside)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: nil)
        try await Task.sleep(for: .milliseconds(250))
        button.mouseEntered(with: event)
        button.mouseExited(with: event)
        #expect(callbacks.suffix(2) == [true, false])
        callbacks.removeAll()
        // The final clip animation can still move after both global gates
        // are inactive. Tracking must remain quiet until that movement ends.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let document = MyTasksViewport()
        scroll.documentView = document
        document.attach(to: scroll)
        defer { document.detach() }
        document.addSubview(button)
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 1))
        #expect(document.isScrollMotionActive)
        button.mouseEntered(with: event)
        button.mouseExited(with: event)
        #expect(callbacks.isEmpty, "Momentum tail must suppress hover even after live-scroll end")
        try await Task.sleep(for: .milliseconds(400))
        button.mouseEntered(with: event)
        button.mouseExited(with: event)
        #expect(callbacks == [true, false], "Real pointer feedback must resume after the clip settles")
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

    @Test func unrelatedMediaPublicationsDoNotRelayoutTaskRows() async throws {
        ApolloRuntimeEnvironment.activateStudio()
        let state = AppState(previewMode: true)
        let tasks = ApolloBoardFixtureGenerator.tasks(count: 20)
        let rows = tasks.map { task in
            let row = MyTasksNativeRowView(frame: NSRect(x: 0, y: 0, width: 1000, height: 36))
            row.bind(task: task, appState: state)
            return row
        }
        defer { rows.forEach { $0.prepareForReuse() } }
        // Drain the initial published popup/media state before checking a
        // background update unrelated to any of these visible tasks.
        try await Task.sleep(for: .milliseconds(100))
        for row in rows { row.layoutSubtreeIfNeeded(); row.needsLayout = false }
        for _ in 0..<100 { state.taskMediaTransfers.discard(taskId: "unrelated-missing-task") }
        try await Task.sleep(for: .milliseconds(100))
        let dirtied = rows.filter(\.needsLayout).count
        print("TASKS_UNRELATED_MEDIA_DIRTY_ROWS=\(dirtied)")
        #expect(dirtied == 0, "A publication for another task must not rewrite every retained capsule")

        // An invalid fixture replacement exercises a real batch mutation and
        // failure label entirely in the offline Studio runtime, without upload.
        await state.taskMediaTransfers.prepareReplacement(
            task: tasks[0], assetId: UUID(),
            replacementURL: URL(fileURLWithPath: "/tmp/apollo-nonexistent-fixture.mov"),
            appState: state)
        try await Task.sleep(for: .milliseconds(100))
        #expect(state.taskMediaTransfers.phase(for: tasks[0].id) == .failed)
        #expect(rows[0].needsLayout, "The affected row must still receive a real transfer update")
        #expect(rows.dropFirst().allSatisfy { !$0.needsLayout })
        func label(_ row: MyTasksNativeRowView) -> String? {
            contentSubviews(of: row).compactMap { $0 as? MyTasksMediaButton }
                .first { !$0.isHidden }?.title
        }
        #expect(label(rows[0]) == "REPETIR")
        rows[0].prepareForReuse()
        rows[0].bind(task: tasks[1], appState: state)
        rows[0].layoutSubtreeIfNeeded()
        rows[0].needsLayout = false
        state.taskMediaTransfers.discard(taskId: tasks[0].id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!rows[0].needsLayout, "A reused row must stop observing its former task")
        #expect(label(rows[0]) == "ANEXAR")
        #expect(rows[0].mediaSubscriptionCount == 1)
        await state.taskMediaTransfers.prepareReplacement(
            task: tasks[1], assetId: UUID(),
            replacementURL: URL(fileURLWithPath: "/tmp/apollo-nonexistent-fixture.mov"),
            appState: state)
        try await Task.sleep(for: .milliseconds(100))
        #expect(label(rows[0]) == "REPETIR", "The reused subscription must follow its new task")
        state.taskMediaTransfers.discard(taskId: tasks[1].id)
    }

    @Test func mediaProjectionPreservesEveryPhaseAndComposition() {
        let empty = MyTasksMediaPresentation(batch: nil)
        #expect(empty.label == "ANEXAR" && empty.phase == nil)
        let hook = UUID(), body = UUID()
        let plan = TaskMediaPlan(catalog: .empty(taskId: "projection"), newAssetIds: [],
                                pendingRevisionAssetIds: [], outputs: [
            .init(lineage: .combination(hook: hook, body: body), version: 1, displayFileName: "fixture.mov")
        ])
        for phase: TaskMediaTransferStore.Phase in [.preparing, .ready, .sending, .partialFailure, .sent, .failed] {
            let batch = TaskMediaTransferStore.BatchState(
                id: UUID(), taskId: "projection", phase: phase, plan: plan,
                preparedFiles: [:], published: [:], completed: 2, total: 5,
                progress: 0.4, errorMessage: nil)
            let projected = MyTasksMediaPresentation(batch: batch)
            #expect(projected.phase == phase)
            #expect(projected.composing == (phase == .preparing))
            #expect(projected.label == TaskMediaTransferStore.capsuleLabel(
                phase: phase, completed: 2, total: 5, pending: 3, composing: phase == .preparing))
            #expect(projected.progress == (phase == .preparing || phase == .sending ? 0.4 : 0))
            #expect(projected.badgeCount == (phase == .partialFailure ? 3 : 5))
        }
    }

    @Test func recyclingKeepsUnchangedMediaButtonLayoutClean() throws {
        ApolloRuntimeEnvironment.activateStudio()
        let state = AppState(previewMode: true)
        let tasks = ApolloBoardFixtureGenerator.tasks(count: 2)
        let row = MyTasksNativeRowView(frame: NSRect(x: 0, y: 0, width: 1000, height: 36))
        row.bind(task: tasks[0], appState: state)
        row.layoutSubtreeIfNeeded()
        let button = try #require(contentSubviews(of: row).compactMap { $0 as? MyTasksMediaButton }
            .first { $0.title == "ANEXAR" })
        let title = button.attributedTitle
        button.needsLayout = false
        row.prepareForReuse()
        row.bind(task: tasks[1], appState: state)
        #expect(button.attributedTitle.isEqual(to: title))
        #expect(!button.needsLayout, "Recycling between idle tasks must not invalidate identical button content")
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
