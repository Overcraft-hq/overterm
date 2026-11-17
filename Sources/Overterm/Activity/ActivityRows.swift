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
    let cpu: Double?
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
    var listening = 0
    /// The rows the filter matched, its dimmed ancestors left out: `shown`
    /// when there is no filter.
    var matched = 0
    /// The user's processes' threads, summed.
    var threads = 0
    /// The five busiest rows shown, CPU first: names, pids and rates only.
    var busiest: [Busy] = []
    var meters: SystemMeters?
    /// Identities the churn budget left for a later tick: still reading.
    var unread = 0
    /// No rates yet: the first full tick.
    var firstSample = true
    /// A test run lists only its own tabs' processes (9.9).
    var scopedToRun = false

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
    /// The snapshot's owners when they were read: a selection made between
    /// two publishes is read with them (`ActivityRows.subject`).
    var attribution: ActivityAttribution?
}

enum ActivityRows {
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
        var known = ActivityVerbSubject.Known()
        /// What each section's filter field says (6.6).
        var processFilter = ""
        var portFilter = ""
        /// Listening's connections (`c`), the LaunchAgents' programs
        /// (`LaunchdJobs`), the ephemeral range's first port.
        var connections = false
        var launchAgents: [LaunchdJobs.Agent] = []
        var ephemeralFirst = 49_152
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
        var rows: [ActivityProcessRow] = []
        rows.reserveCapacity(snapshot.table.processes.count)
        var threads = 0
        var rated = false
        for process in snapshot.table.processes {
            let identity = process.identity
            let own = process.isOwn(by: uid)
            let facts = snapshot.facts[identity]
            if own, let usage = facts?.usage { threads += Int(usage.threads) }
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
            if case .pane(let tag)? = owner?.place, let tab = owner?.tab {
                row.pane = panesByTab[tab]?.firstIndex(of: tag).map { $0 + 1 }
            }
            row.whereText = whereText(row, tabs: tabFacts)
            row.stoppedHere = process.isStopped && options.known.stoppedHere.contains(identity)
            row.backgroundHere = options.known.backgroundHere.contains(identity)
            rows.append(row)
        }
        // Listening, the detail and the busiest read every row in scope:
        // Processes' filter is that section's alone (6.6).
        let inScope = rows
        // The filter (6.6): in a tree a match keeps its ancestors, dimmed.
        let filter = ActivityFilter(options.processFilter)
        var matched = rows.count
        if !filter.isEmpty {
            let kept = filtered(
                rows, by: filter, now: snapshot.date, ancestorsIn: options.grouping != nil && options.tree ? snapshot.table : nil,
                grouping: options.grouping)
            matched = kept.filter { !$0.dimmed }.count
            rows = kept
        }
        var content = ActivityPageContent()
        content.attribution = attribution
        if let identity = options.subjectOf, let attribution {
            content.subject = ActivityVerbSubject.read(identity, in: snapshot, owners: attribution, known: options.known)
        }
        content.processes = sorted(rows, by: options.processSort)
        if let grouping = options.grouping {
            // A checkout's containers are its scope's and wider's (6.5): a
            // tab's is its panes, what left them, its forwards.
            var listed = options
            if case .tab = options.scope { listed.containers = [] }
            // A filtered list shows what matches, never a stack it didn't.
            if !filter.isEmpty { listed.containers = [] }
            content.list = list(rows, grouping: grouping, in: snapshot, tabs: tabFacts, options: listed)
        }
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
        summary.shown = rows.count
        summary.matched = matched
        // Every listener in scope, folded or filtered away too.
        summary.listening = made.listeners.count
        summary.threads = threads
        summary.busiest = Array(
            inScope.compactMap { row in row.cpu.map { ActivitySummary.Busy(id: row.id, name: row.name, cpu: $0) } }.sorted { $0.cpu > $1.cpu }.prefix(5))
        summary.meters = snapshot.meters
        summary.unread = snapshot.unread
        summary.firstSample = !rated
        summary.scopedToRun = options.isolated
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
