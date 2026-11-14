import AppKit
import Foundation

/// `kubernetesCharts` part 10 (docs/design/kubernetes/metrics.md, 8; stage
/// M9), over the fake's Prometheus with the pod's tab on a range: Copy
/// PromQL gives the exact query its chart was asked with, Copy Values as
/// CSV its window, to the (recorded) clipboard only; Expand puts the chart
/// alone in the right slot — the browser column giving the slot up
/// (`RightSlot`) — and the page steps aside, the tab's reads going on for
/// it and nothing else; Show in Kubernetes brings the tab back; closing
/// the slot stops every read and gives the browser its slot back. Reads only.
extension E2ERunner {
    func kubernetesChartExpand(
        _ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, service: KubePrometheusService, pod name: String
    ) async {
        let scope = app.theme.map(ObjectIdentifier.init)
        let charts = KubeChartRegistry.shared
        let cpuID = "pod.shop.\(name).cpu"
        func built() -> KubePodCharts? { page.detail.flatMap { page.podCharts(of: $0.ref, object: $0.object) } }
        func cpu() -> KubePodCharts.Chart? { built()?.pod.first { $0.id == cpuID } }
        guard await eventually(15, { cpu()?.data.source == "Prometheus" && !(cpu()?.data.queries.isEmpty ?? true) }), let chart = cpu(), let span = built()?.span
        else {
            return check("the pod's CPU from Prometheus, its query with it", false, cpu().map { "\($0.data.source) \($0.data.queries.count)" } ?? "none")
        }
        let actions = page.actions
        defer { page.actions = actions }
        var copied: [String] = []
        page.actions?.copy = { copied.append($0) }

        // Copy PromQL: the query as it was sent; Copy Values as CSV: the window's values.
        // What the fake's Prometheus is asked, as it records it — never what the reading says it sent:
        // the clock a step on, as a refresh after one, so each query goes out again (for its tail).
        func sent() -> Set<String> {
            Set(fake.requests.filter { $0.path == service.rangePath || $0.path == service.queryPath }.compactMap { $0.query["query"] })
        }
        guard let promQL = KubeChartExport.promQL(chart.data) else { return check("Copy PromQL offered", false) }
        fake.forgetRequests()
        model.prometheus.clock = { Date().addingTimeInterval(120) }
        let reached = await eventually(15) { chart.data.queries.allSatisfy { sent().contains($0.promql) } }
        model.prometheus.clock = { Date() }
        page.copyChartText(promQL)
        check(
            "Copy PromQL: the queries Prometheus was asked for the chart", reached && copied.last == promQL,
            "\(chart.data.queries.map(\.promql)) of \(sent())")
        check("the pod's own", copied.last?.contains("pod=\"\(name)\"") == true)
        page.copyChartText(KubeChartExport.csv(chart.data))
        let lines = copied.last?.split(separator: "\n").map(String.init) ?? []
        let points = chart.data.usage.first?.points.filter { $0.time >= chart.data.start && $0.time <= chart.data.end }.count ?? 0
        check(
            "Copy Values as CSV: a row a time, a column a series", lines.first?.hasPrefix("time,") == true && lines.count == points + 1 && points > 0,
            "\(lines.prefix(2)) of \(lines.count), \(points) points")
        check("the clipboard only: nothing written", fake.writes.isEmpty)

        // The browser column has the right slot; Expand takes it.
        if app.diffItem?.isCollapsed == false { app.toggleDiff(nil) }
        if app.browserItem?.isCollapsed != false { app.toggleBrowser(nil) }
        check("the browser has the right slot", await eventually(3) { self.app.browserItem?.isCollapsed == false })
        if app.store.showingOverlay != .kubernetes { app.showKubernetesPage() }
        page.expandChart(chart, span: span, caption: built()?.caption)
        let expandedID = "kubernetes.chart." + KubeExpandedChart.identifier(cpuID)
        check(
            "Expand: the chart alone in the right slot, the browser giving it up",
            await eventually(5) {
                self.app.diffItem?.isCollapsed == false && self.app.browserItem?.isCollapsed == true && self.app.rightPane.mode == .manifest
                    && self.app.kubernetesManifest.shown == .chart
            }, "diff \(app.diffItem?.isCollapsed as Any), browser \(app.browserItem?.isCollapsed as Any), \(app.rightPane.mode)")
        check("the page steps aside", app.store.showingOverlay == nil)
        check("drawn there, under its own identifier", await eventually(10) { charts.chart(expandedID, in: scope)?.plot != nil }, charts.lines(in: scope).joined(separator: "; "))
        check("taller than the tab's", (charts.chart(expandedID, in: scope)?.plot?.size.height ?? 0) > KubePodChartsList.height)

        // The tab's reads go on for it — Prometheus and nothing of the list's.
        check("the slot on screen, its tab followed", page.expandedChartOnScreen && page.expansionFollowed && model.readsMetrics && !model.isShown)
        check("its tab's Prometheus want kept", page.metricsTabWant.map { model.prometheus.tabs[$0] != nil } == true && model.prometheus.isPolling)
        fake.forgetRequests()
        await pause(1.5)
        check(
            "no list, watch or discovery read for it",
            !fake.requests.contains { $0.path == "/api/v1/namespaces/shop/pods" || $0.path == "/api/v1/pods" || $0.isWatch || $0.isDiscovery },
            "\(fake.requests.map(\.description))")
        check("the same data as the tab's", page.expandedChart.flatMap { page.liveChart(for: $0) }?.chart.data.version == cpu()?.data.version)

        // Show in Kubernetes: the page on the tab again.
        if let expanded = page.expandedChart { app.showKubernetesExpandedSource(expanded) }
        check("Show in Kubernetes: the page, on its Metrics tab", app.store.showingOverlay == .kubernetes && page.detailTab == .metrics && page.detail?.ref.name == name)

        // Expanded again, then closed: nothing is read for it, the browser has its slot back.
        page.expandChart(chart, span: span, caption: built()?.caption)
        check("expanded again", await eventually(5) { self.app.store.showingOverlay == nil && page.expandedChartOnScreen })
        app.toggleDiff(nil)
        check(
            "closed: nothing read for it", await eventually(10) { !page.expandedChartOnScreen && !model.readsMetrics && model.prometheus.tabs.isEmpty },
            "on screen \(page.expandedChartOnScreen), reads \(model.readsMetrics), tabs \(model.prometheus.tabs.count)")
        check("the browser has the slot back", await eventually(3) { self.app.browserItem?.isCollapsed == false && self.app.diffItem?.isCollapsed == true })
        fake.forgetRequests()
        await pause(1)
        check("not a query since", !fake.requests.contains(where: \.isPrometheusQuery), "\(fake.requests.map(\.path))")
        app.closeBrowser()
        app.showKubernetesPage()
        check("the page and its tab back", await eventually(5) { self.app.store.showingOverlay == .kubernetes && page.metricsTabWant != nil })
    }
}
