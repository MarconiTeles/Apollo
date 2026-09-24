import AppKit
import SwiftUI
import Testing
@testable import ApolloRuntime

/// Diagnostic only: separate event concentration, state invalidation, and width
/// feedback. This measures CPU work, not displayed frames or GPU composition.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["APOLLO_MONTH_DIAGNOSTICS"] == "1"))
@MainActor
struct AgendaMonthRenderingDiagnostics {
    @Test func compareSelectedDayScroll() async throws {
        ApolloRuntimeEnvironment.activateStudio()
        let today = Calendar.current.startOfDay(for: Date())
        for reference in [true, false] {
            let state = AppState.preview()
            state.events = (0..<1_000).map { index in
                CalendarEvent(id: "event-\(index)", title: "Reunião \(index)",
                              startDate: today.addingTimeInterval(32400), endDate: today.addingTimeInterval(34200),
                              colorHex: "#039BE5", calendarId: "calendar-\(index % 10)", isAllDay: false)
            }
            let content = reference
                ? AnyView(AgendaMonthReferenceView(month: .constant(today)))
                : AnyView(AgendaMonthView(month: .constant(today)))
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 800),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: content.environmentObject(state))
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }
                .max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })
            let document = try #require(scroll.documentView)
            print("AGENDA_RESPONSIVE right reference=\(reference) scroll=\(type(of: scroll)) compatible=\(type(of: scroll).isCompatibleWithResponsiveScrolling) document=\(type(of: document)) compatible=\(type(of: document).isCompatibleWithResponsiveScrolling) prepared=\(document.preparedContentRect) visible=\(document.visibleRect)")
            var values: [Double] = []
            for index in 0..<120 {
                let y = min(max(0, document.bounds.height - scroll.contentSize.height),
                            CGFloat(index < 60 ? index : 119 - index) * 80)
                let start = CACurrentMediaTime()
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded()
                await Task.yield()
                host.layoutSubtreeIfNeeded()
                values.append((CACurrentMediaTime() - start) * 1000)
            }
            let nativeViews = descendants(host).count
            if !reference {
                #expect(nativeViews < 100, "Selected-day list retained offscreen event views: \(nativeViews) native views for a small viewport")
            }
            print("MONTH_DAY_SCROLL reference=\(reference) N=1000 scroll80pt[\(stats(values))] nativeViews=\(nativeViews)")
            window.contentView = nil
            window.close()
        }
    }

    @Test func compareWholeAgenda() async throws {
        ApolloRuntimeEnvironment.activateStudio()
        let today = Calendar.current.startOfDay(for: Date())
        for concentrated in [false, true] {
            for monthVisible in [false, true] {
                let state = AppState.preview()
                state.events = (0..<1_000).map { index in
                    let day = Calendar.current.date(byAdding: .day, value: concentrated ? 0 : index % 31, to: today)!
                    let start = day.addingTimeInterval(TimeInterval((9 + index % 3) * 3600))
                    return CalendarEvent(id: "recurrence-\(index / 10)", title: "Reunião de planejamento \(index)",
                                         startDate: start, endDate: start.addingTimeInterval(1800),
                                         colorHex: "#039BE5", calendarId: "calendar-\(index % 10)", isAllDay: false)
                }
                let view = ZStack(alignment: .top) {
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            ApolloRuntime.TimelineView(forwardOnly: true, topContentInset: EditorialHomeHeader.chromeHeight - 18)
                                .frame(width: AgendaLayout.timelineWidth(geometry.size.width))
                            Rectangle().fill(Editorial.rule.opacity(0.65)).frame(width: 1)
                            if monthVisible {
                                AgendaMonthView(month: .constant(today), topInset: EditorialHomeHeader.chromeHeight + 25)
                            } else { Editorial.paper.frame(maxWidth: .infinity) }
                        }
                    }
                    EditorialHomeHeader(month: today).padding(.top, 52).finderHeaderMaterial()
                }.environmentObject(state)
                let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 800),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: view)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                let table = try #require(descendants(host).compactMap { $0 as? NSTableView }.first)
                let scroll = try #require(table.enclosingScrollView)
                print("AGENDA_RESPONSIVE left scroll=\(type(of: scroll).isCompatibleWithResponsiveScrolling) table=\(type(of: table).isCompatibleWithResponsiveScrolling) prepared=\(table.preparedContentRect) visible=\(table.visibleRect)")
                func measure(_ count: Int = 20, update: (Int) -> Void) async -> [Double] {
                    var values: [Double] = []
                    for index in 0..<count {
                        let start = CACurrentMediaTime()
                        update(index)
                        host.layoutSubtreeIfNeeded()
                        await Task.yield()
                        host.layoutSubtreeIfNeeded()
                        values.append((CACurrentMediaTime() - start) * 1000)
                    }
                    return values
                }
                let scrolling = await measure(120) { index in
                    let maxY = max(0, table.bounds.height - scroll.contentSize.height)
                    let y = min(maxY, CGFloat(index < 60 ? index : 119 - index) * 80)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                let invalidation = await measure { _ in state.isOnline.toggle() }
                let width = await measure { window.setContentSize(NSSize(width: 1000 + $0 % 2, height: 800)) }
                print("MONTH_WHOLE N=1000 sameDay=\(concentrated) monthVisible=\(monthVisible) scroll80pt[\(stats(scrolling))] invalidation[\(stats(invalidation))] width1pt[\(stats(width))]")
                window.contentView = nil
                window.close()
            }
        }
    }

    @Test func compareConcentrationAndGeometry() async throws {
        ApolloRuntimeEnvironment.activateStudio()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let month = AgendaMonth(containing: today)
        for (count, concentrated) in [(0, false), (100, false), (100, true), (1_000, false), (1_000, true)] {
            let state = AppState.preview()
            state.events = []
            let events = (0..<count).map { index in
                let day = concentrated ? today : month.monthDays[index % month.monthDays.count]
                let start = day.addingTimeInterval(TimeInterval((9 + index % 3) * 3600))
                return CalendarEvent(id: "recurrence-\(index / 10)", title: "Reunião de planejamento \(index)",
                                     startDate: start, endDate: start.addingTimeInterval(1800),
                                     colorHex: "#039BE5", calendarId: "calendar-\(index % 10)", isAllDay: false)
            }
            state.events = events
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 800),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: AgendaMonthView(month: .constant(today), topInset: 110)
                .environmentObject(state))
            let mounting = CACurrentMediaTime()
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            let mountMS = (CACurrentMediaTime() - mounting) * 1000
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()

            func measure(_ update: (Int) -> Void) async -> [Double] {
                var samples: [Double] = []
                for index in 0..<20 {
                    let start = CACurrentMediaTime()
                    update(index)
                    host.layoutSubtreeIfNeeded()
                    await Task.yield()
                    host.layoutSubtreeIfNeeded()
                    samples.append((CACurrentMediaTime() - start) * 1000)
                }
                return samples
            }
            let steady = await measure { _ in }
            let invalidation = await measure { _ in state.isOnline.toggle() }
            let width = await measure { window.setContentSize(NSSize(width: 600 + $0 % 2, height: 800)) }
            window.setContentSize(NSSize(width: 600, height: 800))
            host.layoutSubtreeIfNeeded()
            let height = await measure { window.setContentSize(NSSize(width: 600, height: 800 + $0 % 2)) }
            print("MONTH_DIAGNOSTIC N=\(count) sameDay=\(concentrated) mount=\(String(format: "%.2f", mountMS))ms steady[\(stats(steady))] invalidation[\(stats(invalidation))] width1pt[\(stats(width))] height1pt[\(stats(height))]")
            window.contentView = nil
            window.close()
        }
    }

    private func stats(_ values: [Double]) -> String {
        let ordered = values.sorted()
        return String(format: "mean=%.2f p95=%.2f max=%.2f", values.reduce(0, +) / Double(values.count),
                      ordered[Int(Double(ordered.count - 1) * 0.95)], ordered.last!)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
