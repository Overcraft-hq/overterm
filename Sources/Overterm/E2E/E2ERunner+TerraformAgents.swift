import AppKit

/// Terraform stage 1c (docs/design/terraform/analysis.md 9): guarding
/// agents. An agent tab's launch command in a checkout with a production
/// root carries the deny rules — recorded, never run — and Codex's says
/// it isn't guarded; a fake agent's permission prompt for `terraform
/// apply` on envs/prod marks its tab, the Inbox shows it with no answer,
/// and Overterm types nothing when asked to answer it; the mark goes with
/// the prompt. A plan saved with the real terraform (offline, a cleared
/// environment) read through `tf_plan_summary` with its sentinel absent;
/// `tf_roots`, `tf_validate`; Ask Why on a failed validate hands the brief.
///
/// The real terraform (`OVERTERM_TERRAFORM`) behind the recording wrapper,
/// `terraform_data` only. Without one, SKIP, loudly.
extension E2ERunner {
    func terraformAgentsScenario() async {
        guard case .variable(let binary) = AppEnvironment.terraformBinary else {
            print("E2E SKIP terraformAgents: no OVERTERM_TERRAFORM — the test names the installed terraform")
            return
        }
        guard let recorder = try? TerraformRecorder.make(in: out("terraform-agents-recorder"), target: binary) else {
            return check("the recording wrapper is made", false)
        }
        TerraformCLI.scenarioWrapper = recorder.wrapper
        defer { TerraformCLI.scenarioWrapper = nil }

        let sentinel = "acme-hunter2-SECRET"
        let checkout = out("acme-agents")
        let lockHeader = "# This file is maintained automatically by \"terraform init\".\n# Manual edits may be lost in future updates.\n"
        let files: [String: String] = [
            ".gitignore": ".terraform/\n*.tfstate\n*.tfstate.*\n*.tfplan\n",
            "envs/dev/main.tf":
                "variable \"acme_db_password\" {\n  type      = string\n  sensitive = true\n  default   = \"\(sentinel)\"\n}\n\nresource \"terraform_data\" \"acme_db\" {\n  input = {\n    name     = \"acme-db\"\n    password = var.acme_db_password\n  }\n}\n\noutput \"db_password\" {\n  value     = var.acme_db_password\n  sensitive = true\n}\n",
            "envs/dev/.terraform.lock.hcl": lockHeader,
            "envs/prod/main.tf": "resource \"terraform_data\" \"acme\" {\n  input = \"acme-prod\"\n}\n",
            "envs/stage/main.tf": "variable \"acme_name\" {\n  default = \"acme-stage\"\n}\n\nresource \"terraform_data\" \"acme\" {\n  input = var.acme_nme\n}\n",
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

        // The launch: Claude Code with the deny rules, recorded — the tab
        // is made without starting it; Codex not guarded; a checkout with
        // no Terraform, nothing added.
        let launch = app.agentCommand(.claude, in: checkout)
        check("Claude Code's launch carries the deny rules", TerraformAgentGuard.carriesRules(launch.command) && launch.launch == .denied, launch.command)
        check("the rules come last", launch.command.hasSuffix(")'"))
        check(
            "the checkout's roots are read for the next launch", await eventually(10) { TerraformAgentGuards.shared.known(checkout) == true },
            "\(String(describing: TerraformAgentGuards.shared.known(checkout)))")
        check("Codex isn't guarded, and says so", { if case .notGuarded = self.app.agentCommand(.codex, in: checkout).launch { true } else { false } }())
        let plain = out("acme-plain")
        try? FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try? "# acme\n".write(to: plain.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try? Git.runBlocking(git, ["init", "-q", "-b", "main"], in: plain, success: [0], timeout: 10)
        // Not read yet: guarded, the safe side — and read for the next launch.
        check("a checkout not read yet is guarded", app.agentCommand(.claude, in: plain).launch == .denied)
        check("read off the main thread", await eventually(10) { TerraformAgentGuards.shared.known(plain) == false })
        check("no Terraform, nothing added", app.agentCommand(.claude, in: plain).command == Agent.claude.command(arguments: Settings.shared.arguments(for: .claude)))
        app.newTab(in: checkout, agent: .claude, startAgent: false)
        guard let agentTab = app.store.selected, agentTab.agent == .claude else { return check("the agent tab", false) }
        check("its pane knows it was guarded", agentTab.terminal.terraformAgentGuard == .denied)

        // A fake agent's permission prompt for terraform apply on envs/prod:
        // printed, never run. Another tab in front, so the mark is news.
        let pane = agentTab.terminal
        check("the agent tab's shell is up", await eventually(15) { pane.shellReported })
        await pause(0.5)
        let prompt = out("acme-agents-prompt.txt")
        try? TerraformPromptTexts.claudeApply.write(to: prompt, atomically: true, encoding: .utf8)
        let printing = out("acme-agents-prompt.sh")
        // Lines before it, as an agent's conversation is: the screen moves,
        // which is what has the monitor read it (3.2's budget).
        try? "#!/bin/bash\n/usr/bin/seq 1 80\n/bin/cat '\(prompt.path)'\n/bin/sleep 8\nprintf '\\033[2J\\033[H'\n/bin/sleep 60\n".write(
            to: printing, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: printing.path)
        pane.insertText("'\(printing.path)'")
        pane.pressReturn()
        app.newTab(in: plain)
        let monitor = TerraformPaneMonitor.shared
        check(
            "the ask is read off the agent's screen", await eventually(20) { monitor.asks[pane.processTag] != nil },
            "running: \(app.blocks(of: pane).ledger.running?.command ?? "nothing"), roots: \(String(describing: TerraformCheckouts.shared.hasRoots(checkout)))")
        let ask = agentTab.terraformAsk
        check("its tab carries it", ask != nil)
        check("envs/prod, production, apply", ask?.warning?.root == "envs/prod" && ask?.isProduction == true && ask?.prompt.line.operation == "apply", ask?.summary ?? "none")
        check("the tab is marked", agentTab.activity.mark == .waiting && agentTab.activity.note == ask?.summary, agentTab.activity.note ?? "")
        app.toggleInbox(nil)
        let entry = app.inbox.entries.first { $0.id == agentTab.id }
        check("the Inbox shows the ask", entry?.terraform != nil && entry?.headline.contains("asks to run terraform apply") == true, entry?.headline ?? "none")
        check("with no answer to press", entry?.prompt == nil)
        let before = pane.visibleText
        app.answer(AgentPrompt.Choice(key: "1", label: "Yes", isDefault: true), in: agentTab.id)
        await pause(0.5)
        check("asked to answer anyway, Overterm types nothing", pane.visibleText == before)
        // Ask Agent and Ask Why never type into it either (3.3).
        check("Ask Agent won't type into a tab at the ask", !app.type("acme: why does this fail?", intoAgent: agentTab))
        await pause(0.3)
        check("and nothing reached its screen", pane.visibleText == before)
        check("nor is it offered as Ask Why's target", app.terraformAsking(agentTab))
        app.toggleInbox(nil)
        check("the mark goes with the prompt", await eventually(20) { agentTab.terraformAsk == nil && agentTab.activity.mark == .none }, "\(agentTab.activity.mark)")
        if let sleeper = TerraformProcesses.descendants(of: SurfaceProcesses.shared.loginPID(of: pane) ?? 0).first(where: { TerraformProcesses.name(of: $0) == "sleep" }) {
            kill(sleeper, SIGTERM)
        }

        // 5.6 rule 6: a shell pane that ran `terraform output` (a stand-in
        // printing the sentinel, never the real one) keeps no scrollback,
        // and ⌘L over it is scrubbed.
        let fakeBin = out("acme-agents-fake-bin")
        try? FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let fake = fakeBin.appendingPathComponent("terraform")
        try? "#!/bin/bash\necho 'db_password = \"\(sentinel)\"'\n".write(to: fake, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        app.newTab(in: checkout)
        guard let shellTab = app.store.selected, shellTab.agent == nil else { return check("a shell tab", false) }
        let shell = shellTab.terminal
        check("the shell tab is up", await eventually(15) { shell.shellReported })
        shell.insertText("PATH='\(fakeBin.path)':$PATH terraform output")
        shell.pressReturn()
        check("it printed the output", await eventually(10) { shell.visibleText?.contains(sentinel) == true })
        check("the pane is marked as having printed secrets", await eventually(5) { self.app.terraformSensitive(shell) })
        check("the session keeps no text of it", !app.scrollbackPanes().contains { $0 === shell })
        check("but keeps another shell pane's", app.scrollbackPanes().contains { pane in app.store.tabs.contains { $0.agent == nil && $0.terminal === pane && $0 !== shellTab } })
        let selected = app.askSelection(shell.visibleText ?? "", of: shell, in: shellTab)
        check("⌘L over it is scrubbed", !selected.text.contains(sentinel) && !selected.text.isEmpty, String(selected.text.suffix(200)))

        // A plan the "agent" saved, with the real terraform in a cleared
        // environment (the scenario's own run, not the wrapper's).
        let dev = checkout.appendingPathComponent("envs/dev", isDirectory: true)
        guard let scratch = try? TerraformGuards.prepareScratch(at: out("terraform-agents-scratch")) else { return check("the scratch folder", false) }
        var environment = scratch.environment
        environment["TF_DATA_DIR"] = dev.appendingPathComponent(".terraform").path
        for arguments in [["init", "-input=false", "-no-color", "-lockfile=readonly"], ["plan", "-input=false", "-no-color", "-out=acme.tfplan"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            process.currentDirectoryURL = dev
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return check("terraform \(arguments[0]) runs", false, "\(error)")
            }
            check("terraform \(arguments[0]) in the sandbox", process.terminationStatus == 0, "exit \(process.terminationStatus)")
        }
        recorder.reset()
        let tag = pane.processTag
        let summary = await toolText("tf_plan_summary", ["path": "envs/dev/acme.tfplan"], pane: tag)
        check("tf_plan_summary reads the agent's plan", summary.contains("Plan of envs/dev") && summary.contains("+1"), summary)
        check("no sensitive value in it", !summary.contains(sentinel) && summary.contains("db_password create (sensitive)"), summary)
        let shows = recorder.calls().filter { $0.subcommand == "show" }
        check("by show -json of its descriptor", shows.count == 1 && shows.first?.arguments == TerraformCommands.showPlanDescriptor, "\(recorder.calls().map(\.arguments))")
        check(
            "with no credential and a scratch HOME",
            shows.first.map { TerraformGuards.credentials(in: Dictionary(uniqueKeysWithValues: $0.names.map { ($0, "") })).isEmpty } == true
                && shows.first?.values["HOME"] != FileManager.default.homeDirectoryForCurrentUser.path, "\(shows.first?.names ?? [])")
        let outside = await toolText("tf_plan_summary", ["path": "../acme-plain/README.md"], pane: tag)
        check("a path outside the checkout is refused", outside.contains("inside your checkout"), outside)

        let roots = await toolText("tf_roots", [:], pane: tag)
        check("tf_roots says envs/prod is production", roots.contains("envs/prod — PRODUCTION"), roots)
        let validate = await toolText("tf_validate", ["root": "envs/dev"], pane: tag)
        check("tf_validate validates an initialised root", validate.contains("envs/dev: valid"), validate)
        let refused = await toolText("tf_validate", ["root": "envs/stage"], pane: tag)
        check("and refuses one with no lock file: init is the person's", refused.contains("needs init"), refused)
        check("the tools are listed", BrowserMCP.offered.contains { ($0["name"] as? String) == "tf_plan_summary" })
        check("none ran init, plan or apply", !recorder.calls().contains { ["init", "plan", "apply"].contains($0.subcommand ?? "") }, "\(recorder.calls().map(\.arguments))")

        // Ask Why on a failed validate: the brief, its diagnostic in it.
        var brief: TerraformAgentBrief?
        app.terraformBriefRecorder = { brief = $0 }
        defer { app.terraformBriefRecorder = nil }
        app.openInEditor(checkout.appendingPathComponent("envs/stage/main.tf"))
        guard let editor = app.editor else { return check("the editor", false) }
        check("main.tf opens", await eventually(3) { editor.active?.url?.lastPathComponent == "main.tf" })
        editor.perform("terraform.validate")
        check("validate fails", await eventually(30) { editor.active?.terraform?.state == .problems(errors: 1, warnings: 0) }, "\(String(describing: editor.active?.terraform?.state))")
        Self.accessibilityTree(true)
        defer { Self.accessibilityTree(false) }
        check("Ask Why is on the bar", await eventually(5) { Self.accessibilityPress("terraform.editor.askWhy", in: editor.view, press: true) })
        check("the brief names the root and the error", await eventually(10) { brief?.text.contains("envs/stage") == true && brief?.text.contains("acme_nme") == true }, brief?.text ?? "none")
        check("and tells the agent not to init, plan or apply", brief?.message.contains("don't run init, plan or apply") == true)
    }

    private func toolText(_ name: String, _ arguments: [String: Any], pane: String) async -> String {
        do {
            let result = try await TerraformMCP.call(name, arguments, pane: pane)
            return ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        } catch let error as BrowserMCP.ToolError {
            return error.message
        } catch {
            return "\(error)"
        }
    }
}

/// What the scenario's fake agent prints: Claude Code's permission prompt, as its screen shows it.
enum TerraformPromptTexts {
    static let claudeApply = """
        ╭──────────────────────────────────────────────────────────────╮
        │ Bash command                                                 │
        │                                                              │
        │   cd envs/prod && terraform apply -auto-approve              │
        │   Apply the change                                           │
        │                                                              │
        │ Do you want to proceed?                                      │
        │ ❯ 1. Yes                                                     │
        │   2. Yes, and don't ask again for terraform apply commands   │
        │   3. No, and tell Claude what to do differently (esc)        │
        ╰──────────────────────────────────────────────────────────────╯

        """
}
