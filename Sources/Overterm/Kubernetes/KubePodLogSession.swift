import Combine
import Foundation

/// A pod's container's log as a follower reads it (`LogFollower`): one GET
/// of `pods/{p}/log`, followed, with timestamps — its last lines (`tail`,
/// `since`), or, resumed, from the last line's second (`sinceTime`). A
/// stream that ends — the server's timeout, a dropped connection, the
/// proxy restarting — is followed again while the container runs, and not
/// once the pod is gone or the container ended for good (`ended` says
/// why). Previous (the last terminated instance) is read whole, once.
/// Only reads: every request is a GET.
@MainActor
final class KubePodLogSource: LogSource {
    let namespace: String
    let pod: String
    let container: String?
    let previous: Bool
    let since: KubeLogSince
    private let client: KubeClient
    /// The stream's failure, set before its consumer hears of it.
    private let failure = Failure()
    /// How long until the pod is asked again, while the container waits —
    /// the first wait, after a steady stream.
    var retryDelay: Duration = .milliseconds(300)
    var maxRetryDelay: Duration = .seconds(5)
    /// A stream open this long was a steady one: the wait after it starts
    /// at `retryDelay` again. One that ends sooner — a server or proxy that
    /// closes every follow as it opens, while the pod reads Running — waits
    /// longer each time, up to `maxRetryDelay`: no storm of GETs. Lines it
    /// brought don't count (a resume brings its second's lines again).
    var steadyAfter: Duration = .seconds(5)
    /// The next wait, across streams: grown by each that ended quickly.
    private var backoff: Duration?
    /// When the stream now open was opened.
    private var opened: ContinuousClock.Instant?
    /// The pod as each read after a stream ended found it: its
    /// containers' states and restarts, for the tab's picker and Previous.
    var onPod: ([String: Any]) -> Void = { _ in }
    /// Followed again this many times: a stream dropped and resumed.
    private(set) var resumes = 0
    /// Why it isn't followed now (waiting for the container), or ended.
    var onState: (KubePodLogSession.Reading) -> Void = { _ in }

    init(client: KubeClient, namespace: String, pod: String, container: String?, previous: Bool, since: KubeLogSince) {
        self.client = client
        self.namespace = namespace
        self.pod = pod
        self.container = container
        self.previous = previous
        self.since = since
    }

    /// The query for the first stream (`after` nil) or a resumed one. A
    /// resumed one is capped at what the feed keeps: a tab hidden for an
    /// hour on a noisy pod would otherwise be sent every line since — the
    /// newest `LogFeed.keep` of them replace the feed whole, so no gap shows.
    nonisolated static func query(container: String?, previous: Bool, since: KubeLogSince, tail: Int, after: String?) -> KubeLogQuery {
        var query = KubeLogQuery(container: container, previous: previous, follow: !previous)
        if let after, !previous {
            query.sinceTime = KubeLogQuery.sinceTime(after: after)
            query.tailLines = LogFeed.keep
        } else {
            query.tailLines = tail
            query.since = since
        }
        return query
    }

    func follow(tail: Int, after: String?) async -> AsyncThrowingStream<[LogLine], any Error>? {
        guard !Task.isCancelled else { return nil }
        failure.set(nil)
        onState(.following)
        let query = Self.query(container: container, previous: previous, since: since, tail: tail, after: after)
        opened = .now
        return Self.recorded(client.logs(namespace: namespace, pod: pod, query: query), into: failure)
    }

    /// The stream, its failure kept where `followsAgain` reads it first.
    nonisolated private static func recorded(
        _ stream: AsyncThrowingStream<[LogLine], Error>, into failure: Failure
    ) -> AsyncThrowingStream<[LogLine], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await lines in stream { continuation.yield(lines) }
                    continuation.finish()
                } catch {
                    failure.set(error)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// The stream ended: followed again while the container runs — asked
    /// of the pod, waiting while it waits (a restart's back-off) — and not
    /// once the pod is gone, the container ended for good, or the server
    /// refused the log; Previous's log, read whole, isn't followed.
    func followsAgain() async -> Bool {
        if previous {
            if let error = failure.value { onState(.ended(KubernetesModel.said(error))) } else { onState(.ended(nil)) }
            return false
        }
        switch Self.after(failure.value) {
        case .stop(let reason):
            onState(.ended(reason))
            return false
        case .wait(let reason):
            onState(.waiting(reason))
        case .follow:
            onState(.resuming)
        }
        let steady = opened.map { ContinuousClock.now - $0 >= steadyAfter } ?? false
        opened = nil
        var delay = steady ? retryDelay : (backoff ?? retryDelay)
        while !Task.isCancelled {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return false }
            delay = min(delay * 2, maxRetryDelay)
            backoff = delay
            let read: [String: Any]?
            do {
                read = try await client.object(.pods, namespace: namespace, name: pod).json
            } catch let error as KubeAPIError where error.isNotFound {
                read = nil
            } catch let problem as KubeProxyProblem where problem.stopsRequests {
                onState(.ended(problem.reason))
                return false
            } catch let error as KubeAPIError where error.isForbidden {
                onState(.ended(KubernetesModel.said(error)))
                return false
            } catch {
                // A blip, the proxy restarting: the pod is asked again.
                onState(.waiting("Reconnecting: \(KubernetesModel.said(error))"))
                continue
            }
            guard !Task.isCancelled else { return false }
            if let read { onPod(read) }
            switch KubeLogResume.of(pod: read, container: container ?? read.flatMap(KubePodContainers.defaultContainer) ?? "") {
            case .follow:
                resumes += 1
                return true
            case .wait(let reason):
                onState(.waiting(reason))
            case .stop(let reason):
                onState(.ended(reason))
                return false
            }
        }
        return false
    }

    /// What a stream's failure means: the server's refusal (a container
    /// it has no log of, a 403) ends it — but "waiting to start", which
    /// passes; a pod not found is gone; a credential failure stops; the
    /// rest (a dropped connection, a 5xx) is asked again.
    static func after(_ error: Error?) -> KubeLogResume {
        switch error {
        case nil: return .follow
        case let error as KubeAPIError where error.isNotFound: return .stop(KubeLogResume.podGone)
        case let error as KubeAPIError where error.status == 400 && error.message.contains("waiting to start"):
            return .wait("Waiting for the container to start…")
        case let error as KubeAPIError where error.status == 400 || error.isForbidden: return .stop(KubernetesModel.said(error))
        case let problem as KubeProxyProblem where problem.stopsRequests: return .stop(problem.reason)
        default: return .follow
        }
    }

    /// A stream's failure, across the task that reads it and the follower.
    private final class Failure: @unchecked Sendable {
        private let lock = NSLock()
        private var error: Error?
        func set(_ error: Error?) { lock.withLock { self.error = error } }
        var value: Error? { lock.withLock { error } }
    }
}

/// A pod's Logs tab, while its detail shows it: which container (the
/// default one, else picked — init and ephemeral ones too), Previous (the
/// last terminated instance, offered once it restarted), how far back
/// (`since`), the lines followed into a `LogFeed`, older ones asked for
/// again with a larger tail (the API has no offset) up to the feed's cap.
/// It reads only while the tab shows (`show`/`hide`), and the stream
/// closes with the detail, the page hidden or another context.
@MainActor
final class KubePodLogSession: ObservableObject {
    /// How it reads now.
    enum Reading: Equatable {
        case idle
        case following
        /// The stream ended and the container runs: followed again.
        case resuming
        case waiting(String)
        /// Not followed any more, and why (nil: Previous's whole log read).
        case ended(String?)
    }

    let namespace: String
    let pod: String
    let feed = LogFeed()
    @Published private(set) var containers: [KubeLogContainer] = []
    @Published private(set) var container: String?
    @Published private(set) var previous = false
    @Published private(set) var since: KubeLogSince = .all
    @Published private(set) var reading: Reading = .idle
    @Published private(set) var loadingOlder = false
    /// An older answer had fewer lines than asked: the log starts there.
    @Published private(set) var reachedStart = false
    /// What a read of older lines couldn't do.
    @Published private(set) var olderProblem: String?
    /// The pod's own env, for scrubbing what an agent is given.
    private(set) var env: [(key: String, value: String)] = []

    private let client: KubeClient?
    private var follower: LogFollower?
    private(set) var source: KubePodLogSource?
    private var wanted = false
    private var olderTask: Task<Void, Never>?
    /// The tail asked for: the first one, then larger for older lines.
    private(set) var tail = KubePodLogSession.firstTail

    nonisolated static let firstTail = 500
    /// The most asked for at once: what the feed keeps.
    nonisolated static let maxTail = LogFeed.keep

    init(namespace: String, pod: String, client: KubeClient?) {
        self.namespace = namespace
        self.pod = pod
        self.client = client
    }

    /// The pod read (its detail's one GET): its containers, the default one picked.
    func podRead(_ object: [String: Any]) {
        containers = KubePodContainers.of(object)
        env = KubeLogScrub.env(of: object)
        if container == nil || !containers.contains(where: { $0.name == container }) {
            container = KubePodContainers.defaultContainer(object)
        }
        if wanted && follower == nil { start() }
    }

    /// The pod read again after a stream ended (it crashed, it restarted):
    /// its containers' states and restarts — Previous offered once it
    /// restarted — the container picked kept.
    func podChanged(_ object: [String: Any]) {
        let read = KubePodContainers.of(object)
        if read != containers { containers = read }
        env = KubeLogScrub.env(of: object)
    }

    /// The pod couldn't be read: neither can its log be.
    func podFailed(_ reason: String) {
        reading = .ended(reason)
    }

    /// The container shown.
    var shown: KubeLogContainer? { containers.first { $0.name == container } }

    /// The tab shows: followed (from where it was, if it was).
    func show(since: KubeLogSince) {
        let was = wanted
        wanted = true
        if since != self.since {
            self.since = since
            if follower != nil { return restart() }
        }
        guard !was, container != nil else { return }
        // Shown again, it is read again from its last line.
        if follower == nil { start() } else if follower?.following == false { follower?.start(tail: tail) }
    }

    /// The tab is gone, the page hidden: the stream closes.
    func hide() {
        wanted = false
        follower?.stop()
        olderTask?.cancel()
        olderTask = nil
        loadingOlder = false
        if case .ended = reading {} else { reading = .idle }
    }

    /// Another container, Previous on or off: its log from the start.
    func pick(container: String? = nil, previous: Bool? = nil) {
        let name = container ?? self.container
        // Previous only where there was one: another container's current log.
        let previous = (previous ?? (name == self.container ? self.previous : false)) && (containers.first { $0.name == name }?.hasPrevious ?? false)
        guard name != self.container || previous != self.previous else { return }
        self.container = name
        self.previous = previous
        restart()
    }

    private func restart() {
        follower?.stop()
        follower = nil
        source = nil
        olderTask?.cancel()
        olderTask = nil
        loadingOlder = false
        reachedStart = false
        olderProblem = nil
        tail = Self.firstTail
        feed.clear()
        reading = .idle
        if wanted { start() }
    }

    private func start() {
        guard let client, follower == nil, container != nil else {
            if client == nil { reading = .ended("Kubernetes is off, or the context is gone.") }
            return
        }
        let source = KubePodLogSource(client: client, namespace: namespace, pod: pod, container: container, previous: previous, since: since)
        source.onState = { [weak self] state in self?.reading = state }
        source.onPod = { [weak self] pod in self?.podChanged(pod) }
        let follower = LogFollower(source: source, feed: feed, merging: false)
        follower.onChange = { [weak self, weak follower] in self?.feed.following = follower?.following ?? false }
        self.source = source
        self.follower = follower
        follower.start(tail: tail)
    }

    /// Scrolled to the oldest line: the log asked for again with twice the
    /// tail (up to `maxTail`), and what it has before the first line shown
    /// put in front.
    func loadOlder() {
        guard let client, let container, !loadingOlder, !reachedStart, tail < Self.maxTail, feed.lines.count < LogFeed.keep else { return }
        let wanted = min(max(tail, feed.lines.count) * 2, Self.maxTail)
        loadingOlder = true
        olderProblem = nil
        let query = KubeLogQuery(container: container, previous: previous, tailLines: wanted, since: since)
        let (namespace, pod) = (self.namespace, self.pod)
        olderTask = Task { [weak self] in
            do {
                let fetched = try await client.logLines(namespace: namespace, pod: pod, query: query)
                guard let self, !Task.isCancelled else { return }
                self.tail = wanted
                self.feed.prepend(KubeLogText.older(fetched, than: self.feed.lines))
                self.reachedStart = fetched.count < wanted
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.olderProblem = KubernetesModel.said(error)
            }
            self?.loadingOlder = false
        }
    }

    /// What Save As suggests.
    var fileName: String { KubeLogText.fileName(pod: pod, container: container, previous: previous) }

    /// Lines picked out of it, for an agent: scrubbed.
    func scrubbed(_ text: String) -> String { KubeLogScrub.scrub(text, env: env) }

    /// The detail closed or moved on: nothing more is read.
    func cancel() {
        hide()
        follower = nil
        source = nil
    }
}
