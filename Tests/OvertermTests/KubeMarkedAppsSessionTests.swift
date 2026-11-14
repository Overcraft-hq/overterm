import Foundation
import XCTest

@testable import Overterm

/// The apps read from Argo CD's marks (`KubeMarkedAppsSession`, gitops.md
/// 14.4) against a fake spoke on a socket of the tests' own
/// (`FakeKubeAPI.addSpoke`) — never a real cluster; every assertion from
/// the fake's log of requests or the session's own counts, never a moment
/// sampled: nothing of Argo CD's or Flux's is asked where they aren't
/// served; three watches, and three still for six namespaces; the check
/// (M1b) paged, cut at its bound and never watched; a stuck single-replica
/// rollout whose cells say `1/1` Progressing once checked; M2 only for a
/// moved generation, not-ready cells or a last unhealthy state, 60 a
/// minute under 2,000 row events; M3 and M3b never watched; a refusal
/// across the cluster read where it may be, said; argoproj.io failing
/// discovery "couldn't tell", a failing metrics.k8s.io not; hidden, every
/// read ends; no discovery, no request. Only GETs, never a Secret, a
/// ConfigMap, a ReplicaSet or a pod.
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
        session.clock = { [unowned self] in self.now }
        return session
    }

    private func app(_ session: KubeMarkedAppsSession, _ instance: String) -> KubeMarkedRanked? {
        session.apps.first { $0.app.key.instance == instance }
    }

    /// Checked by Argo CD's rule (M1b) and every first list in.
    private func settled(_ session: KubeMarkedAppsSession) async -> Bool {
        await eventually {
            session.state == .live && session.store?.done.contains("check:deployments.apps") == true && session.store?.done.contains("objects:cronjobs.batch") == true
                && session.store?.done.contains("rows:services") == true && session.reading.checking == nil && session.refetchIdle && session.isMerged
        }
    }

    private func argoOrFlux(_ path: String) -> Bool { path.contains("argoproj.io") || path.contains("toolkit.fluxcd.io") }

    /// An object's GET (M2): a workload by name, not a list.
    private func objectGETs(_ api: FakeKubeAPI) -> [FakeKubeAPI.Request] {
        api.requests.filter { request in
            !request.isWatch && !request.isDiscovery && request.query["limit"] == nil && request.path.contains("/namespaces/")
                && request.path.split(separator: "/").count == 7
        }
    }

    // MARK: A spoke

    func testASpokesAppsComeFromTheirMarksAndArgoCDIsNeverAsked() async throws {
        let (api, client, spoke) = try startFake()
        let discovery = try await client.discover()
        api.forgetRequests()
        let gitOps = KubeGitOpsSession()
        gitOps.flushInterval = .milliseconds(20)
        gitOps.marked.flushInterval = .milliseconds(20)
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

    func testArgoRolloutsAreReadForTheirAppsHealthOnly() async throws {
        var options = FakeKubeAPI.SpokeOptions()
        options.apps = 4
        options.rollouts = true
        let (api, client, spoke) = try startFake(options)
        let discovery = try await client.discover()
        api.forgetRequests()
        let session = session()
        session.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let read = await eventually { session.store?.done.contains("check:rollouts.argoproj.io") == true && session.refetchIdle && session.state == .live }
        XCTAssertTrue(read)
        XCTAssertTrue(session.reading.rolloutsServed)
        let canary = await eventually { self.app(session, spoke.rollout)?.health.state == .ready }
        XCTAssertTrue(canary, "\(app(session, spoke.rollout)?.health.why ?? "none")")
        // Its Deployment, scaled to 0 by the Rollout, is no problem.
        let deployment = app(session, spoke.rollout)?.app.members.first { $0.id.kind == .deployment }
        XCTAssertNotNil(deployment)
        XCTAssertEqual(app(session, spoke.rolloutDegraded)?.health.state, .failed)
        XCTAssertEqual(api.requests.filter { $0.isWatch }.count(where: { $0.path.contains("/rollouts") }), 1, "its rows followed, as a Deployment's")
        XCTAssertFalse(api.requests.contains { $0.path.contains("argoproj.io") && !$0.path.contains("/rollouts") && !$0.isDiscovery }, "nothing else of Argo's")
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

    func testTheCheckIsPagedCutAtItsBoundAndNeverWatched() async throws {
        let (api, client, _) = try startFake()
        let discovery = try await client.discover()
        api.forgetRequests()
        let session = session()
        session.bounds.checkPage = 7
        session.bounds.checkObjects = 20
        session.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let read = await settled(session)
        XCTAssertTrue(read)
        let checks = api.requests.filter { $0.path == "/apis/apps/v1/deployments" && !$0.accept.contains("as=Table") }
        XCTAssertFalse(checks.isEmpty)
        XCTAssertTrue(checks.allSatisfy { !$0.isWatch && (Int($0.query["limit"] ?? "") ?? 99) <= 7 }, "\(checks.map(\.query))")
        XCTAssertEqual(checks.count, 3, "7 + 7 + 6, then cut")
        XCTAssertEqual(
            session.reading.notes["check:deployments.apps"]?.hasPrefix("Deployments: 20 of "), true, "\(session.reading.notes)")
        XCTAssertTrue(session.reading.notes["check:deployments.apps"]?.hasSuffix("checked by Argo CD's rule; the rest from their rows") == true)
        // Past the cut, a state is from its row.
        XCTAssertTrue(session.apps.contains { $0.health.fromRows })
        XCTAssertTrue(session.reading.isWhole, "the check's cut leaves the marks whole")
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
        for path in ["/api/v1/services", "/apis/networking.k8s.io/v1/ingresses", "/api/v1/persistentvolumeclaims", "/apis/batch/v1/jobs"] {
            let asked = api.requests.filter { $0.path == path }
            XCTAssertFalse(asked.isEmpty, path)
            XCTAssertTrue(asked.allSatisfy { $0.accept.contains("as=Table") && $0.query["includeObject"] == "Metadata" }, "rows with their metadata: \(path)")
        }
        for path in ["/apis/batch/v1/cronjobs", "/apis/autoscaling/v2/horizontalpodautoscalers"] {
            let asked = api.requests.filter { $0.path == path }
            XCTAssertFalse(asked.isEmpty, path)
            XCTAssertTrue(asked.allSatisfy { !$0.accept.contains("as=Table") && $0.query["limit"] != nil }, "whole, paged: \(path)")
        }
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
        let lists = api.requests.filter { !$0.isWatch && !$0.isDiscovery && !$0.accept.contains("as=Table") }
        XCTAssertEqual(lists.map(\.path), [], "no check, no CronJob or HPA again")
        XCTAssertFalse(api.requests.contains { $0.path == "/api/v1/services" }, "no Service list again")
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
        // A spec change: its generation moves.
        api.modify("deployments.apps", name, namespace: namespace) { body in
            var metadata = body["metadata"] as? [String: Any] ?? [:]
            metadata["generation"] = 5
            body["metadata"] = metadata
        }
        let fetched = await eventually { self.objectGETs(api).contains { $0.path.hasSuffix("/deployments/\(name)") } }
        XCTAssertTrue(fetched, "\(api.requests.map(\.path))")
        session.drop()
    }

    func testTwoThousandReadinessEventsAskAtMostSixtyAMinute() async throws {
        var options = FakeKubeAPI.SpokeOptions()
        options.apps = 100
        options.padding = 500
        let (api, client, spoke) = try startFake(options)
        let discovery = try await client.discover()
        let session = session()
        session.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let read = await settled(session)
        XCTAssertTrue(read)
        api.forgetRequests()
        let before = session.rowsChanged
        let deployments = spoke.deployments
        XCTAssertEqual(deployments.count, 100)
        // 10 rounds × 2 × 100 = 2,000 events, the generation never moving;
        // the session's clock stands: one minute.
        api.churnReadiness(deployments, rounds: 10)
        let all = await eventually(60) { session.rowsChanged - before >= 2000 }
        XCTAssertTrue(all, "\(session.rowsChanged - before)")
        // A hundred turned not ready; the minute's 60 are all it reads.
        let capped = await eventually(30) { session.takenLastMinute == 60 && session.getsQueued == 0 }
        XCTAssertTrue(capped, "\(session.takenLastMinute)")
        XCTAssertEqual(objectGETs(api).count, 60, "60 a minute")
        XCTAssertLessThanOrEqual(session.mostTaken, 20, "20 a flush")
        XCTAssertLessThanOrEqual(session.mostInFlight, 4)
        // The next minute reads what waits — never past its own 60.
        now = now.addingTimeInterval(61)
        let next = await eventually(30) { session.takenLastMinute > 0 && session.getsQueued == 0 && self.objectGETs(api).count > 60 }
        XCTAssertTrue(next, "\(objectGETs(api).count)")
        XCTAssertLessThanOrEqual(session.takenLastMinute, 60)
        XCTAssertLessThanOrEqual(objectGETs(api).count, 120)
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

    // MARK: Beside Applications

    func testBesideApplicationsTheMarksAreListedNotWatched() async throws {
        let (api, client, spoke) = try startFake(FakeKubeAPI.SpokeOptions(apps: 6, states: false))
        api.serveArgoCD()
        api.addApplication(
            spoke.apps[0], spec: ["project": "acme", "destination": ["namespace": "team-0"], "source": ["repoURL": "https://git.acme.example/acme/fleet.git"]],
            status: ["sync": ["status": "Synced"], "health": ["status": "Healthy"]])
        let discovery = try await client.discover()
        api.forgetRequests()
        let gitOps = KubeGitOpsSession()
        gitOps.flushInterval = .milliseconds(20)
        gitOps.marked.flushInterval = .milliseconds(20)
        gitOps.show(context: "fake-prod", scope: .all, discovery: discovery, client: client)
        let mode = await eventually {
            if case .beside(let coexistence) = gitOps.marksMode { return !coexistence.missing.isEmpty }
            return false
        }
        XCTAssertTrue(mode, "\(gitOps.marksMode)")
        guard case .beside(let coexistence) = gitOps.marksMode else { return XCTFail() }
        XCTAssertFalse(coexistence.missing.contains { $0.instance == spoke.apps[0] }, "its Application is here")
        XCTAssertTrue(coexistence.missing.contains { $0.instance == spoke.apps[1] })
        XCTAssertEqual(gitOps.marked.reads, .periodic)
        XCTAssertFalse(api.requests.contains { $0.isWatch && $0.path.hasSuffix("/deployments") && !$0.path.contains("/namespaces/") }, "listed, never watched")
        gitOps.drop()
    }
}
