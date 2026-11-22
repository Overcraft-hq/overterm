import Foundation
import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell
@testable import OvertermOvergit
@testable import OvertermAPI
@testable import OvertermNotes
@testable import OvertermSimulator
@testable import OvertermUsage
@testable import OvertermSettingsPage
@testable import OvertermAgents

/// The GitOps section on a spoke, through the page (docs/design/
/// kubernetes/gitops.md, 14.2, stages D3 and D4) against the fake API server —
/// never a real cluster: no Argo CD and no Flux are served, only the marks
/// Argo CD leaves on what it deploys (`FakeKubeAPI.addSpoke`). `g`,
/// `:gitops` and `:argo` open the section, `:flux` is refused; the GitOps
/// row shows once a list's rows have shown a mark; its rows are the apps
/// read from marks, problems first; on such a row `r`, `p`, ⌫, `s` and ⇧K
/// do nothing and send nothing — on a writable context and on production —,
/// `k` copies argocd's line without `--core`, its menu has no write, ↩
/// opens its detail — its tree read, no write or Application verb in any
/// menu, a node its object in its own list (its name pressed, or ↩ on it:
/// Tab into the tree, ↑ ↓ along it), whose writes say Argo CD may undo
/// them only when it is one of the app's own — never a pod, a ReplicaSet,
/// a CronJob's Job, a hook or a copy of a mark —, what it reads kept by
/// the section and never asked again — and Esc closes it. Beside
/// Applications read, R2's cut at 500 doesn't keep R1's whole list from
/// deriving the apps it doesn't hold.
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
        var briefs: [KubeAgentBrief] = []
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
        actions.askWhy = { box.briefs.append($0) }
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
    /// do nothing and send nothing (`a` asks an agent why: below).
    func testOnADerivedRowNoKeyWritesOrAsks() async throws {
        for context in ["kind-fake", "fake-prod"] {
            let (page, box) = try await page(current: context)
            try await section(page)
            let row = try derivedRow(page)
            page.gitOpsView.selection = [row.id]
            XCTAssertNil(page.gitOpsSelectedRef, "no object of its own: nothing to write to")
            XCTAssertNil(page.writeTarget)
            api.forgetRequests()
            for key in ["r", "p", "\u{7F}", "s", "K", "+", "-"] {
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
        XCTAssertEqual(verbs.map(\.title), ["Open", "Ask an Agent Why…", "Copy as argocd (against your Argo CD server)", "Copy Name"])
        let writes = Set(KubernetesPageModel.writeVerbOrder.map(\.title))
        XCTAssertTrue(verbs.allSatisfy { !writes.contains($0.title) && $0.place != .remove }, "no write in its menu")
        verbs[2].perform()
        XCTAssertEqual(box.copied.last, "argocd app get \(instance)")
        XCTAssertEqual(api.writes, [])
    }

    // MARK: Ask Why (D6)

    /// `a` on an app read from marks asks an agent why — on every one that
    /// isn't Ready, Progressing included (a `0/3` StatefulSet is never
    /// Failed under Argo CD's rules): its brief read by GETs, handed to the
    /// window, the sentinel in nothing of it; one failing Deployment its
    /// own brief with the app named; a Ready one says why not and asks
    /// nothing. Its menu's Ask an Agent Why… is greyed with why on a Ready
    /// one, and the detail's button asks the same. Nothing written.
    func testAAsksAnAgentWhyOnADerivedAppProgressingToo() async throws {
        let (page, box) = try await page(current: "fake-prod")
        defer { page.model.hide() }
        try await section(page)
        try await until("settled by their objects", 30) { page.gitOps.marked.refetchIdle && page.gitOps.marked.isMerged }
        let ledger = try derivedRow(page, spoke.statefulSet)
        XCTAssertEqual(ledger.state, .progressing)
        page.gitOpsView.selection = [ledger.id]
        api.forgetRequests()
        XCTAssertTrue(page.press("a"))
        try await until("its brief") { !box.briefs.isEmpty }
        let brief = try XCTUnwrap(box.briefs.last)
        XCTAssertEqual(brief.message, "Why is Argo CD app \(spoke.statefulSet) still Progressing — 0/3 ready, StatefulSet acme-ledger-db?")
        XCTAssertTrue(brief.text.contains("Argo CD runs in another cluster — not in your kubeconfig."), brief.text)
        XCTAssertTrue(brief.text.contains("PRODUCTION context fake-prod"), brief.text)
        XCTAssertTrue(brief.parts.first { $0.title == "pods" }?.text.contains("acme-ledger-db-0: Pending") == true, "\(brief.parts.map(\.title))")
        XCTAssertNil(page.askingWhyApp)
        XCTAssertNil(page.commandProblem)
        let whole = ([brief.message, brief.text] + brief.parts.map(\.text)).joined(separator: "\n")
        XCTAssertFalse(whole.contains(FakeKubeAPI.gitOpsSentinel), whole)
        XCTAssertTrue(api.requests.allSatisfy { $0.method == "GET" }, "\(api.requests.map(\.description))")

        // The stalled rollout: one failing Deployment, its own brief, the app named.
        let stalled = try derivedRow(page, spoke.stalled)
        page.gitOpsView.selection = [stalled.id]
        XCTAssertNil(page.gitOpsVerbs(for: [stalled.id]).first { $0.title == "Ask an Agent Why…" }?.unavailable)
        XCTAssertTrue(page.press("a"))
        try await until("its Deployment's brief") { box.briefs.count == 2 }
        XCTAssertEqual(box.briefs.last?.subject, "deploy/acme-cart ProgressDeadlineExceeded")
        XCTAssertEqual(box.briefs.last?.parts.first?.title, "Argo CD app")
        XCTAssertTrue(box.briefs.last?.text.contains("It is one of Argo CD app \(spoke.stalled)'s objects") == true, box.briefs.last?.text ?? "")

        // A Ready one: why not, over the list; nothing asked.
        let ready = try XCTUnwrap(page.gitOps.rows.shown.first { $0.isMarked && $0.state == .ready })
        page.gitOpsView.selection = [ready.id]
        let verb = try XCTUnwrap(page.gitOpsVerbs(for: [ready.id]).first { $0.title == "Ask an Agent Why…" })
        XCTAssertEqual(verb.unavailable?.hasSuffix("Ask Why is for one that isn't."), true, verb.unavailable ?? "")
        XCTAssertTrue(page.press("a"))
        XCTAssertEqual(page.commandProblem?.hasSuffix("Ask Why is for one that isn't."), true, page.commandProblem ?? "")
        XCTAssertNil(page.askingWhyApp, "no brief read for a Ready app: refused before any read")
        XCTAssertEqual(box.briefs.count, 2, "nothing asked of a Ready app")

        // The detail's button: the same brief, from the detail's reads.
        page.gitOpsView.selection = [ledger.id]
        XCTAssertTrue(page.press("\r"))
        try await until("its detail read", 30) { page.markedRead.state == .loaded }
        page.gitOpsView.selection = []
        XCTAssertTrue(page.press("a"), "the detail's app, none picked")
        try await until("the detail's brief") { box.briefs.count == 3 }
        XCTAssertEqual(box.briefs.last?.message, brief.message)
        XCTAssertEqual(api.writes, [], "nothing written")
        XCTAssertTrue(box.confirmations.isEmpty && box.confirms.isEmpty && box.commands.isEmpty, "nothing asked, nothing run")
    }

    func testReturnOpensItsDetailAndEscClosesIt() async throws {
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
        let detail = KubeMarkedAppDetail.make(shown, mode: page.gitOps.marksMode, context: "kind-fake")
        XCTAssertEqual(
            detail.absent, "Sync, Refresh, Rollback and Diff act on the Application, which is in Argo CD's cluster — not in your kubeconfig. Use Argo CD there.")
        XCTAssertTrue(page.press("\u{1B}"))
        XCTAssertNil(page.markedDetail)
        // x: its detail too (its tree is there); another section closes it.
        XCTAssertTrue(page.press("x"))
        XCTAssertNotNil(page.markedDetail)
        page.showSection(.overview)
        XCTAssertNil(page.markedDetail, "the section left: its detail goes")
        XCTAssertEqual(api.writes, [])
    }

    // MARK: The detail (D4)

    /// ↩ on the stalled app: its tree read (M4) — the Deployment Failed by
    /// its object, under it the newest ReplicaSet and the old one still
    /// serving, each carrying the Deployment's mark as a copy, their pods
    /// with their own health —, what only the Application knows, no Sync,
    /// Refresh, Rollback, Diff or write in any menu. A node opens its
    /// object in its own list: there `r` asks, saying Argo CD may undo it —
    /// nothing sent —, and `[` comes back to the app's detail. The same
    /// Deployment opened from its own list says nothing of Argo CD.
    func testReturnShowsTheTreeAndANodeOpensItsObjectWhoseWritesSayArgoCDMayUndoThem() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        try await section(page)
        // The section's own settle done: none of its GETs answers after the detail's.
        try await until("the marks settled") { page.gitOps.marked.refetchIdle && page.gitOps.marked.isMerged }
        let row = try derivedRow(page, spoke.stalled)
        page.gitOpsView.selection = [row.id]
        XCTAssertTrue(page.press("\r"))
        try await until("its objects read") { page.markedRead.state == .loaded && page.markedRead.ref?.key == row.marked?.key }
        let detail = try XCTUnwrap(page.markedDetailShown)
        XCTAssertEqual(detail.title, spoke.stalled)
        XCTAssertEqual(detail.word, "Failed")
        XCTAssertEqual(detail.lead, "Argo CD runs in another cluster — not in your kubeconfig.")
        XCTAssertTrue(detail.knows.allSatisfy { $0.place == "in the Application, in Argo CD's cluster" })
        let deployment = try XCTUnwrap(detail.tree.first { $0.kind == "Deployment" && $0.name == "acme-cart" })
        XCTAssertEqual(deployment.said(namespaced: false), "Deployment acme-cart — Degraded: rollout stalled (ProgressDeadlineExceeded)")
        XCTAssertEqual(deployment.children.map(\.name), ["acme-cart-5f8d7c", "acme-cart-7d4b9c"])
        XCTAssertTrue(deployment.children.allSatisfy { $0.note == "a copy of Deployment acme-cart's mark: not a member" }, "copies: children, never members")
        XCTAssertEqual(deployment.children.first?.children.first?.said(namespaced: false), "Pod acme-cart-5f8d7c-x2k9p — Degraded: CrashLoopBackOff")
        let service = try XCTUnwrap(detail.tree.first { $0.kind == "Service" })
        XCTAssertEqual(service.role, .ignored, "its ignore-healthcheck: grey, not counted")
        XCTAssertTrue(detail.hints.contains("sync-options Prune=false — Deployment acme-cart"), "\(detail.hints)")
        XCTAssertTrue(detail.hints.contains("link external-link: https://grafana.acme.example/d/cart?orgId=1 — Service acme-cart"), "\(detail.hints)")
        let absent: Set<String> = ["Sync", "Refresh", "Rollback", "Diff"]
        let writes = Set(KubernetesPageModel.writeVerbOrder.map(\.title))
        for node in detail.tree.flatMap(\.all) + detail.hooks {
            let titles = page.markedNodeVerbs(node).map(\.title)
            XCTAssertEqual(titles, ["Open", "Copy as kubectl", "Copy Name"], node.name)
            XCTAssertTrue(absent.isDisjoint(with: titles) && writes.isDisjoint(with: titles))
        }
        XCTAssertTrue(page.gitOpsVerbs(for: [row.id]).allSatisfy { !absent.contains($0.title) && !writes.contains($0.title) })
        // Copy Names: each of its objects.
        page.copyMarkedNames()
        XCTAssertEqual(box.copied.last, "Deployment team-2/acme-cart\nService team-2/acme-cart")

        // A node opens its object in its own list; its write says Argo CD may undo it.
        XCTAssertTrue(page.openMarkedNode(deployment))
        XCTAssertEqual(page.detail?.ref.name, "acme-cart")
        XCTAssertEqual(page.detail?.ref.kind.fullName, "deployments.apps")
        XCTAssertNotEqual(page.section, .gitops)
        XCTAssertNil(page.markedDetail, "the section left")
        XCTAssertTrue(page.press("r"))
        try await until("asked") { !box.confirmations.isEmpty }
        let asked = try XCTUnwrap(box.confirmations.last?.0)
        XCTAssertTrue(asked.detail.contains("⚠︎ Argo CD may undo this: whether selfHeal is on is in the Application, in another cluster."), asked.detail)
        // `[`: the app's detail again.
        page.goBack()
        XCTAssertEqual(page.section, .gitops)
        XCTAssertEqual(page.markedDetail?.key, row.marked?.key)
        XCTAssertNil(page.markedOrigin)
        // From its own list: nothing said of Argo CD.
        page.openFromOverview(kind: "deployments.apps", KubeRowID(namespace: "team-2", name: "acme-cart"))
        XCTAssertNil(page.markedOrigin)
        XCTAssertTrue(page.press("r"))
        try await until("asked again") { box.confirmations.count == 2 }
        XCTAssertFalse(box.confirmations[1].0.detail.contains("Argo CD may undo"), box.confirmations[1].0.detail)
        // Asked, never answered: nothing sent but the access reviews that come before a write's question.
        XCTAssertEqual(api.writes.filter { !$0.path.hasSuffix("/selfsubjectaccessreviews") }, [], "nothing sent")
    }

    /// The stalled app's detail open, its tree read.
    private func stalledDetail(_ page: KubernetesPageModel) async throws -> KubeMarkedAppDetail.Detail {
        let row = try derivedRow(page, spoke.stalled)
        page.gitOpsView.selection = [row.id]
        XCTAssertTrue(page.press("\r"))
        try await until("its objects read") { page.markedRead.state == .loaded && page.markedRead.ref?.key == row.marked?.key }
        try await until("its tree") { page.markedDetailShown?.tree.first?.children.first?.children.isEmpty == false }
        return try XCTUnwrap(page.markedDetailShown)
    }

    /// ↩ on a node (14.2.3): Tab takes the keyboard into the tree, on its
    /// first node; ↓ and ↑ walk it as it is drawn, held at either end; ↩
    /// opens the node's object in its own list, and `[` comes back with the
    /// keyboard on that node. Tab gives the rows their arrows back, so does
    /// another row picked, and Esc closes the detail. Outside the tree the
    /// arrows and ↩ are the rows'.
    func testTheKeyboardWalksTheTreeAndReturnOnANodeOpensIt() async throws {
        let (page, _) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        try await section(page)
        XCTAssertFalse(page.press("\u{F701}"), "no detail: the rows' arrow")
        XCTAssertFalse(page.press("\t"), "no detail: no tree to go into")
        let detail = try await stalledDetail(page)
        let walk = KubeMarkedAppDetail.walk(detail)
        XCTAssertEqual(
            walk.map(\.name), ["acme-cart", "acme-cart-5f8d7c", "acme-cart-5f8d7c-x2k9p", "acme-cart-7d4b9c", "acme-cart-7d4b9c-m4n8q", "acme-cart"],
            "the tree depth first, as drawn")
        XCTAssertFalse(page.press("\u{F701}"), "not in the tree: the rows' arrow")
        XCTAssertNil(page.markedNode)

        XCTAssertTrue(page.press("\t"))
        XCTAssertEqual(page.markedNode, walk[0].id, "Tab: the first node")
        XCTAssertTrue(page.press("\u{F700}"))
        XCTAssertEqual(page.markedNode, walk[0].id, "held at the top")
        for index in 1..<walk.count {
            XCTAssertTrue(page.press("\u{F701}"))
            XCTAssertEqual(page.markedNode, walk[index].id)
        }
        XCTAssertTrue(page.press("\u{F701}"))
        XCTAssertEqual(page.markedNode, walk.last?.id, "held at the end")
        for _ in 1..<walk.count { XCTAssertTrue(page.press("\u{F700}")) }
        XCTAssertEqual(page.markedNode, walk[0].id)

        // ↩: the Deployment in its own list; `[` back, the keyboard on it again.
        XCTAssertTrue(page.press("\r"))
        XCTAssertEqual(page.detail?.ref.name, "acme-cart")
        XCTAssertEqual(page.detail?.ref.kind.fullName, "deployments.apps")
        XCTAssertNotEqual(page.section, .gitops)
        XCTAssertNil(page.markedNode, "the detail closed with the section")
        XCTAssertEqual(page.markedOrigin?.node, walk[0].id)
        page.goBack()
        XCTAssertEqual(page.section, .gitops)
        XCTAssertNotNil(page.markedDetail)
        XCTAssertEqual(page.markedNode, walk[0].id, "back on the node it opened")
        // Its app being made again as the section reads: the keyboard waits on its node.
        XCTAssertTrue(page.press("\u{F701}"))
        try await until("its tree again") { page.markedDetailShown.map(KubeMarkedAppDetail.walk)?.map(\.id) == walk.map(\.id) }
        XCTAssertTrue(page.markedNode == walk[0].id || page.markedNode == walk[1].id, page.markedNode ?? "none")
        page.markedNode = walk[0].id
        XCTAssertTrue(page.press("\u{F701}"))
        XCTAssertEqual(page.markedNode, walk[1].id)

        // Tab: back to the rows; another row picked, too; Esc closes the detail.
        XCTAssertTrue(page.press("\t"))
        XCTAssertNil(page.markedNode)
        XCTAssertFalse(page.press("\u{F701}"), "the rows' arrows again")
        XCTAssertTrue(page.press("\t"))
        XCTAssertNotNil(page.markedNode)
        page.gitOpsView.selection = []
        XCTAssertNil(page.markedNode, "another row picked: the rows have the keyboard")
        XCTAssertTrue(page.press("\t"))
        XCTAssertTrue(page.press("\u{1B}"))
        XCTAssertNil(page.markedDetail)
        XCTAssertNil(page.markedNode)
        XCTAssertEqual(api.writes, [])
    }

    /// Whether a write says Argo CD may undo it (14.2.3: only from the
    /// detail, "which knows the object is a member"): a member and an
    /// `ignore-healthcheck` one say it; a pod (opened by ↩ on its node), a
    /// ReplicaSet, a CronJob's Job, a hook and a copy of a mark don't —
    /// their controller, or nobody, sets them back; Argo CD keeps no sync
    /// status of a hook or a copy. `[` comes back from each all the same.
    func testOnlyAWriteOnOneOfTheAppsOwnObjectsSaysArgoCDMayUndoIt() async throws {
        // An HPA carrying the stalled Deployment's mark, as an operator copies it.
        api.addCopiedMark("horizontalpodautoscalers.autoscaling", "acme-cart-extra", namespace: "team-2", app: spoke.stalled, of: "acme-cart", now: Date())
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        try await section(page)
        let detail = try await stalledDetail(page)
        let undone = "Argo CD may undo this: whether selfHeal is on is in the Application, in another cluster."

        /// ⌫ on what `open` opened: its confirmation, asked and never answered.
        func deleteAsked(_ name: String, _ open: () -> Bool) async throws -> String {
            let app = try XCTUnwrap(page.markedDetail)
            XCTAssertTrue(open(), name)
            XCTAssertEqual(page.detail?.ref.name, name)
            XCTAssertNotNil(page.markedOrigin, "\(name): `[` comes back to the app")
            let asked = box.confirmations.count
            XCTAssertTrue(page.press("\u{7F}"), name)
            try await until("\(name): asked") { box.confirmations.count == asked + 1 }
            page.goBack()
            XCTAssertEqual(page.markedDetail, app, "\(name): back to the app's detail")
            return try XCTUnwrap(box.confirmations.last?.0.detail)
        }

        // The pod, by the keyboard: Tab, ↓ ↓, ↩.
        let deployment = try XCTUnwrap(detail.tree.first { $0.kind == "Deployment" })
        let set = try XCTUnwrap(deployment.children.first { $0.kind == "ReplicaSet" })
        let pod = try XCTUnwrap(set.children.first)
        XCTAssertEqual(pod.name, "acme-cart-5f8d7c-x2k9p")
        let podAsked = try await deleteAsked(pod.name) {
            page.press("\t") && page.press("\u{F701}") && page.press("\u{F701}") && page.markedNode == pod.id && page.press("\r")
        }
        XCTAssertFalse(podAsked.contains("Argo CD may undo"), podAsked)
        XCTAssertEqual(page.markedNode, pod.id, "back on the pod's node")
        let setAsked = try await deleteAsked(set.name) { page.openMarkedNode(set) }
        XCTAssertFalse(setAsked.contains("Argo CD may undo"), setAsked)
        let copy = try XCTUnwrap(deployment.children.first { $0.role == .copy }, "the copy under what its mark names")
        XCTAssertEqual(copy.name, "acme-cart-extra")
        let copyAsked = try await deleteAsked(copy.name) { page.openMarkedNode(copy) }
        XCTAssertFalse(copyAsked.contains("Argo CD may undo"), copyAsked)
        // The app's own: the Deployment, and the Service its ignore-healthcheck leaves out of health only.
        let deploymentAsked = try await deleteAsked(deployment.name) { page.openMarkedNode(deployment) }
        XCTAssertTrue(deploymentAsked.contains("⚠︎ " + undone), deploymentAsked)
        let service = try XCTUnwrap(detail.tree.first { $0.kind == "Service" })
        XCTAssertEqual(service.role, .ignored)
        let serviceAsked = try await deleteAsked(service.name) { page.openMarkedNode(service) }
        XCTAssertTrue(serviceAsked.contains("⚠︎ " + undone), serviceAsked)

        // A CronJob's Job, and a hook — their apps' rows made again since the section was left.
        for (instance, what) in [(spoke.cronJob, "a CronJob's Job"), (spoke.hooked, "a hook")] {
            try await until("\(what): its app's row") { page.gitOps.rows.shown.contains { $0.marked?.key.instance == instance } }
            let row = try derivedRow(page, instance)
            let ref = KubeMarkedDetailRef(context: "kind-fake", key: try XCTUnwrap(row.marked?.key))
            page.openMarkedApp(ref)
            try await until("\(what): its app read") { page.markedRead.state == .loaded && page.markedRead.ref == ref }
            let shown = try XCTUnwrap(page.markedDetailShown)
            let node = try XCTUnwrap(KubeMarkedAppDetail.walk(shown).first { $0.kind == "Job" }, what)
            XCTAssertEqual(node.role, instance == spoke.hooked ? .hook : .owned)
            let asked = try await deleteAsked(node.name) { page.openMarkedNode(node) }
            XCTAssertFalse(asked.contains("Argo CD may undo"), "\(what): \(asked)")
            XCTAssertEqual(page.markedDetail, ref)
        }
        XCTAssertEqual(api.writes.filter { !$0.path.hasSuffix("/selfsubjectaccessreviews") }, [], "asked, never answered: nothing sent")
    }

    /// What the detail reads, the section keeps (14.4.2): the stalled
    /// Deployment's generation moves and the section's own GET of it waits
    /// (its clock held inside the object's 15 s) when Read Again reads it;
    /// the section then holds the detail's read — its time, the new
    /// generation —, has nothing waiting for it, and once its clock is
    /// past the 15 s and its tick has run, asks nothing more of it: the
    /// detail's GET is the only one.
    func testWhatTheDetailReadsTheSectionKeepsAndAsksNoMoreOf() async throws {
        let (page, _) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        try await section(page)
        let marked = page.gitOps.marked
        try await until("the marks settled") { marked.refetchIdle && marked.isMerged }
        let id = KubeMarkedMember.ID(kind: .deployment, namespace: "team-2", name: "acme-cart")
        let path = "/apis/apps/v1/namespaces/team-2/deployments/acme-cart"
        let before = try XCTUnwrap(marked.store?.settled[id], "settled by the section's own GET")
        XCTAssertEqual(before.generation, 4)
        // Its next GET held: the section's clock where it last read it.
        marked.clock = { before.at }
        api.modify("deployments.apps", "acme-cart", namespace: "team-2") { body in
            var metadata = body["metadata"] as? [String: Any] ?? [:]
            metadata["generation"] = 5
            body["metadata"] = metadata
        }
        try await until("its generation moved: the section's GET waits") { marked.isAsking(id) }
        _ = try await stalledDetail(page)
        // Read Again: the detail's own GET of each member.
        api.forgetRequests()
        page.updateMarkedDetailReading(again: true)
        XCTAssertEqual(page.markedRead.state, .loading)
        try await until("read again") { page.markedRead.state == .loaded }
        let read = try XCTUnwrap(page.markedRead.read.objects[id])
        XCTAssertGreaterThan(read.at, before.at)
        XCTAssertEqual(read.generation, 5)
        XCTAssertEqual(marked.store?.settled[id]?.at, read.at, "the section keeps the detail's read")
        XCTAssertEqual(marked.store?.settled[id]?.generation, 5)
        XCTAssertFalse(marked.isAsking(id), "its own GET forgotten")
        // Past the object's 15 s, the tick run: nothing more asked of it.
        marked.clock = { before.at.addingTimeInterval(KubeMarkedRefetch.perObject + 1) }
        marked.tick()
        try await until("the section's GETs done") { marked.refetchIdle }
        XCTAssertFalse(marked.isAsking(id))
        XCTAssertEqual(api.requests.filter { $0.path == path && !$0.isWatch }.count, 1, "the detail's GET, and no other")
        XCTAssertEqual(api.writes, [])
    }

    /// A GET of one object in a namespace: the section's M1b, M2 and M3b.
    private func objectGETs() -> [FakeKubeAPI.Request] {
        api.requests.filter { request in
            let parts = request.path.split(separator: "/").count
            return !request.isWatch && !request.isDiscovery && request.path.contains("/namespaces/")
                && ((request.path.hasPrefix("/apis/") && parts == 7) || (request.path.hasPrefix("/api/") && parts == 6))
        }
    }

    /// Its window covered and uncovered: every read ends, what the section
    /// read stays — shown again, nothing is settled again (gitops.md
    /// 14.4.2). The page hidden and shown, another context and back,
    /// within the minute (the section's clock held): what it read goes,
    /// the context's minute doesn't (`KubernetesModel.markedMinutes`, the
    /// app's) — no object of it read again; another context's its own.
    func testACoveredWindowKeepsWhatWasReadAndNoHideGivesTheMinuteAgain() async throws {
        let (page, _) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        let marked = page.gitOps.marked
        let start = Date()
        marked.clock = { start }
        XCTAssertTrue(marked.ledger === page.model.markedMinutes, "the app's minutes")
        try await section(page)
        try await until("the marks settled") { marked.isMerged && marked.refetchIdle && marked.reading.checking == nil }
        let read = objectGETs()
        XCTAssertFalse(read.isEmpty)
        // Covered: every read ends, what was read stays.
        page.windowVisible = false
        XCTAssertEqual(marked.state, .idle)
        XCTAssertNotNil(marked.store, "kept, as when the section is left")
        XCTAssertNotNil(page.gitOps.store)
        api.forgetRequests()
        page.windowVisible = true
        try await until("uncovered: shown again") { marked.state == .live && marked.isMerged && marked.refetchIdle && marked.reading.checking == nil }
        XCTAssertEqual(objectGETs().map(\.path), [], "uncovered: nothing settled again")
        // The page hidden and shown: what was read goes, the minute doesn't.
        page.visible = false
        XCTAssertNil(marked.store)
        page.visible = true
        try await until("shown again, its settle waiting") { marked.state == .live && marked.isMerged && !marked.refetchIdle && marked.getsQueued == 0 }
        XCTAssertEqual(objectGETs().map(\.path), [], "hidden and shown again within the minute: no GET")
        // Another context, its discovery not read yet: the marks start once
        // it comes, a minute of its own; then back — none again.
        page.model.select("fake-dev")
        page.model.setScope(.all)
        try await until("fake-dev's settled") {
            marked.context == "fake-dev" && page.gitOps.marksMode == .only(.notServed) && marked.state == .live && marked.isMerged && marked.refetchIdle
                && marked.reading.checking == nil
        }
        XCTAssertFalse(objectGETs().isEmpty, "fake-dev's own minute")
        api.forgetRequests()
        page.model.select("kind-fake")
        try await until("back, its settle waiting") {
            marked.context == "kind-fake" && marked.state == .live && marked.isMerged && !marked.refetchIdle && marked.getsQueued == 0
        }
        XCTAssertEqual(objectGETs().map(\.path), [], "kind-fake, fake-dev and kind-fake again within the minute: no GET")
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
        // A marked app whose Application lies past R2's cut: R1's whole list
        // holds it, R2's 500 summaries don't — presence from R2 would call
        // it missing.
        let late = try XCTUnwrap(perf.names.last)
        api.addMarkedDeployment("acme-late", namespace: "team-9", app: late, padding: 0, now: Date())
        let (page, _) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        XCTAssertTrue(page.press("g"))
        try await until("summarised and derived", 30) {
            guard case .beside(let coexistence) = page.gitOps.marksMode else { return false }
            return !page.gitOps.summarising && !coexistence.missing.isEmpty && !page.gitOps.rows.beside.isEmpty
                && page.gitOps.marked.apps.contains { $0.app.key.instance == late }
        }
        XCTAssertEqual(page.gitOps.objects.filter { $0.role == .application }.count, 500, "R2 cut at 500")
        XCTAssertTrue(page.gitOps.notes.contains { $0.contains("500 of") }, "\(page.gitOps.notes)")
        XCTAssertFalse(page.gitOps.objects.contains { $0.role == .application && $0.ref.name == late }, "past R2's cut: never summarised")
        XCTAssertFalse(page.gitOps.rows.shown.contains { $0.marked?.key.instance == late }, "R1's whole list holds its Application: not derived")
        guard case .beside(let coexistence) = page.gitOps.marksMode else { return XCTFail("\(page.gitOps.marksMode)") }
        XCTAssertFalse(coexistence.listed.contains { $0.instance == late }, "never tagged not in this cluster")
        let derived = Set(page.gitOps.rows.beside.compactMap { $0.marked?.key.instance })
        XCTAssertTrue(derived.isSuperset(of: spoke.apps), "every marked app is missing from R1's whole list: \(derived.count)")
        XCTAssertTrue(page.gitOps.rows.beside.allSatisfy { $0.tags.contains(.text("not in this cluster")) || $0.marked?.installation != nil })
        XCTAssertEqual(Set(page.gitOps.rows.shown.filter(\.isMarked).map(\.id)), Set(page.gitOps.rows.beside.map(\.id)), "among the Applications")
        XCTAssertTrue(page.gitOps.rows.shown.contains { $0.role == .application })
        page.toggleGitOpsBeside()
        XCTAssertEqual(Set(page.gitOpsVisibleRows.map(\.id)), Set(page.gitOps.rows.beside.map(\.id)), "their chip shows them alone")
        XCTAssertEqual(api.writes, [])
    }

    /// Beside Applications: a marked app's detail is open when
    /// its Application comes to be read here — R1 sees it, the mode is read
    /// again, and the detail says it is gone, never a derived app whose
    /// Application "isn't among those read" (the marks' apps hold every
    /// marked app then: only the section's rows say which are derived).
    func testTheDetailOfAnAppWhoseApplicationComesIsGone() async throws {
        api.serveArgoCD()
        let target = spoke.apps[2]
        let instances =
            spoke.apps + [spoke.stuck, spoke.stalled, spoke.paused, spoke.statefulSet, spoke.hpa, spoke.serviceOnly, spoke.loadBalancer, spoke.cronJob, spoke.claim, spoke.hooked, spoke.labelOnly]
        func application(_ name: String) {
            api.addApplication(
                name, spec: ["project": "acme", "destination": ["namespace": "team-0"], "source": ["repoURL": "https://git.acme.example/acme/fleet.git"]],
                status: ["sync": ["status": "Synced"], "health": ["status": "Healthy"]])
        }
        for name in instances where name != target { application(name) }
        let (page, _) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        XCTAssertTrue(page.press("g"))
        try await until("the one with none here, beside them", 20) {
            guard case .beside(let coexistence) = page.gitOps.marksMode else { return false }
            return coexistence.listed.map(\.instance) == [target] && page.gitOps.rows.beside.count == 1
        }
        let row = try XCTUnwrap(page.gitOps.rows.beside.first)
        XCTAssertTrue(row.tags.contains(.text("not in this cluster")))
        page.gitOpsView.selection = [row.id]
        XCTAssertTrue(page.press("\r"))
        XCTAssertEqual(page.markedDetailApp?.app.key.instance, target)
        // The marks all read and settled: nothing of theirs will move again,
        // so only R1's row follow can tell the Application came.
        try await until("the marks settled") { page.gitOps.marked.state == .live && page.gitOps.marked.refetchIdle && page.gitOps.marked.isMerged }
        application(target)
        try await until("its Application read: the detail gone") { page.markedDetailApp == nil }
        XCTAssertNotNil(page.markedDetail, "still open, saying the app is no longer read from marks")
        XCTAssertFalse(page.gitOps.rows.shown.contains(where: \.isMarked))
        XCTAssertTrue(page.gitOps.marked.apps.contains { $0.app.key.instance == target }, "still among the marks' apps")
        XCTAssertEqual(page.gitOps.marksMode, .off)
        XCTAssertEqual(api.writes, [])
    }
}
