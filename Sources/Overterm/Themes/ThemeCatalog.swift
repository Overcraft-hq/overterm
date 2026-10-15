import Combine
import Foundation

/// Every theme this Mac can show, read off disk once.
///
/// Two places, and the gallery keeps them apart: the ones bundled with the
/// app — Ghostty's own, plus the rest of iTerm2-Color-Schemes
/// (Scripts/fetch-themes.sh) — and the user's own
/// `~/.config/ghostty/themes`, which Ghostty reads as well, so a theme
/// dropped in there works without the app knowing anything about it.
///
/// Reading 800 small files takes a few milliseconds, but it happens off the
/// main actor anyway: the gallery is the only thing that wants them, and it
/// fades them in when they arrive.
@MainActor
final class ThemeCatalog: ObservableObject {
    static let shared = ThemeCatalog()

    /// Where a theme came from, which is also how the gallery groups them.
    enum Source: String, CaseIterable, Sendable {
        case builtIn
        case user

        var title: String {
            switch self {
            case .builtIn: "Built in"
            case .user: "Yours"
            }
        }
    }

    struct Entry: Identifiable, Sendable {
        let theme: TerminalTheme
        let source: Source
        var id: String { theme.name }
    }

    /// Every theme, by name. Empty until `load()` finishes.
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isLoaded = false

    private let directories: [(URL, Source)]
    private var loading = false

    init(directories: [(URL, Source)]? = nil) {
        self.directories =
            directories
            ?? [AppEnvironment.bundledThemesDirectory.map { ($0, Source.builtIn) }, AppEnvironment.userThemesDirectory.map { ($0, .user) }]
            .compactMap { $0 }
    }

    /// Reads the files, once per launch. Called when Settings ▸ Themes
    /// opens — not at launch, where nothing needs them.
    func load() {
        guard !isLoaded, !loading else { return }
        loading = true
        let directories = directories
        Task {
            let entries = await Task.detached { Self.scan(directories) }.value
            self.entries = entries
            self.isLoaded = true
            self.loading = false
        }
    }

    /// The directories' theme files, parsed. A name found twice keeps the
    /// first — the same order Ghostty resolves `theme =` in, so what the
    /// gallery draws is what the terminal takes.
    nonisolated static func scan(_ directories: [(URL, Source)]) -> [Entry] {
        var seen = Set<String>()
        var entries = [Entry]()
        for (directory, source) in directories {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names.sorted() {
                guard !name.hasPrefix("."), !seen.contains(name),
                    // The fetched directory carries its licence and a note.
                    !["LICENSE", "README.md"].contains(name),
                    let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8),
                    let theme = TerminalTheme.parse(text, name: name)
                else { continue }
                seen.insert(name)
                entries.append(Entry(theme: theme, source: source))
            }
        }
        return entries.sorted { $0.theme.name.localizedCaseInsensitiveCompare($1.theme.name) == .orderedAscending }
    }

    /// The ten to open on. Ghostty's catalogue is 473 themes deep, which is
    /// a wall, not a choice; these are the ones people name, a light one
    /// for every two dark, in the order they are shown.
    nonisolated static let popular = [
        "Catppuccin Mocha", "TokyoNight Night", "Dracula", "Gruvbox Dark", "Nord",
        "Rose Pine", "Everforest Dark Hard", "Claude Dark", "Catppuccin Latte", "One Half Light",
    ]

    /// What the gallery shows: themes whose name matches, of the asked-for
    /// kind. Pure, so the filtering is tested without any files.
    nonisolated static func filter(_ entries: [Entry], search: String, showing: Showing) -> [Entry] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let found = entries.filter { entry in
            guard showing.accepts(entry.theme) else { return false }
            guard !query.isEmpty else { return true }
            return entry.theme.name.lowercased().contains(query)
        }
        guard showing == .popular else { return found }
        // Shown as the list names them, not alphabetically: the first card
        // is the one most people would have picked.
        return found.sorted { popular.firstIndex(of: $0.theme.name) ?? 0 < popular.firstIndex(of: $1.theme.name) ?? 0 }
    }

    /// Which themes the gallery is showing: the ten to start from, or the
    /// whole catalogue, dark, light or both.
    enum Showing: String, CaseIterable, Identifiable, Sendable {
        case popular, dark, light, all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .popular: "Popular"
            case .dark: "Dark"
            case .light: "Light"
            case .all: "All"
            }
        }

        func accepts(_ theme: TerminalTheme) -> Bool {
            switch self {
            case .popular: ThemeCatalog.popular.contains(theme.name)
            case .dark: theme.isDark
            case .light: !theme.isDark
            case .all: true
            }
        }
    }

    func theme(named name: String) -> TerminalTheme? {
        entries.first { $0.theme.name == name }?.theme
    }

    /// One theme, read from disk now rather than waiting for the gallery:
    /// the chrome asks for the one in force while the window is being built
    /// (`GhosttyRuntime.backgroundColor`). One small file, and the answer
    /// is kept.
    @MainActor
    static func read(_ name: String) -> TerminalTheme? {
        if let known = cache[name] { return known }
        let directories = [AppEnvironment.bundledThemesDirectory, AppEnvironment.userThemesDirectory].compactMap { $0 }
        for directory in directories.reversed() {
            guard let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8),
                let theme = TerminalTheme.parse(text, name: name)
            else { continue }
            cache[name] = theme
            return theme
        }
        return nil
    }

    @MainActor private static var cache: [String: TerminalTheme] = [:]
}
