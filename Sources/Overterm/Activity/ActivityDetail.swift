import Foundation

/// The detail of the selected process (docs/design/activity/analysis.md,
/// 6.4), without history (stage 4 brings it): its header, the masked
/// command — there is no unmasked view (9.3, D-27) —, where it is and why,
/// its tree, its listeners and connections counted, its usage. Made from
/// the page's row and the snapshot it came from; pure.
struct ActivityDetail: Equatable, Sendable {
    struct Relative: Equatable, Sendable {
        let id: String
        let pid: pid_t
        let name: String
    }

    let row: ActivityProcessRow
    /// Up to the first that isn't one of the page's rows, or launchd:
    /// nearest first. A test run's rows are its own tabs' alone (9.9), so
    /// its tree stops at the pane's login, never the processes that
    /// launched the run.
    var ancestors: [Relative] = []
    /// Its children among the rows, oldest first, at most `childLimit`,
    /// then counted.
    var children: [Relative] = []
    var moreChildren = 0
    var listeners: [ActivityPortRow] = []
    /// Established TCP connections, counted: whom they reach stays out of
    /// the page (9.4).
    var connections = 0
    var descriptors: Int?
    /// More sockets than a tick reads: its listeners read in rotation.
    var bounded = false
    var rates: ActivityRates?
    var interruptWakeups: UInt64?

    static let ancestorLimit = 12
    static let childLimit = 50

    /// The detail of `row`, read in `snapshot`; `rows` the page's process
    /// rows in scope — its tree goes no further —, `ports` its listeners'
    /// rows.
    static func make(_ row: ActivityProcessRow, in snapshot: ActivitySnapshot, rows: Set<ActivityProcessID>, ports: [ActivityPortRow]) -> ActivityDetail {
        var detail = ActivityDetail(row: row)
        let table = snapshot.table
        var current = row.identity
        for _ in 0..<ancestorLimit {
            guard let parent = table.parent(of: current), rows.contains(parent.identity) else { break }
            detail.ancestors.append(Relative(id: parent.identity.id, pid: parent.pid, name: snapshot.name(of: parent.identity) ?? parent.shortName))
            if parent.pid <= 1 { break }
            current = parent.identity
        }
        let children = table.children(of: row.identity).filter { rows.contains($0.identity) }.sorted { $0.identity < $1.identity }
        detail.children = children.prefix(childLimit).map { Relative(id: $0.identity.id, pid: $0.pid, name: snapshot.name(of: $0.identity) ?? $0.shortName) }
        detail.moreChildren = max(children.count - childLimit, 0)
        detail.listeners = ports.filter { $0.holder == row.identity }
        let facts = snapshot.facts[row.identity]
        if let sockets = facts?.sockets {
            detail.connections = sockets.records.filter { $0.kind == .tcp && $0.state == .established }.count
            detail.descriptors = sockets.descriptors
            detail.bounded = sockets.bound != nil
        }
        detail.rates = facts?.rates
        detail.interruptWakeups = facts?.usage?.interruptWakeups
        return detail
    }

    /// The header's line: user, state, started.
    var subtitle: String {
        var words = ["pid \(row.identity.pid)", row.user]
        switch row.state {
        case .running: words.append("running")
        case .sleeping: words.append("sleeping")
        case .stopped: words.append("stopped")
        case .zombie: words.append("ended; its parent (pid \(row.parentPID)) hasn't collected it")
        case .unknown: break
        }
        words.append("started \(row.startedText)")
        return words.joined(separator: " · ")
    }

    /// The Usage block's lines, label and value; "—" for what isn't read
    /// (another user's, a first sample).
    var usage: [(String, String)] {
        let dash = "—"
        var lines: [(String, String)] = [
            ("CPU", row.cpu.map { "\(ActivityRows.percent($0))%" } ?? dash),
            ("Memory", row.memory.map(ActivityRows.bytes) ?? dash),
            ("Real memory", row.residentSize.map(ActivityRows.bytes) ?? dash),
            ("Threads", row.threads.map { "\($0)" } ?? dash),
            ("CPU time", row.cpuTime.map(ActivityDetail.duration) ?? dash),
        ]
        if let rates {
            if let energy = rates.energy { lines.append(("Energy", String(format: "%.2f W, estimate", locale: Locale(identifier: "en_US_POSIX"), energy))) }
            lines.append(("Idle wake-ups", String(format: "%.0f a second", locale: Locale(identifier: "en_US_POSIX"), rates.idleWakeupsPerSecond)))
            lines.append(
                ("Disk", "\(ActivityRows.bytes(UInt64(max(rates.diskReadPerSecond, 0))))/s read, \(ActivityRows.bytes(UInt64(max(rates.diskWrittenPerSecond, 0))))/s written"))
        }
        lines.append(("Nice", "\(row.nice)"))
        if let priority = row.priority { lines.append(("Priority", "\(priority)")) }
        if let terminal = row.terminal { lines.append(("Terminal", terminal)) }
        if row.translated { lines.append(("Kind", "Intel, under Rosetta")) }
        return lines
    }

    /// CPU time as `top` writes it: `1:02:03`, `2:03.45`.
    static func duration(_ nanoseconds: UInt64) -> String {
        let hundredths = nanoseconds / 10_000_000
        let seconds = hundredths / 100
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        if hours > 0 { return String(format: "%llu:%02llu:%02llu", hours, minutes, seconds % 60) }
        return String(format: "%llu:%02llu.%02llu", minutes, seconds % 60, hundredths % 100)
    }
}
