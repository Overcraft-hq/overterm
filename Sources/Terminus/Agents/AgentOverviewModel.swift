import Foundation

/// Every tab at a glance, agents first: whether it works, waits for you,
/// finished or failed; where (checkout, branch, its PR); and, for Claude,
/// what the session is about, what you last asked, and what it last said
/// or is doing right now. Refreshed every 2 s while shown.
@MainActor
final class AgentOverviewModel: ObservableObject {
    struct Card: Identifiable, Equatable {
        let id: Tab.ID
        let title: String
        let color: TabColor?
        /// The agent the tab was opened for, or one found running in it.
        let agent: Agent?
        /// An agent process is alive in one of its panes.
        let agentRunning: Bool
        let activity: TabActivity
        /// Where the agent works, else the focused pane's directory.
        let directory: String?
        let branch: String?
        let claude: ClaudeActivity?
        let panes: Int
    }

    @Published private(set) var cards: [Card] = []

    struct Snapshot: Sendable {
        let id: Tab.ID
        let title: String
        let color: TabColor?
        let agent: Agent?
        let activity: TabActivity
        let directory: String?
        let roots: [(pid_t?, String)]
        let panes: Int
    }

    func refresh(_ tabs: [Tab], inspector: ProcessInspector) async {
        let snapshots = tabs.map { tab in
            Snapshot(
                id: tab.id, title: tab.title, color: tab.color, agent: tab.agent, activity: tab.activity,
                directory: tab.agentDirectory ?? tab.workingDirectory,
                roots: tab.terminals.map { (SurfaceProcesses.shared.loginPID(of: $0), $0.processTag) }, panes: tab.terminals.count)
        }
        // Process scans and transcript tails: off the main thread.
        let cards = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: snapshots.map { Self.card(for: $0, inspector: inspector) })
            }
        }
        self.cards = Self.ordered(cards)
    }

    nonisolated private static func card(for snapshot: Snapshot, inspector: ProcessInspector) -> Card {
        let process = TerminalWindowController.firstAgent(in: snapshot.roots) { inspector.tree(root: $0, tag: $1) }
        let running = process.flatMap(Self.agent(of:))
        let agent = running ?? snapshot.agent
        let directory = process?.workingDirectory ?? snapshot.directory
        let claude =
            agent == .claude
            ? directory.flatMap(ClaudeUsageReader.latestSession(for:)).flatMap { ClaudeActivity.read($0) } : nil
        return Card(
            id: snapshot.id, title: snapshot.title, color: snapshot.color, agent: agent, agentRunning: running != nil,
            activity: snapshot.activity, directory: directory, branch: claude?.branch ?? directory.flatMap(Self.branch(in:)),
            claude: claude, panes: snapshot.panes)
    }

    nonisolated static func agent(of node: ProcessNode) -> Agent? {
        let base = node.command.split(separator: " ").first.map { (String($0) as NSString).lastPathComponent }
        for agent in Agent.allCases where node.name == agent.rawValue || base == agent.rawValue { return agent }
        return nil
    }

    /// The checked-out branch, read from .git/HEAD (no git process per card
    /// every 2 s). A linked worktree's .git is a file pointing at its gitdir.
    nonisolated static func branch(in directory: String) -> String? {
        var url = URL(fileURLWithPath: directory)
        while url.path != "/" {
            let git = url.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                var gitDir = git
                if !isDirectory.boolValue, let pointer = try? String(contentsOf: git, encoding: .utf8),
                    let path = pointer.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespacesAndNewlines)
                {
                    gitDir = URL(fileURLWithPath: path, relativeTo: url)
                }
                let head = (try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)) ?? ""
                let prefix = "ref: refs/heads/"
                return head.hasPrefix(prefix) ? head.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines) : nil
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// Waiting for you first, then failed, working, done; tabs without an
    /// agent last. The tab order otherwise.
    nonisolated static func ordered(_ cards: [Card]) -> [Card] {
        func rank(_ card: Card) -> Int {
            if card.activity.mark == .waiting { return 0 }
            if card.activity.mark == .failed { return 1 }
            if card.activity.isWorking { return 2 }
            if card.activity.mark == .done { return 3 }
            return card.agent != nil ? 4 : 5
        }
        return cards.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
}
