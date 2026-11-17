import Darwin
import Foundation

/// Free :N on the page (docs/design/activity/analysis.md, 6.8, Free :N;
/// 6.10): what a Listening row's owner decides — its own verb, asked here
/// first: Stop Container (Docker's page), Stop Forward (`KubeForwards`),
/// Disconnect (the database's tunnel), Stop the Service (`launchctl
/// bootout` or `brew services stop`, typed into a new tab — never a
/// SIGTERM, which KeepAlive undoes), AirPlay Receiver's switch in System
/// Settings (opened, never changed by the app), and the read route for
/// another user's (`sudo lsof` typed with no Return). The user's own
/// process — a tab's, an app's, one elsewhere — is Activity's own verb,
/// as its class asks (`ActivitySignalCheck`'s `.freePort`): its plan
/// (`Plan`) made again from a fresh read as the sheet opens, every holder
/// listed, its supervisor named and never added. Pure.
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
        /// The user's own process holds it: Activity's own verb, as its
        /// class asks — decided on the process read again as the sheet
        /// opens (`plan`).
        case stopHolder(ActivityProcessID)
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
            return own(row)
        case .service(let job):
            // Typed and run as keystrokes: a label any process can set
            // through its environment runs nothing but launchd's own.
            guard launchdLabel(job.label) else { return .refused("Its label holds characters a shell would act on: stop it where it runs.") }
            return .stopService(job)
        case .macOS:
            return .refused("Part of macOS; it would start again.")
        case .system(let user):
            return .readRoute(user: user)
        case .pane, .app, .elsewhere, .leftBehind:
            return own(row)
        }
    }

    /// The user's own holder: Activity's verb, by the identity listed.
    private static func own(_ row: ActivityPortRow) -> Step {
        guard let holder = row.holder, holder.pid > 1 else { return .refused("No process holds it now: list it again in a moment.") }
        return .stopHolder(holder)
    }

    /// Why the Free verb is greyed for `row`; nil when it can run.
    static func unavailable(_ row: ActivityPortRow) -> String? {
        switch step(for: row) {
        case nil: return "Only a listening port is freed"
        case .refused(let reason)?: return reason
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
        case .refused, .stopHolder: "Free :\(port)…"
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
        case .refused, .stopHolder:
            // Activity's own verb asks with its plan (`question(_ plan:)`).
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

// MARK: The user's own holder (6.8's rows a process of the user's holds)

extension ActivityPortHolder {
    /// Free :N's plan when the user's own process holds the port (6.8):
    /// the holder as the policy sees it and what `.freePort` does to it —
    /// Interrupt for a pane's foreground job with no agent in its group,
    /// Stop Agent for the agent, Stop for an agent's child, a background
    /// job or one elsewhere, Interrupt only for a terraform write, an app's
    /// Quit, the pane's close for its shell — and every other holder of
    /// the port: a socket inherited by several processes stays open until
    /// each has ended, and a Free ends one of them only. Made from the
    /// read as the sheet opens, and again at the button. Pure.
    struct Plan: Sendable {
        /// Another process of the user's holding the port.
        struct Other: Hashable, Sendable {
            let identity: ActivityProcessID
            let name: String
            /// It holds the very socket the holder does (`soi_so`): one it
            /// inherited — a child's, a pre-fork server's worker.
            let sharesSocket: Bool
        }

        let port: Int
        let proto: String
        /// Who the verb is for: the holder, or the terraform write it runs
        /// under — a provider plugin holds terraform's ports, and is never
        /// the one stopped (`subject(of:in:owners:known:)`).
        var subject: ActivityVerbSubject
        var rule: ActivityRule
        /// The process the row listed on the port, and its name: the one
        /// the watch follows.
        var holder: ActivityProcessID
        var holderName: String
        /// Every other holder, oldest first.
        var others: [Other]
    }

    /// How far up a holder's parents are looked at for a write it runs under.
    static let ancestorLimit = 64

    /// `holder` as the policy sees it, read in `snapshot`: itself — or, when
    /// it runs under a terraform, tofu or terragrunt write, that write,
    /// which only Interrupt may reach (a provider plugin holds terraform's
    /// ports); under a helm or pulumi write, itself marked as that write's,
    /// its sheet critical (6.10). Nil once it is gone.
    static func subject(
        of holder: ActivityProcessID, in snapshot: ActivitySnapshot, owners: ActivityAttribution, known: ActivityVerbSubject.Known
    ) -> ActivityVerbSubject? {
        guard var subject = ActivityVerbSubject.read(holder, in: snapshot, owners: owners, known: known) else { return nil }
        guard subject.target.terraformWrite == nil else { return subject }
        var current = snapshot.table.parent(of: holder)
        for _ in 0..<ancestorLimit {
            guard let parent = current, parent.pid > 1, parent.pid != known.appPID, parent.isWhollyOwn(by: snapshot.uid) else { break }
            guard let above = ActivityVerbSubject.read(parent.identity, in: snapshot, owners: owners, known: known) else { break }
            if above.target.terraformWrite != nil { return above }
            if subject.target.releaseWrite == nil, let write = above.target.releaseWrite { subject.target.releaseWrite = write }
            current = snapshot.table.parent(of: parent.identity)
        }
        return subject
    }

    /// The plan for `row`'s port, its holder read as `subject`; `holders`,
    /// every process of the user's holding the port in `snapshot`, read as
    /// the sheet opens (`ListeningPorts.holders`).
    static func plan(
        _ row: ActivityPortRow, subject: ActivityVerbSubject, holders: [ActivityProcessID], snapshot: ActivitySnapshot, user: uid_t = getuid()
    ) -> Plan {
        let identity = row.holder ?? subject.signal.identity
        let udp = row.proto == "udp"
        func sockets(_ holder: ActivityProcessID) -> Set<UInt64> {
            Set(
                snapshot.facts[holder]?.sockets?.records.filter { Int($0.localPort) == row.port && (udp ? $0.isBoundUDP : $0.isListening) }.map(\.socket)
                    ?? [])
        }
        let own = sockets(identity)
        let others = holders.filter { $0 != identity && $0 != subject.signal.identity }.sorted { ($0.start, $0.pid) < ($1.start, $1.pid) }.map { other in
            Plan.Other(
                identity: other, name: snapshot.name(of: other) ?? snapshot.table.process(other)?.shortName ?? "a process",
                sharesSocket: !own.isDisjoint(with: sockets(other)))
        }
        return Plan(
            port: row.port, proto: row.proto, subject: subject, rule: ActivitySignalCheck.rule(.freePort, for: subject.target, user: user),
            holder: identity, holderName: snapshot.name(of: identity) ?? snapshot.table.process(identity)?.shortName ?? row.process, others: others)
    }

    /// The question before `plan` (6.8's table): the verb's own sheet
    /// (`ActivityVerbQuestion`) — "Stop “node” (pid 5150)?", its
    /// executable, its command, its children, the supervisor that may
    /// start it again, the command it equals — with the port it holds and
    /// every other holder, which a Free doesn't end. Nil for a refusal or
    /// a route the page doesn't take, which ask nothing. `pane`: for the
    /// close route, its tab's title and whether it is split.
    static func question(
        _ plan: Plan, scope: String?, pane: (title: String, isSplit: Bool)? = nil, timeZone: TimeZone = .current
    ) -> ActivityPortFree.Question? {
        guard ActivityPageModel.unavailable(plan.rule) == nil,
            var question = ActivityVerbQuestion.question(.freePort, plan.rule, subject: plan.subject, scope: scope, pane: pane, timeZone: timeZone)
        else { return nil }
        let port = ":\(plan.port)\(plan.proto == "udp" ? "/udp" : "")"
        var lines = question.detail.components(separatedBy: "\n")
        let equals = lines.last?.hasPrefix("The command it equals") == true ? lines.removeLast() : nil
        if plan.holder == plan.subject.signal.identity {
            lines.insert("It holds \(port).", at: 0)
        } else {
            lines.insert(
                "It runs “\(DockerMCP.displayed(plan.holderName))” (pid \(plan.holder.pid)), which holds \(port): the write is interrupted, never what it runs.",
                at: 0)
        }
        if !plan.others.isEmpty {
            lines.append("Also holding \(port) — a Free ends none of them, and the port stays open until each has ended:")
            lines += plan.others.map { other in
                let how = other.sharesSocket ? "the same socket, inherited" : "a socket of its own"
                return "  pid \(other.identity.pid) \(DockerMCP.displayed(other.name)) — \(how)"
            }
        }
        if let equals { lines.append(equals) }
        question.detail = lines.joined(separator: "\n")
        return question
    }

    /// Why the button refuses what the sheet asked (6.10 step 4, 6.8's
    /// plan made again): the holder read again is gone, another holds the
    /// port, or the policy says something else of it now. Nil: do it.
    static func changedAtButton(_ asked: Plan, now: Plan?, holders: [ActivityProcessID]) -> String? {
        let port = ":\(asked.port)"
        guard let now, now.subject.signal.identity == asked.subject.signal.identity, now.holder == asked.holder, holders.contains(asked.holder) else {
            return "What held \(port) ended or let it go while you were asked: nothing was sent."
        }
        guard now.rule == asked.rule else {
            return "What holds \(port) changed while you were asked: nothing was sent — free it again to be asked about what it is now."
        }
        return nil
    }
}
