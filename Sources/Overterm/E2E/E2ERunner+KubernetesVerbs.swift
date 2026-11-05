import AppKit
import Foundation

/// Stage 2a's other verbs against the fake API server, never a real
/// cluster: on `kind-fake` (local by name, so writable) a CronJob is
/// triggered by `s` as the window takes it — a Job appears, its own and
/// listed —, a node is cordoned by `u` — its row says SchedulingDisabled —,
/// and a namespace is made from `N`'s sheet, typed into its field, then
/// deleted by ⌫ with what it holds said and its name typed. Every
/// confirmation is the window's sheet, ended by the runner. On `fake-dev`
/// (read-only) each key is refused with why and nothing reaches the fake.
extension E2ERunner {
    func kubernetesVerbs(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        let wasShowing = app.store.showingOverlay == .kubernetes
        if !wasShowing { app.toggleKubernetesPage(nil) }
        defer { if !wasShowing, app.store.showingOverlay == .kubernetes { app.toggleKubernetesPage(nil) } }
        fake.add(
            "cronjobs.batch", "nightly", namespace: "shop", values: ["Schedule": "0 3 * * *", "Timezone": "<none>", "Active": 0, "Last Schedule": "<none>"],
            fields: [
                "spec": [
                    "schedule": "0 3 * * *",
                    "jobTemplate": [
                        "metadata": ["labels": ["app": "nightly"]],
                        "spec": ["template": ["spec": ["restartPolicy": "OnFailure", "containers": [["name": "job", "image": "busybox:1.36"]]]]],
                    ],
                ]
            ])
        page.jobSuffix = { "e2e01" }
        model.select("kind-fake")
        model.setScope(.namespace("shop"))

        // A CronJob triggered: a Job made from its template.
        guard await showKubernetesKind(model, page, "cj", row: KubeRowID(namespace: "shop", name: "nightly")) else { return }
        page.selection = ["shop/nightly"]
        page.giveListTheKeyboard()
        check(
            "Trigger Now… is offered once reviewed",
            await eventually(10) { page.verbs(for: ["shop/nightly"]).first { $0.title == "Trigger Now…" }.map { $0.unavailable == nil } == true },
            page.verbs(for: ["shop/nightly"]).first { $0.title == "Trigger Now…" }?.unavailable ?? "none")
        check("s is the list's", await pressKubernetesKey("s", keyCode: 1))
        check("the trigger is asked in the window", await eventually(10) { self.window.attachedSheet != nil })
        let trigger = sheetTexts().joined(separator: "\n")
        check("naming the CronJob", trigger.contains("Trigger cronjob shop/nightly now?"), trigger)
        check("the context and namespace", trigger.contains("kind-fake · namespace shop"), trigger)
        check(
            "and the kubectl it equals", trigger.contains("kubectl create job nightly-manual-e2e01 --from=cronjob/nightly --context kind-fake -n shop"),
            trigger)
        check("nothing is made while it asks", !fake.writes.contains { $0.path.hasSuffix("/jobs") })
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check("confirmed, a Job appears", await eventually(10) { fake.names("jobs.batch") == ["nightly-manual-e2e01"] }, "\(fake.names("jobs.batch"))")
        check(
            "as one POST", fake.writes.filter { $0.path.hasSuffix("/jobs") }.map(\.description) == ["POST /apis/batch/v1/namespaces/shop/jobs"],
            "\(fake.writes.suffix(3))")
        check(
            "the outcome is said",
            await eventually(10) { page.writeStatus == .done("Triggered cronjob shop/nightly in kind-fake: job shop/nightly-manual-e2e01 made.") },
            "\(String(describing: page.writeStatus))")
        check("the outcome drawn", await shownText(15) { $0.contains("Triggered cronjob shop/nightly") } != nil)
        if await showKubernetesKind(model, page, "jobs", row: KubeRowID(namespace: "shop", name: "nightly-manual-e2e01")) {
            check("the Job is listed", true)
            check("and drawn", await shownText(15) { $0.contains("nightly-manual-e2e01") } != nil)
        }

        // A node cordoned: its row says SchedulingDisabled.
        let node = KubeRowID(namespace: nil, name: "fake-node-1")
        guard await showKubernetesKind(model, page, "no", row: node) else { return }
        page.selection = ["fake-node-1"]
        page.giveListTheKeyboard()
        check(
            "Cordon… is offered once reviewed",
            await eventually(10) { page.verbs(for: ["fake-node-1"]).first { $0.title == "Cordon…" }.map { $0.unavailable == nil } == true },
            page.verbs(for: ["fake-node-1"]).first { $0.title == "Cordon…" }?.unavailable ?? "none")
        check("u is the list's", await pressKubernetesKey("u", keyCode: 32))
        check("the cordon is asked in the window", await eventually(10) { self.window.attachedSheet != nil })
        let cordon = sheetTexts().joined(separator: "\n")
        check("cluster-wide, naming the node", cordon.contains("Cordon node fake-node-1?") && cordon.contains("kind-fake · cluster-wide"), cordon)
        check("and its kubectl", cordon.contains("kubectl cordon fake-node-1 --context kind-fake"), cordon)
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check(
            "confirmed, its row says SchedulingDisabled by the watch",
            await eventually(10) { model.rows[node]?.cell("Status", in: model.rows.columns)?.text == "Ready,SchedulingDisabled" },
            model.rows[node]?.cells.map(\.text).joined(separator: " ") ?? "no row")
        check("drawn so", await shownText(15) { $0.contains("SchedulingDisabled") } != nil)
        check("as one PATCH", fake.writes.filter { $0.path == "/api/v1/nodes/fake-node-1" }.count == 1, "\(fake.writes.suffix(3))")
        check("Cordon… now greyed with why", page.verbs(for: ["fake-node-1"]).first { $0.title == "Cordon…" }?.unavailable == "node fake-node-1 is cordoned already.")

        // A namespace made from N's sheet, then deleted with its name typed.
        let name = "scratch-e2e"
        page.giveListTheKeyboard()
        check("the list has the keyboard for N", await eventually(3) { self.app.kubernetesListHasKeyboard() })
        check("N is the list's", await pressKubernetesKey("N", keyCode: 45, shift: true))
        check("N opens the namespace sheet", page.namespaceDraft?.context == "kind-fake")
        check("the sheet drawn", await shownText(15) { $0.contains("New Namespace") } != nil)
        check(
            "its name field has the keyboard",
            await eventually(5) {
                guard let editor = self.window.firstResponder as? NSTextView, let field = editor.delegate as? NSTextField,
                    let view = self.app.kubernetesView
                else { return false }
                return field.isDescendant(of: view)
                    && (field.placeholderString ?? field.placeholderAttributedString?.string) == KubeNamespaceSheetView.placeholder
                    && !self.app.kubernetesListHasKeyboard()
            }, "\(String(describing: window.firstResponder))")
        if let editor = window.firstResponder as? NSTextView {
            editor.insertText("Scratch", replacementRange: editor.selectedRange())
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            check("a name that isn't a DNS label is said", page.namespaceDraft?.problem == "Lowercase only: scratch?", page.namespaceDraft?.problem ?? "closed")
            check("and drawn", await shownText(15) { $0.contains("Lowercase only") } != nil)
            check("nothing asked", window.attachedSheet == nil)
            editor.selectAll(nil)
            editor.insertText(name, replacementRange: editor.selectedRange())
            check("what is typed is the name", page.namespaceDraft?.name == name, page.namespaceDraft?.name ?? "closed")
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        }
        check("the create is asked in the window", await eventually(10) { self.window.attachedSheet != nil })
        let create = sheetTexts().joined(separator: "\n")
        check("naming it", create.contains("Create namespace \(name)?") && create.contains("kubectl create namespace \(name) --context kind-fake"), create)
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check("confirmed, it is made", await eventually(10) { fake.names("namespaces").contains(name) }, "\(fake.names("namespaces"))")
        fake.addPod("tmp-0", namespace: name)
        guard await showKubernetesKind(model, page, "ns", row: KubeRowID(namespace: nil, name: name)) else { return }
        page.selection = [name]
        page.giveListTheKeyboard()
        check(
            "Delete… is offered once reviewed",
            await eventually(10) { page.verbs(for: [name]).first { $0.title == "Delete…" }.map { $0.unavailable == nil } == true })
        check("the list has the keyboard for ⌫", await eventually(3) { self.app.kubernetesListHasKeyboard() })
        check("⌫ is the list's", await pressKubernetesKey("\u{7F}", keyCode: 51))
        check("the delete is asked in the window", await eventually(10) { self.window.attachedSheet != nil && self.typedNameField() != nil })
        let delete = sheetTexts().joined(separator: "\n")
        check("naming it and what goes with it", delete.contains("Delete namespace \(name) and everything in it?"), delete)
        check("what it holds, counted", delete.contains("Among the kinds Overterm counts, it holds 1 pod."), delete)
        check("asking for its name on a local context too", delete.contains("Type \(name) to confirm."), delete)
        typedNameField()?.stringValue = "scratch"
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check("a wrong name sends nothing", await eventually(5) { page.writeStatus == .failed("The name typed wasn't \(name): nothing was changed.") })
        check("it is still there", fake.names("namespaces").contains(name) && !fake.writes.contains { $0.method == "DELETE" && $0.path.hasSuffix("/\(name)") })
        check("⌫ again", await pressKubernetesKey("\u{7F}", keyCode: 51))
        check("asked again", await eventually(10) { self.window.attachedSheet != nil && self.typedNameField() != nil })
        typedNameField()?.stringValue = name
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check(
            "its name typed, it goes with what it held",
            await eventually(10) { !fake.names("namespaces").contains(name) && fake.pod("tmp-0", namespace: name) == nil })
        check("by the watch", await eventually(10) { model.rows[KubeRowID(namespace: nil, name: name)] == nil })

        // fake-dev: read-only, each refused with why; nothing reaches the fake.
        let before = fake.writes.count
        model.select("fake-dev")
        model.setScope(.namespace("shop"))
        let readOnly = "This context is read-only: Overterm changes nothing here (its writable setting)."
        guard await showKubernetesKind(model, page, "cj", row: KubeRowID(namespace: "shop", name: "nightly")) else { return }
        page.selection = ["shop/nightly"]
        let cronVerbs = page.verbs(for: ["shop/nightly"]).filter { [KubeWriteVerb.trigger, .suspend, .unsuspend].map(\.title).contains($0.title) }
        check("fake-dev's trigger and suspend greyed with why", cronVerbs.count == 3 && cronVerbs.allSatisfy { $0.unavailable == readOnly })
        page.giveListTheKeyboard()
        check("s refused at once", await pressKubernetesKey("s", keyCode: 1) && page.writeStatus == .failed(readOnly) && window.attachedSheet == nil)
        check("the refusal drawn", await shownText(15) { $0.contains("This context is read-only") } != nil)
        check("p too", page.press("p") && page.writeStatus == .failed(readOnly))
        if await showKubernetesKind(model, page, "no", row: node) {
            page.selection = ["fake-node-1"]
            check("u too", page.press("u") && page.writeStatus == .failed(readOnly))
        }
        page.writeStatus = nil
        check("and N: no sheet", page.press("N") && page.namespaceDraft == nil && page.writeStatus == .failed(readOnly))
        await pause(0.5)
        check("nothing reached the fake from fake-dev", fake.writes.count == before, "\(fake.writes.suffix(3))")
        // A namespace's delete: greyed with why, ⌫ refused at once — no
        // review, not one of the counting reads.
        if await showKubernetesKind(model, page, "ns", row: KubeRowID(namespace: nil, name: "shop")) {
            page.selection = ["shop"]
            page.giveListTheKeyboard()
            check(
                "fake-dev's namespace delete greyed with why", page.verbs(for: ["shop"]).first { $0.title == KubeWriteVerb.delete.title }?.unavailable == readOnly,
                page.verbs(for: ["shop"]).first { $0.title == KubeWriteVerb.delete.title }?.unavailable ?? "none")
            fake.forgetRequests()
            page.writeStatus = nil
            check("⌫ refused at once", await pressKubernetesKey("\u{7F}", keyCode: 51) && page.writeStatus == .failed(readOnly) && window.attachedSheet == nil)
            await pause(0.3)
            check(
                "no write, no review, nothing counted",
                fake.writes.isEmpty && !fake.requests.contains { $0.isAccessReview || $0.path.contains("/namespaces/shop/") },
                "\(fake.requests.map(\.description).suffix(5))")
        }
        page.showKind(model.discovery?.kind("po") ?? .pods)
    }

    /// The kind by kubectl's name, until `row` is listed.
    private func showKubernetesKind(_ model: KubernetesModel, _ page: KubernetesPageModel, _ name: String, row: KubeRowID) async -> Bool {
        guard let kind = model.discovery?.kind(name) else {
            check("\(model.selectedName ?? "?") serves \(name)", false)
            return false
        }
        page.showKind(kind)
        let listed = await eventually(15) { model.kind.fullName == kind.fullName && model.rows[row] != nil && model.listState == .live }
        check("\(model.selectedName ?? "?")'s \(name) lists \(row)", listed, "\(model.rows.sorted.map(\.id.description)) \(model.listState)")
        return listed
    }

    /// A key down as the window takes it, once the list has the keyboard.
    private func pressKubernetesKey(_ characters: String, keyCode: UInt16, shift: Bool = false) async -> Bool {
        _ = await eventually(3) { self.app.kubernetesListHasKeyboard() }
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: shift ? characters.lowercased() : characters, isARepeat: false, keyCode: keyCode)
        else { return false }
        return app.handlePageKey(event)
    }
}
