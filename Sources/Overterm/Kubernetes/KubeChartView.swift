import Accessibility
import AppKit
import SwiftUI
import os

/// The hovered time a scope's charts share — a Metrics tab, an Overview,
/// an expanded chart: every chart in it draws the crosshair there, the one
/// under the mouse its tooltip (metrics.md, 3.1). Only `KubeChartOverlay`
/// observes it, so a move redraws the overlays and nothing else.
@MainActor
final class KubeChartCursor: ObservableObject {
    struct Hover: Equatable {
        var time: Date
        /// The chart under the mouse (its identifier): the one that shows the tooltip.
        var owner: String
    }

    @Published private(set) var hover: Hover?

    /// A drag across a chart, while it goes: the band every chart of the scope draws.
    struct Selection: Equatable {
        var from: Date
        var to: Date
        var owner: String
    }

    @Published private(set) var selection: Selection?

    func select(from: Date, to: Date, owner: String) {
        let next = Selection(from: from, to: to, owner: owner)
        if next != selection { selection = next }
    }

    func endSelection() {
        if selection != nil { selection = nil }
    }

    func move(to time: Date?, owner: String) {
        let next = time.map { Hover(time: $0, owner: owner) }
        if next != hover { hover = next }
    }

    func leave(_ owner: String) {
        if hover?.owner == owner { hover = nil }
    }
}

/// How often each chart's two layers were drawn, by identifier and by
/// the window it is in (its `ChromeTheme`, one a window): the series layer
/// (`KubeChartView`'s Canvas), the overlay, the tooltip (the overlay
/// drawn on the chart under the mouse), and the body of the view that
/// holds the cursor (`KubePrometheusChartView`) — what `kubernetesPerf`
/// and `kubernetesPrometheus` read to show a hover redraws only the
/// overlays, and the tooltip only on the chart hovered.
final class KubeChartDraws: Sendable {
    static let shared = KubeChartDraws()

    struct Counts: Equatable, Sendable {
        var series = 0
        var overlay = 0
        var tooltip = 0
        /// The body of the view holding the charts and their cursor (keyed by its own identifier).
        var container = 0

        static func + (a: Counts, b: Counts) -> Counts {
            Counts(series: a.series + b.series, overlay: a.overlay + b.overlay, tooltip: a.tooltip + b.tooltip, container: a.container + b.container)
        }
    }

    private struct Key: Hashable, Sendable {
        var id: String
        var window: ObjectIdentifier
    }

    private let counts = OSAllocatedUnfairLock<[Key: Counts]>(initialState: [:])

    func drew(_ id: String, window: ObjectIdentifier, overlay: Bool, tooltip: Bool = false) {
        counts.withLock { counts in
            let key = Key(id: id, window: window)
            if overlay { counts[key, default: Counts()].overlay += 1 } else { counts[key, default: Counts()].series += 1 }
            if tooltip { counts[key, default: Counts()].tooltip += 1 }
        }
    }

    func composed(_ id: String, window: ObjectIdentifier) {
        counts.withLock { $0[Key(id: id, window: window), default: Counts()].container += 1 }
    }

    /// One window's counts, or every window's added up.
    func of(_ id: String, in window: ObjectIdentifier? = nil) -> Counts {
        counts.withLock { counts in
            counts.filter { $0.key.id == id && (window == nil || $0.key.window == window) }.values.reduce(Counts(), +)
        }
    }
}

/// A chart's plot for the size it is shown at: built off the main thread
/// whenever the key (`data.version`, the size, the series hidden) changes,
/// published in one assignment.
@MainActor
final class KubeChartState: ObservableObject {
    @Published private(set) var plot: KubePlot?
    private var wanted: KubePlot.Key?
    private var building: Task<Void, Never>?

    func want(_ data: KubeChartData, size: CGSize, hidden: Set<String>, hideReferences: Bool) {
        guard size.width > 1, size.height > 1 else { return }
        let key = KubePlot.Key(
            version: data.version, width: Int(size.width.rounded()), height: Int(size.height.rounded()), hidden: hidden, hideReferences: hideReferences)
        guard key != wanted else { return }
        wanted = key
        building?.cancel()
        if plot?.key == key { return }
        building = Task { [weak self] in
            let plot = await Self.build(data, size: size, hidden: hidden, hideReferences: hideReferences)
            guard let self, !Task.isCancelled, self.wanted == key else { return }
            self.plot = plot
        }
    }

    nonisolated static func build(_ data: KubeChartData, size: CGSize, hidden: Set<String>, hideReferences: Bool) async -> KubePlot {
        await Task.detached(priority: .userInitiated) {
            KubePlot(data, size: size, hidden: hidden, hideReferences: hideReferences)
        }.value
    }
}

/// The charts on screen with their plots: what `OVERTERM_DUMP_LAYOUT`
/// prints of a window's (`KubeChartSummary.dump`) and what the scenarios
/// read — a chart is in it from its appearing to its disappearing. Each
/// chart view is its own entry (its token): two windows' Overviews both
/// show `kubernetes.chart.cluster.cpu`, and on a detail switch SwiftUI may
/// show the new view before the old one goes — one's going never takes
/// the other's entry with it.
@MainActor
final class KubeChartRegistry {
    static let shared = KubeChartRegistry()

    struct Shown {
        var data: KubeChartData
        var plot: KubePlot?
        /// The window it is in, by its `ChromeTheme` (one a window).
        var window: ObjectIdentifier
        /// The crosshair it shares with its scope's other charts.
        var cursor: KubeChartCursor
    }

    private var entries: [UUID: Shown] = [:]

    func show(_ data: KubeChartData, plot: KubePlot?, token: UUID, window: ObjectIdentifier, cursor: KubeChartCursor) {
        entries[token] = Shown(data: data, plot: plot, window: window, cursor: cursor)
    }

    func hide(_ token: UUID) { entries[token] = nil }

    /// The chart of that identifier on screen — in that window, or in any.
    func chart(_ identifier: String, in window: ObjectIdentifier? = nil) -> Shown? {
        entries.values.first { $0.data.identifier == identifier && (window == nil || $0.window == window) }
    }

    /// The dump's lines of one window's charts, or of every window's.
    func lines(in window: ObjectIdentifier? = nil) -> [String] {
        entries.values.filter { window == nil || $0.window == window }
            .sorted { $0.data.identifier < $1.data.identifier }
            .map { KubeChartSummary.dump($0.data, plot: $0.plot) }
    }

    /// The tooltip a chart would show at `time`.
    func tooltip(_ identifier: String, in window: ObjectIdentifier? = nil, at time: Date) -> KubeChartTooltip? {
        guard let shown = chart(identifier, in: window), let plot = shown.plot else { return nil }
        return KubeChartTooltip.at(time, plot: plot, step: shown.data.step)
    }
}

extension KubeChartPalette.RGB {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
}

/// One chart: its header (title, latest value, legend), the plot drawn in
/// one Canvas pass from a `KubePlot`, the y labels in its gutter, the
/// reference lines' labels at their right ends, the time axis under it,
/// and the overlay over it. It doesn't observe the cursor; hovering it
/// moves the cursor (`onContinuousHover`, the nearest point by binary
/// search). The legend isolates a series with a click, adds or removes
/// one with ⌘-click, dims the others while hovered; "Lines" toggles the
/// reference lines together (metrics.md, 3.6, 5.2).
struct KubeChartView: View {
    var data: KubeChartData
    let cursor: KubeChartCursor
    /// How it is said beside the title; nil, the latest value.
    var headline: String?
    /// "last 1h", for its accessibility summary.
    var span: String
    var height: CGFloat = 120
    /// What the header says beside the value: `48% of request`, red when it warns.
    var chips: [KubeChartChip] = []
    /// A marker's popover's button: what it opens (a restart's previous log,
    /// a change's diff, an event); nil, its popover only says what it is.
    var openMarker: ((KubeChartMarker) -> Void)? = nil
    /// ⌥-click, or the popover's "Show ±30 min": the tab's window around it; nil, not offered.
    var showAround: ((KubeChartMarker) -> Void)? = nil
    /// The context menu's "Logs from here", at the crosshair's time; nil, no such item.
    var logsFromHere: ((Date) -> Void)? = nil
    /// A drag across the plot released: the window from one time to the
    /// other (metrics.md 3.3) — every chart of the tab moves to it; nil, no zoom.
    var zoom: ((Date, Date) -> Void)? = nil
    /// The context menu's "Copy PromQL" (a Prometheus chart's) and "Copy
    /// Values as CSV" (the window shown, the series shown): the clipboard;
    /// nil, neither is offered (metrics.md 3.9, M9).
    var copy: ((String) -> Void)? = nil
    /// ⤢ and the context menu's "Expand": the chart alone in the window's
    /// right slot; nil, not offered.
    var expand: (() -> Void)? = nil
    @ObservedObject var theme: ChromeTheme
    @StateObject private var state = KubeChartState()
    /// Where the mouse last was over the plot: the context menu's time —
    /// the hover has ended by the time its item is picked. Held, not observed.
    @State private var lastHover = KubeChartHoverMemo()
    @State private var hidden: Set<String> = []
    @State private var hideReferences = false
    @State private var highlighted: String?
    @State private var size: CGSize = .zero
    /// The marker whose popover is open.
    @State private var popover: String?
    /// Its own entry in `KubeChartRegistry`.
    @State private var token = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            plotArea
            timeAxis
        }
        .onAppear {
            // A series off by default (C2's RSS) starts hidden; the legend shows it.
            if hidden.isEmpty, !data.hiddenByDefault.isEmpty { hidden = data.hiddenByDefault }
            register(state.plot)
        }
        .onDisappear { KubeChartRegistry.shared.hide(token) }
        .onReceive(state.$plot) { plot in register(plot) }
        .onChange(of: data.version) { _ in
            register(state.plot)
            want()
        }
        .onChange(of: hidden) { _ in want() }
        .onChange(of: hideReferences) { _ in want() }
    }

    /// The window it is in, as the registry and the draw counter know it.
    private var window: ObjectIdentifier { ObjectIdentifier(theme) }

    private func register(_ plot: KubePlot?) {
        KubeChartRegistry.shared.show(data, plot: plot, token: token, window: window, cursor: cursor)
    }

    private func want() { state.want(data, size: size, hidden: hidden, hideReferences: hideReferences) }

    private var colours: [Color] { theme.chartPalette }

    private func referenceColour(_ role: KubeChartRole) -> Color { KubeChartPalette.reference(role, dark: theme.isDark).color }

    // MARK: Header and legend

    /// Up to three series, the legend sits on the header's line; more wrap under it.
    private var header: some View {
        let wraps = data.legendSeries.count > 3
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: data.title).font(.system(size: 11)).foregroundStyle(theme.text3)
                if let value = headline ?? KubeChartSummary.totals(data).last.map({ data.unit.format($0.value) }) {
                    Text(verbatim: value).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(theme.text)
                }
                ForEach(chips, id: \.text) { chip in
                    Text(verbatim: chip.text).font(.system(size: 10.5, weight: chip.alert ? .semibold : .regular))
                        .foregroundStyle(chip.alert ? TabStatusStyle.failed : theme.text2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill((chip.alert ? TabStatusStyle.failed : theme.text3).opacity(0.12)))
                        .fixedSize()
                        .accessibilityIdentifier(data.identifier + ".chip")
                }
                Spacer(minLength: 8)
                if !wraps { legend }
                if let expand {
                    Button(action: expand) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.text3)
                    .help("Expand: this chart alone, in the window's right slot")
                    .accessibilityIdentifier(data.identifier + ".expand")
                }
            }
            if wraps { legend }
        }
    }

    @ViewBuilder private var legend: some View {
        let usage = data.legendSeries
        KubeFlowLayout(spacing: 8, lineSpacing: 3) {
            if usage.count > 1 {
                ForEach(Array(usage.enumerated()), id: \.element.id) { index, series in
                    legendItem(series, colour: colours[index % colours.count])
                }
            }
            if let note = data.markerNote {
                Text(verbatim: note).font(.system(size: 10.5)).foregroundStyle(theme.text3).fixedSize()
                    .help("The cluster keeps events about an hour: older warnings and scaling are marked only where a History has them")
                    .accessibilityIdentifier(data.identifier + ".markerNote")
            }
            if !data.references.isEmpty {
                Button {
                    hideReferences.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Canvas { context, size in
                            var path = Path()
                            path.move(to: CGPoint(x: 0, y: size.height / 2))
                            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        }
                        .frame(width: 12, height: 6)
                        Text(verbatim: "Lines").font(.system(size: 10.5)).fixedSize()
                    }
                    .foregroundStyle(hideReferences ? theme.text3.opacity(0.5) : theme.text3)
                }
                .buttonStyle(.plain)
                .help(data.references.map(\.name).joined(separator: ", ") + (hideReferences ? ": shown again" : ": hidden"))
                .accessibilityIdentifier(data.identifier + ".lines")
            }
        }
    }

    private func legendItem(_ series: KubeChartSeries, colour: Color) -> some View {
        Button {
            let ids = data.legendSeries.map(\.id)
            if NSEvent.modifierFlags.contains(.command) {
                // ⌘-click: this one added or removed, never the last one left.
                if hidden.contains(series.id) {
                    hidden.remove(series.id)
                } else if hidden.count < ids.count - 1 {
                    hidden.insert(series.id)
                }
            } else {
                // A click isolates it; clicked again, all come back.
                let isolated = Set(ids.filter { $0 != series.id })
                hidden = hidden == isolated ? [] : isolated
            }
        } label: {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 8, height: 8)
                Text(verbatim: series.name).font(.system(size: 10.5)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(hidden.contains(series.id) ? theme.text3.opacity(0.5) : theme.text3)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { highlighted = series.id } else if highlighted == series.id { highlighted = nil }
        }
        .accessibilityIdentifier(data.identifier + ".legend." + series.id)
    }

    // MARK: The plot

    private var plotArea: some View {
        GeometryReader { geometry in
            let plot = state.plot
            ZStack(alignment: .topLeading) {
                Canvas(
                    renderer: Self.renderer(
                        data.identifier, window: window, plot: plot, colours: colours, references: Dictionary(uniqueKeysWithValues: KubeChartRole.allCases.map { ($0, referenceColour($0)) }),
                        markers: Dictionary(uniqueKeysWithValues: KubeChartMarker.Kind.allCases.map { ($0, KubeChartPalette.marker($0, dark: theme.isDark).color) }),
                        grid: theme.border, highlighted: highlighted))
                if let plot {
                    labels(plot)
                }
                KubeChartOverlay(cursor: cursor, id: data.identifier, plot: plot, step: data.step, colours: colours, theme: theme)
                if let plot, !plot.markers.isEmpty { markerTicks(plot) }
                if let plot, data.earlierMarkers > 0 { earlier(plot) }
                if let plot, !plot.bands.isEmpty { bandTips(plot) }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { drag in
                        guard zoom != nil, let plot = state.plot else { return }
                        cursor.select(from: plot.time(atX: drag.startLocation.x), to: plot.time(atX: drag.location.x), owner: data.identifier)
                    }
                    .onEnded { drag in
                        defer { cursor.endSelection() }
                        guard let zoom, let plot = state.plot else { return }
                        zoom(plot.time(atX: drag.startLocation.x), plot.time(atX: drag.location.x))
                    }, including: zoom == nil ? .subviews : .all
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let time = state.plot?.nearestTime(toX: location.x)
                    lastHover.time = time
                    cursor.move(to: time, owner: data.identifier)
                case .ended:
                    cursor.leave(data.identifier)
                }
            }
            .contextMenu {
                if let logsFromHere {
                    Button("Logs from Here") { logsFromHere(lastHover.time ?? state.plot?.end ?? data.end) }
                        .help("The Logs tab from a minute before the crosshair's time")
                }
                if let copy {
                    if let promQL = KubeChartExport.promQL(data) {
                        Button("Copy PromQL") { copy(promQL) }
                            .help("The exact query this chart was drawn from, to paste into Grafana")
                    }
                    Button("Copy Values as CSV") { copy(KubeChartExport.csv(data, hidden: hidden, hideReferences: hideReferences)) }
                        .help("The window shown, a row a time and a column a series shown — to the clipboard only")
                }
                if let expand {
                    Divider()
                    Button("Expand") { expand() }
                        .help("This chart alone, in the window's right slot")
                }
            }
            .onAppear {
                size = geometry.size
                want()
            }
            .onChange(of: geometry.size) { new in
                size = new
                want()
            }
        }
        .frame(height: height)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: KubeChartSummary.of(data, span: span)))
        .accessibilityIdentifier(data.identifier)
        .accessibilityChartDescriptor(KubeChartDescriptor(data: data))
    }

    /// Each marker's tick, hit where it sits on the bottom edge: hover says
    /// what it was, a click opens its popover, ⌥-click the window around it.
    private func markerTicks(_ plot: KubePlot) -> some View {
        ForEach(plot.markers, id: \.marker.id) { placed in
            let marker = placed.marker
            Button {
                if NSEvent.modifierFlags.contains(.option), let showAround {
                    showAround(marker)
                } else {
                    popover = marker.id
                }
            } label: {
                Color.clear.frame(width: 12, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(marker.title + (showAround != nil ? " — click for more, ⌥-click for ±30 min around it" : ""))
            .popover(isPresented: Binding(get: { popover == marker.id }, set: { if !$0, popover == marker.id { popover = nil } }), arrowEdge: .bottom) {
                markerPopover(marker)
            }
            .position(x: placed.x, y: plot.frame.maxY - 7)
            .accessibilityIdentifier(data.identifier + ".marker." + marker.kind.rawValue)
        }
    }

    /// What a marker was, when, what it opens, and the window around it.
    private func markerPopover(_ marker: KubeChartMarker) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(KubeChartPalette.marker(marker.kind, dark: theme.isDark).color).frame(width: 8, height: 8)
                Text(verbatim: marker.kind.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text2)
                Spacer(minLength: 8)
                Text(verbatim: KubeChartTime.full(marker.time)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(theme.text3)
            }
            Text(verbatim: marker.title).font(.system(size: 12)).foregroundStyle(theme.text).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let detail = marker.detail {
                Text(verbatim: detail).font(.system(size: 11)).foregroundStyle(theme.text2).lineLimit(6).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if let opens = marker.opens, let openMarker {
                    Button(opens.title) {
                        popover = nil
                        openMarker(marker)
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("kubernetes.chart.marker.open")
                }
                if let showAround {
                    Button("Show ±30 min") {
                        popover = nil
                        showAround(marker)
                    }
                    .controlSize(.small)
                    .help("Every chart of the tab from 30 minutes before to 30 minutes after it (⌥-click)")
                    .accessibilityIdentifier("kubernetes.chart.marker.around")
                }
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .accessibilityIdentifier("kubernetes.chart.marker.popover")
    }

    /// The markers past the cap, the oldest, folded at the left edge.
    private func earlier(_ plot: KubePlot) -> some View {
        Text(verbatim: "+\(data.earlierMarkers) earlier")
            .font(.system(size: 9, weight: .medium)).foregroundStyle(theme.text3)
            .fixedSize()
            .padding(.horizontal, 3)
            .background(RoundedRectangle(cornerRadius: 3).fill(theme.border.opacity(0.6)))
            .position(x: plot.frame.minX + 30, y: plot.frame.maxY - 20)
            .help("\(data.earlierMarkers) older change\(data.earlierMarkers == 1 ? "" : "s") in this window aren't marked: only the newest \(KubeChartMarkers.cap) are")
            .accessibilityIdentifier(data.identifier + ".earlier")
    }

    /// Each band's name along its top edge, hover saying since when.
    private func bandTips(_ plot: KubePlot) -> some View {
        ForEach(plot.bands, id: \.band.id) { placed in
            Text(verbatim: placed.band.title)
                .font(.system(size: 9, weight: .medium)).foregroundStyle(Color.orange).lineLimit(1)
                .frame(width: max(placed.maxX - placed.minX, 1), height: 12, alignment: .leading)
                .clipped()
                .help("\(placed.band.title) since \(KubeChartTime.clock(placed.band.start))")
                .position(x: (placed.minX + placed.maxX) / 2, y: plot.frame.minY + 6)
                .accessibilityIdentifier(data.identifier + ".band")
        }
    }

    /// The y ticks in the gutter, the reference lines' names at their right ends.
    private func labels(_ plot: KubePlot) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(plot.yTicks, id: \.self) { tick in
                Text(verbatim: plot.unit.format(tick))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(theme.text3)
                    .frame(width: KubePlot.gutter - 6, alignment: .trailing)
                    .position(x: (KubePlot.gutter - 6) / 2, y: min(max(plot.y(of: tick), 6), plot.size.height - 6))
            }
            ForEach(plot.references, id: \.id) { reference in
                Text(verbatim: reference.name)
                    .font(.system(size: 9)).foregroundStyle(referenceColour(reference.role))
                    .fixedSize()
                    .frame(width: 120, alignment: .trailing)
                    // Above its line, or under it at the very top.
                    .position(x: reference.labelAt.x - 62, y: reference.labelAt.y < 16 ? reference.labelAt.y + 7 : reference.labelAt.y - 7)
            }
        }
        .allowsHitTesting(false)
    }

    private var timeAxis: some View {
        GeometryReader { _ in
            if let plot = state.plot {
                let interval = plot.timeTicks.count > 1 ? plot.timeTicks[1].timeIntervalSince(plot.timeTicks[0]) : 3600
                ZStack(alignment: .topLeading) {
                    ForEach(plot.timeTicks, id: \.self) { tick in
                        Text(verbatim: KubeChartTime.tick(tick, interval: interval))
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(theme.text3)
                            .fixedSize()
                            .position(x: min(max(plot.x(of: tick), 16), plot.size.width - 16), y: 6)
                    }
                }
            }
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }

    /// The series layer: grid, bands, lines, references — one pass. Made
    /// outside the view's isolation: SwiftUI calls it while drawing.
    nonisolated static func renderer(
        _ id: String, window: ObjectIdentifier, plot: KubePlot?, colours: [Color], references: [KubeChartRole: Color], markers: [KubeChartMarker.Kind: Color] = [:],
        grid: Color, highlighted: String?, bandColour: Color = .orange
    ) -> (inout GraphicsContext, CGSize) -> Void {
        { context, _ in
            KubeChartDraws.shared.drew(id, window: window, overlay: false)
            guard let plot, !colours.isEmpty else { return }
            for tick in plot.yTicks {
                var path = Path()
                let y = plot.y(of: tick)
                path.move(to: CGPoint(x: plot.frame.minX, y: y))
                path.addLine(to: CGPoint(x: plot.frame.maxX, y: y))
                context.stroke(path, with: .color(grid), lineWidth: tick == 0 ? 1 : 0.5)
            }
            // A band: a faint stretch the plot's height, under the lines.
            for band in plot.bands {
                context.fill(
                    Path(CGRect(x: band.minX, y: plot.frame.minY, width: max(band.maxX - band.minX, 1), height: plot.frame.height)),
                    with: .color(bandColour.opacity(0.12)))
            }
            // A peak band: a faint area behind the lines.
            for peak in plot.peaks {
                let alpha = highlighted == nil || highlighted == peak.id ? 1.0 : 0.25
                context.fill(Path(peak.stroke.cgPath), with: .color(colours[peak.colour % colours.count].opacity(0.1 * alpha)))
            }
            for line in plot.lines {
                let colour = colours[line.colour % colours.count]
                let alpha = highlighted == nil || highlighted == line.id ? 1.0 : 0.25
                if let fill = line.fill { context.fill(Path(fill.cgPath), with: .color(colour.opacity(0.15 * alpha))) }
                context.stroke(
                    Path(line.stroke.cgPath), with: .color(colour.opacity(alpha)), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            }
            for reference in plot.references {
                context.stroke(
                    Path(reference.stroke.cgPath), with: .color(references[reference.role] ?? .gray), style: StrokeStyle(lineWidth: 1, dash: reference.role.dash))
            }
            // A marker: a faint line the plot's height, a tick on its bottom edge.
            for placed in plot.markers {
                let colour = markers[placed.marker.kind] ?? .orange
                var line = Path()
                line.move(to: CGPoint(x: placed.x, y: plot.frame.minY))
                line.addLine(to: CGPoint(x: placed.x, y: plot.frame.maxY))
                context.stroke(line, with: .color(colour.opacity(0.35)), lineWidth: 1)
                context.fill(Path(CGRect(x: placed.x - 1.5, y: plot.frame.maxY - 7, width: 3, height: 7)), with: .color(colour))
            }
        }
    }
}

/// The time the mouse was last over a chart at: a class held in `@State`,
/// so writing it on every move redraws nothing.
final class KubeChartHoverMemo {
    var time: Date?
}

/// A number a chart's header says beside its value — `48% of request`,
/// `working set 93% of limit · OOM risk` — red when it warns.
struct KubeChartChip: Equatable, Sendable {
    var text: String
    var alert = false
}

/// Over a chart: the crosshair at the cursor's time, the hovered points,
/// and on the chart under the mouse the tooltip. The only part that
/// observes the cursor.
struct KubeChartOverlay: View {
    @ObservedObject var cursor: KubeChartCursor
    var id: String
    var plot: KubePlot?
    var step: TimeInterval
    var colours: [Color]
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        let hover = cursor.hover
        let band = cursor.selection.flatMap { selection in plot.map { (min($0.x(of: selection.from), $0.x(of: selection.to)), max($0.x(of: selection.from), $0.x(of: selection.to))) } }
        // The tooltip over the Canvas, not beside it: an overlay never sizes
        // the view under it, so the series layer is never laid out again.
        Canvas(
            renderer: Self.renderer(
                id, window: ObjectIdentifier(theme), plot: plot, time: hover?.time, owns: hover?.owner == id, step: step, colours: colours, line: theme.text3,
                band: band)
        )
        .overlay(alignment: .topLeading) {
            if let plot, let hover, hover.owner == id {
                tooltip(KubeChartTooltip.at(hover.time, plot: plot, step: step), x: plot.x(of: hover.time), plot: plot)
            }
        }
        .allowsHitTesting(false)
    }

    private func tooltip(_ tip: KubeChartTooltip, x: CGFloat, plot: KubePlot) -> some View {
        let right = x > plot.frame.midX
        // As many rows as the plot's height holds; the rest counted.
        let room = max(1, Int((plot.size.height - 30) / 14))
        let rows = tip.rows.count > room ? Array(tip.rows.prefix(room - 1)) : tip.rows
        let card = VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: tip.time).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.text)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 5) {
                    if let colour = row.colour {
                        Circle().fill(colours[colour % max(colours.count, 1)]).frame(width: 6, height: 6)
                    } else {
                        Rectangle().fill(KubeChartPalette.reference(row.role, dark: theme.isDark).color).frame(width: 6, height: 1)
                    }
                    Text(verbatim: row.name).font(.system(size: 10)).foregroundStyle(theme.text3).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(verbatim: row.value).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.text)
                }
            }
            if rows.count < tip.rows.count {
                Text(verbatim: "+\(tip.rows.count - rows.count) more").font(.system(size: 10)).foregroundStyle(theme.text3)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 5).fill(theme.menu))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.menuEdge, lineWidth: 0.5))
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("kubernetes.chart.tooltip")
        // Beside the crosshair, on whichever side has the room.
        return Group {
            if right {
                card.frame(width: max(x - 10, 0), alignment: .trailing)
            } else {
                card.padding(.leading, x + 10)
            }
        }
        .padding(.top, 4)
    }

    nonisolated static func renderer(
        _ id: String, window: ObjectIdentifier, plot: KubePlot?, time: Date?, owns: Bool, step: TimeInterval, colours: [Color], line: Color,
        band: (CGFloat, CGFloat)? = nil
    ) -> (inout GraphicsContext, CGSize) -> Void {
        { context, _ in
            // `owns`: the chart under the mouse, the one whose tooltip shows.
            KubeChartDraws.shared.drew(id, window: window, overlay: true, tooltip: owns && plot != nil && time != nil)
            // A drag's band, on every chart of the scope.
            if let plot, let band {
                let from = max(band.0, plot.frame.minX)
                let to = min(band.1, plot.frame.maxX)
                if to > from {
                    context.fill(Path(CGRect(x: from, y: plot.frame.minY, width: to - from, height: plot.frame.height)), with: .color(line.opacity(0.18)))
                }
            }
            guard let plot, let time, !colours.isEmpty else { return }
            let x = plot.x(of: time)
            var path = Path()
            path.move(to: CGPoint(x: x, y: plot.frame.minY))
            path.addLine(to: CGPoint(x: x, y: plot.frame.maxY))
            context.stroke(path, with: .color(line), lineWidth: 1)
            // Stacked, a band's point sits on the band's top.
            var below = 0.0
            for (track, value) in plot.values(at: time, step: step) where track.role == .usage {
                let shown = plot.stacked ? below + value : value
                below = shown
                let y = plot.y(of: shown)
                context.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)), with: .color(colours[track.colour % colours.count]))
            }
        }
    }
}

/// A chart for VoiceOver's Audio Graph (`AXChartDescriptor`): the series
/// a Canvas otherwise hides behind its one label (metrics.md, 5.2).
struct KubeChartDescriptor: AXChartDescriptorRepresentable {
    var data: KubeChartData

    func makeChartDescriptor() -> AXChartDescriptor { Self.make(data) }

    nonisolated static func make(_ data: KubeChartData) -> AXChartDescriptor {
        let unit = data.unit
        let values = data.series.flatMap { $0.points.map(\.value) }
        let top = KubePlot.niceScale(values.max() ?? 0, unit: unit).top
        let start = data.start.timeIntervalSince1970
        let end = max(data.end.timeIntervalSince1970, start + 1)
        let x = AXNumericDataAxisDescriptor(
            title: "Time", range: start...end, gridlinePositions: [],
            valueDescriptionProvider: { KubeChartTime.full(Date(timeIntervalSince1970: $0)) })
        let y = AXNumericDataAxisDescriptor(
            title: data.title, range: 0...max(top, 1e-9), gridlinePositions: [], valueDescriptionProvider: { unit.format($0) })
        let series = data.series.map { series in
            AXDataSeriesDescriptor(
                name: series.name, isContinuous: !series.role.isReference,
                dataPoints: series.points.map { AXDataPoint(x: $0.time.timeIntervalSince1970, y: $0.value) })
        }
        return AXChartDescriptor(
            title: data.title, summary: KubeChartSummary.of(data, span: ""), xAxis: x, yAxis: y, additionalAxes: [], series: series)
    }
}

/// Views laid left to right, wrapping onto the next line when the width
/// runs out: a legend of many series.
struct KubeFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let frames = place(subviews, width: width)
        let used = frames.reduce(CGRect.zero) { $0.union($1) }
        return CGSize(width: proposal.width.map { min($0, used.width) } ?? used.width, height: used.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, place(subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += line + lineSpacing
                line = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            line = max(line, size.height)
        }
        return frames
    }
}
