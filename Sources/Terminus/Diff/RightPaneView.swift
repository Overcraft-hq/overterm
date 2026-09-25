import SwiftUI

/// What the pane on the right shows.
@MainActor
final class RightPane: ObservableObject {
    enum Mode: String {
        case changes, pullRequest
    }

    @Published var mode: Mode = .changes
}

/// The pane on the right: the checkout's changes (uncommitted, or the
/// branch's), or its pull request — a switch at the top chooses.
struct RightPaneView: View {
    @ObservedObject var pane: RightPane
    @ObservedObject var diff: DiffModel
    @ObservedObject var worktrees: WorktreeModel
    let theme: ChromeTheme
    let changes: DiffPanelView
    let pullRequest: PullRequestView

    private var pr: PullRequestSummary? { diff.branch.flatMap { worktrees.pullRequests[$0] } }

    var body: some View {
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
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            switch pane.mode {
            case .changes: changes
            case .pullRequest: pullRequest
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
