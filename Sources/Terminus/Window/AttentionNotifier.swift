import AppKit
import UserNotifications

/// Tells you about a tab that wants you while you're in another app: a
/// notification (clicking it brings the tab up), a Dock bounce, and the
/// Dock badge counting such tabs.
@MainActor
enum AttentionNotifier {
    nonisolated static let tabIDKey = "tabID"

    /// Notifications an isolated run would have posted (it posts none).
    static var suppressed = 0

    static func notify(tab: Tab) {
        guard !NSApp.isActive, Settings.shared.notifications else { return }
        if AppEnvironment.isIsolated {
            suppressed += 1
            return
        }
        NSApp.requestUserAttention(.informationalRequest)

        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = tab.title
        content.body = tab.activity.note ?? (tab.agent.map { "\($0.name) is waiting for you" } ?? "Needs your attention")
        content.userInfo = [tabIDKey: tab.id.uuidString]
        content.sound = .default
        let request = UNNotificationRequest(identifier: tab.id.uuidString, content: content, trigger: nil)
        // Asks for permission the first time; if refused, the badge and the
        // Dock bounce still say it.
        center.requestAuthorization(options: [.alert, .sound, .badge], completionHandler: authorized(then: request))
    }

    /// What runs once permission is answered — built outside the main
    /// actor. UserNotifications calls it on a queue of its own; a closure
    /// written in this @MainActor type is main-actor-isolated, and Swift 6
    /// traps when it runs anywhere else: the app crashed (EXC_BREAKPOINT in
    /// dispatch_assert_queue) at an agent's notification while in the
    /// background, 2026-09-28.
    nonisolated static func authorized(
        then request: UNNotificationRequest, add: @escaping @Sendable (UNNotificationRequest) -> Void = { UNUserNotificationCenter.current().add($0) }
    ) -> @Sendable (Bool, (any Error)?) -> Void {
        nonisolated(unsafe) let request = request
        return { granted, _ in
            guard granted else { return }
            add(request)
        }
    }

    static func withdraw(tab: Tab) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [tab.id.uuidString])
    }

    static func updateBadge(count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 && Settings.shared.dockBadge ? "\(count)" : nil
    }
}
