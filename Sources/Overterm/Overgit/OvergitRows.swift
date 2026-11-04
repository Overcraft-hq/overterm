import AppKit
import SwiftUI

/// Where you are, at the top of the panel: the branch, how it stands
/// against its upstream, what is uncommitted, and the pull request. The
/// one row a person reads before anything else — "where am I, and is
/// anything broken".
struct OvergitOverview: View {
    let branch: String?
    let ref: BranchRef?
    let badge: DiffModel.Badge?
    let pullRequest: PullRequestSummary?
    /// Against its upstream, read whatever sections are open.
    var tracking = BranchTracking()
    var inProgress: GitInProgress?
    /// A command running ("Pulling…").
    var running: String?
    @ObservedObject var theme: ChromeTheme
    let onChanges: () -> Void
    let onPullRequest: () -> Void
    var onCommand: (OvergitCommand) -> Void = { _ in }
    /// Opens the Changes section, where the message and Commit are.
    var onCommit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text2)
                Text(verbatim: branch ?? "detached")
                    .font(.system(size: ChromeMetrics.text(13), weight: .semibold)).foregroundStyle(theme.text)
                    .lineLimit(1).truncationMode(.middle)
                if tracking.ahead > 0 { track("arrow.up", tracking.ahead) }
                if tracking.behind > 0 { track("arrow.down", tracking.behind) }
                Spacer(minLength: 0)
            }
            if let inProgress { banner(inProgress) }
            sync
            HStack(spacing: 8) {
                Button(action: onChanges) {
                    HStack(spacing: 4) {
                        if let counts {
                            Text(verbatim: "+\(counts.added)").foregroundStyle(DiffColors.added)
                            Text(verbatim: "−\(counts.removed)").foregroundStyle(DiffColors.removed)
                        } else {
                            Text("No local changes").foregroundStyle(theme.text3)
                        }
                    }
                    .font(.system(size: ChromeMetrics.text(11), design: .monospaced))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Changes (⌥⌘D)")
                if let pullRequest {
                    Button(action: onPullRequest) {
                        HStack(spacing: 4) {
                            Text(verbatim: "#\(pullRequest.number)")
                                .font(.system(size: ChromeMetrics.text(11), design: .monospaced))
                                .foregroundStyle(StatePill.color(pullRequest.state))
                            CIGlyph(overall: pullRequest.checks.overall).font(.system(size: ChromeMetrics.text(9)))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(pullRequest.title)
                }
                Spacer(minLength: 0)
                if let upstream = ref?.upstream {
                    Text(verbatim: upstream).font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3)
                        .lineLimit(1).truncationMode(.head)
                } else if ref?.isGone == true {
                    Text("upstream gone").font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.orangeText)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Pull, Push, and the rest of what a checkout's branch does.
    private var sync: some View {
        HStack(spacing: 6) {
            if branch != nil, tracking.upstream != nil {
                syncButton("Pull", symbol: "arrow.down", count: tracking.behind, help: "git pull from \(tracking.upstream ?? "")") {
                    onCommand(.pull(rebase: false))
                }
                .accessibilityIdentifier("overgitPull")
            }
            if branch != nil {
                let publish = tracking.upstream == nil
                syncButton(
                    publish ? "Publish" : "Push", symbol: "arrow.up", count: tracking.ahead,
                    help: publish ? "Push the branch to origin, tracking it" : "git push to \(tracking.upstream ?? "")"
                ) { onCommand(.push) }
                .accessibilityIdentifier("overgitPushBranch")
            }
            Menu {
                Button("Commit…", action: onCommit)
                Button("Fetch All") { onCommand(.fetch) }
                if tracking.upstream != nil { Button("Pull with Rebase") { onCommand(.pull(rebase: true)) } }
                Divider()
                Button("New Branch…") { onCommand(.newBranch(from: nil)) }
                Button("Stash Changes…") { onCommand(.stash) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: ChromeMetrics.text(11)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More: commit, fetch, a new branch, stash")
            if let running {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
                Text(verbatim: running).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .disabled(running != nil)
    }

    private func syncButton(_ title: String, symbol: String, count: Int, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: ChromeMetrics.text(9), weight: .semibold))
                Text(title).font(.system(size: ChromeMetrics.text(11), weight: .medium))
                if count > 0 { Text(verbatim: "\(count)").font(.system(size: ChromeMetrics.text(10), design: .monospaced)) }
            }
            .foregroundStyle(count > 0 ? theme.text : theme.text2)
            .padding(.horizontal, 7)
            .frame(height: ChromeMetrics.row(22))
            .background(RoundedRectangle(cornerRadius: 5).fill(theme.iconBg))
            .contentShape(Rectangle())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// A merge or rebase stopped half way: what it is, and the two ways out.
    private func banner(_ state: GitInProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: ChromeMetrics.text(10)))
                Text(verbatim: "\(state.title) stopped").font(.system(size: ChromeMetrics.text(11), weight: .semibold))
            }
            .foregroundStyle(theme.orangeText)
            Text("Resolve the conflicts in Changes and stage them, then continue.")
                .font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                syncButton("Continue", symbol: "play.fill", count: 0, help: "git \(state.command) --continue") {
                    onCommand(.continueOperation)
                }
                .accessibilityIdentifier("overgitContinue")
                syncButton("Abort", symbol: "xmark", count: 0, help: "git \(state.command) --abort") { onCommand(.abortOperation) }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.attnBg))
    }

    private var counts: (added: Int, removed: Int)? {
        switch badge {
        case .uncommitted(let added, let removed): (added, removed)
        case .branch(let added, let removed): (added, removed)
        default: nil
        }
    }

    private func track(_ symbol: String, _ count: Int) -> some View {
        HStack(spacing: 1) {
            Image(systemName: symbol).font(.system(size: ChromeMetrics.text(8), weight: .semibold))
            Text(verbatim: "\(count)").font(.system(size: ChromeMetrics.text(10), design: .monospaced))
        }
        .foregroundStyle(theme.text2)
    }
}

/// One commit: its lane in the graph, its subject, and who and when.
struct CommitRowView<Extra: View>: View {
    let commit: Commit
    let row: GraphRow?
    let lanes: Int
    let isSelected: Bool
    @ObservedObject var theme: ChromeTheme
    let onOpen: () -> Void
    /// More of the menu: Compare, where the row is Overgit's.
    @ViewBuilder var menu: Extra
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if let row {
                GraphGutter(row: row, lanes: lanes, height: OvergitView.commitRowHeight)
            } else {
                Color.clear.frame(width: GraphGutter.width(lanes: lanes))
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    // One pill and a count, not every ref: the sidebar can
                    // be 180 pt and the subject is what the row is for.
                    if let ref = Self.leadingRef(commit.refs) {
                        RefPill(ref: ref, theme: theme)
                        if commit.refs.count > 1 {
                            Text(verbatim: "+\(commit.refs.count - 1)")
                                .font(.system(size: ChromeMetrics.text(9))).foregroundStyle(theme.text3).fixedSize()
                        }
                    }
                    Text(verbatim: commit.subject)
                        .font(.system(size: ChromeMetrics.text(12)))
                        .foregroundStyle(theme.text)
                        .lineLimit(1).truncationMode(.tail)
                }
                HStack(spacing: 5) {
                    Text(verbatim: commit.shortSHA)
                        .font(.system(size: ChromeMetrics.text(10), design: .monospaced)).foregroundStyle(theme.text3).fixedSize()
                    Text(verbatim: commit.relative).font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3).fixedSize()
                    Text(verbatim: commit.author).font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, 8)
        .frame(height: OvergitView.commitRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? theme.rowSel : (hovering ? theme.rowHover : .clear))
                .padding(.trailing, 4)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .help(CommitRowRefs.help(commit))
        .contextMenu {
            Button("Show This Commit", action: onOpen)
            Button("Copy SHA") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.sha, forType: .string)
            }
            Button("Copy Subject") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.subject, forType: .string)
            }
            menu
        }
    }

    /// The one ref worth the room: where HEAD is, else a local branch,
    /// else a tag, else whatever there is.
    static func leadingRef(_ refs: [CommitRef]) -> CommitRef? { CommitRowRefs.leading(refs) }
}

/// Which ref a commit row shows.
enum CommitRowRefs {
    static func leading(_ refs: [CommitRef]) -> CommitRef? {
        refs.first { $0.isHead } ?? refs.first { $0.kind == .branch } ?? refs.first { $0.kind == .tag } ?? refs.first
    }

    static func help(_ commit: Commit) -> String {
        var lines = [commit.subject, "\(commit.shortSHA) · \(commit.author) · \(commit.relative)"]
        if !commit.refs.isEmpty { lines.append(commit.refs.map(\.name).joined(separator: ", ")) }
        if !commit.body.isEmpty { lines.append(commit.body) }
        return lines.joined(separator: "\n")
    }
}

/// A branch, a tag or HEAD riding a commit row.
struct RefPill: View {
    let ref: CommitRef
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        Text(verbatim: ref.name)
            .font(.system(size: ChromeMetrics.text(9), weight: ref.isHead ? .semibold : .regular))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
            .fixedSize()
    }

    private var color: Color {
        switch ref.kind {
        case .head: theme.greenText
        case .branch: ref.isHead ? theme.greenText : theme.accentText
        case .remote: theme.text3
        case .tag: theme.orangeText
        }
    }
}

/// A branch, or the folder a `/` makes.
struct BranchRowView: View {
    @ObservedObject var model: OvergitModel
    let node: BranchNode
    let isCurrent: Bool
    let isOpen: Bool
    @ObservedObject var theme: ChromeTheme
    let onToggle: () -> Void
    let actions: OvergitActions
    /// The checked-out branch: what Merge goes into and Rebase moves.
    var current: String?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                .font(.system(size: ChromeMetrics.text(8), weight: .semibold)).frame(width: 10)
                .opacity(node.isFolder ? 1 : 0)
                .foregroundStyle(theme.text3)
            Image(systemName: glyph).font(.system(size: ChromeMetrics.text(10))).frame(width: 14).foregroundStyle(theme.text3)
            Text(verbatim: node.name)
                .font(.system(size: ChromeMetrics.text(12), weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? theme.text : theme.text2)
                .lineLimit(1).truncationMode(.middle)
            if let branch = node.branch {
                if branch.ahead > 0 { count("arrow.up", branch.ahead) }
                if branch.behind > 0 { count("arrow.down", branch.behind) }
                if branch.isGone {
                    Image(systemName: "questionmark.circle").font(.system(size: ChromeMetrics.text(9))).foregroundStyle(theme.orangeText)
                        .help("Its upstream is gone")
                }
            } else {
                Text(verbatim: "\(node.count)").font(.system(size: ChromeMetrics.text(10), design: .monospaced)).foregroundStyle(theme.text3)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 20 + CGFloat(node.depth) * 12)
        .padding(.trailing, 10)
        .frame(height: ChromeMetrics.row(26))
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? theme.rowHover : .clear).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if node.isFolder { onToggle() } }
        .help(node.branch.map { "\($0.name)\n\($0.sha) · \($0.subject)" } ?? node.id)
        .contextMenu {
            if let branch = node.branch {
                if !isCurrent { Button("Check Out") { actions.checkOut(branch) } }
                Button("New Branch From Here…") { actions.git(.newBranch(from: branch.name)) }
                Button("New Worktree Here…") { actions.newWorktree(branch) }
                if let current, !isCurrent, current != branch.name {
                    Divider()
                    Button("Merge into \(current)") { actions.git(.merge(branch.name)) }
                    Button("Rebase \(current) onto This") { actions.git(.rebase(onto: branch.name)) }
                }
                Divider()
                if isCurrent {
                    if branch.upstream != nil { Button("Pull") { actions.git(.pull(rebase: false)) } }
                    Button(branch.upstream == nil ? "Publish" : "Push") { actions.git(.push) }
                } else if !branch.isRemote {
                    Button(branch.upstream == nil ? "Publish" : "Push") { actions.git(.pushBranch(branch)) }
                }
                if !branch.isRemote { Button("Rename…") { actions.git(.renameBranch(branch)) } }
                if !isCurrent { Button("Delete…", role: .destructive) { actions.git(.deleteBranch(branch)) } }
                Divider()
                Button("Copy Name") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(branch.name, forType: .string)
                }
                Button("Review Branch") { actions.reviewBranch(branch.name) }
                CompareMenuItems(ref: branch.name, model: model, actions: actions)
            }
        }
    }

    private var glyph: String {
        guard let branch = node.branch else { return isOpen ? "folder" : "folder.fill" }
        return branch.isRemote ? "cloud" : (isCurrent ? "checkmark.circle" : "arrow.triangle.branch")
    }

    private func count(_ symbol: String, _ number: Int) -> some View {
        HStack(spacing: 1) {
            Image(systemName: symbol).font(.system(size: ChromeMetrics.text(7), weight: .semibold))
            Text(verbatim: "\(number)").font(.system(size: ChromeMetrics.text(9), design: .monospaced))
        }
        .foregroundStyle(theme.text3)
    }
}

/// An open pull request, as the list shows it.
struct PullRequestRowView: View {
    let pullRequest: PullRequestSummary
    let isCurrent: Bool
    @ObservedObject var theme: ChromeTheme
    let onOpen: () -> Void
    let onOpenExternally: () -> Void
    var onReview: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: "#\(pullRequest.number)")
                .font(.system(size: ChromeMetrics.text(10), design: .monospaced))
                .foregroundStyle(StatePill.color(pullRequest.state))
                .frame(width: 38, alignment: .trailing)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: pullRequest.title)
                    .font(.system(size: ChromeMetrics.text(12), weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? theme.text : theme.text2)
                    .lineLimit(1).truncationMode(.tail)
                Text(verbatim: pullRequest.branch)
                    .font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            CIGlyph(overall: pullRequest.checks.overall).font(.system(size: ChromeMetrics.text(9)))
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .frame(height: ChromeMetrics.row(34))
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? theme.rowHover : .clear).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .help("#\(pullRequest.number) \(pullRequest.title)")
        .contextMenu {
            Button("Review Changes", action: onReview)
            Button("Open on GitHub", action: onOpenExternally)
        }
    }
}

struct StashRowView: View {
    let stash: Stash
    @ObservedObject var theme: ChromeTheme
    let actions: OvergitActions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full").font(.system(size: ChromeMetrics.text(10))).frame(width: 14).foregroundStyle(theme.text3)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: stash.subject)
                    .font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text2).lineLimit(1).truncationMode(.tail)
                Text(verbatim: "\(stash.ref) · \(stash.relative)")
                    .font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .frame(height: ChromeMetrics.row(34))
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? theme.rowHover : .clear).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(stash.subject)
        .contextMenu {
            Button("Pop") { actions.git(.popStash(stash)) }
            Button("Apply") { actions.applyStash(stash) }
            Button("Drop…", role: .destructive) { actions.dropStash(stash) }
        }
    }
}

extension CommitRowView where Extra == EmptyView {
    init(commit: Commit, row: GraphRow?, lanes: Int, isSelected: Bool, theme: ChromeTheme, onOpen: @escaping () -> Void) {
        self.init(commit: commit, row: row, lanes: lanes, isSelected: isSelected, theme: theme, onOpen: onOpen) { EmptyView() }
    }
}

/// What a commit's menu runs on the checked-out branch: a branch or a tag
/// on it, it picked onto the branch, it undone, the branch reset to it.
struct CommitGitMenuItems: View {
    let commit: Commit
    let current: String?
    let actions: OvergitActions

    var body: some View {
        Divider()
        Button("New Branch Here…") { actions.git(.newBranch(from: commit.sha)) }
        Button("New Tag Here…") { actions.git(.tag(at: commit.sha)) }
        Button("Check Out (Detached)") { actions.git(.checkOutCommit(commit.sha)) }
        Divider()
        Button("Cherry-Pick onto \(current ?? "HEAD")") { actions.git(.cherryPick(commit)) }
        Button("Revert") { actions.git(.revert(commit)) }
        Menu("Reset \(current ?? "HEAD") to Here") {
            Button("Soft — keep changes staged") { actions.git(.reset(commit, .soft)) }
            Button("Mixed — keep changes unstaged") { actions.git(.reset(commit, .mixed)) }
            Button("Hard — discard changes…", role: .destructive) { actions.git(.reset(commit, .hard)) }
        }
    }
}
