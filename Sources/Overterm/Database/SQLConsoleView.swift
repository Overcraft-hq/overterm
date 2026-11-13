import AppKit
import SwiftUI

/// Under a `.sql` file in the editor: the connection and schema it runs on,
/// Run (⌘↩), and what came back — a tab a statement, a grid or a message.
struct SQLConsoleView: View {
    @ObservedObject var console: SQLConsole
    @ObservedObject var store: DatabaseStore
    @ObservedObject var theme: ChromeTheme
    let runStatement: () -> Void
    let runAll: () -> Void
    let newConnection: () -> Void
    /// A query from the history, written into the console.
    var insert: (String) -> Void = { _ in }
    /// A trace's id, from a log line — to a Tempo connection's console.
    var openTrace: (String) -> Void = { _ in }
    /// The statement at the caret, or the selection — what Save keeps.
    var statement: () -> String? = { nil }
    @State private var saving = false
    @State private var savedName = ""
    @ObservedObject var model = DatabaseModel.shared

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(theme.border).frame(height: 1)
            toolbar
            if !console.runs.isEmpty {
                tabs
                Rectangle().fill(theme.border.opacity(0.6)).frame(height: 1)
                if let run = console.current { body(of: run) }
            }
        }
        .background(theme.panelGround)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(store.connections) { connection in
                    Button(connection.name) { console.use(connection) }
                }
                if !store.connections.isEmpty { Divider() }
                Button("New Connection…", action: newConnection)
                if console.connection != nil { Button("No Connection") { console.use(nil) } }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cylinder").font(.system(size: ChromeMetrics.text(10)))
                    Text(verbatim: console.connection?.name ?? "Choose a connection").font(.system(size: ChromeMetrics.text(11.5), weight: .medium)).lineLimit(1)
                    if let state = console.session?.state { stateDot(state) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("consoleConnection")
            if let session = console.session, session.connection.kind.isObservability {
                RangeMenu(session: session, theme: theme)
            } else if let session = console.session, !session.schemas.isEmpty {
                Menu {
                    ForEach(session.schemas, id: \.self) { schema in
                        Button(schema) { session.schema = schema }
                    }
                } label: {
                    Text(verbatim: session.schema ?? "schema").font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text2)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("The schema completion and unqualified names are about")
            }
            Spacer(minLength: 4)
            if let connection = console.connection {
                let recent = model.history.filter { $0.connection == connection.id }.prefix(25)
                Menu {
                    if recent.isEmpty { Text("Nothing run yet") }
                    ForEach(Array(recent)) { item in
                        Button((item.error == nil ? "" : "⚠︎ ") + item.sql.replacingOccurrences(of: "\n", with: " ").prefix(80)) { insert(item.sql) }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: ChromeMetrics.text(11)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("What was run on this connection — chosen, it goes into the console")
            }
            if let connection = console.connection {
                Button {
                    savedName = statement().flatMap { connection.kind.subject(of: $0) } ?? ""
                    saving = true
                } label: {
                    Image(systemName: "bookmark").font(.system(size: ChromeMetrics.text(11)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.text2)
                .help("Save the query at the caret — under the connection in the panel")
                .accessibilityIdentifier("consoleSave")
                .popover(isPresented: $saving, arrowEdge: .bottom) { savePopover(connection) }
            }
            if console.isRunning {
                ProgressView().controlSize(.mini)
                Button("Stop", action: console.stop).controlSize(.small)
            }
            Button(action: runStatement) {
                Label("Run", systemImage: "play.fill").font(.system(size: ChromeMetrics.text(11.5)))
            }
            .controlSize(.small)
            .disabled(console.connection == nil || console.isRunning)
            .help("Run the statement at the caret, or the selection (⌘↩)")
            .accessibilityIdentifier("consoleRun")
            Button("Run All", action: runAll)
                .controlSize(.small)
                .disabled(console.connection == nil || console.isRunning)
                .help("Run every statement of the file, in order")
        }
        .padding(.horizontal, 10)
        .frame(height: ChromeMetrics.row(32))
    }

    private func savePopover(_ connection: DatabaseConnection) -> some View {
        let text = statement() ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            Text("Save Query").font(.system(size: ChromeMetrics.text(12), weight: .semibold))
            TextField("Name", text: $savedName).textFieldStyle(.roundedBorder).frame(width: 260)
                .onSubmit { keep(text, connection) }
            Text(verbatim: text.isEmpty ? "Put the caret in a query first." : text).font(.system(size: ChromeMetrics.text(11), design: .monospaced))
                .foregroundStyle(theme.text3).lineLimit(4).frame(width: 260, alignment: .leading)
            HStack {
                Text(verbatim: "Under \(connection.name) in the panel").font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3)
                Spacer()
                Button("Save") { keep(text, connection) }.keyboardShortcut(.defaultAction)
                    .disabled(text.isEmpty || savedName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
    }

    private func keep(_ text: String, _ connection: DatabaseConnection) {
        guard !text.isEmpty, !savedName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.save(savedName, text: text, on: connection.id)
        // The panel shows where it went.
        model.expanded.insert(connection.id.uuidString)
        model.expanded.insert("\(connection.id.uuidString)/saved")
        saving = false
    }

    private func stateDot(_ state: DatabaseSession.State) -> some View {
        let color: Color =
            switch state {
            case .open: TabStatusStyle.done
            case .failed: DiffColors.removed
            case .connecting: theme.orangeText
            case .closed: theme.text3
            }
        return Circle().fill(color).frame(width: 6, height: 6)
    }

    // MARK: Results

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(console.runs.enumerated()), id: \.element.id) { index, run in
                    let picked = run.id == (console.current?.id)
                    HStack(spacing: 4) {
                        if run.running {
                            ProgressView().controlSize(.mini).scaleEffect(0.7)
                        } else if run.error != nil {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: ChromeMetrics.text(9))).foregroundStyle(DiffColors.removed)
                        }
                        Text(verbatim: Self.title(run, index: index, kind: console.connection?.kind ?? .postgres)).font(.system(size: ChromeMetrics.text(11))).lineLimit(1)
                        Button {
                            console.close(run)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: ChromeMetrics.text(7), weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .opacity(picked ? 1 : 0.5)
                    }
                    .foregroundStyle(picked ? theme.text : theme.text2)
                    .padding(.horizontal, 8)
                    .frame(height: ChromeMetrics.row(22))
                    .background(RoundedRectangle(cornerRadius: 5).fill(picked ? theme.selected : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { console.selected = run.id }
                    .help(run.sql)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
    }

    /// A tab's name: the statement's verb and its first table, else its start.
    static func title(_ run: SQLConsole.Run, index: Int, kind: DatabaseKind = .postgres) -> String {
        if kind.isObservability { return kind.subject(of: run.sql) ?? "Query \(index + 1)" }
        let verb = kind.verb(of: run.sql).capitalized
        if let table = kind.subject(of: run.sql) { return "\(verb) \(table)" }
        return verb.isEmpty ? "Result \(index + 1)" : verb
    }

    @ViewBuilder private func body(of run: SQLConsole.Run) -> some View {
        if let error = run.error {
            ScrollView {
                Text(verbatim: error).font(.system(size: ChromeMetrics.text(12), design: .monospaced)).foregroundStyle(DiffColors.removed)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        } else if let result = run.result {
            if let payload = result.payload {
                ObservabilityResultView(
                    run: run, payload: payload, result: result, console: console, theme: theme,
                    openTrace: { id in
                        // Tempo's own console opens it as a tab; Loki's asks a Tempo connection.
                        if console.connection?.kind == .tempo { console.run([id]) } else { openTrace(id) }
                    },
                    grid: { AnyView(ResultGrid(result: result, theme: theme, table: "result")) })
                status(result, sql: run.sql)
            } else if result.hasRows {
                ResultGrid(result: result, theme: theme, table: SQLText.tables(in: run.sql).first?.name ?? "table_name")
                status(result, sql: run.sql)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: Self.summary(result)).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text)
                    Text(verbatim: run.sql).font(.system(size: ChromeMetrics.text(11), design: .monospaced)).foregroundStyle(theme.text3).lineLimit(3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
            }
        } else {
            Text("Running…").font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    static func summary(_ result: QueryResult) -> String {
        var parts: [String] = []
        if result.hasRows {
            parts.append(result.truncated ? "first \(result.rows.count) rows" : "\(result.rows.count) row\(result.rows.count == 1 ? "" : "s")")
        } else if let affected = result.affected {
            parts.append("\(affected) row\(affected == 1 ? "" : "s") affected")
        } else {
            parts.append(result.message ?? "Done")
        }
        parts.append(Self.duration(result.duration))
        if result.hasRows, let message = result.message { parts.append(message) }
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int(seconds * 1000)) ms" : String(format: "%.2f s", seconds)
    }

    private func status(_ result: QueryResult, sql: String) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: Self.summary(result)).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(result.truncated ? theme.orangeText : theme.text3)
                .help(result.truncated ? "More rows than Settings ▸ Database ▸ Rows fetched" : "")
            Spacer(minLength: 0)
            Menu {
                ForEach(ResultExport.Format.allCases) { format in
                    Button("Save as \(format.title)…") { save(result, sql: sql, format: format) }
                }
            } label: {
                Image(systemName: "square.and.arrow.down").font(.system(size: ChromeMetrics.text(11)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Save the rows")
        }
        .padding(.horizontal, 10)
        .frame(height: ChromeMetrics.row(24))
    }

    private func save(_ result: QueryResult, sql: String, format: ResultExport.Format) {
        let panel = NSSavePanel()
        let table = (console.connection?.kind ?? .postgres).subject(of: sql) ?? "result"
        panel.nameFieldStringValue = "\(table).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? ResultExport.text(format, columns: result.columns, rows: result.rows, table: table).write(to: url, atomically: true, encoding: .utf8)
    }
}

/// The window a Prometheus, Loki or Tempo console's queries look at.
private struct RangeMenu: View {
    @ObservedObject var session: DatabaseSession
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        Menu {
            ForEach(TimeRange.allCases) { range in
                Button(range.title) { session.range = range }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "clock").font(.system(size: ChromeMetrics.text(10)))
                Text(verbatim: session.range.title).font(.system(size: ChromeMetrics.text(11.5)))
            }
            .foregroundStyle(theme.text2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("The window every query looks at, up to now")
        .accessibilityIdentifier("consoleRange")
    }
}
