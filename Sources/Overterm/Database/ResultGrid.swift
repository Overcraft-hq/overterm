import AppKit
import SwiftUI

/// A result's rows in a grid: NSTableView, because a SwiftUI list of a few
/// thousand rows and dozens of columns isn't one that scrolls. Columns are
/// made from the result; a header click sorts; ⌘C copies the selected rows
/// as tab-separated text, the menu in the other formats.
struct ResultGrid: NSViewRepresentable {
    let result: QueryResult
    let theme: ChromeTheme
    /// Where INSERT statements are written into, for Copy as INSERT.
    let table: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = GridTableView()
        table.coordinator = context.coordinator
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.style = .plain
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.menu = context.coordinator.menu(for: table)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.theme = theme
        context.coordinator.tableName = table
        context.coordinator.show(result)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        var theme: ChromeTheme?
        var tableName = "table_name"
        private var shown: QueryResult?
        private(set) var columns: [String] = []
        private(set) var rows: [[String?]] = []

        func show(_ result: QueryResult) {
            guard let table, result != shown else { return }
            shown = result
            columns = result.columns
            rows = result.rows
            for column in table.tableColumns.reversed() { table.removeTableColumn(column) }
            let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
            for (index, name) in result.columns.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
                column.title = name
                column.headerToolTip = index < result.types.count ? "\(name) — \(result.types[index])" : name
                column.sortDescriptorPrototype = NSSortDescriptor(key: "\(index)", ascending: true)
                // As wide as its widest of the first rows, within reason.
                let sample = result.rows.prefix(200).map { ($0[safe: index] ?? nil) ?? "NULL" } + [name]
                let widest = sample.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 60
                column.width = min(max(widest + 18, 50), 420)
                table.addTableColumn(column)
            }
            table.reloadData()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let index = Int(tableColumn.identifier.rawValue) else { return nil }
            let id = NSUserInterfaceItemIdentifier("cell")
            let field =
                (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField)
                ?? {
                    let field = NSTextField(labelWithString: "")
                    field.identifier = id
                    field.lineBreakMode = .byTruncatingTail
                    field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
                    return field
                }()
            let value = rows[safe: row]?[safe: index] ?? nil
            field.stringValue = value.map { $0.replacingOccurrences(of: "\n", with: "⏎ ") } ?? "NULL"
            field.textColor = value == nil ? .tertiaryLabelColor : .labelColor
            field.toolTip = value.map { $0.count > 60 ? String($0.prefix(2000)) : "" }
            return field
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let column = descriptor.key.flatMap(Int.init) else { return }
            rows = ResultExport.sorted(shown?.rows ?? [], by: column, ascending: descriptor.ascending)
            tableView.reloadData()
        }

        // MARK: Copying

        func selectedRows() -> [[String?]] {
            guard let table else { return [] }
            let picked = table.selectedRowIndexes.isEmpty ? IndexSet(rows.indices) : table.selectedRowIndexes
            return picked.compactMap { rows[safe: $0] }
        }

        func copy(_ format: ResultExport.Format, header: Bool = true) {
            let text = ResultExport.text(format, columns: columns, rows: selectedRows(), table: tableName, header: header)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        func menu(for table: NSTableView) -> NSMenu {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem("Copy") { [weak self] in self?.copy(.tsv, header: false) })
            menu.addItem(ClosureMenuItem("Copy with Column Names") { [weak self] in self?.copy(.tsv) })
            menu.addItem(
                ClosureMenuItem("Copy Value") { [weak self, weak table] in
                    guard let self, let table, table.clickedRow >= 0, table.clickedColumn >= 0,
                        let index = Int(table.tableColumns[table.clickedColumn].identifier.rawValue)
                    else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString((self.rows[safe: table.clickedRow]?[safe: index] ?? nil) ?? "", forType: .string)
                })
            menu.addItem(.separator())
            for format in [ResultExport.Format.csv, .json, .markdown, .insert] {
                menu.addItem(ClosureMenuItem("Copy as \(format.title)") { [weak self] in self?.copy(format) })
            }
            return menu
        }
    }
}

/// ⌘C in the grid: the selected rows, tab-separated.
final class GridTableView: NSTableView {
    weak var coordinator: ResultGrid.Coordinator?

    @objc func copy(_ sender: Any?) {
        coordinator?.copy(.tsv, header: false)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
