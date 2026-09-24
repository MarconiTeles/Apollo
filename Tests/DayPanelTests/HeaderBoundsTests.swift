import AppKit
import SwiftUI
import Testing
@testable import ApolloRuntime

@Suite(.serialized)
@MainActor
struct HeaderBoundsTests {
    @Test func tracksMaximumAndRemovesDisappearingSources() {
        let store = HeaderBoundsStore()
        let first = UUID(), second = UUID()
        store.update(first, bottom: 90)
        store.update(second, bottom: 140)
        #expect(store.bottom == 140)
        store.update(first, bottom: 110)
        #expect(store.bottom == 140)
        store.update(second, bottom: nil)
        #expect(store.bottom == 110)
        store.update(first, bottom: nil)
        #expect(store.bottom == 52)
    }

    @Test func reportsWindowCoordinatesIncludingMaterialExtension() async throws {
        let store = HeaderBoundsStore()
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = VStack(spacing: 0) {
            Color.clear.frame(height: 30)
            Text("Agenda").frame(height: 70)
                .finderHeaderMaterial(bottomExtension: 8)
            Spacer()
        }.coordinateSpace(name: "appWindow")
            .environment(\.headerBoundsStore, store)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(abs(store.bottom - 108) < 0.01)
    }
}
