import Foundation
import XCTest

@testable import Overterm

/// The summary's decode is its allow-list (docs/design/kubernetes/
/// gitops.md, 2.4, 8.1, decision 15): every struct's keys against a
/// reviewed list — a struct that declares `values` fails here —, and the
/// sentinel, put in every carrier Argo CD and Flux have, never in a
/// summary, a row's text, a hover or `KubeHealth.kept`'s output.
final class KubeGitOpsWireTests: XCTestCase {
    /// Reviewed: what each struct may read. A change here is a review.
    static let reviewed: [String: [String]] = [
        "Object": ["apiVersion", "kind", "metadata", "spec", "status"],
        "List": ["metadata", "items"],
        "ListMetadata": ["continue", "remainingItemCount", "resourceVersion"],
        "Metadata": [
            "name", "namespace", "uid", "resourceVersion", "generation", "creationTimestamp", "deletionTimestamp", "labels", "annotations", "ownerReferences",
            "managedFields",
        ],
        "Labels": [
            "argocd.argoproj.io/instance", "app.kubernetes.io/instance", "kustomize.toolkit.fluxcd.io/name", "kustomize.toolkit.fluxcd.io/namespace",
            "helm.toolkit.fluxcd.io/name", "helm.toolkit.fluxcd.io/namespace",
        ],
        "Annotations": ["argocd.argoproj.io/tracking-id", "meta.helm.sh/release-name", "argocd.argoproj.io/manifest-generate-paths"],
        "OwnerReference": ["apiVersion", "kind", "name", "controller"],
        "ManagedField": ["manager", "operation", "time", "fieldsV1"],
        "FieldsV1": ["f:spec", "f:suspend"],
        "Spec": [
            "source", "sources", "destination", "project", "syncPolicy", "sourceHydrator", "suspend", "interval", "retryInterval", "path", "prune",
            "targetNamespace", "sourceRef", "chartRef", "chart", "dependsOn", "kubeConfig", "url", "ref", "endpoint",
        ],
        "ArgoSource": ["repoURL", "path", "chart", "targetRevision", "ref"],
        "Destination": ["server", "name", "namespace"],
        "SyncPolicy": ["automated", "retry"],
        "Automated": ["enabled", "prune", "selfHeal"],
        "Retry": ["limit"],
        "Hydrator": ["drySource"],
        "DrySource": ["repoURL", "path", "targetRevision"],
        "Reference": ["apiVersion", "kind", "name", "namespace"],
        "Chart": ["spec"],
        "ChartSpec": ["chart", "version", "sourceRef"],
        "KubeConfig": ["secretRef", "configMapRef"],
        "Named": ["name"],
        "GitRef": ["branch", "tag", "semver", "name", "commit"],
        "Status": [
            "sync", "health", "operationState", "history", "reconciledAt", "resourceHealthSource", "resources", "summary", "conditions", "observedGeneration",
            "lastAppliedRevision", "lastAttemptedRevision", "lastAttemptedRevisionDigest", "inventory", "artifact",
        ],
        "Sync": ["status", "revision", "revisions"],
        "Health": ["status", "message"],
        "Condition": ["type", "status", "reason", "message", "lastTransitionTime"],
        "OperationState": ["phase", "message", "startedAt", "finishedAt", "retryCount", "operation", "syncResult"],
        "Operation": ["initiatedBy"],
        "InitiatedBy": ["username", "automated"],
        "SyncResult": ["revision", "revisions", "resources"],
        "SyncResource": ["kind", "name", "namespace", "status", "message"],
        "HistoryEntry": ["revision", "revisions", "deployedAt", "chartName", "chartVersion", "status", "lastDeployed"],
        "ResourceEntry": ["namespace", "status", "requiresPruning"],
        "Summary": ["images"],
        "Inventory": ["entries"],
        "InventoryEntry": ["id"],
        "Artifact": ["revision", "lastUpdateTime", "metadata"],
        "ArtifactMetadata": ["org.opencontainers.image.source", "org.opencontainers.image.revision"],
        // The detail's (G3): history's revisions and times, the resources' identities and states.
        "Detail": ["status"],
        "DetailStatus": ["history", "resources", "operationState"],
        "DetailOperationState": ["syncResult"],
        "DetailSyncResult": ["resources"],
        "DetailResource": ["group", "version", "kind", "namespace", "name", "status", "requiresPruning", "health"],
        // The rail's (G5): what an Application manages, by name only.
        "Managed": ["status"],
        "ManagedStatus": ["resources"],
        "ManagedEntry": ["group", "kind", "namespace", "name"],
    ]

    /// Never declared, anywhere: what holds a value, a manifest or a copy of the source.
    static let forbidden: Set<String> = [
        "values", "valuesObject", "valuesFrom", "parameters", "fileParameters", "extVars", "tlas", "env", "plugin", "helm", "kustomize", "directory",
        "patches", "patchesStrategicMerge", "patchesJson6902", "postBuild", "substitute", "substituteFrom", "elements", "generators", "template",
        "manifests", "comparedTo", "data", "stringData", "kubectl.kubernetes.io/last-applied-configuration", "sync.source", "fieldsV1.values",
    ]

    func testEveryStructDeclaresOnlyTheReviewedKeys() {
        let declared = KubeGitOpsWire.declared
        XCTAssertEqual(Set(declared.keys), Set(Self.reviewed.keys), "a new struct is reviewed here")
        for (name, keys) in declared {
            XCTAssertEqual(keys, Self.reviewed[name], name)
            XCTAssertTrue(Set(keys).isDisjoint(with: Self.forbidden), "\(name) declares \(Set(keys).intersection(Self.forbidden))")
        }
        // Copies of a source never have a home: no struct of status declares `source(s)`.
        for name in ["Status", "Sync", "OperationState", "Operation", "SyncResult", "HistoryEntry", "DetailStatus", "DetailOperationState", "DetailSyncResult"] {
            XCTAssertFalse(declared[name]?.contains("source") ?? true, name)
            XCTAssertFalse(declared[name]?.contains("sources") ?? true, name)
        }
    }

    /// The sentinel, in every carrier: never in a summary (its every field,
    /// reflected), a row's words, the hover's, `kept`'s output.
    func testTheSentinelIsNeverRead() throws {
        let s = FakeKubeAPI.gitOpsSentinel
        let now = Date()
        let fake = FakeKubeAPI(socket: nil)
        fake.addGitOpsFixtures(now: now)
        var objects: [KubeGitOpsObject] = []
        var wholes: [[String: Any]] = []
        for kind in KubeGitOpsSummary.summarised {
            for name in fake.names(kind.fullName) {
                for namespace in ["argocd", "team-a", "flux-system"] {
                    guard let whole = fake.object(kind.fullName, name, namespace: namespace) else { continue }
                    wholes.append(whole)
                    let summary = try XCTUnwrap(try KubeGitOpsSummary.object(JSONSerialization.data(withJSONObject: whole), readAt: now))
                    objects.append(summary)
                }
            }
        }
        // The fixtures do carry it, and a URL's token.
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: wholes), as: UTF8.self)
        XCTAssertTrue(raw.contains(s))
        XCTAssertTrue(raw.contains("ghp_fake"))
        // A message quoting a Secret, the sentinel in the operation's and the source's copies: all present raw.
        for carrier in ["comparedTo", "manifests", "valuesObject", "extVars", "tlas", "postBuild", "elements", "last-applied-configuration", "kind: Secret"] {
            XCTAssertTrue(raw.contains(carrier), carrier)
        }

        let ranked = KubeGitOpsSummary.ranked(objects, now: now)
        for object in ranked {
            let reflected = String(reflecting: object)
            XCTAssertFalse(reflected.contains(s), "\(object.kind) \(object.ref): \(reflected)")
            XCTAssertFalse(reflected.contains("ghp_fake"), "\(object.kind) \(object.ref): a URL's userinfo")
            let row = [
                object.why, object.lastError ?? "", KubeGitOpsRevision.column(object), object.sources.map(\.said).joined(separator: " "),
                object.tags.map { $0.said(now: now) }.joined(separator: " "),
            ]
            .joined(separator: " ")
            XCTAssertFalse(row.contains(s), row)
            let hover = object.conditions.compactMap(\.message).joined(separator: "\n") + (object.operation?.message ?? "")
            XCTAssertFalse(hover.contains(s), hover)
            XCTAssertFalse(hover.contains("ghp_fake"), hover)
        }
        let kept = wholes.map(KubeHealth.kept)
        let keptText = String(decoding: try JSONSerialization.data(withJSONObject: kept), as: UTF8.self)
        XCTAssertFalse(keptText.contains(s), "the Overview's net")

        // What is said instead.
        let api = try XCTUnwrap(ranked.first { $0.kind == "Application" && $0.ref.name == "acme-api" })
        XCTAssertEqual(
            api.operation?.message,
            "one or more objects failed to apply, reason: fetching https://git.acme.example/acme/shop.git failed: … manifest omitted",
            "cut at the manifest, the URL without its token")
        let cron = try XCTUnwrap(ranked.first { $0.ref.name == "acme-cron" })
        XCTAssertEqual(cron.lastError, "BuildFailed: kustomize build failed: accumulating resources: … manifest omitted")
        let fleet = try XCTUnwrap(ranked.first { $0.ref.name == "acme-fleet" })
        XCTAssertEqual(fleet.sources.first?.repoURL, "https://git.acme.example/acme/shop.git", "a source's URL without its token")
        XCTAssertEqual(fleet.tracks, "main")
        let broken = try XCTUnwrap(ranked.first { $0.ref.name == "acme-broken" })
        XCTAssertFalse(broken.lastError?.contains("ghp_fake") ?? true)
        XCTAssertEqual(try XCTUnwrap(ranked.first { $0.ref.name == "acme-manifests" }).artifactOrigin?.repo.description, "git.acme.example/acme/shop")
    }

    /// An Application's destination server loses its userinfo as it is
    /// decoded (5.2: a URL's userinfo, anywhere): never in the summary,
    /// the destination or the remote the row shows.
    func testADestinationServerLosesItsUserinfo() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "apiVersion": "argoproj.io/v1alpha1", "kind": "Application", "metadata": ["name": "acme-remote", "namespace": "argocd"],
            "spec": ["destination": ["server": "https://deploy:ghp_fakeDestination@kube.acme.example:6443", "namespace": "shop"]],
            "status": ["sync": ["status": "Synced"], "health": ["status": "Healthy"]],
        ])
        XCTAssertEqual(try KubeGitOpsWire.object(data).spec?.destination?.server, "https://kube.acme.example:6443")
        let summary = try XCTUnwrap(try KubeGitOpsSummary.object(data, readAt: Date()))
        XCTAssertEqual(summary.destination?.cluster, "https://kube.acme.example:6443")
        XCTAssertEqual(summary.remote, "https://kube.acme.example:6443")
        XCTAssertFalse(String(reflecting: summary).contains("ghp_fakeDestination"))
    }

    /// History: only its ends are decoded — Argo CD's last, a HelmRelease's first.
    func testOnlyTheEndsOfHistoryAreRead() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "apiVersion": "argoproj.io/v1alpha1", "kind": "Application", "metadata": ["name": "a", "namespace": "argocd"],
            "status": [
                "history": [["revision": "1111111"], ["revision": 42, "source": ["helm": ["values": "x"]]], NSNull(), ["revision": "3333333"]],
                "sync": ["status": "Synced", "revision": "3333333"],
            ],
        ])
        let wire = try KubeGitOpsWire.object(data)
        XCTAssertEqual(wire.status?.historyFirst?.revision, "1111111")
        XCTAssertEqual(wire.status?.historyLast?.revision, "3333333", "a malformed entry and a null in between are skipped")
        let summary = try XCTUnwrap(KubeGitOpsObject(wire, readAt: Date()))
        XCTAssertEqual(summary.revisions.applied, ["3333333"])
    }

    /// A field of an unexpected type is dropped, never the whole object.
    func testAnOddFieldDropsOnlyItself() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "apiVersion": "kustomize.toolkit.fluxcd.io/v1", "kind": "Kustomization", "metadata": ["name": "k", "namespace": "flux-system"],
            "spec": ["interval": 5, "path": "./apps", "prune": "yes", "sourceRef": ["kind": "GitRepository", "name": "fleet"]],
            "status": ["conditions": [["type": "Ready", "status": "True"]]],
        ])
        let summary = try XCTUnwrap(try KubeGitOpsSummary.object(data, readAt: Date()))
        XCTAssertNil(summary.interval)
        XCTAssertFalse(summary.prune)
        XCTAssertEqual(summary.sourceRef?.name, "fleet")
        XCTAssertEqual(summary.condition("Ready")?.status, "True")
    }

    func testDurationsAndTimes() {
        XCTAssertEqual(KubeGitOpsTime.duration("10m"), 600)
        XCTAssertEqual(KubeGitOpsTime.duration("1h0m0s"), 3600)
        XCTAssertEqual(KubeGitOpsTime.duration("1m30s"), 90)
        XCTAssertEqual(KubeGitOpsTime.duration("500ms"), 0.5)
        XCTAssertEqual(KubeGitOpsTime.duration("1.5h"), 5400)
        XCTAssertNil(KubeGitOpsTime.duration("soon"))
        XCTAssertNil(KubeGitOpsTime.duration(""))
        XCTAssertEqual(KubeGitOpsTime.date("2026-11-10T09:00:00Z"), Date(timeIntervalSince1970: 1_794_301_200))
        XCTAssertEqual(KubeGitOpsTime.date("2026-11-10T09:00:00.5Z"), Date(timeIntervalSince1970: 1_794_301_200.5))
        XCTAssertNil(KubeGitOpsTime.date("yesterday"))
    }
}
