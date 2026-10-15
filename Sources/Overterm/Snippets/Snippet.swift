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

    /// What a first run used to be planted with, up to v1.31.1: five
    /// invented commands — someone else's deploy script, a task runner this
    /// repository doesn't have. They are dropped from the file the next time
    /// it is read, matched name *and* command, so one you edited or wrote
    /// yourself stays. The list starts empty now.
    private static let planted: Set<[String]> = [
        ["Validate everything", "mise run validate"],
        ["Deploy a service", "infra/scripts/deploy.sh release {{service}}"],
        ["Rollout status", "infra/scripts/deploy.sh status"],
        ["Open a PR", "gh pr create --fill --draft"],
        ["Worktrees", "git worktree list"],
    ]

    /// `snippets` without the planted ones. Pure, so what it spares is tested.
    static func withoutPlanted(_ snippets: [Snippet]) -> [Snippet] {
        snippets.filter { !planted.contains([$0.name, $0.command]) }
    }

    init(url: URL = defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Snippet].self, from: data) {
            snippets = Self.withoutPlanted(saved)
            // Only when it dropped something: a save on every launch would
            // rewrite a file the user may be editing by hand.
            if snippets.count != saved.count { save() }
        } else if !FileManager.default.fileExists(atPath: url.path) {
            // Nothing written until there is a snippet to write.
        } else {
            // Unreadable: set aside, so the next save doesn't write over what
            // was in it; the list starts empty.
            UnreadableFile.setAside(url)
        }
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
