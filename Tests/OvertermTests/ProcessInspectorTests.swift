import XCTest

@testable import Overterm

final class ProcessInspectorTests: XCTestCase {
    private func spawn(_ script: String, tag: String?) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // "; true" keeps sh alive as the parent instead of exec'ing sleep.
        p.arguments = ["-c", script + "; true"]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: ProcessInspector.tagVariable)
        if let tag { env[ProcessInspector.tagVariable] = tag }
        p.environment = env
        try p.run()
        return p
    }

    /// The main path: a tab is everything under its login.
    func testDescendantsOfTheRoot() throws {
        let mine = try spawn("sleep 20", tag: nil)
        Thread.sleep(forTimeInterval: 0.3)
        let inspector = ProcessInspector()
        // This test process plays the part of `login`.
        let roots = inspector.tree(root: getpid(), tag: nil)
        defer {
            roots.flatMap(\.flattened).filter { $0.name == "sleep" }.forEach { kill($0.pid, SIGTERM) }
            mine.terminate()
        }
        let sh = try XCTUnwrap(roots.first { $0.pid == mine.processIdentifier }, "the child is a root under us")
        XCTAssertEqual(sh.children.map(\.name), ["sleep"])
        XCTAssertFalse(roots.contains { $0.pid == getpid() }, "the root itself is not listed")
    }

    /// The fallback: a process that left the tab's tree (nohup, disown) is
    /// still the tab's if its environment carries the tag — visible for
    /// non-Apple binaries like a python or node dev server.
    func testFindsADaemonizedProcessByItsTag() throws {
        let tag = "test-\(UUID().uuidString)"
        func python(tag: String?) throws -> Process {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = ["-c", "import time; time.sleep(20)"]
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: ProcessInspector.tagVariable)
            if let tag { env[ProcessInspector.tagVariable] = tag }
            p.environment = env
            try p.run()
            return p
        }
        let mine = try python(tag: tag)
        let other = try python(tag: nil)
        Thread.sleep(forTimeInterval: 1.0)
        let inspector = ProcessInspector()
        // No root: found by tag alone.
        let found = inspector.tree(root: nil, tag: tag).flatMap(\.flattened)
        defer {
            found.forEach { kill($0.pid, SIGTERM) }
            [mine, other].forEach { $0.terminate() }
        }
        XCTAssertTrue(found.contains { $0.maskedCommand.contains("time.sleep(20)") }, found.map(\.maskedCommand).joined(separator: " | "))
        XCTAssertFalse(found.contains { $0.pid == other.processIdentifier }, "untagged processes are not the tab's")
        XCTAssertGreaterThan(found.first?.totalMemory ?? 0, 0)
    }

    func testCPUIsMeasuredBetweenSamples() throws {
        let tag = "test-\(UUID().uuidString)"
        let busy = try spawn("while :; do :; done", tag: tag)
        defer {
            kill(busy.processIdentifier, SIGKILL)
        }
        let inspector = ProcessInspector()
        _ = inspector.tree(root: getpid(), tag: nil)
        Thread.sleep(forTimeInterval: 0.5)
        let cpu = inspector.tree(root: getpid(), tag: nil).first { $0.pid == busy.processIdentifier }?.totalCPU ?? 0
        // Measured at all, not how much: a busy loop gets well under a core
        // on a loaded machine (41% at load 10), an idle process reads ~0.
        XCTAssertGreaterThan(cpu, 10, "a busy loop's CPU shows between two samples")
    }

    func testParseProcArgs() {
        var bytes: [UInt8] = []
        var argc = Int32(2)
        withUnsafeBytes(of: &argc) { bytes += $0 }
        for part in ["/bin/zsh", "", "", "-zsh", "-l", "HOME=/Users/b", "OVERTERM_TAB_ID=abc", "", "ptr_munge="] {
            bytes += Array(part.utf8) + [0]
        }
        let parsed = ProcessInspector.parseProcArgs(bytes)
        XCTAssertEqual(parsed?.arguments, ["-zsh", "-l"])
        XCTAssertEqual(parsed?.environment["OVERTERM_TAB_ID"], "abc")
        XCTAssertNil(parsed?.environment["ptr_munge"], "apple strings after the environment are not env")
    }

    func testAssembleNestsChildren() {
        func node(_ pid: pid_t, _ parent: pid_t) -> ProcessNode {
            ProcessNode(identity: ActivityProcessID(pid: pid, start: UInt64(pid)), parent: parent, name: "p\(pid)", maskedCommand: "", cpuPercent: 1, memory: 10, workingDirectory: nil)
        }
        let roots = ProcessInspector.assemble([10: node(10, 1), 11: node(11, 10), 12: node(12, 11), 20: node(20, 99)])
        XCTAssertEqual(roots.map(\.pid), [10, 20])
        XCTAssertEqual(roots[0].flattened.map(\.pid), [10, 11, 12])
        XCTAssertEqual(roots[0].totalMemory, 30)
    }

    /// A pid comes round again within hours (docs/design/activity/
    /// analysis.md, 2.4 item 10): whatever holds it next is another row,
    /// its id not the old one's, so it inherits no selection and no menu
    /// target — and a child hangs under the node holding its parent's pid
    /// only when that one started no later: the old holder's children
    /// never join the new one.
    func testAReusedPidInheritsNothing() {
        func node(_ pid: pid_t, start: UInt64, parent: pid_t) -> ProcessNode {
            ProcessNode(
                identity: ActivityProcessID(pid: pid, start: start), parent: parent, name: "p\(pid)", maskedCommand: "", cpuPercent: 0, memory: 0,
                workingDirectory: nil)
        }
        let earlier = node(40, start: 100, parent: 1)
        let later = node(40, start: 900, parent: 1)
        XCTAssertEqual(earlier.id, "40:100")
        XCTAssertNotEqual(earlier.id, later.id, "the same pid, another process")
        // 41 started under the old holder of 40, before the new one began.
        let roots = ProcessInspector.assemble([40: later, 41: node(41, start: 500, parent: 40), 42: node(42, start: 950, parent: 40)])
        XCTAssertEqual(roots.map(\.id), ["41:500", "40:900"], "the old holder's child is a root, oldest first")
        XCTAssertEqual(roots.first { $0.pid == 40 }?.children.map(\.id), ["42:950"])
    }

    /// A command is masked as it is read (2.4 item 8, 9.3): Tab Info's
    /// tooltip showed the raw argv, a password on the command line among
    /// it. A child of the test's carries an invented one in a secret flag;
    /// its node and its tooltip say the flag, never the value, and the
    /// rest of the line stays as it was. Its footprint, what Activity
    /// Monitor calls Memory, is measured.
    func testACommandIsMaskedAsItIsReadAndItsFootprintMeasured() throws {
        // Invented, and made at run time: no token-shaped string in the source.
        let planted = ["acme", "sentinel", String(4_242)].joined(separator: "-")
        let child = try TestChild("/bin/sh", ["-c", "sleep 30; true", "acme-worker", "--password=\(planted)"], environment: TestChild.cleanEnvironment)
        defer { child.stop() }
        let inspector = ProcessInspector()
        var node: ProcessNode?
        XCTAssertTrue(
            TestChild.eventually {
                node = inspector.tree(root: getpid(), tag: nil).flatMap(\.flattened).first { $0.identity == child.identity }
                return node?.maskedCommand.contains("acme-worker") == true
            }, "the child is read")
        let found = try XCTUnwrap(node)
        XCTAssertTrue(found.maskedCommand.contains("--password=\(Secrets.credentialMask)"), "the flag is said, its value masked")
        XCTAssertFalse(found.maskedCommand.contains(planted), "never the value")
        XCTAssertTrue(found.maskedCommand.hasPrefix("/bin/sh -c sleep 30; true acme-worker"), "the rest as it was")
        let help = TabInfoView.help(for: found)
        XCTAssertFalse(help.contains(planted), "nor in the tooltip")
        XCTAssertTrue(help.contains("acme-worker"))
        XCTAssertGreaterThan(found.footprint, 0, "its footprint is measured")
        XCTAssertGreaterThan(found.memory, 0, "and its real memory")
    }
}
