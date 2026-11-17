import AppKit

/// Left Behind (docs/design/activity/analysis.md, 6.9, 10.3 items 12 and
/// 15) over the run's own children only: a stand-in `claude` that starts a
/// detached server and exits — the tab's note, the Inbox, Left Behind's
/// section and the overview's count —; a tab closed over two survivors, one
/// ticked and stopped by its identity, one kept; and the next launch's
/// Resume offer for what an earlier run's Activity stopped (D-29). Every
/// detached child ends itself once this part writes its stop file. Checks
/// say pids, ports and counts — the run's own.
extension E2ERunner {
    func activityLeftBehindChecks() async {
        let page = app.activityPage
        let kernel = LiveActivityKernel()
        let gate = ActivitySignalGate.shared
        let stop = out("left-behind.stop")
        defer { try? Data().write(to: stop) }
        let began = LeftBehind.micros(Date()) - 1_000_000
        /// The run's own child whose pid `file` holds: started since this part began.
        func own(_ file: URL) -> ActivityProcessID? {
            guard let text = try? String(contentsOf: file, encoding: .utf8), let pid = pid_t(text.split(whereSeparator: \.isWhitespace).last ?? ""),
                let process = kernel.process(pid), process.identity.start >= began
            else { return nil }
            return process.identity
        }
        func alive(_ identity: ActivityProcessID) -> Bool { kernel.process(identity.pid).map { $0.identity == identity && !$0.isZombie } ?? false }
        /// A python that forks away from its terminal (setsid), listens on
        /// a port the OS picks, writes "<port> <pid>" and ends at the stop file.
        func detached(_ file: URL) -> String {
            "python3 -c 'import os,socket,time\nif os.fork(): os._exit(0)\nos.setsid()\ns=socket.socket(); s.bind((\"127.0.0.1\",0)); s.listen()\n"
                + "open(\"\(file.path)\",\"w\").write(\"%d %d\" % (s.getsockname()[1], os.getpid()))\n"
                + "[time.sleep(0.2) for _ in range(900) if not os.path.exists(\"\(stop.path)\")]'"
        }

        // 1. An agent's run that leaves a server (6.9, D-17): a stand-in
        // claude starts it and exits a few ticks later.
        app.newTab(nil)
        guard let agentTab = app.store.selected else { return check("a tab for the stand-in agent", false) }
        check("the agent's tab's shell is up", await eventually(15) { agentTab.terminal.shellReported })
        let serverFile = out("left-behind-server")
        agentTab.terminal.insertText("(exec -a claude /bin/sh -c '\(detached(serverFile).replacingOccurrences(of: "'", with: "'\\''")) ; /bin/sleep 6')")
        agentTab.terminal.pressReturn()
        let started = await eventually(15) { own(serverFile) != nil }
        let server = own(serverFile)
        let port = (try? String(contentsOf: serverFile, encoding: .utf8))?.split(separator: " ").first.flatMap { Int($0) } ?? -1
        check("the stand-in agent's tool starts a detached server", started && port > 0, "port \(port)")
        let ledger = LeftBehindLedger.shared
        check("the census follows the agent's run", await eventually(10) { ledger.runs.running[agentTab.terminal.processTag] != nil })
        let noted = await eventually(20) { agentTab.activity.fromLeftBehind }
        check(
            "once it exits, the tab's note says what it left: done, never failed",
            noted && agentTab.activity.mark == .done && agentTab.activity.note?.hasPrefix("Claude finished — left ") == true
                && agentTab.activity.note?.contains(":\(port)") == true, "\(agentTab.activity.note?.contains(":\(port)") == true ? "port named" : "port unnamed")")
        app.refreshInbox()
        check("the Inbox's card offers Show", app.inbox.entries.contains { $0.id == agentTab.id && $0.leftBehind })
        check("the overview's count", server.map { _ in ledger.leftCount(of: agentTab.id, in: ActivityMonitor.shared.snapshot) == 1 } ?? false)
        app.showLeftBehind(of: agentTab.id)
        check("Show opens Left Behind, the tab's", app.store.showingOverlay == .activity && page.section == .leftBehind)
        let listed = await eventually(15) {
            page.content.leftBehind.contains { item in
                guard case .process(let row) = item else { return false }
                return row.identity == server && row.owner?.rule == 8 && row.owner?.reason?.hasPrefix("left by Claude in “") == true
            }
        }
        check("Left Behind lists the server, with its reason: left by Claude", listed, "\(page.content.leftBehind.count) rows")
        check("3 is Left Behind", page.press("1") && page.press("3") && page.section == .leftBehind)
        page.setScope(.mac, for: .leftBehind)
        app.toggleActivityPage(nil)

        // 2. The close sheet (D-16): two survivors, one ticked and stopped
        // by its identity, the other unticked and so kept.
        app.newTab(nil)
        guard let closing = app.store.selected else { return check("a tab to close", false) }
        check("the tab's shell is up", await eventually(15) { closing.terminal.shellReported })
        let tickedFile = out("left-behind-ticked")
        let keptFile = out("left-behind-kept")
        closing.terminal.insertText("\(detached(tickedFile)) ; \(detached(keptFile))")
        closing.terminal.pressReturn()
        _ = await eventually(15) { own(tickedFile) != nil && own(keptFile) != nil }
        guard let ticked = own(tickedFile), let kept = own(keptFile) else { return check("two survivors start", false) }
        gate.register(ticked)
        defer { gate.unregister(ticked) }
        let tag = closing.terminal.processTag
        check(
            "the census places both with the tab: they carry its tag",
            await eventually(15) {
                let tagged = ActivityMonitor.shared.snapshot?.pane(tag)?.tagged ?? []
                return tagged.contains(ticked) && tagged.contains(kept)
            })
        app.closeTab(closing)
        let asked = await eventually(10) { self.window.attachedSheet != nil }
        let sheet = activitySheet()
        let texts = sheet.texts.joined(separator: " ")
        check(
            "closing names what will keep running, a checkbox each, all unticked",
            asked && texts.contains("Will keep running: ") && sheet.buttons.contains { $0.hasPrefix("Also stop ") && $0.contains("(pid \(ticked.pid))") }
                && sheet.buttons.contains { $0.hasPrefix("Also stop ") && $0.contains("(pid \(kept.pid))") } && survivorBoxes().allSatisfy { $0.state == .off },
            "\(sheet.buttons.count) buttons")
        survivorBoxes().first { $0.title.contains("(pid \(ticked.pid))") }?.state = .on
        answerActivitySheet(.alertFirstButtonReturn)
        check("the tab closes", await eventually(5) { !self.app.store.tabs.contains { $0 === closing } })
        check("the ticked one is stopped by its identity", await eventually(10) { !alive(ticked) })
        check("the unticked one runs on, kept", alive(kept) && ledger.kept.contains(kept))
        check("and the closed pane is retired, with its tag", ledger.retired.contains { $0.pane.tag == tag })
        app.toggleActivityPage(nil)
        _ = await eventually(15) { page.hasRead }
        let keptRow = await eventually(15) {
            page.content.processes.contains { $0.identity == kept && $0.owner?.kept == true && $0.owner?.reason?.hasPrefix("kept running — left by “") == true }
        }
        check("it shows as kept running when its tab closed — never Left Behind", keptRow)
        check("nor in Left Behind's section", !page.content.leftBehind.contains { if case .process(let row) = $0 { row.identity == kept } else { false } })
        app.toggleActivityPage(nil)

        // 3. After a crash (D-29): Activity stops one of the run's own and
        // the writer puts it in the file, beside the kept one; the next
        // launch reads that file and offers to resume it.
        let sleeperFile = out("left-behind-sleeper")
        agentTab.terminal.insertText("/bin/sleep 163 & echo $! > \(sleeperFile.path)")
        agentTab.terminal.pressReturn()
        _ = await eventually(10) { own(sleeperFile) != nil }
        guard let sleeper = own(sleeperFile) else { return check("a process to stop", false) }
        gate.register(sleeper)
        defer { gate.unregister(sleeper) }
        let target = ActivitySignalTarget(sleeper, path: kernel.path(of: sleeper.pid))
        let sent = await PaneAgent.offMain { ActivityHeld.stopTree([target], signals: ProcessSignals()) }
        check("Activity's Suspend stops it", sent.first?.answer == .sent(pinned: true) && kernel.process(sleeper.pid)?.isStopped == true)
        let held = ActivityHeld.shared
        held.suspended(root: target, name: "sleep", members: [target], names: [sleeper: "sleep"])
        let persistence = ActivityPersistence.shared
        persistence.flush()
        let written = try? Data(contentsOf: persistence.url)
        let record = written.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [[String: Any]]] }
        func holds(_ key: String, _ identity: ActivityProcessID) -> Bool {
            record?[key]?.contains { ($0["pid"] as? NSNumber)?.int32Value == identity.pid && ($0["start"] as? NSNumber)?.uint64Value == identity.start }
                ?? false
        }
        check("the writer put the Suspend and the Keep in the file", holds("stopped", sleeper) && holds("kept", kept))
        let keys = Set(record?.values.flatMap { $0.flatMap(\.keys) } ?? [])
        let text = written.map { String(decoding: $0, as: UTF8.self) } ?? ""
        var info = stat()
        let mode = lstat(persistence.url.path, &info) == 0 ? info.st_mode & 0o777 : 0
        check(
            "the file names pid and start only, 0600",
            Set(record?.keys.map { $0 } ?? []).isSubset(of: ["kept", "stopped"]) && keys == ["pid", "start"] && !text.contains("sleep")
                && !text.contains("python") && mode == 0o600, "mode \(String(mode, radix: 8))")
        // The crash: the app's memory goes, the file stays as written.
        held.resumed([sleeper])
        persistence.flush()
        if let written { try? written.write(to: persistence.url) }
        await app.activityRestoreAtLaunch()
        let offered = await eventually(10) { self.window.attachedSheet != nil }
        let resume = activitySheet()
        check(
            "the next launch offers to resume it",
            offered && resume.texts.contains { $0.hasPrefix("Activity stopped “") && $0.hasSuffix("” before Overterm last quit") }
                && resume.buttons == ["Resume", "Leave Stopped"], "\(resume.buttons)")
        answerActivitySheet(.alertFirstButtonReturn)
        check("Resume continues it, by its identity", await eventually(10) { kernel.process(sleeper.pid)?.isStopped == false })
        persistence.flush()
        check("what still runs and was kept stays in the file", ActivityPersisted.load(from: persistence.url).keptIdentities.contains(kept))
        ActivityPersisted().save(to: persistence.url)
    }

    /// The close sheet's checkboxes.
    private func survivorBoxes() -> [NSButton] {
        guard let root = window.attachedSheet?.contentView else { return [] }
        var boxes: [NSButton] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton, button.title.hasPrefix("Also stop ") { boxes.append(button) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return boxes
    }
}
