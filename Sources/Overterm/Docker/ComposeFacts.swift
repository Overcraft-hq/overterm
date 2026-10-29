import Foundation

/// What a compose project's files say that its containers' labels don't:
/// which services `compose watch` would watch, and the profiles the files
/// name. Asked of `docker compose config`, which reads the files and never
/// the engine; its JSON is read by `ComposeConfig`, which keeps no
/// variable's value, and only names are kept here. Pure, but for `stamp`
/// and `read`.
struct ComposeFacts: Equatable, Sendable {
    /// The project's compose files and its `.env`, each with its size and
    /// modification time: a read is due when this changes.
    struct Stamp: Equatable, Sendable {
        var files: [String: String]
    }

    var stamp: Stamp
    /// The services `up` starts that have a `develop.watch` of their own,
    /// sorted: what `compose watch` watches.
    var watched: [String] = []
    /// Every profile the files name, sorted (`config --profiles`).
    var profiles: [String] = []
    /// What Compose said when it couldn't read them, its first line.
    var problem: String?
    /// When the problem isn't the files' — Compose didn't answer in time
    /// or didn't start, or there is no docker — when to ask again: a view's
    /// draw waits till then, a key or a menu item asks at once. One that is
    /// the files' (Compose read them and said no) stands until they change.
    var retry: Date?

    /// How long a view waits before asking again about a problem that
    /// isn't the files'.
    static let retryAfter: TimeInterval = 30

    /// `compose -p <name> -f <file>…`: the project by its labels, its files
    /// as `up` was given them — or as given (`ComposePortStore.files(for:)`:
    /// a forgotten override's path left out). Show Resolved Config asks the
    /// same way.
    static func arguments(_ project: ComposeProject, files: [String]? = nil) -> [String] {
        ["compose", "-p", project.name] + (files ?? project.configFiles).flatMap { ["-f", $0] }
    }

    /// Its files and the `.env` of its folder (where `up` ran, else the
    /// first file's), with their sizes and dates. `.env` counts: it holds
    /// `COMPOSE_PROFILES` and what the files interpolate. Nil when Compose
    /// can't be asked here: no files (a project before it runs is its
    /// plan's, `ComposeConfig`), or none of them on this Mac (a remote
    /// engine's project). A link is stamped by what it points at: Compose
    /// names the link, and it is the target that is edited.
    static func stamp(_ project: ComposeProject) -> Stamp? {
        guard !project.planned, let first = project.configFiles.first else { return nil }
        let folder = project.workingDir ?? (first as NSString).deletingLastPathComponent
        var files: [String: String] = [:]
        var any = false
        for path in project.configFiles + [(folder as NSString).appendingPathComponent(".env")] {
            let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if let attributes = try? FileManager.default.attributesOfItem(atPath: target) {
                if project.configFiles.contains(path) { any = true }
                let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
                let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                files[path] = "\(size):\(date)"
            } else {
                files[path] = "-"
            }
        }
        return any ? Stamp(files: files) : nil
    }

    /// `config --format json` → the services whose `develop.watch` has a
    /// rule; nil when it isn't a project's JSON.
    static func watched(fromConfig json: String) -> [String]? {
        (try? ComposeConfig.parse(json))?.services.filter(\.watched).map(\.name)
    }

    /// `config --profiles` → each once, sorted.
    static func profiles(fromList output: String) -> [String] {
        Array(Set(output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted()
    }

    /// Both asked at once. A failure says Compose's first line (`problem`)
    /// and leaves its list empty; one that isn't the files' is asked again
    /// (`retry`).
    static func read(_ project: ComposeProject, files: [String]? = nil, stamp: Stamp, cli: DockerCLI, timeout: TimeInterval = 15) async -> ComposeFacts {
        let arguments = Self.arguments(project, files: files)
        async let config = outcome { try await cli.composeConfig(arguments + ["config", "--format", "json"], in: home, timeout: timeout) }
        async let listed = outcome { try await cli.composeConfig(arguments + ["config", "--profiles"], in: home, timeout: timeout) }
        var facts = ComposeFacts(stamp: stamp)
        var problems: [String] = []
        var passing = false
        switch await config {
        case .success(let json):
            if let watched = watched(fromConfig: json) { facts.watched = watched } else { problems.append("Compose's config wasn't JSON.") }
        case .failure(let error):
            problems.append(problem(error))
            passing = passing || !isTheFiles(error)
        }
        switch await listed {
        case .success(let output): facts.profiles = profiles(fromList: output)
        case .failure(let error):
            problems.append(problem(error))
            passing = passing || !isTheFiles(error)
        }
        facts.problem = problems.first
        if passing { facts.retry = Date().addingTimeInterval(retryAfter) }
        return facts
    }

    /// Whether Compose ran and said no: the files' problem, which stands
    /// until they change. No answer in time (status -1), a `docker` that
    /// didn't start (env's 126 and 127) or any other error may pass.
    static func isTheFiles(_ error: Error) -> Bool {
        guard let error = error as? GitError else { return false }
        return error.status > 0 && error.status != 126 && error.status != 127
    }

    /// With `-f` the files are found wherever it runs.
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private static func outcome(_ work: @Sendable () async throws -> String) async -> Result<String, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    /// Compose's own words (`ComposeConfig.message`), its first line, short.
    static func problem(_ error: Error) -> String {
        let line = ComposeConfig.message(error).split(whereSeparator: \.isNewline).first.map(String.init) ?? "docker compose config failed."
        return line.count > 200 ? String(line.prefix(199)) + "…" : line
    }
}
