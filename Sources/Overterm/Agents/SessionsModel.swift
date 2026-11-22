import Foundation

/// The Sessions panel: Claude Code conversations run in this repository's
/// worktrees, newest first, and which of them are running in a tab now.
@MainActor
package final class SessionsModel: ObservableObject {
    @Published package private(set) var sessions: [ClaudeSession] = []
    /// Session id → the tab it is running in.
    @Published package private(set) var running: [String: Tab.ID] = [:]
    @Published package private(set) var loading = false

    /// A tab's Claude process: where it runs and how it was started.
    package struct RunningClaude: Sendable {
        package let tab: Tab.ID
        package let directory: String
        /// The session its `--resume`/`-r` picks back up, off argv's raw
        /// words (`PaneAgent.resumes`).
        package let resumes: String?
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
            return (Self.claudes(asked.map(\.id), agents), snapshot)
        }
        let sessions = await PaneAgent.offMain { ClaudeSessions.list(in: directories) }
        self.sessions = sessions
        self.running = Self.running(sessions, claudes)
    }

    /// Of each tab's agent, the Claude ones whose folder is known, in the
    /// tabs' order. Pure.
    package nonisolated static func claudes(_ tabs: [Tab.ID], _ agents: [Tab.ID: PaneAgent]) -> [RunningClaude] {
        tabs.compactMap { tab in
            guard let agent = agents[tab], agent.kind == .claude, let folder = agent.folder else { return nil }
            return RunningClaude(tab: tab, directory: folder, resumes: agent.resumes)
        }
    }

    /// Which session each running Claude is: the one its command resumed
    /// (`--resume <id>`), else the newest one in its directory.
    package nonisolated static func running(_ sessions: [ClaudeSession], _ claudes: [RunningClaude]) -> [String: Tab.ID] {
        var result: [String: Tab.ID] = [:]
        for claude in claudes {
            if let id = claude.resumes, sessions.contains(where: { $0.id == id }) {
                result[id] = claude.tab
                continue
            }
            let directory = URL(fileURLWithPath: claude.directory).standardizedFileURL.path
            if let newest = sessions.first(where: { $0.directory == directory && result[$0.id] == nil }) {
                result[newest.id] = claude.tab
            }
        }
        return result
    }
}
