import Foundation

/// What the class decision reads from Settings, taken once on the main
/// thread and handed to the readers (never `Settings.shared` off it).
struct TerraformClassSettings: Equatable, Sendable {
    var pattern: String = ""
    var accounts: Set<String> = []
    var roots: [String: TerraformRootSettings] = [:]
    /// `kubernetes.contexts`' classes set by hand: a Kubernetes backend's or
    /// provider's literal `config_context` is classified as Kubernetes does.
    var kubeContexts: [String: KubeContextClass] = [:]

    var regex: NSRegularExpression { TerraformClassifier.pattern(pattern) }

    @MainActor static var current: TerraformClassSettings {
        let settings = Settings.shared
        return TerraformClassSettings(
            pattern: settings.terraformProductionPattern, accounts: Set(settings.terraformProductionAccounts), roots: settings.terraformRoots,
            kubeContexts: settings.kubernetesContexts.compactMapValues(\.contextClass))
    }
}

/// One root as the rail and the pane header say it (6.1, 6.2): its name,
/// class and why, the workspace, the backend, the identity — and what
/// other worktrees of the repository say of the same root. Pure, from the
/// facts read.
struct TerraformRootCard: Equatable, Sendable, Identifiable {
    var path: String
    /// `terraform.roots`' display name, else the path ("." for the top).
    var name: String
    var folder: URL
    var kind: TerraformFolderKind
    var facts: TerraformRootFacts
    var backendSummary: String
    var identity: TerraformStateIdentity?
    var verdict: TerraformClassifier.Verdict
    /// Each local workspace's class, the selected one's included.
    var workspaceClasses: [String: TerraformClass] = [:]
    var backendChanged = false
    /// A local backend's state missing here but in another worktree's
    /// same root: that worktree's name (3.7).
    var stateElsewhere: String?
    /// The other worktrees whose same root has this identity ("also in `bump-eks`").
    var sharedWith: [String] = []
    /// Changed in this branch, directly or through a module it calls.
    var touched = false
    /// The modules it calls, by path.
    var modules: [String] = []
    /// The identities of its production workspaces that something of the
    /// root or its state says is production — never only the shell's
    /// `AWS_PROFILE`, which says nothing about this state: kept by
    /// `TerraformRootStore` (5.1, sticky by identity).
    var rememberedIdentities: [TerraformStateIdentity] = []
    /// The binary's version, once asked (`version -json`), and the pill's mismatch.
    var version: String?
    var versionMismatch: String?
    /// The checkout is a Terragrunt tree (`root.hcl`): a signal the class reads, kept to decide it again at a run.
    var terragruntTree = false

    var id: String { path }
    var workspace: String { facts.workspace }
    var rootClass: TerraformClass { verdict.rootClass }
    var isProduction: Bool { rootClass == .production }

    /// The signals of a root, by name.
    static func signals(
        path: String, facts: TerraformRootFacts, workspace: String? = nil, varFiles: [String], awsProfile: String?, terragruntTree: Bool
    ) -> TerraformSignals {
        TerraformSignals(
            workspace: workspace ?? facts.workspace, path: path, backends: [facts.config.backend, facts.initRecord].compactMap { $0 },
            varFiles: varFiles, awsProfile: awsProfile, config: facts.config, terragruntTree: terragruntTree)
    }

    /// The class of `facts`' root for `workspace` (its own by default).
    static func verdict(
        path: String, folder: URL, facts: TerraformRootFacts, workspace: String? = nil, varFiles: [String], awsProfile: String?,
        terragruntTree: Bool, settings: TerraformClassSettings, productionIdentities: Set<TerraformStateIdentity>
    ) -> (TerraformClassifier.Verdict, TerraformStateIdentity?) {
        let workspace = workspace ?? facts.workspace
        let backend = facts.backend
        let identity = TerraformStateIdentity.of(backend: backend, workspace: workspace, root: folder)
        let signals = signals(path: path, facts: facts, workspace: workspace, varFiles: varFiles, awsProfile: awsProfile, terragruntTree: terragruntTree)
        let verdict = TerraformClassifier.classify(
            signals, backend: backend, lockProviders: facts.lockProviders, identity: identity, productionIdentities: productionIdentities,
            set: settings.roots[path]?.rootClass ?? settings.roots[path.isEmpty ? "." : path]?.rootClass, pattern: settings.regex,
            accounts: settings.accounts, kubeContexts: settings.kubeContexts)
        return (verdict, identity)
    }

    /// The identity to remember as production for this verdict: production
    /// by something tied to the root or its state — its workspace, path,
    /// backend, var files, providers, a class set by hand, an identity
    /// already kept — and not by `AWS_PROFILE` alone, the environment's
    /// (the app's login shell's, or a process's), which follows whoever
    /// exported it rather than the state: one `export
    /// AWS_PROFILE=acme-prod-admin` would otherwise make every state
    /// production for good. Nil when there is nothing to remember.
    static func identityToRemember(
        verdict: TerraformClassifier.Verdict, identity: TerraformStateIdentity?, awsProfile: String?, path: String, folder: URL,
        facts: TerraformRootFacts, workspace: String, varFiles: [String], terragruntTree: Bool, settings: TerraformClassSettings,
        productionIdentities: Set<TerraformStateIdentity>
    ) -> TerraformStateIdentity? {
        guard verdict.rootClass == .production, let identity, !productionIdentities.contains(identity) else { return nil }
        guard awsProfile != nil else { return identity }
        let (without, _) = Self.verdict(
            path: path, folder: folder, facts: facts, workspace: workspace, varFiles: varFiles, awsProfile: nil, terragruntTree: terragruntTree,
            settings: settings, productionIdentities: productionIdentities)
        return without.rootClass == .production ? identity : nil
    }

    static func make(
        folder root: TerraformRootFolder, at url: URL, facts: TerraformRootFacts, awsProfile: String?, terragruntTree: Bool,
        settings: TerraformClassSettings, productionIdentities: Set<TerraformStateIdentity>
    ) -> TerraformRootCard {
        let path = root.path
        let (verdict, identity) = verdict(
            path: path, folder: url, facts: facts, varFiles: root.autoVarFiles, awsProfile: awsProfile, terragruntTree: terragruntTree,
            settings: settings, productionIdentities: productionIdentities)
        var card = TerraformRootCard(
            path: path, name: settings.roots[path]?.displayName ?? (path.isEmpty ? "." : path), folder: url, kind: root.kind, facts: facts,
            backendSummary: TerraformStateIdentity.summary(of: facts.backend, workspace: facts.workspace), identity: identity, verdict: verdict)
        card.backendChanged = TerraformStateIdentity.changedSinceInit(config: facts.config.backend, record: facts.initRecord)
        card.terragruntTree = terragruntTree
        for workspace in Set(facts.localWorkspaces + [facts.workspace, "default"]).sorted() {
            let (each, eachIdentity) = Self.verdict(
                path: path, folder: url, facts: facts, workspace: workspace, varFiles: root.autoVarFiles, awsProfile: awsProfile,
                terragruntTree: terragruntTree, settings: settings, productionIdentities: productionIdentities)
            card.workspaceClasses[workspace] = each.rootClass
            if let remembered = identityToRemember(
                verdict: each, identity: eachIdentity, awsProfile: awsProfile, path: path, folder: url, facts: facts, workspace: workspace,
                varFiles: root.autoVarFiles, terragruntTree: terragruntTree, settings: settings, productionIdentities: productionIdentities)
            {
                card.rememberedIdentities.append(remembered)
            }
        }
        return card
    }
}

/// What the user's shell sets that decides silently which state a run
/// touches (4.5): said on the card, never used.
struct TerraformInheritedEnvironment: Equatable, Sendable {
    var workspace: String?
    var dataDir: String?
    /// The profile's name only: what Overterm's runs and a terminal's
    /// terraform use. A signal while set (5.1), never remembered.
    var awsProfile: String?

    init(_ environment: [String: String]) {
        workspace = environment["TF_WORKSPACE"].flatMap { $0.isEmpty ? nil : $0 }
        dataDir = environment["TF_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        awsProfile = environment["AWS_PROFILE"].flatMap { $0.isEmpty ? nil : $0 }
    }

    var notes: [String] {
        var notes: [String] = []
        if let workspace {
            notes.append("Your shell sets TF_WORKSPACE=\(workspace): a terraform typed in a terminal uses it, whatever the root selects.")
        }
        if dataDir != nil { notes.append("Your shell sets TF_DATA_DIR: Overterm uses each root's own .terraform; a terminal's terraform uses yours.") }
        if let awsProfile {
            notes.append(
                "Your shell sets AWS_PROFILE=\(awsProfile): Overterm's runs and a terminal's terraform use it, so a production profile makes every root here production while it is set — and only then."
            )
        }
        return notes
    }
}
