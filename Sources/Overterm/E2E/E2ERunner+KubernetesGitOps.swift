import AppKit
import Foundation

/// Stage 4's Flux and Argo CD verbs (docs/design/kubernetes/analysis.md,
/// 2.23, decision 24) against the fake API server, never a real cluster,
/// once the tree check has Argo CD's and Flux's CRDs served. On `fake-dev`
/// (read-only) a Kustomization's verbs are greyed with why, `p`, `r` and an
/// Application's `s` refused at once — nothing sent, not even a review. On
/// `kind-fake` (local, so writable), by the window's key path: `p`
/// suspends the Kustomization, `p` again resumes it (the object read
/// decides), `r` reconciles it — each reviewed, asked in the window's sheet
/// naming the context, namespace and the flux command it equals, then one
/// merge patch the fake applies; its tree's GitRepository reconciled from
/// the node's own verbs; an Application refreshed by `r`, then synced by
/// `s` with argocd in a tab — recorded, not typed, the tab pinned to the
/// context. Nothing is written but those patches.
extension E2ERunner {
    func kubernetesGitOpsVerbs(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
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
        fake.addCRD(group: "source.toolkit.fluxcd.io", version: "v1", plural: "gitrepositories", kind: "GitRepository", shortNames: ["gitrepo"])
        fake.add(
            "gitrepositories.source.toolkit.fluxcd.io", "acme-shop", namespace: "shop",
            fields: ["spec": ["url": "https://git.acme.example/shop.git", "interval": "1m"]])
        // Argo CD in argocd, its Application in shop: the sync's tab is pinned to argocd.
        fake.add("configmaps", KubeGitOps.argoConfigMap, namespace: "argocd", data: ["url": "https://argocd.acme.example"])
        defer { fake.delete("configmaps", KubeGitOps.argoConfigMap, namespace: "argocd") }
        let ks = "kustomizations.kustomize.toolkit.fluxcd.io"
        let row = KubeRowID(namespace: "shop", name: "tree-shop")
        func verb(_ title: String) -> ResourceVerb? { page.verbs(for: [row.description]).first { $0.title == title } }
        func spec(_ resource: String, _ name: String = "tree-shop") -> [String: Any] { fake.object(resource, name, namespace: "shop") ?? [:] }
        func annotations(_ resource: String, _ name: String = "tree-shop") -> [String: String] {
            ((spec(resource, name)["metadata"] as? [String: Any])?["annotations"] as? [String: String]) ?? [:]
        }
        func suspended() -> Bool { KubeWriteToggle.suspended.state(of: spec(ks)) }
        func confirmSheet() { if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) } }
        let gitOpsTitles = [KubeWriteVerb.reconcile, .fluxSuspend, .fluxResume].map(\.title) + [KubeTabWrite.title(.fluxReconcile)]

        // fake-dev: read-only — greyed with why, refused, nothing sent.
        page.closeDetail()
        fake.forgetRequests()
        model.select("fake-dev")
        model.setScope(.namespace("shop"))
        let readOnly = "This context is read-only: Overterm changes nothing here (its writable setting)."
        guard await showKubernetesKind(model, page, "ks", row: row) else { return }
        page.selection = [row.description]
        let devVerbs = page.verbs(for: [row.description]).filter { gitOpsTitles.contains($0.title) }
        check(
            "fake-dev's Kustomization verbs greyed with why", devVerbs.count == 4 && devVerbs.allSatisfy { $0.unavailable == readOnly },
            "\(devVerbs.map { "\($0.title) \($0.unavailable ?? "none")" })")
        page.giveListTheKeyboard()
        page.writeStatus = nil
        check("p refused at once", await pressKubernetesKey("p", keyCode: 35) && page.writeStatus == .failed(readOnly) && window.attachedSheet == nil)
        page.writeStatus = nil
        check("r too", await pressKubernetesKey("r", keyCode: 15) && page.writeStatus == .failed(readOnly) && window.attachedSheet == nil)
        check("the refusal drawn", await shownText(15) { $0.contains("This context is read-only") } != nil)
        if await showKubernetesKind(model, page, "applications", row: row) {
            page.selection = [row.description]
            page.giveListTheKeyboard()
            page.writeStatus = nil
            check(
                "an Application's s refused", await pressKubernetesKey("s", keyCode: 1) && page.writeStatus == .failed(readOnly) && window.attachedSheet == nil)
        }
        await pause(0.3)
        check("nothing sent from fake-dev — not even a review", fake.writes.isEmpty && recorded.isEmpty, "\(fake.writes)")

        // kind-fake: reviewed, asked, patched.
        page.writeStatus = nil
        model.select("kind-fake")
        model.setScope(.namespace("shop"))
        // Its discovery was read before the CRDs came: its CRD watch's first list brings them in.
        check(
            "kind-fake serves Flux's and Argo CD's kinds, by its CRD watch",
            await eventually(15) { ["ks", "applications", "gitrepositories"].allSatisfy { model.discovery?.kind($0) != nil } })
        guard await showKubernetesKind(model, page, "ks", row: row) else { return }
        page.selection = [row.description]
        let suspendTitle = KubeWriteVerb.fluxSuspend.title
        check(
            "Suspend Reconciliation… is offered once reviewed", await eventually(10) { verb(suspendTitle).map { $0.unavailable == nil } == true },
            verb(suspendTitle)?.unavailable ?? "none")
        let reviewed = fake.requests.filter(\.isAccessReview).compactMap {
            (($0.json as? [String: Any])?["spec"] as? [String: Any])?["resourceAttributes"] as? [String: String]
        }
        check(
            "as the cluster's access review: patch kustomizations",
            reviewed.contains(["verb": "patch", "resource": "kustomizations", "group": "kustomize.toolkit.fluxcd.io", "namespace": "shop"]), "\(reviewed)")
        page.giveListTheKeyboard()
        check("p is the list's", await pressKubernetesKey("p", keyCode: 35))
        check("the suspend is asked in the window", await eventually(10) { self.window.attachedSheet != nil }, "\(String(describing: page.writeStatus))")
        let suspend = sheetTexts().joined(separator: "\n")
        check("naming it", suspend.contains("Suspend Flux's reconciliation of kustomization shop/tree-shop?"), suspend)
        check("the context and namespace", suspend.contains("kind-fake · namespace shop"), suspend)
        check("and the flux command it equals", suspend.contains("flux suspend kustomization tree-shop --context kind-fake -n shop"), suspend)
        check("nothing patched while it asks", !fake.writes.contains { $0.method == "PATCH" })
        confirmSheet()
        check("confirmed, it is suspended", await eventually(10) { suspended() })
        check(
            "as one merge patch",
            fake.writes.filter { $0.method == "PATCH" }.map { "\($0.description) \($0.contentType)" } == [
                "PATCH /apis/kustomize.toolkit.fluxcd.io/v1/namespaces/shop/kustomizations/tree-shop application/merge-patch+json"
            ], "\(fake.writes.suffix(3))")
        check(
            "the outcome said", await eventually(10) { page.writeStatus == .done("Suspended Flux's reconciliation of kustomization shop/tree-shop in kind-fake.") },
            "\(String(describing: page.writeStatus))")
        check("and drawn", await shownText(15) { $0.contains("Suspended Flux's reconciliation") } != nil)

        // r on a suspended one: refused with why.
        page.giveListTheKeyboard()
        page.writeStatus = nil
        check("r is the list's", await pressKubernetesKey("r", keyCode: 15))
        check(
            "a suspended one isn't reconciled",
            await eventually(10) { page.writeStatus == .failed(KubeGitOps.suspended("kustomization shop/tree-shop")) } && window.attachedSheet == nil,
            "\(String(describing: page.writeStatus))")

        // p again: read as suspended, so a resume, with a reconcile asked.
        page.giveListTheKeyboard()
        check("p again", await pressKubernetesKey("p", keyCode: 35))
        check("the resume is asked", await eventually(10) { self.window.attachedSheet != nil })
        let resume = sheetTexts().joined(separator: "\n")
        check("as a resume", resume.contains("Resume Flux's reconciliation of kustomization shop/tree-shop?"), resume)
        confirmSheet()
        check(
            "confirmed, resumed with a reconcile asked",
            await eventually(10) { !suspended() && annotations(ks)[KubeGitOps.requestedAt] != nil }, "\(annotations(ks))")
        let firstAsk = annotations(ks)[KubeGitOps.requestedAt]

        // r: a reconcile.
        await pause(1.1)
        page.giveListTheKeyboard()
        check("r reconciles", await pressKubernetesKey("r", keyCode: 15))
        check("asked", await eventually(10) { self.window.attachedSheet != nil }, "\(String(describing: page.writeStatus))")
        let reconcile = sheetTexts().joined(separator: "\n")
        check(
            "naming it and its flux command",
            reconcile.contains("Reconcile kustomization shop/tree-shop now?") && reconcile.contains("flux reconcile kustomization tree-shop --context kind-fake -n shop"),
            reconcile)
        confirmSheet()
        check(
            "confirmed, asked again: requestedAt is now",
            await eventually(10) { annotations(ks)[KubeGitOps.requestedAt].map { $0 != firstAsk } == true }, "\(annotations(ks))")

        // The tree: its GitRepository's own verbs.
        page.open(KubeObjectRef(context: "kind-fake", kind: model.discovery?.kind("ks") ?? .pods, namespace: "shop", name: "tree-shop"), from: .list)
        page.showTab(.overview)
        check(
            "the detail's buttons have them",
            page.detailVerbs(for: page.detail?.ref ?? KubeObjectRef(context: "", kind: .pods, namespace: nil, name: "")).contains { $0.title == "Reconcile…" })
        check("its tree", await eventually(15) { page.detail?.tree?.state == .loaded }, "\(String(describing: page.detail?.tree?.state))")
        if let source = page.detail?.tree?.tree?.root.children.first(where: { $0.kind == "GitRepository" }) {
            let title = KubeWriteVerb.reconcile.title
            check(
                "its GitRepository reconciles from the tree, once reviewed",
                await eventually(10) { page.treeVerbs(for: source).first { $0.title == title }.map { $0.unavailable == nil } == true },
                "\(page.treeVerbs(for: source).map { "\($0.title) \($0.unavailable ?? "")" })")
            page.treeVerbs(for: source).first { $0.title == title }?.perform()
            check("asked", await eventually(10) { self.window.attachedSheet != nil }, "\(String(describing: page.writeStatus))")
            let sourceText = sheetTexts().joined(separator: "\n")
            check(
                "naming the source", sourceText.contains("Reconcile gitrepository shop/acme-shop now?") && sourceText.contains("flux reconcile source git acme-shop"),
                sourceText)
            confirmSheet()
            check(
                "confirmed, it is asked to reconcile",
                await eventually(10) { annotations("gitrepositories.source.toolkit.fluxcd.io", "acme-shop")[KubeGitOps.requestedAt] != nil })
        } else {
            check("its tree's GitRepository", false, "\(page.detail?.tree?.tree?.root.children.map(\.kind) ?? [])")
        }
        page.closeDetail()

        // An Application: r refreshes it, s syncs it with argocd in a tab.
        guard await showKubernetesKind(model, page, "applications", row: row) else { return }
        page.selection = [row.description]
        let refreshTitle = KubeWriteVerb.refresh.title
        check("Refresh… is offered once reviewed", await eventually(10) { verb(refreshTitle).map { $0.unavailable == nil } == true })
        page.giveListTheKeyboard()
        check("r is the list's", await pressKubernetesKey("r", keyCode: 15))
        check("the refresh is asked", await eventually(10) { self.window.attachedSheet != nil }, "\(String(describing: page.writeStatus))")
        let refresh = sheetTexts().joined(separator: "\n")
        check("naming it", refresh.contains("Refresh application shop/tree-shop?") && refresh.contains("kind-fake · namespace shop"), refresh)
        check(
            "and the annotation it is",
            refresh.contains("kubectl annotate applications.argoproj.io tree-shop argocd.argoproj.io/refresh=normal --overwrite --context kind-fake -n shop"), refresh)
        confirmSheet()
        check("confirmed, Argo CD is asked", await eventually(10) { annotations("applications.argoproj.io")[KubeGitOps.refresh] == "normal" })
        let syncTitle = KubeTabWrite.title(.argoSync)
        check("Sync in a Tab… once reviewed", await eventually(10) { verb(syncTitle).map { $0.unavailable == nil } == true }, verb(syncTitle)?.unavailable ?? "none")
        page.giveListTheKeyboard()
        page.writeStatus = nil
        check("s is the list's", await pressKubernetesKey("s", keyCode: 1))
        check("the sync is asked", await eventually(10) { self.window.attachedSheet != nil }, "\(String(describing: page.writeStatus))")
        let syncLine = "env -u ARGOCD_SERVER -u ARGOCD_AUTH_TOKEN -u ARGOCD_OPTS argocd app sync tree-shop --app-namespace shop --core --kube-context kind-fake"
        let sync = sheetTexts().joined(separator: "\n")
        check(
            "naming it, Argo CD's namespace and the command its tab runs",
            sync.contains("Sync application shop/tree-shop?") && sync.contains("namespace argocd") && sync.contains(syncLine), sync)
        check("nothing recorded while it asks", recorded.isEmpty)
        confirmSheet()
        check("confirmed, it is recorded, not typed", await eventually(10) { recorded.count == 1 }, "\(String(describing: page.writeStatus))")
        check("argocd, its context said", recorded.first?.command == syncLine, recorded.first?.command ?? "")
        check(
            "in a tab pinned to kind-fake, in Argo CD's namespace", recorded.first?.tab.kubePin?.context == "kind-fake" && recorded.first?.tab.kubePin?.namespace == "argocd",
            "\(String(describing: recorded.first?.tab.kubePin))")
        if app.store.showingOverlay != .kubernetes { app.showKubernetesPage() }

        // Nothing written but those patches.
        let patched = Set(fake.writes.filter { !$0.isAccessReview }.map(\.description))
        check(
            "nothing written elsewhere",
            patched == [
                "PATCH /apis/kustomize.toolkit.fluxcd.io/v1/namespaces/shop/kustomizations/tree-shop",
                "PATCH /apis/source.toolkit.fluxcd.io/v1/namespaces/shop/gitrepositories/acme-shop",
                "PATCH /apis/argoproj.io/v1alpha1/namespaces/shop/applications/tree-shop",
            ] && fake.writes.filter { !$0.isAccessReview }.count == 5, "\(fake.writes.map(\.description))")
        page.writeStatus = nil
        page.showKind(model.discovery?.kind("po") ?? .pods)
    }
}
