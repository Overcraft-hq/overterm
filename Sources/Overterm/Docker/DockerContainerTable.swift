import AppKit
import SwiftUI

/// A row of the containers list: a group's own row (a compose project, a
/// test run, the rest), one of its containers, or a service of a project
/// that hasn't run.
enum DockerTableRow: Equatable {
    case group(DockerListGroup)
    case container(ContainerSummary, group: DockerListGroup)
    case service(ComposeService, group: DockerListGroup)

    /// The selection's tag, as the page's model keeps it.
    var id: String {
        switch self {
        case .group(let group): group.id
        case .container(let container, _): container.Id
        case .service(let service, _): DockerPageModel.serviceTag(service)
        }
    }

    var height: CGFloat {
        switch self {
        case .group: 28
        case .container, .service: 30
        }
    }

    /// The list's rows: each group's row, then — unless it is folded — its
    /// containers and its services not yet created. Pure.
    static func rows(_ groups: [DockerListGroup], collapsed: Set<String>) -> [DockerTableRow] {
        var rows: [DockerTableRow] = []
        for group in groups {
            rows.append(.group(group))
            guard !collapsed.contains(group.id) else { continue }
            rows += group.containers.map { .container($0, group: group) }
            rows += group.services.map { .service($0, group: group) }
        }
        return rows
    }
}

/// The containers list as an AppKit table: a row is a view only while it
/// is on screen, and one scrolled in takes the view of one scrolled out —
/// the same SwiftUI row, handed its new values, not made again. As a
/// SwiftUI `List`, 160 containers took 39 ms a scroll step (30 once its
/// menus left the rows): every row built whole as it came in.
struct DockerContainerTable: NSViewRepresentable {
    let rows: [DockerTableRow]
    @Binding var selection: Set<String>
    /// A row's view; the page makes it, with what it observes.
    let cell: (DockerTableRow) -> AnyView
    /// The right-click menu's verbs for these rows.
    let verbs: (Set<String>) -> [ResourceVerb]
    /// ⌘C: the selected containers' names.
    let copy: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = DockerTableView()
        table.headerView = nil
        table.style = .inset
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsTypeSelect = false
        table.focusRingType = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        table.setAccessibilityIdentifier("docker.list")
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
        weak var table: DockerTableView?
        private var rows: [DockerTableRow] = []
        private var view: DockerContainerTable?
        /// Set while the table's selection is set from the model's.
        private var settingSelection = false

        func update(_ view: DockerContainerTable) {
            self.view = view
            guard let table else { return }
            table.copyNames = view.copy
            if view.rows.map(\.id) != rows.map(\.id) {
                rows = view.rows
                table.reloadData()
            } else if view.rows != rows {
                // The same rows, newer values (a status, CPU and memory):
                // only those on screen are drawn again.
                rows = view.rows
                let visible = table.rows(in: table.visibleRect)
                for index in visible.location..<min(visible.location + visible.length, rows.count) {
                    (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? DockerHostingCell)?.show(view.cell(rows[index]))
                }
            } else {
                // The values the rows show may come from elsewhere (the
                // theme, a platform read): those on screen are asked again.
                let visible = table.rows(in: table.visibleRect)
                for index in visible.location..<min(visible.location + visible.length, rows.count) {
                    (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? DockerHostingCell)?.show(view.cell(rows[index]))
                }
            }
            let wanted = IndexSet(rows.indices.filter { view.selection.contains(rows[$0].id) })
            if wanted != table.selectedRowIndexes {
                settingSelection = true
                table.selectRowIndexes(wanted, byExtendingSelection: false)
                if let first = wanted.first, !table.rows(in: table.visibleRect).contains(first) { table.scrollRowToVisible(first) }
                settingSelection = false
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].height }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let view else { return nil }
            let cell = tableView.makeView(withIdentifier: DockerHostingCell.identifier, owner: nil) as? DockerHostingCell ?? DockerHostingCell()
            cell.identifier = DockerHostingCell.identifier
            cell.show(view.cell(rows[row]))
            cell.setAccessibilityIdentifier(rows[row].id)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !settingSelection, let table, let view else { return }
            let picked = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
            if picked != view.selection { view.selection = picked }
        }

        // MARK: The right-click menu, made as it opens

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, let view, rows.indices.contains(table.clickedRow) else { return }
            let clicked = table.clickedRow
            // On the selection, it is the selection's; elsewhere the row's.
            let ids =
                table.selectedRowIndexes.contains(clicked)
                ? Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil }) : [rows[clicked].id]
            for item in ResourceVerbMenuItem.items(view.verbs(ids)) { menu.addItem(item) }
        }
    }
}

/// The list's table: ⌘C copies the selected containers' names, and a
/// disabled item stays disabled (the menu doesn't validate by target).
///
/// A press on a row goes to the row's SwiftUI view — its buttons (a
/// project's chevron, its Up) take it as any — and selects the row once
/// released (`pressRow`): ⌘ adds or takes one away, ⇧ extends. Left to
/// the table, a press on a row's text selected it only sometimes, the
/// hosting view or the table taking it as it happened.
final class DockerTableView: NSTableView {
    var copyNames: () -> Void = {}

    /// Called by a row's view as a press begins on it.
    func pressRow(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return }
        var rows = selectedRowIndexes
        if event.modifierFlags.contains(.command) {
            if rows.contains(row) { rows.remove(row) } else { rows.insert(row) }
        } else if event.modifierFlags.contains(.shift), selectedRow >= 0 {
            rows.formUnion(IndexSet(integersIn: min(selectedRow, row)...max(selectedRow, row)))
        } else {
            rows = [row]
        }
        selectRowIndexes(rows, byExtendingSelection: false)
    }

    /// A press on no row clears the selection. One on a row is its
    /// view's, selected on release (`DockerRowHostingView`); passed up here
    /// too, selecting it again undid a ⌘-click's toggle.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if row(at: convert(event.locationInWindow, from: nil)) < 0 { deselectAll(nil) }
    }

    @objc func copy(_ sender: Any?) { copyNames() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRow >= 0 }
        return super.validateUserInterfaceItem(item)
    }
}

/// A row's cell: a SwiftUI row in a hosting view kept for the cell's life,
/// handed new rows as the cell is reused.
final class DockerHostingCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("docker.row")
    private let hosting = DockerRowHostingView(rootView: AnyView(EmptyView()))

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
final class DockerRowHostingView: NSHostingView<AnyView> {
    private var down: NSEvent?

    /// The first click in a window behind others selects, as a table's
    /// does; taken for bringing the window forward, it selected nothing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var table: DockerTableView? {
        var view = superview
        while let current = view, !(current is DockerTableView) { view = current.superview }
        return view as? DockerTableView
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
