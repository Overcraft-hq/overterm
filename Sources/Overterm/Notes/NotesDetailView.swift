import SwiftUI

/// The Notes panel's lower half — Obsidian's side panes: the links into
/// the note open (with the line each is on), its outline, the vault's
/// tags (one picked filters the tree), and its open tasks.
struct NotesDetailView: View {
    @ObservedObject var model: NotesModel
    @ObservedObject var theme: ChromeTheme
    let actions: NotesActions

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(theme.border).frame(height: 1)
            tabs
            if let detail = model.detail {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        switch detail {
                        case .backlinks: backlinks
                        case .outline: outline
                        case .tags: tags
                        case .tasks: tasks
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(NotesDetail.allCases) { detail in
                Button {
                    model.detail = model.detail == detail ? nil : detail
                } label: {
                    Image(systemName: detail.symbol)
                        .font(.system(size: 11, weight: model.detail == detail ? .semibold : .regular))
                        .frame(width: 26, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(model.detail == detail ? theme.rowSel : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.detail == detail ? theme.text : theme.text3)
                .help(detail.title)
                .accessibilityIdentifier("notesDetail-\(detail.rawValue)")
            }
            Spacer(minLength: 4)
            Button {
                model.detail = model.detail == nil ? .backlinks : nil
            } label: {
                Image(systemName: model.detail == nil ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                    .frame(width: 20, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.text3)
            .help(model.detail == nil ? "Show" : "Hide")
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
    }

    private var currentPath: String? { model.current.map(model.path(of:)) }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(theme.text3).padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: Panes

    @ViewBuilder private var backlinks: some View {
        if let path = currentPath {
            let lines = model.backlinkLines(of: path)
            if lines.isEmpty {
                placeholder("No links to this note")
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, entry in
                    DetailRow(theme: theme, help: entry.source) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: (LinkResolver.name(of: entry.source) as NSString).deletingPathExtension)
                                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.text)
                            Text(verbatim: entry.text).font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(2)
                        }
                    } action: {
                        actions.openAt(model.url(of: entry.source), entry.line)
                    }
                }
            }
        } else {
            placeholder("Open a note to see what links to it")
        }
    }

    @ViewBuilder private var outline: some View {
        if let path = currentPath, let doc = model.index.document(path) {
            if doc.headings.isEmpty {
                placeholder("No headings")
            } else {
                let top = doc.headings.map(\.level).min() ?? 1
                ForEach(Array(doc.headings.enumerated()), id: \.offset) { _, heading in
                    DetailRow(theme: theme, help: heading.text) {
                        Text(verbatim: heading.text).font(.system(size: 11.5)).foregroundStyle(theme.text2).lineLimit(1)
                            .padding(.leading, CGFloat(heading.level - top) * 12)
                    } action: {
                        actions.openAt(model.url(of: path), heading.line)
                    }
                }
            }
        } else {
            placeholder("Open a note to see its outline")
        }
    }

    @ViewBuilder private var tags: some View {
        let counts = model.index.tags
        if counts.isEmpty {
            placeholder("No tags in this vault")
        } else {
            ForEach(counts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { tag in
                let picked = model.tagFilter?.lowercased() == tag.lowercased()
                DetailRow(theme: theme, selected: picked, help: "Notes tagged #\(tag)") {
                    HStack(spacing: 4) {
                        Text(verbatim: "#" + (tag.split(separator: "/").last.map(String.init) ?? tag))
                            .font(.system(size: 11.5)).foregroundStyle(theme.text2).lineLimit(1)
                            .padding(.leading, CGFloat(tag.split(separator: "/").count - 1) * 12)
                        Spacer(minLength: 4)
                        Text(verbatim: "\(counts[tag] ?? 0)").font(.system(size: 10)).foregroundStyle(theme.text3)
                    }
                } action: {
                    model.tagFilter = picked ? nil : tag
                }
            }
        }
    }

    @ViewBuilder private var tasks: some View {
        let open = model.index.tasks.filter { !$0.task.isDone && $0.task.status != "-" }
        if open.isEmpty {
            placeholder("No open tasks")
        } else {
            let grouped = Dictionary(grouping: open, by: \.path)
            ForEach(grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { path in
                Text(verbatim: (LinkResolver.name(of: path) as NSString).deletingPathExtension)
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(theme.text3)
                    .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
                ForEach(grouped[path] ?? [], id: \.task.line) { item in
                    DetailRow(theme: theme, help: path) {
                        HStack(alignment: .top, spacing: 6) {
                            Button {
                                actions.toggleTask(model.url(of: path), item.task.line, item.task.text)
                            } label: {
                                Image(systemName: "square").font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.text3)
                            .help("Done")
                            Text(verbatim: item.task.text).font(.system(size: 11.5)).foregroundStyle(theme.text2).lineLimit(2)
                        }
                    } action: {
                        actions.openAt(model.url(of: path), item.task.line)
                    }
                }
            }
        }
    }
}

/// One row of a pane: hover, a click, the panel's rounded selection.
private struct DetailRow<Content: View>: View {
    @ObservedObject var theme: ChromeTheme
    var selected = false
    let help: String
    @ViewBuilder var content: Content
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5).fill(selected ? theme.rowSel : (hovering ? theme.rowHover : .clear)).padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .help(help)
    }
}
