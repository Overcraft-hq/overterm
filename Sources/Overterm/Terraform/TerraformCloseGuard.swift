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
enum TerraformCloseGuard {
    enum Path: Sendable, Equatable {
        case pane, tabs, window, quit
    }

    /// One terraform that closing would kill.
    struct Running: Equatable, Sendable {
        var pid: pid_t
        /// Its process group: SIGINT goes to the group when terraform leads it.
        var group: pid_t?
        /// `apply`, `state rm`…
        var operation: String
        var tool: String
        /// The root it works in, as the header says it: `envs/prod`.
        var root: String
        /// Which pane: "this pane", or the tab's title.
        var place: String
        /// The pane's process tag: its header says "shutting down" after Interrupt.
        var tag: String? = nil
    }

    /// What the close asks.
    struct Question: Equatable, Sendable {
        var title: String
        var detail: String
        static let buttons = ["Interrupt", "Close Anyway", "Cancel"]
    }

    /// The operations whose death mid-way loses state (4.8): apply,
    /// destroy, import, any `state`, `force-unlock`, `workspace delete`;
    /// and `-auto-approve` or a state migration whatever the verb.
    static func isGuarded(_ line: TerraformCommandLine) -> Bool {
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
    static func question(_ running: [Running], path: Path) -> Question? {
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
    static func interruptTarget(_ running: Running) -> pid_t {
        if let group = running.group, group == running.pid { return -group }
        return running.pid
    }

    /// The terraform writes under each of `panes` (tag, its login pid,
    /// what to call it). Blocking, a process walk; read nothing but argv,
    /// folder and the environment's names (`TerraformProcesses`).
    static func find(_ panes: [(login: pid_t, place: String, checkout: URL?, tag: String?)]) -> [Running] {
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
                        tool: process.line.tool, root: root, place: pane.place, tag: pane.tag))
            }
        }
        return found
    }

    /// Interrupt: SIGINT to each, by pid or its own group.
    static func interrupt(_ running: [Running]) {
        for process in running { kill(interruptTarget(process), SIGINT) }
    }

    /// Whether any of them still runs.
    static func anyAlive(_ running: [Running]) -> Bool {
        running.contains { TerraformRunFolder.isAlive($0.pid) }
    }

    /// What the notice says once interrupted writes have stopped (4.8),
    /// and its buttons: Close Now finishes the close Interrupt held back.
    static func stoppedNotice(_ running: [Running], path: Path) -> Question? {
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

    static let stoppedButtons = ["Close Now", "Keep Open"]

    /// What a pane's header says while an interrupted write shuts down.
    static func shuttingDown(_ running: Running) -> String { "\(running.tool) \(running.operation) shutting down — interrupted" }

    /// What quitting asks while Overterm's own detached applies run (4.7):
    /// they go on — quitting never waits on a graceful stop.
    static func quitQuestion(_ applies: [(name: String, since: Date)]) -> Question? {
        guard let first = applies.first else { return nil }
        let more = applies.count > 1 ? " and \(applies.count - 1) more" : ""
        return Question(
            title: "An apply in \(first.name)\(more) is running.",
            detail:
                "It runs on its own: quitting lets it finish, and Overterm follows it again at the next launch. Stop it from the Terraform pane to stop it now (gracefully).")
    }
}
