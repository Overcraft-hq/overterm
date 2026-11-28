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

    /// The tips (7.6, D-9): four, one time each, each there to head off a
    /// real surprise, not to announce a feature. The raw values are what
    /// `onboarding.tipsSeen` keeps. A fifth is the owner's call (stage 6);
    /// a sixth fails `StartStateTests` (risk 6).
    package enum Tip: String, CaseIterable, Sendable {
        /// T1: the first mark a tab raises — the Inbox, its key, and the
        /// notification permission asked by a click (D-6).
        case needsYou
        /// T2: the first pane whose header says production.
        case production
        /// T3: ⌘K's first three showings — Clear the Screen is ⇧⌘K here.
        case clearMoved
        /// T4: the first agent tab Overterm starts — what its tools are.
        case agentTools

        /// No more than this, ever (D-9).
        package static let cap = 5

        /// Its id in `onboarding.tipsSeen`.
        package var seenKey: String { rawValue }
        /// What Reset Tips clears for it, beside its seen key: T3's count.
        package var resetsCount: Bool { self == .clearMoved }
        /// In the banner under the title bar; T3 is the palette's own hint row.
        package var inBanner: Bool { self != .clearMoved }
        /// Shown whatever the one-a-launch limit says (7.6): T2 is about
        /// production; T1 carries the notification offer, and the first
        /// agent tab's T4 would otherwise push it to a later launch.
        package var exempt: Bool { self == .needsYou || self == .production }
    }

    /// The mark a tab raised, as T1 words it.
    package enum Mark: String, Sendable {
        case waiting, done, failed
    }

    /// What a pane's header says is production (T2).
    package enum Production: Equatable, Sendable {
        /// kubectl there reaches this context.
        case kubernetes(context: String)
        /// terraform there runs in this root.
        case terraform(root: String)
    }

    /// A banner tip, with what its words name.
    package enum Banner: Equatable, Sendable {
        case needsYou(tab: String, mark: Mark)
        case production(Production)
        case agentTools

        package var tip: Tip {
            switch self {
            case .needsYou: .needsYou
            case .production: .production
            case .agentTools: .agentTools
            }
        }
    }

    /// What happened, from the one-line `Start.shared.note(_:)` calls.
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
        /// A tab's mark went up, by any of its three ways (T1).
        case markRaised(Mark, tab: String)
        /// A pane's header said production (T2).
        case productionPane(Production)
        /// ⌘K showed (T3).
        case paletteOpened
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
    /// Tips shown, closed, or made needless by the feature used
    /// (`onboarding.tipsSeen`): never again, until Reset Tips.
    package var tipsSeen: Set<Tip>
    /// ⌘K's showings while T3 counts, up to three (`onboarding.paletteOpens`).
    package var paletteOpens: Int

    // What follows is this launch's, never kept.

    /// This launch is a fresh install's first: the notification ask waits
    /// for T1's button (D-6). From the second launch on it is asked as before.
    package var fresh = false
    /// The banner tip placed, shown while nothing covers its place.
    package var banner: Banner?
    /// Banner tips raised, waiting for their place (`placing`).
    package var waiting: [Banner] = []
    /// A banner tip has been placed this launch: the one-a-launch limit.
    package var bannerThisLaunch = false
    /// ⌘K's showing just now says T3 in its hint row.
    package var paletteTip = false
    /// A sheet, ⌘K, Tab Peek or the held-settings banner shows: a tip
    /// waits, and one placed hides until they've gone. The held banner is
    /// a security question and stands alone.
    package var blocked = false
    /// The app is in front: a tip is placed only then, where it is seen.
    package var inFront = true

    package init(
        steps: [Step: Date] = [:], card: Card? = nil, tips: Bool = true, asked: Bool = false, tipsSeen: Set<Tip> = [], paletteOpens: Int = 0
    ) {
        self.steps = steps
        self.card = card
        self.tips = tips
        self.asked = asked
        self.tipsSeen = tipsSeen
        self.paletteOpens = paletteOpens
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
        case .markRaised, .productionPane, .paletteOpened: nil
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
    /// back collapsed. An update counts every tip of this version seen:
    /// nobody is told about what they have been using.
    package func launched(_ launch: FirstRun.Launch) -> StartState {
        var next = self
        next.fresh = false
        switch launch {
        case .fresh:
            next.card = .open
            next.fresh = true
        case .upgraded:
            if next.card == .open { next.card = .collapsed }
            next.tipsSeen = Set(Tip.allCases)
        case .same:
            if next.card == .open { next.card = .collapsed }
        }
        return next
    }

    // MARK: Tips

    /// The banner tip showing now: placed, and nothing covering its place.
    package var shownBanner: Banner? { blocked ? nil : banner }

    /// Whether the notification ask waits for T1's button (D-6): a fresh
    /// install's first launch, tips on, T1 not seen yet.
    package var holdsNotificationAsk: Bool { fresh && tips && !tipsSeen.contains(.needsYou) }

    /// `event` at `now`, with the tips' rules (7.6): its step done, and the
    /// banner tip it places, if one takes its place now. Every tip once;
    /// none while `tips` is off; none for a feature already used; one
    /// banner tip a launch but T1 and T2; no timer — a tip stays until
    /// closed or answered.
    package func apply(_ event: Event, now: Date) -> (state: StartState, tip: Banner?) {
        var next = applying(event, now: now)
        next.paletteTip = false
        switch event {
        case .markRaised(let mark, let tab):
            next.raise(.needsYou(tab: tab, mark: mark))
        case .productionPane(let production):
            next.raise(.production(production))
        case .agentTabStarted:
            next.raise(.agentTools)
        case .paletteOpened:
            next.openedPalette()
        case .inboxOpened:
            // The Inbox opened, with a mark or before any: T1 has nothing to teach.
            next.tipsSeen.insert(.needsYou)
            next.drop(.needsYou)
        case .waitingTabSelected:
            // T1's tab looked at: placed, it was seen and goes; waiting, it
            // goes unseen, for the next mark to raise.
            next.drop(.needsYou)
        case .inRepository, .agentChosen, .taskCreated, .changesShown:
            break
        }
        return next.placing()
    }

    /// × on the banner: gone for good (it was seen when placed); the next
    /// waiting one may take its place.
    package func dismissingTip() -> (state: StartState, tip: Banner?) {
        var next = self
        if let banner { next.tipsSeen.insert(banner.tip) }
        next.banner = nil
        return next.placing()
    }

    /// What covers a tip's place, and whether the app is in front.
    package func withRoom(blocked: Bool, inFront: Bool) -> (state: StartState, tip: Banner?) {
        var next = self
        next.blocked = blocked
        next.inFront = inFront
        return next.placing()
    }

    /// Help ▸ Reset Tips: every tip shows again, the next time its moment
    /// comes; T3 counts its three showings again. The limit stays this launch's.
    package func resettingTips() -> StartState {
        var next = self
        next.tipsSeen = []
        next.paletteOpens = 0
        next.paletteTip = false
        return next
    }

    private mutating func raise(_ banner: Banner) {
        let tip = banner.tip
        guard tips, !tipsSeen.contains(tip), self.banner?.tip != tip, !waiting.contains(where: { $0.tip == tip }) else { return }
        // Past the limit it isn't kept: it comes again at a later launch.
        guard tip.exempt || !bannerThisLaunch else { return }
        waiting.append(banner)
    }

    private mutating func drop(_ tip: Tip) {
        if banner?.tip == tip { banner = nil }
        waiting.removeAll { $0.tip == tip }
    }

    private mutating func openedPalette() {
        guard tips, !tipsSeen.contains(.clearMoved) else { return }
        paletteOpens = min(paletteOpens + 1, 3)
        paletteTip = true
        if paletteOpens >= 3 { tipsSeen.insert(.clearMoved) }
    }

    /// The first waiting tip into the banner's place, when it is empty,
    /// uncovered and the app in front. T1 and T2 go first; one past the
    /// limit is dropped unseen.
    private func placing() -> (state: StartState, tip: Banner?) {
        var next = self
        guard next.tips else {
            next.banner = nil
            next.waiting = []
            return (next, nil)
        }
        guard next.banner == nil, !next.blocked, next.inFront else { return (next, nil) }
        let order = next.waiting.filter { $0.tip.exempt } + next.waiting.filter { !$0.tip.exempt }
        next.waiting = []
        for (index, candidate) in order.enumerated() {
            if !candidate.tip.exempt && next.bannerThisLaunch { continue }
            next.banner = candidate
            next.tipsSeen.insert(candidate.tip)
            next.bannerThisLaunch = true
            next.waiting = order.suffix(from: index + 1).filter { $0.tip.exempt }
            return (next, candidate)
        }
        return (next, nil)
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
        if !on {
            next.asked = false
            next.banner = nil
            next.waiting = []
            next.paletteTip = false
        }
        return next
    }

    // MARK: Kept

    /// `onboarding.card`, `onboarding.steps`, `onboarding.tipsSeen` and
    /// `onboarding.paletteOpens` as the defaults hold them: an id this
    /// build doesn't know is passed over.
    package init(storedCard: String?, storedSteps: [String: Any]?, tips: Bool, storedTips: [String]? = nil, paletteOpens: Int = 0) {
        var steps: [Step: Date] = [:]
        for (id, value) in storedSteps ?? [:] {
            guard let step = Step(rawValue: id), let date = value as? Date else { continue }
            steps[step] = date
        }
        self.init(
            steps: steps, card: storedCard.flatMap(Card.init(rawValue:)), tips: tips, tipsSeen: Set((storedTips ?? []).compactMap(Tip.init(rawValue:))),
            paletteOpens: min(max(paletteOpens, 0), 3))
    }

    /// The tips seen as `onboarding.tipsSeen` keeps them, in a fixed order.
    package var storedTips: [String] { Tip.allCases.filter { tip in tipsSeen.contains(tip) }.map(\.seenKey) }

    /// The steps as `onboarding.steps` keeps them.
    package var storedSteps: [String: Date] {
        Dictionary(uniqueKeysWithValues: steps.map { ($0.key.rawValue, $0.value) })
    }
}
