import Foundation

/// What Overterm keeps of Terraform roots, in its own folder, never the
/// repository (analysis 2.1, 5.1): the state identities once seen
/// production — names only (a backend's type, bucket and key, a local
/// state's path) — so production stays production in every worktree and
/// under every folder name; the var files the person chose for a root's
/// plans, per checkout and root (stage 1d, "Missing variables"), by name;
/// and whether they took the plugin cache (4.13). One for the app.
@MainActor
final class TerraformRootStore {
    static let shared = TerraformRootStore(url: AppEnvironment.terraformRootsFile)

    private struct File: Codable {
        var productionIdentities: [TerraformStateIdentity] = []
        /// By `key(checkout:root:)`: the var files' paths, relative to the root.
        var varFiles: [String: [String]]? = nil
        /// The plugin cache's offer, answered (4.13): nil until it was.
        var pluginCache: Bool? = nil
    }

    let url: URL
    private var file: File?

    init(url: URL) {
        self.url = url
    }

    private func load() -> File {
        if let file { return file }
        let read = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(File.self, from: $0) } ?? File()
        file = read
        return read
    }

    var productionIdentities: Set<TerraformStateIdentity> { Set(load().productionIdentities) }

    static func key(checkout: URL, root: String) -> String { checkout.standardizedFileURL.path + "\u{0}" + root }

    /// The var files chosen for a root's plans in a checkout.
    func varFiles(checkout: URL, root: String) -> [String] { load().varFiles?[Self.key(checkout: checkout, root: root)] ?? [] }

    func setVarFiles(_ files: [String], checkout: URL, root: String) {
        var current = load()
        var all = current.varFiles ?? [:]
        let key = Self.key(checkout: checkout, root: root)
        let kept = files.filter(TerraformCommands.isVarFile)
        guard all[key] ?? [] != kept else { return }
        all[key] = kept.isEmpty ? nil : kept
        // Bounded: the oldest choices aren't worth more than a few KB.
        if all.count > 500, let drop = all.keys.sorted().first { all[drop] = nil }
        current.varFiles = all
        save(current)
    }

    /// The plugin cache's offer, as answered; nil when it never was.
    var pluginCache: Bool? { load().pluginCache }

    func setPluginCache(_ taken: Bool) {
        var current = load()
        current.pluginCache = taken
        save(current)
    }

    private func save(_ current: File) {
        file = current
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(current) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Remembers `identities` as production; written at once when one is
    /// new. Never forgotten, and never evicted: a bound that dropped the
    /// oldest would lower a state once production back to remote (5.1,
    /// 5.13 rule 12). An identity is a backend's names — a hundred bytes —
    /// and only what the classifier called production by the root's own
    /// signals is kept (`TerraformRootCard.identityToRemember`).
    func rememberProduction(_ identities: [TerraformStateIdentity]) {
        var current = load()
        var known = Set(current.productionIdentities)
        var added = false
        for identity in identities where known.insert(identity).inserted {
            current.productionIdentities.append(identity)
            added = true
        }
        guard added else { return }
        save(current)
    }
}

extension TerraformRootStore {
    func rememberProduction(_ identity: TerraformStateIdentity) { rememberProduction([identity]) }
}
