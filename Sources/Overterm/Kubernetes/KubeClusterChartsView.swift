import SwiftUI

/// The Overview's usage sampled from metrics-server while it shows
/// (metrics.md 2.9, X1, X2, X4; stage M8): the cluster's CPU and memory
/// against its nodes' allocatable and capacity, the chip saying requests
/// need Prometheus, and its nodes as small multiples. Where the context's
/// Prometheus is found, `KubePrometheusChartView(.cluster)` draws them over
/// the range instead.
struct KubeClusterSampledView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var metrics: KubeMetricsMonitor
    @ObservedObject var theme: ChromeTheme
    /// The crosshair its two charts share — held, not observed.
    @State private var cursor = KubeChartCursor()

    var body: some View {
        let charts = page.sampledClusterCharts()
        if !charts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(charts) { chart in
                        KubeChartView(
                            data: chart.data, cursor: cursor, headline: chart.headline, span: "last 10 min", chips: chart.chips,
                            copy: { [weak page] in page?.copyChartText($0) }, theme: theme
                        )
                        .frame(minWidth: 200, maxWidth: .infinity)
                    }
                }
                Text(verbatim: page.sampledClusterCaption()).font(.system(size: 10.5)).foregroundStyle(theme.text3)
                    .accessibilityIdentifier("kubernetes.overview.usage.caption")
                Text(verbatim: KubeChartEmpty.requestsNeedSpecs.sentence).font(.system(size: 10.5)).foregroundStyle(theme.text3)
                let nodes = page.sampledNodeRows()
                KubeNodeStripsView(
                    page: page, rows: nodes.rows, more: nodes.more, caption: "Nodes, the last 15 min of allocatable — sampled while shown", theme: theme)
            }
            .accessibilityIdentifier("kubernetes.overview.sampled")
        }
    }
}

/// X4: the nodes as small multiples — a row each, its CPU's and memory's
/// 60 cells of its allocatable, the share now — the hottest 50 past that
/// many, by name; a row's name opens the node's Metrics tab.
struct KubeNodeStripsView: View {
    @ObservedObject var page: KubernetesPageModel
    var rows: [KubeNodeStripRow]
    var more: Int
    var caption: String
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: caption).font(.system(size: 11)).foregroundStyle(theme.text3)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    GridRow {
                        Text(verbatim: "").gridColumnAlignment(.leading)
                        Text(verbatim: "CPU").font(.system(size: 10)).foregroundStyle(theme.text3)
                        Text(verbatim: "Memory").font(.system(size: 10)).foregroundStyle(theme.text3)
                    }
                    ForEach(rows) { row in
                        GridRow {
                            Button {
                                page.openNodeMetrics(row.node)
                            } label: {
                                Text(verbatim: row.node).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(theme.accentText).lineLimit(1)
                                    .truncationMode(.middle).frame(maxWidth: 220, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .help("Open the node's Metrics tab")
                            strip(row.cpu, row.node, .cpu)
                            strip(row.memory, row.node, .memory)
                        }
                    }
                }
                if more > 0 {
                    Text(verbatim: "The 50 most used of \(rows.count + more) nodes; the rest are in the Nodes list.").font(.system(size: 10.5)).foregroundStyle(theme.text3)
                }
            }
            .accessibilityIdentifier("kubernetes.overview.nodes")
        }
    }

    @ViewBuilder private func strip(_ strip: KubeHeatStrip?, _ node: String, _ measure: KubeUsageCell.Measure) -> some View {
        HStack(spacing: 5) {
            if let strip {
                KubeHeatStripView(
                    strip: strip, identifier: KubeClusterCharts.stripIdentifier(node, measure), dark: theme.isDark, track: theme.text3, window: ObjectIdentifier(theme)
                )
                .help(strip.summary())
                Text(verbatim: strip.now.map { "\(Int($0.rounded()))%" } ?? "–").font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text2)
                    .frame(width: 36, alignment: .trailing)
            } else {
                Text(verbatim: "–").font(.system(size: 11)).foregroundStyle(theme.text3).frame(width: KubeHeatStripView.width + 41, alignment: .leading)
            }
        }
    }
}
