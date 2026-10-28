import Foundation

/// A compose project as its containers' labels describe it. Compose keeps
/// no other record — `docker compose ls` reads the same labels — so a
/// project is there while one of its containers is, running or not.
struct ComposeProject: Identifiable, Equatable, Sendable {
    var name: String
    /// Where `compose up` ran, as Compose resolved it (`/private/tmp/…`,
    /// the spike): compared with a checkout's real path.
    var workingDir: String?
    var configFiles: [String]
    var services: [ComposeService]
    /// Made from a checkout's compose files (`ComposeConfig`) before any
    /// of its containers exist: its services have none, and `up` runs in
    /// its folder without `-f`.
    var planned = false

    var id: String { name }
    var containers: [ContainerSummary] { services.flatMap(\.containers) }
    var running: Int { containers.filter { $0.state == .running }.count }

    /// The containers it is made of, one-offs left out — for a project
    /// before it runs, the ones `up` would make, replicas counted.
    var expected: Int {
        planned ? services.reduce(0) { $0 + ($1.spec?.replicas ?? 1) } : containers.filter { !$0.isOneOff }.count
    }

    enum Status: Equatable, Sendable { case running, partial, stopped }

    /// Every container up, some, none — one-offs (`compose run`) left out:
    /// one that finished doesn't make the stack partial.
    var status: Status {
        let lasting = containers.filter { !$0.isOneOff }
        let up = lasting.filter { $0.state.isUp }.count
        if up == 0 { return .stopped }
        return up == lasting.count ? .running : .partial
    }

    /// Something wrong in it: a service exited non-zero, unhealthy, or
    /// left `created` (a port already taken leaves it there, the spike).
    var failing: [ContainerSummary] {
        containers.filter { container in
            !container.isOneOff
                && (container.health == "unhealthy" || container.state == .dead || (container.exitCode.map { $0 != 0 } ?? false)
                    || container.state == .created)
        }
    }
}

struct ComposeService: Identifiable, Equatable, Sendable {
    var project: String
    var name: String
    /// Its replicas by container number, `compose run`'s one-offs after.
    var containers: [ContainerSummary]
    /// The services it waits for (`com.docker.compose.depends_on`).
    var dependsOn: [String]
    /// What the compose files say of it, for a project before it runs.
    var spec: ComposeConfig.Service? = nil

    var id: String { project + "/" + name }
}

/// The projects among the containers, and the containers in none. Pure.
enum ComposeProjects {
    static func group(_ containers: [ContainerSummary]) -> (projects: [ComposeProject], loose: [ContainerSummary]) {
        var byProject: [String: [ContainerSummary]] = [:]
        var loose: [ContainerSummary] = []
        for container in containers {
            if let project = container.composeProject, !project.isEmpty {
                byProject[project, default: []].append(container)
            } else {
                loose.append(container)
            }
        }
        let projects = byProject.keys.sorted().map { name in
            let members = byProject[name] ?? []
            let services = Dictionary(grouping: members) { $0.composeService ?? $0.name }
                .map { service, containers in
                    ComposeService(
                        project: name, name: service, containers: containers.sorted(by: replicaOrder),
                        dependsOn: dependencies(containers.lazy.compactMap { $0.labels["com.docker.compose.depends_on"] }.first))
                }
                .sorted { $0.name < $1.name }
            // The newest container says where the project is now: one made
            // before a move (or in another worktree of the same name) may
            // still carry the old folder.
            let newest = members.max { $0.Created < $1.Created }
            let files = newest?.labels["com.docker.compose.project.config_files"] ?? ""
            return ComposeProject(
                name: name, workingDir: newest?.composeWorkingDir, configFiles: files.split(separator: ",").map(String.init), services: services)
        }
        return (projects, loose.sorted { $0.name < $1.name })
    }

    /// What a checkout's projects publish, as a pane header shows ports:
    /// running containers' host ports, each once, by number.
    static func ports(of projects: [ComposeProject]) -> [ListeningPort] {
        var seen = Set<Int>()
        var ports: [ListeningPort] = []
        for project in projects {
            for container in project.containers where container.state == .running {
                for port in PublishedPort.of(container.Ports ?? []) where port.proto == "tcp" && seen.insert(port.hostPort).inserted {
                    ports.append(
                        ListeningPort(
                            pid: 0, process: container.composeService ?? container.name, port: port.hostPort, address: port.hostIP ?? "*",
                            container: container.name))
                }
            }
        }
        return ports.sorted { $0.port < $1.port }
    }

    /// The names `docker compose` looks for at a folder's top, in its order.
    static let composeFileNames = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]

    /// The compose file at a folder's top, as `docker compose` looks for it.
    static func composeFile(in folder: URL) -> URL? {
        composeFileNames.lazy.map { folder.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Whether a project from labels takes the place of a checkout's project
    /// before it runs (`planned`): it has its name, or it was made from the
    /// same compose file under another (`-p`, a `COMPOSE_PROJECT_NAME` in
    /// the shell). The plan's Up would then make a second copy of the same
    /// services, its ports already taken. Pure.
    static func replaces(_ project: ComposeProject, _ planned: ComposeProject) -> Bool {
        if project.name == planned.name { return true }
        guard let folder = planned.workingDir else { return false }
        let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        if project.configFiles.isEmpty { return project.workingDir == base }
        let files = Set(composeFileNames.map { base + "/" + $0 })
        return project.configFiles.contains(where: files.contains)
    }

    /// `db:service_started:false,cache:service_healthy:true` → db, cache.
    static func dependencies(_ label: String?) -> [String] {
        (label ?? "").split(separator: ",").compactMap { $0.split(separator: ":").first.map(String.init) }.filter { !$0.isEmpty }
    }

    private static func replicaOrder(_ a: ContainerSummary, _ b: ContainerSummary) -> Bool {
        if a.isOneOff != b.isOneOff { return !a.isOneOff }
        let na = Int(a.labels["com.docker.compose.container-number"] ?? "") ?? 0
        let nb = Int(b.labels["com.docker.compose.container-number"] ?? "") ?? 0
        return na != nb ? na < nb : a.Created < b.Created
    }

    /// The projects a checkout holds: run in it or below it, or from a
    /// compose file in it (`-f` from elsewhere, `--project-directory`).
    /// `checkout` is a real path (FileTreeModel.realPath).
    static func projects(_ projects: [ComposeProject], in checkout: String) -> [ComposeProject] {
        guard checkout.count > 1 else { return [] }
        let folder = checkout.hasSuffix("/") ? String(checkout.dropLast()) : checkout
        func inside(_ path: String) -> Bool { path == folder || path.hasPrefix(folder + "/") }
        return projects.filter { project in
            project.workingDir.map(inside) == true || project.configFiles.contains(where: inside)
        }
    }
}
