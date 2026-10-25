import AppKit
import SwiftUI

/// What the Overgit panel asks the window to do.
struct OvergitActions {
    /// Show this commit in the right-hand pane.
    var showCommit: (Commit) -> Void
    /// Check a branch out in the checkout the panel is about.
    var checkOut: (BranchRef) -> Void
    /// A new worktree (and a tab) on this branch.
    var newWorktree: (BranchRef) -> Void
    /// The right pane on the current checkout's pull request.
    var showPullRequest: () -> Void
    /// A pull request on github.com.
    var openPullRequest: (PullRequestSummary) -> Void
    /// Any pull request of the repository, in the right-hand pane.
    var showPullRequestNumber: (PullRequestSummary) -> Void = { _ in }
    var applyStash: (Stash) -> Void
    var dropStash: (Stash) -> Void
    /// The changes pane, for the working tree.
    var showChanges: () -> Void
}

/// Overgit: one git home in the sidebar — where you are, what has
/// happened, what branches there are, what is in flight, and the worktrees
/// that used to have a panel of their own.
///
/// Every section but the overview is collapsible and reads nothing while
/// it is shut (`OvergitModel`). The rows are plain: a click opens the
/// thing, the context menu does the rest.
struct OvergitView: View {
    @ObservedObject var model: OvergitModel
    /// The working tree's own numbers and branch — already read, once, for
    /// the title bar's badge; Overgit does not ask again.
    @ObservedObject var diff: DiffModel
    @ObservedObject var worktrees: WorktreeModel
    /// Which tabs are in which worktree, for the Worktrees section.
    @ObservedObject var store: TabStore
    let currentRoot: URL?
    let group: TabGroup?
    @ObservedObject var theme: ChromeTheme
    let actions: OvergitActions
    let worktreeActions: WorktreeActions

    /// Fixed, because the graph's lines have to meet across rows.
    static let commitRowHeight: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Overgit", group: group, theme: theme, help: model.root?.path) {
                if model.isReading {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 22, height: 22)
                }
                PanelHeaderButton(symbol: "plus", help: "New Task… (⇧⌘N)", action: worktreeActions.newTask, theme: theme)
                PanelHeaderButton(
                    symbol: "arrow.clockwise", help: "Fetch and reload", action: reload, theme: theme)
            }
            if !model.isRepository {
                Text("Not in a git repository").font(.system(size: 12)).foregroundStyle(theme.text3).padding(12)
                Spacer()
            } else {
                list
            }
        }
    }

    private func reload() {
        Task {
            await worktrees.refresh(fetch: true)
            await model.refresh()
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                overview
                if let error = model.error {
                    Text(verbatim: error)
                        .font(.system(size: 11)).foregroundStyle(theme.orangeText)
                        .padding(.horizontal, 12).padding(.bottom, 6)
                }
                ForEach(OvergitModel.Section.allCases) { section in
                    OvergitSectionHeader(
                        section: section, open: model.isExpanded(section), count: count(of: section), theme: theme,
                        onToggle: { model.toggle(section) })
                    if model.isExpanded(section) { rows(of: section) }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func count(of section: OvergitModel.Section) -> Int {
        switch section {
        case .commits: model.commits.count
        case .branches: model.branches.count
        case .pullRequests: livePullRequests.count
        case .worktrees: worktrees.worktrees.count
        case .stashes: model.stashes.count
        case .tags: model.tags.count
        case .remotes: model.remotes.count
        }
    }

    @ViewBuilder private func rows(of section: OvergitModel.Section) -> some View {
        switch section {
        case .commits: commits
        case .branches: branches
        case .pullRequests: pullRequests
        case .worktrees: worktreeRows
        case .stashes: stashes
        case .tags: tags
        case .remotes: remotes
        }
    }

    /// Where you are: the branch, how it stands against its upstream, what
    /// is uncommitted, and the pull request if there is one.
    private var overview: some View {
        OvergitOverview(
            branch: diff.branch, ref: model.branch(named: diff.branch), badge: diff.badge,
            pullRequest: diff.branch.flatMap { worktrees.pullRequests[$0] }, theme: theme,
            onChanges: actions.showChanges, onPullRequest: actions.showPullRequest)
    }

    // MARK: Commits

    @ViewBuilder private var commits: some View {
        if model.commits.isEmpty {
            OvergitEmpty(text: "No commits yet", theme: theme)
        } else {
            let lanes = model.gutterLanes
            ForEach(Array(model.commits.enumerated()), id: \.element.id) { index, commit in
                CommitRowView(
                    commit: commit, row: model.graphRow(at: index), lanes: lanes,
                    isSelected: model.selected == commit.sha, theme: theme,
                    onOpen: { actions.showCommit(commit) })
            }
        }
    }

    // MARK: Branches

    @ViewBuilder private var branches: some View {
        if model.branches.isEmpty {
            OvergitEmpty(text: "No branches", theme: theme)
        } else {
            ForEach(BranchTree.rows(model.branches, expanded: model.expandedBranchFolders)) { node in
                BranchRowView(
                    node: node, isCurrent: node.branch?.name == diff.branch && node.branch?.isRemote == false,
                    isOpen: model.expandedBranchFolders.contains(node.id), theme: theme,
                    onToggle: {
                        if model.expandedBranchFolders.contains(node.id) {
                            model.expandedBranchFolders.remove(node.id)
                        } else {
                            model.expandedBranchFolders.insert(node.id)
                        }
                    },
                    actions: actions)
            }
        }
    }

    // MARK: Pull requests

    private var livePullRequests: [PullRequestSummary] {
        worktrees.pullRequests.values
            .filter { $0.state == .open || $0.state == .draft }
            .sorted { $0.number > $1.number }
    }

    @ViewBuilder private var pullRequests: some View {
        if let error = worktrees.pullRequestError {
            OvergitEmpty(text: error, theme: theme)
        } else if livePullRequests.isEmpty {
            OvergitEmpty(text: "No open pull requests", theme: theme)
        } else {
            ForEach(livePullRequests, id: \.number) { pr in
                PullRequestRowView(
                    pullRequest: pr, isCurrent: pr.branch == diff.branch, theme: theme,
                    // In the right-hand pane, whichever it is; ↗ for GitHub.
                    onOpen: { actions.showPullRequestNumber(pr) },
                    onOpenExternally: { actions.openPullRequest(pr) })
            }
        }
    }

    // MARK: Worktrees — the panel that used to have an icon of its own

    @ViewBuilder private var worktreeRows: some View {
        if worktrees.worktrees.isEmpty {
            OvergitEmpty(text: "No worktrees", theme: theme)
        } else {
            ForEach(worktrees.worktrees) { worktree in
                WorktreeRowView(
                    worktree: worktree,
                    isCurrent: currentRoot?.standardizedFileURL == worktree.path.standardizedFileURL,
                    tabs: store.tabs.filter { tab in
                        let directory = tab.attachedCheckout?.path ?? tab.agentDirectory ?? tab.workingDirectory
                        return directory.map { Worktree.containing($0, in: worktrees.worktrees)?.path == worktree.path } ?? false
                    },
                    reason: worktrees.showing.flatMap {
                        $0.root.standardizedFileURL == worktree.path.standardizedFileURL ? $0.reason : nil
                    },
                    merged: worktree.branch.flatMap { worktrees.merged[$0] },
                    pullRequest: worktree.branch.flatMap { worktrees.pullRequests[$0] },
                    theme: theme, actions: worktreeActions)
            }
            if !worktrees.cleanable.isEmpty {
                Button(action: worktreeActions.cleanUp) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.merge").font(.system(size: 9))
                        Text(verbatim: "Clean up \(worktrees.cleanable.count) merged")
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(TabStatusStyle.merged)
            }
        }
    }

    // MARK: Stashes, tags, remotes

    @ViewBuilder private var stashes: some View {
        if model.stashes.isEmpty {
            OvergitEmpty(text: "Nothing stashed", theme: theme)
        } else {
            ForEach(model.stashes) { stash in
                StashRowView(stash: stash, theme: theme, actions: actions)
            }
        }
    }

    @ViewBuilder private var tags: some View {
        if model.tags.isEmpty {
            OvergitEmpty(text: "No tags", theme: theme)
        } else {
            ForEach(model.tags) { tag in
                OvergitPlainRow(
                    symbol: "tag", title: tag.name, detail: tag.subject, trailing: tag.sha, theme: theme,
                    help: "\(tag.name) · \(tag.sha)")
            }
        }
    }

    @ViewBuilder private var remotes: some View {
        if model.remotes.isEmpty {
            OvergitEmpty(text: "No remotes", theme: theme)
        } else {
            ForEach(model.remotes) { remote in
                OvergitPlainRow(
                    symbol: "cloud", title: remote.name, detail: remote.host ?? remote.url, trailing: nil, theme: theme,
                    help: remote.url)
            }
        }
    }
}

// MARK: - The pieces

/// A collapsible section's title row.
struct OvergitSectionHeader: View {
    let section: OvergitModel.Section
    let open: Bool
    let count: Int
    @ObservedObject var theme: ChromeTheme
    let onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 5) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold)).frame(width: 10)
                Image(systemName: section.symbol).font(.system(size: 10)).frame(width: 14)
                Text(section.title)
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.text3)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.text2)
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? theme.rowHover : .clear).padding(.horizontal, 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// What a section says when it has nothing in it.
struct OvergitEmpty: View {
    let text: String
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11))
            .foregroundStyle(theme.text3)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 26)
            .padding(.trailing, 10)
            .padding(.vertical, 4)
    }
}

/// A row with nothing clever about it: a glyph, a name, a note.
struct OvergitPlainRow: View {
    let symbol: String
    let title: String
    let detail: String
    let trailing: String?
    @ObservedObject var theme: ChromeTheme
    var help: String?
    var onTap: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10)).frame(width: 14).foregroundStyle(theme.text3)
            Text(verbatim: title).font(.system(size: 12)).foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
            if !detail.isEmpty {
                Text(verbatim: detail).font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if let trailing {
                Text(verbatim: trailing)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.text3)
                    .lineLimit(1).fixedSize()
            }
        }
        .padding(.leading, 32)
        .padding(.trailing, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? theme.rowHover : .clear).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onTap?() }
        .help(help ?? title)
    }
}
