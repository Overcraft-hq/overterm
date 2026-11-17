import AppKit

/// A pane as the screen check last saw it (`AgentScreenCheck`).
struct AgentScreenPane {
    /// The agent in its foreground, as last read, and when.
    var agent: Agent?
    var readAt: Date = .distantPast
    /// It sent a notification or progress since its last command began.
    var signalled = false
    /// What its screen asked at the last read.
    var question: String?
}

// MARK: Waiting for you, read off the screen (AgentScreenCheck)

extension TerminalWindowController {
    func startAgentScreenCheck() {
        guard agentScreenLoop == nil else { return }
        agentScreenLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: AgentScreenCheck.interval)
                await self?.agentScreenRound()
            }
        }
    }

    /// A pane's own signal: it says when it wants you, so its screen
    /// isn't read. A command finishing starts it over (another program
    /// may run there next).
    func noteAttentionSignal(_ event: TerminalEvent, from pane: TerminalView?) {
        guard let pane else { return }
        switch event {
        case .notification, .progress(true, _):
            agentScreenPanes[pane.processTag, default: AgentScreenPane()].signalled = true
        case .commandFinished:
            agentScreenPanes[pane.processTag] = nil
        default:
            break
        }
    }

    /// One round: which panes to look at, their agents read off the main
    /// thread where not known lately, the screens of those with one read
    /// here and parsed off it; the tabs marked, or their marks taken back.
    func agentScreenRound(now: Date = Date()) async {
        guard !agentScreenInFlight else { return }
        agentScreenInFlight = true
        defer { agentScreenInFlight = false }

        struct Look: Sendable {
            var tag: String
            var login: pid_t
            var recheck: Bool
            var screen: String?
        }
        var looks: [Look] = []
        var tabOf: [String: Tab] = [:]
        var live: Set<String> = []
        for tab in store.tabs {
            let visible = isVisible(tab)
            for pane in tab.terminals {
                let tag = pane.processTag
                live.insert(tag)
                let state = agentScreenPanes[tag] ?? AgentScreenPane()
                let running = tab.agent != nil || blocks(of: pane).ledger.running != nil
                guard tab.terraformAsk == nil,
                    AgentScreenCheck.looks(running: running, signalled: state.signalled, visible: visible, standing: tab.screenAsk != nil),
                    let login = SurfaceProcesses.shared.loginPID(of: pane)
                else { continue }
                tabOf[tag] = tab
                let recheck = now.timeIntervalSince(state.readAt) >= AgentScreenCheck.agentRecheck
                // The screen only where an agent was found: a long build's isn't read.
                let screen = !recheck && state.agent != nil ? pane.visibleText : nil
                looks.append(Look(tag: tag, login: login, recheck: recheck, screen: screen))
            }
        }
        agentScreenPanes = agentScreenPanes.filter { live.contains($0.key) }
        let asked = looks
        let found: [(tag: String, agent: Agent??, question: String?)] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let inspector = ProcessInspector()
                continuation.resume(
                    returning: asked.map { look in
                        let agent: Agent?? = look.recheck ? .some(Self.foregroundAgent(login: look.login, inspector: inspector)) : .none
                        return (look.tag, agent, look.screen.flatMap(AgentScreenCheck.question(in:)))
                    })
            }
        }
        var touched: Set<Tab.ID> = []
        for item in found {
            guard let tab = tabOf[item.tag] else { continue }
            var state = agentScreenPanes[item.tag] ?? AgentScreenPane()
            if let agent = item.agent {
                state.agent = agent
                state.readAt = now
                // No agent there any more: nothing it asked stands.
                if agent == nil, state.question != nil {
                    state.question = nil
                    touched.insert(tab.id)
                }
            } else {
                state.question = item.question
                touched.insert(tab.id)
            }
            agentScreenPanes[item.tag] = state
        }
        for tab in store.tabs where touched.contains(tab.id) {
            // Its panes in order: the first one's question that stands.
            var question: String?
            for pane in tab.terminals where question == nil { question = agentScreenPanes[pane.processTag]?.question }
            markScreenAsk(question, on: tab)
        }
    }

    /// The agent in a pane's foreground process group, if any. Blocking:
    /// a walk of the pane's processes.
    nonisolated static func foregroundAgent(login: pid_t, inspector: ProcessInspector) -> Agent? {
        guard let foreground = ProcessInspector.foregroundGroup(of: login) else { return nil }
        for node in inspector.tree(root: login, tag: nil).flatMap(\.flattened) {
            if let agent = AgentOverviewModel.agent(of: node), ProcessInspector.processGroup(of: node.pid) == foreground { return agent }
        }
        return nil
    }

    /// `tab`'s question, or none now: marked waiting while you are
    /// elsewhere (and told), the mark taken back when it goes.
    func markScreenAsk(_ question: String?, on tab: Tab) {
        guard tab.screenAsk != question else { return }
        tab.screenAsk = question
        if let question {
            if tab.activity.agentAsked(question, visible: isVisible(tab)) { notifyUnlessHeld(tab) }
        } else if tab.activity.agentAnswered() {
            AttentionNotifier.withdraw(tab: tab)
        }
        updateAttentionBadge()
    }
}
