import AppKit
import Foundation

/// Stage 2f's check (docs/design/kubernetes/analysis.md, Section 9): Helm's
/// writes against the fake's own release records, never a real cluster,
/// and no helm ever run. On `fake-dev` (read-only) Roll Back and Uninstall
/// are greyed with why and refused — nothing recorded, nothing sent, not
/// even a review. On `kind-fake` (local, so writable) the release's records
/// are reviewed (SelfSubjectAccessReview: create and update secrets; an
/// opened release's Deployment too), the revision picked from its history,
/// the rollback asked in the window naming the context and namespace and
/// the helm it runs, then **recorded, not typed** — in a tab pinned to the
/// context; the uninstall asks for the release's name even here, a wrong
/// one running nothing; a ConfigMap-stored release's says its driver. On
/// `fake-prod`, refused until its writes are on for the session; then a
/// rollback from its History row asks for the name. Only reviews reach the fake.
extension E2ERunner {
    func kubernetesHelmWrites(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        let wasShowing = app.store.showingOverlay == .kubernetes
        if !wasShowing { app.toggleKubernetesPage(nil) }
        defer { if !wasShowing, app.store.showingOverlay == .kubernetes { app.toggleKubernetesPage(nil) } }
        let opened = Set(app.store.tabs.map(\.id))
        var recorded: [(command: String, tab: Tab)] = []
        app.kubernetesCommandRecorder = { command, tab in recorded.append((command, tab)) }
        defer {
            app.kubernetesCommandRecorder = nil
            app.closeTabsWithoutAsking(app.store.tabs.filter { !opened.contains($0.id) })
        }
        let helm = page.helm
        func back() { if app.store.showingOverlay != .kubernetes { app.showKubernetesPage() } }
        func sheetButtons() -> [String] {
            guard let root = window.attachedSheet?.contentView else { return [] }
            var titles: [String] = []
            func walk(_ view: NSView) {
                if let button = view as? NSButton, !button.title.isEmpty { titles.append(button.title) }
                view.subviews.forEach(walk)
            }
            walk(root)
            return titles
        }
        /// The context's releases in shop, on the Helm section.
        func releases(on context: String) async -> KubeHelmRelease? {
            model.select(context)
            model.setScope(.namespace("shop"))
            back()
            page.showSection(.helm)
            let listed = await eventually(15) {
                helm.context == context && helm.listState == .live && helm.releases.map(\.name) == ["cache", "web"]
            }
            check("\(context)'s releases listed", listed, "\(helm.context ?? "none") \(helm.listState) \(helm.releases.map(\.name))")
            return helm.releases.first { $0.name == "web" }
        }
        func verb(_ verb: KubeProcessVerb, _ release: KubeHelmRelease) -> ResourceVerb? {
            page.helmWriteVerbs(for: release).first { $0.title == KubeHelmWrite.title(verb) }
        }
        func answer(_ code: NSApplication.ModalResponse) { if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: code) } }

        // fake-dev: read-only — both greyed with why, refused, nothing sent.
        guard let devWeb = await releases(on: "fake-dev") else { return }
        fake.forgetRequests()
        page.writeStatus = nil
        let readOnly = KubeProcessCheck.readOnly(.remote)
        check(
            "fake-dev's Roll Back and Uninstall are greyed with why",
            verb(.helmRollback, devWeb)?.unavailable == readOnly && verb(.helmUninstall, devWeb)?.unavailable == readOnly,
            "\(page.helmWriteVerbs(for: devWeb).map { $0.unavailable ?? "none" })")
        verb(.helmRollback, devWeb)?.perform()
        check("a rollback refused at once", page.writeStatus == .failed(readOnly) && window.attachedSheet == nil, "\(String(describing: page.writeStatus))")
        check("the refusal drawn", await shownText(15) { $0.contains("This context is read-only") } != nil)
        page.writeStatus = nil
        helm.selection = devWeb.id
        check("⌫ on the release is refused too", page.helmPress("\u{7F}") == true && page.writeStatus == .failed(readOnly), "\(String(describing: page.writeStatus))")
        await pause(0.3)
        check("nothing recorded, nothing sent — not even a review", recorded.isEmpty && fake.writes.isEmpty, "\(fake.writes)")

        // kind-fake: reviewed, picked, asked, recorded.
        model.writeAccess.forget(context: "kind-fake")
        page.writeStatus = nil
        guard let web = await releases(on: "kind-fake") else { return }
        check(
            "kind-fake's rollback is offered once reviewed", await eventually(10) { verb(.helmRollback, web).map { $0.unavailable == nil } == true },
            verb(.helmRollback, web)?.unavailable ?? "none")
        func reviewed() -> [[String: String]] {
            fake.requests.filter(\.isAccessReview).compactMap {
                (($0.json as? [String: Any])?["spec"] as? [String: Any])?["resourceAttributes"] as? [String: String]
            }
        }
        check(
            "as the cluster's access review of its records in shop",
            reviewed().contains(["verb": "create", "resource": "secrets", "group": "", "namespace": "shop"])
                && reviewed().contains(["verb": "update", "resource": "secrets", "group": "", "namespace": "shop"]), "\(reviewed())")
        page.openHelm(web)
        check("web opened and read", await eventually(15) { helm.opened?.detail != nil }, "\(String(describing: helm.opened?.state))")
        check("its buttons drawn", await shownText(15) { $0.contains("Roll Back") } != nil)
        // Each offered once its review answers: the uninstall's is its own.
        let wanted = ["Kubernetes: Roll Back Helm Release shop/web in a Tab…", "Kubernetes: Uninstall Helm Release shop/web in a Tab…"]
        check(
            "⌘K finds them too", await eventually(10) { Set(wanted).isSubset(of: self.app.kubernetesPageCommands().map(\.title)) },
            "\(app.kubernetesPageCommands().map(\.title))")
        verb(.helmRollback, web)?.perform()
        check("which revision is asked", await eventually(10) { self.window.attachedSheet != nil }, "\(String(describing: page.writeStatus))")
        check(
            "and its manifest's Deployment reviewed too",
            reviewed().contains(["verb": "patch", "resource": "deployments", "group": "apps", "namespace": "shop"]), "\(reviewed())")
        let choices = sheetButtons()
        check("the earlier revision, from its history", choices.first?.hasPrefix("Revision 1 — superseded") == true && choices.count == 2, "\(choices)")
        answer(.alertFirstButtonReturn)
        check(
            "then the rollback is asked",
            await eventually(10) { self.sheetTexts().contains { $0.contains("Roll back Helm release shop/web to revision 1?") } }, "\(sheetTexts())")
        let rollLine = "helm rollback web 1 --kube-context kind-fake -n shop"
        check(
            "naming kind-fake and shop, and the helm it runs", sheetTexts().contains { $0.contains("kind-fake · namespace shop") } && sheetTexts().contains { $0.contains(rollLine) }, "\(sheetTexts())"
        )
        check("no name asked off production", typedNameField() == nil)
        check("nothing recorded while it asks", recorded.isEmpty)
        answer(.alertFirstButtonReturn)
        check("confirmed, it is recorded, not typed", await eventually(10) { recorded.count == 1 }, "\(String(describing: page.writeStatus))")
        check("helm rollback, its context and namespace said", recorded.first?.command == rollLine, recorded.first?.command ?? "")
        check(
            "in a tab pinned to kind-fake", recorded.first?.tab.kubePin?.context == "kind-fake" && recorded.first?.tab.kubePin?.namespace == "shop",
            "\(String(describing: recorded.first?.tab.kubePin))")
        check(
            "the page says so", page.writeStatus == .done("Rolling back Helm release shop/web to revision 1 in a new tab, in kind-fake."),
            "\(String(describing: page.writeStatus))")

        // Uninstall: the name asked even on a local context; a wrong one runs nothing.
        back()
        page.writeStatus = nil
        check(
            "its uninstall is offered once reviewed", await eventually(10) { verb(.helmUninstall, web).map { $0.unavailable == nil } == true },
            verb(.helmUninstall, web)?.unavailable ?? "none")
        verb(.helmUninstall, web)?.perform()
        check("the uninstall is asked", await eventually(10) { self.window.attachedSheet != nil && self.typedNameField() != nil }, "\(String(describing: page.writeStatus))")
        let uninstallLine = "helm uninstall web --kube-context kind-fake -n shop"
        check(
            "naming the release and the helm it runs",
            sheetTexts().contains { $0.contains("Uninstall Helm release shop/web?") } && sheetTexts().contains { $0.contains(uninstallLine) }, "\(sheetTexts())")
        typedNameField()?.stringValue = "wbe"
        answer(.alertFirstButtonReturn)
        check("a wrong name runs nothing", await eventually(10) { page.writeStatus == .failed("The name typed wasn't web: nothing was run.") } && recorded.count == 1)
        verb(.helmUninstall, web)?.perform()
        check("asked again", await eventually(10) { self.typedNameField() != nil })
        typedNameField()?.stringValue = "web"
        answer(.alertFirstButtonReturn)
        check("its name typed, recorded", await eventually(10) { recorded.count == 2 } && recorded.last?.command == uninstallLine, recorded.last?.command ?? "")

        // A ConfigMap-stored release: helm told its driver. Cancelled: nothing.
        back()
        page.writeStatus = nil
        if let cache = helm.releases.first(where: { $0.name == "cache" }) {
            check("cache, one revision: no rollback", verb(.helmRollback, cache)?.unavailable == KubernetesPageModel.noEarlierRevision(cache))
            check("its uninstall offered once reviewed", await eventually(10) { verb(.helmUninstall, cache).map { $0.unavailable == nil } == true })
            verb(.helmUninstall, cache)?.perform()
            check("asked", await eventually(10) { self.window.attachedSheet != nil })
            check(
                "with its driver said", sheetTexts().contains { $0.contains("HELM_DRIVER=configmap helm uninstall cache --kube-context kind-fake -n shop") },
                "\(sheetTexts())")
            answer(.alertSecondButtonReturn)
            await pause(0.3)
            check("cancelled, nothing recorded", recorded.count == 2)
        }

        // fake-prod: refused until writes are on for the session; then the name is asked.
        page.writeStatus = nil
        guard let prodWeb = await releases(on: "fake-prod") else { return }
        let prodReadOnly = KubeProcessCheck.readOnly(.production)
        check("fake-prod's rollback is refused", verb(.helmRollback, prodWeb)?.unavailable == prodReadOnly, verb(.helmRollback, prodWeb)?.unavailable ?? "none")
        page.allowProductionWrites()
        check("turning writes on is asked", await eventually(5) { self.window.attachedSheet != nil })
        answer(.alertFirstButtonReturn)
        check("fake-prod's writes are on", await eventually(5) { model.selected?.isWritable == true && page.productionWritesOn })
        check(
            "its rollback offered once reviewed", await eventually(15) { verb(.helmRollback, prodWeb).map { $0.unavailable == nil } == true },
            verb(.helmRollback, prodWeb)?.unavailable ?? "none")
        // From its History row: revision 1, no picker.
        page.runHelmWrite(.helmRollback, on: prodWeb, revision: 1)
        check("asked, its name asked too", await eventually(10) { self.window.attachedSheet != nil && self.typedNameField() != nil }, "\(String(describing: page.writeStatus))")
        check("PRODUCTION, fake-prod and shop", sheetTexts().contains { $0.contains("PRODUCTION · fake-prod · namespace shop") }, "\(sheetTexts())")
        check(
            "in production's red",
            Self.find(NSTextField.self, in: window.attachedSheet?.contentView) { $0.accessibilityIdentifier() == "write.scope" }?.textColor
                == WriteConfirmation.productionRed)
        typedNameField()?.stringValue = "webb"
        answer(.alertFirstButtonReturn)
        check("a wrong name runs nothing", await eventually(10) { page.writeStatus == .failed("The name typed wasn't web: nothing was run.") } && recorded.count == 2)
        page.runHelmWrite(.helmRollback, on: prodWeb, revision: 1)
        check("asked again", await eventually(10) { self.typedNameField() != nil })
        typedNameField()?.stringValue = "web"
        answer(.alertFirstButtonReturn)
        let prodLine = "helm rollback web 1 --kube-context fake-prod -n shop"
        check("its name typed, recorded, not typed", await eventually(10) { recorded.count == 3 } && recorded.last?.command == prodLine, recorded.last?.command ?? "")
        back()
        page.endProductionWrites()
        check("writes off again", await eventually(5) { model.selected?.isWritable == false })

        check("only access reviews reached the fake", fake.writes.allSatisfy(\.isAccessReview), "\(fake.writes.filter { !$0.isAccessReview })")
        check("and every record is still there", fake.names("secrets").filter { $0.hasPrefix("sh.helm.release.v1.web.") }.count == 2)
        page.writeStatus = nil
        helm.close()
        page.showSection(.workloads)
        model.select("fake-dev")
        check("fake-dev's version read again", await eventually(10) { model.version != nil })
    }
}
