import Foundation
import XCTest

@testable import Overterm

/// Helm's writes (stage 2f): the lines — `--kube-context` and `-n` always,
/// quoted for zsh, a ConfigMap-stored release's driver said —, the process
/// class check refusing both on every read-only context, Helm 2 refused
/// everywhere, the typed names (a rollback's on production, an
/// uninstall's on every class), the confirmation's words, the revisions
/// offered and the kinds a manifest names for the access review. Pure.
final class KubeHelmWritesTests: XCTestCase {
    private func context(_ name: String, settings: KubeContextSettings = KubeContextSettings(), session: Bool = false) -> KubeContext {
        KubeWritesTests.context(name, settings: settings, session: session)
    }

    private let rollback = KubeHelmWrite.rollback(release: "web", namespace: "shop", storage: .secret, revision: 1, from: 2)
    private let uninstall = KubeHelmWrite.uninstall(release: "web", namespace: "shop", storage: .secret, revisions: 2)

    func testTheLinesNameTheContextAndNamespaceAlways() {
        XCTAssertEqual(rollback.line(context: "kind-fake"), "helm rollback web 1 --kube-context kind-fake -n shop")
        XCTAssertEqual(uninstall.line(context: "kind-fake"), "helm uninstall web --kube-context kind-fake -n shop")
        XCTAssertEqual(
            KubeHelmWrite.uninstall(release: "cache", namespace: "shop", storage: .configMap, revisions: 1).line(context: "kind-fake"),
            "HELM_DRIVER=configmap helm uninstall cache --kube-context kind-fake -n shop", "a ConfigMap-stored release: helm told so")
        XCTAssertEqual(rollback.verb, .helmRollback)
        XCTAssertEqual(uninstall.verb, .helmUninstall)
    }

    func testEveryWordNotOursIsQuotedForZsh() {
        let line = KubeHelmWrite.rollback(release: "web;rm -rf", namespace: "a b", storage: .secret, revision: 3, from: 4).line(context: "kind fake")
        XCTAssertEqual(line, "helm rollback 'web;rm -rf' 3 --kube-context 'kind fake' -n 'a b'")
        let flag = KubeHelmWrite.uninstall(release: "-x", namespace: "$(id)", storage: .secret, revisions: 1)
        XCTAssertEqual(flag.line(context: "c"), "helm uninstall '-x' --kube-context c -n '$(id)'", "never expanded by zsh")
        // The quotes don't keep helm from reading `-x` as a flag: a name
        // helm wouldn't give a release is refused before a line is built.
        XCTAssertEqual(flag.refused, KubeHelmWrite.refusal(name: "-x", storage: .secret))
        XCTAssertThrowsError(try KubeCommands.command(flag, in: context("kind-fake")), "a flag for a name: refused")
        for name in ["web;rm -rf", "--kubeconfig=/x", "-x"] {
            let write = KubeHelmWrite.rollback(release: name, namespace: "shop", storage: .secret, revision: 1, from: 2)
            XCTAssertThrowsError(try KubeCommands.command(write, in: context("kind-fake")), name) { error in
                XCTAssertEqual((error as? KubeCommands.Refused)?.reason.hasPrefix("\"\(name)\" isn't a name helm gives a release"), true, "\(error)")
            }
        }
    }

    func testOnlyNamesHelmWouldGiveAReleaseAreTyped() {
        for name in ["web", "my-app", "web.v2", "a", "0-api", String(repeating: "a", count: 53)] {
            XCTAssertTrue(KubeHelmWrite.isReleaseName(name), name)
        }
        for name in ["", "-x", "--kubeconfig=/x", "web-", "Web", "a_b", "a..b", ".a", "a b", "web;id", String(repeating: "a", count: 54)] {
            XCTAssertFalse(KubeHelmWrite.isReleaseName(name), name)
        }
        XCTAssertNil(KubeHelmWrite.refusal(name: "web", storage: .secret))
        XCTAssertEqual(KubeHelmWrite.refusal(name: "web", storage: .tiller), KubeHelmWrite.refusal(.tiller))
    }

    func testBothAreRefusedOnEveryReadOnlyContext() throws {
        for write in [rollback, uninstall] {
            XCTAssertTrue(write.verb.writes)
            for name in ["fake-dev", "fake-prod", "globex-eu-west-1-prod", "arn:aws:eks:eu-west-1:123456789012:cluster/acme-dev"] {
                XCTAssertThrowsError(try KubeCommands.command(write, in: context(name)), "\(write) on \(name)") { error in
                    XCTAssertEqual((error as? KubeCommands.Refused)?.reason, KubeProcessCheck.readOnly(self.context(name).contextClass))
                }
            }
            XCTAssertThrowsError(try KubeCommands.command(write, in: context("kind-fake", settings: KubeContextSettings(writable: false))), "turned off")
            XCTAssertEqual(try KubeCommands.command(write, in: context("kind-fake")), write.line(context: "kind-fake"))
            XCTAssertNoThrow(try KubeCommands.command(write, in: context("fake-prod", session: true)), "production, writes on for the session")
            XCTAssertNoThrow(try KubeCommands.command(write, in: context("fake-dev", settings: KubeContextSettings(writable: true))))
        }
    }

    func testAHelm2ReleaseIsRefusedEverywhere() {
        let tiller = KubeHelmWrite.uninstall(release: "old", namespace: "kube-system", storage: .tiller, revisions: 1)
        XCTAssertThrowsError(try KubeCommands.command(tiller, in: context("kind-fake"))) { error in
            XCTAssertEqual((error as? KubeCommands.Refused)?.reason, KubeHelmWrite.refusal(.tiller))
        }
        XCTAssertNil(KubeHelmWrite.refusal(.secret))
        XCTAssertNil(KubeHelmWrite.refusal(.configMap))
    }

    func testTheNameIsTypedForARollbackOnProductionAndAnUninstallEverywhere() {
        let local = context("kind-fake")
        let prod = context("fake-prod", session: true)
        let dev = context("fake-dev", settings: KubeContextSettings(writable: true))
        XCTAssertFalse(KubeProcessCheck.rule(.helmRollback, for: local).typedName)
        XCTAssertFalse(KubeProcessCheck.rule(.helmRollback, for: dev).typedName)
        XCTAssertTrue(KubeProcessCheck.rule(.helmRollback, for: prod).typedName)
        for writable in [local, dev, prod] {
            XCTAssertTrue(KubeProcessCheck.rule(.helmUninstall, for: writable).typedName, writable.name)
            XCTAssertTrue(KubeProcessCheck.rule(.helmUninstall, for: writable).confirm)
            XCTAssertEqual(uninstall.confirmation(context: writable, rule: KubeProcessCheck.rule(.helmUninstall, for: writable)).typedName, "web")
        }
        XCTAssertNil(rollback.confirmation(context: local, rule: KubeProcessCheck.rule(.helmRollback, for: local)).typedName)
        XCTAssertEqual(rollback.confirmation(context: prod, rule: KubeProcessCheck.rule(.helmRollback, for: prod)).typedName, "web")
    }

    func testTheConfirmationNamesTheContextNamespaceAndCommand() {
        let local = context("kind-fake")
        let asked = rollback.confirmation(context: local, rule: KubeProcessCheck.rule(.helmRollback, for: local))
        XCTAssertEqual(asked.title, "Roll back Helm release shop/web to revision 1?")
        XCTAssertEqual(asked.scope, "kind-fake · namespace shop")
        XCTAssertEqual(asked.kubectl, "helm rollback web 1 --kube-context kind-fake -n shop")
        XCTAssertTrue(asked.detail.contains("helm makes revision 3 from revision 1's chart and values"), asked.detail)
        XCTAssertTrue(asked.detail.contains("Runs in a new tab pinned to kind-fake: helm rollback web 1"), asked.detail)
        XCTAssertNil(asked.verb, "no request: a tab's")
        XCTAssertFalse(asked.production)
        let prod = context("fake-prod", session: true)
        let gone = uninstall.confirmation(context: prod, rule: KubeProcessCheck.rule(.helmUninstall, for: prod))
        XCTAssertEqual(gone.title, "Uninstall Helm release shop/web?")
        XCTAssertEqual(gone.scope, "PRODUCTION · fake-prod · namespace shop")
        XCTAssertTrue(gone.production)
        XCTAssertTrue(gone.detail.contains("(2 revisions): it can't be rolled back after"), gone.detail)
        XCTAssertTrue(gone.detail.hasSuffix("Type web to confirm."), gone.detail)
        XCTAssertFalse(gone.accepts("we"))
        XCTAssertTrue(gone.accepts(" web "))
        let cm = KubeHelmWrite.uninstall(release: "cache", namespace: "shop", storage: .configMap, revisions: 1)
        XCTAssertTrue(cm.confirmation(context: local, rule: KubeProcessCheck.rule(.helmUninstall, for: local)).detail.contains("HELM_DRIVER=configmap"))
        XCTAssertEqual(rollback.opened(context: "kind-fake"), "Rolling back Helm release shop/web to revision 1 in a new tab, in kind-fake.")
        XCTAssertEqual(uninstall.opened(context: "kind-fake"), "Uninstalling Helm release shop/web in a new tab, in kind-fake.")
    }

    func testTheRecordsAreReviewedInTheReleasesNamespace() {
        func said(_ accesses: [(access: KubeAccess, namespace: String?)]) -> [String] { accesses.map { "\($0.access) @\($0.namespace ?? "*")" } }
        XCTAssertEqual(said(KubeHelmWrite.accesses(.helmRollback, storage: .secret, namespace: "shop")), ["create secrets @shop", "update secrets @shop"])
        XCTAssertEqual(said(KubeHelmWrite.accesses(.helmUninstall, storage: .secret, namespace: "shop")), ["update secrets @shop", "delete secrets @shop"])
        XCTAssertEqual(said(KubeHelmWrite.accesses(.helmUninstall, storage: .configMap, namespace: "shop")), ["update configmaps @shop", "delete configmaps @shop"])
        XCTAssertEqual(
            KubeAccessReview.attributes(KubeAccess(verb: "create", resource: "secrets"), namespace: "shop"),
            ["verb": "create", "resource": "secrets", "group": "", "namespace": "shop"])
    }

    func testTheManifestsKindsAreReviewedWhereTheyLive() {
        let manifest = """
            ---
            # Source: web/templates/secret.yaml
            apiVersion: v1
            kind: Secret
            metadata:
              name: web-auth
            data:
              password: "***"
            ---
            # Source: web/templates/deployment.yaml
            apiVersion: "apps/v1"
            kind: Deployment
            metadata:
              name: web
              labels:
                kind: not-this
            ---
            apiVersion: rbac.authorization.k8s.io/v1
            kind: ClusterRole
            metadata:
              name: web-reader
            ---
            apiVersion: v1
            kind: List
            items: []
            ---
            apiVersion: example.com/v1
            kind: Widget
            ---
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: worker

            """
        let kinds = KubeHelmWrite.manifestKinds(manifest)
        XCTAssertEqual(kinds.map { "\($0.group)/\($0.kind)" }, ["/Secret", "apps/Deployment", "rbac.authorization.k8s.io/ClusterRole", "example.com/Widget", "apps/Deployment"])
        let clusterRoles = KubeResourceKind(
            group: "rbac.authorization.k8s.io", version: "v1", resource: "clusterroles", kind: "ClusterRole", singular: "clusterrole", namespaced: false,
            verbs: ["delete", "get", "list", "patch"])
        let discovery = KubeDiscovery(kinds: [KubeHelm.secrets, KubeWritesTests.deployments, clusterRoles])
        let accesses = KubeHelmWrite.resourceAccesses(.helmUninstall, manifest: manifest, discovery: discovery, namespace: "shop")
        XCTAssertEqual(
            accesses.map { "\($0.access) @\($0.namespace ?? "*")" },
            ["delete secrets @shop", "delete deployments.apps @shop", "delete clusterroles.rbac.authorization.k8s.io @*"],
            "each kind once, a kind the server doesn't serve left to helm")
        XCTAssertEqual(
            KubeHelmWrite.resourceAccesses(.helmRollback, manifest: manifest, discovery: discovery, namespace: "shop").first?.access.verb, "patch")
        XCTAssertTrue(KubeHelmWrite.resourceAccesses(.helmRollback, manifest: manifest, discovery: nil, namespace: "shop").isEmpty)
        XCTAssertTrue(KubeHelmWrite.resourceAccesses(.helmRollback, manifest: "", discovery: discovery, namespace: "shop").isEmpty)
    }

    func testARollbackIsOfferedEveryRevisionButTheLatest() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func record(_ revision: Int, _ status: String, hours: Double) -> KubeHelmRecord {
            KubeHelmRecord(
                storage: .secret, namespace: "shop", object: "sh.helm.release.v1.web.v\(revision)", release: "web", revision: revision, status: status,
                updated: now.addingTimeInterval(-hours * 3600))
        }
        let release = KubeHelmRelease(
            name: "web", namespace: "shop", storage: .secret, history: [record(3, "deployed", hours: 1), record(2, "superseded", hours: 3), record(1, "superseded", hours: 5)])
        XCTAssertEqual(KubeHelmWrite.choices(release).map(\.revision), [2, 1])
        XCTAssertEqual(KubeHelmWrite.choices(release, limit: 1).map(\.revision), [2])
        XCTAssertTrue(KubeHelmWrite.canRollBack(release, to: 1))
        XCTAssertFalse(KubeHelmWrite.canRollBack(release, to: 3), "the latest")
        XCTAssertFalse(KubeHelmWrite.canRollBack(release, to: 7), "not kept")
        let kept = KubeHelmRelease(
            name: "web", namespace: "shop", storage: .secret,
            history: (1...10).reversed().map { record($0, $0 == 10 ? "deployed" : "superseded", hours: Double(11 - $0)) })
        XCTAssertEqual(KubeHelmWrite.choices(kept).map(\.revision), Array((1...9).reversed()), "every earlier revision helm keeps by default")
        XCTAssertTrue(KubeHelmWrite.canRollBack(kept, to: 1))
        XCTAssertTrue(KubeHelmWrite.canRollBack(kept, to: 1) && KubeHelmWrite.choices(kept, limit: 3).count == 3, "a History row past the sheet's limit")
        XCTAssertEqual(KubeHelmWrite.label(release.history[1], summary: "Upgrade complete", now: now), "Revision 2 — superseded · 3h ago · Upgrade complete")
        XCTAssertEqual(KubeHelmWrite.label(release.history[2], summary: nil, now: now), "Revision 1 — superseded · 5h ago")
        let single = KubeHelmRelease(name: "cache", namespace: "shop", storage: .configMap, history: [record(1, "deployed", hours: 1)])
        XCTAssertTrue(KubeHelmWrite.choices(single).isEmpty)
    }
}

/// The page's Helm writes against the fake API server over `kind-fake`
/// (writable), `fake-dev` (read-only) and `fake-prod`: refused on a
/// read-only context before anything is sent; on a writable one the
/// release's records reviewed, a revision picked, asked, then typed into a
/// tab — never before the button, never with a wrong name.
@MainActor
final class KubeHelmWritesPageTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!

    override func setUpWithError() throws {
        socket = "/tmp/otkhw-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        api.addPod("web-1", namespace: "shop", labels: ["app": "web"])
        api.addPod("web-2", namespace: "shop", labels: ["app": "web"])
        api.addHelmRelease("web", namespace: "shop", revision: 1, status: "superseded")
        api.addHelmRelease(
            "web", namespace: "shop", revision: 2, description: "Upgrade complete",
            manifest: """
                ---
                # Source: web/templates/deployment.yaml
                apiVersion: apps/v1
                kind: Deployment
                metadata:
                  name: web
                """)
        api.addHelmRelease("cache", namespace: "shop", configMap: true)
    }

    override func tearDown() {
        api?.stop()
    }

    private final class Box {
        var confirmations: [(KubeWriteConfirmation, (String) -> Void)] = []
        var choices: [([String], (Int) -> Void)] = []
        var commands: [(String, String, String)] = []
    }

    private func page(current: String, releases: [String] = ["cache", "web"]) async throws -> (KubernetesPageModel, Box) {
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
        let box = Box()
        var actions = KubernetesActions(run: { _ in }, settings: {}, copy: { _ in }, copySecret: { _ in })
        actions.confirmWrite = { confirmation, then in box.confirmations.append((confirmation, then)) }
        actions.confirm = { _, _, _, then in then() }
        actions.choose = { _, _, buttons, then in box.choices.append((buttons, then)) }
        actions.runInTab = { command, context, namespace in box.commands.append((command, context.name, namespace)) }
        page.actions = actions
        model.show()
        try await until("listed") { model.rows.count == 2 && model.selectedName == current }
        page.model.setScope(.namespace("shop"))
        page.loadHelm()
        try await until("releases") { page.helm.listState == .live && page.helm.releases.map(\.name) == releases }
        return (page, box)
    }

    private func until(_ what: String, _ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func reviewed() -> [[String: String]] {
        api.requests.filter(\.isAccessReview).compactMap {
            (($0.json as? [String: Any])?["spec"] as? [String: Any])?["resourceAttributes"] as? [String: String]
        }
    }

    private func release(_ page: KubernetesPageModel, _ name: String) -> KubeHelmRelease? { page.helm.releases.first { $0.name == name } }

    func testARollbackIsReviewedPickedAskedThenTypedIntoATab() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        let web = try XCTUnwrap(release(page, "web"))
        page.runHelmWrite(.helmRollback, on: web)
        try await until("picked") { box.choices.count == 1 }
        XCTAssertEqual(
            reviewed(),
            [["verb": "create", "resource": "secrets", "group": "", "namespace": "shop"], ["verb": "update", "resource": "secrets", "group": "", "namespace": "shop"]],
            "its records reviewed first")
        XCTAssertEqual(box.choices[0].0.count, 1, "the latest revision isn't offered")
        XCTAssertTrue(box.choices[0].0[0].hasPrefix("Revision 1 — superseded"), box.choices[0].0[0])
        box.choices[0].1(0)
        XCTAssertEqual(box.confirmations.count, 1)
        let (confirmation, then) = box.confirmations[0]
        XCTAssertEqual(confirmation.title, "Roll back Helm release shop/web to revision 1?")
        XCTAssertNil(confirmation.typedName, "not production: no name typed")
        XCTAssertTrue(box.commands.isEmpty, "nothing typed before the button")
        then("")
        XCTAssertEqual(box.commands.first?.0, "helm rollback web 1 --kube-context kind-fake -n shop")
        XCTAssertEqual(box.commands.first?.1, "kind-fake")
        XCTAssertEqual(box.commands.first?.2, "shop", "its tab pinned to the release's namespace")
        XCTAssertEqual(page.writeStatus, .done("Rolling back Helm release shop/web to revision 1 in a new tab, in kind-fake."))
        XCTAssertTrue(api.writes.allSatisfy(\.isAccessReview), "the page itself sends no write: \(api.writes)")
    }

    func testAnOpenedReleasesKindsAreReviewedToo() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        let web = try XCTUnwrap(release(page, "web"))
        page.openHelm(web)
        try await until("read") { page.helm.opened?.detail != nil }
        try await until("discovery") { page.model.knownDiscovery(of: "kind-fake") != nil }
        page.runHelmWrite(.helmRollback, on: web, revision: 1)
        try await until("asked") { box.confirmations.count == 1 }
        XCTAssertTrue(box.choices.isEmpty, "its History row named the revision")
        XCTAssertTrue(
            reviewed().contains(["verb": "patch", "resource": "deployments", "group": "apps", "namespace": "shop"]), "the manifest's Deployment: \(reviewed())")
    }

    func testAnUninstallAsksForTheNameEvenLocally() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        page.helm.selection = try XCTUnwrap(release(page, "cache")).id
        XCTAssertEqual(page.helmPress("\u{7F}"), true, "⌫ uninstalls the release picked")
        try await until("asked") { box.confirmations.count == 1 }
        XCTAssertTrue(reviewed().contains(["verb": "delete", "resource": "configmaps", "group": "", "namespace": "shop"]), "\(reviewed())")
        XCTAssertEqual(box.confirmations[0].0.typedName, "cache")
        XCTAssertEqual(box.confirmations[0].0.kubectl, "HELM_DRIVER=configmap helm uninstall cache --kube-context kind-fake -n shop")
        box.confirmations[0].1("cach")
        XCTAssertEqual(page.writeStatus, .failed("The name typed wasn't cache: nothing was run."))
        XCTAssertTrue(box.commands.isEmpty)
        XCTAssertTrue(page.helmPress("\u{7F}") == true)
        try await until("asked again") { box.confirmations.count == 2 }
        box.confirmations[1].1("cache")
        XCTAssertEqual(box.commands.map(\.0), ["HELM_DRIVER=configmap helm uninstall cache --kube-context kind-fake -n shop"])
    }

    func testARollbackFromTheOldestKeptRevisionsRowIsAsked() async throws {
        // Helm keeps 10 revisions by default: 9 to roll back to, past the sheet's old limit of 8.
        for revision in 1...10 {
            api.addHelmRelease("api", namespace: "shop", revision: revision, status: revision == 10 ? "deployed" : "superseded")
        }
        let (page, box) = try await page(current: "kind-fake", releases: ["api", "cache", "web"])
        defer { page.model.hide() }
        let big = try XCTUnwrap(release(page, "api"))
        XCTAssertEqual(big.history.count, 10)
        XCTAssertEqual(big.history.last?.revision, 1, "the oldest History row")
        XCTAssertNotEqual(page.helmWriteVerbs(for: big).first { $0.title == KubeHelmWrite.title(.helmRollback) }?.unavailable, KubernetesPageModel.noEarlierRevision(big))
        page.runHelmWrite(.helmRollback, on: big, revision: 1)
        try await until("asked") { box.confirmations.count == 1 || page.writeStatus?.isFailure == true }
        XCTAssertNotEqual(page.writeStatus?.isFailure, true, page.writeStatus?.text ?? "")
        XCTAssertEqual(box.confirmations.first?.0.title, "Roll back Helm release shop/api to revision 1?")
        box.confirmations.first?.1("")
        XCTAssertEqual(box.commands.map(\.0), ["helm rollback api 1 --kube-context kind-fake -n shop"])
        // The sheet offers every one of the nine.
        page.runHelmWrite(.helmRollback, on: big)
        try await until("picked") { box.choices.count == 1 }
        XCTAssertEqual(box.choices[0].0.count, 9)
        XCTAssertTrue(box.choices[0].0.last?.hasPrefix("Revision 1 — superseded") == true, box.choices[0].0.last ?? "")
    }

    func testDeleteActsOnTheHighlightedRowNotTheOpenedOne() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        page.openHelm(try XCTUnwrap(release(page, "web")))
        try await until("read") { page.helm.opened?.detail != nil }
        XCTAssertEqual(page.helm.selectedRelease?.name, "web")
        XCTAssertEqual(page.helmPress("\u{F700}"), true, "↑ to cache")
        XCTAssertEqual(page.helm.selectedRelease?.name, "cache")
        XCTAssertEqual(page.helm.opened?.release.name, "web", "still open")
        XCTAssertEqual(page.helmPicked?.name, "cache")
        XCTAssertEqual(page.helmPress("\u{7F}"), true)
        try await until("asked") { box.confirmations.count == 1 }
        XCTAssertEqual(box.confirmations[0].0.title, "Uninstall Helm release shop/cache?")
        XCTAssertEqual(box.confirmations[0].0.typedName, "cache")
        XCTAssertTrue(page.helmCommand.contains("cache"), page.helmCommand)
    }

    func testOnAReadOnlyContextNothingIsSentOrTyped() async throws {
        for current in ["fake-dev", "fake-prod"] {
            let (page, box) = try await page(current: current)
            defer { page.model.hide() }
            let readOnly = KubeProcessCheck.readOnly(page.model.selected?.contextClass ?? .remote)
            let web = try XCTUnwrap(release(page, "web"))
            api.forgetRequests()
            for verb in KubernetesPageModel.helmWriteVerbs {
                XCTAssertEqual(page.helmWriteVerbs(for: web).first { $0.title == KubeHelmWrite.title(verb) }?.unavailable, readOnly, "\(verb) greyed with why")
                page.runHelmWrite(verb, on: web)
                XCTAssertEqual(page.writeStatus, .failed(readOnly), "\(verb) on \(current)")
            }
            page.helm.selection = web.id
            XCTAssertEqual(page.helmPress("\u{7F}"), true)
            XCTAssertEqual(page.writeStatus, .failed(readOnly))
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(box.confirmations.isEmpty && box.choices.isEmpty && box.commands.isEmpty)
            XCTAssertEqual(api.writes, [], "not even a review on \(current)")
        }
    }

    func testARefusedReviewStopsIt() async throws {
        api.deniedAccess = ["delete secrets"]
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        page.runHelmWrite(.helmUninstall, on: try XCTUnwrap(release(page, "web")))
        try await until("said") { page.writeStatus?.isFailure == true }
        XCTAssertEqual(page.writeStatus?.text.hasPrefix("The cluster's access review says you may not delete secrets in shop"), true, page.writeStatus?.text ?? "")
        XCTAssertTrue(box.confirmations.isEmpty && box.commands.isEmpty)
    }

    func testNoEarlierRevisionNoRollback() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        let cache = try XCTUnwrap(release(page, "cache"))
        let said = KubernetesPageModel.noEarlierRevision(cache)
        XCTAssertEqual(page.helmWriteVerbs(for: cache).first { $0.title == KubeHelmWrite.title(.helmRollback) }?.unavailable, said)
        page.runHelmWrite(.helmRollback, on: cache)
        XCTAssertEqual(page.writeStatus, .failed(said))
        page.runHelmWrite(.helmRollback, on: try XCTUnwrap(release(page, "web")), revision: 2)
        XCTAssertEqual(page.writeStatus?.isFailure, true, "the revision it is at isn't one to roll back to")
        XCTAssertTrue(box.confirmations.isEmpty && box.choices.isEmpty)
    }

    func testOnProductionWithWritesOnARollbackAsksForTheName() async throws {
        let (page, box) = try await page(current: "fake-prod")
        defer { page.model.hide() }
        await page.model.setProductionWrites(true, for: "fake-prod")
        try await until("writable") { page.model.selected?.isWritable == true }
        let web = try XCTUnwrap(release(page, "web"))
        page.runHelmWrite(.helmRollback, on: web, revision: 1)
        try await until("asked") { box.confirmations.count == 1 }
        XCTAssertEqual(box.confirmations[0].0.typedName, "web")
        XCTAssertEqual(box.confirmations[0].0.scope, "PRODUCTION · fake-prod · namespace shop")
        box.confirmations[0].1("wbe")
        XCTAssertEqual(page.writeStatus, .failed("The name typed wasn't web: nothing was run."))
        XCTAssertTrue(box.commands.isEmpty)
        // Writes off while it asks: the button runs nothing.
        page.runHelmWrite(.helmRollback, on: web, revision: 1)
        try await until("asked again") { box.confirmations.count == 2 }
        await page.model.setProductionWrites(false, for: "fake-prod")
        box.confirmations[1].1("web")
        XCTAssertEqual(page.writeStatus, .failed(KubeProcessCheck.readOnly(.production)))
        XCTAssertTrue(box.commands.isEmpty)
    }
}
