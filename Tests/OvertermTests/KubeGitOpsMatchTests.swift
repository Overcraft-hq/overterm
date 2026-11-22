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
@testable import OvertermActivity

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
        let flux = KubeGitOpsOwner.parse(labels: ["kustomize.toolkit.fluxcd.io/name": "acme-apps", "kustomize.toolkit.fluxcd.io/namespace": "flux-system"], annotations: [:], self: nil)
        let tracked = KubeGitOpsOwner.parse(labels: [:], annotations: ["argocd.argoproj.io/tracking-id": "team-a_acme-web:apps/Deployment:shop/web"], self: nil)
        let helm = KubeGitOpsOwner.parse(labels: ["app.kubernetes.io/instance": "acme-web"], annotations: [:], self: nil)
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
        let asked = try KubeTableReader.read(table, namespace: "shop", kind: .deployments, owners: true)
        XCTAssertEqual(asked.rows.first?.owners.map(\.said), ["Application acme-shop", "Kustomization flux-system/acme-apps"])
        XCTAssertFalse(String(describing: asked.rows).contains(FakeKubeAPI.gitOpsSentinel), "no other annotation is kept")
        XCTAssertEqual(try KubeTableReader.read(table, namespace: "shop").rows.first?.owners, [], "every other list's rows unchanged")
    }
}

// MARK: Apps read from marks (gitops.md 14.2.5, 14.9.2)

/// A, B, C and D against the surveyed shape: app names
/// `<env>-<ns>-<name>-service` that never equal a workload's own, each
/// tracking id naming its own object.
extension KubeGitOpsMatchTests {
    /// A member as a row with Argo CD's marks makes it: its own tracking id.
    private func member(
        _ namespace: String, _ name: String, app: String, kind: KubeMarkedKind = .deployment, image: String? = nil, health: KubeMarkedHealth.Status = .healthy
    ) -> KubeMarkedMember {
        let id = KubeTrackingID.parse("\(app):\(kind.group)/\(kind.kind):\(namespace)/\(name)")!
        return KubeMarkedMember(
            id: KubeMarkedMember.ID(kind: kind, namespace: namespace, name: name), marks: KubeMarkWire(tracking: .own(id)),
            health: KubeMarkedHealth.Verdict(status: health, sentence: health == .healthy ? "2/2 ready" : "1/2 ready", fromRow: true),
            images: image.map { [$0] } ?? ["registry.acme.example/acme/\(name):4.12.0"])
    }

    private func apps(_ members: [KubeMarkedMember]) -> [KubeMarkedApp] { KubeMarkedApps.group(members).apps }

    private func manifests(_ identities: [KubeCheckoutManifests.Identity], folders: Set<String> = []) -> KubeCheckoutManifests.Read {
        var read = KubeCheckoutManifests.Read()
        read.files = identities.count
        read.read = identities.count
        read.documents = identities.count
        read.identities = Set(identities)
        for identity in identities { read.names[identity.namespace ?? "", default: []].insert(identity.name.lowercased()) }
        read.folders = folders
        return read
    }

    private func deployment(_ name: String, in namespace: String?) -> KubeCheckoutManifests.Identity {
        KubeCheckoutManifests.Identity(group: "apps", kind: "Deployment", namespace: namespace, name: name)
    }

    /// A checkout whose remote is `acme/<repo>`.
    private func checkout(repo: String) -> KubeGitOpsMatch.Checkout {
        KubeGitOpsMatch.Checkout(root: root, remotes: [KubeGitOpsMatch.Remote(name: "origin", repo: GitRemoteURL("git@git.acme.example:acme/\(repo).git")!)])
    }

    func testBDescribesItsObjectsNeverOwnsThem() {
        let checkoutAPI = "prod-payments-checkout-api-service"
        let all = apps([
            member("payments", "checkout-api", app: checkoutAPI), member("payments", "checkout-worker", app: checkoutAPI),
            member("ledger", "ledger", app: "prod-ledger-ledger-service"),
        ])
        let read = manifests([deployment("checkout-api", in: "payments"), deployment("other", in: "payments")])
        let listing = KubeGitOpsMatch.markedListing(all, manifests: read, checkout: checkout(repo: "fleet"), namespace: "shop", reason: .notServed)
        let answer = KubeGitOpsMatch.marked(bound: [], listing: listing)
        XCTAssertEqual(answer.found.map(\.app.key.instance), [checkoutAPI])
        XCTAssertEqual(answer.found.first?.whys, [.describes(1, of: 2)])
        XCTAssertFalse(answer.found.contains { $0.whys.contains { if case .owns = $0 { true } else { false } } }, "an identity never owns")
        XCTAssertEqual(answer.found.first?.whys.first?.said, "this checkout's manifests describe 1 of its 2 objects read here")
        XCTAssertFalse(answer.found.first?.whys.first?.said.contains("deploys") ?? true)
        XCTAssertTrue(answer.probably.isEmpty && answer.nothing == nil, "B found: C and D unsaid")
    }

    func testBIsExactOnlyWithItsNamespace() {
        let all = apps([member("payments", "checkout-api", app: "prod-payments-checkout-api-service")])
        let elsewhere = manifests([deployment("checkout-api", in: "payments-staging")])
        let none = KubeGitOpsMatch.marked(bound: [], listing: KubeGitOpsMatch.markedListing(all, manifests: elsewhere, checkout: checkout(repo: "fleet"), namespace: "shop", reason: .notServed))
        XCTAssertTrue(none.found.isEmpty, "another namespace names another object")
        let group = manifests([KubeCheckoutManifests.Identity(group: "extensions", kind: "Deployment", namespace: "payments", name: "checkout-api")])
        let other = KubeGitOpsMatch.marked(bound: [], listing: KubeGitOpsMatch.markedListing(all, manifests: group, checkout: checkout(repo: "fleet"), namespace: "shop", reason: .notServed))
        XCTAssertTrue(other.found.isEmpty, "another group: another object")
    }

    /// `Deployment/api` with no namespace, beside 40 apps each with an
    /// `api`: only the binding's namespace's, and only "probably".
    func testANamespacelessManifestIsProbablyAndOnlyInTheBindingsNamespace() {
        let all = apps((0..<40).map { member("team-\($0)", "api", app: "prod-team-\($0)-api-service") })
        let read = manifests([deployment("api", in: nil)])
        let listing = KubeGitOpsMatch.markedListing(all, manifests: read, checkout: checkout(repo: "fleet"), namespace: "team-3", reason: .notServed)
        let answer = KubeGitOpsMatch.marked(bound: [], listing: listing)
        XCTAssertTrue(answer.found.isEmpty, "never described without its namespace")
        XCTAssertEqual(answer.probably.map(\.app.key.instance), ["prod-team-3-api-service"], "the binding's namespace only")
        XCTAssertEqual(answer.probably.first?.whys, [.probably("a manifest names Deployment api without a namespace; this app's is in team-3, the bound one")])
        XCTAssertTrue(answer.probably.allSatisfy(\.probable))
        XCTAssertNil(answer.tooMany)
    }

    func testAnAppsNameLosesItsEnvironmentNamespaceAndService() {
        func stem(_ name: String, _ namespace: String) -> String {
            KubeGitOpsMatch.stem(apps([member(namespace, "x", app: name)]).first!)
        }
        XCTAssertEqual(stem("prod-team-3-acme-svc-003-service", "team-3"), "acme-svc-003")
        XCTAssertEqual(stem("prod-team-3-acme-svc-006", "team-3"), "acme-svc-006")
        XCTAssertEqual(stem("prod-acme-svc-009", "team-3"), "prod-acme-svc-009", "no namespace in it: as it is")
        XCTAssertEqual(stem("team-3_prod-team-3-checkout-api-service", "team-3"), "checkout-api", "an app in any namespace: its name")
        XCTAssertEqual(stem("team-3-api", "team-3"), "team-3-api", "nothing before the namespace: as it is")
        XCTAssertEqual(KubeGitOpsMatch.imageParts("registry.acme.example/acme/api:4.1@sha256:abc"), ["acme", "api"])
        XCTAssertEqual(KubeGitOpsMatch.imageParts("nginx:1.27"), ["nginx"])
        XCTAssertEqual(KubeGitOpsMatch.imageParts("localhost:5000/acme/api"), ["acme", "api"])
    }

    /// C and D, said "probably" with what matched — only when A and B found nothing.
    func testCAndDAreProbably() {
        let byName = "prod-payments-checkout-api-service"
        let byImage = "prod-shop-storefront-service"
        let all = apps([
            member("payments", "acme-checkout", app: byName), member("shop", "web", app: byImage, image: "registry.acme.example/acme/shop:2.0.1"),
            member("ledger", "ledger", app: "prod-ledger-ledger-service"),
        ])
        let read = KubeCheckoutManifests.Read()
        let listing = KubeGitOpsMatch.markedListing(all, manifests: read, checkout: checkout(repo: "checkout-api"), namespace: "payments", reason: .notServed)
        var answer = KubeGitOpsMatch.marked(bound: [], listing: listing)
        XCTAssertEqual(answer.probably.map(\.app.key.instance), [byName], "the image names acme/shop, not this repository")
        XCTAssertEqual(answer.probably.first?.whys, [.probably("its name, read as checkout-api, is the repository's")])
        XCTAssertEqual(answer.probably.first?.whys.first?.said, "probably: its name, read as checkout-api, is the repository's")
        let shop = KubeGitOpsMatch.markedListing(all, manifests: read, checkout: checkout(repo: "shop"), namespace: "shop", reason: .notServed)
        answer = KubeGitOpsMatch.marked(bound: [], listing: shop)
        XCTAssertEqual(answer.probably.map(\.app.key.instance), [byImage])
        XCTAssertEqual(answer.probably.first?.whys, [.probably("its image …/shop:2.0.1 is named as this repository")])
        // A found the app: C and D aren't said at all.
        let bound = apps([member("shop", "web", app: byImage)])
        answer = KubeGitOpsMatch.marked(bound: [(bound[0], [KubeWorkloadRef(kind: .deployment, name: "web")])], listing: listing)
        XCTAssertEqual(answer.found.map(\.app.key.instance), [byImage])
        XCTAssertTrue(answer.probably.isEmpty && answer.tooMany == nil && answer.nothing == nil)
        // A folder under apps/, a manifest's name.
        let folder = KubeGitOpsMatch.markedListing(
            all, manifests: manifests([], folders: ["checkout-api"]), checkout: checkout(repo: "fleet"), namespace: "payments", reason: .notServed)
        XCTAssertEqual(
            KubeGitOpsMatch.marked(bound: [], listing: folder).probably.first?.whys.first, .probably("its name, read as checkout-api, is a folder's under apps/, deploy/, k8s/, charts/ or manifests/"))
        // A manifest's name, in the namespace it names; another namespace's says nothing.
        let named = KubeGitOpsMatch.markedListing(
            all, manifests: manifests([KubeCheckoutManifests.Identity(group: "", kind: "Service", namespace: "payments", name: "checkout-api")]),
            checkout: checkout(repo: "fleet"), namespace: "shop", reason: .notServed)
        XCTAssertEqual(KubeGitOpsMatch.marked(bound: [], listing: named).probably.first?.whys.first, .probably("its name, read as checkout-api, is a manifest's here"))
        let elsewhere = KubeGitOpsMatch.markedListing(
            all, manifests: manifests([KubeCheckoutManifests.Identity(group: "", kind: "Service", namespace: "ledger", name: "checkout-api")]),
            checkout: checkout(repo: "fleet"), namespace: "shop", reason: .notServed)
        XCTAssertTrue(KubeGitOpsMatch.marked(bound: [], listing: elsewhere).probably.isEmpty)
    }

    func testMoreThanThreeByNameAreTooManyToTell() {
        let all = apps((0..<4).map { member("team-\($0)", "web-\($0)", app: "prod-team-\($0)-api-service") })
        let listing = KubeGitOpsMatch.markedListing(all, manifests: KubeCheckoutManifests.Read(), checkout: checkout(repo: "api"), namespace: "shop", reason: .notServed)
        let answer = KubeGitOpsMatch.marked(bound: [], listing: listing)
        XCTAssertEqual(answer.tooMany, "4 apps by name or image: too many to tell")
        XCTAssertTrue(answer.probably.isEmpty, "none listed")
        XCTAssertNil(answer.nothing)
        let three = KubeGitOpsMatch.markedListing(Array(all.prefix(3)), manifests: KubeCheckoutManifests.Read(), checkout: checkout(repo: "api"), namespace: "shop", reason: .notServed)
        XCTAssertEqual(KubeGitOpsMatch.marked(bound: [], listing: three).probably.count, 3)
    }

    // MARK: C and D: the bound namespace first (gitops.md 14.9.4)

    /// One service deployed into several namespaces — `checkout` in each,
    /// never two within one —, as the surveyed spokes' apps with a
    /// Deployment share a name.
    private func shared(_ namespaces: [String]) -> [KubeMarkedApp] {
        apps(namespaces.map { member($0, "checkout-api", app: "prod-\($0)-checkout-service") })
    }

    /// C, D and B with no namespace against `apps`, bound in `namespace`,
    /// the checkout `acme/checkout`.
    private func matched(_ apps: [KubeMarkedApp], manifests read: KubeCheckoutManifests.Read = KubeCheckoutManifests.Read(), bound namespace: String)
        -> KubeGitOpsMatch.MarkedAnswer
    {
        let listing = KubeGitOpsMatch.markedListing(apps, manifests: read, checkout: checkout(repo: "checkout"), namespace: namespace, reason: .notServed)
        return KubeGitOpsMatch.marked(bound: [], listing: listing)
    }

    /// (a) Bound in acme-food: its app said alone, the two elsewhere only counted.
    func testByNameTheBoundNamespacesAppIsSaidAloneTheOthersCounted() {
        let answer = matched(shared(["acme-food", "acme-market", "acme-water"]), bound: "acme-food")
        XCTAssertTrue(answer.found.isEmpty)
        XCTAssertEqual(answer.probably.map(\.app.key.instance), ["prod-acme-food-checkout-service"])
        XCTAssertEqual(answer.probably.first?.whys, [.probably("its name, read as checkout, is the repository's")])
        XCTAssertTrue(answer.probably.allSatisfy(\.probable))
        XCTAssertEqual(answer.elsewhere, "2 more by name or image in other namespaces: acme-market, acme-water")
        XCTAssertNil(answer.tooMany)
        XCTAssertNil(answer.nothing, "something said: never nothing found")
    }

    /// (b) Five of one name, bound in one of their namespaces: one said,
    /// four counted — never "too many to tell", which counts only those
    /// said. Past five namespaces named, "…"; one, "another namespace".
    func testByNameElsewhereIsCountedNeverTooManyToTell() {
        let five = ["acme-books", "acme-food", "acme-games", "acme-market", "acme-water"]
        let answer = matched(shared(five), bound: "acme-food")
        XCTAssertEqual(answer.probably.map(\.app.key.instance), ["prod-acme-food-checkout-service"])
        XCTAssertNil(answer.tooMany, "the four elsewhere are counted, never too many")
        XCTAssertEqual(answer.elsewhere, "4 more by name or image in other namespaces: acme-books, acme-games, acme-market, acme-water")
        XCTAssertEqual(
            matched(shared(five + ["acme-pets", "acme-tools", "acme-toys"]), bound: "acme-food").elsewhere,
            "7 more by name or image in other namespaces: acme-books, acme-games, acme-market, acme-pets, acme-tools, …")
        XCTAssertEqual(matched(shared(["acme-food", "acme-market"]), bound: "acme-food").elsewhere, "1 more by name or image in another namespace: acme-market")
    }

    /// (c) Bound in none of their namespaces: all said as before — three
    /// listed, four too many to tell —, nothing counted apart.
    func testByNameWithNoneInTheBoundNamespaceAllAreSaid() {
        let three = matched(shared(["acme-food", "acme-market", "acme-water"]), bound: "acme-shop")
        XCTAssertEqual(
            three.probably.map(\.app.key.instance), ["prod-acme-food-checkout-service", "prod-acme-market-checkout-service", "prod-acme-water-checkout-service"])
        XCTAssertNil(three.tooMany)
        XCTAssertNil(three.elsewhere)
        let four = matched(shared(["acme-food", "acme-games", "acme-market", "acme-water"]), bound: "acme-shop")
        XCTAssertEqual(four.tooMany, "4 apps by name or image: too many to tell")
        XCTAssertTrue(four.probably.isEmpty, "none listed")
        XCTAssertNil(four.elsewhere)
    }

    /// (d) Two apps of one stem in the bound namespace are both said; four
    /// there are too many to tell, the one elsewhere still counted.
    func testByNameSeveralInTheBoundNamespaceAreSaidThenTooMany() {
        let two = matched(
            apps([member("acme-food", "checkout-web", app: "prod-acme-food-checkout"), member("acme-food", "checkout-api", app: "prod-acme-food-checkout-service")]),
            bound: "acme-food")
        XCTAssertEqual(two.probably.map(\.app.key.instance), ["prod-acme-food-checkout", "prod-acme-food-checkout-service"])
        XCTAssertEqual(two.probably.map { $0.whys.first?.said }, Array(repeating: "probably: its name, read as checkout, is the repository's", count: 2))
        XCTAssertNil(two.tooMany)
        XCTAssertNil(two.elsewhere)
        let four = matched(
            apps([
                member("acme-food", "checkout-web", app: "prod-acme-food-checkout"), member("acme-food", "checkout-api", app: "prod-acme-food-checkout-service"),
                member("acme-food", "checkout-worker", app: "stage-acme-food-checkout-service"),
                member("acme-food", "checkout-cron", app: "acme-food_prod-acme-food-checkout"),
                member("acme-market", "checkout-api", app: "prod-acme-market-checkout-service"),
            ]), bound: "acme-food")
        XCTAssertEqual(four.tooMany, "4 apps by name or image: too many to tell")
        XCTAssertTrue(four.probably.isEmpty, "none listed")
        XCTAssertEqual(four.elsewhere, "1 more by name or image in another namespace: acme-market")
    }

    /// (e) A or B found an app: C and D aren't said — neither listed nor counted.
    func testByNameIsUnsaidOnceAOrBFound() {
        let all = shared(["acme-food", "acme-market", "acme-water"])
        let listing = KubeGitOpsMatch.markedListing(all, manifests: KubeCheckoutManifests.Read(), checkout: checkout(repo: "checkout"), namespace: "acme-food", reason: .notServed)
        let bound = apps([member("acme-food", "checkout-api", app: "prod-acme-food-checkout-service")])
        let byA = KubeGitOpsMatch.marked(bound: [(bound[0], [KubeWorkloadRef(kind: .deployment, name: "checkout-api")])], listing: listing)
        XCTAssertEqual(byA.found.map(\.app.key.instance), ["prod-acme-food-checkout-service"])
        XCTAssertTrue(byA.probably.isEmpty)
        XCTAssertNil(byA.tooMany)
        XCTAssertNil(byA.elsewhere)
        let byB = matched(all, manifests: manifests([deployment("checkout-api", in: "acme-market")]), bound: "acme-food")
        XCTAssertEqual(byB.found.map(\.app.key.instance), ["prod-acme-market-checkout-service"])
        XCTAssertEqual(byB.found.first?.whys, [.describes(1, of: 1)])
        XCTAssertTrue(byB.probably.isEmpty)
        XCTAssertNil(byB.tooMany)
        XCTAssertNil(byB.elsewhere)
    }

    /// Nothing found says what was compared, and what couldn't be — never
    /// that nothing deploys the checkout.
    func testNothingFoundSaysWhatWasCompared() {
        let all = apps([member("ledger", "ledger", app: "prod-ledger-ledger-service")])
        var read = manifests([deployment("api", in: "shop"), deployment("web", in: "shop"), deployment("db", in: "shop")])
        read.templates = 37
        read.prefixed = 1
        read.files = 41
        let listing = KubeGitOpsMatch.markedListing(
            all, manifests: read, checkout: checkout(repo: "fleet"), namespace: "shop", reason: .notServed,
            notes: ["Deployments refused in 3 namespaces (a, b, c)"])
        let answer = KubeGitOpsMatch.marked(bound: [], listing: listing)
        XCTAssertEqual(
            answer.nothing,
            "No marked app matched: 3 manifests compared, 37 Helm templates not rendered, 1 kustomization's namePrefix or nameSuffix not applied, Deployments refused in 3 namespaces (a, b, c)")
        for word in ["not deployed", "doesn't deploy", "nothing deploys"] { XCTAssertFalse(answer.nothing?.contains(word) ?? false, word) }
        XCTAssertNil(KubeGitOpsMatch.marked(bound: [], listing: nil).nothing, "B not run: nothing said")
        var empty = KubeCheckoutManifests.Read()
        empty.files = 0
        let noFiles = KubeGitOpsMatch.markedListing(all, manifests: empty, checkout: checkout(repo: "fleet"), namespace: "shop", reason: .notServed)
        XCTAssertEqual(KubeGitOpsMatch.marked(bound: [], listing: noFiles).nothing, "No marked app matched: no committed manifest in this checkout")
    }

    /// A and B on one app: it owns its bound workloads and the manifests describe it.
    func testABesideB() {
        let app = "prod-shop-shop-api-service"
        let listed = apps([member("shop", "shop-api", app: app), member("shop-jobs", "shop-sync", app: app)])
        let bound = apps([member("shop", "shop-api", app: app)])
        let listing = KubeGitOpsMatch.markedListing(listed, manifests: manifests([deployment("shop-api", in: "shop")]), checkout: checkout(repo: "shop"), namespace: "shop", reason: .notServed)
        let answer = KubeGitOpsMatch.marked(bound: [(bound[0], [KubeWorkloadRef(kind: .deployment, name: "shop-api")])], listing: listing)
        XCTAssertEqual(answer.found.count, 1)
        XCTAssertEqual(answer.found.first?.whys, [.owns([KubeWorkloadRef(kind: .deployment, name: "shop-api")]), .describes(1, of: 2)])
        XCTAssertTrue(answer.found.first?.bound == true)
        XCTAssertEqual(listing.members[KubeTrackingID.AppKey(installation: "", instance: app)]?.count, 2, "its members elsewhere, for the rail's line")
    }

    func testWhoseHealthAndWhereItStandsAreSaid() {
        let now = Date()
        XCTAssertEqual(KubeGitOpsMatch.MarkedScope.bound(2, elsewhere: nil).said(now: now), "health of the 2 objects bound here; other namespaces not read")
        XCTAssertEqual(KubeGitOpsMatch.MarkedScope.bound(1, elsewhere: [:]).said(now: now), "health of the 1 object bound here")
        XCTAssertEqual(
            KubeGitOpsMatch.MarkedScope.bound(1, elsewhere: ["shop": 1, "jobs": 2]).said(now: now), "health of the 1 object bound here; 2 more in jobs and 1 in shop not counted")
        // Its app's Rollout beside it; a listing cut or refused somewhere: a floor, said.
        XCTAssertEqual(KubeGitOpsMatch.MarkedScope.bound(1, rollouts: 1, elsewhere: [:]).said(now: now), "health of the 1 object bound here with its app's Argo Rollout")
        XCTAssertEqual(
            KubeGitOpsMatch.MarkedScope.bound(2, rollouts: 2, elsewhere: nil).said(now: now),
            "health of the 2 objects bound here with its app's 2 Argo Rollouts; other namespaces not read")
        XCTAssertEqual(
            KubeGitOpsMatch.MarkedScope.bound(1, elsewhere: ["jobs": 1], whole: false).said(now: now),
            "health of the 1 object bound here; 1 more in jobs not counted; other namespaces not all read")
        XCTAssertEqual(KubeGitOpsMatch.MarkedScope.bound(1, elsewhere: [:], whole: false).said(now: now), "health of the 1 object bound here; other namespaces not all read")
        XCTAssertEqual(KubeGitOpsMatch.MarkedScope.listed(3).said(now: now), "health of its 3 workloads, from their rows")
        XCTAssertEqual(KubeGitOpsMatch.MarkedScope.section(now.addingTimeInterval(-40)).said(now: now), "as the GitOps section read it 40s ago")
        XCTAssertEqual(KubeGitOpsMatch.MarkedPlace.reason(.notServed).said(context: "fake-dev"), "Argo CD runs in another cluster — not in your kubeconfig")
        XCTAssertEqual(KubeGitOpsMatch.MarkedPlace.notFound.said(context: "fake-dev"), "its Application wasn't found in argocd; Argo CD's namespace here is unknown")
        for place in [KubeGitOpsMatch.MarkedPlace.reason(.undiscovered), .reason(.noApplications), .reason(.forbidden), .absent, .notFound, .refused, .unread] {
            XCTAssertFalse(place.said(context: "fake-dev").contains("another cluster"), "only Applications not served say another cluster")
        }
        XCTAssertEqual(KubeGitOpsMatch.marksLine(.notServed, context: "fake-dev", namespace: "shop"), "Argo CD isn't in fake-dev; read from the marks on shop's workloads")
        XCTAssertEqual(
            KubeGitOpsMatch.marksLine(.undiscovered, context: "fake-dev", namespace: "shop"), "Couldn't tell whether Argo CD runs in fake-dev: argoproj.io didn't answer discovery")
        XCTAssertEqual(
            KubeGitOpsMatch.marksLine(.noApplications, context: "fake-dev", namespace: nil),
            "Argo CD's Applications aren't in fake-dev; read from the marks on the cluster's workloads", "only B, C or D: the cluster's")
    }

    /// A Deployment scaled to 0 (14.12's second consequence): its own where
    /// Argo Rollouts aren't served, or were read whole with none of its
    /// app's; where they weren't read, Unknown as a member — never Ready on
    /// it — and ranked with the others by Argo CD's rules: a Degraded
    /// sibling still ranks the app with Failed and is named first (D-7).
    func testADeploymentScaledToZeroWhereRolloutsArentReadIsUnknownRankedWithTheRest() {
        var zero = member("shop", "web", app: "prod-shop-web-service")
        zero.health = KubeMarkedHealth.Verdict(status: .healthy, sentence: "scaled to 0", fromRow: true, scaledToZero: true)
        let alone = apps([zero])[0]
        XCTAssertEqual(KubeGitOpsMatch.health(alone, rollouts: .notServed).state, .ready)
        XCTAssertEqual(KubeGitOpsMatch.health(alone, rollouts: .read).state, .ready, "read whole, no Rollout of its app: its 0 is its own")
        let unread = KubeGitOpsMatch.health(alone, rollouts: .unread("shop's Rollouts not read yet"))
        XCTAssertEqual(unread.state, .unknown)
        XCTAssertEqual(unread.word, "Unknown")
        XCTAssertEqual(unread.why, "scaled to 0; an Argo Rollout may run it (shop's Rollouts not read yet) · Deployment web")

        // A Degraded sibling: the app ranks with Failed, its word Unknown, the Degraded named first.
        var stalled = member("shop", "web-api", app: "prod-shop-web-service")
        stalled.health = KubeMarkedHealth.Verdict(status: .degraded, sentence: "rollout stalled (ProgressDeadlineExceeded)")
        let both = apps([zero, stalled])[0]
        let ranked = KubeGitOpsMatch.health(both, rollouts: .unread("shop's Rollouts can't be read (forbidden)"))
        XCTAssertEqual(ranked.state, .failed, "ranked by its worst known member")
        XCTAssertEqual(ranked.word, "Unknown", "Argo CD's word for the app")
        XCTAssertEqual(ranked.why, "rollout stalled (ProgressDeadlineExceeded) · Deployment web-api · and 1 more")
        XCTAssertEqual(ranked.causes.map(\.status), [.degraded, .unknown])
        XCTAssertEqual(ranked.causes.map(\.member.name), ["web-api", "web"])
        XCTAssertTrue(ranked.notes.contains("Argo CD's rule: Unknown"), "\(ranked.notes)")

        // Its Rollout read: the Deployment scaled by it, the app's health the Rollout's phase.
        var rollout = member("shop", "web", app: "prod-shop-web-service", kind: .rollout)
        rollout.health = KubeMarkedHealth.Verdict(status: .degraded, sentence: "rollout degraded")
        rollout.workloadRef = "web"
        let run = apps([zero, rollout])[0]
        for read in [KubeGitOpsMatch.RolloutsRead.read, .unread("shop's Rollouts read in part")] {
            let health = KubeGitOpsMatch.health(run, rollouts: read)
            XCTAssertEqual(health.state, .failed)
            XCTAssertEqual(health.why, "rollout degraded · Rollout web", "the Deployment's 0 is no cause")
        }
        XCTAssertEqual(KubeMarkedHealth.member(zero, in: run)?.sentence, KubeMarkedHealth.scaledByRollout)
    }

    // MARK: The checkout's manifests (option B's side)

    private func write(_ text: String, _ path: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Several documents a file; a kustomization names nothing and its
    /// prefix is counted; a Helm template, a test folder and a link out of
    /// the checkout aren't read; nothing past the four keys is walked.
    func testTheManifestsFourKeysAndWhatIsntRead() throws {
        try write(
            """
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: checkout-api
              namespace: payments
              labels: {app: checkout-api}
            spec:
              template:
                spec:
                  containers: [{name: app, image: "registry.acme.example/acme/checkout-api:4.12.0", env: [{name: DB_PASSWORD, value: SENTINEL}]}]
            ---
            apiVersion: v1
            kind: Service
            metadata:
              name: "checkout-api"
            ---
            # a comment only
            ---
            apiVersion: v1
            kind: List
            metadata: {name: everything}
            ---
            apiVersion: apps/v1
            kind: Deployment
            metadata: &meta
              name: aliased
            ---
            apiVersion: apps/v1
            kind: Deployment
            metadata: *meta
            """, "apps/checkout-api/deploy.yaml")
        try write("apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nnamePrefix: prod-\nresources: [deploy.yaml]\n", "apps/checkout-api/kustomization.yaml")
        try write("nameSuffix: -v2\nresources: []\n", "deploy/kustomization.yml")
        try write("apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: {{ .Release.Name }}\n", "charts/checkout/templates/deployment.yaml")
        try write("apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: test-only\n  namespace: payments\n", "tests/fixture.yaml")
        try write("not: [valid", "broken.yaml")
        // A link out of the checkout, and a folder linked out.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("gitops-manifests-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: secret-ledger\n  namespace: ledger\n".write(
            to: outside.appendingPathComponent("ledger.yaml"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("ledger.yaml"), withDestinationURL: outside.appendingPathComponent("ledger.yaml"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        let paths = [
            "apps/checkout-api/deploy.yaml", "apps/checkout-api/kustomization.yaml", "deploy/kustomization.yml", "charts/checkout/templates/deployment.yaml", "tests/fixture.yaml",
            "broken.yaml", "ledger.yaml", "linked/ledger.yaml",
        ]
        let read = KubeCheckoutManifests.read(root, paths: paths)
        XCTAssertEqual(
            read.identities,
            [
                KubeCheckoutManifests.Identity(group: "apps", kind: "Deployment", namespace: "payments", name: "checkout-api"),
                KubeCheckoutManifests.Identity(group: "", kind: "Service", namespace: nil, name: "checkout-api"),
                KubeCheckoutManifests.Identity(group: "apps", kind: "Deployment", namespace: nil, name: "aliased"),
            ])
        XCTAssertEqual(read.documents, 3, "the List and the aliased metadata left out")
        XCTAssertEqual(read.prefixed, 2, "kustomize's own file, with or without its apiVersion and kind")
        XCTAssertEqual(read.templates, 1)
        XCTAssertEqual(read.skipped, 1)
        XCTAssertEqual(read.links, 2, "a link, and a folder linked out")
        XCTAssertEqual(read.unreadable, 1)
        XCTAssertEqual(read.files, paths.count)
        XCTAssertEqual(read.folders, ["checkout-api", "checkout"])
        XCTAssertEqual(read.names, ["payments": ["checkout-api"], "": ["checkout-api", "aliased"]])
        XCTAssertFalse(String(describing: read).contains("SENTINEL") || String(describing: read).contains("secret-ledger"))
    }

    /// `{{` decides nothing alone (14.2.5): a rendered file whose
    /// PrometheusRule quotes `{{ $labels.pod }}` parses, and both its
    /// documents are compared; only a document whose four keys hold `{{` is
    /// left out, its file counted a template, as is one naming nothing that
    /// holds `{{` (a whole `{{ toYaml … }}`); a file the grammar can't read
    /// that holds `{{` is a template, one without is unreadable.
    func testATemplateIsOnlyADocumentWhoseFourKeysAreTemplated() throws {
        try write(
            """
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: acme-api
              namespace: payments
            ---
            apiVersion: monitoring.coreos.com/v1
            kind: PrometheusRule
            metadata:
              name: acme-api-alerts
              namespace: payments
              annotations:
                summary: "{{ $labels.pod }} restarts"
            spec:
              groups:
                - name: acme-api
                  rules:
                    - alert: AcmeAPIRestarts
                      annotations:
                        description: "{{ $labels.pod }} restarted {{ $value }} times"
            """, "rendered/payments.yaml")
        try write(
            """
            apiVersion: v1
            kind: Service
            metadata:
              name: "{{ .Release.Name }}-api"
              namespace: payments
            ---
            apiVersion: v1
            kind: Service
            metadata:
              name: acme-web
              namespace: payments
            """, "rendered/quoted.yaml")
        try write("{{- if .Values.enabled }}\napiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: {{ include \"acme.name\" . }}\n{{- end }}\n", "charts/acme/templates/deployment.yaml")
        try write("apiVersion: v1\nkind: ConfigMap\nmetadata: {{ include \"acme.metadata\" . }}\n", "charts/acme/templates/configmap.yaml")
        try write("{{ toYaml .Values.extraObjects }}\n", "charts/acme/templates/extra.yaml")
        try write("not: [valid", "broken.yaml")
        let read = KubeCheckoutManifests.read(
            root,
            paths: [
                "rendered/payments.yaml", "rendered/quoted.yaml", "charts/acme/templates/deployment.yaml", "charts/acme/templates/configmap.yaml",
                "charts/acme/templates/extra.yaml", "broken.yaml",
            ])
        XCTAssertEqual(
            read.identities,
            [
                KubeCheckoutManifests.Identity(group: "apps", kind: "Deployment", namespace: "payments", name: "acme-api"),
                KubeCheckoutManifests.Identity(group: "monitoring.coreos.com", kind: "PrometheusRule", namespace: "payments", name: "acme-api-alerts"),
                KubeCheckoutManifests.Identity(group: "", kind: "Service", namespace: "payments", name: "acme-web"),
            ])
        XCTAssertEqual(read.documents, 3)
        XCTAssertEqual(read.templates, 4, "the templated Service's file, and the chart's three templates")
        XCTAssertEqual(read.unreadable, 1, "broken YAML, no template in it")
        XCTAssertEqual(read.read, 6)
    }

    /// The bounds: a file over 256 KB isn't read; 32 MB in all, then the rest said.
    func testTheManifestsBounds() throws {
        let big = String(repeating: "#", count: 300 << 10)
        try write(big, "big.yaml")
        // 129 templates of 256 KB: 32 MB is reached before the last.
        let template = "{{ .Values.x }}\n" + String(repeating: "x", count: (256 << 10) - 16)
        var paths = ["big.yaml"]
        for index in 0..<129 {
            let path = "t/\(index).yaml"
            try write(template, path)
            paths.append(path)
        }
        let read = KubeCheckoutManifests.read(root, paths: paths)
        XCTAssertEqual(read.unreadable, 1, "over 256 KB")
        XCTAssertEqual(read.templates, 128)
        XCTAssertEqual(read.cut, "32 MB of the checkout's manifests read")
        let few = KubeCheckoutManifests.read(root, paths: paths, bounds: KubeCheckoutManifests.Bounds(files: 3))
        XCTAssertEqual(few.cut, "3 of 130 manifest files read")
    }
}
