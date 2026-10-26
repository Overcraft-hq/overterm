import Combine
import Foundation

/// What Settings sets, kept as VS Code keeps it: settings.json in the
/// support directory (an isolated run has its own), holding only what
/// differs from the defaults (SettingsSchema). The Settings page edits it;
/// so can anyone, by hand — comments are fine, and a change made outside
/// the app applies at once. A file that doesn't parse is never written
/// over: the last good settings stay and the page says what is wrong.
///
/// Appearance and Terminal values are Ghostty options: unset leaves the
/// user's Ghostty config in charge, a value overrides it (written to
/// `ghosttyOverridesFile`, loaded after the user's config).
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings(
        url: AppEnvironment.supportDirectory.appendingPathComponent("settings.json"), legacy: AppEnvironment.defaults)

    enum NewTabDirectory: String, CaseIterable, Identifiable {
        /// The selected tab's directory.
        case current
        case home
        var id: String { rawValue }
    }

    enum CloseConfirmation: String, CaseIterable, Identifiable {
        case always
        /// Only when something runs in what closes.
        case whenRunning
        var id: String { rawValue }
    }

    /// Where New Task puts a worktree.
    enum WorktreeLocation: String, CaseIterable, Identifiable {
        /// Next to the repository: `<repo>-wt-<branch>`.
        case sibling
        /// Inside it: `<repo>/.worktrees/<branch>`, locally ignored.
        case inside
        var id: String { rawValue }
    }

    let url: URL
    /// What the file sets, each value valid for its setting.
    @Published private(set) var values: [String: SettingValue] = [:]
    /// What is wrong with the file: it doesn't parse (and nothing in it
    /// applies), or a setting's value can't be used (that one doesn't).
    @Published private(set) var problems: [String] = []
    /// The keys whose values changed, as they change — from the page, or
    /// from the file edited by hand.
    let changes = PassthroughSubject<Set<String>, Never>()

    /// The file as last read or written, to tell an outside edit from our own.
    private var knownText: String?
    private var watcher: DirectoryWatcher?

    init(url: URL, legacy: UserDefaults? = nil, watch: Bool = true) {
        self.url = url
        if let legacy { Self.migrate(from: legacy, to: url) }
        load()
        if watch {
            // FSEvents follows a directory that exists. Until the app had
            // written something of its own there was none, and a
            // settings.json put there by hand went unnoticed until the next
            // launch — which used to be hidden by the snippets file being
            // written on a first run.
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            watcher = DirectoryWatcher(root: directory, latency: 0.2) { [weak self] _ in self?.reloadIfChanged() }
        }
    }

    // MARK: Reading

    /// The setting's value: the file's, else its default.
    func value(_ key: String) -> SettingValue? {
        values[key] ?? SettingsSchema.byKey[key]?.defaultValue
    }

    /// Whether the file sets it (Settings shows a reset for those).
    func isSet(_ key: String) -> Bool { values[key] != nil }

    func bool(_ key: String) -> Bool { value(key)?.bool ?? false }
    func string(_ key: String) -> String { value(key)?.string ?? "" }
    func number(_ key: String) -> Double? { value(key)?.number }

    /// The file's text, for the JSON view; a fresh one when there is none.
    var fileText: String { (try? String(contentsOf: url, encoding: .utf8)) ?? "{\n}\n" }

    // MARK: Writing

    /// Sets `key` (nil: back to its default), editing the file in place.
    func set(_ key: String, _ value: SettingValue?) {
        guard let spec = SettingsSchema.byKey[key] else { return }
        let stored = value == spec.defaultValue ? nil : value
        guard values[key] != stored else { return }
        // A file that doesn't parse is the user's to fix, not ours to lose.
        guard problemsParsing == false else { return }
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? "{\n}\n"
        var all = values
        all[key] = stored
        // In place when the file's layout allows, else rewritten whole.
        let text = SettingsJSON.setting(current, key: key, json: stored?.json) ?? SettingsJSON.text(of: all)
        write(text)
        apply(text)
    }

    /// The JSON view's Save: the text as typed, written even when it has
    /// problems — they are shown, and the good parts apply.
    func save(text: String) {
        write(text)
        apply(text)
    }

    /// Re-reads the file now (the watcher does so on its own).
    func reload() { load() }

    private var problemsParsing = false

    private func write(_ text: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        knownText = text
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

    /// Takes the text's settings: every valid one, the rest reported.
    private func apply(_ text: String) {
        let object: [String: Any]
        do {
            object = try SettingsJSON.object(from: text)
        } catch {
            problemsParsing = true
            problems = ["settings.json doesn't parse, so none of it applies until it does: \(error.message)"]
            return
        }
        problemsParsing = false
        var parsed: [String: SettingValue] = [:]
        var found: [String] = []
        for (key, raw) in object.sorted(by: { $0.key < $1.key }) {
            guard let spec = SettingsSchema.byKey[key] else {
                found.append("\"\(key)\" isn't a setting Overterm knows; it is left as it is.")
                continue
            }
            guard let value = SettingValue(json: raw) else {
                found.append("\"\(key)\" \(spec.problem(with: .string("")) ?? "has a value Overterm can't use").")
                continue
            }
            // A whole number where a fraction fits is fine (1 for 1.0).
            let fitted: SettingValue =
                if case .number = spec.kind, case .int(let int) = value { .double(Double(int)) } else { value }
            if let problem = spec.problem(with: fitted) {
                found.append("\"\(key)\" \(problem); its default applies.")
                continue
            }
            parsed[key] = fitted
        }
        problems = found
        let changed = Set(parsed.keys).union(values.keys).filter { parsed[$0] != values[$0] }
        guard !changed.isEmpty else { return }
        values = parsed
        changes.send(changed)
    }

    // MARK: Before settings.json

    /// Carries the UserDefaults settings of earlier versions into
    /// settings.json — once: a flag keeps a deleted file from coming back.
    static func migrate(from defaults: UserDefaults, to url: URL) {
        let flag = "settings.movedToFile"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        var values: [String: SettingValue] = [:]
        for (old, key) in SettingsSchema.legacyKeys {
            guard let raw = defaults.object(forKey: "settings." + old), let spec = SettingsSchema.byKey[key],
                var value = SettingValue(json: raw)
            else { continue }
            if case .number = spec.kind, case .int(let int) = value { value = .double(Double(int)) }
            if case .integer = spec.kind, case .double(let double) = value { value = .int(Int(double)) }
            guard spec.problem(with: value) == nil, value != spec.defaultValue else { continue }
            values[key] = value
        }
        guard !values.isEmpty else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? SettingsJSON.text(of: values).write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Typed, for the rest of the app

    var restoreTabs: Bool { bool("general.restoreTabs") }
    var restoreScrollback: Bool { restoreTabs && bool("general.restoreScrollback") }
    var scrollbackLines: Int { Int(number("general.scrollbackLines") ?? 2000) }
    var newTabDirectory: NewTabDirectory { NewTabDirectory(rawValue: string("general.newTabDirectory")) ?? .current }
    var confirmClose: CloseConfirmation { CloseConfirmation(rawValue: string("general.confirmClose")) ?? .always }
    var tabPeekGesture: TabPeekGesture.Fingers { TabPeekGesture.Fingers(rawValue: string("general.tabPeekGesture")) ?? .three }
    var checkForUpdates: Bool { bool("updates.checkDaily") }

    var notifications: Bool { bool("notifications.enabled") }
    var dockBadge: Bool { bool("notifications.dockBadge") }

    /// Whether a mark of this kind sends a notification.
    func notifies(_ mark: TabActivity.Mark) -> Bool {
        guard notifications else { return false }
        switch mark {
        case .waiting: return bool("notifications.waiting")
        case .done: return bool("notifications.finished")
        case .failed: return bool("notifications.failed")
        case .none: return false
        }
    }

    /// What New Task starts: an agent's raw value, or "shell".
    var taskAgent: String { string("agents.newTaskAgent") }
    var defaultTaskAgent: Agent? { Agent(rawValue: taskAgent) }
    var claudeArguments: String { string("agents.claudeArguments") }
    var codexArguments: String { string("agents.codexArguments") }
    var worktreeLocation: WorktreeLocation { WorktreeLocation(rawValue: string("agents.worktreeLocation")) ?? .sibling }
    /// New Task's "From"; empty is the main worktree's branch.
    var taskBase: String { string("agents.newTaskBase") }

    /// Added to an agent's command wherever it starts or resumes.
    func arguments(for agent: Agent) -> String {
        switch agent {
        case .claude:
            // The tab's browser, for Claude Code — the pane being made has the
            // file (TerminalView sets the variable; BrowserBridge writes it).
            BrowserBridge.shared.isServing
                ? (claudeArguments + " --mcp-config \"$\(BrowserBridge.configVariable)\"").trimmingCharacters(in: .whitespaces)
                : claudeArguments
        case .codex: codexArguments
        }
    }

    /// The quota gauge at the right of the tab strip.
    var usageChip: Bool { bool("general.usageChip") }
    /// Whether the usage pane runs the agents' own usage command to keep
    /// its numbers current.
    var usageAsk: Bool { bool("general.usageAsk") }
    /// Whether the usage pane puts a price on the tokens it counts.
    var usageCost: Bool { bool("general.usageCost") }

    /// How many commits Overgit's history and graph read.
    var overgitCommits: Int { Int(number("general.overgitCommits") ?? 300) }
    /// Whether that history is every branch's or only the one checked out.
    var overgitAllRefs: Bool { bool("general.overgitAllRefs") }

    /// Whether the terminal follows macOS between two themes.
    var followsSystemAppearance: Bool { bool("appearance.followSystemAppearance") }

    /// The theme in force for an appearance: the pair's half while it
    /// follows macOS, else the one theme. Empty when Settings sets none and
    /// the user's own Ghostty config decides.
    func themeName(dark: Bool) -> String {
        followsSystemAppearance && !dark ? string("appearance.themeLight") : string("appearance.theme")
    }

    /// How much the panes without the keyboard are dimmed, 0…0.7.
    var unfocusedPaneDim: Double { number("appearance.unfocusedPaneDim") ?? 0.35 }
    var editorFontSize: Double { number("editor.fontSize") ?? 13 }
    var editorFontFamily: String { string("editor.fontFamily") }
    /// Times the font's own height.
    var editorLineHeight: CGFloat {
        switch string("editor.lineHeight") {
        case "compact": 1.2
        case "standard": 1.4
        default: 1.618
        }
    }
    var editorSoftWrap: String { string("editor.softWrap") }
    var editorTabSize: Int { Int(number("editor.tabSize") ?? 4) }
    var editorIndentGuides: Bool { bool("editor.indentGuides") }
    var editorOpenZoomed: Bool { bool("editor.openZoomed") }
    var editorGitGutter: Bool { bool("editor.gitGutter") }
    var editorLanguageServers: Bool { bool("editor.languageServers") }
    var editorCompletions: Bool { bool("editor.completions") }
    var editorFormatOnSave: Bool { bool("editor.formatOnSave") }
    var editorVimMode: Bool { bool("editor.vimMode") }
    var editorRelativeLineNumbers: Bool { bool("editor.relativeLineNumbers") }
    var browserEnabled: Bool { bool("browser.enabled") }
    var simulatorEnabled: Bool { bool("browser.simulator") }
    var browserLinks: BrowserLinks.Policy { browserEnabled ? BrowserLinks.Policy(rawValue: string("browser.openLinks")) ?? .local : .none }
    var browserReloadOnSave: Bool { browserEnabled && bool("browser.reloadOnSave") }
    var browserAgentControl: Bool { browserEnabled && bool("browser.agentControl") }
    var apiEnabled: Bool { bool("api.enabled") }
    var apiTimeout: Int { Int(number("api.timeout") ?? 30) }
    var apiFollowRedirects: Bool { bool("api.followRedirects") }
    var apiVerifyTLS: Bool { bool("api.verifyTLS") }
    var apiDiscoverServers: Bool { bool("api.discoverServers") }
    var apiAgentControl: Bool { apiEnabled && bool("api.agentControl") }
    var notesEnabled: Bool { bool("notes.enabled") }
    var notesVaultPath: String { string("notes.vaultPath") }
    var notesAgentAccess: Bool { notesEnabled && bool("notes.agentAccess") }
    var databaseEnabled: Bool { bool("database.enabled") }
    var sessionsEnabled: Bool { bool("general.sessions") }
    var snippetsEnabled: Bool { bool("general.snippets") }
    var databaseRowLimit: Int { Int(number("database.rowLimit") ?? 500) }
    var databaseConfirmDestructive: Bool { databaseEnabled && bool("database.confirmDestructive") }
    var databaseAgentAccess: Bool { databaseEnabled && bool("database.agentAccess") }
    var databaseAgentWrites: Bool { databaseAgentAccess && bool("database.agentWrites") }
    var notesLivePreview: Bool { notesEnabled && bool("notes.livePreview") }

    // MARK: Ghostty overrides

    /// Loaded after the user's Ghostty config: only what Settings sets.
    static var ghosttyOverridesFile: URL { AppEnvironment.supportDirectory.appendingPathComponent("ghostty-overrides.conf") }

    /// The Ghostty lines for what is set, then `keybindings`' lines.
    func ghosttyOverrides(keybindings: [String] = []) -> String {
        Self.ghosttyOverrides(values: values, keybindings: keybindings)
    }

    nonisolated static func ghosttyOverrides(values: [String: SettingValue], keybindings: [String] = []) -> String {
        var lines = ["# Written by Overterm ▸ Settings (settings.json). Loaded after your Ghostty config; edits here are overwritten."]
        lines += themeLines(values: values)
        for spec in SettingsSchema.all {
            guard let option = spec.ghostty, option != "theme", let value = values[spec.key] else { continue }
            lines += ghosttyLines(option: option, value: value)
        }
        lines += keybindings
        return lines.joined(separator: "\n") + "\n"
    }

    /// `theme` takes one name, or a pair Ghostty switches between as macOS
    /// does — `light:A,dark:B`. The pair can't be quoted (the comma and the
    /// colon are the syntax), and doesn't need to be: Ghostty reads the rest
    /// of the line, so a name with spaces in it arrives whole.
    nonisolated static func themeLines(values: [String: SettingValue]) -> [String] {
        let dark = values["appearance.theme"]?.string ?? ""
        let light = values["appearance.themeLight"]?.string ?? ""
        if values["appearance.followSystemAppearance"]?.bool == true, !dark.isEmpty, !light.isEmpty {
            return ["theme = light:\(light),dark:\(dark)"]
        }
        guard !dark.isEmpty else { return [] }
        return ["theme = \"\(dark)\""]
    }

    nonisolated static func ghosttyLines(option: String, value: SettingValue) -> [String] {
        switch (option, value) {
        // A family, not a list: one line resets Ghostty's fallback list to it.
        case ("font-family", .string(let family)) where !family.isEmpty: ["font-family = \"\(family)\""]
        case ("window-padding", _): value.number.map { ["window-padding-x = \(Int($0))", "window-padding-y = \(Int($0))"] } ?? []
        case ("scrollback-limit", _): value.number.map { ["scrollback-limit = \(Int($0) * 1_000_000)"] } ?? []
        case (_, .bool(let flag)): ["\(option) = \(flag)"]
        case (_, .int(let number)): ["\(option) = \(number)"]
        case (_, .double(let number)): ["\(option) = \(String(format: "%g", number))"]
        case (_, .string(let text)) where !text.isEmpty: ["\(option) = \(text)"]
        default: []
        }
    }

    /// Writes the overrides file (none when there is nothing to override).
    /// Returns whether it changed — Ghostty reloads only then.
    @discardableResult
    func writeGhosttyOverrides(keybindings: [String] = []) -> Bool {
        let url = Self.ghosttyOverridesFile
        let text = ghosttyOverrides(keybindings: keybindings)
        let current = try? String(contentsOf: url, encoding: .utf8)
        if text.split(separator: "\n").count <= 1 {
            guard current != nil else { return false }
            try? FileManager.default.removeItem(at: url)
            return true
        }
        guard text != current else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return true
    }
}
