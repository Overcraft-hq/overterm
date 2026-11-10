import AppKit
import Foundation

/// G8 (docs/design/kubernetes/gitops.md, 3.2, 8.4, 10): `kubernetesPerf`'s
/// GitOps leg, against the fake only. 1,000 Argo CD Applications, each
/// with the metadata a busy one carries (managedFields, a client-side
/// apply's annotation) and a status of a dozen resources: `g` across every
/// namespace drawn with every row live in under 5 s, the rows' first list
/// and the summaries' pages counted and their bytes recorded — the
/// summaries cut at 500, said, by 25 pages of 20, the rows' first list
/// one streaming list (and, back to `g` on a server refusing one, two
/// pages of 500); a burst of 500 status
/// writes (450 `reconciledAt` alone, 50 turning Degraded) applied in under
/// 3 s, read again only for the rows whose cells moved or aren't healthy,
/// at most 4 GETs in flight and 20 a flush, ranked and drawn once a flush
/// (the main thread never held 500 ms); the table scrolled; another section ends every follow and back
/// to `g` reads no summary again. Reads only.
extension E2ERunner {
    func kubernetesGitOpsPerf(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        let count = 1000
        let applications = "applications.argoproj.io"
        fake.tableManagedFields = true
        defer { fake.tableManagedFields = false }
        let made = fake.addGitOpsPerfApplications(count)
        let scope = model.scope
        model.setScope(.all)
        defer { model.setScope(scope) }
        model.rediscover()
        check("Argo CD served", await eventually(15) { page.gitOpsServed }, "\(model.discovery?.kinds.filter { $0.group == "argoproj.io" }.map(\.fullName) ?? [])")
        // A whole Application, as a GET answers it: what one weighs.
        let whole = FakeKubeAPI.encode(fake.object(applications, made.names[1], namespace: "argocd") ?? [:]).count
        note("kubernetes GitOps: one Application weighs \(whole / 1024) KB whole")
        fake.forgetRequests()
        fake.forgetBytes()
        let gitOps = page.gitOps

        // The first draw: `g` until every row is live, the summaries read and the table drawn.
        let stall = MainThreadStall()
        stall.start()
        let opened = CACurrentMediaTime()
        check("g shows GitOps", page.press("g") && page.section == .gitops)
        let read = await eventually(30) { gitOps.state == .live && !gitOps.summarising && gitOps.rows.shown.count == count }
        var table: NSTableView?
        let drawn = await eventually(15) {
            table = self.gitOpsTable()
            return (table?.numberOfRows ?? 0) == page.gitOpsVisibleRows.count && (table?.numberOfRows ?? 0) > 0
        }
        app.kubernetesView?.displayIfNeeded()
        let firstDraw = (CACurrentMediaTime() - opened) * 1000
        let openStall = stall.stop()
        check("1,000 Applications' rows live and summarised", read, "\(gitOps.state) \(gitOps.summarising) \(gitOps.rows.shown.count) rows")
        check("the table drawn", drawn, "\(table?.numberOfRows ?? -1) of \(page.gitOpsVisibleRows.count)")
        note("kubernetes GitOps first draw of \(count) Applications: \(Int(firstDraw)) ms, the main thread held at most \(Int(openStall)) ms")
        check("first drawn in under 5 s", firstDraw < 5000, "\(Int(firstDraw)) ms")
        check("the main thread never held 500 ms", openStall < 500, "\(Int(openStall)) ms")
        check("Hide Ready, past 50 rows", page.gitOpsHidesReady && page.gitOpsVisibleRows.count < count, "\(page.gitOpsVisibleRows.count) shown")

        // What it read: the rows' list (metadata with them), the summaries' pages.
        let requests = fake.requests.filter { $0.path.contains("/apis/argoproj.io/") }
        let rowsBytes = fake.bytesSent(applications) - fake.bytesSent(applications, table: false)
        let summaryBytes = fake.bytesSent(applications, table: false)
        let pages = requests.filter { !$0.isWatch && !$0.accept.contains("as=Table") && $0.query["limit"] != nil && $0.path.hasSuffix("/applications") }
        note(
            "kubernetes GitOps reads: rows \(rowsBytes / 1024) KB (\(rowsBytes / count) bytes a row, metadata with it), summaries \(summaryBytes / 1024) KB in \(pages.count) pages"
        )
        let rowsPath = "/apis/argoproj.io/v1alpha1/applications"
        check("the rows followed once, across the cluster", requests.filter { $0.isWatch && $0.path == rowsPath }.count == 1)
        // §8.4: the rows' first list, on a server that streams it (the fake, as 1.32 and 1.34+): no page.
        check(
            "the rows' first list one streaming list, no page",
            requests.contains { $0.isWatch && $0.path == rowsPath && $0.query["sendInitialEvents"] == "true" }
                && !requests.contains { !$0.isWatch && $0.accept.contains("as=Table") && $0.path == rowsPath },
            "\(requests.filter { $0.path == rowsPath }.map(\.query))")
        check("the rows' first list under §3.2's 30 MB", rowsBytes < 30 << 20, "\(rowsBytes) bytes")
        check(
            "the summaries cut at 500, by pages of 20",
            gitOps.objects.filter { $0.role == .application }.count == KubeGitOpsSession.kindObjects && pages.count == KubeGitOpsSession.kindObjects / KubeGitOpsSession.pageLimit
                && pages.allSatisfy { $0.query["limit"] == String(KubeGitOpsSession.pageLimit) },
            "\(gitOps.objects.count) summarised in \(pages.count) pages")
        check("and said so", gitOps.notes.contains { $0.contains("500 of \(count.formatted())") }, "\(gitOps.notes)")
        check("under 64 MB", summaryBytes < KubeGitOpsSession.kindBytes, "\(summaryBytes) bytes")
        check(
            "no Secret, no ConfigMap read",
            !fake.requests.contains { $0.path.hasSuffix("/secrets") || $0.path.hasSuffix("/configmaps") || $0.path.contains("/secrets/") || $0.path.contains("/configmaps/") })
        check("no whole-object watch", !fake.requests.contains { $0.isWatch && $0.path.contains("argoproj.io") && !$0.accept.contains("as=Table") })
        check("nothing read again yet", fake.requests.filter { Self.isApplicationGet($0) }.isEmpty, "\(fake.requests.filter { Self.isApplicationGet($0) }.count) GETs")

        await gitOpsBurst(page, fake, made, count: count)
        await gitOpsScroll()

        // Another section: every follow ends; back to g within five minutes reads no summary again.
        let watches = fake.openWatches
        page.showKind(.pods)
        check("another section: its follows end", await eventually(10) { gitOps.openFollows == 0 && !gitOps.isReading }, "\(gitOps.openFollows) follows")
        check("and their watches", await eventually(10) { fake.openWatches <= watches - 3 }, "\(fake.openWatches) open, \(watches) before")
        // Back on a server that refuses a streaming list (the WatchList
        // gate off): the rows' first list in pages of 500 — two for 1,000.
        fake.forgetRequests()
        fake.streamingLists = false
        let back = CACurrentMediaTime()
        check("back to g", page.press("g") && page.section == .gitops)
        check("its rows live again", await eventually(15) { gitOps.state == .live && gitOps.rows.shown.count == count }, "\(gitOps.rows.shown.count)")
        note("kubernetes GitOps back to g: \(Int((CACurrentMediaTime() - back) * 1000)) ms")
        let rowPages = fake.requests.filter { !$0.isWatch && $0.accept.contains("as=Table") && $0.path == rowsPath }
        check(
            "streaming refused, the rows' first list in two pages of 500",
            rowPages.count == 2 && rowPages.allSatisfy { $0.query["limit"] == "500" } && rowPages[0].query["continue"] == nil
                && rowPages[1].query["continue"] != nil,
            "\(rowPages.map(\.query))")
        check(
            "with no summary read again",
            !fake.requests.contains { !$0.isWatch && !$0.accept.contains("as=Table") && $0.query["limit"] != nil && $0.path.contains("argoproj.io") })
        page.showKind(.pods)
        check("left, nothing follows", await eventually(10) { gitOps.openFollows == 0 }, "\(gitOps.openFollows)")
        // The refusal is the context's for the run: forgotten, and streaming served again.
        fake.streamingLists = true
        if let name = model.selectedName {
            model.streamingLists.forget(name)
            model.streamingLists.learn(name, minor: Int(fake.minor))
        }
        check("it wrote nothing", fake.writes.isEmpty)
    }

    private static func isApplicationGet(_ request: FakeKubeAPI.Request) -> Bool {
        !request.isWatch && request.path.hasPrefix("/apis/argoproj.io/v1alpha1/namespaces/argocd/applications/")
    }

    /// 500 status writes: 450 healthy Applications' `reconciledAt` alone —
    /// no cell moves, nothing read — and 50 summarised ones turning
    /// Degraded, each read once. Applied in under 3 s; the reads within
    /// R3's bounds.
    private func gitOpsBurst(_ page: KubernetesPageModel, _ fake: FakeKubeAPI, _ made: FakeKubeAPI.GitOpsPerfApps, count: Int) async {
        let gitOps = page.gitOps
        let summarised = Set(gitOps.objects.filter { $0.role == .application }.map(\.ref.name))
        // Summarised, healthy now, turning Degraded; and healthy ones only touched.
        let healthy = (0..<count).filter { !made.degraded.contains($0) && !made.drifting.contains($0) }
        let degrading = healthy.filter { summarised.contains(made.names[$0]) }.prefix(50).map { made.names[$0] }
        let touched = healthy.map { made.names[$0] }.filter { !degrading.contains($0) }.prefix(450)
        check("the burst's 500 picked", degrading.count == 50 && touched.count == 450, "\(degrading.count) + \(touched.count)")
        fake.forgetRequests()
        let failedBefore = gitOps.rows.shown.filter { $0.state == .failed }.count
        let stall = MainThreadStall()
        stall.start()
        let started = CACurrentMediaTime()
        let sending = Task.detached {
            for name in touched { fake.touchApplication(name, degrade: false) }
            for name in degrading { fake.touchApplication(name, degrade: true) }
        }
        _ = await sending.value
        let degraded = Set(degrading)
        let applied = await eventually(20) {
            gitOps.rows.shown.filter { degraded.contains($0.ref.name) && $0.state == .failed && $0.summarised }.count == degrading.count
        }
        let burstTime = (CACurrentMediaTime() - started) * 1000
        let held = stall.stop()
        check(
            "the burst's 50 Degraded read again and Failed", applied,
            "\(gitOps.rows.shown.filter { degraded.contains($0.ref.name) && $0.state == .failed }.count) of 50; \(gitOps.rows.shown.filter { $0.state == .failed }.count - failedBefore) more failing")
        note("kubernetes GitOps burst of \(touched.count + degrading.count) events applied in \(Int(burstTime)) ms, the main thread held at most \(Int(held)) ms")
        check("in under 3 s", burstTime < 3000, "\(Int(burstTime)) ms")
        // The table's visible rows made again as rows turn Failed (a reload)
        // is most of what is left; one GET ranked and drawn at a time held
        // it 500–800 ms and took 7–8 s (G8's finding).
        check("the main thread never held 500 ms", held < 500, "\(Int(held)) ms")
        await pause(1)
        let gets = fake.requests.filter { Self.isApplicationGet($0) }.map { String($0.path.split(separator: "/").last ?? "") }
        note("kubernetes GitOps burst: \(gets.count) GETs, at most \(gitOps.mostInFlight) in flight, \(gitOps.mostTaken) a flush")
        check("only the moved rows read again, each once", Set(gets) == degraded && gets.count == degraded.count, "\(gets.count) GETs: \(Set(gets).subtracting(degraded).sorted().prefix(5))")
        check("at most 4 in flight", gitOps.mostInFlight <= KubeGitOpsSession.inFlight, "\(gitOps.mostInFlight)")
        check("at most 20 a flush", gitOps.mostTaken <= KubeGitOpsRefetch.perFlush, "\(gitOps.mostTaken)")
        check("still by the one follow", !fake.requests.contains { $0.isWatch && $0.path.contains("argoproj.io") }, "\(fake.requests.filter(\.isWatch).map(\.path))")
    }

    /// The section's table scrolled top to bottom with Ready shown: 1,000 rows.
    private func gitOpsScroll() async {
        let page = app.kubernetesPage
        page.gitOpsView.hideReady = false
        defer { page.gitOpsView.hideReady = nil }
        var table: NSTableView?
        _ = await eventually(10) {
            table = self.gitOpsTable()
            return table?.numberOfRows == page.gitOpsVisibleRows.count && page.gitOpsVisibleRows.count >= 1000
        }
        guard let table, let scroll = table.enclosingScrollView, let view = app.kubernetesView else { return check("the section's table", false) }
        var samples: [Double] = []
        var y: CGFloat = 0
        for _ in 0..<1000 {
            let height = scroll.documentView?.frame.height ?? 0
            let visible = scroll.contentView.bounds.height
            guard y + visible < height else { break }
            y += visible / 3
            let start = CACurrentMediaTime()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            samples.append((CACurrentMediaTime() - start) * 1000)
            await Task.yield()
        }
        let scrolled = Self.summary(samples)
        note("kubernetes GitOps scrolled: \(table.numberOfRows) rows, \(samples.count) steps, \(scrolled)")
        check("scrolls in under 35 ms a step (p95)", samples.count > 5 && scrolled.p95 < 35, "\(scrolled)")
    }

    private func gitOpsTable() -> NSTableView? {
        guard let view = app.kubernetesView else { return nil }
        var found: NSTableView?
        func walk(_ view: NSView) {
            if found != nil { return }
            if let table = view as? NSTableView, table.accessibilityIdentifier() == "kubernetes.gitops", !table.isHiddenOrHasHiddenAncestor {
                found = table
                return
            }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }
}

/// How long the main thread was held at most while it ran: a timer on the
/// main run loop every 10 ms, the longest gap between its firings taken
/// (the scenario's own awaits yield, so a gap is work that didn't).
@MainActor
final class MainThreadStall {
    private var timer: Timer?
    private var last = CACurrentMediaTime()
    private var longest: Double = 0

    func start() {
        last = CACurrentMediaTime()
        longest = 0
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func fired() {
        let now = CACurrentMediaTime()
        longest = max(longest, (now - last) * 1000)
        last = now
    }

    /// The longest gap, in ms.
    func stop() -> Double {
        timer?.invalidate()
        timer = nil
        fired()
        return longest
    }
}
