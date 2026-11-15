import Foundation
import XCTest

@testable import Overterm

/// A chart's Copy PromQL and Copy Values as CSV, and the expanded chart's
/// own identity (docs/design/kubernetes/metrics.md 2.1, 3.9; stage M9). Pure.
@MainActor
final class KubeChartExportTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func data(source: String = "Prometheus", series: [KubeChartSeries], id: String = "pod.shop.web-1.cpu") -> KubeChartData {
        KubeChartData(
            id: id, title: "CPU", unit: .cores, series: series, start: start, end: at(120), step: 30, source: source, tier: "raw cAdvisor", version: 1)
    }

    private let sent = [
        KubeTabQuery(id: "cpu", family: .cpu, promql: "sum by (container)(rate(container_cpu_usage_seconds_total{namespace=\"shop\"}[2m]))"),
        KubeTabQuery(id: "cpuPeak", family: .cpuPeak, promql: "max_over_time(x[5m:1m])"),
        KubeTabQuery(id: "throttling", family: .throttling, promql: "sum by (container)(increase(a[5m])) / sum by (container)(increase(b[5m]))"),
        KubeTabQuery(id: "topCPU", family: .topCPU, promql: "sum by (namespace,pod)(rate(c[2m]))"),
        KubeTabQuery(id: "saved.1", family: .saved, promql: "sum(rate(http_requests_total{namespace=\"shop\"}[2m]))"),
        KubeTabQuery(id: "disks", family: .disks, promql: "node_filesystem_size_bytes"),
        KubeTabQuery(id: "gpu", family: .gpu, promql: "DCGM_FI_DEV_GPU_UTIL"),
        KubeTabQuery(id: "hpaMetrics", family: .hpaMetrics, promql: "kube_horizontalpodautoscaler_status_target_metric", instant: false),
    ]

    func testAChartsQueriesAreTheOnesItWasDrawnFrom() {
        func ids(_ chart: String) -> [String] {
            KubeChartExport.attach(data(series: [], id: chart), sent: sent).queries.map(\.id)
        }
        XCTAssertEqual(ids("pod.shop.web-1.cpu"), ["cpu", "cpuPeak"], "the usage and its peaks")
        XCTAssertEqual(ids("container.shop.web-1.app.throttling"), ["throttling"])
        XCTAssertEqual(ids("node.fake-node-1.top.cpu"), ["topCPU"])
        XCTAssertEqual(ids("workload.shop.deployment.web.saved.1"), ["saved.1"], "a saved query's own")
        XCTAssertEqual(ids("node.fake-node-1.disk.root"), ["disks"])
        XCTAssertEqual(ids("pod.shop.web-1.gpu.utilisation"), ["gpu"])
        XCTAssertEqual(ids("hpa.shop.web.cpu-utilization"), ["hpaMetrics"], "an HPA's metric, by its slug")
        XCTAssertEqual(ids("pod.shop.web-1.network"), [], "one the read didn't send: none")
        XCTAssertTrue(KubeChartExport.attach(data(source: "metrics-server", series: []), sent: sent).queries.isEmpty, "a sampled chart has none")
    }

    /// The Overview's and a claim's charts (M9): the queries their reading
    /// sent for the measure each draws — its line (a union carrying its
    /// totals), the totals asked alone, its parts' —, never another's.
    func testAnOverviewChartsQueriesAreItsMeasures() {
        var reading = KubeChartReading(range: .hour)
        reading.queries = [
            KubeChartQuery(id: "cpu", promql: "cpu_line_union"),
            KubeChartQuery(id: "memory", promql: "memory_line_union"),
            KubeChartQuery(id: "cpuCapacity", promql: "cpu_capacity", instant: true),
            KubeChartQuery(id: "cpu by namespace", promql: "cpu_by_namespace"),
            KubeChartQuery(id: "volumeUsed", promql: "used"),
            KubeChartQuery(id: "volumeCapacity", promql: "capacity"),
            KubeChartQuery(id: "volumeAvailable", promql: "available", instant: true),
        ]
        func ids(_ chart: String, source: String = "Prometheus") -> [String] {
            KubeChartExport.attach(data(source: source, series: [], id: chart), reading: reading).queries.map(\.id)
        }
        XCTAssertEqual(ids("cluster.cpu"), ["cpu", "cpuCapacity", "cpu by namespace"])
        XCTAssertEqual(ids("cluster.memory"), ["memory"])
        XCTAssertEqual(ids("volume.shop.data-db-0.used"), ["volumeUsed", "volumeCapacity", "volumeAvailable"], "its capacity and fill with its use")
        XCTAssertEqual(ids("cluster.cpu", source: "metrics-server"), [], "sampled: none")
        XCTAssertEqual(KubeChartExport.promQL(reading.reported), nil, "nothing refused: nothing reported")
    }

    func testOnlyARefusalOffersCopyPromQLBesideItsSentence() {
        XCTAssertTrue(KubeChartEmpty.offersCopyPromQL(.badData))
        XCTAssertTrue(KubeChartEmpty.offersCopyPromQL(.filterRefused))
        for kind: KubePrometheusReader.Failure.Kind in [.timeout, .busy, .serviceProxyForbidden, .notFound, .unprocessable, .other] {
            XCTAssertFalse(KubeChartEmpty.offersCopyPromQL(kind), "\(kind)")
        }
    }

    func testCopyPromQLIsTheQueryAsSentOrEachNamed() throws {
        let one = KubeChartExport.attach(data(series: [], id: "container.shop.web-1.app.throttling"), sent: sent)
        XCTAssertEqual(KubeChartExport.promQL(one), sent[2].promql)
        let two = KubeChartExport.attach(data(series: []), sent: sent)
        XCTAssertEqual(KubeChartExport.promQL(two), "# cpu\n\(sent[0].promql)\n\n# cpuPeak\n\(sent[1].promql)")
        XCTAssertNil(KubeChartExport.promQL(data(source: "metrics-server", series: [])), "sampled: not offered")
    }

    func testAttachReachesEveryChartOfATab() {
        let chart = KubePodCharts.Chart(data: data(series: []))
        let charts = KubePodCharts(
            range: .hour, pod: [chart], sections: [KubePodCharts.Section(container: "app", charts: [chart])], caption: "", span: "last 1h", hasSamples: true)
        let attached = KubeChartExport.attach(charts, sent: sent)
        XCTAssertEqual(attached.pod[0].data.queries.count, 2)
        XCTAssertEqual(attached.sections[0].charts[0].data.queries.count, 2)
        let object = KubeObjectCharts(
            range: .hour, groups: [KubeObjectCharts.Group(title: "Usage", charts: [chart])], caption: "", span: "last 1h", hasSamples: true)
        XCTAssertEqual(KubeChartExport.attach(object, sent: sent).groups[0].charts[0].data.queries.count, 2)
    }

    func testCSVIsTheWindowsValuesEveryCellInert() throws {
        let csv = KubeChartExport.csv(
            data(series: [
                KubeChartSeries(id: "app", name: "app", points: [KubeSeriesPoint(time: at(-30), value: 9), KubeSeriesPoint(time: at(0), value: 0.12), KubeSeriesPoint(time: at(60), value: 0.25)]),
                // A gap at 0: empty there, never a zero.
                KubeChartSeries(id: "evil", name: "=HYPERLINK(\"x\")", points: [KubeSeriesPoint(time: at(60), value: 0.005), KubeSeriesPoint(time: at(90), value: 1)]),
                KubeChartSeries(id: "request", name: "request", role: .request, points: [KubeSeriesPoint(time: at(120), value: 0.25)]),
                KubeChartSeries(id: "limit", name: "limit", role: .limit, points: [KubeSeriesPoint(time: at(30), value: 1), KubeSeriesPoint(time: at(90), value: 2)]),
            ]))
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, #"time,app (cores),"'=HYPERLINK(""x"") (cores)",request (cores),limit (cores)"#, "a name a spreadsheet would run, inert")
        XCTAssertEqual(lines.count, 4, "the window's times only: the point before it left out")
        XCTAssertEqual(lines[1], "2027-01-15T08:00:00Z,0.12,,0.25,1", "a reference before its first point: its first, as drawn")
        XCTAssertEqual(lines[2], "2027-01-15T08:01:00Z,0.25,0.005,0.25,1")
        XCTAssertEqual(lines[3], "2027-01-15T08:01:30Z,,1,0.25,2", "a reference holds its last value")
    }

    func testCSVLeavesOutWhatTheLegendHides() {
        let chart = data(series: [
            KubeChartSeries(id: "app", name: "app", points: [KubeSeriesPoint(time: at(0), value: 1)]),
            KubeChartSeries(id: "sidecar", name: "sidecar", points: [KubeSeriesPoint(time: at(0), value: 2)]),
            KubeChartSeries(id: "limit", name: "limit", role: .limit, points: [KubeSeriesPoint(time: at(0), value: 3)]),
        ])
        XCTAssertEqual(KubeChartExport.csv(chart, hidden: ["sidecar"], hideReferences: true), "time,app (cores)\n2027-01-15T08:00:00Z,1\n")
        XCTAssertEqual(KubeChartExport.number(-0.5), "-0.5")
        XCTAssertEqual(KubeChartExport.number(1_048_576), "1048576")
        XCTAssertEqual(KubeChartExport.number(.infinity), "+Inf")
    }

    func testAnExpandedChartIsTheTabsUnderItsOwnIdentifier() {
        let chart = KubePodCharts.Chart(data: data(series: []), headline: "120m now")
        let expanded = KubeExpandedChart(
            ref: KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "web-1"),
            shown: KubeExpandedChart.Shown(chart: chart, span: "last 1h", caption: nil), now: at(0))
        XCTAssertEqual(expanded.chartID, "pod.shop.web-1.cpu")
        XCTAssertEqual(KubeExpandedChart.data(expanded.last).identifier, "kubernetes.chart.expanded.pod.shop.web-1.cpu")
        XCTAssertEqual(KubeExpandedChart.data(expanded.last).version, chart.data.version, "the same data: no plot of its own built for nothing")
        var again = chart
        again.headline = "200m now"
        expanded.remember(KubeExpandedChart.Shown(chart: again, span: "last 1h", caption: nil), now: at(60))
        XCTAssertEqual(expanded.last.chart.headline, "200m now")
        XCTAssertEqual(expanded.updated, at(60))
        XCTAssertTrue(KubeExpandedChart.stale(since: at(60)).contains("nothing is read for it"))
    }
}
