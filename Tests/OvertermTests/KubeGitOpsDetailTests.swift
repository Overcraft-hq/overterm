import Foundation
import XCTest

@testable import Overterm

/// A GitOps object's detail and its Ask Why (docs/design/kubernetes/
/// gitops.md, 2.9, 6.2, G3): the header's state sentence, sources,
/// revisions with their times, settings, chain and root cause from the
/// summaries alone; Argo CD's operation, out-of-sync resources (each a
/// link) and last 10 history entries; the brief's words — the sentinel and
/// a URL's token never in any of it. Pure, over `FakeKubeAPI+GitOps`'s
/// objects read as a GET answers them.
final class KubeGitOpsDetailTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let c = FakeKubeAPI.GitOpsCommit.self
    private let dev = KubeBriefContext(name: "kind-fake", production: false, writable: true)

    private struct Fixtures {
        var fake: FakeKubeAPI
        var peers: KubeGitOpsLadder.Peers
    }

    private func fixtures() throws -> Fixtures {
        let fake = FakeKubeAPI(socket: nil)
        fake.addGitOpsFixtures(now: now)
        var objects: [KubeGitOpsObject] = []
        for kind in KubeGitOpsSummary.summarised {
            for name in fake.names(kind.fullName) {
                for namespace in ["argocd", "team-a", "flux-system"] {
                    guard let whole = fake.object(kind.fullName, name, namespace: namespace) else { continue }
                    objects.append(try XCTUnwrap(try KubeGitOpsSummary.object(try JSONSerialization.data(withJSONObject: whole), readAt: now)))
                }
            }
        }
        var peers: KubeGitOpsLadder.Peers = [:]
        for object in KubeGitOpsSummary.ranked(objects, now: now) { peers[object.key] = object }
        return Fixtures(fake: fake, peers: peers)
    }

    private func detail(_ fake: FakeKubeAPI, _ resource: String, _ name: String, in namespace: String) throws -> KubeGitOpsDetail {
        let whole = try XCTUnwrap(fake.object(resource, name, namespace: namespace), "\(resource) \(name)")
        return try XCTUnwrap(KubeGitOpsDetail.read(try JSONSerialization.data(withJSONObject: whole), readAt: now))
    }

    private let ks = "kustomizations.kustomize.toolkit.fluxcd.io"
    private let hr = "helmreleases.helm.toolkit.fluxcd.io"
    private let app = "applications.argoproj.io"

    func testTheFourKindsHaveAHeaderAndSourcesDont() throws {
        let f = try fixtures()
        XCTAssertNotNil(try? detail(f.fake, app, "acme-web", in: "argocd"))
        XCTAssertNotNil(try? detail(f.fake, ks, "acme-cron", in: "flux-system"))
        XCTAssertNotNil(try? detail(f.fake, "applicationsets.argoproj.io", "acme-envs", in: "argocd"))
        let source = try XCTUnwrap(f.fake.object("gitrepositories.source.toolkit.fluxcd.io", "acme-fleet", namespace: "flux-system"))
        XCTAssertNil(KubeGitOpsDetail.read(try JSONSerialization.data(withJSONObject: source), readAt: now), "a source is no detail's")
        let kinds = KubeGitOpsSummary.summarised.map { KubeResourceKind(group: $0.group, version: "v1", resource: $0.resource, kind: "", singular: "", namespaced: true, verbs: []) }
        XCTAssertEqual(kinds.filter(KubeGitOpsDetail.isGitOps).map(\.resource), ["applications", "kustomizations", "helmreleases", "applicationsets"])
    }

    func testTheStateSentenceIsTheLaddersWithItsAge() throws {
        let f = try fixtures()
        let payments = try detail(f.fake, hr, "acme-payments", in: "flux-system")
        let verdict = payments.verdict(peers: f.peers, now: now)
        XCTAssertEqual(KubeGitOpsDetail.sentence(verdict, now: now), "Failed: upgrade to 1.5.0 failed; rolled back to 1.4.2 (4m)")
        let api = try detail(f.fake, ks, "acme-api", in: "flux-system")
        XCTAssertEqual(api.verdict(peers: f.peers, now: now).state, .blocked, "its source's failure, from the summaries")
        XCTAssertEqual(api.verdict(peers: [:], now: now).state, .failed, "without them, what it says of itself")
    }

    func testWhereFromWhatIsAppliedAndHow() throws {
        let f = try fixtures()
        let cron = try detail(f.fake, ks, "acme-cron", in: "flux-system")
        XCTAssertEqual(cron.sourceLines(peers: f.peers), ["git.acme.example/acme/shop ./apps/cron @main"], "the source's URL, without its token")
        let revisions = cron.revisionLines(peers: f.peers, now: now)
        XCTAssertEqual(revisions.map(\.label), ["Applied", "Attempted", "Fetched"])
        XCTAssertEqual(revisions[0].value, "main@a77b0d1")
        XCTAssertEqual(revisions[1].value, "main@c03f9aa")
        XCTAssertEqual(revisions[1].when, "failed (BuildFailed) 8m ago")
        XCTAssertEqual(revisions[2].when, "by GitRepository acme-fleet 60m ago")
        let settings = Dictionary(uniqueKeysWithValues: cron.settingLines(now: now).map { ($0.label, $0.value) })
        XCTAssertEqual(settings["Into"], "shop")
        XCTAssertEqual(settings["Interval"], "10m")
        XCTAssertEqual(settings["Prune"], "on: what leaves git is deleted")

        let jobs = try detail(f.fake, ks, "acme-jobs", in: "flux-system")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: jobs.settingLines(now: now).map { ($0.label, $0.value) })["Suspended"], "yes, 12d ago by overterm")

        let shop = try detail(f.fake, app, "acme-shop-prod", in: "argocd")
        XCTAssertEqual(shop.sourceLines(peers: f.peers), ["git.acme.example/acme/shop deploy/fake-prod @main"])
        let shopSettings = Dictionary(uniqueKeysWithValues: shop.settingLines(now: now).map { ($0.label, $0.value) })
        XCTAssertEqual(shopSettings["Auto-sync"], "on — prune, self-heal")
        XCTAssertEqual(shopSettings["Into"], "shop · this cluster")
        let shopRevisions = shop.revisionLines(peers: f.peers, now: now)
        XCTAssertEqual(shopRevisions.first?.value, "a77b0d1")
        XCTAssertEqual(shopRevisions.first?.when, "deployed 60m ago")

        let multi = try detail(f.fake, app, "acme-api", in: "team-a")
        XCTAssertEqual(
            multi.sourceLines(peers: f.peers), ["api@1.5.0 from oci://ghcr.io/acme/charts", "git.acme.example/acme/shop @main — values from this repo"])
        XCTAssertEqual(multi.revisionLines(peers: f.peers, now: now).first { $0.label == "Wanted" }?.value, "1.5.0 · 77e1a02")

        let payments = try detail(f.fake, hr, "acme-payments", in: "flux-system")
        XCTAssertEqual(payments.sourceLines(peers: f.peers), ["payments@1.5.0 from https://charts.acme.example"])
        let release = payments.revisionLines(peers: f.peers, now: now)
        XCTAssertEqual(release.map(\.label), ["Release", "Attempted", "Fetched"])
        XCTAssertEqual(release[0].value, "1.4.2")
        XCTAssertEqual(release[0].when, "deployed 4m ago", "the history head's status and when")
        XCTAssertEqual(release[1].value, "1.5.0")
        XCTAssertEqual(release[1].when, "failed (RollbackSucceeded) 4m ago", "a time where a time belongs, never a digest")

        let redis = try detail(f.fake, hr, "globex-redis", in: "flux-system")
        let tried = try XCTUnwrap(redis.revisionLines(peers: f.peers, now: now).first { $0.label == "Attempted" })
        XCTAssertEqual(tried.value, "18.2.0 @ " + KubeGitOpsRevision.shown("sha256:" + String(repeating: "9a8b7c6d", count: 8)), "the digest is the value's")
        XCTAssertEqual(tried.when, "failed (InstallFailed) 15m ago")
    }

    func testTheChainFromTheSummariesAndItsRootCause() throws {
        let f = try fixtures()
        let web = try detail(f.fake, ks, "acme-web", in: "flux-system")
        let chain = web.chain(peers: f.peers)
        XCTAssertEqual(chain.map(\.role), ["Source", "Depends on"])
        XCTAssertEqual(chain.map { "\($0.key)" }, ["GitRepository flux-system/acme-fleet", "Kustomization flux-system/acme-infra"])
        XCTAssertTrue(chain.allSatisfy { $0.peer != nil })
        let link = KubeGitOpsDetail.link(chain[1].key, peer: chain[1].peer)
        XCTAssertEqual(link, KubeLink(apiVersion: "kustomize.toolkit.fluxcd.io/v1", kind: "Kustomization", namespace: "flux-system", name: "acme-infra"))
        let cause = try XCTUnwrap(web.rootCause(peers: f.peers, now: now))
        XCTAssertEqual(cause.key.name, "acme-infra")
        XCTAssertEqual(cause.verdict.state, .failed)

        let api = try detail(f.fake, ks, "acme-api", in: "flux-system")
        XCTAssertEqual(try XCTUnwrap(api.rootCause(peers: f.peers, now: now)).key.name, "acme-broken")
        XCTAssertNil(api.rootCause(peers: [:], now: now), "nothing read for it: no summaries, no cause")
        XCTAssertNil(api.chain(peers: [:]).first?.peer, "said as not summarised")

        let generated = try detail(f.fake, app, "acme-envs-dev", in: "argocd")
        XCTAssertEqual(generated.chain(peers: f.peers).map(\.role), ["Generated by"])
        XCTAssertEqual(generated.chain(peers: f.peers).first?.key.description, "ApplicationSet argocd/acme-envs")
    }

    func testArgoCDsOperationOutOfSyncResourcesAndHistory() throws {
        let f = try fixtures()
        let web = try detail(f.fake, app, "acme-web", in: "argocd")
        XCTAssertEqual(web.failures.map(\.said), ["Deployment shop/acme-web: admission webhook denied the request"])
        let operation = Dictionary(uniqueKeysWithValues: web.operationLines(now: now).map { ($0.label, $0.value) })
        XCTAssertEqual(operation["Phase"], "Failed, started 13m ago")
        XCTAssertEqual(operation["Message"], "one or more synchronization tasks completed unsuccessfully")

        let api = try detail(f.fake, app, "acme-api", in: "team-a")
        XCTAssertEqual(api.resources.map(\.said), ["Deployment shop/api"])
        XCTAssertEqual(api.resources.first?.link, KubeLink(apiVersion: "apps/v1", kind: "Deployment", namespace: "shop", name: "api"), "each opens its object")

        let shop = try detail(f.fake, app, "acme-shop-prod", in: "argocd")
        XCTAssertEqual(shop.history.map { $0.revisions }, [[c.applied], [c.older]], "newest first")
        XCTAssertTrue(shop.resources.isEmpty, "a synced resource isn't listed")

        // Only the last 10 entries, 50 resources each, the rest counted.
        let history = (0..<15).map { ["revision": String(format: "%040d", $0), "deployedAt": FakeKubeAPI.time(now.addingTimeInterval(Double($0 - 15) * 60))] }
        let resources =
            (0..<60).map { ["group": "", "version": "v1", "kind": "ConfigMap", "namespace": "shop", "name": "cm-\($0)", "status": "OutOfSync"] }
            + [["group": "apps", "version": "v1", "kind": "Deployment", "namespace": "shop", "name": "synced", "status": "Synced"]]
        let failed = (0..<55).map { ["kind": "Job", "name": "job-\($0)", "namespace": "shop", "status": "SyncFailed", "message": "boom"] }
        let big: [String: Any] = [
            "apiVersion": "argoproj.io/v1alpha1", "kind": "Application", "metadata": ["name": "acme-big", "namespace": "argocd"],
            "status": ["history": history, "resources": resources, "operationState": ["phase": "Failed", "syncResult": ["resources": failed]]],
        ]
        let read = try XCTUnwrap(KubeGitOpsDetail.read(try JSONSerialization.data(withJSONObject: big), readAt: now))
        XCTAssertEqual(read.history.count, 10)
        XCTAssertEqual(read.history.first?.revisions, [String(format: "%040d", 14)])
        XCTAssertEqual(read.history.last?.revisions, [String(format: "%040d", 5)])
        XCTAssertEqual(read.resources.count, 50)
        XCTAssertEqual(read.resourcesPast, 10)
        XCTAssertEqual(read.failures.count, 50)
        XCTAssertEqual(read.failuresPast, 5)
    }

    func testTheBriefSaysWhyWhereFromAndTheRootCause() throws {
        let f = try fixtures()
        let api = try detail(f.fake, ks, "acme-api", in: "flux-system")
        let brief = api.brief(context: dev, peers: f.peers, now: now)
        XCTAssertEqual(brief.message, "Why is Flux Kustomization flux-system/acme-api blocked, and what would unblock it?")
        XCTAssertEqual(brief.subject, "Kustomization/acme-api Blocked")
        XCTAssertTrue(brief.text.contains("Kubernetes Flux Kustomization flux-system/acme-api, in context kind-fake."), brief.text)
        XCTAssertTrue(brief.text.contains("Root cause, along its chain: GitRepository flux-system/acme-broken is Failed"), brief.text)
        XCTAssertEqual(brief.parts.map(\.title), ["conditions", "chain"])

        let web = try detail(f.fake, app, "acme-web", in: "argocd")
        let argo = web.brief(context: dev, peers: f.peers, now: now)
        XCTAssertEqual(argo.message, "Why does Argo CD Application argocd/acme-web fail to deploy, and what should change?")
        XCTAssertTrue(argo.parts.contains { $0.title == "operation" && $0.text.contains("Deployment shop/acme-web: admission webhook denied the request") })
        XCTAssertTrue(argo.parts.contains { $0.title == "history" })

        let cron = try detail(f.fake, ks, "acme-cron", in: "flux-system")
        let flux = cron.brief(context: dev, peers: f.peers, now: now)
        XCTAssertTrue(flux.text.contains("Attempted: main@c03f9aa (failed (BuildFailed) 8m ago)"), flux.text)
        XCTAssertTrue(flux.text.contains("Applied: main@a77b0d1"), flux.text)

        let fine = try detail(f.fake, ks, "acme-apps", in: "flux-system")
        let verdict = fine.verdict(peers: f.peers, now: now)
        XCTAssertEqual(
            KubeGitOpsDetail.notAsked(fine.object, state: verdict.state, why: verdict.why),
            "Kustomization flux-system/acme-apps is Ready (applied main@a77b0d1): Ask Why is for one that is Failed, Blocked or Stuck.")
        XCTAssertNil(KubeGitOpsDetail.notAsked(cron.object, state: .failed, why: ""))
    }

    /// The sentinel and a URL's token: never in a header's or a brief's words, for any object.
    func testTheSentinelIsNeverInTheDetailOrTheBrief() throws {
        let f = try fixtures()
        for resource in [app, "applicationsets.argoproj.io", ks, hr] {
            for name in f.fake.names(resource) {
                for namespace in ["argocd", "team-a", "flux-system"] {
                    guard f.fake.object(resource, name, namespace: namespace) != nil else { continue }
                    let detail = try detail(f.fake, resource, name, in: namespace)
                    let brief = detail.brief(context: dev, peers: f.peers, now: now)
                    var words = [String(reflecting: detail), brief.message, brief.subject, brief.text] + brief.parts.map(\.text)
                    words += detail.sourceLines(peers: f.peers) + detail.conditionLines + [detail.conditionsText]
                    words += detail.revisionLines(peers: f.peers, now: now).map { "\($0.value) \($0.when ?? "")" }
                    words += detail.settingLines(now: now).map(\.value) + detail.operationLines(now: now).map(\.value)
                    let all = words.joined(separator: "\n")
                    XCTAssertFalse(all.contains(FakeKubeAPI.gitOpsSentinel), "\(resource) \(name)")
                    XCTAssertFalse(all.contains("ghp_fake"), "\(resource) \(name): a URL's userinfo")
                }
            }
        }
    }
}

/// Ask Why on GitOps objects against the fake API server on a socket of the
/// tests' own (gitops.md 6.2, 8.2): offered on a Failed one, greyed with why
/// on a Ready one, the detail's header read from its one GET, the brief's
/// chain read by a GET each when the page holds no summaries — only GETs,
/// never a Secret or a ConfigMap.
@MainActor
final class KubeGitOpsAskWhyPageTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!

    override func setUp() async throws {
        socket = "/tmp/otgd-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        api.addGitOpsFixtures()
    }

    override func tearDown() async throws {
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
            XCTAssertFalse(api.requests.contains { $0.path.contains("/secrets") || $0.path.contains("/configmaps") }, "never a Secret or a ConfigMap")
            api.stop()
        }
    }

    private final class Box { var briefs: [KubeAgentBrief] = [] }

    private func page() async throws -> (KubernetesPageModel, Box) {
        let model = KubernetesModel(proxies: KubeProxies())
        let name = "kind-fake"
        let context = KubeContext(
            name: name, cluster: name, server: "http://127.0.0.1:1", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: KubeClassifier.classify(context: name, cluster: name, set: nil), settings: KubeContextSettings())
        model.load = { _ in KubeContextList(contexts: [context], current: name) }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.flushInterval = .milliseconds(20)
        model.statusInterval = .milliseconds(50)
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
        model.statusOverride = { _ in .open }
        model.access.run = { _, _, _ in .yes }
        let page = KubernetesPageModel(model: model)
        let box = Box()
        var actions = KubernetesActions(run: { _ in }, settings: {}, copy: { _ in }, copySecret: { _ in })
        actions.askWhy = { brief in box.briefs.append(brief) }
        page.actions = actions
        model.show()
        try await until("discovered") { model.discovery?.kinds.contains { $0.fullName == "kustomizations.kustomize.toolkit.fluxcd.io" } == true }
        return (page, box)
    }

    private func until(_ what: String, _ timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func ref(_ page: KubernetesPageModel, _ fullName: String, _ name: String, in namespace: String = "flux-system") throws -> KubeObjectRef {
        let kind = try XCTUnwrap(page.model.discovery?.kinds.first { $0.fullName == fullName })
        return KubeObjectRef(context: "kind-fake", kind: kind, namespace: namespace, name: name)
    }

    func testTheDetailsHeaderAndAskWhyOnAFailingKustomization() async throws {
        let (page, box) = try await page()
        defer { page.model.hide() }
        let cron = try ref(page, "kustomizations.kustomize.toolkit.fluxcd.io", "acme-cron")
        page.open(cron, from: .link)
        try await until("the detail read") { page.detail?.gitOps != nil }
        XCTAssertEqual(page.detail?.gitOps?.object.ref.name, "acme-cron")
        let verb = page.detailVerbs(for: cron).first { $0.title == "Ask an Agent Why…" }
        XCTAssertNotNil(verb, "offered on a GitOps object")
        XCTAssertNil(verb?.unavailable, "it is Failed")
        verb?.perform()
        try await until("the brief") { box.briefs.count == 1 }
        let brief = try XCTUnwrap(box.briefs.first)
        XCTAssertEqual(brief.subject, "Kustomization/acme-cron Failed")
        XCTAssertTrue(brief.text.contains("main@c03f9aa failed (BuildFailed); main@a77b0d1 still applied"), brief.text)
        XCTAssertFalse(([brief.text] + brief.parts.map(\.text)).joined().contains(FakeKubeAPI.gitOpsSentinel))
        XCTAssertEqual(brief.namespace, "flux-system")
        XCTAssertNil(page.askingWhy)
    }

    func testAReadyOneIsGreyedWithWhyAndAsksNothing() async throws {
        let (page, box) = try await page()
        defer { page.model.hide() }
        let apps = try ref(page, "kustomizations.kustomize.toolkit.fluxcd.io", "acme-apps")
        page.open(apps, from: .link)
        try await until("the detail read") { page.detail?.gitOps != nil }
        let why = page.askWhyVerb(for: apps)?.unavailable
        XCTAssertEqual(why, "Kustomization flux-system/acme-apps is Ready (applied main@a77b0d1): Ask Why is for one that is Failed, Blocked or Stuck.")
        XCTAssertTrue(page.press("a"))
        XCTAssertEqual(page.commandProblem, why)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(box.briefs.isEmpty)
    }

    func testABlockedOnesBriefReadsItsChainByAGetEach() async throws {
        let (page, box) = try await page()
        defer { page.model.hide() }
        api.forgetRequests()
        page.askWhy(try ref(page, "kustomizations.kustomize.toolkit.fluxcd.io", "acme-api"))
        try await until("the brief") { box.briefs.count == 1 || page.commandProblem != nil }
        let brief = try XCTUnwrap(box.briefs.first, page.commandProblem ?? "")
        XCTAssertEqual(brief.subject, "Kustomization/acme-api Blocked")
        XCTAssertTrue(brief.text.contains("Root cause, along its chain: GitRepository flux-system/acme-broken is Failed"), brief.text)
        XCTAssertFalse(brief.text.contains("ghp_fake"), "a URL's token out")
        let reads = api.requests.filter { !$0.isDiscovery }.map(\.path)
        XCTAssertTrue(reads.contains { $0.hasSuffix("/kustomizations/acme-api") })
        XCTAssertTrue(reads.contains { $0.hasSuffix("/gitrepositories/acme-broken") }, "its source read for the chain: \(reads)")
        XCTAssertLessThanOrEqual(reads.filter { $0.contains("toolkit.fluxcd.io") }.count, 1 + KubeAgentBriefing.gitOpsChainReads)
    }

    /// More dependencies than the brief may read, none summarised, every
    /// one Ready but the last: the reads go where it fails — the one its
    /// Ready message names — never spent on healthy siblings first.
    func testTheChainsReadsGoToTheBranchThatFails() async throws {
        let ks = "kustomizations.kustomize.toolkit.fluxcd.io"
        let count = KubeAgentBriefing.gitOpsChainReads + 3
        let names = (1...count).map { "acme-dep-\($0)" }
        let now = Date()
        for name in names {
            let failing = name == names.last
            api.addFlux(
                ks, name, spec: ["interval": "10m", "path": "./\(name)", "sourceRef": ["kind": "GitRepository", "name": "acme-fleet"]],
                status: [
                    "observedGeneration": 1,
                    "conditions": [
                        failing
                            ? FakeKubeAPI.condition("Ready", "False", "HealthCheckFailed", "health check failed after 5m: Deployment/shop/acme-queue not ready", since: now)
                            : FakeKubeAPI.condition("Ready", "True", "ReconciliationSucceeded", "Applied revision: main@sha1:abc", since: now)
                    ],
                ], metadata: ["generation": 1])
        }
        api.addFlux(
            ks, "acme-many",
            spec: [
                "interval": "10m", "path": "./apps/many", "sourceRef": ["kind": "GitRepository", "name": "acme-fleet"],
                "dependsOn": names.map { ["name": $0] },
            ],
            status: [
                "observedGeneration": 1,
                "conditions": [FakeKubeAPI.condition("Ready", "False", "DependencyNotReady", "dependency 'flux-system/\(names.last!)' is not ready", since: now)],
            ], metadata: ["generation": 1])
        let (page, box) = try await page()
        defer { page.model.hide() }
        api.forgetRequests()
        page.askWhy(try ref(page, ks, "acme-many"))
        try await until("the brief") { box.briefs.count == 1 || page.commandProblem != nil }
        let brief = try XCTUnwrap(box.briefs.first, page.commandProblem ?? "")
        XCTAssertEqual(brief.subject, "Kustomization/acme-many Blocked")
        XCTAssertTrue(brief.text.contains("Root cause, along its chain: Kustomization flux-system/\(names.last!) is Failed"), brief.text)
        let reads = api.requests.filter { !$0.isDiscovery }.map(\.path)
        XCTAssertTrue(reads.contains { $0.hasSuffix("/kustomizations/\(names.last!)") }, "the failing one read: \(reads)")
        XCTAssertFalse(reads.contains { $0.hasSuffix("/kustomizations/acme-dep-1") }, "a healthy sibling not read first: \(reads)")
    }
}
