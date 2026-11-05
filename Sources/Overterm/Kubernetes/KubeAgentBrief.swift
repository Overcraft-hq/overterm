import Foundation

// MARK: What is wrong

/// What is wrong with a pod or a Deployment, as its object says it — what
/// Ask Why asks about (docs/design/kubernetes/analysis.md, 3.4). Pure.
enum KubeTrouble: Equatable, Sendable {
    /// Its container keeps exiting and the kubelet backs off restarting it.
    case crashLoop(container: String, exit: Int?)
    /// The kernel killed a container over its memory limit — now, or the
    /// last time it ended (a crash loop of OOM kills says it here).
    case outOfMemory(container: String)
    /// `ImagePullBackOff`, `ErrImagePull`, `ErrImageNeverPull`, `InvalidImageName`.
    case imagePull(container: String, reason: String)
    /// `CreateContainerConfigError`, `CreateContainerError`: a missing
    /// Secret or ConfigMap key, usually.
    case configError(container: String, reason: String)
    /// A container that ended with an error, or the pod failed (Evicted).
    case failed(container: String?, reason: String, exit: Int?)
    /// Not scheduled, or its containers not started.
    case pending
    /// A Deployment past its `progressDeadlineSeconds`.
    case stuckRollout
    /// A Deployment with fewer available replicas than it wants.
    case unavailable(available: Int, desired: Int)

    static let imagePullReasons: Set<String> = ["ImagePullBackOff", "ErrImagePull", "ErrImageNeverPull", "InvalidImageName"]
    static let configReasons: Set<String> = ["CreateContainerConfigError", "CreateContainerError"]
    static let failedReasons: Set<String> = ["RunContainerError", "ContainerCannotRun", "StartError", "PreStartHookError", "PostStartHookError"]

    /// As kubectl says it: `CrashLoopBackOff`, `OOMKilled`, `Pending`.
    var reason: String {
        switch self {
        case .crashLoop: "CrashLoopBackOff"
        case .outOfMemory: "OOMKilled"
        case .imagePull(_, let reason), .configError(_, let reason), .failed(_, let reason, _): reason
        case .pending: "Pending"
        case .stuckRollout: "ProgressDeadlineExceeded"
        case .unavailable(let available, let desired): "Unavailable \(available)/\(desired)"
        }
    }

    /// The container it is about, when it is one's.
    var container: String? {
        switch self {
        case .crashLoop(let container, _), .outOfMemory(let container), .imagePull(let container, _), .configError(let container, _): container
        case .failed(let container, _, _): container
        default: nil
        }
    }

    /// The question an agent is started with; `object` is `pod shop/web-7d9`.
    func question(_ object: String) -> String {
        switch self {
        case .crashLoop: "Why does \(object) keep crashing (CrashLoopBackOff)?"
        case .outOfMemory: "Why does \(object) run out of memory (OOMKilled)?"
        case .imagePull(_, let reason): "Why can't \(object) pull its image (\(reason))?"
        case .configError(_, let reason): "Why can't \(object) create its container (\(reason))?"
        case .failed(_, let reason, let exit): "Why did \(object) fail (\(reason)\(exit.map { ", exit \($0)" } ?? ""))?"
        case .pending: "Why is \(object) stuck in Pending?"
        case .stuckRollout: "Why is the rollout of \(object) stuck (ProgressDeadlineExceeded)?"
        case .unavailable(let available, let desired): "Why is \(object) unavailable (\(available) of \(desired) replicas available)?"
        }
    }

    /// What a pod's object says is wrong with it: its containers (init
    /// first, as they run first), then its phase. Nil for a pod that runs,
    /// or finished.
    static func of(pod: [String: Any]) -> KubeTrouble? {
        let status = pod["status"] as? [String: Any] ?? [:]
        let containers = (status["initContainerStatuses"] as? [[String: Any]] ?? []) + (status["containerStatuses"] as? [[String: Any]] ?? [])
        for container in containers {
            let name = container["name"] as? String ?? "?"
            let state = container["state"] as? [String: Any] ?? [:]
            let last = (container["lastState"] as? [String: Any])?["terminated"] as? [String: Any]
            if let waiting = state["waiting"] as? [String: Any], let reason = waiting["reason"] as? String {
                switch reason {
                case "CrashLoopBackOff":
                    if last?["reason"] as? String == "OOMKilled" { return .outOfMemory(container: name) }
                    return .crashLoop(container: name, exit: KubeRollout.int(last?["exitCode"]))
                case _ where imagePullReasons.contains(reason): return .imagePull(container: name, reason: reason)
                case _ where configReasons.contains(reason): return .configError(container: name, reason: reason)
                case _ where failedReasons.contains(reason): return .failed(container: name, reason: reason, exit: nil)
                default: break
                }
            }
            if let terminated = state["terminated"] as? [String: Any] {
                let reason = terminated["reason"] as? String
                let exit = KubeRollout.int(terminated["exitCode"]) ?? 0
                if reason == "OOMKilled" { return .outOfMemory(container: name) }
                if exit != 0 { return .failed(container: name, reason: reason ?? "Error", exit: exit) }
            }
        }
        switch status["phase"] as? String {
        case "Failed": return .failed(container: nil, reason: status["reason"] as? String ?? "Failed", exit: nil)
        case "Pending": return .pending
        default: return nil
        }
    }

    /// What a Deployment's object says: stuck past its progress deadline
    /// (`KubeRollout`), else fewer available replicas than it wants.
    static func of(deployment: [String: Any]) -> KubeTrouble? {
        let name = (deployment["metadata"] as? [String: Any])?["name"] as? String ?? ""
        if KubeRollout.deployment(deployment, name: name).state == .stuck { return .stuckRollout }
        let spec = deployment["spec"] as? [String: Any] ?? [:]
        let status = deployment["status"] as? [String: Any] ?? [:]
        let desired = KubeRollout.int(spec["replicas"]) ?? 1
        let available = KubeRollout.int(status["availableReplicas"]) ?? 0
        return desired > 0 && available < desired ? .unavailable(available: available, desired: desired) : nil
    }

    /// A pod's or a Deployment's, by its `kind`; nil for any other kind.
    static func of(object: [String: Any]) -> KubeTrouble? {
        switch (object["kind"] as? String, object["apiVersion"] as? String ?? "") {
        case ("Pod", "v1"): of(pod: object)
        case ("Deployment", let version) where version.hasPrefix("apps/"): of(deployment: object)
        default: nil
        }
    }

    /// Why a pod's list row offers no Ask Why: nil when its Status is a
    /// failure (`KubePodSummary.isFailing`) or Pending — the object read
    /// says which.
    static func notFailing(_ summary: KubePodSummary) -> String? {
        if summary.isFailing || summary.status == "Pending" { return nil }
        return "pod/\(summary.id.name) isn't failing: \(summary.status)" + (summary.ready.map { ", \($0)/\(summary.containers ?? $0) ready" } ?? "") + "."
    }

    /// Why a Deployment's list row offers none: nil while it isn't
    /// Available (rolling out, unavailable, not ready) — whether it is stuck
    /// is in its conditions, which a row hasn't — or unknown.
    static func notFailing(_ hint: KubeDeploymentHint?, name: String) -> String? {
        guard let hint, hint.isDone else { return nil }
        return "deploy/\(name) is \(hint.text.lowercased()): nothing to ask about."
    }

    /// Why an object read offers none: nil when `of(object:)` finds trouble.
    static func notFailing(object: [String: Any]) -> String? {
        guard of(object: object) == nil else { return nil }
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let name = metadata["name"] as? String ?? ""
        switch object["kind"] as? String {
        case "Pod":
            let phase = (object["status"] as? [String: Any])?["phase"] as? String ?? "?"
            return "pod/\(name) isn't failing: \(phase)."
        case "Deployment": return "deploy/\(name) is rolled out and available: nothing to ask about."
        default: return "Ask Why is a pod's or a Deployment's."
        }
    }
}

// MARK: The brief

/// The context a brief is about, as it says it.
struct KubeBriefContext: Equatable, Sendable {
    var name: String
    var production: Bool
    var writable: Bool

    /// `context fake-dev (remote, read-only for Overterm)`.
    var said: String {
        if production { return "PRODUCTION context \(name) (read-only: Overterm changes nothing there)" }
        return "context \(name)" + (writable ? "" : " (read-only for Overterm)")
    }
}

/// What the Ask Agent sheet opens with for a failing pod or a stuck
/// rollout: the question, what the fixed chip calls it, the text always
/// sent, the rest a chip each. Every word in it has been scrubbed.
struct KubeAgentBrief: Equatable {
    var message: String
    var subject: String
    var text: String
    var parts: [AskAgentModel.Part]
    /// The bound checkout's deployed commit (3.2): stage 3a, with the
    /// binding (3.1). Nil until a checkout is bound; a part of its own then.
    var deployedCommit: String? = nil
    var production: Bool
}

/// Why no brief was made.
enum KubeBriefProblem: Error, Equatable, CustomStringConvertible {
    /// The object isn't failing: nothing to ask about.
    case notFailing(String)
    /// Not a pod or a Deployment.
    case unsupported(String)

    var description: String {
        switch self {
        case .notFailing(let why), .unsupported(let why): why
        }
    }
}

/// The brief's words, from the API's JSON. Pure; bounded — it is typed
/// into a terminal, and an agent reads it whole.
enum KubeAgentText {
    static let maxEvents = 15
    /// A container's last lines, asked of the API (`tailLines`).
    static let logLines = 60
    static let maxLogBytes = 8 << 10
    /// What a log's read may bring at most (`limitBytes`), and how much of
    /// its end is scrubbed: sixty lines can be megabytes of JSON.
    static let logReadBytes = 256 << 10
    static let logKeepBytes = 64 << 10
    /// A line is cut to this before it is scrubbed: more than `logs` shows
    /// of it, so what it shows was scrubbed whole.
    static let maxLineBytes = maxLogBytes + (1 << 10)
    /// At most this many containers' logs: the failing one first.
    static let maxLogContainers = 2
    static let maxTemplateBytes = 8 << 10
    static let maxDiffBytes = 6 << 10
    static let maxNodes = 20
    static let maxPods = 10
    static let maxEnv = 40
    /// An event's or a condition's message, at most.
    static let maxMessage = 600

    // MARK: Exit codes

    /// What an exit code means, in a container's words: the shell's 126 and
    /// 127, 128 + a signal's number (137 SIGKILL — the OOM killer when
    /// `OOMKilled` — 143 SIGTERM, 139 SIGSEGV), 1 and 2. Nil for 0 and
    /// codes that only the program knows.
    static func exitMeaning(_ code: Int, reason: String? = nil) -> String? {
        switch code {
        case 1: return "a general error: the program itself exited with 1 (its log says why)"
        case 2: return "a usage error: a shell builtin misused, or the program refused its arguments"
        case 126: return "the command couldn't be run (not executable, or a permission)"
        case 127: return "a command wasn't found (the image's entrypoint, or one its script ran)"
        case 137 where reason == "OOMKilled":
            return "SIGKILL (128 + 9) from the kernel's OOM killer: the container went over its memory limit"
        case 137:
            return "SIGKILL (128 + 9), not marked OOMKilled: something killed it — the kubelet after a failed liveness probe, or a stop past terminationGracePeriodSeconds, or the node short of memory"
        case 139: return "SIGSEGV (128 + 11): it crashed, a segmentation fault"
        case 143: return "SIGTERM (128 + 15): it was asked to stop — a failed liveness probe, the pod deleted or rolled — and exited on the signal"
        case 129...159:
            let number = code - 128
            return "killed by signal \(number)" + (signals[number].map { " (SIG\($0))" } ?? "")
        case 255: return "exit status out of range (often exit(-1)), or a runtime error before the program ran"
        default: return nil
        }
    }

    private static let signals: [Int: String] = [
        1: "HUP", 2: "INT", 3: "QUIT", 4: "ILL", 5: "TRAP", 6: "ABRT", 7: "BUS", 8: "FPE", 10: "USR1", 12: "USR2", 13: "PIPE", 14: "ALRM", 24: "XCPU",
        25: "XFSZ", 31: "SYS",
    ]

    // MARK: Reading the JSON

    static func map(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    static func list(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
    static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
    static func name(_ object: [String: Any]) -> String { string(map(object["metadata"])["name"]) ?? "?" }

    /// A message, on one line and bounded.
    static func short(_ text: String, _ limit: Int = maxMessage) -> String {
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + " …" : flat
    }

    /// The owner that controls it: `ReplicaSet web-7d9f`.
    static func controller(of object: [String: Any]) -> (apiVersion: String, kind: String, name: String, uid: String?)? {
        let owners = list(map(object["metadata"])["ownerReferences"])
        guard let owner = owners.first(where: { $0["controller"] as? Bool == true }) ?? owners.first, let kind = string(owner["kind"]),
            let name = string(owner["name"])
        else { return nil }
        return (string(owner["apiVersion"]) ?? "", kind, name, string(owner["uid"]))
    }

    /// What a brief names anyway — the pod, its namespace, its containers,
    /// its node, its images' repositories, its owners — kept out of what
    /// scrubbing takes out (`Secrets.values`): `POSTGRES_PASSWORD=postgres`
    /// would blank the image `postgres:16` and every line naming it.
    static func names(of object: [String: Any], owners: [String] = []) -> Set<String> {
        let metadata = map(object["metadata"])
        var names = Set([string(metadata["name"]), string(metadata["namespace"])].compactMap { $0 } + owners)
        let spec = map(object["spec"])
        let template = map(map(spec["template"])["spec"])
        for pod in [spec, template] {
            if let node = string(pod["nodeName"]) { names.insert(node) }
            for key in ["initContainers", "containers"] {
                for container in list(pod[key]) {
                    if let name = string(container["name"]) { names.insert(name) }
                    if let image = string(container["image"]) {
                        var repository = image.split(separator: "@").first.map(String.init) ?? image
                        if let colon = repository.lastIndex(of: ":"), !repository[colon...].contains("/") { repository = String(repository[..<colon]) }
                        names.insert(repository)
                        names.formUnion(repository.split(separator: "/").map(String.init))
                    }
                }
            }
        }
        return names
    }

    // MARK: A pod

    /// What is always sent about a pod: where it is, its status and why,
    /// each container's state and how it last ended, what its exit code
    /// means, its resources, probes and env (secret-looking values masked,
    /// a Secret's values named — never read), its owners.
    static func pod(_ pod: [String: Any], trouble: KubeTrouble?, context: KubeBriefContext, owners: [String]) -> String {
        let metadata = map(pod["metadata"])
        let spec = map(pod["spec"])
        let status = map(pod["status"])
        let namespace = string(metadata["namespace"]) ?? "default"
        let name = string(metadata["name"]) ?? "?"
        var lines = ["Kubernetes pod \(namespace)/\(name), in \(context.said)."]
        var state = "Status: phase \(string(status["phase"]) ?? "unknown")"
        if let trouble { state += ", \(trouble.reason)" + (trouble.container.map { " (container \($0))" } ?? "") }
        if let reason = string(status["reason"]) { state += ", pod reason \(reason)" }
        if let qos = string(status["qosClass"]) { state += ", QoS \(qos)" }
        lines.append(state + ".")
        if let message = string(status["message"]) { lines.append("Pod message: \(short(message))") }
        var placed: [String] = []
        if let node = string(spec["nodeName"]) { placed.append("node \(node)") }
        if let ip = string(status["podIP"]) { placed.append("IP \(ip)") }
        if let started = string(status["startTime"]) { placed.append("started \(started)") }
        if let policy = string(spec["restartPolicy"]) { placed.append("restartPolicy \(policy)") }
        if let account = string(spec["serviceAccountName"]) { placed.append("service account \(account)") }
        if !placed.isEmpty { lines.append("Placed: " + placed.joined(separator: ", ") + ".") }
        if !owners.isEmpty { lines.append("Owned by: " + owners.joined(separator: " ← ") + ".") }
        let conditions = list(status["conditions"]).filter { $0["status"] as? String != "True" }
        if !conditions.isEmpty {
            lines.append(
                "Conditions not True: "
                    + conditions.map { condition in
                        var said = "\(string(condition["type"]) ?? "?") \(string(condition["status"]) ?? "?")"
                        if let reason = string(condition["reason"]) { said += " (\(reason))" }
                        if let message = string(condition["message"]) { said += ": \(short(message, 300))" }
                        return said
                    }.joined(separator: "; "))
        }
        let statuses = Dictionary(
            (list(status["initContainerStatuses"]) + list(status["containerStatuses"])).compactMap { item in string(item["name"]).map { ($0, item) } },
            uniquingKeysWith: { first, _ in first })
        for (key, role) in [("initContainers", "Init container"), ("containers", "Container")] {
            for container in list(spec[key]) {
                lines += self.container(container, status: statuses[string(container["name"]) ?? ""], role: role)
            }
        }
        lines.append("Read it with: kubectl --context \(KubectlLine.quoted(context.name)) -n \(KubectlLine.quoted(namespace)) describe pod \(KubectlLine.quoted(name))")
        return lines.joined(separator: "\n")
    }

    /// One container: its image, its state now, its restarts, how it last
    /// ended and what the exit code means, its resources, probes, command
    /// and env.
    static func container(_ container: [String: Any], status: [String: Any]?, role: String = "Container") -> [String] {
        let name = string(container["name"]) ?? "?"
        var lines = ["\(role) \(name) (image \(string(container["image"]) ?? "?")):"]
        if let status {
            let state = map(status["state"])
            if let waiting = state["waiting"] as? [String: Any] {
                lines.append("  State: waiting — \(string(waiting["reason"]) ?? "?")" + (string(waiting["message"]).map { ": \(short($0, 400))" } ?? ""))
            } else if let running = state["running"] as? [String: Any] {
                lines.append("  State: running" + (string(running["startedAt"]).map { " since \($0)" } ?? "") + ((status["ready"] as? Bool) == false ? ", not ready" : ""))
            } else if let terminated = state["terminated"] as? [String: Any] {
                lines.append("  State: " + ended(terminated))
            }
            let restarts = KubeRollout.int(status["restartCount"]) ?? 0
            if restarts > 0 { lines.append("  Restarts: \(restarts)") }
            if let last = map(status["lastState"])["terminated"] as? [String: Any] { lines.append("  Last terminated: " + ended(last)) }
            if let image = string(status["imageID"]), image != string(container["image"]) { lines.append("  Image ID: \(image)") }
        }
        if let resources = resources(container) { lines.append("  Resources: \(resources)") }
        for (key, title) in [("livenessProbe", "Liveness"), ("readinessProbe", "Readiness"), ("startupProbe", "Startup")] {
            if let probe = container[key] as? [String: Any] { lines.append("  \(title) probe: \(self.probe(probe))") }
        }
        let command = (container["command"] as? [String] ?? []) + (container["args"] as? [String] ?? [])
        if !command.isEmpty { lines.append("  Command: " + Secrets.maskArguments(command).joined(separator: " ")) }
        let env = self.env(container)
        if !env.isEmpty { lines.append("  Env: " + env.joined(separator: "; ")) }
        return lines
    }

    /// `Error, exit 1 at 2026-11-05T10:00:00Z: a general error …`.
    static func ended(_ terminated: [String: Any]) -> String {
        let reason = string(terminated["reason"])
        let code = KubeRollout.int(terminated["exitCode"])
        var said = "terminated — \(reason ?? "?")"
        if let code { said += ", exit \(code)" }
        if let signal = KubeRollout.int(terminated["signal"]), signal > 0 { said += ", signal \(signal)" }
        if let started = string(terminated["startedAt"]) { said += ", started \(started)" }
        if let finished = string(terminated["finishedAt"]) { said += ", finished \(finished)" }
        if let code, let meaning = exitMeaning(code, reason: reason) { said += ". Exit \(code): \(meaning)" }
        if let message = string(terminated["message"]) { said += ". Message: \(short(message, 400))" }
        return said
    }

    /// `requests cpu 100m, memory 128Mi; limits memory 256Mi`.
    static func resources(_ container: [String: Any]) -> String? {
        let resources = map(container["resources"])
        let said = ["requests", "limits"].compactMap { key -> String? in
            let values = map(resources[key])
            guard !values.isEmpty else { return nil }
            return key + " " + values.keys.sorted().map { "\($0) \(values[$0].map { "\($0)" } ?? "")" }.joined(separator: ", ")
        }
        return said.isEmpty ? nil : said.joined(separator: "; ")
    }

    /// `HTTP GET :8080/healthz, every 10s, timeout 1s, 3 failures`.
    static func probe(_ probe: [String: Any]) -> String {
        var said: String
        if let http = probe["httpGet"] as? [String: Any] {
            said = "HTTP GET :\(http["port"].map { "\($0)" } ?? "?")\(string(http["path"]) ?? "/")"
        } else if let tcp = probe["tcpSocket"] as? [String: Any] {
            said = "TCP :\(tcp["port"].map { "\($0)" } ?? "?")"
        } else if let exec = probe["exec"] as? [String: Any], let command = exec["command"] as? [String] {
            said = "exec " + Secrets.maskArguments(command).joined(separator: " ")
        } else if let grpc = probe["grpc"] as? [String: Any] {
            said = "gRPC :\(grpc["port"].map { "\($0)" } ?? "?")"
        } else {
            said = "?"
        }
        var options: [String] = []
        if let delay = KubeRollout.int(probe["initialDelaySeconds"]), delay > 0 { options.append("after \(delay)s") }
        options.append("every \(KubeRollout.int(probe["periodSeconds"]) ?? 10)s")
        options.append("timeout \(KubeRollout.int(probe["timeoutSeconds"]) ?? 1)s")
        options.append("\(KubeRollout.int(probe["failureThreshold"]) ?? 3) failures")
        return said + ", " + options.joined(separator: ", ")
    }

    /// A container's env as a brief says it: a plain value (masked when
    /// its name looks secret, a URL's password masked), a Secret's key by
    /// its name — `from Secret web-db, key password (not read)` — a
    /// ConfigMap's or a field's by theirs; `envFrom` by the Secret's or the
    /// ConfigMap's name. No Secret is ever read for it.
    static func env(_ container: [String: Any]) -> [String] {
        var said: [String] = []
        let entries = list(container["env"])
        for entry in entries.prefix(maxEnv) {
            guard let name = string(entry["name"]) else { continue }
            if let value = entry["value"] as? String {
                said.append("\(name)=\(Secrets.masked(name, value))")
            } else if let from = entry["valueFrom"] as? [String: Any] {
                if let secret = from["secretKeyRef"] as? [String: Any] {
                    said.append("\(name) from Secret \(string(secret["name"]) ?? "?"), key \(string(secret["key"]) ?? "?") (not read)")
                } else if let map = from["configMapKeyRef"] as? [String: Any] {
                    said.append("\(name) from ConfigMap \(string(map["name"]) ?? "?"), key \(string(map["key"]) ?? "?")")
                } else if let field = from["fieldRef"] as? [String: Any] {
                    said.append("\(name) from field \(string(field["fieldPath"]) ?? "?")")
                } else if let resource = from["resourceFieldRef"] as? [String: Any] {
                    said.append("\(name) from \(string(resource["resource"]) ?? "a resource")")
                } else {
                    said.append("\(name) from elsewhere")
                }
            } else {
                said.append("\(name)=")
            }
        }
        if entries.count > maxEnv { said.append("… \(entries.count - maxEnv) more") }
        for source in list(container["envFrom"]) {
            let prefix = string(source["prefix"]).map { " (prefix \($0))" } ?? ""
            if let secret = source["secretRef"] as? [String: Any] {
                said.append("every key of Secret \(string(secret["name"]) ?? "?")\(prefix) (not read)")
            } else if let map = source["configMapRef"] as? [String: Any] {
                said.append("every key of ConfigMap \(string(map["name"]) ?? "?")\(prefix)")
            }
        }
        return said
    }

    /// The containers whose last lines a brief brings, the troubled one
    /// first, then the others that restarted or ended — and whether its
    /// last terminated instance's (`previous`) is the one to read: a
    /// container that restarted ran before, one that crashed once and
    /// wasn't restarted is its current log. A container waiting to be
    /// created has none.
    static func logTargets(_ pod: [String: Any], trouble: KubeTrouble?) -> [(container: String, previous: Bool)] {
        let status = map(pod["status"])
        var targets: [(container: String, previous: Bool, first: Bool)] = []
        for item in list(status["initContainerStatuses"]) + list(status["containerStatuses"]) {
            guard let name = string(item["name"]) else { continue }
            let restarts = KubeRollout.int(item["restartCount"]) ?? 0
            let state = map(item["state"])
            let reason = string(map(state["waiting"])["reason"])
            if reason.map({ KubeTrouble.imagePullReasons.contains($0) || KubeTrouble.configReasons.contains($0) }) == true && restarts == 0 { continue }
            if restarts > 0 {
                targets.append((name, true, name == trouble?.container))
            } else if let terminated = state["terminated"] as? [String: Any], (KubeRollout.int(terminated["exitCode"]) ?? 0) != 0 {
                targets.append((name, false, name == trouble?.container))
            } else if name == trouble?.container, state["running"] != nil {
                targets.append((name, false, true))
            }
        }
        let ordered = targets.filter(\.first) + targets.filter { !$0.first }
        return ordered.prefix(maxLogContainers).map { ($0.container, $0.previous) }
    }

    /// A container's last lines, newest last, already scrubbed — the newest
    /// that fit in `maxLogBytes`, saying when earlier ones were left out.
    /// The newest alone too long is cut, not dropped: it is the crash. Nil
    /// for none.
    static func logs(_ lines: [String], container: String, previous: Bool, stopped: Bool = false) -> (count: Int, text: String)? {
        guard !lines.isEmpty else { return nil }
        var kept: [String] = []
        var size = 0
        for line in lines.reversed() {
            var text = line
            let fits = size + text.utf8.count + 1 <= maxLogBytes
            if !fits {
                guard kept.isEmpty else { break }
                text = DockerAgentText.cut(text, bytes: maxLogBytes - 64) + " … (line cut)"
            }
            kept.append(text)
            size += text.utf8.count + 1
            if !fits { break }
        }
        let which = previous ? "its previous (terminated) instance's" : "its log's"
        let heading = "Container \(container): \(which) last \(kept.count) line\(kept.count == 1 ? "" : "s") (newest last, secrets taken out):\n"
        let cut = kept.count < lines.count ? "… earlier lines left out\n" : ""
        let past = stopped ? "\n… the read stopped at \(logReadBytes >> 10) KB: newer lines may be past it" : ""
        return (kept.count, heading + cut + kept.reversed().joined(separator: "\n") + past)
    }

    /// A line bounded before it is scrubbed (`maxLineBytes`): cut back to
    /// its last whitespace, so no word is kept in part.
    static func bounded(_ line: String) -> String {
        guard line.utf8.count > maxLineBytes else { return line }
        var text = DockerAgentText.cut(line, bytes: maxLineBytes)
        if let space = text.lastIndex(where: \.isWhitespace) { text = String(text[..<space]) }
        return text + " … (line cut)"
    }

    // MARK: Events

    /// Its events, newest first: a warning marked, how often, how long ago.
    static func events(_ events: [KubeEvent], about: String, now: Date = Date()) -> String? {
        guard !events.isEmpty else { return nil }
        let shown = events.prefix(maxEvents).map { event -> String in
            var line = "\(event.isWarning ? "Warning" : "Normal") \(event.reason)"
            if event.count > 1 { line += " ×\(event.count)" }
            if let last = event.last { line += " (\(KubeAge.format(max(0, now.timeIntervalSince(last)))) ago)" }
            if !event.source.isEmpty { line += " [\(event.source)]" }
            return line + ": " + short(event.message, 400)
        }
        var text = "Events of \(about), newest first:\n" + shown.joined(separator: "\n")
        if events.count > maxEvents { text += "\n… \(events.count - maxEvents) older left out" }
        return text
    }

    // MARK: The template

    /// A pod template as YAML, as `kubectl get -o yaml` writes it: the
    /// controller's `pod-template-hash` label out, what looks secret masked
    /// (`masked`); bounded.
    static func templateYAML(_ template: [String: Any]) -> String {
        KubeYAML.text(masked(stripped(template)))
    }

    /// A template without what its controller adds: the `pod-template-hash`
    /// label, an empty `creationTimestamp`.
    static func stripped(_ template: [String: Any]) -> [String: Any] {
        var template = template
        var metadata = map(template["metadata"])
        var labels = map(metadata["labels"])
        labels["pod-template-hash"] = nil
        metadata["labels"] = labels.isEmpty ? nil : labels
        metadata["creationTimestamp"] = nil
        template["metadata"] = metadata.isEmpty ? nil : metadata
        return template
    }

    /// The lists of a pod spec's containers.
    static let containerLists = ["initContainers", "containers", "ephemeralContainers"]

    /// A template as an agent may read it: env values whose names look
    /// secret masked (`KubeObjectStrip.maskingEnv`, a Secret's keys only
    /// named there), and every container's command and args as one command
    /// line, its probes' and hooks' `exec` commands, through
    /// `Secrets.maskArguments` (`--requirepass` then its value, one list
    /// item each, as the pod's own Command line is).
    static func masked(_ template: [String: Any]) -> [String: Any] {
        var template = KubeObjectStrip.maskingEnv(template) as? [String: Any] ?? template
        guard var spec = template["spec"] as? [String: Any] else { return template }
        for key in containerLists {
            guard let containers = spec[key] as? [[String: Any]] else { continue }
            spec[key] = containers.map(maskingCommands)
        }
        template["spec"] = spec
        return template
    }

    private static func maskingCommands(_ container: [String: Any]) -> [String: Any] {
        var container = container
        let command = container["command"] as? [String] ?? []
        let args = container["args"] as? [String] ?? []
        if !command.isEmpty || !args.isEmpty {
            let words = Secrets.maskArguments(command + args)
            if container["command"] != nil { container["command"] = Array(words.prefix(command.count)) }
            if container["args"] != nil { container["args"] = Array(words.dropFirst(command.count)) }
        }
        func exec(_ handler: Any?) -> Any? {
            guard var handler = handler as? [String: Any], var exec = handler["exec"] as? [String: Any], let words = exec["command"] as? [String] else {
                return handler
            }
            exec["command"] = Secrets.maskArguments(words)
            handler["exec"] = exec
            return handler
        }
        for probe in ["livenessProbe", "readinessProbe", "startupProbe"] where container[probe] != nil { container[probe] = exec(container[probe]) }
        if var lifecycle = container["lifecycle"] as? [String: Any] {
            for hook in ["postStart", "preStop"] where lifecycle[hook] != nil { lifecycle[hook] = exec(lifecycle[hook]) }
            container["lifecycle"] = lifecycle
        }
        return container
    }

    static func template(_ template: [String: Any], of owner: String) -> String? {
        guard !template.isEmpty else { return nil }
        var text = templateYAML(template)
        if text.utf8.count > maxTemplateBytes { text = DockerAgentText.cut(text, bytes: maxTemplateBytes) + "\n… the rest left out" }
        return "The pod template of \(owner) (env values and arguments that look secret masked; a Secret's keys named, never read):\n" + text
    }

    /// The mark on a masked value that changed: its value isn't shown, but
    /// that it changed is — a rotated password is the change most likely
    /// to break a pod.
    static let changedMark = " (changed)"

    /// What changed between the previous ReplicaSet's template and the
    /// current one's, as a unified diff of their YAML (two lines of context);
    /// nil when there is no previous one. Bounded. Whether they differ is
    /// asked of the templates themselves, not their masked YAML: a masked
    /// value that changed (`markingChanged`) is marked, and named.
    static func templateDiff(current: [String: Any], previous: [String: Any], currentName: String, previousName: String) -> String {
        let rawOld = stripped(previous)
        let rawNew = stripped(current)
        guard !NSDictionary(dictionary: rawOld).isEqual(to: rawNew) else {
            return "The pod template of ReplicaSet \(currentName) is the same as the previous one's (\(previousName))."
        }
        let maskedOld = masked(rawOld)
        let (maskedNew, changed) = markingChanged(masked(rawNew), raw: rawNew, previous: rawOld, previousMasked: maskedOld)
        let old = KubeYAML.text(maskedOld).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let new = KubeYAML.text(maskedNew).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var heading = "What changed in the pod template, previous ReplicaSet \(previousName) → current \(currentName):\n"
        if !changed.isEmpty {
            heading += "Masked values that changed (not shown, marked\(changedMark)): " + changed.joined(separator: ", ") + ".\n"
        }
        guard old != new else { return heading + "Nothing else: only values masked here differ." }
        var text = lineDiff(old, new).joined(separator: "\n")
        if text.utf8.count > maxDiffBytes { text = DockerAgentText.cut(text, bytes: maxDiffBytes) + "\n… the rest left out" }
        return heading + "--- \(previousName)\n+++ \(currentName)\n" + text
    }

    /// `masked`, the current template masked, with each value that masks as
    /// the previous one's did but isn't the same marked `changedMark` — an
    /// env value, a word of a container's command and args — and what each
    /// was: "DB_PASSWORD's value (container app)".
    static func markingChanged(
        _ masked: [String: Any], raw: [String: Any], previous: [String: Any], previousMasked: [String: Any]
    ) -> (template: [String: Any], changed: [String]) {
        guard var spec = masked["spec"] as? [String: Any] else { return (masked, []) }
        let rawSpec = map(raw["spec"])
        let oldSpec = map(previous["spec"])
        let oldMaskedSpec = map(previousMasked["spec"])
        var changed: [String] = []
        func named(_ list: Any?, _ name: String?) -> [String: Any]? {
            (list as? [[String: Any]])?.first { $0["name"] as? String == name }
        }
        for key in containerLists {
            guard var containers = spec[key] as? [[String: Any]] else { continue }
            for index in containers.indices {
                let name = containers[index]["name"] as? String
                guard let rawContainer = named(rawSpec[key], name), let oldContainer = named(oldSpec[key], name),
                    let oldMasked = named(oldMaskedSpec[key], name)
                else { continue }
                if var env = containers[index]["env"] as? [[String: Any]] {
                    for entry in env.indices {
                        let variable = env[entry]["name"] as? String
                        guard let shown = env[entry]["value"] as? String, let now = named(rawContainer["env"], variable)?["value"] as? String,
                            let before = named(oldContainer["env"], variable)?["value"] as? String,
                            let shownBefore = named(oldMasked["env"], variable)?["value"] as? String, shown == shownBefore, now != before
                        else { continue }
                        env[entry]["value"] = shown + changedMark
                        changed.append("\(variable ?? "?")'s value (container \(name ?? "?"))")
                    }
                    containers[index]["env"] = env
                }
                let words = { (container: [String: Any]) in (container["command"] as? [String] ?? []) + (container["args"] as? [String] ?? []) }
                let shownNow = words(containers[index])
                let rawNow = words(rawContainer)
                let rawBefore = words(oldContainer)
                let shownBefore = words(oldMasked)
                guard shownNow.count == shownBefore.count, rawNow.count == rawBefore.count, shownNow.count == rawNow.count else { continue }
                var marked = shownNow
                for word in marked.indices where marked[word] == shownBefore[word] && rawNow[word] != rawBefore[word] {
                    marked[word] += changedMark
                }
                guard marked != shownNow else { continue }
                changed.append("an argument of container \(name ?? "?")'s command")
                let commandCount = (containers[index]["command"] as? [String])?.count ?? 0
                if containers[index]["command"] != nil { containers[index]["command"] = Array(marked.prefix(commandCount)) }
                if containers[index]["args"] != nil { containers[index]["args"] = Array(marked.dropFirst(commandCount)) }
            }
            spec[key] = containers
        }
        var template = masked
        template["spec"] = spec
        return (template, changed)
    }

    /// `old` to `new` as diff lines (`-`, `+`, ` `), unchanged runs cut to
    /// `context` lines either side, `@@` between hunks.
    static func lineDiff(_ old: [String], _ new: [String], context: Int = 2) -> [String] {
        let difference = new.difference(from: old)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var merged: [(mark: Character, text: String)] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                merged.append(("-", old[i]))
                i += 1
            } else if j < new.count, inserted.contains(j) {
                merged.append(("+", new[j]))
                j += 1
            } else {
                if i < old.count { merged.append((" ", old[i])) }
                i += 1
                j += 1
            }
        }
        let changed = merged.indices.filter { merged[$0].mark != " " }
        var shown = Set<Int>()
        for index in changed { for near in max(0, index - context)...min(merged.count - 1, index + context) { shown.insert(near) } }
        var out: [String] = []
        var last = -1
        for index in shown.sorted() {
            if last >= 0, index != last + 1 { out.append("@@") }
            out.append("\(merged[index].mark) \(merged[index].text)")
            last = index
        }
        return out
    }

    // MARK: Pending

    /// For a Pending pod: the scheduler's message, what the pod asks for
    /// (its containers' requests, the largest init container's if larger,
    /// its node selector and tolerations) against each node's allocatable —
    /// the node's whole room for pods, not what is left of it.
    static func scheduling(_ pod: [String: Any], nodes: [[String: Any]]?, nodesProblem: String? = nil) -> String {
        let spec = map(pod["spec"])
        var lines = ["Scheduling:"]
        let scheduled = list(map(pod["status"])["conditions"]).first { $0["type"] as? String == "PodScheduled" }
        if let scheduled, scheduled["status"] as? String != "True" {
            lines.append(
                "  The scheduler: \(string(scheduled["reason"]) ?? "not scheduled")" + (string(scheduled["message"]).map { ": \(short($0))" } ?? ""))
        } else if let node = string(spec["nodeName"]) {
            lines.append("  Scheduled on \(node): its containers haven't started.")
        }
        let wanted = requests(pod)
        lines.append("  It requests: cpu \(wanted.cpu.map(cpuSaid) ?? "none"), memory \(wanted.memory.map(memorySaid) ?? "none").")
        if let selector = spec["nodeSelector"] as? [String: Any], !selector.isEmpty {
            lines.append("  Node selector: " + selector.keys.sorted().map { "\($0)=\(selector[$0] ?? "")" }.joined(separator: ", "))
        }
        if spec["affinity"] != nil { lines.append("  It has affinity rules (see the template).") }
        let tolerations = list(spec["tolerations"]).map { toleration in
            [string(toleration["key"]) ?? "*", string(toleration["operator"]), string(toleration["value"]), string(toleration["effect"])].compactMap { $0 }
                .joined(separator: " ")
        }
        if !tolerations.isEmpty { lines.append("  Tolerations: " + tolerations.joined(separator: "; ")) }
        if let nodesProblem {
            lines.append("  The nodes couldn't be read: \(nodesProblem)")
        } else if let nodes {
            lines.append("  Nodes (allocatable — what other pods already request isn't counted here):")
            for node in nodes.prefix(maxNodes) { lines.append("    " + self.node(node, wanted: wanted)) }
            if nodes.count > maxNodes { lines.append("    … \(nodes.count - maxNodes) more") }
            if nodes.isEmpty { lines.append("    none") }
        }
        return lines.joined(separator: "\n")
    }

    /// A node: ready, cordoned, taints, allocatable, and whether the pod's
    /// requests are more than it has at all.
    static func node(_ node: [String: Any], wanted: (cpu: Double?, memory: Double?)) -> String {
        let status = map(node["status"])
        let spec = map(node["spec"])
        let ready = list(status["conditions"]).first { $0["type"] as? String == "Ready" }?["status"] as? String
        var said = "\(name(node)): " + (ready == "True" ? "Ready" : "NotReady")
        if spec["unschedulable"] as? Bool == true { said += ", cordoned (unschedulable)" }
        let allocatable = map(status["allocatable"])
        let cpu = (allocatable["cpu"] as? String).flatMap(KubeQuantity.value)
        let memory = (allocatable["memory"] as? String).flatMap(KubeQuantity.value)
        said += "; allocatable cpu \(cpu.map(cpuSaid) ?? "?"), memory \(memory.map(memorySaid) ?? "?"), pods \(allocatable["pods"].map { "\($0)" } ?? "?")"
        var short: [String] = []
        if let need = wanted.cpu, let have = cpu, need > have { short.append("cpu") }
        if let need = wanted.memory, let have = memory, need > have { short.append("memory") }
        if !short.isEmpty { said += " — too little \(short.joined(separator: " and ")) for its requests even empty" }
        let taints = list(spec["taints"]).map { taint in
            "\(string(taint["key"]) ?? "?")\(string(taint["value"]).map { "=\($0)" } ?? ""):\(string(taint["effect"]) ?? "?")"
        }
        if !taints.isEmpty { said += "; taints " + taints.joined(separator: ", ") }
        return said
    }

    /// What a pod asks for: its containers' requests summed, or its largest
    /// init container's if that is more (they run one at a time, first).
    static func requests(_ pod: [String: Any]) -> (cpu: Double?, memory: Double?) {
        let spec = map(pod["spec"])
        func asked(_ containers: [[String: Any]], _ key: String, sum: Bool) -> Double? {
            let values = containers.compactMap { (map(map($0["resources"])["requests"])[key] as? String).flatMap(KubeQuantity.value) }
            guard !values.isEmpty else { return nil }
            return sum ? values.reduce(0, +) : values.max()
        }
        let containers = list(spec["containers"])
        let inits = list(spec["initContainers"])
        func both(_ key: String) -> Double? {
            switch (asked(containers, key, sum: true), asked(inits, key, sum: false)) {
            case (let a?, let b?): max(a, b)
            case (let a, let b): a ?? b
            }
        }
        return (both("cpu"), both("memory"))
    }

    static func cpuSaid(_ cores: Double) -> String {
        cores < 1 || cores != cores.rounded() ? "\(Int((cores * 1000).rounded()))m" : "\(Int(cores))"
    }

    static func memorySaid(_ bytes: Double) -> String {
        let gi = bytes / Double(1 << 30)
        if gi >= 1 { return gi == gi.rounded() ? "\(Int(gi))Gi" : String(format: "%.1fGi", gi) }
        return "\(Int((bytes / Double(1 << 20)).rounded()))Mi"
    }

    // MARK: A Deployment

    /// What is always sent about a Deployment: where it is, its rollout as
    /// `kubectl rollout status` reads it, its replicas, strategy and
    /// deadline, its conditions, its ReplicaSets.
    static func deployment(
        _ deployment: [String: Any], trouble: KubeTrouble?, context: KubeBriefContext, current: [String: Any]?, previous: [String: Any]?
    ) -> String {
        let metadata = map(deployment["metadata"])
        let spec = map(deployment["spec"])
        let status = map(deployment["status"])
        let namespace = string(metadata["namespace"]) ?? "default"
        let name = string(metadata["name"]) ?? "?"
        var lines = ["Kubernetes Deployment \(namespace)/\(name), in \(context.said)."]
        if let trouble { lines.append("Trouble: \(trouble.reason).") }
        lines.append("Rollout: \(KubeRollout.deployment(deployment, name: name).message).")
        func count(_ key: String) -> String { "\(KubeRollout.int(status[key]) ?? 0)" }
        lines.append(
            "Replicas: \(KubeRollout.int(spec["replicas"]) ?? 1) wanted, \(count("updatedReplicas")) updated, \(count("readyReplicas")) ready, "
                + "\(count("availableReplicas")) available, \(count("unavailableReplicas")) unavailable.")
        var strategy = string(map(spec["strategy"])["type"]) ?? "RollingUpdate"
        if let rolling = map(spec["strategy"])["rollingUpdate"] as? [String: Any] {
            strategy += " (maxSurge \(rolling["maxSurge"].map { "\($0)" } ?? "25%"), maxUnavailable \(rolling["maxUnavailable"].map { "\($0)" } ?? "25%"))"
        }
        lines.append("Strategy: \(strategy); progressDeadlineSeconds \(KubeRollout.int(spec["progressDeadlineSeconds"]) ?? 600).")
        if let revision = string(map(metadata["annotations"])["deployment.kubernetes.io/revision"]) { lines.append("Revision: \(revision).") }
        for condition in list(status["conditions"]) {
            var said = "Condition \(string(condition["type"]) ?? "?") \(string(condition["status"]) ?? "?")"
            if let reason = string(condition["reason"]) { said += " (\(reason))" }
            if let message = string(condition["message"]) { said += ": \(short(message, 400))" }
            if let time = string(condition["lastUpdateTime"]) ?? string(condition["lastTransitionTime"]) { said += " — \(time)" }
            lines.append(said)
        }
        if let current { lines.append("Current ReplicaSet: " + replicaSet(current)) }
        if let previous { lines.append("Previous ReplicaSet: " + replicaSet(previous)) }
        lines.append(
            "Read it with: kubectl --context \(KubectlLine.quoted(context.name)) -n \(KubectlLine.quoted(namespace)) rollout status deploy/\(KubectlLine.quoted(name))")
        return lines.joined(separator: "\n")
    }

    /// `web-7d9f, revision 3: 1 wanted, 0 ready, 0 available`.
    static func replicaSet(_ set: [String: Any]) -> String {
        let status = map(set["status"])
        let revision = string(map(map(set["metadata"])["annotations"])["deployment.kubernetes.io/revision"])
        return "\(name(set))" + (revision.map { ", revision \($0)" } ?? "")
            + ": \(KubeRollout.int(map(set["spec"])["replicas"]) ?? 0) wanted, \(KubeRollout.int(status["readyReplicas"]) ?? 0) ready, "
            + "\(KubeRollout.int(status["availableReplicas"]) ?? 0) available"
    }

    /// The pods of a ReplicaSet, as the list's rows say them.
    static func pods(_ pods: [KubePodSummary], of owner: String) -> String? {
        guard !pods.isEmpty else { return nil }
        var lines = pods.prefix(maxPods).map { pod in
            "\(pod.id.name): \(pod.exitReason ?? pod.status)" + (pod.ready.map { ", \($0)/\(pod.containers ?? $0) ready" } ?? "")
                + (pod.restarts.map { $0 > 0 ? ", \($0) restarts" : "" } ?? "")
        }
        if pods.count > maxPods { lines.append("… \(pods.count - maxPods) more") }
        return "Pods of \(owner):\n" + lines.joined(separator: "\n")
    }

    // MARK: ReplicaSets

    /// The revision a ReplicaSet's annotation says.
    static func revision(_ set: [String: Any]) -> Int? {
        Int(string(map(map(set["metadata"])["annotations"])["deployment.kubernetes.io/revision"]) ?? "")
    }

    /// Of a Deployment's ReplicaSets (those it controls), the current one —
    /// the revision the Deployment says, else the highest — and the one
    /// before it.
    static func currentAndPrevious(_ sets: [[String: Any]], of deployment: [String: Any]) -> (current: [String: Any]?, previous: [String: Any]?) {
        let metadata = map(deployment["metadata"])
        let uid = string(metadata["uid"])
        let deploymentName = string(metadata["name"])
        let owned = sets.filter { set in
            guard let owner = controller(of: set), owner.kind == "Deployment" else { return false }
            if let uid, let ownerUID = owner.uid { return uid == ownerUID }
            return owner.name == deploymentName
        }
        .sorted { (revision($0) ?? 0) > (revision($1) ?? 0) }
        let wanted = Int(string(map(metadata["annotations"])["deployment.kubernetes.io/revision"]) ?? "")
        guard let current = owned.first(where: { wanted != nil && revision($0) == wanted }) ?? owned.first else { return (nil, nil) }
        let currentRevision = revision(current) ?? 0
        let previous = owned.first { (revision($0) ?? 0) < currentRevision && name($0) != name(current) }
        return (current, previous)
    }
}

/// Kubernetes' quantities (`500m`, `1.5`, `128Mi`, `1G`, `1e3`) as numbers:
/// cores for cpu, bytes for memory. Pure.
enum KubeQuantity {
    static func value(_ text: String) -> Double? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let suffixes: [(String, Double)] = [
            ("Ki", 1024), ("Mi", 1_048_576), ("Gi", 1_073_741_824), ("Ti", 1_099_511_627_776), ("Pi", 1_125_899_906_842_624),
            ("Ei", 1_152_921_504_606_846_976), ("n", 1e-9), ("u", 1e-6), ("m", 1e-3), ("k", 1e3), ("M", 1e6), ("G", 1e9), ("T", 1e12), ("P", 1e15),
            ("E", 1e18),
        ]
        for (suffix, scale) in suffixes where text.hasSuffix(suffix) {
            guard let number = Double(text.dropLast(suffix.count)) else { return nil }
            return number * scale
        }
        return Double(text)
    }
}
