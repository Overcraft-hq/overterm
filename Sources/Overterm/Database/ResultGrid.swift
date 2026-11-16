import AppKit
import SwiftUI

/// A result's rows in a grid: NSTableView, because a SwiftUI list of a few
/// thousand rows and dozens of columns isn't one that scrolls. Columns are
/// made from the result; a header click sorts; ⌘C copies the selected rows
/// as tab-separated text, the menu in the other formats.
///
/// With an editor whose rows can be edited (`ResultEditor`), a cell is
/// edited in place (a double-click; a value of several lines in a sheet),
/// rows are added, duplicated, deleted — each change marked until it is
/// saved or discarded: an edited cell tinted, a deleted row struck through,
/// a new row green, its unset cells DEFAULT.
struct ResultGrid: NSViewRepresentable {
    let result: QueryResult
    let theme: ChromeTheme
    /// Where INSERT statements are written into, for Copy as INSERT.
    let table: String
    /// The rows' editor; nil, or not editable: the grid only reads.
    var editor: ResultEditor? = nil
    /// The editor's pending changes and state, so a change redraws the grid.
    var edits: PendingEdits? = nil
    var editable: EditableResult? = nil

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
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        table.setAccessibilityIdentifier("resultGrid")
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
        context.coordinator.update(result, editor: editor, edits: edits ?? PendingEdits(), editable: editable)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        weak var table: NSTableView?
        var theme: ChromeTheme?
        var tableName = "table_name"
        private var shown: QueryResult?
        private(set) var columns: [String] = []
        /// The result's rows, as read.
        private(set) var source: [[String?]] = []
        /// The rows' order on screen: indexes into `source`.
        private(set) var order: [Int] = []
        private weak var editor: ResultEditor?
        private(set) var edits = PendingEdits()
        private(set) var editable: EditableResult?
        /// The cell being edited in place, and its text when editing began.
        private var editing: (row: Int, column: Int, start: String)?

        /// A row on screen: one read, or one added.
        enum Place: Equatable {
            case read(Int)
            case added(Int)
        }

        func update(_ result: QueryResult, editor: ResultEditor?, edits: PendingEdits, editable: EditableResult?) {
            self.editor = editor
            let changed = edits != self.edits || editable != self.editable
            self.edits = edits
            self.editable = editable
            if result != shown {
                show(result)
            } else if changed, editing == nil {
                table?.reloadData()
            }
        }

        func show(_ result: QueryResult) {
            guard let table else { return }
            shown = result
            columns = result.columns
            source = result.rows
            order = Array(result.rows.indices)
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

        // MARK: Rows

        func place(_ row: Int) -> Place? {
            if order.indices.contains(row) { return .read(order[row]) }
            let added = row - order.count
            return edits.inserted.indices.contains(added) ? .added(added) : nil
        }

        /// A cell's value as it stands — edited, or as read; nil for an added
        /// row's column left to its default.
        func value(_ place: Place, column: Int) -> CellValue? {
            switch place {
            case .read(let row): edits.value(row: row, column: column) ?? CellValue(source[safe: row]?[safe: column] ?? nil)
            case .added(let index): edits.inserted[safe: index]?[column]
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { order.count + edits.inserted.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let index = Int(tableColumn.identifier.rawValue), let place = place(row) else { return nil }
            let id = NSUserInterfaceItemIdentifier("cell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? GridCell) ?? GridCell(identifier: id)
            cell.textField?.delegate = self
            cell.show(value(place, column: index), marking: marking(place, column: index))
            return cell
        }

        private func marking(_ place: Place, column: Int) -> GridCell.Marking {
            switch place {
            case .read(let row):
                if edits.deleted.contains(row) { return .deleted }
                return edits.isEdited(row: row, column: column) ? .edited : .none
            case .added(let index): return edits.inserted[safe: index]?[column] == nil ? .addedDefault : .added
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let column = descriptor.key.flatMap(Int.init) else { return }
            order = ResultExport.sortedIndexes(source, by: column, ascending: descriptor.ascending)
            tableView.reloadData()
        }

        // MARK: Copying

        func selectedRows() -> [[String?]] {
            guard let table else { return [] }
            let picked = table.selectedRowIndexes.isEmpty ? IndexSet(0..<numberOfRows(in: table)) : table.selectedRowIndexes
            return picked.compactMap { row in place(row).map { place in columns.indices.map { value(place, column: $0)?.text } } }
        }

        func copy(_ format: ResultExport.Format, header: Bool = true) {
            let text = ResultExport.text(format, columns: columns, rows: selectedRows(), table: tableName, header: header)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        // MARK: The menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            let row = table.clickedRow
            let column = table.clickedColumn >= 0 ? Int(table.tableColumns[table.clickedColumn].identifier.rawValue) : nil
            menu.addItem(ClosureMenuItem("Copy") { [weak self] in self?.copy(.tsv, header: false) })
            menu.addItem(ClosureMenuItem("Copy with Column Names") { [weak self] in self?.copy(.tsv) })
            menu.addItem(
                ClosureMenuItem("Copy Value") { [weak self] in
                    guard let self, let column, let place = self.place(row) else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(self.value(place, column: column)?.text ?? "", forType: .string)
                })
            menu.addItem(.separator())
            for format in [ResultExport.Format.csv, .json, .markdown, .insert] {
                menu.addItem(ClosureMenuItem("Copy as \(format.title)") { [weak self] in self?.copy(format) })
            }
            guard let editable, editor != nil else { return }
            menu.addItem(.separator())
            let rows = targetRows(clicked: row)
            if let column, let place = place(row) {
                let canEdit = editable.isEditable(column) && marking(place, column: column) != .deleted
                menu.addItem(ClosureMenuItem("Edit Value…", enabled: canEdit) { [weak self] in self?.editInSheet(row: row, column: column) })
                menu.addItem(ClosureMenuItem("Set to NULL", enabled: canEdit) { [weak self] in self?.set(row: row, column: column, to: .null) })
                menu.addItem(ClosureMenuItem("Set to Empty String", enabled: canEdit) { [weak self] in self?.set(row: row, column: column, to: .text("")) })
                if case .added = place {
                    let title = editable.removesFields ? "Leave Unset" : "Set to DEFAULT"
                    menu.addItem(ClosureMenuItem(title, enabled: canEdit) { [weak self] in self?.set(row: row, column: column, to: nil) })
                } else if editable.removesFields {
                    menu.addItem(ClosureMenuItem("Remove Field", enabled: canEdit) { [weak self] in self?.set(row: row, column: column, to: .absent) })
                }
                menu.addItem(.separator())
            }
            menu.addItem(ClosureMenuItem("Add Row") { [weak self] in self?.editor?.addRow() })
            let read = rows.compactMap { if case .read(let index)? = place($0) { index } else { nil } }
            let added = rows.compactMap { if case .added(let index)? = place($0) { index } else { nil } }
            menu.addItem(
                ClosureMenuItem(read.count > 1 ? "Duplicate \(read.count) Rows" : "Duplicate Row", enabled: !read.isEmpty) { [weak self] in
                    self?.editor?.duplicate(read)
                })
            let count = read.count + added.count
            menu.addItem(
                ClosureMenuItem(count > 1 ? "Delete \(count) Rows" : "Delete Row", enabled: count > 0) { [weak self] in
                    self?.editor?.delete(read, new: added)
                })
            let changed = read.filter { edits.deleted.contains($0) || edits.updates[$0] != nil }
            menu.addItem(
                ClosureMenuItem("Revert", enabled: !changed.isEmpty || !added.isEmpty) { [weak self] in self?.editor?.revert(changed, new: added) }
            )
        }

        /// The selection when the clicked row is in it, else the clicked row.
        private func targetRows(clicked: Int) -> [Int] {
            guard let table, clicked >= 0 else { return [] }
            return table.selectedRowIndexes.contains(clicked) ? Array(table.selectedRowIndexes) : [clicked]
        }

        // MARK: Editing

        private func set(row: Int, column: Int, to value: CellValue?) {
            switch place(row) {
            case .read(let index)?: editor?.set(row: index, column: column, to: value ?? .null)
            case .added(let index)?: editor?.set(new: index, column: column, to: value)
            case nil: break
            }
        }

        private func canEdit(row: Int, column: Int) -> Bool {
            guard let editable, editor != nil, let place = place(row) else { return false }
            return editable.isEditable(column) && marking(place, column: column) != .deleted
        }

        /// A double-click edits the cell in place — or, a value of several
        /// lines, in a sheet.
        @objc func doubleClicked(_ sender: Any?) {
            guard let table, table.clickedRow >= 0, table.clickedColumn >= 0,
                let column = Int(table.tableColumns[table.clickedColumn].identifier.rawValue)
            else { return }
            beginEditing(row: table.clickedRow, column: column)
        }

        func beginEditing(row: Int, column: Int) {
            guard let table, canEdit(row: row, column: column), let place = place(row),
                let at = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "\(column)" })
            else { return }
            let text = value(place, column: column)?.text ?? ""
            if text.contains(where: \.isNewline) { return editInSheet(row: row, column: column) }
            guard let cell = table.view(atColumn: at, row: row, makeIfNecessary: true) as? GridCell, let field = cell.textField else { return }
            editing = (row, column, text)
            field.isEditable = true
            field.stringValue = text
            field.textColor = .labelColor
            table.editColumn(at, row: row, with: nil, select: true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let editing else { return }
            self.editing = nil
            field.isEditable = false
            if field.stringValue != editing.start { set(row: editing.row, column: editing.column, to: .text(field.stringValue)) }
            table?.reloadData(forRowIndexes: [editing.row], columnIndexes: IndexSet(integersIn: 0..<(table?.numberOfColumns ?? 0)))
        }

        /// Esc: the edit is dropped, the cell as it was.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)), let field = control as? NSTextField, let editing else { return false }
            self.editing = nil
            field.abortEditing()
            field.isEditable = false
            table?.reloadData(forRowIndexes: [editing.row], columnIndexes: IndexSet(integersIn: 0..<(table?.numberOfColumns ?? 0)))
            return true
        }

        /// A value in a sheet of its own: several lines, or NULL.
        func editInSheet(row: Int, column: Int) {
            guard let window = table?.window, canEdit(row: row, column: column), let place = place(row) else { return }
            let alert = NSAlert()
            alert.messageText = columns[safe: column] ?? "Value"
            alert.informativeText = "Set writes the text as it is; NULL is no value at all."
            alert.addButton(withTitle: "Set")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Set to NULL")
            let scroll = NSTextView.scrollableTextView()
            scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 180)
            let text = scroll.documentView as? NSTextView
            text?.string = value(place, column: column)?.text ?? ""
            text?.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            text?.isAutomaticQuoteSubstitutionEnabled = false
            text?.isAutomaticDashSubstitutionEnabled = false
            text?.isAutomaticTextReplacementEnabled = false
            alert.accessoryView = scroll
            alert.window.initialFirstResponder = text
            alert.beginSheetModal(for: window) { [weak self] response in
                let typed = text?.string ?? ""
                MainActor.assumeIsolated {
                    switch response {
                    case .alertFirstButtonReturn: self?.set(row: row, column: column, to: .text(typed))
                    case .alertThirdButtonReturn: self?.set(row: row, column: column, to: .null)
                    default: break
                    }
                }
            }
        }
    }
}

/// One cell: its text field, the value's look (NULL grey, DEFAULT grey and
/// italic) and the change's tint.
final class GridCell: NSTableCellView {
    enum Marking { case none, edited, deleted, added, addedDefault }

    convenience init(identifier: NSUserInterfaceItemIdentifier) {
        self.init(frame: .zero)
        self.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        field.drawsBackground = true
        field.backgroundColor = .clear
        field.isEditable = false
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = field
    }

    static let editedTint = NSColor.systemOrange.withAlphaComponent(0.28)
    static let deletedTint = NSColor.systemRed.withAlphaComponent(0.22)
    static let addedTint = NSColor.systemGreen.withAlphaComponent(0.22)

    func show(_ value: CellValue?, marking: Marking) {
        guard let field = textField else { return }
        field.isEditable = false
        let text: String
        var color = NSColor.labelColor
        var font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        switch value {
        case .text(let string)?: text = string.replacingOccurrences(of: "\n", with: "⏎ ")
        case .null?:
            text = "NULL"
            color = .tertiaryLabelColor
        case nil:
            text = "DEFAULT"
            color = .tertiaryLabelColor
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        case .absent?:
            text = "(removed)"
            color = .tertiaryLabelColor
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        field.font = font
        field.textColor = color
        field.toolTip = value?.text.flatMap { $0.count > 60 ? String($0.prefix(2000)) : nil }
        switch marking {
        case .none:
            field.backgroundColor = .clear
            field.attributedStringValue = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        case .edited:
            field.backgroundColor = Self.editedTint
            field.attributedStringValue = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        case .deleted:
            field.backgroundColor = Self.deletedTint
            field.attributedStringValue = NSAttributedString(
                string: text, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .strikethroughStyle: NSUnderlineStyle.single.rawValue])
        case .added, .addedDefault:
            field.backgroundColor = Self.addedTint
            field.attributedStringValue = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
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
