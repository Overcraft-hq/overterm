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
            return Alert(container: name, detail: "ran out of memory", workingDir: folder)
        case "die":
            let asked = stopping.removeValue(forKey: id) != nil
            let said = outOfMemory.remove(id) != nil
            let code = attributes["exitCode"] ?? "0"
            guard code != "0", !asked, !said else { return nil }
            return Alert(container: name, detail: "exited (\(code))", workingDir: folder)
        case "health_status":
            return event.Action.hasSuffix("unhealthy") ? Alert(container: name, detail: "is unhealthy", workingDir: folder) : nil
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
}
