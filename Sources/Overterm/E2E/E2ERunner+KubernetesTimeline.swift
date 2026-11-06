import AppKit
import Foundation

/// Stage 3b's change timeline check (docs/design/kubernetes/analysis.md,
/// 3.6, Section 9): a Deployment of `fake-dev` with three ReplicaSet
/// revisions (an image change, then a rollout restart), a Helm release
/// of two revisions, a scale event and a warning on its ReplicaSet. `h` opens its History
/// tab: one bounded list of its ReplicaSets by its selector, its events
/// and its release's records by their metadata — no record read —,
/// joined newest first and drawn. A revision's Diff opens in the changes
/// pane, the page stepping aside, its secret env value masked as
/// `*** (before)` / `*** (after)`; a Helm revision's reads its two records
/// then, values masked. Reads only.
extension E2ERunner {
    func kubernetesTimeline(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        let wasShowing = app.store.showingOverlay == .kubernetes
        if !wasShowing { app.toggleKubernetesPage(nil) }
        let diffWas = app.diffItem?.isCollapsed ?? true
        defer {
            if app.rightPane.mode == .manifest { app.rightPane.mode = .changes }
            if diffWas, app.diffItem?.isCollapsed == false { app.toggleDiff(nil) }
        }
        let oldPassword = "acme-e2e-timeline-pw-old-W2n"
        let newPassword = "acme-e2e-timeline-pw-new-P5k"
        let now = Date()
        fake.add(
            "deployments.apps", "hist", namespace: "shop", values: ["Ready": "2/2", "Up-to-date": 2, "Available": 2],
            annotations: [KubeTimeline.helmRelease: "hist", KubeTimeline.helmNamespace: "shop"],
            fields: ["spec": ["replicas": 2, "selector": ["matchLabels": ["app": "hist"]]], "status": ["replicas": 2, "readyReplicas": 2]])
        fake.addRevision(
            of: "hist", namespace: "shop", name: "hist-aaaa", revision: 1, image: "nginx:1.25", env: ["DB_PASSWORD": oldPassword], labels: ["app": "hist"],
            created: now.addingTimeInterval(-3 * 3600))
        fake.addRevision(
            of: "hist", namespace: "shop", name: "hist-bbbb", revision: 2, image: "nginx:1.27", env: ["DB_PASSWORD": newPassword], labels: ["app": "hist"],
            created: now.addingTimeInterval(-2 * 3600))
        fake.addRevision(
            of: "hist", namespace: "shop", name: "hist-cccc", revision: 3, image: "nginx:1.27", env: ["DB_PASSWORD": newPassword],
            restartedAt: FakeKubeAPI.time(now.addingTimeInterval(-3600)), labels: ["app": "hist"], created: now.addingTimeInterval(-3600))
        fake.addEvent(
            about: "deployments.apps", "hist", namespace: "shop", reason: "ScalingReplicaSet", message: "Scaled up replica set hist-cccc from 1 to 2",
            last: now.addingTimeInterval(-1800), component: "deployment-controller")
        // Recorded where a real cluster records it: on the ReplicaSet.
        fake.addEvent(
            about: "replicasets.apps", "hist-cccc", namespace: "shop", type: "Warning", reason: "FailedCreate",
            message: "Error creating: pods \"hist-cccc-w8r2n\" is forbidden: exceeded quota: compute", last: now.addingTimeInterval(-600),
            component: "replicaset-controller")
        fake.addHelmRelease(
            "hist", namespace: "shop", revision: 1, status: "superseded", config: ["auth": ["password": oldPassword]], modified: now.addingTimeInterval(-3 * 3600 - 60))
        fake.addHelmRelease("hist", namespace: "shop", revision: 2, config: ["auth": ["password": newPassword]], modified: now.addingTimeInterval(-2 * 3600 - 60))
        if model.selectedName != "fake-dev" { model.select("fake-dev") }
        model.setScope(.namespace("shop"))
        page.filter = ""
        page.applySelector()
        guard await eventually(15, { model.discovery?.kind("deployments") != nil }), let deployments = model.discovery?.kind("deployments") else {
            return check("fake-dev serves Deployments", false)
        }
        page.closeDetail()
        page.showKind(deployments)
        check(
            "the Deployments of fake-dev's shop",
            await eventually(15) { model.kind.fullName == "deployments.apps" && model.rows[KubeRowID(namespace: "shop", name: "hist")] != nil })
        fake.forgetRequests()
        page.giveListTheKeyboard()
        page.selection = ["shop/hist"]
        check(
            "h on a Deployment is its History, by the window's key path",
            await pressKubernetesKey("h", keyCode: 4) && page.detailTab == .history && page.detail?.ref.name == "hist")
        guard let timeline = page.detail?.timeline else { return check("its timeline", false) }
        check("read", await eventually(15) { timeline.state == .loaded }, "\(timeline.state)")
        check("nothing it couldn't read", timeline.notes.isEmpty, "\(timeline.notes)")
        let kinds = timeline.entries.map(\.kind)
        check(
            "newest first: the warning, the scaling, the restart, the image change, Helm's revisions",
            kinds == [.warning, .scale, .restart, .revision, .helm, .revision, .helm], "\(kinds) \(timeline.entries.map(\.title))")
        check("the image change said", timeline.entries.contains { $0.detail?.hasPrefix("app: nginx:1.25 → nginx:1.27") == true })
        check("the warning its ReplicaSet's", timeline.entries.first?.detail?.hasPrefix("replicaset/hist-cccc: ") == true, timeline.entries.first?.detail ?? "none")
        let lists = fake.requests.filter { $0.path == "/apis/apps/v1/namespaces/shop/replicasets" }
        check(
            "one list of its ReplicaSets, by its selector, bounded",
            lists.count == 1 && lists.first?.query["labelSelector"] == "app=hist" && lists.first?.query["limit"] == String(KubeTimeline.revisionLimit),
            "\(lists.map(\.query))")
        check(
            "its release's records by their metadata",
            fake.requests.contains { $0.path == "/api/v1/namespaces/shop/secrets" && $0.accept == KubeClient.metadataListAccept && $0.query["labelSelector"] == "owner=helm,name=hist" })
        check("no record read for the timeline", !fake.requests.contains { $0.path.contains("/secrets/") })
        check("drawn", await shownText(15) { $0.contains("Restarted: revision 3") } != nil)

        // A revision's Diff: the changes pane, the page stepping aside.
        fake.forgetRequests()
        page.openChange(.template(from: 1, to: 2))
        check(
            "the revision's diff in the changes pane",
            await eventually(10) { app.rightPane.mode == .manifest && app.kubernetesManifest.shown == .change && app.kubernetesManifest.change?.title == "deployment/hist: revision 1 → 2" },
            app.kubernetesManifest.change?.title ?? "none")
        check("the page steps aside", app.store.showingOverlay == nil)
        check("made from what was read", fake.requests.isEmpty, "\(fake.requests)")
        let text = app.kubernetesManifest.change?.diff.items.map(\.diff).joined() ?? ""
        let lines = text.split(separator: "\n")
        check(
            "the image changed",
            lines.contains { $0.hasPrefix("-") && $0.contains("image: nginx:1.25") } && lines.contains { $0.hasPrefix("+") && $0.contains("image: nginx:1.27") }, text)
        check("the secret env value masked, said changed", text.contains("(before)") && text.contains("(after)"))
        check("and never itself", !text.contains(oldPassword) && !text.contains(newPassword))
        check("drawn", await shownText(15) { $0.contains("deployment/hist: revision 1") } != nil)

        // A Helm revision's: its two records read now, masked.
        app.toggleKubernetesPage(nil)
        page.openChange(.helm(from: 1, to: 2))
        check(
            "the Helm revisions' diff", await eventually(15) { app.kubernetesManifest.change?.title == "Helm hist: revision 1 → 2" },
            timeline.diffProblem ?? app.kubernetesManifest.change?.title ?? "none")
        check(
            "its two records read for it",
            Set(fake.requests.filter { $0.path.contains("/secrets/") }.map(\.path)) == [
                "/api/v1/namespaces/shop/secrets/sh.helm.release.v1.hist.v1", "/api/v1/namespaces/shop/secrets/sh.helm.release.v1.hist.v2",
            ])
        let helm = app.kubernetesManifest.change?.diff.items.map(\.diff).joined() ?? ""
        check("its values masked", helm.contains("password: \"*** (before)\"") && !helm.contains(oldPassword) && !helm.contains(newPassword), helm)
        check("drawn", await shownText(15) { $0.contains("Helm hist: revision 1") } != nil)
        check("reads only", fake.writes.isEmpty, "\(fake.writes)")

        if app.store.showingOverlay != .kubernetes { app.toggleKubernetesPage(nil) }
        page.closeDetail()
        page.showKind(.pods)
        if !wasShowing { app.toggleKubernetesPage(nil) }
    }
}
