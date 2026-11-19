import AppKit

/// A resource list's rows pressed as a person presses them: a press and its
/// release given to the list's own window (`sendEvent`), never the
/// system's. The scenarios set the selection through the model elsewhere,
/// which a list that took no press at all still passed.
extension E2ERunner {
    /// What a press on a row's cell met: the view that answered it, as the
    /// window's frame view finds it, and the rows selected after.
    struct ListPress {
        let hit: String
        let selected: [Int]
    }

    /// Presses `row` of `table` in the column `column` (by identifier; the
    /// first when nil), `dx` points in from the cell's leading edge, and
    /// waits until the release has been handled.
    @discardableResult
    func pressListRow(
        _ table: NSTableView, row: Int, column: String? = nil, dx: CGFloat? = nil, x: CGFloat? = nil, modifiers: NSEvent.ModifierFlags = []
    ) async -> ListPress {
        guard let window = table.window, row >= 0, row < table.numberOfRows else { return ListPress(hit: "no row", selected: []) }
        table.scrollRowToVisible(row)
        table.window?.contentView?.layoutSubtreeIfNeeded()
        await pause(0.1)
        let at = column.map { table.column(withIdentifier: NSUserInterfaceItemIdentifier($0)) } ?? 0
        let cell = table.frameOfCell(atColumn: max(at, 0), row: row)
        let point = NSPoint(x: x ?? (cell.minX + (dx ?? min(40, cell.width / 2))), y: cell.midY)
        let location = table.convert(point, to: nil)
        let frameView = window.contentView?.superview
        let answered = frameView?.hitTest(frameView?.superview?.convert(location, from: nil) ?? location)
        let hit = answered.map { String(describing: type(of: $0)) } ?? "nothing"
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return ListPress(hit: hit, selected: []) }
        // The release queued first, for a tracking loop to find.
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        await pause(0.3)
        return ListPress(hit: hit, selected: Array(table.selectedRowIndexes))
    }
}

extension E2ERunner {
    /// Processes' rows pressed: a text column's cell, the name's, the
    /// strip's, a group's hosted header; Listening's port row (`port`).
    func activityPressChecks(tab: Tab, port: Int? = nil) async {
        let page = app.activityPage
        guard let view = app.pages.view(.activity), let table = WorkspacePages.firstTable(in: view) as? ResourceTableView else {
            return check("the page's table, to press", false)
        }
        func clear() async {
            page.selection = []
            _ = await eventually(3) { table.selectedRowIndexes.isEmpty }
        }
        func at(_ id: String) -> Int? { page.list.rows.rows.firstIndex { $0.id == id } }
        if let port {
            guard let row = page.list.rows.rows.firstIndex(where: { if case .port(let p) = $0 { p.port == port } else { false } }) else {
                return check("the port's row, to press", false)
            }
            let id = page.list.rows.rows[row].id
            await clear()
            let press = await pressListRow(table, row: row, column: "port")
            let chosen = await eventually(2) { page.selection == [id] }
            check("a press on a port's row selects it", chosen, "hit \(press.hit), table \(press.selected), row \(row), page \(page.selection.count)")
            return
        }
        guard
            let process = page.list.rows.rows.first(where: {
                if case .process(let p) = $0 { p.tab == tab.id && !p.dimmed && p.name == "sleep" } else { false }
            })
        else { return check("a process's row, to press", false) }
        let id = process.id
        for (column, what, dx) in [("pid", "a text cell", CGFloat?.none), ("name", "the name cell", CGFloat?.none), ("cpu15", "the strip cell", CGFloat?.none)] {
            await clear()
            guard let row = at(id) else { return check("the process's row, to press", false) }
            let name = column == "name" ? table.frameOfCell(atColumn: table.column(withIdentifier: .init("name")), row: row).width - 8 : dx
            let press = await pressListRow(table, row: row, column: column, dx: name)
            let chosen = await eventually(2) { page.selection == [id] }
            check(
                "a press on a process's row, on \(what), selects it", chosen,
                "hit \(press.hit), table \(press.selected), row \(row), page \(page.selection.count), detail \(page.detail?.row.id == id)")
        }
        // The row's room no cell covers: past its last column, its inset.
        for (x, what) in [(CGFloat?.none, "past its last column"), (CGFloat(4), "in its inset")] {
            await clear()
            guard let row = at(id) else { return check("the process's row, to press", false) }
            let last = (0..<table.numberOfColumns).map { table.frameOfCell(atColumn: $0, row: row).maxX }.max() ?? 0
            let place = x ?? min(last + 20, table.bounds.width - 4)
            guard place > last || x != nil else {
                note("no room past the last column to press")
                continue
            }
            let press = await pressListRow(table, row: row, x: place)
            check("a press on a process's row, \(what), selects it", await eventually(2) { page.selection == [id] }, "hit \(press.hit), at \(place)")
        }
        // ⌘ adds the next row, a plain press selects one alone again.
        if let row = at(id), row + 1 < table.numberOfRows {
            let next = page.list.rows.rows[row + 1].id
            await pressListRow(table, row: row, column: "pid")
            _ = await eventually(2) { page.selection == [id] }
            await pressListRow(table, row: row + 1, column: "pid", modifiers: .command)
            check("⌘-press adds a row", await eventually(2) { page.selection == [id, next] }, "\(page.selection.count) selected")
            await pressListRow(table, row: row, column: "pid")
            check("a plain press selects it alone again", await eventually(2) { page.selection == [id] }, "\(page.selection.count) selected")
        }
        // A group's hosted header.
        if let group = page.list.rows.rows.firstIndex(where: { if case .group(let g) = $0 { g.kind != .more && g.kind != .container } else { false } }) {
            let groupID = page.list.rows.rows[group].id
            await clear()
            let width = table.frameOfCell(atColumn: 0, row: group).width
            let press = await pressListRow(table, row: group, column: nil, dx: min(width / 2, 160))
            let chosen = await eventually(2) { page.selection == [groupID] }
            check("a press on a group's header selects it", chosen, "hit \(press.hit), table \(press.selected), row \(group)")
        } else {
            note("no group header listed to press")
        }
        await clear()
    }
}

extension E2ERunner {
    /// Docker's containers list: a container's row pressed, then another,
    /// then ⌘ adding the first.
    func dockerPressChecks() async {
        let page = app.dockerPage
        guard let view = app.dockerView, let table = WorkspacePages.firstTable(in: view) as? ResourceTableView else {
            return check("Docker's table, to press", false)
        }
        let rows = DockerTableRow.rows(page.groups, collapsed: page.collapsed)
        let containers = rows.indices.filter { if case .container = rows[$0] { true } else { false } }
        guard containers.count >= 2 else { return check("two containers' rows, to press", false, "\(containers.count)") }
        let saved = page.selection
        page.selection = []
        _ = await eventually(3) { table.selectedRowIndexes.isEmpty }
        let first = containers[0]
        let second = containers[1]
        let press = await pressListRow(table, row: first, dx: 90)
        check(
            "a press on a container's row selects it", await eventually(2) { page.selection == [rows[first].id] },
            "hit \(press.hit), table \(press.selected), row \(first), page \(page.selection)")
        await pressListRow(table, row: second, dx: 90)
        check("a press on another selects it", await eventually(2) { page.selection == [rows[second].id] }, "\(page.selection)")
        await pressListRow(table, row: first, dx: 90, modifiers: .command)
        check("⌘-press adds one", await eventually(2) { page.selection == [rows[first].id, rows[second].id] }, "\(page.selection)")
        page.selection = saved
    }
}

extension E2ERunner {
    /// A Kubernetes list (any kind): `id`'s row pressed.
    func kubernetesPressChecks(id: String) async {
        let page = app.kubernetesPage
        guard let view = app.kubernetesView, let table = WorkspacePages.firstTable(in: view) as? ResourceTableView else {
            return check("the Kubernetes table, to press", false)
        }
        let rows = page.rows
        guard let row = rows.firstIndex(where: { $0.id == id }), table.numberOfRows == rows.count else {
            return check("\(id)'s row, to press", false, "\(rows.count) rows, table \(table.numberOfRows)")
        }
        page.selection = []
        _ = await eventually(3) { table.selectedRowIndexes.isEmpty }
        let press = await pressListRow(table, row: row, column: table.tableColumns.first?.identifier.rawValue, dx: 30)
        check(
            "a press on a Kubernetes row selects it", await eventually(2) { page.selection == [id] },
            "hit \(press.hit), table \(press.selected), row \(row), page \(page.selection)")
    }
}
