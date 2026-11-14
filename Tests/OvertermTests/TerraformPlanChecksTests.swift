import XCTest

@testable import Overterm

/// What a plan checks between the click and the process (analysis 2.8,
/// 4.9, 5.5, 5.10, D-12, D-20): HCP's roots aren't planned here; the root
/// is read and classed again at the run, so a workspace selected since the
/// card, or a class now production, is refused; an agent's allowance holds
/// only while its code runs nothing new; whose code it is, by every commit
/// of the branch; the branch's changed lines from git itself, committed
/// ones too. Over scratch folders only, with no terraform run.
final class TerraformPlanChecksTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-checks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func write(_ path: String, _ text: String) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The card of `path` as the panel makes it, from what is on disk now.
    private func card(_ path: String, identities: Set<TerraformStateIdentity> = []) -> TerraformRootCard {
        let root = folder.appendingPathComponent(path, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let facts = TerraformRootFacts.read(root: root, checkout: folder)
        return TerraformRootCard.make(
            folder: TerraformRootFolder(path: path, kind: .root, files: names), at: root, facts: facts, awsProfile: nil, terragruntTree: false,
            settings: TerraformClassSettings(), productionIdentities: identities)
    }

    @MainActor private func why(_ run: TerraformPlanRun) -> String? { if case .refused(let why) = run.phase { why } else { nil } }

    // MARK: HCP

    func testHCPRootsArentPlannedOrInitialisedHere() {
        XCTAssertEqual(TerraformProcessCheck.refused(.plan, backendType: "cloud"), "HCP runs remotely: plan it in HCP (stage 3)")
        XCTAssertEqual(TerraformProcessCheck.refused(.initialize, backendType: "remote"), "HCP runs remotely: plan it in HCP (stage 3)")
        XCTAssertNil(TerraformProcessCheck.refused(.plan, backendType: "s3"))
        XCTAssertNil(TerraformProcessCheck.refused(.validate, backendType: "cloud"), "the editor's reads stay")
    }

    @MainActor func testACloudRootIsRefusedBeforeAnythingRuns() async throws {
        try write(
            "envs/acme-hcp/main.tf",
            "terraform {\n  cloud {\n    organization = \"acme\"\n    workspaces {\n      name = \"acme-app\"\n    }\n  }\n}\nresource \"terraform_data\" \"acme\" {}\n")
        let card = card("envs/acme-hcp")
        XCTAssertEqual(card.facts.backend.type, "cloud")
        let run = TerraformPlanRun(kind: .plan, checkout: folder, card: card)
        await run.start(registry: TerraformRunRegistry(), settingPath: "/nonexistent/terraform", classing: .init(settings: .init(), identities: []))
        XCTAssertEqual(why(run), "HCP runs remotely: plan it in HCP (stage 3)")
        let initialize = TerraformPlanRun(kind: .initialize, checkout: folder, card: card)
        await initialize.start(registry: TerraformRunRegistry(), settingPath: "/nonexistent/terraform", classing: .init(settings: .init(), identities: []))
        XCTAssertEqual(why(initialize), "HCP runs remotely: plan it in HCP (stage 3)")
    }

    // MARK: Read again at the run

    @MainActor func testAWorkspaceSelectedSinceTheCardIsRefused() async throws {
        try write("envs/acme/main.tf", "resource \"terraform_data\" \"acme\" {}\n")
        let card = card("envs/acme")
        XCTAssertEqual(card.workspace, "default")
        // Someone — an agent in this worktree — selects another workspace after the card was read.
        try write("envs/acme/.terraform/environment", "acme-stage\n")
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("envs/acme/terraform.tfstate.d/acme-stage"), withIntermediateDirectories: true)
        let run = TerraformPlanRun(kind: .plan, checkout: folder, card: card)
        await run.start(registry: TerraformRunRegistry(), settingPath: "/nonexistent/terraform", classing: .init(settings: .init(), identities: []))
        XCTAssertEqual(why(run)?.hasPrefix("envs/acme's workspace is now acme-stage, not default"), true, why(run) ?? "\(run.phase)")
        // One that doesn't exist says that first: the trap of 4.9.
        try write("envs/acme/.terraform/environment", "acme-ghost\n")
        let ghost = TerraformPlanRun(kind: .plan, checkout: folder, card: card)
        await ghost.start(registry: TerraformRunRegistry(), settingPath: "/nonexistent/terraform", classing: .init(settings: .init(), identities: []))
        XCTAssertEqual(why(ghost)?.contains("acme-ghost no longer exists"), true, why(ghost) ?? "\(ghost.phase)")
    }

    @MainActor func testAClassNowProductionIsRefused() async throws {
        try write("envs/acme/main.tf", "resource \"terraform_data\" \"acme\" {}\n")
        let local = card("envs/acme")
        XCTAssertEqual(local.rootClass, .local)
        let identity = try XCTUnwrap(local.identity)
        // Since the card, the same state was seen production elsewhere (sticky, 5.1).
        let now = TerraformPlanRun.Classing(settings: .init(), identities: [identity])
        let person = TerraformPlanRun(kind: .plan, checkout: folder, card: local)
        await person.start(registry: TerraformRunRegistry(), settingPath: "/nonexistent/terraform", classing: now)
        XCTAssertEqual(why(person)?.contains("is production now"), true, why(person) ?? "\(person.phase)")
        XCTAssertEqual(why(person)?.contains("plan it again from the panel"), true)
        let agent = TerraformPlanRun(kind: .plan, checkout: folder, card: local, agent: "Claude Code", lockWait: .agent)
        await agent.start(registry: TerraformRunRegistry(), settingPath: "/nonexistent/terraform", classing: now)
        XCTAssertEqual(why(agent)?.contains("an agent doesn't plan it"), true, why(agent) ?? "\(agent.phase)")
        // The card already production, the person asked first: no refusal from the class.
        let asked = card("envs/acme", identities: [identity])
        XCTAssertEqual(asked.rootClass, .production)
        XCTAssertNil(TerraformPlanRun(kind: .plan, checkout: folder, card: asked).changedSinceCard(asked.facts, varFiles: [], profile: nil, classing: now))
        XCTAssertNotNil(
            TerraformPlanRun(kind: .plan, checkout: folder, card: asked, agent: "Claude Code").changedSinceCard(asked.facts, varFiles: [], profile: nil, classing: now),
            "an agent never plans production")
    }

    // MARK: Agents

    func testAnAgentsAllowanceHoldsOnlyWhileItsCodeRunsNothingNew() {
        let before = TerraformRunRisks.risks(config: TerraformConfigFacts.read(["resource \"terraform_data\" \"acme\" {}\n"]), lockProviders: nil)
        XCTAssertTrue(TerraformPlanGate.agentAsks(approved: nil, risks: before), "the first tf_plan per root and session asks")
        let approved = Set(before)
        XCTAssertFalse(TerraformPlanGate.agentAsks(approved: approved, risks: before), "the same code: not again")
        // The agent adds a data source that runs a command, and calls tf_plan again.
        let after = TerraformRunRisks.risks(
            config: TerraformConfigFacts.read(["resource \"terraform_data\" \"acme\" {}\ndata \"external\" \"acme\" {\n  program = [\"sh\", \"x\"]\n}\n"]),
            lockProviders: nil)
        XCTAssertTrue(TerraformPlanGate.agentAsks(approved: approved, risks: after), "a new risk asks again")
        let question = TerraformPlanGate.question(
            root: "envs/acme", workspace: "default", rootClass: .local, profile: "acme-dev", firstOnProduction: false, authoredByPerson: true, newRisks: [],
            allRisks: after, agent: "Claude Code")
        XCTAssertEqual(question?.detail.contains("data.external runs a command"), true)
        XCTAssertFalse(TerraformPlanGate.agentAsks(approved: approved.union(after), risks: after), "once approved with it")
        // A provider added to the lock file is a new risk too.
        let provider = [TerraformLockFile.Provider("registry.terraform.io/acme/acme")!]
        XCTAssertTrue(
            TerraformPlanGate.agentAsks(
                approved: approved, risks: TerraformRunRisks.risks(config: TerraformConfigFacts.read(["resource \"terraform_data\" \"acme\" {}\n"]), lockProviders: provider)))
    }

    func testTheAgentsQuestionNamesTheProfile() {
        func ask(_ profile: String?) -> String {
            TerraformPlanGate.question(
                root: "envs/acme", workspace: "default", rootClass: .local, profile: profile, firstOnProduction: false, authoredByPerson: true, newRisks: [],
                allRisks: [], agent: "Claude Code")?.detail ?? ""
        }
        XCTAssertTrue(ask("acme-dev-admin").contains("with AWS_PROFILE acme-dev-admin"), ask("acme-dev-admin"))
        XCTAssertTrue(ask(nil).contains("with your default credentials"), ask(nil))
        XCTAssertTrue(ask(nil).contains("outside the agent's sandbox"))
    }

    // MARK: Whose code

    func testWhoseCodeItIs() {
        XCTAssertEqual(TerraformPlanGate.authoredByPerson(authors: ["acme@example.test", "ACME@example.test\n"], me: "acme@example.test\n"), true)
        XCTAssertEqual(
            TerraformPlanGate.authoredByPerson(authors: ["acme@example.test", "globex@example.test"], me: "acme@example.test"), false,
            "a teammate's commits under one of the person's: not theirs")
        XCTAssertNil(TerraformPlanGate.authoredByPerson(authors: ["acme@example.test"], me: nil), "no user.email: can't be told")
        XCTAssertNil(TerraformPlanGate.authoredByPerson(authors: ["acme@example.test"], me: "  "))
        XCTAssertNil(TerraformPlanGate.authoredByPerson(authors: [], me: "acme@example.test"))
        let unknown = TerraformPlanGate.question(
            root: "envs/acme", workspace: "default", rootClass: .local, profile: nil, firstOnProduction: false, authoredByPerson: nil, newRisks: [],
            allRisks: [TerraformRunRisk(kind: .command, detail: "data.external")])
        XCTAssertNotNil(unknown, "unknown is not theirs: asked")
        XCTAssertEqual(unknown?.detail.contains("data.external"), true, "with the whole risk list")
    }

    private func git(_ arguments: [String], email: String = "acme@example.test") throws {
        _ = try Git.runBlocking(
            URL(fileURLWithPath: "/usr/bin/git"), ["-c", "user.name=Acme", "-c", "user.email=\(email)", "-c", "commit.gpgsign=false"] + arguments, in: folder,
            success: [0], timeout: 20)
    }

    /// A repository: main, then a branch of a teammate's commit with one of
    /// the person's on top; the tfvars change committed on it.
    private func branch() throws -> String {
        try write("envs/dev/main.tf", "variable \"acme_name\" {}\n")
        try write("envs/dev/dev.tfvars", "# acme dev\nacme_name = \"acme-one\"\n")
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "acme@example.test"])
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", "acme"])
        let base = try Git.runBlocking(URL(fileURLWithPath: "/usr/bin/git"), ["rev-parse", "HEAD"], in: folder, success: [0], timeout: 10)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["checkout", "-q", "-b", "acme-change"])
        try write("envs/dev/dev.tfvars", "# acme dev\nacme_name = \"acme-two\"\n")
        try git(["commit", "-q", "-am", "globex's change"], email: "globex@example.test")
        try write("envs/dev/main.tf", "variable \"acme_name\" {\n  type = string\n}\n")
        try git(["commit", "-q", "-am", "acme's change"])
        return base
    }

    @MainActor func testEveryCommitOfTheBranchIsCompared() async throws {
        let base = try branch()
        let authored = await TerminalWindowController.authoredByPerson(folder, base: base)
        XCTAssertEqual(authored, false, "HEAD is the person's, the commit under it isn't")
        let head = await TerminalWindowController.authoredByPerson(folder, base: "HEAD")
        XCTAssertEqual(head, true, "on its own, HEAD's author is")
    }

    // MARK: Changed in this branch

    func testTheBranchsAddedLines() {
        let diff = """
            diff --git a/envs/dev/dev.tfvars b/envs/dev/dev.tfvars
            index 1..2 100644
            --- a/envs/dev/dev.tfvars
            +++ b/envs/dev/dev.tfvars
            @@ -2 +2 @@
            -acme_name = "acme-one"
            +acme_name = "acme-two"
            @@ -5,0 +6,3 @@
            +a
            +b
            +c
            diff --git a/envs/dev/README.md b/envs/dev/README.md
            +++ b/envs/dev/README.md
            @@ -1 +1 @@
            diff --git a/envs/dev/old.tf b/envs/dev/old.tf
            +++ /dev/null
            @@ -1,3 +0,0 @@
            """
        XCTAssertEqual(TerraformChangedLines.parse(diff), ["envs/dev/dev.tfvars": [2, 6, 7, 8]], "Terraform's files only; a deletion adds nothing")
        XCTAssertEqual(TerraformChangedLines.merged(["a.tf": [1]], ["a.tf": [2], "b.tf": [3]]), ["a.tf": [1, 2], "b.tf": [3]])
    }

    func testACommittedTfvarsLineIsChangedInThisBranch() async throws {
        let base = try branch()
        let lines = await TerraformChangedLines.read(checkout: folder, root: "envs/dev", base: base)
        XCTAssertEqual(lines["envs/dev/dev.tfvars"], [2], "committed on the branch, nothing uncommitted: still this branch's")
        XCTAssertEqual(lines["envs/dev/main.tf"], [1, 2, 3])
        let uncommitted = await TerraformChangedLines.read(checkout: folder, root: "envs/dev", base: "HEAD")
        XCTAssertTrue(uncommitted.isEmpty, "against HEAD: nothing")
    }
}
