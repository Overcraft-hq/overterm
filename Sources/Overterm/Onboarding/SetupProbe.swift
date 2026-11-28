import Foundation

/// Fills `SetupFacts` with each feature's own finders, off the main thread
/// (docs/design/onboarding/analysis.md, 3.1–3.2).
///
/// It looks; it never runs. No agent's CLI, no `git`, no `gh auth status`:
/// a file's existence or whether it is executable, and the login shell's
/// PATH — asked through `ShellEnvironment.login()`, which runs the
/// person's rc files once (so the card says "No tool was run", never
/// "Nothing was run"). Nothing inside `~/.claude` or `~/.codex` is read —
/// only whether the two folders exist —, nothing under Documents, Desktop
/// or iCloud Drive is touched, and nothing is written.
package enum SetupProbe {
    /// A scenario's facts, handed back instead of looking (as
    /// `GitHub.executableOverride` stands in for gh).
    @MainActor package static var override: SetupFacts?

    /// Where the two agents that keep a folder of their sessions keep it.
    package struct Places: Sendable {
        package var home: String
        package var claudeProjects: String
        package var codexSessions: String

        package init(home: String, claudeProjects: String, codexSessions: String) {
            self.home = home
            self.claudeProjects = claudeProjects
            self.codexSessions = codexSessions
        }
    }

    /// Command Line Tools, or Xcode: git is there to run. Only their existence.
    package static let developerToolsPaths = ["/Library/Developer/CommandLineTools", "/Applications/Xcode.app"]

    /// The facts now. The shell is asked off the main thread; `gh`'s place
    /// is read on it, as everything that runs gh reads it.
    @MainActor package static func read() async -> SetupFacts {
        if let override { return override }
        let gh = GitHub.executable
        let places = Places(
            home: FileManager.default.homeDirectoryForCurrentUser.path, claudeProjects: AppEnvironment.claudeProjectsDirectory.path,
            codexSessions: AppEnvironment.codexSessionsDirectory.path)
        return await withCheckedContinuation { continuation in
            // Spelled `@Sendable`: left to inference, a block for a queue
            // written here could be typed main-actor and trap off it.
            let work: @Sendable () -> Void = {
                let facts = Self.facts(
                    environment: ShellEnvironment.login(), gh: gh, places: places, exists: { FileManager.default.fileExists(atPath: $0) },
                    isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
                continuation.resume(returning: facts)
            }
            DispatchQueue.global(qos: .utility).async(execute: work)
        }
    }

    /// The facts from the shell's answer (nil: not answered) and the two
    /// file checks. Pure but for `exists` and `isExecutable`, the only
    /// ways it touches the disk — `SetupCheckTests` records every path.
    package nonisolated static func facts(
        environment: [String: String]?, gh: URL?, places: Places, exists: (String) -> Bool, isExecutable: (String) -> Bool
    ) -> SetupFacts {
        var agents: [Agent: AgentFinder.Result] = [:]
        for agent in Agent.allCases {
            agents[agent] = AgentFinder.find(
                agent, environment: environment, knownPaths: AgentFinder.knownPaths(for: agent, home: places.home), isExecutable: isExecutable)
        }
        var usedBefore: Set<Agent> = []
        if exists(places.claudeProjects) { usedBefore.insert(.claude) }
        if exists(places.codexSessions) { usedBefore.insert(.codex) }
        return SetupFacts(
            shellAnswered: environment != nil, agents: agents, usedBefore: usedBefore, developerTools: developerToolsPaths.contains(where: exists),
            gh: gh, ghOnPath: environment.flatMap { ShellEnvironment.executable("gh", in: $0, isExecutable: isExecutable) })
    }
}
