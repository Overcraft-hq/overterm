#if E2E
import Foundation

/// The harness's leftover check, inside the app (docs/design/activity/
/// analysis.md, 10.5): at a scenario's end, once what quitting ends was
/// ended, anything of the run's still running — its `OVERTERM_RUN`, a
/// stand-in's own record in the scratch folder, an argv sign naming the
/// run's pid and start or its scratch folder, a helper registry's pid, or
/// anything still under the app; only where its parents lead to the run or
/// launchd (`RunLeftovers`) — is a
/// failure, said by pid and name, then stopped by its exact identity
/// through the one signal path, the gate admitting it as the run's own.
/// The test harness looks again once the app has quit.
extension E2ERunner {
    /// What the harness reads before the app's lines: this run's marker and
    /// its scratch folder, both the test's own.
    package func announceRun() {
        print("E2E RUN \(OvertermRun.current.marker) \(scratch.path)")
        fflush(stdout)
    }

    package func checkNothingLeftRunning() async {
        let run = OvertermRun.current
        let scratch = scratch
        // The panes' shells end on their hangup, a stand-in on its pipe's
        // end: given their moment, read off the main thread each time.
        var left: [RunLeftover] = []
        let deadline = Date().addingTimeInterval(10)
        repeat {
            // The app is alive: what is still under it, or in a helper's
            // registry (a terraform's group), is the run's too — a
            // platform binary a pane left says nothing else (6.9).
            left = await Task.detached {
                RunLeftovers.find(run: run, scratch: scratch, registered: ActivityHelperGroups.now(), descendants: true)
            }.value
            if left.isEmpty { break }
            await pause(0.25)
        } while Date() < deadline
        check("at the end, nothing of the run's is left running", left.isEmpty, left.map(\.said).joined(separator: "; "))
        guard !left.isEmpty else { return }
        let stopped = await Task.detached { Self.stop(left) }.value
        check("what the run left is stopped by its identity", stopped, "still running: \(left.map(\.identity.pid))")
    }

    /// TERM, then KILL to what is still that process after 5 s — each by
    /// the identity found, through `ProcessSignals`, registered with the
    /// gate first: it is the run's own. True once every one has ended.
    package nonisolated static func stop(_ left: [RunLeftover]) -> Bool {
        let kernel = LiveActivityKernel()
        let signals = ProcessSignals(kernel: kernel)
        let targets = left.map { ActivitySignalTarget($0.identity, path: kernel.path(of: $0.identity.pid)) }
        for target in targets { ActivitySignalGate.shared.register(target.identity) }
        defer { for target in targets { ActivitySignalGate.shared.unregister(target.identity) } }
        func running(_ target: ActivitySignalTarget) -> Bool {
            guard let process = kernel.process(target.identity.pid) else { return false }
            return process.identity == target.identity && !process.isZombie
        }
        for target in targets { _ = signals.send(.term, to: target, alone: true) }
        for _ in 0..<50 where targets.contains(where: running) { usleep(100_000) }
        for target in targets where running(target) { _ = signals.send(.kill, to: target, alone: true) }
        for _ in 0..<30 where targets.contains(where: running) { usleep(100_000) }
        return !targets.contains(where: running)
    }
}
#endif
