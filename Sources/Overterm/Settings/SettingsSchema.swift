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
    static let all: [SettingSpec] = general + appearance + terminal + agents + editor + browser + api + notes + database + notifications + updates

    static let byKey: [String: SettingSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    static func specs(in section: SettingsSection) -> [SettingSpec] { all.filter { $0.section == section } }

    private static let general: [SettingSpec] = [
        SettingSpec(
            key: "general.restoreTabs", section: .general, group: "Startup", title: "Reopen the last session's tabs",
            help: "Agent tabs resume their conversation.", kind: .toggle, defaultValue: .bool(true)),
        SettingSpec(
            key: "general.restoreScrollback", section: .general, group: "Startup", title: "…with each shell pane's text",
            help: "Saved when Overterm quits.", kind: .toggle, defaultValue: .bool(true), requires: "general.restoreTabs"),
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
            key: "general.usageChip", section: .general, group: "Usage", title: "Show the quota gauge in the tab strip",
            help: "What is left of the tightest limit any agent reports, at the right of the strip.", kind: .toggle,
            defaultValue: .bool(true)),
        SettingSpec(
            key: "general.usageAsk", section: .general, group: "Usage", title: "Ask the agents for fresh numbers",
            help:
                "Runs the agent's own usage command every ten minutes while Overterm is in front, so the pane says what that command says. Off, it shows the last figures the agent wrote down and how old they are.",
            kind: .toggle, defaultValue: .bool(true)),
        SettingSpec(
            key: "general.usageCost", section: .general, group: "Usage", title: "Work out what it would have cost",
            help:
                "Prices the tokens in the agents' own logs at list API rates. An estimate of what the work would cost on the API — not your bill.",
            kind: .toggle, defaultValue: .bool(true)),
        SettingSpec(
            key: "general.overgitCommits", section: .general, group: "Overgit", title: "Commits the panel reads",
            help: "How far back the history and its graph go. More is a longer read on a repository with a long history.",
            kind: .integer(50...2000, step: 50, unit: "commits"), defaultValue: .int(300)),
        SettingSpec(
            key: "general.overgitAllRefs", section: .general, group: "Overgit", title: "Graph every branch, not just this one",
            help: "Shows the commits of every branch and tag in the repository, so branches that have not been merged appear.",
            kind: .toggle, defaultValue: .bool(false)),
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
            key: "appearance.theme", section: .themes, group: "Colours", title: "Theme",
            help: "The terminal and everything around it change at once.",
            kind: .dynamicChoice(.themes), defaultValue: nil, ghostty: "theme"),
        SettingSpec(
            key: "appearance.followSystemAppearance", section: .themes, group: "Colours",
            title: "Follow macOS between a light and a dark theme",
            help: "Ghostty switches as the system does — no relaunch, and no reading a dark theme in daylight.",
            // All three write the one `theme` option (Settings.themeLines);
            // naming it here is also what tells the window to rewrite the
            // overrides file when one of them changes.
            kind: .toggle, defaultValue: nil, ghostty: "theme"),
        SettingSpec(
            key: "appearance.themeLight", section: .themes, group: "Colours", title: "Light theme",
            help: "Used while macOS is light, and only while the setting above is on.", kind: .dynamicChoice(.themes),
            defaultValue: nil, ghostty: "theme", requires: "appearance.followSystemAppearance"),
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
            help: "Off: a file opens beside the terminal, and ⇧⎋ or the header's ⤢ zooms it. On: the editor takes the terminal's place (the sidebar stays).",
            kind: .toggle, defaultValue: .bool(false)),
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

    private static let browser: [SettingSpec] = [
        SettingSpec(
            key: "browser.enabled", section: .browser, group: "Browser", title: "A browser beside the terminal",
            help: "Each tab has its own — the page its dev server serves, say. Off: no browser column, and links open in your own browser.",
            kind: .toggle, defaultValue: .bool(true)),
        SettingSpec(
            key: "browser.openLinks", section: .browser, group: "Browser", title: "Links clicked in the terminal open",
            kind: .choice([
                .init(value: "local", label: "Here when they are on this machine (localhost), else in your browser"),
                .init(value: "all", label: "Here, always"), .init(value: "none", label: "In your browser, always"),
            ]), defaultValue: .string("local"), requires: "browser.enabled"),
        SettingSpec(
            key: "browser.reloadOnSave", section: .browser, group: "Browser", title: "Reload the page when a file is saved",
            help: "For a server without hot reload: a save in the editor, or an agent's edit in the checkout.", kind: .toggle,
            defaultValue: .bool(false), requires: "browser.enabled"),
        SettingSpec(
            key: "browser.agentControl", section: .browser, group: "Agents", title: "Agents can use the browser",
            help:
                "Claude Code started from Overterm gets an MCP server for its tab's browser: open a page, read it, click, type, take a screenshot, read the console.",
            kind: .toggle, defaultValue: .bool(true), requires: "browser.enabled"),
        SettingSpec(
            key: "browser.simulator", section: .browser, group: "Simulator", title: "An iOS simulator beside the terminal",
            help: "The phone in the title bar: a simulator you can see and click, in the browser's column. Off: the phone goes from the title bar.",
            kind: .toggle, defaultValue: .bool(true)),
    ]

    private static let api: [SettingSpec] = [
        SettingSpec(
            key: "api.enabled", section: .api, group: "API Client", title: "An API client in the sidebar",
            help:
                "Bruno collections in the checkout — their requests, environments, scripts and tests — sent and run beside the terminal. The files stay Bruno's: Bruno and bru run open them the same.",
            kind: .toggle, defaultValue: .bool(true)),
        SettingSpec(
            key: "api.timeout", section: .api, group: "Requests", title: "Give up on a request after", kind: .integer(1...600, step: 5, unit: "s"),
            defaultValue: .int(30), requires: "api.enabled"),
        SettingSpec(
            key: "api.followRedirects", section: .api, group: "Requests", title: "Follow redirects", kind: .toggle, defaultValue: .bool(true),
            requires: "api.enabled"),
        SettingSpec(
            key: "api.verifyTLS", section: .api, group: "Requests", title: "Check TLS certificates",
            help: "Off: a server with a self-signed certificate (a local HTTPS dev server, say) answers too.", kind: .toggle,
            defaultValue: .bool(true), requires: "api.enabled"),
        SettingSpec(
            key: "api.discoverServers", section: .api, group: "Importing", title: "Look for an API the selected tab is serving",
            help: "The ports a tab listens on are asked where frameworks publish their OpenAPI document (/openapi.json, /v3/api-docs…), on this machine only, to offer it for import.",
            kind: .toggle, defaultValue: .bool(true), requires: "api.enabled"),
        SettingSpec(
            key: "api.agentControl", section: .api, group: "Agents", title: "Agents can use the API client",
            help:
                "Claude Code started from Overterm gets MCP tools for its checkout's collection: list the requests, send one with its tests, send a one-off, run the collection.",
            kind: .toggle, defaultValue: .bool(true), requires: "api.enabled"),
    ]

    private static let notes: [SettingSpec] = [
        SettingSpec(
            key: "notes.enabled", section: .notes, group: "Notes", title: "Notes in the sidebar",
            help: "A folder of Markdown notes — an Obsidian vault opens as it is, and stays one: Obsidian, the phone and Overterm share it.",
            kind: .toggle, defaultValue: .bool(true)),
        SettingSpec(
            key: "notes.vaultPath", section: .notes, group: "Notes", title: "Vault folder",
            help: "Empty: “Overterm Notes” in iCloud Drive. An Obsidian vault's folder (the Notes panel lists the ones Obsidian knows) uses it as it is.",
            kind: .text(placeholder: "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/My Vault", monospaced: true),
            defaultValue: .string(""), requires: "notes.enabled"),
        SettingSpec(
            key: "notes.livePreview", section: .notes, group: "Editing", title: "Live Preview",
            help: "Notes open as Obsidian's Live Preview: headings, emphasis, links and tasks as they read, their markup shown only on the line you edit. Off: the Markdown as written.",
            kind: .toggle, defaultValue: .bool(true), requires: "notes.enabled"),
        SettingSpec(
            key: "notes.agentAccess", section: .notes, group: "Agents", title: "Agents can read the notes",
            help: "Claude Code started from Overterm gets MCP tools to search the vault and read a note. Agents never write to it.",
            kind: .toggle, defaultValue: .bool(true), requires: "notes.enabled"),
    ]

    private static let database: [SettingSpec] = [
        SettingSpec(
            key: "database.enabled", section: .database, group: "Database", title: "A database client in the sidebar",
            help: "PostgreSQL, MySQL, SQLite, Redshift, ClickHouse and BigQuery: connections, their schemas, a console with completion, results in a grid. Passwords and keys stay in your keychain.",
            kind: .toggle, defaultValue: .bool(true)),
        SettingSpec(
            key: "database.rowLimit", section: .database, group: "Queries", title: "Rows fetched for a result",
            help: "A query's first this many rows are shown; the grid says when there were more.", kind: .integer(100...100_000, step: 100, unit: "rows"),
            defaultValue: .int(500), requires: "database.enabled"),
        SettingSpec(
            key: "database.confirmDestructive", section: .database, group: "Queries", title: "Ask before a statement that destroys",
            help: "DROP, TRUNCATE, and an UPDATE or DELETE without WHERE are asked about before they are sent.",
            kind: .toggle, defaultValue: .bool(true), requires: "database.enabled"),
    ]

    private static let notifications: [SettingSpec] = [
        SettingSpec(
            key: "notifications.enabled", section: .notifications, group: "When a tab needs you", title: "Notify while Overterm is in the background",
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
