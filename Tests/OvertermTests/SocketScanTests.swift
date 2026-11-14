import Darwin
import XCTest

@testable import Overterm

/// The census's sockets (docs/design/activity/analysis.md, 7.6): the
/// classification from fixtures, real sockets of the test's own children,
/// and the bound on one process with thousands.
final class SocketScanTests: XCTestCase {
    private func classify(_ info: socket_fdinfo) -> SocketRecord? { SocketRecord.classify(info, descriptor: 7) }

    func testTCPListenersByFamily() throws {
        let v4 = try XCTUnwrap(classify(FakeActivityKernel.tcp(local: "127.0.0.1", port: 8080, backlog: 3, backlogLimit: 128)))
        XCTAssertEqual(v4.kind, .tcp)
        XCTAssertEqual(v4.state, .listen)
        XCTAssertTrue(v4.isListening)
        XCTAssertTrue(v4.isListener)
        XCTAssertEqual(v4.families, .v4)
        XCTAssertEqual(v4.localPort, 8080, "network byte order read as a number")
        XCTAssertEqual(v4.localAddress?.description, "127.0.0.1")
        XCTAssertTrue(v4.localAddress?.isLoopback ?? false)
        XCTAssertEqual(v4.backlog, 3)
        XCTAssertEqual(v4.backlogLimit, 128)
        XCTAssertEqual(v4.descriptor, 7)

        let v6 = try XCTUnwrap(classify(FakeActivityKernel.tcp(local: "::1", port: 5173)))
        XCTAssertEqual(v6.families, .v6)
        XCTAssertEqual(v6.localAddress?.description, "::1")
        XCTAssertTrue(v6.localAddress?.isLoopback ?? false)

        let dual = try XCTUnwrap(classify(FakeActivityKernel.tcp(local: "::", port: 3000, dualStack: true)))
        XCTAssertEqual(dual.families, [.v4, .v6])
        XCTAssertTrue(dual.localAddress?.isWildcard ?? false)

        let wildcard = try XCTUnwrap(classify(FakeActivityKernel.tcp(local: "0.0.0.0", port: 5000)))
        XCTAssertTrue(wildcard.localAddress?.isWildcard ?? false)
        XCTAssertFalse(wildcard.localAddress?.isLoopback ?? true)
        XCTAssertEqual(try XCTUnwrap(classify(FakeActivityKernel.tcp(local: "192.168.1.5", port: 65_535))).localPort, 65_535)
    }

    func testConnectionsUDPAndTheRest() throws {
        let established = try XCTUnwrap(
            classify(FakeActivityKernel.tcp(local: "127.0.0.1", port: 52_011, remote: "127.0.0.1", remotePort: 5173, state: .established)))
        XCTAssertEqual(established.state, .established)
        XCTAssertFalse(established.isListener)
        XCTAssertEqual(established.remotePort, 5173)
        XCTAssertEqual(established.remoteAddress?.description, "127.0.0.1")
        XCTAssertEqual(try XCTUnwrap(classify(FakeActivityKernel.tcp(local: "::1", port: 1, state: .closeWait))).state, .closeWait)

        let bound = try XCTUnwrap(classify(FakeActivityKernel.udp(local: "0.0.0.0", port: 5353)))
        XCTAssertEqual(bound.kind, .udp)
        XCTAssertTrue(bound.isBoundUDP)
        XCTAssertTrue(bound.isListener)
        XCTAssertNil(bound.state)
        let connected = try XCTUnwrap(classify(FakeActivityKernel.udp(local: "192.168.1.5", port: 61_000, remote: "1.1.1.1", remotePort: 53)))
        XCTAssertFalse(connected.isBoundUDP, "a UDP socket with a peer is a client's")
        XCTAssertFalse(try XCTUnwrap(classify(FakeActivityKernel.udp(local: "0.0.0.0", port: 0))).isBoundUDP)

        let unix = try XCTUnwrap(classify(FakeActivityKernel.unix()))
        XCTAssertEqual(unix.kind, .unix)
        XCTAssertNil(unix.localAddress)
        XCTAssertFalse(unix.isListener)
    }

    /// `::ffff:127.0.0.1` is the IPv4 loopback it maps: both ends of a
    /// connection pair whatever family each socket was made in.
    func testV4MappedAddressesAreNormalised() throws {
        let mapped = try XCTUnwrap(classify(FakeActivityKernel.tcp(local: "::ffff:127.0.0.1", port: 8000)))
        XCTAssertEqual(mapped.localAddress, ActivityAddress.v4(inet_addr("127.0.0.1")))
        XCTAssertEqual(mapped.localAddress?.description, "127.0.0.1")
        XCTAssertTrue(mapped.localAddress?.isLoopback ?? false)
        var linkLocal = in6_addr()
        inet_pton(AF_INET6, "fe80::1", &linkLocal)
        XCTAssertTrue(ActivityAddress(v6: linkLocal).isLinkLocal)
        XCTAssertFalse(ActivityAddress.v4(inet_addr("10.0.0.1")).isLinkLocal)
        XCTAssertEqual(SocketRecord.port(Int32(UInt16(443).bigEndian)), 443)
    }

    // MARK: Real sockets

    private func socket(_ family: Int32, _ type: Int32, address: String) throws -> (fd: Int32, port: UInt16) {
        let fd = Darwin.socket(family, type, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        var on: Int32 = 1
        var port: UInt16 = 0
        if family == AF_INET6 {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
            var socketAddress = sockaddr_in6()
            socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            socketAddress.sin6_family = sa_family_t(AF_INET6)
            inet_pton(AF_INET6, address, &socketAddress.sin6_addr)
            let size = socklen_t(MemoryLayout<sockaddr_in6>.size)
            XCTAssertEqual(withUnsafePointer(to: &socketAddress) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) } }, 0)
            var length = size
            _ = withUnsafeMutablePointer(to: &socketAddress) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
            port = UInt16(bigEndian: socketAddress.sin6_port)
        } else {
            var socketAddress = sockaddr_in()
            socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            socketAddress.sin_family = sa_family_t(AF_INET)
            socketAddress.sin_addr.s_addr = inet_addr(address)
            let size = socklen_t(MemoryLayout<sockaddr_in>.size)
            XCTAssertEqual(withUnsafePointer(to: &socketAddress) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) } }, 0)
            var length = size
            _ = withUnsafeMutablePointer(to: &socketAddress) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
            port = UInt16(bigEndian: socketAddress.sin_port)
        }
        if type == SOCK_STREAM { XCTAssertEqual(listen(fd, 16), 0) }
        return (fd, port)
    }

    /// A child of the test's holding a TCP listener on 127.0.0.1, one on
    /// ::1 and a bound UDP socket — handed to it, so they listen before it
    /// runs: each found with its family, port and state, the same socket
    /// (`soi_so`) the test held; a connection waiting in its queue counted.
    func testARealChildsListeners() throws {
        let v4 = try socket(AF_INET, SOCK_STREAM, address: "127.0.0.1")
        let v6 = try socket(AF_INET6, SOCK_STREAM, address: "::1")
        let udp = try socket(AF_INET, SOCK_DGRAM, address: "127.0.0.1")
        let child = try TestChild("/bin/sleep", ["60"], descriptors: [v4.fd: v4.fd, v6.fd: v6.fd, udp.fd: udp.fd])
        defer { child.stop() }
        let kernel = LiveActivityKernel()
        var scan = SocketScan()
        let ours = try XCTUnwrap(scan.read(ActivityProcessID(pid: getpid(), start: 0), kernel: kernel))
        let theirs = try XCTUnwrap(scan.read(child.identity, kernel: kernel))
        for fd in [v4.fd, v6.fd, udp.fd] {
            XCTAssertEqual(ours.records.first { $0.descriptor == fd }?.socket, theirs.records.first { $0.descriptor == fd }?.socket, "one socket, two holders")
            close(fd)
        }

        let tcp4 = try XCTUnwrap(theirs.records.first { $0.descriptor == v4.fd })
        XCTAssertEqual(tcp4.kind, .tcp)
        XCTAssertEqual(tcp4.state, .listen)
        XCTAssertEqual(tcp4.families, .v4)
        XCTAssertEqual(tcp4.localPort, v4.port)
        XCTAssertEqual(tcp4.localAddress, .v4(inet_addr("127.0.0.1")))
        let tcp6 = try XCTUnwrap(theirs.records.first { $0.descriptor == v6.fd })
        XCTAssertEqual(tcp6.state, .listen)
        XCTAssertEqual(tcp6.families, .v6)
        XCTAssertEqual(tcp6.localPort, v6.port)
        XCTAssertEqual(tcp6.localAddress?.description, "::1")
        let bound = try XCTUnwrap(theirs.records.first { $0.descriptor == udp.fd })
        XCTAssertTrue(bound.isBoundUDP)
        XCTAssertEqual(bound.localPort, udp.port)
        XCTAssertEqual(Set(theirs.listeners.map(\.localPort)), [v4.port, v6.port, udp.port])

        // A client of the test's: the kernel completes the handshake and the
        // connection waits in the child's queue (sleep never accepts).
        let client = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_addr.s_addr = inet_addr("127.0.0.1")
        target.sin_port = v4.port.bigEndian
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, size) } }, 0)
        // A fresh scan each time: a scan's own cache reads again only when
        // the descriptors change, and the queue's don't.
        func listener() -> SocketRecord? {
            var scan = SocketScan()
            return scan.read(child.identity, kernel: kernel)?.records.first { $0.descriptor == v4.fd }
        }
        XCTAssertTrue(TestChild.eventually { listener()?.backlog == 1 }, "the connection waits in its queue")
        var fresh = SocketScan()
        let connection = try XCTUnwrap(fresh.read(ActivityProcessID(pid: getpid(), start: 0), kernel: kernel)?.records.first { $0.descriptor == client })
        XCTAssertEqual(connection.state, .established)
        XCTAssertEqual(connection.remotePort, v4.port)
        XCTAssertTrue(connection.remoteAddress?.isLoopback ?? false)
    }

    // MARK: The bound

    /// A process with 20,000 sockets (7.2): at most the budget read a tick,
    /// rotating until every one was read; its listeners kept by descriptor
    /// and `soi_so` and read again on their own beat; nothing read again
    /// while its descriptors don't change, until the refresh.
    func testAHeavyProcessIsReadInRotation() throws {
        let kernel = FakeActivityKernel()
        let identity = ActivityProcessID(pid: 4242, start: 1)
        var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 4242, start: 1, parent: 1))
        for fd in Int32(3)..<20_003 {
            process.descriptors.append(FakeActivityKernel.descriptor(fd))
            process.sockets[fd] =
                fd == 15_000
                ? FakeActivityKernel.tcp(local: "127.0.0.1", port: 3000, handle: 0xACE)
                : FakeActivityKernel.tcp(local: "10.0.0.2", port: 40_000, remote: "10.0.0.9", remotePort: 443, state: .closeWait, handle: UInt64(fd))
        }
        process.descriptors.append(FakeActivityKernel.descriptor(2, socket: false))
        kernel.add(process)
        var scan = SocketScan(budget: 2_000, refreshTicks: 5)
        var found: Int?
        for tick in 1...10 {
            scan.advance(keeping: [identity])
            kernel.resetCounts()
            let sockets = try XCTUnwrap(scan.read(identity, kernel: kernel))
            XCTAssertLessThanOrEqual(kernel.count("socket"), 2_000, "tick \(tick)")
            XCTAssertEqual(sockets.bound, SocketScan.Bound(sockets: 20_000, perTick: 2_000, ticksPerPass: 10, listenerTicks: 5))
            XCTAssertEqual(sockets.sockets, 20_000)
            XCTAssertEqual(sockets.descriptors, 20_001)
            XCTAssertLessThanOrEqual(sockets.records.count, 2_001)
            if found == nil, sockets.listeners.contains(where: { $0.localPort == 3000 }) { found = tick }
        }
        XCTAssertEqual(found, 8, "fd 15,000 is in the eighth window of 2,000")
        // The pass came round; nothing changed: a tick reads only its
        // listener, on the listeners' own beat.
        scan.advance(keeping: [identity])
        kernel.resetCounts()
        let quiet = try XCTUnwrap(scan.read(identity, kernel: kernel))
        XCTAssertEqual(kernel.count("socket"), 1)
        XCTAssertEqual(quiet.listeners.map(\.localPort), [3000], "the listener kept from its window")
        // A listener closed and another opened on the same descriptor: the
        // count is the same, the listeners' own beat finds it.
        kernel.update(4242) { $0.sockets[15_000] = FakeActivityKernel.tcp(local: "127.0.0.1", port: 3001, handle: 0xBEE) }
        var moved: Int?
        for tick in 1...6 {
            scan.advance(keeping: [identity])
            if moved == nil, scan.read(identity, kernel: kernel)?.listeners.map(\.localPort) == [3001] { moved = tick }
        }
        XCTAssertNotNil(moved)
        // Gone from the table: forgotten.
        scan.advance(keeping: [])
        kernel.remove(4242)
        XCTAssertNil(scan.read(identity, kernel: kernel))
    }

    /// A light process is read whole when its descriptors change, and
    /// again every `refreshTicks` ticks — not every tick.
    func testALightProcessIsReadWhenItChanges() throws {
        let kernel = FakeActivityKernel()
        let identity = ActivityProcessID(pid: 77, start: 9)
        var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 77, start: 9, parent: 1))
        process.descriptors = [FakeActivityKernel.descriptor(5), FakeActivityKernel.descriptor(6), FakeActivityKernel.descriptor(7)]
        process.sockets = [5: FakeActivityKernel.tcp(local: "127.0.0.1", port: 8000), 6: FakeActivityKernel.unix(), 7: FakeActivityKernel.udp(local: "0.0.0.0", port: 0)]
        kernel.add(process)
        var scan = SocketScan(budget: 2_000, refreshTicks: 5)
        var reads: [Int] = []
        for _ in 1...6 {
            scan.advance(keeping: [identity])
            kernel.resetCounts()
            let sockets = try XCTUnwrap(scan.read(identity, kernel: kernel))
            XCTAssertNil(sockets.bound)
            XCTAssertEqual(sockets.unixSockets, 1)
            XCTAssertEqual(sockets.records.count, 2, "TCP and UDP; the unix one counted")
            reads.append(kernel.count("socket"))
        }
        XCTAssertEqual(reads, [3, 0, 0, 0, 0, 3])
        kernel.update(77) {
            $0.descriptors.append(FakeActivityKernel.descriptor(8))
            $0.sockets[8] = FakeActivityKernel.tcp(local: "::1", port: 9000)
        }
        scan.advance(keeping: [identity])
        kernel.resetCounts()
        let changed = try XCTUnwrap(scan.read(identity, kernel: kernel))
        XCTAssertEqual(kernel.count("socket"), 4)
        XCTAssertEqual(Set(changed.listeners.map(\.localPort)), [8000, 9000])
        XCTAssertNil(scan.read(ActivityProcessID(pid: 1, start: 0), kernel: kernel), "nobody the kernel lists")
    }

    /// A real child holding a few thousand sockets: bounded a tick, its
    /// listener found when the rotation comes to it, quick.
    func testARealChildWithThousandsOfSockets() throws {
        var limit = rlimit()
        getrlimit(RLIMIT_NOFILE, &limit)
        let saved = limit
        if limit.rlim_cur < 4_096 {
            limit.rlim_cur = min(4_096, limit.rlim_max)
            XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &limit), 0)
        }
        defer {
            var restore = saved
            setrlimit(RLIMIT_NOFILE, &restore)
        }
        var held: [Int32] = []
        defer { held.forEach { close($0) } }
        for _ in 0..<3_000 {
            let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
            XCTAssertGreaterThanOrEqual(fd, 0)
            if fd >= 0 { held.append(fd) }
        }
        let listener = try socket(AF_INET, SOCK_STREAM, address: "127.0.0.1")
        held.append(listener.fd)
        let child = try TestChild("/bin/sleep", ["60"], descriptors: Dictionary(uniqueKeysWithValues: held.map { ($0, $0) }))
        defer { child.stop() }
        held.forEach { close($0) }
        held = []

        let kernel = CountingKernel(LiveActivityKernel())
        var scan = SocketScan(budget: 2_000, refreshTicks: 5)
        var found = false
        for _ in 0..<2 {
            scan.advance(keeping: [child.identity])
            kernel.reset()
            let sockets = try XCTUnwrap(scan.read(child.identity, kernel: kernel))
            XCTAssertLessThanOrEqual(kernel.sockets, 2_000)
            XCTAssertEqual(sockets.bound?.sockets, 3_001)
            found = found || sockets.listeners.contains { $0.localPort == listener.port && $0.state == .listen }
        }
        XCTAssertTrue(found, "the listener, past the first 2,000, found by the second tick")
    }
}

/// A kernel that counts the socket infos asked of the real one.
private final class CountingKernel: ActivityKernel, @unchecked Sendable {
    private let base: LiveActivityKernel
    private let lock = NSLock()
    private var count = 0

    init(_ base: LiveActivityKernel) { self.base = base }

    var sockets: Int { lock.withLock { count } }
    func reset() { lock.withLock { count = 0 } }

    var uid: uid_t { base.uid }
    func uptime() -> UInt64 { base.uptime() }
    func processes() -> [ActivityProcess]? { base.processes() }
    func usage(of pid: pid_t) -> ActivityUsage? { base.usage(of: pid) }
    func name(of pid: pid_t) -> String? { base.name(of: pid) }
    func path(of pid: pid_t) -> String? { base.path(of: pid) }
    func codeSigningStatus(of pid: pid_t) -> CodeSigningAnswer { base.codeSigningStatus(of: pid) }
    func securityCodeSigning(of pid: pid_t) -> ActivityCodeSigning? { base.securityCodeSigning(of: pid) }
    func argumentsLength(of pid: pid_t) -> Int? { base.argumentsLength(of: pid) }
    func readArguments(of pid: pid_t, into region: UnsafeMutableRawBufferPointer) -> Int? { base.readArguments(of: pid, into: region) }
    func descriptors(of pid: pid_t) -> [proc_fdinfo]? { base.descriptors(of: pid) }
    func socket(of pid: pid_t, descriptor: Int32) -> socket_fdinfo? {
        lock.withLock { count += 1 }
        return base.socket(of: pid, descriptor: descriptor)
    }
}
