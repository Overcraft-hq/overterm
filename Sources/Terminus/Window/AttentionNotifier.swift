import AppKit
import UserNotifications

/// Tells you about a tab that wants you while you're in another app: a
/// notification (clicking it brings the tab up), a Dock bounce, and the
/// Dock badge counting such tabs.
@MainActor
enum AttentionNotifier {
    static let tabIDKey = "tabID"

    static func notify(tab: Tab) {
        guard !NSApp.isActive else { return }
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
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            center.add(request)
        }
    }

    static func withdraw(tab: Tab) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [tab.id.uuidString])
    }

    static func updateBadge(count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }
}
