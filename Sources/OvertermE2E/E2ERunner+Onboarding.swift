#if E2E
import AppKit
import Foundation

/// Onboarding's stage 0, run in the `task` scenario (its steps 3 and 5 in
/// the `onboarding` scenario too): New Task outside a repository offers
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
        // Stage 1's rule past the rail: the pane header's tooltips read the key bound now.
        func paneHelp() -> [String] { Self.accessibilityHelps("pane.splitRight", in: root) }
        let split = KeyHints.help("Split Right", command: "splits.right")
        check("the pane header's Split Right says its key", await eventually(3) { paneHelp().contains(split) }, "\(paneHelp()) vs \(split)")
        if let command = KeyCommands.byID["splits.right"] {
            keys.set(command, to: KeyCombo("ctrl+alt+cmd+d"))
            check("rebound, the pane header follows", await eventually(3) { paneHelp().contains("Split Right (⌃⌥⌘D)") }, "\(paneHelp())")
            keys.reset(command)
            check("and back", await eventually(3) { paneHelp().contains(split) }, "\(paneHelp())")
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
        // Stage 3 (risk 3): every other scenario is a first launch too, and shows no Start card.
        app.beginStart(.fresh)
        check("no Start card in any scenario but onboarding", !Start.shared.active && !Start.shared.state.isShown && !present("start.card"))
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
            "a.newTab", "a.splitRight", "a.splitDown", "a.newTask", "a.openFolder", "a.shortcuts", "a.whatsNew", "a.gettingStarted", "a.resetTips", "a.checkSetup", "a.overview",
            "a.focusSidebar",
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
        check("Help's Getting Started is a row of its own", row("a.gettingStarted") != nil && row("menu.help.gettingStarted") == nil)
        check("Help's Reset Tips is a row of its own", row("a.resetTips") != nil && row("menu.help.resetTips") == nil)
        check("Help's Check Setup is a row of its own", row("a.checkSetup") != nil && row("menu.help.setup") == nil)
    }

    /// Stages 3 and 4, the `onboarding` scenario (onboarding 7.3, 7.6,
    /// 7.10): the Start card's five steps done through the window's own
    /// methods and the card's own buttons, and the tips raised by the real
    /// paths — a mark sent by the shell, ⌘K shown, an agent's tab — all
    /// pressed through the accessibility tree, never with synthetic input;
    /// after every one the keyboard still in the terminal (7.14): a press
    /// on the card or a tip must not take it. That last check is the
    /// design's gate (risk 1); a real click is the person's to try
    /// (issue-tracker#132).
    func onboardingScenario() async {
        guard let root = window.contentView else { return check("the window's content", false) }
        let start = Start.shared
        check("the onboarding scenario wakes Start in an isolated run", start.active)
        guard start.active else { return }
        func present(_ id: String) -> Bool { Self.accessibilityPress(id, in: root, press: false) }
        func press(_ id: String) -> Bool { Self.accessibilityPress(id, in: root) }
        func keyboardStays(_ after: String) async {
            check(
                "after \(after), the keyboard is still the terminal's",
                await eventually(2) { self.window.firstResponder === self.app.store.selected?.terminal },
                "\(String(describing: self.window.firstResponder))")
        }
        // No agent on the PATH, git there, no gh: the second step's facts.
        SetupProbe.override = SetupFacts(
            shellAnswered: true, agents: Dictionary(uniqueKeysWithValues: Agent.allCases.map { agent in (agent, AgentFinder.Result.missing) }),
            developerTools: true, gh: nil)
        defer { SetupProbe.override = nil }
        await waitForPrompt()

        // 1. A fresh launch: nothing in front of the shell, the card open at the sidebar's foot.
        app.beginStart(.fresh)
        check("a fresh install's card is open", start.state.card == .open && start.state.isShown)
        check("no sheet, page or overlay in front of the shell", window.attachedSheet == nil && app.store.showingOverlay == nil)
        check("the card shows in the sidebar", await eventually(3) { present("start.card") && present("start.title") })
        check("with nothing done yet", StartText.collapsed(start.state) == "Getting started · 0 of 5", StartText.collapsed(start.state))
        check("its first step open, with Open Folder…", present("start.button.file.openFolder") && present("start.step.repository"))
        check("its foot: Check Setup · Turn Off Tips", present("start.foot.checkSetup") && present("start.turnOffTips"))
        await keyboardStays("the card appeared")

        // The chevron and the collapsed row: open, collapsed, open.
        check("the chevron pressed", press("start.chevron"))
        check("collapsed to one row", await eventually(2) { start.state.card == .collapsed && present("start.collapsed") })
        await keyboardStays("the chevron")
        check("the collapsed row pressed", press("start.collapsed"))
        check("open again", await eventually(2) { start.state.card == .open && present("start.title") })
        await keyboardStays("the collapsed row")

        // Turn Off Tips on the open card: the card goes; tips on again, back.
        check("Turn Off Tips pressed", press("start.turnOffTips"))
        check("tips off, the card gone", await eventually(2) { !Settings.shared.tips && !present("start.card") })
        await keyboardStays("Turn Off Tips")
        Settings.shared.set("general.tips", nil)
        check("tips on again, the card is back", await eventually(2) { present("start.card") })

        // Its Open Folder… is the menu item's: Finder's panel, as a sheet.
        check("Open Folder… pressed on the card", press("start.button.file.openFolder"))
        let panel = await eventually(3) { self.window.attachedSheet != nil }
        check("opens Finder's panel", panel)
        await keyboardStays("Open Folder… on the card")
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        _ = await eventually(2) { self.window.attachedSheet == nil }

        // 1b. A fresh install's two settings: its tools' panels and the theme.
        await freshInstallChecks(root: root, keyboardStays: keyboardStays)

        // 3. New Task outside a repository offers Open Folder….
        await newTaskOutsideARepositoryChecks()
        await keyboardStays("New Task outside a repository")

        // 4. A repository opened: the first step done.
        let repo = scratch.appendingPathComponent("onboarding-repo")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        try? await git(["commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        app.open([repo])
        check("a repository opened does the first step", await eventually(10) { start.state.isDone(.repository) })
        await keyboardStays("a repository opened")

        // 2. In the home folder outside a repository: Files' strip says what
        // to open instead (stage 1's rule) — a scratch home of the run's own.
        // After step 4: the git home below is a repository, and would do step 1.
        let home = scratch.appendingPathComponent("onboarding-home", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let first = app.store.selected
        // The home folder as the window names it once the tab is there (the
        // temporary folder's /var is /private/var to a shell), then the
        // sidebar drawn again for it.
        func becomeHome(_ folder: URL) async {
            _ = await eventually(8) { self.app.tree.root?.lastPathComponent == folder.lastPathComponent }
            EmptyStates.homeOverride = app.tree.root ?? folder
            app.sidebarPanel.panel = .git
            app.sidebarPanel.panel = .files
        }
        app.newTab(in: home)
        let homeTab = app.store.selected
        await becomeHome(home)
        check(
            "Files over the home folder shows its strip, with Open Folder…",
            await eventually(8) { present("files.homeStrip") && present("files.openFolder") },
            "root \(app.tree.root?.path ?? "nil"), checked \(app.diff.root?.path ?? "nil"), not a repository: \(app.diff.notARepository)")
        await keyboardStays("the home strip")
        // A home folder kept in git is a repository: no strip.
        let gitHome = scratch.appendingPathComponent("onboarding-git-home", isDirectory: true)
        try? FileManager.default.createDirectory(at: gitHome, withIntermediateDirectories: true)
        try? await git(["init", "-q", "-b", "main"], in: gitHome)
        try? await git(["commit", "-q", "--allow-empty", "-m", "home"], in: gitHome)
        app.newTab(in: gitHome)
        let gitHomeTab = app.store.selected
        await becomeHome(gitHome)
        // Its read in: the window's own, which said it is a repository.
        _ = await eventually(8) { self.app.diff.root?.lastPathComponent == gitHome.lastPathComponent && self.app.diff.branch == "main" }
        check(
            "a home folder that is a repository shows none",
            app.diff.root?.lastPathComponent == gitHome.lastPathComponent && !app.diff.notARepository && !present("files.homeStrip"),
            "checked \(app.diff.root?.path ?? "nil"), not a repository: \(app.diff.notARepository)")
        EmptyStates.homeOverride = nil
        app.closeTabsWithoutAsking([homeTab, gitHomeTab].compactMap { tab in tab })
        if let first { app.store.select(first) }
        app.focusSelectedTerminal()
        await keyboardStays("the home tabs closed")

        // 5a. The login shell silent: said, with what can be done — never "Asking…" for good.
        // The card's own probe first (Check Again waits for one in flight).
        _ = await eventually(5) { start.setup != nil }
        let facts = SetupProbe.override
        SetupProbe.override = SetupFacts(shellAnswered: false)
        start.probe(force: true)
        check(
            "a shell that didn't answer is said, with Check Again, A shell only and Check Setup",
            await eventually(5) {
                StartText.agentStep(start.setup) == .noAnswer && present("start.checkAgain") && present("start.shellOnly") && present("start.checkSetup")
            },
            "\(String(describing: start.setup))")
        await keyboardStays("the shell's silence")
        SetupProbe.override = facts
        check("Check Again asks again", press("start.checkAgain"))
        _ = await eventually(5) { start.setup?.shellAnswered == true }

        // 5. No agent found: said on the second step; an agent's tab types nothing.
        check(
            "no agent found: the second step says so and offers A shell only",
            await eventually(5) { StartText.agentStep(start.setup) == .noneFound && present("start.shellOnly") },
            "\(String(describing: start.setup))")
        var opened: [Agent] = []
        app.agentTabRecorder = { agent, _ in opened.append(agent) }
        app.findAgent = { _ in .missing }
        app.newAgentTab(.claude)
        check("an agent not on the PATH is said before anything is typed", await eventually(3) { self.window.attachedSheet != nil } && opened.isEmpty)
        // Stage 5 (7.4): the warning offers the Setup page.
        check("the warning offers Check Setup", sheetHasButton("Check Setup"))
        clickSheetButton("Check Setup")
        _ = await eventually(2) { self.window.attachedSheet == nil }
        check("Check Setup shows the Setup page, and nothing is typed", await eventually(3) { self.app.store.showingOverlay == .setup } && opened.isEmpty)
        app.hideOverlay()
        app.closeOverlay(.setup)
        app.findAgent = { AgentFinder.find($0) }
        app.agentTabRecorder = nil
        check("nothing opened", opened.isEmpty)

        // 6. A shell only, chosen on the card: written where Settings ▸ Agents writes it.
        check("A shell only pressed", press("start.shellOnly"))
        check(
            "the second step is done, New Task starts a shell",
            await eventually(2) { start.state.isDone(.agent) } && Settings.shared.taskAgent == "shell", Settings.shared.taskAgent)
        await keyboardStays("A shell only")

        // 7. A task made: the third step done.
        do {
            try await app.createTask(repo: repo, branch: "first-task", base: "main", agent: nil)
        } catch {
            check("New Task makes its worktree", false, error.localizedDescription)
        }
        check("a task made does the third step", start.state.isDone(.task))
        app.focusSelectedTerminal()

        // 8. A tab that needs you (stage 4, T1): the task's tab, in the
        // background, sends the agent's notification as `attention` does.
        // A fresh Mac's notifications: not asked yet — injected, never asked of macOS.
        AttentionNotifier.permissionOverride = .notAsked
        defer { AttentionNotifier.permissionOverride = nil }
        guard let worked = app.store.selected, let other = app.store.tabs.first(where: { $0 !== worked }) else {
            return check("two tabs to switch between", false)
        }
        app.store.select(other)
        _ = await eventually(2) { self.window.firstResponder === other.terminal }
        let strip = app.tabBarView.map { bar in bar.convert(NSPoint(x: bar.bounds.maxX - 24, y: bar.bounds.midY), to: nil) }
        let stripBefore = strip.map { Self.answering(window, at: $0) }
        func notify(_ tab: Tab) {
            tab.terminal.insertText("printf '\\033]777;notify;Claude;needs your permission\\a'")
            tab.terminal.pressReturn()
        }
        // The live decision `AttentionNotifier.notify` asks: a fresh first
        // launch, tips on, T1 not seen — the question waits for T1.
        check("before the first mark, the notification ask is held for T1", Start.shared.holdsNotificationAsk)
        notify(worked)
        check("the task's tab is marked waiting", await eventually(10) { worked.activity.mark == .waiting }, "\(worked.activity.mark)")
        func showsT1() -> Bool {
            if case .needsYou(_, .waiting)? = start.state.banner { return true }
            return false
        }
        check(
            "T1: the first mark brings the tip, under the title bar", await eventually(3) { showsT1() && present("tip.banner") },
            "\(String(describing: start.state.banner))")
        check("its words show", present("tip.text"))
        check("seen once shown: the notification ask is no longer held for it", !start.holdsNotificationAsk)
        await keyboardStays("T1 appeared")
        if let strip, let stripBefore {
            check("the strip answers a press as it did", Self.answering(window, at: strip) == stripBefore, "\(Self.answering(window, at: strip)) vs \(stripBefore)")
        }
        check("its host refuses the keyboard", app.tipBanner.map { host in !host.acceptsFirstResponder } ?? false)

        // 9. Notifications not asked: T1 offers to ask, by this click (D-6).
        check("not asked yet: T1 offers Allow Notifications…", await eventually(3) { present("tip.allowNotifications") && present("tip.offer") })
        let asked = AttentionNotifier.requestedNow
        check("Allow Notifications… pressed", press("tip.allowNotifications"))
        check("it asks then — an isolated run counts it and puts no question", await eventually(2) { AttentionNotifier.requestedNow == asked + 1 })
        await keyboardStays("Allow Notifications…")
        // What `notify` and `summarize` decide by, along the real path: T1
        // shown, a later notice asks as it always did.
        check("T1 shown: the live decision asks lazily again", !Start.shared.holdsNotificationAsk && start.state.tipsSeen.contains(.needsYou))
        // A sheet covers its place: hidden while it shows, back after.
        app.resetTips(nil)
        check("Reset Tips asks first", await eventually(3) { self.window.attachedSheet != nil })
        check("the tip waits under a sheet", await eventually(2) { self.app.tipBanner?.isHidden == true })
        clickSheetButton("Cancel")
        _ = await eventually(2) { self.window.attachedSheet == nil }
        check("and is back after", await eventually(2) { present("tip.banner") })
        check("Cancel resets nothing", start.state.tipsSeen.contains(.needsYou))

        // 10. The Inbox, from the card's Open Inbox: T1 goes, the fourth step is done.
        app.updateAttentionBadge()
        check("while a tab needs you, the card offers Open Inbox", await eventually(3) { start.anyNeedsYou && present("start.button.inbox.show") })
        check("Open Inbox pressed", press("start.button.inbox.show"))
        check("the Inbox opens, and the fourth step is done", await eventually(3) { self.app.inboxItem?.isCollapsed == false && start.state.isDone(.answered) })
        check("T1 goes with it", await eventually(2) { start.state.banner == nil && !present("tip.banner") })
        await keyboardStays("Open Inbox")
        app.toggleInbox(nil)

        // 11. Another mark: no tip — each shows once.
        worked.activity.seen()
        app.updateAttentionBadge()
        notify(worked)
        check("the tab is marked again", await eventually(10) { worked.activity.mark == .waiting })
        await pause(0.3)
        check("and no tip comes", start.state.banner == nil && start.state.waiting.isEmpty && !present("tip.banner"))
        await keyboardStays("a second mark")
        worked.activity.seen()
        app.updateAttentionBadge()

        // 12. A second, agent-shaped tab in the same launch: T4 waits for
        // a later launch — one banner tip a launch, T1 was this one's.
        let tabs = Set(app.store.tabs.map(\.id))
        app.newTab(in: repo, agent: .claude, command: "true")
        guard let agentTab = app.store.tabs.first(where: { !tabs.contains($0.id) }) else { return check("an agent's tab", false) }
        await pause(0.3)
        check(
            "T4 is held: one banner tip a launch", start.state.banner == nil && !start.state.tipsSeen.contains(.agentTools) && !present("tip.banner"),
            "\(String(describing: start.state.banner))")
        app.closeTabsWithoutAsking([agentTab])
        app.store.select(worked)
        app.focusSelectedTerminal()
        await keyboardStays("an agent's tab")

        // T3: ⌘K's hint row, from the first showing; Reset Tips counts again.
        app.showPalette(nil)
        let clear = KeyHints.key("terminal.clear") ?? "?"
        check(
            "⌘K's hint row says where Clear the Screen went", app.palette.tip == "Clear the screen is \(clear) here.",
            app.palette.tip ?? "nil")
        check("in the palette's own row, not the banner", await eventually(2) { present("palette.tip") } && !present("tip.banner"))
        app.hidePalette()
        app.resetTips(nil)
        _ = await eventually(3) { self.window.attachedSheet != nil }
        clickSheetButton("Reset Tips")
        check("Reset Tips: every tip again, ⌘K counted from nought", await eventually(2) { start.state.tipsSeen.isEmpty && start.state.paletteOpens == 0 })
        await keyboardStays("Reset Tips")

        // 13. The changes shown: all five done, the loop said, the panels offered.
        check("Show Changes pressed", await eventually(3) { present("start.button.changes.toggle") } && press("start.button.changes.toggle"))
        check("the changes pane shows, the fifth step done", await eventually(3) { self.app.diffItem?.isCollapsed == false && start.state.allDone })
        check("the card says That's the loop.", await eventually(3) { present("start.doneTitle") && present("start.done") })
        let toggled = SidebarPanel.allCases.filter { $0.toggleKey != nil }
        check("eight ticks, one for each panel with a switch", toggled.count == 8 && toggled.allSatisfy { present("start.panel.\($0.rawValue)") })
        check("each ticked as its setting says", toggled.allSatisfy { start.panels[$0] == Settings.shared.bool($0.toggleKey ?? "") })
        await keyboardStays("Show Changes")
        // The theme line (a fresh install's pair, chosen in step 1b), and its Change….
        let themeWords = Self.accessibilityElement("start.theme", in: root)?.text ?? ""
        check(
            "the done state says the theme, following macOS",
            themeWords == "Theme: \(FreshInstall.darkTheme) / \(FreshInstall.lightTheme), following macOS" && present("start.changeTheme"), themeWords)
        check("Change… pressed", press("start.changeTheme"))
        check(
            "Change… opens Settings ▸ Themes", await eventually(3) { self.app.store.settingsShowing && self.app.settingsPage.section == .themes },
            "\(app.settingsPage.section)")
        let sidebar = app.sidebarItem?.viewController.view
        let onCard = (window.firstResponder as? NSView).map { view in sidebar.map { column in view.isDescendant(of: column) } ?? false } ?? false
        check("and leaves no keyboard on the card", !onCard, "\(String(describing: window.firstResponder))")
        app.closeOverlay(.settings)
        app.focusSelectedTerminal()
        for key in FreshInstall.themeKeys { Settings.shared.set(key, nil) }
        app.toggleDiff(nil)

        // 14. Kubernetes unticked: its setting off, its icon off the rail.
        if SidebarPanel.shown.contains(.kubernetes) {
            app.performStartAction(.setPanel(.kubernetes, false))
            check("unticked, kubernetes.enabled is off", !Settings.shared.bool("kubernetes.enabled"))
            check("and the rail loses its icon", await eventually(3) { !present("sidebar.rail.kubernetes") })
            Settings.shared.set("kubernetes.enabled", nil)
            await keyboardStays("a tick")
        }

        // 15. Done: put away for good — a second Start from the same defaults shows nothing.
        check("Done pressed", press("start.done"))
        check("the card is put away", await eventually(2) { !start.state.isShown && !present("start.card") })
        check("kept as closed", AppEnvironment.defaults.string(forKey: Start.cardKey) == "closed")
        let again = Start(defaults: AppEnvironment.defaults, active: true)
        again.begin(.same)
        check("the next launch shows none", !again.state.isShown)
        await keyboardStays("Done")

        // 16. Help ▸ Getting Started brings it back, open: the one way in that moves the keyboard.
        app.showGettingStarted(nil)
        check("Getting Started brings the card back, open", await eventually(3) { start.state.card == .open && present("start.card") })
        check(
            "and gives the sidebar the keyboard, as asked",
            (window.firstResponder as? NSView)?.accessibilityIdentifier() == "sidebar.keyboard", "\(String(describing: window.firstResponder))")
        app.focusSelectedTerminal()

        // 17. Turn Off Tips (the open card's; the done state has Done):
        // general.tips off, the card gone, nothing shown after.
        app.performStartAction(.turnOffTips)
        check("general.tips is off, the card gone", await eventually(2) { !Settings.shared.tips && !present("start.card") })
        start.note(.changesShown)
        start.note(.inRepository)
        check("later events show nothing", !start.state.isShown)
        Settings.shared.set("general.tips", nil)

        // 18. Check Setup (stage 5, 7.7): asked for, never by itself.
        await setupPageChecks(root: root)

        // 20. An update's defaults: no card.
        let suite = scratch.appendingPathComponent("updated-defaults").path
        if let updated = UserDefaults(suiteName: suite) {
            updated.set("1.6.2", forKey: FirstRun.lastRunVersionKey)
            let upgraded = Start(defaults: updated, active: true)
            upgraded.begin(.upgraded(from: "1.6.2"))
            check("an update gets no card", !upgraded.state.isShown && updated.object(forKey: Start.cardKey) == nil)
            updated.removePersistentDomain(forName: suite)
        }
    }

    /// Step 18: the Setup page from Help's action with the probe's facts
    /// injected — its rows those facts word for word, read while it shows
    /// and dropped when it goes; Put in a New Tab types and presses no
    /// Return; Allow… asks by the click; Esc gives the keyboard back.
    private func setupPageChecks(root: NSView) async {
        func present(_ id: String) -> Bool { Self.accessibilityPress(id, in: root, press: false) }
        let claude = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
        var agents = Dictionary(uniqueKeysWithValues: Agent.allCases.map { agent in (agent, AgentFinder.Result.missing) })
        agents[.claude] = .found(claude, onPath: true)
        let facts = SetupFacts(
            shellAnswered: true, agents: agents, usedBefore: [.claude], developerTools: true, gh: nil, notifications: .notAsked, toolGroups: 8,
            bridgeServing: true)
        let before = SetupProbe.override
        defer { SetupProbe.override = before }
        SetupProbe.override = facts
        check("the Setup page isn't open by itself", app.store.showingOverlay != .setup && !app.setupPage.visible)

        app.showSetup(nil)
        check("Check Setup shows the page", await eventually(3) { self.app.store.showingOverlay == .setup && present("setup.page") })
        let page = app.pages.view(.setup)
        check(
            "and gives it the keyboard: the person asked",
            page.flatMap { page in (window.firstResponder as? NSView)?.isDescendant(of: page) } ?? false, "\(String(describing: window.firstResponder))")
        let rows = SetupCheck.rows(facts: facts)
        check("its rows are the injected facts'", await eventually(5) { self.app.setupPage.rows == rows }, "\(String(describing: self.app.setupPage.rows))")
        for row in rows {
            let shown = Self.accessibilityElement("setup.detail.\(row.id.key)", in: root)?.text ?? ""
            check("\(row.title) says “\(row.detail)”", shown.contains(row.detail), shown)
        }
        check(
            "Claude Code: where it is, used here before",
            rows.first { $0.id == .agent(.claude) }?.detail == "/opt/homebrew/bin/claude · used here before")
        check(
            "the GitHub CLI: what needs it, and its command",
            rows.first { $0.id == .gh }.map { row in row.detail == "not found · pull requests, CI and update checks need it" && row.action == .command("brew install gh") }
                ?? false)
        check("Notifications not asked: Allow… is offered", present("setup.allow.notifications"))
        check("the page says no tool was run", Self.accessibilityElement("setup.note", in: root)?.text.contains("No tool was run.") == true)
        let steps = Self.accessibilityElement("setup.steps", in: root)?.text ?? ""
        check("Getting started has the person's own step times", steps.contains("pened a repository"), steps)
        check("kept on this Mac only", present("setup.usageAsk") && (Self.accessibilityElementTexts(root).contains { $0.contains(SetupCheck.keptHere) }))

        // Put in a New Tab: the command typed, never run.
        var typed: [String] = []
        app.setupTabRecorder = { command in typed.append(command) }
        check("Put in a New Tab pressed", Self.accessibilityPress("setup.newTab.gh", in: root))
        check("it types the row's command, and nothing presses Return", await eventually(2) { typed == ["brew install gh"] }, "\(typed)")
        app.setupTabRecorder = nil

        // Allow…: the system's question, by this click (an isolated run counts it).
        let asked = AttentionNotifier.requestedNow
        check("Allow… pressed", Self.accessibilityPress("setup.allow.notifications", in: root))
        check("it asks then", await eventually(2) { AttentionNotifier.requestedNow == asked + 1 })

        // What runs by itself: general.usageAsk, its switch.
        app.performSetupAction(.usageAsk(false))
        check("the usage switch turns general.usageAsk off", !Settings.shared.usageAsk && !app.setupPage.usageAsk)
        Settings.shared.set("general.usageAsk", nil)
        check("and on again from Settings, the page follows", await eventually(2) { self.app.setupPage.usageAsk })

        // Tools the panels use: folded, nothing read; opened, a scenario's facts.
        let panels = SetupPanelFacts(
            kubernetes: SetupPanelFacts.Kubernetes(kubectl: nil, contexts: 3, production: 1),
            simulator: SetupPanelFacts.Simulator(xcode: false, coreSimulator: false))
        let panelsBefore = SetupProbe.panelsOverride
        defer { SetupProbe.panelsOverride = panelsBefore }
        SetupProbe.panelsOverride = panels
        check("the panels' tools are folded, and not read", app.setupPage.panels == .closed && !present("setup.row.kubectl"))
        check("opened", Self.accessibilityPress("setup.panels", in: root))
        check("their rows are the injected facts'", await eventually(3) { self.app.setupPage.panelRows == SetupCheck.panelRows(panels) })
        let kube = Self.accessibilityElement("setup.detail.kubeconfig", in: root)?.text ?? ""
        check("Kubernetes says its contexts, and how many are production", kube.contains("3 contexts, 1 production"), kube)
        let kubectl = Self.accessibilityElement("setup.detail.kubectl", in: root)?.text ?? ""
        check("kubectl not found, in the feature's own words", kubectl.contains("No kubectl found. Install it, or set Settings ▸ Kubernetes ▸ kubectl."), kubectl)
        app.performSetupAction(.panels(false))
        check("folded again", app.setupPage.panels == .closed)

        // Esc: the page put away, the keyboard back to the terminal; what it read dropped.
        check("the page's host answers Esc", page is SetupHostingView)
        (page as? SetupHostingView)?.cancelOperation(nil)
        check("Esc closes the page", await eventually(2) { self.app.store.showingOverlay == nil })
        check(
            "the keyboard is the terminal's again", await eventually(2) { self.window.firstResponder === self.app.store.selected?.terminal },
            "\(String(describing: self.window.firstResponder))")
        check("what it read is dropped", app.setupPage.facts == nil && !app.setupPage.visible)

        // hideOverlay leaves the terminal the first responder too.
        app.showSetup(nil)
        _ = await eventually(3) { self.app.store.showingOverlay == .setup }
        app.hideOverlay()
        check(
            "hideOverlay gives the keyboard to the terminal", await eventually(2) { self.window.firstResponder === self.app.store.selected?.terminal })
        app.closeOverlay(.setup)
    }

    /// Step 1b: a fresh install's two settings (`FreshInstall`), through
    /// `FreshInstallSetup` with the scenario's own look at the Mac — an
    /// isolated run looks at nothing of the user's. The panels whose tool
    /// isn't there start hidden and the card says so in one line, with
    /// Show; the PATH unknown, an update or the same version hides nothing;
    /// the theme follows macOS with the chosen pair unless a Ghostty config
    /// or settings.json names one. Each decided once.
    private func freshInstallChecks(root: NSView, keyboardStays: (String) async -> Void) async {
        func present(_ id: String) -> Bool { Self.accessibilityPress(id, in: root, press: false) }
        func press(_ id: String) -> Bool { Self.accessibilityPress(id, in: root) }
        let settings = Settings.shared
        let defaults = AppEnvironment.defaults
        let start = Start.shared
        let panelKeys = FreshInstall.toolPanels.compactMap(\.toggleKey)
        let others = ["api.enabled", "database.enabled", "notes.enabled", "general.sessions", "general.snippets"]
        func forget() {
            for key in [FreshInstall.panelsDecidedKey, FreshInstall.panelsHiddenKey, FreshInstall.themeDecidedKey] { defaults.removeObject(forKey: key) }
        }
        func reset() {
            for key in panelKeys + FreshInstall.themeKeys { settings.set(key, nil) }
            forget()
        }
        func noneSet(_ keys: [String]) -> Bool { !keys.contains { key in settings.isSet(key) } }
        reset()
        defer {
            FreshInstallSetup.toolsOverride = nil
            FreshInstallSetup.ghosttyThemeOverride = nil
        }

        // Nothing handed over: an isolated run looks at nothing, decides nothing.
        FreshInstallSetup.toolsOverride = nil
        FreshInstallSetup.ghosttyThemeOverride = nil
        let unlooked = await FreshInstallSetup.decidePanels(.fresh)
        check(
            "an isolated run without the scenario's look hides nothing and decides nothing",
            unlooked.isEmpty && noneSet(panelKeys) && defaults.object(forKey: FreshInstall.panelsDecidedKey) == nil)
        check(
            "nor chooses a theme",
            !FreshInstallSetup.chooseTheme(.fresh) && noneSet(FreshInstall.themeKeys)
                && defaults.object(forKey: FreshInstall.themeDecidedKey) == nil)

        // The login shell silent: the PATH unknown, nothing hidden — and decided, once.
        FreshInstallSetup.toolsOverride = .unknown
        let silent = await FreshInstallSetup.decidePanels(.fresh)
        check("the PATH unknown: nothing hidden", silent.isEmpty && noneSet(panelKeys), "\(silent)")
        check("and decided: it never runs again", defaults.bool(forKey: FreshInstall.panelsDecidedKey))
        forget()

        // An update, or the same version: nothing changes, whatever is missing.
        FreshInstallSetup.toolsOverride = FreshInstall.Tools(pathKnown: true)
        FreshInstallSetup.ghosttyThemeOverride = false
        for launch in [FirstRun.Launch.upgraded(from: "1.6.8"), .same] {
            let hidden = await FreshInstallSetup.decidePanels(launch)
            let themed = FreshInstallSetup.chooseTheme(launch)
            check(
                "\(launch == .same ? "the same version" : "an update"): no panel hidden, no theme chosen",
                hidden.isEmpty && !themed && noneSet(panelKeys + FreshInstall.themeKeys)
                    && defaults.object(forKey: FreshInstall.panelsDecidedKey) == nil && defaults.object(forKey: FreshInstall.themeDecidedKey) == nil)
        }

        // Fresh, no docker, kubectl or terraform — Terraform's switch the
        // person's own already, in settings.json: Docker and Kubernetes hidden.
        settings.set("terraform.enabled", .bool(false))
        let hidden = await FreshInstallSetup.decidePanels(.fresh)
        check("no docker, kubectl or terraform: Docker and Kubernetes hidden", hidden == [.docker, .kubernetes], "\(hidden)")
        check("their switches off in settings.json", !settings.bool("docker.enabled") && !settings.bool("kubernetes.enabled"))
        check(
            "Terraform's, the person's, kept and not claimed",
            settings.isSet("terraform.enabled") && FreshInstall.hidden(stored: defaults.stringArray(forKey: FreshInstall.panelsHiddenKey)) == [.docker, .kubernetes])
        check("API, Database, Notes, Sessions and Snippets left as they are", noneSet(others))
        let twice = await FreshInstallSetup.decidePanels(.fresh)
        check("decided once: never again", twice.isEmpty && defaults.bool(forKey: FreshInstall.panelsDecidedKey))
        settings.set("terraform.enabled", nil)

        // The card: one line, and Show.
        start.hiddenAtInstallChanged()
        check(
            "the card says what was hidden, in one line, with Show",
            await eventually(3) { present("start.hiddenPanels") && present("start.showHidden") })
        let words = Self.accessibilityElement("start.hiddenPanels", in: root)?.text ?? ""
        check("“Docker, Kubernetes hidden — not found on this Mac”", words.contains("Docker, Kubernetes hidden — not found on this Mac"), words)
        // Check Setup's "Tools the panels use" says the same.
        let inputs = SetupPanelProbe.Inputs(
            home: scratch, appPath: nil, docker: settings.dockerEnabled, kubernetes: settings.kubernetesEnabled, terraform: false, simulator: false,
            languageServers: false, hiddenAtInstall: start.hiddenAtInstall)
        let facts = SetupPanelProbe.facts(
            inputs, login: nil, exists: { _ in false }, isExecutable: { _ in false },
            dockerEndpoint: { DockerEndpoint(address: .unix("/var/run/docker.sock"), source: "default") }, kubeconfigs: { [] }, terraformBinary: { nil },
            discovery: ServerDiscovery(home: scratch, searchDirectories: [], toolchainDirectories: [], runsXcrun: false))
        let rows = SetupCheck.panelRows(facts).filter { row in row.detail == SetupCheck.hiddenAtInstallDetail }
        check("and Check Setup agrees", rows.map(\.id) == [.panelHidden(.docker), .panelHidden(.kubernetes)], "\(rows.map(\.id))")
        check("Show pressed", press("start.showHidden"))
        check(
            "Show turns them on again, and the line goes",
            await eventually(3) { settings.dockerEnabled && settings.kubernetesEnabled && !present("start.hiddenPanels") })
        await keyboardStays("Show")

        // The theme: a Ghostty config naming one keeps it.
        FreshInstallSetup.ghosttyThemeOverride = true
        check("a Ghostty config naming a theme: untouched", !FreshInstallSetup.chooseTheme(.fresh) && noneSet(FreshInstall.themeKeys))
        check("and decided", defaults.bool(forKey: FreshInstall.themeDecidedKey))
        forget()
        // settings.json naming one keeps it.
        FreshInstallSetup.ghosttyThemeOverride = false
        settings.set("appearance.theme", .string("Claude Dark"))
        check(
            "settings.json naming a theme: untouched",
            !FreshInstallSetup.chooseTheme(.fresh) && settings.string("appearance.theme") == "Claude Dark" && !settings.followsSystemAppearance)
        settings.set("appearance.theme", nil)
        forget()
        // Fresh, nothing named: it follows macOS with the pair.
        check("fresh: the pair chosen", FreshInstallSetup.chooseTheme(.fresh))
        check(
            "the terminal follows macOS, \(FreshInstall.darkTheme) after dark and \(FreshInstall.lightTheme) in daylight",
            settings.followsSystemAppearance && settings.string("appearance.theme") == FreshInstall.darkTheme
                && settings.string("appearance.themeLight") == FreshInstall.lightTheme)
        check("chosen once", !FreshInstallSetup.chooseTheme(.fresh))
        check("the card knows it", await eventually(2) { start.theme.follows && start.theme.dark == FreshInstall.darkTheme })
        forget()
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
        check(
            "with Open the Tab Anyway, Cancel and Check Setup",
            sheetHasButton("Open the Tab Anyway") && sheetHasButton("Cancel") && sheetHasButton("Check Setup"))
        check("and nothing typed: no tab yet", app.store.tabs.count == tabs && opened.isEmpty)
        clickSheetButton("Cancel")
        _ = await eventually(2) { self.window.attachedSheet == nil }
        check("Cancel opens nothing", app.store.tabs.count == tabs && opened.isEmpty)

        // A tab in a folder (the sidebar's New ‹agent› Tab Here, Ask
        // Agent's) is said first too, and what waits for the tab — Ask
        // Agent's prompt — goes nowhere at Cancel.
        var handed = 0
        app.newAgentTab(.claude, in: scratch) { _ in handed += 1 }
        check("a tab in a folder is said first too", await eventually(3) { self.window.attachedSheet != nil })
        clickSheetButton("Cancel")
        _ = await eventually(2) { self.window.attachedSheet == nil }
        check("its Cancel hands no tab on: nothing typed anywhere", handed == 0 && app.store.tabs.count == tabs && opened.isEmpty)

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
