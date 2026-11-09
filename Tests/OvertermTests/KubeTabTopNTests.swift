import Foundation
import XCTest

@testable import Overterm

/// A workload's pods by owner, its top five and the rest, by revision; a
/// namespace's top eight workloads, its pods by phase, its quota and what
/// it requests but leaves idle (docs/design/kubernetes/metrics.md 2.5, 2.7,
/// 4.3, 4.5, 4.6; stage M7): every query a golden string or evaluated on
/// the fake's series, the ranking one instant `topk` a measure, the
/// charts built from the answers. Pure.
final class KubeTabTopNTests: XCTestCase {
    private let now = KubeTabTesting.now
    private let deployment = KubeTabSubject.workload(namespace: "shop", kind: "Deployment", name: "web", hpa: nil)
    private let statefulSet = KubeTabSubject.workload(namespace: "shop", kind: "StatefulSet", name: "db", hpa: nil)
    private let namespace = KubeTabSubject.namespace("shop")

    /// kube-prometheus-stack: the mixin's rules (the workload rule among them), a 30 s scrape.
    private var stack: KubePromProfile {
        var profile = KubePromProfile(probed: now)
        profile.metrics = FakePromProfile.kubePrometheusStack.metrics
        profile.cadvisorPath = "/metrics/cadvisor"
        profile.ksmJob = "kube-state-metrics"
        profile.nodeLabel = .node
        profile.scrape = 30
        return profile
    }

    /// The prometheus chart: no rules, a minute's scrape, kube-state-metrics' owners.
    private var chart: KubePromProfile {
        var profile = KubePromProfile(probed: now)
        profile.metrics = FakePromProfile.prometheusChart.metrics
        profile.nodeLabel = .instance
        profile.scrape = 60
        return profile
    }

    private func request(_ subject: KubeTabSubject, _ range: KubeMetricsRange, families: Set<KubeTabFamily>? = nil) -> KubeTabRequest {
        let all: Set<KubeTabFamily> = {
            if case .namespace = subject { return KubePromTabCharts.families(.namespace, source: .prometheus) }
            return KubePromTabCharts.families(.workload("Deployment"), source: .prometheus)
        }()
        return KubeTabRequest(subject: subject, span: .range(range), families: families ?? all)
    }

    private func plan(_ subject: KubeTabSubject, _ range: KubeMetricsRange, profile: KubePromProfile, ranking: KubeTabRanking? = nil) -> KubeTabPlan {
        let asked = request(subject, range)
        return KubeTabQueries.plan(asked, span: asked.resolve(scrape: profile.scrapeInterval, now: now), profile: profile, ranking: ranking)
    }

    private func queries(_ plan: KubeTabPlan) -> [String: String] { Dictionary(uniqueKeysWithValues: plan.queries.map { ($0.id, $0.promql) }) }

    private func ranking(_ subject: KubeTabSubject, _ range: KubeMetricsRange, profile: KubePromProfile) -> KubeTabRankPlan? {
        let asked = request(subject, range)
        return KubeTabQueries.ranking(asked, span: asked.resolve(scrape: profile.scrapeInterval, now: now), profile: profile)
    }

    // MARK: By owner

    func testAWorkloadsPodsAreChosenByOwnerInTierOrder() throws {
        XCTAssertEqual(KubeTabQueries.workloadSelection(kind: "Deployment", profile: stack), .rule)
        XCTAssertEqual(KubeTabQueries.workloadSelection(kind: "Job", profile: stack), .owner, "the mixin's rule names no Jobs")
        XCTAssertEqual(KubeTabQueries.workloadSelection(kind: "Deployment", profile: chart), .owner)
        var none = chart
        none.metrics?["kube_pod_owner"] = nil
        XCTAssertEqual(KubeTabQueries.workloadSelection(kind: "Deployment", profile: none), .name)
        XCTAssertEqual(KubeTabQueries.workloadSelection(kind: "Deployment", profile: .unknown), .owner, "unknown: every raw metric assumed there")

        XCTAssertEqual(
            queries(plan(deployment, .hour, profile: stack))["cpu"],
            #"sum((sum by (namespace,pod,container)(rate(container_cpu_usage_seconds_total{container!="",image!="",container!="POD",metrics_path="/metrics/cadvisor",namespace="shop",pod=~"web-.+"}[2m])))"#
                + #" * on(namespace,pod) group_left() max by (namespace,pod)(namespace_workload_pod:kube_pod_owner:relabel{namespace="shop",workload="web",workload_type="deployment"}))"#,
            "the rule: the workload's kind lower case, as the mixin writes it; its pods' names a prefilter, not the namespace's every series")
        // A name Kubernetes cuts: the prefix where it cuts a generated name.
        let long = String(repeating: "a", count: 60)
        XCTAssertEqual(KubeTabQueries.podPrefixMatcher(name: long), "pod=~\"" + String(repeating: "a", count: 58) + ".+\"")
        XCTAssertEqual(KubeTabQueries.podPrefixMatcher(name: "acme.db"), #"pod=~"acme\\.db-.+""#, "escaped as a regex, then as a string")
        XCTAssertEqual(
            KubeTabQueries.ownerOf(kind: "Deployment", namespace: "shop", name: "web", selection: .owner, profile: chart),
            #"max by (namespace,pod,replicaset)(label_replace(kube_pod_owner{namespace="shop",owner_kind="ReplicaSet"},"replicaset","$1","owner_name","(.*)")"#
                + #" * on(namespace,replicaset) group_left() max by (namespace,replicaset)(kube_replicaset_owner{namespace="shop",owner_kind="Deployment",owner_name="web"}))"#,
            "a Deployment through its ReplicaSets, each de-duplicated")
        XCTAssertEqual(
            KubeTabQueries.ownerOf(kind: "StatefulSet", namespace: "shop", name: "acme.db", selection: .owner, profile: stack),
            #"max by (namespace,pod)(kube_pod_owner{job="kube-state-metrics",namespace="shop",owner_kind="StatefulSet",owner_name="acme.db"})"#)
        let byName = queries(plan(deployment, .hour, profile: none))
        XCTAssertTrue(byName["cpu"]?.contains(#"pod=~"web-[bcdfghjklmnpqrstvwxz2456789]{1,10}"#) == true, "names: the selector's regex")
        XCTAssertFalse(byName["cpu"]?.contains("group_left") ?? true)
    }

    /// The owner join on data: a StatefulSet's pods, never its neighbour's
    /// whose name it prefixes; a Deployment's through its ReplicaSets.
    func testTheOwnerJoinCountsOnlyItsOwnPods() throws {
        let cad = ["image": "nginx:1.27", "namespace": "shop", "container": "app"]
        var series: [FakePromQL.Series] = [
            ("container_cpu_usage_seconds_total", cad.merging(["pod": "db-0"]) { $1 }, 0.2),
            ("container_cpu_usage_seconds_total", cad.merging(["pod": "db-1"]) { $1 }, 0.3),
            ("container_cpu_usage_seconds_total", cad.merging(["pod": "db-extra-0"]) { $1 }, 0.5),
            ("container_cpu_usage_seconds_total", cad.merging(["pod": "web-7f9c6d-aaaaa"]) { $1 }, 0.4),
            ("container_cpu_usage_seconds_total", cad.merging(["pod": "web-55d4f-bbbbb"]) { $1 }, 0.1),
        ]
        for (pod, kind, owner) in [
            ("db-0", "StatefulSet", "db"), ("db-1", "StatefulSet", "db"), ("db-extra-0", "StatefulSet", "db-extra"), ("web-7f9c6d-aaaaa", "ReplicaSet", "web-7f9c6d"),
            ("web-55d4f-bbbbb", "ReplicaSet", "web-55d4f"),
        ] {
            // Two kube-state-metrics replicas scrape the same: counted once.
            for instance in ["a", "b"] {
                series.append(("kube_pod_owner", ["namespace": "shop", "pod": pod, "owner_kind": kind, "owner_name": owner, "instance": instance], 1))
            }
        }
        for replicaSet in ["web-7f9c6d", "web-55d4f"] {
            series.append(("kube_replicaset_owner", ["namespace": "shop", "replicaset": replicaSet, "owner_kind": "Deployment", "owner_name": "web"], 1))
        }
        let db = try XCTUnwrap(FakePromQL.evaluate(try XCTUnwrap(queries(plan(statefulSet, .hour, profile: chart))["cpu"]), series))
        XCTAssertEqual(db.map(\.value).first ?? 0, 0.5, accuracy: 1e-9, "db-0 and db-1, not db-extra-0")
        let web = queries(plan(deployment, .hour, profile: chart))
        let total = try XCTUnwrap(FakePromQL.evaluate(try XCTUnwrap(web["cpu"]), series))
        XCTAssertEqual(total.map(\.value).first ?? 0, 0.5, accuracy: 1e-9, "both ReplicaSets' pods")
        let revisions = try XCTUnwrap(FakePromQL.evaluate(try XCTUnwrap(web["revisions"]), series))
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: revisions.map { ($0.labels["replicaset"] ?? "", $0.value) }), ["web-7f9c6d": 0.4, "web-55d4f": 0.1],
            "W3: by ReplicaSet, kube-state-metrics' own")
        // With rules or names, the ReplicaSet is read off the pod's name.
        XCTAssertEqual(
            queries(plan(deployment, .hour, profile: stack))["revisions"]?.hasSuffix(#""replicaset","$1","pod","(.+)-[bcdfghjklmnpqrstvwxz2456789]{5}"))"#), true)
        XCTAssertNil(queries(plan(statefulSet, .hour, profile: chart))["revisions"], "by revision over Prometheus: a Deployment's")
        // Restarts and OOMKills follow the same pods.
        XCTAssertTrue(web["restarts"]?.contains("group_left() max by (namespace,pod,replicaset)(") == true, web["restarts"] ?? "")
        XCTAssertTrue(web["oom"]?.hasPrefix("max by (pod,container)((") == true)
    }

    // MARK: The top five

    func testTheRankingIsOneInstantTopkAMeasureWithoutASubqueryForCPU() throws {
        let hour = try XCTUnwrap(ranking(deployment, .hour, profile: chart))
        XCTAssertEqual(hour.queries.map(\.id), ["cpu", "memory"])
        XCTAssertTrue(hour.queries.allSatisfy { $0.instant && $0.at == KubeMetricsSpan.of(.hour, scrape: 60, now: now).end }, "at the span's end")
        let cpu = try XCTUnwrap(hour.queries.first)
        XCTAssertEqual(
            cpu.promql,
            #"topk(5, sum by (pod)((sum by (namespace,pod,container)(rate(container_cpu_usage_seconds_total{container!="",image!="",container!="POD",namespace="shop",pod=~"web-.+"}[1h])))"#
                + #" * on(namespace,pod) group_left() max by (namespace,pod,replicaset)(label_replace(kube_pod_owner{namespace="shop",owner_kind="ReplicaSet"},"replicaset","$1","owner_name","(.*)")"#
                + #" * on(namespace,replicaset) group_left() max by (namespace,replicaset)(kube_replicaset_owner{namespace="shop",owner_kind="Deployment",owner_name="web"}))))"#,
            "the average rate over the range: the counter's increase, no subquery")
        XCTAssertFalse(cpu.promql.contains(":"), "no subquery")
        XCTAssertTrue(hour.queries[1].promql.contains("avg_over_time(max by (namespace,pod,container)(container_memory_working_set_bytes{"), hour.queries[1].promql)
        XCTAssertTrue(hour.queries[1].promql.contains("[1h:1m]"), "raw memory de-duplicated first: a subquery at the step")
        XCTAssertTrue(hour.notes.isEmpty)
        // 7 days raw: 9,000 series × 7d ÷ 60 s is about 91M samples — ranked by the last 24h; memory too.
        let week = try XCTUnwrap(ranking(deployment, .week, profile: chart))
        XCTAssertTrue(week.queries[0].promql.contains("[24h]"), week.queries[0].promql)
        XCTAssertTrue(week.queries[1].promql.contains("[24h:30m]"), week.queries[1].promql)
        XCTAssertEqual(week.notes, ["CPU ranked by the last 24h.", "Memory ranked by the last 24h."])
        // With the rules: their average over the whole range, no subquery at all.
        let rules = try XCTUnwrap(ranking(deployment, .week, profile: stack))
        XCTAssertTrue(rules.queries.allSatisfy { !$0.promql.contains(":3") && $0.promql.contains("avg_over_time(node_namespace_pod_container:") && $0.promql.contains("[168h]") })
        XCTAssertTrue(rules.notes.isEmpty)
        XCTAssertNotEqual(rules.key, week.key, "another tier, another ranking")
        XCTAssertNotEqual(ranking(deployment, .day, profile: chart)?.key, hour.key, "another range, ranked again")
        XCTAssertNil(KubeTabQueries.ranking(request(deployment, .hour, families: [.restarts]), span: KubeMetricsSpan.of(.hour, scrape: 60, now: now), profile: chart))
    }

    /// A raw workload's pods counted before it is ranked: its own series
    /// the CPU estimate (not the cluster's), its pods the memory subquery's gate.
    func testARawWorkloadIsCountedBeforeItIsRanked() throws {
        let hour = try XCTUnwrap(ranking(deployment, .hour, profile: chart))
        XCTAssertEqual(
            hour.count?.promql, #"count by (pod)(container_cpu_usage_seconds_total{container!="",image!="",container!="POD",namespace="shop",pod=~"web-.+"})"#)
        XCTAssertEqual(hour.count?.instant, true)
        XCTAssertNil(ranking(deployment, .week, profile: stack)?.count, "the rules: nothing to count")
        XCTAssertNil(
            ranking(
                namespace, .hour,
                profile: {
                    var p = chart; p.namespaceSeries["shop"] = 10; return p
                }())?.count, "a namespace's count is the profile's")
        let pods = (0..<3).map { KubeSeries(labels: ["pod": "web-\($0)"], points: [KubeSeriesPoint(time: now, value: 2)]) }
        XCTAssertEqual(KubeTabCount.of(pods), KubeTabCount(series: 6, pods: 3))
        let asked = request(deployment, .week)
        let span = asked.resolve(scrape: 60, now: now)
        // Three pods' six series over 7d: about 60k samples, ranked over the whole week.
        let small = try XCTUnwrap(KubeTabQueries.ranking(asked, span: span, profile: chart, counted: KubeTabCount(series: 6, pods: 3)))
        XCTAssertNil(small.count)
        XCTAssertTrue(small.queries[0].promql.contains("[168h]"), small.queries[0].promql)
        XCTAssertEqual(small.notes, ["Memory ranked by the last 24h."])
        // 60 pods: no raw memory subquery over them.
        let many = try XCTUnwrap(KubeTabQueries.ranking(asked, span: span, profile: chart, counted: KubeTabCount(series: 120, pods: 60)))
        XCTAssertEqual(many.queries.map(\.id), ["cpu"])
        XCTAssertEqual(many.skipped, ["memory"])
        XCTAssertTrue(many.notes.contains("Memory's top five need recording rules past 50 pods: the total alone."), "\(many.notes)")
        // The count failed: the cluster's estimate, no memory subquery.
        let failed = try XCTUnwrap(KubeTabQueries.ranking(asked, span: span, profile: chart, counted: .failed))
        XCTAssertTrue(failed.queries[0].promql.contains("[24h]"), "9,000 series assumed: ranked by the last 24h")
        XCTAssertEqual(failed.skipped, ["memory"])
    }

    /// A window shorter than four scrapes: the CPU ranking's rate over four.
    func testAShortWindowsRankingReadsAtLeastFourScrapes() throws {
        let end = now
        let window = KubeChartWindow(start: end.addingTimeInterval(-120), end: end)
        let asked = KubeTabRequest(subject: deployment, span: .window(window), families: [.cpu, .memory])
        let span = asked.resolve(scrape: 60, now: now)
        let plan = try XCTUnwrap(KubeTabQueries.ranking(asked, span: span, profile: chart, counted: KubeTabCount(series: 2, pods: 1)))
        XCTAssertTrue(plan.queries[0].promql.contains("[4m]"), plan.queries[0].promql)
    }

    func testTheTopFiveAreAskedByNameOnlyOnceRanked() throws {
        let unranked = queries(plan(deployment, .hour, profile: chart))
        XCTAssertNil(unranked["cpuTop"], "no names yet: the total alone")
        XCTAssertNotNil(unranked["cpu"])
        let ranked = KubeTabRanking(key: "k", names: ["cpu": ["web-a.b-x2k4q", "web-c"], "memory": ["web-c"]])
        let asked = queries(plan(deployment, .hour, profile: chart, ranking: ranked))
        XCTAssertEqual(
            asked["cpuTop"],
            #"sum by (pod)(sum by (namespace,pod,container)(rate(container_cpu_usage_seconds_total{container!="",image!="",container!="POD",namespace="shop",pod=~"web-a\\.b-x2k4q|web-c"}[4m])))"#,
            "the names exactly, escaped as a regex, then as a string")
        XCTAssertTrue(asked["memoryTop"]?.contains(#"pod=~"web-c""#) == true)
        XCTAssertFalse(asked["cpuTop"]?.contains("kube_pod_owner") ?? true, "chosen by owner already")
        var kept = ranked
        for _ in 0..<KubeTabRanking.kept - 1 { kept.refreshes += 1 }
        XCTAssertFalse(kept.isStale)
        kept.refreshes += 1
        XCTAssertTrue(kept.isStale, "ranked again every 10 refreshes")
    }

    func testRankingAnswersAreReadLargestFirst() {
        let pods = [("web-b", 0.2), ("web-a", 0.5), ("web-c", 0.2), ("", 9.0)].map {
            KubeSeries(labels: ["pod": $0.0], points: [KubeSeriesPoint(time: now, value: $0.1)])
        }
        XCTAssertEqual(KubeTabQueries.rankNames(pods, subject: deployment), ["web-a", "web-b", "web-c"], "by value, then name; an unnamed series left out")
        let workloads = [("deployment", "api", 1.0), ("StatefulSet", "db", 2.0)].map {
            KubeSeries(labels: ["workload_type": $0.0, "workload": $0.1], points: [KubeSeriesPoint(time: now, value: $0.2)])
        }
        XCTAssertEqual(KubeTabQueries.rankNames(workloads, subject: namespace), ["StatefulSet/db", "Deployment/api"], "the rule's lower case read as the Kind")
    }

    // MARK: A namespace

    func testANamespacesQueries() throws {
        let ranked = KubeTabRanking(key: "k", names: ["cpu": ["Deployment/api", "StatefulSet/acme.db"], "memory": ["Deployment/api"]])
        let rules = queries(plan(namespace, .day, profile: stack, ranking: ranked))
        XCTAssertEqual(
            rules["cpu"],
            #"sum(max by (namespace,pod,container)(node_namespace_pod_container:container_cpu_usage_seconds_total:sum_rate5m{namespace="shop",container!="",container!="POD"}))"#)
        XCTAssertEqual(
            rules["cpuTop"],
            #"sum by (workload_type,workload)((max by (namespace,pod,container)(node_namespace_pod_container:container_cpu_usage_seconds_total:sum_rate5m{namespace="shop",container!="",container!="POD"}))"#
                + #" * on(namespace,pod) group_left(workload,workload_type) max by (namespace,pod,workload,workload_type)(namespace_workload_pod:kube_pod_owner:relabel{namespace="shop",workload=~"acme\\.db|api"}))"#
        )
        XCTAssertEqual(
            rules["phases"], #"sum by (phase)(max by (namespace,pod,phase)(kube_pod_status_phase{job="kube-state-metrics",namespace="shop"}) == 1)"#,
            "two kube-state-metrics replicas: each pod's phase once")
        XCTAssertEqual(
            rules["quota"],
            #"min by (resource,type)(max by (resourcequota,resource,type)(kube_resourcequota{job="kube-state-metrics",namespace="shop",resource=~"requests.cpu|cpu|requests.memory|memory",type=~"hard|used"}))"#
        )
        let idle = try XCTUnwrap(plan(namespace, .day, profile: stack).queries.first { $0.id == "idle" })
        XCTAssertTrue(idle.instant)
        XCTAssertTrue(
            idle.promql.hasPrefix(#"label_replace(avg_over_time((sum(max by (namespace,pod,container,node)(cluster:namespace:pod_cpu:active:kube_pod_container_resource_requests{namespace="shop"}))"#),
            idle.promql)
        XCTAssertTrue(idle.promql.contains(#"[24h:5m]),"overterm_s","cpu""#) && idle.promql.contains(#""overterm_s","memory""#))
        // Without rules: kube-state-metrics' owners, raw only below 2,000 series, the idle chip only to 24h.
        var counted = chart
        counted.namespaceSeries["shop"] = 400
        let raw = plan(namespace, .day, profile: counted, ranking: ranked)
        let rawQueries = queries(raw)
        XCTAssertTrue(rawQueries["cpuTop"]?.contains(#"owner_kind=~"StatefulSet|DaemonSet|Job",owner_name=~"acme\\.db|api""#) == true, rawQueries["cpuTop"] ?? "")
        XCTAssertTrue(
            rawQueries["cpuTop"]?.contains(
                #"group_left(owner_name) max by (namespace,replicaset,owner_name)(kube_replicaset_owner{namespace="shop",owner_kind="Deployment",owner_name=~"acme\\.db|api"})"#) == true)
        XCTAssertTrue(
            rawQueries["idle"]?.contains(
                #"kube_pod_container_resource_requests{namespace="shop",resource="cpu"}) * on(namespace,pod) group_left() max by (namespace,pod)(kube_pod_status_phase{namespace="shop",phase=~"Pending|Running"} == 1)"#
            )
                == true, "active pods' requests")
        XCTAssertNotNil(plan(namespace, .week, profile: counted).refused[.idle], "a subquery past 24h without rules")
        var crowded = chart
        crowded.namespaceSeries["shop"] = 3000
        let refused = plan(namespace, .hour, profile: crowded)
        XCTAssertNil(refused.queries.first { $0.family == .cpu })
        XCTAssertTrue(refused.refused[.cpu]?.contains("3000 series") == true, refused.refused[.cpu] ?? "")
        XCTAssertNil(ranking(namespace, .hour, profile: crowded), "nothing ranked where nothing is drawn")
        XCTAssertNotNil(queries(refused)["phases"], "its phases still asked")
        XCTAssertNil(queries(refused)["idle"], "the idle chip's subquery costs more than the refused range query")
        XCTAssertEqual(refused.refused[.idle], refused.refused[.cpu])
        // The count failed: raw refused, said so, until it is counted.
        var uncounted = chart
        uncounted.uncounted = ["shop"]
        let unknown = plan(namespace, .hour, profile: uncounted)
        XCTAssertNil(unknown.queries.first { $0.family == .cpu || $0.family == .memory || $0.family == .idle })
        XCTAssertTrue(unknown.refused[.cpu]?.contains("couldn't be counted") == true, unknown.refused[.cpu] ?? "")
        XCTAssertNil(ranking(namespace, .hour, profile: uncounted))
        XCTAssertNotNil(queries(unknown)["phases"])
        // Without kube-state-metrics: the total, said so.
        var bare = chart
        for name in ["kube_pod_owner", "kube_replicaset_owner", "kube_pod_status_phase", KubePromProfile.requestsMetric, "kube_resourcequota"] { bare.metrics?[name] = nil }
        bare.namespaceSeries["shop"] = 10
        let alone = plan(namespace, .hour, profile: bare)
        XCTAssertEqual(Set(alone.queries.map(\.id)), ["cpu", "memory"])
        XCTAssertTrue(alone.notes.contains(KubeChartEmpty.ksmMissing.sentence))
        XCTAssertNil(ranking(namespace, .hour, profile: bare))
    }

    func testANamespacesSeriesAreCountedOnceWithoutRules() {
        let asked = request(namespace, .hour)
        XCTAssertEqual(KubeTabQueries.namespaceCount(asked, profile: chart)?.promql, #"count(container_cpu_usage_seconds_total{namespace="shop",container!=""})"#)
        XCTAssertNil(KubeTabQueries.namespaceCount(asked, profile: stack), "the rules need no count")
        var counted = chart
        counted.namespaceSeries["shop"] = 12
        XCTAssertNil(KubeTabQueries.namespaceCount(asked, profile: counted), "kept with the profile")
        XCTAssertNil(KubeTabQueries.namespaceCount(asked, profile: .unknown), "nothing known: as before the probe")
        XCTAssertNil(KubeTabQueries.namespaceCount(request(deployment, .hour), profile: chart))
    }

    func testANamespacesChartsFromPrometheus() throws {
        let span = KubeMetricsSpan.of(.hour, scrape: 30, now: now)
        let times = [span.end.addingTimeInterval(-60), span.end].map(\.timeIntervalSince1970)
        func line(_ labels: [String: String], _ value: Double) -> KubeSeries {
            KubeSeries(labels: labels, points: times.map { KubeSeriesPoint(time: Date(timeIntervalSince1970: $0), value: value) })
        }
        var reading = KubeTabReading(request: request(namespace, .hour))
        reading.span = span
        reading.read = span.end
        reading.tier = .raw
        reading.selection = .owner
        reading.results = [
            "cpu": [line([:], 1.0)], "cpuTop": [line(["workload_type": "deployment", "workload": "api"], 0.6), line(["workload_type": "StatefulSet", "workload": "db"], 0.3)],
            "memory": [line([:], 512 * 1_048_576)],
            "quota": [
                line(["resource": "requests.cpu", "type": "hard"], 2), line(["resource": "requests.cpu", "type": "used"], 1.5),
                line(["resource": "cpu", "type": "hard"], 9),
            ],
            "idle": [line(["overterm_s": "cpu"], 0.5)], "phases": [line(["phase": "Running"], 4), line(["phase": "Failed"], 1), line(["phase": "Pending"], 0)],
        ]
        reading.ranking = KubeTabRanking(key: "k", names: ["cpu": ["Deployment/api", "StatefulSet/db"]])
        let charts = KubePromTabCharts.namespace(namespace: "shop", reading: reading, quota: nil, changes: KubeChartChanges(), window: nil)
        let cpu = try XCTUnwrap(charts.charts.first { $0.data.id == "namespace.shop.cpu" })
        XCTAssertEqual(cpu.data.usage.map(\.id), ["Deployment/api", "StatefulSet/db", "other"])
        XCTAssertEqual(cpu.data.usage.map(\.name), ["api", "db", "other"])
        XCTAssertEqual(cpu.data.usage.last?.points.last?.value ?? 0, 0.1, accuracy: 1e-9, "other: the total less the top")
        XCTAssertTrue(cpu.data.stacked)
        XCTAssertEqual(cpu.data.references.map(\.role), [.quota, .guide])
        XCTAssertEqual(cpu.data.references.first?.points.count, 2, "the quota over time, requests.cpu before cpu")
        XCTAssertEqual(cpu.data.references.first?.points.last?.value, 2)
        XCTAssertEqual(cpu.chips.map(\.text), ["requests 75% of quota", "requested but idle: \(KubeMetricsFormat.cpu(0.5)) (avg, 1h)"])
        XCTAssertEqual(cpu.data.tier, "raw cAdvisor · by owner")
        let memory = try XCTUnwrap(charts.charts.first { $0.data.id == "namespace.shop.memory" })
        XCTAssertEqual(memory.data.usage.map(\.id), ["total"], "not ranked: the total alone")
        XCTAssertTrue(memory.data.references.isEmpty, "no memory quota")
        let phases = try XCTUnwrap(charts.charts.first { $0.data.id == "namespace.shop.phases" })
        XCTAssertEqual(phases.data.usage.map(\.name), ["Running", "Failed"], "in phase order, the empty left out")
        XCTAssertTrue(phases.data.stepped)
        // No quota from kube-state-metrics: the one the tab read as it opened.
        reading.results["quota"] = nil
        let looked = KubePromTabCharts.namespace(
            namespace: "shop", reading: reading, quota: KubeQuota(cpuHard: 4, cpuUsed: 1, memoryHard: nil, memoryUsed: nil), changes: KubeChartChanges(), window: nil)
        XCTAssertEqual(looked.charts.first?.data.references.first?.points.last?.value, 4)
        XCTAssertEqual(looked.charts.first?.chips.first?.text, "requests 25% of quota")
        let none = KubePromTabCharts.namespace(namespace: "shop", reading: reading, quota: nil, changes: KubeChartChanges(), window: nil)
        XCTAssertTrue(none.notes.contains("No ResourceQuota on requests here: no quota line."))
    }
}
