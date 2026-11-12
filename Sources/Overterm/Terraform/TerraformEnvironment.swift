import Foundation

/// The environment of a terraform Overterm starts (analysis 4.5). Pure.
///
/// Stage 1a runs only what needs no credentials — `fmt` and `validate` —
/// so both get the stripped environment: every credential variable
/// (`TerraformGuards.isCredential`) taken out, and `HOME` and the CLI
/// config a scratch folder's, so the providers `validate` starts find
/// neither `~/.aws` nor `~/.terraform.d/credentials.tfrc.json`, and nothing
/// is downloaded. Whatever the purpose, what injects flags or logs values
/// never reaches a run (`isAlwaysRemoved`).
enum TerraformEnvironment {
    enum Purpose: Sendable, Equatable {
        /// `fmt -`, `fmt -check`: reads HCL, runs no provider.
        case format
        /// `validate -json`: starts every provider binary (spike 19), so
        /// no credential, no HOME of the user's.
        case validate
        /// An agent's read through a `tf_` tool (`fmt -check -diff`,
        /// `validate`, `show -json` of its saved plan): run outside the
        /// agent's sandbox, so the same as validate's — nothing to reach a
        /// cloud with (analysis 4.5, 5.10).
        case agentRead
        /// Overterm's own runs that reach the backend and the cloud —
        /// `plan`, `show -json` of its plan, `init`, `workspace list` and
        /// `select` (stage 1d): the user's environment, so credential
        /// chains reach the providers unchanged; `TF_WORKSPACE` the
        /// checked workspace (4.9), or none (`workspace list`/`select`,
        /// which refuse a pinned shell); the plugin cache when the person
        /// took it (4.13).
        case run(workspace: String?, pluginCache: String?)
    }

    /// Names no run ever gets: `TF_CLI_ARGS` and `TF_CLI_ARGS_*` (they
    /// inject `-auto-approve` and `-lock=false`, verified), `TF_LOG*`
    /// (logs `-var` values), `TF_REATTACH_PROVIDERS` (bypasses the lock
    /// file's hashes), and an inherited `TF_WORKSPACE` or `TF_DATA_DIR`
    /// (each decides silently which state a run touches).
    static func isAlwaysRemoved(_ name: String) -> Bool {
        name == "TF_CLI_ARGS" || name.hasPrefix("TF_CLI_ARGS_") || name == "TF_LOG" || name.hasPrefix("TF_LOG_")
            || name == "TF_REATTACH_PROVIDERS" || name == "TF_WORKSPACE" || name == "TF_DATA_DIR"
    }

    /// The environment for `purpose`, in `root`, over `base` (the user's
    /// login shell's, or a guarded run's scratch one —
    /// `AppEnvironment.terraformBaseEnvironment`).
    static func build(base: [String: String], purpose: Purpose, root: URL, scratch: TerraformGuards.Scratch) -> [String: String] {
        var environment: [String: String]
        switch purpose {
        case .format, .validate, .agentRead:
            environment = base.filter { name, _ in !isAlwaysRemoved(name) && !TerraformGuards.isCredential(name) }
            environment["HOME"] = scratch.home.path
            environment["TF_CLI_CONFIG_FILE"] = scratch.cliConfig.path
        case .run(let workspace, let pluginCache):
            // Credentials pass through, unread (5.7); what injects flags,
            // logs values or decides the state silently never does.
            environment = base.filter { name, _ in !isAlwaysRemoved(name) }
            if let workspace { environment["TF_WORKSPACE"] = workspace }
            if let pluginCache { environment["TF_PLUGIN_CACHE_DIR"] = pluginCache }
        }
        environment["CHECKPOINT_DISABLE"] = "1"
        environment["TF_INPUT"] = "0"
        environment["TF_IN_AUTOMATION"] = "1"
        environment["TF_DATA_DIR"] = root.appendingPathComponent(".terraform", isDirectory: true).path
        return environment
    }

    /// The `TF_VAR_*` names of an environment — never their values: what
    /// the plan's header says changes it (2.2, "Inputs that change a plan").
    static func variableNames(in environment: [String: String]) -> [String] {
        environment.keys.filter { $0.hasPrefix("TF_VAR_") && $0.count > 7 }.map { String($0.dropFirst(7)) }.sorted()
    }

    /// What terraform-ls never has in its environment, nor the
    /// `terraform validate` it runs, in `LanguageServers.Spec`'s patterns
    /// (`X*` begins, `*X` ends, `*X*` contains): the credentials of
    /// `TerraformGuards` and `isAlwaysRemoved`'s names.
    static let languageServerRemoved: [String] = {
        var patterns = TerraformGuards.credentialPrefixes.map { $0 + "*" }
        patterns += TerraformGuards.credentialNames.sorted()
        patterns += TerraformGuards.credentialSuffixes.map { "*" + $0 }
        patterns += ["*_SECRET*", "SECRET*", "TF_CLI_ARGS", "TF_CLI_ARGS_*", "TF_LOG", "TF_LOG_*", "TF_REATTACH_PROVIDERS", "TF_WORKSPACE", "TF_DATA_DIR"]
        return patterns
    }()

    /// What terraform-ls has set (analysis 4.14, 5.13 rule 11): no call
    /// home, and a scratch HOME and CLI config — the stripped variables
    /// alone leave `~/.aws` and `~/.terraform.d` readable to the providers
    /// its `validate` starts.
    static func languageServerAdded(scratch: TerraformGuards.Scratch) -> [String: String] {
        ["CHECKPOINT_DISABLE": "1", "HOME": scratch.home.path, "TF_CLI_CONFIG_FILE": scratch.cliConfig.path]
    }
}
