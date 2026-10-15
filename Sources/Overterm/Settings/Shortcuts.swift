import Foundation

/// A gesture Settings ▸ Keyboard Shortcuts lists but can't change — the
/// keys themselves are KeyCommands, changed in Keybindings.
struct Shortcut: Identifiable, Equatable {
    let title: String
    let keys: String
    var id: String { "\(title)/\(keys)" }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty || title.lowercased().contains(query) || keys.lowercased().contains(query)
    }
}

enum Shortcuts {
    static let mouse: [Shortcut] = [
        Shortcut(title: "Open a printed path:line in the editor", keys: "⌘-click"),
        Shortcut(title: "Drop files as plain quoted paths, even where Claude Code runs", keys: "⌥ while dropping"),
        Shortcut(title: "Rename a tab", keys: "Double-click the tab"),
        Shortcut(title: "Reorder tabs", keys: "Drag a tab"),
        Shortcut(title: "Tab menu: colour, pin, Show Info", keys: "Right-click a tab"),
        Shortcut(title: "Resize panes and panels", keys: "Drag a divider"),
        Shortcut(title: "Peek at every tab, then the full grid, then close", keys: "Swipe down with three fingers"),
    ]
}
