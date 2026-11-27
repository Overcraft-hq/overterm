import Foundation

/// What a Terraform run that ended says to someone not looking (TF-U6): a
/// tab's mark and one notification. Overterm's own words only — the root,
/// its workspace, the plan's counts — never terraform's output, which can
/// carry a value it marks sensitive. Pure.
package struct TerraformRunEnd: Equatable, Sendable {
    package var text: String
    package var failed: Bool

    /// A plan's, a drift check's or an init's end; nil while it runs, and
    /// for one stopped or refused — the person did that, or was told.
    package static func plan(_ phase: TerraformPlanRun.Phase, root: String, workspace: String, kind: TerraformPlanRun.Kind, refreshOnly: Bool, counts: String?)
        -> TerraformRunEnd?
    {
        let what = kind == .initialize ? "Init of \(root)" : refreshOnly ? "Drift check of \(root)" : "Plan of \(root)"
        let place = "\(what) @\(workspace)"
        switch phase {
        case .planned:
            if kind == .initialize { return TerraformRunEnd(text: "\(place) done", failed: false) }
            return TerraformRunEnd(text: "\(place): " + (counts ?? "planned"), failed: false)
        case .noChanges: return TerraformRunEnd(text: refreshOnly ? "\(place): no drift" : "\(place): no changes", failed: false)
        case .tooLarge: return TerraformRunEnd(text: "\(place): planned, too large to show", failed: false)
        case .failed: return TerraformRunEnd(text: "\(place) failed", failed: true)
        case .preparing, .waiting, .running, .refused, .stopped: return nil
        }
    }

    package static func apply(_ phase: TerraformApplyRun.Phase, root: String, workspace: String) -> TerraformRunEnd? {
        switch phase {
        case .applied: TerraformRunEnd(text: "Apply of \(root) @\(workspace) done", failed: false)
        case .failed: TerraformRunEnd(text: "Apply of \(root) @\(workspace) failed", failed: true)
        case .stopped: TerraformRunEnd(text: "Apply of \(root) @\(workspace) stopped", failed: true)
        case .running, .stopping: nil
        }
    }

    package static func test(_ phase: TerraformTestRun.Phase, root: String) -> TerraformRunEnd? {
        switch phase {
        case .passed: TerraformRunEnd(text: "Tests of \(root) passed", failed: false)
        case .failed: TerraformRunEnd(text: "Tests of \(root) failed", failed: true)
        case .preparing, .running, .refused, .stopped: nil
        }
    }
}
