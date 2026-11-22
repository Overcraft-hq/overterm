import CommonCrypto
import CryptoKit
import Foundation

/// A `mongodb://` or `mongodb+srv://` connection string, as pasted into
/// the form — pure. Hosts as written (a replica set's several), the user
/// and password percent-decoded, the database from the path, and the
/// options the form keeps: authSource, TLS and its CA bundle.
package struct MongoURL: Equatable {
    package var srv = false
    /// `host` or `host:port`, IPv6 in brackets.
    package var hosts: [String] = []
    package var user = ""
    package var password: String?
    package var database = ""
    /// Lowercased names, as the spec compares them.
    package var options: [String: String] = [:]

    package init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let rest: Substring
        if lower.hasPrefix("mongodb+srv://") {
            srv = true
            rest = text.dropFirst("mongodb+srv://".count)
        } else if lower.hasPrefix("mongodb://") {
            rest = text.dropFirst("mongodb://".count)
        } else {
            return nil
        }
        // Userinfo ends at the last @ before the path: a password may hold one, encoded or not.
        let pathStart = rest.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? rest.endIndex
        var authority = rest[..<pathStart]
        if let at = authority.lastIndex(of: "@") {
            let info = authority[..<at]
            authority = authority[authority.index(after: at)...]
            if let colon = info.firstIndex(of: ":") {
                user = String(info[..<colon]).removingPercentEncoding ?? String(info[..<colon])
                let secret = String(info[info.index(after: colon)...])
                password = secret.removingPercentEncoding ?? secret
            } else {
                user = String(info).removingPercentEncoding ?? String(info)
            }
        }
        hosts = authority.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !hosts.isEmpty else { return nil }
        // An srv URL names one host and no port.
        if srv, hosts.count != 1 || Self.split(hosts[0]).port != nil { return nil }
        var tail = rest[pathStart...]
        if tail.first == "/" {
            tail = tail.dropFirst()
            let end = tail.firstIndex(of: "?") ?? tail.endIndex
            database = String(tail[..<end]).removingPercentEncoding ?? String(tail[..<end])
            tail = tail[end...]
        }
        if tail.first == "?" {
            for pair in tail.dropFirst().split(whereSeparator: { $0 == "&" || $0 == ";" }) {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard let name = parts.first?.lowercased(), !name.isEmpty else { continue }
                let value = parts.count > 1 ? parts[1] : ""
                options[name] = value.removingPercentEncoding ?? value
            }
        }
    }

    /// TLS as the string says it: `tls` or `ssl`; on for srv unless said off.
    package var tls: Bool {
        if let value = options["tls"] ?? options["ssl"] { return value.lowercased() == "true" }
        return srv
    }

    /// Asked not to check the certificate.
    package var insecure: Bool {
        ["tlsinsecure", "tlsallowinvalidcertificates", "sslallowinvalidcertificates", "tlsallowinvalidhostnames"].contains {
            options[$0]?.lowercased() == "true"
        }
    }

    /// The spec's rule: authSource, else the path's database, else admin.
    package var authSource: String { options["authsource"] ?? (database.isEmpty ? "" : database) }
    package var caFile: String { options["tlscafile"] ?? options["sslca"] ?? "" }

    /// `host`, `host:port`, `[::1]:port` → its parts.
    package static func split(_ hostPort: String) -> (host: String, port: Int?) {
        if hostPort.hasPrefix("["), let close = hostPort.firstIndex(of: "]") {
            let host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
            let after = hostPort[hostPort.index(after: close)...]
            return (host, after.hasPrefix(":") ? Int(after.dropFirst()) : nil)
        }
        let parts = hostPort.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let port = Int(parts[1]) { return (String(parts[0]), port) }
        return (hostPort, nil)
    }
}

/// SCRAM as MongoDB signs in with it (RFC 5802, RFC 7677) — pure, so the
/// RFCs' own examples test it. SHA-1's password is MongoDB's digest of
/// `user:mongo:password`; SHA-256's the password itself, SASLprepped.
package struct MongoSCRAM {
    package enum Mechanism: String, Sendable {
        case sha1 = "SCRAM-SHA-1"
        case sha256 = "SCRAM-SHA-256"
    }

    package struct Failure: LocalizedError {
        package let message: String
        package var errorDescription: String? { message }
    }

    package let mechanism: Mechanism
    package let user: String
    /// What PBKDF2 is given: the digest (SHA-1) or the prepared password.
    package let secret: String
    package let clientNonce: String

    package init(mechanism: Mechanism, user: String, password: String, nonce: String? = nil) {
        self.mechanism = mechanism
        self.user = user
        switch mechanism {
        case .sha1:
            let digest = Insecure.MD5.hash(data: Data("\(user):mongo:\(password)".utf8))
            secret = digest.map { String(format: "%02x", $0) }.joined()
        case .sha256:
            secret = Self.saslPrep(password)
        }
        clientNonce = nonce ?? Data((0..<24).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    }

    /// For the RFCs' examples: the password as given, no MongoDB digest.
    package init(mechanism: Mechanism, user: String, rawSecret: String, nonce: String) {
        self.mechanism = mechanism
        self.user = user
        secret = rawSecret
        clientNonce = nonce
    }

    private var escapedUser: String { user.replacingOccurrences(of: "=", with: "=3D").replacingOccurrences(of: ",", with: "=2C") }
    package var clientFirstBare: String { "n=\(escapedUser),r=\(clientNonce)" }
    package var clientFirst: String { "n,," + clientFirstBare }

    /// The proof for the server's challenge, and the signature the
    /// server must answer with.
    package func clientFinal(serverFirst: String) throws -> (message: String, serverSignature: Data) {
        var fields: [Character: String] = [:]
        for part in serverFirst.split(separator: ",") where part.count >= 2 && part.dropFirst().first == "=" {
            fields[part.first!] = String(part.dropFirst(2))
        }
        guard let nonce = fields["r"], nonce.hasPrefix(clientNonce), let saltText = fields["s"], let salt = Data(base64Encoded: saltText),
            let iterations = fields["i"].flatMap(Int.init), iterations > 0
        else { throw Failure(message: "The server's SCRAM challenge didn't read: \(serverFirst)") }
        // A server asking for too few rounds is a downgrade.
        guard iterations >= 4096 else { throw Failure(message: "The server asked for \(iterations) SCRAM iterations — fewer than 4096 is refused.") }
        let salted = pbkdf2(Data(secret.utf8), salt: salt, rounds: iterations)
        let clientKey = hmac(salted, Data("Client Key".utf8))
        let storedKey = hash(clientKey)
        let withoutProof = "c=biws,r=\(nonce)"
        let authMessage = Data("\(clientFirstBare),\(serverFirst),\(withoutProof)".utf8)
        let signature = hmac(storedKey, authMessage)
        let proof = Data(zip(clientKey, signature).map { $0 ^ $1 })
        let serverKey = hmac(salted, Data("Server Key".utf8))
        return ("\(withoutProof),p=\(proof.base64EncodedString())", hmac(serverKey, authMessage))
    }

    /// The server's last word: its signature, or why it refused.
    package static func verify(serverFinal: String, expected: Data) throws {
        if serverFinal.hasPrefix("e=") { throw Failure(message: "The server refused: \(serverFinal.dropFirst(2))") }
        guard serverFinal.hasPrefix("v="), let signature = Data(base64Encoded: String(serverFinal.dropFirst(2).prefix { $0 != "," })),
            signature == expected
        else { throw Failure(message: "The server's SCRAM signature is wrong — it isn't the server it says it is.") }
    }

    private func hmac(_ key: Data, _ data: Data) -> Data {
        switch mechanism {
        case .sha1: Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: key)))
        case .sha256: Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
        }
    }

    private func hash(_ data: Data) -> Data {
        switch mechanism {
        case .sha1: Data(Insecure.SHA1.hash(data: data))
        case .sha256: Data(SHA256.hash(data: data))
        }
    }

    private func pbkdf2(_ password: Data, salt: Data, rounds: Int) -> Data {
        let length = mechanism == .sha1 ? 20 : 32
        var out = [UInt8](repeating: 0, count: length)
        let prf = mechanism == .sha1 ? CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1) : CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
        _ = password.withUnsafeBytes { p in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                    s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count, prf, UInt32(rounds), &out, length)
            }
        }
        return Data(out)
    }

    /// SASLprep (RFC 4013), as far as a password needs it: non-ASCII
    /// spaces as a space, what maps to nothing dropped, then NFKC.
    package static func saslPrep(_ password: String) -> String {
        guard !password.allSatisfy(\.isASCII) else { return password }
        var scalars = String.UnicodeScalarView()
        for scalar in password.unicodeScalars {
            if [0x00AD, 0x034F, 0x1806, 0x180B, 0x180C, 0x180D, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF].contains(scalar.value)
                || (0xFE00...0xFE0F).contains(scalar.value)
            {
                continue
            }
            if scalar.properties.generalCategory == .spaceSeparator {
                scalars.append(" ")
                continue
            }
            scalars.append(scalar)
        }
        return String(scalars).precomposedStringWithCompatibilityMapping
    }
}
