import Darwin
import Foundation

/// The pane pill's Free… (docs/design/activity/analysis.md, 6.12, 6.10;
/// 2.4 item 5): what holds a pill's port, read fresh at the press as the
/// policy sees it (`ActivityTarget`), and the words of each question.
/// `ActivitySignalCheck` decides; `ProcessSignals` sends; ⌃C is typed into
/// the pane only while the pane's foreground group is still the target's.
/// Pure: one snapshot, nothing read here.
enum ActivityPortFree {
    /// What holds a pill's port, as the policy sees it.
    struct Holder: Hashable, Sendable {
        var target: ActivityTarget
        /// Who a signal or ⌃C is for: the holder, or the terraform write it
        /// runs under — a provider plugin holds terraform's ports, and is
        /// never the one interrupted.
        var signal: ActivitySignalTarget
        /// What the sheet calls that one: its name, its masked command.
        var name: String
        var command: String?
        /// Its process group: ⌃C typed into the pane reaches it only while
        /// the pane's foreground group is this.
        var group: pid_t
        /// The holder itself, when it isn't `signal`'s: "under terraform
        /// apply", it holds the port.
        var holder: (pid: pid_t, name: String)?
        /// The pane's agent, when the target is it.
        var agent: Agent?
        /// Its children, which a Stop leaves running.
        var children: Int

        static func == (lhs: Holder, rhs: Holder) -> Bool {
            lhs.target == rhs.target && lhs.signal == rhs.signal && lhs.name == rhs.name && lhs.command == rhs.command && lhs.group == rhs.group
                && lhs.holder?.pid == rhs.holder?.pid && lhs.holder?.name == rhs.holder?.name && lhs.agent == rhs.agent
                && lhs.children == rhs.children
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(target)
            hasher.combine(signal)
        }
    }

    /// What a press found.
    enum Reading: Hashable, Sendable {
        case holder(Holder)
        /// It ended since the pill listed it; `now`, what holds its pid now.
        case ended(now: String?)
        /// It no longer runs in this pane: another pane's, or out of reach.
        case elsewhere
    }

    /// How far up a holder's parents are looked at for a terraform, helm or
    /// pulumi write it runs under.
    static let ancestorLimit = 64

    /// What holds the port the pill listed as `identity`, in `slice` of
    /// `snapshot`: its class (6.10's rows a pill can name — the pane's
    /// `login` and shell, its agent and the agent's children, its jobs,
    /// what left its terminal, Overterm's helpers) and the facts read now.
    /// `foregroundGroup`: the pane's foreground process group, read from
    /// its surface at the press (`ghostty_surface_foreground_pid`); nil,
    /// the census's `e_tpgid`. `terminal` and `checkouts` as
    /// `ActivityPaneSet` takes them.
    static func read(
        _ identity: ActivityProcessID, slice: ActivityPaneSlice, in snapshot: ActivitySnapshot, foregroundGroup: pid_t?, terminal: dev_t? = nil,
        checkouts: [String] = []
    ) -> Reading {
        let table = snapshot.table
        guard let process = table.process(identity) else {
            return .ended(now: table.process(pid: identity.pid).map { snapshot.name(of: $0.identity) ?? $0.shortName })
        }
        if snapshot.helpers.contains(identity) {
            return .holder(holder(process, kind: .helper(.other), in: snapshot, slice: slice, foregroundGroup: foregroundGroup))
        }
        guard identity == slice.login || slice.placed.contains(identity) else { return .elsewhere }

        // What chose to outlive its terminal, or an app, by the pane's set's
        // own reasons (6.5): what it leaves out, a pill frees from nowhere.
        let set = ActivityPaneSet(slice, in: snapshot, terminal: terminal, checkouts: checkouts)
        var detached = process.ignoresHangup
        var isApp = false
        switch reason(for: identity, in: set, table: table) {
        case .ignoresHangup?, .otherTerminal?, .detachedOnPurpose?: detached = true
        case .app?: isApp = true
        case .anotherPane?: return .elsewhere
        case .underExcluded?, nil: break
        }

        // A terraform write it runs under, itself first: Interrupt only, and
        // terraform the one interrupted — never its plugin.
        var writer: ActivityProcess?
        var terraformWrite: String?
        var releaseWrite: String?
        var current: ActivityProcess? = process
        for _ in 0..<ancestorLimit {
            guard let each = current, each.identity != slice.login, each.identity == identity || slice.placed.contains(each.identity) else { break }
            let facts = snapshot.facts[each.identity]
            let name = ActivityPaneSet.executableName(each, facts: facts)
            if terraformWrite == nil, TerraformCommandLine.tools.contains(name) {
                if let command = facts?.command {
                    if let line = TerraformCommandLine.parse(command, probable: false), line.isWrite {
                        terraformWrite = [line.tool, line.operation].compactMap { $0 }.joined(separator: " ")
                        writer = each
                    }
                } else {
                    // Its argv not read: a write, until it says otherwise.
                    terraformWrite = name
                    writer = each
                }
            }
            if releaseWrite == nil, let command = facts?.command {
                releaseWrite = ActivityTarget.releaseWrite(name: name, arguments: command.split(separator: " ").map(String.init))
            }
            current = table.parent(of: each.identity)
        }

        let signalled = writer ?? process
        var holder = holder(signalled, kind: kind(of: signalled.identity, slice: slice, table: table), in: snapshot, slice: slice, foregroundGroup: foregroundGroup)
        holder.target.terraformWrite = terraformWrite
        holder.target.releaseWrite = releaseWrite
        holder.target.detached = detached
        holder.target.isApp = isApp
        if writer != nil, signalled.identity != identity { holder.holder = (identity.pid, snapshot.name(of: identity) ?? process.shortName) }
        return .holder(holder)
    }

    /// Its class in the pane: the `login` and its child the shell are the
    /// pane itself; then the agent, what runs under it, the tree's jobs,
    /// and what carries the tag outside the tree.
    static func kind(of identity: ActivityProcessID, slice: ActivityPaneSlice, table: ProcessTable) -> ActivityClass {
        if identity == slice.login { return .paneSession }
        if let login = slice.login, table.parent(of: identity)?.identity == login { return .paneSession }
        if identity == slice.agent { return .agent }
        if let agent = slice.agent, table.descends(identity, from: agent) { return .agentChild }
        return slice.tree.contains(identity) ? .paneJob : .leftTerminal
    }

    /// Why the pane's set leaves `identity` out — for one under another
    /// left out, that one's reason.
    private static func reason(for identity: ActivityProcessID, in set: ActivityPaneSet, table: ProcessTable) -> ActivityPaneSet.Exclusion? {
        let reasons = Dictionary(set.leftOut.map { ($0.identity, $0.reason) }, uniquingKeysWith: { first, _ in first })
        var current = identity
        for _ in 0..<ancestorLimit {
            guard let reason = reasons[current] else { return nil }
            guard reason == .underExcluded, let parent = table.parent(of: current) else { return reason }
            current = parent.identity
        }
        return .underExcluded
    }

    private static func holder(
        _ process: ActivityProcess, kind: ActivityClass, in snapshot: ActivitySnapshot, slice: ActivityPaneSlice, foregroundGroup: pid_t?
    ) -> Holder {
        let table = snapshot.table
        let facts = snapshot.facts[process.identity]
        let group = process.group
        let inForeground = foregroundGroup.map { $0 == group } ?? (process.terminal != nil && process.terminalGroup == group)
        // A ⌃C, or a SIGINT to the group, reaches every member: an agent
        // among them too (Codex's children keep its group).
        var groupHoldsAgent = false
        for member in slice.placed + [slice.agent].compactMap({ $0 }) where !groupHoldsAgent {
            guard let other = table.process(member), other.group == group else { continue }
            let facts = snapshot.facts[member]
            if member == slice.agent || Agent.of(name: facts?.name ?? other.shortName, argv: facts?.argvAgent, command: facts?.command ?? "") != nil { groupHoldsAgent = true }
        }
        let target = ActivityTarget(
            kind, pid: process.pid, effectiveUID: process.effectiveUID, realUID: process.realUID, savedUID: process.savedUID,
            isZombie: process.isZombie, inForeground: inForeground, groupHoldsAgent: groupHoldsAgent)
        return Holder(
            target: target, signal: ActivitySignalTarget(process.identity, path: facts?.path), name: snapshot.name(of: process.identity) ?? process.shortName,
            command: facts?.command, group: group, holder: nil, agent: kind == .agent ? slice.agentKind : nil,
            children: table.children(of: process.identity).filter { !$0.isZombie }.count)
    }

    // MARK: Words

    /// A question, as `WriteConfirmation` asks it.
    struct Question: Hashable, Sendable {
        var title: String
        var scope: String?
        var production = false
        var detail: String
        var button: String
        var critical = false
    }

    /// Where the pane is, for a sheet's scope: "Tab “web” · feature-x · Claude".
    static func scope(tab: String, checkout: String?, agent: Agent?) -> String {
        (["Tab “\(DockerMCP.displayed(tab))”"] + [checkout, agent?.name].compactMap { $0 }).joined(separator: " · ")
    }

    /// The question before `rule` acts on `holder`, which holds `port`; nil
    /// for a refusal, which asks nothing (`refusal`). `tabTitle`, `isSplit`:
    /// which close the pane's own route is.
    static func question(
        _ rule: ActivityRule, holder: Holder, port: Int, scope: String?, tabTitle: String, isSplit: Bool, timeZone: TimeZone = .current
    ) -> Question? {
        let pid = holder.signal.identity.pid
        let name = DockerMCP.displayed(holder.name)
        var lines: [String] = []
        let held = holder.holder.map { "It holds :\(port) under it: “\(DockerMCP.displayed($0.name))” (pid \($0.pid))." } ?? "It holds :\(port)."
        switch rule {
        case .refused:
            return nil
        case .route(.closePane, _):
            let title = isSplit ? "Close this pane?" : "Close tab “\(DockerMCP.displayed(tabTitle))”?"
            lines.append("“\(name)” (pid \(pid)) holds :\(port): the pane's shell, which ends with the pane — and whatever runs in it.")
            return Question(title: title, scope: scope, detail: lines.joined(separator: "\n"), button: isSplit ? "Close Pane" : "Close Tab")
        case .route:
            // A pill's process is never a container's nor a helper's own
            // route but by `container` and `forward`: those ask themselves.
            return nil
        case .allowed(let action, _, let critical):
            let title: String
            let button: String
            switch action {
            case .interruptPane:
                title = "Interrupt “\(name)” (pid \(pid))?"
                button = "Interrupt"
                lines.append(held)
                lines.append("⌃C is typed into the pane, as if you pressed it: its foreground job stops as it does for ⌃C.")
            case .signal(.int):
                title = "Interrupt “\(name)” (pid \(pid))?"
                button = "Interrupt"
                lines.append(held)
                lines.append("It is sent SIGINT alone — it stops safely, as for ⌃C — never the agent or shell whose group it shares.")
            case .signal:
                if let agent = holder.agent {
                    title = "Stop \(agent.name) (pid \(pid))?"
                    button = "Stop Agent"
                    lines.append(held)
                    lines.append("\(agent.name) stops mid-task; the pane goes back to its shell. `\(agent.resumeCommand)` picks the conversation up.")
                } else {
                    title = "Stop “\(name)” (pid \(pid))?"
                    button = "Stop Process"
                    lines.append(held)
                    lines.append("It is sent SIGTERM, by the process Overterm listed — its pid, start and executable — and nothing else.")
                }
            }
            if let write = holder.target.terraformWrite {
                lines.append("A running \(DockerMCP.displayed(write)): SIGTERM or SIGKILL could leave its state locked and half written.")
            }
            if let write = holder.target.releaseWrite {
                lines.append("A running \(DockerMCP.displayed(write)): a release stopped mid-upgrade stays pending-upgrade.")
            }
            lines.append(executable(holder.signal.path))
            lines.append("pid \(pid), started \(started(holder.signal.identity.start, timeZone: timeZone))")
            if let command = holder.command { lines.append("Command: \(DockerMCP.displayed(command))") }
            if holder.children > 0, action != .interruptPane {
                lines.append(holder.children == 1 ? "Its child keeps running." : "Its \(holder.children) children keep running.")
            }
            lines.append("The command it equals: \(equals(action, pid: pid))")
            return Question(title: title, scope: scope, detail: lines.joined(separator: "\n"), button: button, critical: critical)
        }
    }

    /// What the sheet says it equals, as Kubernetes' asks name their kubectl.
    static func equals(_ action: ActivityAction, pid: pid_t) -> String {
        switch action {
        case .interruptPane: "⌃C in the pane"
        case .signal(let signal): signal.command(for: pid)
        }
    }

    /// The executable the identity was listed with.
    static func executable(_ path: String?) -> String {
        guard let path else { return "Its executable was deleted or replaced: it is named by its pid and start alone." }
        return "Runs \(DockerMCP.displayed(path))"
    }

    /// When it started, µs since 1970, to the second.
    static func started(_ start: UInt64, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: Double(start) / 1_000_000))
    }

    /// A refusal, said: nothing is asked, nothing sent.
    static func refusal(_ reason: String, port: Int) -> (title: String, detail: String) {
        ("Overterm doesn't free :\(port) from here", reason)
    }

    /// A container's port: its Stop, asked by Activity first — the Docker
    /// page's Stop acts at once (6.12).
    static func containerQuestion(_ name: String, port: Int) -> Question {
        let shown = DockerMCP.displayed(name)
        return Question(
            title: "Stop container “\(shown)”?",
            detail: "It publishes :\(port); Docker's engine holds the socket. The engine stops it, as the Docker page's Stop does.\nThe command it equals: docker stop \(shown)",
            button: "Stop Container")
    }

    /// A Kubernetes forward's: Stop Forward, asked first — Kubernetes ▸
    /// Forwards' Stop acts at once (6.12).
    static func forwardQuestion(_ forward: KubeForwardPill, port: Int) -> Question {
        Question(
            title: "Stop the forward to \(DockerMCP.displayed(forward.target))?",
            scope: "\(forward.production ? "PRODUCTION · " : "")\(DockerMCP.displayed(forward.context)) · namespace \(DockerMCP.displayed(forward.namespace))",
            production: forward.production,
            detail: "Overterm's own kubectl port-forward holds :\(port). Stop Forward ends it and frees the port; the pods aren't touched.",
            button: "Stop Forward")
    }

    /// Why a typed ⌃C is refused at the button (7.10): the pane's
    /// foreground group read now must be the target's, and the target the
    /// process the sheet named — a wrongly paired surface refuses rather
    /// than receives it. `now`, the target's pid read now; `leader`, the
    /// pane's foreground group's leader's name. Nil: type it.
    static func interruptRefusal(listed: ActivityProcessID, group: pid_t, now: ActivityProcess?, foregroundGroup: pid_t?, leader: String?) -> String? {
        guard let now, now.identity == listed, !now.isZombie else { return "It ended before ⌃C was typed: nothing was sent." }
        guard let foregroundGroup, foregroundGroup == group, now.group == group else {
            if let leader { return "The pane now runs “\(DockerMCP.displayed(leader))”: nothing was typed." }
            return "It is no longer the pane's foreground job: nothing was typed."
        }
        return nil
    }

    /// Why the button refuses what the sheet asked (6.10 step 4): the
    /// holder read again at the button, `now`, is another process, or the
    /// policy says something else of it — a job that became a terraform
    /// write, joined an agent's group or moved to the foreground while the
    /// sheet was up. Nil: do what was asked.
    static func changedAtButton(asked: Holder, rule: ActivityRule, now: Reading, port: Int, user: uid_t = getuid()) -> String? {
        guard case .holder(let fresh) = now else { return "What held :\(port) ended or left the pane while you were asked: nothing was sent." }
        if fresh.signal.identity != asked.signal.identity || ActivitySignalCheck.rule(.free, for: fresh.target, user: user) != rule {
            return "What holds :\(port) changed while you were asked: nothing was sent — free it again to be asked about what it is now."
        }
        return nil
    }

    /// What a send that didn't go says; nil when it went.
    static func answer(_ answer: ActivitySignalAnswer, pid: pid_t) -> String? {
        switch answer {
        case .sent: nil
        case .ended(let now): now.map { "It ended — pid \(pid) is now “\(DockerMCP.displayed($0))”. Nothing was sent." } ?? "It ended. Nothing was sent."
        case .ranAnotherProgram(let path):
            "It became “\(DockerMCP.displayed(path.map { ($0 as NSString).lastPathComponent } ?? "another program"))” since it was listed: nothing was sent — free it again to be asked about what it runs now."
        case .refused(let refusal): refusal.reason
        case .failed(let code): "macOS refused the signal: \(String(cString: strerror(code)))."
        }
    }
}

/// A port a pill freed, watched until it is (6.12; 6.10 step 10): the
/// pill says when the port is free, or that it isn't.
struct PortFreeing: Hashable, Sendable {
    enum State: Hashable, Sendable {
        /// Asked to stop; not free yet.
        case freeing
        /// Nothing of the user's holds it now.
        case free
        /// Still held after the watch: by the process freed, or by one that
        /// held it with it before the Free (a pre-fork server's workers, a
        /// child that inherited the socket, terraform's plugin). Nil: what
        /// the engine or a helper holds it by, named by no process.
        case stillHeld(pid: pid_t?)
        /// Held again, by a process started since the Free: "came back as
        /// pid N".
        case cameBack(pid: pid_t)
    }

    /// The pane whose pill freed it.
    var pane: ObjectIdentifier
    var port: Int
    var proto: String
    var state: State

    /// What the header says of it.
    var label: String { Self.label(state, port: port) }

    /// What is said of `port` in `state`: the pill's header, the page's.
    static func label(_ state: State, port: Int) -> String {
        switch state {
        case .freeing: ":\(port) freeing…"
        case .free: ":\(port) is free"
        case .stillHeld(let pid?): ":\(port) still held — pid \(pid)"
        case .stillHeld(nil): ":\(port) still held"
        case .cameBack(let pid): ":\(port) came back as pid \(pid)"
        }
    }

    /// What the watch makes of a read: `holders`, every process of the
    /// user's holding the port now; `freed`, the one the pill listed (nil
    /// for a container's or a forward's port); `sentAt`, when the Free was
    /// sent, µs since 1970 as a start is. Only a holder started after the
    /// Free came back; one older held the socket already — under the one
    /// freed, beside it — and is waited for, then said still held. Pure.
    static func state(holders: [ActivityProcessID], freed: ActivityProcessID?, sentAt: UInt64, final: Bool) -> State {
        guard !holders.isEmpty else { return .free }
        if let freed, holders.contains(freed) { return final ? .stillHeld(pid: freed.pid) : .freeing }
        if let new = holders.filter({ $0.start > sentAt }).min(by: { $0.start < $1.start }) { return .cameBack(pid: new.pid) }
        return final ? .stillHeld(pid: holders.min(by: { $0.start < $1.start })?.pid) : .freeing
    }

    /// Now, µs since 1970: what `sentAt` and a process's start count in.
    static func now() -> UInt64 { UInt64(max(Date().timeIntervalSince1970, 0) * 1_000_000) }
}
