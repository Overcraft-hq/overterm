import Foundation

/// What Overterm keeps of Terraform roots, in its own folder, never the
/// repository (analysis 2.1, 5.1): the state identities once seen
/// production — names only (a backend's type, bucket and key, a local
/// state's path) — so production stays production in every worktree and
/// under every folder name. Var files and workspaces chosen per checkout
/// join with the plan (stage 1d). One for the app.
@MainActor
final class TerraformRootStore {
    static let shared = TerraformRootStore(url: AppEnvironment.terraformRootsFile)

    private struct File: Codable {
        var productionIdentities: [TerraformStateIdentity] = []
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
        file = current
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(current) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

extension TerraformRootStore {
    func rememberProduction(_ identity: TerraformStateIdentity) { rememberProduction([identity]) }
}
