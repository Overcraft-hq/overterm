import AppKit
import Foundation

/// Stage 2b against the fake API server, never a real cluster (Section 9's
/// check: a diff with masked Secret data; a 409 conflict shown; Apply on
/// writable `fake-prod` with nothing turned on, the name typed): the detail's YAML tab is the editor on
/// the resource's one buffer — followed quietly without edits, the banner
/// with them —, `y` opens that buffer in the window's editor (stripped,
/// in memory, never a file); Diff with Cluster sends a dry run and shows its diff in the
/// right-hand pane, Helm's field named; Apply is asked in the window's
/// sheet (ended by the runner) and the fake's 409 shown with its manager,
/// then Force asked again and landing. A checkout's Secret manifest diffs
/// with its values masked before and after, none of them in what is shown;
/// a kustomization is rendered by the stand-in kubectl with KUBECONFIG
/// `/dev/null`; `fake-dev` (read-only) diffs client-side, labelled, sending
/// nothing; `fake-prod`, writable with no switch and no setting, offers
/// Apply with its name typed (the owner's decision).
extension E2ERunner {
    /// The Secret's values here: never in the app's output (testKubernetes).
    static let applySecretOld = "acme-e2e-apply-Hx4Wq"
    static let applySecretNew = "acme-e2e-apply-Rt8Pz"

    func kubernetesApply(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, kubeconfig: URL, port: Int) async {
        do {
            try Self.fakeKubeconfig(port: port, kind: true).write(to: kubeconfig, atomically: true, encoding: .utf8)
        } catch {
            return check("the kubeconfig gains kind-fake again", false, "\(error)")
        }
        let wasShowing = app.store.showingOverlay == .kubernetes
        defer { if (app.store.showingOverlay == .kubernetes) != wasShowing { app.toggleKubernetesPage(nil) } }
        if !wasShowing { app.toggleKubernetesPage(nil) }
        model.reloadContexts()
        check("kind-fake is read", await eventually(10) { model.contexts.context(named: "kind-fake") != nil }, "\(model.contexts.contexts.map(\.name))")
        fake.add(
            "deployments.apps", "shop-api", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1],
            fields: ["spec": ["replicas": 1, "selector": ["matchLabels": ["app": "shop-api"]]], "status": ["replicas": 1, "readyReplicas": 1]])
        fake.setManagedFields(
            "deployments.apps", "shop-api", namespace: "shop",
            [["manager": "helm", "operation": "Apply", "apiVersion": "apps/v1", "fieldsType": "FieldsV1", "fieldsV1": ["f:spec": ["f:replicas": [String: Any]()]]]])
        fake.add("secrets", "api-creds", namespace: "shop", values: ["Type": "Opaque"], data: ["token": Self.applySecretOld, "user": "api"])
        fake.add("deployments.apps", "pay-api", namespace: "payments", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1], fields: ["spec": ["replicas": 1]])
        guard let editor = app.editor else { return check("the window has an editor", false) }

        // y: kind-fake's deployment, Overterm's copy in the editor.
        model.select("kind-fake")
        model.setScope(.namespace("shop"))
        check(
            "what kind-fake serves is read", await eventually(15) { model.selectedName == "kind-fake" && model.discovery?.kind("deploy") != nil },
            "\(String(describing: model.discoveryProblem))")
        guard await showKubernetesKind(model, page, "deploy", row: KubeRowID(namespace: "shop", name: "shop-api")) else { return }
        guard let kind = model.discovery?.kind("deploy") else { return check("kind-fake serves deployments", false) }
        let ref = KubeObjectRef(context: "kind-fake", kind: kind, namespace: "shop", name: "shop-api")

        // The detail's YAML tab is the editor: the resource's one buffer.
        page.selection = ["shop/shop-api"]
        page.openSelected()
        page.showTab(.yaml)
        check("the YAML tab has the resource's buffer", await eventually(10) { page.detail?.resource?.state == .loaded }, "\(String(describing: page.detail?.resource?.state))")
        guard let resource = page.detail?.resource, let tab = page.yamlEditor else { return check("the YAML tab's editor", false) }
        check("shown by the app's editor, in the tab", await eventually(5) { tab.active === resource.buffer && tab.view.window === self.window })
        check("tree-sitter YAML", resource.buffer.language?.id == "yaml")
        check("drawn", await shownText(15) { $0.contains("replicas: 1") } != nil)
        check("its bar over it", await shownText(15) { $0.contains("Diff with Cluster") } != nil)
        check("followed while the tab shows", resource.isFollowing)
        // No edits: a change on the cluster is taken quietly.
        func spec(_ ready: Int) -> [String: Any] {
            [
                "spec": ["replicas": 1, "selector": ["matchLabels": ["app": "shop-api"]], "minReadySeconds": ready],
                "status": ["replicas": 1, "readyReplicas": 1],
            ]
        }
        fake.setFields("deployments.apps", "shop-api", namespace: "shop", spec(5))
        check("followed quietly", await eventually(10) { resource.buffer.storage.string.contains("minReadySeconds: 5") && resource.clusterChange == nil })
        // Edits: the next change is the banner's, never written over them.
        tab.replaceText(of: resource.buffer, with: resource.buffer.storage.string.replacingOccurrences(of: "replicas: 1", with: "replicas: 7"))
        check("edited in the tab", resource.isEdited)
        fake.setFields("deployments.apps", "shop-api", namespace: "shop", spec(9))
        check("the banner", await eventually(10) { resource.clusterChange != nil })
        check("the edits kept", resource.buffer.storage.string.contains("replicas: 7") && !resource.buffer.storage.string.contains("minReadySeconds: 9"))
        // The banner wraps where the tab's width says.
        check("the banner drawn", await shownPhrase("changed on the cluster"))
        check("with Reload", await shownText(15) { $0 == "Reload" } != nil)
        resource.reload()
        check(
            "Reload: the cluster's", resource.buffer.storage.string.contains("minReadySeconds: 9") && !resource.isEdited && resource.clusterChange == nil)

        // y: the same buffer in the window's editor.
        page.giveListTheKeyboard()
        check("y is the list's", await pressKubernetesKey("y", keyCode: 16))
        let copy = resource.url
        check("its YAML opens in the editor", await eventually(10) { editor.active === resource.buffer }, editor.active?.url?.path ?? "none")
        check("the page steps aside", app.store.showingOverlay == nil)
        check("the window's editor follows it while it shows", await eventually(5) { editor.watching === resource && resource.isFollowing })
        app.toggleKubernetesPage(nil)
        check("not while the page covers it", await eventually(5) { editor.watching == nil && !editor.isOnScreen })
        app.toggleKubernetesPage(nil)
        check("again once uncovered", await eventually(5) { editor.watching === resource && resource.isFollowing })
        check("never a file", !FileManager.default.fileExists(atPath: copy.path) && resource.buffer.document.isVirtual, copy.path)
        guard let buffer = editor.active, let session = buffer.kubeManifest else { return check("the copy has its manifest bar", false) }
        check("for the object it came from", session.ref == ref && session.contextName == "kind-fake")
        let opened = buffer.storage.string
        check(
            "stripped: no managedFields, status or resourceVersion",
            !opened.contains("managedFields") && !opened.contains("status:") && !opened.contains("resourceVersion") && opened.contains("replicas: 1"), opened)
        check("its version kept beside it", resource.resourceVersion != nil && KubeManifestEdits.edit(at: copy)?.resourceVersion == resource.resourceVersion)
        check("the bar under it", await eventually(5) { editor.consoleHeight.constant >= KubeManifestBar.height }, "\(editor.consoleHeight.constant)")
        check("the bar drawn", await shownText(15) { $0.contains("Diff with Cluster") || $0.contains("deployment shop/shop-api") } != nil)

        // Diff with Cluster: a dry run, its diff in the right-hand pane, Helm named.
        editor.replaceText(of: buffer, with: opened.replacingOccurrences(of: "replicas: 1", with: "replicas: 2"))
        check("the tab has the same edits", tab.textView.string.contains("replicas: 2"))
        // Never saved: what is typed stays in memory (rule 9); closing with edits asks.
        editor.save(buffer, overwriting: false)
        check("never saved", !FileManager.default.fileExists(atPath: copy.path) && session.state.text == KubeManifestEdits.unsaved, "\(session.state)")
        check("its edits count as unsaved", editor.unsavedNames.contains(buffer.name), "\(editor.unsavedNames)")
        fake.forgetRequests()
        session.diffWithCluster()
        check("the diff comes", await eventually(15) { session.result != nil }, "\(session.state)")
        let dry = fake.writes.filter { $0.query["dryRun"] == "All" }
        check(
            "as a server-side apply with dryRun=All",
            dry.count == 1 && dry.first?.method == "PATCH" && dry.first?.contentType == "application/apply-patch+yaml" && dry.first?.query["fieldManager"] == "overterm",
            "\(fake.writes.map { "\($0.description) \($0.query)" })")
        check("that changes nothing", fake.writes.allSatisfy { $0.query["dryRun"] == "All" } && replicas(fake, "shop-api") == 1)
        check("in the right-hand pane", app.rightPane.mode == .manifest && app.kubernetesManifest.session === session)
        check("the change in it", session.result?.items.first?.diff.contains("+  replicas: 2") == true, session.result?.items.first?.diff ?? "none")
        check("server-side, said", session.result?.isServerSide == true)
        check("drawn", await shownText(15) { $0.contains("Server-side dry run") } != nil)
        check("Helm's field named before applying", session.result?.warnings.first == "Helm manages this: its next upgrade sets these fields back.")
        check("and drawn", await shownText(15) { $0.contains("Helm manages this") } != nil)
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_APPLY_PNG"], !png.isEmpty {
            await pause(0.8)
            app.captureWindow(to: png)
        }

        // Apply: asked in the window; the fake's 409 shown with its manager.
        session.apply()
        check("the apply is asked in the window", await eventually(15) { self.window.attachedSheet != nil })
        let asked = sheetWords()
        check("naming it", asked.contains("Apply deployment shop/shop-api to kind-fake?"), asked)
        check("the context and namespace", asked.contains("kind-fake · namespace shop"), asked)
        check("the dry run's diff", asked.contains("+  replicas: 2"), asked)
        check("Helm's field", asked.contains("Helm manages this"), asked)
        check("the kubectl it equals", asked.contains("kubectl apply --server-side --field-manager=overterm -f deployment-shop-api.yaml --context kind-fake -n shop"), asked)
        check("nothing applied while it asks", !fake.writes.contains { $0.contentType == "application/apply-patch+yaml" && $0.query["dryRun"] == nil })
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check(
            "the 409 is shown with its manager", await eventually(15) { session.conflict == .fields([.init(manager: "helm", field: ".spec.replicas")]) },
            "\(session.state)")
        check("nothing applied", replicas(fake, "shop-api") == 1)
        check("the conflict drawn", await shownText(15) { $0.contains("helm owns .spec.replicas") } != nil)
        check("Force offered", await shownText(15) { $0.contains("Force") } != nil)

        // Force: asked again, then it lands.
        session.forceApply()
        check("forcing is asked again", await eventually(15) { self.window.attachedSheet != nil })
        let forcing = sheetWords()
        check("as a force", forcing.contains("Force the apply of deployment shop/shop-api?") && forcing.contains("--force-conflicts"), forcing)
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check("then it lands", await eventually(15) { self.replicas(fake, "shop-api") == 2 }, "\(session.state)")
        check(
            "with force=true", fake.writes.contains { $0.contentType == "application/apply-patch+yaml" && $0.query["dryRun"] == nil && $0.query["force"] == "true" })
        check("the apply said", await eventually(15) { session.state == .done("Applied deployment shop/shop-api to kind-fake.") }, "\(session.state)")
        check("and drawn", await shownText(15) { $0.contains("Applied deployment shop/shop-api") } != nil)
        await kubernetesYAMLEditsAsk(page, editor: editor, tab: tab, resource: resource)

        // A checkout's Secret manifest: the diff masks its values.
        let checkout = scratch.appendingPathComponent("k8s-checkout-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: checkout.appendingPathComponent("deploy"), withIntermediateDirectories: true)
        let secretFile = checkout.appendingPathComponent("api-creds.yaml")
        try? """
        apiVersion: v1
        kind: Secret
        metadata:
          name: api-creds
          namespace: shop
        stringData:
          token: \(Self.applySecretNew)
          user: api

        """.write(to: secretFile, atomically: true, encoding: .utf8)
        // From here until its diff is checked, a Secret's value may be
        // drawn: what a failing read saw is never kept.
        withholdPictures = true
        app.openInEditor(secretFile)
        check("a checkout's manifest gets the bar", await eventually(10) { editor.active?.url?.standardizedFileURL == secretFile.standardizedFileURL && editor.active?.kubeManifest != nil })
        guard let secret = editor.active?.kubeManifest else { withholdPictures = false; return }
        secret.contextName = "kind-fake"
        secret.diffWithCluster()
        check("its diff comes", await eventually(15) { secret.result != nil }, "\(secret.state)")
        let secretDiff = secret.result?.items.first?.diff ?? ""
        check("the value that changes masked before and after", secretDiff.contains("*** (before)") && secretDiff.contains("*** (after)"))
        let values = [Self.applySecretOld, Self.applySecretNew, Data(Self.applySecretOld.utf8).base64EncodedString(), Data(Self.applySecretNew.utf8).base64EncodedString()]
        let shownSecret = [secret.result?.items.first?.before, secret.result?.items.first?.after, secretDiff, secret.result?.summary(), secret.state.text]
            .compactMap { $0 }.joined(separator: "\n")
        check("no value in what is shown", !values.contains { shownSecret.contains($0) })
        check("drawn masked", await shownText(15) { $0.contains("*** (before)") } != nil)
        check("drawn without its value", await shownText(3) { line in values.contains { line.contains($0) } } == nil)
        check("the Secret unchanged", (fake.object("secrets", "api-creds", namespace: "shop")?["data"] as? [String: String])?["token"] == values[2])
        withholdPictures = false

        // A kustomization: rendered by kubectl kustomize, from files alone.
        let deploy = checkout.appendingPathComponent("deploy")
        try? "resources:\n- api.yaml\n".write(to: deploy.appendingPathComponent("kustomization.yaml"), atomically: true, encoding: .utf8)
        try? "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: shop-api\n  namespace: shop\nspec:\n  replicas: 2\n".write(
            to: deploy.appendingPathComponent("api.yaml"), atomically: true, encoding: .utf8)
        app.openInEditor(deploy.appendingPathComponent("kustomization.yaml"))
        check("a kustomization gets the bar", await eventually(10) { editor.active?.kubeManifest?.title == "kustomization deploy" })
        if let kustomization = editor.active?.kubeManifest {
            kustomization.contextName = "kind-fake"
            kustomization.diffWithCluster()
            check("rendered and diffed", await eventually(15) { kustomization.result?.items.map(\.spoken) == ["deployment shop/shop-api"] }, "\(kustomization.state)")
            check("as the cluster has it: no change", kustomization.result?.changes == 0, "\(kustomization.state)")
            let rendered = (try? String(contentsOf: Self.kustomizeLog(in: scratch), encoding: .utf8)) ?? ""
            check("by kubectl kustomize with KUBECONFIG /dev/null", rendered.contains("/dev/null|kustomize \(deploy.path)"), rendered)
        }

        // fake-dev: read-only — client-side, labelled, nothing sent.
        let before = fake.writes.count
        secret.contextName = "fake-dev"
        secret.diffWithCluster()
        check("fake-dev's diff comes", await eventually(15) { secret.result?.context == "fake-dev" }, "\(secret.state)")
        check("client-side, labelled", secret.result?.label.hasPrefix(KubeManifestDiffResult.clientSideLabel) == true, secret.result?.label ?? "none")
        check("still masked", secret.result?.items.first?.diff.contains("*** (before)") == true)
        check("the label drawn", await shownText(15) { $0.contains("client-side: defaults and admission not applied") } != nil)
        check("nothing reached the fake from fake-dev", fake.writes.count == before, "\(fake.writes.suffix(2))")
        check("no Apply there, with why", secret.applyRefusal?.hasPrefix("This context is read-only") == true, secret.applyRefusal ?? "none")

        // fake-prod, writable (no switch, no applyOnProduction): a person's Apply is offered, the name typed.
        let prodFile = checkout.appendingPathComponent("pay-api.yaml")
        try? "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: pay-api\n  namespace: payments\nspec:\n  replicas: 2\n".write(
            to: prodFile, atomically: true, encoding: .utf8)
        app.toggleKubernetesPage(nil)
        model.select("fake-prod")
        check("fake-prod is writable, nothing turned on", await eventually(5) { model.selected?.isWritable == true && self.window.attachedSheet == nil })
        // The page steps aside for the editor.
        app.toggleKubernetesPage(nil)
        app.openInEditor(prodFile)
        check("its manifest opens", await eventually(10) { editor.active?.url?.standardizedFileURL == prodFile.standardizedFileURL && editor.active?.kubeManifest != nil })
        if let prod = editor.active?.kubeManifest {
            prod.contextName = "fake-prod"
            await prod.refreshContexts()
            check("Apply offered on writable fake-prod, no setting turned on", prod.applyRefusal == nil, prod.applyRefusal ?? "offered")
            if let context = model.contexts.context(named: "fake-prod") {
                check("its name typed (rule 4)", KubeApplyCheck.rule(context).typedName)
                check(
                    "an agent's still needs applyOnProduction",
                    KubeApplyCheck.refused(context, agent: true)?.hasPrefix("An agent's apply is off on production") == true)
            }
            prod.diffWithCluster()
            check("the diff works there", await eventually(15) { prod.result?.context == "fake-prod" && prod.result?.production == true }, "\(prod.state)")
            check("nothing applied on fake-prod by a diff", replicas(fake, "pay-api", namespace: "payments") == 1)
        }
        if app.store.showingOverlay != .kubernetes { app.toggleKubernetesPage(nil) }

        // The copy goes with its tab; the checkout's files stay.
        check("applied: no edits left", !resource.isEdited)
        for url in [copy, secretFile, deploy.appendingPathComponent("kustomization.yaml"), prodFile] {
            if let index = editor.buffers.firstIndex(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) { editor.removeBuffer(at: index) }
        }
        page.closeDetail()
        check(
            "the buffer goes once nothing shows it",
            model.resourceBuffers.existing(ref) == nil && KubeManifestEdits.edit(at: copy) == nil
                && !FileManager.default.fileExists(atPath: copy.path))
        check("the checkout's own files stay", FileManager.default.fileExists(atPath: secretFile.path))
        try? FileManager.default.removeItem(at: checkout)
        model.select("fake-dev")
    }

    /// Everything the sheet says: its labels, and a long detail's text view.
    private func sheetWords() -> String {
        guard let root = window.attachedSheet?.contentView else { return "" }
        var texts: [String] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField { texts.append(field.stringValue) }
            if let text = view as? NSTextView { texts.append(text.string) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return texts.joined(separator: "\n")
    }

    private func replicas(_ fake: FakeKubeAPI, _ name: String, namespace: String = "shop") -> Int? {
        ((fake.object("deployments.apps", name, namespace: namespace)?["spec"] as? [String: Any])?["replicas"] as? NSNumber)?.intValue
    }

    /// Closing with edits asks, wherever they were typed: the `y` tab's
    /// Discard Edits sheet (Cancel keeps the text, Discard reverts the one
    /// buffer — the detail's tab with it); edits typed only in the detail's
    /// tab, the detail moved on, are said kept and asked about by the
    /// window's close.
    func kubernetesYAMLEditsAsk(_ page: KubernetesPageModel, editor: EditorViewController, tab: EditorViewController, resource: KubeResourceBuffer) async {
        guard let index = editor.buffers.firstIndex(where: { $0 === resource.buffer }) else { return check("the y tab is open", false) }
        let clean = resource.buffer.storage.string
        editor.replaceText(of: resource.buffer, with: clean.replacingOccurrences(of: "replicas: 2", with: "replicas: 5"))
        check("edited in the y tab", resource.isEdited && resource.buffer.document.isDirty)
        editor.closeBuffer(at: index)
        check("closing it asks", await eventually(10) { self.window.attachedSheet != nil })
        let asked = sheetWords()
        check("to discard the edits", asked.contains("Discard your edits to deployment shop/shop-api?"), asked)
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check("Cancel keeps the text", await eventually(5) { self.window.attachedSheet == nil })
        check("and the tab", resource.isEdited && resource.buffer.storage.string.contains("replicas: 5") && editor.buffers.contains { $0 === resource.buffer })
        if let again = editor.buffers.firstIndex(where: { $0 === resource.buffer }) { editor.closeBuffer(at: again) }
        check("asked again", await eventually(10) { self.window.attachedSheet != nil })
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        check("Discard reverts the one buffer", await eventually(5) { !resource.isEdited && resource.buffer.storage.string == clean })
        check("the tab closed", !editor.buffers.contains { $0 === resource.buffer })
        check("the detail's tab has no edits either", tab.active !== resource.buffer || tab.textView.string == clean)

        // Typed only in the detail's tab, then the detail moves on.
        tab.replaceText(of: resource.buffer, with: clean.replacingOccurrences(of: "replicas: 2", with: "replicas: 6"))
        check("edited in the detail's tab only", resource.isEdited && editor.unsavedNames.isEmpty)
        check("counted by the window's close", app.unsavedNames(everyWindow: false).contains(resource.buffer.name), "\(app.unsavedNames(everyWindow: false))")
        page.closeDetail()
        check("leaving says the edits are kept", page.writeStatus == .done(KubernetesPageModel.keptEdits(resource.ref)), "\(String(describing: page.writeStatus))")
        check("kept by the app", KubernetesModel.shared.resourceBuffers.edited.contains { $0 === resource })
        check("and still asked about by the last window's close and the quit", app.unsavedNames(everyWindow: true).contains(resource.buffer.name))
        check("the window's close asks", !app.windowShouldClose(window) && window.attachedSheet != nil)
        let closing = sheetWords()
        check("naming them", closing.contains(resource.buffer.name) && closing.contains("unsaved changes"), closing)
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check("Cancel keeps the window", await eventually(5) { self.window.attachedSheet == nil && self.window.isVisible })
        resource.revert()
        check("reverted, held by nobody: gone", KubernetesModel.shared.resourceBuffers.existing(resource.ref) == nil)
        check("nothing left to ask about", app.unsavedNames(everyWindow: true).isEmpty, "\(app.unsavedNames(everyWindow: true))")
    }
}
