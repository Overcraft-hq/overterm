import Foundation

/// A setting's value as settings.json holds it.
enum SettingValue: Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    /// From what JSONSerialization made of the file; nil for anything else
    /// (arrays, objects, null).
    init?(json: Any) {
        if let number = json as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) < 1e15 {
                self = .int(number.intValue)
            } else {
                self = .double(number.doubleValue)
            }
        } else if let string = json as? String {
            self = .string(string)
        } else {
            return nil
        }
    }

    /// As a JSON value, written into settings.json.
    var json: String {
        switch self {
        case .bool(let value): value ? "true" : "false"
        case .int(let value): String(value)
        case .double(let value): value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(format: "%g", value)
        case .string(let value):
            // A one-element array is JSONSerialization's way to escape a string.
            String(decoding: (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8), as: UTF8.self)
                .dropFirst().dropLast().description
        }
    }

    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var number: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }
}

/// One choice of a setting that picks among fixed values.
struct SettingOption: Sendable {
    let value: String
    let label: String
}

/// What a setting is, and so how Settings shows it and what the file may hold.
enum SettingKind: Sendable {
    case toggle
    case choice([SettingOption])
    /// A choice among values found at run time (installed fonts, themes).
    case dynamicChoice(SettingSource)
    case integer(ClosedRange<Int>, step: Int, unit: String)
    case number(ClosedRange<Double>, step: Double)
    case text(placeholder: String, monospaced: Bool)
}

enum SettingSource: Sendable {
    case monospacedFonts
    case themes
}

/// One line of settings.json: its key, where Settings shows it, its default.
/// A nil default means "unset": for Ghostty's settings, the user's own
/// Ghostty config decides.
struct SettingSpec: Identifiable, Sendable {
    let key: String
    let section: SettingsSection
    let group: String
    let title: String
    var help: String? = nil
    let kind: SettingKind
    let defaultValue: SettingValue?
    /// The Ghostty option this sets, written to the overrides file when set.
    var ghostty: String? = nil
    /// Greyed out unless this toggle is on.
    var requires: String? = nil

    var id: String { key }

    /// Whether `value` is one this setting can hold; nil when it can, else why not.
    func problem(with value: SettingValue) -> String? {
        switch kind {
        case .toggle:
            return value.bool == nil ? "must be true or false" : nil
        case .choice(let options):
            guard let string = value.string, options.contains(where: { $0.value == string }) else {
                return "must be one of " + options.map { "\"\($0.value)\"" }.joined(separator: ", ")
            }
            return nil
        case .dynamicChoice, .text:
            return value.string == nil ? "must be a string" : nil
        case .integer(let range, _, _):
            guard case .int(let number) = value, range.contains(number) else {
                return "must be a whole number from \(range.lowerBound) to \(range.upperBound)"
            }
            return nil
        case .number(let range, _):
            guard let number = value.number, range.contains(number) else {
                return "must be a number from \(String(format: "%g", range.lowerBound)) to \(String(format: "%g", range.upperBound))"
            }
            return nil
        }
    }

    /// Searchable text: Settings' search matches the title, the help and the key.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return [title, help ?? "", key, group, section.title].contains { $0.lowercased().contains(query) }
    }
}

/// Every setting, in the order Settings shows them.
enum SettingsSchema {
    static let all: [SettingSpec] = general + appearance + terminal + agents + editor + notifications + updates

    static let byKey: [String: SettingSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    static func specs(in section: SettingsSection) -> [SettingSpec] { all.filter { $0.section == section } }

    private static let general: [SettingSpec] = [
        SettingSpec(
            key: "general.restoreTabs", section: .general, group: "Startup", title: "Reopen the last session's tabs",
            help: "Agent tabs resume their conversation.", kind: .toggle, defaultValue: .bool(true)),
        SettingSpec(
            key: "general.restoreScrollback", section: .general, group: "Startup", title: "…with each shell pane's text",
            help: "Saved when Terminus quits.", kind: .toggle, defaultValue: .bool(true), requires: "general.restoreTabs"),
        SettingSpec(
            key: "general.scrollbackLines", section: .general, group: "Startup", title: "Lines of text kept per pane",
            help: "The last lines of each shell pane, brought back at launch.", kind: .integer(100...20_000, step: 500, unit: "lines"),
            defaultValue: .int(2000), requires: "general.restoreScrollback"),
        SettingSpec(
            key: "general.newTabDirectory", section: .general, group: "Tabs", title: "New tabs open in",
            kind: .choice([.init(value: "current", label: "The current tab's folder"), .init(value: "home", label: "Home")]),
            defaultValue: .string("current")),
        SettingSpec(
            key: "general.confirmClose", section: .general, group: "Tabs", title: "Ask before closing",
            help: "Tabs, the window and quitting. A pane of a split asks only when something runs in it.",
            kind: .choice([
                .init(value: "always", label: "Always"), .init(value: "whenRunning", label: "Only when something is running"),
            ]), defaultValue: .string("always")),
        SettingSpec(
            key: "general.tabPeekGesture", section: .general, group: "Tab Peek", title: "Peek at every tab with",
            help:
                "Swipe down to see every tab's terminal, keep going for the full grid, and swipe down again to close it. Esc and ⇧⌘E work whatever this says.",
            kind: .choice(TabPeekGesture.Fingers.allCases.map { .init(value: $0.rawValue, label: $0.name) }), defaultValue: .string("three")),
    ]

    private static let appearance: [SettingSpec] = [
        SettingSpec(
            key: "appearance.fontFamily", section: .appearance, group: "Text", title: "Font",
            kind: .dynamicChoice(.monospacedFonts), defaultValue: nil, ghostty: "font-family"),
        SettingSpec(
            key: "appearance.fontSize", section: .appearance, group: "Text", title: "Size",
            kind: .integer(8...32, step: 1, unit: "pt"), defaultValue: nil, ghostty: "font-size"),
        SettingSpec(
            key: "appearance.fontThicken", section: .appearance, group: "Text", title: "Thicker strokes",
            help: "Draws text a little bolder, as some prefer on light backgrounds.", kind: .toggle, defaultValue: nil,
            ghostty: "font-thicken"),
        SettingSpec(
            key: "appearance.theme", section: .appearance, group: "Colours", title: "Theme",
            help: "The terminal changes at once; the tab strip and sidebar take the new colours on the next launch.",
            kind: .dynamicChoice(.themes), defaultValue: nil, ghostty: "theme"),
        SettingSpec(
            key: "appearance.windowPadding", section: .appearance, group: "Window", title: "Padding around the text",
            kind: .integer(0...40, step: 2, unit: "pt"), defaultValue: nil, ghostty: "window-padding"),
        SettingSpec(
            key: "appearance.cursorStyle", section: .appearance, group: "Window", title: "Cursor",
            kind: .choice([.init(value: "block", label: "Block"), .init(value: "bar", label: "Bar"), .init(value: "underline", label: "Underline")]),
            defaultValue: nil, ghostty: "cursor-style"),
        SettingSpec(
            key: "appearance.cursorBlink", section: .appearance, group: "Window", title: "Blinking cursor", kind: .toggle,
            defaultValue: nil, ghostty: "cursor-style-blink"),
        SettingSpec(
            key: "appearance.unfocusedPaneDim", section: .appearance, group: "Window", title: "Dim the panes without the keyboard",
            kind: .number(0...0.7, step: 0.05), defaultValue: .double(0.35)),
    ]

    private static let terminal: [SettingSpec] = [
        SettingSpec(
            key: "terminal.optionAsAlt", section: .terminal, group: "Keyboard", title: "Option key acts as Alt",
            help: "For Emacs, readline's word movement, and others that read Meta. Off types ⌥'s characters (ş, ç, ğ…).",
            kind: .choice([
                .init(value: "false", label: "Off"), .init(value: "true", label: "Both"), .init(value: "left", label: "Left ⌥ only"),
                .init(value: "right", label: "Right ⌥ only"),
            ]), defaultValue: nil, ghostty: "macos-option-as-alt"),
        SettingSpec(
            key: "terminal.copyOnSelect", section: .terminal, group: "Mouse", title: "Copy what you select",
            kind: .choice([.init(value: "false", label: "Off"), .init(value: "clipboard", label: "To the clipboard")]),
            defaultValue: nil, ghostty: "copy-on-select"),
        SettingSpec(
            key: "terminal.hideMouseWhileTyping", section: .terminal, group: "Mouse", title: "Hide the pointer while typing",
            kind: .toggle, defaultValue: nil, ghostty: "mouse-hide-while-typing"),
        SettingSpec(
            key: "terminal.scrollbackMegabytes", section: .terminal, group: "Scrollback", title: "Scrollback per pane",
            help: "How much output a pane keeps to scroll back through.", kind: .integer(1...500, step: 10, unit: "MB"),
            defaultValue: nil, ghostty: "scrollback-limit"),
        SettingSpec(
            key: "terminal.clipboardRead", section: .terminal, group: "Clipboard", title: "A program reading the clipboard",
            help: "OSC 52, as remote editors use. Asking shows what it would get first.",
            kind: .choice([.init(value: "ask", label: "Asks first"), .init(value: "allow", label: "Is allowed"), .init(value: "deny", label: "Is refused")]),
            defaultValue: nil, ghostty: "clipboard-read"),
        SettingSpec(
            key: "terminal.pasteProtection", section: .terminal, group: "Clipboard", title: "Ask before pasting text that could run commands",
            kind: .toggle, defaultValue: nil, ghostty: "clipboard-paste-protection"),
    ]

    private static let agents: [SettingSpec] = [
        SettingSpec(
            key: "agents.claudeArguments", section: .agents, group: "Arguments", title: "Claude",
            help: "Added wherever the agent starts or picks up again: ⌥⌘C / ⌥⌘X, New Task, tabs reopened at launch, and Sessions' resume.",
            kind: .text(placeholder: "--model opus", monospaced: true), defaultValue: .string("")),
        SettingSpec(
            key: "agents.codexArguments", section: .agents, group: "Arguments", title: "Codex",
            kind: .text(placeholder: "-m gpt-5", monospaced: true), defaultValue: .string("")),
        SettingSpec(
            key: "agents.newTaskAgent", section: .agents, group: "New Task", title: "Starts",
            kind: .choice(Agent.allCases.map { .init(value: $0.rawValue, label: $0.name) } + [.init(value: "shell", label: "A shell only")]),
            defaultValue: .string(Agent.claude.rawValue)),
        SettingSpec(
            key: "agents.worktreeLocation", section: .agents, group: "New Task", title: "Worktrees go",
            help: "Inside the repository, .worktrees/ is added to its local exclude file (.git/info/exclude) — no tracked file changes.",
            kind: .choice([
                .init(value: "sibling", label: "Next to the repository — repo-wt-branch"),
                .init(value: "inside", label: "Inside it — repo/.worktrees/branch"),
            ]), defaultValue: .string("sibling")),
        SettingSpec(
            key: "agents.newTaskBase", section: .agents, group: "New Task", title: "New branches start from",
            help: "Empty: the main worktree's branch.", kind: .text(placeholder: "the main worktree's branch", monospaced: true),
            defaultValue: .string("")),
    ]

    private static let editor: [SettingSpec] = [
        SettingSpec(
            key: "editor.fontFamily", section: .editor, group: "Text", title: "Font", help: "Empty: the system's monospaced font.",
            kind: .dynamicChoice(.monospacedFonts), defaultValue: .string("")),
        SettingSpec(
            key: "editor.fontSize", section: .editor, group: "Text", title: "Font size", kind: .integer(9...28, step: 1, unit: "pt"),
            defaultValue: .int(13)),
        SettingSpec(
            key: "editor.lineHeight", section: .editor, group: "Text", title: "Line height",
            kind: .choice([
                .init(value: "compact", label: "Compact"), .init(value: "standard", label: "Standard"),
                .init(value: "comfortable", label: "Comfortable — Zed's"),
            ]), defaultValue: .string("comfortable")),
        SettingSpec(
            key: "editor.softWrap", section: .editor, group: "Text", title: "Wrap long lines",
            kind: .choice([
                .init(value: "none", label: "Never — scroll sideways"), .init(value: "prose", label: "In Markdown and text files"),
                .init(value: "always", label: "Always"),
            ]), defaultValue: .string("prose")),
        SettingSpec(
            key: "editor.tabSize", section: .editor, group: "Text", title: "Tab width",
            help: "A file's own indentation wins: one indented with 2 spaces keeps 2.", kind: .integer(1...16, step: 1, unit: "columns"),
            defaultValue: .int(4)),
        SettingSpec(
            key: "editor.indentGuides", section: .editor, group: "Text", title: "Indent guides", kind: .toggle, defaultValue: .bool(true)),
        SettingSpec(
            key: "editor.openZoomed", section: .editor, group: "Window", title: "Open files zoomed",
            help: "The editor takes the terminal's place (the sidebar stays); ⇧⎋ or the header's ⤢ gives the terminal back.", kind: .toggle,
            defaultValue: .bool(true)),
        SettingSpec(
            key: "editor.gitGutter", section: .editor, group: "Window", title: "Mark lines changed since the last commit",
            kind: .toggle, defaultValue: .bool(true)),
        SettingSpec(
            key: "editor.languageServers", section: .editor, group: "Code intelligence", title: "Use language servers",
            help:
                "Completions, problems, hover and go to definition from gopls, rust-analyzer, sourcekit-lsp, clangd, vtsls, basedpyright… — on your PATH or the ones Zed downloaded.",
            kind: .toggle, defaultValue: .bool(true)),
        SettingSpec(
            key: "editor.completions", section: .editor, group: "Code intelligence", title: "Show completions as you type",
            help: "⌃Space shows them either way.", kind: .toggle, defaultValue: .bool(true)),
        SettingSpec(
            key: "editor.formatOnSave", section: .editor, group: "Code intelligence", title: "Format on save",
            help: "With the language server's formatter.", kind: .toggle, defaultValue: .bool(false),
            requires: "editor.languageServers"),
        SettingSpec(
            key: "editor.vimMode", section: .editor, group: "Vim", title: "Vim mode", help: "As Zed's: yanks go to the clipboard.",
            kind: .toggle, defaultValue: .bool(false)),
        SettingSpec(
            key: "editor.relativeLineNumbers", section: .editor, group: "Vim", title: "Relative line numbers", kind: .toggle,
            defaultValue: .bool(false)),
    ]

    private static let notifications: [SettingSpec] = [
        SettingSpec(
            key: "notifications.enabled", section: .notifications, group: "When a tab needs you", title: "Notify while Terminus is in the background",
            kind: .toggle, defaultValue: .bool(true)),
        SettingSpec(
            key: "notifications.waiting", section: .notifications, group: "When a tab needs you", title: "…when an agent waits for you",
            kind: .toggle, defaultValue: .bool(true), requires: "notifications.enabled"),
        SettingSpec(
            key: "notifications.finished", section: .notifications, group: "When a tab needs you", title: "…when work finishes",
            help: "An agent done, or a command that ran 10 s or more.", kind: .toggle, defaultValue: .bool(true),
            requires: "notifications.enabled"),
        SettingSpec(
            key: "notifications.failed", section: .notifications, group: "When a tab needs you", title: "…when something fails",
            kind: .toggle, defaultValue: .bool(true), requires: "notifications.enabled"),
        SettingSpec(
            key: "notifications.dockBadge", section: .notifications, group: "Dock", title: "Count tabs that need you on the Dock icon",
            kind: .toggle, defaultValue: .bool(true)),
    ]

    private static let updates: [SettingSpec] = [
        SettingSpec(
            key: "updates.checkDaily", section: .about, group: "Updates", title: "Check for updates once a day, at launch",
            help: "Releases come from GitHub, through your gh login.", kind: .toggle, defaultValue: .bool(true))
    ]

    /// UserDefaults keys (under "settings.") before settings.json, and their
    /// keys now: carried over once.
    static let legacyKeys: [String: String] = [
        "restoreTabs": "general.restoreTabs", "restoreScrollback": "general.restoreScrollback",
        "newTabDirectory": "general.newTabDirectory", "confirmClose": "general.confirmClose",
        "notifications": "notifications.enabled", "dockBadge": "notifications.dockBadge",
        "checkForUpdates": "updates.checkDaily", "tabPeekGesture": "general.tabPeekGesture",
        "taskAgent": "agents.newTaskAgent", "claudeArguments": "agents.claudeArguments", "codexArguments": "agents.codexArguments",
        "worktreeLocation": "agents.worktreeLocation", "taskBase": "agents.newTaskBase",
        "fontFamily": "appearance.fontFamily", "fontSize": "appearance.fontSize", "theme": "appearance.theme",
        "windowPadding": "appearance.windowPadding", "cursorStyle": "appearance.cursorStyle",
        "unfocusedPaneDim": "appearance.unfocusedPaneDim",
    ]
}
