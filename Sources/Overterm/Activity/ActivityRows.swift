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

    var height: CGFloat { 24 }

    /// What VoiceOver says of it (6.4): name, pid, CPU, where.
    var accessibilityLabel: String {
        var words = ["\(name), pid \(identity.pid)"]
        if let cpu { words.append("\(ActivityRows.percent(cpu)) percent CPU") }
        if let tabTitle { words.append("in “\(tabTitle)”") } else if !isOwn { words.append(user) }
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
    var processes: [ActivityProcessRow] = []
    var ports: [ActivityPortRow] = []
    var summary = ActivitySummary()
}

enum ActivityRows {
    /// What the page lists of `snapshot`.
    struct Options: Sendable {
        /// Tabs' titles, by id, every window's.
        var titles: [UUID: String] = [:]
        /// Other users' processes too (`activity.everyone`).
        var everyone = true
        /// A test run (`AppEnvironment.isIsolated`): only the run's own
        /// tabs' processes are rows, the rest counted (6.4, 9.9).
        var isolated = false
        var processSort: ResourceSort? = ResourceSort(column: "cpu", ascending: false)
        var portSort: ResourceSort? = ResourceSort(column: "port")
    }

    static func content(of snapshot: ActivitySnapshot, _ options: Options) -> ActivityPageContent {
        // A tab's title is often the command running in it: masked as every
        // command is, wherever it leaves the strip (9.3).
        let titles = options.titles.mapValues(ActivityText.title)
        let today = Calendar.current.startOfDay(for: snapshot.date)
        // Where each process runs: the first pane that places it.
        var tabs: [ActivityProcessID: UUID] = [:]
        for slice in snapshot.panes {
            for identity in slice.placed where tabs[identity] == nil { tabs[identity] = slice.tab }
        }
        let uid = snapshot.uid
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
            let tab = tabs[identity]
            let started = Date(timeIntervalSince1970: Double(identity.start) / 1_000_000)
            rows.append(
                ActivityProcessRow(
                    id: identity.id, identity: identity, name: snapshot.name(of: identity) ?? process.shortName, cpu: facts?.rates?.cpuPercent,
                    memory: facts?.usage?.footprint, threads: facts?.usage?.threads,
                    state: ActivityState(status: process.status, runningThreads: own ? facts?.usage?.runningThreads : nil),
                    started: started, startedText: startedText(started, today: today),
                    user: own ? userName(uid) : userName(process.effectiveUID), isOwn: own, tab: tab, tabTitle: tab.flatMap { titles[$0] }))
        }
        var content = ActivityPageContent()
        content.processes = sorted(rows, by: options.processSort)
        content.ports = sorted(ports(of: rows, in: snapshot, tabs: tabs, titles: titles), by: options.portSort)
        var summary = ActivitySummary()
        summary.processes = snapshot.table.processes.count
        summary.own = snapshot.table.processes.lazy.filter { $0.isOwn(by: uid) }.count
        summary.shown = rows.count
        summary.listening = content.ports.count
        summary.threads = threads
        summary.busiest = Array(
            rows.compactMap { row in row.cpu.map { ActivitySummary.Busy(id: row.id, name: row.name, cpu: $0) } }.sorted { $0.cpu > $1.cpu }.prefix(5))
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
    static func ports(of rows: [ActivityProcessRow], in snapshot: ActivitySnapshot, tabs: [ActivityProcessID: UUID], titles: [UUID: String])
        -> [ActivityPortRow]
    {
        let ports = ListeningPorts.of(rows.filter(\.isOwn).map(\.identity), in: snapshot, udp: true)
        return ports.map { port in
            let tab = port.identity.flatMap { tabs[$0] }
            return ActivityPortRow(
                id: port.id, port: port.port, proto: port.proto, address: port.address, families: port.families, scope: port.scope, process: port.process,
                holder: port.identity, tab: tab, tabTitle: tab.flatMap { titles[$0] }, url: port.url)
        }
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
