import Foundation
import Combine
import AppKit
import UserNotifications
import Sparkle

/// Bridges Sparkle's `SPUUpdater` into the rest of Apollo:
///
/// - publishes `availableUpdate` so SwiftUI views (the persistent
///   banner) can react when there's a new version waiting,
/// - fires a one-shot native notification via UNUserNotificationCenter
///   the first time Sparkle discovers each version,
/// - pushes a row into AppState's persistent in-app notification log
///   (bell icon popover) so the user has a trail even after dismissing
///   the banner,
/// - exposes thin helpers (`presentUpdateUI()`, `dismissBanner()`,
///   `checkSilently()`) for buttons in the UI.
///
/// The standard Sparkle modal continues to work for the explicit
/// "Verificar Atualizações…" menu item — we do NOT swap in a custom
/// `SPUUserDriver`. The banner is additive: it stays visible after
/// the user clicks "Remind Me Later" on the Sparkle dialog and is
/// dismissed only by installing the update, skipping it, or clicking
/// the X.
///
/// Not annotated `@MainActor` so the AppDelegate's `lazy var` can
/// build it in a synchronous nonisolated context. The `@Published`
/// mutations and any UI-adjacent work explicitly hop to main via
/// `MainActor.run` / `Task { @MainActor in }` below.
final class UpdateService: NSObject, ObservableObject {

    // MARK: - Published state

    /// Currently-pending update, or `nil` when the app is up to
    /// date. The banner observes this; setting it back to `nil`
    /// hides the banner.
    @Published private(set) var availableUpdate: AvailableUpdate?

    /// Wall-clock time of the most recent successful Sparkle
    /// check (either "found update" or "no update available").
    /// Surfaced in Settings → About so the user can tell at a
    /// glance that the auto-check is actually running.
    @Published private(set) var lastCheckedAt: Date?

    // MARK: - Wiring

    /// Held weakly because the controller owns *us* (we're its
    /// `updaterDelegate`) — making this strong would cause a
    /// retain cycle. Set immediately after init in AppDelegate.
    weak var updaterController: SPUStandardUpdaterController?

    /// Used to push an entry into the in-app notification log.
    /// Weak — AppState owns the rest of the dependency graph
    /// and outlives us.
    weak var appState: AppState?

    /// Versions for which a native notification has already
    /// been sent in this launch. Prevents the banner from
    /// being announced twice if Sparkle re-checks while the
    /// update is still pending.
    private var notifiedVersions = Set<String>()

    /// Persistent notification ID — replacing an existing
    /// banner instead of stacking duplicates each check.
    private let nativeNotifIdentifier = "com.painellunar.app.update-available"

    // MARK: - Public actions

    /// Run a silent background check (no UI shown if nothing's
    /// available). Triggered by the explicit "Verificar agora"
    /// button in About / Settings; also re-runs at app launch
    /// even when the scheduled timer hasn't fired yet.
    @MainActor
    func checkSilently() {
        updaterController?.updater.checkForUpdatesInBackground()
    }

    /// Open Sparkle's standard "found update / install" dialog,
    /// same path as the menu item. The banner's "Atualizar agora"
    /// button calls this so the user can review release notes
    /// before committing.
    @MainActor
    func presentUpdateUI() {
        updaterController?.checkForUpdates(nil)
    }

    /// Manual dismiss from the banner X. Hides the banner for
    /// this session only — Sparkle's next scheduled check will
    /// re-publish if the version is still pending.
    @MainActor
    func dismissBanner() {
        availableUpdate = nil
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdateService: SPUUpdaterDelegate {

    /// Channels Apollo subscribes to. Empty string is the
    /// default "everyone gets this" stream. `"silent"` is
    /// Apollo-specific: items tagged
    /// `<sparkle:channel>silent</sparkle:channel>` in the
    /// appcast are still DISCOVERED by the updater (so a
    /// manual `⌘ → Verificar Atualizações…` finds them and
    /// can install them) — but the `SPUStandardUserDriver`
    /// delegate below refuses to show the scheduled-check
    /// banner for them. Net effect: dev can ship a release
    /// that's available on demand but doesn't spam every
    /// running install with a notification.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        ["", "silent"]
    }

    /// Sparkle calls this on whatever thread it parsed the
    /// appcast on. We hop to main to mutate `@Published`
    /// properties and touch UI-adjacent APIs.
    nonisolated func updater(_ updater: SPUUpdater,
                             didFindValidUpdate item: SUAppcastItem) {
        let version  = item.displayVersionString
        let build    = item.versionString
        let notesURL = item.releaseNotesURL
        let pubDate  = item.date
        // Items in the `silent` channel are discovered AND
        // installable via the menu, but we suppress every
        // in-app announcement surface (persistent banner,
        // system notification, in-app notification center).
        // The user only encounters the update by explicitly
        // clicking `⌘ → Verificar Atualizações…`.
        let isSilent = item.channel == "silent"
        Task { @MainActor in
            let info = AvailableUpdate(
                version: version,
                buildVersion: build,
                releaseNotesURL: notesURL,
                pubDate: pubDate
            )
            self.lastCheckedAt = Date()
            if isSilent {
                // Don't surface anywhere. `availableUpdate`
                // also stays nil so the persistent banner
                // doesn't appear.
                return
            }
            self.availableUpdate = info

            // Suppress duplicate announcements for the same version
            // within a single launch — Sparkle re-checks at the
            // scheduled interval and the same item shows up each
            // time until installed.
            let key = "\(version)-\(build)"
            if !self.notifiedVersions.contains(key) {
                self.notifiedVersions.insert(key)
                self.postSystemNotification(for: info)
                self.appState?.notify(
                    .info,
                    title: "Apollo \(info.version) disponível",
                    subtitle: "Nova versão pronta pra instalar",
                    message: "Clique em \"Atualizar\" no banner para abrir o instalador."
                )
            }
        }
    }

    /// "Nothing to do" callback. Used to update the last-check
    /// timestamp and to clear a stale banner — e.g. if the user
    /// already installed the update via the Sparkle modal in
    /// another launch, the next background check returns
    /// "no update" and we want the banner gone.
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.lastCheckedAt   = Date()
            self.availableUpdate = nil
        }
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension UpdateService: SPUStandardUserDriverDelegate {

    /// Sparkle calls this on every scheduled (background)
    /// update discovery. Returning `false` tells the standard
    /// user driver NOT to surface the "Apollo X is available"
    /// modal for THIS particular discovery.
    ///
    /// We return false for items in the `silent` channel so
    /// the scheduled check stays quiet. Manual checks via
    /// `⌘ → Verificar Atualizações…` route through a
    /// different code path (the standard user driver doesn't
    /// consult this delegate for user-initiated checks) — so
    /// the user sees the silent release the moment they click
    /// the menu item, but never gets a surprise banner.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        return update.channel != "silent"
    }
}

// MARK: - System notifications

private extension UpdateService {

    /// Post a banner to Notification Center. Authorization was
    /// already requested at app launch (AppDelegate registers the
    /// UN delegate and asks for permission for task reminders);
    /// `.add` is a no-op without permission, so we don't gate.
    func postSystemNotification(for update: AvailableUpdate) {
        let content = UNMutableNotificationContent()
        content.title = "Apollo \(update.version) disponível"
        content.body  = "Toque para abrir o instalador da nova versão."
        content.sound = nil
        content.threadIdentifier = "apollo-updates"
        content.userInfo = [
            "kind":    "update-available",
            "version": update.version,
            "build":   update.buildVersion,
        ]

        let req = UNNotificationRequest(
            identifier: nativeNotifIdentifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req) { error in
            if let error {
                NSLog("[Apollo] update notification failed: %@",
                      error.localizedDescription)
            }
        }
    }
}
