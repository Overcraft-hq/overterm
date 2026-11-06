import AppKit
import Foundation

/// Stage 4's API docs (3.15) against the fake API server, never a real
/// cluster: a checkout's Deployment manifest opened in the editor reads
/// nothing until asked; a hover over `replicas` shows what fake-dev's own
/// `/openapi/v3` says of it (GETs through the context's proxy, then kept),
/// the misspelt field beside it is marked, completion offers the spec's
/// other fields from what was read, and Explain on the bar says
/// `deployment.spec.replicas` as kubectl explain would, in the right-hand
/// pane; a CRD's field is explained from its own schema.
extension E2ERunner {
    func kubernetesAPIDocs(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        guard let editor = app.editor else { return check("the window has an editor", false) }
        let wasShowing = app.store.showingOverlay == .kubernetes
        defer { if (app.store.showingOverlay == .kubernetes) != wasShowing { app.toggleKubernetesPage(nil) } }
        if !wasShowing { app.toggleKubernetesPage(nil) }
        model.select("fake-dev")
        model.setScope(.namespace("shop"))
        check("docs: on fake-dev", await eventually(10) { model.selectedName == "fake-dev" })
        // The editor in front: the page steps aside, its context stays the one picked.
        app.toggleKubernetesPage(nil)
        model.apiDocs.forgetAll()
        fake.addCRD(
            group: "docs.example.com", version: "v1", plural: "sprockets", kind: "Sprocket", shortNames: ["spk"],
            schema: [
                "type": "object", "description": "What the sprocket does.",
                "properties": ["size": ["type": "integer", "description": "How many sprockets turn at once."]],
            ])
        defer { fake.removeCRD("sprockets.docs.example.com") }
        let checkout = scratch.appendingPathComponent("k8s-docs-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let file = checkout.appendingPathComponent("web.yaml")
        let text = """
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: web
              namespace: shop
            spec:
              replicas: 2
              replicaz: 3
              template:
                spec:
                  containers:
                  - name: web
                    image: nginx:1.27

            """
        try? text.write(to: file, atomically: true, encoding: .utf8)
        fake.forgetRequests()
        app.openInEditor(file)
        check(
            "a checkout's manifest gets its bar",
            await eventually(10) { editor.active?.url?.standardizedFileURL == file.standardizedFileURL && editor.active?.kubeManifest != nil })
        guard let buffer = editor.active, let session = buffer.kubeManifest else { return }
        defer {
            if let index = editor.buffers.firstIndex(where: { $0 === buffer }) { editor.removeBuffer(at: index) }
        }
        check("on the page's context", session.contextName == "fake-dev", session.contextName ?? "none")
        check("Explain on its bar", await shownText(15) { $0.contains("Explain") } != nil)
        await pause(1)
        let openAPI = { fake.requests.filter { $0.path.hasPrefix("/openapi") } }
        check("nothing read while not asked", openAPI().isEmpty, "\(openAPI())")
        check("nothing marked before", buffer.kubeDiagnostics.isEmpty)

        // A hover: the field's docs, from fake-dev's own /openapi/v3.
        let replicas = (text as NSString).range(of: "replicas").location + 2
        editor.textView.setSelectedRange(NSRange(location: replicas, length: 0))
        check("the editor's window has the keyboard", editor.view.window?.isKeyWindow == true)
        editor.showHover(at: replicas, fromKeyboard: true)
        check("a hover shows replicas' docs", await eventually(15) { Self.hoverText(editor).contains("Number of desired pods") }, Self.hoverText(editor))
        let hover = Self.hoverText(editor)
        check("its type, its path and whose docs", hover.contains("replicas <integer>") && hover.contains("Deployment.spec.replicas") && hover.contains("fake-dev's API"), hover)
        check(
            "read with GETs: the index, then apps/v1's document", openAPI().map(\.path) == ["/openapi/v3", "/openapi/v3/apis/apps/v1"] && openAPI().allSatisfy { $0.method == "GET" },
            "\(openAPI())")
        check("nothing written", fake.writes.isEmpty, "\(fake.writes)")
        check("said on the bar", session.docsNote?.hasPrefix("Field docs: fake-dev's API") == true, session.docsNote ?? "none")
        check(
            "the misspelt field marked", await eventually(5) { buffer.kubeDiagnostics.map { (text as NSString).substring(with: $0.range) } == ["replicaz"] },
            "\(buffer.kubeDiagnostics)")
        check("saying so", buffer.kubeDiagnostics.first?.message.contains("Unknown field \"replicaz\" in Deployment.spec") == true, buffer.kubeDiagnostics.first?.message ?? "")
        editor.hover?.close()

        // Completion: the spec's fields, from what was read.
        fake.forgetRequests()
        let typed = text.replacingOccurrences(of: "  replicaz: 3\n", with: "  replicaz: 3\n  rev\n")
        editor.replaceText(of: buffer, with: typed)
        let caret = (typed as NSString).range(of: "  rev\n").location + 5
        editor.textView.setSelectedRange(NSRange(location: caret, length: 0))
        editor.triggerCompletion(manual: false)
        let labels = editor.completion.map { state in state.shown.map { state.candidates[$0].label } } ?? []
        check("completion offers the spec's fields", editor.completion?.isKube == true && labels.first == "revisionHistoryLimit", "\(labels)")
        if let index = labels.firstIndex(of: "revisionHistoryLimit") { editor.acceptCompletion(at: index) }
        check("accepted as a key", buffer.storage.string.contains("\n  revisionHistoryLimit: \n"), buffer.storage.string)
        check("from the cache: nothing read again", openAPI().isEmpty, "\(openAPI())")

        // Explain on the bar: the field at the caret, kubectl explain's words, beside the editor.
        let at = (buffer.storage.string as NSString).range(of: "replicas").location + 1
        editor.textView.setSelectedRange(NSRange(location: at, length: 0))
        let explain = session.explainAtCaret()
        check("explain deployment.spec.replicas", explain.query == "deployment.spec.replicas" && explain.apiVersion == "apps/v1", explain.query)
        check("explained", await eventually(15) { explain.result?.spokenPath == "Deployment.spec.replicas" }, "\(explain.state)")
        check("in the right-hand pane", app.rightPane.mode == .manifest && app.kubernetesManifest.shown == .explain && app.kubernetesManifest.explain === explain)
        let said = explain.text ?? ""
        check("as kubectl says it", said.contains("KIND:       Deployment") && said.contains("FIELD: replicas <integer>") && said.contains("Number of desired pods"), said)
        check("the line it equals", explain.kubectl == "kubectl explain deployment.spec.replicas --context fake-dev --api-version apps/v1", explain.kubectl ?? "none")
        check("drawn", await shownText(15) { $0.contains("Deployment.spec.replicas") } != nil)
        explain.up()
        check("up to spec, its fields listed", await eventually(15) { explain.result?.spokenPath == "Deployment.spec" }, "\(explain.state)")
        check("drawn with its fields", await shownText(15) { $0.contains("minReadySeconds") } != nil)

        // A CRD's field, from the palette's Explain on the page's context.
        let titles = app.kubernetesPaletteItems().map(\.title)
        check("⌘K offers Kubernetes Explain…", titles.contains("Kubernetes Explain…"))
        let crd = app.showKubernetesExplain("sprocket.spec.size")
        check("the palette's reads nothing until asked", crd.result == nil && crd.state == .idle)
        crd.explain()
        check("a CRD's field explained from its schema", await eventually(15) { crd.result?.description == "How many sprockets turn at once." }, "\(crd.state)")
        check("its type", crd.result?.type == "integer")
        check(
            "its group's document read", fake.requests.contains { $0.path == "/openapi/v3/apis/docs.example.com/v1" },
            "\(fake.requests.filter { $0.path.hasPrefix("/openapi") })")
        check("and still nothing written", fake.writes.isEmpty, "\(fake.writes)")

        // ⌃Space where the docs can't be read (a server without OpenAPI v3):
        // the regular completion still comes, the buffer's words at least.
        fake.servesOpenAPI = false
        model.apiDocs.forgetAll()
        defer {
            fake.servesOpenAPI = true
            model.apiDocs.forgetAll()
        }
        let unread = text.replacingOccurrences(of: "  replicaz: 3\n", with: "  replicaz: 3\n  na\n")
        editor.replaceText(of: buffer, with: unread)
        let unreadCaret = (unread as NSString).range(of: "  na\n").location + 4
        editor.textView.setSelectedRange(NSRange(location: unreadCaret, length: 0))
        editor.triggerCompletion(manual: true)
        let words = {
            editor.completion.flatMap { state in state.isKube ? nil : state.shown.map { state.candidates[$0].label } } ?? []
        }
        check("⌃Space without the docs: the regular completion", await eventually(10) { words().contains("name") }, "\(words())")
        check(
            "the docs' failure said on the bar", session.docsNote?.contains("serves no OpenAPI v3") == true, session.docsNote ?? "none")
        editor.dismissCompletion()
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_EXPLAIN_PNG"], !png.isEmpty {
            await pause(0.8)
            app.captureWindow(to: png)
        }
    }

    /// What the editor's hover shows now.
    static func hoverText(_ editor: EditorViewController) -> String {
        guard let popover = editor.hover, popover.isShown, let scroll = popover.contentViewController?.view as? NSScrollView,
            let text = scroll.documentView as? NSTextView
        else { return "" }
        return text.string
    }
}
