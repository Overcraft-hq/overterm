import AppKit
import SwiftUI

/// A pane pill's Stop… (`PortStop`; the Activity analysis, 2.4 item 5),
/// through the pill's own action — its header's `killPort` — on the `info`
/// scenario's server: asked first, naming the process, its pid and the
/// port; Cancel sends nothing; a listing gone stale is sent nothing, and
/// said; confirmed, the server stops and its pill goes. Only processes of
/// the scenario's own are signalled, each by its pid and start time.
extension E2ERunner {
    /// Open goes where Settings ▸ Browser says (`openLink`): recorded, so
    /// neither the browser column nor a real browser opens.
    func pillOpenChecks(_ port: ListeningPort, in tab: Tab) async {
        var opened: [(URL, Bool)] = []
        app.linkRecorder = { opened.append(($0, $1)) }
        defer {
            app.linkRecorder = nil
            Settings.shared.set("browser.openLinks", nil)
            Settings.shared.set("browser.enabled", nil)
        }
        let actions = app.paneHeaderActions(for: tab)
        Settings.shared.set("browser.openLinks", .string("none"))
        actions.openPort(port)
        check(
            "a pill's Open goes through openLink: the default browser, as Settings ▸ Browser says",
            opened.count == 1 && opened.first?.0 == port.url && opened.first?.1 == false, "\(opened.map { "\($0.0) \($0.1)" })")
        opened = []
        // The browser on, its default, whatever the run set: off, every
        // policy is "none", and this check would say nothing the first didn't.
        Settings.shared.set("browser.enabled", .bool(true))
        Settings.shared.set("browser.openLinks", .string("local"))
        actions.openPort(port)
        check(
            "and the browser column when it says local links open here",
            opened.count == 1 && opened.first?.0 == port.url && opened.first?.1 == true, "\(opened.map { "\($0.0) \($0.1)" })")
    }

    /// One of the scenario's own listeners (`pillListener`).
    struct PillListener {
        let process: Process
        let pid: pid_t
        let start: UInt64
        let port: Int
    }

    /// Listens on 127.0.0.1 — the port its second argument asks, 0 for any
    /// —, writes the port to the file its first names, then sleeps 30 s at most.
    static let pillListenerScript = """
        use Socket;
        my ($file, $want) = @ARGV;
        socket(my $s, PF_INET, SOCK_STREAM, 0) or die;
        setsockopt($s, SOL_SOCKET, SO_REUSEADDR, 1);
        bind($s, sockaddr_in($want, inet_aton("127.0.0.1"))) or die;
        listen($s, 5) or die;
        my ($port) = sockaddr_in(getsockname($s));
        open(my $f, ">", "$file.tmp") or die; print $f "$port\\n"; close $f; rename("$file.tmp", $file);
        sleep 30;
        """

    /// `port` is the server the scenario started in `tab`'s pane; the pill
    /// shows it from the window's own listing of the pane.
    func portPillStop(in tab: Tab, port: Int) async {
        let pane = tab.terminal
        guard let header = app.host(of: tab)?.header(of: pane) as? NSHostingView<PaneHeaderView> else {
            return check("the pane has its header", false)
        }
        let pill = await eventually(12) { tab.ports(of: pane).contains { $0.port == port } }
        guard pill, let listed = tab.ports(of: pane).first(where: { $0.port == port }), let started = listed.start else {
            return check("the pill's port carries its process's start time", false, "\(tab.ports(of: pane).count) ports on the pane")
        }
        check("the pill's port carries its process's start time", ListeningPorts.start(of: listed.pid) == started)
        func press(_ port: ListeningPort) { header.rootView.actions.killPort(port) }
        func said() -> String { sheetTexts().joined(separator: "\n") }
        func asking() -> Bool { Self.find(NSButton.self, in: window.attachedSheet?.contentView) { $0.title == "Stop Process" } != nil }
        func answer(_ response: NSApplication.ModalResponse) async {
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: response) }
            _ = await eventually(3) { self.window.attachedSheet == nil }
        }
        func running(_ pid: pid_t, _ start: UInt64) -> Bool { ListeningPorts.start(of: pid) == start }

        // Asked first, naming what it stops; Cancel sends nothing.
        press(listed)
        let asked = await eventually(10) { asking() }
        check("the pill's Stop… asks first", asked)
        let question = said()
        let named = [listed.process, "pid \(listed.pid)", ":\(port)", "SIGTERM", "server.py"].filter { !question.contains($0) }
        check("naming the process, its pid, the port, its command line and SIGTERM", asked && named.isEmpty, "\(named.count) of 5 missing")
        await answer(.alertSecondButtonReturn)
        await pause(0.5)
        check("Cancel sends nothing", running(listed.pid, started) && window.attachedSheet == nil)

        // A listing gone stale: nothing asked, nothing sent, and said why —
        // its pid another process's (the server ended, the pid reused), a
        // port it doesn't hold, a start time never read.
        let other = port == 65535 ? port - 1 : port + 1
        let stale: [(ListeningPort, String, String)] = [
            (ListeningPort(pid: listed.pid, start: started - 1, process: listed.process, port: port, address: listed.address), "has exited", "its pid another process's"),
            (ListeningPort(pid: listed.pid, start: started, process: listed.process, port: other, address: listed.address), "no longer holds :\(other)", "a port it doesn't hold"),
            (ListeningPort(pid: listed.pid, process: listed.process, port: port, address: listed.address), "can't be stopped from here", "its start time unread"),
        ]
        for (stalePort, words, what) in stale {
            press(stalePort)
            let told = await eventually(10) { said().contains(words) }
            check(
                "\(what): nothing asked, nothing sent, and said", told && said().contains("Nothing was sent") && !asking() && running(listed.pid, started))
            await answer(.alertFirstButtonReturn)
        }

        // Confirmed: SIGTERM to it, and it stops; its pill goes.
        press(listed)
        let askedAgain = await eventually(10) { asking() }
        check("asked again", askedAgain)
        if askedAgain { await answer(.alertFirstButtonReturn) }
        let stopped = await eventually(10) { !running(listed.pid, started) }
        check("confirmed, the server stops", askedAgain && stopped && window.attachedSheet == nil)
        check("and its pill goes", await eventually(15) { !tab.ports(of: pane).contains { $0.port == port } })

        // Replaced while asked — the server ended, another took its port —
        // nothing is sent, and said: two listeners of the scenario's own,
        // the first ended while the question is up, the second on its port.
        guard let first = await pillListener("pill-first", on: 0) else { return check("a listener of the scenario's own", false) }
        defer { endNow(first) }
        let firstPorts = await ListeningPorts.of([first.pid])
        guard let firstListed = firstPorts.first(where: { $0.port == first.port }), firstListed.start == first.start else {
            return check("listed with its start time", false, "\(firstPorts.count) ports")
        }
        press(firstListed)
        let askedFirst = await eventually(10) { asking() && said().contains("pid \(first.pid)") }
        check("a listener's Stop… asks", askedFirst)
        let ended = await end(first)
        var second: PillListener?
        if ended { second = await pillListener("pill-second", on: first.port) }
        defer { if let second { endNow(second) } }
        check("while it is asked, it ends and another takes its port", askedFirst && ended && second != nil)
        await answer(.alertFirstButtonReturn)
        let refused = await eventually(10) { said().contains("has exited") && said().contains("Nothing was sent") }
        check("confirmed, nothing is sent, and said", refused && second.map { running($0.pid, $0.start) && $0.process.isRunning } == true)
        await answer(.alertFirstButtonReturn)
        if let second { check("the one on its port is left running, and ends when told", await end(second)) }
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
    }

    /// A listener of the scenario's own (`pillListenerScript`, perl) on
    /// `port`, 0 for any: once it listens, its process, pid, start time and port.
    private func pillListener(_ name: String, on port: Int) async -> PillListener? {
        let file = scratch.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.pillListenerScript, file.path, String(port)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil, let start = ListeningPorts.start(of: process.processIdentifier) else { return nil }
        var bound = 0
        _ = await eventually(10) {
            bound = (try? String(contentsOf: file, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
            return bound > 0 || !process.isRunning
        }
        let listener = PillListener(process: process, pid: process.processIdentifier, start: start, port: bound)
        guard bound > 0 else {
            endNow(listener)
            return nil
        }
        return listener
    }

    /// Ends one of the scenario's own listeners — its pid, while it has its
    /// start time — and waits until it has.
    private func end(_ listener: PillListener) async -> Bool {
        endNow(listener)
        return await eventually(5) { !listener.process.isRunning }
    }

    private func endNow(_ listener: PillListener) {
        if listener.process.isRunning, ListeningPorts.start(of: listener.pid) == listener.start { kill(listener.pid, SIGTERM) }
    }
}
