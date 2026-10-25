import AppKit

/// Overgit's work: stage and commit, search the history, compare two sides.
extension E2ERunner {
    func overgitWorkScenario() async {
        let remote = scratch.appendingPathComponent("work-remote.git")
        let repo = scratch.appendingPathComponent("workrepo")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try? await git(["init", "-q", "--bare", remote.path], in: scratch)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        try? await git(["config", "user.email", "ada@example.com"], in: repo)
        try? await git(["config", "user.name", "Ada"], in: repo)
        func write(_ name: String, _ text: String) { try? text.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        write("app.swift", "let a = 1\n")
        try? await git(["add", "-A"], in: repo)
        try? await git(["commit", "-q", "-m", "Start the app"], in: repo)
        write("auth.swift", "func login() {}\n")
        try? await git(["add", "-A"], in: repo)
        try? await git(["commit", "-q", "-m", "Add the login screen"], in: repo)
        try? await git(["remote", "add", "origin", remote.path], in: repo)
        try? await git(["push", "-q", "-u", "origin", "main"], in: repo)
        try? await git(["checkout", "-q", "-b", "feature/pay"], in: repo)
        write("pay.swift", "func pay() { charge() }\n")
        try? await git(["add", "-A"], in: repo)
        try? await git(["-c", "user.name=Grace", "-c", "user.email=grace@example.com", "commit", "-q", "-m", "Pay with a card"], in: repo)
        try? await git(["checkout", "-q", "main"], in: repo)

        app.newTab(in: repo)
        await eventually { self.app.diff.branch == "main" }
        app.showOvergit(nil)
        let overgit = app.overgit
        check("Overgit reads the repository", await eventually(10) { overgit.commits.count == 2 })
        check("Changes is a section of its own, open", overgit.isExpanded(.changes))

        // Stage and commit from Overgit (DiffModel's, as the changes pane's).
        write("app.swift", "let a = 2\n")
        write("notes.txt", "todo\n")
        let diff = app.diff
        check("the changes are listed", await eventually(10) { diff.files.count == 2 }, "\(diff.files.map(\.path))")
        if let file = diff.files.first(where: { $0.path == "app.swift" }) { await diff.stage(file) }
        check("a file is staged", await eventually(5) { diff.files.first { $0.path == "app.swift" }?.isStaged == true })
        let committed = await diff.commit(message: "Change a")
        let subject = (try? await Git.run(["log", "-1", "--format=%s"], in: repo)) ?? ""
        check("Commit commits what is staged", committed && subject.contains("Change a"), subject)
        check("and leaves the rest", await eventually(5) { diff.files.map(\.path) == ["notes.txt"] }, "\(diff.files.map(\.path))")
        await diff.stageAll()
        _ = await diff.commit(message: "Change a, with notes", amend: true)
        let last = (try? await Git.run(["log", "-2", "--format=%s"], in: repo)) ?? ""
        check("Amend rewrites the last commit", last.hasPrefix("Change a, with notes\nAdd the login screen"), last)
        check("its message is what Amend starts from", await diff.lastCommitMessage() == "Change a, with notes")
        await diff.push()
        let pushed = (try? await Git.run(["log", "-1", "--format=%s", "main"], in: remote)) ?? ""
        check("Push sends it to the upstream", pushed.contains("Change a, with notes"), pushed)

        // Search: the commits read filter at once, git searches the rest.
        await overgit.refresh([.commits])
        overgit.commitQuery = "login"
        check("a word filters the commits at once", overgit.searchResults?.map(\.subject) == ["Add the login screen"])
        overgit.commitQuery = "card branch:feature/pay"
        check(
            "a filter git answers — another branch's history",
            await eventually(5) { overgit.searchResults?.map(\.subject) == ["Pay with a card"] }, "\(overgit.searchResults?.map(\.subject) ?? [])")
        overgit.commitQuery = "author:grace branch:feature/pay"
        check("by author", await eventually(5) { overgit.searchResults?.map(\.subject) == ["Pay with a card"] })
        overgit.commitQuery = "path:auth.swift"
        check("by file", await eventually(5) { overgit.searchResults?.map(\.subject) == ["Add the login screen"] })
        let sha = ((try? await Git.run(["rev-parse", "--short", "feature/pay"], in: repo)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        overgit.commitQuery = sha
        check("a hash finds its commit, on any branch", await eventually(5) { overgit.searchResults?.first?.subject == "Pay with a card" })
        overgit.commitQuery = ""
        check("an empty search gives the history back", overgit.searchResults == nil)

        // Compare: what the feature has that main doesn't.
        app.showCompare(base: "HEAD", head: "feature/pay")
        let compare = app.compare
        check("Compare takes the right-hand pane", app.rightPane.mode == .compare && app.diffItem?.isCollapsed == false)
        check("the current branch is named", compare.base == "main" && compare.head == "feature/pay")
        check("it loads", await eventually(10) { compare.phase == .loaded }, "\(compare.phase)")
        check("the feature's own commit", compare.ahead.map(\.subject) == ["Pay with a card"] && compare.aheadCount == 1)
        check("and main's since they parted", compare.behindCount == 1 && compare.behind.first?.subject == "Change a, with notes")
        check("the files it changed since they parted — not main's", compare.files.map(\.path) == ["pay.swift"], "\(compare.files.map(\.path))")
        check("with their diffs", await eventually(5) { compare.diffs["pay.swift"]?.lines.contains { $0.kind == .added } == true })
        compare.swap()
        check("swapped, the other side", await eventually(10) { compare.phase == .loaded && compare.files.map(\.path).sorted() == ["app.swift", "notes.txt"] }, "\(compare.files.map(\.path))")
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
            await pause(0.8)
            app.captureWindow(to: png)
        }
    }
}
