import Darwin
import Foundation

/// Every user's listening sockets, root's and macOS's included
/// (docs/design/activity/analysis.md, 6.8, 3.4, D-25): `nettop -L 1 -n -x
/// -J state`, run once a read — nettop is entitled to the network
/// statistics a non-root app can't read itself, and isn't blinded by an ad
/// hoc-signed parent the way netstat is (3.5). One pid a socket, where
/// libproc names every holder: the user's own sockets stay libproc's.
///
/// - **`parse`** reads nettop's text, pure: a process row is `name.pid,,`
///   (the pid after the **last** dot: a name may hold dots and spaces), a
///   flow row `tcp4 127.0.0.1:8021<->*:*,Listen,` or `udp6 *.3722<->*.*,,`
///   — IPv4 puts the port after a `:`, IPv6 after a `.`. Anything else
///   fails the whole parse: the read is "unknown", never "nothing".
/// - **The blind check** (`check`): an entitled reader sees at least what
///   libproc sees, so its answer must hold every TCP listener of the
///   user's that libproc found then. One that doesn't was read blind and is
///   "unknown"; with none of the user's to compare it is "unchecked".
/// - **The read** (`Reader`) runs nettop as a short-lived child in a group
///   of its own (`KubeProcessRun`: 5 s, 1 MB, ended at quit), on a GCD
///   thread, never twice at once. In an isolated run or a unit test the
///   real nettop never runs — only a stand-in the test names (9.9).
package enum NettopListeners {
    /// One listening socket as nettop prints it.
    package struct Listener: Hashable, Sendable {
        /// The process's name as nettop prints it (`p_comm`'s, cut).
        package let name: String
        package let pid: pid_t
        /// "tcp" or "udp".
        package let proto: String
        package let family: SocketRecord.Families
        /// The local address; a wildcard of its family for `*`.
        package let address: ActivityAddress
        package let port: UInt16

        /// As the census's own records are: what the rows are made of.
        package var record: SocketRecord {
            SocketRecord(
                descriptor: -1, socket: 0, kind: proto == "udp" ? .udp : .tcp, families: family, localAddress: address, localPort: port,
                remoteAddress: nil, remotePort: 0, state: proto == "udp" ? nil : .listen, backlog: 0, backlogLimit: 0)
        }
    }

    /// The command line: one sample (`-L 1`), numbers not names (`-n`),
    /// exact counts (`-x`), only the state column (`-J state`).
    package static let executable = URL(fileURLWithPath: "/usr/bin/nettop")
    package static let arguments = ["-L", "1", "-n", "-x", "-J", "state"]

    // MARK: The text

    /// nettop's text as listeners: TCP in Listen and UDP bound to a port
    /// with no peer, each once; nil for text that isn't nettop's.
    package static func parse(_ text: String) -> [Listener]? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard let header = lines.first, header.trimmingCharacters(in: .whitespaces) == ",state," else { return nil }
        var found: [Listener] = []
        var seen = Set<Listener>()
        var process: (name: String, pid: pid_t)?
        for line in lines.dropFirst() {
            guard line.hasSuffix(",") else { return nil }
            if line.contains("<->") {
                guard let process else { return nil }
                guard let flow = flow(line.dropLast()) else { return nil }
                guard let listener = flow.listener(name: process.name, pid: process.pid) else { continue }
                if seen.insert(listener).inserted { found.append(listener) }
            } else {
                // `name.pid,,`: its pid after the last dot.
                guard line.hasSuffix(",,") else { return nil }
                let body = line.dropLast(2)
                guard let dot = body.lastIndex(of: "."), let pid = pid_t(body[body.index(after: dot)...]), pid > 0 else { return nil }
                let name = String(body[..<dot])
                guard !name.isEmpty else { return nil }
                process = (name, pid)
            }
        }
        return found
    }

    /// One flow row, its trailing comma taken off: `proto local<->remote,state`.
    private struct Flow {
        let proto: Substring
        let local: (address: ActivityAddress, port: UInt16)
        let remoteIsAny: Bool
        let state: Substring

        func listener(name: String, pid: pid_t) -> Listener? {
            let family: SocketRecord.Families = proto.hasSuffix("6") ? .v6 : .v4
            switch proto {
            case "tcp4", "tcp6":
                guard state == "Listen", local.port != 0 else { return nil }
                return Listener(name: name, pid: pid, proto: "tcp", family: family, address: local.address, port: local.port)
            case "udp4", "udp6":
                guard remoteIsAny, local.port != 0 else { return nil }
                return Listener(name: name, pid: pid, proto: "udp", family: family, address: local.address, port: local.port)
            default:
                return nil
            }
        }
    }

    /// Nil for a TCP or UDP row whose endpoints can't be read; another
    /// protocol's (QUIC's) is read as one with no listener.
    private static func flow(_ row: Substring) -> Flow? {
        guard let comma = row.lastIndex(of: ","), let space = row.firstIndex(of: " ") else { return nil }
        let state = row[row.index(after: comma)...]
        let proto = row[..<space]
        let endpoints = row[row.index(after: space)..<comma]
        guard let arrow = endpoints.range(of: "<->") else { return nil }
        guard ["tcp4", "tcp6", "udp4", "udp6"].contains(proto) else {
            return Flow(proto: proto, local: (.v4(0), 0), remoteIsAny: false, state: state)
        }
        let v6 = proto.hasSuffix("6")
        guard let local = endpoint(endpoints[..<arrow.lowerBound], v6: v6) else { return nil }
        let remote = endpoints[arrow.upperBound...]
        return Flow(proto: proto, local: local, remoteIsAny: remote == "*:*" || remote == "*.*", state: state)
    }

    /// `127.0.0.1:8021`, `*:53`, `::1.8021`, `*.5353`, `fe80::1%lo0.5353`:
    /// IPv4's port after its last `:`, IPv6's after its last `.`; `*` the
    /// family's wildcard, a zone (`%en0`) left out.
    package static func endpoint(_ text: Substring, v6: Bool) -> (address: ActivityAddress, port: UInt16)? {
        guard let separator = text.lastIndex(of: v6 ? "." : ":") else { return nil }
        let portText = text[text.index(after: separator)...]
        let port: UInt16
        if portText == "*" {
            port = 0
        } else {
            guard let number = UInt16(portText) else { return nil }
            port = number
        }
        var host = text[..<separator]
        if let zone = host.firstIndex(of: "%") { host = host[..<zone] }
        if host == "*" { return (v6 ? .v6(0, 0) : .v4(0), port) }
        guard let address = ActivityAddress(text: String(host)) else { return nil }
        return (address, port)
    }

    // MARK: The blind check

    /// A TCP listener of the user's that libproc found: its port and every
    /// holder's pid — nettop names one.
    package struct Expected: Hashable, Sendable {
        package let port: UInt16
        package let pids: Set<pid_t>
    }

    /// What a read's answer is worth.
    package enum Check: Hashable, Sendable {
        /// It holds every listener of the user's libproc found.
        case checked
        /// None of the user's to compare it with: believed, said so.
        case unchecked
        /// It lacks some of the user's: read blind, "unknown".
        case blind(missing: Int)
    }

    /// `listeners` against the user's own TCP listeners libproc found then.
    package static func check(_ listeners: [Listener], expected: Set<Expected>) -> Check {
        guard !expected.isEmpty else { return .unchecked }
        var byPort: [UInt16: Set<pid_t>] = [:]
        for listener in listeners where listener.proto == "tcp" { byPort[listener.port, default: []].insert(listener.pid) }
        let missing = expected.count { byPort[$0.port]?.isDisjoint(with: $0.pids) ?? true }
        return missing == 0 ? .checked : .blind(missing: missing)
    }

    /// The user's TCP listeners in `snapshot`, every holder's pid: what
    /// nettop's answer must hold. `among`: only these processes' — a test
    /// run's own (9.9: it lists nothing else, and its stand-in can't know
    /// the rest).
    package static func expected(in snapshot: ActivitySnapshot, among: Set<ActivityProcessID>? = nil) -> Set<Expected> {
        var byPort: [UInt16: Set<pid_t>] = [:]
        for process in snapshot.table.processes where process.isOwn(by: snapshot.uid) && (among?.contains(process.identity) ?? true) {
            guard let records = snapshot.facts[process.identity]?.sockets?.records else { continue }
            for record in records where record.isListening { byPort[record.localPort, default: []].insert(process.pid) }
        }
        return Set(byPort.map { Expected(port: $0.key, pids: $0.value) })
    }

    // MARK: A read

    /// One read and what it is worth.
    package struct Reading: Sendable {
        package enum Outcome: Hashable, Sendable {
            case read(Check)
            /// It didn't run, ran past its time, or printed what isn't
            /// nettop's: why.
            case failed(String)
        }

        package var listeners: [Listener] = []
        package var outcome: Outcome
        /// When it began.
        package var date: Date
        /// What libproc found as it began: what the answer is checked with,
        /// less what has closed by then (`checked(against:)`).
        package var expected: Set<Expected> = []

        /// Its listeners are shown: read, and not blind.
        package var isBelieved: Bool {
            switch outcome {
            case .read(.checked), .read(.unchecked): true
            default: false
            }
        }

        /// The check made again against what libproc still finds: a
        /// listener that closed while nettop ran is no proof of blindness.
        package func checked(against now: Set<Expected>) -> Reading {
            guard case .read = outcome else { return self }
            let nowByPort = Dictionary(now.map { ($0.port, $0.pids) }, uniquingKeysWith: { $0.union($1) })
            let still = Set(
                expected.compactMap { wanted -> Expected? in
                    guard let pids = nowByPort[wanted.port] else { return nil }
                    let kept = wanted.pids.intersection(pids)
                    return kept.isEmpty ? nil : Expected(port: wanted.port, pids: kept)
                })
            var copy = self
            copy.outcome = .read(NettopListeners.check(listeners, expected: still))
            return copy
        }
    }

    /// `text` as a reading begun at `date`, against `expected`.
    package static func reading(_ text: String?, status: Int32, date: Date, expected: Set<Expected>) -> Reading {
        guard let text else { return Reading(outcome: .failed("nettop didn't answer in 5 s"), date: date, expected: expected) }
        guard status == 0 else { return Reading(outcome: .failed("nettop failed (exit \(status))"), date: date, expected: expected) }
        guard let listeners = parse(text) else { return Reading(outcome: .failed("nettop's answer couldn't be read"), date: date, expected: expected) }
        return Reading(listeners: listeners, outcome: .read(check(listeners, expected: expected)), date: date, expected: expected)
    }

    /// Runs nettop, or the stand-in a test names, one read at a time.
    package final class Reader: @unchecked Sendable {
        /// The app's.
        package static let shared = Reader()

        private let lock = NSLock()
        // Under `lock`.
        private var running = false
        private var standInURL: URL?
        private var last: Reading?
        private var waiters: [@Sendable (Reading) -> Void] = []

        /// A test's nettop: the only one an isolated run or a unit test
        /// runs (9.9). Nil there: nothing is read.
        package var standIn: URL? {
            get { lock.withLock { standInURL } }
            set { lock.withLock { standInURL = newValue } }
        }

        /// The last read, whoever asked.
        package var latest: Reading? { lock.withLock { last } }

        package var isReading: Bool { lock.withLock { running } }

        /// Why nothing can be read here; nil when it can.
        package var unavailable: String? {
            let guarded = AppEnvironment.isIsolated || AppEnvironment.isUnitTest
            if guarded, standIn == nil { return "not read in a test run" }
            return nil
        }

        /// One read on a GCD thread, `done` called there; false — nothing
        /// started — while one is running or nothing can be read.
        @discardableResult
        package func read(expected: Set<Expected>, done: @escaping @Sendable (Reading) -> Void) -> Bool {
            let guarded = AppEnvironment.isIsolated || AppEnvironment.isUnitTest
            let started: URL? = lock.withLock {
                guard !running else { return nil }
                if guarded, standInURL == nil { return nil }
                running = true
                return standInURL ?? NettopListeners.executable
            }
            guard let executable = started else { return false }
            let block: @Sendable () -> Void = { [self] in
                let reading = Self.run(executable, expected: expected)
                let waiting = lock.withLock {
                    running = false
                    last = reading
                    defer { waiters = [] }
                    return waiters
                }
                done(reading)
                for waiter in waiting { waiter(reading) }
            }
            DispatchQueue.global(qos: .userInitiated).async(execute: block)
            return true
        }

        /// `done` called with the read now running, as it lands; false —
        /// nothing waited for — when none is running.
        package func whenRead(_ done: @escaping @Sendable (Reading) -> Void) -> Bool {
            lock.withLock {
                guard running else { return false }
                waiters.append(done)
                return true
            }
        }

        /// One read, here, waited for: `executable` with nettop's
        /// arguments, nothing of the app's environment.
        package static func run(_ executable: URL, expected: Set<Expected>) -> Reading {
            let date = Date()
            let result = KubeProcessRun.run(
                executable, NettopListeners.arguments, environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"], timeout: 5, outputLimit: 1 << 20,
                helper: .nettop)
            guard let result else { return NettopListeners.reading(nil, status: 0, date: date, expected: expected) }
            guard !result.truncated else { return Reading(outcome: .failed("nettop's answer was over 1 MB"), date: date, expected: expected) }
            return NettopListeners.reading(result.stdout, status: result.status, date: date, expected: expected)
        }
    }
}
