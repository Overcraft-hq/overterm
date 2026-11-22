import XCTest

@testable import Overterm
@testable import OvertermCore

final class SurfaceProcessesTests: XCTestCase {
    /// A git the app runs is its child too, and may start between two
    /// surfaces' logins: it must never be taken for a terminal's login.
    func testOnlyUnclaimedLoginsArePaired() {
        let children: [(pid: pid_t, start: UInt64, name: String)] = [
            (pid: 10, start: 1, name: "login"),
            (pid: 11, start: 2, name: "git"),
            (pid: 12, start: 3, name: "login"),
            (pid: 13, start: 4, name: "gh"),
            (pid: 14, start: 5, name: "login"),
        ]
        XCTAssertEqual(
            SurfaceProcesses.unclaimedLogins(children, claimed: [ActivityProcessID(pid: 10, start: 1)]),
            [ActivityProcessID(pid: 12, start: 3), ActivityProcessID(pid: 14, start: 5)])
        // Claimed by its identity: a login that took a claimed one's pid isn't it.
        XCTAssertEqual(
            SurfaceProcesses.unclaimedLogins([(pid: 10, start: 9, name: "login")], claimed: [ActivityProcessID(pid: 10, start: 1)]),
            [ActivityProcessID(pid: 10, start: 9)])
    }

    /// The app's children are the census's child map (docs/design/activity/
    /// analysis.md, 7.8): one read of the table, oldest first — a zombie
    /// `login` left out, so the next surface's never shifts onto it (7.10),
    /// and a process that started before the app did isn't its child, its
    /// parent's pid taken by the app since.
    func testTheChildrenAreTheCensussChildMap() {
        let kernel = FakeActivityKernel(uid: 501)
        func add(_ pid: pid_t, start: UInt64, parent: pid_t, uid: uid_t = 501, status: Int32 = SRUN, name: String) {
            kernel.add(
                FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: pid, start: start, parent: parent, uid: uid, status: status, name: name)))
        }
        add(1, start: 1, parent: 0, uid: 0, name: "launchd")
        add(1000, start: 1_000, parent: 1, name: "Overterm")
        add(1300, start: 3_000, parent: 1000, uid: 0, name: "login")
        add(1100, start: 2_000, parent: 1000, uid: 0, name: "login")
        add(1200, start: 2_500, parent: 1000, uid: 0, status: SZOMB, name: "login")
        add(1400, start: 3_500, parent: 1000, name: "git")
        add(900, start: 500, parent: 1000, name: "acme-orphan")
        let children = ProcessInspector.children(of: 1000, kernel: kernel)
        XCTAssertEqual(children.map(\.pid), [1100, 1300, 1400])
        XCTAssertEqual(children.map(\.name), ["login", "login", "git"])
        XCTAssertEqual(children.map(\.start), [2_000, 3_000, 3_500])
        XCTAssertEqual(kernel.count("processes"), 1, "one read of the table")
        XCTAssertEqual(ProcessInspector.children(of: 4242, kernel: kernel).count, 0, "nobody holds the pid")
    }

    // MARK: The pairing

    /// A terminal as the pairing sees one: a surface, or none — a unit test
    /// has no surface (never `ghostty_init`).
    @MainActor private final class StandIn: PairedSurface {
        var hasSurface = true
    }

    /// A fake Mac's `login`: root's to the kernel's reads, the user's to its
    /// real uid, a child of the fake app.
    private func login(
        _ pid: pid_t, start: UInt64, status: Int32 = SRUN, parent: pid_t = 1000, in kernel: FakeActivityKernel
    ) -> (pid: pid_t, start: UInt64, name: String) {
        let record = FakeActivityKernel.record(pid: pid, start: start, parent: parent, uid: 0, realUID: 501, status: status, name: "login")
        kernel.add(FakeActivityKernel.Process(record: record))
        return (pid: pid, start: start, name: "login")
    }

    /// A list may be a census's, a tick old (docs/design/activity/
    /// analysis.md, 7.7): a pairing from it is made from what holds now.
    /// The review's case — a pane closed after a tick listed its `login`,
    /// the `login` reaped with its surface, then ⌘T — paired the new pane
    /// with the dead `login`, and every reader saw it empty, for good. A
    /// surface made after the list was read takes nothing from it, and a
    /// `login` it names is taken only while a read by its pid finds it,
    /// alive: not ended, not a zombie, its pid not another's since.
    @MainActor func testAPairingIsMadeOnlyFromWhatHoldsNow() {
        let kernel = FakeActivityKernel(uid: 501)
        let surfaces = SurfaceProcesses()
        let first = StandIn()
        surfaces.register(first, at: 100)
        let closed = login(1100, start: 1_000, in: kernel)
        XCTAssertTrue(surfaces.pair([closed], listedAt: 200, kernel: kernel))
        XCTAssertEqual(surfaces.login(of: first), ActivityProcessID(pid: 1100, start: 1_000))
        XCTAssertFalse(surfaces.hasWaiting)

        // Its tab closes: the login is reaped as the surface is freed, the
        // pane gone. Then a new one, and the latest list still names it.
        kernel.remove(1100)
        surfaces.closed(first)
        let second = StandIn()
        surfaces.register(second, at: 300)
        XCTAssertTrue(surfaces.hasWaiting)
        XCTAssertFalse(surfaces.pair([closed], listedAt: 200, kernel: kernel), "made after the list was read: nothing from it")
        XCTAssertFalse(surfaces.pair([closed], listedAt: 400, kernel: kernel), "its login ended: no read by its pid finds it")
        XCTAssertNil(surfaces.login(of: second))

        // A zombie is no login to take, nor a pid another login holds now.
        let zombie = login(1200, start: 2_000, status: SZOMB, in: kernel)
        XCTAssertFalse(surfaces.pair([zombie], listedAt: 400, kernel: kernel), "a zombie")
        _ = login(1100, start: 3_000, in: kernel)
        XCTAssertFalse(surfaces.pair([closed], listedAt: 400, kernel: kernel), "its pid holds another login now")
        XCTAssertNil(surfaces.login(of: second))

        // Its own, once a list names it: the oldest of the list that holds.
        let own = login(1300, start: 4_000, in: kernel)
        XCTAssertTrue(surfaces.pair([closed, zombie, own], listedAt: 500, kernel: kernel))
        XCTAssertEqual(surfaces.login(of: second), ActivityProcessID(pid: 1300, start: 4_000))
        XCTAssertFalse(surfaces.hasWaiting)
    }

    /// Surfaces take the list's `login`s in order, the oldest surface the
    /// oldest `login` that holds; one that has no surface any more waits
    /// for nothing.
    @MainActor func testWaitingSurfacesTakeTheLoginsInOrder() {
        let kernel = FakeActivityKernel(uid: 501)
        let surfaces = SurfaceProcesses()
        let older = StandIn()
        let gone = StandIn()
        let newer = StandIn()
        surfaces.register(older, at: 100)
        surfaces.register(gone, at: 150)
        surfaces.register(newer, at: 200)
        gone.hasSurface = false
        let listed = [login(1200, start: 2_000, in: kernel), login(1100, start: 1_000, in: kernel)]
        XCTAssertTrue(surfaces.pair(listed, listedAt: 300, kernel: kernel))
        XCTAssertEqual(surfaces.login(of: older), ActivityProcessID(pid: 1100, start: 1_000))
        XCTAssertEqual(surfaces.login(of: newer), ActivityProcessID(pid: 1200, start: 2_000))
        XCTAssertNil(surfaces.login(of: gone))
    }

    /// A pairing ends with its `login`, and only then: a list that doesn't
    /// name it — a tick old, read before the pairing was made — is checked
    /// by a read of its pid, and a login alive keeps it.
    @MainActor func testAPairingEndsOnlyWithItsLogin() {
        let kernel = FakeActivityKernel(uid: 501)
        let surfaces = SurfaceProcesses()
        let surface = StandIn()
        surfaces.register(surface, at: 100)
        let own = login(1100, start: 1_000, in: kernel)
        XCTAssertTrue(surfaces.pair([own], listedAt: 200, kernel: kernel))
        XCTAssertFalse(surfaces.pair([], listedAt: 150, kernel: kernel), "a list without it, its login alive: kept")
        XCTAssertEqual(surfaces.login(of: surface), ActivityProcessID(pid: 1100, start: 1_000))
        kernel.remove(1100)
        XCTAssertTrue(surfaces.pair([], listedAt: 300, kernel: kernel), "its login ended: the pairing is over")
        XCTAssertNil(surfaces.login(of: surface))
    }

    /// From a census that landed (7.7): the app's children and the logins
    /// no pane has are listed on the sampler's queue, the main actor only
    /// hands them out. A `login` that exited before it was paired is a
    /// zombie until its surface is freed and it is reaped: it never pairs
    /// (7.10) — listed, the next surface took it and its own `login`
    /// shifted onto the one after. Nor does a `login` another surface has
    /// taken since the tick listed it.
    @MainActor func testAZombieLoginNeverPairsFromACensus() throws {
        let kernel = FakeActivityKernel(uid: 501)
        kernel.add(FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 1, start: 1, parent: 0, uid: 0, name: "launchd")))
        kernel.add(FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 1000, start: 500, parent: 1, name: "Overterm")))
        // Its pane closed before its pairing: the surface freed, the login
        // not reaped yet.
        let ended = login(1100, start: 1_000, status: SZOMB, in: kernel)
        let own = login(1200, start: 2_000, in: kernel)
        let next = login(1300, start: 3_000, in: kernel)
        let sampler = ActivitySampler(kernel: kernel)
        let snapshot = try XCTUnwrap(sampler.tickNow(ActivityDemand(.light(tabs: nil)), context: ActivityContext(appPID: 1000)))
        XCTAssertFalse(snapshot.appChildren.contains { $0.pid == ended.pid }, "a zombie isn't the app's child to pair")
        XCTAssertEqual(snapshot.unclaimedLogins, [ActivityProcessID(pid: 1200, start: 2_000), ActivityProcessID(pid: 1300, start: 3_000)])

        let surfaces = SurfaceProcesses()
        let surface = StandIn()
        surfaces.register(surface, at: 0)
        XCTAssertTrue(surfaces.pair(snapshot, kernel: kernel))
        XCTAssertEqual(surfaces.login(of: surface), ActivityProcessID(pid: own.pid, start: own.start), "its own, not the dead pane's")
        // The same snapshot again: the login taken since isn't offered twice.
        let later = StandIn()
        surfaces.register(later, at: 0)
        XCTAssertTrue(surfaces.pair(snapshot, kernel: kernel))
        XCTAssertEqual(surfaces.login(of: later), ActivityProcessID(pid: next.pid, start: next.start))
        XCTAssertFalse(surfaces.pair(snapshot, kernel: kernel), "nothing waits: nothing changes")
    }

    /// Which threads read the fake's table, in order: true for the main one.
    private final class TableReads: @unchecked Sendable {
        private let lock = NSLock()
        private var threads: [Bool] = []
        func add(onMain: Bool) { lock.withLock { threads.append(onMain) } }
        var all: [Bool] { lock.withLock { threads } }
    }

    /// Tab Info pairs its panes as it opens, before its first want, and
    /// never reads the table on the main thread for it (7.7): the app's
    /// children are listed off it, the main actor pairing what was listed.
    /// With nothing waiting, nothing is read.
    @MainActor func testWaitingSurfacesArePairedFromAListReadOffTheMainThread() async {
        let kernel = FakeActivityKernel(uid: 501)
        let app = getpid()
        kernel.add(FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: app, start: 500, parent: 1, name: "Overterm")))
        _ = login(1100, start: 1_000, parent: app, in: kernel)
        let reads = TableReads()
        kernel.onCall { call in
            if call == "processes" { reads.add(onMain: Thread.isMainThread) }
        }
        let surfaces = SurfaceProcesses()
        let surface = StandIn()
        surfaces.register(surface, at: 0)
        await surfaces.pairWaiting(kernel: kernel)
        XCTAssertEqual(surfaces.login(of: surface), ActivityProcessID(pid: 1100, start: 1_000))
        XCTAssertEqual(reads.all, [false], "one read of the table, off the main thread")
        await surfaces.pairWaiting(kernel: kernel)
        XCTAssertEqual(reads.all, [false], "none waits: nothing read")
    }

    /// The real listing names libghostty's children as sysctl does.
    func testChildrenCarryTheirCommandNames() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate() }
        let found = ProcessInspector.children(of: getpid()).first { $0.pid == child.processIdentifier }
        XCTAssertEqual(found?.name, "sleep")
    }
}
