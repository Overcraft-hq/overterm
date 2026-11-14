import AppKit
import Foundation

/// `kubernetesCharts` part 13 (docs/design/kubernetes/metrics.md, 8; stage
/// M5b), run inside `kubernetesPrometheus` where the fake's Prometheus is
/// found: the Pods list wide (`w`) shows `%CPU/R %CPU/L %MEM/R %MEM/L`,
/// with the `prometheus-chart` profile — each pod's usage, sampled from
/// metrics-server, against its containers' requests and limits from one
/// instant kube-state-metrics query a namespace shown; a pod not wholly
/// limited says so; a limit's share at 80% is drawn warmer. With
/// Prometheus off for the context: dashes and their sentence, and no pod
/// object read for them. Reads only.
extension E2ERunner {
    func prometheusShares(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, service: KubePrometheusService) async {
        let entries = Settings.shared.value("kubernetes.contexts")
        fake.setPrometheusProfile(.prometheusChart)
        model.prometheus.forgetProfile()
        let shareInterval = model.prometheus.shareInterval
        defer {
            fake.setPrometheusProfile(.noNodeExporter)
            model.prometheus.forgetProfile()
            model.prometheus.shareInterval = shareInterval
            page.wide = false
            Settings.shared.set("kubernetes.contexts", entries)
        }
        let name = "shares-api-1"
        let id = KubeRowID(namespace: "shop", name: name)
        fake.metricsServer = true
        fake.addPod(
            name, namespace: "shop",
            FakeKubeAPI.Pod(resources: ["app": ["requests": ["cpu": "250m", "memory": "128Mi"], "limits": ["cpu": "250m"]]]))
        fake.setPodMetrics(name, namespace: "shop", [("app", "200m", "96Mi")])
        // kube-state-metrics' raw series, as two replicas scrape them: the query evaluated, not a fixture's answer.
        let ksmMetrics = ["kube_pod_container_info", "kube_pod_container_resource_requests", "kube_pod_container_resource_limits"]
        for instance in ["ksm-a", "ksm-b"] {
            let labels = ["namespace": "shop", "pod": name, "container": "app", "instance": instance]
            fake.setPrometheusSeries("kube_pod_container_info", labels: labels, value: 1)
            fake.setPrometheusSeries("kube_pod_container_resource_requests", labels: labels.merging(["resource": "cpu"]) { $1 }, value: 0.25)
            fake.setPrometheusSeries("kube_pod_container_resource_requests", labels: labels.merging(["resource": "memory"]) { $1 }, value: 128 * 1_048_576)
            fake.setPrometheusSeries("kube_pod_container_resource_limits", labels: labels.merging(["resource": "cpu"]) { $1 }, value: 0.25)
        }
        defer { for metric in ksmMetrics { fake.clearPrometheusSeries(metric, matching: ["pod": name]) } }
        func ksmAsked() -> [FakeKubeAPI.Request] {
            prometheusAskedOf(fake).filter { $0.query["query"]?.contains("kube_pod_container_info") == true }
        }
        func cell(_ column: KubePodShares.Column) -> KubeUsageCell? {
            page.rows.first { $0.row.id == id }.map { page.share(column, of: $0) }
        }

        fake.forgetRequests()
        guard await showKubernetesKind(model, page, "po", row: id) else { return }
        check("not wide: no shares, none asked", !page.columns.contains { $0.title == "%CPU/R" } && !model.prometheus.wants.contains(.shares))
        check("w is wide", page.press("w") && page.wide)
        check(
            "wide adds the four shares after the usage",
            page.columns.map(\.title).filter { $0.hasPrefix("%") } == ["%CPU/R", "%CPU/L", "%MEM/R", "%MEM/L"], "\(page.columns.map(\.title))")
        check(
            "the pod's CPU against its request, from kube-state-metrics", await eventually(15) { cell(.cpuRequest)?.text == "80%" },
            "\(String(describing: cell(.cpuRequest))) \(model.prometheus.shares.map { "\($0)" } ?? "no reading")")
        check("and its limit, drawn warmer", cell(.cpuLimit)?.text == "80%" && cell(.cpuLimit).map { KubePodShares.level(.cpuLimit, $0) } == .near)
        check("its memory against its request", cell(.memoryRequest)?.text == "75%")
        check(
            "no memory limit: said, not guessed",
            cell(.memoryLimit)?.help == "Not every container of this pod has a memory limit: the pod has none as a whole.",
            "\(String(describing: cell(.memoryLimit)))")
        // What the first read asked, before the window is read: the shares
        // are read again every so often, and reading text can take seconds.
        let asked = ksmAsked()
        check("drawn", await shownText(15) { $0.contains("%CPU/R") } != nil)
        let fit = usageColumnsFit(page)
        check("wide, CPU and Memory still drawn whole at this window's width", fit.ok, fit.said)
        check("one instant query for shop", asked.count == 1 && asked.allSatisfy { $0.path == service.queryPath }, "\(asked.map(\.query))")
        check("scoped to it", asked.first?.query["query"]?.contains(#"namespace="shop""#) == true)
        check("given 20 s", asked.allSatisfy { $0.query["timeout"] == "20s" })
        check("no pod object read for it", !fake.requests.contains { $0.path == "/api/v1/namespaces/shop/pods/\(name)" }, "\(fake.requests)")

        // Two namespaces: one query each.
        fake.addNamespace("billing")
        fake.forgetRequests()
        model.setScope(KubeScope.of(["shop", "billing"]))
        check(
            "two namespaces, a query each",
            await eventually(15) {
                let queries = ksmAsked().compactMap { $0.query["query"] }
                return queries.count == 2 && queries.contains { $0.contains(#"namespace="billing""#) }
            }, "\(ksmAsked().map(\.query))")
        check("the shares still read", await eventually(15) { cell(.cpuRequest)?.text == "80%" }, "\(String(describing: cell(.cpuRequest)))")
        model.setScope(.namespace("shop"))

        // Without Prometheus: dashes and their sentence, nothing read for them.
        Settings.shared.set("kubernetes.contexts", Self.kubeContexts())
        check("Prometheus off for fake-dev", await eventually(10) { !page.prometheusOn })
        fake.forgetRequests()
        check("the shares are dashes", await eventually(10) { cell(.cpuRequest) == .dash(KubeChartEmpty.sharesNeedPrometheus.sentence) })
        check("said once above the list", page.metricsNote == KubeChartEmpty.sharesNeedPrometheus.sentence, page.metricsNote ?? "no note")
        check("drawn", await shownText(15) { $0.contains("turn Prometheus on") } != nil)
        await pause(1)
        check("kube-state-metrics not asked", ksmAsked().isEmpty, "\(ksmAsked())")
        check(
            "and no pod object read",
            !fake.requests.contains { $0.path == "/api/v1/namespaces/shop/pods/\(name)" }
                && !fake.requests.contains { $0.path == "/api/v1/namespaces/shop/pods" && !$0.accept.contains("as=Table") }, "\(fake.requests)")
        fake.delete("pods", name, namespace: "shop")
    }
}
