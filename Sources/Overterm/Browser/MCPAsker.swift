import AppKit

/// Who asks, when a write's confirmation comes from an agent's MCP call
/// (analysis D-15): the tab the calling pane is in and the agent running
/// there, "asked through MCP". The pane is the bridge's path, which only
/// that pane's token opens; the line is what the person reads to tell one
/// agent's request from another's — another of the user's processes could
/// still read a pane's token out of its environment, and then the sheet
/// names the pane it pretends to be, in that pane's own window.
package enum MCPAsker {
    /// The pane whose MCP call is running: set by `BrowserMCP.handle` for
    /// the length of the call, so every confirmation the call asks knows it.
    @TaskLocal package static var pane: String?

    /// What a confirmation says of who asks (pure). `tab`: its title, nil
    /// when the pane has closed since; `checkout`: the folder it works in,
    /// when it says more than the title.
    @MainActor package static func line(tab: String?, checkout: String? = nil, agent: String?) -> String {
        guard let tab else { return "Asked through MCP by a pane that is no longer open" }
        // A shell sets its own title: one line, every character visible,
        // so a title can't draw a second asker under the first.
        func shown(_ text: String) -> String {
            DockerMCP.displayed(String(text.map { $0.isNewline || $0 == "\t" ? " " : $0 }))
        }
        let folder = checkout.flatMap { $0 == tab ? nil : " (\(shown($0)))" } ?? ""
        return "Asked through MCP by \(agent ?? "an agent") in the tab “\(shown(tab))”\(folder)"
    }

    /// The line for the call running now; nil when this isn't an agent's call.
    @MainActor package static func current() async -> String? {
        guard let pane else { return nil }
        guard let (tab, terminal) = locate(pane) else { return line(tab: nil, agent: nil) }
        var agent = tab.agent?.name
        if agent == nil {
            // An agent typed into a plain tab: the census says which.
            agent = await Self.agent(tab: tab.id, pane: terminal.processTag)
        }
        // Where its agent works now, read again first while its window is off screen.
        let checkout = await TerminalWindowController.paneCheckout(pane) ?? tab.checkoutSource?.root
        return line(tab: tab.title, checkout: checkout?.lastPathComponent, agent: agent)
    }

    /// The window the pane is in, else the main one, else any terminal
    /// window on screen.
    @MainActor package static func window(forPane pane: String?) -> NSWindow? {
        let terminals = controllers()
        if let pane, let own = terminals.first(where: { $0.store.tabs.contains { $0.terminals.contains { $0.processTag == pane } } }) {
            return own.window
        }
        return (NSApp as NSApplication?)?.mainWindow ?? terminals.first { $0.window?.isVisible == true }?.window
    }

    /// Every terminal window's controller; none before the app is up (a unit test).
    @MainActor private static func controllers() -> [TerminalWindowController] {
        ((NSApp as NSApplication?)?.windows ?? []).compactMap { $0.windowController as? TerminalWindowController }
    }

    /// The pane's tab, over every pane of every tab (`tab.terminals`).
    @MainActor private static func locate(_ pane: String) -> (Tab, TerminalView)? {
        for controller in controllers() {
            for tab in controller.store.tabs {
                if let terminal = tab.terminals.first(where: { $0.processTag == pane }), let found = controller.tab(containing: terminal) {
                    return (found, terminal)
                }
            }
        }
        return nil
    }

    /// The agent running in the pane, by its process: a lookup in the
    /// census (docs/design/activity/analysis.md, 7.8; 2.4 items 2 and 3) —
    /// the light tick's snapshot of the pane's tab while it is fresh, one
    /// tick of that tab else — on a GCD thread. The pane's `login` was
    /// paired on the main actor by a scan of the app's children when it
    /// wasn't yet, and a fresh inspector read every process's environment
    /// again, ≈21 ms a confirmation: a pane not paired yet is paired from
    /// the lookup's own snapshot (`PaneAgent.pairing`), and the census
    /// reads an environment once per process, for its markers alone.
    @MainActor package static func agent(
        tab: UUID, pane: String, census: ActivitySampler = .app, surfaces: SurfaceProcesses = .shared, monitor: ActivityMonitor = .shared
    ) async -> String? {
        await PaneAgent.read([(id: tab, tags: [pane])], census: census, folders: false, surfaces: surfaces, monitor: monitor)[tab]?.kind.name
    }

}
