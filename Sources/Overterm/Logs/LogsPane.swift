import AppKit
import SwiftUI

/// What the log shows: a word in it, how bad a line must be, and — for
/// merged logs (a compose project's) — whose. Pure.
struct LogFilter: Equatable {
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
    /// One source's lines (a service's); nil, every one's.
    var source: String?

    var isEmpty: Bool { text.isEmpty && level == .all && source == nil }

    func matches(_ line: LogLine) -> Bool {
        if let source, line.source != source { return false }
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

/// A Logs tab: followed, filtered, coloured by level — one source's (a
/// container's), or several merged (a compose project's services').
struct LogsPane: View {
    @ObservedObject var feed: LogFeed
    @ObservedObject var theme: ChromeTheme
    /// Its accessibility identifiers' first word: `docker` makes
    /// `docker.logs.filter`, `docker.logs.service` and `docker.text`.
    let identifier: String
    /// Types a command into a new terminal tab: the feed's
    /// `terminalCommand`, Follow in a Terminal Tab.
    let runInTerminal: (String) -> Void
    /// The merged feed's sources, for the picker; with `source`, the one
    /// shown (the project's session keeps it).
    var sources: [String] = []
    var source: Binding<String?>? = nil
    /// What a source is called in the picker: a service.
    var noun = "service"
    /// Lines picked out of it, to an agent (`LogLinesTextView`).
    var ask: ((String) -> Void)? = nil
    @State private var filter = LogFilter()
    @State private var wrap = true
    @State private var timestamps = true

    /// The field's and the level's filter, narrowed to the source picked.
    private var effective: LogFilter {
        var filter = filter
        filter.source = source?.wrappedValue
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
                LogTextView(
                    count: shown.count,
                    // Filtered, it is another text: drawn again, not added to.
                    revision: feed.revision
                        &+ (filter.isEmpty ? 0 : filter.text.hashValue &+ filter.level.hashValue &+ (filter.source?.hashValue ?? 0) &+ 1)
                        &+ (timestamps ? 0 : 7),
                    render: { range in
                        shown[range].map { LogStyle.line($0, text: text, dim: text.withAlphaComponent(0.45), timestamps: stamps) }
                    },
                    wrap: wrap, follow: true, ask: ask, identifier: identifier + ".text")
            }
        }
    }

    /// What the pane says in place of its lines: none at all, or none
    /// from the source picked — a filter over the merged feed, said rather
    /// than left blank. Each source keeps its last lines there
    /// (`LogFeed.keepEach`), so none is none. Nil: the lines. Pure.
    nonisolated static func note(lines: Int, shown: Int, filter: LogFilter, following: Bool) -> String? {
        if lines == 0 { return following ? "Nothing written yet." : "No logs." }
        guard shown == 0, let source = filter.source else { return nil }
        return filter.text.isEmpty && filter.level == .all ? "Nothing from \(source) yet." : "Nothing from \(source) matches."
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(theme.text3)
                TextField("Filter the log", text: $filter.text).textFieldStyle(.plain).font(.system(size: 12))
                    .accessibilityIdentifier(identifier + ".logs.filter")
            }
            .padding(.horizontal, 7)
            .frame(minWidth: 100, maxWidth: .infinity)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.rowHover.opacity(0.7)))
            Picker("", selection: $filter.level) {
                ForEach(LogFilter.Level.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("Lines shown: all, warnings and errors (stderr's unlevelled lines too), or errors")
            if let source, sources.count > 1 {
                Picker("", selection: source) {
                    Text(verbatim: "All \(noun)s").tag(String?.none)
                    ForEach(sources, id: \.self) { Text(verbatim: $0).tag(Optional($0)) }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("One \(noun)'s lines, or all of them merged")
                .accessibilityIdentifier(identifier + ".logs.service")
            }
            HStack(spacing: 4) {
                Circle().fill(feed.following ? TabStatusStyle.done : theme.text3).frame(width: 7, height: 7)
                Text(feed.following ? "Following" : "Stopped").font(.system(size: 11)).foregroundStyle(theme.text3)
            }
            .help(feed.following ? "New lines appear as they are written" : "Nothing runs: its log is followed again when it starts")
            Menu {
                Toggle("Wrap Lines", isOn: $wrap)
                Toggle("Timestamps", isOn: $timestamps)
                Divider()
                Button("Clear") { feed.clear() }
                if let command = feed.terminalCommand { Button("Follow in a Terminal Tab") { runInTerminal(command) } }
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
