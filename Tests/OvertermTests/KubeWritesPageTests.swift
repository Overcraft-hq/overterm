import Foundation
import XCTest

@testable import Overterm

/// The page's guard path against the fake API server, over three fictional
/// contexts on it: `kind-fake` (local, so writable), `fake-dev` (remote, so
/// read-only) and `fake-prod` (production: read-only until its switch).
/// Nothing is written before the access review and the confirmation; a
/// typed name is checked by the page; a read-only context sends nothing.
@MainActor
final class KubeWritesPageTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!

    override func setUpWithError() throws {
        socket = "/tmp/otkwp-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        api.addPod(
            "web-1", namespace: "shop",
            labels: ["app": "web"])
        api.setFields(
            "pods", "web-1", namespace: "shop",
            ["metadata": ["ownerReferences": [["apiVersion": "apps/v1", "kind": "ReplicaSet", "name": "web-7d9f", "controller": true]]]])
        api.addPod("api-1", namespace: "shop")
        api.add(
            "deployments.apps", "web", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1],
            fields: ["spec": ["replicas": 1, "template": ["metadata": ["labels": ["app": "web"]]]], "status": ["replicas": 1]])
    }

    override func tearDown() {
        api?.stop()
    }

    private final class Box {
        var confirmations: [(KubeWriteConfirmation, (KubeWriteAnswer) -> Void)] = []
        var confirms: [(String, String, () -> Void)] = []
    }

    private func page(current: String) async throws -> (KubernetesPageModel, Box) {
        let model = KubernetesModel(proxies: KubeProxies())
        let list = KubeContextList(
            contexts: ["fake-dev", "fake-prod", "kind-fake"].map { KubeWritesTests.context($0) }, current: current)
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.flushInterval = .milliseconds(20)
        model.statusInterval = .milliseconds(50)
        let socket = self.socket!
        // Writable as the model's context says it — production's switch included.
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name, writable: context.isWritable) }
        model.statusOverride = { _ in .open }
        model.access.run = { _, _, _ in .yes }
        let page = KubernetesPageModel(model: model)
        page.clock = { Date(timeIntervalSince1970: 1_793_000_000) }
        let box = Box()
        var actions = KubernetesActions(run: { _ in }, settings: {}, copy: { _ in }, copySecret: { _ in })
        actions.confirmWrite = { confirmation, then in box.confirmations.append((confirmation, then)) }
        actions.confirm = { _, detail, button, then in box.confirms.append((detail, button, then)) }
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

    private func written() -> [FakeKubeAPI.Request] { api.writes.filter { !$0.isAccessReview } }
    private func reviews() -> [FakeKubeAPI.Request] { api.requests.filter(\.isAccessReview) }

    /// The order: the access review, then the confirmation, and only after
    /// its button the request — which lands, and the list follows by its watch.
    func testAWriteIsReviewedThenConfirmedThenSent() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        page.selection = ["shop/api-1"]
        XCTAssertTrue(page.press("\u{7F}"), "⌫")
        try await until("asked") { box.confirmations.count == 1 }
        XCTAssertFalse(reviews().isEmpty, "reviewed first")
        let asked = reviews().compactMap { (($0.json as? [String: Any])?["spec"] as? [String: Any])?["resourceAttributes"] as? [String: String] }
        XCTAssertTrue(asked.contains(["verb": "delete", "resource": "pods", "group": "", "namespace": "shop"]), "\(asked)")
        XCTAssertEqual(written(), [], "nothing written before the confirmation")
        let (confirmation, then) = box.confirmations[0]
        XCTAssertEqual(confirmation.title, "Delete pod shop/api-1?")
        XCTAssertEqual(confirmation.scope, "kind-fake · namespace shop")
        XCTAssertTrue(confirmation.detail.contains("Equals: kubectl delete po api-1 --context kind-fake -n shop"), confirmation.detail)
        XCTAssertNil(confirmation.typedName, "not production: no name typed")
        then("")
        try await until("deleted") { self.api.pod("api-1", namespace: "shop") == nil }
        XCTAssertEqual(written().map(\.description), ["DELETE /api/v1/namespaces/shop/pods/api-1"])
        try await until("the list follows by its watch") { page.model.rows.count == 1 }
        try await until("said") { page.writeStatus == .done("Deleted pod shop/api-1 in kind-fake.") }
    }

    /// Cancel: the confirmation's `then` never runs, so nothing is sent.
    func testCancelSendsNothing() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        page.selection = ["shop/api-1"]
        XCTAssertTrue(page.press("\u{7F}"))
        try await until("asked") { box.confirmations.count == 1 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(written(), [])
        XCTAssertNotNil(api.pod("api-1", namespace: "shop"))
    }

    /// The access review's no greys the verb with why, and stops a key
    /// before anything is asked.
    func testARefusedReviewStopsBeforeTheConfirmation() async throws {
        api.deniedAccess = ["delete pods"]
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        page.selection = ["shop/api-1"]
        let why = "The cluster's access review says you may not delete pods in shop: RBAC: delete pods is not allowed"
        try await until("reviewed as the pod was picked") {
            page.verbs(for: ["shop/api-1"]).first { $0.title == "Delete…" }?.unavailable == why
        }
        XCTAssertNil(page.verbs(for: ["shop/api-1"]).first { $0.title == "Evict…" }?.unavailable, "another verb, another review")
        XCTAssertTrue(page.press("\u{7F}"))
        try await until("said") { page.writeStatus == .failed(why) }
        XCTAssertTrue(box.confirmations.isEmpty, "not asked")
        XCTAssertEqual(written(), [])
    }

    /// A read-only context: every write greyed with why, a key refused at
    /// once — not even a review is sent (its socket takes no POST).
    func testAReadOnlyContextSendsNothing() async throws {
        let (page, box) = try await page(current: "fake-dev")
        defer { page.model.hide() }
        page.selection = ["shop/api-1"]
        let verbs = page.verbs(for: ["shop/api-1"]).filter { KubeWriteVerb.allCases.map(\.title).contains($0.title) }
        XCTAssertEqual(verbs.count, 6)
        XCTAssertTrue(verbs.allSatisfy { $0.unavailable == "This context is read-only: Overterm changes nothing here (its writable setting)." })
        XCTAssertTrue(page.press("\u{7F}"))
        XCTAssertEqual(page.writeStatus, .failed("This context is read-only: Overterm changes nothing here (its writable setting)."))
        XCTAssertTrue(page.press("r"))
        page.write(.forceDelete, on: try XCTUnwrap(page.ref(for: "shop/api-1")))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(box.confirmations.isEmpty)
        XCTAssertEqual(api.writes, [], "nothing but GETs: no write, no review")
    }

    /// Production: greyed until its switch — asked, naming it — then each
    /// destructive write asks for the name, which the page checks.
    func testProductionNeedsItsSwitchThenTheTypedName() async throws {
        let (page, box) = try await page(current: "fake-prod")
        defer { page.model.hide() }
        page.selection = ["shop/api-1"]
        XCTAssertEqual(
            page.verbs(for: ["shop/api-1"]).first { $0.title == "Delete…" }?.unavailable,
            "Production is read-only: turn on writes for this session on its card first.")
        XCTAssertEqual(page.band, "PRODUCTION · fake-prod · read-only: Overterm changes nothing here")
        XCTAssertTrue(page.press("\u{7F}"))
        XCTAssertEqual(page.writeStatus, .failed("Production is read-only: turn on writes for this session on its card first."))
        XCTAssertEqual(api.writes, [])

        // The switch, asked first, naming the context.
        page.allowProductionWrites()
        XCTAssertEqual(box.confirms.count, 1)
        XCTAssertTrue(box.confirms[0].0.hasPrefix("PRODUCTION · fake-prod"), box.confirms[0].0)
        XCTAssertEqual(box.confirms[0].1, "Allow Writes Until Quit")
        XCTAssertFalse(page.model.productionWrites.isOn("fake-prod"), "not before the button")
        box.confirms[0].2()
        try await until("on, listed again") { page.model.selected?.isWritable == true && page.model.rows.count == 2 }
        XCTAssertTrue(page.productionWritesOn)
        XCTAssertEqual(page.band, "PRODUCTION · fake-prod · writes on until quit: each one asked, a destructive one by its name")

        // A delete now asks for the name.
        XCTAssertTrue(page.press("\u{7F}"))
        try await until("asked") { box.confirmations.count == 1 }
        let (confirmation, then) = box.confirmations[0]
        XCTAssertTrue(confirmation.production)
        XCTAssertEqual(confirmation.typedName, "api-1")
        XCTAssertEqual(confirmation.scope, "PRODUCTION · fake-prod · namespace shop")
        then("api-2")
        XCTAssertEqual(page.writeStatus, .failed("The name typed wasn't api-1: nothing was changed."))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(written(), [], "the wrong name sends nothing")
        XCTAssertTrue(page.press("\u{7F}"))
        try await until("asked again") { box.confirmations.count == 2 }
        box.confirmations[1].1("api-1")
        try await until("deleted") { self.api.pod("api-1", namespace: "shop") == nil }
        XCTAssertEqual(written().map(\.description), ["DELETE /api/v1/namespaces/shop/pods/api-1"])

        // Off again: greyed, and the client refuses.
        page.endProductionWrites()
        try await until("off, listed again") { page.model.selected?.isWritable == false && page.model.rows.count == 1 }
        page.selection = ["shop/web-1"]
        XCTAssertTrue(page.press("r"))
        XCTAssertEqual(page.writeStatus, .failed("Production is read-only: turn on writes for this session on its card first."))
        XCTAssertEqual(written().count, 1)
    }

    /// Writes turned off while the confirmation shows: the button sends nothing.
    func testWritesTurnedOffMeanwhileStopAtTheButton() async throws {
        let (page, box) = try await page(current: "fake-prod")
        defer { page.model.hide() }
        await page.model.setProductionWrites(true, for: "fake-prod")
        try await until("listed again") { page.model.rows.count == 2 }
        page.selection = ["shop/web-1"]
        page.write(.evict, on: try XCTUnwrap(page.ref(for: "shop/web-1")))
        try await until("asked") { box.confirmations.count == 1 }
        XCTAssertNil(box.confirmations[0].0.typedName, "an eviction respects PDBs: not typed")
        await page.model.setProductionWrites(false, for: "fake-prod")
        box.confirmations[0].1("")
        XCTAssertEqual(page.writeStatus, .failed("Production is read-only: turn on writes for this session on its card first."))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(written(), [])
    }

    /// The kubeconfig read again while the confirmation shows points a
    /// writable context's name at another cluster: the review and the
    /// reads were the old one's, so the button sends nothing.
    func testAContextRepointedMeanwhileStopsAtTheButton() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        page.selection = ["shop/api-1"]
        XCTAssertTrue(page.press("\u{7F}"), "⌫")
        try await until("asked") { box.confirmations.count == 1 }
        let old = try XCTUnwrap(page.model.contexts.context(named: "kind-fake"))
        let moved = KubeContext(
            name: old.name, cluster: "globex-eks", server: "https://globex.example:443", namespace: old.namespace, user: old.user, auth: old.auth,
            file: nil, contextClass: old.contextClass, settings: old.settings)
        XCTAssertTrue(moved.isWritable, "still writable by its class")
        let list = KubeContextList(
            contexts: ["fake-dev", "fake-prod"].map { KubeWritesTests.context($0) } + [moved], current: "kind-fake")
        page.model.load = { _ in list }
        page.model.reloadContexts()
        try await until("read again") { page.model.contexts.context(named: "kind-fake")?.server == moved.server }
        box.confirmations[0].1("")
        XCTAssertEqual(page.writeStatus, .failed(KubernetesPageModel.writeContextChanged))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(written(), [])
        XCTAssertNotNil(api.pod("api-1", namespace: "shop"))
    }

    /// `r` on a pod (its controller named), scale (`+`, the sheet's number),
    /// a rollout restart, an eviction a PDB refuses, finalizers, force
    /// delete — each request exactly, after its review and confirmation.
    func testEachVerbThroughThePage() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        let pod = try XCTUnwrap(page.ref(for: "shop/web-1"))

        // r on a pod: deleted so its ReplicaSet makes it again — its metadata read, never more.
        page.selection = ["shop/web-1"]
        XCTAssertTrue(page.press("r"))
        try await until("asked") { box.confirmations.count == 1 }
        XCTAssertTrue(box.confirmations[0].0.detail.contains("Its ReplicaSet web-7d9f makes a new pod"), box.confirmations[0].0.detail)
        XCTAssertTrue(api.requests.contains { $0.path == "/api/v1/namespaces/shop/pods/web-1" && $0.accept.contains("as=PartialObjectMetadata") })
        box.confirmations[0].1("")
        try await until("deleted") { self.api.pod("web-1", namespace: "shop") == nil }
        _ = pod

        // Scale: + reads the scale subresource, asks 1 → 2.
        let deployment = KubeObjectRef(context: "kind-fake", kind: KubeWritesTests.deployments, namespace: "shop", name: "web")
        page.write(.scale, on: deployment, scale: .by(1))
        try await until("asked") { box.confirmations.count == 2 }
        XCTAssertEqual(box.confirmations[1].0.title, "Scale deployment shop/web from 1 to 2 replicas?")
        box.confirmations[1].1("")
        try await until("scaled") { self.written().last?.path == "/apis/apps/v1/namespaces/shop/deployments/web/scale" }
        let scaled = try XCTUnwrap(written().last)
        XCTAssertEqual(scaled.method, "PATCH")
        XCTAssertEqual(scaled.contentType, "application/merge-patch+json")
        XCTAssertEqual(String(decoding: scaled.body, as: UTF8.self), #"{"spec":{"replicas":2}}"#)
        try await until("said") { page.writeStatus == .done("Scaled deployment shop/web from 1 to 2 in kind-fake.") }

        // =: the sheet with the current count; a bad number refused there.
        page.openScaleSheet(deployment)
        try await until("read") { page.scaleDraft?.current == 2 && page.scaleDraft?.replicas == "2" }
        page.scaleDraft?.replicas = "-1"
        page.confirmScale()
        XCTAssertEqual(page.scaleDraft?.problem, "A whole number of replicas, 0 to 10000.")
        page.scaleDraft?.replicas = "0"
        page.confirmScale()
        XCTAssertNil(page.scaleDraft)
        try await until("asked") { box.confirmations.count == 3 }
        XCTAssertNil(box.confirmations[2].0.typedName, "to 0 asks for the name on production only")
        box.confirmations[2].1("")
        try await until("scaled to 0") { String(decoding: self.written().last?.body ?? Data(), as: UTF8.self) == #"{"spec":{"replicas":0}}"# }

        // Restart: kubectl's annotation, the page's clock.
        page.write(.restart, on: deployment)
        try await until("asked") { box.confirmations.count == 4 }
        box.confirmations[3].1("")
        try await until("restarted") { self.written().last?.contentType == "application/strategic-merge-patch+json" }
        XCTAssertTrue(String(decoding: written().last!.body, as: UTF8.self).contains(#""kubectl.kubernetes.io\/restartedAt":"2026-10-26T07:33:20Z""#))

        // Evict, a PDB refusing: said, the pod kept.
        api.evictionBlock = "The disruption budget api-pdb needs 1 healthy pods and has 1 currently"
        let api1 = try XCTUnwrap(page.ref(for: "shop/api-1"))
        page.write(.evict, on: api1)
        try await until("asked") { box.confirmations.count == 5 }
        box.confirmations[4].1("")
        try await until("said") { page.writeStatus?.isFailure == true }
        XCTAssertTrue(page.writeStatus?.text.hasPrefix("A PodDisruptionBudget doesn't allow evicting pod shop/api-1 now") == true, page.writeStatus?.text ?? "")
        XCTAssertTrue(page.writeStatus?.text.contains("api-pdb needs 1 healthy pods") == true)
        XCTAssertNotNil(api.pod("api-1", namespace: "shop"))
        api.evictionBlock = nil

        // Finalizers: none to remove says so; one there asks for the name on every class.
        page.write(.removeFinalizers, on: api1)
        try await until("said") { page.writeStatus == .failed("pod shop/api-1 has no finalizers.") }
        XCTAssertEqual(box.confirmations.count, 5)
        api.setFields("pods", "api-1", namespace: "shop", ["metadata": ["finalizers": ["example.com/guard"]]])
        page.write(.removeFinalizers, on: api1)
        try await until("asked") { box.confirmations.count == 6 }
        XCTAssertEqual(box.confirmations[5].0.typedName, "api-1")
        XCTAssertTrue(box.confirmations[5].0.detail.contains("example.com/guard"))
        box.confirmations[5].1("api-1")
        try await until("patched") { self.written().last?.contentType == "application/json-patch+json" }

        // Force delete: grace 0, the name typed.
        page.write(.forceDelete, on: api1)
        try await until("asked") { box.confirmations.count == 7 }
        XCTAssertEqual(box.confirmations[6].0.typedName, "api-1")
        box.confirmations[6].1("api-1")
        try await until("gone") { self.api.pod("api-1", namespace: "shop") == nil }
        XCTAssertEqual((written().last?.json as? [String: Any])?["gracePeriodSeconds"] as? Int, 0)
        XCTAssertTrue(written().allSatisfy { !$0.path.contains("/exec") && !$0.path.contains("/portforward") })
    }
}
