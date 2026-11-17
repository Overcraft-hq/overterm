import Darwin
import Foundation

/// One agent's run in a pane (docs/design/activity/analysis.md, 6.9): its
/// window comes from the census — the agent's identity first seen in the
/// pane's tree (its own start), last seen, and the tick that found it gone.
/// A process carrying the pane's tag, outside its tree, that started inside
/// the window was left by the run. `COMMAND_FINISHED` says only when a
/// command ended, and the ledger's block names the pane's last title, which
/// Claude Code rewrites: the census, not the ledger, says when the agent ran.
struct ActivityAgentRun: Hashable, Sendable {
    /// Its pane's tag and tab.
    let tag: String
    let tab: UUID
    let agent: Agent
    /// The agent's process: its start opens the window.
    let identity: ActivityProcessID
    /// The last tick that saw it, µs since 1970 (the snapshot's date).
    var lastSeen: UInt64
    /// The tick that found it gone; nil while it runs.
    var ended: Date?
    /// It was its pane's foreground job each time it was seen: then nothing
    /// else could have started there in the window, and the sign is
    /// certain; else it is "probably".
    var foreground: Bool
    /// The tick that found it gone came soon after the last that saw it —
    /// within two intervals: the window ends where the agent did. A tab
    /// read again after minutes off screen has a window covering whatever
    /// the person started meanwhile, so its sign is only "probably".
    var exact = true

    /// The window's end, µs: the tick that found it gone — it ended
    /// somewhere between `lastSeen` and then.
    var end: UInt64? { ended.map(LeftBehind.micros) }

    /// Whether `process` started inside the window: no earlier than the
    /// agent, no later than the tick that found it gone.
    func covers(_ process: ActivityProcessID) -> Bool {
        guard let end else { return false }
        return process.start >= identity.start && process.start <= end
    }
}

/// The agents' runs the census has seen in each pane (6.9): pure, one
/// snapshot at a time. A pane the snapshot didn't read says nothing — its
/// agent may still run.
struct ActivityAgentRuns: Hashable, Sendable {
    /// What runs now, by its pane's tag.
    private(set) var running: [String: ActivityAgentRun] = [:]
    /// What has ended, oldest first, at most `kept`.
    private(set) var ended: [ActivityAgentRun] = []

    static let kept = 64
    /// Two of the census's default intervals (2 s) and a second's slack, µs.
    static let gap: UInt64 = 5_000_000

    /// Takes `snapshot`: each pane it read whose agent is new is followed,
    /// each whose agent has gone — or is another one now — has its run
    /// ended at the snapshot's time. Returns the runs that ended. `gap`, µs:
    /// the longest time between the last tick that saw an agent and the one
    /// that found it gone for its window to end where the agent did.
    @discardableResult
    mutating func observe(_ snapshot: ActivitySnapshot, gap: UInt64 = ActivityAgentRuns.gap) -> [ActivityAgentRun] {
        var endedNow: [ActivityAgentRun] = []
        let now = LeftBehind.micros(snapshot.date)
        var read = Set<String>()
        for slice in snapshot.panes {
            read.insert(slice.tag)
            let current = slice.agent.flatMap { snapshot.table.process($0) }.flatMap { $0.isZombie ? nil : $0 }
            if var run = running[slice.tag] {
                if let current, current.identity == run.identity {
                    run.lastSeen = now
                    run.foreground = run.foreground && Self.inForeground(current)
                    running[slice.tag] = run
                    continue
                }
                run.ended = snapshot.date
                run.exact = now >= run.lastSeen && now - run.lastSeen <= gap
                running[slice.tag] = nil
                endedNow.append(run)
            }
            if let current {
                running[slice.tag] = ActivityAgentRun(
                    tag: slice.tag, tab: slice.tab, agent: slice.agentKind ?? .claude, identity: current.identity, lastSeen: now,
                    foreground: Self.inForeground(current))
            }
        }
        ended.append(contentsOf: endedNow)
        if ended.count > Self.kept { ended.removeFirst(ended.count - Self.kept) }
        return endedNow
    }

    /// A pane closed: what ran in it is the closed pane's to explain now.
    mutating func forget(tag: String) {
        running[tag] = nil
        ended.removeAll { $0.tag == tag }
    }

    /// The ended runs of the pane `tag`, newest first.
    func ended(in tag: String) -> [ActivityAgentRun] { ended.filter { $0.tag == tag }.reversed() }

    private static func inForeground(_ process: ActivityProcess) -> Bool {
        process.terminalGroup.map { $0 == process.group } ?? false
    }
}

/// Why a process is Left Behind (6.9): one of these signs, each with how
/// sure it is. Nothing here is ever ended on its own.
enum LeftBehindSign: Hashable, Sendable {
    /// It carries the tag of a pane this run closed.
    case closedPane(ActivityContext.RetiredPane)
    /// It carries a live pane's tag, outside its tree, and started inside
    /// an agent run of that pane that has ended. The pane's tab's title.
    case agentRun(ActivityAgentRun, title: String)
    /// Its `OVERTERM_RUN`, or an argv sign, names an Overterm run that is
    /// gone; its kind when the marker said it (a sign doesn't).
    case earlierRun(OvertermRun.Kind?)
    /// A test run's: its marker's kind is `isolated`, or its argv names a
    /// scenario's scratch folder.
    case testRun
    /// Its group's leader is gone, it has no terminal, launchd is its
    /// parent, and it runs inside a known checkout no open tab is in.
    case deadLeader(checkout: String)

    var certainty: ActivityOwner.Certainty {
        switch self {
        case .closedPane, .earlierRun, .testRun: .certain
        case .agentRun(let run, _): run.foreground && run.exact ? .certain : .probably
        case .deadLeader: .probably
        }
    }

    /// The checkout it belongs to, by its folder; nil when none is known.
    var checkout: String? {
        switch self {
        case .closedPane(let retired): retired.pane.checkout
        case .agentRun: nil
        case .deadLeader(let checkout): checkout
        case .earlierRun, .testRun: nil
        }
    }

    /// The tab it came from: a closed pane's (gone now), an agent run's.
    var tab: UUID? {
        switch self {
        case .closedPane(let retired): retired.pane.tab
        case .agentRun(let run, _): run.tab
        default: nil
        }
    }

    /// The row's reason (6.9): "left by Claude in “web”, which exited at 13:10".
    var reason: String {
        switch self {
        case .closedPane(let retired):
            let title = "“\(retired.pane.title)”"
            let by = retired.pane.agent.map { "\($0.name) in \(title)" } ?? title
            return "left by \(by), closed at \(LeftBehind.clock(retired.closed))"
        case .agentRun(let run, let title):
            let when = run.ended.map(LeftBehind.clock) ?? "—"
            return "left by \(run.agent.name) in “\(title)”, which exited \(run.exact ? "at" : "by") \(when)"
        case .earlierRun(let kind):
            return kind == .dev ? "left by an earlier run of a development Overterm" : "left by Overterm’s earlier run"
        case .testRun:
            return "left by a test run"
        case .deadLeader(let checkout):
            return "its group’s leader is gone; it runs in \(ActivityRows.folderName(checkout)), which no tab shows"
        }
    }

    /// Whether it is an earlier Overterm's (a test run's included): the
    /// launch check's (D-14).
    var isEarlierRun: Bool {
        switch self {
        case .earlierRun, .testRun: true
        default: false
        }
    }
}

/// The signs of 6.9, pure: one process, one snapshot, one context.
enum LeftBehind {
    /// µs since 1970, as a process's start is kept.
    static func micros(_ date: Date) -> UInt64 { UInt64(max(date.timeIntervalSince1970, 0) * 1_000_000) }

    /// "13:10".
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// Why `process` is never Left Behind whatever it carries (6.9's
    /// "Never"): detached on purpose, an app (with a bundle outside every
    /// checkout), a launchd job or brew service. Nil when none applies.
    static func neverReason(_ process: ActivityProcess, facts: ActivityFacts?, checkouts: [String]) -> String? {
        if ActivityPaneSet.isDetachedOnPurpose(process, facts: facts) { return "detached on purpose" }
        if let path = facts?.path, let bundle = ActivityPaneSet.appBundle(of: path),
            !checkouts.contains(where: { ActivityPaneSet.isInside(bundle, $0) })
        {
            return "an app"
        }
        if let service = facts?.markers?.service, !service.isEmpty, service != "0" { return "a launchd job" }
        return nil
    }

    /// Rule 11's signs (6.5): a closed pane's tag, an earlier Overterm's
    /// marker or argv sign, a dead group leader — first that matches.
    /// `live`: the panes' tags now; `openCheckouts`: the checkouts a tab
    /// shows. Rule 8 (an agent run's window) is `agentRun`'s, asked where
    /// the live pane's tagged processes are placed.
    static func sign(
        of process: ActivityProcess, facts: ActivityFacts?, table: ProcessTable, context: ActivityContext, live: Set<String>,
        checkouts: [String], openCheckouts: Set<String>
    ) -> LeftBehindSign? {
        guard process.pid > 1, process.pid != context.appPID, !process.isZombie else { return nil }
        if neverReason(process, facts: facts, checkouts: checkouts) != nil { return nil }
        // A closed pane's tag.
        if let tag = facts?.markers?.tab, !live.contains(tag), let retired = context.retired.last(where: { $0.pane.tag == tag }) {
            return .closedPane(retired)
        }
        let own = context.run.flatMap(OvertermRun.init(marker:))
        // Its marker: a run that is gone.
        if let marker = facts?.markers?.run, marker != context.run, let run = OvertermRun(marker: marker), !isLive(run.identity, in: table) {
            return run.kind == .isolated ? .testRun : .earlierRun(run.kind)
        }
        // An argv sign.
        if let command = facts?.command {
            for sign in ArgvSign.signs(in: command) {
                switch sign {
                case .testScratch:
                    // Only an orphan: a running test's stand-in has its
                    // live parent, and is that test's, not left.
                    guard process.parentPID == 1 else { continue }
                    return .testRun
                default:
                    guard let named = sign.run, named != own?.identity, !isLive(named, in: table) else { continue }
                    return .earlierRun(nil)
                }
            }
        }
        // Its group's leader gone, no terminal, launchd its parent, in a
        // checkout no tab shows: probably.
        if process.group != process.pid, process.group > 1, table.process(pid: process.group) == nil, process.terminal == nil,
            process.parentPID == 1, case .path(let folder)? = facts?.folder,
            let checkout = checkouts.filter({ ActivityPaneSet.isInside(folder, $0) }).max(by: { $0.count < $1.count }),
            !openCheckouts.contains(checkout)
        {
            return .deadLeader(checkout: checkout)
        }
        return nil
    }

    /// Rule 8 (6.5): the ended run of `tag`'s pane `process` started inside.
    static func agentRun(_ process: ActivityProcessID, tag: String, runs: [ActivityAgentRun]) -> ActivityAgentRun? {
        runs.last { $0.tag == tag && $0.covers(process) }
    }

    /// Whether the person kept `identity` or one of its ancestors: what a
    /// kept server started — its workers, a database's backends — is kept
    /// with it (6.9). Bounded.
    static func isKept(_ identity: ActivityProcessID, kept: Set<ActivityProcessID>, table: ProcessTable) -> Bool {
        guard !kept.isEmpty else { return false }
        var current = identity
        for _ in 0..<64 {
            if kept.contains(current) { return true }
            guard let parent = table.parent(of: current), parent.pid > 1 else { return false }
            current = parent.identity
        }
        return false
    }

    /// Whether a run named by its identity is alive: its pid holds the
    /// same start.
    static func isLive(_ identity: ActivityProcessID, in table: ProcessTable) -> Bool {
        table.process(identity).map { !$0.isZombie } ?? false
    }

    /// Whether a bulk Stop may take it (6.9): certain, and not one that
    /// ignores SIGHUP, detached on purpose, an app or a terraform write —
    /// nor one the person kept. A `setsid` leader stays eligible.
    static func isBulkEligible(_ owner: ActivityOwner, process: ActivityProcess, terraformWrite: Bool, kept: Bool) -> Bool {
        guard owner.place == .leftBehind, owner.certainty == .certain, !kept, !terraformWrite else { return false }
        if process.ignoresHangup || owner.marks.contains(.nohup) || owner.marks.contains(.detached) || owner.marks.contains(.fromPane) { return false }
        return true
    }
}

/// What an ended agent run left in its pane (6.9's tab note): each process
/// by identity, its name and what it listens on.
struct LeftBehindItem: Hashable, Sendable {
    let identity: ActivityProcessID
    let name: String
    /// Its listening TCP ports, sorted.
    var ports: [Int] = []
}

extension LeftBehind {
    /// What `run` left, as `snapshot` read its pane: carrying the pane's
    /// tag outside its tree, started inside the run's window — never a
    /// process detached on purpose, an app, a launchd job, nor one kept.
    static func left(by run: ActivityAgentRun, in snapshot: ActivitySnapshot, checkouts: [String], kept: Set<ActivityProcessID>) -> [LeftBehindItem] {
        guard let slice = snapshot.pane(run.tag) else { return [] }
        var items: [LeftBehindItem] = []
        for identity in slice.tagged where run.covers(identity) && !isKept(identity, kept: kept, table: snapshot.table) {
            guard let process = snapshot.table.process(identity), !process.isZombie else { continue }
            let facts = snapshot.facts[identity]
            if neverReason(process, facts: facts, checkouts: checkouts) != nil { continue }
            let ports = (facts?.sockets?.listeners ?? []).filter { $0.kind == .tcp }.map { Int($0.localPort) }
            items.append(LeftBehindItem(identity: identity, name: snapshot.name(of: identity) ?? process.shortName, ports: Array(Set(ports)).sorted()))
        }
        // The ones that listen first: what the note names.
        return items.sorted { ($0.ports.isEmpty ? 1 : 0, $0.identity) < ($1.ports.isEmpty ? 1 : 0, $1.identity) }
    }

    /// A tab's leftovers after a run settled: `left` added to what its
    /// earlier runs, and its other panes', left and still runs — a run
    /// that left nothing takes none of theirs. Each once, at most `limit`.
    static func merged(_ earlier: [LeftBehindItem], _ left: [LeftBehindItem], in snapshot: ActivitySnapshot, limit: Int) -> [LeftBehindItem] {
        let still = earlier.filter { item in
            !left.contains { $0.identity == item.identity } && snapshot.table.process(item.identity).map { !$0.isZombie } ?? false
        }
        return Array((still + left).suffix(limit))
    }

    /// The tab's note (6.9, D-17): "Claude finished — left node :3001 running".
    static func note(_ agent: Agent, left: [LeftBehindItem]) -> String {
        guard let first = left.first else { return "\(agent.name) finished" }
        var named = first.name
        if !first.ports.isEmpty { named += " " + first.ports.prefix(2).map { ":\($0)" }.joined(separator: " ") }
        let more = left.count > 1 ? " and \(left.count - 1) more" : ""
        return "\(agent.name) finished — left \(named)\(more) running"
    }
}

/// The launch check (6.9, D-14): what an earlier Overterm left, listed with
/// one asked Stop All, a test run's apart; what ignores SIGHUP listed but
/// never in the Stop All; kept identities left out (their owner says kept).
/// Nothing is stopped automatically. Pure.
struct LeftBehindAtLaunch: Hashable, Sendable {
    struct Item: Hashable, Sendable {
        let identity: ActivityProcessID
        let name: String
        let path: String?
        /// In the Stop All: certain, not ignoring SIGHUP, not detached, not
        /// a terraform tool.
        let stops: Bool
    }

    var earlier: [Item] = []
    var test: [Item] = []

    var isEmpty: Bool { earlier.isEmpty && test.isEmpty }
    var all: [Item] { earlier + test }

    static func of(_ snapshot: ActivitySnapshot, owners: ActivityAttribution) -> LeftBehindAtLaunch {
        var found = LeftBehindAtLaunch()
        for process in snapshot.table.processes {
            guard let owner = owners[process.identity], owner.place == .leftBehind, let sign = owner.leftBehind, sign.isEarlierRun else { continue }
            // The Stop All's rule is a bulk Stop's: never a terraform tool
            // (Interrupt only), nor what chose to outlive its terminal.
            let terraform = TerraformCommandLine.tools.contains(ActivityPaneSet.executableName(process, facts: snapshot.facts[process.identity]))
            let item = Item(
                identity: process.identity, name: snapshot.name(of: process.identity) ?? process.shortName, path: snapshot.facts[process.identity]?.path,
                stops: LeftBehind.isBulkEligible(owner, process: process, terraformWrite: terraform, kept: owner.kept))
            if sign == .testRun { found.test.append(item) } else { found.earlier.append(item) }
        }
        return found
    }

    /// "9 kubectl, 2 acme-server": by name, most first.
    static func counted(_ items: [Item]) -> String {
        var counts: [String: Int] = [:]
        for item in items { counts[item.name, default: 0] += 1 }
        let named = counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(4).map { "\($0.value) \($0.key)" }
        let more = counts.count > 4 ? " and \(counts.count - 4) more names" : ""
        return named.joined(separator: ", ") + more
    }

    /// The sheet's title: "Overterm's earlier run left 9 kubectl".
    var title: String {
        if !earlier.isEmpty { return "Overterm’s earlier run left \(Self.counted(earlier))" }
        return "A test run left \(Self.counted(test))"
    }

    /// The sheet's words: each group, what Stop All leaves.
    var detail: String {
        var lines: [String] = []
        if !earlier.isEmpty, !test.isEmpty { lines.append("Left by a test run: \(Self.counted(test)).") }
        let unstopped = all.filter { !$0.stops }
        if !unstopped.isEmpty {
            lines.append("Not in Stop All — they ignore SIGHUP, are terraform's or are only probably its: \(Self.counted(unstopped)). Activity ▸ Left Behind lists them.")
        }
        lines.append("Nothing is stopped unless you say so; Activity ▸ Left Behind (3) lists each with its reason.")
        return lines.joined(separator: "\n")
    }
}
