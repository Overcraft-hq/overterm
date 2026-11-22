#if E2E
import AppKit
import Darwin

/// Stage 4's listeners (docs/design/activity/analysis.md, 6.8, D-25,
/// D-32) over the run's own children and stand-ins — never the real
/// nettop, never this Mac's launchd folders, never a real kubectl or ssh:
/// a stand-in nettop whose answer the scenario writes, checked against the
/// run's own listeners and blind without them; launchd's listener named
/// from a fixture plist, its Free refused; a `kubectl port-forward` and an
/// `ssh -L` typed in the tab, each saying its target; a unix-socket
/// listener behind its setting; the detail's Files (`l`). Ports, pids and
/// the run's own paths only.
extension E2ERunner {
    func activityListenerSourceChecks(tab: Tab) async {
        let page = app.activityPage
        let pane = tab.terminal
        check("2 is Listening", page.press("2") && page.section == .listening)
        let folder = out("activity-sources")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let numbersFile = folder.appendingPathComponent("numbers")
        let held = folder.appendingPathComponent("acme-held.txt")
        let socketPath = "/tmp/ot-e2e-acme-\(UUID().uuidString.prefix(6)).sock"
        let server = folder.appendingPathComponent("acme-sources.py")
        try? "acme\n".write(to: held, atomically: true, encoding: .utf8)
        try? """
        import os, socket, sys, time
        out, path, held = sys.argv[1], sys.argv[2], sys.argv[3]
        unix = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        unix.bind(path)
        unix.listen()
        kept = open(held)
        open(out + ".tmp", "w").write(f"{os.getpid()}")
        os.rename(out + ".tmp", out)
        time.sleep(120)
        """.write(to: server, atomically: true, encoding: .utf8)
        // The stand-ins: a script named as the tool, listening on the port
        // its words give — argv as the real one's would be.
        let standIn = """
            #!/usr/bin/env python3
            import socket, sys, time
            words = sys.argv[1:]
            if sys.argv[0].endswith("kubectl"):
                port = int([w for w in words if ":" in w and not w.startswith("-")][0].split(":")[0])
            else:
                port = int(words[words.index("-L") + 1].split(":")[0])
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.bind(("127.0.0.1", port))
            s.listen()
            time.sleep(120)
            """
        let kubectl = folder.appendingPathComponent("kubectl")
        let ssh = folder.appendingPathComponent("ssh")
        for tool in [kubectl, ssh] {
            try? standIn.write(to: tool, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        }
        let forwardPort = Self.activityFreePort()
        let tunnelPort = Self.activityFreePort()
        pane.insertText(
            "python3 \(server.path) \(numbersFile.path) \(socketPath) \(held.path) & "
                + "\(kubectl.path) port-forward -n acme --context fake-dev svc/acme-web \(forwardPort):80 & "
                + "\(ssh.path) -N -L \(tunnelPort):db.acme.internal:5432 bastion.acme &")
        pane.pressReturn()
        let started = await eventually(15) { FileManager.default.fileExists(atPath: numbersFile.path) }
        let holder = pid_t((try? String(contentsOf: numbersFile, encoding: .utf8)) ?? "") ?? 0
        defer { unlink(socketPath) }
        guard started, holder > 0 else { return check("the run's own listeners start", false) }

        // Typed forwards (6.8 rule 6): their targets from their argv.
        let typed = await eventually(15) {
            page.content.ports.first { $0.port == forwardPort }?.target != nil && page.content.ports.first { $0.port == tunnelPort }?.target != nil
        }
        let forward = page.content.ports.first { $0.port == forwardPort }
        let tunnel = page.content.ports.first { $0.port == tunnelPort }
        check(
            "a kubectl port-forward typed in the tab says its target",
            typed && forward?.target == "port-forward → svc/acme-web:80 · namespace acme, context fake-dev" && forward?.tab == tab.id
                && forward?.ownerText.contains("port-forward → svc/acme-web:80") == true,
            "port \(forwardPort): \(forward?.target ?? "none")")
        check(
            "an ssh -L typed in the tab says where it goes, and through which host",
            tunnel?.target == "ssh -L → db.acme.internal:5432 via bastion.acme" && tunnel?.tab == tab.id, "port \(tunnelPort)")

        // Unix-socket listeners (D-32): off by default, on behind their setting.
        check("no unix-socket rows by default", !page.content.ports.contains { $0.kind == .unix })
        Settings.shared.set("activity.unixSockets", .bool(true))
        page.settingsChanged()
        let unixShown = await eventually(15) { page.content.ports.contains { $0.kind == .unix && $0.address == socketPath } }
        let unixRow = page.content.ports.first { $0.kind == .unix && $0.address == socketPath }
        check(
            "on, the run's unix listener is a row: its path, its holder, its tab, no URL, no Free",
            unixShown && unixRow?.holder?.pid == holder && unixRow?.tab == tab.id && unixRow?.url == nil
                && unixRow.map { ActivityPortHolder.step(for: $0) == nil } == true)
        Settings.shared.set("activity.unixSockets", nil)
        page.settingsChanged()
        check("off again, it goes", await eventually(15) { !page.content.ports.contains { $0.kind == .unix } })

        // Every user's listeners (D-25), through a stand-in nettop and a
        // fixture launchd folder: the real ones are never read here.
        check(
            "in a test run, other users' listeners aren't read without a stand-in",
            page.content.summary.others == .unavailable("not read in a test run") && !page.readOtherListenersNow())
        let launchdPort = Self.activityFreePort()
        let plists = folder.appendingPathComponent("launchd", isDirectory: true)
        try? FileManager.default.createDirectory(at: plists, withIntermediateDirectories: true)
        let plist: [String: Any] = ["Label": "com.acme.fake-proxy", "Sockets": ["Listeners": ["SockNodeName": "localhost", "SockServiceName": "\(launchdPort)"]]]
        try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plists.appendingPathComponent("com.acme.fake-proxy.plist"))
        LaunchdSockets.standIn = [LaunchdSockets.Folder(url: plists, domain: .system)]
        let answer = folder.appendingPathComponent("nettop.txt")
        let nettop = folder.appendingPathComponent("nettop")
        try? "#!/bin/sh\n[ \"$*\" = \"-L 1 -n -x -J state\" ] || exit 3\ncat \"\(answer.path)\"\n".write(to: nettop, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nettop.path)
        page.othersReader.standIn = nettop
        defer {
            page.othersReader.standIn = nil
            LaunchdSockets.standIn = nil
        }
        // The run's own TCP listeners, as nettop would name them, and launchd's.
        func write(own: Bool) {
            var text = ",state,\n"
            if own {
                for row in page.content.listeners where row.kind == .listener && row.proto == "tcp" {
                    guard let pid = row.holder?.pid else { continue }
                    text += "acme.\(pid),,\ntcp4 127.0.0.1:\(row.port)<->*:*,Listen,\n"
                }
            }
            text += "launchd.1,,\ntcp4 127.0.0.1:\(launchdPort)<->*:*,Listen,\ntcp6 ::1.\(launchdPort)<->*.*,Listen,\n"
            try? text.write(to: answer, atomically: true, encoding: .utf8)
        }
        write(own: true)
        check("a read asked now starts", page.readOtherListenersNow())
        let named = await eventually(15) { page.content.ports.contains { $0.port == launchdPort && $0.holder?.pid == 1 } }
        let launchd = page.content.ports.first { $0.port == launchdPort }
        check(
            "who holds the port: launchd, for the job its plist names — checked against the run's own",
            named && launchd?.ownerText == "launchd — com.acme.fake-proxy" && launchd?.familyWords == "v4 + v6"
                && { if case .checked = page.content.summary.others { true } else { false } }(),
            "port \(launchdPort)")
        let refused = launchd.flatMap(ActivityPortHolder.unavailable)
        check("its Free is refused, the job named", refused?.contains("com.acme.fake-proxy") == true, refused ?? "not refused")
        let said = await eventually(5) {
            self.app.pages.view(.activity).flatMap { Self.accessibilityElement("activity.listeningNote", in: $0) }?.text.contains("checked against yours") == true
        }
        check("and the note says it was checked", said)
        page.setFilter("owner:system")
        check("owner:system lists it", await eventually(5) { page.content.ports.contains { $0.port == launchdPort } })
        page.setFilter("")

        write(own: false)
        check("a read lacking the run's own listeners", page.readOtherListenersNow())
        let blind = await eventually(15) { if case .blind = page.content.summary.others { true } else { false } }
        check(
            "is blind: unknown, its rows not shown", blind && !page.content.ports.contains { $0.port == launchdPort },
            "\(page.content.summary.others)")
        Settings.shared.set("activity.otherListeners", .bool(false))
        page.settingsChanged()
        check("off, nothing of it is said or read", await eventually(10) { page.content.summary.others == .off } && !page.readOtherListenersNow())
        Settings.shared.set("activity.otherListeners", nil)
        page.settingsChanged()

        // Files (`l`): the server's open file and its unix socket, read when asked.
        check("1 is Processes", page.press("1") && page.section == .processes)
        let listed = await eventually(15) { page.content.processes.contains { $0.identity.pid == holder } }
        if let row = page.content.processes.first(where: { $0.identity.pid == holder }) { page.selection = [row.id] }
        let detailed = await eventually(10) { page.detail?.row.identity.pid == holder }
        check("its row is selected and shown", listed && detailed)
        check("l reads its open files", page.press("l") && page.showsFiles)
        let real =
            realpath(held.path, nil).map { pointer -> String in
                defer { free(pointer) }
                return String(cString: pointer)
            } ?? held.path
        let read = await eventually(10) { page.openFiles?.entries.contains { $0.text == real } == true }
        let entries = page.openFiles?.entries ?? []
        check(
            "the file it holds open, and its unix socket listening",
            read && entries.contains { $0.text == "unix \(socketPath), listening" }, "\(entries.count) entries")
        check("l again hides them", page.press("l") && !page.showsFiles)
    }
}
#endif
