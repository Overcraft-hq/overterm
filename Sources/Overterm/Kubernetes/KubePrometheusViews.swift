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
/// each series, why there is none. The Overview's (`.cluster`) is X1–X4
/// (metrics.md 2.9, M8): the cluster's CPU and memory against its
/// requests, limits, allocatable and capacity, its CPU by namespace, its
/// nodes; a claim's its usage with its fill forecast (V1) and, toggled,
/// its inodes (V2).
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
                    problemAndNotes(reading)
                    if chart == .cluster { overviewParts(service) }
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
        case .cluster, .namespaces, .nodes: "Usage over time"
        case .volume, .volumeInodes: "Volume usage"
        }
    }

    private var identifier: String {
        switch chart {
        case .cluster, .namespaces, .nodes: "kubernetes.overview.prometheus"
        case .volume, .volumeInodes: "kubernetes.detail.volume"
        }
    }

    @ViewBuilder private func problemAndNotes(_ reading: KubeChartReading) -> some View {
        if let problem = reading.problem {
            Text(verbatim: problem).font(.system(size: 11)).foregroundStyle(TabStatusStyle.failed).textSelection(.enabled)
        }
        ForEach(reading.notes, id: \.self) { note in
            Text(verbatim: note).font(.system(size: 10.5)).foregroundStyle(theme.text3).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("kubernetes.chart.note")
        }
    }

    @ViewBuilder private func content(_ reading: KubeChartReading) -> some View {
        switch chart {
        case .cluster where reading.refused != nil:
            refused(reading.refused ?? "")
            requests(reading)
        case .cluster:
            HStack(alignment: .top, spacing: 20) {
                ForEach(KubeClusterCharts.prometheus(reading)) { drawn($0, reading) }
            }
            requests(reading)
        case .volume:
            volume(reading)
        default:
            EmptyView()
        }
    }

    /// X3 and X4 under X1 and X2, sharing their crosshair: each its own reading.
    @ViewBuilder private func overviewParts(_ service: KubePrometheusService) -> some View {
        let byNamespace = page.namespacesChart
        if let reading = monitor.charts[byNamespace], reading.unavailable == nil {
            if let chart = KubeClusterCharts.namespaces(reading) {
                drawn(chart, reading)
            } else if let why = reading.refused {
                Text(verbatim: "CPU by namespace: " + why).font(.system(size: 11)).foregroundStyle(theme.text3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = reading.problem {
                Text(verbatim: "CPU by namespace: " + problem).font(.system(size: 11)).foregroundStyle(TabStatusStyle.failed).textSelection(.enabled)
            }
        }
        if let reading = monitor.charts[.nodes], reading.unavailable == nil {
            if let why = reading.refused {
                // Too costly over this range: the last 15 minutes sampled, where metrics-server is.
                Text(verbatim: "Nodes over \(reading.range.title): " + why).font(.system(size: 11)).foregroundStyle(theme.text3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                let sampled = page.sampledNodeRows()
                KubeNodeStripsView(page: page, rows: sampled.rows, more: sampled.more, caption: "Nodes, the last 15 min of allocatable — sampled while shown", theme: theme)
            } else {
                let rows = KubeClusterCharts.nodeRows(reading, allocatable: page.nodeAllocatable)
                let cells = KubeHeatStrip.spoken(KubeChart.nodeStep(reading.range))
                KubeNodeStripsView(
                    page: page, rows: rows.rows, more: rows.more,
                    caption: "Nodes, the last \(reading.range.title) of allocatable in \(cells) cells — from Prometheus" + ((reading.tier?.title).map { " · \($0)" } ?? ""),
                    theme: theme)
            }
            if let problem = reading.problem {
                Text(verbatim: "Nodes: " + problem).font(.system(size: 11)).foregroundStyle(TabStatusStyle.failed).textSelection(.enabled)
            }
        }
    }

    /// A claim's usage against its capacity, its fill forecast as a chip and
    /// a dotted line; none of either where it has no fixed size (EFS);
    /// its inodes toggled beside.
    @ViewBuilder private func volume(_ reading: KubeChartReading) -> some View {
        let data = KubeChartData.of(reading, chart: chart, measure: .volumeUsed)
        let capacity = reading.series[.volumeCapacity]?.last?.value
        let used = reading.series[.volumeUsed]?.last?.value
        let unbounded = KubeVolumeUsage.isUnbounded(capacity)
        let usage = used.map { KubeVolumeUsage(used: $0, capacity: capacity) }
        let headline = usage.map {
            unbounded ? KubeVolumeFormat.bytes($0.used) : KubeVolumeFormat.bytes($0.used) + (capacity.map { " of \(KubeVolumeFormat.bytes($0))" } ?? "") + ($0.percent.map { " · \($0)%" } ?? "")
        }
        let forecast = unbounded ? nil : KubeVolumeForecast.chip(available: reading.totals[.volumeAvailable], rate: KubeVolumeForecast.rate(reading))
        drawn(KubePodCharts.Chart(data: data, headline: headline, chips: forecast.map { [$0] } ?? []), reading)
        if unbounded, let capacity {
            Text(verbatim: KubeVolumeForecast.unbounded(capacity)).font(.system(size: 11)).foregroundStyle(theme.text3).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("kubernetes.detail.volume.unbounded")
        }
        if case .volume(let namespace, let claim) = chart {
            Toggle(isOn: $page.volumeInodesShown) { Text(verbatim: "Inodes used") }
                .toggleStyle(.checkbox).controlSize(.small)
                .help("kubelet_volume_stats_inodes_used against _inodes, read only while shown")
                .accessibilityIdentifier("kubernetes.detail.volume.inodes")
            if page.volumeInodesShown {
                let inodes = KubeChart.volumeInodes(namespace: namespace, claim: claim)
                if let reading = monitor.charts[inodes] {
                    let data = KubeChartData.of(reading, chart: inodes, measure: .inodes)
                    drawn(KubePodCharts.Chart(data: data, headline: reading.series[.inodes]?.last.map { KubeChartUnit.ratio.format($0.value) }), reading)
                    if let problem = reading.problem { Text(verbatim: problem).font(.system(size: 11)).foregroundStyle(TabStatusStyle.failed) }
                } else {
                    Text(verbatim: "Asking Prometheus…").font(.system(size: 11)).foregroundStyle(theme.text3)
                }
            }
        }
    }

    /// A chart, or why there's nothing to draw.
    @ViewBuilder private func drawn(_ chart: KubePodCharts.Chart, _ reading: KubeChartReading) -> some View {
        let data = chart.data
        if data.usage.contains(where: { !$0.points.isEmpty }) {
            KubeChartView(data: data, cursor: cursor, headline: chart.headline, span: "last \(reading.range.title)", chips: chart.chips, theme: theme)
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

    /// kube-state-metrics' requests and limits of active pods as shares of
    /// the nodes' allocatable — the chips X1 and X2 carry, said in a line
    /// too (where the lines are refused, alone) — or why there are none.
    @ViewBuilder private func requests(_ reading: KubeChartReading) -> some View {
        let shares = KubeClusterCharts.chips(reading, cpu: true).map { "CPU " + $0.text } + KubeClusterCharts.chips(reading, cpu: false).map { "Memory " + $0.text }
        if shares.isEmpty {
            Text(verbatim: "No requests or limits in Prometheus: kube-state-metrics' kube_pod_container_resource_requests (and kube_pod_status_phase, which says which pods are active) isn't scraped.")
                .font(.system(size: 11)).foregroundStyle(theme.text3)
        } else if reading.refused != nil {
            Text(verbatim: shares.joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(theme.text2).textSelection(.enabled)
                .accessibilityIdentifier("kubernetes.overview.requests")
        }
    }
}

extension KubeChartData {
    /// A Prometheus reading's chart of one measure: its line over the
    /// range's window, and what it is measured against as reference lines —
    /// the cluster's active requests, limits, allocatable and capacity
    /// (instant totals, flat across), a volume's capacity (stepped) and its
    /// fill forecast (dotted, to a quarter of the range past now) — neither
    /// for a volume with no fixed size (EFS). Pure.
    static func of(_ reading: KubeChartReading, chart: KubeChart, measure: KubeChartMeasure) -> KubeChartData {
        // The subject names its object: two pods' charts are two charts.
        let (subject, title): (String, String) =
            switch chart {
            case .cluster: ("cluster", measure == .cpu ? "CPU" : "Memory")
            case .namespaces: ("cluster.namespaces", "CPU by namespace")
            case .nodes: ("cluster.nodes", measure == .cpu ? "CPU" : "Memory")
            case .volume(let namespace, let claim): ("volume.\(namespace).\(claim)", "Used")
            case .volumeInodes(let namespace, let claim): ("volume.\(namespace).\(claim)", "Inodes used")
            }
        let id = subject + "." + (measure == .volumeUsed ? "used" : measure.rawValue)
        let window = reading.range.window(now: reading.read ?? Date())
        var end = window.end
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
            flat(.capacity, .cpuCapacity)
        case (.cluster, .memory):
            flat(.request, .memoryRequests)
            flat(.limit, .memoryLimits)
            flat(.allocatable, .memoryAllocatable)
            flat(.capacity, .memoryCapacity)
        case (.volume, _):
            let capacity = reading.series[.volumeCapacity] ?? []
            if let last = capacity.last?.value, !KubeVolumeUsage.isUnbounded(last) {
                series.append(KubeChartSeries(id: "capacity", name: "capacity", role: .capacity, points: capacity))
                if let used = reading.series[.volumeUsed]?.last, let rate = KubeVolumeForecast.rate(reading) {
                    let ahead = window.end.addingTimeInterval(reading.range.seconds * KubeVolumeForecast.ahead)
                    if let projection = KubeVolumeForecast.projection(from: used, rate: rate, capacity: last, until: ahead) {
                        series.append(projection)
                        end = ahead
                    }
                }
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
            hasher.combine(line.id)
            hasher.combine(line.points.count)
            hasher.combine(line.points.last?.value)
        }
        let unit: KubeChartUnit = measure == .inodes ? .ratio : measure.isBytes ? .bytes : .cores
        let tier: String
        switch measure {
        case .volumeUsed, .inodes: tier = "kubelet volume stats"
        default: tier = (reading.tier ?? .raw).title
        }
        return KubeChartData(
            id: id, title: title, unit: unit, series: series, start: window.start, end: end, step: reading.range.step, source: "Prometheus", tier: tier,
            version: hasher.finalize(), bands: bands)
    }
}
