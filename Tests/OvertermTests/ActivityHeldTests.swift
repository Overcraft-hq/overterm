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

/// What Activity stopped and put in the background (docs/design/activity/
/// analysis.md, 6.10, 3.9): kept by identity, resumed only as kept — a
/// Suspension whole from its root, a member alone —, let go once a census
/// read after the change says it ended or runs again, read now for the quit
/// question, and continued children first by Resume All. Over a fake Mac:
/// nothing real is signalled.
@MainActor
final class ActivityHeldTests: XCTestCase {
    private let kernel = FakeActivityKernel(uid: 501)
    private let app = ActivityProcessID(pid: 100, start: 100_000)

    private func add(_ pid: pid_t, parent: pid_t, status: Int32 = SSTOP, name: String) -> ActivitySignalTarget {
        var process = FakeActivityKernel.Process(
            record: FakeActivityKernel.record(pid: pid, start: UInt64(pid) * 1_000, parent: parent, status: status, name: name))
        process.path = "/opt/acme/bin/\(name)"
        kernel.add(process)
        return ActivitySignalTarget(ActivityProcessID(pid: pid, start: UInt64(pid) * 1_000), path: process.path)
    }

    private func signals() -> ProcessSignals {
        ProcessSignals(kernel: kernel, gate: ActivitySignalGate(guards: false), app: app, helperGroups: { [] })
    }

    private func stopped() -> (ActivityHeld, root: ActivitySignalTarget, child: ActivitySignalTarget, other: ActivitySignalTarget) {
        add(1, parent: 0, status: SRUN, name: "launchd")
        add(app.pid, parent: 1, status: SRUN, name: "Overterm")
        let root = add(500, parent: 1, name: "acme-runner")
        let child = add(501, parent: 500, name: "acme-worker")
        let other = add(600, parent: 1, name: "globex-batch")
        let held = ActivityHeld()
        let at = Date(timeIntervalSince1970: 1_000)
        held.suspended(root: root, name: "acme-runner", members: [root, child], names: [root.identity: "acme-runner", child.identity: "acme-worker"], at: at)
        held.suspended(root: other, name: "globex-batch", members: [other], names: [other.identity: "globex-batch"], at: at)
        return (held, root, child, other)
    }

    func testKeptByIdentityAndResumedAsKept() {
        let (held, root, child, other) = stopped()
        XCTAssertEqual(held.stoppedCount, 3)
        XCTAssertEqual(held.stopped, [root.identity, child.identity, other.identity])
        let now = Date(timeIntervalSince1970: 5_000)
        held.resumed([other.identity], at: now)
        XCTAssertEqual(held.recentlyResumed(now: now + 1), [other.identity], "a census begun before may still list it stopped")
        XCTAssertEqual(held.recentlyResumed(now: now + 3), [])
        held.suspended(root: other, name: "globex-batch", members: [other], names: [other.identity: "globex-batch"])
        XCTAssertEqual(held.resumeTargets(for: root.identity), [root, child], "its root: the whole Suspension, parents first")
        XCTAssertEqual(held.resumeTargets(for: child.identity), [child], "a member: itself")
        XCTAssertEqual(held.resumeTargets(for: ActivityProcessID(pid: 500, start: 9)), [], "the pid alone is nobody's")
        XCTAssertEqual(held.name(of: child.identity), "acme-worker")
        held.resumed([child.identity])
        XCTAssertEqual(held.resumeTargets(for: root.identity), [root])
        held.resumed([root.identity])
        XCTAssertEqual(held.suspensions.map(\.id), [other.identity], "an empty Suspension goes")
        // Stopped again from here: one record each.
        held.suspended(root: other, name: "globex-batch", members: [other], names: [:])
        XCTAssertEqual(held.stoppedCount, 1)
    }

    /// Suspend sends the root alone first: one that isn't stopped — ended,
    /// exec'd, refused — stops nothing of its tree.
    func testSuspendStopsTheTreeOnlyOnceItsRootStopped() {
        add(1, parent: 0, status: SRUN, name: "launchd")
        add(app.pid, parent: 1, status: SRUN, name: "Overterm")
        let root = add(700, parent: 1, status: SRUN, name: "acme-runner")
        let child = add(701, parent: 700, status: SRUN, name: "acme-worker")
        kernel.remove(root.identity.pid)
        let none = ActivityHeld.stopTree([root, child], signals: signals())
        XCTAssertEqual(none.map(\.target), [root], "its root ended: only its answer")
        XCTAssertTrue(kernel.sent.isEmpty, "nothing of its tree was stopped")
        XCTAssertEqual(kernel.process(child.identity.pid)?.isStopped, false)
        let again = add(700, parent: 1, status: SRUN, name: "acme-runner")
        let both = ActivityHeld.stopTree([again, child], signals: signals())
        XCTAssertEqual(both.map(\.target), [again, child])
        XCTAssertEqual(kernel.sent.map(\.pid), [700, 701], "the root first, then its tree")
    }

    /// A Resume's button sends only what is still held now: one let go
    /// while its sheet was up — continued elsewhere — is left alone.
    func testAResumePlannedAgainAtItsButton() {
        let (held, root, child, other) = stopped()
        let listed = [root, child]
        held.resumed([child.identity])
        XCTAssertEqual(held.stillHeld(listed), [root])
        let all = Set([root, child, other].map(\.identity))
        XCTAssertEqual(held.stillHeld(listed: all).flatMap(\.members), [root, other])
        XCTAssertEqual(held.stillHeld(listed: [other.identity]).flatMap(\.members), [other], "only what the sheet listed")
    }

    /// A census read after the change lets go what ended, became a zombie,
    /// or runs again; one read before it — up to `settle` after — says
    /// nothing yet.
    func testPrunedOnlyByALaterCensus() {
        let (held, root, child, other) = stopped()
        let at = Date(timeIntervalSince1970: 1_000)
        kernel.update(child.identity.pid) { $0.record = FakeActivityKernel.record($0.record, status: SRUN) }
        kernel.remove(other.identity.pid)
        held.prune(at: at + 1) { self.kernel.process($0.pid) }
        XCTAssertEqual(held.stoppedCount, 3, "read before the stop could land")
        held.prune(at: at + 3) { self.kernel.process($0.pid) }
        XCTAssertEqual(held.stopped, [root.identity], "continued elsewhere, and ended: let go")
        // Its pid another process's now: let go too.
        add(500, parent: 1, name: "globex-other")
        kernel.update(500) { $0.record = FakeActivityKernel.record(FakeActivityKernel.record(pid: 500, start: 77, parent: 1), status: SSTOP) }
        held.prune(at: at + 4) { self.kernel.process($0.pid) }
        XCTAssertEqual(held.stoppedCount, 0)

        held.backgrounded(root.identity, at: at)
        held.prune(at: at + 4) { self.kernel.process($0.pid) }
        XCTAssertTrue(held.backgroundHere.isEmpty, "the background kept only while it lives")
    }

    /// The quit question counts what is still stopped now, and Resume and
    /// Quit continues each, children first, by its token.
    func testTheQuitQuestionAndResumeAll() {
        let (held, root, child, other) = stopped()
        kernel.update(other.identity.pid) { $0.record = FakeActivityKernel.record($0.record, status: SRUN) }
        let still = held.stillStopped(kernel: kernel)
        XCTAssertEqual(still, [root, child], "running again: not asked about")
        let question = ActivityHeld.quitQuestion(stopped: still.count)
        XCTAssertEqual(question?.title, "2 processes you suspended from Activity are still stopped")
        XCTAssertTrue(question?.detail.contains("Resume and Quit continues each first") == true)
        XCTAssertEqual(ActivityHeld.quitQuestion(stopped: 1)?.title, "A process you suspended from Activity is still stopped")
        XCTAssertNil(ActivityHeld.quitQuestion(stopped: 0))
        XCTAssertEqual(ActivityHeld.quitButtons, ["Resume and Quit", "Quit", "Cancel"])

        let failed = held.resumeAll(signals: signals())
        XCTAssertTrue(failed.isEmpty)
        XCTAssertEqual(kernel.sent.map(\.pid), [501, 500, 600], "children first, each Suspension")
        XCTAssertTrue(kernel.sent.allSatisfy { $0.signal == SIGCONT && $0.pinned })
        XCTAssertEqual(held.stoppedCount, 0)
        XCTAssertEqual(kernel.process(500)?.isStopped, false)
    }

    /// Resume All continues only what is still the process stopped: a pid
    /// taken again since is never sent anything.
    func testResumeAllKeepsToTheIdentities() {
        let (held, _, child, _) = stopped()
        kernel.remove(child.identity.pid)
        add(child.identity.pid, parent: 1, name: "globex-stranger")
        kernel.update(child.identity.pid) {
            $0.record = FakeActivityKernel.record(FakeActivityKernel.record(pid: child.identity.pid, start: 999_999, parent: 1), status: SSTOP)
        }
        _ = held.resumeAll(signals: signals())
        XCTAssertFalse(kernel.sent.contains { $0.pid == child.identity.pid }, "the stranger holding its pid is left stopped")
        XCTAssertEqual(kernel.process(child.identity.pid)?.isStopped, true)
    }

    /// Resume and Quit lets go only what continued or ended: one refused
    /// — no token to continue it by — stays held, and the quit asks again.
    func testWhatResumeAllCouldntContinueStaysHeld() {
        let (held, root, child, other) = stopped()
        kernel.refuseTokens(true)
        let failed = held.resumeAll(signals: signals())
        XCTAssertEqual(Set(failed.map(\.target)), [root, child, other])
        XCTAssertEqual(held.stoppedCount, 3, "still Activity's: not let go")
        XCTAssertTrue(kernel.sent.isEmpty)
        let question = ActivityHeld.notResumedQuestion(failed.map { (pid: $0.target.identity.pid, name: held.name(of: $0.target.identity), why: "refused") })
        XCTAssertEqual(question?.title, "3 processes you suspended couldn't be resumed")
        XCTAssertTrue(question?.detail.contains("pid 501 acme-worker: refused") == true, question?.detail ?? "")
        XCTAssertNil(ActivityHeld.notResumedQuestion([]))
        XCTAssertEqual(ActivityHeld.notResumedButtons, ["Don't Quit", "Quit Anyway"])
        kernel.refuseTokens(false)
        XCTAssertTrue(held.resumeAll(signals: signals()).isEmpty)
        XCTAssertEqual(held.stoppedCount, 0)
    }
}
