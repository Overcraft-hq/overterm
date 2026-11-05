import Combine
import Foundation

/// Kubernetes for the app, as `DockerModel` is Docker: the kubeconfig's
/// contexts, the one the page shows and its namespace, what that context
/// serves (discovery, kept per context), the kind shown — Pods first —
/// kept live by a watch, and how its proxy stands. One for every window;
/// each window's page holds it while it shows (`show`/`hide`).
///
/// **Nothing is read while nobody looks.** The kubeconfig is read when a
/// page first shows (and again when its settings change while one does),
/// the kind is followed only while a page shows it — the last `hide`
/// ends the watch — and no cluster is asked anything until then: this
/// Mac's current context is production. A proxy is left to its idle close
/// (`KubeProxies`), so coming back within minutes needs no new sign-in.
///
/// **Rows only.** The rows are the server's Table rows (`KubeClient.follow`),
/// the columns `kubectl get` shows for the kind — a CRD's printer columns
/// too; watch events are applied in batches every `flushInterval`
/// (Docker's burst coalescing), and an age is counted on from when its row
/// came (`KubeAge`).
///
/// **What the cluster serves** is read once a context is picked and kept
/// for it (`discoveries`) for `rediscoveryInterval`. A new or removed CRD
/// shows without a reconnect (decision 28): while a page shows, the
/// context's CustomResourceDefinitions are watched where they may be
/// listed, and a change reads discovery again; where they may not,
/// discovery is read again every `rediscoveryInterval`. A kind the server
/// answers 404 for is looked up again once too: gone, the list says so; at
/// another version, it is followed there.
///
/// **Reads only.** Every request is a GET through the context's proxy,
/// whose flags refuse every write on a read-only context (remote and
/// production by default); this model has no verb that writes.
@MainActor
final class KubernetesModel: ObservableObject {
    static let shared = KubernetesModel()
    /// The production contexts whose Secrets Show was confirmed for this
    /// session (in memory; asked again after a relaunch).
    let secretConsent = KubeSecretConsent()
    /// `kubectl auth can-i`'s answers, a minute each, for the verbs that
    /// start kubectl in a tab (a shell, attach, a log followed).
    let access = KubeAccessChecks(run: { _, _, _ in .failed("Not asked.") })
    /// The shells and attaches on production confirmed this session (rule 5).
    let shellConsent = KubeShellConsent()
    /// The access reviews behind the page's writes (SelfSubjectAccessReview
    /// through a writable context's socket), a minute each per context,
    /// namespace and verb.
    let writeAccess = KubeAccessChecks(run: { _, _, _ in .failed("Not asked.") })
    /// The production contexts whose writes are on for this session (rule
    /// 2): off at launch, turned on from the context's card, never a setting.
    @Published private(set) var productionWrites = KubeProductionWrites()
    /// Usage from metrics.k8s.io, polled only while a page shows it (stage 2d).
    let metrics = KubeMetricsMonitor()
    private var metricsChanges: AnyCancellable?

    /// What the settings say, read once a page shows and on each change.
    struct Configuration: Equatable, Sendable {
        var enabled = true
        var extraKubeconfigs: [String] = []
        var contexts: [String: KubeContextSettings] = [:]
        var pinned: [String] = []
        var proxies = KubeProxies.Configuration()
        /// The production contexts whose agents get write tools while their writes are on.
        var agentWrites: [String] = []
        /// What `E` runs, unless the context names its own.
        var debugImage = KubeCommands.defaultDebugImage
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
    /// What the selected context serves, once read; nil before.
    @Published private(set) var discovery: KubeDiscovery?
    /// Discovery's kinds that can be listed and watched, by section.
    @Published private(set) var catalog = KubeKindCatalog()
    /// Why discovery couldn't be read, when it couldn't.
    @Published private(set) var discoveryProblem: String?
    /// The kind the list shows.
    @Published private(set) var kind: KubeResourceKind = .pods
    /// The kind's rows in the scope.
    @Published private(set) var rows = KubeRows()
    /// What the rows are asked for with: a page's `label:` and `field:`
    /// words, sent to the server (`KubeListSelectors`). Empty: every row in
    /// the scope. They are the page's that asked last (`selectorOwner`), and
    /// go when that page hides: a window's page, or the switcher, never gets
    /// a list narrowed by a filter that isn't on screen.
    @Published private(set) var selectors = KubeListSelectors()
    /// The page whose filter `selectors` are; nil when nobody's are.
    private(set) var selectorOwner: ObjectIdentifier?

    var labelSelector: String? { selectors.label }
    var fieldSelector: String? { selectors.field }
    /// Where each row's age is counted from.
    @Published private(set) var anchors: [KubeRowID: KubeAge.Anchor] = [:]
    @Published private(set) var listState: ListState = .idle
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
    /// How long a context's discovery is kept, and how often it is read
    /// again while a page shows where CRDs can't be watched (decision 28).
    var rediscoveryInterval: Duration = .seconds(300)
    /// A burst of CRD changes (one applied, its versions established) is
    /// one read of discovery, this long after the first.
    var rediscoveryDelay: Duration = .milliseconds(300)

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
    /// Each context's discovery, and when it was read.
    private var discoveries: [String: (discovery: KubeDiscovery, read: ContinuousClock.Instant)] = [:]
    /// The CRD watch, or the timer that stands in for it.
    private var crdWatch: Task<Void, Never>?
    private var rediscovering: Task<Void, Never>?
    /// CRDs changed since discovery was last read: the kind shown is
    /// listed again when it is one of them (its printer columns).
    private var changedCRDs: Set<String> = []
    /// The kind followed has been looked up again after a 404.
    private var lookedUpAfter404 = false
    /// How many times discovery has been read, for the tests.
    private(set) var discoveryReads = 0

    private static let rememberedKey = "kubernetes.selectedContext"

    init(proxies: KubeProxies = .shared) {
        self.proxies = proxies
        // A sample read is the page's to draw: the list's cells read it.
        metricsChanges = metrics.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        // The kubectl and the environment the context's proxy would get,
        // as the settings say them when asked.
        // Under the proxies' credential rules: a stopped context isn't
        // asked, an oidc sign-in waits for any other.
        access.run = { [weak self] context, namespace, access in
            guard let (configuration, proxies) = await self?.canIRunWith else { return .failed("Kubernetes is off.") }
            return await KubeCanIRunner.run(context, namespace: namespace, access, configuration: configuration, proxies: proxies)
        }
        // Through the context's socket as it stands now — writable, or
        // the review isn't sent.
        writeAccess.run = { [weak self] context, namespace, access in
            guard let client = await self?.reviewClient(for: context.name) else { return .failed("Kubernetes is off, or the context is gone.") }
            return await client.review(access, namespace: namespace.isEmpty ? nil : namespace)
        }
    }

    private func reviewClient(for name: String) -> KubeClient? { client(for: name) }

    /// What the proxies are started with: which kubectl, the extra kubeconfigs.
    var proxyConfiguration: KubeProxies.Configuration { configuration.proxies }

    /// The image `E` runs on `context`: its own, else the setting's.
    func debugImage(for context: KubeContext) -> String {
        if let own = context.settings.debugImage { return own }
        let image = readConfiguration().debugImage
        return image.isEmpty ? KubeCommands.defaultDebugImage : image
    }

    /// The image a node is debugged with: the context's `nodeShellImage`,
    /// else the debug container's (`debugImage(for:)`).
    func nodeShellImage(for context: KubeContext) -> String {
        context.settings.nodeShellImage ?? debugImage(for: context)
    }

    private var canIRunWith: (KubeProxies.Configuration, KubeProxies) { (configuration.proxies, proxies) }

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
        // Whoever looks next asks with its own filter.
        selectorOwner = nil
        selectors = KubeListSelectors()
        stopReading()
    }

    private func stopReading() {
        endFollow()
        polling?.cancel()
        polling = nil
        side?.cancel()
        side = nil
        endDiscoveryWatch()
        reading?.cancel()
        reading = nil
        listState = .idle
        updateMetrics()
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
            rows = KubeRows()
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

    private func loaded(_ read: KubeContextList) {
        var list = read
        // Production's writes stay on only for the cluster they were turned
        // on for; the proxies are told of any that go. They don't wait to
        // be told: they keep the context as it was turned on and plan any
        // other copy of the name with the method filter.
        for name in productionWrites.apply(to: &list) {
            let proxies = self.proxies
            Task { await proxies.endSessionWrites(name) }
        }
        let before = selected
        // What was read for a context is kept only while it is the same
        // cluster: a name now pointing at another server, cluster or user
        // is read afresh — never another cluster's kinds offered as its.
        discoveries = discoveries.filter { name, _ in
            guard let old = contexts.context(named: name), let new = list.context(named: name) else { return false }
            return Self.sameCluster(old, new)
        }
        if let before, let now = list.context(named: before.name), !Self.sameCluster(before, now) {
            discovery = nil
            catalog = KubeKindCatalog()
        }
        // can-i's answers were about a user on a cluster: a context gone,
        // or now another cluster, user, credential or class, is asked again.
        for old in contexts.contexts where list.context(named: old.name).map({ !Self.sameAccess(old, $0) }) ?? true {
            access.forget(context: old.name)
            writeAccess.forget(context: old.name)
        }
        contexts = list
        contextsRead = true
        guard let name = Self.choose(in: list, kept: selectedName, remembered: remembered, pinned: configuration.pinned) else {
            selectedName = nil
            endFollow()
            endDiscoveryWatch()
            rows = KubeRows()
            listState = .idle
            discovery = nil
            catalog = KubeKindCatalog()
            updateMetrics()
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

    /// Whether two readings of a context reach the same cluster as the same user. Pure.
    nonisolated static func sameCluster(_ old: KubeContext, _ new: KubeContext) -> Bool {
        old.server == new.server && old.cluster == new.cluster && old.user == new.user && old.auth == new.auth
    }

    /// The same cluster, and the same class: what can-i's answers hold for.
    nonisolated static func sameAccess(_ old: KubeContext, _ new: KubeContext) -> Bool {
        sameCluster(old, new) && old.contextClass == new.contextClass
    }

    /// What `name` is known to serve: the selected context's discovery, or
    /// what was read for another lately; nil when nothing was.
    func knownDiscovery(of name: String) -> KubeDiscovery? {
        name == selectedName ? discovery : discoveries[name]?.discovery
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
    /// the kind shown followed there — what it serves read, or taken from
    /// what was read for it lately.
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
            endDiscoveryWatch()
            let cached = discoveries[name]
            discovery = cached?.discovery
            catalog = cached.map { KubeKindCatalog($0.discovery) } ?? KubeKindCatalog()
            discoveryProblem = nil
            // The kind shown, as this context serves it — else Pods.
            if let cached { kind = Self.resolved(kind, in: cached.discovery) ?? .pods }
        }
        restartReading()
    }

    /// The namespace the page opens a context on: its setting's, else the
    /// context's own, else `default` — as kubectl has it.
    static func defaultScope(_ context: KubeContext) -> KubeScope {
        .namespace(context.settings.defaultNamespace ?? context.namespace ?? "default")
    }

    /// The list shows `kind` (one of the catalog's), in the scope.
    func setKind(_ kind: KubeResourceKind) {
        guard kind != self.kind else { return }
        self.kind = kind
        guard selectedName != nil else { return }
        restartReading(side: false)
    }

    /// The kind as a context's discovery has it — another version, maybe —
    /// or nil when it doesn't serve it, or not as a list kept live. Pure.
    static func resolved(_ kind: KubeResourceKind, in discovery: KubeDiscovery) -> KubeResourceKind? {
        discovery.kinds.first { $0.fullName == kind.fullName && KubeKindCatalog.isOffered($0) }
    }

    /// One namespace, or all of them (`0`).
    func setScope(_ scope: KubeScope) {
        guard let name = selectedName, scope != self.scope else { return }
        scopes[name] = scope
        self.scope = scope
        restartReading(side: false)
    }

    /// The rows asked for again, for `owner`'s filter, with only those the
    /// selectors pick — or all of them, empty. The namespaces and the
    /// version stay as read. Two pages showing at once share one list: the
    /// one that asked last has it, and the other says so (`isSelector(of:)`).
    func setSelectors(_ selectors: KubeListSelectors, for owner: AnyObject) {
        selectorOwner = ObjectIdentifier(owner)
        changeSelectors(selectors)
    }

    /// Only a label selector (the switcher's tests, the `:` bar's words).
    func setLabelSelector(_ selector: String?, for owner: AnyObject) {
        setSelectors(KubeListSelectors(label: selector), for: owner)
    }

    /// `owner`'s page hides: the list it narrowed is every row's again.
    /// Another page's selectors are left alone.
    func releaseSelectors(for owner: AnyObject) {
        guard selectorOwner == ObjectIdentifier(owner) else { return }
        selectorOwner = nil
        changeSelectors(KubeListSelectors())
    }

    /// Whether the list is asked for with `selectors` on `owner`'s behalf —
    /// or, for none, with none at all.
    func isSelector(_ selectors: KubeListSelectors, of owner: AnyObject) -> Bool {
        selectors == self.selectors && (selectors.isEmpty || selectorOwner == ObjectIdentifier(owner))
    }

    private func changeSelectors(_ new: KubeListSelectors) {
        guard new != selectors else { return }
        selectors = new
        guard selectedName != nil else { return }
        restartReading(side: false)
    }

    // MARK: Production's writes, for the session

    /// A production context's writes on (or off) until quit: its proxy is
    /// started again — without the method filter only while they are on —
    /// and the context, as the page and its checks see it, says so. Only a
    /// production context has the switch; any other's writability is its
    /// `writable` setting alone.
    func setProductionWrites(_ on: Bool, for name: String) async {
        guard let context = contexts.context(named: name), context.isProduction, on != productionWrites.isOn(name) else { return }
        if on { await proxies.allowSessionWrites(context) } else { await proxies.endSessionWrites(name) }
        if on { productionWrites.turnOn(context) } else { productionWrites.turnOff(name) }
        var list = contexts
        _ = productionWrites.apply(to: &list)
        contexts = list
        writeAccess.forget(context: name)
        if name == selectedName { restartReading() }
    }

    /// After a sign-in, or a failure put right: the context's requests may go again.
    func retry() {
        guard let name = selectedName else { return }
        let proxies = self.proxies
        Task { [weak self] in
            await proxies.retry(name)
            self?.restartReading()
            self?.metrics.retry()
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

    private func connection(for context: KubeContext, role: KubeProxies.Role = .page) -> any KubeConnection {
        connectOverride?(context) ?? KubeProxyConnection(proxies: proxies, context: context, role: role)
    }

    /// What a page's detail reads through: the context's proxy (the page's
    /// slot; a forward's reads `.background`), or a test's connection. Nil
    /// with Kubernetes off, or for a context the kubeconfig no longer has.
    func client(for name: String, role: KubeProxies.Role = .page) -> KubeClient? {
        guard enabled, let context = contexts.context(named: name) else { return nil }
        return KubeClient(connection(for: context, role: role))
    }

    // MARK: Agents (KubeMCP)

    /// The kubeconfig's contexts as an agent's tool sees them: the page's,
    /// while one shows; else the files read again now (locally — no
    /// cluster is asked anything), the settings applied to the proxies
    /// first. Nil with Kubernetes off. Nothing the page shows changes.
    func contextsForAgents() async -> KubeContextList? {
        if isShown, contextsRead { return enabled ? contexts : nil }
        let configuration = readConfiguration()
        apply(configuration)
        await proxies.configure(configuration.proxies)
        guard configuration.enabled else { return nil }
        let load = self.load
        var list = await KubeBlocking.run { load(configuration) }
        var writes = productionWrites
        _ = writes.apply(to: &list)
        return list
    }

    /// The context a tool works on unless told another: the one the page
    /// has selected, and nothing else — never the one it would open on,
    /// which falls back to kubectl's current context (production, often):
    /// with no selection a call names its context. Stage 3a's binding (the
    /// calling pane's checkout) comes before it.
    func agentDefaultContext(in list: KubeContextList) -> String? {
        guard let name = selectedName, list.context(named: name) != nil else { return nil }
        return name
    }

    /// What `context` — as an agent's tool read it — is known to serve: the
    /// page's discovery only while the page's reading of the name is the
    /// same cluster as the tool's (the kubeconfig may have changed while
    /// the page was hidden); nil otherwise.
    func knownDiscovery(of context: KubeContext) -> KubeDiscovery? {
        guard let known = knownDiscovery(of: context.name), let read = contexts.context(named: context.name), Self.sameCluster(read, context) else {
            return nil
        }
        return known
    }

    /// The namespace a tool works in unless told another: the page's, on
    /// its context; else the one last picked there, else the context's own.
    func agentDefaultScope(for context: KubeContext) -> KubeScope {
        context.name == selectedName ? scope : (scopes[context.name] ?? Self.defaultScope(context))
    }

    /// What a tool reads through: the context's proxy in a background slot
    /// — never the page's — or a test's connection. GETs only.
    func agentClient(for context: KubeContext) -> KubeClient {
        KubeClient(connection(for: context, role: .background))
    }

    /// The contexts where agents get write tools while Overterm may write
    /// there (`kubernetes.agentWrites`), as the settings say now; empty,
    /// the write tools aren't listed.
    var agentWrites: [String] { readConfiguration().agentWrites }

    /// How the context's proxy stands, asked of the proxies (nothing started).
    func agentProxyStatus(of name: String) async -> KubeProxies.Status {
        if let statusOverride { return await statusOverride(name) }
        return await proxies.status(of: name)
    }

    private func restartReading(side readSide: Bool = true) {
        endFollow()
        rows = KubeRows()
        anchors = [:]
        lookedUpAfter404 = false
        guard isShown, enabled, let context = selected else {
            listState = .idle
            updateMetrics()
            return
        }
        let client = KubeClient(connection(for: context))
        if readSide { self.readSide(context, client) }
        follow(kind, client)
        updateMetrics()
    }

    /// The list again, the kind as it stands now.
    private func refollow() {
        guard isShown, enabled, let context = selected else { return }
        endFollow()
        rows = KubeRows()
        anchors = [:]
        follow(kind, KubeClient(connection(for: context)))
    }

    private func follow(_ kind: KubeResourceKind, _ client: KubeClient) {
        listState = .loading
        let scope = self.scope
        let options = selectors.options
        let generation = self.generation
        following = Task { [weak self] in
            do {
                for try await update in client.follow(kind, in: scope, options: options) {
                    guard let self, self.generation == generation else { return }
                    self.received(update)
                }
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == generation else { return }
                self.flush()
                if let api = error as? KubeAPIError, api.isNotFound, !self.lookedUpAfter404 {
                    // Gone, or served at another version now: discovery says which.
                    self.lookedUpAfter404 = true
                    self.listState = .loading
                    self.rediscover(now: true)
                    return
                }
                self.listState = .failed(Self.said(error), error as? KubeProxyProblem)
            }
        }
    }

    /// The server's version, what it serves and the namespaces, once a
    /// context is picked; its CRDs watched.
    private func readSide(_ context: KubeContext, _ client: KubeClient) {
        side?.cancel()
        endDiscoveryWatch()
        let accessible = context.settings.accessibleNamespaces
        let name = context.name
        let fresh = discoveries[name].map { ContinuousClock.now - $0.read < rediscoveryInterval } ?? false
        side = Task { [weak self] in
            if let version = try? await client.version() {
                guard let self, self.selectedName == name else { return }
                self.version = version
            }
            // Cancelled (another context, the page hidden, Kubernetes off):
            // nothing more is asked — a failed version read goes on otherwise.
            guard !Task.isCancelled, self?.selectedName == name else { return }
            if fresh {
                self?.watchDiscovery(client)
            } else {
                await self?.readDiscovery(client, context: name)
            }
            guard !Task.isCancelled else { return }
            if !accessible.isEmpty {
                self?.namespaces = accessible
                return
            }
            do {
                let table = try await client.list(.namespaces)
                guard let self, self.selectedName == name else { return }
                self.namespaces = table.rows.map(\.id.name).sorted()
                self.namespacesRefused = nil
            } catch let error as KubeAPIError where error.isForbidden {
                guard let self, self.selectedName == name else { return }
                self.namespacesRefused = "Listing namespaces isn't allowed here: type one."
            } catch {
                // The list says what failed.
            }
        }
    }

    private func received(_ update: KubeFollowUpdate) {
        // Listed: a later 404 is looked up again.
        if case .listed = update { lookedUpAfter404 = false }
        if case .retrying(let error) = update {
            listState = .retrying(error.message)
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
        var rows = self.rows
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
        self.rows = rows
        self.anchors = anchors
        if listState != .live { listState = .live }
    }

    // MARK: What the cluster serves

    /// Discovery read for `context` and applied, then its CRDs watched.
    private func readDiscovery(_ client: KubeClient, context name: String) async {
        discoveryReads += 1
        do {
            let discovery = try await client.discover()
            guard selectedName == name, !Task.isCancelled else { return }
            applyDiscovery(discovery, context: name)
            watchDiscovery(client)
        } catch is CancellationError {
        } catch {
            guard selectedName == name, !Task.isCancelled else { return }
            discoveryProblem = Self.said(error)
            // Read again in `rediscoveryInterval`.
            watchDiscovery(client, crds: false)
        }
    }

    private func applyDiscovery(_ new: KubeDiscovery, context name: String) {
        discoveries[name] = (new, ContinuousClock.now)
        discoveryProblem = nil
        let changed = changedCRDs
        changedCRDs = []
        if new != discovery {
            discovery = new
            let newCatalog = KubeKindCatalog(new)
            if newCatalog != catalog { catalog = newCatalog }
            updateMetrics()
        }
        // The kind shown, as the cluster serves it now.
        guard let current = Self.resolved(kind, in: new) else {
            // Pods are always asked for: their list says what's wrong —
            // unless it said 404, and discovery read again has no pods.
            guard kind.fullName != KubeResourceKind.pods.fullName else {
                if lookedUpAfter404 {
                    listState = .failed("\(name) answers 404 for pods, and doesn't serve them as a list.", nil)
                }
                return
            }
            endFollow()
            rows = KubeRows()
            anchors = [:]
            listState = .failed("\(name) doesn't serve \(KubeKindCatalog.title(of: kind)) (\(kind.fullName)) as a list.", nil)
            return
        }
        if current.groupVersion != kind.groupVersion || current.namespaced != kind.namespaced || lookedUpAfter404 || changed.contains(kind.fullName) {
            kind = current
            refollow()
        } else if current != kind {
            // Its verbs or short names: nothing to read again.
            kind = current
        }
    }

    private func endDiscoveryWatch() {
        crdWatch?.cancel()
        crdWatch = nil
        rediscovering?.cancel()
        rediscovering = nil
        changedCRDs = []
    }

    /// While a page shows: the context's CRDs watched where they may be
    /// listed and watched, a change reading discovery again; else (or once
    /// the watch is refused) discovery read again every `rediscoveryInterval`.
    private func watchDiscovery(_ client: KubeClient, crds: Bool = true) {
        crdWatch?.cancel()
        guard isShown, let name = selectedName else { return }
        let crdKind = crds ? discovery?.kinds.first { $0.fullName == Self.crdName && KubeKindCatalog.isOffered($0) } : nil
        let interval = rediscoveryInterval
        crdWatch = Task { [weak self] in
            if let crdKind {
                var known: Set<String>?
                do {
                    for try await update in client.follow(crdKind) {
                        guard let self, self.selectedName == name, !Task.isCancelled else { return }
                        switch update {
                        case .listed(let table):
                            let names = Set(table.rows.map(\.id.name))
                            if let known {
                                // Listed again (a 410): whatever differs.
                                if known != names { self.crdsChanged(names.symmetricDifference(known)) }
                            } else {
                                // The first list: a CRD discovery didn't have.
                                let served = Set(self.discovery?.kinds.map(\.fullName) ?? [])
                                if !names.isSubset(of: served) { self.crdsChanged(names.subtracting(served)) }
                            }
                            known = names
                        case .changed(let changes, _):
                            self.crdsChanged(Set(changes.map(\.id.name)))
                            for change in changes {
                                if case .deleted(let id) = change { known?.remove(id.name) } else { known?.insert(change.id.name) }
                            }
                        case .bookmark, .retrying: break
                        }
                    }
                    return
                } catch {
                    // Refused (RBAC), or failing: discovery on a timer instead.
                    guard !Task.isCancelled else { return }
                }
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled, self.selectedName == name else { return }
                self.rediscover(now: true)
            }
        }
    }

    static let crdName = "customresourcedefinitions.apiextensions.k8s.io"

    /// CRDs added, changed or removed: discovery read again, once a burst.
    private func crdsChanged(_ names: Set<String>) {
        changedCRDs.formUnion(names)
        rediscover(now: false)
    }

    /// Discovery read again for the context shown: at once, or after
    /// `rediscoveryDelay` (a burst of CRD changes is one read).
    func rediscover(now: Bool = true) {
        guard isShown, let context = selected else { return }
        if !now, rediscovering != nil { return }
        rediscovering?.cancel()
        let delay = now ? Duration.zero : rediscoveryDelay
        let client = KubeClient(connection(for: context))
        let name = context.name
        rediscovering = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, self.selectedName == name else { return }
            self.discoveryReads += 1
            do {
                let discovery = try await client.discover()
                guard !Task.isCancelled, self.selectedName == name else { return }
                self.rediscovering = nil
                self.applyDiscovery(discovery, context: name)
            } catch {
                guard !Task.isCancelled, self.selectedName == name else { return }
                self.rediscovering = nil
                self.discoveryProblem = Self.said(error)
                if self.lookedUpAfter404 {
                    self.listState = .failed("\(self.kind.fullName) isn't found (404), and discovery couldn't be read: \(Self.said(error))", nil)
                }
            }
        }
    }

    // MARK: Usage

    /// Where usage is read: the context shown, its namespace, the list's
    /// label selector, and whether discovery says metrics-server is there
    /// (`metrics: none` skips it). Nobody looking, nowhere.
    func updateMetrics() {
        guard isShown, enabled, let context = selected else {
            metrics.update(nil) { nil }
            return
        }
        let name = context.name
        metrics.update(
            KubeMetricsMonitor.Situation(
                context: name, scope: scope, labels: labelSelector,
                availability: KubeMetricsAvailability.of(discovery, source: context.settings.metrics ?? .auto))
        ) { [weak self] in self?.client(for: name) }
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
    nonisolated static func said(_ error: Error) -> String {
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
            pinned: settings.kubernetesPinnedContexts, proxies: settings.kubernetesProxyConfiguration, agentWrites: settings.kubernetesAgentWrites,
            debugImage: settings.kubernetesDebugImage)
    }
}
