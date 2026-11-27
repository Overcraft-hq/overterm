import Foundation

/// A new note's name, as Obsidian takes one: the `.md` added, and refused
/// with the characters Obsidian refuses in a file name (and those a link
/// can't carry), or when a note of that name is there already. Pure but
/// for the names already taken.
package enum NoteNaming {
    /// Obsidian's "File name cannot contain": `* " \ / < > : | ?`; and
    /// `# ^ [ ]`, which break a link to it.
    package static let refused: Set<Character> = ["*", "\"", "\\", "/", "<", ">", ":", "|", "?", "#", "^", "[", "]"]

    /// The file's name for a note named `name`.
    package static func fileName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.lowercased().hasSuffix(".md") ? trimmed : trimmed + ".md"
    }

    /// Why `name` can't be a new note in `folder`, or nil when it can.
    package static func problem(_ name: String, in folder: URL) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let bare = trimmed.lowercased().hasSuffix(".md") ? String(trimmed.dropLast(3)) : trimmed
        if bare.trimmingCharacters(in: .whitespaces).isEmpty { return "A name, please." }
        if bare.hasPrefix(".") { return "A name starting with a dot would be hidden." }
        let bad = bare.filter { refused.contains($0) }
        if let first = bad.first { return "A note's name can't have “\(first)” in it." }
        let url = folder.appendingPathComponent(fileName(trimmed))
        if FileManager.default.fileExists(atPath: url.path) || NoteFiles.isEvicted(url) {
            return "There is a note named “\(bare)” here already."
        }
        return nil
    }
}
