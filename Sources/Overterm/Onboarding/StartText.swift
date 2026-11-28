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
        /// Asked, and the login shell didn't answer: Check Again, A shell
        /// only and Check Setup offered, never "Asking…" for good.
        case noAnswer
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
    /// The login shell asked and silent (an error in its rc files, or
    /// slower than `ShellEnvironment.timeout`).
    package static let noAnswer = "Your login shell didn't answer, so its PATH is unknown."
    package static let probeNote = "Asked your login shell for its PATH and looked at files. No tool was run."
    package static let checkAgain = "Check Again"
    /// The second step's link to the Setup page (Help ▸ Check Setup…).
    package static let checkSetup = "Check Setup"
    package static let needsRepository = "Open a repository first"

    // MARK: The done state's theme line

    /// The terminal's theme as Settings has it, for the done state's line.
    package struct Theme: Equatable, Sendable {
        /// `appearance.theme`: the one theme, or the pair's dark half.
        package var dark: String
        /// `appearance.themeLight`: the pair's light half.
        package var light: String
        /// `appearance.followSystemAppearance`.
        package var follows: Bool
        /// The person's own Ghostty config names a theme (its last `theme`
        /// line, as `FreshInstall.ghosttySetsTheme` reads it, any of the
        /// files libghostty loads): with no theme in Settings, it decides.
        package var ghosttyConfig: Bool

        package init(dark: String, light: String, follows: Bool, ghosttyConfig: Bool) {
            self.dark = dark
            self.light = light
            self.follows = follows
            self.ghosttyConfig = ghosttyConfig
        }
    }

    /// "Theme: Catppuccin Mocha / Catppuccin Latte, following macOS" — the
    /// theme in force, said as Settings ▸ Themes would; its button beside it.
    package static func themeLine(_ theme: Theme) -> String {
        let names: String
        if theme.follows, !theme.dark.isEmpty, !theme.light.isEmpty {
            names = "\(theme.dark) / \(theme.light), following macOS"
        } else if !theme.dark.isEmpty {
            names = theme.dark
        } else {
            names = theme.ghosttyConfig ? "your Ghostty config's" : "Ghostty's default"
        }
        return "Theme: \(names)"
    }

    /// The theme line's button: Settings ▸ Themes.
    package static let changeTheme = "Change…"

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
        guard let setup else { return .asking }
        guard setup.shellAnswered else { return .noAnswer }
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
        return SetupCheck.rows(facts: setup, home: home).filter { row in (row.id == .git || row.id == .gh) && row.isProblem }
    }

    /// VoiceOver's value for a step.
    package static func accessibilityValue(done: Bool) -> String { done ? "done" : "not done" }

    // MARK: Tips (7.6)

    /// The commands the tips name; `keys` holds theirs for a tip's words.
    package static let tipCommands = ["inbox.show", "tabs.nextAttention", "terminal.clear"]

    /// A banner tip's button: what it does is the menu item's of the same
    /// name, or the setting's page.
    package struct TipButton: Equatable, Sendable {
        package let title: String
        package let action: TipAction
        /// Its accessibility identifier.
        package let id: String
    }

    /// T1's second line, while macOS hasn't asked yet (D-6).
    package static let notificationOffer = "Want a notification when this happens while you're in another app?"
    package static let allowNotifications = "Allow Notifications…"
    package static let openInbox = "Open Inbox"
    package static let closeTip = "Close Tip"

    /// "Settings ▸ Kubernetes": the page's own title, as Settings shows it.
    package static func settingsName(_ section: SettingsSection) -> String { "Settings ▸ \(section.title)" }

    /// A banner tip's words: its keys as bound now, a setting by its page's title.
    package func tip(_ banner: StartState.Banner) -> String {
        switch banner {
        case .needsYou(let tab, let mark, _):
            let inbox = keys["inbox.show"].map { "\($0) opens the Inbox" } ?? "View ▸ Inbox opens the Inbox"
            let next = keys["tabs.nextAttention"].map { " \($0) goes to the tab." } ?? ""
            switch mark {
            case .waiting: return "“\(tab)” needs you. \(inbox): answer from there.\(next)"
            case .done: return "“\(tab)” has finished. \(inbox): every tab with something to say.\(next)"
            case .failed: return "“\(tab)” failed. \(inbox): every tab with something to say.\(next)"
            }
        case .production(.kubernetes(let context)):
            return "This pane's kubectl points at production (\(context)). Its header says so while it does. "
                + "\(Self.settingsName(.kubernetes)) decides what counts as production."
        case .production(.terraform(let root)):
            return "This pane's terraform runs in a production root (\(root)). Its header says so while it does. "
                + "\(Self.settingsName(.terraform)) decides what counts as production."
        case .agentTools:
            return "Agents started from Overterm get its tools: the browser, databases, Docker… \(Self.settingsName(.agents)) chooses which. "
                + "One typed by hand gets none."
        }
    }

    /// The second line, if any: T1's offer while notifications are not asked.
    package static func tipOffer(_ banner: StartState.Banner, permission: NotificationPermission?) -> String? {
        guard case .needsYou = banner, permission == .notAsked else { return nil }
        return notificationOffer
    }

    /// A banner tip's buttons before its ×; Turn Off Tips is on every one.
    package static func tipButtons(_ banner: StartState.Banner, permission: NotificationPermission?) -> [TipButton] {
        switch banner {
        case .needsYou:
            var buttons = [TipButton(title: openInbox, action: .openInbox, id: "tip.openInbox")]
            if permission == .notAsked {
                buttons.append(TipButton(title: allowNotifications, action: .allowNotifications, id: "tip.allowNotifications"))
            }
            return buttons
        case .production(.kubernetes):
            return [TipButton(title: settingsName(.kubernetes), action: .settings(.kubernetes), id: "tip.settings")]
        case .production(.terraform):
            return [TipButton(title: settingsName(.terraform), action: .settings(.terraform), id: "tip.settings")]
        case .agentTools:
            return [TipButton(title: settingsName(.agents), action: .settings(.agents), id: "tip.settings")]
        }
    }

    /// T3, ⌘K's hint row on its first three showings: Ghostty's ⌘K is the
    /// palette here. `ghosttyConfig`: the person has one, and it applies.
    package func paletteTip(ghosttyConfig: Bool) -> String {
        let clear = keys["terminal.clear"].map { "Clear the screen is \($0) here." } ?? "Clear the screen is a row here: type “clear”."
        return ghosttyConfig ? "Your Ghostty config applies as it is. " + clear : clear
    }
}
