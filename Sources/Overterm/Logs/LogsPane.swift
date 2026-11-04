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
    /// The text is a regular expression (case aside).
    var regex = false
    /// The text marks the lines it matches rather than picking them out.
    var highlight = false

    /// Whether the text picks lines: it marks them instead, highlighting.
    var picksByText: Bool { !text.isEmpty && !highlight }
    var isEmpty: Bool { !picksByText && level == .all && source == nil }

    /// The text as a regular expression: itself, or escaped. Nil when
    /// there's none, or it isn't one (`problem` says).
    var expression: NSRegularExpression? {
        guard !text.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: regex ? text : NSRegularExpression.escapedPattern(for: text), options: [.caseInsensitive])
    }

    /// What is wrong with the text: a regular expression that isn't one.
    var problem: String? { regex && !text.isEmpty && expression == nil ? "Not a regular expression" : nil }

    func matches(_ line: LogLine) -> Bool { matcher().matches(line) }

    /// The filter, its expression made once: a log's thousands of lines go through it.
    func matcher() -> Matcher { Matcher(filter: self, expression: regex && picksByText ? expression : nil) }

    struct Matcher {
        let filter: LogFilter
        let expression: NSRegularExpression?

        func matches(_ line: LogLine) -> Bool {
            if let source = filter.source, line.source != source { return false }
            switch filter.level {
            case .all: break
            // A line nobody levelled isn't taken for a warning, but stderr's
            // unlevelled lines are kept: that is where most errors go.
            case .warnings: guard (line.level ?? (line.stream == .stderr ? .warning : .info)) >= .warning else { return false }
            case .errors: guard (line.level ?? .info) >= .error else { return false }
            }
            guard filter.picksByText else { return true }
            if filter.regex {
                // Not a regular expression: nothing is picked out by it (the pane says why).
                guard let expression else { return true }
                func found(_ text: String) -> Bool { expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil }
                return found(line.message) || line.fields.contains { found($0.1) }
            }
            let text = filter.text
            return line.message.localizedCaseInsensitiveContains(text) || line.fields.contains { $0.1.localizedCaseInsensitiveContains(text) }
        }
    }
}

/// How a log is shown, besides its filter: kept per window by a page that
/// keeps them (Kubernetes'), else the pane's own.
struct LogViewOptions: Equatable {
    var wrap = true
    var timestamps = true
    var newestFirst = false
    var regex = false
    var highlight = false
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
    /// The options a page keeps for its window; nil, the pane's own.
    var options: Binding<LogViewOptions>? = nil
    /// Save As…: the lines shown, as text. Nil: not offered.
    var save: ((String) -> Void)? = nil
    /// Scrolled to the oldest line: older ones asked for. Nil: none to ask for.
    var older: (() -> Void)? = nil
    /// What Stopped means, said on it.
    var stoppedHelp = "Nothing runs: its log is followed again when it starts"
    /// Bumped by the page to give the filter field the keyboard (⌘F).
    var focusFilter = 0
    @State private var filter = LogFilter()
    @FocusState private var filterFocused: Bool
    @State private var ownOptions = LogViewOptions()

    private var view: Binding<LogViewOptions> { options ?? $ownOptions }

    /// The field's and the level's filter, narrowed to the source picked,
    /// as a regular expression or marking matches as the options say.
    private var effective: LogFilter {
        var filter = filter
        filter.source = source?.wrappedValue
        filter.regex = view.wrappedValue.regex
        filter.highlight = view.wrappedValue.highlight
        return filter
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(theme.border).frame(height: 1)
            let filter = effective
            let options = view.wrappedValue
            let matcher = filter.matcher()
            let shown = filter.isEmpty ? feed.lines : feed.lines.filter(matcher.matches)
            if let note = Self.note(lines: feed.lines.count, shown: shown.count, filter: filter, following: feed.following) {
                Text(verbatim: note).font(.system(size: 12)).foregroundStyle(theme.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let text = theme.textNS
                let stamps = options.timestamps
                let marked = filter.highlight ? filter.expression : nil
                LogTextView(
                    count: shown.count,
                    // Filtered, it is another text: drawn again, not added to.
                    revision: feed.revision
                        &+ (filter.isEmpty ? 0 : filter.text.hashValue &+ filter.level.hashValue &+ (filter.source?.hashValue ?? 0) &+ (filter.regex ? 3 : 1))
                        &+ (options.timestamps ? 0 : 7) &+ (marked == nil ? 0 : filter.text.hashValue &+ (filter.regex ? 11 : 13)),
                    render: { range in
                        shown[range].map { LogStyle.line($0, text: text, dim: text.withAlphaComponent(0.45), timestamps: stamps, highlight: marked) }
                    },
                    wrap: options.wrap, follow: true, ask: ask, identifier: identifier + ".text", newestFirst: options.newestFirst,
                    prepended: feed.prepended, onOldest: older)
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
                TextField(view.wrappedValue.highlight ? "Find in the log" : "Filter the log", text: $filter.text).textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($filterFocused)
                    .accessibilityIdentifier(identifier + ".logs.filter")
                if let problem = effective.problem {
                    Text(verbatim: problem).font(.system(size: 10.5)).foregroundStyle(TabStatusStyle.failed).lineLimit(1).fixedSize()
                }
                Button {
                    view.wrappedValue.regex.toggle()
                } label: {
                    Text(verbatim: ".*").font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(view.wrappedValue.regex ? theme.accentText : theme.text3)
                }
                .buttonStyle(.plain)
                .help(view.wrappedValue.regex ? "A regular expression (case aside) — click for plain text" : "Plain text — click for a regular expression")
                .accessibilityIdentifier(identifier + ".logs.regex")
                Button {
                    view.wrappedValue.highlight.toggle()
                } label: {
                    Image(systemName: view.wrappedValue.highlight ? "highlighter" : "line.3.horizontal.decrease")
                        .font(.system(size: 10)).foregroundStyle(view.wrappedValue.highlight ? theme.accentText : theme.text3)
                }
                .buttonStyle(.plain)
                .help(view.wrappedValue.highlight ? "Matches are marked, every line shown — click to show only them" : "Only matching lines — click to mark them instead")
                .accessibilityIdentifier(identifier + ".logs.highlight")
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
            .help(feed.following ? "New lines appear as they are written" : stoppedHelp)
            Menu {
                Toggle("Wrap Lines", isOn: view.wrap)
                Toggle("Timestamps", isOn: view.timestamps)
                Toggle("Newest First", isOn: view.newestFirst)
                Divider()
                if let save {
                    Button("Save As…") {
                        let filter = effective
                        let matcher = filter.matcher()
                        save((filter.isEmpty ? feed.lines : feed.lines.filter(matcher.matches)).map(\.plain).joined(separator: "\n") + "\n")
                    }
                }
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
        .onChange(of: focusFilter) { _ in filterFocused = true }
    }
}
