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
        .background(theme.strip)
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
                    Image(systemName: "cylinder").font(.system(size: 10))
                    Text(verbatim: console.connection?.name ?? "Choose a connection").font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    if let state = console.session?.state { stateDot(state) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("consoleConnection")
            if let session = console.session, !session.schemas.isEmpty {
                Menu {
                    ForEach(session.schemas, id: \.self) { schema in
                        Button(schema) { session.schema = schema }
                    }
                } label: {
                    Text(verbatim: session.schema ?? "schema").font(.system(size: 11.5)).foregroundStyle(theme.text2)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("The schema completion and unqualified names are about")
            }
            Spacer(minLength: 4)
            if console.isRunning {
                ProgressView().controlSize(.mini)
                Button("Stop", action: console.stop).controlSize(.small)
            }
            Button(action: runStatement) {
                Label("Run", systemImage: "play.fill").font(.system(size: 11.5))
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
        .frame(height: 32)
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
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(DiffColors.removed)
                        }
                        Text(verbatim: Self.title(run, index: index)).font(.system(size: 11)).lineLimit(1)
                        Button {
                            console.close(run)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .opacity(picked ? 1 : 0.5)
                    }
                    .foregroundStyle(picked ? theme.text : theme.text2)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
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
    static func title(_ run: SQLConsole.Run, index: Int) -> String {
        let verb = SQLText.verb(of: run.sql).capitalized
        if let table = SQLText.tables(in: run.sql).first?.name { return "\(verb) \(table)" }
        return verb.isEmpty ? "Result \(index + 1)" : verb
    }

    @ViewBuilder private func body(of run: SQLConsole.Run) -> some View {
        if let error = run.error {
            ScrollView {
                Text(verbatim: error).font(.system(size: 12, design: .monospaced)).foregroundStyle(DiffColors.removed)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        } else if let result = run.result {
            if result.hasRows {
                ResultGrid(result: result, theme: theme, table: SQLText.tables(in: run.sql).first?.name ?? "table_name")
                status(result, sql: run.sql)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: Self.summary(result)).font(.system(size: 12)).foregroundStyle(theme.text)
                    Text(verbatim: run.sql).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3).lineLimit(3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
            }
        } else {
            Text("Running…").font(.system(size: 12)).foregroundStyle(theme.text3)
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
            Text(verbatim: Self.summary(result)).font(.system(size: 11)).foregroundStyle(result.truncated ? theme.orangeText : theme.text3)
                .help(result.truncated ? "More rows than Settings ▸ Database ▸ Rows fetched" : "")
            Spacer(minLength: 0)
            Menu {
                ForEach(ResultExport.Format.allCases) { format in
                    Button("Save as \(format.title)…") { save(result, sql: sql, format: format) }
                }
            } label: {
                Image(systemName: "square.and.arrow.down").font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Save the rows")
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
    }

    private func save(_ result: QueryResult, sql: String, format: ResultExport.Format) {
        let panel = NSSavePanel()
        let table = SQLText.tables(in: sql).first?.name ?? "result"
        panel.nameFieldStringValue = "\(table).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? ResultExport.text(format, columns: result.columns, rows: result.rows, table: table).write(to: url, atomically: true, encoding: .utf8)
    }
}
