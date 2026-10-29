import Foundation
import XCTest

@testable import Overterm

/// The list's CPU and memory against the fake engine: each running
/// container read once a round, a few at a time, set against its read
/// before — and nothing read while no page's Containers section shows.
@MainActor
final class DockerUsageTests: XCTestCase {
    private var fake: FakeDockerEngine!
    private var model: DockerModel!
    private var socket = ""

    override func setUp() async throws {
        socket = "/tmp/ot-usage-\(UUID().uuidString.prefix(8)).sock"
        fake = FakeDockerEngine(socket: socket)
        try fake.start()
        let endpoint = DockerEndpoint(address: .unix(socket), context: nil, source: "test")
        model = DockerModel(endpoint: { endpoint }, retries: [.milliseconds(50)], poll: .milliseconds(200))
        model.usage.interval = .milliseconds(100)
        model.usage.first = .milliseconds(50)
    }

    override func tearDown() async throws {
        model.usage.unwant()
        model.stop()
        fake.stop()
    }

    private func eventually(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out: \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private var statsRequests: [String] { fake.requests.filter { $0.contains("/stats") } }

    /// web and db running, old stopped; listed.
    private func shop() async throws -> (web: String, db: String, old: String) {
        let web = fake.add(name: "web")
        let db = fake.add(name: "db")
        let old = fake.add(name: "old", state: .exited)
        fake.setUsage(web, cpuPercent: 12.5, memory: 96 << 20)
        fake.setUsage(db, cpuPercent: 40, memory: 32 << 20)
        model.start()
        try await eventually("listed") { model.containers.count == 3 }
        return (web, db, old)
    }

    func testReadsAreCappedAtTheLimit() async {
        actor Flight {
            var now = 0
            var most = 0
            func begin() {
                now += 1
                most = max(most, now)
            }
            func end() { now -= 1 }
        }
        let flight = Flight()
        let ids = (0..<12).map { "c\($0)" }
        let read = await DockerUsageMonitor.read(ids, limit: 4, timeout: .seconds(5)) { id -> Int? in
            await flight.begin()
            try? await Task.sleep(for: .milliseconds(30))
            await flight.end()
            return id == "c7" ? nil : Int(id.dropFirst())
        }
        XCTAssertEqual(read.count, 11, "one came back with nothing")
        XCTAssertNil(read["c7"])
        XCTAssertEqual(read["c11"], 11)
        let most = await flight.most
        XCTAssertLessThanOrEqual(most, 4)
        XCTAssertGreaterThan(most, 1, "read side by side")
    }

    func testAReadTooSlowIsGivenUpOn() async {
        let started = Date()
        let read = await DockerUsageMonitor.read(["slow", "quick"], limit: 4, timeout: .milliseconds(100)) { id -> Int? in
            guard id == "slow" else { return 2 }
            try? await Task.sleep(for: .seconds(30))
            return 1
        }
        XCTAssertEqual(read, ["quick": 2])
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "cancelled at its deadline, not waited for")
    }

    func testItReadsRunningContainersWhileWanted() async throws {
        let (web, db, old) = try await shop()
        model.usage.want()
        try await eventually("web's and db's use") {
            abs((model.usage.byContainer[web]?.cpuPercent ?? 0) - 12.5) < 0.01 && abs((model.usage.byContainer[db]?.cpuPercent ?? 0) - 40) < 0.01
        }
        XCTAssertEqual(model.usage.byContainer[web]?.memoryBytes, 96 << 20)
        XCTAssertNil(model.usage.byContainer[old])
        XCTAssertFalse(statsRequests.contains { $0.contains("/containers/\(old)/stats") }, "a stopped one isn't asked")
        XCTAssertFalse(statsRequests.isEmpty)
        XCTAssertTrue(statsRequests.allSatisfy { $0.contains("stats?one-shot=true&stream=false") }, "\(statsRequests)")
        fake.setUsage(web, cpuPercent: 75, memory: 10 << 20)
        try await eventually("and follows it") { abs((model.usage.byContainer[web]?.cpuPercent ?? 0) - 75) < 0.01 }
    }

    func testAStoppedContainerDropsOut() async throws {
        let (web, _, _) = try await shop()
        model.usage.want()
        try await eventually("read") { model.usage.byContainer[web] != nil }
        fake.set(web, state: .exited)
        try await eventually("gone when it stops") { model.usage.byContainer[web] == nil }
        fake.set(web, state: .running)
        try await eventually("back when it starts") { model.usage.byContainer[web] != nil }
    }

    /// A container whose stats never answer (its shim stopped): the
    /// round still ends, the others are read, and its own number goes.
    func testAReadThatHangsFailsAtItsDeadline() async throws {
        let (web, db, _) = try await shop()
        model.usage.timeout = .milliseconds(300)
        model.usage.want()
        try await eventually("read") { model.usage.byContainer[web] != nil && model.usage.byContainer[db] != nil }
        fake.setStatsAnswer(web, .never)
        fake.setUsage(db, cpuPercent: 75, memory: 10 << 20)
        // A round's values land only when it ends: db's new ones say it did.
        try await eventually("the others still read, and its last number goes") {
            abs((model.usage.byContainer[db]?.cpuPercent ?? 0) - 75) < 0.01 && model.usage.byContainer[web] == nil
        }
        fake.setStatsAnswer(web, .read)
        try await eventually("back once it answers") { model.usage.byContainer[web] != nil }
    }

    /// Round by round: a failed read keeps what it showed one round, then
    /// a dash — and never hurries the next round, as a first read does.
    func testFailedReadsShowADashAndDontHurryTheRounds() async throws {
        let (web, db, _) = try await shop()
        let usage = model.usage
        var waiting = await usage.round()
        XCTAssertTrue(waiting, "read for the first time: the next round comes sooner")
        waiting = await usage.round()
        XCTAssertFalse(waiting)
        XCTAssertNotNil(usage.byContainer[web])
        fake.setStatsAnswer(web, .failing)
        waiting = await usage.round()
        XCTAssertFalse(waiting)
        XCTAssertNotNil(usage.byContainer[web], "its last value outlives one failed round")
        waiting = await usage.round()
        XCTAssertNil(usage.byContainer[web], "not two: a dash, not an old number as if current")
        XCTAssertNotNil(usage.byContainer[db])

        let new = fake.add(name: "new")
        try await eventually("listed") { model.containers.contains { $0.Id == new } }
        waiting = await usage.round()
        XCTAssertTrue(waiting, "its first read")
        fake.setStatsAnswer(new, .failing)
        waiting = await usage.round()
        XCTAssertFalse(waiting, "its second failed: no round a second after another for it")
        XCTAssertNil(usage.byContainer[new])

        fake.setStatsAnswer(web, .read)
        fake.setStatsAnswer(new, .read)
        _ = await usage.round()
        XCTAssertNotNil(usage.byContainer[web], "set against its read before the failures")
        XCTAssertNotNil(usage.byContainer[new])
    }

    func testUnwantedItStops() async throws {
        let (web, _, _) = try await shop()
        model.usage.want()
        try await eventually("read") { model.usage.byContainer[web] != nil }
        model.usage.unwant()
        XCTAssertFalse(model.usage.isPolling)
        XCTAssertTrue(model.usage.byContainer.isEmpty, "its values go at once")
        // Those on their way land; then nothing more is asked.
        try await Task.sleep(for: .milliseconds(150))
        let asked = statsRequests.count
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(statsRequests.count, asked)
    }

    func testAPageWantsItOnlyWhileContainersShows() async throws {
        let (web, _, _) = try await shop()
        // A page coming up asks the CLI about the MCP Toolkit: here a
        // `docker` that answers nothing, never the user's.
        DockerCLI.override = URL(fileURLWithPath: "/usr/bin/false")
        defer { DockerCLI.override = nil }
        let page = DockerPageModel(docker: model)
        page.visible = true
        try await eventually("a page on Containers reads them") { model.usage.isPolling && page.usage[web] != nil }
        page.section = .images
        try await eventually("another section stops it") { !model.usage.isPolling && page.usage.isEmpty }
        page.section = .containers
        try await eventually("Containers again reads them again") { model.usage.isPolling && page.usage[web] != nil }
        page.windowVisible = false
        try await eventually("its window covered, minimized or hidden stops it") { !model.usage.isPolling && page.usage.isEmpty }
        page.windowVisible = true
        try await eventually("on screen again, it reads again") { model.usage.isPolling && page.usage[web] != nil }
        let other = DockerPageModel(docker: model)
        other.visible = true
        try await Task.sleep(for: .milliseconds(50))
        page.visible = false
        try await eventually("the hidden one lets its values go") { page.usage.isEmpty }
        XCTAssertTrue(model.usage.isPolling, "the other page still shows it")
        XCTAssertNotNil(other.usage[web])
        other.close()
        XCTAssertFalse(model.usage.isPolling, "a window's page closing stops it at once")
        XCTAssertTrue(other.usage.isEmpty)
    }

    func testAnEngineGoneEmptiesIt() async throws {
        let (web, _, _) = try await shop()
        model.usage.want()
        try await eventually("read") { model.usage.byContainer[web] != nil }
        model.stop()
        XCTAssertTrue(model.usage.byContainer.isEmpty, "a stopped engine's use isn't shown as if it were there")
        model.start()
        try await eventually("back with it, still wanted") { model.usage.byContainer[web] != nil }
    }
}
