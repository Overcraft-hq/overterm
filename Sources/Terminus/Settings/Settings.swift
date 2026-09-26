import Foundation

/// What Terminus ▸ Settings… (⌘,) sets. Kept in AppEnvironment.defaults, so
/// an isolated run has its own. Appearance values are Ghostty settings:
/// nil leaves the user's Ghostty config in charge, a value overrides it
/// (written to `ghosttyOverridesFile`, loaded after the user's config).
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings(defaults: AppEnvironment.defaults)

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

    /// Ghostty's cursor-style values.
    enum CursorStyle: String, CaseIterable, Identifiable {
        case block, bar, underline
        var id: String { rawValue }
    }

    // MARK: General

    @Published var restoreTabs: Bool { didSet { save(restoreTabs, "restoreTabs") } }
    @Published var restoreScrollback: Bool { didSet { save(restoreScrollback, "restoreScrollback") } }
    @Published var newTabDirectory: NewTabDirectory { didSet { save(newTabDirectory.rawValue, "newTabDirectory") } }
    @Published var confirmClose: CloseConfirmation { didSet { save(confirmClose.rawValue, "confirmClose") } }
    @Published var notifications: Bool { didSet { save(notifications, "notifications") } }
    @Published var dockBadge: Bool { didSet { save(dockBadge, "dockBadge") } }

    // MARK: Appearance

    @Published var fontFamily: String? { didSet { save(fontFamily, "fontFamily") } }
    @Published var fontSize: Double? { didSet { save(fontSize, "fontSize") } }
    @Published var theme: String? { didSet { save(theme, "theme") } }
    @Published var windowPadding: Int? { didSet { save(windowPadding, "windowPadding") } }
    @Published var cursorStyle: CursorStyle? { didSet { save(cursorStyle?.rawValue, "cursorStyle") } }
    /// How much the panes without the keyboard are dimmed, 0…0.7.
    @Published var unfocusedPaneDim: Double { didSet { save(unfocusedPaneDim, "unfocusedPaneDim") } }

    private let defaults: UserDefaults
    private static let prefix = "settings."

    init(defaults: UserDefaults) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: Self.prefix + key) as? Bool ?? fallback }
        func string(_ key: String) -> String? { defaults.string(forKey: Self.prefix + key) }
        restoreTabs = bool("restoreTabs", true)
        restoreScrollback = bool("restoreScrollback", true)
        newTabDirectory = string("newTabDirectory").flatMap(NewTabDirectory.init(rawValue:)) ?? .current
        confirmClose = string("confirmClose").flatMap(CloseConfirmation.init(rawValue:)) ?? .always
        notifications = bool("notifications", true)
        dockBadge = bool("dockBadge", true)
        fontFamily = string("fontFamily")
        fontSize = defaults.object(forKey: Self.prefix + "fontSize") as? Double
        theme = string("theme")
        windowPadding = defaults.object(forKey: Self.prefix + "windowPadding") as? Int
        cursorStyle = string("cursorStyle").flatMap(CursorStyle.init(rawValue:))
        unfocusedPaneDim = defaults.object(forKey: Self.prefix + "unfocusedPaneDim") as? Double ?? 0.35
    }

    private func save(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: Self.prefix + key) } else { defaults.removeObject(forKey: Self.prefix + key) }
    }

    // MARK: Ghostty overrides

    /// Loaded after the user's Ghostty config: only what Settings sets.
    static var ghosttyOverridesFile: URL { AppEnvironment.supportDirectory.appendingPathComponent("ghostty-overrides.conf") }

    /// The overrides as Ghostty config lines.
    var ghosttyOverrides: String {
        Self.ghosttyOverrides(fontFamily: fontFamily, fontSize: fontSize, theme: theme, windowPadding: windowPadding, cursorStyle: cursorStyle)
    }

    nonisolated static func ghosttyOverrides(
        fontFamily: String?, fontSize: Double?, theme: String?, windowPadding: Int?, cursorStyle: CursorStyle?
    ) -> String {
        var lines = ["# Written by Terminus ▸ Settings. Loaded after your Ghostty config; edits here are overwritten."]
        // A family, not a list: one line resets Ghostty's fallback list to it.
        if let fontFamily, !fontFamily.isEmpty { lines.append("font-family = \"\(fontFamily)\"") }
        if let fontSize { lines.append("font-size = \(String(format: "%g", fontSize))") }
        if let theme, !theme.isEmpty { lines.append("theme = \"\(theme)\"") }
        if let windowPadding {
            lines.append("window-padding-x = \(windowPadding)")
            lines.append("window-padding-y = \(windowPadding)")
        }
        if let cursorStyle { lines.append("cursor-style = \(cursorStyle.rawValue)") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the overrides file (nothing when there is nothing to override).
    func writeGhosttyOverrides() {
        let url = Self.ghosttyOverridesFile
        let text = ghosttyOverrides
        if text.split(separator: "\n").count <= 1 {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
