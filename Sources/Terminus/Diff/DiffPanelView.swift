import AppKit
import SwiftUI

/// The changes pane beside the terminal, laid out like Warp's: a header
/// (checkout, branch, file count, totals), an "Uncommitted changes" row with
/// Commit, and one foldable card per changed file with its diff inline.
struct DiffPanelView: View {
    @ObservedObject var model: DiffModel
    let theme: ChromeTheme
    let onClose: () -> Void
    /// Undo an attachment: back to following the agent / shell.
    let onDetach: () -> Void
    /// Opens a changed file in the editor pane.
    let onOpen: (URL) -> Void
    /// The file whose Discard is awaiting confirmation.
    @State private var discarding: ChangedFile?
    @State private var composing = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = model.error {
                placeholder(error)
            } else if model.files.isEmpty {
                placeholder(model.root == nil ? "" : "No uncommitted changes")
            } else {
                changesBar
                if composing {
                    CommitComposer(model: model, theme: theme, onDone: { composing = false })
                }
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.files) { file in
                            FileCard(
                                file: file, diff: model.diffs[file.path], collapsed: model.collapsed.contains(file.path),
                                theme: theme,
                                onToggle: {
                                    if model.collapsed.contains(file.path) {
                                        model.collapsed.remove(file.path)
                                    } else {
                                        model.collapsed.insert(file.path)
                                    }
                                },
                                onStage: { Task { await model.toggleStaged(file) } },
                                onDiscard: { discarding = file },
                                onOpen: { model.root.map { onOpen($0.appendingPathComponent(file.path)) } }
                            )
                        }
                        if model.files.count > DiffModel.maxDiffedFiles {
                            Text("Diffs shown for the first \(DiffModel.maxDiffedFiles) files.")
                                .font(.system(size: 11)).foregroundStyle(theme.dimText)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(theme.strip)
        .alert(
            "Discard changes to \((discarding?.path as NSString?)?.lastPathComponent ?? "")?",
            isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }),
            presenting: discarding
        ) { file in
            Button("Discard", role: .destructive) { Task { await model.discard(file) } }
            Button("Cancel", role: .cancel) {}
        } message: { file in
            Text(
                file.kind == .untracked || file.kind == .added
                    ? "The file is moved to the Trash."
                    : "Staged and unstaged changes are lost; the file goes back to HEAD.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(headerTitle)
                .font(.system(size: 12))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .truncationMode(.head)
                .help(model.root?.path ?? "")
            if !model.files.isEmpty {
                Image(systemName: "doc").font(.system(size: 10)).foregroundStyle(theme.dimText)
                Text(verbatim: "\(model.files.count)").foregroundStyle(theme.text)
                Text("·").foregroundStyle(theme.dimText)
                Text(verbatim: "+\(model.totals.added)").foregroundStyle(DiffColors.added)
                Text(verbatim: "−\(model.totals.removed)").foregroundStyle(DiffColors.removed)
            }
            Spacer(minLength: 0)
            sourceChip
            iconButton("arrow.clockwise", help: "Refresh") { Task { await model.refresh() } }
            iconButton("xmark", help: "Close (⌥⌘D)", action: onClose)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    /// Why this checkout: following the tab's agent into its worktree, or
    /// attached by hand (with Detach).
    @ViewBuilder private var sourceChip: some View {
        switch model.showing {
        case .agent(let agent):
            Label("following \(agent.name)", systemImage: agent.symbol)
                .font(.system(size: 11))
                .foregroundStyle(TabStatusStyle.signal)
                .help("\(agent.name) is working in this worktree")
        case .attached:
            Button(action: onDetach) {
                Label("attached · Detach", systemImage: "pin.fill").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Pinned to this tab — Detach to follow the shell and agent again")
        case .shell:
            EmptyView()
        }
    }

    private var headerTitle: String {
        let path = model.root?.path ?? ""
        return model.branch.map { "\(path): \($0)" } ?? path
    }

    private var changesBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right").font(.system(size: 11))
            Text("Uncommitted changes").font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Button {
                composing.toggle()
            } label: {
                Label("Commit", systemImage: "arrow.triangle.merge")
            }
            .controlSize(.small)
        }
        .foregroundStyle(theme.text)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(theme.dimText).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.dimText)
        .help(help)
    }
}

enum DiffColors {
    static let added = Color(red: 0.36, green: 0.78, blue: 0.44)
    static let removed = Color(red: 0.94, green: 0.36, blue: 0.34)
}

/// One changed file: a header row and, unfolded, its diff.
private struct FileCard: View {
    let file: ChangedFile
    let diff: DiffModel.FileDiff?
    let collapsed: Bool
    let theme: ChromeTheme
    let onToggle: () -> Void
    let onStage: () -> Void
    let onDiscard: () -> Void
    let onOpen: () -> Void

    private var stageSymbol: String {
        switch file.stageState {
        case .full: "checkmark.square.fill"
        case .partial: "minus.square.fill"
        case .none: "square"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !collapsed {
                Divider().opacity(0.3)
                if let diff, !diff.lines.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.lines) { DiffLineView(line: $0, theme: theme) }
                        if diff.truncated {
                            Text("Diff truncated.").font(.system(size: 11)).foregroundStyle(theme.dimText).padding(8)
                        }
                    }
                    .padding(.vertical, 4)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                } else {
                    Text(diff == nil ? "Loading…" : "No textual diff (binary or empty).")
                        .font(.system(size: 11)).foregroundStyle(theme.dimText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.selected.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.dimText.opacity(0.2)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold)).frame(width: 14, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            Button(action: onStage) {
                Image(systemName: stageSymbol).font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(file.stageState == .none ? theme.dimText : theme.text)
            .help(file.stageState == .full ? "Unstage" : "Stage")
            Text((file.path as NSString).lastPathComponent)
                .font(.system(size: 13))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            let dir = (file.path as NSString).deletingLastPathComponent
            if !dir.isEmpty {
                Text(dir).font(.system(size: 11)).foregroundStyle(theme.dimText).lineLimit(1).truncationMode(.head)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Copy Path")
            counts
            Spacer(minLength: 4)
            Button(action: onDiscard) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Discard Changes…")
            Button(action: onOpen) {
                Image(systemName: "arrow.up.forward.square").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Open in Editor")
            .disabled(file.kind == .deleted)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .help(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
    }

    @ViewBuilder private var counts: some View {
        if let added = file.added, let removed = file.removed {
            HStack(spacing: 3) {
                Text(verbatim: "+\(added)").foregroundStyle(DiffColors.added)
                Text("·").foregroundStyle(theme.dimText)
                Text(verbatim: "−\(removed)").foregroundStyle(DiffColors.removed)
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.dimText.opacity(0.3)))
        }
    }
}

private struct DiffLineView: View {
    let line: DiffLine
    let theme: ChromeTheme

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(edge).frame(width: 3)
            number(line.oldNumber)
            number(line.newNumber)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .hunk || line.kind == .meta ? theme.dimText : theme.text)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
        }
        .frame(height: 18)
        .background(background)
    }

    private var edge: Color {
        switch line.kind {
        case .added: DiffColors.added
        case .removed: DiffColors.removed
        default: .clear
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: DiffColors.added.opacity(0.14)
        case .removed: DiffColors.removed.opacity(0.14)
        case .hunk: theme.selected.opacity(0.6)
        default: .clear
        }
    }

    private func number(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .foregroundStyle(theme.dimText.opacity(0.7))
            .frame(width: 38, alignment: .trailing)
            .padding(.trailing, 6)
    }
}

/// The commit message under "Uncommitted changes". Commits what is staged —
/// or, with nothing staged, everything.
private struct CommitComposer: View {
    @ObservedObject var model: DiffModel
    let theme: ChromeTheme
    let onDone: () -> Void
    @State private var message = ""
    @State private var committing = false

    private var trimmed: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Commit message", text: $message, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...5)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.selected))
            if let error = model.actionError {
                Text(error).font(.system(size: 11)).foregroundStyle(DiffColors.removed).lineLimit(3)
            }
            HStack {
                Text(model.stagedCount == 0 ? "Nothing staged — commits all changes." : "\(model.stagedCount) staged.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.dimText)
                Spacer()
                Button("Cancel", action: onDone)
                Button(committing ? "Committing…" : (model.stagedCount == 0 ? "Commit All" : "Commit")) { commit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(trimmed.isEmpty || committing)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func commit() {
        committing = true
        Task { @MainActor in
            let ok = model.stagedCount == 0 ? await model.commitAll(message: trimmed) : await model.commit(message: trimmed)
            committing = false
            if ok {
                message = ""
                onDone()
            }
        }
    }
}
