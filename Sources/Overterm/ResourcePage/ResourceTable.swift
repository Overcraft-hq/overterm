import AppKit
import SwiftUI

/// A row of a page's resource list: a group's own row or one of what it
/// holds. Its `id` is the selection's tag, as the page's model keeps it.
package protocol ResourceTableRow: Equatable {
    var id: String { get }
    var height: CGFloat { get }
    /// A group's row, laid across every column of a table that has more
    /// than one (the server's columns); a lone column's rows span it anyway.
    var spansColumns: Bool { get }
    /// Which of the list's row views it is (a group's, a container's): a
    /// cell is reused only for a row of its kind, in its column.
    var reuseKind: String { get }
}

extension ResourceTableRow {
    package var spansColumns: Bool { false }
    package var reuseKind: String { "row" }
}

/// A column of a resource table. One column and no header is Docker's
/// containers list (its row draws its own cells, under a SwiftUI header);
/// several are a header the table draws — the server's Table columns, for
/// Kubernetes.
package struct ResourceColumn: Equatable, Sendable {
    package var id: String
    package var title: String
    package var width: CGFloat = 120
    package var minWidth: CGFloat = 40
    /// A click on its title sorts by it.
    package var sortable = true
    /// Help over its title.
    package var help: String? = nil

    /// The one column of a list whose rows draw everything themselves.
    package static let row = ResourceColumn(id: "row", title: "", sortable: false)
}

/// What a person is doing with a list (`ResourceTable.interacting`): the
/// pointer over it, a press, its menu. A page whose order moves on its own
/// (a CPU sort) holds it while these last, or a press resolved at release,
/// or a menu's targets, could land on another row (Activity, 6.7).
package enum ResourceTableInteraction: Equatable, Sendable {
    /// The pointer moved over the list, or came onto it.
    case hover
    /// It left the list.
    case exit
    case pressBegan, pressEnded
    case menuOpened, menuClosed
}

/// A list's order: by a column, either way.
package struct ResourceSort: Equatable, Sendable {
    package var column: String
    package var ascending = true

    /// The order after a click on `column`'s title: by it, ascending; the
    /// same column clicked again, the other way.
    package func clicked(_ column: String) -> ResourceSort {
        column == self.column ? ResourceSort(column: column, ascending: !ascending) : ResourceSort(column: column)
    }

    /// `items` in this order by `key`, those with equal keys (and those
    /// with none, last either way) in the order they came. Pure.
    package func sorted<Item, Key: Comparable>(_ items: [Item], by key: (Item) -> Key?) -> [Item] {
        let keyed = items.map(key)
        return items.indices
            .sorted { a, b in
                switch (keyed[a], keyed[b]) {
                case (let x?, let y?) where x != y: ascending ? x < y : x > y
                case (.some, nil): true
                case (nil, .some): false
                default: a < b
                }
            }
            .map { items[$0] }
    }
}

/// A grouped list's rows: each group's own row, then — unless it is
/// folded — what it holds. Pure.
package enum ResourceGrouping {
    package static func rows<Group, Row>(
        _ groups: [Group], collapsed: Set<String>, id: (Group) -> String, header: (Group) -> Row, members: (Group) -> [Row]
    ) -> [Row] {
        var rows: [Row] = []
        for group in groups {
            rows.append(header(group))
            guard !collapsed.contains(id(group)) else { continue }
            rows += members(group)
        }
        return rows
    }
}

/// A page's resource list as an AppKit table: a row is a view only while
/// it is on screen, and one scrolled in takes the view of one scrolled
/// out — the same SwiftUI row, handed its new values, not made again. As
/// a SwiftUI `List`, Docker's 160 containers took 39 ms a scroll step (30
/// once its menus left the rows): every row built whole as it came in.
///
/// The selection is the model's set of row ids; the right-click menu is
/// the clicked rows' verbs (`ResourceVerb`); ⌘C is the page's. With more
/// than one column the table draws their header, and a click on a title
/// sets `sort`.
package struct ResourceTable<Row: ResourceTableRow>: NSViewRepresentable {
    package let rows: [Row]
    @Binding package var selection: Set<String>
    package var columns: [ResourceColumn] = [.row]
    /// The order the header shows; nil for a list that has no header or
    /// sorts elsewhere.
    package var sort: Binding<ResourceSort?> = .constant(nil)
    /// A row's view in a column (a spanning row's, column nil); the page
    /// makes it, with what it observes.
    package let cell: (Row, ResourceColumn?) -> AnyView
    /// The right-click menu's verbs for these rows.
    package let verbs: (Set<String>) -> [ResourceVerb]
    /// ⌘C: the selection, as the page copies it.
    package let copy: () -> Void
    package var accessibilityIdentifier = "resource.list"
    /// A plain click on a row (no ⌘ or ⇧), once it is selected: what the
    /// page opens for it (Kubernetes' detail). Nil: a click only selects.
    package var pressed: ((String) -> Void)? = nil
    /// What VoiceOver says of a row, set on its row view: nil leaves the
    /// cells to speak for themselves.
    package var accessibilityLabel: ((Row) -> String)? = nil
    /// The pointer, a press, the menu (`ResourceTableInteraction`).
    package var interacting: ((ResourceTableInteraction) -> Void)? = nil
    /// A header dragged to another place or resized by the person: every
    /// column in the table's order now, with its width — the page keeps
    /// them, or the next change of its columns loses the move.
    package var columnsChanged: (([ResourceColumn]) -> Void)? = nil
    /// The header's right-click menu: every column the page offers, each
    /// ticked while shown, `toggleColumn` with its id when picked. Nil: no
    /// menu.
    package var columnChoices: [ResourceColumn]? = nil
    package var toggleColumn: ((String) -> Void)? = nil
    /// ← and → on the selected row (its id; true for →): whether it folded
    /// or unfolded something. False, or nil, leaves the key to the table.
    package var fold: ((String, Bool) -> Bool)? = nil
    /// The selected row kept in view as the rows change under it.
    package var follow = false
    /// A token of the rows' ids in their order, made with them: equal to
    /// the last update's, the ids aren't compared one by one (Activity's
    /// 5,000 rows, 7.7). Nil: compared.
    package var order: Int? = nil
    /// A row's place by its id, made with the rows: the selection found
    /// through it, not by a walk of every row. Nil: walked.
    package var index: ((String) -> Int?)? = nil
    /// Every row is the same height: a move in place notes no height and
    /// looks only at the rows with a view.
    package var uniformHeight = false
    /// A cell that is one line of text, drawn by AppKit rather than a
    /// hosting view each (`ResourceTextCell`): its words, or nil for a
    /// column the `cell` draws. Whether it answers nil may depend only on
    /// the row's kind and the column — a cell is reused by both. Nil: every
    /// cell is the `cell`'s (Docker's, Kubernetes').
    package var plainCell: ((Row, ResourceColumn) -> ResourceTextCellValue?)? = nil
    /// A cell an AppKit view of the page's draws (`ResourceDrawnCell`), or
    /// nil; asked before `plainCell`, by the same rule.
    package var drawnCell: ((Row, ResourceColumn) -> ResourceDrawnCell?)? = nil
    /// A key of what a hosted cell draws (`cell`): a cell shown with the
    /// same key isn't handed its row again. Nil: always handed it.
    package var cellKey: ((Row, ResourceColumn?) -> Int)? = nil
    /// A row equal to the one its view last showed, under the same `look`,
    /// isn't shown again — none of its cells is asked for its words. Only
    /// for rows that hold everything their cells draw; `look` the rest (the
    /// theme, the text size, a clock a cell reads). Off: every row with a
    /// view is shown at every update.
    package var skipsEqualRows = false
    package var look = 0
    /// The list takes whatever room it is offered, told so (`sizeThatFits`):
    /// asked its size otherwise, SwiftUI had AppKit fit the scroll view's
    /// whole subtree by its constraints at every update of the page.
    package var fillsProposal = false

    /// This table with `change` made: the options above, set in place.
    package func with(_ change: (inout ResourceTable) -> Void) -> ResourceTable {
        var table = self
        change(&table)
        return table
    }

    /// A list of one column, its rows drawing everything (Docker's).
    package init(
        rows: [Row], selection: Binding<Set<String>>, cell: @escaping (Row) -> AnyView, verbs: @escaping (Set<String>) -> [ResourceVerb],
        copy: @escaping () -> Void, accessibilityIdentifier: String = "resource.list"
    ) {
        self.rows = rows
        self._selection = selection
        self.cell = { row, _ in cell(row) }
        self.verbs = verbs
        self.copy = copy
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    /// A list of columns under a header the table draws.
    package init(
        rows: [Row], selection: Binding<Set<String>>, columns: [ResourceColumn], sort: Binding<ResourceSort?>,
        cell: @escaping (Row, ResourceColumn?) -> AnyView, verbs: @escaping (Set<String>) -> [ResourceVerb], copy: @escaping () -> Void,
        accessibilityIdentifier: String = "resource.list", pressed: ((String) -> Void)? = nil, accessibilityLabel: ((Row) -> String)? = nil
    ) {
        self.rows = rows
        self._selection = selection
        self.columns = columns
        self.sort = sort
        self.cell = cell
        self.verbs = verbs
        self.copy = copy
        self.accessibilityIdentifier = accessibilityIdentifier
        self.pressed = pressed
        self.accessibilityLabel = accessibilityLabel
    }

    /// A header only for more than one column.
    package var hasHeader: Bool { columns.count > 1 }

    package func makeCoordinator() -> Coordinator { Coordinator() }

    /// Each column with where the table shows it now, by identifier: a header
    /// dragged to another place moves the table's column, not the model's, so
    /// the index into `columns` is not the table's once the user reorders.
    package static func placed(_ columns: [ResourceColumn], in table: NSTableView) -> [(at: Int, column: ResourceColumn)] {
        columns.compactMap { column in
            let at = table.column(withIdentifier: NSUserInterfaceItemIdentifier(column.id))
            return at >= 0 ? (at, column) : nil
        }
    }

    package func makeNSView(context: Context) -> NSScrollView {
        let table = ResourceTableView()
        table.headerView = nil
        table.style = .inset
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsTypeSelect = false
        table.focusRingType = .none
        table.floatsGroupRows = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        context.coordinator.rowMenu = menu
        table.setAccessibilityIdentifier(accessibilityIdentifier)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        // Columns at their least widths still wider than the list: scrolled
        // sideways, never drawn clipped.
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        return scroll
    }

    package func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    package func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard fillsProposal else { return nil }
        return proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 240))
    }

    @MainActor
    package final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        package weak var table: ResourceTableView?
        package weak var rowMenu: NSMenu?
        private var headerMenu: NSMenu?
        /// Set while the table's columns are made from the model's.
        private var settingColumns = false
        private var rows: [Row] = []
        private var columns: [ResourceColumn] = []
        private var view: ResourceTable?
        /// Set while the table's selection is set from the model's.
        private var settingSelection = false
        /// Set while the table's sort is set from the model's.
        private var settingSort = false
        /// The selection, by id, as the last update found it.
        private var shownSelection: Set<String> = []
        /// The last update's `order`.
        private var shownOrder: Int?

        package func update(_ view: ResourceTable) {
            self.view = view
            guard let table else { return }
            table.updates += 1
            table.copySelection = view.copy
            table.pressedRow = { [weak self] index in
                guard let self, self.rows.indices.contains(index) else { return }
                self.view?.pressed?(self.rows[index].id)
            }
            table.interaction = view.interacting
            table.foldRow =
                view.fold.map { fold in
                    { [weak self] index, open in
                        guard let self, self.rows.indices.contains(index) else { return false }
                        return fold(self.rows[index].id, open)
                    }
                }
            let columnsMade = view.columns != columns
            if columnsMade { setColumns(view, in: table) }
            let sameOrder =
                if let order = view.order, order == shownOrder, view.rows.count == rows.count { true } else { view.rows.map(\.id) == rows.map(\.id) }
            shownOrder = view.order
            if !sameOrder {
                let old = rows
                rows = view.rows
                if columnsMade || old.isEmpty || rows.isEmpty {
                    table.reloads += 1
                    table.reloadData()
                } else {
                    // The rows moved (a CPU sort every tick, a fold): the
                    // row views on screen stay and are handed their new
                    // rows. `reloadData` took every one off the window and
                    // put it back — 1,300 processes re-sorted cost 270 ms a
                    // tick, a row's SwiftUI torn down with its view.
                    reorder(from: old, view, in: table)
                }
            } else {
                // The same rows with newer values (a status, CPU and
                // memory), or the same values whose look comes from
                // elsewhere (the theme, a platform read): only those on
                // screen are drawn again.
                rows = view.rows
                showVisible(view, in: table)
            }
            let wanted = Self.wanted(view.selection, index: view.index, rows: rows)
            // A selection made — a press, a link, a reveal — is brought into
            // view once; the same selection moving with its rows only when
            // followed (`follow`), or the list jumps to it at every re-sort.
            // A row a reveal selected before its rows came stays to bring
            // into view once they do.
            let picked = view.selection != shownSelection
            if !wanted.isEmpty || view.selection.isEmpty { shownSelection = view.selection }
            if wanted != table.selectedRowIndexes {
                settingSelection = true
                table.selectRowIndexes(wanted, byExtendingSelection: false)
                settingSelection = false
            }
            if picked || view.follow, let first = wanted.first, !Self.shows(first, in: table.rows(in: table.visibleRect)) {
                table.scrollRowToVisible(first)
            }
            if view.hasHeader { showSort(view.sort.wrappedValue, in: table) }
        }

        /// `old` become `rows` in place: rows added or taken at the end, a
        /// row with a view whose kind changed made again, the rest drawn
        /// with their new values.
        private func reorder(from old: [Row], _ view: ResourceTable, in table: ResourceTableView) {
            table.reorders += 1
            let made = Self.madeRows(in: table)
            let plan =
                view.uniformHeight
                ? Self.inPlace(oldCount: old.count, newCount: rows.count, made: made) { index in
                    old[index].reuseKind != rows[index].reuseKind || spans(old[index]) != spans(rows[index])
                }
                : Self.inPlace(
                    old: old.map { RowShape(height: $0.height, kind: $0.reuseKind, spans: spans($0)) },
                    new: rows.map { RowShape(height: $0.height, kind: $0.reuseKind, spans: spans($0)) }, made: made)
            settingSelection = true
            table.beginUpdates()
            if !plan.removed.isEmpty { table.removeRows(at: plan.removed, withAnimation: []) }
            if !plan.added.isEmpty { table.insertRows(at: plan.added, withAnimation: []) }
            if !plan.remade.isEmpty {
                table.removeRows(at: plan.remade, withAnimation: [])
                table.insertRows(at: plan.remade, withAnimation: [])
            }
            if !plan.heights.isEmpty { table.noteHeightOfRows(withIndexesChanged: plan.heights) }
            table.endUpdates()
            settingSelection = false
            showVisible(view, in: table)
        }

        /// What a row's place needs of its view: its height, its kind of
        /// cells, whether it spans the columns.
        package struct RowShape: Equatable {
            package let height: CGFloat
            package let kind: String
            package let spans: Bool
        }

        /// Every row the table holds a view for: those on screen and those
        /// it prepared beyond them (responsive scrolling's
        /// `preparedContentRect`) — each drawn as its row, or a press and ↩,
        /// which resolve by index, act on another process than the one
        /// drawn once it scrolls in.
        package static func madeRows(in table: NSTableView) -> IndexSet {
            var made = IndexSet()
            let visible = table.rows(in: table.visibleRect)
            if visible.length > 0 { made.insert(integersIn: visible.location..<(visible.location + visible.length)) }
            table.enumerateAvailableRowViews { _, row in if row >= 0 { made.insert(row) } }
            return made
        }

        /// How a list of `old` rows becomes `new` without a reload: rows
        /// added or removed at the end, the rows with a view (`made`) whose
        /// kind or span differ remade, heights that changed noted. Pure.
        package nonisolated static func inPlace(old: [RowShape], new: [RowShape], made: IndexSet)
            -> (added: IndexSet, removed: IndexSet, remade: IndexSet, heights: IndexSet)
        {
            let common = min(old.count, new.count)
            let added = new.count > old.count ? IndexSet(integersIn: old.count..<new.count) : IndexSet()
            let removed = old.count > new.count ? IndexSet(integersIn: new.count..<old.count) : IndexSet()
            var remade = IndexSet()
            var heights = IndexSet()
            for index in 0..<common {
                if made.contains(index), old[index].kind != new[index].kind || old[index].spans != new[index].spans {
                    remade.insert(index)
                } else if old[index].height != new[index].height {
                    heights.insert(index)
                }
            }
            return (added, removed, remade, heights)
        }

        /// `inPlace` for rows of one height: only the rows with a view
        /// (`made`) are looked at, `changed` saying whether one's kind or
        /// span differ. Pure.
        package nonisolated static func inPlace(oldCount: Int, newCount: Int, made: IndexSet, changed: (Int) -> Bool)
            -> (added: IndexSet, removed: IndexSet, remade: IndexSet, heights: IndexSet)
        {
            let common = min(oldCount, newCount)
            let added = newCount > oldCount ? IndexSet(integersIn: oldCount..<newCount) : IndexSet()
            let removed = oldCount > newCount ? IndexSet(integersIn: newCount..<oldCount) : IndexSet()
            var remade = IndexSet()
            for index in made where index < common && changed(index) { remade.insert(index) }
            return (added, removed, remade, IndexSet())
        }

        /// The rows `selection` means: through `index` where the page
        /// made one, else by a walk of the rows; none for none. Pure.
        package nonisolated static func wanted(_ selection: Set<String>, index: ((String) -> Int?)?, rows: [Row]) -> IndexSet {
            guard !selection.isEmpty else { return IndexSet() }
            guard let index else { return IndexSet(rows.indices.filter { selection.contains(rows[$0].id) }) }
            var wanted = IndexSet()
            for id in selection {
                if let at = index(id), rows.indices.contains(at), rows[at].id == id { wanted.insert(at) }
            }
            return wanted
        }

        /// Whether `row` lies inside the visible range, wholly. Pure.
        package nonisolated static func shows(_ row: Int, in visible: NSRange) -> Bool {
            visible.length > 0 && row >= visible.location && row < visible.location + visible.length
        }

        private func setColumns(_ view: ResourceTable, in table: NSTableView) {
            settingColumns = true
            defer { settingColumns = false }
            columns = view.columns
            for column in table.tableColumns { table.removeTableColumn(column) }
            for column in columns {
                let item = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
                item.title = column.title
                item.headerToolTip = column.help
                if view.hasHeader {
                    item.width = column.width
                    item.minWidth = column.minWidth
                    item.resizingMask = [.userResizingMask, .autoresizingMask]
                    if column.sortable { item.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: true) }
                } else {
                    item.resizingMask = .autoresizingMask
                }
                table.addTableColumn(item)
            }
            table.headerView = view.hasHeader ? NSTableHeaderView() : nil
            if view.columnChoices != nil, let header = table.headerView {
                let menu = NSMenu()
                menu.delegate = self
                header.menu = menu
                headerMenu = menu
            }
        }

        /// The columns as the table holds them now: its order, its widths.
        private func tableColumns(_ table: NSTableView) -> [ResourceColumn] {
            table.tableColumns.compactMap { item in
                guard var column = columns.first(where: { $0.id == item.identifier.rawValue }) else { return nil }
                column.width = item.width.rounded()
                return column
            }
        }

        package func tableViewColumnDidMove(_ notification: Notification) {
            guard !settingColumns, let table, let view, view.hasHeader else { return }
            columns = tableColumns(table)
            view.columnsChanged?(columns)
        }

        package func tableViewColumnDidResize(_ notification: Notification) {
            // The person's drag only: the table's own autoresizing as the
            // window resizes is no choice to keep.
            guard !settingColumns, let table, let view, view.hasHeader, (table.headerView?.resizedColumn ?? -1) >= 0 else { return }
            columns = tableColumns(table)
            view.columnsChanged?(columns)
        }

        private func showSort(_ sort: ResourceSort?, in table: NSTableView) {
            let wanted = sort.map { [NSSortDescriptor(key: $0.column, ascending: $0.ascending)] } ?? []
            guard wanted != table.sortDescriptors else { return }
            settingSort = true
            table.sortDescriptors = wanted
            settingSort = false
        }

        /// Every row with a view, on screen or prepared beyond it, handed
        /// its row's values.
        private func showVisible(_ view: ResourceTable, in table: ResourceTableView) {
            let made = Self.madeRows(in: table)
            table.madeRowsLastUpdate = made.count
            table.visibleRowsLastUpdate = table.rows(in: table.visibleRect).length
            let placed = ResourceTable.placed(columns, in: table)
            for index in made where index < rows.count {
                let rowView = view.skipsEqualRows ? table.rowView(atRow: index, makeIfNecessary: false) as? ResourceRowView : nil
                if let rowView, rowView.shownLook == view.look, let shown = rowView.shownRow as? Row, shown == rows[index] {
                    table.rowSkips += 1
                    continue
                }
                defer {
                    rowView?.shownRow = rows[index]
                    rowView?.shownLook = view.look
                }
                if let label = view.accessibilityLabel, let rowView = table.rowView(atRow: index, makeIfNecessary: false) {
                    let said = label(rows[index])
                    if rowView.accessibilityLabel() != said { rowView.setAccessibilityLabel(said) }
                }
                let id = rows[index].id
                if spans(rows[index]) {
                    if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ResourceHostingCell {
                        show(rows[index], nil, in: cell, view, table)
                        if cell.accessibilityIdentifier() != id { cell.setAccessibilityIdentifier(id) }
                    }
                    continue
                }
                for (at, column) in placed {
                    guard let cell = table.view(atColumn: at, row: index, makeIfNecessary: false) else { continue }
                    if let text = cell as? ResourceTextCell {
                        if let value = view.plainCell?(rows[index], column) {
                            if text.show(value) { table.plainShows += 1 } else { table.plainSkips += 1 }
                        }
                    } else if let drawn = cell as? ResourcePressCell {
                        if let content = view.drawnCell?(rows[index], column) {
                            if content.show(drawn) { table.plainShows += 1 } else { table.plainSkips += 1 }
                        }
                    } else if let hosted = cell as? ResourceHostingCell {
                        show(rows[index], view.hasHeader ? column : nil, in: hosted, view, table)
                    } else {
                        continue
                    }
                    // Moved in place: the cell says its new row.
                    if cell.accessibilityIdentifier() != id { cell.setAccessibilityIdentifier(id) }
                }
            }
        }

        /// A hosted cell handed its row, unless its key says it draws it
        /// already.
        private func show(_ row: Row, _ column: ResourceColumn?, in cell: ResourceHostingCell, _ view: ResourceTable, _ table: ResourceTableView) {
            let key = view.cellKey?(row, column)
            if let key, cell.shownKey == key {
                table.hostedSkips += 1
                return
            }
            cell.show(view.cell(row, column))
            cell.shownKey = key
            table.hostedShows += 1
        }

        /// A group's row across a header's columns.
        private func spans(_ row: Row) -> Bool { columns.count > 1 && row.spansColumns }

        package func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        package func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].height }

        package func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows.indices.contains(row) && spans(rows[row]) }

        package func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let view else { return nil }
            let column = tableColumn.flatMap { item in columns.first { $0.id == item.identifier.rawValue } }
            let shown = view.hasHeader && !spans(rows[row]) ? column : nil
            if let shown, let content = view.drawnCell?(rows[row], shown) {
                let identifier = NSUserInterfaceItemIdentifier("resource.drawn.\(shown.id).\(rows[row].reuseKind).\(content.kind)")
                let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ResourcePressCell ?? content.make()
                cell.identifier = identifier
                _ = content.show(cell)
                (tableView as? ResourceTableView)?.plainShows += 1
                cell.setAccessibilityIdentifier(rows[row].id)
                return cell
            }
            if let shown, let value = view.plainCell?(rows[row], shown) {
                let identifier = ResourceTextCell.identifier(column: shown.id, kind: rows[row].reuseKind)
                let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ResourceTextCell ?? ResourceTextCell()
                cell.identifier = identifier
                _ = cell.show(value)
                (tableView as? ResourceTableView)?.plainShows += 1
                cell.setAccessibilityIdentifier(rows[row].id)
                return cell
            }
            let identifier = ResourceHostingCell.identifier(column: shown?.id, kind: rows[row].reuseKind)
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ResourceHostingCell ?? ResourceHostingCell()
            cell.identifier = identifier
            cell.show(view.cell(rows[row], shown))
            cell.shownKey = view.cellKey?(rows[row], shown)
            (tableView as? ResourceTableView)?.hostedShows += 1
            cell.setAccessibilityIdentifier(rows[row].id)
            return cell
        }

        /// A row's view as it comes on screen: what VoiceOver says of it,
        /// and the row its cells were just made for.
        package func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
            guard rows.indices.contains(row) else { return }
            if let shown = rowView as? ResourceRowView {
                shown.shownRow = rows[row]
                shown.shownLook = view?.look ?? 0
            }
            guard let label = view?.accessibilityLabel else { return }
            rowView.setAccessibilityLabel(label(rows[row]))
        }

        /// A row view that remembers its row (`skipsEqualRows`); the table's
        /// own otherwise.
        package func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            guard view?.skipsEqualRows == true else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("resource.rowView")
            let made = tableView.makeView(withIdentifier: identifier, owner: nil) as? ResourceRowView ?? ResourceRowView()
            made.identifier = identifier
            made.shownRow = nil
            return made
        }

        package func tableViewSelectionDidChange(_ notification: Notification) {
            guard !settingSelection, let table, let view else { return }
            let picked = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
            if picked != view.selection { view.selection = picked }
        }

        package func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !settingSort, let view, let first = tableView.sortDescriptors.first, let key = first.key else { return }
            let sort = ResourceSort(column: key, ascending: first.ascending)
            if sort != view.sort.wrappedValue { view.sort.wrappedValue = sort }
        }

        // MARK: The right-click menu, made as it opens

        package func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            if menu === headerMenu {
                guard let choices = view?.columnChoices else { return }
                let shown = Set(columns.map(\.id))
                for choice in choices {
                    let item = NSMenuItem(title: choice.title.isEmpty ? choice.id : choice.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = choice.id
                    item.state = shown.contains(choice.id) ? .on : .off
                    menu.addItem(item)
                }
                return
            }
            guard let table, let view, rows.indices.contains(table.clickedRow) else { return }
            let ids = Self.menuTargets(
                clicked: table.clickedRow, selected: table.selectedRowIndexes, ids: rows.map(\.id))
            for item in ResourceVerbMenuItem.items(view.verbs(ids)) { menu.addItem(item) }
        }

        @objc package func toggleColumn(_ item: NSMenuItem) {
            guard let id = item.representedObject as? String else { return }
            view?.toggleColumn?(id)
        }

        package func menuWillOpen(_ menu: NSMenu) {
            if menu === rowMenu { view?.interacting?(.menuOpened) }
        }

        package func menuDidClose(_ menu: NSMenu) {
            if menu === rowMenu { view?.interacting?(.menuClosed) }
        }

        /// The rows a right-click means: on the selection, the selection's;
        /// elsewhere the row's. Pure.
        package nonisolated static func menuTargets(clicked: Int, selected: IndexSet, ids: [String]) -> Set<String> {
            guard ids.indices.contains(clicked) else { return [] }
            return selected.contains(clicked) ? Set(selected.compactMap { ids.indices.contains($0) ? ids[$0] : nil }) : [ids[clicked]]
        }
    }
}

/// A resource list's table: ⌘C copies the selection as the page says, and
/// a disabled item stays disabled (the menu doesn't validate by target).
///
/// A press on a row goes to the row's SwiftUI view — its buttons (a
/// project's chevron, its Up) take it as any — and selects the row once
/// released (`pressRow`): ⌘ adds or takes one away, ⇧ extends. Left to
/// the table, a press on a row's text selected it only sometimes, the
/// hosting view or the table taking it as it happened.
package final class ResourceTableView: NSTableView {
    package var copySelection: () -> Void = {}
    /// A plain click on a row, by its index, once it is selected.
    package var pressedRow: (Int) -> Void = { _ in }
    /// The pointer, a press, the menu: the page's `interacting`.
    package var interaction: ((ResourceTableInteraction) -> Void)?
    /// ← and → on the selected row, by index (true for →): whether the page
    /// folded or unfolded it.
    package var foldRow: ((Int, Bool) -> Bool)?
    /// Counted for the scenarios (`activityPerf`): whole reloads, and rows
    /// moved in place — a held order makes neither.
    package var reloads = 0
    package var reorders = 0
    /// What a publish touches (7.7), counted for the same: the page's
    /// updates of the table, the cells handed a row (each a SwiftUI
    /// update), and at the last update the rows with a view against
    /// those on screen.
    package var updates = 0
    package var hostedShows = 0
    /// Hosted cells whose key said they draw their row already, and the
    /// AppKit text cells (`ResourceTextCell`) drawn again or left as they
    /// were.
    package var hostedSkips = 0
    package var plainShows = 0
    package var plainSkips = 0
    /// Rows equal to what their view showed, passed over whole.
    package var rowSkips = 0
    package var madeRowsLastUpdate = 0
    package var visibleRowsLastUpdate = 0
    private var hover: NSTrackingArea?

    package override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hover { removeTrackingArea(hover) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hover = area
    }

    /// Where the pointer was last seen over the list, in screen points.
    /// AppKit says "entered" again each time the tracking area is made
    /// anew under a pointer at rest — a reload, a relayout, a sheet gone —
    /// several times a second while a page's rows tick; told as a move,
    /// a pointer resting on the list held its order for ever (6.7).
    private var pointerSeen: NSPoint?

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A window opened under a resting pointer: not a move either.
        pointerSeen = window == nil ? nil : NSEvent.mouseLocation
    }

    package override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hovered(event)
    }

    package override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hovered(event)
    }

    /// `.hover` only when the pointer is somewhere else than it was.
    private func hovered(_ event: NSEvent) {
        let location = window.map { $0.convertPoint(toScreen: event.locationInWindow) }
        guard Self.moved(to: location, from: pointerSeen) else { return }
        pointerSeen = location
        interaction?(.hover)
    }

    /// Whether a pointer at `location` has moved from `seen`, by more than
    /// rounding: an unknown place counts as a move. Pure.
    package nonisolated static func moved(to location: NSPoint?, from seen: NSPoint?) -> Bool {
        guard let location, let seen else { return true }
        return abs(location.x - seen.x) > 0.5 || abs(location.y - seen.y) > 0.5
    }

    package override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        interaction?(.exit)
    }

    /// ← folds the selected row, → unfolds it, where the page says it
    /// can; otherwise the table's own (Docker's list, a leaf).
    package override func keyDown(with event: NSEvent) {
        if let foldRow, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty, selectedRow >= 0,
            let key = event.specialKey, key == .leftArrow || key == .rightArrow, foldRow(selectedRow, key == .rightArrow)
        {
            return
        }
        super.keyDown(with: event)
    }

    /// Called by a row's view as a press ends on it.
    package func pressRow(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return }
        selectRowIndexes(
            Self.pressed(row, in: selectedRowIndexes, anchor: selectedRow, modifiers: event.modifierFlags), byExtendingSelection: false)
        if event.modifierFlags.intersection([.command, .shift]).isEmpty { pressedRow(row) }
    }

    /// The selection after a press on `row`: ⌘ adds or takes it away, ⇧
    /// extends from `anchor` (the selected row, -1 for none), else it
    /// alone. Pure.
    package nonisolated static func pressed(_ row: Int, in selected: IndexSet, anchor: Int, modifiers: NSEvent.ModifierFlags) -> IndexSet {
        var rows = selected
        if modifiers.contains(.command) {
            if rows.contains(row) { rows.remove(row) } else { rows.insert(row) }
        } else if modifiers.contains(.shift), anchor >= 0 {
            rows.formUnion(IndexSet(integersIn: min(anchor, row)...max(anchor, row)))
        } else {
            rows = [row]
        }
        return rows
    }

    /// A press on no row clears the selection. One on a row is its
    /// view's, selected on release (`ResourceRowHostingView`); passed up
    /// here too, selecting it again undid a ⌘-click's toggle. Only one on
    /// a row's room outside its cells comes here, and is selected here.
    package override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        interaction?(.hover)
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        if row < 0 {
            deselectAll(nil)
        } else if !cellCovers(point, row: row) {
            // A row's room no cell covers — its inset, past its last
            // column — reaches the table: selected on release, as a cell's.
            // One a hosted cell passed up is its cell's, selected there.
            roomPress = event
            interaction?(.pressBegan)
        }
    }

    /// Whether one of `row`'s cells lies under `point`, in the table's
    /// coordinates.
    private func cellCovers(_ point: NSPoint, row: Int) -> Bool {
        guard let rowView = rowView(atRow: row, makeIfNecessary: false) else { return false }
        let inRow = rowView.convert(point, from: self)
        return rowView.subviews.contains { $0 is NSTableCellView && !$0.isHidden && $0.frame.contains(inRow) }
    }

    /// A press on a row that reached the table itself, until its release.
    private var roomPress: NSEvent?

    /// A row's own view — its room no cell covers, the selection drawn
    /// there — answers as the table: the row view took the press for its
    /// own and the row was never selected.
    package override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit is NSTableRowView { return self }
        // A view AppKit lays in the row beside its cells answered for the
        // row's room past its last column, and selected nothing either:
        // only a cell, or what is in it, answers for itself.
        var view = hit
        while let up = view.superview, up !== self {
            if up is NSTableRowView { return view is NSTableCellView ? hit : self }
            view = up
        }
        return hit
    }

    /// A press on an AppKit cell (`ResourcePressCell`) is the cell's to
    /// take. A view-based table hands a press to a view in a row only when
    /// it says so here, and its own answer is no for all but controls: it
    /// hit itself instead, and its `mouseDown` selects nothing.
    package override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if responder is ResourcePressCell { return true }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    package override func mouseUp(with event: NSEvent) {
        guard let down = roomPress else { return super.mouseUp(with: event) }
        roomPress = nil
        pressRow(down)
        interaction?(.pressEnded)
    }

    @objc package func copy(_ sender: Any?) { copySelection() }

    package override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRow >= 0 }
        return super.validateUserInterfaceItem(item)
    }
}

/// A row's view that remembers the row its cells show (`skipsEqualRows`).
package final class ResourceRowView: NSTableRowView {
    package var shownRow: Any?
    package var shownLook = 0
}

/// A row's cell: a SwiftUI row in a hosting view kept for the cell's life,
/// handed new rows as the cell is reused.
package final class ResourceHostingCell: NSTableCellView {
    /// A cell's reuse identifier: a column's cells for one kind of row
    /// hold the same SwiftUI view, handed new values as they are reused.
    /// One identifier for all, a project's row reused for a container's
    /// (another type under the `AnyView`) was torn down and built whole.
    package static func identifier(column: String?, kind: String) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("resource.row.\(column ?? "-").\(kind)")
    }
    private let hosting = ResourceRowHostingView(rootView: AnyView(EmptyView()))

    package init() {
        super.init(frame: .zero)
        // The row sizes to the cell, never the cell to the row.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    /// The `cellKey` of what it was last handed; nil for none.
    package var shownKey: Int?

    package func show(_ row: AnyView) { hosting.rootView = row }

    package override func prepareForReuse() {
        super.prepareForReuse()
        shownKey = nil
    }
}

/// A row's hosting view: the press goes to SwiftUI whole, and its row is
/// selected once it is released (the table's `pressRow`). Selected as it
/// began, the page drew the row again mid-press and its button (a
/// project's chevron) lost the click.
package final class ResourceRowHostingView: NSHostingView<AnyView> {
    private var down: NSEvent?

    /// The first click in a window behind others selects, as a table's
    /// does; taken for bringing the window forward, it selected nothing.
    package override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var table: ResourceTableView? {
        var view = superview
        while let current = view, !(current is ResourceTableView) { view = current.superview }
        return view as? ResourceTableView
    }

    package override func mouseDown(with event: NSEvent) {
        down = event
        table?.interaction?(.pressBegan)
        super.mouseDown(with: event)
    }

    package override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if let down {
            self.down = nil
            table?.pressRow(down)
            table?.interaction?(.pressEnded)
        }
    }

    package override func rightMouseDown(with event: NSEvent) {
        // The table's menu, for the row clicked: its `clickedRow`.
        if let table { table.rightMouseDown(with: event) } else { super.rightMouseDown(with: event) }
    }
}
