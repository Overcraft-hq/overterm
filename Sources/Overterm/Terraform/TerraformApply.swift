import Foundation

/// What 5.4 checks before an apply, gathered in one place: what the plan's
/// record kept, and what was read again just now (off the main thread —
/// the descriptor hashed, the binary and its version, the workspace, the
/// lock file, the environment built again). Names and hashes only: the
/// environments are compared by `TerraformApplyCheck.changedNames`, whose
/// answer is names, never values.
struct TerraformApplyFacts: Sendable {
    // The record's.
    var plan: TerraformPlan
    var mode: TerraformPlanMode = .normal
    var recordSHA: String
    var recordBinary: String
    var recordVersion: String?
    var recordWorkspace: String
    var recordDataDir: String
    var recordEnvironment: [String: String]
    /// The lock file's hash inside the plan zip; nil when it had none.
    var zipLockSHA: String?
    /// The plan's lock file pins no provider (`TerraformPlanZip.lockFilePinsNothing`).
    var zipLockPinsNothing = false
    /// The plan's stream warned that provider development overrides are in effect.
    var devOverrides = false

    // The root's.
    var rootName = ""
    var rootClass: TerraformClass
    /// Its `terraform.roots` `writable`: yes unless it says no.
    var writable = true
    /// A local backend's state is in another worktree, not here (3.7).
    var stateElsewhere: String?

    // Now.
    /// The root's class decided again now (5.1): its identity seen as
    /// production elsewhere since (sticky), the pattern, `terraform.roots`.
    var classNow: TerraformClassifier.Verdict?
    var descriptorSHA: String?
    var binaryNow: String?
    var versionNow: String?
    /// `TerraformWorkspaceCheck`'s answer for the record's workspace, now.
    var workspaceRefusal: String?
    var environmentNow: [String: String]?
    var dataDirNow: String?
    /// The root's `.terraform.lock.hcl` hashed now; nil when there is none.
    var lockSHANow: String?
    /// That file names no provider: builtin ones only, like no file at all.
    var lockPinsNothingNow = false
    /// Why the plan on screen isn't what applying would do: written since,
    /// its files changed, older than 30 minutes (`TerraformPlanRun.staleReason`).
    var staleReason: String?
    /// Another run holds this state's turn.
    var busy: String?
}

/// 5.4, in order, each refusal with its reason; nothing runs on a
/// refusal. What passes still asks (`TerraformApplySheet`), naming the
/// root's name to type where 5.4 says, and the version's sentence to
/// confirm where 3.8 says. Overterm doesn't reimplement Terraform's own
/// lineage and serial check: its refusal is authoritative. Pure.
enum TerraformApplyCheck {
    enum Verdict: Equatable, Sendable {
        case refused(String)
        /// May go, asked: `typed` — the root's name typed (production, a
        /// destroy, "creates everything"); `versionMove` — 3.8's sentence,
        /// confirmed on its own; `partial` — a `-target` plan's label.
        case ask(typed: Bool, versionMove: String?, partial: Bool, createsEverything: Bool)
    }

    static let devOverridesWarning = "Provider development overrides are in effect"

    /// Whether a plan's diagnostics carry the `dev_overrides` warning (4.5):
    /// a provider binary no lock file checks.
    static func hasDevOverrides(_ diagnostics: [TerraformDiagnostic]) -> Bool {
        diagnostics.contains { $0.summary.contains(devOverridesWarning) || $0.summary.contains("Provider development overrides") }
    }

    /// The checks that need nothing read now: what greys Apply in the
    /// header (6.4), with why, or nil when Apply may be pressed.
    static func greyed(
        plan: TerraformPlan?, rootClass: TerraformClass, writable: Bool, mode: TerraformPlanMode, devOverrides: Bool,
        staleReason: String?, busy: String?, versionConfirmed: Bool = true
    ) -> String? {
        guard let plan else { return "No plan to apply." }
        if let why = TerraformProcessCheck.refused(mode.verb, rootClass: rootClass, writable: writable) { return why }
        if let why = TerraformDrift.nothingToAccept(plan, mode: mode) { return why }
        if !plan.applyable || plan.errored { return plan.errored ? "The plan errored: it can't be applied." : "Terraform says this plan can't be applied." }
        if !plan.complete, rootClass == .production {
            return "A partial plan (-target, or deferred changes) isn't applied on production: plan the whole root."
        }
        if plan.partlyUnderstood {
            return "Partly understood: Overterm doesn't read \(plan.unknownKeys.joined(separator: ", ")) — apply it in a terminal."
        }
        if devOverrides { return "Provider development overrides are in effect: a provider no lock file checks. Apply it in a terminal." }
        if let staleReason { return "Stale: \(staleReason)" }
        if let busy { return busy }
        return nil
    }

    /// Why a root's class rose since its plan, or nil (5.1, 5.13 rule
    /// 12): a plan made as `local` is never applied as production — no
    /// switch, no name typed. Planned again, from the panel, which asks.
    static func risen(name: String, planned: TerraformClass, now: TerraformClassifier.Verdict?) -> String? {
        guard let now, now.rootClass > planned else { return nil }
        return "\(name) is \(now.rootClass.title.lowercased()) now (\(now.reason)), not \(planned.title.lowercased()) as when it was planned: plan it again from the panel, which asks first."
    }

    /// 5.4 in order, over what was read now.
    static func check(_ facts: TerraformApplyFacts) -> Verdict {
        let plan = facts.plan
        // The class now, never only the plan's (5.1).
        if let why = risen(name: facts.rootName, planned: facts.rootClass, now: facts.classNow) { return .refused(why) }
        // 0. Writable at all (5.3).
        if let why = TerraformProcessCheck.refused(facts.mode.verb, rootClass: facts.rootClass, writable: facts.writable) {
            return .refused(why)
        }
        if let why = TerraformDrift.nothingToAccept(plan, mode: facts.mode) { return .refused(why) }
        // 1. Applyable; partial refused on production.
        if !plan.applyable || plan.errored {
            return .refused(plan.errored ? "The plan errored: it can't be applied." : "Terraform says this plan can't be applied.")
        }
        if !plan.complete, facts.rootClass == .production {
            return .refused("A partial plan (-target, or deferred changes) isn't applied on production: plan the whole root.")
        }
        // 2. Same plan: the descriptor still holds what was hashed.
        guard let sha = facts.descriptorSHA, sha == facts.recordSHA else {
            return .refused("The plan file isn't the one shown (its hash changed): plan again.")
        }
        // 3. Same place: binary, version, workspace, data dir, environment, lock file.
        guard let binary = facts.binaryNow, binary == facts.recordBinary else {
            return .refused("The terraform this root resolves to is now \(facts.binaryNow ?? "none"), not \(facts.recordBinary), which made the plan: plan again.")
        }
        if let made = facts.recordVersion, let now = facts.versionNow, made != now {
            return .refused("\(binary) is now Terraform \(now), not \(made), which made the plan: plan again.")
        }
        if facts.recordVersion != nil, facts.versionNow == nil {
            return .refused("\(binary) didn't say its version: plan again once it does.")
        }
        if let why = facts.workspaceRefusal { return .refused(why) }
        if let now = facts.dataDirNow, now != facts.recordDataDir {
            return .refused("The root's data dir is now \(now), not \(facts.recordDataDir): plan again.")
        }
        guard let environment = facts.environmentNow else { return .refused("The environment for terraform couldn't be read.") }
        let changed = changedNames(facts.recordEnvironment, environment)
        if !changed.isEmpty {
            let named = changed.prefix(8).joined(separator: ", ") + (changed.count > 8 ? " and \(changed.count - 8) more" : "")
            return .refused("The environment changed since the plan (\(named)): plan and apply run in one environment — plan again.")
        }
        // No lock file is one that pins nothing: a plan of builtin
        // providers only carries init's header, its root no file — or one
        // naming no provider either.
        let pinsNothingNow = facts.lockSHANow == nil || facts.lockPinsNothingNow
        let sameLock = facts.lockSHANow == facts.zipLockSHA || (pinsNothingNow && (facts.zipLockSHA == nil || facts.zipLockPinsNothing))
        if !sameLock {
            return .refused("The lock file changed since the plan: providers aren't the ones planned with — plan again.")
        }
        // 4. Understood.
        if plan.partlyUnderstood {
            return .refused("Partly understood: Overterm doesn't read \(plan.unknownKeys.joined(separator: ", ")) — apply it in a terminal.")
        }
        if facts.devOverrides { return .refused("Provider development overrides are in effect: apply it in a terminal.") }
        // 5, 6. Age, and no write to this state since.
        if let stale = facts.staleReason { return .refused("Stale: \(stale)") }
        if let busy = facts.busy { return .refused(busy) }
        // 7. Version: a newer minor moves the state (asked, 3.8).
        let move = movesState(root: facts.rootName, planVersion: plan.terraformVersion, priorVersion: plan.priorStateVersion)
        // 8. State exists.
        // A refresh-only plan creates nothing: it records what is there (2d).
        let everything = !facts.mode.isRefreshOnly && createsEverything(plan: plan, workspace: facts.recordWorkspace, stateElsewhere: facts.stateElsewhere)
        // 9. The risk list is the sheet's.
        let typed = facts.rootClass == .production || facts.mode.isDestroy || everything
        return .ask(typed: typed, versionMove: move, partial: !plan.complete, createsEverything: everything)
    }

    /// The names whose values differ between two environments, sorted:
    /// never a value.
    static func changedNames(_ a: [String: String], _ b: [String: String]) -> [String] {
        Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.sorted()
    }

    /// "Creates everything: no state found" (3.7): no prior state on a
    /// workspace that isn't `default`, or on a root whose state is in
    /// another worktree.
    static func createsEverything(plan: TerraformPlan, workspace: String, stateElsewhere: String?) -> Bool {
        !plan.hasPriorState && (workspace != "default" || stateElsewhere != nil)
    }

    /// (major, minor) of `1.17.1`.
    static func minor(_ version: String?) -> (Int, Int)? {
        guard let version else { return nil }
        let parts = version.trimmingCharacters(in: CharacterSet(charactersIn: "v ")).split(separator: ".")
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1].prefix { $0.isNumber }) else { return nil }
        return (major, minor)
    }

    /// 3.8's sentence when the plan's Terraform is a newer minor than the
    /// state's (D-18), else nil.
    static func movesState(root: String, planVersion: String?, priorVersion: String?) -> String? {
        guard let made = minor(planVersion), let prior = minor(priorVersion), made > prior else { return nil }
        let name = root.isEmpty ? "this root" : root
        return "This moves the state of \(name) to Terraform \(made.0).\(made.1); anyone on \(prior.0).\(prior.1) can no longer plan it."
    }
}

/// The apply's confirmation (5.4, 6.4): root, worktree, branch @ commit,
/// workspace, backend and class, red on production; the counts; every
/// destroy, replace, forget and action by address (the first 50 here,
/// escaped — a `for_each` key can hold bidi or zero-width characters);
/// risky updates, labelled a heuristic; what the code runs or reaches;
/// the profile and region of the run's environment (names); the exact
/// command. The root's name typed on every production apply, a destroy
/// and "creates everything" (D-21). Pure.
struct TerraformApplySheet: Equatable, Sendable {
    var title: String
    var scope: String
    var production: Bool
    var detail: String
    /// The name to type, or nil.
    var typedName: String?
    var button: String
    /// 3.8's sentence, confirmed on its own after this one (D-18).
    var versionMove: String?

    struct Root: Sendable {
        var name: String
        var path: String
        var rootClass: TerraformClass
        var backend: String
        var workspace: String
        var worktree: String
        var branch: String?
    }

    static let shownAddresses = 50

    /// What is typed: the root's name, `@<workspace>` when it isn't `default`.
    static func typedName(root: String, workspace: String) -> String {
        workspace == "default" ? root : "\(root)@\(workspace)"
    }

    static func make(
        root: Root, plan: TerraformPlan, mode: TerraformPlanMode, typed: Bool, versionMove: String?, partial: Bool, createsEverything: Bool,
        risks: [String], profile: String?, region: String?
    ) -> TerraformApplySheet {
        if mode.isRefreshOnly {
            return TerraformDrift.acceptSheet(root: root, plan: plan, typed: typed, versionMove: versionMove, risks: risks, profile: profile, region: region)
        }
        let production = root.rootClass == .production
        let scope =
            "\(root.rootClass.title.uppercased()) · \(root.name) · workspace \(root.workspace) · \(root.backend)"
        var lines: [String] = []
        lines.append("Worktree \(root.worktree)" + (root.branch.map { " · \($0)" } ?? ""))
        lines.append(plan.counts.sentence.replacingOccurrences(of: "Plan: ", with: "Changes: ") + "  " + plan.counts.bar)
        if let label = mode.label { lines.append("This is a \(label) plan.") }
        if partial, !mode.isDestroy { lines.append("Partial: only what -target named, or with changes deferred — the rest isn't applied.") }
        if createsEverything {
            lines.append(
                "Creates everything: no state found" + (root.workspace == "default" ? "" : " in workspace \(root.workspace)") + " — check this is the state you mean.")
        }
        let destructive = plan.resourceChanges.filter(\.isRisky)
        if !destructive.isEmpty || !plan.actions.isEmpty {
            lines.append("")
            lines.append("Destroyed, replaced, forgotten, invoked (\(destructive.count + plan.actions.count)):")
            for change in destructive.prefix(shownAddresses) {
                lines.append("  \(symbol(change.action)) \(TerraformPlanText.escaped(change.address))  \(change.action.rawValue)")
            }
            for action in plan.actions.prefix(max(0, shownAddresses - destructive.count)) {
                lines.append("  ⚡ \(TerraformPlanText.escaped(action.address))  action")
            }
            let shown = min(destructive.count + plan.actions.count, shownAddresses)
            if destructive.count + plan.actions.count > shown { lines.append("  … and \(destructive.count + plan.actions.count - shown) more") }
        }
        let updates = riskyUpdates(plan)
        if !updates.isEmpty {
            lines.append("")
            lines.append("Risky updates (a heuristic):")
            for update in updates.prefix(shownAddresses) { lines.append("  ~ \(update)") }
        }
        if !risks.isEmpty {
            lines.append("")
            lines.append("Its code: " + risks.joined(separator: "; "))
        }
        var environment: [String] = []
        if let profile { environment.append("AWS_PROFILE \(profile)") }
        if let region { environment.append("region \(region)") }
        if !environment.isEmpty { lines.append("The plan's environment: " + environment.joined(separator: " · ")) }
        lines.append("")
        lines.append("In \(root.path.isEmpty ? "." : root.path): terraform " + TerraformCommands.apply.joined(separator: " "))
        lines.append("Runs on its own, outside this window: quitting Overterm doesn't stop it; Stop does, gracefully.")
        if typed { lines.append("Type \(typedName(root: root.name, workspace: root.workspace)) to apply.") }
        let title =
            mode.isDestroy
            ? "Destroy everything in \(root.name)?" : production ? "Apply this plan to production \(root.name)?" : "Apply this plan to \(root.name)?"
        return TerraformApplySheet(
            title: title, scope: scope, production: production, detail: lines.joined(separator: "\n"),
            typedName: typed ? typedName(root: root.name, workspace: root.workspace) : nil, button: mode.isDestroy ? "Destroy" : "Apply",
            versionMove: versionMove)
    }

    static func symbol(_ action: TerraformPlan.Action) -> String {
        switch action {
        case .create: "+"
        case .update: "~"
        case .delete: "-"
        case .replace: "±"
        case .forget: "⊘"
        case .read: "≤"
        case .noop: "·"
        }
    }

    /// Attribute names whose change in place can be the worst one (5.4).
    static let riskyNames = ["deletion_protection", "force_destroy", "skip_final_snapshot", "prevent_destroy", "ingress", "cidr_blocks"]

    /// Whether `value` holds the string `text` anywhere in it, bounded.
    static func holds(_ value: TerraformValue, _ text: String, depth: Int = 0) -> Bool {
        guard depth < 32 else { return false }
        switch value {
        case .string(let string): return string == text
        case .list(let items): return items.prefix(2_000).contains { holds($0, text, depth: depth + 1) }
        case .object(let fields): return fields.values.contains { holds($0, text, depth: depth + 1) }
        default: return false
        }
    }

    /// Updates in place that read as risky: protection turned off, a
    /// policy changed, an ingress or a CIDR open to the world. By name,
    /// a heuristic, labelled one.
    static func riskyUpdates(_ plan: TerraformPlan) -> [String] {
        var found: [String] = []
        for change in plan.resourceChanges where change.action == .update {
            let paths = change.changedPaths.map { $0.lowercased() }
            var why: [String] = []
            for name in riskyNames where paths.contains(where: { $0 == name || $0.hasPrefix(name + ".") || $0.hasSuffix("." + name) || $0.contains("." + name + ".") }) {
                why.append(name)
            }
            if paths.contains(where: { $0.contains("policy") }) { why.append("policy") }
            if (paths.contains { $0.contains("cidr") || $0.contains("ingress") }), let after = change.after, holds(after, "0.0.0.0/0") || holds(after, "::/0") {
                why.append("open to 0.0.0.0/0")
            }
            if !why.isEmpty {
                var unique: [String] = []
                for item in why where !unique.contains(item) { unique.append(item) }
                found.append("\(TerraformPlanText.escaped(change.address)): \(unique.joined(separator: ", "))")
            }
        }
        return found
    }
}
