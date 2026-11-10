import XCTest

@testable import Overterm

/// Which Argo CD and Flux objects deploy a checkout (docs/design/
/// kubernetes/gitops.md, 4.2, 8.1): the owners from each mark, the
/// repository and its path checked in a checkout of the test's own (a path
/// not on the branch, `..`, an absolute one, a NUL byte and a symlink out
/// of it refused), a Flux source across namespaces, a HelmRelease's chart
/// path and its `chartRef`, an OCI artifact's origin, a `ref:` values
/// source, what each tracks, "not in this cluster", the image fallback.
/// Pure: the only disk read is the path's one look.
final class KubeGitOpsMatchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gitops-match-\(UUID().uuidString)", isDirectory: true)
        for path in ["deploy/fake-dev", "charts/shop", "apps"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("gitops-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private var checkout: KubeGitOpsMatch.Checkout {
        KubeGitOpsMatch.Checkout(
            root: root, remotes: [KubeGitOpsMatch.Remote(name: "origin", repo: GitRemoteURL("git@git.acme.example:acme/shop.git")!)],
            branch: "fix/orders", defaults: ["origin": "main"])
    }

    private func object(_ kind: String, _ name: String, namespace: String, spec: [String: Any], status: [String: Any] = [:]) -> KubeGitOpsObject {
        let apiVersion: String =
            switch kind {
            case "Application": "argoproj.io/v1alpha1"
            case "Kustomization": "kustomize.toolkit.fluxcd.io/v1"
            case "HelmRelease": "helm.toolkit.fluxcd.io/v2"
            default: "source.toolkit.fluxcd.io/v1"
            }
        let json: [String: Any] = ["apiVersion": apiVersion, "kind": kind, "metadata": ["name": name, "namespace": namespace], "spec": spec, "status": status]
        return KubeGitOpsSummary.object(json, readAt: Date())!
    }

    private func application(_ source: [String: Any]) -> KubeGitOpsObject {
        object("Application", "acme-shop", namespace: "argocd", spec: ["source": source, "destination": ["namespace": "shop"]])
    }

    private func objects(_ list: [KubeGitOpsObject]) -> [KubeGitOpsObject.Key: KubeGitOpsObject] {
        Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: (a)

    func testAnApplicationsRepositoryAndPath() {
        let app = application(["repoURL": "https://bot:ghp_fake@git.acme.example/acme/shop.git", "path": "./deploy/fake-dev/", "targetRevision": "HEAD"])
        let why = KubeGitOpsMatch.source(app, in: checkout, objects: [:])
        XCTAssertEqual(why, .repoAndPath("deploy/fake-dev", source: nil))
        XCTAssertEqual(why?.said, "deploy/fake-dev")
        XCTAssertEqual(KubeGitOpsMatch.tracks(app, why: why, in: checkout, objects: [:]), "tracks main; this branch is fix/orders", "HEAD is the remote's default branch")
    }

    func testAPathNotOnThisBranchOrOutOfTheCheckout() {
        let missing = application(["repoURL": "https://git.acme.example/acme/shop", "path": "apps/web", "targetRevision": "main"])
        XCTAssertEqual(KubeGitOpsMatch.source(missing, in: checkout, objects: [:]), .repoOnly("path apps/web is not on this branch", source: nil))
        for path in ["../outside", "/etc", "apps/\u{0}x", "escape"] {
            let app = application(["repoURL": "https://git.acme.example/acme/shop", "path": path])
            guard case .repoOnly(let why, _) = KubeGitOpsMatch.source(app, in: checkout, objects: [:]) else { return XCTFail(path) }
            XCTAssertFalse(why.isEmpty, path)
            XCTAssertFalse(why.contains("not on this branch"), "\(path): refused, not missing — \(why)")
        }
        let root = application(["repoURL": "ssh://git@git.acme.example:22/acme/shop.git", "path": "."])
        XCTAssertEqual(KubeGitOpsMatch.source(root, in: checkout, objects: [:]), .repoAndPath("", source: nil))
        XCTAssertEqual(KubeGitOpsMatch.Why.repoAndPath("", source: nil).said, "the repository's root")
    }

    func testAnotherRepositoryOrAChartNeverMatches() {
        XCTAssertNil(KubeGitOpsMatch.source(application(["repoURL": "https://git.acme.example/acme/fleet.git", "path": "deploy/fake-dev"]), in: checkout, objects: [:]))
        XCTAssertNil(KubeGitOpsMatch.source(application(["repoURL": "oci://git.acme.example/acme/shop", "chart": "shop"]), in: checkout, objects: [:]))
        XCTAssertNil(
            KubeGitOpsMatch.source(application(["repoURL": "https://git.acme.example/acme/shop", "chart": "shop", "targetRevision": "1.0.0"]), in: checkout, objects: [:]),
            "a chart's source names a Helm repository, not git")
    }

    func testAValuesSourceIsTheRepositoryOnly() {
        let app = object(
            "Application", "acme-api", namespace: "team-a",
            spec: [
                "sources": [
                    ["repoURL": "oci://ghcr.io/acme/charts", "chart": "api", "targetRevision": "1.5.0"],
                    ["repoURL": "git@git.acme.example:acme/shop", "targetRevision": "main", "ref": "values"],
                ]
            ])
        let why = KubeGitOpsMatch.source(app, in: checkout, objects: [:])
        XCTAssertEqual(why, .repoOnly("values from this repository", source: 1))
        XCTAssertEqual(KubeGitOpsMatch.tracks(app, why: why, in: checkout, objects: [:]), "tracks main; this branch is fix/orders")
    }

    func testAKustomizationThroughItsGitRepositoryInAnotherNamespace() {
        let source = object(
            "GitRepository", "acme-shop", namespace: "sources", spec: ["url": "https://user:tok@git.acme.example/acme/shop.git", "ref": ["branch": "fix/orders"]])
        let ks = object(
            "Kustomization", "acme-apps", namespace: "flux-system",
            spec: ["path": "./deploy/fake-dev", "sourceRef": ["kind": "GitRepository", "name": "acme-shop", "namespace": "sources"]])
        let all = objects([source, ks])
        XCTAssertEqual(KubeGitOpsMatch.source(ks, in: checkout, objects: all), .repoAndPath("deploy/fake-dev", source: nil))
        XCTAssertEqual(KubeGitOpsMatch.tracks(ks, why: nil, in: checkout, objects: all), "tracks fix/orders", "the same branch: said once")
        // Its source in its own namespace (none said) is another object: no match.
        let local = object("Kustomization", "acme-local", namespace: "flux-system", spec: ["path": "./x", "sourceRef": ["kind": "GitRepository", "name": "acme-shop"]])
        XCTAssertNil(KubeGitOpsMatch.source(local, in: checkout, objects: all))
        // Flux's default branch.
        let plain = object("GitRepository", "acme-plain", namespace: "flux-system", spec: ["url": "https://git.acme.example/acme/shop"])
        let byPlain = object("Kustomization", "acme-p", namespace: "flux-system", spec: ["path": "apps", "sourceRef": ["kind": "GitRepository", "name": "acme-plain"]])
        XCTAssertEqual(KubeGitOpsMatch.tracks(byPlain, why: nil, in: checkout, objects: objects([plain, byPlain])), "tracks master; this branch is fix/orders")
    }

    func testAHelmReleasesChartPathAndItsChartRef() {
        let source = object("GitRepository", "acme-shop", namespace: "flux-system", spec: ["url": "https://git.acme.example/acme/shop"])
        let byChart = object(
            "HelmRelease", "shop", namespace: "flux-system",
            spec: ["chart": ["spec": ["chart": "./charts/shop", "sourceRef": ["kind": "GitRepository", "name": "acme-shop"]]]])
        XCTAssertEqual(KubeGitOpsMatch.source(byChart, in: checkout, objects: objects([source, byChart])), .repoAndPath("charts/shop", source: nil))
        let chart = object(
            "HelmChart", "flux-system-shop", namespace: "flux-system", spec: ["chart": "charts/shop", "sourceRef": ["kind": "GitRepository", "name": "acme-shop"]])
        let byRef = object("HelmRelease", "shop2", namespace: "flux-system", spec: ["chartRef": ["kind": "HelmChart", "name": "flux-system-shop"]])
        XCTAssertEqual(KubeGitOpsMatch.source(byRef, in: checkout, objects: objects([source, chart, byRef])), .repoAndPath("charts/shop", source: nil))
        XCTAssertNil(KubeGitOpsMatch.source(byRef, in: checkout, objects: objects([chart, byRef])), "its source not read: no match")
    }

    func testAnOCIArtifactsOrigin() {
        let oci = object(
            "OCIRepository", "acme-manifests", namespace: "flux-system", spec: ["url": "oci://ghcr.io/acme/manifests"],
            status: ["artifact": ["revision": "latest@sha256:abc", "metadata": ["org.opencontainers.image.source": "https://git.acme.example/acme/shop"]]])
        let ks = object("Kustomization", "acme-oci", namespace: "flux-system", spec: ["path": "./", "sourceRef": ["kind": "OCIRepository", "name": "acme-manifests"]])
        XCTAssertEqual(KubeGitOpsMatch.source(ks, in: checkout, objects: objects([oci, ks])), .repoOnly("an OCI artifact built from this repository", source: nil))
        XCTAssertTrue(KubeGitOpsMatch.sourceMatches(oci, in: checkout))
        let other = object("OCIRepository", "x", namespace: "flux-system", spec: ["url": "oci://ghcr.io/acme/x"])
        XCTAssertFalse(KubeGitOpsMatch.sourceMatches(other, in: checkout), "an OCI URL never matches a checkout by itself")
    }

    // MARK: (b)

    func testTheOwnersFromEachMark() {
        let web = KubeWorkloadRef(kind: .deployment, name: "web")
        let api = KubeWorkloadRef(kind: .deployment, name: "api")
        let flux = KubeGitOpsOwner.parse(labels: ["kustomize.toolkit.fluxcd.io/name": "acme-apps", "kustomize.toolkit.fluxcd.io/namespace": "flux-system"], annotations: [:])
        let tracked = KubeGitOpsOwner.parse(labels: [:], annotations: ["argocd.argoproj.io/tracking-id": "team-a_acme-web:apps/Deployment:shop/web"])
        let helm = KubeGitOpsOwner.parse(labels: ["app.kubernetes.io/instance": "acme-web"], annotations: [:])
        let owners = KubeGitOpsMatch.owners([(web, flux + tracked), (api, flux + helm)])
        XCTAssertEqual(owners.map(\.owner.said), ["Application team-a/acme-web", "Kustomization flux-system/acme-apps", "probably Argo CD Application acme-web"])
        XCTAssertEqual(owners[1].workloads, [web, api])
        XCTAssertEqual(KubeGitOpsMatch.key(of: owners[0].owner).description, "Application team-a/acme-web")
        XCTAssertEqual(KubeGitOpsMatch.key(of: owners[2].owner).description, "Application argocd/acme-web", "Argo CD's own namespace when nothing says")
        XCTAssertEqual(KubeGitOpsMatch.Why.owns([web, api]).said, "owns Deployment/web, Deployment/api")
    }

    func testNotInThisClusterAndHelmsLabelDropped() {
        let web = KubeWorkloadRef(kind: .deployment, name: "web")
        let sure = KubeGitOpsOwner(tool: .argoCD, name: "acme-shop", namespace: nil, mark: .trackingID)
        let helm = KubeGitOpsOwner(tool: .argoCD, name: "acme-web", namespace: nil, mark: .appInstance)
        let found = KubeGitOpsMatch.found(
            owned: [(sure, [web], .absent), (helm, [web], .absent)], objects: [:], workloads: [(web, [])], checkout: checkout, context: "kind-fake")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.whys, [.notInCluster("managed by Argo CD Application acme-shop (not in kind-fake)")])
        // Refused or failed: nothing said of the cluster — the problem line says it.
        let refused = KubeGitOpsMatch.found(owned: [(sure, [web], .unreadable)], objects: [:], workloads: [(web, [])], checkout: checkout, context: "kind-fake")
        XCTAssertEqual(refused, [])
    }

    func testFoundOwnersThenSourcesEachOnce() {
        let web = KubeWorkloadRef(kind: .deployment, name: "shop-api")
        let source = object("GitRepository", "acme-fleet", namespace: "flux-system", spec: ["url": "https://git.acme.example/acme/shop", "ref": ["branch": "main"]])
        let ks = object(
            "Kustomization", "acme-apps", namespace: "flux-system", spec: ["path": "./deploy/fake-dev", "sourceRef": ["kind": "GitRepository", "name": "acme-fleet"]])
        let cron = object("Kustomization", "acme-cron", namespace: "flux-system", spec: ["path": "./apps/cron", "sourceRef": ["kind": "GitRepository", "name": "acme-fleet"]])
        let owner = KubeGitOpsOwner(tool: .fluxKustomize, name: "acme-apps", namespace: "flux-system", mark: .fluxLabels)
        let found = KubeGitOpsMatch.found(
            owned: [(owner, [web], .present)], objects: objects([source, ks, cron]), workloads: [(web, [])], checkout: checkout, context: "kind-fake")
        XCTAssertEqual(found.map(\.key.description), ["Kustomization flux-system/acme-apps", "Kustomization flux-system/acme-cron"])
        XCTAssertEqual(found[0].whys, [.owns([web]), .repoAndPath("deploy/fake-dev", source: nil)])
        XCTAssertEqual(found[0].tracks, "tracks main; this branch is fix/orders")
        XCTAssertEqual(found[1].whys, [.repoOnly("path apps/cron is not on this branch", source: nil)])
    }

    func testTheImageFallbackAndWhatAnApplicationManages() {
        let web = KubeWorkloadRef(kind: .deployment, name: "shop-api")
        let app = object(
            "Application", "acme-other", namespace: "argocd", spec: ["source": ["repoURL": "https://git.acme.example/acme/fleet", "path": "x"]],
            status: ["summary": ["images": ["ghcr.io/acme/shop-api:a77b0d1"]]])
        XCTAssertEqual(KubeGitOpsMatch.sameImage(app, workloads: [(web, ["ghcr.io/acme/shop-api:a77b0d1"])]), [web])
        XCTAssertEqual(KubeGitOpsMatch.sameImage(app, workloads: [(web, ["ghcr.io/acme/shop-api:other"])]), [])
        let found = KubeGitOpsMatch.found(owned: [], objects: objects([app]), workloads: [(web, ["ghcr.io/acme/shop-api:a77b0d1"])], checkout: checkout, context: "c")
        XCTAssertEqual(found.first?.whys.first?.said, "probably deploys shop-api (same image)")
        let managed = [KubeGitOpsWire.ManagedEntry(group: "apps", kind: "Deployment", namespace: "shop", name: "shop-api")]
        XCTAssertTrue(KubeGitOpsMatch.manages(managed, web, namespace: "shop"))
        XCTAssertFalse(KubeGitOpsMatch.manages(managed, web, namespace: "other"))
        XCTAssertFalse(KubeGitOpsMatch.manages(managed, KubeWorkloadRef(kind: .statefulSet, name: "shop-api"), namespace: "shop"))
    }

    func testTheManagedDecodeKeepsNamesOnly() throws {
        let body: [String: Any] = [
            "status": [
                "resources": [["group": "apps", "version": "v1", "kind": "Deployment", "namespace": "shop", "name": "shop-api", "status": "Synced", "health": ["message": FakeKubeAPI.gitOpsSentinel]]]
            ]
        ]
        let managed = try KubeGitOpsWire.managed(JSONSerialization.data(withJSONObject: body))
        XCTAssertEqual(managed.status?.resources, [KubeGitOpsWire.ManagedEntry(group: "apps", kind: "Deployment", namespace: "shop", name: "shop-api")])
        XCTAssertFalse(String(describing: managed).contains(FakeKubeAPI.gitOpsSentinel))
    }

    func testARowSaysItsOwnersOnlyWhereAsked() throws {
        let table: [String: Any] = [
            "kind": "Table", "columnDefinitions": [["name": "Name", "type": "string", "format": "name"]],
            "rows": [
                [
                    "cells": ["shop-api"],
                    "object": [
                        "metadata": [
                            "name": "shop-api", "namespace": "shop",
                            "labels": ["kustomize.toolkit.fluxcd.io/name": "acme-apps", "kustomize.toolkit.fluxcd.io/namespace": "flux-system"],
                            "annotations": ["argocd.argoproj.io/tracking-id": "acme-shop:apps/Deployment:shop/shop-api", "other": FakeKubeAPI.gitOpsSentinel],
                        ]
                    ],
                ]
            ],
        ]
        let asked = try KubeTableReader.read(table, namespace: "shop", owners: true)
        XCTAssertEqual(asked.rows.first?.owners.map(\.said), ["Application acme-shop", "Kustomization flux-system/acme-apps"])
        XCTAssertFalse(String(describing: asked.rows).contains(FakeKubeAPI.gitOpsSentinel), "no other annotation is kept")
        XCTAssertEqual(try KubeTableReader.read(table, namespace: "shop").rows.first?.owners, [], "every other list's rows unchanged")
    }
}
