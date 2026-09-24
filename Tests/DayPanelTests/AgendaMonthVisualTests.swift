import AppKit
import SwiftUI
import Testing
@testable import ApolloRuntime

@Suite(.serialized)
@MainActor
struct AgendaMonthVisualTests {
    @Test(arguments: [430, 600, 850], [false, true])
    func matchesFrozenReference(width: Int, dark: Bool) async throws {
        ApolloRuntimeEnvironment.activateStudio()
        let state = AppState.preview()
        let today = Calendar.current.startOfDay(for: Date())
        let month = AgendaMonth(containing: today)
        state.events = (0..<100).map { index in
            let day = index < 12 ? today : month.days[index % month.days.count]
            let start = day.addingTimeInterval(TimeInterval((9 + index % 3) * 3600))
            return CalendarEvent(id: "event-\(index / 10)",
                                 title: index == 0 ? "Planejamento de gravação, revisão de roteiro e alinhamento das próximas entregas da equipe" : "Reunião \(index)",
                                 startDate: start, endDate: start.addingTimeInterval(1800),
                                 colorHex: index % 2 == 0 ? "#039BE5" : "#F6BF26",
                                 calendarId: "calendar-\(index % 10)", isAllDay: index == 1)
        }
        let current = try await render(AgendaMonthView(month: .constant(today)).environmentObject(state),
                                       width: width, dark: dark)
        let reference = try await render(AgendaMonthReferenceView(month: .constant(today)).environmentObject(state),
                                         width: width, dark: dark)
        let label = "\(width)-\(dark ? "dark" : "light")"
        try #require(current.pixelsWide == reference.pixelsWide && current.pixelsHigh == reference.pixelsHigh)
        try #require(current.bitsPerPixel == 32 && reference.bitsPerPixel == 32)
        let actual = try #require(current.bitmapData), expected = try #require(reference.bitmapData)
        var different = 0, maximum = 0
        var colors = Set<UInt32>()
        for y in 0..<current.pixelsHigh {
            for x in 0..<current.pixelsWide {
                var delta = 0
                for channel in 0..<4 {
                    delta = max(delta, abs(Int(actual[y * current.bytesPerRow + x * 4 + channel])
                        - Int(expected[y * reference.bytesPerRow + x * 4 + channel])))
                }
                maximum = max(maximum, delta)
                if delta > 2 { different += 1 }
                if colors.count < 100 {
                    let p = y * current.bytesPerRow + x * 4
                    colors.insert(UInt32(actual[p]) << 16 | UInt32(actual[p + 1]) << 8 | UInt32(actual[p + 2]))
                }
            }
        }
        #expect(colors.count >= 100, "Monthly snapshot was blank or did not render its content")
        if different > 200 {
            for (name, bitmap) in [("current", current), ("reference", reference)] {
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: "/tmp/apollo-month-\(label)-\(name).png"))
            }
        }
        print("MONTH_PIXEL_PARITY \(label) pixelsOverTolerance=\(different) maxChannelDifference=\(maximum)")
        #expect(different <= 200, "Monthly layout changed in \(different) pixels for \(label) (tolerance 2, max \(maximum)); inspect /tmp/apollo-month-\(label)-{current,reference}.png")
    }

    private func render<V: View>(_ view: V, width: Int, dark: Bool) async throws -> NSBitmapImageRep {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }
}
