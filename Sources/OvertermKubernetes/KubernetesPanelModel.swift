import Combine
import Foundation

/// A window's Kubernetes panel in the rail (docs/design/kubernetes/analysis.md,
/// Section 6 and 3.1–3.2): the selected tab's checkout, what it is bound
/// to, that namespace's workloads and pods with their health, the forwards
/// there, and each workload's deployed commit against the checkout's.
/// A pod picked shows in the right slot (`KubeSlotView`).
///
/// **It reads nothing while it is not the panel on screen** (`SidebarModel`'s
/// rule, as Overgit's): the window says when (`panelVisible`); until then
/// no file of the checkout is read for a guess, no kubeconfig, no cluster.
/// Shown with a binding, it follows the bound namespace's Deployments,
/// StatefulSets (DaemonSets when one is bound) and Pods — Table rows only,
/// the binding's label selector sent to the server — through the
/// context's proxy in a background slot, never the page's; hidden, every
/// watch ends and the rows go, so nothing stale is shown as current. Watch
/// events are applied in batches every `flushInterval`, as the page's; a
/// kind that can't be listed (a 403, the proxy closed for the page's
/// slot) says so while the others show, and is followed again after a
/// wait. The pod picked in the right slot outlives the panel hiding — its
/// reads follow the slot and the window — and goes when the binding does.
/// The workloads' rows carry their metadata there, so their Argo CD or
/// Flux owners are known (`KubeListOptions.owners`), and Argo CD's marks
/// by their allow-list (`.marks`: an app read from them where its
/// Application isn't read here, gitops.md 14.2.5); what deploys the
/// checkout is `gitOps`'s (`KubePanelGitOps`, gitops.md 4), started and
/// stopped with these follows. Its own follows (at most 4, rows only) take
/// the rail's to at most 8, all on the background slot — on-screen reads,
/// not attention watches: none counts against `kubernetes.backgroundWatches`,
/// and the page takes the slot first when it needs one.
/// Reads only: every request is a GET.
@MainActor
package final class KubernetesPanelModel: ObservableObject {
    package enum State: Equatable {
        case idle
        case reading
        case live
        case failed(String)
    }

    /// One bound workload, as its row says it.
    package struct Workload: Identifiable, Equatable {
        package var ref: KubeWorkloadRef
        package var health: String
        package var failing: Bool
        package var images: [String]
        /// The Argo CD or Flux objects its marks name (`KubeRow.owners`).
        package var owners: [KubeGitOpsOwner] = []
        /// Argo CD's marks on it and its health from its row
        /// (`KubeRow.marks`): what the rail reads an app from where its
        /// Application isn't read here (gitops.md 14.2.5).
        package var member: KubeMarkedMember?
        package var id: String { ref.said }

        /// As the rail's GitOps part takes it.
        package var bound: KubePanelGitOps.Bound { KubePanelGitOps.Bound(ref: ref, owners: owners, images: images, member: member) }
    }

    /// One of its pods.
    package struct Pod: Identifiable, Equatable {
        package var summary: KubePodSummary

        package init(summary: KubePodSummary) {
            self.summary = summary
        }
        package var id: KubeRowID { summary.id }
    }

    /// The selected tab's checkout (`Tab.checkoutSource`'s root, as the
    /// diff and agents' tools have it).
    @Published package var checkout: URL? {
        didSet { if checkout != oldValue { checkoutChanged() } }
    }
    /// Whether the sidebar shows the panel now (the window says).
    @Published package var panelVisible = false {
        didSet { if panelVisible != oldValue { visibilityChanged() } }
    }
    /// Whether the right slot shows the pod picked now (the window says).
    @Published package var slotVisible = false {
        didSet { if slotVisible != oldValue { updateSlot() } }
    }
    /// Whether the window is on screen at all (a covered or minimized one
    /// reads nothing, the slot's log included).
    @Published package var windowVisible = true {
        didSet { if windowVisible != oldValue { updateSlot() } }
    }
    @Published package private(set) var binding: KubeBinding?
    /// What the checkout's files say, read once it shows unbound.
    @Published package private(set) var guess: KubeBindingGuess?
    @Published package private(set) var guessing = false
    /// Whether the checkout is a repository's root, the only folder the
    /// guess reads and Bind is offered for (`KubeCheckoutScan.isRepositoryRoot`).
    @Published package private(set) var canBind = false
    /// The binding being made or edited in the panel.
    @Published package var draft: KubeBinding?
    @Published package private(set) var state: State = .idle
    @Published package private(set) var workloads: [Workload] = []
    @Published package private(set) var pods: [Pod] = []
    /// The pods not listed (past `podLimit`): the page has them.
    @Published package private(set) var podsHidden = 0
    /// The kinds that couldn't be listed, and why — the others still show.
    @Published package private(set) var problems: [String] = []
    /// Each workload's deployed commit against the checkout, by its id.
    @Published package private(set) var deployed: [String: KubeDeployedAnswer] = [:]
    /// The workloads whose revision label (or appVersion) is being asked for.
    @Published package private(set) var lookingUp: Set<String> = []
    /// What asking for one couldn't do.
    @Published package var lookUpProblem: String?
    /// Whether the bound context is production (its band).
    @Published package private(set) var production = false
    /// The pod in the right slot.
    @Published package private(set) var picked: KubeRowID?
    @Published package private(set) var session: KubeDetailSession?
    @Published package var slotTab: SlotTab = .logs
    /// The bound release against the checkout's chart: Diff Chart with
    /// Release, Upgrade… (made when first asked; it goes with the binding).
    @Published package private(set) var helmUpgrade: KubeHelmUpgradeSession?
    /// Asked of the window for the upgrade's sheet, its tab and its diff.
    package weak var helmHost: KubeHelmUpgradeHost?
    /// What deploys the checkout: Argo CD's and Flux's objects (gitops.md 4).
    package let gitOps: KubePanelGitOps
    /// Asked of the window for a GitOps verb: the page's guard path.
    package weak var gitOpsHost: KubeGitOpsPanelHost? {
        didSet { gitOps.host = gitOpsHost }
    }

    package enum SlotTab: String, CaseIterable, Identifiable {
        case logs = "Logs"
        case overview = "Overview"
        package var id: String { rawValue }
    }

    package let store: KubeBindingStore
    package let kubernetes: KubernetesModel
    /// The cluster's pulse in the rail: warnings, nodes (`KubePanelPulse`).
    package let pulse = KubePanelPulse()
    /// Asked of the window: a review tab for a range in the checkout.
    package var openReview: (ReviewSource, URL) -> Void = { _, _ in }
    /// Asked of the window: the right slot on the pod picked.
    package var showSlot: () -> Void = {}
    /// The user's docker, for an image's revision label (nil in an isolated
    /// run unless a scenario set one: tests never reach the user's Docker).
    package var revisionCLI: () -> DockerCLI? = { DockerImageUpdates.defaultCLI(nil) }
    /// A test's way of reading the revision label instead of the CLI.
    package var inspectRevision: ((String) async -> String?)?
    /// The context, its client: the proxy's background slot (a test's connection instead).
    package var clientFor: ((KubeContext) -> KubeClient)?

    /// At most this many pods are listed: failing ones first, the rest
    /// by name. A binding with no selector covers the whole namespace.
    package static let podLimit = 50
    /// Watch events are applied at most this often.
    package var flushInterval: Duration = .milliseconds(120)
    /// The waits before a kind that failed is followed again (the last one repeated).
    package var retryDelays: [Duration] = [1, 2, 4, 8, 15, 30].map { .seconds($0) }

    private var rows: [String: KubeRows] = [:]
    private var follows: [String: Task<Void, Never>] = [:]
    /// The kinds followed, by full name, and the ones that failed (why, and how often).
    private var followed: [KubeResourceKind] = []
    private var failed: [String: (said: String, failures: Int)] = [:]
    private var pending: [(String, KubeFollowUpdate)] = []
    private var flushing: Task<Void, Never>?
    /// What a follow needs to be started again.
    private var following: (binding: KubeBinding, context: KubeContext, checkout: URL)?
    private var generation = 0
    private var bindingChanges: AnyCancellable?
    private var guessed: URL?
    /// The answers' keys: a workload's images and what was asked, so a
    /// watch event that changes nothing about them runs no git.
    private var answered: [String: String] = [:]
    /// An image's revision label: the image's own, whichever checkout asks.
    private var revisions: [String: String] = [:]
    /// A release's appVersion, by its binding's context, namespace and
    /// release (`releaseKey`): never another binding's.
    private var appVersions: [String: String] = [:]
    /// The look-up running for a workload: only its own end clears it.
    private var lookUps: [String: UUID] = [:]

    package init(
        store: KubeBindingStore = .shared, kubernetes: KubernetesModel = .shared, gitOpsCache: KubeGitOpsMatchCache = .shared,
        gitOpsCheckouts: KubeGitOpsCheckouts = .shared
    ) {
        self.store = store
        self.kubernetes = kubernetes
        gitOps = KubePanelGitOps(kubernetes: kubernetes, cache: gitOpsCache, checkouts: gitOpsCheckouts)
        bindingChanges = store.$bindings.dropFirst().sink { [weak self] _ in
            // @Published emits before the value lands.
            DispatchQueue.main.async { self?.bindingMayHaveChanged() }
        }
        gitOps.openReview = { [weak self] source, root in self?.openReview(source, root) }
    }

    // MARK: The checkout and its binding

    private func checkoutChanged() {
        guess = nil
        guessed = nil
        draft = nil
        canBind = checkout.map { KubeCheckoutScan.isRepositoryRoot($0) } ?? false
        bindingMayHaveChanged(force: true)
    }

    private func bindingMayHaveChanged(force: Bool = false) {
        let now = panelVisible || force ? store.binding(for: checkout) : binding
        guard force || now != binding else { return }
        // The checkout's own binding edited or removed (not another checkout's
        // shown): what the rail listed for it is dropped (gitops.md 4.4).
        if let old = binding, old != now, let checkout, old.checkout == KubeBindingStore.key(checkout) {
            gitOps.cache.drop(binding: old)
            if let now { gitOps.cache.drop(binding: now) }
        }
        binding = now
        if let session = helmUpgrade, session.binding != now || session.checkout != checkout { helmUpgrade = nil }
        // The pod picked stays while the namespace it is in is still the bound one.
        if let session, session.ref.context != now?.context || (session.ref.namespace != now?.namespace) { closeSlot() }
        restart()
    }

    private func visibilityChanged() {
        if panelVisible {
            bindingMayHaveChanged(force: true)
        } else {
            stop()
        }
    }

    /// The kubeconfig's contexts, for the binding's picker (read when editing starts).
    @Published package private(set) var contextNames: [String] = []

    /// Starts editing: the binding there, else the guess with the page's
    /// context (if it isn't production), else the first one that isn't.
    /// The kubeconfig is read now, locally — no cluster is asked.
    package func beginEdit() {
        guard let checkout, binding != nil || canBind else { return }
        let kubernetes = self.kubernetes
        Task { [weak self] in
            let contexts = await kubernetes.contextsForAgents()?.contexts ?? []
            guard let self, self.checkout == checkout else { return }
            self.contextNames = contexts.map(\.name)
            if let binding = self.binding { return self.draft = binding }
            let pick =
                kubernetes.selected.flatMap { $0.isProduction ? nil : $0.name } ?? contexts.first { !$0.isProduction }?.name ?? contexts.first?.name
                ?? ""
            self.draft = (self.guess ?? KubeBindingGuess()).binding(checkout: checkout, context: pick)
        }
    }

    package func cancelEdit() { draft = nil }

    /// The draft kept: the checkout bound.
    @discardableResult
    package func saveDraft() -> Bool {
        guard let draft else { return false }
        guard store.set(draft) else { return false }
        self.draft = nil
        bindingMayHaveChanged(force: true)
        return true
    }

    /// Binds the checkout (the scenario's, a test's).
    @discardableResult
    package func bind(_ binding: KubeBinding) -> Bool {
        draft = binding
        return saveDraft()
    }

    package func unbind() {
        guard let checkout else { return }
        store.remove(checkout)
        draft = nil
        bindingMayHaveChanged(force: true)
    }

    // MARK: Reading

    /// Every watch ended and what it showed dropped; the look-ups' state
    /// with it (a look-up still running ends on its own). The right slot's
    /// pod stays: its reads follow the slot (`updateSlot`).
    private func stop() {
        generation += 1
        gitOps.stop()
        pulse.stop()
        for task in follows.values { task.cancel() }
        follows = [:]
        followed = []
        failed = [:]
        following = nil
        pending = []
        flushing?.cancel()
        flushing = nil
        rows = [:]
        workloads = []
        pods = []
        podsHidden = 0
        problems = []
        deployed = [:]
        answered = [:]
        lookingUp = []
        lookUps = [:]
        lookUpProblem = nil
        state = .idle
    }

    private func restart() {
        stop()
        guard panelVisible else { return }
        guard let binding else {
            gitOps.unbound()
            readGuess()
            followUnboundPulse()
            return
        }
        guard let checkout else { return }
        state = .reading
        let generation = self.generation
        let kubernetes = self.kubernetes
        Task { [weak self] in
            guard let list = await kubernetes.contextsForAgents() else {
                guard let self, self.generation == generation else { return }
                return self.state = .failed("Kubernetes is off in Settings.")
            }
            guard let self, self.generation == generation else { return }
            guard let context = list.context(named: binding.context) else {
                return self.state = .failed("The kubeconfig has no context “\(binding.context)”: edit the binding.")
            }
            self.production = context.isProduction
            self.follow(binding, context: context, checkout: checkout, generation: generation)
        }
    }

    private func client(for context: KubeContext) -> KubeClient {
        clientFor?(context) ?? kubernetes.panelClient(for: context)
    }

    private func follow(_ binding: KubeBinding, context: KubeContext, checkout: URL, generation: Int) {
        var kinds: [KubeResourceKind] = [.deployments, .statefulSets]
        if binding.workloads.contains(where: { KubeWorkloadRef(parsing: $0)?.kind == .daemonSet }) { kinds.append(.daemonSets) }
        kinds.append(.pods)
        followed = kinds
        following = (binding, context, checkout)
        pulse.follow(client(for: context), context: context.name, namespace: binding.namespace)
        for kind in kinds { follow(kind, generation: generation) }
        gitOps.follow(binding, context: context, checkout: checkout, client: client(for: context))
    }

    /// One kind followed. What it can't get past (`KubeClient.follow`
    /// retries the transient itself) is said for that kind, its rows
    /// dropped, and it is followed again after a wait — the others go on.
    private func follow(_ kind: KubeResourceKind, generation: Int) {
        guard let following else { return }
        let client = client(for: following.context)
        // A workload's rows say who deploys it (its metadata, in this one
        // namespace: its owners, Argo CD's marks by their allow-list); a pod's needn't.
        let workload = kind.fullName != KubeResourceKind.pods.fullName
        let options = KubeListOptions(labelSelector: following.binding.selector, metadata: workload, owners: workload, marks: workload)
        let scope = KubeScope.namespace(following.binding.namespace)
        let key = kind.fullName
        follows[key]?.cancel()
        follows[key] = Task { [weak self] in
            do {
                for try await update in client.follow(kind, in: scope, options: options) {
                    guard let self, self.generation == generation, !Task.isCancelled else { return }
                    self.received(update, for: key)
                }
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.kindFailed(kind, KubernetesModel.said(error), generation: generation)
            }
        }
    }

    private func received(_ update: KubeFollowUpdate, for key: String) {
        if case .retrying = update { return }
        if case .listed = update, failed[key] != nil {
            failed[key] = nil
            problemsChanged()
        }
        pending.append((key, update))
        // A kind's first list at once; changes in batches.
        if case .listed = update, rows[key] == nil {
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

    /// What came since the last flush, applied in one change; the
    /// workloads whose rows had events told to the rail's GitOps part (a
    /// settled one may be read again: gitops.md 14.2.5).
    private func flush() {
        guard !pending.isEmpty, let following else { return }
        var moved = Set<KubeWorkloadRef>()
        for (key, update) in pending {
            var kept = rows[key] ?? KubeRows()
            kept.apply(update)
            rows[key] = kept
            guard case .changed(let changes, _) = update, let kind = KubeWorkloadKind.allCases.first(where: { $0.kind.fullName == key }) else { continue }
            for change in changes { moved.insert(KubeWorkloadRef(kind: kind, name: change.id.name)) }
        }
        pending = []
        rowsChanged(following.binding, checkout: following.checkout)
        gitOps.rowsMoved(moved)
    }

    private func kindFailed(_ kind: KubeResourceKind, _ said: String, generation: Int) {
        let key = kind.fullName
        let failures = (failed[key]?.failures ?? 0) + 1
        failed[key] = ("Couldn't list \(kind.kind)s: \(said)", failures)
        follows[key] = nil
        pending.removeAll { $0.0 == key }
        if rows.removeValue(forKey: key) != nil, let following { rowsChanged(following.binding, checkout: following.checkout) }
        problemsChanged()
        let delay = retryDelays.isEmpty ? Duration.seconds(30) : retryDelays[min(failures - 1, retryDelays.count - 1)]
        follows[key] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.generation == generation, self.failed[key] != nil else { return }
            self.follow(kind, generation: generation)
        }
    }

    /// The kinds that failed said, and the state: live once every kind
    /// has listed or failed, failed when none listed.
    private func problemsChanged() {
        let said = followed.compactMap { failed[$0.fullName]?.said }
        if said != problems { problems = said }
        guard !followed.isEmpty else { return }
        if failed.count == followed.count {
            let first = said.first ?? "Couldn't list the namespace."
            if state != .failed(first) { state = .failed(first) }
        } else if followed.allSatisfy({ rows[$0.fullName] != nil || failed[$0.fullName] != nil }) {
            if state != .live { state = .live }
        }
    }

    /// Try Again: every kind that failed followed again now.
    package func retry() {
        guard panelVisible else { return }
        guard following != nil else { return restart() }
        let generation = self.generation
        for kind in followed where failed[kind.fullName] != nil {
            failed[kind.fullName] = (failed[kind.fullName]?.said ?? "", 0)
            follow(kind, generation: generation)
        }
        if case .failed = state { state = .reading }
    }

    private func rowsChanged(_ binding: KubeBinding, checkout: URL) {
        var found: [Workload] = []
        for workload in KubeWorkloadKind.allCases {
            guard let kept = rows[workload.kind.fullName] else { continue }
            for row in kept.sorted where binding.includes(workload, row.id.name) {
                found.append(Self.workload(workload, row: row, columns: kept.columns))
            }
        }
        if found != workloads {
            workloads = found
            gitOps.workloadsChanged(found.map(\.bound))
        }
        let kept = rows[KubeResourceKind.pods.fullName] ?? KubeRows()
        let (shown, hidden) = Self.limited(kept.sorted.compactMap { KubePodSummary(row: $0, columns: kept.columns).map(Pod.init) })
        if shown != pods { pods = shown }
        if hidden != podsHidden { podsHidden = hidden }
        problemsChanged()
        answer(checkout: checkout)
    }

    /// At most `limit` pods, in the order given: every failing one (a
    /// pending one too) first picked, then the rest.
    package static func limited(_ pods: [Pod], limit: Int = podLimit) -> (shown: [Pod], hidden: Int) {
        guard pods.count > limit else { return (pods, 0) }
        func failing(_ pod: Pod) -> Bool { pod.summary.isFailing || pod.summary.status == "Pending" }
        var picked = Set(pods.filter(failing).prefix(limit).map(\.id))
        for pod in pods where picked.count < limit { picked.insert(pod.id) }
        return (pods.filter { picked.contains($0.id) }, pods.count - picked.count)
    }

    /// A workload's row read into its health: a Deployment's state off its
    /// cells (as the page's Status), a StatefulSet's or DaemonSet's Ready;
    /// with Argo CD's marks, its member as an app read from them counts it.
    package static func workload(_ kind: KubeWorkloadKind, row: KubeRow, columns: [KubeColumn]) -> Workload {
        let ref = KubeWorkloadRef(kind: kind, name: row.id.name)
        let images = KubeDeployedCommit.images(inCell: row.cell("Images", in: columns)?.text)
        let member = KubeMarkedMember.row(row, kind: KubeMarkedKind(kind.kind), columns: columns, now: Date())
        switch kind {
        case .deployment:
            let hint = KubeDeploymentHint(row: row, columns: columns)
            let failing = hint.map { if case .available = $0 { false } else if case .scaledToZero = $0 { false } else { true } } ?? false
            return Workload(
                ref: ref, health: hint?.text ?? row.cell("Ready", in: columns)?.text ?? "—", failing: failing, images: images, owners: row.owners,
                member: member)
        case .statefulSet:
            let ready = row.cell("Ready", in: columns)?.text ?? "—"
            let parts = ready.split(separator: "/").compactMap { Int($0) }
            let failing = parts.count == 2 && parts[0] < parts[1]
            return Workload(ref: ref, health: "\(ready) ready", failing: failing, images: images, owners: row.owners, member: member)
        case .daemonSet:
            let ready = row.cell("Ready", in: columns).flatMap { Int($0.text) }
            let desired = row.cell("Desired", in: columns).flatMap { Int($0.text) }
            let failing = (ready ?? 0) < (desired ?? 0)
            return Workload(
                ref: ref, health: "\(ready.map(String.init) ?? "?")/\(desired.map(String.init) ?? "?") ready", failing: failing, images: images,
                owners: row.owners, member: member)
        }
    }

    // MARK: The deployed commit (3.2)

    /// Each workload's commit, looked up in the checkout (`Git.run`, nothing
    /// fetched) when its images — or what was asked — change.
    private func answer(checkout: URL) {
        let generation = self.generation
        let appVersion = binding.flatMap { appVersions[Self.releaseKey($0) ?? ""] }
        for workload in workloads {
            let candidates = KubeDeployedCommit.candidates(images: workload.images, revisions: revisions, appVersion: appVersion)
            let key = candidates.map { "\($0.source.rawValue):\($0.sha)" }.joined(separator: ",")
            guard answered[workload.id] != key else { continue }
            answered[workload.id] = key
            Task { [weak self] in
                let answer = await KubeDeployedCommit.answer(candidates, in: checkout)
                guard let self, self.generation == generation, self.answered[workload.id] == key else { return }
                self.deployed[workload.id] = answer
            }
        }
    }

    /// The deployed commit everything else says: the first workload's that
    /// the checkout has, else the first one's answer.
    package var headline: (workload: Workload, answer: KubeDeployedAnswer)? {
        let answered = workloads.compactMap { workload in deployed[workload.id].map { (workload, $0) } }
        return answered.first { $0.1.found != nil } ?? answered.first
    }

    /// "Look up": the image's revision label through the user's docker
    /// (`buildx imagetools`), and the bound release's appVersion — only
    /// when asked; then the commit answered again.
    package func lookUp(_ workload: Workload) {
        guard let checkout, let binding, !lookingUp.contains(workload.id) else { return }
        let token = UUID()
        lookUps[workload.id] = token
        lookingUp.insert(workload.id)
        lookUpProblem = nil
        let inspect = inspectRevision
        let cli = inspect == nil ? revisionCLI() : nil
        let release = binding.release
        let production = self.production
        let kubernetes = self.kubernetes
        let generation = self.generation
        let images = workload.images
        Task { [weak self] in
            var found: [String: String] = [:]
            for image in images {
                if let inspect {
                    if let revision = await inspect(image) { found[image] = revision }
                } else if let cli, let revision = await KubeDeployedCommit.inspectRevision(image, cli: cli) {
                    found[image] = revision
                }
            }
            var version: String?
            var problems: [String] = []
            if inspect == nil, cli == nil { problems.append("the image's label needs docker buildx (imagetools)") }
            if let release {
                if production {
                    problems.append("a production release's appVersion is read on the Helm page")
                } else if let list = await kubernetes.contextsForAgents(), let context = list.context(named: binding.context) {
                    version = await Self.appVersion(release, namespace: binding.namespace, client: self?.client(for: context))
                }
            }
            guard let self else { return }
            // Its own end clears it, whatever happened meanwhile.
            if self.lookUps[workload.id] == token {
                self.lookUps[workload.id] = nil
                self.lookingUp.remove(workload.id)
            }
            self.revisions.merge(found) { _, new in new }
            if let version, let key = Self.releaseKey(binding) { self.appVersions[key] = version }
            // Hidden, another checkout, another binding: nothing more said.
            guard self.generation == generation else { return }
            if found.isEmpty, version.flatMap(KubeDeployedCommit.commit(inTag:)) == nil {
                self.lookUpProblem =
                    "No revision label" + (release == nil ? "" : " or SHA-shaped appVersion") + " found"
                    + (problems.isEmpty ? "." : ": " + problems.joined(separator: "; ") + ".")
            }
            self.answered = [:]
            self.answer(checkout: checkout)
        }
    }

    /// The key a release's appVersion is kept under: the binding's
    /// context, namespace and release; nil without a release.
    package static func releaseKey(_ binding: KubeBinding) -> String? {
        binding.release.map { "\(binding.context)\u{1F}\(binding.namespace)\u{1F}\($0)" }
    }

    /// A release's newest revision's chart appVersion: its Helm records'
    /// metadata listed, the newest one read (Helm's own decoding, masked).
    package nonisolated static func appVersion(_ release: String, namespace: String, client: KubeClient?) async -> String? {
        guard let client else { return nil }
        guard let records = try? await client.helmRecords(.secret, in: .namespace(namespace)),
            let found = KubeHelm.releases(records).first(where: { $0.name == release }),
            let detail = try? await client.helmRelease(found.latest)
        else { return nil }
        return detail.chart.appVersion
    }

    /// "Diff deployed…current": a review tab for what the checkout has that
    /// isn't deployed.
    package func reviewDeployed(_ found: KubeDeployedAnswer.Found) {
        guard let checkout else { return }
        openReview(KubeDeployedCommit.review(found), checkout)
    }

    // MARK: The right slot

    /// A pod picked: its detail (one GET, then its log while the slot shows it).
    package func pick(_ pod: KubeRowID) {
        guard let binding else { return }
        if picked != pod {
            session?.cancel()
            picked = pod
            session = nil
            let ref = KubeObjectRef(context: binding.context, kind: .pods, namespace: pod.namespace ?? binding.namespace, name: pod.name)
            let kubernetes = self.kubernetes
            Task { [weak self] in
                let context = await kubernetes.contextsForAgents()?.context(named: binding.context)
                guard let self, self.picked == pod else { return }
                self.session = KubeDetailSession(ref: ref, client: context.map { self.client(for: $0) })
                self.updateSlot()
            }
        }
        showSlot()
    }

    private func updateSlot() {
        guard let session else { return }
        if slotVisible, windowVisible {
            session.load()
            if slotTab == .logs { session.logs?.show(since: .all) } else { session.logs?.hide() }
        } else {
            session.logs?.hide()
        }
    }

    package func pickTab(_ tab: SlotTab) {
        slotTab = tab
        updateSlot()
    }

    private func closeSlot() {
        session?.cancel()
        session = nil
        picked = nil
    }

    // MARK: The guess

    private func readGuess() {
        // Only a repository's root is walked (`isRepositoryRoot`): a tab in ~ or / reads nothing.
        guard let checkout, canBind, guessed != checkout else { return }
        guessed = checkout
        guessing = true
        Task { [weak self] in
            let read = await KubeCheckoutScan.guess(checkout)
            guard let self, self.checkout == checkout else { return }
            self.guessing = false
            self.guess = read
            self.followUnboundPulse()
        }
    }

    // MARK: The release and the checkout's chart (stage 3a)

    /// The bound release's session, made when first asked.
    package func helmSession() -> KubeHelmUpgradeSession? {
        guard let binding, binding.release != nil, let checkout else { return nil }
        if let helmUpgrade, helmUpgrade.binding == binding, helmUpgrade.checkout == checkout { return helmUpgrade }
        let session = KubeHelmUpgradeSession(binding: binding, checkout: checkout, model: kubernetes)
        if let clientFor { session.client = clientFor }
        session.host = helmHost
        helmUpgrade = session
        return session
    }

    /// Diff Chart with Release: the checkout's chart rendered with the
    /// release's values, against what it has — in the changes pane.
    package func diffChart() { helmSession()?.diff() }

    /// Upgrade…: `helm upgrade` from the checkout's chart, asked first.
    package func upgradeChart() { helmSession()?.upgrade() }

    /// The forwards in the bound namespace.
    /// No binding: the pulse of the page's context (else the kubeconfig's
    /// current one) in the namespace the checkout's files name, if they do.
    private func followUnboundPulse() {
        guard panelVisible, binding == nil else { return }
        let generation = self.generation
        let kubernetes = self.kubernetes
        let guessed = guess?.namespace
        Task { [weak self] in
            guard let list = await kubernetes.contextsForAgents() else { return }
            guard let self, self.generation == generation, self.binding == nil else { return }
            guard let context = kubernetes.selected ?? list.current.flatMap(list.context(named:)) ?? list.contexts.first else { return }
            // One namespace, never the cluster: the files', else the context's own.
            self.pulse.follow(self.client(for: context), context: context.name, namespace: guessed ?? context.namespace ?? "default")
        }
    }

    /// The forwards that are this binding's — or, with none, every one running.
    package func forwards(_ all: [KubeForward]) -> [KubeForward] {
        guard let binding else { return all }
        return all.filter { $0.spec.context == binding.context && $0.spec.namespace == binding.namespace }
    }
}
