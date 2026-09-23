import AppKit
import SwiftUI

/// What the file tree asks the window to do with an entry.
struct FileTreeActions {
    /// Type the entry's path into the selected terminal.
    var insertPath: (URL) -> Void
    /// Open a new tab whose shell starts in this folder.
    var newTab: (URL) -> Void
    /// The path as the selected tab's shell would write it (relative to its
    /// cwd when inside it).
    var relativePath: (URL) -> String
}

/// The left panel: for now, the file tree of the selected tab's checkout.
struct SidebarView: View {
    @ObservedObject var tree: FileTreeModel
    let theme: ChromeTheme
    let actions: FileTreeActions

    var body: some View {
        VStack(spacing: 0) {
            header
            if tree.root == nil {
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(tree.rows) { row in
                            FileRowView(row: row, tree: tree, theme: theme, actions: actions)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(theme.strip)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(tree.root?.lastPathComponent ?? "")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(theme.dimText)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(tree.root?.path ?? "")
            Spacer(minLength: 0)
            headerButton("arrow.clockwise", help: "Reload") { tree.reload() }
            headerButton("rectangle.compress.vertical", help: "Collapse All") { tree.collapseAll() }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.dimText)
        .help(help)
    }
}

private struct FileRowView: View {
    let row: FileRow
    @ObservedObject var tree: FileTreeModel
    let theme: ChromeTheme
    let actions: FileTreeActions
    @State private var hovering = false

    private var isSelected: Bool { tree.selection == row.id }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .frame(width: 10)
                .opacity(row.entry.isDirectory ? 1 : 0)
            Image(systemName: row.entry.isDirectory ? "folder" : "doc")
                .font(.system(size: 11))
                .frame(width: 14)
            Text(row.entry.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isSelected ? theme.text : theme.dimText)
        .padding(.leading, 8 + CGFloat(row.depth) * 14)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? theme.selected : (hovering ? theme.hover : .clear))
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            tree.selection = row.id
            tree.toggle(row)
        }
        // Simultaneous, so a plain click isn't held back for the double-click
        // interval. A folder already toggled on the single clicks.
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                if !row.entry.isDirectory { NSWorkspace.shared.open(row.entry.url) }
            }
        )
        .contextMenu { menu }
        .help(row.entry.url.path)
    }

    @ViewBuilder private var menu: some View {
        let url = row.entry.url
        Button("Insert Path in Terminal") { actions.insertPath(url) }
        if row.entry.isDirectory {
            Button("New Tab Here") { actions.newTab(url) }
        } else {
            Button("Open") { NSWorkspace.shared.open(url) }
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Divider()
        Button("Copy Path") { copy(url.path) }
        Button("Copy Relative Path") { copy(actions.relativePath(url)) }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
