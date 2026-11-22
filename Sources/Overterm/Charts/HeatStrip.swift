import SwiftUI

/// How hot a cell is: under half of allocatable, under 80%, under all
/// of it, and over (CPU can be, memory nearly).
package enum HeatStripLevel: Int, CaseIterable, Sendable {
    case low, mid, high, over

    package init(_ percent: Double) {
        switch percent {
        case ..<50: self = .low
        case ..<80: self = .mid
        case ..<100: self = .high
        default: self = .over
        }
    }
}

extension TimeChartPalette {
    /// A heat cell's colour by level: teal and blue for calm, orange near
    /// allocatable, red past it — the series palette's own, each reading
    /// on the card in both appearances.
    package static func heat(_ level: HeatStripLevel, dark: Bool) -> RGB {
        switch level {
        case .low: RGB(dark ? 0x3DD6C3 : 0x0E8A7E)
        case .mid: RGB(dark ? 0x5AA3FF : 0x2167C9)
        case .high: RGB(dark ? 0xFF9A4D : 0xC2570C)
        case .over: reference(.limit, dark: dark)
        }
    }
}

/// A heat strip's cells as bars (Kubernetes' node rows, Activity's rows).
package enum HeatStripBars {
    /// Where `draw` puts each cell in `rect`, y down: a sampled one a bar
    /// from the foot, as tall as its share (at least 2) in its level; an
    /// unsampled one a 1-point tick at the foot, no level. Pure: the Canvas
    /// and Activity's AppKit strip draw the same rects.
    package nonisolated static func bars(_ percents: [Double?], in rect: CGRect) -> [(rect: CGRect, level: HeatStripLevel?)] {
        let cell = rect.width / CGFloat(max(1, percents.count))
        var bars: [(rect: CGRect, level: HeatStripLevel?)] = []
        bars.reserveCapacity(percents.count)
        for (index, percent) in percents.enumerated() {
            let x = rect.minX + CGFloat(index) * cell
            guard let percent else {
                bars.append((CGRect(x: x, y: rect.maxY - 1, width: cell, height: 1), nil))
                continue
            }
            let height = max(2, rect.height * CGFloat(min(percent, 100) / 100))
            bars.append((CGRect(x: x, y: rect.maxY - height, width: cell, height: height), HeatStripLevel(percent)))
        }
        return bars
    }
}
