import AppKit
import Charts
import SwiftUI

/// What a Prometheus, Loki or Tempo query gave back, under its console:
/// series as a graph (and a table), log lines as a log, traces as a list,
/// a trace as its waterfall.
struct ObservabilityResultView: View {
    let run: SQLConsole.Run
    let payload: ObservabilityPayload
    let result: QueryResult
    @ObservedObject var console: SQLConsole
    @ObservedObject var theme: ChromeTheme
    /// A trace's id: opened in the console that can (Tempo's), as a new tab.
    let openTrace: (String) -> Void
    /// The grid, for the table and the export.
    let grid: () -> AnyView

    var body: some View {
        switch payload {
        case .series(let series): SeriesView(series: series, theme: theme, grid: grid)
        case .logs(let lines): LogsView(lines: lines, run: run, console: console, theme: theme, openTrace: openTrace)
        case .traces(let traces): TracesView(traces: traces, theme: theme, open: openTrace)
        case .trace(let trace): WaterfallView(trace: trace, theme: theme)
        }
    }

    /// Colours for series and services, in order.
    static let palette: [Color] = [
        Color(red: 0.36, green: 0.62, blue: 0.98), Color(red: 0.98, green: 0.62, blue: 0.24), Color(red: 0.36, green: 0.78, blue: 0.50),
        Color(red: 0.92, green: 0.40, blue: 0.48), Color(red: 0.66, green: 0.50, blue: 0.96), Color(red: 0.25, green: 0.76, blue: 0.80),
        Color(red: 0.90, green: 0.78, blue: 0.30), Color(red: 0.94, green: 0.50, blue: 0.80), Color(red: 0.55, green: 0.70, blue: 0.35),
        Color(red: 0.60, green: 0.60, blue: 0.66),
    ]

    static func color(_ index: Int) -> Color { palette[index % palette.count] }
}

// MARK: Series

private struct SeriesView: View {
    let series: [MetricSeries]
    @ObservedObject var theme: ChromeTheme
    let grid: () -> AnyView
    @State private var table = false
    @State private var hidden: Set<String> = []
    @State private var hover: Date?

    /// Series drawn at most: more is a smear, and slow.
    static let drawn = 40

    private var shown: [(offset: Int, element: MetricSeries)] {
        Array(series.prefix(Self.drawn).enumerated()).filter { !hidden.contains($0.element.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $table) {
                    Text("Graph").tag(false)
                    Text("Table").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
                .accessibilityIdentifier("seriesMode")
                Text(verbatim: series.count == 1 ? "1 series" : "\(series.count) series\(series.count > Self.drawn ? " — the first \(Self.drawn) drawn" : "")")
                    .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            if table {
                grid()
            } else if series.allSatisfy({ $0.points.isEmpty }) || series.isEmpty {
                Text("No data in this window.").font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    chart.padding(.leading, 10).padding(.vertical, 6)
                    legend.frame(width: 260)
                }
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(shown, id: \.element.id) { index, item in
                ForEach(Array(item.points.enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value("Time", point.time), y: .value("Value", point.value), series: .value("Series", item.id))
                        .foregroundStyle(ObservabilityResultView.color(index))
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                        .interpolationMethod(.linear)
                }
            }
            if let hover {
                RuleMark(x: .value("Time", hover)).foregroundStyle(theme.text3.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine().foregroundStyle(theme.border.opacity(0.5)); AxisValueLabel()
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(theme.border.opacity(0.5)); AxisValueLabel()
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let x = location.x - geometry[proxy.plotAreaFrame].origin.x
                            hover = proxy.value(atX: x, as: Date.self)
                        case .ended:
                            hover = nil
                        }
                    }
            }
        }
        .accessibilityIdentifier("seriesChart")
    }

    /// Each series: its colour, its labels, its value at the pointer (else the last); a click hides it.
    private var legend: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if let hover {
                    Text(hover, format: .dateTime.hour().minute().second()).font(.system(size: ChromeMetrics.text(10.5), weight: .semibold))
                        .foregroundStyle(theme.text2).padding(.bottom, 2)
                }
                ForEach(Array(series.prefix(Self.drawn).enumerated()), id: \.element.id) { index, item in
                    HStack(alignment: .top, spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(ObservabilityResultView.color(index)).frame(width: 10, height: 3).padding(.top, 6)
                        Text(verbatim: MetricSeries.signature(item.labels)).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced))
                            .foregroundStyle(hidden.contains(item.id) ? theme.text3 : theme.text2).lineLimit(2)
                        Spacer(minLength: 4)
                        Text(verbatim: value(of: item).map(ObservabilityRows.format) ?? "")
                            .font(.system(size: ChromeMetrics.text(10.5), weight: .medium, design: .monospaced)).foregroundStyle(theme.text)
                    }
                    .opacity(hidden.contains(item.id) ? 0.45 : 1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if hidden.contains(item.id) { hidden.remove(item.id) } else { hidden.insert(item.id) }
                    }
                    .help("Click to hide or show it")
                    .contextMenu {
                        Button("Copy Series") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(MetricSeries.signature(item.labels), forType: .string)
                        }
                        Button("Show Only This") { hidden = Set(series.map(\.id)).subtracting([item.id]) }
                        Button("Show All") { hidden = [] }
                    }
                }
            }
            .padding(8)
        }
        .background(theme.rowHover.opacity(0.3))
    }

    private func value(of series: MetricSeries) -> Double? {
        guard let hover else { return series.points.last?.value }
        return series.points.min { abs($0.time.timeIntervalSince(hover)) < abs($1.time.timeIntervalSince(hover)) }?.value
    }
}

// MARK: Logs

private struct LogsView: View {
    let lines: [LogLine]
    let run: SQLConsole.Run
    @ObservedObject var console: SQLConsole
    @ObservedObject var theme: ChromeTheme
    let openTrace: (String) -> Void
    @State private var filter = ""
    @State private var levels: Set<LogLevel> = []
    @State private var open: Set<String> = []
    @State private var wrap = false

    private var shown: [LogLine] {
        lines.filter { line in
            (levels.isEmpty || line.level.map(levels.contains) == true) && (filter.isEmpty || line.line.localizedCaseInsensitiveContains(filter))
        }
    }

    static func color(_ level: LogLevel?, theme: ChromeTheme) -> Color {
        switch level {
        case .critical: Color(red: 0.85, green: 0.25, blue: 0.75)
        case .error: DiffColors.removed
        case .warn: theme.orangeText
        case .info: TabStatusStyle.done
        case .debug: Color(red: 0.36, green: 0.62, blue: 0.98)
        case .trace: theme.text3
        case nil: theme.border
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(theme.border.opacity(0.5)).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { line in row(line) }
                    if shown.isEmpty {
                        Text(lines.isEmpty ? "No lines in this window." : "No line matches.").font(.system(size: ChromeMetrics.text(12)))
                            .foregroundStyle(theme.text3).padding(12)
                    }
                }
            }
            .accessibilityIdentifier("logLines")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3)
            TextField("Find in these lines", text: $filter).textFieldStyle(.plain).font(.system(size: ChromeMetrics.text(11.5))).frame(maxWidth: 220)
            let counts = Dictionary(grouping: lines.compactMap(\.level), by: { $0 }).mapValues(\.count)
            ForEach(LogLevel.allCases.filter { counts[$0] != nil }, id: \.self) { level in
                Button {
                    if levels.contains(level) { levels.remove(level) } else { levels.insert(level) }
                } label: {
                    HStack(spacing: 3) {
                        Circle().fill(Self.color(level, theme: theme)).frame(width: 6, height: 6)
                        Text(verbatim: "\(level.rawValue) \(counts[level] ?? 0)")
                    }
                    .font(.system(size: ChromeMetrics.text(10.5)))
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(levels.contains(level) ? theme.selected : .clear))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.text2)
                .help("Only \(level.rawValue) lines — click again for all")
            }
            Spacer()
            Text(verbatim: shown.count == lines.count ? "\(lines.count) lines" : "\(shown.count) of \(lines.count) lines")
                .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3)
            Toggle("Wrap", isOn: $wrap).toggleStyle(.checkbox).controlSize(.small)
            if console.live == run.id {
                Button {
                    console.stopFollowing()
                } label: {
                    Label("Live", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(TabStatusStyle.done)
                }
                .controlSize(.small).help("Following new lines every 2 s — click to stop")
            } else {
                Button {
                    console.follow(run)
                } label: {
                    Label("Live", systemImage: "play.circle")
                }
                .controlSize(.small).help("Follow new lines as they come")
                .accessibilityIdentifier("logLive")
            }
        }
        .padding(.horizontal, 10).frame(height: ChromeMetrics.row(30))
    }

    private func row(_ line: LogLine) -> some View {
        let expanded = open.contains(line.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(Self.color(line.level, theme: theme)).frame(width: 3)
                Text(line.time, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3)))
                    .font(.system(size: ChromeMetrics.text(11), design: .monospaced)).foregroundStyle(theme.text3)
                    .fixedSize()
                Text(verbatim: line.line).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced)).foregroundStyle(theme.text)
                    .lineLimit(expanded || wrap ? nil : 1).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    labels(line.labels)
                    HStack(spacing: 8) {
                        Button("Copy Line") { copy(line.line) }.controlSize(.small)
                        if let trace = line.traceID {
                            Button {
                                openTrace(trace)
                            } label: {
                                Label("Open Trace \(trace.prefix(8))…", systemImage: "point.3.connected.trianglepath.dotted")
                            }
                            .controlSize(.small)
                            .accessibilityIdentifier("logOpenTrace")
                        }
                    }
                }
                .padding(.leading, 11 + 90)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 2)
        .background(expanded ? theme.rowHover.opacity(0.6) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if expanded { open.remove(line.id) } else { open.insert(line.id) }
        }
    }

    private func labels(_ labels: [String: String]) -> some View {
        // Wrapped as text: a few dozen chips would be a layout of their own.
        Text(verbatim: labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "   "))
            .font(.system(size: ChromeMetrics.text(10.5), design: .monospaced)).foregroundStyle(theme.accentText).textSelection(.enabled)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: Traces

private struct TracesView: View {
    let traces: [TraceSummary]
    @ObservedObject var theme: ChromeTheme
    let open: (String) -> Void

    var body: some View {
        let longest = max(traces.map(\.durationMs).max() ?? 1, 0.001)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(traces) { trace in
                    HStack(spacing: 10) {
                        Text(verbatim: String(trace.id.prefix(12))).font(.system(size: ChromeMetrics.text(11), design: .monospaced))
                            .foregroundStyle(theme.accentText).frame(width: 110, alignment: .leading)
                        Text(verbatim: trace.service).font(.system(size: ChromeMetrics.text(11.5), weight: .medium)).foregroundStyle(theme.text)
                            .lineLimit(1).frame(width: 150, alignment: .leading)
                        Text(verbatim: trace.name).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text2).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(trace.start, format: .dateTime.hour().minute().second()).font(.system(size: ChromeMetrics.text(11)))
                            .foregroundStyle(theme.text3)
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 2).fill(ObservabilityResultView.color(0).opacity(0.7))
                                .frame(width: max(2, geometry.size.width * trace.durationMs / longest), height: 6)
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(width: 90, height: 14)
                        Text(verbatim: ObservabilityRows.milliseconds(trace.durationMs)).font(.system(size: ChromeMetrics.text(11), design: .monospaced))
                            .foregroundStyle(theme.text).frame(width: 70, alignment: .trailing)
                    }
                    .padding(.horizontal, 10).frame(height: ChromeMetrics.row(24))
                    .contentShape(Rectangle())
                    .onTapGesture { open(trace.id) }
                    .help("Open the trace")
                    .accessibilityIdentifier("trace-\(trace.id)")
                }
                if traces.isEmpty {
                    Text("No traces match in this window.").font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text3).padding(12)
                }
            }
        }
    }
}

/// A trace as Jaeger and Grafana draw it: each span a bar where it ran,
/// under its parent, in its service's colour; a span picked, its attributes.
private struct WaterfallView: View {
    let trace: TraceDetail
    @ObservedObject var theme: ChromeTheme
    @State private var picked: String?

    var body: some View {
        let rows = trace.rows
        let services = trace.services
        let start = trace.start
        let total = max(Double(trace.end - start), 1)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(verbatim: trace.id).font(.system(size: ChromeMetrics.text(11), design: .monospaced)).foregroundStyle(theme.accentText)
                    .textSelection(.enabled)
                Text(verbatim: ObservabilityRows.milliseconds(trace.durationMs))
                Text(verbatim: "\(trace.spans.count) spans")
                ForEach(Array(services.enumerated()), id: \.offset) { index, service in
                    HStack(spacing: 3) {
                        Circle().fill(ObservabilityResultView.color(index)).frame(width: 7, height: 7)
                        Text(verbatim: service)
                    }
                }
                Spacer()
            }
            .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text2)
            .padding(.horizontal, 10).frame(height: ChromeMetrics.row(26))
            Rectangle().fill(theme.border.opacity(0.5)).frame(height: 1)
            HSplitOrStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            let color = ObservabilityResultView.color(services.firstIndex(of: row.span.service) ?? 0)
                            HStack(spacing: 0) {
                                HStack(spacing: 4) {
                                    Rectangle().fill(color).frame(width: 3, height: 14)
                                    Text(verbatim: row.span.service).foregroundStyle(theme.text3)
                                    Text(verbatim: row.span.name).foregroundStyle(row.span.failed ? DiffColors.removed : theme.text)
                                }
                                .font(.system(size: ChromeMetrics.text(11)))
                                .lineLimit(1)
                                .padding(.leading, CGFloat(row.depth) * 12)
                                .frame(width: 300, alignment: .leading)
                                GeometryReader { geometry in
                                    let x = geometry.size.width * Double(row.span.startNanos - start) / total
                                    let width = max(2, geometry.size.width * Double(row.span.endNanos - row.span.startNanos) / total)
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 2).fill(row.span.failed ? DiffColors.removed : color)
                                            .frame(width: width, height: 10).offset(x: x)
                                        Text(verbatim: ObservabilityRows.milliseconds(row.span.durationMs))
                                            .font(.system(size: ChromeMetrics.text(9.5), design: .monospaced)).foregroundStyle(theme.text3)
                                            .offset(x: min(x + width + 4, max(0, geometry.size.width - 60)))
                                    }
                                    .frame(maxHeight: .infinity)
                                }
                            }
                            .padding(.horizontal, 10).frame(height: ChromeMetrics.row(22))
                            .background(picked == row.id ? theme.selected : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture { picked = picked == row.id ? nil : row.id }
                        }
                    }
                }
                if let span = trace.spans.first(where: { $0.id == picked }) { details(span) }
            }
        }
        .accessibilityIdentifier("traceWaterfall")
    }

    private func details(_ span: TraceSpan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: span.name).font(.system(size: ChromeMetrics.text(12), weight: .semibold)).foregroundStyle(theme.text)
                Text(verbatim: "\(span.service) · \(span.kind) · \(ObservabilityRows.milliseconds(span.durationMs))\(span.failed ? " · error" : "")")
                    .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text2)
                Text(verbatim: "span \(span.id)").font(.system(size: ChromeMetrics.text(10.5), design: .monospaced)).foregroundStyle(theme.text3)
                    .textSelection(.enabled)
                ForEach(Array(span.attributes.enumerated()), id: \.offset) { _, attribute in
                    HStack(alignment: .top, spacing: 6) {
                        Text(verbatim: attribute.key).foregroundStyle(theme.text3).frame(width: 150, alignment: .leading)
                        Text(verbatim: attribute.value).foregroundStyle(theme.text).textSelection(.enabled)
                    }
                    .font(.system(size: ChromeMetrics.text(10.5), design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(width: 320)
        .background(theme.rowHover.opacity(0.4))
    }
}

/// Side by side.
private struct HSplitOrStack<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View { HStack(spacing: 0) { content } }
}
