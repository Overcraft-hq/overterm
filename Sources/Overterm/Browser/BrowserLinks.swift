import Foundation

/// Which links Overterm's browser takes (Settings ▸ Browser ▸ Open links):
/// what you are building — localhost and the like — by default; the rest
/// of the web stays in your own browser, with your logins and extensions.
enum BrowserLinks {
    enum Policy: String, CaseIterable, Sendable {
        case local, all, none
    }

    /// Whether `url` opens in Overterm's browser under `policy`.
    static func opensInside(_ url: URL, policy: Policy) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        switch policy {
        case .all: return true
        case .none: return false
        case .local: return isLocal(url)
        }
    }

    /// A server on this machine or its network: what a dev server prints.
    static func isLocal(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased() else { return false }
        if host.hasPrefix("[") { host = String(host.dropFirst().dropLast()) }
        if ["localhost", "127.0.0.1", "0.0.0.0", "::1", "::"].contains(host) { return true }
        if host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".test") { return true }
        // Private IPv4: 10/8, 172.16/12, 192.168/16, and loopback 127/8.
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, host.split(separator: ".").count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// What was typed in the address bar, as a URL: a URL as it is, a
    /// host[:port][/path] with http:// (https:// for a dotted public name),
    /// anything else a search.
    static func url(fromTyped typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https", "file", "about"].contains(scheme) {
            return url
        }
        // ":3000" — a port on this machine, as Tab Info lists them.
        if text.hasPrefix(":"), Int(text.dropFirst()) != nil { return URL(string: "http://localhost\(text)") }
        let looksLikeHost = !text.contains(" ") && (text.contains(".") || text.contains(":") || text.hasPrefix("localhost"))
        if looksLikeHost, let url = URL(string: "http://" + text), url.host != nil {
            let secure = !isLocal(url) && url.port == nil
            return URL(string: (secure ? "https://" : "http://") + text)
        }
        let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        return URL(string: "https://duckduckgo.com/?q=\(query)")
    }
}
