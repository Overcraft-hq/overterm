import Foundation
import XCTest

@testable import Overterm

/// The Metrics tab of a workload, an HPA, a node and a namespace, sampled
/// (docs/design/kubernetes/metrics.md, 2.5–2.8; stage M3b): what the
/// objects' reads decode to, the parts the ring keeps beside a sum, the
/// status history, the charts built from them — and, over `FakeKubeAPI`,
/// what each tab reads while it shows and nothing once it doesn't. No
/// cluster of the user's is reached.
@MainActor
final class KubeObjectChartsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func pod(_ name: String, cpu: Double, memory: Double = 64 * 1_048_576, at time: Date, revision: String? = nil, namespace: String = "shop")
        -> KubePodMetrics
    {
        KubePodMetrics(
            id: KubeRowID(namespace: namespace, name: name), timestamp: time, window: "15s", containers: ["app": KubeUsage(cpu: cpu, memory: memory)],
            revision: revision)
    }

    // MARK: Reading the objects

    func testAPodsWorkloadIsReadOffItsNameOnlyWhenNoRowSaysIt() {
        XCTAssertEqual(KubeWorkloadName.of(pod: "web-7d9f8b6c5d-x2k4q").id, "Deployment/web")
        XCTAssertEqual(KubeWorkloadName.of(pod: "api-v2-6c8b5f9d4-bcdfg").id, "Deployment/api-v2")
        XCTAssertEqual(KubeWorkloadName.of(pod: "db-0").id, "StatefulSet/db")
        XCTAssertEqual(KubeWorkloadName.of(pod: "fluent-bit-x2k4q").id, "fluent-bit", "a DaemonSet's or a Job's: the name can't say which")
        XCTAssertEqual(KubeWorkloadName.of(pod: "standalone").id, "Pod/standalone")
        XCTAssertEqual(KubeWorkloadName.of(pod: "web-aeiou-x2k4q").id, "web-aeiou", "vowels are no generated hash")

        let deployment: [String: Any] = [
            "labels": ["pod-template-hash": "7d9f8b6c5d"], "ownerReferences": [["kind": "ReplicaSet", "name": "web-7d9f8b6c5d", "controller": true]],
        ]
        XCTAssertEqual(KubeNamespacePods.owner(name: "web-7d9f8b6c5d-x2k4q", metadata: deployment), "Deployment/web")
        XCTAssertEqual(KubeNamespacePods.owner(name: "db-0", metadata: ["ownerReferences": [["kind": "StatefulSet", "name": "db"]]]), "StatefulSet/db")
        XCTAssertEqual(KubeNamespacePods.owner(name: "db-0", metadata: [:]), "StatefulSet/db", "no metadata in the row: the name read")
        XCTAssertEqual(KubeNamespacePods.owner(name: "db-1", metadata: ["name": "db-1"]), "Pod/db-1", "the rows say it has no owner: a bare pod")
    }

    func testARowsStatusIsAPhase() {
        XCTAssertEqual(KubePodPhase.of(status: "Running"), "Running")
        XCTAssertEqual(KubePodPhase.of(status: "CrashLoopBackOff"), "Running", "its phase is Running")
        XCTAssertEqual(KubePodPhase.of(status: "Completed"), "Succeeded")
        XCTAssertEqual(KubePodPhase.of(status: "Evicted"), "Failed")
        XCTAssertEqual(KubePodPhase.of(status: "Init:0/1"), "Pending")
        XCTAssertEqual(KubePodPhase.of(status: "ContainerCreating"), "Pending")
    }

    func testANamespacesMetadataRowsSayEachPodsOwnerAndPhase() throws {
        let table: [String: Any] = [
            "kind": "Table", "columnDefinitions": [["name": "Name"], ["name": "Ready"], ["name": "Status"]],
            "rows": [
                [
                    "cells": ["web-7d9f8b6c5d-x2k4q", "1/1", "Running"],
                    "object": [
                        "metadata": [
                            "name": "web-7d9f8b6c5d-x2k4q", "labels": ["pod-template-hash": "7d9f8b6c5d"],
                            "ownerReferences": [["kind": "ReplicaSet", "name": "web-7d9f8b6c5d", "controller": true]],
                        ]
                    ],
                ],
                ["cells": ["migrate-x2k4q", "0/1", "Completed"], "object": ["metadata": ["name": "migrate-x2k4q", "ownerReferences": [["kind": "Job", "name": "migrate"]]]]],
            ],
            "metadata": ["continue": "next"],
        ]
        let page = try KubeNamespacePods.read(JSONSerialization.data(withJSONObject: table))
        XCTAssertEqual(page.continueToken, "next")
        let pods = KubeNamespacePods(pods: page.pods)
        XCTAssertEqual(pods.owners, ["web-7d9f8b6c5d-x2k4q": "Deployment/web", "migrate-x2k4q": "Job/migrate"])
        XCTAssertEqual(pods.phases, ["Running": 1, "Succeeded": 1])
    }

    func testANodesPodsAreDecodedToWhatTheyRequestAndNothingElse() throws {
        func item(_ name: String, phase: String, cpu: String, memory: String) -> [String: Any] {
            [
                "metadata": ["name": name, "namespace": "shop"],
                "spec": [
                    "containers": [
                        ["name": "app", "env": [["name": "TOKEN", "value": "tok-fake-123"]], "resources": ["requests": ["cpu": cpu, "memory": memory]]]
                    ]
                ],
                "status": ["phase": phase],
            ]
        }
        let list: [String: Any] = [
            "items": [item("a", phase: "Running", cpu: "500m", memory: "256Mi"), item("b", phase: "Pending", cpu: "1", memory: "1Gi"), item("c", phase: "Succeeded", cpu: "2", memory: "1Gi")],
            "metadata": ["continue": ""],
        ]
        let pods = try KubeNodePods.read(JSONSerialization.data(withJSONObject: list))
        XCTAssertFalse(pods.more)
        XCTAssertEqual(pods.active.map(\.id.name), ["a", "b"], "a Succeeded pod isn't counted, as the scheduler doesn't")
        XCTAssertEqual(pods.requested.cpu, 1.5, accuracy: 1e-9)
        XCTAssertEqual(pods.requested.memory, 1_342_177_280, accuracy: 1)
        XCTAssertEqual(pods.largest(1).map(\.id.name), ["b"])
        XCTAssertFalse("\(pods)".contains("tok-fake-123"), "no env value kept")
        let cut = try KubeNodePods.read(JSONSerialization.data(withJSONObject: ["items": [], "metadata": ["continue": "more"]]))
        XCTAssertTrue(cut.more)
    }

    func testANodeSaysItsAllocatableItsPodsAndItsPressure() {
        let since = t0.addingTimeInterval(-600)
        let facts = KubeNodeFacts.of([
            "spec": ["unschedulable": true, "taints": [["key": "node.kubernetes.io/unschedulable", "effect": "NoSchedule", "timeAdded": since.formatted(.iso8601)]]],
            "status": [
                "allocatable": ["cpu": "3920m", "memory": "15Gi", "pods": "58"], "capacity": ["cpu": "4", "memory": "16Gi", "pods": "58"],
                "conditions": [
                    ["type": "MemoryPressure", "status": "True", "lastTransitionTime": since.formatted(.iso8601)], ["type": "DiskPressure", "status": "False"],
                    ["type": "Ready", "status": "True"],
                ],
            ],
        ])
        XCTAssertEqual(facts.allocatable?.cpu ?? 0, 3.92, accuracy: 1e-9)
        XCTAssertEqual(facts.capacity?.cpu, 4)
        XCTAssertEqual(facts.allocatablePods, 58)
        XCTAssertEqual(facts.spells.map(\.title), ["MemoryPressure", "Cordoned"])
        XCTAssertEqual(facts.spells.first?.since, since)
    }

    func testAQuotaAndAWorkloadsReplicasRead() throws {
        let quotas: [String: Any] = [
            "items": [
                ["status": ["hard": ["requests.cpu": "4", "requests.memory": "8Gi"], "used": ["requests.cpu": "1500m", "requests.memory": "2Gi"]]],
                ["status": ["hard": ["requests.cpu": "10"], "used": ["requests.cpu": "1500m"]]],
            ]
        ]
        let quota = KubeQuota.read(try JSONSerialization.data(withJSONObject: quotas))
        XCTAssertEqual(quota.cpuHard, 4, "the tightest")
        XCTAssertEqual(quota.cpuUsed, 1.5)
        XCTAssertEqual(quota.memoryHard, 8 * 1_073_741_824)
        XCTAssertTrue(KubeQuota.read(Data("{\"items\":[]}".utf8)).isEmpty)

        let deployment = KubeReplicaStatus.of(["spec": ["replicas": 3], "status": ["availableReplicas": 2]], kind: "Deployment")
        XCTAssertEqual(deployment.numbers, ["desired": 3, "available": 2, "unavailable": 1])
        let job = KubeReplicaStatus.of(["status": ["active": 1, "succeeded": 4]], kind: "Job")
        XCTAssertEqual(job.numbers, ["active": 1, "succeeded": 4, "failed": 0])
        let daemons = KubeReplicaStatus.of(["status": ["desiredNumberScheduled": 5, "numberAvailable": 4, "numberUnavailable": 1]], kind: "DaemonSet")
        XCTAssertEqual(daemons.numbers, ["desired": 5, "available": 4, "unavailable": 1])
    }

    func testAnHPAsMetricsAreNumbersInTheirUnit() {
        XCTAssertEqual(KubeHPAStatus.Metric(name: "cpu", current: "45%", target: "70%").numbers.unit, .ratio)
        XCTAssertEqual(KubeHPAStatus.Metric(name: "cpu", current: "45%", target: "70%").numbers.target ?? 0, 0.7, accuracy: 1e-9)
        XCTAssertEqual(KubeHPAStatus.Metric(name: "memory", current: "300Mi", target: "512Mi").numbers.unit, .bytes)
        XCTAssertEqual(KubeHPAStatus.Metric(name: "requests_per_second", current: "1500m", target: "2").numbers.current, 1.5)
        let table = KubeTable(
            columns: [KubeColumn(name: "Name", format: "name"), KubeColumn(name: "Reference")],
            rows: [
                KubeRow(id: KubeRowID(namespace: "shop", name: "api"), cells: [.text("api"), .text("Deployment/api")]),
                KubeRow(id: KubeRowID(namespace: "shop", name: "web"), cells: [.text("web"), .text("Deployment/web")]),
            ])
        XCTAssertEqual(KubeChartLookups.hpa(targeting: "Deployment", "web", in: table), "web")
        XCTAssertNil(KubeChartLookups.hpa(targeting: "StatefulSet", "web", in: table))
    }

    // MARK: The status history

    func testTheStatusHistoryKeepsChangesHeldAndBreaksWhereNotRead() {
        var history = KubeStatusHistory()
        let key = KubeStatusKey.hpa(namespace: "shop", name: "web")
        for (offset, current) in [(0, 2.0), (15, 2), (30, 3), (45, 3)] {
            history.record(key, ["current": current], at: t0.addingTimeInterval(Double(offset)), expected: 15, now: t0.addingTimeInterval(Double(offset)))
        }
        XCTAssertEqual(history.of(key, now: t0.addingTimeInterval(45))?.points.count, 2, "a point only where it changed")
        // Hidden for five minutes: a break, then the reading again.
        history.record(key, ["current": 3], at: t0.addingTimeInterval(345), expected: 15, now: t0.addingTimeInterval(345))
        let (points, breaks) = history.points(key, "current", from: t0.addingTimeInterval(-60), now: t0.addingTimeInterval(345))
        XCTAssertEqual(points.map(\.value), [2, 3, 3, 3])
        XCTAssertEqual(points.map { $0.time.timeIntervalSince(t0) }, [0, 30, 45, 345], "held to when it was last read, then a break")
        XCTAssertEqual(breaks, [t0.addingTimeInterval(345)])
        // A window starting after the change: the value held at its start.
        let late = history.points(key, "current", from: t0.addingTimeInterval(40), now: t0.addingTimeInterval(345)).points
        XCTAssertEqual(late.first?.time, t0.addingTimeInterval(40))
        XCTAssertEqual(late.first?.value, 3)
        history.prune(now: t0.addingTimeInterval(345 + 3601))
        XCTAssertTrue(history.isEmpty, "forgotten an hour after it was fed")

        var many = KubeStatusHistory()
        for index in 0...KubeStatusHistory.keys {
            many.record(.phases("ns-\(index)"), ["Running": 1], at: t0.addingTimeInterval(Double(index)), expected: 60, now: t0.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(many.count, KubeStatusHistory.keys)
        XCTAssertNil(many.of(.phases("ns-0"), now: t0.addingTimeInterval(100)), "the least recently fed went")
    }

    // MARK: The ring's parts

    func testAWorkloadsSampleKeepsEachPodAndEachRevisionBesideItsSum() {
        var ring = KubeUsageRing()
        let detail = KubeMetricsDetail.workload(namespace: "shop", kind: "Deployment", name: "web", labels: "app=web")
        for step in 0..<3 {
            let time = t0.addingTimeInterval(Double(step) * 15)
            let sample = KubeMetricsSample(
                pods: [
                    pod("web-aaaaa-bbbbb", cpu: 0.1, at: time, revision: "aaaaa"), pod("web-ccccc-ddddd", cpu: 0.3, at: time.addingTimeInterval(-4), revision: "ccccc"),
                ], read: time)
            ring.record(sample, for: detail.target, asList: false, asDetail: true, sums: [detail.sum!], parts: detail.parts, now: time)
        }
        XCTAssertEqual(ring.points(.workload(namespace: "shop", kind: "Deployment", name: "web"), now: t0.addingTimeInterval(30)).count, 3)
        XCTAssertEqual(ring.points(.pod(KubeRowID(namespace: "shop", name: "web-ccccc-ddddd")), now: t0.addingTimeInterval(30)).count, 3)
        XCTAssertEqual(ring.parts(of: "Deployment/web", in: "shop", now: t0.addingTimeInterval(30)), ["rev:aaaaa", "rev:ccccc"])

        // Past 50 pods: the sum alone.
        var crowded = KubeUsageRing()
        let pods = (0...KubeUsageRing.podPartsAtMost).map { pod("big-\($0)", cpu: 0.01, at: t0) }
        crowded.record(KubeMetricsSample(pods: pods, read: t0), for: detail.target, asList: false, asDetail: true, sums: [detail.sum!], parts: detail.parts, now: t0)
        XCTAssertEqual(crowded.detailKeyCount, 1, "only the sum")
    }

    func testANamespacesSampleIsSummedByOwnerElseByName() {
        var ring = KubeUsageRing()
        let detail = KubeMetricsDetail.namespace("shop")
        let sample = KubeMetricsSample(
            pods: [pod("web-7d9f8b6c5d-x2k4q", cpu: 0.2, at: t0), pod("web-7d9f8b6c5d-z4m5r", cpu: 0.1, at: t0), pod("db-0", cpu: 0.5, at: t0)], read: t0)
        ring.record(sample, for: detail.target, asList: false, asDetail: true, sums: [detail.sum!], parts: detail.parts, owners: ["db-0": "StatefulSet/postgres"], now: t0)
        XCTAssertEqual(ring.parts(of: "", in: "shop", now: t0), ["Deployment/web", "StatefulSet/postgres"])
        let web = ring.points(.part(namespace: "shop", whole: "", part: "Deployment/web"), now: t0)
        XCTAssertEqual(web.first?.usage.cpu ?? 0, 0.3, accuracy: 1e-6)
    }

    func testANamespacesWorkloadGuessedByNameGivesWayToItsOwner() {
        var ring = KubeUsageRing()
        let detail = KubeMetricsDetail.namespace("shop")
        let first = KubeMetricsSample(pods: [pod("fluent-bit-x2k4q", cpu: 0.1, at: t0)], read: t0)
        ring.record(first, for: detail.target, asList: false, asDetail: true, sums: [detail.sum!], parts: detail.parts, now: t0)
        XCTAssertEqual(ring.parts(of: "", in: "shop", now: t0), ["fluent-bit"], "before the rows: the name read")
        let t1 = t0.addingTimeInterval(15)
        let second = KubeMetricsSample(pods: [pod("fluent-bit-x2k4q", cpu: 0.1, at: t1)], read: t1)
        ring.record(
            second, for: detail.target, asList: false, asDetail: true, sums: [detail.sum!], parts: detail.parts,
            owners: ["fluent-bit-x2k4q": "DaemonSet/fluent-bit"], now: t1)
        XCTAssertEqual(ring.parts(of: "", in: "shop", now: t1), ["DaemonSet/fluent-bit"], "one series, the owner's")
    }

    func testPartsAreLinedUpOnTheTotalsTimes() {
        let points = [KubeSeriesPoint(time: t0, value: 1), KubeSeriesPoint(time: t0.addingTimeInterval(15), value: 2)]
        let aligned = KubeChartBuild.align(points, to: [t0.addingTimeInterval(4), t0.addingTimeInterval(19), t0.addingTimeInterval(200)], within: 37.5)
        XCTAssertEqual(aligned.map(\.value), [1, 2], "none in a gap, never a guess")
        let rest = KubeChartBuild.rest([KubeSeriesPoint(time: t0, value: 5)], minus: [[KubeSeriesPoint(time: t0, value: 2)], [KubeSeriesPoint(time: t0, value: 4)]])
        XCTAssertEqual(rest.first?.value, 0, "never below zero")
    }

    // MARK: Charts

    private func workloadRing(pods: Int, revisions: [String] = ["7d9f8b6c5d"]) -> (KubeUsageRing, [KubePodMetrics], Date) {
        var ring = KubeUsageRing()
        let detail = KubeMetricsDetail.workload(namespace: "shop", kind: "Deployment", name: "web", labels: "app=web")
        var last: [KubePodMetrics] = []
        var now = t0
        for step in 0..<4 {
            now = t0.addingTimeInterval(Double(step) * 15)
            last = (0..<pods).map { index in
                pod(
                    "web-\(revisions[index % revisions.count])-pod\(String(repeating: "b", count: 2))\(["b", "c", "d", "f", "g", "h", "j", "k"][index % 8])",
                    cpu: 0.1 * Double(index + 1), at: now, revision: revisions[index % revisions.count])
            }
            ring.record(KubeMetricsSample(pods: last, read: now), for: detail.target, asList: false, asDetail: true, sums: [detail.sum!], parts: detail.parts, now: now)
        }
        return (ring, last, now)
    }

    private let template: [String: Any] = [
        "spec": [
            "replicas": 3,
            "template": ["spec": ["containers": [["name": "app", "resources": ["requests": ["cpu": "250m", "memory": "128Mi"], "limits": ["cpu": "1", "memory": "256Mi"]]]]]],
        ],
        "status": ["replicas": 3],
    ]

    func testAWorkloadWithFewPodsDrawsEachAgainstOnePodsTemplate() throws {
        let (ring, pods, now) = workloadRing(pods: 3)
        var statuses = KubeStatusHistory()
        statuses.record(.replicas(namespace: "shop", kind: "Deployment", name: "web"), ["desired": 3, "available": 2, "unavailable": 1], at: t0, expected: 60, now: now)
        let charts = KubeWorkloadCharts.build(
            KubeWorkloadCharts.Input(
                namespace: "shop", kind: "Deployment", name: "web", object: template, ring: ring, statuses: statuses, pods: pods, range: .live, now: now,
                interval: 15, revisions: ["web-7d9f8b6c5d": "rev 14 (nginx:1.27.2)"]))
        XCTAssertEqual(charts.view, .perPod, "five pods or fewer: Per pod (decision 13)")
        let cpu = try XCTUnwrap(charts.charts.first { $0.data.id.hasSuffix(".cpu") })
        XCTAssertFalse(cpu.data.stacked)
        XCTAssertEqual(cpu.data.usage.count, 3)
        XCTAssertEqual(cpu.data.usage.first?.points.last?.value ?? 0, 0.3, accuracy: 1e-6, "the busiest first")
        XCTAssertEqual(cpu.data.references.map(\.name), ["request a pod (template)", "limit a pod (template)"])
        XCTAssertEqual(cpu.data.references.first?.points.last?.value, 0.25)
        let revisions = try XCTUnwrap(charts.charts.first { $0.data.id.hasSuffix(".revisions") })
        XCTAssertEqual(revisions.data.usage.map(\.name), ["rev 14 (nginx:1.27.2)"], "labelled from the timeline")
        let replicas = try XCTUnwrap(charts.charts.first { $0.data.id.hasSuffix(".replicas") })
        XCTAssertTrue(replicas.data.stepped)
        XCTAssertEqual(replicas.data.usage.map(\.id), ["available", "unavailable"])
        XCTAssertEqual(replicas.data.references.map(\.name), ["desired"])
        XCTAssertTrue(charts.caption.hasPrefix("Sampled from metrics-server while shown since"), charts.caption)
    }

    func testAWorkloadWithManyPodsStacksItsTopFiveAndTheRest() throws {
        let (ring, pods, now) = workloadRing(pods: 7, revisions: ["7d9f8b6c5d", "6c8b5f9d4"])
        let charts = KubeWorkloadCharts.build(
            KubeWorkloadCharts.Input(
                namespace: "shop", kind: "Deployment", name: "web", object: template, ring: ring, statuses: KubeStatusHistory(), pods: pods, range: .live, now: now,
                interval: 15, hpa: (name: "web", status: KubeHPAStatus(name: "web", current: 3, desired: 3, min: 2, max: 10, scalingLimited: false, metrics: []))))
        XCTAssertEqual(charts.view, .total)
        let cpu = try XCTUnwrap(charts.charts.first { $0.data.id.hasSuffix(".cpu") })
        XCTAssertTrue(cpu.data.stacked)
        XCTAssertEqual(cpu.data.usage.count, 6, "the top five and other")
        XCTAssertEqual(cpu.data.usage.last?.id, "other")
        XCTAssertEqual(cpu.data.usage.last?.points.last?.value ?? 0, 0.3, accuracy: 1e-5, "0.1 + 0.2: the two least busy")
        XCTAssertEqual(cpu.data.references.first?.points.last?.value, 0.75, "the template's request × 3 replicas")
        XCTAssertEqual(cpu.data.references.first?.name, "request × 3 (template)")
        XCTAssertEqual(cpu.headline, "total 2800m")
        let revisions = try XCTUnwrap(charts.charts.first { $0.data.id.hasSuffix(".revisions") })
        XCTAssertEqual(revisions.data.usage.map(\.name).sorted(), ["rev 6c8b5f9d4", "rev 7d9f8b6c5d"], "unlabelled: their hashes")
        XCTAssertNil(charts.charts.first { $0.data.id.hasSuffix(".replicas") }, "no replicas read yet")
        // Per pod picked: the top five as lines.
        let perPod = KubeWorkloadCharts.build(
            KubeWorkloadCharts.Input(
                namespace: "shop", kind: "Deployment", name: "web", object: template, ring: ring, statuses: KubeStatusHistory(), pods: pods, range: .live, now: now,
                interval: 15, view: .perPod))
        XCTAssertEqual(perPod.charts.first?.data.usage.count, 5)
        XCTAssertFalse(perPod.charts.first?.data.stacked ?? true)
    }

    func testAnHPAsReplicasAreSteppedWithItsBoundsAndItsFlapping() throws {
        var statuses = KubeStatusHistory()
        let key = KubeStatusKey.hpa(namespace: "shop", name: "web")
        var now = t0
        for step in 0..<12 {
            now = t0.addingTimeInterval(Double(step) * 15)
            let current = Double(2 + step % 2)
            statuses.record(
                key,
                ["current": current, "desired": current, "min": 2, "max": 10, "metric.cpu.current": 0.85, "metric.cpu.target": 0.7]
                    .merging(step >= 8 ? ["limited": 1] : [:]) { $1 }, at: now, expected: 15, now: now)
        }
        let status = KubeHPAStatus(
            name: "web", current: 3, desired: 3, min: 2, max: 10, scalingLimited: true, metrics: [KubeHPAStatus.Metric(name: "cpu", current: "85%", target: "70%")])
        let charts = KubeHPACharts.build(namespace: "shop", name: "web", status: status, statuses: statuses, range: .live, now: now, interval: 15)
        let replicas = try XCTUnwrap(charts.charts.first)
        XCTAssertTrue(replicas.data.stepped)
        XCTAssertEqual(replicas.data.references.map(\.name), ["min", "max"])
        XCTAssertTrue(replicas.chips.contains { $0.text == "flapping: 11 scales in 1h" && $0.alert }, "\(replicas.chips)")
        XCTAssertEqual(replicas.data.bands.map(\.title), ["ScalingLimited"])
        XCTAssertEqual(replicas.data.bands.first?.start, t0.addingTimeInterval(120))
        let cpu = try XCTUnwrap(charts.charts.last)
        XCTAssertEqual(cpu.data.unit, .ratio)
        XCTAssertEqual(cpu.data.references.map(\.name), ["target"])
        XCTAssertEqual(cpu.chips.first?.text, "121% of target")
    }

    func testANodeIsDrawnAgainstItsPodsRequestsItsAllocatableAndItsPressure() throws {
        var ring = KubeUsageRing()
        var statuses = KubeStatusHistory()
        var now = t0
        for step in 0..<4 {
            now = t0.addingTimeInterval(Double(step) * 15)
            ring.record(
                KubeMetricsSample(nodes: [KubeNodeMetrics(name: "fake-node-1", timestamp: now, window: "15s", usage: KubeUsage(cpu: 1.2, memory: 4e9))], allocatable: [:], read: now),
                for: .node("fake-node-1"), asList: false, asDetail: true, sums: [], now: now)
            ring.record(
                KubeMetricsSample(pods: [pod("big", cpu: 0.8, at: now), pod("small", cpu: 0.1, at: now)], read: now),
                for: KubeMetricsDetail.nodeTopPods(node: "fake-node-1", namespaces: ["shop"], pods: ["big", "small"]).target, asList: false, asDetail: true, sums: [],
                parts: [.pods(only: ["big", "small"])], now: now)
        }
        statuses.record(.nodePods("fake-node-1"), ["pods": 12, "cpu": 2.5, "memory": 6e9], at: t0, expected: 300, now: now)
        let facts = KubeNodeFacts(
            allocatable: KubeUsage(cpu: 3.92, memory: 15e9), capacity: KubeUsage(cpu: 4, memory: 16e9), allocatablePods: 58,
            spells: [KubeNodeFacts.Spell(title: "MemoryPressure", since: t0.addingTimeInterval(20))])
        let charts = KubeNodeCharts.build(
            KubeNodeCharts.Input(
                node: "fake-node-1", facts: facts, ring: ring, statuses: statuses, pods: KubeNodePods(pods: [], more: true),
                top: [KubeRowID(namespace: "shop", name: "big"), KubeRowID(namespace: "shop", name: "small")], range: .live, now: now, interval: 15))
        let cpu = try XCTUnwrap(charts.charts.first)
        XCTAssertEqual(cpu.data.references.map(\.role), [.request, .allocatable, .capacity])
        XCTAssertEqual(cpu.data.references.first?.name, "requested")
        XCTAssertEqual(cpu.chips.map(\.text), ["31% of allocatable", "requests 64% of allocatable"])
        XCTAssertEqual(cpu.data.bands.map(\.title), ["MemoryPressure"])
        let pods = try XCTUnwrap(charts.charts.first { $0.data.id.hasSuffix(".pods") })
        XCTAssertEqual(pods.headline, "12 active")
        XCTAssertEqual(pods.data.references.first?.points.last?.value, 58)
        XCTAssertTrue(charts.notes.contains { $0.contains("more than 250 pods") }, "\(charts.notes)")
        let top = try XCTUnwrap(charts.groups.last)
        XCTAssertEqual(top.title, "Top pods (by request)")
        XCTAssertTrue(top.charts.first?.data.stacked ?? false)
        XCTAssertEqual(top.charts.first?.data.usage.map(\.name), ["big", "small"])
        XCTAssertEqual(top.charts.first?.data.usage.first?.points.count, 4, "at the node's own sample times")
    }

    func testANamespaceStacksItsTopWorkloadsAgainstItsQuota() throws {
        var ring = KubeUsageRing()
        let detail = KubeMetricsDetail.namespace("shop")
        var now = t0
        for step in 0..<3 {
            now = t0.addingTimeInterval(Double(step) * 15)
            let pods = (0..<10).map { pod("app\($0)-0", cpu: 0.05 * Double($0 + 1), at: now) }
            ring.record(KubeMetricsSample(pods: pods, read: now), for: detail.target, asList: false, asDetail: true, sums: [detail.sum!], parts: detail.parts, now: now)
        }
        var statuses = KubeStatusHistory()
        statuses.record(.phases("shop"), ["Running": 9, "Pending": 1, "Succeeded": 0, "Failed": 0, "Unknown": 0], at: t0, expected: 60, now: now)
        let charts = KubeNamespaceCharts.build(
            KubeNamespaceCharts.Input(
                namespace: "shop", ring: ring, statuses: statuses, quota: KubeQuota(cpuHard: 4, cpuUsed: 3.8, memoryHard: nil, memoryUsed: nil), byOwner: false,
                range: .live, now: now, interval: 15))
        let cpu = try XCTUnwrap(charts.charts.first)
        XCTAssertTrue(cpu.data.stacked)
        XCTAssertEqual(cpu.data.usage.count, 9, "the top eight and other")
        XCTAssertEqual(cpu.data.usage.first?.name, "app9", "a StatefulSet's name, read off its pod's")
        XCTAssertEqual(cpu.data.usage.last?.points.last?.value ?? 0, 0.15, accuracy: 1e-5)
        XCTAssertEqual(cpu.data.references.map(\.role), [.quota, .guide])
        XCTAssertEqual(cpu.chips.first, KubeChartChip(text: "requests 95% of quota", alert: true))
        XCTAssertTrue(cpu.data.tier?.contains("grouped by name") ?? false)
        let phases = try XCTUnwrap(charts.charts.first { $0.data.id.hasSuffix(".phases") })
        XCTAssertEqual(phases.data.usage.map(\.name), ["Running", "Pending"], "phases with none left out")
        XCTAssertTrue(phases.data.stacked && phases.data.stepped)
        XCTAssertTrue(charts.notes.contains { $0.hasPrefix("Grouped by the pods' names") })
    }

    func testBandsAndSteppedLinesArePlotted() {
        let data = KubeChartBuild.data(
            id: "x", title: "Replicas", unit: .count,
            series: [KubeChartSeries(id: "n", name: "n", points: [KubeSeriesPoint(time: t0, value: 1), KubeSeriesPoint(time: t0.addingTimeInterval(60), value: 3)])],
            start: t0, end: t0.addingTimeInterval(120), step: 15, source: "s", tier: nil, breaksMarked: true,
            bands: [KubeChartBand(id: "b", title: "Cordoned", start: t0.addingTimeInterval(-60), end: t0.addingTimeInterval(60))], stepped: true)
        let plot = KubePlot(data, size: CGSize(width: 240, height: 100))
        XCTAssertEqual(plot.bands.count, 1)
        XCTAssertEqual(plot.bands[0].minX, plot.frame.minX, accuracy: 0.5, "clipped to the window")
        XCTAssertEqual(plot.bands[0].maxX, plot.x(of: t0.addingTimeInterval(60)), accuracy: 0.5)
        XCTAssertTrue(KubeChartSummary.dump(data, plot: plot).contains("bands=[Cordoned]"))
    }

    func testASteppedChartsFillStepsWithItsLine() throws {
        let points = [KubeSeriesPoint(time: t0, value: 1), KubeSeriesPoint(time: t0.addingTimeInterval(60), value: 3)]
        let data = KubeChartBuild.data(
            id: "x", title: "Pods", unit: .count, series: [KubeChartSeries(id: "n", name: "n", points: points)], start: t0, end: t0.addingTimeInterval(120),
            step: 15, source: "s", tier: nil, breaksMarked: true, stepped: true)
        let plot = KubePlot(data, size: CGSize(width: 240, height: 100))
        let fill = try XCTUnwrap(plot.lines.first?.fill?.cgPath, "one series: filled")
        let middle = plot.x(of: t0.addingTimeInterval(30))
        XCTAssertTrue(fill.contains(CGPoint(x: middle, y: plot.y(of: 0.5))), "under the held value")
        XCTAssertFalse(fill.contains(CGPoint(x: middle, y: plot.y(of: 1.8))), "above it: no slope filled")

        // Stacked: each band's top and bottom step too.
        let stacked = KubeChartBuild.data(
            id: "y", title: "Pods by phase", unit: .count,
            series: [
                KubeChartSeries(id: "a", name: "Running", points: points),
                KubeChartSeries(id: "b", name: "Pending", points: points.map { KubeSeriesPoint(time: $0.time, value: 1) }),
            ], start: t0, end: t0.addingTimeInterval(120), step: 15, stacked: true, source: "s", tier: nil, breaksMarked: true, stepped: true)
        let stackedPlot = KubePlot(stacked, size: CGSize(width: 240, height: 100))
        let upper = try XCTUnwrap(stackedPlot.lines.first { $0.id == "b" }?.fill?.cgPath)
        XCTAssertTrue(upper.contains(CGPoint(x: middle, y: stackedPlot.y(of: 1.5))), "between 1 and 2, held")
        XCTAssertFalse(upper.contains(CGPoint(x: middle, y: stackedPlot.y(of: 2.6))), "the slope to 4 isn't filled")
        XCTAssertFalse(upper.contains(CGPoint(x: middle, y: stackedPlot.y(of: 0.6))), "nor the band under it")
    }

    func testANodesTopPodsAreThoseItsSamplingReads() {
        let pods = KubeNodePods(
            pods: (0..<6).map { index in
                KubeNodePods.Pod(id: KubeRowID(namespace: "ns-\(index)", name: "p-\(index)"), phase: "Running", cpuRequest: Double(10 - index), memoryRequest: 0)
            }, more: false)
        let picked = KubernetesPageModel.topPodsPicked(pods)
        XCTAssertEqual(picked.map(\.name), ["p-0", "p-1", "p-2", "p-3"], "a fifth namespace's pod isn't sampled, so isn't drawn")
    }

    // MARK: Over the fake

    private var api: FakeKubeAPI!
    private var socket: String!

    override func tearDown() async throws {
        api?.stop()
        api = nil
    }

    private func until(_ timeout: TimeInterval = 5, _ what: String = "", _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func pageOverFake(metricsServer: Bool = true, settings: KubeContextSettings = KubeContextSettings()) throws -> (KubernetesModel, KubernetesPageModel) {
        socket = "/tmp/otkc-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.metricsServer = metricsServer
        api.addNamespace("shop")
        api.add(
            "deployments.apps", "web", namespace: "shop", values: ["Ready": "2/2"],
            fields: [
                "spec": [
                    "replicas": 2, "selector": ["matchLabels": ["app": "web"]],
                    "template": ["spec": ["containers": [["name": "app", "resources": ["requests": ["cpu": "100m", "memory": "64Mi"]]]]]],
                ],
                "status": ["replicas": 2, "availableReplicas": 2],
            ])
        api.add(
            "horizontalpodautoscalers.autoscaling", "web", namespace: "shop", values: ["Reference": "Deployment/web"],
            fields: [
                "spec": ["minReplicas": 2, "maxReplicas": 6, "metrics": [["type": "Resource", "resource": ["name": "cpu", "target": ["averageUtilization": 70]]]]],
                "status": [
                    "currentReplicas": 2, "desiredReplicas": 2,
                    "currentMetrics": [["type": "Resource", "resource": ["name": "cpu", "current": ["averageUtilization": 40]]]],
                ],
            ])
        for name in ["web-7d9f8b6c5d-x2k4q", "web-7d9f8b6c5d-z4m5r"] {
            api.addPod(name, namespace: "shop", labels: ["app": "web", "pod-template-hash": "7d9f8b6c5d"])
            api.setPodMetrics(name, namespace: "shop", [("app", "40m", "50Mi")], labels: ["app": "web", "pod-template-hash": "7d9f8b6c5d"])
        }
        api.add(
            "nodes", "fake-node-1",
            fields: ["status": ["allocatable": ["cpu": "4", "memory": "16Gi", "pods": "58"], "capacity": ["cpu": "4", "memory": "16Gi", "pods": "58"]]])
        api.setNodeMetrics("fake-node-1", cpu: "900m", memory: "6Gi")
        let model = KubernetesModel(proxies: KubeProxies())
        let context = KubeContext(
            name: "fake-dev", cluster: "fake-dev", server: "http://127.0.0.1:1", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: .remote, settings: settings)
        model.load = { _ in KubeContextList(contexts: [context], current: "fake-dev") }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.flushInterval = .milliseconds(20)
        model.statusInterval = .milliseconds(50)
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
        model.statusOverride = { _ in .open }
        model.metrics.interval = .milliseconds(100)
        return (model, KubernetesPageModel(model: model))
    }

    func testEachTabReadsWhatItChartsOnlyWhileItShows() async throws {
        let (model, page) = try pageOverFake()
        model.show()
        defer { model.hide() }
        page.visible = true
        try await until(5, "listed, metrics-server served") { model.discovery != nil && model.metrics.availability == .served }
        let deployments = try XCTUnwrap(model.discovery?.kind("deployments"))
        page.showKind(deployments)
        try await until(5, "deployments listed") { model.kind.fullName == "deployments.apps" && model.rows.count == 1 }
        page.selection = ["shop/web"]
        XCTAssertTrue(page.press("m"), "m: the Deployment's Metrics tab")
        XCTAssertEqual(page.detailTab, .metrics)
        try await until(5, "its HPA found, its pods and its object polled") {
            page.metricsDetailsOnScreen.contains(.hpa(namespace: "shop", name: "web"))
                && model.metrics.reading(.workload(namespace: "shop", kind: "Deployment", name: "web", labels: "app=web"))?.sample?.pods.count == 2
        }
        XCTAssertTrue(api.requests.contains { $0.path == "/apis/metrics.k8s.io/v1beta1/namespaces/shop/pods" && $0.query["labelSelector"] == "app=web" })
        XCTAssertTrue(api.requests.contains { $0.path == "/apis/apps/v1/namespaces/shop/deployments/web" })
        XCTAssertEqual(api.requests.filter { $0.path == "/apis/autoscaling/v2/namespaces/shop/horizontalpodautoscalers" }.count, 1, "the HPA looked up once")
        try await until(5, "its charts drawn") {
            guard let detail = page.detail, let charts = page.objectCharts(of: detail) else { return false }
            return charts.groups.map(\.title) == ["Deployment", "Autoscaler web"] && charts.charts.first?.data.usage.first?.points.isEmpty == false
        }
        XCTAssertEqual(page.detailKubectl, "kubectl --context fake-dev -n shop top pods -l app=web")
        // Built once for one reading, however often the tab's body runs.
        let builds = page.objectChartsBuilds
        for _ in 0..<10 { _ = page.detail.flatMap { page.objectCharts(of: $0) } }
        XCTAssertLessThanOrEqual(page.objectChartsBuilds - builds, 1)

        // Another tab: nothing read.
        page.showTab(.overview)
        try await until(5, "polling stopped") { !model.metrics.isPolling }
        api.forgetRequests()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(api.requests.contains { $0.path.hasPrefix("/apis/metrics.k8s.io") || $0.path.contains("horizontalpodautoscalers") }, "\(api.requests.map(\.path))")
        XCTAssertTrue(api.writes.isEmpty)
    }

    func testANodesTabReadsItsPodsAsObjectsAndItsTopPodsOnRequest() async throws {
        let (model, page) = try pageOverFake()
        model.show()
        defer { model.hide() }
        page.visible = true
        try await until(5, "discovery read") { model.discovery != nil && model.metrics.availability == .served }
        let nodes = try XCTUnwrap(model.discovery?.kind("nodes"))
        page.showKind(nodes)
        try await until(5, "nodes listed") { model.kind.fullName == "nodes" && model.rows.count == 1 }
        page.selection = ["fake-node-1"]
        XCTAssertTrue(page.press("m"))
        try await until(5, "its pods read as objects") { model.metrics.reading(.nodePods("fake-node-1"))?.sample?.nodePods?.pods.count == 2 }
        XCTAssertTrue(
            api.requests.contains { $0.path == "/api/v1/pods" && $0.query["fieldSelector"] == "spec.nodeName=fake-node-1" && $0.query["limit"] == "250" },
            "\(api.requests.map(\.path))")
        XCTAssertTrue(api.requests.contains { $0.path == "/apis/metrics.k8s.io/v1beta1/nodes/fake-node-1" })
        XCTAssertFalse(api.requests.contains { $0.path.contains("nodes/fake-node-1/proxy") }, "never the kubelet")
        XCTAssertFalse(model.metrics.targets.contains { if case .podsOn = $0 { true } else { false } }, "top pods only on request")
        page.topPodsDuration = .milliseconds(600)
        page.sampleTopPods()
        try await until(5, "its largest pods' namespace sampled") {
            model.metrics.targets.contains(.podsOn(node: "fake-node-1", namespaces: ["shop"]))
        }
        try await until(5, "stopped after its time") { page.topPodsSampling?.stopped == true && !model.metrics.targets.contains { if case .podsOn = $0 { true } else { false } } }
        XCTAssertEqual(page.topPodsTitle, "Sample Again")
        XCTAssertEqual(page.detailKubectl, "kubectl --context fake-dev top node fake-node-1")
    }

    /// Reads on a tab that draws nothing, from `since` on: what metrics.md
    /// 6.2 says a tab never does.
    private func uncharted(since: Int) -> [String] {
        api.requests.dropFirst(since).compactMap { request in
            let said = request.path + "?" + request.query.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "&")
            let read =
                request.path.hasPrefix("/apis/metrics.k8s.io") || request.path.contains("horizontalpodautoscalers")
                || request.path.contains("replicasets") || request.path.contains("controllerrevisions") || request.path.contains("resourcequotas")
                || (request.path == "/api/v1/pods" && request.query["fieldSelector"] != nil) || said.contains("includeObject=Metadata")
            return read ? said : nil
        }
    }

    /// Opens `selection`'s Metrics tab in `kind`'s list, its object read; the requests' count then.
    private func openMetricsTab(_ model: KubernetesModel, _ page: KubernetesPageModel, kind: String, selection: String) async throws -> Int {
        let shown = try XCTUnwrap(model.discovery?.kind(kind))
        page.showKind(shown)
        try await until(5, "\(kind) listed") { model.kind.fullName == shown.fullName && model.rows.count >= 1 }
        page.selection = [selection]
        XCTAssertTrue(page.press("m"), "m: \(selection)'s Metrics tab")
        XCTAssertEqual(page.detailTab, .metrics)
        try await until(5, "its object read") { page.detail?.object != nil }
        return api.requests.count
    }

    func testWithoutMetricsServerOnlyWhatIsChartedIsRead() async throws {
        let (model, page) = try pageOverFake(metricsServer: false)
        model.show()
        defer { model.hide() }
        page.visible = true
        try await until(5, "discovery read: no metrics-server") { model.discovery != nil && model.metrics.availability == .absent }
        for (kind, selection) in [("deployments", "shop/web"), ("nodes", "fake-node-1"), ("namespaces", "shop")] {
            let since = try await openMetricsTab(model, page, kind: kind, selection: selection)
            XCTAssertEqual(page.metricsDetailsOnScreen, [], "\(selection): nothing to chart, nothing polled")
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(uncharted(since: since), [], "\(selection)")
            XCTAssertFalse(
                api.requests.dropFirst(since).contains { $0.path.hasPrefix("/apis/apps") && $0.query["watch"] == nil }, "\(selection): no replicas polled")
            XCTAssertEqual(page.detail.flatMap { page.objectMetricsProblem(of: $0) }, KubernetesPageModel.metricsServerAbsent(prometheus: false))
            XCTAssertTrue(page.chartLookups.asked.isEmpty, "nothing looked up: asked again once metrics-server serves")
        }
        XCTAssertTrue(api.writes.isEmpty)
    }

    func testWithTheContextsMetricsOffNothingIsLookedUp() async throws {
        let (model, page) = try pageOverFake(settings: KubeContextSettings(metrics: KubeMetricsSource.none))
        model.show()
        defer { model.hide() }
        page.visible = true
        try await until(5, "discovery read, metrics off") { model.discovery != nil && model.metrics.availability == .off }
        for (kind, selection) in [("deployments", "shop/web"), ("namespaces", "shop")] {
            let since = try await openMetricsTab(model, page, kind: kind, selection: selection)
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(uncharted(since: since), [], "\(selection): no HPA, revisions or quota read")
            XCTAssertTrue(page.chartLookups.asked.isEmpty)
        }
        XCTAssertTrue(api.writes.isEmpty)
    }

    // MARK: Markers (M4)

    func testAWorkloadsTabMarksItsPodsRestartsFromABoundedReadWhileItShows() async throws {
        let (model, page) = try pageOverFake()
        page.podStatesInterval = .milliseconds(200)
        model.show()
        defer { model.hide() }
        page.visible = true
        try await until(5, "listed, metrics-server served") { model.discovery != nil && model.metrics.availability == .served }
        let since = try await openMetricsTab(model, page, kind: "deployments", selection: "shop/web")
        let statesRead = { (request: FakeKubeAPI.Request) in
            request.path == "/api/v1/namespaces/shop/pods" && request.query["labelSelector"] == "app=web" && request.query["limit"] == "250"
        }
        try await until(5, "its pods' states read by its selector, bounded") { self.api.requests.dropFirst(since).contains(where: statesRead) }
        try await until(5, "two pods' states") { page.podStates?.log.states?.pods.count == 2 }
        let finished = Date().addingTimeInterval(-30)
        api.updatePod("web-7d9f8b6c5d-x2k4q", namespace: "shop") {
            $0.restarts = 1
            $0.lastReason = "OOMKilled"
            $0.lastExitCode = 137
            $0.lastFinished = finished
        }
        try await until(5, "the OOMKill marked on its memory, named by its pod") {
            guard let detail = page.detail, let charts = page.objectCharts(of: detail),
                let memory = charts.charts.first(where: { $0.data.id.hasSuffix("deployment.web.memory") })
            else { return false }
            return memory.data.shownMarkers.contains { $0.kind == .oom && $0.title.hasPrefix("web-7d9f8b6c5d-x2k4q/app: OOMKilled") }
        }
        XCTAssertEqual(page.podStates?.log.restarts.map(\.container), ["app"], "the restart seen between two reads")
        XCTAssertTrue(api.requests.contains { $0.path == "/apis/apps/v1/namespaces/shop/replicasets" }, "its History, as the History tab reads it")

        // The marker opens the pod's previous log.
        let marker = try XCTUnwrap(
            page.detail.flatMap { page.objectCharts(of: $0) }?.charts.flatMap(\.data.shownMarkers).first { $0.kind == .oom })
        page.openMarker(marker)
        XCTAssertEqual(page.detail?.ref.name, "web-7d9f8b6c5d-x2k4q")
        XCTAssertEqual(page.detailTab, .logs)
        try await until(5, "its app container's previous log") { page.detail?.logs?.container == "app" && page.detail?.logs?.previous == true }
        XCTAssertNil(page.podStates?.log.states?.pods.first { $0.name == "web-7d9f8b6c5d-z4m5r" }, "another detail: the workload's states dropped")

        // Hidden: not read.
        page.goBack()
        page.showTab(.metrics)
        page.visible = false
        try await Task.sleep(for: .milliseconds(100))
        api.forgetRequests()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(api.requests.contains(where: statesRead), "\(api.requests.map(\.path))")
        XCTAssertTrue(api.writes.isEmpty)
    }

    func testThePodsStatesReadStopsAtItsBoundAndAtA403AndSaysSo() async throws {
        let (model, page) = try pageOverFake()
        page.podStatesInterval = .milliseconds(200)
        page.podStatesMaxBytes = 1024
        model.show()
        defer { model.hide() }
        page.visible = true
        try await until(5, "listed, metrics-server served") { model.discovery != nil && model.metrics.availability == .served }
        let statesRead = { (request: FakeKubeAPI.Request) in
            request.path == "/api/v1/namespaces/shop/pods" && request.query["labelSelector"] == "app=web" && request.query["limit"] == "250"
        }
        _ = try await openMetricsTab(model, page, kind: "deployments", selection: "shop/web")
        try await until(5, "past its bound: stopped, said") { page.podStates?.stopped == true }
        XCTAssertNil(page.podStates?.log.states, "nothing past the bound is decoded")
        let said = KubePodStates.tooLarge(limit: 1024)
        XCTAssertTrue(said.contains("1 KB"), said)
        try await until(5, "said under the charts") {
            guard let detail = page.detail, let charts = page.objectCharts(of: detail) else { return false }
            return charts.notes.contains { $0.hasSuffix(said) }
        }
        api.forgetRequests()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(api.requests.contains(where: statesRead), "not asked again in a loop")

        // Within the bound, then refused: stopped at the 403, said once.
        page.closeDetail()
        page.podStatesMaxBytes = KubePodStates.maxBytes
        _ = try await openMetricsTab(model, page, kind: "deployments", selection: "shop/web")
        try await until(5, "two pods' states") { page.podStates?.log.states?.pods.count == 2 }
        api.forbidden = ["pods@shop"]
        defer { api.forbidden = [] }
        try await until(5, "refused: stopped") { page.podStates?.stopped == true }
        XCTAssertTrue(page.podStates?.problem?.hasPrefix("Not allowed") == true, "\(page.podStates?.problem ?? "nil")")
        XCTAssertEqual(page.podStates?.log.states?.pods.count, 2, "what was read stands")
        api.forgetRequests()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(api.requests.contains(where: statesRead), "a 403 isn't asked again")
        XCTAssertTrue(api.writes.isEmpty)
    }

    func testAMarkersWindowNarrowsTheChartsUntilReset() async throws {
        let (model, page) = try pageOverFake()
        model.show()
        defer { model.hide() }
        page.visible = true
        try await until(5, "listed, metrics-server served") { model.discovery != nil && model.metrics.availability == .served }
        api.addEvent(
            about: "horizontalpodautoscalers.autoscaling", "web", namespace: "shop", type: "Normal", reason: "SuccessfulRescale", message: "New size: 3", component: "horizontal-pod-autoscaler")
        _ = try await openMetricsTab(model, page, kind: "horizontalpodautoscalers", selection: "shop/web")
        try await until(5, "its events read once, its rescale marked") {
            guard let detail = page.detail, let charts = page.objectCharts(of: detail) else { return false }
            return charts.charts.first?.data.shownMarkers.map(\.kind) == [.scale]
        }
        XCTAssertEqual(api.requests.filter { $0.path == "/api/v1/namespaces/shop/events" }.count, 1, "asked once")
        let marker = try XCTUnwrap(page.detail.flatMap { page.objectCharts(of: $0) }?.charts.first?.data.shownMarkers.first)
        page.showAround(marker)
        let window = try XCTUnwrap(page.metricsWindow)
        XCTAssertLessThanOrEqual(window.end.timeIntervalSince(marker.time), 1800)
        let narrowed = try XCTUnwrap(page.detail.flatMap { page.objectCharts(of: $0) })
        XCTAssertEqual(narrowed.charts.first?.data.start, window.start)
        XCTAssertTrue(narrowed.caption.contains("Custom \(window.title)") || !narrowed.hasSamples, narrowed.caption)
        XCTAssertTrue(page.press("\u{1B}"), "Esc: the window goes first")
        XCTAssertNil(page.metricsWindow)
        XCTAssertNotNil(page.detail, "the detail stays")
        page.showAround(marker)
        page.pickMetricsRange(.live)
        XCTAssertNil(page.metricsWindow, "a range picked: the window goes")
        page.openMarker(marker)
        XCTAssertEqual(page.detailTab, .events)
        XCTAssertEqual(page.markedEntry, "event/\(marker.id.dropFirst("event/".count))")
        XCTAssertTrue(api.writes.isEmpty)
    }
}
