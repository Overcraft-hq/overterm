import AppKit

/// A checkout tied to what it deploys (docs/design/kubernetes/analysis.md,
/// 3.1–3.2, stage 3a), in the `kubernetes` scenario against `FakeKubeAPI`:
/// a fixture git checkout of the run's own (`ot-kube-shop`, its manifest
/// naming namespace shop and `app.kubernetes.io/part-of: ot-shop`), its tab
/// selected, the rail's Kubernetes panel guessing from its files without
/// asking any cluster, bound to fake-dev/shop — kept in the run's own
/// support folder, nothing written into the repository —, then showing the
/// bound workload and its pod (the selector the server's), the deployed
/// commit answered against the checkout, Diff Deployed…Current opening a
/// review tab, a pod in the right slot, Ask Why's brief carrying the
/// deployed commit and offered to the checkout's agent first, agents'
/// tools defaulting to the binding — and hidden, the panel asks nothing
/// while the right slot keeps its pod.
extension E2ERunner {
    func kubernetesCheckout(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        let panel = app.kubernetesPanel
        // The panel alone here: the attention watches (3.13) are
        // `kubernetesAttention`'s, and would keep two watches open.
        Settings.shared.set("kubernetes.notifyOnFailure", .bool(false))
        defer { Settings.shared.set("kubernetes.notifyOnFailure", nil) }
        if app.store.showingOverlay != nil { app.hideOverlay(focus: false) }
        _ = await eventually(5) { fake.openWatches == 0 }

        // The fixture checkout: c1 deployed, c2 on a branch not yet.
        let repo = scratch.appendingPathComponent("ot-kube-shop", isDirectory: true)
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.createDirectory(at: repo.appendingPathComponent("k8s"), withIntermediateDirectories: true)
        let manifest =
            "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: shop-api\n  namespace: shop\n  labels:\n    app.kubernetes.io/part-of: ot-shop\n"
        try? manifest.write(to: repo.appendingPathComponent("k8s/api.yaml"), atomically: true, encoding: .utf8)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        try? await git(["add", "k8s/api.yaml"], in: repo)
        try? await git(["commit", "-q", "-m", "shop-api"], in: repo)
        let c1 = ((try? await Git.run(["rev-parse", "HEAD"], in: repo)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        try? await git(["checkout", "-q", "-b", "fix/orders"], in: repo)
        try? "fix\n".write(to: repo.appendingPathComponent("FIX"), atomically: true, encoding: .utf8)
        try? await git(["add", "FIX"], in: repo)
        try? await git(["commit", "-q", "-m", "the fix"], in: repo)
        guard c1.count == 40 else { return check("the fixture checkout is made", false, c1) }
        let short = String(c1.prefix(7))

        let part = ["app.kubernetes.io/part-of": "ot-shop"]
        fake.add(
            "deployments.apps", "shop-api", namespace: "shop",
            values: ["Ready": "0/1", "Up-to-date": 1, "Available": 0, "Images": .text("ghcr.io/acme/shop-api:\(short)")], labels: part)
        var crashing = FakeKubeAPI.Pod(status: "CrashLoopBackOff", phase: "Running", ready: 0, containers: 1, restarts: 3, lastRestart: "20s")
        crashing.image = "ghcr.io/acme/shop-api:\(short)"
        fake.addPod("shop-api-1", namespace: "shop", crashing, labels: part)

        // An agent tab in the checkout, its agent not started, and a shell tab there selected.
        let previous = app.store.selected
        app.newTab(in: repo, agent: .claude, startAgent: false)
        let agentTab = app.store.selected
        agentTab?.customTitle = "ot-kube-shop · claude"
        app.newTab(in: repo)
        guard let tab = app.store.selected, tab !== agentTab, let agentTab else { return check("the checkout's tabs open", false) }
        let real = FileTreeModel.realPath(repo)
        check(
            "the panel follows the selected tab's checkout",
            await eventually(10) { panel.checkout.map(FileTreeModel.realPath) == real }, panel.checkout?.path ?? "none")

        // Not on screen yet: nothing read.
        fake.forgetRequests()
        await pause(0.5)
        check("off screen the panel reads nothing", panel.guess == nil && fake.requests.isEmpty, "\(fake.requests)")

        app.showKubernetesPanel(nil)
        check("the rail's helm shows the panel", app.sidebarPanel.panel == .kubernetes && panel.panelVisible)
        check(
            "unbound, it guesses from the checkout's files",
            await eventually(10) { panel.guess?.namespace == "shop" && panel.guess?.selector == "app.kubernetes.io/part-of=ot-shop" },
            "\(String(describing: panel.guess))")
        check("and the guess asked no cluster", fake.requests.isEmpty, "\(fake.requests)")
        check("it says what it found, and offers to bind", await shownText(15) { $0.contains("Bind to a") } != nil)

        panel.beginEdit()
        check("Bind starts from the guess, on the page's context", await eventually(5) { panel.draft?.context == "fake-dev" && panel.draft?.namespace == "shop" })
        check("the picker lists the kubeconfig's contexts", panel.contextNames == ["fake-dev", "fake-prod"], "\(panel.contextNames)")
        check("bound", panel.saveDraft() && panel.binding?.context == "fake-dev")
        let file = AppEnvironment.supportDirectory.appendingPathComponent("Kubernetes/bindings.json")
        let saved = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check("kept in the run's own support folder, by the checkout's path", saved.contains(real) && saved.contains("\"namespace\" : \"shop\""), saved)
        let status = ((try? await Git.run(["status", "--porcelain", "--ignored"], in: repo)) ?? "?").trimmingCharacters(in: .whitespacesAndNewlines)
        check("nothing is written into the repository", status.isEmpty, status)

        // Bound: its workload and pod, the selector the server's.
        check(
            "the rail shows the bound workload and its pod",
            await eventually(15) { panel.state == .live && panel.workloads.map(\.id) == ["deploy/shop-api"] && panel.pods.map(\.id.name) == ["shop-api-1"] },
            "\(panel.state) \(panel.workloads.map(\.id)) \(panel.pods.map(\.id.name))")
        check("its health said", panel.workloads.first?.failing == true && panel.pods.first?.summary.status == "CrashLoopBackOff")
        check(
            "asked of the server by the binding's selector, in its namespace",
            fake.requests.contains {
                $0.path == "/apis/apps/v1/namespaces/shop/deployments" && $0.query["labelSelector"] == "app.kubernetes.io/part-of=ot-shop"
            } && fake.requests.contains { $0.path == "/api/v1/namespaces/shop/pods" && $0.query["labelSelector"] == "app.kubernetes.io/part-of=ot-shop" },
            "\(fake.requests.map { "\($0.path)?\($0.query)" })")
        check("drawn", await shownText(15) { $0.contains("shop-api-1") } != nil)

        // The deployed commit (3.2): the image's tag, looked up in the checkout.
        let expected = "deployed \(short), up to date with main; this branch is 1 commit ahead"
        check(
            "the deployed commit is answered against the checkout",
            await eventually(10) { panel.deployed["deploy/shop-api"]?.text == expected }, panel.deployed["deploy/shop-api"]?.text ?? "none")
        check("from the image's tag", panel.headline?.answer.sourceSaid == "from the image's tag")
        check("and drawn", await shownText(15) { $0.contains("1 commit ahead") } != nil)

        // Diff deployed…current: a review tab for the range.
        if let found = panel.deployed["deploy/shop-api"]?.found {
            panel.reviewDeployed(found)
            let review = app.store.reviews.first { $0.source == .range(base: c1, head: "HEAD") }
            check("Diff Deployed…Current opens a review tab for the range", review != nil && app.store.reviewShowing == review?.id, "\(app.store.reviews.map(\.source))")
            if let review { app.closeReview(review) }
        } else {
            check("Diff Deployed…Current opens a review tab for the range", false, "no commit found")
        }

        // A pod in the right slot: its object read once it shows there.
        panel.pick(KubeRowID(namespace: "shop", name: "shop-api-1"))
        check("a pod picked takes the right slot", await eventually(5) { self.app.rightPane.mode == .kubernetes && panel.slotVisible })
        check(
            "its object is read for it",
            await eventually(10) { panel.session?.state == .loaded && fake.requests.contains { $0.path == "/api/v1/namespaces/shop/pods/shop-api-1" } },
            "\(String(describing: panel.session?.state))")

        // Ask Why (3.4): the brief carries the deployed commit and goes to the checkout's agent first.
        let actions = page.actions
        var asked: KubeAgentBrief?
        page.actions?.askWhy = { asked = $0 }
        page.askWhy(KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "shop-api-1"))
        check("Ask Why's brief is read", await eventually(15) { asked != nil }, page.commandProblem ?? "")
        page.actions = actions
        if let brief = asked {
            check(
                "it carries the bound checkout's deployed commit",
                brief.parts.contains { $0.title == "deployed commit" && $0.text.contains(expected) }, brief.deployedCommit ?? "none")
            check("and offers the checkout's agent first", app.kubernetesBriefTargets(brief).first === agentTab, "\(app.kubernetesBriefTargets(brief).map(\.title))")
        }

        // Agents' tools from a pane of the checkout: the binding's context and namespace.
        let tag = tab.terminal.processTag
        let list = await model.contextsForAgents() ?? KubeContextList()
        check("a pane of the checkout has its binding", KubeMCP.binding(for: tag, in: list)?.namespace == "shop")
        if let dev = list.context(named: "fake-dev") {
            check("its tools default to the binding's namespace", KubeMCP.defaultScope(for: dev, list: list, kubernetes: model, pane: tag) == .namespace("shop"))
        }
        if let result = try? await KubeMCP.call("k8s_get", ["kind": "deployments"], kubernetes: model, pane: tag),
            let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String
        {
            check("k8s_get there reads the bound namespace", text.contains("namespace shop") && text.contains("shop-api"), text)
        } else {
            check("k8s_get there reads the bound namespace", false)
        }

        // Hidden, the panel asks nothing.
        app.sidebarPanel.panel = .files
        check("hidden, the panel's watches end", await eventually(5) { !panel.panelVisible && fake.openWatches == 0 }, "\(fake.openWatches) open")
        check("and nothing stale is kept", panel.workloads.isEmpty && panel.pods.isEmpty)
        let slotPod = KubeRowID(namespace: "shop", name: "shop-api-1")
        check(
            "the right slot keeps its pod while the rail shows another panel",
            panel.picked == slotPod && panel.session?.state == .loaded && app.rightPane.mode == .kubernetes,
            "\(String(describing: panel.picked)) \(String(describing: panel.session?.state))")
        // The slot put aside too: its log stops, and nothing more is read.
        app.rightPane.mode = .changes
        app.updateRightPaneVisibility()
        check("the slot hidden, its log is not read", await eventually(5) { !panel.slotVisible })
        fake.forgetRequests()
        fake.addPod("shop-api-2", namespace: "shop", labels: part)
        await pause(1.5)
        check("the rail reads nothing while hidden", fake.requests.isEmpty, "\(fake.requests)")
        app.showKubernetesPanel(nil)
        check("shown again it reads again", await eventually(15) { panel.pods.map(\.id.name) == ["shop-api-1", "shop-api-2"] }, "\(panel.pods.map(\.id.name))")
        app.showKubernetesSlot()
        check("and the slot shows the same pod again", panel.slotVisible && panel.picked == slotPod && panel.session?.state == .loaded)
        check("only GETs", fake.writes.isEmpty, "\(fake.writes)")
        check("and no Secret", !fake.requests.contains { $0.path.contains("/secrets") })

        // Back as it was.
        panel.unbind()
        app.sidebarPanel.panel = .files
        if app.rightPane.mode == .kubernetes { app.rightPane.mode = .changes }
        _ = await eventually(5) { fake.openWatches == 0 }
        app.closeTabsWithoutAsking([tab, agentTab])
        if let previous { app.store.select(previous) }
        fake.deletePod("shop-api-1", namespace: "shop")
        fake.deletePod("shop-api-2", namespace: "shop")
        fake.delete("deployments.apps", "shop-api", namespace: "shop")
    }
}
