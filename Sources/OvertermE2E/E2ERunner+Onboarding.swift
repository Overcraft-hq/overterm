#if E2E
import AppKit
import Foundation

/// Onboarding's stage 0, run in the `task` scenario (steps 3 and 5 of the
/// `onboarding` scenario to come): New Task outside a repository offers
/// Open Folder…, and an agent's CLI that a new tab's shell wouldn't find is
/// said before its command is typed. Stage 1's checks run in the
/// `sidebarPanels` and `palette` scenarios. No synthetic input: the window's
/// own methods, the facts injected, the sheets' buttons pressed.
extension E2ERunner {
    func onboardingTaskChecks() async {
        await newTaskOutsideARepositoryChecks()
        await missingAgentChecks()
    }

    /// Stage 1, in the `sidebarPanels` scenario (7.5): the rail's tooltips
    /// say the key bound now and follow a rebinding; outside a repository
    /// Overgit, Kubernetes and Terraform offer Open Folder…, and Sessions
    /// says how to start one. Read from the accessibility tree; nothing pressed.
    func onboardingSidebarChecks() async {
        guard let root = window.contentView else { return check("the window's content", false) }
        let keys = Keybindings.shared
        func help(_ id: String) -> [String] { Self.accessibilityHelps("sidebar.rail.\(id)", in: root) }
        func present(_ id: String) -> Bool { Self.accessibilityPress(id, in: root, press: false) }

        let overgit = KeyHints.help("Overgit", command: "overgit.show")
        check("the rail's Overgit tooltip says its key", await eventually(3) { help("git").contains(overgit) }, "\(help("git")) vs \(overgit)")
        check("Files, unbound, says its name alone", help("files").contains("Files"), "\(help("files"))")
        check(
            "the gear says Settings' key", help("settings").contains(KeyHints.help("Settings", command: "app.settings")), "\(help("settings"))")
        if let command = KeyCommands.byID["overgit.show"] {
            keys.set(command, to: KeyCombo("ctrl+alt+cmd+g"))
            check("rebound, the tooltip follows", await eventually(3) { help("git").contains("Overgit (⌃⌥⌘G)") }, "\(help("git"))")
            keys.reset(command)
            check("and back", await eventually(3) { help("git").contains(overgit) }, "\(help("git"))")
        }

        // Outside a repository: a tab in a folder git doesn't know.
        let outside = scratch.appendingPathComponent("onboarding-outside", isDirectory: true)
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        app.newTab(in: outside)
        guard let tab = app.store.selected else { return check("a tab outside a repository", false) }
        defer { app.closeTabsWithoutAsking([tab]) }

        app.sidebarPanel.panel = .git
        check(
            "Overgit outside a repository offers Open Folder…",
            await eventually(5) { !self.app.overgit.isRepository && present("overgit.openFolder") },
            "repository: \(app.overgit.isRepository), root: \(app.overgit.root?.path ?? "nil")")

        if SidebarPanel.shown.contains(.sessions) {
            app.sidebarPanel.panel = .sessions
            check("Sessions with none says how to start one", await eventually(5) { present("sessions.emptyHint") })
        }
        if SidebarPanel.shown.contains(.kubernetes) {
            app.sidebarPanel.panel = .kubernetes
            check(
                "Kubernetes outside a repository offers Open Folder…", await eventually(5) { present("kubernetes.openFolder") },
                app.kubernetesPanel.checkout?.path ?? "no checkout")
        }
        if SidebarPanel.shown.contains(.terraform) {
            app.sidebarPanel.panel = .terraform
            check(
                "Terraform outside a repository offers Open Folder…", await eventually(5) { present("terraform.openFolder") },
                "\(app.terraformPanel.state) \(app.terraformPanel.checkout?.path ?? "no checkout")")
        }
        app.sidebarPanel.panel = .files
        check("Files in a folder that isn't home has no home strip", !present("files.homeStrip"))
    }

    /// Stage 1, in the `palette` scenario (9.1, 7.8): a hand-written row's
    /// key is its command's as bound now, a rebinding changes it, none is
    /// written into the rows' words; Help's Keyboard Shortcuts is a row.
    func onboardingPaletteChecks() async {
        let keys = Keybindings.shared
        guard let peek = KeyCommands.byID["tabs.peek"] else { return check("Tab Peek's command", false) }
        func row(_ id: String) -> PaletteItem? { app.palette.results.first { $0.id == id } }

        app.palette.query = ""
        let now = keys.key(for: peek)?.display ?? "?"
        check("Tab Peek's row says its command's key", row("a.peek")?.subtitle == "Every tab's terminal, live  \(now)", row("a.peek")?.subtitle ?? "nil")
        // Shown again: the rows are made as the palette opens.
        func reopen() {
            app.hidePalette()
            app.showPalette(nil)
            app.palette.query = ""
        }
        keys.set(peek, to: KeyCombo("ctrl+alt+cmd+e"))
        reopen()
        check(
            "rebound, the row says the new key", row("a.peek")?.subtitle == "Every tab's terminal, live  ⌃⌥⌘E", row("a.peek")?.subtitle ?? "nil")
        keys.reset(peek)
        reopen()
        check("and back", row("a.peek")?.subtitle?.hasSuffix(now) == true, row("a.peek")?.subtitle ?? "nil")

        // The rows the window writes: each names its command, and its
        // words hold no key of their own.
        let named = [
            "a.newTab", "a.splitRight", "a.splitDown", "a.newTask", "a.openFolder", "a.shortcuts", "a.whatsNew", "a.overview", "a.focusSidebar",
            "a.focusTerminal", "a.focusEditor", "a.goToFile", "a.focusRight", "a.focusInbox", "a.nextColumn", "a.previousColumn", "a.peek",
            "a.reviewBranch", "a.sidebar", "a.overgit", "a.api", "a.notes", "a.diff",
        ]
        let glyphs = CharacterSet(charactersIn: "⌘⌥⌃⇧")
        for id in named {
            guard let item = row(id) else {
                check("⌘K has \(id)", false)
                continue
            }
            var words = item.subtitle ?? ""
            if let live = PaletteCommands.command(of: item).flatMap({ keys.key(for: $0)?.display }), words.hasSuffix(live) {
                words = String(words.dropLast(live.count))
            }
            check(
                "\(id) names its command and writes no key", item.command != nil && words.rangeOfCharacter(from: glyphs) == nil,
                "\(item.command ?? "no command"): \(item.subtitle ?? "nil")")
        }
        check("Help's Keyboard Shortcuts is a row of its own", row("a.shortcuts") != nil && row("menu.help.shortcuts") == nil)
        check("Help's What's New is a row of its own", row("a.whatsNew") != nil && row("menu.help.whatsNew") == nil)
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
