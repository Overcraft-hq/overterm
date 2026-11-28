import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermKubernetes

/// K8S-G2: the forwards kept from one run to the next — their specs on
/// disk, listed stopped at the next launch, started again only when asked.
@MainActor
final class KubeForwardStoreTests: XCTestCase {
    private var file: URL!

    override func setUp() async throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("kube-forwards-\(UUID().uuidString)/Kubernetes/forwards.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent())
    }

    private static func context(_ name: String, production: Bool = false) -> KubeContext {
        KubeContext(
            name: name, cluster: name, server: "http://127.0.0.1:1", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: production ? .production : .remote, settings: KubeContextSettings())
    }

    private func spec(_ context: String, _ target: KubeForwardTarget, local: Int) -> KubeForwardSpec {
        var spec = KubeForwardSpec(context: context, namespace: "shop", target: target, remotePort: 80, localPort: local, tab: UUID())
        spec.https = true
        spec.address = "0.0.0.0"
        return spec
    }

    func testASpecRoundTripsWithoutItsTab() throws {
        let kept = [spec("fake-dev", .service("web"), local: 8080), spec("fake-dev", .deployment("api"), local: 8081), spec("fake-dev", .pod("db-0"), local: 5432)]
        KubeForwardStore.save(kept, to: file)
        let read = KubeForwardStore.load(from: file)
        XCTAssertEqual(read.map(\.id), kept.map(\.id))
        XCTAssertEqual(read.map(\.target), kept.map(\.target))
        XCTAssertEqual(read.map(\.localPort), [8080, 8081, 5432])
        XCTAssertTrue(read.allSatisfy { $0.https && $0.address == "0.0.0.0" && $0.tab == nil }, "its tab isn't kept")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("\"tab\""), text)
        KubeForwardStore.save([], to: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing kept, no file")
        XCTAssertEqual(KubeForwardStore.load(from: file), [])
    }

    func testAnUnreadableOrLaterFileKeepsNothing() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: file)
        XCTAssertEqual(KubeForwardStore.load(from: file), [])
        try Data(#"{"version":2,"forwards":[]}"#.utf8).write(to: file)
        XCTAssertEqual(KubeForwardStore.load(from: file), [])
    }

    private func forwards(saved: @escaping ([KubeForwardSpec]) -> Void = { _ in }, kept: [KubeForwardSpec] = []) -> KubeForwards {
        let forwards = KubeForwards(
            client: { _ in nil }, canI: { _, _ in .yes },
            launch: { _, _, _ in throw KubeForwardFailure.stops("not in a unit test") })
        forwards.keep = saved
        forwards.kept = { kept }
        return forwards
    }

    func testWhatIsKeptIsWhatTheListHoldsAndQuittingKeepsIt() {
        var saves: [[KubeForwardSpec]] = []
        let forwards = forwards(saved: { saves.append($0) })
        let dev = Self.context("fake-dev")
        let one = forwards.start(spec("fake-dev", .service("web"), local: 8080), in: dev)
        let two = forwards.start(spec("fake-dev", .pod("db-0"), local: 5432), in: dev)
        XCTAssertEqual(saves.last?.map(\.id), [one, two], "kept as started")
        forwards.stop(one)
        XCTAssertEqual(saves.last?.map(\.id), [two], "a Stop is no longer kept")
        let count = saves.count
        forwards.stopAll()
        XCTAssertEqual(saves.count, count, "quitting writes nothing: what runs is kept for the next run")
    }

    func testKeptForwardsAreListedStoppedAndStartOnlyWhenAsked() {
        let web = spec("fake-dev", .service("web"), local: 8080)
        let api = spec("fake-dev", .deployment("api"), local: 8081)
        let prod = spec("fake-prod", .service("pay"), local: 9090)
        let gone = spec("old-cluster", .service("x"), local: 7070)
        let forwards = forwards(kept: [web, api, prod, gone])
        let list = KubeContextList(contexts: [Self.context("fake-dev"), Self.context("fake-prod", production: true)])
        forwards.restore(list)
        XCTAssertEqual(forwards.forwards.map(\.id), [web.id, api.id, prod.id, gone.id])
        XCTAssertTrue(forwards.forwards.allSatisfy { $0.state.isStopped }, "never started by being kept")
        XCTAssertEqual(forwards.forward(web.id)?.state, .stopped(KubeForwards.keptNote))
        XCTAssertEqual(forwards.forward(prod.id)?.production, true)
        XCTAssertEqual(forwards.forward(gone.id)?.state, .stopped("old-cluster is no longer in the kubeconfig"))
        XCTAssertFalse(forwards.canStartAgain(gone.id), "a gone context's can only be removed")
        XCTAssertTrue(forwards.canStartAgain(prod.id))
        XCTAssertEqual(Set(forwards.startableAgain.map(\.id)), [web.id, api.id], "Start All leaves production's to be asked one by one")
        XCTAssertTrue(forwards.takenPorts.isEmpty, "a stopped one's port isn't taken")
        forwards.restore(list)
        XCTAssertEqual(forwards.forwards.count, 4, "once a run")
        forwards.stopAll()
    }
}
