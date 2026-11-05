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

    /// Against an earlier read's CPU rather than the sample's own
    /// `precpu_stats` — what a one-shot read needs.
    init(_ sample: ContainerStatsSample, since earlier: ContainerStatsSample.CPU) {
        var paired = sample
        paired.precpu_stats = earlier
        self.init(paired)
    }

    /// A project's, or a block's: its containers' use added up. No limit:
    /// theirs aren't one.
    static func sum(_ usages: [DockerUsage]) -> DockerUsage? {
        guard !usages.isEmpty else { return nil }
        return DockerUsage(
            cpuPercent: usages.reduce(0) { $0 + $1.cpuPercent }, memoryBytes: usages.reduce(0) { $0 + $1.memoryBytes }, memoryLimit: 0,
            networkIn: usages.reduce(0) { $0 + $1.networkIn }, networkOut: usages.reduce(0) { $0 + $1.networkOut },
            diskRead: usages.reduce(0) { $0 + $1.diskRead }, diskWrite: usages.reduce(0) { $0 + $1.diskWrite },
            processes: usages.reduce(0) { $0 + $1.processes })
    }

    /// The list's cells: `12.5%`, from 100 whole (`250%`) — not the
    /// locale's comma; memory as the detail says it.
    var cpuLabel: String { String(format: cpuPercent >= 99.95 ? "%.0f%%" : "%.1f%%", cpuPercent) }
    var memoryLabel: String { DockerBytes.string(memoryBytes, memory: true) }
    /// Within a tenth of its limit: the kernel kills it there.
    var nearMemoryLimit: Bool { memoryLimit > 0 && memoryPercent >= 90 }
}

/// One-shot reads carry no `precpu_stats`: a container's CPU is its read
/// set against the one before it, as `docker stats` sets a sample against
/// `precpu_stats` — over the seconds between. Pure.
struct DockerUsageReadings: Sendable {
    private var last: [String: ContainerStatsSample.CPU] = [:]

    /// Read once, waiting for its second.
    func has(_ id: String) -> Bool { last[id] != nil }

    /// Its use since the read before — nil for its first read, after a
    /// restart (its counter went back), or for an empty read (it stopped;
    /// forgotten). The read is kept to set the next against.
    mutating func add(_ sample: ContainerStatsSample, for id: String) -> DockerUsage? {
        guard let cpu = sample.cpu_stats, (cpu.system_cpu_usage ?? 0) > 0 else {
            last[id] = nil
            return nil
        }
        let earlier = last[id]
        last[id] = cpu
        guard let earlier, (cpu.cpu_usage?.total_usage ?? 0) >= (earlier.cpu_usage?.total_usage ?? 0),
            (cpu.system_cpu_usage ?? 0) > (earlier.system_cpu_usage ?? 0)
        else { return nil }
        return DockerUsage(sample, since: earlier)
    }

    /// Only these are kept: the rest stopped or went.
    mutating func keep(_ ids: Set<String>) { last = last.filter { ids.contains($0.key) } }
}

/// A container's published ports, once each: the engine lists a port
/// twice, for IPv4 and IPv6 (`0.0.0.0` and `::`, the spike). Pure.
struct PublishedPort: Hashable, Sendable, Comparable {
    var hostPort: Int
    var containerPort: Int
    var proto: String
    /// The host address it is bound to, when it isn't every address.
    var hostIP: String?
    /// The engine's host when it isn't this Mac (`DockerModel.publishedHost`).
    var remoteHost: String?

    static func < (a: PublishedPort, b: PublishedPort) -> Bool { (a.hostPort, a.containerPort) < (b.hostPort, b.containerPort) }

    /// Where it is reached from here: localhost unless bound elsewhere; a
    /// remote engine's host — nil when bound to that host's own loopback,
    /// which only the host reaches.
    var address: String? {
        guard let remoteHost else { return hostIP ?? "localhost" }
        guard let hostIP else { return remoteHost }
        return ["127.0.0.1", "::1"].contains(hostIP) ? nil : hostIP
    }

    /// Where to open it.
    var url: URL? {
        guard let address else { return nil }
        return URL(string: "http://\(address.contains(":") ? "[\(address)]" : address):\(hostPort)")
    }

    var label: String { "\(hostPort)→\(containerPort)\(proto == "tcp" ? "" : "/\(proto)")" }

    /// As an agent is told it: `localhost:8080→80`; on a remote engine,
    /// its host's name.
    var spoken: String { "\(address ?? "the host's loopback"):\(hostPort)→\(containerPort)" }

    static func of(_ ports: [DockerPort], remoteHost: String? = nil) -> [PublishedPort] {
        var byPort: [String: PublishedPort] = [:]
        for port in ports {
            guard let host = port.PublicPort else { continue }
            let ip = port.IP.flatMap { ["0.0.0.0", "::", ""].contains($0) ? nil : $0 }
            let candidate = PublishedPort(hostPort: host, containerPort: port.PrivatePort, proto: port.Type, hostIP: ip, remoteHost: remoteHost)
            let key = "\(host)/\(port.Type)"
            // Bound to every address wins; else IPv4's address over IPv6's.
            if let kept = byPort[key], kept.hostIP == nil || candidate.hostIP?.contains(":") == true { continue }
            byPort[key] = candidate
        }
        return byPort.values.sorted()
    }
}

/// Docker's name for the shared secrets helper (`Secrets`): its masking and
/// scrubbing, unchanged.
typealias DockerSecrets = Secrets

/// Sizes as Docker's lists say them: `0 KB`, never ByteCountFormatter's
/// "Zero KB"; memory in binary units, files and images in decimal.
enum DockerBytes {
    static func string(_ count: Int, memory: Bool = false) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = memory ? .memory : .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(count))
    }
}
