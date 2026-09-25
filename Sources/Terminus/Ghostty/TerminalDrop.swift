import AppKit
import UniformTypeIdentifiers

/// Dropping onto a terminal pane: what a drag carries, what a drop types
/// in, and what runs in the pane — the references depend on it.
///
/// A drop never runs anything: it is a paste (TerminalView.insertText),
/// the references separated by spaces, with a trailing space.
enum TerminalDrop {
    /// One dragged thing.
    enum Item: Equatable {
        /// A file or folder, by its absolute URL.
        case file(URL, isDirectory: Bool)
        /// A web URL or a plain string.
        case text(String)
    }

    /// What runs in a pane, as far as a drop cares.
    enum Program: Equatable {
        /// A shell, an editor, Codex: anything but Claude Code.
        case other
        /// Claude Code has the pane's keyboard, working in `directory`.
        case claude(directory: String?)
    }

    /// What a drag carries: files (Finder, the sidebar); else files still to
    /// be written — promises: Photos, Safari, the screenshot thumbnail; else
    /// web URLs, else text.
    enum Payload {
        case items([Item])
        case promises([NSFilePromiseReceiver])
    }

    /// The pasteboard types a pane takes.
    static let draggedTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .URL, .string] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    /// What Claude Code takes for an image in a paste (its own test is
    /// `/\.(png|jpe?g|gif|webp)$/i`).
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    // MARK: What a drop types in

    /// The text a drop inserts into a pane where `program` runs.
    /// - `plainPaths` (⌥ held), or anything but Claude Code: each file's
    ///   absolute path, shell-quoted, as Terminal does.
    /// - Claude Code: an image as its absolute path, the form Claude Code
    ///   turns into `[Image #N]`; another file or a folder as an @-mention,
    ///   relative to where Claude works when inside it — Claude Code
    ///   attaches it on submit.
    /// Text goes in as it is, without line breaks at either end: a drop
    /// never presses Return.
    static func insertion(_ items: [Item], for program: Program, plainPaths: Bool = false) -> String {
        var words: [String] = []
        var images: [String] = []
        for item in items {
            switch item {
            case .text(let text):
                let text = text.trimmingCharacters(in: .newlines)
                if !text.isEmpty { words.append(text) }
            case .file(let url, let isDirectory):
                let path = url.standardizedFileURL.path
                guard case .claude(let directory) = program, !plainPaths else {
                    words.append(TerminalWindowController.shellQuoted(path))
                    continue
                }
                if !isDirectory, isImage(path), let image = claudeImagePath(path) {
                    images.append(image)
                } else {
                    let relative = relativePath(url.standardizedFileURL, to: directory)
                    let written = isDirectory && !relative.hasSuffix("/") ? relative + "/" : relative
                    words.append(claudeMention(written) ?? TerminalWindowController.shellQuoted(path))
                }
            }
        }
        guard !words.isEmpty || !images.isEmpty else { return "" }
        // Claude Code takes each image path out of a paste (from a " /" to the
        // next) and puts its [Image #N] before what is left: images go last,
        // and what is left then starts with a space — an @-mention right after
        // "]" is no @-mention.
        let lead = !words.isEmpty && !images.isEmpty ? " " : ""
        return lead + (words + images).joined(separator: " ") + " "
    }

    /// What the highlight over a pane says a drop there does.
    static func label(_ items: [Item], for program: Program, plainPaths: Bool = false) -> String {
        let files = items.compactMap { item -> (path: String, isDirectory: Bool)? in
            if case .file(let url, let isDirectory) = item { return (url.path, isDirectory) }
            return nil
        }
        guard !files.isEmpty else { return "Drop to insert text" }
        var mentions = false
        if case .claude = program, !plainPaths { mentions = files.contains { $0.isDirectory || !isImage($0.path) } }
        let noun = mentions ? "@ reference" : "path"
        return files.count == 1 ? "Drop to insert \(noun)" : "Drop to insert \(files.count) \(noun)s"
    }

    static func isImage(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// An image path as Claude Code reads a paste: absolute, whitespace and
    /// backslashes escaped with a backslash, as a terminal writes a dropped
    /// path (it splits a paste before each " /", unescapes each part, and
    /// reads a part ending in an image extension as an image). nil for a
    /// path that splitting would cut: a line break, or " /" in it.
    static func claudeImagePath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains(where: \.isNewline), !path.contains(" /") else { return nil }
        var escaped = ""
        for character in path {
            if character == "\\" || character.isWhitespace { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// An @-mention as Claude Code reads one on submit: `@path`, or
    /// `@"path"` where the plain form would come through cut — it takes
    /// `@\S+` up to the last word character, so whitespace, or an ending
    /// such as `.` or `é`, needs the quotes (its own completion quotes a
    /// path with a space). nil when neither form carries the path: a `#`
    /// starts a line range, a quote can't be escaped, and whitespace at
    /// either end is trimmed.
    static func claudeMention(_ path: String) -> String? {
        func isSpace(_ character: Character) -> Bool { character.isWhitespace || character == "\u{FEFF}" }
        guard let first = path.first, let last = path.last, !isSpace(first), !isSpace(last), !path.contains("#") else { return nil }
        let core = path.count > 1 && last == "/" ? path.dropLast() : Substring(path)
        let endsInWord = core.last.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } ?? false
        if endsInWord, first != "\"", !path.contains(where: isSpace) { return "@" + path }
        guard !path.contains("\"") else { return nil }
        return "@\"" + path + "\""
    }

    /// `url` relative to `directory` when inside it, else absolute — also
    /// when the two spell the same place differently (/var is /private/var).
    static func relativePath(_ url: URL, to directory: String?) -> String {
        let direct = TerminalWindowController.relativePath(url, cwd: directory)
        guard direct.hasPrefix("/"), let directory else { return direct }
        let resolved = TerminalWindowController.relativePath(
            url.resolvingSymlinksInPath(), cwd: URL(fileURLWithPath: directory).resolvingSymlinksInPath().path)
        return resolved.hasPrefix("/") ? direct : resolved
    }

    // MARK: What a drag carries

    /// Reads a drag's pasteboard.
    @MainActor static func payload(from pasteboard: NSPasteboard) -> Payload? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return .items(
                urls.map { url in
                    // Finder may hand over file reference URLs (/.file/id=…).
                    let path = ((url as NSURL).filePathURL ?? url).standardizedFileURL
                    return .file(path, isDirectory: (try? path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
                })
        }
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
            !promises.isEmpty
        {
            return .promises(promises)
        }
        if pasteboard.availableType(from: [.URL]) != nil, let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
            !urls.isEmpty
        {
            return .items(urls.map { .text($0.absoluteString) })
        }
        if let strings = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [String], !strings.isEmpty {
            return .items(strings.map { .text($0) })
        }
        return nil
    }

    /// Stand-ins for the label while promised files have no names yet, only
    /// types.
    @MainActor static func labelItems(_ payload: Payload) -> [Item] {
        switch payload {
        case .items(let items):
            return items
        case .promises(let promises):
            return promises.flatMap { promise in
                (promise.fileTypes.isEmpty ? [""] : promise.fileTypes).map { type in
                    .file(URL(fileURLWithPath: "/promised." + (UTType(type)?.preferredFilenameExtension ?? "")), isDirectory: false)
                }
            }
        }
    }

    // MARK: Promised files

    /// A new folder under AppEnvironment.dropsDirectory for one drop's
    /// promised files, so names never collide.
    static func newDropFolder() throws -> URL {
        let folder = AppEnvironment.dropsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Stands in for the promises' sources: an E2E run can't start a real
    /// drag, and a promise is kept only at the end of one. Gets the promise
    /// and the folder, and calls back with each file written there.
    @MainActor static var keepPromise: ((NSFilePromiseReceiver, URL, @escaping @Sendable (URL) -> Void) -> Void)?

    /// Has every promise's files written into `folder`, then hands them to
    /// `done` on the main thread, in the order promised. A file that fails,
    /// or is still missing after `timeout`, is left out.
    @MainActor static func receive(
        _ promises: [NSFilePromiseReceiver], into folder: URL, timeout: TimeInterval = 30, done: @escaping @MainActor ([URL]) -> Void
    ) {
        let collector = PromisedFiles(expected: promises.reduce(0) { $0 + max($1.fileTypes.count, 1) }, done: done)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        for (index, promise) in promises.enumerated() {
            if let keepPromise {
                keepPromise(promise, folder) { collector.arrived(index, $0) }
            } else {
                promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { url, error in
                    collector.arrived(index, error == nil ? url : nil)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { collector.finish() }
    }

    // MARK: What runs in the pane

    /// What has the keyboard of the pane whose `login` this is. Blocking
    /// (a scan of the pane's processes): call off the main thread.
    nonisolated static func program(login: pid_t?) -> Program {
        guard let login else { return .other }
        let nodes = ProcessInspector().tree(root: login, tag: nil).flatMap(\.flattened)
        return program(among: nodes, foreground: ProcessInspector.foregroundGroup(of: login), groupOf: ProcessInspector.processGroup(of:))
    }

    /// Claude Code has the pane when a Claude process (by name or argv[0],
    /// as the agent overview finds one) is in its terminal's foreground
    /// process group — not one left running in the background. Without a
    /// foreground group to go by, any Claude process counts.
    nonisolated static func program(among nodes: [ProcessNode], foreground: pid_t?, groupOf: (pid_t) -> pid_t?) -> Program {
        let claudes = nodes.filter { AgentOverviewModel.agent(of: $0) == .claude }
        let claude = foreground.map { group in claudes.first { groupOf($0.pid) == group } } ?? claudes.first
        return claude.map { .claude(directory: $0.workingDirectory) } ?? .other
    }
}

/// Collects promised files as their sources write them, on any thread, and
/// hands them over once: when all have come, or at the timeout.
private final class PromisedFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var files: [(index: Int, order: Int, url: URL)] = []
    private var finished = false
    private let done: @MainActor ([URL]) -> Void

    init(expected: Int, done: @escaping @MainActor ([URL]) -> Void) {
        remaining = expected
        self.done = done
    }

    func arrived(_ index: Int, _ url: URL?) {
        lock.lock()
        if let url { files.append((index, files.count, url)) }
        remaining -= 1
        let complete = remaining <= 0
        lock.unlock()
        if complete { finish() }
    }

    func finish() {
        lock.lock()
        guard !finished else { return lock.unlock() }
        finished = true
        let urls = files.sorted { ($0.index, $0.order) < ($1.index, $1.order) }.map(\.url)
        lock.unlock()
        let done = self.done
        DispatchQueue.main.async { MainActor.assumeIsolated { done(urls) } }
    }
}
