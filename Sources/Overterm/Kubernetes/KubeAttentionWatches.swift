import Combine
import Foundation

/// The attention watches (stage 3a — docs/design/kubernetes/analysis.md,
/// 3.13, Section 10): the one stated exception to "only what is on
/// screen", with a budget.
///
/// - **What:** two watches per bound namespace — Pods (rows only) and
///   Deployments (their conditions, `includeObject=Object`) — both with
///   the binding's label selector sent to the server; nothing else is
///   read: no logs, no metrics, no discovery.
/// - **When:** only while a checkout bound there has a tab open (any
///   window says so, `report`) and `kubernetes.notifyOnFailure` is on.
/// - **How many:** at most `kubernetes.backgroundWatches` bound namespaces
///   (so twice that many watches) across the app, the most recently used
///   checkouts first (`KubeAttentionBudget`); the rest say "not watched".
/// - **Proxies:** the context's proxy in a background slot — never the
///   page's (`KubeProxies`: at most `maxProxies − 1`, and the first closed
///   when the page needs a slot). A watch whose proxy was closed for the
///   page, or that can't have one, says "not watched" and tries again
///   after a wait, until a slot is free.
///
/// What fails is turned into marks by `KubeAttention` (news only, each
/// once) and sent to the windows (`events`), which mark the bound
/// checkout's tabs and offer Ask Why on the mark. Reads only: every
/// request is a GET.
@MainActor
final class KubeAttentionWatches: ObservableObject {
    static let shared = KubeAttentionWatches()

    /// What a bound checkout's tab says of its watches.
    enum State: Equatable, Sendable {
        case watching
        /// Why its failures won't mark it now.
        case notWatched(String)

        var notWatched: String? { if case .notWatched(let why) = self { why } else { nil } }
    }

    /// Marks raised or cleared for the checkouts (by key) bound to a scope.
    struct Event: Equatable {
        var checkouts: [String]
        var change: KubeAttention.Change
    }

    typealias Scope = KubeAttentionBudget.Scope

    /// Each open bound checkout's state, by its key (`KubeBindingStore.key`).
    @Published private(set) var states: [String: State] = [:]
    let events = PassthroughSubject<Event, Never>()

    let store: KubeBindingStore
    let kubernetes: KubernetesModel
    var enabled: () -> Bool = { Settings.shared.kubernetesNotifyOnFailure }
    var budget: () -> Int = { Settings.shared.kubernetesBackgroundWatches }
    /// The context's client: its proxy in a background slot (a test's connection instead).
    var clientFor: ((KubeContext) -> KubeClient)?
    /// The kubeconfig's contexts (read locally — no cluster is asked).
    var contexts: (() async -> KubeContextList?)?
    var now: () -> Date = { Date() }
    /// Watch events are applied at most this often.
    var flushInterval: Duration = .milliseconds(120)
    /// The waits before a watch that failed is tried again (the last repeated).
    var retryDelays: [Duration] = [5, 10, 20, 30].map { .seconds($0) }

    /// Each window's open checkouts, by key, with when each was last selected.
    private var windows: [ObjectIdentifier: [String: Date]] = [:]
    private var lastUsed: [String: Date] = [:]
    private var watches: [Scope: Watch] = [:]
    private var over: Set<Scope> = []
    private var scheduled = false
    private var bindingChanges: AnyCancellable?
    private var contextChanges: AnyCancellable?

    init(store: KubeBindingStore = .shared, kubernetes: KubernetesModel = .shared) {
        self.store = store
        self.kubernetes = kubernetes
        bindingChanges = store.$bindings.dropFirst().sink { [weak self] _ in
            // @Published emits before the value lands.
            DispatchQueue.main.async { self?.refresh() }
        }
        // The kubeconfig or the settings read again: a watch whose context
        // now is another cluster, user or class starts again on the
        // context as it is — never on with the copy it started with.
        contextChanges = kubernetes.$contexts.dropFirst().sink { [weak self] list in
            DispatchQueue.main.async { self?.contextsChanged(list) }
        }
    }

    /// The watches whose context changed under them, started again.
    func contextsChanged(_ list: KubeContextList) {
        for watch in watches.values {
            guard let context = watch.context else { continue }
            if let now = list.context(named: context.name), KubernetesModel.sameAccess(context, now), now.isWritable == context.isWritable { continue }
            watch.stop()
            watch.start()
        }
    }

    // MARK: What the windows say

    /// A window's tabs' checkouts (`KubeBindingStore.key`), and the one its
    /// selected tab is in — the most recently used.
    func report(_ window: ObjectIdentifier, open: Set<String>, selected: String?) {
        let time = now()
        if let selected { lastUsed[selected] = time }
        var mine: [String: Date] = [:]
        for key in open { mine[key] = lastUsed[key] ?? .distantPast }
        guard windows[window] != mine else { return }
        windows[window] = mine
        refresh()
    }

    func forget(_ window: ObjectIdentifier) {
        guard windows.removeValue(forKey: window) != nil else { return }
        refresh()
    }

    /// The checkouts with a tab open in any window, each with when it was last used.
    var open: [String: Date] {
        var all: [String: Date] = [:]
        for window in windows.values {
            for (key, used) in window { all[key] = max(all[key] ?? .distantPast, lastUsed[key] ?? used) }
        }
        return all
    }

    /// The scopes followed now (tests, the scenario).
    var watchedScopes: [Scope] { watches.keys.sorted() }

    /// The state of the scope's watches (tests, the scenario).
    func state(of scope: Scope) -> State? { watches[scope]?.state }

    // MARK: The plan

    /// Looked at again soon (one pass for a burst of changes).
    func refresh() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.refreshNow()
        }
    }

    /// The scopes to follow, started and stopped, and every open bound checkout's state.
    func refreshNow() {
        let open = self.open
        var bindings: [String: KubeBinding] = [:]
        if enabled(), !open.isEmpty {
            for key in open.keys {
                if let binding = store.binding(for: URL(fileURLWithPath: key, isDirectory: true)) { bindings[key] = binding }
            }
        }
        let plan = KubeAttentionBudget.plan(open: open, bindings: bindings, budget: budget())
        let wanted = Set(plan.watched)
        for (scope, watch) in watches where !wanted.contains(scope) {
            retire(watch)
            watches[scope] = nil
        }
        for scope in plan.watched {
            let includes = Self.includes(bindings.values.filter { KubeAttentionBudget.scope(of: $0) == scope })
            if let watch = watches[scope] {
                watch.includes = includes
            } else {
                let watch = Watch(scope: scope, includes: includes, owner: self)
                watches[scope] = watch
                watch.start()
            }
        }
        over = Set(plan.over)
        updateStates(bindings)
    }

    /// The Deployments the scope's bindings name: every one when any binding names none.
    private static func includes(_ bindings: [KubeBinding]) -> (String) -> Bool {
        if bindings.isEmpty || bindings.contains(where: { $0.workloads.isEmpty }) { return { _ in true } }
        let names = Set(bindings.flatMap { $0.workloads.compactMap(KubeWorkloadRef.init(parsing:)) }.filter { $0.kind == .deployment }.map(\.name))
        return { names.contains($0) }
    }

    fileprivate func stateChanged() {
        var bindings: [String: KubeBinding] = [:]
        if enabled() {
            for key in open.keys {
                if let binding = store.binding(for: URL(fileURLWithPath: key, isDirectory: true)) { bindings[key] = binding }
            }
        }
        updateStates(bindings)
    }

    private func updateStates(_ bindings: [String: KubeBinding]) {
        var next: [String: State] = [:]
        let count = budget()
        for (key, binding) in bindings {
            let scope = KubeAttentionBudget.scope(of: binding)
            if let watch = watches[scope] {
                next[key] = watch.state
            } else if over.contains(scope) {
                next[key] = .notWatched(
                    "More bound namespaces have a tab open than are watched at once (\(count), Settings ▸ Kubernetes): the most recently used are.")
            }
        }
        if next != states { states = next }
    }

    fileprivate func client(for context: KubeContext) -> KubeClient {
        clientFor?(context) ?? kubernetes.watchClient(for: context)
    }

    fileprivate func readContexts() async -> KubeContextList? {
        if let contexts { return await contexts() }
        return await kubernetes.contextsForAgents()
    }

    /// The checkouts it went to (which the watch keeps, to clear its marks from them when it stops).
    @discardableResult
    fileprivate func send(_ change: KubeAttention.Change, for scope: Scope) -> [String] {
        guard !change.isEmpty else { return [] }
        let checkouts = open.keys.filter { key in
            store.binding(for: URL(fileURLWithPath: key, isDirectory: true)).map { KubeAttentionBudget.scope(of: $0) == scope } ?? false
        }.sorted()
        guard !checkouts.isEmpty else { return [] }
        events.send(Event(checkouts: checkouts, change: change))
        return checkouts
    }

    /// A watch stopped for good (over the budget, its binding edited, the
    /// marks turned off): the marks it raised are taken down, since no
    /// later watch knows of them to clear them when what caused them goes
    /// — a new one starts from where things stand, and a pod it never saw
    /// marked is never news. A scope over the budget says "not watched".
    private func retire(_ watch: Watch) {
        watch.stop()
        let standing = watch.standing
        guard !standing.isEmpty, !watch.told.isEmpty else { return }
        events.send(Event(checkouts: watch.told.sorted(), change: .init(cleared: standing)))
    }

    /// Every watch ended (Kubernetes off, the app quitting).
    func stopAll() {
        for watch in watches.values { retire(watch) }
        watches = [:]
        over = []
        if !states.isEmpty { states = [:] }
    }

    // MARK: One scope's two watches

    @MainActor
    fileprivate final class Watch {
        let scope: Scope
        var includes: (String) -> Bool
        weak var owner: KubeAttentionWatches?
        private(set) var state: State = .notWatched("Starting the watches…")
        private var attention: KubeAttention
        /// The checkouts its marks went to.
        private(set) var told: Set<String> = []
        /// The marks it raised that stand.
        var standing: [KubeAttentionAlert] { attention.standing }
        private var rows: [String: KubeRows] = [:]
        private var listed: Set<String> = []
        private var tasks: [String: Task<Void, Never>] = [:]
        private var failures: [String: Int] = [:]
        private var pending: [(String, KubeFollowUpdate)] = []
        private var flushing: Task<Void, Never>?
        private var generation = 0
        private(set) var context: KubeContext?

        static let pods = KubeResourceKind.pods.fullName
        static let deployments = KubeResourceKind.deployments.fullName

        init(scope: Scope, includes: @escaping (String) -> Bool, owner: KubeAttentionWatches) {
            self.scope = scope
            self.includes = includes
            self.owner = owner
            attention = KubeAttention(context: scope.context, namespace: scope.namespace)
        }

        func start() {
            let generation = self.generation
            Task { [weak self] in
                guard let owner = self?.owner else { return }
                let list = await owner.readContexts()
                guard let self, self.generation == generation else { return }
                guard let list else { return self.set(.notWatched("Kubernetes is off in Settings.")) }
                guard let context = list.context(named: self.scope.context) else {
                    return self.set(.notWatched("The kubeconfig has no context “\(self.scope.context)”: edit the binding."))
                }
                self.context = context
                self.follow(Self.pods)
                self.follow(Self.deployments)
            }
        }

        func stop() {
            generation += 1
            for task in tasks.values { task.cancel() }
            tasks = [:]
            flushing?.cancel()
            flushing = nil
            pending = []
        }

        private func set(_ state: State) {
            guard state != self.state else { return }
            self.state = state
            owner?.stateChanged()
        }

        private func follow(_ key: String) {
            guard let owner, let context else { return }
            let client = owner.client(for: context)
            let kind: KubeResourceKind = key == Self.pods ? .pods : .deployments
            let options = KubeListOptions(labelSelector: scope.selector, objects: key == Self.deployments)
            let scope = KubeScope.namespace(self.scope.namespace)
            let generation = self.generation
            tasks[key]?.cancel()
            tasks[key] = Task { [weak self] in
                do {
                    for try await update in client.follow(kind, in: scope, options: options) {
                        guard let self, self.generation == generation, !Task.isCancelled else { return }
                        self.received(update, for: key)
                    }
                } catch is CancellationError {
                } catch {
                    guard let self, self.generation == generation, !Task.isCancelled else { return }
                    self.failed(key, error, generation: generation)
                }
            }
        }

        private func received(_ update: KubeFollowUpdate, for key: String) {
            if case .retrying = update { return }
            pending.append((key, update))
            if case .listed = update {
                // A list at once, alone: where things stand is the
                // baseline, never mixed with what changed after it.
                failures[key] = nil
                listed.insert(key)
                flush()
                if listed.count == 2 { set(.watching) }
                return
            }
            guard flushing == nil else { return }
            let interval = owner?.flushInterval ?? .milliseconds(120)
            flushing = Task { [weak self] in
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.flushing = nil
                self.flush()
            }
        }

        /// What came since the last flush, applied, then looked at whole.
        private func flush() {
            flushing?.cancel()
            flushing = nil
            guard !pending.isEmpty else { return }
            var touched = Set<String>()
            for (key, update) in pending {
                var kept = rows[key] ?? KubeRows()
                kept.apply(update)
                rows[key] = kept
                touched.insert(key)
            }
            pending = []
            var change = KubeAttention.Change()
            if touched.contains(Self.pods), listed.contains(Self.pods), let pods = rows[Self.pods] {
                let found = attention.observePods(pods)
                change.raised += found.raised
                change.cleared += found.cleared
            }
            if touched.contains(Self.deployments), listed.contains(Self.deployments), let deployments = rows[Self.deployments] {
                let found = attention.observeDeployments(deployments, includes: includes)
                change.raised += found.raised
                change.cleared += found.cleared
            }
            if let owner { told.formUnion(owner.send(change, for: scope)) }
        }

        /// What a follow couldn't get past (`KubeClient.follow` retries the
        /// transient itself): said, and followed again after a wait. Its
        /// rows wait for the next list — a gap is not deletions.
        private func failed(_ key: String, _ error: Error, generation: Int) {
            listed.remove(key)
            pending.removeAll { $0.0 == key }
            let count = (failures[key] ?? 0) + 1
            failures[key] = count
            set(.notWatched(Self.said(error)))
            let delays = owner?.retryDelays ?? []
            let delay = delays.isEmpty ? Duration.seconds(30) : delays[min(count - 1, delays.count - 1)]
            tasks[key] = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.follow(key)
            }
        }

        /// Why a watch stopped, as the tab says it.
        static func said(_ error: Error) -> String {
            switch error as? KubeProxyProblem {
            case .noSlot, .closedWhileOpening:
                "Every connection is in use and the page keeps one (Contexts connected at once, Settings ▸ Kubernetes): watched again once a slot is free."
            case .needsPageSignIn:
                "Sign in on the page first: this context signs in in the browser, which a watch never opens."
            default:
                "Its watches stopped: \(KubernetesModel.said(error)) — tried again shortly."
            }
        }
    }
}

extension KubernetesModel {
    /// What Ask Why on a mark reads through: the context's proxy in a
    /// background slot — never the page's — or a test's connection. GETs only.
    func attentionClient(for context: KubeContext) -> KubeClient { agentClient(for: context) }
}
