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
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: "Cluster usage").font(.system(size: ChromeMetrics.text(13), weight: .semibold)).foregroundStyle(theme.text)
                // Side by side where they fit, else one under the other.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) { sampled(charts) }
                    VStack(alignment: .leading, spacing: 14) { sampled(charts) }
                }
                Text(verbatim: page.sampledClusterCaption()).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3)
                    .accessibilityIdentifier("kubernetes.overview.usage.caption")
                Text(verbatim: KubeChartEmpty.requestsNeedSpecs.sentence).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3)
                let nodes = page.sampledNodeRows()
                KubeNodeStripsView(
                    page: page, rows: nodes.rows, more: nodes.more, caption: "Nodes, the last 15 min of allocatable — sampled while shown", theme: theme
                )
                .padding(.top, 4)
            }
            .resourceCard(theme)
            .accessibilityIdentifier("kubernetes.overview.sampled")
        }
    }

    private func sampled(_ charts: [KubePodCharts.Chart]) -> some View {
        ForEach(charts) { chart in
            KubeChartView(
                data: chart.data, cursor: cursor, headline: chart.headline, span: "last 10 min", chips: chart.chips,
                copy: { [weak page] in page?.copyChartText($0) }, theme: theme
            )
            .frame(minWidth: 200, maxWidth: .infinity)
        }
    }
}

/// X4: the nodes as small multiples — a row each, its CPU's and memory's
/// 60 cells of its allocatable, the share now — the hottest 50 past that
/// many, by name; a row's name opens the node's Metrics tab. Drawn in one
/// Canvas (`KubeNodeStripsLayout`): fifty rows of views — a button, two
/// strips, their numbers — took the Overview's first draw past its 50 ms
/// (metrics.md 5.3, M12). Each strip's summary is the hover's label and
/// VoiceOver's, every row an accessibility element of its own.
struct KubeNodeStripsView: View {
    @ObservedObject var page: KubernetesPageModel
    var rows: [KubeNodeStripRow]
    var more: Int
    var caption: String
    @ObservedObject var theme: ChromeTheme
    @State private var token = UUID()
    /// What the pointer is over — held, not observed: only the hover's label redraws.
    @State private var hover = KubeNodeStripsHover()

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: caption).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3)
                // Its rows are as wide as their strips: a narrow card scrolls them, the page never.
                ViewThatFits(in: .horizontal) {
                    grid
                    ScrollView(.horizontal, showsIndicators: false) { grid }
                }
                if more > 0 {
                    Text(verbatim: "The 50 most used of \(rows.count + more) nodes; the rest are in the Nodes list.").font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3)
                }
            }
            .accessibilityIdentifier("kubernetes.overview.nodes")
            .onAppear { register(rows) }
            .onChange(of: rows) { register($0) }
            .onChange(of: ObjectIdentifier(theme)) { _ in register(rows) }
            .onDisappear { KubeHeatStripRegistry.shared.hide(token) }
        }
    }

    private var grid: some View {
        let rows = rows
        let layout = KubeNodeStripsLayout(count: rows.count)
        let dark = theme.isDark
        let colours = KubeHeatStrip.Level.allCases.map { KubeChartPalette.heat($0, dark: dark).color }
        let track = theme.text3
        let label = theme.text3
        let name = theme.accentText
        let value = theme.text2
        return Canvas { context, _ in
            context.draw(Text(verbatim: "CPU").font(.system(size: ChromeMetrics.text(10))).foregroundColor(label), at: CGPoint(x: layout.strip(.cpu).minX, y: layout.height(0) / 2), anchor: .leading)
            context.draw(
                Text(verbatim: "Memory").font(.system(size: ChromeMetrics.text(10))).foregroundColor(label), at: CGPoint(x: layout.strip(.memory).minX, y: layout.height(0) / 2), anchor: .leading)
            let fits = KubeNodeStripsLayout.fits(context.resolve(Self.name("M", name)).measure(in: CGSize(width: 100, height: 100)).width)
            for (index, row) in rows.enumerated() {
                let mid = layout.mid(index)
                context.draw(Self.name(KubeNodeStripsLayout.middleCut(row.node, fits: fits), name), at: CGPoint(x: 0, y: mid), anchor: .leading)
                for measure in [KubeUsageCell.Measure.cpu, .memory] {
                    let frame = layout.strip(measure, row: index)
                    guard let strip = measure == .cpu ? row.cpu : row.memory else {
                        context.draw(Text(verbatim: "–").font(.system(size: ChromeMetrics.text(11))).foregroundColor(label), at: CGPoint(x: frame.minX, y: mid), anchor: .leading)
                        continue
                    }
                    KubeHeatStripView.draw(strip.percents, in: frame, context: &context, colours: colours, track: track)
                    let share = strip.now.map { "\(Int($0.rounded()))%" } ?? "–"
                    context.draw(
                        Text(verbatim: share).font(.system(size: ChromeMetrics.text(11), design: .monospaced)).foregroundColor(value),
                        at: CGPoint(x: frame.maxX + KubeNodeStripsLayout.shareWidth + 5, y: mid), anchor: .trailing)
                }
            }
        }
        .frame(width: layout.width, height: layout.height(rows.count), alignment: .topLeading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hover.set(layout.hit(point, rows: rows.count))
            case .ended: hover.set(nil)
            }
        }
        .onTapGesture { point in
            if let hit = layout.hit(point, rows: rows.count), hit.measure == nil { page.openNodeMetrics(rows[hit.row].node) }
        }
        .overlay(alignment: .topLeading) { KubeNodeStripsHoverLabel(hover: hover, rows: rows, layout: layout, theme: theme) }
        .accessibilityElement(children: .contain)
        .accessibilityChildren {
            VStack(alignment: .leading) {
                ForEach(rows) { row in
                    HStack {
                        Button(row.node) { page.openNodeMetrics(row.node) }
                            .accessibilityHint(Text(verbatim: "Opens the node's Metrics tab"))
                        ForEach([KubeUsageCell.Measure.cpu, .memory], id: \.self) { measure in
                            if let strip = measure == .cpu ? row.cpu : row.memory {
                                Rectangle().accessibilityLabel(Text(verbatim: strip.summary()))
                                    .accessibilityIdentifier(KubeClusterCharts.stripIdentifier(row.node, measure))
                            }
                        }
                    }
                }
            }
        }
    }

    private static func name(_ text: String, _ colour: Color) -> Text {
        Text(verbatim: text).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced)).foregroundColor(colour)
    }

    /// Every strip drawn, said to the registry the scenario and the layout dump read.
    private func register(_ rows: [KubeNodeStripRow]) {
        let strips = rows.flatMap { row in
            [(KubeUsageCell.Measure.cpu, row.cpu), (.memory, row.memory)].compactMap { measure, strip in
                strip.map { (identifier: KubeClusterCharts.stripIdentifier(row.node, measure), strip: $0) }
            }
        }
        KubeHeatStripRegistry.shared.show(strips, token: token, window: ObjectIdentifier(theme))
    }
}

/// Where X4's rows and strips are in its Canvas, and what a point is over. Pure.
struct KubeNodeStripsLayout: Equatable {
    var count: Int

    static let nameWidth: CGFloat = 220
    static let rowHeight: CGFloat = 18
    static let shareWidth: CGFloat = 36
    static let gap: CGFloat = 10
    /// A strip, the gap before its share, its share.
    static let column = KubeHeatStripView.width + 5 + shareWidth

    var width: CGFloat { Self.nameWidth + 2 * (Self.gap + Self.column) }
    /// The header and `rows` rows.
    func height(_ rows: Int) -> CGFloat { CGFloat(rows + 1) * Self.rowHeight }
    /// A row's middle (row 0 is the first node's, under the header).
    func mid(_ row: Int) -> CGFloat { CGFloat(row + 1) * Self.rowHeight + Self.rowHeight / 2 }

    /// A measure's column: the header's.
    func strip(_ measure: KubeUsageCell.Measure) -> CGRect {
        let x = Self.nameWidth + Self.gap + (measure == .cpu ? 0 : Self.column + Self.gap)
        return CGRect(x: x, y: 0, width: KubeHeatStripView.width, height: KubeHeatStripView.height)
    }

    /// A row's strip of a measure.
    func strip(_ measure: KubeUsageCell.Measure, row: Int) -> CGRect {
        var frame = strip(measure)
        frame.origin.y = mid(row) - KubeHeatStripView.height / 2
        return frame
    }

    /// What a point is over: a row's name (no measure) or one of its strips.
    func hit(_ point: CGPoint, rows: Int) -> (row: Int, measure: KubeUsageCell.Measure?)? {
        let row = Int((point.y / Self.rowHeight).rounded(.down)) - 1
        guard row >= 0, row < min(rows, count), point.x >= 0 else { return nil }
        if point.x < Self.nameWidth { return (row, nil) }
        for measure in [KubeUsageCell.Measure.cpu, .memory] {
            let column = strip(measure)
            if point.x >= column.minX, point.x < column.minX + Self.column { return (row, measure) }
        }
        return nil
    }

    /// How many characters of a monospaced name fit the names' column, one being `advance` wide.
    static func fits(_ advance: CGFloat) -> Int { advance > 0 ? max(4, Int((nameWidth - 4) / advance)) : 32 }

    /// A name cut in its middle to `fits` characters: `ip-10-0-1…compute.internal`.
    static func middleCut(_ name: String, fits: Int) -> String {
        guard name.count > fits else { return name }
        let kept = fits - 1
        return String(name.prefix((kept + 1) / 2)) + "…" + String(name.suffix(kept / 2))
    }
}

/// What X4's pointer is over: only `KubeNodeStripsHoverLabel` observes it.
@MainActor
final class KubeNodeStripsHover: ObservableObject {
    @Published private(set) var at: (row: Int, measure: KubeUsageCell.Measure?)?

    /// The same place again isn't a change.
    func set(_ next: (row: Int, measure: KubeUsageCell.Measure?)?) {
        if next?.row != at?.row || next?.measure != at?.measure { at = next }
    }
}

/// The hovered strip's summary, or what a row's name does, by the pointer.
private struct KubeNodeStripsHoverLabel: View {
    @ObservedObject var hover: KubeNodeStripsHover
    var rows: [KubeNodeStripRow]
    var layout: KubeNodeStripsLayout
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        if let at = hover.at, at.row < rows.count {
            let row = rows[at.row]
            let text: String? =
                switch at.measure {
                case .none: "\(row.node) — open the node's Metrics tab"
                case .cpu?: row.cpu?.summary()
                case .memory?: row.memory?.summary()
                }
            if let text {
                Text(verbatim: text).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(theme.menu).shadow(color: theme.cardShadow, radius: 2))
                    .fixedSize()
                    .offset(x: at.measure.map { layout.strip($0).minX } ?? 0, y: layout.mid(at.row) + KubeNodeStripsLayout.rowHeight / 2 + 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
