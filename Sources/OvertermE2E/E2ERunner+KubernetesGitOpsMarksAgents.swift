#if E2E
import AppKit
import Foundation
import SwiftUI

/// D6 (docs/design/kubernetes/gitops.md, 14.2.6), part 5 of the
/// `kubernetesGitOpsMarks` scenario, on its spoke (`fake-dev`, a fake API
/// server on a socket of the scenario's own — never a real cluster): agents.
///
/// - `a` on the StatefulSet `0/3`'s app — Progressing, never Failed under
///   Argo CD's rules — opens the Ask Agent sheet with its brief shown whole
///   before anything is sent: the question in Argo CD's word, where Argo CD
///   runs, what only its Application knows, its pods as their rows say
///   them, the sentinel nowhere; its reads GETs only, its pods by its own
///   selector as rows in its namespace; Cancel sends nothing.
/// - `a` on a Ready app says why not and opens nothing.
/// - The detail's Ask Why on the stalled rollout's app — one failing
///   Deployment — opens the Deployment's own brief with the app named.
/// - `k8s_gitops` from an agent: the apps the section ranked, problems
///   first, "Argo CD runs in another cluster", never "serves neither" — and
///   nothing read for it (the section's store).
///
/// Each sub-part's reads are checked as a closed set (14.9.3: "for each
/// part, the set of paths the part read, so a new list can't sneak in"):
/// the brief's kinds, and beside them only what the section shown reads
/// (`readsOnly`). The checkout's rail's Ask Why on its app read from marks
/// is part 5's (`kubernetesCheckoutGitOpsMarks`).
extension E2ERunner {
    /// What one sub-part read of the spoke, discovery aside, is within
    /// `kinds` — what it reads itself — and what the section shown reads
    /// beside it: the marks' kinds, the page's namespaces and CRDs. What it
    /// reads of other kinds (pods, ReplicaSets, events) only in its app's
    /// `namespace`; events only about `eventsAbout` (an object's name, or a
    /// ReplicaSet's prefix) — never beyond its causes'. Never a Secret or a
    /// ConfigMap.
    private func readsOnly(_ what: String, _ requests: [FakeKubeAPI.Request], _ kinds: Set<String>, in namespace: String? = nil, eventsAbout: [String] = []) {
        let read = Set(requests.filter { !$0.isDiscovery }.compactMap { Self.resource(of: $0.path) })
        let allowed = Self.marksKinds.union(kinds).union(["namespaces", "customresourcedefinitions"])
        check(
            "\(what): nothing read but \(kinds.isEmpty ? "the section's own" : kinds.sorted().joined(separator: ", ")) beside the section's", read.isSubset(of: allowed),
            "\(read.subtracting(allowed).sorted())")
        let own = requests.filter { request in Self.resource(of: request.path).map { kinds.contains($0) && !Self.marksKinds.contains($0) } ?? false }
        if let namespace {
            check("\(what): what is under its objects read in \(namespace) alone", own.allSatisfy { $0.path.contains("/namespaces/\(namespace)/") }, "\(own.map(\.path))")
        }
        let events = requests.filter { Self.resource(of: $0.path) == "events" }
        check(
            "\(what): events about its causes alone",
            events.allSatisfy { request in
                let named = request.query["fieldSelector"]?.split(separator: ",").first { $0.hasPrefix("involvedObject.name=") }
                return named.map { field in eventsAbout.contains { field.dropFirst("involvedObject.name=".count).hasPrefix($0) } } ?? false
            }, "\(events.map { $0.query["fieldSelector"] ?? "none" })")
        check("\(what): never a Secret or a ConfigMap", !requests.contains { $0.path.contains("/secrets") || $0.path.contains("/configmaps") })
    }

    package func kubernetesGitOpsMarksAgents(_ model: KubernetesModel, _ page: KubernetesPageModel, _ spoke: FakeKubeAPI, made: FakeKubeAPI.Spoke) async {
        let gitOps = page.gitOps
        func row(_ instance: String) -> KubeGitOpsRow? { gitOps.rows.shown.first { $0.marked?.key.instance == instance } }
        func sheet() -> AskAgentView? { (window.attachedSheet?.contentViewController as? NSHostingController<AskAgentView>)?.rootView }
        func cancelSheet() async -> Bool {
            let cancelled = sheet().map { $0.cancel() } != nil
            return await eventually(3) { self.window.attachedSheet == nil } && cancelled
        }
        if app.store.showingOverlay != .kubernetes { app.showKubernetesPage() }
        if page.section != .gitops { page.showSection(.gitops) }
        page.closeMarkedApp()
        page.commandProblem = nil
        // Shown again: its apps made again from what the section keeps, its rows followed again.
        check(
            "the section's apps again",
            await eventually(30) { gitOps.marked.state == .live && gitOps.marked.isMerged && row(made.statefulSet) != nil && row(made.stalled) != nil },
            "\(gitOps.marked.state) \(gitOps.rows.shown.count) rows")
        guard let ledger = row(made.statefulSet) else { return check("the StatefulSet's app row", false) }
        check("a StatefulSet 0/3's app Progressing, never Failed", ledger.state == .progressing, ledger.state.word)
        check(
            "its menu asks an agent why", page.gitOpsVerbs(for: [ledger.id]).first { $0.title == "Ask an Agent Why…" }.map { $0.unavailable == nil && $0.key == "a" } == true)
        page.gitOpsView.selection = [ledger.id]
        page.giveListTheKeyboard()
        spoke.forgetRequests()
        check("a asks why", await pressKubernetesKey("a", keyCode: 0))
        check("the Ask Agent sheet opens", await eventually(15) { self.window.attachedSheet != nil && sheet() != nil }, page.commandProblem ?? "")
        let ask = app.askAgent
        check(
            "the question, in Argo CD's word", ask.message == "Why is Argo CD app \(made.statefulSet) still Progressing — 0/3 ready, StatefulSet acme-ledger-db?",
            ask.message)
        check("its chip", ask.subject == "Argo CD app \(made.statefulSet) Progressing", ask.subject ?? "none")
        check("the whole brief shown before it is sent", ask.showsBrief)
        check("its pods a chip", ask.parts.contains { $0.title == "pods" }, "\(ask.parts.map(\.title))")
        let prompt = await app.askAgentPrompt()
        check(
            "where Argo CD runs, what only its Application knows",
            prompt.contains("Argo CD runs in another cluster — not in your kubeconfig.") && prompt.contains("What only its Application knows isn't here"), prompt)
        check("its pods as their rows say them", prompt.contains("acme-ledger-db-0: Pending"), prompt)
        check("scrubbed: the sentinel nowhere", !prompt.contains(FakeKubeAPI.gitOpsSentinel))
        let reads = spoke.requests
        check("read with GETs alone", reads.allSatisfy { $0.method == "GET" } && spoke.writes.isEmpty, "\(reads.filter { $0.method != "GET" }.map(\.description))")
        check(
            "its pods by its own selector, as rows, in its namespace",
            reads.contains { request in
                request.path == "/api/v1/namespaces/team-4/pods" && request.query["labelSelector"] == "app=acme-ledger-db" && request.accept == KubeClient.tableOnlyAccept
                    && request.query["includeObject"] == "Metadata"
            }, "\(reads.map(\.path))")
        // Its object, its pods, its events — and nothing else of the brief's.
        readsOnly("a's brief", reads, ["statefulsets", "pods", "events"], in: "team-4", eventsAbout: ["acme-ledger-db"])
        check(
            "never a pod or a ReplicaSet across the cluster",
            !reads.contains { request in request.path == "/api/v1/pods" || request.path == "/apis/apps/v1/replicasets" })
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty, let shown = window.attachedSheet {
            app.captureWindow(to: png.replacingOccurrences(of: ".png", with: "-kube-gitops-marks-ask-why.png"), window: shown)
        }
        check("Cancel sends nothing and puts the sheet away", await cancelSheet() && !ask.isOpen)

        // A Ready app: why not, over the list; nothing opens.
        if let ready = gitOps.rows.shown.first(where: { $0.isMarked && $0.state == .ready }) {
            page.gitOpsView.selection = [ready.id]
            page.giveListTheKeyboard()
            check(
                "a on a Ready app says why not", await pressKubernetesKey("a", keyCode: 0) && page.commandProblem?.hasSuffix("Ask Why is for one that isn't.") == true,
                page.commandProblem ?? "none")
            await pause(0.4)
            check("and opens nothing", window.attachedSheet == nil)
            let problem = await overviewElement("kubernetes.commandProblem", timeout: 10)
            check("said over the list", problem?.text.contains("Ask Why is for one that isn't.") == true, problem?.text ?? "none")
            check("drawn", await shownText(10) { $0.contains("is Ready") || $0.contains("Ask Why is for") } != nil)
            page.commandProblem = nil
        } else {
            check("a Ready app's row", false)
        }

        // The detail's Ask Why: the stalled rollout's app, one failing Deployment — its own brief, the app named.
        guard let stalled = row(made.stalled)?.marked?.key else { return check("the stalled app's row", false) }
        page.gitOpsView.selection = []
        page.openMarkedApp(KubeMarkedDetailRef(context: "fake-dev", key: stalled))
        check("its detail read", await eventually(15) { page.markedDetailShown != nil && page.markedRead.state == .loaded })
        spoke.forgetRequests()
        check("its Ask Why pressed", await pressOnce("kubernetes.gitops.marked.askWhy"))
        check("the sheet opens", await eventually(15) { self.window.attachedSheet != nil && sheet() != nil }, page.commandProblem ?? "")
        check("the Deployment's own brief", ask.subject == "deploy/acme-cart ProgressDeadlineExceeded", ask.subject ?? "none")
        check("the app named in it, its objects a chip", ask.parts.first?.title == "Argo CD app", "\(ask.parts.map(\.title))")
        let handed = await app.askAgentPrompt()
        check("one of the app's objects, said", handed.contains("It is one of Argo CD app \(made.stalled)'s objects"), handed)
        check("its rollout and its pod template", handed.contains("ProgressDeadlineExceeded") && handed.contains("pod template"), handed)
        check("scrubbed: env, args and last-applied's sentinel nowhere", !handed.contains(FakeKubeAPI.gitOpsSentinel))
        check("read with GETs alone", spoke.requests.allSatisfy { $0.method == "GET" } && spoke.writes.isEmpty)
        // The Deployment's own brief: it, its ReplicaSets, its pods (a failing one's log), their events.
        readsOnly("the detail's brief", spoke.requests, ["deployments", "replicasets", "pods", "events"], in: "team-2", eventsAbout: ["acme-cart"])
        check("Cancel", await cancelSheet())
        page.closeMarkedApp()
        page.giveListTheKeyboard()

        // An agent's k8s_gitops on the spoke: the section's apps, nothing read for them.
        spoke.forgetRequests()
        var answer = ""
        do {
            let result = try await KubeMCP.call("k8s_gitops", ["context": "fake-dev", "namespace": "all"], kubernetes: model)
            answer = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        } catch {
            answer = "\(error)"
        }
        let lines = answer.components(separatedBy: "\n")
        check("an agent on the spoke gets apps, never \"serves neither\"", !answer.contains("serves neither") && lines.contains { $0.hasPrefix("marks  ") }, answer)
        check(
            "the opening line: Argo CD in another cluster",
            lines.dropFirst().first == "Argo CD runs in another cluster (not in the kubeconfig); apps read from the marks on their objects; no sync status, repository or revision.",
            answer)
        check("as the section read them, nothing read for it", answer.contains("As the GitOps section on the Kubernetes page read them") && answer.contains("nothing read for this answer"), answer)
        check("problems first", lines.first { $0.hasPrefix("marks  ") }?.hasPrefix("marks  Failed") == true, answer)
        check("the HPA's metrics as the section read them", lines.contains { $0.contains(made.hpa) && $0.contains("FailedGetResourceMetric") }, answer)
        let listedForIt = spoke.requests.filter { request in
            !request.isWatch && request.query["limit"] == "500"
                && ["/apis/apps/v1/deployments", "/apis/apps/v1/statefulsets", "/apis/apps/v1/daemonsets", "/apis/argoproj.io/v1alpha1/rollouts"].contains(request.path)
        }
        check("no row of the marks' kinds listed for it", listedForIt.isEmpty, "\(listedForIt.map(\.path))")
        // Nothing of its own: the section's reads alone, beside it.
        readsOnly("k8s_gitops", spoke.requests, [])
        check("scrubbed", !answer.contains(FakeKubeAPI.gitOpsSentinel))
        check("nothing written", spoke.writes.isEmpty)
    }
}
#endif
