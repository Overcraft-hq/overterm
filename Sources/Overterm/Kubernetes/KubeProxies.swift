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
/// - **Read-only follows the context**: a context that stops (or starts)
///   being writable gets a new proxy with the other flags.
actor KubeProxies {
    struct Configuration: Equatable, Sendable {
        var maxProxies = 4
        var idleTime: TimeInterval = 600
        /// `kubernetes.kubectlPath`; empty: found (decision 22).
        var kubectlPath = ""
        /// `kubernetes.kubeconfigs`.
        var extraKubeconfigs: [String] = []
    }

    /// Who asks: the page (its context keeps a slot) or the background.
    enum Role: Sendable { case page, background }

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

    // MARK: Requests

    /// One request through `context`'s proxy, started if it isn't. Throws a
    /// `KubeProxyProblem` when the proxy can't be had or kubectl failed
    /// (a credential failure stops the context); the server's own errors
    /// come back as responses.
    nonisolated func send(
        _ context: KubeContext, role: Role = .page, _ method: HTTPMethod, _ path: String, body: Data? = nil, headers: [(String, String)] = []
    ) async throws -> HTTPResponse {
        let (proxy, holds, id) = try await begin(context, role)
        let response: HTTPResponse
        do {
            response = try await proxy.transport.send(method, path, body: body, headers: headers)
        } catch {
            await finish(context.name, id, holds: holds, problem: nil, answered: false)
            throw error
        }
        let problem = KubeProxyProblem.classify(
            status: response.status, contentType: response.header("Content-Type"), text: String(decoding: response.body.prefix(4096), as: UTF8.self),
            stderr: proxy.stderr, signIn: proxy.signIn)
        let minor = path == "/version" && response.status == 200 ? KubeVersion.minor(response.body) : nil
        await finish(context.name, id, holds: holds, problem: problem, answered: true, serverMinor: minor)
        if let problem { throw problem }
        return response
    }

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
        do {
            (proxy, holds, id) = try await begin(context, role)
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
            await finish(context.name, id, holds: holds, problem: nil, answered: true)
            continuation.finish()
        } catch let error as HTTPError {
            let problem = KubeProxyProblem.classify(error, stderr: proxy.stderr, signIn: proxy.signIn)
            await finish(context.name, id, holds: holds, problem: problem, answered: error.status != 0)
            continuation.finish(throwing: problem ?? error)
        } catch {
            await finish(context.name, id, holds: holds, problem: nil, answered: false)
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
    private func begin(_ context: KubeContext, _ role: Role) async throws -> (KubeProxy, Bool, UInt64) {
        let name = context.name
        if let problem = stopped[name] { throw problem }
        if role == .page { page = name }
        let readOnly = !context.isWritable
        if let spec = entries[name]?.spec, spec.readOnly != readOnly { await closeProxy(name) }
        if entries[name] == nil {
            try await makeRoom(for: name, role)
            if entries[name] == nil {
                lastID += 1
                entries[name] = Entry(id: lastID, lastUsed: now())
            }
        }
        let id = entries[name]!.id
        entries[name]!.inFlight += 1
        entries[name]!.lastUsed = now()
        let proxy: KubeProxy
        do {
            let spec: KubeProxySpec
            if let planned = entries[name]?.spec {
                spec = planned
            } else {
                let planned = try await plan(context, configuration, serverMinors[name])
                guard entries[name]?.id == id else { throw KubeProxyProblem.closedWhileOpening }
                // Another request planned it meanwhile: the one already there.
                spec = entries[name]!.spec ?? planned
                entries[name]!.spec = spec
            }
            proxy = try await pool.value(for: spec)
            guard entries[name]?.id == id else {
                // Closed while it opened: the pool keeps what finished
                // opening after the close — end it, unless the context's
                // entry now is another's on the same proxy.
                if entries[name]?.spec != spec { await pool.close(spec) }
                throw KubeProxyProblem.closedWhileOpening
            }
        } catch {
            if let problem = error as? KubeProxyProblem, problem.stopsRequests { stopped[name] = problem }
            end(name, id)
            if let entry = entries[name], entry.id == id, entry.inFlight == 0 { entries[name] = nil }
            throw error
        }
        startSweeping()
        do {
            return (proxy, try await signIn(name, proxy), id)
        } catch {
            end(name, id)
            throw error
        }
    }

    /// One request done: its problem kept when it stops the context, the
    /// sign-in released, the server's minor noted.
    private func finish(_ name: String, _ id: UInt64, holds: Bool, problem: KubeProxyProblem?, answered: Bool, serverMinor: Int? = nil) {
        if let problem, problem.stopsRequests { stopped[name] = problem }
        if let serverMinor { serverMinors[name] = serverMinor }
        if holds { released(name, signedIn: answered && problem == nil) }
        end(name, id)
    }

    /// The request no longer holds entry `id` — nothing, when that entry
    /// was closed since.
    private func end(_ name: String, _ id: UInt64) {
        guard entries[name]?.id == id else { return }
        entries[name]!.inFlight = max(0, entries[name]!.inFlight - 1)
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
    /// true when this request is the one signing in.
    private func signIn(_ name: String, _ proxy: KubeProxy) async throws -> Bool {
        try await signIn(name, proxy.signIn)
    }

    private func signIn(_ name: String, _ kind: KubeSignIn) async throws -> Bool {
        guard kind == .oidc else { return false }
        while !signedIn.contains(name) {
            if let problem = stopped[name] { throw problem }
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

    /// Closes what must close for `name` to open: for the background, a
    /// background slot (`maxProxies − 1`); then any slot, the least recently
    /// used idle one first — for the page, a busy background one too.
    private func makeRoom(for name: String, _ role: Role) async throws {
        let max = configuration.maxProxies
        if role == .background {
            let background = entries.keys.filter { $0 != name && $0 != page }
            if background.count >= max - 1 {
                guard let victim = leastRecent(background, idleOnly: true) else { throw KubeProxyProblem.noSlot(max: max) }
                await closeProxy(victim)
            }
        }
        while entries.keys.filter({ $0 != name }).count >= max {
            let others = entries.keys.filter { $0 != name && $0 != page }
            let victim = leastRecent(others, idleOnly: true) ?? (role == .page ? leastRecent(others, idleOnly: false) : nil)
            guard let victim else { throw KubeProxyProblem.noSlot(max: max) }
            await closeProxy(victim)
        }
    }

    /// One already planned (one being planned can't be closed yet).
    private func leastRecent(_ names: [String], idleOnly: Bool) -> String? {
        names.filter { entries[$0]?.spec != nil && (!idleOnly || entries[$0]?.inFlight == 0) }.min {
            entries[$0]!.lastUsed < entries[$1]!.lastUsed
        }
    }

    private func closeProxy(_ name: String) async {
        guard let entry = entries.removeValue(forKey: name) else { return }
        signedIn.remove(name)
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

    /// The contexts with a proxy (or one opening), for tests and the page.
    var connected: [String] { entries.keys.sorted() }

    /// After the user signed in again: the context's requests may go, on a
    /// new proxy.
    func retry(_ name: String) async {
        stopped[name] = nil
        await closeProxy(name)
    }

    /// Closes the context's proxy.
    func close(_ name: String) async {
        await closeProxy(name)
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
