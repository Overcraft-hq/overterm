import AppKit
import Foundation

/// Stage 2b against the fake API server, never a real cluster (Section 9's
/// check: a diff with masked Secret data; a 409 conflict shown; no Apply
/// on `fake-prod` with writes on): `y` on `kind-fake`'s deployment opens
/// Overterm's copy in the editor (in the run's support folder, 0600,
/// stripped); Diff with Cluster sends a dry run and shows its diff in the
/// right-hand pane, Helm's field named; Apply is asked in the window's
/// sheet (ended by the runner) and the fake's 409 shown with its manager,
/// then Force asked again and landing. A checkout's Secret manifest diffs
/// with its values masked before and after, none of them in what is shown;
/// a kustomization is rendered by the stand-in kubectl with KUBECONFIG
/// `/dev/null`; `fake-dev` (read-only) diffs client-side, labelled, sending
/// nothing; `fake-prod` with its writes on still offers no Apply.
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
        page.selection = ["shop/shop-api"]
        page.giveListTheKeyboard()
        check("y is the list's", await pressKubernetesKey("y", keyCode: 16))
        guard let kind = model.discovery?.kind("deploy") else { return check("kind-fake serves deployments", false) }
        let ref = KubeObjectRef(context: "kind-fake", kind: kind, namespace: "shop", name: "shop-api")
        let copy = KubeManifestEdits.url(for: ref)
        check("its copy opens in the editor", await eventually(10) { editor.active?.url?.standardizedFileURL == copy.standardizedFileURL }, editor.active?.url?.path ?? "none")
        check("the page steps aside", app.store.showingOverlay == nil)
        check(
            "Overterm's copy, in the run's own support folder — no checkout's file",
            copy.path.hasPrefix(AppEnvironment.supportDirectory.appendingPathComponent("Kubernetes/Edits").path), copy.path)
        check("0600", (try? FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int) == 0o600)
        guard let buffer = editor.active, let session = buffer.kubeManifest else { return check("the copy has its manifest bar", false) }
        check("for the object it came from", session.ref == ref && session.contextName == "kind-fake")
        let opened = buffer.storage.string
        check(
            "stripped: no managedFields, status or resourceVersion",
            !opened.contains("managedFields") && !opened.contains("status:") && !opened.contains("resourceVersion") && opened.contains("replicas: 1"), opened)
        check("its version kept beside it", KubeManifestEdits.edit(at: copy)?.resourceVersion != nil)
        check("the bar under it", await eventually(5) { editor.consoleHeight.constant >= KubeManifestBar.height }, "\(editor.consoleHeight.constant)")
        check("the bar drawn", await shownText(15) { $0.contains("Diff with Cluster") || $0.contains("deployment shop/shop-api") } != nil)

        // Diff with Cluster: a dry run, its diff in the right-hand pane, Helm named.
        editor.replaceText(of: buffer, with: opened.replacingOccurrences(of: "replicas: 1", with: "replicas: 2"))
        // Never saved: a value retyped in it stays in memory (rule 9); closing asks nothing.
        editor.save(buffer, overwriting: false)
        check(
            "Overterm's copy is never saved", (try? String(contentsOf: copy, encoding: .utf8)) == opened && session.state.text == KubeManifestEdits.unsaved,
            "\(session.state)")
        check("still 0600", (try? FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int) == 0o600)
        check("not counted as unsaved", !editor.unsavedNames.contains(buffer.name), "\(editor.unsavedNames)")
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
        app.openInEditor(secretFile)
        check("a checkout's manifest gets the bar", await eventually(10) { editor.active?.url?.standardizedFileURL == secretFile.standardizedFileURL && editor.active?.kubeManifest != nil })
        guard let secret = editor.active?.kubeManifest else { return }
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

        // fake-prod, writes on for the session, no applyOnProduction: no Apply.
        let prodFile = checkout.appendingPathComponent("pay-api.yaml")
        try? "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: pay-api\n  namespace: payments\nspec:\n  replicas: 2\n".write(
            to: prodFile, atomically: true, encoding: .utf8)
        app.toggleKubernetesPage(nil)
        model.select("fake-prod")
        page.allowProductionWrites()
        check("fake-prod's writes are asked first", await eventually(5) { self.window.attachedSheet != nil })
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check("fake-prod's writes are on", await eventually(5) { model.selected?.isWritable == true && page.productionWritesOn })
        // The page steps aside for the editor.
        app.toggleKubernetesPage(nil)
        app.openInEditor(prodFile)
        check("its manifest opens", await eventually(10) { editor.active?.url?.standardizedFileURL == prodFile.standardizedFileURL && editor.active?.kubeManifest != nil })
        if let prod = editor.active?.kubeManifest {
            prod.contextName = "fake-prod"
            await prod.refreshContexts()
            check(
                "no Apply on fake-prod with its writes on: applyOnProduction is off",
                prod.applyRefusal
                    == "Apply is off on production, even with its writes on: the context's applyOnProduction setting turns it on. Diff with Cluster still works.",
                prod.applyRefusal ?? "offered")
            let writes = fake.writes.count
            await prod.runApply()
            check("Apply refused at once, asking nothing", prod.state.isFailure && window.attachedSheet == nil && fake.writes.count == writes, "\(prod.state)")
            check("production's refusal drawn", await shownText(15) { $0.contains("Apply is off on production") } != nil)
            prod.diffWithCluster()
            check("the diff still works there", await eventually(15) { prod.result?.context == "fake-prod" && prod.result?.production == true }, "\(prod.state)")
            check("nothing applied on fake-prod", replicas(fake, "pay-api", namespace: "payments") == 1)
        }
        if app.store.showingOverlay != .kubernetes { app.toggleKubernetesPage(nil) }
        page.endProductionWrites()
        check("fake-prod's writes off again", await eventually(5) { model.selected?.isWritable == false })

        // The copy goes with its tab; the checkout's files stay.
        for url in [copy, secretFile, deploy.appendingPathComponent("kustomization.yaml"), prodFile] {
            if let index = editor.buffers.firstIndex(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) { editor.removeBuffer(at: index) }
        }
        check("the copy is removed with its tab", !FileManager.default.fileExists(atPath: copy.path) && KubeManifestEdits.edit(at: copy) == nil)
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
}
