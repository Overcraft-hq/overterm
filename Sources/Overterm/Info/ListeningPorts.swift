import Foundation
import os

/// A port a tab's process is listening on — typically a dev server —
/// or one a container of the tab's checkout publishes (Docker's own
/// process holds those, so the socket walk never finds them under the tab).
package struct ListeningPort: Identifiable, Hashable {
    package let pid: pid_t
    package let process: String
    package let port: Int
    /// The bound address as lsof prints it (`*`, `127.0.0.1`, `[::1]`): of
    /// a process's sockets on the port, the widest — a wildcard, else one
    /// address that isn't loopback, else loopback.
    package let address: String
    /// The container publishing it; its service is `process`, `pid` is 0.
    package var container: String? = nil
    /// The port the compose file asks for, when Up on Free Ports moved it
    /// here for this checkout (`ComposePorts`).
    package var movedFrom: Int? = nil
    /// A Kubernetes port-forward's (`KubeForwards`): kubectl is Overterm's
    /// child, not the tab's, so the socket walk never finds it under the
    /// tab. Its pid is kubectl's while it forwards, 0 while it restarts.
    package var forward: KubeForwardPill? = nil
    /// "tcp" or "udp".
    package var proto = "tcp"
    /// The families its sockets serve (`insi_vflag`, docs/design/activity/
    /// analysis.md 6.8): a dual-stack socket both. None known for a
    /// container's or a forward's.
    package var families: SocketRecord.Families = []
    /// Who can reach it (6.8).
    package var scope = Scope.thisMac
    /// When the process holding it started, µs since 1970: with `pid`, the
    /// identity a pill's verb checks before it acts (6.12). Nil for a
    /// container's or a forward's, whose owners act for them.
    package var start: UInt64? = nil
    /// Where a browser reaches it (6.8): its URL's host, from its sockets'
    /// bound addresses and families — `localhost` only where both families
    /// listen on loopback, since a client may try ::1 first and give up.
    /// Nil when there is none to open: a link-local address needs a zone
    /// id, so it is copied only.
    package var host: String? = "localhost"

    /// Who can reach a listener (6.8, Scope).
    package enum Scope: Hashable, Sendable {
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
    package var identity: ActivityProcessID? {
        guard pid > 0, let start else { return nil }
        return ActivityProcessID(pid: pid, start: start)
    }

    package var id: String {
        if let forward { return "forward:\(forward.id)" }
        if let container { return "\(container):\(port)" }
        return "\(pid):\(start ?? 0):\(proto):\(port)"
    }

    /// Where it is opened: where it listens (a forward's, https when it says so).
    package var url: URL? {
        if let forward { return URL(string: "\(forward.https ? "https" : "http")://\(KubeForwardAddress.host(for: address)):\(port)") }
        guard let host else { return nil }
        return URL(string: "http://\(host):\(port)")
    }

    /// What a pill and the browser's empty page say for it: its URL's
    /// host and the port, else its bound address and the port.
    package var endpoint: String {
        if forward != nil { return "\(KubeForwardAddress.host(for: address)):\(port)" }
        return "\(host ?? address):\(port)"
    }

    /// Its scope as 6.8's Scope column says it.
    package var reach: String {
        switch scope {
        case .thisMac: "This Mac"
        case .network: "Network"
        case .oneAddress: "Network · \(address)"
        }
    }
}

/// What listens, as the census's socket walk reads it (docs/design/
/// activity/analysis.md, 7.6): no reading path runs lsof.
package enum ListeningPorts {
    /// Whoever of the user's listens on `port` — a TCP listener, or a bound
    /// UDP socket for `udp` — as a one-off census reads it
    /// (docs/design/activity/analysis.md, 7.6: `ActivityMonitor.census`, at
    /// most one every 2 s, a younger one answering), no lsof. It sees what
    /// lsof saw: every process of the user's, and nobody else's — root's
    /// and other users' listeners come from nettop (stage 4). Nil when
    /// nothing of the user's holds it, or the table can't be read.
    package static func holder(of port: Int, proto: String = "tcp") async -> ListeningPort? {
        guard let snapshot = await ActivityMonitor.shared.census() else { return nil }
        return holder(of: port, proto: proto, in: snapshot)
    }

    /// Of what `snapshot` read, the oldest process holding `port` — every
    /// socket it holds there as one entry, as `of` makes them. Pure.
    package static func holder(of port: Int, proto: String = "tcp", in snapshot: ActivitySnapshot) -> ListeningPort? {
        let udp = proto == "udp"
        for identity in snapshot.facts.keys.sorted() {
            guard let facts = snapshot.facts[identity], let sockets = facts.sockets else { continue }
            let held = sockets.records.filter { Int($0.localPort) == port && (udp ? $0.isBoundUDP : $0.isListening) }
            if !held.isEmpty { return self.port(held, holder: identity, name: facts.name) }
        }
        return nil
    }

    /// Of what `snapshot` read, every process holding `port`: a pre-fork
    /// server's workers share its listener, a child inherits it. Pure.
    package static func holders(of port: Int, proto: String = "tcp", in snapshot: ActivitySnapshot) -> [ActivityProcessID] {
        let udp = proto == "udp"
        return snapshot.facts.keys.sorted().filter { identity in
            snapshot.facts[identity]?.sockets?.records.contains { Int($0.localPort) == port && (udp ? $0.isBoundUDP : $0.isListening) } == true
        }
    }

    /// Whether something on this Mac holds `port` — what Docker's own bind
    /// for a published port would run into, whoever holds it. A bind with
    /// SO_REUSEADDR on 0.0.0.0, 127.0.0.1, :: and ::1, then on each address
    /// of this Mac's interfaces (docs/design/activity/analysis.md, 6.8): a
    /// listener on one address is only met binding that one — a LAN, utun
    /// or Tailscale address, an IPv6 ULA, global or link-local one, which
    /// the four alone answered "free" for. Each is closed at once:
    /// TIME_WAIT doesn't count, and nothing listens, so no firewall asks. A
    /// family this Mac can't make counts as free.
    ///
    /// A probe at a decision, never a watch: it binds the very port, and a
    /// bind made while a supervisor or a KeepAlive job rebinds it makes
    /// that restart fail (EADDRINUSE), after which "free" would be said of
    /// a server the check broke. A port is watched with the census's
    /// socket walk (`holder(of:)`).
    package static func isBound(_ port: Int, proto: String = "tcp", probing addresses: [ProbeAddress] = probeAddresses()) -> Bool {
        guard (1...65535).contains(port) else { return false }
        probed.withLock { $0[port, default: 0] += 1 }
        let type = proto == "udp" ? SOCK_DGRAM : SOCK_STREAM
        return addresses.contains { refusesBind($0, port: port, type: type) }
    }

    /// How many bind probes each port has had in this process: what lets
    /// a test say a Free's watch never binds the port it watches (6.8).
    private static let probed = OSAllocatedUnfairLock<[Int: Int]>(initialState: [:])

    /// The bind probes `port` has had in this process.
    package static func bindProbes(of port: Int) -> Int { probed.withLock { $0[port] ?? 0 } }

    /// One address a bind probe tries: its family, its text, and the
    /// interface a link-local one is scoped to.
    package struct ProbeAddress: Hashable, Sendable {
        package let family: Int32
        package let address: String
        package var scope: UInt32 = 0
    }

    /// The wildcard and loopback addresses of both families, then every
    /// other address of this Mac's interfaces (`getifaddrs`), each once.
    package static func probeAddresses() -> [ProbeAddress] {
        var found = [
            ProbeAddress(family: AF_INET, address: "0.0.0.0"), ProbeAddress(family: AF_INET, address: "127.0.0.1"),
            ProbeAddress(family: AF_INET6, address: "::"), ProbeAddress(family: AF_INET6, address: "::1"),
        ]
        for address in interfaceAddresses() where !found.contains(address) { found.append(address) }
        return found
    }

    /// This Mac's interfaces' IPv4 and IPv6 addresses, loopback's left out.
    package static func interfaceAddresses() -> [ProbeAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [ProbeAddress] = []
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let raw = entry.pointee.ifa_addr else { continue }
            switch Int32(raw.pointee.sa_family) {
            case AF_INET:
                var address = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                guard inet_ntop(AF_INET, &address, &text, socklen_t(text.count)) != nil else { continue }
                let value = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if !value.hasPrefix("127.") { found.append(ProbeAddress(family: AF_INET, address: value)) }
            case AF_INET6:
                let socketAddress = raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                var address = socketAddress.sin6_addr
                var scope: UInt32 = 0
                // A link-local address is bound on its interface: the kernel
                // hands it with the interface's index in its third and
                // fourth bytes (KAME's way), which a bind wants in the scope.
                if ActivityAddress(v6: address).isLinkLocal {
                    scope = socketAddress.sin6_scope_id
                    withUnsafeMutableBytes(of: &address) { bytes in
                        if scope == 0 { scope = UInt32(bytes[2]) << 8 | UInt32(bytes[3]) }
                        bytes[2] = 0
                        bytes[3] = 0
                    }
                    if scope == 0 { scope = if_nametoindex(entry.pointee.ifa_name) }
                }
                guard inet_ntop(AF_INET6, &address, &text, socklen_t(text.count)) != nil else { continue }
                let value = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                guard value != "::1" else { continue }
                found.append(ProbeAddress(family: AF_INET6, address: value, scope: scope))
            default:
                continue
            }
        }
        return found
    }

    /// Whether binding `port` on `probe` is refused as in use.
    private static func refusesBind(_ probe: ProbeAddress, port: Int, type: Int32) -> Bool {
        let fd = socket(probe.family, type, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, size)
        let result: Int32
        if probe.family == AF_INET {
            var socketAddress = sockaddr_in()
            socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            socketAddress.sin_family = sa_family_t(AF_INET)
            socketAddress.sin_port = in_port_t(UInt16(port)).bigEndian
            guard inet_pton(AF_INET, probe.address, &socketAddress.sin_addr) == 1 else { return false }
            result = withUnsafePointer(to: &socketAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        } else {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, size)
            var socketAddress = sockaddr_in6()
            socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            socketAddress.sin6_family = sa_family_t(AF_INET6)
            socketAddress.sin6_port = in_port_t(UInt16(port)).bigEndian
            socketAddress.sin6_scope_id = probe.scope
            guard inet_pton(AF_INET6, probe.address, &socketAddress.sin6_addr) == 1 else { return false }
            result = withUnsafePointer(to: &socketAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
        return result != 0 && errno == EADDRINUSE
    }

    /// The listening TCP sockets of `members` — and their bound UDP ones,
    /// with `udp` — as the census's socket walk read them for `snapshot`
    /// (docs/design/activity/analysis.md, 7.6): a filter over the scan, no
    /// lsof. A process's sockets on one protocol and port are one entry,
    /// its v4 and v6 together: their families, the widest scope, the URL
    /// their bound addresses give (6.8), the holder's start.
    package static func of(_ members: [ActivityProcessID], in snapshot: ActivitySnapshot, udp: Bool = false) -> [ListeningPort] {
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
    package static func port(_ records: [SocketRecord], holder: ActivityProcessID, name: String) -> ListeningPort? {
        guard let first = records.first else { return nil }
        let bound = records.map { (address: $0.localAddress, families: $0.families) }
        let widest =
            records.first { $0.localAddress?.isWildcard == true }
            ?? records.first { $0.localAddress.map { !$0.isLoopback } ?? false } ?? first
        return ListeningPort(
            pid: holder.pid, process: name, port: Int(first.localPort), address: address(of: widest), proto: first.kind == .udp ? "udp" : "tcp",
            families: records.reduce([]) { $0.union($1.families) }, scope: scope(of: bound), start: holder.start, host: host(of: bound))
    }

    /// Of `tabs` — each its id, title and panes' tags —, the first whose
    /// panes `snapshot` read holding `port` (a TCP listener), with the
    /// holder's name: Docker's "a tab holds the port". A pane the snapshot
    /// has for another tab isn't this one's. Pure.
    package static func tab(holding port: Int, among tabs: [(id: UUID, title: String, tags: [String])], in snapshot: ActivitySnapshot) -> (
        UUID, String, String
    )? {
        for tab in tabs {
            for tag in tab.tags {
                guard let slice = snapshot.pane(tag), slice.tab == tab.id,
                    let held = of(slice.placed, in: snapshot).first(where: { $0.port == port })
                else { continue }
                return (tab.id, tab.title, held.process)
            }
        }
        return nil
    }

    /// A socket's bound address as lsof prints it.
    package static func address(of record: SocketRecord) -> String {
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
    package static func host(of bound: [(address: ActivityAddress?, families: SocketRecord.Families)]) -> String? {
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
    package static func scope(of bound: [(address: ActivityAddress?, families: SocketRecord.Families)]) -> ListeningPort.Scope {
        if bound.contains(where: { $0.address?.isWildcard == true }) { return .network }
        if bound.contains(where: { $0.address.map { !$0.isLoopback } ?? false }) { return .oneAddress }
        return .thisMac
    }

    /// A published port's host address (Docker's `HostIp`; nil for every
    /// address) as its URL's host, as `PublishedPort` reaches it, and its
    /// scope.
    package static func published(hostIP: String?) -> (host: String, scope: ListeningPort.Scope) {
        guard let hostIP, !["0.0.0.0", "::", "*"].contains(hostIP) else { return ("localhost", .network) }
        let host = hostIP.contains(":") ? "[\(hostIP)]" : hostIP
        return (host, KubeForwardAddress.isLoopback(hostIP) ? .thisMac : .oneAddress)
    }
}
