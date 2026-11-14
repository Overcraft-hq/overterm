import AppKit
import Foundation

/// The Kubernetes page at a large cluster's scale on FakeKubeAPI
/// (docs/design/kubernetes/analysis.md, Section 10): 5,000 pods across 50
/// namespaces, each namespace's ten Deployments, their ReplicaSets and a
/// Service each — and in `acme-00` one Deployment of 200 pods. Every
/// namespace listed: the first list's time to rows (a streaming list),
/// the list scrolled top to bottom (as `dockerPerf` scrolls), a burst of
/// 500 watch events across namespaces applied, the Overview's health
/// checks read and decoded, the 200-pod Deployment's dependency tree, and
/// the footprint after. Timed by the page's own models and views (no
/// system events). Its kubeconfig is OVERTERM_KUBECONFIG's file, whose
/// contexts reach only the fake. Reads only.
extension E2ERunner {
    func kubernetesScaleScenario() async {
        await settledPrompt()
        guard let path = ProcessInfo.processInfo.environment["OVERTERM_KUBECONFIG"], !path.isEmpty, !path.contains(":") else {
            return check("OVERTERM_KUBECONFIG names the scenario's own file", false, "testKubernetesScale sets it")
        }
        let kubeconfig = URL(fileURLWithPath: path)
        guard !KubeconfigSources.isUsersOwn(kubeconfig, home: FileManager.default.homeDirectoryForCurrentUser) else {
            return check("OVERTERM_KUBECONFIG isn't under ~/.kube", false, path)
        }
        check("the run guards the user's kubeconfig", AppEnvironment.guardsKubeconfig)
        let footprintBefore = Self.footprintMB()
        let socket = "/tmp/ot-e2e-kscale-\(UUID().uuidString.prefix(6)).sock"
        let fake = FakeKubeAPI(socket: socket)
        let port: Int
        do {
            try fake.start()
            port = try fake.listenTCP()
        } catch {
            return check("the fake API server starts", false, "\(error)")
        }
        defer { fake.stop() }

        // 50 namespaces: acme-00 holds `big`, 200 pods; the 49 others the
        // other 4,800, by ten Deployments each.
        let namespaces = (0..<50).map { String(format: "acme-%02d", $0) }
        let count = 5000
        let bigPods = 200
        fake.addNamespace("shop")
        for namespace in namespaces { fake.addNamespace(namespace) }
        func deployment(_ name: String, namespace: String, replicas: Int) -> (deployment: String, set: String)? {
            fake.add(
                "deployments.apps", name, namespace: namespace,
                values: ["Ready": .text("\(replicas)/\(replicas)"), "Up-to-date": .integer(replicas), "Available": .integer(replicas)],
                fields: [
                    "spec": [
                        "replicas": replicas, "selector": ["matchLabels": ["app": name]],
                        "template": [
                            "metadata": ["labels": ["app": name]],
                            "spec": [
                                "containers": [
                                    [
                                        "name": "app", "image": "acme/\(name):1.4.2",
                                        "resources": ["requests": ["cpu": "100m", "memory": "64Mi"], "limits": ["memory": "128Mi"]],
                                        "readinessProbe": ["httpGet": ["path": "/ready", "port": 8080]],
                                        "livenessProbe": ["httpGet": ["path": "/live", "port": 8080]],
                                    ]
                                ]
                            ],
                        ],
                    ],
                    "status": ["observedGeneration": 0, "replicas": replicas, "readyReplicas": replicas, "updatedReplicas": replicas, "availableReplicas": replicas],
                ])
            guard let uid = fake.uid("deployments.apps", name, namespace: namespace) else { return nil }
            let set = "\(name)-7c9d"
            fake.add(
                "replicasets.apps", set, namespace: namespace, labels: ["app": name], annotations: ["deployment.kubernetes.io/revision": "1"],
                fields: [
                    "metadata": ["ownerReferences": [["apiVersion": "apps/v1", "kind": "Deployment", "name": name, "uid": uid, "controller": true]]],
                    "spec": ["replicas": replicas], "status": ["replicas": replicas, "readyReplicas": replicas],
                ])
            fake.add(
                "services", name, namespace: namespace, values: ["Type": "ClusterIP", "Port(s)": "80/TCP"],
                fields: ["spec": ["selector": ["app": name], "ports": [["port": 80, "targetPort": 8080, "protocol": "TCP"]]]])
            guard let setUID = fake.uid("replicasets.apps", set, namespace: namespace) else { return nil }
            return (name, setUID)
        }
        guard let big = deployment("big", namespace: "acme-00", replicas: bigPods) else { return check("acme-00's big added", false) }
        for index in 0..<bigPods {
            let name = String(format: "big-7c9d-%04d", index)
            fake.addPod(name, namespace: "acme-00", labels: ["app": "big"])
            fake.setFields(
                "pods", name, namespace: "acme-00",
                ["metadata": ["ownerReferences": [["apiVersion": "apps/v1", "kind": "ReplicaSet", "name": "big-7c9d", "uid": big.set, "controller": true]]]])
        }
        let others = Array(namespaces.dropFirst())
        for namespace in others {
            for app in 0..<10 { _ = deployment("web-\(app)", namespace: namespace, replicas: 10) }
        }
        for index in 0..<(count - bigPods) {
            let namespace = others[index % others.count]
            let app = (index / others.count) % 10
            let name = String(format: "web-\(app)-7c9d-%04d", index)
            fake.addPod(name, namespace: namespace, labels: ["app": "web-\(app)"])
            fake.setPodMetrics(name, namespace: namespace, [("app", "\(index % 900 + 1)m", "\(index % 500 + 16)Mi")])
        }
        do {
            try Self.fakeKubeconfig(port: port).write(to: kubeconfig, atomically: true, encoding: .utf8)
        } catch {
            return check("the scenario's kubeconfig is written", false, "\(error)")
        }
        defer { try? FileManager.default.removeItem(at: kubeconfig) }
        let model = KubernetesModel.shared
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
        model.statusOverride = { _ in .open }
        defer {
            model.connectOverride = nil
            model.statusOverride = nil
        }
        let page = app.kubernetesPage

        // The first list: every namespace, opened until the table holds every row.
        app.toggleKubernetesPage(nil)
        check("the page shows fake-dev", await eventually(15) { model.selectedName == "fake-dev" && model.discovery?.kind("deployments") != nil })
        let opened = CACurrentMediaTime()
        model.setScope(.all)
        check(
            "5,000 pods listed in every namespace", await eventually(30) { model.rows.count == count && model.listState == .live },
            "\(model.rows.count) \(model.listState)")
        var table: NSTableView?
        var scroll: NSScrollView?
        func find() {
            guard let view = app.kubernetesView else { return }
            func walk(_ view: NSView) {
                if let found = view as? NSScrollView, !found.isHidden, let documentView = found.documentView as? NSTableView,
                    documentView.accessibilityIdentifier() == "kubernetes.list"
                {
                    scroll = found
                    table = documentView
                }
                view.subviews.forEach(walk)
            }
            walk(view)
        }
        let drawn = await eventually(30) {
            find()
            return table?.numberOfRows == count
        }
        app.kubernetesView?.displayIfNeeded()
        let firstList = (CACurrentMediaTime() - opened) * 1000
        check("the table has every row", drawn, "\(table?.numberOfRows ?? -1) rows")
        note("kubernetes scale: first list of \(count) pods in \(namespaces.count) namespaces to rows: \(Int(firstList)) ms")
        check("listed in under 5 s", firstList < 5000, "\(Int(firstList)) ms")
        check(
            "by one streaming list of every namespace",
            fake.requests.filter { $0.isWatch && $0.path == "/api/v1/pods" && $0.query["sendInitialEvents"] == "true" }.count == 1
                && !fake.requests.contains { !$0.isWatch && $0.path == "/api/v1/pods" })

        // Scrolled top to bottom, a third of a screen a step.
        find()
        if let scroll, let view = app.kubernetesView {
            var samples: [Double] = []
            var y: CGFloat = 0
            for _ in 0..<1000 {
                let height = scroll.documentView?.frame.height ?? 0
                let visible = scroll.contentView.bounds.height
                guard y + visible < height else { break }
                y += visible / 3
                let start = CACurrentMediaTime()
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                samples.append((CACurrentMediaTime() - start) * 1000)
                await Task.yield()
            }
            let scrolled = Self.summary(samples)
            note("kubernetes scale: list scrolled: \(samples.count) steps, \(scrolled)")
            check("the list scrolls in under 35 ms a step (p95)", scrolled.p95 < 35, "\(scrolled)")
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            check("the list's table", false)
        }

        // A burst of 500 events across the namespaces: every ninth pod failing.
        let burst = Array(stride(from: 0, to: count - bigPods, by: 9)).prefix(500).map { index in
            (namespace: others[index % others.count], name: String(format: "web-\((index / others.count) % 10)-7c9d-%04d", index))
        }
        let burstCount = burst.count
        let started = CACurrentMediaTime()
        let sending = Task.detached {
            for pod in burst {
                fake.updatePod(pod.name, namespace: pod.namespace) {
                    $0.status = "CrashLoopBackOff"
                    $0.ready = 0
                    $0.restarts = 1
                }
            }
        }
        _ = await sending.value
        let applied = await eventually(20) { page.failing.count == burstCount }
        let burstTime = (CACurrentMediaTime() - started) * 1000
        check("the burst's \(burstCount) events applied", applied, "\(page.failing.count) failing")
        note("kubernetes scale: burst of \(burstCount) events across \(others.count) namespaces applied in \(Int(burstTime)) ms")
        check("in under 3 s", burstTime < 3000, "\(Int(burstTime)) ms")
        check("by the one watch", fake.requests.filter { $0.isWatch && $0.path == "/api/v1/pods" }.count == 1)

        // The Overview's health checks: every namespace's lists, bounded, read and decoded.
        fake.forgetRequests()
        let healthStart = CACurrentMediaTime()
        check("1 is the Overview", page.press("1") && page.section == .overview)
        let health = page.health
        let healthRead = await eventually(30) { health.state == .loaded }
        let healthTime = (CACurrentMediaTime() - healthStart) * 1000
        check("its health checks are read", healthRead, "\(health.state)")
        let healthReads = fake.requests.filter { !$0.isWatch && $0.query["limit"] != nil && $0.query["includeObject"] == nil }
        note(
            "kubernetes scale: Overview health checks read and decoded in \(Int(healthTime)) ms (\(healthReads.count) lists, \(health.report.findings.count) findings)"
        )
        check("in under 3 s", healthTime < 3000, "\(Int(healthTime)) ms")
        check("never a Secret or a ConfigMap", !fake.requests.contains { $0.path.contains("/secrets") || $0.path.contains("/configmaps") })
        // A cluster 100 ms away (a VPN's): the lists one after the other, then four at once.
        let healthPaths = Set(healthReads.map(\.path))
        for path in healthPaths { fake.answerSlowly(path, milliseconds: 100) }
        var healthFar: [Int: Int] = [:]
        for width in [1, KubeHealthSession.readWidth] {
            let saved = KubeHealthSession.readWidth
            KubeHealthSession.readWidth = width
            _ = page.press("2")
            let start = CACurrentMediaTime()
            _ = page.press("1")
            let read = await eventually(30) { page.health.state == .loaded }
            healthFar[width] = Int((CACurrentMediaTime() - start) * 1000)
            KubeHealthSession.readWidth = saved
            check("read again \(width) at a time", read, "\(page.health.state)")
        }
        for path in healthPaths { fake.answerSlowly(path, milliseconds: nil) }
        note(
            "kubernetes scale: health checks with 100 ms a list: \(healthFar[1] ?? -1) ms one after the other, \(healthFar[KubeHealthSession.readWidth] ?? -1) ms \(KubeHealthSession.readWidth) at once"
        )
        check("asked at once, faster than one after the other", (healthFar[KubeHealthSession.readWidth] ?? .max) < (healthFar[1] ?? 0), "\(healthFar)")
        check("2 is Workloads", page.press("2") && page.section == .workloads)

        // The dependency tree of a Deployment of 200 pods.
        guard let deployments = model.discovery?.kind("deployments") else { return check("fake-dev serves Deployments", false) }
        page.showKind(deployments)
        check(
            "every namespace's 500 Deployments",
            await eventually(20) { model.kind.fullName == "deployments.apps" && model.rows.count == 1 + others.count * 10 && model.listState == .live },
            "\(model.rows.count)")
        fake.forgetRequests()
        page.selection = ["acme-00/big"]
        let treeStart = CACurrentMediaTime()
        check("x opens big's tree", page.openTree())
        let treeRead = await eventually(30) { page.detail?.tree?.state == .loaded }
        let treeTime = (CACurrentMediaTime() - treeStart) * 1000
        check("its tree read and built", treeRead, "\(String(describing: page.detail?.tree?.state))")
        let tree = page.detail?.tree?.tree
        let set = tree?.root.all.first { $0.kind == "ReplicaSet" && $0.name == "big-7c9d" }
        check("its ReplicaSet", set != nil)
        check(
            "nothing it couldn't read — only that 150 pods aren't drawn", tree?.notes == ["big-7c9d: 150 more pods not drawn — the first 50 are."],
            "\(tree?.notes ?? [])")
        // The detail's own selected pods are a Table; the tree's, whole objects.
        let pods = fake.requests.filter { $0.path == "/api/v1/namespaces/acme-00/pods" && !$0.isWatch && $0.query["includeObject"] == nil }
        check(
            "its pods by one bounded read, by its selector",
            pods.count == 1 && pods.first?.query["limit"] == String(KubeTree.podLimit) && pods.first?.query["labelSelector"] == "app=big", "\(pods.map(\.query))")
        note("kubernetes scale: dependency tree of a Deployment of \(bigPods) pods in \(Int(treeTime)) ms")
        check("in under 2 s", treeTime < 2000, "\(Int(treeTime)) ms")
        // 100 ms away again: its lists one after the other, then at once.
        let treePaths = Set(fake.requests.filter { !$0.isWatch && $0.path.hasPrefix("/api") && $0.path.contains("/namespaces/acme-00/") && $0.query["limit"] != nil }.map(\.path))
        for path in treePaths { fake.answerSlowly(path, milliseconds: 100) }
        var treeFar: [Int: Int] = [:]
        for width in [1, KubeTreeSession.readWidth] {
            let saved = KubeTreeSession.readWidth
            KubeTreeSession.readWidth = width
            page.closeDetail()
            page.selection = ["acme-00/big"]
            let start = CACurrentMediaTime()
            _ = page.openTree()
            let read = await eventually(30) { page.detail?.tree?.state == .loaded }
            treeFar[width] = Int((CACurrentMediaTime() - start) * 1000)
            KubeTreeSession.readWidth = saved
            check("its tree again, \(width) at a time", read, "\(String(describing: page.detail?.tree?.state))")
        }
        for path in treePaths { fake.answerSlowly(path, milliseconds: nil) }
        note(
            "kubernetes scale: its tree with 100 ms a list (\(treePaths.count) lists): \(treeFar[1] ?? -1) ms one after the other, \(treeFar[KubeTreeSession.readWidth] ?? -1) ms at once"
        )
        check("faster at once", (treeFar[KubeTreeSession.readWidth] ?? .max) < (treeFar[1] ?? 0), "\(treeFar)")
        page.closeDetail()
        page.showKind(.pods)

        let footprint = Self.footprintMB()
        note(String(format: "kubernetes scale: footprint %.0f MB after (%.0f MB before the cluster)", footprint, footprintBefore))
        check("in a sane amount of memory (< 900 MB)", footprint < 900, String(format: "%.0f MB", footprint))

        app.closeOverlay(.kubernetes)
        check("closed, its watch ends", await eventually(5) { fake.openWatches == 0 }, "\(fake.openWatches)")
        check("it wrote nothing", fake.writes.isEmpty)
        KubeSocketFolder.app.remove()
    }
}
