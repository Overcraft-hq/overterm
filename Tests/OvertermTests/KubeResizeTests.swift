import Foundation
import XCTest

@testable import Overterm

/// In-place resize (stage 3b): what a pod's containers say, what is typed
/// checked against it, the patch and the request it is, the kubectl it
/// equals, the class check — refused where the server doesn't serve
/// `pods/resize`, and on every read-only context. Pure.
final class KubeResizeTests: XCTestCase {
    nonisolated(unsafe) private static let pod: [String: Any] = [
        "spec": [
            "containers": [
                ["name": "app", "image": "nginx:1.27", "resources": ["requests": ["cpu": "100m", "memory": "128Mi"], "limits": ["cpu": "500m", "memory": "256Mi"]]],
                ["name": "sidecar", "image": "envoy:1", "resources": ["requests": ["cpu": 1]]],
            ],
            "initContainers": [["name": "migrate", "image": "busybox:1.36"]],
        ]
    ]

    private var current: [KubeContainerResources] { KubeResize.containers(of: Self.pod) }

    private func typed(_ change: (inout [KubeContainerResources]) -> Void) -> [KubeContainerResources] {
        var typed = current
        change(&typed)
        return typed
    }

    private func ref(_ context: String = "kind-fake") -> KubeObjectRef {
        KubeObjectRef(context: context, kind: .pods, namespace: "shop", name: "web-1")
    }

    func testAPodsRegularContainersAreRead() {
        XCTAssertEqual(
            current,
            [
                KubeContainerResources(name: "app", cpuRequest: "100m", cpuLimit: "500m", memoryRequest: "128Mi", memoryLimit: "256Mi"),
                KubeContainerResources(name: "sidecar", cpuRequest: "1"),
            ], "not its init containers; a number said as text")
        XCTAssertEqual(KubeResize.containers(of: [:]), [])
    }

    func testOnlyWhatChangedIsPlanned() throws {
        let changes = try KubeResize.plan(
            current: current,
            typed: typed {
                $0[0].cpuRequest = " 250m "; $0[0].memoryLimit = "512Mi"; $0[1].cpuLimit = "2"
            }
        ).get()
        XCTAssertEqual(
            changes,
            [
                KubeResize.Change(container: "app", field: .cpuRequest, from: "100m", to: "250m"),
                KubeResize.Change(container: "app", field: .memoryLimit, from: "256Mi", to: "512Mi"),
                KubeResize.Change(container: "sidecar", field: .cpuLimit, from: nil, to: "2"),
            ])
        XCTAssertEqual(KubeResize.said(changes), "app: cpu request 100m → 250m\napp: memory limit 256Mi → 512Mi\nsidecar: cpu limit unset → 2")
        if case .success = KubeResize.plan(current: current, typed: typed { $0[0].cpuRequest = "0.1" }) { XCTFail("the same quantity is no change") }
    }

    func testWhatWontDoIsSaid() {
        func problem(_ change: (inout [KubeContainerResources]) -> Void) -> String? {
            if case .failure(let refused) = KubeResize.plan(current: current, typed: typed(change)) { return refused.reason }
            return nil
        }
        XCTAssertEqual(problem { _ in }, "Nothing changed.")
        XCTAssertEqual(problem { $0[0].cpuRequest = "lots" }, "app's cpu request: “lots” isn't a quantity (250m, 1, 512Mi, 2Gi).")
        XCTAssertEqual(problem { $0[0].cpuRequest = "0" }, "app's cpu request: “0” isn't a quantity (250m, 1, 512Mi, 2Gi).")
        XCTAssertEqual(problem { $0[0].cpuLimit = "1Gi" }, "app's cpu limit: cpu is in cores or millicores (500m, 2), not bytes.")
        XCTAssertEqual(problem { $0[0].cpuLimit = "2G" }, "app's cpu limit: cpu is in cores or millicores (500m, 2) — “2G” would be millions or more of cores.")
        XCTAssertEqual(problem { $0[0].cpuRequest = "500M" }, "app's cpu request: cpu is in cores or millicores (500m, 2) — “500M” would be millions or more of cores.")
        XCTAssertEqual(problem { $0[0].cpuLimit = "2k" }, "app's cpu limit: cpu is in cores or millicores (500m, 2) — “2k” would be thousands of cores.")
        XCTAssertEqual(problem { $0[0].memoryLimit = "512m" }, "app's memory limit: “512m” is millibytes — memory is in bytes (512Mi, 2Gi, 512M).")
        XCTAssertNil(problem { $0[0].memoryLimit = "512M" }, "decimal megabytes are memory")
        XCTAssertEqual(problem { $0[0].memoryLimit = "" }, "app's memory limit (256Mi) can't be removed in place: its QoS class would change.")
        XCTAssertEqual(problem { $0[0].memoryRequest = "1Gi" }, "app's memory request (1Gi) is over its limit (256Mi).")
        XCTAssertEqual(problem { $0[1].cpuLimit = "500m" }, "sidecar's cpu request (1) is over its limit (500m).")
    }

    func testTheChangesAreRebasedOnThePodAsReadAgain() {
        let changes = [
            KubeResize.Change(container: "app", field: .cpuRequest, from: "100m", to: "250m"),
            KubeResize.Change(container: "app", field: .memoryLimit, from: "256Mi", to: "512Mi"),
        ]
        var now = current
        now[0].cpuRequest = "200m"
        now[0].memoryLimit = "512Mi"
        XCTAssertEqual(
            try KubeResize.rebase(changes, on: now)?.get(), [KubeResize.Change(container: "app", field: .cpuRequest, from: "200m", to: "250m")],
            "said as it is now; what it says already dropped")
        XCTAssertNil(KubeResize.rebase(changes, on: [KubeContainerResources(name: "other")]), "a container gone")
        now[0].cpuRequest = "250m"
        XCTAssertEqual(try KubeResize.rebase(changes, on: now)?.get(), [], "nothing left to change")

        // Planned again on what was read: a limit lowered meanwhile under the request asked for.
        var lowered = current
        lowered[0].cpuLimit = "200m"
        guard case .failure(let refused) = KubeResize.rebase(changes, on: lowered) else { return XCTFail("refused before the confirmation") }
        XCTAssertEqual(refused.reason, "app's cpu request (250m) is over its limit (200m).")
    }

    func testTheQoSClassIsKubernetes() {
        func pod(_ containers: KubeContainerResources...) -> KubeResize.QoS { KubeResize.qos(containers) }
        XCTAssertEqual(pod(KubeContainerResources(name: "a"), KubeContainerResources(name: "b", cpuRequest: "0")), .bestEffort, "zero counts as unset")
        XCTAssertEqual(pod(KubeContainerResources(name: "a", cpuRequest: "100m")), .burstable)
        XCTAssertEqual(
            pod(KubeContainerResources(name: "a", cpuRequest: "0.5", cpuLimit: "500m", memoryRequest: "1Gi", memoryLimit: "1024Mi")), .guaranteed,
            "equal quantities, however written")
        XCTAssertEqual(pod(KubeContainerResources(name: "a", cpuLimit: "1", memoryLimit: "1Gi")), .guaranteed, "a missing request is its limit")
        XCTAssertEqual(
            pod(
                KubeContainerResources(name: "a", cpuRequest: "1", cpuLimit: "1", memoryRequest: "1Gi", memoryLimit: "1Gi"),
                KubeContainerResources(name: "init")), .burstable, "an init container without limits")
        XCTAssertEqual(pod(KubeContainerResources(name: "a", cpuRequest: "1", cpuLimit: "1", memoryRequest: "512Mi", memoryLimit: "1Gi")), .burstable)
        let pod = ["spec": ["initContainers": [["name": "migrate", "resources": ["limits": ["cpu": "1"]]]]]]
        XCTAssertEqual(KubeResize.initContainers(of: pod), [KubeContainerResources(name: "migrate", cpuLimit: "1")])
    }

    func testAnEditThatChangesTheQoSClassIsRefused() {
        let guaranteed = [KubeContainerResources(name: "app", cpuRequest: "500m", cpuLimit: "500m", memoryRequest: "256Mi", memoryLimit: "256Mi")]
        func problem(_ current: [KubeContainerResources], others: [KubeContainerResources] = [], _ change: (inout [KubeContainerResources]) -> Void) -> String? {
            var typed = current
            change(&typed)
            if case .failure(let refused) = KubeResize.plan(current: current, typed: typed, others: others) { return refused.reason }
            return nil
        }
        // A Guaranteed pod's limit raised alone would make it Burstable.
        XCTAssertEqual(
            problem(guaranteed) { $0[0].cpuLimit = "1" },
            "The pod is Guaranteed (each request equals its limit): change a request and its limit together — its QoS class can't change in place.")
        XCTAssertEqual(problem(guaranteed) { $0[0].memoryLimit = "512Mi" }, problem(guaranteed) { $0[0].cpuLimit = "1" })
        XCTAssertNil(
            problem(guaranteed) {
                $0[0].cpuRequest = "1"; $0[0].cpuLimit = "1"
            }, "both together keep it Guaranteed")
        // A BestEffort container given its first request.
        XCTAssertEqual(
            problem([KubeContainerResources(name: "app")]) { $0[0].cpuRequest = "100m" },
            "The pod is BestEffort (no requests or limits): none can be given in place — its QoS class can't change.")
        // A Burstable pod given limits equal to its requests everywhere.
        let burstable = [KubeContainerResources(name: "app", cpuRequest: "250m", memoryRequest: "128Mi")]
        XCTAssertEqual(
            problem(burstable) {
                $0[0].cpuLimit = "250m"; $0[0].memoryLimit = "128Mi"
            },
            "Every request would equal its limit, making the pod Guaranteed: its QoS class (Burstable) can't change in place.")
        XCTAssertNil(
            problem(burstable, others: [KubeContainerResources(name: "migrate")]) {
                $0[0].cpuLimit = "250m"; $0[0].memoryLimit = "128Mi"
            },
            "an init container without limits keeps it Burstable")
        XCTAssertNil(
            problem(burstable) {
                $0[0].cpuLimit = "500m"; $0[0].memoryLimit = "128Mi"
            }, "still Burstable")
    }

    func testTheRequestIsTheResizeSubresourcesStrategicPatch() throws {
        let changes = [
            KubeResize.Change(container: "app", field: .cpuRequest, from: "100m", to: "250m"),
            KubeResize.Change(container: "app", field: .memoryLimit, from: "256Mi", to: "512Mi"),
            KubeResize.Change(container: "sidecar", field: .cpuLimit, from: nil, to: "2"),
        ]
        let request = KubeResize.request(ref(), changes)
        XCTAssertEqual(request.method, .PATCH)
        XCTAssertEqual(request.path, "/api/v1/namespaces/shop/pods/web-1/resize?fieldManager=overterm")
        XCTAssertEqual(request.contentType, "application/strategic-merge-patch+json")
        let body = try XCTUnwrap(request.json as? [String: Any])
        XCTAssertEqual(KubeWrites.encode(body), KubeWrites.encode(KubeResize.patch(changes)))
        let containers = try XCTUnwrap((body["spec"] as? [String: Any])?["containers"] as? [[String: Any]])
        XCTAssertEqual(containers.compactMap { $0["name"] as? String }, ["app", "sidecar"], "by name, the strategic merge key, in order")
        XCTAssertEqual(
            containers[0]["resources"] as? [String: [String: String]], ["requests": ["cpu": "250m"], "limits": ["memory": "512Mi"]], "only what changed")
        XCTAssertEqual(
            KubeWrites.kubectl(.resize, ref(), resize: changes),
            #"kubectl patch po web-1 --subresource resize -p '{"spec":{"containers":[{"name":"app","resources":{"limits":{"memory":"512Mi"},"requests":{"cpu":"250m"}}},{"name":"sidecar","resources":{"limits":{"cpu":"2"}}}]}}' --context kind-fake -n shop"#
        )
    }

    func testTheClassCheckAndTheServer() {
        XCTAssertTrue(KubeWriteCheck.offered(.resize, on: .pods))
        XCTAssertFalse(KubeWriteCheck.offered(.resize, on: KubeWritesTests.deployments), "a pod's, not its controller's")
        var old = KubeResourceKind.pods
        old.subresources.removeAll { $0 == "resize" }
        XCTAssertTrue(KubeWriteCheck.offered(.resize, on: old), "offered, so the refusal is said")
        XCTAssertEqual(KubeWriteCheck.rule(.resize, for: KubeWritesTests.context("kind-fake"), kind: old).refused, KubeResize.unsupported)
        let rule = KubeWriteCheck.rule(.resize, for: KubeWritesTests.context("kind-fake"), kind: .pods)
        XCTAssertNil(rule.refused)
        XCTAssertEqual(rule.access, KubeAccess(verb: "patch", resource: "pods/resize"))
        XCTAssertFalse(rule.typedName, "not in rule 4's list: it is changed back the same way")
        XCTAssertNotNil(rule.warning, "a controller's pod gets its template's values back")
        for name in ["fake-dev", "fake-prod", "globex-eu-west-1-prod"] {
            XCTAssertNotNil(KubeWriteCheck.rule(.resize, for: KubeWritesTests.context(name, readOnly: true), kind: .pods).refused, name)
        }
        XCTAssertNil(KubeWriteCheck.rule(.resize, for: KubeWritesTests.context("fake-prod"), kind: .pods).refused, "production: writable by default")
        XCTAssertEqual(
            KubeAccessReview.attributes(KubeAccess(verb: "patch", resource: "pods/resize"), namespace: "shop"),
            ["verb": "patch", "resource": "pods", "group": "", "subresource": "resize", "namespace": "shop"])
    }

    func testTheConfirmationListsEachChange() {
        let changes = [KubeResize.Change(container: "app", field: .cpuRequest, from: "100m", to: "250m")]
        let context = KubeWritesTests.context("fake-prod")
        let confirmation = KubeWriteConfirmation.make(
            .resize, ref("fake-prod"), context: context, rule: KubeWriteCheck.rule(.resize, for: context, kind: .pods), resize: changes)
        XCTAssertEqual(confirmation.title, "Resize pod shop/web-1 in place?")
        XCTAssertEqual(confirmation.scope, "PRODUCTION · fake-prod · namespace shop")
        XCTAssertTrue(confirmation.detail.contains("app: cpu request 100m → 250m"), confirmation.detail)
        XCTAssertTrue(confirmation.detail.contains("Equals: kubectl patch po web-1 --subresource resize"), confirmation.detail)
        XCTAssertEqual(confirmation.button, "Resize")
        XCTAssertNil(confirmation.typedName)
    }
}

/// Resize in Place… through the page's one guard path, against the fake
/// API server: the sheet's values read from the pod, the access review
/// (patch pods/resize) before the pod is read again, the confirmation,
/// then the `resize` subresource's PATCH — and refusals with nothing sent:
/// a server that doesn't serve it, a read-only context.
@MainActor
final class KubeResizePageTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!

    override func setUp() async throws {
        socket = "/tmp/otkrs-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        var pod = FakeKubeAPI.Pod(containers: 2)
        pod.resources = ["app": ["requests": ["cpu": "100m", "memory": "128Mi"], "limits": ["memory": "256Mi"]]]
        api.addPod("web-1", namespace: "shop", pod)
    }

    override func tearDown() async throws {
        api?.stop()
    }

    private final class Box {
        var confirmations: [(KubeWriteConfirmation, (KubeWriteAnswer) -> Void)] = []
    }

    private func page(current: String, readOnly: Set<String> = []) async throws -> (KubernetesPageModel, Box) {
        let model = KubernetesModel(proxies: KubeProxies())
        let list = KubeContextList(
            contexts: ["fake-dev", "fake-prod", "kind-fake"].map { KubeWritesTests.context($0, readOnly: readOnly.contains($0)) }, current: current)
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
        page.actions = actions
        model.show()
        try await until("listed") { model.rows.count == 1 && model.selectedName == current && model.discovery != nil }
        return (page, box)
    }

    private func until(_ what: String, _ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func pods(_ page: KubernetesPageModel) throws -> KubeResourceKind { try XCTUnwrap(page.model.discovery?.kind("pods")) }
    private func written() -> [FakeKubeAPI.Request] { api.writes.filter { !$0.isAccessReview } }

    func testTheSheetsValuesAreReviewedConfirmedThenPatched() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        let ref = KubeObjectRef(context: "kind-fake", kind: try pods(page), namespace: "shop", name: "web-1")
        let verb = try XCTUnwrap(page.writeVerbs(for: ref).first { $0.title == KubeWriteVerb.resize.title })
        try await until("reviewed") { page.writeVerbs(for: ref).first { $0.title == KubeWriteVerb.resize.title }?.unavailable == nil }
        verb.perform()
        try await until("read") { page.resizeDraft?.current != nil }
        XCTAssertEqual(page.resizeDraft?.typed.map(\.name), ["app", "sidecar-1"])
        XCTAssertEqual(page.resizeDraft?.typed.first, KubeContainerResources(name: "app", cpuRequest: "100m", memoryRequest: "128Mi", memoryLimit: "256Mi"))
        page.resizeDraft?.typed[0].memoryLimit = ""
        page.confirmResize()
        XCTAssertEqual(page.resizeDraft?.problem, "app's memory limit (256Mi) can't be removed in place: its QoS class would change.")
        page.resizeDraft?.typed[0].memoryLimit = "512Mi"
        page.resizeDraft?.typed[0].cpuRequest = "250m"
        // What the menu asked is forgotten: the write's own review counted.
        page.model.writeAccess.forget(context: "kind-fake")
        api.forgetRequests()
        page.confirmResize()
        XCTAssertNil(page.resizeDraft, "the sheet steps aside for the write's own confirmation")
        try await until("asked") { box.confirmations.count == 1 }
        let order = api.requests.map(\.description)
        let review = try XCTUnwrap(order.firstIndex(of: "POST /apis/authorization.k8s.io/v1/selfsubjectaccessreviews"))
        let read = try XCTUnwrap(order.firstIndex(of: "GET /api/v1/namespaces/shop/pods/web-1"))
        XCTAssertLessThan(review, read, "reviewed before it is read again")
        let attributes = api.requests.filter(\.isAccessReview).compactMap {
            (($0.json as? [String: Any])?["spec"] as? [String: Any])?["resourceAttributes"] as? [String: String]
        }
        XCTAssertEqual(attributes, [["verb": "patch", "resource": "pods", "group": "", "subresource": "resize", "namespace": "shop"]])
        XCTAssertEqual(written(), [], "nothing sent before the button")
        let (confirmation, then) = box.confirmations[0]
        XCTAssertEqual(confirmation.title, "Resize pod shop/web-1 in place?")
        XCTAssertEqual(confirmation.scope, "kind-fake · namespace shop")
        XCTAssertTrue(confirmation.detail.contains("app: cpu request 100m → 250m\napp: memory limit 256Mi → 512Mi"), confirmation.detail)
        then("")
        try await until("patched") { self.written().count == 1 }
        XCTAssertEqual(written().map(\.description), ["PATCH /api/v1/namespaces/shop/pods/web-1/resize"])
        XCTAssertEqual(written().first?.query["fieldManager"], "overterm")
        let client = KubeClient(KubeSocketConnection(socket: socket, context: "kind-fake"))
        let pod = try await client.object(try pods(page), namespace: "shop", name: "web-1").json
        let app = KubeResize.containers(of: pod).first
        XCTAssertEqual(app, KubeContainerResources(name: "app", cpuRequest: "250m", memoryRequest: "128Mi", memoryLimit: "512Mi"))
        XCTAssertEqual(
            (((pod["spec"] as? [String: Any])?["containers"] as? [[String: Any]])?.first?["image"]) as? String, "nginx:1.27", "only its resources changed")
        try await until("said") {
            page.writeStatus == .done("Resized pod shop/web-1 in place in kind-fake: the kubelet applies it — its PodResizePending condition says if it can't.")
        }
    }

    func testAPodChangedMeanwhileIsRefusedBeforeTheConfirmation() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        let ref = KubeObjectRef(context: "kind-fake", kind: try pods(page), namespace: "shop", name: "web-1")
        page.openResizeSheet(ref)
        try await until("read") { page.resizeDraft?.current != nil }
        page.resizeDraft?.typed[0].memoryRequest = "200Mi"
        // Another write between its key and its confirmation: said, the values kept.
        page.writeChecking = 99
        page.confirmResize()
        XCTAssertEqual(page.resizeDraft?.problem, "Another write is being checked: try again once it is asked or done.")
        XCTAssertEqual(page.resizeDraft?.typed.first?.memoryRequest, "200Mi")
        page.writeChecking = nil
        // The limit lowered under it after the sheet read the pod.
        api.updatePod("web-1", namespace: "shop") { $0.resources["app"]?["limits"]?["memory"] = "150Mi" }
        page.confirmResize()
        XCTAssertNil(page.resizeDraft)
        try await until("refused") {
            page.writeStatus == .failed("pod shop/web-1 changed meanwhile, nothing was sent: app's memory request (200Mi) is over its limit (150Mi).")
        }
        XCTAssertTrue(box.confirmations.isEmpty, "never asked")
        XCTAssertEqual(written(), [], "nothing sent")
    }

    func testTheFakeRefusesAClassChangeAsTheServerDoes() async throws {
        api.addPod("plain-1", namespace: "shop", FakeKubeAPI.Pod())
        let client = KubeClient(KubeSocketConnection(socket: socket, context: "kind-fake", writable: true))
        let ref = KubeObjectRef(context: "kind-fake", kind: .pods, namespace: "shop", name: "plain-1")
        do {
            try await client.write(KubeResize.request(ref, [KubeResize.Change(container: "app", field: .cpuRequest, from: nil, to: "100m")]))
            XCTFail("BestEffort can't be given a request")
        } catch let error as KubeAPIError {
            XCTAssertEqual(error.status, 422)
            XCTAssertTrue(error.message.contains("Pod QOS Class may not change as a result of resizing"), error.message)
        }
        XCTAssertNil(api.pod("plain-1", namespace: "shop")?.resources["app"], "nothing changed")
        try await client.write(
            KubeResize.request(
                KubeObjectRef(context: "kind-fake", kind: .pods, namespace: "shop", name: "web-1"),
                [
                    KubeResize.Change(container: "app", field: .cpuRequest, from: "100m", to: "200m")
                ]))
        XCTAssertEqual(api.pod("web-1", namespace: "shop")?.resources["app"]?["requests"]?["cpu"], "200m", "Burstable stays Burstable")
    }

    func testAServerWithoutItRefusesWithWhyAndSendsNothing() async throws {
        api.servesResize = false
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        let ref = KubeObjectRef(context: "kind-fake", kind: try pods(page), namespace: "shop", name: "web-1")
        XCTAssertFalse(ref.kind.subresources.contains("resize"), "discovery says so")
        let verb = try XCTUnwrap(page.writeVerbs(for: ref).first { $0.title == KubeWriteVerb.resize.title }, "offered, so why is said")
        XCTAssertEqual(verb.unavailable, KubeResize.unsupported)
        verb.perform()
        XCTAssertEqual(page.writeStatus, .failed(KubeResize.unsupported))
        XCTAssertNil(page.resizeDraft)
        page.write(.resize, on: ref, resize: [KubeResize.Change(container: "app", field: .cpuRequest, from: "100m", to: "250m")])
        XCTAssertEqual(page.writeStatus, .failed(KubeResize.unsupported), "the guard path refuses it too")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(box.confirmations.isEmpty)
        XCTAssertEqual(written(), [], "nothing sent")
        let resize = api.requests.filter(\.isAccessReview).filter {
            ((($0.json as? [String: Any])?["spec"] as? [String: Any])?["resourceAttributes"] as? [String: String])?["subresource"] == "resize"
        }
        XCTAssertEqual(resize, [], "not even its review")
    }

    func testAReadOnlyContextSendsNothing() async throws {
        for current in ["fake-dev", "fake-prod"] {
            let (page, box) = try await page(current: current, readOnly: [current])
            defer { page.model.hide() }
            let ref = KubeObjectRef(context: current, kind: try pods(page), namespace: "shop", name: "web-1")
            page.openResizeSheet(ref)
            XCTAssertEqual(page.writeStatus, .failed(KubeWriteCheck.readOnly(try XCTUnwrap(page.model.selected))), current)
            XCTAssertNil(page.resizeDraft)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(box.confirmations.isEmpty)
            XCTAssertEqual(api.writes, [], current)
        }
    }
}
