import AppKit

/// Terraform stage 1b (docs/design/terraform/analysis.md 9): which root,
/// which workspace, and is it production — before anyone runs anything.
/// Two roots and a module listed, `envs/prod` red; the panel reads nothing
/// while hidden (no read, no terraform: the wrapper records no call); a
/// second worktree's "no state here" and "shares its state"; a pane running
/// the real terraform (offline, `console`, in a cleared environment)
/// gets the header; Terminal in this root; `init`'s writes under
/// `.terraform/providers` don't recount the changes pane; a checkout with
/// no roots isn't walked until a configuration appears in it, and ⌃⌘E
/// lists roots its read finds after it opened.
///
/// The real terraform (`OVERTERM_TERRAFORM`) behind the recording wrapper,
/// over a checkout this scenario writes, `terraform_data` only. Without
/// one, SKIP, loudly.
extension E2ERunner {
    func terraformRootsScenario() async {
        guard case .variable(let binary) = AppEnvironment.terraformBinary else {
            print("E2E SKIP terraformRoots: no OVERTERM_TERRAFORM — the test names the installed terraform")
            return
        }
        guard let recorder = try? TerraformRecorder.make(in: out("terraform-roots-recorder"), target: binary) else {
            return check("the recording wrapper is made", false)
        }
        TerraformCLI.scenarioWrapper = recorder.wrapper
        defer { TerraformCLI.scenarioWrapper = nil }

        // The checkout: two roots calling nothing but terraform_data, one
        // calling a module, one on an http backend nobody reaches.
        let checkout = out("acme-live")
        let worktree = out("acme-live-bump")
        let files: [String: String] = [
            ".gitignore": ".terraform/\n*.tfstate\n*.tfstate.*\n.terraform.tfstate.lock.info\n",
            "envs/dev/main.tf": "module \"net\" {\n  source = \"../../modules/acme-net\"\n}\n\nresource \"terraform_data\" \"acme\" {\n  input = \"acme-dev\"\n}\n",
            "envs/dev/dev.tfvars": "acme_name = \"acme-dev\"\n",
            "envs/prod/main.tf": "terraform {\n  required_version = \">= 1.0\"\n}\n\nresource \"terraform_data\" \"acme\" {\n  input = \"acme-prod\"\n}\n",
            "envs/shared/main.tf": "terraform {\n  backend \"http\" {\n    address = \"http://127.0.0.1:9/state/acme-shared\"\n  }\n}\n",
            "modules/acme-net/main.tf": "variable \"name\" {\n  default = \"acme-net\"\n}\n\nresource \"terraform_data\" \"net\" {\n  input = var.name\n}\n",
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
            // The dev root's state is here, in main's checkout only.
            try "{}\n".write(to: checkout.appendingPathComponent("envs/dev/terraform.tfstate"), atomically: true, encoding: .utf8)
        } catch {
            return check("the checkout is written", false, "\(error)")
        }
        defer {
            _ = try? Git.runBlocking(git, ["worktree", "remove", "--force", worktree.path], in: checkout, success: [0], timeout: 10)
        }

        let panel = app.terraformPanel
        app.newTab(in: checkout)
        let real = realPath(checkout)
        check(
            "the panel follows the selected tab's checkout",
            await eventually(10) { panel.checkout.map { self.realPath($0) } == real }, panel.checkout?.path ?? "none")

        // Off screen: nothing read, no terraform — even when files change.
        await pause(0.6)
        let before = panel.reads
        try? "resource \"terraform_data\" \"stage\" {}\n".write(
            to: checkout.appendingPathComponent("envs/staging/main.tf").creatingFolder(), atomically: true, encoding: .utf8)
        await pause(1.5)
        check("hidden, the panel reads nothing", panel.reads == before && panel.roots.isEmpty, "\(panel.reads) reads")
        check("and runs no terraform", recorder.calls().isEmpty, "\(recorder.calls().map(\.arguments))")

        app.showTerraformPanel(nil)
        check("⌥⌘E shows the panel", app.sidebarPanel.panel == .terraform && panel.panelVisible)
        check(
            "the roots are listed", await eventually(15) { panel.roots.map(\.path) == ["envs/dev", "envs/prod", "envs/shared", "envs/staging"] },
            "\(panel.roots.map(\.path)) \(panel.state)")
        check(
            "and the module, with the root that calls it", panel.modules.map(\.path) == ["modules/acme-net"] && panel.modules.first?.callers == ["envs/dev"],
            "\(panel.modules)")
        check(
            "the chip says the branch and commit, as the diff has them", await eventually(10) { panel.branchLabel?.hasPrefix("main @ ") == true },
            panel.branchLabel ?? "none")
        let prod = panel.roots.first { $0.path == "envs/prod" }
        check("envs/prod is production", prod?.rootClass == .production && prod?.verdict.reason == "path envs/prod", prod?.verdict.reason ?? "")
        check("envs/dev is local", panel.roots.first { $0.path == "envs/dev" }?.rootClass == .local)
        check(
            "envs/shared is remote, its backend said",
            panel.roots.first { $0.path == "envs/shared" }.map { $0.rootClass == .remote && $0.backendSummary == "http · 127.0.0.1/state/acme-shared" } == true,
            panel.roots.first { $0.path == "envs/shared" }?.backendSummary ?? "")
        Self.accessibilityTree(true)
        defer { Self.accessibilityTree(false) }
        if let sidebar = app.sidebarItem?.viewController.view {
            check("drawn in the rail, red on production", await eventually(5) { Self.accessibilityPress("terraform.panel.class.envs/prod", in: sidebar, press: false) })
        }
        // The version pill: `version -json`, the one terraform 1b runs, once per binary.
        check("the version is asked", await eventually(20) { prod?.path != nil && panel.roots.first { $0.path == "envs/prod" }?.version != nil })
        let versions = recorder.calls().filter { $0.arguments == TerraformCommands.version }
        check("by `version -json`, once for the binary", versions.count == 1, "\(recorder.calls().map(\.arguments))")
        check(
            "no other terraform ran", recorder.calls().allSatisfy { $0.arguments == TerraformCommands.version }, "\(recorder.calls().map(\.arguments))")
        check(
            "with no credential and no call home",
            versions.first.map { TerraformGuards.credentials(in: Dictionary(uniqueKeysWithValues: $0.names.map { ($0, "") })).isEmpty } == true
                && versions.first?.values["CHECKPOINT_DISABLE"] == "1", "\(versions.first?.names ?? [])")
        let status = ((try? await Git.run(["status", "--porcelain"], in: checkout)) ?? "?").trimmingCharacters(in: .whitespacesAndNewlines)
        check("nothing written in the checkout but the scenario's own file", status == "?? envs/staging/", status)

        // Hidden again: a change marks it, and it is read when it shows.
        app.sidebarPanel.panel = .files
        await pause(0.3)
        check("on another panel it isn't visible", !panel.panelVisible)
        let hiddenReads = panel.reads
        try? "# acme\n".write(to: checkout.appendingPathComponent("envs/prod/notes.tf"), atomically: true, encoding: .utf8)
        await pause(1.5)
        check("a change while hidden reads nothing", panel.reads == hiddenReads, "\(panel.reads)")
        app.showTerraformPanel(nil)
        check("shown, it reads again", await eventually(10) { panel.reads == hiddenReads + 1 }, "\(panel.reads)")

        // The switcher: the palette on the roots.
        app.showTerraformSwitcher(nil)
        check(
            "⌃⌘E lists the roots", app.palette.scope == .terraform && app.palette.results.map(\.title).contains("envs/prod"),
            "\(app.palette.results.map(\.title))")
        app.hidePalette()

        // `init` writes ~50 MB of providers: the changes pane doesn't count it.
        let providers = checkout.appendingPathComponent("envs/dev/.terraform/providers/registry.terraform.io/hashicorp/null/3.2.1/darwin_arm64")
        try? FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        await pause(2.5)
        let counted = app.diff.refreshCount
        for index in 0..<12 {
            try? Data(count: 512 << 10).write(to: providers.appendingPathComponent("terraform-provider-null_v3.2.1_x5.\(index)"))
        }
        await pause(2)
        check("init's provider writes don't refresh the changes", app.diff.refreshCount == counted, "\(counted) → \(app.diff.refreshCount)")
        try? "acme-stage\n".write(to: checkout.appendingPathComponent("envs/dev/.terraform/environment"), atomically: true, encoding: .utf8)
        check(
            "its workspace selection does", await eventually(5) { self.app.diff.refreshCount > counted },
            "\(counted) → \(app.diff.refreshCount), the diff on \(app.diff.root?.path ?? "none")")

        // A pane running the real terraform gets the header — found in the
        // pane's tree, its folder by -chdir. A cleared environment: no
        // HOME, credential or CLI config of the user's; TF_DATA_DIR set to
        // say the amber.
        guard let pane = app.store.selected?.terminal else { return check("the checkout's tab", false) }
        check("its shell is up", await eventually(15) { pane.shellReported })
        await pause(1)
        let scratchHome = out("terraform-roots-home")
        let cliConfig = out("terraform-roots-rc")
        try? FileManager.default.createDirectory(at: scratchHome, withIntermediateDirectories: true)
        try? TerraformGuards.cliConfig().write(to: cliConfig, atomically: true, encoding: .utf8)
        let line =
            "env -i HOME='\(scratchHome.path)' TF_CLI_CONFIG_FILE='\(cliConfig.path)' CHECKPOINT_DISABLE=1 PATH=/usr/bin:/bin "
            + "HTTP_PROXY=\(TerraformGuards.deadProxy) HTTPS_PROXY=\(TerraformGuards.deadProxy) TF_DATA_DIR='\(out("terraform-roots-data").path)' "
            + "'\(recorder.wrapper.path)' -chdir=envs/prod console"
        pane.insertText(line)
        pane.pressReturn()
        let tag = pane.processTag
        let monitor = TerraformPaneMonitor.shared
        check(
            "the header names the root over the pane", await eventually(20) { monitor.warnings[tag] != nil },
            "running: \(app.blocks(of: pane).ledger.running?.command ?? "nothing"), walks \(monitor.walks), login "
                + "\(SurfaceProcesses.shared.pairedLoginPID(of: pane).map(String.init) ?? "unpaired"), processes \(monitor.processes[tag] ?? []), "
                + "calls \(recorder.calls().map(\.arguments))")
        let warning = monitor.warnings[tag]
        check("envs/prod, production, console", warning?.root == "envs/prod" && warning?.isProduction == true && warning?.operation == "console", warning?.label ?? "")
        check("its TF_DATA_DIR said", warning?.inheritedDataDir == true)
        check("the workspace the root selects", warning?.workspace == "default")
        let header = app.window?.contentView
        if let header {
            check("drawn in the pane's header", await eventually(5) { Self.accessibilityPress("pane.terraformWarning", in: header, press: false) })
        }
        // Ended by its exact pid (never a pattern). console outlived SIGTERM
        // here, so SIGKILL: whatever it leaves is in this scenario's folder.
        if let pid = monitor.processes[tag]?.first?.pid { kill(pid, SIGKILL) }
        check("the header goes when terraform does", await eventually(15) { monitor.warnings[tag] == nil })

        // Terminal in this root: a tab at the root, a Terraform tab.
        if let prod = panel.roots.first(where: { $0.path == "envs/prod" }), let tab = app.openTerraformTerminal(prod) {
            check("Terminal in this root opens a Terraform tab", tab.kind == .terraform && tab.terminal.terraformRoot == "envs/prod")
            check(
                "at the root",
                await eventually(10) { tab.terminal.workingDirectory.map { self.realPath(URL(fileURLWithPath: $0)) } == self.realPath(prod.folder) },
                tab.terminal.workingDirectory ?? "")
            if let header { check("its header says the root", await eventually(5) { Self.accessibilityPress("pane.terraformRoot", in: header, press: false) }) }
            app.closeTabsWithoutAsking([tab])
        } else {
            check("Terminal in this root opens a Terraform tab", false)
        }

        // A second worktree: the dev root's state is in main's checkout.
        do {
            _ = try Git.runBlocking(git, ["worktree", "add", "-q", worktree.path, "-b", "bump-acme"], in: checkout, success: [0], timeout: 10)
        } catch {
            return check("the worktree is made", false, "\(error)")
        }
        app.newTab(in: worktree)
        check(
            "the panel follows it", await eventually(10) { panel.checkout.map { self.realPath($0) } == self.realPath(worktree) && panel.state == .read },
            panel.checkout?.path ?? "")
        check(
            "no state in this worktree: it is in main's",
            await eventually(10) { panel.roots.first { $0.path == "envs/dev" }?.stateElsewhere == "main" },
            "\(panel.roots.map { "\($0.path): \($0.stateElsewhere ?? "-")" })")
        check(
            "the shared backend's root shares its state with main",
            panel.roots.first { $0.path == "envs/shared" }?.sharedWith == ["main"], "\(panel.roots.map { "\($0.path): \($0.sharedWith)" })")
        check("a local root's state is its own", panel.roots.first { $0.path == "envs/prod" }?.sharedWith == [])
        let calls = recorder.calls()
        check(
            "every terraform run was `version -json` or the pane's console",
            calls.allSatisfy { $0.arguments == TerraformCommands.version || $0.arguments == ["-chdir=envs/prod", "console"] }, "\(calls.map(\.arguments))")
        check("none ran init, plan or apply", !calls.contains { ["init", "plan", "apply"].contains($0.subcommand ?? "") })

        // A checkout with no roots: read, its panes never walked — until a
        // configuration is written there, shown or not (3.2).
        let empty = out("acme-empty")
        do {
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            try "# acme\n".write(to: empty.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            _ = try Git.runBlocking(git, ["init", "-q", "-b", "main"], in: empty, success: [0], timeout: 10)
            _ = try Git.runBlocking(git, ["add", "-A"], in: empty, success: [0], timeout: 10)
            _ = try Git.runBlocking(
                git, ["-c", "user.name=Acme", "-c", "user.email=acme@example.test", "commit", "-q", "-m", "acme"], in: empty, success: [0], timeout: 10)
        } catch {
            return check("the empty checkout is written", false, "\(error)")
        }
        app.newTab(in: empty)
        check(
            "the panel reads a checkout with no roots",
            await eventually(10) { panel.checkout.map { self.realPath($0) } == self.realPath(empty) && panel.state == .read && panel.roots.isEmpty },
            "\(panel.checkout?.path ?? "none") \(panel.state)")
        check("its panes aren't walked", TerraformCheckouts.shared.hasRoots(panel.checkout) == false)
        app.sidebarPanel.panel = .files
        await pause(0.3)
        try? "resource \"terraform_data\" \"acme\" {}\n".write(
            to: empty.appendingPathComponent("envs/prod/main.tf").creatingFolder(), atomically: true, encoding: .utf8)
        check(
            "a configuration written there, the panel hidden, opens the question again",
            await eventually(10) { TerraformCheckouts.shared.hasRoots(panel.checkout) != false })
        // ⌃⌘E before the hidden panel read the new root: listed when the read lands.
        app.showTerraformSwitcher(nil)
        check(
            "⌃⌘E lists the roots its read finds", await eventually(10) { self.app.palette.scope == .terraform && self.app.palette.results.map(\.title).contains("envs/prod") },
            "\(app.palette.results.map(\.title))")
        app.hidePalette()
    }
}

extension URL {
    /// The file's folder made first; the file itself.
    fileprivate func creatingFolder() -> URL {
        try? FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}
