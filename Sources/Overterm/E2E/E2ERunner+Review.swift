import AppKit

/// Review tabs: the branch, a commit and a pull request (a stand-in gh),
/// each a page over the window, side by side or as one column, with the
/// page's own keys; ⌘W closes one, a terminal tab uncovers.
extension E2ERunner {
    func reviewScenario() async {
        let repo = scratch.appendingPathComponent("review-repo")
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.createDirectory(at: repo.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        let old = (1...40).map { "let line\($0) = \($0)" }.joined(separator: "\n") + "\n"
        try? old.write(to: repo.appendingPathComponent("Sources/app.swift"), atomically: true, encoding: .utf8)
        try? "keep\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try? await git(["add", "-A"], in: repo)
        try? await git(["commit", "-q", "-m", "init"], in: repo)
        try? await git(["checkout", "-q", "-b", "feat/review"], in: repo)
        var new = (1...40).map { "let line\($0) = \($0)" }
        new[4] = "let line5 = 500  // changed"
        new.remove(at: 20)
        new.insert("let added = true", at: 30)
        try? (new.joined(separator: "\n") + "\n").write(to: repo.appendingPathComponent("Sources/app.swift"), atomically: true, encoding: .utf8)
        try? await git(["commit", "-q", "-am", "change app"], in: repo)
        // Not committed: the branch's review has it too.
        try? "notes\n".write(to: repo.appendingPathComponent("NOTES.md"), atomically: true, encoding: .utf8)

        app.newTab(in: repo)
        let ready = await eventually(8) { self.app.diff.branch == "feat/review" && self.app.diff.comparison?.mergeBase != nil }
        check("the checkout's branch has something to review", ready, "\(String(describing: app.diff.comparison))")
        let terminalTab = app.store.selectedID

        // ⇧⌘R: the branch, in a tab of its own.
        app.reviewBranch(nil)
        guard let review = app.store.reviews.last else { return check("Review Branch opens a review tab", false) }
        check("Review Branch opens a review tab, showing", app.store.reviewShowing == review.id && app.reviewView?.isHidden == false)
        check("the terminal tab stays selected under it", app.store.selectedID == terminalTab)
        check("the page has the keyboard", app.window?.firstResponder === app.reviewView)
        check(
            "it lists the branch's files, with what isn't committed",
            await eventually(8) { review.phase == .loaded && review.files.map(\.path) == ["NOTES.md", "Sources/app.swift"] },
            "\(review.phase) \(review.files.map(\.path))")
        check("it opens on the first file, read", await eventually(5) { review.selected == "NOTES.md" && review.diffs["NOTES.md"] != nil })
        check("its title is the branch", review.title == "feat/review")

        // The page covers the window's body, inside the window.
        if let page = app.reviewView, let content = app.window?.contentView {
            let frame = page.convert(page.bounds, to: content)
            check("the page fills the window under the strip", frame.width >= content.bounds.width - 1 && frame.maxX <= content.bounds.width + 0.5, "\(frame)")
        }

        // The page's keys: j next file, n a change, v viewed.
        press("j")
        check("j: the next file", await eventually(3) { review.selected == "Sources/app.swift" && review.diffs["Sources/app.swift"] != nil })
        let rows = review.rows["Sources/app.swift"] ?? []
        check(
            "side by side: the changed line faces its old self",
            rows.contains { $0.left?.text == "let line5 = 5" && $0.right?.text == "let line5 = 500  // changed" }, "\(rows.count) rows")
        check("a removed line faces nothing", rows.contains { $0.left?.text == "let line21 = 21" && $0.right == nil })
        check("an added line has nothing on the left", rows.contains { $0.left == nil && $0.right?.text == "let added = true" })
        check("the file has three changes", review.changes.count == 3, "\(review.changes)")
        press("n")
        check("n: the first change", review.scrollTarget == review.changes.first)
        press("n")
        check("n again: the second", review.scrollTarget == review.changes.dropFirst().first)
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"] {
            await pause(0.8)
            app.captureWindow(to: png)
        }
        review.layout = .unified
        await pause(0.2)
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"] {
            app.captureWindow(to: png.replacingOccurrences(of: ".png", with: "-unified.png"))
        }
        review.layout = .split
        press("v")
        check("v: viewed, and on to the next not viewed", review.viewed == ["Sources/app.swift"] && review.selected == "NOTES.md")

        // Opening it again goes to the same tab.
        app.reviewBranch(nil)
        check("the same review again is the same tab", app.store.reviews.count == 1 && app.store.reviewShowing == review.id)

        // A terminal tab chosen uncovers it; the review stays in the strip.
        app.hideReviewPage()
        check("a terminal tab uncovers it", app.store.reviewShowing == nil && app.reviewView?.isHidden == true && app.store.reviews.count == 1)
        app.showReview(review)
        app.openSettings()
        check("Settings and a review don't show at once", app.store.settingsShowing && app.store.reviewShowing == nil)
        app.closeOverlay(.settings)
        app.showReview(review)

        // A commit.
        let head = ((try? await Git.run(["rev-parse", "HEAD"], in: repo)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        app.reviewCommits(from: head, to: head)
        let commit = app.store.reviews.last
        check(
            "a commit is a review of its own",
            await eventually(8) { commit !== review && commit?.phase == .loaded && commit?.files.map(\.path) == ["Sources/app.swift"] },
            "\(app.store.reviews.count)")
        check("titled by its short SHA", commit?.title == String(head.prefix(7)))

        // A pull request, from a stand-in gh.
        let gh = scratch.appendingPathComponent("gh-review")
        try? Self.reviewGh.write(to: gh, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        GitHub.executableOverride = gh
        defer { GitHub.executableOverride = nil }
        app.reviewPullRequest(9)
        let pr = app.store.reviews.last
        check(
            "a pull request's changes come from gh pr diff",
            await eventually(8) { pr?.phase == .loaded && pr?.files.map(\.path) == ["server.go", "lib/new.go"] },
            "\(String(describing: pr?.phase)) \(pr?.files.map(\.path) ?? [])")
        check("with its title", await eventually(5) { pr?.title == "#9 Speed up the server" }, pr?.title ?? "")
        check("a file's diff is its part of the patch", await eventually(5) { pr?.diffs["lib/new.go"]?.lines.contains { $0.text == "package lib" } == true })

        // ⌘W closes the one showing, and nothing else.
        let before = app.store.reviews.count
        app.closeSelectedTab(nil)
        check(
            "⌘W closes the review showing", app.store.reviews.count == before - 1 && app.store.reviewShowing == nil && app.store.tabs.count > 0,
            "\(app.store.reviews.count)")
        for open in app.store.reviews { app.closeReview(open) }
        check("closing them all leaves the terminal", app.store.reviews.isEmpty && app.reviewView?.isHidden == true)
    }

    /// One of the page's keys, handed to the page itself — no system event.
    private func press(_ key: String) {
        guard let view = app.reviewView,
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: app.window?.windowNumber ?? 0, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)
        else { return }
        view.keyDown(with: event)
    }

    private static let reviewGh = #"""
        #!/usr/bin/python3
        import json, sys
        args = sys.argv[1:]
        if args[:3] == ["pr", "diff", "9"]:
            sys.stdout.write("""diff --git a/server.go b/server.go
        index 1111111..2222222 100644
        --- a/server.go
        +++ b/server.go
        @@ -1,3 +1,3 @@
         package main
        -func slow() {}
        +func fast() {}
         // end
        diff --git a/lib/new.go b/lib/new.go
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/lib/new.go
        @@ -0,0 +1,2 @@
        +package lib
        +// new
        """)
        elif args[:3] == ["pr", "view", "9"]:
            print(json.dumps({"number": 9, "title": "Speed up the server", "headRefName": "fast", "baseRefName": "main", "state": "OPEN",
                "isDraft": False, "url": "https://github.com/o/r/pull/9", "statusCheckRollup": [], "body": "", "author": {"login": "me"},
                "additions": 3, "deletions": 1, "changedFiles": 2, "comments": [], "reviews": []}))
        else:
            sys.stderr.write("fake gh: unexpected %s\n" % args)
            sys.exit(2)
        """#
}
