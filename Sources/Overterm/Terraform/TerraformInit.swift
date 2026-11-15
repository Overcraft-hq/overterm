import Foundation

/// What `init` would fetch, read statically before the person's click
/// (analysis 4.13, 5.9): each provider's source and whether the lock file
/// pins it, each module's source and version — flagging what isn't a
/// registry source with an exact version (a branch ref, a bare git URL,
/// an `http://` source) and a provider the lock file doesn't list. The
/// lock file pins providers only; a `?ref=main` module changes under the
/// same lock file. Pure.
enum TerraformInitPlan {
    struct Item: Equatable, Sendable, Identifiable {
        enum Kind: String, Sendable { case provider, module }
        var kind: Kind
        var name: String
        var source: String
        var version: String?
        /// Why it is worth a look, or nil.
        var flag: String?
        var id: String { kind.rawValue + "." + name + "." + source }
    }

    static func items(config: TerraformConfigFacts, lockProviders: [TerraformLockFile.Provider]?) -> [Item] {
        var items: [Item] = []
        let locked = Set((lockProviders ?? []).map { "\($0.namespace)/\($0.type)" })
        let lockedTypes = Set((lockProviders ?? []).map(\.type))
        for (name, source) in config.requiredProviders.sorted(by: { $0.key < $1.key }) {
            let parts = source.lowercased().split(separator: "/").map(String.init)
            let short = parts.suffix(2).joined(separator: "/")
            let pinned = locked.contains(short) || (parts.count == 1 && lockedTypes.contains(parts[0]))
            items.append(
                Item(
                    kind: .provider, name: name, source: source,
                    flag: pinned ? nil : "not in .terraform.lock.hcl: init with -lockfile=readonly refuses it — run terraform init in a terminal, then review the lock file"))
        }
        for source in Set(config.moduleSources).sorted() where !TerraformRunRisks.isLocal(source) {
            let version = config.moduleVersions[source]
            items.append(Item(kind: .module, name: moduleName(source), source: source, version: version, flag: moduleFlag(source, version: version)))
        }
        return items
    }

    static func moduleName(_ source: String) -> String {
        let trimmed = source.split(separator: "?").first.map(String.init) ?? source
        return trimmed.split(separator: "/").last.map(String.init) ?? source
    }

    /// Why a module source is worth a look, or nil for a registry module
    /// at an exact version.
    static func moduleFlag(_ source: String, version: String?) -> String? {
        let lower = source.lowercased()
        if lower.hasPrefix("http://") || lower.contains("::http://") { return "fetched over plain HTTP" }
        if let ref = lower.range(of: "?ref=").map({ String(lower[$0.upperBound...]) }) {
            let value = ref.split(separator: "&").first.map(String.init) ?? ref
            let isTag = value.range(of: #"^v?\d+(\.\d+)*$"#, options: .regularExpression) != nil
            let isCommit = value.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
            if !isTag && !isCommit { return "a branch ref (\(value)): it changes under the same lock file" }
            return nil
        }
        if lower.hasPrefix("git::") || lower.hasPrefix("git@") || lower.hasPrefix("github.com/") || lower.hasPrefix("bitbucket.org/")
            || lower.hasPrefix("hg::") || lower.hasPrefix("s3::") || lower.hasPrefix("gcs::") || lower.hasPrefix("https://")
        {
            return "not a registry source, and no ref: whatever is there when init runs"
        }
        guard isRegistry(source) else { return "not a registry source" }
        guard let version else { return "no version: the newest is fetched" }
        let exact = version.range(of: #"^=?\s*v?\d+\.\d+\.\d+[^\s,~><]*$"#, options: .regularExpression) != nil
        return exact ? nil : "version \(version) isn't exact"
    }

    /// `namespace/name/provider`, or with a host in front.
    static func isRegistry(_ source: String) -> Bool {
        let parts = source.split(separator: "/")
        guard (3...4).contains(parts.count), !source.contains("::"), !source.contains(":") || parts.count == 4 else { return false }
        return parts.allSatisfy { !$0.isEmpty && !$0.contains("?") }
    }

    /// Whether the plugin cache is offered at this Init (4.13, D-17): the
    /// person never answered, two worktrees of this repository have
    /// Terraform roots, and the user configures no CLI of their own.
    static func offersCache(answered: Bool, worktreesWithRoots: Int, userConfiguresCLI: Bool) -> Bool {
        !answered && worktreesWithRoots >= 2 && !userConfiguresCLI
    }
}
