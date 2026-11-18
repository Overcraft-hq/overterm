import AppKit

/// The Processes table (docs/design/activity/analysis.md, 6.5–6.7, 10.3):
/// htop's sort keys and the header's order, the filter with a match's
/// ancestors dimmed, `/`, the detail, follow, pause, ← and → in the table,
/// a column moved and kept, and the order held while the list is worked —
/// over the run's own children only. Pids and counts, never another
/// process's name or command.
extension E2ERunner {
    /// The tab whose checkout the detail's Show in Overgit names, for the
    /// scenario's last check (it takes the page away).
    @discardableResult
    func activityTable(tab: Tab) async -> UUID? {
        let page = app.activityPage
        let pane = tab.terminal
        guard let view = app.pages.view(.activity), let table = WorkspacePages.firstTable(in: view) as? ResourceTableView else {
            check("the page's table", false)
            return nil
        }
        func own() -> [ActivityProcessRow] { page.content.processes.filter { $0.tab == tab.id && !$0.dimmed } }
        func listed() -> [ActivityProcessRow] {
            page.content.list.compactMap { if case .process(let row) = $0, row.tab == tab.id { row } else { nil } }
        }
        func said(_ identifier: String) -> String? { Self.accessibilityElement(identifier, in: view)?.text }

        // Two sleeps of the table's own, beside the scenario's.
        pane.insertText("sleep 60 & sleep 61 &")
        pane.pressReturn()
        _ = await eventually(10) { own().filter { $0.name == "sleep" }.count >= 2 }

        // Sort: N by PID, I inverted; the header shows it.
        check("N sorts by PID", page.press("N") && page.processSort == ResourceSort(column: "pid"))
        let ascending = await eventually(10) {
            let pids = own().map(\.identity.pid)
            return pids.count >= 3 && pids == pids.sorted() && table.sortDescriptors.first?.key == "pid"
        }
        check("by PID, ascending, the header's arrow on PID", ascending, "\(own().count) rows")
        check("I inverts it", page.press("I") && page.processSort == ResourceSort(column: "pid", ascending: false))
        let descending = await eventually(10) {
            let pids = own().map(\.identity.pid)
            return pids.count >= 3 && pids == pids.sorted(by: >) && table.sortDescriptors.first?.ascending == false
        }
        check("descending", descending)
        check("P back to CPU, busiest first", page.press("P") && page.processSort == ResourceSort(column: "cpu", ascending: false))

        // The filter: `/` gives it the keyboard; a match keeps its ancestors.
        app.focusPageList(.activity)
        _ = await eventually(3) { self.app.pageListHasKeyboard(.activity) }
        let slash = page.press("/")
        let focused = await eventually(3) { (self.app.window?.firstResponder as? NSTextView)?.isFieldEditor == true }
        check("/ focuses the filter field", slash && focused)
        app.focusPageList(.activity)
        page.setFilter("name:sleep")
        let filtered = await eventually(10) { own().count >= 2 && own().allSatisfy { $0.name == "sleep" } }
        check("name:sleep lists only the sleeps", filtered, "\(own().count) matches")
        let dimmed = await eventually(10) { listed().contains(where: \.dimmed) && listed().filter { !$0.dimmed }.allSatisfy { $0.name == "sleep" } }
        check("in the tree each keeps its ancestors, dimmed", dimmed, "\(listed().filter(\.dimmed).count) dimmed")
        page.setFilter("name:sleep|python")
        let ored = await eventually(10) { own().contains { $0.name.lowercased().hasPrefix("python") } && own().contains { $0.name == "sleep" } }
        check("| inside a value ORs", ored)
        page.setFilter("name:acme-nothing-runs-this")
        let none = await eventually(10) { page.content.list.isEmpty && said("activity.empty")?.contains("Nothing matches") == true }
        check("a filter that matches nothing says so", none)
        page.setFilter("")
        _ = await eventually(10) { own().count >= 3 }

        // The detail: the selected server's.
        guard let server = own().first(where: { $0.name.lowercased().hasPrefix("python") }) else {
            check("the server's row", false)
            return nil
        }
        page.selection = [server.id]
        let detailed = await eventually(5) { said("activity.detail.command")?.isEmpty == false }
        check("the selected process's detail, its masked command", page.detail?.row.id == server.id && detailed, "pid \(server.identity.pid)")
        check("its tree reaches up to the tab's shell", page.detail?.ancestors.isEmpty == false)
        // The run's rows are its own tabs' (9.9): the tree stops there, never
        // naming what launched the run.
        let rows = Set(page.content.identities.map(\.id))
        check(
            "every ancestor in the detail is one of the run's rows", page.detail?.ancestors.allSatisfy { rows.contains($0.id) } == true,
            "\(page.detail?.ancestors.count ?? 0) ancestors")
        let bar = await eventually(5) { Self.accessibilityElement("activity.actions", in: view) != nil }
        check("the detail's verbs are an action bar, the row menu's list", bar && page.verbs(for: [server.id]) { _ in }.contains { $0.title == "Go to Tab" })
        // Where and why's links (6.4): the checkout in Overgit too.
        var overgitTab: UUID?
        if server.checkout != nil, let tabID = server.tab {
            let link = await eventually(5) { Self.accessibilityElement("activity.detail.overgit", in: view) != nil }
            check("Where and why links the checkout in Overgit", link)
            overgitTab = tabID
        } else {
            check("the server's row has its tab's checkout", false)
        }

        // Follow: a list taller than its view, the selected row scrolled
        // off: unfollowed it stays off, followed it comes back into view.
        let earlier = Set(own().filter { $0.name == "sleep" }.map(\.id))
        func follow() -> [ActivityProcessRow] { own().filter { $0.name == "sleep" && !earlier.contains($0.id) } }
        // One job of the shell's own: its group is its pid. (`$!` only at
        // the line's end: within it, zsh reads `!` as history.)
        pane.insertText("(for i in {1..80}; do sleep 90 & done; wait) & ACME_FOLLOW=$!")
        pane.pressReturn()
        // The job's sleeps: the eighty that share its subshell as parent.
        func job() -> [ActivityProcessRow] { Dictionary(grouping: follow(), by: \.parentPID).values.first { $0.count >= 80 } ?? [] }
        let many = await eventually(15) { job().count == 80 }
        let started = Set(job().map(\.id))
        page.processSort = ResourceSort(column: "pid")
        page.selection = [server.id]
        // The selection shown — the row the table selected is the server's
        // — and its verbs read, so no update for either is still to come
        // once the list is scrolled away.
        let tall = await eventually(10) {
            table.selectedRow >= 0 && page.content.list.firstIndex { $0.id == server.id } == table.selectedRow
                && page.verbSubject?.signal.identity == server.identity && table.numberOfRows > 0
                && table.bounds.height > table.visibleRect.height * 1.5
        }
        await pause(0.3)
        check("a list taller than its view", many && tall, "\(table.numberOfRows) rows")
        table.scrollRowToVisible(table.numberOfRows - 1)
        let away = !table.rows(in: table.visibleRect).contains(table.selectedRow)
        let quiet = page.builds
        _ = await eventually(10) { page.builds >= quiet + 2 }
        check(
            "unfollowed, the list stays where the person left it",
            away && page.builds >= quiet + 2 && table.selectedRow >= 0 && !table.rows(in: table.visibleRect).contains(table.selectedRow),
            "\(page.builds - quiet) builds")
        check("F follows", page.press("F") && page.following)
        let builds = page.builds
        let followed = await eventually(10) {
            page.builds >= builds + 1 && page.selection == [server.id] && table.selectedRow >= 0
                && table.rows(in: table.visibleRect).contains(table.selectedRow)
        }
        check("followed, the selected row is brought back into view", followed, "\(page.builds - builds) builds")
        _ = page.press("F")
        // The run's own job ends, by the group the shell made for it.
        pane.insertText("kill -TERM -$ACME_FOLLOW")
        pane.pressReturn()
        let ended = await eventually(15) { !own().contains { started.contains($0.id) } }
        check("the follow's sleeps end", ended, "\(own().filter { started.contains($0.id) }.count) of \(started.count) left")
        page.processSort = ResourceSort(column: "cpu", ascending: false)

        // ← and → in the table: the agent's row folds and unfolds.
        if let agent = listed().first(where: { $0.owner?.paneRole == .agent && $0.hasChildren }) {
            page.selection = [agent.id]
            _ = await eventually(5) { table.selectedRow >= 0 && page.content.list.firstIndex { $0.id == agent.id } == table.selectedRow }
            func arrow(_ code: UInt16, _ scalar: Int) {
                let character = String(Character(UnicodeScalar(scalar)!))
                guard
                    let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: app.window?.windowNumber ?? 0, context: nil, characters: character, charactersIgnoringModifiers: character,
                        isARepeat: false, keyCode: code)
                else { return }
                table.keyDown(with: event)
            }
            arrow(123, NSLeftArrowFunctionKey)
            let folded = await eventually(5) { listed().first { $0.id == agent.id }?.folded == true }
            check("← folds the agent's row", folded)
            arrow(124, NSRightArrowFunctionKey)
            let unfolded = await eventually(5) { listed().first { $0.id == agent.id }?.folded == false }
            check("→ unfolds it", unfolded)
        } else {
            check("the agent's row with its child", false)
        }

        // A column moved in the header: kept.
        let before = page.columns(.processes).map(\.id)
        table.moveColumn(1, toColumn: 2)
        let moved = page.columns(.processes).map(\.id)
        check(
            "a column dragged to another place is kept",
            moved.count == before.count && moved != before && page.layout["processes"]?.map(\.id) == moved
                && AppEnvironment.defaults.data(forKey: ActivityColumns.key) != nil)
        table.moveColumn(2, toColumn: 1)

        // Pause: nothing read, the header says so.
        check("Z pauses", page.press("Z") && page.paused && !ActivityMonitor.shared.demand.full)
        let saysPaused = await eventually(3) { said("activity.pause")?.contains("paused") == true }
        check("the header says paused", saysPaused)
        let paused = page.builds
        await pause(1.5)
        check("paused, no rows made", page.builds == paused, "\(page.builds - paused) builds")
        check("Z again reads", page.press("Z") && !page.paused && ActivityMonitor.shared.demand.full)

        // The held order: the pointer over the list holds it; a new process
        // waits until it lets go.
        page.processSort = ResourceSort(column: "pid")
        _ = await eventually(5) { own().map(\.identity.pid) == own().map(\.identity.pid).sorted() }
        page.selection = []
        table.interaction?(.hover)
        check("the pointer over the list holds the order", page.orderHeld)
        let saysHeld = await eventually(3) { said("activity.orderHeld") != nil }
        check("and the header says order held", saysHeld)
        let shown = Set(page.content.list.map(\.id))
        pane.insertText("sleep 31 &")
        pane.pressReturn()
        var lastMove = ContinuousClock.now
        let waited = await eventually(15) {
            // The pointer keeps moving: resting 5 s would let go.
            table.interaction?(.hover)
            lastMove = .now
            return page.waiting?.processes.contains { $0.tab == tab.id && $0.name == "sleep" && !shown.contains($0.id) } == true
        }
        check("a new process waits while it holds", waited && Set(page.content.list.map(\.id)) == shown, "\(page.content.list.count) rows")
        // The pointer rests (6.7, 10.3): the model's own timer lets go after
        // 5 s, and what waited comes.
        let rested = await eventually(10) { !page.orderHeld && page.content.list.contains { !shown.contains($0.id) } }
        let rest = ContinuousClock.now - lastMove
        check(
            "after 5 s at rest it lets go, the waiting rows shown", rested && rest >= .milliseconds(4_900),
            "held \(page.orderHeld), waiting \(page.waiting != nil), \(rest)")
        let letGo = await eventually(5) { said("activity.orderHeld") == nil }
        check("and the header lets go", letGo)
        table.interaction?(.hover)
        check("the pointer moving again holds it", page.orderHeld)
        table.interaction?(.exit)
        check("once the pointer leaves, it lets go at once", !page.orderHeld && page.waiting == nil)
        // AppKit says "entered" again whenever the list's tracking area is
        // made anew under a pointer at rest — every reload. Told as a move,
        // a pointer resting where this window opened held the order for the
        // whole run. The view's own handler, given such an event: only a
        // pointer somewhere else holds.
        if let window = table.window {
            func entered(_ offset: CGFloat) {
                let screen = NSEvent.mouseLocation
                let at = window.convertPoint(fromScreen: NSPoint(x: screen.x + offset, y: screen.y))
                guard
                    let event = NSEvent.enterExitEvent(
                        with: .mouseEntered, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
                else { return }
                table.mouseEntered(with: event)
            }
            entered(40)
            check("an enter where the pointer wasn't holds the order", page.orderHeld)
            table.interaction?(.exit)
            entered(0)
            table.interaction?(.exit)
            entered(0)
            check("an enter again where the pointer rests doesn't", !page.orderHeld)
        }
        page.processSort = ResourceSort(column: "cpu", ascending: false)

        return overgitTab
    }
}
