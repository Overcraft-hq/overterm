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

    /// When a cell begins.
    func start(of index: Int) -> Date { end.addingTimeInterval(-Double(Self.cellCount - index) * Self.cellSeconds) }

    /// What its help and VoiceOver say: "CPU, the last 15 min of
    /// allocatable: 22% now, peak 61% at 14:02 — sampled while shown".
    func summary(timeZone: TimeZone = .current) -> String {
        let title = measure == .cpu ? "CPU" : "Memory"
        var parts: [String] = []
        if let now { parts.append("\(Int(now.rounded()))% now") }
        if let peak { parts.append("peak \(Int(peak.percent.rounded()))% at \(KubeChartTime.clock(peak.time, timeZone: timeZone))") }
        let said = parts.isEmpty ? "" : ": " + parts.joined(separator: ", ")
        let gaps = filled < Self.cellCount ? " (\(Self.cellCount - filled) of 60 cells not sampled)" : ""
        return "\(title) as a share of allocatable, the last 15 min in 15 s cells\(said)\(gaps) — sampled while shown"
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

    func show(_ strip: KubeHeatStrip, identifier: String, token: UUID, window: ObjectIdentifier) {
        entries[token] = Shown(identifier: identifier, strip: strip, window: window)
    }
    func hide(_ token: UUID) { entries[token] = nil }

    /// The strip of that identifier on screen — in that window, or in any.
    func strip(_ identifier: String, in window: ObjectIdentifier? = nil) -> KubeHeatStrip? {
        entries.values.first { $0.identifier == identifier && (window == nil || $0.window == window) }?.strip
    }

    /// The dump's lines of one window's strips, or of every window's: each
    /// strip's identifier, filled cells, levels, peak.
    func lines(in window: ObjectIdentifier? = nil) -> [String] {
        entries.values.filter { window == nil || $0.window == window }
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

    static let width: CGFloat = 75
    static let height: CGFloat = 14

    @State private var token = UUID()

    var body: some View {
        let colours = KubeHeatStrip.Level.allCases.map { KubeChartPalette.heat($0, dark: dark).color }
        let percents = strip.percents
        let track = track
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(track.opacity(0.08)))
            let cell = size.width / CGFloat(percents.count)
            for (index, percent) in percents.enumerated() {
                let x = CGFloat(index) * cell
                guard let percent else {
                    context.fill(Path(CGRect(x: x, y: size.height - 1, width: cell, height: 1)), with: .color(track.opacity(0.3)))
                    continue
                }
                let height = max(2, size.height * CGFloat(min(percent, 100) / 100))
                let rect = CGRect(x: x, y: size.height - height, width: cell, height: height)
                context.fill(Path(rect), with: .color(colours[KubeHeatStrip.Level(percent).rawValue]))
            }
        }
        .frame(width: Self.width, height: Self.height)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: strip.summary()))
        .accessibilityIdentifier(identifier)
        .onAppear { KubeHeatStripRegistry.shared.show(strip, identifier: identifier, token: token, window: window) }
        .onChange(of: strip) { KubeHeatStripRegistry.shared.show($0, identifier: identifier, token: token, window: window) }
        .onChange(of: identifier) { KubeHeatStripRegistry.shared.show(strip, identifier: $0, token: token, window: window) }
        .onDisappear { KubeHeatStripRegistry.shared.hide(token) }
    }
}
