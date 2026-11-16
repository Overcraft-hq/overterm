import Darwin
import Foundation

/// Free :N on the page (docs/design/activity/analysis.md, 6.8, Free :N;
/// 6.10): what a Listening row's owner decides — its own verb, asked here
/// first. Stage 1 frees a port only through the owners' verbs: Stop
/// Container (Docker's page), Stop Forward (`KubeForwards`), Disconnect (the
/// database's tunnel), Stop the Service (`launchctl bootout` or `brew
/// services stop`, typed into a new tab — never a SIGTERM, which KeepAlive
/// undoes), AirPlay Receiver's switch in System Settings (opened, never
/// changed by the app), and the read route for another user's (`sudo lsof`
/// typed with no Return). Stopping the user's own processes is the verbs'
/// stage (2): a pane's port pill frees those now. Pure.
enum ActivityPortHolder {
    /// What freeing a row's port takes.
    enum Step: Hashable, Sendable {
        /// A local engine's container publishes it: the Docker page's Stop.
        case stopContainer(name: String, project: String?)
        /// Overterm's own `kubectl port-forward`, by kubectl's pid.
        case stopForward(pid: pid_t, target: String)
        /// A database's `ssh -L`, by ssh's pid: the connection's Disconnect.
        case disconnect(name: String, pid: pid_t)
        /// A launchd job of the user's: its own stop, typed into a new tab.
        case stopService(LaunchdJobs.Job)
        /// AirPlay Receiver (ControlCenter on 5000 or 7000): its switch.
        case airPlay
        /// Another user's: `sudo lsof` typed into a new tab, no Return.
        case readRoute(user: String)
        /// Nothing here frees it; why.
        case refused(String)
        /// The user's own process: Activity's own Stop comes with its
        /// verbs (stage 2); why, and where it is freed now.
        case notYet(String)
    }

    /// The step for `row`'s port, by the owner Listening found (6.8): its
    /// first matching owner decides. Nil for what has no port to free — a
    /// connection, the ephemeral fold.
    static func step(for row: ActivityPortRow) -> Step? {
        guard row.kind == .listener else { return nil }
        switch row.portOwner {
        case .container(let name, let project):
            return .stopContainer(name: name, project: project)
        case .forward(let target):
            guard let pid = row.holder?.pid, pid > 0 else { return .refused("The forward is restarting: free it again in a moment.") }
            return .stopForward(pid: pid, target: target)
        case .tunnel(let name):
            guard let pid = row.holder?.pid, pid > 0 else { return .refused("The tunnel has no process now.") }
            return .disconnect(name: name, pid: pid)
        case .bridge:
            return .refused("Overterm's agent bridge: it closes when no agent setting needs it (Settings ▸ Agents).")
        case .overterm:
            return .refused("Overterm's own: it closes with what opened it, and when Overterm quits.")
        case .anotherOverterm:
            return .refused("Another Overterm's: quit it there.")
        case .engine(let engine):
            return .refused("\(engine)’s engine holds every container's ports: stop a container, or quit \(engine) from its menu.")
        case .known(let holder):
            if holder == KnownHolders.airPlay { return .airPlay }
            if holder.word == "container" {
                return .refused("\(holder.name) holds every container's ports: stop a container, or quit the engine from its menu.")
            }
            if holder.word == "macos" { return .refused("Part of macOS; it would start again.") }
            return .notYet("\(holder.note).")
        case .service(let job):
            // Typed and run as keystrokes: a label any process can set
            // through its environment runs nothing but launchd's own.
            guard launchdLabel(job.label) else { return .refused("Its label holds characters a shell would act on: stop it where it runs.") }
            return .stopService(job)
        case .macOS:
            return .refused("Part of macOS; it would start again.")
        case .system(let user):
            return .readRoute(user: user)
        case .pane:
            return .notYet("A tab's process: its pane's port pill frees it (Free…). Activity's own Stop comes with its verbs.")
        case .app:
            return .notYet("An app's: quit the app. Activity's own Quit comes with its verbs.")
        case .elsewhere:
            return .notYet("Started outside Overterm's tabs: stop it where it runs. Activity's own Stop comes with its verbs.")
        }
    }

    /// Why the Free verb is greyed for `row`; nil when it can run.
    static func unavailable(_ row: ActivityPortRow) -> String? {
        switch step(for: row) {
        case nil: return "Only a listening port is freed"
        case .refused(let reason)?, .notYet(let reason)?: return reason
        default: return nil
        }
    }

    /// The verb's name for `step`: the owner's own.
    static func title(_ step: Step, port: Int) -> String {
        switch step {
        case .stopContainer: "Stop Container…"
        case .stopForward: "Stop Forward…"
        case .disconnect: "Disconnect…"
        case .stopService: "Stop the Service…"
        case .airPlay: "Turn Off AirPlay Receiver…"
        case .readRoute: "Who Holds :\(port)…"
        case .refused, .notYet: "Free :\(port)…"
        }
    }

    /// The command a step types into a new tab: the service's own stop,
    /// or the read route's `lsof`. `uid`, the gui domain's. Nil for a step
    /// that types nothing.
    static func command(_ step: Step, port: Int, proto: String, uid: uid_t = getuid()) -> String? {
        switch step {
        case .stopService(let job):
            guard launchdLabel(job.label) else { return nil }
            if let formula = job.formula { return "brew services stop \(ActivityPortHolder.quoted(formula))" }
            return "launchctl bootout gui/\(uid)/\(quoted(job.label))"
        case .readRoute:
            let family = proto == "udp" ? "-iUDP:\(port)" : "-iTCP:\(port) -sTCP:LISTEN"
            return "sudo lsof -nP \(family)"
        default:
            return nil
        }
    }

    /// Whether the command is run (Return pressed) or left for the person:
    /// the read route asks for a password and so is only typed.
    static func runs(_ step: Step) -> Bool {
        if case .stopService = step { return true }
        return false
    }

    /// AirPlay Receiver's switch: System Settings ▸ General ▸ AirDrop &
    /// Handoff, opened — the app changes no setting itself.
    static let airPlaySettings = URL(string: "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension")!

    /// Whether `label` is made of launchd's label characters alone — what
    /// a service's stop may type (its formula is part of it). The label is
    /// the process's own `XPC_SERVICE_NAME`, which any process can set, and
    /// a command typed into a shell reaches its line editor as keys: a
    /// control character inside quotes still acts (^C or ^U drops the
    /// line, a return accepts it, ESC runs a widget).
    static func launchdLabel(_ label: String) -> Bool {
        !label.isEmpty && label.utf8.count <= 255
            && label.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._@+-".unicodeScalars.contains(scalar))
            }
    }

    /// A word for a shell, single-quoted when it needs to be.
    static func quoted(_ word: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(plain.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The question before `step` (6.8's table), as `WriteConfirmation`
    /// asks it; nil for a refusal, which asks nothing.
    static func question(_ step: Step, row: ActivityPortRow, uid: uid_t = getuid()) -> ActivityPortFree.Question? {
        let port = row.port
        let holder = row.holder.map { "\(DockerMCP.displayed(row.process)) (pid \($0.pid))" }
        switch step {
        case .stopContainer(let name, let project):
            var question = ActivityPortFree.containerQuestion(name, port: port)
            question.scope =
                ([project.map { "compose project \(DockerMCP.displayed($0))" }, row.checkout.map { "checkout \(DockerMCP.displayed($0))" }]
                .compactMap { $0 }).joined(separator: " · ")
            if question.scope?.isEmpty == true { question.scope = nil }
            return question
        case .stopForward(let pid, let target):
            return ActivityPortFree.Question(
                title: "Stop the forward to \(DockerMCP.displayed(target))?", scope: row.tabTitle.map { "from tab “\(DockerMCP.displayed($0))”" },
                detail: "Overterm's own kubectl port-forward (pid \(pid)) holds :\(port). Stop Forward ends it and frees the port; the pods aren't touched.",
                button: "Stop Forward")
        case .disconnect(let name, let pid):
            return ActivityPortFree.Question(
                title: "Disconnect “\(DockerMCP.displayed(name))”?",
                detail: "Its ssh tunnel (pid \(pid)) holds :\(port). Disconnect closes the connection and its tunnel, as the Database's Disconnect does.",
                button: "Disconnect")
        case .stopService(let job):
            let command = command(step, port: port, proto: row.proto, uid: uid) ?? ""
            return ActivityPortFree.Question(
                title: "\(DockerMCP.displayed(job.label)) holds :\(port) — stop the service?", scope: holder,
                detail:
                    "A service launchd keeps running: a SIGTERM would only see it started again. Its own stop is typed and run in a new tab:\n\(DockerMCP.displayed(command))",
                button: "Stop the Service")
        case .airPlay:
            return ActivityPortFree.Question(
                title: "AirPlay Receiver holds :\(port)",
                detail:
                    "ControlCenter holds it while AirPlay Receiver is on. It is turned off in System Settings ▸ General ▸ AirDrop & Handoff, which opens there; Overterm changes no setting itself.",
                button: "Open System Settings")
        case .readRoute(let user):
            let command = command(step, port: port, proto: row.proto, uid: uid) ?? ""
            let owner = user.isEmpty ? "another user" : DockerMCP.displayed(user)
            return ActivityPortFree.Question(
                title: "Owned by \(owner): Overterm doesn't signal it", scope: holder,
                detail:
                    "Overterm signals only your own processes, and never asks for a password. To see who holds :\(port), this is typed into a new tab — Return is yours to press:\n\(command)",
                button: "Type It in a New Tab")
        case .refused, .notYet:
            return nil
        }
    }

    /// Whether what the sheet would ask of is still what holds the port —
    /// read from a fresh census as the sheet opens (6.8: "the plan is made
    /// again"). `holders`: the user's processes holding it now. Nil: ask;
    /// else what is said instead, and nothing is asked.
    static func changed(_ row: ActivityPortRow, step: Step, holders: [ActivityProcessID], snapshot: ActivitySnapshot) -> String? {
        switch step {
        case .stopContainer, .readRoute:
            // The engine's or another user's: not among the user's own
            // holders to check; the container's running state is checked
            // as the sheet opens. AirPlay's ControlCenter is the user's own
            // process, checked as the rest are.
            return nil
        default:
            break
        }
        guard let listed = row.holder else { return nil }
        if holders.contains(listed) { return nil }
        if let now = holders.min(by: { $0.start < $1.start }) {
            let name = snapshot.name(of: now) ?? snapshot.table.process(now)?.shortName ?? "a process"
            return ":\(row.port) is now held by \(DockerMCP.displayed(name)) (pid \(now.pid)): nothing was asked — free it again to be asked about what it is now."
        }
        return ":\(row.port) is free now: nothing was asked, nothing done."
    }
}
