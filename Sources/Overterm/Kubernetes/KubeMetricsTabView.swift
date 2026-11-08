import SwiftUI

/// A pod's Metrics tab (`m`; metrics.md 2.2): the range picker and where
/// the numbers come from, then the pod's charts stacked by container and
/// each container's own — a picker in place of the sections past four
/// containers. Its charts share one crosshair, held in `@State` and not
/// observed, so a hover redraws the charts' overlays and never this body.
struct KubeMetricsTabView: View {
    static let identifier = "kubernetes.detail.metrics"

    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var metrics: KubeMetricsMonitor
    @ObservedObject var session: KubeDetailSession
    @ObservedObject var theme: ChromeTheme
    @State private var cursor = KubeChartCursor()

    var body: some View {
        // Counted: `kubernetesCharts` checks a hover never runs it.
        let _ = KubeChartDraws.shared.composed(Self.identifier, window: ObjectIdentifier(theme))
        if session.ref.isPod {
            let charts = page.podCharts(of: session.ref, object: session.object)
            VStack(alignment: .leading, spacing: 0) {
                controls(caption: charts?.caption)
                Rectangle().fill(theme.border).frame(height: 1)
                if let charts, charts.hasSamples {
                    KubePodChartsList(
                        charts: charts, cursor: cursor, theme: theme, openMarker: { [weak page] in page?.openMarker($0) },
                        logsFromHere: { [weak page] container, time in page?.logsFromHere(container: container, at: time) })
                } else {
                    problem(charts)
                }
            }
            .accessibilityIdentifier(Self.identifier)
        } else {
            let charts = page.objectCharts(of: session)
            VStack(alignment: .leading, spacing: 0) {
                controls(caption: charts?.caption, workloadView: charts?.view)
                Rectangle().fill(theme.border).frame(height: 1)
                if let charts, charts.charts.contains(where: { chart in chart.data.usage.contains { !$0.points.isEmpty } }) {
                    KubeObjectChartsList(charts: charts, cursor: cursor, theme: theme)
                } else {
                    objectProblem(charts)
                }
            }
            .accessibilityIdentifier(Self.identifier)
        }
    }

    /// A workload's Total or Per pod, a node's "Sample top pods".
    @ViewBuilder private func objectControls(_ view: KubeWorkloadView?) -> some View {
        switch session.ref.metricsSubject {
        case .workload:
            Picker("", selection: Binding(get: { view ?? page.workloadChartView ?? .total }, set: { page.pickWorkloadView($0) })) {
                ForEach(KubeWorkloadView.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("Total: stacked, its top five pods and the rest, against the template's request × replicas. Per pod: the top five as lines, against one pod's.")
            .accessibilityIdentifier("kubernetes.metrics.workloadView")
        case .node:
            Button(page.topPodsTitle) { page.sampleTopPods() }
                .controlSize(.small)
                .disabled(page.topPodsSampling.map { !$0.stopped && $0.node == session.ref.name } ?? false)
                .help("Read the namespaces of this node's largest pods (by request, at most four) every 30 s for 15 minutes")
                .accessibilityIdentifier("kubernetes.metrics.sampleTopPods")
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func objectProblem(_ charts: KubeObjectCharts?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let said = page.objectMetricsProblem(of: session) {
                Text(verbatim: said).font(.system(size: 12)).foregroundStyle(theme.text2).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("kubernetes.metrics.problem")
            } else if session.object == nil {
                ProgressView().controlSize(.small)
            } else {
                Text(verbatim: charts?.caption ?? "Waiting for the first sample…").font(.system(size: 12)).foregroundStyle(theme.text3)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func controls(caption: String?, workloadView: KubeWorkloadView? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ForEach(KubeMetricsRange.allCases) { range in
                    let enabled = page.metricsRanges.contains(range)
                    Button {
                        page.pickMetricsRange(range)
                    } label: {
                        Text(verbatim: range.title)
                            .font(.system(size: 11.5, weight: page.metricsRange == range ? .semibold : .regular))
                            .foregroundStyle(!enabled ? theme.text3.opacity(0.5) : page.metricsRange == range ? theme.text : theme.text2)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: 5).fill(page.metricsRange == range ? theme.selected : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                    .help(page.metricsRangeHelp(range) + (enabled ? "  ,  ." : ""))
                    .accessibilityIdentifier("kubernetes.metrics.range.\(range.rawValue)")
                }
                Spacer(minLength: 0)
                objectControls(workloadView)
            }
            if let caption {
                Text(verbatim: caption).font(.system(size: 10.5)).foregroundStyle(theme.text3).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("kubernetes.metrics.caption")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder private func problem(_ charts: KubePodCharts?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let said = page.metricsTabProblem(of: session.ref) {
                Text(verbatim: said).font(.system(size: 12)).foregroundStyle(theme.text2).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("kubernetes.metrics.problem")
                if page.podUsageRefused(of: session.ref) {
                    Button("Try Again") { page.model.retry() }.controlSize(.small)
                        .help("Ask metrics-server again: access may have been granted since")
                }
                if page.metricsTabOffersOverview {
                    Button("Show Overview") { page.showTab(.overview) }.controlSize(.small)
                        .help("The pod's chart from Prometheus")
                        .accessibilityIdentifier("kubernetes.metrics.showOverview")
                }
            } else if session.object == nil {
                ProgressView().controlSize(.small)
            } else {
                Text(verbatim: charts?.caption ?? "Waiting for metrics-server's first sample of this pod…").font(.system(size: 12)).foregroundStyle(theme.text3)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The charts themselves, from `KubePodCharts` alone — what the page and
/// `kubernetesPerf` host: the pod's two, then a section a container, in a
/// `LazyVStack` so a chart scrolled off isn't built.
struct KubePodChartsList: View {
    var charts: KubePodCharts
    let cursor: KubeChartCursor
    @ObservedObject var theme: ChromeTheme
    var openMarker: ((KubeChartMarker) -> Void)?
    var logsFromHere: ((String?, Date) -> Void)?
    @State private var picked: String?

    static let height: CGFloat = 140

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                caption("Pod")
                ForEach(charts.pod) { chart in view(chart, container: charts.sections.first?.container) }
                if charts.picksContainer {
                    Picker("Container", selection: Binding(get: { shown.first?.container ?? "" }, set: { picked = $0 })) {
                        ForEach(charts.sections) { Text(verbatim: $0.container).tag($0.container) }
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityIdentifier("kubernetes.metrics.container")
                }
                ForEach(shown) { section in
                    caption("Container \(section.container)")
                    ForEach(section.charts) { chart in view(chart, container: section.container) }
                }
            }
            .padding(14)
        }
    }

    /// The sections shown: every one, or past four the one picked.
    private var shown: [KubePodCharts.Section] {
        guard charts.picksContainer else { return charts.sections }
        return [charts.sections.first { $0.container == picked } ?? charts.sections[0]]
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
    }

    private func view(_ chart: KubePodCharts.Chart, container: String?) -> some View {
        KubeChartView(
            data: chart.data, cursor: cursor, headline: chart.headline, span: charts.span, height: Self.height, chips: chart.chips, openMarker: openMarker,
            logsFromHere: logsFromHere.map { logs in { logs(container, $0) } }, theme: theme
        )
        .frame(maxWidth: .infinity)
    }
}

/// A workload's, an HPA's, a node's or a namespace's charts: a section a
/// group, then the sentences that say why a chart is left out — in a
/// `LazyVStack`, so a chart scrolled off isn't built.
struct KubeObjectChartsList: View {
    var charts: KubeObjectCharts
    let cursor: KubeChartCursor
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(charts.groups) { group in
                    Text(verbatim: group.title).font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
                    ForEach(group.charts) { chart in
                        KubeChartView(
                            data: chart.data, cursor: cursor, headline: chart.headline, span: charts.span, height: KubePodChartsList.height, chips: chart.chips,
                            theme: theme
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                ForEach(charts.notes, id: \.self) { note in
                    Text(verbatim: note).font(.system(size: 11)).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("kubernetes.metrics.note")
                }
            }
            .padding(14)
        }
    }
}
