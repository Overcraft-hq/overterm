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
    /// Another folder as the vault, picked in an open panel.
    var chooseVault: () -> Void
}

/// The sidebar's Notes panel: the vault's folders and notes, Obsidian's
/// order, a filter, and the vault switcher in the header.
struct NotesPanelView: View {
    @ObservedObject var model: NotesModel
    @ObservedObject var theme: ChromeTheme
    let actions: NotesActions

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
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
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
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
            .help(model.vault.root.path)
            .accessibilityIdentifier("notesVault")
            Spacer(minLength: 4)
            if model.isLoading && model.tree != nil { ProgressView().controlSize(.mini) }
            PanelHeaderButton(symbol: "square.and.pencil", help: "New Note", action: { actions.newNote(nil) }, theme: theme)
            PanelHeaderButton(symbol: "calendar", help: "Today’s Note", action: actions.dailyNote, theme: theme)
            PanelHeaderButton(symbol: "folder.badge.plus", help: "New Folder", action: { actions.newFolder(nil) }, theme: theme)
            PanelHeaderButton(symbol: "rectangle.compress.vertical", help: "Collapse All", action: model.collapseAll, theme: theme)
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
    static func rows(_ root: NoteItem, query: String, expanded: Set<String>) -> [Row] {
        let filtering = !query.isEmpty
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
                ForEach(Self.rows(tree, query: model.query, expanded: model.expanded)) { row in
                    NoteRowView(row: row, model: model, theme: theme, actions: actions)
                }
            }
            .padding(.vertical, 4)
        }
        .contextMenu { folderMenu(model.vault.root) }
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
        Button("Insert Path in Terminal") { actions.insertPath(item.url) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Divider()
        Button("Rename…") { actions.rename(item.url) }
        Button("Move to Trash…") { actions.trash(item.url) }
    }
}
