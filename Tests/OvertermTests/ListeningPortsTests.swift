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
