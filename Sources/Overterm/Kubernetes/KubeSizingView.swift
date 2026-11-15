import SwiftUI

/// The Metrics tab's Sizing card (metrics.md 2.10; M10): while asked, what
/// is asked; then a container each — CPU's p50, p95 and max and memory's
/// p95 and max as bars against its request (green, dashed) and limit (red,
/// long dashes), the suggestion beside — or why nothing was sized. Its
/// queries copied as sent; Hide closes it. Nothing on it changes anything.
struct KubeSizingView: View {
    static let identifier = "kubernetes.metrics.sizing.card"

    var reading: KubeSizingReading
    var card: KubeSizingCard?
    @ObservedObject var theme: ChromeTheme
    var copy: ((String) -> Void)?
    var again: () -> Void
    var hide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(verbatim: card?.title ?? "Sizing").font(.system(size: ChromeMetrics.text(10.5), weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if reading.done {
                    if let copy, !reading.queries.isEmpty {
                        Button("Copy PromQL") { copy(reading.queries.map(\.promql).joined(separator: "\n\n")) }
                            .controlSize(.small)
                            .help("The queries asked, exactly as sent: to try them in Grafana")
                            .accessibilityIdentifier("kubernetes.metrics.sizing.copy")
                    }
                    Button("Ask Again") { again() }
                        .controlSize(.small)
                        .help("Seven days read again, once")
                        .accessibilityIdentifier("kubernetes.metrics.sizing.again")
                }
                Button("Hide") { hide() }
                    .controlSize(.small)
                    .accessibilityIdentifier("kubernetes.metrics.sizing.hide")
            }
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Self.identifier)
    }

    @ViewBuilder private var content: some View {
        if !reading.done {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(verbatim: "Asking Prometheus for seven days of usage, once…").font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text3)
            }
        } else if let why = reading.unavailable ?? reading.refused {
            sentence(why)
        } else if let card, !card.rows.isEmpty {
            ForEach(card.rows) { row in rowView(row) }
            if let problem = reading.problem { sentence("Part of it couldn't be read: \(problem)") }
            ForEach(reading.notes, id: \.self) { sentence($0) }
            Text(verbatim: KubeSizingCard.advice).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
        } else if let problem = reading.problem {
            sentence("Sizing couldn't be read: \(problem)")
        } else {
            sentence("Prometheus has no usage for it over \(KubeSizing.said(window: reading.window ?? KubeSizing.span)).")
        }
    }

    private func sentence(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text2).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityIdentifier("kubernetes.metrics.sizing.said")
    }

    private func rowView(_ row: KubeSizingCard.Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: row.container).font(.system(size: ChromeMetrics.text(12), weight: .semibold)).foregroundStyle(theme.text)
            if let cpu = row.cpu { measureView(cpu) }
            if let memory = row.memory { measureView(memory) }
            if let note = row.note {
                Text(verbatim: note).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(TabStatusStyle.failed).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("kubernetes.metrics.sizing.oom")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("kubernetes.metrics.sizing.\(row.container)")
    }

    private func measureView(_ measure: KubeSizingCard.Measure) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: measure.title).font(.system(size: ChromeMetrics.text(11), weight: .medium)).foregroundStyle(theme.text2)
                Text(verbatim: measure.suggestion).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text).textSelection(.enabled)
            }
            KubeSizingBars(measure: measure, theme: theme)
            Text(verbatim: measure.now).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3)
        }
    }
}

/// A measure's bars on one scale, its request and limit lines across them.
private struct KubeSizingBars: View {
    var measure: KubeSizingCard.Measure
    @ObservedObject var theme: ChromeTheme

    static let label: CGFloat = 32
    static let value: CGFloat = 64
    static let height: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(measure.bars) { bar in
                HStack(spacing: 6) {
                    Text(verbatim: bar.label).font(.system(size: ChromeMetrics.text(10.5)).monospacedDigit()).foregroundStyle(theme.text3).frame(width: Self.label, alignment: .trailing)
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 2).fill(theme.selected)
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.75))
                                    .frame(width: max(1, geometry.size.width * bar.value / measure.scale))
                            }
                    }
                    .frame(height: Self.height)
                    Text(verbatim: bar.text).font(.system(size: ChromeMetrics.text(10.5)).monospacedDigit()).foregroundStyle(theme.text2).frame(width: Self.value, alignment: .leading)
                }
            }
        }
        .overlay {
            GeometryReader { geometry in
                let width = geometry.size.width - Self.label - Self.value - 12
                let lines = [(measure.request, Color.green, [3.0, 3.0]), (measure.limit, Color.red, [6.0, 2.0]), (Optional(measure.suggested), theme.text2, [1.0, 2.0])]
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if let value = line.0 {
                        let x = Self.label + 6 + width * value / measure.scale
                        Path { path in
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                        }
                        .stroke(line.1, style: StrokeStyle(lineWidth: 1.25, dash: line.2.map { CGFloat($0) }))
                    }
                }
            }
            .allowsHitTesting(false)
        }
        .clipped()
    }
}
