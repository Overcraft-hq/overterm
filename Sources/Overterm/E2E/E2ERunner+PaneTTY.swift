import AppKit
import Darwin

/// Stage 0's spikes in the app (docs/design/activity/analysis.md, 3.11,
/// 7.10): each pane's pty named by libghostty against what the census
/// reads.
/// Read only: the real process table, the run's own panes and processes
/// alone named, counts and devices printed — nothing else of the Mac's.
extension E2ERunner {
    /// 7.10's checks 1–4 over a tab's first two panes, each running a job:
    /// the name libghostty gives, the `login` and shell on that terminal,
    /// the same members through the tty as through the pairing, and a
    /// process that called `setsid` off the tty but still in the tree.
    func paneTTYChecks(_ tab: Tab) async {
        let panes = Array(tab.terminals.prefix(2))
        guard panes.count == 2 else { return check("two panes for the tty spike", false) }
        // Building the census's context asks a paired pane once more.
        let named = await eventually(10) {
            _ = TerminalWindowController.activityContext()
            return panes.allSatisfy { $0.terminalDevice != nil && SurfaceProcesses.shared.login(of: $0) != nil }
        }
        check(
            "each pane's pty is named, once its login is paired (7.10, 1)", named,
            panes.map { "\($0.terminalDevice.map { String($0) } ?? "none") / \(SurfaceProcesses.shared.login(of: $0)?.description ?? "unpaired")" }
                .joined(separator: " | "))
        guard named else { return }
        let devices = panes.compactMap(\.terminalDevice)
        check("two panes, two ptys", Set(devices).count == 2, "\(devices)")
        let context = TerminalWindowController.activityContext()
        check(
            "and the census's context carries them",
            panes.allSatisfy { pane in context.panes.first { $0.tag == pane.processTag }?.terminal == pane.terminalDevice })

        // One table for both ways in, so nothing moves between them.
        let logins = panes.compactMap { SurfaceProcesses.shared.login(of: $0) }
        var last = ""
        let same = await eventuallyAsync(6) {
            guard let table = await Self.processTable() else { return false }
            var ok = true
            var said: [String] = []
            for (login, device) in zip(logins, devices) {
                let tree = Set([login] + table.descendants(of: login).filter { !$0.isZombie }.map(\.identity))
                let byTTY = Set(table.processes.filter { $0.terminal == device && !$0.isZombie }.map(\.identity))
                if tree != byTTY { ok = false }
                said.append("tree \(tree.count), tty \(byTTY.count), only in tree \(tree.subtracting(byTTY).count), only on tty \(byTTY.subtracting(tree).count)")
            }
            last = said.joined(separator: " | ")
            return ok
        }
        check("each pane's members are the same through its tty as through its paired login (7.10, 3)", same, last)

        if let table = await Self.processTable() {
            let carried = zip(logins, devices).allSatisfy { login, device in
                guard table.process(login)?.terminal == device else { return false }
                let shells = table.children(of: login)
                return !shells.isEmpty && shells.allSatisfy { $0.terminal == device }
            }
            check("the login and its shell carry the pane's terminal (7.10, 2)", carried)
        }

        // A process that leaves its session: off the tty, still in the tree.
        let right = panes[1]
        window.makeFirstResponder(right)
        await eventually(2) { tab.terminal === right }
        let pidFile = out("setsid-pid")
        let stop = out("setsid-stop")
        let script =
            "import os,time\npid=os.fork()\nif pid==0:\n os.setsid()\n open('\(pidFile.path)','w').write(str(os.getpid()))\n"
            + " n=0\n while not os.path.exists('\(stop.path)') and n<300:\n  time.sleep(0.1); n+=1\n os._exit(0)\nos.wait()\n"
        try? script.write(to: out("setsid.py"), atomically: true, encoding: .utf8)
        await runAndExpect(
            "python3 \(out("setsid.py").path) & echo s > \(out("setsid-started").path)", file: out("setsid-started"), content: "s",
            "a job that calls setsid")
        let leftItsTTY = await eventuallyAsync(10) {
            guard let pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap({ pid_t($0) }), let table = await Self.processTable(),
                let login = logins.last, let process = table.process(pid: pid)
            else { return false }
            let inTree = table.descendants(of: login).contains { $0.identity == process.identity }
            return process.terminal == nil && inTree
        }
        check("a process that called setsid drops off the tty and is found by the tree (7.10, 4)", leftItsTTY)
        // It ends itself: no signal from here.
        FileManager.default.createFile(atPath: stop.path, contents: Data())
    }

    /// One `KERN_PROC_ALL`, read here for the scenario's checks only — off
    /// the main thread, as every read of the whole table is (7.1).
    private static func processTable() async -> ProcessTable? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { @Sendable in
                continuation.resume(returning: ProcessTable.read(LiveActivityKernel()))
            }
        }
    }
}
