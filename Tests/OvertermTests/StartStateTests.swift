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
            (.inboxOpened(waiting: true), .answered), (.inboxOpened(waiting: false), nil), (.waitingTabSelected, .answered),
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
        let events: [StartState.Event] = [.changesShown, .waitingTabSelected, .taskCreated, .agentTabStarted, .inRepository]
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
}
