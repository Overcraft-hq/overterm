import Darwin
import Foundation
import XCTest

@testable import Overterm
@testable import OvertermCore

/// D-29 (docs/design/activity/analysis.md, 6.9): the kept and stopped
/// identities across a crash — pid and start only, 0600, never through a
/// link, swept of what ended or was continued elsewhere.
final class ActivityPersistedTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("activity-persisted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var file: URL { folder.appendingPathComponent(ActivityPersisted.fileName) }

    private func process(_ identity: ActivityProcessID, status: Int32 = SRUN) -> ActivityProcess {
        FakeActivityKernel.record(pid: identity.pid, start: identity.start, parent: 1, status: status, name: "acme-worker")
    }

    func testItKeepsIdentitiesOnlyIn0600() throws {
        let kept = ActivityProcessID(pid: 4242, start: 1_700_000_000_000_001)
        let stopped = ActivityProcessID(pid: 4343, start: 1_700_000_000_000_002)
        XCTAssertTrue(ActivityPersisted(kept: [kept], stopped: [stopped]).save(to: file))
        let read = ActivityPersisted.load(from: file)
        XCTAssertEqual(read.keptIdentities, [kept])
        XCTAssertEqual(read.stoppedIdentities, [stopped])
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        // Nothing but pids and starts: no name, no path, no argv.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [[String: Any]]])
        XCTAssertEqual(Set(object.keys), ["kept", "stopped"])
        XCTAssertEqual(Set(object.values.flatMap { $0.flatMap(\.keys) }), ["pid", "start"])
    }

    func testAFileOnceWiderIsMade0600Again() throws {
        FileManager.default.createFile(atPath: file.path, contents: Data("{}".utf8), attributes: [.posixPermissions: 0o644])
        XCTAssertTrue(ActivityPersisted(kept: [ActivityProcessID(pid: 4242, start: 1)]).save(to: file))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testNeverThroughALink() throws {
        let elsewhere = folder.appendingPathComponent("elsewhere.json")
        try Data("{\"kept\":[{\"pid\":4242,\"start\":1}],\"stopped\":[]}".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
        XCTAssertTrue(ActivityPersisted.load(from: file).isEmpty, "a link is not read")
        XCTAssertFalse(ActivityPersisted(kept: [ActivityProcessID(pid: 1, start: 2)]).save(to: file), "nor written through")
        XCTAssertEqual(try String(contentsOf: elsewhere, encoding: .utf8), "{\"kept\":[{\"pid\":4242,\"start\":1}],\"stopped\":[]}")
    }

    func testEmptyRemovesTheFileAndAMissingOneReadsEmpty() {
        XCTAssertTrue(ActivityPersisted(kept: [ActivityProcessID(pid: 4242, start: 1)]).save(to: file))
        XCTAssertTrue(ActivityPersisted().save(to: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(ActivityPersisted.load(from: file).isEmpty)
        try? Data("not json".utf8).write(to: file)
        XCTAssertTrue(ActivityPersisted.load(from: file).isEmpty, "not ours: nothing")
    }

    func testTheSweepKeepsOnlyWhatStillRunsAndWhatIsStillStopped() {
        let alive = ActivityProcessID(pid: 4242, start: 10)
        let ended = ActivityProcessID(pid: 4243, start: 11)
        let reused = ActivityProcessID(pid: 4244, start: 12)
        let stillStopped = ActivityProcessID(pid: 4245, start: 13)
        let continued = ActivityProcessID(pid: 4246, start: 14)
        let table: [pid_t: ActivityProcess] = [
            4242: process(alive),
            4244: process(ActivityProcessID(pid: 4244, start: 99)),
            4245: process(stillStopped, status: SSTOP),
            4246: process(continued),
        ]
        let swept = ActivityPersisted(kept: [alive, ended, reused], stopped: [stillStopped, continued, ended]).swept { table[$0.pid] }
        XCTAssertEqual(swept.keptIdentities, [alive], "an ended one goes, and a pid another process holds now")
        XCTAssertEqual(swept.stoppedIdentities, [stillStopped], "one continued elsewhere is no longer Activity's to resume")
    }

    @MainActor
    func testTheLaunchPutsTheKeptBackInTheLedgerAndOffersTheStopped() throws {
        let kernel = FakeActivityKernel(uid: 501)
        let kept = ActivityProcessID(pid: 4242, start: 4_242_000)
        let stopped = ActivityProcessID(pid: 4343, start: 4_343_000)
        for (identity, status) in [(kept, SRUN), (stopped, SSTOP)] {
            var fake = FakeActivityKernel.Process(record: process(identity, status: status))
            fake.name = "acme-worker"
            kernel.add(fake)
        }
        let snapshot = try XCTUnwrap(ActivitySampler(kernel: kernel).tickNow(ActivityDemand(.full), context: ActivityContext()))
        let persistence = ActivityPersistence.shared
        XCTAssertTrue(ActivityPersisted(kept: [kept, ActivityProcessID(pid: 9, start: 9)], stopped: [stopped]).save(to: persistence.url))
        let ledger = LeftBehindLedger(monitor: ActivityMonitor(sampler: ActivitySampler(kernel: kernel)))
        XCTAssertEqual(persistence.restore(from: snapshot, ledger: ledger), [stopped])
        XCTAssertEqual(ledger.kept, [kept])
        persistence.flush()
        XCTAssertEqual(ActivityPersisted.load(from: persistence.url).keptIdentities, [kept], "written again, swept")
        XCTAssertTrue(ActivityPersisted().save(to: persistence.url))
    }

    /// The writer's wiring (10.3 item 15): a Keep and a Suspend each reach
    /// the file — pid and start only, 0600 — and what an earlier run wrote
    /// stays in it until the launch's census has swept it.
    @MainActor
    func testKeepAndSuspendAreWrittenAndTheEarlierRunsRecordKeptUntilRestored() throws {
        let persistence = ActivityPersistence()
        let earlier = ActivityProcessID(pid: 4141, start: 4_141_000)
        XCTAssertTrue(ActivityPersisted(kept: [earlier]).save(to: persistence.url))
        defer { ActivityPersisted().save(to: persistence.url) }
        let kernel = FakeActivityKernel(uid: 501)
        let ledger = LeftBehindLedger(monitor: ActivityMonitor(sampler: ActivitySampler(kernel: kernel)))
        let held = ActivityHeld()
        persistence.start(ledger: ledger, held: held)
        let kept = ActivityProcessID(pid: 4242, start: 4_242_000)
        ledger.keep([kept])
        persistence.flush()
        XCTAssertEqual(ActivityPersisted.load(from: persistence.url).keptIdentities, [earlier, kept], "the earlier run's kept one isn't replaced")
        let stopped = ActivitySignalTarget(ActivityProcessID(pid: 4343, start: 4_343_000), path: "/opt/acme/bin/acme-worker")
        held.suspended(root: stopped, name: "acme-worker", members: [stopped], names: [stopped.identity: "acme-worker"])
        persistence.flush()
        XCTAssertEqual(ActivityPersisted.load(from: persistence.url).stoppedIdentities, [stopped.identity])
        let bytes = try Data(contentsOf: persistence.url)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("acme"), "no name, no path")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: [[String: Any]]])
        XCTAssertEqual(Set(object.values.flatMap { $0.flatMap(\.keys) }), ["pid", "start"])
        var info = stat()
        XCTAssertEqual(lstat(persistence.url.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        // The launch's census: the earlier one ended, the rest still runs and is still stopped.
        var running = FakeActivityKernel.Process(record: process(kept))
        running.name = "acme-worker"
        kernel.add(running)
        var frozen = FakeActivityKernel.Process(record: process(stopped.identity, status: SSTOP))
        frozen.name = "acme-worker"
        kernel.add(frozen)
        let snapshot = try XCTUnwrap(ActivitySampler(kernel: kernel).tickNow(ActivityDemand(.full), context: ActivityContext()))
        XCTAssertEqual(persistence.restore(from: snapshot, ledger: ledger), [stopped.identity])
        persistence.flush()
        let after = ActivityPersisted.load(from: persistence.url)
        XCTAssertEqual(after.keptIdentities, [kept], "swept of the earlier run's ended one")
        XCTAssertEqual(after.stoppedIdentities, [stopped.identity])
        // Swept now: a change writes only what the app holds.
        ledger.prune(in: try XCTUnwrap(ActivitySampler(kernel: kernel).tickNow(ActivityDemand(.full), context: ActivityContext())))
        persistence.flush()
        XCTAssertEqual(ActivityPersisted.load(from: persistence.url).keptIdentities, [kept])
    }
}
