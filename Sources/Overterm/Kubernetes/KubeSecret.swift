import Foundation

/// One key of a Secret Show read: its name and how long its value is,
/// never the value — that stays in the session (`KubeSecretSession`).
struct KubeSecretEntry: Equatable, Sendable, Identifiable {
    var key: String
    /// The value's length in bytes, decoded.
    var length: Int
    /// A TLS Secret's `tls.key`: never decoded, revealed or copied.
    var isPrivateKey = false
    /// Not text (or not valid base64): revealed as base64.
    var isBinary = false

    var id: String { key }

    /// What a masked value says: its length, never its content.
    var masked: String {
        if isPrivateKey { return "private key · never shown" }
        return "•••••••• · \(length) byte\(length == 1 ? "" : "s")" + (isBinary ? ", binary" : "")
    }
}

/// A Secret as Show's one GET answered it (docs/design/kubernetes/
/// analysis.md, rule 9), taken apart at once: the object without its
/// values — what the Overview and the YAML show — the keys with their
/// lengths, and the values, decoded, for the session alone. A TLS
/// Secret's `tls.key` is counted from its base64 and never decoded. Pure.
struct KubeSecretRead: Sendable {
    /// The object as JSON, `data` and `stringData` each value `***`, the
    /// last-applied annotation (which can hold every value) gone.
    var stripped: Data
    var type: String
    /// By key.
    var entries: [KubeSecretEntry]
    /// Decoded, by key; no private key's.
    var values: [String: Data]
}

extension KubeSecretRead: CustomStringConvertible {
    /// Never a value: a read printed (a check's detail, a log) says only
    /// what it holds.
    var description: String { "Secret (\(type)): \(entries.map(\.key).joined(separator: ", "))" }
}

enum KubeSecret {
    static let tlsType = "kubernetes.io/tls"

    /// An answer that isn't a Secret. Never says what came: that could be
    /// any of its values.
    struct Unreadable: Error, Equatable, LocalizedError {
        var errorDescription: String? { "The server's answer isn't a Secret." }
    }

    static func isPrivateKey(_ key: String, type: String) -> Bool { type == tlsType && key == "tls.key" }

    static func read(_ body: Data) throws -> KubeSecretRead {
        guard var object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], KubeObjectStrip.isSecret(object),
            (object["metadata"] as? [String: Any])?["name"] is String
        else { throw Unreadable() }
        let type = object["type"] as? String ?? "Opaque"
        var entries: [String: KubeSecretEntry] = [:]
        var values: [String: Data] = [:]
        for (key, raw) in object["data"] as? [String: Any] ?? [:] {
            let text = raw as? String ?? ""
            if isPrivateKey(key, type: type) {
                entries[key] = KubeSecretEntry(key: key, length: decodedLength(ofBase64: text), isPrivateKey: true, isBinary: true)
                continue
            }
            guard let value = Data(base64Encoded: text) else {
                entries[key] = KubeSecretEntry(key: key, length: decodedLength(ofBase64: text), isBinary: true)
                continue
            }
            values[key] = value
            entries[key] = KubeSecretEntry(key: key, length: value.count, isBinary: !isText(value))
        }
        // Written, never read back by a server — but masked all the same.
        for (key, raw) in object["stringData"] as? [String: Any] ?? [:] where entries[key] == nil {
            let value = Data((raw as? String ?? "").utf8)
            if isPrivateKey(key, type: type) {
                entries[key] = KubeSecretEntry(key: key, length: value.count, isPrivateKey: true, isBinary: true)
            } else {
                values[key] = value
                entries[key] = KubeSecretEntry(key: key, length: value.count, isBinary: !isText(value))
            }
        }
        for key in ["data", "stringData"] {
            if let map = object[key] as? [String: Any] { object[key] = map.mapValues { _ in KubeObjectStrip.mask } }
        }
        if var metadata = object["metadata"] as? [String: Any] {
            if var annotations = metadata["annotations"] as? [String: Any] {
                annotations[KubeObjectStrip.lastApplied] = nil
                metadata["annotations"] = annotations.isEmpty ? nil : annotations
            }
            object["metadata"] = metadata
        }
        guard let stripped = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { throw Unreadable() }
        return KubeSecretRead(
            stripped: stripped, type: type, entries: entries.values.sorted { $0.key < $1.key }, values: values)
    }

    /// How many bytes a base64 text decodes to, without decoding it.
    static func decodedLength(ofBase64 text: String) -> Int {
        let characters = text.utf8.filter { $0 != 0x0A && $0 != 0x0D && $0 != 0x20 }
        guard !characters.isEmpty else { return 0 }
        let padding = characters.reversed().prefix { $0 == UInt8(ascii: "=") }.count
        return max(0, characters.count * 3 / 4 - padding)
    }

    /// Valid UTF-8 without control characters but newlines and tabs —
    /// checked without making a String of the value.
    static func isText(_ data: Data) -> Bool {
        var iterator = data.makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                if scalar.value < 0x20, scalar != "\n", scalar != "\r", scalar != "\t" { return false }
                if scalar.value == 0x7F { return false }
            case .emptyInput: return true
            case .error: return false
            }
        }
    }
}

/// Which production contexts have been asked about Show this session:
/// the first Show on each asks, naming the context (decision 21); the
/// answer is kept in memory until the app quits, never written. The
/// app's, as `KubernetesModel` is.
@MainActor
final class KubeSecretConsent {
    private var granted: Set<String> = []

    func needsAsking(_ context: String, production: Bool) -> Bool { production && !granted.contains(context) }
    func grant(_ context: String) { granted.insert(context) }
    func forget() { granted = [] }
}
