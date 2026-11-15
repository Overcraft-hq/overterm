import XCTest

@testable import Overterm

/// Stage 2f: a review tab's Terraform section — the roots what is reviewed
/// touches (directly, through modules, new ones), which checkout has its
/// head, the question that always asks before planning it (5.5), and the
/// pull request's comment, masked and fenced.
final class TerraformReviewTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ot-tf-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("envs/dev/main.tf", "module \"net\" {\n  source = \"../../modules/acme-net\"\n}\nresource \"terraform_data\" \"acme\" {}\n")
        try write(
            "envs/prod/main.tf",
            "terraform {\n  backend \"s3\" {\n    bucket = \"acme-tfstate\"\n    key    = \"prod/network.tfstate\"\n    region = \"eu-west-1\"\n  }\n}\nmodule \"net\" {\n  source = \"../../modules/acme-net\"\n}\n"
        )
        try write("envs/globex-sandbox/main.tf", "resource \"terraform_data\" \"globex\" {}\n")
        try write("modules/acme-net/main.tf", "module \"inner\" {\n  source = \"../acme-inner\"\n}\nvariable \"acme_cidr\" {}\n")
        try write("modules/acme-inner/main.tf", "data \"external\" \"acme\" {\n  program = [\"echo\"]\n}\n")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func write(_ path: String, _ text: String) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private var listing: TerraformRootScan.Listing {
        TerraformRootScan.Listing(
            folders: [
                "envs/dev": ["main.tf"], "envs/prod": ["main.tf"], "envs/globex-sandbox": ["main.tf"], "modules/acme-net": ["main.tf"],
                "modules/acme-inner": ["main.tf"],
            ], capped: false)
    }

    private func read(_ changed: [String], listing: TerraformRootScan.Listing? = nil) -> TerraformReviewModel.Read {
        TerraformReviewModel.assemble(
            checkout: folder, listing: listing ?? self.listing, changed: changed, settings: TerraformClassSettings(), identities: [], awsProfile: nil)
    }

    // MARK: Touched roots

    func testAModuleChangeTouchesEveryRootThatCallsIt() {
        let read = read(["modules/acme-inner/main.tf"])
        XCTAssertEqual(read.roots.map(\.path), ["envs/prod", "envs/dev"], "production first, then by path; the sandbox untouched")
        XCTAssertEqual(read.roots.first?.rootClass, .production)
        XCTAssertEqual(read.roots.map(\.why), ["through modules/acme-inner", "through modules/acme-inner"])
        XCTAssertTrue(read.roots.allSatisfy(\.present))
        XCTAssertEqual(Set(read.cards.map(\.path)), ["envs/dev", "envs/prod"], "only the touched roots' cards are kept")
    }

    func testADirectChangeSaysItsFile() {
        let read = read(["envs/dev/main.tf", "README.md"])
        XCTAssertEqual(read.roots.map(\.path), ["envs/dev"])
        XCTAssertEqual(read.roots.first?.why, "envs/dev/main.tf")
        let two = self.read(["envs/dev/main.tf", "envs/dev/dev.tfvars", "modules/acme-net/main.tf"])
        XCTAssertEqual(two.roots.first { $0.path == "envs/dev" }?.why, "2 files · through modules/acme-net")
    }

    func testNothingTerraformsChangedNothingListed() {
        XCTAssertTrue(read(["Sources/App.swift", "docs/x.md"]).roots.isEmpty)
        XCTAssertTrue(
            TerraformReviewModel.assemble(
                checkout: folder, listing: nil, changed: ["README.md"], settings: TerraformClassSettings(), identities: [], awsProfile: nil
            ).roots.isEmpty, "no listing and no Terraform file: no read at all")
    }

    func testARootTheReviewAddsIsListedAsNew() {
        let read = read(["envs/acme-new/main.tf"])
        XCTAssertEqual(read.roots.map(\.path), ["envs/acme-new"])
        XCTAssertEqual(read.roots.first?.present, false, "its files aren't in this checkout")
        XCTAssertEqual(
            TerraformReview.listing(["envs/dev": ["main.tf"]], adding: ["envs/dev/main.tf", "envs/x/a.tf", "envs/.terraform/b.tf", "a/README.md"]),
            ["envs/dev": ["main.tf"], "envs/x": ["a.tf"]])
    }

    func testARenameCountsBothPaths() {
        let files = [ChangedFile(path: "envs/staging/main.tf", originalPath: "envs/dev/main.tf", kind: .renamed, isStaged: false, hasUnstaged: false)]
        XCTAssertEqual(TerraformReview.changedPaths(files), ["envs/staging/main.tf", "envs/dev/main.tf"])
    }

    func testModuleRisksAreTheModulesTheRootCallsThroughOthersToo() {
        let read = read(["modules/acme-net/main.tf"])
        XCTAssertEqual(read.moduleRisks["envs/dev"], [TerraformRunRisk(kind: .command, detail: "data.external in modules/acme-inner")])
        XCTAssertEqual(read.moduleRisks["envs/prod"]?.first?.said, "data.external in modules/acme-inner runs a command on this Mac when planned")
        XCTAssertNil(read.unreadModules["envs/dev"], "every module it calls was read")
    }

    func testAModuleNotReadIsSaidNotCalledHarmless() throws {
        // envs/dev calls a module listed but not in this checkout: its code can't be read.
        try write(
            "envs/dev/main.tf",
            "module \"net\" {\n  source = \"../../modules/acme-net\"\n}\nmodule \"gone\" {\n  source = \"../../modules/acme-gone\"\n}\n")
        var folders = listing.folders
        folders["modules/acme-gone"] = ["main.tf"]
        let read = read(["envs/dev/main.tf"], listing: TerraformRootScan.Listing(folders: folders, capped: false))
        XCTAssertEqual(read.unreadModules["envs/dev"], 1)
        let question = try XCTUnwrap(
            TerraformPlanGate.question(
                root: "envs/dev", workspace: "default", rootClass: .local, profile: nil, firstOnProduction: false, authoredByPerson: true,
                newRisks: [], allRisks: [], reviewing: "globex-change", unreadModules: 201))
        XCTAssertTrue(question.detail.contains("201 modules it calls weren't read"), question.detail)
        XCTAssertFalse(question.detail.contains("Nothing in its root's code"), "no all-clear when modules weren't read")
    }

    // MARK: Where its head is

    func testWhichCheckoutHasTheHead() {
        let me = TerraformReview.Checkout(url: URL(fileURLWithPath: "/w/acme"), branch: "main", head: "1111111aaaa")
        let feature = TerraformReview.Checkout(url: URL(fileURLWithPath: "/w/acme-wt-globex"), branch: "globex-change", head: "2222222bbbb")
        let detached = TerraformReview.Checkout(url: URL(fileURLWithPath: "/w/acme-wt-review"), branch: nil, head: "3333333cccc")
        let all = [me, feature, detached]
        let branch = ReviewSource.branch(mergeBase: "0000000", base: "main", branch: "main")
        XCTAssertEqual(TerraformReview.head(of: branch, review: me, wanted: nil, checkouts: all)?.checkout, me, "the branch is the checkout itself")
        let range = ReviewSource.range(base: "main", head: "globex-change")
        XCTAssertEqual(TerraformReview.head(of: range, review: me, wanted: TerraformReview.wanted(range), checkouts: all)?.checkout, feature)
        let commit = ReviewSource.commits(from: "3333333", to: "3333333cccc")
        XCTAssertEqual(TerraformReview.head(of: commit, review: me, wanted: TerraformReview.wanted(commit), checkouts: all)?.checkout, detached)
        let elsewhere = ReviewSource.range(base: "main", head: "acme-elsewhere")
        XCTAssertNil(TerraformReview.head(of: elsewhere, review: me, wanted: TerraformReview.wanted(elsewhere), checkouts: all))

        let pr = ReviewSource.pullRequest(number: 42)
        XCTAssertNil(TerraformReview.wanted(pr), "before gh said its branch: nothing")
        let atHead = TerraformReview.head(
            of: pr, review: me, wanted: TerraformReview.wanted(pr, pullRequestBranch: "globex-change", pullRequestHead: "2222222bbbbcccc"), checkouts: all)
        XCTAssertEqual(atHead?.checkout, feature)
        XCTAssertNil(atHead?.note)
        let behind = TerraformReview.head(
            of: pr, review: me, wanted: TerraformReview.wanted(pr, pullRequestBranch: "globex-change", pullRequestHead: "9999999ffff"), checkouts: all)
        XCTAssertEqual(behind?.checkout, feature)
        XCTAssertEqual(behind?.note, "globex-change here is at 2222222, not the reviewed 9999999: pull it, then Reload — Plan and Post wait for it")
        XCTAssertEqual(behind?.isReviewed, false, "a branch of other code is never planned as the review's")
        XCTAssertNil(TerraformReview.wanted(pr, pullRequestBranch: "globex-change"), "a branch alone, no commit: nothing")
        XCTAssertFalse(TerraformReview.sameCommit("abc", "abcdef0"), "too short to say")
    }

    func testAForkMatchesByCommitNeverByItsBranchName() {
        let me = TerraformReview.Checkout(url: URL(fileURLWithPath: "/w/acme"), branch: "main", head: "1111111aaaa")
        let pr = ReviewSource.pullRequest(number: 43)
        // A contributor's fork, from their `main`: the person's own main is not it.
        let fork = TerraformReview.wanted(pr, pullRequestBranch: "main", pullRequestHead: "4444444dddd", crossRepository: true)
        XCTAssertEqual(fork, TerraformReview.Wanted(branch: nil, commit: "4444444dddd"))
        XCTAssertNil(TerraformReview.head(of: pr, review: me, wanted: fork, checkouts: [me]), "Check Out is offered instead")
        let detached = TerraformReview.Checkout(url: URL(fileURLWithPath: "/w/acme-pr-43"), branch: nil, head: "4444444dddd")
        XCTAssertEqual(TerraformReview.head(of: pr, review: me, wanted: fork, checkouts: [me, detached])?.checkout, detached)
        // The same repository's: its branch, at its commit first.
        let same = TerraformReview.wanted(pr, pullRequestBranch: "main", pullRequestHead: "1111111aaaa", crossRepository: false)
        XCTAssertEqual(TerraformReview.head(of: pr, review: me, wanted: same, checkouts: [me, detached])?.checkout, me)
    }

    func testARemoteBranchHeadMatchesItsDetachedCheckout() {
        let me = TerraformReview.Checkout(url: URL(fileURLWithPath: "/w/acme"), branch: "main", head: "1111111aaaa")
        let detached = TerraformReview.Checkout(url: URL(fileURLWithPath: "/w/acme-review-origin"), branch: nil, head: "5555555eeee")
        let range = ReviewSource.range(base: "main", head: "origin/globex")
        let wanted = TerraformReview.wanted(range, resolved: "5555555eeeeffff")
        XCTAssertEqual(wanted, TerraformReview.Wanted(branch: "origin/globex", commit: "5555555eeeeffff"))
        XCTAssertEqual(TerraformReview.head(of: range, review: me, wanted: wanted, checkouts: [me, detached])?.checkout, detached)
    }

    func testWhatIsReviewedIsSaid() {
        XCTAssertEqual(TerraformReview.reviewing(.pullRequest(number: 7)), "pull request #7")
        XCTAssertEqual(TerraformReview.reviewing(.range(base: "main", head: "globex-change"), pullRequest: 9), "pull request #9")
        XCTAssertEqual(TerraformReview.reviewing(.range(base: "main", head: "globex-change")), "globex-change")
        XCTAssertEqual(TerraformReview.reviewing(.commits(from: String(repeating: "a", count: 40), to: String(repeating: "a", count: 40))), "commit aaaaaaa")
    }

    // MARK: Planning it always asks (5.5)

    func testPlanningAReviewAlwaysAsksWithEveryRisk() throws {
        let risks = [TerraformRunRisk(kind: .command, detail: "data.external in modules/acme-inner")]
        // The person's own commits, nothing new, not production: a plain plan wouldn't ask.
        XCTAssertNil(
            TerraformPlanGate.question(
                root: "envs/dev", workspace: "default", rootClass: .local, profile: nil, firstOnProduction: false, authoredByPerson: true,
                newRisks: [], allRisks: risks))
        let question = try XCTUnwrap(
            TerraformPlanGate.question(
                root: "envs/dev", workspace: "default", rootClass: .local, profile: nil, firstOnProduction: false, authoredByPerson: true,
                newRisks: [], allRisks: risks, reviewing: "pull request #42"))
        XCTAssertEqual(question.title, "Plan envs/dev of pull request #42?")
        XCTAssertTrue(question.detail.contains("pull request #42, which is under review"), question.detail)
        XCTAssertTrue(question.detail.contains("data.external in modules/acme-inner runs a command on this Mac when planned"), question.detail)
        XCTAssertFalse(question.production)
        let none = try XCTUnwrap(
            TerraformPlanGate.question(
                root: "envs/dev", workspace: "default", rootClass: .local, profile: nil, firstOnProduction: false, authoredByPerson: true,
                newRisks: [], allRisks: [], reviewing: "globex-change"))
        XCTAssertTrue(none.detail.contains("Nothing in its root's code runs a command"), "asked even with an empty list, which says so")
        let production = try XCTUnwrap(
            TerraformPlanGate.question(
                root: "envs/prod", workspace: "default", rootClass: .production, profile: "acme-prod-admin", firstOnProduction: true,
                authoredByPerson: false, newRisks: [], allRisks: risks, reviewing: "globex-change"))
        XCTAssertTrue(production.production)
        XCTAssertTrue(production.detail.contains("with AWS_PROFILE acme-prod-admin"))
        XCTAssertFalse(production.detail.contains("Commits on this branch aren't yours"), "the review's sentence says it once")
    }

    // MARK: Posting

    func testTheCommentIsTheMaskedSummaryFenced() throws {
        let plan = try TerraformPlan.decode(Data(TerraformPlanReadingTests.planted.utf8), scrub: TerraformPlan.scrub)
        let summary = TerraformPlanText.copySummary(plan, root: "envs/prod", workspace: "default", branch: "globex-change @ 2222222")
        let text = TerraformReview.comment([TerraformReview.PostedPlan(summary: summary, planned: nil, age: "2 min ago", stale: nil)])
        for sentinel in TerraformPlanReadingTests.sentinels {
            XCTAssertFalse(text.contains(sentinel), "no secret is posted: \(sentinel)")
        }
        XCTAssertTrue(text.contains("```text\nTerraform plan · envs/prod · workspace default · globex-change @ 2222222\n"), text)
        XCTAssertTrue(text.contains("terraform_data.acme"))
        XCTAssertTrue(text.hasSuffix("\n```"))
    }

    func testAnAddressCantCloseTheFenceOrMentionAnyone() {
        let summary = "Terraform plan · x\n± aws_iam.a[\"````\"]  replace\n@globex-team"
        let text = TerraformReview.comment([TerraformReview.PostedPlan(summary: summary, planned: "@acme-bot #12", age: "just now", stale: "applied from `x`")])
        XCTAssertTrue(text.contains("`````text\n"), "a fence longer than the longest run inside")
        XCTAssertTrue(text.contains("@\u{200B}acme-bot #\u{200B}12"), "the header line notifies nobody, links nothing")
        XCTAssertTrue(text.contains("stale: applied from \\`x\\`"))
        XCTAssertEqual(TerraformReview.longestBacktickRun("a``b````c"), 4)
    }

    func testOnlyPlansOfThePullRequestsHeadArePosted() {
        let head = "2222222bbbbcccc"
        func candidate(_ root: String, _ commit: String?, mode: TerraformPlanMode = .normal, uncommitted: Bool = false) -> TerraformReview.Candidate {
            TerraformReview.Candidate(root: root, summary: "plan of \(root)", commit: commit, uncommitted: uncommitted, mode: mode, age: "just now", stale: nil)
        }
        let (plans, skipped) = TerraformReview.postable(
            [
                candidate("envs/dev", "2222222bbbbcccc"), candidate("envs/prod", "1111111aaaa"), candidate("envs/qa", nil),
                candidate("envs/stage", head, mode: .destroy), candidate("envs/sandbox", head, uncommitted: true),
            ], head: head, branch: "globex-change")
        XCTAssertEqual(plans, [TerraformReview.PostedPlan(summary: "plan of envs/dev", planned: "globex-change @ 2222222", age: "just now", stale: nil)])
        XCTAssertEqual(skipped.count, 4)
        XCTAssertEqual(skipped.first, "envs/prod: planned at 1111111, not the pull request's head 2222222 — plan it again")
        XCTAssertTrue(skipped.contains { $0.hasPrefix("envs/qa: which commit it planned isn't known") })
        XCTAssertTrue(skipped.contains { $0.hasPrefix("envs/stage: a ") && $0.hasSuffix("plan, not the whole root's") }, "\(skipped)")
        XCTAssertTrue(skipped.contains("envs/sandbox: planned with uncommitted changes in its checkout"))
        let text = TerraformReview.comment(plans)
        XCTAssertTrue(text.contains("Planned just now at globex-change @\u{200B} 2222222"), "the comment names the commit planned: \(text)")
    }

    /// A plan applied since it was made has nothing left to post: left
    /// out with why, never posted as the head's plan.
    func testAnAppliedPlanIsLeftOut() {
        let head = "2222222bbbbcccc"
        let applied = TerraformReview.Candidate(root: "envs/dev", summary: "", commit: head, age: "2 min ago", held: false)
        let (plans, skipped) = TerraformReview.postable([applied], head: head, branch: "globex-change")
        XCTAssertTrue(plans.isEmpty)
        XCTAssertEqual(skipped, ["envs/dev: its plan has been applied since — plan it again for what is left to change"])
    }

    /// An untracked file the root loads makes its plan another code's
    /// than the commit's: a .tf or var file, not a note, nor what git ignores.
    func testAnUntrackedFileTheRootLoadsIsUncommitted() async throws {
        let user = ["-c", "user.name=Acme", "-c", "user.email=acme@example.test"]
        try write(".gitignore", ".terraform/\n")
        _ = try await Git.run(["init", "-q", "-b", "main"], in: folder)
        _ = try await Git.run(["add", "-A"], in: folder)
        _ = try await Git.run(user + ["commit", "-q", "-m", "acme"], in: folder)
        let dev = folder.appendingPathComponent("envs/dev", isDirectory: true)
        try write("envs/dev/NOTES.md", "acme\n")
        try write("envs/dev/.terraform/modules/acme.tf", "# init's\n")
        try write("envs/prod/scratch.tf", "resource \"terraform_data\" \"globex\" {}\n")
        var planned = await TerminalWindowController.plannedCommit(folder, root: dev)
        XCTAssertNotNil(planned.0)
        XCTAssertFalse(planned.1, "a note, an ignored folder, another root's file: the commit's code")
        let untrackedNone = await TerminalWindowController.untrackedLoaded(under: dev)
        XCTAssertNil(untrackedNone)
        for name in ["scratch.tf", "acme.auto.tfvars", "globex.tfvars.json", "extra.tf.json"] {
            try write("envs/dev/" + name, "acme = 1\n")
            planned = await TerminalWindowController.plannedCommit(folder, root: dev)
            XCTAssertTrue(planned.1, name)
            try FileManager.default.removeItem(at: dev.appendingPathComponent(name))
        }
        try write("envs/dev/main.tf", "resource \"terraform_data\" \"acme\" {}\n")
        planned = await TerminalWindowController.plannedCommit(folder, root: dev)
        XCTAssertTrue(planned.1, "a tracked file changed")
    }

    func testOneOversizedPlanIsCutNotDropped() {
        let big = String(repeating: "± terraform_data.acme_x  replace\n", count: 5_000)
        let text = TerraformReview.comment([TerraformReview.PostedPlan(summary: big, planned: "globex-change @ 2222222", age: "just now", stale: nil)])
        XCTAssertLessThanOrEqual(text.count, TerraformReview.maxComment)
        XCTAssertTrue(text.contains("```text\n± terraform_data.acme_x  replace\n"), "its head is posted, fenced")
        XCTAssertTrue(text.contains("… cut: "), "and says it was cut")
        XCTAssertTrue(text.hasSuffix("than a comment holds\n```"), String(text.suffix(120)))
        XCTAssertFalse(text.contains("not posted"))
    }

    func testTheCommentStaysUnderGitHubsSize() {
        let big = String(repeating: "± terraform_data.acme_x  replace\n", count: 1_000)
        let plans = (0..<5).map { _ in TerraformReview.PostedPlan(summary: big, planned: nil, age: "just now", stale: nil) }
        let text = TerraformReview.comment(plans)
        XCTAssertLessThanOrEqual(text.count, TerraformReview.maxComment)
        XCTAssertTrue(text.hasSuffix("plans not posted: the comment is at GitHub's size."), String(text.suffix(120)))
    }
}
