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
    /// A URL's userinfo holds no `/`, `?` or `#` (RFC 3986), so a port
    /// and a later `@` (`http://api:8080/users/jane@example.com`) are no
    /// password.
    static func maskURL(_ value: String) -> String {
        // No user is Redis's way: `redis://:pass@host`.
        guard let range = value.range(of: #"://[^:/?#@\s]*:([^/?#@\s]+)@"#, options: .regularExpression) else { return value }
        let segment = value[range]
        guard let colon = segment.dropFirst(3).firstIndex(of: ":"), let at = segment.lastIndex(of: "@") else { return value }
        return value.replacingCharacters(in: segment.index(after: colon)..<at, with: "••••••")
    }

    static func masked(_ key: String, _ value: String) -> String {
        isSecret(key) ? mask(value) : maskURL(value)
    }

    /// Every secret value in a set of env entries, to take out of other
    /// text (a log line an agent is shown). Besides `names` the text says
    /// anyway: a dev stack's password is often its image's name
    /// (`POSTGRES_PASSWORD=postgres`), and taking that out blanks the
    /// container's own name, its paths and its log, not a secret.
    static func values(in env: [(key: String, value: String)], besides names: Set<String> = []) -> [String] {
        env.filter { isSecret($0.key) && $0.value.count >= 4 && !names.contains($0.value) }.map(\.value)
    }

    static func redact(_ text: String, values: [String]) -> String {
        values.sorted { $0.count > $1.count }.reduce(text) { $0.replacingOccurrences(of: $1, with: "••••••") }
    }

    /// Every URL's password in `text` masked, not just the first: a log
    /// line can name two databases. No `/`, `?` or `#` in a password, as
    /// in `maskURL`: a request's path with an email in it stays.
    static func maskURLs(in text: String) -> String {
        guard text.contains("://") else { return text }
        return text.replacingOccurrences(of: #"(://[^:/?#@\s]*:)([^/?#@\s]+)(@)"#, with: "$1••••••$3", options: .regularExpression)
    }

    /// What an agent may read of `text`: the env's secret values (but
    /// `names`, see `values`) and every URL's password taken out — it
    /// lands in the agent's transcript.
    static func scrub(_ text: String, env: [(key: String, value: String)], keeping names: Set<String> = []) -> String {
        maskURLs(in: redact(text, values: values(in: env, besides: names)))
    }

    /// `${VAR}` or `$VAR`, nothing else: a default (`${VAR:-pw}`) may be
    /// the secret itself.
    static func isReference(_ text: String) -> Bool {
        text.range(of: #"^\$(\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)$"#, options: .regularExpression) != nil
    }

    /// A command's words, what its secret-looking flags give masked: the
    /// word after `--requirepass`, `--password`, `--token`, `--api-key`,
    /// redis-cli's `-a`, mongosh's `-p`; `--flag=value` and `KEY=value` by
    /// their name; mysql's `-pvalue`; curl's `-u user:password` past the
    /// colon. A shell script's words (`sh -c '…'`, `CMD-SHELL`) the same.
    /// Compose has put `.env`'s values into a command already, so the
    /// container's env can't name them all. A `${VAR}` stays as written.
    static func maskArguments(_ words: [String]) -> [String] {
        enum Pending { case secret, userinfo }
        let programs = Set(words.map { ($0 as NSString).lastPathComponent })
        let redis = programs.contains("redis-cli")
        let curl = programs.contains("curl")
        let mongo = !programs.isDisjoint(with: ["mongosh", "mongo"])
        let mysql = !programs.isDisjoint(with: ["mysql", "mysqladmin", "mysqldump", "mysqlshow", "mysqlcheck", "mariadb", "mariadb-admin", "mariadb-dump"])
        var pending: Pending?
        return words.map { word -> String in
            // A flag after a flag: the first one took no value.
            if let wanted = pending, !word.hasPrefix("--") {
                pending = nil
                return wanted == .userinfo ? maskUserinfo(word) : maskValue(word)
            }
            pending = nil
            if word.contains(where: \.isWhitespace) { return maskScript(word) }
            if word.hasPrefix("-"), word.count > 1 {
                let flag = String(word.drop { $0 == "-" })
                let dashes = String(word.prefix(word.count - flag.count))
                if let equals = flag.firstIndex(of: "=") {
                    let name = String(flag[..<equals])
                    let value = String(flag[flag.index(after: equals)...])
                    if curl && name == "user" { return dashes + name + "=" + maskUserinfo(value) }
                    return isSecretFlag(name) ? dashes + name + "=" + maskValue(value) : word
                }
                let long = dashes.count > 1
                if isSecretFlag(flag) || (redis && word == "-a") || (mongo && word == "-p") {
                    pending = .secret
                } else if curl && (word == "-u" || word == "--user") {
                    pending = .userinfo
                } else if curl && !long && flag.hasPrefix("u") {
                    return "-u" + maskUserinfo(String(flag.dropFirst()))
                } else if mysql && !long && flag.hasPrefix("p") && flag.count > 1 {
                    return "-p" + maskValue(String(flag.dropFirst()))
                }
                return word
            }
            if let equals = word.firstIndex(of: "=") {
                let name = String(word[..<equals])
                if name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil, isSecret(name) {
                    return name + "=" + maskValue(String(word[word.index(after: equals)...]))
                }
            }
            return word
        }
    }

    /// A flag's name that says a secret follows: the env's words, and a
    /// pass (`--requirepass`, `--pass`, `--db-pass`).
    static func isSecretFlag(_ name: String) -> Bool {
        let lower = name.lowercased()
        return isSecret(name.replacingOccurrences(of: "-", with: "_")) || lower.hasSuffix("pass") || lower.contains("passphrase")
    }

    /// A shell script's words masked in place, its spacing kept.
    private static func maskScript(_ script: String) -> String {
        let string = script as NSString
        guard let words = try? NSRegularExpression(pattern: #"\S+"#) else { return script }
        let matches = words.matches(in: script, range: NSRange(location: 0, length: string.length))
        let masked = maskArguments(matches.map { string.substring(with: $0.range) })
        var out = script as NSString
        for (match, word) in zip(matches, masked).reversed() { out = out.replacingCharacters(in: match.range, with: word) as NSString }
        return out as String
    }

    /// A flag's value: a `${VAR}` kept as written, a path too (`--key
    /// /certs/key.pem` names a file, not the key).
    private static func maskValue(_ value: String) -> String {
        let bare = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return isReference(bare) || bare.hasPrefix("/") ? value : mask(value)
    }

    /// `user:password`: the user kept.
    private static func maskUserinfo(_ value: String) -> String {
        guard let colon = value.firstIndex(of: ":") else { return value }
        return String(value[...colon]) + maskValue(String(value[value.index(after: colon)...]))
    }
}

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
