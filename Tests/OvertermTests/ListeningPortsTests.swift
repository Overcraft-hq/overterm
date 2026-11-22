import XCTest

@testable import Overterm
@testable import OvertermCore

final class ListeningPortsTests: XCTestCase {
    // MARK: Where a listener is reached (docs/design/activity/analysis.md, 6.8)

    /// A fixture's socket as the census decodes it.
    private func records(_ sockets: [socket_fdinfo]) -> [SocketRecord] {
        sockets.enumerated().compactMap { SocketRecord.classify($1, descriptor: Int32($0 + 3)) }
    }

    /// One process's sockets on one port, as `ListeningPorts.of` makes them
    /// one entry.
    private func listener(_ sockets: socket_fdinfo...) throws -> ListeningPort {
        try XCTUnwrap(ListeningPorts.port(records(sockets), holder: ActivityProcessID(pid: 4242, start: 1_000_007), name: "acme-dev"))
    }

    /// The URL follows the bound address and its families: `localhost`
    /// only where both families listen on loopback — a client may try ::1
    /// first and get ECONNREFUSED from a v4-only server —, one address
    /// it is bound to as that address, a link-local one Copy only (it
    /// needs a zone id). Addresses are the documentation ranges'.
    func testTheURLFollowsTheBoundAddressAndFamilies() throws {
        typealias K = FakeActivityKernel
        func url(_ sockets: socket_fdinfo...) throws -> String? {
            try XCTUnwrap(ListeningPorts.port(records(sockets), holder: ActivityProcessID(pid: 4242, start: 7), name: "acme-dev")).url?.absoluteString
        }
        XCTAssertEqual(try url(K.tcp(local: "::", port: 3000, dualStack: true)), "http://localhost:3000", "a dual-stack wildcard")
        XCTAssertEqual(try url(K.tcp(local: "0.0.0.0", port: 3000)), "http://127.0.0.1:3000", "0.0.0.0 alone: IPv4 only")
        XCTAssertEqual(try url(K.tcp(local: "::", port: 3000)), "http://[::1]:3000", ":: alone: IPv6 only")
        XCTAssertEqual(try url(K.tcp(local: "127.0.0.1", port: 3000)), "http://127.0.0.1:3000", "the ::1 trap avoided")
        XCTAssertEqual(try url(K.tcp(local: "::ffff:127.0.0.1", port: 3000)), "http://127.0.0.1:3000", "a v4-mapped loopback is IPv4's")
        // A loopback alias (`ifconfig lo0 alias`): 127.0.0.1 doesn't reach
        // it, and may reach another checkout's server on the same port.
        XCTAssertEqual(try url(K.tcp(local: "127.0.0.2", port: 3000)), "http://127.0.0.2:3000", "another 127/8 address is its own host")
        XCTAssertEqual(try url(K.tcp(local: "::ffff:127.0.0.2", port: 3000)), "http://127.0.0.2:3000", "v4-mapped too")
        let alias = try listener(K.tcp(local: "127.0.0.2", port: 3000))
        XCTAssertEqual(alias.scope, .thisMac, "still this Mac's only")
        XCTAssertEqual(alias.endpoint, "127.0.0.2:3000")
        XCTAssertEqual(try url(K.tcp(local: "127.0.0.2", port: 3000), K.tcp(local: "::1", port: 3000, handle: 2)), "http://[::1]:3000")
        XCTAssertEqual(try url(K.tcp(local: "::1", port: 3000)), "http://[::1]:3000")
        XCTAssertEqual(
            try url(K.tcp(local: "127.0.0.1", port: 5173), K.tcp(local: "::1", port: 5173, handle: 2)), "http://localhost:5173",
            "both families, one socket each")
        XCTAssertEqual(try url(K.tcp(local: "0.0.0.0", port: 8000), K.tcp(local: "::", port: 8000, handle: 2)), "http://localhost:8000")
        XCTAssertEqual(try url(K.tcp(local: "192.0.2.10", port: 3000)), "http://192.0.2.10:3000", "one LAN address isn't localhost")
        XCTAssertEqual(try url(K.tcp(local: "2001:db8::5", port: 3000)), "http://[2001:db8::5]:3000")
        XCTAssertNil(try url(K.tcp(local: "fe80::1", port: 3000)), "link-local: nothing to open")
    }

    /// A process's v4 and v6 sockets on one port are one entry, with both
    /// families, the widest scope and its holder's identity.
    func testAProcesssSocketsOnOnePortAreOneEntry() throws {
        typealias K = FakeActivityKernel
        let both = try listener(K.tcp(local: "127.0.0.1", port: 5173), K.tcp(local: "::1", port: 5173, handle: 2))
        XCTAssertEqual(both.families, [.v4, .v6])
        XCTAssertEqual(both.scope, .thisMac)
        XCTAssertEqual(both.reach, "This Mac")
        XCTAssertEqual(both.endpoint, "localhost:5173")
        XCTAssertEqual(both.identity, ActivityProcessID(pid: 4242, start: 1_000_007))
        XCTAssertEqual(both.proto, "tcp")
        let wide = try listener(K.tcp(local: "127.0.0.1", port: 8080), K.tcp(local: "0.0.0.0", port: 8080, handle: 2))
        XCTAssertEqual(wide.scope, .network, "a wildcard beside loopback reaches the network")
        XCTAssertEqual(wide.address, "*")
        XCTAssertEqual(wide.reach, "Network")
        let one = try listener(K.tcp(local: "192.0.2.10", port: 8080))
        XCTAssertEqual(one.scope, .oneAddress)
        XCTAssertEqual(one.reach, "Network · 192.0.2.10")
        XCTAssertEqual(one.endpoint, "192.0.2.10:8080")
        let linkLocal = try listener(K.tcp(local: "fe80::1", port: 3000))
        XCTAssertNil(linkLocal.url)
        XCTAssertEqual(linkLocal.endpoint, "[fe80::1]:3000", "what Copy gives")
        let udp = try listener(K.udp(local: "127.0.0.1", port: 5353))
        XCTAssertEqual(udp.proto, "udp")
    }

    /// A pill's Free… names the process the census listed by its pid and
    /// start (`identity`, checked again by `ProcessSignals` at the button);
    /// a container's port has none — its owner stops it.
    func testAPillsPortCarriesItsHoldersIdentity() throws {
        typealias K = FakeActivityKernel
        let port = try listener(K.tcp(local: "127.0.0.1", port: 3000))
        XCTAssertEqual(port.identity?.pid, 4242)
        XCTAssertNotNil(port.identity?.start)
        let container = ListeningPort(pid: 0, process: "web", port: 8080, address: "*", container: "acme-web-1")
        XCTAssertNil(container.identity, "a container's is its owner's to stop")
    }

    /// A container's published port is reached where it is published, as
    /// Docker's own pills are.
    func testAPublishedPortIsReachedWhereItIsPublished() {
        XCTAssertEqual(ListeningPorts.published(hostIP: nil).host, "localhost")
        XCTAssertEqual(ListeningPorts.published(hostIP: nil).scope, .network)
        XCTAssertEqual(ListeningPorts.published(hostIP: "127.0.0.1").host, "127.0.0.1")
        XCTAssertEqual(ListeningPorts.published(hostIP: "127.0.0.1").scope, .thisMac)
        XCTAssertEqual(ListeningPorts.published(hostIP: "::1").host, "[::1]")
        XCTAssertEqual(ListeningPorts.published(hostIP: "192.0.2.10").scope, .oneAddress)
    }

    /// What Docker's own bind would run into: a listener on loopback (no
    /// firewall prompt), and nothing once it has closed — TIME_WAIT aside.
    /// A port the system gave, listened on and closed again: free.
    private static func closedPortIsFree() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 1)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        close(fd)
        return !ListeningPorts.isBound(Int(UInt16(bigEndian: address.sin_port)))
    }

    /// A socket bound to one of this Mac's own addresses, not loopback: met
    /// only by binding that address (6.8) — the wildcard and loopback
    /// probes alone answered "free". It is bound and never listens, so no
    /// firewall asks; the address goes into no message.
    func testASocketOnOneOfThisMacsAddressesIsMet() throws {
        guard let own = ListeningPorts.interfaceAddresses().first(where: { $0.family == AF_INET }) else {
            throw XCTSkip("no IPv4 address but loopback on this Mac")
        }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        XCTAssertEqual(inet_pton(AF_INET, own.address, &address.sin_addr), 1)
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) } }, 0)
        var length = size
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        let port = Int(UInt16(bigEndian: address.sin_port))
        XCTAssertTrue(ListeningPorts.isBound(port), "met binding that address")
        XCTAssertFalse(
            ListeningPorts.isBound(port, probing: Array(ListeningPorts.probeAddresses().prefix(4))), "the wildcard and loopback alone never met it")
        XCTAssertTrue(ListeningPorts.probeAddresses().prefix(4).map(\.address) == ["0.0.0.0", "127.0.0.1", "::", "::1"])
        XCTAssertEqual(Set(ListeningPorts.probeAddresses()).count, ListeningPorts.probeAddresses().count, "each address once")
    }

    func testAPortInUseIsBound() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        let port = Int(UInt16(bigEndian: address.sin_port))
        XCTAssertTrue(ListeningPorts.isBound(port), "\(port) is listened on")
        XCTAssertFalse(ListeningPorts.isBound(port, proto: "udp"), "TCP's only")
        close(fd)
        // Closed, it is free — unless another process's outgoing connection
        // took the same ephemeral port at once, as a busy machine's can:
        // a fresh one is asked about then, a few times at most.
        XCTAssertTrue(
            ListeningPorts.isBound(port) == false || (0..<5).contains { _ in Self.closedPortIsFree() }, "closed, a port is free")
        XCTAssertFalse(ListeningPorts.isBound(0))
    }

    // MARK: Who holds a port (7.6)

    /// A fake Mac's census, read in full: the user's processes with their
    /// sockets, another user's named only.
    private func census(_ kernel: FakeActivityKernel) throws -> ActivitySnapshot {
        try XCTUnwrap(ActivitySampler(kernel: kernel).tickNow(ActivityDemand(.full), context: ActivityContext(appPID: 1000)))
    }

    private func add(_ pid: pid_t, uid: uid_t = 501, name: String, sockets: [socket_fdinfo], to kernel: FakeActivityKernel) {
        var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: pid, start: UInt64(pid) * 1_000, parent: 1, uid: uid, name: name))
        process.name = name
        process.path = "/opt/acme/bin/\(name)"
        process.usage = FakeActivityKernel.usage()
        process.arguments = FakeActivityKernel.arguments(executable: "/opt/acme/bin/\(name)", [name])
        process.descriptors = sockets.indices.map { FakeActivityKernel.descriptor(Int32($0 + 3)) }
        process.sockets = Dictionary(uniqueKeysWithValues: sockets.enumerated().map { (Int32($0 + 3), $1) })
        kernel.add(process)
    }

    /// Who holds a port is the census's, no lsof: the oldest of the user's
    /// processes listening there, its sockets on it one entry; a UDP socket
    /// on the number isn't a TCP holder, nor a connection from that port;
    /// another user's is never named — its sockets aren't the user's to read.
    func testTheHolderOfAPortIsTheCensuss() throws {
        typealias K = FakeActivityKernel
        let kernel = FakeActivityKernel(uid: 501)
        add(1, uid: 0, name: "launchd", sockets: [], to: kernel)
        add(1000, name: "Overterm", sockets: [], to: kernel)
        add(2000, name: "acme-dns", sockets: [K.udp(local: "127.0.0.1", port: 3000)], to: kernel)
        add(2100, name: "acme-client", sockets: [K.tcp(local: "127.0.0.1", port: 3000, remote: "127.0.0.1", remotePort: 49_200, state: .established)], to: kernel)
        add(2200, name: "acme-web", sockets: [K.tcp(local: "127.0.0.1", port: 3000), K.tcp(local: "::1", port: 3000, handle: 2)], to: kernel)
        add(2300, name: "acme-web-2", sockets: [K.tcp(local: "0.0.0.0", port: 3000, handle: 3)], to: kernel)
        add(400, uid: 0, name: "acme-daemon", sockets: [K.tcp(local: "0.0.0.0", port: 8021)], to: kernel)
        let snapshot = try census(kernel)
        let holder = try XCTUnwrap(ListeningPorts.holder(of: 3000, in: snapshot))
        XCTAssertEqual(holder.identity, ActivityProcessID(pid: 2200, start: 2_200_000), "the oldest listener")
        XCTAssertEqual(holder.process, "acme-web")
        XCTAssertEqual(holder.families, [.v4, .v6])
        XCTAssertEqual(holder.url?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(ListeningPorts.holder(of: 3000, proto: "udp", in: snapshot)?.identity, ActivityProcessID(pid: 2000, start: 2_000_000))
        XCTAssertNil(ListeningPorts.holder(of: 8021, in: snapshot), "root's: nettop's to say (stage 4)")
        XCTAssertNil(ListeningPorts.holder(of: 3001, in: snapshot))
    }

    /// A TCP listener on 127.0.0.1 handed to a child of the test's: the
    /// census's socket walk names the child, with its identity, as the
    /// holder — and its URL avoids the ::1 trap. Only the child is read
    /// (in focus), and nothing of any other process goes into an assertion.
    func testARealChildIsItsListenersHolder() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) } }, 0)
        XCTAssertEqual(listen(fd, 4), 0)
        var length = size
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        let port = Int(UInt16(bigEndian: address.sin_port))
        let child = try TestChild("/bin/sleep", ["60"], descriptors: [fd: fd])
        defer { child.stop() }
        close(fd)
        let snapshot = try XCTUnwrap(ActivitySampler().tickNow(ActivityDemand(.focus([child.identity])), context: ActivityContext()))
        let holder = try XCTUnwrap(ListeningPorts.holder(of: port, in: snapshot), "found by the walk")
        XCTAssertEqual(holder.identity, child.identity)
        XCTAssertEqual(holder.families, .v4)
        XCTAssertEqual(holder.scope, .thisMac)
        XCTAssertEqual(holder.url?.absoluteString, "http://127.0.0.1:\(port)")
        XCTAssertEqual(ListeningPorts.of([child.identity], in: snapshot).map(\.port), [port])
    }
}
