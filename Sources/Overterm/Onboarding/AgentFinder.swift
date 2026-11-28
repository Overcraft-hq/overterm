import Foundation

/// Whether an agent's CLI is where a new tab's shell would find it
/// (docs/design/onboarding/analysis.md, 7.4): asked before an agent's tab
/// types its command, so a CLI that isn't there is said before the shell
/// says "command not found", and New Task's picker marks it.
///
/// It looks where the tab's shell looks: the login shell's PATH, as
/// `ShellEnvironment` was told it — `known()`, which never asks and never
/// waits. Until the shell has answered the answer is `.unknown` and nothing
/// changes. Claude Code's installers also put it in a few fixed places
/// (`knownPaths`); one found only there is found off the PATH — Claude
/// Code's local install is reached by `alias claude=~/.claude/local/claude`,
/// which no PATH lookup sees — so it is never warned about and never makes
/// New Task start on Shell only: the picker notes "not on PATH", the Setup
/// page says where it was found.
///
/// An alias or a shell function named `claude` never shows in a PATH
/// lookup, so `.missing` says "not found", never "not installed", and never
/// blocks: Open the Tab Anyway is always offered. No agent's CLI is run.
package enum AgentFinder {
    package enum Result: Equatable, Sendable {
        /// An executable at `url`: on the PATH, or only in one of the known places.
        case found(URL, onPath: Bool)
        /// The shell answered, and neither its PATH nor a known place has it.
        case missing
        /// The login shell hasn't answered yet (or never will, in an isolated run).
        case unknown

        /// Neither the PATH nor a known place has it: the only answer an
        /// agent's tab warns about and New Task starts on Shell only for.
        /// Found off the PATH is not — an alias may well reach it.
        package var isNotFound: Bool { self == .missing }

        /// What New Task's picker says beside the agent's name; nil when nothing.
        package var pickerNote: String? {
            switch self {
            case .missing: "not found"
            case .found(_, onPath: false): "not on PATH"
            case .found, .unknown: nil
            }
        }
    }

    /// Where Claude Code's installers put it, tried before the PATH by
    /// `AgentUsageCommand.executable()` too. Other agents have none.
    package nonisolated static func knownPaths(for agent: Agent, home: String) -> [String] {
        guard agent == .claude else { return [] }
        return [
            // ~/.local/bin is the native installer's.
            "\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.bun/bin/claude",
        ]
    }

    /// `agent`'s CLI on `environment`'s PATH, else in `knownPaths`; nil
    /// `environment` (the shell hasn't answered) is `.unknown`. Pure but for
    /// `isExecutable`.
    package nonisolated static func find(
        _ agent: Agent, environment: [String: String]?, knownPaths: [String], isExecutable: (String) -> Bool
    ) -> Result {
        guard let environment else { return .unknown }
        if let url = ShellEnvironment.executable(agent.command, in: environment, isExecutable: isExecutable) {
            return .found(url, onPath: true)
        }
        if let path = knownPaths.first(where: isExecutable) { return .found(URL(fileURLWithPath: path), onPath: false) }
        return .missing
    }

    /// The same with the probes' rule: nothing in a folder macOS guards
    /// (`SetupProbe.isProtected` — Desktop, Documents, Downloads, iCloud
    /// Drive) is looked at, so a PATH folder there never brings macOS's
    /// question. Pure but for `isExecutable`.
    package nonisolated static func find(
        _ agent: Agent, environment: [String: String]?, home: String, isExecutable: (String) -> Bool
    ) -> Result {
        func looksExecutable(_ path: String) -> Bool { !SetupProbe.isProtected(path, home: home) && isExecutable(path) }
        return find(agent, environment: environment, knownPaths: knownPaths(for: agent, home: home), isExecutable: looksExecutable)
    }

    /// `agent` as the login shell last said its PATH: never asks it, never
    /// waits for it — the main thread may call it.
    package static func find(_ agent: Agent) -> Result {
        find(
            agent, environment: ShellEnvironment.known(), home: FileManager.default.homeDirectoryForCurrentUser.path,
            isExecutable: { path in FileManager.default.isExecutableFile(atPath: path) })
    }

    /// The warning before an agent's tab types its command; nil when the
    /// command goes as before — found (on the PATH, or in a known place an
    /// alias may reach), or not known yet.
    package nonisolated static func warning(_ agent: Agent, _ result: Result) -> (title: String, detail: String)? {
        guard result == .missing else { return nil }
        return ("\(agent.productName) isn’t on your PATH.", "Overterm looked where a new tab’s shell looks.")
    }
}
