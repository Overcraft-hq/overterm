import AppKit
import Combine

/// An agent's MCP write asked (D-6 (b), P09): the calling pane's tab marked
/// and a notification sent, the Inbox's card; the sheet only over a tab
/// in front — never the app brought forward (`MCPApprovals`).
extension TerminalWindowController {
    package func wireMCPApprovals() {
        // @Published emits before the value lands: the emitted one is used.
        MCPApprovals.shared.$pending
            .sink { [weak self] pending in self?.applyMCPApprovals(pending) }
            .store(in: &cancellables)
    }

    /// Each tab's request — the oldest any of its panes made (`tab.terminals`).
    package func applyMCPApprovals(_ pending: [MCPApprovals.Request]) {
        for tab in store.tabs {
            let panes = Set(tab.terminals.map(\.processTag))
            if let request = pending.first(where: { $0.pane.map(panes.contains) ?? false }) {
                let text = request.summary
                guard mcpMarked[tab.id] != text else { continue }
                mcpMarked[tab.id] = text
                if tab.activity.mcpAsked(text, visible: isVisible(tab)) { notifyUnlessHeld(tab) }
                if isVisible(tab), let window { MCPApprovals.shared.showSheet(request.id, on: window) }
            } else if let text = mcpMarked.removeValue(forKey: tab.id), tab.activity.mcpAnswered(text) {
                AttentionNotifier.withdraw(tab: tab)
            }
        }
        updateAttentionBadge()
        // The Inbox reads the requests themselves, which land after this.
        DispatchQueue.main.async { [weak self] in
            if self?.inboxItem?.isCollapsed == false { self?.refreshInbox() }
        }
    }

    /// The request of the tab now in front, as its sheet: the person looked.
    package func showSelectedApproval() {
        guard let tab = store.selected, let window, MCPApprovals.shared.isInFront(window),
            let request = MCPApprovals.shared.first(forPanes: Set(tab.terminals.map(\.processTag)))
        else { return }
        MCPApprovals.shared.showSheet(request.id, on: window)
    }

    /// The request a tab's panes made, for its Inbox card.
    package func approval(of tab: Tab) -> MCPApprovals.Request? {
        MCPApprovals.shared.first(forPanes: Set(tab.terminals.map(\.processTag)))
    }
}
