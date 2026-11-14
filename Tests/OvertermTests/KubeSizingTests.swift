import Foundation
import XCTest

@testable import Overterm

/// Rightsizing's queries and card (docs/design/kubernetes/metrics.md 2.10,
/// 4.6's R1; stage M10): per pod, never the workload's sum; memory from the
/// max; an OOMKill in the window said; the bounds — a raw workload's pods
/// counted, past 50 refused, recording rules with no subquery — and the
/// retention. Pure.
final class KubeSizingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// The prometheus chart: no rules, a minute's scrape, kube-state-metrics' owners.
    private var raw: KubePromProfile {
        var profile = KubePromProfile(probed: now)
        profile.metrics = [
            "container_cpu_usage_seconds_total": 9000, "container_memory_working_set_bytes": 9000, "kube_pod_owner": 3000, "kube_replicaset_owner": 900,
            "kube_pod_container_resource_requests": 8000, "kube_pod_status_phase": 9000, "kube_pod_container_status_last_terminated_reason": 500,
            "kube_pod_container_status_restarts_total": 500, "kube_pod_info": 3000,
        ]
        profile.scrape = 60
        profile.retention = now.addingTimeInterval(-15 * 86400)
        return profile
    }

    /// kube-prometheus-stack: the mixin's rules besides.
    private var rules: KubePromProfile {
        var profile = raw
        profile.metrics?[KubePromProfile.containerCPURate5m] = 4000
        profile.metrics?[KubePromProfile.containerMemoryRule] = 4000
        profile.metrics?[KubePromProfile.workloadRule] = 3000
        profile.scrape = 30
        return profile
    }

    private let api = KubeSizingSubject.workload(namespace: "shop", kind: "Deployment", name: "api")

    private func query(_ plan: KubeSizingPlan, _ measure: KubeSizingMeasure) -> String? { plan.queries.first { $0.id == measure.rawValue }?.promql }

    private func pods(_ count: Int) -> [String] { (0..<count).map { "api-7d9fc-\(String(format: "%05d", $0))" } }

    func testARawWorkloadIsCountedFirstThenSizedPerPod() throws {
        let first = KubeSizing.plan(api, profile: raw, now: now)
        XCTAssertTrue(first.queries.isEmpty, "nothing sized before its pods are listed")
        let count = try XCTUnwrap(first.count?.promql)
        XCTAssertTrue(count.hasPrefix("max by (namespace,pod)(label_replace(max_over_time(kube_pod_owner{"), "a series a pod, by name: \(count)")
        XCTAssertTrue(count.contains(#"max_over_time(kube_replicaset_owner{namespace="shop",owner_kind="Deployment",owner_name="api"}[168h])"#), count)
        XCTAssertFalse(count.contains("container_"), "listed from kube-state-metrics, never cAdvisor's week: \(count)")

        let plan = KubeSizing.plan(api, profile: raw, now: now, pods: ["api-7d9fc-x2b4q", "api-7d9fc-zz9k2"])
        XCTAssertNil(plan.refused)
        XCTAssertEqual(plan.tier, .raw)
        XCTAssertEqual(plan.window, 7 * 86400)
        XCTAssertEqual(plan.queries.map(\.id), ["cpu50", "cpu95", "cpuMax", "memory95", "memoryMax", "oom"])
        XCTAssertTrue(plan.queries.allSatisfy(\.instant))
        let p95 = try XCTUnwrap(query(plan, .cpu95))
        // Each pod's own rate, its quantile over the week, then the highest pod's — never a sum across pods.
        XCTAssertTrue(
            p95.hasPrefix(
                "max by (container)(quantile_over_time(0.95, (sum by (namespace,pod,container)(rate(container_cpu_usage_seconds_total{container!=\"\",image!=\"\",container!=\"POD\",namespace=\"shop\",pod=~\"api-7d9fc-x2b4q|api-7d9fc-zz9k2\"}[5m])))[168h:5m]))"
            ), p95)
        for promql in plan.queries.map(\.promql) {
            XCTAssertTrue(promql.hasPrefix("max by (container)("), promql)
            XCTAssertFalse(promql.contains("sum("), "no sum across the workload's pods: \(promql)")
            XCTAssertFalse(promql.contains("sum by (container)"), promql)
        }
        XCTAssertTrue(try XCTUnwrap(query(plan, .cpu50)).contains("quantile_over_time(0.5, "))
        XCTAssertTrue(try XCTUnwrap(query(plan, .cpuMax)).contains("max_over_time((sum by (namespace,pod,container)(rate("))
        // Memory's max needs no subquery: every sample's highest, a series, then the pod's.
        let memoryMax = try XCTUnwrap(query(plan, .memoryMax))
        XCTAssertTrue(memoryMax.contains("max by (namespace,pod,container)(max_over_time(container_memory_working_set_bytes{"), memoryMax)
        XCTAssertFalse(memoryMax.contains(":5m]"), memoryMax)
        XCTAssertTrue(try XCTUnwrap(query(plan, .memory95)).contains("quantile_over_time(0.95, (max by (namespace,pod,container)(container_memory_working_set_bytes{"))
        let oom = try XCTUnwrap(query(plan, .oom))
        XCTAssertTrue(oom.contains(#"kube_pod_container_status_last_terminated_reason{reason="OOMKilled",namespace="shop",pod=~"api-7d9fc-x2b4q|api-7d9fc-zz9k2"}"#), oom)
        XCTAssertTrue(
            oom.contains(
                #"and on(namespace,pod,container) (max by (namespace,pod,container)(increase(kube_pod_container_status_restarts_total{namespace="shop",pod=~"api-7d9fc-x2b4q|api-7d9fc-zz9k2"}[168h])) > 0)"#
            ), "only a container that restarted in the window ended in it: \(oom)")
    }

    /// api has 2 pods, api-gateway 500 beside it: the prefix `api-.+` matches
    /// both, so the subqueries read the listed pods by name — never the prefix,
    /// which the owner join would only filter after the week was read.
    func testASiblingThatSharesThePrefixIsNeverInTheSubquery() throws {
        let plan = KubeSizing.plan(api, profile: raw, now: now, pods: ["api-7d9fc-x2b4q", "api-7d9fc-zz9k2"])
        XCTAssertEqual(plan.queries.count, 6)
        for promql in plan.queries.map(\.promql) {
            XCTAssertFalse(promql.contains(#"pod=~"api-.+""#), "no prefix in a subquery: \(promql)")
            XCTAssertFalse(promql.contains("group_left"), "the names are the selection: \(promql)")
            XCTAssertFalse(promql.contains("api-gateway"), promql)
        }
        // An escaped name stays one name.
        let odd = KubeSizing.plan(api, profile: raw, now: now, pods: ["api-1.a"])
        XCTAssertTrue(try XCTUnwrap(query(odd, .cpu95)).contains(#"pod=~"api-1\\.a""#))
    }

    func testNoPodsListedIsRefusedNotSizedAsZero() throws {
        let plan = KubeSizing.plan(api, profile: raw, now: now, pods: [])
        XCTAssertTrue(plan.queries.isEmpty, "no subquery without the pods it reads")
        XCTAssertEqual(plan.refused, KubeSizing.noPods)
    }

    func testARawWorkloadPastFiftyPodsIsRefusedAndSaysWhy() throws {
        let plan = KubeSizing.plan(api, profile: raw, now: now, pods: pods(51))
        XCTAssertTrue(plan.queries.isEmpty)
        let why = try XCTUnwrap(plan.refused)
        XCTAssertTrue(why.hasPrefix("Sizing reads each of its 51 pods' 7 days in a subquery"), why)
        XCTAssertTrue(why.contains("at most 50 pods, or one of its pods"), why)
        XCTAssertNil(KubeSizing.plan(api, profile: raw, now: now, pods: pods(50)).refused, "fifty are sized")
    }

    func testRecordingRulesNeedNoSubqueryAndNoCount() throws {
        let plan = KubeSizing.plan(api, profile: rules, now: now)
        XCTAssertNil(plan.count, "no subquery: nothing to count")
        XCTAssertNil(plan.refused)
        XCTAssertEqual(plan.tier, .rules)
        XCTAssertEqual(plan.selection, .rule)
        for promql in plan.queries.map(\.promql) { XCTAssertFalse(promql.contains(":5m]"), "no subquery: \(promql)") }
        XCTAssertEqual(
            query(plan, .cpu95),
            "max by (container)((max by (namespace,pod,container)(quantile_over_time(0.95, \(KubePromProfile.containerCPURate5m){namespace=\"shop\",pod=~\"api-.+\",container!=\"\",container!=\"POD\"}[168h]))) * on(namespace,pod) group_left() max by (namespace,pod)(max_over_time(\(KubePromProfile.workloadRule){namespace=\"shop\",workload=\"api\",workload_type=\"deployment\"}[168h])))"
        )
        XCTAssertTrue(try XCTUnwrap(query(plan, .memoryMax)).contains("max_over_time(\(KubePromProfile.containerMemoryRule){"))
    }

    func testAPodIsOneScopeWithNoOwnersAndNoCount() throws {
        let plan = KubeSizing.plan(.pod(namespace: "shop", name: "web-\"1"), profile: raw, now: now)
        XCTAssertNil(plan.count)
        XCTAssertNil(plan.selection)
        XCTAssertEqual(plan.queries.count, 6)
        for promql in plan.queries.map(\.promql) {
            XCTAssertTrue(promql.contains(#"namespace="shop",pod="web-\"1""#), "escaped: \(promql)")
            XCTAssertFalse(promql.contains("group_left"), promql)
        }
    }

    func testTheWindowIsWhatPrometheusKeeps() throws {
        var short = raw
        short.retention = now.addingTimeInterval(-2 * 86400 - 1800)
        let plan = KubeSizing.plan(.pod(namespace: "shop", name: "web-1"), profile: short, now: now)
        XCTAssertEqual(plan.window, 2 * 86400, "in whole hours")
        XCTAssertTrue(try XCTUnwrap(query(plan, .cpu95)).contains("[48h:5m]"))
        XCTAssertEqual(KubeSizing.said(window: plan.window), "2 days (what Prometheus keeps)")
        XCTAssertEqual(KubeSizing.said(window: 7 * 86400), "7 days")
        XCTAssertEqual(KubeSizing.said(window: 18 * 3600), "18 hours (what Prometheus keeps)")
        var unknown = raw
        unknown.retention = nil
        XCTAssertEqual(KubeSizing.plan(.pod(namespace: "shop", name: "web-1"), profile: unknown, now: now).window, 7 * 86400, "unknown: a week")
        var young = raw
        young.retention = now.addingTimeInterval(-1800)
        let refused = KubeSizing.plan(.pod(namespace: "shop", name: "web-1"), profile: young, now: now)
        XCTAssertTrue(refused.queries.isEmpty)
        XCTAssertEqual(refused.refused, "Prometheus keeps less than an hour here: there is nothing to size from yet.")
    }

    func testNoKubeStateMetricsNoOOMQueryAndPodsByName() throws {
        var bare = raw
        for name in ["kube_pod_owner", "kube_replicaset_owner", "kube_pod_container_resource_requests", "kube_pod_status_phase", "kube_pod_container_status_last_terminated_reason"] {
            bare.metrics?[name] = nil
        }
        bare.metrics?["kube_pod_info"] = nil
        let first = KubeSizing.plan(api, profile: bare, now: now)
        XCTAssertEqual(first.selection, .name)
        let listed = try XCTUnwrap(first.count?.promql)
        // Without kube-state-metrics: the last hour's cAdvisor, never the week's, and said.
        XCTAssertTrue(listed.hasPrefix("max by (namespace,pod)(last_over_time(container_cpu_usage_seconds_total{"), listed)
        XCTAssertTrue(listed.hasSuffix("[1h]))"), listed)
        XCTAssertFalse(listed.contains("168h"), listed)
        XCTAssertEqual(first.notes, [KubeSizing.recentNote])
        let plan = KubeSizing.plan(api, profile: bare, now: now, pods: ["api-7d9fc-x2b4q", "api-7d9fc-zz9k2", "api-7d9fc-q4n8w"])
        XCTAssertNil(query(plan, .oom))
        XCTAssertEqual(plan.queries.count, 5)
        XCTAssertTrue(plan.queries.allSatisfy { !$0.promql.contains("group_left") }, "the names are the selection")
    }

    /// kube-state-metrics without its owners: the pods by name pattern from
    /// `kube_pod_info` — a series a pod — never the week's raw samples.
    func testPodsByNameAreListedFromKubeStateMetricsInfo() throws {
        var noOwners = raw
        noOwners.metrics?["kube_pod_owner"] = nil
        let first = KubeSizing.plan(api, profile: noOwners, now: now)
        XCTAssertEqual(first.selection, .name)
        let listed = try XCTUnwrap(first.count?.promql)
        XCTAssertTrue(listed.hasPrefix("max by (namespace,pod)(max_over_time(kube_pod_info{"), listed)
        XCTAssertTrue(listed.contains(#"namespace="shop",pod=~""#), listed)
        XCTAssertFalse(listed.contains("container_"), listed)
        XCTAssertTrue(first.notes.isEmpty)
    }

    func testFiguresAreTheHighestPodsAContainer() {
        func series(_ container: String, _ value: Double) -> KubeSeries {
            KubeSeries(labels: ["container": container], points: [KubeSeriesPoint(time: now, value: value)])
        }
        let figures = KubeSizing.figures([
            .cpu95: [series("app", 0.21), series("sidecar", 0.01)], .cpu50: [series("app", 0.11)], .cpuMax: [series("app", 0.48)],
            .memory95: [series("app", 400 * 1_048_576)], .memoryMax: [series("app", 509 * 1_048_576), series("", 1)], .oom: [series("app", 1)],
        ])
        XCTAssertEqual(figures.map(\.container), ["app", "sidecar"])
        XCTAssertEqual(figures[0].cpu95, 0.21)
        XCTAssertTrue(figures[0].lastOOMKilled)
        XCTAssertNil(figures[1].memoryMax)
    }

    func testTheCardSuggestsCPUFromP95AndMemoryFromTheMax() throws {
        let mi = 1_048_576.0
        var reading = KubeSizingReading(request: KubeSizingRequest(context: "fake-dev", subject: api, asked: now))
        reading.window = 7 * 86400
        reading.tier = .raw
        reading.selection = .owner
        reading.done = true
        reading.figures = [KubeSizingFigures(container: "app", cpu50: 0.11, cpu95: 0.21, cpuMax: 0.48, memory95: 498 * mi, memoryMax: 509 * mi)]
        let spec = KubePodCharts.Container(name: "app", cpuRequest: 1, cpuLimit: nil, memoryRequest: 256 * mi, memoryLimit: 512 * mi)
        let card = KubeSizingCard.of(reading, containers: [spec], oomKilled: [:], now: now)
        XCTAssertEqual(card.title, "Sizing · 7 days · per pod · raw cAdvisor · by owner")
        let row = try XCTUnwrap(card.rows.first)
        XCTAssertEqual(row.cpu?.bars.map(\.text), ["110m", "210m", "480m"])
        XCTAssertEqual(row.cpu?.suggestion, "suggested request ≈ p95 × 1.15 = 245m", "241.5m, up to 5m")
        XCTAssertEqual(row.cpu?.now, "now: request 1000m · limit none")
        XCTAssertEqual(row.memory?.bars.map(\.label), ["p95", "max"])
        XCTAssertEqual(row.memory?.suggestion, "suggested request and limit ≈ max × 1.15 = 586Mi", "from the max, not the p95")
        XCTAssertEqual(row.memory?.request, 256 * mi)
        XCTAssertEqual(row.memory?.limit, 512 * mi)
        XCTAssertNil(row.note)
        XCTAssertEqual(row.cpu?.scale, 1, "the request the widest")
        XCTAssertTrue(card.summary[0].hasPrefix("app: CPU p50 110m, p95 210m, max 480m, suggested request"), card.summary[0])
    }

    func testAnOOMKillInTheWindowIsSaid() throws {
        var reading = KubeSizingReading(request: KubeSizingRequest(context: "fake-dev", subject: api, asked: now))
        reading.window = 7 * 86400
        reading.done = true
        reading.figures = [KubeSizingFigures(container: "app", cpu95: 0.2, memoryMax: 100 * 1_048_576)]
        let killed = now.addingTimeInterval(-3600)
        let card = KubeSizingCard.of(reading, containers: [], oomKilled: ["app": killed], now: now)
        XCTAssertEqual(card.rows.first?.note, "OOMKilled at \(KubeSizing.time(killed, now: now)); the max understates the need.")
        let old = KubeSizingCard.of(reading, containers: [], oomKilled: ["app": now.addingTimeInterval(-8 * 86400)], now: now)
        XCTAssertNil(old.rows.first?.note, "before the window: not this week's max")
        reading.figures[0].lastOOMKilled = true
        let ksm = KubeSizingCard.of(reading, containers: [], oomKilled: [:], now: now)
        XCTAssertEqual(ksm.rows.first?.note, "A pod's last end was OOMKilled; the max understates the need.")
        // The objects date it before the window: kube-state-metrics' untimed flag doesn't bring it back.
        let dated = KubeSizingCard.of(reading, containers: [], oomKilled: ["app": now.addingTimeInterval(-21 * 86400)], now: now)
        XCTAssertNil(dated.rows.first?.note, "an OOMKill three weeks ago isn't this window's")
    }

    func testSuggestionsRoundUp() {
        XCTAssertEqual(KubeSizing.cpuRequest(p95: 0.21), 0.245, accuracy: 1e-9)
        XCTAssertEqual(KubeSizing.cpuRequest(p95: 0), 0.005, accuracy: 1e-9, "never zero")
        XCTAssertEqual(KubeSizing.memory(max: 509 * 1_048_576), 586 * 1_048_576)
        XCTAssertEqual(KubeSizing.rateWindow(scrape: 30), 300)
        XCTAssertEqual(KubeSizing.rateWindow(scrape: 120), 480)
    }
}
