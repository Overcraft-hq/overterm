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

    /// The app's bundle id (Scripts/make-app.sh writes the same one): its
    /// defaults domain, log subsystem, caches folder, pasteboards.
    static let bundleIdentifier = "io.github.terminus-app.terminus"
    /// What it was until 2026-09-26; settings are carried over from it once.
    static let formerBundleIdentifier = "ai.promptrails.terminus"
    private static let migratedKey = "migratedFromFormerBundleIdentifier"

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
            // Named before the app was, and left that way: the session,
            // the snippets and the command history live in it, and a new
            // name would open the app on an empty one.
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
            .appendingPathComponent("\(bundleIdentifier)/Drops", isDirectory: true)
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

    /// The themes bundled with the app: Ghostty's own, and the rest of
    /// iTerm2-Color-Schemes beside them (Scripts/fetch-themes.sh). Ghostty
    /// resolves `theme = "<name>"` here itself; Settings ▸ Themes reads the
    /// files to draw each one.
    static var bundledThemesDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("ghostty/themes", isDirectory: true)
    }

    /// The user's own themes, where Ghostty looks for them too. Nil in an
    /// isolated run: a scenario must not depend on what the user has put there.
    static var userThemesDirectory: URL? {
        guard !isIsolated else { return nil }
        if let config = env["XDG_CONFIG_HOME"], !config.isEmpty {
            return URL(fileURLWithPath: config, isDirectory: true).appendingPathComponent("ghostty/themes", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ghostty/themes", isDirectory: true)
    }

    private static let isolatedSuite = "\(bundleIdentifier).isolated"

    /// UserDefaults.standard, or a throwaway suite for an isolated run.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard isIsolated, let suite = UserDefaults(suiteName: isolatedSuite) else { return .standard }
        suite.removePersistentDomain(forName: isolatedSuite)
        return suite
    }()

    /// Once, on the first launch under the new bundle id: the old id's
    /// settings (window frame, divider positions, panels, the app files
    /// open in) are copied over. Before the window is built — it reads them.
    /// Privacy grants belong to the id and are asked for again; the session
    /// and snippets live in Application Support/Terminus and never moved.
    static func carryOverFormerDefaults() {
        guard !isIsolated, !defaults.bool(forKey: migratedKey) else { return }
        let former = UserDefaults.standard.persistentDomain(forName: formerBundleIdentifier) ?? [:]
        carryOver(former, into: defaults)
        defaults.set(true, forKey: migratedKey)
    }

    /// Copies what `into` doesn't already have: a setting made under the new
    /// id wins over the old one.
    static func carryOver(_ former: [String: Any], into defaults: UserDefaults) {
        for (key, value) in former where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
