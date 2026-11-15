import AppKit
import XCTest

@testable import Overterm

/// The log's text view keeps to its newest lines however late it is laid
/// out: a pod's or a container's Logs tab is made with its first 500 lines
/// at once, before the window has given it a size — and on a loaded
/// machine after any one turn of the main queue. It landed in the middle
/// of the log (testKubernetes, "its end in view", in a batch run).
@MainActor
final class LogTextViewTests: XCTestCase {
    private func lines(_ count: Int) -> [NSAttributedString] {
        (1...count).map { NSAttributedString(string: "2026-11-05T10:00:00Z GET /health \($0) 200 from 10.0.0.\($0 % 250) in 3ms, upstream web-7d9") }
    }

    private func view(_ all: [NSAttributedString], newestFirst: Bool = false, onOldest: (() -> Void)? = nil) -> LogTextView {
        LogTextView(
            count: all.count, revision: 1, render: { Array(all[$0]) }, wrap: true, follow: true, newestFirst: newestFirst, onOldest: onOldest)
    }

    private func move(_ scroll: NSScrollView, toY y: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// A trackpad's gesture, or a scroller dragged: what AppKit posts around it.
    private func live(_ scroll: NSScrollView, _ body: () -> Void) {
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        body()
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    }

    /// A few turns of the main queue, as the window's layout comes in between.
    private func turn() {
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func atEnd(_ scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView else { return false }
        return scroll.contentView.bounds.maxY >= document.frame.height - 24
    }

    private func laidOut(_ scroll: NSScrollView, _ size: NSSize) {
        scroll.frame = NSRect(origin: .zero, size: size)
        scroll.tile()
        scroll.layoutSubtreeIfNeeded()
        if let text = scroll.documentView as? NSTextView, let container = text.textContainer {
            text.layoutManager?.ensureLayout(for: container)
        }
    }

    func testTheFirstBatchShowsItsEndWhenLaidOutLate() {
        let scroll = LogTextView.makeScroll(identifier: "log.text")
        let coordinator = LogTextView.Coordinator()
        var all = lines(500)
        // Drawn before the view has a size; the one hop of the queue goes by.
        coordinator.update(scroll, view(all))
        turn()
        laidOut(scroll, NSSize(width: 900, height: 300))
        turn()
        XCTAssertTrue(atEnd(scroll), "\(scroll.contentView.bounds) of \(scroll.documentView?.frame ?? .zero)")
        // Laid out again, narrower: the wrapped lines make it taller.
        laidOut(scroll, NSSize(width: 320, height: 260))
        turn()
        XCTAssertTrue(atEnd(scroll), "\(scroll.contentView.bounds) of \(scroll.documentView?.frame ?? .zero)")
        // And followed as lines come.
        all += lines(40)
        coordinator.update(scroll, view(all))
        turn()
        XCTAssertTrue(atEnd(scroll))
        XCTAssertTrue(coordinator.pinned)
    }

    func testAScrollUpLetsGoAndTheEndFollowsAgain() {
        let scroll = LogTextView.makeScroll(identifier: "log.text")
        let coordinator = LogTextView.Coordinator()
        laidOut(scroll, NSSize(width: 600, height: 300))
        var all = lines(500)
        coordinator.update(scroll, view(all))
        turn()
        XCTAssertTrue(atEnd(scroll))
        // Moved by the layout or by code, not a person: back to the end.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
        scroll.reflectScrolledClipView(scroll.contentView)
        turn()
        XCTAssertTrue(atEnd(scroll))
        XCTAssertTrue(coordinator.pinned)
        // A person reads further up: new lines and a new size leave it there.
        coordinator.byPerson {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        XCTAssertFalse(coordinator.pinned)
        all += lines(20)
        coordinator.update(scroll, view(all))
        laidOut(scroll, NSSize(width: 600, height: 280))
        turn()
        // Where it was, give or take what the layout measured again.
        XCTAssertFalse(atEnd(scroll))
        XCTAssertEqual(scroll.contentView.bounds.minY, 400, accuracy: 150)
        // Back at the end: followed again.
        coordinator.byPerson { (scroll.documentView as? NSTextView)?.scrollToEndOfDocument(nil) }
        XCTAssertTrue(coordinator.pinned)
        all += lines(20)
        coordinator.update(scroll, view(all))
        turn()
        XCTAssertTrue(atEnd(scroll))
    }

    func testNewestFirstKeepsToTheTopWhenLaidOutLate() {
        let scroll = LogTextView.makeScroll(identifier: "log.text")
        let coordinator = LogTextView.Coordinator()
        var all = lines(500)
        coordinator.update(scroll, view(all, newestFirst: true))
        turn()
        laidOut(scroll, NSSize(width: 320, height: 260))
        turn()
        XCTAssertLessThanOrEqual(scroll.contentView.bounds.minY, 24)
        // Moved by the layout or by code: back to the top, lines coming or not.
        move(scroll, toY: 400)
        turn()
        XCTAssertLessThanOrEqual(scroll.contentView.bounds.minY, 24)
        move(scroll, toY: 400)
        all += lines(30)
        coordinator.update(scroll, view(all, newestFirst: true))
        turn()
        XCTAssertLessThanOrEqual(scroll.contentView.bounds.minY, 24)
        all += lines(30)
        coordinator.update(scroll, view(all, newestFirst: true))
        laidOut(scroll, NSSize(width: 700, height: 300))
        turn()
        XCTAssertLessThanOrEqual(scroll.contentView.bounds.minY, 24)
    }

    /// Lines that come while a person's live scroll goes on (a trackpad's
    /// gesture or its momentum, a scroller dragged) don't pull the view back
    /// to the end; where the scroll ends says whether it follows.
    func testLinesDuringALiveScrollLeaveItWhereThePersonTookIt() {
        let scroll = LogTextView.makeScroll(identifier: "log.text")
        let coordinator = LogTextView.Coordinator()
        laidOut(scroll, NSSize(width: 600, height: 300))
        var all = lines(450)
        coordinator.update(scroll, view(all))
        turn()
        XCTAssertTrue(atEnd(scroll))
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        move(scroll, toY: 400)
        all += lines(10)
        coordinator.update(scroll, view(all))
        turn()
        XCTAssertEqual(scroll.contentView.bounds.minY, 400, accuracy: 150, "pulled back during the gesture")
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        XCTAssertFalse(coordinator.pinned)
        all += lines(10)
        coordinator.update(scroll, view(all))
        turn()
        XCTAssertEqual(scroll.contentView.bounds.minY, 400, accuracy: 150)
        // Back to the end by a live scroll: followed again.
        live(scroll) { (scroll.documentView as? NSTextView)?.scrollToEndOfDocument(nil) }
        XCTAssertTrue(coordinator.pinned)
    }

    /// A legacy mouse's wheel: no start or end, only `didLiveScroll`, posted
    /// after the clip moved. It lets go as a trackpad does.
    func testALegacyWheelLetsGo() {
        let scroll = LogTextView.makeScroll(identifier: "log.text")
        let coordinator = LogTextView.Coordinator()
        laidOut(scroll, NSSize(width: 600, height: 300))
        var all = lines(450)
        coordinator.update(scroll, view(all))
        turn()
        move(scroll, toY: 400)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        turn()
        XCTAssertFalse(coordinator.pinned)
        XCTAssertEqual(scroll.contentView.bounds.minY, 400, accuracy: 150)
        all += lines(10)
        coordinator.update(scroll, view(all))
        turn()
        XCTAssertFalse(atEnd(scroll))
    }

    /// Older lines are asked for when a person scrolls to the oldest edge —
    /// not when the layout or code moves a followed view there for a moment.
    func testOnlyAPersonsScrollToTheTopAsksForOlderLines() {
        let scroll = LogTextView.makeScroll(identifier: "log.text")
        let coordinator = LogTextView.Coordinator()
        var asked = 0
        let all = lines(450)
        // Laid out late, as a new Logs tab is.
        coordinator.update(scroll, view(all, onOldest: { asked += 1 }))
        turn()
        laidOut(scroll, NSSize(width: 600, height: 300))
        turn()
        XCTAssertEqual(asked, 0)
        move(scroll, toY: 0)
        turn()
        XCTAssertTrue(atEnd(scroll))
        XCTAssertEqual(asked, 0, "asked for older lines nobody scrolled to")
        live(scroll) { move(scroll, toY: 0) }
        turn()
        XCTAssertEqual(asked, 1)
        XCTAssertFalse(coordinator.pinned)
        XCTAssertLessThanOrEqual(scroll.contentView.bounds.minY, 4)
    }
}
