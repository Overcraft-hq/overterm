import Foundation

/// An X.509 certificate as a TLS Secret's `tls.crt` holds it (PEM, the
/// leaf first, then the chain): who it is for, who signed it, the names
/// it covers and when it is good — what cert-manager's and Freelens's
/// certificate panels say. Read with a DER reader of its own, from the
/// `CERTIFICATE` blocks only: a key that found its way into `tls.crt` is
/// never decoded, and `tls.key` is never handed here at all. Pure.
struct KubeCertificate: Equatable, Sendable {
    /// `C=US, O=Acme, CN=web.acme.example`, in the certificate's order.
    var subject: String
    var commonName: String?
    var issuer: String
    /// `DNS:web.acme.example`, `IP:10.0.0.12`, `email:…`, `URI:…`.
    var alternativeNames: [String]
    var notBefore: Date
    var notAfter: Date
    var isCA = false

    var isSelfSigned: Bool { subject == issuer }

    /// How it stands at a time: soon is within 30 days, as cert-manager
    /// renews a 90-day certificate (two thirds through).
    enum Validity: Equatable, Sendable {
        case valid
        case expiringSoon(days: Int)
        case expired
        case notYetValid
    }

    static let soon: TimeInterval = 30 * 86_400

    func validity(at now: Date = Date()) -> Validity {
        if now < notBefore { return .notYetValid }
        if now >= notAfter { return .expired }
        let left = notAfter.timeIntervalSince(now)
        return left <= Self.soon ? .expiringSoon(days: Int(left / 86_400)) : .valid
    }

    /// Every certificate in a PEM text, in order; blocks of any other kind
    /// (a private key, parameters) are passed over unread.
    static func certificates(inPEM text: String) -> [KubeCertificate] {
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        var out: [KubeCertificate] = []
        var rest = text[...]
        while let start = rest.range(of: begin), let stop = rest.range(of: end, range: start.upperBound..<rest.endIndex) {
            let body = rest[start.upperBound..<stop.lowerBound]
            if let der = Data(base64Encoded: String(body), options: .ignoreUnknownCharacters), let certificate = parse(der: der) {
                out.append(certificate)
            }
            rest = rest[stop.upperBound...]
        }
        return out
    }

    /// One DER certificate; nil when it isn't one.
    static func parse(der: Data) -> KubeCertificate? {
        let bytes = [UInt8](der)[...]
        guard let (outer, _) = DER.node(bytes), outer.tag == 0x30, let parts = DER.children(outer.content),
            let tbs = parts.first, tbs.tag == 0x30, var fields = DER.children(tbs.content)
        else { return nil }
        // version [0] is optional (v1 has none).
        if fields.first?.tag == 0xA0 { fields.removeFirst() }
        // serial, signature algorithm, issuer, validity, subject, key.
        guard fields.count >= 6, fields[0].tag == 0x02, fields[2].tag == 0x30, fields[3].tag == 0x30, fields[4].tag == 0x30,
            let validity = DER.children(fields[3].content), validity.count == 2,
            let notBefore = time(validity[0]), let notAfter = time(validity[1])
        else { return nil }
        let issuer = name(fields[2])
        let subject = name(fields[4])
        var certificate = KubeCertificate(
            subject: subject.text, commonName: subject.commonName, issuer: issuer.text, alternativeNames: [], notBefore: notBefore, notAfter: notAfter)
        // Extensions: [3], after the key and the optional unique ids.
        if let extensions = fields.dropFirst(6).first(where: { $0.tag == 0xA3 }), let list = DER.children(extensions.content).flatMap(\.first),
            list.tag == 0x30, let entries = DER.children(list.content)
        {
            for entry in entries {
                guard let items = DER.children(entry.content), let id = items.first, id.tag == 0x06, let value = items.last, value.tag == 0x04 else {
                    continue
                }
                switch DER.oid(id.content) {
                case "2.5.29.17": certificate.alternativeNames = alternativeNames(value.content)
                case "2.5.29.19":
                    // BasicConstraints: SEQUENCE { cA BOOLEAN DEFAULT FALSE, … }
                    if let (sequence, _) = DER.node(value.content), let inner = DER.children(sequence.content), let flag = inner.first, flag.tag == 0x01 {
                        certificate.isCA = flag.content.first.map { $0 != 0 } ?? false
                    }
                default: break
                }
            }
        }
        return certificate
    }

    // MARK: Reading

    private static let attributeNames: [String: String] = [
        "2.5.4.3": "CN", "2.5.4.6": "C", "2.5.4.7": "L", "2.5.4.8": "ST", "2.5.4.10": "O", "2.5.4.11": "OU", "2.5.4.5": "serialNumber",
        "1.2.840.113549.1.9.1": "emailAddress", "0.9.2342.19200300.100.1.25": "DC",
    ]

    /// A Name: SEQUENCE of SET of SEQUENCE { OID, string }.
    private static func name(_ node: DER.Node) -> (text: String, commonName: String?) {
        var parts: [String] = []
        var commonName: String?
        for set in DER.children(node.content) ?? [] where set.tag == 0x31 {
            for pair in DER.children(set.content) ?? [] {
                guard let items = DER.children(pair.content), items.count == 2, items[0].tag == 0x06 else { continue }
                let oid = DER.oid(items[0].content)
                let value = DER.string(items[1]) ?? ""
                if oid == "2.5.4.3", commonName == nil { commonName = value }
                parts.append("\(attributeNames[oid] ?? oid)=\(value)")
            }
        }
        return (parts.joined(separator: ", "), commonName)
    }

    /// UTCTime (`YYMMDDHHMMSSZ`, 50 and on the 1900s) or GeneralizedTime
    /// (`YYYYMMDDHHMMSS[.fff]Z`).
    private static func time(_ node: DER.Node) -> Date? {
        guard node.tag == 0x17 || node.tag == 0x18 else { return nil }
        var text = String(decoding: node.content, as: UTF8.self)
        guard text.hasSuffix("Z") else { return nil }
        text.removeLast()
        if let dot = text.firstIndex(of: ".") { text = String(text[..<dot]) }
        if node.tag == 0x17 {
            guard text.count == 12 || text.count == 10, let year = Int(text.prefix(2)) else { return nil }
            text = (year < 50 ? "20" : "19") + text
        }
        if text.count == 12 { text += "00" }
        guard text.count == 14, text.allSatisfy(\.isNumber) else { return nil }
        let digits = Array(text)
        func number(_ range: Range<Int>) -> Int { Int(String(digits[range])) ?? 0 }
        var components = DateComponents()
        components.year = number(0..<4)
        components.month = number(4..<6)
        components.day = number(6..<8)
        components.hour = number(8..<10)
        components.minute = number(10..<12)
        components.second = number(12..<14)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)
    }

    /// GeneralNames: the kinds a TLS certificate carries.
    private static func alternativeNames(_ content: ArraySlice<UInt8>) -> [String] {
        guard let (sequence, _) = DER.node(content), sequence.tag == 0x30, let names = DER.children(sequence.content) else { return [] }
        return names.compactMap { name in
            switch name.tag {
            case 0x82: "DNS:" + String(decoding: name.content, as: UTF8.self)
            case 0x81: "email:" + String(decoding: name.content, as: UTF8.self)
            case 0x86: "URI:" + String(decoding: name.content, as: UTF8.self)
            case 0x87: "IP:" + address(Array(name.content))
            default: nil
            }
        }
    }

    private static func address(_ bytes: [UInt8]) -> String {
        if bytes.count == 4 { return bytes.map(String.init).joined(separator: ".") }
        guard bytes.count == 16 else { return bytes.map { String(format: "%02x", $0) }.joined() }
        return stride(from: 0, to: 16, by: 2).map { String(format: "%x", Int(bytes[$0]) << 8 | Int(bytes[$0 + 1])) }.joined(separator: ":")
    }
}

/// Just enough of DER to read a certificate: single-byte tags, definite
/// lengths. Every read is bounded by the bytes it was given. Pure.
enum DER {
    struct Node {
        var tag: UInt8
        var content: ArraySlice<UInt8>
    }

    /// The first node, and what follows it.
    static func node(_ bytes: ArraySlice<UInt8>) -> (Node, rest: ArraySlice<UInt8>)? {
        var index = bytes.startIndex
        guard index < bytes.endIndex else { return nil }
        let tag = bytes[index]
        guard tag & 0x1F != 0x1F else { return nil }
        index += 1
        guard index < bytes.endIndex else { return nil }
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...4).contains(count), bytes.endIndex - index >= count else { return nil }
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(bytes[index])
                index += 1
            }
        }
        guard length >= 0, bytes.endIndex - index >= length else { return nil }
        return (Node(tag: tag, content: bytes[index..<index + length]), bytes[(index + length)...])
    }

    /// A constructed node's children; nil when they don't add up.
    static func children(_ content: ArraySlice<UInt8>) -> [Node]? {
        var out: [Node] = []
        var rest = content
        while !rest.isEmpty {
            guard let (node, next) = node(rest) else { return nil }
            out.append(node)
            rest = next
        }
        return out
    }

    static func oid(_ content: ArraySlice<UInt8>) -> String {
        guard let first = content.first else { return "" }
        var parts = [Int(first) / 40, Int(first) % 40]
        var value = 0
        for byte in content.dropFirst() {
            value = value << 7 | Int(byte & 0x7F)
            if byte & 0x80 == 0 {
                parts.append(value)
                value = 0
            }
        }
        return parts.map(String.init).joined(separator: ".")
    }

    /// A directory string: UTF8, Printable, IA5, Teletex (as Latin-1), BMP.
    static func string(_ node: Node) -> String? {
        switch node.tag {
        case 0x0C, 0x13, 0x16, 0x12, 0x1A: return String(decoding: node.content, as: UTF8.self)
        case 0x14: return String(bytes: node.content, encoding: .isoLatin1)
        case 0x1E: return String(bytes: node.content, encoding: .utf16BigEndian)
        default: return nil
        }
    }
}
