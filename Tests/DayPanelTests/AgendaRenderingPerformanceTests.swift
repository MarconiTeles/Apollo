import AppKit
import SwiftUI
import Testing
@testable import ApolloRuntime

/// Offline, opt-in layout benchmark. Run with APOLLO_AGENDA_BENCHMARK=1 and
/// `swift test --filter AgendaRenderingPerformanceTests` (prefer -c release).
/// These numbers measure CPU layout, not display FPS or GPU presentation.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["APOLLO_AGENDA_BENCHMARK"] == "1"))
@MainActor
struct AgendaRenderingPerformanceTests {
    @Test(arguments: [100, 1_000])
    func renderingCost(eventCount: Int) async throws {
        ApolloRuntimeEnvironment.activateStudio()
        let state = AppState.preview()
        let today = Calendar.current.startOfDay(for: Date())
        func fixture(duplicates: Bool = false) -> [CalendarEvent] { (0..<eventCount).map { index in
            let day = Calendar.current.date(byAdding: .day, value: index % 31, to: today)!
            let start = day.addingTimeInterval(TimeInterval(9 * 3600 + (index / 31) * 60))
            let id = duplicates ? "fixture-\(index % 31)-\((index / 31) / 10)" : "fixture-\(index)"
            return CalendarEvent(id: id, title: "Reunião de planejamento \(index)",
                                 startDate: start, endDate: start.addingTimeInterval(1800),
                                 colorHex: "#039BE5", calendarId: "calendar-\((index / 31) % 10)",
                                 isAllDay: false)
        } }
        state.events = fixture()
        try await benchmark("month", count: eventCount, state: state,
                            view: AgendaMonthView(month: .constant(today), topInset: 110)
                                .environmentObject(state))
        try await benchmark("timeline", count: eventCount, state: state,
                            view: ApolloRuntime.TimelineView(forwardOnly: true, topContentInset: 100)
                                .environmentObject(state))
        if eventCount == 1_000, ProcessInfo.processInfo.environment["APOLLO_AGENDA_BENCHMARK_DUPLICATES"] == "1" {
            state.events = fixture(duplicates: true)
            try await benchmark("timeline-duplicate-ids", count: eventCount, state: state,
                                view: ApolloRuntime.TimelineView(forwardOnly: true, topContentInset: 100)
                                    .environmentObject(state))
        }
    }

    private func benchmark<V: View>(_ label: String, count: Int, state: AppState, view: V) async throws {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 430, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let start = CACurrentMediaTime()
        let host = NSHostingView(rootView: view)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        let mount = (CACurrentMediaTime() - start) * 1000
        defer { window.contentView = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        let views = descendants(host)
        let cards = views.compactMap { $0 as? EventRightClickCatcher.CatcherView }
        let cardHeights = Set(cards.map { $0.frame.height }).sorted()
        let table = views.compactMap { $0 as? NSTableView }.first
        let rowHeights = table.map { table in (0..<table.numberOfRows).map { table.rect(ofRow: $0).height } } ?? []
        print("AGENDA_GEOMETRY \(label) N=\(count) mountedCards=\(cards.count) cardHeights=\(cardHeights) rowCount=\(rowHeights.count) firstRowHeights=\(rowHeights.prefix(10))")

        var invalidations: [Double] = []
        for _ in 0..<20 {
            let start = CACurrentMediaTime()
            state.isOnline.toggle()
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            invalidations.append((CACurrentMediaTime() - start) * 1000)
        }
        var resize: [Double] = []
        for index in 0..<20 {
            let start = CACurrentMediaTime()
            window.setContentSize(NSSize(width: 430 + index % 2, height: 800))
            host.layoutSubtreeIfNeeded()
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            resize.append((CACurrentMediaTime() - start) * 1000)
        }
        let scroll = try #require(firstScrollView(in: host))
        let document = try #require(scroll.documentView)
        var scrolling: [Double] = []
        for index in 0..<60 {
            let maxY = max(0, document.bounds.height - scroll.contentSize.height)
            let fraction = CGFloat(index < 30 ? index : 59 - index) / 29
            let start = CACurrentMediaTime()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: fraction * maxY))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            scrolling.append((CACurrentMediaTime() - start) * 1000)
        }
        var localScrolling: [Double] = []
        for index in 0..<120 {
            let maxY = max(0, document.bounds.height - scroll.contentSize.height)
            let y = min(maxY, CGFloat(index < 60 ? index : 119 - index) * 80)
            let start = CACurrentMediaTime()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            localScrolling.append((CACurrentMediaTime() - start) * 1000)
        }
        #expect(host.bounds.width > 0)
        #expect(document.bounds.height > 0)
        func stats(_ values: [Double]) -> String {
            let ordered = values.sorted()
            return String(format: "mean=%.2f p95=%.2f max=%.2f", values.reduce(0, +) / Double(values.count),
                          ordered[Int(Double(ordered.count - 1) * 0.95)], ordered.last!)
        }
        print("AGENDA_BENCH \(label) N=\(count) mount=\(String(format: "%.2f", mount))ms invalidation[\(stats(invalidations))] resize[\(stats(resize))] scroll[\(stats(scrolling))] scroll80pt[\(stats(localScrolling))] documentHeight=\(document.bounds.height)")
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { firstScrollView(in: $0) }.first
    }
}
