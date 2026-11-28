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
/// (`knownPaths`); one found only there is said as found off the PATH —
/// the tab's shell still won't find it unless an alias names it.
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

        /// A new tab's shell wouldn't find it: missing, or found off the PATH.
        package var isNotFound: Bool {
            switch self {
            case .missing: true
            case .found(_, let onPath): !onPath
            case .unknown: false
            }
        }

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

    /// `agent` as the login shell last said its PATH: never asks it, never
    /// waits for it — the main thread may call it.
    package static func find(_ agent: Agent) -> Result {
        find(
            agent, environment: ShellEnvironment.known(),
            knownPaths: knownPaths(for: agent, home: FileManager.default.homeDirectoryForCurrentUser.path),
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// The warning before an agent's tab types its command; nil when the
    /// command goes as before (found on the PATH, or not known yet).
    package nonisolated static func warning(_ agent: Agent, _ result: Result, home: String = NSHomeDirectory())
        -> (title: String, detail: String)?
    {
        let title = "\(agent.productName) isn’t on your PATH."
        let looked = "Overterm looked where a new tab’s shell looks."
        switch result {
        case .missing:
            return (title, looked)
        case .found(let url, onPath: false):
            let path = url.path.hasPrefix(home + "/") ? "~" + String(url.path.dropFirst(home.count)) : url.path
            return (title, looked + " Found at \(path), not on your PATH: the tab’s shell won’t find it unless an alias names it.")
        case .found, .unknown:
            return nil
        }
    }
}
