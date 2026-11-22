import AppKit
import SwiftUI

/// A row of the review's file list: a folder's name over its files, or a file.
package enum ReviewListRow: Equatable {
    case folder(String)
    case file(ChangedFile, indented: Bool)

    /// The list's rows for files already in order (`ReviewModel.ordered`):
    /// each folder named once, above its files; files at the top level
    /// under no name.
    package static func rows(_ files: [ChangedFile]) -> [ReviewListRow] {
        var rows: [ReviewListRow] = []
        var folder: String?
        for file in files {
            let parent = (file.path as NSString).deletingLastPathComponent
            if parent != folder {
                folder = parent
                if !parent.isEmpty { rows.append(.folder(parent)) }
            }
            rows.append(.file(file, indented: !parent.isEmpty))
        }
        return rows
    }

    package var path: String? {
        if case .file(let file, _) = self { file.path } else { nil }
    }
}

/// The review's file list, as an AppKit table: only the rows on screen are
/// views, and a change reloads only the rows it touches. As SwiftUI rows
/// (a LazyVStack of folders and files, each with a tooltip and a hover),
/// 250 files took 108 ms a scroll step — every row laid out again each time.
package struct ReviewFileTable: NSViewRepresentable {
    package let rows: [ReviewListRow]
    package let selected: String?
    package let viewed: Set<String>
    @ObservedObject package var theme: ChromeTheme
    package let select: (String) -> Void
    package let toggleViewed: (String) -> Void

    package init(rows: [ReviewListRow], selected: String?, viewed: Set<String>, theme: ChromeTheme, select: @escaping (String) -> Void, toggleViewed: @escaping (String) -> Void) {
        self.rows = rows
        self.selected = selected
        self.viewed = viewed
        self._theme = ObservedObject(wrappedValue: theme)
        self.select = select
        self.toggleViewed = toggleViewed
    }

    package func makeCoordinator() -> Coordinator { Coordinator() }

    package func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.allowsTypeSelect = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.setAccessibilityIdentifier("review.files")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        context.coordinator.table = table
        return scroll
    }

    package func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    @MainActor
    package final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        package weak var table: NSTableView?
        private var rows: [ReviewListRow] = []
        private var viewed: Set<String> = []
        private var selected: String?
        private var colors = Colors()
        private var select: (String) -> Void = { _ in }
        private var toggleViewed: (String) -> Void = { _ in }
        /// Set while the table's selection is being set from the model.
        private var settingSelection = false

        package struct Colors: Equatable {
            package var text = NSColor.textColor
            package var dim = NSColor.secondaryLabelColor
            package var selected = NSColor.selectedContentBackgroundColor
        }

        package func update(_ view: ReviewFileTable) {
            guard let table else { return }
            select = view.select
            toggleViewed = view.toggleViewed
            let colors = Colors(text: view.theme.textNS, dim: NSColor(view.theme.dimText), selected: NSColor(view.theme.selected))
            if view.rows != rows || colors != self.colors {
                rows = view.rows
                self.colors = colors
                viewed = view.viewed
                table.reloadData()
            } else if view.viewed != viewed {
                let changed = view.viewed.symmetricDifference(viewed)
                viewed = view.viewed
                let indexes = IndexSet(rows.indices.filter { rows[$0].path.map(changed.contains) == true })
                table.reloadData(forRowIndexes: indexes, columnIndexes: [0])
            }
            if view.selected != selected || table.selectedRow < 0 && view.selected != nil {
                selected = view.selected
                let index = rows.firstIndex { $0.path == view.selected && view.selected != nil }
                settingSelection = true
                if let index {
                    table.selectRowIndexes([index], byExtendingSelection: false)
                    table.scrollRowToVisible(index)
                } else {
                    table.deselectAll(nil)
                }
                settingSelection = false
            }
        }

        package func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        package func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            if case .folder = rows[row] { return row == 0 ? 22 : 28 }
            return 26
        }

        package func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].path != nil }

        package func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = tableView.makeView(withIdentifier: ReviewRowView.identifier, owner: nil) as? ReviewRowView ?? ReviewRowView()
            view.identifier = ReviewRowView.identifier
            view.fill = colors.selected
            return view
        }

        package func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            switch rows[row] {
            case .folder(let name):
                let cell = tableView.makeView(withIdentifier: ReviewFolderCell.identifier, owner: nil) as? ReviewFolderCell ?? ReviewFolderCell()
                cell.identifier = ReviewFolderCell.identifier
                cell.show(name, color: colors.dim)
                return cell
            case .file(let file, let indented):
                let cell = tableView.makeView(withIdentifier: ReviewFileCell.identifier, owner: nil) as? ReviewFileCell ?? ReviewFileCell()
                cell.identifier = ReviewFileCell.identifier
                cell.show(file, indented: indented, viewed: viewed.contains(file.path), colors: colors)
                cell.onToggleViewed = { [weak self] in self?.toggleViewed(file.path) }
                return cell
            }
        }

        package func tableViewSelectionDidChange(_ notification: Notification) {
            guard !settingSelection, let table, rows.indices.contains(table.selectedRow), let path = rows[table.selectedRow].path else { return }
            selected = path
            select(path)
        }
    }
}

/// The picked file's row: a rounded fill inside the list's margins, in the
/// chrome's colour rather than the system's accent.
package final class ReviewRowView: NSTableRowView {
    package static let identifier = NSUserInterfaceItemIdentifier("review.row")
    package var fill = NSColor.selectedContentBackgroundColor

    package override func drawSelection(in dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 5, yRadius: 5).fill()
    }

    package override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

package final class ReviewFolderCell: NSTableCellView {
    package static let identifier = NSUserInterfaceItemIdentifier("review.folder")
    private let label = NSTextField(labelWithString: "")

    package init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingHead
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    package func show(_ name: String, color: NSColor) {
        label.stringValue = name
        label.textColor = color
        toolTip = name
    }
}

/// A file's row: viewed, how it changed, its name, its lines added and removed.
package final class ReviewFileCell: NSTableCellView {
    package static let identifier = NSUserInterfaceItemIdentifier("review.file")
    package var onToggleViewed: () -> Void = {}
    private let viewedButton = NSButton()
    private let letter = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let counts = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint!

    package init() {
        super.init(frame: .zero)
        viewedButton.isBordered = false
        viewedButton.imagePosition = .imageOnly
        viewedButton.target = self
        viewedButton.action = #selector(toggle)
        letter.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        letter.alignment = .center
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        counts.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        counts.alignment = .right
        counts.setContentCompressionResistancePriority(.required, for: .horizontal)
        counts.setContentHuggingPriority(.required, for: .horizontal)
        for view in [viewedButton, letter, name, counts] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        leading = viewedButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        NSLayoutConstraint.activate([
            leading,
            viewedButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            viewedButton.widthAnchor.constraint(equalToConstant: 16),
            letter.leadingAnchor.constraint(equalTo: viewedButton.trailingAnchor, constant: 4),
            letter.centerYAnchor.constraint(equalTo: centerYAnchor),
            letter.widthAnchor.constraint(equalToConstant: 12),
            name.leadingAnchor.constraint(equalTo: letter.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            counts.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            counts.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            counts.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    @objc private func toggle() { onToggleViewed() }

    package func show(_ file: ChangedFile, indented: Bool, viewed: Bool, colors: ReviewFileTable.Coordinator.Colors) {
        leading.constant = indented ? 18 : 12
        let symbol = NSImage(systemSymbolName: viewed ? "checkmark.circle.fill" : "circle", accessibilityDescription: viewed ? "Viewed" : "Not viewed")
        viewedButton.image = symbol?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        viewedButton.contentTintColor = viewed ? NSColor(DiffColors.added) : colors.dim.withAlphaComponent(0.6)
        viewedButton.toolTip = viewed ? "Viewed — v" : "Mark as Viewed — v"
        letter.stringValue = file.letter
        letter.textColor = Self.color(of: file.kind)
        name.stringValue = (file.path as NSString).lastPathComponent
        name.textColor = viewed ? colors.dim : colors.text
        let text = NSMutableAttributedString()
        if let added = file.added, added > 0 {
            text.append(NSAttributedString(string: "+\(added)", attributes: [.foregroundColor: NSColor(DiffColors.added)]))
        }
        if let removed = file.removed, removed > 0 {
            if text.length > 0 { text.append(NSAttributedString(string: " ")) }
            text.append(NSAttributedString(string: "−\(removed)", attributes: [.foregroundColor: NSColor(DiffColors.removed)]))
        }
        text.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), range: NSRange(location: 0, length: text.length))
        counts.attributedStringValue = text
        counts.alphaValue = viewed ? 0.6 : 1
        toolTip = file.originalPath.map { "\($0) → \(file.path)" } ?? file.path
    }

    private static func color(of kind: ChangedFile.Kind) -> NSColor {
        switch kind {
        case .added, .untracked: NSColor(DiffColors.added)
        case .deleted: NSColor(DiffColors.removed)
        case .renamed: .systemBlue
        default: .systemOrange
        }
    }
}
