import Foundation
import XCTest

@testable import Overterm

/// Stage M5 of docs/design/kubernetes/metrics.md (4.3, 4.4, 4.7, 6.3):
/// the probe's four queries and what they derive — the metrics there and
/// their counts, the `metrics_path` and kube-state-metrics job pins, the
/// node label, the cAdvisor job's own scrape, the retention, agent mode,
/// kube-state-metrics 1.x and missing —; the tiers each chart reads in;
/// the cost caps; every empty chart's sentence; and the monitor probing
/// once a context, against `FakeKubeAPI`'s profiles on a socket of the
/// test's own. Nothing reads ~/.kube, nothing reaches a real cluster.
@MainActor
final class KubePromProfileTests: XCTestCase {
    private let service = KubePrometheusService(namespace: "monitoring", name: "prometheus-operated", port: "9090")!

    private func series(_ labels: [String: String], _ value: Double) -> KubeSeries {
        KubeSeries(labels: labels, points: [KubeSeriesPoint(time: Date(), value: value)])
    }

    // MARK: Reading the answers

    func testTheDuplicatesPinThePathTheJobAndTheNodeLabel() {
        var stack = KubePromProfile(probed: Date())
        stack.read(duplicates: [
            series(["overterm_s": "cadvisor", "job": "kubelet", "metrics_path": "/metrics/cadvisor"], 4000),
            series(["overterm_s": "cadvisor", "job": "kubelet", "metrics_path": "/metrics/resource"], 4000),
            series(["overterm_s": "ksm", "job": "kube-state-metrics-b"], 50),
            series(["overterm_s": "ksm", "job": "kube-state-metrics-a"], 50),
            series(["overterm_s": "node"], 9000),
        ])
        XCTAssertEqual(stack.cadvisorPath, "/metrics/cadvisor")
        XCTAssertEqual(stack.cadvisorJob, "kubelet")
        XCTAssertFalse(stack.cadvisorJobPinned, "one job: the path separates them")
        XCTAssertEqual(stack.ksmJob, "kube-state-metrics-a", "the first in name order")
        XCTAssertEqual(stack.nodeLabel, .node)
        XCTAssertEqual(stack.cadvisorMatchers, #"container!="",image!="",container!="POD",metrics_path="/metrics/cadvisor""#)
        XCTAssertEqual(stack.ksmMatcher, #"job="kube-state-metrics-a""#)

        // The prometheus chart: no metrics_path, one job each, the node in `instance`.
        var chart = KubePromProfile(probed: Date())
        chart.read(duplicates: [
            series(["overterm_s": "cadvisor", "job": "kubernetes-nodes-cadvisor"], 4000), series(["overterm_s": "ksm", "job": "kubernetes-service-endpoints"], 50),
        ])
        XCTAssertNil(chart.cadvisorPath, "nothing pinned by a label it doesn't set")
        XCTAssertNil(chart.ksmJob)
        XCTAssertEqual(chart.nodeLabel, .instance)
        XCTAssertEqual(chart.cadvisorMatchers, KubePromQL.containers)

        // Two jobs scraping cAdvisor: the one at its path pinned.
        var twice = KubePromProfile(probed: Date())
        twice.read(duplicates: [
            series(["overterm_s": "cadvisor", "job": "kubelet", "metrics_path": "/metrics/cadvisor"], 1),
            series(["overterm_s": "cadvisor", "job": "cadvisor-extra"], 1),
        ])
        XCTAssertTrue(twice.cadvisorJobPinned)
        XCTAssertTrue(twice.cadvisorMatchers.hasSuffix(#",job="kubelet""#))
        // No cAdvisor at all: no node label.
        var none = KubePromProfile(probed: Date())
        none.read(duplicates: [])
        XCTAssertNil(none.nodeLabel)
    }

    func testTheScrapeIsTheCAdvisorJobsAndRounded() {
        XCTAssertEqual(KubePromProfile.scrapeQuery(job: "kubelet"), #"600 / max(count_over_time(up{job="kubelet"}[10m]))"#, "that job's up, not every job's")
        XCTAssertEqual(KubePromProfile.scrape(15), 15)
        XCTAssertEqual(KubePromProfile.scrape(20), 15)
        XCTAssertEqual(KubePromProfile.scrape(30), 30)
        XCTAssertEqual(KubePromProfile.scrape(31.6), 30, "a missed sample or two")
        XCTAssertEqual(KubePromProfile.scrape(60), 60)
        XCTAssertEqual(KubePromProfile.scrape(120), 60)
        XCTAssertNil(KubePromProfile.scrape(nil))
        XCTAssertNil(KubePromProfile.scrape(.infinity))
        XCTAssertEqual(KubePromProfile.retention(1_800_000_000), Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(KubePromProfile.retention(0))
        XCTAssertEqual(KubePromProfile.unknown.scrapeInterval, 60, "a minute until it is read")
    }

    func testWhatExistsSaysWhatIsMissing() {
        XCTAssertTrue(KubePromProfile.existsQuery.hasPrefix(#"count by (__name__) ({__name__=~"container_cpu_usage_seconds_total|"#))
        XCTAssertTrue(KubePromProfile.existsQuery.contains("kube_pod_container_resource_requests_cpu_cores|"))
        XCTAssertTrue(KubePromProfile.existsQuery.contains("|prometheus_tsdb_lowest_timestamp_seconds\"})"))
        let metrics = KubePromProfile.metrics([
            series(["__name__": "container_cpu_usage_seconds_total"], 9000), series(["__name__": "kube_pod_container_resource_requests_cpu_cores"], 10),
        ])
        var old = KubePromProfile(probed: Date())
        old.metrics = metrics
        XCTAssertEqual(old.ksmMajor, 1)
        XCTAssertEqual(old.missing, [.ksmOld, .noThrottling])
        XCTAssertEqual(KubeChartEmpty.ksmOld.sentence, "kube-state-metrics is older than 2.0; requests and limits use its old names.")
        XCTAssertTrue(KubeChartEmpty.ksmOld.isFootnote)
        XCTAssertEqual(KubePromQL.requests("cpu", profile: old).contains("kube_pod_container_resource_requests_cpu_cores{}"), true)
        XCTAssertEqual(KubePromQL.allocatable("memory", profile: old), "sum(max by (node)(kube_node_status_allocatable_memory_bytes{}))")
        var none = old
        none.metrics = ["container_cpu_usage_seconds_total": 9000]
        XCTAssertTrue(none.ksmMissing)
        XCTAssertEqual(none.missing.first, .ksmMissing)
        let cluster = KubeChart.cluster.queries(range: .hour, profile: none)
        XCTAssertTrue(cluster.totals.isEmpty, "no requests asked of a server without kube-state-metrics")
        XCTAssertEqual(cluster.notes, ["kube-state-metrics isn't scraped: no requests or limits over time."])
        XCTAssertTrue(KubePromProfile.unknown.missing.isEmpty, "unknown: nothing said missing")
        XCTAssertTrue(KubePromProfile.unknown.mayHave("container_fs_usage_bytes"))
        XCTAssertFalse(KubePromProfile.unknown.has("container_fs_usage_bytes"))
    }

    // MARK: Tiers

    private var stack: KubePromProfile {
        var profile = KubePromProfile(probed: Date())
        profile.metrics = FakePromProfile.kubePrometheusStack.metrics
        profile.cadvisorPath = "/metrics/cadvisor"
        profile.cadvisorJob = "kubelet"
        profile.ksmJob = "kube-state-metrics"
        profile.scrape = 30
        return profile
    }

    func testEachChartReadsTheBestTierThePrometheusHas() {
        // Rules: the cluster at every range, 5-minute averages.
        for range in KubeChartRange.allCases {
            let queries = KubeChart.cluster.queries(range: range, profile: stack)
            XCTAssertEqual(queries.tier, .rules, "\(range)")
            XCTAssertNil(queries.refused)
            XCTAssertEqual(
                queries.series.map(\.1),
                [
                    "sum(instance:node_cpu_utilisation:rate5m * on(instance) instance:node_num_cpu:sum)",
                    "sum(instance:node_memory_utilisation:ratio * on(instance) node_memory_MemTotal_bytes)",
                ])
            XCTAssertEqual(queries.totals.first?.1, "sum(max by (namespace,pod,container,node)(cluster:namespace:pod_cpu:active:kube_pod_container_resource_requests))")
        }
        XCTAssertEqual(KubeChartReading.caption(.rules, chart: .cluster, profile: stack), "recording rules (5 min averages) · scrape 30s")
        // node-exporter, then raw up to 6 h, then refused with the samples it would read.
        var exporter = stack
        for name in [KubePromProfile.nodeCPURule, KubePromProfile.nodeMemoryRule, KubePromProfile.activeRequestsRule] { exporter.metrics?[name] = nil }
        let node = KubeChart.cluster.queries(range: .week, profile: exporter)
        XCTAssertEqual(node.tier, .nodeExporter)
        XCTAssertEqual(node.series.first?.1, #"sum(rate(node_cpu_seconds_total{mode!~"idle|iowait|steal"}[61m]))"#, "a week's step and a 30 s scrape")
        XCTAssertEqual(
            node.totals.first?.1,
            #"sum(max by (namespace,pod,container,node)(kube_pod_container_resource_requests{job="kube-state-metrics",resource="cpu"}) * on(namespace,pod) group_left() max by (namespace,pod)(kube_pod_status_phase{job="kube-state-metrics",phase=~"Pending|Running"} == 1))"#,
            "kube-state-metrics' job pinned")
        var raw = KubePromProfile(probed: Date())
        raw.metrics = FakePromProfile.noNodeExporter.metrics
        raw.scrape = 60
        let hour = KubeChart.cluster.queries(range: .hour, profile: raw)
        XCTAssertEqual(hour.tier, .raw)
        XCTAssertEqual(KubeChartReading.caption(.raw, chart: .cluster, profile: raw), "raw cAdvisor (≤ 6h) · scrape 1m")
        let day = KubeChart.cluster.queries(range: .day, profile: raw)
        XCTAssertNil(day.tier)
        XCTAssertTrue(day.series.isEmpty)
        XCTAssertEqual(
            day.refused, "Raw container metrics over 24h would read about 13M samples, and this Prometheus has no recording rules. Pick 6h or less.",
            "9,000 series a minute for a day")
        XCTAssertEqual(KubeChart.cluster.queries(range: .day).refused, KubeChart.rawRefusal(.day), "unknown: as before the probe")

        // A pod: raw, pinned, over an hour or less even with rules; the rules past it.
        let close = KubeTabTesting.plan(.hour, profile: stack)
        XCTAssertEqual(close.tier, .raw)
        XCTAssertEqual(
            close.queries.first { $0.id == "cpu" }?.promql,
            #"sum by (container)(rate(container_cpu_usage_seconds_total{container!="",image!="",container!="POD",metrics_path="/metrics/cadvisor",namespace="shop",pod="web-1"}[2m]))"#
        )
        let far = KubeTabTesting.plan(.week, profile: stack)
        XCTAssertEqual(far.tier, .rules)
        XCTAssertEqual(
            far.queries.filter { [.cpu, .memory].contains($0.family) }.map(\.promql),
            [
                #"max by (container)(node_namespace_pod_container:container_cpu_usage_seconds_total:sum_rate5m{namespace="shop",pod="web-1",container!="",container!="POD"})"#,
                #"max by (container)(max_over_time(node_namespace_pod_container:container_memory_working_set_bytes{namespace="shop",pod="web-1",container!="",container!="POD"}[30m]))"#,
            ])
        XCTAssertEqual(KubeTabTesting.plan(.week, profile: raw).tier, .raw, "no rules: raw, a pod's series are cheap")
        XCTAssertFalse(KubeChart.volume(namespace: "shop", claim: "data").needsProfile, "a volume's queries ask no probe")
    }

    // MARK: The cost caps

    /// The mixin's active-pod rules keep kube-state-metrics' `instance`:
    /// two replicas in one job, two of each series — taken once, as the raw tier is.
    func testTheRulesTierCountsTwoKSMReplicasOnce() throws {
        var series: [FakePromQL.Series] = []
        for instance in ["10.0.0.1:8080", "10.0.0.2:8080"] {
            let ksm = ["instance": instance, "job": "kube-state-metrics", "node": "fake-node-1", "namespace": "shop"]
            for (pod, container, cpu, memory) in [("web-1", "app", 0.5, 256.0), ("web-1", "proxy", 0.1, 64.0), ("web-2", "app", 0.5, 256.0)] {
                let labels = ksm.merging(["pod": pod, "container": container]) { $1 }
                series.append(("cluster:namespace:pod_cpu:active:kube_pod_container_resource_requests", labels, cpu))
                series.append(("cluster:namespace:pod_memory:active:kube_pod_container_resource_limits", labels, memory))
            }
        }
        let requests = KubePromQL.requests("cpu", profile: stack)
        XCTAssertEqual(try XCTUnwrap(FakePromQL.evaluate(requests, series)?.first?.value), 1.1, accuracy: 1e-9, "each container once, whichever replica said it")
        XCTAssertEqual(FakePromQL.evaluate(KubePromQL.limits("memory", profile: stack), series)?.first?.value, 576)
        XCTAssertEqual(
            FakePromQL.evaluate("sum(cluster:namespace:pod_cpu:active:kube_pod_container_resource_requests)", series)?.first?.value ?? 0, 2.2, accuracy: 1e-9,
            "summed bare, it would double")
    }

    func testTheCostCapsRefuseBeforeSending() {
        var raw = KubePromProfile(probed: Date())
        raw.metrics = ["container_cpu_usage_seconds_total": 2000]
        raw.scrape = 30
        XCTAssertEqual(KubeQueryCost.samples(series: 2000, span: 7 * 86400, scrape: 30), 40_320_000)
        XCTAssertEqual(KubeQueryCost.said(40_320_000), "40M")
        XCTAssertEqual(KubeQueryCost.said(4500), "5k")
        XCTAssertTrue(KubeQueryCost.raw(.cluster, span: 6 * 3600, profile: raw).isAllowed)
        XCTAssertFalse(KubeQueryCost.raw(.cluster, span: 24 * 3600, profile: raw).isAllowed)
        XCTAssertTrue(KubeQueryCost.raw(.pod, span: 7 * 86400, profile: raw).isAllowed)
        XCTAssertTrue(KubeQueryCost.raw(.namespace("shop", series: 1999), span: 7 * 86400, profile: raw).isAllowed)
        XCTAssertEqual(
            KubeQueryCost.raw(.namespace("shop", series: 2400), span: 24 * 3600, profile: raw).sentence,
            "Raw container metrics of shop (2400 series) over 24h would read about 7M samples, and this Prometheus has no recording rules. Pick a workload in it.")
        XCTAssertTrue(KubeQueryCost.raw(.namespace("shop", series: nil), span: 3600, profile: raw).isAllowed)
        XCTAssertFalse(KubeQueryCost.raw(.namespace("shop", series: nil), span: 86400, profile: raw).isAllowed, "uncounted: as the cluster")
        // Subqueries: one pod, a workload of 50 pods, or rules.
        XCTAssertTrue(KubeQueryCost.subquery(.pod, profile: raw).isAllowed)
        XCTAssertTrue(KubeQueryCost.subquery(.workload(pods: 50), profile: raw).isAllowed)
        XCTAssertFalse(KubeQueryCost.subquery(.workload(pods: 51), profile: raw).isAllowed)
        XCTAssertTrue(KubeQueryCost.subquery(.workload(pods: 500), profile: stack).isAllowed)
        XCTAssertFalse(KubeQueryCost.subquery(.cluster, profile: raw).isAllowed)
        XCTAssertTrue(KubeQueryCost.names(50).isAllowed)
        XCTAssertFalse(KubeQueryCost.names(51).isAllowed)
        XCTAssertEqual(KubeQueryCost.rankingSpan(series: 2000, span: 7 * 86400, scrape: 30).span, 86400)
        XCTAssertEqual(KubeQueryCost.rankingSpan(series: 2000, span: 7 * 86400, scrape: 30).note, "ranked by the last 24h")
        XCTAssertEqual(KubeQueryCost.rankingSpan(series: 100, span: 7 * 86400, scrape: 30).span, 7 * 86400)
    }

    // MARK: The sentences

    func testEveryEmptyChartSaysWhyInOneSentence() {
        let cases: [(KubeChartEmpty, String)] = [
            (.noMetricsServer, "No metrics-server in this cluster: there are no usage numbers without it or Prometheus."),
            (.noMetricsServerPrometheus, "No metrics-server in this cluster: the Metrics tab's charts come from Prometheus, once it is found."),
            (.ksmMissing, "kube-state-metrics isn't scraped: no requests or limits over time."),
            (.noThrottling, "This cluster's kubelet doesn't report CPU throttling."),
            (
                .costRefused(what: "Raw container metrics", span: "24h", samples: 30_000_000, rules: false, pick: "6h or less"),
                "Raw container metrics over 24h would read about 30M samples, and this Prometheus has no recording rules. Pick 6h or less."
            ),
            (.timeout, "Prometheus took longer than 20 s. Pick a shorter range."),
            (.badData("1:5: parse error: unexpected )"), "Prometheus refused the query: 1:5: parse error: unexpected )."),
            (.partial("store eu-1 timed out"), "Partial answer: store eu-1 timed out"),
            (
                .agentMode(KubePrometheusService(namespace: "monitoring", name: "prometheus-agent", port: "9090")!),
                "Prometheus at monitoring/prometheus-agent only forwards metrics to a remote store (agent mode); it can't be asked."
            ),
            (.serviceProxyForbidden(service), "You can't reach monitoring/prometheus-operated here: `get services/proxy` is refused in monitoring."),
            (.metricsServerForbidden(verb: "list", resource: "pods.metrics.k8s.io", place: " in api"), "metrics-server answered 403: you can't list pods.metrics.k8s.io in api."),
            (.credential("The AWS SSO session expired: sign in again."), "The AWS SSO session expired: sign in again."),
            (.filterRefused, "Overterm's metrics proxy refused this path."),
            (.requestsNeedSpecs, "Requests need the pods' specs; pick one node or turn Prometheus on."),
            (.busy(status: 503, retryAfter: 30), "Prometheus is busy (HTTP 503); asked again in 30 s."),
            (.busy(status: 429, retryAfter: nil), "Prometheus is busy (HTTP 429); asked again at the next refresh."),
        ]
        for (cause, sentence) in cases { XCTAssertEqual(cause.sentence, sentence) }
        XCTAssertTrue(KubeChartEmpty.badData("x").offersCopyPromQL && KubeChartEmpty.filterRefused.offersCopyPromQL)
        XCTAssertFalse(KubeChartEmpty.timeout.offersCopyPromQL)
        XCTAssertEqual(KubeChartEmpty.timeout.sentence, KubePrometheusReader.tookTooLong)
        let started = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 28, hour: 14, minute: 2).date!
        XCTAssertEqual(KubeChartEmpty.youngPod(started).sentence, "Pod started 14:02")
        XCTAssertEqual(KubeChartEmpty.retention(started).sentence, "Prometheus keeps data from Oct 28")
        XCTAssertTrue(KubeChartEmpty.retention(started).isFootnote && KubeChartEmpty.youngPod(started).isFootnote)
        XCTAssertEqual(KubeMetricsTarget.node("a").refusal, KubeChartEmpty.metricsServerForbidden(verb: "get", resource: "nodes.metrics.k8s.io", place: "").sentence)
    }

    func testTheReaderSaysWhatFailed() throws {
        func failure(_ status: Int, _ body: String, headers: [(String, String)] = []) -> KubePrometheusReader.Failure? {
            do {
                _ = try KubePrometheusReader.answer(HTTPResponse(status: status, headers: headers, body: Data(body.utf8)))
                return nil
            } catch {
                return error as? KubePrometheusReader.Failure
            }
        }
        XCTAssertEqual(failure(503, #"{"status":"error","errorType":"unavailable","error":"unavailable with Prometheus Agent"}"#)?.kind, .agentMode)
        XCTAssertEqual(failure(404, "404 page not found")?.kind, .notFound, "the Service answers, its query API doesn't")
        XCTAssertEqual(failure(404, #"{"kind":"Status","code":404,"message":"services \"x\" not found"}"#)?.kind, .serviceMissing)
        XCTAssertEqual(failure(403, #"{"kind":"Status","code":403,"message":"forbidden"}"#)?.kind, .serviceProxyForbidden)
        XCTAssertEqual(failure(403, "Forbidden\n")?.kind, .filterRefused, "kubectl proxy's filter")
        XCTAssertEqual(failure(403, "Forbidden\n")?.message, "Overterm's metrics proxy refused this path.")
        XCTAssertEqual(failure(422, #"{"status":"error","errorType":"execution","error":"many-to-many matching"}"#)?.kind, .unprocessable)
        XCTAssertEqual(failure(400, #"{"status":"error","errorType":"bad_data","error":"parse error"}"#)?.message, "Prometheus refused the query: parse error.")
        let busy = failure(503, "upstream connect error", headers: [("Retry-After", "12")])
        XCTAssertEqual(busy?.kind, .busy)
        XCTAssertEqual(busy?.retryAfter, 12)
        XCTAssertTrue(busy?.stopsQueries == true)
        // A 503 without Retry-After is a server down, not busy: the apiserver's own words kept.
        let down = failure(503, #"{"kind":"Status","code":503,"reason":"ServiceUnavailable","message":"no endpoints available for service \"prometheus-operated\""}"#)
        XCTAssertEqual(down?.kind, .other)
        XCTAssertEqual(down?.message, #"The service proxy answered 503: no endpoints available for service "prometheus-operated""#)
        XCTAssertFalse(down?.stopsQueries == true, "asked again at the next refresh")
        XCTAssertEqual(failure(503, "upstream connect error")?.kind, .other)
        XCTAssertEqual(failure(503, #"{"kind":"Status","code":503,"message":"x"}"#, headers: [("Retry-After", "5")])?.kind, .busy, "with Retry-After: busy")
        XCTAssertEqual(failure(429, #"{"kind":"Status","code":429,"message":"too many requests"}"#)?.kind, .busy, "a 429 always")
    }

    /// `Retry-After` comes from the cluster: only whole seconds, capped at
    /// the queue's longest pause — and the sentence says that same pause.
    func testRetryAfterIsReadSafelyAndSaidAsTheQueueTakesIt() {
        for header in ["nan", "inf", "-inf", "-5", "1e300", "1.5", "99999999999999999999999", "Wed, 21 Oct 2026 07:28:00 GMT", "", "  "] {
            XCTAssertNil(KubePrometheusReader.retryAfter(header), header)
        }
        XCTAssertNil(KubePrometheusReader.retryAfter(nil))
        XCTAssertEqual(KubePrometheusReader.retryAfter(" 12 "), 12)
        XCTAssertEqual(KubePrometheusReader.retryAfter("0"), 0)
        XCTAssertEqual(KubePrometheusReader.retryAfter("3600"), KubePromQueue.maxPause, "capped")
        func failure(_ after: String) -> KubePrometheusReader.Failure? {
            let body = Data(#"{"kind":"Status","code":429,"message":"too many requests"}"#.utf8)
            do {
                _ = try KubePrometheusReader.answer(HTTPResponse(status: 429, headers: [("Retry-After", after)], body: body))
                return nil
            } catch {
                return error as? KubePrometheusReader.Failure
            }
        }
        XCTAssertEqual(failure("3600")?.message, "Prometheus is busy (HTTP 429); asked again in 300 s.", "the pause the queue takes")
        XCTAssertEqual(failure("3600")?.retryAfter, 300)
        for header in ["nan", "inf", "1e300", "-5"] {
            XCTAssertEqual(failure(header)?.message, "Prometheus is busy (HTTP 429); asked again at the next refresh.", header)
        }
    }

    // MARK: The probe

    private var api: FakeKubeAPI!
    private var socket: String!

    override func setUp() async throws {
        socket = "/tmp/otkpp-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("monitoring")
        api.servePrometheus(namespace: "monitoring", service: "prometheus-operated", port: "9090")
    }

    override func tearDown() async throws {
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
            XCTAssertFalse(api.requests.contains { $0.path.contains("nodes/") && $0.path.contains("/proxy") }, "never a node's proxy")
            api.stop()
        }
    }

    private var direct: KubePrometheusDirect { KubePrometheusDirect(connection: KubeSocketConnection(socket: socket, context: "fake-dev"), service: service) }
    private var asked: [FakeKubeAPI.Request] { api.requests.filter(\.isPrometheusQuery) }

    private func probe() async throws -> KubePromProfile {
        let direct = self.direct
        let service = self.service
        return try await KubePromProfile.probe(at: Date()) { query in
            try await KubePrometheusMonitor.fetch(direct, KubePromQL.instantPath(service, query), deadline: .seconds(5))
        }
    }

    func testTheProbeAsksDCGMsLabelsOnlyWhereItIsScraped() async throws {
        api.setPrometheusProfile(.gpuOperator)
        let profile = try await probe()
        XCTAssertEqual(asked.count, 5, "one more query, DCGM exporter's labels")
        XCTAssertEqual(asked.last?.query["query"], KubePromProfile.dcgmQuery)
        XCTAssertTrue(asked.allSatisfy { $0.path == service.queryPath && $0.query["timeout"] == "20s" })
        XCTAssertTrue(profile.hasDCGM)
        XCTAssertEqual(profile.dcgm, KubePromProfile.DCGM(podPrefix: "exported_", namesPods: true, nodeLabel: "Hostname", mig: false))
        // No GPU allocated when probed, honor_labels off: every `pod` the
        // exporter's own — the exported labels read, never `pod`.
        api.forgetRequests()
        api.setPrometheusProfile(.gpuOperatorIdle)
        let idle = try await probe()
        XCTAssertEqual(idle.dcgm, KubePromProfile.DCGM(podPrefix: "exported_", namesPods: true, nodeLabel: "Hostname", mig: false))
        api.forgetRequests()
        api.setPrometheusProfile(.kubePrometheusStack)
        let stack = try await probe()
        XCTAssertEqual(asked.count, 4, "no DCGM exporter: not asked")
        XCTAssertNil(stack.dcgm)
        XCTAssertFalse(stack.hasDCGM)
    }

    func testTheProbeAsksFourQueriesOneAfterAnother() async throws {
        api.setPrometheusProfile(.kubePrometheusStack)
        let profile = try await probe()
        XCTAssertEqual(asked.count, 4)
        XCTAssertTrue(asked.allSatisfy { $0.path == service.queryPath && $0.query["timeout"] == "20s" }, "instant queries, each given 20 s")
        XCTAssertEqual(asked.map { $0.query["query"] ?? "" }.last, KubePromProfile.retentionQuery)
        XCTAssertEqual(asked[2].query["query"], KubePromProfile.scrapeQuery(job: "kubelet"))
        XCTAssertTrue(profile.hasNodeRules && profile.hasContainerRules && profile.hasActiveRules)
        XCTAssertEqual(profile.cadvisorPath, "/metrics/cadvisor")
        XCTAssertEqual(profile.ksmJob, "kube-state-metrics")
        XCTAssertEqual(profile.nodeLabel, .node)
        XCTAssertEqual(profile.scrape, 30)
        XCTAssertNotNil(profile.retention)
        XCTAssertEqual(profile.count("container_cpu_usage_seconds_total"), 9000)

        api.forgetRequests()
        api.setPrometheusProfile(.noNodeExporter)
        let chart = try await probe()
        XCTAssertEqual(asked.count, 3, "no retention metric: three queries")
        XCTAssertNil(chart.retention, "unknown, not hatched")
        XCTAssertEqual(chart.scrape, 60)
        XCTAssertEqual(chart.nodeLabel, .instance)
        XCTAssertNil(chart.cadvisorPath)
        XCTAssertFalse(chart.hasNodeExporter || chart.nodeExporterMapped)

        api.forgetRequests()
        api.setPrometheusProfile(.agentMode)
        let agent = try await probe()
        XCTAssertTrue(agent.agentOnly)
        XCTAssertEqual(asked.count, 1, "one query says it")

        // A Prometheus that refuses what exists: unknown, the charts as before.
        api.clearPrometheusMatrix("")
        api.clearPrometheusMatrix("count by (__name__)")
        api.forgetRequests()
        let refused = try await probe()
        XCTAssertFalse(refused.known)
        XCTAssertEqual(refused.problem?.hasPrefix("Prometheus refused the query:"), true)
        XCTAssertEqual(asked.count, 1)

        // The services/proxy 403 is thrown: it stops the context.
        api.refusePrometheusProxy(403)
        do {
            _ = try await probe()
            XCTFail("refused")
        } catch let failure as KubePrometheusReader.Failure {
            XCTAssertEqual(failure.kind, .serviceProxyForbidden)
        }
    }

    // MARK: The monitor

    private func monitor() -> KubePrometheusMonitor {
        let monitor = KubePrometheusMonitor()
        monitor.interval = .milliseconds(80)
        let socket = self.socket!
        monitor.update(
            KubePrometheusMonitor.Situation(context: "fake-dev", use: .configured(service), scope: .namespace("shop")), client: { nil },
            transport: { KubePrometheusDirect(connection: KubeSocketConnection(socket: socket, context: "fake-dev"), service: $0) },
            close: { _ in })
        return monitor
    }

    private func until(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func probesAsked() -> [FakeKubeAPI.Request] {
        asked.filter { ($0.query["query"] ?? "").contains("count by (__name__)") }
    }

    func testTheMonitorProbesOnceAContextAndReadsTheTierItAllows() async throws {
        api.setPrometheusProfile(.kubePrometheusStack)
        api.setPrometheusSeries(KubePromProfile.nodeCPURule, labels: ["instance": "10.0.0.1:9100"], value: 0.5)
        api.setPrometheusSeries(KubePromProfile.nodeCPUCountRule, labels: ["instance": "10.0.0.1:9100"], value: 4)
        api.setPrometheusSeries(KubePromProfile.nodeMemoryRule, labels: ["instance": "10.0.0.1:9100"], value: 0.25)
        api.setPrometheusSeries("node_memory_MemTotal_bytes", labels: ["instance": "10.0.0.1:9100"], value: 8_589_934_592)
        let cadvisor = ["namespace": "shop", "pod": "web-1", "container": "app", "image": "nginx:1.27"]
        api.setPrometheusSeries("container_cpu_usage_seconds_total", labels: cadvisor.merging(["metrics_path": "/metrics/cadvisor"]) { $1 }, value: 0.25)
        // The same counter at kubelet's resource path: pinned away, not doubled.
        api.setPrometheusSeries("container_cpu_usage_seconds_total", labels: cadvisor.merging(["metrics_path": "/metrics/resource"]) { $1 }, value: 0.25)
        api.setPrometheusSeries("container_memory_working_set_bytes", labels: cadvisor.merging(["metrics_path": "/metrics/cadvisor"]) { $1 }, value: 1024)
        let monitor = monitor()
        let owner = NSObject()
        let other = NSObject()
        let pod = KubeTabTesting.request(.day, families: [.cpu, .memory])
        monitor.range = .day
        monitor.want([.chart(.cluster)], for: owner)
        monitor.want([.tab(pod)], for: other)
        try await until("charted") { monitor.charts[.cluster]?.read != nil && monitor.tabs[pod]?.read != nil }
        XCTAssertEqual(monitor.tabs[pod]?.tier, .rules, "a pod's day from the rules")
        XCTAssertEqual(probesAsked().count, 1, "two charts, one probe")
        XCTAssertEqual(monitor.probes, 1)
        XCTAssertEqual(monitor.profile?.scrape, 30)
        let cluster = try XCTUnwrap(monitor.charts[.cluster])
        XCTAssertEqual(cluster.tier, .rules)
        XCTAssertNil(cluster.refused, "24h drawn from the rules")
        XCTAssertEqual(cluster.series[.cpu]?.last?.value, 2, "half of four cores")
        XCTAssertTrue(cluster.caption?.hasPrefix("recording rules") == true)
        XCTAssertNotNil(cluster.retention)
        XCTAssertTrue(cluster.notes.contains { $0.hasPrefix("Prometheus keeps data from") } == false, "ten days kept: not inside a day")
        let hour = KubeTabTesting.request(.hour, families: [.cpu, .memory])
        monitor.want([.tab(hour)], for: other)
        try await until("an hour") { monitor.tabs[hour]?.read != nil }
        XCTAssertEqual(monitor.tabs[hour]?.tier, .raw)
        XCTAssertEqual(monitor.tabs[hour]?.results["cpu"]?.first?.points.last?.value, 0.25, "one path's counter, not two")
        XCTAssertTrue(asked.contains { $0.query["query"]?.contains("[2m]") == true }, "a 30 s scrape's rate window")

        // Hidden and shown: kept; an hour on: asked again.
        monitor.want([], for: owner)
        monitor.want([], for: other)
        monitor.want([.chart(.cluster)], for: owner)
        try await until("again") { monitor.charts[.cluster]?.read != nil }
        XCTAssertEqual(probesAsked().count, 1, "kept while the page hid")
        monitor.forgetProfile()
        try await until("probed again") { self.probesAsked().count == 2 }
        monitor.want([], for: owner)
    }

    func testAgentModeIsSaidAndNotRetried() async throws {
        api.setPrometheusProfile(.agentMode)
        let monitor = monitor()
        let owner = NSObject()
        monitor.want([.chart(.cluster)], for: owner)
        try await until("said") { monitor.charts[.cluster]?.unavailable != nil }
        XCTAssertEqual(
            monitor.charts[.cluster]?.unavailable,
            "Prometheus at monitoring/prometheus-operated only forwards metrics to a remote store (agent mode); it can't be asked.")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(asked.count, 1, "nothing asked again within the hour")
        monitor.want([], for: owner)
    }

    func testAServiceProxy403StopsTheContextUntilItsCredentialsChange() async throws {
        api.setPrometheusProfile(.noNodeExporter)
        api.refusePrometheusProxy(403)
        let monitor = monitor()
        let owner = NSObject()
        monitor.want([.chart(.cluster)], for: owner)
        try await until("said") { monitor.charts[.cluster]?.problem != nil }
        XCTAssertEqual(monitor.charts[.cluster]?.problem, KubeChartEmpty.serviceProxyForbidden(service).sentence)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(asked.count, 1, "said once; nothing retried")
        XCTAssertFalse(monitor.isPolling)
        // Signed in again: asked again.
        api.refusePrometheusProxy(nil)
        monitor.retry()
        try await until("read after the sign-in") { monitor.charts[.cluster]?.read != nil && monitor.charts[.cluster]?.problem == nil }
        monitor.want([], for: owner)
    }

    /// The kubeconfig points the context at another cluster or user: the
    /// queue a 403 stopped isn't kept — no Try Again needed.
    func testAStoppedQueueIsntKeptWhenTheContextsClusterChanges() async throws {
        api.setPrometheusProfile(.noNodeExporter)
        api.refusePrometheusProxy(403)
        let monitor = monitor()
        let owner = NSObject()
        monitor.want([.chart(.cluster)], for: owner)
        try await until("said") { monitor.charts[.cluster]?.problem == KubeChartEmpty.serviceProxyForbidden(service).sentence }
        api.refusePrometheusProxy(nil)
        let socket = self.socket!
        monitor.update(
            KubePrometheusMonitor.Situation(context: "fake-dev", use: .configured(service), scope: .namespace("shop"), cluster: "fake-dev-2 as admin"),
            client: { nil }, transport: { KubePrometheusDirect(connection: KubeSocketConnection(socket: socket, context: "fake-dev"), service: $0) },
            close: { _ in })
        try await until("read on the new cluster") { monitor.charts[.cluster]?.read != nil && monitor.charts[.cluster]?.problem == nil }
        monitor.want([], for: owner)
    }

    func testRetryAfterPausesTheChartsQueries() async throws {
        api.setPrometheusProfile(.noNodeExporter)
        api.refusePrometheusProxy(429, retryAfter: 2)
        let monitor = monitor()
        let owner = NSObject()
        monitor.want([.chart(.cluster)], for: owner)
        try await until("said") { monitor.charts[.cluster]?.problem == "Prometheus is busy (HTTP 429); asked again in 2 s." }
        api.refusePrometheusProxy(nil)
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(asked.count, 1, "paused: the polls every 80 ms send nothing")
        try await until("read once the pause ended") { monitor.charts[.cluster]?.read != nil }
        monitor.want([], for: owner)
    }
}
