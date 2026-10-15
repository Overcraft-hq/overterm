import Foundation

/// Where Overterm keeps its state, and whether this run must keep its hands
/// off the real state.
///
/// An isolated run — the end-to-end tests (`OVERTERM_E2E`) or the layout
/// dump (`OVERTERM_DUMP_LAYOUT`) — shares the bundle id, and so the real
/// app's defaults, with the user's Overterm. It gets its own defaults suite
/// (wiped at launch), its own support directory, no notifications, no
/// focus stealing and no saved divider positions.
enum AppEnvironment {
    private static let env = ProcessInfo.processInfo.environment

    /// The app's bundle id (Scripts/make-app.sh writes the same one): its
    /// defaults domain, log subsystem, caches folder, pasteboards.
    static let bundleIdentifier = "io.github.overcraft-hq.overterm"
    /// The ids it has had, newest first; settings are carried over from the
    /// newest one that has any, once. It was Terminus until 2026-10-14, and
    /// published under another name again before 2026-09-26.
    static let formerBundleIdentifiers = ["io.github.terminus-app.terminus", "ai.promptrails.terminus"]
    private static let migratedKey = "migratedFromFormerBundleIdentifier"

    /// The end-to-end scenario to run, if any.
    static let e2eScenario = env["OVERTERM_E2E"]

    static let isIsolated = e2eScenario != nil || env["OVERTERM_DUMP_LAYOUT"] != nil

    /// session.json and snippets.json live here. OVERTERM_SUPPORT_DIR
    /// overrides (a test hands in a prepared session); an isolated run
    /// without it gets a fresh temporary directory.
    static let supportDirectory: URL = {
        if let dir = env["OVERTERM_SUPPORT_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        if isIsolated {
            return FileManager.default.temporaryDirectory.appendingPathComponent("overterm-isolated-\(UUID().uuidString)", isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let ours = support.appendingPathComponent("Overterm", isDirectory: true)
        // It was named after the app, and the app has been renamed: the
        // session, the snippets, the settings and the command history move
        // with the name — once, and only where nothing of ours is yet.
        let former = support.appendingPathComponent("Terminus", isDirectory: true)
        if !FileManager.default.fileExists(atPath: ours.path), FileManager.default.fileExists(atPath: former.path) {
            try? FileManager.default.moveItem(at: former, to: ours)
        }
        return ours
    }()

    /// Files dropped onto a terminal as promises (Photos, Safari, the
    /// screenshot thumbnail write theirs only when asked) land here, a
    /// folder per drop. The caches, where macOS may clear them in time; an
    /// isolated run keeps them in its own support directory.
    static let dropsDirectory: URL = {
        if isIsolated || env["OVERTERM_SUPPORT_DIR"] != nil {
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
    /// and snippets live in Application Support/Overterm and never moved.
    static func carryOverFormerDefaults() {
        guard !isIsolated, !defaults.bool(forKey: migratedKey) else { return }
        for id in formerBundleIdentifiers {
            let former = UserDefaults.standard.persistentDomain(forName: id) ?? [:]
            guard !former.isEmpty else { continue }
            carryOver(former, into: defaults)
            break
        }
        defaults.set(true, forKey: migratedKey)
    }

    /// Copies what `into` doesn't already have: a setting made under the new
    /// id wins over the old one. A key naming the app the window and the
    /// dividers were saved under ("NSWindow Frame TerminusMainWindow") is
    /// renamed with it, or the window opens where it never was.
    static func carryOver(_ former: [String: Any], into defaults: UserDefaults) {
        for (key, value) in former {
            let key = key.replacingOccurrences(of: "Terminus", with: "Overterm")
            guard defaults.object(forKey: key) == nil else { continue }
            defaults.set(value, forKey: key)
        }
    }
}
