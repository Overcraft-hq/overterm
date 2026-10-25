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

    /// The open note's tasks, done ones too — or the vault's open ones,
    /// grouped by note, the most recently changed first. A vault holding
    /// agents' plans had pages of tasks under file names; the note open is
    /// what is usually meant.
    @ViewBuilder private var tasks: some View {
        Picker("", selection: $model.tasksInVault) {
            Text("This Note").tag(false)
            Text("Vault").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        if model.tasksInVault {
            vaultTasks
        } else if let path = currentPath {
            let items = model.index.document(path)?.tasks ?? []
            if items.isEmpty {
                placeholder("No tasks in this note")
            } else {
                ForEach(items, id: \.line) { task in taskRow(task, in: path) }
            }
        } else {
            placeholder("Open a note to see its tasks")
        }
    }

    @ViewBuilder private var vaultTasks: some View {
        let groups = NotesTaskGroups.make(model.index)
        if groups.isEmpty {
            placeholder("No open tasks")
        } else {
            ForEach(groups, id: \.path) { group in
                let open = !model.foldedTaskNotes.contains(group.path)
                HStack(spacing: 4) {
                    Button {
                        if open { model.foldedTaskNotes.insert(group.path) } else { model.foldedTaskNotes.remove(group.path) }
                    } label: {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                            .frame(width: 12, height: 16).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        actions.open(model.url(of: group.path))
                    } label: {
                        HStack(spacing: 4) {
                            Text(verbatim: group.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text2)
                                .lineLimit(1).truncationMode(.middle)
                            if !group.folder.isEmpty {
                                Text(verbatim: group.folder).font(.system(size: 10)).foregroundStyle(theme.text3)
                                    .lineLimit(1).truncationMode(.head)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(group.path)
                    Spacer(minLength: 4)
                    Text(verbatim: "\(group.tasks.count)").font(.system(size: 10)).foregroundStyle(theme.text3)
                }
                .foregroundStyle(theme.text3)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 2)
                if open {
                    ForEach(group.tasks, id: \.line) { task in taskRow(task, in: group.path) }
                }
            }
        }
    }

    private func taskRow(_ task: NoteDocument.Task, in path: String) -> some View {
        DetailRow(theme: theme, help: path) {
            HStack(alignment: .top, spacing: 6) {
                Button {
                    actions.toggleTask(model.url(of: path), task.line, task.text)
                } label: {
                    Image(systemName: task.isDone ? "checkmark.square.fill" : "square").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(task.isDone ? theme.accentText : theme.text3)
                .help(task.isDone ? "Not done" : "Done")
                Text(NotesTaskGroups.inline(task.text))
                    .font(.system(size: 11.5))
                    .foregroundStyle(task.isDone ? theme.text3 : theme.text2)
                    .strikethrough(task.isDone)
                    .lineLimit(2)
            }
        } action: {
            actions.openAt(model.url(of: path), task.line)
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

/// The vault's open tasks by note, for the Tasks pane. Pure.
enum NotesTaskGroups {
    struct Group: Equatable {
        var path: String
        /// The note's first heading, else its name.
        var title: String
        var folder: String
        var modified: Date
        var tasks: [NoteDocument.Task]
    }

    /// Notes with an open task, the most recently changed first.
    static func make(_ index: NotesIndex, limit: Int = 60) -> [Group] {
        index.paths.compactMap { path -> Group? in
            guard let entry = index.notes[path] else { return nil }
            let open = entry.document.tasks.filter { !$0.isDone && $0.status != "-" }
            guard !open.isEmpty else { return nil }
            let name = (LinkResolver.name(of: path) as NSString).deletingPathExtension
            return Group(
                path: path, title: entry.document.title ?? name, folder: LinkResolver.folder(of: path), modified: entry.modified, tasks: open)
        }
        .sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.path < $1.path }
        .prefix(limit).map { $0 }
    }

    /// A task's Markdown as it reads: **bold**, `code`, links — not its markup.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        // Wikilinks read as their names.
        let plain = text.replacingOccurrences(of: #"\[\[([^\]|]+\|)?([^\]]+)\]\]"#, with: "$2", options: .regularExpression)
        return (try? AttributedString(markdown: plain, options: options)) ?? AttributedString(plain)
    }
}
