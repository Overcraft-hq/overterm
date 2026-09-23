import XCTest

@testable import Terminus

final class ListeningPortsTests: XCTestCase {
    func testParse() {
        let output = "p501\ncnode\nn*:5173\nn[::1]:5173\np777\ncpython3\nn127.0.0.1:8000\n"
        let ports = ListeningPorts.parse(output)
        XCTAssertEqual(ports.map(\.port), [5173, 8000])
        XCTAssertEqual(ports.map(\.process), ["node", "python3"])
        XCTAssertEqual(ports.first?.address, "*")
        XCTAssertEqual(ports.first?.url?.absoluteString, "http://localhost:5173")
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
