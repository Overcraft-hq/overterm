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
    /// running containers' host ports, each once, by number. A port Up on
    /// Free Ports moved says where it came from (`overrides`, by project).
    static func ports(of projects: [ComposeProject], overrides: [String: ComposePortOverride] = [:]) -> [ListeningPort] {
        var seen = Set<Int>()
        var ports: [ListeningPort] = []
        for project in projects {
            let moves = overrides[project.name]?.moves ?? []
            for container in project.containers where container.state == .running {
                for port in PublishedPort.of(container.Ports ?? []) where port.proto == "tcp" && seen.insert(port.hostPort).inserted {
                    let moved = moves.first { $0.service == container.composeService && $0.to == port.hostPort && $0.proto == port.proto }
                    ports.append(
                        ListeningPort(
                            pid: 0, process: container.composeService ?? container.name, port: port.hostPort, address: port.hostIP ?? "*",
                            container: container.name, movedFrom: moved?.from))
                }
            }
        }
        return ports.sorted { $0.port < $1.port }
    }

    /// The names `docker compose` looks for at a folder's top, in its order
    /// (compose-go's `DefaultFileNames`)…
    static let composeFileNames = ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"]
    /// …and the override it adds to the first of them found
    /// (`DefaultOverrideFileNames`).
    static let overrideFileNames = ["compose.override.yml", "compose.override.yaml", "docker-compose.override.yml", "docker-compose.override.yaml"]

    /// The compose file at a folder's top, as `docker compose` looks for it.
    static func composeFile(in folder: URL) -> URL? {
        composeFiles(in: folder).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The files `docker compose` reads in `folder` when it is given none,
    /// in its order: `COMPOSE_FILE` in the folder's `.env` (split on
    /// `COMPOSE_PATH_SEPARATOR`, else `:`; relative to the folder), else
    /// the first default name there and the first override name. Passing
    /// files with `-f` turns that search off, so whoever passes them passes
    /// these. The shell's own `COMPOSE_FILE` isn't seen.
    static func composeFiles(in folder: URL) -> [URL] {
        let env = dotEnv(in: folder)
        if let list = env["COMPOSE_FILE"], !list.isEmpty {
            let separator = env["COMPOSE_PATH_SEPARATOR"].flatMap { $0.isEmpty ? nil : $0 } ?? ":"
            var files: [URL] = []
            for part in list.components(separatedBy: separator) where !part.isEmpty {
                let path = (part as NSString).expandingTildeInPath
                files.append(path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path))
            }
            return files.map(\.standardizedFileURL)
        }
        var files: [URL] = []
        for name in composeFileNames {
            let file = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                files.append(file)
                break
            }
        }
        guard !files.isEmpty else { return [] }
        for name in overrideFileNames {
            let file = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                files.append(file)
                break
            }
        }
        return files
    }

    /// The folder Compose makes a checkout's project of: its first file's,
    /// as a real path (what the labels' `working_dir` says). Nil with no
    /// compose file.
    static func projectFolder(in checkout: URL) -> String? {
        composeFiles(in: checkout).first.map { FileTreeModel.realPath($0.deletingLastPathComponent()) }
    }

    /// A compose file's path as Compose takes it, to pass with `-f`: its
    /// folder a real path, the file as named. A link stays a link: Compose
    /// resolves none (`filepath.Abs`), so a linked `compose.yaml` keeps
    /// the checkout as its project folder — its build contexts, its mounts,
    /// its `.env` and its name. Given the target, they would all be the
    /// target's folder's.
    static func composePath(_ file: URL) -> String {
        let folder = FileTreeModel.realPath(file.deletingLastPathComponent())
        return (folder.hasSuffix("/") ? folder : folder + "/") + file.lastPathComponent
    }

    /// The folder's `.env`, as Compose reads it for itself (`COMPOSE_FILE`,
    /// `COMPOSE_PROFILES`, `COMPOSE_PROJECT_NAME`).
    static func dotEnv(in folder: URL) -> [String: String] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(".env"), encoding: .utf8) else { return [:] }
        return DotEnv.parse(text)
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
