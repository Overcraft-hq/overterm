import Foundation

/// The file open in the editor pane: its text, whether it has unsaved
/// edits, and why it can't be shown when it can't.
@MainActor
final class EditorDocument: ObservableObject {
    @Published private(set) var url: URL?
    @Published private(set) var isDirty = false
    /// Set instead of text for binary, huge or unreadable files.
    @Published private(set) var unavailable: String?
    /// The text as loaded or last saved. The text view owns the live text.
    private(set) var text = ""
    /// On-disk modification date at load/save, to notice outside changes.
    private var loadedModification: Date?
    /// Why this file is never saved, when it isn't: Overterm's copy of a
    /// cluster object (`KubeManifestEdits`) — a value retyped in it stays in
    /// memory, never in the file. Nothing writes it, and its edits ask
    /// nothing on close.
    var unsaveable: String?
    /// Text that lives in memory only, under a name no file has: a cluster
    /// object's YAML (`KubeResourceBuffer`). Nothing reads or writes the
    /// disk for it, and `unsaveable` says why a save is refused.
    private(set) var isVirtual = false

    /// Refused: `unsaveable` says why.
    struct Unsaveable: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Bigger than this is a log or a dump, not something to edit here.
    static let maxBytes = 5 * 1024 * 1024

    var name: String { url?.lastPathComponent ?? "" }

    /// The file was renamed (the sidebar's Rename…): the same file, so its
    /// text and edits stay, under its new name.
    func moved(to newURL: URL) {
        url = newURL
    }

    func load(_ url: URL) {
        self.url = url
        isDirty = false
        unavailable = nil
        text = ""
        do {
            // Through a symlink to what it points at: attributesOfItem
            // describes the link itself.
            let attributes = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
            // A FIFO or a device would block the main thread on read — for a
            // FIFO, until something writes to it.
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                unavailable = "Not a regular file."
                return
            }
            if let size = attributes[.size] as? Int, size > Self.maxBytes {
                unavailable = "Too large to edit here (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))."
                return
            }
            let data = try Data(contentsOf: url)
            // A NUL in the first 8 KB is how git decides a file is binary too.
            if data.prefix(8192).contains(0) {
                unavailable = "Binary file."
                return
            }
            guard let string = String(data: data, encoding: .utf8) else {
                unavailable = "Not UTF-8 text."
                return
            }
            text = string
            loadedModification = attributes[.modificationDate] as? Date
        } catch {
            unavailable = error.localizedDescription
        }
    }

    /// `text`, in memory, under `url` — never read from it, never written.
    func loadVirtual(_ url: URL, text: String) {
        self.url = url
        isVirtual = true
        isDirty = false
        unavailable = nil
        self.text = text
        loadedModification = nil
    }

    /// A virtual document's text as its source has it now: no edits of its own.
    func replaceVirtual(_ text: String) {
        guard isVirtual else { return }
        self.text = text
        isDirty = false
    }

    func markEdited() {
        // A virtual document's edits are its source's to say (`setVirtualEdited`):
        // undone back to it, it has none, whichever editor typed.
        guard url != nil, unavailable == nil, !isVirtual else { return }
        isDirty = true
    }

    /// A virtual document's edits, as its source says: a cluster object's
    /// text against what the cluster had — the same for every editor showing it.
    func setVirtualEdited(_ edited: Bool) {
        guard isVirtual, isDirty != edited else { return }
        isDirty = edited
    }

    /// The file changed on disk while it had unsaved edits here: saving would
    /// silently throw away what changed it (usually an agent).
    struct ChangedOnDisk: LocalizedError {
        let name: String
        var errorDescription: String? { "“\(name)” changed on disk since you opened it." }
    }

    /// Writes `newText`. Refuses with `ChangedOnDisk` when the file changed
    /// meanwhile, unless `overwriting`. Written through a symlink to its
    /// target — an atomic write to the link would replace it with a file.
    func save(_ newText: String, overwriting: Bool = false) throws {
        guard let url, unavailable == nil else { return }
        if let unsaveable { throw Unsaveable(reason: unsaveable) }
        if changedOnDisk, !overwriting { throw ChangedOnDisk(name: name) }
        let target = url.resolvingSymlinksInPath()
        try Data(newText.utf8).write(to: target, options: .atomic)
        text = newText
        isDirty = false
        loadedModification = Self.modification(of: url)
    }

    /// The file changed on disk since it was loaded or saved (an agent
    /// edited it).
    var changedOnDisk: Bool {
        guard let url, let loadedModification, let current = Self.modification(of: url) else { return false }
        return current > loadedModification
    }

    private static func modification(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.modificationDate] as? Date
    }

    func close() {
        isVirtual = false
        url = nil
        isDirty = false
        unavailable = nil
        text = ""
        loadedModification = nil
    }
}

/// Where each line starts, for the line-number gutter.
enum LineIndex {
    /// UTF-16 offsets of every line start (the first is 0).
    static func starts(of text: NSString) -> [Int] {
        var starts = [0]
        let length = text.length
        // In chunks: character(at:) per character is a message send each,
        // and this runs on every edit (the gutter) — 4 MB made that visible.
        let chunk = 64 * 1024
        var buffer = [unichar](repeating: 0, count: chunk)
        var base = 0
        while base < length {
            let count = min(chunk, length - base)
            buffer.withUnsafeMutableBufferPointer { pointer in
                text.getCharacters(pointer.baseAddress!, range: NSRange(location: base, length: count))
                for i in 0..<count where pointer[i] == 0x0A { starts.append(base + i + 1) }
            }
            base += count
        }
        return starts
    }

    /// 1-based line number of a UTF-16 offset.
    static func line(of offset: Int, in starts: [Int]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }
}
