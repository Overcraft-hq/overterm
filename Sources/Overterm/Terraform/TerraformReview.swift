import Foundation

/// A review tab's Terraform section (stage 2f, analysis 2.9, 5.5): which
/// roots what is under review touches — a file in the root, or in a module
/// it calls —, which checkout has its head (where a plan of it can run),
/// and the text "Post to Pull Request…" shows before it posts. Pure.
enum TerraformReview {
    /// One root the review touches.
    struct Root: Equatable, Sendable, Identifiable {
        var path: String
        var name: String
        var rootClass: TerraformClass
        /// "envs/dev/main.tf", "2 files", or "through modules/acme-net".
        var why: String
        /// Its folder is in the checkout read (a root the review adds is not
        /// until it is checked out).
        var present: Bool
        var id: String { path }
        var isProduction: Bool { rootClass == .production }
    }

    /// The roots `changed` touches (paths relative to the top; a rename's
    /// old path too), each with why — from the cards and modules of the
    /// checkout read. Production first, then by path.
    static func touched(cards: [TerraformRootCard], modules: [TerraformModuleRow], changed: [String], present: Set<String>? = nil) -> [Root] {
        let callers = Dictionary(modules.map { ($0.path, $0.callers) }, uniquingKeysWith: { first, _ in first })
        let rootPaths = Set(cards.map(\.path))
        var direct: [String: [String]] = [:]
        var through: [String: Set<String>] = [:]
        for file in changed {
            let folder = (file as NSString).deletingLastPathComponent
            if let root = TerraformRootGuess.nearestRoot(of: folder, roots: rootPaths) { direct[root, default: []].append(file) }
            for (module, roots) in callers where folder == module || folder.hasPrefix(module + "/") {
                for root in roots { through[root, default: []].insert(module) }
            }
        }
        var rows: [Root] = []
        for card in cards where direct[card.path] != nil || through[card.path] != nil {
            var reasons: [String] = []
            if let files = direct[card.path] {
                reasons.append(files.count == 1 ? files[0] : "\(files.count) files")
            }
            if let modules = through[card.path] {
                reasons.append("through " + modules.sorted().prefix(3).joined(separator: ", ") + (modules.count > 3 ? " +\(modules.count - 3)" : ""))
            }
            rows.append(
                Root(
                    path: card.path, name: card.name, rootClass: card.rootClass, why: reasons.joined(separator: " · "),
                    present: present?.contains(card.path) ?? true))
        }
        return rows.sorted { ($0.isProduction ? 0 : 1, $0.path) < ($1.isProduction ? 0 : 1, $1.path) }
    }

    /// The changed paths a review lists, renames' old paths included.
    static func changedPaths(_ files: [ChangedFile]) -> [String] {
        var paths: [String] = []
        for file in files {
            paths.append(file.path)
            if let original = file.originalPath { paths.append(original) }
        }
        return paths
    }

    /// The listing of the checkout read, with the reviewed Terraform files
    /// that aren't in it added — a root or module the review adds is then
    /// one too, read with no facts (its files aren't here).
    static func listing(_ folders: [String: [String]], adding changed: [String]) -> [String: [String]] {
        var folders = folders
        for path in changed where TerraformRootGuess.isTerraformName((path as NSString).lastPathComponent) && !TerraformRootGuess.isSkipped(path) {
            let folder = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            if !(folders[folder] ?? []).contains(name) { folders[folder, default: []].append(name) }
        }
        return folders
    }

    // MARK: Where its head is

    /// A checkout of the repository: its folder, its branch and HEAD.
    struct Checkout: Equatable, Sendable {
        var url: URL
        var branch: String?
        var head: String?
        var name: String { branch ?? head.map { "(\($0.prefix(7)))" } ?? url.lastPathComponent }
    }

    /// The checkout a plan of the review runs in, and whether it is at
    /// the reviewed head.
    struct Head: Equatable, Sendable {
        var checkout: Checkout
        /// Why it isn't what is reviewed: a pull request's branch here
        /// behind (or ahead of) the pull request's head. Plan and Post
        /// wait for it: a plan of other code isn't the review's.
        var note: String?
        var isReviewed: Bool { note == nil }
    }

    /// What the review's head is, as git and gh name it.
    struct Wanted: Equatable, Sendable {
        /// A local branch's name — never a fork's: its name says nothing here.
        var branch: String?
        /// A commit (full or abbreviated): a range's head resolved, a pull
        /// request's `headRefOid`.
        var commit: String?
    }

    /// The head the source reviews: the checkout itself for `branch` and
    /// `uncommitted` (nil here: `head(…)` takes the review's own); a
    /// range's head — a branch with its commit (`resolved`), else a
    /// commit —; the last commit; a pull request's head commit, once `gh
    /// pr view` said it, and its branch only when the pull request is from
    /// this repository (a fork's `main` is not the person's `main`).
    static func wanted(
        _ source: ReviewSource, pullRequestBranch: String? = nil, pullRequestHead: String? = nil, crossRepository: Bool = false,
        resolved: String? = nil
    ) -> Wanted? {
        switch source {
        case .branch, .uncommitted: return nil
        case .range(_, let head): return isCommit(head) ? Wanted(commit: head) : Wanted(branch: head, commit: resolved)
        case .commits(_, let to): return Wanted(commit: to)
        case .paths(_, let head, _): return Wanted(commit: head)
        case .pullRequest:
            guard let pullRequestHead, isCommit(pullRequestHead) else { return nil }
            return Wanted(branch: crossRepository ? nil : pullRequestBranch, commit: pullRequestHead)
        }
    }

    static func isCommit(_ ref: String) -> Bool { ref.count >= 7 && ref.count <= 64 && ref.allSatisfy(\.isHexDigit) }

    static func sameCommit(_ a: String?, _ b: String?) -> Bool {
        guard let a = a?.lowercased(), let b = b?.lowercased(), min(a.count, b.count) >= 7 else { return false }
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    /// Which checkout has the head: for the branch and what isn't committed,
    /// the review's own; else one at the wanted commit (on the wanted
    /// branch first); else one on the wanted branch elsewhere, said and not
    /// planned ("pull it first"). Nil when none has it: "Check Out in a New
    /// Worktree…". A branch alone matches only when no commit is known.
    static func head(of source: ReviewSource, review: Checkout, wanted: Wanted?, checkouts: [Checkout]) -> Head? {
        switch source {
        case .branch, .uncommitted: return Head(checkout: review)
        default: break
        }
        guard let wanted else { return nil }
        let all = [review] + checkouts.filter { $0.url.standardizedFileURL != review.url.standardizedFileURL }
        if let commit = wanted.commit {
            let atCommit = all.filter { sameCommit($0.head, commit) }
            if let found = atCommit.first(where: { wanted.branch != nil && $0.branch == wanted.branch }) ?? atCommit.first {
                return Head(checkout: found)
            }
        }
        if let branch = wanted.branch, let found = all.first(where: { $0.branch == branch }) {
            if let commit = wanted.commit {
                let here = found.head.map { String($0.prefix(7)) } ?? "another commit"
                return Head(
                    checkout: found,
                    note: "\(branch) here is at \(here), not the reviewed \(commit.prefix(7)): pull it, then Reload — Plan and Post wait for it")
            }
            return Head(checkout: found)
        }
        return nil
    }

    /// What is under review, for the plan's question (5.5: planning code
    /// the person didn't write always asks).
    static func reviewing(_ source: ReviewSource, pullRequest: Int? = nil) -> String {
        if let pullRequest { return "pull request #\(pullRequest)" }
        switch source {
        case .branch(_, _, let branch): return "the branch \(branch)"
        case .uncommitted: return "uncommitted changes"
        case .range(_, let head): return "\(ReviewSource.short(head))"
        case .commits(let from, let to): return from == to ? "commit \(ReviewSource.short(to))" : "commits \(ReviewSource.short(from))…\(ReviewSource.short(to))"
        case .pullRequest(let number): return "pull request #\(number)"
        case .paths(_, let head, _): return "commit \(ReviewSource.short(head))"
        }
    }

    // MARK: Posting

    /// One root's plan as the comment says it.
    struct PostedPlan: Equatable, Sendable {
        /// `TerraformPlanText.copySummary`'s text: the masked model only.
        var summary: String
        /// "feature-x @ 3f2a91c", where it was planned.
        var planned: String?
        var age: String
        /// Why it may no longer be what applying would do.
        var stale: String?
    }

    /// A root's latest plan in the head's checkout, as Post weighs it.
    struct Candidate: Equatable, Sendable {
        var root: String
        var summary: String
        /// The checkout's HEAD when it was planned.
        var commit: String?
        /// Tracked files of the checkout differed from that commit.
        var uncommitted = false
        var mode: TerraformPlanMode = .normal
        var age: String
        var stale: String?
        /// False once it was applied: its changes are made, nothing is left to post.
        var held = true
    }

    /// The plans a pull request's comment may carry (5.5): only a whole
    /// plan (no destroy, target or replace) made at the pull request's
    /// head with nothing uncommitted — anything else is another code's
    /// plan, and is left out with why. Each names the commit it planned.
    static func postable(_ candidates: [Candidate], head: String, branch: String?) -> (plans: [PostedPlan], skipped: [String]) {
        var plans: [PostedPlan] = []
        var skipped: [String] = []
        for candidate in candidates {
            guard candidate.held else {
                skipped.append("\(candidate.root): its plan has been applied since — plan it again for what is left to change")
                continue
            }
            guard let commit = candidate.commit else {
                skipped.append("\(candidate.root): which commit it planned isn't known — plan it again from the review")
                continue
            }
            guard sameCommit(commit, head) else {
                skipped.append("\(candidate.root): planned at \(commit.prefix(7)), not the pull request's head \(head.prefix(7)) — plan it again")
                continue
            }
            guard !candidate.uncommitted else {
                skipped.append("\(candidate.root): planned with uncommitted changes in its checkout")
                continue
            }
            if let label = candidate.mode.label {
                skipped.append("\(candidate.root): a \(label) plan, not the whole root's")
                continue
            }
            plans.append(
                PostedPlan(
                    summary: candidate.summary, planned: (branch.map { $0 + " @ " } ?? "") + String(commit.prefix(7)), age: candidate.age,
                    stale: candidate.stale))
        }
        return (plans, skipped)
    }

    /// GitHub's limit for a comment is 65,536 characters; a margin kept.
    static let maxComment = 60_000

    /// The pull request's comment (2.2, 5.6 rule 8): every plan's masked
    /// summary, each in a fence longer than any run of backticks in it (an
    /// address can't close it, nor a mention inside notify anyone), cut to
    /// GitHub's size with what was left out said — the first plan cut to
    /// fit rather than left out. Never `terraform show`.
    static func comment(_ plans: [PostedPlan]) -> String {
        var parts = ["**Terraform plans** (from Overterm; values Terraform marks sensitive, and what looks like a secret, masked)"]
        var used = parts[0].count
        var left = 0
        let room = maxComment - 200
        for (index, plan) in plans.enumerated() {
            var header = "Planned " + plan.age + (plan.planned.map { " at \(TerraformPlanText.escaped($0))" } ?? "")
            if let stale = plan.stale { header += " · stale: \(stale)" }
            let fence = String(repeating: "`", count: max(3, longestBacktickRun(plan.summary) + 1))
            func block(_ summary: String) -> String { "\n\n" + inline(header) + "\n\n" + fence + "text\n" + summary + "\n" + fence }
            var text = block(plan.summary)
            if used + text.count > room {
                guard index == 0 else {
                    left = plans.count - index
                    break
                }
                // The first alone is too long: its head, cut at a line, said.
                let lines = plan.summary.split(separator: "\n", omittingEmptySubsequences: false)
                var kept: [Substring] = []
                var size = used + block("").count + 120
                for line in lines {
                    guard size + line.count + 1 <= room else { break }
                    kept.append(line)
                    size += line.count + 1
                }
                let dropped = lines.count - kept.count
                text = block(kept.joined(separator: "\n") + "\n… cut: \(dropped) more line\(dropped == 1 ? "" : "s") of this plan than a comment holds")
            }
            parts.append(text)
            used += text.count
        }
        if left > 0 { parts.append("\n\n… \(left) more plan\(left == 1 ? "" : "s") not posted: the comment is at GitHub's size.") }
        return parts.joined()
    }

    /// A line outside a fence, with nothing GitHub would act on: no
    /// mention, no reference, no markup.
    static func inline(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "@": out += "@\u{200B}"
            case "#": out += "#\u{200B}"
            case "`", "*", "_", "[", "]", "<", ">", "|", "~", "\\": out += "\\" + String(character)
            default: out.append(character)
            }
        }
        return out
    }

    static func longestBacktickRun(_ text: String) -> Int {
        var longest = 0
        var run = 0
        for character in text {
            if character == "`" {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        return longest
    }
}

/// What a review tab's Plan hands the plan (2f): what is reviewed, for the
/// question that always asks (5.5); the base its risks and changed lines
/// are read against; the risks in the modules the root calls, which a
/// review of a module's change is about; the head, as the plan's header
/// says where it was planned.
struct TerraformReviewPlan: Equatable, Sendable {
    var reviewing: String
    var base: String?
    var moduleRisks: [TerraformRunRisk] = []
    /// Modules the root calls whose code wasn't read (past the cap, or not
    /// in the checkout): the question can't say they run nothing.
    var unreadModules = 0
    var branch: String?
}

extension TerraformReview {
    /// The risks in the modules a root calls (local ones, through other
    /// modules too), each said with its module: "data.external in
    /// modules/acme-net". The lock file's providers are the root's alone.
    static func moduleRisks(_ modules: [(path: String, config: TerraformConfigFacts)]) -> [TerraformRunRisk] {
        var found: [TerraformRunRisk] = []
        for module in modules.sorted(by: { $0.path < $1.path }) {
            for risk in TerraformRunRisks.risks(config: module.config, lockProviders: nil) {
                found.append(TerraformRunRisk(kind: risk.kind, detail: "\(risk.detail) in \(module.path)"))
            }
        }
        return found
    }
}
