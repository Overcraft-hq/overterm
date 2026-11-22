import AppKit
import SwiftUI
import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell
@testable import OvertermOvergit
@testable import OvertermAPI

/// A page's resource table (`ResourceTable`): its grouped rows, its order,
/// what a press selects and what a right-click means — Docker's containers
/// list is one, Kubernetes' lists with the server's columns the next.
final class ResourceTableTests: XCTestCase {
    /// A list that is not Docker's: a basket's row, then its fruit.
    private enum Fruit: ResourceTableRow {
        case basket(String)
        case fruit(String, weight: Int?)

        var id: String {
            switch self {
            case .basket(let name): "basket:" + name
            case .fruit(let name, _): name
            }
        }

        var height: CGFloat { 24 }

        var spansColumns: Bool {
            if case .basket = self { return true }
            return false
        }
    }

    private let baskets = [("a", ["apple", "apricot"]), ("b", ["banana"])]

    private func rows(collapsed: Set<String> = []) -> [Fruit] {
        ResourceGrouping.rows(
            baskets, collapsed: collapsed, id: { "basket:" + $0.0 }, header: { .basket($0.0) },
            members: { $0.1.map { .fruit($0, weight: nil) } })
    }

    func testAGroupsRowComesBeforeWhatItHolds() {
        XCTAssertEqual(rows().map(\.id), ["basket:a", "apple", "apricot", "basket:b", "banana"])
    }

    func testAFoldedGroupKeepsOnlyItsRow() {
        XCTAssertEqual(rows(collapsed: ["basket:a"]).map(\.id), ["basket:a", "basket:b", "banana"])
    }

    func testSortingIsStableAndPutsTheUnknownLast() {
        let items: [Fruit] = [.fruit("c", weight: 2), .fruit("a", weight: nil), .fruit("b", weight: 1), .fruit("d", weight: 2)]
        func weight(_ fruit: Fruit) -> Int? {
            if case .fruit(_, let weight) = fruit { return weight }
            return nil
        }
        XCTAssertEqual(ResourceSort(column: "weight").sorted(items, by: weight).map(\.id), ["b", "c", "d", "a"])
        XCTAssertEqual(ResourceSort(column: "weight", ascending: false).sorted(items, by: weight).map(\.id), ["c", "d", "b", "a"])
    }

    func testAColumnClickedAgainTurnsTheOrder() {
        let byName = ResourceSort(column: "name")
        XCTAssertEqual(byName.clicked("name"), ResourceSort(column: "name", ascending: false))
        XCTAssertEqual(byName.clicked("age"), ResourceSort(column: "age"))
        XCTAssertEqual(byName.clicked("name").clicked("name"), byName)
    }

    @MainActor
    func testAPressSelectsAddsAndExtends() {
        XCTAssertEqual(ResourceTableView.pressed(3, in: [1], anchor: 1, modifiers: []), [3], "a press: that row alone")
        XCTAssertEqual(ResourceTableView.pressed(3, in: [1], anchor: 1, modifiers: .command), [1, 3], "⌘ adds")
        XCTAssertEqual(ResourceTableView.pressed(1, in: [1, 3], anchor: 1, modifiers: .command), [3], "⌘ again takes it away")
        XCTAssertEqual(ResourceTableView.pressed(4, in: [1], anchor: 1, modifiers: .shift), [1, 2, 3, 4], "⇧ extends")
        XCTAssertEqual(ResourceTableView.pressed(4, in: [], anchor: -1, modifiers: .shift), [4], "⇧ with nothing selected: that row")
    }

    /// A tracking area made again under a resting pointer says "entered"
    /// at the same place: no move, so no hold (Activity's 6.7).
    @MainActor
    func testAnEnterWhereThePointerRestsIsNoMove() {
        let here = NSPoint(x: 1012.1171875, y: 658.21484375)
        XCTAssertFalse(ResourceTableView.moved(to: here, from: here), "the same place")
        XCTAssertFalse(ResourceTableView.moved(to: NSPoint(x: here.x + 0.25, y: here.y), from: here), "rounding")
        XCTAssertTrue(ResourceTableView.moved(to: NSPoint(x: here.x + 3, y: here.y), from: here), "moved")
        XCTAssertTrue(ResourceTableView.moved(to: here, from: nil), "never seen")
        XCTAssertTrue(ResourceTableView.moved(to: nil, from: here), "no window to place it")
    }

    func testARightClickMeansTheSelectionOnlyWhenOnIt() {
        typealias Table = ResourceTable<Fruit>
        let ids = rows().map(\.id)
        XCTAssertEqual(Table.Coordinator.menuTargets(clicked: 1, selected: [1, 2], ids: ids), ["apple", "apricot"])
        XCTAssertEqual(Table.Coordinator.menuTargets(clicked: 4, selected: [1, 2], ids: ids), ["banana"])
        XCTAssertEqual(Table.Coordinator.menuTargets(clicked: 9, selected: [], ids: ids), [])
    }

    func testDockersRowsAreGroupedAsBefore() {
        func container(_ name: String, project: String?) -> ContainerSummary {
            var labels: [String: String] = [:]
            if let project {
                labels["com.docker.compose.project"] = project
                labels["com.docker.compose.service"] = name
                labels["com.docker.compose.project.config_files"] = "/w/\(project)/compose.yaml"
                labels["com.docker.compose.project.working_dir"] = "/w/\(project)"
            }
            return ContainerSummary(Id: name + "-id", Names: ["/" + name], Image: "nginx", Created: 1, Labels: labels, State: "running", Status: "Up")
        }
        let (projects, loose) = ComposeProjects.group([container("web", project: "shop"), container("db", project: "shop"), container("redis", project: nil)])
        let groups = DockerPageModel.groups(projects: projects, loose: loose, filter: DockerFilter(""), runningOnly: false)
        let rows = DockerTableRow.rows(groups, collapsed: [])
        XCTAssertEqual(rows.map(\.id), ["project:shop"] + groups[0].containers.map(\.Id) + ["loose", "redis-id"])
        XCTAssertEqual(DockerTableRow.rows(groups, collapsed: ["project:shop"]).map(\.id), ["project:shop", "loose", "redis-id"])
        XCTAssertEqual(rows.map(\.height), [28, 30, 30, 28, 30])
        XCTAssertEqual(rows.map(\.spansColumns), [true, false, false, true, false])
        XCTAssertEqual(rows.map(\.reuseKind), ["group", "container", "container", "group", "container"])
    }

    /// A cell is reused for a row of its kind in its column only: a
    /// project's row and a container's are other SwiftUI views, and so are
    /// two columns' cells. The table's own cells, scrolled through, each
    /// handed out again only for its kind and its column.
    @MainActor
    func testACellIsReusedOnlyForItsKindInItsColumn() throws {
        func container(_ name: String, project: String) -> ContainerSummary {
            let labels = [
                "com.docker.compose.project": project, "com.docker.compose.service": name,
                "com.docker.compose.project.config_files": "/w/\(project)/compose.yaml", "com.docker.compose.project.working_dir": "/w/\(project)",
            ]
            return ContainerSummary(
                Id: "\(project)-\(name)-id", Names: ["/\(project)-\(name)"], Image: "nginx", Created: 1, Labels: labels, State: "running", Status: "Up")
        }
        let summaries = (0..<40).flatMap { index in ["web", "db"].map { container($0, project: "acme-\(index)") } }
        let (projects, loose) = ComposeProjects.group(summaries)
        let groups = DockerPageModel.groups(projects: projects, loose: loose, filter: DockerFilter(""), runningOnly: false)
        let docker = DockerTableRow.rows(groups, collapsed: [])
        XCTAssertGreaterThan(docker.count, 100)
        let list = ResourceTable<DockerTableRow>(
            rows: docker, selection: .constant([]), cell: { _ in AnyView(Text(verbatim: "row")) }, verbs: { _ in [] }, copy: {})
        let handedOut = try scrolledThrough(list, rows: docker)
        XCTAssertEqual(Set(handedOut.values.map(\.kind)), ["group", "container"])
        XCTAssertTrue(handedOut.values.allSatisfy { $0.column == "-" }, "one column, no header")

        // Columns under a header: a basket spans them, its fruit's cells are
        // each their column's.
        let fruit: [Fruit] = (0..<60).flatMap { index in [Fruit.basket("b\(index)"), .fruit("f\(index)", weight: index)] }
        let columns = ["name", "weight"].map { ResourceColumn(id: $0, title: $0) }
        let table = ResourceTable<Fruit>(
            rows: fruit, selection: .constant([]), columns: columns, sort: .constant(nil), cell: { _, _ in AnyView(Text(verbatim: "cell")) },
            verbs: { _ in [] }, copy: {})
        let cells = try scrolledThrough(table, rows: fruit)
        XCTAssertEqual(Set(cells.values.map(\.column)), ["-", "name", "weight"])
        XCTAssertTrue(cells.values.filter { $0.column == "-" }.allSatisfy { $0.kind == "row" })
    }

    /// Every cell the table shows while `list` is scrolled top to bottom,
    /// by the cell, with the column and kind it was first handed out for;
    /// fails if one is shown again for another, or carries another's
    /// identifier.
    @MainActor
    private func scrolledThrough<Row: ResourceTableRow>(_ list: ResourceTable<Row>, rows: [Row]) throws -> [ObjectIdentifier: (column: String, kind: String)] {
        let coordinator = list.makeCoordinator()
        let table = ResourceTableView()
        table.dataSource = coordinator
        table.delegate = coordinator
        table.intercellSpacing = .zero
        coordinator.table = table
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scroll.documentView = table
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = scroll
        coordinator.update(list)
        table.sizeLastColumnToFit()

        var seen: [ObjectIdentifier: (column: String, kind: String)] = [:]
        var offset: CGFloat = 0
        var reused = false
        repeat {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            window.layoutIfNeeded()
            table.layoutSubtreeIfNeeded()
            let visible = table.rows(in: table.visibleRect)
            XCTAssertGreaterThan(visible.length, 0)
            for index in visible.location..<min(visible.location + visible.length, rows.count) {
                for at in 0..<table.numberOfColumns {
                    guard let cell = table.view(atColumn: at, row: index, makeIfNecessary: false) as? ResourceHostingCell else { continue }
                    let spans = table.numberOfColumns > 1 && rows[index].spansColumns
                    let column = table.numberOfColumns > 1 && !spans ? table.tableColumns[at].identifier.rawValue : "-"
                    let wanted = (column: column, kind: rows[index].reuseKind)
                    XCTAssertEqual(cell.identifier, ResourceHostingCell.identifier(column: column == "-" ? nil : column, kind: wanted.kind))
                    if let first = seen[ObjectIdentifier(cell)] {
                        reused = true
                        XCTAssertTrue(first == wanted, "a \(first) cell handed out for a \(wanted) row")
                    } else {
                        seen[ObjectIdentifier(cell)] = wanted
                    }
                }
            }
            offset += 90
        } while offset < table.bounds.height
        XCTAssertTrue(reused, "the table reused cells as it scrolled")
        return seen
    }

    /// A refresh finds each column where the table shows it: after a header
    /// is dragged elsewhere, the model's order is not the table's.
    @MainActor
    func testARefreshFindsAColumnWhereTheUserMovedIt() {
        let columns = ["name", "status", "age"].map { ResourceColumn(id: $0, title: $0) }
        let table = NSTableView()
        for column in columns { table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))) }
        table.moveColumn(2, toColumn: 0)
        let placed = ResourceTable<Fruit>.placed(columns, in: table)
        XCTAssertEqual(placed.map(\.column.id), ["name", "status", "age"])
        XCTAssertEqual(placed.map(\.at), [1, 2, 0])
        for (at, column) in placed { XCTAssertEqual(table.tableColumns[at].identifier.rawValue, column.id) }

        table.removeTableColumn(table.tableColumns[0])
        XCTAssertEqual(ResourceTable<Fruit>.placed(columns, in: table).map(\.column.id), ["name", "status"])
    }

    /// Rows reordered in place (a CPU sort every tick): rows added or taken
    /// at the end only, a row on screen remade only where its kind or span
    /// changed, another's height noted; nothing else is reloaded.
    func testRowsMoveInPlace() {
        typealias Shape = ResourceTable<Fruit>.Coordinator.RowShape
        let row = Shape(height: 24, kind: "process", spans: false)
        let group = Shape(height: 24, kind: "group", spans: true)
        let tall = Shape(height: 40, kind: "process", spans: false)
        let plan = ResourceTable<Fruit>.Coordinator.inPlace(old: [group, row, row, row, row], new: [group, row, group, tall], made: IndexSet(0..<3))
        XCTAssertEqual(plan.removed, IndexSet([4]))
        XCTAssertEqual(plan.added, IndexSet())
        XCTAssertEqual(plan.remade, IndexSet([2]), "on screen and now a group")
        XCTAssertEqual(plan.heights, IndexSet([3]))
        let grown = ResourceTable<Fruit>.Coordinator.inPlace(old: [row], new: [row, row, group], made: IndexSet(0..<1))
        XCTAssertEqual(grown.added, IndexSet([1, 2]))
        XCTAssertTrue(grown.remade.isEmpty)
        let offscreen = ResourceTable<Fruit>.Coordinator.inPlace(old: [row, row], new: [row, group], made: IndexSet(0..<1))
        XCTAssertTrue(offscreen.remade.isEmpty, "no view: made as it scrolls in")
        let prepared = ResourceTable<Fruit>.Coordinator.inPlace(old: [row, row, row], new: [row, row, group], made: IndexSet([0, 2]))
        XCTAssertEqual(prepared.remade, IndexSet([2]), "a view prepared off screen is remade too")
    }

    /// Rows of one height moved in place: only the rows with a view are
    /// looked at — gaps in them too —, no height is noted.
    func testRowsOfOneHeightMoveInPlaceLookingOnlyAtThoseMade() {
        var asked: [Int] = []
        let plan = ResourceTable<Fruit>.Coordinator.inPlace(oldCount: 6, newCount: 4, made: IndexSet([0, 2, 3, 5])) { index in
            asked.append(index)
            return index == 3
        }
        XCTAssertEqual(asked, [0, 2, 3], "the made rows both lists have, and only those")
        XCTAssertEqual(plan.remade, IndexSet([3]))
        XCTAssertEqual(plan.removed, IndexSet([4, 5]))
        XCTAssertTrue(plan.added.isEmpty)
        XCTAssertTrue(plan.heights.isEmpty)
        let grown = ResourceTable<Fruit>.Coordinator.inPlace(oldCount: 1, newCount: 3, made: IndexSet([0])) { _ in false }
        XCTAssertEqual(grown.added, IndexSet([1, 2]))
    }

    /// The selection found through the page's index of the rows, or walked
    /// without one: the same rows; an index that names another row's
    /// place is not believed.
    func testTheSelectionIsFoundThroughTheIndex() {
        let fruit: [Fruit] = (0..<20).map { (index: Int) in .fruit("f\(index)", weight: index) }
        let index = Dictionary(uniqueKeysWithValues: fruit.enumerated().map { ($1.id, $0) })
        let selection: Set<String> = ["f3", "f17", "gone"]
        XCTAssertEqual(ResourceTable<Fruit>.Coordinator.wanted(selection, index: { index[$0] }, rows: fruit), IndexSet([3, 17]))
        XCTAssertEqual(ResourceTable<Fruit>.Coordinator.wanted(selection, index: nil, rows: fruit), IndexSet([3, 17]))
        XCTAssertEqual(ResourceTable<Fruit>.Coordinator.wanted([], index: { index[$0] }, rows: fruit), IndexSet())
        XCTAssertEqual(ResourceTable<Fruit>.Coordinator.wanted(["f3"], index: { _ in 5 }, rows: fruit), IndexSet(), "a stale index")
    }

    /// A row the table prepared beyond the visible rect (responsive
    /// scrolling) is a row with a view: moved in place, it is handed its
    /// new row — never left drawing the one that sat there, which a press
    /// or ↩, resolved by index, would then act on.
    @MainActor
    func testARowPreparedOffScreenTakesItsNewRow() throws {
        let columns = ["name", "weight"].map { ResourceColumn(id: $0, title: $0) }
        func list(_ fruit: [Fruit]) -> ResourceTable<Fruit> {
            ResourceTable<Fruit>(
                rows: fruit, selection: .constant([]), columns: columns, sort: .constant(nil), cell: { _, _ in AnyView(Text(verbatim: "cell")) },
                verbs: { _ in [] }, copy: {})
        }
        let first: [Fruit] = (0..<60).map { (index: Int) in .fruit("f\(index)", weight: index) }
        let coordinator = list(first).makeCoordinator()
        let table = ResourceTableView()
        table.dataSource = coordinator
        table.delegate = coordinator
        table.intercellSpacing = .zero
        coordinator.table = table
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scroll.documentView = table
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = scroll
        coordinator.update(list(first))
        table.layoutSubtreeIfNeeded()
        let visible = table.rows(in: table.visibleRect)
        let offscreen = visible.location + visible.length + 3
        // Prepared as responsive scrolling prepares it: views beyond the
        // visible rect, none of them on screen.
        _ = try XCTUnwrap(table.rowView(atRow: offscreen, makeIfNecessary: true))
        XCTAssertFalse(ResourceTable<Fruit>.Coordinator.shows(offscreen, in: visible))
        XCTAssertTrue(ResourceTable<Fruit>.Coordinator.madeRows(in: table).contains(offscreen), "a prepared row has a view")

        // Reversed: every row moves; the prepared one's cells say the new row.
        let moved = Array(first.reversed())
        coordinator.update(list(moved))
        XCTAssertEqual(table.reloads, 1, "the first rows only")
        XCTAssertEqual(table.reorders, 1)
        for at in 0..<table.numberOfColumns {
            let cell = try XCTUnwrap(table.view(atColumn: at, row: offscreen, makeIfNecessary: false))
            XCTAssertEqual(cell.accessibilityIdentifier(), moved[offscreen].id)
        }
        // Now a basket there: the prepared row is made again, spanning.
        var grouped = moved
        grouped[offscreen] = .basket("acme")
        coordinator.update(list(grouped))
        let fruitCells = Set(columns.map { ResourceHostingCell.identifier(column: $0.id, kind: Fruit.basket("acme").reuseKind) })
        let left = (0..<table.numberOfColumns).compactMap { table.view(atColumn: $0, row: offscreen, makeIfNecessary: false)?.identifier }
        XCTAssertFalse(left.contains { fruitCells.contains($0) }, "no fruit's cell left where the basket now is")
    }

    /// The selection moving with its rows stays where the person left the
    /// list unless followed; a selection made is brought into view once.
    @MainActor
    func testOnlyAFollowedSelectionIsKeptInView() {
        let columns = ["name", "weight"].map { ResourceColumn(id: $0, title: $0) }
        func list(_ fruit: [Fruit], selected: String, follow: Bool) -> ResourceTable<Fruit> {
            ResourceTable<Fruit>(
                rows: fruit, selection: .constant([selected]), columns: columns, sort: .constant(nil),
                cell: { _, _ in AnyView(Text(verbatim: "cell")) }, verbs: { _ in [] }, copy: {}
            )
            .with { $0.follow = follow }
        }
        let fruit: [Fruit] = (0..<60).map { (index: Int) in .fruit("f\(index)", weight: index) }
        let coordinator = list(fruit, selected: "f0", follow: false).makeCoordinator()
        let table = ResourceTableView()
        table.dataSource = coordinator
        table.delegate = coordinator
        table.intercellSpacing = .zero
        coordinator.table = table
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scroll.documentView = table
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = scroll
        coordinator.update(list(fruit, selected: "f0", follow: false))
        table.layoutSubtreeIfNeeded()
        XCTAssertEqual(table.selectedRow, 0)
        let top = scroll.contentView.bounds.origin.y

        // Re-sorted: the selected row moves to the end, off screen.
        let reversed = Array(fruit.reversed())
        coordinator.update(list(reversed, selected: "f0", follow: false))
        XCTAssertEqual(table.selectedRow, 59, "still selected, by id")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, top, "not followed: the list stays where it was")
        // Followed: brought into view as it moves.
        coordinator.update(list(fruit, selected: "f0", follow: true))
        coordinator.update(list(reversed, selected: "f0", follow: true))
        XCTAssertTrue(table.rows(in: table.visibleRect).contains(59), "followed: in view")
        // A selection made elsewhere is brought into view once, unfollowed.
        scroll.contentView.scroll(to: .zero)
        coordinator.update(list(reversed, selected: "f1", follow: false))
        XCTAssertTrue(table.rows(in: table.visibleRect).contains(58), "a new selection is shown")
    }

    func testAShownRowIsWhollyInsideTheVisibleRange() {
        XCTAssertTrue(ResourceTable<Fruit>.Coordinator.shows(3, in: NSRange(location: 2, length: 5)))
        XCTAssertFalse(ResourceTable<Fruit>.Coordinator.shows(7, in: NSRange(location: 2, length: 5)))
        XCTAssertFalse(ResourceTable<Fruit>.Coordinator.shows(0, in: NSRange(location: 0, length: 0)))
    }

    /// A list whose weights are AppKit text (`plainCell`) and names hosted.
    @MainActor
    private func plainTable(_ fruit: [Fruit], selection: Binding<Set<String>>, key: ((Fruit, ResourceColumn?) -> Int)? = nil, made: @escaping () -> Void = {})
        -> ResourceTable<Fruit>
    {
        let columns = ["name", "weight"].map { ResourceColumn(id: $0, title: $0) }
        return ResourceTable<Fruit>(
            rows: fruit, selection: selection, columns: columns, sort: .constant(nil),
            cell: { _, _ in
                made()
                return AnyView(Text(verbatim: "cell"))
            }, verbs: { _ in [] }, copy: {}
        )
        .with { table in
            table.plainCell = { row, column in
                guard column.id == "weight", case .fruit(_, let weight) = row else { return nil }
                return ResourceTextCellValue(text: weight.map { String($0) } ?? "—", color: .labelColor, size: 12, number: true)
            }
            table.cellKey = key
        }
    }

    @MainActor
    private func hosted<Row: ResourceTableRow>(_ list: ResourceTable<Row>) -> (ResourceTable<Row>.Coordinator, ResourceTableView, NSWindow) {
        let coordinator = list.makeCoordinator()
        let table = ResourceTableView()
        table.dataSource = coordinator
        table.delegate = coordinator
        table.intercellSpacing = .zero
        coordinator.table = table
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scroll.documentView = table
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.update(list)
        table.layoutSubtreeIfNeeded()
        return (coordinator, table, window)
    }

    /// A text cell takes a row's press as a hosted one does: selected on
    /// release, ⌘ toggling, and it answers for every point inside it — the
    /// table's own mouseDown never selects, so a press falling through to
    /// it would select nothing.
    @MainActor
    func testAPressOnATextCellSelectsItsRowOnRelease() throws {
        final class Picked { var ids: Set<String> = [] }
        let picked = Picked()
        let selection = Binding(get: { picked.ids }, set: { picked.ids = $0 })
        let fruit: [Fruit] = (0..<20).map { (index: Int) in .fruit("f\(index)", weight: index) }
        let (coordinator, table, window) = hosted(plainTable(fruit, selection: selection))
        defer {
            window.close()
            withExtendedLifetime(coordinator) {}
        }
        let at = table.column(withIdentifier: NSUserInterfaceItemIdentifier("weight"))
        let cell = try XCTUnwrap(table.view(atColumn: at, row: 3, makeIfNecessary: false) as? ResourceTextCell)
        XCTAssertEqual(cell.shown?.text, "3")
        XCTAssertTrue(cell.acceptsFirstMouse(for: nil), "the first click in a window behind others selects")
        let middle = NSPoint(x: cell.frame.midX, y: cell.frame.midY)
        XCTAssertTrue(cell.hitTest(middle) === cell, "the cell, never its words, takes the press")
        // As a real press finds it, from the window's frame view: a table
        // hands a press to a view in a row only when that view says it may.
        let frameView = try XCTUnwrap(window.contentView?.superview)
        let inWindow = cell.convert(NSPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: nil)
        XCTAssertTrue(
            frameView.hitTest(frameView.convert(inWindow, from: nil)) === cell, "the window's press reaches the cell, not the table, which selects nothing")
        // Room past the last column, whatever the table's own widths: its
        // columns narrowed under a table as wide as the window, inset as
        // the pages' tables are (AppKit lays a view of its own in the row).
        table.style = .inset
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for column in table.tableColumns {
            column.minWidth = 20
            column.width = 60
        }
        table.layoutSubtreeIfNeeded()
        let rowView = try XCTUnwrap(table.rowView(atRow: 3, makeIfNecessary: false))
        let last = try XCTUnwrap(rowView.subviews.filter { $0 is NSTableCellView }.map(\.frame.maxX).max())
        let room = NSPoint(x: (last + rowView.bounds.maxX) / 2, y: rowView.bounds.midY)
        XCTAssertGreaterThan(rowView.bounds.maxX - last, 20, "room past the last column, to press")
        XCTAssertTrue(
            table.hitTest(rowView.convert(room, to: table.superview)) === table, "a row's room no cell covers is the table's, to select")
        let roomInWindow = rowView.convert(room, to: nil)
        XCTAssertTrue(frameView.hitTest(frameView.convert(roomInWindow, from: nil)) === table, "the window's press there reaches the table")
        func press(_ modifiers: NSEvent.ModifierFlags) {
            let point = cell.convert(NSPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1)!
                if type == .leftMouseDown {
                    cell.mouseDown(with: event)
                    XCTAssertTrue(picked.ids.isEmpty || modifiers.contains(.command), "nothing selected while pressed")
                } else {
                    cell.mouseUp(with: event)
                }
            }
        }
        press([])
        XCTAssertEqual(picked.ids, ["f3"], "selected on release, by id")
        press(.command)
        XCTAssertEqual(picked.ids, [], "⌘ takes it away again")
    }

    /// A view laid in a row beside its cells — AppKit lays one in an inset
    /// table's row, over the room past the last column — never takes a
    /// press there: the table does, to select the row (the cells keep
    /// theirs).
    @MainActor
    func testAViewInARowBesideItsCellsLeavesItsRoomToTheTable() throws {
        let fruit: [Fruit] = (0..<20).map { (index: Int) in .fruit("f\(index)", weight: index) }
        let (coordinator, table, window) = hosted(plainTable(fruit, selection: .constant([])))
        defer {
            window.close()
            withExtendedLifetime(coordinator) {}
        }
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for column in table.tableColumns {
            column.minWidth = 20
            column.width = 60
        }
        table.layoutSubtreeIfNeeded()
        let rowView = try XCTUnwrap(table.rowView(atRow: 3, makeIfNecessary: false))
        let stray = NSView(frame: rowView.bounds.insetBy(dx: 10, dy: 0))
        rowView.addSubview(stray, positioned: .below, relativeTo: nil)
        let last = try XCTUnwrap(rowView.subviews.filter { $0 is NSTableCellView }.map(\.frame.maxX).max())
        let room = NSPoint(x: (last + stray.frame.maxX) / 2, y: rowView.bounds.midY)
        XCTAssertTrue(rowView.hitTest(rowView.convert(room, to: rowView.superview)) === stray, "the view lies over the room")
        XCTAssertTrue(table.hitTest(rowView.convert(room, to: table.superview)) === table, "the row's room is the table's, to select")
        let at = table.column(withIdentifier: NSUserInterfaceItemIdentifier("weight"))
        let cell = try XCTUnwrap(table.view(atColumn: at, row: 3, makeIfNecessary: false) as? ResourceTextCell)
        let middle = cell.convert(NSPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: table.superview)
        XCTAssertTrue(table.hitTest(middle) === cell, "a cell keeps its press")
    }

    /// A text cell is drawn again only when its words changed; a hosted cell
    /// whose key is the same isn't handed its row again; a nil key always is.
    @MainActor
    func testUnchangedCellsAreNotShownAgain() throws {
        final class Count { var made = 0 }
        let count = Count()
        let fruit: [Fruit] = (0..<20).map { (index: Int) in .fruit("f\(index)", weight: index) }
        let key: (Fruit, ResourceColumn?) -> Int = { row, _ in row.id.hashValue }
        let (coordinator, table, window) = hosted(plainTable(fruit, selection: .constant([]), key: key, made: { count.made += 1 }))
        defer { window.close() }
        let visible = table.rows(in: table.visibleRect).length
        XCTAssertGreaterThan(visible, 0)
        let (made, plain) = (count.made, table.plainShows)
        coordinator.update(plainTable(fruit, selection: .constant([]), key: key, made: { count.made += 1 }))
        XCTAssertEqual(count.made, made, "the same keys: no name cell made again")
        XCTAssertEqual(table.plainShows, plain, "the same words: no text cell drawn again")
        XCTAssertGreaterThanOrEqual(table.plainSkips, visible)

        var heavier = fruit
        heavier[1] = .fruit("f1", weight: 100)
        coordinator.update(plainTable(heavier, selection: .constant([]), key: key, made: { count.made += 1 }))
        XCTAssertEqual(table.plainShows, plain + 1, "one weight changed: one text cell drawn")
        let at = table.column(withIdentifier: NSUserInterfaceItemIdentifier("weight"))
        XCTAssertEqual((table.view(atColumn: at, row: 1, makeIfNecessary: false) as? ResourceTextCell)?.shown?.text, "100")

        // Rows moved in place: each cell says its new row, a key changed.
        coordinator.update(plainTable(Array(heavier.reversed()), selection: .constant([]), key: key, made: { count.made += 1 }))
        XCTAssertEqual((table.view(atColumn: at, row: 1, makeIfNecessary: false) as? ResourceTextCell)?.shown?.text, "18")
        XCTAssertGreaterThan(count.made, made, "moved rows' name cells handed their new rows")

        let unkeyed = count.made
        coordinator.update(plainTable(Array(heavier.reversed()), selection: .constant([]), made: { count.made += 1 }))
        XCTAssertEqual(count.made, unkeyed + visible, "no key: every name cell on screen handed its row, as before")
    }

    /// A row equal to what its view showed, under the same look, is passed
    /// over whole; a changed row, or a new look, is shown again.
    @MainActor
    func testAnEqualRowIsPassedOverUntilTheLookChanges() throws {
        final class Count { var asked = 0 }
        let count = Count()
        func list(_ fruit: [Fruit], look: Int) -> ResourceTable<Fruit> {
            plainTable(fruit, selection: .constant([])).with { table in
                let plain = table.plainCell
                table.plainCell = { row, column in
                    count.asked += 1
                    return plain?(row, column)
                }
                table.skipsEqualRows = true
                table.look = look
            }
        }
        let fruit: [Fruit] = (0..<20).map { (index: Int) in .fruit("f\(index)", weight: index) }
        let (coordinator, table, window) = hosted(list(fruit, look: 1))
        defer {
            window.close()
            withExtendedLifetime(coordinator) {}
        }
        XCTAssertTrue(table.rowView(atRow: 0, makeIfNecessary: false) is ResourceRowView)
        let visible = table.rows(in: table.visibleRect).length
        count.asked = 0
        coordinator.update(list(fruit, look: 1))
        XCTAssertEqual(count.asked, 0, "no row changed: no cell asked")
        XCTAssertGreaterThanOrEqual(table.rowSkips, visible)
        var heavier = fruit
        heavier[2] = .fruit("f2", weight: 99)
        coordinator.update(list(heavier, look: 1))
        XCTAssertEqual(count.asked, 1, "the changed row alone, its one text column")
        let at = table.column(withIdentifier: NSUserInterfaceItemIdentifier("weight"))
        XCTAssertEqual((table.view(atColumn: at, row: 2, makeIfNecessary: false) as? ResourceTextCell)?.shown?.text, "99")
        count.asked = 0
        coordinator.update(list(heavier, look: 2))
        XCTAssertGreaterThanOrEqual(count.asked, visible, "a new look: every row shown again")
    }
}
