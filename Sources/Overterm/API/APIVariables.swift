import Foundation
import Security

/// The variables a request sees, layered as Bruno layers them — runtime
/// over request over folder over environment over collection — and
/// `{{name}}` put in their place.
struct APIVariables: Equatable, Sendable {
    /// collection.bru's `vars:pre-request`.
    var collection: [String: String] = [:]
    /// The chosen environment's `vars`, its secrets filled in.
    var environment: [String: String] = [:]
    /// Each folder's `vars:pre-request`, outermost first.
    var folders: [[String: String]] = []
    /// The request's own `vars:pre-request`.
    var request: [String: String] = [:]
    /// What scripts set (`bru.setVar`) and `vars:post-response` captured,
    /// kept for the collection while the app runs.
    var runtime: [String: String] = [:]
    /// `{{process.env.NAME}}`: the collection's `.env` over the app's own.
    var processEnv: [String: String] = [:]

    /// One map, the higher layers winning.
    var merged: [String: String] {
        var all = collection
        all.merge(environment) { $1 }
        for folder in folders { all.merge(folder) { $1 } }
        all.merge(request) { $1 }
        all.merge(runtime) { $1 }
        return all
    }

    /// `text` with each `{{name}}` it knows replaced — values that hold
    /// variables of their own are resolved too, a few levels deep. An
    /// unknown name is left as written, so it shows up in what was sent.
    func interpolate(_ text: String) -> String {
        guard text.contains("{{") else { return text }
        let values = merged
        var result = text
        for _ in 0..<5 {
            let next = Self.replace(in: result) { name in
                if name.hasPrefix("process.env.") { return processEnv[String(name.dropFirst(12))] }
                if name.hasPrefix("$") { return Self.dynamic(String(name.dropFirst())) }
                return values[name]
            }
            if next == result { break }
            result = next
        }
        return result
    }

    /// The names `text` uses that no layer defines.
    func unresolved(in text: String) -> [String] {
        var missing: [String] = []
        _ = Self.replace(in: interpolate(text)) { name in
            if !name.hasPrefix("$"), !missing.contains(name) { missing.append(name) }
            return nil
        }
        return missing
    }

    private static func replace(in text: String, _ value: (String) -> String?) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                out += rest[open.lowerBound...]
                return out
            }
            let name = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            out += value(name) ?? String(rest[open.lowerBound..<close.upperBound])
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    /// Bruno's `{{$…}}`: a fresh value each time it is sent.
    static func dynamic(_ name: String) -> String? {
        switch name {
        case "guid", "randomUUID": return UUID().uuidString.lowercased()
        case "timestamp": return String(Int(Date().timeIntervalSince1970))
        case "isoTimestamp": return ISO8601DateFormatter().string(from: Date())
        case "randomInt": return String(Int.random(in: 0...1000))
        case "randomBoolean": return Bool.random() ? "true" : "false"
        case "randomFirstName": return ["Ada", "Alan", "Grace", "Linus", "Margaret", "Ken"].randomElement()
        case "randomLastName": return ["Lovelace", "Turing", "Hopper", "Torvalds", "Hamilton", "Thompson"].randomElement()
        case "randomEmail": return "user\(Int.random(in: 1000...9999))@example.com"
        case "randomWord": return ["alpha", "bravo", "charlie", "delta", "echo"].randomElement()
        default: return nil
        }
    }

    /// The enabled pairs as a map, later ones winning; `@name` (Bruno's
    /// request-local marker) answers to `name`.
    static func map(_ pairs: [BruPair]) -> [String: String] {
        var map: [String: String] = [:]
        for pair in pairs where pair.enabled {
            map[pair.key.hasPrefix("@") ? String(pair.key.dropFirst()) : pair.key] = pair.value
        }
        return map
    }
}

/// Where an environment's secret values live: never in its file (that is
/// committed), as with Bruno, which keeps them in its own app data.
@MainActor
protocol APISecretStore: AnyObject {
    func value(collection: URL, environment: String, name: String) -> String?
    func set(_ value: String?, collection: URL, environment: String, name: String)
}

/// The login keychain, one item per collection, environment and name.
@MainActor
final class KeychainSecretStore: APISecretStore {
    static let service = "\(AppEnvironment.bundleIdentifier).api-secrets"

    private func account(_ collection: URL, _ environment: String, _ name: String) -> String {
        "\(collection.standardizedFileURL.path)|\(environment)|\(name)"
    }

    func value(collection: URL, environment: String, name: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account(collection, environment, name), kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, collection: URL, environment: String, name: String) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account(collection, environment, name),
        ]
        SecItemDelete(match as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = match
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = "Overterm API secret: \(name) (\(environment))"
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// For isolated runs and tests: nothing reaches the user's keychain.
@MainActor
final class MemorySecretStore: APISecretStore {
    private var values: [String: String] = [:]

    func value(collection: URL, environment: String, name: String) -> String? {
        values["\(collection.path)|\(environment)|\(name)"]
    }

    func set(_ value: String?, collection: URL, environment: String, name: String) {
        values["\(collection.path)|\(environment)|\(name)"] = value
    }
}

extension AppEnvironment {
    /// The keychain, or a store that forgets, for an isolated run.
    @MainActor static func makeSecretStore() -> APISecretStore {
        isIsolated ? MemorySecretStore() : KeychainSecretStore()
    }
}
