import AppKit
import SwiftUI

/// The detail's tabs.
enum ContainerTab: String, CaseIterable, Identifiable {
    case overview, logs, inspect, stats

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// What the log shows: a word in it, and how bad a line must be. Pure.
struct DockerLogFilter: Equatable {
    enum Level: String, CaseIterable, Identifiable {
        case all, warnings, errors

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All levels"
            case .warnings: "Warnings+"
            case .errors: "Errors"
            }
        }
    }

    var text = ""
    var level = Level.all

    var isEmpty: Bool { text.isEmpty && level == .all }

    func matches(_ line: DockerLogLine) -> Bool {
        switch level {
        case .all: break
        // A line nobody levelled isn't taken for a warning, but stderr's
        // unlevelled lines are kept: that is where most errors go.
        case .warnings: guard (line.level ?? (line.stream == .stderr ? .warning : .info)) >= .warning else { return false }
        case .errors: guard (line.level ?? .info) >= .error else { return false }
        }
        guard !text.isEmpty else { return true }
        return line.message.localizedCaseInsensitiveContains(text) || line.fields.contains { $0.1.localizedCaseInsensitiveContains(text) }
    }
}

/// The Logs tab: followed, filtered, coloured by level.
struct DockerLogsPane: View {
    let container: ContainerSummary
    @ObservedObject var session: ContainerSession
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions
    @State private var filter = DockerLogFilter()
    @State private var wrap = true
    @State private var timestamps = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(theme.border).frame(height: 1)
            let shown = filter.isEmpty ? session.lines : session.lines.filter(filter.matches)
            if session.lines.isEmpty {
                Text(session.following ? "Nothing written yet." : "No logs.").font(.system(size: 12)).foregroundStyle(theme.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let text = theme.textNS
                let stamps = timestamps
                DockerTextView(
                    count: shown.count,
                    // Filtered, it is another text: drawn again, not added to.
                    revision: session.linesRevision &+ (filter.isEmpty ? 0 : filter.text.hashValue &+ filter.level.hashValue &+ 1)
                        &+ (timestamps ? 0 : 7),
                    render: { range in
                        shown[range].map { DockerLogStyle.line($0, text: text, dim: text.withAlphaComponent(0.45), timestamps: stamps) }
                    },
                    wrap: wrap, follow: true)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(theme.text3)
                TextField("Filter the log", text: $filter.text).textFieldStyle(.plain).font(.system(size: 12))
                    .accessibilityIdentifier("docker.logs.filter")
            }
            .padding(.horizontal, 7)
            .frame(minWidth: 100, maxWidth: .infinity)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.rowHover.opacity(0.7)))
            Picker("", selection: $filter.level) {
                ForEach(DockerLogFilter.Level.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("Lines shown: all, warnings and errors (stderr's unlevelled lines too), or errors")
            HStack(spacing: 4) {
                DockerStatusDot(color: session.following ? TabStatusStyle.done : theme.text3)
                Text(session.following ? "Following" : "Stopped").font(.system(size: 11)).foregroundStyle(theme.text3)
            }
            .help(session.following ? "New lines appear as they are written" : "The container isn't running; its log is followed again when it starts")
            Menu {
                Toggle("Wrap Lines", isOn: $wrap)
                Toggle("Timestamps", isOn: $timestamps)
                Divider()
                Button("Clear") { session.clearLogs() }
                Button("Follow in a Terminal Tab") { actions.run(DockerCommands.followLogs(of: container, endpoint: DockerModel.shared.endpoint), nil) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// The Inspect tab: the engine's JSON, secrets taken out.
struct DockerInspectPane: View {
    @ObservedObject var session: ContainerSession
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("As the engine says it, secrets hidden").font(.system(size: 11)).foregroundStyle(theme.text3)
                Spacer()
                Button("Copy") { if let json = session.json { actions.copy(json) } }.font(.system(size: 11.5)).disabled(session.json == nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Rectangle().fill(theme.border).frame(height: 1)
            if let json = session.json {
                let lines = json.split(separator: "\n", omittingEmptySubsequences: false)
                DockerTextView(
                    count: lines.count, revision: json.hashValue, render: { range in lines[range].map { Self.line(String($0), theme: theme) } },
                    wrap: false, follow: false)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { session.loadJSON() }
    }

    /// A key in the text colour, its value dimmer.
    static func line(_ text: String, theme: ChromeTheme) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: [.font: DockerLogStyle.font, .foregroundColor: theme.textNS.withAlphaComponent(0.7)])
        if let range = text.range(of: #"^\s*"[^"]+"(?= :)"#, options: .regularExpression) {
            out.addAttribute(.foregroundColor, value: theme.textNS, range: NSRange(range, in: text))
        }
        return out
    }
}

/// The Stats tab: a sample a second while it is open.
struct DockerStatsPane: View {
    let container: ContainerSummary
    @ObservedObject var session: ContainerSession
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        ScrollView {
            if container.state != .running {
                Text("Stats are read while it runs.").font(.system(size: 12)).foregroundStyle(theme.text3).padding(20)
            } else if let usage = session.usage {
                VStack(spacing: 12) {
                    tile(
                        "CPU", String(format: "%.1f%%", usage.cpuPercent), detail: "of one core",
                        values: session.history.map(\.cpuPercent))
                    tile(
                        "Memory", Self.bytes(usage.memoryBytes),
                        detail: usage.memoryLimit > 0 ? String(format: "of %@ — %.1f%%", Self.bytes(usage.memoryLimit), usage.memoryPercent) : "",
                        values: session.history.map { Double($0.memoryBytes) })
                    HStack(alignment: .top, spacing: 12) {
                        tile("Network", "↓ \(Self.bytes(usage.networkIn))", detail: "↑ \(Self.bytes(usage.networkOut))", values: [])
                        tile("Disk", "R \(Self.bytes(usage.diskRead))", detail: "W \(Self.bytes(usage.diskWrite))", values: [])
                        tile("Processes", "\(usage.processes)", detail: " ", values: [])
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            } else {
                ProgressView().controlSize(.small).padding(20)
            }
        }
        .accessibilityIdentifier("docker.stats")
    }

    static func bytes(_ count: Int) -> String { DockerBytes.string(count, memory: true) }

    private func tile(_ title: String, _ value: String, detail: String, values: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
            Text(verbatim: value).font(.system(size: 18, weight: .medium, design: .rounded)).foregroundStyle(theme.text).monospacedDigit()
            if !detail.isEmpty { Text(verbatim: detail).font(.system(size: 11)).foregroundStyle(theme.text2) }
            if values.count > 1 { DockerSparkline(values: values, color: TabStatusStyle.working).frame(height: 34).padding(.top, 4) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.rowHover.opacity(0.6)))
    }
}

/// The last minute as a line, its lowest at the bottom.
struct DockerSparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let top = max(values.max() ?? 1, 0.0001)
            let step = geometry.size.width / CGFloat(max(values.count - 1, 1))
            Path { path in
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: CGFloat(index) * step, y: geometry.size.height * (1 - CGFloat(value / top)))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(color, lineWidth: 1.5)
        }
    }
}
