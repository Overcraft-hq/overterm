import SwiftUI

/// The Overview section (`1`): what fails first — pods failing and why,
/// workloads and nodes not ready, the last hour's Warning events — then
/// the cluster's usage against its nodes' allocatable (metrics-server's,
/// when it is there) and over time (X1–X4: sampled, or from Prometheus), the counts per kind and pods by phase, then the
/// applications by their recommended labels. Read only while it shows
/// (`KubeClusterOverviewSession`); a row opens its object's detail.
struct KubeClusterOverviewView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var session: KubeClusterOverviewSession
    @ObservedObject var model: KubernetesModel
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        let overview = session.overview
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if session.state == .loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the cluster…").font(.system(size: 12)).foregroundStyle(theme.text3)
                    }
                }
                KubePinnedHealthView(page: page, session: page.pinnedHealth, theme: theme)
                header
                attention(overview)
                usage
                // X1–X4: over the range from Prometheus where it is found, else sampled while shown.
                if page.chartsFromPrometheus {
                    KubePrometheusChartView(page: page, monitor: model.prometheus, chart: .cluster, theme: theme)
                } else {
                    KubeClusterSampledView(page: page, metrics: model.metrics, theme: theme)
                    if page.prometheusOn { KubePrometheusChartView(page: page, monitor: model.prometheus, chart: .cluster, theme: theme) }
                }
                KubeOverviewHealthView(page: page, session: page.health, theme: theme)
                counts(overview)
                applications(overview)
                if !session.problems.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        caption("Not read")
                        ForEach(session.problems.sorted { $0.key.title < $1.key.title }, id: \.key) { part, why in
                            Text(verbatim: "\(part.title): \(why)").font(.system(size: 11.5)).foregroundStyle(theme.text3).textSelection(.enabled)
                        }
                    }
                    .accessibilityIdentifier("kubernetes.overview.problems")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: GhosttyRuntime.shared.backgroundColor))
        .accessibilityIdentifier("kubernetes.overview")
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
    }

    /// The server's version and its nodes, as discovery and the who-am-I read say them.
    @ViewBuilder private var header: some View {
        let version = model.version.map { "Kubernetes \($0.gitVersion)" }
        let nodes = session.state == .idle ? nil : "\(session.overview.nodes) node\(session.overview.nodes == 1 ? "" : "s")"
        if version != nil || nodes != nil {
            HStack(spacing: 10) {
                Text(verbatim: [version, nodes].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text2).textSelection(.enabled)
                    .accessibilityIdentifier("kubernetes.overview.version")
                // The health checks' count, where it is seen first; the findings below.
                KubeHealthCount(session: page.health, theme: theme)
            }
        }
    }

    // MARK: What fails

    @ViewBuilder private func attention(_ overview: KubeClusterOverview) -> some View {
        let notReady = overview.workloads.flatMap { count in count.notReady.map { (key: count.resource + "/" + $0.description, count: count, id: $0) } }
        if overview.problems > 0 || !overview.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                caption("Needs attention")
                ForEach(overview.failingPods, id: \.id) { pod in
                    row(
                        symbol: "exclamationmark.triangle.fill", tone: TabStatusStyle.failed, title: "pod/\(pod.id.name)", namespace: pod.id.namespace,
                        detail: pod.exitReason ?? pod.status + (pod.restarts.map { $0 > 0 ? " · \($0) restarts" : "" } ?? "")
                    ) { page.openFromOverview(kind: KubeResourceKind.pods.fullName, pod.id) }
                }
                ForEach(notReady, id: \.key) { item in
                    row(
                        symbol: "exclamationmark.circle.fill", tone: TabStatusStyle.waiting, title: "\(item.count.title.lowercased().dropLast())/\(item.id.name)",
                        namespace: item.id.namespace, detail: "not ready"
                    ) { page.openFromOverview(kind: item.count.resource, item.id) }
                }
                ForEach(overview.notReadyNodes, id: \.self) { node in
                    row(symbol: "server.rack", tone: TabStatusStyle.failed, title: "node/\(node)", namespace: nil, detail: "not ready") {
                        page.openFromOverview(kind: "nodes", KubeRowID(namespace: nil, name: node))
                    }
                }
                if !overview.warnings.isEmpty {
                    Text(verbatim: "Warning events, the last hour").font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.text2).padding(.top, 6)
                    ForEach(overview.warnings) { warning in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: warning.age.map(KubeAge.format) ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3)
                                .frame(width: 44, alignment: .trailing)
                            Text(verbatim: warning.reason).font(.system(size: 12, weight: .medium)).foregroundStyle(TabStatusStyle.waiting)
                            Text(verbatim: (warning.namespace.map { "\($0)/" } ?? "") + warning.object).font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
                            Text(verbatim: warning.message).font(.system(size: 12)).foregroundStyle(theme.text2).lineLimit(2).textSelection(.enabled)
                            if let count = warning.count, count > 1 {
                                Text(verbatim: "×\(count)").font(.system(size: 11)).foregroundStyle(theme.text3)
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("kubernetes.overview.attention")
        } else if session.state == .live {
            Label("Nothing fails: every pod, workload and node is fine, and no warning in the last hour.", systemImage: "checkmark.circle")
                .font(.system(size: 12)).foregroundStyle(TabStatusStyle.done)
                .accessibilityIdentifier("kubernetes.overview.fine")
        }
    }

    private func row(
        symbol: String, tone: Color, title: String, namespace: String?, detail: String, _ open: @escaping () -> Void
    ) -> some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(tone).frame(width: 16)
                Text(verbatim: (namespace.map { "\($0)/" } ?? "") + title).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.text)
                    .lineLimit(1).truncationMode(.middle)
                Text(verbatim: detail).font(.system(size: 12)).foregroundStyle(tone)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open its detail")
    }

    // MARK: Usage

    @ViewBuilder private var usage: some View {
        let note = model.metrics.note(.nodes)
        if let usage = page.clusterUsage {
            // The moment's; the charts under it have the history (X1, X2).
            let history = page.chartsFromPrometheus ? [] : page.clusterHistory
            VStack(alignment: .leading, spacing: 6) {
                caption("Usage")
                HStack(alignment: .top, spacing: 24) {
                    meter(
                        "CPU", used: KubeMetricsFormat.cpu(usage.used.cpu), of: usage.allocatable.map { KubeMetricsFormat.cpu($0.cpu) },
                        percent: KubeMetricsFormat.percent(usage.used.cpu, of: usage.allocatable?.cpu))
                    meter(
                        "Memory", used: KubeMetricsFormat.memory(usage.used.memory),
                        of: usage.allocatable.map { KubeMetricsFormat.memory($0.memory) },
                        percent: KubeMetricsFormat.percent(usage.used.memory, of: usage.allocatable?.memory))
                }
                if let span = KubeUsageRing.span(history) {
                    Text(verbatim: "Usage over \(span)").font(.system(size: 11)).foregroundStyle(theme.text3)
                        .accessibilityIdentifier("kubernetes.overview.usage.history")
                }
                if let note { Text(verbatim: note).font(.system(size: 11)).foregroundStyle(theme.text3) }
            }
            .accessibilityIdentifier("kubernetes.overview.usage")
        } else if let note {
            VStack(alignment: .leading, spacing: 4) {
                caption("Usage")
                Text(verbatim: note).font(.system(size: 11.5)).foregroundStyle(theme.text3).textSelection(.enabled)
                if model.metrics.isRefused(.nodes) {
                    Button("Try Again") { model.retry() }.buttonStyle(.plain).foregroundStyle(theme.accentText).font(.system(size: 11))
                        .help("Ask metrics-server again: access may have been granted since")
                        .accessibilityIdentifier("kubernetes.overview.usage.retry")
                }
            }
            .accessibilityIdentifier("kubernetes.overview.usage")
        }
    }

    private func meter(_ title: String, used: String, of total: String?, percent: Int?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title).font(.system(size: 11)).foregroundStyle(theme.text3)
            Text(verbatim: used + (total.map { " of \($0)" } ?? "") + (percent.map { " · \($0)%" } ?? ""))
                .font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(theme.text)
            if let percent {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.rowHover)
                        Capsule().fill(percent >= 90 ? TabStatusStyle.failed : percent >= 70 ? TabStatusStyle.waiting : TabStatusStyle.done)
                            .frame(width: geometry.size.width * CGFloat(min(100, percent)) / 100)
                    }
                }
                .frame(width: 180, height: 5)
            }
        }
    }

    // MARK: Counts

    @ViewBuilder private func counts(_ overview: KubeClusterOverview) -> some View {
        if session.state != .idle {
            VStack(alignment: .leading, spacing: 8) {
                caption("Workloads")
                HStack(alignment: .top, spacing: 12) {
                    tile("Pods", total: overview.pods, bad: overview.failingPods.count, badWord: "failing") {
                        page.showKind(.pods)
                    }
                    ForEach(overview.workloads) { count in
                        tile(count.title, total: count.total, bad: count.notReady.count, badWord: "not ready") {
                            if let kind = model.catalog.kind(fullName: count.resource) { page.showKind(kind) }
                        }
                    }
                    if overview.nodes > 0 {
                        tile("Nodes", total: overview.nodes, bad: overview.notReadyNodes.count, badWord: "not ready") {
                            if let kind = model.catalog.kind(fullName: "nodes") { page.showKind(kind) }
                        }
                    }
                }
                HStack(spacing: 14) {
                    ForEach(KubeClusterOverview.phases, id: \.self) { phase in
                        if let count = overview.phases[phase] {
                            HStack(spacing: 4) {
                                Circle().fill(color(phase)).frame(width: 7, height: 7)
                                Text(verbatim: "\(phase) \(count)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(theme.text2)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("kubernetes.overview.phases")
            }
            .accessibilityIdentifier("kubernetes.overview.counts")
        }
    }

    private func color(_ phase: String) -> Color {
        switch phase {
        case "Running": TabStatusStyle.done
        case "Pending": TabStatusStyle.waiting
        case "Failed", "Unknown": TabStatusStyle.failed
        default: theme.text3
        }
    }

    private func tile(_ title: String, total: Int, bad: Int, badWord: String, _ open: @escaping () -> Void) -> some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).font(.system(size: 11)).foregroundStyle(theme.text3)
                Text(verbatim: "\(total)").font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(theme.text)
                Text(verbatim: bad > 0 ? "\(bad) \(badWord)" : "all fine").font(.system(size: 11))
                    .foregroundStyle(bad > 0 ? TabStatusStyle.failed : theme.text3)
            }
            .padding(10)
            .frame(width: 118, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.rowHover.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the list")
    }

    // MARK: Applications

    @ViewBuilder private func applications(_ overview: KubeClusterOverview) -> some View {
        if !overview.systems.isEmpty || overview.unlabelled > 0 {
            VStack(alignment: .leading, spacing: 6) {
                caption("Applications")
                ForEach(overview.systems) { system in
                    if let partOf = system.partOf {
                        Text(verbatim: partOf).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text).padding(.top, 4)
                    }
                    ForEach(system.applications) { application in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(application.notReady > 0 ? TabStatusStyle.failed : TabStatusStyle.done).frame(width: 7, height: 7)
                            Text(verbatim: application.name).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text)
                            if let instance = application.instance, instance != application.name {
                                Text(verbatim: instance).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3)
                            }
                            if let namespace = application.namespace, model.scope.spansNamespaces {
                                Text(verbatim: namespace).font(.system(size: 11)).foregroundStyle(theme.text3)
                            }
                            Text(verbatim: application.members.map { "\($0.kind.resource.dropLast())/\($0.id.name)" }.joined(separator: ", "))
                                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(theme.text2).lineLimit(1).truncationMode(.tail)
                            if application.notReady > 0 {
                                Text(verbatim: "\(application.notReady) not ready").font(.system(size: 11)).foregroundStyle(TabStatusStyle.failed)
                            }
                        }
                        .padding(.leading, system.partOf == nil ? 0 : 12)
                    }
                }
                if overview.unlabelled > 0 {
                    Text(verbatim: "\(overview.unlabelled) workloads carry no app.kubernetes.io/name or instance label.")
                        .font(.system(size: 11)).foregroundStyle(theme.text3)
                }
            }
            .accessibilityIdentifier("kubernetes.overview.applications")
        }
    }
}

/// Samples drawn as a line, scaled to their own highest (a flat line at
/// the bottom when every one is zero); nothing with fewer than two.
struct KubeSparkline: View {
    var values: [Double]
    var color: Color

    var body: some View {
        if values.count >= 2 {
            GeometryReader { geometry in
                Path { path in
                    let top = max(values.max() ?? 0, .leastNonzeroMagnitude)
                    let step = geometry.size.width / CGFloat(values.count - 1)
                    for (index, value) in values.enumerated() {
                        let point = CGPoint(x: CGFloat(index) * step, y: geometry.size.height * (1 - CGFloat(value / top)))
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            }
            .accessibilityHidden(true)
        }
    }
}
