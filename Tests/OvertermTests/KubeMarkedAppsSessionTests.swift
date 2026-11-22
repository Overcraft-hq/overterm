import Foundation
import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell
@testable import OvertermOvergit
@testable import OvertermAPI
@testable import OvertermNotes
@testable import OvertermSimulator
@testable import OvertermUsage
@testable import OvertermSettingsPage
@testable import OvertermAgents

/// The apps read from Argo CD's marks (`KubeMarkedAppsSession`, gitops.md
/// 14.4) against a fake spoke on a socket of the tests' own
/// (`FakeKubeAPI.addSpoke`) — never a real cluster; every assertion from
/// the fake's log of requests or the session's own counts, never a moment
/// sampled: nothing of Argo CD's or Flux's is asked where they aren't
/// served; three watches, and three still for six namespaces; a kind left
/// without a watch listed every 5 min; the settle (M1b) a GET of one
/// object each, after M2's moves, once every first list is in, what may be
/// a problem first — just synced too —, within the context's 60 a minute —
/// kept across a hide, a drop and another context, never more at a slow
/// server — never a list of whole objects; a stuck single-replica rollout
/// whose cells say `1/1` Progressing once settled; M2 only for a moved
/// generation, none under 2,000 readiness-only row events; M3 never
/// watched, M3b a GET only of a CronJob or an `<unknown>` HPA; a refusal
/// across the cluster read where it may be, said; argoproj.io failing
/// discovery "couldn't tell", a failing metrics.k8s.io not; derived where
/// Applications are served with none, refused, or missing for most marked
/// apps; hidden, every read ends; no discovery, no request; the sentinel
/// in nothing kept. Only GETs, never a Secret, a ConfigMap, a ReplicaSet
/// or a pod.
@MainActor
final class KubeMarkedAppsSessionTests: XCTestCase {
    nonisolated(unsafe) private var fakes: [FakeKubeAPI] = []
    private var now = Date()

    override func tearDown() {
        for api in fakes {
            XCTAssertEqual(api.requests.filter { $0.method != "GET" }, [], "only GETs")
            let paths = api.requests.map(\.path)
            XCTAssertFalse(paths.contains { $0.contains("/secrets") || $0.contains("/configmaps") }, "never a Secret or a ConfigMap")
            XCTAssertFalse(paths.contains { $0.contains("/replicasets") || $0.contains("/pods") }, "never a ReplicaSet or a pod")
            XCTAssertFalse(api.requests.contains { $0.isWatch && $0.query["includeObject"] == "Object" }, "never a whole-object watch")
            let marksKinds = ["/deployments", "/statefulsets", "/daemonsets", "/rollouts", "/cronjobs", "/horizontalpodautoscalers", "/services", "/ingresses", "/persistentvolumeclaims", "/jobs"]
            let wholeLists = api.requests.filter { request in
                !request.isDiscovery && !request.accept.contains("as=Table") && marksKinds.contains { request.path.hasSuffix($0) }
            }
            XCTAssertEqual(wholeLists.map(\.path), [], "never a list of whole objects: rows, and a GET of one")
            api.stop()
        }
        fakes = []
    }

    private func startFake(_ options: FakeKubeAPI.SpokeOptions = FakeKubeAPI.SpokeOptions()) throws -> (FakeKubeAPI, KubeClient, FakeKubeAPI.Spoke) {
        let socket = "/tmp/othm-\(UInt32.random(in: 0...UInt32.max)).sock"
        let api = FakeKubeAPI(socket: socket)
        try api.start()
        fakes.append(api)
        let spoke = api.addSpoke(options, now: now)
        return (api, KubeClient(KubeSocketConnection(socket: socket, context: "fake-prod")), spoke)
    }

    private func eventually(_ seconds: Double = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func session() -> KubeMarkedAppsSession {
        let session = KubeMarkedAppsSession()
        session.flushInterval = .milliseconds(20)
        // The tick is called by the tests that want it, at the clock they set.
        session.tickInterval = .seconds(3600)
        session.clock = { [unowned self] in self.now }
        return session
    }

    private func app(_ session: KubeMarkedAppsSession, _ instance: String) -> KubeMarkedRanked? {
        session.apps.first { $0.app.key.instance == instance }
    }

    /// Every first list in, and every object asked for read (M1b, M3b) —
    /// the session's clock moved a minute on whenever the minute's 60 are
    /// taken (`advancing`).
    private func settled(_ session: KubeMarkedAppsSession, advancing: Bool = true, _ seconds: Double = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let done =
                session.state == .live && session.store?.done.contains("rows:services") == true && session.store?.done.contains("rows:cronjobs.batch") == true
                && session.reading.checking == nil && session.refetchIdle && session.isMerged
            if done { return true }
            if advancing, session.takenLastMinute >= KubeMarkedRefetch.perMinute, session.getsQueued == 0 { now = now.addingTimeInterval(61) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func argoOrFlux(_ path: String) -> Bool { path.contains("argoproj.io") || path.contains("toolkit.fluxcd.io") }

    /// An object's GET (M1b, M2, M3b): one by name, not a list.
    private func objectGETs(_ api: FakeKubeAPI) -> [FakeKubeAPI.Request] {
        api.requests.filter { request in
            let parts = request.path.split(separator: "/").count
            return !request.isWatch && !request.isDiscovery && request.path.contains("/namespaces/")
                && ((request.path.hasPrefix("/apis/") && parts == 7) || (request.path.hasPrefix("/api/") && parts == 6))
        }
    }

    /// Nothing the session keeps carries what the allow-lists drop.
    private func assertNoSentinel(_ session: KubeMarkedAppsSession, file: StaticString = #filePath, line: UInt = #line) {
        let sentinel = FakeKubeAPI.gitOpsSentinel
        for (what, kept) in [("apps", String(describing: session.apps)), ("store", String(describing: session.store)), ("reading", String(describing: session.reading))] {
            XCTAssertFalse(kept.contains(sentinel), "the sentinel in the session's \(what)", file: file, line: line)
        }
    }

    private func makeGitOps() -> KubeGitOpsSession {
        let gitOps = KubeGitOpsSession()
        gitOps.flushInterval = .milliseconds(20)
        gitOps.marked.flushInterval = .milliseconds(20)
        return gitOps
    }

    // MARK: A spoke

    func testASpokesAppsComeFromTheirMarksAndArgoCDIsNeverAsked() async throws {
        let (api, client, spoke) = try startFake()
        let discovery = try await client.discover()
        api.forgetRequests()
        let gitOps = makeGitOps()
        gitOps.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let session = gitOps.marked
        let read = await settled(session)
        XCTAssertTrue(read, "\(session.state) \(session.reading) \(session.store?.done ?? [])")
        XCTAssertEqual(gitOps.marksMode, .only(.notServed))
        XCTAssertEqual(KubeMarkedAppsMode.Reason.notServed.line(context: "fake-prod"), "Argo CD runs in another cluster — not in your kubeconfig.")
        XCTAssertFalse(api.requests.contains { argoOrFlux($0.path) }, "no Argo CD or Flux kind asked: \(api.requests.map(\.path).filter(argoOrFlux))")
        let names = Set(session.apps.map(\.app.key.instance))
        XCTAssertTrue(names.isSuperset(of: spoke.apps), "every plain app")
        XCTAssertTrue(names.contains(spoke.labelOnly), "an instance label alone is an app")
        XCTAssertFalse(names.contains("fake-metrics-agent"), "Helm's instance label isn't")
        XCTAssertFalse(names.contains { $0.contains("garbled") || $0.contains("acme-x") }, "garbled marks name nobody")
        XCTAssertGreaterThanOrEqual(session.tally.unparsed, 2)
        XCTAssertGreaterThan(session.tally.copied, 0, "the copies on HPAs and PDBs")
        XCTAssertTrue(session.reading.isWhole)
        XCTAssertEqual(session.reading.count(session.apps.count), "\(session.apps.count) apps")
        // Problems first.
        let states = session.apps.map(\.health.state)
        XCTAssertEqual(states, states.sorted())
        XCTAssertEqual(session.apps.first?.health.state, .failed)
        assertNoSentinel(session)
        gitOps.drop()
        XCTAssertTrue(session.apps.isEmpty)
        XCTAssertNil(session.store)
    }

    func testEachStateIsArgoCDsRuleOnceChecked() async throws {
        let (_, client, spoke) = try startFake()
        let discovery = try await client.discover()
        let session = session()
        session.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let read = await settled(session)
        XCTAssertTrue(read, "\(session.reading)")
        func state(_ name: String) -> KubeGitOpsState? { app(session, name)?.health.state }
        // Cells `1/1`: only the object says the new pod never came up.
        XCTAssertEqual(state(spoke.stuck), .progressing, "\(app(session, spoke.stuck)?.health.why ?? "")")
        XCTAssertEqual(app(session, spoke.stuck)?.health.why.contains("old replica"), true)
        XCTAssertEqual(state(spoke.stalled), .failed)
        XCTAssertEqual(app(session, spoke.stalled)?.health.why.contains("ProgressDeadlineExceeded"), true)
        XCTAssertEqual(state(spoke.paused), .paused, "cells 2/2; its object is paused")
        XCTAssertEqual(state(spoke.statefulSet), .progressing, "a StatefulSet is never Degraded")
        XCTAssertEqual(state(spoke.hpa), .failed, "an HPA whose metrics fail, read whole")
        XCTAssertEqual(state(spoke.serviceOnly), .unknown, "no workload read")
        XCTAssertEqual(state(spoke.loadBalancer), .progressing)
        XCTAssertEqual(state(spoke.cronJob), .failed, "its last run failed, read whole")
        XCTAssertEqual(state(spoke.claim), .progressing)
        // A failed hook Job is shown under its app, never its health.
        XCTAssertEqual(state(spoke.hooked), .ready)
        XCTAssertEqual(app(session, spoke.hooked)?.app.hooks.map(\.id.name), ["acme-orders-migrate"])
        XCTAssertEqual(app(session, spoke.labelOnly)?.app.mark, .argoInstance)
        // A plain app is settled, not "from its row".
        XCTAssertEqual(app(session, spoke.apps[1])?.health.state, .ready)
        XCTAssertEqual(app(session, spoke.apps[1])?.health.fromRows, false)
        session.drop()
    }

    /// A copied Argo CD mark on a workload (14.1): the surveyed production
    /// spoke has a Deployment an operator made whose tracking id names
    /// another app's Deployment, and copies on Services. Counted, never a
    /// member, shown under the app the mark names — and never read by GET:
    /// the settle reads members' objects, a copy is only listed.
    func testACopiedMarkOnAWorkloadIsNeverReadAndNeverAMember() async throws {
        let (api, client, spoke) = try startFake()
        let discovery = try await client.discover()
        // The spoke's own copies (on HPAs), counted first.
        let plain = session()
        plain.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let plainRead = await settled(plain)
        XCTAssertTrue(plainRead, "\(plain.reading)")
        let spokeCopies = plain.tally.copied
        plain.drop()

        // An operator's Deployment and its Service, each carrying team-0's acme-svc-000's own tracking id.
        let (namespace, deployment) = spoke.deployments[0]
        let owner = spoke.apps[0]
        api.addCopiedMark("deployments.apps", "acme-operand", namespace: namespace, app: owner, of: deployment, now: now)
        api.addCopiedMark("services", "acme-operand-metrics", namespace: namespace, app: owner, of: deployment, now: now)
        let copies: Set<KubeMarkedMember.ID> = [
            .init(kind: .deployment, namespace: namespace, name: "acme-operand"), .init(kind: .service, namespace: namespace, name: "acme-operand-metrics"),
        ]
        api.forgetRequests()
        let session = session()
        session.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let read = await settled(session)
        XCTAssertTrue(read, "\(session.state) \(session.reading) \(session.store?.done ?? [])")
        XCTAssertEqual(session.tally.copied, spokeCopies + 2, "both counted")
        XCTAssertFalse(session.apps.contains { $0.app.members.contains { copies.contains($0.id) } }, "neither is anybody's member")
        let named = try XCTUnwrap(app(session, owner), "the app their marks name")
        XCTAssertEqual(Set(named.app.copies.map(\.id)).intersection(copies), copies, "shown under the app their marks name")
        XCTAssertEqual(
            named.app.members.filter { $0.id.kind == .deployment }.map(\.id), [.init(kind: .deployment, namespace: namespace, name: deployment)],
            "its own Deployment its only one")
        // Listed as rows (M1's watch, M3's list), never asked for by name.
        XCTAssertTrue(api.requests.contains { $0.path == "/apis/apps/v1/deployments" && $0.query["includeObject"] == "Metadata" })
        XCTAssertTrue(api.requests.contains { $0.path == "/api/v1/services" && $0.query["includeObject"] == "Metadata" })
        XCTAssertFalse(api.requests.contains { $0.path == "/apis/apps/v1/namespaces/\(namespace)/deployments/acme-operand" }, "never read by GET")
        XCTAssertFalse(api.requests.contains { $0.path == "/api/v1/namespaces/\(namespace)/services/acme-operand-metrics" })
        XCTAssertTrue(
            objectGETs(api).contains { $0.path == "/apis/apps/v1/namespaces/\(namespace)/deployments/\(deployment)" }, "the settle read the member it names")
        assertNoSentinel(session)
        session.drop()
    }

    func testArgoRolloutsAreReadForTheirAppsHealthOnly() async throws {
        var options = FakeKubeAPI.SpokeOptions()
        options.apps = 4
        options.rollouts = true
        let (api, client, spoke) = try startFake(options)
        let discovery = try await client.discover()
        api.forgetRequests()
        let session = session()
        session.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let read = await settled(session)
        XCTAssertTrue(read, "\(session.reading)")
        XCTAssertTrue(session.reading.rolloutsServed)
        guard let canary = app(session, spoke.rollout) else { return XCTFail("the Rollout's app") }
        XCTAssertEqual(canary.health.state, .ready, canary.health.why)
        // The Rollout's object settled it: its workloadRef from the GET.
        let rollout = canary.app.members.first { $0.id.kind == .rollout }
        XCTAssertEqual(rollout?.workloadRef, "acme-canary", "from its object")
        XCTAssertTrue(objectGETs(api).contains { $0.path == "/apis/argoproj.io/v1alpha1/namespaces/team-0/rollouts/acme-canary" })
        // Its Deployment, scaled to 0 by the Rollout, is said so — never a
        // problem, and never the workload the app's health was read from.
        guard let deployment = canary.app.members.first(where: { $0.id.kind == .deployment }) else { return XCTFail("its Deployment") }
        XCTAssertEqual(KubeMarkedHealth.member(deployment, in: canary.app)?.sentence, KubeMarkedHealth.scaledByRollout)
        XCTAssertFalse(canary.health.causes.contains { $0.member == deployment.id })
        XCTAssertEqual(app(session, spoke.rolloutDegraded)?.health.state, .failed)
        XCTAssertEqual(api.requests.filter { $0.isWatch }.count(where: { $0.path.contains("/rollouts") }), 1, "its rows followed, as a Deployment's")
        XCTAssertFalse(api.requests.contains { $0.path.contains("argoproj.io") && !$0.path.contains("/rollouts") && !$0.isDiscovery }, "nothing else of Argo's")
        session.drop()
    }

    /// The Rollout's object not read (refused in its namespace): its app is
    /// Unknown, never Ready from the Deployment it scales to 0.
    func testARolloutNotReadLeavesItsAppUnknownNeverReady() async throws {
        var options = FakeKubeAPI.SpokeOptions()
        options.apps = 4
        options.rollouts = true
        let (api, client, spoke) = try startFake(options)
        let discovery = try await client.discover()
        api.forbidden = ["rollouts@team-0"]
        let session = session()
        session.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let read = await settled(session)
        XCTAssertTrue(read, "\(session.reading)")
        XCTAssertTrue(api.requests.contains { $0.path == "/apis/argoproj.io/v1alpha1/namespaces/team-0/rollouts/acme-canary" }, "asked, refused")
        guard let canary = app(session, spoke.rollout) else { return XCTFail("the Rollout's app") }
        XCTAssertEqual(canary.health.state, .unknown, canary.health.why)
        XCTAssertEqual(canary.health.why, "not read yet")
        XCTAssertNil(canary.app.members.first { $0.id.kind == .rollout }?.workloadRef)
        let deployment = canary.app.members.first { $0.id.kind == .deployment }
        XCTAssertEqual(deployment.flatMap { KubeMarkedHealth.member($0, in: canary.app) }?.sentence, KubeMarkedHealth.scaledByRollout)
        session.drop()
    }

    // MARK: Watches and lists

    func testThreeWatchesAndSixNamespacesStillThree() async throws {
        let (api, client, _) = try startFake()
        let discovery = try await client.discover()
        api.forgetRequests()
        let session = session()
        session.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let watching = await eventually { api.openWatches == 3 && session.state == .live }
        XCTAssertTrue(watching, "\(api.openWatches)")
        XCTAssertEqual(session.openFollows, 3)
        session.hide()
        let closed = await eventually { api.openWatches == 0 }
        XCTAssertTrue(closed)
        api.forgetRequests()
        let six = KubeScope.of((0..<6).map { "team-\($0)" })
        session.show(context: "fake-prod", scope: six, discovery: discovery, client: client)
        let again = await eventually { api.openWatches == 3 && session.state == .live }
        XCTAssertTrue(again, "\(api.openWatches)")
        let watches = api.requests.filter(\.isWatch)
        XCTAssertTrue(watches.allSatisfy { !$0.path.contains("/namespaces/") }, "across the cluster, filtered: \(watches.map(\.path))")
        XCTAssertTrue(session.apps.allSatisfy { $0.app.namespaces.allSatisfy { six.includes($0) } }, "kept to the six")
        session.drop()
    }

    /// Two watches for three kinds: Deployments and StatefulSets followed,
    /// DaemonSets — the last — listed, and listed again every 5 min and on
    /// Refresh, never left frozen.
    func testAKindLeftWithoutAWatchIsListedEveryFiveMinutes() async throws {
        let (api, client, _) = try startFake()
        let discovery = try await client.discover()
        api.forgetRequests()
        let session = session()
        session.show(context: "fake-prod", scope: .all, discovery: discovery, client: client, watches: 2)
        let read = await settled(session)
        XCTAssertTrue(read, "\(session.reading)")
        XCTAssertEqual(session.openFollows, 2)
        XCTAssertEqual(Set(api.requests.filter(\.isWatch).map(\.path)), ["/apis/apps/v1/deployments", "/apis/apps/v1/statefulsets"])
        func daemonSetLists() -> Int { api.requests.count { !$0.isWatch && $0.path == "/apis/apps/v1/daemonsets" } }
        XCTAssertEqual(daemonSetLists(), 1)
        now = now.addingTimeInterval(KubeMarkedAppsSession.rereadEvery + 1)
        session.tick()
        let again = await eventually { daemonSetLists() == 2 }
        XCTAssertTrue(again, "listed again after 5 min")
        session.refresh()
        let refreshed = await eventually { daemonSetLists() == 3 }
        XCTAssertTrue(refreshed, "and on Refresh")
        XCTAssertLessThanOrEqual(
            api.requests.count { !$0.isWatch && $0.path == "/apis/apps/v1/deployments" && $0.accept.contains("as=Table") }, 1, "a followed kind isn't listed again")
        XCTAssertEqual(KubeMarkedAppsSession.allot(3, reads: .follow, kinds: 4), [1, 1, 1, 0], "Rollouts, last, the one listed")
        XCTAssertEqual(KubeMarkedAppsSession.allot(10, reads: .follow, kinds: 3), [3, 3, 3])
        XCTAssertEqual(KubeMarkedAppsSession.allot(10, reads: .periodic, kinds: 3), [0, 0, 0])
        session.drop()
    }

    /// Flux and Argo Rollouts served on a spoke: Flux's kinds and its
    /// controller take five, the marks' four kinds a watch each before a
    /// refused Flux kind's namespaces take what is left — ten at most.
    func testWithFluxServedTheMarksTakeTheirWatchesFirst() async throws {
        var options = FakeKubeAPI.SpokeOptions()
        options.apps = 6
        options.rollouts = true
        let (api, client, _) = try startFake(options)
        api.serveFlux()
        api.forbidden = ["kustomizations@cluster"]
        let discovery = try await client.discover()
        api.forgetRequests()
        let gitOps = makeGitOps()
        gitOps.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let session = gitOps.marked
        let read = await settled(session)
        XCTAssertTrue(read, "\(session.reading)")
        XCTAssertEqual(session.openFollows, 4, "every marks kind followed: \(session.reading.kinds)")
        let marksWatches = Set(api.requests.filter { $0.isWatch && !$0.path.contains("/namespaces/") }.map(\.path))
        XCTAssertTrue(
            marksWatches.isSuperset(of: ["/apis/apps/v1/deployments", "/apis/apps/v1/statefulsets", "/apis/apps/v1/daemonsets", "/apis/argoproj.io/v1alpha1/rollouts"]),
            "\(marksWatches)")
        XCTAssertLessThanOrEqual(api.openWatches, KubeScope.watchCap)
        XCTAssertEqual(gitOps.marksMode, .only(.notServed))
        gitOps.drop()
    }

    func testTheSettleIsGETsAfterMovesWithinTheMinutesSixty() async throws {
        var options = FakeKubeAPI.SpokeOptions()
        options.apps = 80
        options.padding = 500
        let (api, client, spoke) = try startFake(options)
        let discovery = try await client.discover()
        api.forgetRequests()
        let session = session()
        session.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        // The session's clock stands: one minute's 60, then the settle waits.
        let first = await eventually { session.state == .live && session.takenLastMinute == KubeMarkedRefetch.perMinute && session.getsQueued == 0 }
        XCTAssertTrue(first, "\(session.takenLastMinute)")
        XCTAssertEqual(objectGETs(api).count, 60, "60 a minute, one object each")
        XCTAssertLessThanOrEqual(session.mostTaken, 20, "20 a flush")
        XCTAssertLessThanOrEqual(session.mostInFlight, 4)
        XCTAssertFalse(session.refetchIdle, "the rest wait their minute")
        let checking = session.reading.said.first { $0.hasPrefix("checking rollouts 60 of ") }
        XCTAssertNotNil(checking, "\(session.reading.said)")
        XCTAssertTrue(session.apps.contains { $0.health.fromRows }, "not yet settled: from its row")
        // A settled Deployment's spec changes: M2's GET comes before the settle's.
        guard let target = spoke.deployments.first(where: { session.store?.settled[KubeMarkedMember.ID(kind: .deployment, namespace: $0.namespace, name: $0.name)] != nil })
        else { return XCTFail("one settled") }
        let (namespace, name) = (target.namespace, target.name)
        api.modify("deployments.apps", name, namespace: namespace) { body in
            var metadata = body["metadata"] as? [String: Any] ?? [:]
            metadata["generation"] = 5
            body["metadata"] = metadata
        }
        let moved = await eventually { session.rowsChanged > 0 }
        XCTAssertTrue(moved)
        api.forgetRequests()
        now = now.addingTimeInterval(61)
        let next = await eventually { self.objectGETs(api).count >= KubeMarkedAppsSession.inFlight }
        XCTAssertTrue(next)
        // Taken first, so among the first in flight (4 at once, in any order).
        let firstIn = objectGETs(api).prefix(KubeMarkedAppsSession.inFlight).map(\.path)
        XCTAssertTrue(firstIn.contains("/apis/apps/v1/namespaces/\(namespace)/deployments/\(name)"), "M2 first: \(firstIn)")
        let all = await settled(session)
        XCTAssertTrue(all, "\(session.reading)")
        XCTAssertLessThanOrEqual(session.mostTaken, 20)
        let paths = api.requests.filter { !$0.isWatch && !$0.isDiscovery && !$0.accept.contains("as=Table") }.map(\.path)
        XCTAssertEqual(paths.count, objectGETs(api).count, "only GETs of one object: \(paths.filter { !$0.contains("/namespaces/") })")
        XCTAssertEqual(Set(paths).count, paths.count, "each object once")
        assertNoSentinel(session)
        session.drop()
    }

    /// More to settle than the minute's 60 (D7, gitops.md 14.9.3: ≈1,150 on
    /// the surveyed spoke): what may be a problem — the rollout past its
    /// deadline, the StatefulSet 0/3, the Argo Rollouts whose phase no cell
    /// says, the CronJob, the `<unknown>` HPA — is taken first, ahead of a
    /// hundred ready-looking Deployments a name before them: across every
    /// kind, the settle waiting until every first list it orders by is in
    /// (the workloads', the CronJobs', the HPAs'), whichever came last. The
    /// session's own order, never the server's arrivals.
    func testWhatMayBeAProblemIsSettledFirst() async throws {
        var options = FakeKubeAPI.SpokeOptions()
        options.apps = 100
        options.padding = 500
        options.rollouts = true
        let (api, client, _) = try startFake(options)
        let discovery = try await client.discover()
        // The HPAs' list comes last, well after every other: the settle waits for it.
        api.answerSlowly("/apis/autoscaling/v2/horizontalpodautoscalers", milliseconds: 300)
        api.forgetRequests()
        let session = session()
        session.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let first = await eventually { session.state == .live && session.takenLastMinute == KubeMarkedRefetch.perMinute && session.getsQueued == 0 }
        XCTAssertTrue(first, "\(session.takenLastMinute)")
        let gets = objectGETs(api).map(\.path)
        XCTAssertEqual(gets.count, KubeMarkedRefetch.perMinute)
        XCTAssertGreaterThan(session.reading.checking ?? 0, 100, "more to settle than a minute's")
        let doubtful: [KubeMarkedMember.ID] = [
            .init(kind: .deployment, namespace: "team-2", name: "acme-cart"), .init(kind: .statefulSet, namespace: "team-4", name: "acme-ledger-db"),
            .init(kind: .rollout, namespace: "team-0", name: "acme-canary"), .init(kind: .rollout, namespace: "team-1", name: "acme-blue"),
            .init(kind: .cronJob, namespace: "team-8", name: "acme-reindex"), .init(kind: .horizontalPodAutoscaler, namespace: "team-5", name: "acme-search"),
        ]
        // The first flush that took any: twenty, those six before every other.
        XCTAssertEqual(session.firstTaken.count, KubeMarkedRefetch.perFlush)
        XCTAssertEqual(Set(session.firstTaken.prefix(doubtful.count)), Set(doubtful), "\(session.firstTaken)")
        XCTAssertTrue(gets.contains("/apis/autoscaling/v2/namespaces/team-5/horizontalpodautoscalers/acme-search"), "read in that minute")
        // Their apps said by Argo CD's rule already, the Rollouts' too.
        let settledFirst = await eventually { session.isMerged && session.apps.first { $0.app.key.instance.hasSuffix("acme-blue-service") }?.health.state == .failed }
        XCTAssertTrue(settledFirst, "\(session.apps.map { "\($0.app.key.instance) \($0.health.state)" }.prefix(5))")
        session.drop()
    }

    /// More not ready by their rows than the minute's 60 — seventy
    /// Deployments — and a single replica stuck behind its old pod and a
    /// paused rollout whose cells read ready, both synced by Argo CD
    /// minutes ago: the two are said by Argo CD's rule in the first minute,
    /// the newest change first, not after the seventy (D-4, gitops.md
    /// 14.10: what cells hide, where M1b's settle exists for).
    func testJustSyncedUnderReadyCellsIsSettledInTheFirstMinute() async throws {
        var options = FakeKubeAPI.SpokeOptions()
        options.apps = 80
        options.notReady = 70
        options.padding = 500
        let (api, client, spoke) = try startFake(options)
        // Argo CD's server-side apply minutes ago on the two, its time on every row with managedFields.
        api.setManagedFields("deployments.apps", "acme-pay", namespace: "team-1", FakeKubeAPI.surveyManagedFields(desired: 1, argoChanged: now.addingTimeInterval(-180), now: now))
        api.setManagedFields("deployments.apps", "acme-batch", namespace: "team-3", FakeKubeAPI.surveyManagedFields(desired: 2, argoChanged: now.addingTimeInterval(-600), now: now))
        api.tableManagedFields = true
        let discovery = try await client.discover()
        let session = session()
        session.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        // The session's clock stands: one minute's 60.
        let first = await eventually { session.state == .live && session.takenLastMinute == KubeMarkedRefetch.perMinute && session.getsQueued == 0 && session.isMerged }
        XCTAssertTrue(first, "\(session.takenLastMinute)")
        XCTAssertEqual(
            Array(session.firstTaken.prefix(2)), [.init(kind: .deployment, namespace: "team-1", name: "acme-pay"), .init(kind: .deployment, namespace: "team-3", name: "acme-batch")],
            "the newest changes first: \(session.firstTaken.prefix(4))")
        let stuck = await eventually { self.app(session, spoke.stuck)?.health.fromRows == false && self.app(session, spoke.paused)?.health.fromRows == false }
        XCTAssertTrue(stuck, "\(String(describing: app(session, spoke.stuck)?.health)) \(String(describing: app(session, spoke.paused)?.health))")
        XCTAssertEqual(app(session, spoke.stuck)?.health.state, .progressing, "its cells read 1/1: its object says the new pod never came up")
        XCTAssertEqual(app(session, spoke.paused)?.health.state, .paused, "its cells read 2/2: its object is paused")
        // While some of the seventy still wait their minute, from their rows.
        let waiting = spoke.apps.suffix(options.notReady).filter { app(session, $0)?.health.fromRows == true }
        XCTAssertGreaterThan(waiting.count, 0, "more not ready than the minute's 60")
        XCTAssertTrue(waiting.allSatisfy { app(session, $0)?.health.state == .progressing }, "said from their rows meanwhile")
        session.drop()
    }

    /// A server slower than four in flight can keep up with: a GET's place
    /// is held until a minute after its answer, never freed unanswered —
    /// the minute's 60 taken while it is slow, the clock moved a minute on
    /// twice, the server fast again: no backlog goes out at once, never
    /// more than 60 GETs at the server in any minute of the session's clock
    /// (gitops.md 14.4.1; D7's fix pass: freed a minute after the take, a
    /// slow minute queued its next 60 behind the last's).
    func testASlowServerNeverSeesMoreThanSixtyAMinute() async throws {
        var options = FakeKubeAPI.SpokeOptions()
        options.apps = 200
        options.padding = 500
        let (api, client, _) = try startFake(options)
        let discovery = try await client.discover()
        api.answerObjectsSlowly(["deployments", "statefulsets", "daemonsets", "cronjobs", "horizontalpodautoscalers"], milliseconds: 150)
        api.forgetRequests()
        let session = session()
        session.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        // The minute's 60 taken; a few answered, most still waiting their turn.
        let slow = await eventually { session.state == .live && session.takenLastMinute == KubeMarkedRefetch.perMinute && self.objectGETs(api).count >= 8 }
        XCTAssertTrue(slow, "\(session.takenLastMinute) held, \(objectGETs(api).count) GETs")
        // What the fake saw while the session's clock read each minute: counted and moved on together, nothing awaited between.
        var seen = [objectGETs(api).count]
        now = now.addingTimeInterval(61)
        let refilled = await eventually { session.takenLastMinute == KubeMarkedRefetch.perMinute }
        XCTAssertTrue(refilled, "only the places answered free")
        seen.append(objectGETs(api).count)
        now = now.addingTimeInterval(61)
        // The server fast again: what waits goes out, within the minute's places alone.
        api.answerObjectsSlowly([], milliseconds: nil)
        let quiet = await eventually { session.getsQueued == 0 && session.takenLastMinute == KubeMarkedRefetch.perMinute }
        XCTAssertTrue(quiet, "\(session.getsQueued) waiting")
        seen.append(objectGETs(api).count)
        let minutes = [seen[0], seen[1] - seen[0], seen[2] - seen[1]]
        XCTAssertTrue(minutes.allSatisfy { $0 <= KubeMarkedRefetch.perMinute }, "GETs at the server in each minute: \(minutes)")
        XCTAssertGreaterThan(minutes[1] + minutes[2], 0, "the settle went on")
        session.drop()
    }

    /// The minute is the context's (gitops.md 14.4.1; D7's fix pass): the
    /// page hidden and shown again (`drop`: what was read goes), another
    /// context and back — within the minute no object of it read again;
    /// another context's minute is its own; a minute on, its 60 again.
    func testTheMinuteStandsAcrossADropAndAnotherContext() async throws {
        var options = FakeKubeAPI.SpokeOptions()
        options.apps = 80
        options.padding = 500
        let (api, client, _) = try startFake(options)
        let discovery = try await client.discover()
        let gitOps = makeGitOps()
        let marked = gitOps.marked
        marked.clock = { [unowned self] in self.now }
        marked.tickInterval = .seconds(3600)
        func spent(_ context: String) async -> Bool {
            await eventually { marked.context == context && marked.state == .live && marked.isMerged && marked.takenLastMinute == KubeMarkedRefetch.perMinute && marked.getsQueued == 0 }
        }
        /// Shown, every first list in, its settle waiting its turn: nothing it could take.
        func waiting(_ context: String) async -> Bool {
            await eventually {
                marked.context == context && marked.state == .live && marked.isMerged && marked.store?.done.contains("rows:horizontalpodautoscalers.autoscaling") == true
                    && !marked.refetchIdle && marked.getsQueued == 0
            }
        }
        api.forgetRequests()
        gitOps.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let first = await spent("fake-prod")
        XCTAssertTrue(first)
        XCTAssertEqual(objectGETs(api).count, KubeMarkedRefetch.perMinute)
        // The page hidden and shown again: what was read goes, the minute doesn't.
        gitOps.drop()
        XCTAssertNil(marked.store)
        api.forgetRequests()
        gitOps.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let shown = await waiting("fake-prod")
        XCTAssertTrue(shown, "\(marked.state) \(marked.refetchIdle)")
        XCTAssertEqual(objectGETs(api).map(\.path), [], "dropped and shown again within the minute: no GET")
        XCTAssertEqual(marked.takenLastMinute, KubeMarkedRefetch.perMinute)
        // Another context: a minute of its own.
        gitOps.show(context: "fake-dev", scope: .all, discovery: discovery, client: client)
        let other = await spent("fake-dev")
        XCTAssertTrue(other)
        XCTAssertEqual(objectGETs(api).count, KubeMarkedRefetch.perMinute, "fake-dev's own 60")
        // And back within the minute: none again.
        api.forgetRequests()
        gitOps.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let back = await waiting("fake-prod")
        XCTAssertTrue(back)
        XCTAssertEqual(objectGETs(api).map(\.path), [], "fake-prod, fake-dev and fake-prod again within the minute: no GET")
        // A minute on: its 60 again, and no more.
        now = now.addingTimeInterval(61)
        let again = await spent("fake-prod")
        XCTAssertTrue(again)
        XCTAssertEqual(objectGETs(api).count, KubeMarkedRefetch.perMinute)
        gitOps.drop()
    }

    /// Hidden and shown again — another scope, the section left and
    /// back — the minute's 60 aren't given again; another context's are its own.
    func testTheMinutesSixtyStandAcrossAHide() async throws {
        var options = FakeKubeAPI.SpokeOptions()
        options.apps = 80
        options.padding = 500
        let (api, client, _) = try startFake(options)
        let discovery = try await client.discover()
        let session = session()
        session.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let first = await eventually { session.takenLastMinute == KubeMarkedRefetch.perMinute && session.getsQueued == 0 }
        XCTAssertTrue(first)
        session.hide()
        api.forgetRequests()
        session.show(context: "fake-prod", scope: .of(["team-8", "team-9"]), discovery: discovery, client: client)
        let shown = await eventually { session.state == .live && session.isMerged && !session.refetchIdle && session.getsQueued == 0 }
        XCTAssertTrue(shown)
        XCTAssertEqual(session.takenLastMinute, KubeMarkedRefetch.perMinute)
        XCTAssertEqual(objectGETs(api).map(\.path), [], "the same minute: no GET")
        session.drop()
        session.show(context: "fake-dev", scope: .all, discovery: discovery, client: client)
        let fresh = await eventually { !self.objectGETs(api).isEmpty }
        XCTAssertTrue(fresh, "dropped: a minute of its own")
        session.drop()
    }

    func testServicesAndHPAsAreListedNeverWatched() async throws {
        let (api, client, _) = try startFake()
        let discovery = try await client.discover()
        api.forgetRequests()
        let session = session()
        session.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let read = await settled(session)
        XCTAssertTrue(read)
        let watched = Set(api.requests.filter(\.isWatch).map(\.path))
        XCTAssertEqual(watched, ["/apis/apps/v1/deployments", "/apis/apps/v1/statefulsets", "/apis/apps/v1/daemonsets"])
        for path in [
            "/api/v1/services", "/apis/networking.k8s.io/v1/ingresses", "/api/v1/persistentvolumeclaims", "/apis/batch/v1/jobs", "/apis/batch/v1/cronjobs",
            "/apis/autoscaling/v2/horizontalpodautoscalers",
        ] {
            let asked = api.requests.filter { $0.path == path }
            XCTAssertFalse(asked.isEmpty, path)
            XCTAssertTrue(asked.allSatisfy { $0.accept.contains("as=Table") && $0.query["includeObject"] == "Metadata" }, "rows with their metadata: \(path)")
        }
        // M3b: a GET of the marked CronJob, and of the HPA whose target reads <unknown> — no other HPA's.
        let gets = objectGETs(api).map(\.path)
        XCTAssertEqual(gets.filter { $0.contains("/cronjobs/") }, ["/apis/batch/v1/namespaces/team-8/cronjobs/acme-reindex"])
        XCTAssertEqual(gets.filter { $0.contains("/horizontalpodautoscalers/") }, ["/apis/autoscaling/v2/namespaces/team-5/horizontalpodautoscalers/acme-search"])
        XCTAssertFalse(gets.contains { $0.contains("/services/") || $0.contains("/ingresses/") || $0.contains("/jobs/") }, "their cells say it")
        session.drop()
    }

    func testShownAgainWithinFiveMinutesReadsOnlyTheFollows() async throws {
        let (api, client, _) = try startFake()
        let discovery = try await client.discover()
        let session = session()
        session.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let read = await settled(session)
        XCTAssertTrue(read)
        let count = session.apps.count
        session.hide()
        api.forgetRequests()
        now = now.addingTimeInterval(120)
        session.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let again = await eventually { session.state == .live && session.apps.count == count && session.refetchIdle }
        XCTAssertTrue(again)
        XCTAssertEqual(objectGETs(api).map(\.path), [], "nothing settled is read again")
        XCTAssertFalse(api.requests.contains { $0.path == "/api/v1/services" || $0.path == "/apis/batch/v1/cronjobs" }, "no Service or CronJob list again")
        session.drop()
    }

    // MARK: M2

    func testAMovedGenerationIsReadAgainAndAReadyMoveIsNot() async throws {
        let (api, client, spoke) = try startFake()
        let discovery = try await client.discover()
        let session = session()
        session.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let read = await settled(session)
        XCTAssertTrue(read)
        let (namespace, name) = spoke.deployments[2]
        api.forgetRequests()
        // Its cells move, every one still equal, its generation the same: nothing read.
        let before = session.rowsChanged
        api.modify("deployments.apps", name, namespace: namespace, values: ["Ready": "3/3", "Up-to-date": 3, "Available": 3]) { _ in }
        let moved = await eventually { session.rowsChanged > before }
        XCTAssertTrue(moved)
        let quiet = await eventually { session.refetchIdle }
        XCTAssertTrue(quiet)
        XCTAssertEqual(objectGETs(api).map(\.path), [], "a ready row that stays ready isn't read")
        // Not ready, its generation the same (a pod restarting): its cells say it.
        let notReady = session.rowsChanged
        api.modify("deployments.apps", name, namespace: namespace, values: ["Ready": "2/3", "Available": 2]) { _ in }
        let turned = await eventually { session.rowsChanged > notReady && session.refetchIdle && session.isMerged }
        XCTAssertTrue(turned)
        XCTAssertEqual(objectGETs(api).map(\.path), [], "readiness alone isn't read")
        // A spec change: its generation moves (15 s past its last GET, an object's least).
        now = now.addingTimeInterval(KubeMarkedRefetch.perObject)
        api.modify("deployments.apps", name, namespace: namespace) { body in
            var metadata = body["metadata"] as? [String: Any] ?? [:]
            metadata["generation"] = 5
            body["metadata"] = metadata
        }
        let fetched = await eventually { self.objectGETs(api).contains { $0.path.hasSuffix("/deployments/\(name)") } && session.refetchIdle && session.isMerged }
        XCTAssertTrue(fetched, "\(api.requests.map(\.path))")
        assertNoSentinel(session)
        session.drop()
    }

    /// 14.9.3's leg: 2,000 readiness-only row events — every Deployment
    /// turned not ready and back, ten times, its generation never moving —
    /// cause no GET at all.
    func testTwoThousandReadinessOnlyEventsCauseNoGET() async throws {
        var options = FakeKubeAPI.SpokeOptions()
        options.apps = 100
        options.padding = 500
        let (api, client, spoke) = try startFake(options)
        let discovery = try await client.discover()
        let session = session()
        session.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let read = await settled(session)
        XCTAssertTrue(read, "\(session.reading)")
        api.forgetRequests()
        let before = session.rowsChanged
        let asked = session.getsAsked
        let deployments = spoke.deployments
        XCTAssertEqual(deployments.count, 100)
        api.churnReadiness(deployments, rounds: 10)
        let all = await eventually(60) { session.rowsChanged - before >= 2000 && session.refetchIdle && session.isMerged }
        XCTAssertTrue(all, "\(session.rowsChanged - before)")
        XCTAssertEqual(session.getsAsked, asked, "no GET asked")
        XCTAssertEqual(objectGETs(api).map(\.path), [], "none reached the server")
        session.drop()
    }

    // MARK: Refusals and discovery

    func testRefusedAcrossTheClusterIsReadWhereItMayBeAndSaid() async throws {
        let (api, client, _) = try startFake()
        api.forbidden = ["deployments@cluster"]
        let discovery = try await client.discover()
        api.forgetRequests()
        let session = session()
        session.show(context: "fake-prod", scope: .all, discovery: discovery, client: client, accessible: ["team-1", "team-2"])
        let read = await eventually { session.reading.listed.contains("Deployments") && session.state == .live }
        XCTAssertTrue(read, "\(session.reading)")
        XCTAssertFalse(api.requests.contains { $0.isWatch && $0.path.contains("/deployments") && $0.path.contains("/namespaces/") }, "no watch a namespace")
        let lists = api.requests.filter { $0.path.contains("/namespaces/") && $0.path.hasSuffix("/deployments") }
        XCTAssertEqual(Set(lists.map(\.path)), ["/apis/apps/v1/namespaces/team-1/deployments", "/apis/apps/v1/namespaces/team-2/deployments"])
        XCTAssertEqual(session.reading.fallback["Deployments"], ["team-1", "team-2"])
        XCTAssertTrue(session.reading.said.contains("Deployments refused across the cluster; read in team-1, team-2 every 5 min"), "\(session.reading.said)")
        XCTAssertFalse(session.reading.isWhole)
        let empty = session.reading.empty(context: "fake-prod", scope: .all, served: false)
        XCTAssertFalse(empty.contains("carries"), empty)
        XCTAssertEqual(session.reading.count(3)?.hasPrefix("At least 3 apps"), true)
        XCTAssertTrue(session.apps.allSatisfy { app in app.app.members.filter { $0.id.kind == .deployment }.allSatisfy { ["team-1", "team-2"].contains($0.id.namespace) } })
        session.drop()
    }

    func testRefusedWithNowhereToReadSaysSoNeverNoMarks() async throws {
        let (api, client, _) = try startFake()
        api.forbidden = ["deployments@cluster"]
        let discovery = try await client.discover()
        let session = session()
        session.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let refused = await eventually { session.reading.refused["Deployments"] != nil }
        XCTAssertTrue(refused)
        XCTAssertEqual(session.reading.refused["Deployments"], [KubeMarkedReading.acrossTheCluster])
        XCTAssertEqual(
            session.reading.empty(context: "fake-prod", scope: .all, served: false),
            "No Argo CD marks found in what could be read: Deployments refused across the cluster")
        session.drop()
    }

    func testArgoFailingDiscoveryCantTellAndAFailingMetricsGroupStillCan() async throws {
        let (api, client, _) = try startFake(FakeKubeAPI.SpokeOptions(apps: 2, states: false))
        api.addCRD(group: "argoproj.io", version: "v1alpha1", plural: "workflows", kind: "Workflow")
        api.failingGroups = ["argoproj.io/v1alpha1"]
        var discovery = try await client.discover()
        XCTAssertFalse(discovery.failedGroups.isEmpty)
        let mode = KubeMarkedAppsMode.of(discovery: discovery, applications: .notYetListed, marked: [])
        XCTAssertEqual(mode, .only(.undiscovered))
        XCTAssertFalse(KubeMarkedAppsMode.Reason.undiscovered.line(context: "fake-prod").contains("another cluster"))
        api.failingGroups = ["metrics.k8s.io/v1beta1"]
        discovery = try await client.discover()
        XCTAssertTrue(discovery.failedGroups.keys.contains { $0.hasPrefix("metrics.k8s.io") }, "\(discovery.failedGroups)")
        let gitOps = KubeGitOpsSession()
        gitOps.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        XCTAssertEqual(gitOps.marksMode, .only(.notServed), "a down metrics.k8s.io says nothing of Argo CD")
        gitOps.drop()
    }

    func testNoDiscoveryNoRequestAtAll() async throws {
        let (api, client, _) = try startFake()
        api.forgetRequests()
        let session = session()
        session.show(context: "fake-prod", scope: .all, discovery: nil, client: client)
        let gitOps = KubeGitOpsSession()
        gitOps.show(context: "fake-prod", scope: .all, discovery: nil, client: client)
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.isReading)
        XCTAssertFalse(gitOps.marked.isReading)
        XCTAssertEqual(gitOps.marksMode, .off)
        // Nothing was started that could ask later: no task holds a read.
        await Task.yield()
        XCTAssertEqual(api.requests.map(\.path), [], "a sign-in still waiting: nothing asked")
    }

    /// The section shown before the context's discovery was read (another
    /// context picked, a sign-in still waiting): nothing asked; discovery
    /// comes, the same none of Argo CD's or Flux's kinds served — the marks
    /// start then, once (gitops.md 14.4.8: "the reads start once … when
    /// discovery comes back"; before D7's fix pass they never did).
    func testDiscoveryComingAfterTheSectionShowsStartsTheMarks() async throws {
        let (api, client, spoke) = try startFake(FakeKubeAPI.SpokeOptions(apps: 6, states: false))
        let discovery = try await client.discover()
        api.forgetRequests()
        let gitOps = makeGitOps()
        gitOps.show(context: "fake-prod", scope: .all, discovery: nil, client: client)
        await Task.yield()
        XCTAssertEqual(gitOps.marksMode, .off)
        XCTAssertEqual(api.requests.map(\.path), [], "no discovery: nothing asked")
        gitOps.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let read = await eventually { gitOps.marksMode == .only(.notServed) && gitOps.marked.state == .live && !gitOps.marked.apps.isEmpty }
        XCTAssertTrue(read, "\(gitOps.marksMode) \(gitOps.marked.state)")
        XCTAssertTrue(Set(gitOps.marked.apps.map(\.app.key.instance)).isSuperset(of: spoke.apps))
        XCTAssertEqual(api.requests.filter { $0.isWatch && $0.path == "/apis/apps/v1/deployments" }.count, 1, "followed once")
        gitOps.drop()
    }

    func testHiddenEveryReadEndsAndDropForgets() async throws {
        let (api, client, _) = try startFake()
        let discovery = try await client.discover()
        let session = session()
        session.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let live = await eventually { session.state == .live && !session.apps.isEmpty }
        XCTAssertTrue(live)
        session.hide()
        XCTAssertFalse(session.isReading)
        XCTAssertEqual(session.openFollows, 0)
        XCTAssertTrue(session.apps.isEmpty)
        XCTAssertNotNil(session.store, "kept for five minutes")
        let closed = await eventually { api.openWatches == 0 }
        XCTAssertTrue(closed)
        session.drop()
        XCTAssertNil(session.store)
    }

    // MARK: Beside Applications, and where none deploys these

    /// The development cluster's case (14.12, consequence 1): Applications
    /// served, R1's whole list across the cluster has none — derived, and
    /// followed, said "aren't in this cluster", never "another cluster".
    func testApplicationsServedWithNoneListedAreDerivedAndFollowed() async throws {
        let (api, client, spoke) = try startFake(FakeKubeAPI.SpokeOptions(apps: 6, env: "dev", states: false))
        api.serveArgoCD()
        let discovery = try await client.discover()
        let gitOps = makeGitOps()
        gitOps.show(context: "fake-dev", scope: .all, discovery: discovery, client: client)
        let mode = await eventually { gitOps.marksMode == .only(.noApplications) }
        XCTAssertTrue(mode, "\(gitOps.marksMode)")
        XCTAssertEqual(gitOps.marked.reads, .follow)
        let read = await settled(gitOps.marked)
        XCTAssertTrue(read, "\(gitOps.marked.reading)")
        XCTAssertTrue(Set(gitOps.marked.apps.map(\.app.key.instance)).isSuperset(of: spoke.apps))
        XCTAssertTrue(api.requests.contains { $0.isWatch && $0.path == "/apis/apps/v1/deployments" }, "followed")
        XCTAssertEqual(KubeMarkedAppsMode.Reason.noApplications.line(context: "fake-dev"), "Argo CD's Applications for these aren't in this cluster.")
        gitOps.drop()
    }

    /// Served with none listed and no mark anywhere: the marks' from R1's
    /// whole list on — while they are read, and once read whole with none
    /// (never `.off`, whose "No GitOps object lives in or deploys into the
    /// cluster" would stand for seconds on the development cluster before
    /// its 905 apps came) — said by the marks' empty sentence.
    func testApplicationsServedWithNoneListedAreTheMarksBeforeAnyIsFound() async throws {
        let (api, client, _) = try startFake(FakeKubeAPI.SpokeOptions(apps: 0, states: false))
        api.serveArgoCD()
        let discovery = try await client.discover()
        let gitOps = makeGitOps()
        gitOps.show(context: "fake-dev", scope: .all, discovery: discovery, client: client)
        let listed = await eventually { gitOps.applicationsRead == .acrossCluster([]) }
        XCTAssertTrue(listed, "\(gitOps.applicationsRead)")
        // Decided when R1's list came, in the same turn: no mark found yet.
        XCTAssertEqual(gitOps.marksMode, .only(.noApplications))
        let read = await eventually { gitOps.marked.state == .live && gitOps.marked.reading.isWhole }
        XCTAssertTrue(read, "\(gitOps.marked.reading)")
        XCTAssertTrue(gitOps.marked.apps.isEmpty)
        XCTAssertEqual(gitOps.marksMode, .only(.noApplications))
        XCTAssertEqual(
            KubeMarkedSection.empty(.noApplications, context: "fake-dev", scope: .all, reading: gitOps.marked.reading),
            "No Argo CD Application deploys here, and no Deployment, StatefulSet or DaemonSet in all namespaces carries Argo CD's marks.")
        gitOps.drop()
    }

    /// Applications served but refused across the cluster and in `argocd`:
    /// derived, followed, said forbidden (14.9.1's variant).
    func testApplicationsRefusedEverywhereAreDerivedAndFollowed() async throws {
        let (api, client, _) = try startFake(FakeKubeAPI.SpokeOptions(apps: 6, states: false))
        api.serveArgoCD()
        api.forbidden = ["applications@cluster", "applications@argocd"]
        let discovery = try await client.discover()
        let gitOps = makeGitOps()
        gitOps.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let mode = await eventually { gitOps.marksMode == .only(.forbidden) && gitOps.marked.state == .live && !gitOps.marked.apps.isEmpty }
        XCTAssertTrue(mode, "\(gitOps.marksMode)")
        XCTAssertEqual(gitOps.marked.reads, .follow)
        XCTAssertFalse(gitOps.marked.apps.isEmpty)
        gitOps.drop()
    }

    func testBesideApplicationsTheMarksAreListedNotWatched() async throws {
        let (api, client, spoke) = try startFake(FakeKubeAPI.SpokeOptions(apps: 6, states: false))
        api.serveArgoCD()
        // Most marked apps have their Application here: the derived ones are extras.
        for app in spoke.apps.prefix(4) {
            api.addApplication(
                app, spec: ["project": "acme", "destination": ["namespace": "team-0"], "source": ["repoURL": "https://git.acme.example/acme/fleet.git"]],
                status: ["sync": ["status": "Synced"], "health": ["status": "Healthy"]])
        }
        let discovery = try await client.discover()
        api.forgetRequests()
        let gitOps = makeGitOps()
        gitOps.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let mode = await eventually {
            if case .beside(let coexistence) = gitOps.marksMode { return !coexistence.missing.isEmpty }
            return false
        }
        XCTAssertTrue(mode, "\(gitOps.marksMode)")
        guard case .beside(let coexistence) = gitOps.marksMode else { return XCTFail() }
        XCTAssertFalse(coexistence.missing.contains { $0.instance == spoke.apps[0] }, "its Application is here")
        XCTAssertEqual(Set(coexistence.missing.map(\.instance)), Set(spoke.apps.suffix(2)))
        XCTAssertEqual(gitOps.marked.reads, .periodic)
        XCTAssertFalse(api.requests.contains { $0.isWatch && $0.path.hasSuffix("/deployments") && !$0.path.contains("/namespaces/") }, "listed, never watched")
        // Only the derived apps' objects are read by GET (14.4.5).
        let derived = spoke.deployments.suffix(2).map { "/apis/apps/v1/namespaces/\($0.namespace)/deployments/\($0.name)" }
        let gets = await eventually { Set(self.objectGETs(api).map(\.path)) == Set(derived) && gitOps.marked.refetchIdle }
        XCTAssertTrue(gets, "\(objectGETs(api).map(\.path))")
        gitOps.drop()
    }

    /// Beside Applications, most marked apps have none here (a few local
    /// Applications, a hub's many apps): followed as on a spoke, its
    /// objects settled only for the derived apps.
    func testBesideApplicationsMostlyMissingAreFollowed() async throws {
        let (api, client, spoke) = try startFake(FakeKubeAPI.SpokeOptions(apps: 6, states: false))
        api.serveArgoCD()
        api.addApplication(
            spoke.apps[0], spec: ["project": "acme", "destination": ["namespace": "team-0"], "source": ["repoURL": "https://git.acme.example/acme/fleet.git"]],
            status: ["sync": ["status": "Synced"], "health": ["status": "Healthy"]])
        let discovery = try await client.discover()
        api.forgetRequests()
        let gitOps = makeGitOps()
        gitOps.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let followed = await eventually {
            guard case .beside = gitOps.marksMode else { return false }
            return gitOps.marked.reads == .follow && gitOps.marked.state == .live && gitOps.marked.refetchIdle
        }
        XCTAssertTrue(followed, "\(gitOps.marksMode) \(gitOps.marked.reads)")
        XCTAssertTrue(api.requests.contains { $0.isWatch && $0.path == "/apis/apps/v1/deployments" })
        XCTAssertFalse(objectGETs(api).contains { $0.path.hasSuffix("/deployments/\(spoke.deployments[0].name)") }, "its Application is here: not settled")
        XCTAssertTrue(KubeGitOpsSession.followsBeside(KubeMarkedAppsMode.Coexistence(missing: Set((0..<101).map { KubeTrackingID.AppKey(installation: "", instance: "fake-\($0)") })), marked: 1000))
        XCTAssertFalse(KubeGitOpsSession.followsBeside(KubeMarkedAppsMode.Coexistence(missing: [KubeTrackingID.AppKey(installation: "", instance: "fake-1")]), marked: 10))
        gitOps.drop()
    }
}
