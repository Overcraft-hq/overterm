import Foundation

/// A port a tab's process is listening on — typically a dev server —
/// or one a container of the tab's checkout publishes (Docker's own
/// process holds those, so the socket walk never finds them under the tab).
struct ListeningPort: Identifiable, Hashable {
    let pid: pid_t
    /// When `pid`'s process started (µs), read with the listing
    /// (`ListeningPorts.of`): with the pid, which process held the port —
    /// a pid is reused, the pair never. A pill's Stop… signals only that
    /// process (`PortStop`), and nothing when this couldn't be read. A
    /// container's and a forward's have none: their owners stop them.
    var start: UInt64? = nil
    let process: String
    let port: Int
    /// The bound address as lsof prints it (`*`, `127.0.0.1`, `[::1]`): of
    /// a process's sockets on the port, the widest — a wildcard, else one
    /// address that isn't loopback, else loopback.
    let address: String
    /// The container publishing it; its service is `process`, `pid` is 0.
    var container: String? = nil
    /// The port the compose file asks for, when Up on Free Ports moved it
    /// here for this checkout (`ComposePorts`).
    var movedFrom: Int? = nil
    /// A Kubernetes port-forward's (`KubeForwards`): kubectl is Overterm's
    /// child, not the tab's, so the socket walk never finds it under the
    /// tab. Its pid is kubectl's while it forwards, 0 while it restarts.
    var forward: KubeForwardPill? = nil
    /// "tcp" or "udp".
    var proto = "tcp"
    /// The families its sockets serve (`insi_vflag`, docs/design/activity/
    /// analysis.md 6.8): a dual-stack socket both. None known for a
    /// container's or a forward's.
    var families: SocketRecord.Families = []
    /// Who can reach it (6.8).
    var scope = Scope.thisMac
    /// When the process holding it started, µs since 1970: with `pid`, the
    /// identity a pill's verb checks before it acts (6.12). Nil for a
    /// container's or a forward's, whose owners act for them.
    var start: UInt64? = nil
    /// Where a browser reaches it (6.8): its URL's host, from its sockets'
    /// bound addresses and families — `localhost` only where both families
    /// listen on loopback, since a client may try ::1 first and give up.
    /// Nil when there is none to open: a link-local address needs a zone
    /// id, so it is copied only.
    var host: String? = "localhost"

    /// Who can reach a listener (6.8, Scope).
    enum Scope: Hashable, Sendable {
        /// Loopback only: 127/8, ::1, a v4-mapped `::ffff:127.0.0.1`.
        case thisMac
        /// A wildcard (`*`, 0.0.0.0, ::): anything that can route to this
        /// Mac — over IPv6 that may be the internet.
        case network
        /// One address of this Mac that isn't loopback: a LAN, utun or
        /// Tailscale one, an IPv6 ULA or global one.
        case oneAddress
    }

    /// Its holder as the census names it, pid and start; nil for a
    /// container's or a forward's.
    var identity: ActivityProcessID? {
        guard pid > 0, let start else { return nil }
        return ActivityProcessID(pid: pid, start: start)
    }

    var id: String {
        if let forward { return "forward:\(forward.id)" }
        if let container { return "\(container):\(port)" }
        return "\(pid):\(start ?? 0):\(proto):\(port)"
    }

    /// Where it is opened: where it listens (a forward's, https when it says so).
    var url: URL? {
        if let forward { return URL(string: "\(forward.https ? "https" : "http")://\(KubeForwardAddress.host(for: address)):\(port)") }
        guard let host else { return nil }
        return URL(string: "http://\(host):\(port)")
    }

    /// What a pill and the browser's empty page say for it: its URL's
    /// host and the port, else its bound address and the port.
    var endpoint: String {
        if forward != nil { return "\(KubeForwardAddress.host(for: address)):\(port)" }
        return "\(host ?? address):\(port)"
    }

    /// Its scope as 6.8's Scope column says it.
    var reach: String {
        switch scope {
        case .thisMac: "This Mac"
        case .network: "Network"
        case .oneAddress: "Network · \(address)"
        }
    }
}

enum ListeningPorts {
    static let lsof = URL(fileURLWithPath: "/usr/sbin/lsof")

    /// Whoever of the user's listens on `port` — a TCP listener, or a bound
    /// UDP socket for `udp` — as a one-off census reads it
    /// (docs/design/activity/analysis.md, 7.6: `ActivityMonitor.census`, at
    /// most one every 2 s, a younger one answering), no lsof. It sees what
    /// lsof saw: every process of the user's, and nobody else's — root's
    /// and other users' listeners come from nettop (stage 4). Nil when
    /// nothing of the user's holds it, or the table can't be read.
    static func holder(of port: Int, proto: String = "tcp") async -> ListeningPort? {
        guard let snapshot = await ActivityMonitor.shared.census() else { return nil }
        return holder(of: port, proto: proto, in: snapshot)
    }

    /// Of what `snapshot` read, the oldest process holding `port` — every
    /// socket it holds there as one entry, as `of` makes them. Pure.
    static func holder(of port: Int, proto: String = "tcp", in snapshot: ActivitySnapshot) -> ListeningPort? {
        let udp = proto == "udp"
        for identity in snapshot.facts.keys.sorted() {
            guard let facts = snapshot.facts[identity], let sockets = facts.sockets else { continue }
            let held = sockets.records.filter { Int($0.localPort) == port && (udp ? $0.isBoundUDP : $0.isListening) }
            if !held.isEmpty { return self.port(held, holder: identity, name: facts.name) }
        }
        return nil
    }

    /// Whether something on this Mac holds `port` — what Docker's own bind
    /// for a published port would run into. A bind with SO_REUSEADDR on
    /// 0.0.0.0, 127.0.0.1, :: and ::1, each closed at once: a listener on
    /// one address is only met binding that one, TIME_WAIT doesn't count,
    /// and nothing listens, so no firewall asks. Any user's socket counts,
    /// unlike lsof's. A family this Mac can't make counts as free.
    static func isBound(_ port: Int, proto: String = "tcp") -> Bool {
        guard (1...65535).contains(port) else { return false }
        let type = proto == "udp" ? SOCK_DGRAM : SOCK_STREAM
        for (family, address) in [(AF_INET, "0.0.0.0"), (AF_INET, "127.0.0.1"), (AF_INET6, "::"), (AF_INET6, "::1")] {
            let fd = socket(family, type, 0)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var on: Int32 = 1
            let size = socklen_t(MemoryLayout<Int32>.size)
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, size)
            let result: Int32
            if family == AF_INET {
                var socketAddress = sockaddr_in()
                socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                socketAddress.sin_family = sa_family_t(AF_INET)
                socketAddress.sin_port = in_port_t(UInt16(port)).bigEndian
                inet_pton(AF_INET, address, &socketAddress.sin_addr)
                result = withUnsafePointer(to: &socketAddress) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            } else {
                setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, size)
                var socketAddress = sockaddr_in6()
                socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                socketAddress.sin6_family = sa_family_t(AF_INET6)
                socketAddress.sin6_port = in_port_t(UInt16(port)).bigEndian
                inet_pton(AF_INET6, address, &socketAddress.sin6_addr)
                result = withUnsafePointer(to: &socketAddress) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
                }
            }
            if result != 0, errno == EADDRINUSE { return true }
        }
        return false
    }

    /// The listening TCP sockets of `members` — and their bound UDP ones,
    /// with `udp` — as the census's socket walk read them for `snapshot`
    /// (docs/design/activity/analysis.md, 7.6): a filter over the scan, no
    /// lsof. A process's sockets on one protocol and port are one entry,
    /// its v4 and v6 together: their families, the widest scope, the URL
    /// their bound addresses give (6.8), the holder's start.
    static func of(_ members: [ActivityProcessID], in snapshot: ActivitySnapshot, udp: Bool = false) -> [ListeningPort] {
        var result: [ListeningPort] = []
        var seen = Set<String>()
        for identity in members {
            guard let facts = snapshot.facts[identity], let sockets = facts.sockets else { continue }
            var order: [String] = []
            var byPort: [String: [SocketRecord]] = [:]
            for record in sockets.records where record.isListening || (udp && record.isBoundUDP) {
                let key = "\(record.kind == .udp ? "udp" : "tcp"):\(record.localPort)"
                if byPort[key] == nil { order.append(key) }
                byPort[key, default: []].append(record)
            }
            for key in order where seen.insert("\(identity.id):\(key)").inserted {
                guard let records = byPort[key], let port = port(records, holder: identity, name: facts.name) else { continue }
                result.append(port)
            }
        }
        return result.sorted { ($0.port, $0.pid, $0.proto) < ($1.port, $1.pid, $1.proto) }
    }

    /// One process's sockets on one protocol and port as one entry.
    static func port(_ records: [SocketRecord], holder: ActivityProcessID, name: String) -> ListeningPort? {
        guard let first = records.first else { return nil }
        let bound = records.map { (address: $0.localAddress, families: $0.families) }
        let widest =
            records.first { $0.localAddress?.isWildcard == true }
            ?? records.first { $0.localAddress.map { !$0.isLoopback } ?? false } ?? first
        return ListeningPort(
            pid: holder.pid, process: name, port: Int(first.localPort), address: address(of: widest), proto: first.kind == .udp ? "udp" : "tcp",
            families: records.reduce([]) { $0.union($1.families) }, scope: scope(of: bound), start: holder.start, host: host(of: bound))
    }

    /// A socket's bound address as lsof prints it.
    static func address(of record: SocketRecord) -> String {
        guard let local = record.localAddress, !local.isWildcard else { return "*" }
        if case .v6 = local { return "[\(local.description)]" }
        return local.description
    }

    /// Where a browser reaches a listener bound to `bound` — each of its
    /// sockets' local address and families (6.8's table): `localhost`
    /// where both families listen on loopback, through a dual-stack
    /// wildcard or one socket each; `127.0.0.1` where only IPv4 does — a
    /// client may try ::1 first and give up (Node 17–19's fetch) —, and
    /// `[::1]` where only IPv6 does; else the one address it is bound to,
    /// none for a link-local one, which needs a zone id. Another address
    /// of 127/8 (a loopback alias, `ifconfig lo0 alias 127.0.0.2`) is one
    /// address too: 127.0.0.1 doesn't reach it, and may reach another
    /// checkout's server on the same port. Pure.
    static func host(of bound: [(address: ActivityAddress?, families: SocketRecord.Families)]) -> String? {
        var loopbackV4 = false
        var loopbackV6 = false
        var specific: ActivityAddress?
        for socket in bound {
            guard let address = socket.address else { continue }
            switch address {
            case .v4 where address.isWildcard || address == loopback: loopbackV4 = true
            case .v6 where address.isWildcard:
                // `::` serves ::1, and 127.0.0.1 too when dual-stack.
                loopbackV6 = true
                if socket.families.contains(.v4) { loopbackV4 = true }
            case .v6 where address.isLoopback: loopbackV6 = true
            default: if specific == nil { specific = address }
            }
        }
        if loopbackV4 && loopbackV6 { return "localhost" }
        if loopbackV4 { return "127.0.0.1" }
        if loopbackV6 { return "[::1]" }
        guard let specific, !specific.isLinkLocal else { return nil }
        if case .v6 = specific { return "[\(specific.description)]" }
        return specific.description
    }

    /// 127.0.0.1, the IPv4 loopback a URL names (its v4-mapped form taken
    /// as it, `ActivityAddress`).
    private static let loopback = ActivityAddress.v4(in_addr_t(0x7F00_0001).bigEndian)

    /// Who can reach a listener bound to `bound` (6.8): a wildcard is the
    /// network, one address that isn't loopback that address, else this
    /// Mac. Pure.
    static func scope(of bound: [(address: ActivityAddress?, families: SocketRecord.Families)]) -> ListeningPort.Scope {
        if bound.contains(where: { $0.address?.isWildcard == true }) { return .network }
        if bound.contains(where: { $0.address.map { !$0.isLoopback } ?? false }) { return .oneAddress }
        return .thisMac
    }

    /// A published port's host address (Docker's `HostIp`; nil for every
    /// address) as its URL's host, as `PublishedPort` reaches it, and its
    /// scope.
    static func published(hostIP: String?) -> (host: String, scope: ListeningPort.Scope) {
        guard let hostIP, !["0.0.0.0", "::", "*"].contains(hostIP) else { return ("localhost", .network) }
        let host = hostIP.contains(":") ? "[\(hostIP)]" : hostIP
        return (host, KubeForwardAddress.isLoopback(hostIP) ? .thisMac : .oneAddress)
    }

    /// The listening TCP sockets of `pids`, each with its process's start
    /// time read right after the listing, off the main thread as it is.
    static func of(_ pids: [pid_t]) async -> [ListeningPort] {
        guard !pids.isEmpty else { return [] }
        let list = pids.map(String.init).joined(separator: ",")
        // -a: AND the filters (these pids AND listening TCP); -n/-P: no DNS or
        // service names; -F: machine-readable fields. Exit 1 = none found.
        let output =
            (try? await Git.run(
                lsof, ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", list, "-F", "pcn"],
                in: URL(fileURLWithPath: "/"), success: [0, 1])) ?? ""
        return parse(output).map { port in
            var port = port
            port.start = start(of: port.pid)
            return port
        }
    }

    /// When `pid`'s process started (µs), if it runs and is the user's:
    /// proc_pidinfo answers for no one else's.
    static func start(of pid: pid_t) -> UInt64? {
        ProcessInspector.bsdInfo(pid).map(ProcessInspector.startTime)
    }

    /// Parses `lsof -F pcn`: `p<pid>` and `c<command>` start a process, each
    /// `n<address:port>` is one of its sockets. IPv4 and IPv6 bindings of the
    /// same port collapse into one entry.
    static func parse(_ output: String) -> [ListeningPort] {
        var result: [ListeningPort] = []
        var seen = Set<String>()
        var pid: pid_t = 0
        var command = ""
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                pid = pid_t(value) ?? 0
            case "c":
                command = value
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let key = "\(pid):\(port)"
                guard seen.insert(key).inserted else { continue }
                result.append(ListeningPort(pid: pid, process: command, port: port, address: String(value[..<colon])))
            default:
                continue
            }
        }
        return result.sorted { $0.port < $1.port }
    }
}
