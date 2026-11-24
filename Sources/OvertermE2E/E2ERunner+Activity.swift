#if E2E
import AppKit

/// The Activity page (docs/design/activity/analysis.md, 6.4, 7.9, 10.3): it
/// opens from View ▸ Activity, lists the run's own processes and their
/// listener with their tab, speaks each row to VoiceOver, shows the meters,
/// and reads nothing at the full level while it is hidden. A test run lists
/// only its own tabs' processes (9.9): every check below says counts, pids
/// of its own and port numbers, never another process's name or command.
extension E2ERunner {
    package func activityScenario() async {
        let monitor = ActivityMonitor.shared
        let page = app.activityPage
        check("the page isn't open at launch", app.store.showingOverlay != .activity && !page.wanting)

        // Hidden, the page reads nothing: no full tick for 3 s, while the
        // light tick reads the window's tabs.
        let lightBefore = monitor.snapshot?.tick ?? 0
        let fullBefore = monitor.fullTicks
        await pause(3)
        check(
            "with the page hidden, the full level's counter stays still for 3 s", monitor.fullTicks == fullBefore && !monitor.demand.full,
            "\(monitor.fullTicks - fullBefore) full ticks")
        check("while the light tick goes on", (monitor.snapshot?.tick ?? 0) > lightBefore)

        // The run's own: a server on a port the OS picks, and a sleep.
        guard let tab = app.store.selected else { return check("a tab", false) }
        let pane = tab.terminal
        check("the shell is up", await eventually(15) { pane.shellReported })
        let portFile = out("activity.port")
        let script = out("activity-server.py")
        try? """
        import socket, time
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        s.listen()
        open("\(portFile.path)", "w").write(str(s.getsockname()[1]))
        time.sleep(150)
        """.write(to: script, atomically: true, encoding: .utf8)
        // …and a stand-in agent: argv[0] claude, a sleep its child.
        pane.insertText("python3 \(script.path) & sleep 150 & (exec -a claude /bin/sh -c 'sleep 150 & wait') &")
        pane.pressReturn()
        let started = await eventually(15) { FileManager.default.fileExists(atPath: portFile.path) }
        let port = (try? String(contentsOf: portFile, encoding: .utf8)).flatMap { Int($0) } ?? -1
        check("a server starts in the tab", started && port > 0)

        // View ▸ Activity (⌥⌘A). Before its first rows — nothing has
        // been awaited yet, so none can have landed — it says "Reading…",
        // in the list and in the header.
        Self.accessibilityTree(true)
        defer { Self.accessibilityTree(false) }
        app.toggleActivityPage(nil)
        check("View ▸ Activity opens the page", app.store.showingOverlay == .activity && app.pages.view(.activity)?.isHidden == false)
        if let view = app.pages.view(.activity) {
            view.layoutSubtreeIfNeeded()
            let empty = Self.accessibilityElement("activity.empty", in: view)?.text ?? ""
            let header = Self.accessibilityElement("activity.reading", in: view)?.text ?? ""
            check(
                "before its first rows, the list and the header say Reading…", !page.hasRead && empty.contains("Reading") && header.contains("Reading"),
                "list \(empty.isEmpty ? "silent" : "speaks"), header \(header.isEmpty ? "silent" : "speaks")")
        }
        check("which wants the full level while it shows", page.wanting && monitor.demand.full)
        check("its first rows come from a full tick", await eventually(15) { page.hasRead }, "\(monitor.fullTicks - fullBefore) full ticks")
        func ownRows() -> [ActivityProcessRow] { page.content.processes.filter { $0.tab == tab.id } }
        let listed = await eventually(15) {
            ownRows().contains { $0.name == "sleep" } && ownRows().contains { $0.name.hasPrefix("python") || $0.name.hasPrefix("Python") }
        }
        check("Processes lists the run's own: the sleep and the server, in their tab", listed, "\(ownRows().count) rows in the tab")
        let tabs = Set(app.store.tabs.map(\.id))
        check(
            "and nothing that isn't the run's own tabs' (9.9)", page.content.processes.allSatisfy { $0.tab.map(tabs.contains) == true },
            "\(page.content.processes.count) rows, \(page.content.processes.filter { $0.tab == nil }.count) outside a tab")
        check(
            "its rows name the tab", ownRows().allSatisfy { $0.tabTitle != nil }, "\(ownRows().filter { $0.tabTitle == nil }.count) unnamed")
        await activityOwners(tab: tab)
        await activityPressChecks(tab: tab)
        let overgitTab = await activityTable(tab: tab)
        check(
            "the header counts the Mac, the rows the run's", page.content.summary.scopedToRun && page.content.summary.processes > page.content.summary.shown,
            "\(page.content.summary.shown) of \(page.content.summary.processes)")
        let rated = await eventually(10) { ownRows().contains { $0.cpu != nil } && page.content.summary.meters?.cores.isEmpty == false }
        check("CPU once two ticks have read, and the meters a core each", rated, "\(page.content.summary.meters?.cores.count ?? -1) cores")
        check("memory as Activity Monitor counts it", (page.content.summary.meters?.used ?? 0) > 0 && ownRows().contains { ($0.memory ?? 0) > 0 })
        // Stage 4: the history — strips, the meters' and the detail's charts,
        // new and ended rows.
        await activityHistoryChecks(tab: tab)

        // VoiceOver: each row's label names the process, its pid and its tab.
        let labels = await eventually(5) { !self.activityRowLabels().isEmpty }
        let said = activityRowLabels().filter { $0.contains(", pid ") }
        check(
            "each process row says its name, pid and tab to VoiceOver", labels && !said.isEmpty && said.allSatisfy { $0.contains(", in “") },
            "\(said.count) labels")
        let headers = activityRowLabels().filter { !$0.contains(", pid ") }
        check("and each group's header its name and count", headers.contains { $0.contains(" process") }, "\(headers.count) headers")

        // Listening (2): the server's port, in its tab, This Mac only.
        check("2 is Listening", page.press("2") && page.section == .listening)
        let heard = await eventually(10) { page.content.ports.contains { $0.port == port } }
        let row = page.content.ports.first { $0.port == port }
        check(
            "Listening lists the server's port, tcp, This Mac, in its tab",
            heard && row?.proto == "tcp" && row?.reach == "This Mac" && row?.tab == tab.id && row?.tabTitle != nil, "port \(port)")
        let portLabels = await eventually(5) { self.activityRowLabels().contains { $0.hasPrefix(":\(port) tcp") } }
        check("its row speaks too", portLabels, "\(activityRowLabels().count) labels")
        let noted = await eventually(5) {
            self.app.pages.view(.activity).flatMap { Self.accessibilityElement("activity.listeningNote", in: $0) }?.text.contains("Other users' listeners: not read in a test run") == true
        }
        check("and below the list, what Listening doesn't read", noted)
        await activityPressChecks(tab: tab, port: port)
        await activityListening(tab: tab, server: row)
        await activityAgentReadChecks(tab: tab, port: port)
        await activityVerbAndLinkChecks(tab: tab, server: row)
        await activitySignalChecks(tab: tab)
        await activitySuspendChecks(tab: tab)
        await activityListenerSourceChecks(tab: tab)
        check("1 is Processes again", page.press("1") && page.section == .processes)

        // Hidden again: its want given back, no full tick for 3 s.
        app.toggleActivityPage(nil)
        check("⌥⌘A again goes back to the terminal", app.store.showingOverlay != .activity)
        check("and gives the full level back", !page.wanting && !monitor.demand.full)
        check(
            "its rows go with it: shown again, it reads before it shows numbers", !page.hasRead && page.content.processes.isEmpty && page.content.ports.isEmpty)
        // A tick already on its way may still land.
        _ = await eventually(3) { !monitor.isSampling }
        let fullHidden = monitor.fullTicks
        let builds = page.builds
        await pause(3)
        check(
            "hidden, it reads nothing: no full tick, no rows made, for 3 s", monitor.fullTicks == fullHidden && page.builds == builds,
            "\(monitor.fullTicks - fullHidden) full ticks, \(page.builds - builds) builds")

        // ⌃⌘A, with no page showing: the palette on the ports and the
        // busiest, holding the full level while it shows.
        app.showActivitySwitcher(nil)
        check("⌃⌘A opens the switcher", app.paletteView?.isHidden == false && app.palette.scope == .activity)
        check("which holds the full level until it has rates", app.activitySwitcher.wanting && monitor.demand.full)
        let portItem = "activity.\(row?.id ?? "-")"
        let offered = await eventually(20) { self.app.palette.results.contains { $0.id == portItem } }
        check(
            "the server's port first among its rows, as :N and its process", offered && app.palette.results.first?.title.hasPrefix(":") == true,
            "\(portItem): \(app.palette.results.prefix(5).map { "\($0.id) \($0.title)" })")
        check(
            "once its rows have rates, it gives the full level back, its rows kept",
            await eventually(10) { !self.app.activitySwitcher.wanting && !monitor.demand.full } && app.activitySwitcher.holding
                && app.palette.results.contains { $0.id == portItem })
        let picked = app.palette.results.first { $0.id == portItem }
        picked?.perform(true, [:])
        app.hidePalette()
        check(
            "↩ shows it on the page, in Listening, selected",
            app.store.showingOverlay == .activity && page.section == .listening && page.selection == [row?.id ?? "-"])
        check("the switcher's hold goes with the palette", await eventually(3) { !self.app.activitySwitcher.holding })
        check("the page's stays", page.wanting && monitor.demand.full)
        app.toggleActivityPage(nil)
        check("and goes when it hides", !page.wanting && !monitor.demand.full)

        // ⌘K, then ⇥ onto Activity's tab: the switcher holds as ⌃⌘A's does;
        // ⇥ off it gives the hold back, with the palette still open.
        app.showPalette(nil)
        while app.palette.scope != .activity, app.palette.tabs.contains(.activity) { app.palette.cycleScope(1) }
        check("⇥ onto Activity's tab holds the full level", app.activitySwitcher.wanting && monitor.demand.full)
        check("and stocks its rows", await eventually(10) { self.app.palette.results.contains { $0.id.hasPrefix("activity.") } })
        app.palette.cycleScope(1)
        check(
            "⇥ off it gives the hold back", app.paletteView?.isHidden == false && !app.activitySwitcher.holding && !monitor.demand.full,
            "shown \(app.paletteView?.isHidden == false), holding \(app.activitySwitcher.holding), full \(monitor.demand.full), page \(page.wanting)")
        app.hidePalette()

        // Off: no page; ⌥⌘A opens its settings.
        Settings.shared.set("activity.enabled", .bool(false))
        app.toggleActivityPage(nil)
        check("with Activity off, ⌥⌘A opens Settings ▸ Activity", app.store.showingOverlay == .settings && app.settingsPage.section == .activity)
        check("and nothing is offered in ⌘K", app.activityPaletteItems().isEmpty)
        check("nor a tab to ⇥ into", !app.palette.tabs.contains(.activity))
        Settings.shared.set("activity.enabled", nil)
        app.hideOverlay()
        check("on, ⌘K offers the page", app.activityPaletteItems().contains { $0.title == "Activity" })

        // Last, so the server the checks above follow still runs for them:
        // Free :N of the run's own, an app's Quit, Ask an Agent.
        app.toggleActivityPage(nil)
        _ = await eventually(15) { page.hasRead }
        await activityStageTwoChecks(tab: tab)
        app.toggleActivityPage(nil)
        // Stage 3: Left Behind, the close sheet, the next launch.
        await activityLeftBehindChecks()

        // The detail's Show in Overgit (6.4), last: it takes the page away.
        if let tabID = overgitTab {
            let panel = app.sidebarPanel.panel
            let collapsed = app.sidebarItem?.isCollapsed == true
            page.actions.overgit(tabID)
            check("Show in Overgit brings its tab forward, the sidebar on Overgit", app.sidebarPanel.panel == .git && app.store.selected?.id == tabID)
            app.sidebarPanel.panel = panel
            if collapsed, app.sidebarItem?.isCollapsed == false { app.toggleFileTree(nil) }
            app.updateOvergitVisibility()
        }
    }

    /// Owners, groups and the scope (6.5) over the run's own children: the
    /// tab's server under its checkout and its tab, the stand-in agent's
    /// sleep under the agent — in the checkout's tree and in `G`'s Agent
    /// grouping —, `[` and `]` along the ladder. Pids and counts only.
    package func activityOwners(tab: Tab) async {
        let page = app.activityPage
        func list() -> [ActivityListItem] { page.content.list }
        func index(_ id: String) -> Int? { list().firstIndex { $0.id == id } }
        func header(_ id: String) -> ActivityGroupRow? {
            for item in list() { if case .group(let row) = item, row.id == id { return row } }
            return nil
        }
        func rows() -> [(index: Int, row: ActivityProcessRow)] {
            list().enumerated().compactMap { if case .process(let row) = $0.element, row.tab == tab.id { ($0.offset, row) } else { nil } }
        }
        let tabID = "group:tab:\(tab.id.uuidString)"
        let agentFound = await eventually(15) { rows().contains { $0.row.owner?.paneRole == .agent } && header(tabID)?.agent == .claude }
        let checkoutHeader = list().prefix { $0.id != tabID }.last { item in
            if case .group(let row) = item { return row.kind == .checkout }
            return false
        }
        check(
            "Processes groups the tab under its checkout, the stand-in agent named on the tab",
            agentFound && checkoutHeader != nil && header(tabID)?.depth == 1 && header(tabID)?.detail.hasPrefix("Claude Code") == true,
            "\(list().count) rows")
        // The end of the tab's group: the next header no deeper than it.
        let start = index(tabID) ?? -1
        let end =
            list().enumerated().first { offset, item in
                guard offset > start, case .group(let row) = item else { return false }
                return row.depth <= 1 && row.kind != .pane
            }?.offset ?? list().count
        let server = rows().first { $0.row.name.lowercased().hasPrefix("python") }
        check(
            "the tab's server in its tab's tree, a pane's process by lineage",
            server.map { $0.index > start && $0.index < end && $0.row.owner?.rule == 4 && $0.row.depth > 1 } == true
                && server?.row.owner?.reason?.hasPrefix("in “") == true,
            "pid \(server?.row.identity.pid ?? -1)")
        let agent = rows().first { $0.row.owner?.paneRole == .agent }
        let child = rows().first { $0.row.name == "sleep" && $0.row.owner?.agent != nil }
        check(
            "the agent's child under the agent, started by it",
            agent != nil && child.map { $0.index > agent!.index && $0.row.depth > agent!.row.depth && $0.row.owner?.agent == agent?.row.identity } == true
                && child?.row.owner?.reason?.hasPrefix("started by Claude") == true,
            "agent pid \(agent?.row.identity.pid ?? -1), child pid \(child?.row.identity.pid ?? -1)")
        let plain = rows().first { $0.row.name == "sleep" && $0.row.owner?.agent == nil }
        check("the person's own sleep says nothing of an agent", plain?.row.owner?.paneRole == .background, "pid \(plain?.row.identity.pid ?? -1)")

        // G: Checkout → Tab → Agent; the agent's group holds its child.
        check("G groups by tab, then by agent", page.press("G") && page.grouping == .tab && page.press("G") && page.grouping == .agent)
        let agentGroup = agent.map { "group:agent:\($0.row.id)" } ?? "-"
        let grouped = await eventually(10) {
            guard let at = index(agentGroup), let childID = child?.row.id, let below = index(childID) else { return false }
            return below > at && header("group:agent:none") != nil
        }
        check("by agent, the agent's subtree under its group, the rest under No agent", grouped, "\(list().count) rows")
        while page.grouping != .checkout { _ = page.press("G") }

        // The ladder: [ narrows from the Mac to all tabs, the checkout, the
        // tab; the chip says so; ] widens back.
        check("[ narrows to all tabs", page.press("[") && page.scope(.processes) == .allTabs)
        check("[ again, to the tab's checkout", page.press("[") && { if case .checkout = page.scope(.processes) { true } else { false } }())
        check("[ again, to the tab", page.press("[") && page.scope(.processes) == .tab(tab.id))
        let scoped = await eventually(10) { !page.content.processes.isEmpty && page.content.processes.allSatisfy { $0.tab == tab.id } }
        let chip = await eventually(5) {
            self.app.pages.view(.activity).flatMap { Self.accessibilityElement("activity.scope", in: $0) }?.text.contains("Tab:") == true
        }
        check("only the tab's processes, and the chip says Tab", scoped && chip, "\(page.content.processes.count) rows")
        _ = page.press("]")
        _ = page.press("]")
        _ = page.press("]")
        check("] widens back to the Mac", page.scope(.processes) == .mac && page.scopeTitle(.processes) == nil)
    }

    /// The accessibility labels of the page's list's rows on screen.
    package func activityRowLabels() -> [String] {
        guard let view = app.pages.view(.activity), let table = WorkspacePages.firstTable(in: view) else { return [] }
        let visible = table.rows(in: table.visibleRect)
        var labels: [String] = []
        for index in visible.location..<(visible.location + visible.length) {
            if let label = table.rowView(atRow: index, makeIfNecessary: false)?.accessibilityLabel(), !label.isEmpty { labels.append(label) }
        }
        return labels
    }
}
#endif
