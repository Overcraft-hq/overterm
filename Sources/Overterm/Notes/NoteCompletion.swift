import Foundation

/// What typing in a note asks to complete — a `[[link`, its `#heading`, or
/// a `#tag` — and what the vault offers for it. Pure.
enum NoteCompletion {
    enum Context: Equatable {
        /// `[[Pla|`: the query, and where it starts (UTF-16, in the line).
        case link(query: String, start: Int)
        /// `[[Plan#Go|`: the note, the heading typed so far, where that starts.
        case heading(target: String, query: String, start: Int)
        /// `#pro|`: after the `#`.
        case tag(query: String, start: Int)
    }

    struct Candidate: Equatable {
        var label: String
        var insert: String
        var detail: String
    }

    /// From the line up to the caret.
    static func context(before line: String) -> Context? {
        let ns = line as NSString
        let open = ns.range(of: "[[", options: .backwards)
        if open.location != NSNotFound {
            let after = ns.substring(from: NSMaxRange(open))
            if !after.contains("]]"), !after.contains("|") {
                if let hash = after.firstIndex(of: "#") {
                    let target = String(after[..<hash])
                    let query = String(after[after.index(after: hash)...])
                    return .heading(target: target, query: query, start: NSMaxRange(open) + (target as NSString).length + 1)
                }
                return .link(query: after, start: NSMaxRange(open))
            }
        }
        guard let regex = cache.regex(#"(?:^|[\s(])#([\p{L}\p{N}_/\-]*)$"#, []),
            let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        let query = match.range(at: 1)
        // A heading's `# ` is not a tag; `#` at the line's start followed by nothing is either.
        if query.location == 1 && query.length == 0 { return nil }
        return .tag(query: ns.substring(with: query), start: query.location)
    }

    private static let cache = RegexCache()

    static func candidates(_ context: Context, index: NotesIndex, source: String, settings: ObsidianSettings) -> [Candidate] {
        switch context {
        case .link(let query, _):
            var paths = index.notes(matching: query, limit: 40)
            // Attachments too (images, PDFs) once a name is typed.
            if !query.isEmpty {
                let files = index.resolver.files.filter { !$0.lowercased().hasSuffix(".md") && $0.localizedCaseInsensitiveContains(query) }
                paths += files.prefix(max(0, 50 - paths.count))
            }
            return paths.map { path in
                let text = index.resolver.linkText(for: path, from: source, format: settings.newLinkFormat)
                let folder = LinkResolver.folder(of: path)
                return Candidate(label: (LinkResolver.name(of: path) as NSString).deletingPathExtension, insert: text, detail: folder)
            }
        case .heading(let target, let query, _):
            let path = target.isEmpty ? source : index.resolver.resolve(target, from: source)
            guard let path, let doc = index.document(path) else { return [] }
            return doc.headings.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
                .map { Candidate(label: $0.text, insert: $0.text, detail: String(repeating: "#", count: $0.level)) }
        case .tag(let query, _):
            return index.tags.filter { query.isEmpty || $0.key.localizedCaseInsensitiveContains(query) }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(50)
                .map { Candidate(label: $0.key, insert: $0.key, detail: "\($0.value)") }
        }
    }
}
