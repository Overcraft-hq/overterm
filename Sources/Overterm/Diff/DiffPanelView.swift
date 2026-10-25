import AppKit
import SwiftUI

/// The changes pane beside the terminal, laid out like Warp's: a header
/// (checkout, branch, file count, totals), the Uncommitted | Branch switch
/// (Commit beside it for uncommitted changes), the branch's commits, and one
/// foldable card per changed file with its diff inline — folded to start
/// with when many files changed, a list of them — and, under its header, why
/// it changed.
struct DiffPanelView: View {
    @ObservedObject var model: DiffModel
    @ObservedObject var theme: ChromeTheme
    let onClose: () -> Void
    /// Undo an attachment: back to following the agent / shell.
    let onDetach: () -> Void
    /// Opens a changed file in the editor pane.
    let onOpen: (URL) -> Void
    /// The file whose Discard is awaiting confirmation.
    @State private var discarding: ChangedFile?
    @State private var composing = false
    /// Commits whose message is shown.
    @State private var openCommits: Set<String> = []

    /// Stage, discard and commit act on the index: only for uncommitted changes.
    private var editable: Bool { model.shownScope == .uncommitted }
    private var palette: DiffPalette { DiffPalette(text: theme.textNS) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = model.error {
                placeholder(error)
            } else if model.root == nil {
                placeholder("")
            } else {
                scopeBar
                if let note = model.scopeNote {
                    Text(verbatim: note)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.dimText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                        .help(branchHelp)
                }
                if composing, editable {
                    CommitComposer(model: model, theme: theme, onDone: { composing = false })
                }
                if model.shownFiles.isEmpty, editable || model.commits.isEmpty {
                    placeholder(editable ? "No uncommitted changes" : "No changes on this branch")
                } else {
                    cards
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

    private var cards: some View {
        ScrollViewReader { proxy in
            cardList
                .onChange(of: model.revealed?.ticket) { _ in
                    guard let path = model.revealed?.path else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(path, anchor: .top) }
                }
        }
    }

    private var cardList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if !editable, !model.commits.isEmpty {
                    CommitList(
                        commits: model.commits, more: model.moreCommits, open: openCommits, theme: theme,
                        onToggle: { id in
                            if openCommits.contains(id) { openCommits.remove(id) } else { openCommits.insert(id) }
                        })
                }
                ForEach(model.shownFiles) { file in
                    FileCard(
                        file: file, diff: model.diffs[file.path], collapsed: model.isFolded(file.path),
                        editable: editable, theme: theme, palette: palette,
                        why: model.why(for: file.path),
                        onToggleWhy: { model.toggleWhy(file.path) },
                        onToggle: { model.toggleFold(file.path) },
                        onStage: { Task { await model.toggleStaged(file) } },
                        onDiscard: { discarding = file },
                        onOpen: { model.root.map { onOpen($0.appendingPathComponent(file.path)) } }
                    )
                    .id(file.path)
                }
                if model.shownFiles.count > DiffModel.maxDiffedFiles {
                    Text("Diffs shown for the first \(DiffModel.maxDiffedFiles) files.")
                        .font(.system(size: 11)).foregroundStyle(theme.dimText)
                }
            }
            .padding(12)
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
            if !model.shownFiles.isEmpty {
                Image(systemName: "doc").font(.system(size: 10)).foregroundStyle(theme.dimText)
                Text(verbatim: "\(model.shownFiles.count)").foregroundStyle(theme.text)
                Text("·").foregroundStyle(theme.dimText)
                Text(verbatim: "+\(model.shownTotals.added)").foregroundStyle(DiffColors.added)
                Text(verbatim: "−\(model.shownTotals.removed)").foregroundStyle(DiffColors.removed)
            }
            Spacer(minLength: 0)
            sourceChip
            if !model.shownFiles.isEmpty {
                // Expand All once every card is folded, else Collapse All.
                if model.everyCardFolded {
                    iconButton("rectangle.expand.vertical", help: "Expand All") { model.expandAll() }
                } else {
                    iconButton("rectangle.compress.vertical", help: "Collapse All") { model.collapseAll() }
                }
            }
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

    /// Uncommitted | Branch, each with its file count, and Commit.
    private var scopeBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                scopeButton(.uncommitted, "Uncommitted", count: model.files.count)
                    .help("Staged, unstaged and untracked changes, against HEAD")
                scopeButton(.branch, "Branch", count: model.comparison?.mergeBase == nil ? nil : model.branchFiles.count)
                    .help(branchHelp)
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(theme.selected.opacity(0.5)))
            Spacer(minLength: 0)
            if editable, !model.files.isEmpty {
                Button {
                    composing.toggle()
                } label: {
                    Label("Commit", systemImage: "arrow.triangle.merge")
                }
                .controlSize(.small)
            }
        }
        .foregroundStyle(theme.text)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    /// Highlighted: the scope listed below — Uncommitted when Branch is
    /// picked but has nothing to compare with (the note says why).
    private func scopeButton(_ scope: DiffModel.Scope, _ title: String, count: Int?) -> some View {
        let on = model.shownScope == scope
        return Button {
            model.choose(scope)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if let count { Text(verbatim: "\(count)").foregroundStyle(theme.dimText) }
            }
            .font(.system(size: 12, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? theme.text : theme.dimText)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(on ? theme.selected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var branchHelp: String {
        switch model.comparison {
        case .since(let mergeBase, let base)?:
            "Everything since this branch left \(base) — its commits and what is not committed yet — against their merge-base \(mergeBase.prefix(7))"
        case let other?: other.unavailable ?? ""
        case nil: ""
        }
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

/// Under a card's header, quiet: why the file changed. Claude's words at its
/// latest edit, two lines and when; a click shows them in full, and what it
/// said at the edits before. In Branch, the commits that touched the file.
/// Nothing when there is nothing to say.
struct WhyStrip: View {
    let why: FileWhy
    @ObservedObject var theme: ChromeTheme
    let onToggle: () -> Void
    /// Commits listed at most; the rest are counted.
    private static let maxCommits = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(why.shownReasons.enumerated()), id: \.offset) { index, edit in
                ReasonRow(edit: edit, open: why.open, more: index == 0 ? why.hiddenReasons : 0, theme: theme)
            }
            ForEach(why.commits.prefix(Self.maxCommits)) { commit in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "smallcircle.filled.circle").font(.system(size: 9)).foregroundStyle(theme.dimText).frame(width: 12)
                    Text(verbatim: commit.subject)
                        .font(.system(size: 12)).foregroundStyle(theme.text.opacity(0.85))
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: commit.shortSHA).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.dimText)
                }
                .help(Self.help(commit))
            }
            if why.commits.count > Self.maxCommits {
                Text(verbatim: "and \(why.commits.count - Self.maxCommits) more commits")
                    .font(.system(size: 11)).foregroundStyle(theme.dimText).padding(.leading, 18)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }

    /// A plain string: a subject is never read as markdown or localized.
    private static func help(_ commit: BranchCommit) -> String { "\(commit.shortSHA), \(commit.date): \(commit.subject)" }
}

/// One reason: what it is (Claude's words, your prompt, the session's title),
/// the text, and when.
private struct ReasonRow: View {
    let edit: ClaudeEdit
    let open: Bool
    /// Reasons not shown until opened.
    let more: Int
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(theme.dimText).frame(width: 12)
            Text(verbatim: edit.reason?.text ?? "")
                .font(.system(size: 12))
                .foregroundStyle(theme.text.opacity(0.85))
                .lineLimit(open ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                if more > 0 { Text(verbatim: "+\(more)") }
                if let time = edit.time { Text(verbatim: ClaudeEdits.ago(time)) }
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.dimText)
            .fixedSize()
        }
        .help(help)
    }

    private var symbol: String {
        switch edit.reason?.source {
        case .said?: Agent.claude.symbol
        case .asked?: "person"
        case .title?, nil: "text.bubble"
        }
    }

    private var help: String {
        switch edit.reason?.source {
        case .said?: "What Claude said making this edit (\(edit.tool))"
        case .asked?: "What Claude was asked: it said nothing before this edit (\(edit.tool))"
        case .title?, nil: "The session's title: nothing was said or asked before this edit (\(edit.tool))"
        }
    }
}

/// The branch's commits, newest first: subject and short hash; a click
/// shows when, the rest of the message and the files it touched.
private struct CommitList: View {
    let commits: [BranchCommit]
    /// There are more than those listed.
    let more: Bool
    let open: Set<String>
    @ObservedObject var theme: ChromeTheme
    let onToggle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "smallcircle.filled.circle").font(.system(size: 11)).foregroundStyle(theme.dimText)
                Text("Commits").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                Text(verbatim: more ? "\(commits.count)+" : "\(commits.count)").foregroundStyle(theme.dimText)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: 30)
            Divider().opacity(0.3)
            ForEach(commits) { commit in
                CommitRow(commit: commit, open: open.contains(commit.id), theme: theme, onToggle: { onToggle(commit.id) })
            }
        }
        .padding(.bottom, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.selected.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.dimText.opacity(0.2)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct CommitRow: View {
    let commit: BranchCommit
    let open: Bool
    @ObservedObject var theme: ChromeTheme
    let onToggle: () -> Void
    /// A huge commit's file list is cut here.
    private static let maxFiles = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.dimText).frame(width: 12)
                Text(verbatim: commit.subject).font(.system(size: 12)).foregroundStyle(theme.text).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(verbatim: commit.shortSHA).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.dimText)
            }
            .frame(minHeight: 22)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
            .help(commit.subject)
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: commit.date).font(.system(size: 11)).foregroundStyle(theme.dimText)
                    if !commit.body.isEmpty {
                        Text(verbatim: commit.body)
                            .font(.system(size: 12)).foregroundStyle(theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(commit.files.prefix(Self.maxFiles), id: \.self) { path in
                            Text(verbatim: path).lineLimit(1).truncationMode(.head)
                        }
                        if commit.files.count > Self.maxFiles {
                            Text(verbatim: "and \(commit.files.count - Self.maxFiles) more")
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.dimText)
                }
                .padding(.leading, 18)
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 10)
    }
}

/// The commit message under "Uncommitted changes". Commits what is staged —
/// or, with nothing staged, everything.
private struct CommitComposer: View {
    @ObservedObject var model: DiffModel
    @ObservedObject var theme: ChromeTheme
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
