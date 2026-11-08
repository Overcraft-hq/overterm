import SwiftUI

/// The range a Prometheus chart covers (1 h, 6 h, 24 h, 7 d): only where
/// the context's Prometheus is found — without it there is no range to
/// pick, the chart covers the time it has been shown, and says so.
struct KubeChartRangePicker: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var monitor: KubePrometheusMonitor

    var body: some View {
        Picker(
            "Range",
            selection: Binding(get: { monitor.range }, set: { page.chartRange = $0 })
        ) {
            ForEach(KubeChartRange.allCases) { range in Text(verbatim: range.title).tag(range) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 200)
        .help("The time the charts cover, asked of Prometheus as query_range's start, end and step")
        .accessibilityIdentifier("kubernetes.chart.range")
    }
}

/// A series over a range, drawn as a line under its highest value, with
/// a dashed line for what it is measured against (a volume's capacity, a
/// limit); the latest value and the range's ends said in words. A gap of
/// more than two steps is drawn as a gap (`KubePrometheusReader.segments`).
struct KubeRangeChart: View {
    var title: String
    var points: [KubeSeriesPoint]
    var reference: Double?
    var measure: KubeChartMeasure
    var range: KubeChartRange
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(verbatim: title).font(.system(size: 11)).foregroundStyle(theme.text3)
                if let last = points.last {
                    Text(verbatim: measure.format(last.value) + (reference.map { " of \(measure.format($0))" } ?? ""))
                        .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(theme.text)
                }
            }
            if points.count >= 2 {
                GeometryReader { geometry in
                    let top = max(points.map(\.value).max() ?? 0, reference ?? 0, .leastNonzeroMagnitude)
                    let first = points.first!.time.timeIntervalSince1970
                    let span = max(points.last!.time.timeIntervalSince1970 - first, 1)
                    ZStack {
                        if let reference {
                            Path { path in
                                let y = geometry.size.height * (1 - CGFloat(reference / top))
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                            }
                            .stroke(theme.text3, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        }
                        Path { path in
                            for run in KubePrometheusReader.segments(points, step: range.step) {
                                for (index, point) in run.enumerated() {
                                    let x = geometry.size.width * CGFloat((point.time.timeIntervalSince1970 - first) / span)
                                    let y = geometry.size.height * (1 - CGFloat(point.value / top))
                                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                                }
                            }
                        }
                        .stroke(theme.accentText, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                    }
                }
                .frame(width: 220, height: 40)
                .background(RoundedRectangle(cornerRadius: 4).fill(theme.rowHover.opacity(0.5)))
                .accessibilityHidden(true)
                HStack {
                    Text(verbatim: "\(range.title) ago").font(.system(size: 9.5)).foregroundStyle(theme.text3)
                    Spacer(minLength: 0)
                    Text(verbatim: "now").font(.system(size: 9.5)).foregroundStyle(theme.text3)
                }
                .frame(width: 220)
            } else {
                Text(verbatim: "Prometheus has no samples of it over the last \(range.title).").font(.system(size: 11)).foregroundStyle(theme.text3)
            }
        }
    }
}

/// A chart's reading as a detail or the Overview shows it: the picker,
/// each series, why there is none.
struct KubePrometheusChartView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var monitor: KubePrometheusMonitor
    var chart: KubeChart
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(verbatim: title).font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
                if monitor.service != nil { KubeChartRangePicker(page: page, monitor: monitor) }
                Spacer(minLength: 0)
            }
            if let service = monitor.service {
                if let reading = monitor.charts[chart] {
                    content(reading)
                    Text(verbatim: "The last \(reading.range.title), from Prometheus \(service)")
                        .font(.system(size: 10.5)).foregroundStyle(theme.text3)
                        .accessibilityIdentifier("kubernetes.chart.caption")
                    if let problem = reading.problem {
                        Text(verbatim: problem).font(.system(size: 11)).foregroundStyle(TabStatusStyle.failed).textSelection(.enabled)
                    }
                    ForEach(reading.notes, id: \.self) { note in
                        Text(verbatim: note).font(.system(size: 10.5)).foregroundStyle(theme.text3).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("kubernetes.chart.note")
                    }
                } else {
                    Text(verbatim: "Asking Prometheus \(service)…").font(.system(size: 11)).foregroundStyle(theme.text3)
                }
            } else if let said = monitor.state.said {
                Text(verbatim: said).font(.system(size: 11)).foregroundStyle(theme.text3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier(identifier)
    }

    private var title: String {
        switch chart {
        case .cluster: "Usage over time"
        case .pod: "Usage over time"
        case .volume: "Volume usage"
        }
    }

    private var identifier: String {
        switch chart {
        case .cluster: "kubernetes.overview.prometheus"
        case .pod: "kubernetes.detail.prometheus"
        case .volume: "kubernetes.detail.volume"
        }
    }

    @ViewBuilder private func content(_ reading: KubeChartReading) -> some View {
        switch chart {
        case .cluster where reading.refused != nil:
            refused(reading.refused ?? "")
            requests(reading)
        case .cluster, .pod:
            HStack(alignment: .top, spacing: 20) {
                KubeRangeChart(title: "CPU", points: reading.series[.cpu] ?? [], reference: nil, measure: .cpu, range: reading.range, theme: theme)
                KubeRangeChart(title: "Memory", points: reading.series[.memory] ?? [], reference: nil, measure: .memory, range: reading.range, theme: theme)
            }
            if chart == .cluster { requests(reading) }
        case .volume:
            KubeRangeChart(
                title: "Used", points: reading.series[.volumeUsed] ?? [], reference: reading.series[.volumeCapacity]?.last?.value, measure: .volumeUsed,
                range: reading.range, theme: theme)
        }
    }

    /// Why the lines aren't asked over this range, and the range they are.
    private func refused(_ why: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: why).font(.system(size: 11)).foregroundStyle(theme.text3).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("kubernetes.chart.refused")
            Button {
                page.chartRange = KubeChartRange.rawClusterLimit
            } label: {
                Text(verbatim: "Show \(KubeChartRange.rawClusterLimit.title)")
            }
            .controlSize(.small)
            .accessibilityIdentifier("kubernetes.chart.showRawLimit")
        }
    }

    /// kube-state-metrics' requests and limits of active pods against the nodes' allocatable.
    @ViewBuilder private func requests(_ reading: KubeChartReading) -> some View {
        let lines: [(String, KubeChartMeasure, KubeChartMeasure)] = [
            ("CPU requested", .cpuRequests, .cpuAllocatable), ("CPU limits", .cpuLimits, .cpuAllocatable),
            ("Memory requested", .memoryRequests, .memoryAllocatable), ("Memory limits", .memoryLimits, .memoryAllocatable),
        ]
        let shown = lines.compactMap { line in reading.share(line.1, of: line.2).map { (line.0, line.1, $0) } }
        if shown.isEmpty {
            Text(verbatim: "No requests or limits in Prometheus: kube-state-metrics' kube_pod_container_resource_requests (and kube_pod_status_phase, which says which pods are active) isn't scraped.")
                .font(.system(size: 11)).foregroundStyle(theme.text3)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(shown, id: \.0) { title, measure, share in
                    HStack(spacing: 8) {
                        Text(verbatim: title).font(.system(size: 11)).foregroundStyle(theme.text3).frame(width: 120, alignment: .leading)
                        Text(
                            verbatim: measure.format(share.used) + (share.total > 0 ? " of \(measure.format(share.total)) allocatable" : "")
                                + (share.percent.map { " · \($0)%" } ?? "")
                        )
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle((share.percent ?? 0) > 100 ? TabStatusStyle.failed : theme.text)
                        .help((share.percent ?? 0) > 100 ? "More than the nodes can give: overcommitted." : "")
                    }
                }
            }
            .textSelection(.enabled)
            .accessibilityIdentifier("kubernetes.overview.requests")
        }
    }
}
