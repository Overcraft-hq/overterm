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

    /// A banner tip, with what its words name. T1's `id` is its tab's:
    /// selecting that tab, and no other, takes it (nil: any tab's).
    package enum Banner: Equatable, Sendable {
        case needsYou(tab: String, mark: Mark, id: UUID? = nil)
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
        /// A tab that was waiting, or had finished, selected: its id.
        case waitingTabSelected(UUID?)
        /// The changes pane on screen.
        case changesShown
        /// A tab's mark went up, by any of its three ways (T1): its title, and its id.
        case markRaised(Mark, tab: String, id: UUID? = nil)
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
    /// When `banner` was placed, or came back on screen: T1's tab selected
    /// only goes with a T1 that has been on screen a moment (`seenAfter`)
    /// — time behind another app or under a sheet doesn't count.
    package var bannerPlacedAt: Date?
    /// The launch's one tip that isn't exempt, put back by T1 or T2 taking
    /// its place: it comes back when their place is free, not counted
    /// again against the limit, seen already.
    package var displaced: Banner?
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

    /// How long T1 has been on screen before its tab selected takes it:
    /// coming back to the app places it and selects its tab in one turn,
    /// and it must not go unseen then.
    package static let seenAfter: TimeInterval = 1

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
        case .markRaised(let mark, let tab, let id):
            next.raise(.needsYou(tab: tab, mark: mark, id: id))
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
        case .waitingTabSelected(let selected):
            // T1's tab looked at: once T1 has been on screen, it was seen
            // and goes. One still waiting — the app behind another, a sheet
            // over its place — or placed this very moment (the app coming
            // back places it and selects its tab in one turn) stays, until
            // ×, the Inbox or its own button: the first launch's
            // notification question is in it (D-6). Another tab that needs
            // you, selected, isn't the one T1 names: it stays.
            if case .needsYou(_, _, let named)? = next.banner, named == nil || named == selected, let placed = next.bannerPlacedAt,
                now.timeIntervalSince(placed) >= Self.seenAfter
            {
                next.banner = nil
                next.bannerPlacedAt = nil
            }
        case .inRepository, .agentChosen, .taskCreated, .changesShown:
            break
        }
        return next.placing(now: now)
    }

    /// × on the banner: gone for good (it was seen when placed); the next
    /// waiting one may take its place.
    package func dismissingTip(now: Date = Date()) -> (state: StartState, tip: Banner?) {
        var next = self
        if let banner { next.tipsSeen.insert(banner.tip) }
        next.banner = nil
        next.bannerPlacedAt = nil
        return next.placing(now: now)
    }

    /// What covers a tip's place, and whether the app is in front.
    package func withRoom(blocked: Bool, inFront: Bool, now: Date = Date()) -> (state: StartState, tip: Banner?) {
        var next = self
        let wasShown = !self.blocked && self.inFront
        next.blocked = blocked
        next.inFront = inFront
        // On screen again after a sheet or another app: its moment counts from now.
        if !wasShown, !blocked, inFront, next.banner != nil { next.bannerPlacedAt = now }
        return next.placing(now: now)
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
        guard tips, !tipsSeen.contains(tip), self.banner?.tip != tip, displaced?.tip != tip, !waiting.contains(where: { $0.tip == tip }) else {
            return
        }
        // Past the limit it isn't kept: it comes again at a later launch.
        guard tip.exempt || !bannerThisLaunch else { return }
        waiting.append(banner)
    }

    private mutating func drop(_ tip: Tip) {
        if banner?.tip == tip {
            banner = nil
            bannerPlacedAt = nil
        }
        if displaced?.tip == tip { displaced = nil }
        waiting.removeAll { $0.tip == tip }
    }

    private mutating func openedPalette() {
        guard tips, !tipsSeen.contains(.clearMoved) else { return }
        paletteOpens = min(paletteOpens + 1, 3)
        paletteTip = true
        if paletteOpens >= 3 { tipsSeen.insert(.clearMoved) }
    }

    /// The first waiting tip into the banner's place, when it is
    /// uncovered and the app in front. T1 and T2 go first — taking the
    /// place of a tip that isn't exempt (T4 has no timer), which waits to
    /// come back (`displaced`) —; one past the limit is dropped unseen.
    private func placing(now: Date) -> (state: StartState, tip: Banner?) {
        var next = self
        guard next.tips else {
            next.banner = nil
            next.bannerPlacedAt = nil
            next.displaced = nil
            next.waiting = []
            return (next, nil)
        }
        guard !next.blocked, next.inFront else { return (next, nil) }
        let exempt = next.waiting.filter { $0.tip.exempt }
        if let shown = next.banner, !shown.tip.exempt, !exempt.isEmpty {
            next.displaced = shown
            next.banner = nil
            next.bannerPlacedAt = nil
        }
        guard next.banner == nil else { return (next, nil) }
        if let first = exempt.first {
            // Placing counts against the limit: those not exempt still waiting are past it.
            next.waiting = Array(exempt.dropFirst())
            next.show(first, now: now)
            return (next, first)
        }
        if let back = next.displaced {
            // Already the launch's one, already seen: back without counting again.
            next.displaced = nil
            next.waiting = []
            next.banner = back
            next.bannerPlacedAt = now
            return (next, back)
        }
        let candidate = next.bannerThisLaunch ? nil : next.waiting.first
        next.waiting = []
        guard let candidate else { return (next, nil) }
        next.show(candidate, now: now)
        return (next, candidate)
    }

    private mutating func show(_ candidate: Banner, now: Date) {
        banner = candidate
        bannerPlacedAt = now
        tipsSeen.insert(candidate.tip)
        bannerThisLaunch = true
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
            next.bannerPlacedAt = nil
            next.displaced = nil
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
