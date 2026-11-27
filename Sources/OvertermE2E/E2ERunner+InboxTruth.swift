#if E2E
import AppKit

/// #31's fourth patch (AGT-U1, U6, U7, U8): the Inbox says what is true —
/// ⌫ is the Deny it shows, a finished entry can be let go of, a wait is
/// counted from when it began — and ⌘L with nothing selected says so.
extension E2ERunner {
    func inboxTruthChecks(agent: Tab, shell: Tab) async {
        // The question back on the agent's screen, the tab waiting.
        agent.terminal.insertText("clear; cat \(out("prompt.txt").path)")
        agent.terminal.pressReturn()
        _ = await eventually(10) { (agent.terminal.visibleText ?? "").contains("3. No, and tell") }
        agent.activity.seen()
        agent.activity.handle(.notification(title: "Claude", body: "needs your permission"), visible: false)
        app.refreshInbox()
        let entry = app.inbox.entries.first { $0.id == agent.id }
        check(
            "the wait is counted from when it began",
            // Within a second: another read of the screen may raise the mark again in between.
            entry?.since.flatMap { since in agent.activity.waitingSince.map { abs(since.timeIntervalSince($0)) < 1 } } == true,
            "\(String(describing: entry?.since)) \(String(describing: agent.activity.waitingSince))")
        check("and said", entry.flatMap { $0.since.map { InboxModel.waited(since: $0) } } == "waiting <1 min")

        // ⌫ on the Inbox: the card's Deny, typed into that pane (AGT-U1).
        app.inbox.highlighted = agent.id
        guard let host = Self.find(NSView.self, in: app.inboxItem?.viewController.view, where: { String(describing: type(of: $0)).hasPrefix("InboxHostingView") }),
            let delete = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: app.window?.windowNumber ?? 0, context: nil,
                characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)
        else { return check("the Inbox's host takes keys", false) }
        host.keyDown(with: delete)
        check(
            "⌫ types the Deny the card shows",
            await eventually(8) {
                let text = agent.terminal.visibleText ?? ""
                return text.contains("command not found: 3") || text.contains("no such entry in dir stack")
            }, String((agent.terminal.visibleText ?? "").suffix(80)).debugDescription)

        // A failed command's entry, let go of from the list (AGT-U6).
        shell.activity.handle(.commandFinished(exitCode: 1, seconds: 30), visible: false)
        app.refreshInbox()
        guard let failed = app.inbox.entries.first(where: { $0.id == shell.id }) else { return check("the failed command is listed", false) }
        check("a failed entry can be dismissed", InboxModel.dismissable(failed))
        check("a waiting one can't", !(app.inbox.entries.first { $0.id == agent.id }.map(InboxModel.dismissable) ?? true))
        app.dismissInboxEntry(shell.id)
        check("dismissed, it leaves the list and its tab's mark goes", !app.inbox.entries.contains { $0.id == shell.id } && shell.activity.mark == .none)

        // ⌘L with nothing selected says so (AGT-U8).
        var said: String?
        app.askAgentHintRecorder = { said = $0 }
        defer { app.askAgentHintRecorder = nil }
        app.store.select(shell)
        app.askAboutSelection(nil)
        check("⌘L with nothing selected says so", said == "Select some text first", said ?? "nothing said")
        check("the new tab Ask Agent offers is New Task's agent", TerminalWindowController.newTabAgent == (Agent(rawValue: Settings.shared.taskAgent) ?? .claude))
    }
}
#endif
