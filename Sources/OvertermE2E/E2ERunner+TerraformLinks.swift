#if E2E
import AppKit

/// P15 (Overcraft-hq/issue-tracker#25): the Terraform flow's missing links
/// — var files chosen before a plan, a run that ends while nobody looks
/// said on its checkout's tab, the changes pane's roots with Plan, the
/// editor's bar naming its root. In the `terraformPlan` scenario, after
/// envs/dev planned with dev.tfvars.
extension E2ERunner {
    func terraformLinksChecks(checkout: URL, devCard: TerraformRootCard, prodCard: TerraformRootCard?, tab: Tab) async {
        // TF-U4: Var Files… — the root's own .tfvars, ticked as chosen; None clears.
        var offered: ([String], [String])?
        app.terraformVarFilesRecorder = { choosable, current in
            offered = (choosable, current)
            return []
        }
        app.chooseTerraformVarFiles(devCard, checkout: checkout)
        check(
            "Var Files… lists the root's own and ticks the chosen", await eventually(5) { offered?.0 == ["dev.tfvars"] && offered?.1 == ["dev.tfvars"] },
            "\(String(describing: offered))")
        check("None clears the choice", await eventually(3) { TerraformRootStore.shared.varFiles(checkout: checkout, root: "envs/dev").isEmpty })
        app.terraformVarFilesRecorder = { _, _ in ["dev.tfvars", "../outside.tfvars"] }
        app.chooseTerraformVarFiles(devCard, checkout: checkout)
        check(
            "chosen again, only the root's own file is kept",
            await eventually(3) { TerraformRootStore.shared.varFiles(checkout: checkout, root: "envs/dev") == ["dev.tfvars"] })
        app.terraformVarFilesRecorder = nil

        // TF-U6: a plan's end said once, on the checkout's tab, in Overterm's words.
        var ends: [(TerraformRunEnd, Tab, Bool)] = []
        app.terraformRunEndRecorder = { ends.append(($0, $1, $2)) }
        defer { app.terraformRunEndRecorder = nil }
        // The scenario's failed plans marked it earlier (as they should): start clean.
        tab.activity.seen()
        app.planTerraformRoot(devCard, checkout: checkout)
        check("the plan's end is said", await eventually(40) { !ends.isEmpty }, "\(String(describing: app.terraformPlanPane.run?.phase))")
        if let (end, marked, looking) = ends.first {
            check("on the checkout's tab", marked === tab)
            check("in Overterm's words: the root, its workspace, the counts", end.text.hasPrefix("Plan of envs/dev @") && end.text.contains("±1") && !end.failed, end.text)
            check("its tab marked when nobody looked", looking || (tab.activity.mark == .done && tab.activity.note == end.text), "\(tab.activity)")
        }
        await pause(0.5)
        check("once", ends.count == 1, "\(ends.count)")

        // TF-G1: a changed file under envs/prod — the changes pane names the root, production red, with Plan.
        let prodMain = checkout.appendingPathComponent("envs/prod/main.tf")
        let kept = try? String(contentsOf: prodMain, encoding: .utf8)
        try? ((kept ?? "") + "# edited\n").write(to: prodMain, atomically: true, encoding: .utf8)
        await app.diff.refresh()
        app.rightPane.mode = .changes
        if app.diffItem?.isCollapsed == true { app.toggleDiff(nil) }
        app.readChangesTerraform()
        check(
            "the changes pane names the root they touch",
            await eventually(15) { self.app.changesTerraform.roots.contains { $0.path == "envs/prod" && $0.isProduction } },
            "\(app.changesTerraform.roots.map(\.path))")
        check("its line says so", TerraformChangesLine.summary(app.changesTerraform.roots).contains("envs/prod"))
        var asked: TerraformPlanGate.Question?
        app.terraformPlanQuestionRecorder = {
            asked = $0; return false
        }
        if let root = app.changesTerraform.roots.first(where: { $0.path == "envs/prod" }) { app.planChangedTerraformRoot(root) }
        check("its Plan is production's, asked first", await eventually(10) { asked?.production == true }, "\(String(describing: asked))")
        app.terraformPlanQuestionRecorder = nil
        if let kept { try? kept.write(to: prodMain, atomically: true, encoding: .utf8) }
        await app.diff.refresh()

        // TF-U5: envs/prod/main.tf in the editor — its bar names the root, workspace and class.
        app.openInEditor(prodMain)
        check(
            "the editor's bar knows the file's root",
            await eventually(15) {
                let roots = self.app.editor?.active?.terraform?.roots
                return roots?.roots.first?.path == "envs/prod" && roots?.roots.first?.isProduction == true && roots?.cards["envs/prod"]?.workspace != nil
            }, "\(app.editor?.active?.terraform?.roots.roots.map(\.path) ?? [])")
        _ = prodCard
    }
}
#endif
