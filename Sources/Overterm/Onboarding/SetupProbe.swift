import Foundation

/// Fills `SetupFacts` with each feature's own finders, off the main thread
/// (docs/design/onboarding/analysis.md, 3.1–3.2).
///
/// It looks; it never runs. No agent's CLI, no `git`, no `gh auth status`:
/// a file's existence or whether it is executable, and the login shell's
/// PATH — asked through `ShellEnvironment.login()`, which runs the
/// person's rc files once (so the card says "No tool was run", never
/// "Nothing was run"). Nothing inside `~/.claude` or `~/.codex` is read —
/// only whether the two folders exist —, nothing under Desktop, Documents,
/// Downloads or iCloud Drive is touched — a PATH folder there is passed
/// over (`isProtected`): macOS asks the person before an app looks in
/// those —, and nothing is written.
package enum SetupProbe {
    /// A scenario's facts, handed back instead of looking (as
    /// `GitHub.executableOverride` stands in for gh).
    @MainActor package static var override: SetupFacts?
    /// A scenario's "Tools the panels use", handed back instead of looking.
    @MainActor package static var panelsOverride: SetupPanelFacts?

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

    /// Command Line Tools, or Xcode: git is there to run. Only their
    /// existence. Last, the developer folder `xcode-select -s` picked — an
    /// Xcode elsewhere, `Xcode-beta.app` — through the link it keeps, which
    /// exists only while what it points at does; `xcode-select` isn't run.
    package static let developerToolsPaths = ["/Library/Developer/CommandLineTools", "/Applications/Xcode.app", "/var/db/xcode_select_link"]

    /// The folders macOS asks the person about before an app looks inside
    /// (Files and Folders): the probes look at nothing there, not even a
    /// PATH folder's executable.
    package nonisolated static func protectedFolders(home: String) -> [String] {
        ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"].map { folder in home + "/" + folder }
    }

    /// Whether `path` is one of `protectedFolders` or inside one. Pure.
    package nonisolated static func isProtected(_ path: String, home: String) -> Bool {
        let path = (path as NSString).standardizingPath
        return protectedFolders(home: home).contains { folder in path == folder || path.hasPrefix(folder + "/") }
    }

    /// The facts now. The shell is asked off the main thread; `gh`'s place
    /// is read on it, as everything that runs gh reads it. `full`: the
    /// Setup page's too — notifications as macOS says now (never its
    /// question), the bridge as Settings has it. `again`: a person's Check
    /// Again — the shell asked again at once, even one that answered.
    @MainActor package static func read(full: Bool = false, again: Bool = false) async -> SetupFacts {
        if let override { return override }
        let gh = GitHub.executable
        let places = Places(
            home: FileManager.default.homeDirectoryForCurrentUser.path, claudeProjects: AppEnvironment.claudeProjectsDirectory.path,
            codexSessions: AppEnvironment.codexSessionsDirectory.path)
        let geminiVariable = ProcessInfo.processInfo.environment["GEMINI_CLI_SYSTEM_DEFAULTS_PATH"] != nil
        var facts = await withCheckedContinuation { (continuation: CheckedContinuation<SetupFacts, Never>) in
            // Spelled `@Sendable`: left to inference, a block for a queue
            // written here could be typed main-actor and trap off it.
            let work: @Sendable () -> Void = {
                let facts = Self.facts(
                    environment: ShellEnvironment.login(askingAgain: again), gh: gh, places: places, exists: { FileManager.default.fileExists(atPath: $0) },
                    isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }, geminiVariable: geminiVariable)
                continuation.resume(returning: facts)
            }
            DispatchQueue.global(qos: .utility).async(execute: work)
        }
        guard full else { return facts }
        facts.notifications = await AttentionNotifier.authorizationState()
        facts.toolGroups = toolGroups(in: .shared)
        facts.bridgeServing = BrowserBridge.shared.isServing
        return facts
    }

    /// How many of the agents' tool groups Settings turns on — the eight
    /// `BrowserBridge.wanted` asks about.
    @MainActor package static func toolGroups(in settings: Settings) -> Int {
        [
            settings.browserAgentControl, settings.apiAgentControl, settings.notesAgentAccess, settings.databaseAgentAccess, settings.dockerAgentAccess,
            settings.kubernetesAgentAccess, settings.terraformAgentAccess, settings.activityAgentAccess,
        ].count { on in on }
    }

    /// The facts from the shell's answer (nil: not answered) and the file
    /// checks — Gemini CLI's system defaults by the launch's own two tests
    /// (`geminiVariable`: its variable in the app's environment). Pure but
    /// for `exists` and `isExecutable`, the only ways it touches the disk —
    /// `SetupCheckTests` records every path; neither is asked about a path
    /// in `protectedFolders`.
    package nonisolated static func facts(
        environment: [String: String]?, gh: URL?, places: Places, exists: (String) -> Bool, isExecutable: (String) -> Bool, geminiVariable: Bool = false
    ) -> SetupFacts {
        let home = places.home
        func looksExecutable(_ path: String) -> Bool { !isProtected(path, home: home) && isExecutable(path) }
        var agents: [Agent: AgentFinder.Result] = [:]
        for agent in Agent.allCases {
            agents[agent] = AgentFinder.find(
                agent, environment: environment, knownPaths: AgentFinder.knownPaths(for: agent, home: home), isExecutable: looksExecutable)
        }
        var usedBefore: Set<Agent> = []
        if exists(places.claudeProjects) { usedBefore.insert(.claude) }
        if exists(places.codexSessions) { usedBefore.insert(.codex) }
        var ghOnPath: URL?
        if let environment { ghOnPath = ShellEnvironment.executable("gh", in: environment, isExecutable: looksExecutable) }
        return SetupFacts(
            shellAnswered: environment != nil, agents: agents, usedBefore: usedBefore, developerTools: developerToolsPaths.contains(where: exists),
            gh: gh, ghOnPath: ghOnPath,
            geminiSystemDefaults: geminiVariable || exists(AgentLaunchFiles.geminiSystemDefaults))
    }
}
