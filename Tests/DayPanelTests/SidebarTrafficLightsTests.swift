import AppKit
import XCTest
@testable import ApolloRuntime

final class SidebarTrafficLightsTests: XCTestCase {
    @MainActor
    func testNativeButtonsKeepGeometryActionsAndHitTargetsAfterAlignmentAndResize() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27,
                          "The sidebar inset applies only to macOS 27")
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable,
                                          .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = try kinds.map { try XCTUnwrap(window.standardWindowButton($0)) }
        let originalSizes = buttons.map(\.frame.size)
        let originalActions = buttons.map(\.action)
        let originalTargets = buttons.map { $0.target }
        let originalSpacing = zip(buttons, buttons.dropFirst()).map {
            $1.convert($1.bounds, to: nil).minX - $0.convert($0.bounds, to: nil).minX
        }

        // Exercise the resize/re-key alignment path repeatedly, without
        // replacing controls or taking ownership of their native actions.
        for width: CGFloat in [1060, 1340, 1060, 1060] {
            window.setContentSize(NSSize(width: width, height: 720))
            SidebarTrafficLights.align(in: window)
            let content = try XCTUnwrap(window.contentView)
            let contentFrame = content.convert(content.bounds, to: nil)
            for (index, button) in buttons.enumerated() {
                XCTAssertTrue(button === window.standardWindowButton(kinds[index]))
                XCTAssertEqual(button.frame.size, originalSizes[index])
                XCTAssertEqual(button.action, originalActions[index])
                XCTAssertTrue(button.target === originalTargets[index])
                let parent = try XCTUnwrap(button.superview)
                let center = NSPoint(x: button.frame.midX, y: button.frame.midY)
                let hit = parent.hitTest(center)
                XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true)
            }
            let first = buttons[0]
            let frame = first.convert(first.bounds, to: nil)
            let insets = first.alignmentRectInsets
            let diameter = first.bounds.height - insets.top - insets.bottom
            let visibleX = frame.minX + max(0, (first.bounds.width - diameter) / 2)
            XCTAssertEqual(visibleX - contentFrame.minX, 30, accuracy: 0.01)
            XCTAssertEqual(contentFrame.maxY - (frame.maxY - insets.top), 30, accuracy: 0.01)
            for index in 0..<2 {
                let spacing = buttons[index + 1].convert(buttons[index + 1].bounds, to: nil).minX
                    - buttons[index].convert(buttons[index].bounds, to: nil).minX
                XCTAssertEqual(spacing, originalSpacing[index], accuracy: 0.01)
            }
        }
    }
}
