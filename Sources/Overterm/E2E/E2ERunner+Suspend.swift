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

        // Suspend Other Tabs, from a second tab: the first stops, this one
        // runs; the strip counts what is stopped.
        app.newTab(in: scratch)
        guard let other = app.store.selected, other !== tab else { return check("a second tab", false) }
        let menu = app.menu(for: other)
        if let index = menu.items.firstIndex(where: { $0.title == "Suspend Other Tabs" }) {
            menu.performActionForItem(at: index)
        }
        check("Suspend Other Tabs stops the others", await eventually(5) { tab.isSuspended && Self.isStopped(sleep.pid) })
        check("and leaves this one", !other.isSuspended)
        check("the strip counts them", app.store.tabs.filter(\.isSuspended).count >= 1)
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
            app.store.select(tab)
            await pause(0.6)
            app.captureWindow(to: png)
        }
        app.store.tabs.filter(\.isSuspended).forEach { app.resumeTab($0) }
        check("Resume All carries them on", await eventually(5) { !Self.isStopped(sleep.pid) && !app.store.tabs.contains(where: \.isSuspended) })

        // In the second tab, at its prompt: the first runs its job.
        await suspendLeavesADaemon(tab: other)

        // Closed while suspended: continued first, so the hangup lands.
        app.suspendTab(tab)
        check("suspended again", await eventually(5) { Self.isStopped(sleep.pid) })
        let pids = processes().map(\.pid)
        pane.close()
        check("a suspended pane closes with its processes", await eventually(5) { pids.allSatisfy { kill($0, 0) != 0 } }, "\(pids.filter { kill($0, 0) == 0 })")
    }

    /// The pane's set (docs/design/activity/analysis.md, 6.5, 10.3 item
    /// 13): a tmux-like daemon started in the tab — setsid'd, launchd's
    /// child, carrying the pane's tag, a child of its own on a pty of its
    /// own — is shown with the pane but never stopped with it. Both are
    /// made this run's own in the isolated-run gate, so only the pane's
    /// set keeps them running: the gate would let a SIGSTOP through.
    private func suspendLeavesADaemon(tab: Tab) async {
        let pane = tab.terminal
        check("the second tab's shell is up", await eventually { pane.shellReported })
        let login = SurfaceProcesses.shared.loginPID(of: pane)
        let script = out("acme-mux.py")
        let written = out("acme-mux.pids")
        let source = """
            import os, pty, sys, time
            out = sys.argv[1]
            if os.fork():
                sys.exit(0)
            os.setsid()
            pid, fd = pty.fork()
            if pid == 0:
                time.sleep(300)
                os._exit(0)
            with open(out + ".tmp", "w") as f:
                f.write("%d %d\\n" % (os.getpid(), pid))
            os.rename(out + ".tmp", out)
            time.sleep(300)

            """
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        guard (try? source.write(to: script, atomically: true, encoding: .utf8)) != nil else { return check("the daemon's script", false) }
        pane.insertText("/usr/bin/python3 '\(script.path)' '\(written.path)'")
        pane.pressReturn()
        func pids() -> [pid_t] {
            guard let text = try? String(contentsOf: written, encoding: .utf8) else { return [] }
            return text.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
        }
        check("a daemon starts in the tab", await eventually(15) { pids().count == 2 })
        let found = pids()
        guard found.count == 2, let daemon = ProcessInspector.kinfo(found[0]), let child = ProcessInspector.kinfo(found[1]) else { return }
        let identities = [ActivityProcessID(pid: found[0], start: daemon.start), ActivityProcessID(pid: found[1], start: child.start)]
        // Ended by the identities read here, and only those.
        defer {
            for identity in identities {
                ActivitySignalGate.shared.unregister(identity)
                if ProcessInspector.kinfo(identity.pid)?.start == identity.start { kill(identity.pid, SIGKILL) }
            }
        }
        // The test's own: what its script wrote, a child of its own, under
        // launchd since it left the tab — and placed with the pane by its tag.
        check("the daemon is the test's own, setsid'd", daemon.parent == 1 && child.parent == found[0], "parents \(daemon.parent), \(child.parent)")
        check(
            "it carries the pane's tag",
            await eventually(10) { ProcessInspector().tree(root: login, tag: pane.processTag).flatMap(\.flattened).contains { $0.identity == identities[0] } })
        for identity in identities { ActivitySignalGate.shared.register(identity) }
        let checkouts = Array(Set(app.store.tabs.compactMap { $0.checkoutSource?.root.path }))
        let tag = pane.processTag
        let set = await Task.detached { TabSuspension.targets(login: login, tag: tag, checkouts: checkouts).map(\.identity) }.value
        check("it isn't in the pane's set", !set.contains(identities[0]) && !set.contains(identities[1]) && !set.isEmpty)
        // Left out for what it does — it serves another terminal — and its
        // child as under it: never as an app (the interpreter may run from
        // inside a bundle, Xcode's or a framework's Python.app).
        let leftOut = await Task.detached { TabSuspension.paneSet(login: login, tag: tag, checkouts: checkouts)?.leftOut ?? [] }.value
        let reasons = Dictionary(leftOut.map { ($0.identity, $0.reason) }, uniquingKeysWith: { first, _ in first })
        check(
            "left out as detached on purpose, its pty's child under it",
            reasons[identities[0]] == .detachedOnPurpose && reasons[identities[1]] == .underExcluded,
            "\(String(describing: reasons[identities[0]])), \(String(describing: reasons[identities[1]]))")
        // The set's first is the shell: stopped first.
        guard let shell = set.first?.pid else { return }

        app.suspendTab(tab)
        check("Suspend Tab stops the tab's shell", await eventually(5) { Self.isStopped(shell) })
        await pause(0.5)
        check("and leaves the daemon and its pty's process running", !Self.isStopped(found[0]) && !Self.isStopped(found[1]) && kill(found[0], 0) == 0)
        app.resumeTab(tab)
        check("Resume continues the shell", await eventually(5) { !Self.isStopped(shell) })
    }

    static func isStopped(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_stat == SSTOP
    }
}
