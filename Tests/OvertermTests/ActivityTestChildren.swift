import Darwin
import Foundation
import XCTest

@testable import Overterm

/// A process a census test started (docs/design/activity/analysis.md,
/// 10.2, 10.6): in a process group of its own, never the runner's; its
/// identity — pid and start — read at spawn; signalled only by its pid,
/// only once that identity is read again and matches, and reaped. Never a
/// name, a pattern, `kill(-1)` or a group the test didn't make.
final class TestChild {
    let pid: pid_t
    let identity: ActivityProcessID
    private var reaped = false

    init(_ executable: String, _ arguments: [String], environment: [String: String] = [:], descriptors: [Int32: Int32] = [:]) throws {
        let null = open("/dev/null", O_WRONLY)
        defer { close(null) }
        pid = try ProcessGroup.spawn(
            URL(fileURLWithPath: executable), arguments, environment, stdout: null, stderr: null, descriptors: descriptors
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
