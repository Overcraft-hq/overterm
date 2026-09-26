import Foundation

/// A saved command. `{{name}}` marks a value asked for when it is used.
struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var command: String

    /// Placeholder names in order of first appearance, without repeats.
    var placeholders: [String] {
        var seen: [String] = []
        for name in Self.placeholderNames(in: command) where !seen.contains(name) {
            seen.append(name)
        }
        return seen
    }

    /// The command with each `{{name}}` replaced by `values[name]`
    /// (missing ones left as they are).
    func filled(with values: [String: String]) -> String {
        var result = command
        for (name, value) in values {
            result = result.replacingOccurrences(of: "{{\(name)}}", with: value)
        }
        return result
    }

    private static func placeholderNames(in text: String) -> [String] {
        var names: [String] = []
        var rest = text[...]
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            let name = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
                names.append(name)
            }
            rest = rest[close.upperBound...]
        }
        return names
    }
}

/// Snippets, kept as a JSON file you can also edit by hand.
@MainActor
final class SnippetStore: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []
    let url: URL

    static var defaultURL: URL {
        AppEnvironment.supportDirectory.appendingPathComponent("snippets.json")
    }

    /// A first run starts with a few everyday commands.
    static let starters: [Snippet] = [
        Snippet(name: "Validate everything", command: "mise run validate"),
        Snippet(name: "Deploy a service", command: "infra/scripts/deploy.sh release {{service}}"),
        Snippet(name: "Rollout status", command: "infra/scripts/deploy.sh status"),
        Snippet(name: "Open a PR", command: "gh pr create --fill --draft"),
        Snippet(name: "Worktrees", command: "git worktree list"),
    ]

    init(url: URL = defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Snippet].self, from: data) {
            snippets = saved
        } else if !FileManager.default.fileExists(atPath: url.path) {
            snippets = Self.starters
            save()
        }
        // An unreadable file is left alone (not overwritten) and shows empty.
    }

    func upsert(_ snippet: Snippet) {
        if let i = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[i] = snippet
        } else {
            snippets.append(snippet)
        }
        save()
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snippets).write(to: url, options: .atomic)
        } catch {
            GhosttyRuntime.logger.error("snippets save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
