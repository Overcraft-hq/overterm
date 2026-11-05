import Combine
import Foundation

/// One container's stream in a merged log: a pod's log source
/// (`KubePodLogSource` — followed, resumed from `sinceTime`, stopped once
/// the pod is gone), its lines tagged with whose they are and put through
/// the filter's line parts off the main actor. Only reads.
@MainActor
final class KubeMergedLogSource: LogSource {
    let key: KubeLogStreamKey
    let inner: KubePodLogSource
    let filter: KubeMergedLogFilter

    init(key: KubeLogStreamKey, inner: KubePodLogSource, filter: KubeMergedLogFilter) {
        self.key = key
        self.inner = inner
        self.filter = filter
    }

    func follow(tail: Int, after: String?) async -> AsyncThrowingStream<[LogLine], any Error>? {
        guard let stream = await inner.follow(tail: tail, after: after) else { return nil }
        return Self.tagged(stream, source: key.description, filter: filter)
    }

    func followsAgain() async -> Bool { await inner.followsAgain() }

    /// Each line's `source` set, the lines the filter leaves out dropped —
    /// the follower sees only what the feed gets, so a resume's duplicates
    /// are told by the same lines.
    nonisolated static func tagged(
        _ stream: AsyncThrowingStream<[LogLine], any Error>, source: String, filter: KubeMergedLogFilter
    ) -> AsyncThrowingStream<[LogLine], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let matcher = filter.lineMatcher()
                do {
                    for try await lines in stream {
                        var kept: [LogLine] = []
                        kept.reserveCapacity(lines.count)
                        for var line in lines where matcher.keeps(line) {
                            line.source = source
                            kept.append(line)
                        }
                        if !kept.isEmpty { continuation.yield(kept) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

/// A workload's logs as one (stage 2e, stern's way): the pods its label
/// selector picks, watched while the tab shows — a pod joining gets its
/// streams, one gone has them closed — each container's log followed
/// into one `LogFeed`, merged by time, each line prefixed and coloured
/// by its pod and container. At most `cap` streams at once
/// (`kubernetes.logStreams`), said in the tab. Include and exclude
/// regular expressions over pods, containers and lines
/// (`KubeMergedLogFilter`). Followed again from the last line's time,
/// nothing twice (`LogFollower`). It reads only while the tab shows
/// (`show`/`hide`) — the watch and every stream closed otherwise — and
/// only with GETs.
@MainActor
final class KubeMergedLogSession: ObservableObject {
    struct Stream: Equatable, Identifiable {
        var key: KubeLogStreamKey
        var reading: KubePodLogSession.Reading

        var id: String { key.description }
    }

    let context: String
    let namespace: String
    let selector: String
    /// What it is the logs of: `deployment/web`.
    let title: String
    let feed = LogFeed()
    /// The pods the selector picks now, by name.
    @Published private(set) var pods: [String] = []
    /// The streams followed, in the pods' order, and how each reads.
    @Published private(set) var streams: [Stream] = []
    /// How many streams the selector and the filter pick, and how many of
    /// them the cap leaves out.
    @Published private(set) var total = 0
    @Published private(set) var capped = 0
    /// The cap the last plan was made with.
    @Published private(set) var cap: Int
    @Published private(set) var filter = KubeMergedLogFilter()
    @Published private(set) var since: KubeLogSince = .all
    /// What the pod watch couldn't do.
    @Published private(set) var problem: String?
    /// What reading a pod couldn't do, by pod: said beside the summary,
    /// cleared once the pod is read or gone.
    @Published private(set) var podProblems: [String: String] = [:]
    /// Streams that ended for good while their pod stays (a Job's
    /// Completed pod, an Evicted one): closed, their slot given to one
    /// left out, their lines kept and still picked out in the pane.
    @Published private(set) var ended: [KubeLogStreamKey] = []
    /// The pod watch is open and has listed them: streams start only then,
    /// so a re-show never reads pods deleted while it was hidden.
    @Published private(set) var watching = false
    /// One stream's lines shown (the pane's picker); nil, all of them.
    @Published var picked: String?

    /// The first wait of each stream's resume (tests make it short).
    var retryDelay: Duration = .milliseconds(300)
    nonisolated static let firstTail = 200

    private let client: KubeClient?
    private let capSetting: () -> Int
    private var present: Set<String> = []
    private var containers: [String: [String]] = [:]
    private var envs: [String: [(key: String, value: String)]] = [:]
    /// The env of pods gone whose lines may still be in the feed: what an
    /// agent is given of those lines is scrubbed of it too. Dropped once
    /// none of that pod's lines are left (the feed cleared, or trimmed).
    private var retiredEnvs: [String: [(key: String, value: String)]] = [:]
    /// Pods that couldn't be read: no streams until the watch says they changed.
    private var unreadable: Set<String> = []
    private var fetches: [String: Task<Void, Never>] = [:]
    private var followers: [KubeLogStreamKey: LogFollower] = [:]
    private var readings: [KubeLogStreamKey: KubePodLogSession.Reading] = [:]
    /// Followers stopped by `hide`: started again from their last line once
    /// the watch has listed the pods again.
    private var paused: Set<KubeLogStreamKey> = []
    private var watchTask: Task<Void, Never>?
    private var wanted = false
    private var capWatch: AnyCancellable?

    /// `capChanged`: fires when `kubernetes.logStreams` may have changed
    /// (Settings' `changes`, which has no current value to drop).
    init(
        context: String, namespace: String, selector: String, title: String, client: KubeClient?, cap: @escaping () -> Int,
        capChanged: AnyPublisher<Void, Never>? = nil
    ) {
        self.context = context
        self.namespace = namespace
        self.selector = selector
        self.title = title
        self.client = client
        capSetting = cap
        self.cap = max(cap(), 1)
        capWatch = capChanged?.sink { [weak self] in self?.capMayHaveChanged() }
    }

    /// The setting changed while the tab shows: planned again with it.
    private func capMayHaveChanged() {
        guard wanted, max(capSetting(), 1) != cap else { return }
        reconcile()
    }

    /// `deployment/web`, as kubectl names it.
    static func title(kind: String, name: String) -> String { "\(kind.lowercased())/\(name)" }

    // MARK: Shown and hidden

    /// The tab shows: the pods watched, their streams followed (from where
    /// each was, if it was).
    func show(since: KubeLogSince) {
        let was = wanted
        wanted = true
        guard let client else {
            problem = "Kubernetes is off, or the context is gone."
            return
        }
        if since != self.since {
            self.since = since
            restartStreams()
        }
        // Shown again: pods that couldn't be read are asked again, and each
        // stream is read again from its last line — once the watch has
        // listed the pods (`apply(.listed)`), never for one gone meanwhile.
        if !was { unreadable = [] }
        if watchTask == nil {
            watching = false
            watch(client)
        }
    }

    /// The tab is gone, the page hidden: the watch and every stream close.
    func hide() {
        wanted = false
        watchTask?.cancel()
        watchTask = nil
        watching = false
        for task in fetches.values { task.cancel() }
        fetches = [:]
        for follower in followers.values { follower.stop() }
        paused = Set(followers.keys)
        for key in Array(readings.keys) { if case .ended = readings[key] {} else { readings[key] = .idle } }
        publishStreams()
        updateFollowing()
    }

    /// The detail closed or moved on: nothing more is read.
    func cancel() {
        hide()
        followers = [:]
        readings = [:]
        paused = []
        ended = []
        publishStreams()
    }

    /// Other include and exclude expressions: every stream from the start.
    /// One that isn't a regular expression changes nothing (`problem` says).
    @discardableResult
    func setFilter(_ filter: KubeMergedLogFilter) -> Bool {
        guard filter.problem == nil else { return false }
        guard filter != self.filter else { return true }
        self.filter = filter
        restartStreams()
        return true
    }

    // MARK: The pods

    private func watch(_ client: KubeClient) {
        let namespace = self.namespace
        let options = KubeListOptions(labelSelector: selector)
        watchTask = Task { [weak self] in
            do {
                for try await update in client.follow(.pods, in: .namespace(namespace), options: options) {
                    guard let self, !Task.isCancelled else { return }
                    self.apply(update)
                }
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.problem = KubernetesModel.said(error)
                self.watching = false
                self.watchTask = nil
            }
        }
    }

    private func apply(_ update: KubeFollowUpdate) {
        switch update {
        case .listed(let table):
            present = Set(table.rows.map(\.id.name))
            watching = true
            problem = nil
        case .changed(let changes, _):
            for change in changes {
                switch change {
                case .added(let row):
                    present.insert(row.id.name)
                case .modified(let row):
                    present.insert(row.id.name)
                    // Changed: worth reading again.
                    unreadable.remove(row.id.name)
                case .deleted(let id):
                    present.remove(id.name)
                }
            }
        case .bookmark, .retrying:
            return
        }
        reconcile()
    }

    /// The streams the plan wants: those of pods gone (or left out, or past
    /// the cap, or ended) closed, new ones followed, paused ones followed
    /// again, pods not read yet read — the last three only while shown and
    /// the watch has listed the pods.
    private func reconcile() {
        for name in Array(containers.keys) where !present.contains(name) { containers[name] = nil }
        retireEnvs()
        unreadable.formIntersection(present)
        if podProblems.keys.contains(where: { !present.contains($0) }) { podProblems = podProblems.filter { present.contains($0.key) } }
        if ended.contains(where: { !present.contains($0.pod) }) { ended.removeAll { !present.contains($0.pod) } }
        cap = max(capSetting(), 1)
        let done = Set(ended)
        let pods = present.sorted().map { name in
            (name: name, containers: containers[name].map { $0.filter { !done.contains(KubeLogStreamKey(pod: name, container: $0)) } } ?? (unreadable.contains(name) ? [] : nil))
        }
        let plan = KubeMergedLogPlan.plan(pods: pods, following: Set(followers.keys), cap: cap, filter: filter)
        let wantedKeys = Set(plan.streams)
        for key in Array(followers.keys) where !wantedKeys.contains(key) {
            followers[key]?.stop()
            followers[key] = nil
            readings[key] = nil
            paused.remove(key)
        }
        if wanted && watching {
            for key in plan.streams {
                if let follower = followers[key] {
                    if paused.remove(key) != nil { follower.start(tail: Self.firstTail) }
                } else {
                    startStream(key)
                }
            }
            for pod in plan.fetch where fetches[pod] == nil { fetch(pod) }
        }
        self.pods = present.sorted()
        total = plan.total
        capped = plan.capped
        publishStreams(plan.streams)
        updateFollowing()
    }

    private func fetch(_ pod: String) {
        guard let client else { return }
        let namespace = self.namespace
        fetches[pod] = Task { [weak self] in
            do {
                let object = try await client.object(.pods, namespace: namespace, name: pod)
                guard let self, !Task.isCancelled else { return }
                self.fetches[pod] = nil
                guard self.present.contains(pod) else { return }
                let json = object.json
                self.containers[pod] = KubePodContainers.of(json).filter { $0.role == .container }.map(\.name)
                self.envs[pod] = KubeLogScrub.env(of: json)
                self.podProblems[pod] = nil
                self.reconcile()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.fetches[pod] = nil
                if let error = error as? KubeAPIError, error.isNotFound {
                    self.present.remove(pod)
                } else {
                    self.unreadable.insert(pod)
                    self.podProblems[pod] = "\(pod): \(KubernetesModel.said(error))"
                }
                self.reconcile()
            }
        }
    }

    private func startStream(_ key: KubeLogStreamKey) {
        guard let client else { return }
        let source = KubePodLogSource(client: client, namespace: namespace, pod: key.pod, container: key.container, previous: false, since: since)
        source.retryDelay = retryDelay
        source.onState = { [weak self] state in self?.setReading(state, of: key) }
        source.onPod = { [weak self] pod in self?.envs[key.pod] = KubeLogScrub.env(of: pod) }
        let follower = LogFollower(source: KubeMergedLogSource(key: key, inner: source, filter: filter), feed: feed, merging: true)
        follower.onChange = { [weak self] in self?.updateFollowing() }
        followers[key] = follower
        readings[key] = .idle
        follower.start(tail: Self.firstTail)
    }

    /// Since or the filter changed: every stream from its start (ended
    /// ones too), the feed cleared.
    private func restartStreams() {
        for follower in followers.values { follower.stop() }
        followers = [:]
        readings = [:]
        paused = []
        ended = []
        feed.clear()
        reconcile()
    }

    /// A gone pod's env kept while any of its lines are in the feed.
    private func retireEnvs() {
        for name in Array(envs.keys) where !present.contains(name) {
            retiredEnvs[name, default: []] += envs[name] ?? []
            envs[name] = nil
        }
        guard !retiredEnvs.isEmpty else { return }
        var said: Set<Substring> = []
        for line in feed.lines {
            if let source = line.source { said.insert(source.prefix { $0 != "/" }) }
        }
        for name in Array(retiredEnvs.keys) where !said.contains(Substring(name)) { retiredEnvs[name] = nil }
    }

    private func setReading(_ reading: KubePodLogSession.Reading, of key: KubeLogStreamKey) {
        guard followers[key] != nil, readings[key] != reading else { return }
        readings[key] = reading
        // Ended for good while its pod stays: closed, its slot freed.
        if case .ended = reading, present.contains(key.pod) {
            if !ended.contains(key) { ended.append(key) }
            reconcile()
            return
        }
        publishStreams()
    }

    private func publishStreams(_ keys: [KubeLogStreamKey]? = nil) {
        let keys = keys ?? streams.map(\.key).filter { followers[$0] != nil }
        let next = keys.map { Stream(key: $0, reading: readings[$0] ?? .idle) }
        if next != streams { streams = next }
        // A stream no longer followed nor listed: the pane shows them all.
        if let picked, !sources.contains(picked) { self.picked = nil }
    }

    private func updateFollowing() {
        let following = followers.values.contains { $0.following }
        if feed.following != following { feed.following = following }
    }

    // MARK: What it says

    /// The streams' tags, for the pane's picker: those followed and those
    /// ended, in the pods' order and their containers'.
    var sources: [String] {
        guard !ended.isEmpty else { return streams.map(\.id) }
        let keys = streams.map(\.key) + ended.filter { key in !streams.contains { $0.key == key } }
        return keys.sorted { a, b in
            if a.pod != b.pod { return a.pod < b.pod }
            let order = containers[a.pod] ?? []
            return (order.firstIndex(of: a.container) ?? .max, a.container) < (order.firstIndex(of: b.container) ?? .max, b.container)
        }.map(\.description)
    }

    /// The tab's line about the streams, the cap stated.
    var summary: String {
        let pods = self.pods.count
        let containers = streams.count
        var text = "\(containers) container\(containers == 1 ? "" : "s") of \(pods) pod\(pods == 1 ? "" : "s") followed"
        if capped > 0 { text += " · \(capped) more left out" }
        if !ended.isEmpty { text += " · \(ended.count) ended" }
        return text + " · at most \(cap) at once (kubernetes.logStreams)"
    }

    /// What couldn't be done, said beside the summary: the watch's, then
    /// each pod's.
    var problems: [String] { (problem.map { [$0] } ?? []) + podProblems.keys.sorted().compactMap { podProblems[$0] } }

    /// Lines picked out of it, for an agent: scrubbed of what looks secret —
    /// every pod's own env values (a gone pod's too, while its lines may be
    /// in the feed), tokens, keys.
    func scrubbed(_ text: String) -> String {
        KubeLogScrub.scrub(text, env: envs.values.flatMap { $0 } + retiredEnvs.values.flatMap { $0 })
    }

    /// What Save As suggests.
    var fileName: String { KubeLogText.fileName(pod: title.replacingOccurrences(of: "/", with: "-"), container: nil, previous: false) }

    /// How kubectl reads the same.
    func kubectl(timestamps: Bool) -> String {
        KubectlLine.mergedLogs(context: context, namespace: namespace, selector: selector, streams: cap, since: since, timestamps: timestamps)
    }
}
