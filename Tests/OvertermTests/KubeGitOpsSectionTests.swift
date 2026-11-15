import Foundation
import XCTest

@testable import Overterm

/// The GitOps section's rows, chips and words (docs/design/kubernetes/
/// gitops.md, 2.1–2.7, 8.1), R3's policy (3.1) and the controllers'
/// banner: pure, over `FakeKubeAPI+GitOps`'s objects read as a GET
/// answers them, without a server.
final class KubeGitOpsSectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let c = FakeKubeAPI.GitOpsCommit.self

    private func fixtures() throws -> [KubeGitOpsObject] {
        let fake = FakeKubeAPI(socket: nil)
        fake.addGitOpsFixtures(now: now)
        var objects: [KubeGitOpsObject] = []
        for kind in KubeGitOpsSummary.summarised {
            for name in fake.names(kind.fullName) {
                for namespace in ["argocd", "team-a", "flux-system"] {
                    guard let whole = fake.object(kind.fullName, name, namespace: namespace) else { continue }
                    objects.append(try XCTUnwrap(try KubeGitOpsSummary.object(try JSONSerialization.data(withJSONObject: whole), readAt: now)))
                }
            }
        }
        return KubeGitOpsSummary.ranked(objects, now: now)
    }

    private func row(_ rows: [KubeGitOpsRow], _ kind: String, _ name: String) throws -> KubeGitOpsRow {
        try XCTUnwrap(rows.first { $0.key.kind == kind && $0.ref.name == name }, "\(kind) \(name)")
    }

    private func has(_ rows: [KubeGitOpsRow], _ kind: String, _ name: String) -> Bool {
        rows.contains { $0.key.kind == kind && $0.ref.name == name }
    }

    private static let argoColumns = [
        KubeColumn(name: "Name", format: "name"), KubeColumn(name: "Sync Status"), KubeColumn(name: "Health Status"), KubeColumn(name: "Revision", priority: 10),
        KubeColumn(name: "Age", type: "date"),
    ]
    private static let fluxColumns = [KubeColumn(name: "Name", format: "name"), KubeColumn(name: "Age", type: "date"), KubeColumn(name: "Ready"), KubeColumn(name: "Status")]

    private func liveRow(_ name: String, namespace: String = "argocd", _ cells: [String]) -> KubeRow {
        KubeRow(id: KubeRowID(namespace: namespace, name: name), cells: [.text(name)] + cells.map(KubeCell.text))
    }

    private func table(_ columns: [KubeColumn], _ rows: [KubeRow]) -> KubeRows { KubeRows(KubeTable(columns: columns, rows: rows)) }

    // MARK: The section, its key

    func testTheSectionsKeyIsGAndTheDigitsStay() {
        XCTAssertEqual(KubeSection.gitops.key, "g")
        XCTAssertEqual(KubeSection.forwards.key, "9", "Forwards stays on 9")
        XCTAssertEqual(KubeSection.helm.key, "8")
        XCTAssertEqual(KubeSection.gitops.title, "GitOps")
        XCTAssertFalse(KubeSection.gitops.listsKinds, "a summary, not a kind list (decision 2)")
        XCTAssertEqual(KubeSection.allCases.firstIndex(of: .gitops), KubeSection.allCases.firstIndex(of: .helm).map { $0 + 1 }, "between Helm and Forwards")
        guard case .section(.gitops) = KubernetesKey.press("g", sheetShowing: false) else { return XCTFail("g is GitOps") }
        XCTAssertEqual(KubernetesKey.gitops.group, .sections)
        XCTAssertTrue(KubernetesKey.isWellFormed, "no key twice")
        XCTAssertEqual(KubeCommand.parse(":gitops")?.action, .gitops(nil))
        XCTAssertEqual(KubeCommand.parse(":argo")?.action, .gitops(.argo))
        XCTAssertEqual(KubeCommand.parse(":flux")?.action, .gitops(.flux))
        let bar = KubeCommandBar(kinds: [], namespaces: [], contexts: [])
        var typed = bar
        typed.text = "gito"
        XCTAssertEqual(typed.results.first?.text, "gitops", "completed in the bar")
    }

    // MARK: Rows

    func testRowsAreKeptByScopeInDisplayOrder() throws {
        let all = try fixtures()
        let rows = KubeGitOpsSection.rows(summaries: all, live: [:], listed: [], scope: .namespace("shop"), now: now)
        let shown = rows.shown
        XCTAssertTrue(has(shown, "Application", "acme-shop-prod"), "by its destination's managed namespace")
        XCTAssertTrue(has(shown, "Kustomization", "acme-apps"), "by its inventory")
        XCTAssertFalse(has(shown, "Application", "acme-remote"), "deploys to another cluster")
        XCTAssertEqual(try row(shown, "Kustomization", "acme-cron").state, .failed)
        XCTAssertEqual(try row(shown, "Kustomization", "acme-api").state, .blocked)
        XCTAssertTrue(try row(shown, "Kustomization", "acme-web").why.contains("acme-infra"), "the chain names its first link")
        // Problems first, the oldest problem first within a state.
        let states = shown.map(\.state)
        XCTAssertEqual(states, states.sorted(), "\(states)")
        let failed = shown.filter { $0.state == .failed }.compactMap(\.since)
        XCTAssertEqual(failed, failed.sorted())
        XCTAssertTrue(rows.notPlaced.isEmpty)
        XCTAssertEqual(KubeGitOpsSection.rows(summaries: all, live: [:], listed: [], scope: .all, now: now).shown.count, all.count)
    }

    func testTheColumnsSayWhereFromAndWhatIsApplied() throws {
        let rows = KubeGitOpsSection.rows(summaries: try fixtures(), live: [:], listed: [], scope: .all, now: now).shown
        let web = try row(rows, "Application", "acme-web")
        XCTAssertEqual(web.into, "→ shop")
        XCTAssertEqual(web.revision, "5d0c1e2 → 77e1a02", "live → target while OutOfSync")
        XCTAssertEqual(web.source, "acme/fleet apps/web @main", "host-less")
        XCTAssertEqual(try row(rows, "Application", "acme-shop-prod").revision, "a77b0d1")
        XCTAssertEqual(try row(rows, "Application", "acme-api").source, "2 sources")
        XCTAssertEqual(try row(rows, "Application", "acme-remote").into, "⇢ https://fake-prod.example:6443")
        let apps = try row(rows, "Kustomization", "acme-apps")
        XCTAssertEqual(apps.into, "shop", "no targetNamespace: what it manages")
        XCTAssertEqual(apps.revision, "main@a77b0d1")
        XCTAssertEqual(apps.source, "acme/shop ./deploy/fake-dev @main", "through its GitRepository, its token never said")
        let cron = try row(rows, "Kustomization", "acme-cron")
        XCTAssertEqual(cron.revision, "main@a77b0d1", "Flux: what is applied")
        XCTAssertEqual(try row(rows, "HelmRelease", "acme-payments").revision, "1.4.2")
        XCTAssertEqual(try row(rows, "HelmRelease", "acme-payments").source, "payments@1.5.0")
        XCTAssertEqual(try row(rows, "GitRepository", "acme-fleet").revision, "main@a77b0d1")
        XCTAssertEqual(try row(rows, "GitRepository", "acme-fleet").source, "acme/shop @main")
        let all = rows.map { "\($0.why) \($0.source) \($0.hover) \($0.into) \($0.revision)" }.joined(separator: "\n")
        XCTAssertFalse(all.contains(FakeKubeAPI.gitOpsSentinel), "the sentinel never in a row's text or hover")
        XCTAssertFalse(all.contains("ghp_fake"), "nor a URL's token")
        XCTAssertTrue(rows.allSatisfy { $0.why.count <= KubeGitOpsMessage.rowLimit && $0.hover.utf8.count <= KubeGitOpsMessage.hoverLimit })
    }

    func testLiveRowsWithoutASummaryAndRowsDeleted() throws {
        let all = try fixtures()
        let apps = table(
            Self.argoColumns,
            [
                liveRow("acme-shop-prod", ["Synced", "Healthy", c.applied, "3m"]),
                liveRow("acme-unsummarised", ["OutOfSync", "Degraded", c.target, "1m"]),
            ])
        let live = ["applications.argoproj.io": apps]
        let listed: Set<String> = ["applications.argoproj.io"]
        let shop = KubeGitOpsSection.rows(summaries: all, live: live, listed: listed, scope: .namespace("shop"), now: now)
        XCTAssertFalse(has(shop.shown, "Application", "acme-web"), "a listed kind's summary with no row was deleted")
        XCTAssertTrue(has(shop.shown, "Application", "acme-shop-prod"))
        XCTAssertTrue(has(shop.shown, "Kustomization", "acme-apps"), "a kind not followed keeps its summaries")
        let unplaced = try row(shop.notPlaced, "Application", "acme-unsummarised")
        XCTAssertEqual(unplaced.state, .failed, "its state from its cells alone")
        XCTAssertEqual(unplaced.why, "OutOfSync, Degraded …")
        XCTAssertFalse(unplaced.summarised)
        XCTAssertFalse(has(shop.shown, "Application", "acme-unsummarised"), "never implied in or out")
        let everywhere = KubeGitOpsSection.rows(summaries: all, live: live, listed: listed, scope: .all, now: now)
        XCTAssertTrue(has(everywhere.shown, "Application", "acme-unsummarised"), "All Namespaces keeps everything")
        XCTAssertTrue(everywhere.notPlaced.isEmpty)
    }

    func testCellsAloneAndHealth() {
        func state(_ resource: String, _ columns: [KubeColumn], _ cells: [String]) -> KubeGitOpsState {
            KubeGitOpsSection.cellState(resource: resource, liveRow("x", cells), columns: columns).0
        }
        let app = "applications.argoproj.io"
        let ks = "kustomizations.kustomize.toolkit.fluxcd.io"
        XCTAssertEqual(state(app, Self.argoColumns, ["Synced", "Healthy", "", ""]), .ready)
        XCTAssertEqual(state(app, Self.argoColumns, ["OutOfSync", "Healthy", "", ""]), .unknown, "auto-sync isn't in the cells: never Drift from them")
        XCTAssertEqual(state(app, Self.argoColumns, ["OutOfSync", "Progressing", "", ""]), .progressing)
        XCTAssertEqual(state(ks, Self.fluxColumns, ["", "True", "Applied"]), .ready)
        XCTAssertEqual(state(ks, Self.fluxColumns, ["", "False", "boom"]), .failed)
        XCTAssertEqual(state(ks, Self.fluxColumns, ["", "Unknown", ""]), .progressing)
        XCTAssertTrue(KubeGitOpsSection.healthy(resource: app, liveRow("x", ["Synced", "Healthy", "", ""]), columns: Self.argoColumns))
        XCTAssertFalse(KubeGitOpsSection.healthy(resource: app, liveRow("x", ["OutOfSync", "Healthy", "", ""]), columns: Self.argoColumns))
        XCTAssertFalse(KubeGitOpsSection.healthy(resource: ks, liveRow("x", ["", "False", ""]), columns: Self.fluxColumns))
        XCTAssertEqual(
            KubeGitOpsSection.cellsKey(liveRow("x", ["5m", "True", "ok"]), columns: Self.fluxColumns), ["x", "True", "ok"], "a date column left out")
        let token = KubeGitOpsSection.cellState(resource: ks, liveRow("x", ["", "False", "clone 'https://bot:ghp_fake@git.acme.example/x.git' failed"]), columns: Self.fluxColumns)
        XCTAssertFalse(token.1.contains("ghp_fake"), token.1)
    }

    // MARK: Chips, filters, words

    func testChipsHideReadyAndFilters() throws {
        let rows = KubeGitOpsSection.rows(summaries: try fixtures(), live: [:], listed: [], scope: .all, now: now)
        let chips = KubeGitOpsSection.chips(rows.shown)
        XCTAssertEqual(chips.map(\.state), chips.map(\.state).sorted(), "display order")
        XCTAssertEqual(chips.reduce(0) { $0 + $1.count }, rows.shown.count)
        XCTAssertEqual(KubeGitOpsSection.chipText(.failed, 2), "2 failing")
        let failed = KubeGitOpsSection.visible(rows, chip: .failed, hideReady: false, tool: nil, notPlaced: false, text: "")
        XCTAssertTrue(!failed.isEmpty && failed.allSatisfy { $0.state == .failed })
        let hidden = KubeGitOpsSection.visible(rows, chip: nil, hideReady: true, tool: nil, notPlaced: false, text: "")
        XCTAssertFalse(hidden.contains { $0.state == .ready })
        XCTAssertTrue(
            KubeGitOpsSection.visible(rows, chip: .ready, hideReady: true, tool: nil, notPlaced: false, text: "").allSatisfy { $0.state == .ready },
            "the Ready chip shows them")
        XCTAssertTrue(KubeGitOpsSection.visible(rows, chip: nil, hideReady: false, tool: .flux, notPlaced: false, text: "").allSatisfy { $0.tool == .flux })
        XCTAssertEqual(
            KubeGitOpsSection.visible(rows, chip: nil, hideReady: false, tool: nil, notPlaced: false, text: "cron").map(\.ref.name), ["acme-cron"])
    }

    func testTheHeaderTheEmptyScopeAndTheLines() throws {
        XCTAssertEqual(
            KubeGitOpsSection.header(argo: 2, flux: 6, summarisedAt: now.addingTimeInterval(-180), summarising: false, now: now),
            "Argo CD 2 kinds · Flux 6 kinds · summarised 3m ago")
        XCTAssertEqual(KubeGitOpsSection.header(argo: 0, flux: 1, summarisedAt: nil, summarising: true, now: now), "Flux 1 kind · summarising…")
        let rows = KubeGitOpsSection.rows(summaries: try fixtures(), live: [:], listed: [], scope: .namespace("default"), now: now)
        XCTAssertTrue(rows.shown.isEmpty)
        let hint = KubeGitOpsSection.emptyHint(rows, scope: .namespace("default"))
        XCTAssertEqual(hint.namespace, "flux-system", "where most of them are: \(hint.text)")
        XCTAssertTrue(hint.text.hasPrefix("No GitOps object lives in or deploys into default."), hint.text)
        let argo = KubeGitOpsSection.rows(
            summaries: try fixtures().filter { $0.tool == .argo }, live: [:], listed: [], scope: .namespace("default"), now: now)
        XCTAssertEqual(KubeGitOpsSection.emptyHint(argo, scope: .namespace("default")).text, "No GitOps object lives in or deploys into default. Argo CD's Applications are in argocd.")
        let all = KubeGitOpsSection.rows(summaries: try fixtures(), live: [:], listed: [], scope: .all, now: now).shown
        XCTAssertEqual(
            KubeGitOpsSection.cliLine(try row(all, "Kustomization", "acme-api"), context: "kind-fake"),
            "flux get kustomization acme-api -n flux-system --context kind-fake")
        XCTAssertEqual(
            KubeGitOpsSection.cliLine(try row(all, "Application", "acme-web"), context: "kind-fake"),
            "argocd app get acme-web --app-namespace argocd --core --kube-context kind-fake")
        XCTAssertEqual(
            KubeGitOpsSection.cliLine(try row(all, "GitRepository", "acme-fleet"), context: "acme ctx"),
            "flux get source git acme-fleet -n flux-system --context 'acme ctx'")
        XCTAssertNil(KubeGitOpsSection.cliLine(try row(all, "ApplicationSet", "acme-envs"), context: "kind-fake"), "kubectl's instead")
    }

    // MARK: R3

    func testRefetchesAtMostTwentyAFlushProblemsFirstOnceEveryFifteenSeconds() {
        var refetch = KubeGitOpsRefetch()
        func key(_ n: Int) -> KubeGitOpsObject.Key { KubeGitOpsObject.Key(kind: "Application", namespace: "argocd", name: "app-\(n)") }
        for n in 0..<25 { refetch.ask(key(n), .other) }
        for n in 25..<30 { refetch.ask(key(n), .problem) }
        refetch.ask(key(99), .periodic)
        let first = refetch.take(now: now)
        XCTAssertEqual(first.count, 20, "at most 20 a flush")
        XCTAssertEqual(Set(first.prefix(5)), Set((25..<30).map(key)), "problems first")
        XCTAssertFalse(first.contains(key(99)), "the periodic ones last")
        let second = refetch.take(now: now.addingTimeInterval(0.25))
        XCTAssertEqual(second.count, 11, "the rest at the next flush")
        refetch.ask(key(0), .problem)
        XCTAssertEqual(refetch.take(now: now.addingTimeInterval(5)), [], "a second change within 15 s waits")
        XCTAssertEqual(refetch.take(now: now.addingTimeInterval(15)), [key(0)])
    }

    func testWhatAsksForAnObjectAgain() throws {
        let all = try fixtures()
        let app = "applications.argoproj.io"
        var prod = try XCTUnwrap(all.first { $0.ref.name == "acme-shop-prod" })
        let healthy = liveRow("acme-shop-prod", ["Synced", "Healthy", c.applied, "3m"])
        prod.cells = KubeGitOpsSection.cellsKey(healthy, columns: Self.argoColumns)
        XCTAssertNil(
            KubeGitOpsRefetch.reason(added: false, resource: app, row: healthy, columns: Self.argoColumns, summary: prod),
            "a healthy row's new resourceVersion: nothing")
        let aged = liveRow("acme-shop-prod", ["Synced", "Healthy", c.applied, "4m"])
        XCTAssertNil(KubeGitOpsRefetch.reason(added: false, resource: app, row: aged, columns: Self.argoColumns, summary: prod), "a new Age either")
        let moved = liveRow("acme-shop-prod", ["Synced", "Healthy", c.target, "4m"])
        XCTAssertEqual(KubeGitOpsRefetch.reason(added: false, resource: app, row: moved, columns: Self.argoColumns, summary: prod), .other, "a cell moved")
        let outOfSync = liveRow("acme-admin", ["OutOfSync", "Healthy", c.target, "4m"])
        var admin = try XCTUnwrap(all.first { $0.ref.name == "acme-admin" })
        admin.cells = KubeGitOpsSection.cellsKey(outOfSync, columns: Self.argoColumns)
        XCTAssertEqual(
            KubeGitOpsRefetch.reason(added: false, resource: app, row: outOfSync, columns: Self.argoColumns, summary: admin), .problem,
            "a row that isn't healthy: any change")
        XCTAssertEqual(KubeGitOpsRefetch.reason(added: true, resource: app, row: healthy, columns: Self.argoColumns, summary: nil), .other, "added, not summarised")
        let globex = try XCTUnwrap(all.first { $0.ref.name == "globex-batch" })
        XCTAssertFalse(KubeGitOpsRefetch.inProgress(globex, now: now.addingTimeInterval(30)))
        XCTAssertTrue(KubeGitOpsRefetch.inProgress(globex, now: now.addingTimeInterval(61)), "in progress: every 60 s")
        XCTAssertFalse(KubeGitOpsRefetch.inProgress(prod, now: now.addingTimeInterval(600)))
    }

    // MARK: The controllers

    func testAControllerNotReadyIsSaidOnce() {
        let columns = [KubeColumn(name: "Name", format: "name"), KubeColumn(name: "Ready"), KubeColumn(name: "Up-to-date"), KubeColumn(name: "Available")]
        let rows = table(
            columns,
            [
                liveRow("kustomize-controller", namespace: "flux-system", ["0/1", "1", "0"]), liveRow("source-controller", namespace: "flux-system", ["1/1", "1", "1"]),
                liveRow("weave-gitops", namespace: "flux-system", ["0/1", "1", "0"]),
            ])
        let found = KubeGitOpsControllers.controllers(rows, kind: "deployments", namespace: "flux-system", tool: .flux)
        XCTAssertEqual(found.map(\.name), ["kustomize-controller", "source-controller"], "only the tool's controllers")
        XCTAssertEqual(KubeGitOpsControllers.banner(found), "kustomize-controller 0/1 ready in flux-system — Flux's states below may be stale")
        XCTAssertEqual(KubeGitOpsControllers.stale(found), [.flux])
        XCTAssertNil(KubeGitOpsControllers.banner(found.filter(\.ready)))
        XCTAssertEqual(KubeGitOpsControllers.argoNamespace(applications: ["argocd", "team-a", "team-a"]), "team-a")
        XCTAssertEqual(KubeGitOpsControllers.argoNamespace(applications: []), "argocd")
    }
}
