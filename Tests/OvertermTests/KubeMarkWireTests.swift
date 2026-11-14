import XCTest

@testable import Overterm

/// What a row keeps of Argo CD's marks, and what a GET keeps of a workload
/// (docs/design/kubernetes/gitops.md, 14.4.3): the allow-lists — a row
/// whose last-applied copy, env, args and other annotations carry SENTINEL
/// keeps none of it, nor a condition message past 300 characters; the
/// tracking id checked against the kind listed; "last change applied by
/// Argo CD" only from Argo CD's own managers. The data is the spoke's
/// shape (`<env>-<ns>-<name>-service` apps) with fictional names.
final class KubeMarkWireTests: XCTestCase {
    static let sentinel = "SENTINEL"

    /// A Deployment's Metadata row, as the API server embeds it: a
    /// `PartialObjectMetadata` whose annotations, labels and managed fields
    /// carry SENTINEL wherever the allow-list mustn't look.
    static func sentinelRow(name: String = "acme-checkout", namespace: String = "acme-pay") -> [String: Any] {
        let lastApplied =
            #"{"apiVersion":"apps/v1","kind":"Deployment","spec":{"template":{"spec":{"containers":[{"env":[{"name":"DB_PASSWORD","value":"SENTINEL"}]}]}}}}"#
        let metadata: [String: Any] = [
            "name": name, "namespace": namespace, "generation": 7, "resourceVersion": "4711", "creationTimestamp": "2026-11-01T10:00:00Z",
            "labels": ["app": "SENTINEL-label", "app.kubernetes.io/name": "acme-checkout", "team": "SENTINEL"],
            "annotations": [
                "argocd.argoproj.io/tracking-id": "prod-acme-pay-checkout-service:apps/Deployment:\(namespace)/\(name)",
                "kubectl.kubernetes.io/last-applied-configuration": lastApplied, "deployment.kubernetes.io/revision": "SENTINEL",
                "acme.example/owner": "SENTINEL", "argocd.argoproj.io/sync-wave": "2", "argocd.argoproj.io/sync-options": "ServerSideApply=true",
                "link.argocd.argoproj.io/runbook": "https://runbooks.acme.example/checkout",
            ],
            "managedFields": [
                [
                    "manager": "argocd-controller", "operation": "Apply", "time": "2026-11-10T08:00:00Z",
                    "fieldsV1": ["f:spec": ["f:template": ["f:spec": ["f:containers": ["SENTINEL": [String: Any]()]]]]],
                ],
                ["manager": "kube-controller-manager", "operation": "Update", "subresource": "status", "time": "2026-11-12T09:00:00Z", "fieldsV1": ["SENTINEL": 1]],
            ],
        ]
        return [
            "kind": "Table", "apiVersion": "meta.k8s.io/v1",
            "columnDefinitions": [
                ["name": "Name", "type": "string", "format": "name"], ["name": "Ready", "type": "string"], ["name": "Up-to-date", "type": "integer"],
                ["name": "Available", "type": "integer"], ["name": "Images", "type": "string", "priority": 1],
            ],
            "rows": [
                [
                    "cells": [name, "2/2", 2, 2, "registry.acme.example/pay/checkout:4.12.0"],
                    "object": ["kind": "PartialObjectMetadata", "apiVersion": "meta.k8s.io/v1", "metadata": metadata],
                ]
            ],
        ]
    }

    func testARowKeepsArgoCDsMarksAndNothingElse() throws {
        let table = try KubeTableReader.read(Self.sentinelRow(), namespace: nil, kind: .deployments, marks: true)
        let row = try XCTUnwrap(table.rows.first)
        let marks = try XCTUnwrap(row.marks)
        XCTAssertEqual(
            marks.tracking,
            .own(KubeTrackingID(instance: "prod-acme-pay-checkout-service", group: "apps", kind: "Deployment", namespace: "acme-pay", name: "acme-checkout")))
        XCTAssertEqual(marks.generation, 7)
        XCTAssertEqual(marks.resourceVersion, "4711")
        XCTAssertEqual(marks.syncWave, "2")
        XCTAssertEqual(marks.syncOptions, "ServerSideApply=true")
        XCTAssertEqual(marks.links, [KubeMarkWire.Link(name: "runbook", value: "https://runbooks.acme.example/checkout")])
        XCTAssertEqual(marks.argoChanged, try Date("2026-11-10T08:00:00Z", strategy: .iso8601))
        XCTAssertEqual(marks.lastChanged, try Date("2026-11-12T09:00:00Z", strategy: .iso8601))
        XCTAssertEqual(row.owners, [], "marks alone: owners only when asked")
        for kept in [String(reflecting: row), String(reflecting: table)] {
            XCTAssertFalse(kept.contains(Self.sentinel), "the row kept something outside the allow-list: \(kept)")
        }
        XCTAssertFalse(String(reflecting: row).contains("last-applied"))
    }

    func testWithoutMarksAskedARowKeepsNone() throws {
        let table = try KubeTableReader.read(Self.sentinelRow(), namespace: nil, kind: .deployments)
        XCTAssertNil(table.rows.first?.marks, "unused by any list until a list asks")
        XCTAssertEqual(KubeClient.includeObject(.deployments, .namespace("acme-pay")), "None")
        XCTAssertEqual(KubeListOptions(marks: true).marks, true)
    }

    func testARowsMarkIsCheckedAgainstTheKindListed() throws {
        // The same Deployment mark read on its ReplicaSet (the controller copies it).
        let table = try KubeTableReader.read(Self.sentinelRow(name: "acme-checkout"), namespace: nil, kind: .replicaSets, marks: true)
        guard case .copied(let id) = table.rows.first?.marks?.tracking else { return XCTFail("a ReplicaSet's copy is a copy") }
        XCTAssertEqual(id.kind, "Deployment")
        // Its namespace from the row: the same name elsewhere is a copy too.
        var moved = Self.sentinelRow()
        var rows = moved["rows"] as! [[String: Any]]
        var object = rows[0]["object"] as! [String: Any]
        var metadata = object["metadata"] as! [String: Any]
        metadata["namespace"] = "acme-other"
        object["metadata"] = metadata
        rows[0]["object"] = object
        moved["rows"] = rows
        guard case .copied = try KubeTableReader.read(moved, namespace: nil, kind: .deployments, marks: true).rows.first?.marks?.tracking else {
            return XCTFail("another namespace's object")
        }
    }

    func testMarksAreCheckedAndCapped() {
        let identity = KubeTrackingID.Identity(group: "apps", kind: "Deployment", namespace: "acme-pay", name: "acme-checkout")
        let marks = KubeMarkWire.read(
            metadata: [
                "labels": ["argocd.argoproj.io/instance": "Not_Valid_", "app.kubernetes.io/instance": "acme-checkout"],
                "annotations": [
                    "argocd.argoproj.io/tracking-id": "acme:anything", "argocd.argoproj.io/installation-id": "Hub B!",
                    "helm.sh/hook": "pre-install", "argocd.argoproj.io/ignore-healthcheck": "TRUE",
                    "argocd.argoproj.io/sync-options": String(repeating: "x", count: 2000) + "\u{7}",
                    "meta.helm.sh/release-name": "acme-checkout",
                ]
                .merging((0..<8).map { ("link.argocd.argoproj.io/l\($0)", "https://acme.example/\($0)\n") }, uniquingKeysWith: { $1 }),
                "deletionTimestamp": "2026-11-14T00:00:00Z",
            ], self: identity)
        XCTAssertEqual(marks?.tracking, .unparsed)
        XCTAssertEqual(marks?.installationUnparsed, true)
        XCTAssertNil(marks?.installation)
        XCTAssertNil(marks?.argoInstance, "an instance label Argo CD wouldn't write")
        XCTAssertEqual(marks?.appInstance, "acme-checkout")
        XCTAssertEqual(marks?.helmRelease, true)
        XCTAssertEqual(marks?.hook, "pre-install", "Helm's hook when Argo CD's isn't there")
        XCTAssertEqual(marks?.ignoreHealthcheck, true)
        XCTAssertEqual(marks?.syncOptions?.count, KubeMarkWire.hintCap)
        XCTAssertEqual(marks?.links.count, KubeMarkWire.linksKept)
        XCTAssertEqual(marks?.links.first?.value, "https://acme.example/0", "no control character kept")
        XCTAssertEqual(marks?.deleting, true)
        XCTAssertNil(KubeMarkWire.read(metadata: nil, self: identity), "no metadata, no marks")
    }

    /// Argo CD's last change is only ever its own managers': a person's
    /// `kubectl edit`, `kubectl scale` or an HPA writing later never moves
    /// it, and with no Argo CD manager there is no time at all.
    func testLastChangeAppliedIsArgoCDsOwnManagersOnly() throws {
        let identity = KubeTrackingID.Identity(group: "apps", kind: "Deployment", namespace: "acme-pay", name: "acme-checkout")
        func marks(_ fields: [(String, String)]) -> KubeMarkWire? {
            KubeMarkWire.read(
                metadata: ["managedFields": fields.map { ["manager": $0.0, "operation": "Update", "time": $0.1] }], self: identity)
        }
        let argo = try Date("2026-11-01T00:00:00Z", strategy: .iso8601)
        let later = marks([
            ("argocd-application-controller", "2026-11-01T00:00:00Z"), ("kubectl-edit", "2026-11-05T00:00:00Z"),
            ("kube-controller-manager", "2026-11-06T00:00:00Z"), ("kubectl-client-side-apply", "2026-11-07T00:00:00Z"),
        ])
        XCTAssertEqual(later?.argoChanged, argo, "a later edit or HPA write is never Argo CD's")
        XCTAssertEqual(later?.lastChanged, try Date("2026-11-07T00:00:00Z", strategy: .iso8601))
        XCTAssertNil(marks([("kubectl-edit", "2026-11-05T00:00:00Z"), ("acme-operator", "2026-11-06T00:00:00Z")])?.argoChanged, "no Argo CD manager: no time")
        XCTAssertEqual(marks([("argocd-controller", "2026-11-01T00:00:00Z")])?.argoChanged, argo, "server-side apply's manager")
    }

    /// A GET's workload keeps what Argo CD's rule reads: never env, args,
    /// annotations, the last-applied copy, or a message past 300.
    func testAWorkloadKeepsWhatItsRuleReadsAndNothingElse() throws {
        let message = "progress deadline exceeded token=" + "glp" + "at-abcdefghij0123456789 " + String(repeating: "m", count: 400) + Self.sentinel
        let object: [String: Any] = [
            "apiVersion": "apps/v1", "kind": "Deployment",
            "metadata": [
                "name": "acme-checkout", "namespace": "acme-pay", "generation": 3, "resourceVersion": "9",
                "annotations": ["kubectl.kubernetes.io/last-applied-configuration": Self.sentinel, "acme.example/x": Self.sentinel],
                "labels": ["team": Self.sentinel],
            ],
            "spec": [
                "replicas": 1, "strategy": ["type": "RollingUpdate", "rollingUpdate": ["maxSurge": Self.sentinel]],
                "selector": ["matchLabels": ["app": Self.sentinel]],
                "template": [
                    "metadata": ["annotations": ["x": Self.sentinel]],
                    "spec": [
                        "containers": [
                            [
                                "name": "api", "image": "registry.acme.example/pay/checkout:4.12.0", "env": [["name": "TOKEN", "value": Self.sentinel]],
                                "args": [Self.sentinel], "command": [Self.sentinel],
                            ]
                        ],
                        "volumes": [["name": Self.sentinel]],
                    ],
                ],
            ],
            "status": [
                "observedGeneration": 3, "replicas": 2, "updatedReplicas": 1, "readyReplicas": 1, "availableReplicas": 1,
                "conditions": [
                    ["type": "Progressing", "status": "False", "reason": "ProgressDeadlineExceeded", "lastTransitionTime": "2026-11-14T09:00:00Z", "message": message]
                ],
            ],
        ]
        let wire = try KubeMarkedWorkloadWire.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(wire.images, ["registry.acme.example/pay/checkout:4.12.0"])
        XCTAssertEqual(wire.spec?.strategy?.type, "RollingUpdate")
        XCTAssertEqual(wire.status?.updatedReplicas, 1)
        let kept = try XCTUnwrap(wire.condition("Progressing")?.message)
        XCTAssertLessThanOrEqual(kept.count, KubeMarkedWorkloadWire.messageCap)
        XCTAssertFalse(kept.contains("abcdefghij0123456789"), "scrubbed before it is cut")
        XCTAssertFalse(String(reflecting: wire).contains(Self.sentinel), "\(wire)")
    }

    func testARolloutsAndACronJobsFieldsAreRead() throws {
        let rollout = try KubeMarkedWorkloadWire.decode(
            JSONSerialization.data(withJSONObject: [
                "apiVersion": "argoproj.io/v1alpha1", "kind": "Rollout", "metadata": ["name": "acme-checkout", "generation": 4],
                "spec": ["workloadRef": ["apiVersion": "apps/v1", "kind": "Deployment", "name": "acme-checkout"]],
                "status": ["observedGeneration": "4", "phase": "Degraded", "message": "RolloutAborted: metric \"errors\" assessed Failed"],
            ]))
        XCTAssertEqual(rollout.group, "argoproj.io")
        XCTAssertEqual(rollout.status?.observedGeneration, 4, "a Rollout's observedGeneration is a string")
        XCTAssertEqual(rollout.spec?.workloadRef?.name, "acme-checkout")
        XCTAssertEqual(rollout.status?.phase, "Degraded")

        let cronJob = try KubeMarkedWorkloadWire.decode(
            JSONSerialization.data(withJSONObject: [
                "apiVersion": "batch/v1", "kind": "CronJob", "metadata": ["name": "acme-reindex"],
                "spec": [
                    "suspend": false,
                    "jobTemplate": ["spec": ["template": ["spec": ["containers": [["name": "job", "image": "acme/indexer:2.3.1", "env": [["value": Self.sentinel]]]]]]]],
                ],
                "status": [
                    "lastScheduleTime": "2026-11-14T06:00:00Z", "lastSuccessfulTime": "2026-11-13T06:00:00Z",
                    "active": [["name": Self.sentinel, "uid": Self.sentinel]],
                ],
            ]))
        XCTAssertEqual(cronJob.status?.active, 1, "counted, never kept")
        XCTAssertEqual(cronJob.images, ["acme/indexer:2.3.1"])
        XCTAssertFalse(String(reflecting: cronJob).contains(Self.sentinel))
    }
}
