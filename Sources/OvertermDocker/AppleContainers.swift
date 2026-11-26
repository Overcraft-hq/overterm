import Foundation

/// Apple's `container` (github.com/apple/container): Linux containers in
/// light VMs on Apple silicon, macOS 26. It speaks no Engine API — its
/// service is XPC — so the Docker page reads it through its CLI's
/// `--format json`, and these are what that JSON says. Read defensively:
/// the tool is young and its output has changed shape between releases
/// (a container's `status` was a word, then an object with its networks),
/// so a field that isn't there, or is another type, is left out rather
/// than failing the list. Pure.
package enum AppleContainers {
    /// One container, as `container list --all --format json` lists it.
    package struct Container: Identifiable, Equatable, Sendable {
        package var id: String
        package var image: String
        package var state: State
        package var command: [String] = []
        /// `KEY=value`, secret-looking values masked as they are read.
        package var environment: [String] = []
        package var workingDirectory: String?
        package var ports: [Port] = []
        package var networks: [Network] = []
        package var mounts: [Mount] = []
        package var labels: [String: String] = [:]
        package var platform: String?
        package var cpus: Int?
        package var memoryBytes: UInt64?
        package var created: Date?
        package var started: Date?

        package enum State: String, Sendable {
            case running, stopped, stopping, unknown

            package var isUp: Bool { self == .running || self == .stopping }
        }

        /// The address another program reaches it at: its first network's.
        package var address: String? { networks.first?.address }
    }

    /// A published port: `-p 8080:80` is host 8080 to container 80.
    package struct Port: Equatable, Sendable {
        package var hostAddress: String
        package var hostPort: Int
        package var containerPort: Int
        package var proto: String
        /// A range's length: `-p 8000-8002:8000-8002` is three.
        package var count: Int = 1

        /// `127.0.0.1:8080→80/tcp`, a range `8000-8002→…`.
        package var label: String {
            let host = count > 1 ? "\(hostPort)-\(hostPort + count - 1)" : "\(hostPort)"
            let inside = count > 1 ? "\(containerPort)-\(containerPort + count - 1)" : "\(containerPort)"
            let address = hostAddress.isEmpty || hostAddress == "0.0.0.0" ? "" : hostAddress + ":"
            return "\(address)\(host)→\(inside)/\(proto)"
        }

        /// Where a browser reaches it on this Mac: TCP only, the host's
        /// address, a wildcard as localhost.
        package var url: URL? {
            guard proto == "tcp" else { return nil }
            let wildcard = hostAddress.isEmpty || hostAddress == "0.0.0.0" || hostAddress == "::"
            let host = wildcard ? "localhost" : hostAddress.contains(":") ? "[\(hostAddress)]" : hostAddress
            return URL(string: "http://\(host):\(hostPort)")
        }
    }

    package struct Network: Equatable, Sendable {
        package var name: String
        package var hostname: String?
        /// Its IPv4 address without the prefix length.
        package var address: String?
    }

    package struct Mount: Equatable, Sendable {
        package var source: String
        package var destination: String
    }

    /// One image, as `container image list --format json` lists it.
    package struct Image: Identifiable, Equatable, Sendable {
        /// Its digest without the algorithm, as the tool's own `id`.
        package var id: String
        /// As the tool keeps it: `docker.io/library/alpine:3.20`.
        package var reference: String
        package var digest: String?
        /// Every platform's content added up.
        package var size: Int64?
        package var platforms: [String] = []
        package var created: Date?

        /// As a person would type it: Docker Hub's prefix left out.
        package var shortName: String { AppleContainers.shortReference(reference) }
    }

    /// One volume, as `container volume list --format json` lists it.
    package struct Volume: Identifiable, Equatable, Sendable {
        package var id: String { name }
        package var name: String
        package var driver: String?
        package var format: String?
        /// Its disk image on the Mac.
        package var source: String?
        /// How large it may grow — its disk image is sparse: not what it
        /// holds now.
        package var sizeBytes: UInt64?
        package var labels: [String: String] = [:]
        package var created: Date?
    }

    /// `container system status --format json`: whether its service
    /// answers. It exits 1 when it doesn't, still saying so in JSON.
    package enum Service: Equatable, Sendable {
        /// Running, the service's version when it says.
        case running(version: String?)
        /// Installed but not started: `container system start`.
        case stopped
        /// What it said made no sense: its words.
        case unreadable(String)
    }

    /// A reference as a person would type it: `docker.io/library/nginx:alpine`
    /// is `nginx:alpine`.
    package static func shortReference(_ reference: String) -> String {
        for prefix in ["docker.io/library/", "docker.io/"] where reference.hasPrefix(prefix) { return String(reference.dropFirst(prefix.count)) }
        return reference
    }

    // MARK: Reading

    package static func containers(from data: Data) -> [Container] { array(data).compactMap(container) }
    package static func images(from data: Data) -> [Image] { array(data).compactMap(image) }
    package static func volumes(from data: Data) -> [Volume] { array(data).compactMap(volume) }

    package static func service(from data: Data) -> Service {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let status = object["status"] as? String else {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .unreadable(String(text.prefix(300)))
        }
        guard status == "running" else { return .stopped }
        return .running(version: (object["server"] as? [String: Any])?["version"] as? String)
    }

    private static func array(_ data: Data) -> [[String: Any]] {
        // Nothing at all is an empty list: the tool prints nothing for none.
        guard !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else { return [] }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    private static func container(_ object: [String: Any]) -> Container? {
        let configuration = object["configuration"] as? [String: Any] ?? [:]
        guard let id = string(object["id"]) ?? string(configuration["id"]), !id.isEmpty else { return nil }
        // 1.7: `status` an object — state, networks, startedDate. Before
        // it: a word, the networks beside it.
        let status = object["status"]
        let statusObject = status as? [String: Any]
        let stateWord = string(status) ?? string(statusObject?["state"]) ?? ""
        let image = configuration["image"] as? [String: Any]
        let process = configuration["initProcess"] as? [String: Any] ?? [:]
        let executable = string(process["executable"]).map { [$0] } ?? []
        let arguments = (process["arguments"] as? [Any])?.compactMap(string) ?? []
        let resources = configuration["resources"] as? [String: Any]
        return Container(
            id: id,
            image: string(image?["reference"]) ?? "",
            state: Container.State(rawValue: stateWord) ?? .unknown,
            command: Secrets.maskArguments(executable + arguments),
            environment: ((process["environment"] as? [Any])?.compactMap(string) ?? []).map(maskedVariable),
            workingDirectory: string(process["workingDirectory"]),
            ports: ((configuration["publishedPorts"] as? [Any]) ?? []).compactMap { port($0 as? [String: Any]) },
            networks: ((statusObject?["networks"] ?? object["networks"]) as? [Any] ?? []).compactMap { network($0 as? [String: Any]) },
            mounts: ((configuration["mounts"] as? [Any]) ?? []).compactMap { mount($0 as? [String: Any]) },
            labels: strings(configuration["labels"]),
            platform: platform(configuration["platform"]),
            cpus: int(resources?["cpus"]),
            memoryBytes: int(resources?["memoryInBytes"]).map { UInt64(max(0, $0)) },
            created: date(configuration["creationDate"]),
            started: date(statusObject?["startedDate"] ?? object["startedDate"])
        )
    }

    private static func port(_ object: [String: Any]?) -> Port? {
        guard let object, let host = int(object["hostPort"]), let inside = int(object["containerPort"]) else { return nil }
        return Port(
            hostAddress: string(object["hostAddress"]) ?? "", hostPort: host, containerPort: inside, proto: string(object["proto"]) ?? "tcp",
            count: max(1, int(object["count"]) ?? 1))
    }

    private static func network(_ object: [String: Any]?) -> Network? {
        guard let object, let name = string(object["network"]) else { return nil }
        let cidr = string(object["ipv4Address"]) ?? string(object["address"])
        return Network(name: name, hostname: string(object["hostname"]), address: cidr.map { String($0.split(separator: "/").first ?? Substring($0)) })
    }

    private static func mount(_ object: [String: Any]?) -> Mount? {
        guard let object, let destination = string(object["destination"]) else { return nil }
        return Mount(source: string(object["source"]) ?? "", destination: destination)
    }

    private static func image(_ object: [String: Any]) -> Image? {
        let configuration = object["configuration"] as? [String: Any] ?? [:]
        guard let reference = string(configuration["name"]) ?? string(configuration["reference"]) ?? string(object["reference"]), !reference.isEmpty else {
            return nil
        }
        let descriptor = (configuration["descriptor"] ?? object["descriptor"]) as? [String: Any]
        let digest = string(descriptor?["digest"])
        let variants = (object["variants"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        // An index's attestations are `unknown/unknown`: not a platform.
        let platforms = variants.compactMap { platform($0["platform"]) }.filter { $0 != "unknown/unknown" }
        let sizes = variants.compactMap { int($0["size"]) }
        return Image(
            id: string(object["id"]) ?? digest.map { String($0.split(separator: ":").last ?? Substring($0)) } ?? reference,
            reference: reference, digest: digest,
            size: sizes.isEmpty ? int(descriptor?["size"]).map(Int64.init) : Int64(sizes.reduce(0, +)),
            platforms: platforms, created: date(configuration["creationDate"]))
    }

    private static func volume(_ object: [String: Any]) -> Volume? {
        let configuration = object["configuration"] as? [String: Any] ?? object
        guard let name = string(configuration["name"]) ?? string(object["id"]), !name.isEmpty else { return nil }
        return Volume(
            name: name, driver: string(configuration["driver"]), format: string(configuration["format"]), source: string(configuration["source"]),
            sizeBytes: int(configuration["sizeInBytes"]).map { UInt64(max(0, $0)) }, labels: strings(configuration["labels"]),
            created: date(configuration["creationDate"] ?? configuration["createdAt"]))
    }

    /// `linux/arm64`, a variant after it: `linux/arm/v7`.
    private static func platform(_ value: Any?) -> String? {
        guard let object = value as? [String: Any], let os = string(object["os"]), let architecture = string(object["architecture"]) else { return nil }
        return [os, architecture, string(object["variant"])].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "/")
    }

    private static func maskedVariable(_ pair: String) -> String {
        guard let equals = pair.firstIndex(of: "=") else { return pair }
        let key = String(pair[..<equals])
        return key + "=" + Secrets.masked(key, String(pair[pair.index(after: equals)...]))
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        // An address the tool may encode as its parts.
        case let object as [String: Any]: (object["address"] ?? object["value"] ?? object["description"]).flatMap { string($0) }
        default: nil
        }
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let text as String: Int(text)
        default: nil
        }
    }

    private static func strings(_ value: Any?) -> [String: String] {
        (value as? [String: Any] ?? [:]).reduce(into: [:]) { result, pair in if let text = string(pair.value) { result[pair.key] = text } }
    }

    /// ISO 8601, with or without fractions — or seconds since 2001, the
    /// encoder's own default.
    package static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSinceReferenceDate: number.doubleValue) }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

/// What Overterm asks of `container`: its arguments, read by the CLI, and
/// the commands typed into a terminal tab. Pure.
package enum AppleContainerCommands {
    package static let status = ["system", "status", "--format", "json"]
    package static let list = ["list", "--all", "--format", "json"]
    package static let images = ["image", "list", "--format", "json"]
    package static let volumes = ["volume", "list", "--format", "json"]

    package static func start(_ id: String) -> [String] { ["start", id] }
    package static func stop(_ id: String) -> [String] { ["stop", id] }
    package static func kill(_ id: String) -> [String] { ["kill", id] }
    /// Running ones stopped first, as `docker rm -f`.
    package static func delete(_ id: String) -> [String] { ["delete", "--force", id] }
    package static func deleteImage(_ reference: String) -> [String] { ["image", "delete", reference] }
    package static func deleteVolume(_ name: String) -> [String] { ["volume", "delete", name] }
    package static let prune = ["prune"]
    package static let pruneImages = ["image", "prune"]
    package static let pruneVolumes = ["volume", "prune"]

    /// The tool as a terminal tab types it: its full path, so a shell
    /// without `/usr/local/bin` on its PATH runs it too.
    package static func typed(_ tool: URL, _ arguments: [String]) -> String {
        ([tool.path] + arguments).map(DockerCommands.quote).joined(separator: " ")
    }

    package static func shell(_ tool: URL, in id: String) -> String {
        typed(tool, ["exec", "-it", id, "sh"])
    }

    package static func followLogs(_ tool: URL, of id: String) -> String {
        typed(tool, ["logs", "--follow", "-n", "200", id])
    }

    package static func run(_ tool: URL, image reference: String) -> String {
        typed(tool, ["run", "-it", "--rm", reference])
    }

    package static func pull(_ tool: URL, image reference: String) -> String {
        typed(tool, ["image", "pull", reference])
    }

    package static func startService(_ tool: URL) -> String { typed(tool, ["system", "start"]) }
    package static func stopService(_ tool: URL) -> String { typed(tool, ["system", "stop"]) }
}
