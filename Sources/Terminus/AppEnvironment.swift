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

    private static let isolatedSuite = "ai.promptrails.terminus.isolated"

    /// UserDefaults.standard, or a throwaway suite for an isolated run.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard isIsolated, let suite = UserDefaults(suiteName: isolatedSuite) else { return .standard }
        suite.removePersistentDomain(forName: isolatedSuite)
        return suite
    }()
}
