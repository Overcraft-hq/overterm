import AppKit
import Foundation

/// Stage 4's Prometheus (docs/design/kubernetes/analysis.md, 2.1, 2.11,
/// 2.17, Section 4), against the fake API server and its fake Prometheus
/// behind a Service's proxy path, never a real cluster: before `fake-dev`
/// opts in, the Overview has no range picker and asks no Prometheus —
/// its chart covers the time shown and says so; with `metrics: prometheus`
/// in its entry, the Service is found by the Helm chart's labels, the
/// Overview charts the cluster over the range picked (query_range's start,
/// end and step) with requests and limits against allocatable, a pod's and
/// a claim's detail chart theirs, the PVC list has a Used column — through
/// a second proxy that accepts only that Service's query paths (the real
/// kubectl when installed). Hidden, nothing is read and the metrics proxy
/// closes; `fake-prod`, not opted in, shows no picker. Reads only.
extension E2ERunner {
    func kubernetesPrometheus(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, realProxy: Bool) async {
        // Left as found: what follows toggles the page.
        let wasShowing = app.store.showingOverlay == .kubernetes
        if !wasShowing { app.showKubernetesPage() }
        defer { if !wasShowing, app.store.showingOverlay == .kubernetes { app.toggleKubernetesPage(nil) } }
        let interval = model.prometheus.interval
        model.prometheus.interval = .milliseconds(500)
        let metricsInterval = model.metrics.interval
        model.metrics.interval = .milliseconds(500)
        defer {
            model.metrics.interval = metricsInterval
            model.prometheus.interval = interval
            model.prometheus.range = .hour
            Settings.shared.set("kubernetes.contexts", nil)
        }
        func prometheusAsked() -> [FakeKubeAPI.Request] { fake.requests.filter(\.isPrometheusQuery) }
        // The range picker itself (`KubeChartRangePicker`): its segmented control, by identifier or by its ranges.
        func pickerShown() -> Bool {
            Self.find(NSSegmentedControl.self, in: app.kubernetesView) { control in
                control.accessibilityIdentifier() == "kubernetes.chart.range"
                    || (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" } == KubeChartRange.allCases.map(\.title)
            } != nil
        }
        func pickerStaysAway() async -> Bool {
            for _ in 0..<5 {
                if pickerShown() { return false }
                await pause(0.2)
            }
            return true
        }
        func servicesAsked() -> [FakeKubeAPI.Request] {
            fake.requests.filter { $0.path == "/api/v1/services" || $0.path.hasPrefix("/api/v1/namespaces/lens-metrics") }
        }
        let service = KubePrometheusService(namespace: "monitoring", name: "prometheus-server", port: "80")!
        fake.addNamespace("monitoring")
        fake.add(
            "services", "prometheus-server", namespace: "monitoring",
            values: ["Type": "ClusterIP", "Cluster-IP": "10.96.0.90", "External-IP": "<none>", "Port(s)": "80/TCP"],
            labels: ["app": "prometheus", "component": "server", "heritage": "Helm"], fields: ["spec": ["ports": [["name": "http", "port": 80]]]])
        fake.servePrometheus(namespace: "monitoring", service: "prometheus-server", port: "80")
        let container = ["container": "app", "image": "nginx:1.27", "namespace": "shop", "pod": "web-8k2"]
        fake.setPrometheusSeries("container_cpu_usage_seconds_total", labels: container, value: 0.75)
        fake.setPrometheusSeries("container_memory_working_set_bytes", labels: container, value: 96 * 1_048_576)
        fake.setPrometheusSeries("kube_pod_container_resource_requests", labels: ["resource": "cpu", "pod": "web-8k2"], value: 2)
        fake.setPrometheusSeries("kube_pod_container_resource_limits", labels: ["resource": "cpu", "pod": "web-8k2"], value: 3)
        fake.setPrometheusSeries("kube_node_status_allocatable", labels: ["resource": "cpu", "node": "fake-node-1"], value: 4)
        fake.setPrometheusSeries("kube_pod_container_resource_requests", labels: ["resource": "memory", "pod": "web-8k2"], value: 1_073_741_824)
        fake.setPrometheusSeries("kube_node_status_allocatable", labels: ["resource": "memory", "node": "fake-node-1"], value: 8_589_934_592)
        fake.setPrometheusSeries("kubelet_volume_stats_used_bytes", labels: ["namespace": "shop", "persistentvolumeclaim": "data-db-0"], value: 2_147_483_648)
        fake.setPrometheusSeries(
            "kubelet_volume_stats_capacity_bytes", labels: ["namespace": "shop", "persistentvolumeclaim": "data-db-0"], value: 10_737_418_240)
        fake.add(
            "persistentvolumeclaims", "data-db-0", namespace: "shop",
            values: ["Status": "Bound", "Volume": "pvc-1234", "Capacity": "10Gi", "Access Modes": "RWO", "StorageClass": "standard"])
        Settings.shared.set("kubernetes.contexts", nil)
        if model.selectedName != "fake-dev" { model.select("fake-dev") }
        model.setScope(.namespace("shop"))
        check("fake-dev isn't opted in yet", await eventually(10) { model.selected?.settings.metrics == nil && !page.prometheusOn })

        // Not opted in: the Overview's chart is what was sampled while shown, no picker, no Prometheus asked.
        fake.forgetRequests()
        check("1 is the Overview", page.press("1") && page.section == .overview)
        check("its usage said as sampled while shown", await shownText(15) { $0.contains("sampled while shown") } != nil)
        await pause(1)
        check("no range to pick", await pickerStaysAway())
        check("no Prometheus chart", await shownText(1) { $0.contains("from Prometheus") || $0.caseInsensitiveCompare("Usage over time") == .orderedSame } == nil)
        check("and Prometheus is neither looked for nor asked", prometheusAsked().isEmpty && servicesAsked().isEmpty, "\(prometheusAsked()) \(servicesAsked())")

        // Opted in.
        Settings.shared.set("kubernetes.contexts", .entries(["fake-dev": ["metrics": .string("prometheus")]]))
        check("fake-dev opts in", await eventually(10) { page.prometheusOn })
        check(
            "found by the Helm chart's labels", await eventually(15) { model.prometheus.state == .found(service, .helm) },
            "\(model.prometheus.state)")
        check("the Overview's chart read over the range", await eventually(15) { model.prometheus.charts[.cluster]?.read != nil })
        let cluster = model.prometheus.charts[.cluster]
        check("the cluster's CPU and memory over the last hour", (cluster?.series[.cpu]?.count ?? 0) > 100 && cluster?.series[.memory]?.last?.value == 96 * 1_048_576)
        check("requests against allocatable", cluster?.share(.cpuRequests, of: .cpuAllocatable)?.percent == 50, "\(String(describing: cluster?.totals))")
        check("drawn, with the range and where it came from", await shownText(15) { $0.contains("The last 1h, from Prometheus monitoring/prometheus-server:80") } != nil)
        check("the requests and limits drawn", await shownText(15) { $0.contains("2000m of 4000m") } != nil)
        check("a range picker", await eventually(15) { pickerShown() })
        check("the sampled sparkline gone", await shownText(15) { $0.caseInsensitiveCompare("Usage over time") == .orderedSame } != nil)
        let ranges = prometheusAsked().filter { $0.path == service.rangePath }
        check("asked as query_range, its start, end and step", ranges.contains { $0.query["step"] == "30s" && $0.query["start"] != nil && $0.query["end"] != nil })
        check(
            "only that Service's two query paths", prometheusAsked().allSatisfy { $0.path == service.rangePath || $0.path == service.queryPath },
            "\(prometheusAsked().map(\.path))")
        if realProxy {
            let connected = await model.proxies.proxyLabels
            check("through a second proxy of fake-dev's own", connected.contains("fake-dev (prometheus)"), "\(connected)")
        }
        page.chartRange = .day
        check("24h picked: asked again with its step", await eventually(15) { model.prometheus.charts[.cluster]?.range == .day && prometheusAsked().contains { $0.query["step"] == "12m" } })
        check("and said", await shownText(15) { $0.contains("The last 24h, from Prometheus") } != nil)
        page.chartRange = .hour

        // A pod's detail.
        check("2 is Workloads", page.press("2") && page.section == .workloads)
        let pod = KubeRowID(namespace: "shop", name: "web-8k2")
        guard await showKubernetesKind(model, page, "po", row: pod) else { return }
        page.open(KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "web-8k2"), from: .list)
        page.detailTab = .overview
        let podChart = KubeChart.pod(namespace: "shop", name: "web-8k2")
        check("a pod's detail charts the pod", await eventually(15) { model.prometheus.charts[podChart]?.series[.cpu]?.last?.value == 0.75 })
        let podDrawn = await shownText(15) { $0.contains("750m") } != nil
        let podShown = podDrawn ? "" : (await readWindow()).map(\.text).joined(separator: " | ")
        check("the pod's chart drawn", podDrawn, podShown)
        check("the Overview's chart no longer read", model.prometheus.charts[.cluster] == nil)
        page.closeDetail()

        // The PVC list's Used column, and a claim's detail.
        let claim = KubeRowID(namespace: "shop", name: "data-db-0")
        guard await showKubernetesKind(model, page, "pvc", row: claim) else { return }
        check("the PVC list has a Used column", page.columns.map(\.title).contains("Used"), "\(page.columns.map(\.title))")
        check(
            "the claim's usage against its capacity",
            await eventually(15) { page.rows.first { $0.row.id == claim }.map { page.volumeUsage(of: $0).text } == "2.0Gi of 10Gi (20%)" })
        // OCR reads that 0 as an O now and then: the digit isn't what is checked here, the cell drawn is.
        let cellDrawn = await shownText(15) { $0.replacingOccurrences(of: "O", with: "0").contains("2.0Gi of 10Gi") } != nil
        let cellShown = cellDrawn ? "" : (await readWindow()).map(\.text).joined(separator: " | ")
        check("the Used cell drawn", cellDrawn, cellShown)
        if let kind = model.discovery?.kind("pvc") {
            page.open(KubeObjectRef(context: "fake-dev", kind: kind, namespace: "shop", name: "data-db-0"), from: .list)
            page.detailTab = .overview
            let volume = KubeChart.volume(namespace: "shop", claim: "data-db-0")
            check("a claim's detail charts its volume", await eventually(15) { model.prometheus.charts[volume]?.series[.volumeCapacity]?.last?.value == 10_737_418_240 })
            let claimDrawn = await shownText(15) { $0.contains("of 10Gi") } != nil
            let claimShown = claimDrawn ? "" : (await readWindow()).map(\.text).joined(separator: " | ")
            check("the claim's chart drawn", claimDrawn, claimShown)
            page.closeDetail()
        }

        // Hidden: nothing read, the metrics proxy closed.
        app.toggleKubernetesPage(nil)
        check("hidden, nothing is read", await eventually(5) { !model.prometheus.isPolling && model.prometheus.charts.isEmpty })
        if realProxy {
            var closed = false
            for _ in 0..<50 where !closed {
                closed = await !model.proxies.proxyLabels.contains("fake-dev (prometheus)")
                if !closed { await pause(0.2) }
            }
            check("and the metrics proxy closes", closed)
        }
        fake.forgetRequests()
        await pause(1.5)
        check("Prometheus isn't asked", prometheusAsked().isEmpty, "\(prometheusAsked())")
        let detections = model.prometheus.detections
        app.toggleKubernetesPage(nil)
        check(
            "shown again, read again", await eventually(15) { model.prometheus.volumes?.read != nil || model.prometheus.charts.values.contains { $0.read != nil } })
        check("without looking for Prometheus again", model.prometheus.detections == detections && servicesAsked().isEmpty, "\(servicesAsked())")

        // A context without Prometheus: no picker.
        model.select("fake-prod")
        check("fake-prod shows", await eventually(10) { model.selectedName == "fake-prod" && !page.prometheusOn })
        check("1 is its Overview", page.press("1") && page.section == .overview)
        fake.forgetRequests()
        await pause(1.5)
        check("without Prometheus, no picker", await pickerStaysAway())
        check("and no chart of it", await shownText(1) { $0.contains("from Prometheus") || $0.caseInsensitiveCompare("Usage over time") == .orderedSame } == nil)
        check("nothing asked of Prometheus there", prometheusAsked().isEmpty && servicesAsked().isEmpty, "\(prometheusAsked()) \(servicesAsked())")

        // Opted in where none is found: looked for once, said, and still no picker.
        fake.delete("services", "prometheus-server", namespace: "monitoring")
        Settings.shared.set(
            "kubernetes.contexts", .entries(["fake-dev": ["metrics": .string("prometheus")], "fake-prod": ["metrics": .string("prometheus")]]))
        check("fake-prod opts in", await eventually(10) { page.prometheusOn })
        check(
            "none found there, and said", await eventually(15) { model.prometheus.state == .unavailable(KubePrometheusState.notFound) },
            "\(model.prometheus.state)")
        check("opted in but not found, no picker", await pickerStaysAway())
        check("nothing queried", prometheusAsked().isEmpty, "\(prometheusAsked())")
        check("2 is Workloads again", page.press("2"))
        model.select("fake-dev")
        check("and nothing written", fake.writes.isEmpty, "\(fake.writes)")
    }
}
