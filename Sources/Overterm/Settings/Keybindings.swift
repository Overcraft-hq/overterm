import AppKit
import Carbon.HIToolbox
import Combine
import GhosttyKit

/// A key with its modifiers, written as keybindings.json has it:
/// "cmd+shift+d", "ctrl+alt+left", "cmd+=" — VS Code's form.
struct KeyCombo: Hashable, Sendable {
    var control = false
    var option = false
    var shift = false
    var command = false
    /// A character ("d", "[", "=") or a named key ("enter", "up", "f5").
    var key: String

    static let namedKeys: [String] =
        [
            "enter", "tab", "space", "escape", "backspace", "delete", "up", "down", "left", "right", "home", "end", "pageup", "pagedown",
        ] + (1...12).map { "f\($0)" }

    init(control: Bool = false, option: Bool = false, shift: Bool = false, command: Bool = false, key: String) {
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
        self.key = key
    }

    /// "cmd+shift+d"; nil when it isn't one key with modifiers.
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        // The key may itself be "+" ("cmd++").
        var parts = trimmed.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if trimmed.hasSuffix("++") {
            parts.removeLast(2)
            parts.append("+")
        }
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        for part in parts {
            switch part {
            case "cmd", "command", "super": command = true
            case "shift": shift = true
            case "alt", "opt", "option": option = true
            case "ctrl", "control": control = true
            default: return nil
            }
        }
        guard last.count == 1 || Self.namedKeys.contains(last) else { return nil }
        key = last
    }

    /// As keybindings.json writes it, modifiers in a fixed order.
    var text: String {
        (control ? "ctrl+" : "") + (option ? "alt+" : "") + (shift ? "shift+" : "") + (command ? "cmd+" : "") + key
    }

    /// As menus show it: ⌃⌥⇧⌘ and the key.
    var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + Self.displayName(key)
    }

    private static func displayName(_ key: String) -> String {
        switch key {
        case "enter": "↩"
        case "tab": "⇥"
        case "space": "Space"
        case "escape": "⎋"
        case "backspace": "⌫"
        case "delete": "⌦"
        case "up": "↑"
        case "down": "↓"
        case "left": "←"
        case "right": "→"
        case "home": "Home"
        case "end": "End"
        case "pageup": "Page Up"
        case "pagedown": "Page Down"
        default: key.uppercased()
        }
    }

    /// As a Ghostty keybind trigger: "super+shift+d", "super+arrow_up".
    var ghostty: String {
        let name: String =
            switch key {
            case "up", "down", "left", "right": "arrow_" + key
            case "pageup": "page_up"
            case "pagedown": "page_down"
            default: key
            }
        return (control ? "ctrl+" : "") + (option ? "alt+" : "") + (shift ? "shift+" : "") + (command ? "super+" : "") + name
    }

    /// The menu item's key equivalent and modifiers.
    var menuKey: (key: String, modifiers: NSEvent.ModifierFlags) {
        var modifiers: NSEvent.ModifierFlags = []
        if control { modifiers.insert(.control) }
        if option { modifiers.insert(.option) }
        if shift { modifiers.insert(.shift) }
        if command { modifiers.insert(.command) }
        func function(_ value: Int) -> String { String(UnicodeScalar(value).map(Character.init) ?? " ") }
        let equivalent: String =
            switch key {
            case "enter": "\r"
            case "tab": "\t"
            case "space": " "
            case "escape": "\u{1b}"
            case "backspace": "\u{8}"
            case "delete": function(NSDeleteFunctionKey)
            case "up": function(NSUpArrowFunctionKey)
            case "down": function(NSDownArrowFunctionKey)
            case "left": function(NSLeftArrowFunctionKey)
            case "right": function(NSRightArrowFunctionKey)
            case "home": function(NSHomeFunctionKey)
            case "end": function(NSEndFunctionKey)
            case "pageup": function(NSPageUpFunctionKey)
            case "pagedown": function(NSPageDownFunctionKey)
            default:
                if key.hasPrefix("f"), let n = Int(key.dropFirst()), (1...12).contains(n) { function(NSF1FunctionKey + n - 1) } else { key }
            }
        return (equivalent, modifiers)
    }

    /// A key pressed, by where it is on the keyboard (a US layout's name for
    /// it, as menus and Ghostty's defaults have it): ⌘, stays "cmd+," on a
    /// Turkish Q, where AppKit shows it as ⌘Ö. Nil for a key we can't name
    /// or one with no ⌘/⌃/⌥ (a plain letter isn't a shortcut).
    init?(event: NSEvent) {
        self.init(pressed: event)
        let isFunctionKey = key.hasPrefix("f") && key.count > 1
        guard command || control || option || isFunctionKey else { return nil }
    }

    /// Any key pressed, shortcut or not: the editor's ⇧⎋ has only a shift.
    init?(pressed event: NSEvent) {
        guard let key = Self.keyCodes[Int(event.keyCode)] else { return nil }
        let flags = event.modifierFlags
        self.init(
            control: flags.contains(.control), option: flags.contains(.option), shift: flags.contains(.shift),
            command: flags.contains(.command), key: key)
    }

    /// From a Ghostty trigger (the defaults, as its config has them).
    init?(trigger: ghostty_input_trigger_s) {
        let key: String
        switch trigger.tag {
        case GHOSTTY_TRIGGER_UNICODE:
            guard trigger.key.unicode != 0, let scalar = UnicodeScalar(trigger.key.unicode) else { return nil }
            key = String(Character(scalar)).lowercased()
        case GHOSTTY_TRIGGER_PHYSICAL:
            guard let name = Self.physicalKeys[trigger.key.physical.rawValue] else { return nil }
            key = name
        default:
            return nil
        }
        let mods = trigger.mods.rawValue
        self.init(
            control: mods & GHOSTTY_MODS_CTRL.rawValue != 0, option: mods & GHOSTTY_MODS_ALT.rawValue != 0,
            shift: mods & GHOSTTY_MODS_SHIFT.rawValue != 0, command: mods & GHOSTTY_MODS_SUPER.rawValue != 0, key: key)
    }

    private static let keyCodes: [Int: String] = {
        var codes: [Int: String] = [
            kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e", kVK_ANSI_F: "f", kVK_ANSI_G: "g",
            kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j", kVK_ANSI_K: "k", kVK_ANSI_L: "l", kVK_ANSI_M: "m", kVK_ANSI_N: "n",
            kVK_ANSI_O: "o", kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t", kVK_ANSI_U: "u",
            kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x", kVK_ANSI_Y: "y", kVK_ANSI_Z: "z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6",
            kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
            kVK_ANSI_Grave: "`",
            kVK_Return: "enter", kVK_Tab: "tab", kVK_Space: "space", kVK_Escape: "escape", kVK_Delete: "backspace",
            kVK_ForwardDelete: "delete", kVK_UpArrow: "up", kVK_DownArrow: "down", kVK_LeftArrow: "left", kVK_RightArrow: "right",
            kVK_Home: "home", kVK_End: "end", kVK_PageUp: "pageup", kVK_PageDown: "pagedown",
        ]
        let functions = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (i, code) in functions.enumerated() { codes[code] = "f\(i + 1)" }
        return codes
    }()

    private static let physicalKeys: [UInt32: String] = {
        var names: [UInt32: String] = [:]
        for (i, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() { names[GHOSTTY_KEY_A.rawValue + UInt32(i)] = String(letter) }
        for i in 0...9 { names[GHOSTTY_KEY_DIGIT_0.rawValue + UInt32(i)] = "\(i)" }
        let named: [(ghostty_input_key_e, String)] = [
            (GHOSTTY_KEY_BACKQUOTE, "`"), (GHOSTTY_KEY_BACKSLASH, "\\"), (GHOSTTY_KEY_BRACKET_LEFT, "["), (GHOSTTY_KEY_BRACKET_RIGHT, "]"),
            (GHOSTTY_KEY_COMMA, ","), (GHOSTTY_KEY_EQUAL, "="), (GHOSTTY_KEY_MINUS, "-"), (GHOSTTY_KEY_PERIOD, "."), (GHOSTTY_KEY_QUOTE, "'"),
            (GHOSTTY_KEY_SEMICOLON, ";"), (GHOSTTY_KEY_SLASH, "/"), (GHOSTTY_KEY_BACKSPACE, "backspace"), (GHOSTTY_KEY_ENTER, "enter"),
            (GHOSTTY_KEY_SPACE, "space"), (GHOSTTY_KEY_TAB, "tab"), (GHOSTTY_KEY_DELETE, "delete"), (GHOSTTY_KEY_END, "end"),
            (GHOSTTY_KEY_HOME, "home"), (GHOSTTY_KEY_PAGE_DOWN, "pagedown"), (GHOSTTY_KEY_PAGE_UP, "pageup"),
            (GHOSTTY_KEY_ARROW_DOWN, "down"), (GHOSTTY_KEY_ARROW_LEFT, "left"), (GHOSTTY_KEY_ARROW_RIGHT, "right"),
            (GHOSTTY_KEY_ARROW_UP, "up"), (GHOSTTY_KEY_ESCAPE, "escape"),
        ]
        for (key, name) in named { names[key.rawValue] = name }
        return names
    }()
}

/// Something a key can do: a menu item (by identifier), a Ghostty action
/// in the terminal, or both.
struct KeyCommand: Identifiable, Sendable {
    let id: String
    let title: String
    let group: String
    /// The default key; nil for Ghostty's own actions, whose default is
    /// what the user's Ghostty config (or Ghostty) binds.
    let defaultKey: String?
    /// The Ghostty action that also binds the default key (or, for a
    /// terminal-only command, is the command).
    let ghostty: String?
    /// A menu item carries it (NSMenuItem.identifier == id).
    let menu: Bool
    /// Only while the editor has the keyboard, as Zed's `Editor` context:
    /// the editor takes the key before the menu and the terminal never sees
    /// it, so ⌘D can select the next match there and split a pane here.
    let editor: Bool

    init(
        _ id: String, _ title: String, group: String, key: String? = nil, ghostty: String? = nil, menu: Bool = true,
        editor: Bool = false
    ) {
        self.id = id
        self.title = title
        self.group = group
        self.defaultKey = key
        self.ghostty = ghostty
        self.menu = editor ? false : menu
        self.editor = editor
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty || [title, group, id].contains { $0.lowercased().contains(query) }
    }
}

enum KeyCommands {
    static let all: [KeyCommand] = [
        // Overterm
        .init("app.settings", "Settings", group: "Overterm", key: "cmd+,", ghostty: "open_config"),
        .init("app.changelog", "View Latest Changelog", group: "Overterm", key: "alt+cmd+o"),
        .init("app.hide", "Hide Overterm", group: "Overterm", key: "cmd+h"),
        .init("app.hideOthers", "Hide Others", group: "Overterm", key: "alt+cmd+h"),
        .init("app.quit", "Quit Overterm", group: "Overterm", key: "cmd+q", ghostty: "quit"),
        // Tabs
        .init("tabs.new", "New Tab", group: "Tabs", key: "cmd+t", ghostty: "new_tab"),
        .init("tabs.newClaude", "New Claude Tab", group: "Tabs", key: "alt+cmd+c"),
        .init("tabs.newCodex", "New Codex Tab", group: "Tabs", key: "alt+cmd+x"),
        .init("tasks.new", "New Task…", group: "Tabs", key: "shift+cmd+n"),
        .init("tabs.close", "Close (the pane, or the tab)", group: "Tabs", key: "cmd+w", ghostty: "close_surface"),
        .init("tabs.next", "Show Next Tab", group: "Tabs", key: "shift+cmd+]", ghostty: "next_tab"),
        .init("tabs.previous", "Show Previous Tab", group: "Tabs", key: "shift+cmd+[", ghostty: "previous_tab"),
        // ⌘I is the inbox, as the designs have it; Tab Info moves to ⌃⌘I
        // (⌥⌘I is Ghostty's inspector, which it eats before the menu).
        .init("tabs.info", "Tab Info", group: "Tabs", key: "ctrl+cmd+i"),
        .init("inbox.show", "Agent Inbox", group: "Tabs", key: "cmd+i"),
        .init("tabs.nextAttention", "Next Failure or Tab That Needs You", group: "Tabs", key: "alt+cmd+down"),
        .init("tabs.peek", "Tab Peek", group: "Tabs", key: "shift+cmd+e"),
        .init("agents.overview", "Agent Overview", group: "Tabs", key: "shift+cmd+a"),
        // Groups. The designs asked for ⇧⌘G and ⌥⌘I; Ghostty v1.3.1 binds
        // both (navigate_search, inspector) and eats them before the menu,
        // so these live on ⌃⌘, which is free apart from ⌃⌘[ and ⌃⌘].
        .init("groups.new", "Group Selected Tabs", group: "Groups", key: "ctrl+cmd+n"),
        .init("groups.switcher", "Group Switcher", group: "Groups", key: "ctrl+cmd+g"),
        .init("groups.focus", "Focus on This Group", group: "Groups", key: "ctrl+cmd+f"),
        .init("groups.stash", "Stash Group", group: "Groups", key: "ctrl+cmd+s"),
        .init("groups.broadcast", "Broadcast Input to Group…", group: "Groups", key: "ctrl+cmd+b"),
        // ⌃⌘1…9, not the ⌃1…9 the designs drew: ⌃2 and ⌃6 are real control
        // characters a terminal has to pass through.
        .init("groups.goto1", "Go to Group 1", group: "Groups", key: "ctrl+cmd+1"),
        .init("groups.goto2", "Go to Group 2", group: "Groups", key: "ctrl+cmd+2"),
        .init("groups.goto3", "Go to Group 3", group: "Groups", key: "ctrl+cmd+3"),
        .init("groups.goto4", "Go to Group 4", group: "Groups", key: "ctrl+cmd+4"),
        .init("groups.goto5", "Go to Group 5", group: "Groups", key: "ctrl+cmd+5"),
        .init("groups.goto6", "Go to Group 6", group: "Groups", key: "ctrl+cmd+6"),
        .init("groups.goto7", "Go to Group 7", group: "Groups", key: "ctrl+cmd+7"),
        .init("groups.goto8", "Go to Group 8", group: "Groups", key: "ctrl+cmd+8"),
        .init("groups.goto9", "Go to Group 9", group: "Groups", key: "ctrl+cmd+9"),
        // Panes
        .init("splits.right", "Split Right", group: "Panes", key: "cmd+d", ghostty: "new_split:right"),
        .init("splits.down", "Split Down", group: "Panes", key: "shift+cmd+d", ghostty: "new_split:down"),
        .init("splits.next", "Next Pane", group: "Panes", key: "cmd+]", ghostty: "goto_split:next"),
        .init("splits.previous", "Previous Pane", group: "Panes", key: "cmd+[", ghostty: "goto_split:previous"),
        .init("splits.zoom", "Zoom Pane", group: "Panes", key: "shift+cmd+enter", ghostty: "toggle_split_zoom"),
        .init("splits.equalize", "Equalize Panes", group: "Panes", key: "ctrl+cmd+=", ghostty: "equalize_splits"),
        .init("splits.left", "Pane to the Left", group: "Panes", ghostty: "goto_split:left", menu: false),
        .init("splits.rightPane", "Pane to the Right", group: "Panes", ghostty: "goto_split:right", menu: false),
        .init("splits.up", "Pane Above", group: "Panes", ghostty: "goto_split:up", menu: false),
        .init("splits.below", "Pane Below", group: "Panes", ghostty: "goto_split:down", menu: false),
        // Panels
        // ⌘K as the designs have it. Ghostty binds it to clear_screen and
        // takes it before the menu, so `terminal.clear` moves to ⇧⌘K and
        // `ghosttyLines` then writes the unbind for it.
        .init("palette.show", "Command Palette", group: "Panels", key: "cmd+k"),
        .init("sidebar.toggle", "Toggle Sidebar", group: "Panels", key: "cmd+b"),
        .init("overgit.show", "Overgit", group: "Panels", key: "alt+cmd+g"),
        .init("api.show", "API Client", group: "Panels", key: "alt+cmd+r"),
        .init("changes.toggle", "Changes", group: "Panels", key: "alt+cmd+d"),
        .init("browser.toggle", "Browser", group: "Panels", key: "shift+cmd+b"),
        .init("usage.show", "Usage", group: "Panels", key: "alt+cmd+u"),
        .init("search.terminal", "Search Terminal & Files", group: "Panels", ghostty: "start_search", menu: false),
        // Editing
        .init("edit.copy", "Copy", group: "Editing", key: "cmd+c", ghostty: "copy_to_clipboard"),
        .init("edit.paste", "Paste", group: "Editing", key: "cmd+v", ghostty: "paste_from_clipboard"),
        .init("edit.selectAll", "Select All", group: "Editing", key: "cmd+a", ghostty: "select_all"),
        .init("agents.askSelection", "Ask an Agent About the Selection", group: "Editing", key: "cmd+l"),
        .init("edit.find", "Find in the Editor", group: "Editing", key: "cmd+f"),
        .init("file.save", "Save (the editor)", group: "Editing", key: "cmd+s"),
        // Terminal
        .init("terminal.clear", "Clear the Screen", group: "Terminal", key: "shift+cmd+k", ghostty: "clear_screen", menu: false),
        .init("terminal.fontBigger", "Bigger Text", group: "Terminal", ghostty: "increase_font_size:1", menu: false),
        .init("terminal.fontSmaller", "Smaller Text", group: "Terminal", ghostty: "decrease_font_size:1", menu: false),
        .init("terminal.fontReset", "Text Size Back", group: "Terminal", ghostty: "reset_font_size", menu: false),
        .init("terminal.promptPrevious", "Previous Prompt", group: "Terminal", key: "cmd+up", ghostty: "jump_to_prompt:-1", menu: false),
        .init("terminal.promptNext", "Next Prompt", group: "Terminal", key: "cmd+down", ghostty: "jump_to_prompt:1", menu: false),
        .init("terminal.copyOutput", "Copy the Last Command's Output", group: "Terminal", key: "shift+cmd+c"),
        .init("terminal.rerun", "Run the Last Command Again", group: "Terminal", key: "cmd+r"),
        .init("terminal.scrollTop", "Scroll to the Top", group: "Terminal", ghostty: "scroll_to_top", menu: false),
        .init("terminal.scrollBottom", "Scroll to the Bottom", group: "Terminal", ghostty: "scroll_to_bottom", menu: false),
        // Window
        .init("window.close", "Close Window", group: "Window", key: "shift+cmd+w", ghostty: "close_window"),
        .init("window.minimize", "Minimize", group: "Window", key: "cmd+m"),
        // Editor — Zed's keys (its VS Code keymap), only while editing.
        .init("editor.goToLine", "Go to Line…", group: "Editor", key: "ctrl+g", editor: true),
        .init("editor.goToSymbol", "Go to Symbol in File…", group: "Editor", key: "shift+cmd+o", editor: true),
        .init("editor.goToDefinition", "Go to Definition", group: "Editor", key: "f12", editor: true),
        .init("editor.findReferences", "Find All References", group: "Editor", key: "shift+f12", editor: true),
        .init("editor.goBack", "Go Back", group: "Editor", key: "ctrl+-", editor: true),
        .init("editor.goForward", "Go Forward", group: "Editor", key: "ctrl+shift+-", editor: true),
        .init("editor.nextProblem", "Next Problem", group: "Editor", key: "f8", editor: true),
        .init("editor.previousProblem", "Previous Problem", group: "Editor", key: "shift+f8", editor: true),
        .init("editor.showHover", "Show Hover", group: "Editor", key: "alt+f1", editor: true),
        .init("editor.complete", "Show Completions", group: "Editor", key: "ctrl+space", editor: true),
        .init("editor.format", "Format Document", group: "Editor", key: "shift+alt+f", editor: true),
        .init("editor.toggleComment", "Toggle Line Comment", group: "Editor", key: "cmd+/", editor: true),
        .init("editor.moveLineUp", "Move Line Up", group: "Editor", key: "alt+up", editor: true),
        .init("editor.moveLineDown", "Move Line Down", group: "Editor", key: "alt+down", editor: true),
        .init("editor.duplicateLineUp", "Duplicate Line Up", group: "Editor", key: "shift+alt+up", editor: true),
        .init("editor.duplicateLineDown", "Duplicate Line Down", group: "Editor", key: "shift+alt+down", editor: true),
        .init("editor.deleteLine", "Delete Line", group: "Editor", key: "shift+cmd+k", editor: true),
        .init("editor.insertLineBelow", "Insert Line Below", group: "Editor", key: "cmd+enter", editor: true),
        .init("editor.insertLineAbove", "Insert Line Above", group: "Editor", key: "shift+cmd+enter", editor: true),
        .init("editor.selectNext", "Add Next Match to Selection", group: "Editor", key: "cmd+d", editor: true),
        .init("editor.selectAll", "Select All Matches", group: "Editor", key: "shift+cmd+l", editor: true),
        .init("editor.joinLines", "Join Lines", group: "Editor", key: "ctrl+j", editor: true),
        .init("editor.indent", "Indent", group: "Editor", key: "cmd+]", editor: true),
        .init("editor.outdent", "Outdent", group: "Editor", key: "cmd+[", editor: true),
        .init("editor.toggleSoftWrap", "Toggle Soft Wrap", group: "Editor", key: "alt+z", editor: true),
        .init("editor.toggleZoom", "Zoom Editor", group: "Editor", key: "shift+escape", editor: true),
        .init("editor.markdownPreview", "Toggle Markdown Preview", group: "Editor", key: "shift+cmd+v", editor: true),
        .init("editor.closeFile", "Close File", group: "Editor", key: "cmd+w", editor: true),
        .init("editor.nextFile", "Next File", group: "Editor", key: "alt+cmd+right", editor: true),
        .init("editor.previousFile", "Previous File", group: "Editor", key: "alt+cmd+left", editor: true),
    ]

    static let byID: [String: KeyCommand] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    static let groups = ["Overterm", "Tabs", "Groups", "Panes", "Panels", "Editing", "Terminal", "Window", "Editor"]
}

/// keybindings.json, VS Code's way: a list of { "key", "command" }, each
/// adding a binding; "-command" removes the default one with that key. One
/// key per command — a menu item holds one — so the last entry wins.
@MainActor
final class Keybindings: ObservableObject {
    static let shared = Keybindings(
        url: AppEnvironment.supportDirectory.appendingPathComponent("keybindings.json"),
        ghosttyDefault: { GhosttyRuntime.shared.defaultTrigger(for: $0).flatMap(KeyCombo.init(trigger:)) })

    struct Entry: Equatable {
        let key: String
        let command: String
    }

    let url: URL
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var problems: [String] = []
    let changes = PassthroughSubject<Void, Never>()

    /// Ghostty's own binding for an action, without Settings' overrides.
    private let ghosttyDefault: (String) -> KeyCombo?
    private var knownText: String?
    private var watcher: DirectoryWatcher?
    private var parses = true

    init(url: URL, ghosttyDefault: @escaping (String) -> KeyCombo?, watch: Bool = true) {
        self.url = url
        self.ghosttyDefault = ghosttyDefault
        load()
        if watch {
            watcher = DirectoryWatcher(root: url.deletingLastPathComponent(), latency: 0.2) { [weak self] _ in self?.reloadIfChanged() }
        }
    }

    // MARK: Reading

    func defaultKey(_ command: KeyCommand) -> KeyCombo? {
        if let text = command.defaultKey { return KeyCombo(text) }
        guard let action = command.ghostty else { return nil }
        return ghosttyDefault(action) ?? Self.performableDefaults[action].flatMap(KeyCombo.init)
    }

    /// Ghostty's defaults for the actions it binds as "performable", which
    /// `ghostty_config_trigger` doesn't report (v1.3.1, src/config/Config.zig).
    /// Not knowing ⌘F was the terminal's search, the menu's Find… had Ghostty
    /// let go of it — and ⌘F did nothing in the terminal.
    static let performableDefaults: [String: String] = [
        "start_search": "cmd+f", "search_selection": "cmd+e", "end_search": "shift+cmd+f",
    ]

    /// The key that does it now: the file's last word on it, else the default.
    func key(for command: KeyCommand) -> KeyCombo? {
        var key = defaultKey(command)
        for entry in entries {
            if entry.command == command.id {
                key = KeyCombo(entry.key)
            } else if entry.command == "-" + command.id, KeyCombo(entry.key) == key {
                key = nil
            }
        }
        return key
    }

    func isChanged(_ command: KeyCommand) -> Bool { key(for: command) != defaultKey(command) }

    /// Other commands on the same key. Two defaults sharing one is by
    /// design (⌘F: the editor's find, the terminal's search) — only a key
    /// someone chose is a clash.
    func conflicts(for command: KeyCommand) -> [KeyCommand] {
        guard let key = key(for: command) else { return [] }
        return KeyCommands.all.filter { other in
            other.id != command.id && other.editor == command.editor && self.key(for: other) == key
                && (isChanged(command) || isChanged(other))
        }
    }

    var fileText: String { (try? String(contentsOf: url, encoding: .utf8)) ?? Self.text(of: []) }

    // MARK: Writing

    /// Binds `key` to `command`; nil leaves it without one.
    func set(_ command: KeyCommand, to key: KeyCombo?) {
        guard parses else { return }
        var kept = entries.filter { $0.command != command.id && $0.command != "-" + command.id }
        let fallback = defaultKey(command)
        if key != fallback {
            if let key {
                kept.append(Entry(key: key.text, command: command.id))
            } else if let fallback {
                kept.append(Entry(key: fallback.text, command: "-" + command.id))
            }
        }
        save(text: Self.text(of: kept))
    }

    func reset(_ command: KeyCommand) {
        guard parses else { return }
        save(text: Self.text(of: entries.filter { $0.command != command.id && $0.command != "-" + command.id }))
    }

    func resetAll() { save(text: Self.text(of: [])) }

    /// The JSON view's Save.
    func save(text: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        knownText = text
        apply(text)
    }

    static func text(of entries: [Entry]) -> String {
        let header = """
            // Overterm keybindings (Settings ▸ Keyboard Shortcuts writes this file; editing it by hand works too).
            // { "key": "cmd+shift+d", "command": "splits.down" } binds a key; "-splits.down" removes that key from it.
            """
        guard !entries.isEmpty else { return header + "\n[\n]\n" }
        let lines = entries.map { "  { \"key\": \(SettingValue.string($0.key).json), \"command\": \(SettingValue.string($0.command).json) }" }
        return header + "\n[\n" + lines.joined(separator: ",\n") + "\n]\n"
    }

    private func load() {
        let text = try? String(contentsOf: url, encoding: .utf8)
        knownText = text
        apply(text ?? "")
    }

    private func reloadIfChanged() {
        let text = try? String(contentsOf: url, encoding: .utf8)
        guard text != knownText else { return }
        knownText = text
        apply(text ?? "")
    }

    private func apply(_ text: String) {
        let list: [Any]
        do {
            list = try SettingsJSON.array(from: text)
        } catch {
            parses = false
            problems = ["keybindings.json doesn't parse, so the shortcuts stay as they were until it does: \(error.message)"]
            return
        }
        parses = true
        var parsed: [Entry] = []
        var found: [String] = []
        for (index, item) in list.enumerated() {
            guard let object = item as? [String: Any], let key = object["key"] as? String, let command = object["command"] as? String else {
                found.append("Entry \(index + 1) needs a \"key\" and a \"command\".")
                continue
            }
            guard KeyCombo(key) != nil else {
                found.append("\"\(key)\" isn't a key Overterm can bind (entry \(index + 1)).")
                continue
            }
            let id = command.hasPrefix("-") ? String(command.dropFirst()) : command
            guard KeyCommands.byID[id] != nil else {
                found.append("\"\(command)\" isn't a command Overterm knows (entry \(index + 1)).")
                continue
            }
            parsed.append(Entry(key: key, command: command))
        }
        problems = found
        guard parsed != entries else { return }
        entries = parsed
        changes.send()
    }

    // MARK: Applying

    /// Ghostty lines for what differs from the defaults. A menu command's
    /// key is the menu's: Ghostty lets go of its old key and of the new one
    /// (else it would take the key first, in the terminal). A terminal
    /// command is Ghostty's: the old key is let go, the new one bound.
    var ghosttyLines: [String] {
        // Keys a terminal command of ours deliberately holds. ⌘F is the
        // editor's find *and* the terminal's search, by design — unbinding
        // it for the menu would take the terminal's search away.
        let terminalKeys = Set(
            KeyCommands.all.filter { !$0.menu && $0.ghostty != nil }.compactMap { key(for: $0)?.ghostty })
        var lines: [String] = []
        for command in KeyCommands.all {
            let new = key(for: command)
            // Ghostty lets go of its own key for an action we have moved.
            // Asked of Ghostty directly rather than through `isChanged`:
            // `defaultKey` prefers the key written in `KeyCommands`, so a
            // command Overterm always wanted elsewhere never looked
            // changed, and the unbind was never written (⌘K).
            if let action = command.ghostty, let mine = ghosttyDefault(action), mine != new {
                lines.append("keybind = \(mine.ghostty)=unbind")
            }
            guard let new else { continue }
            if command.menu {
                // Ghostty answers a key in performKeyEquivalent, before the
                // menu sees it, so a key it holds is a menu item that
                // silently does nothing. Only where it would actually hold
                // one: a menu command that *is* a Ghostty action on
                // Ghostty's own key already does the same thing either way.
                if command.ghostty == nil || isChanged(command), !terminalKeys.contains(new.ghostty) {
                    lines.append("keybind = \(new.ghostty)=unbind")
                }
            } else if let action = command.ghostty, isChanged(command) || ghosttyDefault(action) != new {
                lines.append("keybind = \(new.ghostty)=\(action)")
            }
        }
        return lines
    }

    /// Puts each command's key on its menu item (found by identifier).
    func apply(to menu: NSMenu?) {
        guard let menu else { return }
        for item in menu.items {
            apply(to: item.submenu)
            guard let id = item.identifier?.rawValue, let command = KeyCommands.byID[id] else { continue }
            if let key = key(for: command) {
                let (equivalent, modifiers) = key.menuKey
                item.keyEquivalent = equivalent
                item.keyEquivalentModifierMask = modifiers
            } else {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
            }
        }
    }
}
