import AppKit

/// Free :N on the Activity page (docs/design/activity/analysis.md, 6.8,
/// Free :N): through the owner's own verb, asked first — every step asks,
/// the owners' too, though Docker's Stop and Kubernetes' Stop Forward act
/// at once when called —, and for the user's own process Activity's own
/// verb, as its class asks (`ActivityPortHolder.Plan`). The holder is read
/// again from a fresh census as the sheet opens: a port that changed hands
/// since the row was drawn is said, never asked about as it was; and again
/// at the button. After the step the port is watched with the census's
/// socket walk — never a bind, which would break a supervisor's rebind —
/// and the page's header says what became of it.
extension TerminalWindowController {
    /// `f` on `row`, or its Free verb.
    func activityFree(_ row: ActivityPortRow) {
        guard let step = ActivityPortHolder.step(for: row) else { return NSSound.beep() }
        switch step {
        case .refused(let reason):
            let said = ActivityPortFree.refusal(reason, port: row.port)
            return tell(said.title, said.detail)
        case .stopHolder:
            return freeOwn(row, step)
        default:
            break
        }
        Task { @MainActor [weak self] in
            // 6.8: the plan made again from a fresh read as the sheet opens.
            if let snapshot = await ActivityMonitor.shared.census(),
                let changed = ActivityPortHolder.changed(
                    row, step: step, holders: ListeningPorts.holders(of: row.port, proto: row.proto, in: snapshot), snapshot: snapshot)
            {
                self?.tell("Not freed", changed)
                return
            }
            self?.askToFree(row, step)
        }
    }

    private func askToFree(_ row: ActivityPortRow, _ step: ActivityPortHolder.Step) {
        guard let window else { return }
        if case .stopContainer(let name, _) = step, DockerModel.shared.container(name)?.State != "running" {
            return tell("Not freed", "Container “\(DockerMCP.displayed(name))” no longer runs: nothing was asked, nothing done.")
        }
        guard let question = ActivityPortHolder.question(step, row: row) else { return }
        // Every Free asks (D-10): no setting skips it.
        confirmation(question).present(on: window) { [weak self] _ in self?.performFree(step, row) }
    }

    /// The owner's verb, once asked. A scenario's recorder takes it
    /// instead — but a container's Stop, which then goes to the run's own
    /// fake engine.
    private func performFree(_ step: ActivityPortHolder.Step, _ row: ActivityPortRow) {
        let recorded = activityFreeRecorder != nil
        activityFreeRecorder?(step)
        if let refusal = Self.isolatedFreeRefusal(
            step, isolated: AppEnvironment.isIsolated, recorded: recorded, terminalRecorded: activityTerminalRecorder != nil)
        {
            return tell("Not freed", refusal)
        }
        switch step {
        case .stopContainer(let name, _):
            guard let container = DockerModel.shared.container(name) else {
                return tell("Not freed", "Container “\(DockerMCP.displayed(name))” is gone: nothing was done.")
            }
            dockerPage.act(.stop, on: [container])
            watchActivityFree(row, freed: nil)
        case .stopForward(let pid, _):
            guard !recorded else { return }
            guard let forward = KubeForwards.shared.forwards.first(where: { $0.pid == pid }) else {
                return tell("Not freed", "The forward ended or restarted since it was listed: nothing was done.")
            }
            KubeForwards.shared.stop(forward.id)
            watchActivityFree(row, freed: nil)
        case .disconnect(let name, let pid):
            guard !recorded else { return }
            // By ssh's pid to its connection's id: names aren't unique,
            // and a connection renamed while open keeps its tunnel's.
            let database = DatabaseModel.shared
            guard let tunnel = SSHTunnel.listed().first(where: { $0.pid == pid }) else {
                return tell("Not freed", "The tunnel closed since it was listed: nothing was done.")
            }
            guard let connection = database.store.connection(tunnel.connection) else {
                return tell("Not freed", "No connection owns the tunnel “\(DockerMCP.displayed(name))” now: nothing was done.")
            }
            database.disconnect(connection)
            watchActivityFree(row, freed: nil)
        case .stopService, .readRoute:
            guard let command = ActivityPortHolder.command(step, port: row.port, proto: row.proto) else { return }
            activityTerminal(ActivityTerminalRequest(directory: NSHomeDirectory(), command: command, run: ActivityPortHolder.runs(step)))
        case .airPlay:
            guard !recorded else { return }
            NSWorkspace.shared.open(ActivityPortHolder.airPlaySettings)
        case .refused, .stopHolder:
            break
        }
    }

    // MARK: The user's own process (6.8's rows a process of the user's holds)

    /// What a fresh read makes of a Free of the user's own holder.
    enum OwnFree: Sendable {
        case plan(ActivityPortHolder.Plan, holders: [ActivityProcessID])
        /// Nothing to ask: the port changed hands, or is free, or its holder
        /// is gone.
        case said(String)
    }

    /// The plan made from a fresh census (6.8: "made again when its sheet
    /// opens"), off the main thread: every holder of the port now, the
    /// listed one among them, read as the policy sees it.
    func ownFree(_ row: ActivityPortRow, _ step: ActivityPortHolder.Step) async -> OwnFree? {
        await activityRead { snapshot, owners, known in
            let holders = ListeningPorts.holders(of: row.port, proto: row.proto, in: snapshot)
            if let changed = ActivityPortHolder.changed(row, step: step, holders: holders, snapshot: snapshot) { return .said(changed) }
            guard let holder = row.holder,
                let subject = ActivityPortHolder.subject(of: holder, in: snapshot, owners: owners, known: known)
            else { return .said(":\(row.port)'s holder ended: nothing was asked, nothing done.") }
            let plan = ActivityPortHolder.plan(
                row, subject: ActivityPageModel.overlaid(subject, known: known), holders: holders, snapshot: snapshot, user: snapshot.uid)
            return .plan(plan, holders: holders)
        }
    }

    private func freeOwn(_ row: ActivityPortRow, _ step: ActivityPortHolder.Step) {
        Task { @MainActor [weak self] in
            guard let self, let window = self.window else { return }
            let read = await self.ownFree(row, step)
            guard case .plan(let plan, _)? = read else {
                if case .said(let said)? = read { return self.tell("Not freed", said) }
                return self.tell("Not freed", "The processes couldn't be read now: nothing was asked, nothing done.")
            }
            if let reason = plan.rule.refusal {
                let said = ActivityPortFree.refusal(reason, port: row.port)
                return self.tell(said.title, said.detail)
            }
            var pane: (title: String, isSplit: Bool)?
            if let (_, tab, _) = Self.activityPane(tag: plan.subject.pane) { pane = (tab.title, tab.isSplit) }
            guard let question = ActivityPortHolder.question(plan, scope: self.activityScope(plan.subject), pane: pane) else {
                let said = ActivityPortFree.refusal(ActivityPageModel.unavailable(plan.rule) ?? ActivityPageModel.routeElsewhere, port: row.port)
                return self.tell(said.title, said.detail)
            }
            // Every Free asks (D-10): no setting skips it.
            self.confirmation(question).present(on: window) { [weak self] _ in self?.freeOwnAtButton(row, step, asked: plan) }
        }
    }

    /// The button (6.10 step 4): the plan made again — the holder still on
    /// the port, read again, and the policy saying what it said — then
    /// what was asked, by the identity listed; the port watched after.
    private func freeOwnAtButton(_ row: ActivityPortRow, _ step: ActivityPortHolder.Step, asked: ActivityPortHolder.Plan) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var now: ActivityPortHolder.Plan?
            var holders: [ActivityProcessID] = []
            if case .plan(let plan, let held)? = await self.ownFree(row, step) {
                now = plan
                holders = held
            }
            if let changed = ActivityPortHolder.changedAtButton(asked, now: now, holders: holders) { return self.tell("Not freed", changed) }
            guard let now else { return }
            // A write over the holder is interrupted, never its plugin: the
            // watch then offers no Force Quit of the one it follows.
            let write = asked.holder == asked.subject.signal.identity ? nil : asked.subject.name
            self.activityPerform(.freePort, now.rule, now.subject, asked: asked.subject, after: .port(row, freed: asked.holder, write: write))
        }
    }

    /// What an isolated run (a scenario, a layout dump, a unit test) won't
    /// do of a Free nobody records (9.9, 10.6): run a service's stop in a
    /// real shell, or open System Settings. Signals are ProcessSignals'
    /// gate's; a container's Stop goes to the run's own engine. Pure.
    nonisolated static func isolatedFreeRefusal(_ step: ActivityPortHolder.Step, isolated: Bool, recorded: Bool, terminalRecorded: Bool) -> String? {
        guard isolated else { return nil }
        switch step {
        case .stopService where !terminalRecorded:
            return "An isolated run never stops a service: nothing was typed or run."
        case .airPlay where !recorded:
            return "An isolated run never opens System Settings: nothing was done."
        default:
            return nil
        }
    }

    /// The port watched after a Free's step, the page's header saying
    /// what became of it. `sentAt`: taken before the step went — what
    /// started after it came back.
    func watchActivityFree(_ row: ActivityPortRow, freed: ActivityProcessID?, write: String? = nil, sentAt: UInt64 = PortFreeing.now()) {
        let page = activityPage
        let freeing = PortFreeing.label(.freeing, port: row.port)
        page.freeing = freeing
        Task { @MainActor [weak page] in
            let state = await Self.watchPort(row.port, proto: row.proto, freed: freed, sentAt: sentAt)
            let said = Self.freeSaid(state, port: row.port, freed: freed, write: write)
            guard let page, page.freeing == freeing else { return }
            page.freeing = said
            try? await Task.sleep(for: Self.freeSaid)
            if page.freeing == said { page.freeing = nil }
        }
    }

    /// What the page's header says once the watch ends: the pill's words,
    /// and Force Quit offered while the one freed still holds it (6.8:
    /// "still listening after 5 s — Force Quit…"). `write`: the
    /// terraform write interrupted over the one freed, its plugin — never
    /// Force Quit, which would SIGKILL into the write: it is said to be
    /// still stopping instead. Pure.
    nonisolated static func freeSaid(_ state: PortFreeing.State, port: Int, freed: ActivityProcessID?, write: String? = nil) -> String {
        let said = PortFreeing.label(state, port: port)
        guard case .stillHeld(let pid?) = state, pid == freed?.pid else { return said }
        if let write { return said + " — “\(DockerMCP.displayed(write))” is still stopping" }
        return said + " — Force Quit… (K)"
    }

    /// A new tab for the page (6.10): in `request`'s folder, its command
    /// typed as the shell starts — run, or left for the person. The tab
    /// goes where `NewTabGroup.placement` puts it (`addTab`), the page put
    /// away. A scenario's recorder takes it instead.
    func activityTerminal(_ request: ActivityTerminalRequest) {
        if let activityTerminalRecorder { return activityTerminalRecorder(request) }
        if store.showingOverlay != nil { hideOverlay(focus: false) }
        let directory = URL(fileURLWithPath: request.directory, isDirectory: true)
        guard let command = request.command else { return newTab(in: directory) }
        if request.run { return newTab(in: directory, running: command) }
        newTab(in: directory, typing: command)
    }
}
