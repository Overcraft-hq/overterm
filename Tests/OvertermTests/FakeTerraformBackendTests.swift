import XCTest

@testable import Overterm

/// `FakeTerraformBackend` answers as Terraform's http backend client
/// expects (its `client.go`): GET 404 for no state, writes refused without
/// the lock's ID, 423 with the holder's lock info, force-unlock's empty
/// UNLOCK. `TerraformRealBackendTests` runs the real terraform against it.
final class FakeTerraformBackendTests: XCTestCase {
    private var backend: FakeTerraformBackend!
    private var session: URLSession!

    override func setUpWithError() throws {
        backend = FakeTerraformBackend()
        try backend.start()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        backend.stop()
    }

    private func send(_ method: String, _ name: String, query: String = "", body: Data? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: backend.address(name) + query)!)
        request.httpMethod = method
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private func lockBody(_ id: String, who: String = "ali@acme-mbp") -> Data {
        FakeTerraformBackend.Lock(id: id, operation: "OperationTypePlan", who: who, version: "1.17.1", created: "2026-11-08T11:42:46.353924Z").json
    }

    func testItListensOnLoopbackOnly() {
        XCTAssertTrue(backend.address("acme-net").hasPrefix("http://127.0.0.1:"))
        XCTAssertGreaterThan(backend.port, 0)
        let block = backend.backendBlock("acme-net")
        XCTAssertTrue(block.contains("backend \"http\""))
        XCTAssertTrue(block.contains("lock_address   = \"\(backend.address("acme-net"))\""))
        XCTAssertTrue(block.contains("unlock_address = \"\(backend.address("acme-net"))\""))
    }

    func testAStateIsWrittenReadAndRemoved() async throws {
        let none = try await send("GET", "acme-net")
        XCTAssertEqual(none.0, 404)
        let state = Data(#"{"version":4,"serial":1,"lineage":"acme"}"#.utf8)
        let written = try await send("POST", "acme-net", body: state)
        XCTAssertEqual(written.0, 200)
        let read = try await send("GET", "acme-net")
        XCTAssertEqual(read.0, 200)
        XCTAssertEqual(read.1, state)
        XCTAssertEqual(backend.state("acme-net"), state)
        XCTAssertNil(backend.state("globex-net"))
        let removed = try await send("DELETE", "acme-net")
        XCTAssertEqual(removed.0, 200)
        XCTAssertNil(backend.state("acme-net"))
    }

    func testALockIsTakenRefusedToOthersAndReleased() async throws {
        let taken = try await send("LOCK", "acme-net", body: lockBody("lock-1"))
        XCTAssertEqual(taken.0, 200)
        XCTAssertEqual(backend.heldLock("acme-net")?.who, "ali@acme-mbp")

        let refused = try await send("LOCK", "acme-net", body: lockBody("lock-2", who: "ci@globex-runner-7"))
        XCTAssertEqual(refused.0, 423)
        XCTAssertEqual(FakeTerraformBackend.Lock(json: refused.1)?.id, "lock-1")

        // A write needs the lock's ID.
        let unlocked = try await send("POST", "acme-net", body: Data("{}".utf8))
        XCTAssertEqual(unlocked.0, 409)
        let wrongID = try await send("POST", "acme-net", query: "?ID=lock-2", body: Data("{}".utf8))
        XCTAssertEqual(wrongID.0, 409)
        let withID = try await send("POST", "acme-net", query: "?ID=lock-1", body: Data("{}".utf8))
        XCTAssertEqual(withID.0, 200)

        // Only the holder's ID releases it.
        let notMine = try await send("UNLOCK", "acme-net", body: lockBody("lock-2"))
        XCTAssertEqual(notMine.0, 409)
        XCTAssertNotNil(backend.heldLock("acme-net"))
        let mine = try await send("UNLOCK", "acme-net", body: lockBody("lock-1"))
        XCTAssertEqual(mine.0, 200)
        XCTAssertNil(backend.heldLock("acme-net"))
    }

    /// A lock's `Created` as Terraform writes it: UTC, `Z`, the fraction's
    /// trailing zeros dropped, none when it is zero.
    func testLockTimesAreWrittenAsTerraformWritesThem() {
        XCTAssertEqual(FakeTerraformBackend.goTime(Date(timeIntervalSince1970: 1_794_000_000)), "2026-11-06T21:20:00Z")
        XCTAssertEqual(FakeTerraformBackend.goTime(Date(timeIntervalSince1970: 1_794_000_000.353924)), "2026-11-06T21:20:00.353924Z")
        XCTAssertEqual(FakeTerraformBackend.goTime(Date(timeIntervalSince1970: 1_794_000_000.5)), "2026-11-06T21:20:00.5Z")
        XCTAssertEqual(FakeTerraformBackend.goTime(Date(timeIntervalSince1970: 1_794_000_000.9999996)), "2026-11-06T21:20:01Z")
        let pattern = #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d{1,9})?Z$"#
        XCTAssertNotNil(FakeTerraformBackend.goTime(Date()).range(of: pattern, options: .regularExpression))
    }

    /// force-unlock sends UNLOCK with nothing in it: whatever lock is there
    /// goes (analysis 4.10).
    func testAnEmptyUnlockRemovesWhateverLockIsThere() async throws {
        let held = backend.holdLock("acme-net", who: "ci@globex-runner-7", created: Date(timeIntervalSince1970: 1_794_000_000))
        XCTAssertEqual(held.who, "ci@globex-runner-7")
        XCTAssertEqual(held.operation, "OperationTypeApply")
        XCTAssertEqual(held.created, "2026-11-06T21:20:00Z")
        let refused = try await send("LOCK", "acme-net", body: lockBody("lock-1"))
        XCTAssertEqual(refused.0, 423)
        let answer = try XCTUnwrap(try JSONSerialization.jsonObject(with: refused.1) as? [String: String])
        XCTAssertEqual(answer["Who"], "ci@globex-runner-7")
        XCTAssertEqual(answer["ID"], held.id)
        XCTAssertEqual(answer["Version"], "1.17.1")

        let forced = try await send("UNLOCK", "acme-net")
        XCTAssertEqual(forced.0, 200)
        XCTAssertNil(backend.heldLock("acme-net"))
        XCTAssertEqual(backend.requests.last?.body, Data())
        XCTAssertNil(backend.requests.last?.lock)
    }

    func testRefusedCredentialsAndEveryRequestRecorded() async throws {
        backend.failCredentials = 401
        let refused = try await send("GET", "acme-net")
        XCTAssertEqual(refused.0, 401)
        backend.failCredentials = 403
        let forbidden = try await send("LOCK", "acme-net", body: lockBody("lock-1"))
        XCTAssertEqual(forbidden.0, 403)
        XCTAssertNil(backend.heldLock("acme-net"))
        backend.failCredentials = nil

        var request = URLRequest(url: URL(string: backend.address("acme-net") + "?ID=x")!)
        request.setValue("Basic YWNtZTpodW50ZXIy", forHTTPHeaderField: "Authorization")
        _ = try await session.data(for: request)
        let unknown = try await send("PATCH", "acme-net")
        XCTAssertEqual(unknown.0, 405)

        XCTAssertEqual(backend.requests.map(\.description), ["GET /state/acme-net", "LOCK /state/acme-net", "GET /state/acme-net", "PATCH /state/acme-net"])
        XCTAssertEqual(backend.requests[2].query, ["ID": "x"])
        XCTAssertTrue(backend.requests[2].authorized)
        XCTAssertFalse(backend.requests[0].authorized)
        XCTAssertFalse(String(reflecting: backend.requests).contains("YWNtZTpodW50ZXIy"))
        XCTAssertEqual(backend.writes.map(\.method), ["LOCK", "PATCH"])
        backend.forgetRequests()
        XCTAssertEqual(backend.requests, [])
    }
}
