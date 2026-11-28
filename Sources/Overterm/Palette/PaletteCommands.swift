import AppKit

/// What ⌘K offers beside its own rows (issue-tracker#22): every menu
/// command, with the key bound to it now — so learning ⌘K finds the whole
/// menu, not half of it — and every setting. A row written by hand that is
/// named as a command shows that command's key as bound now, never the
/// key typed into its text when it was written.
@MainActor
package enum PaletteCommands {
    /// Menu actions left to the menu and their keys: the text field's own
    /// edits, Hide and Quit.
    package static let leftToTheMenu: Set<String> = [
        "copy:", "paste:", "cut:", "selectAll:", "undo:", "redo:", "delete:", "hide:", "hideOtherApplications:", "unhideAllApplications:",
        "terminate:",
    ]

    /// A title as rows and commands are compared: case, an ellipsis and spaces aside.
    package nonisolated static func normalized(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// The command a row is named as.
    package static func command(named title: String) -> KeyCommand? {
        let wanted = normalized(title)
        return KeyCommands.all.first { normalized($0.title) == wanted }
    }

    /// A menu's commands, with the submenus they sit in: every item with an
    /// action but those left to the menu, and none whose title is already
    /// offered (`skipping`, normalized).
    package static func commands(in menu: NSMenu, skipping titles: Set<String>) -> [(item: NSMenuItem, path: [String])] {
        var found: [(NSMenuItem, [String])] = []
        var seen = titles
        func walk(_ menu: NSMenu, _ path: [String]) {
            for item in menu.items where !item.isSeparatorItem && !item.isHidden {
                if let sub = item.submenu {
                    walk(sub, path + [item.title])
                    continue
                }
                guard let action = item.action, !leftToTheMenu.contains(NSStringFromSelector(action)), !item.title.isEmpty else { continue }
                guard seen.insert(normalized(item.title)).inserted else { continue }
                found.append((item, path))
            }
        }
        walk(menu, [])
        return found.map { (item: $0.0, path: $0.1) }
    }

    /// The key a menu item has now: its command's, as bound in
    /// keybindings.json or by default; nil for an item that is no command.
    package static func key(of item: NSMenuItem, keys: Keybindings = .shared) -> String? {
        if let id = item.identifier?.rawValue, let command = KeyCommands.byID[id] { return keys.key(for: command)?.display }
        if let command = command(named: item.title) { return keys.key(for: command)?.display }
        return nil
    }

    private nonisolated static let keyAtEnd = #"\s*(?:[⌃⌥⇧⌘]+\S+|[⌃⌥⇧⌘]*F\d{1,2})$"#

    /// `subtitle` without a key written at its end — "Worktree + branch +
    /// agent  ⇧⌘N" is "Worktree + branch + agent". Pure.
    package nonisolated static func strippingKey(_ subtitle: String) -> String {
        guard let range = subtitle.range(of: keyAtEnd, options: .regularExpression) else { return subtitle }
        return String(subtitle[..<range.lowerBound])
    }

    /// A subtitle with the key bound now in place of any written in it; nil
    /// when nothing is left. Pure.
    package nonisolated static func subtitle(_ subtitle: String?, key: String?) -> String? {
        let text = subtitle.map(strippingKey) ?? ""
        let parts = [text, key ?? ""].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    /// Rows written by hand, each named as a command showing its key now.
    package static func withLiveKeys(_ items: [PaletteItem], keys: Keybindings = .shared) -> [PaletteItem] {
        items.map { item in
            guard item.group == .action, let command = command(named: item.title) else { return item }
            var live = item
            live.subtitle = subtitle(item.subtitle, key: keys.key(for: command)?.display)
            return live
        }
    }

    /// A setting's value as its row says it. Pure.
    package nonisolated static func describe(_ value: SettingValue?) -> String {
        switch value {
        case .bool(let on)?: return on ? "On" : "Off"
        case .int(let n)?: return String(n)
        case .double(let d)?: return d == d.rounded() ? String(Int(d)) : String(d)
        case .string(let s)?: return s.isEmpty ? "—" : (s.count > 40 ? String(s.prefix(40)) + "…" : s)
        case .list(let items)?: return items.isEmpty ? "none" : items.prefix(3).joined(separator: ", ") + (items.count > 3 ? " +\(items.count - 3)" : "")
        case .entries(let entries)?: return "\(entries.count) \(entries.count == 1 ? "entry" : "entries")"
        case .records(let records)?: return "\(records.count)"
        case nil: return "—"
        }
    }
}
