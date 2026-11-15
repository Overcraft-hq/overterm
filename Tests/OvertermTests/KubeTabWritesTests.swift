import Foundation
import XCTest

@testable import Overterm

/// Drain, rollback and debug in a tab (stage 2a, part 3): the commands'
/// lines — `--context` and `-n` always, quoted for zsh —, the process
/// class check refusing them on every read-only context, the typed names
/// rule 4 asks, the confirmation's words, and the revisions a rollback is
/// picked from. Pure.
final class KubeTabWritesTests: XCTestCase {
    private func context(_ name: String, settings: KubeContextSettings = KubeContextSettings(), readOnly: Bool = false) -> KubeContext {
        KubeWritesTests.context(name, settings: settings, readOnly: readOnly)
    }

    func testTheLinesNameTheContextAndNamespaceAlways() {
        XCTAssertEqual(
            KubeTabWrite.drain(node: "fake-node-1", namespace: "shop").line(context: "kind-fake"),
            "kubectl drain fake-node-1 --ignore-daemonsets --context kind-fake -n shop", "-n always, a node's drain too")
        XCTAssertEqual(
            KubeTabWrite.rolloutUndo(deployment: "web", namespace: "shop", revision: 3, images: []).line(context: "kind-fake"),
            "kubectl rollout undo deployment/web --to-revision=3 --context kind-fake -n shop")
        XCTAssertEqual(
            KubeTabWrite.debug(pod: "web-7d9", namespace: "shop", container: "app", image: "busybox:1.36").line(context: "kind-fake"),
            "kubectl debug -it web-7d9 --image=busybox:1.36 --target=app --context kind-fake -n shop")
        XCTAssertEqual(
            KubeTabWrite.debug(pod: "web-7d9", namespace: "shop", container: nil, image: "busybox:1.36").line(context: "kind-fake"),
            "kubectl debug -it web-7d9 --image=busybox:1.36 --context kind-fake -n shop", "no container: kubectl's choice")
        XCTAssertEqual(
            KubeTabWrite.nodeShell(node: "fake-node-1", namespace: "default", image: "busybox:1.36").line(context: "kind-fake"),
            "kubectl debug node/fake-node-1 -it --profile=sysadmin --image=busybox:1.36 --context kind-fake -n default -- chroot /host sh -c "
                + "'command -v bash >/dev/null && exec bash || exec sh'",
            "a node shell: privileged, rooted in the node's filesystem, the command last")
    }

    func testANodeShellSaysWhatItIsAndWhatItLeaves() {
        let shell = KubeTabWrite.nodeShell(node: "fake-node-1", namespace: "default", image: "acme/node-tools:1")
        XCTAssertEqual(KubeTabWrite.title(.nodeShell), "Node Shell in a Tab…")
        XCTAssertEqual(shell.name, "fake-node-1", "the node's name is what is typed")
        let rule = KubeProcessCheck.rule(.nodeShell, for: context("kind-fake", settings: KubeContextSettings(nodeShell: true)))
        let asked = shell.confirmation(context: context("kind-fake", settings: KubeContextSettings(nodeShell: true)), rule: rule)
        XCTAssertEqual(asked.title, "Open a shell on node fake-node-1?")
        XCTAssertEqual(asked.scope, "kind-fake · namespace default")
        XCTAssertEqual(asked.typedName, "fake-node-1", "typed on a local context too (decision 20)")
        XCTAssertTrue(asked.detail.contains("A privileged pod running acme/node-tools:1"), asked.detail)
        XCTAssertTrue(asked.detail.contains("node-debugger-fake-node-1-"), "the pod it leaves is named")
        XCTAssertTrue(asked.detail.contains(shell.line(context: "kind-fake")), "the command the tab runs")
        XCTAssertEqual(asked.kubectl, shell.line(context: "kind-fake"))
        let prod = context("fake-prod", settings: KubeContextSettings(nodeShell: true))
        let onProduction = shell.confirmation(context: prod, rule: KubeProcessCheck.rule(.nodeShell, for: prod))
        XCTAssertTrue(onProduction.production && onProduction.scope.hasPrefix("PRODUCTION · fake-prod"), onProduction.scope)
        XCTAssertEqual(shell.opened(context: "kind-fake"), "A shell on node fake-node-1 in a new tab, in kind-fake.")
        XCTAssertNoThrow(try KubeCommands.command(shell, in: prod), "production: writable, no switch")
        XCTAssertThrowsError(
            try KubeCommands.command(shell, in: context("fake-prod", settings: KubeContextSettings(writable: false, nodeShell: true))), "production set read-only")
    }

    func testEveryWordNotOursIsQuotedForZsh() {
        let line = KubeTabWrite.debug(pod: "web;rm", namespace: "a b", container: "c$(x)", image: "img'1").line(context: "kind fake")
        XCTAssertEqual(line, #"kubectl debug -it 'web;rm' --image='img'\''1' --target='c$(x)' --context 'kind fake' -n 'a b'"#)
        XCTAssertEqual(
            KubeTabWrite.drain(node: "-x", namespace: "-n").line(context: "c"), "kubectl drain '-x' --ignore-daemonsets --context c -n '-n'", "never read as a flag")
    }

    func testEachIsRefusedOnEveryReadOnlyContext() {
        let writes: [KubeTabWrite] = [
            .drain(node: "n", namespace: "shop"), .rolloutUndo(deployment: "web", namespace: "shop", revision: 1, images: []),
            .debug(pod: "p", namespace: "shop", container: nil, image: "busybox:1.36"), .nodeShell(node: "n", namespace: "shop", image: "busybox:1.36"),
        ]
        let nodeShell = KubeContextSettings(nodeShell: true)
        for write in writes {
            XCTAssertTrue(write.verb.writes, "\(write.verb) is a writing process")
            for name in ["fake-dev", "fake-prod", "globex-eu-west-1-prod", "arn:aws:eks:eu-west-1:123456789012:cluster/acme-dev"] {
                XCTAssertThrowsError(try KubeCommands.command(write, in: context(name, settings: nodeShell, readOnly: true)), "\(write) on \(name)") { error in
                    XCTAssertEqual((error as? KubeCommands.Refused)?.reason, KubeProcessCheck.readOnly(self.context(name).contextClass))
                }
            }
            XCTAssertThrowsError(try KubeCommands.command(write, in: context("kind-fake", settings: KubeContextSettings(writable: false))), "turned off")
            XCTAssertNoThrow(try KubeCommands.command(write, in: context("kind-fake", settings: nodeShell)), "\(write) on kind-fake")
            XCTAssertNoThrow(try KubeCommands.command(write, in: context("fake-prod", settings: nodeShell)), "production, writable by default")
            XCTAssertNoThrow(try KubeCommands.command(write, in: context("fake-dev", settings: KubeContextSettings(writable: true, nodeShell: true))))
        }
    }

    func testANodesDebugNeedsItsSettingAndAlwaysItsName() {
        let node = KubeTabWrite.nodeShell(node: "n", namespace: "shop", image: "busybox:1.36")
        XCTAssertThrowsError(try KubeCommands.command(node, in: context("kind-fake"))) { error in
            XCTAssertEqual((error as? KubeCommands.Refused)?.reason, "Node shells are off until the context's nodeShell setting is on.")
        }
        let on = KubeProcessCheck.rule(.nodeShell, for: context("kind-fake", settings: KubeContextSettings(nodeShell: true)))
        XCTAssertEqual(on, KubeProcessRule(confirm: true, typedName: true), "the name typed on every class")
        XCTAssertEqual(KubeContextSettings(fields: ["nodeShell": .bool(true), "debugImage": .string(" alpine:3.20 ")]).debugImage, "alpine:3.20")
        XCTAssertEqual(KubeContextSettings(fields: ["nodeShellImage": .string(" acme/node-tools:1 ")]).nodeShellImage, "acme/node-tools:1")
        XCTAssertNil(KubeContextSettings(fields: ["nodeShellImage": .string(" ")]).nodeShellImage)
        XCTAssertEqual(KubeContextSettings(fields: ["nodeShell": .bool(true)]).nodeShell, true)
        for field in ["nodeShell", "debugImage", "nodeShellImage"] {
            XCTAssertTrue(KubeContextSettings.fields.contains { $0.name == field }, field)
        }
    }

    func testShellsOffRefusesADebugShellAndANodesToo() {
        let off = KubeContextSettings(shells: false, nodeShell: true)
        for name in ["kind-fake", "fake-prod"] {
            let context = context(name, settings: off)
            for write in [
                KubeTabWrite.debug(pod: "p", namespace: "shop", container: nil, image: "busybox:1.36"),
                .nodeShell(node: "n", namespace: "shop", image: "busybox:1.36"),
            ] {
                XCTAssertEqual(KubeProcessCheck.rule(write.verb, for: context).refused, KubeProcessCheck.shellsOff, "\(write.verb) on \(name)")
                XCTAssertThrowsError(try KubeCommands.command(write, in: context))
            }
            for write in [
                KubeTabWrite.drain(node: "n", namespace: "shop"), .rolloutUndo(deployment: "web", namespace: "shop", revision: 1, images: []),
            ] {
                XCTAssertNoThrow(try KubeCommands.command(write, in: context), "shells off leaves \(write.verb)")
            }
        }
        XCTAssertEqual(KubeProcessCheck.rule(.debug, for: context("fake-dev", settings: off)).refused, KubeProcessCheck.readOnly(.remote), "read-only first")
    }

    @MainActor
    func testANodesImageIsItsOwnThenTheDebugImage() {
        let model = KubernetesModel(proxies: KubeProxies())
        var configuration = KubernetesModel.Configuration()
        configuration.debugImage = "acme/debug:2"
        let read = configuration
        model.readConfiguration = { read }
        XCTAssertEqual(model.nodeShellImage(for: context("kind-fake")), "acme/debug:2", "the setting's")
        XCTAssertEqual(model.nodeShellImage(for: context("kind-fake", settings: KubeContextSettings(debugImage: "alpine:3.20"))), "alpine:3.20")
        let own = KubeContextSettings(debugImage: "alpine:3.20", nodeShellImage: "acme/node-tools:1")
        XCTAssertEqual(model.nodeShellImage(for: context("kind-fake", settings: own)), "acme/node-tools:1")
        XCTAssertEqual(model.debugImage(for: context("kind-fake", settings: own)), "alpine:3.20", "a pod's debug container keeps debugImage")
    }

    func testTypedNamesWhereRuleFourSays() {
        let prod = context("fake-prod")
        let local = context("kind-fake")
        XCTAssertTrue(KubeProcessCheck.rule(.drain, for: prod).typedName)
        XCTAssertTrue(KubeProcessCheck.rule(.rolloutUndo, for: prod).typedName)
        XCTAssertTrue(KubeProcessCheck.rule(.debug, for: prod).typedName, "a debug container stays in the pod's spec: rule 4's list")
        XCTAssertTrue(KubeProcessCheck.rule(.debug, for: prod).confirm)
        let debug = KubeTabWrite.debug(pod: "web-7d9", namespace: "shop", container: nil, image: "busybox:1.36")
        XCTAssertEqual(debug.confirmation(context: prod, rule: KubeProcessCheck.rule(.debug, for: prod)).typedName, "web-7d9")
        for verb in [KubeProcessVerb.drain, .rolloutUndo, .debug] {
            XCTAssertFalse(KubeProcessCheck.rule(verb, for: local).typedName, "\(verb) on a local context")
            XCTAssertTrue(KubeProcessCheck.rule(verb, for: local).confirm, "\(verb) is asked")
        }
    }

    func testTheConfirmationNamesTheContextNamespaceAndCommand() {
        let prod = context("fake-prod")
        let drain = KubeTabWrite.drain(node: "fake-node-1", namespace: "shop").confirmation(context: prod, rule: KubeProcessCheck.rule(.drain, for: prod))
        XCTAssertEqual(drain.title, "Drain node fake-node-1?")
        XCTAssertEqual(drain.scope, "PRODUCTION · fake-prod · cluster-wide", "it evicts across the cluster, whatever its -n")
        XCTAssertTrue(drain.production)
        XCTAssertNil(drain.verb, "a tab write, not a request")
        XCTAssertEqual(drain.typedName, "fake-node-1")
        XCTAssertEqual(drain.kubectl, "kubectl drain fake-node-1 --ignore-daemonsets --context fake-prod -n shop")
        XCTAssertTrue(drain.detail.contains("Runs in a new tab pinned to fake-prod: kubectl drain fake-node-1"), drain.detail)
        XCTAssertTrue(drain.detail.hasSuffix("Type fake-node-1 to confirm."), drain.detail)
        XCTAssertFalse(drain.accepts("fake-node-2"))
        XCTAssertTrue(drain.accepts(" fake-node-1 "))

        let local = context("kind-fake")
        let undo = KubeTabWrite.rolloutUndo(deployment: "web", namespace: "shop", revision: 1, images: ["nginx:1.26"])
        let asked = undo.confirmation(context: local, rule: KubeProcessCheck.rule(.rolloutUndo, for: local))
        XCTAssertEqual(asked.title, "Roll back deployment shop/web to revision 1?")
        XCTAssertEqual(asked.scope, "kind-fake · namespace shop")
        XCTAssertTrue(asked.detail.contains("(nginx:1.26)"), asked.detail)
        XCTAssertNil(asked.typedName)
        XCTAssertTrue(asked.accepts(""))
    }

    func testWhatEachIsReviewedFor() {
        let said = { (write: KubeTabWrite) in write.accesses.map { "\($0.access) @\($0.namespace ?? "cluster")" } }
        XCTAssertEqual(said(.drain(node: "n", namespace: "shop")), ["patch nodes @cluster", "create pods/eviction @cluster"])
        XCTAssertEqual(said(.rolloutUndo(deployment: "w", namespace: "shop", revision: 1, images: [])), ["patch deployments.apps @shop"])
        XCTAssertEqual(
            said(.debug(pod: "p", namespace: "shop", container: nil, image: "i")), ["patch pods/ephemeralcontainers @shop", "create pods/attach @shop"])
        XCTAssertEqual(said(.nodeShell(node: "n", namespace: "default", image: "i")), ["create pods @default", "create pods/attach @default"])
    }

    func testWhichKindsHaveThem() {
        XCTAssertTrue(KubeTabWrite.offered(.drain, on: KubeWritesTests.nodes))
        XCTAssertTrue(KubeTabWrite.offered(.nodeShell, on: KubeWritesTests.nodes))
        XCTAssertTrue(KubeTabWrite.offered(.rolloutUndo, on: KubeWritesTests.deployments))
        XCTAssertFalse(KubeTabWrite.offered(.rolloutUndo, on: KubeWritesTests.statefulsets))
        XCTAssertTrue(KubeTabWrite.offered(.debug, on: .pods))
        var old = KubeResourceKind.pods
        old.subresources = ["exec", "log"]
        XCTAssertFalse(KubeTabWrite.offered(.debug, on: old), "no ephemeral containers served")
        XCTAssertFalse(KubeTabWrite.offered(.drain, on: .pods))
    }

    func testRevisionsAreTheDeploymentsOwnNewestFirst() {
        let deployment: [String: Any] = [
            "metadata": ["name": "web", "uid": "u-1", "annotations": ["deployment.kubernetes.io/revision": "3"]]
        ]
        func set(_ name: String, _ revision: String, _ image: String, owner: String = "u-1", created: String = "2026-11-05T10:00:00Z") -> [String: Any] {
            [
                "metadata": [
                    "name": name, "creationTimestamp": created, "annotations": ["deployment.kubernetes.io/revision": revision],
                    "ownerReferences": [["kind": "Deployment", "name": "web", "uid": owner, "controller": true]],
                ],
                "spec": ["template": ["spec": ["containers": [["name": "app", "image": image]]]]],
            ]
        }
        let revisions = KubeRevision.of(
            [set("web-a", "1", "nginx:1.25"), set("web-c", "3", "nginx:1.27"), set("web-b", "2", "nginx:1.26"), set("other", "9", "x", owner: "u-2")],
            deployment: deployment)
        XCTAssertEqual(revisions.map(\.revision), [3, 2, 1], "another Deployment's ReplicaSet left out")
        XCTAssertEqual(revisions.map(\.current), [true, false, false])
        XCTAssertEqual(KubeRevision.choices(revisions).map(\.revision), [2, 1], "never the current one")
        let now = KubeTime.date("2026-11-05T13:00:00Z")!
        XCTAssertEqual(KubeRevision.choices(revisions).first?.label(now: now), "Revision 2 — nginx:1.26 · 3h ago")
        XCTAssertEqual(KubeRevision.choices(revisions, limit: 1).count, 1)
    }
}

/// The page's tab writes against the fake API server over `kind-fake`
/// (writable), `fake-dev` (read-only) and `fake-prod`: refused on a
/// read-only context before anything is sent; on a writable one reviewed,
/// asked, then typed into a tab — never before the button, never with a
/// wrong name.
@MainActor
final class KubeTabWritesPageTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!

    override func setUp() async throws {
        socket = "/tmp/otktw-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        api.addPod("web-1", namespace: "shop", labels: ["app": "web"])
        api.addPod("api-1", namespace: "shop", FakeKubeAPI.Pod(containers: 2))
        api.add("nodes", "fake-node-1", values: ["Status": "Ready", "Roles": "control-plane", "Version": "v1.34.1"])
        api.add(
            "deployments.apps", "web", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1],
            annotations: ["deployment.kubernetes.io/revision": "2"],
            fields: ["spec": ["replicas": 1, "selector": ["matchLabels": ["app": "web"]]]])
        let uid = api.uid("deployments.apps", "web", namespace: "shop") ?? ""
        for (name, revision, image) in [("web-2", "2", "nginx:1.27"), ("web-1x", "1", "nginx:1.26")] {
            api.add(
                "replicasets.apps", name, namespace: "shop", labels: ["app": "web"], annotations: ["deployment.kubernetes.io/revision": revision],
                fields: [
                    "metadata": ["ownerReferences": [["apiVersion": "apps/v1", "kind": "Deployment", "name": "web", "uid": uid, "controller": true]]],
                    "spec": ["template": ["spec": ["containers": [["name": "app", "image": image]]]]],
                ])
        }
    }

    override func tearDown() async throws {
        api?.stop()
    }

    private final class Box {
        var confirmations: [(KubeWriteConfirmation, (KubeWriteAnswer) -> Void)] = []
        var choices: [([String], (Int) -> Void)] = []
        var commands: [(String, String, String)] = []
    }

    private func page(current: String, kindFake settings: KubeContextSettings = KubeContextSettings(), readOnly: Set<String> = []) async throws -> (
        KubernetesPageModel, Box
    ) {
        let model = KubernetesModel(proxies: KubeProxies())
        let list = KubeContextList(
            contexts: ["fake-dev", "fake-prod"].map { KubeWritesTests.context($0, readOnly: readOnly.contains($0)) } + [KubeWritesTests.context("kind-fake", settings: settings)],
            current: current)
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
        return (page, box)
    }

    private func until(_ what: String, _ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func node(_ context: String) -> KubeObjectRef { KubeObjectRef(context: context, kind: KubeWritesTests.nodes, namespace: nil, name: "fake-node-1") }
    private func reviewed() -> [[String: String]] {
        api.requests.filter(\.isAccessReview).compactMap {
            (($0.json as? [String: Any])?["spec"] as? [String: Any])?["resourceAttributes"] as? [String: String]
        }
    }

    func testADrainIsReviewedAskedThenTypedIntoATab() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        page.runTabWrite(.drain, on: node("kind-fake"))
        try await until("asked") { box.confirmations.count == 1 }
        XCTAssertEqual(
            reviewed(), [["verb": "patch", "resource": "nodes", "group": ""], ["verb": "create", "resource": "pods", "group": "", "subresource": "eviction"]],
            "reviewed cluster-wide first")
        XCTAssertTrue(box.commands.isEmpty, "nothing typed before the button")
        let (confirmation, then) = box.confirmations[0]
        XCTAssertEqual(confirmation.scope, "kind-fake · cluster-wide")
        then("")
        XCTAssertEqual(box.commands.count, 1)
        XCTAssertEqual(box.commands.first?.0, "kubectl drain fake-node-1 --ignore-daemonsets --context kind-fake -n shop")
        XCTAssertEqual(box.commands.first?.1, "kind-fake")
        XCTAssertEqual(box.commands.first?.2, "shop", "its tab pinned to the namespace shown")
        XCTAssertEqual(page.writeStatus, .done("Draining node fake-node-1 in a new tab, in kind-fake."))
        XCTAssertTrue(api.writes.allSatisfy(\.isAccessReview), "the page itself sends no write: \(api.writes)")
    }

    func testTheContextChangingWhileAskedRunsNothing() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        page.runTabWrite(.drain, on: node("kind-fake"))
        try await until("asked") { box.confirmations.count == 1 }
        // The kubeconfig read again while the sheet is up: kind-fake now names another cluster.
        let moved = KubeContext(
            name: "kind-fake", cluster: "kind-other", server: "http://127.0.0.1:2", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: .local, settings: KubeContextSettings())
        let list = KubeContextList(contexts: ["fake-dev", "fake-prod"].map { KubeWritesTests.context($0) } + [moved], current: "kind-fake")
        page.model.load = { _ in list }
        page.model.reloadContexts()
        try await until("read again") { page.model.contexts.context(named: "kind-fake")?.cluster == "kind-other" }
        box.confirmations[0].1("")
        XCTAssertEqual(page.writeStatus, .failed("The context changed while it was asked: nothing was run."))
        XCTAssertTrue(box.commands.isEmpty, "nothing typed against a cluster the sheet didn't name")
        XCTAssertTrue(api.writes.allSatisfy(\.isAccessReview))
    }

    func testOnAReadOnlyContextNothingIsSentOrTyped() async throws {
        for current in ["fake-dev", "fake-prod"] {
            // fake-dev set read-only as the fixture's remote; fake-prod by its entry.
            let (page, box) = try await page(current: current, readOnly: [current])
            defer { page.model.hide() }
            let readOnly = KubeProcessCheck.readOnly(page.model.selected?.contextClass ?? .remote)
            for verb in [KubeProcessVerb.drain, .nodeShell] {
                XCTAssertEqual(page.tabWriteVerbs(for: node(current)).first { $0.title == KubeTabWrite.title(verb) }?.unavailable, readOnly)
                page.runTabWrite(verb, on: node(current))
                XCTAssertEqual(page.writeStatus, .failed(readOnly), "\(verb) on \(current)")
            }
            page.selection = ["shop/web-1"]
            XCTAssertTrue(page.press("E"))
            XCTAssertEqual(page.writeStatus, .failed(readOnly))
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(box.confirmations.isEmpty && box.commands.isEmpty)
            XCTAssertEqual(api.writes, [], "not even a review on \(current)")
        }
    }

    /// A node shell (stage 3b): refused until the context's nodeShell is
    /// on, sending nothing; then reviewed (create pods, pods/attach in the
    /// tab's namespace), asked with the node's name typed even on a local
    /// context — a wrong one runs nothing —, then typed into a tab pinned
    /// to the context: privileged, chrooted into the node.
    func testANodeShellIsOffUntilItsSettingThenReviewedTypedAndRun() async throws {
        do {
            let (page, box) = try await page(current: "kind-fake")
            defer { page.model.hide() }
            let off = "Node shells are off until the context's nodeShell setting is on."
            XCTAssertEqual(page.tabWriteVerbs(for: node("kind-fake")).first { $0.title == "Node Shell in a Tab…" }?.unavailable, off)
            page.runTabWrite(.nodeShell, on: node("kind-fake"))
            XCTAssertEqual(page.writeStatus, .failed(off))
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(box.confirmations.isEmpty && box.commands.isEmpty)
            XCTAssertEqual(reviewed().filter { $0["resource"] == "pods" }, [], "not even its review")
            XCTAssertTrue(api.writes.allSatisfy(\.isAccessReview))
        }
        api.forgetRequests()
        let (page, box) = try await page(current: "kind-fake", kindFake: KubeContextSettings(nodeShellImage: "acme/node-tools:1", nodeShell: true))
        defer { page.model.hide() }
        page.runTabWrite(.nodeShell, on: node("kind-fake"))
        try await until("asked") { box.confirmations.count == 1 }
        XCTAssertEqual(
            reviewed().filter { $0["resource"] == "pods" },
            [
                ["verb": "create", "resource": "pods", "group": "", "namespace": "shop"],
                ["verb": "create", "resource": "pods", "group": "", "subresource": "attach", "namespace": "shop"],
            ])
        let line =
            "kubectl debug node/fake-node-1 -it --profile=sysadmin --image=acme/node-tools:1 --context kind-fake -n shop -- chroot /host sh -c "
            + "'command -v bash >/dev/null && exec bash || exec sh'"
        let (confirmation, then) = box.confirmations[0]
        XCTAssertEqual(confirmation.title, "Open a shell on node fake-node-1?")
        XCTAssertEqual(confirmation.typedName, "fake-node-1")
        XCTAssertEqual(confirmation.kubectl, line)
        then("fake-node-2")
        XCTAssertEqual(page.writeStatus, .failed("The name typed wasn't fake-node-1: nothing was run."))
        XCTAssertTrue(box.commands.isEmpty)
        page.runTabWrite(.nodeShell, on: node("kind-fake"))
        try await until("asked again") { box.confirmations.count == 2 }
        box.confirmations[1].1("fake-node-1")
        XCTAssertEqual(box.commands.count, 1)
        XCTAssertEqual(box.commands.first?.0, line)
        XCTAssertEqual(box.commands.first?.1, "kind-fake")
        XCTAssertEqual(box.commands.first?.2, "shop")
        XCTAssertEqual(page.writeStatus, .done("A shell on node fake-node-1 in a new tab, in kind-fake."))
        XCTAssertTrue(api.writes.allSatisfy(\.isAccessReview), "the pod is kubectl's to make: \(api.writes)")
    }

    func testARefusedReviewStopsIt() async throws {
        api.deniedAccess = ["create pods/eviction"]
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        page.runTabWrite(.drain, on: node("kind-fake"))
        try await until("said") { page.writeStatus?.isFailure == true }
        XCTAssertEqual(
            page.writeStatus, .failed("The cluster's access review says you may not create pods/eviction cluster-wide: RBAC: create pods/eviction is not allowed"))
        XCTAssertTrue(box.confirmations.isEmpty && box.commands.isEmpty)
    }

    func testARollbackPicksARevisionWithItsImage() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        page.runTabWrite(.rolloutUndo, on: KubeObjectRef(context: "kind-fake", kind: KubeWritesTests.deployments, namespace: "shop", name: "web"))
        try await until("picked") { box.choices.count == 1 }
        XCTAssertEqual(box.choices[0].0.count, 1, "the current revision isn't offered")
        XCTAssertTrue(box.choices[0].0[0].hasPrefix("Revision 1 — nginx:1.26"), box.choices[0].0[0])
        box.choices[0].1(0)
        XCTAssertEqual(box.confirmations.count, 1)
        XCTAssertEqual(box.confirmations[0].0.title, "Roll back deployment shop/web to revision 1?")
        box.confirmations[0].1("")
        XCTAssertEqual(box.commands.first?.0, "kubectl rollout undo deployment/web --to-revision=1 --context kind-fake -n shop")
    }

    func testEDebugsThePodsChosenContainerWithTheImage() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        page.selection = ["shop/api-1"]
        XCTAssertTrue(page.press("E"))
        try await until("which container") { box.choices.count == 1 }
        XCTAssertEqual(box.choices[0].0, ["app (default)", "sidecar-1"])
        box.choices[0].1(1)
        XCTAssertEqual(box.confirmations.count, 1)
        box.confirmations[0].1("")
        XCTAssertEqual(box.commands.first?.0, "kubectl debug -it api-1 --image=busybox:1.36 --target=sidecar-1 --context kind-fake -n shop")
        XCTAssertTrue(
            reviewed().contains(["verb": "patch", "resource": "pods", "group": "", "subresource": "ephemeralcontainers", "namespace": "shop"]), "\(reviewed())")
    }

    func testOnProductionTheNameIsTypedAndAWrongOneRunsNothing() async throws {
        let (page, box) = try await page(current: "fake-prod")
        defer { page.model.hide() }
        try await until("writable") { page.model.selected?.isWritable == true }
        page.runTabWrite(.drain, on: node("fake-prod"))
        try await until("asked") { box.confirmations.count == 1 }
        XCTAssertEqual(box.confirmations[0].0.typedName, "fake-node-1")
        XCTAssertEqual(box.confirmations[0].0.scope, "PRODUCTION · fake-prod · cluster-wide")
        box.confirmations[0].1("fake-node-2")
        XCTAssertEqual(page.writeStatus, .failed("The name typed wasn't fake-node-1: nothing was run."))
        XCTAssertTrue(box.commands.isEmpty)
        // Set read-only while it asks: the button runs nothing.
        page.runTabWrite(.drain, on: node("fake-prod"))
        try await until("asked again") { box.confirmations.count == 2 }
        let readOnlyList = KubeContextList(
            contexts: ["fake-dev", "kind-fake"].map { KubeWritesTests.context($0) } + [KubeWritesTests.context("fake-prod", readOnly: true)], current: "fake-prod")
        page.model.load = { _ in readOnlyList }
        page.model.reloadContexts()
        try await until("read-only") { page.model.contexts.context(named: "fake-prod")?.isWritable == false }
        box.confirmations[1].1("fake-node-1")
        XCTAssertEqual(page.writeStatus, .failed(KubeProcessCheck.readOnly(.production)))
        XCTAssertTrue(box.commands.isEmpty)
    }

    // MARK: The image field (E, a node shell)

    func testTheImageIsAFieldPrefilledAndCheckedAsAReference() {
        let local = KubeWritesTests.context("kind-fake")
        let debug = KubeTabWrite.debug(pod: "web-7d9", namespace: "shop", container: "app", image: "busybox:1.36")
        let asked = debug.confirmation(context: local, rule: KubeProcessCheck.rule(.debug, for: local))
        XCTAssertEqual(asked.image, "busybox:1.36", "prefilled from the settings")
        XCTAssertNil(KubeTabWrite.drain(node: "n", namespace: "shop").confirmation(context: local, rule: KubeProcessCheck.rule(.drain, for: local)).image)
        XCTAssertEqual(
            KubeTabWrite.nodeShell(node: "n", namespace: "shop", image: "acme/node-tools:1").confirmation(
                context: local, rule: KubeProcessCheck.rule(.nodeShell, for: local)
            ).image, "acme/node-tools:1")
        XCTAssertEqual(
            debug.with(image: "ghcr.io/acme/tools:2.1"), .debug(pod: "web-7d9", namespace: "shop", container: "app", image: "ghcr.io/acme/tools:2.1"))
        XCTAssertEqual(KubeTabWrite.drain(node: "n", namespace: "shop").with(image: "x"), .drain(node: "n", namespace: "shop"))
        XCTAssertEqual(try KubeTabWrite.image(from: " alpine:3.20 ").get(), "alpine:3.20", "trimmed")
        XCTAssertEqual(try KubeTabWrite.image(from: "localhost:5000/acme/debug@sha256:" + String(repeating: "a", count: 64)).get().prefix(15), "localhost:5000/")
        for bad in ["", "  ", "busybox; rm -rf /", "--privileged", "Busy Box", "a:b:c:d", "$(id)"] {
            if case .success(let image) = KubeTabWrite.image(from: bad) { XCTFail("\(bad) taken as \(image)") }
        }
    }

    func testTheFieldsImageRunsAndABadOneRunsNothing() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        page.selection = ["shop/api-1"]
        XCTAssertTrue(page.press("E"))
        try await until("which container") { box.choices.count == 1 }
        box.choices[0].1(0)
        let edited = "kubectl debug -it api-1 --image=ghcr.io/acme/tools:2.1 --target=app --context kind-fake -n shop"
        XCTAssertFalse(box.confirmations[0].0.kubectl?.contains("tools:2.1") ?? true, "the first line was the setting's")
        box.confirmations[0].1(KubeWriteAnswer(typed: "", image: " ghcr.io/acme/tools:2.1 "))
        XCTAssertTrue(box.commands.isEmpty, "another image than the line showed runs nothing yet")
        XCTAssertEqual(box.confirmations.count, 2, "asked again")
        XCTAssertEqual(box.confirmations[1].0.kubectl, edited, "with the line that will run")
        XCTAssertTrue(box.confirmations[1].0.detail.contains(edited))
        XCTAssertEqual(box.confirmations[1].0.image, "ghcr.io/acme/tools:2.1")
        box.confirmations[1].1(KubeWriteAnswer(typed: "", image: "ghcr.io/acme/tools:2.1"))
        XCTAssertEqual(box.commands.first?.0, edited)
        XCTAssertEqual(box.commands.first?.0, box.confirmations[1].0.kubectl, "the line confirmed is the line run")
        XCTAssertEqual(page.model.debugImage(for: KubeWritesTests.context("kind-fake")), "busybox:1.36", "the setting stays the default")

        XCTAssertTrue(page.press("E"))
        try await until("which container again") { box.choices.count == 2 }
        box.choices[1].1(0)
        box.confirmations[2].1(KubeWriteAnswer(typed: "", image: "busybox:1.36 --privileged"))
        XCTAssertEqual(box.commands.count, 1, "nothing typed")
        XCTAssertEqual(box.confirmations.count, 3, "not asked again either")
        guard case .failed(let why) = page.writeStatus else { return XCTFail("\(String(describing: page.writeStatus))") }
        XCTAssertTrue(why.contains("isn't an image reference"), why)
    }
}
