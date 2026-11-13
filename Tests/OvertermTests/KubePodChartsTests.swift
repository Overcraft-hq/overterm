import Foundation
import XCTest

@testable import Overterm

/// A pod's Metrics tab, sampled (docs/design/kubernetes/metrics.md 2.3,
/// 2.4, stage M3a): the containers in the Logs tab's order, references
/// from the spec, the chips, the markers from `lastState`, the ring's two
/// tiers, the ranges `,` and `.` step through. Pure.
final class KubePodChartsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_699_999_980)  // on a minute
    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    private func pod(
        containers: [(String, [String: [String: String]])] = [("app", ["requests": ["cpu": "250m", "memory": "256Mi"], "limits": ["cpu": "1", "memory": "512Mi"]]), ("sidecar", [:])],
        defaultContainer: String? = nil, lastState: [String: Any]? = nil, restarts: Int = 0
    ) -> [String: Any] {
        var metadata: [String: Any] = ["name": "api-1", "namespace": "shop"]
        if let defaultContainer { metadata["annotations"] = [KubePodContainers.defaultAnnotation: defaultContainer] }
        var status: [String: Any] = ["name": containers[0].0, "restartCount": restarts]
        if let lastState { status["lastState"] = ["terminated": lastState] }
        return [
            "metadata": metadata,
            "spec": ["containers": containers.map { ["name": $0.0, "resources": $0.1] as [String: Any] }],
            "status": ["containerStatuses": [status]],
        ]
    }

    /// The ring as a detail's poll fills it: the pod and each container, stamped alike.
    private func ring(_ samples: [(Double, [String: (Double, Double)])]) -> KubeUsageRing {
        var ring = KubeUsageRing()
        for (time, containers) in samples {
            let total = containers.values.reduce(KubeUsage.zero) { $0 + KubeUsage(cpu: $1.0, memory: $1.1) }
            ring.record(.pod(namespace: "shop", name: "api-1"), total, at: at(time), .detail, now: at(time))
            for (name, usage) in containers {
                ring.record(.container(namespace: "shop", pod: "api-1", container: name), KubeUsage(cpu: usage.0, memory: usage.1), at: at(time), .detail, now: at(time))
            }
        }
        return ring
    }

    private let mi = 1_048_576.0

    func testTheContainersComeInTheLogsTabsOrderWithTheirSpec() {
        let containers = KubePodCharts.containers(of: pod(defaultContainer: "sidecar"))
        XCTAssertEqual(containers.map(\.name), ["sidecar", "app"], "kubectl's default container first")
        let app = containers[1]
        XCTAssertEqual(app.cpuRequest, 0.25)
        XCTAssertEqual(app.cpuLimit, 1)
        XCTAssertEqual(app.memoryRequest, 256 * mi)
        XCTAssertEqual(app.memoryLimit, 512 * mi)
        XCTAssertNil(containers[0].cpuRequest, "the sidecar asks for nothing")
        XCTAssertEqual(KubePodCharts.containers(of: pod()).map(\.name), ["app", "sidecar"], "else the spec's order")
    }

    func testThePodsChartsStackItsContainersAndEachContainerHasItsLines() {
        let samples = ring([(0, ["app": (0.1, 100 * mi), "sidecar": (0.02, 20 * mi)]), (15, ["app": (0.12, 120 * mi), "sidecar": (0.02, 20 * mi)])])
        let charts = KubePodCharts.build(namespace: "shop", pod: "api-1", object: pod(), ring: samples, range: .live, now: at(20), interval: 15)
        XCTAssertTrue(charts.hasSamples)
        XCTAssertEqual(charts.pod.map(\.data.id), ["pod.shop.api-1.cpu", "pod.shop.api-1.memory"])
        let cpu = charts.pod[0].data
        XCTAssertTrue(cpu.stacked)
        XCTAssertEqual(cpu.usage.map(\.id), ["app", "sidecar"])
        XCTAssertTrue(cpu.references.isEmpty, "the sidecar has no request: a partial sum would mislead")
        XCTAssertEqual(charts.sections.map(\.container), ["app", "sidecar"])
        let appCPU = charts.sections[0].charts[0]
        XCTAssertEqual(appCPU.data.id, "container.shop.api-1.app.cpu")
        XCTAssertEqual(appCPU.data.references.map(\.role), [.request, .limit])
        XCTAssertEqual(appCPU.data.references.map { $0.points.last?.value }, [0.25, 1])
        XCTAssertEqual(appCPU.data.usage.first?.points.map { ($0.value * 1000).rounded() }, [100, 120], "the ring's Float32s")
        XCTAssertEqual(appCPU.headline, "120m now")
        XCTAssertEqual(appCPU.chips.map(\.text), ["48% of request", "12% of limit"])
        XCTAssertEqual(charts.sections[1].charts[0].chips.map(\.text), ["no limit"])
        XCTAssertEqual(appCPU.data.source, "metrics-server")
        XCTAssertEqual(appCPU.data.start, at(20 - 900), "Live: 15 minutes to the last poll")
        XCTAssertTrue(charts.caption.hasPrefix("Sampled from metrics-server while shown since "), charts.caption)
        XCTAssertTrue(charts.caption.hasSuffix("every 15 s"), charts.caption)
        XCTAssertFalse(charts.picksContainer)
    }

    func testMemoryNearItsLimitIsAnOOMRisk() {
        XCTAssertEqual(KubePodCharts.memoryChips(400 * mi, request: 256 * mi, limit: 512 * mi).map(\.text), ["156% of request", "working set 78% of limit"])
        let risk = KubePodCharts.memoryChips(470 * mi, request: nil, limit: 512 * mi)
        XCTAssertEqual(risk, [KubeChartChip(text: "working set 92% of limit · OOM risk", alert: true)])
        XCTAssertEqual(KubePodCharts.memoryChips(nil, request: nil, limit: 512 * mi), [], "nothing sampled, nothing said")
    }

    func testTheLastTerminationIsMarkedOnItsContainersCharts() {
        let object = pod(lastState: ["reason": "OOMKilled", "exitCode": 137, "finishedAt": "2023-11-14T22:13:20Z"], restarts: 2)
        let finished = Date(timeIntervalSince1970: 1_700_000_000)
        let charts = KubePodCharts.build(
            namespace: "shop", pod: "api-1", object: object, ring: ring([(0, ["app": (0.1, 100 * mi)])]), range: .live, now: at(60), interval: 15)
        let memory = charts.sections[0].charts[1].data
        XCTAssertEqual(memory.markers.count, 1)
        let marker = memory.markers.first
        XCTAssertEqual(marker?.kind, .oom)
        XCTAssertEqual(marker?.time, finished)
        XCTAssertEqual(marker?.container, "app")
        XCTAssertTrue(marker?.title.contains("OOMKilled (exit 137)") == true, marker?.title ?? "")
        XCTAssertTrue(marker?.title.contains("only the last previous instance's log is kept") == true, "two restarts: one log kept")
        XCTAssertEqual(charts.pod[1].data.markers.count, 1, "the pod's memory too")
        XCTAssertEqual(charts.sections[0].charts[0].data.markers.count, 1, "its CPU too: every chart is marked (M4)")
        XCTAssertTrue(charts.sections[1].charts[1].data.markers.isEmpty, "not another container's")
        XCTAssertEqual(memory.shownMarkers.count, 1)
        XCTAssertTrue(KubeChartSummary.dump(memory, plot: nil).contains("markers=1"))

        let error = KubePodCharts.containers(of: pod(lastState: ["reason": "Error", "exitCode": 1, "finishedAt": "2023-11-14T22:13:20Z"], restarts: 1))
        XCTAssertEqual(KubePodCharts.marker(error[0])?.kind, .restart)
        XCTAssertFalse(KubePodCharts.marker(error[0])?.title.contains("only the last") ?? true)
        let untimed = KubePodCharts.containers(of: pod(lastState: ["reason": "Error", "exitCode": 1], restarts: 1))
        XCTAssertNil(KubePodCharts.marker(untimed[0]), "no time, no marker")

        // Long before the window: kept, not drawn.
        let later = KubePodCharts.build(
            namespace: "shop", pod: "api-1", object: object, ring: ring([(0, ["app": (0.1, 100 * mi)])]), range: .live, now: at(3600), interval: 15)
        XCTAssertTrue(later.sections[0].charts[1].data.shownMarkers.isEmpty)
    }

    func testSixHoursDrawsTheMinuteBucketsCPUsMeanAndMemorysPeak() {
        let samples = ring([(0, ["app": (0.1, 100 * mi)]), (15, ["app": (0.3, 300 * mi)]), (30, ["app": (0.2, 50 * mi)]), (60, ["app": (0.4, 10 * mi)])])
        let charts = KubePodCharts.build(namespace: "shop", pod: "api-1", object: pod(), ring: samples, range: .sixHours, now: at(70), interval: 15)
        let cpu = charts.sections[0].charts[0].data
        let memory = charts.sections[0].charts[1].data
        XCTAssertEqual(cpu.step, 60)
        XCTAssertEqual(cpu.start, at(70 - 6 * 3600))
        XCTAssertEqual(cpu.usage[0].points.map(\.time), [at(0), at(60)])
        XCTAssertEqual(cpu.usage[0].points[0].value, 0.2, accuracy: 1e-6, "the minute's mean")
        XCTAssertEqual(memory.usage[0].points[0].value, 300 * mi, accuracy: 1, "the minute's peak: the spike before an OOM survives")
        XCTAssertTrue(charts.caption.contains("1-minute buckets"), charts.caption)
        XCTAssertTrue(cpu.tier?.contains("1-minute") == true)
    }

    func testNothingSampledYetSaysSo() {
        let charts = KubePodCharts.build(namespace: "shop", pod: "api-1", object: pod(), ring: KubeUsageRing(), range: .live, now: at(0), interval: 15)
        XCTAssertFalse(charts.hasSamples)
        XCTAssertEqual(charts.caption, "Waiting for metrics-server's first sample of this pod…")
    }

    func testPastFourContainersAPickerTakesTheSections() {
        let five = (0..<5).map { ("c\($0)", [String: [String: String]]()) }
        let charts = KubePodCharts.build(
            namespace: "shop", pod: "api-1", object: pod(containers: five), ring: ring([(0, ["c0": (0.1, mi)])]), range: .live, now: at(0), interval: 15)
        XCTAssertTrue(charts.picksContainer)
        let four = KubePodCharts.build(
            namespace: "shop", pod: "api-1", object: pod(containers: Array(five.prefix(4))), ring: ring([(0, ["c0": (0.1, mi)])]), range: .live, now: at(0),
            interval: 15)
        XCTAssertFalse(four.picksContainer)
    }

    func testTheVersionMovesWithTheSamplesAndTheRange() {
        let one = ring([(0, ["app": (0.1, mi)])])
        let two = ring([(0, ["app": (0.1, mi)]), (15, ["app": (0.2, mi)])])
        func version(_ ring: KubeUsageRing, _ range: KubeMetricsRange, now: Double) -> Int {
            KubePodCharts.build(namespace: "shop", pod: "api-1", object: pod(), ring: ring, range: range, now: at(now), interval: 15).sections[0].charts[0].data.version
        }
        XCTAssertEqual(version(one, .live, now: 20), version(one, .live, now: 20), "the same data, the same plot")
        XCTAssertNotEqual(version(one, .live, now: 20), version(two, .live, now: 20))
        XCTAssertNotEqual(version(two, .live, now: 20), version(two, .sixHours, now: 20))
    }

    func testTheRangesStepThroughWhatCanBePicked() {
        let sampled = KubeMetricsRange.sampled
        XCTAssertEqual(sampled, [.live, .sixHours], "without Prometheus: Live and what was sampled for 6 hours")
        XCTAssertEqual(KubeMetricsRange.live.stepped(1, among: sampled), .sixHours, "1h needs Prometheus: skipped")
        XCTAssertEqual(KubeMetricsRange.sixHours.stepped(1, among: sampled), .sixHours, "the end")
        XCTAssertEqual(KubeMetricsRange.sixHours.stepped(-1, among: sampled), .live)
        XCTAssertEqual(KubeMetricsRange.live.stepped(-1, among: sampled), .live)
        XCTAssertEqual(KubeMetricsRange.hour.stepped(1, among: sampled), .live, "one that can't be picked: back to the first")
        XCTAssertEqual(KubeMetricsRange.allCases.map(\.title), ["Live", "1h", "6h", "24h", "7d"])
        XCTAssertEqual(KubeMetricsRange.live.span, 900)
    }

    func testAMarkerIsPlacedInsideTheWindowOnly() {
        let markers = [
            KubeChartMarker(id: "a", kind: .oom, time: at(30), title: "OOMKilled"), KubeChartMarker(id: "b", kind: .restart, time: at(-30), title: "before"),
        ]
        let data = KubeChartData(
            id: "t.memory", title: "Memory", unit: .bytes,
            series: [KubeChartSeries(id: "m", name: "m", points: [KubeSeriesPoint(time: at(0), value: 1), KubeSeriesPoint(time: at(60), value: 2)])],
            start: at(0), end: at(60), step: 15, markers: markers)
        let plot = KubePlot(data, size: CGSize(width: 240, height: 100))
        XCTAssertEqual(plot.markers.map(\.marker.id), ["a"], "the one before the window isn't drawn")
        XCTAssertEqual(plot.markers[0].x, plot.x(of: at(30)), accuracy: 0.001)
        XCTAssertEqual(KubeChartPalette.marker(.oom, dark: false), KubeChartPalette.reference(.limit, dark: false), "an OOMKill red, as a limit")
    }

    func testLogsFromHereAsksFromThatSecond() {
        let from = Date(timeIntervalSince1970: 1_700_000_000.7)
        let query = KubePodLogSource.query(container: "app", previous: false, since: .hour, tail: 500, after: nil, from: from)
        XCTAssertEqual(query.sinceTime, "2023-11-14T22:13:20Z")
        let path = query.path(namespace: "shop", pod: "api-1")
        XCTAssertTrue(path.contains("sinceTime=2023-11-14T22%3A13%3A20Z"), path)
        XCTAssertFalse(path.contains("sinceSeconds"), "never both: the API refuses them together")
        // Its head, not the newest lines since: kubelet applies tailLines after sinceTime.
        XCTAssertNil(query.tailLines, "no tail: it would bring the newest lines since, not the ones from the spike")
        XCTAssertEqual(query.limitBytes, KubePodLogSource.fromReadBytes, "the head of the log from that time, up to a limit")
        XCTAssertFalse(query.follow, "read once: following would push the lines near the crosshair out")
        XCTAssertFalse(path.contains("tailLines"), path)
        XCTAssertFalse(path.contains("follow"), path)
        XCTAssertTrue(path.contains("limitBytes=\(KubePodLogSource.fromReadBytes)"), path)
        XCTAssertFalse(KubePodLogSource.cut(lines: LogFeed.keep, bytes: 0), "exactly what the feed keeps: all of it")
        XCTAssertTrue(KubePodLogSource.cut(lines: LogFeed.keep + 1, bytes: 0))
        XCTAssertTrue(KubePodLogSource.cut(lines: 10, bytes: KubePodLogSource.fromReadBytes), "the read stopped at its limit")
        let resumed = KubePodLogSource.query(container: "app", previous: false, since: .hour, tail: 500, after: "2023-11-14T22:20:00.123Z", from: from)
        XCTAssertEqual(resumed.sinceTime, "2023-11-14T22:20:00Z", "a resumed follow goes on from its last line")
        XCTAssertEqual(
            KubectlLine.logs(context: "fake-dev", namespace: "shop", pod: "api-1", container: "app", previous: false, since: .hour, timestamps: false, sinceTime: from),
            "kubectl --context fake-dev -n shop logs api-1 -c app --since-time=2023-11-14T22:13:20Z")
        XCTAssertEqual(KubectlLine.top(context: "fake-dev", namespace: "shop", pod: "api-1"), "kubectl --context fake-dev -n shop top pod api-1 --containers")
    }

    func testWhichDetailsHaveAMetricsTab() {
        let pod = KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "api-1")
        XCTAssertTrue(KubeDetailTab.tabs(for: pod).contains(.metrics))
        XCTAssertEqual(KubeDetailTab.tabs(for: pod).last, .metrics)
        let namespace = KubeObjectRef(context: "fake-dev", kind: .namespaces, namespace: nil, name: "shop")
        XCTAssertEqual(namespace.metricsSubject, .namespace, "M3b: a namespace's too")
        func kind(_ group: String, _ resource: String, namespaced: Bool = true) -> KubeResourceKind {
            KubeResourceKind(group: group, version: "v1", resource: resource, kind: "", singular: "", namespaced: namespaced, verbs: [])
        }
        func ref(_ group: String, _ resource: String, namespaced: Bool = true) -> KubeObjectRef {
            KubeObjectRef(context: "fake-dev", kind: kind(group, resource, namespaced: namespaced), namespace: namespaced ? "shop" : nil, name: "x")
        }
        XCTAssertEqual(ref("apps", "deployments").metricsSubject, .workload("Deployment"))
        XCTAssertEqual(ref("batch", "jobs").metricsSubject, .workload("Job"))
        XCTAssertEqual(ref("autoscaling", "horizontalpodautoscalers").metricsSubject, .hpa)
        XCTAssertEqual(ref("", "nodes", namespaced: false).metricsSubject, .node)
        XCTAssertNil(ref("", "services").metricsSubject, "a Service uses nothing of its own")
        XCTAssertNil(ref("", "configmaps").metricsSubject)
        XCTAssertNil(ref("batch", "cronjobs").metricsSubject)
        XCTAssertEqual(KubernetesKey.of("m"), .metrics)
        XCTAssertEqual(KubernetesKey.of(","), .earlierRange)
        XCTAssertEqual(KubernetesKey.of("."), .laterRange)
    }

    @MainActor
    func testLogsFromHeresNoteBlamesOurLimitNotRotation() {
        let from = Date(timeIntervalSince1970: 1_700_000_000)
        let cut = KubeLogsFromNote.text(from: from, first: from.addingTimeInterval(5), lines: LogFeed.keep, cut: true)
        XCTAssertTrue(cut.text.hasSuffix(": more than 5,000 lines since — the first 5,000 shown"), cut.text)
        XCTAssertFalse(cut.text.contains("rotated"), "our own limit, not kubelet's rotation")
        XCTAssertTrue(cut.warns)
        let bytes = KubeLogsFromNote.text(from: from, first: from, lines: 1200, cut: true)
        XCTAssertTrue(bytes.text.hasSuffix(": more logged since than one read brings — the first 1,200 shown"), bytes.text)
        let late = KubeLogsFromNote.text(from: from, first: from.addingTimeInterval(600), lines: 20, cut: false)
        XCTAssertTrue(late.text.contains("kubelet has rotated it away"), late.text)
        XCTAssertEqual(KubeLogsFromNote.text(from: from, first: from.addingTimeInterval(10), lines: 20, cut: false).warns, false)
    }

    /// A native sidecar: an init container with `restartPolicy: Always`, running beside the others.
    private func sidecarPod() -> [String: Any] {
        [
            "metadata": ["name": "api-1", "namespace": "shop"],
            "spec": [
                "initContainers": [
                    ["name": "migrate", "resources": ["requests": ["cpu": "1"]]] as [String: Any],
                    [
                        "name": "istio-proxy", "restartPolicy": "Always",
                        "resources": ["requests": ["cpu": "100m", "memory": "128Mi"], "limits": ["cpu": "500m", "memory": "256Mi"]],
                    ] as [String: Any],
                ],
                "containers": [
                    ["name": "app", "resources": ["requests": ["cpu": "250m", "memory": "256Mi"], "limits": ["cpu": "1", "memory": "512Mi"]]] as [String: Any]
                ],
            ],
            "status": [
                "containerStatuses": [["name": "app", "restartCount": 0]],
                "initContainerStatuses": [["name": "migrate", "restartCount": 0], ["name": "istio-proxy", "restartCount": 3]],
            ],
        ]
    }

    func testANativeSidecarIsStackedCountedAndHasItsSection() {
        let containers = KubePodCharts.containers(of: sidecarPod())
        XCTAssertEqual(containers.map(\.name), ["app", "istio-proxy"], "the sidecar after the containers; an init container that ran to completion isn't one")
        XCTAssertEqual(containers[1].restarts, 3, "its status from initContainerStatuses")
        XCTAssertEqual(containers[1].memoryLimit, 256 * mi)

        let samples = ring([(0, ["app": (0.2, 200 * mi), "istio-proxy": (0.1, 100 * mi)]), (15, ["app": (0.2, 200 * mi), "istio-proxy": (0.1, 100 * mi)])])
        let charts = KubePodCharts.build(namespace: "shop", pod: "api-1", object: sidecarPod(), ring: samples, range: .live, now: at(20), interval: 15)
        let cpu = charts.pod[0].data
        XCTAssertEqual(cpu.usage.map(\.id), ["app", "istio-proxy"], "the stack adds up to the pod's total")
        XCTAssertEqual(cpu.references.map { $0.points.last?.value }, [0.35, 1.5], "the requests and limits of both")
        let memory = charts.pod[1]
        XCTAssertEqual(memory.data.references.map { $0.points.last?.value }, [384 * mi, 768 * mi])
        XCTAssertEqual(memory.chips.map(\.text), ["78% of request", "working set 39% of limit"], "the whole pod against the whole pod's limit: no false OOM risk")
        XCTAssertEqual(charts.sections.map(\.container), ["app", "istio-proxy"], "the sidecar's own C1, C2")
    }

    func testLiveAtAMinutesResolutionDrawsLinesAndKeepsTheRingsBreaks() {
        // metrics-server at --metric-resolution=60s: a sample a minute, polled every 15 s.
        var ring = KubeUsageRing(interval: 60)
        for time in [0.0, 60, 120, 180, /* a break */ 480, 540] {
            ring.record(.pod(namespace: "shop", name: "api-1"), KubeUsage(cpu: 0.1, memory: 10 * mi), at: at(time), .detail, now: at(time))
            ring.record(.container(namespace: "shop", pod: "api-1", container: "app"), KubeUsage(cpu: 0.1, memory: 10 * mi), at: at(time), .detail, now: at(time))
        }
        let object = pod(containers: [("app", [:])])
        let charts = KubePodCharts.build(namespace: "shop", pod: "api-1", object: object, ring: ring, range: .live, now: at(545), interval: 15)
        let cpu = charts.sections[0].charts[0].data
        XCTAssertEqual(cpu.step, 60, "the samples' own spacing, not a constant 15")
        XCTAssertTrue(cpu.breaksMarked)
        XCTAssertEqual(cpu.usage[0].breaks, [at(480)], "the ring's break, kept")
        XCTAssertTrue(charts.caption.hasSuffix("every 60 s"), charts.caption)
        let plot = KubePlot(cpu, size: CGSize(width: 400, height: 120))
        XCTAssertEqual(plot.lines.first?.points, 6, "every point drawn")
        let runs = KubePlot.runs(cpu.usage[0].points, lower: nil, step: 0, breaks: cpu.usage[0].breaks)
        XCTAssertEqual(runs.map(\.upper.count), [4, 2], "two lines, split where the ring broke them — not a point each")
        XCTAssertEqual(KubePodCharts.spacing([[], []]), nil)
    }

    func testAWindowIsReadAsTheResolution() {
        XCTAssertEqual(KubeMetricsReader.seconds("15s"), 15)
        XCTAssertEqual(KubeMetricsReader.seconds("1m0.5s"), 60.5)
        XCTAssertEqual(KubeMetricsReader.seconds("500ms"), 0.5)
        XCTAssertEqual(KubeMetricsReader.seconds("1h2m"), 3720)
        XCTAssertNil(KubeMetricsReader.seconds("fast"))
        XCTAssertNil(KubeMetricsReader.seconds(nil))
        let sample = KubeMetricsSample(
            pods: [KubePodMetrics(id: KubeRowID(namespace: "shop", name: "api-1"), timestamp: at(0), window: "1m0.12s", containers: [:])], read: at(1))
        XCTAssertEqual(sample.resolution ?? 0, 60.12, accuracy: 1e-9)
    }

    @MainActor
    func testTheChartsAreBuiltOnlyWhenWhatTheyComeFromChanges() throws {
        let ref = KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "api-1")
        func object(_ version: String) throws -> KubeObject {
            var body = pod()
            body["metadata"] = ["name": "api-1", "namespace": "shop", "resourceVersion": version]
            return try KubeObject(data: JSONSerialization.data(withJSONObject: body))
        }
        let samples = ring([(0, ["app": (0.1, mi)])])
        var cache: (key: KubePodChartsKey, charts: KubePodCharts?)?
        let first = try object("1")
        XCTAssertTrue(KubePodChartsKey.charts(ref: ref, object: first, ring: samples, range: .live, now: at(10), interval: 15, cache: &cache).built)
        for _ in 0..<10 {
            XCTAssertFalse(
                KubePodChartsKey.charts(ref: ref, object: first, ring: samples, range: .live, now: at(10), interval: 15, cache: &cache).built,
                "a row event, a list's poll: the same reading, nothing built")
        }
        XCTAssertTrue(KubePodChartsKey.charts(ref: ref, object: first, ring: samples, range: .live, now: at(25), interval: 15, cache: &cache).built, "a new reading")
        XCTAssertTrue(
            KubePodChartsKey.charts(ref: ref, object: try object("2"), ring: samples, range: .live, now: at(25), interval: 15, cache: &cache).built, "the pod changed")
        XCTAssertTrue(
            KubePodChartsKey.charts(ref: ref, object: try object("2"), ring: samples, range: .sixHours, now: at(25), interval: 15, cache: &cache).built,
            "another range")
    }

    func testWithoutMetricsServerTheChartsArePrometheus() {
        XCTAssertEqual(
            KubernetesPageModel.metricsServerAbsent(prometheus: false), "No metrics-server in this cluster: there are no usage numbers without it or Prometheus.")
        let on = KubernetesPageModel.metricsServerAbsent(prometheus: true)
        XCTAssertFalse(on.contains("no usage numbers"), "false with Prometheus on")
        XCTAssertTrue(on.contains("come from Prometheus"), on)
    }
}
