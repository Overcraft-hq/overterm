#if E2E
import AppKit

/// GIT-U6: a push the remote refused is said plainly with its next steps
/// — Pull with Rebase then Push, Force Push with Lease… — and the force
/// push is asked, naming the branch, and never offered on the default branch.
extension E2ERunner {
    package func gitFailuresScenario() async {
        let remote = scratch.appendingPathComponent("failures-remote.git")
        let repo = scratch.appendingPathComponent("failures")
        let other = scratch.appendingPathComponent("failures-other")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try? await git(["init", "-q", "--bare", remote.path], in: scratch)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        for (key, value) in [("user.email", "ada@example.com"), ("user.name", "Ada")] { try? await git(["config", key, value], in: repo) }
        func write(_ folder: URL, _ name: String, _ text: String) { try? text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        write(repo, "app.swift", "let a = 1\n")
        try? await git(["add", "-A"], in: repo)
        try? await git(["commit", "-q", "-m", "Start"], in: repo)
        try? await git(["remote", "add", "origin", remote.path], in: repo)
        try? await git(["push", "-q", "-u", "origin", "main"], in: repo)
        try? await git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], in: repo)
        try? await git(["checkout", "-q", "-b", "feature"], in: repo)
        write(repo, "pay.swift", "func pay() {}\n")
        try? await git(["add", "-A"], in: repo)
        try? await git(["commit", "-q", "-m", "Pay"], in: repo)
        try? await git(["push", "-q", "-u", "origin", "feature"], in: repo)

        /// Someone else pushes to `branch`; this checkout then commits on its own.
        func remoteMovesOn(_ branch: String, _ note: String) async {
            try? FileManager.default.removeItem(at: other)
            try? await git(["clone", "-q", "-b", branch, remote.path, other.path], in: scratch)
            for (key, value) in [("user.email", "grace@example.com"), ("user.name", "Grace")] { try? await git(["config", key, value], in: other) }
            write(other, "theirs-\(note).txt", note)
            try? await git(["add", "-A"], in: other)
            try? await git(["commit", "-q", "-m", "Theirs \(note)"], in: other)
            try? await git(["push", "-q", "origin", branch], in: other)
            write(repo, "mine-\(note).txt", note)
            try? await git(["add", "-A"], in: repo)
            try? await git(["commit", "-q", "-m", "Mine \(note)"], in: repo)
        }
        func sheetButtons() -> [String] {
            guard let root = window.attachedSheet?.contentView else { return [] }
            var titles: [String] = []
            func walk(_ view: NSView) {
                if let button = view as? NSButton, !button.title.isEmpty, button.bezelStyle == .push || button.isBordered { titles.append(button.title) }
                view.subviews.forEach(walk)
            }
            walk(root)
            return titles
        }
        func press(_ index: Int) {
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)) }
        }
        func remoteLog(_ branch: String) async -> String { (try? await Git.run(["log", "--format=%s", branch], in: remote)) ?? "" }

        app.newTab(in: repo)
        check("on feature", await eventually(10) { self.app.diff.branch == "feature" })
        app.showOvergit(nil)
        check("Overgit reads it", await eventually(10) { self.app.overgit.root != nil })

        // Refused: the remote has a commit this checkout doesn't.
        await remoteMovesOn("feature", "one")
        await app.overgit.refresh()
        let push = Task { await self.app.overgit(.push) }
        check("a refused push is said in the window", await eventually(15) { self.window.attachedSheet != nil })
        let said = sheetTexts().joined(separator: "\n")
        check("in plain words", said.contains("feature on the remote has commits that aren't here"), said)
        check("git's own words under it", said.contains("git said:") && said.contains("rejected"), said)
        let buttons = sheetButtons()
        check(
            "with the next steps", ["Pull then Push", "Pull with Rebase then Push", "Force Push with Lease…"].allSatisfy(buttons.contains),
            "\(buttons)")
        press(1)
        _ = await push.value
        let both = await eventuallyAsync(20) {
            let log = await remoteLog("feature")
            return log.contains("Theirs one") && log.contains("Mine one")
        }
        let featureLog = await remoteLog("feature")
        check("Pull with Rebase then Push lands both", both, featureLog)

        // Force push with lease: asked, naming the branch and the remote —
        // and refused by the lease while the remote's commit is unseen here.
        await remoteMovesOn("feature", "two")
        await app.overgit.refresh()
        let again = Task { await self.app.overgit(.push) }
        check("refused again", await eventually(15) { self.window.attachedSheet != nil })
        press(2)
        check(
            "the force push is asked first",
            await eventually(10) { self.window.attachedSheet != nil && self.sheetTexts().joined().contains("Force push feature to origin/feature?") },
            sheetTexts().joined(separator: " | "))
        check("with what it runs", sheetTexts().joined().contains("--force-with-lease=feature:refs/remotes/origin/feature"), sheetTexts().joined(separator: " | "))
        press(0)
        check(
            "the lease refuses it: their commit was never fetched here",
            await eventually(15) { self.sheetTexts().joined().contains("since this checkout last fetched it: nothing was replaced") },
            sheetTexts().joined(separator: " | "))
        press(0)
        _ = await again.value
        let kept = await remoteLog("feature")
        check("theirs kept", kept.contains("Theirs two"), kept)

        // Fetched, theirs seen: the force push replaces it.
        try? await git(["fetch", "-q", "origin"], in: repo)
        await app.overgit.refresh()
        let forced = Task { await self.app.overgit(.push) }
        check("refused once more", await eventually(15) { self.window.attachedSheet != nil })
        press(2)
        check("asked", await eventually(10) { self.sheetTexts().joined().contains("Force push feature to origin/feature?") })
        press(0)
        _ = await forced.value
        let replaced = await eventuallyAsync(20) {
            let log = await remoteLog("feature")
            return log.contains("Mine two") && !log.contains("Theirs two")
        }
        let forcedLog = await remoteLog("feature")
        check("confirmed and fetched, the remote's commit is replaced by ours", replaced, forcedLog)

        // On the default branch: never a force push.
        try? await git(["checkout", "-q", "main"], in: repo)
        check("on main", await eventually(10) { self.app.diff.branch == "main" })
        await remoteMovesOn("main", "three")
        await app.overgit.refresh()
        let onMain = Task { await self.app.overgit(.push) }
        check("main's refusal said", await eventually(15) { self.window.attachedSheet != nil })
        check("without a force push", !sheetButtons().contains("Force Push with Lease…") && sheetButtons().contains("Pull then Push"), "\(sheetButtons())")
        // Cancel is added last, after the two steps: the buttons' order in the view tree isn't the sheet's.
        press(2)
        _ = await onMain.value
        let mainLog = await remoteLog("main")
        check("cancelled, nothing pushed", !mainLog.contains("Mine three"), mainLog)
    }
}
#endif
