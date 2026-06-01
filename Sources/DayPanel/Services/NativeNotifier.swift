import Foundation
import UserNotifications
import AppKit

// Wrapper around UNUserNotificationCenter so AppState can mirror its
// in-app toasts to the macOS Notification Center when the user opts in
// via Settings. Authorization is requested lazily the first time the
// preference is enabled.

final class NativeNotifier {
    static let shared = NativeNotifier()

    private let center = UNUserNotificationCenter.current()

    /// Honors an explicit user opt-out from Apollo Settings. The
    /// macOS authorization status is the canonical gate, but if the
    /// user disables notifications inside the app we silence
    /// delivery here without touching OS-level permission. Defaults
    /// to the persisted preference (`dp_nativeNotifs == false` →
    /// opted out).
    var userOptedOut: Bool = {
        if let stored = UserDefaults.standard.object(forKey: "dp_nativeNotifs") as? Bool {
            return !stored
        }
        return false
    }()

    /// Userinfo keys used to round-trip the target through macOS so
    /// the AppDelegate's `didReceive` handler can route a click back
    /// into `AppState.openNotificationTarget(...)`.
    enum Key {
        static let appNotifId = "apolloNotifId"
        static let targetKind = "targetKind"   // "task" or "event"
        static let targetId   = "targetId"
    }

    /// Notification categories. Registering them up front lets a
    /// click on the notification show a single primary action ("Abrir
    /// no Apollo") in the macOS Notification Center.
    enum Category {
        static let taskTarget  = "apollo.task"
        static let eventTarget = "apollo.event"
        static let plain       = "apollo.plain"
    }

    init() {
        registerCategories()
    }

    private func registerCategories() {
        let openAction = UNNotificationAction(
            identifier: "apollo.open",
            title:      "Abrir no Apollo",
            options:    [.foreground]
        )
        let markRead = UNNotificationAction(
            identifier: "apollo.markRead",
            title:      "Marcar como lida",
            options:    []
        )
        let taskCategory = UNNotificationCategory(
            identifier:        Category.taskTarget,
            actions:           [openAction, markRead],
            intentIdentifiers: [],
            options:           []
        )
        let eventCategory = UNNotificationCategory(
            identifier:        Category.eventTarget,
            actions:           [openAction, markRead],
            intentIdentifiers: [],
            options:           []
        )
        let plainCategory = UNNotificationCategory(
            identifier:        Category.plain,
            actions:           [markRead],
            intentIdentifiers: [],
            options:           []
        )
        center.setNotificationCategories([taskCategory, eventCategory, plainCategory])
    }

    /// Requests authorization for alerts + sounds. Returns whether the
    /// user granted (or had previously granted) permission.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(
                options: [.alert, .sound, .badge]
            )
        } catch {
            NSLog("[DayPanel] requestAuthorization: %@", "\(error)")
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Posts an immediate native notification. Silently no-ops if the
    /// user hasn't granted permission yet. The optional target lets
    /// the AppDelegate's UNUserNotificationCenterDelegate route a tap
    /// back into the in-app target view (task popup / event detail).
    func send(appNotifId: UUID? = nil,
              kind:       AppNotification.Kind,
              title:      String,
              subtitle:   String?                     = nil,
              body:       String?,
              targetKind: AppNotification.TargetKind? = nil,
              targetId:   String?                     = nil,
              tintHex:    String?                     = nil) {
        Task {
            if self.userOptedOut {
                NSLog("[Apollo] native notification skipped — user opted out")
                return
            }
            let status = await self.authorizationStatus()
            guard status == .authorized || status == .provisional else {
                NSLog("[Apollo] native notification skipped — auth status %d", status.rawValue)
                return
            }
            NSLog("[Apollo] native notification posting: %@", title)

            let content = UNMutableNotificationContent()
            content.title = title
            if let subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
            if let body, !body.isEmpty { content.body = body }
            // Treat every Apollo banner as priority: always play the
            // default sound (so the user looks up from another app),
            // request `.timeSensitive` so the banner pierces Focus
            // modes when the user has granted that permission, and
            // pin `relevanceScore` to 1.0 so it surfaces at the top
            // of the macOS notification summary instead of being
            // collapsed into "Other notifications".
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 1.0

            // Carry the in-app id + target so a click can be routed
            // to the right popup. AppDelegate reads these out of
            // `notification.request.content.userInfo`.
            var info: [String: Any] = [:]
            if let appNotifId { info[Key.appNotifId] = appNotifId.uuidString }
            switch targetKind {
            case .task:
                info[Key.targetKind] = "task"
                content.categoryIdentifier = Category.taskTarget
            case .event:
                info[Key.targetKind] = "event"
                content.categoryIdentifier = Category.eventTarget
            case .review:
                // Reuse the task category so the banner shows "Abrir no Apollo";
                // the tap routes via targetKind="review" to reopen the review.
                info[Key.targetKind] = "review"
                content.categoryIdentifier = Category.taskTarget
            case .none:
                content.categoryIdentifier = Category.plain
            }
            if let targetId { info[Key.targetId] = targetId }
            if !info.isEmpty { content.userInfo = info }

            // Render the same iconography used by the in-app row —
            // a circle filled with the target's category/calendar
            // colour, with the kind's SF Symbol drawn in white on
            // top. UNNotificationAttachment displays it as the
            // thumbnail to the right of the banner title.
            if let url = self.makeIconAttachment(kind: kind, tintHex: tintHex) {
                if let attachment = try? UNNotificationAttachment(
                    identifier: "apollo-icon",
                    url:        url,
                    options:    nil
                ) {
                    content.attachments = [attachment]
                }
            }

            let req = UNNotificationRequest(
                identifier: appNotifId?.uuidString ?? UUID().uuidString,
                content:    content,
                trigger:    nil          // deliver immediately
            )
            do { try await self.center.add(req) }
            catch { NSLog("[DayPanel] native notification: %@", "\(error)") }
        }
    }

    // MARK: - Icon rendering

    /// Builds a 96×96 PNG that mirrors the in-app NotificationRow
    /// glyph: the target's category/calendar colour as a filled
    /// circle, with the kind's SF Symbol stroked in white. Returns
    /// the file URL of the cached PNG so it can be attached to a
    /// `UNNotificationRequest`. Falls back to the kind's static
    /// tint when `tintHex` is missing.
    private func makeIconAttachment(kind: AppNotification.Kind,
                                    tintHex: String?) -> URL? {
        let size = NSSize(width: 96, height: 96)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        // Background circle — target tint.
        let tint = NativeNotifier.color(forHex: tintHex)
            ?? NativeNotifier.kindFallbackColor(kind)
        tint.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()

        // Foreground SF Symbol in white. Using palette config so
        // the symbol picks up the requested colour without us
        // having to rasterise via a template.
        let glyphName = kind.systemImage
        if let symbol = NSImage(systemSymbolName: glyphName,
                                accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 52, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            let glyph = symbol.withSymbolConfiguration(cfg) ?? symbol
            let g = glyph.size
            let rect = NSRect(
                x: (size.width  - g.width)  / 2,
                y: (size.height - g.height) / 2,
                width:  g.width,
                height: g.height
            )
            glyph.draw(in: rect, from: .zero,
                       operation: .sourceOver, fraction: 1.0)
        }

        guard let tiff = image.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff),
              let png  = rep.representation(using: .png, properties: [:])
        else { return nil }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apollo-notif-icons", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("icon-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
            return url
        } catch {
            NSLog("[Apollo] icon attachment write failed: %@", "\(error)")
            return nil
        }
    }

    private static func color(forHex hex: String?) -> NSColor? {
        guard var s = hex?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        var rgb: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&rgb) else { return nil }
        return NSColor(
            srgbRed: CGFloat((rgb & 0xFF0000) >> 16) / 255,
            green:   CGFloat((rgb & 0x00FF00) >>  8) / 255,
            blue:    CGFloat( rgb & 0x0000FF)        / 255,
            alpha:   1.0
        )
    }

    private static func kindFallbackColor(_ kind: AppNotification.Kind) -> NSColor {
        switch kind {
        case .info:    return .systemBlue
        case .success: return .systemGreen
        case .warning: return .systemOrange
        case .error:   return .systemRed
        }
    }

    /// Drops a single delivered/pending notification by its app-side
    /// id — used when the user dismisses the in-app row, so the
    /// banner in Notification Center disappears too.
    /// Posts a FUTURE native notification — fires at the
    /// specified `fireDate`. Used by the AI agent's
    /// `[[SCHEDULE_REMINDER]]` marker so users can say
    /// "me lembra 2 dias antes da reunião X" and have a real
    /// macOS banner pop at that moment, even if Apollo is
    /// closed in the meantime (UNUserNotificationCenter
    /// stores pending requests system-wide).
    @discardableResult
    func schedule(appNotifId: UUID = UUID(),
                  fireDate:   Date,
                  kind:       AppNotification.Kind,
                  title:      String,
                  subtitle:   String?                     = nil,
                  body:       String?,
                  targetKind: AppNotification.TargetKind? = nil,
                  targetId:   String?                     = nil,
                  tintHex:    String?                     = nil) async -> Bool {
        if userOptedOut {
            NSLog("[Apollo] schedule skipped — user opted out")
            return false
        }
        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional else {
            NSLog("[Apollo] schedule skipped — auth %d", status.rawValue)
            return false
        }
        // Reject past dates — UNUserNotificationCenter would
        // either fire instantly or refuse the request.
        guard fireDate > Date() else {
            NSLog("[Apollo] schedule rejected — date in past")
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
        if let body,     !body.isEmpty     { content.body     = body }
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 1.0

        var info: [String: Any] = [Key.appNotifId: appNotifId.uuidString]
        switch targetKind {
        case .task:
            info[Key.targetKind] = "task"
            content.categoryIdentifier = Category.taskTarget
        case .event:
            info[Key.targetKind] = "event"
            content.categoryIdentifier = Category.eventTarget
        case .review:
            info[Key.targetKind] = "review"
            content.categoryIdentifier = Category.taskTarget
        case .none:
            content.categoryIdentifier = Category.plain
        }
        if let targetId { info[Key.targetId] = targetId }
        content.userInfo = info

        if let url = makeIconAttachment(kind: kind, tintHex: tintHex),
           let attachment = try? UNNotificationAttachment(
               identifier: "apollo-icon",
               url:        url,
               options:    nil
           ) {
            content.attachments = [attachment]
        }

        // UNCalendarNotificationTrigger uses absolute dates →
        // survives reboots & timezone changes properly.
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: comps,
            repeats:      false
        )
        let req = UNNotificationRequest(
            identifier: appNotifId.uuidString,
            content:    content,
            trigger:    trigger
        )
        do {
            try await center.add(req)
            return true
        } catch {
            NSLog("[Apollo] schedule failed: %@", "\(error)")
            return false
        }
    }

    /// Lists every scheduled (pending) notification we created.
    /// The AI uses this to answer "que lembretes eu programei?".
    func listPending() async -> [(id: String, fireDate: Date, title: String, body: String)] {
        let pending = await center.pendingNotificationRequests()
        return pending.compactMap { req in
            let title = req.content.title
            let body  = req.content.body
            guard let trigger = req.trigger as? UNCalendarNotificationTrigger,
                  let next    = trigger.nextTriggerDate()
            else { return nil }
            return (req.identifier, next, title, body)
        }
        .sorted { $0.fireDate < $1.fireDate }
    }

    /// Cancels a scheduled reminder by its UUID string.
    func cancelScheduled(id: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    func remove(appNotifId: UUID) {
        let key = appNotifId.uuidString
        center.removeDeliveredNotifications(withIdentifiers: [key])
        center.removePendingNotificationRequests(withIdentifiers: [key])
    }

    /// Wipes every Apollo-posted banner from Notification Center.
    /// Called when the user explicitly turns the toggle off so the
    /// effect is visible immediately.
    func removeAllDelivered() {
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }
}
