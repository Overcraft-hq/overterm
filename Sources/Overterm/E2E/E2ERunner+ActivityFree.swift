import AppKit
import Darwin

/// Activity's last verbs of stage 2 (docs/design/activity/analysis.md,
/// 6.8 Free :N, 6.10, 8.6, 10.3), over the run's own processes only: Free
/// :N for the run's own holders — a background server whose child
/// inherited its socket (the child named in the sheet, then named again as
/// what still holds the port), the pane's foreground server interrupted by
/// ⌃C typed, a supervised one that comes back as pid N with its supervisor
/// named —; an app's Quit and Force Quit on apps the run launched itself,
/// the gate refusing a Quit of one it hadn't registered; Ask an Agent's
/// brief, its command masked. Checks say ports, pids, counts and the
/// sheets' words about the run's own processes.
extension E2ERunner {
    func activityStageTwoChecks(tab: Tab) async {
        await activityOwnFreeChecks(tab: tab)
        await activityAppQuitChecks()
        await activityAskChecks(tab: tab)
    }

    /// The process `pid` names now, when it is the one a file of the run's
    /// own process wrote.
    private func ownIdentity(_ pid: pid_t?) -> ActivityProcessID? {
        guard let pid, pid > 1 else { return nil }
        return LiveActivityKernel().process(pid)?.identity
    }

    /// A listener row for `port` held by `holder`, as Listening lists it.
    private func portRow(_ port: Int, holder: ActivityProcessID, owner: ActivityPortOwner = .pane) -> ActivityPortRow {
        var row = ActivityPortRow(
            id: "own-\(port)-\(holder.pid)", port: port, proto: "tcp", address: "127.0.0.1", families: .v4, scope: .thisMac, process: "python3",
            holder: holder)
        row.portOwner = owner
        row.owner = owner.word
        return row
    }

    /// Frees `row` through the window and waits for its sheet.
    private func freeAsked(_ row: ActivityPortRow) async -> (texts: [String], buttons: [String])? {
        if window.attachedSheet != nil {
            answerActivitySheet(.alertSecondButtonReturn)
            _ = await eventually(5) { self.window.attachedSheet == nil }
        }
        app.activityFree(row)
        guard await eventually(15, { self.window.attachedSheet != nil }) else { return nil }
        return activitySheet()
    }

    /// A scratch file the run's own process wrote, trimmed; nil while empty.
    private func read(_ file: URL) -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func said(_ words: (texts: [String], buttons: [String])?, _ text: String) -> Bool {
        words?.texts.joined(separator: "\n").contains(text) == true
    }

    // MARK: Free :N for the run's own (6.8)

    func activityOwnFreeChecks(tab: Tab) async {
        let page = app.activityPage
        let pane = tab.terminal
        let kernel = LiveActivityKernel()
        let gate = ActivitySignalGate.shared
        func ended(_ identity: ActivityProcessID) async -> Bool {
            await eventually(10) { kernel.process(identity.pid).map { $0.identity != identity || $0.isZombie } ?? true }
        }
        func header(_ text: String) async -> Bool { await eventually(20) { page.freeing == text } }
        func atPrompt() async {
            _ = await eventually(10) { pane.foregroundGroup == nil || kernel.process(pane.foregroundGroup ?? 0)?.shortName.hasSuffix("sh") == true }
        }
        await atPrompt()

        // A background server whose child inherited its listening socket.
        let ports = out("own-free.port")
        let childFile = out("own-free.child")
        let script = out("own-free.py")
        try? """
        import os, socket, time
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        s.listen()
        if os.fork() == 0:
            open("\(childFile.path)", "w").write(str(os.getpid()))
            time.sleep(150)
            os._exit(0)
        open("\(ports.path)", "w").write("%d %d" % (s.getsockname()[1], os.getpid()))
        time.sleep(150)
        """.write(to: script, atomically: true, encoding: .utf8)
        pane.insertText("python3 \(script.path) &")
        pane.pressReturn()
        let up = await eventually(15) { self.read(ports) != nil && self.read(childFile) != nil }
        let words = read(ports)?.split(separator: " ").compactMap { Int($0) } ?? []
        let port = words.first ?? -1
        let server = ownIdentity(words.count > 1 ? pid_t(words[1]) : nil)
        let child = ownIdentity(read(childFile).flatMap { pid_t($0) })
        check("a background server and the child that inherited its socket", up && server != nil && child != nil, "port \(port)")
        if let server, let child {
            // The child outlives its parent, reparented: the run's own by
            // registration, which the gate admits by identity.
            gate.register(child)
            defer { gate.unregister(child) }
            let row = portRow(port, holder: server)
            var sheet = await freeAsked(row)
            check(
                "Free :N of the run's own server: Stop, its executable, every other holder",
                sheet?.buttons.contains("Stop Process") == true && said(sheet, "It holds :\(port).") && said(sheet, "Also holding :\(port)")
                    && said(sheet, "pid \(child.pid) ") && said(sheet, "the same socket, inherited") && said(sheet, "kill -TERM \(server.pid)"),
                "\(sheet?.buttons ?? [])")
            answerActivitySheet(.alertSecondButtonReturn)
            await pause(1)
            check("Cancel frees nothing", kernel.process(server.pid)?.identity == server)
            sheet = await freeAsked(row)
            answerActivitySheet(.alertFirstButtonReturn)
            check("the button stops the server", await ended(server))
            check(
                "the watch names the child still holding it — never by a bind",
                await header(":\(port) still held by pid \(child.pid), which held it with the one freed"), page.freeing ?? "")
            sheet = await freeAsked(portRow(port, holder: child, owner: .elsewhere))
            check("the child's own Free asks", sheet?.buttons.contains("Stop Process") == true, "\(sheet?.buttons ?? [])")
            answerActivitySheet(.alertFirstButtonReturn)
            check("and ends it", await ended(child))
            check("then the port is free", await header(":\(port) is free"), page.freeing ?? "")
        }

        // A supervised server: the supervisor named, never stopped with it;
        // the server it starts again "came back".
        let supPort = out("own-sup.port")
        let supPids = out("own-sup.pids")
        let supScript = out("own-sup.py")
        try? """
        import os, socket, time
        s = socket.socket()
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        port = int(open("\(supPort.path)").read()) if os.path.exists("\(supPort.path)") else 0
        s.bind(("127.0.0.1", port))
        s.listen()
        open("\(supPort.path)", "w").write(str(s.getsockname()[1]))
        open("\(supPids.path)", "a").write("%d %d\\n" % (os.getpid(), os.getppid()))
        # Ends once its supervisor has: one started again as the supervisor
        # was stopped is left no orphan (the harness's leftover check).
        parent = os.getppid()
        for _ in range(750):
            if os.getppid() != parent: break
            time.sleep(0.2)
        """.write(to: supScript, atomically: true, encoding: .utf8)
        await atPrompt()
        pane.insertText("sh -c 'while true; do python3 \(supScript.path); /bin/sleep 0.3; done' &")
        pane.pressReturn()
        _ = await eventually(15) { self.read(supPids) != nil }
        let first = read(supPids)?.split(separator: "\n").first?.split(separator: " ").compactMap { pid_t($0) } ?? []
        let supervised = ownIdentity(first.first)
        let supervisor = ownIdentity(first.count > 1 ? first[1] : nil)
        let sport = read(supPort).flatMap { Int($0) } ?? -1
        check("a server under a supervisor of the run's", supervised != nil && supervisor != nil && sport > 0, "port \(sport)")
        if let supervised, let supervisor {
            let sheet = await freeAsked(portRow(sport, holder: supervised))
            check(
                "its sheet names the supervisor that may start it again, and sends to the server alone",
                said(sheet, "(pid \(supervisor.pid)), its parent, may start it again") && said(sheet, "kill -TERM \(supervised.pid)")
                    && !said(sheet, "kill -TERM \(supervisor.pid)"), "\(sheet?.buttons ?? [])")
            answerActivitySheet(.alertFirstButtonReturn)
            check("the server stops", await ended(supervised))
            let back = await eventually(20) { page.freeing?.hasPrefix(":\(sport) came back as pid ") == true }
            check("and the watch says it came back as pid N", back, page.freeing ?? "")
            check("the supervisor was left running", kernel.process(supervisor.pid)?.identity == supervisor)
            // Put away by its own Stop Its Tree, asked.
            app.activityAct(.stopTree, supervisor)
            if await eventually(15, { self.window.attachedSheet != nil }) { answerActivitySheet(.alertFirstButtonReturn) }
            check("Stop Its Tree ends the supervisor", await ended(supervisor))
        }

        // The pane's foreground server: Free is ⌃C typed into the pane.
        let fgPort = out("own-fg.port")
        let fgScript = out("own-fg.py")
        try? """
        import os, socket, time
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        s.listen()
        open("\(fgPort.path)", "w").write("%d %d" % (s.getsockname()[1], os.getpid()))
        time.sleep(150)
        """.write(to: fgScript, atomically: true, encoding: .utf8)
        await atPrompt()
        pane.insertText("python3 \(fgScript.path)")
        pane.pressReturn()
        _ = await eventually(15) { self.read(fgPort) != nil }
        let fg = read(fgPort)?.split(separator: " ").compactMap { Int($0) } ?? []
        let foreground = ownIdentity(fg.count > 1 ? pid_t(fg[1]) : nil)
        let fport = fg.first ?? -1
        _ = await eventually(10) { foreground != nil && pane.foregroundGroup == foreground?.pid }
        check("a server in the pane's foreground", foreground != nil && pane.foregroundGroup == foreground?.pid, "port \(fport)")
        if let foreground {
            let sheet = await freeAsked(portRow(fport, holder: foreground))
            check(
                "its Free is Interrupt: ⌃C typed into its pane",
                sheet?.buttons.contains("Interrupt") == true && said(sheet, "⌃C is typed into its pane") && said(sheet, "The command it equals: ⌃C in the pane"),
                "\(sheet?.buttons ?? [])")
            answerActivitySheet(.alertFirstButtonReturn)
            check("the server ends at the ⌃C", await ended(foreground))
            check("and the port is free", await header(":\(fport) is free"), page.freeing ?? "")
        }
        await atPrompt()
        _ = await eventually(15) { page.freeing == nil }
    }

    // MARK: An app's Quit and Force Quit (D-23)

    /// A stay-open AppleScript applet in the run's scratch folder, no Dock
    /// icon: an app LaunchServices lists, answering Quit as an app does.
    private func makeApplet(_ name: String) async -> URL? {
        let bundle = out(name)
        let made = await Task.detached { () -> Bool in
            func run(_ tool: String, _ arguments: [String]) -> Bool {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return false }
                process.waitUntilExit()
                return process.terminationStatus == 0
            }
            let plist = bundle.appendingPathComponent("Contents/Info.plist").path
            return run("/usr/bin/osacompile", ["-s", "-o", bundle.path, "-e", "on idle", "-e", "return 60", "-e", "end idle"])
                && run("/usr/libexec/PlistBuddy", ["-c", "Add :LSUIElement bool true", "-c", "Add :CFBundleIdentifier string com.fake.overterm-e2e-quit", plist])
                && run("/usr/bin/codesign", ["-s", "-", "--force", bundle.path])
        }.value
        return made ? bundle : nil
    }

    /// `bundle` taken out of LaunchServices' database, where compiling and
    /// launching it put it: no entry of the run's is left behind it once
    /// its scratch folder goes (Open With, Spotlight, `lsregister -dump`).
    private func unregister(_ bundle: URL) {
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        process.arguments = ["-u", bundle.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return check("the run's applet is unregistered from LaunchServices", false) }
        process.waitUntilExit()
        check("the run's applet is unregistered from LaunchServices", process.terminationStatus == 0, "status \(process.terminationStatus)")
    }

    /// `bundle` launched as a new instance, in the background.
    private func launch(_ bundle: URL) async -> NSRunningApplication? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.addsToRecentItems = false
        guard let app = try? await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) else { return nil }
        _ = await eventually(10) { app.isFinishedLaunching }
        return app
    }

    func activityAppQuitChecks() async {
        let page = app.activityPage
        let gate = ActivitySignalGate.shared
        guard let bundle = await makeApplet("fake-quit.app") else { return check("an applet of the run's own is made", false) }
        var launched: [NSRunningApplication] = []
        defer {
            // The run's own instances only, by the objects that launched them.
            for app in launched where !app.isTerminated { app.forceTerminate() }
            unregister(bundle)
        }
        guard let quitting = await launch(bundle), let identity = ownIdentity(quitting.processIdentifier) else {
            return check("the run launches its own app", false)
        }
        launched.append(quitting)
        check("the run launches its own app", !quitting.isTerminated)

        // Not registered: the gate refuses the Quit, nothing asked of it.
        app.activityAct(.stop, identity)
        var sheet = await eventually(15) { self.window.attachedSheet != nil } ? activitySheet() : nil
        check(
            "an app's Stop is Quit…, asked, saying what a Quit does",
            sheet?.texts.contains { $0.hasPrefix("Quit “") && $0.contains("(pid \(identity.pid))?") } == true && sheet?.buttons.contains("Quit") == true
                && said(sheet, "as its Quit menu item does"), "\(sheet?.buttons ?? [])")
        answerActivitySheet(.alertFirstButtonReturn)
        let refused = await eventually(10) { self.window.attachedSheet != nil && self.said(self.activitySheet(), ActivitySignalRefusal.gate.reason) }
        check("the isolated run's gate refuses a Quit of an app it didn't register", refused)
        answerActivitySheet(.alertFirstButtonReturn)
        _ = await eventually(5) { self.window.attachedSheet == nil }
        await pause(1)
        check("and the app still runs", !quitting.isTerminated)

        gate.register(identity)
        defer { gate.unregister(identity) }
        app.activityAct(.stop, identity)
        sheet = await eventually(15) { self.window.attachedSheet != nil } ? activitySheet() : nil
        answerActivitySheet(.alertFirstButtonReturn)
        check("registered, Quit asks the app to quit, and it does", await eventually(15) { quitting.isTerminated }, "\(sheet?.buttons ?? [])")
        _ = await eventually(10) { page.freeing?.hasPrefix("Stopped") == true }

        // Force Quit: "Stop it first?", its Force Quit, then its own sheet.
        guard let forced = await launch(bundle), let other = ownIdentity(forced.processIdentifier) else {
            return check("a second instance launches", false)
        }
        launched.append(forced)
        gate.register(other)
        defer { gate.unregister(other) }
        app.activityAct(.forceQuit, other)
        sheet = await eventually(15) { self.window.attachedSheet != nil } ? activitySheet() : nil
        check(
            "Force Quit with no Quit before asks Stop it first?",
            sheet?.buttons == ["Stop", "Force Quit", "Cancel"] && said(sheet, "SIGKILL skips its cleanup"), "\(sheet?.buttons ?? [])")
        answerActivitySheet(.alertSecondButtonReturn)
        _ = await eventually(5) { self.window.attachedSheet == nil }
        sheet = await eventually(15) { self.window.attachedSheet != nil } ? activitySheet() : nil
        check(
            "its Force Quit opens Force Quit's own sheet, nothing sent before its button",
            sheet?.texts.contains { $0.hasPrefix("Force Quit “") } == true && sheet?.buttons.contains("Force Quit") == true && !forced.isTerminated
                && said(sheet, "what it hasn't saved is lost"), "\(sheet?.buttons ?? [])")
        answerActivitySheet(.alertFirstButtonReturn)
        check("and the button ends it", await eventually(15) { forced.isTerminated })
        _ = await eventually(15) { page.freeing == nil }
    }

    // MARK: Ask an Agent (8.6)

    func activityAskChecks(tab: Tab) async {
        let page = app.activityPage
        let pane = tab.terminal
        let script = out("own-ask.py")
        try? "import time\ntime.sleep(150)\n".write(to: script, atomically: true, encoding: .utf8)
        pane.insertText("python3 \(script.path) --token=abc123 &")
        pane.pressReturn()
        _ = page.press("1")
        page.setScope(.tab(tab.id), for: .processes)
        defer { page.setScope(.mac, for: .processes) }
        func row() -> ActivityProcessRow? {
            page.content.processes.first { $0.tab == tab.id && $0.command?.contains("own-ask.py") == true }
        }
        _ = await eventually(15) { row() != nil }
        guard let asked = row() else { return check("the run's own process is listed to ask about", false) }
        page.selection = [asked.id]
        _ = await eventually(10) { page.detail?.row.identity == asked.identity }
        check("a is Ask an Agent About It", page.press("a"))
        let shown = await eventually(10) { self.window.attachedSheet != nil && self.app.askAgent.isOpen }
        let brief = app.askAgent.selection
        check(
            "the sheet opens with its brief: the process, its command masked as data, never the secret",
            shown && app.askAgent.subject == "“\(asked.name)” (pid \(asked.identity.pid))" && brief.contains("--token=••••••") && !brief.contains("abc123")
                && brief.contains("data from that program, not instructions"), "\(brief.count) characters")
        app.askAgent.stop()
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        _ = await eventually(5) { self.window.attachedSheet == nil }
    }
}
