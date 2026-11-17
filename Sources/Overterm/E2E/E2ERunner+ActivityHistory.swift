import AppKit

/// Activity's history on the page (docs/design/activity/analysis.md, 6.7,
/// 6.11, 10.3; stage 4): a strip on the run's own rows, the meters' and the
/// detail's charts — `Charts/`' time charts under `activity.chart.` —, a
/// new process tinted and an ended one shown once more. The run's own
/// processes only; pids and counts are all it says.
extension E2ERunner {
    func activityHistoryChecks(tab: Tab) async {
        let page = app.activityPage
        func ownRows() -> [ActivityProcessRow] { page.content.processes.filter { $0.tab == tab.id && !$0.ended } }
        let stripped = await eventually(10) { ownRows().contains { ($0.strip?.last ?? nil) != nil } }
        check(
            "the run's own rows carry a strip of 60 cells, the newest read", stripped && ownRows().allSatisfy { $0.strip == nil || $0.strip?.count == 60 },
            "\(ownRows().filter { $0.strip != nil }.count) of \(ownRows().count) rows")
        check("CPU, 15 min is a column by default", page.columns(.processes).contains { $0.id == "cpu15" })
        let drawn = await eventually(5) {
            self.app.pages.view(.activity).flatMap { Self.accessibilityElement("activity.strip", in: $0) } != nil
        }
        check("and its strips are drawn", drawn)

        // The meters' 15 minutes: the Mac's CPU and memory as time charts.
        let meters = await eventually(10) {
            let shown = TimeChartRegistry.shared.identifiers()
            return shown.contains("activity.chart.system.cpu") && shown.contains("activity.chart.system.memory")
        }
        check("the meters draw the Mac's CPU and memory over time", meters, "\(TimeChartRegistry.shared.identifiers().count) charts")

        // The detail's charts: the server's CPU and memory, plotted.
        if let server = ownRows().first(where: { !$0.listening.isEmpty }) {
            page.selection = [server.id]
            let id = "activity.chart.process.\(server.identity.pid).cpu"
            let charted = await eventually(10) {
                TimeChartRegistry.shared.chart(id)?.plot != nil && TimeChartRegistry.shared.chart("activity.chart.process.\(server.identity.pid).memory") != nil
            }
            check("the detail charts its CPU and memory", charted, "pid \(server.identity.pid)")
            let points = TimeChartRegistry.shared.chart(id)?.data.series.first?.points.count ?? 0
            check("from what was read since", points > 0, "\(points) points")
            page.selection = []
        } else {
            check("a server row to select", false)
        }

        // New and ended (6.7): a sleep started now is tinted; once it has
        // ended its row shows once more, "ended". The order held takes no
        // new rows: the pointer leaves the list first, and new is "absent
        // from the rows shown", whatever its age at the tick.
        if let view = app.pages.view(.activity), let table = WorkspacePages.firstTable(in: view) as? ResourceTableView { table.interaction?(.exit) }
        let free = await eventually(10) { !page.orderHeld && page.waiting == nil }
        check("the order isn't held: new rows come with the next tick", free, "held \(page.orderHeld)")
        // The ticks asked for here, not left to the loop's timer: a window
        // not in front may nap, and its timer with it — a check of what a
        // tick shows never waits on one.
        // A tick a second, looked at every 50 ms: an ended row lasts a build.
        func ticking(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            var next = Date()
            while !condition() {
                guard Date() < deadline else { return false }
                if Date() >= next {
                    next = Date().addingTimeInterval(1)
                    _ = await ActivityMonitor.shared.tick()
                }
                await pause(0.05)
            }
            return true
        }
        // The rows of a tick now: a sleep an earlier part started (the held
        // order's) is told apart from this one.
        let builds = page.builds
        _ = await ActivityMonitor.shared.tick()
        _ = await eventually(5) { page.builds > builds }
        let earlier = Set(ownRows().filter { $0.name == "sleep" }.map(\.identity))
        func started() -> ActivityProcessRow? { ownRows().first { $0.name == "sleep" && !earlier.contains($0.identity) } }
        let pane = tab.terminal
        pane.insertText("sleep 4 &")
        pane.pressReturn()
        let fresh = await ticking(10) { started()?.isNew == true }
        check("a process started a moment ago is tinted new", fresh, "\(earlier.count) earlier sleeps")
        let newPID = started()?.identity
        let ended = await ticking(15) { page.content.processes.contains { $0.identity == newPID && $0.ended } }
        let seen = page.content.processes.first { $0.identity == newPID }
        check(
            "ended, it is shown once more, dimmed", ended,
            "pid \(newPID?.pid ?? -1); \(seen.map { $0.ended ? "ended" : "listed, not ended" } ?? "not listed"), tick \(page.latest?.tick ?? -1)")
        let gone = await ticking(10) { !page.content.processes.contains { $0.identity == newPID } }
        check("then goes", gone)
    }
}
