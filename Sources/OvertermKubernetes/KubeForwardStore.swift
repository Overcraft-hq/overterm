import Foundation

/// The forwards kept from one run to the next (K8S-G2): each one's spec —
/// context, namespace, target, ports, address, https — in
/// `Kubernetes/forwards.json` under the support folder, 0600. Nothing
/// secret is in a spec, nor which tab asked for it. Read at launch to list
/// them stopped; never started by this (`KubeForwards.restore`).
package enum KubeForwardStore {
    package static var file: URL { AppEnvironment.supportDirectory.appendingPathComponent("Kubernetes/forwards.json") }

    private struct Saved: Codable {
        var version = 1
        var forwards: [KubeForwardSpec]
    }

    /// What was kept; nothing for a missing or unreadable file, or one of a later version.
    package static func load(from url: URL = file) -> [KubeForwardSpec] {
        guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.version == 1 else { return [] }
        return saved.forwards
    }

    package static func save(_ specs: [KubeForwardSpec], to url: URL = file) {
        let fm = FileManager.default
        guard !specs.isEmpty else {
            try? fm.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder.sorted.encode(Saved(forwards: specs)) else { return }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension JSONEncoder {
    fileprivate static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension KubeForwardTarget: Codable {
    private enum CodingKeys: String, CodingKey { case kind, name }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let name = try values.decode(String.self, forKey: .name)
        switch try values.decode(String.self, forKey: .kind) {
        case "pod": self = .pod(name)
        case "svc": self = .service(name)
        case "deploy": self = .deployment(name)
        case let other: throw DecodingError.dataCorruptedError(forKey: .kind, in: values, debugDescription: "No forward target \(other)")
        }
    }

    package func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(word, forKey: .kind)
        try values.encode(name, forKey: .name)
    }
}

extension KubeForwardSpec: Codable {
    /// Its tab isn't kept: tomorrow's tabs are other tabs.
    private enum CodingKeys: String, CodingKey { case id, context, namespace, target, remotePort, localPort, address, https, forDatabase }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            context: try values.decode(String.self, forKey: .context), namespace: try values.decode(String.self, forKey: .namespace),
            target: try values.decode(KubeForwardTarget.self, forKey: .target), remotePort: try values.decode(Int.self, forKey: .remotePort),
            localPort: try values.decode(Int.self, forKey: .localPort))
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        address = try values.decodeIfPresent(String.self, forKey: .address) ?? KubeForwardAddress.loopback
        https = try values.decodeIfPresent(Bool.self, forKey: .https) ?? false
        forDatabase = try values.decodeIfPresent(Bool.self, forKey: .forDatabase) ?? false
    }

    package func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(context, forKey: .context)
        try values.encode(namespace, forKey: .namespace)
        try values.encode(target, forKey: .target)
        try values.encode(remotePort, forKey: .remotePort)
        try values.encode(localPort, forKey: .localPort)
        try values.encode(address, forKey: .address)
        try values.encode(https, forKey: .https)
        try values.encode(forDatabase, forKey: .forDatabase)
    }
}
