import AppKit
import SwiftUI

/// What the API panel's rows ask the window to do.
struct APIActions {
    var open: (URL) -> Void
    /// Asks for a name (title, initial text); nil when cancelled.
    var prompt: (_ title: String, _ initial: String, _ done: @escaping (String) -> Void) -> Void
    /// Something failed: the window says so.
    var report: (Error) -> Void
    /// Runs requests and folders, in order, into the right-hand pane.
    var run: (_ items: [APIItem], _ title: String) -> Void
    /// Says something that went well, with what to know (an import's notes).
    var inform: (_ title: String, _ detail: String) -> Void
    /// The environment's secrets, in a sheet.
    var editSecrets: (_ environment: String, _ collection: BrunoCollection) -> Void
    /// Renames a request or folder with the editor's tabs following it.
    var rename: (_ item: APIItem, _ name: String) throws -> URL
    /// Asks, then moves it to the Trash, its tabs closing — as Files does.
    var trash: (_ item: APIItem) -> Void
}

/// The sidebar's API panel: the checkout's Bruno collection — its
/// requests by folder, its environments — or, without one, a way to start.
struct APIPanelView: View {
    @ObservedObject var workspace: APIWorkspace
    let group: TabGroup?
    @ObservedObject var theme: ChromeTheme
    let actions: APIActions
    /// Open folders, by path; the collection's first level starts open.
    @State private var expanded: Set<String> = []
    @State private var seeded: Set<String> = []
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: workspace.collection?.name ?? "API", group: group, theme: theme, help: workspace.collection?.root.path) {
                if workspace.collection != nil {
                    Menu {
                        Button("New Request…") { newRequest(in: workspace.collection?.root) }
                        Button("New Folder…") { newFolder(in: workspace.collection?.root) }
                        Divider()
                        importItems
                    } label: {
                        Image(systemName: "plus").font(.system(size: 11)).frame(width: 22, height: 22)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("New request or folder")
                    .accessibilityIdentifier("apiNew")
                }
                if let collection = workspace.collection {
                    PanelHeaderButton(
                        symbol: "play", help: "Run the collection", action: { actions.run([collection.tree], collection.name) }, theme: theme)
                }
                PanelHeaderButton(symbol: "arrow.clockwise", help: "Reload", action: { workspace.reload() }, theme: theme)
            }
            if let collection = workspace.collection {
                pickers(collection)
                searchField
                tree(collection)
            } else if workspace.isLoading {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            } else {
                empty
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    // MARK: Collection and environment

    /// The collection (when there is more than one) and the environment,
    /// each on its own line: side by side, a long name of either squeezed
    /// the other to its icon in a sidebar of ordinary width.
    private func pickers(_ collection: BrunoCollection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Always there, one collection or ten: it is also where a new one
            // is made — only the empty panel offered that before, and only
            // in the checkout.
            Menu {
                let shared = workspace.checkoutCollections
                let mine = workspace.collections.filter(\.isPersonal)
                if !shared.isEmpty {
                    Section("In this checkout") { collectionButtons(shared, current: collection) }
                }
                if !mine.isEmpty {
                    Section("Mine — on this Mac") { collectionButtons(mine, current: collection) }
                }
                Divider()
                if workspace.root != nil { Button("New Collection in This Checkout…") { newCollection() } }
                Button("New Personal Collection…") { newPersonalCollection() }
            } label: {
                Label(collection.name, systemImage: collection.isPersonal ? "person.crop.circle" : "shippingbox")
                    .font(.system(size: 11.5)).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            // Never fixed to its title: a long one made the row, and so
            // the whole panel, wider than the sidebar — the rail was
            // pushed out of the window.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .frame(height: 24)
            .accessibilityIdentifier("apiCollection")
            Menu {
                Button("No Environment") { workspace.environmentName = nil }
                if !collection.environments.isEmpty { Divider() }
                ForEach(collection.environments) { environment in
                    Button {
                        workspace.environmentName = environment.name
                    } label: {
                        if workspace.environmentName == environment.name { Label(environment.name, systemImage: "checkmark") } else { Text(environment.name) }
                    }
                }
                Divider()
                if let name = workspace.environmentName, let ref = collection.environments.first(where: { $0.name == name }) {
                    Button("Edit “\(name)”") { actions.open(ref.url) }
                    Button("Secrets of “\(name)”…") { actions.editSecrets(name, collection) }
                }
                Button("New Environment…") { newEnvironment(collection) }
            } label: {
                Label(workspace.environmentName ?? "No Environment", systemImage: "globe")
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .foregroundStyle(workspace.environmentName == nil ? theme.text3 : theme.text)
            }
            .menuStyle(.borderlessButton)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .frame(height: 24)
            .accessibilityIdentifier("apiEnvironment")
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 2)
    }

    @ViewBuilder private func collectionButtons(_ list: [BrunoCollection], current: BrunoCollection) -> some View {
        ForEach(list, id: \.root) { other in
            Button {
                workspace.selectedRoot = other.root
            } label: {
                if other.root == current.root { Label(other.name, systemImage: "checkmark") } else { Text(other.name) }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(theme.text3)
            TextField("Filter requests", text: $workspace.search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.rowHover.opacity(0.7)))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    // MARK: The tree

    private struct Row: Identifiable {
        let item: APIItem
        let depth: Int
        var id: String { item.id }
    }

    private func rows(_ root: APIItem) -> [Row] {
        let filtering = !workspace.search.isEmpty
        var rows: [Row] = []
        func walk(_ items: [APIItem], _ depth: Int) {
            for item in items {
                rows.append(Row(item: item, depth: depth))
                if let children = item.children, filtering || expanded.contains(item.id) { walk(children, depth + 1) }
            }
        }
        walk(root.children ?? [], 0)
        return rows
    }

    private func tree(_ collection: BrunoCollection) -> some View {
        let root = collection.tree.filtered(workspace.search) ?? APIItem(url: collection.root, name: collection.name, children: [])
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows(root)) { row in
                    APIRowView(
                        item: row.item, depth: row.depth, isExpanded: expanded.contains(row.item.id) || !workspace.search.isEmpty,
                        isSelected: selection == row.item.id, isSending: workspace.isSending(row.item.url),
                        result: workspace.result(for: row.item.url), theme: theme
                    ) {
                        selection = row.item.id
                        if row.item.isFolder {
                            if expanded.contains(row.item.id) { expanded.remove(row.item.id) } else { expanded.insert(row.item.id) }
                        } else {
                            actions.open(row.item.url)
                        }
                    }
                    .contextMenu { menu(row.item) }
                }
                if root.children?.isEmpty != false {
                    if collection.isPersonal && workspace.search.isEmpty {
                        personalIntro(collection)
                    } else {
                        Text(workspace.search.isEmpty ? "No requests yet — + makes one." : "Nothing matches.")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.text3)
                            .padding(12)
                    }
                }
                // No collection in the checkout: how to start one, under yours.
                if workspace.checkoutCollections.isEmpty, !workspace.isLoading, workspace.search.isEmpty {
                    Divider().padding(.vertical, 8)
                    checkoutStart
                }
            }
            .padding(.vertical, 4)
        }
        .onAppear { seed(collection) }
        .onChange(of: collection.root) { _ in seed(collection) }
    }

    /// The first time a collection shows, its top folders are open.
    private func seed(_ collection: BrunoCollection) {
        guard !seeded.contains(collection.root.path) else { return }
        seeded.insert(collection.root.path)
        for child in collection.tree.children ?? [] where child.isFolder { expanded.insert(child.id) }
    }

    @ViewBuilder private func menu(_ item: APIItem) -> some View {
        let folder = item.isFolder ? item.url : item.url.deletingLastPathComponent()
        Button("New Request…") { newRequest(in: folder) }
        Button("New Folder…") { newFolder(in: folder) }
        Divider()
        if item.isFolder {
            Button("Run Folder") { actions.run([item], item.name) }
            Button("Folder Settings") { openFolderSettings(item) }
        } else {
            Button("Open") { actions.open(item.url) }
            Button("Copy as cURL") { copyCurl(item) }
            Button("Duplicate") { run { _ = try workspace.duplicate(item) } }
        }
        Divider()
        Button("Rename…") {
            actions.prompt("Rename “\(item.name)”", item.name) { name in run { _ = try actions.rename(item, name) } }
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Button("Move to Trash…") { actions.trash(item) }
    }

    // MARK: Empty

    /// My Requests, empty: what it is, and the way in.
    private func personalIntro(_ collection: BrunoCollection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your own requests, kept in Overterm — not in the checkout, nothing to commit. Type a URL and send it.")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                newRequest(in: collection.root)
            } label: {
                Label("New Request", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.accentText.opacity(0.2)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.text)
            .accessibilityIdentifier("apiNewPersonalRequest")
        }
        .padding(12)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 0) {
            checkoutStart
            Spacer()
        }
    }

    /// The checkout has no collection: one made, or imported, to share.
    private var checkoutStart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("THIS CHECKOUT")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.text3)
            Text("Has no Bruno collection. One is a folder with bruno.json: its requests are .bru files you commit with the code, and Bruno and bru run open them too.")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            if !workspace.discovered.isEmpty {
                Text("Found here, to import:")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.text2)
                    .padding(.top, 2)
                ForEach(workspace.discovered) { source in
                    startButton(source.title, symbol: Self.symbol(source)) { importSource(source) }
                        .accessibilityIdentifier("apiImport-\(source.id)")
                }
            }
            startButton("New Collection…", symbol: "plus.rectangle.on.folder") { newCollection() }
                .accessibilityIdentifier("apiNewCollection")
            startButton("Import a File…", symbol: "square.and.arrow.down") { importFile() }
            startButton("New Request from cURL in the Clipboard", symbol: "doc.on.clipboard") { importCurl() }
                .disabled(!Self.clipboardHasCurl)
        }
        .padding(12)
    }

    private func startButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.accentText)
    }

    private static func symbol(_ source: APIDiscovery.Source) -> String {
        switch source {
        case .server: "antenna.radiowaves.left.and.right"
        case .file(_, let kind): kind == .http ? "doc.plaintext" : "doc.text"
        }
    }

    @ViewBuilder private var importItems: some View {
        Button("Import a File…") { importFile() }
        Button("New Request from cURL in the Clipboard") { importCurl() }
            .disabled(!Self.clipboardHasCurl)
        if !workspace.discovered.isEmpty {
            Divider()
            ForEach(workspace.discovered) { source in
                Button("Import \(source.title)") { importSource(source) }
            }
        }
    }

    private static var clipboardHasCurl: Bool {
        NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("curl ") == true
    }

    // MARK: Importing

    private func finish(_ imported: APIWorkspace.Imported) {
        if let first = imported.firstRequest { actions.open(first) }
        if !imported.notes.isEmpty {
            actions.inform("Imported — with notes", imported.notes.map { "• " + $0 }.joined(separator: "\n"))
        }
    }

    private func importSource(_ source: APIDiscovery.Source) {
        Task {
            do {
                finish(try await workspace.importSource(source))
            } catch {
                actions.report(error)
            }
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.message = "An OpenAPI document (JSON or YAML), a Postman collection, or a .http file"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = workspace.root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { finish(try workspace.write(try APIImport.read(url))) }
    }

    private func importCurl() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        run { actions.open(try workspace.importCurl(text)) }
    }

    // MARK: Doing

    private func run(_ work: () throws -> Void) {
        do { try work() } catch { actions.report(error) }
    }

    /// A new request opens at once, unnamed and ready to send — it is named,
    /// and lands in `folder`, when it is saved (⌘S), as a Postman tab does.
    /// Asking a name first, and writing an empty request, came before using it.
    private func newRequest(in folder: URL?) {
        guard let folder else { return }
        run {
            // Yours start blank, for a URL typed whole; a collection's
            // start from its environment's base.
            let personal = workspace.collection(containing: folder.appendingPathComponent("x"))?.isPersonal == true
            actions.open(try workspace.newDraft(in: folder, url: personal ? "" : "{{baseUrl}}/"))
        }
    }

    private func newFolder(in parent: URL?) {
        guard let parent else { return }
        actions.prompt("New Folder", "New Folder") { name in
            run {
                let folder = try workspace.newFolder(named: name, in: parent)
                expanded.insert(folder.path)
            }
        }
    }

    /// In the checkout: committed with the code, shared.
    private func newCollection() {
        guard let root = workspace.root else { return }
        actions.prompt("New Collection — in this checkout, shared", root.lastPathComponent + " API") { name in
            run { _ = try workspace.newCheckoutCollection(named: name) }
        }
    }

    /// Yours: in Overterm's folder, nothing of it in the checkout.
    private func newPersonalCollection() {
        actions.prompt("New Personal Collection — on this Mac only", "My API") { name in
            run { _ = try workspace.newPersonalCollection(named: name) }
        }
    }

    private func newEnvironment(_ collection: BrunoCollection) {
        actions.prompt("New Environment", "Local") { name in
            run {
                let folder = collection.root.appendingPathComponent("environments", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent(APIWorkspace.fileName(name) + ".bru")
                guard !FileManager.default.fileExists(atPath: file.path) else { throw APIWorkspace.FileError.exists(file.lastPathComponent) }
                var environment = BruFile()
                environment.variables = [BruPair(key: "baseUrl", value: "http://localhost:3000")]
                try environment.text.write(to: file, atomically: true, encoding: .utf8)
                workspace.reload()
                workspace.environmentName = APIWorkspace.fileName(name)
                actions.open(file)
            }
        }
    }

    /// folder.bru — its headers, auth, vars and scripts — made if missing.
    private func openFolderSettings(_ item: APIItem) {
        let file = item.url.appendingPathComponent("folder.bru")
        if !FileManager.default.fileExists(atPath: file.path) {
            var meta = BruFile()
            meta.setPairs("meta", [BruPair(key: "name", value: item.name)])
            run { try meta.text.write(to: file, atomically: true, encoding: .utf8) }
        }
        actions.open(file)
    }

    private func copyCurl(_ item: APIItem) {
        guard let text = try? String(contentsOf: item.url, encoding: .utf8) else { return }
        let file = BruFile(parsing: text)
        let setup = workspace.setup(for: item.url, file: file)
        var context = APIRequestPlan.Context()
        context.collectionRoot = setup.collectionRoot
        context.collectionFile = setup.collectionFile
        context.folderFiles = setup.folderFiles
        context.variables.environment = setup.environment
        context.variables.runtime = setup.runtime
        context.variables.processEnv = setup.processEnv
        run {
            let plan = try APIRequestPlan.make(file, context: context)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(plan.curl, forType: .string)
        }
    }
}

/// One row: a folder with its chevron, or a request with its method —
/// and how it went the last time it was sent.
private struct APIRowView: View {
    let item: APIItem
    let depth: Int
    let isExpanded: Bool
    let isSelected: Bool
    let isSending: Bool
    let result: APIExecution.Result?
    @ObservedObject var theme: ChromeTheme
    let tap: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            if item.isFolder {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 10)
                Image(systemName: "folder").font(.system(size: 11)).frame(width: 14)
            } else {
                Text(verbatim: APIMethodStyle.short(item.method ?? "GET"))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(APIMethodStyle.color(item.method ?? "GET"))
                    .frame(width: 34, alignment: .trailing)
            }
            Text(verbatim: item.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if isSending {
                ProgressView().controlSize(.mini)
            } else if let result, !item.isFolder {
                Circle()
                    .fill(result.succeeded ? APIResponseView.statusColor(200) : APIResponseView.statusColor(500))
                    .frame(width: 6, height: 6)
                    .help(result.response.map { "\($0.status) — \(result.passed)/\(result.tests.count) tests passed" } ?? (result.error ?? ""))
            }
        }
        .foregroundStyle(isSelected ? theme.text : theme.text2)
        .padding(.leading, 8 + CGFloat(depth) * 14)
        .padding(.trailing, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? theme.rowSel : (hovering ? theme.rowHover : .clear))
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: tap)
        .help(item.url.path)
        .accessibilityIdentifier("apiRow-\(item.name)")
    }
}
