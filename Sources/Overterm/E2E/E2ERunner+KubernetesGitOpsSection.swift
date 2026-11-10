import AppKit
import Foundation
import SwiftUI

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
/// they are and Show adds that namespace; hidden, nothing is asked. G3:
/// the detail's GitOps header says why, where from and what is applied,
/// its chain inside it; `a` on a Failed row opens the brief, scrubbed, and
/// on a Ready one says why not. Reads only but the access reviews; every
/// sheet ended by the runner.
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
            // G3: its Overview's GitOps header, from the detail's one GET and the summaries kept.
            page.showTab(.overview)
            check("the detail's GitOps header read", await eventually(10) { page.detail?.gitOps?.object.ref.name == "acme-cron" })
            check(
                "it says why, as the row does",
                await shownText(15) { $0.contains("Failed: main@c03f9aa failed (BuildFailed); main@a77b0d1 still applied") } != nil)
            let header = await overviewElement("kubernetes.detail.gitops", timeout: 10)
            let chain = await overviewElement("kubernetes.detail.gitops.chain", timeout: 10)
            let detailFrame = await overviewElement("kubernetes.detail", timeout: 10)
            Self.accessibilityTree(false)
            if let header, let chain, let detailFrame {
                check("where from, its source's URL without its token", header.text.contains("git.acme.example/acme/shop ./apps/cron @main"), header.text)
                check("what its source fetched, and when", header.text.contains("by GitRepository acme-fleet"), header.text)
                check("its chain names its source", chain.text.contains("GitRepository flux-system/acme-fleet"), chain.text)
                check("never the sentinel or a token in it", !header.text.contains(FakeKubeAPI.gitOpsSentinel) && !header.text.contains("ghp_fake"), header.text)
                check("the header inside the detail", detailFrame.frame.insetBy(dx: -1, dy: -1).contains(header.frame), "\(detailFrame.frame) \(header.frame)")
                check("its chain inside the header", header.frame.insetBy(dx: -1, dy: -1).contains(chain.frame), "\(header.frame) \(chain.frame)")
            } else {
                check("the header's layout read", false, "\(header.debugDescription) \(chain.debugDescription)")
            }
            check(
                "nothing written for it, the verbs' access reviews aside",
                !fake.requests.contains { $0.method != "GET" && !$0.path.contains("accessreviews") }, "\(fake.requests.filter { $0.method != "GET" }.map(\.path))")
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

        // a: Ask Why on a Failed row — its brief shown whole, scrubbed; on a Ready one, why not.
        if let cron = row("Kustomization", "acme-cron") {
            func sheet() -> AskAgentView? { (window.attachedSheet?.contentViewController as? NSHostingController<AskAgentView>)?.rootView }
            page.gitOpsView.selection = [cron.id]
            page.giveListTheKeyboard()
            fake.forgetRequests()
            check("a on its row", await pressKubernetesKey("a", keyCode: 0))
            check("the Ask Agent sheet opens", await eventually(15) { self.window.attachedSheet != nil && sheet() != nil }, page.commandProblem ?? "")
            let ask = app.askAgent
            check(
                "the question started for you",
                ask.message == "Why does Flux Kustomization flux-system/acme-cron fail to deploy, and what should change?"
                    && ask.subject == "Kustomization/acme-cron Failed", "\(ask.message) / \(ask.subject ?? "none")")
            check("the whole brief shown before it is sent", ask.showsBrief)
            let prompt = await app.askAgentPrompt()
            check("its state, attempted against applied", prompt.contains("main@c03f9aa failed (BuildFailed); main@a77b0d1 still applied"), prompt)
            check("its conditions", ask.parts.contains { $0.title == "conditions" }, "\(ask.parts.map(\.title))")
            check("the sentinel and a token never in it", !prompt.contains(FakeKubeAPI.gitOpsSentinel) && !prompt.contains("ghp_fake"), prompt)
            check("read with GETs alone, no Secret", fake.requests.allSatisfy { $0.method == "GET" } && !fake.requests.contains { $0.path.contains("/secrets") })
            let cancelled = sheet().map { $0.cancel() } != nil
            check("Cancel sends nothing", await eventually(3) { self.window.attachedSheet == nil } && cancelled && !ask.isOpen)
            if app.store.showingOverlay != .kubernetes { app.toggleKubernetesPage(nil) }
            // An isolated run is never activated: after a sheet its window may
            // be neither key nor main, and the later parts need the keyboard —
            // given back, as a person's click on the window would.
            if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
            page.giveListTheKeyboard()
        }
        if let apps = row("Kustomization", "acme-apps") {
            page.gitOpsView.selection = [apps.id]
            page.giveListTheKeyboard()
            check("a on a Ready row", await pressKubernetesKey("a", keyCode: 0))
            check("says why not", page.commandProblem?.contains("acme-apps is Ready") == true, page.commandProblem ?? "none")
            await pause(0.4)
            check("and opens nothing", window.attachedSheet == nil)
            page.commandProblem = nil
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
