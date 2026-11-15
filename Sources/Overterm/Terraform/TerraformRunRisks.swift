import Foundation

/// What in a root's code runs, or reaches, more than its resources when it
/// is planned (analysis 5.4, 5.5): data sources that run a command or
/// fetch a URL (`external`, `http`, `local_command`), provisioners, a
/// state it reads (`terraform_remote_state`), actions, providers added
/// against the base branch's lock file, module sources changed. A plan
/// executes the configuration [verified: `data "local_command"` ran during
/// plan], so these are listed before a plan of code the person didn't
/// write, and on every plan's header. Pure.
struct TerraformRunRisk: Equatable, Hashable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case command, fetch, provisioner, remoteState, action, providerAdded, moduleChanged
    }

    var kind: Kind
    /// What exactly: `data.external`, `hashicorp/acme`, `git::https://…`.
    var detail: String

    var said: String {
        switch kind {
        case .command: "\(detail) runs a command on this Mac when planned"
        case .fetch: "\(detail) fetches a URL when planned"
        case .provisioner: "a provisioner runs a command when applied"
        case .remoteState: "it reads another state (\(detail))"
        case .action: "an action (\(detail)) is invoked"
        case .providerAdded: "provider \(detail) is new against the base branch's lock file"
        case .moduleChanged: "module source \(detail) is new against the base branch"
        }
    }
}

enum TerraformRunRisks {
    static let commandTypes: Set<String> = ["data.external", "data.local_command", "ephemeral.local_command", "action.local_command"]
    static let fetchTypes: Set<String> = ["data.http"]

    /// The base branch's side: its facts and lock file, when it was read.
    struct Base: Equatable, Sendable {
        var config: TerraformConfigFacts
        var lockProviders: [TerraformLockFile.Provider]?
    }

    /// Everything risky in a root's code now, and in its plan (actions).
    static func risks(config: TerraformConfigFacts, lockProviders: [TerraformLockFile.Provider]?, plan: TerraformPlan? = nil) -> [TerraformRunRisk] {
        var found: [TerraformRunRisk] = []
        for type in config.types.sorted() {
            if commandTypes.contains(type) { found.append(.init(kind: .command, detail: type)) }
            if fetchTypes.contains(type) { found.append(.init(kind: .fetch, detail: type)) }
            if type.hasPrefix("action."), !commandTypes.contains(type) { found.append(.init(kind: .action, detail: type)) }
        }
        if config.hasProvisioner { found.append(.init(kind: .provisioner, detail: "provisioner")) }
        for state in config.remoteStates {
            found.append(.init(kind: .remoteState, detail: "terraform_remote_state" + (state.backend.map { " · " + $0 } ?? "")))
        }
        for action in plan?.actions ?? [] where !found.contains(where: { $0.kind == .action && $0.detail == "action." + action.type }) {
            found.append(.init(kind: .action, detail: action.address))
        }
        for provider in (lockProviders ?? []).sorted(by: { $0.type < $1.type }) {
            found.append(.init(kind: .providerAdded, detail: "\(provider.namespace)/\(provider.type)"))
        }
        for source in Set(config.moduleSources).sorted() where !isLocal(source) {
            found.append(.init(kind: .moduleChanged, detail: source))
        }
        return found
    }

    /// The risks `now` has that `base` didn't: what "Plan this" after an
    /// agent's edit asks about (5.5). With no base read (no merge base, a
    /// new repository), all of them but the lock file's and the modules',
    /// which only a base can say are new.
    static func new(config: TerraformConfigFacts, lockProviders: [TerraformLockFile.Provider]?, plan: TerraformPlan? = nil, base: Base?) -> [TerraformRunRisk] {
        let now = risks(config: config, lockProviders: lockProviders, plan: plan)
        guard let base else { return now.filter { $0.kind != .providerAdded && $0.kind != .moduleChanged } }
        let before = Set(risks(config: base.config, lockProviders: base.lockProviders))
        return now.filter { !before.contains($0) }
    }

    /// All of them, the lock file's providers and the module sources only
    /// where they changed: what a plan's header lists.
    static func listed(config: TerraformConfigFacts, lockProviders: [TerraformLockFile.Provider]?, plan: TerraformPlan?, base: Base?) -> [TerraformRunRisk] {
        let now = risks(config: config, lockProviders: lockProviders, plan: plan)
        let fresh = Set(new(config: config, lockProviders: lockProviders, plan: plan, base: base))
        return now.filter { ($0.kind != .providerAdded && $0.kind != .moduleChanged) || fresh.contains($0) }
    }

    static func isLocal(_ source: String) -> Bool { source.hasPrefix("./") || source.hasPrefix("../") }
}

/// Whether the person is asked before a plan starts (5.3, 5.5), and what
/// the question says. Never an automatic plan: this is for a click, or an
/// agent's `tf_plan`. Pure.
enum TerraformPlanGate {
    struct Question: Equatable, Sendable {
        var title: String
        var detail: String
        var button: String
        var production: Bool
        /// What is typed to go ahead (D-21, 5.4: a write to production), or nil.
        var typedName: String? = nil
    }

    /// `authoredByPerson`: every commit since the base is the person's
    /// (`git config user.email`); nil when unknown, which counts as not
    /// theirs — a check that can't answer never lets a plan through
    /// unasked. `firstOnProduction`: no plan of this root this session yet,
    /// on production; `newRisks` against the base branch, `allRisks` now.
    /// `reviewing`: what a review tab plans ("pull request #42") — code the
    /// person didn't write by its nature, so always asked, on every class,
    /// with every risk (5.5).
    static func question(
        root: String, workspace: String, rootClass: TerraformClass, profile: String?, firstOnProduction: Bool, authoredByPerson: Bool?,
        newRisks: [TerraformRunRisk], allRisks: [TerraformRunRisk], agent: String? = nil, reviewing: String? = nil, unreadModules: Int = 0
    ) -> Question? {
        var reasons: [String] = []
        let notTheirs = authoredByPerson != true || reviewing != nil
        let credentials = profile.map { " with AWS_PROFILE \($0)" } ?? " with your default credentials"
        if let reviewing {
            reasons.append(
                "This plans \(reviewing), which is under review: a plan runs its providers, data sources and modules" + credentials
                    + ", whoever wrote them.")
        }
        if let agent {
            // 5.10: naming the root, the profile and the risk list.
            reasons.append(
                "\(agent) asks to plan \(root) · workspace \(workspace). A plan runs the configuration's providers and data sources\(credentials), outside the agent's sandbox."
            )
        }
        if firstOnProduction {
            reasons.append(
                "\(root) is production. A plan runs its providers and data sources" + credentials + ", and takes its state's lock.")
        }
        if notTheirs, reviewing == nil {
            reasons.append(
                authoredByPerson == nil
                    ? "Whose code this is can't be told (no git user.email, or git couldn't say): a plan runs it with your credentials."
                    : "Commits on this branch aren't yours: a plan runs their code with your credentials.")
        }
        let risks = notTheirs || agent != nil ? allRisks : newRisks
        if !risks.isEmpty {
            reasons.append("What its code runs or reaches:\n" + risks.prefix(20).map { "• " + $0.said }.joined(separator: "\n"))
        }
        if reviewing != nil, unreadModules > 0 {
            reasons.append(
                (unreadModules == 1 ? "1 module it calls wasn't" : "\(unreadModules) modules it calls weren't")
                    + " read (too many, or not in this checkout): what they run isn't listed.")
        } else if reviewing != nil, risks.isEmpty {
            reasons.append("Nothing in its root's code runs a command, fetches a URL or reads another state.")
        }
        guard agent != nil || firstOnProduction || notTheirs || !newRisks.isEmpty else { return nil }
        return Question(
            title: agent != nil ? "Let the agent plan \(root)?" : reviewing.map { "Plan \(root) of \($0)?" } ?? "Plan \(root)?", detail: reasons.joined(separator: "\n\n"), button: "Plan",
            production: rootClass == .production)
    }

    /// Whether the person wrote every commit given (`git log --format=%ae
    /// <base>..HEAD`, or HEAD's alone on the base): false when one isn't
    /// theirs, nil when it can't be told (no `user.email`, no author read).
    static func authoredByPerson(authors: [String], me: String?) -> Bool? {
        let me = (me ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let authors = authors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        guard !me.isEmpty, !authors.isEmpty else { return nil }
        return authors.allSatisfy { $0 == me }
    }

    /// Whether an agent's `tf_plan` asks (5.10): its first per root and
    /// session, and again whenever the root's code runs or reaches
    /// something the approved plan's didn't — a `data "external"` added
    /// after the approval runs outside the agent's sandbox with the
    /// person's credentials, so it is asked about.
    static func agentAsks(approved: Set<TerraformRunRisk>?, risks: [TerraformRunRisk]) -> Bool {
        guard let approved else { return true }
        return !Set(risks).isSubset(of: approved)
    }
}
