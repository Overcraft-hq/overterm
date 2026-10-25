import Foundation

/// The links a rename breaks, written again — what Obsidian's "Automatically
/// update internal links" does. A link is rewritten only when it would no
/// longer find its file: `[[Plan]]` stays `[[Plan]]` when Plan.md only
/// moved folder and no other Plan.md is closer. Headings, blocks, aliases
/// and embeds are kept; the new name is written the way the vault's "New
/// link format" says. Pure.
enum NoteRename {
    /// Every file a rename moves, old path to new (a folder moves all of
    /// them), vault-relative.
    static func moves(of old: String, to new: String, files: [String]) -> [String: String] {
        var moves: [String: String] = [:]
        for file in files where file == old || file.hasPrefix(old + "/") {
            moves[file] = new + file.dropFirst(old.count)
        }
        return moves
    }

    /// The new text of every note whose links change, by its path before
    /// the rename. `read` gives a note's text as it is now.
    static func rewrites(
        index: NotesIndex, moves: [String: String], settings: ObsidianSettings, read: (String) -> String?
    ) -> [String: String] {
        guard !moves.isEmpty else { return [:] }
        let after = LinkResolver(files: index.resolver.files.map { moves[$0] ?? $0 })
        var result: [String: String] = [:]
        for source in index.paths {
            guard let doc = index.document(source), !doc.links.isEmpty else { continue }
            let sourceAfter = moves[source] ?? source
            // Only notes with a link that may break are read.
            let touched = doc.links.contains { link in
                guard let target = target(of: link, from: source, resolver: index.resolver) else { return false }
                return moves[target] != nil || moves[source] != nil
            }
            guard touched, let text = read(source) else { continue }
            // Ranges from the text as it is, not as the index last saw it.
            let current = NoteParser.parse(text)
            var edits: [(NSRange, String)] = []
            for link in current.links {
                guard let target = target(of: link, from: source, resolver: index.resolver) else { continue }
                let targetAfter = moves[target] ?? target
                guard moves[target] != nil || moves[source] != nil else { continue }
                if Self.target(of: link, from: sourceAfter, resolver: after) == targetAfter { continue }
                edits.append((link.range, written(link, to: targetAfter, from: sourceAfter, resolver: after, settings: settings, in: text)))
            }
            guard !edits.isEmpty else { continue }
            let ns = NSMutableString(string: text)
            for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) {
                ns.replaceCharacters(in: range, with: replacement)
            }
            result[source] = ns as String
        }
        return result
    }

    /// The file a link names, wikilink or Markdown.
    static func target(of link: NoteDocument.Link, from source: String, resolver: LinkResolver) -> String? {
        if link.target.isEmpty { return nil }
        if link.isMarkdown {
            let folder = LinkResolver.folder(of: source)
            if let path = LinkResolver.standardized(folder.isEmpty ? link.target : folder + "/" + link.target),
                let file = resolver.resolve(path, from: "")
            {
                return file
            }
        }
        return resolver.resolve(link.target, from: source)
    }

    /// The link again, naming `target`: its kind, anchor and alias kept.
    static func written(
        _ link: NoteDocument.Link, to target: String, from source: String, resolver: LinkResolver, settings: ObsidianSettings, in text: String
    ) -> String {
        let original = (text as NSString).substring(with: link.range)
        let bang = link.isEmbed ? "!" : ""
        if link.isMarkdown {
            var path: String
            switch settings.newLinkFormat {
            case "relative": path = LinkResolver.relative(target, from: LinkResolver.folder(of: source))
            default: path = target
            }
            path = path.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: " ", with: "%20")
            let anchor = link.heading.map { "#" + $0.replacingOccurrences(of: " ", with: "%20") } ?? ""
            return "\(bang)[\(link.alias ?? "")](\(path)\(anchor))"
        }
        var name = resolver.linkText(for: target, from: source, format: settings.newLinkFormat)
        // `[[Plan.md]]` was written with its extension: kept so.
        if link.target.lowercased().hasSuffix(".md"), !name.lowercased().hasSuffix(".md") { name += ".md" }
        var inner = name
        if let heading = link.heading { inner += "#" + heading }
        if let block = link.block { inner += "#^" + block }
        // In a table the bar is escaped: `[[a\|b]]`.
        let bar = original.contains("\\|") ? "\\|" : "|"
        if let alias = link.alias { inner += bar + alias }
        return "\(bang)[[\(inner)]]"
    }
}
