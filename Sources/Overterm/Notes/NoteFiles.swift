import Foundation

/// A vault's files on disk — listed, read and written as iCloud and Obsidian
/// expect: through NSFileCoordinator, so a write never lands in the middle
/// of a sync or of Obsidian's own; and a file iCloud hasn't downloaded (a
/// `.name.md.icloud` placeholder) listed under its real name and fetched
/// when it is opened.
enum NoteFiles {
    enum Problem: LocalizedError {
        case notDownloaded(String)
        var errorDescription: String? {
            switch self {
            case .notDownloaded(let name): "“\(name)” is still downloading from iCloud."
            }
        }
    }

    // MARK: Placeholders

    /// `.Note.md.icloud` → `Note.md`; nil for anything else.
    static func realName(ofPlaceholder name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8 else { return nil }
        return String(name.dropFirst().dropLast(7))
    }

    static func placeholder(of url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
    }

    /// Whether `url` is only a placeholder on this Mac.
    static func isEvicted(_ url: URL) -> Bool {
        !FileManager.default.fileExists(atPath: url.path) && FileManager.default.fileExists(atPath: placeholder(of: url).path)
    }

    /// Asks iCloud for the file and waits for it, a few seconds at most.
    static func download(_ url: URL, timeout: TimeInterval = 15) throws {
        guard isEvicted(url) else { return }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while isEvicted(url) && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if isEvicted(url) { throw Problem.notDownloaded(url.deletingPathExtension().lastPathComponent) }
    }

    // MARK: Reading and writing, coordinated

    static func read(_ url: URL) throws -> String {
        try download(url)
        var result: Result<String, Error> = .failure(CocoaError(.fileReadUnknown))
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result { try String(contentsOf: url, encoding: .utf8) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var result: Result<Void, Error> = .success(())
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result { try text.write(to: url, atomically: true, encoding: .utf8) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    /// An empty note at `url` — never over one that is there, here or in iCloud.
    static func create(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) || isEvicted(url) { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var result: Result<Void, Error> = .success(())
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result { try Data().write(to: url, options: .withoutOverwriting) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    /// Asks iCloud for a file only a placeholder is here for, and calls back
    /// on the main thread once it has come (or, after `timeout`, hasn't) —
    /// without holding the main thread meanwhile.
    @MainActor static func whenDownloaded(_ url: URL, timeout: TimeInterval = 30, _ done: @escaping @MainActor (Bool) -> Void) {
        guard isEvicted(url) else { return done(true) }
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            return done(false)
        }
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if !isEvicted(url) { return done(true) }
            guard Date() < deadline else { return done(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { poll() } }
        }
        poll()
    }

    static func move(_ from: URL, to: URL) throws {
        var result: Result<Void, Error> = .success(())
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: from, options: .forMoving, writingItemAt: to, options: .forReplacing, error: &coordinationError
        ) { from, to in
            result = Result { try FileManager.default.moveItem(at: from, to: to) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    // MARK: The tree

    /// The vault's folders and files, Obsidian's way: folders first, then
    /// files, each by name as Finder sorts them (numbers by value); hidden
    /// and excluded ones left out; placeholders under their real names.
    static func tree(of vault: NotesVault) -> NoteItem {
        func walk(_ folder: URL, depth: Int) -> [NoteItem] {
            guard depth < 32,
                let children = try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [])
            else { return [] }
            var folders: [NoteItem] = []
            var files: [NoteItem] = []
            for child in children {
                var url = child
                var evicted = false
                if let real = realName(ofPlaceholder: child.lastPathComponent) {
                    url = child.deletingLastPathComponent().appendingPathComponent(real)
                    evicted = true
                }
                guard !vault.isHidden(url) else { continue }
                if !evicted, (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    folders.append(NoteItem(url: url, kind: .folder, children: walk(url, depth: depth + 1)))
                } else {
                    let modified = (try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    files.append(NoteItem(url: url, kind: NoteItem.Kind(url), modified: modified, isEvicted: evicted))
                }
            }
            func byName(_ a: NoteItem, _ b: NoteItem) -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return folders.sorted(by: byName) + files.sorted(by: byName)
        }
        return NoteItem(url: vault.root, kind: .folder, children: walk(vault.root, depth: 0))
    }
}

/// A folder or a file of the vault.
struct NoteItem: Identifiable, Equatable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case folder, note, canvas, image, pdf, other

        init(_ url: URL) {
            switch url.pathExtension.lowercased() {
            case "md": self = .note
            case "canvas", "excalidraw": self = .canvas
            case "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "heic", "avif": self = .image
            case "pdf": self = .pdf
            default: self = url.lastPathComponent.hasSuffix(".excalidraw.md") ? .canvas : .other
            }
        }
    }

    let url: URL
    let kind: Kind
    var children: [NoteItem]?
    var modified: Date = .distantPast
    /// Only a placeholder on this Mac: iCloud fetches it when opened.
    var isEvicted = false

    var id: String { url.path }
    var isFolder: Bool { kind == .folder }
    /// As Obsidian shows it: a note without `.md`, anything else whole.
    var name: String { kind == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent }

    var allNotes: [NoteItem] {
        guard let children else { return kind == .note ? [self] : [] }
        return children.flatMap(\.allNotes)
    }

    var allFiles: [NoteItem] {
        guard let children else { return [self] }
        return children.flatMap(\.allFiles)
    }

    /// Notes and folders whose name holds `query`, the folders around them kept.
    func filtered(_ query: String) -> NoteItem? {
        guard !query.isEmpty else { return self }
        guard let children else { return name.localizedCaseInsensitiveContains(query) ? self : nil }
        let kept = children.compactMap { $0.filtered(query) }
        if kept.isEmpty && !name.localizedCaseInsensitiveContains(query) { return nil }
        var copy = self
        copy.children = kept.isEmpty ? children : kept
        return copy
    }
}
