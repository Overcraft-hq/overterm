import AppKit
import UserNotifications

/// Whether macOS lets Overterm post notifications, as it says now — read
/// live each time, never kept: an ad hoc signed update can take it back
/// (onboarding D-14).
package enum NotificationPermission: String, Sendable {
    /// Never asked: the system's question is still to come.
    case notAsked
    case allowed
    case denied

    package init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notAsked
        case .denied: self = .denied
        default: self = .allowed
        }
    }
}

/// Tells you about a tab that wants you while you're in another app: a
/// notification (clicking it brings the tab up), a Dock bounce, and the
/// Dock badge counting such tabs.
@MainActor
package enum AttentionNotifier {
    package nonisolated static let tabIDKey = "tabID"

    /// Notifications an isolated run would have posted (it posts none).
    package static var suppressed = 0
    /// What `authorizationState()` answers in an isolated run, which never
    /// asks macOS: a scenario's say; nil reads as a fresh Mac's, not asked.
    package static var permissionOverride: NotificationPermission?
    /// `requestNow()`s an isolated run made — no system question is put to it.
    package static var requestedNow = 0

    /// `note` and `mark`: a notice that isn't the tab's own mark (a cluster
    /// failure while an agent's waiting mark holds the tab) — posted beside
    /// the tab's own notification, not over it.
    package static func notify(tab: Tab, note: String? = nil, mark: TabActivity.Mark? = nil) {
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
        // Dock bounce still say it. On a fresh install's first launch the
        // question waits for T1's button instead (onboarding D-6).
        if Start.shared.holdsNotificationAsk {
            postUnlessNotAsked(request, options: [.alert, .sound, .badge])
        } else {
            center.requestAuthorization(options: [.alert, .sound, .badge], completionHandler: authorized(then: request))
        }
    }

    /// Whether a notice asks for permission as it posts — the lazy ask, as
    /// it always was — or, never asked yet, leaves the question to T1's
    /// Allow Notifications… (onboarding D-6): only on a fresh install's
    /// first launch, with tips on and T1 not seen. From the second launch
    /// on it asks again, T1 seen or not, so a new install can't lose the
    /// question for good. Pure.
    package nonisolated static func asksLazily(state: NotificationPermission, tipsOn: Bool, t1Seen: Bool, firstLaunch: Bool) -> Bool {
        state != .notAsked || !tipsOn || t1Seen || !firstLaunch
    }

    /// The held ask: what macOS says now, read off the main actor; asked
    /// (and so posted) only when it isn't "not asked" — then the request
    /// puts no question and answers at once. Built outside the main actor,
    /// as `authorized(then:)` is.
    private nonisolated static func postUnlessNotAsked(_ request: UNNotificationRequest, options: UNAuthorizationOptions) {
        nonisolated(unsafe) let request = request
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let state = NotificationPermission(settings.authorizationStatus)
            guard asksLazily(state: state, tipsOn: true, t1Seen: false, firstLaunch: true) else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: options, completionHandler: authorized(then: request))
        }
    }

    /// Notifications as macOS says now (T1's second line, the Setup
    /// page). An isolated run never asks: `permissionOverride`, else not asked.
    package static func authorizationState() async -> NotificationPermission {
        if AppEnvironment.isIsolated { return permissionOverride ?? .notAsked }
        return await withCheckedContinuation { (continuation: CheckedContinuation<NotificationPermission, Never>) in
            readPermission(into: continuation)
        }
    }

    /// T1's Allow Notifications…: the system's question, put now — by a
    /// click, with the reason beside it (D-6). What macOS says after.
    /// An isolated run counts it and puts nothing.
    package static func requestNow() async -> NotificationPermission {
        if AppEnvironment.isIsolated {
            requestedNow += 1
            return permissionOverride ?? .notAsked
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            requestPermission(resuming: continuation)
        }
        return await authorizationState()
    }

    /// UserNotifications answers on a queue of its own: built here, outside
    /// the main actor (CLAUDE.md).
    private nonisolated static func readPermission(into continuation: CheckedContinuation<NotificationPermission, Never>) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            continuation.resume(returning: NotificationPermission(settings.authorizationStatus))
        }
    }

    private nonisolated static func requestPermission(resuming continuation: CheckedContinuation<Void, Never>) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            continuation.resume()
        }
    }

    /// What runs once permission is answered — built outside the main
    /// actor. UserNotifications calls it on a queue of its own; a closure
    /// written in this @MainActor type is main-actor-isolated, and Swift 6
    /// traps when it runs anywhere else: the app crashed (EXC_BREAKPOINT in
    /// dispatch_assert_queue) at an agent's notification while in the
    /// background, 2026-09-28.
    package nonisolated static func authorized(
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
    package static func summarize(_ held: [GroupFocus.Held]) {
        guard !NSApp.isActive, Settings.shared.notifications, !held.isEmpty else { return }
        if AppEnvironment.isIsolated {
            suppressed += 1
            return
        }
        let content = UNMutableNotificationContent()
        content.title = held.count == 1 ? "1 tab waited while you focused" : "\(held.count) tabs waited while you focused"
        content.body = held.map { "\($0.groupName) · \($0.title) — \($0.note)" }.joined(separator: "\n")
        let request = UNNotificationRequest(identifier: "focus-summary", content: content, trigger: nil)
        if Start.shared.holdsNotificationAsk {
            // The question waits for T1's button: the Dock says it meanwhile (D-6).
            NSApp.requestUserAttention(.informationalRequest)
            postUnlessNotAsked(request, options: [.alert, .sound])
        } else {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound], completionHandler: authorized(then: request))
        }
    }

    /// A notice beside the tab's own (`notify(tab:note:mark:)`).
    private static func sideIdentifier(_ tab: Tab) -> String { tab.id.uuidString + "-cluster" }

    package static func withdraw(tab: Tab) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [tab.id.uuidString, sideIdentifier(tab)])
    }

    /// Only the notice beside the tab's own: what it said has gone, the tab's mark hasn't.
    package static func withdrawSide(tab: Tab) {
        guard !AppEnvironment.isIsolated else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [sideIdentifier(tab)])
    }

    package static func updateBadge(count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 && Settings.shared.dockBadge ? "\(count)" : nil
    }
}
