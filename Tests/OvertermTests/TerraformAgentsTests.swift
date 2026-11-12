import Darwin
import XCTest

@testable import Overterm

/// Terraform stage 1c (docs/design/terraform/analysis.md 3.3–3.5, 5.6,
/// 5.10): the plan decoded through its allow-list and masked, an agent's
/// ask read off a screen and never answered, agents launched with
/// Terraform's writes denied, the tf_ tools inside the pane's checkout.
final class TerraformPlanTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    /// The sandbox's sentinels (5.6 rule 12), planted in every path the decoder must drop or mask.
    static let sentinels = ["acme-hunter2-SECRET", "tok-acme-123", "globex-BKPW"]

    /// Terraform 1.17.1's `show -json` of a real plan (terraform_data only,
    /// in a sandbox), with a moved, an imported, a forgotten resource, a
    /// data source, drift, an action, checks and a key no Terraform has
    /// added yet — each holding a sentinel where a value would leak.
    static func plan() throws -> TerraformPlan {
        try TerraformPlan.decode(try Data(contentsOf: fixtures.appendingPathComponent("terraform-plan-sentinels.json")), scrub: TerraformPlan.scrub)
    }

    func testNoSentinelSurvivesTheDecoder() throws {
        let fixture = try String(contentsOf: Self.fixtures.appendingPathComponent("terraform-plan-sentinels.json"), encoding: .utf8)
        for sentinel in Self.sentinels { XCTAssertTrue(fixture.contains(sentinel), "the fixture plants \(sentinel)") }
        let plan = try Self.plan()
        let model = String(reflecting: plan)
        let summary = TerraformPlanText.summary(plan, root: "envs/dev", file: "envs/dev/acme.tfplan")
        for sentinel in Self.sentinels {
            XCTAssertFalse(model.contains(sentinel), "\(sentinel) in the model")
            XCTAssertFalse(summary.contains(sentinel), "\(sentinel) in the summary")
        }
    }

    func testCountsAndRows() throws {
        let plan = try Self.plan()
        let counts = plan.counts
        XCTAssertEqual(counts.replace, 1)
        XCTAssertEqual(counts.delete, 1)
        XCTAssertEqual(counts.update, 4)
        XCTAssertEqual(counts.forget, 1)
        XCTAssertEqual(counts.moved, 1)
        XCTAssertEqual(counts.imported, 1)
        XCTAssertEqual(counts.drift, 1)
        XCTAssertEqual(counts.actions, 1)
        XCTAssertEqual(counts.reads, 1)
        XCTAssertEqual(counts.sentence, "Plan: 1 to import, 1 to add, 4 to change, 2 to destroy. 1 to forget. Actions: 1 to invoke.")
        let api = try XCTUnwrap(plan.resourceChanges.first { $0.address == "terraform_data.acme_api" })
        XCTAssertEqual(api.action, .replace)
        XCTAssertFalse(api.createsFirst)
        XCTAssertEqual(api.replacePaths, [["triggers_replace"]])
        XCTAssertEqual(api.reason, "replace_because_cannot_update")
        XCTAssertEqual(plan.references["terraform_data.acme_api"]?["triggers_replace"], ["var.acme_name"], "the cause chain's first link")
        XCTAssertTrue(TerraformPlanText.riskyLine(api, plan: plan).contains("forced by triggers_replace ← var.acme_name"))
        let moved = try XCTUnwrap(plan.resourceChanges.first { $0.isMove })
        XCTAssertEqual(moved.previousAddress, "terraform_data.acme_before")
        XCTAssertEqual(moved.action, .noop, "a move is a no-op with a marker")
        XCTAssertEqual(plan.resourceChanges.first { $0.isImport }?.importingID, "p-9hUg")
        XCTAssertEqual(plan.unknownKeys, ["acme_future"])
        XCTAssertTrue(plan.partlyUnderstood)
        XCTAssertEqual(plan.priorStateVersion, "1.17.1")
        XCTAssertEqual(plan.variables.map(\.name), ["acme_db_password", "acme_name"])
        XCTAssertEqual(plan.variables.first?.sensitive, true)
    }

    /// Mask at decode: Terraform's marks first, then the narrower names.
    func testMasking() throws {
        let plan = try Self.plan()
        let db = try XCTUnwrap(plan.resourceChanges.first { $0.address == "terraform_data.acme_db" })
        guard case .object(let after)? = db.after, case .object(let input)? = after["input"] else { return XCTFail("\(String(describing: db.after))") }
        XCTAssertEqual(input["password"], .sensitive, "marked by Terraform")
        XCTAssertEqual(input["client_secret"], .sensitive, "unmarked, masked by its name")
        XCTAssertEqual(input["key_name"], .string("acme-key-2"), "a key's name is what a reviewer reads")
        XCTAssertEqual(input["kms_key_id"], .string("acme-kms-1"))
        XCTAssertEqual(after["output"], .unknown, "known after apply")
        XCTAssertEqual(db.changedPaths, ["input.key_name", "output"], "the unchanged password isn't a change; paths only")
        let password = try XCTUnwrap(plan.outputs.first { $0.name == "db_password" })
        XCTAssertTrue(password.sensitive)
        XCTAssertNil(password.after)
        XCTAssertEqual(plan.outputs.first { $0.name == "api_name" }?.after, .unknown)
        guard case .object(let config)? = plan.actions.first?.config else { return XCTFail("the action's config") }
        XCTAssertEqual(config["command"], .sensitive)
        XCTAssertEqual(config["note"], .string("acme"))
        XCTAssertEqual(plan.drift.first?.changedPaths, ["input.password"], "a path, never the values")
    }

    func testSecretNames() {
        for name in ["password", "client_secret", "db_password", "private_key", "tls_pem", "sas_token", "token"] {
            XCTAssertTrue(TerraformSecretNames.isSecret(name), name)
        }
        for name in ["key", "key_name", "public_key", "kms_key_id", "ssh_keys", "session_name", "auth_mode", "token_ttl"] {
            XCTAssertFalse(TerraformSecretNames.isSecret(name), name)
        }
    }

    func testEveryCollectionIsOptional() throws {
        let refresh = try TerraformPlan.decode(Data(#"{"format_version":"1.2","terraform_version":"1.17.1","applyable":false,"complete":true,"errored":false}"#.utf8), scrub: { $0 })
        XCTAssertEqual(refresh.resourceChanges, [])
        XCTAssertFalse(refresh.hasPriorState)
        XCTAssertTrue(TerraformPlanText.summary(refresh, root: "envs/dev", file: nil).contains("No prior state"))
        XCTAssertThrowsError(try TerraformPlan.decode(Data(#"{"format_version":"2.0"}"#.utf8), scrub: { $0 })) { error in
            XCTAssertEqual(error as? TerraformPlan.DecodeError, .unknownFormat("2.0"))
        }
        XCTAssertThrowsError(try TerraformPlan.decode(Data("not json".utf8), scrub: { $0 }))
    }

    func testFoldedAndEscaped() throws {
        let plan = try Self.plan()
        let summary = TerraformPlanText.summary(plan, root: "envs/dev", file: nil)
        XCTAssertTrue(summary.contains("~ terraform_data.acme_tags[0] ×3"), summary)
        XCTAssertTrue(summary.contains("input.rev"), summary)
        XCTAssertEqual(TerraformPlanText.escaped("a\u{202E}b\u{200B}c"), "a\\u{202E}b\\u{200B}c")
        XCTAssertEqual(TerraformValue.string(String(repeating: "x", count: 300)).said().count, 203, "cut at 200, quoted, an ellipsis")
    }
}

final class TerraformPromptTests: XCTestCase {
    /// Modelled on Claude Code's permission prompt (2.1.x), with its box.
    static let claude = """
        ╭──────────────────────────────────────────────────────────────╮
        │ Bash command                                                 │
        │                                                              │
        │   cd envs/prod && terraform apply -auto-approve              │
        │   Apply the change to production                             │
        │                                                              │
        │ Do you want to proceed?                                      │
        │ ❯ 1. Yes                                                     │
        │   2. Yes, and don't ask again for terraform apply commands   │
        │   3. No, and tell Claude what to do differently (esc)        │
        ╰──────────────────────────────────────────────────────────────╯

        """

    /// Modelled on Codex's approval prompt.
    static let codex = """
          Would you like to run the following command?

          $ terraform -chdir=envs/prod destroy

        › 1. Yes, proceed (y)
          2. Yes, and don't ask again for this command (a)
          3. No, and tell Codex what to do differently (esc)
        """

    static let terraform = """
        Plan: 0 to add, 1 to change, 0 to destroy.

        Do you want to perform these actions in workspace "acme-prod"?
          Terraform will perform the actions described above.
          Only 'yes' will be accepted to approve.

          Enter a value:
        """

    func testClaudeCodesPrompt() throws {
        let prompt = try XCTUnwrap(TerraformPrompt.parse(Self.claude))
        XCTAssertEqual(prompt.command, "cd envs/prod && terraform apply -auto-approve")
        XCTAssertEqual(prompt.line.operation, "apply")
        XCTAssertTrue(prompt.line.autoApprove)
        let folder = TerraformPrompt.folder(of: prompt.command!, line: prompt.line, base: URL(fileURLWithPath: "/w/acme-live"))
        XCTAssertEqual(folder.path, "/w/acme-live/envs/prod")
    }

    func testCodexsPrompt() throws {
        let prompt = try XCTUnwrap(TerraformPrompt.parse(Self.codex))
        XCTAssertEqual(prompt.line.operation, "destroy")
        XCTAssertEqual(TerraformPrompt.folder(of: prompt.command!, line: prompt.line, base: URL(fileURLWithPath: "/w/acme-live")).path, "/w/acme-live/envs/prod")
    }

    func testTerraformsOwnPrompt() throws {
        let prompt = try XCTUnwrap(TerraformPrompt.parse(Self.terraform))
        XCTAssertEqual(prompt.shape, .terraform(question: #"Do you want to perform these actions in workspace "acme-prod"?"#, workspace: "acme-prod"))
        XCTAssertEqual(prompt.line.operation, "apply")
        XCTAssertFalse(prompt.isAgents)
        let destroy = try XCTUnwrap(TerraformPrompt.parse("Do you really want to destroy all resources?\n  Terraform will destroy all your managed infrastructure.\n\n  Enter a value: "))
        XCTAssertEqual(destroy.line.operation, "destroy")
        XCTAssertTrue(TerraformPrompt.asksForValue("var.acme_db_password\n  Enter a value: \n\n"))
    }

    /// What isn't an ask for a write: a plan, a question answered and
    /// scrolled by, a write in output with no question under it.
    func testWhatIsNoAsk() {
        XCTAssertNil(TerraformPrompt.parse(Self.claude.replacingOccurrences(of: "terraform apply -auto-approve", with: "terraform plan")))
        XCTAssertNil(TerraformPrompt.parse("$ terraform apply\nApply complete! Resources: 1 added.\n$ "))
        XCTAssertNil(TerraformPrompt.parse(Self.claude.replacingOccurrences(of: "❯ 1. Yes", with: "").replacingOccurrences(of: "2. Yes,", with: "").replacingOccurrences(of: "3. No,", with: "")))
        XCTAssertNil(TerraformPrompt.parse(""))
        // Terraform's prompt answered: its line is no longer the last.
        XCTAssertNil(TerraformPrompt.parse(Self.terraform + "yes\n\nterraform_data.acme: Modifying..."))
    }

    func testStateAndWorkspaceWrites() throws {
        for (command, operation) in [
            ("terraform state rm terraform_data.acme", "state rm"), ("tofu workspace delete acme-old", "workspace delete"),
            ("terragrunt run --all apply", "run --all apply"), ("terraform force-unlock 1234", "force-unlock"),
        ] {
            let screen = "Bash command\n\n  \(command)\n\nDo you want to proceed?\n❯ 1. Yes\n  2. No\n"
            XCTAssertEqual(try XCTUnwrap(TerraformPrompt.parse(screen), command).line.operation, operation)
        }
        XCTAssertNil(TerraformPrompt.parse("Bash command\n\n  terraform state list\n\nDo you want to proceed?\n❯ 1. Yes\n  2. No\n"), "a read")
    }

    func testWhatPrintsSecrets() {
        for line in ["terraform output", "terraform output -json db_password", "terraform show", "tofu console", "terraform state show a.b", "terraform state pull"] {
            XCTAssertTrue(TerraformCommandLine.all(in: line).contains(where: \.printsSecrets), line)
        }
        for line in ["terraform plan", "terraform state list", "terraform validate"] {
            XCTAssertFalse(TerraformCommandLine.all(in: line).contains(where: \.printsSecrets), line)
        }
    }

    func testTheAskSaysWhere() {
        let prompt = TerraformPrompt.parse(Self.claude)!
        let warning = TerraformPaneWarning(
            tool: "terraform", operation: "apply", root: "envs/prod", workspace: "default", backend: "local · terraform.tfstate", rootClass: .production,
            reason: "path envs/prod", isWrite: true)
        let ask = TerraformAsk(prompt: prompt, warning: warning)
        XCTAssertEqual(ask.summary, "asks to run terraform apply -auto-approve in envs/prod · workspace default · PRODUCTION")
        XCTAssertTrue(ask.isProduction)
        XCTAssertTrue(ask.preview.last!.contains("never answers"))
    }
}

/// The ask's mark, and the Inbox that never answers it.
@MainActor
final class TerraformAskInboxTests: XCTestCase {
    func testTheMarkComesAndGoes() {
        var activity = TabActivity()
        XCTAssertTrue(activity.terraformAsked("asks to run terraform apply in envs/prod", visible: false), "notify")
        XCTAssertEqual(activity.mark, .waiting)
        XCTAssertFalse(activity.terraformAsked("asks to run terraform apply in envs/prod", visible: false), "the same ask: said once")
        XCTAssertTrue(activity.terraformAnswered())
        XCTAssertEqual(activity.mark, .none)
        // Looked at: marked all the same, nobody told.
        XCTAssertFalse(activity.terraformAsked("asks", visible: true))
        XCTAssertEqual(activity.mark, .waiting)
        // Something else marked it since: its mark stays.
        activity.seen()
        activity.handle(.notification(title: "Claude", body: "needs you"), visible: false)
        XCTAssertFalse(activity.terraformAnswered())
        XCTAssertEqual(activity.mark, .waiting)
    }

    func testTheInboxOffersNoAnswer() {
        let tab = Tab(terminal: TerminalView())
        tab.terraformAsk = TerraformAsk(prompt: TerraformPrompt.parse(TerraformPromptTests.claude)!, warning: nil)
        tab.activity.terraformAsked(tab.terraformAsk!.summary, visible: false)
        let inbox = InboxModel()
        inbox.refresh(tabs: [tab], group: { _ in nil }, screen: { _ in TerraformPromptTests.claude })
        let entry = inbox.entries.first
        XCTAssertNotNil(entry?.terraform)
        XCTAssertNil(entry?.prompt, "no choices: nothing to press, Return answers nothing")
        XCTAssertTrue(entry?.headline.contains("asks to run terraform apply") == true)
        // A Terraform prompt on screen is no AgentPrompt for the Inbox, even unmarked.
        tab.terraformAsk = nil
        inbox.refresh(tabs: [tab], group: { _ in nil }, screen: { _ in TerraformPromptTests.claude })
        XCTAssertNil(inbox.entries.first?.prompt)
    }
}

final class TerraformAgentGuardTests: XCTestCase {
    func testClaudeGetsTheRulesLast() {
        let command = TerraformAgentGuard.command("claude --model opus", launch: .denied)
        XCTAssertTrue(command.hasPrefix("claude --model opus --disallowedTools '"))
        XCTAssertTrue(command.hasSuffix(")'"), "nothing after it: the flag takes every word that follows")
        XCTAssertTrue(TerraformAgentGuard.carriesRules(command))
        for tool in ["terraform", "tofu", "terragrunt"] {
            for operation in ["apply", "destroy", "import", "taint", "force-unlock", "state", "workspace delete", "refresh", "test"] {
                XCTAssertTrue(TerraformAgentGuard.claudeRules.contains("Bash(\(tool) \(operation):*)"), "the documented form: \(tool) \(operation)")
                XCTAssertTrue(TerraformAgentGuard.claudeRules.contains("Bash(*\(tool) * \(operation)*)"), "after flags: \(tool) \(operation)")
            }
        }
        XCTAssertFalse(TerraformAgentGuard.claudeRules.contains { $0.contains("'") || $0.contains(",") }, "one shell word, one list")
        XCTAssertFalse(TerraformAgentGuard.claudeRules.contains { $0.contains("plan") || $0.contains("validate") }, "reads stay the agent's")
    }

    /// Claude Code 2.1.322's `--disallowedTools` splitter, as its code
    /// reads (commas and spaces split, except inside parentheses): the
    /// one quoted word arrives as every rule, none cut at its spaces.
    func testTheFlagSplitsIntoTheRules() {
        func split(_ argument: String) -> [String] {
            var found: [String] = []
            var current = ""
            var inside = false
            for character in argument {
                switch character {
                case "(":
                    inside = true
                    current.append(character)
                case ")":
                    inside = false
                    current.append(character)
                case ",", " ":
                    if inside {
                        current.append(character)
                    } else if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                        found.append(current.trimmingCharacters(in: .whitespaces))
                        current = ""
                    }
                default: current.append(character)
                }
            }
            if !current.trimmingCharacters(in: .whitespaces).isEmpty { found.append(current.trimmingCharacters(in: .whitespaces)) }
            return found
        }
        XCTAssertEqual(split(TerraformAgentGuard.claudeRules.joined(separator: ",")), TerraformAgentGuard.claudeRules)
    }

    func testWhoGetsWhat() {
        XCTAssertEqual(TerraformAgentGuard.launch(for: .claude, applies: true), .denied)
        XCTAssertEqual(TerraformAgentGuard.launch(for: .claude, applies: false), .none)
        guard case .notGuarded(let why) = TerraformAgentGuard.launch(for: .codex, applies: true) else { return XCTFail("Codex has no deny flag") }
        XCTAssertTrue(why.contains("Codex"))
        XCTAssertEqual(TerraformAgentGuard.command("codex", launch: TerraformAgentGuard.launch(for: .codex, applies: true)), "codex", "nothing added")
        XCTAssertEqual(TerraformAgentGuard.command("claude --continue", launch: .none), "claude --continue")
    }

    /// The deny rules as Claude Code's documentation reads them — `:*` a
    /// prefix, `*` any run of characters — over what an agent types: a
    /// model of its matcher (`denies`), not Claude Code itself.
    func testTheRulesMatchTheWrites() throws {
        for command in [
            "terraform apply", "terraform apply -auto-approve", "terraform -chdir=envs/prod apply", "terraform destroy", "terraform state rm a.b",
            "tofu apply", "terragrunt run --all apply", "terragrunt apply-all", "terraform workspace delete acme", "terraform force-unlock 1",
            "TF_WORKSPACE=prod terraform apply", "env TF_WORKSPACE=prod terraform -chdir=envs/prod destroy", "terraform refresh",
            "terraform -chdir=envs/prod refresh", "terraform test", "terraform init -migrate-state", "terraform init -force-copy",
            "terraform plan -auto-approve", "terraform untaint a.b",
        ] {
            XCTAssertTrue(TerraformAgentGuard.denies(command), command)
            XCTAssertTrue(TerraformCommandLine.all(in: command).contains(where: \.isWrite), "marked too: \(command)")
        }
        for command in [
            "terraform plan", "terraform validate", "terraform fmt -check", "terraform init", "terraform show -json acme.tfplan",
            "terraform -chdir=envs/test plan", "terraform plan -out=apply.tfplan", "terraform -chdir=state-bucket plan",
        ] {
            XCTAssertFalse(TerraformAgentGuard.denies(command), command)
        }
    }
}

/// Which checkouts get the deny rules: unknown is guarded; "none" kept
/// only from a complete read, and only under the settings it was read with.
@MainActor
final class TerraformAgentGuardsTests: XCTestCase {
    private var base: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-guards-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

    private func repository(_ name: String, files: [String: String]) throws -> URL {
        let top = base.appendingPathComponent(name, isDirectory: true)
        for (path, text) in files {
            let url = top.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        _ = try Git.runBlocking(URL(fileURLWithPath: "/usr/bin/git"), ["init", "-q", "-b", "main"], in: top, success: [0], timeout: 10)
        return top
    }

    func testUnknownIsGuarded() throws {
        let guards = TerraformAgentGuards()
        let top = try repository("acme-app", files: ["README.md": "# acme\n"])
        XCTAssertNil(guards.known(top), "never read: guarded")
    }

    /// A listing that hit its cap says nothing of what it left out: the
    /// checkout stays guarded, never "none".
    func testACappedReadIsGuarded() {
        let guards = TerraformAgentGuards()
        let names = (0...TerraformRootScan.maxMatches).map { "apps/acme-\($0)/main.tf" }.joined(separator: "\0")
        let listing = TerraformRootScan.listing(names)
        XCTAssertTrue(listing.capped)
        let top = base.appendingPathComponent("acme-monorepo")
        guards.record(top, roots: [], complete: !listing.capped, settings: .current, identities: TerraformRootStore.shared.productionIdentities)
        XCTAssertNil(guards.known(top), "capped: guarded")
        guards.record(top, roots: [], complete: true, settings: .current, identities: TerraformRootStore.shared.productionIdentities)
        XCTAssertEqual(guards.known(top), false)
    }

    /// "None" holds only under the classes' settings it was read with.
    func testNoneIsForgottenWhenTheSettingsChange() {
        let guards = TerraformAgentGuards()
        let top = base.appendingPathComponent("acme-live")
        var other = TerraformClassSettings.current
        other.pattern = "acme-(prod|live)"
        guards.record(top, roots: [], complete: true, settings: other, identities: TerraformRootStore.shared.productionIdentities)
        XCTAssertNil(guards.known(top), "read under other settings: unknown again")
        guards.record(
            top, roots: [], complete: true, settings: .current,
            identities: TerraformRootStore.shared.productionIdentities.union([TerraformStateIdentity(product: "terraform", backend: "s3", location: "globex-tfstate/acme.tfstate")]))
        XCTAssertNil(guards.known(top), "read before another identity was remembered: unknown again")
    }

    func testDecideReadsTheListing() async throws {
        let guards = TerraformAgentGuards()
        let plain = try repository("acme-plain", files: ["README.md": "# acme\n"])
        let decided = await guards.decide(plain)
        XCTAssertFalse(decided)
        XCTAssertEqual(guards.known(plain), false, "a complete listing with no Terraform: none")
        let live = try repository(
            "acme-live",
            files: ["envs/prod/main.tf": "resource \"terraform_data\" \"acme\" {}\n", "envs/dev/main.tf": "resource \"terraform_data\" \"acme\" {}\n"])
        let production = await guards.decide(live)
        XCTAssertTrue(production)
        XCTAssertEqual(guards.productionRoots(live), ["envs/prod"])
        // Production is sticky until the files change.
        guards.record(live, roots: [], complete: true, settings: .current, identities: [])
        XCTAssertEqual(guards.known(live), true)
        guards.forget(live)
        XCTAssertNil(guards.known(live))
        // Not a repository, nothing to list: guarded.
        let loose = base.appendingPathComponent("loose", isDirectory: true)
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        let unlisted = await guards.decide(loose)
        XCTAssertTrue(unlisted)
        XCTAssertNil(guards.known(loose))
    }
}

/// The tf_ tools: inside the calling pane's checkout only, no init, the
/// saved plan by its descriptor.
@MainActor
final class TerraformMCPTests: XCTestCase {
    private var checkout: URL!
    private var outside: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-mcp-\(UUID().uuidString)", isDirectory: true)
        checkout = base.appendingPathComponent("acme-live", isDirectory: true)
        outside = base.appendingPathComponent("globex-live", isDirectory: true)
        for folder in ["envs/dev", "envs/prod"] {
            try FileManager.default.createDirectory(at: checkout.appendingPathComponent(folder), withIntermediateDirectories: true)
            try "resource \"terraform_data\" \"acme\" {\n  input = \"acme\"\n}\n".write(
                to: checkout.appendingPathComponent(folder + "/main.tf"), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data([0x50, 0x4B, 0x03, 0x04, 0, 0]).write(to: outside.appendingPathComponent("globex.tfplan"))
        try FileManager.default.createSymbolicLink(at: checkout.appendingPathComponent("envs/out"), withDestinationURL: outside)
        try Data([0x50, 0x4B, 0x03, 0x04, 0, 0]).write(to: checkout.appendingPathComponent("envs/dev/acme.tfplan"))
        try "not a plan".write(to: checkout.appendingPathComponent("envs/dev/notes.txt"), atomically: true, encoding: .utf8)
        let git = URL(fileURLWithPath: "/usr/bin/git")
        _ = try Git.runBlocking(git, ["init", "-q", "-b", "main"], in: checkout, success: [0], timeout: 10)
        _ = try Git.runBlocking(git, ["add", "-A"], in: checkout, success: [0], timeout: 10)
        _ = try Git.runBlocking(
            git, ["-c", "user.name=Acme", "-c", "user.email=acme@example.test", "commit", "-q", "-m", "acme"], in: checkout, success: [0], timeout: 10)
        let top = checkout!
        TerraformMCP.paneCheckout = { $0 == "acme-pane" ? top : nil }
    }

    override func tearDown() async throws {
        TerraformMCP.paneCheckout = nil
        try? FileManager.default.removeItem(at: checkout.deletingLastPathComponent())
    }

    private func text(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    func testPathsStayInTheCheckout() throws {
        for path in ["/etc/passwd", "../globex-live/globex.tfplan", "envs/../../globex-live/globex.tfplan", "~/x", "envs/out/globex.tfplan"] {
            XCTAssertThrowsError(try TerraformMCPPath.resolve(path, in: checkout, folder: false), path)
        }
        XCTAssertNoThrow(try TerraformMCPPath.resolve("envs/dev/acme.tfplan", in: checkout, folder: false))
        XCTAssertThrowsError(try TerraformMCPPath.resolve("envs/dev", in: checkout, folder: false), "a folder isn't a file")
        let file = try TerraformMCPPath.resolve("envs/dev/acme.tfplan", in: checkout, folder: false)
        XCTAssertEqual(TerraformMCPPath.rootAbove(file, in: checkout)?.lastPathComponent, "dev")
    }

    func testOnlyAZipPlanIsOpened() throws {
        let plan = try TerraformMCPPath.resolve("envs/dev/acme.tfplan", in: checkout, folder: false)
        let fd = try TerraformMCPPath.openPlan(plan, limit: 1 << 20)
        close(fd)
        XCTAssertThrowsError(try TerraformMCPPath.openPlan(checkout.appendingPathComponent("envs/dev/notes.txt"), limit: 1 << 20))
        XCTAssertThrowsError(try TerraformMCPPath.openPlan(checkout.appendingPathComponent("envs/out"), limit: 1 << 20), "never a link")
        XCTAssertThrowsError(try TerraformMCPPath.openPlan(plan, limit: 2), "bounded")
    }

    func testNoPaneNoTool() async throws {
        let result = try await TerraformMCP.call("tf_roots", [:], pane: nil)
        XCTAssertEqual(result["isError"] as? Bool, true)
        let other = try await TerraformMCP.call("tf_roots", [:], pane: "globex-pane")
        XCTAssertEqual(other["isError"] as? Bool, true)
        do {
            _ = try await TerraformMCP.call("tf_apply", [:], pane: "acme-pane")
            XCTFail("tf_apply doesn't exist")
        } catch {}
    }

    func testRootsAndProduction() async throws {
        let said = text(try await TerraformMCP.call("tf_roots", [:], pane: "acme-pane"))
        XCTAssertTrue(said.contains("envs/prod — PRODUCTION"), said)
        XCTAssertTrue(said.contains("envs/dev — "), said)
        XCTAssertEqual(TerraformAgentGuards.shared.known(checkout), true, "the guard learns the checkout has a production root")
    }

    /// No lock file committed: validate isn't run, init is the person's.
    func testValidateNeedsInit() async throws {
        let said = text(try await TerraformMCP.call("tf_validate", ["root": "envs/dev"], pane: "acme-pane"))
        XCTAssertTrue(said.contains("needs init") && said.contains("no tool runs it"), said)
        let ambiguous = try? await TerraformMCP.call("tf_validate", [:], pane: "acme-pane")
        XCTAssertNil(ambiguous, "two roots: “root” is asked for")
    }

    func testPlanSummaryRefusesOutside() async throws {
        for path in ["../globex-live/globex.tfplan", "envs/out/globex.tfplan", "/tmp/x.tfplan"] {
            do {
                _ = try await TerraformMCP.call("tf_plan_summary", ["path": path], pane: "acme-pane")
                XCTFail(path)
            } catch {}
        }
        do {
            _ = try await TerraformMCP.call("tf_plan_summary", ["path": "envs/dev/notes.txt"], pane: "acme-pane")
            XCTFail("not a plan")
        } catch {}
    }

    func testListedOnlyWhenOn() {
        XCTAssertEqual(TerraformMCP.tools.compactMap { $0["name"] as? String }, ["tf_roots", "tf_fmt_check", "tf_validate", "tf_plan_summary"])
        XCTAssertFalse(TerraformMCP.tools.contains { ($0["name"] as? String)?.contains("apply") == true })
    }
}

/// The saved plan reaches terraform as fd 3, never as a path.
final class TerraformDescriptorRunTests: XCTestCase {
    func testThePlanIsHandedAsFdThree() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-fd-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let reader = folder.appendingPathComponent("terraform")
        // argv: show -json -no-color /dev/fd/3
        try Data("#!/bin/bash -p\n/bin/cat \"$4\"\n".utf8).write(to: reader)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: reader.path)
        let plan = folder.appendingPathComponent("acme.tfplan")
        try Data("PK\u{3}\u{4}acme-plan".utf8).write(to: plan)
        let fd = open(plan.path, O_RDONLY | O_CLOEXEC)
        defer { close(fd) }
        // The path goes; the descriptor still reads it (4.4).
        try FileManager.default.removeItem(at: plan)
        let result = try await TerraformRun.short(reader, TerraformCommands.showPlanDescriptor, in: folder, environment: ["PATH": "/usr/bin:/bin"], file: fd)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "PK\u{3}\u{4}acme-plan")
        XCTAssertNotNil(TerraformCommands.refusal(["show", "-json"]), "never show of a state")
        XCTAssertNotNil(TerraformCommands.refusal(["show", "-json", "-no-color", "acme.tfplan"]), "never a path")
        XCTAssertNil(TerraformCommands.refusal(TerraformCommands.formatCheckDiff))
    }
}

extension TerraformPromptTests {
    /// An ask answered and scrolled up under what came after is no ask.
    func testAnAnsweredAskIsGone() {
        XCTAssertNotNil(TerraformPrompt.parse(Self.codex + "\n  Press enter to confirm or esc to cancel\n"), "a hint line under the choices")
        XCTAssertNil(TerraformPrompt.parse(Self.codex + "\n✔ You approved\nterraform_data.acme: Destroying...\n"))
    }
}

/// 5.6 rule 6: a pane that printed Terraform's secrets keeps no scrollback.
@MainActor
final class TerraformScrollbackRuleTests: XCTestCase {
    func testASecretPrintingCommandMarksThePane() {
        let blocks = PaneBlocks()
        blocks.titleChanged("terraform plan", cwd: "/w/acme-live")
        XCTAssertFalse(blocks.printedTerraformSecrets)
        blocks.titleChanged("/w/acme-live", cwd: "/w/acme-live")
        blocks.titleChanged("cd envs/prod && terraform output -json", cwd: "/w/acme-live")
        XCTAssertTrue(blocks.printedTerraformSecrets)
        blocks.titleChanged("ls", cwd: "/w/acme-live")
        XCTAssertTrue(blocks.printedTerraformSecrets, "for the pane's life")
    }
}

/// The ask's command block, read whole and no further; the command as
/// the chrome shows it, masked; an ask whose folder isn't known.
final class TerraformPromptBlockTests: XCTestCase {
    /// A long command wrapped inside Claude Code's box, in a narrow split.
    static let wrapped = """
        ╭────────────────────────────────────────────╮
        │ Bash command                               │
        │                                            │
        │   cd infra/live/prod/eu-west-1/network &&  │
        │   terraform                                │
        │   apply -auto-approve                      │
        │   Apply the network change                 │
        │                                            │
        │ Do you want to proceed?                    │
        │ ❯ 1. Yes                                   │
        │   2. No, and tell Claude what to do        │
        ╰────────────────────────────────────────────╯

        """

    func testAWrappedCommandIsReadWhole() throws {
        let prompt = try XCTUnwrap(TerraformPrompt.parse(Self.wrapped), "neither half alone parses as a write")
        XCTAssertEqual(prompt.line.operation, "apply")
        XCTAssertTrue(prompt.line.autoApprove)
        XCTAssertEqual(prompt.command, "cd infra/live/prod/eu-west-1/network && terraform apply -auto-approve")
        let folder = TerraformPrompt.folder(of: prompt.command!, line: prompt.line, base: URL(fileURLWithPath: "/w/acme-live"))
        XCTAssertEqual(folder.path, "/w/acme-live/infra/live/prod/eu-west-1/network")
        // Wrapped at any column, a word cut in two included.
        let command = "cd infra/live/prod/eu-west-1/network && terraform apply -auto-approve"
        for column in stride(from: 9, to: command.count, by: 7) {
            var lines: [String] = []
            var rest = Substring(command)
            while !rest.isEmpty {
                lines.append(String(rest.prefix(column)))
                rest = rest.dropFirst(column)
            }
            let screen = "Bash command\n\n" + lines.map { "  " + $0 }.joined(separator: "\n") + "\n\nDo you want to proceed?\n❯ 1. Yes\n  2. No\n"
            XCTAssertEqual(TerraformPrompt.parse(screen)?.line.operation, "apply", "wrapped at \(column)")
        }
        // A continuation's backslash.
        let continued = "Bash command\n\n  terraform -chdir=envs/prod \\\n    destroy\n\nDo you want to proceed?\n❯ 1. Yes\n  2. No\n"
        XCTAssertEqual(TerraformPrompt.parse(continued)?.line.operation, "destroy")
    }

    /// A `terraform apply` said earlier in the chat is no ask for an `ls`.
    func testNothingAboveTheBlockIsRead() {
        let screen = """
            ⏺ Next I would run terraform apply -auto-approve in envs/prod, once you agree.

            ╭──────────────────────────────────────────╮
            │ Bash command                             │
            │                                          │
            │   ls envs/prod                           │
            │   List the root                          │
            │                                          │
            │ Do you want to proceed?                  │
            │ ❯ 1. Yes                                 │
            │   2. No                                  │
            ╰──────────────────────────────────────────╯

            """
        XCTAssertNil(TerraformPrompt.parse(screen))
        let headerless = "terraform apply -auto-approve was mentioned\n\n  ls envs/prod\n\nDo you want to proceed?\n❯ 1. Yes\n  2. No\n"
        XCTAssertNil(TerraformPrompt.parse(headerless), "no header: the run above the question only")
    }

    /// 5.6: the command reaches the Inbox, the header and their accessibility text masked.
    func testTheCommandIsMasked() throws {
        let screen = "Bash command\n\n  terraform apply -var 'admin_password=acme-hunter2-SECRET' -var=token=tok-acme-123 -auto-approve\n\nDo you want to proceed?\n❯ 1. Yes\n  2. No\n"
        let prompt = try XCTUnwrap(TerraformPrompt.parse(screen))
        let ask = TerraformAsk(prompt: prompt, warning: nil)
        let shown = ask.preview.joined(separator: "\n") + ask.summary
        for sentinel in TerraformPlanTests.sentinels { XCTAssertFalse(shown.contains(sentinel), shown) }
        XCTAssertTrue(shown.contains("admin_password="), "the variable's name stays: \(shown)")
        XCTAssertEqual(TerraformPrompt.masked("TF_VAR_db_password=globex-BKPW terraform apply").contains("globex-BKPW"), false)
        XCTAssertEqual(TerraformPrompt.masked("terraform apply -target=terraform_data.acme"), "terraform apply -target=terraform_data.acme")
    }

    /// An agent's Bash keeps its `cd`: a bare apply from the checkout's top
    /// in a checkout with production roots is said as production.
    func testAnUnsettledFolderInAProductionCheckout() throws {
        let top = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-unsettled-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: top) }
        try FileManager.default.createDirectory(at: top, withIntermediateDirectories: true)
        let prompt = try XCTUnwrap(TerraformPrompt.parse("Bash command\n\n  terraform apply\n\nDo you want to proceed?\n❯ 1. Yes\n  2. No\n"))
        var candidate = TerraformPaneMonitor.Candidate(tag: "acme", login: 0, commandFolder: top.path, checkout: top)
        let neutral = TerraformPaneMonitor.ask(prompt, candidate: candidate, processes: [], settings: TerraformClassSettings(), identities: [])
        XCTAssertNil(neutral.warning, "no production root known: nothing to say")
        candidate.productionRoots = ["envs/prod"]
        let ask = TerraformPaneMonitor.ask(prompt, candidate: candidate, processes: [], settings: TerraformClassSettings(), identities: [])
        XCTAssertTrue(ask.isProduction)
        XCTAssertTrue(ask.summary.contains("root unknown") && ask.summary.contains("envs/prod") && ask.summary.contains("PRODUCTION"), ask.summary)
    }

    func testTheScreenIsReadOnlyOnASignal() {
        XCTAssertFalse(TerraformPaneMonitor.readsScreen(waiting: false, terraformRunning: false, asked: false, moved: false), "an idle agent: no read")
        XCTAssertTrue(TerraformPaneMonitor.readsScreen(waiting: true, terraformRunning: false, asked: false, moved: false))
        XCTAssertTrue(TerraformPaneMonitor.readsScreen(waiting: false, terraformRunning: true, asked: false, moved: false))
        XCTAssertTrue(TerraformPaneMonitor.readsScreen(waiting: false, terraformRunning: false, asked: true, moved: false))
        XCTAssertTrue(TerraformPaneMonitor.readsScreen(waiting: false, terraformRunning: false, asked: false, moved: true))
    }
}

/// What an agent reads of a plan is masked by the broad list too (5.6 rule 4).
final class TerraformAgentMaskingTests: XCTestCase {
    func testAnAgentsPlanMasksTheBroadNames() throws {
        let object: [String: Any] = [
            "format_version": "1.2",
            "output_changes": [
                "acme_service_account": [
                    "actions": ["create"], "after_sensitive": false,
                    "after": ["private_key_id": "acme-hunter2-SECRET", "session_key": "tok-acme-123", "auth_header": "globex-BKPW", "name": "acme-sa"],
                ]
            ],
        ]
        let agents = try TerraformPlan.decode(object, scrub: TerraformPlan.scrub, secretName: TerraformSecretNames.forAgents)
        let said = String(reflecting: agents) + TerraformPlanText.summary(agents, root: "envs/dev", file: "envs/dev/acme.tfplan")
        for sentinel in TerraformPlanTests.sentinels { XCTAssertFalse(said.contains(sentinel), sentinel) }
        XCTAssertTrue(said.contains("acme-sa"), "what isn't secret stays")
        // The person's view keeps the narrower list: key_name and the like readable.
        let person = try TerraformPlan.decode(object, scrub: TerraformPlan.scrub)
        XCTAssertTrue(String(reflecting: person).contains("acme-sa"))
        XCTAssertFalse(TerraformSecretNames.isSecret("key_name"))
        XCTAssertTrue(TerraformSecretNames.forAgents("private_key_id"))
    }

    func testTheBriefSaysTheVersionsAndProviders() {
        let lock = """
            provider "registry.terraform.io/hashicorp/random" {
              version     = "3.6.3"
              constraints = "~> 3.6"
              hashes = [
                "h1:acme=",
              ]
            }
            """
        let providers = TerraformLockFile.versions(in: lock)
        XCTAssertEqual(providers.map(\.address), ["registry.terraform.io/hashicorp/random"])
        XCTAssertEqual(providers.map(\.version), ["3.6.3"])
        let root = TerraformAgentBrief.Root(
            name: "envs/dev", workspace: "default", backend: "local", rootClass: .local, version: "1.17.1",
            providers: providers.map { "\($0.address) \($0.version)" })
        let brief = TerraformAgentBrief.validate([], root: root, checkout: nil)
        XCTAssertTrue(brief.text.contains("Terraform 1.17.1") && brief.text.contains("hashicorp/random 3.6.3"), brief.text)
    }

    /// ⌘L over a pane that printed Terraform's secrets is scrubbed.
    func testASensitivePanesSelectionIsScrubbed() {
        let text = AskSelection.text("db_password = \"acme-hunter2-SECRET\"\n", kind: .shell, pinned: true)
        XCTAssertFalse(text.contains("acme-hunter2-SECRET"), text)
    }
}

/// The MCP server serves whenever a tool would be offered: Terraform's alone too.
@MainActor
final class TerraformBridgeTests: XCTestCase {
    func testTerraformAloneServes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-bridge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = Settings(url: dir.appendingPathComponent("settings.json"), watch: false)
        for spec in SettingsSchema.all where spec.key.hasSuffix("agentControl") || spec.key.hasSuffix("agentAccess") {
            settings.set(spec.key, .bool(false))
        }
        XCTAssertFalse(BrowserBridge.wanted(in: settings))
        XCTAssertTrue(BrowserMCP.offered(in: settings).isEmpty)
        settings.set("terraform.enabled", .bool(true))
        settings.set("terraform.agentAccess", .bool(true))
        XCTAssertTrue(settings.terraformAgentAccess)
        XCTAssertTrue(BrowserBridge.wanted(in: settings), "only Terraform's tools on: the bridge serves them")
        XCTAssertFalse(BrowserMCP.offered(in: settings).isEmpty)
    }
}
