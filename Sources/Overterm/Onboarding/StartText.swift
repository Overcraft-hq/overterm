import Foundation

/// Every sentence and button of the Start card (docs/design/onboarding/
/// analysis.md, 7.3), from the state, what the window knows, and the keys
/// bound now. Pure: no key is written into a sentence (7.1, rule 6) — each
/// comes from `keys`, the commands' keys as `Keybindings` has them, and a
/// command left unbound is said by its name instead.
package struct StartText: Sendable {
    /// What the card's words depend on besides the steps.
    package struct Facts: Equatable, Sendable {
        /// The selected tab is in a checkout (New Task's own test).
        package var inRepository: Bool
        /// What the probe found; nil before it has been asked.
        package var setup: SetupFacts?
        /// `agents.newTaskAgent`: an agent's raw value, or "shell".
        package var taskAgent: String
        /// Some tab needs you now: the Inbox has something to show.
        package var anyNeedsYou: Bool

        package init(inRepository: Bool, setup: SetupFacts?, taskAgent: String, anyNeedsYou: Bool) {
            self.inRepository = inRepository
            self.setup = setup
            self.taskAgent = taskAgent
            self.anyNeedsYou = anyNeedsYou
        }

        /// New Task starts a shell: chosen so, or no agent was found.
        package var shellOnly: Bool {
            if taskAgent == StartText.shellChoice { return true }
            guard let setup, setup.shellAnswered else { return false }
            return setup.agentsFound.isEmpty
        }
    }

    /// A button under the current step: what it does is the menu item's
    /// of the same command, never more.
    package struct StepButton: Equatable, Sendable {
        package let title: String
        /// The command it is, whose key shows beside it.
        package let command: String
        /// The key bound to it now; nil when unbound.
        package let key: String?
        /// Why it can't be pressed; nil when it can.
        package let disabledReason: String?

        /// What VoiceOver says: the title with its key.
        package var accessibilityLabel: String { key.map { "\(title), \($0)" } ?? title }
    }

    /// New Task's agent, as the card offers it.
    package struct Choice: Equatable, Sendable {
        /// `agents.newTaskAgent`'s value: an agent's raw value, or "shell".
        package let value: String
        package let title: String
    }

    /// The second step's body.
    package enum AgentStep: Equatable, Sendable {
        /// The login shell hasn't said its PATH yet.
        case asking
        /// The agents found, then A shell only.
        case choose([Choice])
        /// None found: A shell only, alone.
        case noneFound
    }

    /// The commands whose keys the card says.
    package static let commands = [
        "file.openFolder", "tasks.new", "inbox.show", "tabs.nextAttention", "changes.toggle", "review.branch", "palette.show",
    ]

    /// Each command's key as bound now, by id; an unbound one is absent.
    package let keys: [String: String]

    package init(keys: [String: String]) { self.keys = keys }

    // MARK: The card's own words

    package static let title = "Overterm"
    /// What the app is, in one sentence (onboarding 2.5, dead end 2).
    package static let pitch = "Several checkouts at once, each with an agent in it."
    package static let privacy = "No account. Overterm sends no telemetry."
    package static let turnOffTips = "Turn Off Tips"
    package static let close = "Close Getting Started"
    package static let doneTitle = "That's the loop."
    package static let whatYouUse = "What you use:"
    package static let done = "Done"
    package static let shellChoice = "shell"
    package static let shellOnly = "A shell only"
    package static let newTaskStarts = "New Task starts:"
    package static let asking = "Asking your shell…"
    package static let noAgent = "No agent found on your PATH."
    package static let probeNote = "Asked your login shell for its PATH and looked at files. No tool was run."
    package static let checkAgain = "Check Again"
    package static let needsRepository = "Open a repository first"

    /// The collapsed row: "Getting started · 2 of 5".
    package static func collapsed(_ state: StartState) -> String {
        "Getting started · \(state.doneCount) of \(StartState.Step.allCases.count)"
    }

    /// The done state's line: where everything else is, and what comes
    /// back at the next launch (onboarding 2.5, dead end 11).
    package var doneLine: String {
        let palette = keys["palette.show"].map { "\($0) finds" } ?? "The command palette finds"
        return "\(palette) everything else. Tabs come back at the next launch; agents resume their conversation."
    }

    // MARK: Steps

    package static func title(of step: StartState.Step) -> String {
        switch step {
        case .repository: "Open a repository"
        case .agent: "Pick what works on it"
        case .task: "Start a task"
        case .answered: "Answer a tab that needs you"
        case .changes: "See what it changed"
        }
    }

    /// The one line under the current step; the second step's is the
    /// label before its menu (`agentStep`).
    package func line(of step: StartState.Step, facts: Facts) -> String {
        switch step {
        case .repository:
            return "Everything follows the tab's folder."
        case .agent:
            return Self.newTaskStarts
        case .task:
            // New Task's own words for what it makes.
            return "A worktree on its own branch, with a tab in it."
        case .answered:
            if facts.shellOnly {
                return "Run something that takes over \(Int(TabActivity.longCommand)) seconds and switch away. Its tab says when it ends."
            }
            let inbox = keys["inbox.show"].map { "\($0) opens the Inbox" } ?? "View ▸ Inbox opens the Inbox"
            let next = keys["tabs.nextAttention"].map { ", \($0) goes to it" } ?? ""
            return "Go back to your own tab. This one says when it needs you: \(inbox)\(next)."
        case .changes:
            let changes = keys["changes.toggle"] ?? "View ▸ Changes"
            let review = keys["review.branch"].map { "\($0) reviews" } ?? "Review Branch reviews"
            return "\(changes) shows the changes. \(review) the whole branch."
        }
    }

    /// The current step's button; nil where it has none (the second step
    /// has its menu; the fourth a button only while a tab needs you).
    package func button(of step: StartState.Step, facts: Facts) -> StepButton? {
        func make(_ title: String, _ command: String, disabled: String? = nil) -> StepButton {
            StepButton(title: title, command: command, key: keys[command], disabledReason: disabled)
        }
        switch step {
        case .repository: return make("Open Folder…", "file.openFolder")
        case .agent: return nil
        case .task: return make("New Task…", "tasks.new", disabled: facts.inRepository ? nil : Self.needsRepository)
        case .answered: return facts.anyNeedsYou ? make("Open Inbox", "inbox.show") : nil
        case .changes: return make("Show Changes", "changes.toggle")
        }
    }

    /// The second step: what New Task can start, as the probe found it.
    package static func agentStep(_ setup: SetupFacts?) -> AgentStep {
        guard let setup, setup.shellAnswered else { return .asking }
        let found = setup.agentsFound
        guard !found.isEmpty else { return .noneFound }
        let agents = found.map { agent in
            Choice(value: agent.rawValue, title: agent.productName + (setup.usedBefore.contains(agent) ? " · used here before" : ""))
        }
        return .choose(agents + [Choice(value: shellChoice, title: shellOnly)])
    }

    /// The menu's label: the choice made now, by its name.
    package static func choiceTitle(_ value: String) -> String {
        Agent(rawValue: value)?.productName ?? shellOnly
    }

    /// The setup rows the second step shows: only what is wrong with git
    /// or the GitHub CLI — the agents are its menu.
    package static func problems(_ setup: SetupFacts?, home: String = NSHomeDirectory()) -> [SetupRow] {
        guard let setup else { return [] }
        return SetupCheck.rows(facts: setup, home: home).filter { $0.id != .agents && $0.isProblem }
    }

    /// VoiceOver's value for a step.
    package static func accessibilityValue(done: Bool) -> String { done ? "done" : "not done" }
}
