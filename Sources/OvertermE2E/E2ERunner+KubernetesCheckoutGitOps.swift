#if E2E
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
///    A Deployment beside it carrying a copied mark — an operator's
///    resource's tracking id, not its own (D0, gitops.md 14.1) — names no
///    owner, read by the same list.
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
/// 7. (G7, gitops.md 6.1) The agent in the checkout's tab: `k8s_gitops`
///    with `checkout: true` answers what the rail found, from its listing
///    — a line each, the deployed sentence, no token or sentinel; another
///    context refused; bound to fake-prod before the press, it lists
///    nothing across the cluster and says to press Find What Deploys This.
///
/// Unbound and hidden, the rail asks nothing. Every write lands on the
/// fake; every sheet is ended by the runner. The rail on a spoke, where
/// Argo CD's apps are read from their marks (D5, gitops.md 14.9.3's part
/// 7), needs the spoke `kubernetesGitOpsMarks` serves: it runs there
/// (`kubernetesCheckoutGitOpsMarks`, below).
extension E2ERunner {
    package func kubernetesCheckoutGitOps(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
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
        // An operator's Deployment, its custom resource's mark copied onto it: nobody's.
        fake.add(
            "deployments.apps", "shop-orders-proxy", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1],
            labels: ["app.kubernetes.io/part-of": "ot-shop"],
            annotations: ["argocd.argoproj.io/tracking-id": "prod-shop-orders-service:acme.example.com/Database:shop/orders"])
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
            fake.delete("deployments.apps", "shop-orders-proxy", namespace: "shop")
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
        // The same Deployments list carried shop-orders-proxy: its copied mark is no Application's.
        check(
            "a copied mark names nobody", !gitOps.matches.contains { $0.key.name == "prod-shop-orders-service" || $0.why.contains("prod-shop-orders-service") },
            "\(gitOps.matches.map { "\($0.id): \($0.why)" })")
        check(
            "the owner found by one GET",
            fake.requests.filter { $0.path == "/apis/kustomize.toolkit.fluxcd.io/v1/namespaces/flux-system/kustomizations/acme-apps" }.count >= 1)
        check(
            "the workloads' rows carry their marks in the binding's namespace only",
            fake.requests.contains { $0.path == "/apis/apps/v1/namespaces/shop/deployments" && $0.query["includeObject"] == "Metadata" })
        // Each object's match is its own read: waited for, not taken as acme-apps' came.
        check(
            "acme-cron's path is not on this branch", await eventually(20) { match("Kustomization", "acme-cron")?.why == "path apps/cron is not on this branch" },
            match("Kustomization", "acme-cron")?.why ?? "none")
        check(
            "an Application of the path, in argocd", await eventually(20) { match("Application", "acme-shop-dev")?.why == "deploy/fake-dev" },
            match("Application", "acme-shop-dev")?.why ?? "none")
        // Where the rail has it, as a person scrolls to it; wrapped where its width says.
        check("the part drawn", await railShowsPhrase("owns Deployment/shop-api"))
        check("with what it tracks", match("Kustomization", "acme-apps")?.tracks == "tracks main; this branch is fix/orders", match("Kustomization", "acme-apps")?.tracks ?? "none")
        check("no token said", !gitOps.matches.contains { "\($0.why) \($0.object?.sources.map(\.repoURL) ?? [])".contains("ghp_fake") })

        // 7. The agent in the checkout's tab asks the same.
        let pane = tab.terminal.processTag
        func agent(_ arguments: [String: Any]) async -> (text: String, error: Bool) {
            do {
                let result = try await KubeMCP.call("k8s_gitops", arguments, kubernetes: model, pane: pane)
                return (((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "", result["isError"] as? Bool == true)
            } catch let error as BrowserMCP.ToolError {
                return (error.message, true)
            } catch {
                return ("\(error)", true)
            }
        }
        let writesBefore = fake.writes.count
        let asked = await agent(["checkout": true])
        let flat = asked.text.replacingOccurrences(of: "\n", with: " | ")
        check("k8s_gitops checkout answers on the binding", !asked.error && asked.text.contains("bound to kind-fake/shop"), flat)
        check(
            "the rail's match, a line each",
            asked.text.contains("Kustomization flux-system/acme-apps  Ready") && asked.text.contains("matched: owns Deployment/shop-api · deploy/fake-dev"), flat)
        check("from the rail's listing", asked.text.contains("as the rail read them in the last five minutes"), flat)
        check("acme-cron's attempt said", asked.text.contains("Flux tried c03f9aa"), flat)
        check("no token, no sentinel", !asked.text.contains("ghp_fake") && !asked.text.contains(FakeKubeAPI.gitOpsSentinel), flat)
        let elsewhere = await agent(["checkout": true, "context": "fake-dev"])
        check("another context refused", elsewhere.error && elsewhere.text.contains("only on the checkout's own context, kind-fake"), elsewhere.text)
        check("nothing written by the agent", fake.writes.count == writesBefore, "\(fake.writes.suffix(3))")

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
            // The access review before the sheet is a POST but no write: kept a
            // minute, it is asked again here when the run is slow.
            let sent = fake.writes.dropFirst(before).filter { !$0.isAccessReview }
            check("nothing sent while it asks", sent.isEmpty, "\(sent)")
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
        let prod = await agent(["checkout": true])
        check(
            "the agent on fake-prod: the owners only, press Find What Deploys This",
            !prod.error && prod.text.contains("On fake-prod only the owners of the bound workloads were read")
                && prod.text.contains("Kustomization flux-system/acme-apps"), prod.text.replacingOccurrences(of: "\n", with: " | "))
        check("and it listed nothing across the cluster", lists().isEmpty && !listedGitRepositories(), "\(lists().map(\.path))")
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
        check("the manifests line drawn", await railShowsPhrase("manifests at \(fixture.short)"))
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
        check(
            "unbound, the rail asks only for the namespace's warnings", fake.requests.allSatisfy { $0.path.hasSuffix("/namespaces/shop/events") },
            "\(fake.requests.map(\.path))")
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

    /// D5 (gitops.md 14.2.5, 14.9.3: the design's checkout part 7), on the
    /// marks scenario's spoke, where Argo CD's Applications aren't served
    /// (`kubernetesGitOpsMarksScenario` runs it last): a checkout bound to
    /// team-3 shows its app read from the bound Deployment's marks — Paused
    /// by its object's GET, though its cells read 2/2 — and the "another
    /// cluster" sentence; bound to team-1's Deployment its Argo Rollout
    /// scales to 0, its app is Failed by the Rollout's phase (the
    /// namespace's Rollouts listed once, the Rollout's GET in place of the
    /// Deployment's); Open shows the paused app's detail on the page; then
    /// fake-dev classed production, a config repository whose committed
    /// manifest names team-5's acme-search is matched by option B only once
    /// Find What Deploys This was pressed — "describes", never "owns" — and
    /// nothing is listed across the cluster before; and the checkout of a
    /// service deployed into three namespaces, bound in one, says that
    /// one's app "probably" and only counts the other two. Each part's reads
    /// checked against the fake's log, and nothing the rail keeps or draws
    /// holds the sentinel its objects carry; nothing written.
    package func kubernetesCheckoutGitOpsMarks(_ model: KubernetesModel, _ page: KubernetesPageModel, _ spoke: FakeKubeAPI, made: FakeKubeAPI.Spoke) async {
        let panel = app.kubernetesPanel
        let gitOps = panel.gitOps
        Settings.shared.set("kubernetes.notifyOnFailure", .bool(false))
        defer { Settings.shared.set("kubernetes.notifyOnFailure", nil) }
        if app.store.showingOverlay != nil { app.hideOverlay(focus: false) }
        KubeGitOpsMatchCache.shared.dropAll()
        func marked(_ instance: String) -> KubePanelGitOps.Match? { gitOps.matches.first { $0.marked?.app.key.instance == instance } }
        /// The workloads' rows across the cluster: option B's list.
        func listedAcross() -> [FakeKubeAPI.Request] {
            spoke.requests.filter { request in
                !request.isWatch && ["/apis/apps/v1/deployments", "/apis/apps/v1/statefulsets", "/apis/apps/v1/daemonsets", "/apis/argoproj.io/v1alpha1/rollouts"].contains(request.path)
            }
        }
        /// What the rail may read: its bound namespace's rows, one object's GET there, option B's rows, discovery.
        func checkReads(_ part: String, bound namespace: String) {
            let requests = spoke.requests.filter { !$0.isDiscovery }
            // The page's own (its namespace picker, the CRDs it follows) aside.
            let outside = requests.filter { request in
                !request.path.contains("/namespaces/\(namespace)/") && !listedAcross().contains(request) && request.path != "/api/v1/namespaces"
                    && !request.path.hasSuffix("/customresourcedefinitions")
            }
            check("\(part): only the bound namespace, one object's GET there, and the workloads' marks across the cluster", outside.isEmpty, "\(outside.map(\.path))")
            check("\(part): GETs only", requests.allSatisfy { $0.method == "GET" })
            check("\(part): never a Secret, a ConfigMap or an Application", !requests.contains { $0.path.contains("/secrets") || $0.path.contains("/configmaps") || $0.path.contains("/applications") })
            check("\(part): the marks' rows never watched, never whole", listedAcross().allSatisfy { $0.query["includeObject"] == "Metadata" })
        }

        // The app repository: its tab, the rail on its panel, bound to team-3's paused Deployment.
        guard let fixture = await E2EKubeCheckoutFixture.make(in: scratch, name: "ot-kube-spoke-batch") else {
            return check("the spoke's checkout is made", false)
        }
        _ = try? await fixture.git(["remote", "add", "origin", "git@git.acme.example:acme/acme-batch.git"])
        let previous = app.store.selected
        app.newTab(in: fixture.repo)
        guard let tab = app.store.selected else { return check("the spoke checkout's tab opens", false) }
        defer {
            app.closeTabsWithoutAsking([tab])
            if let previous { app.store.select(previous) }
        }
        let real = FileTreeModel.realPath(fixture.repo)
        check("the panel follows it", await eventually(10) { panel.checkout.map(FileTreeModel.realPath) == real })
        app.showKubernetesPanel(nil)
        defer {
            panel.unbind()
            app.sidebarPanel.panel = .files
        }
        spoke.forgetRequests()
        let team = "team-3"
        check("bound to fake-dev/team-3", panel.bind(KubeBinding(checkout: real, context: "fake-dev", namespace: team, selector: "app=acme-batch")))
        check(
            "its app read from the bound Deployment's marks, Paused by its object",
            await eventually(20) { marked(made.paused)?.marked?.health.state == .paused }, "\(gitOps.state) \(gitOps.matches.map { "\($0.said): \($0.why)" })")
        let paused = marked(made.paused)
        check("rollout paused, though its cells read 2/2", paused?.marked?.health.why == "rollout paused · Deployment acme-batch", paused?.marked?.health.why ?? "none")
        check("it owns the bound Deployment", paused?.whys.first == .owns([KubeWorkloadRef(kind: .deployment, name: "acme-batch")]), paused?.why ?? "none")
        check(
            "where Argo CD runs", paused?.marked?.place.said(context: "fake-dev") == "Argo CD runs in another cluster — not in your kubeconfig",
            paused?.marked?.place.said(context: "fake-dev") ?? "none")
        check("the part's line", gitOps.marksLine == "Argo CD isn't in fake-dev; read from the marks on team-3's workloads", gitOps.marksLine ?? "none")
        check("A found it: nothing by name", !gitOps.matches.contains { $0.marked?.probable == true } && gitOps.marksSaid.tooMany == nil)
        check("the one GET of it", spoke.requests.contains { $0.path == "/apis/apps/v1/namespaces/team-3/deployments/acme-batch" && !$0.isWatch })
        check("its app drawn, by its name", await railShows { $0.contains("team-3-acme") || $0.contains("acme-batch-service") })
        check("Paused, by its object", await railShowsPhrase("Paused: rollout paused"))
        check("in another cluster", await railShowsPhrase("Argo CD runs in another cluster"))
        check("whose health", await railShowsPhrase("health of the 1 object bound here"))
        // The settle's GET read an object whose env, args and last-applied copy carry the sentinel.
        check("nothing the rail keeps holds the sentinel", !railKept(gitOps).contains(FakeKubeAPI.gitOpsSentinel))
        check("nothing the rail draws holds the sentinel", await railNeverShows { $0.contains(FakeKubeAPI.gitOpsSentinel) })
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
            app.captureWindow(to: png.replacingOccurrences(of: ".png", with: "-kube-rail-marks.png"))
        }
        // Off production, option B listed at once: the app repository's manifest names nothing marked.
        check("off production, the marks listed across the cluster", await eventually(15) { !listedAcross().isEmpty })
        checkReads("bound to team-3", bound: team)
        check("no GitOps verb on it", gitOps.ref(paused ?? KubePanelGitOps.Match(key: .init(kind: "Marks", namespace: nil, name: ""), whys: [])) == nil)
        // Ask Why on it (D6, gitops.md 14.2.6): Paused isn't Ready — the brief with the rail's own words.
        if let paused {
            func sheet() -> AskAgentView? { (window.attachedSheet?.contentViewController as? NSHostingController<AskAgentView>)?.rootView }
            check("Ask Why offered on it", paused.asksWhy)
            check("its button drawn", await railShows { $0.contains("Ask Why") })
            spoke.forgetRequests()
            gitOps.askWhy(paused)
            check("Ask Why from the rail opens the sheet", await eventually(15) { self.window.attachedSheet != nil && sheet() != nil }, page.commandProblem ?? "")
            let ask = app.askAgent
            check(
                "its question, in Argo CD's word", ask.message == "Why is Argo CD app \(made.paused) Suspended — rollout paused, Deployment acme-batch?", ask.message)
            let prompt = await app.askAgentPrompt()
            check("whose health the rail says", prompt.contains("health of the 1 object bound here"), prompt)
            check("where its Application stands, the rail's words", prompt.contains("Argo CD runs in another cluster — not in your kubeconfig."), prompt)
            check("scrubbed", !prompt.contains(FakeKubeAPI.gitOpsSentinel))
            check("read with GETs alone", spoke.requests.allSatisfy { $0.method == "GET" } && spoke.writes.isEmpty)
            let cancelled = sheet().map { $0.cancel() } != nil
            check("Cancel sends nothing", await eventually(3) { self.window.attachedSheet == nil } && cancelled && !ask.isOpen)
            if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        }

        // Bound to a Deployment its Argo Rollout scales to 0 (14.12's second
        // consequence): its app's health is its Rollout's phase, never a scaled-down app.
        spoke.forgetRequests()
        check("rebound to team-1's Rollout-run Deployment", panel.bind(KubeBinding(checkout: real, context: "fake-dev", namespace: "team-1", selector: "app=acme-blue")))
        check(
            "its app's health its Rollout's phase", await eventually(20) { marked(made.rolloutDegraded)?.marked?.health.state == .failed },
            "\(gitOps.matches.map { "\($0.said): \($0.marked?.health.word ?? "") \($0.marked?.health.why ?? "")" })")
        let blue = marked(made.rolloutDegraded)?.marked
        check("rollout degraded, by its Rollout", blue?.health.why == "rollout degraded · Rollout acme-blue", blue?.health.why ?? "none")
        let scaled = blue.flatMap { app in app.app.members.first { $0.id.kind == .deployment }.flatMap { KubeMarkedHealth.member($0, in: app.app) } }
        check("the Deployment scaled by its Rollout", scaled?.sentence == KubeMarkedHealth.scaledByRollout, scaled?.sentence ?? "none")
        check("drawn: Failed by its Rollout", await railShowsPhrase("rollout degraded"))
        check("drawn: whose health", await railShowsPhrase("with its app's Argo Rollout"))
        let teamRollouts = "/apis/argoproj.io/v1alpha1/namespaces/team-1/rollouts"
        check(
            "the namespace's Rollouts listed once as rows, never watched",
            spoke.requests.filter { $0.path == teamRollouts && $0.query["includeObject"] == "Metadata" }.count == 1
                && !spoke.requests.contains { $0.isWatch && $0.path.contains("/rollouts") })
        check(
            "the Rollout's GET, none of the Deployment it scales",
            spoke.requests.contains { $0.path == teamRollouts + "/acme-blue" } && !spoke.requests.contains { $0.path == "/apis/apps/v1/namespaces/team-1/deployments/acme-blue" })
        check("nothing it keeps holds the sentinel", !railKept(gitOps).contains(FakeKubeAPI.gitOpsSentinel))
        checkReads("bound to team-1", bound: "team-1")

        // Open: its detail on the page, the section reading it.
        if let paused {
            gitOps.openMarked(paused)
            check(
                "Open shows its detail on the page",
                await eventually(20) { self.app.store.showingOverlay == .kubernetes && page.section == .gitops && page.markedDetail?.key.instance == made.paused },
                "\(String(describing: page.markedDetail))")
            check("read, its tree drawn", await eventually(30) { page.markedDetailShown?.title.contains(made.paused) == true }, page.markedDetailShown?.title ?? "none")
            page.closeMarkedApp()
            if app.store.showingOverlay == .kubernetes { app.toggleKubernetesPage(nil) }
            app.showKubernetesPanel(nil)
        }

        // The config repository on a production-classed spoke: option B only once pressed.
        panel.unbind()
        _ = await eventually(5) { spoke.openWatches == 0 }
        let settingsBefore = Settings.shared.fileValue("kubernetes.contexts")
        Settings.shared.set("kubernetes.contexts", Self.kubeContexts(["fake-dev": ["class": .string("production")]]))
        defer {
            Settings.shared.set("kubernetes.contexts", settingsBefore)
            KubeGitOpsMatchCache.shared.dropAll()
        }
        check("fake-dev classed production", await eventually(10) { model.contexts.context(named: "fake-dev")?.isProduction == true })
        guard let fleet = await E2EKubeCheckoutFixture.make(in: scratch, name: "ot-kube-spoke-fleet") else { return check("the config checkout is made", false) }
        _ = try? await fleet.git(["remote", "add", "origin", "git@git.acme.example:acme/fleet.git"])
        let manifest = "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: acme-search\n  namespace: team-5\n"
        try? FileManager.default.createDirectory(at: fleet.repo.appendingPathComponent("apps/acme-search"), withIntermediateDirectories: true)
        try? manifest.write(to: fleet.repo.appendingPathComponent("apps/acme-search/deployment.yaml"), atomically: true, encoding: .utf8)
        _ = try? await fleet.git(["add", "apps"])
        _ = try? await fleet.git(["commit", "-q", "-m", "acme-search"])
        app.newTab(in: fleet.repo)
        guard let fleetTab = app.store.selected else { return check("the config checkout's tab opens", false) }
        defer { app.closeTabsWithoutAsking([fleetTab]) }
        let fleetReal = FileTreeModel.realPath(fleet.repo)
        check("the panel follows the config checkout", await eventually(10) { panel.checkout.map(FileTreeModel.realPath) == fleetReal })
        app.showKubernetesPanel(nil)
        spoke.forgetRequests()
        check(
            "bound to fake-dev/team-0, its Helm-installed agent",
            panel.bind(KubeBinding(checkout: fleetReal, context: "fake-dev", namespace: "team-0", selector: "app=fake-metrics-agent")))
        check(
            "Find What Deploys This offered, naming what it lists", await eventually(20) { if case .waiting(let reads) = gitOps.state { reads.contains("with Argo CD's marks") } else { false } },
            "\(gitOps.state)")
        check("drawn", await shownText(15) { $0.contains("Find What Deploys This") } != nil)
        await pause(0.5)
        check("nothing listed across the cluster before it is pressed", listedAcross().isEmpty, "\(listedAcross().map(\.path))")
        check("and nothing matched", marked(made.hpa) == nil)
        gitOps.find()
        check("pressed: option B finds the app its manifest names", await eventually(20) { marked(made.hpa) != nil }, "\(gitOps.state) \(gitOps.matches.map(\.said))")
        let search = marked(made.hpa)
        check("it describes its object, never owns it", search?.whys == [.describes(1, of: 1)] && search?.why.contains("owns") == false, search?.why ?? "none")
        check("listed across the cluster once pressed", !listedAcross().isEmpty)
        check("described, drawn", await railShowsPhrase("describe 1 of its 1 object"))
        check(
            "read from the marks on the cluster's workloads, not the bound namespace's",
            gitOps.marksLine == "Argo CD isn't in fake-dev; read from the marks on the cluster's workloads", gitOps.marksLine ?? "none")
        // Option B's rows across the cluster carry kubectl's last-applied copy, the sentinel in it.
        check("nothing kept of B's rows holds the sentinel", !railKept(gitOps).contains(FakeKubeAPI.gitOpsSentinel))
        check("nothing drawn of them holds it", await railNeverShows { $0.contains(FakeKubeAPI.gitOpsSentinel) })
        checkReads("the config checkout", bound: "team-0")
        check("nothing written", spoke.writes.isEmpty, "\(spoke.writes.map(\.description))")

        // A service deployed into three namespaces and named after its checkout (option C; gitops.md
        // 14.9.4: apps with a Deployment sharing a name, never two in one namespace): bound in one, its
        // app said "probably", the two elsewhere only counted — never listed, never "too many to tell".
        let relaySpaces = ["team-0", "team-1", "team-2"]
        for namespace in relaySpaces {
            spoke.addMarkedDeployment("acme-relay", namespace: namespace, app: "prod-\(namespace)-acme-relay-service", padding: 0, now: Date(), replicaSet: false)
        }
        defer { for namespace in relaySpaces { spoke.delete("deployments.apps", "acme-relay", namespace: namespace) } }
        guard let relay = await E2EKubeCheckoutFixture.make(in: scratch, name: "ot-kube-spoke-relay") else { return check("the relay checkout is made", false) }
        _ = try? await relay.git(["remote", "add", "origin", "git@git.acme.example:acme/acme-relay.git"])
        app.newTab(in: relay.repo)
        guard let relayTab = app.store.selected else { return check("the relay checkout's tab opens", false) }
        defer { app.closeTabsWithoutAsking([relayTab]) }
        let relayReal = FileTreeModel.realPath(relay.repo)
        check("the panel follows the relay checkout", await eventually(10) { panel.checkout.map(FileTreeModel.realPath) == relayReal })
        app.showKubernetesPanel(nil)
        spoke.forgetRequests()
        check(
            "the relay checkout bound to fake-dev/team-0, its Helm-installed agent",
            panel.bind(KubeBinding(checkout: relayReal, context: "fake-dev", namespace: "team-0", selector: "app=fake-metrics-agent")))
        check("Find What Deploys This offered for it", await eventually(20) { if case .waiting = gitOps.state { true } else { false } }, "\(gitOps.state)")
        gitOps.find()
        let relayed = "prod-team-0-acme-relay-service"
        check(
            "by name: the bound namespace's app, probably", await eventually(20) { marked(relayed)?.marked?.probable == true && gitOps.marksSaid.elsewhere != nil },
            "\(gitOps.state) \(gitOps.matches.map(\.said))")
        check(
            "the two elsewhere never listed", marked("prod-team-1-acme-relay-service") == nil && marked("prod-team-2-acme-relay-service") == nil,
            "\(gitOps.matches.map(\.said))")
        check(
            "only counted, never too many to tell",
            gitOps.marksSaid.elsewhere == "2 more by name or image in other namespaces: team-1, team-2" && gitOps.marksSaid.tooMany == nil,
            gitOps.marksSaid.elsewhere ?? "none")
        check("its app drawn, probably", await railShowsPhrase("May deploy this checkout (by name)"))
        check("the count drawn", await railShowsPhrase("2 more by name or image in other namespaces"))
        checkReads("the relay checkout", bound: "team-0")
        railScroll(to: 0)
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
    private func railShows(file: StaticString = #fileID, line: UInt = #line, _ match: @escaping (String) -> Bool) async -> Bool {
        defer { railScroll(to: 0) }
        for step in 0...5 {
            railScroll(to: CGFloat(step) / 5)
            await pause(0.4)
            if await shownText(2, file: file, line: line, match) != nil { return true }
        }
        return false
    }

    /// Whether no line the rail draws matches, read at each step as a person
    /// scrolls it down.
    private func railNeverShows(_ match: @escaping (String) -> Bool) async -> Bool {
        defer { railScroll(to: 0) }
        for step in 0...5 {
            railScroll(to: CGFloat(step) / 5)
            await pause(0.4)
            if await readWindow().contains(where: { match($0.text) }) { return false }
        }
        return true
    }

    /// Everything the rail's GitOps part keeps and says, as text.
    private func railKept(_ gitOps: KubePanelGitOps) -> String {
        String(describing: gitOps.matches) + String(describing: gitOps.marksSaid) + (gitOps.marksLine ?? "") + gitOps.problems.joined()
            + gitOps.searched.joined()
    }

    /// Whether the rail draws `phrase`, on a line or wrapped onto the next,
    /// scrolled down a step at a time as a person would read it.
    private func railShowsPhrase(_ phrase: String, file: StaticString = #fileID, line: UInt = #line) async -> Bool {
        defer { railScroll(to: 0) }
        for step in 0...5 {
            railScroll(to: CGFloat(step) / 5)
            await pause(0.4)
            if await shownPhrase(phrase, 2, file: file, line: line) { return true }
        }
        return false
    }

    /// What the window reads now, filtered: a failure's detail.
    private func ocrLines(_ keep: @escaping (String) -> Bool) async -> String {
        await readWindow().map(\.text).filter(keep).joined(separator: " | ")
    }
}
#endif
