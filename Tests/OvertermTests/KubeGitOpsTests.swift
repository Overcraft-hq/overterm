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
/// And what their objects say, read right (docs/design/kubernetes/
/// gitops.md, 1.1, G0a): `revision(s)`/`source(s)` by one reader, Argo CD
/// 3's `appTree` tree, the owner an object's marks name and the apply's
/// warnings from them.
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

    private static func data(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    // MARK: Revisions and sources

    func testOneReaderForBothFormsOfRevisionsAndSources() {
        XCTAssertEqual(KubeGitOpsSource.revisions(["revision": "a77b0d1"]), ["a77b0d1"])
        XCTAssertEqual(KubeGitOpsSource.revisions(["revision": "", "revisions": ["a77b0d1", "1.4.2"]]), ["a77b0d1", "1.4.2"], "multi-source: the plural")
        XCTAssertEqual(KubeGitOpsSource.revisions(["revision": ""]), [], "nothing fetched yet")
        XCTAssertEqual(KubeGitOpsSource.revisions(nil), [])
        XCTAssertEqual(KubeGitOpsSource.revision(["revisions": ["a77b0d1", "", "1.4.2"]], source: 1), nil, "a source with nothing yet keeps its index")
        XCTAssertEqual(KubeGitOpsSource.revision(["revisions": ["a77b0d1", "", "1.4.2"]], source: 2), "1.4.2")
        XCTAssertEqual(KubeGitOpsSource.revision(["revision": "a77b0d1"], source: 0), "a77b0d1")
        XCTAssertNil(KubeGitOpsSource.revision(["revision": "a77b0d1"], source: 1))
        XCTAssertEqual(KubeGitOpsSource.sourceTypes(["sourceType": "Helm"]), ["Helm"])
        XCTAssertEqual(KubeGitOpsSource.sourceTypes(["sourceTypes": ["Helm", "Directory"]]), ["Helm", "Directory"])

        let multi: [String: Any] = [
            "sources": [
                ["repoURL": "oci://ghcr.io/acme/charts", "chart": "api", "targetRevision": "1.4.2"],
                ["repoURL": "git@git.acme.example:acme/shop", "targetRevision": "main", "ref": "values"],
            ]
        ]
        let sources = KubeGitOpsSource.all(in: multi)
        XCTAssertEqual(sources.map(\.repoURL), ["oci://ghcr.io/acme/charts", "git@git.acme.example:acme/shop"])
        XCTAssertEqual(sources.map(\.place), ["api", nil])
        XCTAssertEqual(sources.map(\.ref), [nil, "values"])
        XCTAssertEqual(KubeGitOpsSource.all(in: ["source": ["repoURL": "https://git.acme.example/acme/shop.git", "path": "deploy"]]).map(\.path), ["deploy"])
        XCTAssertEqual(KubeGitOpsSource.all(in: [:]), [])

        // What is applied (history, else the operation) and what git has now.
        let status: [String: Any] = [
            "sync": ["status": "OutOfSync", "revisions": ["77e1a02", "1.4.2"]],
            "history": [["revisions": ["0000001", "1.4.1"]], ["revisions": ["5d0c1e2", "1.4.2"]]],
            "operationState": ["phase": "Succeeded", "syncResult": ["revisions": ["5d0c1e2", "1.4.2"]]],
        ]
        XCTAssertEqual(KubeGitOpsSource.applied(status), ["5d0c1e2", "1.4.2"], "history's last entry")
        XCTAssertEqual(KubeGitOpsSource.wanted(status), ["77e1a02", "1.4.2"])
        XCTAssertEqual(
            KubeGitOpsSource.applied(["operationState": ["syncResult": ["revision": "5d0c1e2"]]]), ["5d0c1e2"], "no history yet: the operation's")
    }

    // MARK: The tree

    func testAMultiSourceArgoCD3ApplicationsTree() {
        let app: [String: Any] = [
            "kind": "Application", "apiVersion": "argoproj.io/v1alpha1", "metadata": ["name": "acme-api", "namespace": "team-a"],
            "spec": [
                "sources": [
                    ["repoURL": "oci://ghcr.io/acme/charts", "chart": "api", "targetRevision": "1.4.2"],
                    ["repoURL": "git@git.acme.example:acme/shop", "targetRevision": "main", "ref": "values"],
                ],
                "destination": ["server": "https://kubernetes.default.svc", "namespace": "shop"],
            ],
            "status": [
                "sync": ["status": "Synced", "revision": "", "revisions": ["1.4.2", "77e1a02c03f9aa51e8ad0"]],
                "health": ["status": "Healthy"],
                "resourceHealthSource": "appTree",
                "resources": [
                    ["group": "apps", "version": "v1", "kind": "Deployment", "namespace": "shop", "name": "api", "status": "Synced"],
                    ["version": "v1", "kind": "Service", "namespace": "shop", "name": "api", "status": "OutOfSync"],
                ],
            ],
        ]
        let tree = KubeTree.build(.argoApplication, read: KubeTreeRead(root: Self.data(app)))
        let sources = tree.root.children.filter { $0.relation == .source }
        XCTAssertEqual(sources.map(\.status), ["1.4.2", "77e1a02c03f9"], "each source its own revision, never empty")
        XCTAssertEqual(sources.map(\.how), ["api @ 1.4.2", "@ main ref values"])
        XCTAssertEqual(tree.notes.filter { $0 == KubeGitOpsTree.appTreeNote }.count, 1, "said once")
        let managed = tree.root.children.filter { $0.relation == .manages }
        XCTAssertEqual(managed.map(\.health), [.dim, .waiting], "by sync alone: never unknown or unhealthy")
        XCTAssertEqual(managed.map(\.status), ["Synced", "OutOfSync"])

        // Argo CD 2 (or 3 with the health persisted): each resource's own.
        var persisted = app
        var status = app["status"] as! [String: Any]
        status["resourceHealthSource"] = nil
        status["resources"] = [["group": "apps", "version": "v1", "kind": "Deployment", "namespace": "shop", "name": "api", "status": "Synced", "health": ["status": "Degraded"]]]
        persisted["status"] = status
        let old = KubeTree.build(.argoApplication, read: KubeTreeRead(root: Self.data(persisted)))
        XCTAssertFalse(old.notes.contains(KubeGitOpsTree.appTreeNote))
        XCTAssertEqual(old.root.children.filter { $0.relation == .manages }.map(\.health), [.bad])
    }

    // MARK: Owners

    func testTheOwnerAnObjectsMarksName() {
        XCTAssertEqual(
            KubeGitOpsOwner.parse(labels: [:], annotations: ["argocd.argoproj.io/tracking-id": "acme-shop:apps/Deployment:shop/shop-api"]),
            [KubeGitOpsOwner(tool: .argoCD, name: "acme-shop", namespace: nil, mark: .trackingID)])
        XCTAssertEqual(
            KubeGitOpsOwner.tracking("team-a_acme-api:apps/Deployment:shop/api"), KubeGitOpsOwner(tool: .argoCD, name: "acme-api", namespace: "team-a", mark: .trackingID),
            "an app in any namespace")
        XCTAssertEqual(KubeGitOpsOwner.tracking(":apps/Deployment:shop/api"), nil)
        XCTAssertEqual(KubeGitOpsOwner.tracking("no-colon"), nil)
        XCTAssertEqual(
            KubeGitOpsOwner.parse(labels: ["argocd.argoproj.io/instance": "acme-shop"], annotations: [:]).map(\.mark), [.argoInstance])
        let probable = KubeGitOpsOwner.parse(labels: ["app.kubernetes.io/instance": "acme-shop"], annotations: [:])
        XCTAssertEqual(probable, [KubeGitOpsOwner(tool: .argoCD, name: "acme-shop", namespace: nil, mark: .appInstance)])
        XCTAssertEqual(probable.first?.isCertain, false)
        XCTAssertEqual(probable.first?.said, "probably Argo CD Application acme-shop")
        XCTAssertEqual(
            KubeGitOpsOwner.parse(labels: ["app.kubernetes.io/instance": "web"], annotations: ["meta.helm.sh/release-name": "web"]), [],
            "Helm's own install: its instance label names nobody")
        XCTAssertEqual(
            KubeGitOpsOwner.parse(
                labels: ["app.kubernetes.io/instance": "acme-api", "argocd.argoproj.io/instance": "acme-api"],
                annotations: ["argocd.argoproj.io/tracking-id": "acme-shop:apps/Deployment:shop/api"]
            ).map(\.mark), [.trackingID], "the surest mark only")
        let flux = KubeGitOpsOwner.parse(
            labels: [
                "kustomize.toolkit.fluxcd.io/name": "acme-apps", "kustomize.toolkit.fluxcd.io/namespace": "flux-system",
                "helm.toolkit.fluxcd.io/name": "acme-payments", "helm.toolkit.fluxcd.io/namespace": "flux-system", "app.kubernetes.io/instance": "payments",
            ], annotations: [:])
        XCTAssertEqual(flux.map(\.said), ["Kustomization flux-system/acme-apps", "HelmRelease flux-system/acme-payments"], "Helm's instance label under Flux names nobody")
        XCTAssertEqual(
            KubeGitOpsOwner.parse(metadata: ["labels": ["kustomize.toolkit.fluxcd.io/name": "acme-apps"], "annotations": ["other": 1]]).map(\.tool),
            [.fluxKustomize])
    }

    func testTheApplysWarningsTakeTheOwnersMarks() {
        XCTAssertEqual(KubeFieldOwners.managedBy(["metadata": ["labels": ["app.kubernetes.io/instance": "acme-shop"]]]), [.argoCDProbably])
        XCTAssertEqual(
            KubeFieldOwners.managedBy(["metadata": ["annotations": ["argocd.argoproj.io/tracking-id": "acme-shop:apps/Deployment:shop/web"]]]), [.argoCD])
        XCTAssertEqual(
            KubeFieldOwners.managedBy([
                "metadata": ["labels": ["app.kubernetes.io/instance": "web", "app.kubernetes.io/managed-by": "Helm"], "annotations": ["meta.helm.sh/release-name": "web"]]
            ]), [.helm], "a Helm install")
        XCTAssertEqual(
            KubeFieldOwners.warnings([], managedBy: [.argoCDProbably]),
            ["Argo CD probably manages this (its app.kubernetes.io/instance label, which Helm charts set too); your change may be reverted."])
        let argoField = KubeFieldOwners.Owner(manager: "argocd-controller", operation: "Apply", fields: [".spec.replicas"])
        XCTAssertEqual(
            KubeFieldOwners.warnings([argoField], managedBy: [.argoCDProbably]).first, "Argo CD manages this; your change will be reverted.",
            "a field Argo CD owns says it surely")
        XCTAssertEqual(KubeFieldOwners.warnings([argoField], managedBy: [.argoCDProbably]).count, 2, "once, then the field")

        // A tracking id that doesn't parse is still Argo CD's, surely; its instance label then names the app.
        XCTAssertEqual(
            KubeGitOpsOwner.parse(labels: ["argocd.argoproj.io/instance": "acme-shop"], annotations: ["argocd.argoproj.io/tracking-id": "no-colon"]),
            [KubeGitOpsOwner(tool: .argoCD, name: "acme-shop", namespace: nil, mark: .argoInstance)])
        XCTAssertEqual(
            KubeFieldOwners.managedBy([
                "metadata": ["labels": ["app.kubernetes.io/instance": "acme-shop"], "annotations": ["argocd.argoproj.io/tracking-id": ":odd"]]
            ]), [.argoCD], "an odd tracking id: certain, never only probably")
        XCTAssertEqual(KubeFieldOwners.managedBy(["metadata": ["labels": ["argocd.argoproj.io/instance": ""]]]), [.argoCD], "an empty instance label")
        XCTAssertEqual(
            KubeFieldOwners.warnings([], managedBy: KubeFieldOwners.managedBy(["metadata": ["annotations": ["argocd.argoproj.io/tracking-id": "no-colon"]]])),
            ["Argo CD manages this; your change will be reverted."])
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

    /// G0d: Resume on production names what it applies — its source's
    /// revision read after the review, beside the one applied — and, with
    /// prune, has the name typed; a wrong one sends nothing. Off
    /// production nothing more is read.
    func testResumeOnProductionSaysWhatItAppliesAndTypesTheNameWithPrune() async throws {
        api.addCRD(group: "source.toolkit.fluxcd.io", version: "v1", plural: "gitrepositories", kind: "GitRepository", shortNames: ["gitrepo"])
        api.add(
            "gitrepositories.source.toolkit.fluxcd.io", "acme-shop", namespace: "flux-system",
            fields: [
                "spec": ["url": "https://bot:ghp_fake@git.acme.example/acme/shop.git"],
                "status": ["artifact": ["revision": "main@sha1:c03f9aa0123456789abcdef"]],
            ])
        api.setFields(
            "kustomizations.kustomize.toolkit.fluxcd.io", "shop", namespace: "flux-system",
            [
                "spec": ["path": "./deploy", "prune": true, "suspend": true, "sourceRef": ["kind": "GitRepository", "name": "acme-shop"]],
                "status": ["lastAppliedRevision": "main@sha1:a77b0d1e2f3a4b5c6d"],
            ])
        let (page, box) = try await page(current: "fake-prod")
        defer { page.model.hide() }
        await page.model.setProductionWrites(true, for: "fake-prod")
        try await until("on") { page.model.selected?.isWritable == true }
        try await show(page, "ks")
        api.forgetRequests()
        XCTAssertTrue(page.press("p"))
        try await until("asked") { box.confirmations.count == 1 }
        let resume = box.confirmations[0].0
        XCTAssertEqual(resume.verb, .fluxResume)
        XCTAssertEqual(resume.scope, "PRODUCTION · fake-prod · namespace flux-system")
        XCTAssertTrue(
            resume.detail.contains(
                "⚠︎ Resuming applies what gitrepository flux-system/acme-shop holds now: applies main@c03f9aa; a77b0d1 is applied. "
                    + "spec.prune is on: whatever left the source since is deleted from the cluster."), resume.detail)
        XCTAssertFalse(resume.detail.contains("ghp_fake"))
        XCTAssertEqual(resume.typedName, "shop")
        let order = api.requests.map(\.description)
        let review = try XCTUnwrap(order.firstIndex(of: "POST /apis/authorization.k8s.io/v1/selfsubjectaccessreviews"))
        let source = try XCTUnwrap(order.firstIndex(of: "GET /apis/source.toolkit.fluxcd.io/v1/namespaces/flux-system/gitrepositories/acme-shop"))
        XCTAssertLessThan(review, source, "its source read after the review")
        XCTAssertEqual(written(), [])
        box.confirmations[0].1("shp")
        XCTAssertEqual(page.writeStatus, .failed("The name typed wasn't shop: nothing was changed."))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(written(), [], "a wrong name sends nothing")
        XCTAssertTrue(suspended())
        XCTAssertTrue(page.press("p"))
        try await until("asked again") { box.confirmations.count == 2 }
        box.confirmations[1].1("shop")
        try await until("resumed") { !self.suspended() }
        await page.model.setProductionWrites(false, for: "fake-prod")
    }

    func testResumeOffProductionReadsNoSource() async throws {
        api.addCRD(group: "source.toolkit.fluxcd.io", version: "v1", plural: "gitrepositories", kind: "GitRepository", shortNames: ["gitrepo"])
        api.setFields(
            "kustomizations.kustomize.toolkit.fluxcd.io", "shop", namespace: "flux-system",
            ["spec": ["path": "./deploy", "prune": true, "suspend": true, "sourceRef": ["kind": "GitRepository", "name": "acme-shop"]]])
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        try await show(page, "ks")
        api.forgetRequests()
        XCTAssertTrue(page.press("p"))
        try await until("asked") { box.confirmations.count == 1 }
        XCTAssertEqual(box.confirmations[0].0.verb, .fluxResume)
        XCTAssertNil(box.confirmations[0].0.typedName)
        XCTAssertFalse(api.requests.contains { $0.description.contains("gitrepositories") }, "\(api.requests.map(\.description))")
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

    // MARK: G0b — deleting a GitOps object says what goes with it

    private func cascadingApplication() {
        api.setFields(
            "applications.argoproj.io", "shop", namespace: "flux-system",
            [
                "metadata": ["finalizers": ["resources-finalizer.argocd.argoproj.io/background"]],
                "spec": [
                    "destination": ["server": "https://kubernetes.default.svc", "namespace": "shop"],
                    "source": ["repoURL": "https://git.acme.example/shop.git", "helm": ["values": "token: s3cr3t-sentinel"]],
                ],
                "status": [
                    "resources": [
                        ["kind": "Deployment", "group": "apps", "version": "v1", "name": "web", "namespace": "shop"],
                        ["kind": "Service", "version": "v1", "name": "web", "namespace": "payments"],
                    ]
                ],
            ])
    }

    /// ⌫ on an Application with Argo CD's finalizer: reviewed, read, then
    /// asked with its count and its name typed on a local context; a wrong
    /// name sends nothing, the right one one DELETE.
    func testDeletingAnApplicationReadsItThenTypesItsName() async throws {
        cascadingApplication()
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        try await show(page, "app")
        api.forgetRequests()
        XCTAssertTrue(page.deleteKey())
        try await until("asked") { box.confirmations.count == 1 }
        let order = api.requests.map(\.description)
        let review = try XCTUnwrap(order.firstIndex(of: "POST /apis/authorization.k8s.io/v1/selfsubjectaccessreviews"))
        let read = try XCTUnwrap(order.firstIndex(of: "GET /apis/argoproj.io/v1alpha1/namespaces/flux-system/applications/shop"))
        XCTAssertLessThan(review, read, "reviewed before it is read")
        XCTAssertTrue(reviewed().contains(["verb": "delete", "resource": "applications", "group": "argoproj.io", "namespace": "flux-system"]), "\(reviewed())")
        let confirmation = box.confirmations[0].0
        XCTAssertEqual(confirmation.typedName, "shop", "typed off production too")
        XCTAssertTrue(
            confirmation.detail.contains(
                "⚠︎ Argo CD deletes the 2 resources it manages with it, across 2 namespaces (its resources-finalizer.argocd.argoproj.io/background finalizer)."),
            confirmation.detail)
        XCTAssertFalse(confirmation.detail.contains("s3cr3t-sentinel"))
        XCTAssertEqual(written(), [], "nothing before the button")
        box.confirmations[0].1("shp")
        XCTAssertEqual(page.writeStatus, .failed("The name typed wasn't shop: nothing was changed."))
        XCTAssertEqual(written(), [])
        XCTAssertTrue(page.deleteKey())
        try await until("asked again") { box.confirmations.count == 2 }
        box.confirmations[1].1("shop")
        try await until("deleted") { self.written().count == 1 }
        XCTAssertEqual(written().map(\.description), ["DELETE /apis/argoproj.io/v1alpha1/namespaces/flux-system/applications/shop"])
    }

    /// The object's read refused: the worst case said, the name still typed.
    func testADeleteWhoseReadFailsGivesTheWorstCase() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        try await show(page, "ks")
        api.forbidden = ["kustomizations.kustomize.toolkit.fluxcd.io"]
        XCTAssertTrue(page.deleteKey())
        try await until("asked") { box.confirmations.count == 1 }
        let confirmation = box.confirmations[0].0
        XCTAssertEqual(confirmation.typedName, "shop")
        XCTAssertTrue(confirmation.detail.contains("Flux may delete everything it applied with it."), confirmation.detail)
        XCTAssertTrue(confirmation.detail.contains("Couldn't read it ("), confirmation.detail)
        XCTAssertEqual(written(), [])
    }

    /// A namespace's delete counts what its GitOps objects take with it.
    func testDeletingANamespaceCountsItsGitOpsObjects() async throws {
        cascadingApplication()
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        let namespaces = try XCTUnwrap(page.model.discovery?.kind("ns"))
        api.forgetRequests()
        page.write(.delete, on: KubeObjectRef(context: "kind-fake", kind: namespaces, namespace: nil, name: "flux-system"))
        try await until("asked") { box.confirmations.count == 1 }
        let detail = box.confirmations[0].0.detail
        XCTAssertTrue(
            detail.contains(
                "⚠︎ Everything in the namespace is deleted with it. And the Application in it with Argo CD's resources finalizer and the pruning "
                    + "Kustomization in it delete what they manage: 2 objects across 2 namespaces."), detail)
        XCTAssertEqual(box.confirmations[0].0.typedName, "flux-system")
        let paths = api.requests.filter { $0.method == "GET" }.map(\.path)
        XCTAssertTrue(paths.contains("/apis/argoproj.io/v1alpha1/namespaces/flux-system/applications"), "\(paths)")
        XCTAssertTrue(paths.contains("/apis/kustomize.toolkit.fluxcd.io/v1/namespaces/flux-system/kustomizations"), "\(paths)")
        XCTAssertFalse(paths.contains { $0.contains("/configmaps/") || $0.contains("/secrets/") }, "no ConfigMap or Secret read whole: \(paths)")
        XCTAssertEqual(written(), [])
    }
}
