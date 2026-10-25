import AppKit

/// Suspend Tab and Resume Tab on a tab running something in the
/// foreground: everything stopped, the job still the terminal's when it
/// continues, and a suspended tab closes cleanly.
extension E2ERunner {
    func suspendScenario() async {
        app.newTab(in: scratch)
        guard let tab = app.store.selected, let pane = app.store.selected?.terminal else { return check("a tab", false) }
        check("the shell is up", await eventually { pane.shellReported })
        pane.insertText("sleep 300")
        pane.pressReturn()
        let login = SurfaceProcesses.shared.loginPID(of: pane)
        func processes() -> [ProcessNode] { ProcessInspector().tree(root: login, tag: pane.processTag).flatMap(\.flattened) }
        check("it runs", await eventually { processes().contains { $0.name == "sleep" } }, "\(processes().map(\.name))")
        guard let sleep = processes().first(where: { $0.name == "sleep" }) else { return }

        check("the menu offers Suspend Tab", app.menu(for: tab).items.contains { $0.title == "Suspend Tab" })
        app.suspendTab(tab)
        check("Suspend Tab stops every process in it", await eventually(5) { processes().allSatisfy { Self.isStopped($0.pid) } }, "\(processes().map { "\($0.name):\(Self.isStopped($0.pid))" })")
        check("the tab says so", tab.isSuspended && app.menu(for: tab).items.contains { $0.title == "Resume Tab" })
        check("a cover over the pane", pane.subviews.contains { $0 is SuspendedCover })
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
            await pause(0.5)
            app.captureWindow(to: png)
        }
        await pause(1)
        check("still stopped a moment later", Self.isStopped(sleep.pid))

        app.resumeTab(tab)
        check("Resume Tab continues them", await eventually(5) { processes().allSatisfy { !Self.isStopped($0.pid) } })
        check("the cover goes", !pane.subviews.contains { $0 is SuspendedCover } && !tab.isSuspended)
        // The shell never saw its job stop: the job keeps the terminal,
        // rather than continuing in the background behind a prompt.
        check(
            "the job keeps the terminal",
            login.flatMap(ProcessInspector.foregroundGroup(of:)) == ProcessInspector.processGroup(of: sleep.pid),
            "foreground \(String(describing: login.flatMap(ProcessInspector.foregroundGroup(of:)))), sleep's \(String(describing: ProcessInspector.processGroup(of: sleep.pid)))")

        // Closed while suspended: continued first, so the hangup lands.
        app.suspendTab(tab)
        check("suspended again", await eventually(5) { Self.isStopped(sleep.pid) })
        let pids = processes().map(\.pid)
        pane.close()
        check("a suspended pane closes with its processes", await eventually(5) { pids.allSatisfy { kill($0, 0) != 0 } }, "\(pids.filter { kill($0, 0) == 0 })")
    }

    static func isStopped(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_stat == SSTOP
    }
}
