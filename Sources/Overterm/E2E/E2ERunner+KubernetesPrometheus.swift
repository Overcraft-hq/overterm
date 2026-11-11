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
            labels: ["app.kubernetes.io/name": "prometheus", "app.kubernetes.io/component": "server", "app.kubernetes.io/managed-by": "Helm"],
            fields: ["spec": ["ports": [["name": "http", "port": 80]]]])
        fake.servePrometheus(namespace: "monitoring", service: "prometheus-server", port: "80")
        // The prometheus chart without node-exporter: what the probe finds (stage M5).
        fake.setPrometheusProfile(.noNodeExporter)
        // On fake-node-1: the prometheus chart's cAdvisor names the node by instance (X4).
        let container = ["container": "app", "image": "nginx:1.27", "namespace": "shop", "pod": "web-8k2", "instance": "fake-node-1"]
        fake.setPrometheusSeries("container_cpu_usage_seconds_total", labels: container, value: 0.75)
        fake.setPrometheusSeries("container_memory_working_set_bytes", labels: container, value: 96 * 1_048_576)
        let ksm = ["namespace": "shop", "pod": "web-8k2", "container": "app", "node": "fake-node-1"]
        fake.setPrometheusSeries("kube_pod_container_resource_requests", labels: ksm.merging(["resource": "cpu"]) { $1 }, value: 2)
        fake.setPrometheusSeries("kube_pod_container_resource_limits", labels: ksm.merging(["resource": "cpu"]) { $1 }, value: 3)
        fake.setPrometheusSeries("kube_node_status_allocatable", labels: ["resource": "cpu", "node": "fake-node-1"], value: 4)
        fake.setPrometheusSeries("kube_pod_container_resource_requests", labels: ksm.merging(["resource": "memory"]) { $1 }, value: 1_073_741_824)
        fake.setPrometheusSeries("kube_pod_status_phase", labels: ["namespace": "shop", "pod": "web-8k2", "phase": "Running"], value: 1)
        // A finished Job's pod kube-state-metrics still holds: its requests aren't counted.
        let done = ["namespace": "shop", "pod": "migrate-x7", "container": "job", "node": "fake-node-1"]
        fake.setPrometheusSeries("kube_pod_container_resource_requests", labels: done.merging(["resource": "cpu"]) { $1 }, value: 2)
        fake.setPrometheusSeries("kube_pod_status_phase", labels: ["namespace": "shop", "pod": "migrate-x7", "phase": "Succeeded"], value: 1)
        fake.setPrometheusSeries("kube_node_status_allocatable", labels: ["resource": "memory", "node": "fake-node-1"], value: 8_589_934_592)
        fake.setPrometheusSeries("kube_node_status_capacity", labels: ["resource": "cpu", "node": "fake-node-1"], value: 4)
        fake.setPrometheusSeries("kube_node_status_capacity", labels: ["resource": "memory", "node": "fake-node-1"], value: 8_589_934_592)
        // X3's ranking, a topk the fake doesn't read.
        fake.setPrometheusMatrix("topk(8, sum by (namespace)", [FakePromFixture.Line(["namespace": "shop"]) { _ in 0.75 }])
        defer { fake.clearPrometheusMatrix("topk(8, sum by (namespace)") }
        fake.setPrometheusSeries("kubelet_volume_stats_used_bytes", labels: ["namespace": "shop", "persistentvolumeclaim": "data-db-0"], value: 2_147_483_648)
        fake.setPrometheusSeries(
            "kubelet_volume_stats_capacity_bytes", labels: ["namespace": "shop", "persistentvolumeclaim": "data-db-0"], value: 10_737_418_240)
        // V1's forecast (M8): 8 GiB available, filling 4 GiB a day — fixtures, the fake reads no deriv.
        fake.setPrometheusSeries(
            "kubelet_volume_stats_available_bytes", labels: ["namespace": "shop", "persistentvolumeclaim": "data-db-0"], value: 8_589_934_592)
        fake.setPrometheusMatrix("deriv(", [FakePromFixture.Line { _ in 4_294_967_296 / 86400 }])
        defer { fake.clearPrometheusMatrix("deriv(") }
        fake.add(
            "persistentvolumeclaims", "data-db-0", namespace: "shop",
            values: ["Status": "Bound", "Volume": "pvc-1234", "Capacity": "10Gi", "Access Modes": "RWO", "StorageClass": "standard"])
        Settings.shared.set("kubernetes.contexts", nil)
        // Earlier scenarios' probes (kubernetesCharts' over Prometheus) aren't this one's.
        let probesBefore = model.prometheus.probes
        if model.selectedName != "fake-dev" { model.select("fake-dev") }
        model.setScope(.namespace("shop"))
        check("fake-dev isn't opted in yet", await eventually(10) { model.selected?.settings.metrics == nil && !page.prometheusOn })

        // Not opted in: the Overview's chart is what was sampled while shown, no picker, no Prometheus asked.
        fake.forgetRequests()
        check("1 is the Overview", page.press("1") && page.section == .overview)
        // Said once two samples are kept, 15 s apart (`KubeUsageRing.span`):
        // shown just now, the second comes at 15 s — read in a full run a
        // moment after its 15 s were up. Given two intervals.
        check("its usage said as sampled while shown", await shownText(35) { $0.contains("sampled while shown") } != nil)
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
        check(
            "active pods' requests against allocatable", cluster?.share(.cpuRequests, of: .cpuAllocatable)?.percent == 50,
            "\(String(describing: cluster?.totals))")
        check("drawn, with the range and where it came from", await shownText(15) { $0.contains("The last 1h, from Prometheus monitoring/prometheus-server:80") } != nil)
        // Probed once for the context: what exists, the duplicates, the scrape — instant queries.
        let probes = prometheusAsked().filter { $0.query["query"]?.contains("count by (__name__)") == true }
        check("probed once", probes.count == 1 && model.prometheus.probes == probesBefore + 1, "\(probes.count) \(model.prometheus.probes - probesBefore)")
        check(
            "its scrape the cAdvisor job's, a minute",
            model.prometheus.profile?.scrape == 60 && prometheusAsked().contains { $0.query["query"] == KubePromProfile.scrapeQuery(job: "kubernetes-nodes-cadvisor") })
        check("the cluster read raw, named", model.prometheus.charts[.cluster]?.caption == "raw cAdvisor (≤ 6h) · scrape 1m", "\(model.prometheus.charts[.cluster]?.caption ?? "")")
        check(
            "the requests and limits as shares of allocatable",
            cluster.map { KubeClusterCharts.chips($0, cpu: true).map(\.text) } == ["requests 50% of allocatable", "limits 75% of allocatable"],
            "\(cluster.map { KubeClusterCharts.chips($0, cpu: true) } ?? [])")
        check("drawn as chips", await shownText(15) { $0.contains("requests 50% of allocatable") } != nil)
        // Each measure one chart, its plot built and drawn in one Canvas, what it is measured against its reference lines.
        let charts = KubeChartRegistry.shared
        let scope = app.theme.map(ObjectIdentifier.init)
        let cpuID = "kubernetes.chart.cluster.cpu"
        let memoryID = "kubernetes.chart.cluster.memory"
        check(
            "the cluster's CPU and memory charts drawn",
            await eventually(15) { [cpuID, memoryID].allSatisfy { charts.chart($0, in: scope)?.plot != nil } },
            charts.lines(in: scope).joined(separator: "; "))
        let cpuChart = charts.chart(cpuID, in: scope)
        check(
            "with active requests, limits, allocatable and capacity as lines", cpuChart?.data.references.map(\.role) == [.request, .limit, .allocatable, .capacity],
            charts.lines(in: scope).joined(separator: "; "))
        check("the axis reaching the highest line", (cpuChart?.plot?.top ?? 0) >= 4, "\(cpuChart?.plot?.top ?? 0)")
        check("drawn", KubeChartDraws.shared.of(cpuID, in: scope).series > 0)
        if let last = cpuChart?.data.usage.first?.points.last {
            let tip = charts.tooltip(cpuID, in: scope, at: last.time)
            check("its tooltip at the last point: the line, then the four", tip?.rows.first?.name == "CPU" && tip?.rows.count == 5, "\(tip?.rows ?? [])")
            check("the lines with the usage's share", tip?.rows.contains { $0.name == "allocatable" && $0.value.hasSuffix("· 19%") } == true, "\(tip?.rows ?? [])")
        }
        charts.lines(in: scope).forEach { note("kubernetes \($0)") }
        check("a range picker", await eventually(15) { pickerShown() })
        check("the sampled sparkline gone", await shownText(15) { $0.caseInsensitiveCompare("Usage over time") == .orderedSame } != nil)
        let ranges = prometheusAsked().filter { $0.path == service.rangePath }
        check("asked as query_range, its start, end and step", ranges.contains { $0.query["step"] == "30s" && $0.query["start"] != nil && $0.query["end"] != nil })
        check("a rate over four scrapes", ranges.contains { $0.query["query"]?.contains("[4m]") == true }, "\(ranges.compactMap { $0.query["query"] })")
        check("every query given 20 s", prometheusAsked().allSatisfy { $0.query["timeout"] == "20s" })
        check(
            "only that Service's two query paths", prometheusAsked().allSatisfy { $0.path == service.rangePath || $0.path == service.queryPath },
            "\(prometheusAsked().map(\.path))")
        if realProxy {
            let connected = await model.proxies.proxyLabels
            check("through a second proxy of fake-dev's own", connected.contains("fake-dev (prometheus)"), "\(connected)")
        }
        await prometheusOverviewParts(model, page, fake, service: service, scope: scope)
        await sharedCrosshair(model, scope: scope, cpu: cpuID, memory: memoryID)
        // 24h: the cluster's raw lines aren't asked; why is said, and 6h offered.
        fake.forgetRequests()
        page.chartRange = .day
        check(
            "24h picked: the cluster's lines refused, its totals read",
            await eventually(15) { model.prometheus.charts[.cluster]?.range == .day && model.prometheus.charts[.cluster]?.read != nil })
        check("no query_range across the cluster over 24h", !prometheusAsked().contains { $0.path == service.rangePath }, "\(prometheusAsked().map(\.query))")
        check("and said", await shownText(15) { $0.contains("Raw container metrics") } != nil)
        check("the requests still said", await shownText(15) { $0.contains("requests 50% of allocatable") } != nil)
        check(
            "by namespace and the nodes refused raw too, said",
            await eventually(15) { model.prometheus.charts[page.namespacesChart]?.refused != nil && model.prometheus.charts[.nodes]?.refused != nil })
        check("the nodes' last 15 minutes sampled instead", await shownText(15) { $0.contains("Nodes, the last 15 min") } != nil)
        // The button's own action: pressed where it is drawn, by a click
        // queued to the app's own window (`click(at:)`) — nothing reaches
        // the screen's focus. SwiftUI builds no accessibility tree in
        // process until an assistive client asks, so there is no element
        // to press.
        fake.forgetRequests()
        let showRaw = await shownText(15) { $0.contains("Show 6h") }
        check("Show 6h is drawn as a button", showRaw != nil)
        if let showRaw { await click(at: CGPoint(x: showRaw.frame.midX, y: showRaw.frame.midY)) }
        check("and the range is 6h", await eventually(15) { page.chartRange == .sixHours }, "\(page.chartRange)")
        check(
            "6h: the cluster's lines asked with its step",
            await eventually(15) {
                model.prometheus.charts[.cluster]?.range == .sixHours
                    && prometheusAsked().contains { $0.path == service.rangePath && $0.query["step"] == "3m" }
            }, "\(prometheusAsked().map(\.query))")
        check("and drawn", await shownText(15) { $0.contains("The last 6h, from Prometheus") } != nil)
        await prometheusTiers(model, page, fake, service: service)
        page.chartRange = .hour

        // A pod's detail.
        check("2 is Workloads", page.press("2") && page.section == .workloads)
        let pod = KubeRowID(namespace: "shop", name: "web-8k2")
        guard await showKubernetesKind(model, page, "po", row: pod) else { return }
        // Its Metrics tab, over Prometheus (M6): the Overview no longer charts it.
        setTabFixtures(fake)
        page.open(KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "web-8k2"), from: .list)
        page.showTab(.metrics)
        page.pickMetricsRange(.hour)
        defer {
            page.metricsRange = .live
            page.metricsRangePicked = false
        }
        func podReading() -> KubeTabReading? {
            model.prometheus.tabs.values.first { reading in
                if case .pod(_, "web-8k2", _, _) = reading.request.subject { return reading.request.span == .range(.hour) }
                return false
            }
        }
        check(
            "a pod's Metrics tab reads it from Prometheus over 1h",
            await eventually(15) { podReading()?.results["cpu"]?.first?.points.last?.value == 0.75 }, "\(model.prometheus.tabs.values.map(\.results.keys))")
        let podCPU = "kubernetes.chart.pod.shop.web-8k2.cpu"
        check(
            "its CPU drawn from Prometheus",
            await eventually(10) { charts.chart(podCPU, in: scope).map { $0.data.source == "Prometheus" && $0.plot != nil } == true },
            charts.lines(in: scope).joined(separator: "; "))
        check("the Overview's chart no longer read", model.prometheus.charts[.cluster] == nil)
        page.showTab(.overview)
        check("its Overview asks Prometheus nothing", await eventually(10) { podReading() == nil && model.prometheus.charts.isEmpty })
        check("and charts nothing of Prometheus", await shownText(2) { $0.contains("from Prometheus monitoring") } == nil)
        clearTabFixtures(fake)
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
            check(
                "its capacity a line, its fill forecast dotted beside",
                await eventually(10) { charts.chart("kubernetes.chart.volume.shop.data-db-0.used", in: scope)?.data.references.map(\.role) == [.capacity, .projection] },
                charts.lines(in: scope).joined(separator: "; "))
            await prometheusVolumeForecast(model, page, fake, service: service, scope: scope)
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
        await prometheusAgentMode(model, page, fake)
        // Part 13: the Pods list's shares — Prometheus off for a moment there, so found again after.
        await prometheusShares(model, page, fake, service: service)
        _ = await showKubernetesKind(model, page, "pvc", row: claim)
        check("Prometheus found again", await eventually(15) { model.prometheus.state == .found(service, .helm) }, "\(model.prometheus.state)")

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

extension E2ERunner {
    /// The crosshair shared (metrics.md, 3.1), on the Overview as it is
    /// drawn: the cursor moved over the CPU chart, as its hover moves it,
    /// the memory chart beside it draws it too — its overlay again, never
    /// its series, no tooltip of its own — and the view holding the cursor
    /// (`KubePrometheusChartView`) runs no body. The readings are held off
    /// meanwhile, so nothing else redraws them.
    func sharedCrosshair(_ model: KubernetesModel, scope: ObjectIdentifier?, cpu cpuID: String, memory memoryID: String) async {
        let charts = KubeChartRegistry.shared
        guard let scope, let cpu = charts.chart(cpuID, in: scope), let memory = charts.chart(memoryID, in: scope),
            let first = cpu.data.usage.first?.points.first?.time
        else { return check("the Overview's two charts, to hover", false, charts.lines(in: scope).joined(separator: "; ")) }
        check("one cursor for the Overview's charts", memory.cursor === cpu.cursor)
        let interval = model.prometheus.interval
        let metricsInterval = model.metrics.interval
        model.prometheus.interval = .seconds(60)
        model.metrics.interval = .seconds(60)
        defer {
            cpu.cursor.leave(cpuID)
            model.prometheus.interval = interval
            model.metrics.interval = metricsInterval
        }
        // The poll in flight lands, then the next waits a minute.
        let read = model.prometheus.charts[.cluster]?.read
        _ = await eventually(5) { model.prometheus.charts[.cluster]?.read != read }
        await pause(0.8)
        let held = model.prometheus.charts[.cluster]?.read
        let draws = KubeChartDraws.shared
        let container = "kubernetes.overview.prometheus"
        let before = (cpu: draws.of(cpuID, in: scope), memory: draws.of(memoryID, in: scope), container: draws.of(container, in: scope))
        for move in 0..<10 {
            cpu.cursor.move(to: first.addingTimeInterval(Double(10 + move * 5) * cpu.data.step), owner: cpuID)
            await pause(0.05)
        }
        await pause(0.3)
        let after = (cpu: draws.of(cpuID, in: scope), memory: draws.of(memoryID, in: scope), container: draws.of(container, in: scope))
        check("no reading landed meanwhile", model.prometheus.charts[.cluster]?.read == held)
        check("hovering CPU: its overlay and tooltip drawn", after.cpu.overlay > before.cpu.overlay && after.cpu.tooltip > before.cpu.tooltip, "\(before.cpu) → \(after.cpu)")
        check("the memory chart draws the crosshair too", after.memory.overlay > before.memory.overlay, "\(before.memory) → \(after.memory)")
        check("with no tooltip of its own", after.memory.tooltip == before.memory.tooltip, "\(before.memory) → \(after.memory)")
        check(
            "neither chart's series drawn again", after.cpu.series == before.cpu.series && after.memory.series == before.memory.series,
            "cpu \(before.cpu) → \(after.cpu); memory \(before.memory) → \(after.memory)")
        check("the view holding the cursor runs no body", after.container.container == before.container.container, "\(after.container.container - before.container.container) bodies")
    }
}

extension E2ERunner {
    /// Stage M5 (metrics.md, 4.3, 4.4): kube-prometheus-stack's profile —
    /// the mixin's rules, a 30 s scrape, kubelet's cAdvisor at two paths —
    /// probed again (as an hour passing): the Overview's 24h, refused raw a
    /// moment ago, is drawn from the recording rules and says so.
    func prometheusTiers(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, service: KubePrometheusService) async {
        fake.setPrometheusProfile(.kubePrometheusStack)
        let node = ["instance": "10.0.0.1:9100"]
        fake.setPrometheusSeries(KubePromProfile.nodeCPURule, labels: node, value: 0.5)
        fake.setPrometheusSeries(KubePromProfile.nodeCPUCountRule, labels: node, value: 4)
        fake.setPrometheusSeries(KubePromProfile.nodeMemoryRule, labels: node, value: 0.25)
        fake.setPrometheusSeries("node_memory_MemTotal_bytes", labels: node, value: 8_589_934_592)
        // X4 from the per-container rules past 5-minute steps (max_over_time, which the fake doesn't read):
        // a query a measure, its allocatable in it, the arms tagged.
        fake.setPrometheusMatrix(
            "max_over_time(node_namespace_pod_container:",
            ["cpu", "memory", "cpuAllocatable", "memoryAllocatable"].map { tag in FakePromFixture.Line(["node": "fake-node-1", "overterm_s": tag]) { _ in 1 } })
        defer {
            fake.clearPrometheusMatrix("max_over_time(node_namespace_pod_container:")
            fake.setPrometheusProfile(.noNodeExporter)
            model.prometheus.forgetProfile()
        }
        fake.forgetRequests()
        model.prometheus.forgetProfile()
        page.chartRange = .day
        check(
            "24h with recording rules: drawn",
            await eventually(15) {
                let cluster = model.prometheus.charts[.cluster]
                return cluster?.range == .day && cluster?.tier == .rules && cluster?.series[.cpu]?.isEmpty == false
            }, "\(String(describing: model.prometheus.charts[.cluster]?.tier)) \(model.prometheus.charts[.cluster]?.refused ?? "")")
        check("probed again", model.prometheus.profile?.scrape == 30 && model.prometheus.profile?.cadvisorPath == "/metrics/cadvisor")
        check("the rules read over the range", prometheusAskedOf(fake).contains { $0.path == service.rangePath && $0.query["query"]?.hasPrefix("label_replace(\(KubePromQL.ruleClusterCPU),") == true })
        check("the caption names them", await shownText(15) { $0.contains("recording rules") } != nil)
        check("the lines' CPU: half of four cores", model.prometheus.charts[.cluster]?.series[.cpu]?.last?.value == 2)
        check(
            "the nodes over 24h from the per-container rules, 24 minutes a cell",
            await eventually(15) { model.prometheus.charts[.nodes].map { $0.range == .day && $0.tier == .rules && $0.parts[.cpu]?["fake-node-1"]?.isEmpty == false } == true },
            "\(String(describing: model.prometheus.charts[.nodes]?.problem)) \(model.prometheus.charts[.nodes]?.refused ?? "")")
        check(
            "asked at 24m", prometheusAskedOf(fake).contains { $0.path == service.rangePath && $0.query["step"] == "24m" && $0.query["query"]?.hasPrefix("label_replace(sum by (node)") == true })
        check(
            "only the Service's two query paths",
            prometheusAskedOf(fake).allSatisfy { $0.path == service.rangePath || $0.path == service.queryPath })
    }

    /// Prometheus in agent mode (metrics.md, 8's part 7): the plain
    /// sentence on the Overview, and nothing retried within the scenario.
    func prometheusAgentMode(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        let section = page.section
        check("1 is the Overview", page.press("1") && page.section == .overview)
        fake.setPrometheusProfile(.agentMode)
        fake.forgetRequests()
        model.prometheus.forgetProfile()
        defer {
            fake.setPrometheusProfile(.noNodeExporter)
            model.prometheus.forgetProfile()
        }
        check("agent mode said", await eventually(15) { model.prometheus.charts[.cluster]?.unavailable?.contains("agent mode") == true })
        check("drawn as a sentence", await shownText(15) { $0.contains("only forwards metrics") } != nil)
        await pause(2)
        check("asked once, not again", prometheusAskedOf(fake).count == 1, "\(prometheusAskedOf(fake).compactMap { $0.query["query"] })")
        if section == .workloads { _ = page.press("2") }
    }

    func prometheusAskedOf(_ fake: FakeKubeAPI) -> [FakeKubeAPI.Request] { fake.requests.filter(\.isPrometheusQuery) }
}
