import AppKit
import SwiftUI

/// The Overview as cards (`kubernetesOverview`), against the fake on a
/// socket of its own — never kubectl, never ~/.kube: a cluster with
/// something wrong at every level (a node not ready, pods crash-looping,
/// a Deployment and a DaemonSet short, a pod Pending, warning events) and
/// applications by their labels. The header's pills, a card a kind (a
/// press shows its list), what needs attention worst first with its
/// reasons, the usage of allocatable, the applications, the warnings —
/// drawn in a dark theme and a light one, and in a narrow window, one
/// column. With OVERTERM_DUMP_PNG, each is captured (`-overview-dark`,
/// `-overview-light`, `-overview-narrow` before `.png`). Reads only.
extension E2ERunner {
    func kubernetesOverviewScenario() async {
        await settledPrompt()
        guard let path = ProcessInfo.processInfo.environment["OVERTERM_KUBECONFIG"], !path.isEmpty, !path.contains(":") else {
            return check("OVERTERM_KUBECONFIG names the scenario's own file", false, "testKubernetesOverview sets it")
        }
        let kubeconfig = URL(fileURLWithPath: path)
        guard !KubeconfigSources.isUsersOwn(kubeconfig, home: FileManager.default.homeDirectoryForCurrentUser) else {
            return check("OVERTERM_KUBECONFIG isn't under ~/.kube", false, path)
        }
        check("the run guards the user's kubeconfig", AppEnvironment.guardsKubeconfig)
        let socket = "/tmp/ot-e2e-kov-\(UUID().uuidString.prefix(6)).sock"
        let fake = FakeKubeAPI(socket: socket)
        let port: Int
        do {
            try fake.start()
            port = try fake.listenTCP()
        } catch {
            return check("the fake API server starts", false, "\(error)")
        }
        defer { fake.stop() }
        defer { Self.accessibilityTree(false) }
        Self.overviewCluster(fake)
        do {
            try Self.fakeKubeconfig(port: port).write(to: kubeconfig, atomically: true, encoding: .utf8)
        } catch {
            return check("the scenario's kubeconfig is written", false, "\(error)")
        }
        defer { try? FileManager.default.removeItem(at: kubeconfig) }
        let model = KubernetesModel.shared
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
        model.statusOverride = { _ in .open }
        let interval = model.metrics.interval
        model.metrics.interval = .milliseconds(500)
        defer {
            model.connectOverride = nil
            model.statusOverride = nil
            model.metrics.interval = interval
        }
        let page = app.kubernetesPage
        app.toggleKubernetesPage(nil)
        check("the scenario's contexts are read", await eventually(10) { model.contexts.contexts.map(\.name) == ["fake-dev", "fake-prod"] })
        if model.selectedName != "fake-dev" { model.select("fake-dev") }
        model.setScope(.namespace("shop"))
        check("1 is the Overview", page.press("1") && page.section == .overview)
        let session = page.clusterOverview
        check(
            "it reads the cluster",
            await eventually(20) { session.state == .live && session.overview.nodes == 3 && session.overview.pods == 12 && session.overview.workloads.count >= 3 },
            "\(session.state) \(session.overview.pods) pods \(session.overview.nodes) nodes \(session.problems)")
        check("its usage sampled", await eventually(15) { page.clusterUsage != nil }, model.metrics.note(.nodes) ?? "")
        check("its health checks read", await eventually(15) { page.health.state == .loaded }, "\(page.health.state)")
        fake.forgetRequests()

        // What the cards say, from what was read.
        let overview = session.overview
        let rows = KubeOverviewCards.attention(overview)
        check("the node not ready first, worst first", rows.first?.title == "node/fake-node-3" && rows.first?.pill == "NotReady", "\(rows.map(\.title))")
        check(
            "then the pods failing, the most restarted first",
            rows.dropFirst().prefix(2).map(\.title) == ["pod/worker-5c", "pod/api-7f"] && rows.dropFirst().first?.pill == "CrashLoopBackOff · 14×",
            "\(rows.map { "\($0.title) \($0.pill)" })")
        check(
            "the workloads short last, by how far off",
            rows.contains { $0.title == "deployment/api" && $0.pill == "2/3 ready" } && rows.contains { $0.title == "daemonset/node-agent" && $0.pill == "2/3 ready" }
                && rows.last?.tone == .waiting,
            "\(rows.map { "\($0.title) \($0.pill)" })")
        let kinds = KubeOverviewCards.kinds(overview)
        check(
            "a card a kind: pods, the workloads, the nodes",
            kinds.map(\.title).starts(with: ["Pods"]) && kinds.contains { $0.title == "StatefulSets" } && kinds.last?.title == "Nodes", "\(kinds.map(\.title))")
        check("the pods' line says the bar's counts", kinds.first?.line == "7 running · 1 completed · 1 pending · 3 failing", kinds.first?.line ?? "")

        // Dark.
        Settings.shared.set("appearance.theme", .string("Claude Dark"))
        check("a dark theme", await eventually(5) { self.app.theme?.isDark == true })
        check("the header's pill says how many need attention", await shownText(15) { $0.contains("\(overview.problems) need attention") } != nil)
        check("its health count beside it", await shownText(15) { $0.contains("Health: \(page.health.report.said)") } != nil, page.health.report.said)
        check("and the server's version and its nodes", await shownText(15) { $0.contains("Kubernetes v1.") && $0.contains("3 nodes") } != nil)
        check("what needs attention, a card", await shownText(15) { $0.localizedCaseInsensitiveContains("Needs attention") } != nil)
        check("a pod's reason as a pill", await shownText(15) { $0.contains("CrashLoopBackOff") } != nil)
        check("a workload's as its row says it", await shownText(15) { $0.contains("2/3 ready") } != nil)
        check("beside the usage of allocatable", await shownText(15) { $0.contains("Usage of allocatable") } != nil)
        check("its CPU of allocatable", await shownText(15) { $0.contains("3000m of 12000m") } != nil)
        let deployments = await shownText(15) { $0 == "Deployments" }
        check("the Deployments card drawn", deployments != nil)
        // The checks that pass, once the health checks are read — and again
        // after a refresh: the pill follows the health session itself.
        let passing = KubeOverviewCards.passingChecks(page.health.report)
        check("some checks ran whole and pass", passing > 0, "\(page.health.report.ran) \(page.health.report.notes)")
        check("the header says how many pass", await shownText(15) { $0.contains("\(passing) checks pass") } != nil, "\(passing)")
        page.refreshHealth()
        check("its health checks read again", await eventually(15) { page.health.state == .loaded }, "\(page.health.state)")
        check("the pass pill drawn again after the refresh", await shownText(15) { $0.contains("\(passing) checks pass") } != nil)
        for part in ["counts", "attention", "usage", "warnings", "passing"] {
            check("kubernetes.overview.\(part) is there", await overviewElement("kubernetes.overview.\(part)") != nil)
        }
        if let attention = await overviewElement("kubernetes.overview.attention"), let usage = await overviewElement("kubernetes.overview.usage") {
            // Screen points, y up: side by side, tops level, usage on the right.
            check(
                "wide, the usage beside what needs attention", usage.frame.minX >= attention.frame.maxX - 1 && abs(usage.frame.maxY - attention.frame.maxY) < 2,
                "\(attention.frame) \(usage.frame)")
        }
        check("wide, nothing scrolls sideways", overviewFitsAcross(), overviewWidths())
        await overviewPicture("overview-dark")
        // Further down: the health checks, the applications, the warnings.
        check("the Overview scrolls", scrollOverview(toEnd: true))
        check("the applications as cards", await shownText(15) { $0.contains("postgres") } != nil)
        check("each warning with its reason and count", await shownText(15) { $0.contains("FailedScheduling") } != nil)
        // SwiftUI's tree holds what is on screen: the health checks' count, down here.
        check("kubernetes.health.count is there", await overviewElement("kubernetes.health.count") != nil)
        let warnings = await overviewElement("kubernetes.overview.warnings")
        check(
            "the warnings card says FailedScheduling and ×14", warnings.map { $0.text.contains("FailedScheduling") && $0.text.contains("×14") } == true,
            warnings?.text ?? "no kubernetes.overview.warnings")
        await overviewPicture("overview-dark-end")
        _ = scrollOverview(toEnd: false)

        // Light.
        Settings.shared.set("appearance.theme", .string("Claude Light"))
        check("a light theme", await eventually(5) { self.app.theme?.isDark == false })
        check("the cards drawn in it", await shownText(15) { $0.localizedCaseInsensitiveContains("Needs attention") } != nil)
        check("its pills too", await shownText(15) { $0.contains("\(overview.problems) need attention") } != nil)
        await overviewPicture("overview-light")

        // Narrow: one column, nothing cut.
        let frame = window.frame
        window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: 760, height: frame.height), display: true)
        check("narrow, still drawn", await shownText(15) { $0.localizedCaseInsensitiveContains("Needs attention") } != nil)
        // One column: the usage card can sit below the fold, by how tall
        // what needs attention came out — scrolled to, as a person would.
        await revealElement("kubernetes.overview.usage")
        check("and its usage under it", await shownText(15) { $0.contains("Usage of allocatable") } != nil)
        if let attention = await overviewElement("kubernetes.overview.attention"), let usage = await overviewElement("kubernetes.overview.usage") {
            check("narrow, one column: the usage under what needs attention", usage.frame.maxY <= attention.frame.minY + 1, "\(attention.frame) \(usage.frame)")
        } else {
            check("narrow, the attention and usage cards found", false)
        }
        check("narrow, nothing scrolls sideways", overviewFitsAcross(), overviewWidths())
        await overviewPicture("overview-narrow")
        _ = scrollOverview(toEnd: false)
        window.setFrame(frame, display: true)
        Settings.shared.set("appearance.theme", .string("Claude Dark"))

        // A card is a button: its list.
        await pause(0.8)
        if let card = await shownText(15, { $0 == "Deployments" }) {
            await click(at: CGPoint(x: card.frame.midX, y: card.frame.midY))
            check(
                "pressing the Deployments card shows their list",
                await eventually(5) { page.section != .overview && model.kind.fullName == "deployments.apps" }, "\(page.section) \(model.kind.fullName)")
        } else {
            check("the Deployments card to press", false)
        }
        check("1, the Overview again", page.press("1") && page.section == .overview)
        check("live again", await eventually(15) { session.state == .live })
        check("the Overview's cards wrote nothing", fake.writes.isEmpty, "\(fake.writes)")
        check("nor asked anything but GETs", fake.requests.allSatisfy { $0.method == "GET" })
        app.toggleKubernetesPage(nil)
        check("hidden, its follows end", await eventually(10) { session.state == .idle && fake.openWatches == 0 }, "\(fake.openWatches) open")
    }

    /// The Overview's scroll view: the page's tallest that isn't the list's table.
    private func overviewScroll() -> NSScrollView? {
        guard let root = app.kubernetesView else { return nil }
        var found: NSScrollView?
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, !scroll.isHiddenOrHasHiddenAncestor, let document = scroll.documentView, !(document is NSTableView),
                document.frame.height > (found?.documentView?.frame.height ?? 0)
            {
                found = scroll
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    /// No sideways overflow: the Overview's content no wider than what shows it.
    private func overviewFitsAcross() -> Bool {
        guard let scroll = overviewScroll(), let document = scroll.documentView else { return false }
        return document.frame.width <= scroll.contentView.bounds.width + 0.5
    }

    private func overviewWidths() -> String {
        guard let scroll = overviewScroll(), let document = scroll.documentView else { return "no scroll view" }
        return "content \(document.frame.width), shown \(scroll.contentView.bounds.width)"
    }

    /// The accessibility elements under the Kubernetes page that carry
    /// `identifier` (SwiftUI's `.accessibilityIdentifier`): their frames
    /// united, in screen points, and every word in them — read again until
    /// it is there (SwiftUI builds its tree a moment later).
    func overviewElement(_ identifier: String, timeout: TimeInterval = 5) async -> (frame: CGRect, text: String)? {
        Self.accessibilityTree(true)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let root = app.kubernetesView, let found = Self.accessibilityElement(identifier, in: root) { return found }
            await pause(0.3)
        } while Date() < deadline
        return nil
    }

    /// SwiftUI builds its accessibility tree only for an assistive client:
    /// AXEnhancedUserInterface on the app, as one sets it — this run's own
    /// process only, off again at the scenario's end.
    static func accessibilityTree(_ on: Bool) {
        _ = NSApp.perform(Selector(("accessibilitySetValue:forAttribute:")), with: NSNumber(value: on), with: "AXEnhancedUserInterface")
    }

    private static func accessibilityElement(_ identifier: String, in root: NSView) -> (frame: CGRect, text: String)? {
        var seen: Set<ObjectIdentifier> = []
        var frame: CGRect?
        var words: [String] = []
        func get(_ object: NSObject, _ key: String) -> Any? {
            object.responds(to: Selector(key)) ? object.value(forKey: key) : nil
        }
        func children(_ object: NSObject) -> [NSObject] {
            var all = (get(object, "accessibilityChildren") as? [Any] ?? []).compactMap { $0 as? NSObject }
            if let view = object as? NSView { all += view.subviews }
            return all
        }
        func text(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            for key in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"] {
                if let said = get(object, key) as? String, !said.isEmpty { words.append(said) }
            }
            for child in children(object) where (child as? NSView)?.isHiddenOrHasHiddenAncestor != true { text(child) }
        }
        var walked: Set<ObjectIdentifier> = []
        func walk(_ object: NSObject, depth: Int) {
            guard depth < 80, walked.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? NSView, view.isHiddenOrHasHiddenAncestor { return }
            if get(object, "accessibilityIdentifier") as? String == identifier {
                let box = (get(object, "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
                frame = frame.map { $0.union(box) } ?? box
                text(object)
                return
            }
            for child in children(object) { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        guard let frame else { return nil }
        return (frame, words.joined(separator: " "))
    }

    /// The Overview's scroll view moved to its end or back to its top, in process.
    private func scrollOverview(toEnd: Bool) -> Bool {
        guard let scroll = overviewScroll(), let document = scroll.documentView else { return false }
        let clip = scroll.contentView.bounds.height
        let end = document.isFlipped ? max(0, document.frame.height - clip) : 0
        let top = document.isFlipped ? 0 : max(0, document.frame.height - clip)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: toEnd ? end : top))
        scroll.reflectScrolledClipView(scroll.contentView)
        return document.frame.height > clip
    }

    /// OVERTERM_DUMP_PNG's picture of the window, `-<name>` before `.png`.
    private func overviewPicture(_ name: String) async {
        guard let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty else { return }
        await pause(0.8)
        app.captureWindow(to: png.replacingOccurrences(of: ".png", with: "-\(name).png"))
    }

    /// A cluster with something wrong at every level, and applications by their labels.
    private static func overviewCluster(_ fake: FakeKubeAPI) {
        fake.addNamespace("shop")
        let shop = [KubeApplications.partOfLabel: "acme-shop"]
        for index in 1...6 { fake.addPod("web-\(index)", namespace: "shop", labels: ["app": "web"]) }
        fake.addPod("cart-1", namespace: "shop", labels: ["app": "cart"])
        fake.addPod("worker-5c", namespace: "shop", FakeKubeAPI.Pod(status: "CrashLoopBackOff", phase: "Running", ready: 0, restarts: 14, lastRestart: "40s"))
        fake.addPod("api-7f", namespace: "shop", FakeKubeAPI.Pod(status: "OOMKilled", phase: "Running", ready: 0, restarts: 3))
        fake.addPod("pull-1", namespace: "shop", FakeKubeAPI.Pod(status: "ImagePullBackOff", phase: "Pending", ready: 0))
        fake.addPod("migrate-x", namespace: "shop", FakeKubeAPI.Pod(status: "Completed", phase: "Succeeded", ready: 0))
        fake.addPod("queue-0", namespace: "shop", FakeKubeAPI.Pod(status: "Pending", phase: "Pending", ready: 0), created: Date().addingTimeInterval(-180))
        fake.add(
            "deployments.apps", "web", namespace: "shop", values: ["Ready": "6/6", "Up-to-date": 6, "Available": 6],
            labels: shop.merging([KubeApplications.nameLabel: "web", KubeApplications.componentLabel: "frontend"]) { $1 })
        fake.add(
            "deployments.apps", "worker", namespace: "shop", values: ["Ready": "0/1", "Up-to-date": 1, "Available": 0],
            labels: shop.merging([KubeApplications.nameLabel: "worker", KubeApplications.componentLabel: "queue"]) { $1 })
        fake.add(
            "deployments.apps", "api", namespace: "shop", values: ["Ready": "2/3", "Up-to-date": 3, "Available": 2],
            labels: shop.merging([KubeApplications.nameLabel: "api"]) { $1 })
        fake.add("deployments.apps", "cart", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1], labels: [KubeApplications.nameLabel: "cart"])
        fake.add(
            "statefulsets.apps", "postgres", namespace: "shop", values: ["Ready": "1/1"],
            labels: shop.merging([KubeApplications.nameLabel: "postgres", KubeApplications.componentLabel: "database"]) { $1 })
        fake.add("daemonsets.apps", "node-agent", namespace: "shop", values: ["Desired": 3, "Current": 3, "Ready": 2, "Up-to-date": 3, "Available": 2])
        fake.add("jobs.batch", "migrate", namespace: "shop", values: ["Status": "Complete", "Completions": "1/1"])
        for (node, status) in [("fake-node-1", "Ready"), ("fake-node-2", "Ready"), ("fake-node-3", "NotReady")] {
            fake.add("nodes", node, values: ["Status": .text(status), "Roles": "<none>", "Version": "v1.34.1"])
            fake.setFields("nodes", node, ["status": ["allocatable": ["cpu": "4", "memory": "16Gi"], "capacity": ["cpu": "4", "memory": "16Gi"]]])
            fake.setNodeMetrics(node, cpu: "1", memory: "6Gi")
        }
        fake.addEvent(about: "pods", "worker-5c", namespace: "shop", type: "Warning", reason: "BackOff", message: "Back-off restarting failed container worker", count: 14)
        fake.addEvent(about: "pods", "api-7f", namespace: "shop", type: "Warning", reason: "OOMKilling", message: "Memory cgroup out of memory: killed process 4121 (api)", count: 3)
        fake.addEvent(
            about: "pods", "queue-0", namespace: "shop", type: "Warning", reason: "FailedScheduling",
            message: "0/3 nodes are available: 1 node(s) had untolerated taint, 2 Insufficient memory.")
        fake.addEvent(about: "pods", "web-1", namespace: "shop", reason: "Scheduled", message: "Assigned shop/web-1 to fake-node-1")
    }
}
