import Foundation
import XCTest

@testable import Overterm

/// The pod `shop/web-1` the tests' Metrics tabs ask about, and its plans.
enum KubeTabTesting {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let pod = KubeTabSubject.pod(namespace: "shop", name: "web-1", cpuLimited: true, hostNetwork: false)

    static func request(_ range: KubeMetricsRange, families: Set<KubeTabFamily> = [.cpu, .memory], subject: KubeTabSubject = pod) -> KubeTabRequest {
        KubeTabRequest(subject: subject, span: .range(range), families: families)
    }

    static func plan(
        _ range: KubeMetricsRange, profile: KubePromProfile = .unknown, families: Set<KubeTabFamily> = Set(KubeTabFamily.allCases), subject: KubeTabSubject = pod
    ) -> KubeTabPlan {
        let request = request(range, families: families, subject: subject)
        return KubeTabQueries.plan(request, span: request.resolve(scrape: profile.scrapeInterval, now: now), profile: profile)
    }

    static func query(_ id: String, _ range: KubeMetricsRange, profile: KubePromProfile = .unknown, subject: KubeTabSubject = pod) -> String? {
        plan(range, profile: profile, subject: subject).queries.first { $0.id == id }?.promql
    }
}

/// What a Metrics tab asks Prometheus (metrics.md 4.2, 4.3, 4.5, 4.6;
/// stage M6): every chart's query as a golden string, de-duplicated before
/// it is summed, its literals and regexes escaped; what isn't asked and
/// why. Pure.
final class KubeTabQueriesTests: XCTestCase {
    private var stack: KubePromProfile {
        var profile = KubePromProfile(probed: Date())
        profile.metrics = FakePromProfile.kubePrometheusStack.metrics
        profile.cadvisorPath = "/metrics/cadvisor"
        profile.cadvisorJob = "kubelet"
        profile.ksmJob = "kube-state-metrics"
        profile.nodeLabel = .node
        profile.scrape = 30
        return profile
    }

    private var chart: KubePromProfile {
        var profile = KubePromProfile(probed: Date())
        profile.metrics = FakePromProfile.prometheusChart.metrics
        profile.nodeLabel = .instance
        profile.scrape = 60
        return profile
    }

    func testAPodsQueriesOverAnHour() {
        let plan = KubeTabTesting.plan(.hour, profile: stack)
        let by = Dictionary(uniqueKeysWithValues: plan.queries.map { ($0.id, $0.promql) })
        XCTAssertEqual(Set(by.keys), ["cpu", "memory", "rss", "throttling", "network", "restarts", "oom"], "no peak band under 24h")
        XCTAssertEqual(
            by["throttling"],
            #"sum by (container)(increase(container_cpu_cfs_throttled_periods_total{container!="",image!="",container!="POD",metrics_path="/metrics/cadvisor",namespace="shop",pod="web-1"}[5m]))"#
                + #" / sum by (container)(increase(container_cpu_cfs_periods_total{container!="",image!="",container!="POD",metrics_path="/metrics/cadvisor",namespace="shop",pod="web-1"}[5m]))"#,
            "throttled periods over periods, increases over 5 minutes at least")
        XCTAssertEqual(
            by["network"],
            #"label_replace(sum(rate(container_network_receive_bytes_total{metrics_path="/metrics/cadvisor",namespace="shop",pod="web-1"}[2m])),"overterm_s","rx","","")"#
                + #" or label_replace(sum(rate(container_network_transmit_bytes_total{metrics_path="/metrics/cadvisor",namespace="shop",pod="web-1"}[2m])),"overterm_s","tx","","")"#
                + #" or label_replace(sum(rate({__name__=~"container_network_(receive|transmit)_packets_dropped_total",metrics_path="/metrics/cadvisor",namespace="shop",pod="web-1"}[2m])),"overterm_s","drops","","")"#,
            "the sandbox's: no container filter")
        let restarts = #"kube_pod_container_status_restarts_total{job="kube-state-metrics",namespace="shop",pod="web-1"}"#
        XCTAssertEqual(
            by["restarts"],
            "sum(clamp_min(max by (namespace,pod,container)(\(restarts)) - max by (namespace,pod,container)(\(restarts) offset 30s), 0))",
            "a step's restarts: the count against its own a step back, de-duplicated by container first")
        XCTAssertEqual(
            by["oom"],
            "max by (container)((clamp_min(max by (namespace,pod,container)(\(restarts)) - max by (namespace,pod,container)(\(restarts) offset 30s), 0) > 0)"
                + #" and on(namespace,pod,container) (kube_pod_container_status_last_terminated_reason{job="kube-state-metrics",reason="OOMKilled",namespace="shop",pod="web-1"} == 1))"#
                + #" or max by (container)(increase(container_oom_events_total{container!="",image!="",container!="POD",metrics_path="/metrics/cadvisor",namespace="shop",pod="web-1"}[1m]) > 0)"#,
            "a restart a step back after an OOMKill; cAdvisor's own events over the step and a scrape")
        XCTAssertEqual(
            by["rss"], #"max by (container)(container_memory_rss{container!="",image!="",container!="POD",metrics_path="/metrics/cadvisor",namespace="shop",pod="web-1"})"#)
        XCTAssertEqual(plan.tier, .raw, "one pod's raw series over an hour, even with rules")
        XCTAssertTrue(plan.refused.isEmpty)
    }

    func testWhatAPodsTabDoesntAsk() {
        let host = KubeTabSubject.pod(namespace: "shop", name: "web-1", cpuLimited: false, hostNetwork: true)
        let plan = KubeTabTesting.plan(.hour, profile: stack, subject: host)
        XCTAssertNil(plan.queries.first { $0.family == .throttling }, "no CPU limit: never throttled, nothing asked")
        XCTAssertNil(plan.queries.first { $0.family == .network })
        XCTAssertEqual(plan.refused[.network], "This pod uses the node's network; its traffic is the node's.")
        var noCFS = stack
        noCFS.metrics?["container_cpu_cfs_periods_total"] = nil
        XCTAssertEqual(KubeTabTesting.plan(.hour, profile: noCFS).refused[.throttling], KubeChartEmpty.noThrottling.sentence)
        var noKSM = stack
        for name in FakePromProfile.kubePrometheusStack.metrics.keys where name.hasPrefix("kube_") { noKSM.metrics?[name] = nil }
        let bare = KubeTabTesting.plan(.hour, profile: noKSM)
        XCTAssertNil(bare.queries.first { $0.family == .restarts || $0.family == .oom })
        XCTAssertEqual(bare.refused[.restarts], KubeChartEmpty.ksmMissing.sentence)
        XCTAssertEqual(bare.notes, [KubeChartEmpty.ksmMissing.sentence])
        // Only what was asked for: Live's mixed tab asks only what has no sampled form.
        let live = KubeTabTesting.plan(.live, profile: stack, families: KubeTabFamily.prometheusOnly)
        XCTAssertEqual(Set(live.queries.map(\.family)), [.throttling, .network, .restarts, .oom])
    }

    /// A counter's rise a step is never a window one step wide: since
    /// Prometheus 3 a range is left-open, and a scrape-sized window holds
    /// one sample — no increase, no change. Every range's restarts and OOMs
    /// say the step they look back by, and a window that holds two samples.
    func testRestartsAndOOMsLookBackAWholeStep() throws {
        for (range, profile, back, oomWindow) in [
            (KubeMetricsRange.live, stack, "30s", "1m"), (.hour, chart, "1m", "2m"), (.day, stack, "5m", "330s"), (.week, chart, "30m", "31m"),
        ] {
            let restarts = try XCTUnwrap(KubeTabTesting.query("restarts", range, profile: profile))
            XCTAssertTrue(restarts.contains(" offset \(back)), 0))"), "\(range): \(restarts)")
            XCTAssertFalse(restarts.contains("changes(") || restarts.contains(":]"), "no subquery at the server's evaluation interval: \(restarts)")
            let oom = try XCTUnwrap(KubeTabTesting.query("oom", range, profile: profile))
            XCTAssertTrue(oom.contains(" offset \(back)), 0) > 0)"), "\(range): \(oom)")
            XCTAssertFalse(oom.contains("increase(kube_pod_container_status_restarts_total"), "no window a step wide: \(oom)")
            if profile.mayHave("container_oom_events_total") {
                XCTAssertTrue(oom.hasSuffix("}[\(oomWindow)]) > 0)"), "\(range): the step and a scrape, \(oom)")
            }
        }
    }

    /// C1's peak band only from 24h, one pod's subquery at a scrape's
    /// resolution (a minute at least); C2's RSS at every Prometheus range.
    func testAPodsPeakBandAndRSS() throws {
        XCTAssertNil(KubeTabTesting.query("cpuPeak", .hour, profile: stack), "under 24h the usage line is its own peak")
        XCTAssertNil(KubeTabTesting.query("cpuPeak", .sixHours, profile: stack))
        XCTAssertEqual(
            KubeTabTesting.query("cpuPeak", .day, profile: stack),
            #"max_over_time(sum by (container)(rate(container_cpu_usage_seconds_total{container!="",image!="",container!="POD",metrics_path="/metrics/cadvisor",namespace="shop",pod="web-1"}[2m]))[5m:1m])"#
        )
        XCTAssertTrue(KubeTabTesting.query("cpuPeak", .week, profile: chart)?.hasSuffix("[4m]))[30m:1m])") == true, "a minute's scrape: 4m rates, a minute apart")
        XCTAssertTrue(KubeTabTesting.query("rss", .day, profile: chart)?.hasPrefix("max by (container)(max_over_time(container_memory_rss{") == true, "a gauge's peaks past 5m")
        var noRSS = stack
        noRSS.metrics?["container_memory_rss"] = nil
        XCTAssertNil(KubeTabTesting.query("rss", .hour, profile: noRSS), "not where the probe found none")
        let live = KubeTabTesting.plan(.live, profile: stack, families: KubePromTabCharts.families(.pod, source: .mixed))
        XCTAssertNil(live.queries.first { $0.family == .rss || $0.family == .cpuPeak }, "Live's mixed tab: neither")
    }

    func testGaugesKeepTheirPeaksPastFiveMinutes() {
        XCTAssertFalse(KubeTabTesting.query("memory", .sixHours, profile: chart)?.contains("max_over_time") ?? true, "2m steps")
        XCTAssertEqual(
            KubeTabTesting.query("memory", .day, profile: chart),
            #"max by (container)(max_over_time(container_memory_working_set_bytes{container!="",image!="",container!="POD",namespace="shop",pod="web-1"}[5m]))"#)
        XCTAssertTrue(KubeTabTesting.query("cpu", .day, profile: chart)?.hasSuffix("[6m]))") == true, "a 5m step on a minute's scrape: 6m")
    }

    func testAWorkloadsPodsAreMatchedByNameEscaped() {
        XCTAssertEqual(KubeTabQueries.podPattern(kind: "Deployment", name: "acme.web"), #"acme\.web-[bcdfghjklmnpqrstvwxz2456789]{1,10}-[bcdfghjklmnpqrstvwxz2456789]{5}"#)
        XCTAssertEqual(KubeTabQueries.podPattern(kind: "StatefulSet", name: "db"), "db-[0-9]+")
        XCTAssertEqual(KubeTabQueries.podPattern(kind: "DaemonSet", name: "agent"), "agent-[bcdfghjklmnpqrstvwxz2456789]{5}")
        XCTAssertEqual(KubeTabQueries.podMatcher(kind: "StatefulSet", name: "acme.db"), #"pod=~"acme\\.db-[0-9]+""#, "regex first, then the string: the backslash kept")
        let deployment = KubeTabSubject.workload(namespace: "shop", kind: "Deployment", name: "web", hpa: "web")
        let plan = KubeTabTesting.plan(.hour, profile: stack, subject: deployment)
        let by = Dictionary(uniqueKeysWithValues: plan.queries.map { ($0.id, $0.promql) })
        XCTAssertEqual(
            by["cpu"],
            #"sum by (pod)(sum by (namespace,pod,container)(rate(container_cpu_usage_seconds_total{container!="",image!="",container!="POD",metrics_path="/metrics/cadvisor",namespace="shop",pod=~"web-[bcdfghjklmnpqrstvwxz2456789]{1,10}-[bcdfghjklmnpqrstvwxz2456789]{5}"}[2m])))"#
        )
        XCTAssertEqual(
            by["replicas"],
            #"label_replace(max(kube_deployment_spec_replicas{job="kube-state-metrics",namespace="shop",deployment="web"}),"overterm_s","desired","","")"#
                + #" or label_replace(max(kube_deployment_status_replicas_available{job="kube-state-metrics",namespace="shop",deployment="web"}),"overterm_s","available","","")"#
                + #" or label_replace(max(kube_deployment_status_replicas_unavailable{job="kube-state-metrics",namespace="shop",deployment="web"}),"overterm_s","unavailable","","")"#)
        XCTAssertTrue(by["hpa"]?.contains(#"kube_horizontalpodautoscaler_spec_max_replicas{job="kube-state-metrics",namespace="shop",horizontalpodautoscaler="web"}"#) == true)
        XCTAssertNotNil(by["hpaMetrics"])
        XCTAssertNotNil(by["restarts"])
        // Restarts are no subquery: asked however many pods, without rules too.
        let wide = KubeTabTesting.plan(.hour, profile: chart, subject: .workload(namespace: "shop", kind: "Deployment", name: "web", hpa: nil))
        XCTAssertFalse(wide.queries.first { $0.family == .restarts }?.promql.contains(":]") ?? true)
        XCTAssertNil(wide.refused[.restarts])
        XCTAssertNil(wide.queries.first { $0.family == .hpa }, "no HPA, none asked")
        XCTAssertTrue(KubeTabQueries.replicas(kind: "Job", namespace: "shop", name: "migrate", ksm: "")?.contains(#"job_name="migrate""#) == true)
    }

    func testAnHPAsQueriesOnBothKubeStateMetrics() {
        let hpa = KubeTabSubject.hpa(namespace: "shop", name: "web")
        XCTAssertTrue(
            KubeTabTesting.query("hpa", .hour, profile: stack, subject: hpa)?.contains(
                #"max(kube_horizontalpodautoscaler_status_current_replicas{job="kube-state-metrics",namespace="shop",horizontalpodautoscaler="web"})"#) == true)
        var old = chart
        old.metrics?["kube_pod_container_resource_requests"] = nil
        old.metrics?[KubePromProfile.requestsCPUCores] = 10
        let plan = KubeTabTesting.plan(.hour, profile: old, subject: hpa)
        XCTAssertTrue(plan.queries.first { $0.id == "hpa" }?.promql.contains(#"kube_hpa_status_current_replicas{namespace="shop",hpa="web"}"#) == true, "1.x: kube_hpa_*, label hpa")
        XCTAssertNotNil(plan.refused[.hpaMetrics], "1.x has no target metrics")
        XCTAssertEqual(plan.notes, [KubeChartEmpty.ksmOld.sentence])
    }

    func testANodesQueriesNameItAsTheProfileFound() {
        let node = KubeTabSubject.node("ip-10-0-0-1")
        let plan = KubeTabTesting.plan(.hour, profile: chart, subject: node)
        let by = Dictionary(uniqueKeysWithValues: plan.queries.map { ($0.id, $0.promql) })
        XCTAssertTrue(by["cpu"]?.contains(#"instance="ip-10-0-0-1""#) == true, "the prometheus chart: instance is the node")
        XCTAssertTrue(by["cpu"]?.contains(#""overterm_s","request""#) == true, "usage and request in one round trip")
        XCTAssertTrue(by["cpu"]?.contains(#"kube_pod_container_resource_requests{node="ip-10-0-0-1",resource="cpu"}"#) == true)
        XCTAssertEqual(
            by["pods"],
            #"count(max by (namespace,pod)(kube_pod_info{node="ip-10-0-0-1"}) * on(namespace,pod) group_left() max by (namespace,pod)(kube_pod_status_phase{phase=~"Pending|Running"} == 1))"#,
            "active pods only, as the scheduler counts them")
        XCTAssertTrue(by["conditions"]?.contains(#"condition=~"MemoryPressure|DiskPressure|PIDPressure""#) == true)
        XCTAssertTrue(KubeTabTesting.query("cpu", .hour, profile: stack, subject: node)?.contains(#"node="ip-10-0-0-1""#) == true)
        var unlabelled = chart
        unlabelled.nodeLabel = nil
        let none = KubeTabTesting.plan(.hour, profile: unlabelled, subject: node)
        XCTAssertNil(none.queries.first { $0.family == .cpu })
        XCTAssertNotNil(none.refused[.cpu])
    }

    /// Every chart sums over one series a container (a gauge's highest, a
    /// counter's rates): a restarted container's two series overlapping
    /// draw no spike (metrics.md 1.1, KubePromDedupTests' rule).
    func testEveryUsageQuerySumsOneSeriesAContainer() throws {
        let cad = ["image": "nginx:1.27", "namespace": "shop", "pod": "web-1"]
        let series: [FakePromQL.Series] = [
            ("container_memory_working_set_bytes", cad.merging(["container": "app", "id": "/old"]) { $1 }, 400),
            ("container_memory_working_set_bytes", cad.merging(["container": "app", "id": "/new"]) { $1 }, 380),
        ]
        let memory = try XCTUnwrap(FakePromQL.evaluate(try XCTUnwrap(KubeTabTesting.query("memory", .hour)), series))
        XCTAssertEqual(memory.map(\.value), [400], "the highest, not 780")
        let workload = KubeTabSubject.workload(namespace: "shop", kind: "Deployment", name: "web", hpa: nil)
        for id in ["cpu", "memory"] {
            let query = try XCTUnwrap(KubeTabTesting.query(id, .hour, subject: workload))
            XCTAssertTrue(query.hasPrefix("sum by (pod)(\(id == "cpu" ? "sum" : "max") by (namespace,pod,container)("), query)
        }
    }
}
