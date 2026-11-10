import SwiftUI

/// The Overview section (`1`), as cards: a header strip (the context, its
/// server's version, its nodes, whether it is live, the pills saying what
/// needs attention and what passes), a card a kind (pods, each workload
/// kind, the nodes — a press shows its list), what needs attention worst
/// first beside the usage of allocatable, the charts over time (X1–X4:
/// sampled, or from Prometheus), the health checks, the applications by
/// their recommended labels, the last hour's Warning events. Read only
/// while it shows (`KubeClusterOverviewSession`); this is presentation
/// only — every number comes from what the session, the metrics and the
/// health checks already hold. A row opens its object's detail. Narrow,
/// the cards stack in one column.
struct KubeClusterOverviewView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var session: KubeClusterOverviewSession
    @ObservedObject var model: KubernetesModel
    @ObservedObject var theme: ChromeTheme
    /// The page's width, for one column or two.
    @State private var width: CGFloat = 1000

    /// Below this the paired cards stack.
    static let twoColumns: CGFloat = 720
    /// The most rows the Needs-attention card lists; the lists have the rest.
    static let attentionShown = 12

    var body: some View {
        let overview = session.overview
        ScrollView {
            VStack(alignment: .leading, spacing: ResourceCard.spacing) {
                header(overview)
                KubePinnedHealthView(page: page, session: page.pinnedHealth, theme: theme)
                kinds(overview)
                KubeOverviewGitOpsCard(page: page, session: page.health, theme: theme)
                paired(overview)
                charts
                KubeOverviewHealthView(page: page, session: page.health, theme: theme)
                applications(overview)
                warnings(overview)
                if !session.problems.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ResourceCardCaption(text: "Not read", theme: theme)
                        ForEach(session.problems.sorted { $0.key.title < $1.key.title }, id: \.key) { part, why in
                            Text(verbatim: "\(part.title): \(why)").font(.system(size: 11.5)).foregroundStyle(theme.text3).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .resourceCard(theme)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("kubernetes.overview.problems")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { geometry in Color.clear.preference(key: KubeOverviewWidthKey.self, value: geometry.size.width) }
            )
        }
        .onPreferenceChange(KubeOverviewWidthKey.self) { value in
            MainActor.assumeIsolated { if abs(value - width) >= 1 { width = value } }
        }
        .background(Color(nsColor: GhosttyRuntime.shared.backgroundColor))
        .accessibilityIdentifier("kubernetes.overview")
    }

    private var wide: Bool { width >= Self.twoColumns }

    /// A tone's words: legible on the card in dark and light.
    private func words(_ tone: KubeOverviewCards.Tone) -> Color {
        switch tone {
        case .failed: TabStatusStyle.failed
        case .waiting: theme.orangeText
        case .done: theme.greenText
        case .neutral: theme.text2
        }
    }

    /// A tone's fill: a bar's, a dot's.
    private func fill(_ tone: KubeOverviewCards.Tone) -> Color {
        switch tone {
        case .failed: TabStatusStyle.failed
        case .waiting: TabStatusStyle.waiting
        case .done: TabStatusStyle.done
        case .neutral: theme.text3
        }
    }

    // MARK: The header

    /// The context, the server's version and its nodes (as discovery and
    /// the who-am-I read say them), live or reading, and the pills.
    private func header(_ overview: KubeClusterOverview) -> some View {
        let version = model.version.map { "Kubernetes \($0.gitVersion)" }
        let nodes = session.state == .idle ? nil : "\(overview.nodes) node\(overview.nodes == 1 ? "" : "s")"
        let context = model.selected
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: context?.displayName ?? model.selectedName ?? "Overview")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(context?.isProduction == true ? KubernetesPageView.production : theme.text)
                    .lineLimit(1).truncationMode(.middle)
                Text(verbatim: model.scope.title).font(.system(size: 13)).foregroundStyle(theme.text3).lineLimit(1)
                Spacer(minLength: 8)
                state
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    facts(version, nodes)
                    Spacer(minLength: 8)
                    pills(overview)
                }
                VStack(alignment: .leading, spacing: 6) {
                    facts(version, nodes)
                    pills(overview)
                }
            }
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder private func facts(_ version: String?, _ nodes: String?) -> some View {
        if version != nil || nodes != nil {
            Text(verbatim: [version, nodes].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text2).textSelection(.enabled).lineLimit(1)
                .accessibilityIdentifier("kubernetes.overview.version")
        }
    }

    private func pills(_ overview: KubeClusterOverview) -> some View {
        KubeOverviewHeaderPills(overview: overview, health: page.health, theme: theme)
    }

    /// Live, or reading.
    @ViewBuilder private var state: some View {
        switch session.state {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(verbatim: "Reading the cluster…").font(.system(size: 11.5)).foregroundStyle(theme.text3)
            }
        case .live:
            HStack(spacing: 5) {
                Circle().fill(TabStatusStyle.done).frame(width: 7, height: 7)
                Text(verbatim: "Live").font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.text2)
            }
            .help("Followed while the Overview shows")
        case .idle:
            EmptyView()
        }
    }

    // MARK: A card a kind

    @ViewBuilder private func kinds(_ overview: KubeClusterOverview) -> some View {
        if session.state != .idle {
            VStack(alignment: .leading, spacing: 8) {
                let kinds = KubeOverviewCards.kinds(overview)
                // As many across as fit at 150 pt or more, the row filled.
                let across = KubeOverviewCards.columns(count: kinds.count, width: width - 40, minimum: 150, spacing: 12)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: across), alignment: .leading, spacing: 12) {
                    ForEach(kinds) { kind in kindCard(kind) }
                }
                phases(overview)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kubernetes.overview.counts")
        }
    }

    private func kindCard(_ kind: KubeOverviewCards.Kind) -> some View {
        let worst = kind.bar.map(\.tone).max() ?? .neutral
        return KubeOverviewKindCard(theme: theme) {
            if kind.resource == KubeResourceKind.pods.fullName {
                page.showKind(.pods)
            } else if let found = model.catalog.kind(fullName: kind.resource) {
                page.showKind(found)
            }
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(verbatim: kind.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.text2)
                    Spacer(minLength: 0)
                    if worst == .failed || worst == .waiting {
                        Circle().fill(fill(worst)).frame(width: 7, height: 7)
                    }
                }
                Text(verbatim: "\(kind.total)").font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(theme.text)
                    .monospacedDigit()
                KubeOverviewBar(segments: kind.bar.map { (fill($0.tone), $0.count) }, track: theme.rowHover)
                    .frame(height: 4)
                Text(verbatim: kind.line).font(.system(size: 11)).foregroundStyle(worst == .failed ? words(.failed) : theme.text3)
                    .lineLimit(2, reservesSpace: true).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
            }
        }
        .help("Show the \(kind.title) list")
    }

    /// Pods by the server's phase, as a legend under the cards.
    private func phases(_ overview: KubeClusterOverview) -> some View {
        HStack(spacing: 14) {
            Text(verbatim: "Pods by phase").font(.system(size: 11)).foregroundStyle(theme.text3)
            ForEach(KubeClusterOverview.phases, id: \.self) { phase in
                if let count = overview.phases[phase] {
                    HStack(spacing: 5) {
                        Circle().fill(color(phase)).frame(width: 7, height: 7)
                        Text(verbatim: "\(phase) \(count)").font(.system(size: 11.5)).foregroundStyle(theme.text2).monospacedDigit()
                    }
                }
            }
        }
        .padding(.leading, 2)
        .accessibilityIdentifier("kubernetes.overview.phases")
    }

    private func color(_ phase: String) -> Color {
        switch phase {
        case "Running": TabStatusStyle.done
        case "Pending": TabStatusStyle.waiting
        case "Failed", "Unknown": TabStatusStyle.failed
        default: theme.text3
        }
    }

    // MARK: What needs attention, beside the usage

    @ViewBuilder private func paired(_ overview: KubeClusterOverview) -> some View {
        let attention = attentionCard(overview)
        let usage = usageCard
        if wide {
            HStack(alignment: .top, spacing: ResourceCard.spacing) {
                attention.frame(maxWidth: .infinity, alignment: .top)
                usage.frame(maxWidth: .infinity, alignment: .top)
            }
        } else {
            VStack(alignment: .leading, spacing: ResourceCard.spacing) {
                attention
                usage
            }
        }
    }

    @ViewBuilder private func attentionCard(_ overview: KubeClusterOverview) -> some View {
        if overview.problems > 0 || !overview.warnings.isEmpty {
            let rows = KubeOverviewCards.attention(overview)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(verbatim: "Needs attention").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                    if !rows.isEmpty {
                        Text(verbatim: "\(rows.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(words(.failed))
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(TabStatusStyle.failed.opacity(0.14)))
                    }
                    Spacer(minLength: 0)
                }
                if rows.isEmpty {
                    Label("No pod, workload or node failing — only warning events, below.", systemImage: "checkmark.circle")
                        .font(.system(size: 12)).foregroundStyle(theme.text2)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(rows.prefix(Self.attentionShown)) { row in attentionRow(row) }
                    }
                    .padding(.horizontal, -8)
                    if rows.count > Self.attentionShown {
                        Text(verbatim: "and \(rows.count - Self.attentionShown) more — the lists have them all").font(.system(size: 11)).foregroundStyle(theme.text3)
                    }
                }
            }
            .resourceCard(theme, tint: rows.isEmpty ? nil : TabStatusStyle.failed.opacity(0.6))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kubernetes.overview.attention")
        } else if session.state == .live {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 20)).foregroundStyle(TabStatusStyle.done)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "All fine").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                    Text(verbatim: "Nothing fails: every pod, workload and node is fine, and no warning in the last hour.")
                        .font(.system(size: 12)).foregroundStyle(theme.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .resourceCard(theme)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("kubernetes.overview.fine")
        }
    }

    private func attentionRow(_ row: KubeOverviewCards.Attention) -> some View {
        ResourceCardRow(theme: theme, help: "Open its detail") {
            page.openFromOverview(kind: row.resource, row.row)
        } content: {
            HStack(spacing: 8) {
                Image(systemName: row.symbol).font(.system(size: 11.5)).foregroundStyle(fill(row.tone)).frame(width: 16)
                Text(verbatim: row.title).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.text)
                    .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                if let namespace = row.namespace {
                    Text(verbatim: namespace).font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 6)
                ResourcePill(text: row.pill, colour: words(row.tone))
            }
        }
    }

    /// The cluster's CPU and memory against its nodes' allocatable, from
    /// metrics-server's sample, with the samples taken while shown.
    @ViewBuilder private var usageCard: some View {
        let note = model.metrics.note(.nodes)
        if let usage = page.clusterUsage {
            // The moment's; the charts under it have the history (X1, X2).
            let history = page.chartsFromPrometheus ? [] : page.clusterHistory
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: "Usage of allocatable").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                HStack(alignment: .top, spacing: 18) {
                    meter(
                        "CPU", used: KubeMetricsFormat.cpu(usage.used.cpu), of: usage.allocatable.map { KubeMetricsFormat.cpu($0.cpu) },
                        percent: KubeMetricsFormat.percent(usage.used.cpu, of: usage.allocatable?.cpu), history: history.map(\.usage.cpu),
                        top: usage.allocatable?.cpu)
                    meter(
                        "Memory", used: KubeMetricsFormat.memory(usage.used.memory),
                        of: usage.allocatable.map { KubeMetricsFormat.memory($0.memory) },
                        percent: KubeMetricsFormat.percent(usage.used.memory, of: usage.allocatable?.memory), history: history.map(\.usage.memory),
                        top: usage.allocatable?.memory)
                }
                if let span = KubeUsageRing.span(history) {
                    Text(verbatim: "Usage over \(span)").font(.system(size: 11)).foregroundStyle(theme.text3)
                        .accessibilityIdentifier("kubernetes.overview.usage.history")
                }
                if let note { Text(verbatim: note).font(.system(size: 11)).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true) }
            }
            .resourceCard(theme)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kubernetes.overview.usage")
        } else if let note {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "Usage of allocatable").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                Text(verbatim: note).font(.system(size: 11.5)).foregroundStyle(theme.text3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if model.metrics.isRefused(.nodes) {
                    Button("Try Again") { model.retry() }.buttonStyle(.plain).foregroundStyle(theme.accentText).font(.system(size: 11.5, weight: .medium))
                        .help("Ask metrics-server again: access may have been granted since")
                        .accessibilityIdentifier("kubernetes.overview.usage.retry")
                }
            }
            .resourceCard(theme)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kubernetes.overview.usage")
        }
    }

    /// A share now, its bar, and the samples since shown drawn against `top` (allocatable).
    private func meter(_ title: String, used: String, of total: String?, percent: Int?, history: [Double], top: Double?) -> some View {
        let tone = percent.map(KubeOverviewCards.usageTone) ?? .neutral
        return VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.text2)
            Text(verbatim: percent.map { "\($0)%" } ?? used)
                .font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(percent == nil ? theme.text : words(tone))
                .monospacedDigit()
            if let percent {
                KubeOverviewBar(segments: [(fill(tone), percent), (.clear, max(0, 100 - percent))], track: theme.rowHover).frame(height: 5)
            }
            Text(verbatim: used + (total.map { " of \($0)" } ?? ""))
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(theme.text2).lineLimit(1).minimumScaleFactor(0.8)
            if history.count >= 2 {
                KubeSparkline(values: history, color: theme.accentText, top: top).frame(height: 28).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The charts

    /// X1–X4: over the range from Prometheus where it is found, else sampled while shown.
    @ViewBuilder private var charts: some View {
        if page.chartsFromPrometheus {
            KubePrometheusChartView(page: page, monitor: model.prometheus, chart: .cluster, theme: theme).resourceCard(theme)
        } else {
            KubeClusterSampledView(page: page, metrics: model.metrics, theme: theme)
            if page.prometheusOn {
                KubePrometheusChartView(page: page, monitor: model.prometheus, chart: .cluster, theme: theme).resourceCard(theme)
            }
        }
    }

    // MARK: Applications

    @ViewBuilder private func applications(_ overview: KubeClusterOverview) -> some View {
        if !overview.systems.isEmpty || overview.unlabelled > 0 {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(verbatim: "Applications").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                    Text(verbatim: "by app.kubernetes.io labels").font(.system(size: 11)).foregroundStyle(theme.text3)
                }
                ForEach(overview.systems) { system in
                    VStack(alignment: .leading, spacing: 6) {
                        if let partOf = system.partOf {
                            Text(verbatim: partOf).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(theme.text2)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                            ForEach(system.applications) { application in applicationCard(application) }
                        }
                    }
                }
                if overview.unlabelled > 0 {
                    Text(verbatim: "\(overview.unlabelled) workloads carry no app.kubernetes.io/name or instance label.")
                        .font(.system(size: 11)).foregroundStyle(theme.text3)
                }
            }
            .resourceCard(theme)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kubernetes.overview.applications")
        }
    }

    private func applicationCard(_ application: KubeApplications.Application) -> some View {
        let notReady = application.notReady
        let tone: KubeOverviewCards.Tone = notReady > 0 ? .failed : .done
        let members = application.members.map { "\($0.kind.resource.dropLast())/\($0.id.name)" }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(fill(tone)).frame(width: 7, height: 7)
                Text(verbatim: application.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: notReady > 0 ? "\(notReady) not ready" : "ready").font(.system(size: 11, weight: .medium)).foregroundStyle(words(tone))
            }
            let place = [
                application.instance.flatMap { $0 == application.name ? nil : $0 },
                model.scope.spansNamespaces ? application.namespace : nil,
            ]
            .compactMap { $0 }
            Text(verbatim: (place + ["\(members.count) workload\(members.count == 1 ? "" : "s")"]).joined(separator: " · "))
                .font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1)
            Text(verbatim: members.joined(separator: ", ")).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text2)
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.rowHover))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(notReady > 0 ? TabStatusStyle.failed.opacity(0.75) : theme.border, lineWidth: notReady > 0 ? 1.25 : 1)
        )
        .help(members.joined(separator: "\n"))
    }

    // MARK: Warning events

    @ViewBuilder private func warnings(_ overview: KubeClusterOverview) -> some View {
        if !overview.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(verbatim: "Warning events").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                    Text(verbatim: "the last hour").font(.system(size: 11)).foregroundStyle(theme.text3)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(overview.warnings.enumerated()), id: \.element.id) { index, warning in
                        if index > 0 { Rectangle().fill(theme.border).frame(height: 1) }
                        warningRow(warning)
                    }
                }
            }
            .resourceCard(theme)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kubernetes.overview.warnings")
        }
    }

    private func warningRow(_ warning: KubeClusterOverview.Warning) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: warning.age.map(KubeAge.format) ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3)
                .frame(width: 44, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    ResourcePill(text: warning.reason, colour: words(.waiting))
                    Text(verbatim: (warning.namespace.map { "\($0)/" } ?? "") + warning.object).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let count = warning.count, count > 1 {
                        Text(verbatim: "×\(count)").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.text3).monospacedDigit()
                    }
                }
                Text(verbatim: warning.message).font(.system(size: 12)).foregroundStyle(theme.text2).lineLimit(2).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 7)
    }
}

/// The page's width, measured once at the Overview's top.
private struct KubeOverviewWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A kind's card on the Overview: a button showing its list, lit under the pointer.
private struct KubeOverviewKindCard<Content: View>: View {
    @ObservedObject var theme: ChromeTheme
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            content()
                .resourceCard(theme, padding: 12)
                .overlay(RoundedRectangle(cornerRadius: ResourceCard.radius, style: .continuous).fill(hovered ? theme.rowHover : .clear).allowsHitTesting(false))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// A thin bar of parts in proportion (ready, pending, failing), over its track.
struct KubeOverviewBar: View {
    var segments: [(colour: Color, count: Int)]
    var track: Color

    var body: some View {
        GeometryReader { geometry in
            let total = max(1, segments.reduce(0) { $0 + $1.count })
            HStack(spacing: segments.filter { $0.count > 0 }.count > 1 ? 1.5 : 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    if segment.count > 0 {
                        Rectangle().fill(segment.colour)
                            .frame(width: max(2, geometry.size.width * CGFloat(segment.count) / CGFloat(total)))
                    }
                }
            }
            .frame(width: geometry.size.width, alignment: .leading)
            .background(track)
            .clipShape(Capsule())
        }
        .accessibilityHidden(true)
    }
}

/// Samples drawn as a line, scaled to `top` or their own highest (a
/// flat line at the bottom when every one is zero); nothing with fewer than two.
struct KubeSparkline: View {
    var values: [Double]
    var color: Color
    /// The line's ceiling (allocatable), else the samples' own highest.
    var top: Double?

    var body: some View {
        if values.count >= 2 {
            GeometryReader { geometry in
                Path { path in
                    let top = max(top ?? 0, values.max() ?? 0, .leastNonzeroMagnitude)
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

/// The header's pills: what needs attention, the health checks' count and
/// the checks that pass. Its own view, observing the health session — the
/// page doesn't republish it, so the pills follow its read and its refresh.
struct KubeOverviewHeaderPills: View {
    let overview: KubeClusterOverview
    @ObservedObject var health: KubeHealthSession
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        HStack(spacing: 6) {
            let pills = KubeOverviewCards.pills(overview, health: health.state == .loaded ? health.report : nil)
            if let attention = pills.first(where: { $0.tone == .failed }) {
                ResourcePill(text: attention.text, colour: TabStatusStyle.failed, symbol: "exclamationmark.triangle.fill")
            }
            // The health checks' count, where it is seen first; the findings below.
            KubeHealthCount(session: health, theme: theme)
            if let passing = pills.first(where: { $0.tone == .done }) {
                ResourcePill(text: passing.text, colour: theme.greenText, symbol: "checkmark")
                    .accessibilityIdentifier("kubernetes.overview.passing")
            }
        }
    }
}

/// The Overview's GitOps line (docs/design/kubernetes/gitops.md, 2.1) as a
/// card: what Argo CD and Flux say of what lives in the scope, a pill a
/// count, from the health checks already read (K601–K603) — no read of its
/// own. A press goes to the GitOps section (`g`), which counts what lives
/// in or deploys into the scope.
struct KubeOverviewGitOpsCard: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var session: KubeHealthSession
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        if session.state == .loaded, let line = KubeOverviewCards.gitOps(session.report, scope: session.scope) {
            let tint = line.tone == .failed ? TabStatusStyle.failed : TabStatusStyle.waiting
            Button {
                page.showSection(.gitops)
                page.giveListTheKeyboard()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: KubeSection.gitops.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text2)
                    Text(verbatim: line.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                    ForEach(line.counts, id: \.text) { pill in
                        ResourcePill(text: pill.text, colour: pill.tone == .failed ? TabStatusStyle.failed : theme.orangeText)
                    }
                    Spacer(minLength: 8)
                    Text(verbatim: "press \(KubeSection.gitops.key) for what deploys here").font(.system(size: 11.5)).foregroundStyle(theme.text3)
                        .lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.text3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .resourceCard(theme, tint: tint.opacity(0.6), padding: 12)
            .help("From the health checks: Argo CD's failed (K602), drifted or stuck (K603), Flux's not ready (K601) — what lives here. GitOps (g) shows what lives in or deploys into the scope.")
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: line.text))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("kubernetes.overview.gitops")
        }
    }
}
