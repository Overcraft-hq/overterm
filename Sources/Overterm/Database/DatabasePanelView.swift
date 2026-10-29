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
    /// A stored file in the right-hand pane.
    var openObject: (StorageSession, String, StorageObject) -> Void = { _, _, _ in }
    /// Asks for a name (title, what it is for), then does it.
    var prompt: (_ title: String, _ detail: String, _ done: @escaping (String) -> Void) -> Void = { _, _, _ in }
    /// Asks before deleting these keys, then deletes them.
    var deleteObjects: (StorageSession, String, [String], _ refreshing: String) -> Void = { _, _, _, _ in }
    /// Files picked in an open panel, uploaded to bucket/prefix.
    var upload: (StorageSession, String, String) -> Void = { _, _, _ in }
    var download: (StorageSession, String, StorageObject) -> Void = { _, _, _ in }
    var copyLink: (StorageSession, String, String) -> Void = { _, _, _ in }
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
                            if connection.kind.isStorage {
                                StorageTree(
                                    connection: connection, session: model.storage(connection), model: model, theme: theme, actions: actions)
                            } else {
                                ConnectionTree(
                                    connection: connection, session: model.session(connection), model: model, theme: theme, actions: actions)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                TransfersFooter(model: model, theme: theme)
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
                symbol: "arrow.clockwise", help: "Read the catalogs and buckets again",
                action: {
                    for session in model.sessions.values where session.isOpen { Task { await session.reloadCatalog() } }
                    for storage in model.storageSessions.values where storage.isOpen { Task { await storage.refresh() } }
                }, theme: theme)
        }
    }

    private var filterField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(theme.text3)
            TextField("Filter", text: $model.filter).textFieldStyle(.plain).font(.system(size: 12))
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
            Text("PostgreSQL, MySQL, SQLite, Redshift, ClickHouse or BigQuery — and S3 or Google Cloud Storage buckets. Passwords and keys stay in your keychain.")
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
    /// Files from Finder held over it.
    var targeted = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: open == true ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold)).frame(width: 10).opacity(open == nil ? 0 : 1)
            Image(systemName: symbol).font(.system(size: 10.5)).frame(width: 14)
            Text(verbatim: title).font(.system(size: 12)).foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            if let detail {
                // A short one whole — "3…es" said nothing about 34 bytes; a long
                // one (a column's type) gives way to the name.
                Text(verbatim: detail).font(.system(size: 10.5)).foregroundStyle(theme.text3).lineLimit(1).truncationMode(.middle)
                    .fixedSize(horizontal: detail.count <= 12, vertical: false)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.text2)
        .padding(.leading, 8 + CGFloat(depth) * 14)
        .padding(.trailing, 8)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(targeted ? theme.accentText.opacity(0.22) : (hovering ? theme.rowHover : .clear))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(targeted ? theme.accentText : .clear, lineWidth: 1))
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help(detail.map { "\(title) — \($0)" } ?? title)
    }
}

// MARK: Storage

/// A bucket store: its buckets, their folders and files — each folder read
/// as it opens, a page at a time; files dropped on a bucket or a folder
/// uploaded there.
private struct StorageTree: View {
    let connection: DatabaseConnection
    @ObservedObject var session: StorageSession
    @ObservedObject var model: DatabaseModel
    @ObservedObject var theme: ChromeTheme
    let actions: DatabaseActions

    private var key: String { connection.id.uuidString }

    var body: some View {
        TreeRow(
            depth: 0, open: model.expanded.contains(key), symbol: connection.kind == .gcs ? "cloud" : "externaldrive.connected.to.line.below",
            title: connection.name, detail: connection.summary, dot: dot, theme: theme
        ) {
            if model.expanded.contains(key) {
                model.expanded.remove(key)
            } else {
                model.expanded.insert(key)
                Task { await session.open() }
            }
        }
        .contextMenu {
            Button("Refresh") { Task { await session.refresh() } }
            if !connection.readOnly {
                Button("New Bucket…") { actions.prompt("New Bucket", "In \(connection.name)") { name in Task { await session.newBucket(name) } } }
            }
            Divider()
            if session.isOpen { Button("Disconnect") { model.disconnect(connection) } }
            Button("Edit Connection…") { actions.edit(connection, nil) }
            Button("Delete Connection…") { actions.delete(connection) }
        }
        .accessibilityIdentifier("connection-\(connection.name)")
        if model.expanded.contains(key) {
            switch session.state {
            case .connecting: note("Connecting…", depth: 1)
            case .failed(let message): note(message, depth: 1, error: true)
            case .open:
                if let error = session.lastError {
                    HStack {
                        note(error, depth: 1, error: true)
                        Button("OK") { session.lastError = nil }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(theme.accentText)
                    }
                }
                if session.buckets.isEmpty { note("No buckets", depth: 1) }
                ForEach(session.buckets, id: \.self) { bucket in
                    StorageFolder(
                        bucket: bucket.name, prefix: "", depth: 1, session: session, model: model, theme: theme, actions: actions,
                        treeKey: "\(key)/\(bucket.name)")
                }
            case .closed: EmptyView()
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

    private func note(_ text: String, depth: Int, error: Bool = false) -> some View {
        StorageNote(text: text, depth: depth, error: error, theme: theme)
    }
}

/// A bucket (prefix "") or a folder, and — open — what is in it.
private struct StorageFolder: View {
    let bucket: String
    let prefix: String
    let depth: Int
    @ObservedObject var session: StorageSession
    @ObservedObject var model: DatabaseModel
    @ObservedObject var theme: ChromeTheme
    let actions: DatabaseActions
    let treeKey: String
    @State private var targeted = false

    private var title: String { prefix.isEmpty ? bucket : String(prefix.dropLast().split(separator: "/").last ?? "") }

    var body: some View {
        TreeRow(
            depth: depth, open: model.expanded.contains(treeKey), symbol: prefix.isEmpty ? "archivebox" : "folder", title: title,
            detail: nil, dot: nil, theme: theme, targeted: targeted
        ) {
            if model.expanded.contains(treeKey) {
                model.expanded.remove(treeKey)
            } else {
                model.expanded.insert(treeKey)
                Task { await session.load(bucket, prefix) }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard !session.connection.readOnly else { return false }
            FileTreeDrag.urls(providers) { urls in
                model.expanded.insert(treeKey)
                Task { await session.upload(urls, to: bucket, prefix: prefix) }
            }
            return true
        }
        .contextMenu { menu }
        .help(session.client.path(bucket: bucket, key: prefix) + (session.connection.readOnly ? "" : " — drop files here to upload"))
        if model.expanded.contains(treeKey) {
            if let listing = session.listing(bucket, prefix) {
                if listing.folders.isEmpty, listing.objects.isEmpty { StorageNote(text: "Empty", depth: depth + 1, theme: theme) }
                ForEach(listing.folders, id: \.self) { folder in
                    StorageFolder(
                        bucket: bucket, prefix: folder, depth: depth + 1, session: session, model: model, theme: theme, actions: actions,
                        treeKey: treeKey + "/" + folder)
                }
                ForEach(listing.objects, id: \.key) { object in
                    StorageFile(bucket: bucket, object: object, depth: depth + 1, session: session, theme: theme, actions: actions, parent: prefix)
                }
                if listing.next != nil {
                    Button("Load more…") { Task { await session.load(bucket, prefix, more: true) } }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(theme.accentText)
                        .padding(.leading, 36 + CGFloat(depth) * 14).padding(.vertical, 3)
                }
            } else {
                StorageNote(text: "Reading…", depth: depth + 1, theme: theme)
            }
        }
    }

    @ViewBuilder private var menu: some View {
        if !session.connection.readOnly {
            Button("Upload Files…") { actions.upload(session, bucket, prefix) }
            Button("New Folder…") {
                actions.prompt("New Folder", "In \(session.client.path(bucket: bucket, key: prefix))") { name in
                    model.expanded.insert(treeKey)
                    Task { await session.newFolder(name, in: bucket, prefix: prefix) }
                }
            }
        }
        Button("Refresh") { Task { await session.refresh(bucket, prefix) } }
        Divider()
        Button("Copy Path") { copy(session.client.path(bucket: bucket, key: prefix)) }
        if !prefix.isEmpty, !session.connection.readOnly {
            Divider()
            Button("Delete Folder…") {
                Task {
                    let keys = await session.keys(for: prefix, in: bucket)
                    let parent = String(prefix.dropLast().split(separator: "/").dropLast().joined(separator: "/"))
                    actions.deleteObjects(session, bucket, keys.isEmpty ? [prefix] : keys + [prefix], parent.isEmpty ? "" : parent + "/")
                }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct StorageFile: View {
    let bucket: String
    let object: StorageObject
    let depth: Int
    @ObservedObject var session: StorageSession
    @ObservedObject var theme: ChromeTheme
    let actions: DatabaseActions
    let parent: String

    private var symbol: String {
        switch FilePreview.kind(of: object.name) {
        case .table: "tablecells"
        case .json, .text: "doc.text"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .other: "doc"
        }
    }

    var body: some View {
        TreeRow(depth: depth, open: nil, symbol: symbol, title: object.name, detail: FilePreview.size(object.size), dot: nil, theme: theme) {
            actions.openObject(session, bucket, object)
        }
        .contextMenu {
            Button("Open") { actions.openObject(session, bucket, object) }
            Button("Download…") { actions.download(session, bucket, object) }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.client.path(bucket: bucket, key: object.key), forType: .string)
            }
            Button("Copy Link") { actions.copyLink(session, bucket, object.key) }
            if !session.connection.readOnly {
                Divider()
                Button("Delete…") { actions.deleteObjects(session, bucket, [object.key], parent) }
            }
        }
        .accessibilityIdentifier("object-\(object.key)")
    }
}

private struct StorageNote: View {
    let text: String
    let depth: Int
    var error = false
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        Text(verbatim: text).font(.system(size: 11)).foregroundStyle(error ? DiffColors.removed : theme.text3)
            .lineLimit(4).textSelection(.enabled)
            .padding(.leading, 28 + CGFloat(depth) * 14).padding(.trailing, 8).padding(.vertical, 3)
    }
}

/// Uploads under way, at the panel's foot.
private struct TransfersFooter: View {
    @ObservedObject var model: DatabaseModel
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        let sessions = model.storageSessions.values.filter { !$0.transfers.isEmpty }
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Rectangle().fill(theme.border).frame(height: 1)
                ForEach(Array(sessions), id: \.connection.id) { session in
                    SessionTransfers(session: session, theme: theme)
                }
            }
            .padding(.bottom, 6)
        }
    }
}

private struct SessionTransfers: View {
    @ObservedObject var session: StorageSession
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        ForEach(session.transfers) { transfer in
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: transfer.error != nil ? "exclamationmark.triangle.fill" : (transfer.done ? "checkmark.circle.fill" : "arrow.up.circle"))
                        .font(.system(size: 10))
                        .foregroundStyle(transfer.error != nil ? DiffColors.removed : (transfer.done ? TabStatusStyle.done : theme.text3))
                    Text(verbatim: transfer.name).font(.system(size: 11)).foregroundStyle(theme.text2).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if transfer.error != nil {
                        Button("OK") { session.dismissTransfers() }.buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(theme.accentText)
                    }
                }
                if let error = transfer.error {
                    Text(verbatim: error).font(.system(size: 10.5)).foregroundStyle(DiffColors.removed).lineLimit(2)
                } else if !transfer.done {
                    ProgressView(value: transfer.progress).controlSize(.mini)
                }
            }
            .padding(.horizontal, 12)
        }
    }
}
