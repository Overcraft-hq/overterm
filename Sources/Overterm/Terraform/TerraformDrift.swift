import Foundation

/// Drift (analysis 2.6, stage 2d): "Check Drift" is Overterm's plan with
/// `-refresh-only` (`TerraformPlanMode.refreshOnly`) — locked like any
/// plan, run on the person's click, never on a timer (D-14) — whose
/// `resource_drift` and changed outputs are what the providers read now
/// against the state. Its apply, "Accept into State", writes the state
/// and nothing else (`TerraformVerb.refreshOnlyApply`: refused on a
/// read-only root, asked everywhere, the root's name typed on
/// production). A check's age is always said, and once the state was
/// written or its files changed since, its count is said as then, never
/// as now. Pure.
enum TerraformDrift {
    /// The outputs a refresh-only plan changes.
    static func changedOutputs(_ plan: TerraformPlan) -> [TerraformPlan.OutputChange] {
        plan.outputs.filter { !$0.actions.isEmpty && $0.actions != ["no-op"] }
    }

    /// What a check found: objects changed outside Terraform, and outputs.
    static func count(_ plan: TerraformPlan) -> Int { plan.drift.count + changedOutputs(plan).count }

    /// "2 objects changed outside Terraform, 1 output", or "no drift".
    static func said(_ plan: TerraformPlan) -> String {
        let objects = plan.drift.count
        let outputs = changedOutputs(plan).count
        guard objects + outputs > 0 else { return "no drift" }
        var parts: [String] = []
        if objects > 0 { parts.append("\(objects) object\(objects == 1 ? "" : "s") changed outside Terraform") }
        if outputs > 0 { parts.append("\(outputs) output\(outputs == 1 ? "" : "s") changed") }
        return parts.joined(separator: ", ")
    }

    /// Why a refresh-only plan has nothing to accept, or nil.
    static func nothingToAccept(_ plan: TerraformPlan, mode: TerraformPlanMode) -> String? {
        guard mode.isRefreshOnly, !plan.errored, !plan.applyable else { return nil }
        return "No drift to accept: the state already matches what the providers read."
    }

    /// The root card's line about its last check.
    struct Line: Equatable, Sendable {
        var text: String
        /// Drift found and current: said in the drift colour.
        var drifted: Bool
        /// The state or the files moved since: what it found was then.
        var stale: Bool
    }

    /// The card's line: its age always; a stale check's count as then.
    static func line(phase: TerraformPlanRun.Phase, plan: TerraformPlan?, age: String, stale: String?) -> Line {
        switch phase {
        case .preparing, .waiting, .running:
            return Line(text: "Checking drift…", drifted: false, stale: false)
        case .planned, .noChanges:
            let found = plan.map(said) ?? "no drift"
            let drifted = plan.map { count($0) > 0 } ?? false
            if let stale {
                return Line(text: "Drift checked \(age): \(found) then — \(stale)", drifted: false, stale: true)
            }
            return Line(text: (drifted ? "Drift: \(found)" : "No drift") + " · checked \(age)", drifted: drifted, stale: false)
        case .failed(let why), .refused(let why):
            return Line(text: "Drift check failed \(age): \(TerraformPlanText.cut(why, to: 160))", drifted: false, stale: true)
        case .stopped:
            return Line(text: "Drift check stopped \(age)", drifted: false, stale: true)
        case .tooLarge:
            return Line(text: "Drift checked \(age): too large to show", drifted: false, stale: true)
        }
    }

    /// "Accept into State"'s confirmation (2.6, 5.4): the drift by
    /// address (the first 50, escaped), the outputs that change, that it
    /// writes the state and changes no infrastructure — and that the next
    /// plan proposes to change it back unless the code changes too — and,
    /// as on every apply sheet (5.4 item 9), what its code runs: the apply
    /// still configures and starts the providers with your credentials.
    static func acceptSheet(
        root: TerraformApplySheet.Root, plan: TerraformPlan, typed: Bool, versionMove: String?, risks: [String], profile: String?, region: String?
    ) -> TerraformApplySheet {
        let production = root.rootClass == .production
        let scope = "\(root.rootClass.title.uppercased()) · \(root.name) · workspace \(root.workspace) · \(root.backend)"
        var lines: [String] = []
        lines.append("Worktree \(root.worktree)" + (root.branch.map { " · \($0)" } ?? ""))
        lines.append("Accepting \(said(plan)): the state records what the providers read now.")
        lines.append("It writes the state only — no infrastructure changes. Where the configuration says otherwise, the next plan proposes to change it back.")
        if !plan.drift.isEmpty {
            lines.append("")
            lines.append("Changed outside Terraform (\(plan.drift.count)):")
            for change in plan.drift.prefix(TerraformApplySheet.shownAddresses) {
                let what = change.action == .delete ? "deleted outside Terraform: the state forgets it" : change.action.rawValue
                lines.append("  ⚠ \(TerraformPlanText.escaped(change.address))  \(what)")
            }
            if plan.drift.count > TerraformApplySheet.shownAddresses { lines.append("  … and \(plan.drift.count - TerraformApplySheet.shownAddresses) more") }
        }
        let outputs = changedOutputs(plan)
        if !outputs.isEmpty {
            lines.append("Outputs: " + outputs.prefix(20).map { TerraformPlanText.escaped($0.name) + ($0.sensitive ? " (sensitive)" : "") }.joined(separator: ", "))
        }
        if !risks.isEmpty {
            lines.append("")
            lines.append("Its code: " + risks.joined(separator: "; "))
        }
        var environment: [String] = []
        if let profile { environment.append("AWS_PROFILE \(profile)") }
        if let region { environment.append("region \(region)") }
        if !environment.isEmpty { lines.append("The check's environment: " + environment.joined(separator: " · ")) }
        lines.append("")
        lines.append("In \(root.path.isEmpty ? "." : root.path): terraform " + TerraformCommands.apply.joined(separator: " ") + "  (the refresh-only plan shown)")
        lines.append("Runs on its own, outside this window: quitting Overterm doesn't stop it; Stop does, gracefully.")
        if typed { lines.append("Type \(TerraformApplySheet.typedName(root: root.name, workspace: root.workspace)) to accept.") }
        return TerraformApplySheet(
            title: production ? "Accept the drift into production \(root.name)'s state?" : "Accept the drift into \(root.name)'s state?", scope: scope,
            production: production, detail: lines.joined(separator: "\n"),
            typedName: typed ? TerraformApplySheet.typedName(root: root.name, workspace: root.workspace) : nil, button: "Accept into State",
            versionMove: versionMove)
    }
}

extension TerraformPlanRun {
    /// The card's and the slot's drift line at `now`: drawn on a clock
    /// (`TimelineView`), so its age moves and a check past 30 minutes is
    /// said stale even when nothing else redraws it.
    func driftLine(_ registry: TerraformRunRegistry, now: Date = Date()) -> TerraformDrift.Line {
        TerraformDrift.line(phase: phase, plan: plan, age: age(now: now), stale: staleReason(registry, now: now, held: false))
    }
}

extension TerraformPlanMode {
    /// The verb its apply is checked as (5.3): a refresh-only plan's
    /// writes the state alone.
    var verb: TerraformVerb { isRefreshOnly ? .refreshOnlyApply : .apply }
}
