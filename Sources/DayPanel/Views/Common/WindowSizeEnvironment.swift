import SwiftUI

// Propagates the host window's size down the SwiftUI tree so popups
// (which can't easily measure the window themselves) can cap their
// height to a percentage of it.

private struct WindowSizeKey: EnvironmentKey {
    static let defaultValue: CGSize = .zero
}

extension EnvironmentValues {
    var windowSize: CGSize {
        get { self[WindowSizeKey.self] }
        set { self[WindowSizeKey.self] = newValue }
    }
}
