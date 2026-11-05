import Foundation
import XCTest

@testable import Overterm

/// Agents' write tools (stage 2a; docs/design/kubernetes/analysis.md, 3.5
/// and rule 10) against `FakeKubeAPI` on a socket of the test's own, over
/// three fictional contexts — never ~/.kube: where they exist (a context
/// `agentWrites` names that is writable; production only with its switch
/// too), that
/// every call is asked first with the context and namespace, that a
/// declined or wrongly named one sends nothing, and that an allowed one
/// lands as one request after its access review.
@MainActor
final class KubeMCPWritesTests: XCTestCase {
    nonisolated(unsafe) private var api: FakeKubeAPI!
    nonisolated(unsafe) private var socket: String!
    private var agentWrites: [String] = []
    private var asked: [KubeWriteConfirmation] = []

    override func setUpWithError() throws {
        socket = "/tmp/otkmw-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        api.addPod("web-1", namespace: "shop")
        api.add(
            "deployments.apps", "web", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1],
            fields: ["spec": ["replicas": 1, "template": ["metadata": ["labels": ["app": "web"]]]], "status": ["replicas": 1]])
        MainActor.assumeIsolated { KubeMCP.forgetDiscoveries() }
    }

    override func tearDown() {
        MainActor.assumeIsolated { KubeMCP.askOverride = nil }
        api?.stop()
    }

    private func model() -> KubernetesModel {
        let model = KubernetesModel(proxies: KubeProxies())
        let list = KubeContextList(contexts: ["fake-dev", "fake-prod", "kind-fake"].map { KubeWritesTests.context($0) }, current: "kind-fake")
        model.load = { _ in list }
        model.readConfiguration = { [unowned self] in
            var configuration = KubernetesModel.Configuration()
            configuration.agentWrites = MainActor.assumeIsolated { self.agentWrites }
            return configuration
        }
        model.watchesSettings = false
        model.remembersSelection = false
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name, writable: context.isWritable) }
        model.statusOverride = { _ in .open }
        return model
    }

    private func answer(_ typed: String?) {
        KubeMCP.askOverride = { [unowned self] confirmation in
            MainActor.assumeIsolated { self.asked.append(confirmation) }
            return typed
        }
    }

    private func call(_ model: KubernetesModel, _ name: String, _ arguments: [String: Any]) async -> (text: String, error: Bool) {
        do {
            let result = try await KubeMCP.call(name, arguments, kubernetes: model)
            return (((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "", result["isError"] as? Bool == true)
        } catch let error as BrowserMCP.ToolError {
            return (error.message, true)
        } catch {
            return ("\(error)", true)
        }
    }

    private func written() -> [FakeKubeAPI.Request] { api.writes.filter { !$0.isAccessReview } }

    private func listed(_ model: KubernetesModel, _ settings: Settings) async -> [String] {
        let answer = await BrowserMCP.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], browser: { nil }, settings: settings, kubernetes: model)
        return (((answer?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []).filter {
            $0.hasPrefix("k8s_")
        }
    }

    private func settings() throws -> Settings {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("otkmw-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return Settings(url: dir.appendingPathComponent("settings.json"), watch: false)
    }

    /// fake-prod's writes on for the session, as its card turns them on.
    private func switchOn(_ model: KubernetesModel) async {
        model.reloadContexts()
        for _ in 0..<250 where model.contexts.context(named: "fake-prod") == nil { try? await Task.sleep(for: .milliseconds(10)) }
        await model.setProductionWrites(true, for: "fake-prod")
        XCTAssertTrue(model.productionWrites.isOn("fake-prod"))
    }

    // MARK: Where they exist

    func testWhereAgentsMayWrite() {
        let none: [String] = []
        XCTAssertEqual(
            KubeAgentWrites.refused(KubeWritesTests.context("kind-fake"), agentWrites: none),
            "kubernetes.agentWrites doesn't name kind-fake: agents only read there.", "local and writable, but not named: the default is read-only")
        XCTAssertNil(KubeAgentWrites.refused(KubeWritesTests.context("kind-fake"), agentWrites: ["kind-fake"]), "local, writable and named")
        XCTAssertNotNil(
            KubeAgentWrites.refused(KubeWritesTests.context("kind-fake", settings: KubeContextSettings(writable: false)), agentWrites: ["kind-fake"]))
        XCTAssertNotNil(KubeAgentWrites.refused(KubeWritesTests.context("fake-dev"), agentWrites: ["fake-dev"]), "remote, read-only: agentWrites can't open it")
        XCTAssertNotNil(KubeAgentWrites.refused(KubeWritesTests.context("fake-dev", settings: KubeContextSettings(writable: true)), agentWrites: none))
        XCTAssertNil(KubeAgentWrites.refused(KubeWritesTests.context("fake-dev", settings: KubeContextSettings(writable: true)), agentWrites: ["fake-dev"]))
        let prod = KubeWritesTests.context("fake-prod")
        XCTAssertNotNil(KubeAgentWrites.refused(prod, agentWrites: ["fake-prod"]), "production without its switch: none, named or not")
        let on = KubeWritesTests.context("fake-prod", session: true)
        XCTAssertEqual(
            KubeAgentWrites.refused(on, agentWrites: none), "fake-prod is production: its writes are on for this session, but kubernetes.agentWrites doesn't name it.")
        XCTAssertNil(KubeAgentWrites.refused(on, agentWrites: ["fake-prod"]), "the switch and agentWrites")
        XCTAssertNotNil(KubeAgentWrites.refused(on, agentWrites: ["globex-eu-west-1-prod"]), "another context named")
    }

    func testTheToolListFollowsAgentWrites() async throws {
        let settings = try settings()
        let model = model()
        let listed1 = await listed(model, settings)
        XCTAssertEqual(listed1, KubeMCP.reads, "agentWrites empty: no write tool, though kind-fake is writable")
        // Listed by the setting, not by the contexts as they stand at the
        // list (it isn't announced again): a call is refused per context.
        agentWrites = ["fake-prod"]
        let listed2 = await listed(model, settings)
        XCTAssertEqual(listed2, KubeMCP.reads + KubeMCP.writes, "named: listed, before fake-prod's switch")
        settings.set("kubernetes.agentAccess", .bool(false))
        let listed5 = await listed(model, settings)
        XCTAssertEqual(listed5, [], "the group off takes the writes too")
        XCTAssertTrue(api.requests.isEmpty, "listing asks no cluster: \(api.requests)")
        settings.set("kubernetes.agentAccess", nil)
        let refused = await call(model, "k8s_delete_pod", ["name": "web-1", "context": "fake-prod", "namespace": "shop"])
        XCTAssertTrue(refused.error && refused.text.contains("read-only"), "listed, but refused where the context isn't writable: \(refused.text)")
        XCTAssertTrue(asked.isEmpty, "refused before it is asked")
        XCTAssertEqual(written(), [])
    }

    func testTheSettingIsAListOfNames() throws {
        let settings = try settings()
        XCTAssertEqual(settings.kubernetesAgentWrites, [], "empty by default")
        settings.set("kubernetes.agentWrites", .list([" fake-prod ", ""]))
        XCTAssertEqual(settings.kubernetesAgentWrites, ["fake-prod"])
        XCTAssertEqual(KubernetesModel.Configuration(settings).agentWrites, ["fake-prod"])
        XCTAssertEqual(settings.kubernetesDebugImage, "busybox:1.36")
        XCTAssertTrue(SettingsSchema.specs(in: .kubernetes).contains { $0.key == "kubernetes.agentWrites" })
    }

    // MARK: Every call asks first

    func testAScaleIsReviewedAskedThenLands() async throws {
        let model = model()
        agentWrites = ["kind-fake"]
        answer("")
        let said = await call(model, "k8s_scale", ["name": "web", "replicas": 3, "context": "kind-fake", "namespace": "shop"])
        XCTAssertFalse(said.error, said.text)
        XCTAssertEqual(asked.count, 1, "asked once")
        XCTAssertEqual(asked.first?.scope, "kind-fake · namespace shop")
        XCTAssertEqual(asked.first.map(KubeAgentWrites.title), "An agent asks, in kind-fake · namespace shop: Scale deployment shop/web from 1 to 3 replicas?")
        XCTAssertTrue(asked.first?.detail.contains("kubectl scale deploy/web --replicas=3 --context kind-fake -n shop") == true, asked.first?.detail ?? "")
        XCTAssertTrue(api.requests.first(where: { $0.method != "GET" })?.isAccessReview == true, "reviewed before anything else is sent")
        XCTAssertEqual(written().map(\.description), ["PATCH /apis/apps/v1/namespaces/shop/deployments/web/scale"])
        XCTAssertTrue(said.text.contains("Scaled deployment shop/web from 1 to 3 in kind-fake."), said.text)
    }

    func testEveryWriteToolAsksFirstAndARefusalSendsNothing() async throws {
        let model = model()
        agentWrites = ["kind-fake"]
        answer(nil)
        let calls: [(String, [String: Any])] = [
            ("k8s_restart", ["name": "web"]), ("k8s_scale", ["name": "web", "replicas": 2]), ("k8s_delete_pod", ["name": "web-1"]),
        ]
        for (name, arguments) in calls {
            let before = asked.count
            let said = await call(model, name, arguments.merging(["context": "kind-fake", "namespace": "shop"]) { a, _ in a })
            XCTAssertEqual(asked.count, before + 1, "\(name) asked")
            XCTAssertTrue(said.error && said.text.contains("The user declined"), "\(name): \(said.text)")
        }
        XCTAssertEqual(written(), [], "declined, nothing sent")
        XCTAssertNotNil(api.pod("web-1", namespace: "shop"))
    }

    func testOnProductionTheNameIsTypedAndAWrongOneSendsNothing() async throws {
        let model = model()
        await switchOn(model)
        agentWrites = ["fake-prod"]
        answer("web-2")
        let wrong = await call(model, "k8s_delete_pod", ["name": "web-1", "context": "fake-prod", "namespace": "shop"])
        XCTAssertEqual(asked.first?.typedName, "web-1")
        XCTAssertEqual(asked.first?.scope, "PRODUCTION · fake-prod · namespace shop")
        XCTAssertTrue(wrong.error && wrong.text.contains("The name typed wasn't web-1"), wrong.text)
        XCTAssertEqual(written(), [])
        answer("web-1")
        let right = await call(model, "k8s_delete_pod", ["name": "web-1", "context": "fake-prod", "namespace": "shop"])
        XCTAssertFalse(right.error, right.text)
        XCTAssertEqual(written().map(\.description), ["DELETE /api/v1/namespaces/shop/pods/web-1"])
    }

    func testAReadOnlyContextIsRefusedAskingNothing() async throws {
        let model = model()
        answer("")
        for name in KubeMCP.writes {
            let said = await call(model, name, ["name": "web", "replicas": 1, "context": "fake-dev", "namespace": "shop"])
            XCTAssertTrue(said.error && said.text.contains("isn't offered on fake-dev"), said.text)
        }
        XCTAssertTrue(asked.isEmpty, "not asked")
        XCTAssertTrue(api.requests.isEmpty, "nothing sent, not even a review: \(api.requests)")
    }

    func testAWritableContextAgentWritesDoesntNameIsRefusedAskingNothing() async throws {
        let model = model()
        answer("")
        for name in KubeMCP.writes {
            let said = await call(model, name, ["name": "web", "replicas": 1, "context": "kind-fake", "namespace": "shop"])
            XCTAssertTrue(said.error && said.text.contains("kubernetes.agentWrites doesn't name kind-fake"), said.text)
        }
        XCTAssertTrue(asked.isEmpty, "not asked")
        XCTAssertTrue(api.requests.isEmpty, "nothing sent, not even a review: \(api.requests)")
    }

    func testARefusedReviewStopsBeforeTheQuestion() async throws {
        api.deniedAccess = ["delete pods"]
        let model = model()
        agentWrites = ["kind-fake"]
        answer("")
        let said = await call(model, "k8s_delete_pod", ["name": "web-1", "context": "kind-fake", "namespace": "shop"])
        XCTAssertTrue(said.error && said.text.contains("access review says you may not delete pods"), said.text)
        XCTAssertTrue(asked.isEmpty)
        XCTAssertEqual(written(), [])
    }

    func testTurnedOffWhileAskedSendsNothing() async throws {
        let model = model()
        await switchOn(model)
        agentWrites = ["fake-prod"]
        // agentWrites changed while the window asked.
        KubeMCP.askOverride = { [unowned self] _ in
            MainActor.assumeIsolated { self.agentWrites = [] }
            return "web-1"
        }
        let said = await call(model, "k8s_delete_pod", ["name": "web-1", "context": "fake-prod", "namespace": "shop"])
        XCTAssertTrue(said.error && said.text.contains("changed while it was asked"), said.text)
        XCTAssertEqual(written(), [])
    }
}
