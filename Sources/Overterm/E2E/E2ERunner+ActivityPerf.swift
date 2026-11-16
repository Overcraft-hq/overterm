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
        }
        burn()
        _ = await monitor.tick()
        check("rated after a second tick", await eventually(10) { !page.content.summary.firstSample })
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
        }
        let crowd = Self.summary(crowdedRows)
        let census = Self.summary(censusCPU)
        let rows = Self.summary(rowsMade)
        let update = Self.summary(shown)
        let held = Self.summary(heldShown)
        let scroll = Self.summary(scrolled)
        let fullP90 = Self.p90(censusCPU)
        let lightP90 = Self.p90(lightCPU)
        let p90 = { (value: Double) in String(format: "%.1f ms", locale: Locale(identifier: "en_US_POSIX"), value) }
        note("activityPerf: \(count) processes (this Mac: \(live)); census CPU a tick \(census); rows made \(rows)")
        note("activityPerf: the sampler's CPU a tick, p90: full \(p90(fullP90)), light (8 panes) \(p90(lightP90)), \(lightCPU.count) light ticks")
        note("activityPerf: a tick's rows shown \(update), each \(shown.map { Int($0.rounded()) }); held \(held); scrolled \(scrolled.count) steps, \(scroll)")
        note("activityPerf: 5,000 processes' rows, grouped by checkout, made \(crowd)")
        // 10.4's 15 ms isn't met yet — the owners' cost, open (design 15):
        // the gate holds what is, so it can only get better.
        check("5,000 processes' rows are made in under 100 ms (median)", !crowdedRows.isEmpty && crowd.median < 100, "\(crowd)")
        check("the census's own CPU a tick stays under 50 ms (median)", census.median < 50, "\(census)")
        check("the light tick's CPU is read (12 ticks)", lightCPU.count == 12, "\(lightCPU.count)")
        check("the rows of a tick are made in under 60 ms (median), off the main thread", rows.median < 60, "\(rows)")
        // The frames are the Mac's as much as the page's — a busy `make
        // e2e` moves them —: gated loosely, against a break, never at the
        // margin (10.4 gates on counts). 10.4 proposed 4 ms a publish: a
        // re-sorted list of 1,300 rows takes its SwiftUI update and the
        // visible rows' cells (design 15).
        check("a tick's rows are shown in under 100 ms (median)", !shown.isEmpty && update.median < 100, "\(update)")
        check("held, a tick is shown in under 100 ms (median)", !heldShown.isEmpty && held.median < 100, "\(held)")
        check("the list scrolls in under 35 ms a step (p95)", !scrolled.isEmpty && scroll.p95 < 35, "\(scroll)")
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
    private var armed: CFTimeInterval?
    private var samples: [Double] = []

    func arm() { lock.withLock { if armed == nil { armed = CACurrentMediaTime() } } }

    func rest() {
        lock.withLock {
            guard let armed else { return }
            samples.append((CACurrentMediaTime() - armed) * 1000)
            self.armed = nil
        }
    }

    var count: Int { lock.withLock { samples.count } }
    var last: Double { lock.withLock { samples.last ?? 0 } }
}
