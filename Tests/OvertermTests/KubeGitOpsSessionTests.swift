import Combine
import Foundation
import XCTest

@testable import Overterm

/// The GitOps section's reads against `FakeKubeAPI` on a socket of the
/// tests' own (docs/design/kubernetes/gitops.md, 3, 8.2), never a real
/// cluster, every assertion from the fake's log of requests: only GETs;
/// rows-only watches (`includeObject` None or Metadata, never Object); one
/// paged, byte-bounded list of whole objects a served kind; never a
/// Secret or a ConfigMap; at most eight watches. Paging halves a page that
/// is too large, stops at an object alone too large, lists again after a
/// 410. Left and shown again within five minutes, no whole-object list;
/// the page hidden, nothing asked. R3 reads an object whose row isn't
/// healthy when it changes, and not a healthy one's new resourceVersion. A
/// kind refused across the cluster is read in argocd, said; a controller
/// down shows the banner; 600 Applications are cut at 500, said.
@MainActor
final class KubeGitOpsSessionTests: XCTestCase {
    nonisolated(unsafe) private var fakes: [FakeKubeAPI] = []

    override func tearDown() {
        for api in fakes {
            XCTAssertEqual(api.requests.filter { $0.method != "GET" }, [], "only GETs")
            XCTAssertFalse(api.requests.contains { $0.path.contains("/secrets") || $0.path.contains("/configmaps") }, "never a Secret or a ConfigMap")
            api.stop()
        }
        fakes = []
    }

    private func startFake() throws -> (FakeKubeAPI, KubeClient) {
        let socket = "/tmp/othg-\(UInt32.random(in: 0...UInt32.max)).sock"
        let api = FakeKubeAPI(socket: socket)
        try api.start()
        fakes.append(api)
        api.addNamespace("shop")
        api.addGitOpsFixtures()
        return (api, KubeClient(KubeSocketConnection(socket: socket, context: "kind-fake")))
    }

    private func eventually(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func session() -> KubeGitOpsSession {
        let session = KubeGitOpsSession()
        session.flushInterval = .milliseconds(20)
        return session
    }

    /// The lists of whole objects (not rows): what R2 and R3 read.
    private func wholeReads(_ api: FakeKubeAPI) -> [FakeKubeAPI.Request] {
        api.requests.filter { !$0.isWatch && !$0.accept.contains("as=Table") && !$0.isDiscovery }
    }

    private func gitOpsGroup(_ path: String) -> Bool { path.contains("argoproj.io") || path.contains("toolkit.fluxcd.io") }

    func testTheSectionReadsRowsAndOnePagedListAKind() async throws {
        let (api, client) = try startFake()
        let discovery = try await client.discover()
        api.forgetRequests()
        let session = session()
        session.show(context: "kind-fake", scope: .namespace("shop"), discovery: discovery, client: client)
        let read = await eventually { session.state == .live && !session.summarising && !session.objects.isEmpty }
        XCTAssertTrue(read, "\(session.state)")
        let watches = api.requests.filter(\.isWatch)
        XCTAssertTrue(watches.allSatisfy { $0.accept.contains("as=Table") }, "rows only")
        XCTAssertTrue(watches.allSatisfy { ["None", "Metadata"].contains($0.query["includeObject"] ?? "") }, "\(watches.map(\.query))")
        XCTAssertFalse(api.requests.contains { $0.query["includeObject"] == "Object" }, "never a whole-object watch")
        let lists = wholeReads(api).filter { gitOpsGroup($0.path) }
        let served = KubeGitOpsSummary.kinds(discovery)
        XCTAssertEqual(served.count, 9, "\(served.map(\.fullName))")
        XCTAssertEqual(Set(lists.map(\.path)), Set(served.map { $0.path() }), "one paged list a served kind")
        XCTAssertEqual(lists.count, served.count, "each kind's few objects in one page")
        XCTAssertTrue(lists.allSatisfy { $0.query["limit"] == "20" }, "20 a page")
        let followed = watches.filter { gitOpsGroup($0.path) }
        XCTAssertEqual(Set(followed.map { $0.path }).count, 5, "the five kinds followed: \(Set(followed.map(\.path)))")
        XCTAssertTrue(followed.allSatisfy { !$0.path.contains("/namespaces/") }, "across the cluster")
        let controllers = watches.filter { !gitOpsGroup($0.path) }.map(\.path)
        XCTAssertEqual(
            Set(controllers),
            [
                "/apis/apps/v1/namespaces/argocd/deployments", "/apis/apps/v1/namespaces/argocd/statefulsets",
                "/apis/apps/v1/namespaces/flux-system/deployments",
            ], "R1c: the controllers in their namespaces")
        XCTAssertTrue(
            watches.filter { $0.path.contains("/namespaces/") }.allSatisfy { $0.query["includeObject"] == "None" }, "None in one namespace")
        XCTAssertLessThanOrEqual(api.openWatches, 8, "at most eight watches")
        XCTAssertEqual(session.openFollows, 8)

        // What it shows: the scope rule, the ladder.
        let rows = await eventually { session.rows.shown.contains { $0.ref.name == "acme-apps" } }
        XCTAssertTrue(rows)
        let shown = session.rows.shown
        XCTAssertTrue(shown.contains { $0.ref.name == "acme-shop-prod" && $0.key.kind == "Application" })
        XCTAssertFalse(shown.contains { $0.ref.name == "acme-remote" })
        XCTAssertEqual(shown.first { $0.ref.name == "acme-cron" }?.state, .failed)
        XCTAssertEqual(shown.first { $0.ref.name == "acme-api" && $0.key.kind == "Kustomization" }?.state, .blocked)
        let text = shown.map { "\($0.why) \($0.source) \($0.hover)" }.joined()
        XCTAssertFalse(text.contains(FakeKubeAPI.gitOpsSentinel))
        XCTAssertFalse(text.contains("ghp_fake"))

        // Another scope: filtered again, nothing asked.
        api.forgetRequests()
        session.scopeChanged(.namespace("envs-dev"))
        XCTAssertTrue(session.rows.shown.contains { $0.ref.name == "acme-envs-dev" })
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(wholeReads(api).filter { gitOpsGroup($0.path) }, [], "a scope change outside the fallback reads nothing")

        // Left and shown again: no whole-object list (the store).
        session.hide()
        let ended = await eventually { api.openWatches == 0 }
        XCTAssertTrue(ended, "\(api.openWatches) open")
        XCTAssertFalse(session.objects.isEmpty, "the summaries stay")
        api.forgetRequests()
        session.show(context: "kind-fake", scope: .namespace("shop"), discovery: discovery, client: client)
        let again = await eventually { session.state == .live && api.openWatches >= 8 }
        XCTAssertTrue(again)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(wholeReads(api).filter { gitOpsGroup($0.path) && $0.query["limit"] != nil }, [], "no list again")

        // The page hidden: everything goes, nothing is asked.
        session.drop()
        XCTAssertTrue(session.objects.isEmpty)
        XCTAssertNil(session.store)
        let closed = await eventually { api.openWatches == 0 }
        XCTAssertTrue(closed)
        api.forgetRequests()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(api.requests, [], "hidden, nothing is asked")
    }

    func testAnObjectIsReadAgainWhenItsRowIsntHealthy() async throws {
        let (api, client) = try startFake()
        let discovery = try await client.discover()
        let session = session()
        session.show(context: "kind-fake", scope: .all, discovery: discovery, client: client)
        let read = await eventually { session.state == .live && !session.summarising && session.rows.shown.contains { $0.ref.name == "acme-admin" } }
        XCTAssertTrue(read)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(session.objects.first { $0.ref.name == "acme-admin" }?.state, .drift)
        api.forgetRequests()
        // OutOfSync, Healthy — not healthy — its operation fails with no cell changed.
        api.setArgoState("acme-admin") { status in
            status["operationState"] = [
                "phase": "Failed", "message": "one or more objects failed to apply", "startedAt": FakeKubeAPI.time(Date().addingTimeInterval(-60)),
                "finishedAt": FakeKubeAPI.time(Date().addingTimeInterval(-30)), "syncResult": ["revision": FakeKubeAPI.GitOpsCommit.target],
            ]
        }
        let path = "/apis/argoproj.io/v1alpha1/namespaces/argocd/applications/acme-admin"
        let failed = await eventually { session.objects.first { $0.ref.name == "acme-admin" }?.state == .failed }
        XCTAssertTrue(failed, "read again, Failed: \(session.objects.first { $0.ref.name == "acme-admin" }?.why ?? "")")
        XCTAssertEqual(api.requests.filter { $0.path == path }.count, 1, "one GET")
        XCTAssertEqual(session.rows.shown.first { $0.ref.name == "acme-admin" }?.state, .failed)

        // A healthy row's new resourceVersion, no cell changed: nothing.
        api.forgetRequests()
        api.modify("applications.argoproj.io", "acme-shop-prod", namespace: "argocd") { body in
            var metadata = body["metadata"] as? [String: Any] ?? [:]
            metadata["labels"] = ["touched": "yes"]
            body["metadata"] = metadata
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(api.requests.filter { $0.path.hasSuffix("/applications/acme-shop-prod") }, [], "a healthy row's event reads nothing")
        session.drop()
    }

    func testAKindRefusedAcrossTheClusterIsReadWhereItLives() async throws {
        let (api, client) = try startFake()
        api.forbidden = ["applications.argoproj.io@cluster"]
        let discovery = try await client.discover()
        api.forgetRequests()
        let session = session()
        session.show(context: "kind-fake", scope: .namespace("shop"), discovery: discovery, client: client)
        let read = await eventually { !session.summarising && session.objects.contains { $0.ref.name == "acme-shop-prod" } }
        XCTAssertTrue(read, "\(session.notes)")
        XCTAssertTrue(
            session.notes.contains("Applications: forbidden across the cluster; read in argocd and shop"), "said: \(session.notes)")
        let lists = wholeReads(api).filter { $0.path.contains("/applications") }.map(\.path)
        XCTAssertTrue(lists.contains("/apis/argoproj.io/v1alpha1/namespaces/argocd/applications"), "\(lists)")
        let watched = await eventually { api.requests.contains { $0.isWatch && $0.path == "/apis/argoproj.io/v1alpha1/namespaces/argocd/applications" } }
        XCTAssertTrue(watched, "its rows followed in argocd, a spare watch")
        XCTAssertFalse(session.objects.contains { $0.ref.name == "acme-api" && $0.role == .application }, "team-a isn't read: neither argocd nor the scope")
        XCTAssertLessThanOrEqual(api.openWatches, 10)
        session.drop()
    }

    func testAControllerDownShowsTheBanner() async throws {
        let (api, client) = try startFake()
        let discovery = try await client.discover()
        let session = session()
        session.show(context: "kind-fake", scope: .all, discovery: discovery, client: client)
        let read = await eventually { session.state == .live && !session.summarising && session.controllers.count >= 5 }
        XCTAssertTrue(read, "\(session.controllers)")
        XCTAssertNil(KubeGitOpsControllers.banner(session.controllers))
        api.setControllerReady("kustomize-controller", false)
        let down = await eventually { KubeGitOpsControllers.banner(session.controllers) != nil }
        XCTAssertTrue(down)
        XCTAssertEqual(KubeGitOpsControllers.banner(session.controllers), "kustomize-controller 0/1 ready in flux-system — Flux's states below may be stale")
        let tagged = await eventually { session.objects.filter { $0.tool == .flux }.allSatisfy { $0.tags.contains(.mayBeStale) } }
        XCTAssertTrue(tagged, "Flux's rows may be stale")
        XCTAssertFalse(session.objects.contains { $0.tool == .argo && $0.tags.contains(.mayBeStale) })
        session.drop()
    }

    func testManyApplicationsAreCutAtFiveHundredAndSaid() async throws {
        let (api, client) = try startFake()
        for n in 0..<600 {
            api.addApplication(
                "bulk-\(n)", spec: ["source": ["repoURL": "https://git.acme.example/acme/fleet.git", "path": "bulk/\(n)"], "destination": ["namespace": "shop"]],
                status: ["sync": ["status": "Synced", "revision": FakeKubeAPI.GitOpsCommit.applied], "health": ["status": "Healthy"]])
        }
        let discovery = try await client.discover()
        api.forgetRequests()
        let session = session()
        session.show(context: "kind-fake", scope: .all, discovery: discovery, client: client)
        let read = await eventually(30) { session.state == .live && !session.summarising && !session.objects.isEmpty }
        XCTAssertTrue(read)
        let apps = session.objects.filter { $0.role == .application }
        XCTAssertEqual(apps.count, 500, "summarised up to 500")
        XCTAssertTrue(session.notes.contains { $0.hasPrefix("Applications: 500 of ") && $0.hasSuffix("summarised; the rest show their state only") }, "\(session.notes)")
        let pages = wholeReads(api).filter { $0.path == "/apis/argoproj.io/v1alpha1/applications" }
        XCTAssertEqual(pages.count, 25, "20 a page")
        let all = await eventually(10) { session.rows.shown.filter { $0.role == .application }.count >= 600 }
        XCTAssertTrue(all, "every row shows, the rest by their cells: \(session.rows.shown.count)")
        XCTAssertGreaterThanOrEqual(session.rows.shown.filter { !$0.summarised }.count, 100)
        session.drop()
    }

    // MARK: The store, the scope, Refresh

    func testLeftMidSummaryReadsTheRestWhenShownAgain() async throws {
        let (api, client) = try startFake()
        let discovery = try await client.discover()
        let served = KubeGitOpsSummary.kinds(discovery)
        // Every kind's list held: the section left with some read, some not.
        for kind in served { api.answerSlowly(kind.path(), milliseconds: 400) }
        let session = session()
        session.show(context: "kind-fake", scope: .all, discovery: discovery, client: client)
        let some = await eventually { (session.store?.done.count ?? 0) >= 1 }
        XCTAssertTrue(some)
        session.hide()
        let before = session.store?.done ?? []
        XCTAssertLessThan(before.count, served.count, "left mid-read: \(before)")
        for kind in served { api.answerSlowly(kind.path(), milliseconds: nil) }
        api.forgetRequests()
        session.show(context: "kind-fake", scope: .all, discovery: discovery, client: client)
        let all = await eventually { session.store?.done == Set(served.map(\.fullName)) && !session.summarising }
        XCTAssertTrue(all, "every kind summarised at last: \(session.store?.done ?? [])")
        let lists = Set(wholeReads(api).filter { gitOpsGroup($0.path) && $0.query["limit"] != nil }.map(\.path))
        XCTAssertEqual(lists, Set(served.filter { !before.contains($0.fullName) }.map { $0.path() }), "only the kinds not read before")
        for kind in served where !before.contains(kind.fullName) && api.names(kind.fullName).count > 0 {
            XCTAssertTrue(session.objects.contains { $0.resource == kind.fullName }, "\(kind.fullName) summarised")
        }
        session.drop()
    }

    func testRefreshKeepsEverySummaryUntilItsKindIsReadAgain() async throws {
        let (api, client) = try startFake()
        let discovery = try await client.discover()
        let session = session()
        session.show(context: "kind-fake", scope: .all, discovery: discovery, client: client)
        let read = await eventually { session.state == .live && !session.summarising && !session.objects.isEmpty }
        XCTAssertTrue(read)
        let before = Set(session.objects.map(\.key))
        let served = KubeGitOpsSummary.kinds(discovery)
        for kind in served { api.answerSlowly(kind.path(), milliseconds: 300) }
        session.refresh()
        // Some kinds read again, the others still held.
        let partly = await eventually { (session.store?.done.count ?? 0) >= 1 }
        XCTAssertTrue(partly)
        XCTAssertTrue(session.summarising)
        XCTAssertEqual(Set(session.objects.map(\.key)), before, "no row loses its summary while Refresh reads")
        for kind in served { api.answerSlowly(kind.path(), milliseconds: nil) }
        let again = await eventually { !session.summarising }
        XCTAssertTrue(again)
        XCTAssertEqual(Set(session.objects.map(\.key)), before)
        session.drop()
    }

    func testARefusedKindStaysWatchedAcrossScopeChanges() async throws {
        let (api, client) = try startFake()
        for namespace in ["payments", "orders"] { api.addNamespace(namespace) }
        api.forbidden = ["applications.argoproj.io@cluster"]
        let discovery = try await client.discover()
        let session = session()
        session.show(context: "kind-fake", scope: .namespace("shop"), discovery: discovery, client: client)
        let read = await eventually { !session.summarising && session.objects.contains { $0.ref.name == "acme-shop-prod" } }
        XCTAssertTrue(read, "\(session.notes)")
        func watchedInANamespace() -> Bool {
            api.requests.contains { $0.isWatch && $0.path.hasPrefix("/apis/argoproj.io/v1alpha1/namespaces/") && $0.path.hasSuffix("/applications") }
        }
        let first = await eventually { watchedInANamespace() }
        XCTAssertTrue(first, "followed where it lives")
        for scope in ["payments", "orders"] {
            api.forgetRequests()
            session.scopeChanged(.namespace(scope))
            let watched = await eventually { watchedInANamespace() }
            XCTAssertTrue(watched, "still followed after the scope moved to \(scope): \(session.notes)")
            let summarised = await eventually { !session.summarising }
            XCTAssertTrue(summarised)
            XCTAssertTrue(
                wholeReads(api).contains { $0.path == "/apis/argoproj.io/v1alpha1/namespaces/\(scope)/applications" },
                "read again where the scope now is")
            XCTAssertFalse(
                wholeReads(api).contains { $0.path == "/apis/argoproj.io/v1alpha1/applications" }, "still refused: not asked across the cluster again")
            XCTAssertLessThanOrEqual(api.openWatches, 10, "the allotment kept")
        }
        // Every other kind still summarised: the fallback's re-read cancelled none of them.
        let done = await eventually { session.store?.done == Set(KubeGitOpsSummary.kinds(discovery).map(\.fullName)) }
        XCTAssertTrue(done, "\(session.store?.done ?? [])")
        session.drop()
    }

    func testAScopeChangeMidReadKeepsEveryOtherKindsRead() async throws {
        let (api, client) = try startFake()
        api.addNamespace("payments")
        api.forbidden = ["applications.argoproj.io@cluster"]
        let discovery = try await client.discover()
        let served = KubeGitOpsSummary.kinds(discovery)
        for kind in served where kind.fullName != "applications.argoproj.io" { api.answerSlowly(kind.path(), milliseconds: 300) }
        let session = session()
        session.show(context: "kind-fake", scope: .namespace("shop"), discovery: discovery, client: client)
        let refused = await eventually { session.store?.fallback["applications.argoproj.io"] != nil }
        XCTAssertTrue(refused)
        XCTAssertTrue(session.summarising, "the other kinds still being read")
        session.scopeChanged(.namespace("payments"))
        for kind in served { api.answerSlowly(kind.path(), milliseconds: nil) }
        let done = await eventually { !session.summarising && session.store?.done == Set(served.map(\.fullName)) }
        XCTAssertTrue(done, "none cancelled by the fallback's re-read: \(session.store?.done ?? [])")
        XCTAssertEqual(session.store?.fallback["applications.argoproj.io"], ["argocd", "payments"])
        session.drop()
    }

    func testANamespaceThatRefusesIsNamed() async throws {
        let (api, client) = try startFake()
        api.forbidden = ["applications.argoproj.io@cluster", "applications.argoproj.io@shop"]
        let discovery = try await client.discover()
        let session = session()
        session.show(context: "kind-fake", scope: .namespace("shop"), discovery: discovery, client: client)
        let said = await eventually { !session.summarising && session.notes.contains { $0.hasPrefix("Applications: forbidden across the cluster") } }
        XCTAssertTrue(said, "\(session.notes)")
        XCTAssertTrue(
            session.notes.contains("Applications: forbidden across the cluster; read in argocd; refused in shop"), "said: \(session.notes)")
        XCTAssertTrue(session.objects.contains { $0.ref.name == "acme-shop-prod" }, "argocd's still read")
        session.drop()
    }

    func testKindsNotServedAreNotAsked() async throws {
        let (api, client) = try startFake()
        for kind in api.servedKinds where kind.group.hasSuffix("toolkit.fluxcd.io") || kind.fullName == "applicationsets.argoproj.io" {
            api.unserve(kind.fullName)
        }
        let discovery = try await client.discover()
        api.forgetRequests()
        let session = session()
        session.show(context: "kind-fake", scope: .all, discovery: discovery, client: client)
        let read = await eventually { session.state == .live && !session.summarising && !session.objects.isEmpty }
        XCTAssertTrue(read)
        try await Task.sleep(for: .milliseconds(300))
        let asked = api.requests.map(\.path)
        XCTAssertFalse(asked.contains { $0.contains("fluxcd.io") }, "Flux not served: none of its kinds asked")
        XCTAssertFalse(asked.contains { $0.contains("/applicationsets") }, "ApplicationSets not served: not asked")
        XCTAssertFalse(asked.contains { $0.contains("/namespaces/flux-system/") }, "nor Flux's controllers")
        XCTAssertTrue(asked.contains("/apis/argoproj.io/v1alpha1/applications"), "Applications still read")
        session.drop()
    }

    // MARK: R3 at scale

    func testThirtyFailedApplicationsGiveTwentyGETsAFlushFourInFlight() async throws {
        let (api, client) = try startFake()
        let names = (0..<30).map { "acme-failed-\($0)" }
        for name in names {
            api.addApplication(
                name, spec: ["source": ["repoURL": "https://git.acme.example/acme/fleet.git", "path": name], "destination": ["namespace": "shop"]],
                status: [
                    "sync": ["status": "OutOfSync", "revision": FakeKubeAPI.GitOpsCommit.applied], "health": ["status": "Degraded"],
                    "operationState": [
                        "phase": "Failed", "message": "one or more objects failed to apply", "startedAt": FakeKubeAPI.time(Date().addingTimeInterval(-90)),
                        "finishedAt": FakeKubeAPI.time(Date().addingTimeInterval(-60)), "syncResult": ["revision": FakeKubeAPI.GitOpsCommit.target],
                    ],
                ])
        }
        let discovery = try await client.discover()
        let session = session()
        session.show(context: "kind-fake", scope: .all, discovery: discovery, client: client)
        let read = await eventually {
            session.state == .live && !session.summarising && session.rows.shown.filter { $0.ref.name.hasPrefix("acme-failed-") }.count == 30
        }
        XCTAssertTrue(read)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(names.allSatisfy { name in session.objects.first { $0.ref.name == name }?.state.isProblem == true })
        // One flush every 3 s from here: all 30 changes land before the first.
        session.flushInterval = .seconds(3)
        try await Task.sleep(for: .milliseconds(100))
        let paths = names.map { "/apis/argoproj.io/v1alpha1/namespaces/argocd/applications/\($0)" }
        for path in paths { api.answerSlowly(path, milliseconds: 120) }
        api.forgetRequests()
        for name in names { api.setArgoState(name) { status in status["sync"] = ["status": "OutOfSync", "revision": "c9"] } }
        func gets() -> [FakeKubeAPI.Request] { api.requests.filter { !$0.isWatch && paths.contains($0.path) } }
        var most = 0
        let first = await eventually(8) {
            most = max(most, api.heldAnswers)
            return gets().count >= 20
        }
        XCTAssertTrue(first, "\(gets().count) GETs")
        let settled = await eventually(2) {
            most = max(most, api.heldAnswers)
            return api.heldAnswers == 0
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(gets().count, 20, "exactly 20 GETs in the first flush")
        XCTAssertLessThanOrEqual(most, KubeGitOpsSession.inFlight, "at most four in flight")
        XCTAssertGreaterThan(most, 1, "several at once")
        let rest = await eventually(8) {
            most = max(most, api.heldAnswers)
            return gets().count >= 30
        }
        XCTAssertTrue(rest, "the other ten at the next flush: \(gets().count)")
        XCTAssertLessThanOrEqual(most, KubeGitOpsSession.inFlight)
        XCTAssertEqual(Set(gets().map(\.path)), Set(paths), "each once")
        XCTAssertEqual(gets().count, 30)

        // A second change within 15 s waits for its turn.
        for path in paths { api.answerSlowly(path, milliseconds: nil) }
        session.flushInterval = .milliseconds(50)
        api.forgetRequests()
        api.setArgoState(names[0]) { status in status["sync"] = ["status": "OutOfSync", "revision": "c10"] }
        try await Task.sleep(for: .milliseconds(3500))
        XCTAssertEqual(gets(), [], "asked again within 15 s: waits")
        session.clock = { Date().addingTimeInterval(16) }
        let later = await eventually(8) { gets().count == 1 }
        XCTAssertTrue(later, "read once its 15 s are up: \(gets().map(\.path))")
        session.drop()
    }

    /// G8's finding: thirty GETs that come back between two flushes are
    /// ranked and drawn once, at the next flush — not once each (1,000
    /// summaries ranked and the table drawn 50 times over took a burst 8 s).
    func testGETsThatComeBackAreRankedTogetherAtTheNextFlush() async throws {
        let (api, client) = try startFake()
        let names = (0..<30).map { "acme-degraded-\($0)" }
        for name in names {
            api.addApplication(
                name, spec: ["source": ["repoURL": "https://git.acme.example/acme/fleet.git", "path": name], "destination": ["namespace": "shop"]],
                status: ["sync": ["status": "Synced", "revision": FakeKubeAPI.GitOpsCommit.applied], "health": ["status": "Degraded"]])
        }
        let discovery = try await client.discover()
        let session = session()
        session.show(context: "kind-fake", scope: .all, discovery: discovery, client: client)
        let read = await eventually {
            session.state == .live && !session.summarising && session.rows.shown.filter { $0.ref.name.hasPrefix("acme-degraded-") }.count == 30
        }
        XCTAssertTrue(read)
        try await Task.sleep(for: .milliseconds(300))
        session.flushInterval = .milliseconds(400)
        try await Task.sleep(for: .milliseconds(450))
        var ranked = 0
        let counting = session.$objects.dropFirst().sink { _ in ranked += 1 }
        defer { counting.cancel() }
        let paths = Set(names.map { "/apis/argoproj.io/v1alpha1/namespaces/argocd/applications/\($0)" })
        api.forgetRequests()
        for name in names { api.setArgoState(name) { status in status["health"] = ["status": "Degraded", "message": "deadline exceeded"] } }
        let got = await eventually(10) {
            api.requests.filter { !$0.isWatch && paths.contains($0.path) }.count == 30
                && names.allSatisfy { name in session.objects.first { $0.ref.name == name }?.lastError?.contains("deadline exceeded") == true }
        }
        XCTAssertTrue(got, "every one read again and ranked")
        // Two flushes take the thirty (20 + 10); each one's answers ranked once, with the next flush.
        XCTAssertLessThanOrEqual(ranked, 4, "ranked \(ranked) times for 30 GETs")
        XCTAssertLessThanOrEqual(session.mostTaken, KubeGitOpsRefetch.perFlush)
        XCTAssertLessThanOrEqual(session.mostInFlight, KubeGitOpsSession.inFlight)
        session.drop()
    }

    /// A GET that comes back in the last moments before the section is
    /// left is in the store but not yet ranked (the flush it waits for is
    /// cancelled): shown again within five minutes, the store is reused,
    /// and the row must hold the new state at once — not the old one until
    /// the next tick.
    func testAGETAnsweredJustBeforeLeavingIsRankedWhenShownAgain() async throws {
        let (api, client) = try startFake()
        let name = "acme-late"
        api.addApplication(
            name, spec: ["source": ["repoURL": "https://git.acme.example/acme/fleet.git", "path": name], "destination": ["namespace": "shop"]],
            status: ["sync": ["status": "Synced", "revision": FakeKubeAPI.GitOpsCommit.applied], "health": ["status": "Degraded"]])
        let discovery = try await client.discover()
        let session = session()
        session.show(context: "kind-fake", scope: .all, discovery: discovery, client: client)
        let read = await eventually { session.state == .live && !session.summarising && session.rows.shown.contains { $0.ref.name == name } }
        XCTAssertTrue(read)
        try await Task.sleep(for: .milliseconds(300))
        let path = "/apis/argoproj.io/v1alpha1/namespaces/argocd/applications/\(name)"
        api.forgetRequests()
        // The GET is taken by a flush and answered late; the flush its
        // answer waits for is held off, as one in the last 250 ms is.
        api.answerSlowly(path, milliseconds: 500)
        api.setArgoState(name) { status in status["health"] = ["status": "Degraded", "message": "deadline exceeded"] }
        let asked = await eventually { api.requests.contains { !$0.isWatch && $0.path == path } }
        XCTAssertTrue(asked, "read again")
        session.flushInterval = .seconds(60)
        let stored = await eventually {
            session.peers(context: "kind-fake").values.contains { $0.ref.name == name && $0.lastError?.contains("deadline exceeded") == true }
        }
        XCTAssertTrue(stored, "its answer in the store")
        XCTAssertNotEqual(
            session.objects.first { $0.ref.name == name }?.lastError?.contains("deadline exceeded"), true, "not yet ranked: the flush is still to come")

        session.hide()
        session.show(context: "kind-fake", scope: .all, discovery: discovery, client: client)
        XCTAssertEqual(
            session.objects.first { $0.ref.name == name }?.lastError?.contains("deadline exceeded"), true, "the store's state, ranked on show")
        XCTAssertTrue(
            session.rows.shown.contains { $0.ref.name == name && "\($0.why) \($0.hover)".contains("deadline exceeded") },
            "\(session.rows.shown.first { $0.ref.name == name }?.why ?? "no row")")
        session.drop()
    }

    // MARK: Paging

    func testAPageTooLargeIsHalvedAndAnObjectTooLargeStopsTheKind() async throws {
        let (api, client) = try startFake()
        let discovery = try await client.discover()
        let kind = try XCTUnwrap(discovery.kind("applications"))
        api.forgetRequests()
        let halved = try await client.pagedObjects(kind, in: "argocd", pageLimit: 20, maxBytes: 9000)
        let limits = api.requests.compactMap { $0.query["limit"] }
        XCTAssertEqual(limits.first, "20")
        XCTAssertTrue(limits.contains("10") || limits.contains("5"), "halved: \(limits)")
        XCTAssertNil(halved.cut, "every object read at last")
        XCTAssertEqual(halved.objects.count, api.names("applications.argoproj.io").count - 1, "argocd's: all but team-a's")
        XCTAssertEqual(Set(halved.objects.map(\.ref)).count, halved.objects.count, "none twice")

        api.add(
            "applications.argoproj.io", "huge", namespace: "argocd",
            fields: ["metadata": ["annotations": ["note": String(repeating: "x", count: 20_000)]], "spec": ["destination": ["namespace": "shop"]]])
        let stopped = try await client.pagedObjects(kind, in: "argocd", pageLimit: 20, maxBytes: 9000)
        XCTAssertTrue(stopped.cut?.hasPrefix("stopped at an object over") == true, stopped.cut ?? "none")
    }

    func testAPageNeverAsksPastWhatIsLeft() async throws {
        let (api, client) = try startFake()
        for n in 0..<10 {
            api.addApplication(
                "acme-page-\(n)", spec: ["destination": ["namespace": "shop"]],
                status: ["sync": ["status": "Synced"], "health": ["status": "Healthy"]])
        }
        let discovery = try await client.discover()
        let kind = try XCTUnwrap(discovery.kind("applications"))
        api.forgetRequests()
        let three = try await client.pagedObjects(kind, in: "argocd", pageLimit: 20, stopAfter: 3)
        XCTAssertEqual(three.objects.count, 3, "never past stopAfter")
        XCTAssertNotNil(three.cut)
        XCTAssertEqual(api.requests.compactMap { $0.query["limit"] }, ["3"], "a page asks only what is left")
        api.forgetRequests()
        let paged = try await client.pagedObjects(kind, in: "argocd", pageLimit: 2, stopAfter: 3)
        XCTAssertEqual(paged.objects.count, 3)
        XCTAssertEqual(api.requests.compactMap { $0.query["limit"] }, ["2", "1"])
    }

    func testAnExpiredContinueListsAgainFromTheStart() async throws {
        let socket = "/tmp/othg-\(UInt32.random(in: 0...UInt32.max)).sock"
        let api = FakeKubeAPI(socket: socket)
        try api.start()
        fakes.append(api)
        api.addGitOpsFixtures()
        let expired = Expiring()
        let client = KubeClient(
            ExpiringConnection(base: KubeSocketConnection(socket: socket, context: "kind-fake")) { path in
                if path.contains("continue="), expired.first() { api.expireContinueTokens() }
            })
        let served = try await client.discover()
        let kind = try XCTUnwrap(served.kind("applications"))
        let paged = try await client.pagedObjects(kind, in: nil, pageLimit: 3)
        XCTAssertEqual(paged.objects.count, api.names("applications.argoproj.io").count, "every one, after listing again")
        XCTAssertEqual(Set(paged.objects.map(\.ref)).count, paged.objects.count, "none twice")
        XCTAssertNil(paged.cut)
    }
}

/// Once, then never again.
private final class Expiring: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        defer { done = true }
        return !done
    }
}

/// A connection that runs `before` ahead of each bounded read (a stream) it passes on.
private struct ExpiringConnection: KubeConnection {
    let base: KubeSocketConnection
    let before: @Sendable (String) -> Void

    var signIn: KubeSignIn { base.signIn }

    func get(_ path: String, headers: [(String, String)]) async throws -> HTTPResponse { try await base.get(path, headers: headers) }

    func stream(_ path: String, headers: [(String, String)]) -> AsyncThrowingStream<Data, Error> {
        before(path)
        return base.stream(path, headers: headers)
    }
}
