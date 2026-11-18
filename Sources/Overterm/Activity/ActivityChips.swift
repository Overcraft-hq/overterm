import Foundation

/// What changed, on the row it concerns (docs/design/activity/analysis.md,
/// 6.11's evidence chips — there is no Changes log): a level that lasted, a
/// server not where it asked to be.
enum ActivityRowChip: Hashable, Sendable {
    /// One of the user's processes held a core — 90% or more in every
    /// sample — for `ActivityChips.lasting`, since then.
    case heldCore(since: Date)
    /// An agent's tab waits for the person while its subtree burns 50% or
    /// more, since the later of the two; `cpu` its last.
    case idleBurning(cpu: Double, since: Date)
    /// A server asked for `asked` and listens on `got` (probably moved:
    /// the port was taken); `holder`, who holds `asked`, when it is known.
    case moved(asked: Int, got: Int, holder: String?)

    /// What the chip says at `now`: "held a core for 5 min, since 14:02".
    func text(now: Date) -> String {
        switch self {
        case .heldCore(let since):
            return "held a core for \(ActivityChips.minutes(now.timeIntervalSince(since))), since \(ActivityRows.clock(since))"
        case .idleBurning(let cpu, let since):
            return "⚠ idle at \(Int(cpu.rounded()))% for \(ActivityChips.minutes(now.timeIntervalSince(since)))"
        case .moved(let asked, let got, _):
            return "asked \(asked), got \(got)"
        }
    }

    /// Its tooltip: why it says so.
    var help: String {
        switch self {
        case .heldCore: return "Every sample at 90% or more of a core for 5 minutes or longer"
        case .idleBurning:
            return "Its tab waits for you, yet the agent and what runs under it have used 50% or more of a core for 5 minutes or longer"
        case .moved(let asked, let got, let holder):
            let who = holder.map { " — :\(asked) is \($0)'s" } ?? ""
            return "Probably moved: it asked for :\(asked) and listens on :\(got)\(who)"
        }
    }

    /// Drawn as a warning.
    var warns: Bool {
        switch self {
        case .idleBurning, .heldCore: true
        case .moved: false
        }
    }
}

/// The chips of the rows of one census (6.11). Pure.
enum ActivityChips {
    /// How long a level must last before it is an event (glances' rule): 5 min.
    static let lasting: TimeInterval = 300
    /// A core held: every sample at this or more.
    static let core = 90.0
    /// An idle agent burning: its subtree at this or more.
    static let burning = 50.0

    /// Whether `key` has stayed at `threshold` for `lasting`: since when.
    static func lasted(_ key: ActivityRingKey, atLeast threshold: Double, in snapshot: ActivitySnapshot) -> Date? {
        guard let since = sustained(key, atLeast: threshold, in: snapshot), snapshot.date.timeIntervalSince(since) >= lasting else { return nil }
        return since
    }

    /// Since when `key` has stayed at `threshold`, however briefly.
    static func sustained(_ key: ActivityRingKey, atLeast threshold: Double, in snapshot: ActivitySnapshot) -> Date? {
        guard let start = snapshot.history.sustained(key, atLeast: threshold, now: snapshot.historyNow), snapshot.historyNow >= start else { return nil }
        return snapshot.date(of: start)
    }

    /// One of the user's processes' chips: an agent's tab waiting while its
    /// subtree burns, else a core held. `agentWaitingSince`: when its tab
    /// began to wait for the person, nil while it doesn't — the burn
    /// counts only from then: an agent that worked hard and asked its
    /// question a moment ago isn't idle (6.11).
    static func of(_ identity: ActivityProcessID, agentWaitingSince: Date?, isAgent: Bool, in snapshot: ActivitySnapshot) -> [ActivityRowChip] {
        if isAgent, let waiting = agentWaitingSince, let burning = sustained(.agent(identity), atLeast: burning, in: snapshot) {
            // Both at once: from the later of the two, for `lasting`.
            let since = max(waiting, burning)
            if snapshot.date.timeIntervalSince(since) >= lasting {
                return [.idleBurning(cpu: snapshot.history.lastCPU(.agent(identity)) ?? Self.burning, since: since)]
            }
        }
        if let since = lasted(.process(identity), atLeast: core, in: snapshot) { return [.heldCore(since: since)] }
        return []
    }

    /// "12 min", "1 h 5 min".
    static func minutes(_ seconds: TimeInterval) -> String {
        let minutes = max(Int(seconds / 60), 0)
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}

/// A server that is not where it asked to be (6.8's moved server,
/// *probably*). Pure.
enum ActivityMovedServers {
    /// How far a server moves looking for a free port: P+1…P+10.
    static let reach = 10
    /// Programs whose `-p` names a port they reach, not one they serve.
    static let clients: Set<String> = ["ssh", "scp", "sftp", "mosh", "psql", "mysql", "redis-cli", "nc", "telnet", "kubectl"]

    /// The port a masked command line asks for: `--port 3000`,
    /// `--port=3000`, `-p 3000`, `-p3000` (`next dev -p`, vite, serve,
    /// http-server). Nil when it asks for none.
    static func asked(_ command: String?) -> Int? {
        guard let command else { return nil }
        let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // A client's -p is the port it connects to.
        if let first = words.first, clients.contains((first as NSString).lastPathComponent) { return nil }
        for (index, word) in words.enumerated() {
            var value: String?
            if word == "--port" || word == "-p" || word == "--listen-port" {
                value = index + 1 < words.count ? words[index + 1] : nil
            } else if word.hasPrefix("--port=") {
                value = String(word.dropFirst("--port=".count))
            } else if word.hasPrefix("-p"), word.count > 2, word.dropFirst(2).allSatisfy(\.isNumber) {
                value = String(word.dropFirst(2))
            }
            if let value, let port = Int(value), (1...65_535).contains(port) { return port }
        }
        return nil
    }

    /// The note a moved server's port carries (6.8, 8.5): "moved: :3000 is
    /// web's (probably)" — on Listening's row and in `proc_mine`'s servers.
    /// Nil for a port no moved chip names. Pure.
    static func note(_ chips: [ActivityRowChip], port: Int) -> String? {
        for chip in chips {
            guard case .moved(let asked, let got, let holder) = chip, got == port else { continue }
            return holder.map { "moved: :\(asked) is \($0)'s (probably)" } ?? "moved: it asked for :\(asked) (probably)"
        }
        return nil
    }

    /// What a server is, to tell two checkouts' copies of it apart from
    /// other servers: its label or name.
    static func kind(_ row: ActivityProcessRow) -> String { (row.label ?? row.name).lowercased() }

    /// Each moved server's chip, by row id: one that asked for a port and
    /// listens a little above it; or, of two checkouts of one repository
    /// running the same server, the later one on P+1…P+10 of the other's P.
    static func find(_ rows: [ActivityProcessRow], tabs: [UUID: ActivityTabFacts]) -> [String: ActivityRowChip] {
        var found: [String: ActivityRowChip] = [:]
        let servers = rows.filter { $0.isOwn && !$0.listening.isEmpty }
        var byPort: [Int: ActivityProcessRow] = [:]
        for row in servers {
            for port in row.listening where byPort[port] == nil { byPort[port] = row }
        }
        func holder(_ port: Int, besides row: ActivityProcessRow) -> String? {
            guard let other = byPort[port], other.identity != row.identity else { return nil }
            return other.checkout ?? other.name
        }
        for row in servers {
            guard let asked = asked(row.command), !row.listening.contains(asked) else { continue }
            if let got = row.listening.first(where: { $0 > asked && $0 <= asked + reach }) {
                found[row.id] = .moved(asked: asked, got: got, holder: holder(asked, besides: row))
            }
        }
        // Two checkouts of one repository: the same server, the later one a
        // little above the other.
        for row in servers where found[row.id] == nil {
            guard let tab = row.tab, let repository = tabs[tab]?.repository, let checkout = tabs[tab]?.checkout else { continue }
            for other in servers where other.identity != row.identity && other.started < row.started && kind(other) == kind(row) {
                guard let otherTab = other.tab, tabs[otherTab]?.repository == repository, tabs[otherTab]?.checkout != checkout else { continue }
                for port in other.listening {
                    if let got = row.listening.first(where: { $0 > port && $0 <= port + reach }) {
                        found[row.id] = .moved(asked: port, got: got, holder: other.checkout ?? other.name)
                        break
                    }
                }
                if found[row.id] != nil { break }
            }
        }
        return found
    }
}
