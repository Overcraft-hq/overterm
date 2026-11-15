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
        let found = inspector.tree(root: nil, tag: tag, commands: true).flatMap(\.flattened)
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

    /// What a test started, by pid and start time, children after their
    /// parents: tearDown ends exactly these, each only while its pid is
    /// still that process.
    private var started: [(pid: pid_t, start: UInt64)] = []
    private var roots: [Process] = []

    override func tearDown() {
        for process in started.reversed() where ProcessInspector.kinfo(process.pid)?.start == process.start {
            kill(process.pid, SIGKILL)
        }
        roots.forEach { $0.waitUntilExit() }
        started = []
        roots = []
        super.tearDown()
    }

    /// A shell standing for a pane's `login`, and its one child: a subshell
    /// spinning on builtins for 20 s at most, so a crash or ⌃C can't leave
    /// it burning a core.
    private func busyRoot() throws -> (root: pid_t, busy: pid_t) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        // The parenthesised loop is a subshell: a child, which bash waits for.
        p.arguments = ["-c", "(while [ $SECONDS -lt 20 ]; do :; done); true"]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: ProcessInspector.tagVariable)
        p.environment = env
        try p.run()
        started.append((p.processIdentifier, try XCTUnwrap(ProcessInspector.kinfo(p.processIdentifier)?.start)))
        roots.append(p)
        let deadline = Date().addingTimeInterval(5)
        var child = ProcessInspector.children(of: p.processIdentifier).first
        while child == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            child = ProcessInspector.children(of: p.processIdentifier).first
        }
        let busy = try XCTUnwrap(child, "the busy subshell starts")
        started.append((busy.pid, busy.start))
        return (p.processIdentifier, busy.pid)
    }

    /// Tab Info reads a split tab pane by pane, and the window's agent poll
    /// reads with the same inspector. Each read kept only its own tree's
    /// baselines, so reading one root forgot the other's: two busy loops
    /// read in turn read 0% at every round.
    func testRootsReadInTurnAreEachMeasured() throws {
        let panes = try [busyRoot(), busyRoot()]
        let inspector = ProcessInspector()
        // One round as Tab Info's: every root's tree, one after the other.
        func round() -> [Double] {
            panes.map { pane in inspector.tree(root: pane.root, tag: nil).flatMap(\.flattened).first { $0.pid == pane.busy }?.cpuPercent ?? 0 }
        }
        _ = round()  // every process's first sample reads 0
        var readings: [Double] = []
        let deadline = Date().addingTimeInterval(15)
        repeat {
            Thread.sleep(forTimeInterval: 0.25)
            readings = round()
        } while !readings.allSatisfy({ $0 > 10 }) && Date() < deadline
        // Measured at all, not how much: a loaded machine gives a busy loop well under a core.
        XCTAssertTrue(readings.allSatisfy { $0 > 10 }, "each root's busy loop, read in turn: \(readings.map { String(format: "%.1f%%", $0) }.joined(separator: ", "))")
    }

    /// A command is masked as it is read: a shell of the test's own, then
    /// that same process exec'd with argv[0] `claude` (as the CLI's
    /// appears), a fake password and a resumed session as later words.
    /// The exec keeps the pid and the start time, so the line kept from the
    /// first read must not be the second's. What the checks read of argv
    /// is there still — masked, the `-r` after `--fork-session` goes —, and
    /// a read that shows nothing masks nothing.
    func testACommandIsMaskedWhenItIsRead() throws {
        let parts = ["Zq8", "vX2", "mN7", "pL4"]
        let id = "8f2c1e0a-1b2c-4d3e-9f00-aa11bb22cc33"
        // The shell execs once the test has read it as it was started: when
        // a file the test makes is there, 10 s at most.
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-exec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: gate) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        // `; true` keeps the shell, its sleep 20 s at most.
        p.arguments = [
            "-c",
            "while [ ! -e '\(gate.path)' ] && [ $SECONDS -lt 10 ]; do sleep 0.05; done; "
                + "exec -a claude /bin/bash -c 'sleep 20; true' --fork-session -r \(id) --password \(parts.joined())",
        ]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: ProcessInspector.tagVariable)
        p.environment = env
        try p.run()
        let start = try XCTUnwrap(ProcessInspector.kinfo(p.processIdentifier)?.start)
        started.append((p.processIdentifier, start))
        roots.append(p)
        let inspector = ProcessInspector()
        func read(commands: Bool = true) -> ProcessNode? {
            inspector.tree(root: getpid(), tag: nil, commands: commands).flatMap(\.flattened).first { $0.pid == p.processIdentifier }
        }
        var before: ProcessNode?
        let deadline = Date().addingTimeInterval(5)
        repeat {
            before = read()
            if before == nil { Thread.sleep(forTimeInterval: 0.02) }
        } while before == nil && Date() < deadline
        let first = try XCTUnwrap(before, "the shell, before its exec")
        XCTAssertTrue(first.command.hasPrefix("/bin/bash -c "), first.command)
        XCTAssertFalse(parts.contains { first.command.contains($0) }, "no part of the password: \(first.command)")
        XCTAssertNil(first.argvAgent)

        try Data().write(to: gate)
        var after: ProcessNode?
        var child: (pid: pid_t, start: UInt64, name: String)?
        let execDeadline = Date().addingTimeInterval(5)
        repeat {
            after = read().flatMap { $0.argvAgent == .claude ? $0 : nil }
            // Once it has exec'd, its one child is the sleep 20.
            child = after == nil ? nil : ProcessInspector.children(of: p.processIdentifier).first
            if after == nil || child == nil { Thread.sleep(forTimeInterval: 0.02) }
        } while (after == nil || child == nil) && Date() < execDeadline
        if let child { started.append((child.pid, child.start)) }
        let node = try XCTUnwrap(after, "the shell, exec'd as `claude`")
        XCTAssertEqual(ProcessInspector.kinfo(p.processIdentifier)?.start, start, "the same process")
        // The argv it exec'd into, masked again: not the line kept from before.
        XCTAssertTrue(node.command.hasPrefix("claude -c "), node.command)
        XCTAssertTrue(node.command.contains(Secrets.credentialMask), node.command)
        XCTAssertFalse(parts.contains { node.command.contains($0) }, "no part of the password: \(node.command)")
        XCTAssertTrue(TerminalWindowController.isAgent(node))
        XCTAssertEqual(node.resumes, id)

        // A read that only decides (the agent poll, a drop, an image paste):
        // no command, the same answers.
        let bare = try XCTUnwrap(read(commands: false))
        XCTAssertEqual(bare.command, "")
        XCTAssertEqual(bare.argvAgent, .claude)
        XCTAssertEqual(bare.resumes, id)
        XCTAssertTrue(TerminalWindowController.isAgent(bare))
        XCTAssertEqual(AgentOverviewModel.agent(of: bare), .claude)
        XCTAssertEqual(MCPAsker.agentName(bare), "Claude")
    }

    private let second: UInt64 = 1_000_000_000

    /// A pid the system hands to another process: its first reading is 0,
    /// as any process's is — never a rate made of the old one's CPU time.
    func testAReusedPIDReadsZeroNotABorrowedRate() {
        var cpu = ProcessInspector.CPUBaselines()
        XCTAssertEqual(cpu.percent(pid: 4242, start: 100, cpu: 0, at: 10 * second), 0, "a first sample")
        XCTAssertEqual(cpu.percent(pid: 4242, start: 100, cpu: second / 2, at: 11 * second), 50, accuracy: 0.001)
        // It ends; one started later has its pid, and CPU time of its own.
        XCTAssertEqual(cpu.percent(pid: 4242, start: 300, cpu: second * 3 / 4, at: 12 * second), 0, "not 25% borrowed from the one before")
        XCTAssertEqual(cpu.percent(pid: 4242, start: 300, cpu: second, at: 13 * second), 25, accuracy: 0.001, "then its own rate")
        XCTAssertEqual(cpu.count, 1)
    }

    /// Another caller's read (a split tab's other pane, the agent poll)
    /// keeps a process's baseline: only its end, or its pid reused, drops it.
    func testABaselineIsForgottenOnlyWhenItsProcessEnds() {
        var cpu = ProcessInspector.CPUBaselines()
        for pid: pid_t in [10, 11, 12] { _ = cpu.percent(pid: pid, start: 1, cpu: 0, at: second) }
        // 10 runs on, 11 ended, and 12 is another process's pid now.
        cpu.forgetEnded { [10: 1, 12: 2][$0] }
        XCTAssertEqual(cpu.count, 1)
        XCTAssertEqual(cpu.percent(pid: 10, start: 1, cpu: second / 4, at: 2 * second), 25, accuracy: 0.001, "kept: its rate since its own last sample")
        XCTAssertEqual(cpu.percent(pid: 12, start: 2, cpu: second, at: 2 * second), 0, "the newcomer's first sample")
    }

    /// A baseline lives as long as its process: read again after a long
    /// gap, a reading starts again rather than show the gap's average.
    func testARateSpansAtMostTheLongestInterval() {
        var cpu = ProcessInspector.CPUBaselines()
        let longest = ProcessInspector.CPUBaselines.longestInterval
        _ = cpu.percent(pid: 7, start: 1, cpu: 0, at: second)
        XCTAssertEqual(cpu.percent(pid: 7, start: 1, cpu: second, at: second + longest), 100 * Double(second) / Double(longest), accuracy: 0.001, "within it, the rate")
        XCTAssertEqual(cpu.percent(pid: 7, start: 1, cpu: 2 * second, at: 2 * second + 2 * longest), 0, "past it, a first sample again")
        XCTAssertEqual(cpu.percent(pid: 7, start: 1, cpu: 3 * second, at: 3 * second + 2 * longest), 100, accuracy: 0.001, "then the rate")
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
            ProcessNode(pid: pid, parent: parent, name: "p\(pid)", arguments: [], cpuPercent: 1, memory: 10, workingDirectory: nil)
        }
        let roots = ProcessInspector.assemble([10: node(10, 1), 11: node(11, 10), 12: node(12, 11), 20: node(20, 99)])
        XCTAssertEqual(roots.map(\.pid), [10, 20])
        XCTAssertEqual(roots[0].flattened.map(\.pid), [10, 11, 12])
        XCTAssertEqual(roots[0].totalMemory, 30)
    }
}
