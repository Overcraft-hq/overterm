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
    /// An Argo CD app read from marks (gitops.md 14.2.5): the binding's
    /// context on the page, its GitOps section, the app's detail — its
    /// namespaces in the page's scope, so the section reads it.
    func gitOpsOpenMarked(_ ref: KubeMarkedDetailRef, namespaces: [String]) async
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
/// them — and, where it reads Argo CD's apps from marks, option B's
/// (14.2.5: the matched apps, each app's members listed, what was
/// compared), each keyed by the context, the binding, the remotes'
/// normalised set and what discovery said of Argo CD and Flux (a listing
/// made of one isn't another's); whether Find What Deploys This was
/// pressed for it; each context's discovery the rail read (P0); and the
/// namespaces the page's section saw Applications in. Dropped on Refresh,
/// a binding change, a credential failure and at quit; never written to
/// disk.
@MainActor
final class KubeGitOpsMatchCache {
    static let shared = KubeGitOpsMatchCache()

    struct Key: Hashable, Sendable {
        var context: String
        var checkout: String
        var namespace: String
        var remotes: String
        /// What discovery said of each tool when it was read (`KubePanelGitOps.mode(of:)`).
        var mode: String
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
    private var marked: [Key: (at: Date, listing: KubeGitOpsMatch.MarkedListing)] = [:]
    private var pressed: [Key: Date] = [:]
    private var discoveries: [String: (at: Date, discovery: KubeDiscovery)] = [:]
    private var seen: [String: Set<String>] = [:]

    func listing(_ key: Key) -> Listing? {
        guard let kept = listings[key], clock().timeIntervalSince(kept.at) < life else { return nil }
        return kept.listing
    }

    func keep(_ listing: Listing, for key: Key) { listings[key] = (clock(), listing) }

    /// Option B's, where the rail reads from marks (14.2.5).
    func marked(_ key: Key) -> KubeGitOpsMatch.MarkedListing? {
        guard let kept = marked[key], clock().timeIntervalSince(kept.at) < life else { return nil }
        return kept.listing
    }

    func keep(_ listing: KubeGitOpsMatch.MarkedListing, for key: Key) { marked[key] = (clock(), listing) }

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
        marked[key] = nil
        pressed[key] = nil
    }

    /// A binding changed (edited, unbound): every listing and press of
    /// that checkout on that context and namespace, whatever its remotes.
    func drop(binding: KubeBinding) {
        func same(_ key: Key) -> Bool { key.context == binding.context && key.checkout == binding.checkout && key.namespace == binding.namespace }
        listings = listings.filter { !same($0.key) }
        marked = marked.filter { !same($0.key) }
        pressed = pressed.filter { !same($0.key) }
    }

    /// Refresh after P0 failed or found nothing: the context's discovery read again.
    func dropDiscovery(_ context: String) { discoveries[context] = nil }

    /// A credential failure: everything of the context.
    func drop(context: String) {
        listings = listings.filter { $0.key.context != context }
        marked = marked.filter { $0.key.context != context }
        pressed = pressed.filter { $0.key.context != context }
        discoveries[context] = nil
        seen[context] = nil
    }

    func dropAll() {
        listings = [:]
        marked = [:]
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
/// - **P1** the bound workloads' owners and marks, from the panel's own
///   follows (`KubeListOptions.owners`, `.marks`, in the binding's namespace);
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
/// Where Argo CD's Applications aren't read here (14.2.5) — not served,
/// argoproj.io not answering discovery, none listed (the section's word of
/// the last five minutes, or one row asked once P4 found none — never once
/// the rail's own reads hold an Application), refused, or a bound
/// workload's own Application not there —, its apps are read from the
/// marks on their objects: **A** the bound workloads' own (`owns`), with
/// their apps' Argo Rollouts in the binding's namespace where one may scale
/// a bound Deployment to 0 (one paged list, no watch: the Rollout is the
/// app's workload, the Deployment "scaled by its Rollout"), each settled by
/// one GET as the part first shows — a Rollout's phase in place of its
/// Deployment's 0 — within what P2 left of the read's 8 (the rest "from its
/// row"), again when its generation moves or it isn't Healthy, once every
/// 15 s at most; **B** the cluster's marked workloads listed as rows (5,000
/// or 30 MB for every kind together; or the GitOps section's apps, ranked
/// in the last five minutes) set against the checkout's committed
/// manifests — `describes`, never `owns` —, their Rollouts read within the
/// same 8; **C** and **D** by name and image, "probably". B lists only
/// where something here carries a mark (a bound workload, the page's
/// lists, the section). No GitOps verb on such an app: Open shows its
/// detail on the page.
///
/// On a production binding P3, P4 and B wait for Find What Deploys This. A
/// list across the cluster refused (403) is read in Flux's or Argo CD's
/// own namespace and the binding's instead (B's in the context's
/// accessible namespaces) — no ConfigMap. Hidden, every read ends and only
/// the cache stays (`KubeGitOpsMatchCache`).
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

    /// An Argo CD app read from the marks on its objects (14.2.5): its
    /// health by Argo CD's built-in rules, whose that health is, where its
    /// Application stands as far as can be said.
    struct Marked: Equatable {
        var app: KubeMarkedApp
        var health: KubeMarkedHealth.AppVerdict
        var scope: KubeGitOpsMatch.MarkedScope
        var place: KubeGitOpsMatch.MarkedPlace
        /// By name, image, or a manifest with no namespace: "probably".
        var probable: Bool
    }

    /// One object that deploys the checkout.
    struct Match: Identifiable, Equatable {
        var key: KubeGitOpsObject.Key
        /// Ranked by the ladder; nil for an owner the cluster hasn't, and an app read from marks.
        var object: KubeGitOpsObject?
        var whys: [KubeGitOpsMatch.Why]
        var tracks: String?
        /// Has this branch reached the cluster (4.3): a case (a) match's
        /// manifests line and what goes with it, once the checkout answered.
        var reach: KubeGitOpsReach.Answer?
        /// An app read from marks: no object of its own.
        var marked: Marked?

        var id: String { key.description }

        /// `Application argocd/acme-shop-prod`; an app read from marks,
        /// `Argo CD app prod-shop-api-service`.
        var said: String {
            guard let marked else { return key.description }
            return "Argo CD app \(marked.app.said)" + (marked.app.installation.map { " · installation \($0)" } ?? "")
        }

        /// "apps/web · owns Deployment/shop-api".
        var why: String { whys.map(\.said).joined(separator: " · ") }

        var isProblem: Bool { object.map { [.failed, .blocked, .stuck].contains($0.state) } ?? false }

        /// Its state: the object's by the ladder, or an app's from marks by Argo CD's rules.
        var state: KubeGitOpsState? { object?.state ?? marked?.health.state }
    }

    /// One bound workload as the panel's follows list it.
    struct Bound: Equatable, Sendable {
        var ref: KubeWorkloadRef
        var owners: [KubeGitOpsOwner]
        var images: [String]
        /// Its Argo CD marks and health from its row (`KubeListOptions.marks`).
        var member: KubeMarkedMember?
    }

    /// What the rail says over the apps read from marks.
    struct MarksSaid: Equatable {
        /// More than three by name or image.
        var tooMany: String?
        /// Nothing matched, B having compared: what was, never "not deployed".
        var nothing: String?
        /// What B's compare couldn't do.
        var caveats: [String] = []
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
    /// Why the rail reads Argo CD's apps from marks across this cluster
    /// (14.2.5); nil where Applications are read here.
    @Published private(set) var marksReason: KubeMarkedAppsMode.Reason?
    @Published private(set) var marksSaid = MarksSaid()
    /// Whether the part shows: a match, an owner, a problem, what the marks
    /// say, or the button.
    var shows: Bool {
        if !matches.isEmpty || !problems.isEmpty || !searched.isEmpty || status != nil { return true }
        if marksSaid.nothing != nil || marksSaid.tooMany != nil { return true }
        if case .waiting = state { return true }
        if case .failed = state { return true }
        return false
    }

    /// The part's line where it reads from marks across the cluster:
    /// "Argo CD isn't in fake-dev; read from the marks on shop's workloads"
    /// — the cluster's where only option B, C or D found its apps — only
    /// once there is something read from them, or waiting to be.
    var marksLine: String? {
        guard let reason = marksReason, let context, let binding else { return nil }
        var waiting = false
        if case .waiting = state { waiting = marksWanted }
        guard waiting || matches.contains(where: { $0.marked != nil }) || marksSaid.nothing != nil || marksSaid.tooMany != nil else { return nil }
        let bound = matches.contains { match in match.marked != nil && match.whys.contains { if case .owns = $0 { true } else { false } } }
        return KubeGitOpsMatch.marksLine(reason, context: context.name, namespace: bound || waiting ? binding.namespace : nil)
    }

    weak var host: KubeGitOpsPanelHost?
    let kubernetes: KubernetesModel
    let cache: KubeGitOpsMatchCache
    let checkouts: KubeGitOpsCheckouts
    var clock: () -> Date = Date.init

    /// At most this many objects read for the owners (P2), and with them
    /// the bound workloads' settle (14.2.5).
    nonisolated static let ownerReads = 8
    nonisolated static let getBytes = 4 << 20
    /// P3's OCIRepositories: 200 objects or 8 MB.
    nonisolated static let ociObjects = 200
    nonisolated static let ociBytes = 8 << 20
    /// P5: at most four follows.
    nonisolated static let liveFollows = 4
    /// P6: an object read again at most this often.
    nonisolated static let refetchEvery: TimeInterval = 15
    /// B's rows across the cluster: 500 a page, 5,000 objects and 30 MB
    /// for every kind together — the design's M1 bound, "rows under 30 MB
    /// together" (gitops.md 14.4.1) —, each kind read with what the ones
    /// before it left.
    nonisolated static let markedRows = KubeMarkedAppsSession.Bounds(rowsPage: 500, pageBytes: 16 << 20, rowsObjects: 5000, rowsBytes: 30 << 20)
    /// The binding namespace's Argo Rollouts: one paged list, 500 objects or 8 MB.
    nonisolated static let rolloutRows = KubeMarkedAppsSession.Bounds(rowsPage: 500, pageBytes: 8 << 20, rowsObjects: 500, rowsBytes: 8 << 20)
    /// B's bound as this rail reads it: `markedRows` but for a test's.
    var markedRowsBounds = KubePanelGitOps.markedRows

    /// What discovery says of each tool, apart, as the cache keeps a
    /// listing by — `argo=served;flux=unserved`: Argo CD's Applications
    /// served, not served, or argoproj.io not answering; Flux's kinds
    /// served, not, or its groups not answering. A listing made while one
    /// said one thing isn't another's (Flux served, Argo CD's answer changed).
    nonisolated static func mode(of discovery: KubeDiscovery) -> String {
        let argo: String
        if kind(of: "Application", in: discovery) != nil {
            argo = "served"
        } else {
            argo = failedGroup(of: "Application", in: discovery) != nil ? "undiscovered" : "unserved"
        }
        let flux: String
        if discovery.kinds.contains(where: { $0.group.hasSuffix(".toolkit.fluxcd.io") }) {
            flux = "served"
        } else {
            flux = discovery.failedGroups.keys.contains { $0.split(separator: "/").first?.hasSuffix(".toolkit.fluxcd.io") == true } ? "undiscovered" : "unserved"
        }
        return "argo=\(argo);flux=\(flux)"
    }

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
    /// P3/P4's listing is in (read, or kept): B may follow where Applications are served.
    private var listed = false
    /// The workloads' owners and marks as last given (P1), and their images.
    private var workloads: [Bound] = []
    private var ownersNamed: [KubeGitOpsOwner] = []
    /// P2's: the owners' objects, and what each GET said.
    private var owned: [KubeGitOpsObject.Key: KubeGitOpsObject] = [:] {
        didSet { held = nil }
    }
    private var ownersAnswer: OwnersRead?
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

    /// B's listing (14.2.5), and whether it is being read.
    private var marksListing: KubeGitOpsMatch.MarkedListing?
    private var marksReading = false
    /// Why the rail reads from marks across a cluster serving Applications,
    /// as told: the page's section's word of the last five minutes
    /// (`sectionReason`), B's own — one row of Applications asked
    /// (`listedReason`) —; neither stands once the rail's own reads hold an
    /// Application (`updateMarksReason`).
    private var sectionReason: KubeMarkedAppsMode.Reason?
    private var listedReason: KubeMarkedAppsMode.Reason?
    /// Each bound workload as one GET settled it (A), and when each was
    /// last asked; asked in this read; its row's last change seen.
    private var settled: [KubeMarkedMember.ID: KubeMarkedSettled] = [:]
    private var settleLast: [KubeMarkedMember.ID: Date] = [:]
    private var settleAsked: Set<KubeMarkedMember.ID> = []
    private var settleTasks: [KubeMarkedMember.ID: Task<Void, Never>] = [:]
    private var rowChangedAt: [KubeMarkedMember.ID: Date] = [:]
    /// The Argo Rollouts past the read's 8, and those whose GET failed:
    /// their phase not read, said — never "not read yet" for good.
    private var settleSkipped: Set<KubeMarkedMember.ID> = []
    private var settleFailed: Set<KubeMarkedMember.ID> = []
    /// The binding namespace's Argo Rollouts as rows with their marks (a
    /// Rollout runs a Deployment of its own namespace only, by
    /// `workloadRef`): read once — one paged list, no watch — where Argo
    /// Rollouts are served and a bound Deployment of an app read from marks
    /// is scaled to 0; what was read of them, said for such a Deployment.
    private var rollouts: [KubeMarkedMember] = []
    private var rolloutsRead = KubeGitOpsMatch.RolloutsRead.notServed
    private var rolloutsAsked = false
    private var rolloutsDone = false
    /// The settle's GETs made since made (a test's).
    private(set) var settleGets = 0
    /// Whether a settle GET waits or is in flight (a test's).
    var settleAsking: Bool { !settleTasks.isEmpty }
    /// Whether option B's listing is being read (a test's).
    var readingMarks: Bool { marksReading }
    /// The binding namespace's Rollouts listed since made (a test's).
    private(set) var rolloutLists = 0

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
                guard let discovery = await self.discover(context, client: client, generation: generation) else { return }
                self.discovery = discovery
                let key = KubeGitOpsMatchCache.Key(
                    context: context.name, checkout: binding.checkout, namespace: binding.namespace, remotes: facts.remotesKey, mode: Self.mode(of: discovery))
                self.key = key
                if press { self.cache.press(key) }
                // The section's word only while it is fresh: one said hours ago is no answer now.
                self.sectionReason = self.kubernetes.marksReason(of: context)
                self.rolloutsRead = Self.rolloutKind(discovery) == nil ? .notServed : .unread("\(binding.namespace)'s Rollouts not read yet")
                self.updateMarksReason()
                self.updateWillRead()
                guard KubeGitOpsSummary.served(discovery) else {
                    // Argo CD may run in another cluster and deploy to this one: the
                    // workloads' own marks say its apps (no GET for a kind not served).
                    self.state = .unserved
                    self.readOwners()
                    self.listMarks(generation: generation)
                    return
                }
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
        listed = false
        workloads = []
        ownersNamed = []
        owned = [:]
        ownersAnswer = nil
        refetched = [:]
        lastGet = [:]
        asked = [:]
        questions = [:]
        reached = [:]
        marksListing = nil
        marksReading = false
        sectionReason = nil
        listedReason = nil
        settled = [:]
        settleLast = [:]
        settleAsked = []
        settleSkipped = []
        settleFailed = []
        rowChangedAt = [:]
        rollouts = []
        rolloutsRead = .notServed
        rolloutsAsked = false
        rolloutsDone = false
        state = .idle
        if !matches.isEmpty { matches = [] }
        searched = []
        problems = []
        willRead = ""
        if marksReason != nil { marksReason = nil }
        if marksSaid != MarksSaid() { marksSaid = MarksSaid() }
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
        for task in settleTasks.values { task.cancel() }
        settleTasks = [:]
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

    /// The binding's context, as the part names it.
    var contextName: String? { context?.name }

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

    /// Why the rail reads Argo CD's apps from marks across `discovery`'s
    /// cluster: Applications not served (argoproj.io answering, or not), or
    /// served and — as a GitOps section of this cluster last read them —
    /// none there or refused everywhere; nil otherwise (P4 then decides).
    nonisolated static func marksReason(_ discovery: KubeDiscovery, said: KubeMarkedAppsMode.Reason?) -> KubeMarkedAppsMode.Reason? {
        if case .only(let reason) = KubeMarkedAppsMode.of(discovery: discovery, applications: .notYetListed, marked: []) { return reason }
        if let said, said == .noApplications || said == .forbidden { return said }
        return nil
    }

    /// The reason as it stands (14.3: "not in" only from a whole read):
    /// discovery's; served, none listed or refused as the section said it
    /// in the last five minutes or B's own row of Applications found — but
    /// never once the rail's own reads hold an Application (P4's listing,
    /// P2's owners): Applications are here, and what deploys the checkout
    /// is theirs to say.
    private func updateMarksReason() {
        guard let discovery else { return }
        var reason = Self.marksReason(discovery, said: sectionReason ?? listedReason)
        if reason == .noApplications || reason == .forbidden, applicationsHeld { reason = nil }
        if marksReason != reason { marksReason = reason }
    }

    /// An Application among the rail's own reads: P4's listing, P2's owners.
    private var applicationsHeld: Bool {
        listing.objects.values.contains { $0.role == .application } || owned.values.contains { $0.role == .application }
    }

    /// Argo Rollouts as discovery serves them, listable.
    nonisolated static func rolloutKind(_ discovery: KubeDiscovery) -> KubeResourceKind? {
        discovery.kinds.first { $0.fullName == KubeMarkedAppsSession.rollouts && $0.canList }
    }

    // MARK: P1, P2: the owners

    /// The bound workloads as the panel's follows list them: their owners
    /// read (P2) when the set of owners changed; a member's row that
    /// changed noted, for its settle; B listed once a mark is first seen.
    func workloadsChanged(_ given: [Bound]) {
        let now = clock()
        var before: [KubeMarkedMember.ID: KubeMarkedMember] = [:]
        for bound in workloads { if let member = bound.member { before[member.id] = member } }
        for bound in given { if let member = bound.member, before[member.id] != member { rowChangedAt[member.id] = now } }
        let hadMarks = marksEvidence
        workloads = given
        guard discovery != nil else { return }
        if !hadMarks, marksEvidence { updateWillRead() }
        let owners = KubeGitOpsMatch.owners(given.map { ($0.ref, $0.owners) }).map(\.owner)
        if owners != ownersNamed {
            readOwners()
        } else {
            compute()
        }
        if !hadMarks, marksEvidence { listMarks(generation: generation) }
    }

    /// The bound workloads whose rows had events in a flush: one settled
    /// before (14.2.5) is read again when its generation moved, or when it
    /// wasn't Healthy — once every 15 s at most; readiness alone of a
    /// Healthy one, never.
    func rowsMoved(_ refs: Set<KubeWorkloadRef>) {
        guard !refs.isEmpty, discovery != nil else { return }
        for bound in workloads where refs.contains(bound.ref) {
            guard let member = bound.member, let was = settled[member.id], isDerived(bound) else { continue }
            let moved = member.marks.generation.map { $0 != was.generation } ?? false
            guard moved || was.status != .healthy else { continue }
            settleGet(member.id, kind: bound.ref.kind.kind)
        }
    }

    private func readOwners() {
        guard let client, let discovery else { return }
        let named = KubeGitOpsMatch.owners(workloads.map { ($0.ref, $0.owners) })
        ownersNamed = named.map(\.owner)
        ownerTask?.cancel()
        let generation = self.generation
        let namespace = binding?.namespace
        ownerTask = Task { [weak self] in
            guard let read = await Self.readOwners(named, client: client, discovery: discovery, namespace: namespace, now: Date()) else { return }
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            self.owned = read.objects
            self.ownersAnswer = read
            self.updateMarksReason()
            self.compute()
        }
    }

    /// What P2 read: the owners' objects, what each GET said, what couldn't be read.
    struct OwnersRead: Sendable {
        var objects: [KubeGitOpsObject.Key: KubeGitOpsObject] = [:]
        var reads: [KubeGitOpsOwner: KubeGitOpsMatch.OwnerRead] = [:]
        /// Each owner that couldn't be read, and why, in order.
        var unread: [(owner: KubeGitOpsOwner, said: String)] = []
        /// GETs made, of the read's 8.
        var spent = 0
        /// Plain names whose GET in `argocd` found nothing: not in this
        /// cluster only where its Applications were seen in `argocd`
        /// (14.2.5) — `resolved` says which.
        var unplaced: Set<KubeGitOpsOwner> = []
        /// Refused (403).
        var refused: Set<KubeGitOpsOwner> = []
        /// Their kind's group didn't answer discovery.
        var undiscovered: Set<KubeGitOpsOwner> = []

        /// What couldn't be read, said: the rail's problem lines, `k8s_gitops`' notes.
        var problems: [String] { unread.map(\.said) }
    }

    /// P2: each owner the workloads' marks name read by one GET, at most
    /// `ownerReads` objects with a Flux owner's source and chart — the
    /// rail's, and `k8s_gitops checkout`'s. Helm's own label names the
    /// Application only when it manages one of those workloads in
    /// `namespace`. A plain Argo CD name not found in `argocd` is left for
    /// `resolved` to place. Nil when cancelled.
    nonisolated static func readOwners(
        _ named: [(owner: KubeGitOpsOwner, workloads: [KubeWorkloadRef])], client: KubeClient, discovery: KubeDiscovery, namespace: String?,
        now: Date
    ) async -> OwnersRead? {
        var budget = ownerReads
        var read = OwnersRead()
        for (owner, refs) in named where budget > 0 {
            let key = KubeGitOpsMatch.key(of: owner)
            guard let kind = kind(of: key.kind, in: discovery) else {
                // Not served here: no GET, and not in this cluster — unless its
                // group failed to answer discovery, which says nothing.
                if let group = failedGroup(of: key.kind, in: discovery) {
                    read.reads[owner] = .unreadable
                    read.undiscovered.insert(owner)
                    read.unread.append((owner, "Couldn't read \(owner.said): \(group) didn't answer discovery"))
                } else {
                    read.reads[owner] = .absent
                }
                continue
            }
            budget -= 1
            read.spent += 1
            do {
                let data = try await client.get(kind.path(namespace: key.namespace, name: key.name), maxBytes: getBytes)
                var object = try await KubeBlocking.run { Result { try KubeGitOpsSummary.object(data, readAt: now) } }.get()
                // Helm's own label: the Application owns it only when it says so.
                if owner.mark == .appInstance, let namespace {
                    let managed = (try? await KubeBlocking.run { Result { try KubeGitOpsWire.managed(data) } }.get())?.status?.resources ?? []
                    if !refs.contains(where: { KubeGitOpsMatch.manages(managed, $0, namespace: namespace) }) { object = nil }
                }
                if let object {
                    read.objects[object.key] = object
                    read.reads[owner] = .present
                    // A Flux owner's source, and its chart's.
                    for upstream in KubeGitOpsLadder.upstream(object) where budget > 0 && read.objects[upstream] == nil {
                        budget -= 1
                        read.spent += 1
                        if let source = await get(upstream, client: client, discovery: discovery, now: now) {
                            read.objects[source.key] = source
                            for further in KubeGitOpsLadder.upstream(source) where budget > 0 && read.objects[further] == nil {
                                budget -= 1
                                read.spent += 1
                                if let found = await get(further, client: client, discovery: discovery, now: now) { read.objects[found.key] = found }
                            }
                        }
                    }
                } else {
                    read.reads[owner] = .absent
                }
            } catch let error as KubeAPIError where error.isNotFound {
                if owner.tool == .argoCD, owner.isCertain, owner.namespace == nil {
                    // A plain name, looked for in argocd: Argo CD's own namespace here may be another.
                    read.reads[owner] = .unreadable
                    read.unplaced.insert(owner)
                } else {
                    read.reads[owner] = .absent
                }
            } catch is CancellationError {
                return nil
            } catch {
                // Refused (403), failed, timed out: unknown — never "not in" the cluster.
                read.reads[owner] = .unreadable
                if let api = error as? KubeAPIError, api.isForbidden { read.refused.insert(owner) }
                read.unread.append((owner, "Couldn't read \(owner.said): \(KubernetesModel.said(error))"))
            }
        }
        return Task.isCancelled ? nil : read
    }

    /// A plain Argo CD name's 404 in `argocd` placed (14.2.5): not in this
    /// cluster where its Applications were seen in `argocd` — the page's
    /// section, the rail's own listing — or where none is here at all
    /// (`noApplications`); else unknown, said: Argo CD's own namespace here
    /// may be another.
    nonisolated static func resolved(_ read: OwnersRead, seen: Set<String>, noApplications: Bool) -> OwnersRead {
        var read = read
        let placed = noApplications || seen.contains(KubeGitOps.argoDefaultNamespace)
        for owner in read.unplaced.sorted(by: { $0.name < $1.name }) {
            if placed {
                read.reads[owner] = .absent
            } else {
                read.unread.append((owner, "\(owner.said) wasn't found in \(KubeGitOps.argoDefaultNamespace); Argo CD's namespace here is unknown"))
            }
        }
        if placed { read.unplaced = [] }
        return read
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

    // MARK: Apps from marks (14.2.5)

    /// Whether anything here carries Argo CD's marks: a bound workload's
    /// own, a list's rows on the page (`KubernetesModel.marksSeen`), the
    /// section's apps. Without, B lists nothing.
    private var marksEvidence: Bool {
        guard let context else { return false }
        return workloads.contains { $0.member?.marks.hasArgoMark == true } || kubernetes.marksSeen.contains(context.name)
            || freshSection(context) != nil
    }

    /// Whether B would read here: the rail reads from marks across the
    /// cluster, or Applications are served and may turn out none.
    private var marksWanted: Bool {
        guard let discovery else { return false }
        return marksReason != nil || KubePanelGitOps.kind(of: "Application", in: discovery) != nil
    }

    /// The section's apps of `context` ranked in the last five minutes.
    private func freshSection(_ context: KubeContext) -> KubernetesModel.MarkedAppsKept? {
        kubernetes.markedApps(of: context, now: clock())
    }

    /// The Argo CD owner a bound workload's own mark names, when it is sure.
    private static func argoOwner(_ bound: Bound) -> KubeGitOpsOwner? {
        bound.owners.first { $0.tool == .argoCD && $0.isCertain }
    }

    /// A bound workload of an app read from marks: its own Argo CD mark
    /// names an app whose Application isn't read present here (14.2.5),
    /// once its owner's read is known — or needs none (not served).
    private func isDerived(_ bound: Bound) -> Bool {
        guard let member = bound.member, member.marks.hasArgoMark, case .app = KubeMarkedApps.place(member.marks) else { return false }
        guard let owner = Self.argoOwner(bound) else { return marksReason != nil }
        guard let read = ownersAnswer?.reads[owner] else { return false }
        return read != .present
    }

    /// The settle (14.2.5): one GET of each, as the part first shows,
    /// settled by Argo CD's rule within what P2 left of the read's 8 — the
    /// bound apps' Argo Rollouts first (a Rollout's row has no health: its
    /// phase is its object's), then each bound workload of an app read from
    /// marks (a Deployment scaled to 0 where Rollouts are served only once
    /// the namespace's Rollouts were read and none of its app's is there: a
    /// Rollout's GET says that app's health, the Deployment's can't), then
    /// the Rollouts of the apps option B, C or D found. The rest stay "from
    /// its row" — a Rollout's phase said unread (`settleSkipped`). None for
    /// an app the section ranked in the last five minutes: its verdict is shown.
    private func settle(_ answered: KubeGitOpsMatch.MarkedAnswer) {
        guard let context, let discovery, ownersAnswer != nil else { return }
        let section = Set((freshSection(context)?.apps ?? []).map(\.app.key))
        let rolloutKind = Self.rolloutKind(discovery)
        let shown = (answered.found + answered.probably).filter { !section.contains($0.app.key) }
        var wanted: [(id: KubeMarkedMember.ID, kind: KubeResourceKind)] = []
        var runByRollout = Set<KubeTrackingID.AppKey>()
        if let rolloutKind {
            for entry in shown where entry.bound {
                for member in entry.app.members where member.id.kind == .rollout {
                    wanted.append((member.id, rolloutKind))
                    runByRollout.insert(entry.app.key)
                }
            }
        }
        for bound in workloads {
            guard let member = bound.member, member.id.kind.cellsMayHide, isDerived(bound), case .app(let key) = KubeMarkedApps.place(member.marks),
                !section.contains(key)
            else { continue }
            if rolloutKind != nil, member.id.kind == .deployment, member.health?.scaledToZero == true, !rolloutsDone || runByRollout.contains(key) { continue }
            wanted.append((member.id, bound.ref.kind.kind))
        }
        if let rolloutKind {
            for entry in shown where !entry.bound {
                for member in entry.app.members where member.id.kind == .rollout { wanted.append((member.id, rolloutKind)) }
            }
        }
        var left = Self.ownerReads - (ownersAnswer?.spent ?? 0) - settleAsked.count
        var skipped = Set<KubeMarkedMember.ID>()
        var seen = Set<KubeMarkedMember.ID>()
        for (id, kind) in wanted where seen.insert(id).inserted && settled[id] == nil && !settleAsked.contains(id) {
            guard left > 0 else {
                skipped.insert(id)
                continue
            }
            left -= 1
            settleAsked.insert(id)
            settleGet(id, kind: kind)
        }
        settleSkipped = skipped
    }

    /// The binding namespace's Argo Rollouts as rows with their marks, once
    /// a read — one paged list, no watch — where Rollouts are served and a
    /// bound Deployment of an app read from marks is scaled to 0 (the
    /// section's apps aside): the Rollout that runs it, by `workloadRef`,
    /// is its app's workload (14.12's second consequence), and a Rollout
    /// runs a Deployment of its own namespace only.
    private func readRollouts() {
        guard !rolloutsAsked, let client, let discovery, let binding, let context, let kind = Self.rolloutKind(discovery) else { return }
        let section = Set((freshSection(context)?.apps ?? []).map(\.app.key))
        let scaledToZero = workloads.contains { bound in
            guard let member = bound.member, member.id.kind == .deployment, member.health?.scaledToZero == true, isDerived(bound),
                case .app(let key) = KubeMarkedApps.place(member.marks)
            else { return false }
            return !section.contains(key)
        }
        guard scaledToZero else { return }
        rolloutsAsked = true
        rolloutLists += 1
        let namespace = binding.namespace
        let generation = self.generation
        tasks.append(
            Task { [weak self] in
                let read = await KubeMarkedAppsSession.readRows(kind, places: [namespace], client: client, bounds: Self.rolloutRows)
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                switch read {
                case .read(let rows, let refused, let cut, _):
                    let now = Date()
                    self.rollouts = rows.sorted.compactMap { KubeMarkedMember.row($0, kind: .rollout, columns: rows.columns, now: now) }
                    if !refused.isEmpty {
                        self.rolloutsRead = .unread("\(namespace)'s Rollouts can't be read (forbidden)")
                    } else if cut {
                        self.rolloutsRead = .unread("\(namespace)'s Rollouts read in part")
                    } else {
                        self.rolloutsRead = .read
                    }
                case .refusedAcross:
                    self.rolloutsRead = .unread("\(namespace)'s Rollouts can't be read (forbidden)")
                case .failed(let error):
                    if error is KubeProxyProblem { self.cache.drop(context: context.name) }
                    self.rolloutsRead = .unread("\(namespace)'s Rollouts couldn't be read")
                }
                self.rolloutsDone = true
                self.compute()
            })
    }

    /// An app's members as the rail's GETs settled them; an Argo Rollout
    /// past the read's 8 said so — its row has no health to stand in.
    private func settledApp(_ app: KubeMarkedApp) -> KubeMarkedApp {
        var app = app
        app.members = app.members.map { given in
            var member = settledMember(given)
            guard member.id.kind == .rollout, settled[member.id] == nil else { return member }
            if settleFailed.contains(member.id) {
                member.health = KubeMarkedHealth.Verdict(status: .unknown, sentence: "its phase couldn't be read")
            } else if settleSkipped.contains(member.id) {
                member.health = KubeMarkedHealth.Verdict(status: .unknown, sentence: "its phase not read: the rail reads \(Self.ownerReads) objects at most")
            }
            return member
        }
        return app
    }

    /// One bound workload's GET (`KubeMarkedWorkloadWire`), once every 15 s at most.
    private func settleGet(_ id: KubeMarkedMember.ID, kind: KubeResourceKind) {
        guard settleTasks[id] == nil, let client else { return }
        let wait = settleLast[id].map { max(0, Self.refetchEvery - clock().timeIntervalSince($0)) } ?? 0
        let generation = self.generation
        let path = kind.path(namespace: id.namespace, name: id.name)
        settleTasks[id] = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            let at = self.clock()
            self.settleLast[id] = at
            self.settleGets += 1
            let result: Result<KubeMarkedWorkloadWire, Error>
            do {
                let data = try await client.get(path, maxBytes: Self.getBytes)
                result = await KubeBlocking.run { Result { try KubeMarkedWorkloadWire.decode(data) } }
            } catch {
                result = .failure(error)
            }
            guard self.generation == generation, !Task.isCancelled else { return }
            self.settleTasks[id] = nil
            switch result {
            case .success(var wire):
                if wire.kind == nil { wire.kind = kind.kind }
                if wire.apiVersion == nil { wire.apiVersion = kind.groupVersion }
                self.settled[id] = KubeMarkedSettled(wire, at: at)
                self.settleFailed.remove(id)
            case .failure(let error as KubeAPIError) where error.isNotFound:
                self.settled[id] = nil
                self.settleFailed.insert(id)
            case .failure:
                // Refused, too large, failed: from its row, as before (a Rollout's phase said unread).
                self.settleFailed.insert(id)
            }
            self.compute()
        }
    }

    /// A member as its GET settled it, while that still says what its row
    /// does: the same generation, and no row turned not ready since.
    private func settledMember(_ member: KubeMarkedMember) -> KubeMarkedMember {
        guard let was = settled[member.id] else { return member }
        if let generation = member.marks.generation, let read = was.generation, generation != read { return member }
        if let changed = rowChangedAt[member.id], changed > was.at, let status = member.health?.status, status != .healthy { return member }
        return member.settled(by: was.wire, changedAt: rowChangedAt[member.id])
    }

    /// The words a listing of the workloads' marks that failed leaves among the searched lines.
    nonisolated static let marksFailed = "Couldn't list the workloads' marks"

    /// The searched lines once a listing of the workloads' marks ended:
    /// the last one's failure replaced by this one's outcome — said once,
    /// never left beside a listing that read (Refresh once the VPN is back).
    nonisolated static func searched(_ lines: [String], marksFailed error: String?) -> [String] {
        var kept = lines.filter { !$0.hasPrefix(marksFailed + ":") }
        if let error { kept.append("\(marksFailed): \(error)") }
        return kept
    }

    /// B: the cluster's marked workloads (or the section's apps) against
    /// the checkout's manifests — where the rail reads from marks and
    /// something here carries one. Where Applications are served, only
    /// once P4's listing is in and the rail's own reads hold none —
    /// whatever a section said, which only spares B its one row of them
    /// asked across the cluster. On production, only once Find What
    /// Deploys This was pressed (decision 11).
    private func listMarks(generation: Int, force: Bool = false) {
        guard let key, let context, let binding, let client, let discovery, let facts, marksEvidence, !marksReading else { return }
        let served = Self.kind(of: "Application", in: discovery) != nil
        if served {
            guard listed, !applicationsHeld else { return }
        }
        // Not served: discovery's reason; served, the section's fresh word, else B asks.
        let known = served ? sectionReason : marksReason
        if !force, let kept = cache.marked(key) {
            marksListing = kept
            listedReason = kept.reason
            updateMarksReason()
            return compute()
        }
        if context.isProduction, !cache.isPressed(key) {
            if case .failed = state {} else { state = .waiting(willRead) }
            return compute()
        }
        if case .waiting = state { state = KubeGitOpsSummary.served(discovery) ? .reading : .unserved }
        var section: (apps: [KubeMarkedApp], at: Date)?
        if let kept = freshSection(context), kept.scope == .all, kept.whole { section = (kept.apps.map(\.app), kept.at) }
        let accessible = context.settings.accessibleNamespaces
        let git = checkouts.git
        let bounds = markedRowsBounds
        marksReading = true
        tasks.append(
            Task { [weak self] in
                let read = await Self.markedListing(
                    client: client, discovery: discovery, checkout: facts, namespace: binding.namespace, reason: known, accessible: accessible, section: section,
                    git: git, bounds: bounds)
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.marksReading = false
                var failed: String?
                switch read {
                case .success(let found?):
                    self.cache.keep(found, for: key)
                    self.marksListing = found
                    self.listedReason = found.reason
                    self.updateMarksReason()
                case .success(nil):
                    // Applications are here: what deploys the checkout is theirs to say.
                    self.marksListing = nil
                    self.listedReason = nil
                    self.updateMarksReason()
                case .failure(let error):
                    if error is KubeProxyProblem { self.cache.drop(context: context.name) }
                    failed = KubernetesModel.said(error)
                }
                let searched = Self.searched(self.searched, marksFailed: failed)
                if searched != self.searched { self.searched = searched }
                self.compute()
            })
    }

    // MARK: P3, P4: the lists across the cluster

    /// Where Applications are listed: Argo CD's namespace, those the page
    /// saw them in, the binding's.
    private func argoNamespaces(_ binding: KubeBinding) -> [String] { Self.argoNamespaces(binding, cache: cache) }

    /// The rail's, and `k8s_gitops checkout`'s: Argo CD's own, those the page saw them in, the binding's.
    static func argoNamespaces(_ binding: KubeBinding, cache: KubeGitOpsMatchCache) -> [String] {
        let seen = cache.seenApplications(binding.context).sorted()
        var names: Set<String> = []
        return ([KubeGitOps.argoDefaultNamespace] + seen + [binding.namespace]).filter { names.insert($0).inserted }
    }

    /// Find What Deploys This' label, as what would be read stands now.
    private func updateWillRead() {
        guard let discovery, let context, let binding else { return }
        willRead = Self.willRead(discovery, context: context.name, seen: argoNamespaces(binding), marks: marksWanted && marksEvidence)
        if case .waiting = state { state = .waiting(willRead) }
    }

    /// "lists Applications in argocd and shop and GitRepositories on
    /// fake-prod, then what takes from a match" — and, `marks`, the
    /// workloads' marks to compare with the checkout's manifests (14.2.5).
    static func willRead(_ discovery: KubeDiscovery, context: String, seen: [String], marks: Bool = false) -> String {
        var parts: [String] = []
        if kind(of: "Application", in: discovery) != nil { parts.append("Applications in \(seen.joined(separator: ", "))") }
        if kind(of: "GitRepository", in: discovery) != nil { parts.append("GitRepositories") }
        if kind(of: "OCIRepository", in: discovery) != nil { parts.append("OCIRepositories") }
        let said = parts.isEmpty ? "" : "lists \(parts.joined(separator: " and ")) on \(context), then what takes from a match"
        guard marks else { return said }
        let named = KubeMarkedReading.joined(KubeMarkedAppsSession.kinds(discovery).workloads.map(KubeKindCatalog.title(of:)))
        let kinds = named.isEmpty ? "the workloads" : named
        let compared = "with Argo CD's marks, to compare with this checkout's manifests"
        if said.isEmpty { return "lists \(kinds) on \(context) \(compared)" }
        if parts.first?.hasPrefix("Applications") == true { return said + "; where no Application is there, its \(kinds) \(compared)" }
        return said + "; and its \(kinds) \(compared)"
    }

    private func list(generation: Int, force: Bool = false) {
        guard let key, let context, let binding, let client, let discovery, let facts else { return }
        if !force, let kept = cache.listing(key) {
            listing = kept
            listed = true
            searched = kept.searched
            updateMarksReason()
            compute()
            return listMarks(generation: generation)
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
                    self.listed = true
                    self.searched = listing.searched
                    // Applications listed here: a section's "none here" is no answer now.
                    self.updateMarksReason()
                    self.compute()
                    self.listMarks(generation: generation)
                case .failure(let error):
                    if error is KubeProxyProblem { self.cache.drop(context: context.name) }
                    self.state = .failed("Couldn't look for what deploys this: \(KubernetesModel.said(error))")
                }
            })
    }

    /// Find What Deploys This (production): the lists across the cluster, now.
    func find() {
        guard let key, let discovery else { return }
        cache.press(key)
        if KubeGitOpsSummary.served(discovery) { list(generation: generation) } else { listMarks(generation: generation) }
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
        ownersNamed = []
        asked = [:]
        listed = false
        marksListing = nil
        marksReading = false
        listedReason = nil
        settled = [:]
        settleLast = [:]
        settleAsked = []
        settleSkipped = []
        settleFailed = []
        rollouts = []
        rolloutsAsked = false
        rolloutsDone = false
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
    ///
    /// `objects`/`bytes` given (`k8s_gitops checkout`'s 200 or 16 MB), they
    /// are a kind's across every place it is read in — Applications in each
    /// Argo CD namespace, a refused Flux kind namespace by namespace — and
    /// the places past it are said, not read (gitops.md 6.1). Not given, each
    /// place reads the section's own bound (the rail's).
    nonisolated static func listing(
        client: KubeClient, discovery: KubeDiscovery, checkout: KubeGitOpsMatch.Checkout, namespace: String, argo: [String],
        objects: Int? = nil, bytes: Int? = nil
    ) async -> Result<KubeGitOpsMatchCache.Listing, Error> {
        let stopAfter = objects ?? KubeGitOpsSession.kindObjects
        let totalBytes = bytes ?? KubeGitOpsSession.kindBytes
        let shared = objects != nil || bytes != nil
        func budget() -> KubeGitOpsBudget { KubeGitOpsBudget(objects: stopAfter, bytes: totalBytes, shared: shared) }
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
                    paged = try await client.pagedObjects(kind, in: nil, stopAfter: min(ociObjects, stopAfter), totalBytes: min(ociBytes, totalBytes), readAt: now)
                } catch let error as KubeAPIError where error.isForbidden {
                    paged = try await client.pagedObjects(kind, in: flux, stopAfter: min(ociObjects, stopAfter), totalBytes: min(ociBytes, totalBytes), readAt: now)
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
                var budget = budget()
                for place in argo where budget.allows(place) {
                    let left = budget.left
                    do {
                        let paged = try await client.pagedObjects(kind, in: place, stopAfter: left.objects, totalBytes: left.bytes, readAt: now)
                        budget.spend(paged)
                        if let cut = paged.cut { listing.searched.append("searched \(cut) in \(place)") }
                        for object in paged.objects { listing.objects[object.key] = object }
                    } catch let error as KubeAPIError where error.isForbidden || error.isNotFound {
                        refused.append(place)
                    }
                }
                if !refused.isEmpty { listing.searched.append("Applications: refused in \(refused.joined(separator: ", "))") }
                if let said = budget.said(KubeKindCatalog.title(of: kind)) { listing.searched.append(said) }
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
                        let paged = try await client.pagedObjects(kind, in: nil, stopAfter: stopAfter, totalBytes: totalBytes, readAt: now)
                        if let cut = paged.cut { listing.searched.append("searched \(cut)") }
                        objects = paged.objects
                    } catch let error as KubeAPIError where error.isForbidden {
                        var seen: Set<String> = []
                        var budget = budget()
                        var readIn: [String] = []
                        for place in places where seen.insert(place).inserted && budget.allows(place) {
                            let left = budget.left
                            readIn.append(place)
                            guard let paged = try? await client.pagedObjects(kind, in: place, stopAfter: left.objects, totalBytes: left.bytes, readAt: now) else { continue }
                            budget.spend(paged)
                            if let cut = paged.cut { listing.searched.append("searched \(cut) in \(place)") }
                            objects += paged.objects
                        }
                        let title = KubeKindCatalog.title(of: kind)
                        listing.searched.append("\(title): forbidden across the cluster; read in \(readIn.sorted().joined(separator: ", "))")
                        if let said = budget.said(title) { listing.searched.append(said) }
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

    /// B (14.2.5): the cluster's marked workloads as rows with their marks
    /// (`KubeMarkedAppsSession.kinds`' workloads, Argo Rollouts first — the
    /// fewest, and the only health of the apps they run —, paged, no watch,
    /// within `markedRows` for every kind together, each read with what the
    /// ones before it left; refused across the cluster, read in the
    /// context's accessible namespaces, else the binding's), or the
    /// section's apps when it read them whole across the cluster in the
    /// last five minutes (no request); then the checkout's manifests, set
    /// against them off the main thread. `reason` nil: Applications are
    /// served and P4 found none — one row of them asked across the cluster
    /// first; some there, nil (what deploys the checkout is theirs to say).
    nonisolated static func markedListing(
        client: KubeClient, discovery: KubeDiscovery, checkout: KubeGitOpsMatch.Checkout, namespace: String, reason known: KubeMarkedAppsMode.Reason?,
        accessible: [String], section: (apps: [KubeMarkedApp], at: Date)?, git: @escaping KubeGitOpsCheckouts.Runner, bounds rowsBound: KubeMarkedAppsSession.Bounds = markedRows
    ) async -> Result<KubeGitOpsMatch.MarkedListing?, Error> {
        var reason: KubeMarkedAppsMode.Reason
        if let known {
            reason = known
        } else {
            guard let asked = await KubeManifestRun.applicationsHere(discovery, client: client), asked == .noApplications || asked == .forbidden else {
                return .success(nil)
            }
            reason = asked
        }
        var apps: [KubeMarkedApp] = []
        var notes: [String] = []
        let workloads = KubeMarkedAppsSession.kinds(discovery).workloads
        let kinds = workloads.filter { $0.fullName == KubeMarkedAppsSession.rollouts } + workloads.filter { $0.fullName != KubeMarkedAppsSession.rollouts }
        var rollouts: KubeGitOpsMatch.RolloutsRead = kinds.contains { $0.fullName == KubeMarkedAppsSession.rollouts } ? .read : .notServed
        if let section {
            // Apps grouped by app.kubernetes.io/instance alone are only probably
            // Argo CD's (D-5): never said where Argo CD runs, so never here.
            // Every workload kind's rows read whole across the cluster: Rollouts too.
            apps = section.apps.filter { $0.mark != .appInstance }
        } else {
            var members: [KubeMarkedMember] = []
            // One bound for every kind: each read with what the ones before it left.
            var left = (objects: rowsBound.rowsObjects, bytes: rowsBound.rowsBytes)
            for kind in kinds {
                guard !Task.isCancelled else { return .failure(CancellationError()) }
                let title = KubeKindCatalog.title(of: kind)
                let isRollouts = kind.fullName == KubeMarkedAppsSession.rollouts
                guard left.objects > 0, left.bytes > 0 else {
                    let rows = rowsBound.rowsObjects
                    notes.append("\(title) not read: \(rows.formatted()) \(rows == 1 ? "row" : "rows") or \(rowsBound.rowsBytes >> 20) MB read already")
                    if isRollouts { rollouts = .unread("the cluster's Rollouts not read") }
                    continue
                }
                var bounds = rowsBound
                bounds.rowsObjects = left.objects
                bounds.rowsBytes = left.bytes
                var read = await KubeMarkedAppsSession.readRows(kind, places: [nil], client: client, bounds: bounds)
                if case .refusedAcross = read {
                    let places = accessible.isEmpty ? [namespace] : accessible
                    read = await KubeMarkedAppsSession.readRows(kind, places: places, client: client, bounds: bounds)
                    notes.append("\(title) refused across the cluster; read in \(places.joined(separator: ", "))")
                    if isRollouts { rollouts = .unread("the cluster's Rollouts read in part") }
                }
                switch read {
                case .read(let rows, let refused, let cut, let bytes):
                    left.objects -= rows.count
                    left.bytes -= bytes
                    if !refused.isEmpty { notes.append("\(title) refused in \(refused.count) \(refused.count == 1 ? "namespace" : "namespaces") (\(refused.joined(separator: ", ")))") }
                    if cut { notes.append("\(title): the list stopped at \(rows.count.formatted())") }
                    if isRollouts, !refused.isEmpty || cut { rollouts = .unread("the cluster's Rollouts read in part") }
                    let now = Date()
                    for row in rows.sorted {
                        if let member = KubeMarkedMember.row(row, kind: KubeMarkedKind(kind), columns: rows.columns, now: now) { members.append(member) }
                    }
                case .refusedAcross:
                    notes.append("\(title) refused across the cluster")
                    if isRollouts { rollouts = .unread("the cluster's Rollouts can't be read (forbidden)") }
                case .failed(let error):
                    if error is KubeProxyProblem || error is CancellationError { return .failure(error) }
                    notes.append("\(title) not read: \(KubernetesModel.said(error))")
                    if isRollouts { rollouts = .unread("the cluster's Rollouts couldn't be read") }
                }
            }
            let grouped = KubeMarkedApps.group(members)
            apps = grouped.isProbable ? [] : grouped.apps
        }
        let manifests = await KubeCheckoutManifests.read(checkout.root, git: git)
        let made = apps
        let said = notes
        let found = reason
        let at = section?.at
        let read = rollouts
        let listing = await KubeBlocking.run {
            KubeGitOpsMatch.markedListing(
                made, manifests: manifests, checkout: checkout, namespace: namespace, reason: found, notes: said, whole: said.isEmpty, rollouts: read, fromSection: at)
        }
        return .success(listing)
    }

    // MARK: What is shown

    /// The matches from every object held; only theirs ranked (each
    /// against all it holds — its source, its dependencies), a handful,
    /// not the whole listing at every row flip of a rollout. Beside them,
    /// the apps read from marks (14.2.5): A from the bound workloads, B, C
    /// and D from the listing — an Argo CD owner whose Application isn't
    /// read here said as its app, with its health, in place of "not in".
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
        // A plain name's 404 in argocd: placed by where Applications were seen —
        // "none here" only while the rail's own reads hold no Application.
        var seen = cache.seenApplications(context.name)
        for object in listing.objects.values where object.role == .application { if let namespace = object.ref.namespace { seen.insert(namespace) } }
        let answer = ownersAnswer.map { Self.resolved($0, seen: seen, noApplications: marksReason == .noApplications && !applicationsHeld) }
        let reads = answer?.reads ?? [:]
        // An owner not read yet says nothing yet.
        let owners = KubeGitOpsMatch.owners(workloads.map { ($0.ref, $0.owners) }).compactMap { owner, refs in
            reads[owner].map { (owner: owner, workloads: refs, read: $0) }
        }
        var found = KubeGitOpsMatch.found(
            owned: owners, objects: objects, workloads: workloads.map { ($0.ref, $0.images) }, checkout: facts, context: context.name)
        let now = clock()

        // A: the bound workloads whose own marks name an app whose Application isn't
        // read present here, with their apps' Argo Rollouts in the binding's namespace.
        readRollouts()
        var bound: [(member: KubeMarkedMember, ref: KubeWorkloadRef, owner: KubeGitOpsOwner?)] = []
        var boundKeys = Set<KubeTrackingID.AppKey>()
        for workload in workloads where isDerived(workload) {
            guard let member = workload.member else { continue }
            bound.append((settledMember(member), workload.ref, Self.argoOwner(workload)))
            if case .app(let key) = KubeMarkedApps.place(member.marks) { boundKeys.insert(key) }
        }
        let theirRollouts = rollouts.filter { rollout in
            if case .app(let key) = KubeMarkedApps.place(rollout.marks) { boundKeys.contains(key) } else { false }
        }
        let grouped = KubeMarkedApps.group(bound.map(\.member) + theirRollouts).apps
        var boundApps: [(app: KubeMarkedApp, workloads: [KubeWorkloadRef])] = []
        var ownerOf: [KubeTrackingID.AppKey: KubeGitOpsOwner] = [:]
        for app in grouped {
            let ids = Set(app.members.map(\.id))
            let mine = bound.filter { ids.contains($0.member.id) }
            boundApps.append((app, mine.map(\.ref)))
            if let owner = mine.compactMap(\.owner).first { ownerOf[app.key] = owner }
        }
        let answered = KubeGitOpsMatch.marked(bound: boundApps, listing: marksListing)
        // Their owners' "not in" lines are theirs now, and what their place says, said once.
        let replaced = Set(ownerOf.values.map { KubeGitOpsMatch.key(of: $0) })
        found.removeAll { replaced.contains($0.key) && $0.whys.allSatisfy { if case .notInCluster = $0 { true } else { false } } }
        let derivedOwners = Set(ownerOf.values)
        let problems = (answer?.unread ?? []).filter { entry in
            guard derivedOwners.contains(entry.owner) else { return true }
            // Said by its place — refused, its group not answering, not found in argocd; any other failure stays.
            return
                !(answer?.refused.contains(entry.owner) == true || answer?.undiscovered.contains(entry.owner) == true
                || answer?.unplaced.contains(entry.owner) == true)
        }.map(\.said)
        if problems != self.problems { self.problems = problems }

        // Each one's GET within the read's 8, before their health is said.
        settle(answered)
        let section = freshSection(context)
        func derived(_ entry: KubeGitOpsMatch.MarkedFound) -> Match {
            let app = settledApp(entry.app)
            let health: KubeMarkedHealth.AppVerdict
            let scope: KubeGitOpsMatch.MarkedScope
            if let section, let ranked = section.apps.first(where: { $0.app.key == app.key }) {
                health = ranked.health
                scope = .section(section.at)
            } else if entry.bound {
                health = KubeGitOpsMatch.health(app, rollouts: rolloutsRead)
                let rollouts = app.members.count { $0.id.kind == .rollout }
                scope = .bound(app.members.count - rollouts, rollouts: rollouts, elsewhere: elsewhere(app), whole: marksListing?.whole ?? true)
            } else {
                health = KubeGitOpsMatch.health(app, rollouts: marksListing?.rollouts ?? .notServed)
                scope = .listed(app.members.count)
            }
            let marked = Marked(app: app, health: health, scope: scope, place: place(app.key, owner: ownerOf[app.key], answer: answer), probable: entry.probable)
            return Match(key: KubeGitOpsObject.Key(kind: "Marks", namespace: nil, name: app.id), object: nil, whys: entry.whys, marked: marked)
        }
        let fromMarks = answered.found.map(derived).sorted(by: Self.rankedMarks)
        let probably = answered.probably.map(derived).sorted(by: Self.rankedMarks)
        let marksSaid = MarksSaid(tooMany: answered.tooMany, nothing: answered.nothing, caveats: answered.caveats)
        if marksSaid != self.marksSaid { self.marksSaid = marksSaid }

        let plain = found.map { found in
            Match(
                key: found.key, object: objects[found.key].map { KubeGitOpsSummary.evaluated($0, now: now, peers: objects) }, whys: found.whys,
                tracks: found.tracks, reach: reached[found.key])
        }
        let withObjects = plain.filter { $0.object != nil }.sorted { KubeGitOpsSummary.ordered($0.object!, $1.object!) }
        let without = plain.filter { $0.object == nil }.sorted { $0.id < $1.id }
        let new = withObjects + fromMarks + without + probably
        if new != matches { matches = new }
        switch state {
        case .waiting, .failed: break
        default:
            let served = discovery.map(KubeGitOpsSummary.served) ?? true
            state = served ? .live : .unserved
        }
        followLive()
        reach(objects: objects, facts: facts)
    }

    /// Apps from marks in the order the section shows them: problems first, then by name.
    private static func rankedMarks(_ a: Match, _ b: Match) -> Bool {
        let first = a.marked?.health.state ?? .unknown
        let second = b.marked?.health.state ?? .unknown
        return first != second ? first < second : a.said < b.said
    }

    /// An app's other members, as option B listed them, by namespace — nil
    /// when nothing listed the app (B not run, its rows cut or refused
    /// before it, or listed before it came): "other namespaces not read";
    /// empty when all are bound here.
    private func elsewhere(_ app: KubeMarkedApp) -> [String: Int]? {
        guard let listing = marksListing, let listed = listing.members[app.key] else { return nil }
        let mine = Set(app.members.map(\.id))
        var counts: [String: Int] = [:]
        for id in listed where !mine.contains(id) { counts[id.namespace ?? "the cluster", default: 0] += 1 }
        return counts
    }

    /// Where an app's Application stands, as far as can be said: the
    /// rail's reason across the cluster, else its owner's read.
    private func place(_ key: KubeTrackingID.AppKey, owner: KubeGitOpsOwner?, answer: OwnersRead?) -> KubeGitOpsMatch.MarkedPlace {
        if let reason = marksReason { return .reason(reason) }
        guard let owner, let answer else { return .unread }
        if answer.undiscovered.contains(owner) { return .reason(.undiscovered) }
        if answer.refused.contains(owner) { return .refused }
        if answer.unplaced.contains(owner) { return .notFound }
        return answer.reads[owner] == .absent ? .absent : .unread
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
        if match.marked != nil { return openMarked(match) }
        guard let ref = ref(match), let host else { return }
        Task { await host.gitOpsOpenOnPage(ref) }
    }

    /// Open on an app read from marks: its detail on the page (14.2.3) —
    /// it has no object, so no list of a kind to open it in.
    func openMarked(_ match: Match) {
        guard let marked = match.marked, let context, let host else { return }
        let ref = KubeMarkedDetailRef(context: context.name, key: marked.app.key)
        let namespaces = marked.app.namespaces
        Task { await host.gitOpsOpenMarked(ref, namespaces: namespaces) }
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
