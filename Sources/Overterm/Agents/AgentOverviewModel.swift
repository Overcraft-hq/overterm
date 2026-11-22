import Foundation

/// Every tab at a glance, agents first: whether it works, waits for you,
/// finished or failed; where (checkout, branch, its PR); and, for Claude,
/// what the session is about, what you last asked, and what it last said
/// or is doing right now. Refreshed every 2 s while shown.
@MainActor
package final class AgentOverviewModel: ObservableObject {
    package struct Card: Identifiable, Equatable {
        package let id: Tab.ID
        package let title: String
        package let color: TabColor?
        /// The agent the tab was opened for, or one found running in it.
        package let agent: Agent?
        /// An agent process is alive in one of its panes.
        package let agentRunning: Bool
        package let activity: TabActivity
        /// Where the agent works, else the focused pane's directory.
        package let directory: String?
        package let branch: String?
        package let claude: ClaudeActivity?
        package let panes: Int
        /// The agent's process, as the census found it running: where
        /// Show in Activity selects (6.12).
        package var agentProcess: ActivityProcessID? = nil
        /// Its agent's CPU, footprint and servers, from the census's
        /// snapshot the card was made from (6.2, 6.12).
        package var usage: AgentUsage? = nil
        /// What its agents' ended runs left running (6.9): "left 2 behind".
        package var left = 0
    }

    /// What an agent spends, it and everything under it (its tools, its
    /// MCP servers, the dev servers it started), from one census — no scan
    /// of the overview's own (docs/design/activity/analysis.md, 6.12).
    package struct AgentUsage: Equatable, Sendable {
        /// 100 is one core; nil before a second sample gives a rate (7.5).
        package var cpu: Double?
        /// Activity Monitor's Memory, summed.
        package var footprint: UInt64
        /// What it listens on: pills with Open.
        package var servers: [ListeningPort]
    }

    @Published package private(set) var cards: [Card] = []
    /// A refresh still reading: the next poll skips rather than piling up
    /// (and landing out of order) behind a slow one.
    package private(set) var isRefreshing = false

    package struct Snapshot: Sendable {
        package let id: Tab.ID
        package let title: String
        package let color: TabColor?
        package let agent: Agent?
        package let activity: TabActivity
        package let directory: String?
        /// Its panes' tags, in the tab's order.
        package let tags: [String]
        package let panes: Int
    }

    /// Every card again: each tab's agent a lookup in the app's census
    /// (docs/design/activity/analysis.md, 7.8) — the light tick this
    /// window already has while it shows, one tick for every tab when it
    /// is older —, where each refresh walked every pane of every tab with a
    /// scan of its own (2.4 item 2: tabs × panes × 7 ms every 2 s). The
    /// lookup, the transcripts and the branches are read off the main
    /// thread, on a GCD thread.
    package func refresh(_ tabs: [Tab], census: ActivitySampler = .app) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let snapshots = tabs.map { tab in
            Snapshot(
                id: tab.id, title: tab.title, color: tab.color, agent: tab.agent, activity: tab.activity,
                directory: tab.agentDirectory ?? tab.workingDirectory, tags: tab.terminals.map(\.processTag), panes: tab.terminals.count)
        }
        // A pane not paired yet is paired from the lookup's snapshot and
        // read again (`PaneAgent.pairing`).
        let cards = await PaneAgent.pairing(census: census) {
            let (agents, snapshot) = PaneAgent.lookupAndSnapshot(snapshots.map { ($0.id, $0.tags) }, census: census, folders: true)
            return (snapshots.map { Self.card(for: $0, agent: agents[$0.id], snapshot: snapshot) }, snapshot)
        }
        // What its agents' runs left that still runs (6.9).
        let ledger = LeftBehindLedger.shared
        let latest = ActivityMonitor.shared.snapshot
        self.cards = Self.ordered(
            cards.map { card in
                var card = card
                card.left = ledger.leftCount(of: card.id, in: latest)
                return card
            })
    }

    /// A tab's card, with the agent the census found running in it — and,
    /// from `census`, what that agent spends.
    package nonisolated static func card(for snapshot: Snapshot, agent running: PaneAgent?, snapshot census: ActivitySnapshot? = nil) -> Card {
        let agent = running?.kind ?? snapshot.agent
        let directory = running?.folder ?? snapshot.directory
        let claude =
            agent == .claude
            ? directory.flatMap(ClaudeUsageReader.latestSession(for:)).flatMap { ClaudeActivity.read($0) } : nil
        return Card(
            id: snapshot.id, title: snapshot.title, color: snapshot.color, agent: agent, agentRunning: running != nil,
            activity: snapshot.activity, directory: directory, branch: claude?.branch ?? directory.flatMap { Self.branch(in: $0) },
            claude: claude, panes: snapshot.panes, agentProcess: running?.identity,
            usage: running.flatMap { running in census.flatMap { usage(of: running.identity, in: $0) } })
    }

    /// `agent`'s usage in `snapshot`: it and its descendants (at most
    /// 2,000), their rates summed where read, their footprints, their
    /// listening ports. Nil when the snapshot has no such process. Pure.
    package nonisolated static func usage(of agent: ActivityProcessID, in snapshot: ActivitySnapshot) -> AgentUsage? {
        guard snapshot.table.process(agent) != nil else { return nil }
        let members = [agent] + snapshot.table.descendants(of: agent, limit: 2_000).map(\.identity)
        var cpu: Double?
        var footprint: UInt64 = 0
        for member in members {
            guard let facts = snapshot.facts[member] else { continue }
            if let rate = facts.rates?.cpuPercent { cpu = (cpu ?? 0) + rate }
            footprint += facts.usage?.footprint ?? 0
        }
        return AgentUsage(cpu: cpu, footprint: footprint, servers: ListeningPorts.of(members, in: snapshot))
    }

    package nonisolated static func agent(of node: ProcessNode) -> Agent? {
        Agent.of(name: node.name, argv: node.argvAgent, command: node.maskedCommand)
    }

    /// The checked-out branch, read from .git/HEAD (no git process per card
    /// every 2 s). A linked worktree's .git is a file pointing at its gitdir.
    ///
    /// The walk up is bounded, as CLAUDE.md asks of every one (docs/design/
    /// activity/analysis.md, 2.4 item 11): it stops at the top
    /// (`pathComponents.count <= 1`) and after `limit` steps. It compared
    /// with "/", and `/`'s parent is `/..`, so a folder with a `..` in it
    /// never got there — one such walk took 51 GB and the machine down.
    /// The path is standardized first, its `..`s gone.
    package nonisolated static func branch(in directory: String, limit: Int = 64) -> String? {
        var url = URL(fileURLWithPath: directory).standardizedFileURL
        for _ in 0..<max(limit, 0) where url.pathComponents.count > 1 {
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
            url = url.deletingLastPathComponent().standardizedFileURL
        }
        return nil
    }

    /// Waiting for you first, then failed, working, done; tabs without an
    /// agent last. The tab order otherwise.
    package nonisolated static func ordered(_ cards: [Card]) -> [Card] {
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
