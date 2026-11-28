#if E2E
import AppKit
import Foundation

/// Onboarding's stage 0, run in the `task` scenario (steps 3 and 5 of the
/// `onboarding` scenario to come): New Task outside a repository offers
/// Open Folder…, and an agent's CLI that a new tab's shell wouldn't find is
/// said before its command is typed. No synthetic input: the window's own
/// methods, the facts injected, the sheets' buttons pressed.
extension E2ERunner {
    func onboardingTaskChecks() async {
        await newTaskOutsideARepositoryChecks()
        await missingAgentChecks()
    }

    private func sheetHasButton(_ title: String) -> Bool {
        Self.find(NSButton.self, in: window.attachedSheet?.contentView, where: { $0.title == title }) != nil
    }

    private func endSheet() async {
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        _ = await eventually(2) { self.window.attachedSheet == nil }
    }

    /// Step 3: the alert keeps its words and gains the next step.
    private func newTaskOutsideARepositoryChecks() async {
        let outside = scratch.appendingPathComponent("not-a-repository", isDirectory: true)
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        app.newTab(in: outside)
        await pause(0.5)
        await app.worktrees.refresh()
        guard app.worktrees.main == nil else { return check("the first tab is outside a repository", false, "\(app.worktrees.worktrees)") }
        app.newTask(nil)
        check("New Task outside a repository says so", await eventually(3) { self.window.attachedSheet != nil })
        let texts = sheetTexts()
        check(
            "in the words it always had",
            texts.contains("Not in a git repository") && texts.contains { $0.contains("Open a tab inside a repository first; the task’s worktree is created from it.") },
            "\(texts)")
        check("and offers Open Folder… beside OK", sheetHasButton("Open Folder…") && sheetHasButton("OK"))
        await endSheet()
        check("nothing else opened", window.attachedSheet == nil)
    }

    /// Step 5: no agent found — nothing typed, the warning, Open the Tab
    /// Anyway; not known yet — as before.
    private func missingAgentChecks() async {
        var opened: [Agent] = []
        app.agentTabRecorder = { agent, _ in opened.append(agent) }
        defer {
            app.findAgent = { AgentFinder.find($0) }
            app.agentTabRecorder = nil
        }
        let tabs = app.store.tabs.count

        app.findAgent = { _ in .missing }
        app.newAgentTab(.claude)
        check("an agent not on the PATH is said first", await eventually(3) { self.window.attachedSheet != nil })
        let texts = sheetTexts()
        check(
            "as Claude Code isn't on your PATH",
            texts.contains("Claude Code isn’t on your PATH.") && texts.contains("Overterm looked where a new tab’s shell looks."), "\(texts)")
        check("with Open the Tab Anyway and Cancel", sheetHasButton("Open the Tab Anyway") && sheetHasButton("Cancel"))
        check("and nothing typed: no tab yet", app.store.tabs.count == tabs && opened.isEmpty)
        clickSheetButton("Cancel")
        _ = await eventually(2) { self.window.attachedSheet == nil }
        check("Cancel opens nothing", app.store.tabs.count == tabs && opened.isEmpty)

        app.newAgentTab(.claude)
        _ = await eventually(3) { self.window.attachedSheet != nil }
        clickSheetButton("Open the Tab Anyway")
        check("Open the Tab Anyway opens it all the same", await eventually(3) { opened == [.claude] }, "\(opened)")
        _ = await eventually(2) { self.window.attachedSheet == nil }

        // Found only in one of Claude Code's installers' places: still said.
        app.findAgent = { _ in .found(URL(fileURLWithPath: NSHomeDirectory() + "/.claude/local/claude"), onPath: false) }
        app.newAgentTab(.claude)
        check("found off the PATH is said too", await eventually(3) { self.window.attachedSheet != nil })
        let offPath = sheetTexts().joined(separator: " ")
        check("with where it was found", offPath.contains("Found at ~/.claude/local/claude, not on your PATH"), offPath)
        clickSheetButton("Cancel")
        _ = await eventually(2) { self.window.attachedSheet == nil }

        // The shell hasn't answered: nothing changes.
        app.findAgent = { _ in .unknown }
        app.newAgentTab(.claude)
        check("not known yet, the tab opens as before", await eventually(3) { opened == [.claude, .claude] } && window.attachedSheet == nil, "\(opened)")
    }
}
#endif
