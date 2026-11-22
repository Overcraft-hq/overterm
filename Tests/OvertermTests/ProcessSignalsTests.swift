import Darwin
import Foundation
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

/// The one signal path (docs/design/activity/analysis.md, 6.10, 9.6, 10.1,
/// 10.2): the refusals made before any call that touches a process — an
/// effective uid that isn't the user's among them —, the token taken first
/// and the identity checked through it, an ESRCH told apart from an exec,
/// the fallback without a token, a stopped target continued after TERM,
/// Overterm's helpers, and the isolated-run gate. Over a fake Mac first;
/// then the real kernel, with the test's own children only — a setuid one,
/// one that execs, a dead one, a plain one stopped, continued and ended.
/// Nothing else is ever signalled: a real process that isn't the test's
/// is asked about only through a kernel that sends nothing.
final class ProcessSignalsTests: XCTestCase {
    private let kernel = FakeActivityKernel(uid: 501)
    private let app = ActivityProcessID(pid: 100, start: 100)

    override func tearDown() {
        kernel.onCall(nil)
        super.tearDown()
    }

    // MARK: A fake Mac

    /// launchd, the app, a pane — its root-owned `login`, the shell, a job
    /// —, one of the app's helpers with a child, and a process elsewhere.
    private func mac() {
        add(1, parent: 0, uid: 0, name: "launchd")
        add(app.pid, start: app.start, parent: 1, name: "Overterm")
        add(200, parent: app.pid, uid: 0, realUID: 501, name: "login")
        add(300, parent: 200, name: "zsh")
        add(400, parent: 300, name: "acme-server")
        add(210, parent: app.pid, name: "kubectl")
        add(220, parent: 210, name: "acme-plugin")
        add(500, parent: 1, name: "globex-daemon")
    }

    @discardableResult
    private func add(
        _ pid: pid_t, start: UInt64? = nil, parent: pid_t, uid: uid_t = 501, realUID: uid_t? = nil, savedUID: uid_t? = nil, group: pid_t? = nil,
        status: Int32 = SRUN, flags: ActivityProcess.Flags = [], name: String, path: String? = nil
    ) -> ActivitySignalTarget {
        let start = start ?? UInt64(pid) * 1_000
        var process = FakeActivityKernel.Process(
            record: FakeActivityKernel.record(
                pid: pid, start: start, parent: parent, uid: uid, realUID: realUID, savedUID: savedUID, group: group, status: status, flags: flags,
                name: name))
        process.name = name
        process.path = path ?? "/opt/acme/bin/\(name)"
        kernel.add(process)
        return ActivitySignalTarget(ActivityProcessID(pid: pid, start: start), path: process.path)
    }

    private func target(_ pid: pid_t) -> ActivitySignalTarget {
        ActivitySignalTarget(ActivityProcessID(pid: pid, start: UInt64(pid) * 1_000), path: "/opt/acme/bin/\(nameOf(pid))")
    }

    private func nameOf(_ pid: pid_t) -> String { kernel.process(pid)?.shortName ?? "" }

    /// Over the fake Mac: its app, a gate of its own, the helper groups it
    /// says — never the test process's real registries.
    private func sender(guards: Bool = false, gate: ActivitySignalGate? = nil, helperGroups: Set<pid_t> = []) -> ProcessSignals {
        ProcessSignals(kernel: kernel, gate: gate ?? ActivitySignalGate(guards: guards), app: app, helperGroups: { helperGroups })
    }

    /// The calls that touch a process: a token taken, a signal sent.
    private var touched: Int { kernel.count("token") + kernel.count("signal") + kernel.count("kill") }

    /// Makes `identity` the run's own to the app's gate — the one the real
    /// kernel's sends check — until the test ends.
    private func own(_ identity: ActivityProcessID) {
        XCTAssertTrue(ActivitySignalGate.shared.register(identity))
        addTeardownBlock { ActivitySignalGate.shared.unregister(identity) }
    }

    // MARK: A group (6.10 step 9)

    /// A pane's job leading its group, with a child of its own in it: the
    /// leader pinned, every member checked, then one `killpg`.
    private func groupMac() -> ActivitySignalTarget {
        mac()
        let leader = add(600, parent: 300, group: 600, name: "acme-job")
        add(601, parent: 600, group: 600, name: "acme-plugin")
        for pid: pid_t in [300, 600, 601] { kernel.update(pid) { $0.session = 200 } }
        return leader
    }

    func testAGroupIsSignalledOnceEveryMemberIsChecked() {
        let leader = groupMac()
        XCTAssertEqual(sender().sendToGroup(.int, leader: leader), .sent(pinned: true))
        XCTAssertEqual(kernel.sent, [FakeActivityKernel.Sent(pid: 600, signal: SIGINT, pinned: false, group: true)])
        XCTAssertEqual(kernel.count("groupMembers"), 1, "its members listed again just before")
    }

    func testAGroupWithAMemberThatIsntTheLeadersIsRefused() {
        let leader = groupMac()
        let signals = sender()
        // Started before the leader: a group id taken again.
        add(602, start: 1, parent: 1, group: 600, name: "acme-older")
        XCTAssertEqual(signals.sendToGroup(.int, leader: leader), .refused(.group))
        kernel.remove(602)
        // Another session's.
        add(603, parent: 600, group: 600, name: "acme-elsewhere")
        kernel.update(603) { $0.session = 999 }
        XCTAssertEqual(signals.sendToGroup(.int, leader: leader), .refused(.group))
        kernel.remove(603)
        // Not the user's alone: a setuid program started in it.
        add(604, parent: 600, uid: 0, realUID: 501, group: 600, name: "acme-setuid")
        XCTAssertEqual(signals.sendToGroup(.int, leader: leader), .refused(.group))
        kernel.remove(604)
        // One of Overterm's helpers' groups' members.
        XCTAssertEqual(sender(helperGroups: [600]).sendToGroup(.int, leader: leader), .refused(.helper))
        XCTAssertTrue(kernel.sent.isEmpty, "nothing sent")
        XCTAssertEqual(sender().sendToGroup(.int, leader: leader), .sent(pinned: true), "the group its own again")
    }

    /// Activity's Stop Its Group reads each member again for what no group
    /// Stop may reach: one that exec'd into an agent, a terraform write, or
    /// a pane's shell joining since the sheet refuses the whole send.
    func testAGroupsMembersAreReadAgainForWhatNoGroupStopReaches() {
        let leader = groupMac()
        func member(_ pid: pid_t, parent: pid_t = 600, name: String, argv: [String]) {
            add(pid, parent: parent, group: 600, name: name)
            kernel.update(pid) {
                $0.session = 200
                $0.arguments = FakeActivityKernel.arguments(executable: "/opt/acme/bin/\(name)", argv)
            }
        }
        member(610, name: "claude", argv: ["claude"])
        XCTAssertEqual(sender().sendToGroup(.term, leader: leader, policy: true), .refused(.groupHolds), "an agent")
        kernel.remove(610)
        member(611, name: "terraform", argv: ["terraform", "apply", "-auto-approve"])
        XCTAssertEqual(sender().sendToGroup(.term, leader: leader, policy: true), .refused(.groupHolds), "a terraform write")
        kernel.remove(611)
        member(612, name: "terraform", argv: ["terraform", "plan"])
        kernel.update(612) { $0.arguments = nil }
        XCTAssertEqual(sender().sendToGroup(.term, leader: leader, policy: true), .refused(.groupHolds), "a terraform whose argv can't be read")
        kernel.remove(612)
        member(613, parent: 200, name: "zsh", argv: ["-zsh"])
        XCTAssertEqual(sender().sendToGroup(.term, leader: leader, policy: true), .refused(.groupHolds), "a pane's shell")
        kernel.remove(613)
        XCTAssertTrue(kernel.sent.isEmpty, "nothing sent")
        member(614, name: "terraform", argv: ["terraform", "plan"])
        member(615, name: "sh", argv: ["sh", "-c", "acme-build"])
        XCTAssertEqual(sender().sendToGroup(.term, leader: leader, policy: true), .sent(pinned: true), "a plan and a script's shell: a group's own")
        member(616, name: "acme-agent", argv: ["claude", "--continue"])
        XCTAssertEqual(sender().sendToGroup(.term, leader: leader, policy: true), .refused(.groupHolds), "argv[0] names the agent")
        XCTAssertEqual(sender().sendToGroup(.int, leader: leader), .sent(pinned: true), "without the policy: terraform's close guard's group")
    }

    /// Stop Its Group sends to the members its sheet listed and nobody
    /// else: one that joined the group since refuses the send; one that
    /// left or ended since leaves nothing to refuse.
    func testAGroupsSendReachesOnlyTheMembersItsSheetListed() {
        let leader = groupMac()
        let listed: Set<ActivityProcessID> = [ActivityProcessID(pid: 601, start: 601_000)]
        add(620, parent: 600, group: 600, name: "acme-stage")
        kernel.update(620) { $0.session = 200 }
        XCTAssertEqual(sender().sendToGroup(.term, leader: leader, listed: listed, policy: true), .refused(.groupChanged), "joined since the sheet")
        XCTAssertTrue(kernel.sent.isEmpty, "nothing sent")
        kernel.remove(620)
        kernel.remove(601)
        XCTAssertEqual(sender().sendToGroup(.term, leader: leader, listed: listed, policy: true), .sent(pinned: true), "one that ended since")
        XCTAssertEqual(kernel.sent, [FakeActivityKernel.Sent(pid: 600, signal: SIGTERM, pinned: false, group: true)])
    }

    func testAGroupItsLeaderDoesntLeadOrThatEndedIsntSignalled() {
        mac()
        // In the shell's group: the shell's job control's, not its own.
        let member = add(600, parent: 300, group: 300, name: "acme-job")
        XCTAssertEqual(sender().sendToGroup(.int, leader: member), .refused(.group))
        // Ended, its pid another's now.
        let leader = add(700, parent: 300, group: 700, name: "acme-ended")
        kernel.remove(700)
        add(700, start: 9_999_999, parent: 1, group: 700, name: "globex-other")
        XCTAssertEqual(sender().sendToGroup(.int, leader: leader), .ended(now: "globex-other"))
        // This process's own group.
        XCTAssertEqual(sender().sendToGroup(.int, leader: ActivitySignalTarget(app, path: nil)), .refused(.overterm))
        XCTAssertTrue(kernel.sent.isEmpty)
        XCTAssertEqual(kernel.count("killpg"), 0)
    }

    func testAGroupInAnIsolatedRunIsTheRunsOwnOnly() {
        mac()
        // launchd's child: not under a pane's `login`, not registered.
        let leader = add(800, parent: 1, group: 800, name: "globex-job")
        XCTAssertEqual(sender(guards: true).sendToGroup(.int, leader: leader), .refused(.gate))
        // Under the pane, but a member elsewhere isn't the run's.
        let job = add(600, parent: 300, group: 600, name: "acme-job")
        add(801, parent: 1, group: 600, name: "globex-member")
        XCTAssertEqual(sender(guards: true).sendToGroup(.int, leader: job), .refused(.group))
        XCTAssertTrue(kernel.sent.isEmpty)
    }

    // MARK: Refused before anything is read

    /// launchd, the kernel, `kill(0)`'s and `kill(-1)`'s pids, a group's
    /// negative id, this process: refused with not even a read made.
    func testRefusalsBeforeAnythingIsRead() {
        mac()
        kernel.resetCounts()
        let signals = sender()
        for pid: pid_t in [1, 0, -1, -400] {
            XCTAssertEqual(signals.send(.term, to: ActivitySignalTarget(ActivityProcessID(pid: pid, start: 1), path: nil), alone: true), .refused(.system), "pid \(pid)")
        }
        XCTAssertEqual(signals.send(.kill, to: ActivitySignalTarget(app, path: nil), alone: true), .refused(.overterm))
        let me = ActivityProcessID(pid: getpid(), start: 1)
        XCTAssertEqual(signals.send(.term, to: ActivitySignalTarget(me, path: nil), alone: true), .refused(.overterm), "the test process itself")
        XCTAssertEqual(kernel.count("process"), 0, "nothing read")
        XCTAssertEqual(touched, 0)
        XCTAssertTrue(kernel.sent.isEmpty)
    }

    /// Reads compare the effective uid; `kill(2)` the real and saved ones,
    /// so a setuid program the user started would pass the kernel's check
    /// (3.2): refused here by its effective uid, before a token is taken.
    func testAnEffectiveUIDThatIsntTheUsersIsRefusedBeforeAnyCall() {
        mac()
        let setuid = add(600, parent: 300, uid: 0, realUID: 501, name: "top", path: "/usr/bin/top")
        let root = add(601, parent: 1, uid: 0, name: "acme-root-daemon")
        let other = add(602, parent: 1, uid: 502, name: "globex-agent")
        kernel.resetCounts()
        let signals = sender()
        for target in [setuid, root, other] {
            for signal in ActivitySignal.allCases {
                XCTAssertEqual(signals.send(signal, to: target, alone: true), .refused(.notYours), "pid \(target.identity.pid), \(signal)")
            }
        }
        XCTAssertEqual(touched, 0, "no token, no signal")
        XCTAssertTrue(kernel.sent.isEmpty)
    }

    /// Running as the user only for now: a setuid program that set its
    /// effective uid to the user's keeps root as its saved uid, to take
    /// back; root's process doing the same keeps root's real uid. Both pass
    /// the effective uid's test, and `kill(2)` lets the first through by its
    /// real uid: refused here by all three, before any call — with a token
    /// to be had or not.
    func testWhatRunsAsTheUserOnlyForNowIsRefusedBeforeAnyCall() {
        mac()
        let dropped = add(603, parent: 300, uid: 501, realUID: 501, savedUID: 0, name: "acme-setuid-tool")
        let rootsForNow = add(604, parent: 1, uid: 501, realUID: 0, savedUID: 0, name: "acme-root-helper")
        let rootsReal = add(605, parent: 1, uid: 501, realUID: 0, savedUID: 501, name: "acme-root-worker")
        kernel.resetCounts()
        for tokens in [true, false] {
            kernel.refuseTokens(!tokens)
            for target in [dropped, rootsForNow, rootsReal] {
                for signal in ActivitySignal.allCases {
                    XCTAssertEqual(sender().send(signal, to: target, alone: true), .refused(.notYours), "pid \(target.identity.pid), \(signal)")
                }
            }
        }
        XCTAssertEqual(touched, 0, "no token, no signal")
        XCTAssertTrue(kernel.sent.isEmpty)
    }

    // MARK: Ended, or another program

    /// Gone, a zombie, its pid another process's now: ended, the new
    /// holder named; nothing taken, nothing sent.
    func testEndedBeforeTheToken() {
        mac()
        let gone = ActivitySignalTarget(ActivityProcessID(pid: 700, start: 700_000), path: "/opt/acme/bin/acme-gone")
        let zombie = add(701, parent: 300, status: SZOMB, name: "acme-zombie")
        let listed = add(702, parent: 300, name: "acme-worker")
        // Pid 702 came round again: another process, started later.
        add(702, start: 9_000_000, parent: 1, name: "globex-server")
        kernel.resetCounts()
        let signals = sender()
        XCTAssertEqual(signals.send(.term, to: gone, alone: true), .ended(now: nil))
        XCTAssertEqual(signals.send(.term, to: zombie, alone: true), .ended(now: nil), "a zombie has nothing to signal")
        XCTAssertEqual(signals.send(.term, to: listed, alone: true), .ended(now: "globex-server"), "It ended — pid 702 is now globex-server")
        XCTAssertEqual(touched, 0)
    }

    /// A pid that died and was taken again between the read and the token
    /// gives a token for the new process: its start, read after the token,
    /// isn't the listed one, so nothing is sent.
    func testAPidReusedBeforeTheTokenIsNeverSignalled() {
        mac()
        let listed = add(710, parent: 300, name: "acme-worker")
        kernel.onCall { [kernel] call in
            guard call == "token", kernel.count("token") == 1 else { return }
            kernel.remove(710)
            var reused = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 710, start: 9_000_000, parent: 1, name: "globex-server"))
            reused.path = "/opt/globex/bin/globex-server"
            kernel.add(reused)
        }
        XCTAssertEqual(sender().send(.kill, to: listed, alone: true), .ended(now: "globex-server"))
        XCTAssertEqual(kernel.count("token"), 1)
        XCTAssertEqual(kernel.count("signal"), 0)
        XCTAssertTrue(kernel.sent.isEmpty, "its token named the new process: nothing sent")

        // Taken again after the token — at the path check, or between the
        // checks and the send: the token names the image that ended, and
        // reaches nothing of the new process's.
        for call in ["tokenPath", "signal"] {
            kernel.onCall(nil)
            let pid: pid_t = call == "signal" ? 712 : 711
            let old = add(pid, parent: 300, name: "acme-worker")
            kernel.resetCounts()
            kernel.onCall { [kernel] made in
                guard made == call, kernel.count(call) == 1 else { return }
                var reused = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: pid, start: 9_000_000, parent: 1, name: "globex-server"))
                reused.path = "/opt/globex/bin/globex-server"
                kernel.add(reused)
            }
            XCTAssertEqual(sender().send(.term, to: old, alone: true), .ended(now: "globex-server"), "reused at \(call)")
        }
        XCTAssertTrue(kernel.sent.isEmpty)
    }

    /// An exec since it was listed: the same pid and start, another
    /// executable through the token — "it ran another program", nothing sent.
    func testAnExecSinceItWasListedRanAnotherProgram() {
        mac()
        let listed = add(720, parent: 300, name: "acme-launcher")
        kernel.exec(720, path: "/opt/acme/bin/acme-server", name: "acme-server")
        XCTAssertEqual(sender().send(.term, to: listed, alone: true), .ranAnotherProgram(path: "/opt/acme/bin/acme-server"))
        XCTAssertEqual(kernel.count("signal"), 0)
        XCTAssertTrue(kernel.sent.isEmpty)
    }

    /// An exec between the check and the send: the token answers ESRCH (3)
    /// while the process lives on — told apart from an end by its start
    /// and its image's version, a re-exec of its own binary included.
    func testAnESRCHIsToldApartFromAnExec() {
        mac()
        let listed = add(730, parent: 300, name: "acme-launcher")
        kernel.onCall { [kernel] call in
            if call == "signal", kernel.count("signal") == 1 { kernel.exec(730, path: "/opt/acme/bin/acme-server", name: "acme-server") }
        }
        XCTAssertEqual(sender().send(.term, to: listed, alone: true), .ranAnotherProgram(path: "/opt/acme/bin/acme-server"))
        XCTAssertTrue(kernel.sent.isEmpty, "the old token reached nothing")

        // Its own binary again (`exec "$0"`): the same path, a new image.
        kernel.onCall(nil)
        let again = add(731, parent: 300, name: "acme-shim")
        kernel.resetCounts()
        kernel.onCall { [kernel] call in
            if call == "signal", kernel.count("signal") == 1 { kernel.exec(731, path: "/opt/acme/bin/acme-shim", name: "acme-shim") }
        }
        XCTAssertEqual(sender().send(.term, to: again, alone: true), .ranAnotherProgram(path: "/opt/acme/bin/acme-shim"), "asked again, not ended")

        // Gone between the check and the send: ended.
        kernel.onCall(nil)
        let ending = add(732, parent: 300, name: "acme-worker")
        kernel.resetCounts()
        kernel.onCall { [kernel] call in
            if call == "signal", kernel.count("signal") == 1 { kernel.remove(732) }
        }
        XCTAssertEqual(sender().send(.term, to: ending, alone: true), .ended(now: nil))
        XCTAssertTrue(kernel.sent.isEmpty)
    }

    // MARK: Stage 2: a tree, Force Quit, what came back

    /// A tree's members: each by its own token, parents first — CONT
    /// children first —, one that exec'd since the sheet said and the rest
    /// still sent; never by a pid.
    func testATreeIsSentParentsFirstEachByItsToken() {
        mac()
        let root = add(800, parent: 300, name: "acme-supervisor")
        let worker = add(801, parent: 800, name: "acme-worker")
        let leaf = add(802, parent: 801, name: "acme-leaf")
        let answers = sender().sendTree(.term, to: [root, worker, leaf])
        XCTAssertEqual(answers.map(\.answer), [.sent(pinned: true), .sent(pinned: true), .sent(pinned: true)])
        XCTAssertEqual(kernel.sent.map(\.pid), [800, 801, 802], "parents first: a supervisor can't start again what follows")
        XCTAssertTrue(kernel.sent.allSatisfy(\.pinned))

        kernel.resetCounts()
        let continued = sender().sendTree(.cont, to: [root, worker, leaf])
        XCTAssertEqual(continued.map(\.target.identity.pid), [802, 801, 800], "CONT children first")
        XCTAssertEqual(Array(kernel.sent.suffix(3)).map(\.pid), [802, 801, 800])

        // One exec'd since the sheet: said, the others sent.
        let before = kernel.sent.count
        kernel.exec(801, path: "/opt/acme/bin/acme-other", name: "acme-other")
        let mixed = sender().sendTree(.term, to: [root, worker, leaf])
        XCTAssertEqual(mixed[1].answer, .ranAnotherProgram(path: "/opt/acme/bin/acme-other"))
        XCTAssertEqual(kernel.sent.count - before, 2, "the parent and the leaf, not what 801 runs now")
    }

    /// Without tokens a tree's members, and a Force Quit, are refused: only
    /// a single Stop or Interrupt falls back to its pid.
    func testATreeAndAForceQuitNeedTokens() {
        mac()
        let root = add(810, parent: 300, name: "acme-supervisor")
        let worker = add(811, parent: 810, name: "acme-worker")
        kernel.refuseTokens(true)
        XCTAssertEqual(sender().sendTree(.term, to: [root, worker]).map(\.answer), [.refused(.unpinned), .refused(.unpinned)])
        XCTAssertEqual(sender().send(.kill, to: root, alone: true), .refused(.unpinned), "Force Quit: no fallback")
        XCTAssertTrue(kernel.sent.isEmpty)
        XCTAssertEqual(sender().send(.term, to: root, alone: true), .sent(pinned: false), "a single Stop does")
        kernel.refuseTokens(false)
    }

    /// Force Quit by its token: SIGKILL to the process alone, never its
    /// group, and no CONT after it — even stopped, a KILL ends it.
    func testForceQuitIsTheProcessAlone() {
        mac()
        let target = add(820, parent: 300, group: 300, status: SSTOP, name: "acme-stuck")
        XCTAssertEqual(sender().send(.kill, to: target, alone: true), .sent(pinned: true))
        XCTAssertEqual(kernel.sent, [FakeActivityKernel.Sent(pid: 820, signal: SIGKILL, pinned: true)])
    }

    /// What a Stop's watch says (6.10 step 10): stopping, then stopped,
    /// still running at its end, or came back as pid N — the same
    /// executable under the same parent, or its port, by a process started
    /// since; never one older.
    func testTheStopWatch() {
        let listed = ActivityStopWatch.Listed(
            identity: ActivityProcessID(pid: 4242, start: 1_000), name: "acme-server", path: "/opt/acme/bin/acme-server", parent: 4200, ports: [3000])
        let sentAt: UInt64 = 5_000
        XCTAssertEqual(ActivityStopWatch.state(listed, alive: true, seen: [], sentAt: sentAt, final: false), .stopping)
        XCTAssertEqual(ActivityStopWatch.state(listed, alive: true, seen: [], sentAt: sentAt, final: true), .stillRunning)
        XCTAssertEqual(ActivityStopWatch.state(listed, alive: false, seen: [], sentAt: sentAt, final: false), .stopped)
        let again = ActivityStopWatch.Seen(identity: ActivityProcessID(pid: 4300, start: 6_000), path: listed.path, parent: 4200)
        XCTAssertEqual(ActivityStopWatch.state(listed, alive: false, seen: [again], sentAt: sentAt, final: false), .cameBack(pid: 4300))
        let port = ActivityStopWatch.Seen(identity: ActivityProcessID(pid: 4301, start: 7_000), path: "/opt/acme/bin/other", parent: 1, ports: [3000])
        XCTAssertEqual(ActivityStopWatch.state(listed, alive: false, seen: [port], sentAt: sentAt, final: false), .cameBack(pid: 4301))
        let older = ActivityStopWatch.Seen(identity: ActivityProcessID(pid: 4100, start: 2_000), path: listed.path, parent: 4200, ports: [3000])
        XCTAssertEqual(ActivityStopWatch.state(listed, alive: false, seen: [older], sentAt: sentAt, final: true), .stopped, "older: not a comeback")
        let elsewhere = ActivityStopWatch.Seen(identity: ActivityProcessID(pid: 4302, start: 8_000), path: listed.path, parent: 1)
        XCTAssertEqual(ActivityStopWatch.state(listed, alive: false, seen: [elsewhere], sentAt: sentAt, final: true), .stopped, "another parent's")
        XCTAssertEqual(ActivityStopWatch.label(.cameBack(pid: 4300), listed), "“acme-server” (pid 4242) came back as pid 4300")
        XCTAssertEqual(ActivityStopWatch.label(.stillRunning, listed), "“acme-server” (pid 4242) still running — Force Quit…")
    }

    /// A real tree of the test's own: a shell and its two sleeps, ended by
    /// their tokens parents first.
    func testARealTreeEndedByTokens() throws {
        let child = try TestChild("/bin/sh", ["-c", "/bin/sleep 30 & /bin/sleep 30 & wait"])
        defer { child.stop() }
        let real = LiveActivityKernel()
        func kids() -> [ActivityProcess] { (real.processes() ?? []).filter { $0.parentPID == child.pid && !$0.isZombie } }
        XCTAssertTrue(TestChild.eventually { kids().count == 2 }, "two sleeps")
        let members = [child.identity] + kids().map(\.identity)
        // Whatever the checks say, the test's own sleeps end with it: each
        // by its pid, once its start is read again.
        defer {
            for identity in members.dropFirst() where real.process(identity.pid)?.identity == identity { kill(identity.pid, SIGKILL) }
        }
        for identity in members { own(identity) }
        let signals = ProcessSignals(kernel: RecordingKernel(own: Set(members)))
        let targets = members.map { ActivitySignalTarget($0, path: real.path(of: $0.pid)) }
        let answers = signals.sendTree(.term, to: targets)
        XCTAssertEqual(answers.map(\.answer), Array(repeating: .sent(pinned: true), count: 3))
        XCTAssertNotNil(child.exited(), "the shell ended")
        XCTAssertTrue(TestChild.eventually { members.dropFirst().allSatisfy { real.process($0.pid)?.identity != $0 || real.process($0.pid)?.isZombie == true } })
    }

    // MARK: Sent

    /// The plain case: by its token, once.
    func testSentByToken() {
        mac()
        let job = target(400)
        XCTAssertEqual(sender().send(.term, to: job, alone: true), .sent(pinned: true))
        XCTAssertEqual(kernel.sent, [FakeActivityKernel.Sent(pid: 400, signal: SIGTERM, pinned: true)])
        XCTAssertEqual(kernel.count("kill"), 0)
    }

    /// Its executable deleted or replaced while it runs (no path through
    /// the token, none at listing or none now): its pid and start alone,
    /// pinned still by the token.
    func testADeletedExecutableIsItsPidAndStart() {
        mac()
        var deleted = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 740, start: 740_000, parent: 300, name: "acme-server"))
        deleted.path = nil
        kernel.add(deleted)
        let identity = ActivityProcessID(pid: 740, start: 740_000)
        XCTAssertEqual(sender().send(.term, to: ActivitySignalTarget(identity, path: nil), alone: true), .sent(pinned: true), "unreadable when listed")
        XCTAssertEqual(
            sender().send(.term, to: ActivitySignalTarget(identity, path: "/opt/acme/bin/acme-server"), alone: true), .sent(pinned: true),
            "deleted since: the same image")
        XCTAssertEqual(kernel.sent.count, 2)
    }

    /// A stopped target sent TERM or INT is continued right after, by the
    /// same token, so it can act on it — never a traced one (6.10 step 7).
    func testAStoppedTargetIsContinuedAfterTERM() {
        mac()
        let stopped = add(750, parent: 300, status: SSTOP, name: "acme-server")
        XCTAssertEqual(sender().send(.term, to: stopped, alone: true), .sent(pinned: true))
        XCTAssertEqual(kernel.sent.map(\.signal), [SIGTERM, SIGCONT])
        XCTAssertEqual(kernel.sent.map(\.pinned), [true, true])

        let interrupted = add(751, parent: 300, status: SSTOP, name: "acme-build")
        _ = sender().send(.int, to: interrupted, alone: true)
        XCTAssertEqual(kernel.sent.filter { $0.pid == 751 }.map(\.signal), [SIGINT, SIGCONT])

        let traced = add(752, parent: 300, status: SSTOP, flags: [.traced], name: "acme-debugged")
        _ = sender().send(.term, to: traced, alone: true)
        XCTAssertEqual(kernel.sent.filter { $0.pid == 752 }.map(\.signal), [SIGTERM], "left to its debugger")

        let killed = add(753, parent: 300, status: SSTOP, name: "acme-stuck")
        _ = sender().send(.kill, to: killed, alone: true)
        _ = sender().send(.stop, to: add(754, parent: 300, status: SSTOP, name: "acme-held"), alone: true)
        XCTAssertEqual(kernel.sent.filter { $0.pid == 753 || $0.pid == 754 }.map(\.signal), [SIGKILL, SIGSTOP], "nothing after")
    }

    // MARK: No token

    /// No token to be had: a single Stop — or a single Interrupt, the
    /// terraform close guard's — falls back to its pid, its path and start
    /// read once more just before; a Force Quit, a member of a tree, a
    /// group or a bulk, any other signal: refused, saying why.
    func testWithoutATokenOnlyASingleStopFallsBack() {
        mac()
        kernel.refuseTokens(true)
        let job = target(400)
        let signals = sender()
        kernel.resetCounts()
        XCTAssertEqual(signals.send(.term, to: job, alone: true), .sent(pinned: false))
        XCTAssertEqual(kernel.sent, [FakeActivityKernel.Sent(pid: 400, signal: SIGTERM, pinned: false)])
        XCTAssertEqual(kernel.count("kill"), 1)
        XCTAssertEqual(kernel.count("signal"), 0)
        XCTAssertGreaterThanOrEqual(kernel.count("path"), 1, "its path read again just before")

        for signal in ActivitySignal.allCases where signal != .term && signal != .int {
            XCTAssertEqual(signals.send(signal, to: job, alone: true), .refused(.unpinned), "\(signal)")
        }
        XCTAssertEqual(signals.send(.term, to: job, alone: false), .refused(.unpinned), "a member of a tree, a group or a bulk")
        XCTAssertEqual(signals.send(.int, to: job, alone: false), .refused(.unpinned), "a member of a tree, a group or a bulk")
        XCTAssertEqual(kernel.count("kill"), 1)
        XCTAssertEqual(signals.send(.int, to: job, alone: true), .sent(pinned: false), "a single Interrupt")
        XCTAssertEqual(kernel.sent.last, FakeActivityKernel.Sent(pid: 400, signal: SIGINT, pinned: false))
        XCTAssertEqual(kernel.count("kill"), 2)

        // Changed just before: never sent by its pid.
        let launcher = add(760, parent: 300, name: "acme-launcher")
        kernel.exec(760, path: "/opt/acme/bin/acme-server", name: "acme-server")
        XCTAssertEqual(signals.send(.term, to: launcher, alone: true), .ranAnotherProgram(path: "/opt/acme/bin/acme-server"))
        let stopped = add(761, parent: 300, status: SSTOP, name: "acme-server")
        XCTAssertEqual(signals.send(.term, to: stopped, alone: true), .sent(pinned: false))
        XCTAssertEqual(kernel.sent.filter { $0.pid == 761 }.map(\.signal), [SIGTERM, SIGCONT])
        XCTAssertEqual(kernel.sent.filter { $0.pid == 760 }, [])
    }

    /// Without a token, the read just before the kill is all that stands
    /// between a pid taken again and a kill(2) to a stranger (6.10 step 6):
    /// a pid that came round after the path was read — another process,
    /// started later, running the same executable, so the path check
    /// passes — is "ended", the pid's new holder named, and gets nothing.
    func testWithoutATokenThePidIsReadAgainJustBeforeTheKill() {
        mac()
        kernel.refuseTokens(true)
        let listed = add(770, parent: 300, name: "acme-worker")
        kernel.resetCounts()
        kernel.onCall { [kernel] call in
            guard call == "path", kernel.count("path") == 1 else { return }
            var reused = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 770, start: 9_000_000, parent: 1, name: "acme-worker"))
            reused.path = "/opt/acme/bin/acme-worker"
            kernel.add(reused)
        }
        XCTAssertEqual(sender().send(.term, to: listed, alone: true), .ended(now: "acme-worker"))
        XCTAssertEqual(kernel.count("kill"), 0)
        XCTAssertTrue(kernel.sent.isEmpty)
    }

    /// Without `proc_signal_with_audittoken` on this macOS: no token is
    /// even taken, and the same fallback holds.
    func testWithoutTheTokenCallTheSameFallback() {
        mac()
        kernel.dropTokenSignal()
        kernel.resetCounts()
        let signals = sender()
        XCTAssertEqual(signals.send(.term, to: target(400), alone: true), .sent(pinned: false))
        XCTAssertEqual(signals.send(.kill, to: target(400), alone: true), .refused(.unpinned))
        XCTAssertEqual(signals.send(.stop, to: target(400), alone: false), .refused(.unpinned))
        XCTAssertEqual(kernel.count("token"), 0)
        XCTAssertEqual(kernel.sent, [FakeActivityKernel.Sent(pid: 400, signal: SIGTERM, pinned: false)])
    }

    // MARK: Overterm's helpers, and the gate

    /// What descends from one of the app's children that isn't a pane's
    /// `login` is a helper's: refused, its owner's verb ends it. What runs
    /// under a pane's `login` and what is elsewhere is the person's.
    func testOvertermsHelpersAreRefused() {
        mac()
        let signals = sender()
        XCTAssertEqual(signals.lineage(of: kernel.process(400)!), .pane)
        XCTAssertEqual(signals.lineage(of: kernel.process(220)!), .helper)
        XCTAssertEqual(signals.lineage(of: kernel.process(500)!), .elsewhere)
        kernel.resetCounts()
        XCTAssertEqual(signals.send(.term, to: target(210), alone: true), .refused(.helper))
        XCTAssertEqual(signals.send(.term, to: target(220), alone: true), .refused(.helper), "what a helper started")
        XCTAssertEqual(touched, 0)
        XCTAssertEqual(signals.send(.term, to: target(400), alone: true), .sent(pinned: true))
        XCTAssertEqual(signals.send(.term, to: target(500), alone: true), .sent(pinned: true), "the user's app: the gate is off")

        // A child of the app named login that runs as the user isn't a
        // pane's: libghostty's runs setuid.
        add(230, parent: app.pid, name: "login")
        add(231, parent: 230, name: "acme-tool")
        XCTAssertEqual(signals.lineage(of: kernel.process(231)!), .helper)
        // Parents by start time: 801's parent pid is the pane's shell's,
        // but that shell started after it — the pid was taken again — so
        // it is elsewhere, never the pane's.
        add(801, start: 100_000, parent: 300, name: "acme-orphan")
        XCTAssertEqual(signals.lineage(of: kernel.process(801)!), .elsewhere)
    }

    /// What is in a group a helper's registry holds is a helper's wherever
    /// it sits now: an apply found again after a relaunch — its launcher
    /// launchd's child, terraform under it, both in the launcher's group —
    /// and an exec plugin reparented once its kubectl exited, still in
    /// kubectl's group. Their lineage says elsewhere; their group says
    /// whose they are. Refused before any call, even in a gate that would
    /// let elsewhere through.
    func testWhatAHelpersGroupHoldsIsAHelpersWhereverItSits() {
        mac()
        add(610, parent: 1, name: "bash")
        add(611, parent: 610, group: 610, name: "terraform")
        add(620, parent: 1, group: 210, name: "acme-auth-plugin")
        let signals = sender(helperGroups: [610, 210])
        XCTAssertEqual(signals.lineage(of: kernel.process(610)!), .elsewhere)
        XCTAssertEqual(signals.lineage(of: kernel.process(620)!), .elsewhere)
        kernel.resetCounts()
        for pid: pid_t in [610, 611, 620, 210, 220] {
            XCTAssertEqual(signals.send(.term, to: target(pid), alone: true), .refused(.helper), "pid \(pid)")
        }
        XCTAssertEqual(touched, 0)
        // Its group no helper's: the person's, the gate off.
        XCTAssertEqual(signals.send(.term, to: target(500), alone: true), .sent(pinned: true))
        XCTAssertEqual(sender().send(.term, to: target(620), alone: true), .sent(pinned: true), "no registry holds kubectl's group: elsewhere")
    }

    /// In an isolated run or a unit test, only the run's own: what it
    /// registered, and what runs under its panes' `login`s. The rest is
    /// refused before a token is taken; nothing can be registered where
    /// the gate is off.
    func testTheGateKeepsToTheRunsOwn() {
        mac()
        let gate = ActivitySignalGate(guards: true)
        let signals = sender(gate: gate)
        kernel.resetCounts()
        XCTAssertEqual(signals.send(.term, to: target(500), alone: true), .refused(.gate))
        XCTAssertEqual(signals.send(.cont, to: target(500), alone: true), .refused(.gate))
        XCTAssertEqual(touched, 0, "refused before any call")
        XCTAssertEqual(signals.send(.term, to: target(400), alone: true), .sent(pinned: true), "under the run's own pane")
        XCTAssertTrue(gate.register(target(500).identity))
        XCTAssertEqual(signals.send(.term, to: target(500), alone: true), .sent(pinned: true), "registered")
        // A test's own child is its process's child: registered, it is the
        // test's, not a helper.
        XCTAssertEqual(signals.send(.term, to: target(210), alone: true), .refused(.helper))
        gate.register(target(210).identity)
        XCTAssertEqual(signals.send(.term, to: target(210), alone: true), .sent(pinned: true))
        gate.unregister(target(500).identity)
        XCTAssertEqual(signals.send(.term, to: target(500), alone: true), .refused(.gate))
        // By identity: the pid alone is no one's.
        add(500, start: 9_000_000, parent: 1, name: "globex-daemon")
        gate.register(ActivityProcessID(pid: 500, start: 500_000))
        let later = ActivitySignalTarget(ActivityProcessID(pid: 500, start: 9_000_000), path: "/opt/acme/bin/globex-daemon")
        XCTAssertEqual(signals.send(.term, to: later, alone: true), .refused(.gate))

        let off = ActivitySignalGate(guards: false)
        XCTAssertFalse(off.register(target(220).identity), "nothing registered in the user's app")
        XCTAssertFalse(off.isRegistered(target(220).identity))
        XCTAssertEqual(sender(gate: off).send(.term, to: target(220), alone: true), .refused(.helper))
    }

    /// The check the real kernel's sends make themselves (6.10 step 11),
    /// over a fake Mac: in a guarded run what holds the pid now must be the
    /// run's own — registered, or under one of the app's panes' `login`s,
    /// the app this process for the real kernel, never one a caller names.
    /// A stranger, a helper, a pid taken again since it was registered:
    /// EPERM; a pid nobody holds: ESRCH; each with no call. Off: nothing.
    func testTheKernelsOwnGateDecision() {
        mac()
        let gate = ActivitySignalGate(guards: true)
        kernel.resetCounts()
        XCTAssertNil(gate.refusal(of: 400, kernel: kernel, app: app.pid), "under the app's pane")
        XCTAssertEqual(gate.refusal(of: 400, kernel: kernel, app: 500), EPERM, "under no pane of another app's")
        XCTAssertEqual(gate.refusal(of: 500, kernel: kernel, app: app.pid), EPERM, "elsewhere")
        XCTAssertEqual(gate.refusal(of: 220, kernel: kernel, app: app.pid), EPERM, "a helper's")
        XCTAssertEqual(gate.refusal(of: 999, kernel: kernel, app: app.pid), ESRCH, "nobody's")
        gate.register(target(500).identity)
        XCTAssertNil(gate.refusal(of: 500, kernel: kernel, app: app.pid), "registered")
        add(500, start: 9_000_000, parent: 1, name: "globex-daemon")
        XCTAssertEqual(gate.refusal(of: 500, kernel: kernel, app: app.pid), EPERM, "the pid taken again: by identity")
        XCTAssertNil(ActivitySignalGate(guards: false).refusal(of: 500, kernel: kernel, app: app.pid), "the user's app")
        XCTAssertEqual(touched, 0)
    }

    // MARK: An app's Quit and Force Quit (6.10, D-23)

    /// An app asked to quit, or ended, checked as a signal is: the token
    /// first, the identity through it, then `terminate` or `forceTerminate`
    /// by the pid — asked only of the app running the executable the token
    /// named. No signal goes while the app is asked.
    func testAnAppIsAskedToQuitCheckedAsASignalIs() {
        mac()
        let app = add(700, parent: 1, name: "Acme")
        kernel.app(700)
        kernel.resetCounts()
        XCTAssertEqual(sender().quitApp(app, force: false), .sent(pinned: true))
        XCTAssertEqual(kernel.quitsAsked, [FakeActivityKernel.Quit(pid: 700, force: false)])
        XCTAssertEqual(kernel.count("token"), 1, "pinned first")
        XCTAssertEqual(kernel.sent, [], "asked, not signalled")
        XCTAssertEqual(sender().quitApp(app, force: true), .sent(pinned: true))
        XCTAssertEqual(kernel.quitsAsked.last, FakeActivityKernel.Quit(pid: 700, force: true))
        XCTAssertNil(kernel.process(700), "Force Quit ended it")
        XCTAssertEqual(sender().quitApp(app, force: false), .ended(now: nil), "gone: nothing asked")
        XCTAssertEqual(kernel.quitsAsked.count, 2)
    }

    /// The refusals and the gate, before any call: launchd, Overterm, a
    /// helper, another user's, a setuid program the user started, and in
    /// a guarded run what isn't the run's own — a Quit and a Force Quit
    /// alike.
    func testAQuitsRefusalsMakeNoCall() {
        mac()
        add(710, parent: 1, uid: 0, realUID: 501, name: "AcmeRoot")
        add(711, parent: 1, uid: 0, name: "GlobexRoot")
        for pid: pid_t in [700, 710, 711, 220] { kernel.app(pid) }
        add(700, parent: 1, name: "Acme")
        kernel.resetCounts()
        for force in [false, true] {
            XCTAssertEqual(sender().quitApp(target(1), force: force), .refused(.system))
            XCTAssertEqual(sender().quitApp(ActivitySignalTarget(app, path: nil), force: force), .refused(.overterm))
            XCTAssertEqual(sender().quitApp(target(220), force: force), .refused(.helper))
            XCTAssertEqual(sender().quitApp(target(710), force: force), .refused(.notYours))
            XCTAssertEqual(sender().quitApp(target(711), force: force), .refused(.notYours))
            XCTAssertEqual(sender(guards: true).quitApp(target(700), force: force), .refused(.gate))
        }
        XCTAssertEqual(touched + kernel.count("quit"), 0, "refused before any call")
        let gate = ActivitySignalGate(guards: true)
        gate.register(target(700).identity)
        XCTAssertEqual(sender(gate: gate).quitApp(target(700), force: false), .sent(pinned: true), "the run's own")
    }

    /// D-23's fallback: what LaunchServices doesn't list as an app, or an
    /// app that can't be asked, is sent the signal its verb equals by its
    /// token — SIGTERM for Quit, SIGKILL for Force Quit; a stopped one
    /// continued after a TERM.
    func testAQuitThatCantBeAskedIsItsSignalByToken() {
        mac()
        let plain = add(720, parent: 1, name: "acme-tool")
        let stuck = add(721, parent: 1, status: SSTOP, name: "Acme")
        kernel.app(721, asked: false)
        XCTAssertEqual(sender().quitApp(plain, force: false), .sent(pinned: true))
        XCTAssertEqual(sender().quitApp(stuck, force: false), .sent(pinned: true))
        XCTAssertEqual(sender().quitApp(stuck, force: true), .sent(pinned: true))
        XCTAssertEqual(
            kernel.sent,
            [
                FakeActivityKernel.Sent(pid: 720, signal: SIGTERM, pinned: true), FakeActivityKernel.Sent(pid: 721, signal: SIGTERM, pinned: true),
                FakeActivityKernel.Sent(pid: 721, signal: SIGCONT, pinned: true), FakeActivityKernel.Sent(pid: 721, signal: SIGKILL, pinned: true),
            ])
        XCTAssertEqual(kernel.quitsAsked, [])
    }

    /// The pid reused since it was listed, the app exec'd since, or
    /// between the token and the ask (the kernel's executable check):
    /// nothing asked of what holds the pid now. Without a token a Quit is
    /// a single Stop, which may go by its pid; a Force Quit never does.
    func testAQuitNeedsTheListedApp() {
        mac()
        let listed = add(730, parent: 1, name: "Acme")
        kernel.app(730)
        add(730, start: 9_000_000, parent: 1, name: "Globex")
        XCTAssertEqual(sender().quitApp(listed, force: false), .ended(now: "Globex"))
        let app = add(731, parent: 1, name: "Acme")
        kernel.app(731)
        kernel.exec(731, path: "/opt/acme/bin/acme-updater", name: "acme-updater")
        XCTAssertEqual(sender().quitApp(app, force: false), .ranAnotherProgram(path: "/opt/acme/bin/acme-updater"))
        let racing = add(732, parent: 1, name: "Acme")
        kernel.app(732)
        let fake = kernel
        fake.onCall { call in
            if call == "quit" { fake.exec(732, path: "/opt/acme/bin/acme-updater", name: "acme-updater") }
        }
        XCTAssertEqual(sender().quitApp(racing, force: true), .ranAnotherProgram(path: "/opt/acme/bin/acme-updater"))
        kernel.onCall(nil)
        XCTAssertEqual(kernel.quitsAsked, [], "never asked of another")
        XCTAssertEqual(kernel.sent, [])
        let unpinned = add(733, parent: 1, name: "Acme")
        kernel.app(733)
        kernel.refuseTokens(true)
        XCTAssertEqual(sender().quitApp(unpinned, force: true), .refused(.unpinned))
        XCTAssertEqual(sender().quitApp(unpinned, force: false), .sent(pinned: false))
        XCTAssertEqual(kernel.sent, [FakeActivityKernel.Sent(pid: 733, signal: SIGTERM, pinned: false)])
    }

    /// A launcher that exec'd a runtime: LaunchServices names the bundle's
    /// executable, the token the image it runs. The token still names the
    /// listed image, so it is sent its verb's signal by it — never said to
    /// have ended while it runs.
    func testAnAppRunningAnotherImageThanItsBundlesIsSignalledByToken() {
        mac()
        let app = add(740, parent: 1, name: "java", path: "/opt/acme/runtime/bin/java")
        kernel.app(740, executable: "/Applications/Acme.app/Contents/MacOS/Acme")
        XCTAssertEqual(sender().quitApp(app, force: false), .sent(pinned: true))
        XCTAssertEqual(sender().quitApp(app, force: true), .sent(pinned: true))
        XCTAssertEqual(kernel.quitsAsked, [], "LaunchServices' app isn't the token's image: not asked")
        XCTAssertEqual(
            kernel.sent,
            [FakeActivityKernel.Sent(pid: 740, signal: SIGTERM, pinned: true), FakeActivityKernel.Sent(pid: 740, signal: SIGKILL, pinned: true)])
    }

    /// A stopped app asked to Quit is continued right after (6.10 step 7):
    /// its Apple Event waits in a stopped process otherwise. A Force Quit
    /// isn't; a traced one isn't.
    func testAStoppedAppAskedToQuitIsContinued() {
        mac()
        let stopped = add(750, parent: 1, status: SSTOP, name: "Acme")
        kernel.app(750)
        XCTAssertEqual(sender().quitApp(stopped, force: false), .sent(pinned: true))
        XCTAssertEqual(kernel.quitsAsked, [FakeActivityKernel.Quit(pid: 750, force: false)])
        XCTAssertEqual(kernel.sent, [FakeActivityKernel.Sent(pid: 750, signal: SIGCONT, pinned: true)])
        XCTAssertEqual(kernel.process(750)?.isStopped, false)
        let traced = add(751, parent: 1, status: SSTOP, flags: .traced, name: "Globex")
        kernel.app(751)
        let forced = add(752, parent: 1, status: SSTOP, name: "Acme")
        kernel.app(752)
        XCTAssertEqual(sender().quitApp(traced, force: false), .sent(pinned: true))
        XCTAssertEqual(sender().quitApp(forced, force: true), .sent(pinned: true))
        XCTAssertEqual(kernel.sent.count, 1, "a traced one and a Force Quit aren't continued")
    }

    /// No executable to be read — through the token nor listed: the app
    /// isn't asked by its bare pid; its signal goes by the token.
    func testAQuitWithNoExecutableIsNeverAskedByPid() {
        mac()
        var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 760, start: 760_000, parent: 1, name: "Acme"))
        process.name = "Acme"
        process.path = nil
        kernel.add(process)
        kernel.app(760)
        let unread = ActivitySignalTarget(ActivityProcessID(pid: 760, start: 760_000), path: nil)
        kernel.resetCounts()
        XCTAssertEqual(sender().quitApp(unread, force: false), .sent(pinned: true))
        XCTAssertEqual(kernel.count("quit"), 0, "never asked by a bare pid")
        XCTAssertEqual(kernel.quitsAsked, [])
        XCTAssertEqual(kernel.sent, [FakeActivityKernel.Sent(pid: 760, signal: SIGTERM, pinned: true)])
    }

    /// The real kernel's Quit makes the gate's check itself: the test's own
    /// child, not registered, is asked nothing — EPERM, no call.
    func testTheRealKernelsQuitKeepsToTheRunsOwn() throws {
        let child = try TestChild("/bin/sleep", ["30"])
        defer { child.stop() }
        let real = LiveActivityKernel()
        XCTAssertEqual(real.quitApp(pid: child.pid, executable: "/bin/sleep", force: false), EPERM)
        XCTAssertEqual(real.quitApp(pid: child.pid, executable: "/bin/sleep", force: true), EPERM)
        XCTAssertEqual(real.quitApp(pid: 1, executable: nil, force: true), EPERM)
        XCTAssertEqual(real.quitApp(pid: getpid(), executable: nil, force: true), EPERM)
        XCTAssertNotNil(real.process(child.pid), "still running")
        // Registered, a plain process is no app LaunchServices lists: the
        // signal path's fallback takes it, by its token.
        own(child.identity)
        XCTAssertEqual(real.quitApp(pid: child.pid, executable: "/bin/sleep", force: false), ENOENT)
        XCTAssertEqual(real.quitApp(pid: child.pid, executable: nil, force: true), ENOENT, "no executable to hold it to: nothing asked")
        let target = ActivitySignalTarget(child.identity, path: real.path(of: child.pid))
        XCTAssertEqual(ProcessSignals(kernel: real).quitApp(target, force: false), .sent(pinned: true))
        XCTAssertNotNil(child.exited(), "ended by the SIGTERM it fell back to")
    }

    // MARK: Priority (6.10's Run in Background, Lower Priority)

    /// Run in Background, Normally and a nice raised: checked as a signal
    /// is — the token first, the identity through it — then `setpriority`
    /// by the pid. A nice is raised only: no higher than it is refused with
    /// no call; the refusals, the gate and a helper with none either.
    func testPriorityIsSetCheckedAsASignalIs() {
        mac()
        let job = target(400)
        let signals = sender()
        XCTAssertEqual(signals.setPriority(.background, of: job), .sent(pinned: true))
        XCTAssertEqual(signals.setPriority(.normal, of: job), .sent(pinned: true))
        XCTAssertEqual(signals.setPriority(.nice(5), of: job), .sent(pinned: true))
        XCTAssertEqual(kernel.process(400)?.nice, 5)
        XCTAssertEqual(
            kernel.priorities,
            [.init(pid: 400, change: .background), .init(pid: 400, change: .normal), .init(pid: 400, change: .nice(5))])
        kernel.resetCounts()
        XCTAssertEqual(signals.setPriority(.nice(5), of: job), .refused(.niceDown), "upward only")
        XCTAssertEqual(signals.setPriority(.nice(1), of: job), .refused(.niceDown))
        XCTAssertEqual(kernel.count("priority"), 0, "nothing asked of the kernel")
        XCTAssertEqual(signals.setPriority(.nice(20), of: job), .sent(pinned: true))

        kernel.resetCounts()
        XCTAssertEqual(signals.setPriority(.background, of: target(1)), .refused(.system))
        XCTAssertEqual(signals.setPriority(.background, of: ActivitySignalTarget(app, path: nil)), .refused(.overterm))
        XCTAssertEqual(signals.setPriority(.background, of: target(220)), .refused(.helper))
        XCTAssertEqual(signals.setPriority(.nice(10), of: target(200)), .refused(.notYours), "a setuid login")
        XCTAssertEqual(sender(guards: true).setPriority(.background, of: target(500)), .refused(.gate))
        XCTAssertEqual(kernel.count("priority") + kernel.count("token"), 0, "refused before any call")
        XCTAssertEqual(signals.setPriority(.background, of: target(500)), .sent(pinned: true), "elsewhere, the gate off")
    }

    /// A reused pid, an exec, no token: nothing set.
    func testPriorityNeedsTheListedProcessPinned() {
        mac()
        let job = target(400)
        add(400, start: 9_000_000, parent: 300, name: "globex-tool")
        kernel.resetCounts()
        XCTAssertEqual(sender().setPriority(.background, of: job), .ended(now: "globex-tool"))
        XCTAssertEqual(kernel.count("priority"), 0)

        let server = add(410, parent: 300, name: "acme-server")
        kernel.exec(410, path: "/opt/acme/bin/acme-other", name: "acme-other")
        XCTAssertEqual(sender().setPriority(.nice(5), of: server), .ranAnotherProgram(path: "/opt/acme/bin/acme-other"))
        XCTAssertEqual(kernel.count("priority"), 0)

        let plain = add(420, parent: 300, name: "acme-build")
        kernel.refuseTokens(true)
        XCTAssertEqual(sender().setPriority(.background, of: plain), .refused(.unpinned), "only a single Stop goes by the pid")
        XCTAssertEqual(kernel.count("priority"), 0)
    }

    /// What a sheet names it as.
    func testThePrioritysCommand() {
        XCTAssertEqual(ActivityPriorityChange.nice(10).command(for: 4242), "renice 10 -p 4242")
        XCTAssertEqual(ActivityPriorityChange.background.command(for: 4242), "taskpolicy -b -p 4242")
        XCTAssertEqual(ActivityPriorityChange.normal.command(for: 4242), "taskpolicy -B -p 4242")
    }

    /// The nine, by name; never 0 or a number of the caller's.
    func testTheSignalsAreNine() {
        XCTAssertEqual(ActivitySignal.allCases.map(\.rawValue), ["HUP", "INT", "QUIT", "TERM", "USR1", "USR2", "KILL", "STOP", "CONT"])
        XCTAssertEqual(Set(ActivitySignal.allCases.map(\.number)), [SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGUSR1, SIGUSR2, SIGKILL, SIGSTOP, SIGCONT])
        XCTAssertTrue(ActivitySignal.allCases.allSatisfy { $0.number > 0 })
        XCTAssertEqual(ActivitySignal.term.command(for: 4242), "kill -TERM 4242")
    }

    // MARK: The real kernel, the test's own children

    /// A unit test is guarded: the app's gate is on.
    func testAUnitTestIsGuarded() {
        XCTAssertTrue(AppEnvironment.guardsSignals)
        XCTAssertTrue(ActivitySignalGate.shared.guards)
    }

    /// The token of a child of the test's (3.9): its pid, the user, the
    /// executable — `proc_signal_with_audittoken` there on this macOS. After
    /// an exec the old token names no path and answers ESRCH (3) as its
    /// value, while a fresh one carries the pid's next version; once the
    /// child has ended — a zombie, its identity kept, so the gate lets the
    /// call through — its token answers ESRCH too. Reaped, nothing holds
    /// its pid: the gate answers ESRCH and nothing is called.
    func testARealChildsTokenAcrossAnExecAndAnEnd() throws {
        let (child, _, goOn) = try execingChild()
        defer { child.stop() }
        own(child.identity)
        let real = LiveActivityKernel()
        XCTAssertTrue(real.signalsByToken, "proc_signal_with_audittoken on this macOS")
        let before = try XCTUnwrap(real.auditToken(of: child.pid))
        XCTAssertEqual(before.pid, child.pid)
        XCTAssertEqual(before.effectiveUID, getuid())
        XCTAssertEqual(before.realUID, getuid())
        XCTAssertEqual(real.path(of: before), "/bin/bash")
        XCTAssertEqual(real.process(child.pid)?.identity, child.identity)
        goOn()
        XCTAssertNil(real.path(of: before), "the image it named is gone")
        XCTAssertEqual(real.signal(SIGCONT, by: before), ESRCH)
        let after = try XCTUnwrap(real.auditToken(of: child.pid))
        XCTAssertNotEqual(after.version, before.version, "an exec moves the pid's version on")
        XCTAssertEqual(real.path(of: after), "/bin/sleep")
        XCTAssertEqual(real.process(child.pid)?.identity, child.identity, "the same process")
        child.killUnreaped()
        XCTAssertTrue(TestChild.eventually { real.process(child.pid)?.isZombie == true }, "ended, not reaped")
        XCTAssertEqual(real.signal(SIGCONT, by: after), ESRCH, "its image gone with it")
        child.stop()
        XCTAssertEqual(real.signal(SIGCONT, by: after), ESRCH, "reaped: nothing holds its pid")
        XCTAssertNil(real.process(-1))
    }

    /// A setuid program the test started (`top`, root's to reads, the
    /// user's to `kill(2)`): refused by its effective uid with no token
    /// taken and nothing sent — though `kill(child, 0)`, signal 0 alone,
    /// says the kernel would let a signal through. It samples until its
    /// output, a pipe the test never reads, closes: alive for every check,
    /// then ended by its own SIGPIPE at its next sample.
    func testASetuidChildIsRefusedBeforeAnyCall() throws {
        var ends: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&ends), 0)
        let null = open("/dev/null", O_WRONLY)
        defer { close(null) }
        let spawned = ProcessGroup.spawn(URL(fileURLWithPath: "/usr/bin/top"), ["-l", "0", "-s", "1", "-n", "0"], [:], stdout: ends[1], stderr: null)
        close(ends[1])
        guard case .success(let pid) = spawned else {
            close(ends[0])
            return XCTFail("top didn't start")
        }
        defer { endSetuid(pid, output: ends[0]) }
        let real = LiveActivityKernel()
        XCTAssertTrue(TestChild.eventually { real.process(pid)?.effectiveUID == 0 }, "running setuid")
        let process = try XCTUnwrap(real.process(pid))
        XCTAssertEqual(process.realUID, getuid())
        let recorder = RecordingKernel(own: [process.identity])
        own(process.identity)
        let signals = ProcessSignals(kernel: recorder)
        for signal in ActivitySignal.allCases {
            XCTAssertEqual(
                signals.send(signal, to: ActivitySignalTarget(process.identity, path: "/usr/bin/top"), alone: true), .refused(.notYours), "\(signal)")
        }
        let top = ActivitySignalTarget(process.identity, path: "/usr/bin/top")
        XCTAssertEqual(signals.setPriority(.background, of: top), .refused(.notYours), "nor reniced")
        XCTAssertEqual(signals.setPriority(.nice(20), of: top), .refused(.notYours))
        XCTAssertEqual(recorder.calls, [], "no token, no signal")
        XCTAssertEqual(kill(pid, 0), 0, "kill(2) would let it through")
        XCTAssertNil(real.auditToken(of: pid), "and no token comes for it (KERN_FAILURE)")
        XCTAssertEqual(real.process(pid)?.identity, process.identity, "alive throughout")
    }

    /// Closes the setuid child's output, so its next write ends it, and
    /// reaps it. One that outlived that by far — the test's own — is ended.
    private func endSetuid(_ pid: pid_t, output: Int32) {
        close(output)
        var status: Int32 = 0
        if !TestChild.eventually(30, { waitpid(pid, &status, WNOHANG) == pid }) {
            XCTFail("top didn't end at its closed output")
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
    }

    /// bash, waiting for a line before it execs sleep: its identity taken
    /// as bash, then the pipe written when the test says.
    private func execingChild() throws -> (TestChild, ActivitySignalTarget, goOn: @Sendable () -> Void) {
        var ends: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&ends), 0)
        let child = try TestChild("/bin/bash", ["-c", "read line; exec /bin/sleep 30"], stdin: ends[0])
        close(ends[0])
        let write = ends[1]
        let pid = child.pid
        let real = LiveActivityKernel()
        XCTAssertTrue(TestChild.eventually { real.path(of: pid) == "/bin/bash" }, "listed as bash")
        let target = ActivitySignalTarget(child.identity, path: real.path(of: pid))
        let goOn: @Sendable () -> Void = {
            _ = "go\n".withCString { Darwin.write(write, $0, 3) }
            close(write)
            _ = TestChild.eventually { real.path(of: pid) == "/bin/sleep" }
        }
        return (child, target, goOn)
    }

    /// A child that execs `/bin/sleep` after its identity was taken: the
    /// token names sleep's image, not the listed bash — "it ran another
    /// program", nothing sent.
    func testARealChildThatExecsAfterItWasListed() throws {
        let (child, target, goOn) = try execingChild()
        defer { child.stop() }
        goOn()
        XCTAssertEqual(LiveActivityKernel().path(of: child.pid), "/bin/sleep")
        let recorder = RecordingKernel(own: [child.identity])
        own(child.identity)
        XCTAssertEqual(ProcessSignals(kernel: recorder).send(.term, to: target, alone: true), .ranAnotherProgram(path: "/bin/sleep"))
        XCTAssertEqual(recorder.calls.filter { $0 != "token" }, [], "nothing sent")
        XCTAssertEqual(LiveActivityKernel().process(child.pid)?.identity, child.identity, "the same process")
    }

    /// One that execs between the check and the send: the old token
    /// answers ESRCH (3) as its value, the process lives on, and that is
    /// told apart from an end — "it ran another program".
    func testARealChildThatExecsBetweenTheTokenAndTheSend() throws {
        let (child, target, goOn) = try execingChild()
        defer { child.stop() }
        let recorder = RecordingKernel(own: [child.identity])
        recorder.beforeSend = goOn
        own(child.identity)
        XCTAssertEqual(ProcessSignals(kernel: recorder).send(.term, to: target, alone: true), .ranAnotherProgram(path: "/bin/sleep"))
        XCTAssertEqual(recorder.answers, [ESRCH], "the token named bash's image, gone: nothing reached sleep")
        XCTAssertEqual(recorder.calls, ["token", "signal", "token"], "a fresh token told the exec")
    }

    /// A child that ended: a zombie first, then reaped and gone — ended
    /// both times, with no token and nothing sent.
    func testARealDeadChild() throws {
        let child = try TestChild("/usr/bin/true", [])
        defer { child.stop() }
        let real = LiveActivityKernel()
        let target = ActivitySignalTarget(child.identity, path: "/usr/bin/true")
        let recorder = RecordingKernel(own: [child.identity])
        own(child.identity)
        let signals = ProcessSignals(kernel: recorder)
        XCTAssertTrue(TestChild.eventually { real.process(child.pid)?.isZombie == true }, "exited, not reaped")
        XCTAssertEqual(signals.send(.term, to: target, alone: true), .ended(now: nil))
        XCTAssertNotNil(child.exited())
        guard case .ended = signals.send(.kill, to: target, alone: true) else { return XCTFail("reaped: ended") }
        XCTAssertEqual(recorder.calls, [])
    }

    /// A plain child stopped, continued, and ended by its token — stopped
    /// again first, so the TERM's continue after it is what lets it end.
    func testARealChildStoppedContinuedAndEndedByToken() throws {
        let child = try TestChild("/bin/sleep", ["30"])
        defer { child.stop() }
        let real = LiveActivityKernel()
        own(child.identity)
        let signals = ProcessSignals(kernel: RecordingKernel(own: [child.identity]))
        let target = ActivitySignalTarget(child.identity, path: real.path(of: child.pid))
        XCTAssertEqual(target.path, "/bin/sleep")

        XCTAssertEqual(signals.send(.stop, to: target, alone: false), .sent(pinned: true))
        XCTAssertTrue(TestChild.eventually { real.process(child.pid)?.isStopped == true }, "T")
        XCTAssertEqual(signals.send(.cont, to: target, alone: false), .sent(pinned: true))
        XCTAssertTrue(TestChild.eventually { real.process(child.pid)?.isStopped == false }, "running again")
        XCTAssertEqual(signals.send(.stop, to: target, alone: false), .sent(pinned: true))
        XCTAssertTrue(TestChild.eventually { real.process(child.pid)?.isStopped == true })
        XCTAssertEqual(signals.send(.term, to: target, alone: true), .sent(pinned: true))
        let status = try XCTUnwrap(child.exited(), "continued, it acted on the TERM")
        XCTAssertEqual(status & 0x7f, SIGTERM, "ended by the TERM")
    }

    /// A real child of the test's: put in the background and back, and its
    /// nice raised one step then to 20 — never lowered: the kernel would
    /// refuse, and nothing is asked of it. Its nice starts at the test
    /// process's own (a shell's background job runs at 5, zsh's
    /// `bg_nice`). The real kernel's own call keeps to the run's own, as its
    /// sends do.
    func testARealChildsPriority() throws {
        let child = try TestChild("/bin/sleep", ["30"])
        defer { child.stop() }
        let real = LiveActivityKernel()
        let start = Int32(try XCTUnwrap(real.process(child.pid)).nice)
        try XCTSkipIf(start >= ActivityPriorityChange.lowest - 1, "the test runs at nice \(start): no room to raise it")
        XCTAssertEqual(real.setPriority(.nice(start + 1), pid: child.pid), EPERM, "not the app's gate's")
        XCTAssertEqual(real.process(child.pid).map { Int32($0.nice) }, start)
        own(child.identity)
        let recorder = RecordingKernel(own: [child.identity])
        let signals = ProcessSignals(kernel: recorder)
        let target = ActivitySignalTarget(child.identity, path: real.path(of: child.pid))
        XCTAssertEqual(signals.setPriority(.background, of: target), .sent(pinned: true))
        XCTAssertEqual(signals.setPriority(.normal, of: target), .sent(pinned: true))
        XCTAssertEqual(signals.setPriority(.nice(start + 1), of: target), .sent(pinned: true))
        XCTAssertEqual(real.process(child.pid).map { Int32($0.nice) }, start + 1)
        XCTAssertEqual(signals.setPriority(.nice(start), of: target), .refused(.niceDown))
        XCTAssertEqual(signals.setPriority(.nice(20), of: target), .sent(pinned: true))
        XCTAssertEqual(real.process(child.pid)?.nice, 20)
        XCTAssertEqual(recorder.calls.filter { $0 == "priority" }.count, 4)
        XCTAssertEqual(recorder.answers, [0, 0, 0, 0])
    }

    /// A real process that isn't the test's — the process that started the
    /// runner — asked about with the app's own gate: refused before any
    /// call. The kernel here sends nothing whatever it is asked, so not
    /// even a broken gate could signal it.
    func testTheGateRefusesARealProcessThatIsntTheTests() throws {
        let real = LiveActivityKernel()
        let parent = try XCTUnwrap(real.process(getppid()))
        try XCTSkipUnless(parent.pid > 1 && parent.isOwn(by: getuid()), "the runner's parent is launchd or another user's")
        let recorder = RecordingKernel(own: [])
        let signals = ProcessSignals(kernel: recorder)
        XCTAssertEqual(signals.app.pid, getpid())
        let target = ActivitySignalTarget(parent.identity, path: real.path(of: parent.pid))
        for signal in ActivitySignal.allCases {
            // A Bool, so a failure prints nothing of a process not the test's.
            XCTAssertTrue(signals.send(signal, to: target, alone: true) == .refused(.gate), "refused by the gate: \(signal)")
        }
        XCTAssertTrue(signals.setPriority(.background, of: target) == .refused(.gate), "nor reniced")
        XCTAssertTrue(signals.setPriority(.nice(20), of: target) == .refused(.gate))
        XCTAssertEqual(recorder.calls, [], "no token, no signal")
        // And the test's own child, unregistered: its process's child, so a helper's.
        let child = try TestChild("/bin/sleep", ["30"])
        defer { child.stop() }
        XCTAssertEqual(signals.send(.cont, to: ActivitySignalTarget(child.identity, path: "/bin/sleep"), alone: true), .refused(.helper))
        XCTAssertEqual(recorder.calls, [])
    }

    /// The real kernel's sends make the gate's check themselves, with this
    /// process as the app and the app's gate (6.10 step 11): the test's own
    /// child, not registered there, gets nothing from them — called
    /// directly, by its token or its pid, or through a `ProcessSignals`
    /// handed a gate of its own that registered it. Registered, it is
    /// stopped and continued. Only the test's own child is ever named.
    func testTheRealKernelsSendsKeepToTheRunsOwn() throws {
        let child = try TestChild("/bin/sleep", ["30"])
        defer { child.stop() }
        let real = LiveActivityKernel()
        let token = try XCTUnwrap(real.auditToken(of: child.pid))
        XCTAssertEqual(real.signal(SIGSTOP, by: token), EPERM, "not the app's gate's")
        XCTAssertEqual(real.signal(SIGSTOP, pid: child.pid), EPERM)
        let wide = ActivitySignalGate(guards: true)
        wide.register(child.identity)
        let target = ActivitySignalTarget(child.identity, path: real.path(of: child.pid))
        XCTAssertEqual(ProcessSignals(kernel: real, gate: wide).send(.stop, to: target, alone: false), .failed(EPERM), "a gate of its own widens nothing")
        own(child.identity)
        XCTAssertEqual(real.signal(SIGSTOP, by: token), 0)
        XCTAssertTrue(TestChild.eventually { real.process(child.pid)?.isStopped == true }, "T")
        XCTAssertEqual(real.signal(SIGCONT, pid: child.pid), 0)
        XCTAssertTrue(TestChild.eventually { real.process(child.pid)?.isStopped == false }, "running again")
    }

    /// A real helper's group: a `ManagedProcess` of the test's whose shell
    /// let a sleep go — launchd's child now, still in the group — is a
    /// helper's while it is open, refused with no token and no signal
    /// though its lineage says elsewhere; closed, its group is no helper's,
    /// and the sleep ends with the group.
    func testAMemberLetGoByAnOpenManagedProcessIsAHelpers() async throws {
        let launch = ManagedProcess.Launch(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "(/bin/sleep 30 &); echo ready; exec /bin/sleep 31"],
            environment: TestChild.cleanEnvironment, readiness: .line { $0 == "ready" }, timeout: 10)
        let managed = try await ManagedProcess.start(launch)
        defer { managed.close(grace: 0) }
        let real = LiveActivityKernel()
        var found: ActivityProcess?
        let letGo = TestChild.eventually {
            found = real.processes()?.first { $0.group == managed.pid && $0.parentPID == 1 }
            return found != nil
        }
        XCTAssertTrue(letGo, "launchd's child now, in the group")
        let member = try XCTUnwrap(found)
        XCTAssertTrue(ActivityHelperGroups.now().contains(managed.pid))
        let recorder = RecordingKernel(own: [member.identity])
        let signals = ProcessSignals(kernel: recorder)
        XCTAssertEqual(signals.lineage(of: member), .elsewhere)
        XCTAssertEqual(signals.send(.term, to: ActivitySignalTarget(member.identity, path: "/bin/sleep"), alone: true), .refused(.helper))
        XCTAssertEqual(recorder.calls, [], "no token, no signal")
        managed.close(grace: 0)
        XCTAssertFalse(ActivityHelperGroups.now().contains(managed.pid), "closed")
        XCTAssertTrue(TestChild.eventually { real.process(member.pid)?.identity != member.identity }, "ended with its group")
    }

    /// An apply's group is a helper's from when its run is made — started,
    /// or found again after a relaunch — until the run ends or lets it go;
    /// another run of the same group keeps it. The marker's pid is past any
    /// this Mac gives (`PID_MAX`), so nothing real is named, nor any group
    /// read at its end.
    @MainActor func testAnAppliesGroupIsAHelpersWhileARunHasIt() {
        let group: pid_t = 1_000_001
        func run() -> TerraformApplyRun {
            let marker = TerraformApplyMarker(
                pid: group, started: 1, executable: TerraformApplyLaunch.shell, checkout: "/acme", root: "", name: "acme", workspace: "default",
                rootClass: "development", identity: nil, at: TerraformApplyMarker.now)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ot-apply-\(UUID().uuidString)")
            return TerraformApplyRun(marker: marker, folder: folder, plan: nil, identity: nil, key: "acme", reattached: true, child: nil)
        }
        let first = run()
        XCTAssertTrue(ActivityHelperGroups.now().contains(group), "made")
        do {
            let second = run()
            first.detach()
            XCTAssertTrue(ActivityHelperGroups.now().contains(group), "let go by one, kept by the other")
            withExtendedLifetime(second) {}
        }
        XCTAssertFalse(ActivityHelperGroups.now().contains(group), "the other gone")
        let ending = run()
        XCTAssertTrue(ActivityHelperGroups.now().contains(group))
        ending.ended(status: 0, stderr: "")
        XCTAssertFalse(ActivityHelperGroups.now().contains(group), "ended")
    }
}

/// The real kernel's reads passed through; the calls that touch a process
/// — a token taken, a signal sent — recorded, and a signal passed on only
/// to the test's own children (`own`, by pid and start, read again before
/// each): whatever `ProcessSignals` asked, nothing else could be reached.
private final class RecordingKernel: ActivityKernel, @unchecked Sendable {
    private let real = LiveActivityKernel()
    private let lock = NSLock()
    private let own: Set<ActivityProcessID>
    private var recorded: [String] = []
    private var results: [Int32] = []
    /// Runs before a signal by token is passed on.
    var beforeSend: (@Sendable () -> Void)?

    init(own: Set<ActivityProcessID>) { self.own = own }

    /// "token", "signal", "kill", in order.
    var calls: [String] { lock.withLock { recorded } }
    /// What each signal passed on answered.
    var answers: [Int32] { lock.withLock { results } }

    private func record(_ call: String) { lock.withLock { recorded.append(call) } }

    private func isOwn(_ pid: pid_t) -> Bool { real.process(pid).map { own.contains($0.identity) } ?? false }

    var uid: uid_t { real.uid }
    func uptime() -> UInt64 { real.uptime() }
    func processes() -> [ActivityProcess]? { real.processes() }
    func usage(of pid: pid_t) -> ActivityUsage? { real.usage(of: pid) }
    func name(of pid: pid_t) -> String? { real.name(of: pid) }
    func path(of pid: pid_t) -> String? { real.path(of: pid) }
    func codeSigningStatus(of pid: pid_t) -> CodeSigningAnswer { real.codeSigningStatus(of: pid) }
    func securityCodeSigning(of pid: pid_t) -> ActivityCodeSigning? { real.securityCodeSigning(of: pid) }
    func argumentsLength(of pid: pid_t) -> Int? { real.argumentsLength(of: pid) }
    func readArguments(of pid: pid_t, into region: UnsafeMutableRawBufferPointer) -> Int? { real.readArguments(of: pid, into: region) }
    func descriptors(of pid: pid_t) -> [proc_fdinfo]? { real.descriptors(of: pid) }
    func socket(of pid: pid_t, descriptor: Int32) -> socket_fdinfo? { real.socket(of: pid, descriptor: descriptor) }
    func workingDirectory(of pid: pid_t) -> String? { real.workingDirectory(of: pid) }
    func vnodePath(of pid: pid_t, descriptor: Int32) -> String? { real.vnodePath(of: pid, descriptor: descriptor) }
    func process(_ pid: pid_t) -> ActivityProcess? { real.process(pid) }
    func groupMembers(_ group: pid_t, limit: Int) -> [pid_t]? { real.groupMembers(group, limit: limit) }
    func path(of token: ActivityAuditToken) -> String? { real.path(of: token) }
    var signalsByToken: Bool { real.signalsByToken }

    func auditToken(of pid: pid_t) -> ActivityAuditToken? {
        record("token")
        return real.auditToken(of: pid)
    }

    func signal(_ signal: Int32, by token: ActivityAuditToken) -> Int32 {
        record("signal")
        guard isOwn(token.pid) else { return EPERM }
        beforeSend?()
        let answer = real.signal(signal, by: token)
        lock.withLock { results.append(answer) }
        return answer
    }

    func signal(_ signal: Int32, pid: pid_t) -> Int32 {
        record("kill")
        guard isOwn(pid) else { return EPERM }
        let answer = real.signal(signal, pid: pid)
        lock.withLock { results.append(answer) }
        return answer
    }

    func session(of pid: pid_t) -> pid_t? { real.session(of: pid) }

    /// Passed on only when every member the group has now is the test's own.
    func signal(_ signal: Int32, group: pid_t) -> Int32 {
        record("killpg")
        guard let members = real.groupMembers(group, limit: ProcessSignals.groupLimit), !members.isEmpty, members.allSatisfy(isOwn) else {
            return EPERM
        }
        let answer = real.signal(signal, group: group)
        lock.withLock { results.append(answer) }
        return answer
    }

    func setPriority(_ change: ActivityPriorityChange, pid: pid_t) -> Int32 {
        record("priority")
        guard isOwn(pid) else { return EPERM }
        let answer = real.setPriority(change, pid: pid)
        lock.withLock { results.append(answer) }
        return answer
    }

    func quitApp(pid: pid_t, executable: String?, force: Bool) -> Int32 {
        record("quit")
        guard isOwn(pid) else { return EPERM }
        let answer = real.quitApp(pid: pid, executable: executable, force: force)
        lock.withLock { results.append(answer) }
        return answer
    }
}
