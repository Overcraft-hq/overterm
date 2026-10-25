import CryptoKit
import Foundation

/// AWS Signature Version 4, as S3 and everything that speaks it checks a
/// request: a canonical request, the string to sign, a key derived from the
/// secret by date, region and service. Pure — the request in, its headers
/// (or, presigned, its URL) out.
struct S3Signer: Sendable {
    var accessKey: String
    var secretKey: String
    var sessionToken: String?
    var region: String
    var service = "s3"

    /// The payload's hash when the body isn't hashed up front (a file streamed).
    static let unsignedPayload = "UNSIGNED-PAYLOAD"

    /// The headers that sign `request` — Authorization, x-amz-date,
    /// x-amz-content-sha256, and the token when there is one.
    func sign(method: String, url: URL, headers: [String: String], payloadHash: String, date: Date) -> [String: String] {
        let (amzDate, day) = Self.stamps(date)
        var headers = headers
        headers["host"] = Self.hostHeader(url)
        headers["x-amz-date"] = amzDate
        headers["x-amz-content-sha256"] = payloadHash
        if let sessionToken { headers["x-amz-security-token"] = sessionToken }
        let lowered = Dictionary(headers.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }, uniquingKeysWith: { $1 })
        let names = lowered.keys.sorted()
        let canonical = [
            method, Self.canonicalPath(url), Self.canonicalQuery(url),
            names.map { "\($0):\(lowered[$0]!)\n" }.joined(), names.joined(separator: ";"), payloadHash,
        ].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", amzDate, scope, Self.hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: signingKey(day)))
        var signed = headers
        signed["Authorization"] =
            "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(names.joined(separator: ";")), Signature=\(signature)"
        signed.removeValue(forKey: "host")
        return signed
    }

    /// A URL anyone can GET until it expires (at most a week).
    func presign(url: URL, expires: TimeInterval, date: Date) -> URL? {
        let (amzDate, day) = Self.stamps(date)
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "X-Amz-Algorithm", value: "AWS4-HMAC-SHA256"),
            URLQueryItem(name: "X-Amz-Credential", value: "\(accessKey)/\(scope)"),
            URLQueryItem(name: "X-Amz-Date", value: amzDate),
            URLQueryItem(name: "X-Amz-Expires", value: "\(Int(min(max(expires, 1), 604_800)))"),
            URLQueryItem(name: "X-Amz-SignedHeaders", value: "host"),
        ]
        if let sessionToken { items.append(URLQueryItem(name: "X-Amz-Security-Token", value: sessionToken)) }
        components.percentEncodedQuery = items.map { "\(Self.encode($0.name))=\(Self.encode($0.value ?? ""))" }.joined(separator: "&")
        guard let unsigned = components.url else { return nil }
        let canonical = [
            "GET", Self.canonicalPath(unsigned), Self.canonicalQuery(unsigned), "host:\(Self.hostHeader(unsigned))\n", "host",
            Self.unsignedPayload,
        ].joined(separator: "\n")
        let toSign = ["AWS4-HMAC-SHA256", amzDate, scope, Self.hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: signingKey(day)))
        components.percentEncodedQuery! += "&X-Amz-Signature=\(signature)"
        return components.url
    }

    private func signingKey(_ day: String) -> SymmetricKey {
        func hmac(_ key: SymmetricKey, _ text: String) -> SymmetricKey {
            SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key)))
        }
        var key = SymmetricKey(data: Data("AWS4\(secretKey)".utf8))
        for part in [day, region, service, "aws4_request"] { key = hmac(key, part) }
        return key
    }

    // MARK: Canonical forms

    static func stamps(_ date: Date) -> (String, String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: date)
        return (stamp, String(stamp.prefix(8)))
    }

    static func hostHeader(_ url: URL) -> String {
        let host = url.host ?? ""
        guard let port = url.port, !((url.scheme == "https" && port == 443) || (url.scheme == "http" && port == 80)) else { return host }
        return "\(host):\(port)"
    }

    /// The path as sent, each segment encoded once (S3 doesn't double-encode).
    static func canonicalPath(_ url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/"
        guard !path.isEmpty else { return "/" }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { encode($0.removingPercentEncoding ?? String($0)) }
            .joined(separator: "/")
    }

    static func canonicalQuery(_ url: URL) -> String {
        guard let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery, !query.isEmpty else { return "" }
        var pairs: [(name: String, value: String)] = []
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            let value = parts.count > 1 ? String(parts[1]) : ""
            pairs.append((encode(name.removingPercentEncoding ?? name), encode(value.removingPercentEncoding ?? value)))
        }
        pairs.sort { a, b in a.name == b.name ? a.value < b.value : a.name < b.name }
        return pairs.map { $0.name + "=" + $0.value }.joined(separator: "&")
    }

    /// RFC 3986's unreserved characters, everything else %XX.
    static func encode(_ text: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
}
