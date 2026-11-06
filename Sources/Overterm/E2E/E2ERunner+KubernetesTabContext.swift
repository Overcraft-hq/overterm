import AppKit
import Foundation

/// Stage 3b's tab context and kubectl helpers (docs/design/kubernetes/analysis.md,
/// 3.11, 2.8, 2.11, decision 18; Section 9: one check each). No kubectl is run:
/// a pane's command is its title, as shell integration sets it.
///
/// - **The pane-header warning**: a plain pane's `kubectl get pods` reaches
///   the run's kubeconfig's current context, fake-dev — nothing said; one
///   with `--context fake-prod` is said in red (drawn); a `kubectx` that
///   rewrites the file to fake-prod is seen without a command (the file
///   watched), and a plain kubectl then says "probably fake-prod" (drawn).
///   A relative `--kubeconfig` is read from the command's folder; one
///   outside the run's own is never read. The file is put back as it was.
/// - **New Task pinned**: in a repository of the run's own, the offer has
///   every context but production; a task pinned to kind-fake gets its tab
///   pinned there, its `KUBECONFIG` the pin's file first; one asked for
///   fake-prod is refused before any worktree is made, and one whose
///   worktree fails leaves no pin's file.
/// - **Snippets**: a snippet naming `${context}`, `${namespace}` and
///   `${pod}` is in a pod's menu; on fake-dev it is **recorded, not typed**,
///   filled and quoted, in a tab pinned to fake-dev/shop; on fake-prod it
///   is asked first, the line shown, then recorded.
/// - **Templates**: the Deployment template opens as Overterm's copy in the
///   editor, 0600, in the namespace shown, its manifest bar on the page's
///   context; never saved, removed with its tab. A Secret's, its value
///   typed in, is applied to kind-fake (asked first) and its tab closed.
/// - **Saved filters**: the filter saved for fake-dev's pods in shop, kept
///   in the run's own `Kubernetes/filters.json`, offered by the palette,
///   and shown again from another context.
extension E2ERunner {
    func kubernetesTabContext(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, kubeconfig: URL) async {
        if app.store.showingOverlay == .kubernetes { app.toggleKubernetesPage(nil) }
        await kubernetesPaneWarning(kubeconfig: kubeconfig)
        await kubernetesNewTaskPinned()
        if app.store.showingOverlay != .kubernetes { app.toggleKubernetesPage(nil) }
        model.select("fake-dev")
        model.setScope(.namespace("shop"))
        page.filter = ""
        page.applySelector()
        page.closeDetail()
        page.showKind(.pods)
        await kubernetesSnippets(model, page)
        await kubernetesTemplate(model, page, fake)
        await kubernetesSavedFilters(model, page)
        if app.store.showingOverlay == .kubernetes { app.toggleKubernetesPage(nil) }
    }

    private func kubernetesPaneWarning(kubeconfig: URL) async {
        let ambient = KubeAmbientContexts.shared
        let opened = Set(app.store.tabs.map(\.id))
        app.newTab(in: FileManager.default.temporaryDirectory)
        defer { app.closeTabsWithoutAsking(app.store.tabs.filter { !opened.contains($0.id) }) }
        guard let tab = app.store.selected, !opened.contains(tab.id) else { return check("a plain tab for the warning", false) }
        let pane = tab.terminal
        let blocks = app.blocks(of: pane)
        // The new shell's own titles first: a command's title is what it runs.
        await pause(2)
        func warning() -> KubePaneWarning? {
            ambient.warning(command: blocks.latestCommand, cwd: blocks.commandFolder, pin: pane.kubePin, lost: pane.kubePinLost != nil)
        }

        blocks.titleChanged("kubectl get pods", cwd: nil)
        check(
            "a kubectl in a pane reads the files a plain kubectl reads — the run's kubeconfig alone",
            await eventually(10) { ambient.list?.current == "fake-dev" && ambient.list?.files.map(\.path) == [kubeconfig.path] },
            "\(String(describing: ambient.list?.files)) \(String(describing: ambient.list?.current))")
        check("fake-dev isn't production: nothing said", warning()?.context == "fake-dev" && warning()?.shown == false, "\(String(describing: warning()))")

        blocks.titleChanged("kubectl --context fake-prod delete pod web-7d9", cwd: nil)
        check(
            "--context fake-prod: said for certain", warning()?.shown == true && warning()?.source == .flag && warning()?.label == "⎈ fake-prod",
            "\(String(describing: warning()))")
        check("in the pane's header", await shownText(15) { $0.contains("fake-prod") && !$0.contains("probably") } != nil)

        // A kubectx: the file rewritten, current-context fake-prod. Seen by the watch, not by a command.
        let before = (try? String(contentsOf: kubeconfig, encoding: .utf8)) ?? ""
        try? before.replacingOccurrences(of: "current-context: fake-dev", with: "current-context: fake-prod").write(
            to: kubeconfig, atomically: true, encoding: .utf8)
        check("the file's change is seen, no command run", await eventually(10) { ambient.list?.current == "fake-prod" }, "\(String(describing: ambient.list?.current))")
        blocks.titleChanged("kubectl delete pod web-7d9", cwd: nil)
        check(
            "a plain kubectl: probably fake-prod", warning()?.shown == true && warning()?.probably == true && warning()?.label == "⎈ probably fake-prod",
            "\(String(describing: warning()))")
        check("said so in the header", await shownText(15) { $0.contains("probably fake-prod") } != nil)
        // A relative --kubeconfig: the folder the command ran in.
        blocks.titleChanged("kubectl --kubeconfig ./\(kubeconfig.lastPathComponent) delete pod web-7d9", cwd: kubeconfig.deletingLastPathComponent().path)
        check(
            "a relative --kubeconfig is read from the command's folder: fake-prod, for certain",
            await eventually(10) { warning()?.source == .kubeconfigFlag && warning()?.shown == true && warning()?.probably == false },
            "\(String(describing: warning()))")
        // Guarded, a file outside the run's own is never read.
        let outside = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("ot-e2e-never-\(UUID().uuidString.prefix(6))/config")
        blocks.titleChanged("kubectl --kubeconfig \(outside.path) get pods", cwd: nil)
        await pause(0.5)
        check("an isolated run reads no kubeconfig of the user's a command names", ambient.named[outside.path] == nil && warning() == nil, "\(ambient.named.keys)")
        blocks.titleChanged("kubectl delete pod web-7d9", cwd: nil)
        try? before.write(to: kubeconfig, atomically: true, encoding: .utf8)
        check("put back, it says nothing again", await eventually(10) { ambient.list?.current == "fake-dev" && warning()?.shown == false })
        blocks.titleChanged("git status", cwd: nil)
        check("a command not kubectl's says nothing", warning() == nil)
    }

    private func kubernetesNewTaskPinned() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ot-e2e-task-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let repo = root.appendingPathComponent("shop", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            _ = try await Git.run(["init", "-q", "-b", "main"], in: repo)
            _ = try await Git.run(["-c", "user.name=e2e", "-c", "user.email=e2e@example.invalid", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        } catch {
            return check("a repository of the run's own", false, "\(error)")
        }
        let offer = await TerminalWindowController.kubernetesTaskOffer(for: repo)
        check(
            "New Task offers every context but production", offer.choices.map(\.context).sorted() == ["fake-dev", "kind-fake"],
            "\(offer.choices.map(\.context))")
        let opened = Set(app.store.tabs.map(\.id))
        defer { app.closeTabsWithoutAsking(app.store.tabs.filter { !opened.contains($0.id) }) }
        do {
            try await app.createTask(repo: repo, branch: "feat/pinned", base: "main", agent: nil, kubeContext: "kind-fake")
        } catch {
            return check("a task pinned to kind-fake", false, error.localizedDescription)
        }
        let tab = app.store.selected
        check("its tab is pinned to kind-fake", tab.map { !opened.contains($0.id) } == true && tab?.kubePin?.context == "kind-fake", "\(String(describing: tab?.kubePin))")
        check("in kind-fake's own namespace", tab?.kubePin?.namespace == "shop")
        let first = KubeTerminalEnvironment.firstFile(of: tab?.terminal.environment["KUBECONFIG"]) ?? ""
        check(
            "its KUBECONFIG starts with the pin's file", first.hasPrefix(AppEnvironment.supportDirectory.appendingPathComponent("Kubernetes/Contexts").path),
            tab?.terminal.environment["KUBECONFIG"] ?? "none")
        check("in the task's worktree", tab?.terminal.workingDirectory?.hasSuffix("shop-wt-feat-pinned") == true, tab?.terminal.workingDirectory ?? "")
        var refused: String?
        do {
            try await app.createTask(repo: repo, branch: "feat/prod", base: "main", agent: nil, kubeContext: "fake-prod")
        } catch {
            refused = error.localizedDescription
        }
        check("pinned to fake-prod, refused", refused?.contains("production") == true, refused ?? "made")
        let prodTree = TaskCreator.worktreePath(repo: repo, branch: "feat/prod", location: Settings.shared.worktreeLocation)
        check("before any worktree is made", !FileManager.default.fileExists(atPath: prodTree.path))
        // A worktree that fails (its path is taken) leaves no pin's file behind.
        let pins = KubeTerminalFiles.defaultFolder
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: pins.path)) ?? [])
        var failed: String?
        do {
            try await app.createTask(repo: repo, branch: "feat/pinned", base: "main", agent: nil, kubeContext: "kind-fake")
        } catch {
            failed = error.localizedDescription
        }
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: pins.path)) ?? [])
        check("a task whose worktree fails is refused", failed != nil, failed ?? "made")
        check("and leaves nothing in Kubernetes/Contexts", after == before, "\(after.subtracting(before))")
        let pinnedTree = TaskCreator.worktreePath(repo: repo, branch: "feat/pinned", location: Settings.shared.worktreeLocation)
        _ = try? await Git.run(["worktree", "remove", "--force", pinnedTree.path], in: repo)
        try? FileManager.default.removeItem(at: pinnedTree)
    }

    private func kubernetesSnippets(_ model: KubernetesModel, _ page: KubernetesPageModel) async {
        let snippet = Snippet(name: "Tail web", command: "kubectl --context ${context} -n ${namespace} logs ${pod} --tail=20")
        app.snippets.upsert(snippet)
        let opened = Set(app.store.tabs.map(\.id))
        var recorded: [(command: String, tab: Tab)] = []
        app.kubernetesCommandRecorder = { command, tab in recorded.append((command, tab)) }
        defer {
            app.kubernetesCommandRecorder = nil
            app.snippets.delete(snippet)
            app.closeTabsWithoutAsking(app.store.tabs.filter { !opened.contains($0.id) })
            if app.store.showingOverlay != .kubernetes { app.toggleKubernetesPage(nil) }
        }
        func child(_ id: String) -> ResourceVerb? {
            page.verbs(for: [id]).first { $0.title == KubernetesPageModel.snippetsTitle }?.children.first { $0.title == "Tail web" }
        }
        func pod(in namespace: String) -> String? {
            guard model.kind.fullName == KubeResourceKind.pods.fullName, model.listState == .live else { return nil }
            return model.rows.sorted.first { $0.id.namespace == namespace }?.id.name
        }
        guard await eventually(15, { pod(in: "shop") != nil }), let devPod = pod(in: "shop") else {
            return check("fake-dev's pods listed for the snippet", false, "\(model.listState) \(model.kind.fullName)")
        }
        check("a Kubernetes snippet is in a pod's menu", child("shop/\(devPod)") != nil, "\(page.verbs(for: ["shop/\(devPod)"]).map(\.title))")
        child("shop/\(devPod)")?.perform()
        check("run, it is recorded, not typed", await eventually(10) { recorded.count == 1 }, page.commandProblem ?? "")
        check("filled from the pod", recorded.first?.command == "kubectl --context fake-dev -n shop logs \(devPod) --tail=20", recorded.first?.command ?? "")
        check(
            "in a tab pinned to fake-dev/shop", recorded.first?.tab.kubePin?.context == "fake-dev" && recorded.first?.tab.kubePin?.namespace == "shop",
            "\(String(describing: recorded.first?.tab.kubePin))")

        if app.store.showingOverlay != .kubernetes { app.toggleKubernetesPage(nil) }
        model.select("fake-prod")
        model.setScope(.namespace("payments"))
        guard await eventually(15, { model.selectedName == "fake-prod" && pod(in: "payments") != nil }), let prodPod = pod(in: "payments") else {
            model.select("fake-dev")
            return check("fake-prod's pods listed for the snippet", false, "\(model.listState)")
        }
        child("payments/\(prodPod)")?.perform()
        check("on production it is asked first", await eventually(10) { self.window.attachedSheet != nil }, page.commandProblem ?? "")
        let asked = sheetTexts().joined(separator: "\n")
        let line = "kubectl --context fake-prod -n payments logs \(prodPod) --tail=20"
        check("naming the context and the line", asked.contains("PRODUCTION") && asked.contains("fake-prod") && asked.contains(line), asked)
        check("nothing recorded while it asks", recorded.count == 1)
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check("confirmed, it is recorded", await eventually(10) { recorded.count == 2 } && recorded.last?.command == line, recorded.last?.command ?? "")
        check("in a tab pinned to production", recorded.last?.tab.kubePin?.isProduction == true)
        model.select("fake-dev")
        model.setScope(.namespace("shop"))
    }

    private func kubernetesTemplate(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        guard let editor = app.editor else { return check("the window has an editor", false) }
        if app.store.showingOverlay != .kubernetes { app.toggleKubernetesPage(nil) }
        let titles = app.kubernetesPaletteItems().map(\.title)
        check("⌘K offers New Kubernetes Deployment", titles.contains("New Kubernetes Deployment"), "\(titles.filter { $0.hasPrefix("New Kubernetes") })")
        guard let template = KubeTemplates.list().first(where: { $0.kind == "Deployment" }) else {
            return check("the app bundles the Deployment template", false, KubeTemplates.bundled?.path ?? "no resources")
        }
        guard let url = page.newFromTemplate(template) else { return check("the template opens", false, "\(String(describing: page.writeStatus))") }
        check("in the editor, the page aside", await eventually(10) { editor.active?.url?.standardizedFileURL == url.standardizedFileURL && self.app.store.showingOverlay == nil })
        check(
            "Overterm's copy, 0600, in the run's support folder",
            url.path.hasPrefix(AppEnvironment.supportDirectory.appendingPathComponent("Kubernetes/Edits").path)
                && (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600, url.path)
        let text = editor.active?.storage.string ?? ""
        check("in the namespace shown", text.contains("namespace: \"shop\"") && !text.contains("${"), text)
        check("its manifest bar, on the page's context", editor.active?.kubeManifest?.contextName == "fake-dev" && editor.active?.kubeManifest?.isOwnCopy == false)
        check("drawn", await shownText(15) { $0.contains("A new Deployment from a template") || $0.contains("Diff with Cluster") } != nil)
        if let buffer = editor.active {
            editor.save(buffer, overwriting: false)
            check("never saved", buffer.document.unsaveable == KubeManifestEdits.templateUnsaved)
        }
        if let index = editor.buffers.firstIndex(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) { editor.removeBuffer(at: index) }
        check("removed with its tab", !FileManager.default.fileExists(atPath: url.path) && !KubeManifestEdits.isTemplate(url))
        await kubernetesSecretTemplate(page, editor: editor, fake: fake)
    }

    /// 2.18: a Secret from its template — the value typed into the copy,
    /// applied on kind-fake (writable), then the copy's tab closed and its file gone.
    private func kubernetesSecretTemplate(_ page: KubernetesPageModel, editor: EditorViewController, fake: FakeKubeAPI) async {
        guard let template = KubeTemplates.list().first(where: { $0.kind == "Secret" }) else { return check("the app bundles the Secret template", false) }
        if app.store.showingOverlay != .kubernetes { app.toggleKubernetesPage(nil) }
        let model = page.model
        model.select("kind-fake")
        defer {
            model.select("fake-dev")
            model.setScope(.namespace("shop"))
        }
        guard await eventually(10, { model.selectedName == "kind-fake" }) else { return check("kind-fake picked for the Secret", false) }
        guard let url = page.newFromTemplate(template) else { return check("the Secret template opens", false, "\(String(describing: page.writeStatus))") }
        guard await eventually(10, { editor.active?.url?.standardizedFileURL == url.standardizedFileURL && editor.active?.kubeManifest != nil }),
            let buffer = editor.active, let session = buffer.kubeManifest
        else { return check("the Secret's copy in the editor", false) }
        let name = "ot-e2e-secret-\(UUID().uuidString.prefix(4).lowercased())"
        let typed = buffer.storage.string.replacingOccurrences(of: "name: my-secret", with: "name: \(name)")
            .replacingOccurrences(of: "password: \"\"", with: "password: \"e2e-typed-value\"")
        editor.replaceText(of: buffer, with: typed)
        session.apply()
        check("the Secret's apply is asked in the window", await eventually(15) { self.window.attachedSheet != nil }, "\(session.state)")
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check(
            "it lands on kind-fake",
            await eventually(15) { fake.writes.contains { $0.method == "PATCH" && $0.path.hasSuffix("/secrets/\(name)") && $0.query["dryRun"] == nil } },
            "\(session.state) \(fake.writes.map(\.description))")
        check(
            "applied, the copy's tab is closed — the typed value with it",
            await eventually(10) { !editor.buffers.contains { $0.url?.standardizedFileURL == url.standardizedFileURL } }, "\(session.state)")
        check("its file gone", !FileManager.default.fileExists(atPath: url.path) && !KubeManifestEdits.isTemplate(url))
        check("said on the page", page.writeStatus?.text.contains("The template's copy is closed") == true, page.writeStatus?.text ?? "nothing")
    }

    private func kubernetesSavedFilters(_ model: KubernetesModel, _ page: KubernetesPageModel) async {
        if app.store.showingOverlay != .kubernetes { app.toggleKubernetesPage(nil) }
        model.select("fake-dev")
        model.setScope(.namespace("shop"))
        if model.kind.fullName != KubeResourceKind.pods.fullName { page.showKind(.pods) }
        page.filter = "worker"
        guard let saved = page.saveFilter() else { return check("the filter is saved", false) }
        defer { KubeSavedFilters.shared.remove(saved.id) }
        check("for fake-dev's pods in shop", saved.context == "fake-dev" && saved.kind.fullName == "pods" && saved.namespace == "shop", "\(saved)")
        let file = AppEnvironment.supportDirectory.appendingPathComponent("Kubernetes/filters.json")
        check("kept in the run's own filters.json", ((try? String(contentsOf: file, encoding: .utf8)) ?? "").contains("\"worker\""), file.path)
        let titles = app.kubernetesPaletteItems().map(\.title)
        check("⌘K offers it", titles.contains("Kubernetes Filter: worker"), "\(titles.filter { $0.hasPrefix("Kubernetes Filter") })")
        page.filter = ""
        model.select("fake-prod")
        page.applySavedFilter(saved)
        check(
            "used from another context: fake-dev's pods in shop again, filtered",
            await eventually(15) { model.selectedName == "fake-dev" && model.scope == .namespace("shop") && page.rows.map(\.id) == ["shop/worker-5c"] },
            "\(String(describing: model.selectedName)) \(page.rows.map(\.id))")
        page.filter = ""
        page.applySelector()
    }
}
