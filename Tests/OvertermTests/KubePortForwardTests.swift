import Darwin
import Foundation
import XCTest

@testable import Overterm

/// Port-forwards (stage 1d): the target resolved — a pod itself, a
/// Service's ready endpoints only, a Deployment's ready pods — the command
/// line, the backoff, the local port chosen, and `KubeForwards` against
/// `FakeKubeAPI`: started again on the new pod after the old one goes,
/// when kubectl exits, stopped when its target or its context goes, and
/// every kubectl closed. Nothing here reads ~/.kube or runs a kubectl but a
/// stand-in script of the test's own.
final class KubePortForwardTests: XCTestCase {
    private static func pod(
        _ name: String, phase: String = "Running", ready: Bool? = true, terminating: Bool = false, created: String = "2026-11-05T10:00:00Z",
        ports: [[String: Any]] = []
    ) -> [String: Any] {
        var metadata: [String: Any] = ["name": name, "creationTimestamp": created]
        if terminating { metadata["deletionTimestamp"] = "2026-11-05T11:00:00Z" }
        var status: [String: Any] = ["phase": phase]
        if let ready { status["conditions"] = [["type": "Ready", "status": ready ? "True" : "False"]] }
        return ["metadata": metadata, "spec": ["containers": [["name": "app", "ports": ports]]], "status": status]
    }

    // MARK: The target and its ports

    func testATargetIsAPodAServiceOrADeployment() {
        XCTAssertEqual(KubeForwardTarget.of(kind: .pods, name: "web-1"), .pod("web-1"))
        XCTAssertEqual(KubeForwardTarget.of(kind: .services, name: "web"), .service("web"))
        XCTAssertEqual(KubeForwardTarget.of(kind: .deployments, name: "web"), .deployment("web"))
        XCTAssertNil(KubeForwardTarget.of(kind: .namespaces, name: "shop"))
        XCTAssertEqual(KubeForwardTarget.service("web").description, "svc/web")
        XCTAssertEqual(KubeForwardTarget.deployment("api").description, "deploy/api")
    }

    func testThePortsATargetOffersAreTCPOnly() {
        let pod = Self.pod(
            "web-1",
            ports: [["containerPort": 8080, "name": "http"], ["containerPort": 9090, "protocol": "TCP"], ["containerPort": 53, "protocol": "UDP"]])
        XCTAssertEqual(KubeForwardPortOption.offered(by: pod, target: .pod("web-1")).map(\.port), [8080, 9090])
        XCTAssertEqual(KubeForwardPortOption.offered(by: pod, target: .pod("web-1")).first?.label, "8080 (http) · app")
        let service: [String: Any] = [
            "spec": ["ports": [["name": "http", "port": 80, "targetPort": "http"], ["port": 53, "protocol": "UDP"], ["port": 443, "targetPort": 8443]]]
        ]
        XCTAssertEqual(KubeForwardPortOption.offered(by: service, target: .service("web")).map(\.port), [80, 443])
        XCTAssertEqual(KubeForwardPortOption.offered(by: service, target: .service("web")).first?.label, "80 (http) → http")
        let deployment: [String: Any] = ["spec": ["template": ["spec": ["containers": [["name": "api", "ports": [["containerPort": 3000]]]]]]]]
        XCTAssertEqual(KubeForwardPortOption.offered(by: deployment, target: .deployment("api")).map(\.port), [3000])
    }

    // MARK: The command

    /// A pod's Overview gives each container its TCP ports: the buttons
    /// that open Port-forward… with the port picked.
    func testAPodsContainerPortsAreTheOverviewsForwardButtons() {
        let spec: [String: Any] = [
            "image": "nginx:1.27",
            "ports": [
                ["containerPort": 8080, "name": "http", "protocol": "TCP"], ["containerPort": 53, "name": "dns", "protocol": "UDP"], ["containerPort": 9090],
            ],
        ]
        let item = KubeOverview.container(name: "app", spec: spec, status: nil)
        XCTAssertEqual(item.ports.map(\.port), [8080, 9090], "TCP only, UDP left out")
        XCTAssertEqual(item.ports.first?.name, "http")
        XCTAssertEqual(item.ports.first?.container, "app")
        XCTAssertEqual(KubeOverview.container(name: "app", spec: ["image": "x"], status: [:]).ports, [])
    }

    func testTheCommandIsOnePodWithItsContextNamespaceAndAddress() {
        XCTAssertEqual(
            KubePortForwardCommand.arguments(pod: "web-1", localPort: 31234, remotePort: 8080, context: "fake-dev", namespace: "shop", address: "127.0.0.1"),
            ["port-forward", "pod/web-1", "31234:8080", "--context", "fake-dev", "--namespace", "shop", "--address", "127.0.0.1"])
        XCTAssertEqual(
            KubePortForwardCommand.arguments(
                pod: "web-1", localPort: 1, remotePort: 2, context: "c", namespace: "n", address: "0.0.0.0", cacheDirectory: "/tmp/ot-cache"
            ).suffix(2), ["--cache-dir", "/tmp/ot-cache"])
        XCTAssertEqual(
            KubePortForwardCommand.line(
                pod: "web-1", localPort: 31234, remotePort: 8080, context: "arn:aws:eks:eu-west-1:000000000000:cluster/acme-dev", namespace: "shop",
                address: "127.0.0.1"),
            "kubectl port-forward pod/web-1 31234:8080 --context arn:aws:eks:eu-west-1:000000000000:cluster/acme-dev --namespace shop --address 127.0.0.1")
        XCTAssertEqual(
            KubePortForwardCommand.line(pod: "web-1", localPort: 1, remotePort: 2, context: "it's", namespace: "shop", address: "::1"),
            "kubectl port-forward pod/web-1 1:2 --context 'it'\\''s' --namespace shop --address ::1")
        XCTAssertTrue(KubePortForwardCommand.isReady("Forwarding from 127.0.0.1:31234 -> 8080"))
        XCTAssertFalse(KubePortForwardCommand.isReady("Handling connection for 31234"))
    }

    func testTheAddressIsAnIPOrLocalhost() {
        for good in ["127.0.0.1", "0.0.0.0", "::1", "localhost", "192.168.1.20"] { XCTAssertNil(KubeForwardAddress.problem(good), good) }
        for bad in ["", "web", "127.0.0", "1.2.3.4.5"] { XCTAssertNotNil(KubeForwardAddress.problem(bad), bad) }
        XCTAssertEqual(KubeForwardAddress.host(for: "127.0.0.1"), "localhost")
        XCTAssertEqual(KubeForwardAddress.host(for: "0.0.0.0"), "localhost")
        XCTAssertEqual(KubeForwardAddress.host(for: "fd00::1"), "[fd00::1]")
        var spec = KubeForwardSpec(context: "c", namespace: "n", target: .service("web"), remotePort: 443, localPort: 31443)
        XCTAssertEqual(spec.url?.absoluteString, "http://localhost:31443")
        spec.https = true
        XCTAssertEqual(spec.url?.absoluteString, "https://localhost:31443")
    }

    // MARK: Resolution

    func testAPodTargetIsItselfWhileItRuns() {
        XCTAssertEqual(KubeForwardResolve.pod("web-1", Self.pod("web-1"), port: 80), .pinned(.init(pod: "web-1", remotePort: 80)))
        XCTAssertEqual(KubeForwardResolve.pod("web-1", Self.pod("web-1", ready: false), port: 80), .pinned(.init(pod: "web-1", remotePort: 80)), "running is enough for a pod")
        XCTAssertEqual(KubeForwardResolve.pod("web-1", Self.pod("web-1", phase: "Pending"), port: 80), .waiting("pod web-1 is Pending"))
        XCTAssertEqual(KubeForwardResolve.pod("web-1", Self.pod("web-1", terminating: true), port: 80), .waiting("pod web-1 is terminating"))
        XCTAssertEqual(KubeForwardResolve.pod("web-1", nil, port: 80), .gone("pod/web-1 is gone"))
    }

    func testAServiceGoesToReadyEndpointsOnly() {
        let slices: [[String: Any]] = [
            [
                "endpoints": [
                    ["conditions": ["ready": true], "targetRef": ["kind": "Pod", "name": "web-b"]],
                    ["conditions": ["ready": false], "targetRef": ["kind": "Pod", "name": "web-c"]],
                    ["conditions": ["ready": true, "terminating": true], "targetRef": ["kind": "Pod", "name": "web-d"]],
                    ["conditions": [:], "targetRef": ["kind": "Pod", "name": "web-a"]],
                    ["conditions": ["ready": true], "targetRef": ["kind": "Node", "name": "node-1"]],
                    ["conditions": ["ready": true]],
                ]
            ],
            ["endpoints": [["conditions": ["ready": true], "targetRef": ["kind": "Pod", "name": "web-b"]]]],
        ]
        XCTAssertEqual(KubeForwardResolve.readyPods(slices: slices), ["web-a", "web-b"], "ready (nil is ready), pods only, once each")
        let endpoints: [String: Any] = [
            "subsets": [
                [
                    "addresses": [["targetRef": ["kind": "Pod", "name": "web-2"]]],
                    "notReadyAddresses": [["targetRef": ["kind": "Pod", "name": "web-3"]]],
                ]
            ]
        ]
        XCTAssertEqual(KubeForwardResolve.readyPods(endpoints: endpoints), ["web-2"])
        XCTAssertEqual(KubeForwardResolve.pick(["web-a", "web-b"], previous: "web-b"), "web-b", "a forward that works isn't moved")
        XCTAssertEqual(KubeForwardResolve.pick(["web-a", "web-b"], previous: "web-gone"), "web-a")
        XCTAssertNil(KubeForwardResolve.pick([], previous: nil))
    }

    func testAServicesPortIsItsTargetPortInThePod() {
        let pod = Self.pod("web-1", ports: [["containerPort": 8080, "name": "http"]])
        let service: [String: Any] = [
            "spec": ["ports": [["name": "http", "port": 80, "targetPort": "http"], ["port": 443, "targetPort": 8443], ["port": 9000], ["port": 81, "targetPort": "nope"]]]
        ]
        XCTAssertEqual(KubeForwardResolve.targetPort(service: service, port: 80, pod: pod), 8080, "by name, in the pod's containers")
        XCTAssertEqual(KubeForwardResolve.targetPort(service: service, port: 443, pod: pod), 8443, "by number")
        XCTAssertEqual(KubeForwardResolve.targetPort(service: service, port: 9000, pod: pod), 9000, "none set: the Service's port")
        XCTAssertNil(KubeForwardResolve.targetPort(service: service, port: 81, pod: pod), "a name the pod hasn't")
        XCTAssertNil(KubeForwardResolve.targetPort(service: service, port: 22, pod: pod), "a port the Service hasn't")
    }

    func testADeploymentGoesToItsReadyPodsOldestFirst() {
        XCTAssertEqual(
            KubeForwardResolve.labelSelector([
                "matchLabels": ["app": "web", "tier": "front"],
                "matchExpressions": [["key": "env", "operator": "In", "values": ["dev", "qa"]], ["key": "canary", "operator": "DoesNotExist"]],
            ]), "app=web,tier=front,env in (dev,qa),!canary")
        XCTAssertNil(KubeForwardResolve.labelSelector([:]))
        XCTAssertNil(KubeForwardResolve.labelSelector(["matchExpressions": [["key": "a", "operator": "Weird"]]]))
        let pods = [
            Self.pod("web-new", created: "2026-11-05T12:00:00Z"), Self.pod("web-old", created: "2026-11-05T09:00:00Z"),
            Self.pod("web-unready", ready: false, created: "2026-11-05T08:00:00Z"), Self.pod("web-going", terminating: true, created: "2026-11-05T07:00:00Z"),
            Self.pod("web-pending", phase: "Pending", ready: nil, created: "2026-11-05T06:00:00Z"),
        ]
        XCTAssertEqual(KubeForwardResolve.readyPods(pods), ["web-old", "web-new"])
        // No conditions reported: every container ready.
        let bare: [String: Any] = ["metadata": ["name": "bare"], "status": ["phase": "Running", "containerStatuses": [["ready": true]]]]
        XCTAssertTrue(KubeForwardResolve.isReady(bare))
    }

    // MARK: The backoff and the port

    func testTheBackoffDoublesStopsAndStartsOverAfterARun() {
        var backoff = KubeForwardBackoff()
        let waits = (0..<KubeForwardBackoff.maxFailures).map { _ in backoff.next(ran: 0) }
        XCTAssertEqual(waits, [1, 2, 4, 8, 15, 30, 30, 30])
        XCTAssertNil(backoff.next(ran: 0), "no storm: it stops")
        var running = KubeForwardBackoff()
        _ = running.next(ran: 0)
        _ = running.next(ran: 0)
        XCTAssertEqual(running.next(ran: KubeForwardBackoff.stableAfter), 1, "one that ran a while starts the count again")
    }

    func testTheLocalPortIsFreeAndNotAnotherForwards() {
        let bound: Set<Int> = [8080, 31000]
        let isBound = { bound.contains($0) }
        XCTAssertNil(KubeForwardPortChoice.problem(9000, taken: [], isBound: isBound))
        XCTAssertEqual(KubeForwardPortChoice.problem(80, taken: [], isBound: isBound), "Ports under 1024 need root; pick one above.")
        XCTAssertEqual(KubeForwardPortChoice.problem(9000, taken: [9000], isBound: isBound), "Another forward listens on 9000.")
        XCTAssertEqual(KubeForwardPortChoice.problem(8080, taken: [], isBound: isBound), "Something on this Mac listens on 8080 already.")
        XCTAssertNotNil(KubeForwardPortChoice.problem(70000, taken: [], isBound: isBound))
        XCTAssertEqual(KubeForwardPortChoice.free(preferred: 9000, taken: [], isBound: isBound), 9000, "the same port where it is free")
        var tries = [31000, 32000, 33000].makeIterator()
        XCTAssertEqual(
            KubeForwardPortChoice.free(preferred: 8080, taken: [32000], isBound: isBound, random: { tries.next() ?? 0 }), 33000,
            "held, taken by another forward: the next free one at random")
        XCTAssertNil(KubeForwardPortChoice.free(taken: [], isBound: { _ in true }), "none free")
        // A real one: free now on this Mac, in the range.
        let real = KubeForwardPortChoice.free(taken: [], isBound: { ListeningPorts.isBound($0) })
        XCTAssertTrue(real.map(KubeForwardPortChoice.range.contains) == true)
    }

    func testTheSheetChecksWhatItMakes() {
        var draft = KubeForwardDraft(context: "fake-dev", namespace: "shop", target: .service("web"), offered: [], remote: "80", local: "31234")
        guard case .success(let spec) = draft.spec(taken: [], isBound: { _ in false }, tab: nil) else { return XCTFail("a good draft") }
        XCTAssertEqual(spec.remotePort, 80)
        XCTAssertEqual(spec.localPort, 31234)
        XCTAssertEqual(spec.address, "127.0.0.1")
        draft.remote = "x"
        XCTAssertEqual(draft.spec(taken: [], isBound: { _ in false }, tab: nil), .failure(.init("The remote port is 1 to 65535.")))
        draft.remote = "80"
        draft.local = "31234"
        XCTAssertEqual(draft.spec(taken: [31234], isBound: { _ in false }, tab: nil), .failure(.init("Another forward listens on 31234.")))
        draft.address = "web"
        guard case .failure = draft.spec(taken: [], isBound: { _ in false }, tab: nil) else { return XCTFail("a bad address") }
        let id = UUID()
        draft.address = "0.0.0.0"
        draft.editing = id
        guard case .success(let edited) = draft.spec(taken: [], isBound: { _ in false }, tab: nil) else { return XCTFail("an edit") }
        XCTAssertEqual(edited.id, id, "an edit keeps the forward's id")
        XCTAssertEqual(edited.address, "0.0.0.0")
    }

    // MARK: The process check

    func testAForwardStartsOnEveryClassAfterCanI() {
        for kind in KubeContextClass.allCases {
            let rule = KubeProcessCheck.rule(.portForward, class: kind, writable: false, settings: KubeContextSettings())
            XCTAssertNil(rule.refused, "read-only too: a forward changes no object (\(kind))")
            XCTAssertEqual(rule.access, .portForward)
            XCTAssertFalse(rule.confirm)
        }
    }
}

/// `KubeForwards` against the fake API: what it resolves, what it starts
/// (a stand-in process), and starting again after the pod is replaced.
@MainActor
final class KubeForwardsTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!

    /// A forward's process, played: running until closed or ended.
    final class Played: KubeForwardProcess, @unchecked Sendable {
        let pid: pid_t
        let pod: String
        let local: Int
        private let lock = NSLock()
        private var running = true
        private(set) var closed = false
        var said = ""

        init(pid: pid_t, pod: String, local: Int) {
            self.pid = pid
            self.pod = pod
            self.local = local
        }

        var isRunning: Bool { lock.withLock { running } }
        func close() {
            lock.withLock {
                running = false
                closed = true
            }
        }
        /// kubectl exits by itself (its stream lost).
        func end(_ stderr: String) {
            said = stderr
            lock.withLock { running = false }
        }
    }

    final class Launches: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [Played] = []
        private var slow: (Duration, KubeForwardFailure)?
        var failWith: KubeForwardFailure?
        var played: [Played] { lock.withLock { all } }
        func add(_ played: Played) { lock.withLock { all.append(played) } }
        /// The next launch takes `delay`, whatever cancels it, and then fails.
        func slowly(_ delay: Duration, failing: KubeForwardFailure) { lock.withLock { slow = (delay, failing) } }
        func takeSlow() -> (Duration, KubeForwardFailure)? {
            lock.withLock {
                defer { slow = nil }
                return slow
            }
        }
    }

    override func setUpWithError() throws {
        socket = "/tmp/otkf-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        api.addPod("web-a", namespace: "shop", FakeKubeAPI.Pod(ports: [FakeKubeAPI.ContainerPort(8080, name: "http")]), labels: ["app": "web"])
        api.addPod("web-b", namespace: "shop", FakeKubeAPI.Pod(ready: 0, ports: [FakeKubeAPI.ContainerPort(8080, name: "http")]), labels: ["app": "web"])
        api.add(
            "services", "web", namespace: "shop",
            fields: ["spec": ["selector": ["app": "web"], "ports": [["name": "http", "port": 80, "targetPort": "http", "protocol": "TCP"]]]])
        api.add("endpointslices.discovery.k8s.io", "web-x", namespace: "shop", labels: ["kubernetes.io/service-name": "web"], fields: Self.slice(ready: "web-a", notReady: "web-b"))
        api.add(
            "deployments.apps", "web", namespace: "shop",
            fields: ["spec": ["selector": ["matchLabels": ["app": "web"]], "template": ["spec": ["containers": [["name": "app"]]]]]])
    }

    override func tearDown() {
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
            XCTAssertFalse(api.requests.contains { $0.path.contains("portforward") }, "no port-forward through the API: kubectl's own")
            api.stop()
        }
    }

    nonisolated private static func slice(ready: String, notReady: String) -> [String: Any] {
        [
            "endpoints": [
                ["conditions": ["ready": true], "targetRef": ["kind": "Pod", "name": ready]],
                ["conditions": ["ready": false], "targetRef": ["kind": "Pod", "name": notReady]],
            ]
        ]
    }

    private static let dev = KubeContext(
        name: "fake-dev", cluster: "fake-dev", server: "http://127.0.0.1:1", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
        contextClass: .remote, settings: KubeContextSettings())

    private func forwards(canI: KubeCanIAnswer = .yes, launches: Launches) -> KubeForwards {
        let socket = self.socket!
        let forwards = KubeForwards(
            client: { context in KubeClient(KubeSocketConnection(socket: socket, context: context.name)) },
            canI: { _, _ in canI },
            launch: { _, spec, pinned in
                if let (delay, failure) = launches.takeSlow() {
                    // As ManagedProcess.start's wait was: deaf to cancellation.
                    await Task.detached { try? await Task.sleep(for: delay) }.value
                    throw failure
                }
                if let failure = launches.failWith { throw failure }
                let played = Played(pid: pid_t(40000 + launches.played.count), pod: pinned.pod, local: spec.localPort)
                launches.add(played)
                return played
            })
        forwards.podCheckInterval = .milliseconds(50)
        forwards.processCheckInterval = .milliseconds(20)
        forwards.backoffScale = 0.01
        return forwards
    }

    private func until(_ what: String, _ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func spec(_ target: KubeForwardTarget, _ port: Int, tab: UUID? = nil) -> KubeForwardSpec {
        KubeForwardSpec(context: "fake-dev", namespace: "shop", target: target, remotePort: port, localPort: 31234, tab: tab)
    }

    func testAServiceIsForwardedToAReadyEndpointsPodAndFollowsItsNextPod() async throws {
        let launches = Launches()
        let forwards = forwards(launches: launches)
        defer { forwards.stopAll() }
        let tab = UUID()
        let id = forwards.start(spec(.service("web"), 80, tab: tab), in: Self.dev)
        try await until("forwarding") { forwards.forward(id)?.isForwarding == true }
        XCTAssertEqual(launches.played.map(\.pod), ["web-a"], "the ready endpoint's, not web-b")
        XCTAssertEqual(forwards.forward(id)?.podPort, 8080, "the Service's targetPort, by name in the pod")
        XCTAssertEqual(forwards.forward(id)?.listeningPort?.forward?.pod, "web-a", "the pill names the pod")
        XCTAssertEqual(forwards.forwards(inTab: tab).count, 1)
        XCTAssertEqual(
            forwards.forward(id)?.kubectl, "kubectl port-forward pod/web-a 31234:8080 --context fake-dev --namespace shop --address 127.0.0.1")

        // The pod replaced: deleted, a new one ready behind the Service.
        api.deletePod("web-a", namespace: "shop")
        api.addPod("web-c", namespace: "shop", FakeKubeAPI.Pod(ports: [FakeKubeAPI.ContainerPort(8080, name: "http")]), labels: ["app": "web"])
        api.setFields("endpointslices.discovery.k8s.io", "web-x", namespace: "shop", Self.slice(ready: "web-c", notReady: "web-b"))
        try await until("on the new pod") { forwards.forward(id)?.isForwarding == true && forwards.forward(id)?.pod == "web-c" }
        XCTAssertEqual(launches.played.map(\.pod), ["web-a", "web-c"])
        XCTAssertTrue(launches.played[0].closed, "the old kubectl closed, by its pid")
        XCTAssertEqual(forwards.forward(id)?.restarts, 1)
        XCTAssertEqual(forwards.forward(id)?.spec.localPort, 31234, "on the same local port")

        // kubectl exits with the pod still there: started again, on it.
        launches.played[1].end("error: lost connection to pod")
        try await until("again") { launches.played.count == 3 && forwards.forward(id)?.isForwarding == true }
        XCTAssertEqual(launches.played.last?.pod, "web-c", "the pod pinned before, still ready, is kept")

        // The Service gone: it stops, and says so.
        api.delete("services", "web", namespace: "shop")
        launches.played[2].end("error: lost connection to pod")
        try await until("stopped") { forwards.forward(id)?.state.isStopped == true }
        XCTAssertEqual(forwards.forward(id)?.state, .stopped("svc/web is gone"))
        XCTAssertNil(forwards.forward(id)?.listeningPort, "no pill once stopped")
        XCTAssertEqual(launches.played.count, 3, "nothing started for a target that is gone")
        forwards.stop(id)
        XCTAssertNil(forwards.forward(id))
    }

    func testADeploymentGoesToItsReadyPodAndAPodToItself() async throws {
        let launches = Launches()
        let forwards = forwards(launches: launches)
        defer { forwards.stopAll() }
        let deployment = forwards.start(spec(.deployment("web"), 8080), in: Self.dev)
        try await until("the deployment's") { forwards.forward(deployment)?.isForwarding == true }
        XCTAssertEqual(forwards.forward(deployment)?.pod, "web-a", "its selector's ready pod")
        var pod = spec(.pod("web-b"), 8080)
        pod.localPort = 31235
        let direct = forwards.start(pod, in: Self.dev)
        try await until("the pod's") { forwards.forward(direct)?.isForwarding == true }
        XCTAssertEqual(forwards.forward(direct)?.pod, "web-b", "a pod itself, ready or not")
        XCTAssertEqual(forwards.takenPorts, [31234, 31235])
        // The pod goes: a pod target is gone with it.
        api.deletePod("web-b", namespace: "shop")
        try await until("stopped") { forwards.forward(direct)?.state.isStopped == true }
        XCTAssertEqual(forwards.forward(direct)?.state, .stopped("pod/web-b is gone"))
        XCTAssertTrue(launches.played.first { $0.pod == "web-b" }?.closed == true)
    }

    func testCanISaysNoAndNothingStarts() async throws {
        let launches = Launches()
        let forwards = forwards(canI: .no("RBAC: forbidden"), launches: launches)
        let id = forwards.start(spec(.service("web"), 80), in: Self.dev)
        try await until("stopped") { forwards.forward(id)?.state.isStopped == true }
        XCTAssertEqual(forwards.forward(id)?.state, .stopped("kubectl auth can-i create pods/portforward says no in shop: RBAC: forbidden"))
        XCTAssertTrue(launches.played.isEmpty)
    }

    func testFailuresBackOffThenStop() async throws {
        let launches = Launches()
        launches.failWith = .failed("unable to listen on port 31234")
        let forwards = forwards(launches: launches)
        let id = forwards.start(spec(.service("web"), 80), in: Self.dev)
        try await until("stopped", 10) { forwards.forward(id)?.state.isStopped == true }
        XCTAssertEqual(
            forwards.forward(id)?.state, .stopped("unable to listen on port 31234 — stopped after \(KubeForwardBackoff.maxFailures) tries"))
        XCTAssertEqual(forwards.forward(id)?.restarts, KubeForwardBackoff.maxFailures)

        // A failure that would run the exec plugin again isn't retried.
        launches.failWith = .stops("Sign in again: aws sso login --profile acme")
        forwards.startAgain(id)
        try await until("stopped again") { forwards.forward(id)?.state == .stopped("Sign in again: aws sso login --profile acme") }
        XCTAssertEqual(forwards.forward(id)?.restarts, KubeForwardBackoff.maxFailures, "not tried again")
    }

    func testAContextLeavingTheKubeconfigStopsItsForwardsAndStopAllClosesEvery() async throws {
        let launches = Launches()
        let forwards = forwards(launches: launches)
        let id = forwards.start(spec(.service("web"), 80), in: Self.dev)
        try await until("forwarding") { forwards.forward(id)?.isForwarding == true }
        forwards.contextsChanged(KubeContextList(contexts: [Self.dev], current: "fake-dev"))
        XCTAssertEqual(forwards.forward(id)?.isForwarding, true, "the same context: kept")
        let elsewhere = KubeContext(
            name: "fake-dev", cluster: "other", server: "http://127.0.0.1:2", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: .remote, settings: KubeContextSettings())
        forwards.contextsChanged(KubeContextList(contexts: [elsewhere], current: "fake-dev"))
        XCTAssertEqual(forwards.forward(id)?.state, .stopped("fake-dev now names another cluster or user in the kubeconfig"))
        XCTAssertTrue(launches.played[0].closed)
        forwards.startAgain(id)
        XCTAssertEqual(
            forwards.forward(id)?.state, .stopped("fake-dev now names another cluster or user in the kubeconfig"),
            "not started again on a cluster it never went to")
        XCTAssertEqual(launches.played.count, 1)

        forwards.contextsChanged(KubeContextList(contexts: [Self.dev], current: "fake-dev"))
        var other = spec(.service("web"), 80)
        other.localPort = 31299
        let second = forwards.start(other, in: Self.dev)
        try await until("the other") { forwards.forward(second)?.isForwarding == true }
        forwards.contextsChanged(KubeContextList())
        XCTAssertEqual(forwards.forward(second)?.state, .stopped("fake-dev is no longer in the kubeconfig"))
        XCTAssertTrue(launches.played[1].closed)
        forwards.startAgain(second)
        XCTAssertEqual(forwards.forward(second)?.state, .stopped("fake-dev is no longer in the kubeconfig"), "nothing to start again on")

        forwards.stopAll()
        XCTAssertTrue(forwards.forwards.isEmpty)
        XCTAssertTrue(launches.played.allSatisfy(\.closed), "every kubectl closed")
    }

    /// A forward that stopped by itself keeps nothing of a context renamed
    /// onto another cluster: Start Again is refused, as for a running one.
    /// Repointed at the same cluster as production, it is started again red.
    func testAStoppedForwardsContextRepointedIsNotStartedAgainThere() async throws {
        let launches = Launches()
        let forwards = forwards(launches: launches)
        defer { forwards.stopAll() }
        let id = forwards.start(spec(.pod("web-a"), 8080), in: Self.dev)
        try await until("forwarding") { forwards.forward(id)?.isForwarding == true }
        api.deletePod("web-a", namespace: "shop")
        try await until("stopped") { forwards.forward(id)?.state == .stopped("pod/web-a is gone") }
        api.addPod("web-a", namespace: "shop", FakeKubeAPI.Pod(ports: [FakeKubeAPI.ContainerPort(8080, name: "http")]), labels: ["app": "web"])

        // The same cluster, now classed production: kept, its class read again.
        let red = KubeContext(
            name: "fake-dev", cluster: "fake-dev", server: "http://127.0.0.1:1", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: .production, settings: KubeContextSettings())
        forwards.contextsChanged(KubeContextList(contexts: [red], current: "fake-dev"))
        XCTAssertEqual(forwards.forward(id)?.state, .stopped("pod/web-a is gone"), "a stopped one stays stopped")
        XCTAssertEqual(forwards.forward(id)?.production, true)
        forwards.startAgain(id)
        try await until("again") { forwards.forward(id)?.isForwarding == true }
        XCTAssertEqual(forwards.forward(id)?.listeningPort?.forward?.production, true, "its pill red")

        api.deletePod("web-a", namespace: "shop")
        try await until("stopped again") { forwards.forward(id)?.state.isStopped == true }
        let elsewhere = KubeContext(
            name: "fake-dev", cluster: "acme-prod", server: "http://127.0.0.1:2", namespace: "shop", user: "admin", auth: KubeAuth.none, file: nil,
            contextClass: .remote, settings: KubeContextSettings())
        forwards.contextsChanged(KubeContextList(contexts: [elsewhere], current: "fake-dev"))
        XCTAssertEqual(forwards.forward(id)?.state, .stopped("fake-dev now names another cluster or user in the kubeconfig"))
        let launched = launches.played.count
        forwards.startAgain(id)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(forwards.forward(id)?.state, .stopped("fake-dev now names another cluster or user in the kubeconfig"))
        XCTAssertEqual(launches.played.count, launched, "nothing started on the other cluster")
    }

    /// An edit while kubectl starts slowly: the old run's launch failing
    /// later (a credential failure) leaves the new run alone — its task
    /// still stoppable, its kubectl open, its state its own.
    func testAnEditDuringASlowLaunchThatFailsLaterLeavesTheNewRunAlone() async throws {
        let launches = Launches()
        launches.slowly(.milliseconds(300), failing: .stops("Sign in again: aws sso login --profile acme"))
        let forwards = forwards(launches: launches)
        defer { forwards.stopAll() }
        let id = forwards.start(spec(.service("web"), 80), in: Self.dev)
        try await until("starting") { if case .starting = forwards.forward(id)?.state { true } else { false } }
        var edited = spec(.service("web"), 80)
        edited.localPort = 31240
        edited.id = id
        forwards.edit(edited)
        try await until("forwarding, edited") { forwards.forward(id)?.isForwarding == true }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(forwards.forward(id)?.isForwarding, true, "not stopped by the old run's failure")
        XCTAssertEqual(launches.played.count, 1)
        XCTAssertFalse(launches.played[0].closed, "the new kubectl isn't closed by the old run")
        forwards.stop(id)
        XCTAssertTrue(launches.played[0].closed)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(launches.played.count, 1, "its task stopped: nothing started again")
    }

    /// A Service's pod that fails readiness leaves the Service: the forward
    /// follows it to a ready endpoint — skipping one without the port.
    func testAServicesPodTurningUnreadyIsLeftForAReadyEndpointWithThePort() async throws {
        let launches = Launches()
        let forwards = forwards(launches: launches)
        defer { forwards.stopAll() }
        let id = forwards.start(spec(.service("web"), 80), in: Self.dev)
        try await until("forwarding") { forwards.forward(id)?.pod == "web-a" && forwards.forward(id)?.isForwarding == true }

        // web-0 is ready but has no `http` (an old ReplicaSet's); web-b turns ready.
        api.addPod("web-0", namespace: "shop", FakeKubeAPI.Pod(ports: [FakeKubeAPI.ContainerPort(9090, name: "metrics")]), labels: ["app": "web"])
        api.updatePod("web-b", namespace: "shop") { $0.ready = 1 }
        api.updatePod("web-a", namespace: "shop") { $0.readyCondition = false }
        api.setFields(
            "endpointslices.discovery.k8s.io", "web-x", namespace: "shop",
            [
                "endpoints": [
                    ["conditions": ["ready": true], "targetRef": ["kind": "Pod", "name": "web-0"]],
                    ["conditions": ["ready": false], "targetRef": ["kind": "Pod", "name": "web-a"]],
                    ["conditions": ["ready": true], "targetRef": ["kind": "Pod", "name": "web-b"]],
                ]
            ])
        try await until("on web-b") { forwards.forward(id)?.pod == "web-b" && forwards.forward(id)?.isForwarding == true }
        XCTAssertTrue(launches.played[0].closed, "kubectl to the unready pod closed")
        XCTAssertEqual(launches.played.map(\.pod), ["web-a", "web-b"], "web-0, without the port, skipped")
        XCTAssertEqual(forwards.forward(id)?.podPort, 8080)
    }

    /// Stopped while its kubectl hasn't said it listens: kubectl ends now,
    /// not when it says so or the 30 s pass.
    func testStoppingAForwardWhoseKubectlNeverSaysItListensEndsItsPid() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("otkf-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("kubectl")
        try "#!/bin/sh\nexec sleep 60\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let before = Set(ManagedProcess.livePIDs)
        let forwards = KubeForwards(
            client: { [socket] context in KubeClient(KubeSocketConnection(socket: socket!, context: context.name)) },
            canI: { _, _ in .yes },
            launch: { _, _, _ in
                try await ManagedProcess.start(
                    ManagedProcess.Launch(executable: script, arguments: [], readiness: .line(KubePortForwardCommand.isReady), timeout: 30))
            })
        defer { forwards.stopAll() }
        let id = forwards.start(spec(.pod("web-a"), 8080), in: Self.dev)
        var pid: pid_t?
        try await until("kubectl started") {
            pid = Set(ManagedProcess.livePIDs).subtracting(before).first
            return pid != nil
        }
        guard let pid else { return }
        if case .starting = forwards.forward(id)?.state {} else { XCTFail("starting: \(String(describing: forwards.forward(id)?.state))") }
        forwards.stop(id)
        try await until("its pid ended", 2) { kill(pid, 0) != 0 }
    }

    /// kubectl run for real — a stand-in that listens and answers, as the
    /// scenario's does — through the proxies' kubectl and environment: the
    /// test's own kubeconfig alone, HOME and cache the run's, ready on its
    /// `Forwarding from` line, and closed by its pid.
    func testTheRealLaunchIsReadyOnItsLineAndClosedByItsPid() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("otkf-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let kubeconfig = folder.appendingPathComponent("config.yaml")
        try "apiVersion: v1\nkind: Config\n".write(to: kubeconfig, atomically: true, encoding: .utf8)
        let log = folder.appendingPathComponent("forwards.log")
        guard let script = E2ERunner.writeStandInForward(in: folder.appendingPathComponent("bin"), log: log) else { return XCTFail("the stand-in") }
        let sockets = KubeSocketFolder(base: folder)
        defer { sockets.remove() }
        let planner = KubeProxyPlanner(
            folder: sockets, guarded: true, home: FileManager.default.homeDirectoryForCurrentUser, kubeconfigs: { _ in [kubeconfig] },
            baseEnvironment: { ["PATH": "/usr/bin:/bin"] })
        var configuration = KubeProxies.Configuration()
        configuration.kubectlPath = script.path
        guard let local = KubeForwardPortChoice.free(taken: [], isBound: { ListeningPorts.isBound($0) }) else { return XCTFail("a free port") }
        var spec = spec(.pod("web-a"), 8080)
        spec.localPort = local
        let process = try await KubeForwards.start(
            Self.dev, spec, KubeForwardResolve.Pinned(pod: "web-a", remotePort: 8080), configuration: configuration, proxies: nil, planner: planner)
        XCTAssertTrue(process.isRunning)
        XCTAssertTrue(ManagedProcess.livePIDs.contains(process.pid), "a managed process, closed at quit")
        let said = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(
            said.hasPrefix(kubeconfig.path + "|port-forward pod/web-a \(local):8080 --context fake-dev --namespace shop --address 127.0.0.1 --cache-dir "),
            said)
        XCTAssertTrue(ListeningPorts.isBound(local), "it listens")
        let pid = process.pid
        process.close()
        try await until("ended") { kill(pid, 0) != 0 }
        try await until("not listening") { !ListeningPorts.isBound(local) }

        // One that can't listen: kubectl's error, said.
        let blocker = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(blocker) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(local)).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(blocker, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        Darwin.listen(blocker, 1)
        do {
            _ = try await KubeForwards.start(
                Self.dev, spec, KubeForwardResolve.Pinned(pod: "web-a", remotePort: 8080), configuration: configuration, proxies: nil, planner: planner)
            XCTFail("it can't listen")
        } catch let failure as KubeForwardFailure {
            XCTAssertEqual(failure, .failed("error: unable to listen on port \(local): Address already in use"))
        }
    }
}

/// The page's `f`: the sheet with the target's ports, a free local port,
/// can-i asked; Forward starts it pinned to the tab under the page.
@MainActor
final class KubeForwardPageTests: XCTestCase {
    func testFOpensTheSheetAndForwardStartsIt() async throws {
        let socket = "/tmp/otkp-\(UInt32.random(in: 0...UInt32.max)).sock"
        let api = FakeKubeAPI(socket: socket)
        try api.start()
        defer { api.stop() }
        api.addNamespace("shop")
        api.addPod("web-1", namespace: "shop", FakeKubeAPI.Pod(ports: [FakeKubeAPI.ContainerPort(8080, name: "http")]))
        let context = KubeContext(
            name: "fake-dev", cluster: "fake-dev", server: "http://127.0.0.1:1", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: .remote, settings: KubeContextSettings())
        let model = KubernetesModel(proxies: KubeProxies())
        let list = KubeContextList(contexts: [context], current: "fake-dev")
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.flushInterval = .milliseconds(20)
        model.statusInterval = .milliseconds(50)
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
        model.statusOverride = { _ in .open }
        model.access.run = { _, _, access in access == .portForward ? .yes : .no(nil) }
        let launches = KubeForwardsTests.Launches()
        let forwards = KubeForwards(
            client: { context in KubeClient(KubeSocketConnection(socket: socket, context: context.name)) },
            canI: { context, namespace in await model.access.answer(context, namespace: namespace, .portForward) },
            launch: { _, spec, pinned in
                let played = KubeForwardsTests.Played(pid: 41000, pod: pinned.pod, local: spec.localPort)
                launches.add(played)
                return played
            })
        defer { forwards.stopAll() }
        let page = KubernetesPageModel(model: model, forwards: forwards)
        page.isPortBound = { $0 == 8080 }
        let tab = UUID()
        var actions = KubernetesActions(run: { _ in }, settings: {}, copy: { _ in }, copySecret: { _ in })
        actions.currentTab = { tab }
        var opened: [URL] = []
        actions.openURL = { opened.append($0) }
        page.actions = actions
        model.show()
        defer { model.hide() }
        let deadline = Date().addingTimeInterval(5)
        while model.rows.count < 1 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        page.selection = ["shop/web-1"]
        XCTAssertEqual(page.verbs(for: ["shop/web-1"]).filter { $0.title == "Port-forward…" || $0.title == "Quick Forward" }.count, 2)
        XCTAssertTrue(page.press("f"))
        XCTAssertEqual(page.forwardDraft?.target, .pod("web-1"))
        while (page.forwardDraft?.remote.isEmpty ?? true || page.forwardDraft?.unavailable != nil) && Date() < deadline.addingTimeInterval(5) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(page.forwardDraft?.offered.map(\.port), [8080])
        XCTAssertEqual(page.forwardDraft?.remote, "8080")
        let local = Int(page.forwardDraft?.local ?? "") ?? 0
        XCTAssertTrue(KubeForwardPortChoice.range.contains(local), "8080 is held here: one at random")
        XCTAssertFalse(page.press("o"), "the sheet has the keys")
        page.forwardDraft?.local = "80"
        XCTAssertNil(page.confirmForward())
        XCTAssertEqual(page.forwardProblem, "Ports under 1024 need root; pick one above.")
        page.forwardDraft?.local = "\(local)"
        let id = try XCTUnwrap(page.confirmForward())
        XCTAssertNil(page.forwardDraft)
        XCTAssertEqual(forwards.forward(id)?.spec.tab, tab, "the tab under the page has its pill")
        while forwards.forward(id)?.isForwarding != true && Date() < deadline.addingTimeInterval(10) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(launches.played.map(\.pod), ["web-1"])
        XCTAssertTrue(page.press("o"))
        XCTAssertEqual(opened, [URL(string: "http://localhost:\(local)")!])
        XCTAssertTrue(page.press("9"))
        XCTAssertEqual(page.section, .forwards)
        XCTAssertFalse(page.showsSection, "no kind's list")
        XCTAssertEqual(page.title, "Forwards")
        XCTAssertTrue(page.press("1"), "and back")
        XCTAssertEqual(page.section, .workloads)
        XCTAssertEqual(api.writes, [])
    }
}
