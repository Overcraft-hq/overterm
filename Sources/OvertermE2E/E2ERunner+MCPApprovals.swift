#if E2E
import AppKit

/// D-6 (b), P09 (Overcraft-hq/issue-tracker#19): an agent's MCP write asked
/// as a card in the Inbox when its window isn't in front — the tab marked,
/// Allow and Don't on the card, the name typed on production, an error
/// once nobody answered in time — and as today's sheet when it is.
extension E2ERunner {
    package func mcpApprovalsScenario() async {
        app.newTab(in: scratch)
        guard let tab = app.store.selected else { return check("a tab to ask from", false) }
        let pane = tab.terminal.processTag
        let approvals = MCPApprovals.shared
        defer {
            approvals.inFront = nil
            MCPApprovals.timeout = .seconds(600)
        }
        func ask(_ confirmation: WriteConfirmation) -> Task<Result<String?, Error>, Never> {
            Task { @MainActor in
                await MCPAsker.$pane.withValue(pane) {
                    do { return .success(try await approvals.ask(confirmation)) } catch { return .failure(error) }
                }
            }
        }
        let remove = WriteConfirmation(
            title: "An agent wants to remove “e2e-web”", detail: "nginx:latest — Exited (0)", button: "Allow", cancel: "Don't", destroys: true)

        // Not in front: a card, the tab marked, no sheet — and the app not brought forward.
        approvals.inFront = { _ in false }
        let first = ask(remove)
        check("an agent's write waits as a request", await eventually(5) { approvals.pending.count == 1 })
        check("no sheet when its window isn't in front", window.attachedSheet == nil)
        check(
            "its tab is marked waiting, saying what is asked",
            await eventually(3) { tab.activity.mark == .waiting && tab.activity.note == "An agent wants to remove “e2e-web”" }, "\(tab.activity)")
        app.toggleInbox(nil)
        defer { if app.inboxItem?.isCollapsed == false { app.toggleInbox(nil) } }
        check(
            "the Inbox has its card, with who asks",
            await eventually(3) {
                self.app.inbox.entries.first { $0.id == tab.id }?.approval?.confirmation.asker?.contains("Asked through MCP by") == true
            }, "\(app.inbox.entries.map(\.headline))")
        check("the card offers no screen choices", app.inbox.entries.first { $0.id == tab.id }?.prompt == nil)
        if let card = approvals.pending.first { approvals.answer(card.id, typed: "") }
        if case .success(let typed)? = await first.value as Result<String?, Error>? {
            check("Allow on the card lets it run", typed == "")
        } else {
            check("Allow on the card lets it run", false)
        }
        check("answered, its mark and its card go", await eventually(3) { tab.activity.mark == .none && self.app.inbox.entries.allSatisfy { $0.approval == nil } })

        // Don't: the agent reads it was declined.
        let second = ask(remove)
        _ = await eventually(5) { !approvals.pending.isEmpty }
        if let card = approvals.pending.first { approvals.answer(card.id, typed: nil) }
        if case .success(let typed) = await second.value { check("Don't declines it", typed == nil) } else { check("Don't declines it", false) }

        // Production: the name typed before Allow.
        check("a name to type holds Allow until it matches", !MCPApprovals.accepts("prod", name: "payments") && MCPApprovals.accepts(" payments ", name: "payments"))

        // Nobody answers: an error the agent reads, the card gone.
        MCPApprovals.timeout = .seconds(1)
        let third = ask(remove)
        let ended = await third.value
        if case .failure(let error as BrowserMCP.ToolError) = ended {
            check("unanswered in time, the agent gets an error", error.message.hasPrefix("Nobody answered in Overterm within a second"), error.message)
        } else {
            check("unanswered in time, the agent gets an error", false, "\(ended)")
        }
        check("and nothing waits any more", approvals.pending.isEmpty && tab.activity.mark == .none, "\(tab.activity)")
        MCPApprovals.timeout = .seconds(600)

        // In front: today's sheet on the pane's window.
        approvals.inFront = { _ in true }
        let fourth = ask(remove)
        check("in front, it is asked as the sheet", await eventually(5) { self.window.attachedSheet != nil })
        check("the sheet names who asks", sheetTexts().contains { $0.hasPrefix("Asked through MCP by") }, "\(sheetTexts())")
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        if case .success(let typed) = await fourth.value { check("allowed on the sheet", typed == "") } else { check("allowed on the sheet", false) }

        // A card answered while its sheet shows: the sheet goes too.
        let fifth = ask(remove)
        _ = await eventually(5) { self.window.attachedSheet != nil }
        if let card = approvals.pending.first { approvals.answer(card.id, typed: nil) }
        _ = await fifth.value
        check("answered in the Inbox, its sheet closes", await eventually(3) { self.window.attachedSheet == nil })
    }
}
#endif
