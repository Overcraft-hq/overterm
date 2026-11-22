#if E2E
import AppKit
import Darwin

/// Activity's stage 1 verbs and links (docs/design/activity/analysis.md,
/// 6.8 Free :N, 6.10, 6.12) over the run's own children and
/// `FakeDockerEngine`: Free through each owner's own verb, asked first —
/// a container's Stop on the fake engine, every other owner's verb
/// recorded, never reaching a forward, a tunnel, launchd, System Settings
/// or `sudo` —; the verbs that don't signal; and every link that opens the
/// page at a row. Checks say ports, pids and counts of the run's own.
extension E2ERunner {
    /// The sheet on the window: its texts and buttons.
    func activitySheet() -> (texts: [String], buttons: [String]) {
        guard let root = window.attachedSheet?.contentView else { return ([], []) }
        var texts: [String] = []
        var buttons: [String] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton, !button.title.isEmpty {
                buttons.append(button.title)
            } else if let field = view as? NSTextField, !field.stringValue.isEmpty {
                texts.append(field.stringValue)
            } else if let text = view as? NSTextView {
                texts.append(text.string)
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return (texts, buttons)
    }

    /// Answers the sheet on the window: its first button, or Cancel.
    func answerActivitySheet(_ code: NSApplication.ModalResponse) {
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: code) }
    }

    /// Asks Free of `row` through the window and waits for its sheet:
    /// what it says. The sheet is left up.
    private func activityFreeAsked(_ row: ActivityPortRow, byKey: Bool = false) async -> (texts: [String], buttons: [String])? {
        let page = app.activityPage
        if byKey {
            page.selection = [row.id]
            guard page.press("f") else { return nil }
        } else {
            app.activityFree(row)
        }
        guard await eventually(8, { self.window.attachedSheet != nil }) else { return nil }
        return activitySheet()
    }

    /// Free :N (6.8) on Listening: each owner's verb, asked, after the
    /// holder is read again.
    func activityFreeChecks(tab: Tab, held: Int, free: Int, split: Int, shared: Int, parent: pid_t, child: pid_t) async {
        let page = app.activityPage
        var steps: [ActivityPortHolder.Step] = []
        var typed: [ActivityTerminalRequest] = []
        app.activityFreeRecorder = { steps.append($0) }
        app.activityTerminalRecorder = { typed.append($0) }
        defer {
            app.activityFreeRecorder = nil
            app.activityTerminalRecorder = nil
        }
        func listener(_ port: Int, holder: pid_t? = nil) -> ActivityPortRow? {
            page.content.ports.first { $0.port == port && $0.kind == .listener && (holder == nil || $0.holder?.pid == holder) }
        }

        // A container's own row: Stop Container, asked; Cancel does nothing.
        guard let db = listener(free) else { return check("the fake container's port is listed", false, "port \(free)") }
        page.selection = [db.id]
        let verb = page.verbs(for: [db.id]) { _ in }.first { $0.key == "f" }
        check("a container's port: its Free is Stop Container…, a button", verb?.title == "Stop Container…" && verb?.place == .button && verb?.unavailable == nil)
        var words = await activityFreeAsked(db, byKey: true)
        check(
            "f asks first, naming the container",
            words?.texts.contains("Stop container “acme-db”?") == true && words?.buttons.contains("Stop Container") == true,
            "\(words?.buttons ?? [])")
        answerActivitySheet(.alertSecondButtonReturn)
        await pause(1)
        let docker = DockerModel.shared
        check("Cancel stops nothing", steps.isEmpty && docker.container("acme-db")?.State == "running")
        words = await activityFreeAsked(db, byKey: true)
        answerActivitySheet(.alertFirstButtonReturn)
        let stopped = await eventually(10) { docker.container("acme-db").map { $0.State != "running" } ?? true }
        check(
            "the button is the Docker page's Stop, on the run's fake engine", steps.first == .stopContainer(name: "acme-db", project: nil) && stopped,
            "\(steps.count) steps")
        check("and the header says what became of the port", await eventually(15) { page.freeing?.contains(":\(free)") == true }, page.freeing ?? "nothing")

        // A forward and a tunnel, by their pids: the run's own children
        // stand in, named as Overterm's forward and tunnel would be.
        let facts = page.contextFacts
        page.contextFacts = { context in
            facts(&context)
            context.forwards.append(ActivityContext.Forward(pid: child, port: UInt16(shared), target: "svc/fake-api:80", tab: nil))
            context.tunnels.append(ActivityContext.Tunnel(pid: parent, port: UInt16(split), name: "fake-staging"))
        }
        let named = await eventually(15) {
            listener(shared, holder: child)?.portOwner == .forward(target: "svc/fake-api:80")
                && listener(split, holder: parent)?.portOwner == .tunnel(name: "fake-staging")
        }
        check("a forward's and a tunnel's ports are theirs", named, "ports \(shared), \(split)")
        steps = []
        if let forward = listener(shared, holder: child) {
            words = await activityFreeAsked(forward, byKey: true)
            check(
                "a forward's Free: Stop Forward, asked", words?.texts.contains("Stop the forward to svc/fake-api:80?") == true && words?.buttons.contains("Stop Forward") == true,
                "\(words?.buttons ?? [])")
            answerActivitySheet(.alertFirstButtonReturn)
            check("its Stop Forward, recorded — nothing signalled", await eventually(5) { steps == [.stopForward(pid: child, target: "svc/fake-api:80")] })
        }
        if let tunnel = listener(split, holder: parent) {
            words = await activityFreeAsked(tunnel, byKey: true)
            check(
                "a tunnel's Free: Disconnect, asked", words?.texts.contains("Disconnect “fake-staging”?") == true && words?.buttons.contains("Disconnect") == true,
                "\(words?.buttons ?? [])")
            answerActivitySheet(.alertFirstButtonReturn)
            check("its Disconnect, recorded", await eventually(5) { steps.last == .disconnect(name: "fake-staging", pid: parent) })
        }
        page.contextFacts = facts
        _ = await eventually(10) { listener(split, holder: parent)?.portOwner == .pane }
        check("the run's processes are still running", LiveActivityKernel().process(child) != nil && LiveActivityKernel().process(parent) != nil)

        // Owners an isolated run never lists — a service, AirPlay, another
        // user's — as rows of the run's own holder: their sheets, and what
        // each would type or open, recorded.
        guard let base = listener(split, holder: parent) else { return check("the parent's listener", false) }
        var service = base
        service.portOwner = .service(LaunchdJobs.Job(label: "homebrew.mxcl.fake-db"))
        // The job's pid as launchd would say it: the variable alone names no job.
        LaunchdJobs.standInPID = { _ in nil }
        words = await activityFreeAsked(service)
        check(
            "a holder only its XPC_SERVICE_NAME calls a service: its own Free, never the service's stop",
            words != nil && words?.buttons.contains("Stop the Service") == false
                && words?.texts.joined(separator: "\n").contains("brew services") == false,
            "\(words?.buttons ?? [])")
        answerActivitySheet(.alertSecondButtonReturn)
        let holderPID = parent
        LaunchdJobs.standInPID = { label in label == "homebrew.mxcl.fake-db" ? holderPID : nil }
        defer { LaunchdJobs.standInPID = nil }
        words = await activityFreeAsked(service)
        check(
            "a brew service's Free: Stop the Service, the command it runs said",
            words?.texts.contains { $0.hasPrefix("homebrew.mxcl.fake-db holds :\(split)") } == true
                && words?.texts.joined(separator: "\n").contains("brew services stop fake-db") == true && words?.buttons.contains("Stop the Service") == true,
            "\(words?.buttons ?? [])")
        answerActivitySheet(.alertFirstButtonReturn)
        check(
            "typed and run in a new tab — recorded, launchd untouched",
            await eventually(5) { typed.last == ActivityTerminalRequest(directory: NSHomeDirectory(), command: "brew services stop fake-db", run: true) })
        var airPlay = base
        airPlay.portOwner = .known(KnownHolders.airPlay)
        words = await activityFreeAsked(airPlay)
        check(
            "AirPlay Receiver's: its switch, in System Settings",
            words?.texts.contains("AirPlay Receiver holds :\(split)") == true && words?.buttons.contains("Open System Settings") == true)
        answerActivitySheet(.alertFirstButtonReturn)
        check("opened, never changed — recorded here", await eventually(5) { steps.last == .airPlay })
        var theirs = base
        theirs.portOwner = .system(user: "_fakeuser")
        words = await activityFreeAsked(theirs)
        check(
            "another user's: the read route, asked",
            words?.texts.contains("Owned by _fakeuser: Overterm doesn't signal it") == true && words?.buttons.contains("Type It in a New Tab") == true)
        answerActivitySheet(.alertFirstButtonReturn)
        check(
            "sudo lsof typed with no Return",
            await eventually(5) { typed.last == ActivityTerminalRequest(directory: NSHomeDirectory(), command: "sudo lsof -nP -iTCP:\(split) -sTCP:LISTEN", run: false) })

        // The plan made again as the sheet opens: a holder that no longer
        // holds the port is said, never asked about.
        if let other = listener(held)?.holder, let gone = listener(shared, holder: child)?.holder {
            var moved = ActivityPortRow(
                id: "moved", port: held, proto: "tcp", address: "127.0.0.1", families: .v4, scope: .thisMac, process: "fake", holder: gone)
            moved.portOwner = .service(LaunchdJobs.Job(label: "homebrew.mxcl.fake-db"))
            let before = steps.count + typed.count
            words = await activityFreeAsked(moved)
            check(
                "a port another process holds now is said, not asked",
                words?.texts.contains { $0.hasPrefix(":\(held) is now held by") && $0.contains("pid \(other.pid)") } == true && words?.buttons == ["OK"],
                "\(words?.buttons ?? [])")
            answerActivitySheet(.alertFirstButtonReturn)
            check("and nothing is done", steps.count + typed.count == before)
        }

        // Free a Port… (6.3): View's command opens ⌘K on its item; the
        // port typed into its field selects its row and asks its Free.
        app.showActivityFreePort(nil)
        let freeItem = await eventually(5) { self.app.palette.selected?.id == "a.activity.freePort" }
        check("View ▸ Free a Port… opens ⌘K on its item, a field for the port", freeItem && app.palette.selected?.placeholders == ["port"])
        let item = app.palette.selected
        app.hidePalette()
        let before = steps.count + typed.count
        item?.perform(true, ["port": ":\(split)"])
        let freeAsked = await eventually(8) { self.window.attachedSheet != nil }
        let selectedPort = page.selection.compactMap { id in page.content.ports.first { $0.id == id }?.port }
        check(
            "typed, its row selected on Listening and its Free asked",
            freeAsked && page.section == .listening && selectedPort == [split] && activitySheet().buttons.count > 1,
            "\(selectedPort), \(activitySheet().texts.prefix(1))")
        answerActivitySheet(.alertSecondButtonReturn)
        item?.perform(true, ["port": "70000"])
        let refusedAsked = await eventually(5) { self.window.attachedSheet != nil }
        check(
            "a number that isn't a port is said, nothing asked",
            refusedAsked && activitySheet().texts.contains { $0.contains("isn't a port") } && activitySheet().buttons == ["OK"])
        answerActivitySheet(.alertFirstButtonReturn)
        check("and Cancel did nothing", steps.count + typed.count == before)

        // Refused: nothing asked.
        var bridge = base
        bridge.portOwner = .bridge
        words = await activityFreeAsked(bridge)
        check("Overterm's bridge: refused, said", words?.texts.contains("Overterm doesn't free :\(split) from here") == true && words?.buttons == ["OK"])
        answerActivitySheet(.alertFirstButtonReturn)
        page.selection = [base.id]
        let own = page.verbs(for: [base.id]) { _ in }.first { $0.key == "f" }
        check("a tab's own process: Free :N…, offered — Activity's own verb", own?.title == "Free :\(split)…" && own?.unavailable == nil, own?.title ?? "none")
        check("nothing at all reached a real owner", steps.count == 5 && typed.count == 2, "\(steps.count) steps, \(typed.count) typed")
        // The watch after the container's Stop runs one-off censuses: done
        // before the checks that want no full tick and no hold go on.
        check("the port's watch is done before the next checks", await eventually(30) { page.freeing == nil }, page.freeing ?? "")
    }

    static func debugIdentifiers(in root: NSView, prefix: String) -> [String] {
        func get(_ object: NSObject, _ key: String) -> Any? { object.responds(to: Selector(key)) ? object.value(forKey: key) : nil }
        var walked: Set<ObjectIdentifier> = []
        var found: [String] = []
        func walk(_ object: NSObject, depth: Int) {
            guard depth < 80, walked.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? NSView, view.isHiddenOrHasHiddenAncestor { return }
            if let id = get(object, "accessibilityIdentifier") as? String, id.hasPrefix(prefix) { found.append(id) }
            var children = (get(object, "accessibilityChildren") as? [Any] ?? []).compactMap { $0 as? NSObject }
            if let view = object as? NSView { children += view.subviews }
            for child in children { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return found
    }

    /// Presses the element `identifier` names in any of the app's windows
    /// — a popover's is a window of its own.
    private static func pressInAnyWindow(_ identifier: String, press: Bool = true) -> Bool {
        NSApp.windows.contains { window in
            guard window.isVisible, let root = window.contentView?.superview ?? window.contentView else { return false }
            return accessibilityPress(identifier, in: root, press: press)
        }
    }

    /// Links over the run's fake engine (6.12): a tab's container port
    /// from Tab Info's ⋯ opens Listening at the tab's checkout — where its
    /// stack is listed, a tab's own scope lists no container — and
    /// Docker's conflict box, its button pressed, at the holding tab's.
    func activityEngineLinkChecks(tab: Tab, engine: FakeDockerEngine, split: Int, parent: pid_t) async {
        let page = app.activityPage
        let docker = DockerModel.shared
        let facts = TerminalWindowController.activityTabFacts().tabs[tab.id]
        guard let checkout = facts?.checkout else { return check("the run's tab has a checkout", false) }
        let published = Self.activityFreePort()
        let web = engine.add(
            // As Compose writes it: the real path it ran in.
            name: "acme-web", project: "acme-shop", workingDir: FileTreeModel.realPath(URL(fileURLWithPath: checkout)), service: "web",
            ports: [DockerPort(IP: "127.0.0.1", PrivatePort: 80, PublicPort: published, Type: "tcp")])
        let listed = await eventually(15) { tab.containerPorts.contains { $0.port == published } }
        check(
            "the stack's port is the tab's in Tab Info", listed,
            "port \(published); containers \(docker.containers.count), projects \(docker.projects.map { "\($0.name)@\($0.workingDir ?? "-")" }), checkout \(checkout)")

        // Tab Info's port ⋯ ▸ Show in Activity: the checkout's scope.
        app.hideOverlay()
        app.showInfo(for: tab)
        let popover = await eventually(5) { self.app.infoPopover?.isShown == true }
        // Its ⋯ is a SwiftUI Menu, which an accessibility press doesn't
        // open in the run: the control found, then its Show in Activity's
        // own link (`TabInfoView.portLink`) for the row Tab Info lists.
        let control = await eventually(10) { Self.pressInAnyWindow("tabInfo.port.tcp.\(published)", press: false) }
        let listedPort = app.infoModel?.ports.first { $0.port == published && $0.proto == "tcp" }
        check("Tab Info's port row has its ⋯", popover && control && listedPort != nil, "port \(published)")
        if let listedPort {
            app.showInActivity(TabInfoView.portLink(listedPort, tab: tab.id))
        }
        let atContainer = await eventually(20) {
            self.app.store.showingOverlay == .activity && page.section == .listening
                && page.content.ports.first { page.selection.contains($0.id) }.map { $0.port == published && $0.portOwner == .container(name: "acme-web", project: "acme-shop") } == true
        }
        check(
            "a tab's container port: its row selected, at the tab's checkout", atContainer && page.scope(.listening) == .checkout(checkout),
            "port \(published)")
        page.setScope(.mac, for: .listening)

        // Docker's conflict box: a container that couldn't start on the
        // port the run's parent holds in its tab — Show Holder in Activity
        // pressed in the box.
        let clash = engine.add(name: "acme-clash", state: .created)
        engine.set(clash, state: .created, error: "driver failed programming external connectivity: Bind for 0.0.0.0:\(split) failed: port is already allocated")
        app.hideOverlay()
        app.showOverlay(.docker)
        let dockerPage = app.dockerPage
        _ = await eventually(5) { docker.container(clash) != nil }
        dockerPage.selection = [clash]
        let named = await eventually(10) {
            if case .tab(let id, _, _)? = dockerPage.session?.conflict?.holder { return id == tab.id }
            return false
        }
        check("the conflict names the run's tab", named)
        let pressed = await eventually(10) { self.app.dockerView.map { Self.accessibilityPress("docker.conflict.activity", in: $0, press: false) } == true }
        check(
            "its box offers Show Holder in Activity", pressed && app.dockerView.map { Self.accessibilityPress("docker.conflict.activity", in: $0) } == true,
            app.dockerView.map { Self.debugIdentifiers(in: $0, prefix: "docker.") }?.joined(separator: ",") ?? "no view")
        let atHolder = await eventually(20) {
            self.app.store.showingOverlay == .activity && page.section == .listening
                && page.content.ports.first { page.selection.contains($0.id) }.map { $0.port == split && $0.holder?.pid == parent } == true
        }
        check("Docker's conflict box: the holder's row, at its tab's checkout", atHolder && page.scope(.listening) == .checkout(checkout), "port \(split)")
        page.setScope(.mac, for: .listening)
        dockerPage.selection = []
        try? await docker.remove(clash, force: true)
        try? await docker.remove(web, force: true)
        check("the run's containers removed", await eventually(10) { docker.container(clash) == nil && docker.container(web) == nil })
        app.showActivityPage(.listening)
    }

    /// The verbs that don't signal (6.10) on the run's server, and the
    /// links (6.12): Tab Info's header, the tab's menu, ⌘K, a pane's pill,
    /// the overview's card and Docker's conflict box.
    func activityVerbAndLinkChecks(tab: Tab, server: ActivityPortRow?) async {
        let page = app.activityPage
        let monitor = ActivityMonitor.shared
        guard let holder = server?.holder, let port = server?.port else { return check("the server's row", false) }
        var typed: [ActivityTerminalRequest] = []
        var revealed: [String] = []
        var copied: [[String]] = []
        app.activityTerminalRecorder = { typed.append($0) }
        let reveal = page.actions.reveal
        page.actions.reveal = { revealed.append($0) }
        defer {
            app.activityTerminalRecorder = nil
            page.actions.reveal = reveal
        }
        _ = page.press("1")
        page.selection = [holder.id]
        let read = await eventually(15) { page.selectedFolder != nil }
        check("the selection read in depth: its folder, a tick or two later", read && monitor.demand.focus.contains(holder))
        let folder = page.selectedFolder ?? "-"
        check("e: a terminal in its folder", page.press("e") && typed.last == ActivityTerminalRequest(directory: folder))
        check("⌥r: its folder in Finder", page.pressOption("r") && revealed.last == folder)
        check("s: sample, its report to the tab", page.press("s") && typed.last?.command == "sample \(holder.pid) 5 -file /dev/stdout")
        let verbs = page.verbs(for: [holder.id]) { copied.append($0) }
        verbs.first { $0.title == "Open Files in a Tab" }?.perform()
        check("Open Files in a Tab: lsof of it alone", typed.last == ActivityTerminalRequest(directory: NSHomeDirectory(), command: "lsof -nP -p \(holder.pid)"))
        verbs.first { $0.title == "Copy PID" }?.perform()
        let command = page.content.processes.first { $0.identity == holder }?.command
        verbs.first { $0.title == "Copy Command" }?.perform()
        check("Copy PID and Copy Command, the command as masked", copied == [["\(holder.pid)"], [command ?? "-"]] && command != nil)
        page.selection = []
        check("the focus given back with the selection", await eventually(5) { !monitor.demand.focus.contains(holder) })

        // e for real: a tab in that folder, where the island rule puts it.
        app.activityTerminalRecorder = nil
        page.selection = [holder.id]
        _ = await eventually(15) { page.selectedFolder != nil }
        let before = Set(app.store.tabs.map(\.id))
        check("e opens a new tab", page.press("e") && app.store.showingOverlay != .activity)
        let opened = app.store.tabs.first { !before.contains($0.id) }
        let there = await eventually(15) { opened?.workingDirectory.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == URL(fileURLWithPath: folder).standardizedFileURL.path }
        check("its shell in the server's folder", there)
        if let opened { app.closeTabsWithoutAsking([opened]) }
        app.store.select(tab)
        app.activityTerminalRecorder = { typed.append($0) }

        // Links. The tab's menu: Processes, scoped to the tab.
        func shownAgain() async -> Bool { await eventually(15) { self.app.store.showingOverlay == .activity && page.hasRead } }
        if app.store.showingOverlay == .activity { app.hideOverlay() }
        let item = app.menu(for: tab).items.first { $0.title == "Show in Activity" }
        if let item, let action = item.action { _ = (item.target as AnyObject?)?.perform(action) }
        var shown = await shownAgain()
        check("the tab's menu: Show in Activity, the page in the tab's scope", item != nil && shown && page.scope(.processes) == .tab(tab.id))
        page.setScope(.mac, for: .processes)

        // Tab Info's header.
        app.hideOverlay()
        app.showInfo(for: tab)
        let popover = await eventually(5) { self.app.infoPopover?.isShown == true }
        let pressed = popover && app.infoPopover?.contentViewController.map { Self.accessibilityPress("tabInfo.showInActivity", in: $0.view) } == true
        shown = await shownAgain()
        check("Tab Info's header: Show in Activity", pressed && shown && page.scope(.processes) == .tab(tab.id))
        let closed = await eventually(5) { self.app.infoPopover?.isShown != true }
        check("and the popover closed", closed)
        page.setScope(.mac, for: .processes)

        // A process: Tab Info's row, its menu's Show in Activity — a
        // SwiftUI context menu, which an accessibility Show Menu opens in
        // the run only now and then (and once left tracking): the row
        // found, then its item's own link (`TabInfoView.processLink`).
        page.following = false
        app.hideOverlay()
        app.showInfo(for: tab)
        let infoNode = await eventually(10) { self.app.infoModel?.processes.flatMap(\.flattened).contains { $0.identity == holder } == true }
        if let node = app.infoModel?.processes.flatMap(\.flattened).first(where: { $0.identity == holder }) {
            app.showInActivity(TabInfoView.processLink(node, tab: tab.id))
        }
        let selected = await eventually(10) { page.selection == [holder.id] && page.detail?.row.identity == holder }
        check(
            "Tab Info's process row: Show in Activity, it selected and followed",
            infoNode && selected && page.following && page.section == .processes)
        page.setScope(.mac, for: .processes)

        // ⌘K's Activity: This Tab.
        app.hideOverlay()
        app.activityPaletteItems().first { $0.id == "a.activity.tab" }?.perform(false, [:])
        shown = await shownAgain()
        check("⌘K's Activity: This Tab", shown && page.scope(.processes) == .tab(tab.id))
        page.setScope(.mac, for: .processes)

        // A pane's pill, pressed, then its popover's Show in Activity:
        // Listening, the port's row selected, at the tab's checkout.
        let pill = await eventually(15) { tab.ports.contains { $0.port == port } }
        app.hideOverlay()
        let pillShown = await eventually(10) { Self.pressInAnyWindow("pill.tcp.\(port)", press: false) }
        let pillOpened = pillShown && Self.pressInAnyWindow("pill.tcp.\(port)")
        let offered = await eventually(10) { Self.pressInAnyWindow("pill.showInActivity", press: false) }
        let linked = offered && Self.pressInAnyWindow("pill.showInActivity")
        let atPort = await eventually(15) {
            page.section == .listening && page.content.ports.first { page.selection.contains($0.id) }.map { $0.port == port && $0.holder == holder } == true
        }
        let scope = TerminalWindowController.activityTabFacts().tabs[tab.id]?.checkout.map(ActivityScope.checkout) ?? .tab(tab.id)
        check(
            "a pane's pill: its popover's Show in Activity, the port's row selected at the tab's checkout",
            pill && pillOpened && linked && atPort && page.scope(.listening) == scope, "port \(port)")
        page.setScope(.mac, for: .listening)

        // The overview's card: its agent's row.
        app.hideOverlay()
        app.showAgentOverview(nil)
        let carded = await eventually(15) { self.app.overview.cards.first { $0.id == tab.id }?.agentProcess != nil }
        let agent = app.overview.cards.first { $0.id == tab.id }?.agentProcess
        // Its numbers (6.12): the agent and what it started, from the census.
        let usage = app.overview.cards.first { $0.id == tab.id }?.usage
        let usageShown = await eventually(5) { self.app.overviewView.map { Self.accessibilityPress("overview.usage", in: $0, press: false) } == true }
        check("an Agents card: its agent's memory and CPU, from the census", usage.map { $0.footprint > 0 } == true && usageShown)
        let cardPressed = carded && app.overviewView.map { Self.accessibilityPress("overview.showInActivity", in: $0) } == true
        let atAgent = await eventually(15) { page.section == .processes && agent.map { page.selection == [$0.id] } == true }
        check("an Agents card: Show in Activity, its agent selected", cardPressed && atAgent, "agent pid \(agent?.pid ?? -1)")
        check("the overview put away", app.overviewView?.isHidden == true)
        page.setScope(.mac, for: .processes)
        page.following = false
        page.selection = []
        _ = page.press("2")
    }
}
#endif
