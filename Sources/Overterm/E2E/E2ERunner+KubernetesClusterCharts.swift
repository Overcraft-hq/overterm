import AppKit
import Foundation

/// Stage M8 of docs/design/kubernetes/metrics.md (2.9, 4.6, 8): the
/// Overview's CPU by namespace (X3) and its nodes as small multiples (X4)
/// from Prometheus beside the cluster's charts, and `kubernetesCharts`
/// part 6 — a claim's fill forecast, its inodes toggled, and a volume with
/// no fixed size (EFS's 8 EiB): no share, no forecast, nothing asked for
/// one. Against the fake Prometheus, never a real cluster; reads only.
extension E2ERunner {
    /// X3 and X4 over the last hour, raw (the prometheus chart's profile):
    /// the namespaces ranked once by an instant topk at the range's end,
    /// then their lines; the nodes by their instance at a minute's step,
    /// against kube-state-metrics' allocatable, each measure's in its
    /// usage's query; a node's row opening its Metrics tab, `[` returning
    /// to the Overview.
    func prometheusOverviewParts(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, service: KubePrometheusService, scope: ObjectIdentifier?)
        async
    {
        let charts = KubeChartRegistry.shared
        func asked() -> [FakeKubeAPI.Request] { fake.requests.filter(\.isPrometheusQuery) }
        let byNamespace = page.namespacesChart
        check("X3 follows the namespace picked", byNamespace == .namespaces(["shop"]), "\(byNamespace)")
        check(
            "the CPU by namespace drawn, its top namespace by name",
            await eventually(15) { charts.chart("kubernetes.chart.cluster.namespaces.cpu", in: scope).map { $0.data.usage.map(\.id).contains("shop") && $0.plot != nil } == true },
            charts.lines(in: scope).joined(separator: "; "))
        let rankings = asked().filter { $0.query["query"]?.hasPrefix("topk(8, sum by (namespace)") == true }
        check("ranked with one instant query at the range's end", !rankings.isEmpty && rankings.allSatisfy { $0.path == service.queryPath && $0.query["time"] != nil }, "\(rankings.map(\.query))")
        check(
            "within the namespace picked", rankings.first?.query["query"]?.contains(#"namespace="shop""#) == true, rankings.first?.query["query"] ?? "")
        check(
            "the nodes read by their instance, a minute a cell",
            await eventually(15) {
                asked().contains { $0.path == service.rangePath && $0.query["step"] == "1m" && $0.query["query"]?.hasPrefix("label_replace(sum by (instance)") == true }
            }, "\(asked().compactMap { $0.query["query"] })")
        let strip = KubeClusterCharts.stripIdentifier("fake-node-1", .cpu)
        check(
            "the node's CPU strip from Prometheus: 750m of 4 cores",
            await eventually(15) {
                KubeHeatStripRegistry.shared.strip(strip, in: scope).map { !$0.sampled && abs(($0.now ?? 0) - 18.75) < 0.5 } == true
            }, KubeHeatStripRegistry.shared.lines(in: scope).joined(separator: "; "))
        check("said as Prometheus' over the hour", await shownText(15) { $0.contains("of allocatable in 1 min cells") } != nil)
        check("only the Service's two query paths", asked().allSatisfy { $0.path == service.rangePath || $0.path == service.queryPath })
        KubeHeatStripRegistry.shared.lines(in: scope).forEach { note("kubernetes \($0)") }
        // X4's click-through (metrics.md 2.9, 3.7): the node's Metrics tab, and `[` back to the Overview.
        page.openNodeMetrics("fake-node-1")
        check("a node's row opens the node", page.detail?.ref.name == "fake-node-1" && page.detail?.ref.kind.resource == "nodes", "\(String(describing: page.detail?.ref))")
        check("on its Metrics tab", page.detailTab == .metrics, "\(page.detailTab)")
        check("[ returns to the Overview", page.press("[") && page.detail == nil && page.section == .overview, "\(page.section)")
        check("] opens the node again", page.history.canGoForward && page.history.forward.last?.name == "fake-node-1")
        check(
            "the Overview's charts shown again",
            await eventually(15) { charts.chart("kubernetes.chart.cluster.namespaces.cpu", in: scope)?.plot != nil },
            charts.lines(in: scope).joined(separator: "; "))
    }

    /// Part 6 (metrics.md 8): a claim fills toward its capacity — the chip
    /// "full in ~2 d", the projection dotted —, its inodes read only while
    /// toggled; then a claim on EFS (`efs-pvc`): its usage alone, no %, no
    /// capacity line, no projection, said, and no forecast asked for it.
    func prometheusVolumeForecast(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, service: KubePrometheusService, scope: ObjectIdentifier?)
        async
    {
        let charts = KubeChartRegistry.shared
        func asked() -> [FakeKubeAPI.Request] { fake.requests.filter(\.isPrometheusQuery) }
        let claim = KubeChart.volume(namespace: "shop", claim: "data-db-0")
        check(
            "the claim fills: full in about two days",
            await eventually(15) {
                model.prometheus.charts[claim].flatMap { KubeVolumeForecast.chip(available: $0.totals[.volumeAvailable], rate: KubeVolumeForecast.rate($0)) }?.text
                    == "full in ~2 d"
            }, "\(model.prometheus.charts[claim]?.totals ?? [:])")
        check("drawn as a chip", await shownText(15) { $0.contains("full in ~2 d") } != nil)
        // V2: its inodes, only while toggled.
        fake.setPrometheusMatrix("kubelet_volume_stats_inodes_used{", [FakePromFixture.Line { _ in 0.4 }])
        defer { fake.clearPrometheusMatrix("kubelet_volume_stats_inodes_used{") }
        let inodes = KubeChart.volumeInodes(namespace: "shop", claim: "data-db-0")
        check("its inodes not read until shown", model.prometheus.charts[inodes] == nil && !asked().contains { $0.query["query"]?.contains("kubelet_volume_stats_inodes{") == true })
        page.volumeInodesShown = true
        check(
            "toggled: its inodes charted",
            await eventually(15) { charts.chart("kubernetes.chart.volume.shop.data-db-0.inodes", in: scope)?.data.usage.first?.points.last?.value == 0.4 },
            charts.lines(in: scope).joined(separator: "; "))
        page.volumeInodesShown = false
        check("toggled off: no longer read", await eventually(10) { model.prometheus.charts[inodes] == nil })

        // An EFS claim (efs-pvc): 8 EiB of capacity is no size at all.
        let efs = 9_223_372_036_854_775_807.0
        let labels = ["namespace": "shop", "persistentvolumeclaim": "shared-efs"]
        fake.setPrometheusSeries("kubelet_volume_stats_used_bytes", labels: labels, value: 3_221_225_472)
        fake.setPrometheusSeries("kubelet_volume_stats_capacity_bytes", labels: labels, value: efs)
        fake.setPrometheusSeries("kubelet_volume_stats_available_bytes", labels: labels, value: efs)
        fake.add(
            "persistentvolumeclaims", "shared-efs", namespace: "shop",
            values: ["Status": "Bound", "Volume": "pvc-efs", "Capacity": "5Gi", "Access Modes": "RWX", "StorageClass": "efs-sc"])
        guard let kind = model.discovery?.kind("pvc") else { return check("the claims' kind", false) }
        fake.forgetRequests()
        page.open(KubeObjectRef(context: "fake-dev", kind: kind, namespace: "shop", name: "shared-efs"), from: .list)
        page.detailTab = .overview
        let shared = KubeChart.volume(namespace: "shop", claim: "shared-efs")
        let id = "kubernetes.chart.volume.shop.shared-efs.used"
        check(
            "the EFS claim's usage charted alone: no capacity line, no projection",
            await eventually(15) { charts.chart(id, in: scope).map { !$0.data.usage.isEmpty && $0.data.references.isEmpty } == true },
            charts.lines(in: scope).joined(separator: "; "))
        check("no share, no forecast read", model.prometheus.charts[shared]?.totals.isEmpty == true)
        check(
            "no forecast asked for it",
            !asked().contains { ($0.query["query"] ?? "").contains("shared-efs") && (($0.query["query"] ?? "").contains("deriv(") || ($0.query["query"] ?? "").contains("predict_linear(")) },
            "\(asked().compactMap { $0.query["query"] })")
        check("said in a sentence", await shownText(15) { $0.contains("no fixed size") } != nil)
        page.closeDetail()
        let back = KubeObjectRef(context: "fake-dev", kind: kind, namespace: "shop", name: "data-db-0")
        page.open(back, from: .list)
        page.detailTab = .overview
        fake.delete("persistentvolumeclaims", "shared-efs", namespace: "shop")
        for metric in ["kubelet_volume_stats_used_bytes", "kubelet_volume_stats_capacity_bytes", "kubelet_volume_stats_available_bytes"] {
            fake.clearPrometheusSeries(metric, matching: ["persistentvolumeclaim": "shared-efs"])
        }
    }
}
