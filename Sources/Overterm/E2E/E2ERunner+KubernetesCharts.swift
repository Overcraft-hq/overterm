import AppKit
import Foundation
import SwiftUI

/// `kubernetesCharts` (docs/design/kubernetes/metrics.md, 8; stage M3a's
/// parts 1, 3 and 12), against `fake-dev` with metrics-server and no
/// Prometheus: a pod's detail, `m` — Live, sampled, its containers' CPU and
/// memory against the spec's request and limit, the OOMKill its
/// `lastState` says marked, the caption saying where the numbers come
/// from; `.` and `,` over Live and 6h; the crosshair held at a point, the
/// tooltip said, no series layer and no tab body drawn again; the marker's
/// click opening the previous log, "Logs from Here" asking `sinceTime`.
/// Hidden, nothing is read. Reads only.
extension E2ERunner {
    func kubernetesCharts(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        let wasShowing = app.store.showingOverlay == .kubernetes
        if !wasShowing { app.toggleKubernetesPage(nil) }
        defer { if !wasShowing, app.store.showingOverlay == .kubernetes { app.toggleKubernetesPage(nil) } }
        let interval = model.metrics.interval
        model.metrics.interval = .milliseconds(500)
        defer { model.metrics.interval = interval }
        let scope = app.theme.map(ObjectIdentifier.init)
        let charts = KubeChartRegistry.shared
        let name = "charts-api-1"
        let own = "/apis/metrics.k8s.io/v1beta1/namespaces/shop/pods/\(name)"
        let finished = Date().addingTimeInterval(-120)
        fake.metricsServer = true
        fake.addPod(
            name, namespace: "shop",
            FakeKubeAPI.Pod(
                ready: 2, containers: 2, restarts: 2,
                resources: ["app": ["requests": ["cpu": "250m", "memory": "64Mi"], "limits": ["cpu": "1", "memory": "128Mi"]]], lastReason: "OOMKilled",
                lastExitCode: 137, lastFinished: finished))
        fake.setPodMetrics(name, namespace: "shop", [("app", "120m", "100Mi"), ("sidecar-1", "5m", "10Mi")])
        if model.selectedName != "fake-dev" { model.select("fake-dev") }
        model.setScope(.namespace("shop"))
        page.showKind(.pods)
        page.filter = ""
        page.applySelector()
        model.rediscover()
        check(
            "the chart's pod listed, metrics-server served",
            await eventually(15) { model.rows[KubeRowID(namespace: "shop", name: name)] != nil && model.metrics.availability == .served })

        // 1. `m`: Live, sampled, two charts a container.
        page.selection = ["shop/\(name)"]
        page.metricsRange = .live
        check("m opens the pod's Metrics tab", page.press("m") && page.detailTab == .metrics && page.detail?.ref.name == name)
        let memoryID = "kubernetes.chart.container.shop.\(name).app.memory"
        let cpuID = "kubernetes.chart.container.shop.\(name).app.cpu"
        // The app container's two charts, under the pod's: scrolled to.
        await revealChart(cpuID, scope: scope, top: true)
        await revealChart(memoryID, scope: scope)
        let drawn = await eventually(20) {
            guard let memory = charts.chart(memoryID, in: scope), memory.plot != nil else { return false }
            return (memory.data.usage.first?.points.count ?? 0) >= 2
        }
        check("its app container's memory charted from two samples or more", drawn, charts.lines(in: scope).joined(separator: "; "))
        check("asked of the pod's own PodMetrics", fake.requests.contains { $0.path == own })
        let dump = charts.lines(in: scope).first { $0.contains(memoryID) } ?? ""
        note("kubernetes charts dump: \(dump)")
        check("the dump: a request and a limit line", dump.contains("refs=[request=") && dump.contains(" limit="), dump)
        check("the OOMKill its lastState says, marked", dump.contains("markers=1"), dump)
        check("sampled from metrics-server", dump.contains("source=metrics-server"), dump)
        check("the caption says where the numbers come from", await shownText(15) { $0.contains("Sampled from metrics-server while shown since") } != nil)
        // Below the fold the LazyVStack builds nothing: the rest is the model's.
        let built = page.detail.flatMap { page.podCharts(of: $0.ref, object: $0.object) }
        let builds = page.podChartsBuilds
        for _ in 0..<20 { _ = page.detail.flatMap { page.podCharts(of: $0.ref, object: $0.object) } }
        check("the tab's body run again builds nothing from the same reading", page.podChartsBuilds - builds <= 1, "\(page.podChartsBuilds - builds) builds")
        check(
            "the pod's two charts, then two a container, app first",
            built?.pod.count == 2 && built?.sections.map(\.container) == ["app", "sidecar-1"]
                && built?.sections.allSatisfy { $0.charts.count == 2 } == true, "\(built?.sections.map(\.container) ?? [])")
        let chips = built?.sections.first?.charts.map { $0.chips.map(\.text) } ?? []
        check("the chips say the shares", chips == [["48% of request", "12% of limit"], ["156% of request", "working set 78% of limit"]], "\(chips)")
        check(". is 6h, what was sampled in minute buckets", page.press(".") && page.metricsRange == .sixHours)
        await revealChart(memoryID, scope: scope)
        check(
            "drawn from the folded tier",
            await eventually(10) { charts.chart(memoryID, in: scope)?.data.tier?.contains("1-minute") == true }, charts.chart(memoryID, in: scope)?.data.tier ?? "none")
        check(". again stays: 24h needs Prometheus", page.press(".") && page.metricsRange == .sixHours)
        check(", is Live again", page.press(",") && page.metricsRange == .live)
        await revealChart(memoryID, scope: scope)
        check("drawn from the raw samples", await eventually(10) { charts.chart(memoryID, in: scope)?.data.step == 15 })

        // 3. The crosshair at a point: the tooltip said, nothing else drawn again.
        await revealChart(cpuID, scope: scope, top: true)
        await revealChart(memoryID, scope: scope)
        await chartsHover(model, scope: scope, cpu: cpuID, memory: memoryID)

        // 12. The marker opens the previous log; "Logs from Here" asks from a minute before.
        await revealChart(memoryID, scope: scope)
        guard let marker = charts.chart(memoryID, in: scope)?.data.shownMarkers.first else { return check("the OOMKill's marker", false) }
        check("the marker is the OOMKill, of app", marker.kind == .oom && marker.container == "app" && marker.title.contains("OOMKilled (exit 137)"), marker.title)
        fake.forgetRequests()
        page.openMarker(marker)
        check("its click opens the Logs tab", page.detailTab == .logs)
        check("on app, Previous on", page.detail?.logs?.container == "app" && page.detail?.logs?.previous == true)
        check(
            "the previous instance's log asked for",
            await eventually(10) { fake.requests.contains { $0.isLog && $0.query["previous"] == "true" && $0.query["container"] == "app" } },
            "\(fake.requests.filter(\.isLog).map(\.query))")
        check(
            "two restarts: only the last one's log is kept, said", await shownText(15) { $0.contains("Only the last previous instance's log is kept") } != nil,
            "\(page.detail?.logs?.shown.map { "\($0.name) \($0.restarts) restarts" } ?? "no container") previous \(page.detail?.logs?.previous ?? false)")
        page.showTab(.metrics)
        let at = Date().addingTimeInterval(-30)
        let since = KubeLogQuery.sinceTime(at.addingTimeInterval(-60))
        fake.forgetRequests()
        page.logsFromHere(container: "app", at: at)
        check("Logs from Here opens the Logs tab, from a minute before", page.detailTab == .logs && page.detail?.logs?.from != nil && page.detail?.logs?.previous == false)
        check(
            "its request asks sinceTime",
            await eventually(10) { fake.requests.contains { $0.isLog && $0.query["sinceTime"] == since && $0.query["sinceSeconds"] == nil } },
            "\(fake.requests.filter(\.isLog).map(\.query))")
        check("Copy as kubectl says it too", page.detailKubectl?.contains("--since-time=\(since)") == true, page.detailKubectl ?? "")
        page.detail?.logs?.clearFrom()
        page.showTab(.metrics)

        // Parts 2, 4 and 11: the same tab over Prometheus (M6).
        await kubernetesChartsPrometheus(model, page, fake, pod: name)

        // Hidden: nothing read.
        app.toggleKubernetesPage(nil)
        check("hidden, no usage polled", await eventually(5) { !model.metrics.isPolling })
        fake.forgetRequests()
        await pause(1.5)
        check("and the pod's metrics aren't asked", !fake.requests.contains { $0.path == own }, "\(fake.requests)")
        app.toggleKubernetesPage(nil)
        page.showTab(.overview)
        page.closeDetail()
        check("the charts wrote nothing", fake.writes.isEmpty, "\(fake.writes)")
    }

    /// Part 3: the cursor moved over the CPU chart as its hover moves it,
    /// polling held off meanwhile — the tooltip there names the series and
    /// both lines, and is drawn; the memory chart draws the crosshair and no
    /// tooltip; neither's series layer, nor the tab's body, runs again.
    private func chartsHover(_ model: KubernetesModel, scope: ObjectIdentifier?, cpu cpuID: String, memory memoryID: String) async {
        let charts = KubeChartRegistry.shared
        guard let scope, let cpu = charts.chart(cpuID, in: scope), let memory = charts.chart(memoryID, in: scope),
            let last = cpu.data.usage.first?.points.last?.time
        else { return check("the tab's two charts, to hover", false, charts.lines(in: scope).joined(separator: "; ")) }
        check("one cursor for the tab's charts", memory.cursor === cpu.cursor)
        model.metrics.interval = .seconds(60)
        // The poll in flight lands, then the next waits a minute.
        await pause(1.2)
        let draws = KubeChartDraws.shared
        let tab = KubeMetricsTabView.identifier
        let before = (cpu: draws.of(cpuID, in: scope), memory: draws.of(memoryID, in: scope), tab: draws.of(tab, in: scope))
        for move in 0..<10 {
            cpu.cursor.move(to: last.addingTimeInterval(-Double(move % 2)), owner: cpuID)
            await pause(0.05)
        }
        cpu.cursor.move(to: last, owner: cpuID)
        await pause(0.3)
        let after = (cpu: draws.of(cpuID, in: scope), memory: draws.of(memoryID, in: scope), tab: draws.of(tab, in: scope))
        let tip = charts.tooltip(cpuID, in: scope, at: last)
        check(
            "the tooltip there: the usage, then the request and the limit",
            tip?.rows.map(\.name) == ["CPU", "request", "limit"] && tip?.rows.first?.value == "120m", "\(tip?.rows ?? [])")
        if let tip { check("drawn as kubernetes.chart.tooltip", await shownText(5) { $0.contains(tip.time) } != nil, tip.time) }
        check("its overlay and tooltip drawn", after.cpu.overlay > before.cpu.overlay && after.cpu.tooltip > before.cpu.tooltip, "\(before.cpu) → \(after.cpu)")
        check("the memory chart draws the crosshair, no tooltip", after.memory.overlay > before.memory.overlay && after.memory.tooltip == before.memory.tooltip)
        check(
            "no series layer drawn again", after.cpu.series == before.cpu.series && after.memory.series == before.memory.series,
            "cpu \(before.cpu) → \(after.cpu); memory \(before.memory) → \(after.memory)")
        check("the tab's body runs no more", after.tab.container == before.tab.container, "\(after.tab.container - before.tab.container) bodies")
        cpu.cursor.leave(cpuID)
        model.metrics.interval = .milliseconds(500)
    }
}

extension E2ERunner {
    /// What the tab's queries past `FakePromQL`'s grammar are answered with
    /// (metrics.md 8, the fake): a container's throttling, a pod's network
    /// (the union's arms), its restarts a step, the OOMKills (none), C1's
    /// peak band, C2's RSS (none).
    func setTabFixtures(_ fake: FakeKubeAPI) {
        fake.setPrometheusMatrix("container_cpu_cfs_throttled_periods_total{", [FakePromFixture.Line(["container": "app"]) { _ in 0.31 }])
        fake.setPrometheusMatrix(
            "container_network_receive_bytes_total{",
            [FakePromFixture.Line(["overterm_s": "rx"]) { _ in 1_200_000 }, FakePromFixture.Line(["overterm_s": "tx"]) { _ in 340_000 }])
        fake.setPrometheusMatrix("sum(clamp_min(", [FakePromFixture.Line { _ in 0 }])
        fake.setPrometheusMatrix("kube_pod_container_status_last_terminated_reason{", [])
        fake.setPrometheusMatrix(Self.peakFragment, [FakePromFixture.Line(["container": "app"]) { _ in 0.4 }])
        fake.setPrometheusMatrix("container_memory_rss{", [])
        // C2's working set over 24h and 7d, a step's highest from the recording rule.
        fake.setPrometheusMatrix(Self.memoryPeakFragment, [FakePromFixture.Line(["container": "app"]) { _ in 98 * 1_048_576 }])
        // C4: a container's filesystem use against its ephemeral-storage limit (the union's arms).
        fake.setPrometheusMatrix(
            "container_fs_usage_bytes{",
            [
                FakePromFixture.Line(["overterm_s": "usage", "container": "app"]) { _ in 300 * 1_048_576 },
                FakePromFixture.Line(["overterm_s": "limit", "container": "app"]) { _ in 1_073_741_824 },
            ])
    }

    /// C1's peak band's query (24h and 7d), a subquery the fake doesn't read.
    static let peakFragment = "max_over_time(sum by (container)(rate(container_cpu_usage_seconds_total{"

    /// C2's over 24h and 7d with recording rules: a step's highest working set.
    static let memoryPeakFragment = "max_over_time(node_namespace_pod_container:container_memory_working_set_bytes{"

    func clearTabFixtures(_ fake: FakeKubeAPI) {
        for fragment in [
            "container_cpu_cfs_throttled_periods_total{", "container_network_receive_bytes_total{", "sum(clamp_min(", "kube_pod_container_status_last_terminated_reason{",
            Self.peakFragment, Self.memoryPeakFragment, "container_memory_rss{", "container_fs_usage_bytes{",
        ] {
            fake.clearPrometheusMatrix(fragment)
        }
    }

    /// Parts 2, 4 and 11 (metrics.md 8), the pod's tab with fake-dev's
    /// Prometheus on — kube-prometheus-stack's profile, named in its entry:
    /// Live keeps its sampled charts and draws throttling, network and
    /// restarts from a 15-minute query_range, never saying they need
    /// Prometheus; `.` to 1h asks every chart of Prometheus, raw over an
    /// hour, the recording rules over 6h; a zoom is asked at its own step
    /// and never refreshed, Reset gives the range back; 24h draws C1's peak
    /// band. Only the Service's two query paths, each with its timeout. Reads only.
    func kubernetesChartsPrometheus(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, pod name: String) async {
        let scope = app.theme.map(ObjectIdentifier.init)
        let charts = KubeChartRegistry.shared
        let service = KubePrometheusService(namespace: "monitoring", name: "prometheus-k8s", port: "9090")!
        let interval = model.prometheus.interval
        model.prometheus.interval = .milliseconds(500)
        fake.addNamespace("monitoring")
        fake.servePrometheus(namespace: "monitoring", service: "prometheus-k8s", port: "9090")
        fake.setPrometheusProfile(.kubePrometheusStack)
        setTabFixtures(fake)
        let container = ["namespace": "shop", "pod": name, "container": "app", "image": "nginx:1.27", "metrics_path": "/metrics/cadvisor"]
        fake.setPrometheusSeries("container_cpu_usage_seconds_total", labels: container, value: 0.12)
        fake.setPrometheusSeries("container_memory_working_set_bytes", labels: container, value: 100 * 1_048_576)
        let rule = ["namespace": "shop", "pod": name, "container": "app"]
        fake.setPrometheusSeries(KubePromProfile.containerCPURate5m, labels: rule, value: 0.11)
        fake.setPrometheusSeries(KubePromProfile.containerMemoryRule, labels: rule, value: 98 * 1_048_576)
        Settings.shared.set(
            "kubernetes.contexts", Self.kubeContexts(["fake-dev": ["metrics": .string("prometheus"), "prometheus": .string("monitoring/prometheus-k8s:9090")]]))
        defer {
            Settings.shared.set("kubernetes.contexts", Self.kubeContexts())
            clearTabFixtures(fake)
            for metric in ["container_cpu_usage_seconds_total", "container_memory_working_set_bytes", KubePromProfile.containerCPURate5m, KubePromProfile.containerMemoryRule] {
                fake.clearPrometheusSeries(metric, matching: ["pod": name])
            }
            fake.setPrometheusProfile(.noNodeExporter)
            model.prometheus.forgetProfile()
            model.prometheus.interval = interval
            page.metricsZoom = []
            page.metricsRange = .live
            page.metricsRangePicked = false
        }
        func asked() -> [FakeKubeAPI.Request] { fake.requests.filter(\.isPrometheusQuery) }
        // The pod's CPU is the tab's first chart, drawn; a container's sit
        // below the fold, which the LazyVStack doesn't build: theirs are the model's.
        let cpuID = "kubernetes.chart.pod.shop.\(name).cpu"
        func built() -> KubePodCharts? { page.detail.flatMap { page.podCharts(of: $0.ref, object: $0.object) } }
        func throttling() -> KubeChartData? {
            built()?.sections.first { $0.container == "app" }?.charts.first { $0.data.id == "container.shop.\(name).app.throttling" }?.data
        }
        func said() -> String {
            let tabs = model.prometheus.tabs.values.map { "\($0.request.span) \($0.results.keys.sorted()) read=\($0.read != nil) \($0.problem ?? "-") \($0.refused.values)" }
            return
                "tabs \(tabs); source \(page.detail.flatMap { page.metricsSource(of: $0.ref) }.map(\.rawValue) ?? "none"); built \(built().map { ($0.pod + $0.sections.flatMap(\.charts)).map { "\($0.data.id)@\($0.data.source)" } } ?? []); \(charts.lines(in: scope).joined(separator: "; "))"
        }
        check("fake-dev's Prometheus found as its entry names it", await eventually(15) { model.prometheus.state == .found(service, nil) }, "\(model.prometheus.state)")
        let threadsBefore = KubeChartCache.mergeThreads.counted
        let mergesBefore = model.prometheus.merges
        page.pickMetricsRange(.live)
        fake.forgetRequests()

        // 11. Live with Prometheus: throttling from a 15-minute query_range.
        check(
            "Live: the throttling chart drawn from Prometheus",
            await eventually(20) { throttling().map { $0.source == "Prometheus" && !($0.usage.first?.points.isEmpty ?? true) } == true }, said())
        let live = asked().first { $0.path == service.rangePath && $0.query["query"]?.contains("container_cpu_cfs_throttled_periods_total{") == true }
        let span = live.flatMap { request in Double(request.query["end"] ?? "").flatMap { end in Double(request.query["start"] ?? "").map { end - $0 } } }
        check("over 15 minutes at 30 s", span == 900 && live?.query["step"] == "30s", "\(live?.query ?? [:])")
        check("the CPU still sampled", charts.chart(cpuID, in: scope)?.data.source == "metrics-server")
        check(
            "never said to need Prometheus",
            page.metricsTabProblem(of: page.detail!.ref) == nil && !(page.detail.flatMap { page.podCharts(of: $0.ref, object: $0.object) }?.notes.contains { $0.contains("needs Prometheus") } ?? true))
        await revealChart("kubernetes.chart.pod.shop.\(name).network", scope: scope)
        check("its network and restarts beside", await eventually(10) { charts.chart("kubernetes.chart.pod.shop.\(name).network", in: scope) != nil })

        // 2. `.` to 1h: every chart from Prometheus, raw over an hour.
        fake.forgetRequests()
        check(". is 1h", page.press(".") && page.shownMetricsRange == .hour)
        check(
            "the pod's CPU from Prometheus over 1h",
            await eventually(20) { charts.chart(cpuID, in: scope).map { $0.data.source == "Prometheus" && $0.data.step == 30 && $0.plot != nil } == true }, said())
        check(
            "the throttling chart there",
            await eventually(10) { throttling().map { $0.end.timeIntervalSince($0.start) == 3600 } == true }, said())
        check("raw cAdvisor over an hour", charts.chart(cpuID, in: scope)?.data.tier == "raw cAdvisor", charts.chart(cpuID, in: scope)?.data.tier ?? "")
        // C4 (M8): kube-prometheus-stack's kubelet reports filesystem use.
        check(
            "app's ephemeral storage against its limit",
            await eventually(10) {
                built()?.sections.first { $0.container == "app" }?.charts.first { $0.data.id == "container.shop.\(name).app.fs" }.map {
                    $0.chips.map(\.text) == ["29% of limit"] && $0.data.references.map(\.role) == [.limit]
                } == true
            }, said())
        check("only the Service's query and query_range", !asked().isEmpty && asked().allSatisfy { $0.path == service.rangePath || $0.path == service.queryPath }, "\(asked().map(\.path))")
        check("each with 20 s", asked().allSatisfy { $0.query["timeout"] == "20s" })
        // metrics.md 5.3 (M12): every answer merged into the cache off the
        // main thread — counted where the merge runs, not where it was sent.
        let merged = KubeChartCache.mergeThreads.counted
        check(
            "its answers merged into the cache off the main thread",
            model.prometheus.merges > mergesBefore && merged.all > threadsBefore.all && merged.onMain == threadsBefore.onMain,
            "\(model.prometheus.merges - mergesBefore) kept, \(merged.all - threadsBefore.all) merged, \(merged.onMain - threadsBefore.onMain) on the main thread")
        check("no metrics.k8s.io read for it now", await eventually(5) { page.metricsDetailsOnScreen.isEmpty })
        check(". is 6h", page.press(".") && page.shownMetricsRange == .sixHours)
        check(
            "6h from the recording rules",
            await eventually(20) { charts.chart(cpuID, in: scope).map { $0.data.tier == "recording rules" && $0.data.step == 120 } == true },
            charts.chart(cpuID, in: scope).map { "\($0.data.tier ?? "-") \($0.data.step)" } ?? "none")
        check("said in the caption", await eventually(5) { page.detail.flatMap { page.podCharts(of: $0.ref, object: $0.object) }?.caption.contains("recording rules") == true })

        // 4. A zoom, as a drag's release gives it: asked at its own step, not refreshed; Reset.
        guard let shown = charts.chart(cpuID, in: scope)?.data else { return check("the chart to zoom", false) }
        fake.forgetRequests()
        let from = shown.end.addingTimeInterval(-7200)
        let to = shown.end.addingTimeInterval(-3600)
        page.zoomMetrics(from: from, to: to, of: shown)
        check("zoomed", page.metricsWindow?.kind == .zoom)
        check(
            "asked again over the window at its own step",
            await eventually(15) {
                asked().contains { $0.path == service.rangePath && $0.query["step"] == "30s" && $0.query["start"] == KubePromQL.stamp(from) && $0.query["end"] == KubePromQL.stamp(to) }
            }, "\(asked().map(\.query))")
        check("drawn over it", await eventually(10) { charts.chart(cpuID, in: scope).map { $0.data.start == from && $0.data.end == to } == true })
        await pause(1)
        fake.forgetRequests()
        await pause(1.5)
        check("a zoomed window isn't refreshed", asked().isEmpty, "\(asked().map(\.query))")
        check("Reset", page.resetMetricsWindow() && page.metricsWindow == nil)
        check(
            "the range again, asked at its step",
            await eventually(15) { asked().contains { $0.path == service.rangePath && $0.query["step"] == "2m" } && charts.chart(cpuID, in: scope)?.data.step == 120 },
            "\(asked().map(\.query))")

        // 10. Expand, Copy PromQL and CSV (M9), over 6h.
        await kubernetesChartExpand(model, page, fake, service: service, pod: name)

        // C1's peak band from 24h: a container's CPU with its step's highest short rate behind it.
        fake.forgetRequests()
        check(". is 24h", page.press(".") && page.shownMetricsRange == .day)
        check(
            "24h: app's CPU with its peak band",
            await eventually(20) { built()?.sections.first { $0.container == "app" }?.charts.first?.data.peaks.first.map { !$0.points.isEmpty } == true }, said())
        check(
            "the peak a step's highest, a minute apart", asked().contains { $0.query["query"]?.hasPrefix(Self.peakFragment) == true && $0.query["query"]?.hasSuffix("[5m:1m])") == true },
            "\(asked().compactMap { $0.query["query"] })")

        // 9. k8s_metrics (M11): app's working set at 104Mi of its 128Mi limit, said as an agent reads it.
        fake.setPrometheusSeries("container_memory_working_set_bytes", labels: container, value: 104 * 1_048_576)
        await kubernetesChartsAgent(
            model, page, fake, service: service, pod: name,
            chart: {
                built()?.sections.first { $0.container == "app" }?.charts.first { $0.data.id == "container.shop.\(name).app.cpu" }
            }, caption: { built()?.caption })
        // metrics.md 5.3's steady states and the hidden page (M12).
        await kubernetesChartsSteady(model, page, fake, service: service)
        check("Prometheus written nothing", fake.writes.isEmpty)
    }

    /// Part 9 (metrics.md 8; stage M11): `k8s_metrics` through the MCP's
    /// own handler, as an agent in a pane would call it — app's memory over
    /// the last hour, bounded, "81% of limit" said; only the Service's two
    /// query paths, each with 20 s. Then "Ask Agent About This Chart" on
    /// the tab's chart: the Ask Agent sheet, the chart as text shown whole
    /// before anything is sent — cancelled, nothing sent.
    func kubernetesChartsAgent(
        _ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, service: KubePrometheusService, pod name: String,
        chart: () -> KubePodCharts.Chart?, caption: () -> String?
    ) async {
        fake.forgetRequests()
        let arguments: [String: Any] = ["kind": "container", "name": name, "container": "app", "namespace": "shop", "context": "fake-dev", "measures": ["memory"]]
        let result = try? await KubeMCP.call("k8s_metrics", arguments, kubernetes: model)
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "\(result ?? [:])"
        note("k8s_metrics: \(text)")
        check("k8s_metrics answers", result != nil && result?["isError"] as? Bool != true, text)
        check("from the tab's own Prometheus queries", text.contains("container app of pod shop/\(name), 1h: Prometheus \(service)"), text.replacingOccurrences(of: "\n", with: " | "))
        check("app's working set against its limit: 81% of limit", text.contains("81% of limit 128Mi"), text.replacingOccurrences(of: "\n", with: " | "))
        check("bounded to about 4 KB", text.count <= KubeMetricsText.budget + 200, "\(text.count) characters")
        let asked = fake.requests.filter(\.isPrometheusQuery)
        check(
            "only the Service's query and query_range, each with 20 s",
            !asked.isEmpty && asked.allSatisfy { ($0.path == service.rangePath || $0.path == service.queryPath) && $0.query["timeout"] == "20s" },
            "\(asked.map(\.path))")
        check("nothing written", fake.writes.isEmpty)

        // "Ask Agent About This Chart": the sheet, the chart as text.
        // app's CPU over 24h, as the tab draws it (the recording rule's), with points in it.
        _ = await eventually(10) { chart()?.data.usage.first.map { !$0.points.isEmpty } == true }
        guard let shown = chart() else { return check("app's CPU chart to ask about", false) }
        func sheet() -> AskAgentView? { (window.attachedSheet?.contentViewController as? NSHostingController<AskAgentView>)?.rootView }
        let brief = page.askAboutChart(shown, caption: caption())
        check("the chart asked about", brief?.text.contains("app · CPU: last") == true, (brief?.text ?? "none").replacingOccurrences(of: "\n", with: " | "))
        check("the Ask Agent sheet opens", await eventually(10) { self.window.attachedSheet != nil && sheet() != nil })
        let ask = app.askAgent
        check("the whole text shown before it is sent", ask.showsBrief && ask.subject == "CPU of pod/\(name)", ask.subject ?? "none")
        let prompt = await app.askAgentPrompt()
        check("its context and window said", prompt.contains("pod shop/\(name) on context fake-dev") && prompt.contains("· Prometheus ·"), prompt.replacingOccurrences(of: "\n", with: " | "))
        let cancelled = sheet().map { $0.cancel() } != nil
        let away = await eventually(3) { self.window.attachedSheet == nil }
        check("Cancel sends nothing", cancelled && away && !ask.isOpen)
    }
}
