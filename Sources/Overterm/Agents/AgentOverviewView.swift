import SwiftUI

/// ⇧⌘A: every tab as a card over the window — agents waiting for you
/// first. A click goes to the tab.
struct AgentOverviewView: View {
    @ObservedObject var model: AgentOverviewModel
    @ObservedObject var worktrees: WorktreeModel
    @ObservedObject var theme: ChromeTheme
    let onChoose: (Tab.ID) -> Void
    /// Show in Activity (6.12): the page at the card's agent.
    var onActivity: ((AgentOverviewModel.Card) -> Void)? = nil
    /// A server's pill: its URL opened as a link in that tab is (6.12).
    var onOpen: ((AgentOverviewModel.Card, URL) -> Void)? = nil
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).onTapGesture(perform: onDismiss)
            VStack(alignment: .leading, spacing: 12) {
                header
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                        ForEach(model.cards) { card in
                            AgentCard(
                                card: card, pullRequest: card.branch.flatMap { worktrees.pullRequests[$0] }, theme: theme,
                                onActivity: Settings.shared.activityEnabled ? onActivity.map { act in { act(card) } } : nil,
                                onOpen: onOpen.map { open in { open(card, $0) } }
                            )
                            .onTapGesture { onChoose(card.id) }
                            .contextMenu {
                                Button("Go to Tab") { onChoose(card.id) }
                                if Settings.shared.activityEnabled, let onActivity { Button("Show in Activity") { onActivity(card) } }
                            }
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
            Text("Agents").font(.system(size: ChromeMetrics.text(15), weight: .semibold)).foregroundStyle(theme.text)
            Text(verbatim: summary).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.dimText)
            Spacer()
            Text("Esc to close").font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText)
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
    var onActivity: (() -> Void)?
    var onOpen: ((URL) -> Void)?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                status.frame(width: 18)
                if let color = card.color { Circle().fill(color.color).frame(width: 7, height: 7) }
                Text(verbatim: card.title).font(.system(size: ChromeMetrics.text(13), weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                Spacer(minLength: 4)
                if card.panes > 1 {
                    Label("\(card.panes)", systemImage: "rectangle.split.2x1").labelStyle(.titleAndIcon).font(.system(size: ChromeMetrics.text(10)))
                        .foregroundStyle(theme.dimText)
                }
                if let agent = card.agent {
                    Image(systemName: agent.symbol).font(.system(size: ChromeMetrics.text(11)))
                        .foregroundStyle(card.agentRunning ? theme.text : theme.dimText)
                        .help(card.agentRunning ? "\(agent.name) is running" : "\(agent.name) tab — not running")
                }
                if let onActivity {
                    Button(action: onActivity) {
                        Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: ChromeMetrics.text(11)))
                    }
                    .buttonStyle(.borderless).foregroundStyle(theme.dimText)
                    .help(card.agentProcess == nil ? "Show the tab in Activity (⌥⌘A)" : "Show its agent in Activity (⌥⌘A): its processes, CPU and ports")
                    .accessibilityIdentifier("overview.showInActivity")
                }
            }
            HStack(spacing: 5) {
                Image(systemName: "folder").font(.system(size: ChromeMetrics.text(10)))
                Text(verbatim: card.directory.map { ($0 as NSString).lastPathComponent } ?? "—").lineLimit(1)
                if let branch = card.branch {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: ChromeMetrics.text(10)))
                    Text(verbatim: branch).lineLimit(1).truncationMode(.middle)
                }
                if let pullRequest {
                    Text(verbatim: "#\(pullRequest.number)").foregroundStyle(StatePill.color(pullRequest.state))
                    CIGlyph(overall: pullRequest.checks.overall).font(.system(size: ChromeMetrics.text(9), weight: .bold))
                }
            }
            .font(.system(size: ChromeMetrics.text(11)))
            .foregroundStyle(theme.dimText)
            .help(card.directory ?? "")

            if let note = card.activity.note, card.activity.mark == .waiting || card.activity.mark == .failed {
                Text(verbatim: note).font(.system(size: ChromeMetrics.text(12), weight: .medium))
                    .foregroundStyle(card.activity.mark == .failed ? TabStatusStyle.failed : TabStatusStyle.signal).lineLimit(2)
            }
            if let claude = card.claude {
                if let title = claude.title {
                    Text(verbatim: title).font(.system(size: ChromeMetrics.text(12), weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                }
                if let prompt = claude.lastPrompt {
                    Text(verbatim: "You: \(Self.oneLine(prompt))").font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText).lineLimit(2)
                }
                if let tool = claude.currentTool {
                    Label(Self.oneLine(tool), systemImage: "play.fill").font(.system(size: ChromeMetrics.text(11), design: .monospaced))
                        .foregroundStyle(card.activity.isWorking ? TabStatusStyle.signal : theme.dimText).lineLimit(1)
                } else if let reply = claude.lastReply {
                    Text(verbatim: Self.oneLine(reply)).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text).lineLimit(3)
                }
                if let updated = claude.updated {
                    Text(updated, format: .relative(presentation: .named)).font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.dimText)
                }
            } else if card.agent == nil {
                Text(card.activity.isWorking ? "A command is running" : "Shell").font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText)
            }
            if let usage = card.usage { usageRow(usage) }
            if card.left > 0 {
                // 6.9: what its agent's ended runs left running.
                Label {
                    Text(verbatim: "left \(card.left) behind")
                } icon: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .font(.system(size: ChromeMetrics.text(11)))
                .foregroundStyle(theme.dimText)
                .help("Processes its agent's runs left running when it finished: Activity ▸ Left Behind")
                .accessibilityIdentifier("overview.left")
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

    /// Its agent's CPU and footprint, it and what it started, and its
    /// servers as pills with Open (6.12) — from the census.
    private func usageRow(_ usage: AgentOverviewModel.AgentUsage) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu").font(.system(size: ChromeMetrics.text(10)))
            Text(verbatim: "\(TabInfoView.cpu(usage.cpu)) · \(TabInfoView.memory(usage.footprint))")
                .help("Its agent and every process under it: CPU (100% is one core) and memory, as Activity Monitor counts it")
                .accessibilityIdentifier("overview.usage")
            ForEach(usage.servers.prefix(4)) { server in
                Button {
                    if let url = server.url { onOpen?(url) }
                } label: {
                    Text(verbatim: ":\(server.port)").font(.system(size: ChromeMetrics.text(10.5), weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(TabStatusStyle.done.opacity(0.16)))
                }
                .buttonStyle(.plain)
                .disabled(server.url == nil || onOpen == nil)
                .help(server.url.map { "Open \($0.absoluteString)" } ?? "\(server.process) on :\(server.port)")
                .accessibilityIdentifier("overview.server.\(server.port)")
            }
            if usage.servers.count > 4 {
                Text(verbatim: "+\(usage.servers.count - 4)")
            }
        }
        .font(.system(size: ChromeMetrics.text(11)))
        .foregroundStyle(theme.dimText)
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
