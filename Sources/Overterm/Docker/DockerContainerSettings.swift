import Foundation

/// Sizes as `docker run --memory` reads them: 1024-based, any case —
/// `512m`, `1.5g`, `2GiB`, `512 MB`. Pure.
enum DockerSize {
    static let units: [(suffix: String, bytes: Int)] = [("t", 1 << 40), ("g", 1 << 30), ("m", 1 << 20), ("k", 1 << 10)]

    private static let pattern = try? NSRegularExpression(pattern: #"^(\d+(?:\.\d+)?)([kmgt]?)(?:i?b)?$"#)

    /// Nil when empty, unreadable, or not above zero. A comma reads as a
    /// decimal point (`1,5g`): it is what a Turkish or German Mac types.
    static func parse(_ text: String) -> Int? {
        let plain = text.lowercased().filter { !$0.isWhitespace }.replacingOccurrences(of: ",", with: ".")
        guard let pattern, let match = pattern.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)),
            let digits = Range(match.range(at: 1), in: plain), let number = Double(plain[digits])
        else { return nil }
        let unit = Range(match.range(at: 2), in: plain).map { String(plain[$0]) } ?? ""
        let bytes = number * Double(units.first { $0.suffix == unit }?.bytes ?? 1)
        guard bytes >= 1, bytes < Double(Int.max / 2) else { return nil }
        return Int(bytes)
    }

    /// As the field shows it and `docker update` takes it: the largest unit
    /// it is a whole number of (`512m`, `1g`) or one decimal of (`1.5g`),
    /// else bytes. Never the locale's: the field reads it back.
    static func format(_ bytes: Int) -> String {
        for unit in units where bytes >= unit.bytes {
            if bytes % unit.bytes == 0 { return "\(bytes / unit.bytes)\(unit.suffix)" }
            let (tenfold, overflow) = bytes.multipliedReportingOverflow(by: 10)
            if !overflow, tenfold % unit.bytes == 0 { return String(format: "%.1f", Double(bytes) / Double(unit.bytes)) + unit.suffix }
        }
        return "\(bytes)"
    }
}

/// A name Docker gives a container. Pure.
enum DockerContainerName {
    /// Nil when Docker takes it (`[a-zA-Z0-9][a-zA-Z0-9_.-]+`, moby's
    /// `validContainerNamePattern`), else why not.
    static func problem(_ name: String) -> String? {
        name.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_.-]+$"#, options: .regularExpression) != nil
            ? nil : "A container's name is two or more letters, digits, “_”, “.” or “-”, the first a letter or digit."
    }
}

/// What the Settings sheet edits: a container's memory limit, CPUs and
/// restart policy, read from its inspect and changed in place as
/// `docker update` changes them — checked first as the engine checks
/// them, so a mistake is said before it is sent. Pure.
///
/// The engine reads every zero as "unchanged": a limit can be changed but
/// never taken away. A memory limit goes with its swap, always: the engine
/// refuses a limit above the swap it has unless a swap comes with it, and
/// a container with no limit has a swap of 0.
struct DockerContainerSettings: Equatable, Sendable {
    /// What inspect says it has now.
    struct Current: Equatable, Sendable {
        var memory = 0
        /// -1 is swap without a limit; 0 none set.
        var memorySwap = 0
        var nanoCPUs = 0
        var cpuQuota = 0
        var cpuPeriod = 0
        /// `no` when inspect says nothing.
        var restart = "no"
        var retries = 0
        /// `--rm`: no restart policy can be given it.
        var autoRemove = false

        init(_ host: ContainerDetail.HostConfigDetail?) {
            memory = host?.Memory ?? 0
            memorySwap = host?.MemorySwap ?? 0
            nanoCPUs = host?.NanoCpus ?? 0
            cpuQuota = host?.CpuQuota ?? 0
            cpuPeriod = host?.CpuPeriod ?? 0
            let name = host?.RestartPolicy?.Name ?? ""
            restart = name.isEmpty ? "no" : name
            retries = host?.RestartPolicy?.MaximumRetryCount ?? 0
            autoRemove = host?.AutoRemove ?? false
        }

        /// Made with `--cpu-quota` (Compose's `cpu_quota`): changed by its
        /// quota — the engine puts no NanoCpus over one.
        var byQuota: Bool { nanoCPUs == 0 && (cpuQuota > 0 || cpuPeriod > 0) }
        /// The kernel's when none was given.
        var period: Int { cpuPeriod > 0 ? cpuPeriod : 100_000 }

        /// Its CPU limit in CPUs, either way it was given; nil for none.
        var cpus: Double? {
            if nanoCPUs > 0 { return Double(nanoCPUs) / 1e9 }
            if cpuQuota > 0 { return Double(cpuQuota) / Double(period) }
            return nil
        }
    }

    let id: String
    let name: String
    /// Its compose project and service: Compose puts back what its file
    /// says when it makes the container again.
    let project: String?
    let service: String?
    let running: Bool
    let current: Current
    /// What the engine has: the most a limit can be.
    var engineCPUs: Int?
    var engineMemory: Int?
    /// What a running one uses now, one sample.
    var inUse: Int?
    /// As typed: `512m`, `1.5`; empty for no limit.
    var memory: String
    var cpus: String
    /// `no`, `always`, `unless-stopped`, `on-failure`.
    var restart: String
    /// On failure: how many times at most, 0 for no limit.
    var retries: Int

    static let restarts = ["no", "always", "unless-stopped", "on-failure"]
    /// moby's `linuxMinMemory`.
    static let leastMemory = 6 << 20
    /// The most CPUs asked for when the engine hasn't said what it has.
    static let mostCPUs = 1024

    init(_ container: ContainerSummary, _ detail: ContainerDetail, engine: EngineInfo?) {
        id = container.Id
        name = container.name
        project = container.composeProject
        service = container.composeService
        running = container.state == .running
        current = Current(detail.HostConfig)
        engineCPUs = engine?.NCPU
        engineMemory = engine?.MemTotal
        memory = current.memory > 0 ? DockerSize.format(current.memory) : ""
        cpus = current.cpus.map(Self.number) ?? ""
        restart = current.restart
        retries = current.retries
    }

    /// `1.5`, `2`, `0.25`: POSIX, never the locale's.
    static func number(_ value: Double) -> String { String(format: "%g", value) }

    static func nanos(_ cpus: Double) -> Int { whole(cpus * 1e9) }

    static func quota(_ cpus: Double, period: Int) -> Int { whole(cpus * Double(period)) }

    /// Rounded, and held inside what an Int holds: a byte count pasted
    /// into CPUs (`17179869184` is 1.7e19 nano-CPUs) would trap, and take
    /// the app down with it. `problem` says why such a number is refused.
    static func whole(_ value: Double) -> Int {
        let bound = Double(Int.max / 2)
        return value.isFinite ? Int(min(max(value.rounded(), -bound), bound)) : 0
    }

    /// The swap a new limit goes with: what it was — none (the same as the
    /// limit), unlimited, or the same on top — else twice the limit, as
    /// `docker run -m` makes it.
    static func swap(for memory: Int, _ current: Current) -> Int {
        let swap = current.memorySwap
        if swap == -1 { return -1 }
        if current.memory > 0 {
            if swap == current.memory { return memory }
            if swap == 2 * current.memory { return 2 * memory }
            if swap > current.memory { return memory + (swap - current.memory) }
        }
        return 2 * memory
    }

    // MARK: What was typed

    private var memoryText: String { memory.trimmingCharacters(in: .whitespaces) }
    private var cpuText: String { cpus.trimmingCharacters(in: .whitespaces) }

    /// The limit asked for; nil for an empty field, or one unreadable.
    var memoryBytes: Int? { DockerSize.parse(memoryText) }

    var cpuCount: Double? {
        guard let value = Double(cpuText.replacingOccurrences(of: ",", with: ".")), value.isFinite else { return nil }
        return value
    }

    var memoryChanged: Bool { memoryBytes.map { $0 != current.memory } ?? false }

    /// Compared as what would be sent: a quota, or nano-CPUs.
    var cpusChanged: Bool {
        guard let count = cpuCount else { return false }
        return current.byQuota ? Self.quota(count, period: current.period) != current.cpuQuota : Self.nanos(count) != current.nanoCPUs
    }

    var restartChanged: Bool { restart != current.restart || (restart == "on-failure" && retries != current.retries) }

    /// Anything to send: `docker update` with no flag is refused.
    var changed: Bool { memoryChanged || cpusChanged || restartChanged }

    // MARK: What is said

    /// What the engine would refuse, said first; nil when it would take it.
    var problem: String? {
        if !memoryText.isEmpty {
            guard let bytes = memoryBytes else { return "“\(memoryText)” isn't a size Docker reads: 512m, 2g." }
            if bytes < Self.leastMemory { return "Docker's least is 6m." }
        } else if current.memory > 0 {
            return "Docker can change a memory limit but not take one away"
                + (engineMemory.map { " — the most it can be is the engine's \(DockerBytes.string($0, memory: true))." } ?? ".")
        }
        if !cpuText.isEmpty {
            guard let count = cpuCount else { return "“\(cpuText)” isn't a number of CPUs: 0.5, 2." }
            if count < 0.01 { return "The least is 0.01 of a CPU." }
            if let all = engineCPUs, count > Double(all) { return "The engine has \(all) CPU\(all == 1 ? "" : "s"): \(all) at most." }
            if count > Double(Self.mostCPUs) { return "“\(cpuText)” is more CPUs than a machine has: \(Self.mostCPUs) at most." }
        } else if current.cpus != nil {
            return "Docker can change a CPU limit but not take one away" + (engineCPUs.map { " — the most is \($0), all the engine has." } ?? ".")
        }
        if !Self.restarts.contains(restart) { return "“\(restart)” isn't a restart policy: no, always, unless-stopped or on-failure." }
        if retries < 0 { return "On failure, it tries again 0 or more times." }
        if restartChanged, current.autoRemove { return "It was run with --rm: Docker gives such a container no restart policy." }
        return nil
    }

    /// Not a mistake, but worth saying: a limit under what it uses now.
    var caution: String? {
        guard let inUse, let bytes = memoryBytes, bytes < inUse else { return nil }
        return "It uses \(DockerBytes.string(inUse, memory: true)) now: under that, its processes are killed for memory."
    }

    /// What goes to the engine: only what changed. Nil when there is a
    /// problem, or nothing changed.
    var update: DockerEngine.ContainerUpdate? {
        guard problem == nil else { return nil }
        var change = DockerEngine.ContainerUpdate()
        if memoryChanged, let bytes = memoryBytes {
            change.Memory = bytes
            change.MemorySwap = Self.swap(for: bytes, current)
        }
        if cpusChanged, let count = cpuCount {
            if current.byQuota { change.CpuQuota = Self.quota(count, period: current.period) } else { change.NanoCpus = Self.nanos(count) }
        }
        if restartChanged { change.RestartPolicy = .init(Name: restart, MaximumRetryCount: restart == "on-failure" ? retries : 0) }
        return change == DockerEngine.ContainerUpdate() ? nil : change
    }

    /// The same change as `docker update` would make it, for the sheet to
    /// show and copy: only what changed.
    func line(prefix: String = "") -> String {
        var words = ["docker", "update"]
        if memoryChanged, let bytes = memoryBytes {
            let swap = Self.swap(for: bytes, current)
            words += ["--memory", DockerSize.format(bytes), "--memory-swap", swap == -1 ? "-1" : DockerSize.format(swap)]
        }
        if cpusChanged, let count = cpuCount {
            words += current.byQuota ? ["--cpu-quota", "\(Self.quota(count, period: current.period))"] : ["--cpus", Self.number(count)]
        }
        if restartChanged { words += ["--restart", restart == "on-failure" && retries > 0 ? "on-failure:\(retries)" : restart] }
        words.append(DockerCommands.quote(name))
        return prefix + words.joined(separator: " ")
    }

    /// What changed, as the page says it: `memory 1 GB, 1.5 CPUs,
    /// restarts unless stopped`.
    var summary: String {
        var parts: [String] = []
        if memoryChanged, let bytes = memoryBytes { parts.append("memory " + DockerBytes.string(bytes, memory: true)) }
        if cpusChanged, let count = cpuCount { parts.append(count == 1 ? "1 CPU" : "\(Self.number(count)) CPUs") }
        if restartChanged { parts.append(Self.restartWords(restart, retries: retries)) }
        return parts.joined(separator: ", ")
    }

    static func restartWords(_ policy: String, retries: Int) -> String {
        switch policy {
        case "always": "always restarts"
        case "unless-stopped": "restarts unless stopped"
        case "on-failure": "restarts on failure" + (retries == 1 ? ", once at most" : retries > 1 ? ", \(retries) times at most" : "")
        default: "doesn't restart"
        }
    }
}
