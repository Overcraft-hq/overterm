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
@testable import OvertermSimulator
@testable import OvertermUsage
@testable import OvertermSettingsPage
@testable import OvertermAgents
@testable import OvertermActivity
@testable import OvertermE2E

/// A long-lived child process (`ManagedProcess`) and the pool that keeps one
/// a key: started and waited for, the reason it failed, closed by its own
/// pid, reopened on the next use after it died. Only /bin/sh and /bin/sleep.
final class ManagedProcessTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        // Short: a unix socket's path is 104 bytes at most.
        folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("ot-mp-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        ManagedProcess.closeAll()
        try? FileManager.default.removeItem(at: folder)
    }

    private func shell(_ script: String, readiness: ManagedProcess.Readiness, timeout: TimeInterval = 5, removing: [String] = []) -> ManagedProcess.Launch {
        ManagedProcess.Launch(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], readiness: readiness, timeout: timeout, removing: removing)
    }

    private func until(_ ok: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !ok(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    private static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    func testALineOnStdoutSaysItIsReady() async throws {
        let process = try await ManagedProcess.start(
            shell("echo starting; sleep 0.2; echo 'Starting to serve on /tmp/x.sock'; exec sleep 30", readiness: .line { $0.hasPrefix("Starting to serve on ") }))
        XCTAssertTrue(process.isRunning)
        XCTAssertTrue(process.stdout.text.contains("Starting to serve on /tmp/x.sock"))
        let pid = process.pid
        XCTAssertGreaterThan(pid, 0)
        XCTAssertTrue(ManagedProcess.livePIDs.contains(pid))
        process.close()
        try await until { !process.isRunning }
        XCTAssertFalse(process.isRunning)
        XCTAssertFalse(Self.alive(pid), "its own pid was ended")
        XCTAssertFalse(ManagedProcess.livePIDs.contains(pid))
    }

    /// What it started (an exec plugin kubectl ran) ends with it: found
    /// before it is signalled, by pid and start time, SIGKILLed after the
    /// grace when SIGTERM wasn't enough.
    func testWhatItStartedEndsWithIt() async throws {
        let process = try await ManagedProcess.start(
            shell("trap '' TERM; /bin/sleep 30 & /bin/sh -c \"trap '' TERM; exec /bin/sleep 31\" & echo ready; wait", readiness: .line { $0 == "ready" }))
        try await until { ManagedProcess.descendants(of: process.pid).count >= 2 }
        let family = ManagedProcess.descendants(of: process.pid).map(\.pid)
        XCTAssertGreaterThanOrEqual(family.count, 2, "its children found")
        XCTAssertTrue(family.allSatisfy(Self.alive))
        process.close(grace: 0.3)
        let deadline = Date().addingTimeInterval(5)
        while family.contains(where: Self.alive), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(family.contains(where: Self.alive), "every child ended: \(family.filter(Self.alive))")
    }

    /// Its family from the census's child map (7.8), of one table: its
    /// children and theirs, breadth first, bounded; a zombie left out, and
    /// one holding a pid that started before its "parent" — a dead
    /// parent's pid reused — isn't its. One table read for the whole walk.
    func testItsFamilyFromOneTable() throws {
        let kernel = FakeActivityKernel(uid: 501)
        func add(_ pid: pid_t, parent: pid_t, start: UInt64? = nil, status: Int32 = SRUN) {
            kernel.add(
                FakeActivityKernel.Process(
                    record: FakeActivityKernel.record(pid: pid, start: start ?? UInt64(pid) * 1_000, parent: parent, status: status, name: "fake-\(pid)")))
        }
        add(1, parent: 0)
        add(500, parent: 1)
        add(501, parent: 500)
        add(502, parent: 500, status: SZOMB)
        add(503, parent: 501)
        add(504, parent: 500, start: 1)
        add(600, parent: 1)
        let table = try XCTUnwrap(ProcessTable.read(kernel))
        XCTAssertEqual(kernel.count("processes"), 1)
        let family = ManagedProcess.descendants(of: 500, in: table)
        XCTAssertEqual(family.map(\.pid), [501, 503], "no zombie, no stranger holding a reused pid")
        XCTAssertEqual(family.map(\.start), [501_000, 503_000])
        XCTAssertEqual(ManagedProcess.descendants(of: 500, limit: 1, in: table).map(\.pid), [501])
        XCTAssertTrue(ManagedProcess.descendants(of: 999, in: table).isEmpty, "none: nothing holds it")
    }

    /// A close on the main thread returns at once, no longer open; its
    /// family is found and signalled on the closes' queue, and ends.
    @MainActor
    func testACloseOnTheMainThreadSignalsOffIt() async throws {
        let process = try await ManagedProcess.start(
            shell("/bin/sleep 30 & echo ready; wait", readiness: .line { $0 == "ready" }))
        func waited(_ ok: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !ok(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        }
        try await waited { ManagedProcess.descendants(of: process.pid).count >= 1 }
        let family = ManagedProcess.descendants(of: process.pid).map(\.pid)
        XCTAssertFalse(family.isEmpty)
        let reads = TableReads()
        // The closes' queue held: close must return before its work runs.
        ManagedProcess.closing.suspend()
        var held = true
        defer { if held { ManagedProcess.closing.resume() } }
        process.close(grace: 0.3) {
            reads.add(Thread.isMainThread)
            return ProcessTable.read(LiveActivityKernel())
        }
        XCTAssertFalse(ManagedProcess.openGroups.contains(process.pid), "closed when it returns")
        XCTAssertTrue(reads.values.isEmpty, "returned before the table was read")
        XCTAssertTrue(family.allSatisfy(Self.alive), "nothing signalled yet")
        ManagedProcess.closing.resume()
        held = false
        try await waited { !family.contains(where: Self.alive) && !process.isRunning }
        XCTAssertFalse(family.contains(where: Self.alive))
        XCTAssertEqual(reads.values, [false], "one table read, off the main thread")
    }

    /// It runs in a process group of its own: what it started and no
    /// longer parents — a plugin reparented once kubectl exited — ends
    /// with it, though no walk of its children finds it.
    func testWhatItStartedEndsWithItEvenReparented() async throws {
        let file = folder.appendingPathComponent("orphan.pid")
        let process = try await ManagedProcess.start(
            shell("(/bin/sleep 33 & echo $! > \(file.path)); echo ready; exec /bin/sleep 30", readiness: .line { $0 == "ready" }))
        try await until { ((try? String(contentsOf: file, encoding: .utf8)) ?? "").hasSuffix("\n") }
        let orphan = try XCTUnwrap(pid_t(((try? String(contentsOf: file, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
        try await until { ProcessInspector.kinfo(orphan)?.parent != process.pid && !ManagedProcess.descendants(of: process.pid).contains { $0.pid == orphan } }
        XCTAssertFalse(ManagedProcess.descendants(of: process.pid).contains { $0.pid == orphan }, "not its child any more")
        XCTAssertEqual(getpgid(orphan), process.pid, "in its group")
        XCTAssertTrue(Self.alive(orphan))
        process.close(grace: 0.3)
        try await until { !Self.alive(orphan) }
        XCTAssertFalse(Self.alive(orphan), "ended with its group")
    }

    func testASocketThatTakesConnectionsSaysItIsReady() async throws {
        let path = folder.appendingPathComponent("ready.sock").path
        // Something left at the path is removed before it starts.
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
        let listener = Task.detached { @Sendable () async throws -> Int32 in
            try await Task.sleep(for: .milliseconds(300))
            return Self.listen(on: path)
        }
        let process = try await ManagedProcess.start(shell("exec sleep 30", readiness: .socket(path), removing: [path]))
        let fd = try await listener.value
        defer { Darwin.close(fd) }
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertTrue(process.isRunning)
        XCTAssertTrue(ManagedProcess.accepts(path))
        process.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "what it made is removed when it is closed")
        XCTAssertFalse(ManagedProcess.accepts(folder.appendingPathComponent("nothing.sock").path))
    }

    func testAProcessThatExitsSaysWhyOnStderr() async throws {
        do {
            _ = try await ManagedProcess.start(shell("echo 'Permission denied (publickey).' >&2; exit 3", readiness: .line { _ in false }))
            XCTFail("ready though it exited")
        } catch let failure as ManagedProcess.Failure {
            XCTAssertEqual(failure, .exited(status: 3, stderr: "Permission denied (publickey).\n"))
        }
    }

    func testOneNeverReadyIsClosedAtTheTimeout() async throws {
        let before = Set(ManagedProcess.livePIDs)
        do {
            _ = try await ManagedProcess.start(shell("exec sleep 30", readiness: .line { _ in false }, timeout: 0.5))
            XCTFail("ready though it never said so")
        } catch let failure as ManagedProcess.Failure {
            XCTAssertEqual(failure, .timedOut)
        }
        XCTAssertEqual(Set(ManagedProcess.livePIDs), before, "nothing of it left running")
    }

    func testAMissingExecutableCouldNotStart() async throws {
        do {
            _ = try await ManagedProcess.start(
                ManagedProcess.Launch(executable: URL(fileURLWithPath: "/nonexistent/kubectl"), arguments: [], readiness: .line { _ in true }))
            XCTFail("started what isn't there")
        } catch let failure as ManagedProcess.Failure {
            guard case .couldNotStart = failure else { return XCTFail("\(failure)") }
        }
    }

    func testCloseAllEndsEveryOne() async throws {
        let ready = ManagedProcess.Readiness.line { $0 == "up" }
        let one = try await ManagedProcess.start(shell("echo up; exec sleep 30", readiness: ready))
        let two = try await ManagedProcess.start(shell("echo up; exec sleep 30", readiness: ready))
        ManagedProcess.closeAll()
        try await until { !one.isRunning && !two.isRunning }
        XCTAssertFalse(one.isRunning)
        XCTAssertFalse(two.isRunning)
        XCTAssertTrue(ManagedProcess.livePIDs.isEmpty)
    }

    func testOutputKeepsItsLast16KB() {
        let output = ManagedProcess.Output()
        output.append(Data(repeating: UInt8(ascii: "a"), count: ManagedProcess.Output.limit))
        output.append(Data("the end".utf8))
        XCTAssertEqual(output.text.utf8.count, ManagedProcess.Output.limit)
        XCTAssertTrue(output.text.hasSuffix("the end"))
        XCTAssertFalse(output.finished)
        output.finish()
        XCTAssertTrue(output.finished)
    }

    // MARK: The pool

    private final class Resource: ManagedResource {
        let process: ManagedProcess
        init(_ process: ManagedProcess) { self.process = process }
        var isOpen: Bool { process.isRunning }
        func close() { process.close() }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int {
            lock.withLock {
                count += 1; return count
            }
        }
        var value: Int { lock.withLock { count } }
    }

    private func pool(counting opens: Counter) -> ManagedProcessPool<String, Resource> {
        ManagedProcessPool<String, Resource> { _ in
            _ = opens.next()
            let process = try await ManagedProcess.start(
                ManagedProcess.Launch(
                    executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 0.2; echo up; exec sleep 30"], readiness: .line { $0 == "up" }, timeout: 5))
            return Resource(process)
        }
    }

    func testUsesThatArriveWhileItOpensWaitForTheOne() async throws {
        let opens = Counter()
        let pool = pool(counting: opens)
        async let a = pool.value(for: "ctx")
        async let b = pool.value(for: "ctx")
        let (first, second) = try await (a, b)
        XCTAssertTrue(first === second)
        XCTAssertEqual(opens.value, 1)
        let other = try await pool.value(for: "other")
        XCTAssertFalse(other === first, "one a key")
        XCTAssertEqual(opens.value, 2)
        pool.closeAll()
        try await until { !first.isOpen && !other.isOpen }
        XCTAssertFalse(first.isOpen)
        XCTAssertFalse(other.isOpen)
    }

    func testTheNextUseAfterItDiedOpensItAgain() async throws {
        let opens = Counter()
        let pool = pool(counting: opens)
        let first = try await pool.value(for: "ctx")
        // It dies on its own (the network changed, the Mac slept).
        kill(first.process.pid, SIGKILL)
        try await until { !first.isOpen }
        let second = try await pool.value(for: "ctx")
        XCTAssertFalse(first === second)
        XCTAssertTrue(second.isOpen)
        XCTAssertEqual(opens.value, 2)
        let existing = await pool.existing("ctx")
        XCTAssertTrue(existing === second)
        await pool.close("ctx")
        try await until { !second.isOpen }
        XCTAssertFalse(second.isOpen)
        let gone = await pool.existing("ctx")
        XCTAssertNil(gone)
    }

    /// A listening unix socket at `path`, as a proxy would make it.
    private static func listen(on path: String) -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else {
            Darwin.close(fd)
            return -1
        }
        return fd
    }
}

/// Where each table read for a close ran, recorded from any thread.
private final class TableReads: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []
    func add(_ onMain: Bool) { lock.withLock { recorded.append(onMain) } }
    var values: [Bool] { lock.withLock { recorded } }
}
