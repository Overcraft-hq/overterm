import AppKit
import Foundation

/// `kubernetesCharts`, stage M3b (docs/design/kubernetes/metrics.md, 2.5–2.8),
/// against `fake-dev` with metrics-server and no Prometheus: a Deployment's
/// Metrics tab — its pods against the template's request, by revision
/// labelled from its ReplicaSet, its replicas, its HPA found with one read
/// and charted beside it; Total stacks the pods; a node's tab against its
/// pods' requests (read as objects) and its allocatable, its pressure as a
/// band, "Sample top pods" reading its largest pods' namespace; a
/// namespace's tab by workload against its quota, its pods by phase.
/// The Nodes list's heat strips (M3c) from the list's own read.
/// Hidden, nothing is read. Reads only.
extension E2ERunner {
    func kubernetesObjectCharts(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        let wasShowing = app.store.showingOverlay == .kubernetes
        if !wasShowing { app.toggleKubernetesPage(nil) }
        defer { if !wasShowing, app.store.showingOverlay == .kubernetes { app.toggleKubernetesPage(nil) } }
        let interval = model.metrics.interval
        model.metrics.interval = .milliseconds(500)
        defer { model.metrics.interval = interval }
        let statesInterval = page.podStatesInterval
        page.podStatesInterval = .milliseconds(500)
        defer { page.podStatesInterval = statesInterval }
        let scope = app.theme.map(ObjectIdentifier.init)
        let charts = KubeChartRegistry.shared
        let namespace = "charts"
        let node = "charts-node-1"
        let hash = "7d9f8b6c5d"
        fake.metricsServer = true
        fake.addNamespace(namespace)
        fake.add(
            "deployments.apps", "api", namespace: namespace, values: ["Ready": "2/2", "Up-to-date": 2, "Available": 2],
            fields: [
                "spec": [
                    "replicas": 2, "selector": ["matchLabels": ["app": "api"]],
                    "template": ["spec": ["containers": [["name": "app", "resources": ["requests": ["cpu": "100m", "memory": "64Mi"], "limits": ["cpu": "500m", "memory": "256Mi"]]]]]],
                ],
                "status": ["replicas": 2, "availableReplicas": 2],
            ])
        fake.addRevision(of: "api", namespace: namespace, name: "api-\(hash)", revision: 3, image: "nginx:1.27.2", labels: ["app": "api"], replicas: 2)
        fake.add(
            "horizontalpodautoscalers.autoscaling", "api", namespace: namespace, values: ["Reference": "Deployment/api", "MinPods": 2, "MaxPods": 6],
            fields: [
                "spec": ["minReplicas": 2, "maxReplicas": 6, "metrics": [["type": "Resource", "resource": ["name": "cpu", "target": ["averageUtilization": 70]]]]],
                "status": [
                    "currentReplicas": 2, "desiredReplicas": 2, "currentMetrics": [["type": "Resource", "resource": ["name": "cpu", "current": ["averageUtilization": 40]]]],
                ],
            ])
        fake.add(
            "resourcequotas", "compute", namespace: namespace,
            fields: ["status": ["hard": ["requests.cpu": "2", "requests.memory": "4Gi"], "used": ["requests.cpu": "200m", "requests.memory": "128Mi"]]])
        let pods = ["api-\(hash)-x2k4q", "api-\(hash)-z4m5r"]
        for (index, name) in pods.enumerated() {
            fake.addPod(
                name, namespace: namespace,
                FakeKubeAPI.Pod(node: node, resources: ["app": ["requests": ["cpu": "100m", "memory": "64Mi"], "limits": ["cpu": "500m", "memory": "256Mi"]]]),
                labels: ["app": "api", "pod-template-hash": hash])
            fake.setFields(
                "pods", name, namespace: namespace,
                ["metadata": ["ownerReferences": [["apiVersion": "apps/v1", "kind": "ReplicaSet", "name": "api-\(hash)", "controller": true]]]])
            fake.setPodMetrics(name, namespace: namespace, [("app", index == 0 ? "60m" : "30m", "40Mi")], labels: ["app": "api", "pod-template-hash": hash])
        }
        let pressure = Date().addingTimeInterval(-300)
        fake.add(
            "nodes", node, values: ["Status": "Ready", "Roles": "worker", "Version": "v1.34.1"],
            fields: [
                "status": [
                    "allocatable": ["cpu": "4", "memory": "16Gi", "pods": "58"], "capacity": ["cpu": "4", "memory": "16Gi", "pods": "58"],
                    "conditions": [
                        ["type": "MemoryPressure", "status": "True", "lastTransitionTime": pressure.formatted(.iso8601)], ["type": "Ready", "status": "True"],
                    ],
                ]
            ])
        fake.setNodeMetrics(node, cpu: "900m", memory: "6Gi")
        if model.selectedName != "fake-dev" { model.select("fake-dev") }
        model.setScope(.namespace(namespace))
        model.rediscover()
        page.filter = ""
        page.applySelector()
        guard await eventually(15, { model.discovery?.kind("deployments") != nil && model.metrics.availability == .served }),
            let deployments = model.discovery?.kind("deployments")
        else { return check("deployments served, metrics-server too", false) }
        page.showKind(deployments)
        check("the chart's Deployment listed", await eventually(15) { model.rows[KubeRowID(namespace: namespace, name: "api")] != nil })

        // A Deployment's tab: by pod against the template, by revision, its replicas, its HPA.
        fake.forgetRequests()
        page.selection = ["\(namespace)/api"]
        page.metricsRange = .live
        check("m opens the Deployment's Metrics tab", page.press("m") && page.detailTab == .metrics && page.detail?.ref.name == "api")
        let subject = "kubernetes.chart.workload.\(namespace).deployment.api"
        check(
            "its CPU charted by pod, two samples or more",
            await eventually(20) {
                guard let cpu = charts.chart(subject + ".cpu", in: scope), cpu.plot != nil else { return false }
                return cpu.data.usage.count == 2 && cpu.data.usage.allSatisfy { $0.points.count >= 2 }
            }, charts.lines(in: scope).joined(separator: "; "))
        let cpuDump = charts.lines(in: scope).first { $0.contains(subject + ".cpu") } ?? ""
        note("kubernetes object charts dump: \(cpuDump)")
        check("against one pod's request and limit, from the template", cpuDump.contains("refs=[request=100m limit=500m]"), cpuDump)
        check(
            "by revision, labelled from its ReplicaSet",
            await eventually(15) { charts.chart(subject + ".revisions", in: scope)?.data.usage.map(\.name) == ["rev 3 (nginx:1.27.2)"] },
            charts.chart(subject + ".revisions", in: scope)?.data.usage.map(\.name).joined(separator: ", ") ?? "none")
        check(
            "its replicas, stepped, with its HPA's bounds",
            await eventually(15) {
                guard let replicas = charts.chart(subject + ".replicas", in: scope) else { return false }
                return replicas.data.stepped && replicas.data.references.map(\.name).contains("HPA max")
            })
        check(
            "its HPA found and charted beside it",
            await eventually(15) { charts.chart("kubernetes.chart.hpa.\(namespace).api.replicas", in: scope) != nil }, charts.lines(in: scope).joined(separator: "; "))
        check(
            "the HPA looked up with one Table read",
            fake.requests.filter { $0.path == "/apis/autoscaling/v2/namespaces/\(namespace)/horizontalpodautoscalers" }.count == 1)
        check(
            "its pods' samples read by its selector",
            fake.requests.contains { $0.path == "/apis/metrics.k8s.io/v1beta1/namespaces/\(namespace)/pods" && $0.query["labelSelector"] == "app=api" })
        check("the caption says where the numbers come from", await shownText(15) { $0.contains("Sampled from metrics-server while shown since") } != nil)
        page.pickWorkloadView(.total)
        check(
            "Total: stacked, against the request × its replicas",
            await eventually(10) {
                guard let cpu = charts.chart(subject + ".cpu", in: scope) else { return false }
                return cpu.data.stacked && cpu.data.references.first?.points.last?.value == 0.2
            })
        page.pickWorkloadView(.perPod)

        // M4: change markers. Its ReplicaSet's revision a rollout on every chart, from its History;
        // a pod's OOMKill, seen between two reads of its pods' states, on its CPU and memory.
        check(
            "its rollout marked on every chart, from its History",
            await eventually(15) {
                [".cpu", ".memory", ".revisions", ".replicas"].allSatisfy { id in
                    charts.chart(subject + id, in: scope)?.data.shownMarkers.contains { $0.kind == .rollout && $0.title.hasPrefix("Revision 3") } == true
                }
            }, charts.lines(in: scope).filter { $0.contains(subject) }.joined(separator: "; "))
        fake.updatePod(pods[0], namespace: namespace) {
            $0.restarts = 1
            $0.lastReason = "OOMKilled"
            $0.lastExitCode = 137
            $0.lastFinished = Date().addingTimeInterval(-20)
        }
        check(
            "a pod's OOMKill marked on its memory, named by its pod",
            await eventually(15) {
                charts.chart(subject + ".memory", in: scope)?.data.shownMarkers.contains { $0.kind == .oom && $0.title.hasPrefix(pods[0] + "/app: OOMKilled") } == true
            }, charts.lines(in: scope).first { $0.contains(subject + ".memory") } ?? "none")
        check(
            "from its pods' states, read by its selector, bounded",
            fake.requests.contains { $0.path == "/api/v1/namespaces/\(namespace)/pods" && $0.query["labelSelector"] == "app=api" && $0.query["limit"] == "250" })
        let markedDump = charts.lines(in: scope).first { $0.contains(subject + ".memory") } ?? ""
        note("kubernetes markers dump: \(markedDump)")
        check(
            "the dump names them", markedDump.contains("markers=2[rollout,oom]") || markedDump.contains("markers=2[oom,rollout]"), markedDump)
        if let rollout = charts.chart(subject + ".cpu", in: scope)?.data.shownMarkers.first(where: { $0.kind == .rollout }) {
            // Show ±30 min: every chart narrowed to it, nothing asked for it.
            page.showAround(rollout)
            let window = page.metricsWindow
            check(
                "Show ±30 min: every chart narrowed to the marker's half hour either side",
                await eventually(10) { window != nil && charts.chart(subject + ".memory", in: scope)?.data.start == window?.start },
                "\(window.map(\.title) ?? "no window")")
            check("the picker says Custom", await shownText(10) { $0.contains("Custom") } != nil, window?.title ?? "-")
            check("Esc resets it, the detail stays", page.press("\u{1B}") && page.metricsWindow == nil && page.detail?.ref.name == "api")
            // Its click: the History entry, marked, and its diff in the changes pane.
            page.openMarker(rollout)
            check("the rollout opens its History entry, marked", page.detailTab == .history && page.markedEntry == "revision/3")
            check(
                "and its diff in the changes pane",
                await eventually(10) { app.kubernetesManifest.shown == .change && app.kubernetesManifest.change?.title.hasSuffix("→ 3") == true },
                app.kubernetesManifest.change?.title ?? "none")
            if app.store.showingOverlay != .kubernetes { app.toggleKubernetesPage(nil) }
            page.showTab(.metrics)
        } else {
            check("the rollout's marker, to open", false)
        }

        // A node's tab: against its pods' requests and its allocatable, its pressure a band; its top pods on request.
        guard let nodes = model.discovery?.kind("nodes") else { return check("nodes served", false) }
        page.showKind(nodes)
        check("its node listed", await eventually(15) { model.kind.fullName == "nodes" && model.rows[KubeRowID(namespace: nil, name: node)] != nil })

        // The Nodes list's heat strips (M3c): the row's last 15 minutes against allocatable, from the list's own read.
        fake.forgetRequests()
        let strips = KubeHeatStripRegistry.shared
        let cpuStrip = KubernetesPageModel.heatStripIdentifier(node, .cpu)
        let memoryStrip = KubernetesPageModel.heatStripIdentifier(node, .memory)
        check(
            "the node's row draws a CPU and a memory strip, sampled cells filled",
            await eventually(20) { (strips.strip(cpuStrip, in: scope)?.filled ?? 0) >= 1 && (strips.strip(memoryStrip, in: scope)?.filled ?? 0) >= 1 },
            strips.lines(in: scope).joined(separator: "; "))
        note("kubernetes heat strips: \(strips.lines(in: scope).joined(separator: "; "))")
        check(
            "CPU's share of allocatable: 900m of 4 cores, calm",
            strips.strip(cpuStrip, in: scope).map { abs(($0.now ?? 0) - 22.5) < 0.5 && $0.percents.compactMap { $0 }.allSatisfy { KubeHeatStrip.Level($0) == .low } } ?? false,
            strips.strip(cpuStrip, in: scope)?.dump ?? "none")
        check("memory's: 6Gi of 16Gi", strips.strip(memoryStrip, in: scope).map { abs(($0.now ?? 0) - 37.5) < 0.5 } ?? false, strips.strip(memoryStrip, in: scope)?.dump ?? "none")
        check("the unsampled stretch empty, never zero", strips.strip(cpuStrip, in: scope).map { $0.filled < 60 && !$0.percents.contains(0) } ?? false)
        check(
            "nothing read for the strips but the list's own nodes sample",
            !fake.requests.contains { $0.path.hasPrefix("/apis/metrics.k8s.io/v1beta1/nodes/") || $0.path.contains("/proxy") },
            "\(fake.requests.map(\.path))")
        fake.forgetRequests()
        page.selection = [node]
        check("m opens the node's Metrics tab", page.press("m") && page.detailTab == .metrics && page.detail?.ref.name == node)
        let nodeCPU = "kubernetes.chart.node.\(node).cpu"
        check(
            "its CPU against what its pods request, its allocatable and capacity",
            await eventually(20) {
                guard let cpu = charts.chart(nodeCPU, in: scope) else { return false }
                return cpu.data.references.map(\.role) == [.request, .allocatable, .capacity] && (cpu.data.usage.first?.points.count ?? 0) >= 1
            }, charts.lines(in: scope).first { $0.contains(nodeCPU) } ?? "none")
        let nodeDump = charts.lines(in: scope).first { $0.contains(nodeCPU) } ?? ""
        check("its memory pressure a band", nodeDump.contains("bands=[MemoryPressure]"), nodeDump)
        check(
            "its pods read as objects, by field selector",
            fake.requests.contains { $0.path == "/api/v1/pods" && $0.query["fieldSelector"] == "spec.nodeName=\(node)" })
        check("never the kubelet", !fake.requests.contains { $0.path.contains("/proxy") })
        check("its top pods not read until asked", !fake.requests.contains { $0.path == "/apis/metrics.k8s.io/v1beta1/namespaces/\(namespace)/pods" })
        page.sampleTopPods()
        check(
            "Sample Top Pods: its largest pods, stacked",
            await eventually(20) { charts.chart("kubernetes.chart.node.\(node).top.cpu", in: scope)?.data.usage.count == 2 },
            charts.lines(in: scope).joined(separator: "; "))
        check("from their namespace's list", fake.requests.contains { $0.path == "/apis/metrics.k8s.io/v1beta1/namespaces/\(namespace)/pods" })

        // A namespace's tab: by workload against its quota; its pods by phase.
        page.showKind(.namespaces)
        check("the namespaces listed", await eventually(15) { model.kind.fullName == "namespaces" && model.rows[KubeRowID(namespace: nil, name: namespace)] != nil })
        fake.forgetRequests()
        page.selection = [namespace]
        check("m opens the namespace's Metrics tab", page.press("m") && page.detailTab == .metrics && page.detail?.ref.name == namespace)
        let nsCPU = "kubernetes.chart.namespace.\(namespace).cpu"
        check(
            "its CPU by workload, against its quota",
            await eventually(20) {
                guard let cpu = charts.chart(nsCPU, in: scope) else { return false }
                return cpu.data.usage.map(\.name) == ["api"] && cpu.data.references.first?.role == .quota && cpu.data.tier?.contains("by owner") == true
            }, charts.lines(in: scope).first { $0.contains(nsCPU) } ?? "none")
        check(
            "its pods by phase",
            await eventually(15) { charts.chart("kubernetes.chart.namespace.\(namespace).phases", in: scope)?.data.usage.map(\.name) == ["Running"] })
        check(
            "its pods' owners from Metadata rows",
            fake.requests.contains { $0.path == "/api/v1/namespaces/\(namespace)/pods" && $0.query["includeObject"] == "Metadata" })

        // Part 5 (M7): the Deployment's and the namespace's tabs over Prometheus.
        await kubernetesObjectChartsPrometheus(model, page, fake, namespace: namespace, hash: hash, pods: pods)

        // Hidden: nothing read.
        app.toggleKubernetesPage(nil)
        check("hidden, no usage polled", await eventually(5) { !model.metrics.isPolling })
        fake.forgetRequests()
        await pause(1.5)
        check(
            "and nothing of the tab's asked", !fake.requests.contains { $0.path.contains("metrics.k8s.io") || $0.path.contains("/pods") }, "\(fake.requests.map(\.path))")
        app.toggleKubernetesPage(nil)
        page.showTab(.overview)
        page.closeDetail()
        model.setScope(.namespace("shop"))
        check("the charts wrote nothing", fake.writes.isEmpty, "\(fake.writes)")
        // What the parts after it count stays theirs.
        for name in pods {
            fake.deletePod(name, namespace: namespace)
            fake.delete("pods.metrics.k8s.io", name, namespace: namespace)
        }
        for (resource, name) in [
            ("deployments.apps", "api"), ("replicasets.apps", "api-\(hash)"), ("horizontalpodautoscalers.autoscaling", "api"), ("resourcequotas", "compute"),
        ] {
            fake.delete(resource, name, namespace: namespace)
        }
        fake.delete("nodes.metrics.k8s.io", node)
        fake.delete("nodes", node)
        fake.delete("namespaces", namespace)
    }

    /// `kubernetesCharts` part 5 (docs/design/kubernetes/metrics.md 8; stage
    /// M7), fake-dev's Prometheus on (kube-prometheus-stack's profile, its
    /// mixin's workload rule among the rules): the Deployment's tab at 1h —
    /// its pods by owner, ranked once by an instant `topk` a measure at the
    /// span's end, the five asked by name; by revision, a line for each of
    /// its two ReplicaSets labelled with its revision and image — then its
    /// namespace's at 1h: by workload from the rules, against its quota as
    /// kube-state-metrics says it, what it requests but leaves idle, its pods
    /// by phase. Only the Service's two query paths. Reads only.
    func kubernetesObjectChartsPrometheus(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, namespace: String, hash: String, pods: [String]) async {
        let scope = app.theme.map(ObjectIdentifier.init)
        let charts = KubeChartRegistry.shared
        let service = KubePrometheusService(namespace: "monitoring", name: "prometheus-k8s", port: "9090")!
        let interval = model.prometheus.interval
        model.prometheus.interval = .milliseconds(500)
        let older = "5c8b7d9f4b"
        let old = "api-\(older)-q7w8x"
        fake.addRevision(
            of: "api", namespace: namespace, name: "api-\(older)", revision: 2, image: "nginx:1.27.1", labels: ["app": "api"], replicas: 0,
            created: Date().addingTimeInterval(-1800))
        fake.addPod(old, namespace: namespace, FakeKubeAPI.Pod(), labels: ["app": "api", "pod-template-hash": older])
        fake.addNamespace("monitoring")
        fake.servePrometheus(namespace: "monitoring", service: "prometheus-k8s", port: "9090")
        fake.setPrometheusProfile(.kubePrometheusStack)
        setTabFixtures(fake)
        let usage = [(pods[0], 0.06), (pods[1], 0.03), (old, 0.02)]
        for (pod, cpu) in usage {
            let container = ["namespace": namespace, "pod": pod, "container": "app", "image": "nginx:1.27", "metrics_path": "/metrics/cadvisor"]
            fake.setPrometheusSeries("container_cpu_usage_seconds_total", labels: container, value: cpu)
            fake.setPrometheusSeries("container_memory_working_set_bytes", labels: container, value: 40 * 1_048_576)
            let rule = ["namespace": namespace, "pod": pod, "container": "app"]
            fake.setPrometheusSeries(KubePromProfile.containerCPURate5m, labels: rule, value: cpu)
            fake.setPrometheusSeries(KubePromProfile.containerMemoryRule, labels: rule, value: 40 * 1_048_576)
            fake.setPrometheusSeries(
                KubePromProfile.workloadRule, labels: ["namespace": namespace, "pod": pod, "workload": "api", "workload_type": "deployment"], value: 1)
            fake.setPrometheusSeries(
                "kube_pod_status_phase", labels: ["job": "kube-state-metrics", "namespace": namespace, "pod": pod, "phase": "Running"], value: 1)
        }
        for (type, value) in [("hard", 2.0), ("used", 0.2)] {
            fake.setPrometheusSeries(
                "kube_resourcequota",
                labels: ["job": "kube-state-metrics", "namespace": namespace, "resourcequota": "compute", "resource": "requests.cpu", "type": type], value: value)
        }
        fake.setPrometheusMatrix("topk(5,", usage.map { pod in FakePromFixture.Line(["pod": pod.0]) { _ in pod.1 } })
        fake.setPrometheusMatrix("topk(8,", [FakePromFixture.Line(["workload_type": "deployment", "workload": "api"]) { _ in 0.11 }])
        fake.setPrometheusMatrix("sum((clamp_min(", [FakePromFixture.Line { _ in 0 }])
        fake.setPrometheusMatrix("avg_over_time((", [FakePromFixture.Line(["overterm_s": "cpu"]) { _ in 0.09 }])
        Settings.shared.set(
            "kubernetes.contexts", .entries(["fake-dev": ["metrics": .string("prometheus"), "prometheus": .string("monitoring/prometheus-k8s:9090")]]))
        defer {
            Settings.shared.set("kubernetes.contexts", nil)
            clearTabFixtures(fake)
            for fragment in ["topk(5,", "topk(8,", "sum((clamp_min(", "avg_over_time(("] { fake.clearPrometheusMatrix(fragment) }
            for metric in [
                "container_cpu_usage_seconds_total", "container_memory_working_set_bytes", KubePromProfile.containerCPURate5m, KubePromProfile.containerMemoryRule,
                KubePromProfile.workloadRule, "kube_pod_status_phase", "kube_resourcequota",
            ] {
                fake.clearPrometheusSeries(metric, matching: ["namespace": namespace])
            }
            fake.setPrometheusProfile(.noNodeExporter)
            model.prometheus.forgetProfile()
            model.prometheus.interval = interval
            page.metricsZoom = []
            page.metricsRange = .live
            page.metricsRangePicked = false
            fake.deletePod(old, namespace: namespace)
            fake.delete("replicasets.apps", "api-\(older)", namespace: namespace)
        }
        func asked() -> [FakeKubeAPI.Request] { fake.requests.filter(\.isPrometheusQuery) }
        func said() -> String {
            let tabs = model.prometheus.tabs.values.map {
                "\($0.request.subject.object) \($0.request.span) \($0.results.keys.sorted()) read=\($0.read != nil) ranked=\($0.ranking?.refreshes ?? -1) \($0.problem ?? "-") \($0.refused.values.sorted())"
            }
            let source = page.detail.flatMap { page.metricsSource(of: $0.ref) }.map(\.rawValue) ?? "none"
            let built = page.detail.flatMap { page.objectCharts(of: $0) }?.charts.map { "\($0.data.id)@\($0.data.source)" } ?? []
            return "tabs \(tabs); want \(page.metricsTabWant.map { "\($0.subject.object) \($0.span)" } ?? "none"); source \(source); built \(built); \(model.prometheus.state)"
        }
        check("fake-dev's Prometheus found", await eventually(15) { model.prometheus.state == .found(service, nil) }, "\(model.prometheus.state)")

        // The Deployment's tab, opened again so its History reads both ReplicaSets.
        page.showTab(.overview)
        page.closeDetail()
        guard let deployments = model.discovery?.kind("deployments") else { return check("deployments served", false) }
        page.showKind(deployments)
        check("the Deployment listed", await eventually(15) { model.kind.fullName == deployments.fullName && model.rows[KubeRowID(namespace: namespace, name: "api")] != nil })
        fake.forgetRequests()
        page.selection = ["\(namespace)/api"]
        check("m opens its Metrics tab", page.press("m") && page.detailTab == .metrics && page.detail?.ref.name == "api")
        page.pickMetricsRange(.hour)
        check("1h, from Prometheus", page.shownMetricsRange == .hour)
        let subject = "kubernetes.chart.workload.\(namespace).deployment.api"
        let revisionsID = subject + ".revisions"
        func revisions() -> KubeChartData? {
            page.detail.flatMap { page.objectCharts(of: $0) }?.charts.first { $0.data.id == revisionsID }?.data ?? charts.chart(revisionsID, in: scope)?.data
        }
        check(
            "by revision: a line for each ReplicaSet, labelled with its revision and image",
            await eventually(25) { Set(revisions()?.usage.map(\.name) ?? []) == ["rev 2 (nginx:1.27.1)", "rev 3 (nginx:1.27.2)"] && revisions()?.source == "Prometheus" },
            (revisions()?.usage.map(\.name).joined(separator: ", ") ?? "none") + "; " + said())
        let ranks = asked().filter { $0.path == service.queryPath && $0.query["query"]?.hasPrefix("topk(5,") == true }
        check("ranked once a measure, an instant topk at the span's end", ranks.count == 2 && ranks.allSatisfy { $0.query["time"] != nil }, "\(ranks.count) rankings; " + said())
        check(
            "its pods chosen by the mixin's workload rule",
            ranks.allSatisfy { $0.query["query"]?.contains(#"namespace_workload_pod:kube_pod_owner:relabel{namespace="charts",workload="api",workload_type="deployment"}"#) == true })
        check(
            "the five asked by name",
            asked().contains { $0.path == service.rangePath && $0.query["query"]?.hasPrefix("sum by (pod)(") == true && $0.query["query"]?.contains("pod=~") == true },
            "\(asked().compactMap { $0.query["query"] })")
        let cpu = page.detail.flatMap { page.objectCharts(of: $0) }?.charts.first { $0.data.id == "workload.\(namespace).deployment.api.cpu" }?.data
        check("its CPU by pod as ranked", cpu?.usage.map(\.id) == [pods[0], pods[1], old], cpu?.usage.map(\.id).joined(separator: ", ") ?? "none")
        check("said: by owner, from the rules", cpu?.tier == "raw cAdvisor · by owner (recording rules)", cpu?.tier ?? "")
        check(
            "only the Service's query and query_range, each with 20 s",
            !asked().isEmpty && asked().allSatisfy { ($0.path == service.rangePath || $0.path == service.queryPath) && $0.query["timeout"] == "20s" })
        note("kubernetes revisions dump: \(charts.lines(in: scope).first { $0.contains(revisionsID) } ?? "not drawn")")

        // Its namespace's tab: by workload from the rules, against its quota over time.
        page.showTab(.overview)
        page.closeDetail()
        page.showKind(.namespaces)
        check("the namespaces listed", await eventually(15) { model.kind.fullName == "namespaces" && model.rows[KubeRowID(namespace: nil, name: namespace)] != nil })
        fake.forgetRequests()
        page.selection = [namespace]
        check("m opens the namespace's Metrics tab", page.press("m") && page.detailTab == .metrics && page.detail?.ref.name == namespace)
        check("a namespace's ranges over Prometheus too", page.metricsRanges == KubeMetricsRange.allCases)
        page.pickMetricsRange(.hour)
        let nsCPU = "namespace.\(namespace).cpu"
        func namespaceCPU() -> KubePodCharts.Chart? { page.detail.flatMap { page.objectCharts(of: $0) }?.charts.first { $0.data.id == nsCPU } }
        check(
            "its CPU by workload from Prometheus, against its quota",
            await eventually(25) {
                guard let chart = namespaceCPU() else { return false }
                return chart.data.source == "Prometheus" && chart.data.usage.map(\.id) == ["Deployment/api"] && chart.data.references.first?.role == .quota
            }, (namespaceCPU().map { "\($0.data.source) \($0.data.usage.map(\.id)) \($0.data.references.map(\.name))" } ?? "none") + "; " + said())
        check("the quota as kube-state-metrics says it", namespaceCPU()?.chips.first?.text == "requests 10% of quota", "\(namespaceCPU()?.chips.map(\.text) ?? [])")
        check("what it requests but leaves idle", namespaceCPU()?.chips.contains { $0.text.hasPrefix("requested but idle:") } == true)
        check(
            "ranked once a measure, its eight by the rule",
            asked().filter { $0.query["query"]?.hasPrefix("topk(8,") == true }.count == 2
                && asked().contains { $0.query["query"]?.contains(#"workload=~"api""#) == true },
            "\(asked().filter { $0.query["query"]?.hasPrefix("topk(8,") == true }.map(\.query)); " + said())
        check(
            "its pods by phase from kube-state-metrics",
            await eventually(10) { page.detail.flatMap { page.objectCharts(of: $0) }?.charts.first { $0.data.id == "namespace.\(namespace).phases" }?.data.source == "Prometheus" })
        check("Prometheus written nothing", fake.writes.isEmpty)
        page.showTab(.overview)
        page.closeDetail()
    }
}
