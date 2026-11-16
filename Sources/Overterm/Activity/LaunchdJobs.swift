import Darwin
import Foundation

/// A launchd job of the user's (docs/design/activity/analysis.md, 6.8
/// rule 8): its label from `XPC_SERVICE_NAME` — launchd sets it to the
/// job's label, a name and no secret, which the census's byte scan reads
/// (9.2) — or, for a process whose environment macOS hides
/// (`CS_RESTRICT`), a user LaunchAgent plist whose `Program` or first
/// `ProgramArguments` is its executable. `homebrew.mxcl.<formula>` is a
/// brew service. The matching is pure; the plists are read off the main
/// thread, at most once a folder change, from the folder `AppEnvironment`
/// gives — none in a test run.
enum LaunchdJobs {
    /// One LaunchAgent plist: its label and the program it runs.
    struct Agent: Hashable, Sendable {
        let label: String
        let program: String
    }

    /// A job as a listener's owner says it.
    struct Job: Hashable, Sendable {
        let label: String

        /// `homebrew.mxcl.postgresql@16` → `postgresql@16`.
        var formula: String? {
            let prefix = "homebrew.mxcl."
            guard label.hasPrefix(prefix), label.count > prefix.count else { return nil }
            return String(label.dropFirst(prefix.count))
        }

        /// "brew service postgresql@16", or "launchd job com.example.dev".
        var title: String { formula.map { "brew service \($0)" } ?? "launchd job \(label)" }
    }

    /// The job `XPC_SERVICE_NAME`'s value names: none for "0" (not a job),
    /// an app's (`application.…`, set by launchd for every app), or empty.
    static func job(service: String?) -> Job? {
        guard let service, !service.isEmpty, service != "0", !service.hasPrefix("application.") else { return nil }
        return Job(label: service)
    }

    /// The job of a process launchd started (`parent` 1) from `path`, by
    /// the LaunchAgents' programs: exactly, never a prefix.
    static func job(path: String?, parent: pid_t, agents: [Agent]) -> Job? {
        guard parent == 1, let path, !path.isEmpty else { return nil }
        return agents.first { $0.program == path }.map { Job(label: $0.label) }
    }

    /// The agents `folder`'s plists describe: each `*.plist`'s `Label` and
    /// `Program` (or `ProgramArguments`' first), the program resolved as
    /// the census's executable path is (Homebrew's `opt/<formula>` link
    /// into its Cellar). A plist that can't be read, or has neither, is
    /// left out. At most 500 files, each a regular file — never a link or
    /// a FIFO — under 1 MB.
    static func agents(in folder: URL) -> [Agent] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        var found: [Agent] = []
        for name in names.sorted().prefix(500) where name.hasSuffix(".plist") {
            guard let data = regularFile(folder.appendingPathComponent(name).path, limit: 1 << 20), let agent = agent(from: data) else { continue }
            found.append(Agent(label: agent.label, program: resolved(agent.program)))
        }
        return found
    }

    /// `path`'s bytes when it is a regular file under `limit`: opened
    /// without following a link and without blocking (a FIFO opens and is
    /// refused), checked on its descriptor, read from it.
    static func regularFile(_ path: String, limit: Int) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size < limit else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while data.count <= limit {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data.count < limit ? data : nil
    }

    /// `program` with its links resolved (`realpath`); as written when it
    /// can't be.
    static func resolved(_ program: String) -> String {
        guard let real = realpath(program, nil) else { return program }
        defer { free(real) }
        return String(cString: real)
    }

    /// One plist's label and program. Pure.
    static func agent(from data: Data) -> Agent? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let label = plist["Label"] as? String, !label.isEmpty
        else { return nil }
        let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
        guard let program, program.hasPrefix("/") else { return nil }
        return Agent(label: label, program: program)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (folder: URL, modified: Date?, agents: [Agent])?

    /// `folder`'s agents, read again only when the folder changed — never
    /// from the main thread (the page's rows are made off it).
    static func cachedAgents(in folder: URL?) -> [Agent] {
        guard let folder else { return [] }
        let modified = (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.modificationDate] as? Date
        if let known = lock.withLock({ cached }), known.folder == folder, known.modified == modified { return known.agents }
        let agents = agents(in: folder)
        lock.withLock { cached = (folder, modified, agents) }
        return agents
    }
}
