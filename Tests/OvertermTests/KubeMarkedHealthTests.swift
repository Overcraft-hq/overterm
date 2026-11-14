import XCTest

@testable import Overterm

/// Argo CD's health of marked objects and of their app (docs/design/
/// kubernetes/gitops.md, 14.5 and 14.12): each built-in rule from cells and
/// from the object; the stuck single-replica rollout whose cells read
/// ready; StatefulSets and DaemonSets never Degraded; worst first, Unknown
/// Argo CD's word but ranked by its worst known member; an app with no
/// workload read Unknown, one with no member rule Ready; hooks and
/// ignore-healthcheck left out; a Rollout's phase, and the Deployment it
/// scales to 0 said scaled by it. Fictional names in the spoke's shape.
final class KubeMarkedHealthTests: XCTestCase {
    typealias Status = KubeMarkedHealth.Status
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Fixtures

    static let columns: [KubeMarkedKind: [String]] = [
        .deployment: ["Name", "Ready", "Up-to-date", "Available", "Images"], .rollout: ["Name", "Desired", "Current", "Up-to-date", "Available"],
        .statefulSet: ["Name", "Ready", "Images"], .daemonSet: ["Name", "Desired", "Current", "Ready", "Up-to-date", "Available"],
        .service: ["Name", "Type", "Cluster-IP", "External-IP"], .ingress: ["Name", "Class", "Hosts", "Address"], .persistentVolumeClaim: ["Name", "Status"],
        .horizontalPodAutoscaler: ["Name", "Reference", "Targets"], .cronJob: ["Name", "Schedule", "Suspend", "Active"], .job: ["Name", "Status", "Completions"],
    ]

    func columns(_ kind: KubeMarkedKind) -> [KubeColumn] {
        (Self.columns[kind] ?? ["Name"]).map { KubeColumn(name: $0, format: $0 == "Name" ? "name" : "") }
    }

    func row(_ kind: KubeMarkedKind, _ name: String, _ cells: [String: String], namespace: String = "acme-pay") -> KubeRow {
        let names = Self.columns[kind] ?? ["Name"]
        return KubeRow(id: KubeRowID(namespace: namespace, name: name), cells: names.map { $0 == "Name" ? .text(name) : .text(cells[$0] ?? "") })
    }

    func verdict(_ kind: KubeMarkedKind, _ cells: [String: String], marks: KubeMarkWire? = nil, notReadySince: Date? = nil) -> KubeMarkedHealth.Verdict? {
        KubeMarkedHealth.row(kind, row(kind, "acme-x", cells), columns: columns(kind), marks: marks, notReadySince: notReadySince, now: now)
    }

    static func wire(_ object: [String: Any]) -> KubeMarkedWorkloadWire {
        try! KubeMarkedWorkloadWire.decode(JSONSerialization.data(withJSONObject: object))
    }

    static func deployment(
        replicas: Int = 1, generation: Int = 2, observed: Int = 2, statusReplicas: Int = 1, updated: Int = 1, available: Int = 1, paused: Bool = false,
        stalled: Bool = false
    ) -> KubeMarkedWorkloadWire {
        var conditions: [[String: Any]] = [["type": "Available", "status": "True"]]
        if stalled {
            conditions.append([
                "type": "Progressing", "status": "False", "reason": "ProgressDeadlineExceeded", "lastTransitionTime": "2026-11-14T09:00:00Z",
                "message": "ReplicaSet \"acme-checkout-7f\" has timed out progressing.",
            ])
        }
        return wire([
            "apiVersion": "apps/v1", "kind": "Deployment", "metadata": ["name": "acme-checkout", "namespace": "acme-pay", "generation": generation],
            "spec": ["replicas": replicas, "paused": paused],
            "status": [
                "observedGeneration": observed, "replicas": statusReplicas, "updatedReplicas": updated, "readyReplicas": available,
                "availableReplicas": available, "conditions": conditions,
            ],
        ])
    }

    func member(_ kind: KubeMarkedKind, _ name: String, _ verdict: KubeMarkedHealth.Verdict?, marks: KubeMarkWire = KubeMarkWire()) -> KubeMarkedMember {
        KubeMarkedMember(id: .init(kind: kind, namespace: "acme-pay", name: name), marks: marks, health: verdict)
    }

    func app(_ members: [KubeMarkedMember]) -> KubeMarkedApp {
        KubeMarkedApp.make(key: .init(installation: "", instance: "prod-acme-pay-checkout-service"), members)!
    }

    // MARK: From cells

    func testADeploymentFromItsCells() {
        XCTAssertEqual(verdict(.deployment, ["Ready": "2/2", "Up-to-date": "2", "Available": "2"])?.status, .healthy)
        XCTAssertEqual(verdict(.deployment, ["Ready": "2/2", "Up-to-date": "2", "Available": "2"])?.fromRow, true, "ready by its row, not Argo CD's Healthy")
        XCTAssertEqual(verdict(.deployment, ["Ready": "2/4", "Up-to-date": "2", "Available": "2"])?.sentence, "2/4 updated")
        XCTAssertEqual(verdict(.deployment, ["Ready": "1/2", "Up-to-date": "2", "Available": "1"])?.status, .progressing)
        XCTAssertEqual(verdict(.deployment, ["Ready": "1/2", "Up-to-date": "2", "Available": "1"])?.detail, KubeMarkedHealth.podsHint)
        let zero = verdict(.deployment, ["Ready": "0/0", "Up-to-date": "0", "Available": "0"])
        XCTAssertEqual(zero?.status, .healthy)
        XCTAssertEqual(zero?.scaledToZero, true)
        var deleting = KubeMarkWire()
        deleting.deleting = true
        XCTAssertEqual(verdict(.deployment, ["Ready": "2/2", "Up-to-date": "2", "Available": "2"], marks: deleting)?.sentence, "pending deletion")
        XCTAssertNil(verdict(.deployment, [:]), "no cells, no word")
    }

    func testStatefulSetsAndDaemonSetsAreNeverDegraded() {
        let stuck = verdict(.statefulSet, ["Ready": "0/3"], notReadySince: now.addingTimeInterval(-3 * 3600))
        XCTAssertEqual(stuck?.status, .progressing, "0/3 for three hours is Progressing, in Argo CD as here")
        XCTAssertEqual(stuck?.sentence, "0/3 ready for 3h")
        XCTAssertEqual(verdict(.daemonSet, ["Desired": "5", "Up-to-date": "5", "Available": "3"])?.status, .progressing)
        let stalled = Self.wire([
            "apiVersion": "apps/v1", "kind": "StatefulSet", "metadata": ["name": "acme-ledger-db", "generation": 1],
            "spec": ["replicas": 3], "status": ["observedGeneration": 1, "readyReplicas": 0, "replicas": 3],
        ])
        XCTAssertEqual(KubeMarkedHealth.object(stalled)?.status, .progressing)
        for status in Status.allCases where status == .degraded {
            XCTAssertNotEqual(KubeMarkedHealth.object(stalled)?.status, status)
        }
    }

    func testServicesIngressesAndClaimsFromTheirCells() {
        XCTAssertEqual(verdict(.service, ["Type": "ClusterIP", "External-IP": "<none>"])?.status, .healthy)
        XCTAssertEqual(verdict(.service, ["Type": "LoadBalancer", "External-IP": "<pending>"])?.sentence, "load balancer not assigned")
        XCTAssertEqual(verdict(.service, ["Type": "LoadBalancer", "External-IP": ""])?.status, .progressing)
        XCTAssertEqual(verdict(.service, ["Type": "LoadBalancer", "External-IP": "203.0.113.7"])?.status, .healthy)
        XCTAssertEqual(verdict(.ingress, ["Address": ""])?.status, .progressing)
        XCTAssertEqual(verdict(.ingress, ["Address": "198.51.100.4"])?.status, .healthy)
        XCTAssertEqual(verdict(.persistentVolumeClaim, ["Status": "Bound"])?.status, .healthy)
        XCTAssertEqual(verdict(.persistentVolumeClaim, ["Status": "Pending"])?.sentence, "volume claim Pending")
        XCTAssertEqual(verdict(.persistentVolumeClaim, ["Status": "Lost"])?.status, .degraded)
        XCTAssertEqual(verdict(.persistentVolumeClaim, ["Status": "Odd"])?.status, .unknown)
    }

    func testAnHPAWithAnUnknownTargetWaitsForItsObject() {
        XCTAssertEqual(verdict(.horizontalPodAutoscaler, ["Targets": "cpu: 40%/80%"])?.status, .healthy)
        let unknown = verdict(.horizontalPodAutoscaler, ["Targets": "cpu: <unknown>/80%"])
        XCTAssertNil(unknown?.status)
        XCTAssertEqual(unknown?.unread, true)
        XCTAssertEqual(verdict(.cronJob, [:])?.unread, true, "a CronJob's health needs its object")
    }

    // MARK: From the object

    /// One replica, the default surge and no unavailable: a new pod that
    /// crash-loops leaves the old one serving, so every cell reads ready.
    func testAStuckSingleReplicaRolloutIsProgressingThenDegraded() {
        let cells = verdict(.deployment, ["Ready": "1/1", "Up-to-date": "1", "Available": "1"])
        XCTAssertEqual(cells?.status, .healthy)
        XCTAssertEqual(cells?.fromRow, true, "cells can't tell")
        let rolling = KubeMarkedHealth.object(Self.deployment(statusReplicas: 2, updated: 1, available: 1))
        XCTAssertEqual(rolling?.status, .progressing)
        XCTAssertEqual(rolling?.sentence, "1 old replica pending termination")
        XCTAssertEqual(rolling?.fromRow, false)
        let stalled = KubeMarkedHealth.object(Self.deployment(statusReplicas: 2, updated: 1, available: 1, stalled: true))
        XCTAssertEqual(stalled?.status, .degraded)
        XCTAssertEqual(stalled?.sentence, "rollout stalled (ProgressDeadlineExceeded)")
        XCTAssertEqual(stalled?.since, try? Date("2026-11-14T09:00:00Z", strategy: .iso8601))
        XCTAssertEqual(stalled?.detail, "ReplicaSet \"acme-checkout-7f\" has timed out progressing.", "the message for the hover only")
    }

    func testADeploymentByArgoCDsRule() {
        XCTAssertEqual(KubeMarkedHealth.object(Self.deployment(paused: true))?.status, .suspended)
        XCTAssertEqual(KubeMarkedHealth.object(Self.deployment(paused: true))?.sentence, "rollout paused")
        XCTAssertEqual(KubeMarkedHealth.object(Self.deployment(generation: 3, observed: 2))?.status, .progressing, "a stale generation")
        XCTAssertEqual(KubeMarkedHealth.object(Self.deployment(replicas: 4, statusReplicas: 4, updated: 2, available: 2))?.sentence, "2/4 updated")
        XCTAssertEqual(KubeMarkedHealth.object(Self.deployment(replicas: 2, statusReplicas: 2, updated: 2, available: 1))?.status, .progressing)
        XCTAssertEqual(KubeMarkedHealth.object(Self.deployment())?.status, .healthy)
        XCTAssertEqual(KubeMarkedHealth.object(Self.deployment(replicas: 0, statusReplicas: 0, updated: 0, available: 0))?.scaledToZero, true)
    }

    func testStatefulSetDaemonSetCronJobHPAAndJobByArgoCDsRules() {
        func sts(_ spec: [String: Any], _ status: [String: Any], generation: Int = 1) -> Status? {
            KubeMarkedHealth.object(Self.wire(["apiVersion": "apps/v1", "kind": "StatefulSet", "metadata": ["generation": generation], "spec": spec, "status": status]))?.status
        }
        XCTAssertEqual(sts(["replicas": 3], ["observedGeneration": 0, "readyReplicas": 3]), .progressing, "observedGeneration 0")
        XCTAssertEqual(
            sts(["replicas": 3, "updateStrategy": ["type": "RollingUpdate", "rollingUpdate": ["partition": 2]]], ["observedGeneration": 1, "readyReplicas": 3, "updatedReplicas": 1]),
            .healthy, "partitioned: 1 of 3 − 2 updated")
        XCTAssertEqual(
            sts(["replicas": 3, "updateStrategy": ["type": "OnDelete"]], ["observedGeneration": 1, "readyReplicas": 3, "currentRevision": "a", "updateRevision": "b"]),
            .healthy, "OnDelete")
        XCTAssertEqual(sts(["replicas": 3], ["observedGeneration": 1, "readyReplicas": 3, "currentRevision": "a", "updateRevision": "b"]), .progressing)

        let daemon = KubeMarkedHealth.object(
            Self.wire([
                "apiVersion": "apps/v1", "kind": "DaemonSet", "metadata": ["generation": 2],
                "status": ["observedGeneration": 2, "desiredNumberScheduled": 4, "updatedNumberScheduled": 4, "numberAvailable": 3],
            ]))
        XCTAssertEqual(daemon?.status, .progressing)

        func cron(_ spec: [String: Any], _ status: [String: Any]?) -> KubeMarkedHealth.Verdict? {
            var object: [String: Any] = ["apiVersion": "batch/v1", "kind": "CronJob", "metadata": ["name": "acme-reindex"], "spec": spec]
            object["status"] = status
            return KubeMarkedHealth.object(Self.wire(object))
        }
        XCTAssertEqual(cron(["suspend": true], ["lastScheduleTime": "2026-11-14T06:00:00Z"])?.status, .healthy, "suspended is Healthy, as Argo CD's Lua")
        XCTAssertEqual(cron([:], nil)?.status, .progressing, "no status")
        XCTAssertEqual(cron([:], ["lastScheduleTime": "2026-11-14T06:00:00Z"])?.status, .healthy, "never succeeded: Healthy, as Argo CD's Lua")
        let failed = cron([:], ["lastScheduleTime": "2026-11-14T06:00:00Z", "lastSuccessfulTime": "2026-11-13T06:00:00Z"])
        XCTAssertEqual(failed?.status, .degraded)
        XCTAssertEqual(failed?.sentence, "last run of CronJob acme-reindex failed")
        XCTAssertEqual(
            cron([:], ["lastScheduleTime": "2026-11-14T06:00:00Z", "lastSuccessfulTime": "2026-11-13T06:00:00Z", "active": [["name": "x"]]])?.status, .healthy,
            "a run going")

        func hpa(_ conditions: [[String: Any]]) -> Status? {
            KubeMarkedHealth.object(Self.wire(["apiVersion": "autoscaling/v2", "kind": "HorizontalPodAutoscaler", "status": ["conditions": conditions]]))?.status
        }
        XCTAssertEqual(
            hpa([["type": "AbleToScale", "status": "True"], ["type": "ScalingActive", "status": "False", "reason": "FailedGetResourceMetric"]]), .degraded)
        XCTAssertEqual(hpa([["type": "AbleToScale", "status": "False", "reason": "FailedGetScale"]]), .degraded)
        XCTAssertEqual(hpa([["type": "AbleToScale", "status": "True"], ["type": "ScalingActive", "status": "True"]]), .healthy)
        XCTAssertEqual(hpa([["type": "AbleToScale", "status": "False", "reason": "BackoffBoth"]]), .progressing)

        func job(_ conditions: [[String: Any]]) -> Status? {
            KubeMarkedHealth.object(Self.wire(["apiVersion": "batch/v1", "kind": "Job", "status": ["conditions": conditions]]))?.status
        }
        XCTAssertEqual(job([]), .progressing)
        XCTAssertEqual(job([["type": "Failed", "status": "True"]]), .degraded)
        XCTAssertEqual(job([["type": "Complete", "status": "True"]]), .healthy)
        XCTAssertNil(KubeMarkedHealth.object(Self.wire(["apiVersion": "v1", "kind": "Service"])), "no object rule for a Service")
    }

    func testARolloutsPhaseIsItsHealth() {
        func rollout(_ phase: String?, generation: Int = 3, observed: String = "3") -> Status? {
            var status: [String: Any] = ["observedGeneration": observed]
            status["phase"] = phase
            return KubeMarkedHealth.object(
                Self.wire(["apiVersion": "argoproj.io/v1alpha1", "kind": "Rollout", "metadata": ["generation": generation], "status": status]))?.status
        }
        XCTAssertEqual(rollout("Healthy"), .healthy)
        XCTAssertEqual(rollout("Degraded"), .degraded)
        XCTAssertEqual(rollout("Paused"), .suspended)
        XCTAssertEqual(rollout("Progressing"), .progressing)
        XCTAssertEqual(rollout("Healthy", generation: 4), .progressing, "a spec not yet observed")
    }

    // MARK: The app

    func testTheWorstMemberWithUpToThreeCauses() {
        let verdicts: [(String, Status)] = [("a-api", .progressing), ("b-api", .degraded), ("c-api", .degraded), ("d-api", .progressing), ("e-api", .healthy)]
        let members = verdicts.map { member(.deployment, $0.0, .init(status: $0.1, sentence: "\($0.1.word.lowercased()) sentence")) }
        let health = app(members).health
        XCTAssertEqual(health.status, .degraded)
        XCTAssertEqual(health.state, .failed)
        XCTAssertEqual(health.word, "Failed")
        XCTAssertEqual(health.causes.map(\.member.name), ["b-api", "c-api", "a-api"], "Degraded first, three named")
        XCTAssertEqual(health.more, 1)
        XCTAssertEqual(health.why, "degraded sentence · Deployment b-api · and 3 more")
        XCTAssertEqual(health.notes.first, "Argo CD's rule: Degraded")
    }

    /// Decision D-7: Unknown is Argo CD's word, but the app ranks with its
    /// worst known member and its why names that member first.
    func testUnknownIsTheWordButTheWorstKnownMemberIsTheRank() {
        let health = app([
            member(.persistentVolumeClaim, "acme-data", .init(status: .unknown, sentence: "volume claim Odd")),
            member(.deployment, "acme-api", .init(status: .degraded, sentence: "rollout stalled (ProgressDeadlineExceeded)")),
        ]).health
        XCTAssertEqual(health.status, .unknown)
        XCTAssertEqual(health.word, "Unknown")
        XCTAssertEqual(health.state, .failed, "sorts with Failed")
        XCTAssertTrue(health.why.hasPrefix("rollout stalled (ProgressDeadlineExceeded) · Deployment acme-api"))
        let unknownBesideReady = app([
            member(.persistentVolumeClaim, "acme-data", .init(status: .unknown, sentence: "volume claim Odd")),
            member(.deployment, "acme-api", .init(status: .healthy, sentence: "1/1 available")),
        ]).health
        XCTAssertEqual(unknownBesideReady.state, .unknown, "never ranked Ready, so Hide Ready never hides it")
    }

    func testAnAppWithNoWorkloadReadIsUnknownNotReady() {
        let health = app([
            member(.service, "acme-web", .init(status: .healthy, sentence: "service")),
            member(.ingress, "acme-web", .init(status: .healthy, sentence: "address assigned")),
        ]).health
        XCTAssertEqual(health.status, .unknown)
        XCTAssertEqual(health.state, .unknown)
        XCTAssertEqual(health.why, KubeMarkedHealth.noWorkload)
    }

    func testAnAppNoMemberOfWhichHasARuleIsReady() {
        let health = app([member(.other(group: "", kind: "ServiceAccount"), "acme-sa", nil)]).health
        XCTAssertEqual(health.status, .healthy, "Argo CD starts an app's health from Healthy")
        XCTAssertTrue(health.notes.contains("no member here has a health check; Argo CD shows such an app Healthy"))
    }

    func testHooksAndIgnoredMembersAreNotCounted() {
        var hook = KubeMarkWire()
        hook.hook = "PreSync"
        var ignored = KubeMarkWire()
        ignored.ignoreHealthcheck = true
        let built = app([
            member(.deployment, "acme-api", .init(status: .healthy, sentence: "1/1 available")),
            member(.job, "acme-migrate", .init(status: .degraded, sentence: "job failed"), marks: hook),
            member(.deployment, "acme-canary", .init(status: .degraded, sentence: "rollout stalled"), marks: ignored),
        ])
        XCTAssertEqual(built.hooks.map(\.id.name), ["acme-migrate"], "shown under the app as a hook")
        XCTAssertEqual(built.members.map(\.id.name), ["acme-api", "acme-canary"])
        XCTAssertEqual(built.health.status, .healthy)
        XCTAssertEqual(built.health.why, "1 object ready")
    }

    func testFromItsRowIsCarriedToTheApp() {
        let fromRow = app([member(.deployment, "acme-api", .init(status: .healthy, sentence: "1/1 ready", fromRow: true))]).health
        XCTAssertEqual(fromRow.state, .ready)
        XCTAssertTrue(fromRow.fromRows)
        let settled = app([member(.deployment, "acme-api", .init(status: .healthy, sentence: "1/1 available"))]).health
        XCTAssertFalse(settled.fromRows)
        let unreadHPA = app([
            member(.deployment, "acme-api", .init(status: .healthy, sentence: "1/1 available")),
            member(.horizontalPodAutoscaler, "acme-api", .init(status: nil, sentence: "a target reads <unknown>", unread: true)),
        ]).health
        XCTAssertTrue(unreadHPA.fromRows)
        XCTAssertTrue(unreadHPA.notes.contains("an HPA's state wasn't read: HorizontalPodAutoscaler acme-api"))
    }

    /// A Rollout with `workloadRef` runs instead of its Deployment, which
    /// the Rollouts controller scales to 0: that Deployment is "scaled by
    /// its Rollout", and the Rollout's phase is the app's health.
    func testARolloutsDeploymentIsScaledByItNotAProblem() {
        let zero = KubeMarkedHealth.Verdict(status: .healthy, sentence: "scaled to 0", scaledToZero: true)
        var rollout = member(.rollout, "acme-checkout", .init(status: .degraded, sentence: "rollout degraded"))
        rollout.workloadRef = "acme-checkout"
        let built = app([member(.deployment, "acme-checkout", zero), rollout])
        XCTAssertEqual(built.health.status, .degraded)
        XCTAssertEqual(built.health.causes.map(\.member.kind), [.rollout], "the Deployment isn't a cause")
        rollout.health = .init(status: .healthy, sentence: "rollout healthy")
        let healthy = app([member(.deployment, "acme-checkout", zero), rollout]).health
        XCTAssertEqual(healthy.status, .healthy)
        // Its sentence, as the detail will show it.
        let plain = app([member(.deployment, "acme-checkout", zero)])
        XCTAssertEqual(plain.health.status, .healthy, "without a Rollout, Argo CD's Healthy scaled to 0")
    }

    /// A Rollout's row never settles it: its printer columns are counts,
    /// and equal counts can be Paused or an aborted, Degraded canary.
    func testARolloutsRowWaitsForItsPhase() {
        let fromCells = verdict(.rollout, ["Desired": "3", "Current": "3", "Up-to-date": "3", "Available": "3"])
        XCTAssertNil(fromCells?.status, "never Healthy from cells")
        XCTAssertEqual(fromCells?.unread, true)
        // Its row beside the Deployment it scales to 0: not Ready from that 0.
        var rollout = member(.rollout, "acme-checkout", fromCells)
        rollout.workloadRef = "acme-checkout"
        let zero = KubeMarkedHealth.Verdict(status: .healthy, sentence: "scaled to 0", scaledToZero: true)
        let waiting = app([member(.deployment, "acme-checkout", zero), rollout, member(.service, "acme-checkout", .init(status: .healthy, sentence: "service"))]).health
        XCTAssertEqual(waiting.status, .unknown)
        XCTAssertEqual(waiting.why, "not read yet")
        let unrated = app([member(.deployment, "acme-checkout", zero), member(.rollout, "acme-checkout", nil)]).health
        XCTAssertEqual(unrated.status, .unknown, "a Rollout with no verdict leaves a scaled-to-0 Deployment saying nothing")
    }

    /// A CronJob not yet read beside its Service: Unknown, never Ready
    /// from the Service (14.5).
    func testACronJobNotYetReadIsNotReadyFromItsService() {
        let health = app([
            member(.cronJob, "acme-reindex", verdict(.cronJob, [:])), member(.service, "acme-reindex", .init(status: .healthy, sentence: "service")),
        ]).health
        XCTAssertEqual(health.status, .unknown)
        XCTAssertEqual(health.state, .unknown)
        XCTAssertEqual(health.why, "not read yet")
        XCTAssertTrue(health.fromRows)
    }

    func testReadyAppsSinceArgoCDsLastChange() {
        var marks = KubeMarkWire()
        marks.argoChanged = now.addingTimeInterval(-600)
        var created = member(.deployment, "acme-api", .init(status: .healthy, sentence: "1/1 available"), marks: marks)
        created.created = now.addingTimeInterval(-86400)
        XCTAssertEqual(app([created]).health.since, now.addingTimeInterval(-600))
        XCTAssertEqual(app([created]).health.sinceSaid, "last change applied by Argo CD")
        created.marks = KubeMarkWire()
        let byAge = app([created]).health
        XCTAssertEqual(byAge.since, now.addingTimeInterval(-86400))
        XCTAssertTrue(byAge.notes.contains("Argo CD's last change isn't readable here"))
    }

    /// Pods are never members: a ReplicaSet's or a pod's copy of the
    /// Deployment's mark is a copy, and the list reads no pods.
    func testPodsAndCopiesAreNotCounted() {
        let id = KubeTrackingID(instance: "prod-acme-pay-checkout-service", group: "apps", kind: "Deployment", namespace: "acme-pay", name: "acme-checkout")
        var copy = KubeMarkWire()
        copy.tracking = .copied(id)
        let apps = KubeMarkedApps.group([
            member(.other(group: "", kind: "Pod"), "acme-checkout-7f-x", .init(status: .degraded, sentence: "CrashLoopBackOff"), marks: copy)
        ])
        XCTAssertEqual(apps.count, 0)
        XCTAssertEqual(apps.tally.copied, 1)
    }
}
