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
/// socket directly, and what only the real proxy shows is skipped. Besides
/// pods the fake serves deployments, services, configmaps, a secret,
/// nodes, events, CRDs and a custom resource (widgets.example.com, with
/// printer columns of its own): the `:` bar and the digits reach them.
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
        fake.add("deployments.apps", "web", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1, "Images": "nginx:1.27"])
        fake.add("deployments.apps", "worker", namespace: "shop", values: ["Ready": "0/1", "Up-to-date": 1, "Available": 0])
        fake.add(
            "services", "web", namespace: "shop", values: ["Type": "ClusterIP", "Cluster-IP": "10.96.0.12", "External-IP": "<none>", "Port(s)": "80/TCP"])
        fake.add("configmaps", "web-config", namespace: "shop", data: ["nginx.conf": "worker_processes 1;"])
        fake.add("secrets", "web-tls", namespace: "shop", values: ["Type": "kubernetes.io/tls"], data: ["tls.crt": "fake-crt", "tls.key": "fake-key"])
        fake.add("nodes", "fake-node-1", values: ["Status": "Ready", "Roles": "control-plane", "Version": "v1.34.1"])
        fake.add(
            "events.events.k8s.io", "worker-5c.1", namespace: "shop",
            values: ["Last Seen": "30s", "Type": "Warning", "Reason": "BackOff", "Object": "pod/worker-5c", "Message": "Back-off restarting failed container"])
        fake.addCRD(
            group: "example.com", version: "v1", plural: "widgets", kind: "Widget", shortNames: ["wd"],
            columns: [FakeKubeAPI.Column(name: "Color"), FakeKubeAPI.Column(name: "Size", type: "integer"), FakeKubeAPI.Column(name: "Owner", priority: 1)])
        fake.add("widgets.example.com", "blue-1", namespace: "shop", values: ["Color": "blue", "Size": 3, "Owner": "team-a"])
        fake.add("widgets.example.com", "red-1", namespace: "shop", values: ["Color": "red", "Size": 5, "Owner": "team-b"])
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
            "its pods are listed", await eventually(15) { model.rows.sorted.map(\.id.description) == ["shop/web-7d9", "shop/worker-5c"] },
            "\(model.rows.sorted.map(\.id.description)) \(model.listState) \(model.proxyStatus)")
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
        check("a new pod comes in by the watch", await eventually(5) { model.rows[KubeRowID(namespace: "shop", name: "cache-0")] != nil })
        fake.updatePod("web-7d9", namespace: "shop") {
            $0.status = "OOMKilled"
            $0.ready = 0
            $0.restarts = 1
        }
        check("one that starts failing says why", await eventually(5) { page.failing.map(\.id.name) == ["web-7d9", "worker-5c"] }, "\(page.failing)")
        fake.deletePod("cache-0", namespace: "shop")
        check("one deleted goes", await eventually(5) { model.rows[KubeRowID(namespace: "shop", name: "cache-0")] == nil })
        check(
            "by one watch, not lists again", fake.requests.filter { $0.isWatch && $0.path.hasSuffix("/pods") }.count == 1,
            "\(fake.requests.suffix(4))")
        check("what the cluster serves is read once, its CRDs watched", fake.watched.contains(KubernetesModel.crdName), "\(fake.watched)")

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
        page.filter = "label:app=web"
        page.applySelector()
        check(
            "label: is asked of the server", await eventually(10) { model.rows.sorted.map(\.id.description) == ["shop/web-7d9"] },
            "\(model.rows.sorted.map(\.id.description))")
        check(
            "as the list's selector, through the proxy",
            fake.requests.contains { $0.path == "/api/v1/namespaces/shop/pods" && $0.query["labelSelector"] == "app=web" })
        check("and the page says so", await shownText(15) { $0.contains("Asked of the server: app=web") } != nil)
        page.filter = ""
        page.applySelector()
        check("cleared, every pod again", await eventually(10) { model.rows.count == 2 }, "\(model.rows.count)")
        let filterFocus = page.focusFilter
        check("/ goes to the filter", page.press("/") && page.focusFilter == filterFocus + 1)
        page.giveListTheKeyboard()
        _ = page.press("?")
        check("? shows the keys", page.cheatSheet)
        _ = page.press("x")
        check("any key closes them", !page.cheatSheet)
        await namespaceAndContextPickers(model, page)
        await kubernetesKinds(model, page, fake)

        // All namespaces: same-named pods in two are two rows.
        check("0 is all namespaces", page.press("0") && model.scope == .all)
        check(
            "every namespace's pods, same names apart",
            await eventually(10) {
                model.rows.sorted.map(\.id.description) == ["payments/api-0", "payments/web-7d9", "shop/web-7d9", "shop/worker-5c"]
            }, "\(model.rows.sorted.map(\.id.description))")
        check("with a Namespace column first", page.columns.first?.title == "Namespace")
        check(
            "asked for with their metadata, where the namespace is",
            fake.requests.contains { $0.path == "/api/v1/pods" && $0.query["includeObject"] == "Metadata" })
        check("whose creation time the age counts from", model.anchors[KubeRowID(namespace: "payments", name: "api-0")]?.created != nil)

        // Production: the band over the whole page — reached by c.
        check("c opens the contexts", page.press("c") && page.picker?.kind == .context)
        page.picker?.query = "prod"
        check("prod finds fake-prod", page.picker?.selected?.title == "fake-prod" && page.picker?.selected?.production == true)
        page.choosePicked()
        check("fake-prod is picked", model.selected?.isProduction == true)
        check("its band says production", page.band?.hasPrefix("PRODUCTION · fake-prod") == true, page.band ?? "none")
        check("and is drawn across the page", await shownText(15) { $0.contains("PRODUCTION") } != nil)
        check(
            "its pods are read too, in its namespace",
            await eventually(15) { model.rows.sorted.map(\.id.description) == ["payments/api-0", "payments/web-7d9"] && model.listState == .live },
            "\(model.listState) \(model.proxyStatus)")
        if kubectl != nil {
            check("its proxy is up", await eventually(5) { model.proxyStatus == .open }, "\(model.proxyStatus)")
        }
        page.openPicker(.context)
        page.picker?.move(-1)
        page.choosePicked()
        check("back on fake-dev the band goes", model.selectedName == "fake-dev" && page.band == nil)
        check("and its namespace is as it was left", model.scope == .all)

        // What reached the fake: reads only.
        if let kubectl, let dev {
            await proxyRefuses(fake, dev, kubectl: kubectl)
        }
        check("the fake was sent no write", fake.writes.isEmpty, "\(fake.writes)")
        check("nor reached by any subresource", fake.subresourceRequests.isEmpty, "\(fake.subresourceRequests)")

        // Hidden, it reads nothing — and its label: goes with it.
        _ = page.press("n")
        page.picker?.query = "shop"
        page.choosePicked()
        page.filter = "label:app=web"
        page.applySelector()
        check("a label: on the page", await eventually(10) { model.rows.sorted.map(\.id.description) == ["shop/web-7d9"] })
        check("a watch is open while it shows", await eventually(5) { fake.openWatches >= 1 }, "\(fake.openWatches) open")
        app.toggleKubernetesPage(nil)
        check("back to the terminal", app.store.showingOverlay == nil)
        check("hidden, its label: is the list's no more", model.labelSelector == nil && page.filter == "label:app=web", model.labelSelector ?? "none")
        check("hidden, its watch ends", await eventually(5) { fake.openWatches == 0 }, "\(fake.openWatches) open")
        fake.forgetRequests()
        await pause(1.5)
        check("and nothing is asked", fake.requests.isEmpty, "\(fake.requests)")
        await kubernetesSwitcher(model, page, fake)

        // Off: the page says so, and no proxy is left.
        Settings.shared.set("kubernetes.enabled", .bool(false))
        app.toggleKubernetesPage(nil)
        check("with Kubernetes off the page says so", !model.enabled && model.rows.count == 0)
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

    /// `n`, by the key as the window takes it: the namespaces, one picked by
    /// typing, one typed that nobody listed, then back.
    private func namespaceAndContextPickers(_ model: KubernetesModel, _ page: KubernetesPageModel) async {
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "n",
                charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45)
        else { return check("an n key", false) }
        page.giveListTheKeyboard()
        _ = await eventually(3) { self.app.kubernetesListHasKeyboard() }
        check("n is the list's", app.handlePageKey(event))
        check(
            "and lists the namespaces", page.picker?.kind == .namespace && page.picker?.results.map(\.title) == ["All namespaces", "shop", "payments"],
            "\(page.picker?.results.map(\.title) ?? [])")
        check("the one showing highlighted", page.picker?.selected?.title == "shop")
        check("drawn over the page", await shownText(15) { $0.contains("payments") } != nil)
        check("its field has the keyboard", await eventually(3) { !self.app.kubernetesListHasKeyboard() && self.window.firstResponder is NSTextView })
        page.picker?.query = "pay"
        page.choosePicked()
        check("pay picks payments", model.scope == .namespace("payments") && page.picker == nil)
        check(
            "whose pods are listed", await eventually(10) { model.rows.sorted.map(\.id.description) == ["payments/api-0", "payments/web-7d9"] },
            "\(model.rows.sorted.map(\.id.description))")
        check("and the list has the keyboard again", await eventually(3) { self.app.kubernetesListHasKeyboard() })
        _ = page.press("n")
        page.picker?.query = "Nowhere"
        check("a name nobody listed can be typed", page.picker?.selected?.typed == true && page.picker?.selected?.title == "nowhere")
        page.choosePicked()
        check("and is the namespace", model.scope == .namespace("nowhere"))
        check("with no pods in it", await shownText(15) { $0.contains("No pods in nowhere.") } != nil)
        _ = page.press("n")
        page.picker?.query = "shop"
        page.choosePicked()
        check("back to shop", model.scope == .namespace("shop") && page.picker == nil)
        check("its pods again", await eventually(10) { model.rows.count == 2 }, "\(model.rows.count)")
        _ = page.press("n")
        check("Esc", page.picker != nil)
        page.closePicker()
        check("closes it, the namespace as it was", page.picker == nil && model.scope == .namespace("shop"))
    }

    /// Every kind: the digits' sections, the `:` bar — by its field, Tab
    /// completing and Esc closing it — a kind's own columns, a CRD's custom
    /// resources in their printer columns, a CRD added while the page shows
    /// appearing without a reconnect; then back to the pods.
    private func kubernetesKinds(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        check("what fake-dev serves is read", await eventually(10) { model.catalog.kind(fullName: "widgets.example.com") != nil }, model.discoveryProblem ?? "")
        check(
            "its kinds are in their sections",
            model.catalog.kinds(in: .workloads).first?.fullName == "pods" && model.catalog.kinds(in: .network).map(\.fullName).contains("services")
                && model.catalog.kinds(in: .custom).map(\.fullName) == ["widgets.example.com"], "\(model.catalog.all.map(\.fullName))")
        check("and drawn down the left", await shownText(15) { $0.contains("Custom Resources") && $0.contains("Deployments") } != nil)

        // `:` by the key as the window takes it.
        page.giveListTheKeyboard()
        _ = await eventually(3) { self.app.kubernetesListHasKeyboard() }
        guard
            let colon = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: ":",
                charactersIgnoringModifiers: ";", isARepeat: false, keyCode: 41)
        else { return check("a : key", false) }
        check(": is the list's", app.handlePageKey(colon))
        check("and opens the command bar", page.command != nil)
        check("its field has the keyboard", await eventually(3) { self.window.firstResponder is NSTextView && !self.app.kubernetesListHasKeyboard() })
        page.command?.text = "deploy"
        check("drawn, with what deploy completes to", await shownText(15) { $0.contains("deployments") && $0.contains("Deployments · deploy") } != nil)
        page.runCommand()
        check(":deploy shows the deployments", model.kind.fullName == "deployments.apps" && page.command == nil && page.section == .workloads)
        check(
            "the server's deployments", await eventually(10) { model.rows.sorted.map(\.id.description) == ["shop/web", "shop/worker"] && model.listState == .live },
            "\(model.rows.sorted.map(\.id.description)) \(model.listState)")
        check("in its own columns", page.columns.map(\.title) == ["Name", "Ready", "Up-to-date", "Available", "Age"], "\(page.columns.map(\.title))")
        check("as rows only", fake.requests.contains { $0.path == "/apis/apps/v1/namespaces/shop/deployments" && $0.query["includeObject"] == "None" })
        check("titled so", page.title == "Deployments", page.title)
        check("and drawn", await shownText(15) { $0.contains("Up-to-date") } != nil)
        check("the list has the keyboard again", await eventually(3) { self.app.kubernetesListHasKeyboard() })

        // Tab completes; Esc closes, the kind as it was.
        _ = page.press(":")
        _ = await eventually(3) { self.window.firstResponder is NSTextView }
        page.command?.text = "wid"
        (window.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.insertTab(_:)))
        check("Tab completes wid to widgets", page.command?.text == "widgets", page.command?.text ?? "closed")
        (window.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        check("Esc closes the bar", page.command == nil && model.kind.fullName == "deployments.apps")
        check("and gives the list the keyboard", await eventually(3) { self.app.kubernetesListHasKeyboard() })

        // The CRD's custom resources, in its printer columns.
        _ = page.press(":")
        page.command?.text = "widgets"
        page.runCommand()
        check(":widgets shows the custom resources", model.kind.fullName == "widgets.example.com" && page.section == .custom)
        check(
            "the widgets", await eventually(10) { model.rows.sorted.map(\.id.description) == ["shop/blue-1", "shop/red-1"] },
            "\(model.rows.sorted.map(\.id.description)) \(model.listState)")
        check("in the CRD's printer columns", page.columns.map(\.title) == ["Name", "Color", "Size", "Age"], "\(page.columns.map(\.title))")
        check("its wide one behind w", page.press("w") && page.columns.map(\.title) == ["Name", "Color", "Size", "Owner", "Age"])
        _ = page.press("w")
        check("drawn", await shownText(15) { $0.contains("blue-1") && $0.contains("Color") } != nil)
        check(
            "asked of its group's path",
            fake.requests.contains { $0.path == "/apis/example.com/v1/namespaces/shop/widgets" && $0.query["includeObject"] == "None" })
        _ = page.press(":")
        page.command?.text = "nope"
        page.runCommand()
        check("a kind nobody serves is said, the bar left open", page.command?.problem == "fake-dev serves no kind called nope.", page.command?.problem ?? "")
        page.closeCommand()

        // The digits: Network's first kind, Cluster's cluster-scoped nodes.
        check("2 is Network", page.press("2") && model.kind.fullName == "services" && page.section == .network)
        check("its services", await eventually(10) { model.rows.sorted.map(\.id.name) == ["web"] }, "\(model.rows.sorted.map(\.id.name))")
        check("6 is Cluster", page.press("6") && model.kind.fullName == "nodes")
        check(
            "the nodes, cluster-wide", await eventually(10) { model.rows.sorted.map(\.id.description) == ["fake-node-1"] },
            "\(model.rows.sorted.map(\.id.description))")
        check("asked for without a namespace", fake.requests.contains { $0.path == "/api/v1/nodes" })
        _ = page.press(":")
        page.command?.text = "secrets"
        page.runCommand()
        check(
            "a secret's row is its type and how many keys",
            await eventually(10) { model.rows.count == 1 }
                && model.rows[KubeRowID(namespace: "shop", name: "web-tls")]?.cell("Data", in: model.rows.columns) == .integer(2))
        check("never its values", !String(describing: model.rows).contains("fake-key") && !fake.requests.contains { $0.path.contains("/secrets/") })

        // A CRD applied while the page shows: there without a reconnect.
        fake.addCRD(group: "acme.example.com", version: "v1alpha1", plural: "gadgets", kind: "Gadget", namespaced: false, shortNames: ["gd"])
        fake.add("gadgets.acme.example.com", "gadget-1")
        check(
            "a CRD added appears, by the CRD watch",
            await eventually(10) { model.catalog.kinds(in: .custom).map(\.fullName) == ["gadgets.acme.example.com", "widgets.example.com"] },
            "\(model.catalog.kinds(in: .custom).map(\.fullName))")
        _ = page.press(":")
        page.command?.text = "gd"
        page.runCommand()
        check("and lists", await eventually(10) { model.kind.fullName == "gadgets.acme.example.com" && model.rows.sorted.map(\.id.name) == ["gadget-1"] })

        // Back to the pods.
        _ = page.press(":")
        page.command?.text = "po"
        page.runCommand()
        check(":po is the pods again", model.kind.fullName == "pods" && page.section == .workloads)
        check("listed", await eventually(10) { model.rows.count == 2 && model.listState == .live }, "\(model.rows.count)")
        check("by GETs only", fake.writes.isEmpty, "\(fake.writes)")
    }

    /// ⌃⌘J from the terminal, the page hidden: it reads as the page would,
    /// finds a context, a namespace and a pod, and ↩ shows the pod on the page.
    private func kubernetesSwitcher(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        app.showKubernetesSwitcher(nil)
        check("⌃⌘J opens the palette on Kubernetes", app.paletteView?.isHidden == false && app.palette.scope == .kubernetes)
        check("and holds the model while it shows", app.kubernetesSwitcherHeld && model.isShown)
        app.palette.query = "worker"
        check(
            "it finds a pod the hidden page's label: would leave out", await eventually(10) { self.app.palette.results.first?.id == "k.p.shop/worker-5c" },
            "\(app.palette.results.prefix(3).map(\.id))")
        check("saying why it fails", app.palette.results.first?.subtitle?.contains("CrashLoopBackOff") == true, app.palette.results.first?.subtitle ?? "")
        app.palette.query = "fake-prod"
        check("a context", app.palette.results.first?.id == "k.c.fake-prod", "\(app.palette.results.prefix(3).map(\.id))")
        app.palette.query = "payments"
        check("a namespace", app.palette.results.contains { $0.id == "k.n.payments" }, "\(app.palette.results.prefix(3).map(\.id))")
        app.palette.query = "worker"
        guard let worker = app.palette.results.first(where: { $0.id == "k.p.shop/worker-5c" }) else { return }
        // As the palette's ↩ does: closed, then performed.
        app.hidePalette()
        worker.perform(true, [:])
        check("↩ shows the page", app.store.showingOverlay == .kubernetes)
        check(
            "with the pod selected, the label: that could hide it cleared",
            await eventually(10) { page.selection == ["shop/worker-5c"] && page.rows.contains { $0.id == "shop/worker-5c" } } && page.filter.isEmpty,
            "\(page.selection) \(page.filter)")
        check("and the list has the keyboard", await eventually(3) { self.app.kubernetesListHasKeyboard() })
        check("the switcher lets go once the page holds", await eventually(3) { !self.app.kubernetesSwitcherHeld } && model.isShown)
        check(
            "⌃⌘J again closes it",
            { () -> Bool in
                self.app.showKubernetesSwitcher(nil)
                self.app.showKubernetesSwitcher(nil)
                return self.app.paletteView?.isHidden == true
            }())
        check("and lets go", await eventually(3) { !self.app.kubernetesSwitcherHeld })
        app.toggleKubernetesPage(nil)
        check("the page hidden again, nobody looks", await eventually(5) { !model.isShown && fake.openWatches == 0 }, "\(fake.openWatches) open")
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
