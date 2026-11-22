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

/// A process a census test started (docs/design/activity/analysis.md,
/// 10.2, 10.6): in a process group of its own, never the runner's; its
/// identity — pid and start — read at spawn; signalled only by its pid,
/// only once that identity is read again and matches, and reaped. Never a
/// name, a pattern, `kill(-1)` or a group the test didn't make.
final class TestChild {
    let pid: pid_t
    let identity: ActivityProcessID
    private var reaped = false

    /// `stdin`: a descriptor it reads instead of /dev/null — a pipe the
    /// test writes to when the child should go on.
    init(
        _ executable: String, _ arguments: [String], environment: [String: String] = [:], descriptors: [Int32: Int32] = [:], stdin: Int32? = nil
    ) throws {
        let null = open("/dev/null", O_WRONLY)
        defer { close(null) }
        pid = try ProcessGroup.spawn(
            URL(fileURLWithPath: executable), arguments, environment, stdout: null, stderr: null, stdin: stdin, descriptors: descriptors
        ).get()
        guard let start = ProcessInspector.kinfo(pid)?.start else {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            throw POSIXError(.ESRCH)
        }
        identity = ActivityProcessID(pid: pid, start: start)
    }

    /// Ends it — SIGKILL to its pid, after its identity is read again — and
    /// reaps it. A zombie keeps its identity until reaped.
    func stop() {
        guard !reaped else { return }
        reaped = true
        var status: Int32 = 0
        guard ProcessInspector.kinfo(pid)?.start == identity.start else {
            waitpid(pid, &status, WNOHANG)
            return
        }
        kill(pid, SIGKILL)
        waitpid(pid, &status, 0)
    }

    deinit { stop() }

    /// SIGKILL to its pid, after its identity is read again, and not
    /// reaped: a zombie, its identity kept, until `stop` or `exited` reaps it.
    func killUnreaped() {
        guard !reaped, ProcessInspector.kinfo(pid)?.start == identity.start else { return }
        kill(pid, SIGKILL)
    }

    /// Waits up to `seconds` for it to end by itself, and reaps it: how it
    /// ended (`waitpid`'s status); nil while it still runs.
    func exited(within seconds: TimeInterval = 10) -> Int32? {
        guard !reaped else { return nil }
        var status: Int32 = 0
        guard TestChild.eventually(seconds, { waitpid(pid, &status, WNOHANG) == pid }) else { return nil }
        reaped = true
        return status
    }

    /// Waits for `condition`, up to `seconds`: never a moment sampled.
    static func eventually(_ seconds: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date() + seconds
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    /// This test process's environment without Overterm's markers, so a
    /// child carries only what a test plants.
    static var cleanEnvironment: [String: String] {
        ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("OVERTERM_") && $0.key != "XPC_SERVICE_NAME" }
    }
}
