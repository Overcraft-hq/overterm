import AppKit
import Foundation

/// Stage 2a's writes in a tab and agents' writes, against the fake API
/// server, never a real cluster.
///
/// In a tab: on `fake-dev` (read-only) a node's drain is greyed with why
/// and refused — nothing recorded, nothing sent; on `kind-fake` (local, so
/// writable) the drain is reviewed (SelfSubjectAccessReview: patch nodes,
/// create pods/eviction), asked in the window's sheet naming the context
/// and its kubectl, then **recorded, not typed** — the command and its tab
/// pinned to the context; a Deployment's rollback picks a revision from its
/// ReplicaSets, each with its image; `E` on a pod adds a debug container
/// with the setting's image. Only reviews reach the fake.
///
/// Agents: through the app's MCP endpoint, the bridge's HTTP with its
/// token, as Claude Code in a pane would call it — with
/// `kubernetes.agentWrites` empty no write tool is listed and a
/// `k8s_scale` on `kind-fake`, writable though it is, is refused; once it
/// names `kind-fake` they are listed, `k8s_scale` there is asked in the
/// window (the runner answers) and lands on the fake; a declined
/// `k8s_delete_pod` sends nothing. With only `fake-dev` and `fake-prod`, a
/// write on fake-prod is refused, and once its writes are on for the
/// session still refused until `kubernetes.agentWrites` names it; then a
/// delete there asks for the pod's name, and a wrong one sends nothing.
extension E2ERunner {
    func kubernetesTabWrites(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        let wasShowing = app.store.showingOverlay == .kubernetes
        if !wasShowing { app.toggleKubernetesPage(nil) }
        defer { if !wasShowing, app.store.showingOverlay == .kubernetes { app.toggleKubernetesPage(nil) } }
        let opened = Set(app.store.tabs.map(\.id))
        var recorded: [(command: String, tab: Tab)] = []
        recordKubernetesCommands { recorded.append(($0, $1)) }
        defer {
            app.kubernetesCommandRecorder = nil
            app.closeTabsWithoutAsking(app.store.tabs.filter { !opened.contains($0.id) })
        }
        func verb(_ title: String, _ id: String) -> ResourceVerb? { page.verbs(for: [id]).first { $0.title == title } }
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
        let drainTitle = KubeTabWrite.title(.drain)
        let node = KubeRowID(namespace: nil, name: "fake-node-1")

        // fake-dev: read-only — the drain greyed with why, refused, nothing sent.
        fake.forgetRequests()
        model.select("fake-dev")
        model.setScope(.namespace("shop"))
        guard await showKubernetesKind(model, page, "no", row: node) else { return }
        page.selection = ["fake-node-1"]
        let readOnly = "This context is read-only: Overterm changes nothing here (its writable setting)."
        check("fake-dev's drain is greyed with why", verb(drainTitle, "fake-node-1")?.unavailable == readOnly, verb(drainTitle, "fake-node-1")?.unavailable ?? "none")
        verb(drainTitle, "fake-node-1")?.perform()
        check("and refused at once", page.writeStatus == .failed(readOnly) && window.attachedSheet == nil, "\(String(describing: page.writeStatus))")
        check("the refusal drawn", await shownText(15) { $0.contains("This context is read-only") } != nil)
        page.writeStatus = nil
        check("E on its node is refused too", page.press("E") && page.writeStatus == .failed(readOnly), "\(String(describing: page.writeStatus))")
        await pause(0.3)
        check("nothing recorded, nothing sent — not even a review", recorded.isEmpty && fake.writes.isEmpty, "\(fake.writes)")

        // kind-fake: reviewed, asked, recorded. What the cordon asked before is forgotten: every review counted.
        model.writeAccess.forget(context: "kind-fake")
        model.select("kind-fake")
        model.setScope(.namespace("shop"))
        guard await showKubernetesKind(model, page, "no", row: node) else { return }
        page.selection = ["fake-node-1"]
        check(
            "kind-fake's drain is offered once reviewed", await eventually(10) { verb(drainTitle, "fake-node-1").map { $0.unavailable == nil } == true },
            verb(drainTitle, "fake-node-1")?.unavailable ?? "none")
        let reviewed = fake.requests.filter(\.isAccessReview).compactMap {
            (($0.json as? [String: Any])?["spec"] as? [String: Any])?["resourceAttributes"] as? [String: String]
        }
        check(
            "as the cluster's access review: patch nodes, evictions across the cluster",
            reviewed.contains(["verb": "patch", "resource": "nodes", "group": ""])
                && reviewed.contains(["verb": "create", "resource": "pods", "group": "", "subresource": "eviction"]), "\(reviewed)")
        let paletteTitles = app.kubernetesPageCommands().map(\.title)
        check("⌘K finds the drain too", paletteTitles.contains("Kubernetes: Drain node fake-node-1 in a Tab…"), "\(paletteTitles)")
        verb(drainTitle, "fake-node-1")?.perform()
        check("the drain is asked in the window", await eventually(10) { self.window.attachedSheet != nil }, "\(String(describing: page.writeStatus))")
        let drain = sheetTexts().joined(separator: "\n")
        check("naming the node, cluster-wide in kind-fake", drain.contains("Drain node fake-node-1?") && drain.contains("kind-fake · cluster-wide"), drain)
        let drainLine = "kubectl drain fake-node-1 --ignore-daemonsets --context kind-fake -n shop"
        check("and the command its tab runs", drain.contains(drainLine), drain)
        check("nothing recorded while it asks", recorded.isEmpty)
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check("confirmed, it is recorded, not typed", await eventually(10) { recorded.count == 1 }, "\(String(describing: page.writeStatus))")
        check("kubectl drain, its context said", recorded.first?.command == drainLine, recorded.first?.command ?? "")
        check(
            "in a tab pinned to kind-fake", recorded.first?.tab.kubePin?.context == "kind-fake" && recorded.first?.tab.kubePin?.namespace == "shop",
            "\(String(describing: recorded.first?.tab.kubePin))")
        check("the page says so", page.writeStatus == .done("Draining node fake-node-1 in a new tab, in kind-fake."), "\(String(describing: page.writeStatus))")

        // A recorded command's tab is selected and the page steps aside: back to it.
        func back() { if app.store.showingOverlay != .kubernetes { app.showKubernetesPage() } }
        back()

        // A rollback: a revision picked from the ReplicaSets, each with its image.
        fake.add(
            "deployments.apps", "api", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1],
            annotations: ["deployment.kubernetes.io/revision": "2"],
            fields: ["spec": ["replicas": 1, "selector": ["matchLabels": ["app": "api"]]], "status": ["replicas": 1]])
        for (name, revision, image) in [("api-6f8b", "2", "ghcr.io/acme/api:2.0"), ("api-5c4a", "1", "ghcr.io/acme/api:1.9")] {
            fake.add(
                "replicasets.apps", name, namespace: "shop", labels: ["app": "api"], annotations: ["deployment.kubernetes.io/revision": revision],
                fields: [
                    "metadata": ["ownerReferences": [["apiVersion": "apps/v1", "kind": "Deployment", "name": "api", "controller": true]]],
                    "spec": ["replicas": revision == "2" ? 1 : 0, "template": ["spec": ["containers": [["name": "api", "image": image]]]]],
                ])
        }
        page.writeStatus = nil
        let rollTitle = KubeTabWrite.title(.rolloutUndo)
        if await showKubernetesKind(model, page, "deploy", row: KubeRowID(namespace: "shop", name: "api")) {
            page.selection = ["shop/api"]
            check("its rollback is offered once reviewed", await eventually(10) { verb(rollTitle, "shop/api").map { $0.unavailable == nil } == true })
            verb(rollTitle, "shop/api")?.perform()
            check("which revision is asked", await eventually(10) { self.window.attachedSheet != nil }, "\(String(describing: page.writeStatus))")
            let choices = sheetButtons()
            check("the earlier one, with its image", choices.first?.hasPrefix("Revision 1 — ghcr.io/acme/api:1.9") == true && choices.count == 2, "\(choices)")
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
            check(
                "then the rollback is asked",
                await eventually(10) { self.sheetTexts().contains { $0.contains("Roll back deployment shop/api to revision 1?") } }, "\(sheetTexts())")
            let rollLine = "kubectl rollout undo deployment/api --to-revision=1 --context kind-fake -n shop"
            check("with its command", sheetTexts().contains { $0.contains(rollLine) }, "\(sheetTexts())")
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
            check("confirmed, recorded", await eventually(10) { recorded.count == 2 } && recorded.last?.command == rollLine, recorded.last?.command ?? "")
        }

        // E on a pod: a debug container with the setting's image.
        back()
        page.writeStatus = nil
        fake.addPod("debug-me-0", namespace: "shop")
        if await showKubernetesKind(model, page, "po", row: KubeRowID(namespace: "shop", name: "debug-me-0")) {
            page.selection = ["shop/debug-me-0"]
            page.giveListTheKeyboard()
            let debugTitle = KubeTabWrite.title(.debug)
            check("its debug is offered once reviewed", await eventually(10) { verb(debugTitle, "shop/debug-me-0").map { $0.unavailable == nil } == true })
            check("E is the list's", await pressKubernetesKey("E", keyCode: 14, shift: true))
            check("the debug container is asked", await eventually(10) { self.window.attachedSheet != nil }, "\(String(describing: page.writeStatus))")
            let debugLine = "kubectl debug -it debug-me-0 --image=busybox:1.36 --target=app --context kind-fake -n shop"
            check("with its image and target", sheetTexts().contains { $0.contains(debugLine) }, "\(sheetTexts())")
            check("the image in a field, the setting's", imageField()?.stringValue == "busybox:1.36", imageField()?.stringValue ?? "no field")
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
            check("confirmed, recorded", await eventually(10) { recorded.count == 3 } && recorded.last?.command == debugLine, recorded.last?.command ?? "")
            // Another image typed in the field: that one runs, quoted in the line; the setting stays.
            page.writeStatus = nil
            back()
            page.selection = ["shop/debug-me-0"]
            check("E again", page.debugKey())
            check("asked again", await eventually(10) { self.window.attachedSheet != nil && self.imageField() != nil })
            imageField()?.stringValue = "ghcr.io/acme/tools:2.1"
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
            let edited = "kubectl debug -it debug-me-0 --image=ghcr.io/acme/tools:2.1 --target=app --context kind-fake -n shop"
            // Asked again with that image's own line: the line confirmed is the line run.
            check(
                "another image is asked again with its line",
                await eventually(10) { self.window.attachedSheet != nil && self.sheetTexts().contains { $0.contains(edited) } }
                    && recorded.count == 3, "\(sheetTexts())")
            check("its field the new image", imageField()?.stringValue == "ghcr.io/acme/tools:2.1", imageField()?.stringValue ?? "no field")
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
            check("the field's image runs", await eventually(10) { recorded.count == 4 } && recorded.last?.command == edited, recorded.last?.command ?? "")
            check("and the setting is unchanged", model.debugImage(for: model.contexts.context(named: "kind-fake")!) == "busybox:1.36")
            // Not an image: refused, nothing typed.
            page.writeStatus = nil
            back()
            page.selection = ["shop/debug-me-0"]
            // The page shown again lists its rows again: the pod picked once its row is back.
            check("E once more", await eventually(10) { page.writeTarget?.name == "debug-me-0" } && page.debugKey(), "\(String(describing: page.writeTarget))")
            check("asked once more", await eventually(10) { self.window.attachedSheet != nil && self.imageField() != nil })
            imageField()?.stringValue = "busybox; rm -rf /"
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
            check(
                "a field that isn't an image is refused",
                await eventually(10) { if case .failed(let why) = page.writeStatus { why.contains("isn't an image reference") } else { false } }
                    && recorded.count == 4, "\(String(describing: page.writeStatus))")
        }
        back()
        check("only access reviews reached the fake", fake.writes.allSatisfy(\.isAccessReview), "\(fake.writes.filter { !$0.isAccessReview })")
        page.writeStatus = nil
    }

    /// Agents' write tools through the app's own MCP endpoint (see the extension's comment).
    func kubernetesAgentWrites(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, kubeconfig: URL, port: Int) async {
        guard let tab = app.store.selected else { return check("a tab to call from", false) }
        check("the MCP bridge listens", await eventually(5) { BrowserBridge.shared.port != nil })
        guard let bridge = BrowserBridge.shared.port else { return }
        let wasShowing = app.store.showingOverlay == .kubernetes
        if !wasShowing { app.toggleKubernetesPage(nil) }
        defer { if !wasShowing, app.store.showingOverlay == .kubernetes { app.toggleKubernetesPage(nil) } }
        let tag = tab.terminal.processTag
        func post(_ body: [String: Any]) async -> [String: Any]? {
            guard let endpoint = URL(string: "http://127.0.0.1:\(bridge)/mcp/\(tag)") else { return nil }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(BrowserBridge.shared.token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        func listed() async -> [String] {
            let answer = await post(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
            return (((answer?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []).filter {
                $0.hasPrefix("k8s_")
            }
        }
        func call(_ name: String, _ arguments: [String: Any]) async -> (text: String, isError: Bool) {
            let answer = await post(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
            if let error = answer?["error"] as? [String: Any] { return (error["message"] as? String ?? "", true) }
            let result = answer?["result"] as? [String: Any]
            return (((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "\(answer ?? [:])", result?["isError"] as? Bool == true)
        }
        func listedEventually(_ wanted: [String]) async -> Bool {
            for _ in 0..<25 {
                if await listed() == wanted { return true }
                await pause(0.2)
            }
            return false
        }
        /// A call that waits on the window's confirmation, left running while the runner looks.
        func started(_ name: String, _ arguments: [String: Any]) -> Task<(text: String, isError: Bool), Never> {
            Task { @MainActor in await call(name, arguments) }
        }
        fake.forgetRequests()
        defer { Settings.shared.set("kubernetes.agentWrites", nil) }

        // kind-fake is writable, but agentWrites names nothing: agents read only.
        Settings.shared.set("kubernetes.agentWrites", nil)
        let none = await listed()
        check("agentWrites empty: no write tool listed", none == KubeMCP.reads, "\(none)")
        let unnamed = await call("k8s_scale", ["name": "batch", "replicas": 2, "context": "kind-fake", "namespace": "shop"])
        check(
            "k8s_scale on kind-fake is refused, asking nothing",
            unnamed.isError && unnamed.text.contains("kubernetes.agentWrites doesn't name kind-fake") && window.attachedSheet == nil, unnamed.text)
        check("nothing reached the fake", fake.writes.isEmpty, "\(fake.writes)")

        // Named: the write tools are listed.
        Settings.shared.set("kubernetes.agentWrites", .list(["kind-fake"]))
        check("with agentWrites naming kind-fake, the write tools are offered", await listedEventually(KubeMCP.reads + KubeMCP.writes))
        let contexts = await call("k8s_contexts", [:])
        check(
            "k8s_contexts says where agents may write",
            contexts.text.contains("kind-fake — local, writable — agents may restart, scale and delete pods here")
                && contexts.text.contains("fake-prod — PRODUCTION, read-only for Overterm"), contexts.text)

        // k8s_scale on kind-fake: asked in the window, the runner answers, it lands.
        let scaling = started("k8s_scale", ["name": "batch", "replicas": 2, "context": "kind-fake", "namespace": "shop"])
        check("k8s_scale is asked in the window", await eventually(15) { self.window.attachedSheet != nil })
        let asked = sheetTexts().joined(separator: "\n")
        check(
            "the context and namespace in its title",
            asked.contains("An agent asks, in kind-fake · namespace shop: Scale deployment shop/batch from 3 to 2 replicas?"), asked)
        check("and the kubectl it equals", asked.contains("kubectl scale deploy/batch --replicas=2 --context kind-fake -n shop"), asked)
        check("nothing is written while it asks", !fake.writes.contains { !$0.isAccessReview }, "\(fake.writes)")
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        let scaled = await scaling.value
        check("allowed, it lands on the fake", !scaled.isError && scaled.text.contains("Scaled deployment shop/batch from 3 to 2 in kind-fake."), scaled.text)
        check(
            "as one PATCH of its scale subresource",
            fake.writes.filter { !$0.isAccessReview }.map(\.description) == ["PATCH /apis/apps/v1/namespaces/shop/deployments/batch/scale"],
            "\(fake.writes.map(\.description))")
        check("reviewed first", fake.writes.first?.isAccessReview == true)

        // Declined: nothing sent.
        let deleting = started("k8s_delete_pod", ["name": "debug-me-0", "context": "kind-fake", "namespace": "shop"])
        check("k8s_delete_pod is asked", await eventually(15) { self.window.attachedSheet != nil })
        check("naming the pod", sheetTexts().contains { $0.contains("Delete pod shop/debug-me-0?") }, "\(sheetTexts())")
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        let declined = await deleting.value
        check("declined, the agent is told", declined.isError && declined.text.contains("The user declined"), declined.text)
        check("and nothing is deleted", fake.pod("debug-me-0", namespace: "shop") != nil && !fake.writes.contains { $0.method == "DELETE" })

        // Without kind-fake: fake-dev and fake-prod only.
        do {
            try Self.fakeKubeconfig(port: port).write(to: kubeconfig, atomically: true, encoding: .utf8)
        } catch {
            return check("the kubeconfig loses kind-fake", false, "\(error)")
        }
        model.reloadContexts()
        check("kind-fake is gone", await eventually(10) { model.contexts.contexts.map(\.name) == ["fake-dev", "fake-prod"] })
        let writes = fake.writes.count
        check("still listed by the setting (the list isn't announced again)", await listed() == KubeMCP.reads + KubeMCP.writes)
        let refused = await call("k8s_scale", ["name": "web", "replicas": 0, "context": "fake-prod", "namespace": "payments"])
        check(
            "k8s_scale on fake-prod is refused, asking nothing",
            refused.isError && refused.text.contains("isn't offered on fake-prod") && window.attachedSheet == nil, refused.text)

        // fake-prod's writes on for the session: still refused, until agentWrites names it.
        model.select("fake-prod")
        page.allowProductionWrites()
        check("turning writes on is asked", await eventually(5) { self.window.attachedSheet != nil })
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check("fake-prod's writes are on", await eventually(5) { model.selected?.isWritable == true && page.productionWritesOn })
        let notNamed = await call("k8s_delete_pod", ["name": "web-7d9", "context": "fake-prod", "namespace": "payments"])
        check("a write there is refused: agentWrites doesn't name it", notNamed.isError && notNamed.text.contains("kubernetes.agentWrites"), notNamed.text)
        Settings.shared.set("kubernetes.agentWrites", .list(["fake-prod"]))
        let prodContexts = await call("k8s_contexts", [:])
        check("k8s_contexts says agents may write on fake-prod", prodContexts.text.contains("fake-prod — PRODUCTION, writable — agents may"), prodContexts.text)

        // On production a delete asks for the pod's name: a wrong one sends nothing.
        let prodDelete = started("k8s_delete_pod", ["name": "web-7d9", "context": "fake-prod", "namespace": "payments"])
        check("asked in the window", await eventually(15) { self.window.attachedSheet != nil && self.typedNameField() != nil })
        check(
            "PRODUCTION, the context and namespace in its title",
            sheetTexts().contains { $0.contains("An agent asks, in PRODUCTION · fake-prod · namespace payments: Delete pod payments/web-7d9?") },
            "\(sheetTexts())")
        check(
            "in production's red",
            Self.find(NSTextField.self, in: window.attachedSheet?.contentView) { $0.accessibilityIdentifier() == "write.scope" }?.textColor
                == WriteConfirmation.productionRed)
        typedNameField()?.stringValue = "web"
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        let wrong = await prodDelete.value
        check("a wrong name: the agent is told, nothing changed", wrong.isError && wrong.text.contains("The name typed wasn't web-7d9"), wrong.text)
        check("the pod is still there", fake.pod("web-7d9", namespace: "payments") != nil)
        check("nothing but reviews reached the fake since", fake.writes.dropFirst(writes).allSatisfy(\.isAccessReview), "\(fake.writes.suffix(3))")

        page.endProductionWrites()
        check("writes off again", await eventually(5) { model.selected?.isWritable == false })
        Settings.shared.set("kubernetes.agentWrites", nil)
        check("and the write tools go", await listedEventually(KubeMCP.reads))
        model.select("fake-dev")
    }
}
