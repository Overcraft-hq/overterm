import Foundation

/// Which of the engine's events say a container went wrong on its own —
/// the news worth marking the tab whose checkout it belongs to. Pure.
///
/// A container stopped because someone asked (`docker stop`, compose down,
/// the page's s) gets `kill` before its `die`; one that crashed gets `die`
/// alone. An exit 0 is a container done with its work.
struct DockerAttention: Sendable {
    struct Alert: Equatable, Sendable {
        var container: String
        /// `exited (137)`, `ran out of memory`, `is unhealthy`.
        var detail: String
        /// Its compose project's folder, which says whose checkout it is.
        var workingDir: String?

        var note: String { "\(container) \(detail)" }
    }

    /// How long after a `kill` its `die` is the one asked for: `docker
    /// stop` waits ten seconds before it kills.
    static let asked: TimeInterval = 30

    private var stopping: [String: Date] = [:]
    private var outOfMemory: Set<String> = []

    mutating func note(_ event: DockerEvent, at now: Date = Date()) -> Alert? {
        guard event.Type == "container" else { return nil }
        let id = event.Actor.ID
        let attributes = event.Actor.Attributes ?? [:]
        let name = attributes["name"] ?? String(id.prefix(12))
        let folder = attributes["com.docker.compose.project.working_dir"]
        stopping = stopping.filter { now.timeIntervalSince($0.value) < Self.asked }
        switch event.verb {
        case "kill", "stop":
            stopping[id] = now
            return nil
        case "oom":
            outOfMemory.insert(id)
            return Alert(container: name, detail: Trouble.outOfMemory.detail, workingDir: folder)
        case "die":
            let asked = stopping.removeValue(forKey: id) != nil
            let said = outOfMemory.remove(id) != nil
            let code = attributes["exitCode"] ?? "0"
            guard code != "0", !asked, !said else { return nil }
            return Alert(container: name, detail: Int(code).map { Trouble.exited($0).detail } ?? "exited (\(code))", workingDir: folder)
        case "health_status":
            return event.Action.hasSuffix("unhealthy") ? Alert(container: name, detail: Trouble.unhealthy.detail, workingDir: folder) : nil
        default:
            return nil
        }
    }

    /// Whether a project run in `workingDir` is the checkout's — run in
    /// it, or the checkout is a folder of it (a tab in `services/api`).
    static func belongs(_ workingDir: String, to checkout: String) -> Bool {
        guard checkout.count > 1, workingDir.count > 1 else { return false }
        return workingDir == checkout || workingDir.hasPrefix(checkout + "/") || checkout.hasPrefix(workingDir + "/")
    }

    /// How closely a tab's checkout matches a project run in `workingDir`,
    /// to rank its agents (lower first): the folder itself, a checkout
    /// inside it, then a repository holding it, the nearest first. A
    /// folder above it that is no repository (`~`, `~/code`) holds every
    /// project there is, so its agent isn't this one's: nil.
    static func closeness(of checkout: String, to workingDir: String, isRepository: Bool) -> Int? {
        guard belongs(workingDir, to: checkout) else { return nil }
        if checkout == workingDir { return 0 }
        if checkout.hasPrefix(workingDir + "/") { return 1 }
        guard isRepository else { return nil }
        return 1 + workingDir.split(separator: "/").count - checkout.split(separator: "/").count
    }
}

/// What is wrong with a container, as far as its list row and its inspect
/// data say: what the list paints red, and what Ask Why asks about. Pure.
extension DockerAttention {
    enum Trouble: Equatable, Sendable {
        case outOfMemory
        /// Its last exit, when known.
        case restarting(exit: Int?)
        case dead
        case exited(Int)
        case unhealthy
        /// Created, and the engine said why it couldn't start it.
        case didNotStart(String)

        /// As an alert says it: `ran out of memory`, `exited (137)`.
        var detail: String {
            switch self {
            case .outOfMemory: "ran out of memory"
            case .restarting: "keeps restarting"
            case .dead: "is dead"
            case .exited(let code): "exited (\(code))"
            case .unhealthy: "is unhealthy"
            case .didNotStart: "didn't start"
            }
        }

        /// The question an agent is started with.
        func question(_ name: String) -> String {
            switch self {
            case .outOfMemory: "Why did \(name) run out of memory?"
            case .restarting: "Why does \(name) keep restarting?"
            case .dead: "Why is \(name) dead?"
            case .exited(let code): "Why did \(name) exit with code \(code)?"
            case .unhealthy: "Why is \(name) unhealthy?"
            case .didNotStart: "Why didn't \(name) start?"
            }
        }
    }

    /// The first that holds, in this order: out of memory (only inspect
    /// says it), restarting, dead, exited non-zero, unhealthy while it
    /// runs, created with the engine's error. From the summary alone it is
    /// what the list paints red, and restarting. `detail` is used only
    /// when it is this container's.
    static func trouble(of container: ContainerSummary, detail: ContainerDetail? = nil) -> Trouble? {
        let detail = detail?.Id == container.Id ? detail : nil
        if detail?.State.OOMKilled == true { return .outOfMemory }
        switch container.state {
        case .restarting: return .restarting(exit: restartingExit(container.Status) ?? detail?.State.ExitCode)
        case .dead: return .dead
        case .exited:
            if let code = container.exitCode ?? detail?.State.ExitCode, code != 0 { return .exited(code) }
            return nil
        case .running where container.health == "unhealthy": return .unhealthy
        case .created:
            if let error = detail?.State.Error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty { return .didNotStart(error) }
            return nil
        default: return nil
        }
    }

    /// `Restarting (1) 5 seconds ago` → 1, as moby writes it.
    static func restartingExit(_ status: String) -> Int? {
        guard status.hasPrefix("Restarting ("), let close = status.firstIndex(of: ")") else { return nil }
        return Int(status[status.index(status.startIndex, offsetBy: "Restarting (".count)..<close])
    }
}
