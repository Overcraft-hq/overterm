import AppKit
import Foundation

/// Stage 2e's check (docs/design/kubernetes/analysis.md, Section 9): a
/// Deployment's logs as one on `fake-dev` — `l` on it opens its Logs tab,
/// its two pods' streams merged on their timestamps, each line prefixed
/// with its pod and container, drawn; the cap (`kubernetes.logStreams`,
/// 2 here) stated, a third pod joining from the watch left out, then
/// followed once a pod it follows goes, that pod's stream closed; a pod
/// left out by an expression closed too; hidden, nothing open and nothing
/// asked. Reads only.
extension E2ERunner {
    func kubernetesMergedLogs(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        let wasShowing = app.store.showingOverlay == .kubernetes
        if !wasShowing { app.toggleKubernetesPage(nil) }
        Settings.shared.set("kubernetes.logStreams", .int(2))
        defer { Settings.shared.set("kubernetes.logStreams", nil) }
        // Its own objects: the selector picks these and nothing else.
        let base = Date().addingTimeInterval(-120).timeIntervalSince1970.rounded(.down)
        func at(_ offset: Double) -> Date { Date(timeIntervalSince1970: base + offset) }
        fake.add(
            "deployments.apps", "mlog", namespace: "shop", values: ["Ready": "2/2", "Up-to-date": 2, "Available": 2],
            fields: ["spec": ["replicas": 2, "selector": ["matchLabels": ["app": "mlog"]]], "status": ["replicas": 2, "readyReplicas": 2]])
        fake.addPod("mlog-a", namespace: "shop", labels: ["app": "mlog"])
        fake.addPod("mlog-b", namespace: "shop", labels: ["app": "mlog"])
        fake.appendLog("mlog-a", namespace: "shop", "alpha one", at: at(1.25))
        fake.appendLog("mlog-b", namespace: "shop", "bravo two", at: at(2.5))
        fake.appendLog("mlog-a", namespace: "shop", "alpha three", at: at(3.75))
        fake.appendLog("mlog-b", namespace: "shop", "bravo four", at: at(4.125))
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
            "the Deployments of fake-dev's shop", await eventually(15) { model.kind.fullName == "deployments.apps" && model.rows[KubeRowID(namespace: "shop", name: "mlog")] != nil },
            "\(model.kind.fullName) \(model.listState)")
        fake.forgetRequests()
        page.giveListTheKeyboard()
        page.selection = ["shop/mlog"]
        check("l on a Deployment is its logs", page.press("l") && page.detailTab == .logs && page.detail?.ref.name == "mlog")
        check("a Deployment's detail has a Logs tab", page.detail.map { KubeDetailTab.tabs(for: $0.ref).contains(.logs) } ?? false)
        guard await eventually(10, { page.detail?.merged != nil }), let merged = page.detail?.merged else {
            return check("its pods' logs, merged", false, "\(String(describing: page.detail?.state))")
        }
        check("of the pods its selector picks", merged.selector == "app=mlog" && merged.title == "deployment/mlog", "\(merged.selector) \(merged.title)")
        check(
            "two pods merged on their timestamps",
            await eventually(15) { merged.feed.lines.map(\.message) == ["alpha one", "bravo two", "alpha three", "bravo four"] },
            "\(merged.feed.lines.map(\.message)) \(merged.problem ?? "")")
        check("each line its pod's and container's", merged.feed.lines.map { $0.source ?? "" } == ["mlog-a/app", "mlog-b/app", "mlog-a/app", "mlog-b/app"])
        check("one stream a container, followed", await eventually(10) { fake.openLogFollows == ["shop/mlog-a/app", "shop/mlog-b/app"] && merged.feed.following })
        check(
            "the pods watched by the selector, while shown",
            fake.requests.contains { $0.isWatch && $0.path == "/api/v1/namespaces/shop/pods" && $0.query["labelSelector"] == "app=mlog" })
        func text() -> String {
            Self.find(LogLinesTextView.self, in: app.kubernetesView) { $0.accessibilityIdentifier() == "kubernetes.logs.text" }?.string ?? ""
        }
        check(
            "in the text view in that order, prefixed",
            await eventually(10) {
                let shown = text()
                let order = ["mlog-a/app | alpha one", "mlog-b/app | bravo two", "mlog-a/app | alpha three", "mlog-b/app | bravo four"].map {
                    shown.range(of: $0)?.lowerBound
                }
                guard order.allSatisfy({ $0 != nil }) else { return false }
                return zip(order, order.dropFirst()).allSatisfy { $0! < $1! }
            }, String(text().suffix(300)))
        check("drawn", await shownText(15) { $0.contains("bravo four") } != nil)
        check("the cap said in the tab", merged.summary.hasSuffix("at most 2 at once (kubernetes.logStreams)"), merged.summary)
        check("drawn", await shownText(15) { $0.contains("at most 2") } != nil)

        // A third pod joins: past the cap, left out and said.
        fake.addPod("mlog-c", namespace: "shop", labels: ["app": "mlog"])
        fake.appendLog("mlog-c", namespace: "shop", "charlie five", at: at(5))
        check("a pod joining past the cap is left out, said", await eventually(10) { merged.pods.count == 3 && merged.capped == 1 }, merged.summary)
        check("its stream not opened", fake.openLogFollows == ["shop/mlog-a/app", "shop/mlog-b/app"], "\(fake.openLogFollows)")
        check("drawn", await shownText(15) { $0.contains("1 more left out") } != nil)
        // One followed goes: its stream closes, the third joins in its place.
        fake.deletePod("mlog-a", namespace: "shop")
        check(
            "a pod gone has its stream closed, the one left out followed",
            await eventually(10) { fake.openLogFollows == ["shop/mlog-b/app", "shop/mlog-c/app"] && merged.capped == 0 }, "\(fake.openLogFollows)")
        check("its lines merged in", await eventually(10) { merged.feed.lines.contains { $0.message == "charlie five" && $0.source == "mlog-c/app" } })
        check("what the gone pod said stays", merged.feed.lines.contains { $0.message == "alpha one" })
        fake.appendLog("mlog-c", namespace: "shop", "charlie six")
        check("followed", await eventually(10) { merged.feed.lines.last?.message == "charlie six" })

        // An expression leaves a pod out.
        var filter = KubeMergedLogFilter()
        filter.excludePods = "mlog-b"
        check("an exclude expression is taken", merged.setFilter(filter))
        check("the pod it leaves out has its stream closed", await eventually(10) { fake.openLogFollows == ["shop/mlog-c/app"] }, "\(fake.openLogFollows)")
        check(
            "its lines read again without it", await eventually(10) { !merged.feed.lines.isEmpty && merged.feed.lines.allSatisfy { $0.source == "mlog-c/app" } },
            "\(merged.feed.lines.map { $0.source ?? "" })")
        check(
            "⌘L's lines would go scrubbed",
            !merged.scrubbed("auth with Bearer eyJfake.tokenpart.sig ok").contains("eyJfake.tokenpart.sig"))
        check(
            "Copy as kubectl is kubectl's own merge",
            page.detailKubectl?.hasPrefix("kubectl --context fake-dev -n shop logs -l app=mlog --all-containers --prefix --max-log-requests=2") == true,
            page.detailKubectl ?? "")

        // Hidden: the watch and every stream closed, nothing asked.
        app.toggleKubernetesPage(nil)
        check("hidden, its streams and its watch close", await eventually(10) { fake.openLogStreams == 0 && !merged.watching }, "\(fake.openLogFollows)")
        fake.forgetRequests()
        fake.appendLog("mlog-c", namespace: "shop", "while hidden")
        await pause(1.5)
        check("and nothing is asked", fake.requests.isEmpty, "\(fake.requests)")
        app.toggleKubernetesPage(nil)
        check(
            "shown again, followed from its last line", await eventually(10) { merged.feed.lines.last?.message == "while hidden" && fake.openLogStreams == 1 },
            "\(merged.feed.lines.map(\.message).suffix(3))")
        check("nothing twice", merged.feed.lines.filter { $0.message == "charlie six" }.count == 1)
        check("reads only", fake.writes.isEmpty, "\(fake.writes)")
        page.closeDetail()
        check("closed with the detail", await eventually(10) { fake.openLogStreams == 0 })
        page.showKind(.pods)
        if !wasShowing { app.toggleKubernetesPage(nil) }
    }
}
