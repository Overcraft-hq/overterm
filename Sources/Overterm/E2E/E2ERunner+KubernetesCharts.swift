import AppKit
import Foundation

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
        check(
            "drawn from the folded tier",
            await eventually(10) { charts.chart(memoryID, in: scope)?.data.tier?.contains("1-minute") == true }, charts.chart(memoryID, in: scope)?.data.tier ?? "none")
        check(". again stays: 24h needs Prometheus", page.press(".") && page.metricsRange == .sixHours)
        check(", is Live again", page.press(",") && page.metricsRange == .live)
        check("drawn from the raw samples", await eventually(10) { charts.chart(memoryID, in: scope)?.data.step == 15 })

        // 3. The crosshair at a point: the tooltip said, nothing else drawn again.
        await chartsHover(model, scope: scope, cpu: cpuID, memory: memoryID)

        // 12. The marker opens the previous log; "Logs from Here" asks from a minute before.
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
