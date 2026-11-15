import AppKit

/// Terraform stage 2f (docs/design/terraform/analysis.md 2.9, 5.5, 9): a
/// review tab's Terraform section — a branch's touched roots listed (a
/// module's change reaching every root that calls it, production first),
/// the checkout with its head found, planning it asks with its risk list
/// (the module's `data "external"` included) and nothing runs when the
/// question is declined; a head checked out nowhere offers a new worktree,
/// asked; the section reads only while its review shows, and one loaded
/// while hidden is read when it shows. A pull request (a fake `gh`): Post
/// asks with the whole comment — the masked summary, fenced, naming the
/// commit planned, no sentinel — and leaves out a plan of another commit;
/// no Post without a pull request, greyed without a plan.
///
/// A repository this scenario writes, `terraform_data` only; nothing is
/// planned (every question is declined, the posted plans are records made
/// here), so no terraform runs, and gh is a script that logs.
extension E2ERunner {
    func terraformC2fChecks(recorder: TerraformRecorder) async {
        let git = URL(fileURLWithPath: "/usr/bin/git")
        let repo = out("acme-review")
        let worktree = out("acme-review-globex")
        let identity = ["-c", "user.name=Acme", "-c", "user.email=acme@example.test"]
        func write(_ path: String, _ text: String) throws {
            let url = repo.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        do {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            _ = try Git.runBlocking(git, ["init", "-q", "-b", "main"], in: repo, success: [0], timeout: 10)
            try write("envs/dev/main.tf", "module \"net\" {\n  source = \"../../modules/acme-net\"\n}\nresource \"terraform_data\" \"acme\" {}\n")
            try write("envs/prod/main.tf", "module \"net\" {\n  source = \"../../modules/acme-net\"\n}\nresource \"terraform_data\" \"acme_prod\" {}\n")
            try write("envs/globex-sandbox/main.tf", "resource \"terraform_data\" \"globex\" {}\n")
            try write("modules/acme-net/main.tf", "variable \"acme_cidr\" {\n  default = \"10.0.0.0/16\"\n}\n")
            _ = try Git.runBlocking(git, ["add", "-A"], in: repo, success: [0], timeout: 10)
            _ = try Git.runBlocking(git, identity + ["commit", "-q", "-m", "acme"], in: repo, success: [0], timeout: 10)
            // A teammate's branch: the shared module now runs a command when planned.
            _ = try Git.runBlocking(git, ["checkout", "-q", "-b", "globex-change"], in: repo, success: [0], timeout: 10)
            try write("modules/acme-net/main.tf", "variable \"acme_cidr\" {\n  default = \"10.1.0.0/16\"\n}\ndata \"external\" \"globex\" {\n  program = [\"echo\", \"{}\"]\n}\n")
            _ = try Git.runBlocking(
                git, ["-c", "user.name=Globex", "-c", "user.email=globex@example.test", "commit", "-q", "-am", "globex"], in: repo, success: [0], timeout: 10)
            // And one checked out nowhere.
            _ = try Git.runBlocking(git, ["checkout", "-q", "-b", "acme-elsewhere", "main"], in: repo, success: [0], timeout: 10)
            try write("envs/dev/main.tf", "module \"net\" {\n  source = \"../../modules/acme-net\"\n}\nresource \"terraform_data\" \"acme_two\" {}\n")
            _ = try Git.runBlocking(git, identity + ["commit", "-q", "-am", "acme-two"], in: repo, success: [0], timeout: 10)
            _ = try Git.runBlocking(git, ["checkout", "-q", "main"], in: repo, success: [0], timeout: 10)
            _ = try Git.runBlocking(git, ["worktree", "add", "-q", worktree.path, "globex-change"], in: repo, success: [0], timeout: 10)
        } catch {
            return check("2f: the repository is written", false, "\(error)")
        }
        var made: [URL] = [worktree]
        defer {
            for url in made { _ = try? Git.runBlocking(git, ["worktree", "remove", "--force", url.path], in: repo, success: [0], timeout: 10) }
        }

        var questions: [TerraformPlanGate.Question] = []
        var answer = false
        app.terraformPlanQuestionRecorder = { question in
            questions.append(question)
            return answer
        }
        defer { app.terraformPlanQuestionRecorder = nil }
        let plansBefore = recorder.calls().filter { $0.subcommand == "plan" }.count

        // 1. The branch's touched roots: the module's change reaches both its callers.
        let review = app.openReview(.range(base: "main", head: "globex-change"), in: repo)
        let section = review.terraform
        check(
            "2f: a branch's touched roots are listed, production first",
            await eventually(15) { section.roots.map(\.path) == ["envs/prod", "envs/dev"] }, "\(section.roots.map(\.path)) \(section.state)")
        check("2f: envs/prod is production", section.roots.first?.isProduction == true)
        check("2f: each says why: through the module", section.roots.allSatisfy { $0.why == "through modules/acme-net" }, "\(section.roots.map(\.why))")
        check(
            "2f: plans run in the worktree with the branch's head",
            section.head.map { realPath($0.checkout.url) } == realPath(worktree), "\(String(describing: section.head))")
        check("2f: the sandbox, untouched, isn't listed", !section.roots.contains { $0.path == "envs/globex-sandbox" })
        if let view = app.reviewView {
            Self.accessibilityTree(true)
            check(
                "2f: the section shows above the diff, with Plan on each root",
                await eventually(3) {
                    Self.accessibilityPress("review.terraform", in: view, press: false)
                        && Self.accessibilityPress("review.terraform.plan.envs/dev", in: view, press: false)
                })
            Self.accessibilityTree(false)
        }

        // 2. Planning it asks, with its risk list; declined, nothing runs.
        guard let dev = section.roots.first(where: { $0.path == "envs/dev" }), let prod = section.roots.first(where: { $0.path == "envs/prod" }) else {
            return check("2f: envs/dev and envs/prod", false)
        }
        app.planTerraformFromReview(review, dev)
        check("2f: planning the branch asks", await eventually(10) { questions.count == 1 }, "\(questions)")
        let asked = questions.first
        check("2f: naming what is reviewed", asked?.title == "Plan envs/dev of globex-change?", asked?.title ?? "")
        check("2f: as code under review", asked?.detail.contains("which is under review") == true, asked?.detail ?? "")
        check(
            "2f: with its risk list: the module's command data source",
            asked?.detail.contains("data.external in modules/acme-net runs a command on this Mac when planned") == true, asked?.detail ?? "")
        app.planTerraformFromReview(review, prod)
        check("2f: production asks too, red", await eventually(10) { questions.count == 2 && questions.last?.production == true }, "\(questions)")
        await pause(0.5)
        check(
            "2f: declined, nothing planned", recorder.calls().filter { $0.subcommand == "plan" }.count == plansBefore,
            "\(recorder.calls().map(\.arguments))")
        check(
            "2f: no plan registered for it",
            section.head.map { TerraformRunRegistry.shared.latest(checkout: $0.checkout.url, root: "envs/dev") == nil } == true)
        check("2f: no pull request, nothing to post to", app.terraformReviewPullRequest(review) == nil)

        // 3. It reads only while its review shows.
        app.hideReviewPage(focus: false)
        let reads = section.reads
        await review.load()
        await pause(0.5)
        check("2f: a review loaded while hidden reads nothing of Terraform", section.reads == reads, "\(reads) → \(section.reads)")

        // 4. A head checked out nowhere: the roots as in this checkout, and a new worktree, asked.
        let elsewhere = app.openReview(.range(base: "main", head: "acme-elsewhere"), in: repo)
        check(
            "2f: a branch checked out nowhere lists its roots too",
            await eventually(15) { elsewhere.terraform.state == .read && elsewhere.terraform.roots.map(\.path) == ["envs/dev"] },
            "\(elsewhere.terraform.roots.map(\.path))")
        check("2f: with no checkout to plan in", elsewhere.terraform.head == nil)
        let target = TaskCreator.worktreePath(repo: repo, branch: "acme-elsewhere", location: Settings.shared.worktreeLocation)
        made.append(target)
        answer = true
        app.checkOutForTerraform(elsewhere)
        check(
            "2f: Check Out in a New Worktree asks first",
            await eventually(10) { questions.count == 3 && questions.last?.title == "Check out acme-elsewhere in a new worktree?" },
            questions.last?.title ?? "")
        check(
            "2f: then plans can run there",
            await eventually(15) { elsewhere.terraform.head.map { self.realPath($0.checkout.url) } == self.realPath(target) },
            "\(String(describing: elsewhere.terraform.head))")
        check(
            "2f: and nothing was planned by it", recorder.calls().filter { $0.subcommand == "plan" }.count == plansBefore && questions.count == 3)
        check(
            "2f: its roots prepared as New Task's (the workspace note, init without a backend)",
            await eventually(15) { TerraformWorktreeSetup.shared.report(target)?.roots.contains { $0.path == "envs/dev" } == true },
            "\(TerraformWorktreeSetup.shared.report(target)?.roots.map(\.path) ?? [])")

        app.closeReview(elsewhere)
        app.closeReview(review)
        await terraformC2fPostChecks(repo: repo, worktree: worktree, questions: { questions }, answer: { answer = $0 })
    }

    /// A pull request's review (gh a script): read when shown after loading
    /// hidden; Post asks with the comment and posts only its head's plans.
    private func terraformC2fPostChecks(repo: URL, worktree: URL, questions: @escaping () -> [TerraformPlanGate.Question], answer: @escaping (Bool) -> Void) async {
        let git = URL(fileURLWithPath: "/usr/bin/git")
        let folder = out("acme-review-gh")
        let gh = folder.appendingPathComponent("gh")
        let posted = folder.appendingPathComponent("posted.txt")
        let sentinel = "globex-sentinel-4f2a9c"
        let globexHead: String
        let mainHead: String
        do {
            globexHead = try Git.runBlocking(git, ["rev-parse", "globex-change"], in: repo, success: [0], timeout: 10)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            mainHead = try Git.runBlocking(git, ["rev-parse", "main"], in: repo, success: [0], timeout: 10).trimmingCharacters(in: .whitespacesAndNewlines)
            let diff = try Git.runBlocking(git, ["diff", "main...globex-change"], in: repo, success: [0], timeout: 10)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try diff.write(to: folder.appendingPathComponent("pr.diff"), atomically: true, encoding: .utf8)
            try Self.terraformC2fGh(folder: folder.path, head: globexHead).write(to: gh, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        } catch {
            return check("2f: the pull request's gh is written", false, "\(error)")
        }
        GitHub.executableOverride = gh
        defer { GitHub.executableOverride = nil }

        // Loaded while hidden: nothing read then, read once shown.
        let review = app.openReview(.pullRequest(number: 42), in: repo)
        app.hideReviewPage(focus: false)
        let section = review.terraform
        check("2f: a pull request's review loads hidden", await eventually(15) { review.phase == .loaded }, "\(review.phase)")
        await pause(0.3)
        check("2f: and reads nothing of Terraform while hidden", section.reads == 0 && section.roots.isEmpty, "\(section.reads)")
        app.showReview(review)
        check(
            "2f: shown, its section is read",
            await eventually(15) { section.reads == 1 && section.roots.map(\.path) == ["envs/prod", "envs/dev"] }, "\(section.roots.map(\.path))")
        check(
            "2f: its head is the worktree at the pull request's commit",
            await eventually(5) { section.head.map { self.realPath($0.checkout.url) } == self.realPath(worktree) && section.head?.isReviewed == true },
            "\(String(describing: section.head))")
        check("2f: it has a pull request to post to", app.terraformReviewPullRequest(review) == 42)
        check("2f: Post is greyed with no plan", !section.canPost(.shared))
        guard let head = section.head, let dev = section.cards["envs/dev"], let prod = section.cards["envs/prod"] else {
            return check("2f: the pull request's cards", false)
        }

        // Two plans there: envs/dev at the pull request's head, envs/prod at another commit.
        var runs: [TerraformPlanRun] = []
        defer { for run in runs { TerraformRunRegistry.shared.discard(run) } }
        for (card, commit) in [(dev, globexHead), (prod, mainHead)] {
            let run = TerraformPlanRun(kind: .plan, checkout: head.checkout.url, card: card, branch: "globex-change @ " + commit.prefix(7))
            run.commit = commit
            guard let record = Self.terraformC2fRecord(sentinel: sentinel) else { return check("2f: a plan record", false) }
            run.landed(record)
            TerraformRunRegistry.shared.add(run)
            runs.append(run)
        }
        check("2f: with a plan, Post can be pressed", section.canPost(.shared))
        let before = questions().count
        answer(true)
        app.postTerraformPlans(review)
        check("2f: Post asks first", await eventually(10) { questions().count == before + 1 }, "\(questions().map(\.title))")
        let asked = questions().last
        check("2f: naming the pull request", asked?.title == "Post to pull request #42?", asked?.title ?? "")
        check(
            "2f: then gh posts it",
            await eventually(10) { ((try? String(contentsOf: posted, encoding: .utf8)) ?? "").isEmpty == false })
        let text = (try? String(contentsOf: posted, encoding: .utf8)) ?? ""
        check("2f: what was asked is what was posted", !text.isEmpty && asked?.detail.contains(text) == true)
        check("2f: the masked summary, fenced", text.contains("```text\nTerraform plan · envs/dev") && text.hasSuffix("\n```"), text)
        check("2f: naming the commit planned", text.contains("globex-change @ " + globexHead.prefix(7)), text)
        check("2f: no secret in it", !text.contains(sentinel) && asked?.detail.contains(sentinel) == false)
        check("2f: another commit's plan is not posted", !text.contains("envs/prod"), text)
        check(
            "2f: and the question says it was left out",
            asked?.detail.contains("envs/prod: planned at \(mainHead.prefix(7)), not the pull request's head \(globexHead.prefix(7))") == true,
            asked?.detail ?? "")
        answer(false)
        app.closeReview(review)
    }

    /// gh for pull request #42 from this repository: its diff, its head, and
    /// a comment's body written to `posted.txt`.
    private static func terraformC2fGh(folder: String, head: String) -> String {
        #"""
        #!/usr/bin/python3
        import json, sys, time
        FOLDER = "\#(folder)"
        args = sys.argv[1:]
        if args[:3] == ["pr", "diff", "42"]:
            time.sleep(0.5)
            sys.stdout.write(open(FOLDER + "/pr.diff").read())
        elif args[:3] == ["pr", "view", "42"]:
            print(json.dumps({"number": 42, "title": "Globex network", "headRefName": "globex-change", "headRefOid": "\#(head)",
                "isCrossRepository": False, "baseRefName": "main", "state": "OPEN", "isDraft": False, "url": "https://github.com/acme/infra/pull/42",
                "statusCheckRollup": [], "body": "", "author": {"login": "globex"}, "additions": 3, "deletions": 1, "changedFiles": 1,
                "comments": [], "reviews": []}))
        elif args[:3] == ["pr", "comment", "42"]:
            open(FOLDER + "/posted.txt", "w").write(args[args.index("--body") + 1])
            print("https://github.com/acme/infra/pull/42#issuecomment-1")
        else:
            sys.stderr.write("fake gh: unexpected %s\n" % args)
            sys.exit(2)
        """#
    }

    /// A held plan (nothing to apply) of one create whose value Terraform marks sensitive.
    private static func terraformC2fRecord(sentinel: String) -> TerraformPlanRecord? {
        let json = """
            {"format_version": "1.2", "terraform_version": "1.17.1", "applyable": true, "complete": true, "resource_changes": [
             {"address": "terraform_data.acme", "mode": "managed", "type": "terraform_data", "name": "acme", "provider_name": "terraform.io/builtin/terraform",
              "change": {"actions": ["create"], "before": null, "after": {"input": {"password": "\(sentinel)"}}, "after_unknown": {"output": true},
               "before_sensitive": false, "after_sensitive": {"input": {"password": true}}}}]}
            """
        guard let plan = try? TerraformPlan.decode(Data(json.utf8), scrub: TerraformPlan.scrub) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-review-\(UUID().uuidString)")
        guard (try? Data("PK\u{3}\u{4}".utf8).write(to: url)) != nil else { return nil }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        unlink(url.path)
        guard fd >= 0 else { return nil }
        return TerraformPlanRecord(
            plan: plan, file: TerraformPlanFile(descriptor: fd, sha256: "", size: 4, mode: 0o600), binary: URL(fileURLWithPath: "/nonexistent/terraform"),
            version: "1.17.1", environment: [:], dataDir: "", workspace: "default", status: 2)
    }
}
