import SwiftUI

/// What the pane on the right shows.
@MainActor
final class RightPane: ObservableObject {
    enum Mode: String {
        case changes, pullRequest, usage, commit, runner, graph, compare, object, container
    }

    @Published var mode: Mode = .changes
    /// The notes' graph was asked for: its tab stays from then on.
    @Published var graphOpened = false
    /// A comparison was asked for in Overgit: its tab stays from then on.
    @Published var compareOpened = false
    /// A stored file was opened (Database panel): its tab stays from then on.
    @Published var objectOpened = false
    /// A container was picked in the Docker panel: its tab stays from then on.
    @Published var containerOpened = false
}

/// The pane on the right: the checkout's changes (uncommitted, or the
/// branch's), its pull request, what the agents have spent, the commit
/// picked in Overgit, or the API collection run last — a switch at the top
/// chooses. Commit and Runner show only once there is one: a tab that can
/// say nothing is in the way.
struct RightPaneView: View {
    @ObservedObject var pane: RightPane
    @ObservedObject var diff: DiffModel
    @ObservedObject var worktrees: WorktreeModel
    /// Observed so the Commit tab appears the moment one is picked.
    @ObservedObject var detail: CommitDetailModel
    /// Observed so the Runner tab appears when a run starts.
    @ObservedObject var apiRunner: APIRunner
    @ObservedObject var theme: ChromeTheme
    let changes: DiffPanelView
    let pullRequest: PullRequestView
    let usage: UsageView
    let commit: CommitDetailView
    let runner: APIRunnerView
    let compare: CompareView
    let object: StorageObjectView
    let container: DockerSlotView
    let graph: NotesGraphView

    private var pr: PullRequestSummary? { diff.branch.flatMap { worktrees.pullRequests[$0] } }

    var body: some View {
        // Nothing while the pane is collapsed: its views kept updating
        // behind it (a thousand changed files' rows), and collapsing it over
        // a 3000-line diff animated every laid-out row — the window froze
        // for up to a second.
        if diff.panelVisible {
            content
        } else {
            theme.strip
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                tab(.changes) {
                    Text("Changes")
                    if !diff.shownFiles.isEmpty { Text(verbatim: "\(diff.shownFiles.count)").foregroundStyle(theme.dimText) }
                }
                tab(.pullRequest) {
                    Text("Pull Request")
                    if let pr {
                        Text(verbatim: "#\(pr.number)").foregroundStyle(StatePill.color(pr.state))
                        CIGlyph(overall: pr.checks.overall).font(.system(size: 9))
                    }
                }
                tab(.usage) {
                    Text("Usage")
                    if let meter = usage.model.chipMeter()?.meter {
                        Text(verbatim: meter.reading()).foregroundStyle(theme.dimText)
                    }
                }
                if let sha = commit.model.shortSHA {
                    // The sha alone: a fourth word here and the first three
                    // tabs truncate to "Chang…" and "Pull Req…".
                    tab(.commit, help: "The commit picked in Overgit") {
                        Image(systemName: "point.3.filled.connected.trianglepath.dotted").font(.system(size: 10))
                        Text(verbatim: sha).font(.system(size: 11, design: .monospaced))
                    }
                }
                if apiRunner.hasRun {
                    // An icon, as the commit's sha alone: a fifth word here
                    // truncates the others.
                    tab(.runner, help: "Runner: the API collection run last") {
                        Image(systemName: apiRunner.isRunning ? "play.circle" : "checklist").font(.system(size: 11))
                        if apiRunner.failedCount > 0 {
                            Text(verbatim: "\(apiRunner.failedCount)").foregroundStyle(APIResponseView.statusColor(500))
                        }
                    }
                }
                if pane.objectOpened {
                    tab(.object, help: "The file opened in the Database panel") {
                        Image(systemName: "doc").font(.system(size: 11))
                    }
                }
                if pane.containerOpened {
                    tab(.container, help: "The container picked in the Docker panel") {
                        Image(systemName: "shippingbox").font(.system(size: 11))
                    }
                }
                if pane.compareOpened {
                    tab(.compare, help: "The comparison picked in Overgit") {
                        Image(systemName: "arrow.left.arrow.right.square").font(.system(size: 11))
                    }
                }
                if pane.graphOpened {
                    tab(.graph, help: "The notes' graph") {
                        Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 11))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            switch pane.mode {
            case .changes: changes
            case .pullRequest: pullRequest
            case .usage: usage
            case .commit: commit
            case .runner: runner
            case .graph: graph
            case .compare: compare
            case .object: object
            case .container: container
            }
        }
        .background(theme.strip)
        // Text fields and buttons follow the terminal theme, not the system
        // appearance: light ones sat white on the dark chrome.
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    private func tab<Label: View>(_ mode: RightPane.Mode, help: String? = nil, @ViewBuilder label: () -> Label) -> some View {
        Button {
            pane.mode = mode
        } label: {
            HStack(spacing: 4) { label() }
                .font(.system(size: 12, weight: pane.mode == mode ? .semibold : .regular))
                .foregroundStyle(pane.mode == mode ? theme.text : theme.dimText)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(pane.mode == mode ? theme.selected : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? "")
    }
}
