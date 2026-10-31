import Combine
import CryptoKit
import Foundation

/// The checkouts whose stacks run on ports of their own (Up on Free Ports),
/// in Overterm's own folder — never in the repository: `index.json` and one
/// override file a checkout, `<project>-<hash of its folder>.yaml`, passed
/// to Compose with `-f` after the checkout's files. Every compose command
/// that reads files is made here (`command`), so each Up, Pull or config
/// from Overterm uses the same files, and a forgotten override — its path
/// still in the containers' `config_files` label — is left out. An
/// override is written again from its files when they change, before
/// whatever reads them next (`refresh`).
@MainActor
final class ComposePortStore: ObservableObject {
    static let shared = ComposePortStore()

    /// By Compose's project folder (a real path).
    @Published private(set) var overrides: [String: ComposePortOverride] = [:]
    let folder: URL
    /// The folder as given and as a real path: what a path of ours starts with.
    private var roots: [String] = []
    /// The overrides being written again from their files (`refresh`).
    private var refreshing: [String: Task<Void, Never>] = [:]

    /// Reads the index and nothing else: unit tests reach the real support
    /// folder through `shared`, so nothing is written until something is
    /// saved, forgotten or pruned.
    init(folder: URL = AppEnvironment.supportDirectory.appendingPathComponent("Compose", isDirectory: true).appendingPathComponent("Ports", isDirectory: true)) {
        self.folder = folder
        overrides = Self.read(folder.appendingPathComponent("index.json"))
        updateRoots()
    }

    private var index: URL { folder.appendingPathComponent("index.json") }

    private static func read(_ url: URL) -> [String: ComposePortOverride] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let list = try decoder.decode([ComposePortOverride].self, from: Data(contentsOf: url))
            return Dictionary(list.map { ($0.folder, $0) }, uniquingKeysWith: { _, last in last })
        } catch {
            UnreadableFile.setAside(url)
            return [:]
        }
    }

    private func updateRoots() {
        let real = FileTreeModel.realPath(folder)
        roots = Array(Set([folder.path, real])).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
    }

    // MARK: Which

    /// Its override file: named for the project and its folder, the same
    /// from one launch to the next (it is in the containers' labels).
    func file(of override: ComposePortOverride) -> URL {
        let hash = SHA256.hash(data: Data(override.folder.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let name = ComposePortPlan.slug(override.project)
        return folder.appendingPathComponent("\(name.isEmpty ? "project" : name)-\(hash).yaml")
    }

    /// Whether a compose file is one of these overrides.
    func isOurs(_ path: String) -> Bool {
        roots.contains { path.hasPrefix($0) }
    }

    /// The one kept for a Compose project folder.
    func override(in folder: String) -> ComposePortOverride? { overrides[folder] }

    /// The one a project runs with: its folder's, under its name — or the
    /// one its containers were made with, by its file. A project before it
    /// runs is its checkout's, by the folder Compose makes the project of
    /// (`COMPOSE_FILE` in `.env` may name a file in a subfolder), as its
    /// Up and its plan's read find it.
    func override(of project: ComposeProject) -> ComposePortOverride? {
        if project.planned {
            guard !overrides.isEmpty, let checkout = project.workingDir,
                let folder = ComposeProjects.projectFolder(in: URL(fileURLWithPath: checkout))
            else { return nil }
            return overrides[folder]
        }
        if let folder = project.workingDir, let kept = overrides[folder], kept.project == project.name { return kept }
        let names = Set(project.configFiles.filter(isOurs).map { ($0 as NSString).lastPathComponent })
        guard !names.isEmpty else { return nil }
        return overrides.values.first { names.contains(file(of: $0).lastPathComponent) }
    }

    /// The projects' overrides, by project name.
    func overrides(of projects: [ComposeProject]) -> [String: ComposePortOverride] {
        var found: [String: ComposePortOverride] = [:]
        for project in projects {
            if let kept = override(of: project) { found[project.name] = kept }
        }
        return found
    }

    /// The ports the other checkouts' overrides give out: never given twice,
    /// running or not.
    func reservedPorts(except folder: String) -> Set<Int> {
        Set(overrides.values.filter { $0.folder != folder }.flatMap { $0.moves.map(\.to) })
    }

    /// The other checkouts' names, each with its folder.
    func reservedNames(except folder: String) -> [String: String] {
        var names: [String: String] = [:]
        for kept in overrides.values where kept.folder != folder { names[kept.project] = kept.folder }
        return names
    }

    // MARK: Files

    /// A project's compose files as Compose should be given them: its own
    /// (a forgotten override's left out), then the one kept, if any.
    func files(for project: ComposeProject) -> [String] {
        var files = project.configFiles.filter { !isOurs($0) }
        guard let kept = override(of: project) else { return files }
        if files.isEmpty { files = base(of: project, kept) }
        return files + [file(of: kept).path]
    }

    /// What an override is read with and written from, before it: a
    /// project before it runs is its checkout's files as Compose finds them
    /// now — a `compose.override.yaml` added since is one of them, as it is
    /// in the plan's read — else the ones it was made from.
    func base(of project: ComposeProject, _ kept: ComposePortOverride) -> [String] {
        guard project.planned, let checkout = project.workingDir else { return kept.baseFiles }
        let files = ComposeProjects.composeFiles(in: URL(fileURLWithPath: checkout))
        return files.isEmpty ? kept.baseFiles : files.map(ComposeProjects.composePath)
    }

    /// A compose verb for a project, with the files it should read. One
    /// before it runs is its folder's files, no `-p` (`DockerCommands`) —
    /// unless its checkout has an override: its name then, and its files.
    func command(
        _ project: ComposeProject, _ verb: String, services: [String] = [], profiles: [String] = [], endpoint: DockerEndpoint?
    ) -> String {
        if project.planned, let kept = override(of: project) {
            return DockerCommands.compose(name: kept.project, files: files(for: project), verb, services: services, profiles: profiles, endpoint: endpoint)
        }
        return DockerCommands.compose(project, verb, services: services, profiles: profiles, endpoint: endpoint, files: files(for: project))
    }

    // MARK: As the files are now

    /// Its base files and their folder's `.env` by size and date, a link
    /// by what it points at (what is edited): what the override was
    /// written from.
    nonisolated static func stamp(of files: [String], folder: String) -> [String: String] {
        var stamp: [String: String] = [:]
        for path in files + [(folder as NSString).appendingPathComponent(".env")] {
            let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if let attributes = try? FileManager.default.attributesOfItem(atPath: target) {
                let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
                let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                stamp[path] = "\(size):\(date)"
            } else {
                stamp[path] = "-"
            }
        }
        return stamp
    }

    /// Whether the files changed since it was written: `base`, the files
    /// it is read with now (`base(of:_:)`), not the same list, or one of
    /// them edited.
    func isStale(_ kept: ComposePortOverride, base: [String]? = nil) -> Bool {
        let base = base ?? kept.baseFiles
        return base != kept.baseFiles || kept.stamp != Self.stamp(of: base, folder: kept.folder)
    }

    /// Whether a project's override must be written again before a command
    /// reads it (`refresh`).
    func needsRefresh(_ project: ComposeProject) -> Bool {
        guard let kept = override(of: project) else { return false }
        return isStale(kept, base: base(of: project, kept))
    }

    /// A project's override as its files are now (`refresh`).
    func refresh(for project: ComposeProject, endpoint: DockerEndpoint?) async {
        if let kept = override(of: project) { await refresh(kept.folder, endpoint: endpoint, base: base(of: project, kept)) }
    }

    /// The folder's override written again from its files when they changed
    /// since — before any command that reads them, not only an Up: Compose
    /// refuses an override naming a service the files no longer have, and
    /// `!override` would pin a service's old ports. Compose reads the base
    /// files (`readConfig`); each move stays while its service still
    /// publishes that port, a service gone is dropped, the moved services'
    /// other ports are the files' now (`ComposePortPlan.refreshed`).
    /// Nothing is looked at or moved: that is an Up's. Forgotten when
    /// nothing is left of it; left as it was when Compose can't read the
    /// files — the command says why. One read at a time a folder.
    func refresh(_ folder: String, endpoint: DockerEndpoint?, base: [String]? = nil) async {
        guard let kept = overrides[folder] else { return }
        let base = base ?? kept.baseFiles
        guard isStale(kept, base: base) else { return }
        if let reading = refreshing[folder] { return await reading.value }
        let task = Task { [weak self] in
            guard DockerPageModel.mayCheckPorts, let cli = DockerCLI(endpoint: endpoint) else { return }
            let stamp = Self.stamp(of: base, folder: folder)
            guard let config = await Self.readConfig(cli, base: base, folder: folder), let self, self.overrides[folder] == kept else { return }
            let plan = ComposePortPlan.refreshed(kept, config: config)
            guard plan.changes else { return self.forget(folder) }
            var next = kept
            next.fileName = config.name
            next.moves = plan.moves
            next.baseFiles = base
            next.stamp = stamp
            try? self.save(next, yaml: ComposePorts.overrideYAML(plan: plan, config: config, folder: folder))
        }
        refreshing[folder] = task
        await task.value
        refreshing[folder] = nil
    }

    /// What a stack would publish, every profile's: Compose's own reading
    /// of the checkout's files (none of ours), env files left out. Decoded
    /// and dropped: what an Up looks at, and what an override is written
    /// from.
    static func readConfig(_ cli: DockerCLI, base: [String], folder: String) async -> ComposeConfig? {
        let arguments = ["compose"] + base.flatMap { ["-f", $0] } + ["--profile", "*", "config", "--format", "json"]
        guard let json = try? await cli.composeConfig(arguments, in: URL(fileURLWithPath: folder), timeout: 15) else { return nil }
        return try? ComposeConfig.parse(json)
    }

    // MARK: Changes

    /// The override file, then the index, each written whole.
    func save(_ override: ComposePortOverride, yaml: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        updateRoots()
        if let old = overrides[override.folder], file(of: old) != file(of: override) { try? FileManager.default.removeItem(at: file(of: old)) }
        try Data(yaml.utf8).write(to: file(of: override), options: .atomic)
        var next = overrides
        next[override.folder] = override
        try write(next)
        overrides = next
    }

    /// Back to the file's ports: the record and its file go.
    func forget(_ folder: String) {
        guard let old = overrides[folder] else { return }
        var next = overrides
        next[folder] = nil
        try? write(next)
        try? FileManager.default.removeItem(at: file(of: old))
        overrides = next
    }

    /// The overrides of folders that are gone (a worktree removed). The
    /// app asks once a launch; reading never does.
    func prune() {
        let gone = overrides.keys.filter { !FileManager.default.fileExists(atPath: $0) }
        guard !gone.isEmpty else { return }
        var next = overrides
        for folder in gone {
            if let old = next.removeValue(forKey: folder) { try? FileManager.default.removeItem(at: file(of: old)) }
        }
        try? write(next)
        overrides = next
    }

    private func write(_ overrides: [String: ComposePortOverride]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(overrides.values.sorted { $0.folder < $1.folder }).write(to: index, options: .atomic)
    }
}
