import Foundation

/// Snapshot of the pending Sparkle update, surfaced to SwiftUI via
/// `UpdateService.availableUpdate`. We mirror only the fields the
/// in-app banner / system notification actually need; the full
/// `SUAppcastItem` stays inside Sparkle's process so we don't leak
/// Sparkle types into the view layer.
struct AvailableUpdate: Equatable {
    /// `CFBundleShortVersionString` of the available release — e.g.
    /// "1.4.2". This is what users see in copy and dialogs.
    let version: String

    /// `CFBundleVersion` of the available release — e.g. "13". Kept
    /// for "skip this version" comparisons that look at the build
    /// integer rather than the user-facing string.
    let buildVersion: String

    /// Optional URL to the HTML release notes Sparkle pulled from
    /// the appcast `<description>` / `<sparkle:releaseNotesLink>`.
    let releaseNotesURL: URL?

    /// `<pubDate>` value from the appcast item. Used for a tooltip
    /// ("released 2 hours ago") on the banner; nil-safe.
    let pubDate: Date?
}
