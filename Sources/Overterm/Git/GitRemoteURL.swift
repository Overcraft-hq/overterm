import Foundation

/// A git remote's URL, as anything that shows or compares one reads it:
/// never with the credentials a URL can carry (`https://bot:ghp_…@host/…`,
/// or a token alone, `https://ghp_…@host/…`, which `Secrets.maskURL` —
/// a password after a `:` — doesn't see). Pure
/// (docs/design/kubernetes/gitops.md, 4.2 and 5.3).
enum GitRemoteURL {
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
