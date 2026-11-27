import AppKit

/// The keyboard between the window's columns (P14, A11Y-U3): a command for
/// each — the sidebar, the terminal, the editor, the right slot, the Inbox
/// — and the next and previous open one. Only these commands move it; a
/// column that appears, or whose content changes, never takes it.
extension TerminalWindowController {
    package enum WindowColumn: String, CaseIterable {
        case sidebar, terminal, editor, right, inbox

        package var title: String {
            switch self {
            case .sidebar: "Sidebar"
            case .terminal: "Terminal"
            case .editor: "Editor"
            case .right: "Right Pane"
            case .inbox: "Inbox"
            }
        }
    }

    /// The split items the columns are, left to right as the window lays them.
    private func item(of column: WindowColumn) -> NSSplitViewItem? {
        switch column {
        case .sidebar: sidebarItem
        case .terminal: terminalColumn
        case .editor: editorItem
        case .right: browserItem?.isCollapsed == false ? browserItem : diffItem
        case .inbox: inboxItem
        }
    }

    /// Open, and so reachable: the terminal always is.
    package func isOpen(_ column: WindowColumn) -> Bool {
        column == .terminal || item(of: column)?.isCollapsed == false
    }

    /// The open columns, left to right.
    package var openColumns: [WindowColumn] { WindowColumn.allCases.filter(isOpen) }

    /// The column the keyboard is in: the one whose view holds the first
    /// responder; the terminal when nothing of a column's has it.
    package var focusedColumn: WindowColumn {
        guard let responder = window?.firstResponder as? NSView else { return .terminal }
        for column in WindowColumn.allCases where column != .terminal {
            if let view = item(of: column)?.viewController.view, isOpen(column), responder.isDescendant(of: view) { return column }
        }
        return .terminal
    }

    /// The keyboard to `column`; a closed one is a beep, never opened for it.
    @discardableResult
    package func focusColumn(_ column: WindowColumn) -> Bool {
        guard isOpen(column), let window else {
            NSSound.beep()
            return false
        }
        switch column {
        case .terminal:
            focusSelectedTerminal()
            return true
        case .editor:
            guard let text = editor?.textView else { return false }
            return window.makeFirstResponder(text)
        case .sidebar:
            if let target = sidebarKeyTarget?() { return window.makeFirstResponder(target) }
            return focusFirstKeyView(in: item(of: column)?.viewController.view)
        case .right, .inbox:
            return focusFirstKeyView(in: item(of: column)?.viewController.view)
        }
    }

    /// The next open column after the focused one (or before it), wrapping.
    package func focusColumn(by step: Int) {
        let open = openColumns
        guard open.count > 1, let at = open.firstIndex(of: focusedColumn) ?? open.firstIndex(of: .terminal) else { return NSSound.beep() }
        focusColumn(open[((at + step) % open.count + open.count) % open.count])
    }

    /// The first view inside `root` that takes the keyboard — a hosting
    /// view that does (the Inbox's), a list, a field — depth first.
    private func focusFirstKeyView(in root: NSView?) -> Bool {
        guard let root, let window else { return false }
        func first(_ view: NSView) -> NSView? {
            if !view.isHidden, view.acceptsFirstResponder, view.canBecomeKeyView || view is NSTableView || view is NSOutlineView { return view }
            for sub in view.subviews where !sub.isHidden {
                if let found = first(sub) { return found }
            }
            return nil
        }
        // The Inbox's own host takes J and K: it, before anything inside it.
        if let host = Self.find(in: root, where: { $0.acceptsFirstResponder && String(describing: Swift.type(of: $0)).hasPrefix("InboxHostingView") }) {
            return window.makeFirstResponder(host)
        }
        guard let target = first(root) else {
            NSSound.beep()
            return false
        }
        return window.makeFirstResponder(target)
    }

    private static func find(in view: NSView, where test: (NSView) -> Bool) -> NSView? {
        if test(view) { return view }
        for sub in view.subviews {
            if let found = find(in: sub, where: test) { return found }
        }
        return nil
    }

    // MARK: The commands

    @objc package func focusSidebarColumn(_ sender: Any?) { focusColumn(.sidebar) }
    @objc package func focusTerminalColumn(_ sender: Any?) { focusColumn(.terminal) }
    @objc package func focusEditorColumn(_ sender: Any?) { focusColumn(.editor) }
    @objc package func focusRightColumn(_ sender: Any?) { focusColumn(.right) }
    @objc package func focusInboxColumn(_ sender: Any?) { focusColumn(.inbox) }
    @objc package func focusNextColumn(_ sender: Any?) { focusColumn(by: 1) }
    @objc package func focusPreviousColumn(_ sender: Any?) { focusColumn(by: -1) }

    // MARK: The sidebar's keys (A11Y-U2)

    /// A key while the sidebar has the keyboard: ↑↓ (k j) move, → (l)
    /// opens, ← (h) closes, ↩ opens what is picked, Esc gives the keyboard
    /// back to the terminal. Files and Overgit; the other panels Esc alone.
    package func sidebarKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty else { return false }
        guard let key = SidebarKey(event) else { return false }
        if key == .escape {
            focusSelectedTerminal()
            return true
        }
        switch sidebarPanel.panel {
        case .files:
            switch key {
            case .down: tree.moveSelection(by: 1)
            case .up: tree.moveSelection(by: -1)
            case .right: tree.expandSelection()
            case .left: tree.collapseSelection()
            case .open:
                guard let row = tree.selectedRow else { return false }
                if row.entry.isDirectory { tree.toggle(row) } else { openInEditor(row.entry.url) }
            case .escape: break
            }
        case .git:
            switch key {
            case .down: overgit.moveKeyFocus(by: 1)
            case .up: overgit.moveKeyFocus(by: -1)
            case .right: overgit.setKeySectionOpen(true)
            case .left: overgit.setKeySectionOpen(false)
            case .open:
                if let commit = overgit.keyCommit {
                    showCommit(commit)
                } else if case .section(let section) = overgit.keyFocus {
                    overgit.toggle(section)
                } else {
                    return false
                }
            case .escape: break
            }
        default:
            return false
        }
        return true
    }
}

/// A sidebar key, as the panels read it. Pure over the event's key code
/// and characters.
package enum SidebarKey: Equatable {
    case up, down, left, right, open, escape

    package init?(_ event: NSEvent) {
        switch event.keyCode {
        case 126: self = .up
        case 125: self = .down
        case 123: self = .left
        case 124: self = .right
        case 36, 76: self = .open
        case 53: self = .escape
        default:
            switch event.charactersIgnoringModifiers {
            case "k": self = .up
            case "j": self = .down
            case "h": self = .left
            case "l": self = .right
            default: return nil
            }
        }
    }
}
