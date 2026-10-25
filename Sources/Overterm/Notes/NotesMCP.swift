import Foundation

/// The notes vault's MCP tools, beside the browser's and the API client's
/// on the same server (BrowserBridge): an agent searches the vault and
/// reads a note — its links and what links to it too. Read-only: agents
/// never write to the vault (Settings ▸ Notes says so).
@MainActor
enum NotesMCP {
    static func call(_ name: String, _ arguments: [String: Any], notes: NotesModel) async throws -> [String: Any] {
        await withCheckedContinuation { continuation in notes.whenLoaded { continuation.resume() } }
        func string(_ key: String) -> String? { (arguments[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let index = notes.index
        let vault = notes.vault
        switch name {
        case "notes_search":
            guard let query = string("query") else { throw BrowserMCP.ToolError(message: "notes_search needs “query”.") }
            let limit = min(max(arguments["limit"] as? Int ?? 20, 1), 100)
            return BrowserMCP.textResult(await search(query, index: index, vault: vault, limit: limit))
        case "notes_read":
            guard let target = string("note") else { throw BrowserMCP.ToolError(message: "notes_read needs “note”: a path or a name from notes_search.") }
            var name = target
            var anchor: String?
            if let hash = target.firstIndex(of: "#") {
                anchor = String(target[target.index(after: hash)...])
                name = String(target[..<hash])
            }
            guard let path = index.resolver.resolve(name, from: ""), path.lowercased().hasSuffix(".md"), index.notes[path] != nil else {
                throw BrowserMCP.ToolError(message: "No note “\(target)” in the vault — notes_search finds them.")
            }
            // Off the main thread: a note iCloud hasn't downloaded is waited for.
            let url = vault.root.appendingPathComponent(path)
            let loaded = await Task.detached(priority: .userInitiated) { Result { try NoteFiles.read(url) } }.value
            let text: String
            do {
                text = try loaded.get()
            } catch {
                throw BrowserMCP.ToolError(message: error.localizedDescription)
            }
            // Bounded both ways: a negative prefix traps.
            let limit = min(max(arguments["max_chars"] as? Int ?? 40_000, 100), 1_000_000)
            return BrowserMCP.textResult(read(path, text: anchor.map { NoteSections.extract(text, anchor: $0) } ?? text, index: index, limit: limit))
        default:
            throw BrowserMCP.ToolError(message: "No tool \(name).")
        }
    }

    /// Names, aliases and tags first, then lines that hold every word.
    static func search(_ query: String, index: NotesIndex, vault: NotesVault, limit: Int) async -> String {
        var out: [String] = []
        let tag = query.hasPrefix("#") ? String(query.dropFirst()) : nil
        if let tag {
            let tagged = index.notes(tagged: tag).prefix(limit)
            out.append(tagged.isEmpty ? "No note is tagged #\(tag)." : "Tagged #\(tag):\n" + tagged.map { "- \($0)" }.joined(separator: "\n"))
            return out.joined(separator: "\n\n")
        }
        let named = index.notes(matching: query, limit: limit)
        if !named.isEmpty { out.append("Notes by name:\n" + named.map { "- \($0)" }.joined(separator: "\n")) }
        let paths = index.paths
        let lines = await Task.detached(priority: .userInitiated) { NotesSearch.lines(query, in: vault, paths: paths, perNote: 3, limit: limit) }.value
        if !lines.isEmpty { out.append("Lines:\n" + lines.map { "- \($0.path):\($0.line): \($0.text)" }.joined(separator: "\n")) }
        return out.isEmpty ? "Nothing in the vault matches “\(query)”." : out.joined(separator: "\n\n")
    }

    static func read(_ path: String, text: String, index: NotesIndex, limit: Int) -> String {
        var out = "# \(path)\n\n"
        out += text.count > limit ? String(text.prefix(limit)) + "\n… (\(text.count - limit) more characters; max_chars for more)" : text
        let doc = index.document(path)
        let links = Set(doc?.links.compactMap { index.resolve($0, from: path) } ?? []).sorted()
        if !links.isEmpty { out += "\n\n---\nLinks to: " + links.joined(separator: ", ") }
        let backlinks = Set(index.backlinks(of: path).map(\.source)).sorted()
        if !backlinks.isEmpty { out += "\nLinked from: " + backlinks.joined(separator: ", ") }
        return out
    }

    static let tools: [[String: Any]] = [
        tool(
            "notes_search",
            "Search the user's notes (an Obsidian vault of Markdown): note names and aliases, then lines holding every word. `#tag` lists the notes with that tag.",
            [
                "query": ["type": "string", "description": "Words to find, or #tag."],
                "limit": ["type": "integer", "description": "At most this many results of each kind (default 20)."],
            ], required: ["query"]),
        tool(
            "notes_read",
            "Read one of the user's notes, with the notes it links to and the ones linking to it. Read-only.",
            [
                "note": ["type": "string", "description": "Its path (Projects/Plan.md) or name (Plan); Plan#Heading reads that section."],
                "max_chars": ["type": "integer", "description": "How much of it to return (default 40000)."],
            ], required: ["note"]),
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        [
            "name": name, "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any],
        ]
    }
}
