import Foundation
import SwiftUI

/// A node's row's heat strip (docs/design/kubernetes/metrics.md, 2.1, stage
/// M3c): its CPU or memory over the last 15 minutes as 60 cells of 15 s,
/// each its share of the node's allocatable — the ring's samples of the
/// node (`KubeUsageRing`, the Nodes list's own `/nodes` read; nothing more
/// is asked for it). Pure.
///
/// A cell takes the largest share sampled in it; a sample stands for the
/// stretch since the one before it in its run (metrics-server's window),
/// so a 60 s resolution fills four cells, not one. A break in the ring
/// (the page hidden, a read missed) and a time before the first sample
/// are empty cells, never zero. The strip ends at the node's newest
/// sample, so metrics-server's lag never leaves its last cell blank.
/// Colour is not its only cue: each cell's height is its share too, and
/// the row's text says the share now.
struct KubeHeatStrip: Equatable, Sendable {
    static let cellCount = 60
    static let cellSeconds: TimeInterval = 15

    /// How hot a cell is: under half of allocatable, under 80%, under all
    /// of it, and over (CPU can be, memory nearly).
    enum Level: Int, CaseIterable, Sendable {
        case low, mid, high, over

        init(_ percent: Double) {
            switch percent {
            case ..<50: self = .low
            case ..<80: self = .mid
            case ..<100: self = .high
            default: self = .over
            }
        }
    }

    var measure: KubeUsageCell.Measure
    /// The cells' shares in percent, oldest first; nil, nothing sampled there.
    var percents: [Double?]
    /// When the last cell ends: the newest sample's time.
    var end: Date
    /// How long a cell is: 15 s sampled; over Prometheus a sixtieth of the
    /// range picked (the Overview's nodes, X4).
    var cell: TimeInterval = cellSeconds
    /// From metrics-server's samples taken while shown, or Prometheus'.
    var sampled = true

    /// The strip of `segments` (the ring's runs, oldest first) against
    /// `allocatable`; nil without an allocatable or a sample.
    static func of(_ segments: [[KubeUsagePoint]], _ measure: KubeUsageCell.Measure, allocatable: Double?) -> KubeHeatStrip? {
        guard let allocatable, allocatable > 0, let end = segments.last(where: { !$0.isEmpty })?.last?.time else { return nil }
        func share(_ point: KubeUsagePoint) -> Double { (measure == .cpu ? point.usage.cpu : point.usage.memory) / allocatable * 100 }
        // The cell a time falls in: the last one ends at `end`.
        func cell(_ time: Date) -> Int { cellCount - 1 - Int((max(0, end.timeIntervalSince(time)) / cellSeconds).rounded(.down)) }
        var percents = [Double?](repeating: nil, count: cellCount)
        for segment in segments {
            var previous: Int?
            for point in segment {
                let last = cell(point.time)
                let first = previous.map { Swift.min($0 + 1, last) } ?? last
                previous = last
                guard last >= 0 else { continue }
                let value = share(point)
                for index in Swift.max(0, first)...last { percents[index] = Swift.max(percents[index] ?? 0, value) }
            }
        }
        return KubeHeatStrip(measure: measure, percents: percents, end: end)
    }

    /// The cells with a sample.
    var filled: Int { percents.lazy.compactMap { $0 }.count }

    /// The newest cell's share.
    var now: Double? { percents.last ?? nil }

    /// The largest share, and when its cell began.
    var peak: (percent: Double, time: Date)? {
        var best: (Int, Double)?
        for (index, value) in percents.enumerated() {
            guard let value, value >= (best?.1 ?? -1) else { continue }
            best = (index, value)
        }
        guard let (index, value) = best else { return nil }
        return (value, start(of: index))
    }

    /// A node's strip from Prometheus' answer over `start…end` (X4): the
    /// range as 60 cells, each the largest share among the points in it —
    /// a point stands for the step that ends at it. Nil without an
    /// allocatable. A cell without a point is empty, never zero.
    static func of(
        _ points: [KubeSeriesPoint], _ measure: KubeUsageCell.Measure, allocatable: Double?, start: Date, end: Date
    ) -> KubeHeatStrip? {
        guard let allocatable, allocatable > 0, end > start else { return nil }
        let cell = end.timeIntervalSince(start) / Double(cellCount)
        var percents = [Double?](repeating: nil, count: cellCount)
        for point in points where point.time > start && point.time <= end {
            let index = Swift.min(cellCount - 1, Swift.max(0, Int((point.time.timeIntervalSince(start) / cell).rounded(.up)) - 1))
            percents[index] = Swift.max(percents[index] ?? 0, point.value / allocatable * 100)
        }
        return KubeHeatStrip(measure: measure, percents: percents, end: end, cell: cell, sampled: false)
    }

    /// When a cell begins.
    func start(of index: Int) -> Date { end.addingTimeInterval(-Double(Self.cellCount - index) * cell) }

    /// What its help and VoiceOver say: "CPU, the last 15 min of
    /// allocatable: 22% now, peak 61% at 14:02 — sampled while shown".
    func summary(timeZone: TimeZone = .current) -> String {
        let title = measure == .cpu ? "CPU" : "Memory"
        var parts: [String] = []
        if let now { parts.append("\(Int(now.rounded()))% now") }
        if let peak { parts.append("peak \(Int(peak.percent.rounded()))% at \(KubeChartTime.clock(peak.time, timeZone: timeZone))") }
        let said = parts.isEmpty ? "" : ": " + parts.joined(separator: ", ")
        let gaps = filled < Self.cellCount ? " (\(Self.cellCount - filled) of 60 cells \(sampled ? "not sampled" : "without a point"))" : ""
        let span = Self.spoken(cell * Double(Self.cellCount))
        let cells = Self.spoken(cell)
        return "\(title) as a share of allocatable, the last \(span) in \(cells) cells\(said)\(gaps) — " + (sampled ? "sampled while shown" : "from Prometheus")
    }

    /// `15 s`, `15 min`, `6h`, `7 d`: a span as the summary says it.
    static func spoken(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole) s" }
        if whole < 3 * 3600 || whole % 3600 != 0 { return "\(whole / 60) min" }
        if whole < 2 * 86400 { return "\(whole / 3600)h" }
        return "\(whole / 86400) d"
    }

    /// The dump's line: the filled cells, the levels' counts, the peak.
    var dump: String {
        let levels = Level.allCases.map { level in "\(level)=\(percents.filter { $0.map { Level($0) == level } ?? false }.count)" }
        return "\(measure == .cpu ? "cpu" : "memory") filled=\(filled)/\(Self.cellCount) \(levels.joined(separator: " ")) peak=\(peak.map { "\(Int($0.percent.rounded()))%" } ?? "none")"
    }
}

/// The heat strips on screen, by their row's identifier
/// (`kubernetes.heat.<node>.<measure>`) and the window they are in (its
/// `ChromeTheme`, one a window, as `KubeChartRegistry` keys charts): what
/// the scenario and the layout dump read back. Two windows on the same
/// context's Nodes list show the same identifiers.
@MainActor
final class KubeHeatStripRegistry {
    static let shared = KubeHeatStripRegistry()

    struct Shown {
        var identifier: String
        var strip: KubeHeatStrip
        var window: ObjectIdentifier
    }

    private var entries: [UUID: Shown] = [:]
    /// Strips drawn together in one view (X4's), by that view's token.
    private var groups: [UUID: [Shown]] = [:]

    func show(_ strip: KubeHeatStrip, identifier: String, token: UUID, window: ObjectIdentifier) {
        entries[token] = Shown(identifier: identifier, strip: strip, window: window)
    }
    /// A view's strips, all at once: those it showed before replaced.
    func show(_ strips: [(identifier: String, strip: KubeHeatStrip)], token: UUID, window: ObjectIdentifier) {
        groups[token] = strips.map { Shown(identifier: $0.identifier, strip: $0.strip, window: window) }
    }
    func hide(_ token: UUID) {
        entries[token] = nil
        groups[token] = nil
    }

    private var shown: [Shown] { Array(entries.values) + groups.values.flatMap { $0 } }

    /// The strip of that identifier on screen — in that window, or in any.
    func strip(_ identifier: String, in window: ObjectIdentifier? = nil) -> KubeHeatStrip? {
        shown.first { $0.identifier == identifier && (window == nil || $0.window == window) }?.strip
    }

    /// The dump's lines of one window's strips, or of every window's: each
    /// strip's identifier, filled cells, levels, peak.
    func lines(in window: ObjectIdentifier? = nil) -> [String] {
        shown.filter { window == nil || $0.window == window }
            .sorted { $0.identifier < $1.identifier }
            .map { "heat \($0.identifier) \($0.strip.dump)" }
    }
}

extension KubeChartPalette {
    /// A heat cell's colour by level: teal and blue for calm, orange near
    /// allocatable, red past it — the series palette's own, each reading
    /// on the card in both appearances.
    static func heat(_ level: KubeHeatStrip.Level, dark: Bool) -> RGB {
        switch level {
        case .low: RGB(dark ? 0x3DD6C3 : 0x0E8A7E)
        case .mid: RGB(dark ? 0x5AA3FF : 0x2167C9)
        case .high: RGB(dark ? 0xFF9A4D : 0xC2570C)
        case .over: reference(.limit, dark: dark)
        }
    }
}

/// A heat strip drawn in one Canvas pass: each sampled cell a bar as tall
/// as its share (at least a sliver) in its level's colour, an unsampled one
/// a faint tick at the foot — a gap, never a zero.
struct KubeHeatStripView: View {
    let strip: KubeHeatStrip
    let identifier: String
    let dark: Bool
    let track: Color
    /// The window it is in, by its `ChromeTheme`.
    let window: ObjectIdentifier

    nonisolated static let width: CGFloat = 75
    nonisolated static let height: CGFloat = 14

    @State private var token = UUID()

    var body: some View {
        let colours = KubeHeatStrip.Level.allCases.map { KubeChartPalette.heat($0, dark: dark).color }
        let percents = strip.percents
        let track = track
        let summary = strip.summary()
        cells(percents, colours: colours, track: track)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: summary))
            .accessibilityIdentifier(identifier)
            .onAppear { KubeHeatStripRegistry.shared.show(strip, identifier: identifier, token: token, window: window) }
            .onChange(of: strip) { KubeHeatStripRegistry.shared.show($0, identifier: identifier, token: token, window: window) }
            .onChange(of: identifier) { KubeHeatStripRegistry.shared.show(strip, identifier: $0, token: token, window: window) }
            .onDisappear { KubeHeatStripRegistry.shared.hide(token) }
    }

    /// The cells, in one Canvas pass.
    private func cells(_ percents: [Double?], colours: [Color], track: Color) -> some View {
        Canvas { context, size in
            Self.draw(percents, in: CGRect(origin: .zero, size: size), context: &context, colours: colours, track: track)
        }
        .frame(width: Self.width, height: Self.height)
    }

    /// A strip's cells drawn in `rect` (X4 draws fifty rows' in one Canvas).
    static func draw(_ percents: [Double?], in rect: CGRect, context: inout GraphicsContext, colours: [Color], track: Color) {
        context.fill(Path(rect), with: .color(track.opacity(0.08)))
        let cell = rect.width / CGFloat(max(1, percents.count))
        for (index, percent) in percents.enumerated() {
            let x = rect.minX + CGFloat(index) * cell
            guard let percent else {
                context.fill(Path(CGRect(x: x, y: rect.maxY - 1, width: cell, height: 1)), with: .color(track.opacity(0.3)))
                continue
            }
            let height = max(2, rect.height * CGFloat(min(percent, 100) / 100))
            context.fill(Path(CGRect(x: x, y: rect.maxY - height, width: cell, height: height)), with: .color(colours[KubeHeatStrip.Level(percent).rawValue]))
        }
    }
}
