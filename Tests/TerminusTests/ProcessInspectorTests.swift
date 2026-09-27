import XCTest

@testable import Terminus

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
        XCTAssertTrue(found.contains { $0.command.contains("time.sleep(20)") }, found.map(\.command).joined(separator: " | "))
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
        for part in ["/bin/zsh", "", "", "-zsh", "-l", "HOME=/Users/b", "TERMINUS_TAB_ID=abc", "", "ptr_munge="] {
            bytes += Array(part.utf8) + [0]
        }
        let parsed = ProcessInspector.parseProcArgs(bytes)
        XCTAssertEqual(parsed?.arguments, ["-zsh", "-l"])
        XCTAssertEqual(parsed?.environment["TERMINUS_TAB_ID"], "abc")
        XCTAssertNil(parsed?.environment["ptr_munge"], "apple strings after the environment are not env")
    }

    func testAssembleNestsChildren() {
        func node(_ pid: pid_t, _ parent: pid_t) -> ProcessNode {
            ProcessNode(pid: pid, parent: parent, name: "p\(pid)", command: "", cpuPercent: 1, memory: 10, workingDirectory: nil)
        }
        let roots = ProcessInspector.assemble([10: node(10, 1), 11: node(11, 10), 12: node(12, 11), 20: node(20, 99)])
        XCTAssertEqual(roots.map(\.pid), [10, 20])
        XCTAssertEqual(roots[0].flattened.map(\.pid), [10, 11, 12])
        XCTAssertEqual(roots[0].totalMemory, 30)
    }
}
