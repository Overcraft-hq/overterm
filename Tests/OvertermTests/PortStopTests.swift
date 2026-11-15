import XCTest

@testable import Overterm

/// A pane pill's Stop… (`PortStop`): whether the process listed may be
/// sent SIGTERM, from what is read just before — and, on a listener of the
/// test's own, that it alone is, and only while it is still the one
/// listed, holding its port.
final class PortStopTests: XCTestCase {
    private let started: UInt64 = 1_763_000_000_123_456

    func testTheSameProcessStillHoldingThePortMayBeSignalled() {
        XCTAssertEqual(PortStop.check(pid: 4242, listed: started, now: started, listens: true), .same)
    }

    func testOneThatExitedIsNot() {
        XCTAssertEqual(PortStop.check(pid: 4242, listed: started, now: nil, listens: false), .exited)
    }

    /// Another process has its pid: whatever it listens on, it is another's.
    func testItsPidReusedWithAnotherStartIsNot() {
        XCTAssertEqual(PortStop.check(pid: 4242, listed: started, now: started + 1, listens: true), .reused)
        XCTAssertEqual(PortStop.check(pid: 4242, listed: started, now: started - 1, listens: false), .reused)
    }

    func testOneNoLongerListeningIsNot() {
        XCTAssertEqual(PortStop.check(pid: 4242, listed: started, now: started, listens: false), .notListening)
    }

    /// Nothing tells it from a process that took its pid since.
    func testOneWhoseStartCouldNotBeReadIsNot() {
        XCTAssertEqual(PortStop.check(pid: 4242, listed: nil, now: started, listens: true), .unidentified)
        XCTAssertEqual(PortStop.check(pid: 4242, listed: nil, now: nil, listens: false), .unidentified)
    }

    /// A group (0, a negative pid), launchd, Overterm itself: never, whatever was read.
    func testAGroupLaunchdOrItselfIsNever() async {
        for pid in [0, -1, -4242, 1, getpid()] as [pid_t] {
            XCTAssertEqual(PortStop.check(pid: pid, listed: started, now: started, listens: true), .unidentified, "pid \(pid)")
            let opening = await PortStop.opening(ListeningPort(pid: pid, start: started, process: "acme-web", port: 3000, address: "*"))
            XCTAssertEqual(opening.check, .unidentified, "pid \(pid)")
            XCTAssertNil(opening.command)
        }
    }

    @MainActor func testTheQuestionNamesTheProcessItsPidThePortAndSIGTERM() {
        let port = ListeningPort(pid: 4242, start: started, process: "acme-web", port: 3000, address: "127.0.0.1")
        let asked = PortStop.confirmation(for: port, command: "acme-web serve --port 3000")
        XCTAssertEqual(asked.title, "Stop “acme-web” (pid 4242)?")
        XCTAssertEqual(asked.button, "Stop Process")
        XCTAssertNil(asked.typedName)
        for words in [":3000", "acme-web serve --port 3000", "SIGTERM", "kill -TERM 4242"] {
            XCTAssertTrue(asked.detail.contains(words), words)
        }
        // Every character visible: a name can't hide behind a direction override.
        let hiding = ListeningPort(pid: 4242, start: started, process: "acme\u{202E}bew", port: 3000, address: "*")
        XCTAssertEqual(PortStop.confirmation(for: hiding, command: nil).title, "Stop “acme\\u{202E}bew” (pid 4242)?")
    }

    @MainActor func testEachRefusalSaysWhyNothingWasSent() {
        let port = ListeningPort(pid: 4242, start: started, process: "acme-web", port: 3000, address: "*")
        XCTAssertNil(PortStop.refusal(.sent, port: port))
        XCTAssertEqual(PortStop.refusal(.refused(.exited), port: port)?.title, "“acme-web” has exited")
        // Its pid unreadable may be another user's process, or root's, now:
        // only what is known is said.
        XCTAssertEqual(PortStop.refusal(.refused(.exited), port: port)?.detail, "Nothing was sent: no process of yours has pid 4242 any more.")
        XCTAssertEqual(PortStop.refusal(.refused(.reused), port: port)?.title, "“acme-web” has exited")
        XCTAssertEqual(PortStop.refusal(.refused(.notListening), port: port)?.title, "“acme-web” no longer holds :3000")
        XCTAssertEqual(PortStop.refusal(.refused(.unidentified), port: port)?.title, "“acme-web” can't be stopped from here")
        for check in [PortStop.Check.exited, .reused, .notListening, .unidentified] {
            XCTAssertEqual(PortStop.refusal(.refused(check), port: port)?.detail.hasPrefix("Nothing was sent: "), true, "\(check)")
        }
        XCTAssertEqual(PortStop.refusal(.failed(EPERM), port: port)?.detail.hasPrefix("SIGTERM to pid 4242 failed: "), true)
    }

    /// Listens on 127.0.0.1 — the port its second argument asks, 0 for any
    /// —, writes the port to the file its first names, then sleeps 30 s at
    /// most. Its other arguments are only words on its command line.
    private static let listener = """
        use Socket;
        my ($file, $want) = @ARGV;
        socket(my $s, PF_INET, SOCK_STREAM, 0) or die;
        setsockopt($s, SOL_SOCKET, SO_REUSEADDR, 1);
        bind($s, sockaddr_in($want, inet_aton("127.0.0.1"))) or die;
        listen($s, 5) or die;
        my ($port) = sockaddr_in(getsockname($s));
        open(my $f, ">", "$file.tmp") or die; print $f "$port\\n"; close $f; rename("$file.tmp", $file);
        sleep 30;
        """

    /// A real listener of the test's own: listed with its start time, asked
    /// about with its line masked, sent nothing while the listing is stale,
    /// and SIGTERM — it alone — once it is still the one listed.
    func testOnlyTheListenerStillListedHoldingItsPortIsSent() async throws {
        // A fake password, made here from parts: a word of its command line.
        let password = ["Qw7", "rT2", "zX9", "mK4"].joined()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-port-stop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        server.arguments = ["-e", Self.listener, file.path, "0", "acme-server", "--password", password]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        let pid = server.processIdentifier
        let start = try XCTUnwrap(ListeningPorts.start(of: pid), "its start time")
        // Left running by a failure: it alone, by its pid and start time.
        defer { if ListeningPorts.start(of: pid) == start { kill(pid, SIGTERM) } }
        var port = 0
        try await until("it listens") {
            port = (try? String(contentsOf: file, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
            return port > 0 || !server.isRunning
        }
        XCTAssertGreaterThan(port, 0, "it listens")

        // Listed with its start time, read with the listing.
        let ports = await ListeningPorts.of([pid])
        let listed = try XCTUnwrap(ports.first { $0.port == port }, "\(ports.count) ports listed")
        XCTAssertEqual(listed.start, start)

        // The question opens on it, its line masked.
        let opening = await PortStop.opening(listed)
        XCTAssertEqual(opening.check, .same)
        let command = try XCTUnwrap(opening.command)
        XCTAssertTrue(command.contains("acme-server"), "its own words")
        XCTAssertTrue(command.contains(Secrets.credentialMask), "the password masked")
        XCTAssertFalse(command.contains(password), "the password nowhere")

        // A listing gone stale is sent nothing: its pid another process's,
        // a port it doesn't hold, a start time never read.
        var reused = listed
        reused.start = start + 1
        let other = ListeningPort(pid: pid, start: start, process: listed.process, port: port == 65535 ? port - 1 : port + 1, address: listed.address)
        var unread = listed
        unread.start = nil
        let listings: [(ListeningPort, PortStop.Check)] = [(reused, .reused), (other, .notListening), (unread, .unidentified)]
        for (stale, refused) in listings {
            let outcome = await PortStop.signal(stale)
            XCTAssertEqual(outcome, .refused(refused))
            let opened = await PortStop.opening(stale)
            XCTAssertEqual(opened.check, refused)
            XCTAssertNil(opened.command, "no line under another's name")
        }
        XCTAssertTrue(server.isRunning, "nothing was sent")
        XCTAssertEqual(ListeningPorts.start(of: pid), start)

        // Still the one listed, holding its port: SIGTERM, and it ends.
        let outcome = await PortStop.signal(listed)
        XCTAssertEqual(outcome, .sent)
        try await until("it ends") { !server.isRunning }
        XCTAssertEqual(server.terminationReason, .uncaughtSignal)
        XCTAssertEqual(server.terminationStatus, SIGTERM)
        // Gone, it is sent nothing again.
        let again = await PortStop.signal(listed)
        XCTAssertTrue(again == .refused(.exited) || again == .refused(.reused), "\(again)")
    }

    private func until(_ what: String, _ timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
