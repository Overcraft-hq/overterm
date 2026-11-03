import Combine
import Foundation

/// Kubernetes for the app, as `DockerModel` is Docker: the kubeconfig's
/// contexts, the one the page shows and its namespace, that context's
/// pods kept live by a watch, and how its proxy stands. One for every
/// window; each window's page holds it while it shows (`show`/`hide`).
///
/// **Nothing is read while nobody looks.** The kubeconfig is read when a
/// page first shows (and again when its settings change while one does),
/// the pods are followed only while a page shows them — the last `hide`
/// ends the watch — and no cluster is asked anything until then: this
/// Mac's current context is production. A proxy is left to its idle close
/// (`KubeProxies`), so coming back within minutes needs no new sign-in.
///
/// **Rows only.** The pods are the server's Table rows (`KubeClient.follow`),
/// the columns `kubectl get pods` shows; watch events are applied in
/// batches every `flushInterval` (Docker's burst coalescing), and an age is
/// counted on from when its row came (`KubeAge`).
///
/// **Reads only.** Every request is a GET through the context's proxy,
/// whose flags refuse every write on a read-only context (remote and
/// production by default); this model has no verb that writes.
@MainActor
final class KubernetesModel: ObservableObject {
    static let shared = KubernetesModel()

    /// What the settings say, read once a page shows and on each change.
    struct Configuration: Equatable, Sendable {
        var enabled = true
        var extraKubeconfigs: [String] = []
        var contexts: [String: KubeContextSettings] = [:]
        var pinned: [String] = []
        var proxies = KubeProxies.Configuration()
    }

    /// How the list stands.
    enum ListState: Equatable {
        /// Nobody looks, or there is no context.
        case idle
        /// Listing, the first time.
        case loading
        /// Listed, and watched.
        case live
        /// A 429 or the server's own 5xx: the rows stand while it tries again.
        case retrying(String)
        /// Stopped: why, and the proxy's problem when it was one (its button).
        case failed(String, KubeProxyProblem?)
    }

    @Published private(set) var enabled = true
    @Published private(set) var contexts = KubeContextList()
    /// Whether the kubeconfig has been read once: before, the page waits.
    @Published private(set) var contextsRead = false
    @Published private(set) var selectedName: String?
    /// The selected context's namespace, or all of them.
    @Published private(set) var scope: KubeScope = .all
    /// The context's namespaces, for the picker: its `accessibleNamespaces`,
    /// else the server's list.
    @Published private(set) var namespaces: [String] = []
    /// Why the namespaces couldn't be listed (RBAC often refuses it): one is typed.
    @Published private(set) var namespacesRefused: String?
    @Published private(set) var pods = KubeRows()
    /// Where each row's age is counted from.
    @Published private(set) var anchors: [KubeRowID: KubeAge.Anchor] = [:]
    @Published private(set) var podState: ListState = .idle
    @Published private(set) var proxyStatus: KubeProxies.Status = .closed
    @Published private(set) var version: KubeServerVersion?

    var selected: KubeContext? { selectedName.flatMap(contexts.context(named:)) }
    var isShown: Bool { viewers > 0 }

    /// The proxies the requests go through.
    var proxies: KubeProxies
    /// Instead of the context's proxy: a test's transport, the scenario's
    /// stand-in when no kubectl is installed.
    var connectOverride: ((KubeContext) -> any KubeConnection)?
    /// Instead of asking the proxies how the context stands.
    var statusOverride: ((String) async -> KubeProxies.Status)?
    /// Reads the kubeconfig files; blocking, run on a GCD thread.
    var load: @Sendable (Configuration) -> KubeContextList = { configuration in
        KubeContextList.fromEnvironment(extra: configuration.extraKubeconfigs, settings: configuration.contexts)
    }
    var readConfiguration: () -> Configuration = { Configuration(Settings.shared) }
    /// Whether it follows `Settings.shared`'s changes itself (a unit test's doesn't).
    var watchesSettings = true
    /// Whether the context picked is remembered for the next launch.
    var remembersSelection = !AppEnvironment.isUnitTest
    var flushInterval: Duration = .milliseconds(120)
    var statusInterval: Duration = .seconds(1)

    private var viewers = 0
    private var configuration = Configuration()
    /// Each context's namespace, as last picked.
    private var scopes: [String: KubeScope] = [:]
    private var following: Task<Void, Never>?
    /// Bumped whenever the follow is replaced: a late update of the old one is dropped.
    private var generation = 0
    private var pending: [KubeFollowUpdate] = []
    private var flushing: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var reading: Task<Void, Never>?
    private var side: Task<Void, Never>?
    private var settingsWatch: AnyCancellable?

    private static let rememberedKey = "kubernetes.selectedContext"

    init(proxies: KubeProxies = .shared) {
        self.proxies = proxies
    }

    // MARK: Who looks

    /// A page shows it: the kubeconfig read, the context's pods followed,
    /// until the last `hide`.
    func show() {
        viewers += 1
        guard viewers == 1 else { return }
        watchSettings()
        apply(readConfiguration())
        startPolling()
        reloadContexts()
    }

    func hide() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        stopReading()
    }

    private func stopReading() {
        endFollow()
        polling?.cancel()
        polling = nil
        side?.cancel()
        side = nil
        reading?.cancel()
        reading = nil
        podState = .idle
        let proxies = self.proxies
        Task { await proxies.setPage(nil) }
    }

    // MARK: Settings

    private func watchSettings() {
        guard watchesSettings, settingsWatch == nil else { return }
        settingsWatch = Settings.shared.changes
            .filter { $0.contains { $0.hasPrefix("kubernetes.") } }
            .sink { [weak self] _ in self?.settingsChanged() }
    }

    private func apply(_ new: Configuration) {
        configuration = new
        if enabled != new.enabled { enabled = new.enabled }
        let proxies = self.proxies
        Task { await proxies.configure(new.proxies) }
    }

    /// A `kubernetes.*` setting changed: off, everything stops and every
    /// proxy closes; otherwise the kubeconfig is read again where what it
    /// depends on changed (its files, a context's class).
    func settingsChanged() {
        let old = configuration
        let new = readConfiguration()
        apply(new)
        guard new.enabled else {
            stopReading()
            pods = KubeRows()
            anchors = [:]
            let proxies = self.proxies
            Task {
                for name in await proxies.connected { await proxies.close(name) }
            }
            return
        }
        guard isShown else { return }
        if !old.enabled {
            startPolling()
            reloadContexts()
        } else if old.extraKubeconfigs != new.extraKubeconfigs || old.contexts != new.contexts {
            reloadContexts()
        }
    }

    // MARK: Contexts

    /// The kubeconfig read again, off the main thread.
    func reloadContexts() {
        guard enabled else { return }
        reading?.cancel()
        let configuration = self.configuration
        let load = self.load
        reading = Task { [weak self] in
            let list = await KubeBlocking.run { load(configuration) }
            guard let self, !Task.isCancelled else { return }
            self.reading = nil
            self.loaded(list)
        }
    }

    private func loaded(_ list: KubeContextList) {
        let before = selected
        contexts = list
        contextsRead = true
        guard let name = Self.choose(in: list, kept: selectedName, remembered: remembered, pinned: configuration.pinned) else {
            selectedName = nil
            endFollow()
            pods = KubeRows()
            podState = .idle
            return
        }
        if name != selectedName {
            select(name)
        } else if selected != before || following == nil {
            // Its class, its server, its settings may have changed: a
            // context that stopped being writable gets a proxy with the
            // other flags on its next request.
            restartReading()
        }
    }

    /// Which context the page shows: the one it showed, else the one last
    /// picked, else the first pinned, else kubectl's current, else the first. Pure.
    static func choose(in list: KubeContextList, kept: String?, remembered: String?, pinned: [String]) -> String? {
        let names = Set(list.contexts.map(\.name))
        for candidate in [kept, remembered] + pinned.map(Optional.some) + [list.current] {
            if let candidate, names.contains(candidate) { return candidate }
        }
        return list.contexts.first?.name
    }

    private var remembered: String? {
        remembersSelection ? AppEnvironment.defaults.string(forKey: Self.rememberedKey) : nil
    }

    /// The page shows `name`: its namespace as last picked (else its own),
    /// its pods followed.
    func select(_ name: String) {
        guard let context = contexts.context(named: name) else { return }
        let changed = name != selectedName
        selectedName = name
        if remembersSelection { AppEnvironment.defaults.set(name, forKey: Self.rememberedKey) }
        scope = scopes[name] ?? Self.defaultScope(context)
        if changed {
            namespaces = []
            namespacesRefused = nil
            version = nil
            proxyStatus = .closed
        }
        restartReading()
    }

    /// The namespace the page opens a context on: its setting's, else the
    /// context's own, else `default` — as kubectl has it.
    static func defaultScope(_ context: KubeContext) -> KubeScope {
        .namespace(context.settings.defaultNamespace ?? context.namespace ?? "default")
    }

    /// One namespace, or all of them (`0`).
    func setScope(_ scope: KubeScope) {
        guard let name = selectedName, scope != self.scope else { return }
        scopes[name] = scope
        self.scope = scope
        restartReading(side: false)
    }

    /// After a sign-in, or a failure put right: the context's requests may go again.
    func retry() {
        guard let name = selectedName else { return }
        let proxies = self.proxies
        Task { [weak self] in
            await proxies.retry(name)
            self?.restartReading()
        }
    }

    // MARK: The pods

    private func endFollow() {
        following?.cancel()
        following = nil
        flushing?.cancel()
        flushing = nil
        pending = []
        generation += 1
    }

    private func connection(for context: KubeContext) -> any KubeConnection {
        connectOverride?(context) ?? KubeProxyConnection(proxies: proxies, context: context)
    }

    private func restartReading(side readSide: Bool = true) {
        endFollow()
        pods = KubeRows()
        anchors = [:]
        guard isShown, enabled, let context = selected else {
            podState = .idle
            return
        }
        podState = .loading
        let client = KubeClient(connection(for: context))
        let scope = self.scope
        let generation = self.generation
        following = Task { [weak self] in
            do {
                for try await update in client.follow(.pods, in: scope) {
                    guard let self, self.generation == generation else { return }
                    self.received(update)
                }
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == generation else { return }
                self.flush()
                self.podState = .failed(Self.said(error), error as? KubeProxyProblem)
            }
        }
        if readSide { self.readSide(context, client) }
    }

    /// The server's version and the namespaces, once a context is picked.
    private func readSide(_ context: KubeContext, _ client: KubeClient) {
        side?.cancel()
        let accessible = context.settings.accessibleNamespaces
        let name = context.name
        side = Task { [weak self] in
            if let version = try? await client.version() {
                guard let self, self.selectedName == name else { return }
                self.version = version
            }
            if !accessible.isEmpty {
                self?.namespaces = accessible
                return
            }
            do {
                let table = try await client.list(.namespaces)
                guard let self, self.selectedName == name else { return }
                self.namespaces = table.rows.map(\.id.name).sorted()
            } catch let error as KubeAPIError where error.isForbidden {
                guard let self, self.selectedName == name else { return }
                self.namespacesRefused = "Listing namespaces isn't allowed here: type one."
            } catch {
                // The list says what failed.
            }
        }
    }

    private func received(_ update: KubeFollowUpdate) {
        if case .retrying(let error) = update {
            podState = .retrying(error.message)
            return
        }
        pending.append(update)
        // The first list at once; changes in batches.
        if case .listed = update, pending.count == 1 {
            flush()
            return
        }
        guard flushing == nil else { return }
        let interval = flushInterval
        flushing = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, let self else { return }
            self.flushing = nil
            self.flush()
        }
    }

    /// What came since the last flush, applied in one change.
    private func flush() {
        guard !pending.isEmpty else { return }
        var rows = pods
        var anchors = self.anchors
        let now = Date()
        for update in pending {
            rows.apply(update)
            switch update {
            case .listed(let table):
                anchors = Dictionary(table.rows.map { ($0.id, KubeAge.anchor($0, columns: table.columns, received: now)) }, uniquingKeysWith: { $1 })
            case .changed(let changes, _):
                for change in changes {
                    switch change {
                    case .added(let row), .modified(let row): anchors[row.id] = KubeAge.anchor(row, columns: rows.columns, received: now)
                    case .deleted(let id): anchors[id] = nil
                    }
                }
            case .bookmark, .retrying: break
            }
        }
        pending = []
        pods = rows
        self.anchors = anchors
        if podState != .live { podState = .live }
    }

    // MARK: The proxy

    private func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let name = self.selectedName {
                    let status: KubeProxies.Status
                    if let override = self.statusOverride { status = await override(name) } else { status = await self.proxies.status(of: name) }
                    if self.selectedName == name, status != self.proxyStatus { self.proxyStatus = status }
                }
                try? await Task.sleep(for: self.statusInterval)
            }
        }
    }

    /// What went wrong, in words.
    static func said(_ error: Error) -> String {
        switch error {
        case let problem as KubeProxyProblem: return problem.reason
        case let api as KubeAPIError where api.isForbidden: return "Not allowed: \(api.message)"
        case let api as KubeAPIError: return api.message
        default: return error.localizedDescription
        }
    }
}

extension KubernetesModel.Configuration {
    @MainActor
    init(_ settings: Settings) {
        self.init(
            enabled: settings.kubernetesEnabled, extraKubeconfigs: settings.kubernetesKubeconfigs, contexts: settings.kubernetesContexts,
            pinned: settings.kubernetesPinnedContexts, proxies: settings.kubernetesProxyConfiguration)
    }
}
