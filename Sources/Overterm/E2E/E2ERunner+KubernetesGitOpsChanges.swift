import AppKit
import Foundation

/// G0d (docs/design/kubernetes/gitops.md, 1.1 rows 9–10) against the fake
/// API server, never a real cluster: a checkout's manifest that moves a
/// Kustomization's path, applied on kind-fake (local), is asked naming the
/// change and with its name typed — a wrong one applies nothing; resuming
/// it on fake-prod with the session's writes on names what its source
/// holds against what is applied, and asks its name for its prune — a
/// wrong one sends nothing. Every sheet is ended by the runner.
extension E2ERunner {
    func kubernetesGitOpsChanges(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        let ks = "kustomizations.kustomize.toolkit.fluxcd.io"
        let row = KubeRowID(namespace: "shop", name: "acme-cron")
        let spec: [String: Any] = ["path": "./apps/cron", "prune": true, "suspend": true, "sourceRef": ["kind": "GitRepository", "name": "acme-shop"]]
        fake.add(ks, row.name, namespace: "shop", fields: ["spec": spec, "status": ["lastAppliedRevision": "main@sha1:a77b0d1e2f3a4b5c6d7e"]])
        defer { fake.delete(ks, row.name, namespace: "shop") }
        fake.setFields(
            "gitrepositories.source.toolkit.fluxcd.io", "acme-shop", namespace: "shop",
            [
                "spec": ["url": "https://git.acme.example/shop.git", "interval": "1m"],
                "status": ["artifact": ["revision": "main@sha1:c03f9aa0123456789abcdef"]],
            ])
        func live() -> [String: Any] { fake.object(ks, row.name, namespace: "shop")?["spec"] as? [String: Any] ?? [:] }
        func confirmSheet() { if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) } }
        guard let editor = app.editor else { return check("the window has an editor", false) }

        // kind-fake: a manifest moving its path — named, its name typed.
        let folder = scratch.appendingPathComponent("gitops-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("acme-cron.yaml")
        try? """
        apiVersion: kustomize.toolkit.fluxcd.io/v1
        kind: Kustomization
        metadata:
          name: acme-cron
          namespace: shop
        spec:
          path: ./apps/cron-v2
          prune: true
          suspend: true
          sourceRef:
            kind: GitRepository
            name: acme-shop

        """.write(to: file, atomically: true, encoding: .utf8)
        model.select("kind-fake")
        model.setScope(.namespace("shop"))
        if app.store.showingOverlay == .kubernetes { app.toggleKubernetesPage(nil) }
        app.openInEditor(file)
        check(
            "a Kustomization's manifest gets the bar",
            await eventually(10) { editor.active?.url?.standardizedFileURL == file.standardizedFileURL && editor.active?.kubeManifest != nil })
        if let session = editor.active?.kubeManifest {
            session.contextName = "kind-fake"
            fake.forgetRequests()
            session.apply()
            check("the apply is asked with its name", await eventually(15) { self.window.attachedSheet != nil && self.typedNameField() != nil }, "\(session.state)")
            let asked = sheetTexts().joined(separator: "\n")
            check("on kind-fake", asked.contains("Apply kustomization shop/acme-cron to kind-fake?") && asked.contains("kind-fake · namespace shop"), asked)
            check(
                "the change named",
                asked.contains("kustomization shop/acme-cron's source, destination, prune or suspension changes: .spec.path: ./apps/cron → ./apps/cron-v2."), asked)
            check("its name asked on a local context", asked.contains("Type acme-cron to confirm."), asked)
            typedNameField()?.stringValue = "acme-crn"
            confirmSheet()
            check(
                "a wrong name applies nothing",
                await eventually(10) { session.state == .failed("The name typed wasn't acme-cron: nothing was applied.") }
                    && !fake.writes.contains { $0.contentType == KubeApply.contentType && $0.query["dryRun"] == nil }, "\(session.state)")
            check("its path as it was", live()["path"] as? String == "./apps/cron")
            check("said in the bar", await shownText(15) { $0.contains("The name typed wasn't acme-cron") } != nil)
        }
        if let index = editor.buffers.firstIndex(where: { $0.url?.standardizedFileURL == file.standardizedFileURL }) { editor.removeBuffer(at: index) }
        if app.store.showingOverlay != .kubernetes { app.toggleKubernetesPage(nil) }

        // fake-prod, writes on for the session: Resume says what it applies, its name typed for its prune.
        model.select("fake-prod")
        model.setScope(.namespace("shop"))
        page.allowProductionWrites()
        check("fake-prod's writes are asked first", await eventually(5) { self.window.attachedSheet != nil })
        confirmSheet()
        check("fake-prod's writes are on", await eventually(10) { model.selected?.isWritable == true && page.productionWritesOn })
        defer { page.endProductionWrites() }
        check(
            "fake-prod serves Flux's kinds", await eventually(15) { ["ks", "gitrepositories"].allSatisfy { model.discovery?.kind($0) != nil } },
            "\(String(describing: model.discoveryProblem))")
        guard await showKubernetesKind(model, page, "ks", row: row) else { return }
        page.selection = [row.description]
        page.writeStatus = nil
        let resumeTitle = KubeWriteVerb.fluxSuspend.title
        check(
            "its pause verb is offered once reviewed",
            await eventually(10) { page.verbs(for: [row.description]).first { $0.title == resumeTitle }.map { $0.unavailable == nil } == true })
        page.giveListTheKeyboard()
        fake.forgetRequests()
        check("p is the list's", await pressKubernetesKey("p", keyCode: 35))
        check("the resume is asked with its name", await eventually(15) { self.window.attachedSheet != nil && self.typedNameField() != nil }, "\(String(describing: page.writeStatus))")
        let resume = sheetTexts().joined(separator: "\n")
        check("as a resume, on PRODUCTION", resume.contains("Resume Flux's reconciliation of kustomization shop/acme-cron?") && resume.contains("PRODUCTION · fake-prod · namespace shop"), resume)
        check(
            "what it applies against what is applied",
            resume.contains("Resuming applies what gitrepository shop/acme-shop holds now: applies main@c03f9aa; a77b0d1 is applied."), resume)
        check("and its prune", resume.contains("spec.prune is on: whatever left the source since is deleted from the cluster."), resume)
        check("its source read, after the review", fake.requests.contains { $0.description == "GET /apis/source.toolkit.fluxcd.io/v1/namespaces/shop/gitrepositories/acme-shop" })
        typedNameField()?.stringValue = "acme-crn"
        confirmSheet()
        check(
            "a wrong name sends nothing",
            await eventually(5) { page.writeStatus == .failed("The name typed wasn't acme-cron: nothing was changed.") }
                && !fake.writes.contains { $0.method == "PATCH" && $0.description.contains("acme-cron") }, "\(String(describing: page.writeStatus))")
        check("still suspended", KubeWriteToggle.suspended.state(of: ["spec": live()]))
        check("said", await shownText(15) { $0.contains("The name typed wasn't acme-cron") } != nil)
        page.writeStatus = nil
        page.endProductionWrites()
        check("fake-prod's writes off again", await eventually(5) { model.selected?.isWritable == false })
        model.select("kind-fake")
    }
}
