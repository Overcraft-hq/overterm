import Foundation

/// The Start card's state (docs/design/onboarding/analysis.md, 7.10): the
/// five steps done and when, whether the card is open, collapsed or put
/// away, and whether tips are on. Pure — `Start` keeps it and says what
/// happened; every rule is here.
///
/// A step is done when the work is really done, anywhere in the app, in
/// any order (`applying`): nothing is locked, nothing waits on another
/// step, and there is no Next. A sixth step is the owner's call.
package struct StartState: Equatable, Sendable {
    /// The five steps, in the order the card lists them. The raw values are
    /// what `onboarding.steps` keeps (D-12): five fixed ids, five dates.
    package enum Step: String, CaseIterable, Sendable {
        case repository, agent, task, answered, changes
    }

    /// How the card shows, as `onboarding.card` keeps it.
    package enum Card: String, Sendable {
        case open, collapsed
        /// × or Done: gone for good, until Help ▸ Getting Started.
        case closed
    }

    /// What happened, from the one-line `Start.shared.note(_:)` calls.
    /// Stage 4's tips add theirs (a mark raised, ⌘K opened, a production pane).
    package enum Event: Equatable, Sendable {
        /// The selected tab is in a checkout: `worktrees.main != nil`, New Task's own test.
        case inRepository
        /// New Task's agent picked on the card, written to `agents.newTaskAgent`.
        case agentChosen
        /// An agent's tab started, anywhere.
        case agentTabStarted
        /// `createTask` made a worktree and its tab.
        case taskCreated
        /// The Inbox opened; `waiting`: while a tab needed you.
        case inboxOpened(waiting: Bool)
        /// A tab that was waiting, or had finished, selected.
        case waitingTabSelected
        /// The changes pane on screen.
        case changesShown
    }

    /// Each step done, and when (D-12: shown on the Setup page, kept on this Mac only).
    package var steps: [Step: Date]
    /// nil: never offered — an update, or the same version after one.
    package var card: Card?
    /// `general.tips`: off, neither the card nor a tip shows (D-11).
    package var tips: Bool
    /// Help ▸ Getting Started asked for the card this run: it shows
    /// whatever `tips` says — the person asked. Never kept.
    package var asked: Bool

    package init(steps: [Step: Date] = [:], card: Card? = nil, tips: Bool = true, asked: Bool = false) {
        self.steps = steps
        self.card = card
        self.tips = tips
        self.asked = asked
    }

    package func isDone(_ step: Step) -> Bool { steps[step] != nil }
    package var doneCount: Int { Step.allCases.count { steps[$0] != nil } }
    /// All five: the card says "That's the loop." and offers the panels.
    package var allDone: Bool { doneCount == Step.allCases.count }
    /// The step whose line and button show: the first not done.
    package var current: Step? { Step.allCases.first { steps[$0] == nil } }
    /// Whether the card is in the sidebar at all.
    package var isShown: Bool { (tips || asked) && (card == .open || card == .collapsed) }

    /// The step an event does, if any.
    package static func step(for event: Event) -> Step? {
        switch event {
        case .inRepository: .repository
        case .agentChosen, .agentTabStarted: .agent
        case .taskCreated: .task
        case .inboxOpened(let waiting): waiting ? .answered : nil
        case .waitingTabSelected: .answered
        case .changesShown: .changes
        }
    }

    /// `event` at `now`: its step done, the first time only. Steps are
    /// kept whether or not the card shows — the work was done.
    package func applying(_ event: Event, now: Date) -> StartState {
        guard let step = Self.step(for: event), steps[step] == nil else { return self }
        var next = self
        next.steps[step] = now
        return next
    }

    /// At launch, as `FirstRun` decided it (7.2): a fresh install opens
    /// the card (D-2); an update never offers one — a card kept from
    /// before stays as it was; after the first launch an open card comes
    /// back collapsed.
    package func launched(_ launch: FirstRun.Launch) -> StartState {
        var next = self
        switch launch {
        case .fresh:
            next.card = .open
        case .upgraded, .same:
            if next.card == .open { next.card = .collapsed }
        }
        return next
    }

    /// Help ▸ Getting Started: open, whatever the flags say.
    package func gettingStarted() -> StartState {
        var next = self
        next.card = .open
        next.asked = true
        return next
    }

    /// The chevron, or a click on the collapsed row.
    package func toggled() -> StartState {
        var next = self
        switch card {
        case .open: next.card = .collapsed
        case .collapsed: next.card = .open
        case .closed, nil: break
        }
        return next
    }

    /// × or Done: gone for good. Tips go on.
    package func closed() -> StartState {
        var next = self
        next.card = .closed
        next.asked = false
        return next
    }

    /// `general.tips` changed: off takes the card and every tip with it.
    package func withTips(_ on: Bool) -> StartState {
        var next = self
        next.tips = on
        if !on { next.asked = false }
        return next
    }

    // MARK: Kept

    /// `onboarding.card`, `onboarding.steps` as the defaults hold them:
    /// an id this build doesn't know is passed over.
    package init(storedCard: String?, storedSteps: [String: Any]?, tips: Bool) {
        var steps: [Step: Date] = [:]
        for (id, value) in storedSteps ?? [:] {
            guard let step = Step(rawValue: id), let date = value as? Date else { continue }
            steps[step] = date
        }
        self.init(steps: steps, card: storedCard.flatMap(Card.init(rawValue:)), tips: tips)
    }

    /// The steps as `onboarding.steps` keeps them.
    package var storedSteps: [String: Date] {
        Dictionary(uniqueKeysWithValues: steps.map { ($0.key.rawValue, $0.value) })
    }
}
