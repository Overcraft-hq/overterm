import AppKit
import Foundation
import SwiftUI

/// G5 (docs/design/kubernetes/gitops.md, 4, 8.4) against the fake API
/// server, never a real cluster, once `kubernetesGitOpsSection` has
/// Argo CD's and Flux's fixtures served: the shared fixture checkout
/// (`E2EKubeCheckoutFixture`, its own folder here) with a remote in the
/// scp form naming `acme/shop` and a `deploy/fake-dev` folder, its tab
/// selected, the rail on its Kubernetes panel, bound to kind-fake/shop.
///
/// 1. The rail's GitOps part: Kustomization flux-system/acme-apps owns
///    Deployment/shop-api — found by one GET of it, the workloads' rows
///    carrying their marks in the binding's namespace — and takes
///    deploy/fake-dev from the checkout's repository (its GitRepository's
///    URL listed without its token); acme-cron's path isn't on this
///    branch, said; an Application with the path is found in argocd, Open
///    on Page opens its detail on the page, and its history's entry opens
///    a review of `git diff c1..c3 -- deploy/fake-dev` in the checkout.
/// 2. Reconcile from the rail asks the page's own sheet in the window —
///    the context, the namespace, the flux command — then one merge patch;
///    its outcome said in the rail.
/// 3. Bound to fake-prod: Find What Deploys This shows, and nothing is
///    listed across the cluster before it is pressed; pressed, it is.
/// 4. (G6, gitops.md 4.3) Bound to kind-fake again: acme-cron's attempt
///    as the fixture has it ("tried c03f9aa and failed…; a77b0d1 is still
///    applied", its commits not in the checkout: fetch to compare); then
///    with acme-apps applied at c1 and origin/main left there by a fetch,
///    the manifests line — "manifests at c1, up to date with origin/main;
///    this branch is 2 commits ahead", from Flux's applied revision —
///    drawn, and Diff Deployed…Current's review tab.
/// 5. The files this branch changes under the paths it names (the path
///    and its kustomization.yaml's entry), drawn, opening a review of them;
///    the Application's "no change under … since c3 on origin/main".
/// 6. Ask Why from the rail on acme-cron, which tried HEAD: the brief
///    carries the commits from what is applied to what was tried, and the
///    changed files, scrubbed; cancelled, nothing sent.
///
/// Unbound and hidden, the rail asks nothing. Every write lands on the
/// fake; every sheet is ended by the runner.
extension E2ERunner {
    func kubernetesCheckoutGitOps(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        let panel = app.kubernetesPanel
        let gitOps = panel.gitOps
        Settings.shared.set("kubernetes.notifyOnFailure", .bool(false))
        defer { Settings.shared.set("kubernetes.notifyOnFailure", nil) }
        if app.store.showingOverlay != nil { app.hideOverlay(focus: false) }
        _ = await eventually(5) { fake.openWatches == 0 }
        func endSheet(_ code: NSApplication.ModalResponse) { if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: code) } }
        func match(_ kind: String, _ name: String) -> KubePanelGitOps.Match? { gitOps.matches.first { $0.key.kind == kind && $0.key.name == name } }
        /// A list of a GitOps kind across the cluster (no `/namespaces/` in its path), or of whole objects
        /// anywhere: never P5's rows in one namespace, nor a GET of one object.
        func lists() -> [FakeKubeAPI.Request] {
            fake.requests.filter { request in
                request.method == "GET" && !request.isWatch && (request.path.contains("argoproj.io") || request.path.contains("toolkit.fluxcd.io"))
                    && ["applications", "kustomizations", "helmreleases", "gitrepositories", "ocirepositories", "helmcharts"].contains {
                        request.path.hasSuffix("/\($0)")
                    }
                    && (!request.path.contains("/namespaces/") || !request.accept.contains("as=Table"))
            }
        }
        let gitRepositoriesAcross = "/apis/source.toolkit.fluxcd.io/v1/gitrepositories"
        func listedGitRepositories() -> Bool { fake.requests.contains { $0.path == gitRepositoriesAcross && !$0.isWatch } }

        // The fixture, with a remote naming acme/shop and the path a Kustomization takes; c3 changes it.
        guard let fixture = await E2EKubeCheckoutFixture.make(in: scratch, name: "ot-kube-shop-gitops") else {
            return check("the fixture checkout is made", false)
        }
        let repo = fixture.repo
        try? await fixture.git(["remote", "add", "origin", "git@git.acme.example:acme/shop.git"])
        try? FileManager.default.createDirectory(at: repo.appendingPathComponent("deploy/fake-dev"), withIntermediateDirectories: true)
        try? "resources:\n  - ../../k8s/api.yaml\n".write(to: repo.appendingPathComponent("deploy/fake-dev/kustomization.yaml"), atomically: true, encoding: .utf8)
        try? await fixture.git(["add", "deploy"])
        try? await fixture.git(["commit", "-q", "-m", "deploy fake-dev"])
        let c3 = ((try? await fixture.git(["rev-parse", "HEAD"])) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        check("the checkout has its remote and path", c3.count == 40, c3)

        // The workload Flux deploys, marked so; an Application of the path whose history the checkout has.
        let labels = [
            "app.kubernetes.io/part-of": "ot-shop", "kustomize.toolkit.fluxcd.io/name": "acme-apps", "kustomize.toolkit.fluxcd.io/namespace": "flux-system",
        ]
        fake.add("deployments.apps", "shop-api", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1], labels: labels)
        let now = Date()
        fake.addApplication(
            "acme-shop-dev",
            spec: [
                "project": "acme", "source": ["repoURL": "https://git.acme.example/acme/shop.git", "path": "deploy/fake-dev", "targetRevision": "main"],
                "destination": ["server": "https://kubernetes.default.svc", "namespace": "shop"],
            ],
            status: [
                "sync": ["status": "Synced", "revision": c3], "health": ["status": "Healthy"],
                "history": [
                    ["revision": fixture.c1, "deployedAt": FakeKubeAPI.time(now.addingTimeInterval(-7200))],
                    ["revision": c3, "deployedAt": FakeKubeAPI.time(now.addingTimeInterval(-600))],
                ],
            ])
        defer {
            fake.delete("applications.argoproj.io", "acme-shop-dev", namespace: "argocd")
            fake.delete("deployments.apps", "shop-api", namespace: "shop")
        }

        let previous = app.store.selected
        app.newTab(in: repo)
        guard let tab = app.store.selected else { return check("the checkout's tab opens", false) }
        defer {
            app.closeTabsWithoutAsking([tab])
            if let previous { app.store.select(previous) }
        }
        let real = FileTreeModel.realPath(repo)
        check("the panel follows the checkout", await eventually(10) { panel.checkout.map(FileTreeModel.realPath) == real }, panel.checkout?.path ?? "none")
        app.showKubernetesPanel(nil)
        defer {
            panel.unbind()
            app.sidebarPanel.panel = .files
        }

        // 1. The rail says what deploys the checkout.
        fake.forgetRequests()
        check("bound to kind-fake/shop", panel.bind(KubeBinding(checkout: real, context: "kind-fake", namespace: "shop", selector: "app.kubernetes.io/part-of=ot-shop")))
        check(
            "acme-apps owns shop-api and takes deploy/fake-dev",
            await eventually(20) { match("Kustomization", "acme-apps")?.whys.count == 2 }, "\(gitOps.state) \(gitOps.matches.map { "\($0.id): \($0.why)" })")
        check(
            "said so", match("Kustomization", "acme-apps")?.why == "owns Deployment/shop-api · deploy/fake-dev", match("Kustomization", "acme-apps")?.why ?? "none")
        check(
            "the owner found by one GET",
            fake.requests.filter { $0.path == "/apis/kustomize.toolkit.fluxcd.io/v1/namespaces/flux-system/kustomizations/acme-apps" }.count >= 1)
        check(
            "the workloads' rows carry their marks in the binding's namespace only",
            fake.requests.contains { $0.path == "/apis/apps/v1/namespaces/shop/deployments" && $0.query["includeObject"] == "Metadata" })
        check(
            "acme-cron's path is not on this branch", match("Kustomization", "acme-cron")?.why == "path apps/cron is not on this branch",
            match("Kustomization", "acme-cron")?.why ?? "none")
        check("an Application of the path, in argocd", match("Application", "acme-shop-dev")?.why == "deploy/fake-dev", match("Application", "acme-shop-dev")?.why ?? "none")
        check("the part drawn", await shownText(15) { $0.contains("owns Deployment/shop-api") } != nil)
        check("with what it tracks", match("Kustomization", "acme-apps")?.tracks == "tracks main; this branch is fix/orders", match("Kustomization", "acme-apps")?.tracks ?? "none")
        check("no token said", !gitOps.matches.contains { "\($0.why) \($0.object?.sources.map(\.repoURL) ?? [])".contains("ghp_fake") })

        // Open on Page: the Application's detail; its history's entry a review in the checkout.
        if let app0 = match("Application", "acme-shop-dev") {
            gitOps.openOnPage(app0)
            check(
                "Open on Page opens its detail on the page",
                await eventually(20) { self.app.store.showingOverlay == .kubernetes && page.detail?.ref.name == "acme-shop-dev" && page.detail?.gitOps != nil },
                "\(String(describing: page.detail?.ref))")
            if let detail = page.detail?.gitOps {
                check("Diff in the checkout drawn on its history", await shownText(15) { $0.contains("Diff in ot-kube-shop-gitops") } != nil)
                let checkout = await page.historyCheckout(detail)
                check("the history's checkout is the window's", checkout?.root.standardizedFileURL.path == repo.standardizedFileURL.path, "\(String(describing: checkout))")
                if let checkout {
                    page.reviewHistory(detail, entry: 0, in: checkout)
                    let expected = ReviewSource.paths(base: fixture.c1, head: c3, paths: ["deploy/fake-dev"])
                    check(
                        "its entry opens a review of the path between the two",
                        await eventually(10) { self.app.store.reviews.contains { $0.source == expected } }, "\(app.store.reviews.map(\.source))")
                    if let review = app.store.reviews.first(where: { $0.source == expected }) { app.closeReview(review) }
                }
            }
            page.closeDetail()
            if app.store.showingOverlay == .kubernetes { app.toggleKubernetesPage(nil) }
            app.showKubernetesPanel(nil)
        }

        // 2. Reconcile from the rail: the page's sheet, then one merge patch; said in the rail.
        _ = await eventually(15) { match("Kustomization", "acme-apps")?.object != nil }
        if let apps = match("Kustomization", "acme-apps") {
            page.writeStatus = nil
            let before = fake.writes.count
            gitOps.reconcile(apps)
            check("Reconcile asks in the window", await eventually(15) { self.window.attachedSheet != nil }, "\(String(describing: gitOps.status))")
            let sheet = sheetTexts().joined(separator: "\n")
            check("naming the context and namespace", sheet.contains("kind-fake · namespace flux-system"), sheet)
            check("and the flux command", sheet.contains("flux reconcile kustomization acme-apps --context kind-fake -n flux-system"), sheet)
            check("nothing sent while it asks", fake.writes.count == before)
            endSheet(.alertFirstButtonReturn)
            check(
                "confirmed: one merge patch",
                await eventually(10) {
                    fake.writes.dropFirst(before).contains {
                        $0.method == "PATCH" && $0.path == "/apis/kustomize.toolkit.fluxcd.io/v1/namespaces/flux-system/kustomizations/acme-apps"
                    }
                }, "\(fake.writes.suffix(3))")
            check(
                "its outcome said in the rail", await eventually(10) { gitOps.status.map { !$0.isWorking && !$0.isFailure } == true },
                "rail \(String(describing: gitOps.status)), page \(String(describing: page.writeStatus))")
            // Read off the screen line by line, the rail narrow: its first two words.
            let said = (gitOps.status?.text ?? "—").split(separator: " ").prefix(2).joined(separator: " ")
            check("and drawn", await shownText(15) { $0.contains(said) } != nil, said)
        } else {
            check("Reconcile asks in the window", false, "no acme-apps")
        }

        // 3. On production: nothing listed across the cluster until asked.
        panel.unbind()
        _ = await eventually(5) { fake.openWatches == 0 }
        fake.forgetRequests()
        check("bound to fake-prod/shop", panel.bind(KubeBinding(checkout: real, context: "fake-prod", namespace: "shop", selector: "app.kubernetes.io/part-of=ot-shop")))
        check("the owner still found, by its GET", await eventually(20) { match("Kustomization", "acme-apps") != nil }, "\(gitOps.state)")
        check("Find What Deploys This offered", await eventually(10) { if case .waiting = gitOps.state { true } else { false } }, "\(gitOps.state)")
        check("drawn", await shownText(15) { $0.contains("Find What Deploys This") } != nil)
        await pause(0.5)
        check("nothing listed across the cluster before it is pressed", lists().isEmpty, "\(lists().map(\.path))")
        check("no GitRepository rows across the cluster before it is pressed", !listedGitRepositories())
        gitOps.find()
        check("pressed, it lists and finds acme-cron", await eventually(20) { match("Kustomization", "acme-cron") != nil }, "\(gitOps.state)")
        check("by lists across the cluster", !lists().isEmpty)
        check("GitRepositories' rows among them", listedGitRepositories())

        // 4. Has this branch reached the cluster: the attempt as the fixture has it.
        let ks = "kustomizations.kustomize.toolkit.fluxcd.io"
        func setRevisions(_ name: String, applied: String, attempted: String) {
            fake.setFluxStatus(ks, name) { status in
                status["lastAppliedRevision"] = "main@sha1:\(applied)"
                status["lastAttemptedRevision"] = "main@sha1:\(attempted)"
            }
        }
        func setArtifact(_ revision: String) {
            fake.setFluxStatus("gitrepositories.source.toolkit.fluxcd.io", "acme-fleet") { status in
                status["artifact"] = ["revision": "main@sha1:\(revision)", "lastUpdateTime": FakeKubeAPI.time(Date().addingTimeInterval(-600))]
            }
        }
        defer {
            let c = FakeKubeAPI.GitOpsCommit.self
            setRevisions("acme-apps", applied: c.applied, attempted: c.applied)
            setRevisions("acme-cron", applied: c.applied, attempted: c.attempted)
            setArtifact(c.applied)
        }
        panel.unbind()
        _ = await eventually(5) { fake.openWatches == 0 }
        KubeGitOpsMatchCache.shared.dropAll()
        check("bound to kind-fake/shop again", panel.bind(KubeBinding(checkout: real, context: "kind-fake", namespace: "shop", selector: "app.kubernetes.io/part-of=ot-shop")))
        check("acme-cron's attempt", await eventually(20) { match("Kustomization", "acme-cron")?.reach?.attempted != nil }, "\(gitOps.state)")
        let attempt = match("Kustomization", "acme-cron")?.reach?.attempted ?? "none"
        check(
            "c03f9aa failed; a77b0d1 still applied",
            attempt.hasPrefix("Flux tried c03f9aa and failed: BuildFailed") && attempt.hasSuffix("; a77b0d1 is still applied"), attempt)
        check("no Secret quoted", !attempt.contains(FakeKubeAPI.gitOpsSentinel), attempt)
        check(
            "its applied commit not in the checkout: fetch to compare",
            match("Kustomization", "acme-cron")?.reach?.deployed.text == "manifests at a77b0d1, not in this checkout — fetch to compare",
            match("Kustomization", "acme-cron")?.reach?.deployed.text ?? "none")
        check("the attempt drawn", await shownText(15) { $0.contains("Flux tried c03f9aa") } != nil)

        // acme-apps applied at c1, its source holding the same; acme-cron tried HEAD (c3) —
        // set while unbound, so the rail reads them afresh (a source's change isn't followed).
        panel.unbind()
        _ = await eventually(5) { fake.openWatches == 0 }
        try? await fixture.git(["update-ref", "refs/remotes/origin/main", fixture.c1])
        setArtifact(fixture.c1)
        setRevisions("acme-apps", applied: fixture.c1, attempted: fixture.c1)
        setRevisions("acme-cron", applied: fixture.c1, attempted: c3)
        KubeGitOpsMatchCache.shared.dropAll()
        panel.bind(KubeBinding(checkout: real, context: "kind-fake", namespace: "shop", selector: "app.kubernetes.io/part-of=ot-shop"))
        let manifests = "manifests at \(fixture.short), up to date with origin/main; this branch is 2 commits ahead"
        check(
            "kubernetes.panel.gitops.deployed: manifests at c1, this branch ahead",
            await eventually(20) { match("Kustomization", "acme-apps")?.reach?.deployed.text == manifests },
            match("Kustomization", "acme-apps")?.reach?.deployed.text ?? "none")
        check(
            "from Flux's applied revision", match("Kustomization", "acme-apps")?.reach?.source == "from Flux's applied revision (Kustomization acme-apps, Ready)",
            match("Kustomization", "acme-apps")?.reach?.source ?? "none")
        check("the manifests line drawn", await shownText(15) { $0.contains("manifests at \(fixture.short)") } != nil)
        if let apps = match("Kustomization", "acme-apps") {
            gitOps.reviewDeployed(apps)
            let expected = ReviewSource.range(base: fixture.c1, head: "HEAD")
            check("Diff Deployed…Current opens a review tab", await eventually(10) { self.app.store.reviews.contains { $0.source == expected } }, "\(app.store.reviews.map(\.source))")
            if let review = app.store.reviews.first(where: { $0.source == expected }) { app.closeReview(review) }
            app.showKubernetesPanel(nil)
        }

        // 5. The files this branch changes, under the paths it names.
        let changed = match("Kustomization", "acme-apps")?.reach?.changed
        check(
            "the changed files name the paths checked", changed?.text == "1 file under deploy/fake-dev, k8s/api.yaml on this branch",
            changed?.text ?? "none")
        let changedDrawn = await railShows { $0.contains("1 file under deploy") }
        let read = changedDrawn ? "" : await ocrLines { $0.contains("under") || $0.contains("manifests") }
        check("the changed files drawn", changedDrawn, read)
        if let apps = match("Kustomization", "acme-apps") {
            gitOps.reviewChanged(apps)
            let expected = ReviewSource.paths(base: fixture.c1, head: c3, paths: ["deploy/fake-dev/kustomization.yaml"])
            check("they open a review of those files", await eventually(10) { self.app.store.reviews.contains { $0.source == expected } }, "\(app.store.reviews.map(\.source))")
            if let review = app.store.reviews.first(where: { $0.source == expected }) { app.closeReview(review) }
            app.showKubernetesPanel(nil)
        }
        let unchanged = "no change under deploy/fake-dev, k8s/api.yaml since \(c3.prefix(7)) on origin/main"
        check(
            "the Application: no change under its path since what is live",
            await eventually(15) { match("Application", "acme-shop-dev")?.reach?.unchanged == unchanged },
            match("Application", "acme-shop-dev")?.reach?.unchanged ?? "none")

        // 6. Ask Why from the rail: the commits from what is applied to what was tried.
        _ = await eventually(15) { match("Kustomization", "acme-cron")?.reach?.range != nil }
        if let cron = match("Kustomization", "acme-cron") {
            func sheet() -> AskAgentView? { (window.attachedSheet?.contentViewController as? NSHostingController<AskAgentView>)?.rootView }
            fake.forgetRequests()
            gitOps.askWhy(cron)
            check("Ask Why from the rail opens the sheet", await eventually(15) { self.window.attachedSheet != nil && sheet() != nil }, page.commandProblem ?? "")
            let ask = app.askAgent
            let commits = ask.parts.first { $0.title == "commits" }?.text ?? ""
            check("with the commits applied..tried", commits.contains("\(c3.prefix(7)) deploy fake-dev") && commits.contains("the fix"), commits)
            check("and the checkout's lines", ask.parts.contains { $0.title == "checkout" && $0.text.contains("this branch's HEAD") }, "\(ask.parts.map(\.title))")
            let prompt = await app.askAgentPrompt()
            check("scrubbed", !prompt.contains(FakeKubeAPI.gitOpsSentinel) && !prompt.contains("ghp_fake"), prompt)
            check("read with GETs alone", fake.requests.allSatisfy { $0.method == "GET" })
            let cancelled = sheet().map { $0.cancel() } != nil
            check("Cancel sends nothing", await eventually(3) { self.window.attachedSheet == nil } && cancelled && !ask.isOpen)
            if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        } else {
            check("Ask Why from the rail opens the sheet", false, "no acme-cron")
        }

        railScroll(to: 0)

        // Unbound, then hidden: nothing asked.
        panel.unbind()
        _ = await eventually(5) { fake.openWatches == 0 }
        fake.forgetRequests()
        await pause(1)
        check("unbound, the rail asks nothing", fake.requests.isEmpty, "\(fake.requests.map(\.path))")
        check("and shows no GitOps part", !gitOps.shows)
        panel.bind(KubeBinding(checkout: real, context: "kind-fake", namespace: "shop", selector: "app.kubernetes.io/part-of=ot-shop"))
        _ = await eventually(20) { match("Kustomization", "acme-apps") != nil }
        app.sidebarPanel.panel = .files
        check("hidden, its watches end", await eventually(5) { !panel.panelVisible && fake.openWatches == 0 }, "\(fake.openWatches) open")
        fake.forgetRequests()
        await pause(1.5)
        check("hidden, the rail asks nothing", fake.requests.isEmpty, "\(fake.requests.map(\.path))")
        check("no Secret, no ConfigMap", !fake.requests.contains { $0.path.contains("/secrets") || $0.path.contains("/configmaps") })
    }

    /// The rail's scroll views (the sidebar's, on the window's left), tallest content first.
    private func railScrolls() -> [NSScrollView] {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, let document = scroll.documentView, !scroll.isHidden,
                scroll.convert(scroll.bounds, to: nil).minX < 80, document.frame.height > scroll.contentView.bounds.height
            {
                found.append(scroll)
            }
            view.subviews.forEach(walk)
        }
        if let root = window.contentView?.superview { walk(root) }
        return found.sorted { ($0.documentView?.frame.height ?? 0) > ($1.documentView?.frame.height ?? 0) }
    }

    /// The rail scrolled to a fraction of its length (0 top, 1 end), in process.
    private func railScroll(to fraction: CGFloat) {
        for scroll in railScrolls() {
            guard let document = scroll.documentView else { continue }
            let clip = scroll.contentView.bounds.height
            let room = max(0, document.frame.height - clip)
            let y = document.isFlipped ? room * fraction : room * (1 - fraction)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// Whether the rail draws a line matching, scrolled down a step at a time as a person would read it.
    private func railShows(_ match: @escaping (String) -> Bool) async -> Bool {
        defer { railScroll(to: 0) }
        for step in 0...5 {
            railScroll(to: CGFloat(step) / 5)
            await pause(0.4)
            if await shownText(2, match) != nil { return true }
        }
        return false
    }

    /// What the window reads now, filtered: a failure's detail.
    private func ocrLines(_ keep: @escaping (String) -> Bool) async -> String {
        await readWindow().map(\.text).filter(keep).joined(separator: " | ")
    }
}
