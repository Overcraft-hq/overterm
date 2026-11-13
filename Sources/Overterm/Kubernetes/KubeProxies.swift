import Foundation
import NIOHTTP1

/// Every context's `kubectl proxy`: one long-lived proxy a context in use,
/// started by its first request (through `ManagedProcessPool`, which opens
/// it again on the next use after it died), and everything Overterm asks a
/// cluster goes through here.
///
/// - **At most `maxProxies`**, one slot always kept for the page's context:
///   background requests (attention marks, later) use `maxProxies − 1` at
///   most, and theirs are the first closed when the page needs a slot;
///   otherwise opening another closes the least recently used idle one.
/// - **Idle close:** a proxy no request has used for `idleTime` is closed.
/// - **oidc sign-ins one at a time:** kubelogin opens a browser and listens
///   on 127.0.0.1:8000, then 18000; a third at once fails to bind. A
///   context whose user signs in with it waits for its first answer until
///   no other such sign-in is running ("Waiting for the browser sign-in").
/// - **A credential failure stops the context** (`KubeProxyProblem`): no
///   retries — each would run the plugin again — until `retry`.
/// - **A metrics proxy** (stage 4, `sendPrometheus`): a context's second
///   proxy, its own entry and slot, accepting only its Prometheus
///   Service's query paths; closed when no chart shows (`closePrometheus`).
///   The page context's is not the background's to close (`pageMetrics`),
///   and what its answers say never stops the context (`metricsProblem`).
/// - **The proxies decide, not the copy** (`update`): every context as the
///   kubeconfig and the settings say now is told here on every read, and a
///   proxy's flags and every write are worked out from that — a session
///   holding a copy from before (an attention watch, a detail) never
///   reopens a socket without the method filter, and a name the list no
///   longer has is read-only. A proxy whose context now reaches another
///   cluster, or stopped being writable, is closed when the list comes.
/// - **Read-only follows the context**: a context that stops (or starts)
///   being writable gets a new proxy with the other flags. Whichever copy
///   of the context a request comes with, its proxy has the flags of the
///   context as told — and a write (`sendWrite`) is refused here, before
///   any socket, unless that context is writable (its `writable` setting:
///   yes unless it says no, on every class).
actor KubeProxies {
    struct Configuration: Equatable, Sendable {
        var maxProxies = 4
        var idleTime: TimeInterval = 600
        /// `kubernetes.kubectlPath`; empty: found (decision 22).
        var kubectlPath = ""
        /// `kubernetes.kubeconfigs`.
        var extraKubeconfigs: [String] = []
    }

    /// Who asks: the page (its context keeps a slot), the background (an
    /// agent's tools, the rail, Ask Why), or an attention watch — the
    /// background too, but nobody asked for it: it never opens a browser
    /// sign-in (an oidc context it reaches only once a request someone made
    /// has signed in, `needsPageSignIn`), and a proxy only watches hold is
    /// given up for another background request (the watch says "not
    /// watched" and tries again), so watches never fill the background's
    /// slots for good. A spare read (the Overview's pinned cards) is a
    /// watch's kind too, and more: it opens a proxy only in a slot free as
    /// it stands — nothing is closed for it (`noSlot` otherwise).
    enum Role: Sendable {
        case page, background, watch, spare

        /// Nobody asked for it: never a browser sign-in, given up for a
        /// request someone made.
        var unasked: Bool { self == .watch || self == .spare }
    }

    enum Status: Equatable, Sendable {
        case closed
        case open
        /// Its first request waits for the browser.
        case signingIn
        /// Behind another context's browser sign-in.
        case waitingForSignIn(behind: String)
        /// Its requests stopped until `retry`.
        case stopped(KubeProxyProblem)

        var reason: String? {
            switch self {
            case .closed, .open: nil
            case .signingIn: "Waiting for the browser sign-in"
            case .waitingForSignIn(let other): "Waiting for \(other)'s sign-in in the browser to finish"
            case .stopped(let problem): problem.reason
            }
        }
    }

    typealias Plan = @Sendable (KubeContext, Configuration, Int?) async throws -> KubeProxySpec
    typealias Open = @Sendable (KubeProxySpec) async throws -> KubeProxy

    static let shared = KubeProxies()

    private var configuration: Configuration
    private let plan: Plan
    private let pool: ManagedProcessPool<KubeProxySpec, KubeProxy>
    private let now: @Sendable () -> Date
    private let sweepEvery: Duration

    /// One proxy as the requests hold it. A request remembers the entry's
    /// `id`: an entry closed while the request was suspended (and maybe
    /// made again by another) is no longer its own to count down.
    private struct Entry {
        let id: UInt64
        /// Nil while it is being planned.
        var spec: KubeProxySpec?
        var lastUsed: Date
        var inFlight = 0
        /// Its last request was the background's (attention watches, the
        /// rail, agents): the first closed when the page needs a slot.
        var background = false
        /// Its requests in flight that are attention watches'.
        var watches = 0
        /// The context it is planned for, as the proxies had it when the
        /// entry was made: one whose name now reaches another server,
        /// cluster or user is closed, not reused. `plan` is given this,
        /// never a request's copy.
        var reaches: KubeContext
        /// The flags decided when it was made — before its spec is planned,
        /// so a list told while `plan` runs closes it all the same (and
        /// the request planning it ends, `closedWhileOpening`).
        var readOnly: Bool
    }

    private var entries: [String: Entry] = [:]
    private var lastID: UInt64 = 0
    private var page: String?
    private var stopped: [String: KubeProxyProblem] = [:]
    private var serverMinors: [String: Int] = [:]
    private var signingIn: String?
    private var signedIn: Set<String> = []
    private var waiting: [String: Int] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var sweeper: Task<Void, Never>?
    /// Every context as the kubeconfig and the settings say now, by name
    /// (`update`); nil until the model has said (a test's proxies).
    private var current: [String: KubeContext]?
    /// The background proxies closed for the page's slot, the last first
    /// (the last few): what a test and the scenario read.
    private(set) var closedForPage: [String] = []

    init(
        configuration: Configuration = Configuration(), now: @escaping @Sendable () -> Date = { Date() }, sweepEvery: Duration = .seconds(60),
        plan: Plan? = nil, open: @escaping Open = { try await KubeProxy.open($0) }
    ) {
        self.configuration = configuration
        self.now = now
        self.sweepEvery = sweepEvery
        let planner = KubeProxyPlanner()
        self.plan = plan ?? { try await planner.plan($0, configuration: $1, serverMinor: $2) }
        self.pool = ManagedProcessPool(open: open)
    }

    func configure(_ configuration: Configuration) {
        self.configuration = configuration
    }

    /// The context the page shows: its proxy is never closed for another's.
    func setPage(_ context: String?) {
        page = context
    }

    // MARK: The contexts as they are now

    /// The contexts as the kubeconfig and the settings say now — told on
    /// every read of them (`KubernetesModel`). From here on they, not the
    /// copy a request comes with, decide each proxy's flags and every
    /// write. A proxy whose context is gone, now reaches another cluster or
    /// user, or now has the other flags, is closed at once: kubectl read
    /// the kubeconfig when it started, so a running one would go on
    /// reaching the old cluster, and a writable one would go on taking
    /// writes for a context that is read-only now.
    func update(contexts list: KubeContextList) async {
        var named: [String: KubeContext] = [:]
        for context in list.contexts where named[context.name] == nil { named[context.name] = context }
        // A name gone, or now another cluster or user: what was learnt
        // about the old one — its server's version, a credential failure —
        // isn't the new one's.
        for (name, was) in current ?? [:] where named[name].map({ !KubernetesModel.sameCluster(was, $0) }) ?? true {
            forget(name)
        }
        current = named
        for key in Array(entries.keys) {
            guard let entry = entries[key] else { continue }
            let name = Self.contextName(key)
            guard let now = named[name] else {
                await closeProxy(key)
                continue
            }
            let planned = self.planned(now)
            let readOnly = Self.isMetrics(key) || !planned.isWritable
            let moved = !KubernetesModel.sameCluster(entry.reaches, planned)
            if moved { forget(name) }
            // Compared with what the entry was made for, planned or not yet.
            if moved || entry.readOnly != readOnly { await closeProxy(key) }
        }
    }

    /// What the proxies learnt about a name's old cluster and user: the
    /// server's version (which kubectl, streaming lists) and a stop.
    private func forget(_ name: String) {
        serverMinors[name] = nil
        stopped[name] = nil
    }

    /// The context a proxy for `copy`'s name is planned with: the context
    /// as the proxies were last told it — whatever the copy says, so a
    /// stale copy neither reopens a socket without the method filter nor
    /// closes a current one. A name the list no longer has is read-only;
    /// the copy decides only before any list was told.
    private func planned(_ copy: KubeContext) -> KubeContext {
        guard let current else { return copy }
        return current[copy.name] ?? copy.withoutWrites
    }

    /// Whether `context` may be written to now: the proxies' own context
    /// writable, and the copy the write comes with the same cluster, user
    /// and class as it — a write reviewed on another reading is refused.
    func isWritable(_ context: KubeContext) -> Bool {
        let planned = self.planned(context)
        guard planned.isWritable else { return false }
        guard current != nil else { return true }
        return KubernetesModel.sameAccess(planned, context)
    }

    /// A write through `context`'s proxy — refused before it reaches any
    /// socket unless the context is writable (its writable setting). A
    /// read-only context's socket refuses it too: this is the second lock,
    /// not the only one.
    nonisolated func sendWrite(
        _ context: KubeContext, role: Role = .page, _ method: HTTPMethod, _ path: String, body: Data?, headers: [(String, String)] = []
    ) async throws -> HTTPResponse {
        guard method != .GET, await isWritable(context) else {
            throw KubeWriteRefused(reason: method == .GET ? "A write is never a GET." : KubeWriteCheck.readOnly(context))
        }
        return try await send(context, role: role, method, path, body: body, headers: headers)
    }

    // MARK: Requests

    /// One request through `context`'s proxy, started if it isn't. Throws a
    /// `KubeProxyProblem` when the proxy can't be had or kubectl failed
    /// (a credential failure stops the context); the server's own errors
    /// come back as responses.
    nonisolated func send(
        _ context: KubeContext, role: Role = .page, _ method: HTTPMethod, _ path: String, body: Data? = nil, headers: [(String, String)] = []
    ) async throws -> HTTPResponse {
        try await request(context, role, prometheus: nil, method, path, body: body, headers: headers)
    }

    /// One Prometheus query through `context`'s metrics proxy (stage 4):
    /// a second `kubectl proxy`, started for it, whose `--accept-paths`
    /// names only `service`'s `query` and `query_range` paths, GETs only —
    /// anything else is refused here before any socket, and by its flags.
    /// It counts towards `maxProxies` as any proxy does (its own entry,
    /// never the page's kept slot), and is closed by `closePrometheus`
    /// when no chart shows, or idle.
    nonisolated func sendPrometheus(
        _ context: KubeContext, _ service: KubePrometheusService, role: Role = .page, _ path: String
    ) async throws -> HTTPResponse {
        guard service.allows(path) else { throw KubePrometheusRefused(path: path) }
        return try await request(context, role, prometheus: service, .GET, path, body: nil, headers: [("Accept", "application/json")])
    }

    private nonisolated func request(
        _ context: KubeContext, _ role: Role, prometheus: KubePrometheusService?, _ method: HTTPMethod, _ path: String, body: Data?,
        headers: [(String, String)]
    ) async throws -> HTTPResponse {
        let key = Self.key(context.name, prometheus)
        // A chart hidden meanwhile: its metrics proxy isn't opened again.
        if prometheus != nil { try Task.checkCancellation() }
        let (proxy, holds, id) = try await begin(context, role, prometheus: prometheus)
        let watch = role.unasked
        let response: HTTPResponse
        do {
            response = try await proxy.transport.send(method, path, body: body, headers: headers)
        } catch {
            await finish(context.name, key, id, watch: watch, holds: holds, problem: nil, answered: false)
            throw error
        }
        let problem =
            prometheus == nil
            ? KubeProxyProblem.classify(
                status: response.status, contentType: response.header("Content-Type"), text: String(decoding: response.body.prefix(4096), as: UTF8.self),
                stderr: proxy.stderr, signIn: proxy.signIn)
            : Self.metricsProblem(status: response.status, stderr: proxy.stderr, signIn: proxy.signIn)
        let minor = prometheus == nil && path == "/version" && response.status == 200 ? KubeVersion.minor(response.body) : nil
        await finish(context.name, key, id, watch: watch, holds: holds, problem: problem, answered: true, serverMinor: minor)
        if let problem { throw problem }
        return response
    }

    /// A metrics proxy's answer comes from a process in the cluster: its
    /// body never says what kubectl failed at — a Prometheus (or any
    /// Service its labels match) answering a plain 500 that reads
    /// "getting credentials" must not stop the context's requests. Only
    /// kubectl's own stderr can: the credential failure it logged.
    /// Anything else is the chart's problem (`KubePrometheusReader`).
    nonisolated static func metricsProblem(status: Int, stderr: String, signIn: KubeSignIn) -> KubeProxyProblem? {
        guard status == 500 else { return nil }
        let line = stderr.components(separatedBy: .newlines).last {
            let lower = $0.lowercased()
            return lower.contains("getting credentials") || lower.contains("exec plugin") || lower.contains("exec:")
        }
        guard let line else { return nil }
        // kubectl logs "… error: getting credentials: exec: …": classified from there.
        let lower = line.lowercased()
        let start = ["getting credentials", "exec plugin", "exec:"].compactMap { lower.range(of: $0)?.lowerBound }.min()
        let said = start.map { String(line[$0...]) } ?? line
        let problem = KubeProxyProblem.classify(status: 500, contentType: "text/plain", text: said, stderr: stderr, signIn: signIn)
        return problem?.stopsRequests == true ? problem : nil
    }

    /// An entry's key: the context's name for its proxy, with a mark for its metrics proxy.
    private static let metricsMark = "\u{1}prometheus"

    nonisolated static func key(_ name: String, _ prometheus: KubePrometheusService?) -> String {
        prometheus == nil ? name : name + metricsMark
    }

    private static func isMetrics(_ key: String) -> Bool { key.hasSuffix(metricsMark) }

    /// The context an entry's key is for.
    private static func contextName(_ key: String) -> String { isMetrics(key) ? String(key.dropLast(metricsMark.count)) : key }

    /// The page context's metrics proxy: a slot of the page's while its
    /// charts show — never counted in the background's budget, and never
    /// closed for a watch or a spare read (closed for one, the next chart
    /// poll would close a watch for it, and so on every refresh).
    private var pageMetrics: String? { page.map { Self.key($0, Self.anyService) } }

    /// A response read as it arrives — a watch, a followed log — through
    /// `context`'s proxy, which stays in use until the stream ends. Its
    /// pieces are handed on outside the actor.
    nonisolated func stream(
        _ context: KubeContext, role: Role = .page, _ method: HTTPMethod = .GET, _ path: String, headers: [(String, String)] = []
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.pump(context, role, method, path, headers, continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private nonisolated func pump(
        _ context: KubeContext, _ role: Role, _ method: HTTPMethod, _ path: String, _ headers: [(String, String)],
        _ continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async {
        let proxy: KubeProxy
        var holds: Bool
        let id: UInt64
        let watch = role.unasked
        do {
            (proxy, holds, id) = try await begin(context, role, prometheus: nil)
        } catch {
            continuation.finish(throwing: error)
            return
        }
        do {
            for try await piece in proxy.transport.stream(method, path, body: nil, headers: headers) {
                if holds {
                    // Answered: signed in, the next sign-in may go.
                    await released(context.name, signedIn: true)
                    holds = false
                }
                continuation.yield(piece)
            }
            await finish(context.name, context.name, id, watch: watch, holds: holds, problem: nil, answered: true)
            continuation.finish()
        } catch let error as HTTPError {
            let problem = KubeProxyProblem.classify(error, stderr: proxy.stderr, signIn: proxy.signIn)
            await finish(context.name, context.name, id, watch: watch, holds: holds, problem: problem, answered: error.status != 0)
            continuation.finish(throwing: problem ?? error)
        } catch {
            await finish(context.name, context.name, id, watch: watch, holds: holds, problem: nil, answered: false)
            continuation.finish(throwing: error)
        }
    }

    /// The context's proxy, opened if need be, held for one request — and
    /// whether that request holds the oidc sign-in, and the entry it holds.
    ///
    /// Every `await` here may let another request in: one for the same
    /// context that makes the entry too, or one that closes it. So the
    /// entry is made only when there still is none, and after each wait
    /// the request checks it still holds the entry it counted itself in;
    /// one closed meanwhile ends the request (`closedWhileOpening`) rather
    /// than going on with a proxy that may be gone, uncounted.
    private func begin(_ copy: KubeContext, _ role: Role, prometheus: KubePrometheusService?) async throws -> (KubeProxy, Bool, UInt64) {
        var context = planned(copy)
        let name = context.name
        // The context's proxy is `name`'s entry; its metrics proxy another
        // of its own (a slot like any), keyed apart. Credentials — a stop,
        // a sign-in — are the context's, whichever proxy meets them.
        let key = Self.key(name, prometheus)
        if let problem = stopped[name] { throw problem }
        let watch = role.unasked
        // A watch never signs in: an oidc context only once someone has.
        if watch, KubeSignIn(context.auth) == .oidc, !signedIn.contains(name) { throw KubeProxyProblem.needsPageSignIn }
        if role == .page { page = name }
        var readOnly = prometheus != nil || !context.isWritable
        if let entry = entries[key], let spec = entry.spec,
            entry.readOnly != readOnly || spec.prometheus != prometheus || !KubernetesModel.sameCluster(entry.reaches, context)
        {
            // Other flags, or the name now reaches another cluster or user:
            // kubectl read the kubeconfig when it started.
            await closeProxy(key)
        }
        if entries[key] == nil {
            if prometheus != nil { try Task.checkCancellation() }
            try await makeRoom(for: key, role)
            if prometheus != nil { try Task.checkCancellation() }
            if entries[key] == nil {
                // The list may have been told while room was made.
                context = planned(copy)
                readOnly = prometheus != nil || !context.isWritable
                lastID += 1
                entries[key] = Entry(id: lastID, lastUsed: now(), reaches: context, readOnly: readOnly)
            }
        }
        let id = entries[key]!.id
        entries[key]!.inFlight += 1
        if watch { entries[key]!.watches += 1 }
        entries[key]!.lastUsed = now()
        entries[key]!.background = role != .page && key != page
        let proxy: KubeProxy
        do {
            let spec: KubeProxySpec
            if let planned = entries[key]?.spec {
                spec = planned
            } else {
                // The entry's context, not this request's: the two differ
                // when another request made the entry.
                var planned = try await plan(entries[key]!.reaches, configuration, serverMinors[name])
                if let prometheus { planned = try planned.metrics(prometheus) }
                guard entries[key]?.id == id else { throw KubeProxyProblem.closedWhileOpening }
                // Another request planned it meanwhile: the one already there.
                spec = entries[key]!.spec ?? planned
                entries[key]!.spec = spec
            }
            proxy = try await pool.value(for: spec)
            guard entries[key]?.id == id else {
                // Closed while it opened: the pool keeps what finished
                // opening after the close — end it, unless the context's
                // entry now is another's on the same proxy.
                if entries[key]?.spec != spec { await pool.close(spec) }
                throw KubeProxyProblem.closedWhileOpening
            }
        } catch {
            if let problem = error as? KubeProxyProblem, problem.stopsRequests { stopped[name] = problem }
            end(key, id, watch: watch)
            if let entry = entries[key], entry.id == id, entry.inFlight == 0 { entries[key] = nil }
            throw error
        }
        startSweeping()
        do {
            return (proxy, try await signIn(name, proxy.signIn, interactive: !watch), id)
        } catch {
            end(key, id, watch: watch)
            throw error
        }
    }

    /// The socket `name`'s proxy (with `prometheus`, its metrics proxy)
    /// listens at, once planned: what a test reaches it by directly.
    func socket(_ name: String, prometheus: KubePrometheusService? = nil) -> String? {
        entries[Self.key(name, prometheus)]?.spec?.socket
    }

    /// One request done: its problem kept when it stops the context, the
    /// sign-in released, the server's minor noted.
    private func finish(
        _ name: String, _ key: String, _ id: UInt64, watch: Bool, holds: Bool, problem: KubeProxyProblem?, answered: Bool, serverMinor: Int? = nil
    ) {
        if let problem, problem.stopsRequests { stopped[name] = problem }
        if let serverMinor { serverMinors[name] = serverMinor }
        if holds { released(name, signedIn: answered && problem == nil) }
        end(key, id, watch: watch)
    }

    /// The request no longer holds entry `id` — nothing, when that entry
    /// was closed since.
    private func end(_ name: String, _ id: UInt64, watch: Bool) {
        guard entries[name]?.id == id else { return }
        entries[name]!.inFlight = max(0, entries[name]!.inFlight - 1)
        if watch { entries[name]!.watches = max(0, entries[name]!.watches - 1) }
        entries[name]!.lastUsed = now()
    }

    // MARK: A short-lived kubectl, under the same rules

    /// Before a short-lived kubectl with the context's own credentials
    /// (`kubectl auth can-i`): it runs the same exec plugin a proxy does, so
    /// the same rules hold — a stopped context isn't asked again (its
    /// problem is thrown, nothing starts), and an oidc sign-in waits its
    /// turn behind any other, a proxy's included. True when this run holds
    /// the sign-in: `endShortLived` releases it.
    func beginShortLived(_ context: KubeContext) async throws -> Bool {
        if let problem = stopped[context.name] { throw problem }
        return try await signIn(context.name, KubeSignIn(context.auth))
    }

    /// After it: a credential failure stops the context, as a proxy's does;
    /// the sign-in released — signed in when kubectl got an answer.
    func endShortLived(_ name: String, holds: Bool, problem: KubeProxyProblem?, answered: Bool) {
        if let problem, problem.stopsRequests { stopped[name] = problem }
        if holds { released(name, signedIn: answered && problem == nil) }
    }

    // MARK: Sign-ins, one at a time

    /// Waits until the context is signed in or no other sign-in runs;
    /// true when this request is the one signing in. Not `interactive` (an
    /// attention watch): refused unless the context is signed in already.
    private func signIn(_ name: String, _ kind: KubeSignIn, interactive: Bool = true) async throws -> Bool {
        guard kind == .oidc else { return false }
        while !signedIn.contains(name) {
            if let problem = stopped[name] { throw problem }
            guard interactive else { throw KubeProxyProblem.needsPageSignIn }
            if signingIn == nil {
                signingIn = name
                return true
            }
            waiting[name, default: 0] += 1
            await withCheckedContinuation { waiters.append($0) }
            waiting[name, default: 1] -= 1
            if waiting[name] == 0 { waiting[name] = nil }
        }
        return false
    }

    private func released(_ name: String, signedIn ok: Bool) {
        guard signingIn == name else { return }
        if ok { signedIn.insert(name) }
        signingIn = nil
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume() }
    }

    // MARK: Slots

    /// Closes what must close for `name` to open (decision 26, 3.13):
    ///
    /// - The background has a background slot (`maxProxies − 1`): the least
    ///   recently used idle one's; else, for a request someone made (not a
    ///   watch), the least recently used one only watches hold — its
    ///   watches say "not watched" and try again.
    /// - Then any slot: an idle background one first, then the least
    ///   recently used idle one. The page, every slot held, takes a
    ///   background one's — busy or not, its watches then say "not watched"
    ///   until a slot is free — before another context's that is busy; every
    ///   background proxy closed for the page is noted (`closedForPage`).
    private func makeRoom(for name: String, _ role: Role) async throws {
        let max = configuration.maxProxies
        let pageMetrics = self.pageMetrics
        if role == .spare {
            // Only a slot nobody holds: the background's (`maxProxies − 1`), and any.
            let background = entries.keys.filter { $0 != name && $0 != page && $0 != pageMetrics }
            guard background.count < max - 1, entries.keys.filter({ $0 != name }).count < max else { throw KubeProxyProblem.noSlot(max: max) }
            return
        }
        if role != .page {
            let background = entries.keys.filter { $0 != name && $0 != page && $0 != pageMetrics }
            if background.count >= max - 1 {
                var victim = leastRecent(background, idleOnly: true)
                if victim == nil, role == .background { victim = leastRecent(background.filter(onlyWatched), idleOnly: false) }
                guard let victim else { throw KubeProxyProblem.noSlot(max: max) }
                await closeProxy(victim)
            }
        }
        while entries.keys.filter({ $0 != name }).count >= max {
            let others = entries.keys.filter { $0 != name && $0 != page && $0 != pageMetrics }
            let background = others.filter { entries[$0]?.background == true }
            let charts = pageMetrics.map { [$0] }?.filter { $0 != name } ?? []
            var victim = leastRecent(background, idleOnly: true) ?? leastRecent(others, idleOnly: true)
            switch role {
            case .page: victim = victim ?? leastRecent(background, idleOnly: false) ?? leastRecent(others, idleOnly: false) ?? leastRecent(charts, idleOnly: false)
            // A request someone made, nothing else to close: the charts' proxy between two reads.
            case .background: victim = victim ?? leastRecent(others.filter(onlyWatched), idleOnly: false) ?? leastRecent(charts, idleOnly: true)
            case .watch, .spare: break
            }
            guard let victim else { throw KubeProxyProblem.noSlot(max: max) }
            if role == .page, entries[victim]?.background == true {
                closedForPage = Array(([Self.label(victim)] + closedForPage).prefix(8))
            }
            await closeProxy(victim)
        }
    }

    /// Busy with attention watches only: given up for a request someone made.
    private func onlyWatched(_ name: String) -> Bool {
        guard let entry = entries[name] else { return false }
        return entry.watches > 0 && entry.inFlight == entry.watches
    }

    /// One already planned (one being planned can't be closed yet).
    private func leastRecent(_ names: [String], idleOnly: Bool) -> String? {
        names.filter { entries[$0]?.spec != nil && (!idleOnly || entries[$0]?.inFlight == 0) }.min {
            entries[$0]!.lastUsed < entries[$1]!.lastUsed
        }
    }

    private func closeProxy(_ name: String) async {
        guard let entry = entries.removeValue(forKey: name) else { return }
        if !Self.isMetrics(name) { signedIn.remove(name) }
        if let spec = entry.spec { await pool.close(spec) }
        if entries.isEmpty {
            sweeper?.cancel()
            sweeper = nil
        }
    }

    // MARK: Idle

    /// Closes the proxies no request has used for `idleTime`; their contexts.
    @discardableResult
    func closeIdle() async -> [String] {
        let cutoff = now().addingTimeInterval(-configuration.idleTime)
        let idle = entries.filter { $0.value.inFlight == 0 && $0.value.spec != nil && $0.value.lastUsed <= cutoff }.map(\.key).sorted()
        for name in idle { await closeProxy(name) }
        return idle
    }

    private func startSweeping() {
        guard sweeper == nil else { return }
        let every = sweepEvery
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: every)
                guard !Task.isCancelled, let self else { return }
                await self.closeIdle()
            }
        }
    }

    // MARK: What the page asks

    func status(of name: String) async -> Status {
        if let problem = stopped[name] { return .stopped(problem) }
        if signingIn == name { return .signingIn }
        if waiting[name] != nil, let other = signingIn { return .waitingForSignIn(behind: other) }
        if let spec = entries[name]?.spec, await pool.existing(spec)?.isOpen == true { return .open }
        return .closed
    }

    /// The contexts with a proxy (or one opening) — a metrics proxy's
    /// context too: names `close` takes.
    var connected: [String] { Set(entries.keys.map(Self.contextName)).sorted() }

    /// Every proxy open (or opening), a metrics proxy as `<context>
    /// (prometheus)`: what the tests and the scenario read.
    var proxyLabels: [String] { entries.keys.map(Self.label).sorted() }

    private static func label(_ key: String) -> String { isMetrics(key) ? contextName(key) + " (prometheus)" : key }

    /// Whether `name`'s metrics proxy is open (or opening).
    func hasPrometheusProxy(_ name: String) -> Bool { entries[Self.key(name, Self.anyService)] != nil }

    /// Any Service: the key doesn't say which.
    private static let anyService = KubePrometheusService(namespace: "x", name: "x", port: "1")!

    /// After the user signed in again: the context's requests may go, on a
    /// new proxy (its metrics proxy too).
    func retry(_ name: String) async {
        stopped[name] = nil
        await closeProxy(name)
        await closeProxy(Self.key(name, Self.anyService))
    }

    /// Closes the context's proxy, and its metrics proxy.
    func close(_ name: String) async {
        await closeProxy(name)
        await closeProxy(Self.key(name, Self.anyService))
    }

    /// Closes the context's metrics proxy: no chart shows (it runs only while one does).
    func closePrometheus(_ name: String) async {
        await closeProxy(Self.key(name, Self.anyService))
    }

    /// Every proxy, at quit (`ManagedProcess.closeAll` ends them too).
    nonisolated func closeAll() { pool.closeAll() }
}

@MainActor
extension Settings {
    /// What the proxies are told: `kubernetes.maxProxies`,
    /// `proxyIdleMinutes`, `kubectlPath`, `kubeconfigs`.
    var kubernetesProxyConfiguration: KubeProxies.Configuration {
        KubeProxies.Configuration(
            maxProxies: kubernetesMaxProxies, idleTime: TimeInterval(kubernetesProxyIdleMinutes * 60), kubectlPath: kubernetesKubectlPath,
            extraKubeconfigs: kubernetesKubeconfigs)
    }
}

extension KubeContext {
    /// This context with no writes: a copy whose name the proxies no longer know.
    fileprivate var withoutWrites: KubeContext {
        var settings = self.settings
        settings.writable = false
        return KubeContext(
            name: name, cluster: cluster, server: server, namespace: namespace, user: user, auth: auth, file: file,
            contextClass: contextClass, settings: settings)
    }
}
