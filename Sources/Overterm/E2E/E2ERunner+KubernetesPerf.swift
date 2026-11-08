import AppKit
import Foundation

/// The Kubernetes page with 5,000 pods in one namespace on FakeKubeAPI
/// (docs/design/kubernetes/analysis.md, Section 10): the first draw — the
/// page opened until the table has every row, by a streaming list —, a burst of 500 watch
/// events applied (in the model's 120 ms batches), and the list scrolled
/// top to bottom, timed by the page's own views (no system events). The
/// run's kubeconfig is OVERTERM_KUBECONFIG's file, written here, whose
/// contexts reach only the fake; the page talks to its socket directly,
/// so kubectl's proxy isn't what is timed. Usage is served for every pod.
/// Then ten namespaces of 500 pods each at once: ten watches, merged, the
/// same budgets for the first list and a burst; their Overview a watch a
/// part, not a part a namespace, and cheap while quiet.
extension E2ERunner {
    func kubernetesPerfScenario() async {
        await settledPrompt()
        guard let path = ProcessInfo.processInfo.environment["OVERTERM_KUBECONFIG"], !path.isEmpty, !path.contains(":") else {
            return check("OVERTERM_KUBECONFIG names the scenario's own file", false, "testKubernetesPerf sets it")
        }
        let kubeconfig = URL(fileURLWithPath: path)
        guard !KubeconfigSources.isUsersOwn(kubeconfig, home: FileManager.default.homeDirectoryForCurrentUser) else {
            return check("OVERTERM_KUBECONFIG isn't under ~/.kube", false, path)
        }
        check("the run guards the user's kubeconfig", AppEnvironment.guardsKubeconfig)
        let socket = "/tmp/ot-e2e-kperf-\(UUID().uuidString.prefix(6)).sock"
        let fake = FakeKubeAPI(socket: socket)
        let port: Int
        do {
            try fake.start()
            port = try fake.listenTCP()
        } catch {
            return check("the fake API server starts", false, "\(error)")
        }
        defer { fake.stop() }
        fake.addNamespace("shop")
        fake.addNamespace("payments")
        let count = 5000
        for index in 0..<count {
            let name = String(format: "perf-%04d", index)
            fake.addPod(name, namespace: "shop", labels: ["app": "perf-\(index % 50)"])
            fake.setPodMetrics(name, namespace: "shop", [("app", "\(index % 900 + 1)m", "\(index % 500 + 16)Mi")])
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

        // The first draw: opened until the table holds every row.
        let opened = CACurrentMediaTime()
        app.toggleKubernetesPage(nil)
        check("5,000 pods listed", await eventually(30) { model.rows.count == count && model.listState == .live }, "\(model.rows.count) \(model.listState)")
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
        let firstDraw = (CACurrentMediaTime() - opened) * 1000
        check("the table has every row", drawn, "\(table?.numberOfRows ?? -1) rows")
        note("kubernetes first draw of \(count) pods: \(Int(firstDraw)) ms")
        check("first drawn in under 5 s", firstDraw < 5000, "\(Int(firstDraw)) ms")
        check(
            "listed by a streaming list (the fake says 1.34)",
            fake.requests.contains { $0.isWatch && $0.path == "/api/v1/namespaces/shop/pods" && $0.query["sendInitialEvents"] == "true" }
                && !fake.requests.contains { !$0.isWatch && $0.path == "/api/v1/namespaces/shop/pods" })
        check("with usage", await eventually(15) { model.metrics.reading(.pods)?.sample?.pods.count == count }, "\(String(describing: model.metrics.reading(.pods)?.sample?.pods.count))")
        // Its 5,000 rows merged into the ring off the main thread, assigned
        // whole (metrics.md 5.3), every row kept under the 6 MB cap.
        check(
            "its rows merged into the ring off the main thread, under the cap",
            await eventually(15) { model.metrics.merges >= 1 && model.metrics.ring.listKeys == count }
                && model.metrics.mergesOnMain == 0 && model.metrics.ring.bytes <= KubeUsageRing.defaultByteCap,
            "\(model.metrics.merges) merges (\(model.metrics.mergesOnMain) on the main thread), \(model.metrics.ring.listKeys) rows, \(model.metrics.ring.bytes) bytes")
        note("kubernetes usage ring of \(count) rows: \(model.metrics.ring.bytes / 1024) KB")

        // A burst of 500 events: every 10th pod starts failing.
        let burst = Array(stride(from: 0, to: count, by: 10)).map { String(format: "perf-%04d", $0) }
        let started = CACurrentMediaTime()
        let sending = Task.detached {
            for name in burst {
                fake.updatePod(name, namespace: "shop") {
                    $0.status = "CrashLoopBackOff"
                    $0.ready = 0
                    $0.restarts = 1
                }
            }
        }
        _ = await sending.value
        let applied = await eventually(20) { page.failing.count == burst.count }
        let burstTime = (CACurrentMediaTime() - started) * 1000
        check("the burst's 500 events applied", applied, "\(page.failing.count) failing")
        note("kubernetes burst of \(burst.count) events applied in \(Int(burstTime)) ms")
        check("in under 3 s", burstTime < 3000, "\(Int(burstTime)) ms")
        check("by the one watch", fake.requests.filter { $0.isWatch && $0.path == "/api/v1/namespaces/shop/pods" }.count == 1)

        // The list scrolled top to bottom, a third of a screen a step.
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
            note("kubernetes list scrolled: \(samples.count) steps, \(scrolled)")
            check("the list scrolls in under 35 ms a step (p95)", scrolled.p95 < 35, "\(scrolled)")
        } else {
            check("the list's table", false)
        }

        // The usage column sorted: 5,000 numbers.
        let sortStart = CACurrentMediaTime()
        page.sort = ResourceSort(column: KubernetesPageModel.cpuColumn, ascending: false)
        let sorted = page.rows
        let sortTime = (CACurrentMediaTime() - sortStart) * 1000
        note("kubernetes rows by CPU: \(Int(sortTime)) ms")
        check("sorted by CPU, the busiest first", sorted.first.map { page.usage(.cpu, of: $0).text } == "900m", sorted.first?.row.id.name ?? "none")
        check("in under 250 ms", sortTime < 250, "\(Int(sortTime)) ms")
        page.sort = nil

        await kubernetesChartPerf()

        await tenNamespaces(model, page, fake)

        app.closeOverlay(.kubernetes)
        check("closed, its watch ends", await eventually(5) { fake.openWatches == 0 }, "\(fake.openWatches)")
        check("and no usage is polled", await eventually(5) { !model.metrics.isPolling })
        check("it wrote nothing", fake.writes.isEmpty)
        KubeSocketFolder.app.remove()
    }

    /// Ten namespaces of 500 pods each picked at once (the cap): a watch
    /// each, merged into one list in under 5 s, a burst of 500 events
    /// across them applied in under 3 s; then back to shop.
    private func tenNamespaces(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        let names = (0..<KubeScope.watchCap).map { "team-\($0)" }
        let each = 500
        for name in names {
            fake.addNamespace(name)
            for index in 0..<each { fake.addPod(String(format: "pod-%03d", index), namespace: name) }
        }
        let started = CACurrentMediaTime()
        model.setScope(.of(names))
        let listed = await eventually(30) { model.rows.count == names.count * each && model.listState == .live }
        let listTime = (CACurrentMediaTime() - started) * 1000
        check("ten namespaces' 5,000 pods in one list", listed, "\(model.rows.count) \(model.listState)")
        note("kubernetes ten namespaces of \(each) pods listed in \(Int(listTime)) ms")
        check("in under 5 s", listTime < 5000, "\(Int(listTime)) ms")
        check(
            "a watch each, none across the cluster",
            await eventually(10) { Set(names.map { "/api/v1/namespaces/\($0)/pods" }).isSubset(of: Set(fake.requests.filter(\.isWatch).map(\.path))) }
                && !fake.requests.contains { $0.isWatch && $0.path == "/api/v1/pods" })
        check("with a Namespace column first", page.columns.first?.title == "Namespace")

        let burst = names.flatMap { name in stride(from: 0, to: each, by: 10).map { (name, String(format: "pod-%03d", $0)) } }
        let burstStart = CACurrentMediaTime()
        let sending = Task.detached {
            for (namespace, pod) in burst {
                fake.updatePod(pod, namespace: namespace) {
                    $0.status = "CrashLoopBackOff"
                    $0.ready = 0
                    $0.restarts = 1
                }
            }
        }
        _ = await sending.value
        let applied = await eventually(20) { page.failing.count == burst.count }
        let burstTime = (CACurrentMediaTime() - burstStart) * 1000
        check("the burst's \(burst.count) events across ten watches applied", applied, "\(page.failing.count) failing")
        note("kubernetes burst of \(burst.count) events over ten namespaces applied in \(Int(burstTime)) ms")
        check("in under 3 s", burstTime < 3000, "\(Int(burstTime)) ms")

        await tenNamespacesOverview(model, page, fake, names)

        model.setScope(.namespace("shop"))
        check("back to shop: one watch", await eventually(10) { model.rows.count == 5000 && fake.openWatches <= 2 }, "\(model.rows.count) \(fake.openWatches)")
    }

    /// The Overview of the ten: its parts share the page's watch budget —
    /// each one watch across the cluster kept to them, not ten a part (a
    /// hundred) — and a quiet cluster costs little CPU while it shows.
    private func tenNamespacesOverview(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, _ names: [String]) async {
        let before = fake.openWatches
        fake.forgetRequests()
        check("1 is the Overview of the ten", page.press("1") && page.section == .overview)
        let overview = page.clusterOverview
        check("it reads them", await eventually(20) { overview.state == .live && overview.overview.pods >= names.count * 500 }, "\(overview.state) \(overview.overview.pods)")
        let parts = KubeClusterOverviewSession.parts(model.discovery).count
        _ = await eventually(10) { fake.openWatches - before >= parts }
        let opened = fake.openWatches - before
        note("kubernetes Overview of ten namespaces: \(opened) watches for \(parts) parts")
        check("a watch a part, none a namespace", opened <= parts, "\(opened) watches for \(parts) parts")
        check(
            "its pods watched across the cluster, kept to the ten",
            !fake.requests.contains { $0.isWatch && $0.path.hasPrefix("/api/v1/namespaces/team-") && $0.query["fieldSelector"] != nil }
                && fake.requests.contains { $0.isWatch && $0.path == "/api/v1/pods" && $0.query["fieldSelector"] == "status.phase=Running" })
        await pause(2)  // the first lists' work settled
        let cpu0 = Self.cpuSeconds()
        let wall0 = Date()
        await pause(5)
        let cpu = (Self.cpuSeconds() - cpu0) / Date().timeIntervalSince(wall0) * 100
        note(String(format: "kubernetes Overview of ten namespaces, quiet: CPU %.2f%%", cpu))
        check("quiet, it costs little CPU", cpu < 10, String(format: "%.2f%%", cpu))
        page.showKind(.pods)
        check("the Overview's watches end", await eventually(10) { fake.openWatches <= before }, "\(fake.openWatches) open, \(before) before")
    }
}
