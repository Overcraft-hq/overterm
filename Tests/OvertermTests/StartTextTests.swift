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

    /// The shell not answered yet: "Asking your shell…", and the fourth
    /// step goes by the setting.
    func testTheShellStillAsked() {
        XCTAssertEqual(StartText.agentStep(nil), .asking)
        XCTAssertEqual(StartText.agentStep(SetupFacts(shellAnswered: false)), .asking)
        XCTAssertEqual(StartText.asking, "Asking your shell…")
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
            ["git — Command Line Tools not found", "GitHub CLI — not found · pull requests and CI need it"])
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
}
