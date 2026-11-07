import AppKit
import Foundation

/// Stage 2a's first writes against the fake API server, never a real
/// cluster: the scenario's kubeconfig gains `kind-fake` (local by name, so
/// writable — on 127.0.0.1 like the others, which is not why). A delete and
/// a scale there are reviewed, confirmed in the window's sheet (ended by
/// the runner, never by a click), land on the fake and come back by the
/// watch; on `fake-prod` the verbs are greyed until its switch for the
/// session, which is asked first, and a delete then asks for the typed
/// name — a wrong one sends nothing; on `fake-dev` (read-only) they are
/// greyed with why and nothing reaches the fake. With kubectl installed the
/// real proxies are in between: fake-prod's refuses a POST again once its
/// writes are off.
extension E2ERunner {
    func kubernetesWrites(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, kubeconfig: URL, port: Int, kubectl: String?) async {
        // kind-fake joins the scenario's kubeconfig.
        do {
            try Self.fakeKubeconfig(port: port, kind: true).write(to: kubeconfig, atomically: true, encoding: .utf8)
        } catch {
            return check("the kubeconfig gains kind-fake", false, "\(error)")
        }
        let wasShowing = app.store.showingOverlay == .kubernetes
        if !wasShowing { app.toggleKubernetesPage(nil) }
        defer { if !wasShowing, app.store.showingOverlay == .kubernetes { app.toggleKubernetesPage(nil) } }
        model.reloadContexts()
        check(
            "kind-fake is read", await eventually(10) { model.contexts.contexts.map(\.name) == ["fake-dev", "fake-prod", "kind-fake"] },
            "\(model.contexts.contexts.map(\.name))")
        let local = model.contexts.context(named: "kind-fake")
        check("kind-fake is local by name, so writable", local?.contextClass == .local && local?.isWritable == true)
        check("fake-prod and fake-dev are not", model.contexts.contexts.filter(\.isWritable).map(\.name) == ["kind-fake"])
        fake.addPod("doomed-0", namespace: "shop")
        fake.add(
            "deployments.apps", "batch", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1],
            fields: ["spec": ["replicas": 1, "selector": ["matchLabels": ["app": "batch"]]], "status": ["replicas": 1]])

        // kind-fake: a delete by ⌫ as the window takes it.
        model.select("kind-fake")
        model.setScope(.namespace("shop"))
        page.showKind(model.discovery?.kind("po") ?? .pods)
        check(
            "kind-fake's pods are listed", await eventually(15) { model.selectedName == "kind-fake" && model.rows[KubeRowID(namespace: "shop", name: "doomed-0")] != nil },
            "\(model.rows.sorted.map(\.id.description)) \(model.listState)")
        page.selection = ["shop/doomed-0"]
        page.giveListTheKeyboard()
        check(
            "Delete… is offered once the access review says yes",
            await eventually(10) { page.verbs(for: ["shop/doomed-0"]).first { $0.title == "Delete…" }.map { $0.unavailable == nil } == true },
            page.verbs(for: ["shop/doomed-0"]).first { $0.title == "Delete…" }?.unavailable ?? "none")
        check("asked of the server as a SelfSubjectAccessReview", fake.requests.contains { $0.isAccessReview })
        check("the list has the keyboard", await eventually(3) { self.app.kubernetesListHasKeyboard() })
        if let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{7F}",
            charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51)
        {
            check("⌫ is the list's", app.handlePageKey(event))
        }
        check("the delete is asked in the window", await eventually(10) { self.window.attachedSheet != nil })
        let asked = sheetTexts().joined(separator: "\n")
        check("naming the verb and the object", asked.contains("Delete pod shop/doomed-0?"), asked)
        check("the context and namespace", asked.contains("kind-fake · namespace shop"), asked)
        check("and the kubectl it equals", asked.contains("kubectl delete po doomed-0 --context kind-fake -n shop"), asked)
        check("nothing is written while it asks", !fake.writes.contains { $0.method == "DELETE" }, "\(fake.writes.map(\.description))")
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check("confirmed, it lands on the fake", await eventually(10) { fake.pod("doomed-0", namespace: "shop") == nil })
        check(
            "as one DELETE", fake.writes.filter { $0.method == "DELETE" }.map(\.path) == ["/api/v1/namespaces/shop/pods/doomed-0"],
            "\(fake.writes.map(\.description))")
        check("the list follows by its watch", await eventually(10) { model.rows[KubeRowID(namespace: "shop", name: "doomed-0")] == nil })
        check("the outcome is said", await eventually(10) { page.writeStatus == .done("Deleted pod shop/doomed-0 in kind-fake.") }, "\(String(describing: page.writeStatus))")
        check("the outcome drawn", await shownText(15) { $0.contains("Deleted pod shop/doomed-0") } != nil)

        // A scale, by = and its sheet.
        guard let deployments = model.discovery?.kind("deploy") else { return check("kind-fake serves deployments", false) }
        page.showKind(deployments)
        check("its deployments are listed", await eventually(15) { model.rows[KubeRowID(namespace: "shop", name: "batch")] != nil })
        page.selection = ["shop/batch"]
        page.giveListTheKeyboard()
        check("the list has the keyboard for =", await eventually(3) { self.app.kubernetesListHasKeyboard() })
        if let equals = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "=",
            charactersIgnoringModifiers: "=", isARepeat: false, keyCode: 24)
        {
            check("= is the list's", app.handlePageKey(equals))
        }
        check("= opens the scale sheet", page.scaleDraft?.ref.name == "batch")
        check("with the replicas now", await eventually(10) { page.scaleDraft?.current == 1 }, "\(String(describing: page.scaleDraft))")
        check("the scale sheet drawn", await shownText(15) { $0.contains("Scale deployment shop/batch") } != nil)
        // Typed into its field as the keyboard has it, Return to go on.
        check(
            "its replicas field has the keyboard",
            await eventually(5) {
                guard let editor = self.window.firstResponder as? NSTextView, let field = editor.delegate as? NSTextField,
                    let view = self.app.kubernetesView
                else { return false }
                return field.isDescendant(of: view) && (field.placeholderString ?? field.placeholderAttributedString?.string) == KubeScaleSheetView.placeholder
                    && !self.app.kubernetesListHasKeyboard()
            }, "\(String(describing: window.firstResponder))")
        if let editor = window.firstResponder as? NSTextView {
            editor.selectAll(nil)
            editor.insertText("3", replacementRange: editor.selectedRange())
            check("what is typed is the count", page.scaleDraft?.replicas == "3", page.scaleDraft?.replicas ?? "closed")
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        }
        check("the scale is asked in the window", await eventually(10) { self.window.attachedSheet != nil })
        let scaling = sheetTexts().joined(separator: "\n")
        check("from 1 to 3", scaling.contains("Scale deployment shop/batch from 1 to 3 replicas?"), scaling)
        check("and its kubectl", scaling.contains("kubectl scale deploy/batch --replicas=3 --context kind-fake -n shop"), scaling)
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check(
            "confirmed, the scale subresource is patched",
            await eventually(10) {
                fake.writes.contains { $0.method == "PATCH" && $0.path == "/apis/apps/v1/namespaces/shop/deployments/batch/scale" }
            }, "\(fake.writes.map(\.description))")
        check(
            "and its row says 3/3 by the watch",
            await eventually(10) { model.rows[KubeRowID(namespace: "shop", name: "batch")]?.cells.contains { $0.text == "3/3" } == true })

        // fake-prod: greyed until the switch, then the typed name.
        page.showKind(model.discovery?.kind("po") ?? .pods)
        model.select("fake-prod")
        model.setScope(.namespace("payments"))
        check(
            "fake-prod's pods", await eventually(15) { model.selectedName == "fake-prod" && model.rows[KubeRowID(namespace: "payments", name: "api-0")] != nil },
            "\(model.rows.sorted.map(\.id.description))")
        page.selection = ["payments/api-0"]
        let refusal = "Production is read-only: turn on writes for this session on its card first."
        check("its Delete… is greyed with why", page.verbs(for: ["payments/api-0"]).first { $0.title == "Delete…" }?.unavailable == refusal)
        let prodWrites = fake.writes.count
        check("⌫ does nothing but say so", page.press("\u{7F}") && page.writeStatus == .failed(refusal) && window.attachedSheet == nil)
        check("the refusal drawn", await shownText(15) { $0.contains("turn on writes for this session") } != nil)
        check("nothing reached the fake", fake.writes.count == prodWrites)
        page.allowProductionWrites()
        check("turning writes on is asked first", await eventually(5) { self.window.attachedSheet != nil })
        check("naming the context", sheetTexts().contains { $0.contains("PRODUCTION · fake-prod") }, "\(sheetTexts())")
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check("then writes are on for the session", await eventually(5) { model.selected?.isWritable == true && page.productionWritesOn })
        check("the band says so", page.band?.contains("writes on until quit") == true, page.band ?? "")
        check("the band drawn so", await shownText(15) { $0.contains("writes on until quit") } != nil)
        check(
            "the pods listed again", await eventually(15) { model.rows[KubeRowID(namespace: "payments", name: "api-0")] != nil && model.listState == .live })
        page.selection = ["payments/api-0"]
        check(
            "Delete… offered once reviewed",
            await eventually(10) { page.verbs(for: ["payments/api-0"]).first { $0.title == "Delete…" }?.unavailable == nil },
            page.verbs(for: ["payments/api-0"]).first { $0.title == "Delete…" }?.unavailable ?? "")
        check("⌫ asks", page.press("\u{7F}"))
        check("in the window", await eventually(10) { self.window.attachedSheet != nil })
        check("PRODUCTION, the context and namespace", sheetTexts().contains { $0.contains("PRODUCTION · fake-prod · namespace payments") }, "\(sheetTexts())")
        check("asking for the name", sheetTexts().contains { $0.contains("Type api-0 to confirm.") } && typedNameField() != nil)
        check(
            "the context and namespace in production's red",
            Self.find(NSTextField.self, in: window.attachedSheet?.contentView) { $0.accessibilityIdentifier() == "write.scope" }?.textColor
                == WriteConfirmation.productionRed)
        typedNameField()?.stringValue = "api-1"
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check("a wrong name sends nothing", await eventually(5) { page.writeStatus == .failed("The name typed wasn't api-0: nothing was changed.") })
        check("the pod is still there", fake.pod("api-0", namespace: "payments") != nil && !fake.writes.contains { $0.method == "DELETE" && $0.path.hasSuffix("/api-0") })
        check("⌫ again", page.press("\u{7F}"))
        check("asked again", await eventually(10) { self.window.attachedSheet != nil && self.typedNameField() != nil })
        typedNameField()?.stringValue = "api-0"
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check("the name typed, it lands", await eventually(10) { fake.pod("api-0", namespace: "payments") == nil }, "\(String(describing: page.writeStatus))")
        check("by the watch", await eventually(10) { model.rows[KubeRowID(namespace: "payments", name: "api-0")] == nil })
        page.endProductionWrites()
        check("writes off again: read-only", await eventually(5) { model.selected?.isWritable == false && page.band?.contains("read-only") == true })
        if kubectl != nil, let prod = model.selected {
            let review = KubeWrites.review(KubeAccess(verb: "delete", resource: "pods"), namespace: "payments")
            let refused = try? await model.proxies.send(
                prod, .POST, review.path, body: review.body, headers: [("Content-Type", review.contentType)])
            check("and fake-prod's proxy refuses a POST again", refused?.status == 403, "\(refused.map { "\($0.status)" } ?? "no answer")")
        } else {
            note("no kubectl: the socket's own refusal of fake-prod's writes is not checked here, only Overterm's")
        }

        // fake-dev: read-only, greyed with why; nothing reaches the fake.
        let devWrites = fake.writes.count
        model.select("fake-dev")
        model.setScope(.namespace("shop"))
        check("fake-dev's pods", await eventually(15) { model.selectedName == "fake-dev" && model.rows.count > 0 })
        guard let row = model.rows.sorted.first else { return }
        page.selection = [row.id.description]
        let readOnly = "This context is read-only: Overterm changes nothing here (its writable setting)."
        let writes = page.verbs(for: [row.id.description]).filter { KubeWriteVerb.allCases.map(\.title).contains($0.title) }
        check("every write greyed with why", !writes.isEmpty && writes.allSatisfy { $0.unavailable == readOnly }, "\(writes.map(\.unavailable))")
        check("⌫ refused at once", page.press("\u{7F}") && page.writeStatus == .failed(readOnly) && window.attachedSheet == nil)
        check("r too", page.press("r") && page.writeStatus == .failed(readOnly))
        // Past Overterm's own refusal, straight at fake-dev's socket: the
        // real proxy's method filter refuses it, and the fake hears nothing.
        if kubectl != nil, let dev = model.selected {
            let refused = try? await model.proxies.send(dev, .DELETE, "/api/v1/namespaces/\(row.id.namespace ?? "shop")/pods/\(row.id.name)")
            check("fake-dev's proxy refuses a DELETE sent past the page", refused?.status == 403, "\(refused.map { "\($0.status)" } ?? "no answer")")
        } else {
            note("no kubectl: fake-dev's socket isn't sent a write here, only Overterm's refusal is checked")
        }
        await pause(0.5)
        check("nothing reached the fake from fake-dev, not even a review", fake.writes.count == devWrites, "\(fake.writes.suffix(3))")
        check(
            "and no write went to a subresource but a scale and an eviction's",
            fake.writes.allSatisfy { !$0.isSubresource || $0.path.hasSuffix("/scale") || $0.path.hasSuffix("/eviction") })
    }

    /// The typed-name field of the confirmation showing.
    func typedNameField() -> NSTextField? { confirmationField(TerminalWindowController.kubernetesTypedNameField) }

    /// The image field of the confirmation showing (a debug container's, a node shell's).
    func imageField() -> NSTextField? { confirmationField(WriteConfirmation.imageField) }

    func confirmationField(_ identifier: String) -> NSTextField? {
        guard let root = window.attachedSheet?.contentView else { return nil }
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.identifier?.rawValue == identifier { return field }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return find(root)
    }
}
