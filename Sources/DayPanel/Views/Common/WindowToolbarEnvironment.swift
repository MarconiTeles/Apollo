import SwiftUI

extension EnvironmentValues {
    /// Set by the main window only: its NSHostingController bridges SwiftUI
    /// toolbars (`sceneBridgingOptions = [.toolbars]`), so ContentView puts
    /// its controls on the native NSWindow toolbar. Other hosts (menu-bar
    /// popover, previews, Studio) keep the in-view toolbar.
    @Entry var apolloUsesWindowToolbar: Bool = false
}
