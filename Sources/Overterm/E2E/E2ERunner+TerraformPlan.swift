import AppKit

/// Terraform stage 1d (docs/design/terraform/analysis.md 9): the plan in
/// the right slot, read as data. A plan whose variable has no value
/// offers the root's var files; with one chosen, the replace it plans is
/// red, its cause chain down to the tfvars line this branch changed, and
/// no sentinel — a sensitive variable's value, an unmarked password, a
/// token — anywhere in the model, the log, the summary or the accessibility
/// text, which shows ••••••; the plan file 0600 in a 0700 folder, held
/// by its descriptor, the folder empty after. A workspace that doesn't
/// exist is refused before any run. Init, the fetch list asked first. A
/// lock held on `FakeTerraformBackend` named — its holder, Ask Why. A
/// second worktree on the same state planned, then marked stale once the
/// first worktree's pane applies from the CLI. An agent's `tf_plan`:
/// asked once, `-lock-timeout=0s` and no var file, its status and
/// resource masked; production refused.
///
/// The real terraform (`OVERTERM_TERRAFORM`) behind the recording wrapper,
/// in the guarded environment, over checkouts this scenario writes,
/// `terraform_data` only, state local or on the fake http backend on
/// 127.0.0.1. Without one, SKIP, loudly.
extension E2ERunner {
    func terraformPlanScenario() async {
        guard case .variable(let binary) = AppEnvironment.terraformBinary else {
            print("E2E SKIP terraformPlan: no OVERTERM_TERRAFORM — the test names the installed terraform")
            return
        }
        guard let recorder = try? TerraformRecorder.make(in: out("terraform-plan-recorder"), target: binary) else {
            return check("the recording wrapper is made", false)
        }
        TerraformCLI.scenarioWrapper = recorder.wrapper
        defer { TerraformCLI.scenarioWrapper = nil }
        let backend = FakeTerraformBackend()
        guard (try? backend.start()) != nil else { return check("the fake backend listens", false) }
        defer { backend.stop() }

        let sentinels = ["acme-hunter2-SECRET", "tok-acme-123", "globex-BKPW"]
        let checkout = out("acme-plan")
        let worktree = out("acme-plan-bump")
        let files: [String: String] = [
            ".gitignore": ".terraform/\n*.tfstate\n*.tfstate.*\n*.tfplan\n",
            "envs/dev/main.tf": """
            variable "acme_name" {
              type = string
            }

            variable "acme_db_password" {
              type      = string
              sensitive = true
              default   = "\(sentinels[0])"
            }

            resource "terraform_data" "acme" {
              triggers_replace = var.acme_name
              input = {
                name     = var.acme_name
                password = "\(sentinels[1])"
                db       = var.acme_db_password
              }
            }

            output "acme_db" {
              value     = var.acme_db_password
              sensitive = true
            }

            """,
            "envs/dev/dev.tfvars": "# acme dev\nacme_name = \"acme-one\"\n",
            "envs/ghost/main.tf": "resource \"terraform_data\" \"acme\" {\n  input = \"acme-ghost\"\n}\n",
            "envs/prod/main.tf": "resource \"terraform_data\" \"acme\" {\n  input = \"acme-prod\"\n}\n",
            "envs/globex-sandbox/main.tf": """
            variable "globex_token" {
              type      = string
              sensitive = true
              default   = "\(sentinels[2])"
            }

            resource "terraform_data" "globex" {
              input = {
                name  = "globex"
                token = var.globex_token
              }
            }

            """,
            // A provisioner that waits: an apply typed in a pane long enough for the header to see it.
            "envs/shared/main.tf": backend.backendBlock("acme-shared")
                + "resource \"terraform_data\" \"acme\" {\n  input = \"acme-shared\"\n\n  provisioner \"local-exec\" {\n    command = \"sleep 5\"\n  }\n}\n",
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
            // The branch the change is committed on: main is its base.
            _ = try Git.runBlocking(git, ["checkout", "-q", "-b", "acme-change"], in: checkout, success: [0], timeout: 10)
        } catch {
            return check("the checkout is written", false, "\(error)")
        }
        defer { _ = try? Git.runBlocking(git, ["worktree", "remove", "--force", worktree.path], in: checkout, success: [0], timeout: 10) }

        // envs/dev's state, made by the CLI in the guarded environment; then
        // this branch changes the variable that forces a replace.
        let dev = checkout.appendingPathComponent("envs/dev", isDirectory: true)
        guard let cli = try? TerraformGuards.prepareScratch(at: out("terraform-plan-cli")) else { return check("the CLI's scratch", false) }
        let environment = cli.environment
        let log = out("terraform-plan-cli.log")
        let applied = await TerraformPanelModel.blocking {
            Self.terraformCLI(binary, ["apply", "-auto-approve", "-input=false", "-var-file=dev.tfvars"], in: dev, environment: environment, log: log)
        }
        check("envs/dev has its state, from the CLI", applied == 0 && FileManager.default.fileExists(atPath: dev.appendingPathComponent("terraform.tfstate").path))
        // Committed on the branch, nothing uncommitted: the changes pane's
        // default scope doesn't show it, and it is still this branch's (3.1).
        try? "# acme dev\nacme_name = \"acme-two\"\n".write(to: dev.appendingPathComponent("dev.tfvars"), atomically: true, encoding: .utf8)
        _ = try? Git.runBlocking(
            git, ["-c", "user.name=Acme", "-c", "user.email=acme@example.test", "commit", "-q", "-am", "acme-two"], in: checkout, success: [0], timeout: 10)

        let asked = Answers()
        app.terraformPlanQuestionRecorder = { question in
            asked.questions.append(question)
            return true
        }
        app.terraformCacheOfferRecorder = {
            asked.cacheOffers += 1
            return false
        }
        defer {
            app.terraformPlanQuestionRecorder = nil
            app.terraformCacheOfferRecorder = nil
            app.terraformBriefRecorder = nil
        }

        let panel = app.terraformPanel
        let pane = app.terraformPlanPane
        app.newTab(in: checkout)
        guard let mainTab = app.store.selected else { return check("the checkout's tab", false) }
        app.showTerraformPanel(nil)
        check(
            "the roots are listed",
            await eventually(15) { panel.roots.map(\.path) == ["envs/dev", "envs/ghost", "envs/globex-sandbox", "envs/prod", "envs/shared"] },
            "\(panel.roots.map(\.path)) \(panel.state)")
        guard let devCard = panel.roots.first(where: { $0.path == "envs/dev" }) else { return check("envs/dev", false) }
        check(
            "the branch's merge base with main is known", await eventually(15) { self.app.diff.comparison?.mergeBase != nil },
            "\(String(describing: app.diff.comparison))")
        check("dev.tfvars isn't uncommitted", !app.diff.files.contains { $0.path == "envs/dev/dev.tfvars" })
        // Nothing ran but `version -json`: no automatic plan, ever (5.5).
        check("no plan before the click", !recorder.calls().contains { $0.subcommand == "plan" })

        // 1. A variable with no value: the root's var files offered.
        app.planTerraformRoot(devCard)
        check("the plan takes the right slot", await eventually(5) { self.app.rightPane.mode == .terraformPlan && pane.run != nil })
        check("it fails: acme_name has no value", await eventually(30) { if case .failed = pane.run?.phase { true } else { false } }, "\(String(describing: pane.run?.phase))")
        guard let failed = pane.run else { return check("the failed run", false) }
        check("the missing variable is named", failed.missingVariables == ["acme_name"], "\(failed.missingVariables)")
        Self.accessibilityTree(true)
        defer { Self.accessibilityTree(false) }
        guard let root = app.window?.contentView else { return check("the window", false) }
        check("dev.tfvars is offered", await eventually(5) { Self.accessibilityPress("terraform.plan.varFile.dev.tfvars", in: root, press: false) })
        app.terraformPlanActions.chooseVarFiles(failed, ["dev.tfvars"])
        check("the choice is kept for the root", TerraformRootStore.shared.varFiles(checkout: checkout, root: "envs/dev") == ["dev.tfvars"])

        // 2. The plan, read as data.
        check(
            "planned with dev.tfvars", await eventually(40) { pane.run !== failed && pane.run?.phase == .planned },
            "\(String(describing: pane.run?.phase)) \(pane.run?.log.suffix(5) ?? [])")
        guard let run = pane.run, let plan = run.plan, let record = run.record else { return check("the plan", false) }
        check("one replace", plan.counts.replace == 1 && plan.counts.bar.hasPrefix("+0 ~0 -0 ±1"), plan.counts.bar)
        let rows = pane.rows
        check("risky first, red: terraform_data.acme replaced", rows.first?.address == "terraform_data.acme" && rows.first?.section == .risky, "\(rows.map(\.address))")
        check("its reason in words", rows.first?.what.contains("can't change in place") == true, rows.first?.what ?? "")
        check("the branch's lines, read from git: the committed tfvars line", run.changedLines["envs/dev/dev.tfvars"] == [2], "\(run.changedLines)")
        check(
            "its cause chain, to the tfvars line this branch changed, committed",
            await eventually(15) {
                guard let first = pane.rows.first else { return false }
                let links = pane.causes(first)
                return links.map(\.text) == ["triggers_replace", "var.acme_name", "envs/dev/dev.tfvars:2"] && links.last?.changed == true
            }, "\(pane.rows.first.map { pane.causes($0).map { "\($0.text)\($0.changed ? "*" : "")" } } ?? [])")
        check("the inputs named: the var file", run.varFiles == ["dev.tfvars"])
        check("the plan file was 0600, held by its descriptor", record.file.mode == 0o600 && record.file.sha256.count == 64, String(record.file.mode, radix: 8))
        check("the prior state's lineage and serial read from the plan", record.zip?.lineage?.isEmpty == false && record.zip?.serial != nil)
        let processFolder = AppEnvironment.terraformRunsBase.appendingPathComponent(TerraformRunFolder.name())
        var info = stat()
        check(
            "the plan folder is 0700 and empty after",
            stat(processFolder.path, &info) == 0 && info.st_mode & 0o777 == 0o700
                && ((try? FileManager.default.contentsOfDirectory(atPath: processFolder.path)) ?? ["?"]).isEmpty)
        let plans = recorder.calls().filter { $0.subcommand == "plan" }
        let planCall = plans.last
        check(
            "plan -input=false -json -detailed-exitcode -lock=true -lock-timeout=10s -out=… -var-file=dev.tfvars, at the root",
            planCall.map { TerraformCommands.isPlan($0.arguments) && $0.arguments.contains("-lock-timeout=10s") && $0.arguments.last == "-var-file=dev.tfvars" }
                == true && planCall?.cwd == realPath(dev), "\(planCall?.arguments ?? [])")
        check(
            "in the workspace it checked, with no call home",
            planCall?.values["TF_WORKSPACE"] == "default" && planCall?.values["CHECKPOINT_DISABLE"] == "1"
                && planCall?.values["TF_DATA_DIR"] == dev.appendingPathComponent(".terraform").path, "\(planCall?.values ?? [:])")
        check(
            "nothing that injects flags or logs values",
            planCall.map { call in !call.names.contains { TerraformEnvironment.isAlwaysRemoved($0) && $0 != "TF_WORKSPACE" && $0 != "TF_DATA_DIR" } } == true,
            "\(planCall?.names ?? [])")
        check(
            "read by show -json of its descriptor", recorder.calls().contains { $0.arguments == TerraformCommands.showPlanDescriptor && $0.cwd == realPath(dev) })
        check("no apply, no init by Overterm", !recorder.calls().contains { ["apply", "init", "destroy", "state"].contains($0.subcommand ?? "") })

        // The list's keys: a pressed row gives the list the keyboard; ↓ and ↩ there.
        pane.selected = nil
        pane.takeKeyboard()
        check(
            "a pressed row gives the plan's list the keyboard",
            await eventually(5) { self.app.window?.firstResponder is TerraformPlanKeyView }, "\(String(describing: app.window?.firstResponder))")
        if let keys = app.window?.firstResponder as? TerraformPlanKeyView, let window = app.window {
            func key(_ code: UInt16, _ characters: String) -> NSEvent? {
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            }
            if let down = key(125, "\u{F701}") { keys.keyDown(with: down) }
            check("↓ selects the first row", pane.selected == pane.rows.first?.id, "\(String(describing: pane.selected))")
            if let enter = key(36, "\r") { keys.keyDown(with: enter) }
            check("↩ opens its detail", pane.rows.first.map { pane.expanded.contains($0.id) } == true)
            keys.copy(nil)
            check("⌘C copies its address", NSPasteboard.general.string(forType: .string) == "terraform_data.acme")
        }

        // No sentinel: in the model, the log, the summary, what is drawn.
        pane.expanded = Set(pane.rows.map(\.id))
        let summary = TerraformPlanText.copySummary(plan, root: run.card.name, workspace: run.workspace, branch: run.branch, causes: pane.causeTexts())
        check("Copy summary has the replace and its cause", summary.contains("± terraform_data.acme") && summary.contains("envs/dev/dev.tfvars:2"), summary)
        var drawn = ""
        check(
            "the detail is drawn, masked",
            await eventually(5) {
                drawn = Self.accessibilityElement("terraform.plan", in: root)?.text ?? ""
                return drawn.contains("output.password ••••••") && drawn.contains("triggers_replace")
            }, drawn)
        let everywhere = [String(reflecting: plan), run.log.joined(separator: "\n"), summary, drawn]
        for sentinel in sentinels {
            check("never \(sentinel.prefix(6))…: model, log, summary, accessibility text", !everywhere.contains { $0.contains(sentinel) })
        }

        // 3. A workspace that doesn't exist: refused before anything runs.
        let ghost = checkout.appendingPathComponent("envs/ghost/.terraform", isDirectory: true)
        try? FileManager.default.createDirectory(at: ghost, withIntermediateDirectories: true)
        try? "acme-ghost\n".write(to: ghost.appendingPathComponent("environment"), atomically: true, encoding: .utf8)
        if let card = panel.roots.first(where: { $0.path == "envs/ghost" }) {
            let before = recorder.calls().count
            app.planTerraformRoot(card)
            check(
                "a missing workspace is refused",
                await eventually(10) {
                    if case .refused(let why) = pane.run?.phase { why.contains("acme-ghost no longer exists") } else { false }
                }, "\(String(describing: pane.run?.phase))")
            check("before any terraform ran there", !recorder.calls().dropFirst(before).contains { $0.cwd.hasSuffix("/envs/ghost") })
            check("said in the slot", await eventually(5) { Self.accessibilityPress("terraform.plan.refused", in: root, press: false) })
        } else {
            check("envs/ghost", false)
        }

        // 4. Init on the fake backend's root: the fetch list asked first.
        guard let shared = panel.roots.first(where: { $0.path == "envs/shared" }) else { return check("envs/shared", false) }
        let questions = asked.questions.count
        app.initTerraformRoot(shared)
        check(
            "init done", await eventually(30) { pane.run?.kind == .initialize && pane.run?.phase == .planned },
            "\(String(describing: pane.run?.phase)) \(pane.run?.log.suffix(4) ?? [])")
        check(
            "asked first, with -lockfile=readonly said",
            asked.questions.dropFirst(questions).first.map { $0.title == "Init envs/shared?" && $0.detail.contains("-lockfile=readonly") } == true)
        check("as init -input=false -json -lockfile=readonly", recorder.calls().contains { $0.arguments == TerraformCommands.initialize })

        // 5. A lock someone else holds, named.
        backend.holdLock("acme-shared", who: "ci@globex-runner-7")
        app.planTerraformRoot(shared)
        check(
            "the plan can't take the lock", await eventually(40) { pane.run?.kind == .plan && pane.run?.card.path == "envs/shared" && pane.run?.lock != nil },
            "\(String(describing: pane.run?.phase))")
        guard let locked = pane.run else { return check("the locked run", false) }
        check("its holder named", locked.lock?.who == "ci@globex-runner-7" && locked.lock?.said().hasPrefix("Locked by ci@globex-runner-7 since") == true, locked.lock?.said() ?? "")
        check("an apply, by Terraform 1.17.1", locked.lock?.operationWords == "an apply" && locked.lock?.version == "1.17.1")
        check(
            "said in the slot, with Wait for It",
            await eventually(5) {
                Self.accessibilityElement("terraform.plan.lock", in: root)?.text.contains("ci@globex-runner-7") == true
                    && Self.accessibilityPress("terraform.plan.wait", in: root, press: false)
            })
        let briefs = Briefs()
        app.terraformBriefRecorder = { briefs.all.append($0) }
        app.askWhy(run: locked)
        check(
            "Ask Why briefs the lock", await eventually(5) { briefs.all.last?.text.contains("ci@globex-runner-7") == true },
            briefs.all.last?.text ?? "none")
        backend.releaseLock("acme-shared")

        // 6. Two worktrees on one state: the second's plan, stale after the first applies.
        do {
            _ = try Git.runBlocking(git, ["worktree", "add", "-q", worktree.path, "-b", "acme-bump"], in: checkout, success: [0], timeout: 10)
        } catch {
            return check("the worktree is made", false, "\(error)")
        }
        app.newTab(in: worktree)
        check(
            "the panel follows the worktree", await eventually(15) { panel.checkout.map { self.realPath($0) } == self.realPath(worktree) && panel.state == .read && !panel.roots.isEmpty },
            panel.checkout?.path ?? "")
        guard let sharedB = panel.roots.first(where: { $0.path == "envs/shared" }) else { return check("the worktree's envs/shared", false) }
        check("the window lists the other worktree", await eventually(10) { !TerraformWorktree.others(self.app.worktrees.worktrees, of: worktree).isEmpty })
        app.initTerraformRoot(sharedB)
        check(
            "init there too",
            await eventually(30) {
                pane.run?.kind == .initialize && pane.run.map { self.realPath($0.checkout) } == self.realPath(worktree) && pane.run?.phase == .planned
            }, "\(String(describing: pane.run?.phase))")
        check("the plugin cache is offered once two worktrees have roots", asked.cacheOffers == 1, "\(asked.cacheOffers)")
        app.planTerraformRoot(sharedB)
        check(
            "the worktree's plan", await eventually(30) { pane.run?.kind == .plan && pane.run?.card.path == "envs/shared" && pane.run?.phase == .planned },
            "\(String(describing: pane.run?.phase)) \(pane.run?.log.suffix(4) ?? [])")
        guard let planB = pane.run else { return check("the plan in the worktree", false) }
        check("creates everything: the shared state is empty", planB.plan?.hasPriorState == false)
        check("not stale yet", planB.staleReason(.shared) == nil)
        // The first worktree's pane applies from the CLI — the person's own
        // terraform, typed: a cleared environment, the fake backend only.
        app.store.select(mainTab)
        let shell = mainTab.terminal
        check("the first worktree's shell is up", await eventually(15) { shell.shellReported })
        await pause(2.5)
        let line =
            "env -i HOME='\(cli.home.path)' TF_CLI_CONFIG_FILE='\(cli.cliConfig.path)' CHECKPOINT_DISABLE=1 PATH=/usr/bin:/bin "
            + "HTTP_PROXY=\(TerraformGuards.deadProxy) HTTPS_PROXY=\(TerraformGuards.deadProxy) NO_PROXY=127.0.0.1,localhost "
            + "'\(binary)' -chdir=envs/shared apply -auto-approve -input=false"
        shell.insertText(line)
        shell.pressReturn()
        check("the CLI's apply wrote the shared state", await eventually(40) { backend.state("acme-shared") != nil })
        check(
            "the worktree's plan is stale at once: applied from the other checkout",
            await eventually(20) { planB.staleReason(.shared)?.hasPrefix("applied from acme-plan at ") == true },
            "\(planB.staleReason(.shared) ?? "not stale"): writes \(TerraformRunRegistry.shared.stateWrites), the pane's last command "
                + "\(app.blocks(of: shell).ledger.lastFinished?.command ?? "none"), the plan's identity \(planB.identity?.description ?? "none")")
        app.showTerraformPlan(planB)
        check("said over the plan", await eventually(5) { Self.accessibilityPress("terraform.plan.stale", in: root, press: false) })

        // 7. An agent's tf_plan: asked once, no flag, masked.
        let tag = shell.processTag
        let agentQuestions = asked.questions.count
        let started = await mcpText("tf_plan", ["root": "envs/globex-sandbox"], pane: tag)
        guard let id = started.range(of: #"tf-[0-9a-f]{8}"#, options: .regularExpression).map({ String(started[$0]) }) else {
            return check("tf_plan starts a run", false, started)
        }
        check("the person was asked", asked.questions.dropFirst(agentQuestions).first?.title == "Let the agent plan envs/globex-sandbox?")
        check(
            "the agent's run plans", await eventually(40) { TerraformRunRegistry.shared.run(id: id)?.phase == .planned },
            "\(String(describing: TerraformRunRegistry.shared.run(id: id)?.phase))")
        let status = await mcpText("tf_run_status", ["id": id], pane: tag)
        check("tf_run_status says the plan", status.contains("planned") && status.contains("Plan: 1 to add"), status)
        let resource = await mcpText("tf_plan_resource", ["root": "envs/globex-sandbox", "address": "terraform_data.globex"], pane: tag)
        check("tf_plan_resource masks the token", resource.contains("••••••") || resource.contains("(sensitive)"), resource)
        let summaryText = await mcpText("tf_plan_summary", ["root": "envs/globex-sandbox"], pane: tag)
        for sentinel in sentinels {
            check("no \(sentinel.prefix(6))… in what the agent read", ![started, status, resource, summaryText].contains { $0.contains(sentinel) })
        }
        let agentCall = recorder.calls().last { $0.subcommand == "plan" && $0.cwd.hasSuffix("/envs/globex-sandbox") }
        check(
            "the agent's plan: -lock-timeout=0s, no var file",
            agentCall.map { $0.arguments.contains("-lock-timeout=0s") && !$0.arguments.contains { $0.hasPrefix("-var-file") } } == true,
            "\(agentCall?.arguments ?? [])")
        let again = asked.questions.count
        _ = await mcpText("tf_plan", ["root": "envs/globex-sandbox"], pane: tag)
        check("asked once per root and session", asked.questions.count == again)
        let refused = await mcpText("tf_plan", ["root": "envs/prod"], pane: tag)
        check("production is the person's to plan", refused.contains("is production"), refused)
        let why = await mcpText("tf_why", ["root": "envs/shared"], pane: tag)
        check("tf_why briefs the lock that stopped a plan", why.contains("ci@globex-runner-7"), why)
        check("no apply by Overterm, ever", !recorder.calls().contains { $0.subcommand == "apply" })
    }

    /// A tool's text answer, as an agent reads it.
    private func mcpText(_ name: String, _ arguments: [String: Any], pane: String) async -> String {
        guard let result = try? await TerraformMCP.call(name, arguments, pane: pane) else { return "(threw)" }
        let content = result["content"] as? [[String: Any]] ?? []
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// The real terraform, in a scratch environment, its output to `log`. Blocking, briefly.
    nonisolated static func terraformCLI(_ binary: String, _ arguments: [String], in folder: URL, environment: [String: String], log: URL) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = environment
        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: log) else { return -1 }
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        try? handle.close()
        return process.terminationStatus
    }

    @MainActor private final class Answers {
        var questions: [TerraformPlanGate.Question] = []
        var cacheOffers = 0
    }

    @MainActor private final class Briefs {
        var all: [TerraformAgentBrief] = []
    }
}
