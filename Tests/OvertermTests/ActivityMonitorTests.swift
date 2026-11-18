import Darwin
import Foundation
import XCTest

@testable import Overterm

/// The census's readers (docs/design/activity/analysis.md, 7.1, 7.3, 7.9)
/// over a fake Mac: wants counted by owner, one tick for every reader at
/// the fastest cadence, the ticks stopped when nothing wants them,
/// one-off censuses coalesced and nil when the table can't be read,
/// agents served from a snapshot at most one interval old, a tick in
/// flight never doubled, the context rebuilt once for a burst and by every
/// tick that finds a rebuild waiting.
@MainActor
final class ActivityMonitorTests: XCTestCase {
    private let kernel = FakeActivityKernel(uid: 501)
    private var monitor: ActivityMonitor!
    private let app: pid_t = 1000
    private let tabA = UUID()
    private let tabB = UUID()
    private var paneA: ActivityContext.Pane!
    private var paneB: ActivityContext.Pane!

    private final class Owner {}

    override func setUp() async throws {
        func add(_ pid: pid_t, parent: pid_t, uid: uid_t = 501, name: String) -> ActivityProcessID {
            var process = FakeActivityKernel.Process(
                record: FakeActivityKernel.record(pid: pid, start: UInt64(pid) * 1_000, parent: parent, uid: uid, name: name))
            process.name = name
            process.path = "/opt/acme/bin/\(name)"
            process.usage = FakeActivityKernel.usage()
            process.arguments = FakeActivityKernel.arguments(executable: "/opt/acme/bin/\(name)", [name])
            kernel.add(process)
            return ActivityProcessID(pid: pid, start: UInt64(pid) * 1_000)
        }
        _ = add(1, parent: 0, uid: 0, name: "launchd")
        _ = add(app, parent: 1, name: "Overterm")
        let loginA = add(1100, parent: app, uid: 0, name: "login")
        _ = add(1101, parent: 1100, name: "zsh")
        let loginB = add(1200, parent: app, uid: 0, name: "login")
        _ = add(1201, parent: 1200, name: "zsh")
        paneA = ActivityContext.Pane(tag: "pane-a", tab: tabA, login: loginA)
        paneB = ActivityContext.Pane(tag: "pane-b", tab: tabB, login: loginB)
        monitor = ActivityMonitor(sampler: ActivitySampler(kernel: kernel))
        monitor.setContext(ActivityContext(panes: [paneA, paneB], appPID: app))
    }

    override func tearDown() async throws {
        monitor.stop()
        kernel.onCall(nil)
    }

    private func eventually(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out: \(what)")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Two readers, one tick: the window's light slice of its tab every
    /// hour, Tab Info's of another every 20 ms — each tick reads both, at
    /// the faster cadence, the table once.
    func testOneTickServesEveryReaderAtTheFastestCadence() async throws {
        let window = Owner()
        let info = Owner()
        monitor.want(window, .light(tabs: [tabA]), every: .seconds(3600))
        XCTAssertTrue(monitor.isTicking)
        await eventually("the first tick") { monitor.snapshot != nil }
        XCTAssertEqual(monitor.snapshot?.panes.map(\.tag), ["pane-a"])
        monitor.want(info, .light(tabs: [tabB]), every: .milliseconds(20))
        XCTAssertEqual(monitor.cadence, .milliseconds(20))
        await eventually("ticks at the faster cadence") { (monitor.snapshot?.tick ?? 0) >= 6 }
        XCTAssertEqual(monitor.snapshot?.panes.map(\.tag), ["pane-a", "pane-b"], "one tick serves both")
        monitor.unwant(window)
        monitor.unwant(info)
        await eventually("the last tick landed") { !monitor.isSampling }
        XCTAssertEqual(kernel.count("processes"), monitor.snapshot?.tick, "one table read a tick, whoever wants it")
    }

    /// The last reader gone, the ticks stop; a want starts them again.
    func testUnwantStopsTheTicksAndAWantStartsThem() async throws {
        let owner = Owner()
        monitor.want(owner, .light(tabs: nil), every: .milliseconds(10))
        await eventually("ticking") { (monitor.snapshot?.tick ?? 0) >= 2 }
        monitor.unwant(owner)
        XCTAssertFalse(monitor.isTicking)
        await eventually("the last tick landed") { !monitor.isSampling }
        let read = kernel.count("processes")
        let none = await monitor.tick()
        XCTAssertNil(none, "nothing wanted: nothing read")
        XCTAssertEqual(kernel.count("processes"), read)
        monitor.want(owner, .light(tabs: nil), every: .milliseconds(10))
        XCTAssertTrue(monitor.isTicking)
        await eventually("ticking again") { kernel.count("processes") > read }
    }

    /// A reader that went without saying so stops wanting: its owner is
    /// held weakly.
    func testAReaderThatWentAwayStopsWanting() async throws {
        var owner: Owner? = Owner()
        monitor.want(try XCTUnwrap(owner), .light(tabs: nil), every: .milliseconds(10))
        await eventually("ticking") { monitor.snapshot != nil }
        owner = nil
        await eventually("stopped by itself") { !monitor.isTicking }
        XCTAssertTrue(monitor.demand.isEmpty)
    }

    /// Only a wider want ticks early, once for a burst: processes newly
    /// in focus wait for the next tick, as a list's rows change while it
    /// scrolls.
    func testOnlyAWiderWantTicksEarlyOnceForABurst() async throws {
        let page = Owner()
        let window = Owner()
        monitor.want(page, .light(tabs: [tabA]), every: .seconds(3600))
        await eventually("the first tick") { monitor.snapshot != nil && !monitor.isSampling }
        let shell = ActivityProcessID(pid: 1101, start: 1_101_000)
        monitor.want(page, .light(tabs: [tabA]), .focus([shell]), every: .seconds(3600))
        XCTAssertEqual(monitor.earlyTicks, 0, "focus waits for the next tick")
        for _ in 0..<3 { monitor.want(window, .light(tabs: [tabB]), every: .seconds(3600)) }
        await eventually("the window's tab read") { monitor.snapshot?.pane("pane-b") != nil && !monitor.isSampling }
        XCTAssertEqual(kernel.count("processes"), 2, "one early tick for the burst")
        XCTAssertEqual(monitor.snapshot?.demand.focus, [shell], "the focus read with it")
    }

    /// A pairing a snapshot brought (7.7) brings the next tick early, with
    /// the context rebuilt: a new pane's tree is read a quarter of a second
    /// after its `login` was first listed, not a cadence later. With
    /// nothing wanting ticks, it only rebuilds the context.
    func testAPairingBringsTheNextTickEarly() async throws {
        let window = Owner()
        let source = PaneSource([ActivityContext.Pane(tag: "pane-a", tab: tabA)])
        let app = self.app
        monitor.contextSource = { ActivityContext(panes: source.panes, appPID: app) }
        monitor.contextChanged()
        monitor.flushContext()
        monitor.want(window, .light(tabs: [tabA]), every: .seconds(3600))
        await eventually("the first tick, the pane not paired yet") { monitor.snapshot != nil && !monitor.isSampling }
        XCTAssertEqual(monitor.snapshot?.pane("pane-a")?.tree, [], "no login, no tree")
        source.panes = [paneA]
        monitor.surfacesPaired()
        XCTAssertEqual(monitor.earlyTicks, 1)
        await eventually("its tree read early") { monitor.snapshot?.pane("pane-a")?.tree.isEmpty == false && !monitor.isSampling }
        XCTAssertEqual(kernel.count("processes"), 2)
        monitor.unwant(window)
        await eventually("stopped") { !monitor.isTicking && !monitor.isSampling }
        monitor.surfacesPaired()
        XCTAssertFalse(monitor.isTicking, "nothing wants ticks: none early")
        XCTAssertTrue(monitor.hasPendingContext, "the context rebuilt still")
    }

    /// A wider want while a tick is in flight: the restarted loop's round
    /// waits for that tick, sees it read less, and ticks for the wider
    /// want once — it never waits on the landed tick again and again,
    /// which held the main actor for ever (its waiters are resumed newest
    /// first, and a finished task's value comes without a suspension).
    func testAWiderWantDuringATickInFlightGetsItsOwnTick() async throws {
        let gate = CallGate()
        defer { gate.open() }
        kernel.onCall { call in if call == "processes" { gate.hold() } }
        let window = Owner()
        let info = Owner()
        monitor.want(window, .light(tabs: [tabA]), every: .seconds(3600))
        await eventually("the first tick is in") { gate.held == 1 }
        monitor.want(info, .light(tabs: [tabB]), every: .seconds(3600))
        XCTAssertEqual(monitor.earlyTicks, 1)
        await eventually("the restarted loop waits on the tick in flight") { monitor.skippedTicks == 1 }
        gate.open()
        await eventually("the wider tick") { monitor.snapshot?.pane("pane-b") != nil && !monitor.isSampling }
        XCTAssertEqual(kernel.count("processes"), 2, "the held tick, then one for the wider want")
        XCTAssertEqual(monitor.snapshot?.panes.map(\.tag), ["pane-a", "pane-b"])
        XCTAssertTrue(monitor.isTicking)
    }

    /// A census while a light tick is in flight waits for it, sees it read
    /// less, and reads in full — once, never waiting on the landed tick
    /// again.
    func testACensusDuringALightTickReadsInFullOnce() async throws {
        let gate = CallGate()
        defer { gate.open() }
        kernel.onCall { call in if call == "processes" { gate.hold() } }
        let window = Owner()
        monitor.want(window, .light(tabs: [tabA]), every: .seconds(3600))
        await eventually("the light tick is in") { gate.held == 1 }
        let census = Task { await monitor.census() }
        await eventually("the census waits on it") { monitor.skippedTicks == 1 }
        gate.open()
        let snapshot = await census.value
        XCTAssertEqual(snapshot?.demand.full, true)
        XCTAssertEqual(kernel.count("processes"), 2, "the light tick, then the census's")
        XCTAssertEqual(monitor.snapshot?.tick, snapshot?.tick, "the newer published")
    }

    /// A reader's want replaces what it wanted before; the readers' wants
    /// merge.
    func testWantsReplaceAndMerge() async throws {
        let window = Owner()
        let page = Owner()
        monitor.want(window, .light(tabs: [tabA]))
        monitor.want(window, .light(tabs: [tabB]))
        XCTAssertEqual(monitor.demand.tabs, [tabB])
        let process = ActivityProcessID(pid: 1101, start: 1_101_000)
        monitor.want(page, .full, .focus([process]))
        XCTAssertTrue(monitor.demand.full)
        XCTAssertEqual(monitor.demand.focus, [process])
        monitor.unwant(page)
        XCTAssertFalse(monitor.demand.full)
    }

    func testDemandsMergeAndCover() {
        let process = ActivityProcessID(pid: 1101, start: 1_101_000)
        let light = ActivityDemand(.light(tabs: [tabA]))
        XCTAssertTrue(light.covers(ActivityDemand(.light(tabs: [tabA]))))
        XCTAssertFalse(light.covers(ActivityDemand(.light(tabs: [tabB]))))
        XCTAssertFalse(light.covers(ActivityDemand(.light(tabs: nil))), "every tab is more")
        XCTAssertTrue(ActivityDemand(.light(tabs: nil)).covers(light))
        XCTAssertFalse(light.covers(ActivityDemand(.focus([process]))))
        XCTAssertTrue(ActivityDemand(.full).covers(light.merged(ActivityDemand(.focus([process])))))
        XCTAssertFalse(light.covers(ActivityDemand(.full)))
        XCTAssertEqual(light.merged(ActivityDemand(.light(tabs: [tabB]))).tabs, [tabA, tabB])
        XCTAssertNil(light.merged(ActivityDemand(.light(tabs: nil))).tabs)
        XCTAssertTrue(ActivityDemand().isEmpty)
        XCTAssertFalse(ActivityDemand(.focus([process])).readsPanes)
        XCTAssertTrue(ActivityDemand(.light(tabs: nil)).readsPanes)
        XCTAssertFalse(ActivityDemand(.light(tabs: [])).readsPanes)
        XCTAssertTrue(ActivityDemand(.full).reads(paneB))
        XCTAssertFalse(light.reads(paneB))
    }

    /// One-off censuses (7.1): full, at most one every 2 s — one younger
    /// answers, one in flight is shared — and none starts the ticks.
    func testOneOffCensusesAreCoalesced() async throws {
        let census = await monitor.census()
        let first = try XCTUnwrap(census)
        XCTAssertTrue(first.demand.full)
        XCTAssertEqual(kernel.count("processes"), 1)
        let again = await monitor.census()
        XCTAssertEqual(again?.tick, first.tick, "less than 2 s old: it answers")
        XCTAssertEqual(kernel.count("processes"), 1)
        kernel.advance(ActivityMonitor.oneOffSpacing)
        let monitor = try XCTUnwrap(self.monitor)
        async let one = monitor.census()
        async let two = monitor.census()
        let (left, right) = await (one, two)
        XCTAssertNotEqual(left?.tick, first.tick)
        XCTAssertEqual(left?.tick, right?.tick, "the one in flight is shared")
        XCTAssertEqual(kernel.count("processes"), 2)
        XCTAssertFalse(monitor.isTicking, "a one-off starts no ticks")
    }

    /// An agent's read (7.3): from the latest full snapshot while it is at
    /// most one interval old; an agent calling in a loop gets the same.
    func testAgentsReadARecentSnapshot() async throws {
        monitor.interval = .seconds(2)
        let answer = await monitor.forAgents()
        let first = try XCTUnwrap(answer)
        XCTAssertEqual(kernel.count("processes"), 1)
        kernel.advance(2_000_000_000)
        let served = await monitor.forAgents()
        XCTAssertEqual(served?.tick, first.tick, "an interval old")
        for _ in 0..<20 { _ = await monitor.forAgents() }
        XCTAssertEqual(kernel.count("processes"), 1, "an agent in a loop: the same snapshot")
        kernel.advance(1)
        let fresh = await monitor.forAgents()
        XCTAssertNotEqual(fresh?.tick, first.tick, "older: one census")
        XCTAssertEqual(kernel.count("processes"), 2)
        // A light tick isn't an agent's answer.
        let owner = Owner()
        monitor.want(owner, .light(tabs: nil), every: .seconds(3600))
        await eventually("a light tick") { monitor.snapshot?.demand.full == false }
        monitor.unwant(owner)
        let after = await monitor.forAgents()
        XCTAssertEqual(after?.tick, fresh?.tick)
        // At a 1 s interval, never the one-offs' 2 s: two intervals.
        monitor.interval = .seconds(1)
        kernel.advance(1_500_000_000)
        let quick = await monitor.forAgents()
        XCTAssertNotEqual(quick?.tick, fresh?.tick, "1.5 s old at a 1 s interval: a census")
        XCTAssertEqual(kernel.count("processes"), 4)
        kernel.advance(1_000_000_000)
        for _ in 0..<20 { _ = await monitor.forAgents() }
        XCTAssertEqual(kernel.count("processes"), 4, "an interval old: the same snapshot")
    }

    /// Light ticks after a full one: the full snapshot kept for the
    /// windows that read it shares the newer ring, and is dropped past
    /// them — never a third copy of the ring kept for nothing.
    func testTheLastFullSnapshotIsLetGoBehindLightTicks() async throws {
        monitor.interval = .seconds(2)
        let census = await monitor.census()
        let first = try XCTUnwrap(census)
        let owner = Owner()
        monitor.want(owner, .light(tabs: nil), every: .seconds(3600))
        await eventually("a light tick") { monitor.snapshot?.demand.full == false }
        XCTAssertEqual(monitor.lastFull?.tick, first.tick, "within the windows: kept")
        XCTAssertEqual(monitor.lastFull?.history.bytes, monitor.snapshot?.history.bytes, "with the newer ring")
        monitor.unwant(owner)
        kernel.advance(4_000_000_001)
        let light = monitor.snapshot?.tick ?? 0
        monitor.want(owner, .light(tabs: nil), every: .seconds(3600))
        await eventually("another light tick") { (monitor.snapshot?.tick ?? 0) > light }
        monitor.unwant(owner)
        XCTAssertNil(monitor.lastFull, "past every window that reads it: dropped")
        let again = await monitor.census()
        XCTAssertNotNil(again, "a census reads anew")
    }

    /// A census whose table can't be read says so: nil, not an older
    /// snapshot passed off as one less than 2 s old.
    func testACensusThatCantReadSaysSo() async throws {
        let first = await monitor.census()
        XCTAssertNotNil(first)
        // Older than a one-off's 2 s and an agent's interval.
        kernel.advance(ActivityMonitor.oneOffSpacing + 1)
        kernel.refuseTable(true)
        let refused = await monitor.census()
        XCTAssertNil(refused)
        let agents = await monitor.forAgents()
        XCTAssertNil(agents, "nor an agent's")
        kernel.refuseTable(false)
        let again = await monitor.census()
        XCTAssertNotNil(again)
        XCTAssertNotEqual(again?.tick, first?.tick)
    }

    /// The in-flight guard: a tick asked for while one runs is skipped,
    /// nothing read twice.
    func testATickInFlightIsNotDoubled() async throws {
        let gate = CallGate()
        defer { gate.open() }
        kernel.onCall { call in if call == "processes" { gate.hold() } }
        let census = Task { await monitor.census() }
        await eventually("the census is in") { gate.held == 1 }
        let skipped = await monitor.tick()
        XCTAssertNil(skipped)
        XCTAssertEqual(monitor.skippedTicks, 1)
        gate.open()
        let snapshot = await census.value
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(kernel.count("processes"), 1)
    }

    /// The context (7.1): rebuilt once for a burst of changes, once it has
    /// been quiet for the debounce; one that never quiets at its limit; a
    /// tick — a census's here — rebuilds a waiting one first.
    func testTheContextIsRebuiltOnceForABurst() async throws {
        let pane = paneA!
        let app = self.app
        monitor.contextSource = { ActivityContext(panes: [pane], appPID: app) }
        monitor.debounce = .milliseconds(50)
        for _ in 0..<5 { monitor.contextChanged() }
        XCTAssertTrue(monitor.hasPendingContext)
        await eventually("rebuilt") { !monitor.hasPendingContext }
        XCTAssertEqual(monitor.contextBuilds, 1, "once for the burst")
        XCTAssertEqual(monitor.context.panes.map(\.tag), ["pane-a"])

        monitor.debounce = .seconds(3600)
        monitor.debounceLimit = .milliseconds(50)
        monitor.contextChanged()
        await eventually("rebuilt at its limit") { !monitor.hasPendingContext }
        XCTAssertEqual(monitor.contextBuilds, 2, "a burst that never quiets")

        monitor.debounceLimit = .seconds(3600)
        monitor.contextChanged()
        let snapshot = await monitor.census()
        XCTAssertEqual(monitor.contextBuilds, 3, "the census's tick rebuilt it first")
        XCTAssertFalse(monitor.hasPendingContext)
        XCTAssertEqual(snapshot?.panes.map(\.tag), ["pane-a"])
    }

    /// The context goes to the sampler too, whole, as it changes: a lookup
    /// between the monitor's ticks reads the app's panes with it (7.8).
    func testTheSamplerHasTheContextForLookups() {
        XCTAssertEqual(monitor.sampler.appContext, monitor.context)
        monitor.setContext(ActivityContext(panes: [paneB], appPID: app))
        XCTAssertEqual(monitor.sampler.appContext.panes.map(\.tag), ["pane-b"])
        let pane = paneA!
        let app = self.app
        monitor.contextSource = { ActivityContext(panes: [pane], appPID: app) }
        monitor.contextChanged()
        monitor.flushContext()
        XCTAssertEqual(monitor.sampler.appContext.panes.map(\.tag), ["pane-a"], "rebuilt, shared")
    }

    /// A tab opened and wanted in the same turn: the early tick its want
    /// makes takes the context with the tab's panes — a waiting rebuild is
    /// made at the start of every tick, not left to its timer, or the tick
    /// would cover the tab with nothing of it read, and no later want for
    /// it would tick early.
    func testAnEarlyTickTakesAWaitingContext() async throws {
        let source = PaneSource([paneA])
        let app = self.app
        monitor.contextSource = { ActivityContext(panes: source.panes, appPID: app) }
        monitor.debounce = .seconds(3600)
        monitor.debounceLimit = .seconds(3600)
        monitor.setContext(ActivityContext(panes: [paneA], appPID: app))
        let window = Owner()
        monitor.want(window, .light(tabs: [tabA]), every: .seconds(3600))
        await eventually("the first tick") { monitor.snapshot != nil && !monitor.isSampling }
        source.panes = [paneA, paneB]
        monitor.contextChanged()
        monitor.want(window, .light(tabs: [tabA, tabB]), every: .seconds(3600))
        XCTAssertEqual(monitor.earlyTicks, 1)
        await eventually("the early tick") { (monitor.snapshot?.tick ?? 0) >= 2 && !monitor.isSampling }
        XCTAssertEqual(monitor.snapshot?.panes.map(\.tag), ["pane-a", "pane-b"], "the new tab's pane read at once")
        XCTAssertEqual(monitor.contextBuilds, 1)
        XCTAssertFalse(monitor.hasPendingContext)
    }

    /// The panes a test's context source gives, changed as the test goes.
    private final class PaneSource {
        var panes: [ActivityContext.Pane]
        init(_ panes: [ActivityContext.Pane]) { self.panes = panes }
    }

    /// A busy Mac stretches the cadence to 5 s (7.3).
    func testABusyMacStretchesTheCadence() async throws {
        let owner = Owner()
        kernel.onCall { [kernel] call in if call == "processes" { kernel.advance(20_000_000) } }
        monitor.want(owner, .light(tabs: nil), every: .milliseconds(10))
        XCTAssertEqual(monitor.cadence, .milliseconds(10))
        await eventually("stretched") { monitor.snapshot?.isStretched == true }
        XCTAssertEqual(monitor.cadence, ActivityCadence.stretched)
    }
}
