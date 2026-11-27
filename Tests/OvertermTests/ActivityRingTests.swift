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

/// Activity's history (docs/design/activity/analysis.md, 6.11, 10.1): the
/// strip's cells — highest, lowest, a gap never zero —, the detail's
/// samples and breaks, the hour folded, ended processes kept 15 minutes,
/// the detail's limit and the byte cap; then the census merging into it on
/// a fake Mac — a process, an agent's subtree, a tab —, the chips it
/// gives (a core held, an idle agent burning, a moved server), the new
/// and ended rows, and who holds a sleep assertion. Nothing of this Mac's.
final class ActivityRingTests: XCTestCase {
    private let second = ActivityRing.second
    private let minute = ActivityRing.second * 60
    /// A clock far from 0, on a cell's start.
    private let base: UInt64 = 1_000 * ActivityRing.cellLength
    private let process = ActivityProcessID(pid: 4242, start: 1_000)

    override func tearDown() {
        ActivityPageModel.forgetView()
        super.tearDown()
    }

    // MARK: The strip

    func testACellKeepsItsHighestAndLowestAndAGapIsNil() throws {
        var ring = ActivityRing()
        let key = ActivityRingKey.process(process)
        ring.record(key, ActivityRingSample(cpu: 20, memory: 100), at: base)
        ring.record(key, ActivityRingSample(cpu: 80, memory: 200), at: base + 2 * second)
        ring.record(key, ActivityRingSample(cpu: 50, memory: 300), at: base + 4 * second)
        // Two cells later: the one between is a gap.
        ring.record(key, ActivityRingSample(cpu: 10, memory: 300), at: base + 2 * ActivityRing.cellLength)
        let strip = ring.cpuStrip(key, now: base + 2 * ActivityRing.cellLength)
        XCTAssertEqual(strip?.count, 60)
        XCTAssertEqual(strip?[57] ?? nil, 80, "the first cell's highest")
        XCTAssertNil(try XCTUnwrap(strip)[58], "nothing sampled: a gap, never zero")
        XCTAssertEqual(strip?[59] ?? nil, 10)
        XCTAssertNil(try XCTUnwrap(strip)[0], "before it began")
        XCTAssertEqual(ring.lastCPU(key), 10)
        XCTAssertEqual(ring.since(key, now: base + 2 * ActivityRing.cellLength), base, "it began inside the window: since then")
        // Fifteen minutes on, nothing of it is in the window.
        let later = base + 70 * ActivityRing.cellLength
        XCTAssertEqual(ring.cpuStrip(key, now: later)?.allSatisfy { $0 == nil }, true)
        XCTAssertNil(ring.since(key, now: later + 60 * ActivityRing.cellLength), "older than the window: no since")
        XCTAssertNil(ring.cpuStrip(.process(ActivityProcessID(pid: 1, start: 1))), "no history: nil, not a strip of gaps")
    }

    func testAStripWrapsWithoutKeepingOldCells() {
        var ring = ActivityRing()
        let key = ActivityRingKey.process(process)
        for cell in 0..<130 {
            ring.record(key, ActivityRingSample(cpu: Double(cell)), at: base + UInt64(cell) * ActivityRing.cellLength)
        }
        let strip = ring.cpuStrip(key, now: base + 129 * ActivityRing.cellLength)
        XCTAssertEqual(strip?.first ?? nil, 70)
        XCTAssertEqual(strip?.last ?? nil, 129)
        // A sample older than the strip is dropped.
        ring.record(key, ActivityRingSample(cpu: 999), at: base)
        XCTAssertEqual(ring.cpuStrip(key, now: base + 129 * ActivityRing.cellLength)?.compactMap { $0 }.max(), 129)
    }

    /// glances' rule: a level lasts before it is an event; a gap or a
    /// sample under it ends the run.
    func testSustainedRunsEndAtAGapOrALowSample() {
        var ring = ActivityRing()
        let key = ActivityRingKey.process(process)
        var time = base
        for _ in 0..<200 {
            ring.record(key, ActivityRingSample(cpu: 99), at: time)
            time += 2 * second
        }
        let start = ring.sustained(key, atLeast: 90, now: time)
        XCTAssertEqual(start, base)
        // One sample under the level: the run starts after its cell.
        ring.record(key, ActivityRingSample(cpu: 40), at: time)
        XCTAssertNil(ring.sustained(key, atLeast: 90, now: time), "the newest cell holds the low sample")
        time += ActivityRing.cellLength
        ring.record(key, ActivityRingSample(cpu: 99), at: time)
        XCTAssertEqual(ring.sustained(key, atLeast: 90, now: time), time / ActivityRing.cellLength * ActivityRing.cellLength)
        // Nothing read for two cells: no run now.
        XCTAssertNil(ring.sustained(key, atLeast: 90, now: time + 3 * ActivityRing.cellLength))
    }

    // MARK: The detail

    func testADetailKeepsItsSamplesBreaksAndTheFoldedHour() {
        var ring = ActivityRing()
        let key = ActivityRingKey.process(process)
        var time = base
        for index in 0..<30 {
            ring.record(key, ActivityRingSample(cpu: Double(index), memory: 1_000, diskRead: 10), at: time, detail: true)
            time += 2 * second
        }
        // The same tick read twice — a one-off census beside the tick — adds nothing.
        ring.record(key, ActivityRingSample(cpu: 500), at: time - 2 * second + 100, detail: true)
        XCTAssertEqual(ring.points(key).count, 30)
        // A gap past the longest rate: a break before the next sample.
        time += 40 * second
        ring.record(key, ActivityRingSample(cpu: 5), at: time, detail: true)
        let points = ring.points(key)
        XCTAssertEqual(points.count, 32)
        XCTAssertTrue(points[30].isBreak)
        XCTAssertFalse(points[31].isBreak)
        XCTAssertTrue(points[31].memory.isNaN, "unread stays unread")
        let hour = ring.hourCPU(key)
        XCTAssertEqual(hour?.low, 0)
        XCTAssertEqual(hour?.high, 29)
        XCTAssertEqual(hour?.minutes, 2)

        // Fifteen minutes later the old samples have gone; the folds stay an hour.
        for _ in 0..<500 {
            time += 2 * second
            ring.record(key, ActivityRingSample(cpu: 1), at: time, detail: true)
        }
        let kept = ring.points(key)
        XCTAssertTrue(kept.allSatisfy { $0.time + ActivityRing.detailSpan >= time })
        XCTAssertFalse(kept.first?.isBreak ?? true, "a break left first stands for nothing")
        XCTAssertLessThanOrEqual(ring.folds(key).count, ActivityRing.foldCount)
        XCTAssertEqual(ring.hourCPU(key)?.high, 29, "the hour still has its peak")
    }

    func testTheDetailKeepsFiftyKeysTheLeastRecentlyFedGoing() {
        var ring = ActivityRing()
        ring.record(.system, ActivityRingSample(cpu: 10), at: base, detail: true)
        for pid in 0..<60 {
            let key = ActivityRingKey.process(ActivityProcessID(pid: pid_t(100 + pid), start: 1))
            ring.record(key, ActivityRingSample(cpu: 1), at: base + UInt64(pid) * second, detail: true)
        }
        XCTAssertEqual(ring.detailCount, ActivityRing.detailLimit)
        XCTAssertTrue(ring.hasDetail(.system), "the Mac's is never the one to go")
        XCTAssertFalse(ring.hasDetail(.process(ActivityProcessID(pid: 100, start: 1))))
        XCTAssertTrue(ring.hasDetail(.process(ActivityProcessID(pid: 159, start: 1))))
        XCTAssertEqual(ring.keyCount, 61, "a strip each still")
    }

    func testEndedHistoryStaysFifteenMinutes() {
        var ring = ActivityRing()
        let gone = ActivityProcessID(pid: 7, start: 7)
        let live = ActivityProcessID(pid: 8, start: 8)
        let tab = UUID()
        ring.record(.process(gone), ActivityRingSample(cpu: 50), at: base, detail: true)
        ring.record(.process(live), ActivityRingSample(cpu: 50), at: base)
        ring.record(.tab(tab), ActivityRingSample(cpu: 50), at: base)
        ring.forgetEnded(live: { $0 == live }, at: base + second)
        XCTAssertNotNil(ring.cpuStrip(.process(gone)), "a stopped server still shows its last minutes")
        XCTAssertEqual(ring.sustained(.process(gone), atLeast: 0, now: base + second), nil, "an ended one holds nothing")
        ring.forgetEnded(live: { $0 == live }, at: base + second + ActivityRing.keepEnded)
        XCTAssertNil(ring.cpuStrip(.process(gone)))
        XCTAssertFalse(ring.hasDetail(.process(gone)))
        XCTAssertNotNil(ring.cpuStrip(.process(live)))
        XCTAssertNil(ring.cpuStrip(.tab(tab)), "a tab nothing fed for 15 minutes goes")
    }

    /// The cap (6.11: 4 MB as `bytes` counts it, both copies alive at once —
    /// the sampler's and the last snapshot's): strips go before details,
    /// ended ones first.
    func testTheCapDropsStripsBeforeDetails() {
        var ring = ActivityRing(byteCap: 60_000)
        let detail = ActivityRingKey.process(ActivityProcessID(pid: 1, start: 1))
        for index in 0..<30 {
            ring.record(detail, ActivityRingSample(cpu: 1), at: base + UInt64(index) * second, detail: true)
        }
        for pid in 0..<500 {
            ring.record(.process(ActivityProcessID(pid: pid_t(1_000 + pid), start: 1)), ActivityRingSample(cpu: Double(pid)), at: base)
        }
        XCTAssertGreaterThan(ring.heldBytes, ring.byteCap)
        ring.keepUnderCap()
        XCTAssertGreaterThan(ring.heldBytes, ring.byteCap / 2, "only as many as it takes")
        XCTAssertLessThanOrEqual(ring.heldBytes, ring.byteCap)
        XCTAssertEqual(ring.heldBytes, ActivityRing.copies * ring.bytes)
        XCTAssertTrue(ring.hasDetail(detail))
        XCTAssertNotNil(ring.cpuStrip(.process(ActivityProcessID(pid: 1_499, start: 1))), "the busiest strips stay")
        XCTAssertNil(ring.cpuStrip(.process(ActivityProcessID(pid: 1_000, start: 1))), "the quietest go")
    }

    /// The default cap holds this Mac's size: 1,000 strips of the user's
    /// and fifty details full, under 4 MB.
    func testAFullRingAtAMacsSizeFitsTheCap() {
        var ring = ActivityRing()
        var time = base
        for _ in 0..<450 {
            time += 2 * second
            for pid in 0..<50 {
                ring.record(
                    .process(ActivityProcessID(pid: pid_t(pid), start: 1)), ActivityRingSample(cpu: 10, memory: 1e8, energy: 1, idleWakeups: 2),
                    at: time, detail: true)
            }
        }
        for pid in 50..<1_000 {
            for cell in 0..<60 { ring.record(.process(ActivityProcessID(pid: pid_t(pid), start: 1)), ActivityRingSample(cpu: 1), at: base + UInt64(cell) * ActivityRing.cellLength) }
        }
        ring.keepUnderCap()
        XCTAssertEqual(ring.keyCount, 1_000)
        XCTAssertLessThanOrEqual(ring.heldBytes, ActivityRing.defaultByteCap, "both copies")
    }

    /// A copy — the one a snapshot holds — is a value: the next records
    /// never reach it, and a strip forgotten gives its slot to the next.
    func testACopyKeepsItsCellsAndASlotIsReused() {
        var ring = ActivityRing()
        let first = ActivityRingKey.process(ActivityProcessID(pid: 1, start: 1))
        ring.record(first, ActivityRingSample(cpu: 10), at: base)
        let held = ring
        ring.record(first, ActivityRingSample(cpu: 90), at: base + second)
        XCTAssertEqual(held.cpuStrip(first, now: base)?.last ?? nil, 10)
        XCTAssertEqual(ring.cpuStrip(first, now: base)?.last ?? nil, 90)
        ring.forgetEnded(live: { _ in false }, at: base + 2 * second)
        ring.forgetEnded(live: { _ in false }, at: base + 2 * second + ActivityRing.keepEnded)
        XCTAssertNil(ring.cpuStrip(first))
        let next = ActivityRingKey.process(ActivityProcessID(pid: 2, start: 2))
        ring.record(next, ActivityRingSample(cpu: 5), at: base + ActivityRing.keepEnded + 3 * second)
        XCTAssertEqual(ring.cpuStrip(next)?.compactMap { $0 }, [5], "a reused slot starts empty")
    }

    // MARK: The census merging

    private let kernel = FakeActivityKernel(uid: 501)
    private let app: pid_t = 1000

    @discardableResult
    private func add(_ pid: pid_t, parent: pid_t, uid: uid_t = 501, name: String, words: [String]? = nil) -> ActivityProcessID {
        let start = UInt64(pid) * 1_000
        let path = "/opt/acme/bin/\(name)"
        var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: pid, start: start, parent: parent, uid: uid, name: name))
        process.name = name
        process.path = path
        process.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid)
        process.usage = FakeActivityKernel.usage(cpuTime: 0, footprint: 8 << 20)
        process.arguments = FakeActivityKernel.arguments(executable: path, words ?? [name], environment: [])
        kernel.add(process)
        return ActivityProcessID(pid: pid, start: start)
    }

    private func burn(_ pid: pid_t, _ cpu: UInt64) {
        kernel.update(pid) { process in
            process.usage = FakeActivityKernel.usage(cpuTime: (process.usage?.cpuTime ?? 0) + cpu, footprint: 8 << 20)
        }
    }

    /// A tab whose pane runs an agent with a busy child, and a busy loop
    /// of the user's elsewhere; `ticks` of 2 s each at the full level.
    private func busyMac(ticks: Int, agentShare: UInt64 = 1_200_000_000, loopShare: UInt64 = 2_000_000_000, sampler: ActivitySampler, tab: UUID)
        -> (snapshot: ActivitySnapshot?, agent: ActivityProcessID, child: ActivityProcessID, loop: ActivityProcessID)
    {
        add(1, parent: 0, uid: 0, name: "launchd")
        add(app, parent: 1, name: "Overterm")
        let login = add(1100, parent: app, uid: 0, name: "login")
        add(1101, parent: 1100, name: "zsh")
        let agent = add(1102, parent: 1101, name: "node", words: ["claude"])
        let child = add(1103, parent: 1102, name: "acme-indexer")
        let loop = add(2000, parent: 1, name: "acme-loop")
        let context = ActivityContext(panes: [ActivityContext.Pane(tag: "fake-pane", tab: tab, login: login)], appPID: app)
        var last: ActivitySnapshot?
        for _ in 0..<ticks {
            kernel.advance(2 * second)
            burn(1102, agentShare / 2)
            burn(1103, agentShare / 2)
            burn(2000, loopShare)
            last = sampler.tickNow(ActivityDemand(.full), context: context)
        }
        return (last, agent, child, loop)
    }

    func testTheCensusMergesProcessesTheAgentsSubtreeAndTheTab() throws {
        let sampler = ActivitySampler(kernel: kernel)
        let tab = UUID()
        let made = busyMac(ticks: 10, sampler: sampler, tab: tab)
        let snapshot = try XCTUnwrap(made.snapshot)
        let history = snapshot.history
        XCTAssertEqual(history.lastCPU(.process(made.loop)) ?? 0, 100, accuracy: 0.5)
        XCTAssertEqual(history.lastCPU(.agent(made.agent)) ?? 0, 60, accuracy: 0.5, "the agent and its child, summed")
        XCTAssertEqual(history.lastCPU(.tab(tab)) ?? 0, 60, accuracy: 0.5)
        XCTAssertTrue(history.hasDetail(.agent(made.agent)), "an agent's subtree is a detail key")
        XCTAssertFalse(history.hasDetail(.process(made.loop)), "a process only while it is in focus")
        XCTAssertEqual(history.points(.agent(made.agent)).count, 9, "the first tick has no rate: no point")
        XCTAssertEqual(history.keyCount, snapshot.facts.values.count { $0.rates != nil } + 2, "each rated process, the agent, the tab")
        // In focus: its samples kept too.
        let focused = sampler.tickNow(ActivityDemand(.full, .focus([made.loop])), context: ActivityContext(appPID: app))
        XCTAssertTrue(focused?.history.hasDetail(.process(made.loop)) ?? false)
    }

    /// Sixty agent and tab keys, more than the detail holds: the keys are
    /// picked once a merge — the agents, then the busiest tabs —, the same
    /// each tick, so none is lost and made again: every kept one has every
    /// sample since it began.
    func testTheDetailKeysArePickedOnceAMergeWithoutChurn() throws {
        let sampler = ActivitySampler(kernel: kernel)
        add(1, parent: 0, uid: 0, name: "launchd")
        add(app, parent: 1, name: "Overterm")
        var panes: [ActivityContext.Pane] = []
        var agents: [ActivityProcessID] = []
        var tabs: [UUID] = []
        for index in 0..<30 {
            let pid = pid_t(1_200 + index * 10)
            let login = add(pid, parent: app, uid: 0, name: "login")
            add(pid + 1, parent: pid, name: "zsh")
            agents.append(add(pid + 2, parent: pid + 1, name: "node", words: ["claude"]))
            let tab = UUID()
            tabs.append(tab)
            panes.append(ActivityContext.Pane(tag: "fake-pane-\(index)", tab: tab, login: login))
        }
        let context = ActivityContext(panes: panes, appPID: app)
        var snapshot: ActivitySnapshot?
        var kept: Set<UUID>?
        for tick in 0..<8 {
            kernel.advance(2 * second)
            for (index, agent) in agents.enumerated() { burn(agent.pid, UInt64(index + 1) * 10_000_000) }
            snapshot = sampler.tickNow(ActivityDemand(.full), context: context)
            let ring = try XCTUnwrap(snapshot?.history)
            XCTAssertLessThanOrEqual(ring.detailCount, ActivityRing.detailLimit)
            let tabsKept = Set(tabs.filter { ring.hasDetail(.tab($0)) })
            if tick > 0 {
                XCTAssertEqual(tabsKept.count, ActivityRing.detailLimit - agents.count, "the busiest tabs fill what the agents leave")
                if let kept { XCTAssertEqual(tabsKept, kept, "the same tabs each merge") }
                kept = tabsKept
            }
        }
        let ring = try XCTUnwrap(snapshot?.history)
        for agent in agents { XCTAssertEqual(ring.points(.agent(agent)).count, 7, "every rated tick's sample: never dropped and begun again") }
        for tab in kept ?? [] { XCTAssertEqual(ring.points(.tab(tab)).count, 7) }
        // The busiest: the last agents' tabs.
        XCTAssertTrue(kept?.contains(tabs[29]) ?? false)
        XCTAssertFalse(kept?.contains(tabs[0]) ?? true)
        XCTAssertNotNil(ring.cpuStrip(.tab(tabs[0])), "a tab without a detail still has its strip")
    }

    /// The Mac slept: the history's clock ran on, so the time asleep is a
    /// gap — the strip's cells empty, a break in the detail — and what came
    /// before keeps its date; rates are uptime's, the sleep left out.
    func testASleepIsAGapAndKeepsItsDates() throws {
        let sampler = ActivitySampler(kernel: kernel)
        let tab = UUID()
        let made = busyMac(ticks: 5, sampler: sampler, tab: tab)
        let before = try XCTUnwrap(made.snapshot)
        let last = try XCTUnwrap(before.history.points(.agent(made.agent)).last)
        kernel.sleep(10 * minute)
        kernel.advance(2 * second)
        burn(1102, 600_000_000)
        burn(1103, 600_000_000)
        burn(2000, 2_000_000_000)
        let snapshot = try XCTUnwrap(
            sampler.tickNow(
                ActivityDemand(.full),
                context: ActivityContext(panes: [ActivityContext.Pane(tag: "fake-pane", tab: tab, login: ActivityProcessID(pid: 1100, start: 1_100_000))], appPID: app)))
        XCTAssertEqual(snapshot.historyNow - before.historyNow, 10 * minute + 2 * second)
        XCTAssertEqual(snapshot.time - before.time, 2 * second, "uptime stood still")
        XCTAssertEqual(snapshot.history.lastCPU(.process(made.loop)) ?? 0, 100, accuracy: 0.5, "the rate over the 2 s awake")
        let points = snapshot.history.points(.agent(made.agent))
        XCTAssertTrue(points.dropLast().last?.isBreak ?? false, "a break across the sleep")
        let strip = try XCTUnwrap(snapshot.history.cpuStrip(.process(made.loop), now: snapshot.historyNow))
        XCTAssertNotNil(strip[59])
        XCTAssertNotNil(strip[19], "before the sleep, where it was")
        XCTAssertTrue(strip[20..<59].allSatisfy { $0 == nil }, "ten minutes asleep: gaps, never the minutes before moved up")
        let dated = snapshot.date(of: last.time)
        XCTAssertEqual(snapshot.date.timeIntervalSince(dated), 10 * 60 + 2, accuracy: 0.01, "before the sleep, said as then")
        let run = snapshot.history.sustained(.process(made.loop), atLeast: 90, now: snapshot.historyNow)
        XCTAssertTrue(run.map { $0 >= before.historyNow } ?? true, "no core held across it")
    }

    // MARK: Chips

    func testHeldACoreAndAnIdleAgentBurningAfterFiveMinutes() throws {
        let sampler = ActivitySampler(kernel: kernel)
        let tab = UUID()
        // Four minutes: nothing yet — a level must last.
        var made = busyMac(ticks: 120, sampler: sampler, tab: tab)
        var snapshot = try XCTUnwrap(made.snapshot)
        XCTAssertEqual(ActivityChips.of(made.loop, agentWaitingSince: nil, isAgent: false, in: snapshot), [])
        // Two minutes more.
        for _ in 0..<60 {
            kernel.advance(2 * second)
            burn(1102, 600_000_000)
            burn(1103, 600_000_000)
            burn(2000, 2_000_000_000)
            snapshot = try XCTUnwrap(
                sampler.tickNow(
                    ActivityDemand(.full),
                    context: ActivityContext(panes: [ActivityContext.Pane(tag: "fake-pane", tab: tab, login: ActivityProcessID(pid: 1100, start: 1_100_000))], appPID: app)))
        }
        let held = ActivityChips.of(made.loop, agentWaitingSince: nil, isAgent: false, in: snapshot)
        guard case .heldCore(let since)? = held.first else { return XCTFail("a core held for 5 min: \(held)") }
        XCTAssertGreaterThanOrEqual(snapshot.date.timeIntervalSince(since), ActivityChips.lasting)
        XCTAssertTrue(held[0].text(now: snapshot.date).hasPrefix("held a core for "))
        // The agent's subtree at 60%: named only while its tab waits.
        XCTAssertEqual(ActivityChips.of(made.agent, agentWaitingSince: nil, isAgent: true, in: snapshot), [])
        let longAgo = snapshot.date.addingTimeInterval(-3_600)
        let idle = ActivityChips.of(made.agent, agentWaitingSince: longAgo, isAgent: true, in: snapshot)
        guard case .idleBurning(let cpu, let burnSince)? = idle.first else { return XCTFail("an idle agent burning: \(idle)") }
        XCTAssertEqual(cpu, 60, accuracy: 0.5)
        XCTAssertTrue(idle[0].text(now: snapshot.date).hasPrefix("⚠ idle at 60% for "))
        XCTAssertGreaterThan(burnSince, longAgo, "waiting since long before: the burn's own start")
        // It worked hard, then asked its question a minute ago: not idle yet.
        XCTAssertEqual(ActivityChips.of(made.agent, agentWaitingSince: snapshot.date.addingTimeInterval(-60), isAgent: true, in: snapshot), [])
        // Waiting began after the burn: counted from the wait, once it lasted 5 minutes.
        let asked = snapshot.date.addingTimeInterval(-ActivityChips.lasting - 30)
        let late = ActivityChips.of(made.agent, agentWaitingSince: asked, isAgent: true, in: snapshot)
        XCTAssertEqual(late, [.idleBurning(cpu: cpu, since: asked)], "the minutes are the idle ones")
        XCTAssertEqual(late.first?.text(now: snapshot.date), "⚠ idle at 60% for 5 min")
        made.snapshot = snapshot

        // The rows carry them: the agent's tab waiting.
        var options = ActivityRows.Options()
        var facts = ActivityTabFacts(id: tab, title: "fake-agent", waiting: true)
        facts.waitingSince = longAgo
        options.tabs = [tab: facts]
        options.grouping = ActivityGrouping.none
        options.tree = false
        options.scope = .mac
        let content = ActivityRows.content(of: snapshot, options)
        // The strips are the list's rows' (10.4).
        let listed = content.list.compactMap { item -> ActivityProcessRow? in
            guard case .process(let row) = item else { return nil }
            return row
        }
        let rows = Dictionary(uniqueKeysWithValues: listed.map { ($0.identity, $0) })
        XCTAssertEqual(rows[made.agent]?.chips.count, 1)
        if case .idleBurning? = rows[made.agent]?.chips.first {} else { XCTFail("the agent's row says it") }
        if case .heldCore? = rows[made.loop]?.chips.first {} else { XCTFail("the loop's row says it") }
        XCTAssertEqual(rows[made.loop]?.strip?.count, 60)
        XCTAssertEqual((rows[made.loop]?.strip?.last ?? nil) ?? 0, 100, accuracy: 0.5)
        XCTAssertNil(rows[ActivityProcessID(pid: 1, start: 1_000)]?.strip, "another user's: no history")
        XCTAssertNil(content.processes.first { $0.identity == made.loop }?.strip, "the flat rows carry none…")
        var byStrip = options
        byStrip.processSort = ResourceSort(column: "cpu15", ascending: false)
        let sorted = ActivityRows.content(of: snapshot, byStrip)
        XCTAssertEqual(sorted.processes.first { $0.identity == made.loop }?.strip?.count, 60, "…unless they sort by them")
    }

    func testAMovedServerAskedForOnePortAndGotTheNext() {
        XCTAssertEqual(ActivityMovedServers.asked("node acme/vite.js --port 3000"), 3000)
        XCTAssertEqual(ActivityMovedServers.asked("next dev -p 4000"), 4000)
        XCTAssertEqual(ActivityMovedServers.asked("serve --port=5000 dist"), 5000)
        XCTAssertEqual(ActivityMovedServers.asked("acme-server -p8080"), 8080)
        XCTAssertNil(ActivityMovedServers.asked("ssh -p 2222 fake-host"), "a client's -p is the port it connects to")
        XCTAssertNil(ActivityMovedServers.asked("python3 -m http.server"))

        let main = UUID()
        let feature = UUID()
        func row(_ pid: pid_t, _ command: String, ports: [Int], tab: UUID, started: TimeInterval) -> ActivityProcessRow {
            var row = ActivityProcessRow(
                id: "\(pid):1", identity: ActivityProcessID(pid: pid, start: 1), name: "node", cpu: 1, memory: nil, threads: nil, state: .sleeping,
                started: Date(timeIntervalSince1970: started), startedText: "", user: "fake", isOwn: true, tab: tab, tabTitle: nil)
            row.command = command
            row.label = "vite"
            row.listening = ports
            row.checkout = tab == main ? "acme" : "acme-feature"
            return row
        }
        let tabs = [
            main: ActivityTabFacts(id: main, title: "web", checkout: "/work/acme", repository: "acme"),
            feature: ActivityTabFacts(id: feature, title: "web", checkout: "/work/acme-feature", repository: "acme"),
        ]
        let first = row(10, "node vite.js --port 3000", ports: [3000], tab: main, started: 100)
        let moved = row(11, "node vite.js --port 3000", ports: [3001], tab: feature, started: 200)
        let found = ActivityMovedServers.find([first, moved], tabs: tabs)
        XCTAssertEqual(found[moved.id], .moved(asked: 3000, got: 3001, holder: "acme"))
        XCTAssertNil(found[first.id])
        XCTAssertEqual(found[moved.id]?.text(now: Date()), "asked 3000, got 3001")
        // Without asking: two checkouts of one repository, the later above the other.
        let plain = row(12, "node vite.js", ports: [5174], tab: feature, started: 300)
        let older = row(13, "node vite.js", ports: [5173], tab: main, started: 50)
        XCTAssertEqual(ActivityMovedServers.find([older, plain], tabs: tabs)[plain.id], .moved(asked: 5173, got: 5174, holder: "acme"))
        // Another repository's server isn't a move.
        let other = [feature: ActivityTabFacts(id: feature, title: "web", checkout: "/work/globex", repository: "globex"), main: tabs[main]!]
        XCTAssertNil(ActivityMovedServers.find([older, plain], tabs: other)[plain.id])
    }

    // MARK: New and ended

    func testANewProcessIsTintedAndAnEndedOneShownOnceMore() throws {
        let sampler = ActivitySampler(kernel: kernel)
        add(1, parent: 0, uid: 0, name: "launchd")
        let old = add(3000, parent: 1, name: "acme-old")
        let gone = add(3001, parent: 1, name: "acme-gone")
        kernel.advance(10 * second)
        var options = ActivityRows.Options()
        options.grouping = .none
        let first = try XCTUnwrap(sampler.tickNow(ActivityDemand(.full), context: ActivityContext()))
        let made = ActivityRows.content(of: first, options)
        let shown = made.processes
        XCTAssertEqual(shown.filter(\.isNew).count, 0, "a page just opened marks nothing new")

        // The next census: one gone, one started now.
        kernel.remove(3001)
        let started = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        var fresh = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 3002, start: started, parent: 1, uid: 501, name: "acme-new"))
        fresh.name = "acme-new"
        fresh.usage = FakeActivityKernel.usage()
        kernel.add(fresh)
        kernel.advance(2 * second)
        let second = try XCTUnwrap(sampler.tickNow(ActivityDemand(.full), context: ActivityContext()))
        options.previous = shown
        options.marksNew = true
        options.shownAt = made.madeAt
        let content = ActivityRows.content(of: second, options)
        let rows = Dictionary(content.processes.map { ($0.identity, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(rows[ActivityProcessID(pid: 3002, start: started)]?.isNew, true)
        XCTAssertEqual(rows[old]?.isNew, false)
        XCTAssertEqual(rows[gone]?.ended, true, "shown once more, dimmed")
        XCTAssertNil(rows[gone]?.cpu)
        XCTAssertEqual(content.summary.shown, content.processes.count - 1, "an ended row isn't counted as shown")
        XCTAssertFalse(content.listeners.contains { $0.holder == gone })
        // The same census made again (a sort): still once, as it was.
        options.previous = content.processes
        options.repeatsEnded = true
        XCTAssertEqual(ActivityRows.content(of: second, options).processes.first { $0.identity == gone }?.ended, true)
        // Once: the next census has it no more; the new one stays tinted a
        // tick at least, 3 s at least, then isn't.
        options.repeatsEnded = false
        options.shownAt = content.madeAt
        let third = ActivityRows.content(of: second, options)
        XCTAssertNil(third.processes.first { $0.identity == gone })
        XCTAssertEqual(third.processes.first { $0.identity.pid == 3002 }?.isNew, true, "a tick on, inside its 3 s")
        kernel.advance(2 * self.second)
        let later = try XCTUnwrap(sampler.tickNow(ActivityDemand(.full), context: ActivityContext()))
        options.previous = third.processes
        options.shownAt = third.madeAt
        let wait = Date().addingTimeInterval(ActivityRows.newFor)
        // The census's date is the wall clock's: past 3 s, it is plain.
        var fourth = ActivityRows.content(of: later, options)
        if Date() < wait {
            XCTAssertEqual(fourth.processes.first { $0.identity.pid == 3002 }?.isNew, true)
        }
        var plain = later
        plain.date = wait.addingTimeInterval(1)
        options.previous = fourth.processes
        fourth = ActivityRows.content(of: plain, options)
        XCTAssertEqual(fourth.processes.first { $0.identity.pid == 3002 }?.isNew, false, "3 s and a tick on: plain")
    }

    /// New is absent from the rows shown, whatever its age: a census 5 s
    /// apart still tints a process that started 4 s before it.
    func testANewProcessIsTintedAtASlowCadence() throws {
        let sampler = ActivitySampler(kernel: kernel)
        add(1, parent: 0, uid: 0, name: "launchd")
        add(3000, parent: 1, name: "acme-old")
        var options = ActivityRows.Options()
        options.grouping = .none
        let first = try XCTUnwrap(sampler.tickNow(ActivityDemand(.full), context: ActivityContext()))
        let made = ActivityRows.content(of: first, options)
        let started = UInt64(first.date.timeIntervalSince1970 * 1_000_000) + 1_000_000
        var fresh = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 3005, start: started, parent: 1, uid: 501, name: "acme-new"))
        fresh.name = "acme-new"
        fresh.usage = FakeActivityKernel.usage()
        kernel.add(fresh)
        kernel.advance(5 * second)
        var later = try XCTUnwrap(sampler.tickNow(ActivityDemand(.full), context: ActivityContext()))
        later.date = first.date.addingTimeInterval(5)
        options.previous = made.processes
        options.marksNew = true
        options.shownAt = made.madeAt
        let rows = ActivityRows.content(of: later, options).processes
        XCTAssertEqual(rows.first { $0.identity.pid == 3005 }?.isNew, true, "started 4 s before the census, new to the person")
        XCTAssertEqual(rows.first { $0.identity.pid == 3000 }?.isNew, false)
        // A wider scope's: absent from the rows, but there before them.
        options.previous = []
        XCTAssertEqual(ActivityRows.content(of: later, options).processes.first { $0.identity.pid == 3000 }?.isNew, false)
    }

    /// An ended row is shown, never counted: not in its group's header nor
    /// its agent's counts, not in Left Behind's, nor a bulk Stop's.
    func testAnEndedRowIsNeverCountedInAGroup() throws {
        let tab = UUID()
        let sampler = ActivitySampler(kernel: kernel)
        let made = busyMac(ticks: 3, sampler: sampler, tab: tab)
        let first = try XCTUnwrap(made.snapshot)
        var options = ActivityRows.Options()
        options.grouping = .checkout
        options.tabs = [tab: ActivityTabFacts(id: tab, title: "fake-agent", checkout: "/work/acme", agent: .claude)]
        options.scope = .mac
        let shown = ActivityRows.content(of: first, options)
        func header(_ content: ActivityPageContent) -> ActivityGroupRow? {
            for item in content.list { if case .group(let row) = item, row.kind == .tab { return row } }
            return nil
        }
        let before = try XCTUnwrap(header(shown))
        // The agent's child ends.
        kernel.remove(1103)
        kernel.advance(2 * second)
        let next = try XCTUnwrap(
            sampler.tickNow(
                ActivityDemand(.full),
                context: ActivityContext(panes: [ActivityContext.Pane(tag: "fake-pane", tab: tab, login: ActivityProcessID(pid: 1100, start: 1_100_000))], appPID: app)))
        options.previous = shown.processes
        options.marksNew = true
        options.shownAt = shown.madeAt
        let content = ActivityRows.content(of: next, options)
        XCTAssertTrue(content.processes.contains { $0.identity == made.child && $0.ended }, "shown once more")
        let listed = content.list.contains { if case .process(let row) = $0 { row.identity == made.child && row.ended } else { false } }
        XCTAssertTrue(listed, "under its group, dimmed")
        let after = try XCTUnwrap(header(content))
        XCTAssertEqual(after.count, before.count - 1, "its tab's header doesn't count it")
        // Left Behind: an ended leftover isn't in the header nor a bulk Stop.
        var left = content.processes.first { $0.identity == made.child }!
        left.owner = ActivityOwner(place: .leftBehind, rule: 8, reason: "fake")
        left.bulkEligible = true
        var live = content.processes.first { $0.identity == made.loop }!
        live.owner = ActivityOwner(place: .leftBehind, rule: 8, reason: "fake")
        live.bulkEligible = true
        let section = ActivityRows.leftBehindList([left, live], tabs: [:], options: options)
        guard case .group(let leftHeader)? = section.first else { return XCTFail("a Left Behind group") }
        XCTAssertEqual(leftHeader.count, 1)
        XCTAssertEqual(leftHeader.detail, "all certain")
        XCTAssertEqual(ActivityRows.certainInGroup(of: live, in: [left, live], tabs: [:]).map(\.identity), [made.loop])
    }

    /// Selected, an ended row has no detail, and of its verbs only the
    /// copies: its pid may be another process's by now.
    @MainActor func testAnEndedRowHasNoDetailAndOnlyItsCopies() async throws {
        add(1, parent: 0, uid: 0, name: "launchd")
        add(app, parent: 1, name: "Overterm")
        let gone = add(3001, parent: 1, name: "acme-gone")
        let monitor = ActivityMonitor(sampler: ActivitySampler(kernel: kernel))
        monitor.setContext(ActivityContext(appPID: app))
        let page = ActivityPageModel(monitor: monitor)
        page.isolated = false
        page.grouping = .none
        page.visible = true
        let listed = await eventually { page.hasRead && page.content.processes.contains { $0.identity == gone } }
        XCTAssertTrue(listed)
        kernel.remove(3001)
        let ended = await eventually {
            self.kernel.advance(2 * self.second)
            Task { _ = await monitor.tick() }
            return page.content.processes.contains { $0.identity == gone && $0.ended }
        }
        XCTAssertTrue(ended, "shown once more")
        page.selection = [gone.id]
        XCTAssertNil(page.detail, "never in the detail")
        XCTAssertNil(page.selectedProcess)
        let titles = page.verbs(for: [gone.id], copy: { _ in }).map(\.title)
        XCTAssertEqual(titles, ["Copy PID", "Copy"], "no Sample, Open Files, Reveal or Ask on a pid that ended")
        page.visible = false
    }

    @MainActor private func eventually(_ seconds: Double = 10, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: Preventing sleep

    func testSleepAssertionsByTypeOnly() {
        let holds = ActivitySleepHold.holds([
            10: ["PreventUserIdleSystemSleep", "UserIsActive"], 11: ["PreventUserIdleDisplaySleep", "PreventSystemSleep"], 12: ["UserIsActive"],
        ])
        XCTAssertEqual(holds[10], .system)
        XCTAssertEqual(holds[11], [.system, .display])
        XCTAssertNil(holds[12], "a declared activity keeps nothing awake for long")
        XCTAssertEqual(holds[11]?.text, "System, Display")

        add(1, parent: 0, uid: 0, name: "launchd")
        let awake = add(3100, parent: 1, name: "acme-player")
        let other = add(3101, parent: 1, uid: 0, name: "fake-daemon")
        kernel.setSleepHolds([3100: .display, 3101: .system])
        let sampler = ActivitySampler(kernel: kernel)
        let snapshot = sampler.tickNow(ActivityDemand(.full), context: ActivityContext())
        var options = ActivityRows.Options()
        options.grouping = nil
        let rows = snapshot.map { ActivityRows.content(of: $0, options).processes } ?? []
        XCTAssertEqual(rows.first { $0.identity == awake }?.sleepHold, .display)
        XCTAssertEqual(rows.first { $0.identity == other }?.sleepHold, .system, "every user's: a public call")
        XCTAssertEqual(ActivityRows.sorted(rows, by: ResourceSort(column: "sleep", ascending: false)).first?.sleepHold, .display)
        // At the light level nothing is asked.
        kernel.resetCounts()
        _ = sampler.tickNow(ActivityDemand(.light(tabs: nil)), context: ActivityContext())
        XCTAssertEqual(kernel.count("sleepAssertions"), 0)
    }
}
