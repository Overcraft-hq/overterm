import Foundation

/// What a root and workspace reach, and so what Overterm may do there
/// (analysis 5.1). A class belongs to a (root, workspace): one folder with
/// three workspaces can be three classes.
enum TerraformClass: String, CaseIterable, Sendable, Comparable {
    case local, remote, production

    var title: String {
        switch self {
        case .production: "Production"
        case .remote: "Remote"
        case .local: "Local"
        }
    }

    /// Higher is stricter: a class set by hand can only raise (5.1).
    private var rank: Int {
        switch self {
        case .local: 0
        case .remote: 1
        case .production: 2
        }
    }

    static func < (a: TerraformClass, b: TerraformClass) -> Bool { a.rank < b.rank }
}

/// A root's own settings: its entry in `terraform.roots`, by its path in
/// the repository (`infra/envs/prod`). Read-only to Overterm; any agent can
/// write settings.json, so the setting is held until confirmed (5.8).
struct TerraformRootSettings: Equatable, Sendable {
    /// Set by hand: only ever raises the class its names give.
    var rootClass: TerraformClass?
    var displayName: String?

    static let fields: [SettingField] = [
        SettingField(
            name: "class", kind: .choice([TerraformClass.production, .remote].map { SettingOption(value: $0.rawValue, label: $0.title) }),
            help: "production or remote: raises the class the names give, never lowers it."),
        SettingField(name: "displayName", kind: .text(placeholder: "", monospaced: false)),
    ]

    init(rootClass: TerraformClass? = nil, displayName: String? = nil) {
        self.rootClass = rootClass
        self.displayName = displayName
    }

    init(fields: [String: SettingValue]) {
        rootClass = fields["class"]?.string.flatMap(TerraformClass.init(rawValue:))
        displayName = fields["displayName"]?.string.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    static func all(from value: SettingValue?) -> [String: TerraformRootSettings] {
        (value?.entries ?? [:]).mapValues(TerraformRootSettings.init(fields:))
    }
}

/// Everything 5.1's signals are read from, by name only — never a
/// credential file, never Terraform run.
struct TerraformSignals: Equatable, Sendable {
    /// The workspace the root selects (`.terraform/environment`, else `default`).
    var workspace: String
    /// The root's path in its repository: `infra/envs/prod/network`.
    var path: String
    /// The backend's location keys, the HCL's and the init record's.
    var backends: [TerraformConfigFacts.Backend] = []
    /// The var files a run uses (`terraform.tfvars`, `*.auto.tfvars`, the
    /// ones chosen) and backend-config files, by name.
    var varFiles: [String] = []
    /// `AWS_PROFILE` in the run's environment: the profile's name, never its contents.
    var awsProfile: String?
    var config = TerraformConfigFacts()
    /// The repository is a Terragrunt tree (`root.hcl` or a top-level
    /// `terragrunt.hcl`): its top folder `live` is structure, not a signal.
    var terragruntTree = false
}

/// Which class a root and workspace are (5.1's precedence, first match wins):
///
/// 1. production by any signal, or by an identity once seen production;
/// 2. a class set by hand — which only raises;
/// 3. local by the strict rule;
/// 4. remote.
///
/// The branch is not a signal: branches name the work, not the target.
enum TerraformClassifier {
    /// Kubernetes' pattern with a trailing digit run allowed: `prod1`,
    /// `prd01`, `prod2-eu`, `production2` match; `product-catalog`,
    /// `delivery`, `reproduce` don't.
    static let defaultPattern = #"(^|[-_/.:@])(prod|prd|production|live)\d*([-_/.:@]|$)"#

    /// The setting's pattern, or the default when it is empty or doesn't
    /// compile — a broken pattern never makes nothing production.
    static func pattern(_ setting: String) -> NSRegularExpression {
        let trimmed = setting.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, let regex = try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive]) { return regex }
        return defaultRegex
    }

    private static let defaultRegex = try! NSRegularExpression(pattern: defaultPattern, options: [.caseInsensitive])

    static func matches(_ name: String, _ pattern: NSRegularExpression) -> Bool {
        !name.isEmpty && pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// The signal that makes it production, said for the card ("workspace
    /// prod", "backend key prod/network.tfstate"); nil when none does.
    static func productionSignal(
        _ signals: TerraformSignals, pattern: NSRegularExpression, accounts: Set<String>, kubeContexts: [String: KubeContextClass] = [:]
    ) -> String? {
        if matches(signals.workspace, pattern) { return "workspace \(signals.workspace)" }
        var path = signals.path
        if signals.terragruntTree, path == "live" || path.hasPrefix("live/") { path = String(path.dropFirst(4)) }
        if matches(path, pattern) { return "path \(signals.path)" }
        for backend in signals.backends {
            for key in [
                "bucket", "key", "prefix", "workspace_key_prefix", "organization", "hostname", "address", "container_name", "storage_account_name",
                "profile", "role_arn", "secret_suffix", "namespace", "config_context", "path",
            ] {
                if let value = backend.settings[key], matches(value, pattern) { return "backend \(key) \(value)" }
            }
            if let context = backend.settings["config_context"], isProductionContext(context, kubeContexts) {
                return "backend config_context \(context), a production Kubernetes context"
            }
            if let name = backend.workspaceName, matches(name, pattern) { return "backend workspace \(name)" }
            if let prefix = backend.workspacePrefix, matches(prefix, pattern) { return "backend workspaces \(prefix)*" }
        }
        for file in signals.varFiles where matches(file, pattern) { return "var file \(file)" }
        if let profile = signals.awsProfile, matches(profile, pattern) { return "AWS_PROFILE \(profile)" }
        for provider in signals.config.providers {
            for key in ["profile", "role_arn", "project", "subscription_id", "config_context"] {
                if let value = provider.settings[key], matches(value, pattern) { return "provider \(provider.name) \(key) \(value)" }
            }
            if let context = provider.settings["config_context"], isProductionContext(context, kubeContexts) {
                return "provider \(provider.name) config_context \(context), a production Kubernetes context"
            }
        }
        for account in signals.config.accountIDs.sorted() where accounts.contains(account) { return "account \(account)" }
        for backend in signals.backends {
            if let arn = backend.settings["role_arn"], let account = accountID(in: arn), accounts.contains(account) { return "account \(account)" }
        }
        return nil
    }

    /// A literal Kubernetes context as Kubernetes classes it (4.11, 5.1):
    /// `kubernetes.contexts`' class set by hand, else `KubeClassifier`'s
    /// names. Never a kubeconfig read: the context's name is the signal.
    static func isProductionContext(_ context: String, _ kubeContexts: [String: KubeContextClass]) -> Bool {
        guard !context.isEmpty, !context.contains("${") else { return false }
        return KubeClassifier.classify(context: context, cluster: nil, set: kubeContexts[context]) == .production
    }

    private static func accountID(in arn: String) -> String? {
        let parts = arn.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 5, parts[4].count == 12, parts[4].allSatisfy(\.isNumber) else { return nil }
        return String(parts[4])
    }

    /// The providers a local root may use: (namespace, type) on either registry.
    static let localProviders: Set<String> = ["null", "random", "local", "time", "tls", "terraform"]

    /// Why a root isn't local, or nil when it is (5.1, strict): a local
    /// backend inside the checkout, no provisioner, nothing that runs a
    /// command or reads the network, no other state read unless local
    /// inside the checkout, only the local providers, pinned by a lock file.
    static func notLocal(
        config: TerraformConfigFacts, backend: TerraformConfigFacts.Backend, lockProviders: [TerraformLockFile.Provider]?, rootPath: String
    ) -> String? {
        guard backend.type == "local" else { return "its backend is \(backend.type)" }
        if let path = backend.settings["path"], !isInside(path, rootPath: rootPath) { return "its state is outside the checkout" }
        if let folder = backend.settings["workspace_dir"], !isInside(folder, rootPath: rootPath) { return "its state is outside the checkout" }
        if config.hasProvisioner { return "it has a provisioner" }
        for type in config.types {
            let bare = type.split(separator: ".").last.map(String.init) ?? type
            if bare == "local_command" { return "it runs a command (\(type))" }
            if type == "data.external" || type == "data.http" { return "it reads \(type)" }
        }
        for state in config.remoteStates {
            guard state.backend == "local", let path = state.path, isInside(path, rootPath: rootPath) else { return "it reads another state" }
        }
        let used = config.providerNames
        if let other = used.subtracting(localProviders).sorted().first { return "it uses the \(other) provider" }
        for source in config.requiredProviders.values {
            guard let provider = TerraformLockFile.Provider("registry.terraform.io/" + source) ?? TerraformLockFile.Provider(source),
                isLocalProvider(provider)
            else { return "it uses \(source)" }
        }
        let needsLock = used.subtracting(["terraform"])
        if !needsLock.isEmpty {
            guard let lockProviders else { return "its providers aren't pinned by a lock file" }
            for name in needsLock where !lockProviders.contains(where: { $0.type == name && isLocalProvider($0) }) {
                return "\(name) isn't in its lock file"
            }
        }
        if let lockProviders, let other = lockProviders.first(where: { !isLocalProvider($0) }) {
            return "its lock file has \(other.namespace)/\(other.type)"
        }
        return nil
    }

    private static func isLocalProvider(_ provider: TerraformLockFile.Provider) -> Bool {
        ["registry.terraform.io", "registry.opentofu.org"].contains(provider.host) && provider.namespace == "hashicorp"
            && localProviders.contains(provider.type)
    }

    /// A path in the root's config that stays inside the checkout: relative,
    /// and its `..` never climbing above the repository's top.
    static func isInside(_ path: String, rootPath: String) -> Bool {
        guard !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("${") else { return false }
        var depth = rootPath.split(separator: "/").count
        for part in path.split(separator: "/") {
            if part == ".." {
                depth -= 1
                if depth < 0 { return false }
            } else if part != "." {
                depth += 1
            }
        }
        return true
    }

    struct Verdict: Equatable, Sendable {
        var rootClass: TerraformClass
        /// Why, in words: the signal, "set by hand", "seen production as …", the local rule's.
        var reason: String
    }

    static func classify(
        _ signals: TerraformSignals, backend: TerraformConfigFacts.Backend, lockProviders: [TerraformLockFile.Provider]?,
        identity: TerraformStateIdentity?, productionIdentities: Set<TerraformStateIdentity>, set: TerraformClass?,
        pattern: NSRegularExpression, accounts: Set<String>, kubeContexts: [String: KubeContextClass] = [:]
    ) -> Verdict {
        if let signal = productionSignal(signals, pattern: pattern, accounts: accounts, kubeContexts: kubeContexts) {
            return Verdict(rootClass: .production, reason: signal)
        }
        if let identity, productionIdentities.contains(identity) {
            return Verdict(rootClass: .production, reason: "its state was production before (\(identity.backend))")
        }
        if set == .production { return Verdict(rootClass: .production, reason: "set by hand in terraform.roots") }
        let whyNot = notLocal(config: signals.config, backend: backend, lockProviders: lockProviders, rootPath: signals.path)
        if set == .remote { return Verdict(rootClass: .remote, reason: "set by hand in terraform.roots") }
        if let whyNot { return Verdict(rootClass: .remote, reason: whyNot) }
        return Verdict(rootClass: .local, reason: "a local state and local providers only")
    }
}
