import Darwin
import Foundation

/// The census (docs/design/activity/analysis.md, 7.1–7.4, 7.7): one read of
/// the Mac that every reader shares, on a serial queue of its own at
/// `.userInitiated` (D-8: lower QoS runs the same calls on E-cores at 3–4×
/// the CPU time). A tick reads `KERN_PROC_ALL`, then what its levels ask
/// (`ActivityDemand`), and hands back one `ActivitySnapshot`, a value.
///
/// What it keeps between ticks lives on its queue: each identity's path,
/// code signing, name, markers and masked argv (`known`), the CPU
/// baselines, the socket walk's state, the cadence. Nothing of the main
/// actor's is touched: the context comes with each tick, whole.
///
/// - **Identities**, not pids (7.5): a reused pid is a new process, its
///   first sample "—". An `exec` keeps the identity and changes `p_comm`:
///   the identity is read again.
/// - **Baselines** are kept for every live identity and pruned only of
///   identities gone from the table — never of what a tick didn't read:
///   two panes read in turn both keep theirs (2.4, item 1). A rate spans
///   at most `Limits.baselineAge`: after a longer gap it is "—" once, its
///   baseline begun again, never the gap's average shown as now.
/// - **The churn budget** (7.3): at most `Limits.identitiesPerTick` new
///   identities read a tick, within `Limits.lightReadTime` or
///   `fullReadTime` on the kernel's clock — the masking is most of a read
///   (140 µs on average here, 0.7 ms for an Electron helper's line) — the
///   level's own processes first — what carries a read pane's tag, once
///   the tag is known, among them — then the oldest; the rest are named
///   from `p_comm` until a later tick (`ActivitySnapshot.unread`).
/// - **Working folders** are asked at most `Limits.foldersPerTick` a tick,
///   the panes' agents' first, and never waited for (`ProcessFolders`).
/// - **The cache** holds at most `Limits.cacheLimit` identities. Ended ones
///   are dropped first, at the tick whose table no longer lists them, so a
///   build's thousands of short lives never fill it; past the limit the
///   identities least recently wanted go.
/// - **The in-flight guard**: a tick asked for while one is running is
///   skipped, nothing read (`submit`).
/// - **The cadence** stretches on a busy Mac (`ActivityCadence`).
///
/// Every call is a plain synchronous one on the queue; the levels' later
/// reads join `sample` where its comments say: the meters at the full
/// level (stage 1), nettop's listeners every 5th tick while Listening shows
/// (stage 4), other users' coalitions (stage 5).
final class ActivitySampler: @unchecked Sendable {
    /// What a tick may read.
    struct Limits: Sendable {
        /// Identities read a tick (7.3).
        var identitiesPerTick = 200
        /// …and the time those reads may take, on the kernel's clock: twice
        /// the level's budget, so the reads alone never make a tick slow.
        var lightReadTime: UInt64 = 2 * ActivityCadence.lightBudget
        var fullReadTime: UInt64 = 2 * ActivityCadence.fullBudget
        /// Identities whose reads are kept (7.3).
        var cacheLimit = 8_192
        /// Security.framework's code signing a tick, where `csops` can't
        /// answer: 1.2–1.4 ms each (measured).
        var signingFallbacks = 4
        /// The longest interval a CPU rate spans: a baseline older than this
        /// begins again, "—" (`ProcessUsage.maximumInterval`).
        var baselineAge = ProcessUsage.maximumInterval
        /// Working folders asked of the file system a tick (7.2): the panes'
        /// agents' first, the rest at a later tick.
        var foldersPerTick = 200

        init() {}
    }

    let kernel: any ActivityKernel
    let limits: Limits
    /// Where every tick runs and the caches live (D-8).
    let queue = DispatchQueue(label: "Overterm.activity", qos: .userInitiated)
    /// The working folders, on a queue of their own (7.7).
    let folders: ProcessFolders

    // On `queue` only.
    private var known: [ActivityProcessID: Known] = [:]
    private var baselines: UsageBaselines
    private var socketScan = SocketScan()
    private var cadence = ActivityCadence()
    private var ticks = 0

    private let flight = NSLock()
    /// A tick is submitted and not yet done: under `flight`.
    private var inFlight = false

    /// The app's census: what `ActivityMonitor.shared` ticks, and what the
    /// old API's lookups read between its ticks (`ProcessInspector`, 7.8).
    /// It reads nothing until asked.
    static let app = ActivitySampler()

    private let shared = NSLock()
    // Under `shared`.
    private var lastSnapshot: ActivitySnapshot?
    private var lastContext = ActivityContext()

    init(kernel: any ActivityKernel = LiveActivityKernel(), limits: Limits = Limits()) {
        self.kernel = kernel
        self.limits = limits
        self.folders = ProcessFolders(kernel: kernel)
        self.baselines = UsageBaselines(maximumAge: limits.baselineAge)
    }

    // MARK: Lookups

    /// The latest snapshot any tick made, whoever asked for it.
    var latest: ActivitySnapshot? { shared.withLock { lastSnapshot } }

    /// The context the app's monitor last built (`ActivityMonitor.context`):
    /// a lookup's tick reads the app's panes with it, so one tick answers
    /// every pane's lookups until it is a tick old.
    var appContext: ActivityContext {
        get { shared.withLock { lastContext } }
        set { shared.withLock { lastContext = newValue } }
    }

    /// Whether `snapshot` is younger than `within`, on the kernel's clock.
    func isFresh(_ snapshot: ActivitySnapshot, within: UInt64) -> Bool {
        let now = kernel.uptime()
        return now < snapshot.time || now - snapshot.time < within
    }

    /// A lookup for a caller that answers at once (7.8: the old API,
    /// `ProcessInspector`): the latest snapshot while it is younger than
    /// `within` — a tick — and `answers` the question; no new scan then.
    /// Else a tick now, waited for on the calling thread: after the tick in
    /// flight, whose snapshot may answer, `demand` over `context`, and again
    /// back to back while the churn budget left reads for a later tick
    /// (`ActivitySnapshot.unread`) — `rounds` ticks at most — so a cold
    /// census reads what a lookup asks in one call: a nohup'd server's tag
    /// among 860 processes' markers. Never from the queue itself; nil when
    /// the table can't be read.
    func lookup(
        within: UInt64, demand: ActivityDemand, context: ActivityContext, rounds: Int = 8, answers: (ActivitySnapshot) -> Bool
    ) -> ActivitySnapshot? {
        dispatchPrecondition(condition: .notOnQueue(queue))
        if let latest, isFresh(latest, within: within), answers(latest) { return latest }
        return queue.sync {
            // A tick that landed while this one waited may answer it.
            if let latest, isFresh(latest, within: within), answers(latest) { return latest }
            guard var snapshot = sample(demand, context: context) else { return nil }
            for _ in 1..<max(rounds, 1) where snapshot.unread > 0 {
                guard let next = sample(demand, context: context) else { break }
                snapshot = next
            }
            return snapshot
        }
    }

    // MARK: Ticks

    /// A tick on the queue, `done` given its snapshot there — unless one is
    /// in flight: then nothing is read, `done` gets nil at once and this
    /// says false (7.3, the in-flight guard). Nil too when the table can't
    /// be read.
    @discardableResult
    func submit(_ demand: ActivityDemand, context: ActivityContext, done: @escaping @Sendable (ActivitySnapshot?) -> Void) -> Bool {
        let free = flight.withLock {
            guard !inFlight else { return false }
            inFlight = true
            return true
        }
        guard free else {
            done(nil)
            return false
        }
        queue.async { [self] in
            let snapshot = sample(demand, context: context)
            flight.withLock { inFlight = false }
            done(snapshot)
        }
        return true
    }

    /// `submit`, awaited: the snapshot, or nil when skipped or unreadable.
    func tick(_ demand: ActivityDemand, context: ActivityContext) async -> ActivitySnapshot? {
        await withCheckedContinuation { continuation in
            submit(demand, context: context) { continuation.resume(returning: $0) }
        }
    }

    /// A tick, waited for on the calling thread: the tests' and the
    /// probes'. Never from the queue itself.
    func tickNow(_ demand: ActivityDemand, context: ActivityContext) -> ActivitySnapshot? {
        dispatchPrecondition(condition: .notOnQueue(queue))
        let done = DispatchSemaphore(value: 0)
        let result = Result()
        submit(demand, context: context) { snapshot in
            result.set(snapshot)
            done.signal()
        }
        done.wait()
        return result.value
    }

    /// One answer, handed from the queue.
    private final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: ActivitySnapshot?
        func set(_ snapshot: ActivitySnapshot?) { lock.withLock { self.snapshot = snapshot } }
        var value: ActivitySnapshot? { lock.withLock { snapshot } }
    }

    /// How many identities the cache holds: the tests' and the probes'.
    var cachedIdentities: Int {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { known.count }
    }

    /// Which identities the cache holds: the tests'.
    var cached: Set<ActivityProcessID> {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { Set(known.keys) }
    }

    // MARK: The tick

    /// What is kept of one identity between ticks.
    private struct Known {
        /// `p_comm` when it was read: an `exec` changes it.
        let comm: String
        var path: String?
        var signing: ActivityCodeSigning?
        /// `proc_name`: the user's only.
        var procName: String?
        var markers = Markers.unread
        var arguments = Arguments.unread
        /// The tick it was last read or wanted: past the cache's limit, the
        /// least recent go.
        var used: Int

        enum Markers {
            case unread
            case read(ProcessMarkers)
            /// `CS_RESTRICT` (the kernel hides it), another user's, or unreadable.
            case hidden
        }

        enum Arguments {
            case unread
            case read(ProcessArguments)
            case unreadable
        }

        var markersUnread: Bool { if case .unread = markers { true } else { false } }
        var argumentsUnread: Bool { if case .unread = arguments { true } else { false } }
        var tag: String? { if case .read(let found) = markers { found.tab } else { nil } }
    }

    /// The reads a tick may make (7.3): a count, and the time they took.
    private struct ReadBudget {
        var left: Int
        let time: UInt64
        let start: UInt64

        mutating func take(at now: UInt64) -> Bool {
            guard left > 0, now < start || now - start <= time else { return false }
            left -= 1
            return true
        }
    }

    /// One tick, on the queue: the table, what `demand`'s levels read, the
    /// rates, the panes' slices; nil when the table can't be read — the
    /// caches are left as they were.
    func sample(_ demand: ActivityDemand, context: ActivityContext) -> ActivitySnapshot? {
        dispatchPrecondition(condition: .onQueue(queue))
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let started = kernel.uptime()
        guard let table = ProcessTable.read(kernel) else { return nil }
        let now = kernel.uptime()
        let date = Date()
        ticks += 1
        let tick = ticks
        let uid = kernel.uid
        var cost = ActivityTickCost()
        cost.processes = table.processes.count

        // Ended identities go, first: the baselines only of those, never of
        // what this tick doesn't read.
        let live = Set(table.processes.map(\.identity))
        forget(keeping: live)
        // An exec keeps the identity and changes p_comm: read it again.
        for process in table.processes {
            if let entry = known[process.identity], entry.comm != process.shortName { known[process.identity] = nil }
        }

        // Every pane's tree, read or not: a process a tree places needs no
        // markers (9.2), whichever pane's it is.
        var trees: [String: [ActivityProcessID]] = [:]
        var inTrees = Set<ActivityProcessID>()
        for pane in context.panes {
            guard let login = pane.login, table.process(login) != nil else { continue }
            let tree = Self.depthFirst(below: login, in: table)
            trees[pane.tag] = tree
            inTrees.formUnion(tree)
        }
        let read = context.panes.filter { demand.reads($0) }
        let readTags = Set(read.map(\.tag))
        let helpers = demand.readsPanes ? Self.helpers(of: context, in: table) : []
        let focus = demand.focus.sorted().compactMap { table.process($0) }

        // The level's own first — focus, the read panes' trees, the
        // helpers, and what carries a read pane's tag already known, with
        // its descendants: a nohup'd server is the pane's as much as its
        // tree is, and a crowd of strangers' markers must not keep it
        // unread tick after tick — then the user's processes outside every
        // tree (their markers), the oldest first; at the full level all of
        // the user's argv and the others' paths and code signing.
        var budget = ReadBudget(
            left: limits.identitiesPerTick, time: demand.full ? limits.fullReadTime : limits.lightReadTime, start: kernel.uptime())
        var fallbacks = limits.signingFallbacks
        var unread = Set<ActivityProcessID>()
        var first: [ActivityProcess] = focus
        var queued = Set(focus.map(\.identity))
        for pane in read {
            for identity in trees[pane.tag] ?? [] where queued.insert(identity).inserted {
                if let process = table.process(identity) { first.append(process) }
            }
        }
        for identity in helpers where queued.insert(identity).inserted {
            if let process = table.process(identity) { first.append(process) }
        }
        let knownTagged = carrying(readTags)
        for pane in read {
            for root in (knownTagged[pane.tag] ?? []).sorted() {
                for identity in [root] + Self.depthFirst(below: root, in: table) where queued.insert(identity).inserted {
                    if let process = table.process(identity) { first.append(process) }
                }
            }
        }
        func consider(_ process: ActivityProcess, command: Bool) {
            let markers = !inTrees.contains(process.identity)
            guard needs(process, command: command, markers: markers, uid: uid) else { return }
            guard budget.take(at: kernel.uptime()) else {
                unread.insert(process.identity)
                return
            }
            readIdentity(process, command: command, markers: markers, tick: tick, uid: uid, fallbacks: &fallbacks, cost: &cost)
        }
        for process in first { consider(process, command: true) }
        if demand.readsPanes {
            let rest = table.processes.filter {
                $0.isOwn(by: uid) && !queued.contains($0.identity) && !inTrees.contains($0.identity)
                    && needs($0, command: demand.full, markers: true, uid: uid)
            }
            for process in rest.sorted(by: { $0.identity < $1.identity }) { consider(process, command: demand.full) }
        }
        if demand.full {
            let others = table.processes.filter { !$0.isOwn(by: uid) && !queued.contains($0.identity) && known[$0.identity] == nil }
            for process in others.sorted(by: { $0.identity < $1.identity }) { consider(process, command: false) }
        }

        // The tagged: carrying a read pane's tag outside its tree, with
        // their descendants — read in full, as the pane's are; those whose
        // tag this tick found now, after the rest.
        let byTag = carrying(readTags)
        var slices: [ActivityPaneSlice] = []
        var placed: [ActivityProcessID] = []
        var counted = Set<ActivityProcessID>()
        for pane in read {
            let tree = trees[pane.tag] ?? []
            var tagged: [ActivityProcessID] = []
            var seen = Set(tree)
            for root in (byTag[pane.tag] ?? []).sorted() where !seen.contains(root) {
                for identity in [root] + Self.depthFirst(below: root, in: table) where seen.insert(identity).inserted {
                    tagged.append(identity)
                    if let process = table.process(identity) { consider(process, command: true) }
                }
            }
            let agent = tree.first { identity in
                guard let process = table.process(identity) else { return false }
                return Self.agent(process, known[identity]) != nil
            }
            let kind = agent.flatMap { identity in table.process(identity).flatMap { Self.agent($0, known[identity]) } }
            slices.append(
                ActivityPaneSlice(
                    tag: pane.tag, tab: pane.tab, login: pane.login.flatMap { table.process($0)?.identity }, tree: tree, tagged: tagged,
                    agent: agent, agentKind: kind))
            for identity in tree + tagged where counted.insert(identity).inserted { placed.append(identity) }
        }

        // What is read this tick: usage, and sockets — at the light level
        // only the listening and bound-UDP ones — for the user's.
        var wanted: [ActivityProcess] = []
        var wantedIDs = Set<ActivityProcessID>()
        func want(_ process: ActivityProcess) {
            if wantedIDs.insert(process.identity).inserted { wanted.append(process) }
        }
        if demand.full {
            for process in table.processes where process.isOwn(by: uid) { want(process) }
        }
        for identity in placed + helpers {
            if let process = table.process(identity) { want(process) }
        }
        for process in focus { want(process) }
        var usages: [ActivityProcessID: (ActivityUsage, ActivityRates?)] = [:]
        var sockets: [ActivityProcessID: SocketScan.Sockets] = [:]
        for process in wanted {
            known[process.identity]?.used = tick
            guard process.isOwn(by: uid), !process.isZombie else { continue }
            if let usage = kernel.usage(of: process.pid) {
                cost.usageRead += 1
                usages[process.identity] = (usage, baselines.record(usage, for: process.identity))
            }
            if var found = socketScan.read(process.identity, kernel: kernel) {
                cost.socketsRead += 1
                if !demand.full, !demand.focus.contains(process.identity) { found.records = found.listeners }
                sockets[process.identity] = found
            }
        }

        // Folders: each read pane's agent's at every tick, a focused
        // process's while fresh — never waited for (7.7), and at most
        // `foldersPerTick` asked, the agents' first (7.2).
        var asked: [ProcessFolders.Request] = slices.compactMap { $0.agent.map { ProcessFolders.Request(identity: $0, everyTick: true) } }
        asked += focus.filter { $0.isOwn(by: uid) }.map { ProcessFolders.Request(identity: $0.identity) }
        let folders = asked.isEmpty ? [:] : self.folders.folders(asked, now: kernel.uptime(), limit: limits.foldersPerTick)

        // The meters join here at the full level (stage 1), nettop's
        // listeners every 5th tick while Listening shows (stage 4).

        var facts: [ActivityProcessID: ActivityFacts] = [:]
        let described = demand.full ? table.processes : wanted
        facts.reserveCapacity(described.count)
        for process in described {
            let usage = usages[process.identity]
            facts[process.identity] = Self.facts(
                process, known[process.identity], usage: usage?.0, rates: usage?.1, sockets: sockets[process.identity],
                folder: folders[process.identity])
        }
        cost.own = table.processes.lazy.filter { $0.isOwn(by: uid) }.count
        // The pairing's list (7.7): the app's children, and the logins no
        // pane of this context has — the main actor only hands them out.
        let appChildren = table.liveChildren(of: context.appPID)
        let unclaimed = SurfaceProcesses.unclaimedLogins(appChildren, claimed: Set(context.panes.compactMap(\.login)))
        bound(tick: tick, wanted: wantedIDs)
        let ended = kernel.uptime()
        cost.wall = ended >= started ? ended - started : 0
        cost.cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- cpuStart
        cadence.record(cost: cost.wall, full: demand.full, at: now)
        let snapshot = ActivitySnapshot(
            tick: tick, demand: demand, time: now, date: date, uid: uid, table: table, facts: facts, panes: slices, helpers: helpers,
            appChildren: appChildren, unclaimedLogins: unclaimed, unread: unread.count, cost: cost, isStretched: cadence.isStretched)
        shared.withLock { lastSnapshot = snapshot }
        return snapshot
    }

    /// The identities whose markers carry one of `tags`, by tag: what left
    /// those panes' trees (nohup, disown), as far as the cache knows.
    private func carrying(_ tags: Set<String>) -> [String: [ActivityProcessID]] {
        var found: [String: [ActivityProcessID]] = [:]
        guard !tags.isEmpty else { return found }
        for (identity, entry) in known {
            if let tag = entry.tag, tags.contains(tag) { found[tag, default: []].append(identity) }
        }
        return found
    }

    /// Drops what is no longer in the table.
    private func forget(keeping live: Set<ActivityProcessID>) {
        let ended = known.keys.filter { !live.contains($0) }
        for identity in ended { known[identity] = nil }
        baselines.prune(keeping: live)
        socketScan.advance(keeping: live)
        folders.prune(keeping: live)
    }

    /// Past the cache's limit, the identities least recently wanted go —
    /// those this tick wants last of all.
    private func bound(tick: Int, wanted: Set<ActivityProcessID>) {
        let excess = known.count - max(limits.cacheLimit, 0)
        guard excess > 0 else { return }
        let order = known.sorted { lhs, rhs in
            let left = (wanted.contains(lhs.key), lhs.value.used, lhs.key)
            let right = (wanted.contains(rhs.key), rhs.value.used, rhs.key)
            if left.0 != right.0 { return !left.0 }
            if left.1 != right.1 { return left.1 < right.1 }
            return left.2 < right.2
        }
        for (identity, _) in order.prefix(excess) { known[identity] = nil }
    }

    /// Whether `process` lacks a read this tick asks for: its identity
    /// (path, code signing, name); for the user's, its markers (outside
    /// every tree) or its argv.
    private func needs(_ process: ActivityProcess, command: Bool, markers: Bool, uid: uid_t) -> Bool {
        guard let entry = known[process.identity] else { return true }
        guard process.isOwn(by: uid), !process.isZombie else { return false }
        return (command && entry.argumentsUnread) || (markers && entry.markersUnread)
    }

    /// Reads what `process` lacks of what is asked.
    private func readIdentity(
        _ process: ActivityProcess, command: Bool, markers: Bool, tick: Int, uid: uid_t, fallbacks: inout Int, cost: inout ActivityTickCost
    ) {
        let pid = process.pid
        let own = process.isOwn(by: uid) && !process.isZombie
        var entry: Known
        if let cached = known[process.identity] {
            entry = cached
        } else {
            entry = Known(comm: process.shortName, used: tick)
            entry.path = kernel.path(of: pid)
            entry.signing = kernel.codeSigning(of: pid, fallbacks: &fallbacks)
            if own {
                entry.procName = kernel.name(of: pid)
                if entry.signing?.isRestricted == true { entry.markers = .hidden }
            } else {
                entry.markers = .hidden
                entry.arguments = .unreadable
            }
            cost.identitiesRead += 1
        }
        if own {
            let scan = markers && entry.markersUnread
            if command && entry.argumentsUnread {
                cost.commandsRead += 1
                if let arguments = ProcessArguments.read(pid, kernel: kernel, markers: scan, codeSigning: entry.signing) {
                    entry.arguments = .read(arguments)
                    if scan { entry.markers = arguments.markers.map(Known.Markers.read) ?? .hidden }
                } else {
                    entry.arguments = .unreadable
                    if scan { entry.markers = .hidden }
                }
            } else if scan {
                entry.markers = ProcessArguments.markers(pid, kernel: kernel, codeSigning: entry.signing).map(Known.Markers.read) ?? .hidden
            }
        }
        entry.used = tick
        known[process.identity] = entry
    }

    /// What a snapshot says of `process`.
    private static func facts(
        _ process: ActivityProcess, _ entry: Known?, usage: ActivityUsage?, rates: ActivityRates?, sockets: SocketScan.Sockets?,
        folder: ProcessFolders.Folder?
    ) -> ActivityFacts {
        var facts = ActivityFacts(name: process.shortName)
        if let entry {
            // Another user's argv is unreadable from the start; the user's
            // is read, or found unreadable, only when a level asks for it:
            // markers alone leave it waiting.
            facts.isRead = !entry.argumentsUnread
            facts.name = name(comm: process.shortName, procName: entry.procName, path: entry.path)
            facts.path = entry.path
            facts.codeSigning = entry.signing
            if case .read(let arguments) = entry.arguments {
                facts.command = arguments.command
                facts.label = arguments.label
                facts.isCut = arguments.isCut
                facts.isTitle = arguments.isTitle
            }
            if case .read(let markers) = entry.markers { facts.markers = markers }
        }
        facts.usage = usage
        facts.rates = rates
        facts.sockets = sockets
        facts.folder = folder
        return facts
    }

    /// A row's name (6.5): `proc_name`'s, which is `pbi_name` when set —
    /// else `p_comm`, cut at 16 bytes, which the path's file completes —
    /// else the path's file; `p_comm` only while nothing else is known.
    static func name(comm: String, procName: String?, path: String?) -> String {
        let file = path.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        if let procName, !procName.isEmpty {
            if procName == comm, let file, file.count > comm.count, file.hasPrefix(comm) { return file }
            return procName
        }
        return file ?? comm
    }

    /// The agent `process` is, by its name or its masked argv's first word.
    private static func agent(_ process: ActivityProcess, _ entry: Known?) -> Agent? {
        let name = entry.map { name(comm: process.shortName, procName: $0.procName, path: $0.path) } ?? process.shortName
        var command = ""
        if case .read(let arguments)? = entry?.arguments { command = arguments.command }
        return Agent.of(name: name, command: command)
    }

    /// `root`'s descendants, depth first, oldest child first; at most `limit`.
    static func depthFirst(below root: ActivityProcessID, in table: ProcessTable, limit: Int = 10_000) -> [ActivityProcessID] {
        var found: [ActivityProcessID] = []
        var stack = table.children(of: root).reversed().map(\.identity)
        while let next = stack.popLast(), found.count < limit {
            found.append(next)
            stack += table.children(of: next).reversed().map(\.identity)
        }
        return found
    }

    /// Overterm's helpers: the app's children that aren't a pane's `login`
    /// (6.5, rule 2), and everything below them.
    static func helpers(of context: ActivityContext, in table: ProcessTable) -> [ActivityProcessID] {
        guard let app = table.process(pid: context.appPID) else { return [] }
        let logins = Set(context.panes.compactMap(\.login))
        var found: [ActivityProcessID] = []
        for child in table.children(of: app.identity) where child.shortName != "login" && !logins.contains(child.identity) {
            found.append(child.identity)
            found += depthFirst(below: child.identity, in: table)
        }
        return found
    }
}

/// How often the census reads on a busy Mac (7.3): when three ticks in a
/// row cost more than four times their level's budget — a light tick over
/// 8 ms, a full one over 48 ms — the cadence stretches to 5 s, and the page
/// says so; a minute of normal ticks brings it back. A tick's cost is its
/// wall time on the kernel's clock: what a busy Mac makes longer. A value
/// on the sampler's queue.
struct ActivityCadence: Hashable, Sendable {
    /// A tick's budget at each level (7.3).
    static let lightBudget: UInt64 = 2_000_000
    static let fullBudget: UInt64 = 12_000_000
    /// Over this many times its budget, a tick is slow.
    static let slowFactor: UInt64 = 4
    /// Slow ticks in a row that stretch it.
    static let slowRun = 3
    /// The cadence stretched.
    static let stretched: Duration = .seconds(5)
    /// How long it takes normal ticks to bring it back.
    static let recovery: UInt64 = 60_000_000_000

    private(set) var isStretched = false
    private var slowInARow = 0
    private var lastSlow: UInt64 = 0

    /// A tick at `time` that cost `cost` at its level.
    mutating func record(cost: UInt64, full: Bool, at time: UInt64) {
        let budget = full ? Self.fullBudget : Self.lightBudget
        if cost > budget * Self.slowFactor {
            slowInARow += 1
            lastSlow = time
            if slowInARow >= Self.slowRun { isStretched = true }
        } else {
            slowInARow = 0
            if isStretched, time >= lastSlow + Self.recovery { isStretched = false }
        }
    }
}
