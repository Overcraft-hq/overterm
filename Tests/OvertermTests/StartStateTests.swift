import XCTest

@testable import Overterm

/// Onboarding 7.10: the Start card's rules — steps done from what really
/// happened, in any order; the card open on a fresh install, collapsed
/// after, never after an update; `general.tips` off shows nothing.
final class StartStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testEachStepIsDoneByItsOwnEvents() {
        let cases: [(StartState.Event, StartState.Step?)] = [
            (.inRepository, .repository), (.agentChosen, .agent), (.agentTabStarted, .agent), (.taskCreated, .task),
            (.inboxOpened(waiting: true), .answered), (.inboxOpened(waiting: false), nil), (.waitingTabSelected(nil), .answered),
            (.changesShown, .changes),
        ]
        for (event, step) in cases {
            XCTAssertEqual(StartState.step(for: event), step, "\(event)")
            let after = StartState().applying(event, now: t0)
            XCTAssertEqual(after.steps.keys.first, step, "\(event)")
            XCTAssertEqual(after.doneCount, step == nil ? 0 : 1, "\(event)")
        }
    }

    /// Nothing is locked: the last step first, the first last — the same five done.
    func testAnyOrderDoesThemAll() {
        let events: [StartState.Event] = [.changesShown, .waitingTabSelected(nil), .taskCreated, .agentTabStarted, .inRepository]
        var forwards = StartState()
        var backwards = StartState()
        for (index, event) in events.enumerated() {
            forwards = forwards.applying(event, now: t0.addingTimeInterval(Double(index)))
            backwards = backwards.applying(events[events.count - 1 - index], now: t0)
        }
        XCTAssertTrue(forwards.allDone)
        XCTAssertTrue(backwards.allDone)
        XCTAssertNil(forwards.current)
        XCTAssertEqual(Set(forwards.steps.keys), Set(StartState.Step.allCases))
    }

    /// The first time is kept: doing it again moves no date (D-12).
    func testAStepKeepsItsFirstTime() {
        let once = StartState().applying(.taskCreated, now: t0)
        let twice = once.applying(.taskCreated, now: t0.addingTimeInterval(60))
        XCTAssertEqual(twice, once)
        XCTAssertEqual(twice.steps[.task], t0)
    }

    func testTheCurrentStepIsTheFirstNotDone() {
        var state = StartState()
        XCTAssertEqual(state.current, .repository)
        state = state.applying(.inRepository, now: t0)
        XCTAssertEqual(state.current, .agent)
        state = state.applying(.changesShown, now: t0)
        XCTAssertEqual(state.current, .agent, "a later step done leaves the earlier one current")
    }

    /// 7.2: fresh opens it (D-2); the next launch collapses it; an update
    /// offers none — a card kept from before stays as it was.
    func testTheLaunchDecidesTheCard() {
        let fresh = StartState().launched(.fresh)
        XCTAssertEqual(fresh.card, .open)
        XCTAssertTrue(fresh.isShown)
        XCTAssertEqual(fresh.launched(.same).card, .collapsed, "collapsed from the second launch on")
        XCTAssertEqual(StartState(card: .collapsed).launched(.same).card, .collapsed)
        XCTAssertNil(StartState().launched(.upgraded(from: "1.6.2")).card, "an update gets no card")
        XCTAssertFalse(StartState().launched(.upgraded(from: nil)).isShown)
        XCTAssertNil(StartState().launched(.same).card, "the same version after an update: still none")
        XCTAssertEqual(StartState(card: .closed).launched(.same).card, .closed, "put away stays away")
        XCTAssertEqual(StartState(card: .open).launched(.upgraded(from: "1.6.8")).card, .collapsed)
    }

    /// D-11: off, neither the card nor anything else shows — but the work
    /// done meanwhile is still kept.
    func testTipsOffShowsNothing() {
        var state = StartState(card: .open).withTips(false)
        XCTAssertFalse(state.isShown)
        state = state.applying(.taskCreated, now: t0)
        XCTAssertFalse(state.isShown)
        XCTAssertTrue(state.isDone(.task))
        XCTAssertTrue(state.withTips(true).isShown)
    }

    /// Help ▸ Getting Started opens it whatever the flags say; × puts it away.
    func testGettingStartedOpensItWhateverTheFlagsSay() {
        for state in [StartState(), StartState(card: .closed), StartState(card: .collapsed, tips: false)] {
            let asked = state.gettingStarted()
            XCTAssertEqual(asked.card, .open)
            XCTAssertTrue(asked.isShown, "\(state)")
        }
        let closed = StartState(card: .open, tips: false).gettingStarted().closed()
        XCTAssertEqual(closed.card, .closed)
        XCTAssertFalse(closed.isShown)
        XCTAssertFalse(StartState(card: .open).gettingStarted().withTips(false).isShown, "Turn Off Tips takes it too")
    }

    func testTheChevronFlipsOpenAndCollapsed() {
        XCTAssertEqual(StartState(card: .open).toggled().card, .collapsed)
        XCTAssertEqual(StartState(card: .collapsed).toggled().card, .open)
        XCTAssertEqual(StartState(card: .closed).toggled().card, .closed)
        XCTAssertNil(StartState().toggled().card)
    }

    /// `onboarding.steps`: five fixed ids, five dates; an unknown id or a
    /// value that isn't a date is passed over.
    func testTheKeptFormRoundTrips() {
        let state = StartState(card: .collapsed).applying(.inRepository, now: t0).applying(.changesShown, now: t0.addingTimeInterval(5))
        XCTAssertEqual(state.storedSteps, ["repository": t0, "changes": t0.addingTimeInterval(5)])
        let read = StartState(storedCard: "collapsed", storedSteps: state.storedSteps, tips: true)
        XCTAssertEqual(read, state)
        let odd = StartState(storedCard: "sideways", storedSteps: ["task": t0, "sixth": t0, "agent": "yesterday"], tips: true)
        XCTAssertNil(odd.card)
        XCTAssertEqual(odd.steps, [.task: t0])
        XCTAssertEqual(StartState.Step.allCases.map(\.rawValue), ["repository", "agent", "task", "answered", "changes"])
    }

    // MARK: Tips (7.6, D-9)

    private func raised(_ state: StartState, _ event: StartState.Event) -> (state: StartState, tip: StartState.Banner?) {
        state.apply(event, now: t0)
    }

    /// The registry: four tips, never more than five (risk 6) — a sixth
    /// fails here —, each with its own seen key, each brought back by Reset Tips.
    func testTheTipRegistryIsSmallAndEveryTipCanBeReset() {
        XCTAssertLessThanOrEqual(StartState.Tip.allCases.count, StartState.Tip.cap, "a sixth tip is the owner's call")
        XCTAssertEqual(StartState.Tip.cap, 5)
        XCTAssertEqual(StartState.Tip.allCases.map(\.seenKey), ["needsYou", "production", "clearMoved", "agentTools"])
        XCTAssertEqual(Set(StartState.Tip.allCases.map(\.seenKey)).count, StartState.Tip.allCases.count, "no two share a seen key")
        let all = StartState(tipsSeen: Set(StartState.Tip.allCases), paletteOpens: 3)
        let reset = all.resettingTips()
        for tip in StartState.Tip.allCases {
            XCTAssertFalse(tip.seenKey.isEmpty, "\(tip)")
            XCTAssertTrue(all.storedTips.contains(tip.seenKey), "\(tip) is kept")
            XCTAssertFalse(reset.tipsSeen.contains(tip), "Reset Tips brings \(tip) back")
            if tip.resetsCount { XCTAssertEqual(reset.paletteOpens, 0, "and its count") }
        }
        XCTAssertEqual(StartState.Tip.allCases.filter { !$0.inBanner }, [.clearMoved], "T3 is ⌘K's own row, not the banner's")
        XCTAssertEqual(StartState.Tip.allCases.filter(\.exempt), [.needsYou, .production], "T1 and T2 pass the limit")
    }

    func testEachTipShowsOnce() {
        let first = raised(StartState(), .markRaised(.waiting, tab: "api"))
        XCTAssertEqual(first.tip, .needsYou(tab: "api", mark: .waiting))
        XCTAssertEqual(first.state.banner, first.tip)
        XCTAssertTrue(first.state.tipsSeen.contains(.needsYou), "seen once placed")
        let closed = first.state.dismissingTip().state
        XCTAssertNil(closed.banner)
        let again = raised(closed, .markRaised(.waiting, tab: "web"))
        XCTAssertNil(again.tip, "× is for good")
        XCTAssertNil(again.state.banner)
        XCTAssertTrue(again.state.waiting.isEmpty)

        // T2 and T4 the same way.
        for event in [StartState.Event.productionPane(.kubernetes(context: "acme-prod")), .agentTabStarted] {
            let shown = raised(StartState(), event)
            XCTAssertNotNil(shown.tip, "\(event)")
            XCTAssertNil(raised(shown.state.dismissingTip().state, event).tip, "\(event) again")
        }
    }

    /// A tip says T1's words by the kind of mark: a shell's first mark is a
    /// finished or failed command (7.6's correction).
    func testT1ComesWithAnyKindOfMark() {
        for mark in [StartState.Mark.waiting, .done, .failed] {
            XCTAssertEqual(raised(StartState(), .markRaised(mark, tab: "zsh")).tip, .needsYou(tab: "zsh", mark: mark))
        }
    }

    /// A feature already used needs no tip: an Inbox opened before any mark.
    func testAUsedFeatureGetsNoTip() {
        let opened = raised(StartState(), .inboxOpened(waiting: false)).state
        XCTAssertTrue(opened.tipsSeen.contains(.needsYou))
        XCTAssertNil(raised(opened, .markRaised(.waiting, tab: "api")).tip)
    }

    /// T1 goes when the Inbox opens or its tab is selected; T2 and T4 only by ×.
    func testWhatEachTipGoesWith() {
        let t1 = raised(StartState(), .markRaised(.waiting, tab: "api")).state
        XCTAssertNil(raised(t1, .inboxOpened(waiting: true)).state.banner)
        XCTAssertNil(t1.apply(.waitingTabSelected(nil), now: t0.addingTimeInterval(StartState.seenAfter)).state.banner, "on screen a moment: seen")
        let t2 = raised(StartState(), .productionPane(.terraform(root: "envs/prod"))).state
        for event in [StartState.Event.inboxOpened(waiting: true), .waitingTabSelected(nil), .changesShown] {
            XCTAssertEqual(raised(t2, event).state.banner, .production(.terraform(root: "envs/prod")), "\(event)")
        }
        let t4 = raised(StartState(), .agentTabStarted).state
        XCTAssertEqual(raised(t4, .waitingTabSelected(nil)).state.banner, .agentTools)
    }

    /// T1 names its tab: another tab that needs you, selected, leaves it.
    func testT1GoesOnlyWithItsOwnTab() {
        let api = UUID()
        let web = UUID()
        let t1 = raised(StartState(), .markRaised(.waiting, tab: "api", id: api)).state
        XCTAssertEqual(t1.banner, .needsYou(tab: "api", mark: .waiting, id: api))
        let later = t0.addingTimeInterval(StartState.seenAfter)
        let other = t1.apply(.waitingTabSelected(web), now: later).state
        XCTAssertEqual(other.banner, t1.banner, "another tab selected: T1 stays")
        XCTAssertTrue(other.isDone(.answered), "the step is done all the same")
        XCTAssertNil(t1.apply(.waitingTabSelected(api), now: later).state.banner, "its own tab, after a moment: seen, it goes")
    }

    /// Time behind another app or under a sheet doesn't count toward T1's
    /// moment on screen: it counts again from when it is seen again.
    func testT1sMomentCountsOnlyWhileShown() {
        let t1 = raised(StartState(), .markRaised(.waiting, tab: "api")).state
        let behind = t1.withRoom(blocked: false, inFront: false, now: t0.addingTimeInterval(0.1)).state
        let back = behind.withRoom(blocked: false, inFront: true, now: t0.addingTimeInterval(10)).state
        XCTAssertNotNil(back.apply(.waitingTabSelected(nil), now: t0.addingTimeInterval(10.5)).state.banner, "back half a second: not seen yet")
        XCTAssertNil(back.apply(.waitingTabSelected(nil), now: t0.addingTimeInterval(10 + StartState.seenAfter)).state.banner)
        let covered = t1.withRoom(blocked: true, inFront: true, now: t0.addingTimeInterval(0.1)).state
        let uncovered = covered.withRoom(blocked: false, inFront: true, now: t0.addingTimeInterval(5)).state
        XCTAssertNotNil(uncovered.apply(.waitingTabSelected(nil), now: t0.addingTimeInterval(5.5)).state.banner, "a sheet's time doesn't count")
        let still = t1.withRoom(blocked: false, inFront: true, now: t0.addingTimeInterval(0.5)).state
        XCTAssertNil(still.apply(.waitingTabSelected(nil), now: t0.addingTimeInterval(StartState.seenAfter)).state.banner, "an unbroken second: seen")
    }

    /// One banner tip a launch: T4 after T1 waits for a later launch, unseen.
    func testOneBannerTipALaunch() {
        var state = raised(StartState(), .markRaised(.waiting, tab: "api")).state
        state = state.dismissingTip().state
        let after = raised(state, .agentTabStarted)
        XCTAssertNil(after.tip, "the limit")
        XCTAssertFalse(after.state.tipsSeen.contains(.agentTools), "not seen: it comes at a later launch")
        XCTAssertTrue(after.state.waiting.isEmpty)
        let nextLaunch = StartState(tipsSeen: after.state.tipsSeen).launched(.same)
        XCTAssertEqual(raised(nextLaunch, .agentTabStarted).tip, .agentTools)
    }

    /// T1 and T2 pass the limit: the first agent tab's T4 doesn't push the
    /// first lesson, nor production, to a later launch.
    func testT1AndT2PassTheLimit() {
        var state = raised(StartState(), .agentTabStarted).state
        XCTAssertEqual(state.banner, .agentTools)
        // Raised while T4 shows (it has no timer): T2 takes its place, T4
        // waits to come back; T1 waits for T2's place.
        state = raised(state, .productionPane(.kubernetes(context: "acme-prod"))).state
        XCTAssertEqual(state.banner, .production(.kubernetes(context: "acme-prod")))
        XCTAssertEqual(state.displaced, .agentTools)
        state = raised(state, .markRaised(.done, tab: "api")).state
        XCTAssertEqual(state.banner, .production(.kubernetes(context: "acme-prod")), "an exempt tip is not put back")
        var next = state.dismissingTip(now: t0)
        XCTAssertEqual(next.tip, .needsYou(tab: "api", mark: .done))
        next = next.state.dismissingTip(now: t0)
        XCTAssertEqual(next.tip, .agentTools, "T4 back: the launch's one, not counted again")
        XCTAssertNil(next.state.displaced)
        XCTAssertEqual(next.state.tipsSeen, [.agentTools, .production, .needsYou])
        next = next.state.dismissingTip(now: t0)
        XCTAssertNil(next.tip)
        XCTAssertNil(next.state.banner)
    }

    /// T1 over T4: the first mark's lesson and its notification question
    /// aren't kept behind a tip with no timer.
    func testT1TakesT4sPlace() {
        let t4 = raised(StartState(), .agentTabStarted).state
        let t1 = raised(t4, .markRaised(.waiting, tab: "api"))
        XCTAssertEqual(t1.tip, .needsYou(tab: "api", mark: .waiting))
        XCTAssertEqual(t1.state.displaced, .agentTools)
        XCTAssertNil(raised(t1.state, .agentTabStarted).state.waiting.first, "T4 raised again: not waiting twice")
        let inbox = raised(t1.state, .inboxOpened(waiting: true))
        XCTAssertEqual(inbox.state.banner, .agentTools, "T1 gone with the Inbox: T4 back")
        XCTAssertNil(t1.state.withTips(false).displaced, "Turn Off Tips takes it too")
    }

    /// `general.tips` off: no tip, ever, and one showing goes.
    func testTipsOffShowsNoTip() {
        let off = StartState(tips: false)
        for event in [StartState.Event.markRaised(.waiting, tab: "a"), .productionPane(.kubernetes(context: "p")), .agentTabStarted, .paletteOpened] {
            let after = raised(off, event)
            XCTAssertNil(after.tip, "\(event)")
            XCTAssertNil(after.state.banner)
            XCTAssertFalse(after.state.paletteTip)
        }
        let showing = raised(StartState(), .agentTabStarted).state
        XCTAssertNil(showing.withTips(false).banner, "Turn Off Tips takes the one showing")
    }

    /// A sheet, ⌘K, Tab Peek or the held banner: a tip waits; the app
    /// behind another: it waits to be where it is seen.
    func testATipWaitsWhileItsPlaceIsCovered() {
        let covered = StartState().withRoom(blocked: true, inFront: true).state
        let waiting = raised(covered, .markRaised(.waiting, tab: "api"))
        XCTAssertNil(waiting.tip)
        XCTAssertFalse(waiting.state.tipsSeen.contains(.needsYou), "not seen while it waits")
        XCTAssertEqual(waiting.state.withRoom(blocked: false, inFront: true).tip, .needsYou(tab: "api", mark: .waiting))

        let behind = raised(StartState().withRoom(blocked: false, inFront: false).state, .markRaised(.waiting, tab: "api"))
        XCTAssertNil(behind.tip)
        // Its tab selected as the app comes back — before the app is said
        // to be in front, or after it placed T1 in the same turn —: T1 is
        // not dropped unseen; it stays until ×, the Inbox or its button.
        let selected = raised(behind.state, .waitingTabSelected(nil)).state
        XCTAssertEqual(selected.waiting, [.needsYou(tab: "api", mark: .waiting)])
        XCTAssertFalse(selected.tipsSeen.contains(.needsYou))
        let back = selected.withRoom(blocked: false, inFront: true, now: t0)
        XCTAssertEqual(back.tip, .needsYou(tab: "api", mark: .waiting), "placed when the app comes to the front")
        let placedFirst = behind.state.withRoom(blocked: false, inFront: true, now: t0).state
        XCTAssertEqual(raised(placedFirst, .waitingTabSelected(nil)).state.banner, .needsYou(tab: "api", mark: .waiting), "placed and selected in one turn")
        XCTAssertNil(
            placedFirst.apply(.waitingTabSelected(nil), now: t0.addingTimeInterval(StartState.seenAfter)).state.banner,
            "on screen a moment, then its tab selected: seen, it goes")
        // A fresh first launch: the ask is held until T1 shows, and T1 does show.
        let fresh = raised(StartState().launched(.fresh).withRoom(blocked: false, inFront: false, now: t0).state, .markRaised(.waiting, tab: "api"))
        let freshSelected = raised(fresh.state, .waitingTabSelected(nil)).state
        XCTAssertTrue(freshSelected.holdsNotificationAsk, "not shown yet")
        XCTAssertFalse(freshSelected.withRoom(blocked: false, inFront: true, now: t0).state.holdsNotificationAsk, "shown on return")

        // Placed, then covered: hidden, not gone.
        let shown = raised(StartState(), .agentTabStarted).state
        let hidden = shown.withRoom(blocked: true, inFront: true).state
        XCTAssertEqual(hidden.banner, .agentTools)
        XCTAssertNil(hidden.shownBanner)
    }

    /// T3: ⌘K's first three showings, then never.
    func testT3StopsAfterThreeShowings() {
        var state = StartState()
        for showing in 1...3 {
            state = raised(state, .paletteOpened).state
            XCTAssertTrue(state.paletteTip, "showing \(showing)")
            XCTAssertEqual(state.paletteOpens, showing)
            XCTAssertNil(state.banner, "never the banner")
        }
        XCTAssertTrue(state.tipsSeen.contains(.clearMoved))
        state = raised(state, .paletteOpened).state
        XCTAssertFalse(state.paletteTip)
        XCTAssertEqual(state.paletteOpens, 3)
        XCTAssertFalse(raised(state, .changesShown).state.paletteTip)
    }

    /// Reset Tips: every tip again, T3's count from nought — the limit stays.
    func testResetTips() {
        var state = raised(StartState(), .agentTabStarted).state.dismissingTip().state
        for _ in 1...3 { state = raised(state, .paletteOpened).state }
        state = state.resettingTips()
        XCTAssertTrue(state.tipsSeen.isEmpty)
        XCTAssertEqual(state.paletteOpens, 0)
        XCTAssertTrue(raised(state, .paletteOpened).state.paletteTip)
        XCTAssertNil(raised(state, .agentTabStarted).tip, "one banner tip a launch still")
        XCTAssertNotNil(raised(state, .markRaised(.waiting, tab: "api")).tip)
    }

    /// An update counts every tip seen; the notification ask waits only on
    /// a fresh install's first launch (D-6).
    func testAnUpdateSeesEveryTipAndOnlyAFreshLaunchHoldsTheAsk() {
        let updated = StartState().launched(.upgraded(from: "1.6.8"))
        XCTAssertEqual(updated.tipsSeen, Set(StartState.Tip.allCases))
        XCTAssertNil(raised(updated, .markRaised(.waiting, tab: "api")).tip)
        XCTAssertFalse(updated.holdsNotificationAsk)

        let fresh = StartState().launched(.fresh)
        XCTAssertTrue(fresh.holdsNotificationAsk)
        XCTAssertFalse(fresh.launched(.same).holdsNotificationAsk, "the second launch asks as before, T1 seen or not")
        XCTAssertFalse(fresh.withTips(false).holdsNotificationAsk)
        XCTAssertFalse(raised(fresh, .markRaised(.waiting, tab: "api")).state.holdsNotificationAsk, "T1 seen")
    }

    /// `onboarding.tipsSeen` and `onboarding.paletteOpens` round-trip; an unknown id is passed over.
    func testTheTipsKeptFormRoundTrips() {
        let state = StartState(tipsSeen: [.agentTools, .needsYou], paletteOpens: 2)
        XCTAssertEqual(state.storedTips, ["needsYou", "agentTools"])
        let read = StartState(storedCard: nil, storedSteps: nil, tips: true, storedTips: state.storedTips + ["sixth"], paletteOpens: 2)
        XCTAssertEqual(read.tipsSeen, [.agentTools, .needsYou])
        XCTAssertEqual(read.paletteOpens, 2)
        XCTAssertEqual(StartState(storedCard: nil, storedSteps: nil, tips: true, paletteOpens: 9).paletteOpens, 3)
    }
}
