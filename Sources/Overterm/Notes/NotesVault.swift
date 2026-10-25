import Foundation

/// A notes vault: a folder of Markdown files, as Obsidian keeps one — the
/// same folder opens in Obsidian, on the phone through iCloud, and here.
/// Overterm keeps nothing of its own in it; `.obsidian/` is read for the
/// settings that decide where things go, never written.
struct NotesVault: Equatable, Sendable {
    let root: URL
    let settings: ObsidianSettings
    /// The root with its links resolved, once: a path from walking the
    /// root needs none, and resolving each one cost a call per component.
    private let resolvedRoot: String

    init(root: URL) {
        self.root = root.standardizedFileURL
        resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        settings = ObsidianSettings.read(from: root)
    }

    var name: String { root.lastPathComponent }

    /// Where the vault is when Settings names none: a folder in iCloud Drive,
    /// so it is on every device — or Documents without iCloud Drive.
    static var defaultRoot: URL {
        if AppEnvironment.isIsolated { return AppEnvironment.supportDirectory.appendingPathComponent("notes-vault", isDirectory: true) }
        let iCloudDrive = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if FileManager.default.fileExists(atPath: iCloudDrive.path) {
            return iCloudDrive.appendingPathComponent("Overterm Notes", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Overterm Notes", isDirectory: true)
    }

    /// Settings ▸ Notes' path, `~` expanded; the default when empty.
    static func root(fromSetting path: String) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultRoot }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Whether the vault is in iCloud (Drive or an app's container): files
    /// there may not be downloaded, and are written coordinated.
    var isUbiquitous: Bool { root.path.contains("/Library/Mobile Documents/") }

    // MARK: Paths

    /// A note's path inside the vault, without `.md`: what links name.
    func relativePath(of url: URL) -> String {
        let plain = url.standardizedFileURL.path
        if plain.hasPrefix(root.path + "/") { return String(plain.dropFirst(root.path.count + 1)) }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(resolvedRoot + "/") ? String(path.dropFirst(resolvedRoot.count + 1)) : url.lastPathComponent
    }

    func contains(_ url: URL) -> Bool {
        let plain = url.standardizedFileURL.path
        if plain == root.path || plain.hasPrefix(root.path + "/") { return true }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path == resolvedRoot || path.hasPrefix(resolvedRoot + "/")
    }

    /// Where a new note goes, as Obsidian's "Default location for new notes" says.
    func folderForNewNote(beside current: URL?) -> URL {
        switch settings.newFileLocation {
        case .current: current?.deletingLastPathComponent() ?? root
        case .folder: root.appendingPathComponent(settings.newFileFolderPath, isDirectory: true)
        case .root: root
        }
    }

    /// Where a pasted image goes, as Obsidian's "Default location for new
    /// attachments" says: `/` the vault, `./` beside the note, `./x` a folder
    /// beside it, `x` a folder in the vault.
    func folderForAttachment(of note: URL) -> URL {
        let path = settings.attachmentFolderPath
        if path.isEmpty || path == "/" { return root }
        if path == "./" || path == "." { return note.deletingLastPathComponent() }
        if path.hasPrefix("./") { return note.deletingLastPathComponent().appendingPathComponent(String(path.dropFirst(2)), isDirectory: true) }
        return root.appendingPathComponent(path, isDirectory: true)
    }

    /// What the vault never has: dotfiles — Obsidian's own folder, the Trash.
    func isHidden(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix(".") && !name.hasSuffix(".icloud")
    }

    /// What "Excluded files" lists: not in the tree, but still notes —
    /// links to them resolve, as in Obsidian.
    func isExcluded(_ url: URL) -> Bool {
        guard !settings.userIgnoreFilters.isEmpty else { return false }
        let relative = relativePath(of: url)
        return settings.userIgnoreFilters.contains { filter in
            let trimmed = filter.hasSuffix("/") ? String(filter.dropLast()) : filter
            return relative == trimmed || relative.hasPrefix(trimmed + "/")
        }
    }
}

/// What `.obsidian/` says about where things go — the settings a vault
/// shared with Obsidian has to agree on.
struct ObsidianSettings: Equatable, Sendable {
    enum NewFileLocation: String, Sendable { case root, current, folder }

    var attachmentFolderPath = "/"
    var newFileLocation = NewFileLocation.root
    var newFileFolderPath = ""
    /// `[[wikilinks]]` (Obsidian's default) or `[text](path.md)`.
    var useMarkdownLinks = false
    /// "shortest", "relative" or "absolute": how a new link names its note.
    var newLinkFormat = "shortest"
    var userIgnoreFilters: [String] = []
    /// "Strict line breaks": off (Obsidian's default), a single newline
    /// breaks the line in the reading view.
    var strictLineBreaks = false
    /// Daily notes: folder, moment.js format, template.
    var dailyFolder = ""
    var dailyFormat = "YYYY-MM-DD"
    var dailyTemplate = ""
    var templatesFolder = ""
    var templateDateFormat = "YYYY-MM-DD"
    var templateTimeFormat = "HH:mm"

    static func read(from root: URL) -> ObsidianSettings {
        var settings = ObsidianSettings()
        let folder = root.appendingPathComponent(".obsidian", isDirectory: true)
        func json(_ name: String) -> [String: Any] {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return [:] }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        let app = json("app.json")
        if let path = app["attachmentFolderPath"] as? String { settings.attachmentFolderPath = path }
        if let location = (app["newFileLocation"] as? String).flatMap(NewFileLocation.init(rawValue:)) { settings.newFileLocation = location }
        if let path = app["newFileFolderPath"] as? String { settings.newFileFolderPath = path }
        if let markdown = app["useMarkdownLinks"] as? Bool { settings.useMarkdownLinks = markdown }
        if let format = app["newLinkFormat"] as? String { settings.newLinkFormat = format }
        if let filters = app["userIgnoreFilters"] as? [String] { settings.userIgnoreFilters = filters }
        if let strict = app["strictLineBreaks"] as? Bool { settings.strictLineBreaks = strict }
        let daily = json("daily-notes.json")
        if let path = daily["folder"] as? String { settings.dailyFolder = path }
        if let format = daily["format"] as? String, !format.isEmpty { settings.dailyFormat = format }
        if let template = daily["template"] as? String { settings.dailyTemplate = template }
        let templates = json("templates.json")
        if let path = templates["folder"] as? String { settings.templatesFolder = path }
        if let format = templates["dateFormat"] as? String, !format.isEmpty { settings.templateDateFormat = format }
        if let format = templates["timeFormat"] as? String, !format.isEmpty { settings.templateTimeFormat = format }
        return settings
    }
}

/// The vaults Obsidian knows on this Mac, from its own list — to pick one
/// in Settings rather than type its path.
enum ObsidianVaults {
    static var listFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
    }

    static func known(listFile: URL = listFile) -> [URL] {
        guard let data = try? Data(contentsOf: listFile),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let vaults = json["vaults"] as? [String: [String: Any]]
        else { return [] }
        return
            vaults.values
            .sorted { ($0["ts"] as? Double ?? 0) > ($1["ts"] as? Double ?? 0) }
            .compactMap { $0["path"] as? String }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Moment.js date formats — what Obsidian's daily notes and templates use —
/// as DateFormatter patterns, for the tokens people use.
enum MomentFormat {
    static func string(from date: Date, format: String, locale: Locale = Locale(identifier: "en_US_POSIX")) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = pattern(format)
        return formatter.string(from: date)
    }

    /// Token by token, longest first; text in [brackets] is literal.
    static func pattern(_ moment: String) -> String {
        let tokens: [(String, String)] = [
            ("YYYY", "yyyy"), ("YY", "yy"), ("MMMM", "MMMM"), ("MMM", "MMM"), ("MM", "MM"), ("M", "M"), ("DDDD", "DDD"), ("DD", "dd"),
            ("Do", "d"), ("D", "d"), ("dddd", "EEEE"), ("ddd", "EEE"), ("dd", "EEEEEE"), ("d", "e"), ("HH", "HH"), ("H", "H"),
            ("hh", "hh"), ("h", "h"), ("mm", "mm"), ("m", "m"), ("ss", "ss"), ("s", "s"), ("A", "a"), ("a", "a"), ("WW", "ww"),
            ("W", "w"), ("gggg", "YYYY"), ("Q", "Q"), ("ZZ", "xx"), ("Z", "xxx"),
        ]
        var out = ""
        var rest = Substring(moment)
        while !rest.isEmpty {
            if rest.first == "[", let close = rest.firstIndex(of: "]") {
                let literal = rest[rest.index(after: rest.startIndex)..<close]
                out += "'" + literal.replacingOccurrences(of: "'", with: "''") + "'"
                rest = rest[rest.index(after: close)...]
                continue
            }
            if let (token, pattern) = tokens.first(where: { rest.hasPrefix($0.0) }) {
                out += pattern
                rest = rest.dropFirst(token.count)
                continue
            }
            let char = rest.removeFirst()
            out += char.isLetter ? "'\(char)'" : String(char)
        }
        return out
    }
}
