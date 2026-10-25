import AppKit
import SwiftUI

/// What the Notes panel asks the window to do.
struct NotesActions {
    var open: (URL) -> Void
    /// A new note in a folder (nil: where Obsidian's settings say), opened.
    var newNote: (URL?) -> Void
    var newFolder: (URL?) -> Void
    /// Today's note, made from the daily template if it isn't there yet.
    var dailyNote: () -> Void
    /// Asks for a new name; a note's links follow it.
    var rename: (URL) -> Void
    /// Asks, then moves it to the Trash.
    var trash: (URL) -> Void
    /// Types its path into the selected terminal.
    var insertPath: (URL) -> Void
    /// A new terminal tab whose shell starts in this folder.
    var newTab: (URL) -> Void = { _ in }
    /// Another folder as the vault, picked in an open panel.
    var chooseVault: () -> Void
    /// Opens a note at a line (0-based).
    var openAt: (URL, Int) -> Void = { _, _ in }
    /// Ticks the task on a line of a note (with these words), where it is written.
    var toggleTask: (URL, Int, String) -> Void = { _, _, _ in }
}

/// The sidebar's Notes panel: the vault's folders and notes, Obsidian's
/// order, a filter, and the vault switcher in the header.
struct NotesPanelView: View {
    @ObservedObject var model: NotesModel
    @ObservedObject var theme: ChromeTheme
    let actions: NotesActions

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                searchField
                if let tag = model.tagFilter { tagChip(tag) }
                if let tree = model.tree {
                    if tree.children?.isEmpty ?? true {
                        empty
                    } else {
                        list(tree)
                    }
                } else {
                    Spacer()
                    if model.isLoading { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if model.tree != nil {
                    NotesDetailView(model: model, theme: theme, actions: actions)
                        .frame(height: model.detail == nil ? 31 : max(160, geometry.size.height * 0.4))
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private func tagChip(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: "#" + tag).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.accentText).lineLimit(1)
            Button {
                model.tagFilter = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.text3)
            .help("Show every note")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(model.knownVaults, id: \.self) { root in
                    Toggle(
                        isOn: Binding(
                            get: { root.standardizedFileURL == model.vault.root },
                            set: { _ in model.switchVault(to: root) })
                    ) {
                        Text(verbatim: root.lastPathComponent)
                    }
                    .help(root.path)
                }
                Divider()
                Button("Open Folder as Vault…", action: actions.chooseVault)
                Button("Reveal Vault in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.vault.root]) }
            } label: {
                HStack(spacing: 3) {
                    Text(verbatim: model.vault.name)
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(theme.text2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            // The vault's name before the buttons: they fold into ⋯ first.
            .layoutPriority(1)
            .help(model.vault.root.path)
            .accessibilityIdentifier("notesVault")
            Spacer(minLength: 4)
            if model.isLoading && model.tree != nil { ProgressView().controlSize(.mini) }
            PanelHeaderButton(symbol: "square.and.pencil", help: "New Note", action: { actions.newNote(nil) }, theme: theme)
            PanelHeaderButton(symbol: "calendar", help: "Today’s Note", action: actions.dailyNote, theme: theme)
            Menu {
                Button("New Folder") { actions.newFolder(nil) }
                Button("Collapse All", action: model.collapseAll)
                Divider()
                Button("Reload") { model.reload() }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 11)).frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(theme.text2)
            .help("More")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 34)
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(theme.text3)
            TextField("Filter notes", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.text3)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.rowHover.opacity(0.7)))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    // MARK: The tree

    struct Row: Identifiable {
        let item: NoteItem
        let depth: Int
        let isExpanded: Bool
        var id: String { item.id }
    }

    /// The tree as rows: open folders' children under them; every folder
    /// open while filtering, so a match is never hidden.
    static func rows(_ root: NoteItem, query: String, expanded: Set<String>, tagged: Set<String>? = nil) -> [Row] {
        // A tag picked: its notes, flat, by name.
        if let tagged {
            return root.allNotes.filter { tagged.contains($0.url.standardizedFileURL.path) }
                .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { Row(item: $0, depth: 0, isExpanded: false) }
        }
        let filtering = !query.isEmpty
        let root = root.shown
        let shown = filtering ? (root.filtered(query) ?? NoteItem(url: root.url, kind: .folder, children: [])) : root
        var rows: [Row] = []
        func walk(_ items: [NoteItem], _ depth: Int) {
            for item in items {
                let open = item.isFolder && (filtering || expanded.contains(item.url.standardizedFileURL.path))
                rows.append(Row(item: item, depth: depth, isExpanded: open))
                if open, let children = item.children { walk(children, depth + 1) }
            }
        }
        walk(shown.children ?? [], 0)
        return rows
    }

    private func list(_ tree: NoteItem) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Self.rows(tree, query: model.query, expanded: model.expanded, tagged: tagged)) { row in
                    NoteRowView(row: row, model: model, theme: theme, actions: actions)
                }
            }
            .padding(.vertical, 4)
        }
        .contextMenu { folderMenu(model.vault.root) }
    }

    /// The notes the picked tag is on, as paths.
    private var tagged: Set<String>? {
        guard let tag = model.tagFilter else { return nil }
        return Set(model.index.notes(tagged: tag).map { model.url(of: $0).standardizedFileURL.path })
    }

    @ViewBuilder func folderMenu(_ folder: URL) -> some View {
        Button("New Note") { actions.newNote(folder) }
        Button("New Folder") { actions.newFolder(folder) }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.query.isEmpty ? "No notes yet" : "Nothing matches")
                .font(.system(size: 12))
                .foregroundStyle(theme.text2)
            if model.query.isEmpty {
                Text("A note is a Markdown file in this folder. An Obsidian vault opens as it is — Obsidian, your phone and Overterm share it.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                Button("New Note") { actions.newNote(nil) }
                    .controlSize(.small)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

private struct NoteRowView: View {
    let row: NotesPanelView.Row
    @ObservedObject var model: NotesModel
    @ObservedObject var theme: ChromeTheme
    let actions: NotesActions
    @State private var hovering = false

    private var item: NoteItem { row.item }
    private var isCurrent: Bool { model.current?.standardizedFileURL == item.url.standardizedFileURL }

    private var symbol: String {
        if item.isEvicted { return "icloud.and.arrow.down" }
        switch item.kind {
        case .folder: return "folder"
        case .note: return "doc.text"
        case .canvas: return "rectangle.3.group"
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .other: return "doc"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .frame(width: 10)
                .opacity(item.isFolder ? 1 : 0)
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 14)
            Text(verbatim: item.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isCurrent ? theme.text : theme.text2)
        .opacity(item.kind == .note || item.isFolder ? 1 : 0.7)
        .padding(.leading, 8 + CGFloat(row.depth) * 14)
        .padding(.trailing, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isCurrent ? theme.rowSel : (hovering ? theme.rowHover : .clear))
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if item.isFolder {
                let key = item.url.standardizedFileURL.path
                if model.expanded.contains(key) { model.expanded.remove(key) } else { model.expanded.insert(key) }
            } else {
                actions.open(item.url)
            }
        }
        .onDrag { FileTreeDrag.item(for: item.url) }
        .contextMenu { menu }
        .help(model.vault.relativePath(of: item.url))
        .accessibilityIdentifier("note-\(model.vault.relativePath(of: item.url))")
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @ViewBuilder private var menu: some View {
        let folder = item.isFolder ? item.url : item.url.deletingLastPathComponent()
        Button("New Note") { actions.newNote(folder) }
        Button("New Folder") { actions.newFolder(folder) }
        Divider()
        if !item.isFolder {
            Button("Open") { actions.open(item.url) }
            Button("Copy Link") {
                let source = model.current.map(model.path(of:)) ?? ""
                let text = model.index.resolver.linkText(
                    for: model.path(of: item.url), from: source, format: model.vault.settings.newLinkFormat)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.kind == .image ? "![[\(text)]]" : "[[\(text)]]", forType: .string)
            }
        }
        if item.isFolder { Button("New Tab Here") { actions.newTab(item.url) } }
        Button("Insert Path in Terminal") { actions.insertPath(item.url) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Divider()
        Button("Copy Path") { Self.copy(item.url.path) }
        // In the vault — `.md` kept, as a path is written (Copy Link has the name).
        Button("Copy Relative Path") { Self.copy(model.vault.relativePath(of: item.url)) }
        Divider()
        Button("Rename…") { actions.rename(item.url) }
        Button("Move to Trash…") { actions.trash(item.url) }
    }
}
