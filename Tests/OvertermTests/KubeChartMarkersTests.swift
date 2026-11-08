import Foundation
import XCTest

@testable import Overterm

/// Change markers on every chart (docs/design/kubernetes/metrics.md 3.2,
/// 8; stage M4): a workload's History, the detail's events, the pods'
/// `lastState` and the restarts seen between two reads into markers within
/// the window; the 50 cap and "+N earlier"; the "events: last hour" note;
/// the pods' states decoded and nothing else kept; the window around a
/// marker, narrowed from the tier that holds it. Pure.
final class KubeChartMarkersTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    private func event(_ id: String, type: String = "Warning", reason: String, at time: Date, count: Int = 1) -> KubeEvent {
        KubeEvent(id: id, type: type, reason: reason, message: "\(reason) happened", count: count, first: time, last: time, source: "kubelet")
    }

    private func states(_ pods: [(String, [(String, Int, KubePodCharts.Termination?)])], at time: Date, more: Bool = false) -> KubePodStates {
        KubePodStates(
            pods: pods.map { name, containers in
                KubePodStates.Pod(name: name, containers: containers.map { KubePodStates.Container(name: $0.0, restarts: $0.1, last: $0.2) })
            }, more: more, read: time)
    }

    // MARK: The sources

    func testAHistorysEntriesAreMarkedByKindAndOpenTheirDiff() {
        let entries = [
            KubeTimelineEntry(
                id: "revision/14", kind: .revision, time: at(600), title: "Revision 14: image changed", detail: "app: nginx:1.27.1 → nginx:1.27.2",
                change: .template(from: 13, to: 14)),
            KubeTimelineEntry(id: "helm/3", kind: .helm, time: at(500), title: "Helm revision 3 · deployed", change: .helm(from: 2, to: 3)),
            KubeTimelineEntry(id: "event/a", kind: .scale, time: at(400), title: "Scaled", detail: "Scaled up replica set web-7d9 from 1 to 2"),
            KubeTimelineEntry(id: "event/b", kind: .warning, time: at(300), title: "BackOff", count: 4),
            KubeTimelineEntry(id: "revision/12", kind: .rollback, time: at(200), approximate: true, title: "Rolled back: revision 12"),
            KubeTimelineEntry(id: "revision/1", kind: .revision, time: nil, title: "Revision 1"),
        ]
        let markers = KubeChartMarkers.timeline(entries)
        XCTAssertEqual(markers.map(\.kind), [.rollout, .helm, .scale, .warning, .rollout], "no time, no marker")
        XCTAssertEqual(markers[0].opens, .history(entry: "revision/14", change: .template(from: 13, to: 14)))
        XCTAssertEqual(markers[0].detail, "app: nginx:1.27.1 → nginx:1.27.2")
        XCTAssertTrue(markers[0].title.hasPrefix("Revision 14: image changed at "), markers[0].title)
        XCTAssertEqual(markers[2].opens, .history(entry: "event/a", change: nil))
        XCTAssertEqual(markers[2].opens?.title, "Show in History")
        XCTAssertEqual(markers[0].opens?.title, "Show Diff")
        XCTAssertTrue(markers[3].title.hasPrefix("BackOff ×4 at "), markers[3].title)
        XCTAssertTrue(markers[4].title.hasSuffix(" or after"), "a rollback's time is a bound")
    }

    func testTheDetailsEventsAreItsWarningsAndItsScaling() {
        let markers = KubeChartMarkers.events([
            event("w", reason: "FailedScheduling", at: at(60), count: 3), event("r", type: "Normal", reason: "SuccessfulRescale", at: at(120)),
            event("p", type: "Normal", reason: "Pulled", at: at(180)),
        ])
        XCTAssertEqual(markers.map(\.kind), [.warning, .scale], "a Normal event other than scaling isn't a change")
        XCTAssertEqual(markers.map(\.id), ["event/w", "event/r"])
        XCTAssertEqual(markers[0].opens, .event("w"))
        XCTAssertEqual(markers[0].opens?.title, "Show in Events")
        XCTAssertTrue(markers[0].title.hasPrefix("FailedScheduling ×3 at "), markers[0].title)
        XCTAssertEqual(markers[0].detail, "FailedScheduling happened")
    }

    func testRestartsBetweenReadsAreMarkedUnlessTheirTerminationSaysWhen() {
        var log = KubeRestartLog(states([("web-1", [("app", 0, nil), ("proxy", 1, nil)]), ("web-2", [("app", 0, nil)])], at: at(0)))
        let oom = KubePodCharts.Termination(reason: "OOMKilled", exitCode: 137, finishedAt: at(30))
        log.record(states([("web-1", [("app", 1, oom), ("proxy", 3, nil)]), ("web-2", [("app", 0, nil)]), ("web-3", [("app", 5, nil)])], at: at(60)))
        XCTAssertEqual(log.restarts.map { "\($0.pod)/\($0.container) +\($0.count)" }, ["web-1/app +1", "web-1/proxy +2"], "a pod new since says nothing")
        let markers = KubeChartMarkers.pods(log, namesPods: true)
        XCTAssertEqual(markers.map(\.kind), [.oom, .restart], "app's restart is its OOMKill, said exactly: once")
        XCTAssertEqual(markers[0].time, at(30))
        XCTAssertTrue(markers[0].title.hasPrefix("web-1/app: OOMKilled (exit 137) at "), markers[0].title)
        XCTAssertEqual(markers[0].opens, .previousLog(pod: "web-1", container: "app"))
        XCTAssertEqual(markers[1].time, at(60), "at the read that saw it")
        XCTAssertTrue(markers[1].title.contains("web-1/proxy: restarted 2 times between "), markers[1].title)
        XCTAssertEqual(markers[1].opens?.title, "Open Pod's Previous Log")
        XCTAssertEqual(KubeChartMarkers.pods(log, pod: "web-1", container: "proxy", namesPods: false).map(\.title).first?.hasPrefix("proxy: restarted"), true)
        XCTAssertEqual(KubeChartMarkers.pods(log, pod: "web-1", container: "proxy", namesPods: false).first?.opens, .previousLog(pod: nil, container: "proxy"))

        // A second OOMKill: the status keeps only it, the first is still marked at its own time.
        var twice = log
        let again = KubePodCharts.Termination(reason: "OOMKilled", exitCode: 137, finishedAt: at(90))
        twice.record(states([("web-1", [("app", 2, again), ("proxy", 3, nil)])], at: at(120)))
        XCTAssertEqual(KubeChartMarkers.pods(twice, container: "app", namesPods: true).map(\.time), [at(90), at(30)], "both, once each")

        // An older read than the last changes nothing; the kept restarts are bounded.
        let before = log
        log.record(states([("web-1", [("app", 9, nil)])], at: at(10)))
        XCTAssertEqual(log, before)
        for read in 1...(KubeRestartLog.kept + 10) {
            log.record(states([("web-1", [("app", 1 + read, oom), ("proxy", 3, nil)])], at: at(60 + Double(read) * 60)))
        }
        XCTAssertEqual(log.restarts.count, KubeRestartLog.kept)
    }

    // MARK: A chart's

    func testOnlyTheNewestFiftyInTheWindowAreMarkedTheRestFolded() {
        let markers = (0..<70).map { KubeChartMarker(id: "m\($0)", kind: .warning, time: at(Double($0) * 10), title: "w\($0)") }
        let (kept, earlier) = KubeChartMarkers.capped(markers + [markers[69]], start: at(50), end: at(690))
        XCTAssertEqual(earlier, 65 - KubeChartMarkers.cap, "inside the window: m5…m69, once each")
        XCTAssertEqual(kept.count, KubeChartMarkers.cap)
        XCTAssertEqual(kept.first?.id, "m20")
        XCTAssertEqual(kept.last?.id, "m69", "the newest kept, oldest first")

        let data = KubeChartData(id: "x", title: "CPU", unit: .cores, series: [], start: at(50), end: at(690), step: 15, version: 1)
        let marked = KubeChartMarkers.apply(markers, eventsJoined: true, to: data, now: at(690))
        XCTAssertEqual(marked.shownMarkers.count, 50)
        XCTAssertEqual(marked.earlierMarkers, 15)
        XCTAssertNotEqual(marked.version, data.version, "the plot is built again with them")
        let dump = KubeChartSummary.dump(marked, plot: nil)
        XCTAssertTrue(dump.contains("markers=50[warning,") && dump.contains(" earlier=15"), dump)
        XCTAssertNil(marked.markerNote, "a window within the hour: every event still kept")
    }

    func testAWindowReachingPastTheHourSaysEventsAreKeptAnHour() {
        XCTAssertEqual(KubeChartMarkers.note(eventsJoined: true, start: at(0), now: at(6 * 3600)), "events: last hour")
        XCTAssertNil(KubeChartMarkers.note(eventsJoined: false, start: at(0), now: at(6 * 3600)), "no events joined, nothing to say")
        XCTAssertNil(KubeChartMarkers.note(eventsJoined: true, start: at(0), now: at(900)))
    }

    func testOnSixHoursAPodWhoseEventsHaveAllExpiredStillSaysEventsAreKeptAnHour() {
        let now = at(6 * 3600)
        var ring = KubeUsageRing()
        ring.record(.pod(namespace: "shop", name: "api-1"), KubeUsage(cpu: 0.1, memory: 1e8), at: now, .detail, now: now)
        func pod(_ changes: KubeChartChanges) -> KubeChartData? {
            KubePodCharts.build(
                namespace: "shop", pod: "api-1", object: podObject(restarts: 0, finished: nil), ring: ring, range: .sixHours, now: now, interval: 15,
                changes: changes
            ).pod.first?.data
        }
        var loaded = KubeChartChanges()
        loaded.eventsJoined = true
        XCTAssertEqual(pod(loaded)?.markerNote, KubeChartMarkers.eventsNote, "its events read, none left: the quiet chart says why")
        XCTAssertNil(pod(KubeChartChanges())?.markerNote, "its events not read yet: nothing to say of them")

        // A workload whose History has no warning: its events still a source.
        let object: [String: Any] = ["spec": ["replicas": 1, "template": ["spec": ["containers": [["name": "app"]]]]], "status": ["replicas": 1]]
        var history = KubeChartChanges(timeline: [KubeTimelineEntry(id: "revision/2", kind: .revision, time: at(400), title: "Revision 2")])
        history.eventsJoined = true
        let charts = KubeWorkloadCharts.build(
            KubeWorkloadCharts.Input(
                namespace: "shop", kind: "Deployment", name: "web", object: object, ring: ring, statuses: KubeStatusHistory(), pods: [], range: .sixHours,
                now: now, interval: 15, changes: history))
        XCTAssertFalse(charts.charts.isEmpty)
        XCTAssertTrue(charts.charts.allSatisfy { $0.data.markerNote == KubeChartMarkers.eventsNote }, "\(charts.charts.map(\.data.markerNote))")
    }

    // MARK: The pods' states

    func testThePodsStatesAreTheirContainersRestartsAndLastTerminationsOnly() throws {
        func item(_ name: String, restarts: Int, reason: String?) -> [String: Any] {
            var status: [String: Any] = ["name": "app", "restartCount": restarts]
            if let reason { status["lastState"] = ["terminated": ["reason": reason, "exitCode": 137, "finishedAt": "2023-11-14T22:13:20Z"]] }
            return [
                "metadata": ["name": name, "namespace": "shop"],
                "spec": ["containers": [["name": "app", "env": [["name": "API_TOKEN", "value": "s3cr3t"]]]]],
                "status": ["containerStatuses": [status]],
            ]
        }
        let list: [String: Any] = ["items": [item("web-2", restarts: 0, reason: nil), item("web-1", restarts: 2, reason: "OOMKilled")], "metadata": ["continue": "more"]]
        let read = try KubePodStates.read(JSONSerialization.data(withJSONObject: list), at: t0)
        XCTAssertEqual(read.pods.map(\.name), ["web-1", "web-2"])
        XCTAssertTrue(read.more)
        XCTAssertEqual(read.pods[0].containers, [KubePodStates.Container(name: "app", restarts: 2, last: KubePodCharts.Termination(reason: "OOMKilled", exitCode: 137, finishedAt: t0))])
        XCTAssertFalse(String(describing: read).contains("s3cr3t"), "nothing but restarts and terminations kept")
        let one = try KubePodStates.read(JSONSerialization.data(withJSONObject: item("web-1", restarts: 1, reason: nil)), at: t0)
        XCTAssertEqual(one.pods.map(\.name), ["web-1"])
        XCTAssertFalse(one.more)
        XCTAssertThrowsError(try KubePodStates.read(Data("[]".utf8), at: t0))
    }

    // MARK: The window around a marker

    func testTheWindowAroundAMarkerIsItsHalfHourEitherSideNeverTheFuture() {
        let now = at(7200)
        let old = KubeChartWindow.around(at(3600), now: now)
        XCTAssertEqual(old, KubeChartWindow(start: at(1800), end: at(5400)))
        XCTAssertEqual(old.tier, .sixHours, "older than the raw 15 minutes: the minute buckets")
        let recent = KubeChartWindow.around(at(7100), now: now)
        XCTAssertEqual(recent.end, now, "never past now")
        XCTAssertEqual(recent.start, at(7100 - 1800))
        XCTAssertEqual(KubeChartWindow.around(now, now: now).start, now.addingTimeInterval(-1800))

        let data = KubeChartData(
            id: "x", title: "CPU", unit: .cores,
            series: [
                KubeChartSeries(id: "cpu", name: "CPU", points: [at(1000), at(2000), at(5000), at(6000)].map { KubeSeriesPoint(time: $0, value: 1) }, breaks: [at(1000), at(5000)]),
                KubeChartSeries(id: "request", name: "request", role: .request, points: [KubeSeriesPoint(time: now, value: 2)]),
                KubeChartSeries(id: "requested", name: "requested", role: .request, points: [at(0), at(2000), at(6000)].map { KubeSeriesPoint(time: $0, value: $0.timeIntervalSince(self.t0)) }),
            ], start: at(0), end: now, step: 60, version: 7)
        let narrowed = old.narrow(data)
        XCTAssertEqual(narrowed.start, at(1800))
        XCTAssertEqual(narrowed.end, at(5400))
        XCTAssertEqual(narrowed.series[0].points.map(\.time), [at(2000), at(5000)])
        XCTAssertEqual(narrowed.series[0].breaks, [at(5000)])
        XCTAssertEqual(narrowed.series[1].points.count, 1, "a flat line stays")
        XCTAssertEqual(narrowed.series[2].points.map(\.time), [at(0), at(2000)], "the reading standing at the start, then those inside")
        XCTAssertNotEqual(narrowed.version, data.version)
    }

    func testAWindowAroundAMarkerTwoMinutesOldIsDrawnFromTheMinuteBuckets() throws {
        let now = at(7200)
        var ring = KubeUsageRing()
        for second in stride(from: 0.0, through: 7200, by: 15) {
            ring.record(.pod(namespace: "shop", name: "api-1"), KubeUsage(cpu: 0.1, memory: 1e8), at: at(second), .detail, now: at(second))
            for container in ["app", "sidecar"] {
                ring.record(.container(namespace: "shop", pod: "api-1", container: container), KubeUsage(cpu: 0.05, memory: 5e7), at: at(second), .detail, now: at(second))
            }
        }
        let window = KubeChartWindow.around(at(7080), now: now)
        XCTAssertEqual(window, KubeChartWindow(start: at(7080 - 1800), end: now))
        XCTAssertEqual(window.tier, .sixHours, "it starts 32 minutes back, past the raw 15")
        let charts = KubePodCharts.build(
            namespace: "shop", pod: "api-1", object: podObject(restarts: 0, finished: nil), ring: ring, range: .live, now: now, interval: 15, window: window)
        let cpu: KubeChartData? = try XCTUnwrap(charts.pod.first?.data)
        XCTAssertEqual(cpu?.tier, "1-minute buckets (CPU the mean, memory the peak)")
        XCTAssertEqual(cpu?.step, 60)
        let times = cpu?.series.first { !$0.role.isReference }?.points.map(\.time) ?? []
        let first = try XCTUnwrap(times.first)
        let last = try XCTUnwrap(times.last)
        XCTAssertTrue(first >= window.start && first < window.start.addingTimeInterval(60), "the first minute inside it: \(first)")
        XCTAssertTrue(last > now.addingTimeInterval(-60) && last <= now, "up to the minute now, the recent minutes folded as they come: \(last)")
        XCTAssertEqual(Set(zip(times, times.dropFirst()).map { $1.timeIntervalSince($0) }), [60], "a point a minute: never the raw 15 s samples of its last 15 minutes")
        XCTAssertEqual(times.count, 32, "its 32 minutes, a point each")
    }

    // MARK: The tabs

    private func podObject(restarts: Int, finished: String?) -> [String: Any] {
        var status: [String: Any] = ["name": "app", "restartCount": restarts]
        if let finished { status["lastState"] = ["terminated": ["reason": "Error", "exitCode": 1, "finishedAt": finished]] }
        return [
            "metadata": ["name": "api-1", "namespace": "shop"], "spec": ["containers": [["name": "app"], ["name": "sidecar"]]],
            "status": ["containerStatuses": [status]],
        ]
    }

    func testAPodsChartsAreMarkedWithItsEventsAndItsContainersRestarts() {
        var ring = KubeUsageRing()
        for second in stride(from: 0.0, through: 600, by: 15) {
            ring.record(.pod(namespace: "shop", name: "api-1"), KubeUsage(cpu: 0.1, memory: 1e8), at: at(second), .detail, now: at(second))
            for container in ["app", "sidecar"] {
                ring.record(.container(namespace: "shop", pod: "api-1", container: container), KubeUsage(cpu: 0.05, memory: 5e7), at: at(second), .detail, now: at(second))
            }
        }
        var log = KubeRestartLog(states([("api-1", [("app", 1, nil), ("sidecar", 0, nil)])], at: at(100)))
        log.record(states([("api-1", [("app", 1, nil), ("sidecar", 1, nil)])], at: at(160)))
        let changes = KubeChartChanges(events: [event("e1", reason: "Unhealthy", at: at(300))], restarts: log)
        let charts = KubePodCharts.build(
            namespace: "shop", pod: "api-1", object: podObject(restarts: 1, finished: nil), ring: ring, range: .live, now: at(600), interval: 15, changes: changes)
        XCTAssertEqual(charts.pod.map { $0.data.shownMarkers.map(\.kind) }, [[.restart, .warning], [.restart, .warning]], "the pod's: every container's")
        XCTAssertEqual(charts.sections.map(\.container), ["app", "sidecar"])
        XCTAssertEqual(charts.sections[0].charts[0].data.shownMarkers.map(\.kind), [.warning], "app didn't restart between the reads")
        XCTAssertEqual(charts.sections[1].charts[1].data.shownMarkers.map(\.kind), [.restart, .warning])
        XCTAssertNil(charts.pod[0].data.markerNote, "15 minutes: every event is still kept")

        // Narrowed to a window with nothing sampled in it: said plainly.
        let window = KubeChartWindow(start: at(-7200), end: at(-3600))
        let empty = KubePodCharts.build(
            namespace: "shop", pod: "api-1", object: podObject(restarts: 1, finished: nil), ring: ring, range: .live, now: at(600), interval: 15, changes: changes,
            window: window)
        XCTAssertFalse(empty.hasSamples)
        XCTAssertEqual(empty.caption, KubeChartMarkers.nothingSampled(window))
        XCTAssertTrue(empty.pod[0].data.shownMarkers.isEmpty)
        let around = KubeChartWindow(start: at(240), end: at(600))
        let narrowed = KubePodCharts.build(
            namespace: "shop", pod: "api-1", object: podObject(restarts: 1, finished: nil), ring: ring, range: .live, now: at(600), interval: 15, changes: changes,
            window: around)
        XCTAssertTrue(narrowed.hasSamples)
        XCTAssertTrue(narrowed.caption.hasSuffix("· Custom \(around.title)"), narrowed.caption)
        XCTAssertEqual(narrowed.pod[0].data.start, at(240))
        XCTAssertEqual(narrowed.pod[0].data.shownMarkers.map(\.kind), [.warning], "the restart at 160 is before it")
    }

    func testAPodWithoutAReadOfItsStatesIsMarkedFromItsObject() {
        let charts = KubePodCharts.build(
            namespace: "shop", pod: "api-1", object: podObject(restarts: 2, finished: "2023-11-14T22:15:00Z"), ring: KubeUsageRing(), range: .live, now: at(600),
            interval: 15)
        let marker = charts.sections[0].charts[0].data.shownMarkers.first
        XCTAssertEqual(marker?.kind, .restart)
        XCTAssertEqual(marker?.opens, .previousLog(pod: nil, container: "app"))
        XCTAssertTrue(marker?.title.contains("only the last previous instance's log is kept") == true)
    }

    func testAWorkloadsChartsCarryItsHistoryAndItsUsageItsPodsRestarts() {
        let object: [String: Any] = [
            "spec": ["replicas": 2, "template": ["spec": ["containers": [["name": "app"]]]]], "status": ["replicas": 2],
        ]
        var statuses = KubeStatusHistory()
        statuses.record(.replicas(namespace: "shop", kind: "Deployment", name: "web"), ["available": 2, "unavailable": 0, "desired": 2], at: at(0), expected: 60, now: at(0))
        statuses.record(.replicas(namespace: "shop", kind: "Deployment", name: "web"), ["available": 2, "unavailable": 0, "desired": 2], at: at(60), expected: 60, now: at(60))
        let oom = KubePodCharts.Termination(reason: "OOMKilled", exitCode: 137, finishedAt: at(500))
        let changes = KubeChartChanges(
            timeline: [KubeTimelineEntry(id: "revision/2", kind: .revision, time: at(400), title: "Revision 2", change: .template(from: 1, to: 2))],
            restarts: KubeRestartLog(states([("web-7d9f8b6c5d-x2k4q", [("app", 1, oom)])], at: at(550), more: true)), namesPods: true,
            problem: nil)
        let charts = KubeWorkloadCharts.build(
            KubeWorkloadCharts.Input(
                namespace: "shop", kind: "Deployment", name: "web", object: object, ring: KubeUsageRing(), statuses: statuses, pods: [], range: .live,
                now: at(600), interval: 15, changes: changes))
        let byID = Dictionary(uniqueKeysWithValues: charts.charts.map { ($0.data.id.split(separator: ".").last.map(String.init) ?? "", $0.data) })
        XCTAssertEqual(byID["cpu"]?.shownMarkers.map(\.kind), [.rollout, .oom], "W1: its History and its pods' OOMKills")
        XCTAssertEqual(byID["memory"]?.shownMarkers.map(\.kind), [.rollout, .oom], "W2")
        XCTAssertEqual(byID["replicas"]?.shownMarkers.map(\.kind), [.rollout], "W4: its History only")
        XCTAssertEqual(byID["memory"]?.shownMarkers.last?.opens, .previousLog(pod: "web-7d9f8b6c5d-x2k4q", container: "app"))
        XCTAssertTrue(charts.notes.contains { $0.contains("More than 250 pods") }, "\(charts.notes)")
    }
}
