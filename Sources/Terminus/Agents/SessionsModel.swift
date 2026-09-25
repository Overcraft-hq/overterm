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

    func refresh(directories: [String], tabs: [Tab], inspector: ProcessInspector) async {
        let roots = tabs.map { tab in (tab.id, tab.terminals.map { (SurfaceProcesses.shared.loginPID(of: $0), $0.processTag) }) }
        loading = true
        defer { loading = false }
        let (sessions, claudes) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let claudes = roots.compactMap { tab, panes -> RunningClaude? in
                    for (root, tag) in panes {
                        if let node = inspector.tree(root: root, tag: tag).flatMap(\.flattened).first(where: {
                            AgentOverviewModel.agent(of: $0) == .claude
                        }), let directory = node.workingDirectory {
                            return RunningClaude(tab: tab, directory: directory, command: node.command)
                        }
                    }
                    return nil
                }
                continuation.resume(returning: (ClaudeSessions.list(in: directories), claudes))
            }
        }
        self.sessions = sessions
        self.running = Self.running(sessions, claudes)
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
