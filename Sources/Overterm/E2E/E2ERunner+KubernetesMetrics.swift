import AppKit
import Foundation

/// Stage 2d's check (docs/design/kubernetes/analysis.md, Section 9): the
/// Pods list's CPU and Memory columns on `fake-dev` — dashes, and nothing
/// asked of metrics.k8s.io, while the fake has no metrics-server (its
/// discovery names none: no error); values once it serves metrics.k8s.io,
/// polled only while the column shows; a pod's detail reading its own
/// sample, kept after it closes and after the page is left; a 403 said
/// once, with Try Again, and not asked again — nor by leaving the page.
/// Then the Overview (`1`): what
/// fails, pods by phase, the counts, the applications by their labels, the
/// cluster's usage against its nodes' allocatable with a sparkline of the
/// samples taken while it shows, the server's version — its follows ended
/// when another section shows. Reads only.
extension E2ERunner {
    func kubernetesMetrics(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        let wasShowing = app.store.showingOverlay == .kubernetes
        if !wasShowing { app.toggleKubernetesPage(nil) }
        defer { if !wasShowing, app.store.showingOverlay == .kubernetes { app.toggleKubernetesPage(nil) } }
        let interval = model.metrics.interval
        model.metrics.interval = .milliseconds(500)
        defer { model.metrics.interval = interval }
        func metricsAsked() -> [FakeKubeAPI.Request] { fake.requests.filter { $0.path.hasPrefix("/apis/metrics.k8s.io") } }
        // Its own objects: earlier checks write to shop through kind-fake.
        fake.addPod("metrics-web-1", namespace: "shop")
        fake.addPod("metrics-crash-1", namespace: "shop", FakeKubeAPI.Pod(status: "CrashLoopBackOff", phase: "Running", ready: 0, restarts: 3))
        fake.add("deployments.apps", "metrics-stuck", namespace: "shop", values: ["Ready": "0/1", "Up-to-date": 1, "Available": 0])
        fake.addEvent(about: "pods", "metrics-crash-1", namespace: "shop", type: "Warning", reason: "MetricsBackOff", message: "Back-off restarting failed container")
        if model.selectedName != "fake-dev" { model.select("fake-dev") }
        model.setScope(.namespace("shop"))
        page.showKind(.pods)
        page.filter = ""
        page.applySelector()
        check(
            "the pods of fake-dev's shop", await eventually(15) { model.rows[KubeRowID(namespace: "shop", name: "metrics-crash-1")] != nil && model.listState == .live },
            "\(model.listState)")

        // No metrics-server: discovery says so; the columns are dashes.
        fake.metricsServer = false
        model.rediscover()
        check("without a metrics-server, discovery says so", await eventually(10) { model.metrics.availability == .absent }, "\(model.metrics.availability)")
        check("the Pods list keeps its CPU and Memory columns", page.columns.map(\.title).contains("CPU") && page.columns.map(\.title).contains("Memory"))
        let web = page.rows.first { $0.row.id.name == "metrics-web-1" }
        check("each a dash", web.map { page.usage(.cpu, of: $0).text == "—" && page.usage(.memory, of: $0).text == "—" } ?? false)
        check("the page says why", await shownText(15) { $0.contains("No metrics-server") } != nil)
        fake.forgetRequests()
        await pause(1.5)
        check("and asks metrics.k8s.io nothing — no error either", metricsAsked().isEmpty && model.listState == .live, "\(metricsAsked())")

        // metrics-server comes: values, polled while shown.
        fake.metricsServer = true
        fake.setPodMetrics("metrics-web-1", namespace: "shop", [("app", "250m", "64Mi")])
        fake.setPodMetrics("metrics-crash-1", namespace: "shop", [("app", "3m", "12Mi")])
        model.rediscover()
        check("served, it is read", await eventually(15) { model.metrics.availability == .served && model.metrics.reading(.pods)?.sample != nil })
        let sampled = page.rows.first { $0.row.id.name == "metrics-web-1" }
        check("the pod's CPU", sampled.map { page.usage(.cpu, of: $0).text } == "250m", sampled.map { page.usage(.cpu, of: $0).text } ?? "no row")
        check("and memory", sampled.map { page.usage(.memory, of: $0).text } == "64Mi")
        check("drawn", await shownText(15) { $0.contains("250m") } != nil)
        check(
            "asked as kubectl top asks, in the namespace", metricsAsked().contains { $0.path == "/apis/metrics.k8s.io/v1beta1/namespaces/shop/pods" },
            "\(metricsAsked())")
        check("polled again while shown", await eventually(10) { metricsAsked().count >= 3 }, "\(metricsAsked().count)")

        // A pod's detail reads its own sample (metrics.md 4.1), kept an hour after it closes.
        let webRef = KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "metrics-web-1")
        let own = "/apis/metrics.k8s.io/v1beta1/namespaces/shop/pods/metrics-web-1"
        page.open(webRef, from: .list)
        page.detailTab = .overview
        check("a pod's detail reads its own sample", await eventually(10) { metricsAsked().filter { $0.path == own }.count >= 2 }, "\(metricsAsked().map(\.path))")
        check("its usage drawn from it", await shownText(15) { $0.contains("cpu 250m") } != nil)
        check(
            "kept in the ring as a detail's, both tiers",
            await eventually(10) {
                model.metrics.ring.holds(.pod(namespace: "shop", name: "metrics-web-1"), .detail)
                    && !model.metrics.ring.folded(.pod(namespace: "shop", name: "metrics-web-1")).isEmpty
            })
        page.closeDetail()
        fake.forgetRequests()
        await pause(1.5)
        check("closed, it isn't read", !metricsAsked().contains { $0.path == own }, "\(metricsAsked().map(\.path))")
        check("but its samples stay their hour", model.metrics.ring.holds(.pod(namespace: "shop", name: "metrics-web-1"), .detail))

        // Leaving the page and coming back (decision 1): kept, not dropped as if the context had changed.
        app.toggleKubernetesPage(nil)
        check("left, the model is hidden", await eventually(5) { !model.isShown && !model.metrics.isPolling }, "shown \(model.isShown)")
        app.toggleKubernetesPage(nil)
        check("back, it is shown again", await eventually(10) { model.isShown && model.listState == .live })
        check(
            "the detail's samples survive leaving the page, both tiers",
            model.metrics.ring.holds(.pod(namespace: "shop", name: "metrics-web-1"), .detail)
                && !model.metrics.ring.folded(.pod(namespace: "shop", name: "metrics-web-1")).isEmpty)

        // A 403 is said once, and not asked again every interval.
        fake.forbidden.insert("pods.metrics.k8s.io")
        check("refused, said in its own words", await shownText(15) { $0.contains("metrics-server answered 403") } != nil)
        check("the list stands", model.listState == .live && model.rows[KubeRowID(namespace: "shop", name: "metrics-web-1")] != nil)
        fake.forgetRequests()
        await pause(2)
        check("and not asked again", metricsAsked().isEmpty, "\(metricsAsked().map(\.path))")
        let retryShown = await shownText(10) { $0.contains("Try Again") } != nil
        check("Try Again beside it", page.metricsNoteIsRefusal && retryShown)
        app.toggleKubernetesPage(nil)
        check("left again, hidden", await eventually(5) { !model.isShown })
        app.toggleKubernetesPage(nil)
        check("back again", await eventually(10) { model.isShown && model.listState == .live })
        await pause(1.5)
        check("leaving and coming back asks nothing again", metricsAsked().isEmpty, "\(metricsAsked().map(\.path))")
        check(
            "the refusal still said", model.metrics.reading(.pods)?.refused?.hasPrefix("metrics-server answered 403") == true,
            model.metrics.reading(.pods)?.refused ?? "nothing")
        check("the detail's samples still held", model.metrics.ring.holds(.pod(namespace: "shop", name: "metrics-web-1"), .detail))
        // Access granted since (RBAC, no new credentials): Try Again asks again.
        fake.forbidden.remove("pods.metrics.k8s.io")
        model.retry()
        check("asked again on Try Again", await eventually(10) { model.metrics.reading(.pods)?.sample != nil })

        // The Overview.
        fake.add(
            "deployments.apps", "cart", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1],
            labels: [KubeApplications.nameLabel: "cart", KubeApplications.instanceLabel: "cart", KubeApplications.partOfLabel: "acme-shop"])
        fake.setFields("nodes", "fake-node-1", ["status": ["allocatable": ["cpu": "4", "memory": "8Gi"]]])
        fake.setNodeMetrics("fake-node-1", cpu: "1", memory: "2Gi")
        let watches = fake.openWatches
        check("1 is the Overview", page.press("1") && page.section == .overview && page.title == "Overview")
        let overview = page.clusterOverview
        check(
            "it reads the cluster", await eventually(15) { overview.state == .live && overview.overview.pods >= 2 && overview.overview.nodes == 1 },
            "\(overview.state) \(overview.problems)")
        check("pods by the server's phase", overview.overview.phases["Running"] ?? 0 >= 2, "\(overview.overview.phases)")
        check(
            "asked by field selector", fake.requests.contains { $0.path == "/api/v1/namespaces/shop/pods" && $0.query["fieldSelector"] == "status.phase=Pending" })
        check("the crashing pod first", overview.overview.failingPods.contains { $0.id.name == "metrics-crash-1" }, "\(overview.overview.failingPods)")
        check("the stuck Deployment too", overview.overview.workloads.first { $0.title == "Deployments" }?.notReady.map(\.name).contains("metrics-stuck") == true)
        check("the last hour's warnings", overview.overview.warnings.contains { $0.reason == "MetricsBackOff" }, "\(overview.overview.warnings.map(\.reason))")
        check(
            "the applications by their labels", overview.overview.systems.first { $0.partOf == "acme-shop" }?.applications.map(\.name) == ["cart"],
            "\(overview.overview.systems)")
        check("drawn", await shownText(15) { $0.localizedCaseInsensitiveContains("Needs attention") } != nil)
        check("with the cluster's usage of its allocatable", await shownText(15) { $0.contains("1000m of 4000m") } != nil)
        check("the server's version, and its nodes", await shownText(15) { $0.contains("Kubernetes v1.") && $0.contains("1 node") } != nil)
        check("the samples taken while it shows, kept", await eventually(15) { page.clusterHistory.count >= 2 }, "\(page.clusterHistory.count)")
        check("drawn as a sparkline, said so", await shownText(15) { $0.contains("sampled while shown") } != nil)
        check("while it shows, its lists are watched", fake.openWatches > watches, "\(fake.openWatches) open, \(watches) before")
        check("the list's verbs aren't keys here", !page.press("r"))
        check("2 is Workloads again", page.press("2") && page.section == .workloads)
        check("its follows end", await eventually(10) { fake.openWatches <= watches && overview.state == .idle }, "\(fake.openWatches) open")
        check("Workloads' last kind, its usage again", model.kind.fullName == "pods" && page.columns.map(\.title).contains("CPU"))

        // Hidden: no usage asked.
        app.toggleKubernetesPage(nil)
        check("hidden, no usage is polled", await eventually(5) { !model.metrics.isPolling })
        fake.forgetRequests()
        await pause(1.5)
        check("and metrics.k8s.io isn't asked", metricsAsked().isEmpty, "\(metricsAsked())")
        app.toggleKubernetesPage(nil)
        check("Metrics and the Overview wrote nothing", fake.writes.isEmpty, "\(fake.writes)")
    }
}
