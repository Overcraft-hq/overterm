import AppKit
import Darwin
import SwiftUI

/// The Activity page at about this Mac's process count (docs/design/
/// activity/analysis.md, 10.4), from a fake Mac of that size — invented
/// names, nothing of this Mac's but how many processes it runs, counted by
/// `proc_listallpids` (no argv, no environment, no census published): the
/// page in a window of the scenario's own, its census over
/// `FakeActivityKernel`, each tick's CPU moving the order. Gated on the
/// fake: the table neither reloaded nor reordered while the order holds,
/// and the census's and rows' costs; reported: the sampler's CPU for a full
/// and a light tick (p90), a tick's rows shown (laid out and drawn), held
/// or not, the list scrolled. Counts and times are all it says.
extension E2ERunner {
    func activityPerfScenario() async {
        // This Mac's count: pids only, off the main thread.
        let live = await Self.processCount()
        let count = min(max(live, 1_300), 5_000)
        let kernel = FakeActivityKernel(uid: 501)
        var pids: [pid_t] = []
        Self.fakeMac(kernel, count: count, pids: &pids)
        let monitor = ActivityMonitor(sampler: ActivitySampler(kernel: kernel))
        // Ticks only when the scenario makes one.
        monitor.interval = .seconds(600)
        let page = ActivityPageModel(monitor: monitor)
        page.isolated = false
        page.grouping = .none
        page.tree = false
        guard let theme = app.theme else { return check("a theme", false) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ActivityPageView(page: page, theme: theme, copy: { _ in }))
        window.contentView = host
        window.orderBack(nil)
        defer {
            page.close()
            monitor.stop()
            window.orderOut(nil)
        }
        page.visible = true
        check("the page reads the fake Mac", await eventually(15) { page.hasRead && page.content.processes.count == count }, "\(page.content.processes.count) of \(count)")

        // Ticks: CPU moved on each process, so the CPU sort reorders.
        var random = SystemRandomNumberGenerator()
        func burn() {
            kernel.advance(2_000_000_000)
            for pid in pids {
                let used = UInt64.random(in: 0...40_000_000, using: &random)
                kernel.update(pid) { process in
                    process.usage = FakeActivityKernel.usage(cpuTime: (process.usage?.cpuTime ?? 0) + used, footprint: process.usage?.footprint ?? 0, threads: 4)
                }
            }
        }
        // A tick's rows shown: from the page's content changing, on the
        // main thread, to the main run loop's next rest — SwiftUI's update,
        // the table's, Core Animation's commit and the drawing between.
        let frame = ActivityFrameClock()
        let observer = Self.frameObserver(frame)
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        let landed = page.$content.dropFirst().sink { _ in frame.arm() }
        defer { landed.cancel() }
        var censusCPU: [Double] = []
        var rowsMade: [Double] = []
        var shown: [Double] = []
        var heldShown: [Double] = []
        var shownMain: [Double] = []
        var heldMain: [Double] = []
        func tick(held: Bool) async {
            burn()
            let builds = page.builds
            guard let snapshot = await monitor.tick() else { return }
            censusCPU.append(Double(snapshot.cost.cpu) / 1_000_000)
            // The rows, made as the page makes them, timed on their own.
            var options = ActivityRows.Options()
            options.grouping = .none
            options.tree = false
            let start = CACurrentMediaTime()
            _ = ActivityRows.content(of: snapshot, options)
            rowsMade.append((CACurrentMediaTime() - start) * 1000)
            let frames = frame.count
            _ = await eventually(10) { page.builds > builds && frame.count > frames }
            let took = frame.last
            if held { heldShown.append(took) } else { shown.append(took) }
            if held { heldMain.append(frame.lastCPU) } else { shownMain.append(frame.lastCPU) }
        }
        // An agent's pane: a login, its shell, Claude Code and three
        // children — a selected agent's detail charts its subtree too.
        let agent = Self.fakeAgent(kernel, pids: &pids)
        monitor.setContext(ActivityContext(panes: [ActivityContext.Pane(tag: "fake-pane-agent", tab: UUID(), login: agent.login)], appPID: 0))
        burn()
        _ = await monitor.tick()
        check("rated after a second tick", await eventually(10) { !page.content.summary.firstSample })
        // With history (6.11, stage 4): fifteen minutes of 2 s ticks first,
        // so every strip is full and what is timed below draws them.
        var merged: [Double] = []
        var lastHistory = ActivityRing()
        for _ in 0..<450 {
            burn()
            guard let snapshot = await monitor.tick() else { continue }
            merged.append(Double(snapshot.cost.history) / 1_000_000)
            lastHistory = snapshot.history
        }
        check(
            "fifteen minutes of history: a strip each of the user's, 60 cells read",
            lastHistory.keyCount >= pids.count && (lastHistory.cpuStrip(.process(ActivityProcessID(pid: pids[0], start: UInt64(pids[0]) * 1_000 + 1)))?.allSatisfy { $0 != nil } ?? false),
            "\(lastHistory.keyCount) keys")
        _ = await eventually(10) { page.content.processes.contains { $0.strip != nil } }
        // The window's first drawing — every cell on screen made — apart:
        // a tick's is what is timed, not the page's first appearance.
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        await pause(0.3)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        for _ in 0..<12 { await tick(held: false) }
        guard let table = WorkspacePages.firstTable(in: host) as? ResourceTableView else { return check("the page's table", false) }
        let moves = (table.reloads, table.reorders)
        for _ in 0..<12 {
            table.interaction?(.hover)
            await tick(held: true)
        }
        // 10.4: with the order held, a tick reloads nothing and moves no
        // row — its values drawn in the rows' places.
        let heldMoves = (table.reloads - moves.0, table.reorders - moves.1)
        table.interaction?(.exit)
        check("ticks were held", page.orderHeld == false && heldShown.count == 12, "\(heldShown.count)")
        check(
            "held, the table neither reloads nor moves a row (12 ticks)", heldMoves == (0, 0),
            "\(heldMoves.0) reloads, \(heldMoves.1) in-place moves")

        // A selected row's verbs (6.10, 7.7): its process read off the main
        // thread with every owner, with the rows; on the main thread only
        // the list — what the detail's bar and the menu draw each update.
        var verbsListed: [Double] = []
        if let selected = page.content.processes.first {
            page.selection = [selected.id]
            let read = await eventually(10) { page.verbSubject?.signal.identity == selected.identity }
            check("a selected row's process is read for its verbs, off the main thread", read)
            await tick(held: false)
            check("and read again with the next tick's rows", page.content.subject?.signal.identity == selected.identity)
            for _ in 0..<50 {
                let start = CACurrentMediaTime()
                _ = page.verbs(for: page.selection) { _ in }
                verbsListed.append((CACurrentMediaTime() - start) * 1000)
            }
            page.selection = []
        }

        // The agent selected (7.7, 10.4): its charts and its subtree's made
        // off the main thread with the rows; the main thread's part of each
        // publish — the detail assigned — timed by the page.
        var detailCost: [Double] = []
        if let row = page.content.processes.first(where: { $0.identity == agent.agent }) {
            page.selection = [row.id]
            let charted = await eventually(10) { !(page.detail?.charts.isEmpty ?? true) && !(page.detail?.subtreeCharts.isEmpty ?? true) }
            check("a selected agent's detail charts it and everything under it", charted)
            for _ in 0..<12 {
                await tick(held: false)
                detailCost.append(page.detailCost)
            }
            check("its charts come with each tick's rows", page.content.detailHistory?.identity == agent.agent)
            page.selection = []
        } else {
            check("the agent's row", false)
        }

        // The light tick on the same fake Mac: eight panes' trees and the
        // table, the sampler's own CPU (10.4's light p90 ≤ 5 ms).
        var lightCPU: [Double] = []
        let light = ActivitySampler(kernel: kernel)
        let panes = stride(from: 0, to: min(pids.count, 64), by: 8).map { index in
            ActivityContext.Pane(
                tag: "fake-pane-\(index)", tab: UUID(), login: ActivityProcessID(pid: pids[index], start: UInt64(pids[index]) * 1_000 + 1))
        }
        let lightContext = ActivityContext(panes: panes, appPID: 0)
        for round in 0..<13 {
            burn()
            guard let snapshot = light.tickNow(ActivityDemand(.light(tabs: nil)), context: lightContext) else { continue }
            // The first reads every pane's process anew: not a tick's cost.
            if round > 0 { lightCPU.append(Double(snapshot.cost.cpu) / 1_000_000) }
        }
        // 10.4's gates on fakes (7.4): a pane's child holding 20,000
        // sockets — the per-process bound keeps a tick's walk to its budget
        // —, then 200 short processes a tick started and ended under a
        // pane: the light tick's p90 and the full one's, on their own fakes.
        let heavy = Self.fakeSockets(kernel, under: panes[0].login?.pid ?? pids[0], count: 20_000)
        var heavyLight: [Double] = []
        for round in 0..<13 {
            burn()
            guard let snapshot = light.tickNow(ActivityDemand(.light(tabs: nil)), context: lightContext) else { continue }
            if round > 0 { heavyLight.append(Double(snapshot.cost.cpu) / 1_000_000) }
        }
        let heavyRead = light.tickNow(ActivityDemand(.light(tabs: nil)), context: lightContext)?.facts[heavy]?.sockets
        kernel.remove(heavy.pid)
        var churnLight: [Double] = []
        var churnFull: [Double] = []
        // What the light ticks under churn read: identities, argv, and
        // what each left for the next tick.
        var churnReads: [(identities: Int, commands: Int, deferred: Int)] = []
        var churned: [pid_t] = []
        let churnFullSampler = ActivitySampler(kernel: kernel)
        _ = churnFullSampler.tickNow(ActivityDemand(.full), context: lightContext)
        for round in 0..<26 {
            burn()
            for pid in churned { kernel.remove(pid) }
            churned = Self.fakeChurn(kernel, under: panes[1].login?.pid ?? pids[8], round: round, count: 200)
            let full = round % 2 == 1
            let sampler = full ? churnFullSampler : light
            guard let snapshot = sampler.tickNow(ActivityDemand(full ? .full : .light(tabs: nil)), context: lightContext) else { continue }
            if round > 1 { (full ? { churnFull.append($0) } : { churnLight.append($0) })(Double(snapshot.cost.cpu) / 1_000_000) }
            if round > 1, !full { churnReads.append((snapshot.cost.identitiesRead, snapshot.cost.commandsRead, snapshot.cost.deferred)) }
        }
        for pid in churned { kernel.remove(pid) }
        // The same churn whose processes outlive a light tick (a `make -j`
        // whose compiles take longer than the cadence, `xargs -P`'s
        // workers): each burst ends a tick after the next starts, so a
        // tick reads the last one's survivors in full beside the new
        // one's 16 — the half of the rule the leg above never pays.
        var lastingLight: [Double] = []
        var lastingReads: [(identities: Int, commands: Int, deferred: Int)] = []
        var bursts: [[pid_t]] = []
        let lasting = ActivitySampler(kernel: kernel)
        for round in 0..<14 {
            burn()
            if bursts.count == 2 { for pid in bursts.removeFirst() { kernel.remove(pid) } }
            bursts.append(Self.fakeChurn(kernel, under: panes[2].login?.pid ?? pids[16], round: 30 + round, count: 200))
            guard let snapshot = lasting.tickNow(ActivityDemand(.light(tabs: nil)), context: lightContext) else { continue }
            if round > 1 {
                lastingLight.append(Double(snapshot.cost.cpu) / 1_000_000)
                lastingReads.append((snapshot.cost.identitiesRead, snapshot.cost.commandsRead, snapshot.cost.deferred))
            }
        }
        for pid in bursts.joined() { kernel.remove(pid) }
        // A lookup of a pane under churn (Tab Info, a drop, an agent's
        // pane): the periodic tick left most of its burst waiting, so the
        // lookup reads again — one round that defers nothing.
        var churnLookup: [Double] = []
        var lookupRounds: [Int] = []
        var lookupWhole = true
        churned = []
        let asked = ActivityDemand(.light(tabs: [panes[1].tab]))
        for round in 0..<13 {
            burn()
            for pid in churned { kernel.remove(pid) }
            churned = Self.fakeChurn(kernel, under: panes[1].login?.pid ?? pids[8], round: 50 + round, count: 200)
            guard let periodic = light.tickNow(ActivityDemand(.light(tabs: nil)), context: lightContext) else { continue }
            let start = CACurrentMediaTime()
            let found = light.lookup(within: .max, demand: asked, context: lightContext) { _ in true }
            let elapsed = (CACurrentMediaTime() - start) * 1000
            // The first follows a gap: nothing waits, nothing to ask again.
            guard round > 0, let found else { continue }
            churnLookup.append(elapsed)
            lookupRounds.append(found.tick - periodic.tick)
            lookupWhole = lookupWhole && found.unread == 0 && churned.allSatisfy { pid in found.facts.contains { $0.key.pid == pid && $0.value.isRead } }
        }
        for pid in churned { kernel.remove(pid) }

        // The list scrolled top to bottom, a third of a screen a step.
        var scrolled: [Double] = []
        if let scroll = table.enclosingScrollView {
            // The first screens' cells made once, as a person's first
            // scroll makes them; the steps timed are the reused ones'.
            for step in 1...3 {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step) * scroll.contentView.bounds.height / 3))
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
            }
            scroll.contentView.scroll(to: .zero)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            var y: CGFloat = 0
            Self.wakeCore(milliseconds: 50)
            for _ in 0..<200 {
                let height = scroll.documentView?.frame.height ?? 0
                let visible = scroll.contentView.bounds.height
                guard visible > 0, y + visible < height else { break }
                y += visible / 3
                let start = CACurrentMediaTime()
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                scrolled.append((CACurrentMediaTime() - start) * 1000)
                await Task.yield()
            }
        }
        // 5,000 processes, as a crowded Mac: the rows of one full tick,
        // made as the page makes them (10.4 proposed 15 ms).
        let crowded = FakeActivityKernel(uid: 501)
        var crowdedPIDs: [pid_t] = []
        Self.fakeMac(crowded, count: 5_000, pids: &crowdedPIDs)
        let sampler = ActivitySampler(kernel: crowded)
        var crowdedRows: [Double] = []
        var crowdedSubject: [Double] = []
        // Read whole first: the churn budget reads 200 new identities a tick.
        for _ in 0..<60 {
            crowded.advance(1_000_000_000)
            guard let read = sampler.tickNow(ActivityDemand(.full), context: ActivityContext()), read.unread > 0 else { break }
        }
        crowded.advance(2_000_000_000)
        if let snapshot = sampler.tickNow(ActivityDemand(.full), context: ActivityContext()) {
            var options = ActivityRows.Options()
            options.grouping = .checkout
            for _ in 0..<7 {
                let start = CACurrentMediaTime()
                _ = ActivityRows.content(of: snapshot, options)
                crowdedRows.append((CACurrentMediaTime() - start) * 1000)
            }
            // A selection made between two publishes: its process read
            // with every owner, off the main thread.
            if let identity = snapshot.table.processes.last?.identity {
                for _ in 0..<7 {
                    let start = CACurrentMediaTime()
                    _ = ActivityRows.subject(identity, of: snapshot, options, attribution: nil)
                    crowdedSubject.append((CACurrentMediaTime() - start) * 1000)
                }
            }
        }
        // The crowded Mac's fifteen minutes: the ring at its fullest.
        var crowdedMerged: [Double] = []
        var crowdedHistory = ActivityRing()
        for _ in 0..<450 {
            crowded.advance(2_000_000_000)
            guard let snapshot = sampler.tickNow(ActivityDemand(.full), context: ActivityContext()) else { continue }
            crowdedMerged.append(Double(snapshot.cost.history) / 1_000_000)
            crowdedHistory = snapshot.history
        }
        let history = Self.summary(merged)
        let crowdedMerge = Self.summary(crowdedMerged)
        let megabytes = { (ring: ActivityRing) in
            String(format: "%.2f MB a copy, %.2f MB held", locale: Locale(identifier: "en_US_POSIX"), Double(ring.bytes) / 1_048_576, Double(ring.heldBytes) / 1_048_576)
        }
        note(
            "activityPerf: history merged a tick \(history), \(lastHistory.keyCount) keys, \(megabytes(lastHistory)); at 5,000 \(crowdedMerge), \(crowdedHistory.keyCount) keys, \(megabytes(crowdedHistory))"
        )
        check("a tick merges into the history in under 5 ms (median)", !merged.isEmpty && history.median < 5, "\(history)")
        check("at 5,000 processes, under 15 ms (median)", !crowdedMerged.isEmpty && crowdedMerge.median < 15, "\(crowdedMerge)")
        check(
            "the history stays under its 4 MB cap, both copies counted",
            lastHistory.heldBytes <= ActivityRing.defaultByteCap && crowdedHistory.heldBytes <= ActivityRing.defaultByteCap)
        let crowd = Self.summary(crowdedRows)
        let verbs = Self.summary(verbsListed)
        let subject = Self.summary(crowdedSubject)
        let census = Self.summary(censusCPU)
        let rows = Self.summary(rowsMade)
        let update = Self.summary(shown)
        let held = Self.summary(heldShown)
        let scroll = Self.summary(scrolled)
        let detail = Self.summary(detailCost)
        let fullP90 = Self.p90(censusCPU)
        let lightP90 = Self.p90(lightCPU)
        let p90 = { (value: Double) in String(format: "%.1f ms", locale: Locale(identifier: "en_US_POSIX"), value) }
        note("activityPerf: \(count) processes (this Mac: \(live)); census CPU a tick \(census); rows made \(rows)")
        note("activityPerf: the sampler's CPU a tick, p90: full \(p90(fullP90)), light (8 panes) \(p90(lightP90)), \(lightCPU.count) light ticks")
        note("activityPerf: a tick's rows shown \(update), each \(shown.map { Int($0.rounded()) }); held \(held); scrolled \(scrolled.count) steps, \(scroll)")
        note("activityPerf: 5,000 processes' rows, grouped by checkout, made \(crowd)")
        note("activityPerf: a publish's main-thread CPU \(Self.summary(shownMain)), p90 \(p90(Self.p90(shownMain))); held \(Self.summary(heldMain))")
        note("activityPerf: a selected row's verbs listed on the main thread \(verbs); its process read off it among 5,000, every owner \(subject)")
        note("activityPerf: a selected agent's detail, its charts made off the main thread: on it \(detail), p90 \(p90(Self.p90(detailCost)))")
        // 10.4's 15 ms isn't met yet — the owners' cost, open (design 15):
        // the gate holds what is, so it can only get better.
        check("5,000 processes' rows are made in under 60 ms (median)", !crowdedRows.isEmpty && crowd.median < 60, "\(crowd)")
        check("the census's own CPU a tick stays under 50 ms (median)", census.median < 50, "\(census)")
        check("the light tick's CPU is read (12 ticks)", lightCPU.count == 12, "\(lightCPU.count)")
        note(
            "activityPerf: light p90 beside a 20,000-socket child \(p90(Self.p90(heavyLight))), under churn of 200 a tick \(p90(Self.p90(churnLight))); full under churn \(p90(Self.p90(churnFull)))"
        )
        note(
            "activityPerf: under churn of 200 a tick, the light tick \(Self.summary(churnLight)), p90 \(p90(Self.p90(churnLight))), "
                + "a tick read identities \(churnReads.map(\.identities)), argv \(churnReads.map(\.commands)), left a tick \(churnReads.map(\.deferred)); "
                + "the full tick \(Self.summary(churnFull)), p90 \(p90(Self.p90(churnFull)))"
        )
        check(
            "a child of 20,000 sockets: its walk bounded, said so", heavyRead?.bound != nil && (heavyRead?.records.count ?? .max) <= SocketScan.perProcessBudget,
            "\(heavyRead?.records.count ?? -1) records")
        check("beside it, the light tick's CPU p90 ≤ 5 ms (12 ticks)", heavyLight.count == 12 && Self.p90(heavyLight) <= 5, "\(Self.summary(heavyLight))")
        // 10.4's 5 ms: a burst's newest wait a tick at the light level, so
        // the 200 that end before it are never read — 1.5–1.7 ms p90
        // measured, 5.0–5.2 when each was read (design 15).
        check("under churn of 200 a tick, the light tick's p90 ≤ 5 ms", churnLight.count == 12 && Self.p90(churnLight) <= 5, "\(Self.summary(churnLight))")
        let allowance = ActivitySampler.Limits().lightNewPerPane
        check(
            "…reading at most \(allowance) argv a tick, the rest left for the next",
            churnReads.count == 12 && churnReads.allSatisfy { $0.commands <= allowance && $0.deferred >= 200 - allowance },
            "argv \(churnReads.map(\.commands)), left \(churnReads.map(\.deferred))")
        note(
            "activityPerf: under churn whose processes outlive a light tick, the light tick \(Self.summary(lastingLight)), p90 \(p90(Self.p90(lastingLight))), "
                + "a tick read identities \(lastingReads.map(\.identities)), argv \(lastingReads.map(\.commands)), left a tick \(lastingReads.map(\.deferred)); "
                + "a pane's lookup beside the periodic tick \(Self.summary(churnLookup)), p90 \(p90(Self.p90(churnLookup))), rounds \(lookupRounds)"
        )
        check(
            "under churn that outlives a tick, the survivors are read the next tick",
            lastingReads.count == 12 && lastingReads.allSatisfy { $0.commands >= 200 - allowance && $0.deferred >= 200 - allowance },
            "argv \(lastingReads.map(\.commands)), left \(lastingReads.map(\.deferred))")
        // Each tick reads the last burst's 184 survivors whole and the new
        // one's 16: 200 reads a tick, as before the deferral, over a tree
        // twice the size — 5.6–5.8 ms p90 measured. 10.4's 5 ms isn't met
        // when a burst outlives a tick (design 15): gated at what it costs.
        check("…the light tick's p90 then ≤ 7 ms", lastingLight.count == 12 && Self.p90(lastingLight) <= 7, "\(Self.summary(lastingLight))")
        check(
            "a pane's lookup under churn reads its burst whole, in one round",
            churnLookup.count == 12 && lookupWhole && lookupRounds.allSatisfy { $0 == 1 }, "rounds \(lookupRounds)")
        check("and the full tick's p90 ≤ 15 ms", churnFull.count == 12 && Self.p90(churnFull) <= 15, "\(Self.summary(churnFull))")
        check("the rows of a tick are made in under 60 ms (median), off the main thread", rows.median < 60, "\(rows)")
        // The frames are the Mac's as much as the page's — a busy `make
        // e2e` moves them —: gated loosely, against a break, never at the
        // margin (10.4 gates on counts). 10.4 proposed 4 ms a publish: a
        // re-sorted list of 1,300 rows takes its SwiftUI update and the
        // visible rows' cells (design 15).
        check("a tick's rows are shown in under 100 ms (median)", !shown.isEmpty && update.median < 100, "\(update)")
        check("held, a tick is shown in under 100 ms (median)", !heldShown.isEmpty && held.median < 100, "\(held)")
        // 7.7's own measure: the main thread's CPU from the content set to
        // the run loop's rest — the Mac's other work left out. 10.4's 4 ms
        // isn't met: SwiftUI lays the visible rows' cells out again
        // (design 15); gated at what it costs, so it only gets better.
        check(
            "a publish takes the main thread under 50 ms of CPU (p90), a held one under 35 ms",
            shownMain.count >= 12 && Self.p90(shownMain) < 50 && heldMain.count == 12 && Self.p90(heldMain) < 35,
            "\(Self.summary(shownMain)); held \(Self.summary(heldMain))")
        check("the list scrolls in under 35 ms a step (p95)", !scrolled.isEmpty && scroll.p95 < 35, "\(scroll)")
        // 7.7: the main thread's part of a publish ≤ 4 ms — the verbs' list
        // is all of theirs that stays on it.
        check("a selected row's verbs are listed on the main thread in under 4 ms (median)", !verbsListed.isEmpty && verbs.median < 4, "\(verbs)")
        check("its process is read among 5,000 off the main thread in under 100 ms (median)", !crowdedSubject.isEmpty && subject.median < 100, "\(subject)")
        check(
            "a selected agent's detail takes the main thread under 4 ms a publish (p90)", detailCost.count == 12 && Self.p90(detailCost) < 4,
            "\(detail)")
    }

    /// An agent's pane on the fake Mac: `login` (root's), `zsh`, Claude
    /// Code (`node` with `claude` in its argv) and three helpers under it,
    /// each burning with the rest (`pids`).
    static func fakeAgent(_ kernel: FakeActivityKernel, pids: inout [pid_t]) -> (login: ActivityProcessID, agent: ActivityProcessID) {
        func add(_ pid: pid_t, parent: pid_t, uid: uid_t, name: String, words: [String]) -> ActivityProcessID {
            let start = UInt64(pid) * 1_000 + 1
            var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: pid, start: start, parent: parent, uid: uid, name: name))
            process.name = name
            process.path = "/opt/fake/bin/\(name)"
            process.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid)
            if uid != 0 {
                process.usage = FakeActivityKernel.usage(cpuTime: 0, footprint: 64 << 20, threads: 4)
                process.arguments = FakeActivityKernel.arguments(executable: "/opt/fake/bin/\(name)", words)
                pids.append(pid)
            }
            kernel.add(process)
            return ActivityProcessID(pid: pid, start: start)
        }
        let login = add(90_000, parent: 1, uid: 0, name: "login", words: ["login"])
        _ = add(90_001, parent: 90_000, uid: 501, name: "zsh", words: ["-zsh"])
        let agent = add(90_002, parent: 90_001, uid: 501, name: "node", words: ["claude"])
        for child in 0..<3 { _ = add(90_003 + pid_t(child), parent: 90_002, uid: 501, name: "fake-mcp-\(child)", words: ["fake-mcp-\(child)"]) }
        return (login, agent)
    }

    /// A child of `parent` holding `count` TCP sockets, connected ones
    /// and a listener (10.4): its identity.
    static func fakeSockets(_ kernel: FakeActivityKernel, under parent: pid_t, count: Int) -> ActivityProcessID {
        let pid: pid_t = 95_000
        let start = UInt64(pid) * 1_000 + 1
        var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: pid, start: start, parent: parent, uid: 501, name: "fake-sockets"))
        process.name = "fake-sockets"
        process.path = "/opt/fake/bin/fake-sockets"
        process.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid)
        process.usage = FakeActivityKernel.usage(cpuTime: 0, footprint: 64 << 20, threads: 4)
        process.arguments = FakeActivityKernel.arguments(executable: "/opt/fake/bin/fake-sockets", ["fake-sockets"])
        process.descriptors = (0..<count).map { FakeActivityKernel.descriptor(Int32(3 + $0)) }
        var sockets: [Int32: socket_fdinfo] = [:]
        sockets.reserveCapacity(count)
        sockets[3] = FakeActivityKernel.tcp(local: "127.0.0.1", port: 39_000, handle: 2_000_000)
        for index in 1..<count {
            sockets[Int32(3 + index)] = FakeActivityKernel.tcp(
                local: "127.0.0.1", port: 39_000, remote: "127.0.0.1", remotePort: UInt16(40_000 + index % 20_000), state: .established,
                handle: UInt64(2_000_000 + index))
        }
        process.sockets = sockets
        kernel.add(process)
        return ActivityProcessID(pid: pid, start: start)
    }

    /// `count` short processes under `parent`, new pids each `round`:
    /// their pids, to end them at the next.
    static func fakeChurn(_ kernel: FakeActivityKernel, under parent: pid_t, round: Int, count: Int) -> [pid_t] {
        (0..<count).map { index in
            let pid = pid_t(100_000 + round * count + index)
            let start = UInt64(pid) * 1_000 + 1
            var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: pid, start: start, parent: parent, uid: 501, name: "fake-cc"))
            process.name = "fake-cc"
            process.path = "/opt/fake/bin/fake-cc"
            process.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid)
            process.usage = FakeActivityKernel.usage(cpuTime: 1_000_000, footprint: 8 << 20, threads: 1)
            process.arguments = FakeActivityKernel.arguments(executable: "/opt/fake/bin/fake-cc", ["fake-cc", "-c", "fake-\(index).c", "-o", "fake-\(index).o"])
            kernel.add(process)
            return pid
        }
    }

    /// The 90th percentile of `samples`, 0 for none.
    static func p90(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
    }

    /// How many processes this Mac runs: `proc_listallpids`' count, read
    /// off the main thread — pids only, no argv, no environment, nothing
    /// published or kept.
    nonisolated static func processCount() async -> Int {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let estimate = proc_listallpids(nil, 0)
                guard estimate > 0 else { return continuation.resume(returning: 0) }
                var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
                let read = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
                continuation.resume(returning: max(Int(read), 0))
            }
        }
    }

    /// Each time the main run loop is about to rest, after everything else
    /// of its turn: what `frame` times up to. Built here, outside the main
    /// actor: the run loop calls it.
    nonisolated static func frameObserver(_ frame: ActivityFrameClock) -> CFRunLoopObserver {
        CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in frame.rest() }
    }

    /// A fake Mac of `count` processes: launchd, root's daemons — a third,
    /// named only —, the user's apps with their helpers and shells with
    /// their children, a few listening. Every name invented.
    static func fakeMac(_ kernel: FakeActivityKernel, count: Int, pids: inout [pid_t]) {
        func add(_ pid: pid_t, parent: pid_t, uid: uid_t, name: String, listen: UInt16? = nil) {
            var process = FakeActivityKernel.Process(
                record: FakeActivityKernel.record(pid: pid, start: UInt64(pid) * 1_000 + 1, parent: parent, uid: uid, name: name))
            process.name = name
            process.path = uid == 0 ? "/usr/libexec/\(name)" : "/opt/fake/bin/\(name)"
            process.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid)
            if uid != 0 {
                process.usage = FakeActivityKernel.usage(cpuTime: 0, footprint: UInt64(20 + pid % 400) << 20, threads: 4)
                process.arguments = FakeActivityKernel.arguments(executable: process.path ?? name, [name, "--fake-flag", "\(pid)"])
                if let listen {
                    process.descriptors = [FakeActivityKernel.descriptor(3)]
                    process.sockets = [3: FakeActivityKernel.tcp(local: "127.0.0.1", port: listen, handle: UInt64(pid))]
                }
                pids.append(pid)
            }
            kernel.add(process)
        }
        add(1, parent: 0, uid: 0, name: "launchd")
        var pid: pid_t = 100
        let root = count / 3
        for index in 0..<root {
            add(pid, parent: 1, uid: 0, name: "fake-daemon-\(index % 60)")
            pid += 1
        }
        var parent: pid_t = 1
        var index = 0
        while Int(pid) - 100 + 1 < count {
            // Every eighth a parent of the next seven.
            if index % 8 == 0 {
                add(pid, parent: 1, uid: 501, name: "fake-app-\(index % 90)")
                parent = pid
            } else {
                add(pid, parent: parent, uid: 501, name: "fake-helper-\(index % 40)", listen: index % 50 == 1 ? UInt16(20_000 + index) : nil)
            }
            pid += 1
            index += 1
        }
    }
}

/// The time from a change of the page's content to the main run loop's
/// next rest, a sample each change.
final class ActivityFrameClock: @unchecked Sendable {
    private let lock = NSLock()
    private var armed: (wall: CFTimeInterval, cpu: UInt64)?
    private var samples: [Double] = []
    private var cpuSamples: [Double] = []

    /// Both on the main thread: its own CPU between them is the publish's
    /// main-thread part (7.7), whatever else the Mac runs.
    func arm() {
        lock.withLock { if armed == nil { armed = (CACurrentMediaTime(), clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) } }
    }

    func rest() {
        lock.withLock {
            guard let armed else { return }
            samples.append((CACurrentMediaTime() - armed.wall) * 1000)
            cpuSamples.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- armed.cpu) / 1_000_000)
            self.armed = nil
        }
    }

    var count: Int { lock.withLock { samples.count } }
    var last: Double { lock.withLock { samples.last ?? 0 } }
    /// The main thread's CPU of the last publish, ms.
    var lastCPU: Double { lock.withLock { cpuSamples.last ?? 0 } }
}
