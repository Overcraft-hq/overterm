import AppKit

/// Activity's agents' reads (docs/design/activity/analysis.md, 8.2): the
/// window tells `ActivityMCP` which pane asks — its tab and the checkout
/// it works in — and the rows' options as the app stands, every window's
/// tabs together, as the page makes its rows.
extension TerminalWindowController {
    func wireActivityMCP() {
        ActivityMCP.scene = { tag in await TerminalWindowController.activityMCPScene(pane: tag) }
    }

    /// Pane `tag`'s scene: nil for a pane no window has. Its checkout is
    /// read as `tf_`'s is — its agent's folder read again first while its
    /// window is off screen (`paneCheckout`).
    static func activityMCPScene(pane tag: String) async -> ActivityMCP.Scene? {
        guard locate(pane: tag) != nil else { return nil }
        let checkout = await paneCheckout(tag)
        // Read again after the wait: the pane may have closed meanwhile.
        guard let (_, tab) = locate(pane: tag) else { return nil }
        let facts = activityTabFacts()
        var options = ActivityRows.Options(everyone: Settings.shared.activityEveryone, isolated: AppEnvironment.isIsolated)
        options.tabs = facts.tabs
        options.checkouts = facts.checkouts
        options.context = ActivityMonitor.shared.context
        activityContextFacts(&options.context)
        options.runningApps = activityRunningApps()
        options.containers = activityContainers()
        // Owners are read for any grouping; the list itself is unused.
        options.grouping = .checkout
        options.known = activityKnown()
        let caller = ActivityMCPCaller(pane: tag, tab: tab.id, checkout: checkout?.standardizedFileURL.path ?? facts.tabs[tab.id]?.checkout)
        return ActivityMCP.Scene(caller: caller, options: options)
    }
}
