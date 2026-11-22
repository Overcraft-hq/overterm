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

/// Suspend Tab over a fake Mac (docs/design/activity/analysis.md, 6.5,
/// 6.10, 10.1): what it stops is the pane's set, its sends go through
/// `ProcessSignals` by identity, and nothing real is ever signalled.
final class TabSuspensionTests: XCTestCase {
    private let tty: dev_t = 0x1000_0007
    private let otherTTY: dev_t = 0x1000_0009
    private let tag = "pane-a"
    private var kernel = FakeActivityKernel(uid: 501)

    override func setUp() {
        super.setUp()
        kernel = FakeActivityKernel(uid: 501)
        add(1, parent: 0, uid: 0, name: "launchd")
        add(1000, parent: 1, name: "Overterm")
        add(1100, parent: 1000, uid: 0, terminal: tty, name: "login")
        add(1101, parent: 1100, terminal: tty, name: "zsh")
    }

    /// A process of the fake Mac; `environment` its own variables, the
    /// pane's tag among them where it carries it.
    @discardableResult
    private func add(
        _ pid: pid_t, parent: pid_t, uid: uid_t = 501, start: UInt64? = nil, terminal: dev_t? = nil, flags: ActivityProcess.Flags = [],
        ignoredSignals: UInt32 = 0, path: String? = nil, name: String, environment: [String] = []
    ) -> ActivityProcessID {
        let start = start ?? UInt64(pid) * 1_000
        var process = FakeActivityKernel.Process(
            record: FakeActivityKernel.record(
                pid: pid, start: start, parent: parent, uid: uid, realUID: uid == 0 ? 501 : nil, terminal: terminal, flags: flags,
                ignoredSignals: ignoredSignals, name: name))
        let executable = path ?? "/opt/acme/bin/\(name)"
        process.name = name
        process.path = executable
        process.arguments = FakeActivityKernel.arguments(executable: executable, [name], environment: environment)
        kernel.add(process)
        return ActivityProcessID(pid: pid, start: start)
    }

    private var tagged: [String] { ["\(ProcessInspector.tagVariable)=\(tag)"] }

    private func census() -> ActivitySampler {
        let census = ActivitySampler(kernel: kernel)
        census.appContext = ActivityContext(
            panes: [ActivityContext.Pane(tag: tag, tab: UUID(), login: ActivityProcessID(pid: 1100, start: 1_100_000))], appPID: 1000)
        return census
    }

    /// The fake Mac's signal path: the gate off, as in the person's app,
    /// this test's process standing nowhere in it.
    private var signals: ProcessSignals {
        ProcessSignals(kernel: kernel, gate: ActivitySignalGate(guards: false), app: ActivityProcessID(pid: 1000, start: 1_000_000), helperGroups: { [] })
    }

    private func targets(checkouts: [String] = []) -> [ActivitySignalTarget] {
        TabSuspension.targets(login: 1100, tag: tag, checkouts: checkouts, census: census())
    }

    /// The shell before what it runs: stopped the other way round, it
    /// would see its job stop and take the terminal back. Continued
    /// children first, the shell last.
    func testTheShellStopsFirstAndContinuesLast() {
        add(1102, parent: 1101, terminal: tty, name: "acme-job")
        add(1103, parent: 1102, terminal: tty, name: "acme-worker")
        add(1104, parent: 1101, terminal: tty, name: "acme-other")
        let targets = targets()
        XCTAssertEqual(targets.map(\.identity.pid), [1101, 1102, 1103, 1104])
        XCTAssertEqual(targets.first?.path, "/opt/acme/bin/zsh", "each with the executable the census read")
        let stopped = TabSuspension.stop(targets, signals: signals)
        XCTAssertEqual(stopped, targets)
        XCTAssertEqual(kernel.sent.map(\.pid), [1101, 1102, 1103, 1104])
        XCTAssertTrue(kernel.sent.allSatisfy { $0.signal == SIGSTOP && $0.pinned }, "by their tokens")
        let sends = kernel.sent.count
        TabSuspension.resume(stopped, signals: signals)
        let continued = kernel.sent.dropFirst(sends)
        XCTAssertEqual(continued.map(\.pid), [1104, 1103, 1102, 1101])
        XCTAssertTrue(continued.allSatisfy { $0.signal == SIGCONT && $0.pinned })
    }

    /// What it stops is read at the press, as the scan it replaced read it
    /// (7.8): the census's other readers answer from a snapshot up to a
    /// tick old, and a tab suspended from one would keep running what
    /// started since — the command just typed — under the cover, its shell
    /// stopped.
    func testWhatItStopsIsReadAtThePress() {
        let census = census()
        let reader = ProcessInspector(census: census)
        XCTAssertEqual(reader.tree(root: 1100, tag: tag).flatMap(\.flattened).map(\.pid), [1101])
        add(1102, parent: 1101, terminal: tty, name: "acme-job")
        XCTAssertEqual(reader.tree(root: 1100, tag: tag).flatMap(\.flattened).map(\.pid), [1101], "another reader's lookup: a tick old")
        XCTAssertEqual(TabSuspension.targets(login: 1100, tag: tag, checkouts: [], census: census).map(\.identity.pid), [1101, 1102], "read at the press")
        XCTAssertTrue(kernel.sent.isEmpty)
    }

    /// 2.4 item 14: a tag reaches past the pane — a tmux server and its
    /// sessions' shells, a daemon, an app started with `code .`, a nohup'd
    /// job — and none of those is stopped with the tab. What left the
    /// pane's terminal (disown, a setsid'd job of its own) still is.
    func testATaggedDaemonWhoseChildSitsOnItsOwnPtyIsNotInThePanesSet() throws {
        // A tmux-like daemon: started in the pane, setsid'd, launchd's now,
        // with a session's shell on a pty of its own.
        add(1200, parent: 1, flags: [.sessionLeader], name: "acme-mux", environment: tagged)
        add(1201, parent: 1200, terminal: otherTTY, flags: [.sessionLeader, .controllingTerminal], name: "acme-sh", environment: tagged)
        add(1202, parent: 1201, terminal: otherTTY, name: "acme-tool", environment: tagged)
        // By name: a tmux server, with nothing under it yet.
        add(1300, parent: 1, flags: [.sessionLeader], path: "/opt/acme/bin/tmux", name: "tmux", environment: tagged)
        // An app started from the pane, and its helper.
        add(1400, parent: 1, path: "/Applications/Acme Editor.app/Contents/MacOS/Acme Editor", name: "Acme Editor", environment: tagged)
        add(1401, parent: 1400, path: "/opt/acme/bin/acme-helper", name: "acme-helper", environment: tagged)
        // A nohup'd job: it chose to outlive its terminal.
        add(1500, parent: 1, ignoredSignals: 1 << UInt32(SIGHUP - 1), name: "acme-nohup", environment: tagged)
        // What left the pane's terminal, disowned or setsid'd on its own:
        // still the pane's.
        add(1600, parent: 1, flags: [.sessionLeader], name: "acme-left", environment: tagged)
        add(1601, parent: 1600, name: "acme-left-child", environment: tagged)
        // In the pane's tree, on another terminal: a session of its own.
        add(1102, parent: 1101, terminal: otherTTY, flags: [.sessionLeader], name: "acme-pty", environment: tagged)
        // A dev build's .app inside a checkout stays the pane's.
        add(1700, parent: 1101, terminal: tty, path: "/Users/fake/acme-repo/build/Acme.app/Contents/MacOS/Acme", name: "Acme")

        let census = census()
        let shown = ProcessInspector(census: census).tree(root: 1100, tag: tag).flatMap(\.flattened).map(\.pid)
        XCTAssertTrue(Set([1200, 1201, 1202, 1300, 1400, 1401, 1500, 1600, 1601]).isSubset(of: Set(shown)), "displayed where the tag places them")

        let stopped = TabSuspension.targets(login: 1100, tag: tag, checkouts: ["/Users/fake/acme-repo/"], census: census).map(\.identity.pid)
        XCTAssertEqual(stopped, [1101, 1700, 1600, 1601])

        let snapshot = try XCTUnwrap(census.latest)
        let slice = try XCTUnwrap(snapshot.pane(tag))
        let set = ActivityPaneSet(slice, in: snapshot, checkouts: ["/Users/fake/acme-repo"])
        let reasons = Dictionary(uniqueKeysWithValues: set.leftOut.map { ($0.identity.pid, $0.reason) })
        XCTAssertEqual(reasons[1200], .detachedOnPurpose, "it serves another terminal")
        XCTAssertEqual(reasons[1201], .underExcluded, "a session's shell, under the daemon")
        XCTAssertEqual(reasons[1202], .underExcluded)
        XCTAssertEqual(reasons[1300], .detachedOnPurpose)
        XCTAssertEqual(reasons[1400], .app)
        XCTAssertEqual(reasons[1401], .underExcluded)
        XCTAssertEqual(reasons[1500], .ignoresHangup)
        XCTAssertEqual(reasons[1102], .otherTerminal)

        // The bundle walk is a string's, bounded by its components.
        XCTAssertNil(ActivityPaneSet.appBundle(of: "/opt/acme/bin/acme.app"), "a file named so is no bundle")
        XCTAssertEqual(ActivityPaneSet.appBundle(of: "/Applications/A.app/Contents/B.app/Contents/MacOS/b"), "/Applications/A.app")
        XCTAssertFalse(ActivityPaneSet.isInside("/Applications/A.app", "/"), "never the whole disk")
        XCTAssertTrue(kernel.sent.isEmpty)
    }

    /// Rule 7 is an app started from the pane, off its terminal: the
    /// pane's own foreground jobs on its terminal are stopped with it
    /// whatever their path — a build under Xcode's `Contents/Developer`, an
    /// interpreter that runs as a framework's `Python.app`, Docker.app's
    /// CLI, even an app's own executable run in the foreground — and a
    /// toolchain inside a bundle is no app off the terminal either.
    func testAPanesOwnJobInsideABundleIsStoppedWithIt() throws {
        let developer = "/Applications/Xcode.app/Contents/Developer"
        add(1102, parent: 1101, terminal: tty, path: "/usr/bin/make", name: "make")
        add(1103, parent: 1102, terminal: tty, path: "\(developer)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-build", name: "swift-build")
        add(1104, parent: 1103, terminal: tty, path: "\(developer)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend", name: "swift-frontend")
        add(
            1105, parent: 1101, terminal: tty,
            path: "\(developer)/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python", name: "Python")
        add(1106, parent: 1101, terminal: tty, path: "/Applications/Acme Engine.app/Contents/Resources/bin/acme", name: "acme")
        add(1107, parent: 1101, terminal: tty, path: "/Applications/Acme Editor.app/Contents/MacOS/Acme Editor", name: "Acme Editor")
        // Off the terminal, setsid'd from the pane: a toolchain's server is
        // still no app.
        add(1108, parent: 1, flags: [.sessionLeader], path: "\(developer)/usr/bin/acme-server", name: "acme-server", environment: tagged)

        let census = census()
        let stopped = TabSuspension.targets(login: 1100, tag: tag, checkouts: [], census: census).map(\.identity.pid)
        XCTAssertEqual(stopped, [1101, 1102, 1103, 1104, 1105, 1106, 1107, 1108])
        let snapshot = try XCTUnwrap(census.latest)
        let slice = try XCTUnwrap(snapshot.pane(tag))
        XCTAssertEqual(ActivityPaneSet(slice, in: snapshot).leftOut.count, 0)

        XCTAssertNil(ActivityPaneSet.appBundle(of: "\(developer)/usr/bin/xcodebuild"), "Xcode's toolchain")
        XCTAssertNil(
            ActivityPaneSet.appBundle(of: "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python"),
            "a framework's interpreter")
        XCTAssertNil(ActivityPaneSet.appBundle(of: "/Applications/Acme Engine.app/Contents/Resources/bin/acme"), "a CLI shipped in a bundle")
        XCTAssertNil(ActivityPaneSet.appBundle(of: "/Applications/Acme.app/Contents/Developer/Platforms/Acme.app/Contents/MacOS/acme"))
        XCTAssertEqual(ActivityPaneSet.appBundle(of: "/Applications/Acme Editor.app/Contents/MacOS/Acme Editor"), "/Applications/Acme Editor.app")
        XCTAssertTrue(kernel.sent.isEmpty)
    }

    /// Resume hours later: a pid ended and taken again by another process
    /// — perhaps a job someone stopped with ⌃Z elsewhere — is never sent
    /// the SIGCONT meant for the one stopped.
    func testAReusedPidIsNeverResumed() {
        add(1102, parent: 1101, terminal: tty, name: "acme-job")
        let stopped = TabSuspension.stop(targets(), signals: signals)
        XCTAssertEqual(stopped.map(\.identity.pid), [1101, 1102])
        kernel.remove(1102)
        add(1102, parent: 1, start: 9_000_000, terminal: otherTTY, name: "acme-stranger")
        kernel.update(1102) { $0.record = FakeActivityKernel.record($0.record, status: SSTOP) }
        let sends = kernel.sent.count
        TabSuspension.resume(stopped, signals: signals)
        XCTAssertEqual(kernel.sent.dropFirst(sends).map(\.pid), [1101], "the shell continued, the stranger left stopped")
        XCTAssertEqual(kernel.process(1102)?.status, SSTOP)
    }

    /// One that is gone isn't remembered, and Resume has nothing to continue.
    func testAProcessThatIsGoneIsNotRemembered() {
        let gone = ActivitySignalTarget(ActivityProcessID(pid: 4_242, start: 4_242_000), path: nil)
        XCTAssertEqual(TabSuspension.stop([gone], signals: signals), [])
        XCTAssertTrue(kernel.sent.isEmpty)
    }
}
