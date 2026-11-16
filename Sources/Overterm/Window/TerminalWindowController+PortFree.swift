import AppKit

/// A pane pill's Free… (docs/design/activity/analysis.md, 6.12; 2.4 item
/// 5): asked, always — `WriteConfirmation`, no setting skips it — and
/// identity-checked. The policy is `ActivitySignalCheck`'s; a signal goes
/// through `ProcessSignals` by the identity the census listed, ⌃C is typed
/// into the pane only while its foreground group is still the target's,
/// and a container's or a forward's port is its owner's Stop, asked first.
/// After a Free the pill watches the port and says when it is free.
extension TerminalWindowController {
    /// Free… on `port`'s pill in `pane`.
    func freePort(_ port: ListeningPort, in pane: TerminalView) {
        guard let window else { return }
        if let forward = port.forward {
            let question = ActivityPortFree.forwardQuestion(forward, port: port.port)
            return confirmation(question).present(on: window) { [weak self, weak pane] _ in
                KubeForwards.shared.stop(forward.id)
                guard let self, let pane, let tab = self.tab(containing: pane) else { return }
                self.watchFreed(port, freed: nil, in: pane, of: tab)
            }
        }
        if let name = port.container {
            let question = ActivityPortFree.containerQuestion(name, port: port.port)
            return confirmation(question).present(on: window) { [weak self, weak pane] _ in
                guard let self, let container = DockerModel.shared.container(name) else { return NSSound.beep() }
                self.dockerPage.act(.stop, on: [container])
                guard let pane, let tab = self.tab(containing: pane) else { return }
                self.watchFreed(port, freed: nil, in: pane, of: tab)
            }
        }
        guard let identity = port.identity, let tab = tab(containing: pane) else { return NSSound.beep() }
        // Paired already, or nil: the lookup then finds the pane by its tag
        // — never a read of the whole table on the main thread (7.7).
        let login = SurfaceProcesses.shared.pairedLoginPID(of: pane)
        let tag = pane.processTag
        // The pane's foreground group at the press: what ⌃C typed reaches.
        let foreground = pane.foregroundGroup
        // A `.app` inside one of these stays the pane's: a dev build.
        let checkouts = Array(Set(store.tabs.compactMap { $0.checkoutSource?.root.path }))
        // Read now (6.10 step 3), off the main thread: a lookup that ticks.
        DispatchQueue.global(qos: .userInitiated).async { @Sendable in
            let reading = Self.readHolder(identity, login: login, tag: tag, foreground: foreground, checkouts: checkouts)
            Task { @MainActor [weak self, weak pane, weak tab] in
                guard let self, let pane, let tab else { return }
                self.askToFree(port, reading, in: pane, of: tab)
            }
        }
    }

    /// What holds `identity` in the pane `login` and `tag` name, read now.
    /// Blocking.
    nonisolated static func readHolder(
        _ identity: ActivityProcessID, login: pid_t?, tag: String, foreground: pid_t?, checkouts: [String], census: ActivitySampler = .app
    ) -> ActivityPortFree.Reading {
        guard let (slice, snapshot) = ProcessInspector(census: census, freshness: 0).slice(root: login, tag: tag) else { return .elsewhere }
        let terminal = census.appContext.panes.first { $0.tag == tag }?.terminal
        return ActivityPortFree.read(identity, slice: slice, in: snapshot, foregroundGroup: foreground, terminal: terminal, checkouts: checkouts)
    }

    func confirmation(_ question: ActivityPortFree.Question) -> WriteConfirmation {
        WriteConfirmation(
            title: question.title, scope: question.scope, production: question.production, detail: question.detail, button: question.button,
            critical: question.critical)
    }

    /// Says `title` and `detail` in a sheet that asks nothing.
    func tell(_ title: String, _ detail: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private func askToFree(_ port: ListeningPort, _ reading: ActivityPortFree.Reading, in pane: TerminalView, of tab: Tab) {
        guard let window else { return }
        let holder: ActivityPortFree.Holder
        switch reading {
        case .ended(let now):
            let detail = now.map { "Its pid is “\(DockerMCP.displayed($0))”'s now: nothing was asked, nothing sent." } ?? "Nothing was asked, nothing sent."
            return tell("“\(DockerMCP.displayed(port.process))” on :\(port.port) has ended", detail)
        case .elsewhere:
            return tell(
                "“\(DockerMCP.displayed(port.process))” no longer runs in this pane",
                "What holds :\(port.port) isn't this pane's now: nothing was asked, nothing sent.")
        case .holder(let found):
            holder = found
        }
        let rule = ActivitySignalCheck.rule(.free, for: holder.target)
        if let reason = rule.refusal {
            let said = ActivityPortFree.refusal(reason, port: port.port)
            return tell(said.title, said.detail)
        }
        let scope = ActivityPortFree.scope(tab: tab.title, checkout: tab.checkoutSource?.root.lastPathComponent, agent: tab.agent)
        guard
            let question = ActivityPortFree.question(rule, holder: holder, port: port.port, scope: scope, tabTitle: tab.title, isSplit: tab.isSplit)
        else {
            // A helper's own route: stage 0 refuses it before here (15).
            let said = ActivityPortFree.refusal(ActivitySignalCheck.helper, port: port.port)
            return tell(said.title, said.detail)
        }
        // Every Free asks (D-10): no setting skips it.
        confirmation(question).present(on: window) { [weak self, weak pane, weak tab] _ in
            guard let self, let pane, let tab else { return }
            self.freeAtButton(port, holder, rule, in: pane, of: tab)
        }
    }

    /// The button (6.10 step 4): the holder read again, off the main
    /// thread, and the policy asked again of what it is now — a job that
    /// became a terraform write, joined an agent's group or moved to the
    /// foreground while the sheet was up is refused, not sent what was
    /// asked for what it was. Then what was asked.
    private func freeAtButton(_ port: ListeningPort, _ holder: ActivityPortFree.Holder, _ rule: ActivityRule, in pane: TerminalView, of tab: Tab) {
        guard let identity = port.identity else { return NSSound.beep() }
        let login = SurfaceProcesses.shared.pairedLoginPID(of: pane)
        let tag = pane.processTag
        let foreground = pane.foregroundGroup
        let checkouts = Array(Set(store.tabs.compactMap { $0.checkoutSource?.root.path }))
        DispatchQueue.global(qos: .userInitiated).async { @Sendable in
            let now = Self.readHolder(identity, login: login, tag: tag, foreground: foreground, checkouts: checkouts)
            Task { @MainActor [weak self, weak pane, weak tab] in
                guard let self, let pane, let tab else { return }
                if let changed = ActivityPortFree.changedAtButton(asked: holder, rule: rule, now: now, port: port.port) {
                    return self.tell("Not freed", changed)
                }
                switch rule {
                case .allowed(.interruptPane, _, _): self.interrupt(holder, port: port, in: pane, of: tab)
                case .allowed(.signal(let signal), _, _): self.signal(signal, holder, port: port, in: pane, of: tab)
                case .route(.closePane, _): self.closeForFree(pane, in: tab)
                // Stage 0 names every helper `.other`, refused before the
                // sheet: a route a pill can't take is said, never a beep.
                case .route, .refused: self.tell(ActivityPortFree.refusal(ActivitySignalCheck.helper, port: port.port).title, ActivitySignalCheck.helper)
                }
            }
        }
    }

    /// ⌃C typed into the pane (7.10): only while the pane's foreground
    /// group, read now, is the target's, and the target the one named.
    private func interrupt(_ holder: ActivityPortFree.Holder, port: ListeningPort, in pane: TerminalView, of tab: Tab) {
        let kernel = LiveActivityKernel()
        let foreground = pane.foregroundGroup
        let refusal = ActivityPortFree.interruptRefusal(
            listed: holder.signal.identity, group: holder.group, now: kernel.process(holder.signal.identity.pid), foregroundGroup: foreground,
            leader: foreground.flatMap { kernel.process($0)?.shortName })
        if let refusal { return tell("Not interrupted", refusal) }
        pane.pressControlC()
        watchFreed(port, freed: port.identity, in: pane, of: tab)
    }

    /// A signal through `ProcessSignals`, off the main thread: by the
    /// identity the census listed, a single process the person asked about.
    private func signal(_ signal: ActivitySignal, _ holder: ActivityPortFree.Holder, port: ListeningPort, in pane: TerminalView, of tab: Tab) {
        let target = holder.signal
        // The port's own holder is watched: terraform's plugin, when
        // terraform is the one signalled.
        let listed = port.identity
        DispatchQueue.global(qos: .userInitiated).async { @Sendable in
            let answer = ProcessSignals().send(signal, to: target, alone: true)
            Task { @MainActor [weak self, weak pane, weak tab] in
                guard let self, let pane, let tab else { return }
                if let said = ActivityPortFree.answer(answer, pid: target.identity.pid) { return self.tell("Not sent", said) }
                self.watchFreed(port, freed: listed, in: pane, of: tab)
            }
        }
    }

    /// The pane's own route for its `login` and shell (6.10): asked by
    /// Activity already, then Terraform's guard, then the close with no
    /// second alert.
    private func closeForFree(_ pane: TerminalView, in tab: Tab) {
        let split = tab.isSplit
        let proceed = { [weak self, weak tab, weak pane] in
            guard let self, let tab else { return }
            if split, let pane {
                self.removePane(pane, from: tab)
            } else {
                self.closeTabsWithoutAsking([tab])
            }
        }
        if terraformCloseGuard(tabs: [tab], panes: split ? [pane] : nil, path: split ? .pane : .tabs, proceed: proceed) { return }
        proceed()
    }

    /// How long a freed port is watched before the pill says it is still held.
    static let freeWatch: Duration = .seconds(10)
    /// How long the pill's last word stays.
    static let freeSaid: Duration = .seconds(6)

    /// Watches `port` after a Free: the one-off census, at most one every
    /// 2 s (7.1's spacing — any reader's answers the watch too), for 10 s,
    /// until nothing of the user's holds it, a process started since the
    /// Free does ("came back as pid N"), or the watch ends with it still
    /// held. `freed`: the process the pill listed on the port — not the one
    /// signalled, terraform over its plugin —; nil for a container's or a
    /// forward's port, which only says free or still held.
    func watchFreed(_ port: ListeningPort, freed: ActivityProcessID?, in pane: TerminalView, of tab: Tab) {
        let freeing = PortFreeing(pane: ObjectIdentifier(pane), port: port.port, proto: port.proto, state: .freeing)
        let sentAt = PortFreeing.now()
        Self.say(freeing, on: tab)
        Task { @MainActor [weak tab] in
            var said = freeing
            said.state = await Self.watchPort(port.port, proto: port.proto, freed: freed, sentAt: sentAt)
            guard let tab else { return }
            Self.say(said, on: tab)
            try? await Task.sleep(for: Self.freeSaid)
            tab.portFreeing.removeAll { $0 == said }
        }
    }

    /// What became of `port` after a Free sent at `sentAt`: the one-off
    /// census, at most one every 2 s (7.1's spacing — any reader's answers
    /// the watch too), for 10 s, until nothing of the user's holds it, a
    /// process started since the Free does ("came back as pid N"), or the
    /// watch ends with it still held — never a bind of the port (6.8).
    /// `freed`: the process listed on the port, nil for one an owner holds.
    static func watchPort(_ port: Int, proto: String, freed: ActivityProcessID?, sentAt: UInt64) async -> PortFreeing.State {
        let clock = ContinuousClock()
        let deadline = clock.now + Self.freeWatch
        var state = PortFreeing.State.freeing
        var last: [ActivityProcessID] = []
        // Bounded however the census answers: 500 ms apart, past the deadline.
        for _ in 0..<40 where state == .freeing {
            try? await Task.sleep(for: .milliseconds(500))
            let final = clock.now >= deadline
            guard let snapshot = await ActivityMonitor.shared.census() else {
                if final { break }
                continue
            }
            last = ListeningPorts.holders(of: port, proto: proto, in: snapshot)
            state = PortFreeing.state(holders: last, freed: freed, sentAt: sentAt, final: final)
        }
        // No read said otherwise by the deadline: still held, by what the
        // last one found — or, with none, by the one freed.
        if state == .freeing {
            state = last.isEmpty ? .stillHeld(pid: freed?.pid) : PortFreeing.state(holders: last, freed: freed, sentAt: sentAt, final: true)
        }
        return state
    }

    /// `freeing` in place of what its pane said of its port before.
    private static func say(_ freeing: PortFreeing, on tab: Tab) {
        tab.portFreeing.removeAll { $0.pane == freeing.pane && $0.port == freeing.port && $0.proto == freeing.proto }
        tab.portFreeing.append(freeing)
    }
}
