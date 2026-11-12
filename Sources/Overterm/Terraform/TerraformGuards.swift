import Foundation

/// What keeps Terraform off the user's own when it must be: in an isolated
/// run or a unit test (`AppEnvironment.guardsTerraform`), no terraform but
/// `OVERTERM_TERRAFORM`'s, nothing of the user's shell in its environment,
/// a HOME and a CLI config of the run's own (so `~/.aws`, `~/.terraformrc`
/// and `~/.terraform.d`'s credentials are never in reach), proxies at a
/// dead port so nothing leaves this Mac but what reaches 127.0.0.1 (the
/// tests' `FakeTerraformBackend`), no provider fetched. Analysis 4.2, 4.5,
/// 4.13, 5.7, 5.13 rule 8. Pure, but for `prepareScratch`.
enum TerraformGuards {
    /// Which terraform a run uses.
    enum Binary: Equatable, Sendable {
        /// `OVERTERM_TERRAFORM`'s, in a guarded run only: a scenario's
        /// recording wrapper (`TerraformRecorder`), or a stand-in script —
        /// an absolute path to an executable, never a name a PATH search
        /// or the run's folder would resolve.
        case variable(String)
        /// Guarded with no usable `OVERTERM_TERRAFORM`: none is found, as
        /// no Docker engine is reached without `OVERTERM_DOCKER_HOST`.
        case none
        /// The user's: `terraform.path`, mise, the shell's PATH
        /// (`TerraformCLI`). `OVERTERM_TERRAFORM` is ignored here: a
        /// variable stray in the app's launch environment never silently
        /// redirects the user's plans and applies (analysis 4.2).
        case search
    }

    /// Guarded, `OVERTERM_TERRAFORM` when it is an absolute path to an
    /// executable, else nothing; unguarded, the user's terraform, searched
    /// for, whatever the variable says.
    static func binary(
        variable: String?, guarded: Bool, isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Binary {
        guard guarded else { return .search }
        guard let variable = variable?.trimmingCharacters(in: .whitespaces), variable.hasPrefix("/"), isExecutable(variable) else { return .none }
        return .variable(variable)
    }

    /// The prefixes of the variables that carry a cloud's, a backend's or a
    /// registry's credentials, or choose them (`AWS_PROFILE`): what
    /// validate, an agent's reads and terraform-ls never get, and what a
    /// guarded run refuses to start with (analysis 4.5, 11). `TF_HTTP_` is
    /// the http backend's (GitLab's managed state: its username and
    /// password); `CONSUL_HTTP_` the consul backend's; `KUBE_` the
    /// kubernetes and helm providers' and the kubernetes backend's
    /// (`KUBE_CONFIG_PATH` names a kubeconfig by absolute path, which a
    /// scratch HOME doesn't hide; `KUBE_CLIENT_KEY_DATA`, `KUBE_HOST`);
    /// `HELM_` helm's (its kube context, token, API server, repositories).
    static let credentialPrefixes = [
        "AWS_", "GOOGLE_", "CLOUDSDK_", "ARM_", "AZURE_", "TF_TOKEN_", "TF_CLOUD_", "TF_VAR_", "TF_HTTP_", "VAULT_", "CONSUL_HTTP_", "TFE_",
        "OCI_", "ALICLOUD_", "CLOUDFLARE_", "DIGITALOCEAN_", "HCLOUD_", "LINODE_", "SCW_", "KUBE_", "HELM_",
    ]
    /// Whole names: a kube context's files (a `kubernetes` provider or
    /// backend), a provider attached by hand (it bypasses the lock file's
    /// hashes), GCP's key file, OpenTofu's state encryption keys, the pg
    /// backend's connection and password.
    static let credentialNames: Set<String> = [
        "KUBECONFIG", "TF_REATTACH_PROVIDERS", "GOOGLE_APPLICATION_CREDENTIALS", "TF_ENCRYPTION", "PG_CONN_STR", "PGPASSWORD", "PGPASSFILE",
        "PGSERVICEFILE",
    ]
    /// Name endings that say a credential whatever the tool
    /// (`GITHUB_TOKEN`, `DATADOG_API_KEY`, `MYSQL_PASSWORD`), and a part
    /// (`_SECRET`: `CLIENT_SECRET_ID`).
    static let credentialSuffixes = ["_TOKEN", "_PASSWORD", "_PASSWD", "_API_KEY", "_APIKEY", "_ACCESS_KEY", "_PRIVATE_KEY", "_CREDENTIALS"]

    static func isCredential(_ name: String) -> Bool {
        let upper = name.uppercased()
        return credentialNames.contains(upper) || credentialPrefixes.contains { upper.hasPrefix($0) }
            || credentialSuffixes.contains { upper.hasSuffix($0) } || upper.contains("_SECRET") || upper.hasPrefix("SECRET")
    }

    /// The credential variables an environment carries, by name, sorted.
    /// Never their values.
    static func credentials(in environment: [String: String]) -> [String] {
        environment.keys.filter(isCredential).sorted()
    }

    /// What a scenario run refuses to start with (analysis 4.5, "Isolated
    /// runs"): the credential variables of its own environment, by name —
    /// its terminal panes would inherit them, and a later stage runs the
    /// real terraform there. Empty outside a scenario.
    static func refusedCredentials(scenario: String?, environment: [String: String]) -> [String] {
        scenario == nil ? [] : credentials(in: environment)
    }

    /// Where the proxies point in a guarded run: the discard port on
    /// 127.0.0.1, where nothing listens — a registry, a cloud, HCP
    /// unreachable even should a test forget to say so.
    static let deadProxy = "http://127.0.0.1:9"

    /// The CLI config of a guarded run: providers only from `mirror`
    /// (when given), never fetched. A provider missing from the mirror
    /// fails `init` instead of being downloaded.
    static func cliConfig(mirror: URL? = nil) -> String {
        var text = "# Overterm's guarded run: no provider is downloaded.\nprovider_installation {\n"
        if let mirror {
            text += "  filesystem_mirror {\n    path    = \(hclString(mirror.path))\n    include = [\"*/*/*\"]\n  }\n"
        }
        text += "  direct {\n    exclude = [\"*/*/*\"]\n  }\n}\n"
        return text
    }

    /// The CLI config of New Task's `init -backend=false` in the user's
    /// app (stage 2b): providers from their registries, as the lock file
    /// pins them — the installer asks a source for the versions before it
    /// looks in the plugin cache, so `direct` can't be excluded —, and no
    /// `credentials` block: a private registry's provider fails there and
    /// is the person's Init…. A guarded run keeps `cliConfig`'s, nothing
    /// fetched.
    static let worktreeInitCLIConfig = "# Overterm's init without a backend: providers from their registries, no credentials.\nprovider_installation {\n  direct {}\n}\n"

    /// The environment of every terraform a guarded run starts — the base
    /// `TerraformEnvironment` builds on there, in place of the user's
    /// shell's: nothing inherited.
    static func guardedEnvironment(home: URL, cliConfig: URL) -> [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home.path,
            "TF_CLI_CONFIG_FILE": cliConfig.path,
            "CHECKPOINT_DISABLE": "1",
            "HTTP_PROXY": deadProxy, "HTTPS_PROXY": deadProxy, "http_proxy": deadProxy, "https_proxy": deadProxy,
            "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost",
            "LANG": "en_US.UTF-8",
        ]
    }

    /// A guarded run's own HOME and CLI config, inside `folder`.
    struct Scratch: Equatable, Sendable {
        var folder: URL
        var home: URL { folder.appendingPathComponent("home", isDirectory: true) }
        var cliConfig: URL { folder.appendingPathComponent("terraformrc") }
        /// `worktreeInitCLIConfig`, beside it.
        var worktreeInitConfig: URL { folder.appendingPathComponent("terraformrc-worktree-init") }
        var environment: [String: String] { TerraformGuards.guardedEnvironment(home: home, cliConfig: cliConfig) }
    }

    /// Makes `folder` (0700), its empty HOME and its CLI config, and
    /// returns them. The config is written again each time: a test may
    /// have changed it.
    static func prepareScratch(at folder: URL, mirror: URL? = nil) throws -> Scratch {
        let scratch = Scratch(folder: folder)
        let manager = FileManager.default
        try manager.createDirectory(at: scratch.home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try Data(cliConfig(mirror: mirror).utf8).write(to: scratch.cliConfig, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scratch.cliConfig.path)
        try Data(worktreeInitCLIConfig.utf8).write(to: scratch.worktreeInitConfig, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scratch.worktreeInitConfig.path)
        return scratch
    }

    /// Whether the user configures Terraform's CLI themselves — a
    /// `TF_CLI_CONFIG_FILE`, a `TF_PLUGIN_CACHE_DIR`, a `~/.terraformrc` —
    /// so the plugin cache is not offered (analysis 4.13). The file is
    /// checked for existence only, never opened: it can hold `credentials`
    /// blocks. A guarded run never looks.
    static func userConfiguresCLI(environment: [String: String], home: URL, guarded: Bool, exists: (String) -> Bool) -> Bool {
        guard !guarded else { return false }
        if !(environment["TF_CLI_CONFIG_FILE"] ?? "").isEmpty || !(environment["TF_PLUGIN_CACHE_DIR"] ?? "").isEmpty { return true }
        return exists(home.appendingPathComponent(".terraformrc").path)
    }

    /// A string as HCL writes it: quotes, backslashes and newlines
    /// escaped, `${` and `%{` doubled so nothing is a template.
    static func hclString(_ text: String) -> String {
        let escaped =
            text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "${", with: "$${")
            .replacingOccurrences(of: "%{", with: "%%{")
        return "\"\(escaped)\""
    }
}
