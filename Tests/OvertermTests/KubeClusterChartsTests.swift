import Foundation
import XCTest

@testable import Overterm

/// The Overview's usage by namespace and node and a claim's fill forecast
/// (docs/design/kubernetes/metrics.md 2.9, 4.6; stage M8): X1–X4's queries
/// per tier as golden strings, their charts sampled and from Prometheus —
/// the shares of allocatable as chips, overcommitted red, a sampled chart
/// with no requests line and its chip saying why —, X3's top eight and the
/// rest, X4's hottest 50 by name; V1's projection and chip, the EFS rule;
/// C4 only where the probe found cAdvisor's filesystem use, K2's node
/// total only where node-exporter maps to nodes. Pure.
final class KubeClusterChartsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let gib = 1_073_741_824.0

    private var stack: KubePromProfile {
        var profile = KubePromProfile(probed: now)
        profile.metrics = FakePromProfile.kubePrometheusStack.metrics
        profile.cadvisorPath = "/metrics/cadvisor"
        profile.cadvisorJob = "kubelet"
        profile.ksmJob = "kube-state-metrics"
        profile.nodeLabel = .node
        profile.scrape = 30
        return profile
    }

    private var chart: KubePromProfile {
        var profile = KubePromProfile(probed: now)
        profile.metrics = FakePromProfile.prometheusChart.metrics
        profile.nodeLabel = .instance
        profile.scrape = 60
        return profile
    }

    private func points(_ values: [Double], from start: Date, step: TimeInterval) -> [KubeSeriesPoint] {
        values.enumerated().map { KubeSeriesPoint(time: start.addingTimeInterval(Double($0.offset) * step), value: $0.element) }
    }

    // MARK: Queries

    func testCPUByNamespaceIsRankedThenReadByTier() throws {
        let rules = try XCTUnwrap(KubeChart.namespaceRanking(range: .day, profile: stack, picked: []))
        XCTAssertEqual(
            rules.query,
            #"topk(8, sum by (namespace)(max by (namespace,pod,container)(avg_over_time(node_namespace_pod_container:container_cpu_usage_seconds_total:sum_rate5m{container!="",container!="POD"}[24h]))))"#,
            "the rule's average over the range: no subquery")
        let lines = KubeChart.namespaceQueries(range: .day, profile: stack, picked: [], top: ["shop", "pay.v2"])
        XCTAssertEqual(lines.tier, .rules)
        XCTAssertEqual(
            lines.series.first?.1,
            #"sum(max by (namespace,pod,container)(node_namespace_pod_container:container_cpu_usage_seconds_total:sum_rate5m{container!="",container!="POD"}))"#)
        XCTAssertEqual(
            lines.parts.first?.1,
            #"sum by (namespace)(max by (namespace,pod,container)(node_namespace_pod_container:container_cpu_usage_seconds_total:sum_rate5m{namespace=~"shop|pay\\.v2",container!="",container!="POD"}))"#,
            "the top ones by name, regex-escaped then string-escaped")
        XCTAssertEqual(lines.partLabel, "namespace")

        // Raw: the counter's rate over the range, the namespaces picked.
        let raw = try XCTUnwrap(KubeChart.namespaceRanking(range: .hour, profile: chart, picked: ["shop", "pay"]))
        XCTAssertEqual(
            raw.query, #"topk(8, sum by (namespace)(rate(container_cpu_usage_seconds_total{container!="",image!="",container!="POD",namespace=~"shop|pay"}[1h])))"#)
        let hour = KubeChart.namespaceQueries(range: .hour, profile: chart, picked: ["shop", "pay"], top: ["pay"])
        XCTAssertEqual(
            hour.series.first?.1,
            #"sum(sum by (namespace,pod,container)(rate(container_cpu_usage_seconds_total{container!="",image!="",container!="POD",namespace=~"shop|pay"}[4m])))"#)
        XCTAssertEqual(
            hour.parts.first?.1,
            #"sum by (namespace)(sum by (namespace,pod,container)(rate(container_cpu_usage_seconds_total{container!="",image!="",container!="POD",namespace="pay"}[4m])))"#)
        XCTAssertTrue(KubeChart.namespaceQueries(range: .hour, profile: chart, picked: [], top: []).parts.isEmpty, "not ranked yet: the total alone")

        // Raw past 6h: refused, said, nothing asked.
        let day = KubeChart.namespaceQueries(range: .day, profile: chart, picked: [], top: [])
        XCTAssertNil(day.tier)
        XCTAssertTrue(day.series.isEmpty && day.parts.isEmpty)
        XCTAssertEqual(day.refused?.hasPrefix("Raw container metrics over 24h"), true, day.refused ?? "")
        XCTAssertNil(KubeChart.namespaceRanking(range: .day, profile: chart, picked: []))
        XCTAssertEqual(KubeChart.order(.namespaces([])), 1)
    }

    /// The rule's average reads a sample a series every interval too: past
    /// the samples cap it ranks over the last 24h, as the raw ranking does,
    /// and says so (metrics.md 4.5).
    func testCPUByNamespaceOverTheRulesIsRankedOver24hOnALargeCluster() throws {
        var large = stack
        large.metrics?[KubePromProfile.containerCPURate5m] = 10_000
        let week = try XCTUnwrap(KubeChart.namespaceRanking(range: .week, profile: large, picked: []))
        XCTAssertEqual(
            week.query,
            #"topk(8, sum by (namespace)(max by (namespace,pod,container)(avg_over_time(node_namespace_pod_container:container_cpu_usage_seconds_total:sum_rate5m{container!="",container!="POD"}[24h]))))"#,
            "10,000 series over a week at 30 s: about 200M samples, ranked over the last day")
        XCTAssertEqual(week.note, "ranked by the last 24h")
        // A small cluster's week is read whole, nothing said.
        var small = stack
        small.metrics?[KubePromProfile.containerCPURate5m] = 200
        let whole = try XCTUnwrap(KubeChart.namespaceRanking(range: .week, profile: small, picked: []))
        XCTAssertTrue(whole.query.contains("[168h]"), whole.query)
        XCTAssertNil(whole.note)
    }

    /// X1, X2 and X4 (metrics.md 4.2, 6.5): each measure's line and its
    /// totals asked as one range union, tagged by measure, read apart.
    func testTheClusterAndTheNodesAskAQueryAMeasure() {
        let cluster = KubeChart.cluster.queries(range: .hour, profile: stack)
        XCTAssertTrue(cluster.unioned)
        XCTAssertEqual(cluster.carried(by: .cpu).map(\.0), [.cpuRequests, .cpuLimits, .cpuAllocatable, .cpuCapacity])
        XCTAssertEqual(cluster.carried(by: .memory).map(\.0), [.memoryRequests, .memoryLimits, .memoryAllocatable, .memoryCapacity])
        let cpu = KubeChartQueries.union(cluster.series[0], carrying: cluster.carried(by: .cpu))
        XCTAssertTrue(cpu.hasPrefix(#"label_replace(\#(KubePromQL.ruleClusterCPU),"overterm_s","cpu","","") or label_replace("#), cpu)
        XCTAssertTrue(cpu.contains(#"kube_node_status_capacity{job="kube-state-metrics",resource="cpu"})),"overterm_s","cpuCapacity","","")"#), cpu)
        XCTAssertFalse(cpu.contains("memory"), "the memory totals ride with memory's line")
        // Its arms read apart; a line asked alone keeps all its series.
        let answer = [
            KubeSeries(labels: ["overterm_s": "cpu"], points: [KubeSeriesPoint(time: now, value: 2)]),
            KubeSeries(labels: ["overterm_s": "cpuAllocatable"], points: [KubeSeriesPoint(time: now, value: 4)]),
        ]
        XCTAssertEqual(KubeChartQueries.arm(answer, .cpuAllocatable, of: cluster.carried(by: .cpu)).first?.points.last?.value, 4)
        XCTAssertEqual(KubeChartQueries.arm(answer, .cpu, of: []).count, 2)

        let nodes = KubeChart.nodeQueries(range: .day, profile: stack)
        XCTAssertTrue(nodes.unioned)
        XCTAssertEqual(nodes.carried(by: .cpu, parts: true).map(\.0), [.cpuAllocatable])
        XCTAssertEqual(
            KubeChartQueries.union(nodes.parts[1], carrying: nodes.carried(by: .memory, parts: true)),
            #"label_replace(sum by (node)(max by (node,namespace,pod,container)(max_over_time(node_namespace_pod_container:container_memory_working_set_bytes{container!="",container!="POD"}[24m]))),"overterm_s","memory","","")"#
                + #" or label_replace(max by (node)(kube_node_status_allocatable{job="kube-state-metrics",resource="memory"}),"overterm_s","memoryAllocatable","","")"#)
        XCTAssertFalse(KubeChart.namespaces([]).queries(range: .hour, profile: stack).unioned, "X3's total and its parts: a query each")
    }

    func testNodesAreReadAsSixtyCellsByTheirLabel() {
        let rules = KubeChart.nodeQueries(range: .day, profile: stack)
        XCTAssertEqual(rules.step, 1440, "a day as 60 cells of 24 minutes")
        XCTAssertEqual(rules.partLabel, "node")
        XCTAssertEqual(
            rules.parts.map(\.1),
            [
                #"sum by (node)(max by (node,namespace,pod,container)(max_over_time(node_namespace_pod_container:container_cpu_usage_seconds_total:sum_rate5m{container!="",container!="POD"}[24m])))"#,
                #"sum by (node)(max by (node,namespace,pod,container)(max_over_time(node_namespace_pod_container:container_memory_working_set_bytes{container!="",container!="POD"}[24m])))"#,
            ], "each cell's highest kept past 5-minute steps")
        XCTAssertEqual(
            rules.partTotals.map(\.1),
            [
                #"max by (node)(kube_node_status_allocatable{job="kube-state-metrics",resource="cpu"})"#,
                #"max by (node)(kube_node_status_allocatable{job="kube-state-metrics",resource="memory"})"#,
            ])
        let raw = KubeChart.nodeQueries(range: .hour, profile: chart)
        XCTAssertEqual(raw.tier, .raw)
        XCTAssertEqual(raw.partLabel, "instance", "the prometheus chart's cAdvisor names the node by instance")
        XCTAssertEqual(
            raw.parts.first?.1,
            #"sum by (instance)(sum by (instance,namespace,pod,container)(rate(container_cpu_usage_seconds_total{container!="",image!="",container!="POD"}[4m])))"#)
        XCTAssertEqual(
            raw.parts.last?.1, #"sum by (instance)(max by (instance,namespace,pod,container)(container_memory_working_set_bytes{container!="",image!="",container!="POD"}))"#)
        let week = KubeChart.nodeQueries(range: .week, profile: chart)
        XCTAssertTrue(week.parts.isEmpty)
        XCTAssertNotNil(week.refused, "raw across the cluster over a week: refused")
        var nameless = chart
        nameless.nodeLabel = nil
        XCTAssertEqual(KubeChart.nodeQueries(range: .hour, profile: nameless).refused?.contains("name no node"), true)
    }

    func testTheClustersCapacityAndAClaimsForecastQueries() {
        XCTAssertEqual(KubePromQL.capacity("cpu", profile: stack), #"sum(max by (node)(kube_node_status_capacity{job="kube-state-metrics",resource="cpu"}))"#)
        var old = chart
        old.metrics?["kube_pod_container_resource_requests"] = nil
        old.metrics?[KubePromProfile.requestsCPUCores] = 10
        XCTAssertEqual(KubePromQL.capacity("memory", profile: old), "sum(max by (node)(kube_node_status_capacity_memory_bytes{}))")
        let volume = KubeChart.volume(namespace: "shop", claim: "data-db-0").queries(range: .hour)
        XCTAssertEqual(volume.totals.map(\.0), [.volumeAvailable, .volumeFill], "deriv alone: predict_linear would extend the same line")
        XCTAssertFalse(volume.totals.contains { $0.1.contains("predict_linear") })
        XCTAssertFalse(volume.unioned)
        XCTAssertEqual(volume.totals[1].1, #"-sum(deriv(kubelet_volume_stats_available_bytes{namespace="shop",persistentvolumeclaim="data-db-0"}[6h]))"#)
        XCTAssertEqual(
            KubeChart.volumeInodes(namespace: "shop", claim: "d").queries(range: .hour).series.first?.1,
            #"sum(kubelet_volume_stats_inodes_used{namespace="shop",persistentvolumeclaim="d"}) / sum(kubelet_volume_stats_inodes{namespace="shop",persistentvolumeclaim="d"})"#)
        XCTAssertFalse(KubeChart.volumeInodes(namespace: "shop", claim: "d").needsProfile)
        XCTAssertTrue(KubeChart.nodes.needsProfile && KubeChart.namespaces([]).needsProfile)
    }

    // MARK: X1, X2

    func testTheClustersChartsCarryTheirSharesAndCapacity() {
        var reading = KubeChartReading(range: .hour)
        reading.read = now
        reading.series[.cpu] = points([1, 2, 3], from: now.addingTimeInterval(-60), step: 30)
        reading.series[.memory] = points([gib], from: now, step: 30)
        reading.totals = [.cpuRequests: 2, .cpuLimits: 5.72, .cpuAllocatable: 4, .cpuCapacity: 4.2, .memoryRequests: gib, .memoryAllocatable: 8 * gib]
        let charts = KubeClusterCharts.prometheus(reading)
        XCTAssertEqual(charts.map(\.data.id), ["cluster.cpu", "cluster.memory"])
        XCTAssertEqual(charts[0].data.references.map(\.role), [.request, .limit, .allocatable, .capacity])
        XCTAssertEqual(charts[0].chips, [KubeChartChip(text: "requests 50% of allocatable"), KubeChartChip(text: "limits 143% of allocatable · overcommitted", alert: true)])
        XCTAssertEqual(charts[1].chips.map(\.text), ["requests 13% of allocatable"], "no limits read: none said")
        XCTAssertEqual(charts[1].data.references.map(\.role), [.request, .allocatable])
    }

    func testSampledClusterChartsHaveNoRequestsLine() {
        let samples = (0..<10).map { KubeUsagePoint(time: now.addingTimeInterval(Double($0 - 9) * 15), usage: KubeUsage(cpu: 1, memory: 2 * gib)) }
        let charts = KubeClusterCharts.sampled(
            samples, allocatable: KubeUsage(cpu: 4, memory: 8 * gib), capacity: KubeUsage(cpu: 4.5, memory: 9 * gib), interval: 15, now: now)
        XCTAssertEqual(charts.map(\.data.id), ["cluster.cpu", "cluster.memory"])
        XCTAssertEqual(charts[0].data.references.map(\.role), [.allocatable, .capacity], "the nodes' read's lines, no requests")
        XCTAssertEqual(charts[0].data.source, "metrics-server")
        XCTAssertEqual(charts[0].chips.map(\.text), ["25% of allocatable", KubeClusterCharts.requestsNeedPrometheus])
        XCTAssertEqual(charts[1].headline, "2.0Gi now")
        XCTAssertEqual(charts[0].data.start, now.addingTimeInterval(-600), "ten minutes at least")
        XCTAssertTrue(KubeClusterCharts.sampled([], allocatable: nil, capacity: nil, interval: 15, now: now).allSatisfy { $0.data.references.isEmpty })
        XCTAssertEqual(KubeChartEmpty.requestsNeedSpecs.sentence, "Requests need the pods' specs; pick one node or turn Prometheus on.")
    }

    // MARK: X3

    func testCPUByNamespaceIsTheTopEightAndTheRest() {
        var reading = KubeChartReading(range: .hour)
        reading.read = now
        reading.tier = .rules
        let start = now.addingTimeInterval(-60)
        reading.series[.cpu] = points([10, 10, 10], from: start, step: 30)
        let names = (1...8).map { "ns-\($0)" }
        reading.ranked = names
        reading.parts[.cpu] = Dictionary(uniqueKeysWithValues: names.map { ($0, points([1, 1, 1], from: start, step: 30)) })
        let chart = KubeClusterCharts.namespaces(reading)
        XCTAssertEqual(chart?.data.id, "cluster.namespaces.cpu")
        XCTAssertEqual(chart?.data.stacked, true)
        XCTAssertEqual(chart?.data.usage.map(\.id), names + ["other"])
        XCTAssertEqual(chart?.data.usage.last?.points.map(\.value), [2, 2, 2], "the total less the eight")
        XCTAssertEqual(chart?.data.tier, "recording rules")
        // Not ranked yet: the total as one band.
        reading.ranked = nil
        XCTAssertEqual(KubeClusterCharts.namespaces(reading)?.data.usage.map(\.name), ["all namespaces"])
        reading.refused = "too costly"
        XCTAssertNil(KubeClusterCharts.namespaces(reading))
    }

    // MARK: X4

    func testNodesAreTheHottestFiftyByName() {
        var reading = KubeChartReading(range: .hour)
        reading.read = now
        let window = KubeChartRange.hour.window(now: now)
        var cpu: [String: [KubeSeriesPoint]] = [:]
        var allocatable: [String: Double] = [:]
        for index in 0..<60 {
            let name = String(format: "node-%02d", index)
            cpu[name] = points([Double(index) / 10], from: window.end, step: 60)
            allocatable[name] = 4
        }
        reading.parts[.cpu] = cpu
        reading.partTotals[.cpuAllocatable] = allocatable
        let (rows, more) = KubeClusterCharts.nodeRows(reading, allocatable: [:])
        XCTAssertEqual(rows.count, 50)
        XCTAssertEqual(more, 10)
        XCTAssertEqual(rows.first?.node, "node-10", "the ten coolest left out")
        XCTAssertEqual(rows.map(\.node), rows.map(\.node).sorted(), "by name")
        let hottest = rows.last
        XCTAssertEqual(hottest?.cpu?.now ?? 0, 147.5, accuracy: 0.01, "5.9 of 4 cores")
        XCTAssertEqual(hottest?.cpu?.sampled, false)
        XCTAssertNil(hottest?.memory, "no memory read: no strip")
        // The /nodes read's allocatable where kube-state-metrics has none.
        reading.partTotals = [:]
        XCTAssertEqual(KubeClusterCharts.nodeRows(reading, allocatable: ["node-01": KubeUsage(cpu: 1, memory: 1)]).rows.map(\.node), ["node-01"])
        XCTAssertEqual(KubeClusterCharts.stripIdentifier("node-01", .memory), "kubernetes.overview.heat.node-01.memory")
    }

    /// X4 in one Canvas (M12): where its rows and strips are, what a
    /// point is over, a long name cut in its middle.
    func testTheNodesStripsLayout() {
        let layout = KubeNodeStripsLayout(count: 3)
        XCTAssertEqual(layout.height(3), 4 * KubeNodeStripsLayout.rowHeight, "a header and three rows")
        XCTAssertEqual(layout.mid(0), KubeNodeStripsLayout.rowHeight * 1.5)
        let cpu = layout.strip(.cpu, row: 1)
        let memory = layout.strip(.memory, row: 1)
        XCTAssertEqual(cpu.minX, KubeNodeStripsLayout.nameWidth + KubeNodeStripsLayout.gap)
        XCTAssertGreaterThan(memory.minX, cpu.maxX + KubeNodeStripsLayout.shareWidth, "the CPU's share between them")
        XCTAssertLessThanOrEqual(memory.minX + KubeNodeStripsLayout.column, layout.width)
        XCTAssertEqual(cpu.midY, layout.mid(1))
        XCTAssertNil(layout.hit(CGPoint(x: 10, y: 5), rows: 3), "the header")
        XCTAssertTrue(layout.hit(CGPoint(x: 10, y: layout.mid(0)), rows: 3).map { $0.row == 0 && $0.measure == nil } == true, "a name")
        XCTAssertTrue(layout.hit(CGPoint(x: cpu.midX, y: cpu.midY), rows: 3).map { $0.row == 1 && $0.measure == .cpu } == true)
        XCTAssertTrue(layout.hit(CGPoint(x: memory.maxX + 20, y: memory.midY), rows: 3).map { $0.row == 1 && $0.measure == .memory } == true, "its share")
        XCTAssertNil(layout.hit(CGPoint(x: 10, y: layout.mid(3)), rows: 3), "past the last row")
        XCTAssertEqual(KubeNodeStripsLayout.middleCut("node-01", fits: 30), "node-01")
        let cut = KubeNodeStripsLayout.middleCut("ip-10-0-12-34.eu-west-1.compute.internal", fits: 20)
        XCTAssertEqual(cut, "ip-10-0-12….internal")
        XCTAssertEqual(cut.count, 20)
        XCTAssertEqual(KubeNodeStripsLayout.fits(0), 32)
    }

    func testAPrometheusStripIsTheRangeAsSixtyCells() throws {
        let start = now.addingTimeInterval(-3600)
        // A point every minute, the last at the end; one missing.
        let line = (1...60).filter { $0 != 30 }.map { KubeSeriesPoint(time: start.addingTimeInterval(Double($0) * 60), value: Double($0) / 60 * 2) }
        let strip = try XCTUnwrap(KubeHeatStrip.of(line, .cpu, allocatable: 2, start: start, end: now))
        XCTAssertEqual(strip.percents.count, 60)
        XCTAssertEqual(strip.cell, 60)
        XCTAssertNil(strip.percents[29], "a minute without a point is empty, never zero")
        XCTAssertEqual(strip.now ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(strip.filled, 59)
        XCTAssertTrue(strip.summary().hasPrefix("CPU as a share of allocatable, the last 60 min in 1 min cells"), strip.summary())
        XCTAssertTrue(strip.summary().hasSuffix("— from Prometheus"))
        XCTAssertNil(KubeHeatStrip.of(line, .cpu, allocatable: nil, start: start, end: now))
        XCTAssertEqual(KubeHeatStrip.spoken(86400), "24h")
        XCTAssertEqual(KubeHeatStrip.spoken(7 * 86400), "7 d")
        XCTAssertEqual(KubeHeatStrip.spoken(1440), "24 min")
    }

    // MARK: V1, V2, EFS

    func testAClaimFillsTowardItsCapacity() throws {
        var reading = KubeChartReading(range: .hour)
        reading.read = now
        let window = KubeChartRange.hour.window(now: now)
        reading.series[.volumeUsed] = points([2 * gib, 2 * gib], from: window.end.addingTimeInterval(-30), step: 30)
        reading.series[.volumeCapacity] = points([10 * gib], from: window.end, step: 30)
        // 8 GiB left, filling 4 GiB a day: full in two days.
        reading.totals = [.volumeAvailable: 8 * gib, .volumeFill: 4 * gib / 86400]
        let data = KubeChartData.of(reading, chart: .volume(namespace: "shop", claim: "data"), measure: .volumeUsed)
        XCTAssertEqual(data.references.map(\.role), [.capacity, .projection])
        let projection = try XCTUnwrap(data.references.last)
        XCTAssertEqual(projection.points.first?.time, window.end)
        XCTAssertEqual(data.end, window.end.addingTimeInterval(900), "a quarter of the range past now")
        XCTAssertEqual(projection.points.last?.value ?? 0, 2 * gib + 4 * gib / 86400 * 900, accuracy: 1)
        XCTAssertEqual(KubeVolumeForecast.chip(available: 8 * gib, rate: KubeVolumeForecast.rate(reading)), KubeChartChip(text: "full in ~2 d"))
        XCTAssertEqual(KubeVolumeForecast.chip(available: 1 * gib, rate: 4 * gib / 86400), KubeChartChip(text: "full in ~6 h", alert: true))
        XCTAssertEqual(KubeVolumeForecast.chip(available: 8 * gib, rate: 0), KubeChartChip(text: "not filling"))
        XCTAssertEqual(KubeVolumeForecast.chip(available: 8 * gib, rate: -5), KubeChartChip(text: "not filling"))
        XCTAssertEqual(KubeVolumeForecast.chip(available: 8 * gib, rate: 1), KubeChartChip(text: "not filling"), "past a year")
        XCTAssertNil(KubeVolumeForecast.chip(available: 8 * gib, rate: nil), "nothing read: nothing said")
        // No deriv read: no rate, no chip.
        reading.totals = [.volumeAvailable: 8 * gib]
        XCTAssertNil(KubeVolumeForecast.rate(reading))
        // Stopped at the capacity where it gets there before the edge.
        let full = try XCTUnwrap(KubeVolumeForecast.projection(from: KubeSeriesPoint(time: now, value: 9 * gib), rate: gib / 60, capacity: 10 * gib, until: now.addingTimeInterval(3600)))
        XCTAssertEqual(full.points.last?.time, now.addingTimeInterval(60))
        XCTAssertEqual(full.points.last?.value, 10 * gib)
        XCTAssertNil(KubeVolumeForecast.projection(from: KubeSeriesPoint(time: now, value: gib), rate: 0, capacity: 10 * gib, until: now.addingTimeInterval(60)))
    }

    func testAVolumeWithNoFixedSizeHasNoShareNorForecast() {
        let efs = 9_223_372_036_854_775_807.0
        XCTAssertTrue(KubeVolumeUsage.isUnbounded(efs))
        XCTAssertFalse(KubeVolumeUsage.isUnbounded(1_125_899_906_842_624.0))
        let usage = KubeVolumeUsage(used: 2 * 1_073_741_824, capacity: efs)
        XCTAssertNil(usage.percent)
        XCTAssertEqual(usage.text, "2.0Gi (no fixed size)")
        XCTAssertEqual(KubeVolumeFormat.bytes(efs), "8.0Ei")
        var reading = KubeChartReading(range: .hour)
        reading.read = now
        reading.series[.volumeUsed] = points([2 * 1_073_741_824.0], from: now, step: 30)
        reading.series[.volumeCapacity] = points([efs], from: now, step: 30)
        reading.totals = [.volumeAvailable: efs, .volumeFill: 1000]
        let data = KubeChartData.of(reading, chart: .volume(namespace: "shop", claim: "efs"), measure: .volumeUsed)
        XCTAssertTrue(data.references.isEmpty, "no capacity line, no projection")
        XCTAssertEqual(KubeVolumeForecast.unbounded(efs), "The volume reports 8.0Ei of capacity, as EFS does: it has no fixed size, so there is no share of it and no forecast.")
        let inodes = KubeChartData.of(reading, chart: .volumeInodes(namespace: "shop", claim: "efs"), measure: .inodes)
        XCTAssertEqual(inodes.unit, .ratio)
        XCTAssertEqual(inodes.id, "volume.shop.efs.inodes")
    }

    func testAProjectionIsDrawnStraightToItsEnd() {
        let data = KubeChartData(
            id: "v", title: "Used", unit: .bytes,
            series: [
                KubeChartSeries(id: "used", name: "Used", points: points([10, 20], from: now, step: 60)),
                KubeChartSeries(
                    id: "forecast", name: "forecast", role: .projection,
                    points: [KubeSeriesPoint(time: now.addingTimeInterval(60), value: 20), KubeSeriesPoint(time: now.addingTimeInterval(120), value: 40)]),
            ], start: now, end: now.addingTimeInterval(180), step: 60)
        let plot = KubePlot(data, size: CGSize(width: 400, height: 140))
        XCTAssertEqual(plot.references.count, 1)
        let reference = plot.references[0]
        XCTAssertEqual(reference.labelAt.x, plot.x(of: now.addingTimeInterval(120)), accuracy: 0.01, "ends where the trend is drawn to, not at the right edge")
        XCTAssertEqual(reference.labelAt.y, plot.y(of: 40), accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(plot.top, 40, "the axis reaches it")
        XCTAssertEqual(KubeChartRole.projection.dash, [1, 3])
        XCTAssertTrue(KubeChartSummary.dump(data, plot: plot).contains("forecast=40B"))
    }

    // MARK: C4, K2

    func testEphemeralStorageOnlyWhereTheKubeletReportsIt() {
        let plan = KubeTabTesting.plan(.hour, profile: stack)
        XCTAssertEqual(
            plan.queries.first { $0.id == "fs" }?.promql,
            #"label_replace(sum by (container)(max by (container,device)(container_fs_usage_bytes{container!="",image!="",container!="POD",metrics_path="/metrics/cadvisor",namespace="shop",pod="web-1"})),"overterm_s","usage","","")"#
                + #" or label_replace(max by (container)(kube_pod_container_resource_limits{job="kube-state-metrics",namespace="shop",pod="web-1",resource="ephemeral_storage"}),"overterm_s","limit","","")"#
        )
        var containerd = chart
        containerd.metrics = FakePromProfile.containerdNoFS.metrics
        let none = KubeTabTesting.plan(.hour, profile: containerd)
        XCTAssertNil(none.queries.first { $0.family == .fs })
        XCTAssertEqual(none.refused[.fs], KubeChartEmpty.noContainerFS.sentence)
        XCTAssertTrue(KubeChartEmpty.noContainerFS.sentence.contains("nodes/proxy"))

        // Drawn per container against its limit; said where the pod's node reports none.
        let span = KubeMetricsSpan.of(.hour, scrape: 30, now: now)
        var reading = KubeTabReading(request: KubeTabTesting.request(.hour))
        reading.span = span
        reading.read = span.end
        reading.results["fs"] = [
            KubeSeries(labels: ["overterm_s": "usage", "container": "app"], points: points([gib, 1.8 * gib], from: span.end.addingTimeInterval(-30), step: 30)),
            KubeSeries(labels: ["overterm_s": "limit", "container": "app"], points: points([2 * gib], from: span.end, step: 30)),
        ]
        let fs = KubePromTabCharts.fsChart("app", reading: reading, span: span, id: "container.shop.web-1.app")
        XCTAssertEqual(fs?.data.id, "container.shop.web-1.app.fs")
        XCTAssertEqual(fs?.data.references.map(\.role), [.limit])
        XCTAssertEqual(fs?.chips, [KubeChartChip(text: "90% of limit", alert: true)])
        XCTAssertNil(KubePromTabCharts.fsChart("sidecar", reading: reading, span: span, id: "x"))
        XCTAssertEqual(KubePromTabCharts.fsNotes(reading), [])
        reading.results["fs"] = [KubeSeries(labels: ["overterm_s": "limit", "container": "app"], points: points([2 * gib], from: span.end, step: 30))]
        XCTAssertEqual(KubePromTabCharts.fsNotes(reading), [KubeChartEmpty.noContainerFS.sentence])
    }

    func testANodesOwnMemoryOnlyWhereNodeExporterMapsToIt() throws {
        let node = KubeTabSubject.node("ip-10-0-0-1")
        let mapped = KubeTabTesting.plan(.hour, profile: stack, subject: node)
        let memory = try XCTUnwrap(mapped.queries.first { $0.id == "memory" }?.promql)
        XCTAssertTrue(
            memory.contains(
                #"label_replace(sum(max by (instance)(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) * on(instance) group_left(nodename) max by (instance,nodename)(node_uname_info{nodename="ip-10-0-0-1"})),"overterm_s","total","","")"#
            ), memory)
        XCTAssertFalse(mapped.notes.contains(KubeChartEmpty.nodeExporterUnmapped.sentence))
        var unmapped = chart
        unmapped.metrics = FakePromProfile.noNodeExporter.metrics
        let plain = KubeTabTesting.plan(.hour, profile: unmapped, subject: node)
        XCTAssertFalse(plain.queries.first { $0.id == "memory" }?.promql.contains("node_uname_info") ?? true)
        XCTAssertTrue(plain.notes.contains(KubeChartEmpty.nodeExporterUnmapped.sentence), "the tab says so")

        let span = KubeMetricsSpan.of(.hour, scrape: 30, now: now)
        var reading = KubeTabReading(request: KubeTabTesting.request(.hour, subject: node))
        reading.span = span
        reading.read = span.end
        reading.results["memory"] = [
            KubeSeries(labels: ["overterm_s": "usage"], points: points([gib], from: span.end, step: 30)),
            KubeSeries(labels: ["overterm_s": "total"], points: points([3 * gib], from: span.end, step: 30)),
        ]
        let charts = KubePromTabCharts.node(
            node: "ip-10-0-0-1", facts: KubeNodeFacts.of(["status": ["allocatable": ["cpu": "4", "memory": "8Gi"]]]), reading: reading, changes: KubeChartChanges(),
            window: nil)
        let chart = try XCTUnwrap(charts.groups.first?.charts.first { $0.data.id == "node.ip-10-0-0-1.memory" })
        XCTAssertEqual(chart.data.usage.map(\.name), ["Memory", "node total"])
        XCTAssertEqual(chart.headline, "1.0Gi now", "the pods' working set, as before")
    }
}

extension KubeChart {
    /// Its place in the queue, for a test to read.
    static func order(_ chart: KubeChart) -> Int { chart.order }
}
