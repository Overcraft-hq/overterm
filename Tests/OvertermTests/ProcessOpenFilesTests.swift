import Darwin
import Foundation
import XCTest

@testable import Overterm
@testable import OvertermCore

/// The detail's Files (docs/design/activity/analysis.md, 6.4, `l`) over a
/// fake Mac: files by path, sockets as the census decodes them, pipes and
/// the other kinds named, the cap and the deadline said; another user's
/// and a reused pid read as nothing. Every name is invented.
final class ProcessOpenFilesTests: XCTestCase {
    private let kernel = FakeActivityKernel(uid: 501)

    private func add(_ pid: pid_t, uid: uid_t = 501) -> ActivityProcessID {
        var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: pid, start: UInt64(pid), parent: 1, uid: uid, name: "acme-db"))
        process.descriptors = [
            FakeActivityKernel.descriptor(3, socket: false), FakeActivityKernel.descriptor(4), FakeActivityKernel.descriptor(5),
            proc_fdinfo(proc_fd: 6, proc_fdtype: UInt32(PROX_FDTYPE_PIPE)), proc_fdinfo(proc_fd: 7, proc_fdtype: UInt32(PROX_FDTYPE_KQUEUE)),
            FakeActivityKernel.descriptor(8, socket: false),
        ]
        process.files = [3: "/tmp/acme-data/base/1"]
        process.sockets = [
            4: FakeActivityKernel.tcp(local: "127.0.0.1", port: 5432, handle: 1),
            5: FakeActivityKernel.unix(handle: 2, path: "/tmp/.s.ACME.5432", listening: true),
        ]
        kernel.add(process)
        return ActivityProcessID(pid: pid, start: UInt64(pid))
    }

    func testWhatItHoldsOpen() {
        let listing = ProcessOpenFiles.read(add(2000), kernel: kernel)
        XCTAssertFalse(listing.gone)
        XCTAssertNil(listing.cut)
        XCTAssertEqual(listing.descriptors, 6)
        XCTAssertEqual(
            listing.entries.map(\.text),
            ["/tmp/acme-data/base/1", "TCP 127.0.0.1:5432, listening", "unix /tmp/.s.ACME.5432, listening", "pipe", "kqueue", "a file (its path can't be read)"])
        XCTAssertEqual(listing.entries.map(\.kind), [.file, .socket, .socket, .pipe, .kqueue, .file])
    }

    func testAnotherUsersOrAReusedPidIsNothing() {
        let other = add(2001, uid: 0)
        XCTAssertTrue(ProcessOpenFiles.read(other, kernel: kernel).gone, "the kernel refuses another user's")
        _ = add(2002)
        XCTAssertTrue(ProcessOpenFiles.read(ActivityProcessID(pid: 2002, start: 1), kernel: kernel).gone, "its pid is another's now")
    }

    /// A path read that never comes back (a hard-mounted share that
    /// stopped answering) is left behind: the read stops there, and a
    /// later read says so at once, asking for no path, until it returns.
    func testAFileThatNeverAnswersIsLeftBehind() {
        let identity = add(2003)
        let release = DispatchSemaphore(value: 0)
        kernel.onCall { call in if call == "vnodePath" { release.wait() } }
        let stuck = ProcessOpenFiles.Stuck()
        let first = ProcessOpenFiles.read(identity, kernel: kernel, wait: .milliseconds(50), stuck: stuck)
        XCTAssertEqual(first.cut?.hasPrefix("a file isn't answering"), true, first.cut ?? "whole")
        XCTAssertTrue(stuck.isStuck)
        let second = ProcessOpenFiles.read(identity, kernel: kernel, wait: .milliseconds(50), stuck: stuck)
        XCTAssertEqual(second.cut?.hasPrefix("a file read earlier still isn't answering"), true, second.cut ?? "whole")
        XCTAssertEqual(kernel.count("vnodePath"), 1, "no path is asked for while one hangs")
        kernel.onCall(nil)
        release.signal()
        let back = expectation(for: NSPredicate { _, _ in !stuck.isStuck }, evaluatedWith: nil)
        wait(for: [back], timeout: 10)
        let third = ProcessOpenFiles.read(identity, kernel: kernel, stuck: stuck)
        XCTAssertNil(third.cut)
        XCTAssertEqual(third.entries.first?.text, "/tmp/acme-data/base/1")
    }

    func testSocketsInWords() {
        let connection = SocketRecord.classify(
            FakeActivityKernel.tcp(local: "::1", port: 52000, remote: "::1", remotePort: 3000, state: .established), descriptor: 9)
        XCTAssertEqual(connection.map(ProcessOpenFiles.describe), "TCP [::1]:52000 → [::1]:3000, established")
        XCTAssertEqual(SocketRecord.classify(FakeActivityKernel.udp(local: "0.0.0.0", port: 5353), descriptor: 9).map(ProcessOpenFiles.describe), "UDP *:5353")
        XCTAssertEqual(SocketRecord.classify(FakeActivityKernel.unix(), descriptor: 9).map(ProcessOpenFiles.describe), "unix socket")
    }
}
