import Foundation

/// The Sessions panel: Claude Code conversations run in this repository's
/// worktrees, newest first, and which of them are running in a tab now.
@MainActor
final class SessionsModel: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []
    /// Session id → the tab it is running in.
    @Published private(set) var running: [String: Tab.ID] = [:]
    @Published private(set) var loading = false

    /// A tab's Claude process: where it runs and how it was started.
    struct RunningClaude: Sendable {
        let tab: Tab.ID
        let directory: String
        let command: String
    }

    /// The sessions again, and which tab runs each: every tab's Claude a
    /// lookup in the app's census (docs/design/activity/analysis.md, 7.8)
    /// — one snapshot for every tab, the window's light tick while it
    /// shows —, where each pane of each tab had a scan of its own. The
    /// lookup and the session files are read off the main thread.
    func refresh(directories: [String], tabs: [Tab], census: ActivitySampler = .app) async {
        let asked = tabs.map { tab in (id: tab.id, tags: tab.terminals.map(\.processTag)) }
        loading = true
        defer { loading = false }
        if census === ActivitySampler.app { ActivityMonitor.shared.flushContext() }
        let (sessions, claudes) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let agents = PaneAgent.lookup(asked, census: census, only: .claude, folders: true)
                continuation.resume(returning: (ClaudeSessions.list(in: directories), Self.claudes(asked.map(\.id), agents)))
            }
        }
        self.sessions = sessions
        self.running = Self.running(sessions, claudes)
    }

    /// Of each tab's agent, the Claude ones whose folder is known, in the
    /// tabs' order. Pure.
    nonisolated static func claudes(_ tabs: [Tab.ID], _ agents: [Tab.ID: PaneAgent]) -> [RunningClaude] {
        tabs.compactMap { tab in
            guard let agent = agents[tab], agent.kind == .claude, let folder = agent.folder else { return nil }
            return RunningClaude(tab: tab, directory: folder, command: agent.command)
        }
    }

    /// Which session each running Claude is: the one its command resumed
    /// (`--resume <id>`), else the newest one in its directory.
    nonisolated static func running(_ sessions: [ClaudeSession], _ claudes: [RunningClaude]) -> [String: Tab.ID] {
        var result: [String: Tab.ID] = [:]
        for claude in claudes {
            let words = claude.command.split(separator: " ").map(String.init)
            if let flag = words.firstIndex(where: { $0 == "--resume" || $0 == "-r" }), flag + 1 < words.count,
                sessions.contains(where: { $0.id == words[flag + 1] })
            {
                result[words[flag + 1]] = claude.tab
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
