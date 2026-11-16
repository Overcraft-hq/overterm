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

/// A listening socket's row (6.8): one process's sockets on one protocol
/// and port, its v4 and v6 together (`ListeningPorts.of`).
struct ActivityPortRow: ResourceTableRow, Sendable {
    let id: String
    let port: Int
    let proto: String
    /// The bound address as lsof prints it (`*`, `127.0.0.1`, `[::1]`).
    let address: String
    let families: SocketRecord.Families
    let scope: ListeningPort.Scope
    let process: String
    let holder: ActivityProcessID?
    let tab: UUID?
    let tabTitle: String?
    /// Where a browser reaches it; nil when there is none to open.
    let url: URL?
    /// Who holds it, in the filter's `owner:` words (6.6): `tab`,
    /// `forward`, `overterm`, `container`, `app`, `macos`, `system`, or
    /// `elsewhere`.
    var owner = "elsewhere"

    var height: CGFloat { 24 }

    /// "This Mac" or "Network" (6.1), or the one address it is bound to.
    var reach: String {
        switch scope {
        case .thisMac: "This Mac"
        case .network: "Network"
        case .oneAddress: address
        }
    }

    var familyWords: String {
        switch (families.contains(.v4), families.contains(.v6)) {
        case (true, true): "v4, v6"
        case (true, false): "v4"
        case (false, true): "v6"
        default: ""
        }
    }

    var accessibilityLabel: String {
        var words = [":\(port) \(proto)", process]
        if let holder { words.append("pid \(holder.pid)") }
        words.append(reach)
        if let tabTitle { words.append("in “\(tabTitle)”") }
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
    /// Every process row in scope before the filter: where the detail's
    /// tree stops (9.9 — a test run's own tabs' processes alone).
    var identities: Set<ActivityProcessID> = []
    var summary = ActivitySummary()
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
        /// What each section's filter field says (6.6).
        var processFilter = ""
        var portFilter = ""
    }

    static func content(of snapshot: ActivitySnapshot, _ options: Options) -> ActivityPageContent {
        // A tab's title is often the command running in it: masked as every
        // command is, wherever it leaves the strip (9.3).
        var tabFacts = options.tabs
        for (id, title) in options.titles where tabFacts[id] == nil { tabFacts[id] = ActivityTabFacts(id: id, title: title) }
        for (id, tab) in tabFacts { tabFacts[id]?.title = ActivityText.title(tab.title) }
        let titles = tabFacts.mapValues(\.title)
        // The owners only where something reads them: the switcher's flat
        // rows over the whole Mac are ranked by CPU and port alone.
        let attribution =
            options.grouping == nil && options.scope == .mac
            ? nil
            : ActivityAttribution.of(
                snapshot, context: options.context,
                inputs: ActivityAttribution.Inputs(
                    tabs: tabFacts, checkouts: options.checkouts + tabFacts.values.compactMap(\.checkout), runningApps: options.runningApps))
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
            if options.isolated, tabs[identity] == nil { continue }
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
        var ports = ports(of: inScope, in: snapshot, tabs: tabs, titles: titles, context: options.context)
        content.listeners = ports
        content.identities = Set(inScope.map(\.identity))
        let portFilter = ActivityFilter(options.portFilter)
        if !portFilter.isEmpty { ports = ports.filter { portFilter.matches($0) } }
        content.ports = sorted(ports, by: options.portSort)
        var summary = ActivitySummary()
        summary.processes = snapshot.table.processes.count
        summary.own = snapshot.table.processes.lazy.filter { $0.isOwn(by: uid) }.count
        summary.shown = rows.count
        summary.matched = matched
        summary.listening = content.ports.count
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

    /// The listening sockets of the rows' processes: TCP listeners and
    /// bound UDP, as the census's socket walk read them — the user's only;
    /// another user's sockets aren't readable.
    static func ports(
        of rows: [ActivityProcessRow], in snapshot: ActivitySnapshot, tabs: [ActivityProcessID: UUID], titles: [UUID: String],
        context: ActivityContext = ActivityContext()
    ) -> [ActivityPortRow] {
        let ports = ListeningPorts.of(rows.filter(\.isOwn).map(\.identity), in: snapshot, udp: true)
        let owners = Dictionary(rows.map { ($0.identity, $0.owner) }, uniquingKeysWith: { first, _ in first })
        let forwards = Set(context.forwards.map(\.pid).filter { $0 > 0 })
        return ports.map { port in
            let tab = port.identity.flatMap { tabs[$0] }
            var row = ActivityPortRow(
                id: port.id, port: port.port, proto: port.proto, address: port.address, families: port.families, scope: port.scope, process: port.process,
                holder: port.identity, tab: tab, tabTitle: tab.flatMap { titles[$0] }, url: port.url)
            row.owner = ownerWord(port.identity.flatMap { owners[$0] ?? nil }, forward: port.identity.map { forwards.contains($0.pid) } ?? false)
            return row
        }
    }

    /// The filter's `owner:` word for a listener's holder (6.6).
    static func ownerWord(_ owner: ActivityOwner?, forward: Bool) -> String {
        if forward { return "forward" }
        switch owner?.place {
        case .pane?: return "tab"
        case .overterm?, .anotherOverterm?: return "overterm"
        case .engine?: return "container"
        case .app?: return "app"
        case .macOS?: return "macos"
        case .system?: return "system"
        case .elsewhere?, nil: return "elsewhere"
        }
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
        case "where": return sort.sorted(rows) { $0.tabTitle?.lowercased() }
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
