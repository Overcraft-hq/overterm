import Foundation

/// What the reading view is handed for a note (NoteReaderView, reader.js):
/// its body without the frontmatter, its properties in the order written,
/// and every link it — and every note it embeds — has, already resolved.
/// The script only draws; deciding what a link means is the index's. Pure.
struct NoteRenderPayload: Equatable, Sendable {
    struct Target: Equatable, Sendable {
        var path: String
        var kind: NoteItem.Kind
    }

    var path: String
    var text: String
    /// Lines the frontmatter took, so a task's line in `text` is its line in the file.
    var lineOffset: Int
    /// Key, value as shown, and the items when it is a list.
    var properties: [(String, String, [String]?)]
    /// By target as written (`Folder/Note`, `image.png`); a missing key is
    /// a link to a note not written yet.
    var links: [String: Target]
    /// Embedded notes' text, by `target` or `target#anchor` as written.
    var embeds: [String: String]

    static func == (a: Self, b: Self) -> Bool {
        a.path == b.path && a.text == b.text && a.lineOffset == b.lineOffset && a.links == b.links && a.embeds == b.embeds
            && a.properties.map { "\($0.0)\u{1}\($0.1)\u{1}\($0.2 ?? [])" } == b.properties.map { "\($0.0)\u{1}\($0.1)\u{1}\($0.2 ?? [])" }
    }

    /// Builds it; `read` gives an embedded note's text (nil when it can't).
    static func make(path: String, text: String, index: NotesIndex, read: (String) -> String?) -> NoteRenderPayload {
        let doc = NoteParser.parse(text)
        let ns = text as NSString
        var body = text
        var lineOffset = 0
        if let range = doc.frontmatterRange {
            body = ns.substring(from: range.length)
            lineOffset = ns.substring(to: range.length).components(separatedBy: "\n").count - 1
        }
        var payload = NoteRenderPayload(
            path: path, text: body, lineOffset: lineOffset, properties: properties(doc), links: [:], embeds: [:])
        var seen: Set<String> = [path]
        func collect(_ doc: NoteDocument, from source: String, depth: Int) {
            // Markdown links and images: a path from the note's folder, else
            // Obsidian's rules — keyed `md:` and the path as written.
            for link in doc.links where link.isMarkdown && !link.target.isEmpty && payload.links["md:" + link.target] == nil {
                if let resolved = NoteRename.target(of: link, from: source, resolver: index.resolver) {
                    payload.links["md:" + link.target] = Target(path: resolved, kind: NoteItem.Kind(URL(fileURLWithPath: resolved)))
                }
            }
            for link in doc.links where !link.isMarkdown {
                if !link.target.isEmpty, payload.links[link.target] == nil,
                    let resolved = index.resolver.resolve(link.target, from: source)
                {
                    payload.links[link.target] = Target(path: resolved, kind: NoteItem.Kind(URL(fileURLWithPath: resolved)))
                }
                guard link.isEmbed, depth < 3 else { continue }
                let target = link.target.isEmpty ? source : index.resolver.resolve(link.target, from: source)
                guard let target, target.lowercased().hasSuffix(".md") else { continue }
                let anchor = link.block.map { "^" + $0 } ?? link.heading
                let key = link.target + (anchor.map { "#" + $0 } ?? "")
                guard payload.embeds[key] == nil, let full = read(target) else { continue }
                // Its links named by their paths: a name means the file
                // closest to the embedded note, not to this one.
                let embedded = absolute(NoteSections.extract(full, anchor: anchor), from: target, resolver: index.resolver)
                payload.embeds[key] = embedded
                // A note embedding itself whole would never end.
                if anchor == nil && !seen.insert(target).inserted { payload.embeds[key] = "" }
                collect(NoteParser.parse(embedded), from: target, depth: depth + 1)
            }
        }
        collect(doc, from: path, depth: 0)
        return payload
    }

    /// `text`'s wikilinks with the paths they resolve to from `source`, so
    /// they mean the same wherever the text is shown. What they read as is
    /// kept: an alias stays, a bare name becomes the alias.
    static func absolute(_ text: String, from source: String, resolver: LinkResolver) -> String {
        let doc = NoteParser.parse(text)
        let ns = NSMutableString(string: text)
        for link in doc.links.reversed() where !link.isMarkdown {
            let path = link.target.isEmpty ? source : resolver.resolve(link.target, from: source)
            guard let path else { continue }
            var inner = path.lowercased().hasSuffix(".md") ? String(path.dropLast(3)) : path
            if let heading = link.heading { inner += "#" + heading }
            if let block = link.block { inner += "#^" + block }
            // In a table the bar stays escaped.
            let bar = ns.substring(with: link.range).contains("\\|") ? "\\|" : "|"
            if let alias = link.alias {
                inner += bar + alias
            } else if !link.isEmbed {
                let shown = link.target.isEmpty ? (link.heading ?? "") : link.target
                inner += bar + (link.heading.map { link.target.isEmpty ? $0 : "\(link.target) > \($0)" } ?? shown)
            }
            ns.replaceCharacters(in: link.range, with: (link.isEmbed ? "![[" : "[[") + inner + "]]")
        }
        return ns as String
    }

    /// The frontmatter's keys in the order they're written (a dictionary
    /// has none), with their values as parsed.
    static func properties(_ doc: NoteDocument) -> [(String, String, [String]?)] {
        guard let yaml = doc.frontmatter else { return [] }
        var keys: [String] = []
        for line in yaml.components(separatedBy: "\n") {
            guard let first = line.first, !first.isWhitespace, first != "#", first != "-", let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !key.isEmpty, !keys.contains(key) { keys.append(key) }
        }
        return keys.compactMap { key in
            guard let value = doc.properties[key] else { return nil }
            if case .list(let items) = value { return (key, value.display, items) }
            return (key, value.display, nil)
        }
    }

    /// As JSON for `OT.render`.
    func json(vaultBase: String, base: String, breaks: Bool, dark: Bool, colors: [String: String]) -> String {
        var links: [String: Any] = [:]
        for (key, target) in self.links { links[key] = ["path": target.path, "kind": target.kind.rawValue] }
        let object: [String: Any] = [
            "path": path, "text": text, "lineOffset": lineOffset,
            "properties": properties.map { [$0.0, $0.1, $0.2 as Any? ?? NSNull()] as [Any] },
            "links": links, "embeds": embeds, "vault": vaultBase, "base": base, "breaks": breaks, "dark": dark, "colors": colors,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// A part of a note, as an embed names it: `#Heading` (the heading and
/// what is under it, to the next heading as high) or `#^block` (the line
/// or paragraph that ends with it). Pure.
enum NoteSections {
    static func extract(_ text: String, anchor: String?) -> String {
        guard let anchor, !anchor.isEmpty else { return stripFrontmatter(text) }
        if anchor.hasPrefix("^") { return block(text, id: String(anchor.dropFirst())) ?? "" }
        return section(text, heading: anchor) ?? ""
    }

    static func stripFrontmatter(_ text: String) -> String {
        guard let range = NoteParser.parse(text).frontmatterRange else { return text }
        return (text as NSString).substring(from: range.length)
    }

    static func section(_ text: String, heading: String) -> String? {
        let doc = NoteParser.parse(text)
        // Obsidian names a nested heading `A#B`: the last part is the one.
        let wanted = (heading.split(separator: "#").last.map(String.init) ?? heading).trimmingCharacters(in: .whitespaces).lowercased()
        guard let start = doc.headings.firstIndex(where: { $0.text.lowercased() == wanted }) else { return nil }
        let found = doc.headings[start]
        let end = doc.headings[(start + 1)...].first { $0.level <= found.level }?.range.location ?? (text as NSString).length
        return (text as NSString).substring(with: NSRange(location: found.range.location, length: end - found.range.location))
            .trimmingCharacters(in: .newlines)
    }

    static func block(_ text: String, id: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasSuffix("^" + id) }) else { return nil }
        let marker = " ^" + id
        func clean(_ line: String) -> String {
            var line = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
            if line.hasSuffix(marker) { line.removeLast(marker.count) }
            return line
        }
        // A line on its own after a paragraph (or a list, a table) names it all.
        if lines[index].trimmingCharacters(in: .whitespaces) == "^" + id, index > 0 {
            var start = index - 1
            while start > 0, !lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty { start -= 1 }
            return lines[start..<index].joined(separator: "\n")
        }
        // A list item is itself; a paragraph is all its lines.
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") || line.first?.isNumber == true {
            return clean(lines[index])
        }
        var start = index
        while start > 0, !lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty { start -= 1 }
        return (lines[start..<index] + [clean(lines[index])]).joined(separator: "\n")
    }
}

/// Edits the reading view asks for, made in the text. Pure.
enum NoteEdits {
    /// The task on `line` ticked or unticked; nil when there is none there.
    /// `[x]` goes back to `[ ]`, anything else (`[ ]`, `[/]`) to `[x]`.
    static func toggleTask(in text: String, line: Int) -> (range: NSRange, replacement: String)? {
        guard let task = NoteParser.parse(text).tasks.first(where: { $0.line == line }) else { return nil }
        return (task.statusRange, task.isDone ? " " : "x")
    }
}
