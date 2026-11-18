import Foundation

/// launchd's socket-activated jobs (docs/design/activity/analysis.md, 6.8
/// Owners rule 9): launchd (pid 1) holds a job's listening socket until a
/// connection starts the job — 8021 is the ftp proxy's, 22 Remote Login's
/// — so nettop names launchd, never the job. Each plist's `Sockets` names
/// the port (`SockServiceName`, a number or a name `/etc/services` gives),
/// the type (`SockType`: stream, TCP, by default; dgram, UDP) and the job's
/// `Label`. Read once, lazily and off the main thread, from the folders
/// `AppEnvironment` gives — `/System/Library/LaunchDaemons`,
/// `/Library/LaunchDaemons`, `/Library/LaunchAgents` and the user's
/// `~/Library/LaunchAgents` — none in an isolated run but a test's own
/// (9.9). Reading the plists is bounded (files, sizes, regular files only,
/// never a link); matching is pure.
enum LaunchdSockets {
    /// Whose job: the system's (a LaunchDaemon: a sudo `launchctl bootout
    /// system/…`), an agent every user loads (`/Library/LaunchAgents`: the
    /// plist the system's, the job loaded into each user's gui domain), or
    /// the user's own LaunchAgent (its gui domain, no sudo — `LaunchdJobs`).
    enum Domain: Hashable, Sendable {
        case system
        case agents
        case user
    }

    /// A job's listening socket.
    struct Job: Hashable, Sendable {
        let label: String
        let port: Int
        /// "tcp" or "udp".
        let proto: String
        let domain: Domain
        /// The user's own job naming the same socket as this one, when both
        /// do: neither is stopped from here (`match`).
        var sharedWith: String?

        /// Apple's own (`com.apple.…`): part of macOS.
        var isApple: Bool { label.hasPrefix("com.apple.") }

        /// "launchd holds :8021 for com.apple.ftp-proxy, part of macOS".
        var sentence: String {
            let held = "launchd holds :\(port) for \(DockerMCP.displayed(label))"
            if let mine = sharedWith {
                return held + " or your job \(DockerMCP.displayed(mine)) — both name it, so neither is stopped from here"
            }
            switch domain {
            case .user: return held + ", your own job: its own stop is `launchctl bootout gui/\(getuid())/\(label)`"
            case .system:
                if isApple { return held + ", part of macOS: turned off where macOS sets it (System Settings ▸ General ▸ Sharing for Remote Login)" }
                return held + ", another's job: `sudo launchctl bootout system/\(label)` stops it"
            case .agents:
                if isApple { return held + ", part of macOS" }
                return held
                    + ", an agent loaded for every user from /Library/LaunchAgents: `launchctl bootout gui/\(getuid())/\(label)` stops yours, and its plist is the system's"
            }
        }
    }

    /// A folder and whose its jobs are.
    struct Folder: Hashable, Sendable {
        let url: URL
        let domain: Domain
    }

    /// The system's folders and the user's LaunchAgents.
    static func defaultFolders(home: URL) -> [Folder] {
        [
            Folder(url: URL(fileURLWithPath: "/System/Library/LaunchDaemons", isDirectory: true), domain: .system),
            Folder(url: URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true), domain: .system),
            Folder(url: URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true), domain: .agents),
            Folder(url: home.appendingPathComponent("Library/LaunchAgents", isDirectory: true), domain: .user),
        ]
    }

    // MARK: Pure

    /// `/etc/services`' names: `name port/proto aliases… # comment`, a name
    /// and each alias to its port by protocol.
    static func services(_ text: String) -> [String: [String: Int]] {
        var found: [String: [String: Int]] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard words.count >= 2 else { continue }
            let parts = words[1].split(separator: "/")
            guard parts.count == 2, let port = Int(parts[0]), (1...65_535).contains(port) else { continue }
            let proto = parts[1].lowercased()
            guard proto == "tcp" || proto == "udp" else { continue }
            for name in [words[0]] + words.dropFirst(2) where found[String(name)]?[proto] == nil {
                found[String(name), default: [:]][proto] = port
            }
        }
        return found
    }

    /// One plist's socket jobs: each listener's port and type; a unix
    /// socket's (`SockPathName`) and one whose service can't be named are
    /// left out.
    static func jobs(from data: Data, domain: Domain, services: [String: [String: Int]]) -> [Job] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let label = plist["Label"] as? String, !label.isEmpty, let sockets = plist["Sockets"] as? [String: Any]
        else { return [] }
        var found: [Job] = []
        for key in sockets.keys.sorted() {
            let entries: [[String: Any]]
            if let one = sockets[key] as? [String: Any] {
                entries = [one]
            } else if let many = sockets[key] as? [[String: Any]] {
                entries = many
            } else {
                continue
            }
            for entry in entries where entry["SockPathName"] == nil {
                let proto = (entry["SockType"] as? String)?.lowercased() == "dgram" ? "udp" : "tcp"
                let port: Int?
                if let number = entry["SockServiceName"] as? Int {
                    port = number
                } else if let name = entry["SockServiceName"] as? String {
                    port = Int(name) ?? services[name]?[proto]
                } else {
                    port = nil
                }
                guard let port, (1...65_535).contains(port) else { continue }
                let job = Job(label: label, port: port, proto: proto, domain: domain)
                if !found.contains(job) { found.append(job) }
            }
        }
        return found
    }

    /// The job whose socket launchd holds on `port`. The user's own plist
    /// is anyone's to write, and may be stale: it names the socket only
    /// when no other job does; when both do, the other's is returned with
    /// the user's named beside it (`sharedWith`) — neither stopped.
    static func job(port: Int, proto: String, in jobs: [Job]) -> Job? {
        let matching = jobs.filter { $0.port == port && $0.proto == proto }
        let mine = matching.first { $0.domain == .user }
        guard var theirs = matching.first(where: { $0.domain != .user }) else { return mine }
        theirs.sharedWith = mine?.label
        return theirs
    }

    // MARK: Read

    /// Every job `folders` describe, `services` naming ports: at most 2,000
    /// plists a folder, each a regular file under 1 MB, sorted by name.
    static func jobs(in folders: [Folder], services: [String: [String: Int]]) -> [Job] {
        var found: [Job] = []
        for folder in folders {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.url.path) else { continue }
            for name in names.sorted().prefix(2_000) where name.hasSuffix(".plist") {
                guard let data = LaunchdJobs.regularFile(folder.url.appendingPathComponent(name).path, limit: 1 << 20) else { continue }
                found += jobs(from: data, domain: folder.domain, services: services)
            }
        }
        return found
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (key: [String], jobs: [Job])?
    nonisolated(unsafe) private static var standInFolders: [Folder]?

    /// A test's folders: the only ones an isolated run reads (9.9).
    static var standIn: [Folder]? {
        get { lock.withLock { standInFolders } }
        set { lock.withLock { standInFolders = newValue } }
    }

    /// `folders`' jobs, read again only when one of them changed — never
    /// from the main thread.
    static func cachedJobs(in folders: [Folder]) -> [Job] {
        guard !folders.isEmpty else { return [] }
        let key = folders.map { folder -> String in
            let modified = (try? FileManager.default.attributesOfItem(atPath: folder.url.path))?[.modificationDate] as? Date
            return "\(folder.url.path)@\(modified?.timeIntervalSince1970 ?? 0)"
        }
        if let known = lock.withLock({ cached }), known.key == key { return known.jobs }
        let text = LaunchdJobs.regularFile("/etc/services", limit: 4 << 20).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let jobs = jobs(in: folders, services: services(text))
        lock.withLock { cached = (key, jobs) }
        return jobs
    }
}
