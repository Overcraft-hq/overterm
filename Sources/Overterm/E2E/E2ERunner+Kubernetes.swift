import AppKit
import Darwin

/// The Kubernetes page against the fake API server (FakeKubeAPI), never one
/// of the user's clusters: this Mac's current context is production. The
/// run reads only OVERTERM_KUBECONFIG's file (testKubernetes names one in a
/// temporary folder; the scenario writes it once the fake listens), whose
/// two contexts both reach the fake on 127.0.0.1 — `fake-dev` (remote by
/// name, so read-only although its server is loopback) and `fake-prod`
/// (production by name). The real `kubectl proxy` runs in front of it when
/// kubectl is installed, with that file as its KUBECONFIG, `--context` and
/// a HOME of the run's own; else a stand-in connection goes to the fake's
/// socket directly, and what only the real proxy shows is skipped.
extension E2ERunner {
    func kubernetesScenario() async {
        await settledPrompt()
        let model = KubernetesModel.shared
        let page = app.kubernetesPage
        let home = FileManager.default.homeDirectoryForCurrentUser
        check("the run guards the user's kubeconfig", AppEnvironment.guardsKubeconfig)
        guard let path = ProcessInfo.processInfo.environment["OVERTERM_KUBECONFIG"], !path.isEmpty, !path.contains(":") else {
            return check("OVERTERM_KUBECONFIG names the scenario's own file", false, "testKubernetes sets it")
        }
        let kubeconfig = URL(fileURLWithPath: path)
        guard !KubeconfigSources.isUsersOwn(kubeconfig, home: home) else {
            return check("OVERTERM_KUBECONFIG isn't under ~/.kube", false, path)
        }
        try? FileManager.default.removeItem(at: kubeconfig)
        check("the only kubeconfig this run may read is the scenario's", AppEnvironment.kubeconfigs(extra: ["~/.kube/config"]) == [kubeconfig])

        // ⌥⌘J before the file exists: the page says there is no kubeconfig.
        app.toggleKubernetesPage(nil)
        check("⌥⌘J opens the Kubernetes page", app.store.showingOverlay == .kubernetes && app.kubernetesView?.isHidden == false)
        check("it sits in the strip as a page", app.store.openOverlays.contains(.kubernetes))
        check(
            "with no kubeconfig to read it has no contexts",
            await eventually(5) { model.contextsRead && model.contexts.contexts.isEmpty && model.contexts.files.isEmpty }, "\(model.contexts.files)")
        check("and says so", await shownText(15) { $0.contains("No kubeconfig") } != nil)
        app.toggleKubernetesPage(nil)

        // The fake, on a socket of its own and on 127.0.0.1.
        let socket = "/tmp/ot-e2e-kube-\(UUID().uuidString.prefix(6)).sock"
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
        fake.addPod("web-7d9", namespace: "shop", labels: ["app": "web"])
        fake.addPod(
            "worker-5c", namespace: "shop",
            FakeKubeAPI.Pod(status: "CrashLoopBackOff", phase: "Running", ready: 0, containers: 1, restarts: 5, lastRestart: "30s"))
        fake.addPod("web-7d9", namespace: "payments")
        fake.addPod("api-0", namespace: "payments")
        do {
            try Self.fakeKubeconfig(port: port).write(to: kubeconfig, atomically: true, encoding: .utf8)
        } catch {
            return check("the scenario's kubeconfig is written", false, "\(error)")
        }

        // The real kubectl proxy if this Mac has one; else the stand-in.
        let kubectl = ["/usr/local/bin/kubectl", "/opt/homebrew/bin/kubectl"].first { FileManager.default.isExecutableFile(atPath: $0) }
        if let kubectl {
            note("kubectl proxy: \(kubectl), KUBECONFIG \(kubeconfig.path) only")
            Settings.shared.set("kubernetes.kubectlPath", .string(kubectl))
        } else {
            note("no kubectl installed: a stand-in connection to the fake's socket")
            model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
            model.statusOverride = { _ in .open }
        }

        app.toggleKubernetesPage(nil)
        check(
            "the scenario's two contexts are read", await eventually(5) { model.contexts.contexts.map(\.name) == ["fake-dev", "fake-prod"] },
            "\(model.contexts.contexts.map(\.name)) \(model.contexts.problems)")
        let dev = model.contexts.context(named: "fake-dev")
        let prod = model.contexts.context(named: "fake-prod")
        check("both on 127.0.0.1", dev?.server == "http://127.0.0.1:\(port)" && prod?.server == dev?.server)
        check("fake-dev is remote, so read-only, although its server is 127.0.0.1", dev?.contextClass == .remote && dev?.isWritable == false)
        check("fake-prod is production by name, and read-only", prod?.contextClass == .production && prod?.isWritable == false)
        check("the page opens on kubectl's current context, in its namespace", model.selectedName == "fake-dev" && model.scope == .namespace("shop"))

        // The Pods list: the server's rows and columns, the namespace's only.
        check(
            "its pods are listed", await eventually(15) { model.pods.sorted.map(\.id.description) == ["shop/web-7d9", "shop/worker-5c"] },
            "\(model.pods.sorted.map(\.id.description)) \(model.podState) \(model.proxyStatus)")
        check("in the server's columns", page.columns.map(\.title) == ["Name", "Ready", "Status", "Restarts", "Age"], "\(page.columns.map(\.title))")
        check("asked for as rows only", fake.requests.contains { $0.path == "/api/v1/namespaces/shop/pods" && $0.query["includeObject"] == "None" })
        check("the list has the keyboard", await eventually(3) { self.app.kubernetesListHasKeyboard() }, "\(String(describing: window.firstResponder))")
        let worker = page.failing.first
        check(
            "a crashing pod's reason is said", page.failing.count == 1 && worker?.id.name == "worker-5c" && worker?.exitReason == "CrashLoopBackOff",
            "\(page.failing)")
        check("its restarts too", worker?.restarts == 5 && worker?.lastRestart == "30s ago", "\(String(describing: worker))")
        check("and drawn", await shownText(15) { $0.contains("CrashLoopBackOff") } != nil)
        check("ages are counted on from the row", model.anchors[KubeRowID(namespace: "shop", name: "web-7d9")]?.said != nil)
        check("nothing marks fake-dev as production", page.band == nil)

        // The watch keeps it current.
        fake.addPod("cache-0", namespace: "shop")
        check("a new pod comes in by the watch", await eventually(5) { model.pods[KubeRowID(namespace: "shop", name: "cache-0")] != nil })
        fake.updatePod("web-7d9", namespace: "shop") {
            $0.status = "OOMKilled"
            $0.ready = 0
            $0.restarts = 1
        }
        check("one that starts failing says why", await eventually(5) { page.failing.map(\.id.name) == ["web-7d9", "worker-5c"] }, "\(page.failing)")
        fake.deletePod("cache-0", namespace: "shop")
        check("one deleted goes", await eventually(5) { model.pods[KubeRowID(namespace: "shop", name: "cache-0")] == nil })
        check("by one watch, not lists again", fake.requests.filter { $0.query["watch"] == "1" }.count == 1, "\(fake.requests.suffix(4))")

        // Keys, while the list has the keyboard.
        if let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "w",
            charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)
        {
            check("w is the list's", app.handlePageKey(event))
        }
        check("and shows the wide columns", page.wide && page.columns.map(\.title).contains("IP") && page.columns.map(\.title).contains("Node"))
        _ = page.press("w")
        check("w again, the default ones", !page.wide && !page.columns.map(\.title).contains("IP"))
        page.filter = "worker"
        check("the filter's text picks rows", page.rows.map(\.id) == ["shop/worker-5c"], "\(page.rows.map(\.id))")
        page.filter = "status:oomkilled"
        check("and a status", page.rows.map(\.id) == ["shop/web-7d9"], "\(page.rows.map(\.id))")
        page.filter = ""
        let filterFocus = page.focusFilter
        check("/ goes to the filter", page.press("/") && page.focusFilter == filterFocus + 1)
        page.giveListTheKeyboard()
        _ = page.press("?")
        check("? shows the keys", page.cheatSheet)
        _ = page.press("x")
        check("any key closes them", !page.cheatSheet)

        // All namespaces: same-named pods in two are two rows.
        check("0 is all namespaces", page.press("0") && model.scope == .all)
        check(
            "every namespace's pods, same names apart",
            await eventually(10) {
                model.pods.sorted.map(\.id.description) == ["payments/api-0", "payments/web-7d9", "shop/web-7d9", "shop/worker-5c"]
            }, "\(model.pods.sorted.map(\.id.description))")
        check("with a Namespace column first", page.columns.first?.title == "Namespace")
        check(
            "asked for with their metadata, where the namespace is",
            fake.requests.contains { $0.path == "/api/v1/pods" && $0.query["includeObject"] == "Metadata" })
        check("whose creation time the age counts from", model.anchors[KubeRowID(namespace: "payments", name: "api-0")]?.created != nil)

        // Production: the band over the whole page.
        model.select("fake-prod")
        check("fake-prod is picked", model.selected?.isProduction == true)
        check("its band says production", page.band?.hasPrefix("PRODUCTION · fake-prod") == true, page.band ?? "none")
        check("and is drawn across the page", await shownText(15) { $0.contains("PRODUCTION") } != nil)
        check(
            "its pods are read too, in its namespace",
            await eventually(15) { model.pods.sorted.map(\.id.description) == ["payments/api-0", "payments/web-7d9"] && model.podState == .live },
            "\(model.podState) \(model.proxyStatus)")
        if kubectl != nil {
            check("its proxy is up", await eventually(5) { model.proxyStatus == .open }, "\(model.proxyStatus)")
        }
        model.select("fake-dev")
        check("back on fake-dev the band goes", page.band == nil)
        check("and its namespace is as it was left", model.scope == .all)

        // What reached the fake: reads only.
        if let kubectl, let dev {
            await proxyRefuses(fake, dev, kubectl: kubectl)
        }
        check("the fake was sent no write", fake.writes.isEmpty, "\(fake.writes)")
        check("nor reached by any subresource", fake.subresourceRequests.isEmpty, "\(fake.subresourceRequests)")

        // Hidden, it reads nothing.
        check("a watch is open while it shows", await eventually(5) { fake.openWatches >= 1 }, "\(fake.openWatches) open")
        app.toggleKubernetesPage(nil)
        check("back to the terminal", app.store.showingOverlay == nil)
        check("hidden, its watch ends", await eventually(5) { fake.openWatches == 0 }, "\(fake.openWatches) open")
        fake.forgetRequests()
        await pause(1.5)
        check("and nothing is asked", fake.requests.isEmpty, "\(fake.requests)")

        // Off: the page says so, and no proxy is left.
        Settings.shared.set("kubernetes.enabled", .bool(false))
        app.toggleKubernetesPage(nil)
        check("with Kubernetes off the page says so", !model.enabled && model.pods.count == 0)
        check("drawn", await shownText(15) { $0.contains("Kubernetes is off") } != nil)
        var left = await model.proxies.connected
        for _ in 0..<50 where !left.isEmpty {
            await pause(0.1)
            left = await model.proxies.connected
        }
        check("and no proxy is left", left.isEmpty, "\(left)")
        app.toggleKubernetesPage(nil)
        Settings.shared.set("kubernetes.enabled", nil)
        app.closeOverlay(.kubernetes)

        // No kubectl outlives the run (the app's quit isn't this exit).
        let pids = ManagedProcess.livePIDs
        ManagedProcess.closeAll()
        check("every kubectl proxy ends", await eventually(5) { pids.allSatisfy { kill($0, 0) != 0 } }, "\(pids)")
        KubeSocketFolder.app.remove()
        Settings.shared.set("kubernetes.kubectlPath", nil)
        model.connectOverride = nil
        model.statusOverride = nil
        try? FileManager.default.removeItem(at: kubeconfig)
    }

    /// The real proxy of a read-only context: a write and an exec, sent as
    /// a person's process on the socket could, are refused before the fake.
    private func proxyRefuses(_ fake: FakeKubeAPI, _ dev: KubeContext, kubectl: String) async {
        let proxies = KubernetesModel.shared.proxies
        let write = try? await proxies.send(dev, .POST, "/api/v1/namespaces/shop/pods", body: Data("{}".utf8), headers: [("Content-Type", "application/json")])
        check("fake-dev's proxy refuses a write", write?.status == 403, "\(write.map { "\($0.status)" } ?? "no answer")")
        let delete = try? await proxies.send(dev, .DELETE, "/api/v1/namespaces/shop/pods/web-7d9")
        check("and a delete", delete?.status == 403, "\(delete.map { "\($0.status)" } ?? "no answer")")
        let exec = try? await proxies.send(dev, .GET, "/api/v1/namespaces/shop/pods/web-7d9/exec?command=sh")
        check("and an exec", exec?.status == 403, "\(exec.map { "\($0.status)" } ?? "no answer")")
        let forward = try? await proxies.send(dev, .GET, "/api/v1/namespaces/shop/pods/web-7d9/portforward")
        check("and a port-forward", forward?.status == 403, "\(forward.map { "\($0.status)" } ?? "no answer")")
        check("the web pod is still there", fake.pod("web-7d9", namespace: "shop") != nil)
    }

    /// Two contexts on the fake: one remote by name, one production by name.
    static func fakeKubeconfig(port: Int) -> String {
        """
        apiVersion: v1
        kind: Config
        clusters:
        - name: fake-dev
          cluster: {server: "http://127.0.0.1:\(port)"}
        - name: fake-prod
          cluster: {server: "http://127.0.0.1:\(port)"}
        users:
        - name: anonymous
          user: {}
        contexts:
        - name: fake-dev
          context: {cluster: fake-dev, user: anonymous, namespace: shop}
        - name: fake-prod
          context: {cluster: fake-prod, user: anonymous, namespace: payments}
        current-context: fake-dev

        """
    }
}
