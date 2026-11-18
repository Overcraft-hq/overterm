import Darwin
import Foundation

/// A process's row on the Activity page (docs/design/activity/analysis.md,
/// 6.4, 6.5): what one full snapshot said of it. Values only; a first
/// sample's CPU is nil, drawn "—", never 0.
struct ActivityProcessRow: ResourceTableRow, Sendable {
    /// Its identity's "pid:start": the selection's key, never the pid alone.
    let id: String
    let identity: ActivityProcessID
    let name: String
    var cpu: Double?
    /// The footprint, Activity Monitor's Memory; nil for another user's.
    let memory: UInt64?
    let threads: Int32?
    let state: ActivityState
    /// `p_starttime`.
    let started: Date
    /// The Started column's words: today's start as its time, an earlier
    /// one as its date — made with the rows, off the main thread.
    let startedText: String
    /// Its effective user's name.
    let user: String
    let isOwn: Bool
    /// The tab it runs in (a pane's tree, or what carries the pane's tag),
    /// by its title; nil outside every tab.
    let tab: UUID?
    let tabTitle: String?
    /// Who it belongs to, and why (6.5).
    var owner: ActivityOwner?
    /// Its tab's checkout, by its folder's name.
    var checkout: String?
    /// The Where column's words: tab · checkout · agent, or its owner.
    var whereText = ""
    /// The TCP ports it listens on, by number.
    var listening: [Int] = []
    /// Its depth in the list's tree, whether it has children there, and
    /// whether they are folded.
    var depth = 0
    var hasChildren = false
    var folded = false
    /// An agent's row: what runs under it, counted ("12 MCP · 3 shells").
    var agentCounts: String?
    /// Kept in a filtered tree only as a match's ancestor: drawn dimmed,
    /// so the match keeps its place (6.6).
    var dimmed = false

    // What the other columns, the filter and the detail read (6.5, 6.6):
    // kinfo's record, the masked command, the usage beyond the footprint.
    var parentPID: pid_t = 0
    var group: pid_t = 0
    var nice: Int8 = 0
    /// Its controlling terminal's name (`ttys003`); nil without one.
    var terminal: String?
    /// argv masked as it was read (9.3); nil for another user's, or unread.
    var command: String?
    /// An interpreter's label (`ActivityText.label`).
    var label: String?
    var path: String?
    var residentSize: UInt64?
    /// User and system CPU time, ns.
    var cpuTime: UInt64?
    var priority: Int32?
    /// W, an estimate.
    var energy: Double?
    /// Idle wake-ups a second (`ri_pkg_idle_wkups`, Activity Monitor's).
    var idleWakeups: Double?
    /// Bytes a second.
    var diskRead: Double?
    var diskWritten: Double?
    /// What its power assertions keep awake; nil where nothing was read.
    var sleepHold: ActivitySleepHold?
    /// Its CPU, 15 min, a cell of 15 s each (`ActivityRing`), nil where not
    /// sampled; nil without any history. `stripSince`: when it began, when
    /// that is inside the 15 minutes.
    var strip: [Double?]?
    var stripSince: Date?
    /// New since the rows shown last (6.7): tinted for a tick, or 3 s
    /// when ticks are faster — since `newSince`.
    var isNew = false
    var newSince: Date?
    /// Gone since the last census: shown once more, dimmed, "ended".
    var ended = false
    /// What changed, on this row (6.11).
    var chips: [ActivityRowChip] = []
    /// Intel code under Rosetta.
    var translated = false
    var ignoresHangup = false
    /// Its pane's number in its tab, from 1.
    var pane: Int?
    var branch: String?
    /// The UDP ports it is bound on.
    var boundUDP: [Int] = []
    /// It holds an established TCP connection.
    var connected = false
    /// Activity stopped it, or put it in the background (6.10): only those
    /// are said so — the background state can't be read back (3.9).
    var stoppedHere = false
    var backgroundHere = false
    /// Left Behind (6.9): a bulk Stop may take it — certain, not ignoring
    /// SIGHUP, detached, an app nor a terraform write, nor kept.
    var bulkEligible = false

    var height: CGFloat { 24 }

    /// What VoiceOver says of it (6.4): name, pid, CPU, where.
    var accessibilityLabel: String {
        var words = ["\(name), pid \(identity.pid)"]
        if let cpu { words.append("\(ActivityRows.percent(cpu)) percent CPU") }
        if let tabTitle {
            words.append("in “\(tabTitle)”")
            if let checkout { words.append(checkout) }
        } else if let label = owner.flatMap(ActivityRows.ownerLabel) {
            words.append(label)
        } else if !isOwn {
            words.append(user)
        }
        if ended { words.append("ended") } else if isNew { words.append("new") }
        return words.joined(separator: ", ")
    }
}

/// What the page says around its lists (6.4): the counts, the busiest
/// five, the meters, whether the census is still reading.
struct ActivitySummary: Equatable, Sendable {
    /// Every process the table listed, and the user's.
    var processes = 0
    var own = 0
    /// The rows shown: fewer than `processes` in a test run (its own tabs')
    /// or with other users' left out.
    var shown = 0
    /// Left Behind's rows in scope (6.9).
    var leftBehind = 0
    var listening = 0
    /// The rows the filter matched, its dimmed ancestors left out: `shown`
    /// when there is no filter.
    var matched = 0
    /// The user's processes' threads, summed.
    var threads = 0
    /// The user's processes' energy, summed (6.4): W, an estimate; nil
    /// where none was rated.
    var energy: Double?
    /// The five busiest rows shown, CPU first: names, pids and rates only.
    var busiest: [Busy] = []
    var meters: SystemMeters?
    /// The meters' 15 minutes (6.11): the Mac's CPU and memory used.
    var history: [TimeChartData] = []
    /// Identities the churn budget left for a later tick: still reading.
    var unread = 0
    /// No rates yet: the first full tick.
    var firstSample = true
    /// A test run lists only its own tabs' processes (9.9).
    var scopedToRun = false
    /// What was read of every user's listeners (D-25).
    var others = ActivityOtherListeners.off

    struct Busy: Equatable, Sendable {
        let id: String
        let name: String
        let cpu: Double
    }
}

/// What one full snapshot makes of the page: its rows, sorted, and what is
/// said around them. Pure, run off the main thread (7.7).
struct ActivityPageContent: Sendable {
    /// Every process row in scope, flat, sorted: the switcher's, ⌘C's.
    var processes: [ActivityProcessRow] = []
    /// Processes as the page lists them: grouped, as a tree (6.5).
    var list: [ActivityListItem] = []
    /// Left Behind's section (6.9): its rows by checkout, by the same filter.
    var leftBehind: [ActivityListItem] = []
    var ports: [ActivityPortRow] = []
    /// Every listener of the rows in scope, whatever either filter says:
    /// the detail's, `o`'s (6.6 keeps each section's filter its own).
    var listeners: [ActivityPortRow] = []
    /// Connection lines past Listening's cap (500): said below the list.
    var droppedConnections = 0
    /// Every process row in scope before the filter: where the detail's
    /// tree stops (9.9 — a test run's own tabs' processes alone).
    var identities: Set<ActivityProcessID> = []
    var summary = ActivitySummary()
    /// The selection's process as a verb sees it (6.10): read here, off the
    /// main thread, with every owner of the snapshot — not only the rows
    /// a scope or a filter left —, so the list and the sheet class it alike.
    var subject: ActivityVerbSubject?
    /// When its census was read: a process started after it is new to
    /// the next rows (6.7).
    var madeAt: Date?
    /// The selection's history (`Options.historyOf`), made with the rows.
    var detailHistory: ActivityDetailHistory?
    /// The snapshot's owners when they were read: a selection made between
    /// two publishes is read with them (`ActivityRows.subject`).
    var attribution: ActivityAttribution?
}

enum ActivityRows {
    /// How long a new process is tinted at least (6.7): 3 s, and never
    /// less than a tick.
    static let newFor: TimeInterval = 3

    /// What the page lists of `snapshot`.
    struct Options: Sendable {
        /// Tabs' titles, by id, every window's.
        var titles: [UUID: String] = [:]
        /// What the main actor says of each tab: its title, checkout,
        /// branch, its place in the strips. `titles` makes them when empty.
        var tabs: [UUID: ActivityTabFacts] = [:]
        /// The census's context the owners are read against (6.5).
        var context = ActivityContext()
        /// Every known checkout (the tabs', the worktrees'), and running
        /// apps' bundles by pid.
        var checkouts: [String] = []
        var runningApps: [pid_t: String] = [:]
        /// How Processes is grouped and whether as a tree; nil: no list
        /// (the switcher's).
        var grouping: ActivityGrouping? = .checkout
        var tree = true
        var scope = ActivityScope.mac
        /// Folds by row id (true folded); a row not in it takes its default.
        var folds: [String: Bool] = [:]
        /// The containers running, with their usage (`DockerUsageMonitor`).
        var containers: [ActivityContainer] = []
        /// A row a link shows: the groups holding it unfolded.
        var reveal: String?
        /// Process rows a group shows before "+N more".
        var groupLimit = 500
        /// Other users' processes too (`activity.everyone`).
        var everyone = true
        /// A test run (`AppEnvironment.isIsolated`): only the run's own
        /// tabs' processes are rows, the rest counted (6.4, 9.9).
        var isolated = false
        var processSort: ResourceSort? = ResourceSort(column: "cpu", ascending: false)
        var portSort: ResourceSort? = ResourceSort(column: "port")
        /// The process the page lists verbs for — the selection's —, and
        /// what the main actor knows of stopped and backgrounded ones.
        var subjectOf: ActivityProcessID?
        /// The selection whose history the detail charts (6.11): made here,
        /// off the main thread, with the rows.
        var historyOf: ActivityProcessID?
        var known = ActivityVerbSubject.Known()
        /// What each section's filter field says (6.6).
        var processFilter = ""
        var portFilter = ""
        /// Listening's connections (`c`), the LaunchAgents' programs
        /// (`LaunchdJobs`), the ephemeral range's first port.
        var connections = false
        var launchAgents: [LaunchdJobs.Agent] = []
        var ephemeralFirst = 49_152
        /// Every user's listeners as nettop last read them (D-25), and
        /// what was read of them: shown only where believed. launchd's
        /// socket jobs name pid 1's (`LaunchdSockets`).
        var others: NettopListeners.Reading?
        var othersState = ActivityOtherListeners.off
        var launchdSockets: [LaunchdSockets.Job] = []
        /// The rows shown before this census: what has gone since is shown
        /// once more, "ended" (6.7); one absent from them is new. Empty on
        /// a first build.
        var previous: [ActivityProcessRow] = []
        /// Rows were shown before: a process absent from them that started
        /// after `shownAt` is new to the person, not merely to a page just
        /// opened.
        var marksNew = false
        /// When the census `previous` was made of was read: a process
        /// started before it was there to be shown — a wider scope, a
        /// filter cleared, isn't new.
        var shownAt: Date?
        /// The same census made again (a sort, a fold): `previous`'s ended
        /// rows stay as they were, still once.
        var repeatsEnded = false
    }

    /// The tabs' facts as the rows read them: a title made into facts, each
    /// title masked — a tab's title is often the command running in it,
    /// masked as every command is wherever it leaves the strip (9.3).
    private static func tabFacts(_ options: Options) -> [UUID: ActivityTabFacts] {
        var tabFacts = options.tabs
        for (id, title) in options.titles where tabFacts[id] == nil { tabFacts[id] = ActivityTabFacts(id: id, title: title) }
        for (id, tab) in tabFacts { tabFacts[id]?.title = ActivityText.title(tab.title) }
        return tabFacts
    }

    /// Whether `owner` is Left Behind by this run's own pane or agent (6.9).
    static func isRunsOwnLeftover(_ owner: ActivityOwner?) -> Bool {
        switch owner?.leftBehind {
        case .closedPane?, .agentRun?: true
        default: false
        }
    }

    /// Every owner of `snapshot` (6.5), with the main actor's facts.
    private static func owners(of snapshot: ActivitySnapshot, _ options: Options, tabs tabFacts: [UUID: ActivityTabFacts]) -> ActivityAttribution {
        ActivityAttribution.of(
            snapshot, context: options.context,
            inputs: ActivityAttribution.Inputs(
                tabs: tabFacts, checkouts: options.checkouts + tabFacts.values.compactMap(\.checkout), runningApps: options.runningApps))
    }

    /// `identity` as a verb sees it (6.10) in `snapshot`, with every owner:
    /// `attribution` when the rows read it, else read here. Off the main
    /// thread — the page's selection between two publishes.
    static func subject(_ identity: ActivityProcessID, of snapshot: ActivitySnapshot, _ options: Options, attribution: ActivityAttribution?)
        -> ActivityVerbSubject?
    {
        let owners = attribution ?? owners(of: snapshot, options, tabs: tabFacts(options))
        return ActivityVerbSubject.read(identity, in: snapshot, owners: owners, known: options.known)
    }

    static func content(of snapshot: ActivitySnapshot, _ options: Options) -> ActivityPageContent {
        let tabFacts = tabFacts(options)
        let titles = tabFacts.mapValues(\.title)
        // The owners only where something reads them: the switcher's flat
        // rows over the whole Mac are ranked by CPU and port alone — unless
        // a selection's verbs are listed.
        let attribution =
            options.grouping == nil && options.scope == .mac && options.subjectOf == nil ? nil : owners(of: snapshot, options, tabs: tabFacts)
        let today = Calendar.current.startOfDay(for: snapshot.date)
        // Where each process runs: the first pane that places it.
        var tabs: [ActivityProcessID: UUID] = [:]
        for slice in snapshot.panes {
            for identity in slice.placed where tabs[identity] == nil { tabs[identity] = slice.tab }
        }
        let uid = snapshot.uid
        var panesByTab: [UUID: [String]] = [:]
        for slice in snapshot.panes { panesByTab[slice.tab, default: []].append(slice.tag) }
        var agentTabs: [ActivityProcessID: UUID] = [:]
        for slice in snapshot.panes { if let agent = slice.agent { agentTabs[agent] = slice.tab } }
        let before = options.marksNew ? Dictionary(options.previous.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
        var rows: [ActivityProcessRow] = []
        rows.reserveCapacity(snapshot.table.processes.count)
        var threads = 0
        var energy: Double?
        var rated = false
        for process in snapshot.table.processes {
            let identity = process.identity
            let own = process.isOwn(by: uid)
            let facts = snapshot.facts[identity]
            if own, let usage = facts?.usage { threads += Int(usage.threads) }
            if own, let watts = facts?.rates?.energy { energy = (energy ?? 0) + watts }
            if facts?.rates != nil { rated = true }
            // A test run's: its tabs' processes, and what its own closed
            // panes and agents' runs left (6.9).
            if options.isolated, tabs[identity] == nil, !isRunsOwnLeftover(attribution?[identity]) { continue }
            if !own, !options.everyone { continue }
            let owner = attribution?[identity]
            guard inScope(owner, options.scope, tabs: tabFacts, context: options.context, identity: identity) else { continue }
            let tab = tabs[identity]
            let started = Date(timeIntervalSince1970: Double(identity.start) / 1_000_000)
            var row = ActivityProcessRow(
                id: identity.id, identity: identity, name: snapshot.name(of: identity) ?? process.shortName, cpu: facts?.rates?.cpuPercent,
                memory: facts?.usage?.footprint, threads: facts?.usage?.threads,
                state: ActivityState(status: process.status, runningThreads: own ? facts?.usage?.runningThreads : nil),
                started: started, startedText: startedText(started, today: today),
                user: own ? userName(uid) : userName(process.effectiveUID), isOwn: own, tab: tab, tabTitle: tab.flatMap { titles[$0] })
            row.owner = owner
            row.checkout = tab.flatMap { tabFacts[$0]?.checkout }.map(folderName)
            row.branch = tab.flatMap { tabFacts[$0]?.branch }
            let records = facts?.sockets?.records ?? []
            row.listening = Array(Set(records.filter(\.isListening).map { Int($0.localPort) })).sorted()
            row.boundUDP = Array(Set(records.filter(\.isBoundUDP).map { Int($0.localPort) })).sorted()
            row.connected = records.contains { $0.kind == .tcp && $0.state == .established }
            row.parentPID = process.parentPID
            row.group = process.group
            row.nice = process.nice
            row.terminal = process.terminal.flatMap(terminalName)
            row.translated = process.flags.contains(.translated)
            row.ignoresHangup = process.ignoresHangup
            row.command = facts?.command
            row.label = facts?.label
            row.path = facts?.path
            row.residentSize = facts?.usage?.residentSize
            row.cpuTime = facts?.usage?.cpuTime
            row.priority = facts?.usage?.priority
            row.energy = facts?.rates?.energy
            row.idleWakeups = facts?.rates?.idleWakeupsPerSecond
            row.diskRead = facts?.rates?.diskReadPerSecond
            row.diskWritten = facts?.rates?.diskWrittenPerSecond
            row.sleepHold = snapshot.sleepHolds.map { $0[process.pid] ?? [] }
            if own {
                row.strip = snapshot.history.cpuStrip(.process(identity), now: snapshot.historyNow)
                row.stripSince = snapshot.history.since(.process(identity), now: snapshot.historyNow).map { snapshot.date(of: $0) }
                let agentTab = agentTabs[identity]
                let waiting = agentTab.flatMap { tabFacts[$0] }.flatMap { $0.waiting ? $0.waitingSince : nil }
                row.chips = ActivityChips.of(identity, agentWaitingSince: waiting, isAgent: agentTab != nil, in: snapshot)
            }
            if options.marksNew {
                if let was = before[identity] {
                    // Tinted on: a tick at least, 3 s at least.
                    if was.isNew, let since = was.newSince, snapshot.date.timeIntervalSince(since) < ActivityRows.newFor {
                        row.isNew = true
                        row.newSince = since
                    }
                } else if let shownAt = options.shownAt, started > shownAt {
                    row.isNew = true
                    row.newSince = snapshot.date
                }
            }
            if case .pane(let tag)? = owner?.place, let tab = owner?.tab {
                row.pane = panesByTab[tab]?.firstIndex(of: tag).map { $0 + 1 }
            }
            row.whereText = whereText(row, tabs: tabFacts)
            row.stoppedHere = process.isStopped && options.known.stoppedHere.contains(identity)
            row.backgroundHere = options.known.backgroundHere.contains(identity)
            if let owner, owner.place == .leftBehind {
                let terraform = TerraformCommandLine.tools.contains(ActivityPaneSet.executableName(process, facts: facts))
                row.bulkEligible = LeftBehind.isBulkEligible(
                    owner, process: process, terraformWrite: terraform, kept: options.context.kept.contains(identity))
            }
            rows.append(row)
        }
        // A server not where it asked to be (6.8, 6.11).
        for (id, chip) in ActivityMovedServers.find(rows, tabs: tabFacts) {
            if let index = rows.firstIndex(where: { $0.id == id }) { rows[index].chips.append(chip) }
        }
        // Listening, the detail and the busiest read every row in scope:
        // Processes' filter is that section's alone (6.6).
        let inScope = rows
        // What has gone since the rows shown last: once more, dimmed (6.7)
        // — never into what the detail, Listening or the busiest read.
        for var gone in options.previous where (options.repeatsEnded || !gone.ended) && snapshot.table.process(gone.identity) == nil {
            gone.ended = true
            gone.isNew = false
            gone.newSince = nil
            gone.cpu = nil
            gone.chips = []
            gone.listening = []
            rows.append(gone)
        }
        // The filter (6.6): in a tree a match keeps its ancestors, dimmed.
        let filter = ActivityFilter(options.processFilter)
        var matched = rows.count { !$0.ended }
        if !filter.isEmpty {
            let kept = filtered(
                rows, by: filter, now: snapshot.date, ancestorsIn: options.grouping != nil && options.tree ? snapshot.table : nil,
                grouping: options.grouping)
            matched = kept.count { !$0.dimmed && !$0.ended }
            rows = kept
        }
        var content = ActivityPageContent()
        content.madeAt = snapshot.date
        content.attribution = attribution
        if let identity = options.subjectOf, let attribution {
            content.subject = ActivityVerbSubject.read(identity, in: snapshot, owners: attribution, known: options.known)
        }
        content.processes = sorted(rows, by: options.processSort)
        if let identity = options.historyOf, snapshot.table.process(identity)?.isOwn(by: uid) == true {
            content.detailHistory = ActivityDetailHistory.make(identity, in: snapshot)
        }
        if let grouping = options.grouping {
            // A checkout's containers are its scope's and wider's (6.5): a
            // tab's is its panes, what left them, its forwards.
            var listed = options
            if case .tab = options.scope { listed.containers = [] }
            // A filtered list shows what matches, never a stack it didn't.
            if !filter.isEmpty { listed.containers = [] }
            content.list = list(rows, grouping: grouping, in: snapshot, tabs: tabFacts, options: listed)
        }
        content.leftBehind = leftBehindList(rows, tabs: tabFacts, options: options)
        // Listening (6.8): its listeners, owners, collisions and, asked
        // for, the user's connections.
        let portFilter = ActivityFilter(options.portFilter)
        var portInputs = ActivityPorts.Inputs()
        portInputs.context = options.context
        portInputs.tabs = tabFacts
        portInputs.containers = options.containers
        portInputs.launchAgents = options.launchAgents
        portInputs.ephemeralFirst = options.ephemeralFirst
        portInputs.connections = options.connections || portFilter.asksConnections
        portInputs.folds = options.folds
        portInputs.unfold = !portFilter.isEmpty
        portInputs.scope = options.scope
        portInputs.others = options.others
        portInputs.everyone = options.everyone
        portInputs.launchdSockets = options.launchdSockets
        let made = ActivityPorts.make(of: inScope, in: snapshot, inputs: portInputs)
        content.listeners = made.listeners
        content.droppedConnections = made.droppedConnections
        content.identities = Set(inScope.map(\.identity))
        var ports = made.rows
        if !portFilter.isEmpty { ports = ports.filter { $0.kind != .folded && portFilter.matches($0) } }
        // The fold last, whatever the sort.
        content.ports = sorted(ports.filter { $0.kind != .folded }, by: options.portSort) + ports.filter { $0.kind == .folded }
        var summary = ActivitySummary()
        summary.processes = snapshot.table.processes.count
        summary.own = snapshot.table.processes.lazy.filter { $0.isOwn(by: uid) }.count
        summary.shown = rows.count { !$0.ended }
        summary.leftBehind = inScope.count { $0.owner?.place == .leftBehind }
        summary.matched = matched
        // Every listener in scope, folded or filtered away too.
        summary.listening = made.listeners.count
        summary.threads = threads
        summary.energy = energy
        summary.busiest = Array(
            inScope.compactMap { row in row.cpu.map { ActivitySummary.Busy(id: row.id, name: row.name, cpu: $0) } }.sorted { $0.cpu > $1.cpu }.prefix(5))
        summary.meters = snapshot.meters
        summary.history = ActivityHistoryCharts.charts(.system, subject: "system", measures: ActivityHistoryCharts.systemMeasures, in: snapshot)
        summary.unread = snapshot.unread
        summary.firstSample = !rated
        summary.scopedToRun = options.isolated
        summary.others = options.othersState
        content.summary = summary
        return content
    }

    /// The rows `filter` keeps: its matches and, with a table to read
    /// parents from, their ancestors in the match's own tree, dimmed
    /// (6.6) — up to the first parent another group or owner holds: a
    /// pane's process up to the pane's login, never Overterm or launchd
    /// pulled into their groups.
    static func filtered(
        _ rows: [ActivityProcessRow], by filter: ActivityFilter, now: Date, ancestorsIn table: ProcessTable?, grouping: ActivityGrouping? = nil
    ) -> [ActivityProcessRow] {
        var keep = Set<ActivityProcessID>()
        var dim = Set<ActivityProcessID>()
        let present = Dictionary(rows.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        for row in rows where filter.matches(row, now: now) {
            keep.insert(row.identity)
            guard let table else { continue }
            // Up the parents among the rows, bounded by their number.
            var current = row.identity
            for _ in 0..<min(rows.count, 256) {
                guard let parent = table.parent(of: current)?.identity, let above = present[parent], sameTree(above, row, grouping: grouping) else {
                    break
                }
                if !keep.contains(parent) { dim.insert(parent) }
                current = parent
            }
        }
        dim.subtract(keep)
        return rows.compactMap { row in
            if keep.contains(row.identity) { return row }
            guard dim.contains(row.identity) else { return nil }
            var dimmed = row
            dimmed.dimmed = true
            return dimmed
        }
    }

    /// Whether `above` sits in `row`'s tree as the list draws it: the same
    /// owner's place and the same group.
    static func sameTree(_ above: ActivityProcessRow, _ row: ActivityProcessRow, grouping: ActivityGrouping?) -> Bool {
        guard above.owner?.place == row.owner?.place else { return false }
        switch grouping {
        case .agent?: return above.owner?.agent == row.owner?.agent
        case .user?: return above.user == row.user
        case .app?:
            // `byApp`'s key: an app's place, else the executable's name.
            switch row.owner?.place {
            case .app?, .engine?, .overterm?, .anotherOverterm?: return true
            default: return above.name == row.name
            }
        case .checkout?, .tab?, .none?, nil: return true
        }
    }

    private static let terminals = NSLock()
    nonisolated(unsafe) private static var terminalNames: [dev_t: String] = [:]

    /// A terminal's name (`ttys003`), `devname_r`, kept for the app's life.
    static func terminalName(_ device: dev_t) -> String? {
        if let known = terminals.withLock({ terminalNames[device] }) { return known.isEmpty ? nil : known }
        var buffer = [CChar](repeating: 0, count: 64)
        let name = devname_r(device, S_IFCHR, &buffer, Int32(buffer.count)).map { String(cString: $0) } ?? ""
        terminals.withLock { terminalNames[device] = name }
        return name.isEmpty ? nil : name
    }

    /// The processes in `sort`'s order, a column's missing values last.
    static func sorted(_ rows: [ActivityProcessRow], by sort: ResourceSort?) -> [ActivityProcessRow] {
        guard let sort else { return rows }
        switch sort.column {
        case "name": return sort.sorted(rows) { $0.name.lowercased() }
        case "pid": return sort.sorted(rows) { $0.identity.pid }
        case "cpu": return sort.sorted(rows) { $0.cpu }
        case "memory": return sort.sorted(rows) { $0.memory }
        case "threads": return sort.sorted(rows) { $0.threads }
        case "state": return sort.sorted(rows) { $0.state.letter.isEmpty ? nil : $0.state.letter }
        case "started": return sort.sorted(rows) { $0.started }
        case "user": return sort.sorted(rows) { $0.user }
        case "where": return sort.sorted(rows) { $0.tabTitle?.lowercased() }
        case "rss": return sort.sorted(rows) { $0.residentSize }
        case "time": return sort.sorted(rows) { $0.cpuTime }
        case "nice": return sort.sorted(rows) { Int($0.nice) }
        case "priority": return sort.sorted(rows) { $0.priority }
        case "ppid": return sort.sorted(rows) { $0.parentPID }
        case "pgid": return sort.sorted(rows) { $0.group }
        case "tty": return sort.sorted(rows) { $0.terminal }
        case "kind": return sort.sorted(rows) { $0.translated ? 1 : 0 }
        case "path": return sort.sorted(rows) { $0.path }
        case "command": return sort.sorted(rows) { $0.command }
        case "cpu15": return sort.sorted(rows) { row in row.strip.flatMap { cells in cells.compactMap { $0 }.max() } }
        case "energy": return sort.sorted(rows) { $0.energy }
        case "wakeups": return sort.sorted(rows) { $0.idleWakeups }
        case "diskRead": return sort.sorted(rows) { $0.diskRead }
        case "diskWritten": return sort.sorted(rows) { $0.diskWritten }
        case "sleep": return sort.sorted(rows) { $0.sleepHold.flatMap { $0.isEmpty ? nil : $0.rawValue } }
        default: return rows
        }
    }

    static func sorted(_ rows: [ActivityPortRow], by sort: ResourceSort?) -> [ActivityPortRow] {
        guard let sort else { return rows }
        switch sort.column {
        case "port": return sort.sorted(rows) { $0.port }
        case "proto": return sort.sorted(rows) { $0.proto }
        case "address": return sort.sorted(rows) { $0.reach }
        case "process": return sort.sorted(rows) { $0.process.lowercased() }
        case "pid": return sort.sorted(rows) { $0.holder?.pid }
        case "where": return sort.sorted(rows) { $0.whereText.isEmpty ? nil : $0.whereText.lowercased() }
        case "owner": return sort.sorted(rows) { $0.ownerText.lowercased() }
        case "since": return sort.sorted(rows) { $0.since }
        case "clients": return sort.sorted(rows) { $0.clients }
        case "backlog": return sort.sorted(rows) { $0.backlogLimit > 0 ? $0.backlog : nil }
        case "note": return sort.sorted(rows) { $0.note }
        default: return rows
        }
    }

    // Formatting is thread-safe; only these two, made once.
    nonisolated(unsafe) private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    nonisolated(unsafe) private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    /// A time of today as the page says it: "14:02".
    static func clock(_ date: Date) -> String { timeFormat.string(from: date) }

    /// A start as the Started column says it: since `today`'s midnight as
    /// its time, earlier as its date.
    static func startedText(_ date: Date, today: Date) -> String {
        (date >= today && date < today.addingTimeInterval(86_400) ? timeFormat : dayFormat).string(from: date)
    }

    /// A CPU share as the page writes it: one decimal, a dot whatever the
    /// locale (`Text(verbatim:)` draws it).
    static func percent(_ value: Double) -> String { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value) }

    /// A footprint in Activity Monitor's units.
    static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = Double(value)
        var unit = 0
        while amount >= 1024, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        let format = unit == 0 || amount >= 100 ? "%.0f %@" : "%.1f %@"
        return String(format: format, locale: Locale(identifier: "en_US_POSIX"), amount, units[unit])
    }

    private static let users = NSLock()
    nonisolated(unsafe) private static var userNames: [uid_t: String] = [:]

    /// A uid's login name (`getpwuid_r`), kept for the app's life; its
    /// number where it has none.
    static func userName(_ uid: uid_t) -> String {
        if let known = users.withLock({ userNames[uid] }) { return known }
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 1024)
        let name: String =
            getpwuid_r(uid, &entry, &buffer, buffer.count, &result) == 0 && result != nil ? String(cString: entry.pw_name) : String(uid)
        users.withLock { userNames[uid] = name }
        return name
    }
}

/// What Listening knows of every user's listeners (D-25), said under the
/// list: every "none" must be true (6.4).
enum ActivityOtherListeners: Equatable, Sendable {
    /// `activity.otherListeners` is off.
    case off
    /// Nothing can be read here: why ("not read in a test run").
    case unavailable(String)
    /// Not read yet.
    case reading
    /// Read, and its answer held every listener of yours libproc found;
    /// read again every `period` seconds.
    case checked(Date, period: TimeInterval)
    /// Read, with none of yours to check it against.
    case unchecked(Date, period: TimeInterval)
    /// Read blind: its answer lacked yours — unknown, nothing shown.
    case blind(missing: Int)
    /// nettop failed: why.
    case failed(String)

    /// Its state for a reading, against what libproc finds now; reads
    /// every `period` seconds (5 × `activity.interval`).
    static func of(_ reading: NettopListeners.Reading?, period: TimeInterval) -> ActivityOtherListeners {
        guard let reading else { return .reading }
        switch reading.outcome {
        case .read(.checked): return .checked(reading.date, period: period)
        case .read(.unchecked): return .unchecked(reading.date, period: period)
        case .read(.blind(let missing)): return .blind(missing: missing)
        case .failed(let why): return .failed(why)
        }
    }

    /// "10 s", "2.5 s".
    private static func seconds(_ period: TimeInterval) -> String {
        let rounded = (period * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded)) s" : String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), rounded) + ""
    }

    /// The note's sentence.
    var sentence: String {
        switch self {
        case .off: return "Other users' listeners — root's, macOS's — aren't read (Settings ▸ Activity)."
        case .unavailable(let why): return "Other users' listeners: \(why)."
        case .reading: return "Other users' listeners: reading…"
        case .checked(_, let period): return "Other users' listeners from nettop, every \(Self.seconds(period)), checked against yours."
        case .unchecked(_, let period):
            return "Other users' listeners from nettop, every \(Self.seconds(period)) — unchecked: none of yours listens to compare with."
        case .blind(let missing):
            return "Other users' listeners: unknown — nettop's answer lacked \(missing) of your own listener\(missing == 1 ? "" : "s"), so it was read blind."
        case .failed(let why): return "Other users' listeners: unknown — \(why)."
        }
    }
}
