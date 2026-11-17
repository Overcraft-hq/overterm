import Darwin
import Foundation

/// The sheet a page verb asks with (docs/design/activity/analysis.md,
/// 6.10, The sheet): one `WriteConfirmation` — "Stop “vite” (pid 4242)?",
/// its tab, checkout and agent, then every character of what it names: the
/// executable `proc_pidpath` gave, its pid and start, the masked command,
/// its listeners, the children a Stop leaves running, the supervisor that
/// may start it again, a tree's or a group's members and what a bulk
/// leaves out, and the command it equals. Pure.
enum ActivityVerbQuestion {
    /// A bulk past this many asks for the count to be typed (D-12).
    static let typedCountAbove = 50
    /// Past this many targets, the critical style (D-12).
    static let criticalAbove = 10
    /// What a SIGUSR1 or SIGUSR2 opens in these (6.10's Send a Signal).
    static let debuggerRuntimes: Set<String> = ["node", "bun", "deno"]

    /// What the sheet says for `verb`, done as `action`, to `subject`.
    /// `scope`: "Tab “web” · feature-x · Claude". `pane`: for the close
    /// route, the tab's title and whether it is split.
    static func question(
        _ verb: ActivityVerb, _ rule: ActivityRule, subject: ActivityVerbSubject, scope: String?, pane: (title: String, isSplit: Bool)? = nil,
        timeZone: TimeZone = .current
    ) -> ActivityPortFree.Question? {
        let pid = subject.signal.identity.pid
        let name = DockerMCP.displayed(subject.name)
        let quoted = "“\(name)” (pid \(pid))"
        var lines: [String] = []
        switch rule {
        case .refused:
            return nil
        case .route(.closePane, _):
            let split = pane?.isSplit ?? true
            let title = split ? "Close this pane?" : "Close tab “\(DockerMCP.displayed(pane?.title ?? ""))”?"
            lines.append("\(quoted) is the pane's own shell: it ends with the pane — and whatever runs in it.")
            lines += identityLines(subject, timeZone: timeZone)
            return ActivityPortFree.Question(title: title, scope: scope, detail: lines.joined(separator: "\n"), button: split ? "Close Pane" : "Close Tab")
        case .route(.suspendTab, _), .route(.resumeTab, _):
            let suspend = rule == .route(.suspendTab, confirm: true) || rule == .route(.suspendTab, confirm: false)
            lines.append("\(quoted) is the pane's own shell: its tab is \(suspend ? "suspended" : "resumed") with it, as the tab's menu does.")
            return ActivityPortFree.Question(
                title: suspend ? "Suspend this tab?" : "Resume this tab?", scope: scope, detail: lines.joined(separator: "\n"),
                button: suspend ? "Suspend Tab" : "Resume Tab")
        case .route:
            return nil
        case .allowed(let action, _, let critical):
            var title: String
            var button: String
            var count = 1
            var members: [pid_t] = []
            switch action {
            case .interruptPane:
                if subject.target.kind == .agent, let agent = subject.agent {
                    title = "Interrupt \(agent.name)'s turn?"
                    button = "Interrupt Turn"
                    lines.append("⌃C is typed into \(agent.name)'s pane: it cancels the turn, and waits for you there.")
                } else {
                    title = "Interrupt \(quoted)?"
                    button = "Interrupt"
                    lines.append(
                        "⌃C is typed into its pane, as if you pressed it — not a SIGINT to its group: a full-screen program in raw mode reads it as a key, its own way.")
                }
            case .signal(let signal):
                (title, button) = words(verb, signal, subject: subject, quoted: quoted)
                lines += signalLines(signal, subject: subject)
            case .signalTree(let signal):
                let included = subject.tree.filter { $0.refusal == nil }
                count = included.count + 1
                members = [pid] + included.map(\.signal.identity.pid)
                title = "Stop \(quoted) and its tree — \(count) processes?"
                button = "Stop \(count) Processes"
                lines.append("Each is sent SIG\(signal.rawValue) by its own audit token, parents first, so a supervisor can't start again what follows:")
                lines += included.prefix(ActivityVerbSubject.memberLimit).map { "  pid \($0.signal.identity.pid) \(DockerMCP.displayed($0.name))" }
                let left = subject.tree.filter { $0.refusal != nil }
                if !left.isEmpty {
                    lines.append("Left out, each asked about alone:")
                    lines += left.map { "  pid \($0.signal.identity.pid) \(DockerMCP.displayed($0.name)) — \($0.refusal ?? "")" }
                }
            case .signalGroup(let signal):
                count = subject.groupMembers.count + 1
                if signal == .int {
                    // A terraform write leading its group: SIGINT as ⌃C
                    // would send it, its providers with it.
                    title = "Interrupt the process group \(subject.group) of \(quoted) — \(count) processes?"
                    button = "Interrupt Group"
                } else {
                    title = "Stop the process group \(subject.group) of \(quoted) — \(count) processes?"
                    button = "Stop Group"
                }
                lines.append("killpg(\(subject.group), SIG\(signal.rawValue)), once every member is checked again just before:")
                lines += subject.groupMembers.map { "  pid \($0.signal.identity.pid) \(DockerMCP.displayed($0.name))" }
            default:
                // Suspend, priority and an app's Quit ask with their own verbs.
                return nil
            }
            if let write = subject.target.terraformWrite {
                lines.append("A running \(DockerMCP.displayed(write)): SIGTERM or SIGKILL could leave its state locked and half written.")
            }
            if let write = subject.target.releaseWrite {
                lines.append("A running \(DockerMCP.displayed(write)): a release stopped mid-upgrade stays pending-upgrade.")
            }
            if subject.target.insideApp { lines.append("It runs inside an app: stopping a helper can leave its app broken, or start it again.") }
            lines += identityLines(subject, timeZone: timeZone)
            if !subject.listening.isEmpty { lines.append("It listens on \(subject.listening.map { ":\($0)" }.joined(separator: ", ")).") }
            if case .signal(let signal) = action, signal != .stop, signal != .cont, subject.children > 0 {
                lines.append(
                    subject.children == 1 ? "Its child keeps running — Stop Its Tree… ends it too." : "Its \(subject.children) children keep running — Stop Its Tree… ends them too.")
            }
            if let supervisor = subject.supervisor, action != .interruptPane {
                lines.append("“\(DockerMCP.displayed(supervisor.name))” (pid \(supervisor.pid)), its parent, may start it again — Stop Its Parent… is there.")
            }
            lines.append("The command it equals: \(ActivityPortFree.equals(action, pid: pid, members: members))")
            return ActivityPortFree.Question(
                title: title, scope: scope, detail: lines.joined(separator: "\n"), button: button, critical: critical || count > criticalAbove)
        }
    }

    /// Whether a bulk of `count` asks for its count to be typed.
    static func typesCount(_ count: Int) -> Bool { count > typedCountAbove }

    /// A single signal's title and button.
    private static func words(_ verb: ActivityVerb, _ signal: ActivitySignal, subject: ActivityVerbSubject, quoted: String) -> (String, String) {
        if case .send(let sent) = verb, sent != .term, sent != .kill {
            return ("Send SIG\(signal.rawValue) to \(quoted)?", "Send SIG\(signal.rawValue)")
        }
        switch signal {
        case .term:
            if subject.target.kind == .agent, let agent = subject.agent { return ("Stop \(agent.name) (pid \(subject.signal.identity.pid))?", "Stop Agent") }
            return ("Stop \(quoted)?", "Stop Process")
        case .kill: return ("Force Quit \(quoted)?", "Force Quit")
        case .int: return ("Interrupt \(quoted)?", "Interrupt")
        default: return ("Send SIG\(signal.rawValue) to \(quoted)?", "Send SIG\(signal.rawValue)")
        }
    }

    /// What a single signal does, said.
    private static func signalLines(_ signal: ActivitySignal, subject: ActivityVerbSubject) -> [String] {
        var lines: [String] = []
        switch signal {
        case .term:
            if subject.target.kind == .agent, let agent = subject.agent {
                lines.append("\(agent.name) stops mid-task; the pane goes back to its shell. `\(agent.resumeCommand)` picks the conversation up.")
            } else {
                lines.append("It is sent SIGTERM, by the process Overterm listed — its pid, start and executable — and nothing else.")
            }
        case .kill:
            lines.append("SIGKILL to this process alone, never its group: it skips its cleanup — pid files, children.")
        case .int where subject.target.terraformWrite != nil:
            lines.append("It is sent SIGINT alone — it stops safely, as for ⌃C — never the agent or shell whose group it shares.")
        case .usr1, .usr2:
            if debuggerRuntimes.contains(subject.name) {
                lines.append("SIG\(signal.rawValue) to \(subject.name) opens its debugger on 127.0.0.1:9229, which runs code for any local user who connects.")
            }
        default:
            break
        }
        if subject.target.stopped != nil, signal == .term || signal == .int, subject.target.stopped != .traced {
            lines.append("It is stopped: it is continued right after, so it can act on it.")
        }
        return lines
    }

    /// The identity the sheet names: the executable, the pid and start,
    /// the masked command.
    private static func identityLines(_ subject: ActivityVerbSubject, timeZone: TimeZone) -> [String] {
        var lines = [ActivityPortFree.executable(subject.signal.path)]
        let identity = subject.signal.identity
        lines.append("pid \(identity.pid), started \(ActivityPortFree.started(identity.start, timeZone: timeZone))")
        if let command = subject.command { lines.append("Command: \(DockerMCP.displayed(command))") }
        return lines
    }

    // MARK: Suspend, Resume, Lower Priority (6.10)

    /// Suspend's sheet, asked for an app, a helper inside one, a helm or
    /// pulumi write, Send a Signal ▸ STOP, and whenever more than one
    /// process is stopped: each listed, what is left out with why.
    static func suspend(_ subject: ActivityVerbSubject, members: [ActivitySignalTarget], scope: String?, timeZone: TimeZone = .current)
        -> ActivityPortFree.Question
    {
        let pid = subject.signal.identity.pid
        let quoted = "“\(DockerMCP.displayed(subject.name))” (pid \(pid))"
        let names = subject.memberNames
        var lines = ["SIGSTOP by each one's own audit token, parents first: nothing is lost, and it uses no CPU until resumed."]
        if members.count > 1 {
            lines.append("Stopped with its tree:")
            lines += members.dropFirst().map { "  pid \($0.identity.pid) \(DockerMCP.displayed(names[$0.identity] ?? ""))" }
        }
        let left = subject.tree.filter { $0.refusal != nil || $0.target.terraformWrite != nil }
        if !left.isEmpty {
            lines.append("Left running:")
            lines += left.map { "  pid \($0.signal.identity.pid) \(DockerMCP.displayed($0.name)) — \($0.refusal ?? ActivitySignalCheck.terraformSuspend)" }
        }
        if subject.target.isApp || subject.target.insideApp {
            lines.append("A stopped app stops answering — its windows, its menus, and any app that waits on a helper of it.")
        }
        if let write = subject.target.releaseWrite {
            lines.append("A running \(DockerMCP.displayed(write)): stopped, it holds its release where it is until resumed.")
        }
        lines += identityLines(subject, timeZone: timeZone)
        if !subject.listening.isEmpty {
            lines.append("It listens on \(subject.listening.map { ":\($0)" }.joined(separator: ", ")): connections to it wait while it is stopped.")
        }
        lines.append("Resume it here, or with Resume All in the page's header; quitting Overterm asks first.")
        lines.append("The command it equals: kill -STOP \(members.map { "\($0.identity.pid)" }.joined(separator: " "))")
        let many = members.count > 1
        return ActivityPortFree.Question(
            title: many ? "Suspend \(quoted) and its tree — \(members.count) processes?" : "Suspend \(quoted)?", scope: scope,
            detail: lines.joined(separator: "\n"), button: many ? "Suspend \(members.count) Processes" : "Suspend",
            critical: members.count > criticalAbove)
    }

    /// Send a Signal ▸ STOP to a pane's job or agent: Suspend's own route —
    /// the pane suspended with it, its shell first —, asked as every Send a
    /// Signal is. `tab`: the tab's title.
    static func suspendPane(_ subject: ActivityVerbSubject, tab: String, scope: String?, timeZone: TimeZone = .current) -> ActivityPortFree.Question {
        let pid = subject.signal.identity.pid
        let quoted = "“\(DockerMCP.displayed(subject.name))” (pid \(pid))"
        var lines = [
            "It runs in a pane of “\(DockerMCP.displayed(tab))”: the pane is suspended with it — its shell first, or the shell takes the terminal back, then every process in it —, as Suspend Tab does.",
            "Resume it with the tab's Resume, or the pane's.",
        ]
        lines += identityLines(subject, timeZone: timeZone)
        lines.append("The command it equals: kill -STOP to the pane's shell, then kill -STOP \(pid) and the rest of the pane")
        return ActivityPortFree.Question(
            title: "Suspend \(quoted) with its pane?", scope: scope, detail: lines.joined(separator: "\n"), button: "Suspend Pane")
    }

    /// Resume's sheet — and Resume All's —, asked for an app and whenever
    /// more than one process is continued: `members` parents first, with
    /// the names they were stopped as.
    static func resume(title: String, members: [(target: ActivitySignalTarget, name: String)], scope: String?) -> ActivityPortFree.Question {
        var lines = ["SIGCONT by each one's own audit token, children first, only while it is still the process Activity stopped:"]
        lines += members.map { "  pid \($0.target.identity.pid) \(DockerMCP.displayed($0.name))" }
        lines.append("The command it equals: kill -CONT \(members.reversed().map { "\($0.target.identity.pid)" }.joined(separator: " "))")
        return ActivityPortFree.Question(
            title: title, scope: scope, detail: lines.joined(separator: "\n"), button: members.count > 1 ? "Resume \(members.count) Processes" : "Resume")
    }

    /// Lower Priority's sheet: asked every time, since it can't be undone
    /// without an administrator.
    static func lower(_ subject: ActivityVerbSubject, to nice: Int32, scope: String?, timeZone: TimeZone = .current) -> ActivityPortFree.Question {
        let pid = subject.signal.identity.pid
        var lines = [
            "Its nice goes from \(subject.nice) to \(nice): it gets the CPU after what runs at a lower nice.",
            "It can't be raised back without an administrator (sudo renice): macOS lets you only lower a process's priority.",
        ]
        if subject.children > 0 { lines.append("Only this process: its children keep their own priority; what it starts from now on inherits it.") }
        lines += identityLines(subject, timeZone: timeZone)
        lines.append("The command it equals: \(ActivityPriorityChange.nice(nice).command(for: pid))")
        return ActivityPortFree.Question(
            title: "Lower the priority of “\(DockerMCP.displayed(subject.name))” (pid \(pid)) to nice \(nice)?", scope: scope,
            detail: lines.joined(separator: "\n"), button: "Lower Priority")
    }

    /// "Stop it first?" (D-11): `K` with no Stop before it.
    static func stopFirst(_ subject: ActivityVerbSubject) -> (title: String, detail: String) {
        (
            "SIGKILL skips its cleanup: pid files, children. Stop it first?",
            "“\(DockerMCP.displayed(subject.name))” (pid \(subject.signal.identity.pid)) is sent SIGTERM by Stop and can clean up; Force Quit ends it at once — "
                + "asked next with its own sheet: its executable, its command and the command it equals."
        )
    }
}
