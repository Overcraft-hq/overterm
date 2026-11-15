import Foundation

/// An LSP glob pattern (3.17 `GlobPattern`): `*` within a segment, `?` one
/// character, `**` any number of segments (none too), `{a,b}` either,
/// `[a-z]` and `[!a-z]` a character. A string pattern matches an absolute
/// path (`**/*.go`, gopls' `/abs/dir/**/*.{go,mod}`), else the path below
/// the server's root (`src/*.rs`); a `RelativePattern` matches the path
/// below its base folder only.
///
/// Pure. Compiled once, to a regular expression (immutable and safe across
/// threads); matching is then one anchored ICU match per path.
struct LSPGlob: @unchecked Sendable, Hashable, CustomStringConvertible {
    /// As the server wrote it.
    let pattern: String
    /// A RelativePattern's folder, as an absolute path without a trailing
    /// slash; nil for a string pattern.
    let base: String?
    private let regex: NSRegularExpression

    /// nil for a pattern that can't be read (an unclosed `{`): it then
    /// matches nothing, as a server's typo should.
    init?(_ pattern: String, base: String? = nil) {
        guard !pattern.isEmpty, let source = Self.regularExpression(for: pattern),
            let regex = try? NSRegularExpression(pattern: source)
        else { return nil }
        self.pattern = pattern
        self.base = base.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        self.regex = regex
    }

    var description: String { base.map { "\($0) + \(pattern)" } ?? pattern }

    static func == (a: LSPGlob, b: LSPGlob) -> Bool { a.pattern == b.pattern && a.base == b.base }
    func hash(into hasher: inout Hasher) {
        hasher.combine(pattern)
        hasher.combine(base)
    }

    /// Whether this absolute path matches; `root` is what a string pattern
    /// that isn't absolute (`src/*.rs`) is taken below.
    func matches(_ path: String, root: String? = nil) -> Bool {
        if let base {
            guard let relative = Self.relative(path, to: base) else { return false }
            return whole(relative)
        }
        if whole(path) { return true }
        guard !pattern.hasPrefix("/"), let root, let relative = Self.relative(path, to: root) else { return false }
        return whole(relative)
    }

    private func whole(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [.anchored], range: range)?.range == range
    }

    /// `path` below `folder`, without the slash; nil when it isn't below it.
    static func relative(_ path: String, to folder: String) -> String? {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// The folder before the first wildcard of an absolute pattern
    /// (`/abs/dir/**/*.go` → `/abs/dir`): where a watcher must look.
    static func literalFolder(of pattern: String) -> String? {
        guard pattern.hasPrefix("/") else { return nil }
        let meta = pattern.firstIndex { "*?[{".contains($0) } ?? pattern.endIndex
        let head = pattern[..<meta]
        guard let slash = head.lastIndex(of: "/") else { return nil }
        let folder = String(head[..<slash])
        return folder.isEmpty ? "/" : folder
    }

    /// The glob as an anchored ICU expression; nil if its braces don't close.
    static func regularExpression(for pattern: String) -> String? {
        let characters = Array(pattern)
        var out = "^"
        var depth = 0
        var index = 0
        func escaped(_ character: Character) -> String { NSRegularExpression.escapedPattern(for: String(character)) }
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                let atSegmentStart = index == 0 || characters[index - 1] == "/"
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    let next = index + 2
                    if atSegmentStart, next < characters.count, characters[next] == "/" {
                        // `**/`: any number of whole segments, none included.
                        out += "(?:[^/]*/)*"
                        index = next + 1
                        continue
                    }
                    if atSegmentStart, next == characters.count, index > 0 {
                        // `dir/**`: the folder itself, or anything below it.
                        out.removeLast()  // the `/` just written
                        out += "(?:/.*)?"
                        index = next
                        continue
                    }
                    out += ".*"
                    index = next
                    continue
                }
                out += "[^/]*"
            case "?":
                out += "[^/]"
            case "[":
                // A class to its `]`; without one the `[` is literal.
                var end = index + 1
                if end < characters.count, characters[end] == "!" || characters[end] == "^" { end += 1 }
                if end < characters.count, characters[end] == "]" { end += 1 }
                while end < characters.count, characters[end] != "]" { end += 1 }
                guard end < characters.count else {
                    out += escaped(character)
                    break
                }
                var body = Array(characters[(index + 1)..<end])
                var negated = false
                if let first = body.first, first == "!" || first == "^" {
                    negated = true
                    body.removeFirst()
                }
                var set = ""
                for member in body {
                    // ICU's class syntax: escape all but the range dash.
                    set += member == "-" ? "-" : (member.isLetter || member.isNumber ? String(member) : "\\" + String(member))
                }
                out += negated ? "[^/\(set)]" : "[\(set)]"
                index = end
            case "{":
                depth += 1
                out += "(?:"
            case "}" where depth > 0:
                depth -= 1
                out += ")"
            case "," where depth > 0:
                out += "|"
            case "/":
                out += "/"
            default:
                out += escaped(character)
            }
            index += 1
        }
        guard depth == 0 else { return nil }
        return out + "$"
    }
}

/// `workspace/didChangeWatchedFiles` from the client's side: what servers
/// registered (`client/registerCapability`), which folders to watch for
/// them, and which file events to tell them about.
///
/// Pure: the file system is asked only through `exists` and `resolve`.
///
/// Declaring `dynamicRegistration` changes what servers do — checked
/// against each one's own registration, captured from the real server where
/// it is installed (LanguageServerTests' fixtures): gopls registers
/// `**/*.{mod,work}` and its module folders' `**/*.{go,mod,sum,work}` (and
/// without it watches nothing); rust-analyzer registers its roots'
/// `**/*.rs` and `Cargo.{toml,lock}` and stops its own watcher;
/// sourcekit-lsp registers `**/*` (and `**/*.swift` changes); clangd
/// registers nothing; terraform-ls (#953) needs it to hear of `init` and of
/// files an agent writes.
struct LSPWatchedFiles: Sendable, Equatable {
    /// LSP's `WatchKind`.
    struct Kinds: OptionSet, Sendable, Hashable {
        let rawValue: Int
        static let create = Kinds(rawValue: 1)
        static let change = Kinds(rawValue: 2)
        static let delete = Kinds(rawValue: 4)
        static let all: Kinds = [.create, .change, .delete]
    }

    /// LSP's `FileChangeType`.
    enum ChangeType: Int, Sendable {
        case created = 1, changed, deleted

        var kind: Kinds {
            switch self {
            case .created: .create
            case .changed: .change
            case .deleted: .delete
            }
        }
    }

    struct Watcher: Sendable, Hashable {
        var glob: LSPGlob
        var kinds: Kinds
        /// The folder (a base, or an absolute pattern's) as the server spelled
        /// it, when the real path `glob` holds differs (`/tmp` →
        /// `/private/tmp`, a symlink → its target): its events go back to the
        /// server in its own spelling.
        var spelled: String? = nil
    }

    struct Change: Sendable, Hashable {
        var path: String
        var type: ChangeType
    }

    static let method = "workspace/didChangeWatchedFiles"
    /// Folders watched at most besides the root, and never these: a server
    /// that names `/` or the home folder doesn't get the whole disk watched.
    static let maxExtraFolders = 16
    /// Changes per notification.
    static let batchLimit = 1000

    /// By registration id.
    private(set) var registrations: [String: [Watcher]] = [:]

    var isEmpty: Bool { registrations.values.allSatisfy(\.isEmpty) }
    var watchers: [Watcher] { registrations.keys.sorted().flatMap { registrations[$0] ?? [] } }

    /// `client/registerCapability`'s params: the watched-files ones kept,
    /// their bases and absolute prefixes made real paths by `resolve` (FSEvents
    /// reports `/private/var/…` for `/var/…`). Whether anything changed.
    @discardableResult
    mutating func register(_ params: Any?, resolve: (String) -> String = LSPWatchedFiles.realPath) -> Bool {
        let registrations = (params as? [String: Any])?["registrations"] as? [[String: Any]] ?? []
        var changed = false
        for registration in registrations where registration["method"] as? String == Self.method {
            guard let id = registration["id"] as? String else { continue }
            let options = registration["registerOptions"] as? [String: Any]
            let watchers = (options?["watchers"] as? [[String: Any]] ?? []).compactMap { Self.watcher($0, resolve: resolve) }
            self.registrations[id] = watchers
            changed = true
        }
        return changed
    }

    /// `client/unregisterCapability`'s params (the spec's key is spelled
    /// `unregisterations`; `unregistrations` is taken too).
    @discardableResult
    mutating func unregister(_ params: Any?) -> Bool {
        let object = params as? [String: Any]
        let list = (object?["unregisterations"] ?? object?["unregistrations"]) as? [[String: Any]] ?? []
        var changed = false
        for item in list where item["method"] as? String == Self.method {
            if let id = item["id"] as? String, registrations.removeValue(forKey: id) != nil { changed = true }
        }
        return changed
    }

    mutating func removeAll() { registrations = [:] }

    private static func watcher(_ json: [String: Any], resolve: (String) -> String) -> Watcher? {
        let kinds = (json["kind"] as? Int).map(Kinds.init(rawValue:)) ?? .all
        switch json["globPattern"] {
        case let pattern as String:
            // An absolute pattern's folder as FSEvents names it.
            if let folder = LSPGlob.literalFolder(of: pattern), folder != "/" {
                let real = resolve(folder)
                let rewritten = real + pattern.dropFirst(folder.count)
                return LSPGlob(rewritten).map { Watcher(glob: $0, kinds: kinds, spelled: real == folder ? nil : folder) }
            }
            return LSPGlob(pattern).map { Watcher(glob: $0, kinds: kinds) }
        case let relative as [String: Any]:
            // baseUri is a URI, or a WorkspaceFolder ({uri, name}).
            let baseURI = relative["baseUri"] as? String ?? (relative["baseUri"] as? [String: Any])?["uri"] as? String
            guard let baseURI, let pattern = relative["pattern"] as? String, let base = LSP.url(fromURI: baseURI), base.isFileURL
            else { return nil }
            let path = base.path.count > 1 && base.path.hasSuffix("/") ? String(base.path.dropLast()) : base.path
            let real = resolve(path)
            return LSPGlob(pattern, base: real).map { Watcher(glob: $0, kinds: kinds, spelled: real == path ? nil : path) }
        default:
            return nil
        }
    }

    /// What to watch: the root, and every base or absolute pattern's folder
    /// outside it — bounded, never `/`, the home folder or above it. The
    /// root is held to the same rule: a file opened from the home folder
    /// with no marker and no `.git` makes it the root, and pyright's `**`
    /// there would watch every file the user has. Such a root isn't
    /// watched; the registered folders that pass are, below it or not.
    func folders(root: String, home: String = NSHomeDirectory()) -> [String] {
        let rootWatched = Self.watchable(root, home: home)
        var extra: [String] = []
        for watcher in watchers {
            guard let folder = watcher.glob.base ?? LSPGlob.literalFolder(of: watcher.glob.pattern) else { continue }
            guard Self.watchable(folder, home: home) else { continue }
            if rootWatched {
                guard folder != root, LSPGlob.relative(folder, to: root) == nil, LSPGlob.relative(root, to: folder) == nil else {
                    // Below the root, it is watched already; above it, too much.
                    continue
                }
            } else if LSPGlob.relative(root, to: folder) != nil {
                // Above a root that is too wide already.
                continue
            }
            if !extra.contains(folder) { extra.append(folder) }
            if extra.count == Self.maxExtraFolders { break }
        }
        // One folder inside another is watched by the outer one.
        let outer = extra.filter { folder in !extra.contains { $0 != folder && LSPGlob.relative(folder, to: $0) != nil } }
        return (rootWatched ? [root] : []) + outer.sorted()
    }

    /// Whether a folder may be watched at all: not `/` or a folder right
    /// under it (`/Users`), not a whole volume (`/Volumes/x`), not the home
    /// folder, nor anything above it.
    static func watchable(_ folder: String, home: String) -> Bool {
        let components = (folder as NSString).pathComponents
        guard components.count > 2, folder != home, !home.hasPrefix(folder + "/") else { return false }
        return !(components.count == 3 && components[1] == "Volumes")
    }

    /// The path as the server knows it: under the root as it was given
    /// (`rootSpelling`, not `/private/var/…`), or under a registered folder
    /// as the server spelled it — the longest real folder the path is in.
    func serverPath(_ path: String, realRoot: String, rootSpelling: String) -> String {
        var folders = [(realRoot, rootSpelling)]
        for watcher in watchers {
            guard let spelled = watcher.spelled,
                let real = watcher.glob.base ?? LSPGlob.literalFolder(of: watcher.glob.pattern)
            else { continue }
            folders.append((real, spelled))
        }
        var best: (length: Int, mapped: String)?
        for (real, spelled) in folders where real != spelled && real.count > (best?.length ?? -1) {
            if path == real {
                best = (real.count, spelled)
            } else if let below = LSPGlob.relative(path, to: real) {
                best = (real.count, spelled + "/" + below)
            }
        }
        return best?.mapped ?? path
    }

    /// Never sent, as VS Code's default `files.watcherExclude`: git's object
    /// store and the insides of each package in node_modules.
    static func excluded(_ path: String) -> Bool {
        if path.contains("/.git/objects/") || path.contains("/.git/subtree-cache/") || path.contains("/.hg/store/") { return true }
        guard let range = path.range(of: "/node_modules/") else { return false }
        // node_modules/<package>/… — the package folder itself still counts.
        return path[range.upperBound...].contains("/")
    }

    /// The changes these events make for the registered watchers, in order,
    /// one per path (its last). Whether a file came or went is what `exists`
    /// says now, since FSEvents' flags are coalesced and sticky.
    func changes(for events: [DirectoryWatcher.Event], root: String, exists: (String) -> Bool) -> [Change] {
        let watchers = watchers
        guard !watchers.isEmpty else { return [] }
        var changes: [Change] = []
        var at: [String: Int] = [:]
        for event in events {
            var path = event.path
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            let flags = event.flags
            guard !flags.intersection([.created, .removed, .modified, .renamed]).isEmpty, !Self.excluded(path) else { continue }
            let type: ChangeType
            if exists(path) {
                type = flags.contains(.created) || flags.contains(.renamed) ? .created : .changed
            } else {
                type = .deleted
            }
            // A folder matches a pattern for folders (`**/`) too.
            let folder = flags.contains(.isDirectory) ? path + "/" : nil
            guard
                watchers.contains(where: { watcher in
                    watcher.kinds.contains(type.kind)
                        && (watcher.glob.matches(path, root: root) || folder.map { watcher.glob.matches($0, root: root) } == true)
                })
            else { continue }
            let change = Change(path: path, type: type)
            if let index = at[path] {
                changes[index] = change
            } else {
                at[path] = changes.count
                changes.append(change)
            }
        }
        return changes
    }

    /// The path FSEvents reports for `path`: symlinks resolved, /var as
    /// /private/var. The path itself when it doesn't exist.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
