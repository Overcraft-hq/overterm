import AppKit
import SwiftUI

/// What the Database panel asks the window to do.
struct DatabaseActions {
    /// New Connection… (a kind preset), Edit Connection… (nil: new).
    var edit: (DatabaseConnection?, DatabaseKind?) -> Void
    var delete: (DatabaseConnection) -> Void
    /// The connection's console in the editor.
    var console: (DatabaseConnection) -> Void
    /// A query in the connection's console, run.
    var run: (DatabaseConnection, String) -> Void
}

/// The sidebar's Database panel: the saved connections, and under each one
/// its schemas, their tables and views, their columns — read as each opens.
struct DatabasePanelView: View {
    @ObservedObject var model: DatabaseModel
    @ObservedObject var store: DatabaseStore
    @ObservedObject var theme: ChromeTheme
    let actions: DatabaseActions

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.connections.isEmpty {
                empty
            } else {
                filterField
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.connections) { connection in
                            ConnectionTree(
                                connection: connection, session: model.session(connection), model: model, theme: theme, actions: actions)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private var header: some View {
        PanelHeader(title: "Database", group: nil, theme: theme) {
            Menu {
                ForEach(DatabaseKind.allCases) { kind in
                    Button(kind.title) { actions.edit(nil, kind) }
                }
            } label: {
                Image(systemName: "plus").font(.system(size: 11)).frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New Connection")
            .accessibilityIdentifier("databaseNew")
            PanelHeaderButton(
                symbol: "arrow.clockwise", help: "Read the catalogs again",
                action: {
                    for session in model.sessions.values where session.isOpen { Task { await session.reloadCatalog() } }
                }, theme: theme)
        }
    }

    private var filterField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(theme.text3)
            TextField("Filter tables", text: $model.filter).textFieldStyle(.plain).font(.system(size: 12))
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.rowHover.opacity(0.7)))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No connections yet").font(.system(size: 12)).foregroundStyle(theme.text2)
            Text("PostgreSQL, MySQL, SQLite, Redshift, ClickHouse or BigQuery. Passwords and keys stay in your keychain.")
                .font(.system(size: 11.5)).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
            ForEach(DatabaseKind.allCases) { kind in
                Button {
                    actions.edit(nil, kind)
                } label: {
                    Label(kind.title, systemImage: "plus").font(.system(size: 11.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accentText)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

/// A connection and what is under it, as far as it is open.
private struct ConnectionTree: View {
    let connection: DatabaseConnection
    @ObservedObject var session: DatabaseSession
    @ObservedObject var model: DatabaseModel
    @ObservedObject var theme: ChromeTheme
    let actions: DatabaseActions

    private var key: String { connection.id.uuidString }

    var body: some View {
        TreeRow(
            depth: 0, open: model.expanded.contains(key), symbol: "cylinder", title: connection.name, detail: connection.summary,
            dot: dot, theme: theme
        ) {
            toggle(key) { await session.open() }
        }
        .contextMenu {
            Button("New Console") { actions.console(connection) }
            if session.isOpen {
                Button("Disconnect") { model.disconnect(connection) }
            } else {
                Button("Connect") { open(key) }
            }
            Divider()
            Button("Edit Connection…") { actions.edit(connection, nil) }
            Button("Duplicate") {
                var copy = connection
                copy.id = UUID()
                copy.name += " copy"
                try? model.store.save(
                    copy, password: model.store.secrets.value(.password, for: connection.id),
                    serviceAccount: model.store.secrets.value(.serviceAccount, for: connection.id))
            }
            Button("Delete Connection…") { actions.delete(connection) }
        }
        .accessibilityIdentifier("connection-\(connection.name)")
        if model.expanded.contains(key) {
            switch session.state {
            case .connecting:
                note("Connecting…", depth: 1)
            case .failed(let message):
                note(message, depth: 1, error: true)
            case .open:
                ForEach(session.schemas, id: \.self) { schema in schemaTree(schema) }
            case .closed:
                EmptyView()
            }
        }
    }

    private var dot: Color? {
        switch session.state {
        case .open: TabStatusStyle.done
        case .failed: DiffColors.removed
        case .connecting: theme.orangeText
        case .closed: nil
        }
    }

    @ViewBuilder private func schemaTree(_ schema: String) -> some View {
        let key = "\(self.key)/\(schema)"
        TreeRow(
            depth: 1, open: model.expanded.contains(key), symbol: "folder", title: schema,
            detail: session.schema == schema ? "default" : nil, dot: nil, theme: theme
        ) {
            toggle(key) {
                await session.loadTables(schema)
                await session.loadColumns(schema)
            }
        }
        .contextMenu {
            Button("Use as Default Schema") { session.schema = schema }
            Button("Copy Name") { copy(schema) }
        }
        if model.expanded.contains(key) {
            if let tables = session.tables[schema] {
                let shown = model.filter.isEmpty ? tables : tables.filter { $0.name.localizedCaseInsensitiveContains(model.filter) }
                if shown.isEmpty { note(tables.isEmpty ? "No tables" : "Nothing matches", depth: 2) }
                ForEach(shown, id: \.self) { table in tableTree(table) }
            } else {
                note("Reading…", depth: 2)
            }
        }
    }

    @ViewBuilder private func tableTree(_ table: CatalogTable) -> some View {
        let key = "\(self.key)/\(table.schema)/\(table.name)"
        TreeRow(
            depth: 2, open: model.expanded.contains(key), symbol: table.isView ? "eye" : "tablecells", title: table.name, detail: nil,
            dot: nil, theme: theme
        ) {
            toggle(key) { await session.loadColumns(table.schema) }
        }
        .contextMenu {
            Button("Select Top 100") { actions.run(connection, select(table, limit: 100)) }
            Button("New Console") { actions.console(connection) }
            Divider()
            Button("Copy Name") { copy(table.name) }
            Button("Copy Qualified Name") { copy(qualified(table)) }
            Button("Copy SELECT") { copy(select(table, limit: 100)) }
        }
        if model.expanded.contains(key) {
            let columns = session.columns(of: table.name, in: table.schema)
            ForEach(columns, id: \.self) { column in
                TreeRow(depth: 3, open: nil, symbol: "line.3.horizontal", title: column.name, detail: column.type, dot: nil, theme: theme) {}
                    .contextMenu { Button("Copy Name") { copy(column.name) } }
            }
        }
    }

    private func qualified(_ table: CatalogTable) -> String {
        switch connection.kind {
        case .sqlite: return quote(table.name)
        case .bigquery: return "`\(connection.project).\(table.schema).\(table.name)`"
        default: return "\(quote(table.schema)).\(quote(table.name))"
        }
    }

    /// A name quoted only when it has to be.
    private func quote(_ name: String) -> String {
        let plain = name.range(of: #"^[a-z_][a-z0-9_]*$"#, options: .regularExpression) != nil
        if plain { return name }
        return connection.kind == .mysql || connection.kind == .clickhouse ? "`\(name)`" : "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func select(_ table: CatalogTable, limit: Int) -> String {
        "SELECT * FROM \(qualified(table)) LIMIT \(limit);"
    }

    private func toggle(_ key: String, load: @escaping () async -> Void) {
        if model.expanded.contains(key) {
            model.expanded.remove(key)
        } else {
            open(key, load: load)
        }
    }

    private func open(_ key: String, load: (() async -> Void)? = nil) {
        model.expanded.insert(key)
        Task { await (load ?? { await session.open() })() }
    }

    private func note(_ text: String, depth: Int, error: Bool = false) -> some View {
        Text(verbatim: text).font(.system(size: 11)).foregroundStyle(error ? DiffColors.removed : theme.text3)
            .lineLimit(4).textSelection(.enabled)
            .padding(.leading, 28 + CGFloat(depth) * 14).padding(.trailing, 8).padding(.vertical, 3)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One row of the tree: its chevron (nil: a leaf), glyph, name, a detail.
private struct TreeRow: View {
    let depth: Int
    let open: Bool?
    let symbol: String
    let title: String
    let detail: String?
    let dot: Color?
    @ObservedObject var theme: ChromeTheme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: open == true ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold)).frame(width: 10).opacity(open == nil ? 0 : 1)
            Image(systemName: symbol).font(.system(size: 10.5)).frame(width: 14)
            Text(verbatim: title).font(.system(size: 12)).foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            if let detail {
                Text(verbatim: detail).font(.system(size: 10.5)).foregroundStyle(theme.text3).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.text2)
        .padding(.leading, 8 + CGFloat(depth) * 14)
        .padding(.trailing, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? theme.rowHover : .clear).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help(detail.map { "\(title) — \($0)" } ?? title)
    }
}
