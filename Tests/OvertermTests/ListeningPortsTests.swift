import XCTest

@testable import Overterm

final class ListeningPortsTests: XCTestCase {
    func testParse() {
        let output = "p501\ncnode\nn*:5173\nn[::1]:5173\np777\ncpython3\nn127.0.0.1:8000\n"
        let ports = ListeningPorts.parse(output)
        XCTAssertEqual(ports.map(\.port), [5173, 8000])
        XCTAssertEqual(ports.map(\.process), ["node", "python3"])
        XCTAssertEqual(ports.first?.address, "*")
        XCTAssertEqual(ports.first?.url?.absoluteString, "http://localhost:5173")
    }

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

    func testFindsARealListener() async throws {
        // A server on an OS-chosen port; it prints the port, then waits.
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", "import socket,time\ns=socket.socket();s.bind(('127.0.0.1',0));s.listen();print(s.getsockname()[1],flush=True);time.sleep(20)"]
        let out = Pipe()
        server.standardOutput = out
        try server.run()
        defer { server.terminate() }
        let line = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let port = try XCTUnwrap(Int(line), "server printed \(line)")

        // /usr/bin/python3 is a shim; the listener is its child. Ask for both.
        let pids = ProcessInspector().tree(root: server.processIdentifier, tag: nil).flatMap(\.flattened).map(\.pid) + [server.processIdentifier]
        let ports = await ListeningPorts.of(pids)
        XCTAssertTrue(ports.contains { $0.port == port }, "found \(ports.map(\.port))")
    }
}
