import AppKit
import SwiftUI

/// Overgit's Changes: the working tree's files — staged or not — each with
/// its box, and the message and Commit under them; Push when the branch is
/// ahead. GitLens's Source Control, in the sidebar.
///
/// It reads nothing of its own: the files are `DiffModel`'s, which the
/// title bar's badge already keeps, and staging goes through it too
/// (CLAUDE.md: what a panel can get from a model the window has, it must
/// not ask git for a second time).
struct OvergitChanges: View {
    @ObservedObject var diff: DiffModel
    @ObservedObject var theme: ChromeTheme
    /// How far the branch is ahead of its upstream (Push shows then).
    let ahead: Int
    let hasUpstream: Bool
    let onOpen: (ChangedFile) -> Void
    /// Committed or pushed: the panel's history reads again.
    let onCommitted: () -> Void
    @State private var message = ""
    @State private var amend = false
    @State private var busy: String?
    @State private var discarding: ChangedFile?

    private var trimmed: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var staged: [ChangedFile] { diff.files.filter(\.isStaged) }
    private var unstaged: [ChangedFile] { diff.files.filter { !$0.isStaged || $0.hasUnstaged } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if diff.files.isEmpty {
                OvergitEmpty(text: "No changes to commit", theme: theme)
            } else {
                if !staged.isEmpty { group("Staged", files: staged, staged: true) }
                if !unstaged.isEmpty { group("Changes", files: unstaged, staged: false) }
            }
            composer
        }
        .confirmationDialog(
            "Discard changes to \((discarding?.path as NSString?)?.lastPathComponent ?? "")?",
            isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }),
            presenting: discarding
        ) { file in
            Button("Discard", role: .destructive) { Task { await diff.discard(file) } }
        } message: { file in
            Text(file.kind == .untracked || file.kind == .added ? "It goes to the Trash." : "Back to the last commit — this can't be undone.")
        }
    }

    // MARK: Files

    private func group(_ title: String, files: [ChangedFile], staged: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(verbatim: title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.text3)
                Text(verbatim: "\(files.count)").font(.system(size: 10)).foregroundStyle(theme.text3)
                Spacer(minLength: 0)
                Button(staged ? "Unstage All" : "Stage All") {
                    Task { staged ? await diff.unstageAll() : await diff.stageAll() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.accentText)
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 2)
            ForEach(files) { file in
                ChangeRow(
                    file: file, staged: staged, theme: theme,
                    onToggle: { Task { staged ? await diff.unstage(file) : await diff.stage(file) } },
                    onOpen: { onOpen(file) },
                    onDiscard: { discarding = file })
            }
        }
    }

    // MARK: Commit and push

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !diff.files.isEmpty || amend {
                TextField(amend ? "Amended message" : "Message (⌘↩ to commit)", text: $message, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(1...6)
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.rowHover.opacity(0.7)))
                    .accessibilityIdentifier("overgitCommitMessage")
                HStack(spacing: 8) {
                    Toggle("Amend", isOn: $amend)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .help("Change the last commit instead of making a new one")
                        .onChange(of: amend) { on in
                            // Amending starts from the last message, as git's editor would.
                            guard on, trimmed.isEmpty else { return }
                            Task { message = await diff.lastCommitMessage() ?? "" }
                        }
                    Spacer(minLength: 0)
                    Button(commitTitle) { commit() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(trimmed.isEmpty || busy != nil)
                        .controlSize(.small)
                }
            }
            if let error = diff.actionError {
                Text(verbatim: error).font(.system(size: 11)).foregroundStyle(DiffColors.removed).lineLimit(4)
                    .textSelection(.enabled)
            }
            if ahead > 0 || (!hasUpstream && diff.branch != nil && diff.files.isEmpty) {
                Button {
                    push()
                } label: {
                    Label(
                        busy == "push" ? "Pushing…" : (hasUpstream ? "Push \(ahead) commit\(ahead == 1 ? "" : "s")" : "Publish Branch"),
                        systemImage: "arrow.up.circle"
                    )
                    .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accentText)
                .disabled(busy != nil)
                .accessibilityIdentifier("overgitPush")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var commitTitle: String {
        if busy == "commit" { return "Committing…" }
        if amend { return "Amend" }
        return staged.isEmpty ? "Commit All" : "Commit \(staged.count)"
    }

    private func commit() {
        guard !trimmed.isEmpty, busy == nil else { return }
        busy = "commit"
        let text = trimmed
        Task { @MainActor in
            let ok = staged.isEmpty && !amend ? await diff.commitAll(message: text) : await diff.commit(message: text, amend: amend)
            busy = nil
            if ok {
                message = ""
                amend = false
                onCommitted()
            }
        }
    }

    private func push() {
        busy = "push"
        Task { @MainActor in
            await diff.push()
            busy = nil
            onCommitted()
        }
    }
}

/// One changed file: its box, its letter, its name, its numbers.
private struct ChangeRow: View {
    let file: ChangedFile
    let staged: Bool
    @ObservedObject var theme: ChromeTheme
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onDiscard: () -> Void
    @State private var hovering = false

    private var letter: (String, Color) {
        switch file.kind {
        case .modified, .typeChanged: ("M", theme.orangeText)
        case .added: ("A", DiffColors.added)
        case .untracked: ("U", DiffColors.added)
        case .deleted: ("D", DiffColors.removed)
        case .renamed: ("R", theme.orangeText)
        case .conflicted: ("!", DiffColors.removed)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                Image(systemName: staged ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(staged ? theme.accentText : theme.text3)
            }
            .buttonStyle(.plain)
            .help(staged ? "Unstage" : "Stage")
            .accessibilityIdentifier("stage-\(file.path)")
            Text(verbatim: letter.0).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(letter.1).frame(width: 10)
            Text(verbatim: (file.path as NSString).lastPathComponent).font(.system(size: 12)).foregroundStyle(theme.text).lineLimit(1)
            Text(verbatim: (file.path as NSString).deletingLastPathComponent)
                .font(.system(size: 10.5)).foregroundStyle(theme.text3).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 2)
            if let added = file.added, let removed = file.removed {
                Text(verbatim: "+\(added)").font(.system(size: 10, design: .monospaced)).foregroundStyle(DiffColors.added)
                Text(verbatim: "−\(removed)").font(.system(size: 10, design: .monospaced)).foregroundStyle(DiffColors.removed)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? theme.rowHover : .clear).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .help(file.path)
        .contextMenu {
            Button(staged ? "Unstage" : "Stage", action: onToggle)
            Button("Open Diff", action: onOpen)
            Divider()
            Button("Discard Changes…", action: onDiscard)
        }
    }
}

/// The search over Overgit's commits, with what it understands in its help.
struct CommitSearchField: View {
    @ObservedObject var model: OvergitModel
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(theme.text3)
            TextField("Search commits", text: $model.commitQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .accessibilityIdentifier("overgitCommitSearch")
            if model.isSearching { ProgressView().controlSize(.mini) }
            if !model.commitQuery.isEmpty {
                Button {
                    model.commitQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.text3)
            }
            Menu {
                Button("Author…") { model.commitQuery += (model.commitQuery.isEmpty ? "" : " ") + "author:" }
                Button("File or Folder…") { model.commitQuery += (model.commitQuery.isEmpty ? "" : " ") + "path:" }
                Button("Changed Code…") { model.commitQuery += (model.commitQuery.isEmpty ? "" : " ") + "code:" }
                Button("Since…") { model.commitQuery += (model.commitQuery.isEmpty ? "" : " ") + "since:2.weeks" }
                Button("On Branch…") { model.commitQuery += (model.commitQuery.isEmpty ? "" : " ") + "branch:" }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Filters: author:, path:, code:, since:, branch: — words search the message, a hash finds its commit")
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.rowHover.opacity(0.7)))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
