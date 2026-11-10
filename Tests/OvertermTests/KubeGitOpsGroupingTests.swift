import Foundation
import XCTest

@testable import Overterm

/// G4 (docs/design/kubernetes/gitops.md, 2.8): `G` groups the GitOps
/// section by tool, source, owner or destination, and the filter's `is:`,
/// `kind:`, `tool:` and `repo:` words — pure, over `FakeKubeAPI+GitOps`'s
/// objects read as a GET answers them, without a server.
final class KubeGitOpsGroupingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

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

    private func shownRows(_ objects: [KubeGitOpsObject]? = nil, scope: KubeScope = .all) throws -> [KubeGitOpsRow] {
        KubeGitOpsSection.rows(summaries: try objects ?? fixtures(), live: [:], listed: [], scope: scope, now: now).shown
    }

    private func group(_ groups: [KubeGitOpsGroup], _ title: String) throws -> KubeGitOpsGroup {
        try XCTUnwrap(groups.first { $0.title == title }, "\(title) among \(groups.map(\.title))")
    }

    private func names(_ group: KubeGitOpsGroup) -> [String] { group.members.map { "\($0.key.kind) \($0.ref.name)" } }

    private func visible(_ rows: [KubeGitOpsRow], _ text: String, hideReady: Bool = false) -> [KubeGitOpsRow] {
        KubeGitOpsSection.visible(KubeGitOpsSection.Rows(shown: rows), chip: nil, hideReady: hideReady, tool: nil, notPlaced: false, text: text)
    }

    // MARK: G

    func testGCyclesTheGroupingsInTheSectionOnly() {
        guard case .key(.groupBy) = KubernetesKey.press("G", sheetShowing: false) else { return XCTFail("G is the grouping") }
        XCTAssertEqual(KubernetesKey.groupBy.group, .list)
        XCTAssertTrue(KubernetesKey.isWellFormed, "no key twice")
        var seen: [KubeGitOpsGroupBy] = []
        var by = KubeGitOpsGroupBy.none
        for _ in 0..<5 {
            by = by.next
            seen.append(by)
        }
        XCTAssertEqual(seen, [.tool, .source, .owner, .destination, .none], "G cycles, back to none")
        XCTAssertTrue(KubeGitOpsGrouping.groups([], by: .source, all: []).isEmpty)
    }

    /// A page with no server: nothing is read, the keys and verbs alone.
    @MainActor private func page() -> KubernetesPageModel {
        let model = KubernetesModel(proxies: KubeProxies())
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        return KubernetesPageModel(model: model)
    }

    @MainActor func testGOutsideTheGitOpsSectionDoesNothing() {
        let page = page()
        XCTAssertNotEqual(page.section, .gitops)
        XCTAssertFalse(page.press("G"), "G is the GitOps section's alone")
        XCTAssertEqual(page.gitOpsView.groupBy, .none, "the section's grouping untouched")
        XCTAssertEqual(page.gitOpsPress("G"), true, "in the section, G cycles")
        XCTAssertEqual(page.gitOpsView.groupBy, .tool)
    }

    @MainActor func testAGroupRowsVerbFoldsAndUnfoldsIt() throws {
        let page = page()
        let id = "\(KubeGitOpsGrouping.groupPrefix)tool:argo"
        let verbs = page.gitOpsVerbs(for: [id])
        XCTAssertEqual(verbs.map(\.title), ["Fold"], "a group's row: Fold alone")
        try XCTUnwrap(verbs.first).perform()
        XCTAssertTrue(page.gitOpsView.folded.contains(id))
        let again = page.gitOpsVerbs(for: [id])
        XCTAssertEqual(again.map(\.title), ["Unfold"])
        try XCTUnwrap(again.first).perform()
        XCTAssertFalse(page.gitOpsView.folded.contains(id))

        // A group's row among several rows: no verb, and ↩ folds nothing.
        let several: Set<String> = [id, "\(KubeGitOpsGrouping.groupPrefix)tool:flux"]
        XCTAssertTrue(page.gitOpsVerbs(for: several).isEmpty)
        page.gitOpsView.selection = several
        XCTAssertEqual(page.gitOpsPress(KubernetesKey.open.key), false)
        XCTAssertTrue(page.gitOpsView.folded.isEmpty, "↩ on several rows folds no group")
    }

    func testNoneIsNoGroupAndToolIsArgoThenFlux() throws {
        let rows = try shownRows()
        XCTAssertTrue(KubeGitOpsGrouping.groups(rows, by: .none, all: rows).isEmpty)
        let groups = KubeGitOpsGrouping.groups(rows, by: .tool, all: rows)
        XCTAssertEqual(groups.map(\.title), ["Argo CD", "Flux"])
        XCTAssertTrue(groups[0].members.allSatisfy { $0.tool == .argo } && groups[1].members.allSatisfy { $0.tool == .flux })
        XCTAssertEqual(groups.reduce(0) { $0 + $1.members.count }, rows.count, "every row once")
        let listed = KubeGitOpsGrouping.rows(groups, folded: [])
        XCTAssertEqual(listed.count, rows.count + 2)
        XCTAssertTrue(listed[0].spansColumns && listed[0].height == 28)
        XCTAssertEqual(listed[1].object, groups[0].members.first, "its members in the section's order")
        XCTAssertEqual(groups[0].members.map(\.state), groups[0].members.map(\.state).sorted(), "problems first within it")
    }

    // MARK: Source

    func testBySourceAFluxSourceHeadsItsGroupAndArgoGroupsByRepository() throws {
        let rows = try shownRows()
        let groups = KubeGitOpsGrouping.groups(rows, by: .source, all: rows)
        let fleet = try group(groups, "GitRepository flux-system/acme-fleet")
        XCTAssertEqual(fleet.head?.ref.name, "acme-fleet", "the source heads its group")
        XCTAssertEqual(fleet.members.first?.ref.name, "acme-fleet", "its own row first")
        XCTAssertTrue(names(fleet).contains("Kustomization acme-apps") && names(fleet).contains("Kustomization acme-cron"), "\(names(fleet))")
        XCTAssertFalse(names(fleet).contains("Kustomization acme-api"), "acme-api's source is acme-broken")
        let broken = try group(groups, "GitRepository flux-system/acme-broken")
        XCTAssertEqual(broken.head?.state, .failed, "it carries its own state")
        XCTAssertEqual(names(broken), ["GitRepository acme-broken", "Kustomization acme-api"])
        XCTAssertEqual(broken.said, "1 object · 1 blocked", "what it holds, its head aside")
        let charts = try group(groups, "HelmRepository flux-system/acme-charts")
        XCTAssertTrue(names(charts).contains("HelmRelease acme-payments"), "a HelmRelease by its chart's repository")
        XCTAssertTrue(names(charts).contains("HelmChart flux-system-acme-payments"), "the HelmChart with its repository")
        XCTAssertTrue(names(try group(groups, "OCIRepository flux-system/globex-charts")).contains("HelmRelease globex-redis"), "chartRef")
        XCTAssertEqual(names(try group(groups, "OCIRepository flux-system/acme-manifests")), ["OCIRepository acme-manifests"], "a source nothing uses, alone")
        let argo = try group(groups, "git.acme.example/acme/fleet")
        XCTAssertNil(argo.head, "Argo CD's by repository: no object heads it")
        XCTAssertTrue(argo.members.allSatisfy { $0.role == .application } && names(argo).contains("Application acme-web"), "\(names(argo))")
        let none = try XCTUnwrap(groups.last)
        XCTAssertTrue(none.rest && none.title == "No source", "the rest last: \(none.title)")
        XCTAssertTrue(names(none).allSatisfy { $0.hasPrefix("ApplicationSet") }, "\(names(none))")
        let ranked = groups.filter { !$0.rest }.map(\.worst)
        XCTAssertEqual(ranked, ranked.sorted(), "groups with a problem first")
        XCTAssertEqual(groups.reduce(0) { $0 + $1.members.count }, rows.count, "every row once")
        for group in groups {
            XCTAssertFalse(group.title.contains("ghp_fake") || group.title.contains("user:"), "never a URL's userinfo: \(group.title)")
        }
        XCTAssertTrue(rows.allSatisfy { !$0.grouping.repo.contains("ghp_fake") && !$0.grouping.repo.contains("@") }, "\(rows.map(\.grouping.repo))")
    }

    // MARK: Owner

    func testByOwnerAnApplicationSetWithItsApplicationsAndADependsOnRoot() throws {
        let rows = try shownRows()
        let groups = KubeGitOpsGrouping.groups(rows, by: .owner, all: rows)
        let set = try group(groups, "ApplicationSet argocd/acme-envs")
        XCTAssertEqual(Set(names(set)), ["ApplicationSet acme-envs", "Application acme-envs-dev", "Application acme-envs-prod"], "\(names(set))")
        XCTAssertEqual(set.members.first?.key.kind, "ApplicationSet", "the set heads its group")
        let infra = try group(groups, "Kustomization flux-system/acme-infra")
        XCTAssertEqual(names(infra).first, "Kustomization acme-infra", "the dependsOn root heads it")
        XCTAssertTrue(names(infra).contains("Kustomization acme-web"))
        let none = try XCTUnwrap(groups.last)
        XCTAssertTrue(none.rest && none.title == "No owner")
        XCTAssertTrue(names(none).contains("Kustomization acme-cron"), "no owner, no dependency")
        XCTAssertEqual(groups.reduce(0) { $0 + $1.members.count }, rows.count, "every row once")
    }

    func testAnAppOfAppsParentByTrackingIDFollowedToItsTop() throws {
        var objects = try fixtures()
        func set(_ name: String, parent: KubeGitOpsOwner) {
            if let at = objects.firstIndex(where: { $0.kind == "Application" && $0.ref.name == name }) { objects[at].parentOwner = parent }
        }
        set("acme-web", parent: KubeGitOpsOwner(tool: .argoCD, name: "acme-shop-prod", namespace: "argocd", mark: .trackingID))
        // No namespace in its mark: its own, then Argo CD's.
        set("acme-admin", parent: KubeGitOpsOwner(tool: .argoCD, name: "acme-web", namespace: nil, mark: .argoInstance))
        // Helm's label alone, naming nobody summarised: no owner.
        set("acme-old-fail", parent: KubeGitOpsOwner(tool: .argoCD, name: "nobody", namespace: nil, mark: .appInstance))
        let rows = try shownRows(objects)
        let groups = KubeGitOpsGrouping.groups(rows, by: .owner, all: rows)
        let root = try group(groups, "Application argocd/acme-shop-prod")
        XCTAssertEqual(names(root).first, "Application acme-shop-prod", "the parent heads it")
        XCTAssertTrue(names(root).contains("Application acme-web") && names(root).contains("Application acme-admin"), "two hops up: \(names(root))")
        XCTAssertTrue(try XCTUnwrap(groups.last).members.contains { $0.ref.name == "acme-old-fail" }, "probably Argo CD names nobody")

        // A cycle ends.
        set("acme-shop-prod", parent: KubeGitOpsOwner(tool: .argoCD, name: "acme-admin", namespace: "argocd", mark: .trackingID))
        let cycled = try shownRows(objects)
        XCTAssertEqual(KubeGitOpsGrouping.groups(cycled, by: .owner, all: cycled).reduce(0) { $0 + $1.members.count }, cycled.count)

        // A certain mark naming an Application not summarised still names the group.
        var lone = objects
        if let at = lone.firstIndex(where: { $0.kind == "Application" && $0.ref.name == "acme-new" }) {
            lone[at].parentOwner = KubeGitOpsOwner(tool: .argoCD, name: "acme-elsewhere", namespace: "argocd", mark: .trackingID)
        }
        let loneRows = try shownRows(lone)
        let elsewhere = try group(KubeGitOpsGrouping.groups(loneRows, by: .owner, all: loneRows), "Application argocd/acme-elsewhere")
        XCTAssertNil(elsewhere.head)
        XCTAssertEqual(names(elsewhere), ["Application acme-new"])
    }

    // MARK: Destination

    func testByDestination() throws {
        let rows = try shownRows()
        let groups = KubeGitOpsGrouping.groups(rows, by: .destination, all: rows)
        let shop = try group(groups, "shop")
        XCTAssertTrue(names(shop).contains("Application acme-shop-prod") && names(shop).contains("Kustomization acme-apps"), "a destination, an inventory")
        XCTAssertTrue(names(shop).contains("HelmRelease acme-payments"))
        let remote = try XCTUnwrap(groups.first { $0.title.hasPrefix("⇢ ") }, "\(groups.map(\.title))")
        XCTAssertTrue(names(remote).contains("Application acme-remote"), "another cluster, said")
        let sources = try group(groups, "Sources — deploy nothing themselves")
        XCTAssertTrue(sources.members.allSatisfy { if case .source = $0.role { true } else { false } })
        XCTAssertTrue(names(try group(groups, "envs-dev")).contains("Application acme-envs-dev"))
        XCTAssertEqual(groups.reduce(0) { $0 + $1.members.count }, rows.count)
    }

    func testAGroupFoldsAndRowsNotSummarisedStayTogether() throws {
        let rows = try shownRows()
        let groups = KubeGitOpsGrouping.groups(rows, by: .tool, all: rows)
        let folded = KubeGitOpsGrouping.rows(groups, folded: [groups[0].id])
        XCTAssertEqual(folded.count, 1 + 1 + groups[1].members.count, "the folded group's row alone")
        guard case .group(_, folded: true) = folded[0] else { return XCTFail("folded said") }
        XCTAssertTrue(KubeGitOpsGrouping.isGroup(groups[0].id) && !KubeGitOpsGrouping.isGroup(rows[0].id))

        let live = KubeRow(id: KubeRowID(namespace: "argocd", name: "acme-later"), cells: [.text("acme-later"), .text("OutOfSync"), .text("Healthy")])
        let columns = [KubeColumn(name: "Name", format: "name"), KubeColumn(name: "Sync Status"), KubeColumn(name: "Health Status")]
        let unsummarised = try XCTUnwrap(KubeGitOpsSection.row(cells: live, columns: columns, resource: "applications.argoproj.io"))
        // A source not summarised yet: its live row already says what it is,
        // so it joins the sources by destination as its summary will.
        let gitLive = KubeRow(
            id: KubeRowID(namespace: "flux-system", name: "acme-later-repo"),
            cells: [.text("acme-later-repo"), .text("https://git.acme.example/acme/later")])
        let gitColumns = [KubeColumn(name: "Name", format: "name"), KubeColumn(name: "URL")]
        let unsummarisedSource = try XCTUnwrap(
            KubeGitOpsSection.row(cells: gitLive, columns: gitColumns, resource: "gitrepositories.source.toolkit.fluxcd.io"))
        XCTAssertFalse(unsummarisedSource.summarised)
        XCTAssertEqual(unsummarisedSource.grouping.destination, KubeGitOpsGrouping.sourcesDestination)
        let withSource = rows + [unsummarisedSource]
        let sources = try group(KubeGitOpsGrouping.groups(withSource, by: .destination, all: withSource), "Sources — deploy nothing themselves")
        XCTAssertTrue(names(sources).contains("GitRepository acme-later-repo"), "\(names(sources))")

        let mixed = rows + [unsummarised]
        for by in [KubeGitOpsGroupBy.source, .owner, .destination] {
            let last = try XCTUnwrap(KubeGitOpsGrouping.groups(mixed, by: by, all: mixed).last)
            XCTAssertEqual(last.title, "Not summarised", "\(by)")
            XCTAssertEqual(names(last), ["Application acme-later"])
        }
    }

    // MARK: Filter

    func testTheFiltersTokens() throws {
        let rows = try shownRows()
        let failed = visible(rows, "is:failed")
        XCTAssertTrue(!failed.isEmpty && failed.allSatisfy { $0.state == .failed })
        XCTAssertEqual(Set(visible(rows, "is:failed,blocked").map(\.state)), [.failed, .blocked], "a comma: any of them")
        XCTAssertFalse(visible(rows, "-is:ready").contains { $0.state == .ready }, "turned around")
        XCTAssertTrue(
            visible(rows, "is:ready", hideReady: true).allSatisfy { $0.state == .ready } && !visible(rows, "is:ready", hideReady: true).isEmpty,
            "asked for, Hide Ready doesn't hide them")
        XCTAssertTrue(visible(rows, "kind:ks").allSatisfy { $0.role == .kustomization })
        XCTAssertTrue(visible(rows, "kind:source").allSatisfy { if case .source = $0.role { true } else { false } })
        XCTAssertEqual(Set(visible(rows, "kind:git").map(\.ref.name)), ["acme-fleet", "acme-broken"])
        XCTAssertTrue(visible(rows, "kind:hr,app").allSatisfy { $0.role == .helmRelease || $0.role == .application })
        XCTAssertTrue(visible(rows, "tool:argo").allSatisfy { $0.tool == .argo } && !visible(rows, "tool:argo").isEmpty)
        XCTAssertTrue(visible(rows, "tool:flux").allSatisfy { $0.tool == .flux })
        let fleet = visible(rows, "repo:acme/fleet")
        XCTAssertTrue(fleet.contains { $0.ref.name == "acme-web" && $0.role == .application }, "\(fleet.map(\.ref.name))")
        XCTAssertTrue(visible(rows, "repo:git.acme.example").contains { $0.role == .kustomization }, "a Flux object by its source's repository, host included")
        XCTAssertTrue(visible(rows, "repo:ghp_fake").isEmpty, "never its userinfo")
        XCTAssertEqual(visible(rows, "is:failed kind:ks cron").map(\.ref.name), ["acme-cron"], "tokens, then the text")
        XCTAssertEqual(visible(rows, "kind:ks tool:argo").count, 0)

        let nope = KubeGitOpsFilter("is:nope kind:ks")
        XCTAssertEqual(nope.refused, ["is:nope"])
        XCTAssertEqual(nope.refusal, "Not read: is:nope — is: failed, blocked, stuck, drift, progressing, paused, ready, unknown")
        XCTAssertTrue(visible(rows, "is:nope kind:ks").allSatisfy { $0.role == .kustomization } && !visible(rows, "is:nope kind:ks").isEmpty, "matches anything, said")
        XCTAssertNil(KubeGitOpsFilter("label:app=web ns:shop cron").refusal, "the kinds' lists' words are nothing here")
        XCTAssertEqual(visible(rows, "label:app=web cron").map(\.ref.name), ["acme-cron"])
        XCTAssertEqual(KubeGitOpsFilter("tool:jenkins").refusal, "Not read: tool:jenkins — tool: argo, flux")
    }
}
