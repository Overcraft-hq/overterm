import AppKit
import Foundation

/// Stage 3a's check (docs/design/kubernetes/analysis.md, Section 9, 3.13
/// and 2.12), in the `kubernetes` scenario against `FakeKubeAPI` — never a
/// real cluster, and no helm ever run but a stand-in of the run's own:
///
/// - **Attention marks.** A fixture checkout bound to fake-dev/shop (in
///   the run's support folder) with a tab open: its Pods and Deployments
///   watched in the background — the binding's selector the server's, the
///   page hidden —, a pod going into CrashLoopBackOff marking that tab
///   (its menu and the Inbox offering Ask Why, whose brief carries the
///   pod, the checkout and its deployed commit, scrubbed), a stuck
///   rollout marking it again, both gone clearing it; another context's
///   page taking the background proxy's slot (`maxProxies` 2, every slot
///   busy) closes it, the tab says "not watched", and once a slot is free
///   it is watched again. The tab closed, the watches end.
/// - **Helm upgrade from the checkout's chart.** The bound release `web`:
///   Diff Chart with Release renders the checkout's chart with the
///   release's values on the stand-in's stdin (`KUBECONFIG=/dev/null`, no
///   values file anywhere), the Secret and the Deployment diffed masked in
///   the changes pane; Upgrade… refused on fake-dev (read-only), reviewed,
///   asked and **recorded, not typed** on kind-fake, the name asked on
///   fake-prod with writes on. Only reviews reach the fake.
extension E2ERunner {
    func kubernetesAttention(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, realProxy: Bool) async {
        let attention = KubeAttentionWatches.shared
        if app.store.showingOverlay != nil { app.hideOverlay(focus: false) }
        _ = await eventually(5) { fake.openWatches == 0 }
        let opened = Set(app.store.tabs.map(\.id))
        let previous = app.store.selected
        var recorded: [(command: String, tab: Tab)] = []
        recordKubernetesCommands { recorded.append(($0, $1)) }
        defer {
            app.kubernetesCommandRecorder = nil
            app.kubernetesBriefRecorder = nil
            Settings.shared.set("kubernetes.maxProxies", nil)
            Settings.shared.set("kubernetes.helmPath", nil)
            app.closeTabsWithoutAsking(app.store.tabs.filter { !opened.contains($0.id) })
            if let previous { app.store.select(previous) }
        }

        // The fixture checkout: a chart for the release `web`.
        let repo = scratch.appendingPathComponent("ot-kube-attn", isDirectory: true)
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.createDirectory(at: repo.appendingPathComponent("chart/templates"), withIntermediateDirectories: true)
        try? "apiVersion: v2\nname: web\nversion: 1.5.0\nappVersion: \"1.27\"\n".write(
            to: repo.appendingPathComponent("chart/Chart.yaml"), atomically: true, encoding: .utf8)
        try? "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: {{ .Release.Name }}\n".write(
            to: repo.appendingPathComponent("chart/templates/deployment.yaml"), atomically: true, encoding: .utf8)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        try? await git(["add", "chart"], in: repo)
        try? await git(["commit", "-q", "-m", "chart"], in: repo)
        let key = KubeBindingStore.key(repo)
        let part = ["app.kubernetes.io/part-of": "ot-attn"]
        let selector = "app.kubernetes.io/part-of=ot-attn"
        fake.add(
            "deployments.apps", "attn-api", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1, "Images": "ghcr.io/acme/attn:1.0"],
            labels: part, fields: ["status": ["conditions": [["type": "Progressing", "status": "True", "reason": "NewReplicaSetAvailable"]]]])
        fake.addPod("attn-api-1", namespace: "shop", labels: part)
        defer {
            fake.deletePod("attn-api-1", namespace: "shop")
            fake.delete("deployments.apps", "attn-api", namespace: "shop")
        }

        // Its tab, then another selected: the run's window is never key, so
        // a mark always stands; the checkout bound.
        app.newTab(in: repo)
        guard let tab = app.store.selected, app.kubernetesCheckoutKey(tab) == key else {
            return check("the bound checkout's tab opens", false, app.store.selected.flatMap(app.kubernetesCheckoutKey) ?? "none")
        }
        if let previous { app.store.select(previous) }
        fake.forgetRequests()
        check(
            "bound to fake-dev/shop with a release and a selector",
            KubeBindingStore.shared.set(KubeBinding(checkout: key, context: "fake-dev", namespace: "shop", release: "web", selector: selector)))
        defer { KubeBindingStore.shared.remove(repo) }
        let scope = KubeAttentionBudget.Scope(context: "fake-dev", namespace: "shop", selector: selector)
        check(
            "its pods and deployments are watched in the background",
            await eventually(15) { attention.state(of: scope) == .watching && fake.watched.filter { $0 == "pods" || $0 == "deployments.apps" }.count >= 2 },
            "\(String(describing: attention.state(of: scope))) \(fake.watched)")
        check("with the page hidden", app.store.showingOverlay != .kubernetes)
        check(
            "the binding's selector the server's, in its namespace",
            fake.requests.filter { $0.path.hasSuffix("/namespaces/shop/pods") || $0.path.hasSuffix("/namespaces/shop/deployments") }.allSatisfy {
                $0.query["labelSelector"] == selector
            } && fake.requests.contains { $0.path.hasSuffix("/deployments") && $0.query["includeObject"] == "Object" },
            "\(fake.requests.map { "\($0.path)?\($0.query)" })")
        check("and nothing else read", fake.requests.allSatisfy { $0.path.hasSuffix("/pods") || $0.path.hasSuffix("/deployments") }, "\(fake.requests)")
        check("the tab is watched", tab.kubeNotWatched == nil)

        // A crash marks the checkout's tab.
        fake.updatePod("attn-api-1", namespace: "shop") {
            $0.status = "CrashLoopBackOff"
            $0.ready = 0
            $0.restarts = 3
        }
        let crash = "pod/attn-api-1 CrashLoopBackOff — fake-dev · shop"
        check(
            "a crash marks the bound checkout's tab", await eventually(10) { tab.activity.mark == .failed && tab.activity.note == crash },
            "\(tab.activity.mark) \(tab.activity.note ?? "none")")
        check("only that tab", app.store.tabs.filter { $0 !== tab && $0.activity.note == crash }.isEmpty)
        check(
            "its menu offers Ask Why", app.menu(for: tab).items.contains { $0.title == "Ask an Agent Why… (pod/attn-api-1 CrashLoopBackOff)" },
            "\(app.menu(for: tab).items.map(\.title))")
        app.refreshInbox()
        check("so does the Inbox", app.inbox.entries.first { $0.id == tab.id }.map { $0.asksWhy && $0.note == crash } == true)
        var asked: KubeAgentBrief?
        app.kubernetesBriefRecorder = { brief, _ in asked = brief }
        app.askWhy(onMarkOf: tab)
        check("Ask Why on the mark reads the pod's brief", await eventually(15) { asked != nil }, app.kubernetesAttentionProblem ?? "")
        if let asked {
            check("about the pod that crashed", asked.subject.contains("attn-api-1") && asked.message.contains("CrashLoopBackOff"), asked.subject)
            check("for the checkout, its deployed commit with it", asked.checkout == repo.path && asked.deployedCommit != nil, asked.checkout ?? "none")
        }

        // A stuck rollout marks it too.
        fake.setFields(
            "deployments.apps", "attn-api", namespace: "shop",
            ["status": ["conditions": [["type": "Progressing", "status": "False", "reason": "ProgressDeadlineExceeded"]]]])
        let stuck = "deploy/attn-api rollout stuck (ProgressDeadlineExceeded) — fake-dev · shop"
        check("a stuck rollout marks it", await eventually(10) { tab.activity.note == stuck }, tab.activity.note ?? "none")
        check("Ask Why goes to the newest", tab.kubeAlerts.map(\.object) == ["deploy/attn-api", "pod/attn-api-1"], "\(tab.kubeAlerts.map(\.object))")
        check("drawn in the strip", await shownText(15) { $0.contains("ot-kube-attn") } != nil)

        // Both gone: the mark goes.
        fake.deletePod("attn-api-1", namespace: "shop")
        fake.setFields(
            "deployments.apps", "attn-api", namespace: "shop",
            ["status": ["conditions": [["type": "Progressing", "status": "True", "reason": "NewReplicaSetAvailable"]]]])
        check("both gone, the mark goes", await eventually(10) { tab.activity.mark == .none && tab.kubeAlerts.isEmpty }, "\(tab.activity.mark)")
        fake.addPod("attn-api-1", namespace: "shop", labels: part)

        // The tab's agent waiting for you (a higher mark): a crash keeps that
        // mark but is still told, and the Inbox still offers Ask Why.
        await pause(0.5)
        _ = tab.activity.handle(.bell, visible: false)
        let notices = app.clusterNotices
        fake.updatePod("attn-api-1", namespace: "shop") { $0.status = "CrashLoopBackOff" }
        check(
            "under a waiting mark, a crash is still told", await eventually(10) { app.clusterNotices == notices + 1 && !tab.kubeAlerts.isEmpty },
            "\(app.clusterNotices) \(tab.kubeAlerts.map(\.object))")
        check("the waiting mark kept", tab.activity.mark == .waiting, "\(tab.activity.mark)")
        app.refreshInbox()
        check("the Inbox offers Ask Why on it", app.inbox.entries.first { $0.id == tab.id }?.asksWhy == true)
        fake.deletePod("attn-api-1", namespace: "shop")
        check("the pod gone, its alert goes, the waiting mark stays", await eventually(10) { tab.kubeAlerts.isEmpty } && tab.activity.mark == .waiting)
        tab.activity.seen()
        fake.addPod("attn-api-1", namespace: "shop", labels: part)

        // The page takes the background's slot; "not watched" until one is free.
        if realProxy {
            await kubernetesAttentionSlot(model, tab, scope, fake)
        } else {
            note("no kubectl installed: the proxies' slots aren't exercised")
        }

        await kubernetesHelmUpgrade(model, page, fake, tab: tab, repo: repo, recorded: { recorded })

        // Its tabs closed (the upgrade's opened in the checkout too): the watches end.
        app.closeTabsWithoutAsking(app.store.tabs.filter { !opened.contains($0.id) })
        check("its tab closed, its watches end", await eventually(10) { attention.watchedScopes.isEmpty }, "\(attention.watchedScopes)")
        check("only reviews reached the fake", fake.writes.allSatisfy(\.isAccessReview), "\(fake.writes.filter { !$0.isAccessReview })")
    }

    /// `maxProxies` 2: the page on kind-fake, held busy, and the attention
    /// watches on fake-dev take both; the page moving to fake-prod closes
    /// the background one — "not watched" — and once kind-fake is let go,
    /// a slot is free and fake-dev is watched again.
    private func kubernetesAttentionSlot(_ model: KubernetesModel, _ tab: Tab, _ scope: KubeAttentionBudget.Scope, _ fake: FakeKubeAPI) async {
        let attention = KubeAttentionWatches.shared
        let proxies = KubeProxies.shared
        Settings.shared.set("kubernetes.maxProxies", .int(2))
        await proxies.configure(Settings.shared.kubernetesProxyConfiguration)
        // Only the attention's proxy left from what ran before: each context the page moves to opens one.
        for name in await proxies.connected where name != "fake-dev" { await proxies.close(name) }
        app.showKubernetesPage()
        model.select("kind-fake")
        model.setScope(.namespace("shop"))
        check("the page on kind-fake", await eventually(15) { model.selectedName == "kind-fake" && model.listState == .live }, "\(model.listState)")
        check(
            "the attention watches have their background slot", await eventually(30) { attention.state(of: scope) == .watching },
            "\(String(describing: attention.state(of: scope)))")
        _ = await eventuallyAsync(10) { Set(await proxies.connected) == ["fake-dev", "kind-fake"] }
        // kind-fake held busy, as a page's long read holds it.
        let holder = Task { [model] in
            guard let client = model.client(for: "kind-fake") else { return }
            for try await _ in client.follow(.deployments, in: .namespace("shop")) {}
        }
        await pause(1)
        model.select("fake-prod")
        let closed = await eventuallyAsync(15) { await proxies.closedForPage.first == "fake-dev" }
        let connected = await proxies.connected
        check("the page needing a slot closes the background proxy", closed, "\(connected)")
        check("its checkout's tab says it isn't watched", await eventually(15) { tab.kubeNotWatched != nil }, "\(String(describing: attention.state(of: scope)))")
        check("drawn in the strip", await shownText(15) { $0.contains("not watched") } != nil)
        check("the page has its slot", await eventually(15) { model.selectedName == "fake-prod" && model.listState == .live }, "\(model.listState)")
        holder.cancel()
        _ = await holder.result
        check(
            "a slot free again, it is watched again", await eventually(40) { attention.state(of: scope) == .watching && tab.kubeNotWatched == nil },
            "\(String(describing: attention.state(of: scope)))")
        Settings.shared.set("kubernetes.maxProxies", nil)
        await proxies.configure(Settings.shared.kubernetesProxyConfiguration)
        model.select("fake-dev")
        check("fake-dev's version read again", await eventually(15) { model.selectedName == "fake-dev" && model.version != nil })
        app.hideOverlay(focus: false)
    }

    /// `eventually`, for a condition that asks an actor.
    private func eventuallyAsync(_ timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            if Date() > deadline { return false }
            await pause(0.05)
        }
        return true
    }

    /// The bound release against the checkout's chart, and its upgrade.
    private func kubernetesHelmUpgrade(
        _ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, tab: Tab, repo: URL, recorded: () -> [(command: String, tab: Tab)]
    ) async {
        let panel = app.kubernetesPanel
        let password = "acme-e2e-helm-pw-T7m2"
        let newPassword = "acme-e2e-helm-pw-new-V9"
        // A stand-in helm: it says what it was given — never the values —
        // and renders the release's Secret and Deployment changed.
        let log = scratch.appendingPathComponent("helm-stand-in.log")
        let script = scratch.appendingPathComponent("helm-stand-in")
        try? FileManager.default.removeItem(at: log)
        let rendered = """
            ---
            # Source: web/templates/secret.yaml
            apiVersion: v1
            kind: Secret
            metadata:
              name: web-auth
            data:
              password: \(Data(newPassword.utf8).base64EncodedString())
            ---
            # Source: web/templates/deployment.yaml
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: web
            spec:
              replicas: 3
            """
        let body = """
            #!/bin/sh
            input=$(cat)
            case "$input" in *apiToken*) given=yes ;; *) given=no ;; esac
            printf '%s|KUBECONFIG=%s|values=%s\\n' "$*" "$KUBECONFIG" "$given" >> '\(log.path)'
            cat <<'YAML'
            \(rendered)
            YAML
            """
        try? body.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        Settings.shared.set("kubernetes.helmPath", .string(script.path))

        let sidebarWas = (app.sidebarItem?.isCollapsed ?? true, app.sidebarPanel.panel)
        let diffWas = app.diffItem?.isCollapsed ?? true
        defer {
            app.sidebarPanel.panel = sidebarWas.1
            if sidebarWas.0, app.sidebarItem?.isCollapsed == false { app.toggleFileTree(nil) }
            if app.rightPane.mode == .manifest { app.rightPane.mode = .changes }
            if diffWas, app.diffItem?.isCollapsed == false { app.toggleDiff(nil) }
        }
        app.store.select(tab)
        app.showKubernetesPanel(nil)
        check("the panel shows the bound release", await eventually(10) { panel.binding?.release == "web" }, "\(String(describing: panel.binding))")
        check("its buttons drawn", await shownText(15) { $0.contains("Diff Chart") } != nil)
        fake.forgetRequests()
        panel.diffChart()
        check("Diff Chart with Release", await eventually(20) { panel.helmUpgrade?.result != nil }, "\(String(describing: panel.helmUpgrade?.state))")
        let said = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        check(
            "helm template of the checkout's chart, the release's values on its stdin",
            said.contains("template web \(repo.appendingPathComponent("chart").standardizedFileURL.path) --namespace shop --values - --is-upgrade")
                && said.contains("values=yes"), said)
        check("reaching no cluster", said.contains("KUBECONFIG=/dev/null"), said)
        check(
            "told the cluster's version and the groups it serves, as helm upgrade will see them",
            said.contains("--kube-version v1.") && said.contains("--api-versions ") && said.contains("apps/v1/Deployment"), said)
        check("no values file written", !said.contains(password) && ((try? FileManager.default.contentsOfDirectory(atPath: repo.path)) ?? []).sorted() == [".git", "chart"])
        if let result = panel.helmUpgrade?.result {
            check("against revision 2", result.revision == 2 && result.context == "fake-dev")
            check(
                "the Secret and the Deployment changed",
                result.diff.items.map(\.id) == ["Secret/shop/web-auth", "Deployment/shop/web"]
                    && result.diff.items.allSatisfy { $0.change == .modified }, "\(result.diff.items.map(\.id))")
            let text = result.diff.items.map(\.diff).joined()
            check("the Secret masked, before and after", text.contains("*** (before)") && text.contains("*** (after)"), text)
            check(
                "no value in it",
                !text.contains(password) && !text.contains(newPassword) && !text.contains(Data(password.utf8).base64EncodedString())
                    && !text.contains(Data(newPassword.utf8).base64EncodedString()))
            check("the replicas said", text.contains("+  replicas: 3"), text)
        }
        check("in the changes pane", app.rightPane.mode == .manifest && app.kubernetesManifest.showsHelm && app.kubernetesManifest.helm === panel.helmUpgrade)
        check("drawn", await shownText(15) { $0.contains("would change") } != nil)
        check("the release's one record read, its list metadata only", fake.requests.filter { $0.path.contains("/secrets/") }.count == 1, "\(fake.requests)")

        // fake-dev is read-only: refused, nothing sent.
        fake.forgetRequests()
        panel.upgradeChart()
        check(
            "Upgrade… refused on fake-dev",
            await eventually(15) { panel.helmUpgrade?.state == .failed(KubeProcessCheck.readOnly(.remote)) }, "\(String(describing: panel.helmUpgrade?.state))")
        check("nothing recorded, no review", recorded().isEmpty && fake.writes.isEmpty && window.attachedSheet == nil)

        // kind-fake: reviewed, asked, recorded.
        let kindKey = KubeBindingStore.key(repo)
        _ = KubeBindingStore.shared.set(KubeBinding(checkout: kindKey, context: "kind-fake", namespace: "shop", release: "web"))
        check("bound to kind-fake", await eventually(10) { panel.binding?.context == "kind-fake" })
        panel.upgradeChart()
        check(
            "the upgrade is asked", await eventually(20) { self.sheetTexts().contains { $0.contains("Upgrade Helm release shop/web from the checkout's chart?") } },
            "\(String(describing: panel.helmUpgrade?.state)) \(sheetTexts())")
        let line =
            KubeHelmWrite.prefix(.secret).joined(separator: " ")
            + " helm upgrade web \(repo.appendingPathComponent("chart").standardizedFileURL.path) --reset-then-reuse-values --kube-context kind-fake -n shop"
        check(
            "naming kind-fake and shop, what changes and the helm it runs",
            sheetTexts().contains { $0.contains("kind-fake · namespace shop") } && sheetTexts().contains { $0.contains(line) }
                && sheetTexts().contains { $0.contains("2 of 2 objects would change") }, "\(sheetTexts())")
        check("after the cluster's access review", fake.requests.contains(where: \.isAccessReview))
        check("no name asked off production", typedNameField() == nil)
        check("nothing recorded while it asks", recorded().isEmpty)
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check("confirmed, it is recorded, not typed", await eventually(10) { recorded().count == 1 }, "\(String(describing: panel.helmUpgrade?.state))")
        check("helm upgrade, its context and namespace said", recorded().first?.command == line, recorded().first?.command ?? "")
        check(
            "the shell's helm server, token and user unset, the driver said",
            ["-u HELM_KUBEAPISERVER", "-u HELM_KUBETOKEN", "-u HELM_KUBEASUSER", "HELM_DRIVER=secret helm upgrade"].allSatisfy {
                recorded().first?.command.contains($0) == true
            }, recorded().first?.command ?? "")
        check(
            "in a tab pinned to kind-fake", recorded().first?.tab.kubePin?.context == "kind-fake" && recorded().first?.tab.kubePin?.namespace == "shop")

        // fake-prod with writes on: the values asked for, the name typed.
        await model.setProductionWrites(true, for: "fake-prod")
        _ = KubeBindingStore.shared.set(KubeBinding(checkout: kindKey, context: "fake-prod", namespace: "shop", release: "web"))
        check("bound to fake-prod", await eventually(10) { panel.binding?.context == "fake-prod" })
        app.store.select(tab)
        panel.upgradeChart()
        if await eventually(15, { self.sheetTexts().contains { $0.contains("Read this release's values") } }) {
            check("its values asked for first, naming it", sheetTexts().contains { $0.contains("fake-prod") })
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        }
        check("the upgrade asks for the name", await eventually(20) { self.typedNameField() != nil }, "\(String(describing: panel.helmUpgrade?.state))")
        check("PRODUCTION, fake-prod and shop", sheetTexts().contains { $0.contains("PRODUCTION · fake-prod · namespace shop") }, "\(sheetTexts())")
        typedNameField()?.stringValue = "wbe"
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check(
            "a wrong name runs nothing",
            await eventually(10) { panel.helmUpgrade?.state == .failed("The name typed wasn't web: nothing was run.") } && recorded().count == 1)
        await model.setProductionWrites(false, for: "fake-prod")
    }
}
