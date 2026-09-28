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

    /// Bigger than this is a log or a dump, not something to edit here.
    static let maxBytes = 5 * 1024 * 1024

    var name: String { url?.lastPathComponent ?? "" }

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

    func markEdited() {
        guard url != nil, unavailable == nil else { return }
        isDirty = true
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
