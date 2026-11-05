import Foundation

/// One of a pod's containers, as its log's picker offers it: a container,
/// an init container or an ephemeral one, with what its status says.
struct KubeLogContainer: Equatable, Sendable, Identifiable {
    enum Role: String, Equatable, Sendable {
        case container, initContainer, ephemeral

        var title: String {
            switch self {
            case .container: ""
            case .initContainer: "init"
            case .ephemeral: "ephemeral"
            }
        }
    }

    enum State: Equatable, Sendable {
        case running
        case waiting(String)
        case terminated(reason: String, exitCode: Int)
        /// No status for it yet.
        case unknown
    }

    var name: String
    var role: Role
    var restarts: Int
    var state: State
    /// How it last ended, when it restarted: what Previous shows.
    var lastTerminated: String?

    var id: String { name }

    /// A terminated container before this one: Previous has a log to show.
    var hasPrevious: Bool { restarts > 0 || lastTerminated != nil }
}

/// A pod's containers and which one its log shows first. Pure.
enum KubePodContainers {
    /// kubectl's annotation naming the container `logs`, `exec` and `attach` use.
    static let defaultAnnotation = "kubectl.kubernetes.io/default-container"

    /// Its containers, then its init containers, then its ephemeral ones —
    /// each with its status.
    static func of(_ pod: [String: Any]) -> [KubeLogContainer] {
        let spec = pod["spec"] as? [String: Any] ?? [:]
        let status = pod["status"] as? [String: Any] ?? [:]
        var out: [KubeLogContainer] = []
        let groups: [(KubeLogContainer.Role, String, String)] = [
            (.container, "containers", "containerStatuses"), (.initContainer, "initContainers", "initContainerStatuses"),
            (.ephemeral, "ephemeralContainers", "ephemeralContainerStatuses"),
        ]
        for (role, key, statusKey) in groups {
            let statuses = (status[statusKey] as? [[String: Any]] ?? []).reduce(into: [String: [String: Any]]()) { all, item in
                if let name = item["name"] as? String, all[name] == nil { all[name] = item }
            }
            for container in spec[key] as? [[String: Any]] ?? [] {
                guard let name = container["name"] as? String, !name.isEmpty, !out.contains(where: { $0.name == name }) else { continue }
                out.append(Self.container(name, role: role, status: statuses[name]))
            }
        }
        return out
    }

    private static func container(_ name: String, role: KubeLogContainer.Role, status: [String: Any]?) -> KubeLogContainer {
        guard let status else { return KubeLogContainer(name: name, role: role, restarts: 0, state: .unknown) }
        let state = status["state"] as? [String: Any] ?? [:]
        let said: KubeLogContainer.State
        if state["running"] != nil {
            said = .running
        } else if let terminated = state["terminated"] as? [String: Any] {
            said = .terminated(reason: terminated["reason"] as? String ?? "Terminated", exitCode: KubeRollout.int(terminated["exitCode"]) ?? 0)
        } else if let waiting = state["waiting"] as? [String: Any] {
            said = .waiting(waiting["reason"] as? String ?? "Waiting")
        } else {
            said = .unknown
        }
        let last = ((status["lastState"] as? [String: Any])?["terminated"] as? [String: Any]).map { terminated in
            "\(terminated["reason"] as? String ?? "Terminated") (exit \(KubeRollout.int(terminated["exitCode"]) ?? 0))"
        }
        return KubeLogContainer(name: name, role: role, restarts: KubeRollout.int(status["restartCount"]) ?? 0, state: said, lastTerminated: last)
    }

    /// The container a pod's log shows first, as kubectl picks it: the one
    /// its `kubectl.kubernetes.io/default-container` annotation names, if
    /// the pod has it, else its first container. Nil: none at all.
    static func defaultContainer(_ pod: [String: Any]) -> String? {
        let containers = ((pod["spec"] as? [String: Any])?["containers"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let annotations = (pod["metadata"] as? [String: Any])?["annotations"] as? [String: String] ?? [:]
        if let named = annotations[defaultAnnotation]?.trimmingCharacters(in: .whitespaces), containers.contains(named) { return named }
        return containers.first ?? of(pod).first?.name
    }
}

/// How far back a pod's log goes (`sinceSeconds`): Since's choices.
enum KubeLogSince: String, CaseIterable, Identifiable, Sendable {
    case fiveMinutes = "5m"
    case hour = "1h"
    case sixHours = "6h"
    case day = "24h"
    case all

    var id: String { rawValue }

    var seconds: Int? {
        switch self {
        case .fiveMinutes: 300
        case .hour: 3600
        case .sixHours: 6 * 3600
        case .day: 24 * 3600
        case .all: nil
        }
    }

    var title: String {
        switch self {
        case .fiveMinutes: "Last 5 minutes"
        case .hour: "Last hour"
        case .sixHours: "Last 6 hours"
        case .day: "Last 24 hours"
        case .all: "All"
        }
    }
}

/// A `pods/{p}/log` request: always with timestamps — the follower resumes
/// from the last line's and merges by them; shown or not is the view's.
/// `sinceSeconds` or `sinceTime`, never both (the API refuses them
/// together); `tailLines` with either. Pure.
struct KubeLogQuery: Equatable, Sendable {
    var container: String?
    /// The container's last terminated instance: its whole log, not followed.
    var previous = false
    var follow = false
    var tailLines: Int?
    /// At most this many bytes of the answer (`limitBytes`): the server
    /// stops there, so it cuts from the start of the tail — the newest
    /// lines are the ones past it.
    var limitBytes: Int?
    var since: KubeLogSince = .all
    /// From this time on (RFC 3339, whole seconds): a follow resumed.
    var sinceTime: String?

    /// `/api/v1/namespaces/ns/pods/p/log?container=…&follow=true&…`.
    func path(namespace: String, pod: String) -> String {
        let base = KubeResourceKind.pods.path(namespace: namespace, name: pod) + "/log"
        let time = sinceTime
        return KubePath.query(
            base,
            [
                ("container", container), ("follow", follow && !previous ? "true" : nil), ("limitBytes", limitBytes.map(String.init)),
                ("previous", previous ? "true" : nil),
                ("sinceSeconds", time == nil ? since.seconds.map(String.init) : nil), ("sinceTime", time),
                ("tailLines", tailLines.map(String.init)), ("timestamps", "true"),
            ])
    }

    /// The `sinceTime` a follow resumes from: its last line's time to the
    /// second, as the API takes it (`metav1.Time` is whole seconds there) —
    /// that second's lines come again, and the follower drops the ones shown.
    static func sinceTime(after stamp: String) -> String {
        stamp.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    }
}

/// Whether a follow that ended is followed again: the container runs —
/// yes; it is waiting (a restart's back-off) — wait and ask again; it
/// ended for good, or the pod is gone — no, saying so. Pure.
enum KubeLogResume: Equatable, Sendable {
    case follow
    case wait(String)
    case stop(String)

    static let podGone = "The pod is gone: its log ends here."

    /// From the pod read again (nil: it's gone).
    static func of(pod: [String: Any]?, container name: String) -> KubeLogResume {
        guard let pod else { return .stop(podGone) }
        let containers = KubePodContainers.of(pod)
        guard let container = containers.first(where: { $0.name == name }) else { return .stop("The pod has no container \(name) any more.") }
        let spec = pod["spec"] as? [String: Any] ?? [:]
        let phase = (pod["status"] as? [String: Any])?["phase"] as? String ?? ""
        let deleting = (pod["metadata"] as? [String: Any])?["deletionTimestamp"] != nil
        switch container.state {
        case .running:
            return .follow
        case .terminated(let reason, let code):
            let policy = spec["restartPolicy"] as? String ?? "Always"
            let restarts =
                !deleting && phase != "Succeeded" && phase != "Failed" && container.role == .container
                && (policy == "Always" || (policy == "OnFailure" && code != 0))
            if restarts { return .wait("The container ended (\(reason), exit \(code)): waiting for it to start again…") }
            return .stop("The container ended: \(reason) (exit \(code)).")
        case .waiting(let reason):
            if deleting { return .stop("The pod is being deleted.") }
            return .wait("Waiting for the container to start again (\(reason))…")
        case .unknown:
            if deleting { return .stop("The pod is being deleted.") }
            return .wait("Waiting for the container to start…")
        }
    }
}

/// A pod's log's pure pieces: its bytes as lines, what an answer with a
/// larger tail adds before the lines shown, the file Save As suggests.
enum KubeLogText {
    /// Lines out of a stream's bytes: whole ones, the rest kept for the
    /// next piece. A line is `<RFC 3339 time> <text>` (`timestamps=true`).
    struct Splitter: Sendable {
        private var pending = Data()

        mutating func feed(_ piece: Data) -> [LogLine] {
            pending.append(piece)
            guard let last = pending.lastIndex(of: 0x0A) else { return [] }
            let whole = pending[pending.startIndex...last]
            pending = Data(pending[pending.index(after: last)...])
            return KubeLogText.lines(Data(whole))
        }

        /// The stream ended: a last line without its newline.
        mutating func finish() -> [LogLine] {
            defer { pending = Data() }
            return pending.isEmpty ? [] : KubeLogText.lines(pending)
        }
    }

    /// An answer's text as lines: split at `\n` only (a `\r` before it
    /// dropped) — each kubelet line has its own time, and a bare `\r`
    /// (progress output), a form feed or U+2028 inside one is its text, not
    /// a line of its own whose first word would be taken for a time.
    static func lines(_ data: Data) -> [LogLine] {
        data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap { line in
            let text = line.last == 0x0D ? line.dropLast() : line
            guard !text.isEmpty else { return nil }
            return LogLine.parse(String(decoding: text, as: UTF8.self), stream: .stdout, timestamps: true)
        }
    }

    /// The last `keep` bytes of a log's answer, no part of a line: a line
    /// the cut went through is left out up to its first newline (or space,
    /// for one longer than `keep`), and when the server `stopped` at its
    /// limit mid-line, the last back to its last newline (or space). A
    /// secret cut in two is never kept in part, where scrubbing can't
    /// know it.
    static func tail(_ body: Data, keep: Int, stopped: Bool) -> Data {
        var kept = body
        if stopped, kept.last != 0x0A {
            if let newline = kept.lastIndex(of: 0x0A) {
                kept = kept[...newline]
            } else if let space = kept.lastIndex(of: 0x20) {
                kept = kept[..<space]
            } else {
                kept = Data()
            }
        }
        if kept.count > keep {
            kept = kept.suffix(keep)
            // Its own last newline ends the last line, not the cut one.
            let head = kept.last == 0x0A ? kept.dropLast() : kept
            if let newline = head.firstIndex(of: 0x0A) {
                kept = kept[kept.index(after: newline)...]
            } else if let space = head.firstIndex(of: 0x20) {
                kept = kept[kept.index(after: space)...]
            } else {
                kept = Data()
            }
        }
        return Data(kept)
    }

    /// The lines an answer with a larger tail has before `shown`'s first:
    /// up to where `shown` starts in it (its first lines matched, not only
    /// one: a line can say the same twice), else those older than its
    /// first. All of them when nothing is shown.
    static func older(_ fetched: [LogLine], than shown: [LogLine]) -> [LogLine] {
        guard let first = shown.first else { return fetched }
        let run = min(shown.count, 5)
        for index in fetched.indices where fetched[index] == first {
            let after = fetched[index...].prefix(run)
            if Array(after) == Array(shown.prefix(after.count)) { return Array(fetched[..<index]) }
        }
        let stamp = LogFeed.sortable(first.timestamp ?? "")
        return fetched.filter { LogFeed.sortable($0.timestamp ?? "") < stamp }
    }

    /// `web-7d9-app-20261104-153012.log` (`-previous` for the last
    /// terminated one's), the time it was saved, local.
    static func fileName(pod: String, container: String?, previous: Bool, at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let parts = [pod, container, previous ? "previous" : nil, formatter.string(from: date)].compactMap { $0 }
        return String(parts.joined(separator: "-").map { "/:\\".contains($0) ? "_" : $0 }) + ".log"
    }
}

/// What an agent may read of a pod's log lines (⌘L): the pod's own env
/// values that look secret, and what looks like a credential whoever wrote
/// it — a URL's password, a bearer token, a JWT, a PEM block's body, AWS
/// keys, a kubeconfig's `token:`, `client-key-data:` and
/// `client-certificate-data:`, `password=`/`secret:`-style pairs, base64
/// blobs — taken out (`Secrets`). Pure.
enum KubeLogScrub {
    static let mask = "••••••"

    /// The pod's env as the spec writes it: plain `value`s only (a
    /// `secretKeyRef`'s value is never read).
    static func env(of pod: [String: Any]) -> [(key: String, value: String)] {
        let spec = pod["spec"] as? [String: Any] ?? [:]
        var out: [(key: String, value: String)] = []
        for key in ["initContainers", "containers", "ephemeralContainers"] {
            for container in spec[key] as? [[String: Any]] ?? [] {
                for item in container["env"] as? [[String: Any]] ?? [] {
                    if let name = item["name"] as? String, let value = item["value"] as? String { out.append((name, value)) }
                }
            }
        }
        return out
    }

    /// The env's secret values and every URL's password taken out
    /// (`Secrets.scrub`), then what looks like a credential
    /// (`Secrets.scrubCredentials`: tokens, keys, a kubeconfig's fields,
    /// base64 blobs).
    static func scrub(_ text: String, env: [(key: String, value: String)]) -> String {
        Secrets.scrubCredentials(Secrets.scrub(text, env: env))
    }
}
