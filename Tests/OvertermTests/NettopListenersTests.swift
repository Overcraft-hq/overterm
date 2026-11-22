import Darwin
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

/// nettop's listeners (docs/design/activity/analysis.md, 6.8, D-25): the
/// pinned, hand-written fixture — every name invented —, the blind check,
/// and a read through a stand-in the test writes: the real nettop never
/// runs in a test (9.9).
final class NettopListenersTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/nettop-listeners.txt")

    private func listeners() throws -> [NettopListeners.Listener] {
        try XCTUnwrap(NettopListeners.parse(String(contentsOf: Self.fixture, encoding: .utf8)))
    }

    func testTheFixturesListenersAreRead() throws {
        let found = try listeners()
        // launchd's two, acme-daemon's two bound UDP, the link-local one,
        // fake.server's wildcard once.
        XCTAssertEqual(found.count, 6, found.map { "\($0.name).\($0.pid) \($0.proto) \($0.port)" }.joined(separator: ", "))
        let launchd = found.filter { $0.pid == 1 }
        XCTAssertEqual(launchd.map(\.port), [8021, 8021])
        XCTAssertEqual(launchd.map(\.family), [.v4, .v6], "`:` before a v4 port, `.` before a v6 one")
        XCTAssertEqual(launchd.first?.address, ActivityAddress(text: "127.0.0.1"))
        XCTAssertEqual(launchd.last?.address, ActivityAddress(text: "::1"))
        let udp = found.filter { $0.proto == "udp" }
        XCTAssertEqual(udp.map(\.port), [5353, 5353], "UDP with no peer and no state; a connected one is no listener")
        XCTAssertTrue(udp.allSatisfy { $0.address.isWildcard })
        let spaced = try XCTUnwrap(found.first { $0.pid == 2042 })
        XCTAssertEqual(spaced.name, "Globex Helper (Renderer)", "a name with spaces")
        XCTAssertEqual(spaced.port, 7000, "a zone (`%lo0`) left out")
        XCTAssertTrue(spaced.address.isLinkLocal)
        let dotted = found.filter { $0.pid == 4242 }
        XCTAssertEqual(dotted.count, 1, "the same listener twice is once")
        XCTAssertEqual(dotted.first?.name, "fake.server.v2", "the pid after the last dot")
        XCTAssertFalse(found.contains { $0.port == 52100 || $0.port == 443 }, "established flows and QUIC are no listeners")
    }

    func testAnythingElseFailsTheWholeParse() {
        XCTAssertNil(NettopListeners.parse(""), "no header")
        XCTAssertNil(NettopListeners.parse("time,state,\nacme.1,,\n"), "another header")
        XCTAssertNil(NettopListeners.parse(",state,\ntcp4 127.0.0.1:80<->*:*,Listen,\n"), "a flow before any process")
        XCTAssertNil(NettopListeners.parse(",state,\nacme,,\n"), "a process row with no pid")
        XCTAssertNil(NettopListeners.parse(",state,\nacme.12,,\ntcp4 127.0.0.1-80<->*:*,Listen,\n"), "an endpoint that isn't one")
        XCTAssertNil(NettopListeners.parse(",state,\nacme.12,,\nnetstat: sysctl: Operation not permitted\n"), "a stray line")
        XCTAssertEqual(NettopListeners.parse(",state,\n")?.count, 0, "nothing listens: read, and empty")
    }

    func testTheBlindCheck() throws {
        let found = try listeners()
        let mine = NettopListeners.Expected(port: 3000, pids: [4242, 4243])
        XCTAssertEqual(NettopListeners.check(found, expected: [mine]), .checked, "nettop names one holder of a shared socket")
        XCTAssertEqual(NettopListeners.check(found, expected: []), .unchecked, "none of the user's to compare")
        let missing = NettopListeners.Expected(port: 3001, pids: [4300])
        XCTAssertEqual(NettopListeners.check(found, expected: [mine, missing]), .blind(missing: 1), "a listener of the user's it lacks")
        XCTAssertEqual(NettopListeners.check([], expected: [mine]), .blind(missing: 1), "0 rows is blind, never \"nothing listens\"")
        XCTAssertEqual(
            NettopListeners.check(found, expected: [NettopListeners.Expected(port: 3000, pids: [999])]), .blind(missing: 1), "another pid on that port isn't it")

        // A listener that closed while nettop ran is no proof of blindness.
        var reading = NettopListeners.reading(",state,\n", status: 0, date: Date(), expected: [missing])
        XCTAssertEqual(reading.outcome, .read(.blind(missing: 1)))
        XCTAssertFalse(reading.isBelieved)
        reading = reading.checked(against: [])
        XCTAssertEqual(reading.outcome, .read(.unchecked))
        XCTAssertTrue(reading.isBelieved)
        XCTAssertEqual(NettopListeners.reading(nil, status: 0, date: Date(), expected: []).outcome, .failed("nettop didn't answer in 5 s"))
        XCTAssertEqual(NettopListeners.reading("", status: 1, date: Date(), expected: []).outcome, .failed("nettop failed (exit 1)"))
        XCTAssertFalse(NettopListeners.reading("garbage", status: 0, date: Date(), expected: []).isBelieved)
    }

    func testTheUsersOwnListenersAreWhatIsExpected() throws {
        let kernel = FakeActivityKernel(uid: 501)
        var server = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 2000, start: 2_000, parent: 1, uid: 501, name: "acme-server"))
        server.descriptors = [FakeActivityKernel.descriptor(3), FakeActivityKernel.descriptor(4)]
        server.sockets = [
            3: FakeActivityKernel.tcp(local: "127.0.0.1", port: 3000, handle: 1), 4: FakeActivityKernel.udp(local: "127.0.0.1", port: 5353, handle: 2),
        ]
        kernel.add(FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 1, start: 1, parent: 0, uid: 0, name: "launchd")))
        kernel.add(server)
        let snapshot = try XCTUnwrap(ActivitySampler(kernel: kernel).tickNow(ActivityDemand(.full), context: ActivityContext()))
        XCTAssertEqual(NettopListeners.expected(in: snapshot), [NettopListeners.Expected(port: 3000, pids: [2000])], "TCP listeners only")
    }

    /// A read through a stand-in the test wrote: its own child, in a group
    /// of its own, ended by the run; never the real nettop.
    func testAReadThroughAStandIn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ot-nettop-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("nettop")
        try "#!/bin/sh\n[ \"$*\" = \"-L 1 -n -x -J state\" ] || exit 3\ncat \"\(Self.fixture.path)\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let reader = NettopListeners.Reader()
        XCTAssertEqual(reader.unavailable, "not read in a test run", "the real nettop never runs in a test")
        XCTAssertFalse(reader.read(expected: []) { _ in XCTFail("nothing is read") })
        reader.standIn = script
        XCTAssertNil(reader.unavailable)
        let done = expectation(description: "read")
        let box = ReadingBox()
        XCTAssertTrue(
            reader.read(expected: [NettopListeners.Expected(port: 3000, pids: [4242])]) { reading in
                box.set(reading)
                done.fulfill()
            })
        wait(for: [done], timeout: 10)
        let reading = try XCTUnwrap(box.get())
        XCTAssertEqual(reading.outcome, .read(.checked), "nettop's arguments, its answer checked")
        XCTAssertEqual(reading.listeners.count, 6)
        XCTAssertFalse(reader.isReading)
        XCTAssertNotNil(reader.latest)
        XCTAssertTrue(KubeProcessRun.livePIDs.isEmpty, "its child ended and reaped")
    }

    private final class ReadingBox: @unchecked Sendable {
        private let lock = NSLock()
        private var reading: NettopListeners.Reading?
        func set(_ value: NettopListeners.Reading) { lock.withLock { reading = value } }
        func get() -> NettopListeners.Reading? { lock.withLock { reading } }
    }
}
