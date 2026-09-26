import Foundation

/// Where Terminus keeps its state, and whether this run must keep its hands
/// off the real state.
///
/// An isolated run — the end-to-end tests (`TERMINUS_E2E`) or the layout
/// dump (`TERMINUS_DUMP_LAYOUT`) — shares the bundle id, and so the real
/// app's defaults, with the user's Terminus. It gets its own defaults suite
/// (wiped at launch), its own support directory, no notifications, no
/// focus stealing and no saved divider positions.
enum AppEnvironment {
    private static let env = ProcessInfo.processInfo.environment

    /// The end-to-end scenario to run, if any.
    static let e2eScenario = env["TERMINUS_E2E"]

    static let isIsolated = e2eScenario != nil || env["TERMINUS_DUMP_LAYOUT"] != nil

    /// session.json and snippets.json live here. TERMINUS_SUPPORT_DIR
    /// overrides (a test hands in a prepared session); an isolated run
    /// without it gets a fresh temporary directory.
    static let supportDirectory: URL = {
        if let dir = env["TERMINUS_SUPPORT_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        if isIsolated {
            return FileManager.default.temporaryDirectory.appendingPathComponent("terminus-isolated-\(UUID().uuidString)", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Terminus", isDirectory: true)
    }()

    /// Files dropped onto a terminal as promises (Photos, Safari, the
    /// screenshot thumbnail write theirs only when asked) land here, a
    /// folder per drop. The caches, where macOS may clear them in time; an
    /// isolated run keeps them in its own support directory.
    static let dropsDirectory: URL = {
        if isIsolated || env["TERMINUS_SUPPORT_DIR"] != nil {
            return supportDirectory.appendingPathComponent("Drops", isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ai.promptrails.terminus/Drops", isDirectory: true)
    }()

    /// Claude Code's session transcripts: ~/.claude/projects, or
    /// $CLAUDE_CONFIG_DIR/projects. An isolated run gets an empty one of its
    /// own — the changes pane reads transcripts, and a scenario must never
    /// read the user's — until a scenario points ClaudeUsageReader at the
    /// transcripts it wrote.
    static let claudeProjectsDirectory: URL = {
        if isIsolated { return supportDirectory.appendingPathComponent("claude-projects", isDirectory: true) }
        if let dir = env["CLAUDE_CONFIG_DIR"] { return URL(fileURLWithPath: dir).appendingPathComponent("projects") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }()

    private static let isolatedSuite = "ai.promptrails.terminus.isolated"

    /// UserDefaults.standard, or a throwaway suite for an isolated run.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard isIsolated, let suite = UserDefaults(suiteName: isolatedSuite) else { return .standard }
        suite.removePersistentDomain(forName: isolatedSuite)
        return suite
    }()
}
