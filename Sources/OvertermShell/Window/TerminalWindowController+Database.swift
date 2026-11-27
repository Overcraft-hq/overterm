import AppKit
import SwiftUI

/// The database client: the sidebar's panel over the saved connections, a
/// connection's console in the editor, and the sheet that makes one.
extension TerminalWindowController {
    package var databaseActions: DatabaseActions {
        DatabaseActions(
            edit: { [weak self] connection, kind in self?.editDatabaseConnection(connection, kind: kind) },
            delete: { [weak self] in self?.deleteDatabaseConnection($0) },
            console: { [weak self] in self?.openDatabaseConsole($0) },
            run: { [weak self] connection, sql in self?.runInDatabaseConsole(connection, sql) },
            openObject: { [weak self] session, bucket, object in self?.openStorageObject(session, bucket, object) },
            prompt: { [weak self] title, detail, done in
                self?.askForName(title: title, detail: detail, initial: "", action: "Create") { name in
                    guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return "A name, please." }
                    done(name)
                    return nil
                }
            },
            deleteObjects: { [weak self] session, bucket, keys, prefix in self?.deleteStorageObjects(session, bucket, keys, refreshing: prefix) },
            upload: { [weak self] session, bucket, prefix in self?.uploadToStorage(session, bucket, prefix) },
            download: { [weak self] session, bucket, object in self?.downloadStorageObject(session, bucket, object) },
            copyLink: { [weak self] session, bucket, key in self?.copyStorageLink(session, bucket, key) },
            openRedisKey: { [weak self] session, db, key in self?.openRedisKey(session, db, key) },
            newRedisKey: { [weak self] session, db in
                self?.redisSlot.newKey(in: session, db: db)
                self?.showRedisSlot()
            },
            redisServer: { [weak self] session in self?.openRedisServer(session) },
            server: { [weak self] in self?.openDatabasePage(.server, for: $0) },
            users: { [weak self] in self?.openDatabasePage(.users, for: $0) },
            deleteRedisKey: { [weak self] session, db, key in self?.deleteRedisKey(session, db, key) },
            rename: { [weak self] title, current, done in
                self?.askForName(title: title, detail: "", initial: current, action: "Rename") { name in
                    guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return "A name, please." }
                    done(name)
                    return nil
                }
            }
        )
    }

    package func wireDatabase() {
        EditorViewController.onNewDatabaseConnection = { [weak self] in self?.editDatabaseConnection(nil, kind: nil) }
        EditorViewController.onOpenTrace = { [weak self] id in self?.openTrace(id) }
    }

    /// View ▸ Database (⌥⌘B): the sidebar, on the database panel.
    @objc package func showDatabase(_ sender: Any?) {
        guard Settings.shared.databaseEnabled else { return }
        if sidebarItem?.isCollapsed == true { toggleFileTree(nil) }
        sidebarPanel.panel = .database
    }

    package func databaseSettingsChanged() {
        // Agents' database tools come and go with the setting.
        BrowserBridge.shared.update()
        if !Settings.shared.databaseEnabled, sidebarPanel.panel == .database { sidebarPanel.panel = .files }
        // The rail lists its icons from the setting: drawn again.
        sidebarPanel.objectWillChange.send()
    }

    /// New Connection… (with a kind picked) and Edit Connection…, in a sheet.
    package func editDatabaseConnection(_ connection: DatabaseConnection?, kind: DatabaseKind?) {
        let model = DatabaseModel.shared
        let start = connection ?? DatabaseConnection(name: kind?.title ?? "PostgreSQL", kind: kind ?? .postgres)
        presentSheet { close in
            DatabaseConnectionForm(connection: start, isNew: connection == nil, store: model.store) { saved in
                close()
                guard let saved else { return }
                // Edited: the open session was the old connection's.
                if connection != nil { model.disconnect(saved) }
                model.expanded.insert(saved.id.uuidString)
                if saved.kind.isStorage {
                    Task { await model.storage(saved).open() }
                } else {
                    Task { await model.session(saved).open() }
                }
            }
        }
    }

    package func deleteDatabaseConnection(_ connection: DatabaseConnection) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(connection.name)”?"
        alert.informativeText = "Its saved password or key goes from the keychain too. Its console file stays."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                do {
                    try DatabaseModel.shared.delete(connection)
                } catch {
                    NSAlert(error: error).beginSheetModal(for: window)
                }
            }
        }
    }

    /// The connection's console, in the editor.
    package func openDatabaseConsole(_ connection: DatabaseConnection, then done: ((EditorViewController) -> Void)? = nil) {
        let url = DatabaseModel.shared.console(for: connection)
        openInEditor(url)
        guard let editor else { return }
        editor.open(url) { opened in
            guard opened else { return }
            // Its console runs on this connection, whatever it ran on before.
            if editor.active?.sqlConsole?.connection?.id != connection.id { editor.active?.sqlConsole?.use(connection) }
            done?(editor)
        }
    }

    /// A query from the panel (Select Top 100): written at the end of the
    /// console and run there, so it stays with what else was run.
    package func runInDatabaseConsole(_ connection: DatabaseConnection, _ sql: String) {
        openDatabaseConsole(connection) { editor in
            guard let buffer = editor.active, let console = buffer.sqlConsole else { return }
            let text = buffer.storage.string
            let separator = text.isEmpty || text.hasSuffix("\n\n") ? "" : (text.hasSuffix("\n") ? "\n" : "\n\n")
            editor.replaceText(of: buffer, with: text + separator + sql + "\n")
            // The caret at the query's start — ⌘↩ runs it again — and the
            // console saved, as DataGrip keeps its consoles.
            let start = (text as NSString).length + (separator as NSString).length
            editor.textView.setSelectedRange(NSRange(location: start, length: 0))
            editor.textView.scrollRangeToVisible(NSRange(location: start, length: 0))
            editor.save(buffer, overwriting: false)
            // A Redis one may be two lines (SELECT, then VIEW): each its own command.
            let commands = connection.kind.statements(in: sql).map { (sql as NSString).substring(with: $0) }
            console.run(commands.isEmpty ? [sql] : commands)
        }
    }
}

// MARK: Storage

extension TerminalWindowController {
    package var storageObjectActions: StorageObjectActions {
        StorageObjectActions(
            download: { [weak self] in
                guard let self, let session = self.storageObject.session, let object = self.storageObject.object else { return }
                self.downloadStorageObject(session, self.storageObject.bucket, object)
            },
            openInEditor: { [weak self] in self?.openStorageObjectInEditor() },
            delete: { [weak self] in
                guard let self, let session = self.storageObject.session, let object = self.storageObject.object else { return }
                let parent = object.key.contains("/") ? String(object.key[...object.key.lastIndex(of: "/")!]) : ""
                self.deleteStorageObjects(session, self.storageObject.bucket, [object.key], refreshing: parent) { [weak self] in
                    self?.storageObject.close()
                }
            },
            copyLink: { [weak self] in
                guard let self, let session = self.storageObject.session, let object = self.storageObject.object else { return }
                self.copyStorageLink(session, self.storageObject.bucket, object.key)
            },
            close: { [weak self] in self?.toggleDiff(nil) }
        )
    }

    /// A stored file in the right-hand pane, which it joins as every pane there does.
    package func openStorageObject(_ session: StorageSession, _ bucket: String, _ object: StorageObject) {
        storageObject.show(object, in: bucket, session: session)
        if zoomedColumn != nil { setZoomed(nil) }
        rightPane.objectOpened = true
        rightPane.mode = .object
        if diffItem?.isCollapsed == true { toggleDiff(nil) }
        updateRightPaneVisibility()
    }

    /// Asks — how many files, the first few by name — then deletes them.
    package func deleteStorageObjects(
        _ session: StorageSession, _ bucket: String, _ keys: [String], refreshing prefix: String, then done: (() -> Void)? = nil
    ) {
        guard let window, !keys.isEmpty else { return }
        let files = keys.filter { !$0.hasSuffix("/") }
        let alert = NSAlert()
        alert.messageText = files.count <= 1 ? "Delete “\(keys.first.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? "")”?" : "Delete \(files.count) files?"
        alert.informativeText =
            (files.count > 1 ? files.prefix(5).joined(separator: "\n") + (files.count > 5 ? "\n…" : "") + "\n\n" : "")
            + "From \(session.client.path(bucket: bucket, key: "")). This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                Task {
                    await session.delete(keys, in: bucket, refreshing: prefix)
                    done?()
                }
            }
        }
    }

    package func uploadToStorage(_ session: StorageSession, _ bucket: String, _ prefix: String) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "To \(session.client.path(bucket: bucket, key: prefix))"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated {
                DatabaseModel.shared.expanded.insert("\(session.connection.id.uuidString)/\(bucket)")
                Task { await session.upload(urls, to: bucket, prefix: prefix) }
            }
        }
    }

    /// The whole file to where it is saved — through a file, never in memory.
    package func downloadStorageObject(_ session: StorageSession, _ bucket: String, _ object: StorageObject) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = object.name
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                Task {
                    do {
                        try await session.client.download(bucket: bucket, key: object.key, to: url)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } catch {
                        self?.reportDatabaseError(error)
                    }
                }
            }
        }
    }

    /// A copy in Overterm's cache, in the editor — read as text, not sent back.
    package func openStorageObjectInEditor() {
        guard let session = storageObject.session, let object = storageObject.object else { return }
        let bucket = storageObject.bucket
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(AppEnvironment.bundleIdentifier)/Storage/\(session.connection.id.uuidString.prefix(8))/\(bucket)", isDirectory: true)
        let file = folder.appendingPathComponent(object.key)
        Task {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await session.client.download(bucket: bucket, key: object.key, to: file)
                openInEditor(file)
            } catch {
                reportDatabaseError(error)
            }
        }
    }

    /// S3: a presigned link for an hour; GCS: the console's page.
    package func copyStorageLink(_ session: StorageSession, _ bucket: String, _ key: String) {
        Task {
            do {
                guard let link = try await session.client.link(bucket: bucket, key: key, expires: 3600) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.absoluteString, forType: .string)
            } catch {
                reportDatabaseError(error)
            }
        }
    }

    package func reportDatabaseError(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }
}

// MARK: Traces

extension TerminalWindowController {
    /// A trace's id (a log line's): in a Tempo connection's console, as a
    /// tab of its own — the first saved one; with none, one is asked for.
    package func openTrace(_ id: String) {
        guard let tempo = DatabaseModel.shared.store.connections.first(where: { $0.kind == .tempo }) else {
            reportDatabaseError(DatabaseError.failed("Trace \(id) — add a Tempo connection (Database ▸ + ▸ Tempo) to open it here."))
            return
        }
        runInDatabaseConsole(tempo, id)
    }
}

// MARK: Redis

extension TerminalWindowController {
    package var redisSlotActions: RedisSlotActions {
        RedisSlotActions(
            confirm: { [weak self] title, detail, button, then in self?.confirmRedis(title, detail, button, then: then) },
            openKey: { [weak self] session, db, key in self?.openRedisKey(session, db, key) },
            close: { [weak self] in
                self?.redisSlot.show(.none)
                self?.toggleDiff(nil)
            }
        )
    }

    /// The Redis page in the right-hand pane, which it joins as every pane there does.
    package func showRedisSlot() {
        // A zoomed column hides the pane: what was asked for must show.
        if zoomedColumn != nil { setZoomed(nil) }
        rightPane.redisOpened = true
        rightPane.mode = .redis
        if diffItem?.isCollapsed == true { toggleDiff(nil) }
        updateRightPaneVisibility()
    }

    package func openRedisKey(_ session: DatabaseSession, _ db: Int, _ key: String) {
        redisSlot.key.show(key, db: db, session: session)
        redisSlot.show(.key)
        showRedisSlot()
    }

    package func openRedisServer(_ session: DatabaseSession) {
        Task {
            if !session.isOpen { await session.open() }
            redisSlot.server.show(session)
            redisSlot.show(.server)
            showRedisSlot()
        }
    }

    package func deleteRedisKey(_ session: DatabaseSession, _ db: Int, _ key: String) {
        confirmRedis(
            "Delete “\(key)”?", "This can't be undone.", "Delete", scope: "Redis · \(session.connection.name) · db\(db)"
        ) { [weak self] in
            Task {
                guard let driver = session.redis else { return }
                do {
                    let reply = try await driver.command(["UNLINK", key], db: db)
                    if case .error(let message) = reply { throw DatabaseError.failed(message) }
                    session.browser(db).removed(key)
                    if self?.redisSlot.page == .key, self?.redisSlot.key.name == key { self?.redisSlot.show(.none) }
                } catch {
                    self?.reportDatabaseError(error)
                }
            }
        }
    }

    /// Every one of Redis' asks deletes or cuts something off — a key, keys,
    /// the slow log, a client: the shared sheet, Return on Cancel (D-1).
    /// `scope`, the connection it reaches, where the caller knows it.
    package func confirmRedis(_ title: String, _ detail: String, _ button: String, scope: String? = nil, then: @escaping () -> Void) {
        guard let window else { return }
        WriteConfirmation(title: title, scope: scope, detail: detail, button: button, destroys: true).present(on: window) { _ in then() }
    }
}

// MARK: Server and Users pages

extension TerminalWindowController {
    package var databaseSlotActions: DatabaseSlotActions {
        DatabaseSlotActions(
            confirm: { [weak self] confirmation, then in
                guard let window = self?.window else { return }
                confirmation.present(on: window) { typed in then(typed) }
            },
            close: { [weak self] in
                self?.databaseSlot.show(.none)
                self?.toggleDiff(nil)
            })
    }

    /// A connection's Server or Users page in the right slot, which it joins
    /// as every pane there does — read only while it shows.
    package func openDatabasePage(_ page: DatabaseSlotModel.Page, for connection: DatabaseConnection) {
        let session = DatabaseModel.shared.session(connection)
        switch page {
        case .server: databaseSlot.server.show(session)
        case .users: databaseSlot.users.show(session)
        case .none: break
        }
        databaseSlot.show(page)
        if zoomedColumn != nil { setZoomed(nil) }
        rightPane.databaseOpened = true
        rightPane.mode = .database
        if diffItem?.isCollapsed == true { toggleDiff(nil) }
        updateRightPaneVisibility()
    }

    /// ⌘K: each connection's Server and Users pages, as far as its kind has them.
    package func databasePaletteItems() -> [PaletteItem] {
        guard Settings.shared.databaseEnabled else { return [] }
        var items: [PaletteItem] = []
        for connection in DatabaseModel.shared.store.connections {
            let features = connection.kind.features
            if features.contains(.monitoring), !connection.kind.isRedis {
                items.append(
                    PaletteItem(
                        id: "db.server.\(connection.id)", group: .action, title: "Server: \(connection.name)",
                        subtitle: "\(connection.kind.title) — sessions, slow queries, locks, sizes", symbol: "server.rack"
                    ) { [weak self] _, _ in self?.openDatabasePage(.server, for: connection) })
            }
            if features.contains(.users) {
                items.append(
                    PaletteItem(
                        id: "db.users.\(connection.id)", group: .action, title: "Users & Roles: \(connection.name)",
                        subtitle: "\(connection.kind.title) — users, roles, grants", symbol: "person.2"
                    ) { [weak self] _, _ in self?.openDatabasePage(.users, for: connection) })
            }
        }
        return items
    }
}

// MARK: MCP

extension TerminalWindowController {
    /// An MCP server in the right-hand pane, connected — as every pane there joins it.
    package func inspectMCP(_ server: MCPServerConfig) {
        apiWorkspace.mcp.open(server)
        if zoomedColumn != nil { setZoomed(nil) }
        rightPane.mcpOpened = true
        rightPane.mode = .mcp
        if diffItem?.isCollapsed == true { toggleDiff(nil) }
        updateRightPaneVisibility()
    }
}
