import AppKit

/// Overgit's git commands, each against a real repository and a remote:
/// pull and push, a branch made, published, renamed, merged and deleted, a
/// merge stopped on a conflict and aborted, tags, a stash, a cherry-pick, a
/// revert and a reset. The sheets that ask are answered by the call.
extension E2ERunner {
    func overgitGitScenario() async {
        let remote = scratch.appendingPathComponent("ops-remote.git")
        let repo = scratch.appendingPathComponent("opsrepo")
        let other = scratch.appendingPathComponent("opsother")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try? await git(["init", "-q", "--bare", "-b", "main", remote.path], in: scratch)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        for dir in [repo] {
            try? await git(["config", "user.email", "ada@example.com"], in: dir)
            try? await git(["config", "user.name", "Ada"], in: dir)
        }
        func write(_ name: String, _ text: String, in dir: URL? = nil) {
            try? text.write(to: (dir ?? repo).appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: repo.appendingPathComponent(name).path) }
        func out(_ arguments: [String], in dir: URL? = nil) async -> String {
            ((try? await Git.run(arguments, in: dir ?? repo)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func commit(_ message: String, in dir: URL? = nil) async {
            try? await git(["add", "-A"], in: dir ?? repo)
            try? await git(["commit", "-q", "-m", message], in: dir ?? repo)
        }
        func head(_ ref: String = "HEAD") async -> Commit? {
            CommitLog.parse((try? await Git.run(CommitShow.headerArguments(ref), in: repo)) ?? "").first
        }
        /// A failure's alert is a sheet: put it away.
        func dismissSheet() {
            if let window = app.window, let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        write("app.swift", "let a = 1\n")
        await commit("Start")
        try? await git(["remote", "add", "origin", remote.path], in: repo)
        try? await git(["push", "-q", "-u", "origin", "main"], in: repo)
        try? await git(["clone", "-q", remote.path, other.path], in: scratch)
        try? await git(["config", "user.email", "grace@example.com"], in: other)
        try? await git(["config", "user.name", "Grace"], in: other)

        app.newTab(in: repo)
        await eventually { self.app.diff.branch == "main" }
        app.showOvergit(nil)
        let model = app.overgit
        check("the overview knows the upstream", await eventually(5) { model.tracking.upstream == "origin/main" }, "\(model.tracking)")

        // Someone else pushed: Fetch says behind, Pull brings it.
        write("theirs.swift", "let theirs = 1\n", in: other)
        await commit("Theirs", in: other)
        try? await git(["push", "-q"], in: other)
        await app.overgit(.fetch)
        check("fetch: one behind", model.tracking.behind == 1, "\(model.tracking)")
        check("pull brings it", await app.overgit(.pull(rebase: false)) && exists("theirs.swift") && model.tracking.behind == 0)

        // Ours, pushed.
        write("ours.swift", "let ours = 1\n")
        await commit("Ours")
        await model.refresh()
        check("a commit: one ahead", model.tracking.ahead == 1, "\(model.tracking)")
        let pushed = await app.overgit(.push)
        let remoteMain = await out(["rev-parse", "main"], in: remote)
        let localHead = await out(["rev-parse", "HEAD"])
        check("push sends it", pushed && model.tracking.ahead == 0 && remoteMain == localHead, "\(remoteMain) vs \(localHead)")

        // A branch: made, published, renamed.
        check("New Branch makes and checks it out", await app.overgit(.newBranch(from: nil), answer: "feature/x"))
        check("it is the checkout's branch", await eventually(3) { self.app.diff.branch == "feature/x" }, app.diff.branch ?? "none")
        check("Publish pushes it, tracking", await app.overgit(.push) && model.tracking.upstream == "origin/feature/x", "\(model.tracking)")
        write("feature.swift", "let feature = 1\n")
        await commit("Feature")
        await model.refresh()
        guard let featureRef = model.branches.first(where: { $0.name == "feature/x" && !$0.isRemote }) else {
            return check("the branch is listed", false, model.branches.map(\.name).joined(separator: ","))
        }
        let renamed = await app.overgit(.renameBranch(featureRef), answer: "feature/y")
        let nowOn = await out(["branch", "--show-current"])
        check("Rename", renamed && nowOn == "feature/y", nowOn)

        // Merged into main.
        try? await git(["checkout", "-q", "main"], in: repo)
        await app.diff.refresh()
        check("Merge brings the branch in", await app.overgit(.merge("feature/y")) && exists("feature.swift"))

        // A merge that stops on a conflict, and the way out.
        try? await git(["checkout", "-q", "-b", "clash"], in: repo)
        write("app.swift", "let a = 2\n")
        await commit("Clash")
        try? await git(["checkout", "-q", "main"], in: repo)
        write("app.swift", "let a = 3\n")
        await commit("Main's own")
        await app.diff.refresh()
        let merged = await app.overgit(.merge("clash"))
        dismissSheet()
        check("a conflicting merge stops", !merged && model.inProgress == .merge, "\(String(describing: model.inProgress))")
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
            await pause(0.6)
            app.captureWindow(to: png)
        }
        check("Abort undoes it", await app.overgit(.abortOperation, confirmed: true) && model.inProgress == nil)
        check("and the file is main's again", (try? String(contentsOf: repo.appendingPathComponent("app.swift"), encoding: .utf8)) == "let a = 3\n")

        // A branch never merged: deleted only when asked twice.
        await model.refresh()
        guard let clash = model.branches.first(where: { $0.name == "clash" && !$0.isRemote }) else {
            return check("clash is listed", false)
        }
        check("an unmerged branch is deleted when confirmed", await app.overgit(.deleteBranch(clash), confirmed: true))
        check("it is gone", (await out(["branch", "--list", "clash"])).isEmpty)

        // Tags.
        let sha = await out(["rev-parse", "HEAD"])
        let tagged = await app.overgit(.tag(at: sha), answer: "v1")
        let tagSHA = await out(["rev-parse", "v1^{commit}"])
        check("a tag", tagged && tagSHA == sha, tagSHA)
        await model.refresh()
        do {
            let tag = model.tags.first { $0.name == "v1" } ?? TagRef(name: "v1", sha: sha, date: Date(), subject: "")
            let tagPushed = await app.overgit(.pushTag(tag))
            let onRemote = await out(["tag", "--list", "v1"], in: remote)
            check("pushed", tagPushed && onRemote == "v1", onRemote)
            let tagDeleted = await app.overgit(.deleteTag(tag), confirmed: true)
            let left = await out(["tag", "--list", "v1"])
            check("deleted here", tagDeleted && left.isEmpty, left)
        }

        // A stash, and back.
        write("ours.swift", "let ours = 2\n")
        write("new.txt", "untracked\n")
        await app.diff.refresh()
        check("Stash puts changes aside, untracked too", await app.overgit(.stash, answer: "wip") && !exists("new.txt"))
        await model.refresh()
        let stashes = Stashes.parse(await out(Stashes.arguments))
        check("as one stash, named", stashes.count == 1 && stashes.first?.subject.contains("wip") == true, "\(stashes.map(\.subject))")
        if let stash = stashes.first {
            check("Pop brings them back", await app.overgit(.popStash(stash)) && exists("new.txt"))
        }
        try? await git(["checkout", "-q", "--", "."], in: repo)
        try? FileManager.default.removeItem(at: repo.appendingPathComponent("new.txt"))

        // Cherry-pick, revert, reset.
        try? await git(["checkout", "-q", "-b", "pick"], in: repo)
        write("picked.swift", "let picked = 1\n")
        await commit("To pick")
        guard let picked = await head() else { return check("the commit to pick", false) }
        try? await git(["checkout", "-q", "main"], in: repo)
        await app.diff.refresh()
        check("Cherry-pick brings one commit", await app.overgit(.cherryPick(picked)) && exists("picked.swift"))
        guard let onMain = await head() else { return check("the picked commit", false) }
        check("Revert undoes it, as a commit", await app.overgit(.revert(onMain)) && !exists("picked.swift"))
        let before = await out(["rev-list", "--count", "HEAD"])
        guard let target = await head("HEAD~1") else { return check("one back", false) }
        let reset = await app.overgit(.reset(target, .soft))
        let after = await out(["rev-list", "--count", "HEAD"])
        check("Soft reset moves the branch back", reset && Int(after) == (Int(before) ?? 0) - 1, "\(before) → \(after)")
        // The revert undone: its removal of the picked file is staged still.
        let staged = await out(["diff", "--cached", "--name-only"])
        check("keeping what it undid staged", staged == "picked.swift", staged)
        check("nothing left running", model.running == nil)
    }
}
