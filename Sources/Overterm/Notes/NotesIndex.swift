import Foundation

/// Which file a link means, as Obsidian decides: a path from the note's
/// folder or from the vault's root, else a name — `[[Plan]]` is whichever
/// `Plan.md` is closest: in the note's own folder, else the shortest path.
/// Case doesn't matter; a link without an extension means a note.
struct LinkResolver: Sendable {
    /// Every file, vault-relative, `.md` kept.
    let files: [String]
    private let byPath: [String: String]
    private let byName: [String: [String]]

    init(files: [String]) {
        self.files = files
        var byPath: [String: String] = [:]
        var byName: [String: [String]] = [:]
        for file in files {
            byPath[file.lowercased()] = file
            byName[Self.name(of: file).lowercased(), default: []].append(file)
        }
        self.byPath = byPath
        self.byName = byName
    }

    /// `Folder/Plan.md` → `Plan.md`.
    static func name(of path: String) -> String { (path as NSString).lastPathComponent }

    static func folder(of path: String) -> String { (path as NSString).deletingLastPathComponent }

    /// The file `target` names from the note at `source`; nil when none does
    /// (a link to a note not written yet). An empty target is the note itself.
    func resolve(_ target: String, from source: String) -> String? {
        var target = target.trimmingCharacters(in: .whitespaces)
        if target.isEmpty { return source }
        if target.hasPrefix("/") { target.removeFirst() }
        let spellings = [target, target + ".md"]
        // A path: from the note's folder, then from the root.
        let folder = Self.folder(of: source)
        if !folder.isEmpty {
            for spelling in spellings {
                let joined = Self.standardized(folder + "/" + spelling)
                if let joined, let file = byPath[joined.lowercased()] { return file }
            }
        }
        for spelling in spellings {
            if let file = byPath[spelling.lowercased()] { return file }
        }
        // A name, or the end of a path: the closest file that answers.
        for spelling in spellings {
            let lowered = spelling.lowercased()
            let candidates = (byName[Self.name(of: lowered)] ?? []).filter { file in
                let path = file.lowercased()
                return path == lowered || path.hasSuffix("/" + lowered)
            }
            if let best = Self.closest(candidates, to: folder) { return best }
        }
        return nil
    }

    /// How a new link names `path` from `source`: Obsidian's "shortest"
    /// (the name, when no other file has it), "relative" or "absolute".
    /// A note without `.md`, anything else whole.
    func linkText(for path: String, from source: String, format: String = "shortest") -> String {
        let shown = path.lowercased().hasSuffix(".md") ? String(path.dropLast(3)) : path
        switch format {
        case "absolute":
            return shown
        case "relative":
            return Self.relative(shown, from: Self.folder(of: source))
        default:
            let name = Self.name(of: path)
            let unique = (byName[name.lowercased()]?.count ?? 0) <= 1
            return unique ? Self.name(of: shown) : shown
        }
    }

    private static func closest(_ candidates: [String], to folder: String) -> String? {
        candidates.min { a, b in
            let aHere = Self.folder(of: a) == folder
            let bHere = Self.folder(of: b) == folder
            if aHere != bHere { return aHere }
            let aDepth = a.split(separator: "/").count
            let bDepth = b.split(separator: "/").count
            if aDepth != bDepth { return aDepth < bDepth }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    /// `a/b/../c` → `a/c`; nil when it climbs out of the vault.
    static func standardized(_ path: String) -> String? {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }

    static func relative(_ path: String, from folder: String) -> String {
        let to = path.split(separator: "/")
        let from = folder.split(separator: "/")
        var common = 0
        while common < min(to.count - 1, from.count), to[common] == from[common] { common += 1 }
        let up = Array(repeating: "..", count: from.count - common)
        return (up + to[common...].map(String.init)).joined(separator: "/")
    }
}

/// What the vault holds, read once and kept: every note's links, tags,
/// headings and tasks — so backlinks, the tag list and the task list are
/// lookups, not reads. A value: built off the main thread, handed over
/// whole; a rebuild reads only the notes whose date changed.
struct NotesIndex: Sendable {
    struct Entry: Sendable {
        var document: NoteDocument
        var modified: Date
        var isEvicted = false
    }

    /// A link into a note, from another.
    struct Backlink: Equatable, Hashable, Sendable {
        var source: String
        var link: NoteDocument.Link
    }

    struct TaskItem: Equatable, Hashable, Sendable {
        var path: String
        var task: NoteDocument.Task
    }

    /// Notes by vault-relative path (`.md` kept).
    private(set) var notes: [String: Entry] = [:]
    private(set) var resolver = LinkResolver(files: [])
    /// Into each path, from every note linking it.
    private(set) var incoming: [String: [Backlink]] = [:]
    /// Links to notes not written yet, by what they name.
    private(set) var unresolved: [String: [Backlink]] = [:]

    init() {}

    init(notes: [String: Entry], files: [String]) {
        self.notes = notes
        relink(files: files)
    }

    /// The notes' paths in Finder's order, sorted once a change (it was a
    /// sort a keystroke, and a hover in the graph).
    private(set) var paths: [String] = []

    func document(_ path: String) -> NoteDocument? { notes[path]?.document }

    func resolve(_ link: NoteDocument.Link, from source: String) -> String? { resolver.resolve(link.target, from: source) }

    func backlinks(of path: String) -> [Backlink] { incoming[path, default: []].filter { $0.source != path } }

    /// Every tag with how many notes carry it — a nested tag's notes count
    /// for its parents too, as Obsidian's tag pane counts them.
    var tags: [String: Int] {
        var counts: [String: Int] = [:]
        for entry in notes.values {
            var seen = Set<String>()
            for tag in entry.document.allTags {
                let parts = tag.split(separator: "/")
                for end in 1...max(1, parts.count) {
                    let name = parts.prefix(end).joined(separator: "/")
                    if seen.insert(name.lowercased()).inserted { counts[name, default: 0] += 1 }
                }
            }
        }
        return counts
    }

    /// Notes carrying `tag` or one nested under it.
    func notes(tagged tag: String) -> [String] {
        let lowered = tag.lowercased()
        return paths.filter { path in
            notes[path]!.document.allTags.contains { $0.lowercased() == lowered || $0.lowercased().hasPrefix(lowered + "/") }
        }
    }

    var tasks: [TaskItem] {
        paths.flatMap { path in notes[path]!.document.tasks.map { TaskItem(path: path, task: $0) } }
    }

    /// Notes whose name, path or alias holds `query`, best first: the name
    /// starting with it, then holding it, then the rest.
    func notes(matching query: String, limit: Int = 50) -> [String] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Array(paths.prefix(limit)) }
        func rank(_ path: String) -> Int? {
            let name = (LinkResolver.name(of: path) as NSString).deletingPathExtension
            if name.range(of: query, options: [.caseInsensitive, .anchored, .diacriticInsensitive]) != nil { return 0 }
            if name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return 1 }
            if notes[path]?.document.aliases.contains(where: { $0.localizedCaseInsensitiveContains(query) }) == true { return 2 }
            if path.localizedCaseInsensitiveContains(query) { return 3 }
            return nil
        }
        return paths.compactMap { path in rank(path).map { (path, $0) } }
            .sorted { $0.1 < $1.1 }
            .prefix(limit).map(\.0)
    }

    // MARK: Changing

    mutating func set(_ path: String, text: String, modified: Date) {
        notes[path] = Entry(document: NoteParser.parse(text), modified: modified)
        var files = resolver.files
        if !files.contains(path) { files.append(path) }
        relink(files: files)
    }

    mutating func remove(_ path: String) {
        notes[path] = nil
        relink(files: resolver.files.filter { $0 != path })
    }

    private mutating func relink(files: [String]) {
        paths = notes.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        resolver = LinkResolver(files: files)
        incoming = [:]
        unresolved = [:]
        for (source, entry) in notes {
            for link in entry.document.links {
                if let target = resolver.resolve(link.target, from: source) {
                    incoming[target, default: []].append(Backlink(source: source, link: link))
                } else {
                    unresolved[link.target, default: []].append(Backlink(source: source, link: link))
                }
            }
        }
        for key in incoming.keys { incoming[key]!.sort { ($0.source, $0.link.range.location) < ($1.source, $1.link.range.location) } }
    }

    // MARK: Building

    /// Reads the vault: the notes whose modification date `previous` already
    /// has are kept, the others read and parsed. Runs off the main thread.
    nonisolated static func build(_ vault: NotesVault, tree: NoteItem? = nil, previous: NotesIndex = NotesIndex()) -> NotesIndex {
        let tree = tree ?? NoteFiles.tree(of: vault)
        var notes: [String: Entry] = [:]
        var files: [String] = []
        for item in tree.allFiles {
            let path = vault.relativePath(of: item.url)
            files.append(path)
            guard item.kind == .note else { continue }
            if item.isEvicted {
                // Not on this Mac yet: known by name, read when opened.
                notes[path] = previous.notes[path] ?? Entry(document: NoteDocument(), modified: .distantPast, isEvicted: true)
                continue
            }
            if let kept = previous.notes[path], kept.modified == item.modified, !kept.isEvicted {
                notes[path] = kept
                continue
            }
            guard let text = try? String(contentsOf: item.url, encoding: .utf8) else { continue }
            notes[path] = Entry(document: NoteParser.parse(text), modified: item.modified)
        }
        return NotesIndex(notes: notes, files: files)
    }
}
