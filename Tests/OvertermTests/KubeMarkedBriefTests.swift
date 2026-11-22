import NIOHTTP1
import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell

/// Ask Why on an Argo CD app read from the marks on its objects (docs/
/// design/kubernetes/gitops.md, 14.2.6, D6): the brief's words — the
/// question in Argo CD's own word, the app, why it is read from marks in
/// the mode's words, what only its Application knows and where, its health
/// and whose, each object as its app counts it, its hooks, its images, how
/// to look with kubectl and argocd; a chip each for the objects'
/// conditions, the not-ready workloads' pods and the causes' events —
/// every word scrubbed, the sentinel nowhere; offered on every app that
/// isn't Ready, Progressing included; one failing Deployment handing off
/// to its own brief with the app named. Against `FakeKubeAPI`'s spoke on a
/// socket of the test's own: only GETs, never a Secret or a ConfigMap,
/// never a write. Nothing reads ~/.kube.
@MainActor
final class KubeMarkedBriefTests: XCTestCase {
    nonisolated(unsafe) private var api: FakeKubeAPI?
    private var now = Date()

    override func tearDown() async throws {
        if let api {
            XCTAssertEqual(api.requests.filter { $0.method != "GET" }.map(\.description), [], "only GETs")
            XCTAssertFalse(api.requests.contains { $0.path.contains("/secrets") || $0.path.contains("/configmaps") }, "never a Secret or a ConfigMap")
            api.stop()
        }
    }

    private static let production = KubeBriefContext(name: "fake-prod", production: true, writable: true)
    private static let password = "s3cr3t-" + "brief-pw"

    private func member(_ kind: KubeMarkedKind, _ name: String, namespace: String = "team-4", app: String, _ verdict: KubeMarkedHealth.Verdict?, image: String? = nil)
        -> KubeMarkedMember
    {
        var marks = KubeMarkWire()
        marks.tracking = .own(KubeTrackingID.parse("\(app):\(kind.group)/\(kind.kind):\(namespace)/\(name)")!)
        return KubeMarkedMember(id: .init(kind: kind, namespace: namespace, name: name), marks: marks, health: verdict, images: image.map { [$0] } ?? [])
    }

    private func ledger() -> KubeMarkedRanked {
        let app = "prod-team-4-acme-ledger-service"
        let members = [
            member(.statefulSet, "acme-ledger-db", app: app, KubeMarkedHealth.Verdict(status: .progressing, sentence: "0/3 ready"), image: "registry.acme.example/postgres:16.4"),
            member(.service, "acme-ledger-db", app: app, KubeMarkedHealth.Verdict(status: .healthy, sentence: "service")),
        ]
        let made = KubeMarkedApp.make(key: .init(installation: "", instance: app), members)!
        return KubeMarkedRanked(app: made, health: made.health)
    }

    // MARK: The words (pure)

    func testTheBriefSaysTheAppWhyFromMarksWhatOnlyTheApplicationKnowsAndWhose() throws {
        let ranked = ledger()
        let id = ranked.app.members[0].id
        var wire = KubeMarkedHealthTests.wire([
            "apiVersion": "apps/v1", "kind": "StatefulSet", "metadata": ["name": "acme-ledger-db", "namespace": "team-4", "generation": 2],
            "spec": ["replicas": 3], "status": ["observedGeneration": 2, "replicas": 3, "readyReplicas": 0],
        ])
        // A message as a test writes it, never decoded: the brief scrubs it all the same.
        wire.status?.conditions = [.init(type: "Ready", status: "False", reason: "PodsPending", message: "fetching https://bot:\(Self.password)@git.acme.example/acme/db failed")]
        var pod = KubeMarkedAppDetail.Child(kind: .pod, namespace: "team-4", name: "acme-ledger-db-0")
        pod.health = KubeMarkedHealth.Verdict(status: .progressing, sentence: "Pending", fromRow: true)
        let event = KubeEvent(
            id: "e1", type: "Warning", reason: "FailedScheduling", message: "0/3 nodes are available: token=\(Self.password)", count: 4, first: now.addingTimeInterval(-600),
            last: now.addingTimeInterval(-60), source: "default-scheduler")
        var facts = KubeMarkedBriefFacts(
            ranked: ranked, lead: KubeMarkedAppsMode.Reason.notServed.line(context: "fake-prod"),
            whereApplication: KubeMarkedAppDetail.whereTheApplicationIs(.only(.notServed)), scope: "health of the 2 objects bound here", context: Self.production)
        facts.objects = [id: wire]
        facts.pods = [id: [pod]]
        facts.events = [id: [event]]
        facts.notes = ["Service acme-ledger-db's events (refused)"]
        let brief = KubeAgentBrief.markedApp(facts, now: now)
        XCTAssertEqual(brief.message, "Why is Argo CD app prod-team-4-acme-ledger-service still Progressing — 0/3 ready, StatefulSet acme-ledger-db?")
        XCTAssertEqual(brief.subject, "Argo CD app prod-team-4-acme-ledger-service Progressing")
        let text = brief.text
        for expected in [
            "Argo CD app prod-team-4-acme-ledger-service, read from the marks Argo CD leaves on its objects, in PRODUCTION context fake-prod (read only: change nothing there).",
            "Argo CD runs in another cluster — not in your kubeconfig.",
            "What only its Application knows isn't here — sync status, repository and path, target and live revision, sync policy (automated, prune, selfHeal), last sync, project: in the Application, in Argo CD's cluster.",
            "Its health, by Argo CD's built-in rules applied to its objects here (custom health checks configured in Argo CD aren't known): Progressing — 0/3 ready · StatefulSet acme-ledger-db; health of the 2 objects bound here.",
            "- StatefulSet team-4/acme-ledger-db: Progressing — 0/3 ready",
            "- Service team-4/acme-ledger-db: Healthy — service",
            "Images: registry.acme.example/postgres:16.4.",
            "Read StatefulSet acme-ledger-db with: kubectl --context fake-prod -n team-4 describe statefulset.apps/acme-ledger-db",
            "Its Application, against your own Argo CD server (never this kubeconfig): argocd app get prod-team-4-acme-ledger-service",
            "Not in this brief, couldn't be read: Service acme-ledger-db's events (refused).",
        ] {
            XCTAssertTrue(text.contains(expected), "\(expected) not in:\n\(text)")
        }
        XCTAssertEqual(brief.parts.map(\.title), ["conditions", "pods", "events"])
        let conditions = try XCTUnwrap(brief.parts.first { $0.title == "conditions" }?.text)
        XCTAssertTrue(conditions.contains("StatefulSet team-4/acme-ledger-db:\n  replicas: 3 wanted, 3 current, 0 updated, 0 ready, 0 available; generation 2, observed 2"), conditions)
        XCTAssertTrue(conditions.contains("Ready False (PodsPending): fetching https://git.acme.example/acme/db failed"), conditions)
        XCTAssertTrue(brief.parts.first { $0.title == "pods" }?.text.contains("acme-ledger-db-0: Pending — Progressing") == true)
        XCTAssertTrue(brief.parts.first { $0.title == "events" }?.text.contains("Warning FailedScheduling ×4") == true)
        let whole = ([brief.message, brief.subject, brief.text] + brief.parts.map(\.text)).joined(separator: "\n")
        XCTAssertFalse(whole.contains(Self.password), "every word scrubbed:\n\(whole)")
        XCTAssertTrue(brief.production)
        XCTAssertEqual(brief.context, "fake-prod")
        XCTAssertEqual(brief.namespace, "team-4")
        XCTAssertEqual(brief.images, ["registry.acme.example/postgres:16.4"])
    }

    /// The mode's words: only `notServed` says Argo CD's cluster; an app only
    /// probably Argo CD's says nothing of where Argo CD runs and has no argocd line.
    func testTheModesWordsAndAProbableApp() {
        let ranked = ledger()
        for (reason, place) in [
            (KubeMarkedAppsMode.Reason.noApplications, "which isn't in this cluster"), (.forbidden, "which can't be read here"), (.undiscovered, "which couldn't be looked for here"),
        ] {
            let facts = KubeMarkedBriefFacts(
                ranked: ranked, lead: reason.line(context: "fake-prod"), whereApplication: KubeMarkedAppDetail.whereTheApplicationIs(.only(reason)), context: Self.production)
            let text = KubeAgentBrief.markedApp(facts, now: now).text
            XCTAssertTrue(text.contains(place), text)
            XCTAssertFalse(text.contains("another cluster") || text.contains("Argo CD's cluster"), text)
        }
        var app = ranked.app
        app.mark = .appInstance
        let probable = KubeMarkedBriefFacts(
            ranked: KubeMarkedRanked(app: app, health: ranked.health), lead: nil,
            whereApplication: KubeMarkedAppDetail.whereTheApplicationIs(.only(.notServed), probable: true), context: Self.production)
        let brief = KubeAgentBrief.markedApp(probable, now: now)
        XCTAssertTrue(brief.message.hasPrefix("Why is app prod-team-4-acme-ledger-service (probably Argo CD's) still Progressing"), brief.message)
        XCTAssertFalse(brief.text.contains("another cluster") || brief.text.contains("Argo CD's cluster") || brief.text.contains("argocd app get"), brief.text)
        XCTAssertTrue(brief.text.contains(KubeMarkedSection.probablyArgos), brief.text)
    }

    /// Offered on every app that isn't Ready — Progressing, Paused and
    /// Unknown too —; an Unknown with a Degraded member said as ranked with Failed.
    func testOfferedOnEveryAppThatIsntReady() {
        let app = "prod-team-1-acme-pay-service"
        let ready = KubeMarkedApp.make(
            key: .init(installation: "", instance: app), [member(.deployment, "acme-pay", namespace: "team-1", app: app, KubeMarkedHealth.Verdict(status: .healthy, sentence: "2/2 available"))])!
        XCTAssertEqual(
            KubeAgentBriefing.markedNotAsked(KubeMarkedRanked(app: ready, health: ready.health)),
            "Argo CD app prod-team-1-acme-pay-service is Ready (1 object ready): Ask Why is for one that isn't.")
        XCTAssertNil(KubeAgentBriefing.markedNotAsked(ledger()), "Progressing: asked")
        let mixed = KubeMarkedApp.make(
            key: .init(installation: "", instance: app),
            [
                member(.deployment, "acme-pay", namespace: "team-1", app: app, KubeMarkedHealth.Verdict(status: .degraded, sentence: "rollout stalled (ProgressDeadlineExceeded)")),
                member(.persistentVolumeClaim, "acme-pay-data", namespace: "team-1", app: app, KubeMarkedHealth.Verdict(status: .unknown, sentence: "volume claim Released")),
            ])!
        let ranked = KubeMarkedRanked(app: mixed, health: mixed.health)
        XCTAssertNil(KubeAgentBriefing.markedNotAsked(ranked))
        let brief = KubeAgentBrief.markedApp(
            KubeMarkedBriefFacts(ranked: ranked, lead: nil, whereApplication: KubeMarkedAppDetail.whereTheApplicationIs(.only(.notServed)), context: Self.production), now: now)
        XCTAssertTrue(brief.message.hasPrefix("What is wrong with Argo CD app \(app) (Unknown — rollout stalled (ProgressDeadlineExceeded), Deployment acme-pay)"), brief.message)
        XCTAssertTrue(brief.text.contains("Unknown — rollout stalled (ProgressDeadlineExceeded) · Deployment acme-pay · and 1 more (ranked with Failed: its worst known member)"), brief.text)
    }

    // MARK: Against the fake

    private func spoke(rollouts: Bool = false) throws -> (FakeKubeAPI, KubeClient, FakeKubeAPI.Spoke, KubeDiscovery?) {
        let socket = "/tmp/otkmb-\(UInt32.random(in: 0...UInt32.max)).sock"
        let api = FakeKubeAPI(socket: socket)
        try api.start()
        self.api = api
        self.socket = socket
        let made = api.addSpoke(FakeKubeAPI.SpokeOptions(apps: 4, rollouts: rollouts), now: now)
        return (api, KubeClient(KubeSocketConnection(socket: socket, context: "fake-prod")), made, nil)
    }

    nonisolated(unsafe) private var socket: String?

    /// The fake's connection with its discovery unanswered — a proxy that
    /// can't say what the context serves —, every other read the fake's.
    private struct NoDiscovery: KubeConnection {
        let inner: KubeSocketConnection
        struct Unanswered: Error, LocalizedError {
            var errorDescription: String? { "the API server didn't answer discovery" }
        }

        func get(_ path: String, headers: [(String, String)]) async throws -> HTTPResponse {
            let bare = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
            if bare == "/api" || bare == "/apis" { throw Unanswered() }
            return try await inner.get(path, headers: headers)
        }
        func stream(_ path: String, headers: [(String, String)]) -> AsyncThrowingStream<Data, Error> { inner.stream(path, headers: headers) }
        var signIn: KubeSignIn { inner.signIn }
        var writable: Bool { inner.writable }
        func write(_ method: HTTPMethod, _ path: String, body: Data?, headers: [(String, String)]) async throws -> HTTPResponse {
            try await inner.write(method, path, body: body, headers: headers)
        }
    }

    /// The app as the section would rank it from the spoke's rows.
    private func ranked(_ instance: String, client: KubeClient, discovery: KubeDiscovery) async throws -> KubeMarkedRanked {
        var members: [KubeMarkedMember] = []
        for kind in KubeMarkedAppsSession.kinds(discovery).workloads + KubeMarkedAppsSession.kinds(discovery).rows {
            let table = try await client.list(kind, in: .all, options: KubeListOptions(marks: true))
            members += table.rows.compactMap { KubeMarkedMember.row($0, kind: KubeMarkedKind(kind), columns: table.columns, now: now) }
        }
        let app = try XCTUnwrap(KubeMarkedApps.group(members).apps.first { $0.key.instance == instance })
        return KubeMarkedRanked(app: app, health: app.health)
    }

    /// The StatefulSet `0/3`, Progressing: its own brief — its object read
    /// by a GET, its pods by its own selector as Table rows, its events —
    /// the sentinel in nothing of it.
    func testAProgressingStatefulSetsAppBriefIsReadByGETsOnly() async throws {
        let (api, client, made, _) = try spoke()
        let discovery = try await client.discover()
        let ranked = try await ranked(made.statefulSet, client: client, discovery: discovery)
        XCTAssertEqual(ranked.health.state, .progressing)
        api.forgetRequests()
        let brief = try await KubeAgentBriefing.markedApp(
            ranked, lead: KubeMarkedAppsMode.Reason.notServed.line(context: "fake-prod"), whereApplication: KubeMarkedAppDetail.whereTheApplicationIs(.only(.notServed)),
            client: client, context: Self.production, discovery: discovery, now: now)
        XCTAssertEqual(brief.message, "Why is Argo CD app \(made.statefulSet) still Progressing — 0/3 ready, StatefulSet acme-ledger-db?")
        let pods = try XCTUnwrap(brief.parts.first { $0.title == "pods" }?.text, "\(brief.parts.map(\.title))")
        XCTAssertTrue(pods.contains("acme-ledger-db-0: Pending — Progressing"), pods)
        XCTAssertTrue(brief.parts.contains { $0.title == "conditions" }, "\(brief.parts.map(\.title))")
        let paths = api.requests.map(\.path)
        // What it read, and nothing else: its object, its pods by its selector, its events (14.9.3).
        XCTAssertEqual(
            Set(paths), ["/apis/apps/v1/namespaces/team-4/statefulsets/acme-ledger-db", "/api/v1/namespaces/team-4/pods", "/api/v1/namespaces/team-4/events"],
            "\(paths)")
        XCTAssertTrue(paths.contains("/apis/apps/v1/namespaces/team-4/statefulsets/acme-ledger-db"), "its object by a GET: \(paths)")
        let podList = try XCTUnwrap(api.requests.first { $0.path == "/api/v1/namespaces/team-4/pods" })
        XCTAssertEqual(podList.query["labelSelector"], "app=acme-ledger-db")
        XCTAssertTrue(podList.accept.contains("as=Table") && podList.query["includeObject"] == "Metadata", "rows, never whole pods")
        XCTAssertTrue(paths.contains("/api/v1/namespaces/team-4/events"), "its events")
        XCTAssertFalse(paths.contains { $0.contains("/services/") }, "a Service's cells say its health: no GET")
        let whole = ([brief.message, brief.subject, brief.text] + brief.parts.map(\.text)).joined(separator: "\n")
        XCTAssertFalse(whole.contains(FakeKubeAPI.gitOpsSentinel), whole)
    }

    /// An Argo Rollout's app (14.12's second consequence: on the surveyed
    /// spokes every Rollout runs a Deployment by `workloadRef`, with no
    /// selector of its own): Degraded by its phase, its pods listed by the
    /// selector of the Deployment it scales to 0 — read within the brief's
    /// six — the crash-looping one among them; the Deployment said scaled by
    /// it, never its pods' owner.
    func testARolloutsAppBriefListsItsPodsByItsDeploymentsSelector() async throws {
        let (api, client, made, _) = try spoke(rollouts: true)
        let discovery = try await client.discover()
        let ranked = try await ranked(made.rolloutDegraded, client: client, discovery: discovery)
        XCTAssertNotEqual(ranked.health.state, .ready, "its Rollout's phase isn't in its row")
        api.forgetRequests()
        let brief = try await KubeAgentBriefing.markedApp(
            ranked, lead: KubeMarkedAppsMode.Reason.notServed.line(context: "fake-prod"), whereApplication: KubeMarkedAppDetail.whereTheApplicationIs(.only(.notServed)),
            client: client, context: Self.production, discovery: discovery, now: now)
        XCTAssertTrue(brief.message.hasPrefix("Why is Argo CD app \(made.rolloutDegraded) Degraded — rollout degraded, Rollout acme-blue"), brief.message)
        let pods = try XCTUnwrap(brief.parts.first { $0.title == "pods" }?.text, "\(brief.parts.map(\.title))")
        XCTAssertTrue(pods.contains("Pods of Rollout team-1/acme-blue:"), pods)
        XCTAssertTrue(pods.contains("acme-blue-84c6d9-d3e4f: CrashLoopBackOff"), "the crash-looping pod: \(pods)")
        XCTAssertFalse(pods.contains("Pods of Deployment"), "the Deployment scaled by its Rollout owns none of them here: \(pods)")
        XCTAssertTrue(brief.text.contains("- Deployment team-1/acme-blue: Healthy — scaled by its Rollout"), brief.text)
        let podList = try XCTUnwrap(api.requests.first { $0.path == "/api/v1/namespaces/team-1/pods" })
        XCTAssertEqual(podList.query["labelSelector"], "app=acme-blue", "the Deployment's own selector")
        XCTAssertTrue(podList.accept.contains("as=Table") && podList.query["includeObject"] == "Metadata", "rows, never whole pods")
        XCTAssertEqual(
            Set(api.requests.map(\.path)),
            [
                "/apis/argoproj.io/v1alpha1/namespaces/team-1/rollouts/acme-blue", "/apis/apps/v1/namespaces/team-1/deployments/acme-blue", "/api/v1/namespaces/team-1/pods",
                "/api/v1/namespaces/team-1/events",
            ], "\(api.requests.map(\.path))")
        let whole = ([brief.message, brief.subject, brief.text] + brief.parts.map(\.text)).joined(separator: "\n")
        XCTAssertFalse(whole.contains(FakeKubeAPI.gitOpsSentinel), whole)
    }

    /// Asked where what the context serves isn't known (the rail's Ask Why
    /// on a context the page never showed): read once for the brief —
    /// and where even that read fails, the built-in workloads' kinds —
    /// never "not served" said for want of it.
    func testWithNoDiscoveryTheBriefReadsItNeverSaysNotServed() async throws {
        let (api, client, made, _) = try spoke()
        let discovery = try await client.discover()
        let ranked = try await ranked(made.statefulSet, client: client, discovery: discovery)
        api.forgetRequests()
        let read = try await KubeAgentBriefing.markedApp(
            ranked, lead: nil, whereApplication: KubeMarkedAppDetail.whereTheApplicationIs(.only(.notServed)), client: client, context: Self.production, discovery: nil,
            now: now)
        XCTAssertTrue(api.requests.contains { $0.isDiscovery }, "what it serves, read for the brief")
        XCTAssertTrue(read.parts.first { $0.title == "pods" }?.text.contains("acme-ledger-db-0: Pending") == true, "\(read.parts.map(\.title))")
        XCTAssertFalse(read.text.contains("aren't served"), read.text)

        // Discovery unanswered: the built-in kinds' GETs all the same.
        api.forgetRequests()
        let blind = KubeClient(NoDiscovery(inner: KubeSocketConnection(socket: try XCTUnwrap(socket), context: "fake-prod")))
        let built = try await KubeAgentBriefing.markedApp(
            ranked, lead: nil, whereApplication: KubeMarkedAppDetail.whereTheApplicationIs(.only(.notServed)), client: blind, context: Self.production, discovery: nil,
            now: now)
        XCTAssertTrue(api.requests.contains { $0.path == "/apis/apps/v1/namespaces/team-4/statefulsets/acme-ledger-db" }, "\(api.requests.map(\.path))")
        XCTAssertTrue(built.parts.first { $0.title == "pods" }?.text.contains("acme-ledger-db-0: Pending") == true, "\(built.parts.map(\.title))")
        XCTAssertFalse(built.text.contains("aren't served"), built.text)
    }

    /// One failing Deployment: the Deployment's own brief — its rollout,
    /// its ReplicaSets and pods, its template masked — with the app named
    /// in what is always sent and a chip of the app's objects.
    func testOneFailingDeploymentHandsOffToItsOwnBriefWithTheAppNamed() async throws {
        let (_, client, made, _) = try spoke()
        let discovery = try await client.discover()
        let ranked = try await ranked(made.stalled, client: client, discovery: discovery)
        let settled = KubeMarkedRanked(
            app: ranked.app,
            health: {
                var app = ranked.app
                app.members = app.members.map { member in
                    guard member.id.kind == .deployment else { return member }
                    var stalled = member
                    stalled.health = KubeMarkedHealth.Verdict(status: .degraded, sentence: "rollout stalled (ProgressDeadlineExceeded)")
                    return stalled
                }
                return app.health
            }())
        XCTAssertEqual(settled.health.causes.map(\.member.name), ["acme-cart"])
        let brief = try await KubeAgentBriefing.markedApp(
            settled, lead: KubeMarkedAppsMode.Reason.notServed.line(context: "fake-prod"), whereApplication: KubeMarkedAppDetail.whereTheApplicationIs(.only(.notServed)),
            client: client, context: Self.production, discovery: discovery, now: now)
        XCTAssertEqual(brief.subject, "deploy/acme-cart ProgressDeadlineExceeded", "the Deployment's own brief")
        XCTAssertEqual(brief.parts.first?.title, "Argo CD app")
        XCTAssertTrue(brief.parts.first?.text.contains("- Service team-2/acme-cart: Healthy — service — ignore-healthcheck: not counted, as in Argo CD") == true, brief.parts.first?.text ?? "")
        XCTAssertTrue(brief.text.contains("It is one of Argo CD app \(made.stalled)'s objects, as the marks Argo CD leaves on them say."), brief.text)
        XCTAssertTrue(brief.text.contains("Argo CD runs in another cluster — not in your kubeconfig."), brief.text)
        XCTAssertTrue(brief.text.contains("What only its Application knows isn't here"), brief.text)
        XCTAssertTrue(brief.parts.contains { $0.title == "pod template" }, "\(brief.parts.map(\.title))")
        let whole = ([brief.message, brief.subject, brief.text] + brief.parts.map(\.text)).joined(separator: "\n")
        XCTAssertFalse(whole.contains(FakeKubeAPI.gitOpsSentinel), "env, args and last-applied all masked:\n\(whole)")
    }

    /// Read again for its brief, a Ready app says so — never a brief.
    func testAnAppReadyNowIsntAsked() async throws {
        let (_, client, made, _) = try spoke()
        let discovery = try await client.discover()
        let ranked = try await ranked(made.apps[0], client: client, discovery: discovery)
        do {
            _ = try await KubeAgentBriefing.markedApp(ranked, lead: nil, whereApplication: "", client: client, context: Self.production, discovery: discovery, now: now)
            XCTFail("a Ready app has no brief")
        } catch let problem as KubeBriefProblem {
            XCTAssertEqual(problem, .notFailing("Argo CD app \(made.apps[0]) is Ready (\(ranked.health.why)): Ask Why is for one that isn't."))
            XCTAssertEqual(ranked.health.why, "3 objects ready", "its Deployment, Service and HPA")
        }
    }
}
