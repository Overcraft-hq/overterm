import Combine
import Foundation

/// What the rail's GitOps part asks of its window (gitops.md 4.5): every
/// verb goes through the page's one guard path — its class check, access
/// review, confirmation in the window naming the context and namespace,
/// the production switch — with the page's contexts loaded first; the
/// object opened on the page; Ask Why's brief. The outcome is told back
/// through `gitOpsWriteStatus`, which the rail says too.
@MainActor
protocol KubeGitOpsPanelHost: AnyObject {
    /// Reconcile, Refresh, Suspend/Resume: `KubernetesPageModel.write`.
    func gitOpsWrite(_ verb: KubeWriteVerb, on ref: KubeObjectRef) async
    /// Sync in a Tab…, Reconcile with Source in a Tab…: `runTabWrite`.
    func gitOpsTabWrite(_ verb: KubeProcessVerb, on ref: KubeObjectRef) async
    /// The binding's context on the page, the object's list and detail open.
    func gitOpsOpenOnPage(_ ref: KubeObjectRef) async
    /// Ask Why: the page's brief, shown whole before it is sent — with
    /// what the rail knows of the checkout (`extra`, scrubbed): the
    /// commits between applied and attempted, the files this branch changes.
    func gitOpsAskWhy(_ ref: KubeObjectRef, extra: [AskAgentModel.Part]) async
    /// The page's write status as it changes.
    var gitOpsWriteStatus: AnyPublisher<KubeWriteStatus?, Never> { get }
}

/// What the rail has read of a binding, kept five minutes in memory, app
/// wide (gitops.md 4.4, decision 11): its lists across the cluster (P3,
/// P4) — the sources that name the checkout and the objects that take from
/// them —, each keyed by the context, the binding and the remotes'
/// normalised set; whether Find What Deploys This was pressed for it; each
/// context's discovery the rail read (P0); and the namespaces the page's
/// section saw Applications in. Dropped on Refresh, a binding change, a
/// credential failure and at quit; never written to disk.
@MainActor
final class KubeGitOpsMatchCache {
    static let shared = KubeGitOpsMatchCache()

    struct Key: Hashable, Sendable {
        var context: String
        var checkout: String
        var namespace: String
        var remotes: String
    }

    struct Listing: Sendable {
        /// The summaries kept: the matching sources, what takes from them, the Applications read.
        var objects: [KubeGitOpsObject.Key: KubeGitOpsObject] = [:]
        /// What was cut or refused, said: "searched 500 of 1,240 Applications".
        var searched: [String] = []
        /// What it said in the end: "lists Applications in argocd…".
        var read: [String] = []
    }

    /// How long a listing is kept.
    var life: TimeInterval = 300
    var clock: () -> Date = Date.init

    private var listings: [Key: (at: Date, listing: Listing)] = [:]
    private var pressed: [Key: Date] = [:]
    private var discoveries: [String: (at: Date, discovery: KubeDiscovery)] = [:]
    private var seen: [String: Set<String>] = [:]

    func listing(_ key: Key) -> Listing? {
        guard let kept = listings[key], clock().timeIntervalSince(kept.at) < life else { return nil }
        return kept.listing
    }

    func keep(_ listing: Listing, for key: Key) { listings[key] = (clock(), listing) }

    /// Find What Deploys This pressed for it (a production binding): its lists may run, for as long as they are kept.
    func press(_ key: Key) { pressed[key] = clock() }
    func isPressed(_ key: Key) -> Bool { pressed[key].map { clock().timeIntervalSince($0) < life } ?? false }

    func discovery(_ context: String) -> KubeDiscovery? {
        guard let kept = discoveries[context], clock().timeIntervalSince(kept.at) < life else { return nil }
        return kept.discovery
    }

    func keep(_ discovery: KubeDiscovery, for context: String) { discoveries[context] = (clock(), discovery) }

    /// The page's section saw Applications in these namespaces of `context`.
    func saw(applicationsIn namespaces: Set<String>, context: String) {
        guard !namespaces.isEmpty else { return }
        seen[context, default: []].formUnion(namespaces)
    }

    func seenApplications(_ context: String) -> Set<String> { seen[context] ?? [] }

    /// Refresh, a binding change: that binding's listing and its press.
    func drop(_ key: Key) {
        listings[key] = nil
        pressed[key] = nil
    }

    /// A binding changed (edited, unbound): every listing and press of
    /// that checkout on that context and namespace, whatever its remotes.
    func drop(binding: KubeBinding) {
        func same(_ key: Key) -> Bool { key.context == binding.context && key.checkout == binding.checkout && key.namespace == binding.namespace }
        listings = listings.filter { !same($0.key) }
        pressed = pressed.filter { !same($0.key) }
    }

    /// Refresh after P0 failed or found nothing: the context's discovery read again.
    func dropDiscovery(_ context: String) { discoveries[context] = nil }

    /// A credential failure: everything of the context.
    func drop(context: String) {
        listings = listings.filter { $0.key.context != context }
        pressed = pressed.filter { $0.key.context != context }
        discoveries[context] = nil
        seen[context] = nil
    }

    func dropAll() {
        listings = [:]
        pressed = [:]
        discoveries = [:]
        seen = [:]
    }
}

/// A checkout's remotes, normalised — read once per checkout through
/// `Git.run` (`git remote -v`): each URL goes straight to `GitRemoteURL`,
/// so the raw output, which may carry a token from the user's
/// `url.*.insteadOf`, is never kept, logged or said. Its branch and each
/// remote's default branch (`refs/remotes/<remote>/HEAD`) are read every
/// time, locally. Nothing is fetched. In isolated runs and unit tests its
/// git runs with the developer's config left out (gitops.md 8), so no
/// `insteadOf` of theirs changes a match.
@MainActor
final class KubeGitOpsCheckouts {
    static let shared = KubeGitOpsCheckouts()

    /// How it runs git: the arguments, the checkout, the exit codes that succeed.
    typealias Runner = @Sendable (_ arguments: [String], _ root: URL, _ success: Set<Int32>) async throws -> String

    /// `Git.run`, or — isolated, or under test — git with `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`.
    var git: Runner = AppEnvironment.isIsolated || AppEnvironment.isUnitTest ? KubeGitOpsCheckouts.isolatedGit : KubeGitOpsCheckouts.plainGit

    nonisolated static let plainGit: Runner = { arguments, root, success in try await Git.run(arguments, in: root, success: success) }

    nonisolated static let isolatedGit: Runner = { arguments, root, success in
        try await Git.run(
            URL(fileURLWithPath: "/usr/bin/env"), ["GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1", Git.executable.path] + arguments, in: root,
            success: success)
    }

    private var remotes: [String: [KubeGitOpsMatch.Remote]] = [:]

    /// `git for-each-ref`: each remote-tracking branch's, branch's and tag's commit, local.
    nonisolated static let refsArguments = ["for-each-ref", "--format=%(objectname) %(refname)", "refs/remotes", "refs/heads", "refs/tags"]

    /// How many times a checkout's remotes were read (a test's).
    private(set) var remoteReads: [String: Int] = [:]

    init() {}

    func facts(_ root: URL) async -> KubeGitOpsMatch.Checkout {
        let key = root.standardizedFileURL.path
        let git = self.git
        var found = remotes[key]
        if found == nil {
            remoteReads[key, default: 0] += 1
            let output = (try? await git(Refs.remoteArguments, root, [0])) ?? ""
            let parsed = Refs.parse(remotes: output).compactMap { remote in remote.repo.map { KubeGitOpsMatch.Remote(name: remote.name, repo: $0) } }
            remotes[key] = parsed
            found = parsed
        }
        let list = found ?? []
        let branch = try? await git(["symbolic-ref", "--quiet", "--short", "HEAD"], root, [0, 1])
        var defaults: [String: String] = [:]
        for remote in list {
            guard let ref = KubeGitOpsGitArgs.remoteRef(remote: remote.name, "HEAD") else { continue }
            let said = (try? await git(["symbolic-ref", "--quiet", "--short", ref], root, [0, 1])) ?? ""
            let trimmed = said.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("\(remote.name)/") { defaults[remote.name] = String(trimmed.dropFirst(remote.name.count + 1)) }
        }
        let name = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = (try? await git(["rev-parse", "--verify", "--quiet", "HEAD"], root, [0, 1]))?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Where every ref points, hashed — nothing of it kept.
        let refs = (try? await git(Self.refsArguments, root, [0])).map { output -> Int in
            var hasher = Hasher()
            hasher.combine(output)
            return hasher.finalize()
        }
        return KubeGitOpsMatch.Checkout(
            root: root, remotes: list, branch: name?.isEmpty == false ? name : nil, defaults: defaults, head: commit?.count == 40 ? commit : nil,
            refs: refs)
    }

    /// The checkout whose remotes name `repo`, among `roots`; its facts.
    func checkout(naming repo: GitRemoteURL, among roots: [URL]) async -> KubeGitOpsMatch.Checkout? {
        var seen: Set<String> = []
        for root in roots where seen.insert(root.standardizedFileURL.path).inserted {
            let facts = await facts(root)
            if facts.repos.contains(repo) { return facts }
        }
        return nil
    }

    /// Refresh: the checkout's remotes read again next time (one added or changed since).
    func forget(_ root: URL) { remotes[root.standardizedFileURL.path] = nil }

    func forget() { remotes = [:] }
}

/// The rail's GitOps part (docs/design/kubernetes/gitops.md, 4): which
/// Argo CD and Flux objects deploy the bound checkout, and their states.
/// Owned by `KubernetesPanelModel`, started by its follows and stopped
/// with them — on screen only, a bound checkout only, the binding's
/// context only (never another context, where the cluster running Argo CD
/// often is production).
///
/// Its reads (4.4), every one a GET through the panel's background slot:
/// - **P0** the context's discovery, the page's when it knows it, else one
///   read, kept with the cache;
/// - **P1** the bound workloads' owners, from the panel's own follows
///   (`KubeListOptions.owners`, in the binding's namespace);
/// - **P2** each owner named read by one GET (at most 8 objects, 4 MB
///   each), with a Flux owner's source and chart;
/// - **P3** GitRepositories' rows across the cluster (their URL column),
///   OCIRepositories' objects (200 or 8 MB) — the remotes compared;
/// - **P4** Applications in Argo CD's namespace and those the page saw
///   them in; Kustomizations and HelmReleases only once a Flux source
///   matched (500 objects or 64 MB a kind, the cut said), and the
///   HelmCharts their chartRefs name by GET, each once, at most 8 (the
///   rest said);
/// - **P5** one rows-only follow per kind and namespace holding a match
///   (at most 4), filtered here by name;
/// - **P6** a match read again when its row changes, once every 15 s at most.
///
/// On a production binding P3 and P4 wait for Find What Deploys This. A
/// list across the cluster refused (403) is read in Flux's or Argo CD's
/// own namespace and the binding's instead — no ConfigMap. Hidden, every
/// read ends and only the cache stays (`KubeGitOpsMatchCache`).
@MainActor
final class KubePanelGitOps: ObservableObject {
    enum State: Equatable {
        case idle
        case reading
        /// Production: the lists across the cluster wait for a press.
        case waiting(String)
        case live
        /// Neither Argo CD nor Flux is served there.
        case unserved
        case failed(String)
    }

    /// One object that deploys the checkout.
    struct Match: Identifiable, Equatable {
        var key: KubeGitOpsObject.Key
        /// Ranked by the ladder; nil for an owner the cluster hasn't.
        var object: KubeGitOpsObject?
        var whys: [KubeGitOpsMatch.Why]
        var tracks: String?
        /// Has this branch reached the cluster (4.3): a case (a) match's
        /// manifests line and what goes with it, once the checkout answered.
        var reach: KubeGitOpsReach.Answer?

        var id: String { key.description }

        /// `Application argocd/acme-shop-prod`.
        var said: String { key.description }

        /// "apps/web · owns Deployment/shop-api".
        var why: String { whys.map(\.said).joined(separator: " · ") }

        var isProblem: Bool { object.map { [.failed, .blocked, .stuck].contains($0.state) } ?? false }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var matches: [Match] = []
    /// A list cut or refused, said: "searched 500 of 1,240 Applications".
    @Published private(set) var searched: [String] = []
    /// What couldn't be read (an owner's GET refused), said.
    @Published private(set) var problems: [String] = []
    /// What the lists across the cluster read, for Find What Deploys This' label.
    @Published private(set) var willRead = ""
    /// The outcome of a verb asked from the rail.
    @Published var status: KubeWriteStatus?
    /// Whether the part shows: a match, an owner, a problem, or the button.
    var shows: Bool {
        if !matches.isEmpty || !problems.isEmpty || !searched.isEmpty || status != nil { return true }
        if case .waiting = state { return true }
        if case .failed = state { return true }
        return false
    }

    weak var host: KubeGitOpsPanelHost?
    let kubernetes: KubernetesModel
    let cache: KubeGitOpsMatchCache
    let checkouts: KubeGitOpsCheckouts
    var clock: () -> Date = Date.init

    /// At most this many objects read for the owners (P2).
    nonisolated static let ownerReads = 8
    nonisolated static let getBytes = 4 << 20
    /// P3's OCIRepositories: 200 objects or 8 MB.
    nonisolated static let ociObjects = 200
    nonisolated static let ociBytes = 8 << 20
    /// P5: at most four follows.
    nonisolated static let liveFollows = 4
    /// P6: an object read again at most this often.
    nonisolated static let refetchEvery: TimeInterval = 15

    private var generation = 0
    private var binding: KubeBinding?
    /// The binding a verb's outcome was said for.
    private var said: KubeBinding?
    private var context: KubeContext?
    private var client: KubeClient?
    private var facts: KubeGitOpsMatch.Checkout?
    private var discovery: KubeDiscovery?
    private var key: KubeGitOpsMatchCache.Key?
    private var listing = KubeGitOpsMatchCache.Listing() {
        didSet { held = nil }
    }
    /// The workloads' owners as last given (P1), and their images.
    private var workloads: [(ref: KubeWorkloadRef, owners: [KubeGitOpsOwner], images: [String])] = []
    private var ownersRead: [KubeGitOpsOwner] = []
    /// P2's: the owners' objects, and what each GET said.
    private var owned: [KubeGitOpsObject.Key: KubeGitOpsObject] = [:] {
        didSet { held = nil }
    }
    private var reads: [KubeGitOpsOwner: KubeGitOpsMatch.OwnerRead] = [:]
    /// P6's: objects read again since.
    private var refetched: [KubeGitOpsObject.Key: KubeGitOpsObject] = [:] {
        didSet { held = nil }
    }
    /// Every object held — the listing, the owners', those read again —
    /// merged once each time one of them changes, not at every row flip.
    private var held: [KubeGitOpsObject.Key: KubeGitOpsObject]?
    /// The checkout followed, for Refresh after P0 failed.
    private var root: URL?
    private var lastGet: [KubeGitOpsObject.Key: Date] = [:]
    private var queued: [KubeGitOpsObject.Key: Task<Void, Never>] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var ownerTask: Task<Void, Never>?
    private var follows: [String: Task<Void, Never>] = [:]
    private var statusWatch: AnyCancellable?
    /// Each case (a) match's question as last asked of the checkout, and
    /// its answer: asked again only when the question's git — the
    /// revisions, the path, what it tracks, HEAD, the refs — changes (4.3's key).
    private var asked: [KubeGitOpsObject.Key: KubeGitOpsReach.Key] = [:]
    /// Each one's question as it is now: its words (`KubeGitOpsReach.labeled`).
    private var questions: [KubeGitOpsObject.Key: KubeGitOpsReach.Question] = [:]
    private var reached: [KubeGitOpsObject.Key: KubeGitOpsReach.Answer] = [:]
    private var reachTasks: [KubeGitOpsObject.Key: Task<Void, Never>] = [:]
    private var headTask: Task<Void, Never>?
    /// How many times a match was asked of the checkout (a test's).
    private(set) var reachRuns = 0
    /// A review tab in the checkout: the panel's (`openReview`).
    var openReview: (ReviewSource, URL) -> Void = { _, _ in }

    init(kubernetes: KubernetesModel, cache: KubeGitOpsMatchCache = .shared, checkouts: KubeGitOpsCheckouts = .shared) {
        self.kubernetes = kubernetes
        self.cache = cache
        self.checkouts = checkouts
    }

    // MARK: Starting and stopping

    /// Shown with a binding: P0, the checkout's remotes, then P3–P4 (off
    /// production, or once pressed) — the owners come as the panel's
    /// follows list them (`workloadsChanged`).
    func follow(_ binding: KubeBinding, context: KubeContext, checkout: URL, client: KubeClient) {
        stop()
        if binding != said {
            status = nil
            statusWatch = nil
        }
        said = binding
        self.binding = binding
        self.context = context
        self.client = client
        root = checkout
        start(press: false)
    }

    /// The checkout's facts, P0, then the owners and the lists: on
    /// `follow`, and again on Refresh (`press`: Find was pressed for it).
    private func start(press: Bool) {
        guard let binding, let context, let client, let checkout = root else { return }
        state = .reading
        let generation = self.generation
        tasks.append(
            Task { [weak self] in
                guard let self else { return }
                let facts = await self.checkouts.facts(checkout)
                guard self.generation == generation else { return }
                self.facts = facts
                let key = KubeGitOpsMatchCache.Key(context: context.name, checkout: binding.checkout, namespace: binding.namespace, remotes: facts.remotesKey)
                self.key = key
                if press { self.cache.press(key) }
                guard let discovery = await self.discover(context, client: client, generation: generation) else { return }
                self.discovery = discovery
                guard KubeGitOpsSummary.served(discovery) else {
                    // Argo CD may run in another cluster and deploy to this one: a
                    // workload's tracking id is still said (no GET for a kind not served).
                    self.state = .unserved
                    self.readOwners()
                    return
                }
                self.willRead = Self.willRead(discovery, context: context.name, seen: self.argoNamespaces(binding))
                self.readOwners()
                self.list(generation: generation)
            })
    }

    /// Every read ended and what was shown dropped; the cache stays.
    func stop() {
        endReads()
        binding = nil
        root = nil
        context = nil
        client = nil
        facts = nil
        discovery = nil
        key = nil
        listing = .init()
        workloads = []
        ownersRead = []
        owned = [:]
        reads = [:]
        refetched = [:]
        lastGet = [:]
        asked = [:]
        questions = [:]
        reached = [:]
        state = .idle
        if !matches.isEmpty { matches = [] }
        searched = []
        problems = []
        willRead = ""
        // A verb's outcome outlives the panel hiding a moment (a sheet, the
        // window covered): it goes with the binding (`follow`).
    }

    /// Every read running ended; what they read stays.
    private func endReads() {
        generation += 1
        for task in tasks { task.cancel() }
        tasks = []
        ownerTask?.cancel()
        ownerTask = nil
        for task in follows.values { task.cancel() }
        follows = [:]
        for task in queued.values { task.cancel() }
        queued = [:]
        for task in reachTasks.values { task.cancel() }
        reachTasks = [:]
        headTask?.cancel()
        headTask = nil
    }

    /// Unbound: a verb's outcome goes too.
    func unbound() {
        stop()
        said = nil
        status = nil
        statusWatch = nil
    }

    /// How many rows-only follows P5 holds now (a test's).
    var openFollows: Int { follows.count }

    // MARK: P0

    private func discover(_ context: KubeContext, client: KubeClient, generation: Int) async -> KubeDiscovery? {
        if let known = kubernetes.knownDiscovery(of: context) ?? cache.discovery(context.name) { return known }
        do {
            let read = try await client.discover()
            guard self.generation == generation else { return nil }
            cache.keep(read, for: context.name)
            return read
        } catch {
            guard self.generation == generation else { return nil }
            failed(error, context: context.name)
            return nil
        }
    }

    private func failed(_ error: Error, context: String) {
        if error is KubeProxyProblem { cache.drop(context: context) }
        state = .failed("Couldn't read what \(context) serves: \(KubernetesModel.said(error))")
    }

    // MARK: P1, P2: the owners

    /// The bound workloads as the panel's follows list them: their owners
    /// read (P2) when the set of owners changed.
    func workloadsChanged(_ given: [(ref: KubeWorkloadRef, owners: [KubeGitOpsOwner], images: [String])]) {
        workloads = given
        guard discovery != nil else { return }
        let owners = KubeGitOpsMatch.owners(given.map { ($0.ref, $0.owners) }).map(\.owner)
        if owners != ownersRead { readOwners() } else { compute() }
    }

    private func readOwners() {
        guard let client, let discovery else { return }
        let owners = KubeGitOpsMatch.owners(workloads.map { ($0.ref, $0.owners) }).map(\.owner)
        ownersRead = owners
        ownerTask?.cancel()
        let generation = self.generation
        let binding = self.binding
        ownerTask = Task { [weak self] in
            var budget = Self.ownerReads
            var objects: [KubeGitOpsObject.Key: KubeGitOpsObject] = [:]
            var reads: [KubeGitOpsOwner: KubeGitOpsMatch.OwnerRead] = [:]
            var problems: [String] = []
            let now = Date()
            for owner in owners where budget > 0 {
                let key = KubeGitOpsMatch.key(of: owner)
                guard let kind = Self.kind(of: key.kind, in: discovery) else {
                    // Not served here: no GET, and not in this cluster — unless its
                    // group failed to answer discovery, which says nothing.
                    if let group = Self.failedGroup(of: key.kind, in: discovery) {
                        reads[owner] = .unreadable
                        problems.append("Couldn't read \(owner.said): \(group) didn't answer discovery")
                    } else {
                        reads[owner] = .absent
                    }
                    continue
                }
                budget -= 1
                do {
                    let data = try await client.get(kind.path(namespace: key.namespace, name: key.name), maxBytes: Self.getBytes)
                    var object = try await KubeBlocking.run { Result { try KubeGitOpsSummary.object(data, readAt: now) } }.get()
                    // Helm's own label: the Application owns it only when it says so.
                    if owner.mark == .appInstance, let namespace = binding?.namespace {
                        let managed = (try? await KubeBlocking.run { Result { try KubeGitOpsWire.managed(data) } }.get())?.status?.resources ?? []
                        let refs = self?.workloads.filter { $0.owners.contains(owner) }.map(\.ref) ?? []
                        if !refs.contains(where: { KubeGitOpsMatch.manages(managed, $0, namespace: namespace) }) { object = nil }
                    }
                    if let object {
                        objects[object.key] = object
                        reads[owner] = .present
                        // A Flux owner's source, and its chart's.
                        for upstream in KubeGitOpsLadder.upstream(object) where budget > 0 && objects[upstream] == nil {
                            budget -= 1
                            if let read = await Self.get(upstream, client: client, discovery: discovery, now: now) {
                                objects[read.key] = read
                                for further in KubeGitOpsLadder.upstream(read) where budget > 0 && objects[further] == nil {
                                    budget -= 1
                                    if let source = await Self.get(further, client: client, discovery: discovery, now: now) { objects[source.key] = source }
                                }
                            }
                        }
                    } else {
                        reads[owner] = .absent
                    }
                } catch let error as KubeAPIError where error.isNotFound {
                    reads[owner] = .absent
                } catch is CancellationError {
                    return
                } catch {
                    // Refused (403), failed, timed out: unknown — never "not in" the cluster.
                    reads[owner] = .unreadable
                    problems.append("Couldn't read \(owner.said): \(KubernetesModel.said(error))")
                }
            }
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            self.owned = objects
            self.reads = reads
            self.problems = problems
            self.compute()
        }
    }

    /// One object by its key, summarised; nil when it isn't there or can't be read.
    nonisolated static func get(_ key: KubeGitOpsObject.Key, client: KubeClient, discovery: KubeDiscovery, now: Date) async -> KubeGitOpsObject? {
        guard let kind = kind(of: key.kind, in: discovery), let data = try? await client.get(kind.path(namespace: key.namespace, name: key.name), maxBytes: getBytes)
        else { return nil }
        return try? await KubeBlocking.run { Result { try KubeGitOpsSummary.object(data, readAt: now) } }.get()
    }

    /// A kind by its `kind` (`Application`, `GitRepository`…), as discovery serves it.
    nonisolated static func kind(of kind: String, in discovery: KubeDiscovery) -> KubeResourceKind? {
        guard let fullName = fullName(of: kind) else { return nil }
        return discovery.kinds.first { $0.fullName == fullName }
    }

    nonisolated static func fullName(of kind: String) -> String? {
        switch kind {
        case "Application": "applications.argoproj.io"
        case "ApplicationSet": "applicationsets.argoproj.io"
        case "Kustomization": "kustomizations.kustomize.toolkit.fluxcd.io"
        case "HelmRelease": "helmreleases.helm.toolkit.fluxcd.io"
        default: KubeGitOps.sourceResources[kind]
        }
    }

    /// The kind's API group when discovery couldn't read it (`argoproj.io`); nil when it answered.
    nonisolated static func failedGroup(of kind: String, in discovery: KubeDiscovery) -> String? {
        guard let fullName = fullName(of: kind), let dot = fullName.firstIndex(of: ".") else { return nil }
        let group = String(fullName[fullName.index(after: dot)...])
        return discovery.failedGroups.keys.contains { $0 == group || $0.hasPrefix(group + "/") } ? group : nil
    }

    // MARK: P3, P4: the lists across the cluster

    /// Where Applications are listed: Argo CD's namespace, those the page
    /// saw them in, the binding's.
    private func argoNamespaces(_ binding: KubeBinding) -> [String] {
        let seen = cache.seenApplications(binding.context).sorted()
        var names: Set<String> = []
        return ([KubeGitOps.argoDefaultNamespace] + seen + [binding.namespace]).filter { names.insert($0).inserted }
    }

    /// "lists Applications in argocd and shop and GitRepositories on fake-prod".
    static func willRead(_ discovery: KubeDiscovery, context: String, seen: [String]) -> String {
        var parts: [String] = []
        if kind(of: "Application", in: discovery) != nil { parts.append("Applications in \(seen.joined(separator: ", "))") }
        if kind(of: "GitRepository", in: discovery) != nil { parts.append("GitRepositories") }
        if kind(of: "OCIRepository", in: discovery) != nil { parts.append("OCIRepositories") }
        guard !parts.isEmpty else { return "" }
        return "lists \(parts.joined(separator: " and ")) on \(context), then what takes from a match"
    }

    private func list(generation: Int, force: Bool = false) {
        guard let key, let context, let binding, let client, let discovery, let facts else { return }
        if !force, let kept = cache.listing(key) {
            listing = kept
            searched = kept.searched
            compute()
            return
        }
        if context.isProduction, !cache.isPressed(key) {
            state = .waiting(willRead)
            compute()
            return
        }
        state = .reading
        let namespaces = argoNamespaces(binding)
        tasks.append(
            Task { [weak self] in
                let read = await Self.listing(client: client, discovery: discovery, checkout: facts, namespace: binding.namespace, argo: namespaces)
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                switch read {
                case .success(let listing):
                    self.cache.keep(listing, for: key)
                    self.listing = listing
                    self.searched = listing.searched
                    self.compute()
                case .failure(let error):
                    if error is KubeProxyProblem { self.cache.drop(context: context.name) }
                    self.state = .failed("Couldn't look for what deploys this: \(KubernetesModel.said(error))")
                }
            })
    }

    /// Find What Deploys This (production): the lists across the cluster, now.
    func find() {
        guard let key else { return }
        cache.press(key)
        list(generation: generation)
    }

    /// Refresh: the cache dropped, the checkout's remotes and everything
    /// else read again — also after a failure, or when neither tool was
    /// served (P0 read again then). What is shown stays until replaced.
    func refresh() {
        guard binding != nil, let context, let root else { return }
        var pressed = false
        if let key {
            pressed = cache.isPressed(key)
            cache.drop(key)
        }
        checkouts.forget(root)
        if discovery == nil || state == .unserved { cache.dropDiscovery(context.name) }
        endReads()
        discovery = nil
        refetched = [:]
        lastGet = [:]
        ownersRead = []
        asked = [:]
        start(press: pressed)
    }

    /// Whether Refresh is offered: read, failed, or neither tool served.
    var canRefresh: Bool {
        switch state {
        case .live, .unserved, .failed: binding != nil
        default: false
        }
    }

    /// P3 and P4: what names the checkout, and what takes from it.
    nonisolated static func listing(
        client: KubeClient, discovery: KubeDiscovery, checkout: KubeGitOpsMatch.Checkout, namespace: String, argo: [String]
    ) async -> Result<KubeGitOpsMatchCache.Listing, Error> {
        var listing = KubeGitOpsMatchCache.Listing()
        let now = Date()
        let flux = KubeGitOpsControllers.fluxNamespace
        do {
            // P3: GitRepositories' rows, their URL column (no credentials: KubeTableReader drops them).
            var matchedSources: [KubeGitOpsObject.Key] = []
            if let kind = kind(of: "GitRepository", in: discovery) {
                let table: KubeTable
                do {
                    table = try await client.list(kind, in: .all)
                } catch let error as KubeAPIError where error.isForbidden {
                    table = try await client.list(kind, in: .of([flux, namespace]))
                    listing.searched.append("GitRepositories: forbidden across the cluster; read in \(flux) and \(namespace)")
                }
                for row in table.rows {
                    guard let url = row.cell("URL", in: table.columns)?.text, let repo = GitRemoteURL(url), checkout.repos.contains(repo) else { continue }
                    matchedSources.append(KubeGitOpsObject.Key(kind: "GitRepository", namespace: row.id.namespace, name: row.id.name))
                }
                // The matching ones whole: their ref (what they track), their artifact.
                for key in matchedSources.prefix(ownerReads) {
                    if let object = await get(key, client: client, discovery: discovery, now: now) { listing.objects[object.key] = object }
                }
            }
            // P3: OCIRepositories whole — the match needs their artifact's origin.
            if let kind = kind(of: "OCIRepository", in: discovery) {
                let paged: KubeGitOpsPaged
                do {
                    paged = try await client.pagedObjects(kind, in: nil, stopAfter: ociObjects, totalBytes: ociBytes, readAt: now)
                } catch let error as KubeAPIError where error.isForbidden {
                    paged = try await client.pagedObjects(kind, in: flux, stopAfter: ociObjects, totalBytes: ociBytes, readAt: now)
                    listing.searched.append("OCIRepositories: forbidden across the cluster; read in \(flux)")
                }
                if let cut = paged.cut { listing.searched.append("searched \(cut)") }
                for object in paged.objects where KubeGitOpsMatch.sourceMatches(object, in: checkout) {
                    listing.objects[object.key] = object
                    matchedSources.append(object.key)
                }
            }
            // P4: Applications where they live.
            if let kind = kind(of: "Application", in: discovery) {
                var refused: [String] = []
                for place in argo {
                    do {
                        let paged = try await client.pagedObjects(kind, in: place, readAt: now)
                        if let cut = paged.cut { listing.searched.append("searched \(cut) in \(place)") }
                        for object in paged.objects { listing.objects[object.key] = object }
                    } catch let error as KubeAPIError where error.isForbidden || error.isNotFound {
                        refused.append(place)
                    }
                }
                if !refused.isEmpty { listing.searched.append("Applications: refused in \(refused.joined(separator: ", "))") }
            }
            // P4: Kustomizations and HelmReleases, only once a Flux source matched.
            // A chartRef's HelmChart by GET: each chart once (a miss remembered), at most `ownerReads`.
            var charts: [KubeGitOpsObject.Key: KubeGitOpsObject?] = [:]
            var chartsLeft = 0
            if !matchedSources.isEmpty {
                let places = [flux, namespace] + matchedSources.compactMap(\.namespace)
                for name in ["Kustomization", "HelmRelease"] {
                    guard let kind = kind(of: name, in: discovery) else { continue }
                    var objects: [KubeGitOpsObject] = []
                    do {
                        let paged = try await client.pagedObjects(kind, in: nil, readAt: now)
                        if let cut = paged.cut { listing.searched.append("searched \(cut)") }
                        objects = paged.objects
                    } catch let error as KubeAPIError where error.isForbidden {
                        var seen: Set<String> = []
                        for place in places where seen.insert(place).inserted {
                            if let paged = try? await client.pagedObjects(kind, in: place, readAt: now) { objects += paged.objects }
                        }
                        listing.searched.append("\(KubeKindCatalog.title(of: kind)): forbidden across the cluster; read in \(seen.sorted().joined(separator: ", "))")
                    }
                    let matched = Set(matchedSources)
                    for object in objects {
                        if let reference = object.sourceRef, matched.contains(KubeGitOpsMatch.key(reference)) {
                            listing.objects[object.key] = object
                        } else if let reference = object.chartRef {
                            // A chart's own source decides: its HelmChart read by one GET.
                            let chartKey = KubeGitOpsMatch.key(reference)
                            if matched.contains(chartKey) {
                                listing.objects[object.key] = object
                            } else if reference.kind == "HelmChart" {
                                var chart = listing.objects[chartKey]
                                if chart == nil {
                                    if let known = charts[chartKey] {
                                        chart = known
                                    } else if charts.count < ownerReads {
                                        chart = await get(chartKey, client: client, discovery: discovery, now: now)
                                        charts[chartKey] = .some(chart)
                                    } else {
                                        chartsLeft += 1
                                        continue
                                    }
                                }
                                if let chart, let source = chart.sourceRef, matched.contains(KubeGitOpsMatch.key(source)) {
                                    listing.objects[chart.key] = chart
                                    listing.objects[object.key] = object
                                }
                            }
                        }
                    }
                }
            }
            if chartsLeft > 0 {
                listing.searched.append("HelmCharts: \(ownerReads) read, \(chartsLeft) HelmRelease\(chartsLeft == 1 ? "" : "s") naming another not compared")
            }
            return .success(listing)
        } catch {
            return .failure(error)
        }
    }

    // MARK: What is shown

    /// The matches from every object held; only theirs ranked (each
    /// against all it holds — its source, its dependencies), a handful,
    /// not the whole listing at every row flip of a rollout.
    private func compute() {
        guard let facts, let context else { return }
        let objects: [KubeGitOpsObject.Key: KubeGitOpsObject]
        if let held {
            objects = held
        } else {
            var merged = listing.objects
            merged.merge(owned) { _, owner in owner }
            merged.merge(refetched) { _, again in again }
            held = merged
            objects = merged
        }
        // An owner not read yet says nothing yet.
        let owners = KubeGitOpsMatch.owners(workloads.map { ($0.ref, $0.owners) }).compactMap { owner, refs in
            reads[owner].map { (owner: owner, workloads: refs, read: $0) }
        }
        let found = KubeGitOpsMatch.found(
            owned: owners, objects: objects, workloads: workloads.map { ($0.ref, $0.images) }, checkout: facts, context: context.name)
        let now = clock()
        let new = found.map { found in
            Match(
                key: found.key, object: objects[found.key].map { KubeGitOpsSummary.evaluated($0, now: now, peers: objects) }, whys: found.whys,
                tracks: found.tracks, reach: reached[found.key])
        }.sorted { a, b in
            switch (a.object, b.object) {
            case let (x?, y?): return KubeGitOpsSummary.ordered(x, y)
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.id < b.id
            }
        }
        if new != matches { matches = new }
        switch state {
        case .waiting, .failed, .unserved: break
        default: state = .live
        }
        followLive()
        reach(objects: objects, facts: facts)
    }

    // MARK: Has this branch reached the cluster (4.3)

    /// Each case (a) match asked of the checkout when its question changed;
    /// an event that changes nothing runs no git.
    private func reach(objects: [KubeGitOpsObject.Key: KubeGitOpsObject], facts: KubeGitOpsMatch.Checkout) {
        let git = checkouts.git
        let root = facts.root
        let generation = self.generation
        var wanted: Set<KubeGitOpsObject.Key> = []
        for match in matches {
            guard let object = match.object, let why = match.whys.first(where: \.isRepository),
                let question = KubeGitOpsReach.question(object, why: why, checkout: facts, peers: objects)
            else { continue }
            wanted.insert(match.key)
            let key = match.key
            questions[key] = question
            guard asked[key] != question.key else {
                // Nothing git reads changed (a reconcile's Ready → Progressing → Ready): the words only.
                if let answer = reached[key] { show(KubeGitOpsReach.labeled(answer, question), for: key) }
                continue
            }
            let asking = question.key
            asked[key] = asking
            reachRuns += 1
            reachTasks[key]?.cancel()
            reachTasks[key] = Task { [weak self] in
                let answer = await KubeGitOpsReach.answer(question, in: root, git: git)
                guard let self, self.generation == generation, !Task.isCancelled, self.asked[key] == asking else { return }
                self.reachTasks[key] = nil
                self.show(self.questions[key].map { KubeGitOpsReach.labeled(answer, $0) } ?? answer, for: key)
            }
        }
        // A match gone, or no longer case (a): its answer goes.
        for key in Set(asked.keys).subtracting(wanted) {
            asked[key] = nil
            questions[key] = nil
            reached[key] = nil
            reachTasks[key]?.cancel()
            reachTasks[key] = nil
        }
    }

    private func show(_ answer: KubeGitOpsReach.Answer, for key: KubeGitOpsObject.Key) {
        if reached[key] != answer { reached[key] = answer }
        if let index = matches.firstIndex(where: { $0.key == key }), matches[index].reach != answer { matches[index].reach = answer }
    }

    /// The checkout may have moved (a commit, a checkout of another branch —
    /// the window's diff saw its git change): its branch and HEAD read again
    /// (a few local git calls, only while shown with a match), and the
    /// answers asked again if they changed.
    func headMayHaveMoved() {
        guard binding != nil, let root, facts != nil, !matches.isEmpty, headTask == nil else { return }
        let generation = self.generation
        headTask = Task { [weak self] in
            guard let self else { return }
            let facts = await self.checkouts.facts(root)
            guard self.generation == generation, !Task.isCancelled else { return }
            self.headTask = nil
            guard facts != self.facts else { return }
            self.facts = facts
            self.compute()
        }
    }

    /// Diff Deployed…Current: what the checkout has that isn't at the manifests' commit.
    func reviewDeployed(_ match: Match) {
        guard let root, let found = match.reach?.found else { return }
        openReview(KubeDeployedCommit.review(found), root)
    }

    /// The files this branch changes under the match's paths.
    func reviewChanged(_ match: Match) {
        guard let root, let review = match.reach?.changed?.review else { return }
        openReview(review, root)
    }

    // MARK: P5, P6: the matches kept current

    /// One rows-only follow per kind and namespace holding a match, at most four.
    private func followLive() {
        guard let client, let discovery else { return }
        var wanted: [String: (kind: KubeResourceKind, namespace: String?, names: Set<String>)] = [:]
        for match in matches where match.object != nil {
            guard let kind = Self.kind(of: match.key.kind, in: discovery) else { continue }
            let id = "\(kind.fullName)\u{1F}\(match.key.namespace ?? "")"
            if wanted[id] == nil, wanted.count >= Self.liveFollows { continue }
            wanted[id, default: (kind, match.key.namespace, [])].names.insert(match.key.name)
        }
        for (id, task) in follows where wanted[id] == nil {
            task.cancel()
            follows[id] = nil
        }
        let generation = self.generation
        for (id, want) in wanted where follows[id] == nil {
            let scope: KubeScope = want.namespace.map { .namespace($0) } ?? .all
            let kindName = want.kind.kind
            follows[id] = Task { [weak self] in
                do {
                    var first = true
                    for try await update in client.follow(want.kind, in: scope) {
                        guard let self, self.generation == generation, !Task.isCancelled else { return }
                        // The first list is what the summaries were read against.
                        if first, case .listed = update {
                            first = false
                            continue
                        }
                        guard case .changed(let changes, _) = update else { continue }
                        let names = Set(self.matches.filter { $0.key.kind == kindName && $0.key.namespace == want.namespace }.map(\.key.name))
                        for change in changes where names.contains(change.id.name) {
                            self.refetch(KubeGitOpsObject.Key(kind: kindName, namespace: want.namespace, name: change.id.name))
                        }
                    }
                } catch {}
            }
        }
    }

    /// P6: the object read again, at most once every 15 s.
    private func refetch(_ key: KubeGitOpsObject.Key) {
        guard queued[key] == nil, let client, let discovery else { return }
        let wait = lastGet[key].map { max(0, Self.refetchEvery - clock().timeIntervalSince($0)) } ?? 0
        let generation = self.generation
        queued[key] = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.lastGet[key] = self.clock()
            let read = await Self.get(key, client: client, discovery: discovery, now: Date())
            guard self.generation == generation, !Task.isCancelled else { return }
            self.queued[key] = nil
            if let read { self.refetched[key] = read }
            self.compute()
        }
    }

    // MARK: Verbs, through the page's guard path

    /// The object's ref on the binding's context.
    func ref(_ match: Match) -> KubeObjectRef? {
        guard let context, let discovery, let kind = Self.kind(of: match.key.kind, in: discovery) else { return nil }
        return KubeObjectRef(context: context.name, kind: kind, namespace: match.key.namespace, name: match.key.name)
    }

    /// Reconcile (Flux) or Refresh (Argo CD): the page's write, asked there.
    func reconcile(_ match: Match) {
        guard let ref = ref(match) else { return }
        run { host in await host.gitOpsWrite(KubeGitOps.isArgoApplication(ref.kind) ? .refresh : .reconcile, on: ref) }
    }

    /// Sync in a Tab… (Argo CD) or Reconcile with Source in a Tab… (Flux).
    func syncInTab(_ match: Match) {
        guard let ref = ref(match) else { return }
        run { host in await host.gitOpsTabWrite(KubeGitOps.isArgoApplication(ref.kind) ? .argoSync : .fluxReconcile, on: ref) }
    }

    func openOnPage(_ match: Match) {
        guard let ref = ref(match), let host else { return }
        Task { await host.gitOpsOpenOnPage(ref) }
    }

    /// Ask Why, with the checkout's side when the match has one: the
    /// commits between applied and attempted (`git log --oneline`, at most
    /// 20, both verified), the files this branch changes (6.2).
    func askWhy(_ match: Match) {
        guard let ref = ref(match), let host else { return }
        let reach = match.reach
        let root = self.root
        let git = checkouts.git
        Task {
            var extra: [AskAgentModel.Part] = []
            if let reach, let root {
                var commits: [String] = []
                if let range = reach.range { commits = await KubeGitOpsReach.commits(range, in: root, git: git) }
                extra = KubeGitOpsReach.briefParts(reach, commits: commits, checkout: root)
            }
            await host.gitOpsAskWhy(ref, extra: extra)
        }
    }

    /// The page's status followed into the rail from the press on, until it ends.
    private func run(_ action: @escaping @MainActor (KubeGitOpsPanelHost) async -> Void) {
        guard let host else {
            status = .failed("The page isn't there to ask.")
            return
        }
        let asking = KubeWriteStatus.working("Asking…")
        status = asking
        statusWatch = host.gitOpsWriteStatus.dropFirst().sink { [weak self] said in
            guard let self else { return }
            guard let said else {
                // The page clears its line as a write starts and while its sheet asks; a
                // sheet cancelled ends with none: the rail's line goes, the watch stays
                // until the page says how it ended (or for two minutes at most).
                if self.status != asking { self.status = nil }
                return
            }
            self.status = said
            if !said.isWorking { self.statusWatch = nil }
        }
        let watch = statusWatch
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard let self, self.statusWatch === watch else { return }
            self.statusWatch = nil
            if self.status?.isWorking == true { self.status = nil }
        }
        Task {
            await action(host)
            // Nothing said by the page at all: the rail's line goes.
            if self.status == asking {
                self.status = nil
                self.statusWatch = nil
            }
        }
    }
}
