import Foundation

/// An image's name as the `docker` CLI reads it (distribution/reference):
/// `nginx` is `docker.io/library/nginx:latest`, `ghcr.io/acme/web:1.2` is
/// itself. What Check for Updates keys its answers by, so `nginx:1.27` and
/// `docker.io/library/nginx:1.27` are asked about once. Pure.
struct DockerImageReference: Hashable, Sendable {
    /// `docker.io`, `ghcr.io`, `localhost:5000`.
    var domain: String
    /// `library/nginx`, `acme/web`.
    var path: String
    /// Nil only when pinned by digest alone (`nginx@sha256:…`).
    var tag: String?
    var digest: String?

    /// Nil for what the CLI wouldn't take as a name.
    init?(_ text: String) {
        guard !text.isEmpty, text.count <= 512, !text.hasPrefix("-"), !text.contains(where: { $0.isWhitespace }) else { return nil }
        var name = Substring(text)
        if let at = name.firstIndex(of: "@") {
            let digest = String(name[name.index(after: at)...])
            guard Self.matches(digest, Self.digestPattern) else { return nil }
            self.digest = digest
            name = name[..<at]
        }
        // The tag is after the last ":" that follows the last "/": a
        // registry's port is before a "/".
        if let colon = name.lastIndex(of: ":"), !name[name.index(after: colon)...].contains("/") {
            let tag = String(name[name.index(after: colon)...])
            guard Self.matches(tag, Self.tagPattern) else { return nil }
            self.tag = tag
            name = name[..<colon]
        }
        var components = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let first = components.first, !first.isEmpty else { return nil }
        // A first part with a dot, a port, or upper case — or `localhost` —
        // names a registry, as the CLI decides.
        if components.count > 1, first.contains(".") || first.contains(":") || first == "localhost" || first.lowercased() != first {
            guard Self.matches(first, Self.domainPattern) else { return nil }
            domain = first == "index.docker.io" ? "docker.io" : first
            components.removeFirst()
        } else {
            domain = "docker.io"
        }
        guard components.allSatisfy({ Self.matches($0, Self.componentPattern) }) else { return nil }
        if domain == "docker.io", components.count == 1 { components.insert("library", at: 0) }
        path = components.joined(separator: "/")
        guard path.count <= 255 else { return nil }
        if tag == nil, digest == nil { tag = "latest" }
    }

    /// `docker.io/library/nginx`.
    var repository: String { domain + "/" + path }

    /// `docker.io/library/nginx:1.27`: what answers are kept by. Nil when
    /// pinned by digest — it can't move, so there is nothing to ask.
    var key: String? { digest == nil ? repository + ":" + (tag ?? "latest") : nil }

    /// `nginx:1.27`, `bitnami/redis:7`, `ghcr.io/acme/web:1.2`: as a person
    /// writes it, and what the CLI is given.
    var familiar: String {
        var name = repository
        if domain == "docker.io" {
            name = path
            if path.hasPrefix("library/"), !path.dropFirst("library/".count).contains("/") { name = String(path.dropFirst("library/".count)) }
        }
        return name + (tag.map { ":" + $0 } ?? "") + (digest.map { "@" + $0 } ?? "")
    }

    /// A `RepoDigests` entry (`nginx@sha256:…`): its repository and the
    /// digest the engine recorded for it. Nil for a bare digest (the
    /// containerd store with no platform match) or anything else.
    static func digested(_ repoDigest: String) -> (repository: String, digest: String)? {
        guard repoDigest.contains("@"), let reference = DockerImageReference(repoDigest), let digest = reference.digest else { return nil }
        return (reference.repository, digest)
    }

    /// `sha256:<64 hex>` and the other algorithms distribution allows.
    static func isDigest(_ text: String) -> Bool { matches(text, digestPattern) }

    private static let componentPattern = #"^[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*$"#
    private static let tagPattern = #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$"#
    private static let digestPattern = #"^[a-z0-9]+(?:[.+_-][a-z0-9]+)*:[0-9a-fA-F]{32,}$"#
    private static let domainPattern =
        #"^(?:(?:[a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9])(?:\.(?:[a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]))*|\[[a-fA-F0-9:]+\])(?::[0-9]+)?$"#

    private static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
}
