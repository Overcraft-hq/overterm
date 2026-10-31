import Foundation

/// What Clean Up would remove, listed before anything goes — the engine's
/// own prunes say what they removed only afterwards. Pure.
///
/// The engine's rules: stopped containers; images no container uses (only
/// untagged ones unless every unused one is asked for — and an image whose
/// only users are stopped containers that go too is unused by then);
/// volumes no container mounts (only anonymous ones unless named ones are
/// asked for); networks of our own nobody is on; build cache not in use.
struct DockerPrunePlan: Equatable, Sendable {
    struct Choice: Equatable, Sendable {
        var containers = true
        var images = true
        /// Tagged images too, not only `<none>`.
        var allImages = false
        var volumes = false
        /// Named volumes too, not only anonymous ones.
        var namedVolumes = false
        var networks = true
        var buildCache = true
    }

    var containers: [ContainerSummary] = []
    var images: [ImageSummary] = []
    var volumes: [VolumeSummary] = []
    var networks: [NetworkSummary] = []
    var buildCache = 0

    var isEmpty: Bool { containers.isEmpty && images.isEmpty && volumes.isEmpty && networks.isEmpty && buildCache == 0 }

    /// Bytes it frees, as the engine counts them: images' own sizes (a
    /// layer another image shares stays, so this is at most), volumes'
    /// data, the cache.
    var reclaimable: Int {
        images.reduce(0) { $0 + $1.Size } + volumes.reduce(0) { $0 + ($1.UsageData?.Size ?? 0) } + buildCache
    }

    static func make(
        _ choice: Choice, containers: [ContainerSummary], images: [ImageSummary], volumes: [VolumeSummary], networks: [NetworkSummary],
        buildCache: [DockerDiskUsage.BuildCacheEntry]
    ) -> DockerPrunePlan {
        var plan = DockerPrunePlan()
        let stopped = containers.filter { !$0.state.isUp }
        if choice.containers { plan.containers = stopped }
        // What still exists once the plan's containers are gone.
        let gone = Set(plan.containers.map(\.Id))
        let left = containers.filter { !gone.contains($0.Id) }
        if choice.images {
            let used = Set(left.compactMap(\.ImageID))
            plan.images = images.filter { !used.contains($0.Id) && (choice.allImages || $0.isDangling) }
        }
        if choice.volumes {
            let mounted = Set(left.flatMap { ($0.Mounts ?? []).compactMap(\.Name) })
            plan.volumes = volumes.filter { !mounted.contains($0.Name) && (choice.namedVolumes || $0.isAnonymous) }
        }
        if choice.networks {
            // A container keeps its networks while it exists, stopped too;
            // a network's own record lists only running members.
            let names = Set(left.flatMap(\.networkNames))
            let ids = Set(left.flatMap { ($0.NetworkSettings?.Networks ?? [:]).values.compactMap(\.NetworkID) })
            plan.networks = networks.filter {
                !$0.isBuiltIn && !names.contains($0.Name) && !ids.contains($0.Id) && ($0.Containers ?? [:]).isEmpty
            }
        }
        if choice.buildCache { plan.buildCache = buildCache.filter { $0.InUse != true && $0.Shared != true }.reduce(0) { $0 + $1.Size } }
        return plan
    }
}
