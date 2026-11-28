import Foundation

/// Whether this launch is the first ever, the first of a new version, or
/// one more of the same (docs/design/onboarding/analysis.md, 7.2): what the
/// later stages of onboarding decide by. Nothing reads it yet — the version
/// is written from this stage on, so that an update to the stage that does
/// read it already finds one.
///
/// Read at the very top of `applicationDidFinishLaunching`, before anything
/// writes: the session's autosave writes session.json, the update check
/// `updates.lastCheck`, and either would make a fresh install look like an
/// update. The version goes in the app's own defaults
/// (`AppEnvironment.defaults` — an isolated run's are its own, wiped at
/// launch), never settings.json: any agent may write that file, people sync
/// it between Macs, and a flag there would turn up in Settings' search.
package enum FirstRun {
    package enum Launch: Equatable, Sendable {
        /// Nothing of Overterm's was here: no version, no session, no
        /// settings.json, no update check.
        case fresh
        /// Another version ran last — older or newer — or none is
        /// remembered but something else of Overterm's is (an update from
        /// a version before this key: `from` nil).
        case upgraded(from: String?)
        /// This version ran last.
        case same
    }

    /// The version that ran last, written at every launch once the window shows.
    package static let lastRunVersionKey = "onboarding.lastRunVersion"
    /// The update check's own key (`UpdateChecker.checkIfDue`): an install
    /// that ever checked is not a fresh one.
    package static let lastUpdateCheckKey = "updates.lastCheck"

    /// The decision, from the facts alone. Pure.
    ///
    /// A 1.6.2 user has none of the new keys but an update check and,
    /// usually, a session: `.upgraded(from: nil)`, never `.fresh`.
    package nonisolated static func decide(
        lastRunVersion: String?, hasSession: Bool, hasSettingsFile: Bool, lastUpdateCheck: Date?, current: String
    ) -> Launch {
        guard let lastRunVersion, !lastRunVersion.isEmpty else {
            return hasSession || hasSettingsFile || lastUpdateCheck != nil ? .upgraded(from: nil) : .fresh
        }
        return lastRunVersion == current ? .same : .upgraded(from: lastRunVersion)
    }

    /// The facts as they are on disk and in `defaults`, then the decision.
    /// Reads only: a file's existence and two keys.
    package static func read(defaults: UserDefaults, sessionURL: URL, settingsURL: URL, current: String) -> Launch {
        let files = FileManager.default
        return decide(
            lastRunVersion: defaults.string(forKey: lastRunVersionKey),
            hasSession: files.fileExists(atPath: sessionURL.path),
            hasSettingsFile: files.fileExists(atPath: settingsURL.path),
            lastUpdateCheck: defaults.object(forKey: lastUpdateCheckKey) as? Date,
            current: current)
    }

    /// This version, remembered as the last to run.
    package static func remember(_ version: String, in defaults: UserDefaults) {
        defaults.set(version, forKey: lastRunVersionKey)
    }

    /// This build's version (CFBundleShortVersionString, i.e. VERSION) —
    /// `UpdateChecker.currentVersion`'s, without making the checker.
    package static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
