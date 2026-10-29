import AppKit
import SwiftUI

/// The detail's tabs.
enum ContainerTab: String, CaseIterable, Identifiable {
    case overview, logs, files, inspect, stats

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// What the log shows: a word in it, how bad a line must be, and — for a
/// compose project's — whose. Pure.
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
    /// One service's lines; nil, every service's.
    var service: String?

    var isEmpty: Bool { text.isEmpty && level == .all && service == nil }

    func matches(_ line: DockerLogLine) -> Bool {
        if let service, line.service != service { return false }
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

/// The Logs tab: followed, filtered, coloured by level — a container's,
/// or a compose project's services' merged.
struct DockerLogsPane: View {
    @ObservedObject var feed: DockerLogFeed
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions
    /// A compose project's services, for the picker; with `service`, the
    /// one shown (the project's session keeps it).
    var services: [String] = []
    var service: Binding<String?>? = nil
    /// Lines picked out of it, to an agent (`DockerLogTextView`).
    var ask: ((String) -> Void)? = nil
    @State private var filter = DockerLogFilter()
    @State private var wrap = true
    @State private var timestamps = true

    /// The field's and the level's filter, narrowed to the service picked.
    private var effective: DockerLogFilter {
        var filter = filter
        filter.service = service?.wrappedValue
        return filter
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(theme.border).frame(height: 1)
            let filter = effective
            let shown = filter.isEmpty ? feed.lines : feed.lines.filter(filter.matches)
            if let note = Self.note(lines: feed.lines.count, shown: shown.count, filter: filter, following: feed.following) {
                Text(verbatim: note).font(.system(size: 12)).foregroundStyle(theme.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let text = theme.textNS
                let stamps = timestamps
                DockerTextView(
                    count: shown.count,
                    // Filtered, it is another text: drawn again, not added to.
                    revision: feed.revision
                        &+ (filter.isEmpty ? 0 : filter.text.hashValue &+ filter.level.hashValue &+ (filter.service?.hashValue ?? 0) &+ 1)
                        &+ (timestamps ? 0 : 7),
                    render: { range in
                        shown[range].map { DockerLogStyle.line($0, text: text, dim: text.withAlphaComponent(0.45), timestamps: stamps) }
                    },
                    wrap: wrap, follow: true, ask: ask)
            }
        }
    }

    /// What the pane says in place of its lines: none at all, or none
    /// from the service picked — a filter over the project's feed, said
    /// rather than left blank. Each service keeps its last lines there
    /// (`DockerLogFeed.keepEach`), so none is none. Nil: the lines. Pure.
    nonisolated static func note(lines: Int, shown: Int, filter: DockerLogFilter, following: Bool) -> String? {
        if lines == 0 { return following ? "Nothing written yet." : "No logs." }
        guard shown == 0, let service = filter.service else { return nil }
        return filter.text.isEmpty && filter.level == .all ? "Nothing from \(service) yet." : "Nothing from \(service) matches."
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
            if let service, services.count > 1 {
                Picker("", selection: service) {
                    Text("All services").tag(String?.none)
                    ForEach(services, id: \.self) { Text(verbatim: $0).tag(Optional($0)) }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("One service's lines, or all of them merged")
                .accessibilityIdentifier("docker.logs.service")
            }
            HStack(spacing: 4) {
                DockerStatusDot(color: feed.following ? TabStatusStyle.done : theme.text3)
                Text(feed.following ? "Following" : "Stopped").font(.system(size: 11)).foregroundStyle(theme.text3)
            }
            .help(feed.following ? "New lines appear as they are written" : "Nothing runs: its log is followed again when it starts")
            Menu {
                Toggle("Wrap Lines", isOn: $wrap)
                Toggle("Timestamps", isOn: $timestamps)
                Divider()
                Button("Clear") { feed.clear() }
                if let command = feed.terminalCommand { Button("Follow in a Terminal Tab") { actions.run(command, nil) } }
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

/// The Files tab: a folder at a time, a file to the editor (saved back
/// into the container), or to the Mac (`DockerFolderList`); or what
/// changed since it started.
struct DockerFilesPane: View {
    let container: ContainerSummary
    @ObservedObject var session: ContainerSession
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions
    @State private var showingChanges = false

    var body: some View {
        Group {
            if showingChanges {
                VStack(spacing: 0) {
                    HStack(spacing: 2) {
                        picker
                        Spacer(minLength: 6)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    Rectangle().fill(theme.border).frame(height: 1)
                    changes
                }
            } else {
                DockerFolderList(browser: session, source: .of(container), theme: theme, actions: actions, leading: AnyView(picker))
            }
        }
        .onChange(of: showingChanges) { on in if on { session.loadChanges() } }
    }

    private var picker: some View {
        Picker("", selection: $showingChanges) {
            Text("Folders").tag(false)
            Text("Changes").tag(true)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
        .help("What it wrote, added and deleted since it started")
    }

    /// Since it started: added, modified, deleted — a file a click from
    /// the editor.
    private var changes: some View {
        List {
            if let changes = session.changes {
                if changes.isEmpty { Text("Nothing changed since it started.").font(.system(size: 12)).foregroundStyle(theme.text3) }
                ForEach(changes, id: \.Path) { change in
                    let (mark, color): (String, Color) =
                        switch change.Kind {
                        case .added: ("A", TabStatusStyle.done)
                        case .modified: ("M", TabStatusStyle.waiting)
                        case .deleted: ("D", TabStatusStyle.failed)
                        }
                    Button {
                        if change.Kind != .deleted { actions.openFile(.of(container), change.Path) }
                    } label: {
                        HStack(spacing: 8) {
                            Text(verbatim: mark).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(color).frame(width: 14)
                            Text(verbatim: change.Path).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.text).lineLimit(1)
                                .truncationMode(.head)
                            Spacer()
                        }
                        .frame(height: 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("docker.changes")
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
                    if let top = session.processes { processes(top) }
                }
                .padding(16)
            } else {
                ProgressView().controlSize(.small).padding(20)
            }
        }
        .accessibilityIdentifier("docker.stats")
    }

    static func bytes(_ count: Int) -> String { DockerBytes.string(count, memory: true) }

    /// `top`'s table: its own columns, its command last and widest.
    private func processes(_ top: (titles: [String], rows: [[String]])) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Processes").font(.system(size: 11, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    ForEach(Array(top.titles.enumerated()), id: \.offset) { _, title in
                        Text(verbatim: title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(theme.text3)
                    }
                }
                ForEach(Array(top.rows.prefix(100).enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                            Text(verbatim: cell).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                .frame(maxWidth: index == row.count - 1 ? .infinity : nil, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.rowHover.opacity(0.6)))
        .accessibilityIdentifier("docker.processes")
    }

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
