import XCTest

@testable import Overterm

/// New Task's Terraform (analysis 2.1, 2.8, 3.7, stage 2b): a new
/// worktree's roots read against the repository's other worktrees — the
/// no-state warning, the lock files compared, the workspace another
/// worktree selects named and never copied — and initialised without
/// their backend only where init fetches nothing flagged, in validate's
/// environment, the lock file read only. Over scratch folders and a
/// scratch repository; no terraform runs (the init is recorded).
final class TerraformWorktreeTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-worktree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func write(_ path: String, _ text: String, in base: URL? = nil) throws {
        let url = (base ?? folder).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func lock(_ providers: [(String, String)]) -> String {
        providers.map { "provider \"\($0.0)\" {\n  version     = \"\($0.1)\"\n  constraints = \"~> \($0.1)\"\n  hashes = [\n    \"h1:acme=\",\n  ]\n}\n" }
            .joined(separator: "\n")
    }

    private func card(_ path: String, in checkout: URL) -> TerraformRootCard {
        let root = checkout.appendingPathComponent(path, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return TerraformRootCard.make(
            folder: TerraformRootFolder(path: path, kind: .root, files: names), at: root, facts: TerraformRootFacts.read(root: root, checkout: checkout),
            awsProfile: nil, terragruntTree: false, settings: TerraformClassSettings(), productionIdentities: [])
    }

    // MARK: Lock files across worktrees (2.8)

    func testLockFilesCompared() {
        let here = TerraformLockDrift.versions(in: lock([("registry.terraform.io/hashicorp/aws", "5.80.0"), ("registry.terraform.io/hashicorp/random", "3.6.3")]))
        let there = TerraformLockDrift.versions(
            in: lock([("registry.terraform.io/hashicorp/aws", "6.2.0"), ("registry.terraform.io/hashicorp/random", "3.6.3"), ("registry.terraform.io/globex/acme", "1.0.0")]))
        let drift = TerraformLockDrift.drift(here: here, there: there, worktree: "main")
        XCTAssertEqual(drift?.differences.map(\.provider), ["globex/acme", "aws"])
        XCTAssertEqual(drift?.sentence, "globex/acme only in main (1.0.0); aws 5.80.0 here, 6.2.0 in main")
        XCTAssertNil(TerraformLockDrift.drift(here: here, there: here, worktree: "main"), "the same lock: nothing said")
        XCTAssertNil(TerraformLockDrift.drift(here: nil, there: nil, worktree: "main"))
        let missingHere = TerraformLockDrift.drift(here: nil, there: here, worktree: "main")
        XCTAssertEqual(missingHere?.sentence, "no lock file here; main's locks aws 5.80.0, random 3.6.3")
        XCTAssertEqual(TerraformLockDrift.drift(here: here, there: nil, worktree: "bump-eks")?.sentence, "bump-eks has no lock file")
        // One line a root, whatever the number of worktrees; a long list capped.
        var other = TerraformLockDrift.drift(here: here, there: nil, worktree: "bump-eks")!
        other.worktreePath = "/acme/bump-eks"
        XCTAssertEqual(
            TerraformLockDrift.summary([drift!, other, other]), "globex/acme only in main (1.0.0); aws 5.80.0 here, 6.2.0 in main — and 2 other worktrees")
        XCTAssertNil(TerraformLockDrift.summary([]))
        XCTAssertEqual(other.id, "/acme/bump-eks", "by path: names repeat")
        let many = TerraformLockDrift.versions(in: lock((1...7).map { ("registry.terraform.io/hashicorp/acme\($0)", "1.0.\($0)") }))
        XCTAssertEqual(
            TerraformLockDrift.drift(here: nil, there: many, worktree: "main")?.sentence,
            "no lock file here; main's locks acme1 1.0.1, acme2 1.0.2, acme3 1.0.3, acme4 1.0.4, 3 more")
        XCTAssertEqual(TerraformLockDrift.shortName("registry.opentofu.org/opentofu/random"), "random")
        XCTAssertEqual(TerraformLockDrift.shortName("tf.globex.example/acme/net"), "tf.globex.example/acme/net", "off the public registry: whole")
    }

    /// Read from the file, bounded, and read again when it changes.
    func testLockVersionsFollowTheFile() throws {
        XCTAssertNil(TerraformLockDrift.versions(at: folder), "no lock file")
        try write(".terraform.lock.hcl", lock([("registry.terraform.io/hashicorp/random", "3.6.3")]))
        XCTAssertEqual(TerraformLockDrift.versions(at: folder), ["registry.terraform.io/hashicorp/random": "3.6.3"])
        try write(".terraform.lock.hcl", lock([("registry.terraform.io/hashicorp/random", "3.7.10")]))
        XCTAssertEqual(TerraformLockDrift.versions(at: folder), ["registry.terraform.io/hashicorp/random": "3.7.10"])
    }

    // MARK: Which roots New Task initialises (2.1, 4.13, 5.9)

    func testWhatIsInitialised() throws {
        // terraform_data only: nothing fetched.
        try write("envs/dev/main.tf", "resource \"terraform_data\" \"acme\" {}\n")
        XCTAssertEqual(TerraformWorktreeRoot.preparation(for: card("envs/dev", in: folder), enabled: true), .waiting)
        XCTAssertEqual(TerraformWorktreeRoot.preparation(for: card("envs/dev", in: folder), enabled: false), .off)
        // A provider the lock file pins: fetched as locked.
        let required = "terraform {\n  required_providers {\n    random = {\n      source = \"hashicorp/random\"\n    }\n  }\n}\n"
        try write("envs/stage/main.tf", required)
        try write("envs/stage/.terraform.lock.hcl", lock([("registry.terraform.io/hashicorp/random", "3.6.3")]))
        XCTAssertEqual(TerraformWorktreeRoot.preparation(for: card("envs/stage", in: folder), enabled: true), .waiting)
        // One it doesn't: the person's Init…, its fetch list first.
        try write("envs/qa/main.tf", required)
        guard case .skipped(let why) = TerraformWorktreeRoot.preparation(for: card("envs/qa", in: folder), enabled: true) else {
            return XCTFail("a provider not in the lock file is never fetched by New Task")
        }
        XCTAssertTrue(why.hasPrefix("provider random — not in .terraform.lock.hcl"), why)
        XCTAssertTrue(why.hasSuffix("Init… in the panel shows what it fetches."), why)
        // A module on a branch: it changes under the same lock file.
        try write("envs/net/main.tf", "module \"acme_net\" {\n  source = \"git::https://git.example/acme/net.git?ref=main\"\n}\n")
        guard case .skipped(let module) = TerraformWorktreeRoot.preparation(for: card("envs/net", in: folder), enabled: true) else {
            return XCTFail("a branch-ref module is never fetched by New Task")
        }
        XCTAssertTrue(module.contains("a branch ref (main)"), module)
        // A module at a tag or a commit still comes from git, with the
        // user's keys, and a tag moves: the person's Init… only.
        for source in [
            "git::ssh://git@git.example/acme/net.git?ref=v1.2.0", "github.com/acme/net?ref=0123456789abcdef0123456789abcdef01234567",
            "git::https://git.example/acme/net.git?ref=v1.2.0",
        ] {
            try write("envs/tag/main.tf", "module \"acme_net\" {\n  source = \"\(source)\"\n}\n")
            guard case .skipped(let why) = TerraformWorktreeRoot.preparation(for: card("envs/tag", in: folder), enabled: true) else {
                return XCTFail("a remote module outside the registry is never fetched by New Task: \(source)")
            }
            XCTAssertTrue(why.contains("outside the registry"), why)
        }
        // A registry module at an exact version: fetched as pinned.
        try write("envs/reg/main.tf", "module \"acme_vpc\" {\n  source  = \"acme/vpc/aws\"\n  version = \"5.1.2\"\n}\n")
        XCTAssertEqual(TerraformWorktreeRoot.preparation(for: card("envs/reg", in: folder), enabled: true), .waiting)
        // A provider implied by a resource, or a provider block, and no
        // lock entry: init would fetch the newest.
        for text in ["resource \"aws_s3_bucket\" \"acme\" {}\n", "provider \"aws\" {\n  region = \"eu-west-1\"\n}\n"] {
            try write("envs/implied/main.tf", text)
            guard case .skipped(let why) = TerraformWorktreeRoot.preparation(for: card("envs/implied", in: folder), enabled: true) else {
                return XCTFail("an implied provider not in the lock file is never fetched by New Task: \(text)")
            }
            XCTAssertTrue(why.hasPrefix("provider aws — not in .terraform.lock.hcl"), why)
            try write("envs/implied/.terraform.lock.hcl", lock([("registry.terraform.io/hashicorp/aws", "6.2.0")]))
            XCTAssertEqual(TerraformWorktreeRoot.preparation(for: card("envs/implied", in: folder), enabled: true), .waiting, "locked: \(text)")
            try FileManager.default.removeItem(at: folder.appendingPathComponent("envs/implied/.terraform.lock.hcl"))
        }
        // A local module is part of the checkout — but the providers it
        // needs are the root's lock file's to pin.
        try write("envs/local/main.tf", "module \"acme\" {\n  source = \"../../modules/acme\"\n}\n")
        try write("modules/acme/main.tf", "resource \"terraform_data\" \"acme\" {}\n\nmodule \"inner\" {\n  source = \"../acme-inner\"\n}\n")
        try write("modules/acme-inner/main.tf", "resource \"terraform_data\" \"inner\" {}\n")
        let local = card("envs/local", in: folder)
        let modules = TerraformWorktreeRoot.localModules(of: local.facts.config, at: local.folder, checkout: folder)
        XCTAssertEqual(modules?.count, 2, "the module, and the one it calls")
        XCTAssertEqual(TerraformWorktreeRoot.preparation(for: local, enabled: true, modules: modules), .waiting)
        try write("modules/acme-inner/main.tf", "resource \"random_pet\" \"inner\" {}\n")
        let unlocked = TerraformWorktreeRoot.localModules(of: local.facts.config, at: local.folder, checkout: folder)
        guard case .skipped(let inner) = TerraformWorktreeRoot.preparation(for: local, enabled: true, modules: unlocked) else {
            return XCTFail("a local module's provider not in the root's lock file is never fetched by New Task")
        }
        XCTAssertTrue(inner.hasPrefix("provider random — not in .terraform.lock.hcl"), inner)
        try write("envs/local/.terraform.lock.hcl", lock([("registry.terraform.io/hashicorp/random", "3.6.3")]))
        XCTAssertEqual(TerraformWorktreeRoot.preparation(for: card("envs/local", in: folder), enabled: true, modules: unlocked), .waiting)
        try write(
            "modules/acme-inner/main.tf",
            "terraform {\n  required_providers {\n    acme = {\n      source = \"globex/acme\"\n    }\n  }\n}\n")
        let requiredInner = TerraformWorktreeRoot.localModules(of: local.facts.config, at: local.folder, checkout: folder)
        guard case .skipped = TerraformWorktreeRoot.preparation(for: card("envs/local", in: folder), enabled: true, modules: requiredInner) else {
            return XCTFail("a local module's required provider not locked")
        }
        // A module that isn't there, or leaves the checkout: not read, not initialised.
        try write("envs/away/main.tf", "module \"acme\" {\n  source = \"../../../acme-elsewhere\"\n}\n")
        let away = card("envs/away", in: folder)
        XCTAssertNil(TerraformWorktreeRoot.localModules(of: away.facts.config, at: away.folder, checkout: folder))
        guard case .skipped = TerraformWorktreeRoot.preparation(for: away, enabled: true, modules: nil) else { return XCTFail("unread modules") }
        // HCP's roots: never.
        try write("envs/hcp/main.tf", "terraform {\n  cloud {\n    organization = \"globex\"\n  }\n}\n")
        XCTAssertEqual(
            TerraformWorktreeRoot.preparation(for: card("envs/hcp", in: folder), enabled: true), .skipped(TerraformProcessCheck.remoteExecutionRefusal))
    }

    /// Another worktree's workspace is named, never taken.
    func testTheWorkspaceIsNotCopied() throws {
        try write("envs/dev/main.tf", "resource \"terraform_data\" \"acme\" {}\n")
        let here = card("envs/dev", in: folder)
        var main = TerraformRootFacts()
        main.workspace = "acme-stage"
        main.workspaceFromFile = true
        let source = TerraformWorktreeRoot.sourceWorkspace(card: here, others: [("main", main)])
        XCTAssertEqual(source, .init(worktree: "main", workspace: "acme-stage"))
        let made = TerraformWorktreeRoot.make(card: here, enabled: true, others: [("main", main)])
        XCTAssertEqual(made.notes.first?.hasPrefix("Workspace default here: main selects acme-stage, which New Task doesn't copy"), true)
        XCTAssertEqual(here.workspace, "default")
        XCTAssertNil(TerraformWorktreeRoot.sourceWorkspace(card: here, others: [("main", TerraformRootFacts())]), "main on default: nothing to say")
    }

    // MARK: The line and its environment (4.3, 4.5, 5.13 rules 1, 3, 8)

    func testTheInitLine() {
        let line = TerraformCommands.initializeWithoutBackend
        XCTAssertEqual(line, ["init", "-backend=false", "-input=false", "-lockfile=readonly", "-no-color"])
        XCTAssertNil(TerraformCommands.refusal(line))
        XCTAssertTrue(TerraformCommands.all.contains(line))
        XCTAssertNotNil(TerraformCommands.refusal(["init", "-backend=false", "-upgrade"]), "never -upgrade")
        XCTAssertNotNil(TerraformCommands.refusal(["init", "-backend=false"]), "only the line built, whole")
    }

    func testTheInitEnvironmentHasNoCredentialNorWorkspace() throws {
        let scratch = try TerraformGuards.prepareScratch(at: folder.appendingPathComponent("scratch"))
        let hostile = [
            "PATH": "/usr/bin:/bin", "HOME": "/Users/acme", "AWS_PROFILE": "acme-prod-admin", "AWS_SECRET_ACCESS_KEY": "acme-hunter2-SECRET",
            "TF_TOKEN_app_terraform_io": "tok-acme-123", "TF_WORKSPACE": "acme-prod", "TF_DATA_DIR": "/tmp/globex", "TF_CLI_ARGS_init": "-upgrade",
            "TF_LOG": "trace", "GOOGLE_APPLICATION_CREDENTIALS": "/Users/acme/key.json", "TF_VAR_db_password": "globex-BKPW",
        ]
        let root = folder.appendingPathComponent("envs/dev")
        let environment = TerraformEnvironment.build(base: hostile, purpose: .worktreeInit(pluginCache: nil), root: root, scratch: scratch)
        XCTAssertTrue(TerraformGuards.credentials(in: environment).isEmpty, "\(environment.keys.sorted())")
        for name in ["TF_WORKSPACE", "TF_CLI_ARGS_init", "TF_LOG", "TF_VAR_db_password", "AWS_PROFILE", "TF_PLUGIN_CACHE_DIR"] {
            XCTAssertNil(environment[name], name)
        }
        XCTAssertEqual(environment["HOME"], scratch.home.path)
        XCTAssertEqual(environment["TF_CLI_CONFIG_FILE"], scratch.cliConfig.path)
        XCTAssertEqual(environment["TF_DATA_DIR"], root.appendingPathComponent(".terraform").path)
        XCTAssertEqual(environment["CHECKPOINT_DISABLE"], "1")
        for sentinel in ["acme-hunter2-SECRET", "tok-acme-123", "globex-BKPW"] { XCTAssertFalse(environment.values.contains(sentinel), sentinel) }
        let cached = TerraformEnvironment.build(base: hostile, purpose: .worktreeInit(pluginCache: "/tmp/acme-cache"), root: root, scratch: scratch)
        XCTAssertEqual(cached["TF_PLUGIN_CACHE_DIR"], "/tmp/acme-cache", "the cache the person took")
    }

    /// In the user's app the init can install the providers the lock file
    /// pins (the installer asks a source before the cache), with no
    /// credential; a guarded run's fetches nothing. git and ssh reach
    /// nothing of the user's: no agent socket, no system gitconfig.
    func testTheInitCLIConfigAndGit() throws {
        let scratch = try TerraformGuards.prepareScratch(at: folder.appendingPathComponent("scratch"))
        let base = [
            "PATH": "/usr/bin:/bin", "SSH_AUTH_SOCK": "/private/tmp/acme-agent.sock", "GIT_SSH_COMMAND": "ssh -i /Users/acme/.ssh/id_globex",
            "GIT_CONFIG_PARAMETERS": "'credential.helper'='osxkeychain'",
        ]
        let root = folder.appendingPathComponent("envs/dev")
        let app = TerraformEnvironment.build(base: base, purpose: .worktreeInit(pluginCache: nil), root: root, scratch: scratch, guarded: false)
        XCTAssertEqual(app["TF_CLI_CONFIG_FILE"], scratch.worktreeInitConfig.path)
        let config = try String(contentsOf: scratch.worktreeInitConfig, encoding: .utf8)
        XCTAssertTrue(config.contains("direct {}"), config)
        XCTAssertFalse(config.contains("exclude"), "installs allowed")
        XCTAssertFalse(config.contains("credentials \""), "no credentials block")
        let guarded = TerraformEnvironment.build(base: base, purpose: .worktreeInit(pluginCache: nil), root: root, scratch: scratch, guarded: true)
        XCTAssertEqual(guarded["TF_CLI_CONFIG_FILE"], scratch.cliConfig.path, "a guarded run: nothing fetched")
        XCTAssertTrue(try String(contentsOf: scratch.cliConfig, encoding: .utf8).contains("exclude = [\"*/*/*\"]"))
        for environment in [app, guarded] {
            for name in ["SSH_AUTH_SOCK", "GIT_SSH_COMMAND", "GIT_CONFIG_PARAMETERS"] { XCTAssertNil(environment[name], name) }
            XCTAssertEqual(environment["GIT_CONFIG_NOSYSTEM"], "1")
            XCTAssertEqual(environment["GIT_TERMINAL_PROMPT"], "0")
            XCTAssertEqual(environment["GIT_CONFIG_GLOBAL"], "/dev/null")
        }
        // Validate's own is unchanged: the scratch config, its agent socket untouched.
        let validate = TerraformEnvironment.build(base: base, purpose: .validate, root: root, scratch: scratch, guarded: false)
        XCTAssertEqual(validate["TF_CLI_CONFIG_FILE"], scratch.cliConfig.path)
        XCTAssertNil(validate["GIT_CONFIG_NOSYSTEM"])
    }

    // MARK: New Task's worktree, end to end (no terraform: the init recorded)

    @MainActor
    func testANewWorktreeIsWarnedAndPrepared() async throws {
        let repo = folder.appendingPathComponent("acme-infra", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try write(".gitignore", ".terraform/\n*.tfstate\n*.tfstate.*\n", in: repo)
        try write("envs/dev/main.tf", "resource \"terraform_data\" \"acme\" {}\n", in: repo)
        try write("envs/qa/main.tf", "terraform {\n  required_providers {\n    random = {\n      source = \"hashicorp/random\"\n    }\n  }\n}\n", in: repo)
        let user = ["-c", "user.name=Acme", "-c", "user.email=acme@example.test"]
        _ = try await Git.run(["init", "-q", "-b", "main"], in: repo)
        _ = try await Git.run(["add", "-A"], in: repo)
        _ = try await Git.run(user + ["commit", "-q", "-m", "acme"], in: repo)
        // main's own state, workspace and lock file: none of them committed.
        try write("envs/dev/terraform.tfstate", "{\"version\": 4, \"lineage\": \"acme\", \"serial\": 1}\n", in: repo)
        try write("envs/dev/.terraform/environment", "acme-stage", in: repo)
        try write("envs/dev/.terraform.lock.hcl", lock([("registry.terraform.io/hashicorp/random", "3.6.3")]), in: repo)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("envs/dev/terraform.tfstate.d/acme-stage"), withIntermediateDirectories: true)

        let worktree = try await TaskCreator.create(repo: repo, branch: "acme-task", base: "main")
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("envs/dev/.terraform/environment").path))

        var initialised: [(String, String?)] = []
        let setup = TerraformWorktreeSetup { root, cache in
            initialised.append((root.standardizedFileURL.path, cache))
            return .ready
        }
        var finished = false
        setup.prepare(worktree, others: [TerraformWorktree(url: repo, name: "main")], initialize: true) { finished = true }
        for _ in 0..<200 where !finished { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(finished)
        let report = try XCTUnwrap(setup.report(worktree))
        // The panel's checkout may spell it with symlinks resolved, or not.
        XCTAssertEqual(setup.report(worktree.resolvingSymlinksInPath()), report)
        let spelled = URL(fileURLWithPath: worktree.path.replacingOccurrences(of: "/private/var/", with: "/var/"))
        XCTAssertEqual(setup.report(spelled), report, spelled.path)
        XCTAssertEqual(report.roots.map(\.path), ["envs/dev", "envs/qa"])
        let dev = try XCTUnwrap(setup.root(worktree, path: "envs/dev"))
        XCTAssertEqual(dev.stateElsewhere, "main", "no state in this worktree: it is in main's")
        XCTAssertEqual(dev.sourceWorkspace, .init(worktree: "main", workspace: "acme-stage"))
        XCTAssertEqual(dev.lockDrift.map(\.sentence), ["no lock file here; main's locks random 3.6.3"])
        XCTAssertEqual(dev.preparation, .ready)
        guard case .skipped = setup.root(worktree, path: "envs/qa")?.preparation else { return XCTFail("a provider not locked: not fetched") }
        XCTAssertEqual(initialised.map(\.0), [worktree.appendingPathComponent("envs/dev").standardizedFileURL.path], "only the root it may")
        XCTAssertNil(initialised.first?.1, "no cache the person never took")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: worktree.appendingPathComponent("envs/dev/.terraform/environment").path), "the workspace not copied")
        XCTAssertTrue(TerraformCheckouts.shared.hasRoots(worktree) == true)
        // The person's own Init there: what New Task said is forgotten.
        setup.forget(checkout: worktree.resolvingSymlinksInPath(), root: "envs/dev")
        XCTAssertNil(setup.root(worktree, path: "envs/dev"))
        XCTAssertNotNil(setup.root(worktree, path: "envs/qa"))

        // Off in Settings: read and warned, nothing initialised.
        initialised = []
        finished = false
        let second = try await TaskCreator.create(repo: repo, branch: "acme-off", base: "main")
        setup.prepare(second, others: [TerraformWorktree(url: repo, name: "main")], initialize: false) { finished = true }
        for _ in 0..<200 where !finished { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(setup.root(second, path: "envs/dev")?.preparation, .off)
        XCTAssertEqual(setup.root(second, path: "envs/dev")?.stateElsewhere, "main")
        XCTAssertTrue(initialised.isEmpty)
    }

    /// While New Task's init runs in a root, the root says so (the panel's
    /// Init and Plan wait); a second prepare of the worktree waits for the
    /// first's init to end rather than starting another beside it.
    @MainActor
    func testOneInitARootAtATime() async throws {
        let repo = folder.appendingPathComponent("acme-serial", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try write("envs/dev/main.tf", "resource \"terraform_data\" \"acme\" {}\n", in: repo)
        let user = ["-c", "user.name=Acme", "-c", "user.email=acme@example.test"]
        _ = try await Git.run(["init", "-q", "-b", "main"], in: repo)
        _ = try await Git.run(["add", "-A"], in: repo)
        _ = try await Git.run(user + ["commit", "-q", "-m", "acme"], in: repo)
        let worktree = try await TaskCreator.create(repo: repo, branch: "acme-serial", base: "main")
        let root = worktree.appendingPathComponent("envs/dev", isDirectory: true)

        var going = 0
        var most = 0
        var release: CheckedContinuation<Void, Never>?
        var calls = 0
        let setup = TerraformWorktreeSetup(registry: TerraformRunRegistry()) { _, _ in
            going += 1
            most = max(most, going)
            calls += 1
            if calls == 1 { await withCheckedContinuation { release = $0 } }
            going -= 1
            return .ready
        }
        setup.prepare(worktree, others: [], initialize: true)
        for _ in 0..<200 where release == nil { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertNotNil(release, "the first init started")
        XCTAssertTrue(setup.isInitializing(root))
        XCTAssertTrue(setup.isInitializing(root.resolvingSymlinksInPath()))
        XCTAssertFalse(setup.isInitializing(repo.appendingPathComponent("envs/dev")), "another worktree's root")
        // Test and State refuse meanwhile, as Plan and Init do: init is installing the providers they start.
        let card = TerraformRootCard(
            path: "envs/dev", name: "envs/dev", folder: root, kind: .root, facts: TerraformRootFacts(), backendSummary: "local", identity: nil,
            verdict: .init(rootClass: .local, reason: "a test's"))
        let test = await TerraformTestRun.begin(
            card: card, checkout: worktree, file: nil, agent: nil, writable: false, settingPath: "", binary: URL(fileURLWithPath: "/usr/bin/false"),
            results: TerraformTestResults(), setup: setup, ask: { _ in true }, show: { _ in XCTFail("nothing shown") })
        guard case .failure(let refused) = test else { return XCTFail("a test while New Task initialises: refused") }
        XCTAssertEqual(refused.message, TerraformWorktreeSetup.initializingRefusal)
        let read = TerraformStateRead(checkout: worktree, card: card, reader: .agent)
        await read.start(registry: TerraformRunRegistry(), setup: setup, settingPath: "", binary: URL(fileURLWithPath: "/usr/bin/false"))
        XCTAssertEqual(read.phase, .refused(TerraformWorktreeSetup.initializingRefusal))
        var finished = false
        setup.prepare(worktree, others: [], initialize: true) { finished = true }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(calls, 1, "the second waits for the first's init")
        release?.resume()
        for _ in 0..<200 where !finished { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(finished)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(most, 1, "never two inits at once")
        XCTAssertFalse(setup.isInitializing(root))
        XCTAssertEqual(setup.root(worktree, path: "envs/dev")?.preparation, .ready)
    }
}
