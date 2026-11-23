import Darwin
import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell
@testable import OvertermOvergit
@testable import OvertermAPI
@testable import OvertermNotes
@testable import OvertermSimulator
@testable import OvertermUsage
@testable import OvertermSettingsPage
@testable import OvertermAgents
@testable import OvertermActivity
@testable import OvertermE2E

/// A tab's processes, looked up in the census (docs/design/activity/
/// analysis.md, 7.8): over a fake Mac, a split tab's two panes read in
/// turn both reading their CPU, no new scan while a snapshot is a tick
/// old, a tag alone, an agent's folder at once; then the test's own
/// children through the real kernel, each through a census of its own —
/// the app's would answer from another test's tick a moment ago.
final class ProcessInspectorTests: XCTestCase {
    private let kernel = FakeActivityKernel(uid: 501)
    private let second: UInt64 = 1_000_000_000
    private let app: pid_t = 1000

    // MARK: A fake Mac

    @discardableResult
    private func add(
        _ pid: pid_t, parent: pid_t, uid: uid_t = 501, name: String, words: [String]? = nil, environment: [String] = [], folder: String? = nil
    ) -> ActivityProcessID {
        let start = UInt64(pid) * 1_000
        let path = "/opt/acme/bin/\(name)"
        var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: pid, start: start, parent: parent, uid: uid, name: name))
        process.name = name
        process.path = path
        process.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid)
        process.usage = FakeActivityKernel.usage(footprint: 6 << 20)
        process.arguments = FakeActivityKernel.arguments(executable: path, words ?? [name], environment: environment)
        process.folder = folder
        kernel.add(process)
        return ActivityProcessID(pid: pid, start: start)
    }

    private func burn(_ pid: pid_t, _ cpu: UInt64) {
        kernel.update(pid) { process in
            process.usage = FakeActivityKernel.usage(cpuTime: (process.usage?.cpuTime ?? 0) + cpu, footprint: 6 << 20)
        }
    }

    /// The app, and a pane: its root-owned `login` under the app, a shell under that.
    private func pane(_ tag: String, login: pid_t, tab: UUID) -> ActivityContext.Pane {
        let identity = add(login, parent: app, uid: 0, name: "login")
        add(login + 1, parent: login, name: "zsh")
        return ActivityContext.Pane(tag: tag, tab: tab, login: identity)
    }

    private func census(_ panes: [ActivityContext.Pane]) -> ActivitySampler {
        add(1, parent: 0, uid: 0, name: "launchd")
        add(app, parent: 1, name: "Overterm")
        let sampler = ActivitySampler(kernel: kernel)
        sampler.appContext = ActivityContext(panes: panes, appPID: app)
        return sampler
    }

    /// The split-tab regression (2.4 item 1): a split tab's two panes asked
    /// for in turn, as Tab Info and the poll asked, pane by pane — the old
    /// scan kept only the tree it had just read's baselines, so each pane
    /// evicted the other's and both read 0%. One tick reads both panes, and
    /// each process's baseline lives as long as it does: both read their
    /// busy child's CPU.
    func testASplitTabsPanesReadInTurnBothReadTheirCPU() throws {
        let tab = UUID()
        let left = pane("pane-a", login: 1100, tab: tab)
        let right = pane("pane-b", login: 1200, tab: tab)
        let busyLeft = add(1102, parent: 1101, name: "node")
        let busyRight = add(1202, parent: 1201, name: "python3")
        let inspector = ProcessInspector(census: census([left, right]))
        var cpu: [pid_t: Double] = [:]
        for round in 0..<6 {
            let (login, tag, busy) = round % 2 == 0 ? (left.login, "pane-a", busyLeft) : (right.login, "pane-b", busyRight)
            let nodes = inspector.tree(root: login?.pid, tag: tag).flatMap(\.flattened)
            cpu[busy.pid] = nodes.first { $0.identity == busy }?.cpuPercent
            kernel.advance(second)
            burn(busyLeft.pid, second)
            burn(busyRight.pid, second)
        }
        XCTAssertEqual(cpu[busyLeft.pid] ?? 0, 100, accuracy: 1e-6, "the left pane's")
        XCTAssertEqual(cpu[busyRight.pid] ?? 0, 100, accuracy: 1e-6, "the right pane's")
    }

    /// A lookup: no new scan while the latest snapshot is a tick old at
    /// most and has the pane — every pane's lookups answered by one tick
    /// (2.4 item 2) — then one, the tree as the table says it now.
    func testNoNewScanWhileTheCensusIsFresh() throws {
        let tab = UUID()
        let left = pane("pane-a", login: 1100, tab: tab)
        let right = pane("pane-b", login: 1200, tab: tab)
        let job = add(1102, parent: 1101, name: "acme-dev", words: ["acme-dev", "--port", "3000"])
        let inspector = ProcessInspector(census: census([left, right]))
        let first = inspector.tree(root: 1100, tag: "pane-a")
        XCTAssertEqual(first.map(\.name), ["zsh"])
        XCTAssertEqual(first.first?.children.map(\.identity), [job])
        XCTAssertEqual(first.first?.children.first?.maskedCommand, "acme-dev --port 3000")
        XCTAssertEqual(first.first?.children.first?.footprint, 6 << 20)
        XCTAssertEqual(kernel.count("processes"), 1)
        _ = inspector.tree(root: 1200, tag: "pane-b")
        _ = ProcessInspector(census: inspector.census).tree(root: 1100, tag: nil)
        XCTAssertEqual(kernel.count("processes"), 1, "one tick answered every pane's")

        let later = add(1103, parent: 1101, name: "acme-test")
        XCTAssertFalse(inspector.tree(root: 1100, tag: "pane-a").flatMap(\.flattened).contains { $0.identity == later }, "a tick old: as it was")
        kernel.advance(2 * second)
        XCTAssertTrue(inspector.tree(root: 1100, tag: "pane-a").flatMap(\.flattened).contains { $0.identity == later }, "then read again")
        XCTAssertEqual(kernel.count("processes"), 2)
    }

    /// A tag alone, or a root no pane has, is read as a pane of its own:
    /// what carries the tag outside every tree with what it started, or the
    /// root's descendants.
    func testATagOrARootNoPaneHas() throws {
        let tab = UUID()
        let left = pane("pane-a", login: 1100, tab: tab)
        let server = add(3000, parent: 1, name: "acme-server", environment: ["OVERTERM_TAB_ID=pane-z"])
        let worker = add(3001, parent: 3000, name: "acme-worker")
        let inspector = ProcessInspector(census: census([left]))
        let tagged = inspector.tree(root: nil, tag: "pane-z")
        XCTAssertEqual(tagged.map(\.identity), [server])
        XCTAssertEqual(tagged.first?.children.map(\.identity), [worker])
        XCTAssertEqual(inspector.tree(root: 3000, tag: nil).map(\.identity), [worker], "a root's descendants, not itself")
        XCTAssertEqual(inspector.tree(root: 9999, tag: nil), [], "gone")
    }

    /// A tree is what the old scan listed (7.8's API kept): the user's
    /// processes, never a zombie — what Suspend Tab stops by pid until its
    /// own step, and what the agent readers look in. A setuid program the
    /// shell runs (root's by its effective uid, the user's by its real one:
    /// `kill(2)` would let a SIGSTOP through, 3.2) is left out, and so is
    /// one that runs as the user for now with root kept as its saved uid,
    /// and a zombie — an agent's, ended, is no agent running. What the
    /// setuid program started as the user is the tab's still. Tab Info,
    /// which signals nothing, names them all.
    func testATreeLeavesOutASetuidProgramAndAZombie() throws {
        let tab = UUID()
        let left = pane("pane-a", login: 1100, tab: tab)
        var setuid = FakeActivityKernel.Process(
            record: FakeActivityKernel.record(pid: 1102, start: 1_102_000, parent: 1101, uid: 0, realUID: 501, name: "sudo"))
        setuid.path = "/usr/bin/sudo"
        kernel.add(setuid)
        let started = add(1103, parent: 1102, name: "acme-tool")
        var dropped = FakeActivityKernel.Process(
            record: FakeActivityKernel.record(pid: 1104, start: 1_104_000, parent: 1101, uid: 501, realUID: 501, savedUID: 0, name: "acme-setuid"))
        dropped.path = "/opt/acme/bin/acme-setuid"
        kernel.add(dropped)
        var zombie = FakeActivityKernel.Process(
            record: FakeActivityKernel.record(pid: 1105, start: 1_105_000, parent: 1101, status: SZOMB, name: "claude"))
        zombie.name = "claude"
        kernel.add(zombie)
        let sampler = census([left])
        let tree = ProcessInspector(census: sampler).tree(root: 1100, tag: "pane-a")
        XCTAssertEqual(tree.flatMap(\.flattened).map(\.pid).sorted(), [1101, 1103], "the shell, and what sudo started as the user")
        XCTAssertTrue(tree.contains { $0.identity == started }, "a root of its own, its parent not listed")
        XCTAssertNil(TerminalWindowController.firstAgent(in: [(1100, "pane-a")]) { _, _ in tree }, "an ended agent isn't running")
        let snapshot = try XCTUnwrap(sampler.latest)
        let slice = try XCTUnwrap(snapshot.pane("pane-a"))
        XCTAssertEqual(TabSuspension.targets(of: slice, in: snapshot).map(\.identity.pid).sorted(), [1101, 1103], "what Suspend Tab would stop")
        let named = ProcessInspector.nodes(slice.tree, in: snapshot)
        XCTAssertEqual(named.flatMap(\.flattened).map(\.pid).sorted(), [1101, 1102, 1103, 1104, 1105], "Tab Info's own nodes name them all")
        XCTAssertNotNil(TerminalWindowController.firstAgent(in: [(1100, "pane-a")]) { _, _ in named }, "the zombie is a claude by its name")
    }

    /// The pane's agent's folder is read at once (the overview, Sessions,
    /// an MCP confirmation and a drop ask for it), though the census reads
    /// folders off its queue and never waits.
    func testAnAgentsFolderIsReadAtOnce() throws {
        let tab = UUID()
        let left = pane("pane-a", login: 1100, tab: tab)
        let agent = add(1102, parent: 1101, name: "claude", folder: "/work/acme/.worktrees/feat")
        let inspector = ProcessInspector(census: census([left]))
        let node = inspector.tree(root: 1100, tag: "pane-a").flatMap(\.flattened).first { $0.identity == agent }
        XCTAssertEqual(node?.workingDirectory, "/work/acme/.worktrees/feat")
    }

    // MARK: Assembly

    func testAssembleNestsChildren() {
        func node(_ pid: pid_t, _ parent: pid_t) -> ProcessNode {
            ProcessNode(
                identity: ActivityProcessID(pid: pid, start: UInt64(pid)), parent: parent, name: "p\(pid)", maskedCommand: "", cpuPercent: 1,
                memory: 10, workingDirectory: nil)
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

    // MARK: The test's own children

    /// A census of the test's own, asked afresh at every call: the
    /// children's trees form as the test waits.
    private func realInspector() -> ProcessInspector {
        ProcessInspector(census: ActivitySampler(kernel: LiveActivityKernel()), freshness: 0)
    }

    /// Ends what `child` started — each found in its tree, its identity
    /// read again before the one SIGKILL — then `child`.
    private func end(_ child: TestChild, _ inspector: ProcessInspector) {
        for node in inspector.tree(root: child.pid, tag: nil).flatMap(\.flattened) where ProcessInspector.kinfo(node.pid)?.start == node.identity.start {
            kill(node.pid, SIGKILL)
        }
        child.stop()
    }

    /// The main path: a tab is everything under its login — the test
    /// process plays its part here.
    func testDescendantsOfTheRoot() throws {
        let child = try TestChild("/bin/sh", ["-c", "sleep 20; true"], environment: TestChild.cleanEnvironment)
        let inspector = realInspector()
        defer { end(child, inspector) }
        var roots: [ProcessNode] = []
        XCTAssertTrue(
            TestChild.eventually {
                roots = inspector.tree(root: getpid(), tag: nil)
                return roots.first { $0.identity == child.identity }?.children.isEmpty == false
            }, "the child and its sleep")
        let sh = try XCTUnwrap(roots.first { $0.identity == child.identity }, "the child is a root under us")
        XCTAssertEqual(sh.children.map(\.name), ["sleep"])
        XCTAssertFalse(roots.contains { $0.pid == getpid() }, "the root itself is not listed")
    }

    /// The fallback: a process that left the tab's tree (nohup, disown) is
    /// still the tab's if its environment carries the tag — visible for
    /// non-Apple binaries like a python or node dev server. Found by its
    /// markers among every process's, read in the one call.
    func testFindsADaemonizedProcessByItsTag() throws {
        let tag = "acme-tag-\(UUID().uuidString)"
        var environment = TestChild.cleanEnvironment
        environment[ProcessInspector.tagVariable] = tag
        let mine = try TestChild("/usr/bin/python3", ["-c", "import time; time.sleep(20)"], environment: environment)
        let other = try TestChild("/usr/bin/python3", ["-c", "import time; time.sleep(21)"], environment: TestChild.cleanEnvironment)
        let inspector = realInspector()
        defer { [mine, other].forEach { end($0, inspector) } }
        var found: [ProcessNode] = []
        XCTAssertTrue(
            TestChild.eventually {
                found = inspector.tree(root: nil, tag: tag).flatMap(\.flattened)
                return found.contains { $0.maskedCommand.contains("time.sleep(20)") }
            }, "the tagged python")
        XCTAssertFalse(found.contains { $0.maskedCommand.contains("time.sleep(21)") || $0.identity == other.identity }, "untagged processes are not the tab's")
        XCTAssertGreaterThan(found.first { $0.maskedCommand.contains("time.sleep(20)") }?.footprint ?? 0, 0)
    }

    /// A busy child's CPU, between two of the census's samples.
    func testCPUIsMeasuredBetweenSamples() throws {
        let busy = try TestChild("/bin/sh", ["-c", "ulimit -c 0; ulimit -t 20; while :; do :; done"], environment: TestChild.cleanEnvironment)
        defer { busy.stop() }
        let inspector = realInspector()
        // Measured at all, not how much: a busy loop gets well under a core
        // on a loaded machine (41% at load 10), an idle process reads ~0.
        XCTAssertTrue(
            TestChild.eventually(30) {
                (inspector.tree(root: getpid(), tag: nil).first { $0.identity == busy.identity }?.cpuPercent ?? 0) > 10
            }, "a busy loop's CPU shows between two samples")
    }

    /// Two roots on one inspector, asked for in turn, both busy: the split
    /// tab's case through the real kernel, each root read as a pane of its
    /// own, neither evicting the other's baselines.
    func testTwoRootsReadInTurnBothReadTheirCPU() throws {
        let script = "(ulimit -c 0; ulimit -t 20; while :; do :; done) & wait"
        let left = try TestChild("/bin/sh", ["-c", script], environment: TestChild.cleanEnvironment)
        let right = try TestChild("/bin/sh", ["-c", script], environment: TestChild.cleanEnvironment)
        let inspector = realInspector()
        defer { [left, right].forEach { end($0, inspector) } }
        var cpu: [pid_t: Double] = [:]
        var turn = 0
        XCTAssertTrue(
            TestChild.eventually(30) {
                let root = turn % 2 == 0 ? left : right
                turn += 1
                cpu[root.pid] = inspector.tree(root: root.pid, tag: nil).first?.cpuPercent ?? 0
                return (cpu[left.pid] ?? 0) > 10 && (cpu[right.pid] ?? 0) > 10
            }, "both read their busy child's CPU")
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
        let inspector = realInspector()
        defer { end(child, inspector) }
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
