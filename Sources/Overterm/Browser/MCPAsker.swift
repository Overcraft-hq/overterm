import AppKit

/// Who asks, when a write's confirmation comes from an agent's MCP call
/// (analysis D-15): the tab the calling pane is in and the agent running
/// there, "asked through MCP". The pane is the bridge's path, which only
/// that pane's token opens; the line is what the person reads to tell one
/// agent's request from another's — another of the user's processes could
/// still read a pane's token out of its environment, and then the sheet
/// names the pane it pretends to be, in that pane's own window.
enum MCPAsker {
    /// The pane whose MCP call is running: set by `BrowserMCP.handle` for
    /// the length of the call, so every confirmation the call asks knows it.
    @TaskLocal static var pane: String?

    /// What a confirmation says of who asks (pure). `tab`: its title, nil
    /// when the pane has closed since; `checkout`: the folder it works in,
    /// when it says more than the title.
    @MainActor static func line(tab: String?, checkout: String? = nil, agent: String?) -> String {
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
    @MainActor static func current() async -> String? {
        guard let pane else { return nil }
        guard let (tab, terminal) = locate(pane) else { return line(tab: nil, agent: nil) }
        var agent = tab.agent?.name
        if agent == nil { agent = await Self.agent(root: SurfaceProcesses.shared.loginPID(of: terminal), tag: terminal.processTag) }
        return line(tab: tab.title, checkout: tab.checkoutSource?.root.lastPathComponent, agent: agent)
    }

    /// The window the pane is in, else the main one, else any terminal
    /// window on screen.
    @MainActor static func window(forPane pane: String?) -> NSWindow? {
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

    /// The agent running in the pane, read off the main thread: Claude or
    /// Codex, by its process.
    nonisolated private static func agent(root: pid_t?, tag: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let inspector = ProcessInspector()
                let node = TerminalWindowController.firstAgent(in: [(root, tag)]) { inspector.tree(root: $0, tag: $1) }
                continuation.resume(returning: node.flatMap(agentName))
            }
        }
    }

    /// "Claude" or "Codex" for an agent's process (by name, else argv[0]).
    nonisolated static func agentName(_ node: ProcessNode) -> String? {
        let first = node.command.split(separator: " ").first.map { (String($0) as NSString).lastPathComponent }
        return (Agent(rawValue: node.name) ?? first.flatMap(Agent.init(rawValue:)))?.name
    }
}
