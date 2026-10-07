import AppKit
import GhosttyKit

/// One line of Settings ▸ Keyboard Shortcuts.
struct Shortcut: Identifiable, Equatable {
    enum Group: String, CaseIterable {
        case app = "Terminus"
        case terminal = "Terminal"
        case mouse = "Mouse and dropping"
    }

    let group: Group
    let title: String
    let keys: String
    var id: String { "\(group.rawValue)/\(title)/\(keys)" }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty || title.lowercased().contains(query) || keys.lowercased().contains(query)
    }
}

/// Where the shortcuts come from: the app's menus as they are now (so a
/// change made in System Settings shows), the user's Ghostty keybinds for
/// the terminal's own actions, and the few mouse gestures.
@MainActor
enum Shortcuts {
    static func all(menu: NSMenu? = NSApp.mainMenu, trigger: (String) -> ghostty_input_trigger_s? = { GhosttyRuntime.shared.trigger(for: $0) })
        -> [Shortcut]
    {
        (menu.map { self.menu($0) } ?? []) + terminal(trigger: trigger) + mouse
    }

    /// Every menu item with a key equivalent, titled by its menu path.
    static func menu(_ menu: NSMenu, path: [String] = []) -> [Shortcut] {
        menu.items.flatMap { item -> [Shortcut] in
            if let submenu = item.submenu {
                // The app menu's title is empty; the top-level titles lead the path.
                let title = submenu.title.isEmpty ? [] : [submenu.title]
                return self.menu(submenu, path: path.isEmpty ? title : path + [item.title])
            }
            guard !item.isSeparatorItem, !item.keyEquivalent.isEmpty else { return [] }
            let title = (path + [item.title]).joined(separator: " ▸ ")
            return [Shortcut(group: .app, title: title, keys: format(keyEquivalent: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask))]
        }
    }

    /// ⌃⌥⇧⌘ + the key, as menus show it.
    static func format(keyEquivalent: String, modifiers: NSEvent.ModifierFlags) -> String {
        var mods = modifiers
        // An upper-case key equivalent carries its own Shift.
        if keyEquivalent.count == 1, keyEquivalent.uppercased() == keyEquivalent, keyEquivalent.lowercased() != keyEquivalent {
            mods.insert(.shift)
        }
        return symbols(control: mods.contains(.control), option: mods.contains(.option), shift: mods.contains(.shift), command: mods.contains(.command))
            + keyName(keyEquivalent)
    }

    private static func symbols(control: Bool, option: Bool, shift: Bool, command: Bool) -> String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
    }

    private static func keyName(_ key: String) -> String {
        switch key {
        case "\r": "↩"
        case "\u{1b}": "⎋"
        case "\t": "⇥"
        case " ": "Space"
        case "\u{8}", "\u{7f}": "⌫"
        case String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑"
        case String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓"
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←"
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): "→"
        default: key.uppercased()
        }
    }

    // MARK: Terminal

    /// The terminal's own actions worth knowing, with Ghostty's action names.
    static let terminalActions: [(title: String, action: String)] = [
        ("Search in the terminal", "start_search"),
        ("Copy", "copy_to_clipboard"),
        ("Paste", "paste_from_clipboard"),
        ("Split right", "new_split:right"),
        ("Split down", "new_split:down"),
        ("Previous pane", "goto_split:previous"),
        ("Next pane", "goto_split:next"),
        ("Pane to the left", "goto_split:left"),
        ("Pane to the right", "goto_split:right"),
        ("Pane above", "goto_split:up"),
        ("Pane below", "goto_split:down"),
        ("Zoom the pane", "toggle_split_zoom"),
        ("Equalize panes", "equalize_splits"),
        ("Bigger text", "increase_font_size:1"),
        ("Smaller text", "decrease_font_size:1"),
        ("Text size back", "reset_font_size"),
        ("Clear the screen", "clear_screen"),
        ("Previous prompt", "jump_to_prompt:-1"),
        ("Next prompt", "jump_to_prompt:1"),
        ("Scroll to the top", "scroll_to_top"),
        ("Scroll to the bottom", "scroll_to_bottom"),
        ("Select all", "select_all"),
    ]

    static func terminal(trigger: (String) -> ghostty_input_trigger_s?) -> [Shortcut] {
        terminalActions.compactMap { title, action in
            guard let bound = trigger(action), let keys = format(trigger: bound) else { return nil }
            return Shortcut(group: .terminal, title: title, keys: keys)
        }
    }

    /// A Ghostty trigger as menus write it; nil when nothing is bound.
    static func format(trigger: ghostty_input_trigger_s) -> String? {
        let key: String
        switch trigger.tag {
        case GHOSTTY_TRIGGER_UNICODE:
            guard let scalar = UnicodeScalar(trigger.key.unicode), trigger.key.unicode != 0 else { return nil }
            key = keyName(String(Character(scalar)))
        case GHOSTTY_TRIGGER_PHYSICAL:
            guard let name = physicalKeys[trigger.key.physical.rawValue] else { return nil }
            key = name
        default:
            return nil
        }
        let mods = trigger.mods.rawValue
        return symbols(
            control: mods & GHOSTTY_MODS_CTRL.rawValue != 0, option: mods & GHOSTTY_MODS_ALT.rawValue != 0,
            shift: mods & GHOSTTY_MODS_SHIFT.rawValue != 0, command: mods & GHOSTTY_MODS_SUPER.rawValue != 0) + key
    }

    private static let physicalKeys: [UInt32: String] = {
        var names: [UInt32: String] = [:]
        let letters = GHOSTTY_KEY_A.rawValue
        for (i, letter) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { names[letters + UInt32(i)] = String(letter) }
        let digits = GHOSTTY_KEY_DIGIT_0.rawValue
        for i in 0...9 { names[digits + UInt32(i)] = "\(i)" }
        let named: [(ghostty_input_key_e, String)] = [
            (GHOSTTY_KEY_BACKQUOTE, "`"), (GHOSTTY_KEY_BACKSLASH, "\\"), (GHOSTTY_KEY_BRACKET_LEFT, "["), (GHOSTTY_KEY_BRACKET_RIGHT, "]"),
            (GHOSTTY_KEY_COMMA, ","), (GHOSTTY_KEY_EQUAL, "="), (GHOSTTY_KEY_MINUS, "-"), (GHOSTTY_KEY_PERIOD, "."), (GHOSTTY_KEY_QUOTE, "'"),
            (GHOSTTY_KEY_SEMICOLON, ";"), (GHOSTTY_KEY_SLASH, "/"), (GHOSTTY_KEY_BACKSPACE, "⌫"), (GHOSTTY_KEY_ENTER, "↩"),
            (GHOSTTY_KEY_SPACE, "Space"), (GHOSTTY_KEY_TAB, "⇥"), (GHOSTTY_KEY_DELETE, "⌦"), (GHOSTTY_KEY_END, "End"),
            (GHOSTTY_KEY_HOME, "Home"), (GHOSTTY_KEY_PAGE_DOWN, "Page Down"), (GHOSTTY_KEY_PAGE_UP, "Page Up"),
            (GHOSTTY_KEY_ARROW_DOWN, "↓"), (GHOSTTY_KEY_ARROW_LEFT, "←"), (GHOSTTY_KEY_ARROW_RIGHT, "→"), (GHOSTTY_KEY_ARROW_UP, "↑"),
            (GHOSTTY_KEY_ESCAPE, "⎋"),
        ]
        for (key, name) in named { names[key.rawValue] = name }
        return names
    }()

    // MARK: Mouse

    static let mouse: [Shortcut] = [
        Shortcut(group: .mouse, title: "Open a printed path:line in the editor", keys: "⌘-click"),
        Shortcut(group: .mouse, title: "Drop files as plain quoted paths, even where Claude Code runs", keys: "⌥ while dropping"),
        Shortcut(group: .mouse, title: "Rename a tab", keys: "Double-click the tab"),
        Shortcut(group: .mouse, title: "Reorder tabs", keys: "Drag a tab"),
        Shortcut(group: .mouse, title: "Tab menu: colour, pin, Show Info", keys: "Right-click a tab"),
        Shortcut(group: .mouse, title: "Resize panes and panels", keys: "Drag a divider"),
        Shortcut(group: .mouse, title: "Peek at every tab, then the full grid, then close", keys: "Swipe down with three fingers"),
    ]
}
