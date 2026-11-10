import Foundation

/// A git remote's URL, as anything that shows or compares one reads it:
/// never with the credentials a URL can carry (`https://bot:token@host/…`,
/// or a token alone, `https://ghp_…@host/…`, which `Secrets.maskURL` —
/// a password after a `:` — doesn't see). A value is the repository a URL
/// names, normalised so that every way of writing one compares equal —
/// `host` and `path` (`github.com`, `acme/shop`), whatever the scheme,
/// user, port or `.git`. Pure (docs/design/kubernetes/gitops.md, 4.2 and 5.3).
///
/// The steps, in order:
/// 1. whitespace, a trailing `/` and `.git` trimmed;
/// 2. the scp form `git@host:org/repo` is `host` + `org/repo`;
/// 3. `ssh://`, `git+ssh://`, `ssh+git://` and `git://` lose the user and
///    the port; `ssh.github.com` is `github.com`, `altssh.gitlab.com` is
///    `gitlab.com`;
/// 4. `http(s)://` always loses its whole userinfo and its port — `http`
///    is `https`;
/// 5. Azure DevOps' three forms are `dev.azure.com/o/p/r`;
/// 6. the host is lowercased; the path compares case-insensitively on
///    github.com, gitlab.com and bitbucket.org, exactly elsewhere —
///    GitLab's subgroups kept whole;
/// 7. an ssh config alias is compared as written (no `ssh -G`);
/// 8. `oci://` (and any other scheme) names no git repository: nil.
struct GitRemoteURL: Hashable, Sendable, CustomStringConvertible {
    /// Lowercased: `git.acme.example`.
    let host: String
    /// `acme/shop`, `acme/group/sub/shop`, as written.
    let path: String

    /// `git.acme.example/acme/shop`: what is shown, credentials never among it.
    var description: String { "\(host)/\(path)" }

    /// The hosts whose paths are case-insensitive.
    static let caseInsensitiveHosts: Set<String> = ["github.com", "gitlab.com", "bitbucket.org"]

    /// What two URLs compare by.
    var key: String { "\(host)/\(Self.caseInsensitiveHosts.contains(host) ? path.lowercased() : path)" }

    static func == (lhs: GitRemoteURL, rhs: GitRemoteURL) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }

    init(host: String, path: String) {
        self.host = host.lowercased()
        self.path = path
    }

    /// The repository `raw` names; nil for what names none (`oci://`, a
    /// local path, an empty one).
    init?(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\u{0}") else { return nil }
        var host: String
        var path: String
        if let separator = text.range(of: "://") {
            let scheme = text[..<separator.lowerBound].lowercased()
            guard ["https", "http", "ssh", "git+ssh", "ssh+git", "git"].contains(scheme) else { return nil }
            let rest = text[separator.upperBound...]
            let authority = rest.prefix { !"/?#".contains($0) }
            var tail = rest.dropFirst(authority.count)
            if let end = tail.firstIndex(where: { "?#".contains($0) }) { tail = tail[..<end] }
            // The whole userinfo, up to the authority's last `@`: a token
            // may have no `:`.
            var hostPort = authority.lastIndex(of: "@").map { authority[authority.index(after: $0)...] } ?? authority
            // ssh and git lose any port; http(s) its default ones.
            if hostPort.hasPrefix("["), let close = hostPort.firstIndex(of: "]") {
                hostPort = hostPort[...close]
            } else if let colon = hostPort.lastIndex(of: ":") {
                let port = hostPort[hostPort.index(after: colon)...]
                if !scheme.hasPrefix("http") || port == "443" || port == "80" || port.isEmpty { hostPort = hostPort[..<colon] }
            }
            host = String(hostPort)
            path = String(tail)
        } else {
            // scp: `[user@]host:path` — a `:` before any `/`.
            guard let colon = text.firstIndex(of: ":"), !text[..<colon].contains("/") else { return nil }
            let before = text[..<colon]
            host = String(before.lastIndex(of: "@").map { before[before.index(after: $0)...] } ?? before)
            path = String(text[text.index(after: colon)...])
        }
        host = host.lowercased()
        guard !host.isEmpty, !host.contains(" ") else { return nil }
        switch host {
        case "ssh.github.com": host = "github.com"
        case "altssh.gitlab.com": host = "gitlab.com"
        default: break
        }
        path = Self.trimmed(path)
        // Azure DevOps: dev.azure.com/o/p/_git/r, ssh.dev.azure.com:v3/o/p/r, o.visualstudio.com/p/_git/r.
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if host == "ssh.dev.azure.com" || host == "vs-ssh.visualstudio.com" {
            if parts.first == "v3" { parts.removeFirst() }
            host = "dev.azure.com"
        } else if host == "dev.azure.com" {
            parts.removeAll { $0 == "_git" }
        } else if host.hasSuffix(".visualstudio.com") {
            let organisation = String(host.dropLast(".visualstudio.com".count))
            parts.removeAll { $0 == "_git" }
            if parts.first == "DefaultCollection" { parts.removeFirst() }
            parts.insert(organisation, at: 0)
            host = "dev.azure.com"
        }
        path = parts.joined(separator: "/")
        guard !path.isEmpty else { return nil }
        self.host = host
        self.path = path
    }

    /// `/acme/shop.git/` is `acme/shop`; `~user` stays.
    private static func trimmed(_ path: String) -> String {
        var path = path
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix(".git") { path.removeLast(4) }
        while path.hasSuffix("/") { path.removeLast() }
        while path.hasPrefix("/") { path.removeFirst() }
        return path
    }

    /// `url` without its whole userinfo: `https://user:token@host/x` is
    /// `https://host/x`, whatever the scheme. A userinfo holds no `/`, `?`
    /// or `#` (RFC 3986), so the authority ends at the first of them, and
    /// it is cut at its last `@` — a password with an `@` written raw goes
    /// too. The scp form (`git@host:org/repo`) names a user, never a
    /// secret, and stays as written; so does anything without `://`.
    static func withoutUserinfo(_ url: String) -> String {
        guard let separator = url.range(of: "://"), isScheme(url[..<separator.lowerBound]) else { return url }
        let rest = url[separator.upperBound...]
        let authority = rest.prefix { !"/?#".contains($0) }
        guard let at = authority.lastIndex(of: "@") else { return url }
        return String(url[..<separator.upperBound]) + String(rest[rest.index(after: at)...])
    }

    /// Every `scheme://userinfo@` in `text` without its userinfo, all of
    /// it: a message can name several URLs, and a token may have no `:`.
    /// A later `@` in a path (`…/users/jane@example.com`) stays.
    static func stripUserinfo(inText text: String) -> String {
        guard text.contains("://"), text.contains("@") else { return text }
        return text.replacingOccurrences(of: #"([A-Za-z][A-Za-z0-9+.-]*://)[^/?#\s]*@"#, with: "$1", options: .regularExpression)
    }

    /// RFC 3986's: a letter, then letters, digits, `+`, `-` and `.`.
    private static func isScheme(_ text: Substring) -> Bool {
        guard let first = text.first, first.isASCII, first.isLetter else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }
    }
}
