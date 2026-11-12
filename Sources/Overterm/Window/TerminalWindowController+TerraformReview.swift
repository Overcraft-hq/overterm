import AppKit
import Combine

// MARK: A review's Terraform section (docs/design/terraform/analysis.md 2.2, 2.9, 5.5; stage 2f)

extension TerminalWindowController {
    var terraformReviewActions: TerraformReviewActions {
        TerraformReviewActions(
            plan: { [weak self] review, root in self?.planTerraformFromReview(review, root) },
            initialize: { [weak self] review, root in
                guard let head = review.terraform.head, let card = review.terraform.cards[root.path] else { return }
                self?.initTerraformRoot(card, checkout: head.checkout.url)
            },
            show: { [weak self] run in
                self?.hideReviewPage(focus: false)
                self?.showTerraformPlan(run)
            },
            post: { [weak self] review in self?.postTerraformPlans(review) },
            checkOut: { [weak self] review in self?.checkOutForTerraform(review) },
            pullRequest: { [weak self] review in self?.terraformReviewPullRequest(review) })
    }

    /// Its section is read each time the review loads (opened, Reload)
    /// while it is the one on screen — never while another shows; one
    /// that loaded hidden is read when it shows (`showTerraformReview`).
    func watchTerraformReview(_ review: ReviewModel) {
        // @Published emits before the change lands: the emitted phase is used,
        // the rest read once it has.
        review.$phase
            .sink { [weak self, weak review] phase in
                guard phase == .loaded else { return }
                Task { @MainActor in
                    guard let self, let review else { return }
                    guard self.store.reviewShowing == review.id else {
                        review.terraform.missed = true
                        return
                    }
                    self.readTerraformReview(review)
                }
            }
            .store(in: &review.terraform.cancellables)
    }

    /// A review shown: its section read if it loaded while hidden.
    func showTerraformReview(_ review: ReviewModel) {
        guard review.phase == .loaded, review.terraform.missed else { return }
        readTerraformReview(review)
    }

    /// The roots the review touches, read in the checkout with its head
    /// (else its own). Nothing for a review whose checkout has no roots
    /// and which changes no Terraform file; nothing with Terraform off.
    func readTerraformReview(_ review: ReviewModel) {
        let model = review.terraform
        guard Settings.shared.terraformEnabled, review.phase == .loaded, !review.files.isEmpty else { return model.clear() }
        let changed = TerraformReview.changedPaths(review.files)
        let terraformChanged = changed.contains { TerraformRootGuess.isTerraformName(($0 as NSString).lastPathComponent) }
        if !terraformChanged, TerraformCheckouts.shared.hasRoots(review.root) == false { return model.clear() }
        model.missed = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            let checkouts = await self.reviewCheckouts(review.root)
            let me = checkouts.first { Self.samePath($0.url, review.root) } ?? TerraformReview.Checkout(url: review.root)
            // A range's head as a commit too: a remote branch or a tag is checked out detached.
            var resolved: String?
            if case .range(_, let head) = review.source, !TerraformReview.isCommit(head) {
                resolved = await Self.commit(of: head, in: review.root)
            }
            let summary = review.pullRequest?.summary
            let wanted = TerraformReview.wanted(
                review.source, pullRequestBranch: summary?.branch, pullRequestHead: summary?.headOid,
                crossRepository: review.pullRequest?.crossRepository ?? true, resolved: resolved)
            let head = TerraformReview.head(of: review.source, review: me, wanted: wanted, checkouts: checkouts)
            model.read(changed: changed, checkout: head?.checkout.url ?? review.root, head: head, wanted: wanted)
        }
    }

    /// `ref` as a commit of `checkout`'s repository, or nil.
    nonisolated static func commit(of ref: String, in checkout: URL) async -> String? {
        guard !ref.hasPrefix("-") else { return nil }
        let sha = (try? await Git.run(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], in: checkout))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The commit a plan of `root` in `checkout` plans: its HEAD, and
    /// whether the files differ from it — a tracked file changed, or an
    /// untracked one under the root that Terraform loads (`untrackedLoaded`)
    /// — read without taking git's lock.
    nonisolated static func plannedCommit(_ checkout: URL, root: URL) async -> (String?, Bool) {
        let head = await commit(of: "HEAD", in: checkout)
        let status = try? await Git.run(["--no-optional-locks", "status", "--porcelain", "--untracked-files=no"], in: checkout)
        let tracked = status.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true
        if tracked { return (head, true) }
        return (head, await untrackedLoaded(under: root) != nil)
    }

    /// The first untracked file under `root` that Terraform loads with it —
    /// a `.tf`, `.tf.json`, `.tofu` or var file (`.tfvars`, `*.auto.tfvars`):
    /// an agent's or the person's scratch file is part of the plan, not of
    /// any commit. Git's ignores apply; "?" when git couldn't say.
    nonisolated static func untrackedLoaded(under root: URL) async -> String? {
        guard
            let listed = try? await Git.run(
                ["--no-optional-locks", "status", "--porcelain", "-z", "--untracked-files=all", "--", "."], in: root, outputLimit: 1 << 20)
        else { return "?" }
        for entry in listed.split(separator: "\0") where entry.hasPrefix("?? ") {
            let path = String(entry.dropFirst(3))
            if loadsWithRoot((path as NSString).lastPathComponent) { return path }
        }
        return nil
    }

    /// A file name Terraform reads into a plan of its folder.
    nonisolated static func loadsWithRoot(_ name: String) -> Bool {
        let lower = name.lowercased()
        return TerraformRootGuess.isConfigFile(lower) || lower.hasSuffix(".tfvars") || lower.hasSuffix(".tfvars.json")
    }

    nonisolated static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The repository's checkouts: the window's list when it is this
    /// repository's (CLAUDE.md: never asked twice), else one `git worktree list`.
    private func reviewCheckouts(_ root: URL) async -> [TerraformReview.Checkout] {
        var listed = worktrees.worktrees
        if !listed.contains(where: { Self.samePath($0.path, root) }) {
            listed = (try? await Git.run(["worktree", "list", "--porcelain"], in: root)).map(Worktree.parse(porcelain:)) ?? []
        }
        return listed.filter { !$0.isBare && !$0.isPrunable }.map { TerraformReview.Checkout(url: $0.path, branch: $0.branch, head: $0.head) }
    }

    /// The pull request a comment goes to: the review's, else the open one
    /// of the reviewed branch.
    func terraformReviewPullRequest(_ review: ReviewModel) -> Int? { reviewPullRequest(review)?.number }

    /// That pull request's number, head commit and branch, as gh said them.
    private func reviewPullRequest(_ review: ReviewModel) -> (number: Int, head: String?, branch: String?)? {
        if case .pullRequest(let number) = review.source {
            return (number, review.pullRequest?.summary.headOid, review.pullRequest?.summary.branch)
        }
        var branch = review.terraform.head?.checkout.branch
        switch review.source {
        case .branch(_, _, let name): branch = branch ?? name
        case .range(_, let head) where !TerraformReview.isCommit(head): branch = head
        default: break
        }
        guard let branch, let pr = worktrees.pullRequests[branch], pr.state == .open || pr.state == .draft else { return nil }
        return (pr.number, pr.headOid, pr.branch)
    }

    // MARK: Plan

    /// Plan, from the review: the root in the checkout with the head, always
    /// asked — code under review, whoever wrote it (5.5) —, with every risk
    /// of the root's code and of the modules it calls.
    /// The root's facts and its modules' risks are read again first — the
    /// checkout may have been pulled, edited or committed to since the
    /// review loaded —, and a checkout no longer at the reviewed commit
    /// isn't planned as the review's.
    func planTerraformFromReview(_ review: ReviewModel, _ root: TerraformReview.Root) {
        let model = review.terraform
        guard Settings.shared.terraformEnabled, let head = model.head, model.cards[root.path] != nil else { return NSSound.beep() }
        if let note = head.note { return alert("Not the reviewed code", note) }
        Task { @MainActor [weak self] in
            guard let self, let read = await model.reread(), let card = read.cards.first(where: { $0.path == root.path }) else { return }
            if let wanted = model.wanted?.commit {
                let now = await Self.commit(of: "HEAD", in: head.checkout.url)
                guard TerraformReview.sameCommit(now, wanted) else {
                    return self.alert(
                        "Not the reviewed code",
                        "\(head.checkout.url.lastPathComponent) is at \(now.map { String($0.prefix(7)) } ?? "another commit") now, not the reviewed \(wanted.prefix(7)): check it out there, then Reload."
                    )
                }
                // An untracked file the root loads is planned too: not the reviewed commit's code.
                if let extra = await Self.untrackedLoaded(under: card.folder) {
                    return self.alert(
                        "Not the reviewed code",
                        extra == "?"
                            ? "git couldn't list \(card.name)'s untracked files in \(head.checkout.url.lastPathComponent): nothing was planned."
                            : "\(extra) in \(head.checkout.url.lastPathComponent) isn't committed, and Terraform would plan it with \(card.name): commit, move or remove it, then plan."
                    )
                }
            }
            let base = await Self.reviewBase(review.source, base: review.pullRequest?.base, in: head.checkout.url)
            let plan = TerraformReviewPlan(
                reviewing: TerraformReview.reviewing(review.source, pullRequest: self.terraformReviewPullRequest(review)), base: base,
                moduleRisks: read.moduleRisks[root.path] ?? [], unreadModules: read.unreadModules[root.path] ?? 0,
                branch: head.checkout.name + (head.checkout.head.map { " @ " + $0.prefix(7) } ?? ""))
            self.planTerraformRoot(card, checkout: head.checkout.url, review: plan)
        }
    }

    /// What the reviewed code's risks and changed lines are read against:
    /// the review's own base, as a commit of the head's checkout. Nil: HEAD.
    static func reviewBase(_ source: ReviewSource, base prBase: String?, in checkout: URL) async -> String? {
        func verified(_ ref: String) async -> String? { await commit(of: ref, in: checkout) }
        func mergeBase(_ ref: String) async -> String? {
            guard await verified(ref) != nil else { return nil }
            let sha = (try? await Git.run(["merge-base", ref, "HEAD"], in: checkout))?.trimmingCharacters(in: .whitespacesAndNewlines)
            return sha.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch source {
        case .branch(let mergeBase, _, _): return mergeBase
        case .uncommitted: return nil
        case .range(let base, _): return await mergeBase(base)
        case .commits(let from, _): return await verified(from + "^1")
        case .paths(let base, _, _): return await verified(base)
        case .pullRequest:
            guard let prBase, !prBase.isEmpty, !prBase.hasPrefix("-") else { return nil }
            if let found = await mergeBase("origin/" + prBase) { return found }
            return await mergeBase(prBase)
        }
    }

    // MARK: Post to pull request

    /// "Post to Pull Request…" (2.2, 5.6 rule 8): each touched root's latest
    /// plan in the head's checkout as its masked summary — never
    /// `terraform show`'s text —, only plans of the pull request's head
    /// commit (others left out, said), the whole comment shown before `gh
    /// pr comment` posts it.
    func postTerraformPlans(_ review: ReviewModel) {
        guard let pr = reviewPullRequest(review), let head = review.terraform.head else { return NSSound.beep() }
        if let note = head.note { return alert("Not the reviewed code", note) }
        guard let prHead = pr.head, TerraformReview.isCommit(prHead) else {
            return alert("Nothing to post", "gh didn't say pull request #\(pr.number)'s head commit: Reload the review.")
        }
        let registry = TerraformRunRegistry.shared
        let candidates = review.terraform.roots.compactMap { root -> TerraformReview.Candidate? in
            guard let run = registry.latest(checkout: head.checkout.url, root: root.path) else { return nil }
            // Applied since: its changes are made — left out, said, never posted as the head's plan.
            if run.apply != nil, run.plan == nil {
                return TerraformReview.Candidate(root: root.path, summary: "", commit: run.commit, age: run.age(), held: false)
            }
            guard let plan = run.plan else { return nil }
            let causes = terraformPlanPane.run === run ? terraformPlanPane.causeTexts() : [:]
            return TerraformReview.Candidate(
                root: root.path,
                summary: TerraformPlanText.copySummary(plan, root: run.card.name, workspace: run.workspace, branch: run.branch, causes: causes),
                commit: run.commit, uncommitted: run.uncommitted, mode: run.mode, age: run.age(), stale: run.staleReason(registry, held: false))
        }
        let (plans, skipped) = TerraformReview.postable(candidates, head: prHead, branch: pr.branch)
        let leftOut = skipped.isEmpty ? "" : "\n\nLeft out:\n" + skipped.map { "• " + $0 }.joined(separator: "\n")
        guard !plans.isEmpty else {
            return alert("Nothing to post", "Plan the roots it touches at the pull request's head first: the comment is their plans." + leftOut)
        }
        let text = TerraformReview.comment(plans)
        let number = pr.number
        let question = TerraformPlanGate.Question(
            title: "Post to pull request #\(number)?",
            detail: "Posted as it reads here, masked by Terraform's sensitive marks and Overterm's rules:\n\n" + text + leftOut, button: "Post",
            production: false)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let recorder = self.terraformPlanQuestionRecorder {
                guard recorder(question) else { return }
            } else {
                let confirmation = WriteConfirmation(
                    title: question.title, scope: "GitHub · a comment everyone who can read the pull request sees", production: false,
                    detail: question.detail, button: question.button)
                guard await confirmation.ask(on: self.window) != nil else { return }
            }
            do {
                _ = try await GitHub.run(["pr", "comment", "\(number)", "--body", text], in: review.root, timeout: 60)
            } catch {
                self.alert("Not posted", error.localizedDescription)
            }
        }
    }

    // MARK: Check out

    /// "Check Out in a New Worktree…": the reviewed head where a plan can
    /// run — a local branch as itself; a commit, a remote branch or a tag
    /// detached; a pull request detached at its head by `gh pr checkout
    /// --detach` (no branch made). Asked first, saying exactly what is
    /// made; a worktree left half made is removed. Nothing is planned by
    /// it; its roots are prepared as New Task's are (2b: the workspace
    /// another worktree selects named, `init -backend=false` where allowed).
    func checkOutForTerraform(_ review: ReviewModel) {
        let model = review.terraform
        guard model.head == nil, !model.checkingOut else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let checkouts = await self.reviewCheckouts(review.root)
            let repo =
                (try? await Git.run(["worktree", "list", "--porcelain"], in: review.root)).map(Worktree.parse(porcelain:))?
                .first(where: \.isMain)?.path ?? review.root
            let name: String
            var add: [String]
            var pullRequest: Int?
            let made: String
            switch review.source {
            case .range(_, let head), .commits(_, let head), .paths(_, let head, _):
                guard !head.hasPrefix("-"), let commit = await Self.commit(of: head, in: repo) else { return NSSound.beep() }
                var local = false
                if !TerraformReview.isCommit(head) {
                    local = (try? await Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/" + head], in: repo)) != nil
                }
                if local {
                    name = head
                    add = ["worktree", "add", "--", head]
                    made = "on the branch \(head)"
                } else {
                    name = "review-" + (TerraformReview.isCommit(head) ? ReviewSource.short(head) : head)
                    add = ["worktree", "add", "--detach", "--", commit]
                    made = "detached at \(head == commit ? ReviewSource.short(commit) : "\(head) (\(ReviewSource.short(commit)))"), no branch made"
                }
            case .pullRequest(let number):
                name = "pr-\(number)"
                add = ["worktree", "add", "--detach", "--", "HEAD"]
                pullRequest = number
                made =
                    "detached at the pull request's head, fetched by gh pr checkout \(number) --detach — no branch is made or moved in your repository"
            case .branch, .uncommitted:
                return
            }
            let location = Settings.shared.worktreeLocation
            let path = TaskCreator.worktreePath(repo: repo, branch: name, location: location)
            guard !FileManager.default.fileExists(atPath: path.path), !checkouts.contains(where: { Self.samePath($0.url, path) }) else {
                return self.alert("\(path.lastPathComponent) already exists", "Open a tab there, or remove it, then Reload the review.")
            }
            // The path goes before the ref: `git worktree add [--detach] <path> <ref>`.
            add.insert(path.path, at: add.count - 1)
            let reviewing = TerraformReview.reviewing(review.source)
            let question = TerraformPlanGate.Question(
                title: "Check out \(reviewing) in a new worktree?",
                detail:
                    "A new worktree at \(path.path), \(made).\n\nNothing is planned: Plan asks first, listing what its code runs or reaches with your credentials. Its roots need Init before a plan, which asks too.",
                button: "Check Out", production: false)
            if let recorder = self.terraformPlanQuestionRecorder {
                guard recorder(question) else { return }
            } else {
                let confirmation = WriteConfirmation(title: question.title, scope: nil, detail: question.detail, button: question.button)
                guard await confirmation.ask(on: self.window) != nil else { return }
            }
            model.checkingOut = true
            defer { model.checkingOut = false }
            if location == .inside { await TaskCreator.excludeWorktreesFolder(in: repo) }
            do {
                _ = try await Git.run(add, in: repo, timeout: nil)
            } catch let error as GitError {
                return self.alert("Not checked out", error.stderr.split(separator: "\n").first.map(String.init) ?? "git couldn’t make the worktree.")
            } catch {
                return self.alert("Not checked out", error.localizedDescription)
            }
            if let pullRequest {
                do {
                    _ = try await GitHub.run(["pr", "checkout", "\(pullRequest)", "--detach"], in: path, timeout: 300)
                } catch {
                    // Not left behind at the main checkout's HEAD, where every later press would stop.
                    _ = try? await Git.run(["worktree", "remove", "--force", path.path], in: repo, timeout: 60)
                    return self.alert("Not checked out", "gh pr checkout \(pullRequest) --detach failed: \(error.localizedDescription)")
                }
            }
            await self.worktrees.refresh()
            // New Task's preparation, as any new worktree's (2b, 3.7): the
            // workspace another worktree selects named, init without a backend.
            await self.prepareTerraformWorktree(path)
            if self.store.reviewShowing == review.id { self.readTerraformReview(review) }
        }
    }
}
