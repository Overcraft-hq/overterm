import Foundation

/// Agents launched with Terraform's writes denied (analysis 3.4, D-8):
/// for a checkout with a production root, `terraform.agentWriteGuard` (on
/// by default) adds to the command Overterm types to start an agent — New
/// Task's, an agent tab's, a resumed one's — for that launch only:
/// - Claude Code: `--disallowedTools` with `Bash(…)` deny rules for each
///   write of `terraform`, `tofu` and `terragrunt` (`claudeRules`), in
///   three forms: the documented prefix (`Bash(terraform apply:*)`), the
///   operation after flags (`Bash(*terraform * apply*)`: `-chdir=…`,
///   `terragrunt run --all apply`) and after an assignment
///   (`Bash(* terraform apply*)`: `TF_WORKSPACE=prod terraform apply`).
///   **Checked statically, not run** (running an agent reaches its model
///   provider): Claude Code 2.1.322's own `--disallowedTools` splitter
///   keeps commas and spaces inside a rule's parentheses, and its rule
///   linter takes a `*` anywhere in a `Bash` rule. Whether each rule
///   matches at run time, and holds under `--dangerously-skip-permissions`,
///   is its documentation's word only — said in Settings and the docs.
/// - opencode: `OPENCODE_PERMISSION` — JSON merged into its permission
///   rules after every config layer — with `bash` patterns set to `deny`
///   (`opencodePermission`), the same three forms. Its matcher anchors
///   the whole command, `*` any run, and checks each command of a chain;
///   the last matching rule wins, and ours are merged after the user's.
/// - Gemini CLI: `--admin-policy <file>` — a policy file of Overterm's
///   (`geminiPolicy`, `AgentLaunchFiles`) whose `deny` rules for
///   `run_shell_command` hold at the admin tier, over any approval; it
///   leaves the user's own policies in place (`--policy` would replace
///   them). Gemini ignores it where an administrator's policies are
///   installed (`/Library/Application Support/GeminiCli/policies`): then
///   not guarded, and said.
/// - Codex: no per-command deny for one launch (its rules files live in
///   its home, none named by a flag): not guarded, and its pane says so
///   (`.notGuarded`).
/// - pi: no approvals and no deny of its own (an extension would be
///   code of ours running in it): not guarded, said.
/// opencode's and Gemini's are checked against their source, not run.
///
/// It writes nothing to the user's agent configuration and puts no shim on
/// PATH (a shim stays rejected, D-8); a script, `bash -c` or `make apply`
/// get around it — the pane header and the Inbox still see the terraform
/// process and the agent's ask. Pure.
enum TerraformAgentGuard {
    enum Launch: Equatable, Sendable {
        /// Nothing added: no production root, or the setting is off.
        case none
        /// The deny rules are on its command line.
        case denied
        /// An agent with no way to deny: said on its pane.
        case notGuarded(String)
    }

    /// The writes denied, as a command's words say them after the tool:
    /// `state` is every state command (`rm`, `mv`, `push`; `list` and
    /// `show` too — the agent's reads go through `tf_` tools); `refresh`
    /// writes state with no prompt; `test` with real providers creates and
    /// destroys real infrastructure (2.9).
    static let deniedOperations = [
        "apply", "destroy", "import", "taint", "untaint", "force-unlock", "state", "workspace delete", "refresh", "test", "apply-all", "destroy-all",
    ]
    /// Flags that write wherever they are: `init -migrate-state` and
    /// `-force-copy` move state to a new backend.
    static let deniedFlags = ["-auto-approve", "-migrate-state", "-force-copy"]
    static let tools = ["terraform", "tofu", "terragrunt"]

    /// Claude Code's `Bash(…)` rules (see above).
    static let claudeRules: [String] = tools.flatMap { tool in
        deniedOperations.flatMap { operation in
            ["Bash(\(tool) \(operation):*)", "Bash(*\(tool) * \(operation)*)", "Bash(* \(tool) \(operation)*)"]
        } + deniedFlags.map { "Bash(*\(tool) *\($0)*)" }
    }

    static let codexNote = "Codex has no per-command deny: its terraform writes aren't blocked — the header and the Inbox still show them"
    static let piNote = "pi asks before nothing and has no per-command deny: its terraform writes aren't blocked — the header still shows them"
    static let geminiAdminNote =
        "Gemini CLI ignores Overterm's deny policy where an administrator's policies are installed: its terraform writes aren't blocked by Overterm"

    /// What `agent` gets in a checkout where a guard applies.
    /// `geminiAdminPolicies`: an administrator's Gemini policies are in
    /// place, so `--admin-policy` would be ignored.
    static func launch(for agent: Agent, applies: Bool, geminiAdminPolicies: Bool = false) -> Launch {
        guard applies else { return .none }
        switch agent {
        case .claude, .opencode: return .denied
        case .gemini: return geminiAdminPolicies ? .notGuarded(geminiAdminNote) : .denied
        case .codex: return .notGuarded(codexNote)
        case .pi: return .notGuarded(piNote)
        }
    }

    /// `base` (the agent's command with what its launch adds) with the
    /// deny rules: Claude Code's last — `--disallowedTools` takes every
    /// word after it, so nothing may follow it; opencode's in front, its
    /// variable; Gemini's `--admin-policy` last. One word each,
    /// single-quoted for the shell. `geminiPolicy`: the policy file's path.
    static func command(_ base: String, launch: Launch, agent: Agent = .claude, geminiPolicy: String? = nil) -> String {
        guard launch == .denied else { return base }
        switch agent {
        case .claude: return base + " --disallowedTools '" + claudeRules.joined(separator: ",") + "'"
        case .opencode: return "OPENCODE_PERMISSION=" + AgentLaunch.quoted(opencodePermission) + " " + base
        case .gemini: return geminiPolicy.map { base + " --admin-policy " + AgentLaunch.quoted($0) } ?? base
        case .codex, .pi: return base
        }
    }

    /// opencode's `permission.bash` rules: each Claude rule's pattern, as
    /// opencode's wildcard reads it (`*` any run, the whole command).
    static let opencodeRules: [String] = tools.flatMap { tool in
        deniedOperations.flatMap { ["\(tool) \($0)*", "*\(tool) * \($0)*", "* \(tool) \($0)*"] } + deniedFlags.map { "*\(tool) *\($0)*" }
    }

    static let opencodePermission: String = {
        // Keys in order: opencode takes the last rule that matches.
        let rules = opencodeRules.map { "\(AgentLaunch.json([$0]).dropFirst().dropLast()):\"deny\"" }.joined(separator: ",")
        return "{\"bash\":{" + rules + "}}"
    }()

    /// Gemini CLI's policy: `deny` for `run_shell_command` by prefix
    /// (`commandPrefix`, a word boundary after it) and, for the two other
    /// forms and the flags, by `commandRegex` — matched from the start of
    /// the command's JSON value, so `[^"]*` stays inside it.
    static let geminiPolicy: String = {
        func literal(_ text: String) -> String { "'" + text + "'" }
        let prefixes = tools.flatMap { tool in deniedOperations.map { "\(tool) \($0)" } }
        var regexes = tools.flatMap { tool in
            deniedOperations.flatMap { ["[^\"]*\(tool) [^\"]* \($0)", "[^\"]* \(tool) \($0)"] }
        }
        regexes += tools.flatMap { tool in deniedFlags.map { "[^\"]*\(tool) [^\"]*\($0)" } }
        var text = "# Overterm: Terraform's writes denied for this launch (--admin-policy). Written by Overterm.\n"
        text += "[[rule]]\ntoolName = \"run_shell_command\"\ncommandPrefix = [" + prefixes.map(literal).joined(separator: ", ")
        text += "]\ndecision = \"deny\"\npriority = 900\n"
        for regex in regexes {
            text += "\n[[rule]]\ntoolName = \"run_shell_command\"\ncommandRegex = " + literal(regex) + "\ndecision = \"deny\"\npriority = 900\n"
        }
        return text
    }()

    /// Whether `command` (a typed line) carries the deny rules.
    static func carriesRules(_ command: String) -> Bool {
        command.contains("--disallowedTools '" + claudeRules.joined(separator: ",") + "'")
    }

    /// Whether `command` would be denied by `rules`, as Claude Code's
    /// documentation reads them: `X:*` a prefix ending at a word, `*` any
    /// run of characters elsewhere. The tests' model of the matcher — not
    /// Claude Code's own code. Pure.
    static func denies(_ command: String, rules: [String] = claudeRules) -> Bool {
        rules.contains { rule in
            guard rule.hasPrefix("Bash("), rule.hasSuffix(")") else { return false }
            let pattern = String(rule.dropFirst("Bash(".count).dropLast())
            if pattern.hasSuffix(":*") {
                let prefix = String(pattern.dropLast(2))
                return command == prefix || command.hasPrefix(prefix + " ")
            }
            let regex = "^" + NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*") + "$"
            return command.range(of: regex, options: .regularExpression) != nil
        }
    }
}

/// Which checkouts have a production root, for the guard at an agent's
/// launch (3.4). Fails closed: a launch in a checkout not known to have
/// none is guarded.
/// - **Production** is kept until the checkout's Terraform files change
///   (`forget`): production is sticky (5.13 rule 12).
/// - **None** is kept only from a complete read — one `git ls-files`
///   (`TerraformRootScan.list`), not capped, every root classified — and
///   only while the classes' settings and the remembered production
///   identities are what they were then: a root raised by hand, a pattern
///   or account changed, an identity the header remembered, each makes it
///   unknown again. Each launch it answers also starts a read again, so a
///   production root merged into a worktree the panel never shows reaches
///   the next launch.
/// - **Unknown** — never read, read and capped, not listable — is guarded,
///   and read off the main thread (`decide`, once at a time a checkout).
/// No walk, no file read on the main thread. New Task awaits `decide`.
@MainActor
final class TerraformAgentGuards {
    static let shared = TerraformAgentGuards()

    enum Verdict: Equatable {
        /// Its production roots' paths ("." for the top).
        case production([String])
        /// None, as read under these settings and identities.
        case noProduction(TerraformClassSettings, Set<TerraformStateIdentity>)
    }

    private var verdicts: [String: Verdict] = [:]
    private var deciding: Set<String> = []
    /// Reads started (`decide`): a test counts them.
    private(set) var reads = 0

    private static func key(_ checkout: URL) -> String { checkout.resolvingSymlinksInPath().standardizedFileURL.path }

    /// The checkout a launch's folder is in: the nearest folder above with a `.git`.
    nonisolated static func checkout(of folder: URL) -> URL { TerraformProcesses.checkout(of: folder) ?? folder.standardizedFileURL }

    /// True: a production root; false: none, still valid; nil: unknown (guarded).
    func known(_ checkout: URL) -> Bool? {
        switch verdicts[Self.key(checkout)] {
        case .production: return true
        case .noProduction(let settings, let identities):
            guard settings == TerraformClassSettings.current, identities == TerraformRootStore.shared.productionIdentities else { return nil }
            return false
        case nil: return nil
        }
    }

    /// The paths of `checkout`'s production roots, as last read.
    func productionRoots(_ checkout: URL) -> [String] {
        if case .production(let paths) = verdicts[Self.key(checkout)] { return paths }
        return []
    }

    /// A read of `checkout`'s roots (the panel's, a tool's): production
    /// kept; none only when `complete` (the listing wasn't capped).
    func record(_ checkout: URL, roots: [TerraformRootCard], complete: Bool, settings: TerraformClassSettings, identities: Set<TerraformStateIdentity>) {
        let key = Self.key(checkout)
        let production = roots.filter { $0.isProduction || $0.workspaceClasses.values.contains(.production) }.map { $0.path.isEmpty ? "." : $0.path }
        if !production.isEmpty {
            verdicts[key] = .production(production)
        } else if complete {
            // A production verdict stays until the files change (`forget`).
            if case .production = verdicts[key] { return }
            verdicts[key] = .noProduction(settings, identities)
        }
    }

    func forget(_ checkout: URL) { verdicts[Self.key(checkout)] = nil }

    /// Reads `checkout`'s roots now (one `git ls-files`, the facts off the
    /// main thread) and keeps what they say; true when it is, or may be,
    /// production — nil listing or capped and nothing production found.
    @discardableResult
    func decide(_ checkout: URL) async -> Bool {
        reads += 1
        let settings = TerraformClassSettings.current
        let identities = TerraformRootStore.shared.productionIdentities
        let profile = AppEnvironment.guardsTerraform ? nil : ShellEnvironment.known()?["AWS_PROFILE"]
        guard let listing = await TerraformRootScan.list(checkout) else { return known(checkout) != false }
        let assembled = await TerraformPanelModel.blocking {
            TerraformPanelModel.assemble(
                checkout: checkout, listing: listing, worktrees: [], settings: settings, identities: identities, awsProfile: profile, changed: [])
        }
        record(checkout, roots: assembled.roots, complete: !listing.capped, settings: settings, identities: identities)
        return known(checkout) != false
    }

    /// The guard for `agent` started in `folder`, now: Settings, then what
    /// is known of its checkout — unknown is guarded — and a read started
    /// for the next launch.
    func launch(for agent: Agent, in folder: URL) -> TerraformAgentGuard.Launch {
        let settings = Settings.shared
        guard settings.terraformEnabled, settings.terraformAgentWriteGuard else { return .none }
        let checkout = Self.checkout(of: folder)
        let applies = known(checkout) != false
        let key = Self.key(checkout)
        if deciding.insert(key).inserted {
            Task { [weak self] in
                await self?.decide(checkout)
                self?.deciding.remove(key)
            }
        }
        return TerraformAgentGuard.launch(
            for: agent, applies: applies, geminiAdminPolicies: agent == .gemini && applies && AgentLaunchFiles.geminiAdminPoliciesDefined())
    }
}
