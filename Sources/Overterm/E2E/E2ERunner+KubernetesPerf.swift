import AppKit
import Foundation

/// The Kubernetes page with 5,000 pods in one namespace on FakeKubeAPI
/// (docs/design/kubernetes/analysis.md, Section 10): the first draw — the
/// page opened until the table has every row —, a burst of 500 watch
/// events applied (in the model's 120 ms batches), and the list scrolled
/// top to bottom, timed by the page's own views (no system events). The
/// run's kubeconfig is OVERTERM_KUBECONFIG's file, written here, whose
/// contexts reach only the fake; the page talks to its socket directly,
/// so kubectl's proxy isn't what is timed. Usage is served for every pod.
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
        check("with usage", await eventually(15) { model.metrics.reading(.pods)?.sample?.pods.count == count }, "\(String(describing: model.metrics.reading(.pods)?.sample?.pods.count))")

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

        app.closeOverlay(.kubernetes)
        check("closed, its watch ends", await eventually(5) { fake.openWatches == 0 }, "\(fake.openWatches)")
        check("and no usage is polled", await eventually(5) { !model.metrics.isPolling })
        check("it wrote nothing", fake.writes.isEmpty)
        KubeSocketFolder.app.remove()
    }
}
