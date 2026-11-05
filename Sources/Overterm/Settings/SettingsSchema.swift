import Foundation

/// A setting's value as settings.json holds it.
enum SettingValue: Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    /// A list of names, in order (`SettingKind.order`, `SettingKind.list`).
    case list([String])
    /// Named entries, each a few fields of its own (`SettingKind.entries`):
    /// `{ "a context": { "class": "production" } }`.
    case entries([String: [String: SettingValue]])

    /// From what JSONSerialization made of the file; nil for anything else
    /// (null, a list holding something other than strings, an object that
    /// isn't one of objects). A field that isn't a plain value is passed over.
    init?(json: Any) {
        if let object = json as? [String: Any] {
            var entries: [String: [String: SettingValue]] = [:]
            for (name, raw) in object {
                guard let fields = raw as? [String: Any] else { return nil }
                var values: [String: SettingValue] = [:]
                for (field, rawValue) in fields {
                    guard let value = SettingValue(json: rawValue), value.entries == nil else { continue }
                    values[field] = value
                }
                entries[name] = values
            }
            self = .entries(entries)
            return
        }
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
        } else if let array = json as? [Any], let strings = array as? [String] {
            self = .list(strings)
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
        case .list(let values):
            // On one line, so the file can still be edited in place.
            "[" + values.map { SettingValue.string($0).json }.joined(separator: ", ") + "]"
        case .entries(let entries):
            // On one line too, sorted, so the same entries write the same text.
            "{"
                + entries.keys.sorted().map { name in
                    let fields = entries[name]!.keys.sorted().map { SettingValue.string($0).json + ": " + entries[name]![$0]!.json }
                    return SettingValue.string(name).json + ": {" + fields.joined(separator: ", ") + "}"
                }.joined(separator: ", ") + "}"
        }
    }

    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var list: [String]? { if case .list(let value) = self { value } else { nil } }
    var entries: [String: [String: SettingValue]]? { if case .entries(let value) = self { value } else { nil } }
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
    /// For an `order`: the toggle that shows this one, if it can be hidden.
    var toggle: String? = nil
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
    /// A colour, written `#rrggbb`; unset, the theme's.
    case color
    /// A file's path (an image), picked in an open panel.
    case file(types: [String])
    /// Lines of text, one item each (a list in the file).
    case lines(placeholder: String)
    /// The options in an order of the user's: a list of their values.
    /// Names it doesn't know are passed over, and options it leaves out
    /// come last — so a file from another version still reads.
    case order([SettingOption])
    /// A list of the user's own: paths, names. Empty is none.
    case list(placeholder: String)
    /// Named entries — a context's own settings, say — each holding some
    /// of `fields`. A field that doesn't fit is reported and left out; the
    /// rest of the entry, and the other entries, still apply.
    case entries(SettingEntries)
}

/// What a `SettingKind.entries` setting's entries are and may hold.
struct SettingEntries: Sendable {
    /// What an entry is named by, for the page: "context".
    let noun: String
    let fields: [SettingField]
}

/// One field of an entry: its name in the file and what it may hold
/// (`toggle`, `choice`, `text` or `list`).
struct SettingField: Sendable {
    let name: String
    let kind: SettingKind
    var help: String? = nil
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
        case .dynamicChoice, .text, .file:
            return value.string == nil ? "must be a string" : nil
        case .color:
            guard let text = value.string, SettingsColor.parse(text) != nil else { return "must be a colour like \"#1e90ff\"" }
            return nil
        case .order:
            return value.list == nil ? "must be a list of names, like [\"files\", \"git\"]" : nil
        case .lines:
            return value.list == nil ? "must be a list of strings, like [\"~/Projects/prod-* = Red Alert\"]" : nil
        case .list:
            return value.list == nil ? "must be a list of strings, like [\"a\", \"b\"]" : nil
        case .entries(let entries):
            return value.entries == nil ? "must be an object of \(entries.noun)s, like { \"name\": { … } }" : nil
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

    /// `value` with each entry's fields that don't fit left out, and why —
    /// for `entries`; anything else comes back as it is. A typo in one
    /// field must not drop a context's hand-set class with it.
    func fitted(_ value: SettingValue) -> (value: SettingValue, problems: [String]) {
        guard case .entries(let kind) = self.kind, let entries = value.entries else { return (value, []) }
        var kept: [String: [String: SettingValue]] = [:]
        var problems: [String] = []
        for name in entries.keys.sorted() {
            var fields: [String: SettingValue] = [:]
            for (field, fieldValue) in entries[name]!.sorted(by: { $0.key < $1.key }) {
                let place = "\"\(key)\" › \"\(name)\": \"\(field)\""
                guard let spec = kind.fields.first(where: { $0.name == field }) else {
                    problems.append("\(place) isn't a field Overterm knows; it is left as it is.")
                    continue
                }
                let probe = SettingSpec(key: key, section: section, group: group, title: title, kind: spec.kind, defaultValue: nil)
                if let problem = probe.problem(with: fieldValue) {
                    problems.append("\(place) \(problem); it is left out.")
                    continue
                }
                fields[field] = fieldValue
            }
            kept[name] = fields
        }
        return (.entries(kept), problems)
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
    static let all: [SettingSpec] =
        general + appearance + terminal + agents + editor + browser + api + notes + database + docker + kubernetes + notifications + updates

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
        SettingSpec(
            key: "general.sidebarOrder", section: .general, group: "Sidebar", title: "Panels in the rail",
            help: "Drag to reorder; tick to show. Right-click an icon in the rail to move or hide it there.",
            kind: .order(SidebarPanel.allCases.map { .init(value: $0.rawValue, label: $0.title, toggle: $0.toggleKey) }),
            defaultValue: .list(SidebarPanel.allCases.map(\.rawValue))),
        SettingSpec(
            key: "general.sidebarStartPanel", section: .general, group: "Sidebar", title: "A new window opens on",
            help: "The panel the sidebar shows in a new window, or whichever was open last.",
            kind: .choice([.init(value: "last", label: "The last one open")] + SidebarPanel.allCases.map { .init(value: $0.rawValue, label: $0.title) }),
            defaultValue: .string("last")),
        SettingSpec(
            key: "general.sidebarRail", section: .general, group: "Sidebar", title: "Rail icons",
            help: "Compact: smaller icons and a narrower rail, which leaves the panel more room.",
            kind: .choice([.init(value: "regular", label: "Regular"), .init(value: "compact", label: "Compact")]),
            defaultValue: .string("regular")),
        SettingSpec(
            key: "general.sessions", section: .general, group: "Sidebar", title: "Claude sessions in the sidebar",
            help: "Every conversation run in the repository, to resume. Off: no panel, and nothing reads the transcripts for it.",
            kind: .toggle, defaultValue: .bool(true)),
        SettingSpec(
            key: "general.snippets", section: .general, group: "Sidebar", title: "Snippets",
            help: "Commands you keep, in the sidebar and ⌘K. Off: neither shows them; snippets.json is kept as it is.",
            kind: .toggle, defaultValue: .bool(true)),
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
            key: "appearance.ligatures", section: .appearance, group: "Text", title: "Ligatures",
            help: "Joins characters a font draws as one (=>, !=, ->). Off, every character stands alone.",
            kind: .toggle, defaultValue: nil, ghostty: "font-feature"),
        SettingSpec(
            key: "appearance.lineHeight", section: .appearance, group: "Text", title: "Line height",
            help: "More or less room between lines, from the font's own.",
            kind: .integer(-20...100, step: 5, unit: "%"), defaultValue: nil, ghostty: "adjust-cell-height"),
        SettingSpec(
            key: "appearance.letterSpacing", section: .appearance, group: "Text", title: "Letter spacing",
            kind: .integer(-20...50, step: 5, unit: "%"), defaultValue: nil, ghostty: "adjust-cell-width"),
        SettingSpec(
            key: "appearance.minimumContrast", section: .appearance, group: "Colours", title: "Minimum contrast",
            help: "Text drawn too faint for its background is lifted to this contrast (1 leaves it; 4.5 is WCAG's for text).",
            kind: .number(1...7, step: 0.5), defaultValue: nil, ghostty: "minimum-contrast"),
        SettingSpec(
            key: "appearance.boldIsBright", section: .appearance, group: "Colours", title: "Bold text in bright colours",
            kind: .toggle, defaultValue: nil, ghostty: "bold-color"),
        SettingSpec(
            key: "appearance.cursorColor", section: .appearance, group: "Colours", title: "Cursor colour",
            kind: .color, defaultValue: nil, ghostty: "cursor-color"),
        SettingSpec(
            key: "appearance.selectionBackground", section: .appearance, group: "Colours", title: "Selection",
            kind: .color, defaultValue: nil, ghostty: "selection-background"),
        SettingSpec(
            key: "appearance.selectionForeground", section: .appearance, group: "Colours", title: "Selected text",
            kind: .color, defaultValue: nil, ghostty: "selection-foreground"),
        SettingSpec(
            key: "appearance.folderThemes", section: .themes, group: "Colours", title: "Themes by folder",
            help: "A theme for the tabs working in a folder, one rule a line: `~/Projects/prod-* = Red Alert`. A group's own theme (its menu ▸ Terminal Theme) comes first.",
            kind: .lines(placeholder: "~/Projects/prod-* = Red Alert"), defaultValue: nil),
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
            key: "appearance.accent", section: .appearance, group: "Interface", title: "Accent colour",
            help: "Selections, the tab you are on, links and buttons. The terminal's own blue, macOS's accent, or one of these.",
            kind: .choice(ChromeAccent.allCases.map { .init(value: $0.rawValue, label: $0.label) }), defaultValue: .string("overterm")),
        SettingSpec(
            key: "appearance.density", section: .appearance, group: "Interface", title: "Density",
            help: "How much room the strip, the pane headers and the lists take.",
            kind: .choice(ChromeMetrics.Density.allCases.map { .init(value: $0.rawValue, label: $0.label) }), defaultValue: .string("regular")),
        SettingSpec(
            key: "appearance.interfaceScale", section: .appearance, group: "Interface", title: "Interface text size",
            help: "The text around the terminal — tabs, panels, lists — apart from the terminal's own font.",
            kind: .integer(80...140, step: 5, unit: "%"), defaultValue: .int(100)),
        SettingSpec(
            key: "appearance.cardGap", section: .appearance, group: "Interface", title: "Space between cards",
            help: "0 puts the panels edge to edge.", kind: .integer(0...24, step: 2, unit: "pt"), defaultValue: .int(10)),
        SettingSpec(
            key: "appearance.cardRadius", section: .appearance, group: "Interface", title: "Card corners",
            kind: .integer(0...20, step: 2, unit: "pt"), defaultValue: .int(10)),
        SettingSpec(
            key: "appearance.paneHeaders", section: .appearance, group: "Interface", title: "Pane headers",
            help: "The bar over each terminal: what runs there, its ports, split and close. A tab of one pane can go without.",
            kind: .choice([.init(value: "always", label: "Always"), .init(value: "whenSplit", label: "Only when a tab is split")]),
            defaultValue: .string("always")),
        SettingSpec(
            key: "appearance.tabWidth", section: .appearance, group: "Tabs", title: "Tab width",
            kind: .choice(ChromeMetrics.TabWidth.allCases.map { .init(value: $0.rawValue, label: $0.label) }), defaultValue: .string("regular")),
        SettingSpec(
            key: "appearance.tabClose", section: .appearance, group: "Tabs", title: "Close button",
            kind: .choice([.init(value: "hover", label: "On the selected tab and under the pointer"), .init(value: "always", label: "On every tab")]),
            defaultValue: .string("hover")),
        SettingSpec(
            key: "appearance.tabIcons", section: .appearance, group: "Tabs", title: "Tab icons",
            help: "Off, a tab shows its badge only when it has news — waiting, finished, failed.", kind: .toggle, defaultValue: .bool(true)),
        SettingSpec(
            key: "appearance.backgroundOpacity", section: .appearance, group: "Window", title: "Opacity",
            help: "Below 1, the desktop shows through the whole window — the terminal, the cards and the strip alike.",
            kind: .number(0.3...1, step: 0.05), defaultValue: .double(1), ghostty: "background-opacity"),
        SettingSpec(
            key: "appearance.backgroundBlur", section: .appearance, group: "Window", title: "Blur what shows through",
            kind: .toggle, defaultValue: .bool(true), ghostty: "background-blur", requires: "appearance.backgroundOpacity"),
        SettingSpec(
            key: "appearance.backgroundImage", section: .appearance, group: "Window", title: "Background image",
            help: "Drawn behind the text of every terminal.",
            kind: .file(types: ["png", "jpg", "jpeg"]), defaultValue: nil, ghostty: "background-image"),
        SettingSpec(
            key: "appearance.backgroundImageOpacity", section: .appearance, group: "Window", title: "Image opacity",
            kind: .number(0.05...1, step: 0.05), defaultValue: .double(0.25), ghostty: "background-image-opacity",
            requires: "appearance.backgroundImage"),
        SettingSpec(
            key: "appearance.backgroundImageFit", section: .appearance, group: "Window", title: "Image fit",
            kind: .choice([
                .init(value: "cover", label: "Fill"), .init(value: "contain", label: "Fit"), .init(value: "stretch", label: "Stretch"),
                .init(value: "none", label: "Actual size"),
            ]), defaultValue: .string("cover"), ghostty: "background-image-fit", requires: "appearance.backgroundImage"),
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
            key: "editor.theme", section: .editor, group: "Text", title: "Colours",
            help: "Zed's One Dark (One Light on a light terminal), or the terminal theme's own colours for the code too.",
            kind: .choice([.init(value: "one", label: "One Dark / One Light"), .init(value: "terminal", label: "The terminal theme's")]),
            defaultValue: .string("one")),
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
            help: "Claude Code started from Overterm gets MCP tools to search the vault and read a note. They never change a note.",
            kind: .toggle, defaultValue: .bool(true), requires: "notes.enabled"),
        SettingSpec(
            key: "notes.agentDrawings", section: .notes, group: "Agents", title: "Agents can add drawings",
            help: "notes_draw: an agent draws boxes, arrows and text into a new Excalidraw drawing, in the vault's Excalidraw folder. Only new files.",
            kind: .toggle, defaultValue: .bool(true), requires: "notes.agentAccess"),
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
        SettingSpec(
            key: "database.agentAccess", section: .database, group: "Agents", title: "Agents can read the databases and buckets",
            help:
                "Claude Code started from Overterm gets MCP tools to list your connections, read a schema, run a query that reads, and browse a bucket and read a file in it. Never a password or a key.",
            kind: .toggle, defaultValue: .bool(true), requires: "database.enabled"),
        SettingSpec(
            key: "database.agentWrites", section: .database, group: "Agents", title: "Agents can ask to write",
            help: "A statement that writes is shown to you in the window, and runs only if you say so. Read-only connections refuse it anyway.",
            kind: .toggle, defaultValue: .bool(false), requires: "database.agentAccess"),
    ]

    private static let docker: [SettingSpec] = [
        SettingSpec(
            key: "docker.enabled", section: .docker, group: "Docker", title: "Docker in Overterm",
            help:
                "Containers and compose projects of the engine your terminal's docker reaches — Docker Desktop, OrbStack, Colima — on a page of their own (⌥⌘P). Nothing is read while it is off.",
            kind: .toggle, defaultValue: .bool(true)),
        SettingSpec(
            key: "docker.endpoint", section: .docker, group: "Docker", title: "Engine",
            help: "Empty: the one docker uses — DOCKER_HOST, else the current context. Or a socket or an address of your own.",
            kind: .text(placeholder: "unix:///var/run/docker.sock, tcp://host:2375", monospaced: true), defaultValue: .string(""),
            requires: "docker.enabled"),
        SettingSpec(
            key: "docker.context", section: .docker, group: "Docker", title: "Context",
            help:
                "Empty: the one docker uses now. A context's name (docker context ls) for Overterm alone — your terminal's current context isn't changed; the commands Overterm types are given it. The Docker page's engine menu picks one.",
            kind: .text(placeholder: "desktop-linux, orbstack, colima", monospaced: true), defaultValue: .string(""), requires: "docker.enabled"),
        SettingSpec(
            key: "docker.debugImage", section: .docker, group: "Docker", title: "Debug shell's image",
            help: "The toolbox a debug shell runs beside a container (E): it shares the container's processes and network; the container's files are at /proc/1/root.",
            kind: .text(placeholder: "nicolaka/netshoot", monospaced: true), defaultValue: .string("nicolaka/netshoot"), requires: "docker.enabled"),
        SettingSpec(
            key: "docker.checkPorts", section: .docker, group: "Compose", title: "Look at a stack's ports before an Up",
            help:
                "A checkout's stack whose host ports another worktree's stack or a program holds — or whose project name another checkout's has — is offered free ones first: an override in Overterm's folder, never in the repository. Off: Up runs as written; Up on Free Ports is still in the project's menu.",
            kind: .toggle, defaultValue: .bool(true), requires: "docker.enabled"),
        SettingSpec(
            key: "docker.notifyOnExit", section: .docker, group: "Attention", title: "Mark a checkout's tab when its container fails",
            help:
                "A container of the tab's checkout that exits with an error, runs out of memory or turns unhealthy marks the tab as a failed command does, and notifies you while you are elsewhere. One you stopped doesn't.",
            kind: .toggle, defaultValue: .bool(true), requires: "docker.enabled"),
        SettingSpec(
            key: "docker.agentAccess", section: .docker, group: "Agents", title: "Agents can see Docker",
            help:
                "Claude Code started from Overterm gets MCP tools to list the containers and compose projects, read a container's logs, inspect data and use. Env values that look like secrets are masked, and taken out of logs.",
            kind: .toggle, defaultValue: .bool(true), requires: "docker.enabled"),
        SettingSpec(
            key: "docker.agentWrites", section: .docker, group: "Agents", title: "Agents can ask to act",
            help:
                "Start, stop, restart or remove a container, change its memory, CPUs or restart policy, run compose, exec in a container — each asked about in the window first, and run only if you say so.",
            kind: .toggle, defaultValue: .bool(true), requires: "docker.agentAccess"),
        SettingSpec(
            key: "docker.showAllContainers", section: .docker, group: "Panel", title: "The panel lists what runs elsewhere too",
            help:
                "Under the selected tab's checkout's stack, the containers of other projects and of none that are running — Testcontainers' test runs in one row.",
            kind: .toggle, defaultValue: .bool(true), requires: "docker.enabled"),
    ]

    private static let kubernetes: [SettingSpec] = [
        SettingSpec(
            key: "kubernetes.enabled", section: .kubernetes, group: "Kubernetes", title: "Kubernetes in Overterm",
            help:
                "The contexts of your kubeconfig, their namespaces and pods. Nothing runs and no cluster is asked anything until the page or the panel opens, or an agent calls a k8s_ tool (Agents can read the clusters).",
            kind: .toggle, defaultValue: .bool(true)),
        SettingSpec(
            key: "kubernetes.kubeconfigs", section: .kubernetes, group: "Kubeconfigs", title: "More kubeconfig files",
            help:
                "Read after KUBECONFIG's files (else ~/.kube/config), merged as kubectl merges them: a context, cluster or user an earlier file names wins. A folder adds every file in it. Overterm never writes a kubeconfig.",
            kind: .list(placeholder: "~/.kube/other.kubeconfig"), defaultValue: .list([]), requires: "kubernetes.enabled"),
        SettingSpec(
            key: "kubernetes.contexts", section: .kubernetes, group: "Contexts", title: "Each context's own settings",
            help:
                "By the context's name: its class (production, remote or local; unset, its name decides), whether a remote or local one may be written to — a production one never is, its writes are turned on for a session — and its namespaces.",
            kind: .entries(SettingEntries(noun: "context", fields: KubeContextSettings.fields)), defaultValue: .entries([:]),
            requires: "kubernetes.enabled"),
        SettingSpec(
            key: "kubernetes.pinnedContexts", section: .kubernetes, group: "Contexts", title: "Pinned contexts",
            help: "At the top of the context picker and in the palette, in this order.",
            kind: .list(placeholder: "a context's name"), defaultValue: .list([]), requires: "kubernetes.enabled"),
        SettingSpec(
            key: "kubernetes.maxProxies", section: .kubernetes, group: "Connections", title: "Contexts connected at once",
            help:
                "Each context in use has one kubectl proxy, and kubectl keeps its credentials. One is always kept for the page's context; past this many, the least recently used idle one closes.",
            kind: .integer(1...16, step: 1, unit: "proxies"), defaultValue: .int(4), requires: "kubernetes.enabled"),
        SettingSpec(
            key: "kubernetes.proxyIdleMinutes", section: .kubernetes, group: "Connections", title: "Close a context's proxy after",
            help: "A proxy nothing has used for this long is closed; the next request starts it again.",
            kind: .integer(1...240, step: 1, unit: "minutes"), defaultValue: .int(10), requires: "kubernetes.enabled"),
        SettingSpec(
            key: "kubernetes.logStreams", section: .kubernetes, group: "Connections", title: "Containers followed at once in merged logs",
            help:
                "A Deployment's, StatefulSet's, DaemonSet's, Job's or Service's Logs tab follows each of its pods' containers, one stream each, merged by time. Past this many, the rest are left out — the tab says how many — until a followed pod goes.",
            kind: .integer(1...50, step: 1, unit: "streams"), defaultValue: .int(10), requires: "kubernetes.enabled"),
        SettingSpec(
            key: "kubernetes.kubectlPath", section: .kubernetes, group: "Connections", title: "kubectl",
            help:
                "Empty: the installed kubectl closest to the cluster's version — /usr/local/bin, /opt/homebrew/bin, Docker Desktop's, your shell's PATH. Overterm never downloads one.",
            kind: .text(placeholder: "/usr/local/bin/kubectl", monospaced: true), defaultValue: .string(""), requires: "kubernetes.enabled"),
        SettingSpec(
            key: "kubernetes.agentAccess", section: .kubernetes, group: "Agents", title: "Agents can read the clusters",
            help:
                "Claude Code started from Overterm gets MCP tools to list a context's objects, describe one, read a pod's logs and events, a rollout's status and history, what pods and nodes use (metrics-server's), and why a pod fails — through the context's proxy, production included. On the contexts Contexts agents may change names, it also gets k8s_restart, k8s_scale, k8s_delete_pod and k8s_apply (a manifest, its dry-run diff shown; on production only where the context sets applyOnProduction), each call asked in the window first. None reads a Secret's values; what looks like a secret is taken out of every answer.",
            kind: .toggle, defaultValue: .bool(true), requires: "kubernetes.enabled"),
        SettingSpec(
            key: "kubernetes.agentWrites", section: .kubernetes, group: "Agents", title: "Contexts agents may change",
            help:
                "By name: the contexts where agents get k8s_restart, k8s_scale, k8s_delete_pod and k8s_apply — empty, agents only read. Only while Overterm may write there too: a local or remote one by its writable setting, a production one while its writes are on for the session. Each call is still asked in the window, naming the context. An agent started before a name was added needs a restart to see the tools.",
            kind: .list(placeholder: "a context's name"), defaultValue: .list([]), requires: "kubernetes.agentAccess"),
        SettingSpec(
            key: "kubernetes.debugImage", section: .kubernetes, group: "Tabs", title: "Debug container's image",
            help:
                "What E runs beside a pod's container (kubectl debug --target) or on a node, in a tab — unless the context's own debugImage (a node: its nodeShellImage, then debugImage) says another. Only on writable contexts.",
            kind: .text(placeholder: "busybox:1.36", monospaced: true), defaultValue: .string("busybox:1.36"), requires: "kubernetes.enabled"),
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

/// `#rrggbb`, as settings.json and Ghostty write a colour.
enum SettingsColor {
    static func parse(_ text: String) -> (red: Double, green: Double, blue: Double)? {
        var hex = text.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    static func format(red: Double, green: Double, blue: Double) -> String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(red), byte(green), byte(blue))
    }
}
