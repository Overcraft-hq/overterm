import Darwin
import Foundation

/// Closing a pane where terraform writes (analysis 4.8): a pane's close
/// sends SIGHUP, and terraform dies at once — no graceful stop, the lock
/// left held, what it was creating unrecorded (spike 11). Overterm's own
/// applies are detached and never in a pane; this is for terraform typed
/// there, a person's or an agent's. Consulted by all four close paths —
/// a pane, tabs, the window, quitting — whatever the close setting says.
/// The decision is pure; `find` walks the panes' trees by pid (never
/// `pkill -f`, never `lazy.compactMap(…).first`).
package enum TerraformCloseGuard {
    package enum Path: Sendable, Equatable {
        case pane, tabs, window, quit
    }

    /// One terraform that closing would kill.
    package struct Running: Equatable, Sendable {
        package var pid: pid_t
        /// Its process group: SIGINT goes to the group when terraform leads it.
        package var group: pid_t?
        /// `apply`, `state rm`…
        package var operation: String
        package var tool: String
        /// The root it works in, as the header says it: `envs/prod`.
        package var root: String
        /// Which pane: "this pane", or the tab's title.
        package var place: String
        /// The pane's process tag: its header says "shutting down" after Interrupt.
        package var tag: String? = nil
        /// When it started, µs since 1970, and its executable, as `find`
        /// read them: who Interrupt may reach (`ProcessSignals`). Nil when
        /// unread — it had ended as `find` looked —, and then Interrupt
        /// reaches nobody: whatever holds the pid by the press isn't the
        /// terraform the close asked about.
        package var started: UInt64? = nil
        package var path: String? = nil
    }

    /// What the close asks.
    package struct Question: Equatable, Sendable {
        package var title: String
        package var detail: String
        package static let buttons = ["Interrupt", "Close Anyway", "Cancel"]
    }

    /// The operations whose death mid-way loses state (4.8): apply,
    /// destroy, import, any `state`, `force-unlock`, `workspace delete`;
    /// and `-auto-approve` or a state migration whatever the verb.
    package static func isGuarded(_ line: TerraformCommandLine) -> Bool {
        if line.autoApprove || line.migratesState { return true }
        guard let operation = line.operation else { return false }
        let first = operation.split(separator: " ").first.map(String.init) ?? operation
        if ["apply", "destroy", "import", "state", "force-unlock", "apply-all", "destroy-all", "taint", "untaint", "refresh"].contains(first) { return true }
        if operation == "workspace delete" { return true }
        if operation.hasPrefix("run --all apply") || operation.hasPrefix("run --all destroy") || operation.hasPrefix("run-all apply")
            || operation.hasPrefix("run-all destroy") || operation == "run apply" || operation == "run destroy"
        {
            return true
        }
        return false
    }

    /// What closing asks for `running` along `path`, or nil when nothing
    /// guarded runs.
    package static func question(_ running: [Running], path: Path) -> Question? {
        guard let first = running.first else { return nil }
        let command = "\(first.tool) \(first.operation)"
        let place = first.place
        let more = running.count > 1 ? " (and \(running.count - 1) more terraform write\(running.count == 2 ? "" : "s"))" : ""
        let closing: String =
            switch path {
            case .pane: "Closing"
            case .tabs: "Closing the tab"
            case .window: "Closing the window"
            case .quit: "Quitting"
            }
        return Question(
            title: "\(command) is running in \(first.root) (\(place))\(more).",
            detail:
                "\(closing) kills it at once: the lock may stay held and what it was creating may be lost. Interrupt stops it gracefully, as Ctrl-C does — running resources may be left tainted — and keeps the pane open until it has stopped."
        )
    }

    /// Where Interrupt sends SIGINT: the group when terraform leads it (a
    /// shell's job, as Ctrl-C would), else terraform alone — never the
    /// agent or shell whose group it shares. Negative for a group, as
    /// `kill` takes it.
    package static func interruptTarget(_ running: Running) -> pid_t {
        if let group = running.group, group == running.pid { return -group }
        return running.pid
    }

    /// The terraform writes under each of `panes` (tag, its login pid,
    /// what to call it). Blocking, a process walk; read nothing but argv,
    /// folder and the environment's names (`TerraformProcesses`).
    package static func find(_ panes: [(login: pid_t, place: String, checkout: URL?, tag: String?)]) -> [Running] {
        var found: [Running] = []
        for pane in panes {
            for process in TerraformProcesses.find(under: pane.login) where isGuarded(process.line) {
                let folder = process.folder
                var root = folder?.lastPathComponent ?? "?"
                if let folder, let checkout = pane.checkout {
                    let base = checkout.standardizedFileURL.path
                    let path = folder.standardizedFileURL.path
                    if path.hasPrefix(base + "/") { root = String(path.dropFirst(base.count + 1)) } else if path == base { root = "." }
                }
                found.append(
                    Running(
                        pid: process.pid, group: ProcessInspector.processGroup(of: process.pid), operation: process.line.operation ?? "apply",
                        tool: process.line.tool, root: root, place: pane.place, tag: pane.tag, started: process.started,
                        path: TerraformApplyMarker.executablePath(process.pid)))
            }
        }
        return found
    }

    /// Interrupt: SIGINT to each, by pid or its own group
    /// (`interruptTarget`, the rule kept exactly), through the one signal
    /// path (docs/design/activity/analysis.md, 6.10): by the identity
    /// `find` read, so a terraform that ended since leaves its pid's next
    /// holder alone, and a group only when every member is terraform's —
    /// its leader's session, started under it, the user's. A group that
    /// isn't is refused and nothing is sent: the caller says so
    /// (`notInterrupted`). What each send did, in `running`'s order.
    @discardableResult
    package static func interrupt(_ running: [Running], signals: ProcessSignals = ProcessSignals()) -> [ActivitySignalAnswer] {
        running.map { process in
            guard let target = target(process) else { return .ended(now: nil) }
            if interruptTarget(process) < 0 { return signals.sendToGroup(.int, leader: target) }
            return signals.send(.int, to: target, alone: true)
        }
    }

    /// Who `running` is, as `find` read it; nil when it read no start.
    package static func target(_ running: Running) -> ActivitySignalTarget? {
        guard let started = running.started else { return nil }
        return ActivitySignalTarget(ActivityProcessID(pid: running.pid, start: started), path: running.path)
    }

    /// Whether Interrupt reached it, or it had ended: either way the close
    /// may wait for it to be gone.
    package static func reached(_ answer: ActivitySignalAnswer) -> Bool {
        switch answer {
        case .sent, .ended: true
        case .refused, .failed, .ranAnotherProgram: false
        }
    }

    /// What the window says when Interrupt didn't reach some of them —
    /// refused, failed, or their pid running another program now: nothing
    /// was sent to those, and the close isn't waiting on them. Nil when
    /// every one was reached.
    package static func notInterrupted(_ running: [Running], answers: [ActivitySignalAnswer]) -> Question? {
        let missed = zip(running, answers).filter { !reached($0.1) }
        guard let (first, answer) = missed.first else { return nil }
        let more = missed.count > 1 ? " and \(missed.count - 1) more" : ""
        let why: String =
            switch answer {
            case .refused(let refusal): refusal.reason
            case .failed(let errno): "macOS refused the signal (\(String(cString: strerror(errno))))."
            case .ranAnotherProgram: "Its process runs another program now."
            case .sent, .ended: ""
            }
        return Question(
            title: "Interrupt didn't reach \(first.tool) \(first.operation) in \(first.root) (\(first.place))\(more).",
            detail: "\(why) Nothing was sent to it. Close again to choose Close Anyway, or stop it in its pane.")
    }

    /// Whether any of them still runs.
    package static func anyAlive(_ running: [Running]) -> Bool {
        running.contains { TerraformRunFolder.isAlive($0.pid) }
    }

    /// What the notice says once interrupted writes have stopped (4.8),
    /// and its buttons: Close Now finishes the close Interrupt held back.
    package static func stoppedNotice(_ running: [Running], path: Path) -> Question? {
        guard let first = running.first else { return nil }
        let closing: String =
            switch path {
            case .pane: "Close the pane now, or keep it open"
            case .tabs: "Close the tab now, or keep it open"
            case .window: "Close the window now, or keep it open"
            case .quit: "Quit now, or keep Overterm open"
            }
        return Question(
            title: "\(first.tool) \(first.operation) has stopped in \(first.root) (\(first.place)).",
            detail: "Its state was saved as Terraform left it: resources it was changing may be tainted. \(closing).")
    }

    package static let stoppedButtons = ["Close Now", "Keep Open"]

    /// What a pane's header says while an interrupted write shuts down.
    package static func shuttingDown(_ running: Running) -> String { "\(running.tool) \(running.operation) shutting down — interrupted" }

    /// What quitting asks while Overterm's own detached applies run (4.7):
    /// they go on — quitting never waits on a graceful stop.
    package static func quitQuestion(_ applies: [(name: String, since: Date)]) -> Question? {
        guard let first = applies.first else { return nil }
        let more = applies.count > 1 ? " and \(applies.count - 1) more" : ""
        return Question(
            title: "An apply in \(first.name)\(more) is running.",
            detail:
                "It runs on its own: quitting lets it finish, and Overterm follows it again at the next launch. Stop it from the Terraform pane to stop it now (gracefully).")
    }

    /// What quitting asks while a `terraform test` with real providers
    /// runs (4.7, 4.8): it is a write in the app's group, so quitting cuts
    /// it off, cleanup and all — what it created stays. Interrupt stops
    /// it gracefully (its cleanup runs) and keeps Overterm open.
    package static func testQuestion(_ tests: [(name: String, since: Date)]) -> Question? {
        guard let first = tests.first else { return nil }
        let more = tests.count > 1 ? " and \(tests.count - 1) more" : ""
        return Question(
            title: "A terraform test with real providers in \(first.name)\(more) is running.",
            detail:
                "Quitting cuts it off: its cleanup would be cut off too, and the resources it created stay. Interrupt stops it gracefully — it destroys what it created — and keeps Overterm open; quit again once it has stopped."
        )
    }

    package static let testButtons = ["Interrupt", "Quit Anyway", "Cancel"]
}
