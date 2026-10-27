import Foundation

// What the Engine API answers, as far as the UI reads it. Every field the
// engine may leave out (an older API, a container that never started) is
// optional; Inspect shows the raw JSON beside these.

struct DockerPort: Codable, Hashable, Sendable {
    var IP: String?
    var PrivatePort: Int
    var PublicPort: Int?
    var `Type`: String
}

struct DockerMountPoint: Codable, Hashable, Sendable {
    var `Type`: String?
    var Name: String?
    var Source: String?
    var Destination: String
    var Mode: String?
    var RW: Bool?
}

/// A row of `GET /containers/json`.
struct ContainerSummary: Codable, Identifiable, Hashable, Sendable {
    var Id: String
    var Names: [String]
    var Image: String
    var ImageID: String?
    var Command: String?
    var Created: Int
    var Ports: [DockerPort]?
    var Labels: [String: String]?
    var State: String
    var Status: String
    var Mounts: [DockerMountPoint]?
    /// API 1.52+; else read from `Status` ("(healthy)").
    var Health: HealthSummary?

    struct HealthSummary: Codable, Hashable, Sendable {
        var Status: String?
        var FailingStreak: Int?
    }

    var id: String { Id }
    /// `/web-1` → `web-1`.
    var name: String { (Names.first ?? Id).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    var shortID: String { String(Id.prefix(12)) }
    var labels: [String: String] { Labels ?? [:] }

    var state: ContainerState { ContainerState(rawValue: State) ?? .unknown }

    /// healthy, unhealthy, starting — or nil without a healthcheck.
    var health: String? {
        if let status = Health?.Status, status != "none", !status.isEmpty { return status }
        for word in ["unhealthy", "healthy", "health: starting"] where Status.contains("(\(word))") {
            return word == "health: starting" ? "starting" : word
        }
        return nil
    }

    /// `Exited (137) 2 minutes ago` → 137.
    var exitCode: Int? {
        guard state == .exited, let open = Status.firstIndex(of: "("), let close = Status.firstIndex(of: ")") else { return nil }
        return Int(Status[Status.index(after: open)..<close])
    }

    var composeProject: String? { labels["com.docker.compose.project"] }
    var composeService: String? { labels["com.docker.compose.service"] }
    var composeWorkingDir: String? { labels["com.docker.compose.project.working_dir"] }
    var isOneOff: Bool { labels["com.docker.compose.oneoff"]?.lowercased() == "true" }
}

enum ContainerState: String, Sendable, CaseIterable {
    case created, running, paused, restarting, removing, exited, dead, unknown

    var isUp: Bool { self == .running || self == .paused || self == .restarting }
}

/// `GET /containers/{id}/json`: what Inspect, Mounts and the detail read.
struct ContainerDetail: Codable, Sendable {
    var Id: String
    var Name: String
    var Created: String?
    var Image: String?
    var RestartCount: Int?
    var Platform: String?
    var State: StateDetail
    var Config: Config
    var HostConfig: HostConfigDetail?
    var Mounts: [DockerMountPoint]?
    var NetworkSettings: Network?

    struct StateDetail: Codable, Sendable {
        var Status: String
        var Running: Bool?
        var Paused: Bool?
        var Restarting: Bool?
        var OOMKilled: Bool?
        var Dead: Bool?
        var Pid: Int?
        var ExitCode: Int?
        var Error: String?
        var StartedAt: String?
        var FinishedAt: String?
        var Health: Health?
    }

    struct Health: Codable, Sendable {
        var Status: String?
        var FailingStreak: Int?
        var Log: [Probe]?

        struct Probe: Codable, Sendable {
            var Start: String?
            var End: String?
            var ExitCode: Int?
            var Output: String?
        }
    }

    struct Config: Codable, Sendable {
        var Image: String?
        var Env: [String]?
        var Cmd: [String]?
        var Entrypoint: [String]?
        var WorkingDir: String?
        var User: String?
        var Labels: [String: String]?
        var ExposedPorts: [String: EmptyObject]?
        var Tty: Bool?
        var Hostname: String?
    }

    struct HostConfigDetail: Codable, Sendable {
        var RestartPolicy: RestartPolicy?
        var NetworkMode: String?
        var Memory: Int?
        var NanoCpus: Int?

        struct RestartPolicy: Codable, Sendable {
            var Name: String?
            var MaximumRetryCount: Int?
        }
    }

    struct Network: Codable, Sendable {
        var Networks: [String: Endpoint]?

        struct Endpoint: Codable, Sendable {
            var IPAddress: String?
            var Gateway: String?
            var MacAddress: String?
        }
    }

    var name: String { Name.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    var env: [(key: String, value: String)] {
        (self.Config.Env ?? []).map { entry in
            guard let equals = entry.firstIndex(of: "=") else { return (entry, "") }
            return (String(entry[..<equals]), String(entry[entry.index(after: equals)...]))
        }
    }
}

/// `{}` in Docker's maps (`ExposedPorts`, `Volumes`).
struct EmptyObject: Codable, Hashable, Sendable {}

/// A row of `GET /images/json`.
struct ImageSummary: Codable, Identifiable, Hashable, Sendable {
    var Id: String
    var RepoTags: [String]?
    var RepoDigests: [String]?
    var Created: Int
    var Size: Int
    /// -1 when the engine wasn't asked to count.
    var Containers: Int?
    var Labels: [String: String]?

    var id: String { Id }
    var shortID: String { String(Id.replacingOccurrences(of: "sha256:", with: "").prefix(12)) }
    var tags: [String] { (RepoTags ?? []).filter { $0 != "<none>:<none>" } }
    var isDangling: Bool { tags.isEmpty }
}

/// A layer, from `GET /images/{name}/history`.
struct ImageLayer: Codable, Hashable, Sendable {
    var Id: String
    var Created: Int
    var CreatedBy: String
    var Tags: [String]?
    var Size: Int
    var Comment: String?
}

struct VolumeList: Codable, Sendable {
    var Volumes: [VolumeSummary]?
    var Warnings: [String]?
}

struct VolumeSummary: Codable, Identifiable, Hashable, Sendable {
    var Name: String
    var Driver: String
    var Mountpoint: String
    var CreatedAt: String?
    var Labels: [String: String]?
    var Scope: String?
    var UsageData: Usage?

    struct Usage: Codable, Hashable, Sendable {
        var Size: Int
        var RefCount: Int
    }

    var id: String { Name }
    /// Compose's own: `project_name`.
    var composeProject: String? { Labels?["com.docker.compose.project"] }
}

struct NetworkSummary: Codable, Identifiable, Hashable, Sendable {
    var Name: String
    var Id: String
    var Driver: String?
    var Scope: String?
    var Internal: Bool?
    var Attachable: Bool?
    var Created: String?
    var Containers: [String: Member]?
    var Labels: [String: String]?

    struct Member: Codable, Hashable, Sendable {
        var Name: String?
        var IPv4Address: String?
    }

    var id: String { Id }
    /// The ones Docker makes and keeps: never offered for removal.
    var isBuiltIn: Bool { ["bridge", "host", "none"].contains(Name) }
}

/// `GET /system/df`.
struct DockerDiskUsage: Codable, Sendable {
    var LayersSize: Int?
    var Images: [ImageSummary]?
    var Containers: [ContainerUsage]?
    var Volumes: [VolumeSummary]?
    var BuildCache: [BuildCacheEntry]?

    struct ContainerUsage: Codable, Sendable {
        var Id: String
        var SizeRw: Int?
    }

    struct BuildCacheEntry: Codable, Sendable {
        var ID: String
        var Size: Int
        var InUse: Bool?
        var Shared: Bool?
    }
}

/// `GET /info`, the little of it the UI says.
struct EngineInfo: Codable, Sendable {
    var Name: String?
    var OperatingSystem: String?
    var ServerVersion: String?
    var NCPU: Int?
    var MemTotal: Int?
    var Containers: Int?
    var ContainersRunning: Int?
    var Images: Int?
}

/// One line of `GET /events`.
struct DockerEvent: Codable, Sendable {
    var `Type`: String
    var Action: String
    var Actor: Actor
    var time: Int?
    var timeNano: Int?

    struct Actor: Codable, Sendable {
        var ID: String
        var Attributes: [String: String]?
    }

    /// `health_status: healthy` → `health_status`.
    var verb: String { String(Action.split(separator: ":").first ?? Substring(Action)).trimmingCharacters(in: .whitespaces) }

    /// The events that change what a list shows. Healthchecks run `exec`s
    /// every few seconds (the spike counted 189 in a minute); those, and our
    /// own `archive` reads, are left out.
    static let listed: Set<String> = [
        "create", "start", "restart", "die", "stop", "kill", "pause", "unpause", "destroy", "rename", "health_status", "oom", "update",
    ]
}

/// `GET /containers/{id}/stats`.
struct ContainerStatsSample: Codable, Sendable {
    var read: String?
    var cpu_stats: CPU?
    var precpu_stats: CPU?
    var memory_stats: Memory?
    var networks: [String: NetworkIO]?
    var blkio_stats: BlockIO?
    var pids_stats: Pids?

    struct CPU: Codable, Sendable {
        var cpu_usage: Usage?
        var system_cpu_usage: Int?
        var online_cpus: Int?

        struct Usage: Codable, Sendable {
            var total_usage: Int?
        }
    }

    struct Memory: Codable, Sendable {
        var usage: Int?
        var limit: Int?
        var stats: [String: Int]?
    }

    struct NetworkIO: Codable, Sendable {
        var rx_bytes: Int?
        var tx_bytes: Int?
    }

    struct BlockIO: Codable, Sendable {
        var io_service_bytes_recursive: [Entry]?

        struct Entry: Codable, Sendable {
            var op: String?
            var value: Int?
        }
    }

    struct Pids: Codable, Sendable {
        var current: Int?
    }
}

/// What a prune freed.
struct PruneReport: Codable, Sendable {
    var SpaceReclaimed: Int?
    var ContainersDeleted: [String]?
    var ImagesDeleted: [ImageDeleted]?
    var VolumesDeleted: [String]?
    var NetworksDeleted: [String]?
    var CachesDeleted: [String]?

    struct ImageDeleted: Codable, Sendable {
        var Untagged: String?
        var Deleted: String?
    }
}
