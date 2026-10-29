import AppKit
import Foundation
import UniformTypeIdentifiers

// Files and folders copied into and out of a container or a volume: the
// archive made as it is sent (`DockerTar.Plan`, `DockerTarWriter`), the
// archive written to the Mac as it comes (`DockerTarExtractor`), the
// app's copies (`DockerFileTransfers`), and a dragged row's file promise
// (`DockerFilePromise`).

extension DockerTar.Plan {
    /// What dropping `urls` sends. Each is an item of its own, named as on
    /// the Mac; a folder goes with everything in it, walked by the system
    /// (paths relative to it, each folder before what it holds, a link
    /// never followed). Hidden files go too; `.DS_Store` stays on the Mac,
    /// and so do sockets, pipes, devices, and links that point above the
    /// drop (the engine refuses the whole archive for one). Reads the
    /// disk: called off the main thread.
    static func make(_ urls: [URL]) throws -> DockerTar.Plan {
        let files = FileManager.default
        var plan = DockerTar.Plan()
        for url in urls {
            let top = url.lastPathComponent
            guard top != ".DS_Store" else { continue }
            guard !plan.tops.contains(top) else {
                throw DockerError(status: 0, message: "Two of the items dropped are named “\(top)”: copy them one at a time.")
            }
            let attributes = try files.attributesOfItem(atPath: url.path)
            let before = plan.items.count
            let isFolder = try add(top, at: url, attributes, to: &plan)
            if plan.items.count > before { plan.tops.append(top) }
            guard isFolder, let walk = files.enumerator(atPath: url.path) else { continue }
            while let relative = walk.nextObject() as? String {
                let name = top + "/" + relative
                if (relative as NSString).lastPathComponent == ".DS_Store" {
                    walk.skipDescendants()
                    continue
                }
                _ = try add(name, at: url.appendingPathComponent(relative), walk.fileAttributes ?? [:], to: &plan)
            }
        }
        return plan
    }

    /// One item, from its own attributes (lstat's): true for a folder,
    /// which the walk goes into.
    private static func add(_ name: String, at url: URL, _ attributes: [FileAttributeKey: Any], to plan: inout DockerTar.Plan) throws -> Bool {
        let files = FileManager.default
        let mode = ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644) & 0o7777
        let modified = attributes[.modificationDate] as? Date ?? Date()
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory?:
            guard files.isReadableFile(atPath: url.path), files.isExecutableFile(atPath: url.path) else { throw unreadable(name) }
            plan.items.append(Item(name: name + "/", kind: .directory, mode: mode, modified: modified))
            return true
        case .typeRegular?:
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard files.isReadableFile(atPath: url.path) else { throw unreadable(name) }
            guard size <= DockerTar.maximumSize else {
                throw DockerError(status: 0, message: "“\(name)” is over 8 GB, more than a plain tar holds: copy it with docker cp in a tab.")
            }
            plan.items.append(Item(name: name, kind: .file(url), size: size, mode: mode, modified: modified))
        case .typeSymbolicLink?:
            let target = try files.destinationOfSymbolicLink(atPath: url.path)
            if DockerTar.escapes(target, from: name) {
                plan.skipped.append(name)
            } else {
                plan.items.append(Item(name: name, kind: .symlink(target), modified: modified))
            }
        default:
            plan.skipped.append(name)
        }
        return false
    }

    private static func unreadable(_ name: String) -> DockerError { DockerError(status: 0, message: "“\(name)” can't be read.") }

    /// Without the own entries of the dropped folders that `folders` has
    /// already: what they hold goes into the folder there, which keeps its
    /// owner and mode. The engine applies a folder entry's owner (root's)
    /// and mode to a folder it merges into — node's `/home/node/app` would
    /// be root's after a drop of `app`, and npm couldn't write in it. A
    /// folder under one is made by the engine as it unpacks. Pure.
    func merging(into folders: Set<String>) -> DockerTar.Plan {
        var plan = self
        plan.items.removeAll { item in
            guard item.kind == .directory, item.name.hasSuffix("/") else { return false }
            let name = String(item.name.dropLast())
            return !name.contains("/") && folders.contains(name)
        }
        return plan
    }
}

/// A plan's archive a piece at a time, as the request sends it: each
/// item's headers, a file's bytes read as they go, its padding, then the
/// end blocks — exactly `plan.length` bytes. One request pulls it, a piece
/// after another, so it needs no lock.
final class DockerTarWriter: @unchecked Sendable {
    /// At most this much a piece.
    static let piece = 1 << 20

    private let plan: DockerTar.Plan
    private var index = 0
    private var file: (handle: FileHandle, name: String, left: Int, padding: Int)?
    private var ended = false

    init(_ plan: DockerTar.Plan) {
        self.plan = plan
    }

    deinit { try? file?.handle.close() }

    /// The next piece; nil after the end. A file whose size isn't the
    /// one planned throws: the request's length was said already.
    func next() throws -> Data? {
        var out = Data()
        while out.count < Self.piece {
            if var open = file {
                let want = min(open.left, Self.piece - out.count)
                let data = try open.handle.read(upToCount: want) ?? Data()
                guard data.count == want else { throw changed(open.name) }
                out += data
                open.left -= want
                guard open.left == 0 else {
                    file = open
                    continue
                }
                // Grown since it was looked at.
                if let more = try open.handle.read(upToCount: 1), !more.isEmpty { throw changed(open.name) }
                try? open.handle.close()
                file = nil
                out += Data(count: open.padding)
                continue
            }
            if index < plan.items.count {
                let item = plan.items[index]
                index += 1
                guard let headers = DockerTar.headers(for: item) else { throw DockerError(status: 0, message: "“\(item.name)” can't go in a tar.") }
                out += headers
                if case .file(let url) = item.kind, item.size > 0 {
                    let handle = try FileHandle(forReadingFrom: url)
                    let size = try handle.seekToEnd()
                    try handle.seek(toOffset: 0)
                    file = (handle, item.name, item.size, DockerTar.padding(item.size))
                    guard size == UInt64(item.size) else { throw changed(item.name) }
                }
                continue
            }
            if !ended {
                out += Data(count: 2 * DockerTar.block)
                ended = true
            }
            break
        }
        return out.isEmpty ? nil : out
    }

    private func changed(_ name: String) -> DockerError {
        try? file?.handle.close()
        file = nil
        return DockerError(status: 0, message: "“\(name)” changed while it was copied: copy it again.")
    }
}

/// An archive the engine's GET gives, written to the Mac as it comes —
/// `apply` each `DockerTar.Reader` event. A file's goes to `destination`;
/// a folder's tree goes inside it, the archive's top being the destination,
/// whatever Finder named it. Nothing lands outside it: `..`, absolute names
/// and whatever is under a link it wrote are left out, a folder entry of a
/// link's name replaces the link, and what is there is always looked at
/// without following a link. Modes and times are kept, owners never; a
/// folder's mode is set last, deepest first, so one that can't be written
/// still gets what is in it.
final class DockerTarExtractor {
    struct Summary: Equatable, Sendable {
        var files = 0
        var bytes = 0
        /// Left out, by their names in the archive.
        var skipped: [String] = []
    }

    let destination: URL
    let folder: Bool
    private var summary = Summary()
    private var ready = false
    /// The destination wasn't there: made here, and removed by `discard`.
    private var made = false
    private var writing: (handle: FileHandle, url: URL, header: DockerTar.Reader.Header)?
    private var folders: [(url: URL, depth: Int, mode: Int, modified: Date)] = []
    private var links: Set<String> = []
    private var written: [String: URL] = [:]
    private var wroteFile = false

    init(destination: URL, folder: Bool) {
        self.destination = destination
        self.folder = folder
    }

    /// Where an entry goes, as path components under the destination;
    /// nil, left out. A folder's archive starts with the folder's own
    /// name, dropped: `nginx/conf.d/a` → `conf.d/a`, `nginx` → the
    /// destination itself. Pure.
    static func place(_ name: String, folder: Bool) -> [String]? {
        guard !name.hasPrefix("/") else { return nil }
        let parts = name.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !parts.contains("..") else { return nil }
        return folder ? Array(parts.dropFirst()) : parts
    }

    func apply(_ event: DockerTar.Reader.Event) throws {
        switch event {
        case .entry(let header): try begin(header)
        case .data(let data): try writing?.handle.write(contentsOf: data)
        case .end: try end()
        }
    }

    /// The last entry closed and the folders' modes and times set: what
    /// was written.
    func finish() throws -> Summary {
        try end()
        if folder {
            if !ready { try prepare() }
            for folder in folders.sorted(by: { $0.depth > $1.depth }) {
                // Still a folder, looked at without following a link: one a
                // later entry made a link would set its target's mode.
                guard Self.isFolder(folder.url) else { continue }
                try FileManager.default.setAttributes(
                    [.posixPermissions: folder.mode & 0o777, .modificationDate: folder.modified], ofItemAtPath: folder.url.path)
            }
        } else if !wroteFile {
            throw DockerError(status: 0, message: "Docker's archive held no file.")
        }
        return summary
    }

    /// Gone again, if it wasn't there before: a copy that failed leaves
    /// nothing half written.
    func discard() {
        try? writing?.handle.close()
        writing = nil
        if made { try? FileManager.default.removeItem(at: destination) }
    }

    private func begin(_ header: DockerTar.Reader.Header) throws {
        let files = FileManager.default
        guard folder else {
            // A file's archive: its one file, whatever it is named in it.
            guard header.kind == .file, !wroteFile else {
                if header.kind != .directory { summary.skipped.append(header.name) }
                return
            }
            wroteFile = true
            made = !files.fileExists(atPath: destination.path)
            try open(destination, header)
            return
        }
        guard let parts = Self.place(header.name, folder: true) else {
            summary.skipped.append(header.name)
            return
        }
        if !ready { try prepare() }
        guard !parts.isEmpty else {
            if header.kind == .directory { folders.append((destination, 0, header.mode, header.modified)) }
            return
        }
        // Under a link written here: through it, it would land elsewhere.
        if (1..<parts.count).contains(where: { links.contains(parts[..<$0].joined(separator: "/")) }) {
            summary.skipped.append(header.name)
            return
        }
        let key = parts.joined(separator: "/")
        let url = parts.reduce(destination) { $0.appendingPathComponent($1) }
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch header.kind {
        case .directory:
            // A link of that name, written earlier, is replaced by the
            // folder, as the engine does: looked at without following it,
            // or the folder's mode would go to the link's target.
            if !Self.isFolder(url) { try removeIfThere(url) }
            links.remove(key)
            written[key] = nil
            try files.createDirectory(at: url, withIntermediateDirectories: true)
            folders.append((url, parts.count, header.mode, header.modified))
        case .file:
            try removeIfThere(url)
            try open(url, header)
            links.remove(key)
            written[key] = url
        case .symlink:
            try removeIfThere(url)
            try files.createSymbolicLink(atPath: url.path, withDestinationPath: header.linkTarget)
            links.insert(key)
            written[key] = nil
        case .hardlink:
            // A copy of the file it names, when that was written here.
            guard let target = Self.place(header.linkTarget, folder: true)?.joined(separator: "/"), let original = written[target] else {
                summary.skipped.append(header.name)
                return
            }
            try removeIfThere(url)
            try files.copyItem(at: original, to: url)
            links.remove(key)
            written[key] = url
            summary.files += 1
        case .other:
            summary.skipped.append(header.name)
        }
    }

    private func prepare() throws {
        made = !FileManager.default.fileExists(atPath: destination.path)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        ready = true
    }

    /// What an earlier entry of the same name left (a link, a file): the
    /// link itself, never what it points to.
    private func removeIfThere(_ url: URL) throws {
        if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil { try FileManager.default.removeItem(at: url) }
    }

    /// A folder itself, not a link to one (lstat's answer).
    private static func isFolder(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }

    private func open(_ url: URL, _ header: DockerTar.Reader.Header) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw DockerError(status: 0, message: "\(url.path) can't be written.")
        }
        writing = (try FileHandle(forWritingTo: url), url, header)
    }

    private func end() throws {
        guard let (handle, url, header) = writing else { return }
        writing = nil
        try handle.close()
        try FileManager.default.setAttributes([.posixPermissions: header.mode & 0o777, .modificationDate: header.modified], ofItemAtPath: url.path)
        summary.files += 1
        summary.bytes += header.size
    }
}

extension DockerEngine {
    /// A drop's files and folders into `folder` of the container, as one
    /// archive written as it is read: its length said first, its pieces
    /// sent as the socket takes them (`sent` hears the bytes so far). The
    /// folder is looked at first — a path that isn't there, or isn't a
    /// folder, is said before anything is sent. `noOverwriteDirNonDir`, as
    /// `docker cp` sends it: a file never replaces a folder, nor a folder a
    /// file. No `copyUIDGID`: the files are root's, as `docker cp` without
    /// `-a` makes them, and engines before moby 29 fail it for a numeric
    /// `USER`.
    func copyIn(_ plan: DockerTar.Plan, into folder: String, of id: String, sent: @escaping @Sendable (Int) -> Void = { _ in }) async throws {
        let stat = try await stat(id, path: folder)
        guard stat.isDirectory || stat.isSymlink else { throw DockerError(status: 400, message: "\(folder) isn't a folder.") }
        let writer = DockerTarWriter(plan)
        try await send(
            .PUT, "/containers/\(id)/archive", ["path": folder, "noOverwriteDirNonDir": "true"], length: plan.length, body: { try writer.next() },
            headers: [("Content-Type", "application/x-tar")], sent: sent)
    }

    /// A file or a folder of the container to `destination`, written as
    /// the archive comes (`DockerTar.Reader`, `DockerTarExtractor`), the
    /// next piece read from the engine only once this one is written
    /// (`receive`): a slow disk slows the engine, and the archive is never
    /// held in memory. `progress` hears the file bytes written and, for a
    /// file, its size (a folder's isn't known before), every 256 KB and at
    /// the end. What it made is removed when it fails.
    func copyOut(
        _ path: String, of id: String, to destination: URL, progress: @escaping @Sendable (_ done: Int, _ total: Int?) -> Void = { _, _ in }
    ) async throws -> DockerTarExtractor.Summary {
        let stat = try await stat(id, path: path)
        let total: Int? = stat.isDirectory ? nil : stat.size
        let extractor = DockerTarExtractor(destination: destination, folder: stat.isDirectory)
        var reader = DockerTar.Reader()
        var done = 0
        var reported = 0
        do {
            try await receive("/containers/\(id)/archive", ["path": path]) { chunk in
                try Task.checkCancellation()
                for event in reader.feed(chunk) {
                    if case .data(let data) = event { done += data.count }
                    try extractor.apply(event)
                }
                if done - reported >= 256 << 10 {
                    reported = done
                    progress(done, total)
                }
            }
            try Task.checkCancellation()
            guard reader.atBoundary else { throw DockerError(status: 0, message: "Docker's archive of \(path) ended partway.") }
            let summary = try extractor.finish()
            progress(done, total)
            return summary
        } catch {
            extractor.discard()
            throw error
        }
    }
}

/// Files copied into and out of containers and volumes: dropped from
/// Finder, picked with Copy Here…, dragged out to Finder, saved to the
/// Mac. The app's, not a detail's: a copy outlives its container being
/// deselected, its tab, its window — each a row its pane's strip shows
/// (`DockerTransfersStrip`). A finished one goes after `linger`; a failed
/// one stays, with the engine's words, until dismissed. A volume's go
/// through a helper made for the copy and removed after
/// (`DockerEngine.reaching`), so the tab's own coming and going can't
/// take it away under one.
@MainActor
final class DockerFileTransfers: ObservableObject {
    static let shared = DockerFileTransfers()

    struct Transfer: Identifiable, Equatable {
        enum Direction: Equatable, Sendable { case into, out }

        let id = UUID()
        var source: DockerFileSource
        var direction: Direction
        /// What goes: `site`, `index.html and site`, `nginx.conf`.
        var name: String
        /// Where: a folder in the container or the volume, or on the Mac
        /// (`~/Desktop`).
        var place: String
        var done = 0
        /// Bytes in all, when known: a folder's copied out isn't.
        var total: Int?
        var error: String?
        var finished = false
        /// Left on the Mac (or out of what came), by name.
        var skipped: [String] = []

        var running: Bool { !finished && error == nil }
    }

    @Published private(set) var transfers: [Transfer] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var shown: [UUID: ContinuousClock.Instant] = [:]
    private let engine: @MainActor () -> DockerEngine?
    private let linger: Duration

    init(engine: @escaping @MainActor () -> DockerEngine? = { DockerModel.shared.engine }, linger: Duration = .seconds(3)) {
        self.engine = engine
        self.linger = linger
    }

    /// A pane's rows: a container's by its id, so a rename (its name in
    /// the source is the old one) keeps them in its strip, to be stopped
    /// or read.
    func transfers(for source: DockerFileSource) -> [Transfer] { transfers.filter { $0.source.target == source.target } }

    /// What of the names dropped a folder has already, and which of those
    /// are folders.
    struct Present: Equatable, Sendable {
        var names: [String] = []
        var folders: Set<String> = []
    }

    /// `urls` into `folder`: planned off the main thread; what is there
    /// already of the names dropped asked about first (`confirm`, a
    /// Replace button), from `listed` when it is the folder shown, else
    /// looked at, at most 20. A folder there already is merged into
    /// (`Plan.merging`). Then sent, and `done` once it is in.
    func copyIn(
        _ urls: [URL], into folder: String, of source: DockerFileSource, listed: [DockerFiles.Entry]?,
        confirm: @escaping (_ title: String, _ detail: String, _ button: String, _ then: @escaping () -> Void) -> Void,
        done: @escaping @MainActor () -> Void = {}
    ) {
        let urls = urls.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        Task {
            let plan: DockerTar.Plan
            do {
                plan = try await Task.detached { try DockerTar.Plan.make(urls) }.value
            } catch {
                return failed(into: folder, of: source, name: DockerTar.Plan.summary(urls.map(\.lastPathComponent)), error)
            }
            guard !plan.items.isEmpty else {
                let why = plan.skipped.isEmpty ? "Nothing to copy." : "Nothing to copy: \(plan.skipped.joined(separator: ", ")) can't go into a container."
                return failed(into: folder, of: source, name: plan.summary, DockerError(status: 0, message: why))
            }
            let there: Present
            if let listed { there = Self.collisions(plan.tops, listed: listed) } else { there = await present(plan.tops, in: folder, of: source) }
            let merged = plan.merging(into: there.folders)
            let start: () -> Void = { self.start(merged, into: folder, of: source, done: done) }
            guard !there.names.isEmpty else { return start() }
            let (title, detail) = Self.replacing(there.names, in: folder)
            confirm(title, detail, "Replace", start)
        }
    }

    /// The names dropped that the folder has already. Pure.
    nonisolated static func collisions(_ names: [String], listed: [DockerFiles.Entry]) -> Present {
        let kinds = Dictionary(listed.map { ($0.name, $0.kind) }, uniquingKeysWith: { first, _ in first })
        let there = names.filter { kinds[$0] != nil }
        return Present(names: there, folders: Set(there.filter { kinds[$0] == .folder }))
    }

    /// What the question says. Pure.
    nonisolated static func replacing(_ names: [String], in folder: String) -> (title: String, detail: String) {
        let how = "A file of the same name is replaced; what a folder holds goes into the one there."
        guard names.count > 1 else { return ("Replace “\(names.first ?? "")” in \(folder)?", "It is there already. \(how)") }
        return ("Replace \(names.count) items in \(folder)?", "\(DockerTar.Plan.summary(names)) are there already. \(how)")
    }

    /// `path` of `source` to `destination` on the Mac. `replacing`: the
    /// user said to replace what is there (a save panel), so it is
    /// written beside it first and swapped in once whole. `finished`
    /// hears how it went, on the main thread.
    func copyOut(
        _ path: String, of source: DockerFileSource, to destination: URL, replacing: Bool = false,
        finished: @escaping @Sendable ((any Error)?) -> Void = { _ in }
    ) {
        let name = (path as NSString).lastPathComponent
        let row = Transfer(source: source, direction: .out, name: name.isEmpty ? path : name, place: Self.place(of: destination))
        transfers.append(row)
        let id = row.id
        guard let engine = engine() else {
            let error = DockerError.unreachable("Docker isn't running.")
            fail(id, error)
            return finished(error)
        }
        tasks[id] = Task {
            do {
                let summary = try await Self.write(path, of: source, through: engine, to: destination, replacing: replacing) { done, total in
                    Task { @MainActor in self.progress(id, done, total) }
                }
                finish(id, skipped: summary.skipped)
                finished(nil)
            } catch {
                fail(id, error)
                finished(error)
            }
        }
    }

    /// Stopped: what is half sent may be in the container already.
    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        transfers.removeAll { $0.id == id }
    }

    func dismiss(_ id: UUID) {
        guard transfers.first(where: { $0.id == id })?.running == false else { return }
        transfers.removeAll { $0.id == id }
    }

    /// `~/Desktop` for a file written there.
    nonisolated static func place(of destination: URL) -> String {
        (destination.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: Running

    private func start(_ plan: DockerTar.Plan, into folder: String, of source: DockerFileSource, done: @escaping @MainActor () -> Void) {
        let row = Transfer(source: source, direction: .into, name: plan.summary, place: folder, total: plan.length, skipped: plan.skipped)
        transfers.append(row)
        let id = row.id
        guard let engine = engine() else { return fail(id, DockerError.unreachable("Docker isn't running.")) }
        tasks[id] = Task {
            do {
                try await engine.reaching(source, folder) { container, at in
                    try await engine.copyIn(plan, into: at, of: container) { sent in Task { @MainActor in self.progress(id, sent, nil) } }
                }
                finish(id)
                done()
            } catch {
                fail(id, error)
            }
        }
    }

    /// The archive read into the destination, off the main actor.
    nonisolated private static func write(
        _ path: String, of source: DockerFileSource, through engine: DockerEngine, to destination: URL, replacing: Bool,
        progress: @escaping @Sendable (Int, Int?) -> Void
    ) async throws -> DockerTarExtractor.Summary {
        let files = FileManager.default
        var beside: URL?
        if replacing { beside = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true) }
        defer { if let beside { try? files.removeItem(at: beside) } }
        let target = beside?.appendingPathComponent(destination.lastPathComponent) ?? destination
        let summary = try await engine.reaching(source, path) { id, at in try await engine.copyOut(at, of: id, to: target, progress: progress) }
        if beside != nil {
            do {
                // The copy's own mode and times: by default the swap keeps
                // the replaced item's, and a script saved over a 0644 one
                // would no longer run.
                _ = try files.replaceItemAt(destination, withItemAt: target, backupItemName: nil, options: [.usingNewMetadataOnly])
            } catch {
                // A folder over a file, or the other way: not swapped in one go.
                try? files.removeItem(at: destination)
                try files.moveItem(at: target, to: destination)
            }
        }
        return summary
    }

    /// A tenth of a second apart at most, and never after it ended.
    private func progress(_ id: UUID, _ done: Int, _ total: Int?) {
        guard let at = transfers.firstIndex(where: { $0.id == id }), transfers[at].running else { return }
        let now = ContinuousClock.now
        if let last = shown[id], now - last < .milliseconds(100) { return }
        shown[id] = now
        transfers[at].done = done
        if let total { transfers[at].total = total }
    }

    private func finish(_ id: UUID, skipped: [String] = []) {
        tasks[id] = nil
        shown[id] = nil
        guard let at = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[at].finished = true
        transfers[at].done = transfers[at].total ?? transfers[at].done
        transfers[at].skipped += skipped
        // What was left out is said until it is read.
        guard transfers[at].skipped.isEmpty else { return }
        let linger = linger
        Task { [weak self] in
            try? await Task.sleep(for: linger)
            self?.transfers.removeAll { $0.id == id }
        }
    }

    private func fail(_ id: UUID, _ error: Error) {
        tasks[id] = nil
        shown[id] = nil
        guard let at = transfers.firstIndex(where: { $0.id == id }) else { return }
        // Stopped by the user, who knows it.
        if error is CancellationError {
            transfers.remove(at: at)
            return
        }
        let said = error.localizedDescription
        if case .volume = transfers[at].source { transfers[at].error = DockerVolumeFiles.said(said) } else { transfers[at].error = said }
    }

    private func failed(into folder: String, of source: DockerFileSource, name: String, _ error: Error) {
        let row = Transfer(source: source, direction: .into, name: name, place: folder)
        transfers.append(row)
        fail(row.id, error)
    }

    /// Which of `names` are in `folder` already, looked at one by one.
    private func present(_ names: [String], in folder: String, of source: DockerFileSource) async -> Present {
        guard let engine = engine() else { return Present() }
        let names = Array(names.prefix(20))
        let found = try? await engine.reaching(source, folder) { id, at in
            var there = Present()
            for name in names {
                guard let stat = try? await engine.stat(id, path: DockerFiles.join(at, name)) else { continue }
                there.names.append(name)
                if stat.isDirectory { there.folders.insert(name) }
            }
            return there
        }
        return found ?? Present()
    }
}

/// A row dragged out of a Files tab: whose, which, and what Finder is
/// told it is.
struct DockerFileItem: Equatable, Sendable {
    var source: DockerFileSource
    var path: String
    var isFolder: Bool

    var name: String { (path as NSString).lastPathComponent }

    /// A promise must be data or a folder: a folder's, else its
    /// extension's when that is data, else plain data.
    var fileType: String {
        if isFolder { return UTType.folder.identifier }
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext, conformingTo: .data), type.conforms(to: .data) { return type.identifier }
        return UTType.data.identifier
    }
}

/// The source side of a dragged row's file promise: Finder (or a terminal
/// pane) names the place, and the archive's GET is written there as it
/// comes, through the app's copies. Not the main actor's: AppKit asks it
/// to write on its own queue, and Swift traps a main-actor closure called
/// there (CLAUDE.md). The provider holds its delegate weakly, so each is
/// kept here until it has written, or its drag ended with nothing taken.
final class DockerFilePromise: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let item: DockerFileItem
    private let transfers: DockerFileTransfers
    private let queue: OperationQueue

    nonisolated(unsafe) private static var kept: [ObjectIdentifier: DockerFilePromise] = [:]
    private static let lock = NSLock()

    init(item: DockerFileItem, transfers: DockerFileTransfers) {
        self.item = item
        self.transfers = transfers
        queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.name = "Overterm file promises"
        super.init()
    }

    static func keep(_ promise: DockerFilePromise) { lock.withLock { kept[ObjectIdentifier(promise)] = promise } }
    static func release(_ promise: DockerFilePromise) { lock.withLock { kept[ObjectIdentifier(promise)] = nil } }
    /// How many wait to be written, for a test.
    static var waiting: Int { lock.withLock { kept.count } }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { item.name }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping ((any Error)?) -> Void) {
        nonisolated(unsafe) let done = completionHandler
        let item = item
        let transfers = transfers
        Task { @MainActor in
            transfers.copyOut(item.path, of: item.source, to: url) { error in
                done(error)
                DockerFilePromise.release(self)
            }
        }
    }
}
