import SwiftUI

/// What the pane on the right shows.
@MainActor
final class RightPane: ObservableObject {
    enum Mode: String {
        case changes, pullRequest, usage
    }

    @Published var mode: Mode = .changes
}

/// The pane on the right: the checkout's changes (uncommitted, or the
/// branch's), its pull request, or what the agents have spent — a switch
/// at the top chooses.
struct RightPaneView: View {
    @ObservedObject var pane: RightPane
    @ObservedObject var diff: DiffModel
    @ObservedObject var worktrees: WorktreeModel
    @ObservedObject var theme: ChromeTheme
    let changes: DiffPanelView
    let pullRequest: PullRequestView
    let usage: UsageView

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
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            switch pane.mode {
            case .changes: changes
            case .pullRequest: pullRequest
            case .usage: usage
            }
        }
        .background(theme.strip)
        // Text fields and buttons follow the terminal theme, not the system
        // appearance: light ones sat white on the dark chrome.
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    private func tab<Label: View>(_ mode: RightPane.Mode, @ViewBuilder label: () -> Label) -> some View {
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
    }
}
