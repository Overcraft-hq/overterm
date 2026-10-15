import SwiftUI

/// ⇧⌘A: every tab as a card over the window — agents waiting for you
/// first. A click goes to the tab.
struct AgentOverviewView: View {
    @ObservedObject var model: AgentOverviewModel
    @ObservedObject var worktrees: WorktreeModel
    @ObservedObject var theme: ChromeTheme
    let onChoose: (Tab.ID) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).onTapGesture(perform: onDismiss)
            VStack(alignment: .leading, spacing: 12) {
                header
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                        ForEach(model.cards) { card in
                            AgentCard(card: card, pullRequest: card.branch.flatMap { worktrees.pullRequests[$0] }, theme: theme)
                                .onTapGesture { onChoose(card.id) }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 1100, maxHeight: .infinity, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.strip))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.dimText.opacity(0.25)))
            .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
            .padding(28)
        }
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Agents").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
            Text(verbatim: summary).font(.system(size: 12)).foregroundStyle(theme.dimText)
            Spacer()
            Text("Esc to close").font(.system(size: 11)).foregroundStyle(theme.dimText)
        }
    }

    private var summary: String {
        let cards = model.cards
        var parts: [String] = []
        let waiting = cards.filter { $0.activity.mark == .waiting }.count
        let working = cards.filter { $0.activity.isWorking }.count
        let failed = cards.filter { $0.activity.mark == .failed }.count
        if waiting > 0 { parts.append("\(waiting) waiting for you") }
        if working > 0 { parts.append("\(working) working") }
        if failed > 0 { parts.append("\(failed) failed") }
        let agents = cards.filter { $0.agent != nil }.count
        parts.append(agents == 1 ? "1 agent" : "\(agents) agents")
        parts.append(cards.count == 1 ? "1 tab" : "\(cards.count) tabs")
        return parts.joined(separator: " · ")
    }
}

private struct AgentCard: View {
    let card: AgentOverviewModel.Card
    let pullRequest: PullRequestSummary?
    @ObservedObject var theme: ChromeTheme
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                status.frame(width: 18)
                if let color = card.color { Circle().fill(color.color).frame(width: 7, height: 7) }
                Text(verbatim: card.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                Spacer(minLength: 4)
                if card.panes > 1 {
                    Label("\(card.panes)", systemImage: "rectangle.split.2x1").labelStyle(.titleAndIcon).font(.system(size: 10))
                        .foregroundStyle(theme.dimText)
                }
                if let agent = card.agent {
                    Image(systemName: agent.symbol).font(.system(size: 11))
                        .foregroundStyle(card.agentRunning ? theme.text : theme.dimText)
                        .help(card.agentRunning ? "\(agent.name) is running" : "\(agent.name) tab — not running")
                }
            }
            HStack(spacing: 5) {
                Image(systemName: "folder").font(.system(size: 10))
                Text(verbatim: card.directory.map { ($0 as NSString).lastPathComponent } ?? "—").lineLimit(1)
                if let branch = card.branch {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                    Text(verbatim: branch).lineLimit(1).truncationMode(.middle)
                }
                if let pullRequest {
                    Text(verbatim: "#\(pullRequest.number)").foregroundStyle(StatePill.color(pullRequest.state))
                    CIGlyph(overall: pullRequest.checks.overall).font(.system(size: 9, weight: .bold))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.dimText)
            .help(card.directory ?? "")

            if let note = card.activity.note, card.activity.mark == .waiting || card.activity.mark == .failed {
                Text(verbatim: note).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(card.activity.mark == .failed ? TabStatusStyle.failed : TabStatusStyle.signal).lineLimit(2)
            }
            if let claude = card.claude {
                if let title = claude.title {
                    Text(verbatim: title).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                }
                if let prompt = claude.lastPrompt {
                    Text(verbatim: "You: \(Self.oneLine(prompt))").font(.system(size: 11)).foregroundStyle(theme.dimText).lineLimit(2)
                }
                if let tool = claude.currentTool {
                    Label(Self.oneLine(tool), systemImage: "play.fill").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(card.activity.isWorking ? TabStatusStyle.signal : theme.dimText).lineLimit(1)
                } else if let reply = claude.lastReply {
                    Text(verbatim: Self.oneLine(reply)).font(.system(size: 12)).foregroundStyle(theme.text).lineLimit(3)
                }
                if let updated = claude.updated {
                    Text(updated, format: .relative(presentation: .named)).font(.system(size: 10)).foregroundStyle(theme.dimText)
                }
            } else if card.agent == nil {
                Text(card.activity.isWorking ? "A command is running" : "Shell").font(.system(size: 11)).foregroundStyle(theme.dimText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? theme.selected : theme.selected.opacity(0.55)))
        .overlay(
            RoundedRectangle(cornerRadius: 10).strokeBorder(
                card.activity.mark == .waiting ? TabStatusStyle.signal.opacity(0.8) : theme.dimText.opacity(0.18),
                lineWidth: card.activity.mark == .waiting ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var status: some View {
        if card.activity.mark == .waiting {
            WaitingDot()
        } else if card.activity.isWorking {
            WorkingGlyph(symbol: card.agent?.symbol ?? "terminal", size: 12)
        } else if card.activity.mark == .failed || card.activity.mark == .done {
            ResultMark(failed: card.activity.mark == .failed, size: 12)
        } else {
            Circle().fill(theme.dimText.opacity(0.5)).frame(width: 6, height: 6)
        }
    }

    /// Markdown and line breaks flattened: a card shows a gist.
    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
    }
}

/// The overview's host: takes the keyboard while shown so Esc closes it
/// (there is no text field to catch it).
final class AgentOverviewHostingView<Content: View>: NSHostingView<Content> {
    var onEscape: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
