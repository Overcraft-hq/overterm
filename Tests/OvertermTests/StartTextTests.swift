import XCTest

@testable import Overterm

/// Onboarding 7.3: every line and button of the Start card for each set of
/// facts — no agent found, a shell only, outside a repository, the shell
/// still asked — and every key read as bound now: a rebinding changes the
/// line, so a key written into the text fails here (risk 15).
@MainActor
final class StartTextTests: XCTestCase {
    private let bound = [
        "file.openFolder": "⌥⌘O", "tasks.new": "⇧⌘N", "inbox.show": "⌘I", "tabs.nextAttention": "⌥⌘↓", "changes.toggle": "⌥⌘D",
        "review.branch": "⇧⌘R", "palette.show": "⌘K",
    ]
    private let claude = URL(fileURLWithPath: "/opt/homebrew/bin/claude")

    private func facts(
        inRepository: Bool = true, setup: SetupFacts? = nil, taskAgent: String = "claude", anyNeedsYou: Bool = false
    ) -> StartText.Facts {
        StartText.Facts(inRepository: inRepository, setup: setup, taskAgent: taskAgent, anyNeedsYou: anyNeedsYou)
    }

    private var found: SetupFacts {
        SetupFacts(
            shellAnswered: true, agents: [.claude: .found(claude, onPath: true), .codex: .missing], usedBefore: [.claude],
            gh: URL(fileURLWithPath: "/opt/homebrew/bin/gh"))
    }
    private var noAgent: SetupFacts {
        SetupFacts(shellAnswered: true, agents: Dictionary(uniqueKeysWithValues: Agent.allCases.map { ($0, AgentFinder.Result.missing) }))
    }

    func testTheCardSaysWhatTheAppIs() {
        XCTAssertEqual(StartText.pitch, "Several checkouts at once, each with an agent in it.")
        XCTAssertEqual(StartText.privacy, "No account. Overterm sends no telemetry.")
        XCTAssertEqual(
            StartText(keys: bound).doneLine, "⌘K finds everything else. Tabs come back at the next launch; agents resume their conversation.")
        XCTAssertEqual(StartText.collapsed(StartState().applying(.inRepository, now: Date()).applying(.taskCreated, now: Date())), "Getting started · 2 of 5")
    }

    func testEachStepsLineAndButton() {
        let text = StartText(keys: bound)
        XCTAssertEqual(text.line(of: .repository, facts: facts()), "Everything follows the tab's folder.")
        XCTAssertEqual(text.button(of: .repository, facts: facts())?.title, "Open Folder…")
        XCTAssertEqual(text.button(of: .repository, facts: facts())?.command, "file.openFolder")
        XCTAssertEqual(text.line(of: .agent, facts: facts()), "New Task starts:")
        XCTAssertNil(text.button(of: .agent, facts: facts()), "the second step has its menu")
        XCTAssertEqual(text.line(of: .task, facts: facts()), "A worktree on its own branch, with a tab in it.")
        let task = text.button(of: .task, facts: facts())
        XCTAssertEqual(task?.title, "New Task…")
        XCTAssertEqual(task?.key, "⇧⌘N")
        XCTAssertEqual(task?.accessibilityLabel, "New Task…, ⇧⌘N", "VoiceOver hears the key too")
        XCTAssertNil(task?.disabledReason)
        XCTAssertEqual(
            text.line(of: .answered, facts: facts(setup: found)),
            "Go back to your own tab. This one says when it needs you: ⌘I opens the Inbox, ⌥⌘↓ goes to it.")
        XCTAssertNil(text.button(of: .answered, facts: facts()), "Open Inbox only while a tab waits")
        XCTAssertEqual(text.button(of: .answered, facts: facts(anyNeedsYou: true))?.command, "inbox.show")
        XCTAssertEqual(text.line(of: .changes, facts: facts()), "⌥⌘D shows the changes. ⇧⌘R reviews the whole branch.")
        XCTAssertEqual(text.button(of: .changes, facts: facts())?.title, "Show Changes")
    }

    /// Outside a repository New Task is greyed, and says why.
    func testOutsideARepositoryNewTaskSaysWhyNot() {
        let button = StartText(keys: bound).button(of: .task, facts: facts(inRepository: false))
        XCTAssertEqual(button?.disabledReason, "Open a repository first")
        XCTAssertEqual(StartText(keys: bound).button(of: .repository, facts: facts(inRepository: false))?.disabledReason, nil)
    }

    /// The shell not asked yet: "Asking your shell…"; asked and silent:
    /// said so, never "Asking…" for good. The fourth step goes by the setting.
    func testTheShellStillAsked() {
        XCTAssertEqual(StartText.agentStep(nil), .asking)
        XCTAssertEqual(StartText.agentStep(SetupFacts(shellAnswered: false)), .noAnswer, "the probe came back with no answer")
        XCTAssertEqual(StartText.asking, "Asking your shell…")
        XCTAssertEqual(StartText.noAnswer, "Your login shell didn't answer, so its PATH is unknown.")
        XCTAssertFalse(facts(setup: SetupFacts(shellAnswered: false)).shellOnly)
        XCTAssertTrue(facts(setup: SetupFacts(shellAnswered: false), taskAgent: "shell").shellOnly)
    }

    /// The agents found, used-here-before first, then A shell only.
    func testTheAgentsFoundAreTheMenu() {
        var setup = found
        setup.agents[.opencode] = .found(URL(fileURLWithPath: "/usr/local/bin/opencode"), onPath: true)
        setup.agents[.gemini] = .found(URL(fileURLWithPath: "/Users/me/.claude/local/gemini"), onPath: false)
        guard case .choose(let choices) = StartText.agentStep(setup) else { return XCTFail("a menu") }
        XCTAssertEqual(choices.map(\.title), ["Claude Code · used here before", "opencode", "A shell only"], "off the PATH isn't offered")
        XCTAssertEqual(choices.map(\.value), ["claude", "opencode", "shell"])
        XCTAssertEqual(StartText.choiceTitle("shell"), "A shell only")
        XCTAssertEqual(StartText.choiceTitle("codex"), "Codex")
    }

    /// No agent found: said so, A shell only offered — and the fourth step
    /// teaches the tab's mark with a long command instead of the Inbox.
    func testNoAgentFound() {
        XCTAssertEqual(StartText.agentStep(noAgent), .noneFound)
        XCTAssertEqual(StartText.noAgent, "No agent found on your PATH.")
        let text = StartText(keys: bound)
        XCTAssertEqual(
            text.line(of: .answered, facts: facts(setup: noAgent)),
            "Run something that takes over 10 seconds and switch away. Its tab says when it ends.")
    }

    func testAShellOnly() {
        let line = StartText(keys: bound).line(of: .answered, facts: facts(setup: found, taskAgent: "shell"))
        XCTAssertTrue(line.hasPrefix("Run something that takes over \(Int(TabActivity.longCommand)) seconds"), line)
    }

    /// Only what is wrong with git or gh; never the agents' row, never "signed in".
    func testTheProblemRows() {
        XCTAssertEqual(StartText.problems(nil), [])
        XCTAssertEqual(StartText.problems(found), [])
        var broken = found
        broken.developerTools = false
        broken.gh = nil
        XCTAssertEqual(
            StartText.problems(broken).map { "\($0.title) — \($0.detail)" },
            ["git — Command Line Tools not found", "GitHub CLI — not found · pull requests, CI and update checks need it"])
        XCTAssertEqual(StartText.probeNote, "Asked your login shell for its PATH and looked at files. No tool was run.")
    }

    /// Rebound, the line follows; unbound, it names the command instead.
    func testKeysAreReadAsBoundNow() {
        var rebound = bound
        rebound["changes.toggle"] = "⌃⌥⌘D"
        rebound["tasks.new"] = "⌃⌘N"
        let text = StartText(keys: rebound)
        XCTAssertEqual(text.line(of: .changes, facts: facts()), "⌃⌥⌘D shows the changes. ⇧⌘R reviews the whole branch.")
        XCTAssertEqual(text.button(of: .task, facts: facts())?.key, "⌃⌘N")

        let unbound = StartText(keys: [:])
        XCTAssertEqual(unbound.line(of: .changes, facts: facts()), "View ▸ Changes shows the changes. Review Branch reviews the whole branch.")
        XCTAssertEqual(
            unbound.line(of: .answered, facts: facts(setup: found)), "Go back to your own tab. This one says when it needs you: View ▸ Inbox opens the Inbox.")
        XCTAssertNil(unbound.button(of: .repository, facts: facts())?.key, "Open Folder… has no key by default (D-10)")
        XCTAssertEqual(unbound.button(of: .task, facts: facts())?.accessibilityLabel, "New Task…")
        XCTAssertTrue(unbound.doneLine.hasPrefix("The command palette finds everything else."))
        // No key in any line but what `keys` gave.
        let glyphs = CharacterSet(charactersIn: "⌘⌥⌃⇧")
        for step in StartState.Step.allCases {
            for setup in [nil, found, noAgent] as [SetupFacts?] {
                let line = unbound.line(of: step, facts: facts(setup: setup))
                XCTAssertNil(line.rangeOfCharacter(from: glyphs), "\(step): \(line)")
            }
        }
    }

    /// Every command the card names is a real one, so its key can be read.
    func testTheCardsCommandsExist() {
        for id in StartText.commands { XCTAssertNotNil(KeyCommands.byID[id], id) }
        let text = StartText(keys: bound)
        for step in StartState.Step.allCases {
            if let button = text.button(of: step, facts: facts(anyNeedsYou: true)) {
                XCTAssertTrue(StartText.commands.contains(button.command), button.command)
            }
        }
    }

    func testStepTitlesAndVoiceOverValues() {
        XCTAssertEqual(
            StartState.Step.allCases.map(StartText.title(of:)),
            ["Open a repository", "Pick what works on it", "Start a task", "Answer a tab that needs you", "See what it changed"])
        XCTAssertEqual(StartText.accessibilityValue(done: true), "done")
        XCTAssertEqual(StartText.accessibilityValue(done: false), "not done")
    }

    // MARK: Tips (7.6)

    private let tipKeys = ["inbox.show": "⌘I", "tabs.nextAttention": "⌥⌘↓", "terminal.clear": "⇧⌘K"]

    func testTipWords() {
        let text = StartText(keys: tipKeys)
        XCTAssertEqual(
            text.tip(.needsYou(tab: "api", mark: .waiting)), "“api” needs you. ⌘I opens the Inbox: answer from there. ⌥⌘↓ goes to the tab.")
        XCTAssertEqual(
            text.tip(.needsYou(tab: "zsh", mark: .done)),
            "“zsh” has finished. ⌘I opens the Inbox: every tab with something to say. ⌥⌘↓ goes to the tab.")
        XCTAssertTrue(text.tip(.needsYou(tab: "zsh", mark: .failed)).hasPrefix("“zsh” failed. "))
        XCTAssertEqual(
            text.tip(.production(.kubernetes(context: "acme-prod"))),
            "This pane's kubectl points at production (acme-prod). Its header says so while it does. Settings ▸ Kubernetes decides what counts as production.")
        XCTAssertTrue(text.tip(.production(.terraform(root: "envs/prod"))).contains("Settings ▸ Terraform decides what counts as production."))
        XCTAssertEqual(
            text.tip(.agentTools),
            "Agents started from Overterm get its tools: the browser, databases, Docker… Settings ▸ Agents chooses which. One typed by hand gets none.")
        XCTAssertEqual(text.paletteTip(ghosttyConfig: false), "Clear the screen is ⇧⌘K here.")
        XCTAssertEqual(text.paletteTip(ghosttyConfig: true), "Your Ghostty config applies as it is. Clear the screen is ⇧⌘K here.")
    }

    /// Keys as bound now, settings by their page's title: a key or a page
    /// name written into a tip fails here (risk 15).
    func testTipsReadKeysAndSettingsNames() {
        let rebound = StartText(keys: ["inbox.show": "⌃⌘I", "tabs.nextAttention": "⌃⌥⌘↓", "terminal.clear": "⌃⌘L"])
        XCTAssertEqual(
            rebound.tip(.needsYou(tab: "api", mark: .waiting)), "“api” needs you. ⌃⌘I opens the Inbox: answer from there. ⌃⌥⌘↓ goes to the tab.")
        XCTAssertEqual(rebound.paletteTip(ghosttyConfig: false), "Clear the screen is ⌃⌘L here.")

        let unbound = StartText(keys: [:])
        let glyphs = CharacterSet(charactersIn: "⌘⌥⌃⇧")
        let banners: [StartState.Banner] = [
            .needsYou(tab: "api", mark: .waiting), .needsYou(tab: "api", mark: .done), .needsYou(tab: "api", mark: .failed),
            .production(.kubernetes(context: "p")), .production(.terraform(root: "r")), .agentTools,
        ]
        for banner in banners {
            XCTAssertNil(unbound.tip(banner).rangeOfCharacter(from: glyphs), "\(banner)")
        }
        XCTAssertNil(unbound.paletteTip(ghosttyConfig: true).rangeOfCharacter(from: glyphs))
        XCTAssertTrue(unbound.tip(.needsYou(tab: "api", mark: .waiting)).contains("View ▸ Inbox opens the Inbox"))

        for section in [SettingsSection.kubernetes, .terraform, .agents] {
            XCTAssertEqual(StartText.settingsName(section), "Settings ▸ \(section.title)")
        }
        for id in StartText.tipCommands { XCTAssertNotNil(KeyCommands.byID[id], id) }
        XCTAssertEqual(KeyCommands.byID["terminal.clear"]?.defaultKey, "shift+cmd+k", "T3 says where Clear the Screen went")
    }

    /// T1 offers Allow Notifications… only while macOS hasn't asked (D-6);
    /// T2 and T4 open the page that decides; none has more than two.
    func testTipButtons() {
        let t1 = StartState.Banner.needsYou(tab: "api", mark: .waiting)
        XCTAssertEqual(StartText.tipButtons(t1, permission: .notAsked).map(\.action), [.openInbox, .allowNotifications])
        XCTAssertEqual(StartText.tipOffer(t1, permission: .notAsked), StartText.notificationOffer)
        for permission in [NotificationPermission.allowed, .denied, nil] as [NotificationPermission?] {
            XCTAssertEqual(StartText.tipButtons(t1, permission: permission).map(\.action), [.openInbox], "\(String(describing: permission))")
            XCTAssertNil(StartText.tipOffer(t1, permission: permission))
        }
        XCTAssertEqual(StartText.tipButtons(.production(.kubernetes(context: "p")), permission: .notAsked).map(\.action), [.settings(.kubernetes)])
        XCTAssertEqual(StartText.tipButtons(.production(.terraform(root: "r")), permission: nil).map(\.title), ["Settings ▸ Terraform"])
        XCTAssertEqual(StartText.tipButtons(.agentTools, permission: .notAsked).map(\.action), [.settings(.agents)])
        XCTAssertNil(StartText.tipOffer(.agentTools, permission: .notAsked))
    }

    /// The done state's theme line: the pair following macOS, one theme,
    /// or none in Settings — the person's Ghostty config's, or Ghostty's own.
    func testTheThemeLine() {
        XCTAssertEqual(
            StartText.themeLine(StartText.Theme(dark: "Catppuccin Mocha", light: "Catppuccin Latte", follows: true, ghosttyConfig: false)),
            "Theme: Catppuccin Mocha / Catppuccin Latte, following macOS")
        XCTAssertEqual(StartText.themeLine(StartText.Theme(dark: "Nord", light: "One Half Light", follows: false, ghosttyConfig: false)), "Theme: Nord")
        XCTAssertEqual(StartText.themeLine(StartText.Theme(dark: "Nord", light: "", follows: true, ghosttyConfig: false)), "Theme: Nord")
        XCTAssertEqual(StartText.themeLine(StartText.Theme(dark: "", light: "", follows: false, ghosttyConfig: true)), "Theme: your Ghostty config's")
        XCTAssertEqual(StartText.themeLine(StartText.Theme(dark: "", light: "", follows: false, ghosttyConfig: false)), "Theme: Ghostty's default")
        XCTAssertEqual(StartText.changeTheme, "Change…")
    }
}
