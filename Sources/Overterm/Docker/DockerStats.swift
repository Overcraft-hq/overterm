import Foundation

/// A container's use, worked out from one stats sample, as `docker stats`
/// works it out. Pure.
struct DockerUsage: Equatable, Sendable {
    /// Percent of one CPU (200 is two CPUs flat out), as `docker stats`.
    var cpuPercent: Double
    var memoryBytes: Int
    var memoryLimit: Int
    var networkIn: Int
    var networkOut: Int
    var diskRead: Int
    var diskWrite: Int
    var processes: Int

    var memoryPercent: Double { memoryLimit > 0 ? Double(memoryBytes) / Double(memoryLimit) * 100 : 0 }

    init(cpuPercent: Double, memoryBytes: Int, memoryLimit: Int, networkIn: Int, networkOut: Int, diskRead: Int, diskWrite: Int, processes: Int) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.memoryLimit = memoryLimit
        self.networkIn = networkIn
        self.networkOut = networkOut
        self.diskRead = diskRead
        self.diskWrite = diskWrite
        self.processes = processes
    }

    /// CPU: the container's share of the change since the sample before
    /// (`precpu_stats`, which the engine fills in), times the CPUs. Memory:
    /// the usage less the page cache (`inactive_file` on cgroup v2,
    /// `cache` on v1), as `docker stats` shows it.
    init(_ sample: ContainerStatsSample) {
        let cpu = Double((sample.cpu_stats?.cpu_usage?.total_usage ?? 0) - (sample.precpu_stats?.cpu_usage?.total_usage ?? 0))
        let system = Double((sample.cpu_stats?.system_cpu_usage ?? 0) - (sample.precpu_stats?.system_cpu_usage ?? 0))
        let cpus = Double(sample.cpu_stats?.online_cpus ?? 1)
        cpuPercent = system > 0 && cpu > 0 ? cpu / system * cpus * 100 : 0
        let stats = sample.memory_stats?.stats ?? [:]
        let cache = stats["inactive_file"] ?? stats["total_inactive_file"] ?? stats["cache"] ?? 0
        memoryBytes = max(0, (sample.memory_stats?.usage ?? 0) - cache)
        memoryLimit = sample.memory_stats?.limit ?? 0
        networkIn = sample.networks?.values.reduce(0) { $0 + ($1.rx_bytes ?? 0) } ?? 0
        networkOut = sample.networks?.values.reduce(0) { $0 + ($1.tx_bytes ?? 0) } ?? 0
        let io = sample.blkio_stats?.io_service_bytes_recursive ?? []
        diskRead = io.filter { $0.op?.lowercased() == "read" }.reduce(0) { $0 + ($1.value ?? 0) }
        diskWrite = io.filter { $0.op?.lowercased() == "write" }.reduce(0) { $0 + ($1.value ?? 0) }
        processes = sample.pids_stats?.current ?? 0
    }
}

/// A container's published ports, once each: the engine lists a port
/// twice, for IPv4 and IPv6 (`0.0.0.0` and `::`, the spike). Pure.
struct PublishedPort: Hashable, Sendable, Comparable {
    var hostPort: Int
    var containerPort: Int
    var proto: String
    /// The host address it is bound to, when it isn't every address.
    var hostIP: String?

    static func < (a: PublishedPort, b: PublishedPort) -> Bool { (a.hostPort, a.containerPort) < (b.hostPort, b.containerPort) }

    /// Where to open it: localhost unless bound elsewhere.
    var url: URL? {
        let host = hostIP.map { $0.contains(":") ? "[\($0)]" : $0 } ?? "localhost"
        return URL(string: "http://\(host):\(hostPort)")
    }

    var label: String { "\(hostPort)→\(containerPort)\(proto == "tcp" ? "" : "/\(proto)")" }

    static func of(_ ports: [DockerPort]) -> [PublishedPort] {
        var byPort: [String: PublishedPort] = [:]
        for port in ports {
            guard let host = port.PublicPort else { continue }
            let ip = port.IP.flatMap { ["0.0.0.0", "::", ""].contains($0) ? nil : $0 }
            let candidate = PublishedPort(hostPort: host, containerPort: port.PrivatePort, proto: port.Type, hostIP: ip)
            let key = "\(host)/\(port.Type)"
            // Bound to every address wins; else IPv4's address over IPv6's.
            if let kept = byPort[key], kept.hostIP == nil || candidate.hostIP?.contains(":") == true { continue }
            byPort[key] = candidate
        }
        return byPort.values.sorted()
    }
}

/// Env values that look like secrets, hidden where a person or an agent
/// reads them — Inspect, the MCP tools. Pure.
enum DockerSecrets {
    static let words = ["PASSWORD", "PASSWD", "SECRET", "TOKEN", "KEY", "CREDENTIAL", "PRIVATE", "AUTH", "SESSION", "SALT", "DSN"]
    /// Keys that carry those words and aren't secrets.
    static let harmless: Set<String> = ["KEYBOARD", "PUBLIC_KEY_PATH", "AUTH_ENABLED", "MONKEY"]

    static func isSecret(_ key: String) -> Bool {
        let upper = key.uppercased()
        guard !harmless.contains(upper) else { return false }
        return words.contains { upper.contains($0) }
    }

    static func mask(_ value: String) -> String { value.isEmpty ? "" : "••••••" }

    /// `postgres://user:pass@host/db` keeps everything but the password.
    static func maskURL(_ value: String) -> String {
        guard let range = value.range(of: #"://[^:/@\s]+:([^@\s]+)@"#, options: .regularExpression) else { return value }
        let segment = value[range]
        guard let colon = segment.dropFirst(3).firstIndex(of: ":"), let at = segment.lastIndex(of: "@") else { return value }
        return value.replacingCharacters(in: segment.index(after: colon)..<at, with: "••••••")
    }

    static func masked(_ key: String, _ value: String) -> String {
        isSecret(key) ? mask(value) : maskURL(value)
    }

    /// Every secret value in a set of env entries, to take out of other
    /// text (a log line an agent is shown).
    static func values(in env: [(key: String, value: String)]) -> [String] {
        env.filter { isSecret($0.key) && $0.value.count >= 4 }.map(\.value)
    }

    static func redact(_ text: String, values: [String]) -> String {
        values.sorted { $0.count > $1.count }.reduce(text) { $0.replacingOccurrences(of: $1, with: "••••••") }
    }
}
