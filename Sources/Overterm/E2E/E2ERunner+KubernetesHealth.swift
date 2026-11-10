import AppKit
import Foundation

/// Stage 3b's health checks, health across pinned contexts and diff
/// across contexts (docs/design/kubernetes/analysis.md, 3.9, 3.10,
/// decision 17; Section 9: one check each).
///
/// - **Health checks**: fake-dev's shop gains a Deployment on `:latest`
///   without probes or resources, a Service selecting nothing, an Ingress
///   to a Service that isn't there, a pod Pending for ten minutes and a
///   budget that allows no disruption. `1`'s Overview reads its bounded
///   lists once — no Secret, no ConfigMap, no watch, GETs only —, says each
///   finding (drawn) and opens one's detail, which says its own (drawn).
/// - **Pinned contexts**: a second fake as `fake-stage` (its pod crashing,
///   its Deployment not ready) and `fake-prod` pinned; the Overview shows a
///   card each, read through its own proxy as rows (drawn), and hidden,
///   neither fake is asked anything more.
/// - **Compare with…**: a Deployment of fake-dev against fake-stage's —
///   one GET there —, the diff in the changes pane, stripped, its secret
///   env value masked `(before)`/`(after)`, never itself (drawn); a Secret
///   against fake-prod asked first, then compared by keyed hashes alone.
extension E2ERunner {
    func kubernetesHealth(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, kubeconfig: URL, port: Int) async {
        let wasShowing = app.store.showingOverlay == .kubernetes
        if !wasShowing { app.toggleKubernetesPage(nil) }
        if model.selectedName != "fake-dev" { model.select("fake-dev") }
        model.setScope(.namespace("shop"))
        page.filter = ""
        page.applySelector()
        page.closeDetail()
        await kubernetesHealthChecks(model, page, fake)

        // fake-stage: a fake of its own, on 127.0.0.1, through the same stand-in kubectl.
        let stageSocket = "/tmp/ot-e2e-kube-stage-\(UUID().uuidString.prefix(6)).sock"
        let stage = FakeKubeAPI(socket: stageSocket)
        let stagePort: Int
        do {
            try stage.start()
            stagePort = try stage.listenTCP()
        } catch {
            return check("fake-stage's server starts", false, "\(error)")
        }
        defer { stage.stop() }
        stage.addNamespace("shop")
        stage.addPod("api-1", namespace: "shop", FakeKubeAPI.Pod(status: "CrashLoopBackOff", ready: 0, restarts: 4, lastRestart: "1m"))
        stage.add("deployments.apps", "api", namespace: "shop", values: ["Ready": "0/1", "Up-to-date": 1, "Available": 0])
        let stagePassword = "acme-e2e-compare-pw-stage-K3d"
        let devPassword = "acme-e2e-compare-pw-dev-T8s"
        for (api, image, password, replicas) in [(fake, "nginx:1.25", devPassword, 1), (stage, "nginx:1.27", stagePassword, 2)] {
            api.add(
                "deployments.apps", "drift", namespace: "shop", values: ["Ready": .text("\(replicas)/\(replicas)"), "Up-to-date": .integer(replicas), "Available": .integer(replicas)],
                fields: [
                    "spec": [
                        "replicas": replicas, "selector": ["matchLabels": ["app": "drift"]],
                        "template": [
                            "metadata": ["labels": ["app": "drift"]],
                            "spec": ["containers": [["name": "app", "image": image, "env": [["name": "DB_PASSWORD", "value": password], ["name": "MODE", "value": "fast"]]]]],
                        ],
                    ]
                ])
        }
        let override = model.connectOverride
        if let override {
            model.connectOverride = { context in
                context.name == "fake-stage" ? KubeSocketConnection(socket: stageSocket, context: context.name) : override(context)
            }
        }
        defer { model.connectOverride = override }
        do {
            try Self.fakeKubeconfig(port: port, kind: true, stagePort: stagePort).write(to: kubeconfig, atomically: true, encoding: .utf8)
        } catch {
            return check("the kubeconfig gains fake-stage", false, "\(error)")
        }
        model.reloadContexts()
        check(
            "fake-stage is read", await eventually(10) { model.contexts.context(named: "fake-stage") != nil }, "\(model.contexts.contexts.map(\.name))")
        check("remote, so read-only", model.contexts.context(named: "fake-stage")?.isWritable == false)
        await kubernetesPinnedHealth(model, page, stage)
        await kubernetesCompare(model, page, fake, stage, devPassword: devPassword, stagePassword: stagePassword)

        Settings.shared.set("kubernetes.pinnedContexts", nil)
        try? Self.fakeKubeconfig(port: port, kind: true).write(to: kubeconfig, atomically: true, encoding: .utf8)
        model.reloadContexts()
        _ = await eventually(10) { model.contexts.context(named: "fake-stage") == nil }
        check("fake-stage was sent no write", stage.writes.isEmpty && stage.requests.allSatisfy { $0.method == "GET" }, "\(stage.writes)")
        check("nor was fake-dev", fake.writes.isEmpty, "\(fake.writes)")
        if app.store.showingOverlay != .kubernetes { app.toggleKubernetesPage(nil) }
        page.closeDetail()
        page.showKind(.pods)
        if !wasShowing { app.toggleKubernetesPage(nil) }
    }

    private func kubernetesHealthChecks(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        fake.add(
            "deployments.apps", "lint", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1],
            fields: [
                "spec": [
                    "replicas": 1, "selector": ["matchLabels": ["app": "lint"]],
                    "template": ["metadata": ["labels": ["app": "lint"]], "spec": ["containers": [["name": "app", "image": "acme/lint:latest"]]]],
                ]
            ])
        fake.add(
            "services", "lonely", namespace: "shop", values: ["Type": "ClusterIP", "Port(s)": "80/TCP"],
            fields: ["spec": ["selector": ["app": "nobody"], "ports": [["port": 80]]]])
        fake.add(
            "ingresses.networking.k8s.io", "lint", namespace: "shop",
            fields: ["spec": ["rules": [["host": "lint.example", "http": ["paths": [["path": "/", "backend": ["service": ["name": "missing-svc", "port": ["number": 80]]]]]]]]]])
        fake.addPod(
            "pending-0", namespace: "shop", FakeKubeAPI.Pod(status: "Pending", phase: "Pending", ready: 0), created: Date().addingTimeInterval(-600))
        fake.add("poddisruptionbudgets.policy", "lint", namespace: "shop", fields: ["status": ["disruptionsAllowed": 0, "expectedPods": 1, "currentHealthy": 1]])
        guard await eventually(15, { model.discovery?.kind("poddisruptionbudgets") != nil }) else { return check("fake-dev serves PDBs", false) }
        // Argo CD's checks are the GitOps ladder's (gitops.md, G1): one
        // OutOfSync with auto-sync off (Drift, K603), one auto-sync is
        // syncing (Progressing: nothing said); the tree's Degraded one Failed (K602).
        let argo = model.discovery?.kind("applications") != nil
        check("fake-dev serves Argo CD's Applications (the tree's CRDs)", argo)
        let target = FakeKubeAPI.GitOpsCommit.target
        fake.addApplication(
            "health-drift", namespace: "shop",
            spec: ["source": ["repoURL": "https://git.acme.example/acme/fleet.git", "path": "apps/drift"], "destination": ["namespace": "shop"]],
            status: ["sync": ["status": "OutOfSync", "revision": target], "health": ["status": "Healthy"]])
        fake.addApplication(
            "health-syncing", namespace: "shop",
            spec: [
                "source": ["repoURL": "https://git.acme.example/acme/fleet.git", "path": "apps/syncing"], "destination": ["namespace": "shop"],
                "syncPolicy": ["automated": ["prune": true]],
            ],
            status: [
                "sync": ["status": "OutOfSync", "revision": target], "health": ["status": "Healthy"],
                "operationState": ["phase": "Running", "startedAt": FakeKubeAPI.time(Date().addingTimeInterval(-30))],
            ])
        defer {
            fake.delete("applications.argoproj.io", "health-drift", namespace: "shop")
            fake.delete("applications.argoproj.io", "health-syncing", namespace: "shop")
        }
        fake.forgetRequests()
        check("1 is the Overview", page.press("1") && page.section == .overview)
        let health = page.health
        check("its health checks are read", await eventually(15) { health.state == .loaded }, "\(health.state)")
        let findings = health.report.findings
        func found(_ code: String, _ said: String) -> Bool { findings.contains { $0.check.code == code && $0.subject.said == said } }
        check("a Deployment on :latest, without probes or resources", found("K105", "deployment/lint") && found("K101", "deployment/lint") && found("K103", "deployment/lint"))
        check("a Service selecting no pod", found("K201", "service/lonely"), "\(findings.map(\.sentence))")
        check("an Ingress to a Service that isn't there", found("K301", "ingress/lint"))
        check("a pod Pending for ten minutes", found("K502", "pod/pending-0"))
        check("a budget allowing no disruption", found("K401", "poddisruptionbudget/lint"))
        if argo {
            check(
                "an Application auto-sync isn't fixing: drifted (K603), said by the ladder",
                findings.contains { $0.check.code == "K603" && $0.subject.said == "application/health-drift" && $0.sentence == "Drift: OutOfSync, auto-sync off" },
                "\(findings.filter { $0.subject.kind == "Application" }.map { "\($0.check.code) \($0.subject.said) \($0.sentence)" })")
            check("one auto-sync is syncing: nothing said", !findings.contains { $0.subject.said == "application/health-syncing" })
            check(
                "a Degraded one is Failed (K602), no longer K603 too",
                found("K602", "application/tree-shop") && !found("K603", "application/tree-shop"))
            let line = KubeOverviewCards.gitOps(health.report, scope: health.scope)
            check("the Overview's GitOps line counts them", line?.text.hasPrefix("GitOps living in shop: ") == true, line?.text ?? "none")
            check("drawn on the Overview's card", await shownText(15) { $0.contains("GitOps living in shop") } != nil)
        }
        check("its count drawn by the Overview's header", await shownText(15) { $0.contains("Health: \(health.report.said)") } != nil, health.report.said)
        let reads = fake.requests.filter { !$0.isWatch && $0.query["limit"] != nil && $0.query["includeObject"] == nil }
        check("its lists bounded", reads.contains { $0.path == "/api/v1/namespaces/shop/pods" && $0.query["limit"] == String(KubeHealth.podLimit) }, "\(reads.map(\.path))")
        check("never a Secret or a ConfigMap", !fake.requests.contains { $0.path.contains("/secrets") || $0.path.contains("/configmaps") })
        check("GETs only", fake.requests.allSatisfy { $0.method == "GET" })
        check(
            "read once", fake.requests.filter { $0.path == "/apis/networking.k8s.io/v1/namespaces/shop/ingresses" && !$0.isWatch }.count == 1,
            "\(fake.requests.filter { $0.path.hasSuffix("/ingresses") })")

        // A finding opens its object's detail, which says its own.
        guard let finding = findings.first(where: { $0.check.code == "K105" }) else { return }
        page.openFinding(finding.subject)
        check(
            "a finding opens its object", await eventually(15) { page.detail?.ref.name == "lint" && page.detail?.state == .loaded },
            "\(String(describing: page.detail?.ref))")
        check("whose detail says its findings", page.detail?.health.contains { $0.check == .latestImage } == true, "\(page.detail?.health ?? [])")
        check("its findings drawn in the detail", await shownText(15) { $0.localizedCaseInsensitiveContains("health checks") } != nil)
        check("2 is Workloads", page.section == .workloads && page.health.state == .idle, "\(page.section)")
    }

    private func kubernetesPinnedHealth(_ model: KubernetesModel, _ page: KubernetesPageModel, _ stage: FakeKubeAPI) async {
        page.closeDetail()
        Settings.shared.set("kubernetes.pinnedContexts", .list(["fake-stage", "fake-prod"]))
        _ = await eventually(5) { model.pinnedContexts == ["fake-stage", "fake-prod"] }
        stage.forgetRequests()
        check("1 again", page.press("1") && page.section == .overview)
        let pinned = page.pinnedHealth
        check("a card for each pinned context, in order", await eventually(10) { pinned.cards.map(\.context) == ["fake-stage", "fake-prod"] }, "\(pinned.cards.map(\.context))")
        func summary(_ name: String) -> KubePinnedHealth.Summary? {
            guard case .read(let summary, _) = pinned.cards.first(where: { $0.context == name })?.state else { return nil }
            return summary
        }
        check("fake-stage's read", await eventually(20) { summary("fake-stage") != nil }, "\(pinned.cards.map(\.state))")
        check("its crashing pod", summary("fake-stage")?.failing == ["pod/shop/api-1 CrashLoopBackOff"], "\(String(describing: summary("fake-stage")))")
        check("its Deployment not ready", summary("fake-stage")?.notReady == ["deployment/shop/api"])
        check(
            "fake-prod's too, in the namespace the page would show it in",
            await eventually(20) { summary("fake-prod") != nil } && pinned.cards.last?.scope == model.contexts.context(named: "fake-prod").map { model.agentDefaultScope(for: $0) },
            "\(pinned.cards.map(\.state))")
        check("the cards drawn", await shownText(15) { $0.contains("fake-stage") } != nil)
        check(
            "through fake-stage's own proxy, one page of rows",
            stage.requests.contains { $0.path == "/api/v1/namespaces/shop/pods" && $0.query["limit"] == String(KubePinnedHealth.limit) && $0.query["includeObject"] == "None" },
            "\(stage.requests.map(\.path))")
        check("no watch", !stage.requests.contains(where: \.isWatch))
        // The setting edited while the Overview shows: the cards follow.
        Settings.shared.set("kubernetes.pinnedContexts", .list(["fake-prod"]))
        check(
            "the pins edited while shown: its cards follow", await eventually(10) { pinned.cards.map(\.context) == ["fake-prod"] },
            "\(pinned.cards.map(\.context))")
        check("and read", await eventually(20) { summary("fake-prod") != nil }, "\(pinned.cards.map(\.state))")
        check("2: hidden, it reads nothing", page.press("2") && pinned.cards.isEmpty && !pinned.isReading)
        await pause(0.5)
        stage.forgetRequests()
        await pause(1.5)
        check("and asks fake-stage nothing", stage.requests.isEmpty, "\(stage.requests)")
    }

    private func kubernetesCompare(
        _ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, _ stage: FakeKubeAPI, devPassword: String, stagePassword: String
    ) async {
        let diffWas = app.diffItem?.isCollapsed ?? true
        defer {
            if app.rightPane.mode == .manifest { app.rightPane.mode = .changes }
            if diffWas, app.diffItem?.isCollapsed == false { app.toggleDiff(nil) }
        }
        guard let deployments = model.discovery?.kind("deployments"), let secrets = model.discovery?.kind("secrets") else {
            return check("fake-dev serves Deployments and Secrets", false)
        }
        page.showKind(deployments)
        let ref = KubeObjectRef(context: "fake-dev", kind: deployments, namespace: "shop", name: "drift")
        page.open(ref, from: .list)
        check("drift's detail", await eventually(15) { page.detail?.ref == ref && page.detail?.state == .loaded })
        check("offers Compare with…", page.detailVerbs(for: ref).contains { $0.title == KubernetesPageModel.compareTitle && $0.unavailable == nil })
        page.openCompare(ref)
        check("its picker: the other contexts", page.picker?.items.map(\.title).contains("fake-stage") == true, "\(page.picker?.items.map(\.title) ?? [])")
        page.picker?.query = "stage"
        check("stage finds fake-stage", page.picker?.selected?.choice == .compare(context: "fake-stage", namespace: "shop"))
        stage.forgetRequests()
        page.choosePicked()
        let title = "deployment/drift: fake-dev/shop ↔ fake-stage/shop"
        check(
            "the two in the changes pane", await eventually(15) { app.kubernetesManifest.shown == .change && app.kubernetesManifest.change?.title == title },
            page.compareStatus?.text ?? app.kubernetesManifest.change?.title ?? "none")
        check("the page steps aside", app.store.showingOverlay == nil)
        check(
            "one GET of fake-stage's", stage.requests.map(\.path) == ["/apis/apps/v1/namespaces/shop/deployments/drift"] && stage.requests.allSatisfy { $0.method == "GET" },
            "\(stage.requests.map(\.path))")
        let text = app.kubernetesManifest.change?.diff.items.map(\.diff).joined() ?? ""
        let lines = text.split(separator: "\n")
        check(
            "the image and replicas differ",
            lines.contains { $0.hasPrefix("-") && $0.contains("image: nginx:1.25") } && lines.contains { $0.hasPrefix("+") && $0.contains("replicas: 2") }, text)
        check("the secret env value masked, said different", text.contains("(before)") && text.contains("(after)"))
        check("and never itself", !text.contains(devPassword) && !text.contains(stagePassword))
        check("stripped of what names each copy", !text.contains("uid:") && !text.contains("resourceVersion") && !text.contains("managedFields"))
        check("the comparison drawn", await shownText(15) { $0.contains("deployment/drift:") } != nil)

        // A Secret against production: asked first, then keys and keyed hashes.
        app.toggleKubernetesPage(nil)
        let secret = KubeObjectRef(context: "fake-dev", kind: secrets, namespace: "shop", name: "web-db")
        let asks = model.secretConsent.needsAsking("fake-prod", production: true)
        fake.forgetRequests()
        page.compare(secret, with: "fake-prod", namespace: nil)
        if asks {
            check("a Secret on production is asked first", await eventually(5) { self.window.attachedSheet != nil })
            check("naming it", sheetTexts().contains { $0.contains("fake-prod") }, "\(sheetTexts())")
            check("nothing read before the button", !fake.requests.contains { $0.path.contains("/secrets/") })
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        } else {
            note("fake-prod's Secrets were shown this session already: not asked again")
        }
        check(
            "compared", await eventually(15) { app.kubernetesManifest.change?.title == "secret/web-db: fake-dev/shop ↔ fake-prod/shop" },
            page.compareStatus?.text ?? app.kubernetesManifest.change?.title ?? "none")
        let item = app.kubernetesManifest.change?.diff.items.first
        check("the same on both: unchanged", item?.change == .unchanged, "\(String(describing: item?.change)) \(item?.diff ?? "")")
        check("by its keys and keyed hashes, said", app.kubernetesManifest.change?.label.contains("hash keyed for this comparison") == true)
        check(
            "one GET a side", fake.requests.filter { $0.path == "/api/v1/namespaces/shop/secrets/web-db" }.count == 2,
            "\(fake.requests.map(\.path))")
        check("production said in the pane", app.kubernetesManifest.change?.production == true)
    }
}
