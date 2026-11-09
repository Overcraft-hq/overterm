import Foundation

/// A chart's own verbs (docs/design/kubernetes/metrics.md 2.1, 3.9; stage
/// M9): Expand — the chart alone in the window's right slot, the page
/// stepping aside, the tab's reads going on for it while it shows there —,
/// Copy PromQL and Copy Values as CSV, to the clipboard only.
extension KubernetesPageModel {
    /// Where the detail's Metrics tab is on screen: on the page in a window
    /// on screen — or, the page stepped aside, as the chart expanded from
    /// it into that window's right slot (its object's tab still the
    /// detail's). Its reads follow this, nothing more: the list, the
    /// Overview and the other tabs read only on the page.
    var chartsShown: Bool { windowVisible && (visible || expansionFollowed) }

    /// The expanded chart shows in the slot and the tab it came from is still the detail's.
    var expansionFollowed: Bool {
        guard expandedChartOnScreen, let expanded = expandedChart, let detail, detail.ref == expanded.ref else { return false }
        return section.listsKinds && metricsTabShows
    }

    /// Whether the model keeps its usage and Prometheus read for the
    /// expanded chart alone: the page hidden, the chart on screen.
    var holdsChartsForExpansion: Bool { !visible && windowVisible && expansionFollowed }

    /// ⤢, or "Expand" in a chart's menu: the tab's chart alone in the
    /// window's right slot; the page steps aside (the window's `expandChart`).
    func expandChart(_ chart: KubePodCharts.Chart, span: String, caption: String?) {
        guard let detail, metricsTabShows else { return }
        // A pod's chart: its section's container, as the tab's "Logs from Here" has it.
        var container: String?
        if detail.ref.isPod, let charts = podCharts(of: detail.ref, object: detail.object) {
            container = charts.sections.first { $0.charts.contains { $0.id == chart.id } }?.container ?? charts.sections.first?.container
        }
        let expanded = KubeExpandedChart(
            ref: detail.ref, shown: KubeExpandedChart.Shown(chart: chart, span: span, caption: caption), container: container)
        expandedChart = expanded
        actions?.expandChart(expanded)
    }

    /// The expanded chart as the tab builds it now: nil when its object's
    /// Metrics tab isn't the detail's, or no longer has that chart.
    func liveChart(for expanded: KubeExpandedChart) -> KubeExpandedChart.Shown? {
        guard let detail, detail.ref == expanded.ref, metricsTabShows else { return nil }
        if detail.ref.isPod {
            guard let charts = podCharts(of: detail.ref, object: detail.object) else { return nil }
            let all = charts.pod + charts.sections.flatMap(\.charts)
            return all.first { $0.id == expanded.chartID }.map { KubeExpandedChart.Shown(chart: $0, span: charts.span, caption: charts.caption) }
        }
        guard let charts = objectCharts(of: detail) else { return nil }
        return charts.charts.first { $0.id == expanded.chartID }.map { KubeExpandedChart.Shown(chart: $0, span: charts.span, caption: charts.caption) }
    }

    /// "Show in Kubernetes" from the slot: its object's Metrics tab on the
    /// page again — opened afresh when the detail has moved on.
    func showExpandedChartSource(_ expanded: KubeExpandedChart) {
        if detail?.ref != expanded.ref {
            detailTab = .metrics
            open(expanded.ref, from: .link)
        }
        showTab(.metrics)
    }

    /// The slot closed, or given to something else: nothing is read for it.
    func expandedChartClosed() {
        expandedChartOnScreen = false
    }

    /// Its window closes: the expanded chart goes with it, so no layout
    /// pass after (the right pane's, a hop late) can say it is on screen
    /// again and hold the model's metrics for a window that is gone.
    func expandedChartWindowClosing() {
        expandedChart = nil
        expandedChartOnScreen = false
    }

    /// "Copy PromQL", "Copy Values as CSV": the clipboard, nowhere else.
    func copyChartText(_ text: String) {
        actions?.copy(text)
    }

    /// What the tab's Copy PromQL beside its sentences gives: the queries
    /// Prometheus refused as sent (`bad_data`, a saved query's 422) or the
    /// metrics proxy's filter did (metrics.md 4.7: a bug report — a chart
    /// that drew nothing has no menu to offer it); nil, none.
    func reportedPromQL(of session: KubeDetailSession) -> String? {
        guard metricsSource(of: session.ref) != .sampled, let reading = tabReading(of: session) else { return nil }
        return KubeChartExport.promQL(reading.reported)
    }
}
