import AppKit
import Foundation

/// G2 (docs/design/kubernetes/gitops.md, 2, 3, 8.4) against the fake API
/// server, never a real cluster: `g` on kind-fake shows Argo CD's and
/// Flux's objects that live in or deploy into `shop` — the chips drawn,
/// problems first, acme-cron Failed, acme-api Blocked by acme-broken,
/// acme-web's chain naming acme-infra, acme-shop-prod kept by its
/// destination and acme-apps by its inventory, acme-remote not; Hide
/// Ready; the banner once kustomize-controller isn't ready; ↩ opens the
/// detail in its kind's list and `[` comes back with no whole-object list
/// read again; `r` asks the page's own sheet (cancelled: nothing sent); `s`
/// records argocd's sync in a tab, never typed; `:flux` keeps Flux's rows;
/// the Overview's GitOps card says to press `g`; the empty scope says where
/// they are and Show adds that namespace; hidden, nothing is asked. Reads
/// only but the access reviews; every sheet ended by the runner.
extension E2ERunner {
    func kubernetesGitOpsSection(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        let wasShowing = app.store.showingOverlay == .kubernetes
        if !wasShowing { app.toggleKubernetesPage(nil) }
        defer { if !wasShowing, app.store.showingOverlay == .kubernetes { app.toggleKubernetesPage(nil) } }
        let opened = Set(app.store.tabs.map(\.id))
        var recorded: [String] = []
        recordKubernetesCommands { command, _ in recorded.append(command) }
        defer {
            app.kubernetesCommandRecorder = nil
            app.closeTabsWithoutAsking(app.store.tabs.filter { !opened.contains($0.id) })
        }
        func endSheet(_ code: NSApplication.ModalResponse) { if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: code) } }
        func row(_ kind: String, _ name: String) -> KubeGitOpsRow? { page.gitOps.rows.shown.first { $0.key.kind == kind && $0.ref.name == name } }
        func whole() -> [FakeKubeAPI.Request] {
            fake.requests.filter {
                !$0.isWatch && !$0.accept.contains("as=Table") && $0.query["limit"] != nil
                    && ($0.path.contains("argoproj.io") || $0.path.contains("toolkit.fluxcd.io"))
            }
        }

        fake.addGitOpsFixtures()
        page.closeDetail()
        page.writeStatus = nil
        model.select("kind-fake")
        model.setScope(.namespace("shop"))
        check(
            "kind-fake serves Argo CD's and Flux's kinds", await eventually(15) { model.selectedName == "kind-fake" && page.gitOpsServed },
            "\(model.discovery?.kinds.filter { $0.group.contains("flux") }.map(\.fullName) ?? [])")
        page.showKind(model.discovery?.kind("po") ?? .pods)
        _ = await eventually(15) { model.listState == .live && !model.rows.columns.isEmpty }
        page.giveListTheKeyboard()
        check("the list has the keyboard", await eventually(5) { self.app.kubernetesListHasKeyboard() })
        fake.forgetRequests()

        // g: the section, problems first.
        check("g is the list's", await pressKubernetesKey("g", keyCode: 5))
        check("and shows GitOps", page.section == .gitops)
        let gitOps = page.gitOps
        check(
            "its rows read and ranked",
            await eventually(20) { gitOps.state == .live && !gitOps.summarising && row("Kustomization", "acme-cron") != nil },
            "\(gitOps.state) \(gitOps.rows.shown.map(\.ref.description))")
        check("acme-cron Failed", row("Kustomization", "acme-cron")?.state == .failed, row("Kustomization", "acme-cron")?.why ?? "none")
        check(
            "acme-api Blocked by acme-broken", row("Kustomization", "acme-api").map { $0.state == .blocked && $0.why.contains("acme-broken") } == true,
            row("Kustomization", "acme-api")?.why ?? "none")
        check("acme-web's chain names acme-infra", row("Kustomization", "acme-web")?.why.contains("acme-infra") == true, row("Kustomization", "acme-web")?.why ?? "none")
        check("acme-shop-prod kept by its destination", row("Application", "acme-shop-prod") != nil)
        check("acme-apps by its inventory", row("Kustomization", "acme-apps") != nil)
        check("acme-remote not kept", row("Application", "acme-remote") == nil)
        let states = page.gitOpsVisibleRows.map(\.state)
        check("problems first", states == states.sorted(), "\(states)")
        check("the chips drawn", await shownText(15) { $0.contains("failing") } != nil)
        check("the rows drawn", await shownText(15) { $0.contains("flux-system/acme-cron") } != nil)
        check("the section's table has the keyboard", await eventually(5) { self.app.kubernetesListHasKeyboard() })
        let watches = fake.requests.filter(\.isWatch)
        check("rows only, never whole objects watched", watches.allSatisfy { $0.query["includeObject"] != "Object" }, "\(watches.map(\.query))")
        check("one paged list a summarised kind", whole().allSatisfy { $0.query["limit"] == "20" } && !whole().isEmpty)
        check("never a Secret or a ConfigMap", !fake.requests.contains { $0.path.contains("/secrets") || $0.path.contains("/configmaps") })
        check("GETs only", fake.requests.allSatisfy { $0.method == "GET" })

        // Hide Ready.
        page.gitOpsView.hideReady = true
        check("Hide Ready hides them", !page.gitOpsVisibleRows.contains { $0.state == .ready })
        page.pressGitOpsChip(.ready)
        check("and the Ready chip shows them", !page.gitOpsVisibleRows.isEmpty && page.gitOpsVisibleRows.allSatisfy { $0.state == .ready })
        page.pressGitOpsChip(.ready)
        page.gitOpsView.hideReady = nil

        // The banner.
        fake.setControllerReady("kustomize-controller", false)
        check("a controller down: the banner", await shownText(15) { $0.contains("kustomize-controller 0/1 ready in flux-system") } != nil)
        check("Flux's rows may be stale", await eventually(5) { row("Kustomization", "acme-cron")?.tags.contains(.mayBeStale) == true })
        fake.setControllerReady("kustomize-controller", true)
        check("up again, gone", await eventually(10) { KubeGitOpsControllers.banner(gitOps.controllers) == nil })

        // ↩ opens the detail; [ comes back with no list read again.
        if let cron = row("Kustomization", "acme-cron") {
            page.gitOpsView.selection = [cron.id]
            check("↩ is the section's", await pressKubernetesKey("\r", keyCode: 36))
            check(
                "the object in its kind's list, its detail open",
                await eventually(10) { page.section == .custom && page.detail?.ref.name == "acme-cron" }, "\(page.section) \(page.detail?.ref.name ?? "none")")
            fake.forgetRequests()
            page.goBack()
            check("[ back to GitOps", page.section == .gitops)
            check("live again", await eventually(10) { gitOps.state == .live && row("Kustomization", "acme-cron") != nil })
            await pause(0.5)
            check("no whole-object list read again", whole().isEmpty, "\(whole().map(\.path))")
        }

        // r: the page's own sheet, cancelled — nothing sent.
        if let cron = row("Kustomization", "acme-cron") {
            page.gitOpsView.selection = [cron.id]
            page.giveListTheKeyboard()
            check("r on its row", await pressKubernetesKey("r", keyCode: 15))
            check("asked in the window", await eventually(10) { self.window.attachedSheet != nil }, "\(String(describing: page.writeStatus))")
            let asked = sheetTexts().joined(separator: "\n")
            check(
                "the reconcile's sheet, naming it",
                asked.contains("Reconcile kustomization flux-system/acme-cron now?") && asked.contains("kind-fake · namespace flux-system"), asked)
            endSheet(.alertSecondButtonReturn)
            await pause(0.3)
            check("cancelled, nothing patched", !fake.writes.contains { $0.method == "PATCH" && $0.path.contains("acme-cron") })
        }

        // s: argocd in a tab, recorded, never typed.
        if let web = row("Application", "acme-web") {
            page.gitOpsView.selection = [web.id]
            page.giveListTheKeyboard()
            check("s on an Application", await pressKubernetesKey("s", keyCode: 1))
            _ = await eventually(10) { self.window.attachedSheet != nil || !recorded.isEmpty }
            if window.attachedSheet != nil { endSheet(.alertFirstButtonReturn) }
            check(
                "argocd's sync recorded, not typed", await eventually(10) { recorded.contains { $0.contains("argocd app sync") && $0.contains("acme-web") } },
                "\(recorded) \(String(describing: page.writeStatus))")
        }
        page.gitOpsView.selection = []
        // The sync's tab took the window: the page again, on GitOps.
        if app.store.showingOverlay != .kubernetes { app.toggleKubernetesPage(nil) }
        if page.section != .gitops { page.showSection(.gitops) }
        check("GitOps again", await eventually(15) { gitOps.state == .live && !gitOps.summarising && row("Kustomization", "acme-cron") != nil })

        // :flux — one tool's rows.
        check(":flux runs", page.run(KubeCommand.parse(":flux")!) == nil)
        check("only Flux's rows", !page.gitOpsVisibleRows.isEmpty && page.gitOpsVisibleRows.allSatisfy { $0.tool == .flux })
        check("said as a chip", await shownText(15) { $0.contains("Flux only") } != nil)
        page.gitOpsView.tool = nil

        // The Overview's line goes to g.
        model.setScope(.namespace("flux-system"))
        page.showSection(.overview)
        check(
            "the Overview's GitOps card", await eventually(20) { KubeOverviewCards.gitOps(page.health.report, scope: page.health.scope) != nil },
            "\(page.health.state)")
        check("drawn, saying where to go", await shownText(15) { $0.contains("press g for what deploys here") } != nil)
        // The card itself clicked where a person would click it, in this window only.
        let card = await overviewElement("kubernetes.overview.gitops", timeout: 10)
        Self.accessibilityTree(false)
        check("the card found", card != nil)
        if let card {
            let centre = window.convertPoint(fromScreen: CGPoint(x: card.frame.midX, y: card.frame.midY))
            check("the card on screen", window.contentView?.bounds.contains(centre) == true, "\(card.frame) → \(centre)")
            await click(at: centre)
        }
        check("its press shows GitOps", await eventually(5) { page.section == .gitops }, "\(page.section)")
        check("and reads it again", await eventually(15) { gitOps.state == .live && !gitOps.summarising })

        // The layout: the section's header, notes and chips laid inside the page, one under another.
        let section = await overviewElement("kubernetes.gitops.section", timeout: 10)
        let header = await overviewElement("kubernetes.gitops.header", timeout: 10)
        let chips = await overviewElement("kubernetes.gitops.chips", timeout: 10)
        Self.accessibilityTree(false)
        if let section, let header, let chips {
            let inside = { (frame: CGRect) in section.frame.insetBy(dx: -1, dy: -1).contains(frame) && frame.width > 0 && frame.height > 0 }
            check("the header and the chips inside the section", inside(header.frame) && inside(chips.frame), "\(section.frame) \(header.frame) \(chips.frame)")
            // Screen points: y grows upwards.
            check("the chips under the header", chips.frame.maxY <= header.frame.minY + 1, "\(header.frame) \(chips.frame)")
            check("the header says what was summarised", !header.text.isEmpty, header.text)
        } else {
            check("the section's layout read", false, "\(section.debugDescription) \(header.debugDescription) \(chips.debugDescription)")
        }

        // The empty scope says where they are.
        fake.addNamespace("quiet")
        model.setScope(.namespace("quiet"))
        check("an empty scope says so", await shownText(15) { $0.contains("No GitOps object lives in or deploys into quiet.") } != nil)
        let hint = KubeGitOpsSection.emptyHint(gitOps.rows, scope: model.scope)
        check("pointing to where they are", hint.namespace != nil, hint.text)
        if let namespace = hint.namespace {
            check("Show drawn", await shownText(15) { $0.contains("Show \(namespace)") } != nil)
            page.showGitOpsNamespace(namespace)
            check("Show adds it, never widened silently", await eventually(5) { model.scope == .namespaces(["quiet", namespace]) }, "\(model.scope)")
            check("its rows then", await eventually(10) { !gitOps.rows.shown.isEmpty })
        }
        model.setScope(.namespace("shop"))
        await pause(0.6)
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
            app.captureWindow(to: png.replacingOccurrences(of: ".png", with: "-kube-gitops.png"))
        }

        // Hidden: nothing asked; the summaries go.
        app.toggleKubernetesPage(nil)
        check("hidden, its follows end", await eventually(5) { gitOps.openFollows == 0 && fake.openWatches == 0 }, "\(fake.openWatches) open")
        check("and the summaries go", gitOps.objects.isEmpty)
        fake.forgetRequests()
        await pause(1.5)
        check("nothing is asked", fake.requests.isEmpty, "\(fake.requests)")
        app.toggleKubernetesPage(nil)
        page.showKind(model.discovery?.kind("po") ?? .pods)
        check("back on the list", await eventually(5) { page.section == .workloads })
    }
}
