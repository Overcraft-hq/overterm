import SwiftUI

/// What the pane on the right shows.
@MainActor
package final class RightPane: ObservableObject {
    package enum Mode: String {
        case changes, pullRequest, usage, commit, runner, graph, compare, object, container, redis, database, manifest, kubernetes, terraformPlan, mcp
    }

    @Published package var mode: Mode = .changes
    /// The notes' graph was asked for: its tab stays from then on.
    @Published package var graphOpened = false
    /// A comparison was asked for in Overgit: its tab stays from then on.
    @Published package var compareOpened = false
    /// A stored file was opened (Database panel): its tab stays from then on.
    @Published package var objectOpened = false
    /// A container was picked in the Docker panel: its tab stays from then on.
    @Published package var containerOpened = false
    /// A Redis key or server was opened (Database panel): its tab stays from then on.
    @Published package var redisOpened = false
    /// A database connection's Server or Users page was opened: its tab stays from then on.
    @Published package var databaseOpened = false
    /// An MCP server was inspected (API panel): its tab stays from then on.
    @Published package var mcpOpened = false
    /// A Kubernetes manifest was diffed with its cluster: its tab stays from then on.
    @Published package var manifestOpened = false
    /// A pod was picked in the Kubernetes panel: its tab stays from then on.
    @Published package var kubernetesOpened = false
    /// A Terraform root was planned (or init run): its tab stays from then on.
    @Published package var terraformPlanOpened = false
}

/// The pane on the right: the checkout's changes (uncommitted, or the
/// branch's), its pull request, what the agents have spent, the commit
/// picked in Overgit, or the API collection run last — a switch at the top
/// chooses. Commit and Runner show only once there is one: a tab that can
/// say nothing is in the way.
package struct RightPaneView: View {
    @ObservedObject package var pane: RightPane
    @ObservedObject package var diff: DiffModel
    @ObservedObject package var worktrees: WorktreeModel
    /// Observed so the Commit tab appears the moment one is picked.
    @ObservedObject package var detail: CommitDetailModel
    /// Observed so the Runner tab appears when a run starts.
    @ObservedObject package var apiRunner: APIRunner
    @ObservedObject package var theme: ChromeTheme
    package let changes: DiffPanelView
    package let pullRequest: PullRequestView
    package let usage: UsageView
    package let commit: CommitDetailView
    package let runner: APIRunnerView
    package let compare: CompareView
    package let object: StorageObjectView
    package let container: DockerSlotView
    package let redis: RedisSlotView
    package let database: DatabaseSlotView
    package let mcp: MCPPageView
    package let graph: NotesGraphView
    package let manifest: KubeManifestDiffView
    package let kubernetes: KubeSlotView
    package let terraformPlan: TerraformPlanPaneView

    private var pr: PullRequestSummary? { diff.branch.flatMap { worktrees.pullRequests[$0] } }

    package var body: some View {
        // Nothing while the pane is collapsed: its views kept updating
        // behind it (a thousand changed files' rows), and collapsing it over
        // a 3000-line diff animated every laid-out row — the window froze
        // for up to a second.
        if diff.panelVisible {
            content
        } else {
            theme.panelGround
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
                        CIGlyph(overall: pr.checks.overall).font(.system(size: ChromeMetrics.text(9)))
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
                        Image(systemName: "point.3.filled.connected.trianglepath.dotted").font(.system(size: ChromeMetrics.text(10)))
                        Text(verbatim: sha).font(.system(size: ChromeMetrics.text(11), design: .monospaced))
                    }
                }
                if apiRunner.hasRun {
                    // An icon, as the commit's sha alone: a fifth word here
                    // truncates the others.
                    tab(.runner, help: "Runner: the API collection run last") {
                        Image(systemName: apiRunner.isRunning ? "play.circle" : "checklist").font(.system(size: ChromeMetrics.text(11)))
                        if apiRunner.failedCount > 0 {
                            Text(verbatim: "\(apiRunner.failedCount)").foregroundStyle(APIResponseView.statusColor(500))
                        }
                    }
                }
                if pane.objectOpened {
                    tab(.object, help: "The file opened in the Database panel") {
                        Image(systemName: "doc").font(.system(size: ChromeMetrics.text(11)))
                    }
                }
                if pane.mcpOpened {
                    tab(.mcp, help: "The MCP server inspected from the API panel") {
                        Image(systemName: "puzzlepiece.extension").font(.system(size: ChromeMetrics.text(11)))
                    }
                }
                if pane.redisOpened {
                    tab(.redis, help: "The Redis key or server opened in the Database panel") {
                        Image(systemName: "bolt.horizontal").font(.system(size: ChromeMetrics.text(11)))
                    }
                }
                if pane.databaseOpened {
                    tab(.database, help: "A database connection's Server or Users page") {
                        Image(systemName: "server.rack").font(.system(size: ChromeMetrics.text(11)))
                    }
                }
                if pane.containerOpened {
                    tab(.container, help: "The container picked in the Docker panel") {
                        Image(systemName: "shippingbox").font(.system(size: ChromeMetrics.text(11)))
                    }
                }
                if pane.kubernetesOpened {
                    tab(.kubernetes, help: "The pod picked in the Kubernetes panel") {
                        Image(systemName: "helm").font(.system(size: ChromeMetrics.text(11)))
                    }
                }
                if pane.terraformPlanOpened {
                    tab(.terraformPlan, help: "The Terraform plan, beside the changes that caused it") {
                        Image(systemName: "square.stack.3d.up").font(.system(size: ChromeMetrics.text(11)))
                    }
                }
                if pane.manifestOpened {
                    tab(.manifest, help: "A Kubernetes manifest against its cluster") {
                        Text(verbatim: "⎈").font(.system(size: ChromeMetrics.text(12)))
                    }
                }
                if pane.compareOpened {
                    tab(.compare, help: "The comparison picked in Overgit") {
                        Image(systemName: "arrow.left.arrow.right.square").font(.system(size: ChromeMetrics.text(11)))
                    }
                }
                if pane.graphOpened {
                    tab(.graph, help: "The notes' graph") {
                        Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: ChromeMetrics.text(11)))
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
            case .redis: redis
            case .database: database
            case .mcp: mcp
            case .manifest: manifest
            case .kubernetes: kubernetes
            case .terraformPlan: terraformPlan
            }
        }
        .background(theme.panelGround)
        // Text fields and buttons follow the terminal theme, not the system
        // appearance: light ones sat white on the dark chrome.
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    private func tab<Label: View>(_ mode: RightPane.Mode, help: String? = nil, @ViewBuilder label: () -> Label) -> some View {
        Button {
            pane.mode = mode
        } label: {
            HStack(spacing: 4) { label() }
                .font(.system(size: ChromeMetrics.text(12), weight: pane.mode == mode ? .semibold : .regular))
                .foregroundStyle(pane.mode == mode ? theme.text : theme.dimText)
                .padding(.horizontal, 8)
                .frame(height: ChromeMetrics.row(24))
                .background(RoundedRectangle(cornerRadius: 6).fill(pane.mode == mode ? theme.selected : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? "")
    }
}
