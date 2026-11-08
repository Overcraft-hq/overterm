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

/// A chart's reading as a detail or the Overview shows it: the picker,
/// each series, why there is none.
struct KubePrometheusChartView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var monitor: KubePrometheusMonitor
    var chart: KubeChart
    @ObservedObject var theme: ChromeTheme
    /// The crosshair its charts share — held, not observed: a class in
    /// `@State` subscribes nothing, so a hover redraws the charts'
    /// overlays and never this body (metrics.md, 5.2).
    @State private var cursor = KubeChartCursor()

    var body: some View {
        // Counted: `kubernetesPrometheus` checks a hover never runs it.
        let _ = KubeChartDraws.shared.composed(identifier, window: ObjectIdentifier(theme))
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(verbatim: title).font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
                if monitor.service != nil { KubeChartRangePicker(page: page, monitor: monitor) }
                Spacer(minLength: 0)
            }
            if let service = monitor.service {
                if let reading = monitor.charts[chart], let unavailable = reading.unavailable {
                    Text(verbatim: unavailable).font(.system(size: 11)).foregroundStyle(theme.text3).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("kubernetes.chart.unavailable")
                } else if let reading = monitor.charts[chart] {
                    content(reading)
                    Text(verbatim: "The last \(reading.range.title), from Prometheus \(service)" + (reading.caption.map { " · \($0)" } ?? ""))
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
                drawn(KubeChartData.of(reading, chart: chart, measure: .cpu), reading)
                drawn(KubeChartData.of(reading, chart: chart, measure: .memory), reading)
            }
            if chart == .cluster { requests(reading) }
        case .volume:
            let data = KubeChartData.of(reading, chart: chart, measure: .volumeUsed)
            let capacity = reading.series[.volumeCapacity]?.last?.value
            drawn(data, reading, headline: reading.series[.volumeUsed]?.last.map { KubeVolumeFormat.bytes($0.value) + (capacity.map { " of \(KubeVolumeFormat.bytes($0))" } ?? "") })
        }
    }

    /// A chart, or why there's nothing to draw.
    @ViewBuilder private func drawn(_ data: KubeChartData, _ reading: KubeChartReading, headline: String? = nil) -> some View {
        if data.usage.contains(where: { !$0.points.isEmpty }) {
            KubeChartView(data: data, cursor: cursor, headline: headline, span: "last \(reading.range.title)", theme: theme)
                .frame(minWidth: 200, maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: data.title).font(.system(size: 11)).foregroundStyle(theme.text3)
                Text(verbatim: "Prometheus has no samples of it over the last \(reading.range.title).").font(.system(size: 11)).foregroundStyle(theme.text3)
            }
            .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
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

extension KubeChartData {
    /// A Prometheus reading's chart of one measure: its line over the
    /// range's window, and what it is measured against as reference lines —
    /// the cluster's active requests, limits and allocatable (instant
    /// totals, flat across), a volume's capacity (stepped). Pure.
    static func of(_ reading: KubeChartReading, chart: KubeChart, measure: KubeChartMeasure) -> KubeChartData {
        // The subject names its object: two pods' charts are two charts.
        let (subject, title): (String, String) =
            switch chart {
            case .cluster: ("cluster", measure == .cpu ? "CPU" : "Memory")
            case .pod(let namespace, let name): ("pod.\(namespace).\(name)", measure == .cpu ? "CPU" : "Memory")
            case .volume(let namespace, let claim): ("volume.\(namespace).\(claim)", "Used")
            }
        let id = subject + "." + (measure == .volumeUsed ? "used" : measure.rawValue)
        let window = reading.range.window(now: reading.read ?? Date())
        var series = [KubeChartSeries(id: measure.rawValue, name: title, points: reading.series[measure] ?? [])]
        func flat(_ role: KubeChartRole, _ total: KubeChartMeasure) {
            guard let value = reading.totals[total] else { return }
            series.append(KubeChartSeries(id: role.rawValue, name: role.label, role: role, points: [KubeSeriesPoint(time: window.end, value: value)]))
        }
        switch (chart, measure) {
        case (.cluster, .cpu):
            flat(.request, .cpuRequests)
            flat(.limit, .cpuLimits)
            flat(.allocatable, .cpuAllocatable)
        case (.cluster, .memory):
            flat(.request, .memoryRequests)
            flat(.limit, .memoryLimits)
            flat(.allocatable, .memoryAllocatable)
        case (.volume, _):
            if let capacity = reading.series[.volumeCapacity], !capacity.isEmpty {
                series.append(KubeChartSeries(id: "capacity", name: "capacity", role: .capacity, points: capacity))
            }
        default: break
        }
        // Before the oldest sample Prometheus keeps: hatched, said.
        var bands: [KubeChartBand] = []
        if let retention = reading.retention, retention > window.start {
            bands.append(
                KubeChartBand(id: "retention", title: KubeChartEmpty.retention(retention).sentence, start: window.start, end: min(retention, window.end)))
        }
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(reading.tier)
        hasher.combine(reading.retention)
        hasher.combine(reading.range)
        hasher.combine(reading.read)
        for line in series {
            hasher.combine(line.points.count)
            hasher.combine(line.points.last?.value)
        }
        return KubeChartData(
            id: id, title: title, unit: measure.isBytes ? .bytes : .cores, series: series, start: window.start, end: window.end, step: reading.range.step,
            source: "Prometheus", tier: measure == .volumeUsed ? "kubelet volume stats" : (reading.tier ?? .raw).title, version: hasher.finalize(),
            bands: bands)
    }
}
