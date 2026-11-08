import Foundation
import XCTest

@testable import Overterm

/// Stage M0 of docs/design/kubernetes/metrics.md (1.1): the rate window
/// (Grafana's `$__rate_interval`, the scrape taken as a minute), the
/// regex escaping before the string's, every sum taken over one series a
/// container (`max by` a gauge, `sum by` a counter's rate) and over
/// kube-state-metrics' series `max by` what identifies them, requests and
/// limits of active pods only, raw cAdvisor across the cluster up to 6h,
/// the reader's scalars, notes, histograms and gaps, and `timeout=20s`
/// with a deadline after it. Pure, and the fake's evaluator (tests only).
@MainActor
final class KubePromQLTests: XCTestCase {
    // MARK: The rate window

    func testTheRateWindowHoldsFourScrapesAtLeast() {
        // A minute's scrape (the prometheus chart's default): rate(x[1m]) would hold one sample.
        XCTAssertEqual(KubeRateWindow.of(step: 30, scrape: 60), 240)
        XCTAssertEqual(KubeRateWindow.of(step: 120, scrape: 60), 240)
        XCTAssertEqual(KubeRateWindow.of(step: 300, scrape: 60), 360, "a step and a scrape past four scrapes")
        XCTAssertEqual(KubeRateWindow.of(step: 720, scrape: 60), 780)
        XCTAssertEqual(KubeRateWindow.of(step: 3600, scrape: 60), 3660)
        // kube-prometheus-stack's 30 s.
        XCTAssertEqual(KubeRateWindow.of(step: 30, scrape: 30), 120)
        XCTAssertEqual(KubeRateWindow.of(step: 15, scrape: 15), 60, "rounded up to a whole minute")
        XCTAssertEqual(KubeRateWindow.of(step: 45, scrape: 30), 120, "75 s up to 2m")
        for scrape: TimeInterval in [15, 30, 60, 120] {
            for step: TimeInterval in [15, 30, 60, 180, 720, 3600] {
                let window = KubeRateWindow.of(step: step, scrape: scrape)
                XCTAssertGreaterThanOrEqual(window, 4 * scrape)
                XCTAssertGreaterThanOrEqual(window, step + scrape)
                XCTAssertEqual(window.truncatingRemainder(dividingBy: 60), 0)
            }
        }
        XCTAssertEqual(KubeRateWindow.assumedScrape, 60, "a minute until a probe says otherwise")
        XCTAssertTrue(KubeChart.pod(namespace: "shop", name: "web-1").queries(range: .hour).series[0].1.hasSuffix("[4m])))"))
    }

    // MARK: Escaping

    func testRegexValuesAreEscapedBeforeTheString() {
        XCTAssertEqual(KubePromQL.regexLiteral("acme.web"), #"acme\.web"#)
        XCTAssertEqual(KubePromQL.regexLiteral(#"a+b*c?(d)|[e]{f}^$\"#), #"a\+b\*c\?\(d\)\|\[e\]\{f\}\^\$\\"#)
        // regexLiteral first, then literal: the backslash survives the string.
        XCTAssertEqual(KubePromQL.namespaces(["acme.api", "globex-web"]), #"namespace=~"acme\\.api|globex-web""#)
        XCTAssertEqual(KubePromQL.namespaces(["shop"]), #"namespace="shop""#, "one is a plain matcher")
        XCTAssertEqual(KubePromQL.literal(#"a"b\c"#), #"a\"b\\c"#)
        // The fake reads the query back to the same names.
        let series: [FakePromQL.Series] = [
            ("kubelet_volume_stats_used_bytes", ["namespace": "acme.api", "persistentvolumeclaim": "a"], 1),
            ("kubelet_volume_stats_used_bytes", ["namespace": "acmeXapi", "persistentvolumeclaim": "b"], 2),
            ("kubelet_volume_stats_used_bytes", ["namespace": "globex-web", "persistentvolumeclaim": "c"], 4),
        ]
        let answer = FakePromQL.evaluate(KubePromQL.volumes(KubePromQL.volumeUsed, namespaces: ["acme.api", "globex-web"]), series)
        XCTAssertEqual(answer?.map(\.value).sorted(), [1, 4], "the `.` is a dot, not any character")
    }

    // MARK: De-duplication and active pods

    private static let cad = ["image": "nginx:1.27", "namespace": "shop", "pod": "web-1"]

    /// A container restarted: its old series (another `id`) lingers until
    /// stale, overlapping the new one. Summed raw, it doubles; over one
    /// series a container, it doesn't.
    func testARestartedContainerIsNotCountedTwice() throws {
        let series: [FakePromQL.Series] = [
            ("container_memory_working_set_bytes", Self.cad.merging(["container": "app", "id": "/old"]) { $1 }, 400),
            ("container_memory_working_set_bytes", Self.cad.merging(["container": "app", "id": "/new"]) { $1 }, 380),
            ("container_memory_working_set_bytes", Self.cad.merging(["container": "sidecar", "id": "/s"]) { $1 }, 20),
            // The sandbox, and a cgroup without an image: never a container's.
            ("container_memory_working_set_bytes", Self.cad.merging(["container": "POD", "id": "/p"]) { $1 }, 1000),
            ("container_memory_working_set_bytes", ["namespace": "shop", "pod": "web-1", "container": "app", "id": "/cg"], 1000),
            ("container_cpu_usage_seconds_total", Self.cad.merging(["container": "app", "id": "/old"]) { $1 }, 0),
            ("container_cpu_usage_seconds_total", Self.cad.merging(["container": "app", "id": "/new"]) { $1 }, 0.25),
        ]
        let memory = try XCTUnwrap(FakePromQL.evaluate(KubePromQL.podMemory(namespace: "shop", pod: "web-1"), series))
        XCTAssertEqual(memory.map(\.value), [420], "the app's highest series and the sidecar's")
        XCTAssertEqual(FakePromQL.evaluate("sum(container_memory_working_set_bytes{namespace=\"shop\"})", series)?.first?.value, 2800, "raw, it would double")
        let cpu = try XCTUnwrap(FakePromQL.evaluate(KubePromQL.podCPU(namespace: "shop", pod: "web-1", window: "4m"), series))
        XCTAssertEqual(cpu.map(\.value), [0.25], "a dead counter's rate is 0")
        XCTAssertEqual(FakePromQL.evaluate(KubePromQL.clusterMemory, series)?.first?.value, 420)
    }

    /// Requests and limits: only Pending and Running pods, each once though
    /// two kube-state-metrics replicas report it; allocatable once a node.
    func testRequestsCountActivePodsOnce() throws {
        var series: [FakePromQL.Series] = []
        for instance in ["10.0.0.1:8080", "10.0.0.2:8080"] {
            let ksm = ["instance": instance, "job": "kube-state-metrics"]
            func pod(_ name: String, _ container: String, cpu: Double, phase: String) {
                series.append(
                    (
                        "kube_pod_container_resource_requests",
                        ksm.merging(["namespace": "shop", "pod": name, "container": container, "node": "fake-node-1", "resource": "cpu"]) { $1 }, cpu
                    ))
                for each in ["Pending", "Running", "Succeeded", "Failed", "Unknown"] {
                    series.append(("kube_pod_status_phase", ksm.merging(["namespace": "shop", "pod": name, "phase": each]) { $1 }, each == phase ? 1 : 0))
                }
            }
            pod("web-1", "app", cpu: 0.5, phase: "Running")
            pod("web-1", "sidecar", cpu: 0.1, phase: "Running")
            pod("web-2", "app", cpu: 0.5, phase: "Pending")
            pod("migrate-x7", "job", cpu: 2, phase: "Succeeded")
            pod("evicted-q2", "app", cpu: 4, phase: "Failed")
            series.append(("kube_node_status_allocatable", ksm.merging(["node": "fake-node-1", "resource": "cpu"]) { $1 }, 4))
        }
        let requested = try XCTUnwrap(FakePromQL.evaluate(KubePromQL.requests("cpu"), series)?.first?.value)
        XCTAssertEqual(requested, 1.1, accuracy: 1e-9, "web-1's two containers and web-2, once each; not the finished pods")
        XCTAssertEqual(FakePromQL.evaluate(KubePromQL.allocatable("cpu"), series)?.first?.value, 4, "a node once, whichever replica said it")
        XCTAssertEqual(FakePromQL.evaluate(KubePromQL.limits("cpu"), series), [], "no limits: none, not zero")
        XCTAssertTrue(KubePromQL.limits("memory").contains(KubePromQL.activePods))
    }

    func testTheFakeRefusesWhatItCannotRead() {
        XCTAssertNil(FakePromQL.evaluate("histogram_quantile(0.9, x)", []))
        XCTAssertNil(FakePromQL.evaluate("sum(x{a=\"b\"}", []), "unbalanced")
        XCTAssertNil(FakePromQL.evaluate("x{a=b}", []), "a matcher's value is a string")
        XCTAssertEqual(FakePromQL.evaluate("sum(x)", []), [], "nothing to add: no series, as Prometheus answers")
    }

    // MARK: The cluster's raw charts

    func testTheClusterIsReadRawUpToSixHours() {
        for range in KubeChartRange.allCases {
            let queries = KubeChart.cluster.queries(range: range)
            XCTAssertEqual(queries.totals.count, 6, "requests, limits and allocatable, every range: instant queries")
            if range.seconds <= 6 * 3600 {
                XCTAssertEqual(queries.series.map(\.0), [.cpu, .memory])
                XCTAssertNil(queries.refused)
            } else {
                XCTAssertTrue(queries.series.isEmpty, "\(range): not asked")
                XCTAssertEqual(queries.refused, KubeChart.rawRefusal(range))
            }
        }
        XCTAssertEqual(
            KubeChart.rawRefusal(.day),
            "Raw container metrics across the cluster are read over 6h at most: over 24h they would be tens of millions of samples, more than Prometheus answers in time. Pick 6h or less."
        )
        // One pod's raw series are cheap at every range.
        XCTAssertEqual(KubeChart.pod(namespace: "shop", name: "web-1").queries(range: .week).series.count, 2)
        XCTAssertNil(KubeChart.pod(namespace: "shop", name: "web-1").queries(range: .week).refused)
    }

    // MARK: The reader

    func testTheReaderKeepsNotesAndSkipsHistograms() throws {
        let partial = Data(
            #"{"status":"success","warnings":["partial response: store 10.0.0.9 unavailable"],"infos":["PromQL info: metric might not be a counter"],"data":{"resultType":"vector","result":[{"metric":{"pod":"a"},"value":[1800000000,"2"]},{"metric":{"pod":"h"},"histogram":[1800000000,{"count":"3","sum":"1","buckets":[]}]}]}}"#
                .utf8)
        let answer = try KubePrometheusReader.answer(partial)
        XCTAssertEqual(answer.resultType, "vector")
        XCTAssertEqual(answer.series.map(\.labels), [["pod": "a"]], "the histogram skipped")
        XCTAssertEqual(
            answer.notes,
            [
                "Partial answer: partial response: store 10.0.0.9 unavailable", "Prometheus notes: PromQL info: metric might not be a counter",
                "1 native-histogram series skipped: only float series are drawn.",
            ])
        // A matrix's histograms too.
        let matrix = Data(#"{"status":"success","data":{"resultType":"matrix","result":[{"metric":{},"histograms":[[1,{"count":"1"}]]}]}}"#.utf8)
        XCTAssertEqual(try KubePrometheusReader.answer(matrix).series, [])
        // A scalar.
        let scalar = Data(#"{"status":"success","data":{"resultType":"scalar","result":[1800000000,"42"]}}"#.utf8)
        XCTAssertEqual(KubePrometheusReader.value(try KubePrometheusReader.read(scalar)), 42)
        XCTAssertEqual(try KubePrometheusReader.answer(scalar).resultType, "scalar")
        // A string answers nothing to draw.
        XCTAssertEqual(try KubePrometheusReader.read(Data(#"{"status":"success","data":{"resultType":"string","result":[1,"x"]}}"#.utf8)), [])
        // Notes are bounded: three, each cut.
        let long = String(repeating: "w", count: 600)
        let many = Data(#"{"status":"success","warnings":["\#(long)","b","c","d"],"data":{"resultType":"vector","result":[]}}"#.utf8)
        let bounded = try KubePrometheusReader.answer(many).notes
        XCTAssertEqual(bounded.count, KubePrometheusReader.maxNotes)
        XCTAssertEqual(bounded.first?.count, KubePrometheusReader.maxNoteLength)
        // Prometheus' own timeout, said plainly.
        XCTAssertThrowsError(
            try KubePrometheusReader.read(Data(#"{"status":"error","errorType":"timeout","error":"query timed out in expression evaluation"}"#.utf8), status: 503)
        ) { XCTAssertEqual(($0 as? KubePrometheusReader.Failure)?.message, "Prometheus took longer than 20 s. Pick a shorter range.") }
    }

    func testALineBreaksWhereTwoPointsAreMoreThanTwoStepsApart() {
        func at(_ seconds: [Double]) -> [KubeSeriesPoint] { seconds.map { KubeSeriesPoint(time: Date(timeIntervalSince1970: $0), value: 1) } }
        let runs = KubePrometheusReader.segments(at([0, 30, 60, 120, 150, 300, 330]), step: 30)
        XCTAssertEqual(runs.map { $0.map { Int($0.time.timeIntervalSince1970) } }, [[0, 30, 60, 120, 150], [300, 330]], "one missing point bridged; a gap broken")
        XCTAssertEqual(KubePrometheusReader.segments([], step: 30).count, 0)
        XCTAssertEqual(KubePrometheusReader.segments(at([0]), step: 30).count, 1)
        // NaN, Inf left out: a run of them is a gap.
        let data = Data(
            #"{"status":"success","data":{"resultType":"matrix","result":[{"metric":{},"values":[[0,"1"],[30,"NaN"],[60,"NaN"],[90,"+Inf"],[120,"2"]]}]}}"#.utf8)
        let points = KubePrometheusReader.points((try? KubePrometheusReader.read(data)) ?? [])
        XCTAssertEqual(KubePrometheusReader.segments(points, step: 30).count, 2)
    }

    // MARK: The timeout

    /// A query answering slower than the deadline: given up, said as
    /// Prometheus' own timeout is, and the query cancelled.
    func testASlowQueryIsGivenUpAtTheDeadline() async throws {
        struct Slow: KubePrometheusTransport {
            let cancelled: CancelFlag
            func query(_ path: String) async throws -> HTTPResponse {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    cancelled.set()
                    throw error
                }
                return HTTPResponse(status: 200, headers: [], body: Data())
            }
        }
        let cancelled = CancelFlag()
        let started = Date()
        do {
            _ = try await KubePrometheusMonitor.fetch(Slow(cancelled: cancelled), "/q", deadline: .milliseconds(200))
            XCTFail("given up")
        } catch let failure as KubePrometheusReader.Failure {
            XCTAssertEqual(failure.message, KubePrometheusReader.tookTooLong)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertTrue(cancelled.value, "the query cancelled, not left holding its place")
        XCTAssertEqual(KubePromQL.deadline, .seconds(25))
        let service = KubePrometheusService(namespace: "monitoring", name: "prometheus-server", port: "80")!
        for path in [KubePromQL.instantPath(service, "up"), KubePromQL.rangePath(service, "up", .hour, now: Date())] {
            XCTAssertTrue(path.contains("timeout=20s"), path)
            XCTAssertTrue(service.allows(path))
        }
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}
