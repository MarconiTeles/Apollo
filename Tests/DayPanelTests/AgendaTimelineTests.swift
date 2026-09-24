import AppKit
import SwiftUI
import Testing
@testable import ApolloRuntime

@Suite(.serialized)
@MainActor
struct AgendaTimelineTests {
    private let calendar = Calendar.current
    private var today: Date { calendar.startOfDay(for: Date()) }
    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: today)!
    }
    private func event(_ index: Int, day offset: Int, calendarID: String = "primary") -> CalendarEvent {
        let start = day(offset).addingTimeInterval(TimeInterval(9 * 3600 + (index % 60) * 60))
        return CalendarEvent(id: "event-\(index)", title: "Reunião de planejamento \(index)",
                             startDate: start, endDate: start.addingTimeInterval(1800),
                             colorHex: "#039BE5", calendarId: calendarID, isAllDay: false)
    }

    @Test func sharedMeetingsRemainDistinctAndEveryDayHasOneDateAnchor() {
        let own = event(0, day: 0)
        let shared = event(0, day: 0, calendarID: "colleague@example.test")
        let rows = AgendaTimelineRow.makeRows(dates: [day(0), day(1)],
                                              eventsByDay: [day(0): [own, shared]])
        #expect(rows.count == 3)
        #expect(Set(rows.map(\.id)).count == 3)
        #expect(rows.filter { $0.id == AnyHashable(day(0)) }.count == 1)
        #expect(rows.filter { $0.id == AnyHashable(day(1)) }.count == 1)
        #expect(rows.compactMap(\.event) == [own, shared])
        #expect(rows.last?.event == nil)
        // Adding another calendar cannot replace the existing first event's
        // day anchor or the shared event's identity.
        let expanded = AgendaTimelineRow.makeRows(dates: [day(0)],
            eventsByDay: [day(0): [own, shared, event(1, day: 0)]])
        #expect(expanded[0].id == rows[0].id)
        #expect(expanded[1].id == rows[1].id)
    }

    @Test func renderedCardsPreserveOriginalPositionsAndEmptyDaySpacing() async throws {
        let state = makeState()
        state.events = [event(0, day: 0), event(1, day: 0), event(2, day: 0),
                        event(3, day: 1), event(4, day: 3), event(5, day: 3)]
        let (window, host) = mount(state)
        defer { window.contentView = nil; window.close() }
        await settle(host)
        let referenceWindow = NSWindow(contentRect: window.frame, styleMask: [.titled], backing: .buffered, defer: false)
        referenceWindow.isReleasedWhenClosed = false
        let referenceHost = NSHostingView(rootView: oldDayGroupedList(state))
        referenceWindow.contentView = referenceHost
        referenceWindow.setContentSize(NSSize(width: 430, height: 800))
        defer { referenceWindow.contentView = nil; referenceWindow.close() }
        await settle(referenceHost)
        try snapshot(host, path: "/tmp/apollo-agenda-current.png")
        try snapshot(referenceHost, path: "/tmp/apollo-agenda-reference.png")
        try assertReferencePixels(viewHeight: host.bounds.height)
        let table = try #require(descendants(host).compactMap { $0 as? NSTableView }.first)
        let referenceTable = try #require(descendants(referenceHost).compactMap { $0 as? NSTableView }.first)
        for (index, shouldClip) in [(1, true), (2, false), (3, false), (4, true), (6, true), (7, false)] {
            let row = try #require(table.rowView(atRow: index, makeIfNecessary: false))
            #expect(row.clipsToBounds == shouldClip)
            #expect(row.layer?.masksToBounds == shouldClip)
        }
        print("AGENDA_TABLE current=\(table.bounds) columns=\(table.tableColumns.map(\.width)) clip=\(String(describing: table.enclosingScrollView?.contentView.bounds)); reference=\(referenceTable.bounds) columns=\(referenceTable.tableColumns.map(\.width)) clip=\(String(describing: referenceTable.enclosingScrollView?.contentView.bounds))")
        let cards = descendants(host).compactMap { $0 as? EventRightClickCatcher.CatcherView }
            .map { $0.convert($0.bounds, to: table) }.sorted { $0.minY < $1.minY }
        let referenceCards = descendants(referenceHost).compactMap { $0 as? EventRightClickCatcher.CatcherView }
            .map { $0.convert($0.bounds, to: referenceTable) }.sorted { $0.minY < $1.minY }
        print("AGENDA_CARDS actual=\(cards) reference=\(referenceCards)")
        print("AGENDA_COLUMNS actualRect=\(table.rect(ofColumn: 0)) refRect=\(referenceTable.rect(ofColumn: 0)) actualStyle=\(table.style.rawValue) refStyle=\(referenceTable.style.rawValue) actualIntercell=\(table.intercellSpacing) refIntercell=\(referenceTable.intercellSpacing) refAuto=\(referenceTable.columnAutoresizingStyle.rawValue) refScroller=\(String(describing: referenceTable.enclosingScrollView?.scrollerStyle.rawValue)) refHasScroller=\(String(describing: referenceTable.enclosingScrollView?.hasVerticalScroller))")
        #expect(cards.count == 6)
        #expect(referenceCards.count == cards.count)
        for (frame, reference) in zip(cards, referenceCards) {
            #expect(abs(frame.minY - reference.minY) < 0.5)
            #expect(abs(frame.height - reference.height) < 0.5)
            #expect(abs(frame.minX - reference.minX) < 0.5)
            #expect(abs(frame.width - reference.width) < 0.5)
        }
        // Unmounted native rows have estimated heights. Compare the visible
        // empty-day row itself, not the provisional full document extent.
        #expect(abs(table.rect(ofRow: 5).height - referenceTable.rect(ofRow: 3).height) < 0.5)
        let scroll = try #require(table.enclosingScrollView)
        // Learn all heights through ordinary scrolling, then compare the full
        // content extent and final day's position with the eager reference.
        for step in 0..<12 {
            let maxY = max(0, table.bounds.height - scroll.contentSize.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(CGFloat(step) * 400, maxY)))
            scroll.reflectScrolledClipView(scroll.contentView)
            await settle(host)
        }
        #expect(abs(table.bounds.height - referenceTable.bounds.height) < 0.5)
        #expect(abs(table.rect(ofRow: table.numberOfRows - 1).minY - referenceTable.rect(ofRow: 31).minY) < 0.5)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle(host)

        state.selectedDate = day(20)
        await settle(host, animation: true)
        let targetRect = table.rect(ofRow: 24) // day 20 after the extra event rows.
        let actualOffset = scroll.contentView.bounds.minY
        print("AGENDA_ANCHOR actual=\(actualOffset) target=\(targetRect) document=\(table.bounds.height) viewport=\(scroll.contentSize.height)")
        #expect(calendar.isDate(state.selectedDate, inSameDayAs: day(20)))
        #expect(abs(actualOffset - targetRect.minY) < 2)
        state.todayJumpToken += 1
        await settle(host, animation: true)
        let resetTable = try #require(descendants(host).compactMap { $0 as? NSTableView }.first)
        let resetScroll = try #require(resetTable.enclosingScrollView)
        #expect(abs(resetScroll.contentView.bounds.minY) < 0.5)
    }

    @Test func oneThousandEventsKeepMountedCardsBounded() async throws {
        let state = makeState()
        state.events = (0..<1_000).map { event($0, day: $0 % 31, calendarID: "calendar-\($0 % 10)") }
        let (window, host) = mount(state)
        defer { window.contentView = nil; window.close() }
        await settle(host)
        let table = try #require(descendants(host).compactMap { $0 as? NSTableView }.first)
        let scroll = try #require(table.enclosingScrollView)
        for fraction in [0.0, 0.5, 1.0, 0.0] {
            let maxY = max(0, table.bounds.height - scroll.contentSize.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: maxY * fraction))
            scroll.reflectScrolledClipView(scroll.contentView)
            await settle(host)
            table.prepareContent(in: table.bounds)
            await settle(host)
            #expect(table.preparedContentRect.height <= scroll.contentSize.height * 3 + 1)
            #expect(table.preparedContentRect.contains(table.visibleRect))
            let mounted = descendants(host).filter { $0 is EventRightClickCatcher.CatcherView }.count
            #expect(mounted > 0)
            #expect(mounted < 100)
        }
    }

    private func makeState() -> AppState {
        ApolloRuntimeEnvironment.activateStudio()
        return AppState.preview()
    }
    /// Frozen pre-fix layout: intentionally day-grouped and eager. Differential
    /// geometry below verifies empty/single/multiple-event days against this
    /// independent reference rather than the new row-height calculation.
    private func oldDayGroupedList(_ state: AppState) -> some View {
        List {
            Color.clear.frame(height: 143).listRowBackground(Color.clear)
                .listRowSeparator(.hidden).listRowInsets(EdgeInsets())
            ForEach((0..<31).map(day), id: \.self) { date in
                HStack(alignment: .top, spacing: 17) {
                    VStack(spacing: 1) {
                        Text(calendar.isDateInToday(date) ? "HOJE" : date.formatted(.dateTime.weekday(.abbreviated)
                            .locale(Locale(identifier: "pt_BR"))).uppercased().replacingOccurrences(of: ".", with: ""))
                            .font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(0.7)
                            .foregroundStyle(calendar.isDateInToday(date) ? Editorial.accent : Editorial.inkMute)
                        Text(date.formatted(.dateTime.day()))
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .foregroundStyle(Editorial.ink).monospacedDigit()
                    }.frame(width: 46, height: 46, alignment: .center).padding(.top, 6)
                    VStack(spacing: 6) {
                        let events = state.mergedEventsByDay[date] ?? []
                        if events.isEmpty {
                            Text("— Sem compromissos").font(Editorial.serif(13.5).italic())
                                .foregroundStyle(Editorial.inkMute)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                        } else {
                            ForEach(events, id: \.calendarIdentity) { event in
                                AgendaEventCard(event: event, onTap: { _ in }).equatable()
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 22)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
            }
        }.listStyle(.plain).scrollContentBackground(.hidden).scrollIndicators(.hidden)
            .contentMargins(.bottom, 60, for: .scrollContent)
    }
    private func mount(_ state: AppState) -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 430, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ApolloRuntime.TimelineView(forwardOnly: true, topContentInset: 100)
            .environmentObject(state))
        window.contentView = host
        return (window, host)
    }
    private func settle(_ host: NSView, animation: Bool = false) async {
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        if animation { try? await Task.sleep(nanoseconds: 500_000_000) }
        host.layoutSubtreeIfNeeded()
    }
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
    private func snapshot(_ host: NSView, path: String) throws {
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    private func assertReferencePixels(viewHeight: CGFloat) throws {
        func image(_ name: String) throws -> NSBitmapImageRep {
            let data = try Data(contentsOf: URL(fileURLWithPath: "/tmp/apollo-agenda-\(name).png"))
            return try #require(NSBitmapImageRep(data: data))
        }
        let current = try image("current"), reference = try image("reference")
        try #require(current.pixelsWide == reference.pixelsWide && current.pixelsHigh == reference.pixelsHigh)
        try #require(current.bitsPerPixel == 32 && reference.bitsPerPixel == 32)
        let actual = try #require(current.bitmapData), expected = try #require(reference.bitmapData)
        // The lower floating controls/fade are outside this frozen layout
        // reference. Tolerate tiny compositing-rounding differences above them.
        let height = min(current.pixelsHigh, Int(650 * CGFloat(current.pixelsHigh) / viewHeight))
        var differentPixels = 0, maximumDifference = 0
        for y in 0..<height {
            for x in 0..<current.pixelsWide {
                var difference = 0
                for channel in 0..<4 {
                    difference = max(difference, abs(Int(actual[y * current.bytesPerRow + x * 4 + channel])
                        - Int(expected[y * reference.bytesPerRow + x * 4 + channel])))
                }
                maximumDifference = max(maximumDifference, difference)
                if difference > 2 { differentPixels += 1 }
            }
        }
        print("AGENDA_PIXEL_PARITY pixelsOverTolerance=\(differentPixels) maxChannelDifference=\(maximumDifference)")
        #expect(differentPixels <= 200,
                "Agenda diverged from the original layout in \(differentPixels) pixels above 650pt (channel tolerance 2, limit 200; max difference \(maximumDifference)). Inspect /tmp/apollo-agenda-current.png and /tmp/apollo-agenda-reference.png for clipped shadows or shifted content.")
    }
}
