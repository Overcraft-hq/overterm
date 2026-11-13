import AppKit

/// Terraform stage 2a (docs/design/terraform/analysis.md 9): the apply,
/// with every guard. A local root's plan applied — the sheet asks, no name
/// typed; the apply is `apply … /dev/fd/3` in the plan's environment, a
/// hostile `TF_CLI_ARGS_apply`/`TF_CLI_ARGS`/`TF_LOG` never reaching it;
/// the plan's descriptor dropped; nothing of the sensitive variable in its
/// log. A destroy plan asks for the root's name. `envs/prod` refused while
/// `terraform.roots` sets it `writable: false`; without that, applied with
/// no switch, the name typed — a wrong one refused. A remote root set
/// `writable: false` refused, then writable again. A pane
/// where the real terraform applies: closing the pane, the window or the
/// tab asks; Interrupt leaves the resource tainted and the lock free. An
/// apply whose record is lost (the app's "crash") is found again by its
/// pid and followed to its end.
///
/// The real terraform (`OVERTERM_TERRAFORM`) behind the recording wrapper,
/// in the guarded environment, over a checkout this scenario writes,
/// `terraform_data` only, state local or on the fake http backend on
/// 127.0.0.1. Without one, SKIP, loudly.
extension E2ERunner {
    func terraformApplyScenario() async {
        guard case .variable(let binary) = AppEnvironment.terraformBinary else {
            print("E2E SKIP terraformApply: no OVERTERM_TERRAFORM — the test names the installed terraform")
            return
        }
        guard let recorder = try? TerraformRecorder.make(in: out("terraform-apply-recorder"), target: binary) else {
            return check("the recording wrapper is made", false)
        }
        TerraformCLI.scenarioWrapper = recorder.wrapper
        // A hostile shell: what would skip the shown plan's guards.
        TerraformCLI.scenarioEnvironment = ["TF_CLI_ARGS_apply": "-lock=false", "TF_CLI_ARGS": "-auto-approve", "TF_LOG": "trace"]
        defer {
            TerraformCLI.scenarioWrapper = nil
            TerraformCLI.scenarioEnvironment = [:]
        }
        let backend = FakeTerraformBackend()
        guard (try? backend.start()) != nil else { return check("the fake backend listens", false) }
        defer { backend.stop() }

        let sentinel = "acme-hunter2-SECRET"
        let checkout = out("acme-apply")
        let files: [String: String] = [
            ".gitignore": ".terraform/\n*.tfstate\n*.tfstate.*\n",
            "envs/globex-sandbox/main.tf": """
            variable "globex_password" {
              type      = string
              sensitive = true
              default   = "\(sentinel)"
            }

            resource "terraform_data" "globex" {
              input = {
                name     = "globex"
                password = var.globex_password
              }
            }

            output "globex_name" {
              value = "globex"
            }

            """,
            "envs/prod/main.tf": "resource \"terraform_data\" \"acme\" {\n  input = \"acme-prod\"\n}\n",
            // A provisioner that waits: long enough to close over, and to
            // lose the record of. It prints a sensitive value in clear: the
            // plan's marks don't reach its output, the plan's values mask
            // it (5.6) — after a relaunch too, from the run folder's digests.
            "envs/shared/main.tf": backend.backendBlock("acme-shared")
                + "variable \"globex_token\" {\n  type      = string\n  sensitive = true\n  default   = \"\(sentinel)\"\n}\n\n"
                + "resource \"terraform_data\" \"acme\" {\n  input = \"acme-shared\"\n\n  provisioner \"local-exec\" {\n"
                + "    command = \"echo globex-${nonsensitive(var.globex_token)}; sleep 12\"\n  }\n}\n",
        ]
        let git = URL(fileURLWithPath: "/usr/bin/git")
        do {
            for (path, text) in files {
                let url = checkout.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            _ = try Git.runBlocking(git, ["init", "-q", "-b", "main"], in: checkout, success: [0], timeout: 10)
            _ = try Git.runBlocking(git, ["add", "-A"], in: checkout, success: [0], timeout: 10)
            _ = try Git.runBlocking(
                git, ["-c", "user.name=Acme", "-c", "user.email=acme@example.test", "commit", "-q", "-m", "acme"], in: checkout, success: [0], timeout: 10)
        } catch {
            return check("the checkout is written", false, "\(error)")
        }

        let asked = ApplyAnswers()
        app.terraformPlanQuestionRecorder = { question in
            asked.planQuestions.append(question)
            return true
        }
        app.terraformCacheOfferRecorder = { false }
        app.terraformApplyQuestionRecorder = { sheet in
            asked.sheets.append(sheet)
            return asked.answers.isEmpty ? "" : asked.answers.removeFirst()
        }
        let settings = Settings.shared
        defer {
            app.terraformPlanQuestionRecorder = nil
            app.terraformCacheOfferRecorder = nil
            app.terraformApplyQuestionRecorder = nil
            settings.set("terraform.roots", nil)
        }

        let panel = app.terraformPanel
        let pane = app.terraformPlanPane
        let registry = TerraformRunRegistry.shared
        app.newTab(in: checkout)
        app.showTerraformPanel(nil)
        check(
            "the roots are listed", await eventually(15) { panel.roots.map(\.path) == ["envs/globex-sandbox", "envs/prod", "envs/shared"] },
            "\(panel.roots.map(\.path)) \(panel.state)")
        guard let sandbox = panel.roots.first(where: { $0.path == "envs/globex-sandbox" }), let prod = panel.roots.first(where: { $0.path == "envs/prod" }),
            let shared = panel.roots.first(where: { $0.path == "envs/shared" })
        else { return check("the three roots", false) }
        check("globex-sandbox is local, prod production, shared remote", sandbox.rootClass == .local && prod.isProduction && shared.rootClass == .remote)
        Self.accessibilityTree(true)
        defer { Self.accessibilityTree(false) }
        guard let root = app.window?.contentView else { return check("the window", false) }

        // 1. A local root: planned, applied — asked, no name typed.
        guard let local = await plan(sandbox, pane: pane) else { return check("the sandbox's plan", false) }
        check("Apply is offered", local.applyGreyed(registry, writable: true) == nil, local.applyGreyed(registry, writable: true) ?? "")
        check(
            "a root set writable: false is plan only", local.applyGreyed(registry, writable: false)?.contains("plan only") == true,
            local.applyGreyed(registry, writable: false) ?? "")
        let before = asked.sheets.count
        let outcome = await app.applyPlan(local)
        guard case .started(let apply) = outcome else { return check("the local apply starts", false, "\(outcome)") }
        let sheet = asked.sheets.dropFirst(before).first
        check("asked first, no name to type on a local root", sheet?.typedName == nil && sheet?.title == "Apply this plan to envs/globex-sandbox?", sheet?.title ?? "none")
        check(
            "the sheet names the command and the change",
            sheet.map { $0.detail.contains("terraform apply -input=false -json -lock=true -lock-timeout=60s /dev/fd/3") && $0.detail.contains("+1") } == true,
            sheet?.detail ?? "")
        check("the plan's descriptor goes with its record: applied once", local.record == nil && local.apply === apply)
        check(
            "the apply lands", await eventually(60) { if case .applied = apply.phase { true } else { false } },
            "\(apply.phase) \(apply.log.suffix(6))")
        check("its words: from the exit code and an apply summary", { if case .applied(let said) = apply.phase { said.hasPrefix("Apply complete — 1 added") } else { false } }())
        check("its row done", apply.rows.first.map { $0.address == "terraform_data.globex" && $0.state == .done } == true, "\(apply.rows)")
        let state = (try? String(contentsOf: checkout.appendingPathComponent("envs/globex-sandbox/terraform.tfstate"), encoding: .utf8)) ?? ""
        check("the state has it", state.contains("terraform_data") && state.contains("globex"))
        let applyCall = recorder.calls().last { $0.subcommand == "apply" }
        check(
            "apply -input=false -json -lock=true -lock-timeout=60s /dev/fd/3, at the root", applyCall?.arguments == TerraformCommands.apply && applyCall?.cwd == realPath(sandbox.folder),
            "\(applyCall?.arguments ?? [])")
        check(
            "the hostile shell never reached it",
            applyCall.map { !$0.names.contains("TF_CLI_ARGS_apply") && !$0.names.contains("TF_CLI_ARGS") && !$0.names.contains("TF_LOG") } == true,
            "\(applyCall?.names ?? [])")
        check("in the plan's workspace and data dir", applyCall?.values["TF_WORKSPACE"] == "default" && applyCall?.values["CHECKPOINT_DISABLE"] == "1")
        check("never the sensitive variable, in the apply's log", !apply.log.joined(separator: "\n").contains(sentinel))

        check("its run folder is gone", !FileManager.default.fileExists(atPath: apply.folder.path))
        check(
            "said in the slot",
            await eventually(5) { Self.accessibilityElement("terraform.apply.status", in: root)?.text.contains("Apply complete") == true },
            Self.accessibilityElement("terraform.apply.status", in: root)?.text ?? "none")
        check("not in a terminal: no apply typed anywhere", !recorder.calls().contains { $0.arguments.contains("-auto-approve") })

        // 2. A destroy plan: the root's name typed, on any class.
        app.planTerraformDestroy(sandbox)
        check("asked before a destroy plan", await eventually(5) { asked.planQuestions.last?.title == "Plan a destroy of envs/globex-sandbox?" })
        check(
            "the destroy is planned", await eventually(40) { pane.run?.mode == .destroy && pane.run?.phase == .planned },
            "\(String(describing: pane.run?.phase))")
        if let destroy = pane.run {
            check("plan … -destroy", recorder.calls().last { $0.subcommand == "plan" }?.arguments.contains("-destroy") == true)
            asked.answers = ["envs/globex-sandbox"]
            let count = asked.sheets.count
            let goneOutcome = await app.applyPlan(destroy)
            guard case .started(let gone) = goneOutcome else { return check("the destroy starts", false, "\(goneOutcome)") }
            check("its name typed: envs/globex-sandbox", asked.sheets.dropFirst(count).first?.typedName == "envs/globex-sandbox")
            check("destroyed", await eventually(60) { if case .applied = gone.phase { true } else { false } }, "\(gone.phase)")
        }

        // 3. Production: plan only while its entry says writable: false;
        // without it, no switch — the name typed.
        guard let prodPlan = await plan(prod, pane: pane) else { return check("prod's plan", false) }
        check("asked before production's first plan", asked.planQuestions.contains { $0.production })
        settings.set("terraform.roots", .entries(["envs/prod": ["writable": .bool(false)]]))
        if case .refused(let why) = await app.applyPlan(prodPlan) {
            check("refused while terraform.roots sets it plan only", why.contains("plan only"), why)
        } else {
            check("refused while terraform.roots sets it plan only", false)
        }
        panel.selectedPath = "envs/prod"
        check(
            "the card says plan only",
            await eventually(5) { Self.accessibilityElement("terraform.panel.planOnly", in: root)?.text.contains("Plan only") == true }, "")
        settings.set("terraform.roots", nil)
        check(
            "its entry gone: no plan-only line, production's name asked instead — nothing to turn on",
            await eventually(5) {
                Self.accessibilityElement("terraform.panel.planOnly", in: root) == nil
                    && Self.accessibilityElement("terraform.panel.productionAsks", in: root)?.text.contains("each apply asks for the root's name") == true
            }, "")
        asked.answers = ["envs/pro"]
        if case .refused(let why) = await app.applyPlan(prodPlan) {
            check("a wrong name is refused", why.contains("wasn't envs/prod"), why)
        } else {
            check("a wrong name is refused", false)
        }
        check("the production sheet: red, the name asked", asked.sheets.last.map { $0.production && $0.typedName == "envs/prod" } == true)
        asked.answers = ["envs/prod"]
        if case .started(let prodApply) = await app.applyPlan(prodPlan) {
            check("production applied", await eventually(60) { if case .applied = prodApply.phase { true } else { false } }, "\(prodApply.phase)")
        } else {
            check("production applies with its name", false)
        }

        // 4. A pane where the real terraform applies: every close asks.
        app.initTerraformRoot(shared)
        check("envs/shared initialised", await eventually(40) { pane.run?.kind == .initialize && pane.run?.phase == .planned }, "\(String(describing: pane.run?.phase))")
        app.newTab(in: checkout)
        guard let cliTab = app.store.selected else { return check("a tab for the CLI", false) }
        app.split(nil, .right)
        guard cliTab.terminals.count == 2, let cliPane = cliTab.terminals.last else { return check("a split", false) }
        check("the pane's shell is up", await eventually(15) { cliPane.shellReported })
        await pause(1.5)
        guard let cli = try? TerraformGuards.prepareScratch(at: out("terraform-apply-cli")) else { return check("the CLI's scratch", false) }
        let line =
            "env -i HOME='\(cli.home.path)' TF_CLI_CONFIG_FILE='\(cli.cliConfig.path)' CHECKPOINT_DISABLE=1 PATH=/usr/bin:/bin "
            + "HTTP_PROXY=\(TerraformGuards.deadProxy) HTTPS_PROXY=\(TerraformGuards.deadProxy) NO_PROXY=127.0.0.1,localhost "
            + "'\(binary)' -chdir=envs/shared apply -auto-approve -input=false"
        cliPane.insertText(line)
        cliPane.pressReturn()
        var writes: [TerraformCloseGuard.Running] = []
        check(
            "the pane's terraform apply is found by pid",
            await eventually(20) {
                writes = self.app.terraformWrites(tabs: [cliTab], panes: [cliPane], path: .pane)
                return writes.first.map { $0.operation == "apply" && $0.root == "envs/shared" } == true
            }, "\(writes)")
        // In its provisioner: created, not yet done.
        await pause(3)
        guard let window = app.window else { return check("the window", false) }
        func sheetText() -> String {
            guard let sheet = window.attachedSheet else { return "" }
            return Self.texts(in: sheet.contentView).joined(separator: " ")
        }
        app.closePane(cliPane, in: cliTab)
        check("closing the pane asks", await eventually(3) { sheetText().contains("terraform apply is running in envs/shared (this pane)") }, sheetText())
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertThirdButtonReturn) }
        _ = await eventually(2) { window.attachedSheet == nil }
        check("Cancel keeps the pane", cliTab.terminals.contains { $0 === cliPane } && TerraformCloseGuard.anyAlive(writes))
        check("closing the window asks", app.windowShouldClose(window) == false)
        check("…naming the apply", await eventually(3) { sheetText().contains("Closing the window kills it") }, sheetText())
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertThirdButtonReturn) }
        _ = await eventually(2) { window.attachedSheet == nil }
        app.closeTabs([cliTab])
        check("closing the tab asks, whatever the setting", await eventually(3) { sheetText().contains("Closing the tab kills it") }, sheetText())
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check("Interrupt keeps the tab", app.store.tabs.contains { $0 === cliTab })
        check("terraform stops, gracefully", await eventually(40) { !TerraformCloseGuard.anyAlive(writes) })
        check("the lock is free", await eventually(10) { backend.heldLock("acme-shared") == nil })
        let tainted = backend.state("acme-shared").map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("the resource is left tainted, its state saved", tainted.contains("\"tainted\""), String(tainted.prefix(400)))
        check("then: it has stopped, said, with Close Now", await eventually(5) { sheetText().contains("has stopped in envs/shared") }, sheetText())
        check("…offering to close the tab", sheetText().contains("Close the tab now"), sheetText())
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        _ = await eventually(2) { window.attachedSheet == nil }
        check("Close Now finishes the close Interrupt held back", await eventually(5) { !self.app.store.tabs.contains { $0 === cliTab } })
        check("the header's shutting-down said no more", TerraformPaneMonitor.shared.shutting.isEmpty)

        // 5. A remote root: refused while set plan only; then the apply, the
        // app "killed" mid-way: its record lost, its run folder a crashed
        // launch's, found again by the launch's own sweep.
        guard let remotePlan = await plan(shared, pane: pane) else { return check("shared's plan", false) }
        check("the tainted resource is replaced", remotePlan.plan?.counts.replace == 1, remotePlan.plan?.counts.bar ?? "")
        settings.set("terraform.roots", .entries(["envs/shared": ["writable": .bool(false)]]))
        if case .refused(let why) = await app.applyPlan(remotePlan) {
            check("a root set writable: false is plan only", why.contains("writable to false"), why)
        } else {
            check("a root set writable: false is plan only", false)
        }
        settings.set("terraform.roots", .entries(["envs/shared": ["writable": .bool(true)]]))
        check("terraform.roots sets it writable", settings.terraformRoots["envs/shared"]?.writable == true)
        // A pid that is gone names the apply's process folder: a launch that crashed.
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        guard (try? gone.run()) != nil else { return check("a pid that is gone", false) }
        gone.waitUntilExit()
        TerraformRunFolder.crashedProcess = gone.processIdentifier
        let longOutcome = await app.applyPlan(remotePlan)
        TerraformRunFolder.crashedProcess = nil
        guard case .started(let long) = longOutcome else { return check("the remote apply starts", false, "\(longOutcome)") }
        check(
            "its run folder is the crashed launch's",
            long.folder.deletingLastPathComponent().lastPathComponent == TerraformRunFolder.name(pid: gone.processIdentifier), long.folder.path)
        check("its provisioner runs", await eventually(20) { long.rows.contains { $0.state == .running } }, "\(long.rows)")
        let pid = long.marker.pid
        registry.forgetApply(long)
        pane.clear()
        check("the record is lost, the apply goes on, detached", TerraformApplyMarker.liveNow(long.marker))
        // The relaunch: the launch's sweep, its reattach, as at startup.
        app.sweepTerraformRunsAtLaunch(again: true)
        check(
            "the launch's sweep finds it by its pid and start time, in the slot",
            await eventually(10) { pane.apply.map { $0.reattached && $0.marker.pid == pid } == true }, "\(String(describing: pane.apply?.marker))")
        check("its folder kept by the sweep", FileManager.default.fileExists(atPath: long.folder.path))
        guard let followed = pane.apply, followed.reattached else { return check("followed again", false) }
        check("said: started before Overterm last quit", await eventually(5) { Self.accessibilityPress("terraform.apply.reattached", in: root, press: false) })
        check("with Stop", await eventually(5) { Self.accessibilityPress("terraform.apply.stop", in: root, press: false) })
        panel.selectedPath = "envs/shared"
        check(
            "and on its root's card",
            await eventually(5) { Self.accessibilityPress("terraform.panel.apply.envs/shared", in: root, press: false) })
        check("followed to its end", await eventually(60) { if case .applied = followed.phase { true } else { false } }, "\(followed.phase) \(followed.log.suffix(4))")
        check(
            "the provisioner's output under its row, the plan's value masked after the relaunch",
            followed.rows.first.map { row in row.output.contains { $0.contains("globex-") } && !row.output.contains { $0.contains(sentinel) } } == true,
            "\(followed.rows.first?.output ?? [])")
        let drawnApply = await eventually(5) { Self.accessibilityElement("terraform.apply.row.terraform_data.acme", in: root)?.text.contains("globex-") == true }
        let applyText =
            (Self.accessibilityElement("terraform.apply.row.terraform_data.acme", in: root)?.text ?? "") + " "
            + (Self.accessibilityElement("terraform.plan", in: root)?.text ?? "")
        check("drawn, masked: no sentinel in the apply's accessibility text", drawnApply && !applyText.contains(sentinel), String(applyText.prefix(300)))
        check(
            "nor in its model or log, before or after the relaunch",
            ![String(reflecting: followed.rows), followed.log.joined(separator: "\n"), String(reflecting: long.rows), long.log.joined(separator: "\n")].contains {
                $0.contains(sentinel)
            })
        check("the lock is free after", backend.heldLock("acme-shared") == nil)
        check("no apply is left running", registry.goingApplies.isEmpty)
    }

    /// A root planned by the app, as a person's click does: the run once planned.
    private func plan(_ card: TerraformRootCard, pane: TerraformPlanPaneModel) async -> TerraformPlanRun? {
        let previous = pane.run
        app.planTerraformRoot(card)
        let planned = await eventually(40) { pane.run !== previous && pane.run?.card.path == card.path && pane.run?.phase == .planned }
        check("\(card.path) planned", planned, "\(String(describing: pane.run?.phase)) \(pane.run?.log.suffix(4) ?? [])")
        return planned ? pane.run : nil
    }

    /// Every label's text under `view`: what a sheet says.
    static func texts(in view: NSView?) -> [String] {
        guard let view else { return [] }
        var found: [String] = []
        if let field = view as? NSTextField { found.append(field.stringValue) }
        for child in view.subviews { found += texts(in: child) }
        return found
    }

    @MainActor private final class ApplyAnswers {
        var planQuestions: [TerraformPlanGate.Question] = []
        var sheets: [TerraformApplySheet] = []
        /// What the next sheets are answered: a name typed; "" when empty.
        var answers: [String] = []
    }
}
