import Foundation
import NIOHTTP1
import XCTest

@testable import Overterm

/// Stage 4's Flux and Argo CD verbs (docs/design/kubernetes/analysis.md,
/// 2.23, decision 24). Pure: which kinds take them, the class check, each
/// request exactly, what each equals, argocd's and flux's lines in a tab.
/// Then through the page's one guard path against the fake API server —
/// `kind-fake` (local, writable), `fake-dev` (read-only), `fake-prod`
/// (production, read-only until its switch), all fictional: the access
/// review, the read, the confirmation naming the context and namespace,
/// then the patch, which the fake applies; refused, nothing is sent.
final class KubeGitOpsTests: XCTestCase {
    static func crd(_ group: String, _ resource: String, _ kind: String, version: String = "v1") -> KubeResourceKind {
        KubeResourceKind(
            group: group, version: version, resource: resource, kind: kind, singular: kind.lowercased(), namespaced: true,
            verbs: ["create", "delete", "deletecollection", "get", "list", "patch", "update", "watch"], subresources: ["status"])
    }

    static let kustomizations = crd("kustomize.toolkit.fluxcd.io", "kustomizations", "Kustomization")
    static let helmReleases = crd("helm.toolkit.fluxcd.io", "helmreleases", "HelmRelease", version: "v2")
    static let gitRepositories = crd("source.toolkit.fluxcd.io", "gitrepositories", "GitRepository")
    static let applications = crd("argoproj.io", "applications", "Application", version: "v1alpha1")

    static func ref(_ kind: KubeResourceKind, _ name: String = "shop", in context: String = "kind-fake") -> KubeObjectRef {
        KubeObjectRef(context: context, kind: kind, namespace: kind == applications ? "argocd" : "flux-system", name: name)
    }

    private static let gitOpsVerbs: [KubeWriteVerb] = [.reconcile, .fluxSuspend, .fluxResume, .refresh]

    // MARK: Which kinds

    func testFluxKindsTakeSuspendResumeAndReconcileAndArgoApplicationsRefresh() {
        for kind in [Self.kustomizations, Self.helmReleases, Self.gitRepositories] {
            XCTAssertEqual(Self.gitOpsVerbs.filter { KubeWriteCheck.offered($0, on: kind) }, [.reconcile, .fluxSuspend, .fluxResume], kind.fullName)
        }
        for name in ["helmrepositories", "helmcharts", "ocirepositories", "buckets"] {
            XCTAssertNotNil(KubeGitOps.flux(Self.crd("source.toolkit.fluxcd.io", name, "Source")), "a Source: \(name)")
        }
        XCTAssertEqual(Self.gitOpsVerbs.filter { KubeWriteCheck.offered($0, on: Self.applications) }, [.refresh])
        for kind in [KubeWritesTests.deployments, KubeWritesTests.cronjobs, .pods, Self.crd("cert-manager.io", "certificates", "Certificate")] {
            XCTAssertTrue(Self.gitOpsVerbs.allSatisfy { !KubeWriteCheck.offered($0, on: kind) }, kind.fullName)
        }
        var readOnly = Self.kustomizations
        readOnly.verbs = ["get", "list", "watch"]
        XCTAssertTrue(Self.gitOpsVerbs.allSatisfy { !KubeWriteCheck.offered($0, on: readOnly) }, "only what discovery says it takes")
        XCTAssertEqual(KubeWriteVerb.fluxSuspend.toggle?.0, .suspended)
        XCTAssertEqual(KubeWriteVerb.fluxSuspend.opposite, .fluxResume)
        XCTAssertEqual(KubeWriteVerb.fluxResume.opposite, .fluxSuspend)
        // Their tab writes: a sync on an Application, a reconcile with its source on a Kustomization or a HelmRelease.
        XCTAssertTrue(KubeTabWrite.offered(.argoSync, on: Self.applications))
        XCTAssertFalse(KubeTabWrite.offered(.argoSync, on: Self.kustomizations))
        XCTAssertTrue(KubeTabWrite.offered(.fluxReconcile, on: Self.kustomizations))
        XCTAssertTrue(KubeTabWrite.offered(.fluxReconcile, on: Self.helmReleases))
        XCTAssertFalse(KubeTabWrite.offered(.fluxReconcile, on: Self.gitRepositories), "a Source has no --with-source")
    }

    // MARK: The class check

    func testTheyAreRefusedOnReadOnlyContextsAndProductionWithoutItsSwitch() {
        let dev = KubeWritesTests.context("fake-dev")
        let prod = KubeWritesTests.context("fake-prod")
        let on = KubeWritesTests.context("fake-prod", session: true)
        let local = KubeWritesTests.context("kind-fake")
        for verb in Self.gitOpsVerbs {
            let kind = verb == .refresh ? Self.applications : Self.kustomizations
            XCTAssertEqual(KubeWriteCheck.rule(verb, for: dev, kind: kind).refused, KubeWriteCheck.readOnly(dev), "\(verb)")
            XCTAssertEqual(KubeWriteCheck.rule(verb, for: prod, kind: kind).refused, KubeWriteCheck.readOnly(prod), "\(verb)")
            for context in [local, on] {
                let rule = KubeWriteCheck.rule(verb, for: context, kind: kind)
                XCTAssertNil(rule.refused, "\(verb) on \(context.name)")
                XCTAssertEqual(rule.access, KubeAccess(verb: "patch", resource: kind.fullName), "\(verb)")
                XCTAssertFalse(rule.typedName, "\(verb): asked, never typed")
            }
        }
        for verb in [KubeProcessVerb.argoSync, .fluxReconcile] {
            XCTAssertTrue(verb.writes)
            XCTAssertEqual(KubeProcessCheck.rule(verb, for: dev).refused, KubeProcessCheck.readOnly(.remote), "\(verb)")
            XCTAssertEqual(KubeProcessCheck.rule(verb, for: prod).refused, KubeProcessCheck.readOnly(.production), "\(verb)")
            XCTAssertNil(KubeProcessCheck.rule(verb, for: local).refused)
        }
        XCTAssertTrue(KubeProcessCheck.rule(.argoSync, for: on).typedName, "a sync on production: the name typed")
        let sync = KubeTabWrite.argoSync(app: "shop", namespace: "argocd", controlPlane: "argocd")
        XCTAssertThrowsError(try KubeCommands.command(sync, in: dev), "nothing built for a read-only context")
        XCTAssertThrowsError(try KubeCommands.command(sync, in: prod))
        XCTAssertNoThrow(try KubeCommands.command(sync, in: local))
    }

    // MARK: The requests

    func testEachVerbIsOneMergePatchOfTheFieldsItsCLISets() throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let stamp = KubeWrites.stamp(at)
        let kustomization = Self.ref(Self.kustomizations)
        let path = "/apis/kustomize.toolkit.fluxcd.io/v1/namespaces/flux-system/kustomizations/shop?fieldManager=overterm"
        let suspend = KubeGitOps.suspend(kustomization)
        XCTAssertEqual(suspend.method, .PATCH)
        XCTAssertEqual(suspend.path, path)
        XCTAssertEqual(suspend.contentType, "application/merge-patch+json", "a custom resource takes no strategic merge patch")
        XCTAssertEqual(String(decoding: suspend.body, as: UTF8.self), #"{"spec":{"suspend":true}}"#)
        let resume = KubeGitOps.resume(kustomization, at: at)
        XCTAssertEqual(resume.path, path)
        XCTAssertEqual(
            resume.json as? NSDictionary, ["metadata": ["annotations": ["reconcile.fluxcd.io/requestedAt": stamp]], "spec": ["suspend": false]] as NSDictionary)
        let reconcile = KubeGitOps.reconcile(Self.ref(Self.helmReleases, "web"), at: at)
        XCTAssertEqual(reconcile.path, "/apis/helm.toolkit.fluxcd.io/v2/namespaces/flux-system/helmreleases/web?fieldManager=overterm")
        XCTAssertEqual(reconcile.json as? NSDictionary, ["metadata": ["annotations": ["reconcile.fluxcd.io/requestedAt": stamp]]] as NSDictionary)
        XCTAssertEqual(reconcile.contentType, KubeWrites.mergePatch)
        let refresh = KubeGitOps.refresh(Self.ref(Self.applications))
        XCTAssertEqual(refresh.path, "/apis/argoproj.io/v1alpha1/namespaces/argocd/applications/shop?fieldManager=overterm")
        XCTAssertEqual(refresh.json as? NSDictionary, ["metadata": ["annotations": ["argocd.argoproj.io/refresh": "normal"]]] as NSDictionary)
        XCTAssertEqual(refresh.contentType, KubeWrites.mergePatch)
    }

    func testWhatEachEqualsAndTheLinesInATab() {
        let kustomization = Self.ref(Self.kustomizations)
        XCTAssertEqual(KubeWrites.kubectl(.fluxSuspend, kustomization), "flux suspend kustomization shop --context kind-fake -n flux-system")
        XCTAssertEqual(KubeWrites.kubectl(.fluxResume, kustomization), "flux resume kustomization shop --context kind-fake -n flux-system")
        XCTAssertEqual(
            KubeWrites.kubectl(.reconcile, Self.ref(Self.gitRepositories, "acme-shop")),
            "flux reconcile source git acme-shop --context kind-fake -n flux-system")
        XCTAssertEqual(
            KubeWrites.kubectl(.refresh, Self.ref(Self.applications)),
            "kubectl annotate applications.argoproj.io shop argocd.argoproj.io/refresh=normal --overwrite --context kind-fake -n argocd")
        XCTAssertEqual(
            KubeWrites.kubectl(.fluxSuspend, Self.ref(Self.kustomizations, "it's", in: "acme dev")),
            "flux suspend kustomization 'it'\\''s' --context 'acme dev' -n flux-system", "quoted for zsh")
        let sync = KubeTabWrite.argoSync(app: "shop", namespace: "argocd", controlPlane: "argocd")
        XCTAssertEqual(
            sync.line(context: "kind-fake"),
            "env -u ARGOCD_SERVER -u ARGOCD_AUTH_TOKEN -u ARGOCD_OPTS argocd app sync shop --app-namespace argocd --core --kube-context kind-fake",
            "core mode: the context's cluster, not a server argocd is logged in to")
        XCTAssertEqual(
            sync.accesses.map(\.access),
            [
                KubeAccess(verb: "patch", resource: "applications.argoproj.io"), KubeAccess(verb: "get", resource: "configmaps"),
                KubeAccess(verb: "list", resource: "secrets"),
            ])
        XCTAssertEqual(sync.accesses.map(\.namespace), ["argocd", "argocd", "argocd"])
        XCTAssertEqual(KubeTabWrite.accesses(.argoSync, namespace: "team-a").map(\.access), [KubeAccess(verb: "patch", resource: "applications.argoproj.io")])
        let flux = KubeTabWrite.fluxReconcile(
            words: ["kustomization"], resource: Self.kustomizations.fullName, name: "shop", namespace: "flux-system", sources: [])
        XCTAssertEqual(flux.line(context: "kind-fake"), "flux reconcile kustomization shop --with-source --context kind-fake -n flux-system")
        XCTAssertEqual(
            KubeTabWrite.accesses(.fluxReconcile, namespace: "flux-system", kind: Self.kustomizations).map(\.access),
            [KubeAccess(verb: "patch", resource: "kustomizations.kustomize.toolkit.fluxcd.io")])
        XCTAssertEqual(KubeTabWrite.accesses(.fluxReconcile, namespace: "flux-system").count, 0, "not without its kind")
    }

    /// Apps in any namespace: an Application in team-a, Argo CD in argocd —
    /// the tab is pinned to argocd (core mode reads its settings there),
    /// `--app-namespace` says team-a, and both are reviewed where they are.
    func testASyncTakesArgoCDsNamespaceNotTheApplications() {
        XCTAssertEqual(KubeGitOps.argoNamespace(installs: ["argocd"], application: "team-a"), "argocd")
        XCTAssertEqual(KubeGitOps.argoNamespace(installs: ["gitops"], application: "team-a"), "gitops", "the one install, wherever it is")
        XCTAssertEqual(KubeGitOps.argoNamespace(installs: ["argocd", "team-a"], application: "team-a"), "team-a", "the Application's own install")
        XCTAssertEqual(KubeGitOps.argoNamespace(installs: ["ops-b", "argocd", "ops-a"], application: "team-a"), "argocd")
        XCTAssertEqual(KubeGitOps.argoNamespace(installs: ["ops-b", "ops-a"], application: "team-a"), "ops-a")
        XCTAssertEqual(KubeGitOps.argoNamespace(installs: [], application: "team-a"), "argocd", "none found: Argo CD's default")
        let sync = KubeTabWrite.argoSync(app: "shop", namespace: "team-a", controlPlane: "argocd")
        XCTAssertTrue(sync.line(context: "kind-fake").contains("argocd app sync shop --app-namespace team-a --core --kube-context kind-fake"))
        XCTAssertEqual(sync.accesses.map(\.namespace), ["team-a", "argocd", "argocd"], "the Application where it is, Argo CD's settings in its own")
        let local = KubeWritesTests.context("kind-fake")
        let asked = sync.confirmation(context: local, rule: KubeProcessCheck.rule(.argoSync, for: local))
        XCTAssertEqual(asked.scope, "kind-fake · namespace team-a")
        XCTAssertTrue(asked.detail.contains("reads Argo CD's settings in namespace argocd"), asked.detail)
    }

    /// `--with-source` annotates the source first: read off the object, each reviewed.
    func testAReconcileWithSourceReviewsItsSource() {
        func object(_ namespace: String, _ name: String, _ spec: [String: Any]) -> [String: Any] {
            ["metadata": ["namespace": namespace, "name": name], "spec": spec]
        }
        let ks = Self.kustomizations.fullName
        let hr = Self.helmReleases.fullName
        let git = KubeGitOps.sources(of: object("apps", "shop", ["sourceRef": ["kind": "GitRepository", "name": "acme-shop"]]), resource: ks)
        XCTAssertEqual(git, [KubeGitOps.FluxSource(kind: "GitRepository", resource: "gitrepositories.source.toolkit.fluxcd.io", name: "acme-shop", namespace: "apps")])
        let elsewhere = KubeGitOps.sources(
            of: object("apps", "shop", ["sourceRef": ["kind": "OCIRepository", "name": "acme-shop", "namespace": "flux-system"]]), resource: ks)
        XCTAssertEqual(elsewhere?.map(\.resource), ["ocirepositories.source.toolkit.fluxcd.io"])
        XCTAssertEqual(elsewhere?.map(\.namespace), ["flux-system"], "sourceRef.namespace")
        XCTAssertNil(KubeGitOps.sources(of: object("apps", "shop", [:]), resource: ks), "no source: refused, not reviewed short")
        XCTAssertNil(KubeGitOps.sources(of: object("apps", "shop", ["sourceRef": ["kind": "Widget", "name": "w"]]), resource: ks))
        // A HelmRelease's chart template: the HelmChart flux makes for it, then its repository.
        let template = KubeGitOps.sources(
            of: object(
                "apps", "web",
                ["chart": ["spec": ["chart": "web", "sourceRef": ["kind": "HelmRepository", "name": "acme", "namespace": "flux-system"]]]]),
            resource: hr)
        XCTAssertEqual(template?.map(\.spoken), ["helmchart flux-system/apps-web", "helmrepository flux-system/acme"])
        let chartRef = KubeGitOps.sources(of: object("apps", "web", ["chartRef": ["kind": "OCIRepository", "name": "web-chart"]]), resource: hr)
        XCTAssertEqual(chartRef?.map(\.spoken), ["ocirepository apps/web-chart"])
        XCTAssertEqual(
            KubeGitOps.chartSources(of: ["spec": ["sourceRef": ["kind": "GitRepository", "name": "charts"]]], at: "apps").map(\.spoken),
            ["gitrepository apps/charts"])
        let write = KubeTabWrite.fluxReconcile(words: ["kustomization"], resource: ks, name: "shop", namespace: "apps", sources: elsewhere ?? [])
        XCTAssertEqual(
            write.accesses.map { "\($0.access) \($0.namespace ?? "")" },
            ["patch \(ks) apps", "patch ocirepositories.source.toolkit.fluxcd.io flux-system"])
        let local = KubeWritesTests.context("kind-fake")
        XCTAssertTrue(
            write.confirmation(context: local, rule: KubeProcessCheck.rule(.fluxReconcile, for: local)).detail.contains(
                "flux fetches its source again (ocirepository flux-system/acme-shop)"))
    }

    func testTheConfirmationsNameTheContextAndNamespace() {
        let local = KubeWritesTests.context("kind-fake")
        let prod = KubeWritesTests.context("fake-prod", session: true)
        let suspend = KubeWriteConfirmation.make(
            .fluxSuspend, Self.ref(Self.kustomizations), context: local, rule: KubeWriteCheck.rule(.fluxSuspend, for: local, kind: Self.kustomizations))
        XCTAssertEqual(suspend.title, "Suspend Flux's reconciliation of kustomization flux-system/shop?")
        XCTAssertEqual(suspend.scope, "kind-fake · namespace flux-system")
        XCTAssertTrue(suspend.detail.contains("Equals: flux suspend kustomization shop --context kind-fake -n flux-system"), suspend.detail)
        XCTAssertTrue(suspend.detail.contains("puts back nothing changed by hand"), "warned: \(suspend.detail)")
        XCTAssertNil(suspend.typedName)
        let refresh = KubeWriteConfirmation.make(
            .refresh, Self.ref(Self.applications, in: "fake-prod"), context: prod, rule: KubeWriteCheck.rule(.refresh, for: prod, kind: Self.applications))
        XCTAssertEqual(refresh.title, "Refresh application argocd/shop?")
        XCTAssertEqual(refresh.scope, "PRODUCTION · fake-prod · namespace argocd")
        XCTAssertTrue(refresh.production)
        XCTAssertTrue(refresh.detail.contains("Nothing is synced"), refresh.detail)
        let sync = KubeTabWrite.argoSync(app: "shop", namespace: "argocd", controlPlane: "argocd").confirmation(context: prod, rule: KubeProcessCheck.rule(.argoSync, for: prod))
        XCTAssertEqual(sync.scope, "PRODUCTION · fake-prod · namespace argocd")
        XCTAssertEqual(sync.typedName, "shop")
        XCTAssertTrue(sync.detail.contains("argocd app sync shop --app-namespace argocd --core --kube-context fake-prod"), sync.detail)
        XCTAssertEqual(KubeWriteOutcome.done(.refresh, Self.ref(Self.applications)), "Asked Argo CD to refresh application argocd/shop in kind-fake: it compares it with its source again.")
    }
}

/// The verbs through the page's guard path, against the fake API server.
@MainActor
final class KubeGitOpsPageTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!

    override func setUp() async throws {
        socket = "/tmp/otkgo-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("flux-system")
        api.addPod("web-1", namespace: "flux-system")
        api.addCRD(group: "kustomize.toolkit.fluxcd.io", version: "v1", plural: "kustomizations", kind: "Kustomization", shortNames: ["ks"])
        api.addCRD(group: "argoproj.io", version: "v1alpha1", plural: "applications", kind: "Application", shortNames: ["app"])
        api.add(
            "kustomizations.kustomize.toolkit.fluxcd.io", "shop", namespace: "flux-system",
            fields: ["spec": ["path": "./deploy", "prune": true, "sourceRef": ["kind": "GitRepository", "name": "acme-shop"]]])
        api.add(
            "applications.argoproj.io", "shop", namespace: "flux-system",
            fields: ["spec": ["destination": ["server": "https://kubernetes.default.svc", "namespace": "shop"]]])
        // Argo CD itself in argocd: the Application above is in another namespace (apps in any namespace).
        api.addNamespace("argocd")
        api.add("configmaps", KubeGitOps.argoConfigMap, namespace: "argocd", data: ["url": "https://argocd.acme.example"])
    }

    override func tearDown() async throws {
        api?.stop()
    }

    private final class Box {
        var confirmations: [(KubeWriteConfirmation, (KubeWriteAnswer) -> Void)] = []
        var confirms: [(String, String, () -> Void)] = []
        var commands: [(String, String, String)] = []
    }

    private let at = Date(timeIntervalSince1970: 1_790_000_000)

    private func page(current: String) async throws -> (KubernetesPageModel, Box) {
        let model = KubernetesModel(proxies: KubeProxies())
        let list = KubeContextList(contexts: ["fake-dev", "fake-prod", "kind-fake"].map { KubeWritesTests.context($0) }, current: current)
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.flushInterval = .milliseconds(20)
        model.statusInterval = .milliseconds(50)
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name, writable: context.isWritable) }
        model.statusOverride = { _ in .open }
        model.access.run = { _, _, _ in .yes }
        let page = KubernetesPageModel(model: model)
        let at = self.at
        page.clock = { at }
        let box = Box()
        var actions = KubernetesActions(run: { _ in }, settings: {}, copy: { _ in }, copySecret: { _ in })
        actions.confirmWrite = { confirmation, then in box.confirmations.append((confirmation, then)) }
        actions.confirm = { _, detail, button, then in box.confirms.append((detail, button, then)) }
        actions.runInTab = { command, context, namespace in box.commands.append((command, context.name, namespace)) }
        page.actions = actions
        model.show()
        try await until("listed") { model.selectedName == current && model.discovery?.kind("ks") != nil }
        return (page, box)
    }

    private func show(_ page: KubernetesPageModel, _ name: String) async throws {
        let kind = try XCTUnwrap(page.model.discovery?.kind(name))
        page.model.setScope(.namespace("flux-system"))
        page.showKind(kind)
        try await until("\(name) listed") { page.model.kind.fullName == kind.fullName && page.model.rows.count == 1 && page.model.listState == .live }
        page.selection = ["flux-system/shop"]
    }

    private func until(_ what: String, _ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func written() -> [FakeKubeAPI.Request] { api.writes.filter { !$0.isAccessReview } }
    private func reviewed() -> [[String: String]] {
        api.requests.filter(\.isAccessReview).compactMap {
            (($0.json as? [String: Any])?["spec"] as? [String: Any])?["resourceAttributes"] as? [String: String]
        }
    }

    private func object(_ resource: String) -> [String: Any] {
        api.object(resource, "shop", namespace: "flux-system") ?? [:]
    }

    private func annotations(_ resource: String) -> [String: String] {
        ((object(resource)["metadata"] as? [String: Any])?["annotations"] as? [String: String]) ?? [:]
    }

    private func suspended() -> Bool { KubeWriteToggle.suspended.state(of: object("kustomizations.kustomize.toolkit.fluxcd.io")) }

    /// `p` suspends, `p` again resumes (the object read decides), `r`
    /// reconciles — each reviewed, asked naming the context and namespace,
    /// then one merge patch the fake applies.
    func testSuspendResumeAndReconcileAKustomization() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        try await show(page, "ks")
        let verbs = page.verbs(for: ["flux-system/shop"]).map(\.title)
        for title in ["Reconcile…", "Suspend Reconciliation…", "Resume Reconciliation…", "Reconcile with Source in a Tab…"] {
            XCTAssertTrue(verbs.contains(title), "\(title) in \(verbs)")
        }
        api.forgetRequests()
        XCTAssertTrue(page.press("p"))
        try await until("asked") { box.confirmations.count == 1 }
        XCTAssertTrue(reviewed().contains(["verb": "patch", "resource": "kustomizations", "group": "kustomize.toolkit.fluxcd.io", "namespace": "flux-system"]), "\(reviewed())")
        let order = api.requests.map(\.description)
        let review = try XCTUnwrap(order.firstIndex(of: "POST /apis/authorization.k8s.io/v1/selfsubjectaccessreviews"))
        let read = try XCTUnwrap(order.firstIndex(of: "GET /apis/kustomize.toolkit.fluxcd.io/v1/namespaces/flux-system/kustomizations/shop"))
        XCTAssertLessThan(review, read, "reviewed before it is read")
        let suspend = box.confirmations[0].0
        XCTAssertEqual(suspend.verb, .fluxSuspend)
        XCTAssertEqual(suspend.scope, "kind-fake · namespace flux-system")
        XCTAssertEqual(written(), [], "nothing before the button")
        box.confirmations[0].1("")
        try await until("suspended") { self.suspended() }
        XCTAssertEqual(written().map(\.description), ["PATCH /apis/kustomize.toolkit.fluxcd.io/v1/namespaces/flux-system/kustomizations/shop"])
        XCTAssertEqual(written().last?.contentType, "application/merge-patch+json")
        try await until("said") { page.writeStatus == .done("Suspended Flux's reconciliation of kustomization flux-system/shop in kind-fake.") }

        // r on a suspended one: refused with why, nothing sent.
        let before = written().count
        XCTAssertTrue(page.press("r"))
        try await until("refused") { page.writeStatus?.isFailure == true }
        XCTAssertEqual(page.writeStatus, .failed(KubeGitOps.suspended("kustomization flux-system/shop")))
        XCTAssertEqual(box.confirmations.count, 1)
        XCTAssertEqual(written().count, before)

        // p again: read as suspended, so a resume — with a reconcile asked.
        XCTAssertTrue(page.press("p"))
        try await until("asked to resume") { box.confirmations.count == 2 }
        XCTAssertEqual(box.confirmations[1].0.verb, .fluxResume)
        box.confirmations[1].1("")
        try await until("resumed") { !self.suspended() }
        XCTAssertEqual(annotations("kustomizations.kustomize.toolkit.fluxcd.io")[KubeGitOps.requestedAt], KubeWrites.stamp(at))

        // r: a reconcile.
        XCTAssertTrue(page.press("r"))
        try await until("asked to reconcile") { box.confirmations.count == 3 }
        XCTAssertEqual(box.confirmations[2].0.verb, .reconcile)
        XCTAssertTrue(box.confirmations[2].0.detail.contains("Equals: flux reconcile kustomization shop --context kind-fake -n flux-system"))
        box.confirmations[2].1("")
        try await until("reconciled") {
            page.writeStatus
                == .done(
                    "Asked Flux to reconcile kustomization flux-system/shop in kind-fake: its status.lastHandledReconcileAt says when it has.")
        }
        XCTAssertEqual(written().count, before + 2)

        // Reconcile with Source: flux in a tab pinned to the context.
        let tab = try XCTUnwrap(page.verbs(for: ["flux-system/shop"]).first { $0.title == "Reconcile with Source in a Tab…" })
        try await until("reviewed") { page.verbs(for: ["flux-system/shop"]).first { $0.title == tab.title }?.unavailable == nil }
        page.verbs(for: ["flux-system/shop"]).first { $0.title == tab.title }?.perform()
        try await until("asked in a tab") { box.confirmations.count == 4 }
        XCTAssertTrue(
            reviewed().contains(["verb": "patch", "resource": "gitrepositories", "group": "source.toolkit.fluxcd.io", "namespace": "flux-system"]),
            "its source reviewed too: \(reviewed())")
        XCTAssertTrue(box.confirmations[3].0.detail.contains("(gitrepository flux-system/acme-shop)"), box.confirmations[3].0.detail)
        XCTAssertTrue(box.commands.isEmpty, "nothing typed while it asks")
        box.confirmations[3].1("")
        XCTAssertEqual(box.commands.first?.0, "flux reconcile kustomization shop --with-source --context kind-fake -n flux-system")
        XCTAssertEqual(box.commands.first?.1, "kind-fake")
        XCTAssertEqual(box.commands.first?.2, "flux-system")
        XCTAssertEqual(written().count, before + 2, "flux's own: nothing of Overterm's sent")
    }

    /// `r` refreshes an Application; `s` syncs it with argocd in a tab.
    func testRefreshAndSyncAnApplication() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        try await show(page, "app")
        XCTAssertTrue(page.press("r"))
        try await until("asked") { box.confirmations.count == 1 }
        XCTAssertEqual(box.confirmations[0].0.title, "Refresh application flux-system/shop?")
        box.confirmations[0].1("")
        try await until("refreshed") { self.annotations("applications.argoproj.io")[KubeGitOps.refresh] == "normal" }
        XCTAssertEqual(written().map(\.description), ["PATCH /apis/argoproj.io/v1alpha1/namespaces/flux-system/applications/shop"])
        XCTAssertTrue(page.press("s"))
        try await until("the sync asked") { box.confirmations.count == 2 }
        XCTAssertTrue(reviewed().contains(["verb": "patch", "resource": "applications", "group": "argoproj.io", "namespace": "flux-system"]), "\(reviewed())")
        XCTAssertTrue(reviewed().contains(["verb": "get", "resource": "configmaps", "group": "", "namespace": "argocd"]), "Argo CD's own namespace: \(reviewed())")
        XCTAssertTrue(box.confirmations[1].0.detail.contains("reads Argo CD's settings in namespace argocd"), box.confirmations[1].0.detail)
        XCTAssertNil(box.confirmations[1].0.typedName, "not typed off production")
        box.confirmations[1].1("")
        XCTAssertEqual(box.commands.first?.2, "argocd", "pinned to Argo CD's namespace, not the Application's")
        XCTAssertEqual(
            box.commands.first?.0,
            "env -u ARGOCD_SERVER -u ARGOCD_AUTH_TOKEN -u ARGOCD_OPTS argocd app sync shop --app-namespace flux-system --core --kube-context kind-fake")
        XCTAssertEqual(written().count, 1, "argocd's own: nothing more sent")
    }

    /// The source's patch refused: Reconcile with Source is refused before it is asked, nothing run.
    func testAReconcileWithSourceRefusedOnItsSource() async throws {
        api.deniedAccess = ["patch gitrepositories.source.toolkit.fluxcd.io"]
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        try await show(page, "ks")
        let title = KubeTabWrite.title(.fluxReconcile)
        try await until("reviewed") { page.verbs(for: ["flux-system/shop"]).first { $0.title == title }?.unavailable == nil }
        page.verbs(for: ["flux-system/shop"]).first { $0.title == title }?.perform()
        try await until("refused") { page.writeStatus?.isFailure == true }
        XCTAssertTrue("\(String(describing: page.writeStatus))".contains("gitrepositories"), "\(String(describing: page.writeStatus))")
        XCTAssertTrue(box.confirmations.isEmpty && box.commands.isEmpty)
        XCTAssertEqual(written(), [])
    }

    /// fake-dev: every verb greyed with why, each key refused at once, nothing sent — not even a review.
    func testReadOnlyRefusesEveryVerbAndSendsNothing() async throws {
        let (page, box) = try await page(current: "fake-dev")
        defer { page.model.hide() }
        try await show(page, "ks")
        let readOnly = "This context is read-only: Overterm changes nothing here (its writable setting)."
        let gitOps = ["Reconcile…", "Suspend Reconciliation…", "Resume Reconciliation…", "Reconcile with Source in a Tab…"]
        let verbs = page.verbs(for: ["flux-system/shop"]).filter { gitOps.contains($0.title) }
        XCTAssertEqual(verbs.count, 4)
        XCTAssertTrue(verbs.allSatisfy { $0.unavailable == readOnly }, "\(verbs.map { $0.unavailable ?? "none" })")
        api.forgetRequests()
        for key in ["p", "r"] {
            page.writeStatus = nil
            XCTAssertTrue(page.press(key))
            XCTAssertEqual(page.writeStatus, .failed(readOnly), key)
        }
        try await show(page, "app")
        page.writeStatus = nil
        XCTAssertTrue(page.press("s"))
        XCTAssertEqual(page.writeStatus, .failed(readOnly))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(box.confirmations.isEmpty && box.commands.isEmpty)
        XCTAssertEqual(api.writes, [], "no write, no review")
    }

    /// fake-prod: refused until its switch; then asked naming PRODUCTION, a sync's name typed.
    func testProductionNeedsItsSwitch() async throws {
        let (page, box) = try await page(current: "fake-prod")
        defer { page.model.hide() }
        try await show(page, "ks")
        XCTAssertTrue(page.press("r"))
        XCTAssertEqual(page.writeStatus, .failed("Production is read-only: turn on writes for this session on its card first."))
        XCTAssertEqual(api.writes, [])
        await page.model.setProductionWrites(true, for: "fake-prod")
        try await until("on, listed again") { page.model.selected?.isWritable == true && page.model.rows.count == 1 }
        page.selection = ["flux-system/shop"]
        XCTAssertTrue(page.press("r"))
        try await until("asked") { box.confirmations.count == 1 }
        XCTAssertEqual(box.confirmations[0].0.scope, "PRODUCTION · fake-prod · namespace flux-system")
        XCTAssertNil(box.confirmations[0].0.typedName)
        try await show(page, "app")
        XCTAssertTrue(page.press("s"))
        try await until("the sync asked") { box.confirmations.count == 2 }
        XCTAssertEqual(box.confirmations[1].0.typedName, "shop")
        box.confirmations[1].1("sho")
        XCTAssertEqual(page.writeStatus, .failed("The name typed wasn't shop: nothing was run."))
        XCTAssertTrue(box.commands.isEmpty)
        await page.model.setProductionWrites(false, for: "fake-prod")
    }

    /// The fake refuses a strategic merge patch of a custom resource, as a server does.
    func testTheFakeRefusesAStrategicPatchOfACustomResource() async throws {
        let connection = KubeSocketConnection(socket: socket, context: "kind-fake", writable: true)
        let client = KubeClient(connection)
        var request = KubeGitOps.suspend(KubeGitOpsTests.ref(KubeGitOpsTests.kustomizations))
        request.contentType = KubeWrites.strategicPatch
        do {
            try await client.write(request)
            XCTFail("a strategic patch of a custom resource")
        } catch {
            XCTAssertEqual((error as? KubeAPIError)?.status, 415, "\(error)")
        }
        XCTAssertFalse(suspended())
    }
}
