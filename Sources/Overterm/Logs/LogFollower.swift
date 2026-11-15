import Foundation

/// Where a follower's lines come from — a container's log through the
/// engine (`DockerLogSource`), a pod's. Only reads: it opens the stream,
/// and says whether one that ended is worth opening again.
@MainActor
protocol LogSource: AnyObject {
    /// The log followed: its last `tail` lines then what comes, or — given
    /// `after`, the newest line's timestamp already in the feed — what was
    /// written from then on. A line or two already shown may come again
    /// (the follower drops them). The lines are parsed off the main actor:
    /// a source writing thousands of lines a second made the window and the
    /// terminal stutter. Nil: nothing to follow now (no engine; cancelled
    /// while it asked).
    func follow(tail: Int, after: String?) async -> AsyncThrowingStream<[LogLine], any Error>?

    /// Asked when a stream ended by itself: whether to follow it again —
    /// a container restarted, whose start came before its old stream's end.
    func followsAgain() async -> Bool
}

/// One source's log followed into a feed: the last lines, then what comes;
/// followed again after a restart from where it stopped, nothing twice. A
/// container's session has one; a compose project's, one a service.
@MainActor
final class LogFollower {
    let source: any LogSource
    private let feed: LogFeed
    /// Merged by time with other followers' lines in the same feed, rather
    /// than added at the end.
    private let merging: Bool
    private var task: Task<Void, Never>?
    private(set) var following = false
    /// The newest line's time, so a log followed again starts after it.
    private var lastStamp: String?
    /// The lines in at `lastStamp`: followed again from that time, a line
    /// of that same time is one already shown only if it says the same —
    /// two lines can share a time, and the second may have come after the
    /// stream dropped.
    private var atLastStamp: [LogLine] = []
    /// Followed again from a time: until a line past it comes, what comes
    /// may be lines already shown (the source asks from that second).
    private var resuming: (stamp: String, shown: [LogLine])?
    var onChange: () -> Void = {}

    init(source: any LogSource, feed: LogFeed, merging: Bool) {
        self.source = source
        self.feed = feed
        self.merging = merging
    }

    func start(tail: Int) {
        task?.cancel()
        let after = lastStamp
        resuming = lastStamp.map { (LogFeed.sortable($0), atLastStamp) }
        task = Task { [weak self, source] in
            guard let stream = await source.follow(tail: tail, after: after) else { return }
            // Stopped while it was opened: the loop below ends at once,
            // and closes it.
            if !Task.isCancelled { self?.set(following: true) }
            do {
                for try await lines in stream {
                    // Stopped: a cancelled stream still hands out what it
                    // had buffered — none of it goes in.
                    guard let self, !Task.isCancelled else { return }
                    let added = self.unseen(lines)
                    guard !added.isEmpty else { continue }
                    self.noteNewest(added)
                    if self.merging { self.feed.merge(added) } else { self.feed.append(added) }
                }
            } catch {}
            guard !Task.isCancelled else { return }
            self?.set(following: false)
            guard await source.followsAgain(), !Task.isCancelled else { return }
            self?.start(tail: tail)
        }
    }

    /// What of `lines` isn't in the feed already: followed again from a
    /// time, the lines before it, and those of that time it showed (the
    /// same time and text, once each). Past that time, all of them.
    private func unseen(_ lines: [LogLine]) -> [LogLine] {
        guard var resume = resuming else { return lines }
        var added: [LogLine] = []
        for line in lines {
            let stamp = LogFeed.sortable(line.timestamp ?? "")
            if resuming != nil {
                if stamp < resume.stamp { continue }
                if stamp == resume.stamp {
                    if let shown = resume.shown.firstIndex(of: line) {
                        resume.shown.remove(at: shown)
                        continue
                    }
                } else {
                    resuming = nil
                }
            }
            added.append(line)
        }
        if resuming != nil { resuming = resume }
        return added
    }

    /// The newest time in, and the lines in at it.
    private func noteNewest(_ added: [LogLine]) {
        guard let newest = added.last?.timestamp else { return }
        let stamp = LogFeed.sortable(newest)
        let same = added.filter { LogFeed.sortable($0.timestamp ?? "") == stamp }
        atLastStamp = lastStamp.map(LogFeed.sortable) == stamp ? atLastStamp + same : same
        lastStamp = newest
    }

    func stop() {
        task?.cancel()
        task = nil
        set(following: false)
    }

    private func set(following: Bool) {
        self.following = following
        onChange()
    }
}
