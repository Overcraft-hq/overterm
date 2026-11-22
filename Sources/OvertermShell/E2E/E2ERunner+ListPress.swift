#if E2E
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
        /// The view itself, to tell it from its neighbours.
        var view: NSView? = nil
    }

    /// Whether `press` hit the cell at `column` (by identifier; the first
    /// when nil) of `row` — an AppKit cell itself, a hosted cell's SwiftUI
    /// within it — and what it expected, to say so.
    func pressHitCell(_ press: ListPress, in table: NSTableView, row: Int, column: String? = nil) -> (ok: Bool, expected: String) {
        let at = column.map { table.column(withIdentifier: NSUserInterfaceItemIdentifier($0)) } ?? 0
        guard at >= 0, let cell = table.view(atColumn: at, row: row, makeIfNecessary: false) else { return (false, "no cell at \(column ?? "0"), \(row)") }
        let expected = String(describing: type(of: cell))
        guard let hit = press.view else { return (false, expected) }
        if cell is ResourcePressCell { return (hit === cell, expected) }
        return (hit.isDescendant(of: cell) && !(hit is NSTableView), "within \(expected)")
    }

    /// Presses `row` of `table` in the column `column` (by identifier; the
    /// first when nil), `dx` points in from the cell's leading edge, and
    /// waits until the release has been handled.
    @discardableResult
    func pressListRow(
        _ table: NSTableView, row: Int, column: String? = nil, dx: CGFloat? = nil, x: CGFloat? = nil, modifiers: NSEvent.ModifierFlags = []
    ) async -> ListPress {
        guard let window = table.window, row >= 0, row < table.numberOfRows else { return ListPress(hit: "no row", selected: [], view: nil) }
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
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return ListPress(hit: hit, selected: [], view: answered) }
        // The release queued first, for a tracking loop to find.
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        await pause(0.3)
        return ListPress(hit: hit, selected: Array(table.selectedRowIndexes), view: answered)
    }

    /// What a right-click on `row`'s cell in `column` met, given to the
    /// list's own window: the view that answered, the table's `clickedRow`
    /// and the menu's titles while it tracked — closed again at once, as
    /// it begins (`NSMenu.didBeginTrackingNotification`), so nothing waits
    /// on a person. Nil titles: no menu opened.
    struct ListRightClick {
        let hit: NSView?
        let clickedRow: Int
        let titles: [String]?
        /// Whether the menu that tracked was the table's own.
        let tables: Bool
    }

    /// A view and its superviews' classes, to say what a press met.
    static func viewChain(_ view: NSView?) -> String {
        var names: [String] = []
        var current = view
        while let one = current, names.count < 8 {
            names.append("\(type(of: one)) \(Int(one.frame.minX)),\(Int(one.frame.width))")
            current = one.superview
        }
        return names.joined(separator: " < ")
    }

    func rightClickListRow(_ table: NSTableView, row: Int, column: String) async -> ListRightClick {
        guard let window = table.window, row >= 0, row < table.numberOfRows else { return ListRightClick(hit: nil, clickedRow: -1, titles: nil, tables: false) }
        table.scrollRowToVisible(row)
        window.contentView?.layoutSubtreeIfNeeded()
        await pause(0.1)
        let cell = table.frameOfCell(atColumn: max(table.column(withIdentifier: NSUserInterfaceItemIdentifier(column)), 0), row: row)
        let location = table.convert(NSPoint(x: cell.minX + min(40, cell.width / 2), y: cell.midY), to: nil)
        let frameView = window.contentView?.superview
        let answered = frameView?.hitTest(frameView?.superview?.convert(location, from: nil) ?? location)
        final class Seen: @unchecked Sendable {
            var menu: NSMenu?
            var titles: [String]?
            var clickedRow = -1
            var tables = false
        }
        let seen = Seen()
        let list = table
        // Whichever menu begins tracking: read, then closed by a timer the
        // tracking loop's own mode runs.
        let began = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            nonisolated(unsafe) let tracked = note.object as? NSMenu
            MainActor.assumeIsolated {
                guard let menu = tracked, seen.menu == nil else { return }
                seen.menu = menu
                seen.tables = menu === list.menu
                seen.clickedRow = list.clickedRow
            }
        }
        // Its items as it shows them — filled once it tracks
        // (`menuNeedsUpdate`), after the notification —, then closed.
        let closer = Timer(timeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                if let menu = seen.menu {
                    if seen.titles == nil { seen.titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title) }
                    menu.cancelTracking()
                }
                list.menu?.cancelTracking()
            }
        }
        RunLoop.main.add(closer, forMode: .common)
        RunLoop.main.add(closer, forMode: .eventTracking)
        defer {
            closer.invalidate()
            NotificationCenter.default.removeObserver(began)
        }
        guard
            let down = NSEvent.mouseEvent(
                with: .rightMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { return ListRightClick(hit: answered, clickedRow: -1, titles: nil, tables: false) }
        // The menu tracks inside this call, and is closed before it returns.
        window.sendEvent(down)
        await pause(0.1)
        return ListRightClick(hit: answered, clickedRow: seen.clickedRow, titles: seen.titles, tables: seen.tables)
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
            let cell = pressHitCell(press, in: table, row: row, column: "port")
            check("the port's cell took the press", cell.ok, "hit \(press.hit), expected \(cell.expected)")
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
            let cell = pressHitCell(press, in: table, row: row, column: column)
            check("\(what) took the press, not the table", cell.ok, "hit \(press.hit), expected \(cell.expected)")
        }
        // The row's room no cell covers: past its last column — the last
        // column narrowed for the press, so there is room whatever the
        // window's width, then given back —, and its inset.
        if let row = at(id), let lastColumn = table.tableColumns.last {
            let width = lastColumn.width
            let least = lastColumn.minWidth
            let style = table.columnAutoresizingStyle
            table.columnAutoresizingStyle = .noColumnAutoresizing
            lastColumn.minWidth = min(least, 20)
            lastColumn.width = max(20, width - 80)
            table.layoutSubtreeIfNeeded()
            await clear()
            let last = (0..<table.numberOfColumns).map { table.frameOfCell(atColumn: $0, row: row).maxX }.max() ?? 0
            let edge = table.visibleRect.maxX
            let place = last + (edge - last) / 2
            check("a narrowed column leaves room past the last", edge - last >= 20, "last \(last), shown to \(edge), width \(table.bounds.width)")
            let press = await pressListRow(table, row: row, x: place)
            check("a press on a process's row, past its last column, selects it", await eventually(2) { page.selection == [id] }, "hit \(press.hit), at \(place)")
            check("the table took the press past the last column", press.view === table, "hit \(press.hit) in \(Self.viewChain(press.view))")
            lastColumn.width = width
            lastColumn.minWidth = least
            table.columnAutoresizingStyle = style
            table.layoutSubtreeIfNeeded()
        } else {
            check("the process's row and a last column, to press past", false)
        }
        if let row = at(id) {
            await clear()
            let inset = table.frameOfCell(atColumn: 0, row: row).minX
            if inset < 2 {
                // The pages' tables are inset: one that isn't says so.
                check("an inset table leaves room before its first column", table.style != .inset, "\(inset) pt")
                note("no inset before the first column to press (\(inset) pt): the table's style leaves none")
            } else {
                let press = await pressListRow(table, row: row, x: inset / 2)
                check("a press on a process's row, in its inset, selects it", await eventually(2) { page.selection == [id] }, "hit \(press.hit), at \(inset / 2)")
                check("the table took the press in the inset", press.view === table, "hit \(press.hit)")
            }
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
        // ⇧ extends from the selected row to the one two below it: the
        // process's row and the two below, or the two above and it.
        if let row = at(id), table.numberOfRows >= 3 {
            let anchor = row + 2 < table.numberOfRows ? row : row - 2
            let range = Set(page.list.rows.rows[anchor...(anchor + 2)].map(\.id))
            let first = page.list.rows.rows[anchor].id
            await pressListRow(table, row: anchor, column: "pid")
            _ = await eventually(2) { page.selection == [first] }
            let press = await pressListRow(table, row: anchor + 2, column: "pid", modifiers: .shift)
            check(
                "⇧-press selects the rows between", await eventually(2) { page.selection == range },
                "\(page.selection.count) selected, table \(press.selected), from \(anchor)")
        } else {
            check("three rows, to ⇧-press", false, "\(table.numberOfRows) rows")
        }
        // A right-click on a text cell: its row clicked, the row's verbs.
        if let row = at(id) {
            await pressListRow(table, row: row, column: "pid")
            _ = await eventually(2) { page.selection == [id] }
            let expected = ResourceVerbMenuItem.items(page.verbs(for: [id], copy: { _ in })).filter { !$0.isSeparatorItem }.map(\.title)
            let click = await rightClickListRow(table, row: row, column: "pid")
            let hit = click.hit.map { String(describing: type(of: $0)) } ?? "nothing"
            check("a right-click on a text cell reaches the cell", click.hit is ResourceTextCell, "hit \(hit)")
            check("the right-click's row is the table's clicked row", click.clickedRow == row, "clicked \(click.clickedRow), row \(row)")
            check("its menu is the table's", click.tables, "\(click.titles ?? ["no menu"])")
            check("its menu is the row's verbs", click.titles == expected, "\(click.titles ?? ["no menu"]) against \(expected)")
        }
        // A group's hosted header.
        if let group = page.list.rows.rows.firstIndex(where: { if case .group(let g) = $0 { g.kind != .more && g.kind != .container } else { false } }) {
            let groupID = page.list.rows.rows[group].id
            // Its fold before any press: the first press already flips it.
            var foldable = false
            var wasFolded = false
            if case .group(let g) = page.list.rows.rows[group] { foldable = g.foldable; wasFolded = g.folded }
            await clear()
            let width = table.frameOfCell(atColumn: 0, row: group).width
            let press = await pressListRow(table, row: group, column: nil, dx: min(width / 2, 160))
            let chosen = await eventually(2) { page.selection == [groupID] }
            check("a press on a group's header selects it", chosen, "hit \(press.hit), table \(press.selected), row \(group)")
            let cell = pressHitCell(press, in: table, row: group)
            check("the group's hosted header took the press", cell.ok, "hit \(press.hit), expected \(cell.expected)")
            // The whole header is the fold's switch, not only its chevron: the
            // press folded or unfolded it, and a second press puts it back.
            func folded() -> Bool? {
                for row in page.list.rows.rows { if case .group(let g) = row, g.id == groupID { return g.folded } }
                return nil
            }
            if foldable {
                let flipped = await eventually(3) { folded() == !wasFolded }
                check("a press on a group's header flips its fold", flipped, "folded \(String(describing: folded())), was \(wasFolded)")
                if let again = page.list.rows.rows.firstIndex(where: { $0.id == groupID }) {
                    let w = table.frameOfCell(atColumn: 0, row: again).width
                    _ = await pressListRow(table, row: again, column: nil, dx: min(w / 2, 160))
                }
                let back = await eventually(3) { folded() == wasFolded }
                check("and a second press puts it back", back, "folded \(String(describing: folded())), was \(wasFolded)")
            } else {
                note("the group pressed can't fold")
            }
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
        let cell = pressHitCell(press, in: table, row: first)
        check("the container's cell took the press", cell.ok, "hit \(press.hit), expected \(cell.expected)")
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
        let column = table.tableColumns.first?.identifier.rawValue
        let press = await pressListRow(table, row: row, column: column, dx: 30)
        check(
            "a press on a Kubernetes row selects it", await eventually(2) { page.selection == [id] },
            "hit \(press.hit), table \(press.selected), row \(row), page \(page.selection)")
        let cell = pressHitCell(press, in: table, row: row, column: column)
        check("the Kubernetes row's cell took the press", cell.ok, "hit \(press.hit), expected \(cell.expected)")
    }

    /// A Kubernetes list with `selected` selected: `adding`'s row pressed
    /// with ⌘ — added, never taken twice (added, then taken away again).
    /// Selected through the model first, so no plain press opens a detail
    /// (and a visit in the history) the scenario doesn't expect.
    func kubernetesCommandPressCheck(selected: String, adding: String) async {
        let page = app.kubernetesPage
        guard let view = app.kubernetesView, let table = WorkspacePages.firstTable(in: view) as? ResourceTableView else {
            return check("the Kubernetes table, to ⌘-press", false)
        }
        let rows = page.rows
        guard let first = rows.firstIndex(where: { $0.id == selected }), let other = rows.firstIndex(where: { $0.id == adding }),
            table.numberOfRows == rows.count
        else { return check("\(selected)'s and \(adding)'s rows, to ⌘-press", false, "\(rows.map(\.id)), table \(table.numberOfRows)") }
        let saved = page.selection
        page.selection = [selected]
        _ = await eventually(3) { table.selectedRowIndexes == [first] }
        let column = table.tableColumns.first?.identifier.rawValue
        let press = await pressListRow(table, row: other, column: column, dx: 30, modifiers: .command)
        check(
            "⌘-press adds a second Kubernetes row", await eventually(2) { page.selection == [selected, adding] },
            "\(page.selection), hit \(press.hit), table \(press.selected)")
        let cell = pressHitCell(press, in: table, row: other, column: column)
        check("the second row's cell took the ⌘-press", cell.ok, "hit \(press.hit), expected \(cell.expected)")
        check("and no detail opened by it", page.detail == nil, page.detail?.ref.name ?? "")
        page.selection = saved
        _ = await eventually(3) { table.selectedRowIndexes.count == saved.count }
    }
}
#endif
