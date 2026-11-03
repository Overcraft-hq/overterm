import AppKit
import SwiftUI

/// A row of a page's resource list: a group's own row or one of what it
/// holds. Its `id` is the selection's tag, as the page's model keeps it.
protocol ResourceTableRow: Equatable {
    var id: String { get }
    var height: CGFloat { get }
    /// A group's row, laid across every column of a table that has more
    /// than one (the server's columns); a lone column's rows span it anyway.
    var spansColumns: Bool { get }
}

extension ResourceTableRow {
    var spansColumns: Bool { false }
}

/// A column of a resource table. One column and no header is Docker's
/// containers list (its row draws its own cells, under a SwiftUI header);
/// several are a header the table draws — the server's Table columns, for
/// Kubernetes.
struct ResourceColumn: Equatable, Sendable {
    var id: String
    var title: String
    var width: CGFloat = 120
    var minWidth: CGFloat = 40
    /// A click on its title sorts by it.
    var sortable = true
    /// Help over its title.
    var help: String? = nil

    /// The one column of a list whose rows draw everything themselves.
    static let row = ResourceColumn(id: "row", title: "", sortable: false)
}

/// A list's order: by a column, either way.
struct ResourceSort: Equatable, Sendable {
    var column: String
    var ascending = true

    /// The order after a click on `column`'s title: by it, ascending; the
    /// same column clicked again, the other way.
    func clicked(_ column: String) -> ResourceSort {
        column == self.column ? ResourceSort(column: column, ascending: !ascending) : ResourceSort(column: column)
    }

    /// `items` in this order by `key`, those with equal keys (and those
    /// with none, last either way) in the order they came. Pure.
    func sorted<Item, Key: Comparable>(_ items: [Item], by key: (Item) -> Key?) -> [Item] {
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
enum ResourceGrouping {
    static func rows<Group, Row>(
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
struct ResourceTable<Row: ResourceTableRow>: NSViewRepresentable {
    let rows: [Row]
    @Binding var selection: Set<String>
    var columns: [ResourceColumn] = [.row]
    /// The order the header shows; nil for a list that has no header or
    /// sorts elsewhere.
    var sort: Binding<ResourceSort?> = .constant(nil)
    /// A row's view in a column (a spanning row's, column nil); the page
    /// makes it, with what it observes.
    let cell: (Row, ResourceColumn?) -> AnyView
    /// The right-click menu's verbs for these rows.
    let verbs: (Set<String>) -> [ResourceVerb]
    /// ⌘C: the selection, as the page copies it.
    let copy: () -> Void
    var accessibilityIdentifier = "resource.list"

    /// A list of one column, its rows drawing everything (Docker's).
    init(
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
    init(
        rows: [Row], selection: Binding<Set<String>>, columns: [ResourceColumn], sort: Binding<ResourceSort?>,
        cell: @escaping (Row, ResourceColumn?) -> AnyView, verbs: @escaping (Set<String>) -> [ResourceVerb], copy: @escaping () -> Void,
        accessibilityIdentifier: String = "resource.list"
    ) {
        self.rows = rows
        self._selection = selection
        self.columns = columns
        self.sort = sort
        self.cell = cell
        self.verbs = verbs
        self.copy = copy
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    /// A header only for more than one column.
    var hasHeader: Bool { columns.count > 1 }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Each column with where the table shows it now, by identifier: a header
    /// dragged to another place moves the table's column, not the model's, so
    /// the index into `columns` is not the table's once the user reorders.
    static func placed(_ columns: [ResourceColumn], in table: NSTableView) -> [(at: Int, column: ResourceColumn)] {
        columns.compactMap { column in
            let at = table.column(withIdentifier: NSUserInterfaceItemIdentifier(column.id))
            return at >= 0 ? (at, column) : nil
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
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
        table.setAccessibilityIdentifier(accessibilityIdentifier)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        weak var table: ResourceTableView?
        private var rows: [Row] = []
        private var columns: [ResourceColumn] = []
        private var view: ResourceTable?
        /// Set while the table's selection is set from the model's.
        private var settingSelection = false
        /// Set while the table's sort is set from the model's.
        private var settingSort = false

        func update(_ view: ResourceTable) {
            self.view = view
            guard let table else { return }
            table.copySelection = view.copy
            if view.columns != columns { setColumns(view, in: table) }
            if view.rows.map(\.id) != rows.map(\.id) {
                rows = view.rows
                table.reloadData()
            } else {
                // The same rows with newer values (a status, CPU and
                // memory), or the same values whose look comes from
                // elsewhere (the theme, a platform read): only those on
                // screen are drawn again.
                rows = view.rows
                showVisible(view, in: table)
            }
            let wanted = IndexSet(rows.indices.filter { view.selection.contains(rows[$0].id) })
            if wanted != table.selectedRowIndexes {
                settingSelection = true
                table.selectRowIndexes(wanted, byExtendingSelection: false)
                if let first = wanted.first, !table.rows(in: table.visibleRect).contains(first) { table.scrollRowToVisible(first) }
                settingSelection = false
            }
            if view.hasHeader { showSort(view.sort.wrappedValue, in: table) }
        }

        private func setColumns(_ view: ResourceTable, in table: NSTableView) {
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
        }

        private func showSort(_ sort: ResourceSort?, in table: NSTableView) {
            let wanted = sort.map { [NSSortDescriptor(key: $0.column, ascending: $0.ascending)] } ?? []
            guard wanted != table.sortDescriptors else { return }
            settingSort = true
            table.sortDescriptors = wanted
            settingSort = false
        }

        private func showVisible(_ view: ResourceTable, in table: NSTableView) {
            let visible = table.rows(in: table.visibleRect)
            for index in visible.location..<min(visible.location + visible.length, rows.count) {
                if spans(rows[index]) {
                    (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ResourceHostingCell)?.show(view.cell(rows[index], nil))
                    continue
                }
                for (at, column) in ResourceTable.placed(columns, in: table) {
                    (table.view(atColumn: at, row: index, makeIfNecessary: false) as? ResourceHostingCell)?
                        .show(view.cell(rows[index], view.hasHeader ? column : nil))
                }
            }
        }

        /// A group's row across a header's columns.
        private func spans(_ row: Row) -> Bool { columns.count > 1 && row.spansColumns }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].height }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows.indices.contains(row) && spans(rows[row]) }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let view else { return nil }
            let column = tableColumn.flatMap { item in columns.first { $0.id == item.identifier.rawValue } }
            let cell =
                tableView.makeView(withIdentifier: ResourceHostingCell.identifier, owner: nil) as? ResourceHostingCell ?? ResourceHostingCell()
            cell.identifier = ResourceHostingCell.identifier
            cell.show(view.cell(rows[row], view.hasHeader && !spans(rows[row]) ? column : nil))
            cell.setAccessibilityIdentifier(rows[row].id)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !settingSelection, let table, let view else { return }
            let picked = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
            if picked != view.selection { view.selection = picked }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !settingSort, let view, let first = tableView.sortDescriptors.first, let key = first.key else { return }
            let sort = ResourceSort(column: key, ascending: first.ascending)
            if sort != view.sort.wrappedValue { view.sort.wrappedValue = sort }
        }

        // MARK: The right-click menu, made as it opens

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, let view, rows.indices.contains(table.clickedRow) else { return }
            let ids = Self.menuTargets(
                clicked: table.clickedRow, selected: table.selectedRowIndexes, ids: rows.map(\.id))
            for item in ResourceVerbMenuItem.items(view.verbs(ids)) { menu.addItem(item) }
        }

        /// The rows a right-click means: on the selection, the selection's;
        /// elsewhere the row's. Pure.
        nonisolated static func menuTargets(clicked: Int, selected: IndexSet, ids: [String]) -> Set<String> {
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
final class ResourceTableView: NSTableView {
    var copySelection: () -> Void = {}

    /// Called by a row's view as a press begins on it.
    func pressRow(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return }
        selectRowIndexes(
            Self.pressed(row, in: selectedRowIndexes, anchor: selectedRow, modifiers: event.modifierFlags), byExtendingSelection: false)
    }

    /// The selection after a press on `row`: ⌘ adds or takes it away, ⇧
    /// extends from `anchor` (the selected row, -1 for none), else it
    /// alone. Pure.
    nonisolated static func pressed(_ row: Int, in selected: IndexSet, anchor: Int, modifiers: NSEvent.ModifierFlags) -> IndexSet {
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
    /// here too, selecting it again undid a ⌘-click's toggle.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if row(at: convert(event.locationInWindow, from: nil)) < 0 { deselectAll(nil) }
    }

    @objc func copy(_ sender: Any?) { copySelection() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRow >= 0 }
        return super.validateUserInterfaceItem(item)
    }
}

/// A row's cell: a SwiftUI row in a hosting view kept for the cell's life,
/// handed new rows as the cell is reused.
final class ResourceHostingCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("resource.row")
    private let hosting = ResourceRowHostingView(rootView: AnyView(EmptyView()))

    init() {
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
    required init?(coder: NSCoder) { fatalError() }

    func show(_ row: AnyView) { hosting.rootView = row }
}

/// A row's hosting view: the press goes to SwiftUI whole, and its row is
/// selected once it is released (the table's `pressRow`). Selected as it
/// began, the page drew the row again mid-press and its button (a
/// project's chevron) lost the click.
final class ResourceRowHostingView: NSHostingView<AnyView> {
    private var down: NSEvent?

    /// The first click in a window behind others selects, as a table's
    /// does; taken for bringing the window forward, it selected nothing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var table: ResourceTableView? {
        var view = superview
        while let current = view, !(current is ResourceTableView) { view = current.superview }
        return view as? ResourceTableView
    }

    override func mouseDown(with event: NSEvent) {
        down = event
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if let down {
            self.down = nil
            table?.pressRow(down)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // The table's menu, for the row clicked: its `clickedRow`.
        if let table { table.rightMouseDown(with: event) } else { super.rightMouseDown(with: event) }
    }
}
