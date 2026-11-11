import AppKit
import Foundation

/// Stage 3b's node shell and in-place resize, against the fake API server,
/// never a real cluster.
///
/// Node shell: on `kind-fake` (local, writable) a node's Node Shell in a
/// Tab… is greyed with why until the context's `nodeShell` is on — `E`
/// refused, nothing sent; turned on in `kubernetes.contexts`, it is
/// reviewed (create pods, pods/attach), asked in the window's sheet with
/// the node's name typed — a wrong one runs nothing — then **recorded, not
/// typed**: `kubectl debug node/… --profile=sysadmin … -- chroot /host`, in
/// a tab pinned to the context. The pod is kubectl's to make: only reviews
/// reach the fake.
///
/// Resize: Resize in Place… on a pod opens the sheet with each container's
/// values read from the pod; a value typed into its field, Return asks in
/// the window naming the change and the kubectl it equals, and the
/// `resize` subresource's PATCH lands on the fake, the pod's other fields
/// untouched. With the fake no longer serving `pods/resize` (discovery read
/// again), the verb is greyed with why and refused, nothing sent.
extension E2ERunner {
    func kubernetesNodeShellAndResize(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        if app.store.showingOverlay != .kubernetes { app.showKubernetesPage() }
        let opened = Set(app.store.tabs.map(\.id))
        var recorded: [(command: String, tab: Tab)] = []
        recordKubernetesCommands { recorded.append(($0, $1)) }
        defer {
            app.kubernetesCommandRecorder = nil
            app.closeTabsWithoutAsking(app.store.tabs.filter { !opened.contains($0.id) })
            Settings.shared.set("kubernetes.contexts", nil)
            fake.servesResize = true
            page.writeStatus = nil
        }
        func verb(_ title: String, _ id: String) -> ResourceVerb? { page.verbs(for: [id]).first { $0.title == title } }
        func back() { if app.store.showingOverlay != .kubernetes { app.showKubernetesPage() } }

        // The node shell: off until the context's nodeShell is on.
        model.writeAccess.forget(context: "kind-fake")
        model.select("kind-fake")
        model.setScope(.namespace("shop"))
        let node = KubeRowID(namespace: nil, name: "fake-node-1")
        guard await showKubernetesKind(model, page, "no", row: node) else { return }
        page.selection = ["fake-node-1"]
        page.writeStatus = nil
        let shellTitle = KubeTabWrite.title(.nodeShell)
        let off = "Node shells are off until the context's nodeShell setting is on."
        check("a node's Node Shell is greyed with why", verb(shellTitle, "fake-node-1")?.unavailable == off, verb(shellTitle, "fake-node-1")?.unavailable ?? "none")
        page.giveListTheKeyboard()
        fake.forgetRequests()
        check("E on the node is refused", await pressKubernetesKey("E", keyCode: 14, shift: true) && page.writeStatus == .failed(off), "\(String(describing: page.writeStatus))")
        check("the refusal drawn", await shownText(15) { $0.contains("Node shells are off") } != nil)
        await pause(0.3)
        check(
            "nothing asked, recorded or reviewed for it",
            window.attachedSheet == nil && recorded.isEmpty && !fake.requests.contains { $0.isAccessReview && ($0.json.map { "\($0)" } ?? "").contains("attach") })

        Settings.shared.set("kubernetes.contexts", .entries(["kind-fake": ["nodeShell": .bool(true)]]))
        check("turned on in kind-fake's entry", await eventually(10) { model.contexts.context(named: "kind-fake")?.settings.nodeShell == true })
        guard await showKubernetesKind(model, page, "no", row: node) else { return }
        page.selection = ["fake-node-1"]
        page.writeStatus = nil
        check(
            "then offered once reviewed", await eventually(10) { verb(shellTitle, "fake-node-1").map { $0.unavailable == nil } == true },
            verb(shellTitle, "fake-node-1")?.unavailable ?? "none")
        let reviewed = fake.requests.filter(\.isAccessReview).compactMap {
            (($0.json as? [String: Any])?["spec"] as? [String: Any])?["resourceAttributes"] as? [String: String]
        }
        check(
            "as the cluster's access review: create pods and pods/attach in shop",
            reviewed.contains(["verb": "create", "resource": "pods", "group": "", "namespace": "shop"])
                && reviewed.contains(["verb": "create", "resource": "pods", "group": "", "subresource": "attach", "namespace": "shop"]), "\(reviewed)")
        let paletteTitles = app.kubernetesPageCommands().map(\.title)
        check("⌘K finds it too", paletteTitles.contains("Kubernetes: Node Shell node fake-node-1 in a Tab…"), "\(paletteTitles)")
        page.giveListTheKeyboard()
        check("E is the list's", await pressKubernetesKey("E", keyCode: 14, shift: true))
        check("the shell is asked in the window", await eventually(10) { self.window.attachedSheet != nil && self.typedNameField() != nil })
        let asked = sheetTexts().joined(separator: "\n")
        let shellLine =
            "kubectl debug node/fake-node-1 -it --profile=sysadmin --image=busybox:1.36 --context kind-fake -n shop -- chroot /host sh -c "
            + "'command -v bash >/dev/null && exec bash || exec sh'"
        check("naming the node, kind-fake and the namespace", asked.contains("Open a shell on node fake-node-1?") && asked.contains("kind-fake · namespace shop"), asked)
        check("privileged, and the pod it leaves", asked.contains("A privileged pod running busybox:1.36") && asked.contains("node-debugger-fake-node-1-"), asked)
        check("the command its tab runs", asked.contains(shellLine), asked)
        check("its name asked for on a local context too", asked.contains("Type fake-node-1 to confirm."), asked)
        typedNameField()?.stringValue = "fake-node-2"
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check("a wrong name runs nothing", await eventually(5) { page.writeStatus == .failed("The name typed wasn't fake-node-1: nothing was run.") } && recorded.isEmpty)
        check("E again", await pressKubernetesKey("E", keyCode: 14, shift: true))
        check("asked again", await eventually(10) { self.window.attachedSheet != nil && self.typedNameField() != nil })
        typedNameField()?.stringValue = "fake-node-1"
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check("its name typed, it is recorded, not typed", await eventually(10) { recorded.count == 1 } && recorded.first?.command == shellLine, recorded.first?.command ?? "")
        check(
            "in a tab pinned to kind-fake", recorded.first?.tab.kubePin?.context == "kind-fake" && recorded.first?.tab.kubePin?.namespace == "shop",
            "\(String(describing: recorded.first?.tab.kubePin))")
        check("the page says so", page.writeStatus == .done("A shell on node fake-node-1 in a new tab, in kind-fake."), "\(String(describing: page.writeStatus))")
        check("only access reviews reached the fake", fake.writes.allSatisfy(\.isAccessReview), "\(fake.writes.filter { !$0.isAccessReview })")
        back()

        // Resize in place: the sheet, the confirmation, the subresource's PATCH.
        var sized = FakeKubeAPI.Pod()
        sized.resources = ["app": ["requests": ["cpu": "100m", "memory": "128Mi"], "limits": ["memory": "256Mi"]]]
        fake.addPod("sized-0", namespace: "shop", sized)
        let pod = KubeRowID(namespace: "shop", name: "sized-0")
        let resizeTitle = KubeWriteVerb.resize.title
        guard await showKubernetesKind(model, page, "po", row: pod) else { return }
        page.selection = ["shop/sized-0"]
        page.writeStatus = nil
        check(
            "a pod's Resize in Place… is offered once reviewed", await eventually(10) { verb(resizeTitle, "shop/sized-0").map { $0.unavailable == nil } == true },
            verb(resizeTitle, "shop/sized-0")?.unavailable ?? "none")
        verb(resizeTitle, "shop/sized-0")?.perform()
        check("its sheet reads the pod's values", await eventually(10) { page.resizeDraft?.current?.first?.cpuRequest == "100m" }, "\(String(describing: page.resizeDraft))")
        check("the sheet drawn", await shownText(15) { $0.contains("Resize pod") } != nil)
        check(
            "its first field has the keyboard",
            await eventually(5) {
                guard let editor = self.window.firstResponder as? NSTextView, let field = editor.delegate as? NSTextField, let view = self.app.kubernetesView
                else { return false }
                return field.isDescendant(of: view) && (field.placeholderString ?? field.placeholderAttributedString?.string) == KubeResize.Field.cpuRequest.placeholder
            }, "\(String(describing: window.firstResponder))")
        fake.forgetRequests()
        if let editor = window.firstResponder as? NSTextView {
            editor.selectAll(nil)
            editor.insertText("250m", replacementRange: editor.selectedRange())
            check("what is typed is the cpu request", page.resizeDraft?.typed.first?.cpuRequest == "250m", "\(String(describing: page.resizeDraft?.typed.first))")
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        }
        check("the resize is asked in the window", await eventually(10) { self.window.attachedSheet != nil }, "\(String(describing: page.writeStatus))")
        let resize = sheetTexts().joined(separator: "\n")
        check("naming the pod and kind-fake", resize.contains("Resize pod shop/sized-0 in place?") && resize.contains("kind-fake · namespace shop"), resize)
        check("the change", resize.contains("app: cpu request 100m → 250m"), resize)
        check("and the kubectl it equals", resize.contains("kubectl patch po sized-0 --subresource resize"), resize)
        check("nothing sent while it asks", !fake.writes.contains { !$0.isAccessReview }, "\(fake.writes.filter { !$0.isAccessReview })")
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check(
            "confirmed, the resize subresource is patched", await eventually(10) { fake.writes.contains { $0.description == "PATCH /api/v1/namespaces/shop/pods/sized-0/resize" } },
            "\(fake.writes)")
        check(
            "the pod's cpu request changed in place",
            fake.pod("sized-0", namespace: "shop")?.resources["app"]?["requests"] == ["cpu": "250m", "memory": "128Mi"]
                && fake.pod("sized-0", namespace: "shop")?.image == "nginx:1.27", "\(String(describing: fake.pod("sized-0", namespace: "shop")?.resources))")
        check("the page says so", await eventually(5) { page.writeStatus?.text.hasPrefix("Resized pod shop/sized-0 in place in kind-fake") == true })

        // A server that doesn't serve pods/resize: greyed with why, refused, nothing sent.
        fake.servesResize = false
        model.rediscover()
        check("discovery read again says no resize", await eventually(10) { model.discovery?.kind("po")?.subresources.contains("resize") == false })
        guard await showKubernetesKind(model, page, "po", row: pod) else { return }
        page.selection = ["shop/sized-0"]
        page.writeStatus = nil
        let before = fake.writes.count
        check("Resize in Place… is greyed with why", verb(resizeTitle, "shop/sized-0")?.unavailable == KubeResize.unsupported, verb(resizeTitle, "shop/sized-0")?.unavailable ?? "none")
        verb(resizeTitle, "shop/sized-0")?.perform()
        check("and refused at once", page.writeStatus == .failed(KubeResize.unsupported) && page.resizeDraft == nil && window.attachedSheet == nil)
        check("the refusal drawn", await shownText(15) { $0.contains("doesn't serve in-place resize") } != nil)
        await pause(0.3)
        check("nothing sent", !fake.writes.dropFirst(before).contains { !$0.isAccessReview }, "\(fake.writes.dropFirst(before))")
        fake.servesResize = true
        model.rediscover()
        _ = await eventually(10) { model.discovery?.kind("po")?.subresources.contains("resize") == true }
    }
}
