import AppKit
import Foundation

/// Stage 4's pod files: `kubectl cp` in a tab, against the fake API server,
/// never a real cluster — the copy is **recorded, not typed** (the fake
/// has no exec, and no kubectl runs but the stand-in's can-i).
///
/// On `fake-dev` (remote, read-only): a pod's Copy from Container is
/// offered once the stand-in's `kubectl auth can-i create pods/exec` says
/// yes; Copy into Container is greyed with the class check's why and
/// refused, nothing asked. Copy Out asks the container's path in the
/// window's own sheet (an odd one: a quote and a space), then where on
/// this Mac (the runner answers the save panel with its own folder), then
/// the confirmation naming the context, namespace, pod, container and both
/// paths with the command; Cancel records nothing, confirmed it is
/// recorded quoted for zsh, in a tab pinned to fake-dev. Made writable by
/// its `kubernetes.contexts` entry, Copy In picks a file (the runner
/// answers the open panel), asks where in the container (`/tmp/<name>`
/// offered) and is recorded the same way. On `fake-prod` a copy in is
/// refused (read-only), and a copy out is asked with PRODUCTION on its
/// scope. Nothing but GETs and access reviews reaches the fake.
extension E2ERunner {
    func kubernetesPodFiles(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        let wasShowing = app.store.showingOverlay == .kubernetes
        if !wasShowing { app.showKubernetesPage() }
        let opened = Set(app.store.tabs.map(\.id))
        var recorded: [(command: String, tab: Tab)] = []
        recordKubernetesCommands { recorded.append(($0, $1)) }
        let actions = page.actions
        let folder = AppEnvironment.supportDirectory.appendingPathComponent("PodFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let local = folder.appendingPathComponent("app.conf")
        try? "worker_processes 1;\n".write(to: local, atomically: true, encoding: .utf8)
        var suggested: [String] = []
        var openAsked: [String] = []
        // The panels are the runner's to answer: the run's own folder, its own file.
        page.actions?.pickSave = { name, then in
            suggested.append(name)
            then(folder.appendingPathComponent(name))
        }
        page.actions?.pickOpen = { message, then in
            openAsked.append(message)
            then(local)
        }
        defer {
            page.actions = actions
            app.kubernetesCommandRecorder = nil
            app.closeTabsWithoutAsking(app.store.tabs.filter { !opened.contains($0.id) })
            Settings.shared.set("kubernetes.contexts", nil)
            page.writeStatus = nil
            try? FileManager.default.removeItem(at: folder)
            if !wasShowing, app.store.showingOverlay == .kubernetes { app.toggleKubernetesPage(nil) }
        }
        func back() { if app.store.showingOverlay != .kubernetes { app.showKubernetesPage() } }
        func verb(_ v: KubeProcessVerb, _ id: String) -> ResourceVerb? { page.verbs(for: [id]).first { $0.title == KubePodCopy.title(v) } }
        /// The window's own text sheet: what it offers, then the text given and OK.
        func answerText(_ text: String) async -> String? {
            guard await eventually(10, { self.window.attachedSheet != nil }), let sheet = window.attachedSheet,
                let field = Self.find(NSTextField.self, in: sheet.contentView, where: { $0.identifier?.rawValue == "fileNameField" })
            else { return nil }
            let offered = field.stringValue
            field.stringValue = text
            window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            return offered
        }
        let q = KubeCommands.quoted
        let readOnly = KubeProcessCheck.readOnly(.remote)

        // fake-dev: read-only — out offered once can-i says yes, in refused.
        model.select("fake-dev")
        model.setScope(.namespace("shop"))
        // A pod of its own: earlier writes deleted web-7d9.
        fake.addPod("files-0", namespace: "shop")
        let pod = KubeRowID(namespace: "shop", name: "files-0")
        guard await showKubernetesKind(model, page, "po", row: pod) else { return }
        page.selection = ["shop/files-0"]
        page.writeStatus = nil
        fake.forgetRequests()
        check(
            "Copy from Container is offered once can-i says yes",
            await eventually(15) { verb(.copyOut, "shop/files-0").map { $0.unavailable == nil } == true },
            verb(.copyOut, "shop/files-0")?.unavailable ?? "none")
        check(
            "Copy into Container is greyed with why on read-only fake-dev", verb(.copyIn, "shop/files-0")?.unavailable == readOnly,
            verb(.copyIn, "shop/files-0")?.unavailable ?? "none")
        if let ref = page.ref(for: "shop/files-0") {
            let titles = page.detailVerbs(for: ref).map(\.title)
            check("the pod's detail offers both", titles.contains(KubePodCopy.title(.copyOut)) && titles.contains(KubePodCopy.title(.copyIn)), "\(titles)")
        }
        verb(.copyIn, "shop/files-0")?.perform()
        check("Copy In is refused at once", page.writeStatus == .failed(readOnly) && window.attachedSheet == nil, "\(String(describing: page.writeStatus))")
        check("the refusal drawn", await shownText(15) { $0.contains("This context is read-only") } != nil)
        check("nothing asked or picked", openAsked.isEmpty && recorded.isEmpty)
        page.writeStatus = nil

        // Copy Out: the container's path, where on this Mac, the confirmation, recorded.
        let remote = "/var/log/app's log.txt"
        verb(.copyOut, "shop/files-0")?.perform()
        let offered = await answerText(remote)
        check("the container's path is asked, empty without a workingDir", offered == "", offered ?? "no sheet: \(String(describing: page.writeStatus))")
        check("then where on this Mac, its name suggested", await eventually(10) { suggested == ["app's log.txt"] }, "\(suggested)")
        check("then the copy is asked", await eventually(10) { self.sheetTexts().contains { $0.contains("Copy \(remote) out of pod shop/files-0?") } }, "\(sheetTexts())")
        let saved = folder.appendingPathComponent("app's log.txt").path
        let outLine = "kubectl cp \(q("files-0:" + remote)) \(q(saved)) -c app --context fake-dev -n shop"
        let said = sheetTexts().joined(separator: "\n")
        check("naming the context and namespace", said.contains("fake-dev · namespace shop"), said)
        check("the pod, its container and both paths", said.contains("pod shop/files-0, container app: \(remote)") && said.contains("app's log.txt"), said)
        check("and the command its tab runs, quoted for zsh", said.contains(outLine), said)
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        _ = await eventually(3) { self.window.attachedSheet == nil }
        await pause(0.3)
        check("Cancel records nothing", recorded.isEmpty, "\(recorded.map(\.command))")
        page.writeStatus = nil
        verb(.copyOut, "shop/files-0")?.perform()
        _ = await answerText(remote)
        check("asked again", await eventually(10) { self.sheetTexts().contains { $0.contains(outLine) } }, "\(sheetTexts())")
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check("confirmed, it is recorded, not typed", await eventually(10) { recorded.count == 1 }, "\(String(describing: page.writeStatus))")
        check("kubectl cp out, its context and namespace said", recorded.first?.command == outLine, recorded.first?.command ?? "")
        check(
            "in a tab pinned to fake-dev in shop", recorded.first?.tab.kubePin?.context == "fake-dev" && recorded.first?.tab.kubePin?.namespace == "shop",
            "\(String(describing: recorded.first?.tab.kubePin))")
        check(
            "the page says so", page.writeStatus == .done("Copying \(remote) out of pod shop/files-0 in a new tab, in fake-dev."),
            "\(String(describing: page.writeStatus))")

        // Made writable by its entry, Copy In: the file picked, where in the container, recorded.
        back()
        Settings.shared.set("kubernetes.contexts", .entries(["fake-dev": ["writable": .bool(true)]]))
        check("fake-dev writable by its entry", await eventually(10) { model.contexts.context(named: "fake-dev")?.isWritable == true })
        guard await showKubernetesKind(model, page, "po", row: pod) else { return }
        page.selection = ["shop/files-0"]
        page.writeStatus = nil
        check(
            "Copy into Container is offered now", await eventually(15) { verb(.copyIn, "shop/files-0").map { $0.unavailable == nil } == true },
            verb(.copyIn, "shop/files-0")?.unavailable ?? "none")
        verb(.copyIn, "shop/files-0")?.perform()
        let into = await answerText("/etc/nginx/app.conf")
        check(
            "the file is picked first, naming the pod and container",
            openAsked.last == "Copy a file or folder into pod shop/files-0, container app in fake-dev.", "\(openAsked)")
        check("then where in the container, /tmp/<name> offered", into == "/tmp/app.conf", into ?? "no sheet: \(String(describing: page.writeStatus))")
        let inLine = "kubectl cp \(q(local.path)) files-0:/etc/nginx/app.conf -c app --context fake-dev -n shop"
        check("then the copy in is asked, with its command", await eventually(10) { self.sheetTexts().contains { $0.contains(inLine) } }, "\(sheetTexts())")
        let intoSaid = sheetTexts().joined(separator: "\n")
        check(
            "naming the pod, container and both paths",
            intoSaid.contains("Copy app.conf into pod shop/files-0?") && intoSaid.contains("pod shop/files-0, container app: /etc/nginx/app.conf")
                && intoSaid.contains("fake-dev · namespace shop"), intoSaid)
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check("confirmed, recorded", await eventually(10) { recorded.count == 2 } && recorded.last?.command == inLine, recorded.last?.command ?? "")
        check("pinned the same", recorded.last?.tab.kubePin?.context == "fake-dev" && recorded.last?.tab.kubePin?.namespace == "shop")
        // The page follows settings while it shows: back to it first.
        back()
        Settings.shared.set("kubernetes.contexts", nil)
        check("read-only again", await eventually(10) { model.contexts.context(named: "fake-dev")?.isWritable == false })

        // fake-prod: a copy in refused; a copy out asked with PRODUCTION on its scope.
        back()
        model.select("fake-prod")
        model.setScope(.namespace("payments"))
        fake.addPod("files-1", namespace: "payments")
        let prodPod = KubeRowID(namespace: "payments", name: "files-1")
        if await showKubernetesKind(model, page, "po", row: prodPod) {
            page.selection = ["payments/files-1"]
            page.writeStatus = nil
            let prodReadOnly = KubeProcessCheck.readOnly(.production)
            check("fake-prod's Copy In is greyed with why", verb(.copyIn, "payments/files-1")?.unavailable == prodReadOnly, verb(.copyIn, "payments/files-1")?.unavailable ?? "none")
            verb(.copyIn, "payments/files-1")?.perform()
            check("and refused", page.writeStatus == .failed(prodReadOnly) && window.attachedSheet == nil, "\(String(describing: page.writeStatus))")
            page.writeStatus = nil
            check("its Copy Out is offered after can-i", await eventually(15) { verb(.copyOut, "payments/files-1").map { $0.unavailable == nil } == true })
            verb(.copyOut, "payments/files-1")?.perform()
            _ = await answerText("/app/config.yaml")
            check(
                "asked with PRODUCTION, the context and namespace",
                await eventually(10) { self.sheetTexts().contains { $0.contains("PRODUCTION · fake-prod · namespace payments") } }, "\(sheetTexts())")
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
            _ = await eventually(3) { self.window.attachedSheet == nil }
            await pause(0.3)
            check("Cancel records nothing", recorded.count == 2)
        }
        check(
            "only GETs and access reviews reached the fake: no exec, no write", fake.writes.allSatisfy(\.isAccessReview) && !fake.requests.contains { $0.path.contains("/exec") },
            "\(fake.writes.filter { !$0.isAccessReview })")
        model.select("fake-dev")
        model.setScope(.namespace("shop"))
    }
}
