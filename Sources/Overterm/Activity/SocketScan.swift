import Darwin

/// An IP address a socket is bound or connected to, IPv4-mapped IPv6
/// (`::ffff:127.0.0.1`) taken as the IPv4 it maps (docs/design/activity/
/// analysis.md, 6.8), so two ends of one connection pair whatever family
/// each socket was made in.
enum ActivityAddress: Hashable, Sendable, CustomStringConvertible {
    /// Network byte order, as `in_addr` keeps it.
    case v4(UInt32)
    /// Network byte order: the address's 16 bytes, first 8 and last 8.
    case v6(UInt64, UInt64)

    init(v4 address: in_addr) { self = .v4(address.s_addr) }

    init(v6 address: in6_addr) {
        let (high, low) = withUnsafeBytes(of: address) { raw in
            (raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self), raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        }
        // ::ffff:a.b.c.d: ten zero bytes, two 0xff, then the IPv4 address.
        let mappedPrefix = withUnsafeBytes(of: address) { raw in raw.prefix(12).elementsEqual([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF]) }
        if mappedPrefix {
            self = .v4(withUnsafeBytes(of: address) { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) })
        } else {
            self = .v6(high, low)
        }
    }

    /// 0.0.0.0 or `::`: every address of the Mac.
    var isWildcard: Bool {
        switch self {
        case .v4(let address): address == 0
        case .v6(let high, let low): high == 0 && low == 0
        }
    }

    /// 127/8 or `::1`: this Mac only.
    var isLoopback: Bool {
        switch self {
        case .v4(let address): UInt32(bigEndian: address) >> 24 == 127
        case .v6(let high, let low): high == 0 && UInt64(bigEndian: low) == 1
        }
    }

    /// fe80::/10: needs a zone to be reached.
    var isLinkLocal: Bool {
        guard case .v6(let high, _) = self else { return false }
        return UInt64(bigEndian: high) >> 54 == 0x3FA
    }

    /// As `inet_ntop` writes it.
    var description: String {
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch self {
        case .v4(let address):
            var raw = in_addr(s_addr: address)
            inet_ntop(AF_INET, &raw, &text, socklen_t(text.count))
        case .v6(let high, let low):
            var raw = in6_addr()
            withUnsafeMutableBytes(of: &raw) { bytes in
                bytes.storeBytes(of: high, toByteOffset: 0, as: UInt64.self)
                bytes.storeBytes(of: low, toByteOffset: 8, as: UInt64.self)
            }
            inet_ntop(AF_INET6, &raw, &text, socklen_t(text.count))
        }
        return String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// A TCP socket's state, by `tcpsi_state`'s numbers (`TSI_S_*`).
enum TCPState: Int32, Hashable, Sendable {
    case closed = 0
    case listen = 1
    case synSent = 2
    case synReceived = 3
    case established = 4
    case closeWait = 5
    case finWait1 = 6
    case closing = 7
    case lastAck = 8
    case finWait2 = 9
    case timeWait = 10
}

/// One socket a process holds, decoded from `socket_fdinfo` (7.6).
struct SocketRecord: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case tcp
        case udp
        /// Counted only (D-32): kept for the detail.
        case unix
        /// Raw IP, a kernel control or event socket, PF_NDRV…: not a port.
        case other
    }

    /// The families it serves (`insi_vflag`): a dual-stack socket both.
    struct Families: OptionSet, Hashable, Sendable {
        let rawValue: UInt8
        static let v4 = Families(rawValue: 0x1)
        static let v6 = Families(rawValue: 0x2)
    }

    let descriptor: Int32
    /// `soi_so`: the kernel's handle of the socket — the same one in every
    /// process that inherited it; a cache's check that a descriptor still
    /// holds the socket it held.
    let socket: UInt64
    let kind: Kind
    let families: Families
    /// Nil for a unix or other socket.
    let localAddress: ActivityAddress?
    let localPort: UInt16
    let remoteAddress: ActivityAddress?
    let remotePort: UInt16
    /// TCP's only.
    let state: TCPState?
    /// Connections accepted by the kernel and not yet by the process
    /// (`soi_qlen`), against how many it may hold (`soi_qlimit`): a listener
    /// at its limit isn't accepting (6.8, Backlog).
    let backlog: Int
    let backlogLimit: Int
    /// A unix socket's bound path (`unsi_addr`), when it listens
    /// (`SO_ACCEPTCONN`): what D-32's rows say. Nil for any other.
    var path: String? = nil

    var isListening: Bool { kind == .tcp && state == .listen }
    /// UDP with a port and no peer: a UDP server's socket.
    var isBoundUDP: Bool { kind == .udp && localPort != 0 && remotePort == 0 }
    /// What the light level keeps: listeners and bound UDP (7.3).
    var isListener: Bool { isListening || isBoundUDP }
    /// A unix socket that accepts connections, with a path (D-32).
    var isUnixListener: Bool { kind == .unix && path != nil }

    /// What the kernel's structure says, pure; nil for a structure that
    /// isn't a socket's.
    static func classify(_ info: socket_fdinfo, descriptor: Int32) -> SocketRecord? {
        let socket = info.psi
        func record(_ kind: Kind, _ internet: in_sockinfo? = nil, state: TCPState? = nil) -> SocketRecord {
            var families: Families = []
            var local: ActivityAddress?
            var remote: ActivityAddress?
            var localPort: UInt16 = 0
            var remotePort: UInt16 = 0
            if let internet {
                families = Families(rawValue: internet.insi_vflag & 0x3)
                // An IPv6 socket in its v4-only state (a v4-mapped peer)
                // keeps its addresses in the IPv4 slot, as an IPv4 one does.
                let v4 = families == .v4
                local = v4 ? ActivityAddress(v4: internet.insi_laddr.ina_46.i46a_addr4) : ActivityAddress(v6: internet.insi_laddr.ina_6)
                remote = v4 ? ActivityAddress(v4: internet.insi_faddr.ina_46.i46a_addr4) : ActivityAddress(v6: internet.insi_faddr.ina_6)
                localPort = port(internet.insi_lport)
                remotePort = port(internet.insi_fport)
            }
            return SocketRecord(
                descriptor: descriptor, socket: socket.soi_so, kind: kind, families: families, localAddress: local, localPort: localPort,
                remoteAddress: remote, remotePort: remotePort, state: state, backlog: Int(socket.soi_qlen), backlogLimit: Int(socket.soi_qlimit))
        }
        switch Int(socket.soi_kind) {
        case SOCKINFO_TCP:
            let tcp = socket.soi_proto.pri_tcp
            return record(.tcp, tcp.tcpsi_ini, state: TCPState(rawValue: tcp.tcpsi_state))
        case SOCKINFO_IN:
            return record(socket.soi_protocol == IPPROTO_UDP ? .udp : .other, socket.soi_proto.pri_in)
        case SOCKINFO_UN:
            var unix = record(.unix)
            // Listening (`SO_ACCEPTCONN`) and bound: its path, for D-32's
            // rows; a connected end or an unnamed one keeps none.
            if Int32(socket.soi_options) & SO_ACCEPTCONN != 0 {
                var address = socket.soi_proto.pri_un.unsi_addr.ua_sun
                let path = withUnsafeBytes(of: &address.sun_path) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
                if !path.isEmpty { unix.path = path }
            }
            return unix
        default:
            return record(socket.soi_family == AF_UNIX ? .unix : .other)
        }
    }

    /// `insi_lport` and `insi_fport` hold the port in network byte order in
    /// an `int`.
    static func port(_ raw: Int32) -> UInt16 { UInt16(bigEndian: UInt16(truncatingIfNeeded: raw)) }
}

/// The user's sockets, process by process (7.6): `PROC_PIDLISTFDS`, then
/// `PROC_PIDFDSOCKETINFO` for each socket descriptor, 1.7–1.8 µs each. One
/// process may hold tens of thousands (a load test, a proxy, a server
/// piling up CLOSE_WAIT), so each is bounded:
///
/// - its sockets are read again only when its descriptor count changed,
///   or `refreshTicks` ticks after the last whole read — a listener closed
///   and another opened between two ticks leaves the count as it was;
/// - at most `budget` socket infos a tick, a pass rotating on from where
///   the last tick stopped;
/// - a process with more sockets than that keeps its listeners cached by
///   descriptor and `soi_so`, read again every `refreshTicks` ticks while
///   the rotation comes round, and of the rest only what this tick read —
///   the bound said on its row (`Bound`).
///
/// A value the sampler keeps between ticks on its queue, never the main
/// thread's.
struct SocketScan: Sendable {
    static let perProcessBudget = 2_000
    /// 10 s at the 2 s default (7.2).
    static let refreshTicks = 5

    /// One process's sockets, as far as they were read.
    struct Sockets: Hashable, Sendable {
        /// Its TCP and UDP sockets known now — and its listening unix ones
        /// with a path (D-32) —, by descriptor: read this tick
        /// or kept from an earlier one (a bounded process's listeners only).
        var records: [SocketRecord]
        /// Its descriptors of any kind.
        var descriptors: Int
        /// How many of them are sockets.
        var sockets: Int
        /// Unix sockets among those known: counted only (D-32).
        var unixSockets: Int
        /// Set when it holds more sockets than a tick reads.
        var bound: Bound?

        var listeners: [SocketRecord] { records.filter(\.isListener) }
    }

    /// A process read in rotation, for its row (7.2: "48,000 sockets —
    /// listeners read every 10 s").
    struct Bound: Hashable, Sendable {
        let sockets: Int
        /// Socket infos read a tick.
        let perTick: Int
        /// Ticks a whole pass takes.
        let ticksPerPass: Int
        /// Ticks between re-reads of the listeners it knows.
        let listenerTicks: Int
    }

    private struct State: Sendable {
        var descriptors = -1
        /// What is known, by descriptor: every socket's, or a bounded
        /// process's listeners and this tick's window.
        var records: [Int32: SocketRecord] = [:]
        var unixDescriptors: Set<Int32> = []
        /// The descriptor the rotation goes on from.
        var next: Int32 = 0
        /// Socket infos still to read before the pass is whole.
        var pending = 0
        /// The tick the last pass came whole.
        var passedAt = Int.min / 2
        /// The tick a bounded process's listeners were last read.
        var listenersReadAt = Int.min / 2
    }

    private var states: [ActivityProcessID: State] = [:]
    private(set) var tick = 0
    let budget: Int
    let refreshTicks: Int

    init(budget: Int = SocketScan.perProcessBudget, refreshTicks: Int = SocketScan.refreshTicks) {
        self.budget = max(budget, 1)
        self.refreshTicks = max(refreshTicks, 1)
    }

    /// A new tick: what is no longer `live` is forgotten.
    mutating func advance(keeping live: Set<ActivityProcessID>) {
        tick += 1
        states = states.filter { live.contains($0.key) }
    }

    /// `process`'s sockets this tick; nil when its descriptors can't be
    /// listed (another user's, or gone).
    mutating func read(_ process: ActivityProcessID, kernel: some ActivityKernel) -> Sockets? {
        guard let listed = kernel.descriptors(of: process.pid) else {
            states[process] = nil
            return nil
        }
        var state = states[process] ?? State()
        let sockets = listed.filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }.map(\.proc_fd).sorted()
        let present = Set(sockets)
        state.records = state.records.filter { present.contains($0.key) }
        state.unixDescriptors.formIntersection(present)
        let changed = listed.count != state.descriptors
        state.descriptors = listed.count
        // A pass begun over more sockets than there are now ends sooner.
        state.pending = min(state.pending, sockets.count)
        let bounded = sockets.count > budget

        var reads = 0
        if bounded {
            // This tick's window replaces the last one's; listeners stay.
            state.records = state.records.filter { $0.value.isListener }
            if tick - state.listenersReadAt >= refreshTicks {
                for descriptor in state.records.keys.sorted() where reads < budget {
                    refresh(descriptor, of: process, in: &state, kernel: kernel)
                    reads += 1
                }
                state.listenersReadAt = tick
            }
        }
        if changed || (state.pending == 0 && tick - state.passedAt >= refreshTicks) { state.pending = sockets.count }
        let wasPending = state.pending > 0
        var position = Self.firstIndex(in: sockets, notBelow: state.next)
        while state.pending > 0, reads < budget {
            if position >= sockets.count { position = 0 }
            refresh(sockets[position], of: process, in: &state, kernel: kernel)
            position += 1
            state.pending -= 1
            reads += 1
        }
        if !sockets.isEmpty { state.next = position < sockets.count ? sockets[position] : sockets[0] }
        if wasPending, state.pending == 0 { state.passedAt = tick }
        if sockets.isEmpty { state.passedAt = tick }
        states[process] = state

        let bound =
            bounded
            ? Bound(sockets: sockets.count, perTick: budget, ticksPerPass: (sockets.count + budget - 1) / budget, listenerTicks: refreshTicks)
            : nil
        return Sockets(
            records: state.records.values.sorted { $0.descriptor < $1.descriptor }, descriptors: listed.count, sockets: sockets.count,
            unixSockets: state.unixDescriptors.count, bound: bound)
    }

    /// The first index of a sorted list whose value is at least `value`.
    private static func firstIndex(in sorted: [Int32], notBelow value: Int32) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// One descriptor read again: its record replaced, or dropped when it
    /// holds no TCP or UDP socket now.
    private func refresh(_ descriptor: Int32, of process: ActivityProcessID, in state: inout State, kernel: some ActivityKernel) {
        guard let info = kernel.socket(of: process.pid, descriptor: descriptor), let record = SocketRecord.classify(info, descriptor: descriptor)
        else {
            state.records[descriptor] = nil
            state.unixDescriptors.remove(descriptor)
            return
        }
        switch record.kind {
        case .tcp, .udp:
            state.unixDescriptors.remove(descriptor)
            state.records[descriptor] = record
        case .unix:
            // Counted; a listening one with a path kept for D-32's rows.
            state.unixDescriptors.insert(descriptor)
            state.records[descriptor] = record.isUnixListener ? record : nil
        case .other:
            state.unixDescriptors.remove(descriptor)
            state.records[descriptor] = nil
        }
    }
}
