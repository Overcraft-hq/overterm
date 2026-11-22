import Foundation

// What the Engine API answers, as far as the UI reads it. Every field the
// engine may leave out (an older API, a container that never started) is
// optional; Inspect shows the raw JSON beside these.

package struct DockerPort: Codable, Hashable, Sendable {
    package var IP: String?
    package var PrivatePort: Int
    package var PublicPort: Int?
    package var `Type`: String
}

package struct DockerMountPoint: Codable, Hashable, Sendable {
    package var `Type`: String?
    package var Name: String?
    package var Source: String?
    package var Destination: String
    package var Mode: String?
    package var RW: Bool?
}

/// A row of `GET /containers/json`.
package struct ContainerSummary: Codable, Identifiable, Hashable, Sendable {
    package var Id: String
    package var Names: [String]
    package var Image: String
    package var ImageID: String?
    package var Command: String?
    package var Created: Int
    package var Ports: [DockerPort]?
    package var Labels: [String: String]?
    package var State: String
    package var Status: String
    package var Mounts: [DockerMountPoint]?
    /// API 1.52+; else read from `Status` ("(healthy)").
    package var Health: HealthSummary?
    /// The networks it is on, stopped or not — what keeps a network from
    /// being pruned.
    package var NetworkSettings: SummaryNetworks?
    /// API 1.48+, in the containerd image store: the manifest it was made
    /// from, with its platform — what it runs, whatever its image's index
    /// has gained since (`DockerModel.platform(of:)`).
    package var ImageManifestDescriptor: ManifestDescriptor? = nil

    /// An OCI descriptor, as far as its platform.
    package struct ManifestDescriptor: Codable, Hashable, Sendable {
        package var platform: Platform?

        package struct Platform: Codable, Hashable, Sendable {
            package var architecture: String?
            package var os: String?
            package var variant: String?
        }

        package var dockerPlatform: DockerPlatform? { platform.flatMap { DockerPlatform(os: $0.os, architecture: $0.architecture, variant: $0.variant) } }
    }

    /// What it runs, as it says itself; nil before API 1.48 and in the
    /// classic image store, where its image's id is the platform's own.
    package var ownPlatform: DockerPlatform? { ImageManifestDescriptor?.dockerPlatform }

    package struct HealthSummary: Codable, Hashable, Sendable {
        package var Status: String?
        package var FailingStreak: Int?
    }

    package struct SummaryNetworks: Codable, Hashable, Sendable {
        package var Networks: [String: Attachment]?

        package struct Attachment: Codable, Hashable, Sendable {
            package var NetworkID: String?
            package var IPAddress: String?
        }
    }

    /// The networks' names.
    package var networkNames: [String] { (NetworkSettings?.Networks ?? [:]).keys.sorted() }

    package var id: String { Id }
    /// `/web-1` → `web-1`.
    package var name: String { (Names.first ?? Id).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    package var shortID: String { String(Id.prefix(12)) }
    package var labels: [String: String] { Labels ?? [:] }

    package var state: ContainerState { ContainerState(rawValue: State) ?? .unknown }

    /// healthy, unhealthy, starting — or nil without a healthcheck.
    package var health: String? {
        if let status = Health?.Status, status != "none", !status.isEmpty { return status }
        for word in ["unhealthy", "healthy", "health: starting"] where Status.contains("(\(word))") {
            return word == "health: starting" ? "starting" : word
        }
        return nil
    }

    /// `Exited (137) 2 minutes ago` → 137.
    package var exitCode: Int? {
        guard state == .exited, let open = Status.firstIndex(of: "("), let close = Status.firstIndex(of: ")") else { return nil }
        return Int(Status[Status.index(after: open)..<close])
    }

    /// Nil for an empty label too: an image Overterm saved empties
    /// Compose's labels (`DockerCommit`), and a container run from it is
    /// no service of a project called "".
    package var composeProject: String? { labels["com.docker.compose.project"].flatMap { $0.isEmpty ? nil : $0 } }
    package var composeService: String? { labels["com.docker.compose.service"].flatMap { $0.isEmpty ? nil : $0 } }
    package var composeWorkingDir: String? { labels["com.docker.compose.project.working_dir"].flatMap { $0.isEmpty ? nil : $0 } }
    package var isOneOff: Bool { labels["com.docker.compose.oneoff"]?.lowercased() == "true" }
    /// One Overterm made for itself (`DockerHelpers`): a volume's helper.
    /// Never listed — one mounting a volume would make it look in use.
    package var isHelper: Bool { labels["overterm.helper"] == "1" }
    /// Its image's name names another image now: once the tag it was made
    /// from moved (a pull), the engine lists it by its image's ID.
    package var imageMovedOn: Bool { ImageID != nil && Image == ImageID }
}

package enum ContainerState: String, Sendable, CaseIterable {
    case created, running, paused, restarting, removing, exited, dead, unknown

    package var isUp: Bool { self == .running || self == .paused || self == .restarting }
    /// Running or paused: the engine has stats for it (a stopped or
    /// restarting one's are empty).
    package var hasStats: Bool { self == .running || self == .paused }
}

/// `GET /containers/{id}/json`: what Inspect, Mounts and the detail read.
package struct ContainerDetail: Codable, Sendable {
    package var Id: String
    package var Name: String
    package var Created: String?
    package var Image: String?
    package var RestartCount: Int?
    package var Platform: String?
    package var State: StateDetail
    package var Config: Config
    package var HostConfig: HostConfigDetail?
    package var Mounts: [DockerMountPoint]?
    package var NetworkSettings: Network?
    /// As the list's (`ContainerSummary.ImageManifestDescriptor`).
    package var ImageManifestDescriptor: ContainerSummary.ManifestDescriptor? = nil

    package struct StateDetail: Codable, Sendable {
        package var Status: String
        package var Running: Bool?
        package var Paused: Bool?
        package var Restarting: Bool?
        package var OOMKilled: Bool?
        package var Dead: Bool?
        package var Pid: Int?
        package var ExitCode: Int?
        package var Error: String?
        package var StartedAt: String?
        package var FinishedAt: String?
        package var Health: Health?
    }

    package struct Health: Codable, Sendable {
        package var Status: String?
        package var FailingStreak: Int?
        package var Log: [Probe]?

        package struct Probe: Codable, Sendable {
            package var Start: String?
            package var End: String?
            package var ExitCode: Int?
            package var Output: String?
        }
    }

    package struct Config: Codable, Sendable {
        package var Image: String?
        package var Env: [String]?
        package var Cmd: [String]?
        package var Entrypoint: [String]?
        package var WorkingDir: String?
        package var User: String?
        package var Labels: [String: String]?
        package var ExposedPorts: [String: EmptyObject]?
        package var Tty: Bool?
        package var Hostname: String?
        package var Healthcheck: HealthConfig?
    }

    /// The image's or the run's health check. Durations in nanoseconds,
    /// as the Engine API says them.
    package struct HealthConfig: Codable, Sendable {
        package var Test: [String]?
        package var Interval: Int?
        package var Timeout: Int?
        package var Retries: Int?
        package var StartPeriod: Int?
    }

    package struct HostConfigDetail: Codable, Sendable {
        package var RestartPolicy: RestartPolicy?
        package var NetworkMode: String?
        package var Memory: Int?
        package var NanoCpus: Int?
        /// What it publishes when it runs, by `3000/tcp`. Kept while it is
        /// stopped, when the list's ports are gone: those exist only while
        /// it runs.
        package var PortBindings: [String: [PortBinding]?]?
        /// `-P`: every exposed port, to a port the engine picks.
        package var PublishAllPorts: Bool?
        /// Memory and swap together; -1 is swap without a limit, 0 none set
        /// (a container with no memory limit has 0).
        package var MemorySwap: Int?
        /// `--cpu-quota` over `--cpu-period` (µs), Compose's `cpu_quota`:
        /// a CPU limit set another way than `NanoCpus`.
        package var CpuQuota: Int?
        package var CpuPeriod: Int?
        /// `--rm`.
        package var AutoRemove: Bool?

        package struct RestartPolicy: Codable, Equatable, Sendable {
            package var Name: String?
            package var MaximumRetryCount: Int?
        }

        /// `""` for either: every address, a port the engine picks.
        package struct PortBinding: Codable, Sendable {
            package var HostIp: String?
            package var HostPort: String?
        }
    }

    package struct Network: Codable, Sendable {
        package var Networks: [String: Endpoint]?

        package struct Endpoint: Codable, Sendable {
            package var IPAddress: String?
            package var Gateway: String?
            package var MacAddress: String?
        }
    }

    package var name: String { Name.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    package var env: [(key: String, value: String)] {
        (self.Config.Env ?? []).map { entry in
            guard let equals = entry.firstIndex(of: "=") else { return (entry, "") }
            return (String(entry[..<equals]), String(entry[entry.index(after: equals)...]))
        }
    }
}

/// `{}` in Docker's maps (`ExposedPorts`, `Volumes`).
package struct EmptyObject: Codable, Hashable, Sendable {}

/// A row of `GET /images/json`.
package struct ImageSummary: Codable, Identifiable, Hashable, Sendable {
    package var Id: String
    package var RepoTags: [String]?
    package var RepoDigests: [String]?
    package var Created: Int
    package var Size: Int
    /// -1 when the engine wasn't asked to count.
    package var Containers: Int?
    package var Labels: [String: String]?

    package var id: String { Id }
    package var shortID: String { String(Id.replacingOccurrences(of: "sha256:", with: "").prefix(12)) }
    package var tags: [String] { (RepoTags ?? []).filter { $0 != "<none>:<none>" } }
    package var isDangling: Bool { tags.isEmpty }
}

/// A layer, from `GET /images/{name}/history`.
package struct ImageLayer: Codable, Hashable, Sendable {
    package var Id: String
    package var Created: Int
    package var CreatedBy: String
    package var Tags: [String]?
    package var Size: Int
    package var Comment: String?
}

package struct VolumeList: Codable, Sendable {
    package var Volumes: [VolumeSummary]?
    package var Warnings: [String]?
}

package struct VolumeSummary: Codable, Identifiable, Hashable, Sendable {
    package var Name: String
    package var Driver: String
    package var Mountpoint: String
    package var CreatedAt: String?
    package var Labels: [String: String]?
    package var Scope: String?
    package var UsageData: Usage?

    package struct Usage: Codable, Hashable, Sendable {
        package var Size: Int
        package var RefCount: Int
    }

    package var id: String { Name }
    /// Compose's own: `project_name`.
    package var composeProject: String? { Labels?["com.docker.compose.project"] }
    /// Made for one container's `VOLUME`, unnamed: what a prune removes
    /// unless asked for every unused volume.
    package var isAnonymous: Bool { Labels?["com.docker.volume.anonymous"] != nil }
    /// A hash for a name says nothing; its start does as well.
    package var shortName: String { isAnonymous || (Name.count == 64 && Name.allSatisfy(\.isHexDigit)) ? String(Name.prefix(12)) : Name }
}

package struct NetworkSummary: Codable, Identifiable, Hashable, Sendable {
    package var Name: String
    package var Id: String
    package var Driver: String?
    package var Scope: String?
    package var Internal: Bool?
    package var Attachable: Bool?
    package var Created: String?
    package var Containers: [String: Member]?
    package var Labels: [String: String]?
    package var IPAM: Addressing?

    package struct Member: Codable, Hashable, Sendable {
        package var Name: String?
        package var IPv4Address: String?
    }

    package struct Addressing: Codable, Hashable, Sendable {
        package var Driver: String?
        package var Config: [Pool]?

        package struct Pool: Codable, Hashable, Sendable {
            package var Subnet: String?
            package var Gateway: String?
        }
    }

    package var subnet: String? { IPAM?.Config?.first?.Subnet }

    package var id: String { Id }
    /// The ones Docker makes and keeps: never offered for removal.
    package var isBuiltIn: Bool { ["bridge", "host", "none"].contains(Name) }
}

/// `GET /system/df`.
package struct DockerDiskUsage: Codable, Sendable {
    package var LayersSize: Int?
    package var Images: [ImageSummary]?
    package var Containers: [ContainerUsage]?
    package var Volumes: [VolumeSummary]?
    package var BuildCache: [BuildCacheEntry]?

    package struct ContainerUsage: Codable, Sendable {
        package var Id: String
        package var SizeRw: Int?
    }

    package struct BuildCacheEntry: Codable, Sendable {
        package var ID: String
        package var Size: Int
        package var InUse: Bool?
        package var Shared: Bool?
    }
}

/// `GET /info`, the little of it the UI says.
package struct EngineInfo: Codable, Sendable {
    package var Name: String?
    package var OperatingSystem: String?
    package var ServerVersion: String?
    package var NCPU: Int?
    package var MemTotal: Int?
    package var Containers: Int?
    package var ContainersRunning: Int?
    package var Images: Int?
    /// The host's `uname -m`: aarch64 on Apple silicon, x86_64 (`DockerPlatform(engine:)`).
    package var Architecture: String? = nil
    /// Go's: linux, windows.
    package var OSType: String? = nil
    /// The storage driver's pairs: the containerd image store says
    /// `driver-type io.containerd.snapshotter.v1`, the classic one its
    /// filesystem's.
    package var DriverStatus: [[String]]? = nil

    /// Docker Desktop's default since 4.34, Engine 29's: an image keeps
    /// nothing of the container it was committed from (`DockerCommit`).
    package var containerdStore: Bool { DriverStatus?.contains { $0.contains { $0.hasPrefix("io.containerd.snapshotter") } } == true }
}

/// One line of `GET /events`.
package struct DockerEvent: Codable, Sendable {
    package var `Type`: String
    package var Action: String
    package var Actor: Actor
    package var time: Int?
    package var timeNano: Int?

    package struct Actor: Codable, Sendable {
        package var ID: String
        package var Attributes: [String: String]?
    }

    /// `health_status: healthy` → `health_status`.
    package var verb: String { String(Action.split(separator: ":").first ?? Substring(Action)).trimmingCharacters(in: .whitespaces) }

    /// The events that change what a list shows. Healthchecks run `exec`s
    /// every few seconds (the spike counted 189 in a minute); those, our
    /// own `archive` reads, and a volume's mount at every start or a
    /// network's connect, are left out.
    package static let listed: Set<String> = [
        "create", "start", "restart", "die", "stop", "kill", "pause", "unpause", "destroy", "rename", "health_status", "oom", "update",
        // Images, volumes, networks.
        "pull", "delete", "tag", "untag", "import", "load", "remove", "prune",
    ]

    /// The kinds of thing whose events are read.
    package static let types = ["container", "image", "volume", "network"]
}

/// `GET /containers/{id}/stats`.
package struct ContainerStatsSample: Codable, Sendable {
    package var read: String?
    package var cpu_stats: CPU?
    package var precpu_stats: CPU?
    package var memory_stats: Memory?
    package var networks: [String: NetworkIO]?
    package var blkio_stats: BlockIO?
    package var pids_stats: Pids?

    package struct CPU: Codable, Sendable {
        package var cpu_usage: Usage?
        package var system_cpu_usage: Int?
        package var online_cpus: Int?

        package struct Usage: Codable, Sendable {
            package var total_usage: Int?
        }
    }

    package struct Memory: Codable, Sendable {
        package var usage: Int?
        package var limit: Int?
        package var stats: [String: Int]?
    }

    package struct NetworkIO: Codable, Sendable {
        package var rx_bytes: Int?
        package var tx_bytes: Int?
    }

    package struct BlockIO: Codable, Sendable {
        package var io_service_bytes_recursive: [Entry]?

        package struct Entry: Codable, Sendable {
            package var op: String?
            package var value: Int?
        }
    }

    package struct Pids: Codable, Sendable {
        package var current: Int?
    }
}

/// What a prune freed.
package struct PruneReport: Codable, Sendable {
    package var SpaceReclaimed: Int?
    package var ContainersDeleted: [String]?
    package var ImagesDeleted: [ImageDeleted]?
    package var VolumesDeleted: [String]?
    package var NetworksDeleted: [String]?
    package var CachesDeleted: [String]?

    package struct ImageDeleted: Codable, Sendable {
        package var Untagged: String?
        package var Deleted: String?
    }
}
