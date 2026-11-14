import Combine
import Darwin
import Foundation

/// A forward's kubectl, as `KubeForwards` sees it: a `ManagedProcess`, or a test's.
protocol KubeForwardProcess: AnyObject, Sendable {
    var pid: pid_t { get }
    var isRunning: Bool { get }
    /// What it said on stderr: why it ended.
    var said: String { get }
    func close()
}

extension ManagedProcess: KubeForwardProcess {
    var said: String { stderr.text }
}

/// Why a forward's kubectl didn't start.
enum KubeForwardFailure: Error, Equatable, CustomStringConvertible {
    /// It exited, or never said it listens: tried again, backing off.
    case failed(String)
    /// It can't start at all — no kubectl, a sign-in that failed, no
    /// kubeconfig: the forward stops, saying why. Nothing is retried that
    /// would run the context's exec plugin again and again.
    case stops(String)

    var description: String {
        switch self {
        case .failed(let reason), .stops(let reason): reason
        }
    }
}

/// Where a forward stands.
enum KubeForwardState: Equatable, Sendable {
    /// `kubectl auth can-i create pods/portforward` is asked.
    case checking
    /// Its target is read: which pod, which port.
    case resolving
    case starting(pod: String)
    case forwarding(pod: String, pid: pid_t)
    /// Waiting to start again: why it ended.
    case restarting(String)
    /// It no longer runs, and says why: its target gone, too many tries,
    /// its context removed, refused.
    case stopped(String)

    var isStopped: Bool { if case .stopped = self { true } else { false } }

    var text: String {
        switch self {
        case .checking: "Checking kubectl auth can-i…"
        case .resolving: "Finding a ready pod…"
        case .starting(let pod): "Starting on \(pod)…"
        case .forwarding(let pod, _): "Forwarding to \(pod)"
        case .restarting(let why): "Restarting — \(why)"
        case .stopped(let why): "Stopped — \(why)"
        }
    }
}

/// One forward: what was asked, where it stands, the pod it is pinned to.
struct KubeForward: Identifiable, Equatable, Sendable {
    var spec: KubeForwardSpec
    var state: KubeForwardState = .checking
    /// The pod it is pinned to — or was last, while it restarts.
    var pod: String?
    /// The pod's port it goes to (a Service's `targetPort`, resolved).
    var podPort: Int?
    var production = false
    /// How many times it was started again.
    var restarts = 0

    var id: UUID { spec.id }

    var isForwarding: Bool { if case .forwarding = state { true } else { false } }

    /// kubectl's pid while it forwards.
    var pid: pid_t? { if case .forwarding(_, let pid) = state { pid } else { nil } }

    /// What it runs, as a person would type it.
    var kubectl: String? {
        guard let pod, let podPort else { return nil }
        return KubePortForwardCommand.line(
            pod: pod, localPort: spec.localPort, remotePort: podPort, context: spec.context, namespace: spec.namespace, address: spec.address)
    }

    /// Its pill in the pane header of the tab that asked for it, and its
    /// row in Tab Info — while it hasn't stopped.
    var listeningPort: ListeningPort? {
        guard !state.isStopped else { return nil }
        return ListeningPort(
            pid: pid ?? 0, process: "kubectl", port: spec.localPort, address: spec.address,
            forward: KubeForwardPill(
                id: id, context: spec.context, namespace: spec.namespace, target: spec.target.description, pod: pod, https: spec.https,
                forwarding: isForwarding, production: production, state: state.text))
    }
}

/// The app's port-forwards (stage 1d; docs/design/kubernetes/analysis.md,
/// 2.7 and 3.8): each a `kubectl port-forward pod/<name>` that Overterm
/// runs as a managed process — the user's own kubectl and credentials,
/// never the proxy's socket, which refuses port-forward on every context.
///
/// - **Allowed on read-only contexts**, once `kubectl auth can-i create
///   pods/portforward` says yes (`KubeProcessCheck`; the page's minute-long
///   answers): a forward changes no object.
/// - **Resolved by Overterm**: a Service is one of its ready endpoints'
///   pods (EndpointSlices, else the legacy Endpoints) and the pod's port
///   its `targetPort`; a Deployment one of its selector's ready pods; a
///   pod itself. kubectl is given only that pod, so the pill names it.
/// - **Started again** when kubectl exits or its pod goes (a GET every
///   `podCheckInterval` while it forwards and the page shows — hidden,
///   nothing is read (a check in flight is cancelled, a start again waits
///   for the page to resolve), and kubectl exiting is what says the pod went
///   — which it does only at the next connection: a pod deleted while
///   nothing connects leaves kubectl listening (kind's 1.37, a minute and
///   more; `KubeRealClusterTests`), so hidden, such a forward stays up until
///   it is used, and its first connection fails; shown again, the pod is looked at at once: gone, no longer running —
///   for a Service or a Deployment, no longer ready) —
///   resolved again first, the pod pinned before kept while it is still
///   ready, backing off (`KubeForwardBackoff`), and stopped, saying why,
///   after too many tries, when the target itself is gone, or on a
///   credential failure (which would run the exec plugin again each time).
/// - **Closed by its pid**, never a pattern: stopped, edited, at quit
///   (`stopAll`), when its context leaves the kubeconfig or names another
///   cluster, and when Kubernetes is turned off.
///
/// One for the app: a forward outlives the window and the tab it was
/// started from, not the app.
@MainActor
final class KubeForwards: ObservableObject {
    static let shared = KubeForwards(model: .shared)

    @Published private(set) var forwards: [KubeForward] = []
    /// The OpenAPI document a forward's server publishes, found once it
    /// first forwards on its local port (3.8): offered to the API client,
    /// never imported without a press. Gone with the forward, or its port.
    @Published private(set) var openAPI: [UUID: APIDiscovery.Source] = [:]

    typealias Launch = @Sendable (KubeContext, KubeForwardSpec, KubeForwardResolve.Pinned) async throws -> any KubeForwardProcess

    /// What the target is read through: the context's proxy, in the background's slots.
    var client: (KubeContext) -> KubeClient?
    /// `kubectl auth can-i create pods/portforward` in the namespace.
    var canI: (KubeContext, String) async -> KubeCanIAnswer
    /// Starts kubectl, ready once it says it forwards.
    var launch: Launch
    /// How often the pinned pod is looked at while it forwards.
    var podCheckInterval: Duration = .seconds(5)
    /// Whether the pinned pod may be looked at now: the app's, only while
    /// the Kubernetes page shows (it reads nothing hidden; Section 10).
    var checksPods: () -> Bool = { true }
    /// How often kubectl is looked at.
    var processCheckInterval: Duration = .milliseconds(250)
    /// The backoff's waits, times this: a test's are short.
    var backoffScale: Double = 1
    var now: () -> Date = { Date() }
    /// Asks a forward's server for its OpenAPI document (`APIDiscovery`'s
    /// paths, bounded); nil asks nothing — a test's, or the app's while
    /// the API client or its server discovery is off (`probes`).
    var probe: (@Sendable (URL) async -> APIDiscovery.Source?)?
    /// Whether a forward is probed now: the app's asks Settings.
    var probes: () -> Bool = { true }

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var processes: [UUID: any KubeForwardProcess] = [:]
    private var contexts: [UUID: KubeContext] = [:]
    private var watches: [AnyCancellable] = []
    private var probing: [UUID: Task<Void, Never>] = [:]
    /// Each forward's pod check in flight: cancelled when the page hides.
    private var podChecks: [UUID: Task<String?, Never>] = [:]
    /// The local port each forward was probed on.
    private var probed: [UUID: Int] = [:]

    init(
        client: @escaping (KubeContext) -> KubeClient?, canI: @escaping (KubeContext, String) async -> KubeCanIAnswer, launch: @escaping Launch
    ) {
        self.client = client
        self.canI = canI
        self.launch = launch
    }

    /// The app's: through the model's proxies and can-i answers, kubectl as
    /// the proxies run it; following the model's contexts and switch.
    convenience init(model: KubernetesModel) {
        self.init(
            client: { [weak model] context in model?.client(for: context.name, role: .background) },
            canI: { [weak model] context, namespace in
                await model?.access.answer(context, namespace: namespace, .portForward) ?? .failed("Kubernetes is off.")
            },
            launch: Self.kubectl(model))
        checksPods = { [weak model] in model?.isShown == true }
        probe = { url in await APIDiscovery.probe(url) }
        probes = { Settings.shared.apiEnabled && Settings.shared.apiDiscoverServers }
        // Turned on while forwards run: those are asked now, not at their next start.
        watches.append(
            Settings.shared.changes.filter { $0.contains("api.enabled") || $0.contains("api.discoverServers") }
                .sink { [weak self] _ in self?.probeForwarding() })
        // The emitted values: the model's properties aren't set yet.
        watches.append(
            model.visibility.sink { [weak self] shown in
                if !shown { self?.cancelPodChecks() }
            })
        watches.append(model.$contexts.dropFirst().sink { [weak self] list in self?.contextsChanged(list) })
        watches.append(
            model.$enabled.dropFirst().removeDuplicates().sink { [weak self] enabled in
                if !enabled { self?.stopAll() }
            })
    }

    // MARK: What the page and the window ask

    func forward(_ id: UUID) -> KubeForward? { forwards.first { $0.id == id } }

    /// Those whose pill a tab's pane header shows.
    func forwards(inTab tab: UUID) -> [KubeForward] { forwards.filter { $0.spec.tab == tab } }

    /// The local ports the forwards have, stopped ones aside: not offered again.
    var takenPorts: Set<Int> { Set(forwards.filter { !$0.state.isStopped }.map(\.spec.localPort)) }

    /// A forward started: can-i, its target resolved, kubectl. Refused at
    /// once (stopped, saying why) where the process check refuses it.
    @discardableResult
    func start(_ spec: KubeForwardSpec, in context: KubeContext) -> UUID {
        var forward = KubeForward(spec: spec)
        forward.production = context.isProduction
        if let refused = KubeProcessCheck.rule(.portForward, for: context).refused { forward.state = .stopped(refused) }
        if let index = forwards.firstIndex(where: { $0.id == spec.id }) {
            forwards[index] = forward
        } else {
            forwards.append(forward)
        }
        contexts[spec.id] = context
        if !forward.state.isStopped { begin(spec.id) }
        return spec.id
    }

    /// Another local port, address or https: kubectl started again with them.
    func edit(_ spec: KubeForwardSpec) {
        guard let index = forwards.firstIndex(where: { $0.id == spec.id }), let context = contexts[spec.id] else { return }
        end(spec.id)
        var edited = forwards[index]
        edited.spec.localPort = spec.localPort
        edited.spec.address = spec.address
        edited.spec.https = spec.https
        forwards[index] = edited
        resume(spec.id, in: context)
    }

    /// One stopped by itself (its target gone, too many tries) started
    /// again — not one whose context left the kubeconfig or now names
    /// another cluster (`contextsChanged` forgot it).
    func startAgain(_ id: UUID) {
        guard let index = forwards.firstIndex(where: { $0.id == id }), forwards[index].state.isStopped, let context = contexts[id] else { return }
        resume(id, in: context)
    }

    /// Started again on the context as it is now: its class (production's
    /// red) and the process check read again, not kept from the first start.
    private func resume(_ id: UUID, in context: KubeContext) {
        let refused = KubeProcessCheck.rule(.portForward, for: context).refused
        update(id) {
            $0.production = context.isProduction
            $0.state = refused.map { .stopped($0) } ?? .checking
        }
        if refused == nil { begin(id) }
    }

    /// Stop: its kubectl closed by its pid, the forward gone from the list.
    func stop(_ id: UUID) {
        end(id)
        forwards.removeAll { $0.id == id }
        contexts[id] = nil
    }

    /// Every one, at quit and when Kubernetes is turned off.
    func stopAll() {
        for id in Array(tasks.keys) + Array(processes.keys) + Array(probing.keys) { end(id) }
        forwards = []
        contexts = [:]
        openAPI = [:]
        probed = [:]
    }

    /// The kubeconfig read again: a forward whose context is gone, or now
    /// reaches another cluster, user or sign-in, stops and says so — a
    /// stopped one too, its context forgotten so Start Again can't take it
    /// somewhere it never went (forwarded again from the page, it is asked
    /// anew). One whose context is the same takes its class as it is now.
    func contextsChanged(_ list: KubeContextList) {
        for forward in forwards {
            guard let old = contexts[forward.id] else { continue }
            guard let new = list.context(named: old.name) else {
                halt(forward.id, "\(old.name) is no longer in the kubeconfig")
                contexts[forward.id] = nil
                continue
            }
            guard KubernetesModel.sameCluster(old, new) else {
                halt(forward.id, "\(old.name) now names another cluster or user in the kubeconfig")
                contexts[forward.id] = nil
                continue
            }
            contexts[forward.id] = new
            update(forward.id) { $0.production = new.isProduction }
            if !forward.state.isStopped, let refused = KubeProcessCheck.rule(.portForward, for: new).refused { halt(forward.id, refused) }
        }
    }

    // MARK: Running one

    private func begin(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = Task { [weak self] in await self?.run(id) }
    }

    /// Its task cancelled and its kubectl closed, by its pid; what its
    /// server was found to be goes with it.
    private func end(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        processes.removeValue(forKey: id)?.close()
        forgetProbe(id)
    }

    private func forgetProbe(_ id: UUID) {
        probing.removeValue(forKey: id)?.cancel()
        probed[id] = nil
        if openAPI[id] != nil { openAPI[id] = nil }
    }

    /// The remote ports of servers that speak no HTTP — the databases the
    /// Database client and Docker's clients know, queues, caches: an API
    /// probe there is ten requests a database logs as bad handshakes, and
    /// MySQL counts toward blocking the host.
    static let nonHTTPPorts: Set<Int> = Set(DatabaseKind.allCases.compactMap(\.defaultPort)).union([
        33060, 9000, 9440, 9009, 1433, 1521, 26257, 6379, 6380, 26379, 27017, 27018, 27019, 11211, 5672, 5671, 9092, 2181, 9042, 7687, 4222, 1883,
        6650, 2379, 2380, 25, 22,
    ])

    /// Every forward that forwards, asked now if it hasn't been on its
    /// port: Settings turned discovery on while it ran.
    func probeForwarding() {
        for forward in forwards where forward.isForwarding { probeOnce(forward.id) }
    }

    /// Its server asked once for an OpenAPI document — on its local port,
    /// the first time it forwards there (or discovery is turned on while
    /// it does); started again on another pod, it is the same server. Not
    /// a production forward's: nothing is sent to production that the user
    /// didn't ask for. Nor one to a database — `d`'s, or a port where a
    /// server speaks no HTTP (`nonHTTPPorts`).
    private func probeOnce(_ id: UUID) {
        guard let probe, probes(), let forward = forward(id), !forward.production, !forward.spec.forDatabase,
            !Self.nonHTTPPorts.contains(forward.spec.remotePort), !(forward.podPort.map(Self.nonHTTPPorts.contains) ?? false),
            probed[id] != forward.spec.localPort, let url = forward.spec.url
        else { return }
        let port = forward.spec.localPort
        probed[id] = port
        probing[id]?.cancel()
        probing[id] = Task { [weak self] in
            let found = await probe(url)
            guard let self, !Task.isCancelled, self.probed[id] == port, let forward = self.forward(id), !forward.state.isStopped else { return }
            self.probing[id] = nil
            guard case .server(let base, let spec, let title)? = found else { return }
            self.openAPI[id] = .server(base: base, spec: spec, title: "\(title) — \(forward.spec.target) in \(forward.spec.context)")
        }
    }

    /// Stopped where it stands: kept in the list, saying why.
    private func halt(_ id: UUID, _ why: String) {
        end(id)
        update(id) { $0.state = .stopped(why) }
    }

    private func update(_ id: UUID, _ change: (inout KubeForward) -> Void) {
        guard let index = forwards.firstIndex(where: { $0.id == id }) else { return }
        var forward = forwards[index]
        change(&forward)
        if forward != forwards[index] { forwards[index] = forward }
    }

    private func run(_ id: UUID) async {
        guard let context = contexts[id], let first = forward(id) else { return }
        update(id) { $0.state = .checking }
        let answer = await canI(context, first.spec.namespace)
        guard !Task.isCancelled else { return }
        if let why = KubeAccessState.answered(answer).unavailable(.portForward, namespace: first.spec.namespace) {
            return finish(id, why)
        }
        var backoff = KubeForwardBackoff()
        var again: String?
        while !Task.isCancelled {
            // Started again while the page is hidden (kubectl exited, a
            // backoff's wait ended): resolved only once it shows — hidden,
            // nothing is read (Section 10). The first start is the user's
            // or an agent's own request, and resolves at once.
            if let why = again {
                while !Task.isCancelled, !checksPods() {
                    update(id) { $0.state = .restarting(why) }
                    try? await Task.sleep(for: processCheckInterval)
                }
                guard !Task.isCancelled else { return }
            }
            guard let forward = forward(id), let context = contexts[id] else { return }
            guard let client = client(context) else { return finish(id, "Kubernetes is off, or \(context.name) is gone.") }
            update(id) { $0.state = .resolving }
            let outcome: KubeForwardResolve.Outcome
            do {
                outcome = try await Self.resolve(forward.spec, client: client, previous: forward.pod)
            } catch let problem as KubeProxyProblem where problem.stopsRequests {
                return finish(id, problem.reason)
            } catch {
                outcome = .waiting(KubernetesModel.said(error))
            }
            guard !Task.isCancelled else { return }
            var ran: TimeInterval = 0
            var why: String
            switch outcome {
            case .gone(let reason):
                return finish(id, reason)
            case .waiting(let reason):
                why = reason
            case .pinned(let pinned):
                update(id) {
                    $0.state = .starting(pod: pinned.pod)
                    $0.pod = pinned.pod
                    $0.podPort = pinned.remotePort
                }
                let process: any KubeForwardProcess
                do {
                    process = try await launch(context, forward.spec, pinned)
                } catch let failure as KubeForwardFailure {
                    if case .stops(let reason) = failure { return finish(id, reason) }
                    why = failure.description
                    break
                } catch let problem as KubeProxyProblem {
                    return finish(id, problem.reason)
                } catch {
                    why = error.localizedDescription
                    break
                }
                guard !Task.isCancelled else {
                    process.close()
                    return
                }
                processes[id] = process
                update(id) { $0.state = .forwarding(pod: pinned.pod, pid: process.pid) }
                probeOnce(id)
                let started = now()
                why = await watch(id, process, pod: pinned.pod, namespace: forward.spec.namespace, client: client, ready: forward.spec.target.followsEndpoints)
                ran = now().timeIntervalSince(started)
                if processes[id] === process { processes[id] = nil }
                process.close()
            }
            guard !Task.isCancelled else { return }
            guard let delay = backoff.next(ran: ran) else {
                return finish(id, "\(why) — stopped after \(KubeForwardBackoff.maxFailures) tries")
            }
            update(id) {
                $0.state = .restarting(why)
                $0.restarts += 1
            }
            again = why
            try? await Task.sleep(for: .milliseconds(Int(delay * backoffScale * 1000)))
        }
    }

    /// Stopped by itself: kept in the list, saying why. Not from a run that
    /// was cancelled — stopped, or replaced by an edit or Start Again — whose
    /// launch or read ended late: the task, kubectl and state are the new
    /// run's by then.
    private func finish(_ id: UUID, _ why: String) {
        guard !Task.isCancelled else { return }
        tasks[id] = nil
        processes.removeValue(forKey: id)?.close()
        forgetProbe(id)
        update(id) { $0.state = .stopped(why) }
    }

    /// Until kubectl exits or its pod goes — for a Service or a Deployment,
    /// until it is no longer ready too: a pod failing readiness leaves the
    /// Service's endpoints, and the forward follows it to one that is ready.
    /// The pod is read only while `checksPods` says so, and a read in
    /// flight when the page hides is cancelled (`podCheck`); the clock isn't
    /// reset meanwhile, so the first look after is at once. Why it ended.
    private func watch(_ id: UUID, _ process: any KubeForwardProcess, pod: String, namespace: String, client: KubeClient, ready: Bool) async -> String {
        var lastCheck = ContinuousClock.now
        while !Task.isCancelled {
            if !process.isRunning {
                return KubeProxyProblem.lastLine(of: process.said).map { "kubectl exited: \($0)" } ?? "kubectl port-forward exited"
            }
            if ContinuousClock.now - lastCheck >= podCheckInterval, checksPods() {
                switch await podCheck(id, pod: pod, namespace: namespace, client: client, ready: ready) {
                case .ended(let why): return why
                case .fine: lastCheck = ContinuousClock.now
                case .abandoned: break  // looked at again at once when shown
                }
                continue
            }
            try? await Task.sleep(for: processCheckInterval)
        }
        return "stopped"
    }

    private enum PodCheck {
        case fine
        case ended(String)
        case abandoned
    }

    /// One look at the pinned pod, as a task of its own: cancelled — its
    /// request closed — when the page hides (the model says so at once;
    /// `checksPods` is asked too, every `processCheckInterval`), or when
    /// the forward's run is.
    private func podCheck(_ id: UUID, pod: String, namespace: String, client: KubeClient, ready: Bool) async -> PodCheck {
        let check = Task { () -> String? in
            // A failed read (the network, the proxy) says nothing of the pod.
            do {
                guard let json = try await Self.objectJSON(client, .pods, namespace, pod) else { return "pod \(pod) went" }
                if !(ready ? KubeForwardResolve.isReady(json) : KubeForwardResolve.isRunning(json)) { return KubeForwardResolve.notReady(json) }
            } catch {}
            return nil
        }
        podChecks[id] = check
        let interval = processCheckInterval
        let watching = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                if !self.checksPods() {
                    check.cancel()
                    return
                }
            }
        }
        let why = await withTaskCancellationHandler {
            await check.value
        } onCancel: {
            check.cancel()
        }
        watching.cancel()
        if podChecks[id] == check { podChecks[id] = nil }
        if check.isCancelled { return .abandoned }
        return why.map(PodCheck.ended) ?? .fine
    }

    /// The page hid: every pod check in flight cancelled now.
    func cancelPodChecks() {
        for check in podChecks.values { check.cancel() }
        podChecks = [:]
    }

    // MARK: Resolving

    /// Which pod, which port, as the API says now — GETs only.
    static func resolve(_ spec: KubeForwardSpec, client: KubeClient, previous: String?) async throws -> KubeForwardResolve.Outcome {
        let namespace = spec.namespace
        switch spec.target {
        case .pod(let name):
            return KubeForwardResolve.pod(name, try await objectJSON(client, .pods, namespace, name), port: spec.remotePort)
        case .service(let name):
            guard let service = try await objectJSON(client, .services, namespace, name) else { return .gone("svc/\(name) is gone") }
            let offered = KubeForwardPortOption.offered(by: service, target: spec.target).map(\.port)
            guard offered.contains(spec.remotePort) else { return .gone("svc/\(name) has no port \(spec.remotePort) any more") }
            let candidates = try await endpointPods(client, namespace: namespace, service: name)
            let ordered = previous.map { previous in candidates.contains(previous) ? [previous] + candidates.filter { $0 != previous } : candidates } ?? candidates
            // The first ready one with the port: during a rollout that renames
            // it, the new ReplicaSet's pods may have it and the old ones not.
            var without: String?
            for pod in ordered {
                guard let json = try await objectJSON(client, .pods, namespace, pod), KubeForwardResolve.isReady(json) else { continue }
                guard let port = KubeForwardResolve.targetPort(service: service, port: spec.remotePort, pod: json) else {
                    without = without ?? pod
                    continue
                }
                return .pinned(KubeForwardResolve.Pinned(pod: pod, remotePort: port))
            }
            if let without { return .waiting("pod \(without) has no port svc/\(name):\(spec.remotePort) goes to") }
            return .waiting("svc/\(name) has no ready endpoint")
        case .deployment(let name):
            guard let deployment = try await objectJSON(client, .deployments, namespace, name) else { return .gone("deploy/\(name) is gone") }
            guard let selector = KubeForwardResolve.labelSelector((deployment["spec"] as? [String: Any])?["selector"] as? [String: Any]) else {
                return .gone("deploy/\(name) has no selector Overterm can read")
            }
            let pods = try await items(client, KubeResourceKind.pods.path(namespace: namespace), labelSelector: selector)
            guard let pod = KubeForwardResolve.pick(KubeForwardResolve.readyPods(pods), previous: previous) else {
                return .waiting("deploy/\(name) has no ready pod")
            }
            return .pinned(KubeForwardResolve.Pinned(pod: pod, remotePort: spec.remotePort))
        }
    }

    /// A Service's ready endpoints' pods: its EndpointSlices, else (a
    /// cluster that serves none) its Endpoints.
    static func endpointPods(_ client: KubeClient, namespace: String, service: String) async throws -> [String] {
        let slices = "/apis/discovery.k8s.io/v1/namespaces/\(KubePath.segment(namespace))/endpointslices"
        do {
            return KubeForwardResolve.readyPods(slices: try await items(client, slices, labelSelector: "kubernetes.io/service-name=\(service)"))
        } catch let error as KubeAPIError where error.isNotFound {
            let endpoints = try await objectJSON(client, .endpoints, namespace, service)
            return endpoints.map { KubeForwardResolve.readyPods(endpoints: $0) } ?? []
        }
    }

    /// One object as JSON; nil when it is gone (a 404).
    static func objectJSON(_ client: KubeClient, _ kind: KubeResourceKind, _ namespace: String, _ name: String) async throws -> [String: Any]? {
        do {
            return try await client.object(kind, namespace: namespace, name: name).json
        } catch let error as KubeAPIError where error.isNotFound {
            return nil
        }
    }

    /// A plain list's items, by a label selector.
    static func items(_ client: KubeClient, _ path: String, labelSelector: String) async throws -> [[String: Any]] {
        let response = try await client.get(KubePath.query(path, [("labelSelector", labelSelector)]))
        let list = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        return list?["items"] as? [[String: Any]] ?? []
    }

    // MARK: kubectl

    /// kubectl as a context's proxy gets it (`KubeProxyPlanner.tool`:
    /// Overterm's kubeconfig files, kuberc off; guarded, only
    /// OVERTERM_KUBECONFIG's and the run's own HOME and cache), under the
    /// proxies' credential rules — a stopped context starts nothing, an
    /// oidc sign-in waits for any other, a credential failure stops the
    /// context — ready on its `Forwarding from` line.
    static func kubectl(_ model: KubernetesModel) -> Launch {
        { [weak model] context, spec, pinned in
            guard let model else { throw KubeForwardFailure.stops("Kubernetes is off.") }
            let (configuration, proxies) = await MainActor.run { (model.proxyConfiguration, model.proxies) }
            return try await start(context, spec, pinned, configuration: configuration, proxies: proxies)
        }
    }

    /// One kubectl port-forward for `pinned`, ready — or why not.
    static func start(
        _ context: KubeContext, _ spec: KubeForwardSpec, _ pinned: KubeForwardResolve.Pinned, configuration: KubeProxies.Configuration,
        proxies: KubeProxies?, planner: KubeProxyPlanner = KubeProxyPlanner()
    ) async throws -> any KubeForwardProcess {
        let holds: Bool
        do {
            holds = try await proxies?.beginShortLived(context) ?? false
        } catch {
            throw KubeForwardFailure.stops((error as? KubeProxyProblem)?.reason ?? error.localizedDescription)
        }
        let tool: KubectlTool
        do {
            tool = try await planner.tool(context, configuration: configuration, serverMinor: nil)
        } catch {
            await proxies?.endShortLived(context.name, holds: holds, problem: nil, answered: false)
            throw KubeForwardFailure.stops((error as? KubeProxyProblem)?.reason ?? error.localizedDescription)
        }
        let arguments = KubePortForwardCommand.arguments(
            pod: pinned.pod, localPort: spec.localPort, remotePort: pinned.remotePort, context: context.name, namespace: spec.namespace,
            address: spec.address, cacheDirectory: tool.cacheDirectory)
        let launch = ManagedProcess.Launch(
            executable: tool.kubectl, arguments: arguments, environment: tool.environment, readiness: .line(KubePortForwardCommand.isReady),
            timeout: 30)
        do {
            let process = try await ManagedProcess.start(launch)
            await proxies?.endShortLived(context.name, holds: holds, problem: nil, answered: true)
            return process
        } catch ManagedProcess.Failure.exited(let status, let stderr) {
            let problem = KubeCanI.credentialProblem(stderr: stderr, signIn: KubeSignIn(context.auth))
            await proxies?.endShortLived(context.name, holds: holds, problem: problem, answered: false)
            if let problem { throw KubeForwardFailure.stops(problem.reason) }
            throw KubeForwardFailure.failed(KubeProxyProblem.lastLine(of: stderr) ?? "kubectl port-forward exited (\(status))")
        } catch ManagedProcess.Failure.couldNotStart(let reason) {
            await proxies?.endShortLived(context.name, holds: holds, problem: nil, answered: false)
            throw KubeForwardFailure.stops("kubectl couldn't start: \(reason)")
        } catch is CancellationError {
            await proxies?.endShortLived(context.name, holds: holds, problem: nil, answered: false)
            throw CancellationError()
        } catch {
            await proxies?.endShortLived(context.name, holds: holds, problem: nil, answered: false)
            throw KubeForwardFailure.failed("kubectl port-forward didn't say it listens in 30 seconds")
        }
    }
}

extension KubeResourceKind {
    static let endpoints = KubeResourceKind(
        group: "", version: "v1", resource: "endpoints", kind: "Endpoints", singular: "endpoints", namespaced: true,
        verbs: ["create", "delete", "get", "list", "patch", "update", "watch"], shortNames: ["ep"])
}

/// What a pill, Tab Info and the palette say of a forward (`ListeningPort.forward`).
struct KubeForwardPill: Hashable, Sendable {
    var id: UUID
    var context: String
    var namespace: String
    /// `svc/web`.
    var target: String
    /// The pod it is pinned to.
    var pod: String?
    var https: Bool
    var forwarding: Bool
    var production: Bool
    var state: String
}
