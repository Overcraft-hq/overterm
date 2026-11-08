import Foundation
import XCTest

@testable import Overterm

/// The Pods list's shares of request and limit (metrics.md 2.1, stage
/// M5b): kube-state-metrics' one union a namespace, read by pod; a pod
/// whose containers don't all set a request (a limit) has no share of one;
/// a limit's share warmer from 80% and red from 100%; `k8s_top`'s named
/// pod read from its own object. Pure — the monitor's reads are in
/// `KubePrometheusTests`, the page's without Prometheus at the end here.
@MainActor
final class KubePodSharesTests: XCTestCase {
    private func series(_ arm: String, _ pod: String, _ resource: String? = nil, _ value: Double, namespace: String = "shop") -> KubeSeries {
        var labels = ["namespace": namespace, "pod": pod, KubePodShares.label: arm]
        if let resource { labels["resource"] = resource }
        return KubeSeries(labels: labels, points: [KubeSeriesPoint(time: Date(), value: value)])
    }

    func testTheQueryIsOneUnionForTheNamespaceItsJobPinned() {
        let query = KubePodShares.query(namespace: "acme.web", profile: .unknown)
        XCTAssertTrue(query.contains(#"kube_pod_container_info{namespace="acme.web"}"#), query)
        XCTAssertTrue(query.contains(#"kube_pod_container_resource_requests{namespace="acme.web",resource=~"cpu|memory"}"#), query)
        XCTAssertTrue(query.contains(#"kube_pod_container_resource_limits{namespace="acme.web",resource=~"cpu|memory"}"#), query)
        XCTAssertTrue(query.contains("max by (namespace,pod,container,resource)("), "each container's series taken once (two replicas)")
        XCTAssertTrue(query.contains("and on(namespace,pod,resource)"), "a pod's sum only where every container sets it")
        XCTAssertTrue(query.contains("== on(namespace,pod) group_left() count by (namespace,pod)"), query)
        for arm in ["containers", "request", "limit"] {
            XCTAssertTrue(query.contains(#""overterm_s","\#(arm)","","""#), arm)
        }
        XCTAssertFalse(query.contains("__"), "no reserved label")
        XCTAssertEqual(query.components(separatedBy: ") or label_replace(").count, 3, "three arms, one query")

        var pinned = KubePromProfile.unknown
        pinned.ksmJob = "kube-state-metrics"
        let withJob = KubePodShares.query(namespace: "shop", profile: pinned)
        XCTAssertTrue(withJob.contains(#"kube_pod_container_info{job="kube-state-metrics",namespace="shop"}"#), withJob)
        XCTAssertFalse(withJob.contains(#"{namespace="shop""#), "every selector pinned")

        var old = KubePromProfile.unknown
        old.metrics = [KubePromProfile.requestsCPUCores: 10]
        let oldQuery = KubePodShares.query(namespace: "shop", profile: old)
        XCTAssertTrue(oldQuery.contains("kube_pod_container_resource_requests_cpu_cores{"), oldQuery)
        XCTAssertTrue(oldQuery.contains("kube_pod_container_resource_limits_memory_bytes{"), oldQuery)
        XCTAssertTrue(oldQuery.contains(#""resource","memory","","""#), "1.x's names given the resource label")

        let quoted = KubePodShares.query(namespace: #"we"ird"#, profile: .unknown)
        XCTAssertTrue(quoted.contains(#"namespace="we\"ird""#), "a literal escaped")
    }

    /// The query's exact text, for kube-state-metrics 2.x and 1.x: any
    /// change to its semantics — the completeness filter, a label, the
    /// dedup, the sidecars — shows here, and the evaluations below show
    /// what it means on raw series.
    func testTheQueryIsExactlyThisForBothVersions() {
        let current = KubePodShares.query(namespace: "shop", profile: .unknown)
        let info = #"max by (namespace,pod,container)(kube_pod_container_info{namespace="shop"})"#
        let sidecars = #"max by (namespace,pod,container)(kube_pod_init_container_info{namespace="shop",restart_policy="Always"})"#
        let containers = "count by (namespace,pod)(\(info) or \(sidecars))"
        func side(_ which: String) -> String {
            #"(max by (namespace,pod,container,resource)(kube_pod_container_resource_\#(which){namespace="shop",resource=~"cpu|memory"}) or "#
                + #"(max by (namespace,pod,container,resource)(kube_pod_init_container_resource_\#(which){namespace="shop",resource=~"cpu|memory"}) and on(namespace,pod,container) \#(sidecars)))"#
        }
        func complete(_ which: String) -> String {
            "sum by (namespace,pod,resource)(\(side(which))) and on(namespace,pod,resource) (count by (namespace,pod,resource)(\(side(which))) == on(namespace,pod) group_left() \(containers))"
        }
        XCTAssertEqual(
            current,
            #"label_replace(\#(containers),"overterm_s","containers","","") or label_replace(\#(complete("requests")),"overterm_s","request","","") or label_replace(\#(complete("limits")),"overterm_s","limit","","")"#
        )

        var old = KubePromProfile.unknown
        old.metrics = [KubePromProfile.requestsCPUCores: 10]
        let oldContainers = "count by (namespace,pod)(\(info))"
        func oldSide(_ which: String) -> String {
            #"(label_replace(max by (namespace,pod,container)(kube_pod_container_resource_\#(which)_cpu_cores{namespace="shop"}),"resource","cpu","","") or "#
                + #"label_replace(max by (namespace,pod,container)(kube_pod_container_resource_\#(which)_memory_bytes{namespace="shop"}),"resource","memory","",""))"#
        }
        func oldComplete(_ which: String) -> String {
            "sum by (namespace,pod,resource)(\(oldSide(which))) and on(namespace,pod,resource) (count by (namespace,pod,resource)(\(oldSide(which))) == on(namespace,pod) group_left() \(oldContainers))"
        }
        XCTAssertEqual(
            KubePodShares.query(namespace: "shop", profile: old),
            #"label_replace(\#(oldContainers),"overterm_s","containers","","") or label_replace(\#(oldComplete("requests")),"overterm_s","request","","") or label_replace(\#(oldComplete("limits")),"overterm_s","limit","","")"#
        )
    }

    /// The query evaluated (`FakePromQL`) over kube-state-metrics' raw
    /// series, as two replicas scrape them: each container once; a native
    /// sidecar counted and summed, an init container that ran to
    /// completion not; a pod one of whose containers sets no CPU limit has
    /// none; another namespace's pod not in it.
    func testTheQueryOnRawSeriesCountsEachContainerOnceAndANativeSidecar() throws {
        var raw: [FakePromQL.Series] = []
        func add(_ metric: String, _ labels: [String: String], _ value: Double = 1, namespace: String = "shop") {
            for instance in ["ksm-a", "ksm-b"] {
                raw.append((metric, labels.merging(["namespace": namespace, "instance": instance, "job": "kube-state-metrics"]) { $1 }, value))
            }
        }
        func resource(_ which: String, _ pod: String, _ container: String, cpu: Double?, memory: Double?, initial: Bool = false, namespace: String = "shop") {
            let metric = initial ? "kube_pod_init_container_resource_\(which)" : "kube_pod_container_resource_\(which)"
            if let cpu { add(metric, ["pod": pod, "container": container, "resource": "cpu", "unit": "core"], cpu, namespace: namespace) }
            if let memory { add(metric, ["pod": pod, "container": container, "resource": "memory", "unit": "byte"], memory, namespace: namespace) }
        }
        let mi = 1_048_576.0
        add("kube_pod_container_info", ["pod": "web-1", "container": "app", "image": "nginx:1.27"])
        add("kube_pod_container_info", ["pod": "web-1", "container": "proxy", "image": "envoy:1.30"])
        add("kube_pod_init_container_info", ["pod": "web-1", "container": "istio-proxy", "restart_policy": "Always"])
        add("kube_pod_init_container_info", ["pod": "web-1", "container": "migrate"])
        resource("requests", "web-1", "app", cpu: 0.25, memory: 64 * mi)
        resource("requests", "web-1", "proxy", cpu: 0.05, memory: 32 * mi)
        resource("requests", "web-1", "istio-proxy", cpu: 0.1, memory: 16 * mi, initial: true)
        resource("requests", "web-1", "migrate", cpu: 2, memory: 1024 * mi, initial: true)
        resource("limits", "web-1", "app", cpu: 1, memory: 128 * mi)
        resource("limits", "web-1", "proxy", cpu: nil, memory: 64 * mi)
        resource("limits", "web-1", "istio-proxy", cpu: 0.5, memory: 32 * mi, initial: true)
        add("kube_pod_container_resource_requests", ["pod": "web-1", "container": "app", "resource": "ephemeral_storage", "unit": "byte"], 1e9)
        add("kube_pod_container_info", ["pod": "api-0", "container": "app"], namespace: "billing")
        resource("requests", "api-0", "app", cpu: 1, memory: 1, namespace: "billing")

        let answer = try XCTUnwrap(FakePromQL.evaluate(KubePodShares.query(namespace: "shop", profile: .unknown), raw), "the fake reads the query")
        let series = answer.map { KubeSeries(labels: $0.labels, points: [KubeSeriesPoint(time: Date(), value: $0.value)]) }
        let specs = KubePodShares.read(series)
        XCTAssertEqual(Set(specs.keys), [KubeRowID(namespace: "shop", name: "web-1")], "billing isn't asked")
        let web = try XCTUnwrap(specs[KubeRowID(namespace: "shop", name: "web-1")])
        XCTAssertEqual(web.containers, 3, "app, proxy and the native sidecar, each once over two replicas; not migrate")
        XCTAssertEqual(web.cpuRequest ?? 0, 0.4, accuracy: 1e-9, "the sidecar's request in, migrate's out")
        XCTAssertEqual(web.memoryRequest ?? 0, 112 * mi, accuracy: 1)
        XCTAssertNil(web.cpuLimit, "proxy sets no CPU limit: the pod has none")
        XCTAssertEqual(web.memoryLimit ?? 0, 224 * mi, accuracy: 1)
        XCTAssertEqual(series.count, 4, "containers, two requests, the memory limit: \(series.map(\.labels))")

        // Pinned to one job where two answer.
        var pinned = KubePromProfile.unknown
        pinned.ksmJob = "other-ksm"
        XCTAssertEqual(FakePromQL.evaluate(KubePodShares.query(namespace: "shop", profile: pinned), raw)?.count, 0, "another job's series only")
    }

    /// KSM 1.x's names, given their resource by `label_replace`: the same
    /// answer; it has no `restart_policy`, so a sidecar isn't counted —
    /// and then the sample's extra container dashes the pod.
    func testTheQueryOnKSM1xSeriesAndASidecarItCantTell() throws {
        var raw: [FakePromQL.Series] = []
        for instance in ["a", "b"] {
            let base = ["namespace": "shop", "pod": "web-1", "instance": instance]
            raw.append(("kube_pod_container_info", base.merging(["container": "app"]) { $1 }, 1))
            raw.append(("kube_pod_init_container_info", base.merging(["container": "istio-proxy"]) { $1 }, 1))
            raw.append(("kube_pod_container_resource_requests_cpu_cores", base.merging(["container": "app"]) { $1 }, 0.5))
            raw.append(("kube_pod_container_resource_requests_memory_bytes", base.merging(["container": "app"]) { $1 }, 64))
            raw.append(("kube_pod_container_resource_limits_memory_bytes", base.merging(["container": "app"]) { $1 }, 128))
        }
        var old = KubePromProfile.unknown
        old.metrics = [KubePromProfile.requestsCPUCores: 10]
        let answer = try XCTUnwrap(FakePromQL.evaluate(KubePodShares.query(namespace: "shop", profile: old), raw))
        let specs = KubePodShares.read(answer.map { KubeSeries(labels: $0.labels, points: [KubeSeriesPoint(time: Date(), value: $0.value)]) })
        let web = try XCTUnwrap(specs[KubeRowID(namespace: "shop", name: "web-1")])
        XCTAssertEqual(web, KubePodShares.Spec(containers: 1, cpuRequest: 0.5, cpuLimit: nil, memoryRequest: 64, memoryLimit: 128))
        let used = KubeUsage(cpu: 0.25, memory: 32)
        XCTAssertEqual(KubePodShares.cell(.cpuRequest, used: used, spec: web, sampled: 1).text, "50%")
        let dashed = KubePodShares.cell(.cpuRequest, used: used, spec: web, sampled: 2)
        XCTAssertNil(dashed.sort, "two containers sampled, one listed: no share")
        XCTAssertTrue(dashed.help?.contains("metrics-server samples 2 containers of this pod, kube-state-metrics lists 1") == true, dashed.help ?? "")
        var reading = KubeShareReading(scope: .namespace("shop"))
        reading.pods[KubeRowID(namespace: "shop", name: "web-1")] = web
        reading.answered = ["shop"]
        XCTAssertNil(reading.cell(.cpuRequest, KubeRowID(namespace: "shop", name: "web-1"), used: used, sampled: 2).sort, "the list's cell too")
        reading.problems["shop"] = "Prometheus took longer than 20 s."
        XCTAssertEqual(reading.whole, [], "a namespace whose last read failed isn't whole")
    }

    /// `k8s_top` with containers listed and the specs from the list's
    /// reading (a pod's totals, no container's own): the pod's line first
    /// with its shares, its containers' lines a dash; a lone container's
    /// line the pod's shares.
    func testTopWithContainersPutsAPodsSharesOnItsOwnLine() {
        let two = KubeRowID(namespace: "shop", name: "web-1")
        let one = KubeRowID(namespace: "shop", name: "api-1")
        let samples = [
            KubePodMetrics(id: two, containers: ["app": KubeUsage(cpu: 0.2, memory: 64 * 1_048_576), "log": KubeUsage(cpu: 0.1, memory: 32 * 1_048_576)]),
            KubePodMetrics(id: one, containers: ["app": KubeUsage(cpu: 0.05, memory: 16 * 1_048_576)]),
        ]
        let specs = [
            two: KubePodShares.Spec(containers: 2, cpuRequest: 0.6, cpuLimit: 0.6, memoryRequest: 192 * 1_048_576, memoryLimit: nil),
            one: KubePodShares.Spec(containers: 1, cpuRequest: 0.1, cpuLimit: nil, memoryRequest: 32 * 1_048_576, memoryLimit: 64 * 1_048_576),
        ]
        let text = KubeMCPText.topPods(samples, allNamespaces: false, containers: true, sortBy: "cpu", limit: 5, now: Date(), specs: specs)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "NAME    CONTAINER   CPU(cores)   MEMORY(bytes)   %CPU/R   %CPU/L   %MEM/R   %MEM/L", text)
        XCTAssertEqual(lines[1], "web-1   (pod)       300m         96Mi            50%      50%      50%      -", text)
        XCTAssertEqual(lines[2], "web-1   app         200m         64Mi            -        -        -        -", text)
        XCTAssertEqual(lines[3], "web-1   log         100m         32Mi            -        -        -        -", text)
        XCTAssertEqual(lines[4], "api-1   app         50m          16Mi            50%      -        50%      25%", text)
    }

    func testTheAnswerIsReadByPodAndAPodNotWhollySetHasNoShare() throws {
        let answer = [
            series("containers", "web-1", nil, 2), series("request", "web-1", "cpu", 0.5), series("request", "web-1", "memory", 256 * 1_048_576),
            series("limit", "web-1", "memory", 512 * 1_048_576),
            series("containers", "zero-1", nil, 1), series("request", "zero-1", "cpu", 0),
        ]
        let specs = KubePodShares.read(answer)
        let web = try XCTUnwrap(specs[KubeRowID(namespace: "shop", name: "web-1")])
        XCTAssertEqual(web.containers, 2)
        XCTAssertEqual(web.cpuRequest, 0.5)
        XCTAssertNil(web.cpuLimit, "not every container is limited")
        let used = KubeUsage(cpu: 0.24, memory: 460 * 1_048_576)
        XCTAssertEqual(KubePodShares.cell(.cpuRequest, used: used, spec: web).text, "48%")
        XCTAssertEqual(KubePodShares.cell(.memoryRequest, used: used, spec: web).text, "180%")
        XCTAssertEqual(KubePodShares.cell(.memoryLimit, used: used, spec: web).text, "90%")
        XCTAssertEqual(
            KubePodShares.cell(.cpuLimit, used: used, spec: web), .dash("Not every container of this pod has a CPU limit: the pod has none as a whole."))
        let zero = try XCTUnwrap(specs[KubeRowID(namespace: "shop", name: "zero-1")])
        XCTAssertEqual(KubePodShares.cell(.cpuRequest, used: used, spec: zero).help, "Its containers' CPU requests add up to 0.")
        XCTAssertEqual(KubePodShares.cell(.memoryRequest, used: used, spec: zero).text, "—")
        XCTAssertEqual(KubePodShares.cell(.memoryRequest, used: used, spec: web).sort ?? 0, 179.6875, accuracy: 0.001, "sorted by the share")
    }

    func testALimitsShareIsWarmerFromEightyAndRedFromAHundred() {
        func level(_ column: KubePodShares.Column, _ share: Double) -> KubePodShares.Level {
            KubePodShares.level(column, .value("", sort: share, percent: nil))
        }
        XCTAssertEqual(level(.cpuLimit, 79.4), .normal)
        XCTAssertEqual(level(.cpuLimit, 80), .near)
        XCTAssertEqual(level(.memoryLimit, 100), .over)
        XCTAssertEqual(level(.memoryRequest, 180), .normal, "a request may be passed: only a limit's share warns")
        XCTAssertEqual(KubePodShares.level(.memoryLimit, .dash("why")), .normal)
        XCTAssertEqual(KubePodShares.Column.allCases.map(\.title), ["%CPU/R", "%CPU/L", "%MEM/R", "%MEM/L"])
    }

    func testANamespaceAnswerReplacesItsOwnAndACutOneShowsNone() {
        var reading = KubeShareReading(scope: KubeScope.of(["shop", "billing"]))
        let shop = KubeRowID(namespace: "shop", name: "web-1")
        let billing = KubeRowID(namespace: "billing", name: "api-1")
        let used = KubeUsage(cpu: 0.25, memory: 0)
        XCTAssertEqual(reading.cell(.cpuRequest, shop, used: used), .waiting, "not answered yet")
        reading.take([series("containers", "web-1", nil, 1), series("request", "web-1", "cpu", 1)], namespace: "shop")
        reading.take([series("containers", "api-1", nil, 1, namespace: "billing"), series("request", "api-1", "cpu", 0.5, namespace: "billing")], namespace: "billing")
        XCTAssertEqual(reading.cell(.cpuRequest, shop, used: used).text, "25%")
        XCTAssertEqual(reading.cell(.cpuRequest, billing, used: used).text, "50%")
        XCTAssertEqual(
            reading.cell(.cpuRequest, KubeRowID(namespace: "shop", name: "new-1"), used: used).help,
            "kube-state-metrics doesn't list this pod yet: its shares come with its next scrape.")
        // shop again, its pod gone: billing's kept.
        reading.take([], namespace: "shop")
        XCTAssertNil(reading.pods[shop])
        XCTAssertNotNil(reading.pods[billing])
        // An answer cut at the reader's cap: none of it shown.
        let many = (0..<KubePrometheusReader.maxSeries).map { series("containers", "p-\($0)", nil, 1, namespace: "billing") }
        reading.take(many, namespace: "billing")
        XCTAssertEqual(reading.cell(.cpuRequest, billing, used: used).help, KubeChartEmpty.sharesCut("billing").sentence)
        XCTAssertTrue(reading.pods.isEmpty)
        reading.problems["shop"] = "Prometheus took longer than 20 s."
        XCTAssertEqual(reading.cell(.cpuRequest, shop, used: used).help, "Shares couldn't be read: Prometheus took longer than 20 s.")
        reading.unavailable = KubeChartEmpty.sharesNeedKSM.sentence
        XCTAssertEqual(reading.cell(.cpuRequest, shop, used: used).help, KubeChartEmpty.sharesNeedKSM.sentence)
    }

    func testANamedPodsObjectGivesItsSharesAndEachContainers() throws {
        let pod: [String: Any] = [
            "spec": [
                "containers": [
                    ["name": "app", "env": [["name": "TOKEN", "value": "s3cr3t"]], "resources": ["requests": ["cpu": "250m", "memory": "64Mi"], "limits": ["cpu": "1", "memory": "128Mi"]]],
                    ["name": "proxy", "resources": ["requests": ["cpu": "50m", "memory": "32Mi"]]],
                ]
            ]
        ]
        let spec = KubePodShares.spec(ofPod: pod)
        XCTAssertEqual(spec.containers, 2)
        XCTAssertEqual(spec.cpuRequest ?? 0, 0.3, accuracy: 1e-9)
        XCTAssertNil(spec.cpuLimit, "proxy has no limit")
        XCTAssertEqual(spec.containers(named: "app")?.cpuLimit, 1)
        let text = KubeMCPText.topPods(
            [
                KubePodMetrics(
                    id: KubeRowID(namespace: "shop", name: "web-1"), containers: ["app": KubeUsage(cpu: 0.12, memory: 100 * 1_048_576), "proxy": KubeUsage(cpu: 0.01, memory: 8 * 1_048_576)])
            ],
            allNamespaces: false, containers: true, sortBy: "cpu", limit: 5, now: Date(), specs: [KubeRowID(namespace: "shop", name: "web-1"): spec])
        XCTAssertTrue(text.contains("%CPU/R   %CPU/L   %MEM/R   %MEM/L"), text)
        XCTAssertTrue(text.contains("web-1   (pod)       130m         108Mi           43%      -        113%     -"), "the pod's own line, as metrics.md 7 asks:\n\(text)")
        XCTAssertTrue(text.contains("web-1   app         120m         100Mi           48%      12%      156%     78%"), text)
        XCTAssertTrue(text.contains("web-1   proxy       10m          8Mi             20%      -        25%      -"), text)
        XCTAssertFalse(text.contains("s3cr3t"))
    }

    // MARK: The page, without Prometheus

    func testWithoutPrometheusTheSharesAreDashesAndNothingIsRead() async throws {
        let socket = "/tmp/otkps-\(UInt32.random(in: 0...UInt32.max)).sock"
        let api = FakeKubeAPI(socket: socket)
        try api.start()
        defer { api.stop() }
        api.addNamespace("shop")
        api.addPod("web-1", namespace: "shop")
        api.setPodMetrics("web-1", namespace: "shop", [("app", "250m", "64Mi")])
        let model = KubernetesModel(proxies: KubeProxies())
        let context = KubeContext(
            name: "fake-dev", cluster: "fake-dev", server: "http://127.0.0.1:1", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: KubeClassifier.classify(context: "fake-dev", cluster: "fake-dev", set: nil), settings: KubeContextSettings())
        let list = KubeContextList(contexts: [context], current: "fake-dev")
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.flushInterval = .milliseconds(20)
        model.statusInterval = .milliseconds(50)
        model.metrics.interval = .milliseconds(100)
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
        model.statusOverride = { _ in .open }
        let page = KubernetesPageModel(model: model)
        model.show()
        defer { model.hide() }
        page.visible = true
        let deadline = Date().addingTimeInterval(5)
        while model.metrics.reading(.pods)?.sample == nil || model.rows.count != 1 {
            if Date() > deadline { return XCTFail("no sample") }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(page.columns.contains { $0.title == "%CPU/R" }, "not without wide")
        page.wide = true
        XCTAssertEqual(page.columns.filter { $0.title.hasPrefix("%") }.map(\.title), ["%CPU/R", "%CPU/L", "%MEM/R", "%MEM/L"])
        let row = try XCTUnwrap(page.rows.first)
        let cell = page.share(.cpuRequest, of: row)
        XCTAssertEqual(cell, .dash(KubeChartEmpty.sharesNeedPrometheus.sentence))
        XCTAssertEqual(page.metricsNote, KubeChartEmpty.sharesNeedPrometheus.sentence, "said once in the header too")
        XCTAssertFalse(page.prometheusWants.contains(.shares))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(api.requests.contains { $0.path == "/api/v1/namespaces/shop/pods/web-1" }, "no pod object read for a share")
        XCTAssertFalse(api.requests.contains { $0.path.hasSuffix("/pods") && !$0.accept.contains("Table") && !$0.path.contains("metrics.k8s.io") }, "nor a list of them")
        XCTAssertTrue(api.requests.filter(\.isPrometheusQuery).isEmpty)

        // A namespace's usage refused too: both said, neither hiding the other.
        api.addNamespace("billing")
        api.forbidden = ["pods.metrics.k8s.io@billing"]
        model.setScope(KubeScope.of(["shop", "billing"]))
        let refusedBy = Date().addingTimeInterval(5)
        while model.metrics.reading(.pods)?.sample?.refusal == nil {
            if Date() > refusedBy { return XCTFail("no refusal: \(page.metricsNote ?? "no note")") }
            try await Task.sleep(for: .milliseconds(20))
        }
        let refusal = try XCTUnwrap(model.metrics.note(.pods))
        XCTAssertEqual(page.metricsNote, refusal + "\n" + KubeChartEmpty.sharesNeedPrometheus.sentence)
        XCTAssertEqual(api.writes, [])
    }

    /// Prometheus on but no metrics-server: there is no usage to share,
    /// so kube-state-metrics isn't asked for the shares at all (nor said
    /// to be missing): the usage's own note says why.
    func testWithoutMetricsServerTheSharesAreNotAsked() async throws {
        let socket = "/tmp/otkps-\(UInt32.random(in: 0...UInt32.max)).sock"
        let api = FakeKubeAPI(socket: socket)
        try api.start()
        defer { api.stop() }
        api.addNamespace("shop")
        api.addNamespace("monitoring")
        api.addPod("web-1", namespace: "shop")
        api.metricsServer = false
        api.servePrometheus(namespace: "monitoring", service: "prometheus-server", port: "80")
        let model = KubernetesModel(proxies: KubeProxies())
        let context = KubeContext(
            name: "fake-dev", cluster: "fake-dev", server: "http://127.0.0.1:1", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: KubeClassifier.classify(context: "fake-dev", cluster: "fake-dev", set: nil),
            settings: KubeContextSettings(prometheus: "monitoring/prometheus-server:80"))
        let list = KubeContextList(contexts: [context], current: "fake-dev")
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.flushInterval = .milliseconds(20)
        model.statusInterval = .milliseconds(50)
        model.metrics.interval = .milliseconds(100)
        model.prometheus.interval = .milliseconds(100)
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
        model.statusOverride = { _ in .open }
        model.prometheusOverride = { context, service in
            KubePrometheusDirect(connection: KubeSocketConnection(socket: socket, context: context.name), service: service)
        }
        let page = KubernetesPageModel(model: model)
        model.show()
        defer { model.hide() }
        page.visible = true
        page.wide = true
        let deadline = Date().addingTimeInterval(5)
        while model.metrics.availability == .unknown || model.rows.count != 1 {
            if Date() > deadline { return XCTFail("discovery not read") }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(page.prometheusOn)
        XCTAssertTrue(page.showsShareColumns)
        XCTAssertFalse(page.prometheusWants.contains(.shares), "nothing to share without usage")
        XCTAssertTrue(page.metricsNote?.contains("No metrics-server") == true, page.metricsNote ?? "no note")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(api.requests.contains { $0.isPrometheusQuery && $0.query["query"]?.contains("kube_pod_container_info") == true }, "\(api.requests)")
        XCTAssertEqual(api.writes, [])
    }
}
