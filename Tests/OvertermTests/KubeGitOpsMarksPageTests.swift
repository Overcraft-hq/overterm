import Foundation
import XCTest

@testable import Overterm

/// The GitOps section on a spoke, through the page (docs/design/
/// kubernetes/gitops.md, 14.2, stage D3) against the fake API server —
/// never a real cluster: no Argo CD and no Flux are served, only the marks
/// Argo CD leaves on what it deploys (`FakeKubeAPI.addSpoke`). `g`,
/// `:gitops` and `:argo` open the section, `:flux` is refused; the GitOps
/// row shows once a list's rows have shown a mark; its rows are the apps
/// read from marks, problems first; on such a row `r`, `p`, ⌫, `s` and ⇧K
/// do nothing and send nothing — on a writable context and on production —,
/// `k` copies argocd's line without `--core`, its menu has no write, ↩
/// opens its placeholder detail and Esc closes it. Beside Applications
/// read, R2's cut at 500 doesn't keep R1's whole list from deriving the
/// apps it doesn't hold.
@MainActor
final class KubeGitOpsMarksPageTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!
    private var spoke = FakeKubeAPI.Spoke()

    override func setUp() async throws {
        socket = "/tmp/otgmp-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        spoke = api.addSpoke(FakeKubeAPI.SpokeOptions(apps: 8, otherInstallation: 2))
    }

    override func tearDown() async throws {
        if let api {
            XCTAssertFalse(api.requests.contains { $0.path.contains("/secrets") || $0.path.contains("/configmaps") }, "never a Secret or a ConfigMap")
            api.stop()
        }
    }

    private final class Box {
        var confirmations: [(KubeWriteConfirmation, (KubeWriteAnswer) -> Void)] = []
        var confirms: [String] = []
        var commands: [String] = []
        var copied: [String] = []
    }

    private func page(current: String) async throws -> (KubernetesPageModel, Box) {
        let model = KubernetesModel(proxies: KubeProxies())
        let list = KubeContextList(contexts: ["fake-dev", "fake-prod", "kind-fake"].map { KubeWritesTests.context($0) }, current: current)
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.flushInterval = .milliseconds(20)
        model.statusInterval = .milliseconds(50)
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name, writable: context.isWritable) }
        model.statusOverride = { _ in .open }
        model.access.run = { _, _, _ in .yes }
        let page = KubernetesPageModel(model: model)
        page.gitOps.flushInterval = .milliseconds(20)
        page.gitOps.marked.flushInterval = .milliseconds(20)
        let box = Box()
        var actions = KubernetesActions(run: { _ in }, settings: {}, copy: { box.copied.append($0) }, copySecret: { _ in })
        actions.confirmWrite = { confirmation, then in box.confirmations.append((confirmation, then)) }
        actions.confirm = { _, detail, _, _ in box.confirms.append(detail) }
        actions.runInTab = { command, _, _ in box.commands.append(command) }
        page.actions = actions
        page.visible = true
        model.show()
        try await until("listed") { model.selectedName == current && model.discovery?.kind("deploy") != nil }
        // The spoke's apps are across its team namespaces, not the context's own.
        model.setScope(.all)
        return (page, box)
    }

    private func until(_ what: String, _ timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The section on, its apps from marks in.
    private func section(_ page: KubernetesPageModel) async throws {
        XCTAssertTrue(page.press("g"))
        XCTAssertEqual(page.section, .gitops)
        XCTAssertNil(page.commandProblem, "g opens it: never \"neither is served\"")
        try await until("the apps read from marks") {
            page.gitOps.marksMode == .only(.notServed) && page.gitOps.marked.state == .live && page.gitOps.rows.shown.count >= self.spoke.apps.count
        }
    }

    private func derivedRow(_ page: KubernetesPageModel, _ instance: String? = nil) throws -> KubeGitOpsRow {
        try XCTUnwrap(page.gitOps.rows.shown.first { $0.isMarked && (instance == nil || $0.marked?.key.instance == instance) }, instance ?? "a derived row")
    }

    // MARK: g, the row, the commands

    func testGOpensTheSectionWhereArgoCDIsntServedAndItsRowShowsOnceAMarkIsSeen() async throws {
        let (page, _) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        XCTAssertFalse(page.gitOpsServed)
        XCTAssertFalse(page.gitOpsListed, "no list has shown a mark yet: the row stays hidden")
        // A Deployments list with metadata shows a mark: the row shows.
        page.showKind(try XCTUnwrap(page.model.discovery?.kind("deploy")))
        try await until("a mark seen") { page.model.marksSeen.contains("kind-fake") }
        XCTAssertTrue(page.gitOpsListed)
        try await section(page)
        XCTAssertTrue(page.gitOps.rows.shown.allSatisfy(\.isMarked), "Argo CD's whole side: the apps read from marks")
        XCTAssertTrue(Set(page.gitOps.rows.shown.compactMap { $0.marked?.key.instance }).isSuperset(of: spoke.apps))
        let states = page.gitOps.rows.shown.map(\.state)
        XCTAssertEqual(states, states.sorted(), "problems first")
        XCTAssertFalse(api.requests.contains { $0.path.contains("argoproj.io") || $0.path.contains("fluxcd.io") }, "nothing of Argo CD's or Flux's asked")
        XCTAssertTrue(page.gitOpsInstallations, "hub-b marks two apps: two installations")
        page.gitOpsView.groupBy = .destination
        page.cycleGitOpsGrouping()
        XCTAssertEqual(page.gitOpsView.groupBy, .installation, "G offers the installation")
        page.cycleGitOpsGrouping()
        XCTAssertEqual(page.gitOpsView.groupBy, KubeGitOpsGroupBy.none)
        // :flux refused, :argo and :gitops open it.
        XCTAssertEqual(page.run(try XCTUnwrap(KubeCommand.parse(":flux"))), "Flux isn't served by kind-fake.")
        XCTAssertNil(page.run(try XCTUnwrap(KubeCommand.parse(":argo"))))
        XCTAssertEqual(page.section, .gitops)
        XCTAssertEqual(page.gitOpsView.tool, .argo)
        XCTAssertFalse(page.gitOpsVisibleRows.isEmpty, "tool:argo keeps the apps read from marks")
        XCTAssertNil(page.run(try XCTUnwrap(KubeCommand.parse(":gitops"))))
        XCTAssertEqual(page.gitOpsView.tool, nil)
        XCTAssertTrue(api.writes.isEmpty)
    }

    func testAFluxFilterLeftFromAnotherContextGoesWhereFluxIsntServed() async throws {
        let (page, _) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        page.gitOpsView.tool = .flux
        page.showSection(.gitops)
        XCTAssertEqual(page.section, .gitops)
        XCTAssertNil(page.gitOpsView.tool, "g shows what is here")
        XCTAssertEqual(KubernetesPageModel.gitOpsRefusal(tool: .argo, discovery: page.model.discovery, context: "kind-fake"), nil)
        XCTAssertEqual(KubernetesPageModel.gitOpsRefusal(tool: nil, discovery: page.model.discovery, context: "kind-fake"), nil)
        XCTAssertNil(KubernetesPageModel.gitOpsRefusal(tool: .flux, discovery: nil, context: "kind-fake"), "not known yet: not refused")
    }

    // MARK: A derived row's keys

    /// On a writable context and on production: `r`, `p`, ⌫, `s` and ⇧K
    /// do nothing and send nothing; `a` waits for D6.
    func testOnADerivedRowNoKeyWritesOrAsks() async throws {
        for context in ["kind-fake", "fake-prod"] {
            let (page, box) = try await page(current: context)
            try await section(page)
            let row = try derivedRow(page)
            page.gitOpsView.selection = [row.id]
            XCTAssertNil(page.gitOpsSelectedRef, "no object of its own: nothing to write to")
            XCTAssertNil(page.writeTarget)
            api.forgetRequests()
            for key in ["r", "p", "\u{7F}", "s", "K", "+", "-", "a"] {
                page.writeStatus = nil
                XCTAssertFalse(page.press(key), "\(key) does nothing on \(context)")
                XCTAssertNil(page.writeStatus, key)
            }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(box.confirmations.isEmpty && box.confirms.isEmpty && box.commands.isEmpty, "nothing asked, nothing run")
            XCTAssertEqual(api.writes, [], "nothing sent, not even a review")
            XCTAssertTrue(box.copied.isEmpty, "⇧K copies no kubectl line")
            page.model.hide()
        }
    }

    func testKCopiesArgocdWithoutCoreAndTheMenuHasNoWrite() async throws {
        let (page, box) = try await page(current: "fake-prod")
        defer { page.model.hide() }
        try await section(page)
        let instance = try XCTUnwrap(spoke.apps.first)
        let row = try derivedRow(page, instance)
        page.gitOpsView.selection = [row.id]
        XCTAssertTrue(page.press("k"))
        XCTAssertEqual(box.copied.last, "argocd app get \(instance)")
        XCTAssertFalse(box.copied.last?.contains("--core") ?? true)
        XCTAssertFalse(box.copied.last?.contains("--kube-context") ?? true)
        let verbs = page.gitOpsVerbs(for: [row.id])
        XCTAssertEqual(verbs.map(\.title), ["Open", "Copy as argocd (against your Argo CD server)", "Copy Name"])
        let writes = Set(KubernetesPageModel.writeVerbOrder.map(\.title))
        XCTAssertTrue(verbs.allSatisfy { !writes.contains($0.title) && $0.place != .remove }, "no write in its menu")
        verbs[1].perform()
        XCTAssertEqual(box.copied.last, "argocd app get \(instance)")
        XCTAssertEqual(api.writes, [])
    }

    func testReturnOpensItsPlaceholderDetailAndEscClosesIt() async throws {
        let (page, _) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        try await section(page)
        let row = try derivedRow(page)
        page.gitOpsView.selection = [row.id]
        XCTAssertTrue(page.press("\r"))
        XCTAssertEqual(page.section, .gitops, "no kind list to open it in")
        XCTAssertNil(page.detail)
        XCTAssertEqual(page.markedDetail?.key, row.marked?.key)
        let shown = try XCTUnwrap(page.markedDetailApp)
        let detail = KubeMarkedSection.detail(shown, mode: page.gitOps.marksMode, context: "kind-fake")
        XCTAssertEqual(
            detail.absent, "Sync, Refresh, Rollback and Diff act on the Application, which is in Argo CD's cluster — not in your kubeconfig. Use Argo CD there.")
        XCTAssertTrue(page.press("\u{1B}"))
        XCTAssertNil(page.markedDetail)
        // x: its detail too (its tree comes with D4); another section closes it.
        XCTAssertTrue(page.press("x"))
        XCTAssertNotNil(page.markedDetail)
        page.showSection(.overview)
        XCTAssertNil(page.markedDetail, "the section left: its detail goes")
        XCTAssertEqual(api.writes, [])
    }

    // MARK: Beside Applications read

    /// A hub of 1,000 Applications that is also a destination: R2's
    /// summaries stop at 500, R1's rows list every one — the marked apps it
    /// doesn't hold are derived all the same, behind their chip (14.3).
    func testAThousandApplicationsCutAtFiveHundredStillDeriveTheMissing() async throws {
        api.serveArgoCD()
        let perf = api.addGitOpsPerfApplications(1000)
        XCTAssertEqual(perf.names.count, 1000)
        let (page, _) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        XCTAssertTrue(page.press("g"))
        try await until("summarised and derived", 30) {
            guard case .beside(let coexistence) = page.gitOps.marksMode else { return false }
            return !page.gitOps.summarising && !coexistence.missing.isEmpty && !page.gitOps.rows.beside.isEmpty
        }
        XCTAssertEqual(page.gitOps.objects.filter { $0.role == .application }.count, 500, "R2 cut at 500")
        XCTAssertTrue(page.gitOps.notes.contains { $0.contains("500 of") }, "\(page.gitOps.notes)")
        let derived = Set(page.gitOps.rows.beside.compactMap { $0.marked?.key.instance })
        XCTAssertTrue(derived.isSuperset(of: spoke.apps), "every marked app is missing from R1's whole list: \(derived.count)")
        XCTAssertTrue(page.gitOps.rows.beside.allSatisfy { $0.tags.contains(.text("not in this cluster")) || $0.marked?.installation != nil })
        XCTAssertEqual(Set(page.gitOps.rows.shown.filter(\.isMarked).map(\.id)), Set(page.gitOps.rows.beside.map(\.id)), "among the Applications")
        XCTAssertTrue(page.gitOps.rows.shown.contains { $0.role == .application })
        page.toggleGitOpsBeside()
        XCTAssertEqual(Set(page.gitOpsVisibleRows.map(\.id)), Set(page.gitOps.rows.beside.map(\.id)), "their chip shows them alone")
        XCTAssertEqual(api.writes, [])
    }
}
