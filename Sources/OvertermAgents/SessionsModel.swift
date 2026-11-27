import Foundation

/// The Sessions panel: Claude Code's and opencode's conversations run in
/// this repository's worktrees, newest first, and which of them are
/// running in a tab now.
@MainActor
package final class SessionsModel: ObservableObject {
    package init() {}

    @Published package private(set) var sessions: [AgentSession] = []
    /// Session id → the tab it is running in.
    @Published package private(set) var running: [String: Tab.ID] = [:]
    @Published package private(set) var loading = false

    /// A tab's Claude (or opencode) process: where it runs and how it was started.
    package struct RunningClaude: Sendable {
        package let tab: Tab.ID
        package let directory: String
        /// The session its `--resume`/`-r` (Claude) or `--session`/`-s`
        /// (opencode) picks back up, off argv's raw words (`PaneAgent.resumes`).
        package let resumes: String?
        package var agent: Agent = .claude

        package init(tab: Tab.ID, directory: String, resumes: String?, agent: Agent = .claude) {
            self.tab = tab
            self.directory = directory
            self.resumes = resumes
            self.agent = agent
        }
    }

    /// The sessions again, and which tab runs each: every tab's Claude a
    /// lookup in the app's census (docs/design/activity/analysis.md, 7.8)
    /// — one snapshot for every tab, the window's light tick while it
    /// shows —, where each pane of each tab had a scan of its own. The
    /// lookup and the session files are read off the main thread.
    package func refresh(directories: [String], tabs: [Tab], census: ActivitySampler = .app) async {
        let asked = tabs.map { tab in (id: tab.id, tags: tab.terminals.map(\.processTag)) }
        loading = true
        defer { loading = false }
        // A pane not paired yet is paired from the lookup's snapshot and
        // read again (`PaneAgent.pairing`); the session files once.
        let claudes = await PaneAgent.pairing(census: census) {
            let (agents, snapshot) = PaneAgent.lookupAndSnapshot(asked, census: census, only: .claude, folders: true)
            // A tab's opencode too, its folder waited for as Claude's is
            // (the census's snapshot of this same tick, looked up again).
            let opencodes = PaneAgent.lookup(asked, census: census, only: .opencode, folders: true)
            return (Self.claudes(asked.map(\.id), agents) + Self.running(asked.map(\.id), opencodes, kind: .opencode), snapshot)
        }
        let sessions = await PaneAgent.offMain { AgentSessions.list(in: directories) }
        self.sessions = sessions
        self.running = Self.running(sessions, claudes)
    }

    /// Of each tab's agent, the Claude ones whose folder is known, in the
    /// tabs' order. Pure.
    package nonisolated static func claudes(_ tabs: [Tab.ID], _ agents: [Tab.ID: PaneAgent]) -> [RunningClaude] {
        running(tabs, agents, kind: .claude)
    }

    /// Of each tab's agent, the `kind` ones whose folder is known. Pure.
    package nonisolated static func running(_ tabs: [Tab.ID], _ agents: [Tab.ID: PaneAgent], kind: Agent) -> [RunningClaude] {
        tabs.compactMap { tab in
            guard let agent = agents[tab], agent.kind == kind, let folder = agent.folder else { return nil }
            return RunningClaude(tab: tab, directory: folder, resumes: agent.resumes, agent: kind)
        }
    }

    /// Which session each running agent is: the one its command resumed
    /// (`--resume <id>`), else its agent's newest one in its directory.
    package nonisolated static func running(_ sessions: [AgentSession], _ claudes: [RunningClaude]) -> [String: Tab.ID] {
        var result: [String: Tab.ID] = [:]
        for claude in claudes {
            if let id = claude.resumes, sessions.contains(where: { $0.id == id && $0.agent == claude.agent }) {
                result[id] = claude.tab
                continue
            }
            let directory = URL(fileURLWithPath: claude.directory).standardizedFileURL.path
            if let newest = sessions.first(where: { $0.agent == claude.agent && $0.directory == directory && result[$0.id] == nil }) {
                result[newest.id] = claude.tab
            }
        }
        return result
    }
}
