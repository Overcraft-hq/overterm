import SwiftUI

/// A pod's Metrics tab (`m`; metrics.md 2.2): the range picker — Live to
/// 7d, Custom over Prometheus —, a zoom's or a window's Reset, Live's
/// pause, and where the numbers come from; then the pod's charts stacked
/// by container and each container's own — a picker in place of the
/// sections past four containers. Its charts share one crosshair, held in
/// `@State` and not observed, so a hover redraws the charts' overlays and
/// never this body; a drag across one zooms them all.
struct KubeMetricsTabView: View {
    static let identifier = "kubernetes.detail.metrics"

    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var metrics: KubeMetricsMonitor
    /// Its Prometheus answers land here: observed, as the samples are.
    @ObservedObject var prometheus: KubePrometheusMonitor
    @ObservedObject var session: KubeDetailSession
    @ObservedObject var theme: ChromeTheme
    @State private var cursor = KubeChartCursor()

    var body: some View {
        // Counted: `kubernetesCharts` checks a hover never runs it.
        let _ = KubeChartDraws.shared.composed(Self.identifier, window: ObjectIdentifier(theme))
        if session.ref.isPod {
            let charts = page.podCharts(of: session.ref, object: session.object)
            let drawn = charts?.hasSamples == true
            VStack(alignment: .leading, spacing: 0) {
                controls(caption: charts?.caption, report: drawn)
                Rectangle().fill(theme.border).frame(height: 1)
                gpus
                sizing
                if let charts, drawn {
                    KubePodChartsList(
                        charts: charts, cursor: cursor, theme: theme, openMarker: { [weak page] in page?.openMarker($0) },
                        showAround: { [weak page] in page?.showAround($0) },
                        logsFromHere: { [weak page] container, time in page?.logsFromHere(container: container, at: time) },
                        zoom: { [weak page] from, to, data in page?.zoomMetrics(from: from, to: to, of: data) },
                        copy: { [weak page] in page?.copyChartText($0) },
                        expand: { [weak page] chart in page?.expandChart(chart, span: charts.span, caption: charts.caption) },
                        ask: { [weak page] chart in page?.askAboutChart(chart, caption: charts.caption) })
                } else {
                    problem(charts)
                }
            }
            .onContinuousHover { _ in page.noteMetricsInput() }
            .accessibilityIdentifier(Self.identifier)
        } else {
            let charts = page.objectCharts(of: session)
            let drawn = charts?.charts.contains(where: { chart in chart.data.usage.contains { !$0.points.isEmpty } }) == true
            VStack(alignment: .leading, spacing: 0) {
                controls(caption: charts?.caption, workloadView: charts?.view, report: drawn)
                Rectangle().fill(theme.border).frame(height: 1)
                gpus
                sizing
                if let charts, drawn {
                    KubeObjectChartsList(
                        charts: charts, cursor: cursor, theme: theme, openMarker: { [weak page] in page?.openMarker($0) },
                        showAround: { [weak page] in page?.showAround($0) },
                        zoom: { [weak page] from, to, data in page?.zoomMetrics(from: from, to: to, of: data) },
                        groupShown: { [weak page] in page?.metricsGroupShown($0, $1) },
                        copy: { [weak page] in page?.copyChartText($0) },
                        expand: { [weak page] chart in page?.expandChart(chart, span: charts.span, caption: charts.caption) },
                        ask: { [weak page] chart in page?.askAboutChart(chart, caption: charts.caption) })
                } else {
                    objectProblem(charts)
                }
            }
            .onContinuousHover { _ in page.noteMetricsInput() }
            .accessibilityIdentifier(Self.identifier)
        }
    }

    /// What the objects say of its GPUs (decision 12), above the charts whatever their source.
    @ViewBuilder private var gpus: some View {
        if let allocation = page.gpuAllocation(of: session) {
            KubeGPUAllocationView(allocation: allocation, theme: theme, open: { [weak page] in page?.openGPUHolder($0) })
            Rectangle().fill(theme.border).frame(height: 1)
        }
    }

    /// Sizing's card, once pressed (M10).
    @ViewBuilder private var sizing: some View {
        if let reading = page.sizingReading(of: session.ref) {
            KubeSizingView(
                reading: reading, card: page.sizingCard(of: session), theme: theme, copy: { [weak page] in page?.copyChartText($0) },
                again: { [weak page] in page?.sizeUsage() }, hide: { [weak page] in page?.hideSizing() })
            Rectangle().fill(theme.border).frame(height: 1)
        }
    }

    /// Sizing's button: a pod's or a workload's, Prometheus opted in.
    @ViewBuilder private var sizingButton: some View {
        if page.offersSizing(session.ref) {
            let disabled = page.sizingDisabled
            Button("Sizing") { page.sizeUsage() }
                .controlSize(.small)
                .disabled(disabled != nil || page.sizingReading(of: session.ref)?.done == false)
                .help(
                    disabled
                        ?? "Seven days of each pod's CPU and memory, asked of Prometheus once: a request from CPU's p95, memory's from its max. Advice only — nothing is changed."
                )
                .accessibilityIdentifier("kubernetes.metrics.sizing")
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
                report
            } else if session.object == nil {
                ProgressView().controlSize(.small)
            } else {
                Text(verbatim: charts?.caption ?? (page.metricsSource(of: session.ref) == .prometheus ? "Asking Prometheus…" : "Waiting for the first sample…"))
                    .font(.system(size: 12)).foregroundStyle(theme.text3)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Copy PromQL beside what a refused query says (metrics.md 4.7: a bug report).
    @ViewBuilder private var report: some View {
        if let promQL = page.reportedPromQL(of: session) {
            KubeCopyPromQLButton(promQL: promQL, copy: { [weak page] in page?.copyChartText($0) })
        }
    }

    /// The range picker and the caption; `report`, the charts drawn: a refused query's Copy PromQL under it.
    private func controls(caption: String?, workloadView: KubeWorkloadView? = nil, report shown: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ForEach(KubeMetricsRange.allCases) { range in
                    let enabled = page.metricsRanges.contains(range)
                    let picked = page.shownMetricsRange == range && page.metricsWindow == nil
                    Button {
                        page.pickMetricsRange(range)
                    } label: {
                        Text(verbatim: range.title)
                            .font(.system(size: 11.5, weight: picked ? .semibold : .regular))
                            .foregroundStyle(!enabled ? theme.text3.opacity(0.5) : picked ? theme.text : theme.text2)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: 5).fill(picked ? theme.selected : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                    .help(page.metricsRangeHelp(range) + (enabled ? "  ,  ." : ""))
                    .accessibilityIdentifier("kubernetes.metrics.range.\(range.rawValue)")
                }
                if page.offersCustomRange {
                    Button {
                        page.customRangeShown = true
                    } label: {
                        Text(verbatim: "Custom").font(.system(size: 11.5, weight: page.metricsWindow?.kind == .custom ? .semibold : .regular))
                            .foregroundStyle(theme.text2)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Two dates, asked of Prometheus  .")
                    .popover(isPresented: $page.customRangeShown, arrowEdge: .bottom) {
                        KubeCustomRangeView(
                            page: page, theme: theme, start: page.metricsWindow?.start ?? Date().addingTimeInterval(-3600),
                            end: page.metricsWindow?.end ?? Date())
                    }
                    .accessibilityIdentifier("kubernetes.metrics.range.customButton")
                }
                if let window = page.metricsWindow {
                    Text(verbatim: (window.kind == .zoom ? "Zoomed " : "Custom ") + window.title)
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(theme.text)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(theme.selected))
                        .help(windowHelp(window))
                        .accessibilityIdentifier("kubernetes.metrics.range.custom")
                    Button("Reset") { page.resetMetricsWindow() }
                        .controlSize(.small)
                        .help(page.metricsZoom.count > 1 ? "The window before  Esc" : "The range again  Esc")
                        .accessibilityIdentifier("kubernetes.metrics.reset")
                }
                if page.metricsLivePaused {
                    Text(verbatim: "Paused").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(theme.text2)
                        .help("Live stopped reading after 15 minutes without input in this window")
                        .accessibilityIdentifier("kubernetes.metrics.paused")
                    Button("Resume") { page.resumeMetrics() }
                        .controlSize(.small)
                        .accessibilityIdentifier("kubernetes.metrics.resume")
                }
                Spacer(minLength: 0)
                objectControls(workloadView)
                sizingButton
            }
            if let caption {
                Text(verbatim: caption).font(.system(size: 10.5)).foregroundStyle(theme.text3).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("kubernetes.metrics.caption")
            }
            if shown { report }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func windowHelp(_ window: KubeChartWindow) -> String {
        let prometheus = page.metricsSource(of: session.ref) != .sampled
        switch window.kind {
        case .zoom: return prometheus ? "A drag's window: asked again at its own step, not refreshed" : "A drag's window: what was sampled then, narrowed — nothing is asked"
        case .custom: return "Custom's window, asked of Prometheus at its own step"
        case .around:
            return prometheus ? "A marker's time ± 30 minutes, asked of Prometheus" : "A marker's time ± 30 minutes: what was sampled then, narrowed — nothing is asked"
        }
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
                report
            } else if session.object == nil {
                ProgressView().controlSize(.small)
            } else {
                Text(
                    verbatim: charts?.caption
                        ?? (page.metricsSource(of: session.ref) == .prometheus ? "Asking Prometheus…" : "Waiting for metrics-server's first sample of this pod…")
                )
                .font(.system(size: 12)).foregroundStyle(theme.text3)
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
    var showAround: ((KubeChartMarker) -> Void)?
    var logsFromHere: ((String?, Date) -> Void)?
    /// A drag across a chart: its two times and the chart's data.
    var zoom: ((Date, Date, KubeChartData) -> Void)?
    /// A chart's Copy PromQL and Copy Values as CSV; its ⤢ (M9).
    var copy: ((String) -> Void)? = nil
    var expand: ((KubePodCharts.Chart) -> Void)? = nil
    /// A chart's "Ask Agent About This Chart" (M11).
    var ask: ((KubePodCharts.Chart) -> Void)? = nil
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
                    ForEach(section.notes, id: \.self) { note($0) }
                }
                ForEach(charts.notes, id: \.self) { note($0) }
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

    private func note(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 11)).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityIdentifier("kubernetes.metrics.note")
    }

    private func view(_ chart: KubePodCharts.Chart, container: String?) -> some View {
        KubeChartView(
            data: chart.data, cursor: cursor, headline: chart.headline, span: charts.span, height: Self.height, chips: chart.chips, openMarker: openMarker,
            showAround: showAround, logsFromHere: logsFromHere.map { logs in { logs(container, $0) } },
            zoom: zoom.map { zoom in { zoom($0, $1, chart.data) } }, copy: copy, expand: expand.map { expand in { expand(chart) } },
            ask: ask.map { ask in { ask(chart) } }, theme: theme
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
    var openMarker: ((KubeChartMarker) -> Void)?
    var showAround: ((KubeChartMarker) -> Void)?
    var zoom: ((Date, Date, KubeChartData) -> Void)?
    /// A group read only while on screen came into view, or left it.
    var groupShown: ((String, Bool) -> Void)?
    /// A chart's Copy PromQL and Copy Values as CSV; its ⤢ (M9).
    var copy: ((String) -> Void)? = nil
    var expand: ((KubePodCharts.Chart) -> Void)? = nil
    /// A chart's "Ask Agent About This Chart" (M11).
    var ask: ((KubePodCharts.Chart) -> Void)? = nil

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(charts.groups) { group in
                    Text(verbatim: group.title).font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
                        .onAppear { if group.readsWhenShown { groupShown?(group.title, true) } }
                        .onDisappear { if group.readsWhenShown { groupShown?(group.title, false) } }
                    if group.pending, group.charts.isEmpty {
                        Text(verbatim: "Asked of Prometheus while shown").font(.system(size: 11)).foregroundStyle(theme.text3)
                            .accessibilityIdentifier("kubernetes.metrics.pending")
                    }
                    ForEach(group.charts) { chart in
                        KubeChartView(
                            data: chart.data, cursor: cursor, headline: chart.headline, span: charts.span, height: KubePodChartsList.height, chips: chart.chips,
                            openMarker: openMarker, showAround: showAround, zoom: zoom.map { zoom in { zoom($0, $1, chart.data) } }, copy: copy,
                            expand: expand.map { expand in { expand(chart) } }, ask: ask.map { ask in { ask(chart) } }, theme: theme
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

/// A detail's GPUs as its objects say them: each resource allocated
/// against what is offered, who holds them (a node's pods open on a
/// click), and how the numbers were read.
struct KubeGPUAllocationView: View {
    static let identifier = "kubernetes.metrics.gpus"

    var allocation: KubeGPUAllocation
    @ObservedObject var theme: ChromeTheme
    var open: ((KubeRowID) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: "GPUs").font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
            ForEach(allocation.resources) { resource in
                Text(verbatim: allocation.lines[allocation.resources.firstIndex(of: resource) ?? 0]).font(.system(size: 12)).foregroundStyle(theme.text)
            }
            ForEach(allocation.holders) { holder in
                let line = allocation.lines[allocation.resources.count + (allocation.holders.firstIndex(of: holder) ?? 0)]
                if let pod = holder.pod, let open {
                    Button {
                        open(pod)
                    } label: {
                        Text(verbatim: line).font(.system(size: 11.5)).foregroundStyle(theme.text2)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(pod.description)")
                    .accessibilityIdentifier("kubernetes.metrics.gpus.holder")
                } else {
                    Text(verbatim: line).font(.system(size: 11.5)).foregroundStyle(theme.text2)
                }
            }
            ForEach(allocation.notes, id: \.self) { note in
                Text(verbatim: note).font(.system(size: 11)).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Contained, not combined: each holder's button stays its own element, its open reachable.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Self.identifier)
    }
}

/// Custom's popover: two dates and times, checked (`KubeChartWindow.custom`)
/// — the start before the end, the end not in the future, the start within
/// what Prometheus keeps — and applied as the tab's window.
struct KubeCustomRangeView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var theme: ChromeTheme
    @State var start: Date
    @State var end: Date
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "Custom range").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
            DatePicker("From", selection: $start, displayedComponents: [.date, .hourAndMinute])
                .accessibilityIdentifier("kubernetes.metrics.custom.start")
            DatePicker("To", selection: $end, displayedComponents: [.date, .hourAndMinute])
                .accessibilityIdentifier("kubernetes.metrics.custom.end")
            if let problem {
                Text(verbatim: problem).font(.system(size: 11)).foregroundStyle(TabStatusStyle.failed).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("kubernetes.metrics.custom.problem")
            }
            HStack {
                Spacer()
                Button("Cancel") { page.customRangeShown = false }.keyboardShortcut(.cancelAction)
                Button("Show") { problem = page.applyCustomRange(start: start, end: end) }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("kubernetes.metrics.custom.apply")
            }
        }
        .controlSize(.small)
        .padding(12)
        .frame(width: 300)
    }
}

/// "Copy PromQL" beside a sentence that says Prometheus (or the metrics
/// proxy's filter) refused a query: the query as sent, to the clipboard
/// only — the bug report metrics.md 4.7 offers for `bad_data` and the
/// filter's 403, where no chart is drawn to carry it in its menu.
struct KubeCopyPromQLButton: View {
    let promQL: String
    let copy: (String) -> Void

    var body: some View {
        Button("Copy PromQL") { copy(promQL) }
            .controlSize(.small)
            .help("The query that was refused, exactly as sent: to report it, or try it in Grafana")
            .accessibilityIdentifier("kubernetes.metrics.copyPromQL")
    }
}
