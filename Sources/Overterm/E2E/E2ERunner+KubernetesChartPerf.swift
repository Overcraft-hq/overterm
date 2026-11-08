import AppKit
import SwiftUI

/// A chart's budgets (docs/design/kubernetes/metrics.md, 5.3, stage M1):
/// 13 series of 300 points, its plot built off the main thread in 5 ms or
/// less, and the crosshair moved 200 times over it in 2 ms or less a frame
/// — each move redrawing the overlays alone, the draw counter showing the
/// series layers never drawn again, nor the view holding the cursor. The
/// chart is hosted as the app holds it (`KubeChartPerfHost`, the cursor in
/// a parent's `@State` beside a second chart, as `KubePrometheusChartView`
/// holds it) in a window of the app's own; the cursor is moved by the
/// model, as the hover moves it (no system events).
extension E2ERunner {
    func kubernetesChartPerf() async {
        guard let theme = app.theme else { return check("the window's theme", false) }
        let step: TimeInterval = 12
        let end = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / step).rounded(.down) * step)
        let start = end.addingTimeInterval(-300 * step)
        var series = (0..<12).map { index in
            KubeChartSeries(
                id: "pod-\(index)", name: "api-7f9c6d-\(index)",
                points: (0..<300).map { point in
                    KubeSeriesPoint(
                        time: start.addingTimeInterval(Double(point) * step),
                        value: 0.05 + 0.02 * Double(index) + 0.03 * sin(Double(point) / 9 + Double(index)))
                })
        }
        series.append(
            KubeChartSeries(
                id: "other", name: "other", points: (0..<300).map { KubeSeriesPoint(time: start.addingTimeInterval(Double($0) * step), value: 0.4) }))
        series.append(KubeChartSeries(id: "request", name: "request", role: .request, points: [KubeSeriesPoint(time: start, value: 0.5)]))
        series.append(KubeChartSeries(id: "limit", name: "limit", role: .limit, points: [KubeSeriesPoint(time: start, value: 1)]))
        let data = KubeChartData(
            id: "perf.cpu", title: "CPU", unit: .cores, series: series, start: start, end: end, step: step, source: "scenario", version: 1)
        check("13 series of 300 points", data.usage.count == 13 && data.usage.allSatisfy { $0.points.count == 300 })

        // The plot, built where the chart builds it: off the main thread.
        var builds: [Double] = []
        for _ in 0..<20 {
            let took = await Task.detached(priority: .userInitiated) { () -> Double in
                let begun = CACurrentMediaTime()
                _ = KubePlot(data, size: CGSize(width: 760, height: 160))
                return (CACurrentMediaTime() - begun) * 1000
            }.value
            builds.append(took)
        }
        let built = Self.summary(builds)
        note("kubernetes chart plot of 13 × 300 points built: \(built)")
        check("the plot built in 5 ms or less (median)", built.median <= 5, "\(built)")

        // Hosted, then hovered.
        let sibling = KubeChartData(
            id: "perf.memory", title: "Memory", unit: .bytes,
            series: [
                KubeChartSeries(
                    id: "memory", name: "Memory",
                    points: (0..<300).map { KubeSeriesPoint(time: start.addingTimeInterval(Double($0) * step), value: 96 * 1_048_576 + 1_048_576 * sin(Double($0) / 7)) })
            ], start: start, end: end, step: step, source: "scenario", version: 1)
        let scope = ObjectIdentifier(theme)
        let host = NSHostingView(rootView: KubeChartPerfHost(data: data, sibling: sibling, theme: theme).padding(10).frame(width: 1220, height: 230))
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1220, height: 230), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let drawn = await eventually(10) {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            return [data, sibling].allSatisfy { chart in
                KubeChartRegistry.shared.chart(chart.identifier, in: scope)?.plot != nil && KubeChartDraws.shared.of(chart.identifier, in: scope).series > 0
            }
        }
        check("the chart drawn", drawn, "\(KubeChartDraws.shared.of(data.identifier, in: scope))")
        if let line = KubeChartRegistry.shared.lines(in: scope).first(where: { $0.contains(data.identifier) }) { note("kubernetes chart dump: \(line)") }
        guard let cursor = KubeChartRegistry.shared.chart(data.identifier, in: scope)?.cursor else { return check("the chart's cursor", false) }
        check("one cursor for both charts", KubeChartRegistry.shared.chart(sibling.identifier, in: scope)?.cursor === cursor)
        await pause(0.3)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let before = KubeChartDraws.shared.of(data.identifier, in: scope)
        let siblingBefore = KubeChartDraws.shared.of(sibling.identifier, in: scope)
        let hostBefore = KubeChartDraws.shared.of(KubeChartPerfHost.identifier, in: scope)
        var samples: [Double] = []
        for move in 0..<200 {
            let time = start.addingTimeInterval(Double(40 + move) * step)
            let begun = CACurrentMediaTime()
            cursor.move(to: time, owner: data.identifier)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            samples.append((CACurrentMediaTime() - begun) * 1000)
            await Task.yield()
        }
        let after = KubeChartDraws.shared.of(data.identifier, in: scope)
        let siblingAfter = KubeChartDraws.shared.of(sibling.identifier, in: scope)
        let hostAfter = KubeChartDraws.shared.of(KubeChartPerfHost.identifier, in: scope)
        let hovered = Self.summary(samples)
        note("kubernetes chart hover, 200 moves over 13 × 300 points: \(hovered); overlay drawn \(after.overlay - before.overlay), series \(after.series - before.series)")
        check("a move costs 2 ms or less a frame (p95)", hovered.p95 <= 2, "\(hovered)")
        check("every move redraws the overlay", after.overlay - before.overlay >= 200, "\(after.overlay - before.overlay)")
        check("and never the series layer", after.series == before.series, "\(after.series - before.series) series draws")
        check("the chart beside it draws the crosshair too", siblingAfter.overlay - siblingBefore.overlay >= 200, "\(siblingAfter.overlay - siblingBefore.overlay)")
        check(
            "never its series, nor a tooltip of its own", siblingAfter.series == siblingBefore.series && siblingAfter.tooltip == siblingBefore.tooltip,
            "\(siblingBefore) → \(siblingAfter)")
        check("the view holding the cursor never runs again", hostAfter.container == hostBefore.container, "\(hostAfter.container - hostBefore.container) bodies")
        let tip = KubeChartRegistry.shared.tooltip(data.identifier, in: scope, at: start.addingTimeInterval(100 * step))
        check("the tooltip there lists every series and both lines", tip?.rows.count == 15, "\(tip?.rows.map(\.name) ?? [])")
        cursor.leave(data.identifier)
        window.contentView = nil
        check("a chart gone from the screen leaves the registry", await eventually(5) { KubeChartRegistry.shared.chart(data.identifier, in: scope) == nil })
    }
}

/// Two charts as the app holds them: the cursor in this parent's `@State`,
/// held and not observed (`KubePrometheusChartView`'s way), its body counted.
private struct KubeChartPerfHost: View {
    static let identifier = "kubernetes.chart.perf.host"
    var data: KubeChartData
    var sibling: KubeChartData
    @ObservedObject var theme: ChromeTheme
    @State private var cursor = KubeChartCursor()

    var body: some View {
        let _ = KubeChartDraws.shared.composed(Self.identifier, window: ObjectIdentifier(theme))
        HStack(alignment: .top, spacing: 20) {
            KubeChartView(data: data, cursor: cursor, span: "last 1h", height: 160, theme: theme).frame(width: 800)
            KubeChartView(data: sibling, cursor: cursor, span: "last 1h", height: 160, theme: theme).frame(width: 380)
        }
    }
}
