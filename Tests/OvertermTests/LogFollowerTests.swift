import XCTest

@testable import Overterm

/// The follower over any source (Docker's, a pod's): what it asks for,
/// what it keeps once, and when it follows again.
@MainActor
final class LogFollowerTests: XCTestCase {
    /// Each `follow` hands out the next batch list as a stream that ends;
    /// `again` says how many ends are followed again. `holding`, `follow`
    /// waits for `release()`; `staysOpen`, the stream is left open after
    /// its batches and `more` yields into it.
    private final class FakeSource: LogSource {
        var batches: [[[LogLine]]]
        var again: Int
        var asked: [(tail: Int, after: String?)] = []
        var askedAgain = 0
        var holding = false
        var staysOpen = false
        private var held: CheckedContinuation<Void, Never>?
        private var open: AsyncThrowingStream<[LogLine], any Error>.Continuation?
        /// Streams terminated — finished, or cancelled by their reader.
        let ended = Counter()

        init(_ batches: [[[LogLine]]], again: Int) {
            self.batches = batches
            self.again = again
        }

        func follow(tail: Int, after: String?) async -> AsyncThrowingStream<[LogLine], any Error>? {
            asked.append((tail, after))
            if holding { await withCheckedContinuation { held = $0 } }
            guard !batches.isEmpty else { return nil }
            let next = batches.removeFirst()
            let ended = ended
            var made: AsyncThrowingStream<[LogLine], any Error>.Continuation?
            let stream = AsyncThrowingStream<[LogLine], any Error> { made = $0 }
            guard let continuation = made else { return nil }
            continuation.onTermination = { @Sendable _ in ended.add() }
            next.forEach { continuation.yield($0) }
            if staysOpen { open = continuation } else { continuation.finish() }
            return stream
        }

        func followsAgain() async -> Bool {
            askedAgain += 1
            guard again > 0 else { return false }
            again -= 1
            return true
        }

        var isHeld: Bool { held != nil }

        func release() {
            held?.resume()
            held = nil
        }

        /// Lines into the open stream: dropped once it was terminated.
        func more(_ lines: [LogLine]) { open?.yield(lines) }
    }

    /// Counted from a stream's `onTermination`, on whatever thread it runs.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private func line(_ second: String, _ message: String, by source: String? = nil) -> LogLine {
        LogLine(stream: .stdout, timestamp: "2026-10-27T10:00:\(second)Z", level: nil, message: message, fields: [], source: source)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// Followed again from the newest line's time: what that second said
    /// again is dropped, nothing shows twice.
    func testFollowedAgainFromWhereItStopped() async {
        let source = FakeSource(
            [
                [[line("01", "one"), line("02", "two")]],
                [[line("02", "two"), line("03", "three")]],
            ], again: 1)
        let feed = LogFeed()
        let follower = LogFollower(source: source, feed: feed, merging: false)
        follower.start(tail: 50)
        let done = await eventually { feed.lines.count == 3 && source.asked.count == 2 }
        XCTAssertTrue(done, "\(feed.lines.map(\.message))")
        XCTAssertEqual(feed.lines.map(\.message), ["one", "two", "three"])
        XCTAssertEqual(source.asked.first?.after, nil, "first its last lines")
        XCTAssertEqual(source.asked.first?.tail, 50)
        XCTAssertEqual(source.asked.last?.after, "2026-10-27T10:00:02Z", "then from the newest line's time")
        let stopped = await eventually { !follower.following }
        XCTAssertTrue(stopped, "ended, and not followed again: stopped")
    }

    /// Followed again from a time: a line of that time already shown is
    /// dropped, one of the same time saying something else is kept, and
    /// past that time nothing is dropped — not even a line said again.
    func testFollowedAgainKeepsALineOfTheSameTimeNotShown() async {
        let source = FakeSource(
            [
                [[line("01", "one"), line("02", "two")]],
                [[line("01", "one"), line("02", "two"), line("02", "two, again"), line("03", "three"), line("03", "three")]],
            ], again: 1)
        let feed = LogFeed()
        let follower = LogFollower(source: source, feed: feed, merging: false)
        follower.start(tail: 50)
        let done = await eventually { feed.lines.count == 5 && source.asked.count == 2 }
        XCTAssertTrue(done, "\(feed.lines.map(\.message))")
        XCTAssertEqual(feed.lines.map(\.message), ["one", "two", "two, again", "three", "three"])
    }

    /// Two followers into one feed, merged by time with each other.
    func testMergingFollowersInterleaveByTime() async {
        let feed = LogFeed()
        let web = LogFollower(source: FakeSource([[[line("01", "web1", by: "web"), line("04", "web4", by: "web")]]], again: 0), feed: feed, merging: true)
        let db = LogFollower(source: FakeSource([[[line("02", "db2", by: "db"), line("03", "db3", by: "db")]]], again: 0), feed: feed, merging: true)
        web.start(tail: 10)
        let first = await eventually { feed.lines.count == 2 }
        XCTAssertTrue(first)
        db.start(tail: 10)
        let all = await eventually { feed.lines.count == 4 }
        XCTAssertTrue(all)
        XCTAssertEqual(feed.lines.map(\.message), ["web1", "db2", "db3", "web4"])
    }

    /// Stopped while following: says so at once, its stream is
    /// terminated (a container's connection closes with it), and what the
    /// source still has never goes in — nor is it followed again.
    func testStoppedWhileFollowingEndsItsStream() async {
        let source = FakeSource([[[line("01", "one")]]], again: 1)
        source.staysOpen = true
        let feed = LogFeed()
        var changes = 0
        let follower = LogFollower(source: source, feed: feed, merging: false)
        follower.onChange = { changes += 1 }
        follower.start(tail: 10)
        let following = await eventually { follower.following && feed.lines.count == 1 }
        XCTAssertTrue(following)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(source.ended.value, 0, "open while followed")
        follower.stop()
        XCTAssertFalse(follower.following)
        XCTAssertEqual(changes, 2)
        let ended = await eventually { source.ended.value == 1 }
        XCTAssertTrue(ended, "its stream terminated")
        source.more([line("02", "two")])
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(feed.lines.map(\.message), ["one"])
        XCTAssertFalse(follower.following)
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(source.askedAgain, 0, "a stopped log isn't followed again")
        XCTAssertEqual(source.asked.count, 1)
    }

    /// Stopped while its stream was being opened: the stream it gets,
    /// lines already in it, is terminated unread; it never says it follows.
    func testStoppedWhileOpeningReadsNothing() async {
        let source = FakeSource([[[line("01", "one"), line("02", "two")]]], again: 1)
        source.holding = true
        source.staysOpen = true
        let feed = LogFeed()
        var changes = 0
        let follower = LogFollower(source: source, feed: feed, merging: false)
        follower.onChange = { changes += 1 }
        follower.start(tail: 10)
        let opening = await eventually { source.isHeld }
        XCTAssertTrue(opening)
        follower.stop()
        XCTAssertFalse(follower.following)
        XCTAssertEqual(changes, 1)
        source.release()
        let ended = await eventually { source.ended.value == 1 }
        XCTAssertTrue(ended, "the stream opened after all is terminated")
        source.more([line("03", "three")])
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(feed.lines.isEmpty, "\(feed.lines.map(\.message))")
        XCTAssertFalse(follower.following)
        XCTAssertEqual(changes, 1, "never said it follows")
        XCTAssertEqual(source.askedAgain, 0)
    }
}
