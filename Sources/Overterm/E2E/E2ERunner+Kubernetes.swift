import AppKit
import Darwin
import OSLog
import SwiftUI

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
        fake.add(
            "deployments.apps", "web", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1, "Images": "nginx:1.27"],
            fields: [
                "metadata": ["generation": 2],
                "spec": [
                    "replicas": 1, "selector": ["matchLabels": ["app": "web"]],
                    "strategy": ["type": "RollingUpdate", "rollingUpdate": ["maxSurge": "25%", "maxUnavailable": "25%"]],
                ],
                "status": [
                    "observedGeneration": 2, "replicas": 1, "updatedReplicas": 1, "readyReplicas": 1, "availableReplicas": 1,
                    "conditions": [["type": "Available", "status": "True", "reason": "MinimumReplicasAvailable"]],
                ],
            ])
        fake.add(
            "deployments.apps", "worker", namespace: "shop", values: ["Ready": "0/1", "Up-to-date": 1, "Available": 0],
            fields: [
                "metadata": ["generation": 1],
                "spec": ["replicas": 1, "selector": ["matchLabels": ["app": "worker"]]],
                "status": [
                    "observedGeneration": 1, "replicas": 1, "updatedReplicas": 1, "unavailableReplicas": 1,
                    "conditions": [["type": "Progressing", "status": "False", "reason": "ProgressDeadlineExceeded"]],
                ],
            ])
        fake.add(
            "replicasets.apps", "web-7d9f", namespace: "shop",
            fields: [
                "metadata": ["ownerReferences": [["apiVersion": "apps/v1", "kind": "Deployment", "name": "web", "controller": true]]],
                "spec": ["replicas": 1, "selector": ["matchLabels": ["app": "web"]]], "status": ["replicas": 1, "readyReplicas": 1, "availableReplicas": 1],
            ])
        fake.setFields(
            "pods", "web-7d9", namespace: "shop",
            [
                "metadata": [
                    "ownerReferences": [["apiVersion": "apps/v1", "kind": "ReplicaSet", "name": "web-7d9f", "controller": true]],
                    "annotations": [KubeObjectStrip.lastApplied: "{\"kind\":\"Pod\"}"],
                ]
            ])
        fake.addEvent(about: "pods", "web-7d9", namespace: "shop", reason: "Scheduled", message: "Assigned shop/web-7d9 to fake-node-1", last: Date().addingTimeInterval(-900))
        fake.addEvent(about: "pods", "web-7d9", namespace: "shop", type: "Warning", reason: "Unhealthy", message: "Readiness probe failed: connection refused", count: 4)
        fake.add(
            "services", "web", namespace: "shop", values: ["Type": "ClusterIP", "Cluster-IP": "10.96.0.12", "External-IP": "<none>", "Port(s)": "80/TCP"])
        fake.add("configmaps", "web-config", namespace: "shop", data: ["nginx.conf": "worker_processes 1;"])
        fake.add(
            "secrets", "web-tls", namespace: "shop", values: ["Type": "kubernetes.io/tls"],
            data: ["tls.crt": FakeKubeAPI.testCertificatePEM, "tls.key": "fake-key"])
        fake.add(
            "secrets", "web-db", namespace: "shop", values: ["Type": "Opaque"],
            annotations: [KubeObjectStrip.lastApplied: "{\"data\":{\"password\":\"\(Self.secretValueBase64)\"}}"],
            data: ["password": Self.secretValue, "username": "web"])
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
        // Either way kubernetes.kubectlPath is a stand-in script of the
        // run's own: it answers `auth can-i` itself (attach refused) and
        // records what it was given, and hands the rest — `proxy` — to the
        // real kubectl.
        let kubectl = ["/usr/local/bin/kubectl", "/opt/homebrew/bin/kubectl"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let standIn = Self.writeStandInKubectl(in: scratch, real: kubectl) else {
            return check("the stand-in kubectl is written", false)
        }
        Settings.shared.set("kubernetes.kubectlPath", .string(standIn.script.path))
        if let kubectl {
            note("kubectl proxy: \(kubectl), through the stand-in, KUBECONFIG \(kubeconfig.path) only")
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
        check("and the page says so", await shownText(15) { $0.contains("Asked of the server: label app=web") } != nil)
        page.filter = ""
        page.applySelector()
        check("cleared, every pod again", await eventually(10) { model.rows.count == 2 }, "\(model.rows.count)")
        await kubernetesFieldSelector(model, page, fake)
        let filterFocus = page.focusFilter
        check("/ goes to the filter", page.press("/") && page.focusFilter == filterFocus + 1)
        page.giveListTheKeyboard()
        _ = page.press("?")
        check("? shows the keys", page.cheatSheet)
        _ = page.press("x")
        check("any key closes them", !page.cheatSheet)
        await namespaceAndContextPickers(model, page)
        await kubernetesKinds(model, page, fake)
        await kubernetesDetail(model, page, fake)

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
        check(
            "nor reached by any subresource but a pod's log", fake.subresourceRequests.allSatisfy { $0.isLog && $0.method == "GET" },
            "\(fake.subresourceRequests.filter { !$0.isLog })")

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
        await kubernetesTerminal(model, page, kubeconfig: kubeconfig)
        await kubernetesPodCommands(model, page, fake, kubeconfig: kubeconfig, canI: standIn.log)
        await kubernetesAskWhy(model, page, fake)
        let forwarding = await kubernetesForwards(model, page, fake, kubeconfig: kubeconfig, canI: standIn.log, forwards: standIn.forwards)

        // Off: the page says so, and no proxy is left.
        Settings.shared.set("kubernetes.enabled", .bool(false))
        app.toggleKubernetesPage(nil)
        check("with Kubernetes off the page says so", !model.enabled && model.rows.count == 0)
        check(
            "and every forward is stopped, its kubectl ended",
            await eventually(5) { KubeForwards.shared.forwards.isEmpty && forwarding.allSatisfy { kill($0, 0) != 0 } }, "\(forwarding)")
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

    /// Terminal in this context (3.11): opened from the page's context card
    /// on fake-dev, in the namespace shown — a tab whose shell's KUBECONFIG
    /// starts with a file of the run's own (0600, the context and its
    /// namespace, no credential) and then OVERTERM_KUBECONFIG's file alone;
    /// the shell has it (printf, never kubectl); the tab and its pane say
    /// so. From the palette on fake-prod it is asked first, naming it, and
    /// its pane carries the red band. A row's menu offers it with the row's
    /// namespace (recorded). The scenario's kubeconfig — the user's current
    /// context, here — is never written.
    private func kubernetesTerminal(_ model: KubernetesModel, _ page: KubernetesPageModel, kubeconfig: URL) async {
        let before = try? Data(contentsOf: kubeconfig)
        let opened = app.store.tabs.map(\.id)
        app.toggleKubernetesPage(nil)
        check("the page again, on fake-dev in shop", await eventually(5) { model.selectedName == "fake-dev" && model.scope == .namespace("shop") })
        page.openTerminal()
        func newPinned(_ context: String) -> Tab? { app.store.tabs.first { !opened.contains($0.id) && $0.kubePin?.context == context } }
        _ = await eventually(10) { newPinned("fake-dev") != nil }
        let tab = newPinned("fake-dev")
        check("Terminal in This Context opens a tab", tab != nil, page.terminalProblem ?? "no problem said")
        guard let tab else { return }
        check("selected, the page stepped aside", app.store.selectedID == tab.id && app.store.showingOverlay == nil)
        check("pinned to fake-dev in shop", tab.kubePin?.context == "fake-dev" && tab.kubePin?.namespace == "shop", "\(String(describing: tab.kubePin))")
        check("a Kubernetes tab", tab.kind == .kubernetes)
        check("in the home folder (no terminalDirectory)", tab.terminal.workingDirectory == FileManager.default.homeDirectoryForCurrentUser.path)
        let value = tab.terminal.environment["KUBECONFIG"] ?? ""
        let parts = value.split(separator: ":").map(String.init)
        let folder = AppEnvironment.supportDirectory.appendingPathComponent("Kubernetes/Contexts").path
        check("its KUBECONFIG is the pin's file, then the run's kubeconfig alone", parts.count == 2 && parts.last == kubeconfig.path, value)
        check("the pin's file is in the run's own support folder", parts.first?.hasPrefix(folder + "/") == true, value)
        check("and nothing else is given the shell", tab.terminal.environment.keys.sorted() == ["KUBECONFIG"], "\(tab.terminal.environment.keys)")
        if let first = parts.first {
            let text = (try? String(contentsOfFile: first, encoding: .utf8)) ?? ""
            check("which names the context", text.contains("current-context: \"fake-dev\""), text)
            check("and its namespace", text.contains("namespace: \"shop\""), text)
            check("and no credential or server", !text.contains("token") && !text.contains("server") && !text.contains("users:"), text)
            var info = stat()
            check("0600", lstat(first, &info) == 0 && info.st_mode & 0o777 == 0o600, String(info.st_mode & 0o777, radix: 8))
            check("its folder 0700", lstat(folder, &info) == 0 && info.st_mode & 0o777 == 0o700, String(info.st_mode & 0o777, radix: 8))
        }
        // The shell has it: printed into a file, never a kubectl run.
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ot-e2e-kubeconfig-\(UUID().uuidString.prefix(6))")
        await runAndExpect("printf '%s' \"$KUBECONFIG\" > \(out.path)", file: out, content: value, "the tab's shell has that KUBECONFIG")
        try? FileManager.default.removeItem(at: out)
        check("the pane's header says the context", await shownText(15) { $0.contains("fake-dev") && $0.contains("shop") } != nil)
        let devLabel = await stripLabel("fake-dev")
        check("its tab in the strip says ⎈ fake-dev, not in red", devLabel.found && !devLabel.red, "\(devLabel)")
        check("and its pane, not production, carries no band", productionBands() == [false], "\(productionBands())")

        // A split of it is pinned the same.
        app.split(tab.terminal, .right)
        check(
            "a split of it is pinned too", tab.terminals.count == 2 && tab.terminals.allSatisfy { $0.environment["KUBECONFIG"] == value && $0.kubePin != nil })

        // A use-context typed in the tab rewrites the pin's file (3.11) — written
        // here as kubectl writes it, never a kubectl run: the label and the band follow.
        if let first = parts.first {
            let before = (try? Data(contentsOf: URL(fileURLWithPath: first))) ?? Data()
            try? Data("apiVersion: v1\nkind: Config\ncurrent-context: fake-prod\ncontexts:\n- context:\n    cluster: fake-dev\n    namespace: shop\n    user: dev\n  name: fake-dev\n".utf8)
                .write(to: URL(fileURLWithPath: first))
            check(
                "a use-context in the tab: both panes say fake-prod now, production",
                await eventually(10) { tab.terminals.allSatisfy { $0.kubePin?.context == "fake-prod" && $0.kubePin?.isProduction == true } },
                "\(tab.terminals.map { String(describing: $0.kubePin) })")
            check("the band follows, under both panes", await eventually(5) { self.productionBands() == [true, true] }, "\(productionBands())")
            let followed = await stripLabel("fake-prod")
            check("and the strip's label, in red", followed.found && followed.red, "\(followed)")
            try? before.write(to: URL(fileURLWithPath: first))
            check(
                "and back to fake-dev in shop, the band gone",
                await eventually(10) {
                    tab.terminals.allSatisfy { $0.kubePin?.context == "fake-dev" && $0.kubePin?.namespace == "shop" }
                        && self.productionBands() == [false, false]
                })
        }

        // A row's menu: the row's namespace (recorded, not opened).
        let actions = page.actions
        var asked: [(String, String?)] = []
        page.actions?.openTerminal = { context, namespace in asked.append((context.name, namespace)) }
        let verb = page.verbs(for: ["shop/web-7d9"]).first { $0.title == "Terminal in This Context" }
        verb?.perform()
        check("a row's menu offers it, in the row's namespace", asked.count == 1 && asked.first?.0 == "fake-dev" && asked.first?.1 == "shop", "\(asked)")
        page.actions = actions

        // fake-prod, from the palette: asked first, naming it.
        let item = app.kubernetesPaletteItems().first { $0.id == "k.t.fake-prod" }
        check("the palette offers Terminal in fake-prod", item?.title == "Terminal in fake-prod")
        let count = app.store.tabs.count
        item?.perform(true, [:])
        check("on production it is asked first", await eventually(5) { self.window.attachedSheet != nil })
        check("naming the context", sheetTexts().contains { $0.contains("fake-prod") }, "\(sheetTexts())")
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        _ = await eventually(2) { self.window.attachedSheet == nil }
        await pause(0.5)
        check("Cancel opens nothing", app.store.tabs.count == count)
        item?.perform(true, [:])
        check("asked again", await eventually(5) { self.window.attachedSheet != nil })
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        _ = await eventually(10) { newPinned("fake-prod") != nil }
        let prod = newPinned("fake-prod")
        check("confirmed, a tab pinned to fake-prod", prod?.kubePin?.isProduction == true, page.terminalProblem ?? "")
        check("its namespace is the context's own (payments)", prod?.kubePin?.namespace == "payments", "\(String(describing: prod?.kubePin))")
        check("its pane says PRODUCTION", await shownText(15) { $0.contains("PRODUCTION") && $0.contains("fake-prod") } != nil)
        check("and carries the red band", await eventually(5) { self.productionBands() == [true] }, "\(productionBands())")
        let prodLabel = await stripLabel("fake-prod")
        check("its tab the red ⎈ fake-prod", prodLabel.found && prodLabel.red, "\(prodLabel)")
        check("the strip's label is in the page's red", prod?.kubeBadge?.alert == true)

        // View ▸ Terminal in Kubernetes Context…: the switcher, on its Terminal in items only.
        if let item = menuItem("View", "Terminal in Kubernetes Context…"), let action = item.action {
            NSApp.sendAction(action, to: nil, from: item)
        } else {
            check("View ▸ Terminal in Kubernetes Context…", false)
        }
        check("View ▸ Terminal in Kubernetes Context… opens the switcher", app.paletteView?.isHidden == false && app.palette.scope == .kubernetes)
        check(
            "listing only its Terminal in items",
            await eventually(5) {
                self.app.palette.query == "Terminal in " && !self.app.palette.results.isEmpty
                    && self.app.palette.results.allSatisfy { $0.id.hasPrefix("k.t.") }
            }, "\(app.palette.query) \(app.palette.results.prefix(6).map(\.id))")
        check("each context's", Set(app.palette.results.map(\.id)).isSuperset(of: ["k.t.fake-dev", "k.t.fake-prod"]))
        app.hidePalette()

        // A context card's right-click (the menu's own item, recorded).
        let recorded = page.actions
        var cards: [(String, String?)] = []
        page.actions?.openTerminal = { context, namespace in cards.append((context.name, namespace)) }
        if let dev = model.contexts.context(named: "fake-dev"), let other = model.contexts.context(named: "fake-prod") {
            page.openTerminal(in: dev)
            page.openTerminal(in: other)
        }
        check(
            "a context card's menu: the namespace shown for the context shown, another's own",
            cards.count == 2 && cards[0] == ("fake-dev", "shop") && cards[1].0 == "fake-prod" && cards[1].1 == nil, "\(cards)")
        page.actions = recorded

        check("the kubeconfig — its current context — is never written", (try? Data(contentsOf: kubeconfig)) == before)
        let made = app.store.tabs.filter { !opened.contains($0.id) }
        app.closeTabsWithoutAsking(made)
        await kubernetesTerminalRestored(page, kubeconfig: kubeconfig)
    }

    /// A saved session's pinned tabs at launch: looked up again in the
    /// run's kubeconfig as it is now — a fake-prod saved as not production,
    /// from a file gone, comes back production on the run's file; one
    /// whose context is gone comes back marked lost with a KUBECONFIG that
    /// reaches nothing, never as a plain shell to the current context.
    private func kubernetesTerminalRestored(_ page: KubernetesPageModel, kubeconfig: URL) async {
        guard app.store.groups.isEmpty else { return check("a window without islands, to restore into", false) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let gone = KubeTerminalPin(
            context: "acme-gone", cluster: "acme", user: "acme", namespace: nil, displayName: "acme-gone", isProduction: false,
            kubeconfigs: [kubeconfig.path])
        let stale = KubeTerminalPin(
            context: "fake-prod", cluster: "old", user: "old", namespace: "payments", displayName: "fake-prod", isProduction: false,
            kubeconfigs: ["/nowhere/old.yaml"])
        let opened = Set(app.store.tabs.map(\.id))
        app.restore(
            SessionState(
                tabs: [
                    .init(workingDirectory: home, customTitle: nil, color: nil, isPinned: false, agent: nil, kubeContext: gone),
                    .init(workingDirectory: home, customTitle: nil, color: nil, isPinned: false, agent: nil, kubeContext: stale),
                ], selectedIndex: nil))
        let made = app.store.tabs.filter { !opened.contains($0.id) }
        guard made.count == 2 else { return check("two tabs restored", false, "\(made.count)") }
        let lost = made[0]
        let prod = made[1]
        check("a pin whose context is gone comes back lost", lost.terminal.kubePinLost?.pin == gone && lost.terminal.kubePin == nil)
        check("its shell's KUBECONFIG reaches nothing", lost.terminal.environment == ["KUBECONFIG": "/dev/null"], "\(lost.terminal.environment)")
        check("its tab says the pin is lost, in red", lost.kubeBadge?.text == "⎈ pin lost" && lost.kubeBadge?.alert == true && lost.kind == .kubernetes)
        check("and the page says why", page.terminalProblem?.contains("acme-gone") == true, page.terminalProblem ?? "nil")
        check("saved again as it was", TerminalWindowController.savedKubePin(lost.terminal) == gone)
        app.store.select(lost)
        check("its header says so", await shownText(15) { $0.contains("pin lost") && $0.contains("acme-gone") } != nil)
        check("no band: it reaches nothing", productionBands() == [false], "\(productionBands())")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ot-e2e-kubeconfig-\(UUID().uuidString.prefix(6))")
        await runAndExpect("printf '%s' \"$KUBECONFIG\" > \(out.path)", file: out, content: "/dev/null", "the lost pane's shell has /dev/null")
        try? FileManager.default.removeItem(at: out)

        check("a pin saved as not production comes back production, as fake-prod is now", prod.kubePin?.isProduction == true && prod.kubePin?.namespace == "payments")
        let value = prod.terminal.environment["KUBECONFIG"] ?? ""
        check(
            "its KUBECONFIG the run's file now, not the saved one", value.hasSuffix(":" + kubeconfig.path) && !value.contains("/nowhere"), value)
        check("its cluster and user the kubeconfig's now", prod.kubePin?.cluster == "fake-prod" && prod.kubePin?.user != "old")
        app.store.select(prod)
        check("its band shows", await eventually(5) { self.productionBands() == [true] }, "\(productionBands())")
        app.closeTabsWithoutAsking(made)
        page.terminalProblem = nil
    }

    /// A stand-in kubectl in `folder`: `auth can-i` answered here — yes,
    /// but no for `pods/attach` — each line of what it was given (its
    /// KUBECONFIG, its arguments) appended to `log`; `port-forward` played
    /// here too (`writeStandInForward`, logged to `forwards`); anything
    /// else handed to `real` with `exec` (the proxy keeps its pid), or
    /// refused when there is none.
    static func writeStandInKubectl(in folder: URL, real: String?) -> (script: URL, log: URL, forwards: URL)? {
        let script = folder.appendingPathComponent("stand-in-bin/kubectl")
        let log = folder.appendingPathComponent("stand-in-kubectl.log")
        let forwards = folder.appendingPathComponent("stand-in-forwards.log")
        guard let forward = writeStandInForward(in: script.deletingLastPathComponent(), log: forwards) else { return nil }
        let text = """
            #!/bin/sh
            if [ "$1" = auth ] && [ "$2" = can-i ]; then
              printf '%s|%s\\n' "$KUBECONFIG" "$*" >> '\(log.path)'
              case "$4" in pods/attach) echo no; exit 1;; *) echo yes; exit 0;; esac
            fi
            if [ "$1" = port-forward ]; then exec '\(forward.path)' "$@"; fi
            \(real.map { "exec '\($0)' \"$@\"" } ?? "echo 'no kubectl here' >&2; exit 1")

            """
        do {
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            return nil
        }
        return (script, log, forwards)
    }

    /// A stand-in `kubectl port-forward pod/P L:R … --address A` in `folder`
    /// (the fake API has no port-forward): it appends its KUBECONFIG and
    /// arguments to `log`, listens on A:L, says `Forwarding from A:L -> R`
    /// as kubectl does, answers every connection with the pod's name, and
    /// runs until it is ended — by its pid (it `exec`s perl, so the pid
    /// Overterm holds is the listener's). A port it can't listen on is
    /// kubectl's error, and an exit.
    static func writeStandInForward(in folder: URL, log: URL) -> URL? {
        let script = folder.appendingPathComponent("port-forward")
        let listener = folder.appendingPathComponent("port-forward.pl")
        let perl = #"""
            use strict;
            use IO::Socket::INET;
            $| = 1;
            my ($address, $local, $pod, $remote) = @ARGV;
            my $server = IO::Socket::INET->new(LocalAddr => $address, LocalPort => $local, Listen => 8, ReuseAddr => 1, Proto => "tcp");
            unless ($server) { print STDERR "error: unable to listen on port $local: $!\n"; exit 1; }
            print "Forwarding from $address:$local -> $remote\n";
            while (my $client = $server->accept) {
                # The request read first: a reply to one unread is reset, which a browser shows as nothing.
                eval { local $SIG{ALRM} = sub { die "slow\n" }; alarm 2; while (my $line = <$client>) { last if $line =~ /^\r?\n$/; } alarm 0; };
                print $client "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n$pod\n";
                close $client;
            }

            """#
        let text = """
            #!/bin/sh
            printf '%s|%s\\n' "$KUBECONFIG" "$*" >> '\(log.path)'
            pod="${2#pod/}"
            ports="$3"
            address=127.0.0.1
            previous=""
            for word in "$@"; do
              [ "$previous" = --address ] && address="$word"
              previous="$word"
            done
            exec /usr/bin/perl '\(listener.path)' "$address" "${ports%%:*}" "$pod" "${ports#*:}"

            """
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try perl.write(to: listener, atomically: true, encoding: .utf8)
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            return nil
        }
        return script
    }

    /// Port-forwards (stage 1d; Section 11's bar): `f` on fake-dev's
    /// Service `web` — read-only, allowed after `kubectl auth can-i create
    /// pods/portforward` — resolved by Overterm to its ready endpoint's pod
    /// and run through the stand-in kubectl (`port-forward pod/web-7d9
    /// L:8080`, `--context`, `--namespace`, `--address 127.0.0.1`, the run's
    /// kubeconfig alone), which answers on L with its pod's name. The fake
    /// then replaces the pod (the old one deleted, a new one ready behind
    /// the Service) and the stand-in is ended by its pid, as kubectl ends
    /// when its pod goes: Overterm resolves again and starts a second
    /// stand-in for the new pod, which the pill, the Forwards section and
    /// Tab Info name. `o` opens it, Edit moves its local port, kubectl
    /// exiting starts it again on the same pod, and with the Service gone it
    /// stops and says so. A Quick Forward of a pod is opened once it
    /// forwards. Nothing of it reaches the API but GETs. Returns the pids
    /// still forwarding, for the Kubernetes-off check.
    private func kubernetesForwards(
        _ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, kubeconfig: URL, canI: URL, forwards log: URL
    ) async -> [pid_t] {
        let forwards = KubeForwards.shared
        forwards.podCheckInterval = .milliseconds(400)
        defer { forwards.podCheckInterval = .seconds(5) }
        try? FileManager.default.removeItem(at: log)
        func launched() -> [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        func canIs() -> [String] { ((try? String(contentsOf: canI, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        var opened: [URL] = []
        let actions = page.actions
        page.actions?.openURL = { opened.append($0) }
        defer { page.actions = actions }

        // The Service, its pods and its endpoints: the fake has no controller, the scenario plays it.
        fake.updatePod("web-7d9", namespace: "shop") {
            $0.status = "Running"
            $0.ready = 1
            $0.ports = [FakeKubeAPI.ContainerPort(8080, name: "http")]
        }
        fake.setFields(
            "services", "web", namespace: "shop",
            ["spec": ["selector": ["app": "web"], "ports": [["name": "http", "port": 80, "targetPort": "http", "protocol": "TCP"]]]])
        func slice(_ ready: String) -> [String: Any] {
            [
                "addressType": "IPv4", "ports": [["name": "http", "port": 8080, "protocol": "TCP"]],
                "endpoints": [
                    ["addresses": ["10.0.0.10"], "conditions": ["ready": true], "targetRef": ["kind": "Pod", "name": ready, "namespace": "shop"]],
                    ["addresses": ["10.0.0.11"], "conditions": ["ready": false], "targetRef": ["kind": "Pod", "name": "worker-5c", "namespace": "shop"]],
                ],
            ]
        }
        fake.add("endpointslices.discovery.k8s.io", "web-x7k2p", namespace: "shop", labels: ["kubernetes.io/service-name": "web"], fields: slice("web-7d9"))

        if app.store.showingOverlay != .kubernetes { app.showKubernetesPage() }
        model.select("fake-dev")
        model.setScope(.namespace("shop"))
        page.filter = ""
        page.applySelector()
        guard let services = model.catalog.kind(fullName: "services") else {
            check("fake-dev serves services", false)
            return []
        }
        page.showKind(services)
        check("the Services list", await eventually(10) { page.rows.contains { $0.id == "shop/web" } }, "\(page.rows.map(\.id))")
        page.selection = ["shop/web"]
        func verb(_ title: String, _ id: String = "shop/web") -> ResourceVerb? { page.verbs(for: [id]).first { $0.title == title } }
        check(
            "Port-forward… on a read-only context's Service, once kubectl auth can-i says yes",
            await eventually(15) { verb("Port-forward…") != nil && verb("Port-forward…")?.unavailable == nil },
            verb("Port-forward…")?.unavailable ?? "no verb")
        check(
            "can-i asked create pods/portforward with --context and -n",
            canIs().contains { $0.hasPrefix(kubeconfig.path + "|auth can-i create pods/portforward --context fake-dev -n shop") }, "\(canIs())")
        let tab = app.store.selected

        // f: the sheet, the Service's port, a free local one.
        check("f opens the forward sheet", page.press("f") && page.forwardDraft?.target == .service("web"))
        check(
            "with the Service's port and a free local one",
            await eventually(10) { page.forwardDraft?.remote == "80" && Int(page.forwardDraft?.local ?? "") != nil && page.forwardDraft?.unavailable == nil },
            "\(String(describing: page.forwardDraft))")
        check("127.0.0.1 unless changed", page.forwardDraft?.address == "127.0.0.1")
        check("drawn", await shownText(15) { $0.contains("Port-forward svc/web") } != nil)
        let local = Int(page.forwardDraft?.local ?? "") ?? 0
        guard let id = page.confirmForward() else {
            check("Forward starts it", false, page.forwardProblem ?? "")
            return []
        }
        check("the sheet goes", page.forwardDraft == nil)
        check(
            "resolved to the ready endpoint's pod, and forwarding",
            await eventually(15) { forwards.forward(id)?.isForwarding == true && forwards.forward(id)?.pod == "web-7d9" },
            forwards.forward(id)?.state.text ?? "gone")
        check("to the pod's port the Service's targetPort names", forwards.forward(id)?.podPort == 8080)
        let line = "port-forward pod/web-7d9 \(local):8080 --context fake-dev --namespace shop --address 127.0.0.1"
        check(
            "kubectl port-forward pod/web-7d9, --context, --namespace, --address, the run's kubeconfig alone",
            launched().count == 1 && launched().first?.hasPrefix(kubeconfig.path + "|" + line) == true, "\(launched())")
        check("it answers on the local port", await answer(local) == "web-7d9")
        let first = forwards.forward(id)?.pid ?? 0
        check("its pill in the tab it was asked from", await eventually(5) { tab?.forwardPorts.first?.forward?.pod == "web-7d9" }, "\(tab?.forwardPorts ?? [])")
        check("not a port of the tab's own processes", tab?.ports.contains { $0.port == local } != true)

        // The pod replaced: deleted, a new one ready behind the Service; the
        // stand-in ended by its pid, as kubectl ends when its pod goes.
        fake.deletePod("web-7d9", namespace: "shop")
        fake.addPod("web-8k2", namespace: "shop", FakeKubeAPI.Pod(ports: [FakeKubeAPI.ContainerPort(8080, name: "http")]), labels: ["app": "web"])
        fake.setFields("endpointslices.discovery.k8s.io", "web-x7k2p", namespace: "shop", slice("web-8k2"))
        if first > 0 { kill(first, SIGTERM) }
        check(
            "it starts again on the new pod",
            await eventually(20) { forwards.forward(id)?.isForwarding == true && forwards.forward(id)?.pod == "web-8k2" },
            forwards.forward(id)?.state.text ?? "gone")
        let second = forwards.forward(id)?.pid ?? 0
        check("a second kubectl, the first ended", second != first && second > 0 && kill(first, 0) != 0, "\(first) \(second)")
        check(
            "port-forward pod/web-8k2 on the same local port",
            launched().count == 2 && launched().last?.contains("port-forward pod/web-8k2 \(local):8080 --context fake-dev --namespace shop") == true,
            "\(launched())")
        check("the new pod answers", await answer(local) == "web-8k2")
        check("said as started again", forwards.forward(id)?.restarts == 1)
        check("the pill names the new pod", await eventually(5) { tab?.forwardPorts.first?.forward?.pod == "web-8k2" }, "\(tab?.forwardPorts ?? [])")
        app.toggleKubernetesPage(nil)
        check("drawn in the tab's pane header", await shownText(15) { $0.contains(":\(local)") && $0.contains("web-8k2") } != nil)
        app.showKubernetesPage()
        if let tab {
            let info = TabInfoModel(tab: tab, inspector: ProcessInspector(), claudeReader: ClaudeUsageReader())
            await info.refreshPorts()
            check("Tab Info lists it", info.ports.contains { $0.port == local && $0.forward?.pod == "web-8k2" }, "\(info.ports)")
            // Closing the tab asks, even when Settings says only when something runs.
            check(
                "closing its tab asks for its forward alone",
                TerminalWindowController.runningForwards(of: [tab], in: forwards.forwards, quitting: false).map(\.id) == [id]
                    && TerminalWindowController.needsCloseConfirmation([tab], confirmClose: .whenRunning))
            check(
                "and says it keeps running, on the page",
                TerminalWindowController.closeWarning(for: [tab]).contains("(127.0.0.1:\(local) → svc/web) keeps running"),
                TerminalWindowController.closeWarning(for: [tab]))
            check(
                "quitting says it stops it",
                TerminalWindowController.closeWarning(for: [tab], quitting: true).contains("Quitting stops the port-forward (127.0.0.1:\(local) → svc/web)"),
                TerminalWindowController.closeWarning(for: [tab], quitting: true))
        }

        // The palette: each forward, with its pod; ↩ opens it.
        let paletteItems = app.kubernetesPaletteItems()
        let forwardItem = paletteItems.first { $0.id == "k.f.\(id)" }
        check(
            "the palette lists the forward with its pod",
            forwardItem?.title == "Forward 127.0.0.1:\(local) → svc/web" && forwardItem?.subtitle?.contains("pod web-8k2") == true,
            "\(forwardItem?.title ?? "none") \(forwardItem?.subtitle ?? "")")
        check("and Kubernetes Forwards", paletteItems.contains { $0.id == "a.kubernetes.forwards" })
        check("its Stop", paletteItems.contains { $0.id == "k.fs.\(id)" && $0.title == "Stop Forward 127.0.0.1:\(local) → svc/web" })
        check("and New Port-forward…", paletteItems.contains { $0.id == "a.kubernetes.forward.new" })
        app.showPalette(nil)
        app.palette.query = "stop forward"
        check(
            "⌘K finds the forward's Stop", await eventually(5) { self.app.palette.results.contains { $0.id == "k.fs.\(id)" } },
            "\(app.palette.results.prefix(4).map(\.id))")
        app.hidePalette()
        await pause(0.3)
        opened = []
        forwardItem?.perform(true, [:])
        check("↩ opens its URL", opened.last?.absoluteString == "http://127.0.0.1:\(local)", "\(opened)")
        if app.store.showingOverlay != .kubernetes { app.showKubernetesPage() }

        // The Forwards section: 9.
        page.giveListTheKeyboard()
        check("9 is Forwards", page.press("9") && page.section == .forwards && !page.showsSection)
        check("it lists the forward with its pod", await shownText(15) { $0.contains("pod web-8k2") } != nil)
        check("o opens it", page.press("o") && opened.last?.absoluteString == "http://127.0.0.1:\(local)", "\(opened)")
        await kubernetesForwardInBrowser(page, local: local, pod: "web-8k2", open: actions?.openURL)

        // Edit: another local port, kubectl started again with it.
        page.editForward(id)
        let moved = page.freeLocalPort(preferring: nil) ?? 0
        page.forwardDraft?.local = "\(moved)"
        check("Edit saves", page.confirmForward() == id)
        check(
            "and forwards on the new local port", await eventually(15) { forwards.forward(id)?.isForwarding == true && forwards.forward(id)?.spec.localPort == moved },
            forwards.forward(id)?.state.text ?? "gone")
        check("which answers", await answer(moved) == "web-8k2")
        check("the old one no longer listens", await eventually(5) { !ListeningPorts.isBound(local) })

        // kubectl exits with the pod still there: started again on it.
        let third = forwards.forward(id)?.pid ?? 0
        if third > 0 { kill(third, SIGTERM) }
        check(
            "kubectl exiting starts it again, on the same pod",
            await eventually(20) {
                forwards.forward(id)?.isForwarding == true && forwards.forward(id)?.pid != third && forwards.forward(id)?.pod == "web-8k2"
            }, forwards.forward(id)?.state.text ?? "gone")

        // The Service gone: resolved again, it stops, and says so.
        fake.delete("services", "web", namespace: "shop")
        let fourth = forwards.forward(id)?.pid ?? 0
        if fourth > 0 { kill(fourth, SIGTERM) }
        check("with its Service gone it stops", await eventually(20) { forwards.forward(id)?.state == .stopped("svc/web is gone") }, forwards.forward(id)?.state.text ?? "")
        check("and says so", await shownText(15) { $0.contains("svc/web is gone") } != nil)
        check("its pill goes", await eventually(5) { tab?.forwardPorts.isEmpty == true })
        page.stopForward(id)
        check("Remove takes it off the list", forwards.forward(id) == nil)

        // Quick Forward on a pod: a random port, opened once it forwards.
        model.setKind(.pods)
        page.showKind(.pods)
        check("back on the pods", await eventually(10) { page.rows.contains { $0.id == "shop/web-8k2" } }, "\(page.rows.map(\.id))")
        // A container port in the pod's Overview: a button that opens the
        // sheet on the pod, that port picked.
        if let ref = page.ref(for: "shop/web-8k2") {
            page.open(ref, from: .list)
            let ports = { page.detail?.overview?.section("Containers")?.items.first?.ports.map(\.port) }
            check("the Overview's container port is a forward's", await eventually(10) { ports() == [8080] }, "\(String(describing: ports()))")
            check("drawn as a button", await shownText(15) { $0.contains("8080 (http)") } != nil)
            page.portForward(ref, port: 8080)
            check(
                "it opens the sheet on the pod, the port picked",
                page.forwardDraft?.target == .pod("web-8k2") && page.forwardDraft?.remote == "8080", "\(String(describing: page.forwardDraft))")
            page.closeForwardSheet()
            page.closeDetail()
        } else {
            check("the pod's ref", false)
        }
        page.selection = ["shop/web-8k2"]
        _ = await eventually(10) { verb("Quick Forward", "shop/web-8k2")?.unavailable == nil }
        opened = []
        verb("Quick Forward", "shop/web-8k2")?.perform()
        check("Quick Forward opens it once it forwards", await eventually(20) { !opened.isEmpty }, forwards.forwards.first?.state.text ?? "none")
        let quick = forwards.forwards.first
        check(
            "a pod's own forward, on a random port", quick?.spec.target == .pod("web-8k2") && KubeForwardPortChoice.range.contains(quick?.spec.localPort ?? 0),
            "\(String(describing: quick?.spec))")
        if let quick { check("which answers", await answer(quick.spec.localPort) == "web-8k2") }
        check("nothing of it reached the API but GETs", fake.writes.isEmpty && !fake.requests.contains { $0.path.contains("portforward") })
        await kubernetesDatabaseAndIngress(model, page, fake, forwards: log)
        check("nor of d and o", fake.writes.isEmpty && !fake.requests.contains { $0.path.contains("portforward") })
        app.toggleKubernetesPage(nil)
        return forwards.forwards.compactMap(\.pid)
    }

    /// `o` on a forward, the window's own way (3.8; Section 2's dock: the
    /// right slot and terminal tabs): the page steps aside and the tab's
    /// browser column loads http://127.0.0.1:<port>, taking the right slot
    /// from the changes pane (`RightSlot`), never a column of its own;
    /// closed, it gives the slot back.
    private func kubernetesForwardInBrowser(_ page: KubernetesPageModel, local: Int, pod: String, open: ((URL) -> Void)?) async {
        guard let open, let tab = app.store.selected else { return check("the window's own Open", false) }
        let recording = page.actions?.openURL
        page.actions?.openURL = open
        defer { if let recording { page.actions?.openURL = recording } }
        if app.diffItem?.isCollapsed != false { app.toggleDiff(nil) }
        _ = await eventually(2) { self.app.diffItem?.isCollapsed == false }
        app.showKubernetesPage()
        page.giveListTheKeyboard()
        check("o, the window's own way", page.press("o"))
        check(
            "opens the browser column in the right slot, the changes pane giving way",
            await eventually(5) { self.app.browserItem?.isCollapsed == false && self.app.diffItem?.isCollapsed == true },
            "browser \(app.browserItem?.isCollapsed as Any), diff \(app.diffItem?.isCollapsed as Any)")
        check("the page steps aside for it", app.store.showingOverlay == nil)
        let session = app.browserWorkspaces[tab.id]?.active
        check(
            "at http://127.0.0.1:\(local), the forward's address",
            await eventually(10) { session?.url?.absoluteString.hasPrefix("http://127.0.0.1:\(local)") == true && session?.isLoading == false },
            session?.url?.absoluteString ?? "no page")
        var text = ""
        for _ in 0..<50 {
            if let webView = session?.webView, let body = (try? await webView.evaluateJavaScript("document.body.innerText")) as? String { text = body }
            if text.contains(pod) { break }
            await pause(0.2)
        }
        check("which the pod answers, through its forward", text.contains(pod), text)
        app.closeBrowser()
        check("closed, the slot goes back to the changes pane", await eventually(3) { self.app.diffItem?.isCollapsed == false && self.app.browserItem?.isCollapsed == true })
        app.toggleDiff(nil)
        app.showKubernetesPage()
    }

    /// `d` on a postgres-looking pod (3.8): a forward to its 5432 through
    /// the stand-in kubectl, after `kubectl auth can-i`; the password its
    /// env takes from Secret web-db read only once the user says so —
    /// asked, naming the Secret and key, one GET — and the Database
    /// client's form, over the page, filled in with 127.0.0.1 and the
    /// forward's local port, the user and database the env writes. Nothing
    /// is saved or connected: the form is put away, and connections.json
    /// never holds the value. A Redis pod says why not. An Ingress's `o`
    /// opens its host in the default browser — recorded, in this run.
    private func kubernetesDatabaseAndIngress(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, forwards log: URL) async {
        func launched() -> [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        fake.addPod(
            "db-0", namespace: "shop",
            FakeKubeAPI.Pod(
                image: "postgres:16", env: ["POSTGRES_USER": "shop", "POSTGRES_DB": "orders"],
                secretEnv: ["POSTGRES_PASSWORD": FakeKubeAPI.SecretKeyRef(name: "web-db", key: "password")], ports: [FakeKubeAPI.ContainerPort(5432)]))
        fake.addPod("cache-0", namespace: "shop", FakeKubeAPI.Pod(image: "redis:7.4"))
        if app.store.showingOverlay != .kubernetes { app.showKubernetesPage() }
        model.setKind(.pods)
        page.showKind(.pods)
        check("the database pod is listed", await eventually(10) { page.rows.contains { $0.id == "shop/db-0" } }, "\(page.rows.map(\.id))")
        let actions = page.actions
        defer { page.actions = actions }
        var asked: [String] = []
        page.actions?.choose = { title, detail, buttons, then in
            asked.append(title + " | " + detail + " | " + buttons.joined(separator: ", "))
            then(0)
        }
        fake.forgetRequests()
        let before = launched().count
        page.selection = ["shop/db-0"]
        page.giveListTheKeyboard()
        check("d on a postgres-looking pod", page.press("d"))
        check("opens the Database client's form", await eventually(20) { self.window.attachedSheet != nil }, page.commandProblem ?? "")
        let draft = app.databaseDraft
        let forward = KubeForwards.shared.forwards.first { $0.spec.target == .pod("db-0") }
        check(
            "through a forward to the pod's 5432, by the stand-in kubectl",
            forward?.isForwarding == true && forward?.spec.remotePort == 5432
                && launched().dropFirst(before).contains { $0.contains("port-forward pod/db-0 \(forward?.spec.localPort ?? 0):5432 --context fake-dev --namespace shop") },
            "\(launched().dropFirst(before))")
        check(
            "filled in: 127.0.0.1 and the forward's local port, the env's user and database",
            draft?.connection.kind == .postgres && draft?.connection.host == "127.0.0.1" && draft?.connection.port == forward?.spec.localPort
                && draft?.connection.user == "shop" && draft?.connection.database == "orders",
            "\(String(describing: draft?.connection))")
        check(
            "the Secret read only once asked, naming it and its key",
            asked.count == 1 && asked.first?.contains("web-db (password)") == true, asked.first ?? "not asked")
        check("its value in the form, masked there", draft?.password == Self.secretValue)
        check(
            "one GET of that Secret, nothing else of it",
            fake.requests.filter { $0.path.hasPrefix("/api/v1/namespaces/shop/secrets") }.map(\.path) == ["/api/v1/namespaces/shop/secrets/web-db"],
            "\(fake.requests.filter { $0.path.contains("secrets") }.map(\.path))")
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        _ = await eventually(2) { self.window.attachedSheet == nil }
        check("the form put away, the window keeps no password", app.databaseDraft != nil && app.databaseDraft?.password == nil)
        check(
            "the forward d started is the Database client's: its server not probed for an API",
            forward?.spec.forDatabase == true && forward.map { KubeForwards.shared.openAPI[$0.id] == nil } == true)
        let connections = DatabaseModel.shared.store.file
        let saved = (try? String(contentsOf: connections, encoding: .utf8)) ?? ""
        check("put away unsaved: nothing saved, nothing of the Secret on disk", !saved.contains(Self.secretValue) && !saved.contains("db-0"))
        if let forward { page.stopForward(forward.id) }

        page.selection = ["shop/cache-0"]
        check("d on a Redis pod", page.press("d"))
        check(
            "says the Database client doesn't speak it, and what does",
            await eventually(10) { page.commandProblem?.contains("redis-cli") == true }, page.commandProblem ?? "")
        check("and starts nothing", !KubeForwards.shared.forwards.contains { $0.spec.target == .pod("cache-0") })
        fake.deletePod("db-0", namespace: "shop")
        fake.deletePod("cache-0", namespace: "shop")

        // An Ingress: o opens its host, in the default browser.
        fake.add(
            "ingresses.networking.k8s.io", "web", namespace: "shop", values: ["Class": "nginx", "Hosts": "shop.acme.test"],
            fields: [
                "spec": [
                    "tls": [["hosts": ["shop.acme.test"], "secretName": "web-tls"]],
                    "rules": [["host": "shop.acme.test", "http": ["paths": [["path": "/", "pathType": "Prefix", "backend": ["service": ["name": "web", "port": ["number": 80]]]]]]]],
                ]
            ])
        guard let ingresses = model.catalog.kind(fullName: "ingresses.networking.k8s.io") else { return check("fake-dev serves ingresses", false) }
        page.showKind(ingresses)
        check("the Ingresses list", await eventually(10) { page.rows.contains { $0.id == "shop/web" } }, "\(page.rows.map(\.id))")
        page.selection = ["shop/web"]
        app.kubernetesOpenedExternally = []
        check("o on an Ingress", page.press("o"))
        check(
            "opens its host in the default browser, https as its TLS says",
            await eventually(10) { self.app.kubernetesOpenedExternally == [URL(string: "https://shop.acme.test/")!] }, "\(app.kubernetesOpenedExternally)")
        check("Open in Browser is its verb", page.verbs(for: ["shop/web"]).contains { $0.title == "Open in Browser" && $0.key == "o" })
        fake.delete("ingresses.networking.k8s.io", "web", namespace: "shop")
        model.setKind(.pods)
        page.showKind(.pods)
    }

    /// What answers on 127.0.0.1:port — the stand-in says its pod's name.
    private func answer(_ port: Int) async -> String? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A pod's commands in a tab (stage 1d): `e` and `t` on fake-dev's
    /// web-7d9 are recorded, never typed — the command that would be typed,
    /// its tab pinned to the context and namespace, the tab's KUBECONFIG —
    /// after the stand-in answered `kubectl auth can-i` with the run's
    /// kubeconfig, `--context` and `-n`, once a minute. Attach, which it
    /// refuses, is greyed with why and opens nothing. A pod with two
    /// containers asks which, kubectl's default first. On fake-prod a
    /// shell is asked first, naming the context and the pod, once per pod.
    private func kubernetesPodCommands(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, kubeconfig: URL, canI log: URL) async {
        let opened = Set(app.store.tabs.map(\.id))
        var recorded: [(command: String, tab: Tab)] = []
        app.kubernetesCommandRecorder = { command, tab in recorded.append((command, tab)) }
        defer { app.kubernetesCommandRecorder = nil }
        // What the pods picked before asked is forgotten: from here, every question counted.
        model.access.forget(context: "fake-dev")
        model.access.forget(context: "fake-prod")
        try? FileManager.default.removeItem(at: log)
        func canIs() -> [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        /// The page again, on the pods, this pod selected.
        func reopen(_ id: String) async -> Bool {
            if app.store.showingOverlay != .kubernetes { app.showKubernetesPage() }
            page.filter = ""
            page.applySelector()
            if model.kind.fullName != KubeResourceKind.pods.fullName { page.showKind(.pods) }
            let listed = await eventually(10) { page.rows.contains { $0.id == id } }
            page.selection = [id]
            return listed
        }
        func sheetButtons() -> [String] {
            guard let root = window.attachedSheet?.contentView else { return [] }
            var titles: [String] = []
            func walk(_ view: NSView) {
                if let button = view as? NSButton, !button.title.isEmpty { titles.append(button.title) }
                view.subviews.forEach(walk)
            }
            walk(root)
            return titles
        }

        check("the page on fake-dev's shop pods", await reopen("shop/web-7d9") && model.selectedName == "fake-dev" && model.scope == .namespace("shop"))
        let titles = ["Shell in a Tab", "Attach in a Tab", "Follow Logs in a Tab"]
        func verb(_ title: String) -> ResourceVerb? { page.verbs(for: ["shop/web-7d9"]).first { $0.title == title } }
        check(
            "kubectl auth can-i is asked as the pod is picked",
            await eventually(15) { (titles + ["Port-forward…"]).allSatisfy { verb($0) != nil && !(verb($0)?.unavailable ?? "").hasPrefix("Checking") } },
            "\(titles.map { verb($0)?.unavailable ?? "none" }) \(canIs())")
        check("a shell is offered", verb("Shell in a Tab") != nil && verb("Shell in a Tab")?.unavailable == nil, verb("Shell in a Tab")?.unavailable ?? "")
        check("so is a log followed in a tab", verb("Follow Logs in a Tab")?.unavailable == nil, verb("Follow Logs in a Tab")?.unavailable ?? "")
        check(
            "attach, refused by can-i, is greyed with the reason",
            verb("Attach in a Tab")?.unavailable == "kubectl auth can-i create pods/attach says no in shop.", verb("Attach in a Tab")?.unavailable ?? "")
        let asked = canIs()
        check(
            "can-i got the run's kubeconfig alone, --context and -n",
            !asked.isEmpty && asked.allSatisfy { $0.hasPrefix(kubeconfig.path + "|auth can-i ") && $0.contains("--context fake-dev -n shop") },
            "\(asked)")
        check(
            "one question each: exec, attach, log, port-forward",
            Set(asked.compactMap { $0.split(separator: " ").dropFirst(2).first.map(String.init) }) == ["create", "get"] && asked.count == 4, "\(asked)")

        // e: a shell, recorded with its tab.
        _ = page.press("e")
        check("e opens a tab", await eventually(10) { recorded.count == 1 }, page.commandProblem ?? "no problem said")
        let shell = "kubectl exec -it web-7d9 -c app --context fake-dev -n shop -- sh -c 'command -v bash >/dev/null && exec bash || exec sh'"
        check("e is kubectl exec, its context and namespace said", recorded.first?.command == shell, recorded.first?.command ?? "")
        if let tab = recorded.first?.tab {
            check("in a tab pinned to fake-dev in shop", tab.kubePin?.context == "fake-dev" && tab.kubePin?.namespace == "shop", "\(String(describing: tab.kubePin))")
            let value = tab.terminal.environment["KUBECONFIG"] ?? ""
            let parts = value.split(separator: ":").map(String.init)
            check(
                "its KUBECONFIG the pin's file, then the run's kubeconfig alone",
                parts.count == 2 && parts.last == kubeconfig.path
                    && parts.first?.hasPrefix(AppEnvironment.supportDirectory.appendingPathComponent("Kubernetes/Contexts").path + "/") == true, value)
            check("selected, the page stepped aside", app.store.selectedID == tab.id && app.store.showingOverlay == nil)
            check("a new tab, after the selected one's", !opened.contains(tab.id))
        }

        // t: the log followed, in its own tab.
        check("back on the page", await reopen("shop/web-7d9"))
        _ = page.press("t")
        check("t opens a tab", await eventually(10) { recorded.count == 2 }, page.commandProblem ?? "")
        check(
            "t is kubectl logs -f, the default container", recorded.last?.command == "kubectl logs -f --tail=200 web-7d9 -c app --context fake-dev -n shop",
            recorded.last?.command ?? "")
        check("pinned the same", recorded.last?.tab.kubePin?.context == "fake-dev" && recorded.last?.tab.kubePin?.namespace == "shop")

        // A: refused — nothing opens, and the page says why.
        check("back on the page", await reopen("shop/web-7d9"))
        _ = page.press("A")
        check("A, refused, says why", await eventually(5) { page.commandProblem?.contains("says no") == true }, page.commandProblem ?? "nothing said")
        await pause(0.3)
        check("and opens nothing", recorded.count == 2)
        check("drawn on the page", await shownText(15) { $0.contains("pods/attach says no") } != nil)
        check("picked again, the refusal goes", await reopen("shop/web-7d9") && page.commandProblem == nil, page.commandProblem ?? "")
        _ = page.press("e")
        check("e again", await eventually(10) { recorded.count == 3 })
        check("can-i's answers are kept: nothing asked again", canIs().count == 4, "\(canIs())")

        // Two containers: which, kubectl's default first.
        fake.updatePod("web-7d9", namespace: "shop") { $0.containers = 2 }
        check("back on the page", await reopen("shop/web-7d9"))
        _ = page.press("t")
        check("two containers: asked which", await eventually(10) { self.window.attachedSheet != nil })
        let buttons = sheetButtons()
        check("the default first, then the other", buttons.starts(with: ["app (default)", "sidecar-1"]), "\(buttons)")
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        check("the one chosen", await eventually(10) { recorded.count == 4 && recorded.last?.command.contains(" -c sidecar-1 ") == true }, recorded.last?.command ?? "")
        fake.updatePod("web-7d9", namespace: "shop") { $0.containers = 1 }

        // fake-prod: a shell asked first, naming the context and the pod.
        model.select("fake-prod")
        check("on fake-prod's pods", await reopen("payments/api-0") && model.scope == .namespace("payments"), "\(model.scope)")
        _ = page.press("e")
        check("a shell on production is asked first", await eventually(15) { self.window.attachedSheet != nil }, page.commandProblem ?? "")
        let said = sheetTexts().joined(separator: "\n")
        check("naming the context, the namespace and the pod", said.contains("fake-prod") && said.contains("payments/api-0"), said)
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        _ = await eventually(2) { self.window.attachedSheet == nil }
        await pause(0.5)
        check("Cancel opens nothing", recorded.count == 4)
        _ = page.press("e")
        check("asked again", await eventually(10) { self.window.attachedSheet != nil })
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check("confirmed, its tab", await eventually(10) { recorded.count == 5 }, page.commandProblem ?? "")
        check(
            "the shell names fake-prod and payments", recorded.last?.command.contains("exec -it api-0 -c app --context fake-prod -n payments -- ") == true,
            recorded.last?.command ?? "")
        check("its tab pinned to production", recorded.last?.tab.kubePin?.isProduction == true && recorded.last?.tab.kubePin?.namespace == "payments")
        check("and carries the red band", await eventually(5) { self.productionBands() == [true] }, "\(productionBands())")
        check("back on the page", await reopen("payments/api-0"))
        _ = page.press("e")
        check("once per pod: not asked again", await eventually(10) { recorded.count == 6 } && window.attachedSheet == nil)
        check("can-i asked of fake-prod with its namespace", canIs().contains { $0.contains("create pods/exec --context fake-prod -n payments") }, "\(canIs())")

        // t on fake-prod: its tab is a pinned shell once the follow ends —
        // asked first, as Terminal in this context is, once for the context.
        check("back on the page", await reopen("payments/api-0"))
        _ = page.press("t")
        check("a log followed on production is asked first", await eventually(15) { self.window.attachedSheet != nil }, page.commandProblem ?? "")
        let follow = sheetTexts().joined(separator: "\n")
        check(
            "saying what the tab becomes", follow.contains("fake-prod") && follow.contains("a plain kubectl, helm or k9s in it goes to fake-prod"), follow)
        check("nothing before the answer", recorded.count == 6)
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check("confirmed, the log's tab", await eventually(10) { recorded.count == 7 }, page.commandProblem ?? "")
        check(
            "kubectl logs -f on fake-prod, pinned to it",
            recorded.last?.command == "kubectl logs -f --tail=200 api-0 -c app --context fake-prod -n payments"
                && recorded.last?.tab.kubePin?.isProduction == true, recorded.last?.command ?? "")
        check("back on the page", await reopen("payments/api-0"))
        _ = page.press("t")
        check("once for the context: not asked again", await eventually(10) { recorded.count == 8 } && window.attachedSheet == nil)
        check("never with a kubeconfig but the run's", canIs().allSatisfy { $0.hasPrefix(kubeconfig.path + "|") })

        model.select("fake-dev")
        check("another context: no command's problem left", page.commandProblem == nil, page.commandProblem ?? "")
        app.closeTabsWithoutAsking(app.store.tabs.filter { !opened.contains($0.id) })
        if app.store.showingOverlay == .kubernetes { app.toggleKubernetesPage(nil) }
    }

    /// The planted secrets Ask Why's brief must never carry.
    static let askWhySecret = "sk_test_fake_e2e_7Hq2"
    static let askWhyBearer = "fakeE2E.bearer-Tok3n"

    /// Ask Why (3.4): on fake-dev's crash-looping pod, `a` reads the brief
    /// — GETs through the proxy, its previous instance's log, its events —
    /// and opens the Ask Agent sheet with the whole brief shown, a planted
    /// secret (the pod's own env value, a bearer token in its log) scrubbed
    /// and a Secret's env named, never read. Nothing is sent: the prompt is
    /// read and the sheet cancelled (an agent's tab, not started, is the
    /// target offered first — the selected tab's). A pod that is fine says
    /// why and opens nothing; ⌘L over the page asks the same; on fake-prod
    /// it works too, reads only.
    private func kubernetesAskWhy(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        let opened = Set(app.store.tabs.map(\.id))
        func sheet() -> AskAgentView? { (window.attachedSheet?.contentViewController as? NSHostingController<AskAgentView>)?.rootView }
        func cancelSheet() async -> Bool {
            let cancelled = sheet().map { $0.cancel() } != nil
            return await eventually(3) { self.window.attachedSheet == nil } && cancelled
        }
        func reopen(_ id: String) async -> Bool {
            if app.store.showingOverlay != .kubernetes { app.showKubernetesPage() }
            page.closeDetail()
            page.filter = ""
            page.applySelector()
            if model.kind.fullName != KubeResourceKind.pods.fullName { page.showKind(.pods) }
            let listed = await eventually(10) { page.rows.contains { $0.id == id } }
            page.selection = [id]
            return listed
        }
        var crashing = FakeKubeAPI.Pod(status: "CrashLoopBackOff", phase: "Running", ready: 0, restarts: 7, lastRestart: "40s", image: "acme/billing:2.3.0")
        crashing.env = ["STRIPE_SECRET_KEY": Self.askWhySecret, "MODE": "live"]
        crashing.secretEnv = ["DB_PASSWORD": FakeKubeAPI.SecretKeyRef(name: "web-db", key: "password")]
        fake.addPod("billing-7f", namespace: "shop", crashing)
        fake.addPod("calm-1", namespace: "shop")
        fake.setLog(
            "billing-7f", namespace: "shop",
            ["billing 2.3.0 starting", "stripe key \(Self.askWhySecret) loaded", "Authorization: Bearer \(Self.askWhyBearer)", "FATAL: cannot reach ledger"],
            previous: true)
        fake.addEvent(about: "pods", "billing-7f", namespace: "shop", type: "Warning", reason: "BackOff", message: "Back-off restarting failed container app", count: 9)

        // The agent offered first: the selected tab's, under the page.
        app.newTab(in: FileManager.default.homeDirectoryForCurrentUser, agent: .claude, startAgent: false)
        guard let agentTab = app.store.selected else { return check("an agent tab to offer", false) }
        agentTab.customTitle = "shop · claude"

        model.select("fake-dev")
        check("the page on fake-dev's crashing pod", await reopen("shop/billing-7f") && model.selectedName == "fake-dev")
        func askWhy(_ id: String) -> ResourceVerb? { page.verbs(for: [id]).first { $0.title == "Ask an Agent Why…" } }
        check("its menu asks an agent why", askWhy("shop/billing-7f")?.unavailable == nil && askWhy("shop/billing-7f")?.key == "a")
        check(
            "greyed with why on a pod that is fine", askWhy("shop/calm-1")?.unavailable == "pod/calm-1 isn't failing: Running, 1/1 ready.",
            askWhy("shop/calm-1")?.unavailable ?? "none")
        check("its row has the Ask Why button", await shownText(15) { $0.contains("Why") } != nil)
        fake.forgetRequests()
        check("a asks why", page.press("a"))
        check("the Ask Agent sheet opens", await eventually(15) { self.window.attachedSheet != nil && sheet() != nil }, page.commandProblem ?? "")
        let ask = app.askAgent
        check(
            "the question is started for you",
            ask.message == "Why does pod shop/billing-7f keep crashing (CrashLoopBackOff)?"
                && ask.subject == "pod/billing-7f CrashLoopBackOff", "\(ask.message) / \(ask.subject ?? "none")")
        check("and the whole brief is shown before it is sent", ask.showsBrief)
        check(
            "the selected tab's agent is offered first, and chosen; a new one last",
            ask.targets.first?.id == agentTab.id && ask.chosen == agentTab.id && ask.targets.last?.id == nil, "\(ask.targets.map(\.title))")
        check(
            "its sections", ["events", "previous log of app"].allSatisfy { title in ask.parts.contains { $0.title == title } },
            "\(ask.parts.map(\.title))")
        let prompt = await app.askAgentPrompt()
        check(
            "how it ended, and what its exit code means",
            prompt.contains("Kubernetes pod shop/billing-7f, in context fake-dev") && prompt.contains("Restarts: 7")
                && prompt.contains("Last terminated: terminated — Error, exit 1") && prompt.contains("a general error"), prompt)
        check("its events", prompt.contains("Warning BackOff ×9"), prompt)
        check("its previous instance's log", prompt.contains("FATAL: cannot reach ledger") && prompt.contains("billing 2.3.0 starting"), prompt)
        check(
            "the planted secrets scrubbed", !prompt.contains(Self.askWhySecret) && !prompt.contains(Self.askWhyBearer) && prompt.contains("stripe key •••••• loaded"),
            prompt)
        check("a Secret's env named, never valued", prompt.contains("DB_PASSWORD from Secret web-db, key password (not read)"), prompt)
        check(
            "read with GETs alone, no Secret among them",
            fake.writes.isEmpty && !fake.requests.contains { $0.path.contains("/secrets") }
                && fake.requests.contains { $0.isLog && $0.query["previous"] == "true" && $0.path.hasSuffix("/billing-7f/log") }, "\(fake.requests)")
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty, let shown = window.attachedSheet {
            app.captureWindow(to: png.replacingOccurrences(of: ".png", with: "-kube-ask-why.png"), window: shown)
        }
        check("Cancel sends nothing and puts the sheet away", await cancelSheet() && !ask.isOpen)
        check("the page is still there, its list has the keyboard", app.store.showingOverlay == .kubernetes)
        _ = await eventually(3) { self.app.kubernetesListHasKeyboard() }

        // A pod that is fine: why not, and nothing opens.
        page.selection = ["shop/calm-1"]
        check("a on a pod that is fine says why", page.press("a") && page.commandProblem == "pod/calm-1 isn't failing: Running, 1/1 ready.")
        await pause(0.4)
        check("and opens nothing", window.attachedSheet == nil)

        // ⌘L over the page: the same, never the terminal hidden under it.
        page.selection = ["shop/billing-7f"]
        app.focusPageList(.kubernetes)
        _ = await eventually(3) { self.app.kubernetesListHasKeyboard() }
        let fromMenu = menuItem("Edit", "Ask an Agent About the Selection").map { perform($0) } == true
        let overPage = await eventually(15) { self.window.attachedSheet != nil && sheet() != nil }
        check("⌘L over the page asks why too", fromMenu && overPage && ask.subject == "pod/billing-7f CrashLoopBackOff", ask.subject ?? "none")
        check("Cancel", await cancelSheet())

        // The detail's button.
        page.pressed("shop/billing-7f")
        _ = await eventually(10) { page.detail?.object != nil }
        let button = page.detail.map { page.detailVerbs(for: $0.ref) }?.first { $0.title == "Ask an Agent Why…" }
        check("the detail has an Ask Why button", button?.place == .button && button?.unavailable == nil)
        page.closeDetail()

        // fake-prod: reads only, and it says production.
        fake.addPod("ledger-0", namespace: "payments", crashing)
        model.select("fake-prod")
        check("on fake-prod's crashing pod", await reopen("payments/ledger-0"), "\(page.rows.map(\.id))")
        fake.forgetRequests()
        check("a asks why on production too", page.press("a"))
        check("the sheet opens", await eventually(15) { self.window.attachedSheet != nil && sheet() != nil }, page.commandProblem ?? "")
        let production = await app.askAgentPrompt()
        check(
            "saying it is production, read-only",
            production.contains("PRODUCTION context fake-prod (read-only: Overterm changes nothing there)")
                && !production.contains(Self.askWhySecret), production)
        check("reads only: no write, no Secret", fake.writes.isEmpty && !fake.requests.contains { $0.path.contains("/secrets") }, "\(fake.writes)")
        check("Cancel", await cancelSheet())

        model.select("fake-dev")
        fake.deletePod("billing-7f", namespace: "shop")
        fake.deletePod("calm-1", namespace: "shop")
        fake.deletePod("ledger-0", namespace: "payments")
        page.commandProblem = nil
        app.closeTabsWithoutAsking(app.store.tabs.filter { !opened.contains($0.id) })
        if app.store.showingOverlay == .kubernetes { app.toggleKubernetesPage(nil) }
    }

    /// The window's pixels, as RGBA, for what SwiftUI draws (no AppKit
    /// view holds it, and without an assistive app no accessibility
    /// element either): read where a person looks.
    struct ShownPixels {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        let scale: CGFloat
        let windowHeight: CGFloat

        /// The page's production red, near enough (the capture is in the display's colours).
        func isRed(at point: CGPoint) -> Bool {
            let x = Int(point.x * scale)
            let y = Int((windowHeight - point.y) * scale)
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            let i = (y * width + x) * 4
            let (r, g, b) = (Double(bytes[i]) / 255, Double(bytes[i + 1]) / 255, Double(bytes[i + 2]) / 255)
            // A pane without the keyboard is dimmed: the red darker, still red.
            return r > 0.4 && r > g * 2.2 && r > b * 2.2
        }
    }

    func shownPixels() -> ShownPixels? {
        guard let image = app.windowImage(window) else { return nil }
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, window.frame.width > 0 else { return nil }
        return ShownPixels(bytes: bytes, width: width, height: height, scale: CGFloat(width) / window.frame.width, windowHeight: window.frame.height)
    }

    /// For each pane header on screen, left to right: whether its bottom
    /// row is the production red band (most of its width), off the pixels.
    func productionBands() -> [Bool] {
        guard let pixels = shownPixels(), let frame = window.contentView?.superview else { return [] }
        var headers: [NSView] = []
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            if String(describing: type(of: view)).contains("PaneHeaderView"), view.bounds.width > 40 { headers.append(view) }
            view.subviews.forEach(walk)
        }
        walk(frame)
        return headers.map { header -> (CGFloat, Bool) in
            let y = header.isFlipped ? header.bounds.maxY - 1.5 : header.bounds.minY + 1.5
            let row = header.convert(NSRect(x: 0, y: y, width: header.bounds.width, height: 0), to: nil)
            let xs = stride(from: row.minX + 8, to: row.maxX - 8, by: 6).map { $0 }
            let red = xs.filter { pixels.isRed(at: CGPoint(x: $0, y: row.minY)) }.count
            return (row.minX, !xs.isEmpty && Double(red) > Double(xs.count) * 0.8)
        }
        .sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// The strip's text with `word` in the title bar, and whether it is
    /// drawn in the production red.
    func stripLabel(_ word: String) async -> (found: Bool, red: Bool) {
        let top = window.contentLayoutRect.maxY
        let deadline = Date().addingTimeInterval(15)
        repeat {
            for tiled in [false, true] {
                for line in await readWindow(tiled: tiled) where line.text.contains(word) && line.frame.midY > top {
                    guard let pixels = shownPixels() else { return (true, false) }
                    var red = 0
                    for x in stride(from: line.frame.minX, to: line.frame.maxX, by: 1) {
                        for y in stride(from: line.frame.minY, to: line.frame.maxY, by: 1) where pixels.isRed(at: CGPoint(x: x, y: y)) { red += 1 }
                    }
                    return (true, red >= 6)
                }
            }
            await pause(0.3)
        } while Date() < deadline
        return (false, false)
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
        check("and drawn down the left", await drawn(["Custom Resources", "Deployments"]))

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
        check("drawn, with what deploy completes to", await drawn(["deployments", "Deployments", "deploy", "apps/v1"]))
        page.runCommand()
        check(":deploy shows the deployments", model.kind.fullName == "deployments.apps" && page.command == nil && page.section == .workloads)
        check(
            "the server's deployments", await eventually(10) { model.rows.sorted.map(\.id.description) == ["shop/web", "shop/worker"] && model.listState == .live },
            "\(model.rows.sorted.map(\.id.description)) \(model.listState)")
        check(
            "in its own columns, and a Status read off them", page.columns.map(\.title) == ["Name", "Ready", "Up-to-date", "Available", "Status", "Age"],
            "\(page.columns.map(\.title))")
        check("as rows only", fake.requests.contains { $0.path == "/apis/apps/v1/namespaces/shop/deployments" && $0.query["includeObject"] == "None" })
        check("titled so", page.title == "Deployments", page.title)
        check("and drawn", await shownText(15) { $0.contains("Up-to-date") } != nil)
        check("the list has the keyboard again", await eventually(3) { self.app.kubernetesListHasKeyboard() })
        await kubernetesCopyAndExport(model, page)

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
        check("drawn", await drawn(["blue-1", "Color"]))
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
            await eventually(10) { model.rows.count == 2 }
                && model.rows[KubeRowID(namespace: "shop", name: "web-tls")]?.cell("Data", in: model.rows.columns) == .integer(2))
        check(
            "never its values",
            !String(describing: model.rows).contains("fake-key") && !String(describing: model.rows).contains(Self.secretValue)
                && !fake.requests.contains { $0.path.contains("/secrets/") })
        check(
            "asked for as rows only",
            fake.requests.filter { $0.path.hasSuffix("/secrets") }.allSatisfy { $0.query["includeObject"] == "None" && $0.accept.contains("as=Table") })

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

    /// `field:` on the Pods list: asked of the server (the fake records the
    /// fieldSelector, the list and its watch), said, and `k` by the key as
    /// the window takes it copies the list's command with it.
    private func kubernetesFieldSelector(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        var done = FakeKubeAPI.Pod()
        done.status = "Completed"
        done.phase = "Succeeded"
        done.ready = 0
        fake.addPod("migrate-1", namespace: "shop", done)
        check("a finished pod comes in", await eventually(5) { model.rows.count == 3 }, "\(model.rows.count)")
        page.filter = "field:status.phase=Running"
        page.applySelector()
        check(
            "field: is asked of the server", await eventually(10) { model.rows.sorted.map(\.id.name) == ["web-7d9", "worker-5c"] },
            "\(model.rows.sorted.map(\.id.name))")
        check(
            "as the list's fieldSelector, through the proxy",
            fake.requests.contains { $0.path == "/api/v1/namespaces/shop/pods" && !$0.isWatch && $0.query["fieldSelector"] == "status.phase=Running" },
            "\(fake.requests.suffix(3))")
        check("and its watch's", fake.requests.contains { $0.isWatch && $0.query["fieldSelector"] == "status.phase=Running" })
        check("and the page says so", await shownText(15) { $0.contains("Asked of the server: field status.phase=Running") } != nil)
        page.selection = []
        page.giveListTheKeyboard()
        _ = await eventually(3) { self.app.kubernetesListHasKeyboard() }
        let copied: String? = await withPasteboardKept {
            guard
                let k = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: self.window.windowNumber, context: nil, characters: "k",
                    charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)
            else { return nil }
            return self.app.handlePageKey(k) ? NSPasteboard.general.string(forType: .string) : nil
        }
        check(
            "k copies the list as kubectl, its field selector with it",
            copied == "kubectl --context fake-dev get po -n shop --field-selector status.phase=Running", copied ?? "nothing")
        page.filter = ""
        page.applySelector()
        fake.deletePod("migrate-1", namespace: "shop")
        check("cleared, the two pods again", await eventually(10) { model.rows.count == 2 }, "\(model.rows.count)")
    }

    /// On the deployments: `k` on a selected one (its YAML's command), the
    /// palette (⌘K) finding it, a page command and the kinds, and the list
    /// as CSV — written into the run's folder, no panel — with the columns
    /// shown, the Status read off the cells among them.
    private func kubernetesCopyAndExport(_ model: KubernetesModel, _ page: KubernetesPageModel) async {
        check(
            "a Status read off the deployments' cells",
            page.rows.map { $0.hint?.text } == ["Available", "Unavailable 0/1"], "\(page.rows.map { $0.hint?.text ?? "-" })")
        check("and drawn", await shownText(15) { $0.contains("Unavailable 0/1") } != nil)
        page.selection = ["shop/web"]
        let copied: String? = await withPasteboardKept { page.press("k") ? NSPasteboard.general.string(forType: .string) : nil }
        check("k copies the deployment as kubectl", copied == "kubectl --context fake-dev -n shop get deploy web -o yaml", copied ?? "nothing")

        app.showPalette(nil)
        app.palette.query = "worker"
        check(
            "⌘K finds a deployment", await eventually(10) { self.app.palette.results.contains { $0.id == "k.o.deployments.apps/shop/worker" } },
            "\(app.palette.results.prefix(4).map(\.id))")
        app.palette.query = "go to deployments"
        check("and the kind", app.palette.results.first?.id == "k.k.deployments.apps", "\(app.palette.results.prefix(3).map(\.id))")
        app.palette.query = "copy as kubectl"
        check("and the page's commands", app.palette.results.first?.id == "k.a.copyKubectl", "\(app.palette.results.prefix(3).map(\.id))")
        app.hidePalette()
        // The palette gives the keyboard to the terminal under the page; the list takes it back.
        await pause(0.3)
        page.giveListTheKeyboard()
        check("the list has the keyboard after the palette", await eventually(3) { self.app.kubernetesListHasKeyboard() })

        let file = TerminalWindowController.kubernetesExportFolder.appendingPathComponent("fake-dev-shop-deployments.csv")
        try? FileManager.default.removeItem(at: file)
        page.selection = []
        app.exportKubernetesList(nil)
        let csv = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let lines = csv.split(separator: "\n").map(String.init)
        check("the export wrote its file", page.exportProblem == nil, page.exportProblem ?? "")
        check("the list exported as CSV, into the run's folder", lines.first == "Name,Ready,Up-to-date,Available,Status,Age", csv)
        check(
            "its rows in the visible columns",
            lines.count == 3 && lines[1].hasPrefix("web,1/1,1,1,Available,") && lines[2].hasPrefix("worker,0/1,1,0,Unavailable 0/1,"), csv)

        // Copy Rows as TSV: the visible rows with nothing selected, the selected one else.
        let visible: String? = await withPasteboardKept {
            page.copyRows(.tsv)
            return NSPasteboard.general.string(forType: .string)
        }
        let tsv = visible?.split(separator: "\n").map(String.init) ?? []
        check(
            "Copy Rows as TSV: the visible rows", tsv.first == "Name\tReady\tUp-to-date\tAvailable\tStatus\tAge" && tsv.count == 3,
            visible ?? "nothing")
        page.selection = ["shop/worker"]
        let selected: String? = await withPasteboardKept {
            page.copyRows(.csv)
            return NSPasteboard.general.string(forType: .string)
        }
        let rows = selected?.split(separator: "\n").map(String.init) ?? []
        check("Copy Rows as CSV: the selected one", rows.count == 2 && rows[1].hasPrefix("worker,0/1,"), selected ?? "nothing")
        page.selection = []
    }

    /// `body` with the user's pasteboard put back after: what it copied is
    /// read inside, then the pasteboard holds what it held before.
    private func withPasteboardKept<T>(_ body: () async -> T) async -> T {
        let board = NSPasteboard.general
        let kept = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let result = await body()
        board.clearContents()
        let items = kept.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
        return result
    }

    /// The detail: a pod opened by ↩ as the window takes it — one GET, its
    /// overview, YAML without managedFields (the toggle shows them), its
    /// events by uid — its owner and the owner's owner followed as links,
    /// ⌘[ and ⌘] back and forward, a stuck deployment opened by a click,
    /// a Secret's (kubernetesSecrets), Esc.
    private func kubernetesDetail(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        func key(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        }
        page.giveListTheKeyboard()
        _ = await eventually(3) { self.app.kubernetesListHasKeyboard() }
        page.selection = ["shop/web-7d9"]
        check("a row selected opens no detail", page.detail == nil)
        fake.forgetRequests()
        guard let enter = key("\r", 36) else { return check("a ↩ key", false) }
        check("↩ is the list's", app.handlePageKey(enter))
        guard let pod = page.detail else { return check("↩ opens the pod's detail", false) }
        check("↩ opens the pod's detail", pod.ref.name == "web-7d9" && pod.ref.kind.fullName == "pods" && pod.ref.namespace == "shop")
        check("on its logs, a pod's ↩", page.detailTab == .logs)
        check("read whole", await eventually(10) { pod.state == .loaded }, "\(pod.state)")
        check(
            "with one GET",
            fake.requests.filter { $0.path.hasPrefix("/api/v1/namespaces/shop/pods/") && !$0.isLog }.map(\.path) == ["/api/v1/namespaces/shop/pods/web-7d9"],
            "\(fake.requests)")
        page.showTab(.overview)
        let overview = pod.overview
        check("its phase", overview?.item("Phase")?.value == "Running", overview?.item("Phase")?.value ?? "none")
        check("its node, a link", overview?.item("Node")?.value == "fake-node-1" && overview?.item("Node")?.link?.kind == "Node")
        check("its container's image", overview?.section("Containers")?.items.first?.detail == "nginx:1.27")
        check("its owner, a link", overview?.section("Owned by")?.items.first?.link?.name == "web-7d9f")
        check("drawn beside the list", await shownText(15) { $0.contains("web-7d9f") } != nil)

        page.showTab(.yaml)
        check(
            "the YAML, without managedFields or the last-applied annotation",
            !pod.yaml.isEmpty && !pod.yaml.contains("managedFields") && !pod.yaml.contains(KubeObjectStrip.lastApplied) && pod.yaml.contains("image: nginx:1.27"),
            String(pod.yaml.prefix(300)))
        check("drawn", await shownText(15) { $0.contains("nodeName: fake-node-1") } != nil)
        pod.showsHidden = true
        check("the toggle shows them", pod.yaml.contains("managedFields:") && pod.yaml.contains(KubeObjectStrip.lastApplied))
        pod.showsHidden = false

        page.showTab(.events)
        check("its events", await eventually(10) { pod.events.value?.map(\.reason) == ["Unhealthy", "Scheduled"] }, "\(pod.events)")
        check("the warning first, marked", pod.events.value?.first?.isWarning == true && pod.events.value?.first?.count == 4)
        let uid = fake.uid("pods", "web-7d9", namespace: "shop") ?? "?"
        check(
            "asked of the server by the pod's uid",
            fake.requests.contains { $0.path == "/api/v1/namespaces/shop/events" && $0.query["fieldSelector"]?.contains("involvedObject.uid=\(uid)") == true },
            "\(fake.requests.suffix(3))")
        check("drawn", await shownText(15) { $0.contains("Readiness probe failed") } != nil)
        page.showTab(.overview)

        // Links: the ReplicaSet, then its Deployment.
        guard let owner = overview?.section("Owned by")?.items.first?.link, page.follow(owner), let replicaSet = page.detail else {
            return check("the owner is followed", false, page.linkProblem ?? "")
        }
        check("the owner is followed", replicaSet.ref.kind.fullName == "replicasets.apps" && replicaSet.ref.name == "web-7d9f")
        check("read", await eventually(10) { replicaSet.state == .loaded }, "\(replicaSet.state)")
        guard let up = replicaSet.overview?.section("Owned by")?.items.first?.link, page.follow(up), let deployment = page.detail else {
            return check("and its own owner", false, page.linkProblem ?? "")
        }
        check("and its own owner, a deployment", deployment.ref.kind.fullName == "deployments.apps" && deployment.ref.name == "web")
        check("read", await eventually(10) { deployment.state == .loaded }, "\(deployment.state)")
        let workload = deployment.overview
        check("its replicas", workload?.item("Replicas")?.value == "1/1 ready", workload?.item("Replicas")?.value ?? "none")
        check("its strategy", workload?.item("Strategy")?.value == "RollingUpdate · maxSurge 25% · maxUnavailable 25%", workload?.item("Strategy")?.value ?? "")
        check("its rollout, as kubectl rollout status says it", workload?.rollout?.message == "deployment \"web\" successfully rolled out")
        check(
            "the pods its selector picks, links too", await eventually(10) { deployment.pods.value?.map(\.row.id.name) == ["web-7d9"] },
            "\(deployment.pods)")
        check("drawn", await shownText(15) { $0.contains("successfully rolled out") || $0.contains("Pods it selects") } != nil)

        // ⌘[ and ⌘] as the window takes them.
        page.giveListTheKeyboard()
        _ = await eventually(3) { self.app.kubernetesListHasKeyboard() }
        guard let back = key("[", 33, .command), let forward = key("]", 30, .command) else { return check("⌘[ and ⌘]", false) }
        check("⌘[ is the detail's", app.handlePageKey(back))
        check("back on the ReplicaSet", page.detail?.ref.name == "web-7d9f")
        _ = app.handlePageKey(back)
        check("⌘[ again, the pod", page.detail?.ref.name == "web-7d9" && page.detail?.ref.kind.fullName == "pods")
        check("with nothing behind, ⌘[ is the menus'", !app.handlePageKey(back))
        check("⌘] forward", app.handlePageKey(forward) && page.detail?.ref.name == "web-7d9f")
        check("] forward again", page.press("]") && page.detail?.ref.kind.fullName == "deployments.apps")
        check("[ back", page.press("[") && page.detail?.ref.name == "web-7d9f")
        check("read again for each", await eventually(10) { page.detail?.state == .loaded })

        // A deployment by a click, from its list: stuck.
        _ = page.press(":")
        page.command?.text = "deploy"
        page.runCommand()
        check("the deployments again", await eventually(10) { model.kind.fullName == "deployments.apps" && model.rows.count == 2 })
        page.selection = ["shop/worker"]
        page.pressed("shop/worker")
        guard let worker = page.detail else { return check("a click opens the deployment", false) }
        check("a click opens the deployment", worker.ref.name == "worker" && worker.ref.kind.fullName == "deployments.apps")
        check("read", await eventually(10) { worker.state == .loaded }, "\(worker.state)")
        check(
            "its rollout is stuck", worker.overview?.rollout?.state == .stuck && worker.overview?.rollout?.message == "deployment \"worker\" exceeded its progress deadline",
            "\(String(describing: worker.overview?.rollout))")
        check("and says so", await shownText(15) { $0.contains("exceeded its progress deadline") } != nil)
        page.selection = ["shop/web"]
        check("the detail follows the list", page.detail?.ref.name == "web")

        await kubernetesSecrets(model, page, fake, key: key)
        _ = page.press(":")
        page.command?.text = "po"
        page.runCommand()
        page.selection = []
        check("the pods once more", await eventually(10) { model.kind.fullName == "pods" && model.rows.count == 2 && model.listState == .live })
        check("the detail read by GETs only", fake.writes.isEmpty, "\(fake.writes)")
        await kubernetesLogs(model, page, fake, key: key)
    }

    /// A pod's logs (stage 1c): `l` by the key as the window takes it, the
    /// last lines shown and drawn, older ones when scrolled to the top, the
    /// follow, the stream dropped by the fake and resumed with nothing
    /// twice, newest first, Previous showing the crashed container's lines,
    /// Save As into the run's folder, ⌘L on picked lines scrubbed, the
    /// stream closed with the detail — and only GETs of `log`.
    private func kubernetesLogs(
        _ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, key: (String, UInt16, NSEvent.ModifierFlags) -> NSEvent?
    ) async {
        // web-7d9's log: 600 older lines, then the last ones that matter.
        let start = Date().addingTimeInterval(-900).timeIntervalSince1970.rounded(.down)
        for index in 1...600 {
            fake.appendLog("web-7d9", namespace: "shop", "GET /health \(index) 200", at: Date(timeIntervalSince1970: start + Double(index)))
        }
        let recent = Date().addingTimeInterval(-60).timeIntervalSince1970.rounded(.down)
        fake.appendLog("web-7d9", namespace: "shop", "listening on :8080", at: Date(timeIntervalSince1970: recent + 0.1))
        fake.appendLog("web-7d9", namespace: "shop", "auth with Bearer eyJfake.tokenpart.sig ok", at: Date(timeIntervalSince1970: recent + 1.2))
        fake.appendLog("web-7d9", namespace: "shop", #"{"level":"error","msg":"upstream timed out","path":"/cart"}"#, at: Date(timeIntervalSince1970: recent + 2.3))
        // Running again (the watch's checks left it OOMKilled): a dropped follow is resumed.
        fake.updatePod("web-7d9", namespace: "shop") {
            $0.status = "Running"
            $0.ready = 1
        }
        fake.setLog("worker-5c", namespace: "shop", ["worker booting", "panic: out of cheese"], previous: true, until: Date().addingTimeInterval(-120))
        fake.setLog("worker-5c", namespace: "shop", ["worker booting again"])
        fake.forgetRequests()

        func text() -> LogLinesTextView? {
            Self.find(LogLinesTextView.self, in: app.kubernetesView) { $0.accessibilityIdentifier() == "kubernetes.logs.text" }
        }
        func shown() -> String { text()?.string ?? "" }
        page.giveListTheKeyboard()
        _ = await eventually(3) { self.app.kubernetesListHasKeyboard() }
        page.selection = ["shop/web-7d9"]
        guard let l = key("l", 37, []) else { return check("an l key", false) }
        check("l is the list's", app.handlePageKey(l))
        guard let detail = page.detail, let logs = detail.logs else { return check("l opens the pod's logs", false, "\(String(describing: page.detail))") }
        check("l opens the pod's logs", page.detailTab == .logs && detail.ref.name == "web-7d9")
        check("its default container's", await eventually(10) { logs.container == "app" }, logs.container ?? "none")
        check(
            "its last lines, followed", await eventually(10) { logs.feed.lines.count == 500 && logs.feed.following },
            "\(logs.feed.lines.count) \(logs.reading)")
        check("in the text view", await eventually(10) { shown().contains("upstream timed out") && shown().contains("listening on :8080") }, String(shown().suffix(300)))
        check(
            "its end in view",
            await eventually(5) {
                guard let scroll = text()?.enclosingScrollView, let document = scroll.documentView else { return false }
                return scroll.contentView.bounds.maxY >= document.frame.height - 24
            })
        let lastDrawn = await drawn(["timed out", "on :8080"])
        let read = lastDrawn ? [] : await readWindow().map(\.text).filter { $0.contains("timed") || $0.contains("8080") || $0.contains("health") }
        check("its last lines drawn", lastDrawn, "\(read.suffix(6))")
        let first = fake.requests.filter(\.isLog).first
        check(
            "asked as pods/{p}/log: its container, followed, its tail, with timestamps",
            first?.path == "/api/v1/namespaces/shop/pods/web-7d9/log" && first?.query["container"] == "app" && first?.query["follow"] == "true"
                && first?.query["tailLines"] == "500" && first?.query["timestamps"] == "true" && first?.method == "GET", "\(String(describing: first))")
        check("Logs is one of a pod's tabs", KubeDetailTab.tabs(for: detail.ref).contains(.logs))

        // Moved to the top by code, not a person: back to the end, and no
        // older lines asked for.
        if let view = text(), let scroll = view.enclosingScrollView {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        check(
            "moved by code, it keeps to its end",
            await eventually(5) {
                guard let scroll = text()?.enclosingScrollView, let document = scroll.documentView else { return false }
                return scroll.contentView.bounds.maxY >= document.frame.height - 24
            })
        check("and asks for nothing older", !fake.requests.contains { $0.isLog && $0.query["tailLines"] == "1000" })
        // Older lines: a person's scroll (a trackpad's live scroll) to the
        // top, asked again with a larger tail.
        if let view = text(), let scroll = view.enclosingScrollView {
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
            scroll.reflectScrolledClipView(scroll.contentView)
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        }
        check(
            "scrolled to the top, its older lines come",
            await eventually(10) { logs.feed.lines.count == 603 && logs.reachedStart }, "\(logs.feed.lines.count) \(logs.reachedStart)")
        check(
            "the line read kept, not the end",
            await eventually(5) {
                guard let scroll = text()?.enclosingScrollView, let document = scroll.documentView else { return false }
                return scroll.contentView.bounds.maxY < document.frame.height - 24 && scroll.contentView.bounds.minY > 24
            })
        check("from the very first, once each", logs.feed.lines.first?.message == "GET /health 1 200" && Set(logs.feed.lines.map(\.message)).count == 603)
        check("by a larger tail", fake.requests.contains { $0.isLog && $0.query["tailLines"] == "1000" && $0.query["follow"] == nil })
        func firstLine() -> String { shown().components(separatedBy: "\n").first ?? "" }
        func lastLine() -> String { shown().components(separatedBy: "\n").last ?? "" }
        check("in the text view too", await eventually(5) { firstLine().hasSuffix("GET /health 1 200") }, firstLine())

        // The follow, a drop, and the resume.
        let placed = Date()
        fake.appendLog("web-7d9", namespace: "shop", "order 1 placed", at: placed)
        check("a line written comes by the follow", await eventually(10) { shown().contains("order 1 placed") }, String(shown().suffix(200)))
        check("the fake drops the stream", fake.dropLogStreams() == 1)
        // Written while it was down: one at the very time of the last line shown.
        fake.appendLog("web-7d9", namespace: "shop", "order 1 paid", at: placed)
        fake.appendLog("web-7d9", namespace: "shop", "order 2 placed", at: placed.addingTimeInterval(0.01))
        check(
            "resumed: what was written meanwhile comes", await eventually(15) { shown().contains("order 2 placed") && shown().contains("order 1 paid") },
            "\(logs.reading) \(String(shown().suffix(200)))")
        check(
            "by a follow from its last line's second, capped at what the feed keeps",
            fake.requests.contains { $0.isLog && $0.query["sinceTime"] != nil && $0.query["tailLines"] == "\(LogFeed.keep)" })
        let messages = logs.feed.lines.map(\.message)
        check("nothing twice", messages.count == Set(messages).count && messages.filter { $0 == "order 1 placed" }.count == 1, "\(messages.suffix(5))")
        check("nothing twice on screen", shown().components(separatedBy: "order 1 placed").count == 2)
        check("following again", await eventually(10) { logs.feed.following && fake.openLogStreams == 1 }, "\(logs.reading)")

        // Newest first.
        page.logOptions.newestFirst = true
        check("newest first, the last line on top", await eventually(5) { firstLine().hasSuffix("order 2 placed") && lastLine().hasSuffix("GET /health 1 200") }, firstLine())
        fake.appendLog("web-7d9", namespace: "shop", "order 3 placed")
        check("a new line on top", await eventually(10) { firstLine().hasSuffix("order 3 placed") }, firstLine())
        page.logOptions.newestFirst = false
        check("and back", await eventually(5) { lastLine().hasSuffix("order 3 placed") }, lastLine())

        // Save As, with a timestamped name: in a scenario, the run's folder.
        let folder = TerminalWindowController.kubernetesExportFolder
        page.saveLogs(logs.feed.lines.map(\.plain).joined(separator: "\n") + "\n")
        let name = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.first { $0.hasPrefix("web-7d9-app-") && $0.hasSuffix(".log") }
        let saved = name.flatMap { try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) } ?? ""
        check("Save As writes the log, its name timestamped", name != nil && saved.contains("order 3 placed") && page.exportProblem == nil, name ?? "none")

        // ⌘L on picked lines: scrubbed, with the pod they come from.
        if let view = text() {
            let string = view.string as NSString
            let from = string.range(of: "auth with Bearer").location
            let to = string.range(of: "upstream timed out").location
            if from != NSNotFound, to != NSNotFound {
                view.setSelectedRange(NSRange(location: from, length: to - from + 4))
                window.makeFirstResponder(view)
                let asked = menuItem("Edit", "Ask an Agent About the Selection").map { perform($0) } == true
                let opened = await eventually(5) { self.window.attachedSheet != nil }
                let agent = app.askAgent
                check(
                    "⌘L on picked log lines asks about them, scrubbed",
                    asked && opened && agent.selection.contains("upstream timed out") && agent.selection.contains("auth with Bearer")
                        && !agent.selection.contains("eyJfake"), "\(asked) \(opened) \(agent.selection.debugDescription)")
                check(
                    "with the pod they come from", agent.parts.first?.title == "pod/web-7d9" && agent.parts.first?.text.contains("logs web-7d9 -c app") == true,
                    "\(agent.parts.map(\.title))")
                (window.attachedSheet?.contentViewController as? NSHostingController<AskAgentView>)?.rootView.cancel()
                _ = await eventually(3) { self.window.attachedSheet == nil }
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
            } else {
                check("the lines to pick are shown", false, String(view.string.suffix(300)))
            }
        }

        // ⌘F, as the window takes it: the Logs tab's filter, not the list's.
        page.giveListTheKeyboard()
        _ = await eventually(3) { self.app.kubernetesListHasKeyboard() }
        let logFocus = page.focusLogFilter
        if let find = key("f", 3, .command) {
            check("⌘F on the Logs tab is the page's", app.handlePageKey(find) && page.focusLogFilter == logFocus + 1)
            check(
                "and gives the log's filter the keyboard",
                await eventually(5) {
                    guard let editor = self.window.firstResponder as? NSTextView, let field = editor.delegate as? NSTextField,
                        let page = self.app.kubernetesView
                    else { return false }
                    return field.isDescendant(of: page) && ["Filter the log", "Find in the log"].contains(field.placeholderString ?? "")
                }, "\(String(describing: window.firstResponder))")
        } else {
            check("a ⌘F key", false)
        }

        // Previous: the crashed container's lines. The detail follows the list.
        page.giveListTheKeyboard()
        page.selection = ["shop/worker-5c"]
        guard let worker = page.detail?.logs, page.detail?.ref.name == "worker-5c" else { return check("the detail follows to the crashing pod", false) }
        check("on its logs", page.detailTab == .logs)
        check(
            "web-7d9's stream closed with it, worker-5c's the one open",
            await eventually(5) { worker.container != nil && fake.openLogFollows == ["shop/worker-5c/\(worker.container ?? "")"] },
            "\(fake.openLogFollows)")
        check("its current log", await eventually(10) { worker.feed.lines.map(\.message) == ["worker booting again"] }, "\(worker.feed.lines.map(\.message))")
        check("Previous offered: it restarted", worker.shown?.hasPrevious == true)
        worker.pick(previous: true)
        check(
            "Previous shows the crashed container's lines",
            await eventually(10) { worker.feed.lines.map(\.message) == ["worker booting", "panic: out of cheese"] }, "\(worker.feed.lines.map(\.message))")
        check("the crashed one's lines drawn", await drawn(["panic: out of cheese"]))
        check("asked with previous, not followed", fake.requests.contains { $0.isLog && $0.path.contains("/worker-5c/") && $0.query["previous"] == "true" && $0.query["follow"] == nil })

        // Hidden with a follow open: its stream closes, and nothing is asked.
        worker.pick(previous: false)
        check("worker-5c followed again", await eventually(10) { fake.openLogStreams == 1 && worker.feed.following }, "\(worker.reading)")
        app.toggleKubernetesPage(nil)
        check("the page hidden, the log's stream closes", await eventually(5) { fake.openLogStreams == 0 }, "\(fake.openLogFollows)")
        fake.forgetRequests()
        await pause(1)
        check("and no log is asked for while hidden", !fake.requests.contains(where: \.isLog), "\(fake.requests.filter(\.isLog))")
        app.toggleKubernetesPage(nil)
        check("shown again, followed again", await eventually(10) { fake.openLogStreams == 1 && page.detail?.logs === worker }, "\(worker.reading)")

        // Another context with a follow open: the detail goes, its stream with it.
        model.select("fake-prod")
        check("on fake-prod, the detail is gone", await eventually(5) { page.detail == nil })
        check("and so is its log's stream", await eventually(5) { fake.openLogStreams == 0 }, "\(fake.openLogFollows)")
        fake.forgetRequests()
        await pause(1)
        check("no log is asked for after the context changed", !fake.requests.contains(where: \.isLog), "\(fake.requests.filter(\.isLog))")
        model.select("fake-dev")
        check(
            "back on fake-dev, its pods",
            await eventually(15) {
                model.selectedName == "fake-dev" && model.rows.sorted.map(\.id.description) == ["shop/web-7d9", "shop/worker-5c"] && model.listState == .live
            },
            "\(model.rows.sorted.map(\.id.description)) \(model.listState)")

        // Closed: nothing is read.
        page.selection = ["shop/web-7d9"]
        check("l on web-7d9 again", page.openLogs())
        check("followed", await eventually(10) { fake.openLogStreams == 1 }, "\(fake.openLogFollows)")
        page.closeDetail()
        check("the detail closed, no log is followed", await eventually(5) { fake.openLogStreams == 0 }, "\(fake.openLogStreams)")
        check("every log read by a GET", fake.requests.filter(\.isLog).allSatisfy { $0.method == "GET" } && fake.writes.isEmpty, "\(fake.writes)")
        page.showTab(.overview)
        page.selection = []
    }

    /// The value of the scenario's Secret: it must never reach the app's
    /// log, its output (testKubernetes reads both) or anything but the
    /// detail that revealed it. Fictional, the fake's alone.
    static let secretValue = "acme-e2e-pw-Zq7Lm"
    static var secretValueBase64: String { Data(secretValue.utf8).base64EncodedString() }

    /// A Secret: nothing read until Show — pressed where a person would —
    /// then one GET, its keys listed with the values masked, one revealed
    /// (another hides it), its YAML masked; a TLS Secret's certificate,
    /// its key never shown; everything dropped on moving on, on Esc and
    /// with the page hidden; and no value in the app's log. No check here
    /// prints a value: what it reads stays in the condition.
    private func kubernetesSecrets(
        _ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, key: (String, UInt16, NSEvent.ModifierFlags) -> NSEvent?
    ) async {
        let value = Self.secretValue
        // What a read of the screen looks for: the value's middle, `e2e-pw`,
        // which Vision reads as it is — its `acme` it reads as Cyrillic
        // (`асте`), and a needle it misreads would let an absence pass
        // for nothing.
        let drawnValue = String(value.dropFirst(5).prefix(6))
        let secretGETs = { fake.requests.filter { $0.path.contains("/secrets/") }.map(\.path) }
        _ = page.press(":")
        page.command?.text = "secrets"
        page.runCommand()
        check("the secrets", await eventually(10) { model.kind.fullName == "secrets" && model.rows.count == 2 })
        page.selection = ["shop/web-db"]
        guard let db = page.detail, let secret = db.secret else { return check("a Secret's detail opens", false) }
        check("a Secret's detail opens, reading nothing", db.ref.name == "web-db" && db.state == .withheld && secret.state == .hidden)
        check(
            "with what its row says: its type and how many keys", secret.listedType == "Opaque" && secret.listedKeys == 2,
            "\(secret.listedType ?? "none") \(secret.listedKeys.map(String.init) ?? "none")")
        check("and says it isn't read", await shownText(15) { $0.contains("Not read") } != nil)
        check("no Secret was asked for", secretGETs().isEmpty)

        // Show, pressed as a person presses it.
        if let button = await wordFrame("Show Values") {
            await click(at: CGPoint(x: button.midX, y: button.midY))
        } else {
            check("Show Values is drawn", false)
        }
        // Not pressed (not found drawn): by its action, so the rest still runs.
        if secret.state == .hidden { _ = page.showSecret() }
        check("Show reads it", await eventually(10) { secret.state == .shown }, "\(secret.state)")
        check("with one GET", secretGETs() == ["/api/v1/namespaces/shop/secrets/web-db"], "\(secretGETs())")
        check("its keys, every value masked", secret.entries.map(\.key) == ["password", "username"] && secret.revealed == nil)
        check("drawn masked, its length shown", await shownText(15) { $0.contains("\(value.utf8.count) bytes") } != nil)
        check("no value drawn", await notDrawn(drawnValue, besides: "\(value.utf8.count) bytes"))
        secret.reveal("password")
        check("one revealed", secret.revealed == "password" && secret.revealedText == value)
        check("and drawn", await shownText(15) { $0.contains(drawnValue) } != nil)
        secret.reveal("username")
        check("revealing another masks the first", secret.revealed == "username" && secret.revealedText == "web")
        check("no longer drawn", await notDrawn(drawnValue, besides: "username"))
        page.showTab(.yaml)
        check(
            "its YAML, every value masked",
            db.yaml.contains("password: \"***\"") && !db.yaml.contains(value) && !db.yaml.contains(Self.secretValueBase64)
                && !db.yaml.contains(KubeObjectStrip.lastApplied))
        check("its YAML drawn masked", await shownText(15) { $0.contains("username") && $0.contains("***") } != nil)
        page.showTab(.overview)

        // The next row: the first one's values go with its detail.
        page.selection = ["shop/web-tls"]
        guard let tls = page.detail?.secret else { return check("the TLS Secret's detail", false) }
        check(
            "moving on drops every value", secret.state == .hidden && !secret.holdsValues && secret.entries.isEmpty && secret.revealedText == nil,
            "\(secret.state)")
        check("the next Secret isn't read either", tls.ref.name == "web-tls" && tls.state == .hidden && secretGETs().count == 1)
        tls.show()
        check("a TLS Secret shown", await eventually(10) { tls.state == .shown }, "\(tls.state)")
        let leaf = tls.certificates.first
        check(
            "its certificate read from tls.crt", leaf?.commonName == "web.acme.example" && leaf?.alternativeNames.contains("DNS:*.shop.acme.example") == true,
            "\(leaf?.subject ?? "none")")
        check("and drawn", await shownText(15) { $0.contains("O=Acme Fake") || $0.contains("CN=web.acme.example") } != nil)
        check(
            "its key never revealed or copied",
            tls.entries.first { $0.key == "tls.key" }?.isPrivateKey == true && !tls.reveal("tls.key") && tls.copyValue("tls.key") == nil)
        check("drawn as never shown", await shownText(15) { $0.contains("never shown") } != nil)

        // Esc: closed, dropped; [ shows it again, unread.
        page.giveListTheKeyboard()
        _ = await eventually(3) { self.app.kubernetesListHasKeyboard() }
        guard let escape = key("\u{1B}", 53, []) else { return check("an Esc key", false) }
        check("Esc closes the detail", app.handlePageKey(escape) && page.detail == nil)
        check("its values with it", tls.state == .hidden && !tls.holdsValues)
        check("[ shows it again", page.press("[") && page.detail?.ref.name == "web-tls")
        check("unread", page.detail?.secret?.state == .hidden && page.detail?.state == .withheld)

        // Shown, then the page hidden: dropped.
        page.detail?.secret?.show()
        let again = page.detail?.secret
        check("shown again", await eventually(10) { again?.state == .shown })
        app.toggleKubernetesPage(nil)
        check("hiding the page drops them", again?.holdsValues == false && again?.state == .hidden)
        app.toggleKubernetesPage(nil)
        check("shown again, the page reads nothing", page.detail?.secret?.holdsValues != true)
        page.closeDetail()

        check("Secrets read only by Show", secretGETs().count == 3, "\(secretGETs())")
        check("no value in the app's log", Self.appLogMentions([value, Self.secretValueBase64]) == false)
    }

    /// Whether one read of the window draws every one of `texts`, each on
    /// a line of its own or not: Vision reads a sidebar's rows, or a
    /// field and the list under it, as separate lines.
    private func drawn(_ texts: [String], _ timeout: TimeInterval = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let lines = await readWindow().map(\.text)
            if texts.allSatisfy({ text in lines.contains { $0.contains(text) } }) { return true }
            await pause(0.3)
        } while Date() < deadline
        return false
    }

    /// Whether one read of the window draws `anchor` and not `text`: a
    /// read that found nothing (Vision failed, the window not drawn) says
    /// nothing about `text`, so it never passes — read again until one
    /// that worked does, or the time is up.
    private func notDrawn(_ text: String, besides anchor: String, _ timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let lines = await readWindow().map(\.text)
            if lines.contains(where: { $0.contains(anchor) }), !lines.contains(where: { $0.contains(text) }) { return true }
            await pause(0.3)
        } while Date() < deadline
        return false
    }

    /// Whether this process's unified log says any of `needles`: nil when
    /// the log can't be read.
    static func appLogMentions(_ needles: [String]) -> Bool? {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier), let entries = try? store.getEntries() else { return nil }
        for entry in entries {
            let message = entry.composedMessage
            if needles.contains(where: { message.contains($0) }) { return true }
        }
        return false
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
