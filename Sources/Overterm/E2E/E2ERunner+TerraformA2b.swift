import AppKit

/// Terraform stage 2b (docs/design/terraform/analysis.md 2.1, 2.8, 3.7, 9):
/// New Task in a repository with Terraform roots. Its worktree's local
/// root is warned — no state here, it is in main's checkout —, the
/// workspace main selects is named and not copied, the lock files are
/// compared, and the root is initialised without its backend
/// (`init -backend=false -lockfile=readonly`, no credential, no
/// workspace), so validate works there: the root calls a local module,
/// which validate can't read until init installed it — a worktree made
/// without New Task's init says "needs init". Through the terraform
/// scenario's recording wrapper, over a repository this scenario writes,
/// `terraform_data` only (a guarded run fetches no provider).
extension E2ERunner {
    func terraformNewWorktreeChecks(recorder: TerraformRecorder) async {
        let git = URL(fileURLWithPath: "/usr/bin/git")
        let repo = out("acme-tasks")
        let user = ["-c", "user.name=Acme", "-c", "user.email=acme@example.test"]
        let files = [
            ".gitignore": ".terraform/\n*.tfstate\n*.tfstate.*\n",
            "envs/dev/main.tf": "resource \"terraform_data\" \"acme\" {\n  input = \"acme-dev\"\n}\n\nmodule \"net\" {\n  source = \"../../modules/acme-net\"\n}\n",
            "modules/acme-net/main.tf": "resource \"terraform_data\" \"net\" {\n  input = \"acme-net\"\n}\n",
        ]
        do {
            for (path, text) in files {
                let url = repo.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            _ = try Git.runBlocking(git, ["init", "-q", "-b", "main"], in: repo, success: [0], timeout: 10)
            _ = try Git.runBlocking(git, ["add", "-A"], in: repo, success: [0], timeout: 10)
            _ = try Git.runBlocking(git, user + ["commit", "-q", "-m", "acme"], in: repo, success: [0], timeout: 10)
            // main's own state, workspace and lock file: none committed.
            let dev = repo.appendingPathComponent("envs/dev", isDirectory: true)
            try "{\"version\": 4, \"lineage\": \"acme\", \"serial\": 1}\n".write(
                to: dev.appendingPathComponent("terraform.tfstate"), atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: dev.appendingPathComponent("terraform.tfstate.d/acme-stage"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dev.appendingPathComponent(".terraform"), withIntermediateDirectories: true)
            try "acme-stage".write(to: dev.appendingPathComponent(".terraform/environment"), atomically: true, encoding: .utf8)
            try "provider \"registry.terraform.io/hashicorp/random\" {\n  version = \"3.6.3\"\n}\n".write(
                to: dev.appendingPathComponent(".terraform.lock.hcl"), atomically: true, encoding: .utf8)
        } catch {
            return check("the repository for New Task is written", false, "\(error)")
        }
        let before = recorder.calls().count
        do {
            try await app.createTask(repo: repo, branch: "acme-task", base: "main", agent: nil)
        } catch {
            return check("New Task in a repository with Terraform roots", false, error.localizedDescription)
        }
        let worktree = TaskCreator.worktreePath(repo: repo, branch: "acme-task", location: Settings.shared.worktreeLocation)
        let setup = TerraformWorktreeSetup.shared
        check(
            "New Task reads the worktree's roots and prepares them", await eventually(60) { setup.report(worktree)?.finished == true },
            "\(setup.report(worktree).map { "\($0.roots.map { "\($0.path): \($0.preparation)" })" } ?? "no report")")
        let dev = setup.root(worktree, path: "envs/dev")
        check("its root is warned: no state here, it is in main's checkout", dev?.stateElsewhere == "main", "\(dev?.stateElsewhere ?? "-")")
        check(
            "main's workspace named, not copied",
            dev?.sourceWorkspace == .init(worktree: "main", workspace: "acme-stage")
                && !FileManager.default.fileExists(atPath: worktree.appendingPathComponent("envs/dev/.terraform/environment").path),
            "\(String(describing: dev?.sourceWorkspace))")
        check("the lock files compared", dev?.lockDrift.map(\.sentence) == ["no lock file here; main's locks random 3.6.3"], "\(dev?.lockDrift ?? [])")
        check("initialised without its backend", dev?.preparation == .ready, dev?.preparation.words ?? "")
        let calls = Array(recorder.calls().dropFirst(before))
        let inits = calls.filter { $0.subcommand == "init" }
        let call = inits.first
        check(
            "one init, -backend=false -lockfile=readonly, in the worktree's root",
            inits.count == 1 && call?.arguments == TerraformCommands.initializeWithoutBackend
                && call?.cwd == realPath(worktree.appendingPathComponent("envs/dev")),
            "\(inits.map { "\($0.arguments) @ \($0.cwd)" })")
        check(
            "with no credential, no workspace, a scratch HOME",
            call.map { TerraformGuards.credentials(in: Dictionary(uniqueKeysWithValues: $0.names.map { ($0, "") })).isEmpty } == true
                && call?.values["TF_WORKSPACE"] == nil && call?.values["CHECKPOINT_DISABLE"] == "1"
                && call?.values["HOME"] == AppEnvironment.terraformScratchDirectory.appendingPathComponent("home").path,
            "\(call?.names ?? []) \(call?.values ?? [:])")
        check(
            "a guarded run's CLI config: nothing fetched; git and ssh reach nothing of the user's",
            call?.values["TF_CLI_CONFIG_FILE"] == AppEnvironment.terraformScratchDirectory.appendingPathComponent("terraformrc").path
                && call?.names.contains("GIT_CONFIG_NOSYSTEM") == true && call?.names.contains("GIT_TERMINAL_PROMPT") == true
                && call?.names.contains("SSH_AUTH_SOCK") == false,
            "\(call?.names ?? []) \(call?.values ?? [:])")
        check(
            "the local module installed for validate",
            FileManager.default.fileExists(atPath: worktree.appendingPathComponent("envs/dev/.terraform/modules/modules.json").path))
        check(
            "no lock file written, no plan, no apply",
            !FileManager.default.fileExists(atPath: worktree.appendingPathComponent("envs/dev/.terraform.lock.hcl").path)
                && !calls.contains { ["plan", "apply", "workspace"].contains($0.subcommand ?? "") }, "\(calls.map(\.arguments))")

        // The panel says it on the root's card.
        app.showTerraformPanel(nil)
        let panel = app.terraformPanel
        check(
            "the panel follows the new worktree",
            await eventually(15) { panel.checkout.map { self.realPath($0) } == self.realPath(worktree) && panel.state == .read && !panel.roots.isEmpty },
            panel.checkout?.path ?? "")
        // The window's worktree list follows the new tab after the panel's
        // first read: the card says it once the list has the others.
        var card: TerraformRootCard? { panel.roots.first { $0.path == "envs/dev" } }
        check("its card: no state here", await eventually(15) { card?.stateElsewhere == "main" }, card?.stateElsewhere ?? "-")
        check(
            "its card: the lock file differs from main's", await eventually(5) { card?.lockDrift.first?.worktree == "main" },
            "\(card?.lockDrift ?? [])")
        if let view = app.window?.contentView {
            check(
                "and what New Task did", await eventually(5) { Self.accessibilityPress("terraform.panel.newWorktree.envs/dev", in: view, press: false) })
        }

        // Validate works there.
        let main = worktree.appendingPathComponent("envs/dev/main.tf")
        app.openInEditor(main)
        guard let editor = app.editor else { return check("the editor", false) }
        check("the worktree's main.tf opens", await eventually(5) { editor.active?.url?.standardizedFileURL == main.standardizedFileURL })
        let folder = editor.active?.terraform
        editor.perform("terraform.validate")
        check("validate works in the new worktree", await eventually(30) { folder?.state == .valid(warnings: 0) }, "\(String(describing: folder?.state))")
        let validate = recorder.calls().dropFirst(before).last { $0.subcommand == "validate" }
        check("in its root", validate?.cwd == realPath(worktree.appendingPathComponent("envs/dev")), validate?.cwd ?? "")

        // Without New Task's init the same root can't be validated: the
        // init is what made it work.
        let plain = out("acme-tasks-plain")
        do {
            _ = try Git.runBlocking(git, ["worktree", "add", "-q", "-b", "acme-plain", plain.path, "main"], in: repo, success: [0], timeout: 10)
        } catch {
            return check("a worktree without New Task", false, "\(error)")
        }
        let plainMain = plain.appendingPathComponent("envs/dev/main.tf")
        app.openInEditor(plainMain)
        check("its main.tf opens", await eventually(5) { editor.active?.url?.standardizedFileURL == plainMain.standardizedFileURL })
        let plainFolder = editor.active?.terraform
        editor.perform("terraform.validate")
        check(
            "without the init: needs init (its module isn't installed)",
            await eventually(30) {
                if case .needsInit = plainFolder?.state { return true }
                return false
            }, "\(String(describing: plainFolder?.state))")
    }
}
