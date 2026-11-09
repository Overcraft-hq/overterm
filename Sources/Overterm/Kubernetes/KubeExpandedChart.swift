import SwiftUI

/// A Metrics tab's chart expanded into the window's right slot
/// (docs/design/kubernetes/metrics.md 2.1, 3.8; stage M9): one chart at
/// the slot's full height, `KubeManifestPane.Shown.chart`, under the
/// `RightSlot` rule — the page steps aside so it shows beside the
/// terminal. It is the tab's own chart, built from the same data: nothing
/// new is asked for it. While it is on screen the tab's reads go on as
/// they would on the page (`KubernetesPageModel.chartsShown`) — the same
/// one GET a target every 15 s, the same Prometheus want —, and only
/// while its object's Metrics tab is still the detail's; otherwise it
/// keeps the last chart it had, said with its time, and nothing is read.
/// Its own crosshair: the tab's charts aren't beside it.
@MainActor
final class KubeExpandedChart: ObservableObject, Identifiable {
    /// What it shows: the chart, its span ("last 15 min") and the tab's caption.
    struct Shown: Equatable {
        var chart: KubePodCharts.Chart
        var span: String
        var caption: String?
    }

    let id = UUID()
    /// The detail it came from.
    let ref: KubeObjectRef
    /// Its chart's id among the tab's (`KubeChartData.id`).
    let chartID: String
    /// A pod's chart: the container whose log "Logs from Here" opens, as
    /// the tab's chart has it (nil, the pod's own: the first container's).
    let container: String?
    let cursor = KubeChartCursor()
    /// The last it was drawn from the tab, and when.
    @Published private(set) var last: Shown
    @Published private(set) var updated: Date

    init(ref: KubeObjectRef, shown: Shown, container: String? = nil, now: Date = Date()) {
        self.ref = ref
        self.container = container
        chartID = shown.chart.id
        last = shown
        updated = now
    }

    /// The tab built it again: kept, in case the tab goes.
    func remember(_ shown: Shown, now: Date = Date()) {
        guard shown != last else { return }
        last = shown
        updated = now
    }

    /// Its identifier part: the tab's chart's, under `expanded.` — so the
    /// dump, the registry and the draw counter tell the two apart.
    static func identifier(_ chartID: String) -> String { "expanded." + chartID }

    /// The chart's data as the slot draws it: the tab's, under its own identifier.
    static func data(_ shown: Shown) -> KubeChartData {
        var data = shown.chart.data
        data.id = identifier(data.id)
        return data
    }

    /// What the slot says when the tab no longer feeds it. Pure.
    static func stale(since updated: Date) -> String {
        "As of \(KubeChartTime.clock(updated)): its Metrics tab isn't open any more, so nothing is read for it. Show in Kubernetes to follow it again."
    }
}

/// The expanded chart in the right slot: its object and context, the
/// chart at the slot's height (its context menu's Copy PromQL and Copy
/// Values as CSV, a drag zooming the tab's charts with it), the tab's
/// caption — or, the tab gone, the time it is from.
struct KubeExpandedChartView: View {
    static let identifier = "kubernetes.expanded"

    @ObservedObject var expanded: KubeExpandedChart
    @ObservedObject var page: KubernetesPageModel
    /// Observed so the chart follows the tab's samples and answers.
    @ObservedObject var metrics: KubeMetricsMonitor
    @ObservedObject var prometheus: KubePrometheusMonitor
    @ObservedObject var theme: ChromeTheme
    let onClose: () -> Void
    /// "Show in Kubernetes": the page, on the chart's object's Metrics tab.
    let onShowPage: () -> Void

    /// What a marker, or "Logs from Here", opens is on the page: shown
    /// first, as Show in Kubernetes does, then the tab or the log.
    private func onPage(_ then: @escaping () -> Void) {
        onShowPage()
        then()
    }

    var body: some View {
        let live = page.liveChart(for: expanded)
        let shown = live ?? expanded.last
        VStack(alignment: .leading, spacing: 0) {
            header(shown)
            Divider().opacity(0.3)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: live == nil ? KubeExpandedChart.stale(since: expanded.updated) : shown.caption ?? "")
                    .font(.system(size: 10.5)).foregroundStyle(live == nil ? theme.text2 : theme.text3).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(Self.identifier + ".caption")
                if live != nil, let window = page.metricsWindow {
                    HStack(spacing: 6) {
                        Text(verbatim: (window.kind == .zoom ? "Zoomed " : "Custom ") + window.title).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.text)
                        Button("Reset") { page.resetMetricsWindow() }.controlSize(.small)
                            .accessibilityIdentifier(Self.identifier + ".reset")
                    }
                }
                if live != nil, page.metricsLivePaused {
                    HStack(spacing: 6) {
                        Text(verbatim: "Paused").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text2)
                        Button("Resume") { page.resumeMetrics() }.controlSize(.small)
                    }
                }
                GeometryReader { geometry in
                    // The tab's own chart: its markers open what they open there, "Logs from Here" a pod's log —
                    // on the page; ⌥-click's ±30 min moves the window here, as a drag does.
                    KubeChartView(
                        data: KubeExpandedChart.data(shown), cursor: expanded.cursor, headline: shown.chart.headline, span: shown.span,
                        height: max(geometry.size.height - 48, 120), chips: shown.chart.chips,
                        openMarker: { [weak page] marker in onPage { page?.openMarker(marker) } },
                        showAround: live == nil ? nil : { [weak page] in page?.showAround($0) },
                        logsFromHere: expanded.ref.isPod
                            ? { [weak page, expanded] time in onPage { page?.logsFromHere(container: expanded.container, at: time) } } : nil,
                        zoom: live == nil ? nil : { [weak page] from, to in page?.zoomMetrics(from: from, to: to, of: shown.chart.data) },
                        copy: { [weak page] in page?.copyChartText($0) },
                        ask: live == nil ? nil : { [weak page] in page?.askAboutChart(shown.chart, caption: shown.caption) }, theme: theme
                    )
                    .frame(width: geometry.size.width)
                }
            }
            .padding(12)
        }
        .background(theme.strip)
        .onContinuousHover { _ in page.noteMetricsInput() }
        .onAppear { if let live { expanded.remember(live) } }
        .onChange(of: live) { new in if let new { expanded.remember(new) } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Self.identifier)
    }

    private func header(_ shown: KubeExpandedChart.Shown) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: "⎈").foregroundStyle(theme.dimText)
            Text(verbatim: shown.chart.data.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
            Text(verbatim: "\(expanded.ref.namespace.map { "\($0)/" } ?? "")\(expanded.ref.name) · \(expanded.ref.context)")
                .font(.system(size: 11)).foregroundStyle(theme.dimText).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Button("Show in Kubernetes", action: onShowPage)
                .controlSize(.small)
                .help("The page again, on this chart's Metrics tab")
                .accessibilityIdentifier(Self.identifier + ".show")
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Close")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }
}
