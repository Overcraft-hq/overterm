import AppKit

/// What the Activity page opens in a new tab (6.10: Terminal in Its
/// Folder, Sample, Open Files, the service's stop, the read route): a
/// folder, and a command typed into its shell — run, or left for the person
/// to run (Return theirs).
struct ActivityTerminalRequest: Equatable, Sendable {
    var directory: String
    var command: String?
    var run = true
}

/// Free :N on the Activity page (docs/design/activity/analysis.md, 6.8,
/// Free :N): through the owner's own verb, asked first — every step asks,
/// the owners' too, though Docker's Stop and Kubernetes' Stop Forward act
/// at once when called. The holder is read again from a fresh census as
/// the sheet opens: a port that changed hands since the row was drawn is
/// said, never asked about as it was. After a Stop Container, Stop Forward
/// or Disconnect the port is watched and the page's header says what
/// became of it.
extension TerminalWindowController {
    /// `f` on `row`, or its Free verb.
    func activityFree(_ row: ActivityPortRow) {
        guard let step = ActivityPortHolder.step(for: row) else { return NSSound.beep() }
        switch step {
        case .refused(let reason), .notYet(let reason):
            let said = ActivityPortFree.refusal(reason, port: row.port)
            return tell(said.title, said.detail)
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
        case .refused, .notYet:
            break
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

    /// The port watched after an owner's verb, the page's header saying
    /// what became of it.
    private func watchActivityFree(_ row: ActivityPortRow, freed: ActivityProcessID?) {
        let page = activityPage
        let freeing = PortFreeing.label(.freeing, port: row.port)
        page.freeing = freeing
        let sentAt = PortFreeing.now()
        Task { @MainActor [weak page] in
            let state = await Self.watchPort(row.port, proto: row.proto, freed: freed, sentAt: sentAt)
            let said = PortFreeing.label(state, port: row.port)
            guard let page, page.freeing == freeing else { return }
            page.freeing = said
            try? await Task.sleep(for: Self.freeSaid)
            if page.freeing == said { page.freeing = nil }
        }
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
