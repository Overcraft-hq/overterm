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

    /// `note` and `mark`: a notice that isn't the tab's own mark (a cluster
    /// failure while an agent's waiting mark holds the tab) — posted beside
    /// the tab's own notification, not over it.
    static func notify(tab: Tab, note: String? = nil, mark: TabActivity.Mark? = nil) {
        // Settings ▸ Notifications: on at all, and for this kind of mark.
        guard !NSApp.isActive, Settings.shared.notifies(mark ?? tab.activity.mark) else { return }
        if AppEnvironment.isIsolated {
            suppressed += 1
            return
        }
        NSApp.requestUserAttention(.informationalRequest)

        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = tab.title
        content.body = note ?? tab.activity.note ?? (tab.agent.map { "\($0.name) is waiting for you" } ?? "Needs your attention")
        content.userInfo = [tabIDKey: tab.id.uuidString]
        content.sound = .default
        let identifier = note == nil ? tab.id.uuidString : sideIdentifier(tab)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
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

    /// Leaving focus: everything that waited, as one notice rather than a
    /// burst — the point of focusing was not to be interrupted.
    static func summarize(_ held: [GroupFocus.Held]) {
        guard !NSApp.isActive, Settings.shared.notifications, !held.isEmpty else { return }
        if AppEnvironment.isIsolated {
            suppressed += 1
            return
        }
        let content = UNMutableNotificationContent()
        content.title = held.count == 1 ? "1 tab waited while you focused" : "\(held.count) tabs waited while you focused"
        content.body = held.map { "\($0.groupName) · \($0.title) — \($0.note)" }.joined(separator: "\n")
        let request = UNNotificationRequest(identifier: "focus-summary", content: content, trigger: nil)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound], completionHandler: authorized(then: request))
    }

    /// A notice beside the tab's own (`notify(tab:note:mark:)`).
    private static func sideIdentifier(_ tab: Tab) -> String { tab.id.uuidString + "-cluster" }

    static func withdraw(tab: Tab) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [tab.id.uuidString, sideIdentifier(tab)])
    }

    /// Only the notice beside the tab's own: what it said has gone, the tab's mark hasn't.
    static func withdrawSide(tab: Tab) {
        guard !AppEnvironment.isIsolated else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [sideIdentifier(tab)])
    }

    static func updateBadge(count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 && Settings.shared.dockBadge ? "\(count)" : nil
    }
}
