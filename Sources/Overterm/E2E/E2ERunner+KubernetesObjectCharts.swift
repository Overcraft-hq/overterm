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
/// Hidden, nothing is read. Reads only.
extension E2ERunner {
    func kubernetesObjectCharts(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        let wasShowing = app.store.showingOverlay == .kubernetes
        if !wasShowing { app.toggleKubernetesPage(nil) }
        defer { if !wasShowing, app.store.showingOverlay == .kubernetes { app.toggleKubernetesPage(nil) } }
        let interval = model.metrics.interval
        model.metrics.interval = .milliseconds(500)
        defer { model.metrics.interval = interval }
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

        // A node's tab: against its pods' requests and its allocatable, its pressure a band; its top pods on request.
        guard let nodes = model.discovery?.kind("nodes") else { return check("nodes served", false) }
        page.showKind(nodes)
        check("its node listed", await eventually(15) { model.kind.fullName == "nodes" && model.rows[KubeRowID(namespace: nil, name: node)] != nil })
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
}
