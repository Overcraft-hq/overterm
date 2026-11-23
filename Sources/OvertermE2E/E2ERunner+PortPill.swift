#if E2E
import AppKit

/// A pane header's port pill (docs/design/activity/analysis.md, 6.12;
/// 2.4 items 4 and 5): its Open and its Free…, through the window's own
/// actions — the ones the pill's popover calls.
extension E2ERunner {
    /// Open goes where Settings ▸ Browser says (`openLink`): recorded, so
    /// neither the browser column nor a real browser opens.
    package func pillOpenChecks(_ port: ListeningPort, in tab: Tab) async {
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

    /// The words of the sheet on the window: its texts and its buttons.
    private func pillSheetWords() -> (texts: [String], buttons: [String]) {
        guard let root = window.attachedSheet?.contentView else { return ([], []) }
        var texts: [String] = []
        var buttons: [String] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton, !button.title.isEmpty {
                buttons.append(button.title)
            } else if let field = view as? NSTextField, !field.stringValue.isEmpty {
                texts.append(field.stringValue)
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return (texts, buttons)
    }

    private func answerPillSheet(_ code: NSApplication.ModalResponse) { if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: code) } }

    /// Whether the process the census named is still that process, alive.
    private func stillRunning(_ identity: ActivityProcessID?) -> Bool {
        guard let identity, let now = LiveActivityKernel().process(identity.pid) else { return false }
        return now.identity == identity && !now.isZombie
    }

    /// Free… on a pill (6.12, D-10): asked every time; Cancel leaves the
    /// test's own server running, the button stops it, and the pill says
    /// the port is free. A background job is stopped by its token; the
    /// pane's foreground job is interrupted — ⌃C typed into the pane. Only
    /// this run's own servers, in this run's panes: the isolated run's gate
    /// refuses anything else.
    package func pillFreeChecks(_ port: ListeningPort, in tab: Tab) async {
        let pane = tab.terminal
        let pid = port.identity?.pid ?? -1
        app.freePort(port, in: pane)
        let asked = await eventually(8) { self.window.attachedSheet != nil }
        var words = pillSheetWords()
        check(
            "Free… on a background job's pill asks first, naming it",
            asked && words.texts.contains { $0.hasPrefix("Stop “") && $0.hasSuffix("(pid \(pid))?") } && words.buttons.contains("Stop Process"),
            "\(words.texts.prefix(1)) \(words.buttons)")
        check(
            "with the command it equals", words.texts.contains { $0.contains("kill -TERM \(pid)") } || words.texts.joined().contains("kill -TERM \(pid)"),
            "\(words.texts.count) texts")
        answerPillSheet(.alertSecondButtonReturn)
        await pause(1.5)
        check(
            "Cancel leaves it running, its pill still there",
            window.attachedSheet == nil && stillRunning(port.identity) && tab.ports(of: pane).contains { $0.port == port.port },
            "alive \(stillRunning(port.identity))")

        app.freePort(port, in: pane)
        _ = await eventually(8) { self.window.attachedSheet != nil }
        answerPillSheet(.alertFirstButtonReturn)
        check("the button stops it", await eventually(10) { !self.stillRunning(port.identity) })
        check("and its pill goes", await eventually(10) { !tab.ports(of: pane).contains { $0.port == port.port } }, "\(tab.ports.map(\.port))")
        check(
            "saying the port is free",
            await eventually(15) { tab.portFreeing(of: pane).contains { $0.port == port.port && $0.state == .free } },
            "\(tab.portFreeing.map(\.label))")

        // The pane's foreground job: ⌃C typed into the pane.
        let file = out("foreground.port")
        let script = out("foreground.py")
        try? """
        import socket, time
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        s.listen()
        open("\(file.path)", "w").write(str(s.getsockname()[1]))
        time.sleep(60)
        """.write(to: script, atomically: true, encoding: .utf8)
        pane.insertText("python3 \(script.path)")
        pane.pressReturn()
        let started = await eventually(10) { FileManager.default.fileExists(atPath: file.path) }
        let number = (try? String(contentsOf: file, encoding: .utf8)).flatMap { Int($0) } ?? -1
        let listed = await eventually(10) { tab.ports(of: pane).contains { $0.port == number } }
        guard started, listed, let foreground = tab.ports(of: pane).first(where: { $0.port == number }) else {
            return check("a foreground server shows on its pill", false, "\(tab.ports.map(\.port)) want \(number)")
        }
        app.freePort(foreground, in: pane)
        _ = await eventually(8) { self.window.attachedSheet != nil }
        words = pillSheetWords()
        check(
            "Free… on the pane's foreground job asks to interrupt it",
            words.texts.contains { $0.hasPrefix("Interrupt “") } && words.buttons.contains("Interrupt"), "\(words.texts.prefix(1)) \(words.buttons)")
        answerPillSheet(.alertSecondButtonReturn)
        await pause(1)
        check("Cancel leaves it running", stillRunning(foreground.identity))
        app.freePort(foreground, in: pane)
        _ = await eventually(8) { self.window.attachedSheet != nil }
        answerPillSheet(.alertFirstButtonReturn)
        check("⌃C typed into the pane ends it", await eventually(10) { !self.stillRunning(foreground.identity) })
        check(
            "and its pill goes", await eventually(10) { !tab.ports(of: pane).contains { $0.port == number } }, "\(tab.ports.map(\.port))")
        // The watch ends before what follows: it reads one-off censuses,
        // which a minimized window's check counts as reads.
        check(
            "saying that port is free too",
            await eventually(15) { tab.portFreeing(of: pane).contains { $0.port == number && $0.state == .free } },
            "\(tab.portFreeing.map(\.label))")
        // Through ProcessSignals, as every signal is: the run's gate holds
        // for its own cleanup too, by the identity the census listed.
        if stillRunning(foreground.identity), let identity = foreground.identity {
            _ = ProcessSignals().send(.term, to: ActivitySignalTarget(identity, path: nil), alone: true)
        }
    }

    /// A container's port: Stop Container, now asked (6.12) — Cancel
    /// leaves it running, the button stops it through the engine (the
    /// fake's). Started again after, for what follows.
    package func containerFreeChecks(_ port: ListeningPort, in tab: Tab, web: String, fake: FakeDockerEngine) async {
        let docker = DockerModel.shared
        app.freePort(port, in: tab.terminal)
        _ = await eventually(5) { self.window.attachedSheet != nil }
        let words = pillSheetWords()
        check(
            "a container's port asks before its Stop",
            words.texts.contains("Stop container “ot-shop-web-1”?") && words.buttons.contains("Stop Container"), "\(words.texts.prefix(1)) \(words.buttons)")
        answerPillSheet(.alertSecondButtonReturn)
        await pause(1)
        check("Cancel leaves it running", docker.container(web)?.state == .running, "\(String(describing: docker.container(web)?.state))")
        app.freePort(port, in: tab.terminal)
        _ = await eventually(5) { self.window.attachedSheet != nil }
        answerPillSheet(.alertFirstButtonReturn)
        check("Stop Container stops it", await eventually(5) { docker.container(web)?.state == .exited }, "\(String(describing: docker.container(web)?.state))")
        fake.set(web, state: .running)
        _ = await eventually(5) { docker.container(web)?.state == .running }
        tab.activity.seen()
    }

    /// A Kubernetes forward's port: Stop Forward, now asked (6.12) — Cancel
    /// leaves the forward running; with `confirm`, the button stops it and
    /// its pill goes, the port watched until it is free.
    package func forwardFreeChecks(_ port: ListeningPort, in tab: Tab, confirm: Bool) async {
        guard let id = port.forward?.id else { return check("a forward's pill names its forward", false) }
        let forwards = KubeForwards.shared
        app.freePort(port, in: tab.terminal)
        let asked = await eventually(5) { self.window.attachedSheet != nil }
        let words = pillSheetWords()
        check(
            "a forward's pill asks before its Stop",
            asked && words.texts.contains { $0.hasPrefix("Stop the forward to ") } && words.buttons.contains("Stop Forward"),
            "\(words.texts.prefix(1)) \(words.buttons)")
        answerPillSheet(.alertSecondButtonReturn)
        await pause(1)
        check(
            "Cancel leaves the forward running, its pill there",
            window.attachedSheet == nil && forwards.forward(id)?.isForwarding == true && tab.forwardPorts.contains { $0.forward?.id == id },
            forwards.forward(id)?.state.text ?? "gone")
        guard confirm else { return }
        app.freePort(port, in: tab.terminal)
        _ = await eventually(5) { self.window.attachedSheet != nil }
        answerPillSheet(.alertFirstButtonReturn)
        check("Stop Forward stops it", await eventually(10) { forwards.forward(id) == nil }, forwards.forward(id)?.state.text ?? "gone")
        check("and its pill goes", await eventually(10) { !tab.forwardPorts.contains { $0.forward?.id == id } }, "\(tab.forwardPorts.map(\.port))")
        check(
            "saying the port is free",
            await eventually(15) { tab.portFreeing(of: tab.terminal).contains { $0.port == port.port && $0.state == .free } },
            "\(tab.portFreeing.map(\.label))")
    }
}
#endif
