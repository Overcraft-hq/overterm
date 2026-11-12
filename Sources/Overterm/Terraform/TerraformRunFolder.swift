import Darwin
import Foundation

/// Where a plan is written for the seconds before Overterm holds it by a
/// descriptor (analysis 4.4, D-5): `$TMPDIR/ot-tf-<uid>-<pid>/`, made 0700,
/// one for the app's process, a run folder per plan inside it. Never the
/// support folder, never kept: once `plan` exits the file is opened,
/// hashed and unlinked, and its folder removed. A guarded run's base is
/// its own support directory (`AppEnvironment.terraformRunsBase`), so a
/// scenario never touches the user's app's folder. At launch a sweep
/// removes only the folders of this user whose process is gone.
enum TerraformRunFolder {
    static let prefix = "ot-tf-"

    static func name(uid: uid_t = getuid(), pid: pid_t = getpid()) -> String { "\(prefix)\(uid)-\(pid)" }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case unsafe(String)
        case create(Int32)

        var description: String {
            switch self {
            case .unsafe(let why): "the plan folder isn't safe: \(why)"
            case .create(let code): "the plan folder can't be made: \(String(cString: strerror(code)))"
            }
        }
    }

    /// Makes `url` a folder of this user's, 0700, or checks the one there
    /// is: a directory (never a link), owned by this user, mode 0700.
    static func ensurePrivate(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0, errno != EEXIST { throw Failure.create(errno) }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw Failure.create(errno) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafe("\(url.lastPathComponent) isn't a folder") }
        guard info.st_uid == getuid() else { throw Failure.unsafe("\(url.lastPathComponent) belongs to another user") }
        if info.st_mode & 0o777 != 0o700 {
            guard chmod(url.path, 0o700) == 0 else { throw Failure.unsafe("\(url.lastPathComponent) is open to others") }
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _crashedProcess: pid_t?

    /// A scenario's "crashed Overterm" (4.7): new runs' process folder
    /// names this pid, one that is gone, instead of the app's — so the
    /// launch's sweep finds their applies as another launch's. Isolated
    /// runs only; nil otherwise.
    static var crashedProcess: pid_t? {
        get { AppEnvironment.guardsTerraform ? lock.withLock { _crashedProcess } : nil }
        set { lock.withLock { _crashedProcess = newValue } }
    }

    /// This process's folder under `base`.
    static func processFolder(base: URL = AppEnvironment.terraformRunsBase) throws -> URL {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let folder = base.appendingPathComponent(name(pid: crashedProcess ?? getpid()), isDirectory: true)
        try ensurePrivate(folder)
        return folder
    }

    /// A new run's folder, 0700, inside this process's.
    static func makeRun(base: URL = AppEnvironment.terraformRunsBase) throws -> URL {
        let run = try processFolder(base: base).appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try ensurePrivate(run)
        return run
    }

    /// A run's folder gone, and whatever terraform left in it.
    static func remove(_ run: URL) {
        try? FileManager.default.removeItem(at: run)
    }

    /// Which of `names` (a base folder's) to sweep: this user's process
    /// folders whose process is gone — never this process's, never
    /// another user's, never anything that isn't one. Pure.
    static func sweepable(_ names: [String], uid: uid_t, me: pid_t, alive: (pid_t) -> Bool) -> [String] {
        names.filter { name in
            guard name.hasPrefix(prefix) else { return false }
            let parts = name.dropFirst(prefix.count).split(separator: "-")
            guard parts.count == 2, let owner = uid_t(parts[0]), let pid = pid_t(parts[1]), owner == uid, pid != me, pid > 0 else { return false }
            return !alive(pid)
        }
    }

    static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// At launch: the folders a crashed Overterm left — but never a run
    /// folder whose detached apply is still alive (4.7): those are kept,
    /// and returned, to be followed again. Blocking (a few stats): off
    /// the main thread.
    @discardableResult
    static func sweep(base: URL = AppEnvironment.terraformRunsBase) -> [(folder: URL, marker: TerraformApplyMarker)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        var alive: [(URL, TerraformApplyMarker)] = []
        for name in sweepable(names, uid: getuid(), me: getpid(), alive: isAlive) {
            let url = base.appendingPathComponent(name, isDirectory: true)
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { continue }
            var kept = false
            for run in ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).prefix(256) {
                let folder = url.appendingPathComponent(run, isDirectory: true)
                if let marker = TerraformApplyMarker.read(folder), TerraformApplyMarker.liveNow(marker) {
                    alive.append((folder, marker))
                    kept = true
                } else {
                    try? FileManager.default.removeItem(at: folder)
                }
            }
            if !kept { try? FileManager.default.removeItem(at: url) }
        }
        return alive
    }
}
