import Darwin
import Foundation

/// What a port-forward goes to (docs/design/kubernetes/analysis.md, 2.7 and
/// 3.8): a pod itself, or a Service or a Deployment, which Overterm
/// resolves to one of its ready pods every time the forward starts — so a
/// forward follows a rollout instead of dying with its first pod. kubectl
/// is only ever given `pod/<name>`. Pure.
enum KubeForwardTarget: Hashable, Sendable, CustomStringConvertible {
    case pod(String)
    case service(String)
    case deployment(String)

    var name: String {
        switch self {
        case .pod(let name), .service(let name), .deployment(let name): name
        }
    }

    /// kubectl's short word: `pod`, `svc`, `deploy`.
    var word: String {
        switch self {
        case .pod: "pod"
        case .service: "svc"
        case .deployment: "deploy"
        }
    }

    var title: String {
        switch self {
        case .pod: "Pod"
        case .service: "Service"
        case .deployment: "Deployment"
        }
    }

    /// `svc/web`.
    var description: String { "\(word)/\(name)" }

    /// Whether it goes to whichever of its pods is ready (a Service's
    /// endpoints, a Deployment's), not one pod: its pod is followed while
    /// it is ready, not only while it runs.
    var followsEndpoints: Bool { if case .pod = self { false } else { true } }

    /// The kind a target of this sort is read as.
    var kind: KubeResourceKind {
        switch self {
        case .pod: .pods
        case .service: .services
        case .deployment: .deployments
        }
    }

    /// The target a row of `kind` is: a pod, a Service or a Deployment; nil
    /// for any other kind.
    static func of(kind: KubeResourceKind, name: String) -> KubeForwardTarget? {
        switch kind.fullName {
        case "pods": .pod(name)
        case "services": .service(name)
        case "deployments.apps": .deployment(name)
        default: nil
        }
    }
}

extension KubeResourceKind {
    static let services = KubeResourceKind(
        group: "", version: "v1", resource: "services", kind: "Service", singular: "service", namespaced: true,
        verbs: ["create", "delete", "get", "list", "patch", "update", "watch"], shortNames: ["svc"], categories: ["all"], subresources: ["proxy", "status"])
    static let deployments = KubeResourceKind(
        group: "apps", version: "v1", resource: "deployments", kind: "Deployment", singular: "deployment", namespaced: true,
        verbs: ["create", "delete", "deletecollection", "get", "list", "patch", "update", "watch"], shortNames: ["deploy"], categories: ["all"],
        subresources: ["scale", "status"])
}

/// One port a target offers: a container's (a pod's, a Deployment's
/// template's) or a Service's own. Only TCP: kubectl port-forward forwards
/// nothing else.
struct KubeForwardPortOption: Hashable, Sendable {
    var port: Int
    var name: String?
    /// The container that declares it; nil for a Service's.
    var container: String?
    /// A Service's port: where it goes in the pod (`targetPort`, a number or a name).
    var targetPort: String?

    /// `80 (http)`, `5432 · db`.
    var label: String {
        var text = "\(port)"
        if let name, !name.isEmpty { text += " (\(name))" }
        if let container { text += " · \(container)" }
        if let targetPort, targetPort != "\(port)" { text += " → \(targetPort)" }
        return text
    }

    /// The ports `object` offers as a forward's remote end: a pod's
    /// containers' ports, a Deployment's template's, a Service's own.
    static func offered(by object: [String: Any], target: KubeForwardTarget) -> [KubeForwardPortOption] {
        switch target {
        case .service:
            let spec = object["spec"] as? [String: Any] ?? [:]
            return (spec["ports"] as? [[String: Any]] ?? []).compactMap { port in
                guard (port["protocol"] as? String ?? "TCP") == "TCP", let number = KubeForwardResolve.int(port["port"]) else { return nil }
                return KubeForwardPortOption(port: number, name: port["name"] as? String, targetPort: port["targetPort"].map { "\($0)" })
            }
        case .pod:
            return containerPorts(object["spec"] as? [String: Any])
        case .deployment:
            let template = ((object["spec"] as? [String: Any])?["template"] as? [String: Any])?["spec"] as? [String: Any]
            return containerPorts(template)
        }
    }

    private static func containerPorts(_ spec: [String: Any]?) -> [KubeForwardPortOption] {
        var options: [KubeForwardPortOption] = []
        for container in spec?["containers"] as? [[String: Any]] ?? [] {
            for port in container["ports"] as? [[String: Any]] ?? [] {
                guard (port["protocol"] as? String ?? "TCP") == "TCP", let number = KubeForwardResolve.int(port["containerPort"]) else { continue }
                guard !options.contains(where: { $0.port == number }) else { continue }
                options.append(KubeForwardPortOption(port: number, name: port["name"] as? String, container: container["name"] as? String))
            }
        }
        return options
    }
}

/// What a forward is asked to be: its target, the port there, where it
/// listens on this Mac. A Service's `remotePort` is the Service's port —
/// the pod's port is worked out from it each time (its `targetPort`, by
/// number or by name), as kubectl does.
struct KubeForwardSpec: Hashable, Sendable, Identifiable {
    var id = UUID()
    var context: String
    var namespace: String
    var target: KubeForwardTarget
    var remotePort: Int
    var localPort: Int
    /// What kubectl listens on: `127.0.0.1` unless changed.
    var address = KubeForwardAddress.loopback
    /// The page it serves is https: what Open and Copy URL say.
    var https = false
    /// Started by `d` for the Database client: its server is a database,
    /// never asked for an API document.
    var forDatabase = false
    /// The tab whose pane header shows its pill: the one under the page
    /// when it was asked for.
    var tab: UUID?

    var url: URL? { URL(string: "\(https ? "https" : "http")://\(KubeForwardAddress.host(for: address)):\(localPort)") }

    /// Where it is reached, as its URL has it: `127.0.0.1:8080`.
    var hostPort: String { "\(KubeForwardAddress.host(for: address)):\(localPort)" }

    /// `127.0.0.1:8080 → svc/web:80`.
    var summary: String { "\(hostPort) → \(target):\(remotePort)" }
}

/// The listen address: an IP literal or `localhost`. Pure.
enum KubeForwardAddress {
    static let loopback = "127.0.0.1"

    /// Why `text` can't be one; nil when it can.
    static func problem(_ text: String) -> String? {
        let address = text.trimmingCharacters(in: .whitespaces)
        if address.isEmpty { return "Give an address to listen on (127.0.0.1)." }
        if address == "localhost" { return nil }
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, address, &v4) == 1 || inet_pton(AF_INET6, address, &v6) == 1 { return nil }
        return "\(address) isn't an IP address (127.0.0.1, 0.0.0.0, ::1)."
    }

    /// Whether only this Mac can reach it.
    static func isLoopback(_ address: String) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(address) || address.hasPrefix("127.")
    }

    /// Where a browser reaches it: the address kubectl listens on, never
    /// `localhost` — which a browser may try as ::1 first, where a forward
    /// on 127.0.0.1 doesn't listen. A wildcard is reached on loopback; an
    /// IPv6 address in brackets.
    static func host(for address: String) -> String {
        switch address {
        case "localhost", "0.0.0.0": return loopback
        case "::", "::1": return "[::1]"
        default: return address.contains(":") ? "[\(address)]" : address
        }
    }
}

/// `kubectl port-forward` as Overterm runs it — always one pod, `--context`
/// and `--namespace` always (rule 7), the address said. A managed process
/// (`KubeForwards`), never typed into a tab; through the user's own
/// kubectl and credentials, never the proxy's socket, which refuses
/// port-forward on every context. Pure.
enum KubePortForwardCommand {
    static func arguments(
        pod: String, localPort: Int, remotePort: Int, context: String, namespace: String, address: String, cacheDirectory: String? = nil
    ) -> [String] {
        var arguments = [
            "port-forward", "pod/\(pod)", "\(localPort):\(remotePort)", "--context", context, "--namespace", namespace, "--address", address,
        ]
        if let cacheDirectory { arguments += ["--cache-dir", cacheDirectory] }
        return arguments
    }

    /// The same, as a person would type it (Copy as kubectl).
    /// Every word that isn't ours quoted for zsh, as Copy as kubectl quotes it.
    static func line(pod: String, localPort: Int, remotePort: Int, context: String, namespace: String, address: String) -> String {
        let q = KubectlLine.quoted
        return [
            "kubectl", "port-forward", q("pod/\(pod)"), "\(localPort):\(remotePort)", "--context", q(context), "--namespace", q(namespace), "--address",
            q(address),
        ].joined(separator: " ")
    }

    /// What kubectl prints once it listens: `Forwarding from 127.0.0.1:8080 -> 80`.
    static func isReady(_ line: String) -> Bool { line.hasPrefix("Forwarding from ") }
}

/// Where a Service or a Deployment points now: one of its ready pods, and
/// the pod's port. Pure over the JSON the API answered.
enum KubeForwardResolve {
    struct Pinned: Equatable, Sendable {
        var pod: String
        var remotePort: Int
    }

    enum Outcome: Equatable, Sendable {
        /// This pod, this port.
        case pinned(Pinned)
        /// No pod to go to now — none ready, the port not found: tried again.
        case waiting(String)
        /// The target itself is gone: the forward stops, and says so.
        case gone(String)
    }

    static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    /// Whether kubectl can forward to it: running, not going away.
    static func isRunning(_ pod: [String: Any]) -> Bool {
        let metadata = pod["metadata"] as? [String: Any] ?? [:]
        guard metadata["deletionTimestamp"] == nil else { return false }
        return (pod["status"] as? [String: Any])?["phase"] as? String == "Running"
    }

    /// Ready, as an endpoint is: its Ready condition, else (no conditions
    /// reported) every container ready.
    static func isReady(_ pod: [String: Any]) -> Bool {
        guard isRunning(pod) else { return false }
        let status = pod["status"] as? [String: Any] ?? [:]
        if let conditions = status["conditions"] as? [[String: Any]], let ready = conditions.first(where: { $0["type"] as? String == "Ready" }) {
            return ready["status"] as? String == "True"
        }
        let containers = status["containerStatuses"] as? [[String: Any]] ?? []
        return !containers.isEmpty && containers.allSatisfy { $0["ready"] as? Bool == true }
    }

    /// Why a pod isn't one to forward to, in a few words.
    static func notReady(_ pod: [String: Any]) -> String {
        let name = (pod["metadata"] as? [String: Any])?["name"] as? String ?? "the pod"
        if (pod["metadata"] as? [String: Any])?["deletionTimestamp"] != nil { return "pod \(name) is terminating" }
        let phase = (pod["status"] as? [String: Any])?["phase"] as? String ?? "Unknown"
        return phase == "Running" ? "pod \(name) isn't ready" : "pod \(name) is \(phase)"
    }

    /// A pod target: itself, while it runs. Nil JSON: it is gone (a 404).
    static func pod(_ name: String, _ json: [String: Any]?, port: Int) -> Outcome {
        guard let json else { return .gone("pod/\(name) is gone") }
        guard isRunning(json) else { return .waiting(notReady(json)) }
        return .pinned(Pinned(pod: name, remotePort: port))
    }

    /// The pods an EndpointSlice list says are ready, by name: endpoints
    /// whose `ready` isn't false (nil is ready, the API says), pointing at
    /// a Pod.
    static func readyPods(slices: [[String: Any]]) -> [String] {
        var names: [String] = []
        for slice in slices {
            for endpoint in slice["endpoints"] as? [[String: Any]] ?? [] {
                let conditions = endpoint["conditions"] as? [String: Any] ?? [:]
                guard conditions["ready"] as? Bool != false, conditions["terminating"] as? Bool != true else { continue }
                guard let ref = endpoint["targetRef"] as? [String: Any], ref["kind"] as? String == "Pod", let name = ref["name"] as? String else { continue }
                if !names.contains(name) { names.append(name) }
            }
        }
        return names.sorted()
    }

    /// The same from a legacy Endpoints object: its subsets' `addresses`
    /// (the ready ones; `notReadyAddresses` are not).
    static func readyPods(endpoints: [String: Any]) -> [String] {
        var names: [String] = []
        for subset in endpoints["subsets"] as? [[String: Any]] ?? [] {
            for address in subset["addresses"] as? [[String: Any]] ?? [] {
                guard let ref = address["targetRef"] as? [String: Any], ref["kind"] as? String == "Pod", let name = ref["name"] as? String else { continue }
                if !names.contains(name) { names.append(name) }
            }
        }
        return names.sorted()
    }

    /// The ready pods of a pod list (a Deployment's selector), oldest first,
    /// then by name: the one picked stays put while newer ones come and go.
    static func readyPods(_ items: [[String: Any]]) -> [String] {
        items.filter(isReady).sorted { lhs, rhs in
            let (a, b) = (created(lhs), created(rhs))
            return a == b ? name(lhs) < name(rhs) : a < b
        }.map(name)
    }

    private static func name(_ object: [String: Any]) -> String { (object["metadata"] as? [String: Any])?["name"] as? String ?? "" }
    private static func created(_ object: [String: Any]) -> String { (object["metadata"] as? [String: Any])?["creationTimestamp"] as? String ?? "" }

    /// The one of `candidates` to pin: the one pinned before while it is
    /// still among them — a forward that works isn't moved — else the first.
    static func pick(_ candidates: [String], previous: String?) -> String? {
        if let previous, candidates.contains(previous) { return previous }
        return candidates.first
    }

    /// A `LabelSelector` (a Deployment's `spec.selector`) as the server's
    /// `labelSelector`: `matchLabels` and `matchExpressions` (In, NotIn,
    /// Exists, DoesNotExist). Nil when it selects nothing it can say.
    static func labelSelector(_ selector: [String: Any]?) -> String? {
        guard let selector else { return nil }
        var terms: [String] = []
        for (key, value) in (selector["matchLabels"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
            terms.append("\(key)=\(value)")
        }
        for expression in selector["matchExpressions"] as? [[String: Any]] ?? [] {
            guard let key = expression["key"] as? String, let op = expression["operator"] as? String else { return nil }
            let values = (expression["values"] as? [Any] ?? []).map { "\($0)" }.joined(separator: ",")
            switch op {
            case "In": terms.append("\(key) in (\(values))")
            case "NotIn": terms.append("\(key) notin (\(values))")
            case "Exists": terms.append(key)
            case "DoesNotExist": terms.append("!\(key)")
            default: return nil
            }
        }
        return terms.isEmpty ? nil : terms.joined(separator: ",")
    }

    /// A Service's port as the pod has it: `targetPort` by number, by name
    /// in the pod's containers, or the Service's port when none is set.
    /// Nil when the Service has no such port, or the pod none by that name.
    static func targetPort(service: [String: Any], port: Int, pod: [String: Any]) -> Int? {
        let ports = (service["spec"] as? [String: Any])?["ports"] as? [[String: Any]] ?? []
        guard let entry = ports.first(where: { int($0["port"]) == port }) else { return nil }
        guard let target = entry["targetPort"] else { return port }
        if let number = int(target) { return number }
        guard let name = target as? String else { return nil }
        let containers = (pod["spec"] as? [String: Any])?["containers"] as? [[String: Any]] ?? []
        for container in containers {
            for declared in container["ports"] as? [[String: Any]] ?? [] where declared["name"] as? String == name {
                return int(declared["containerPort"])
            }
        }
        return nil
    }
}

/// How long a forward waits before it is started again: a second, then
/// twice as long each time up to half a minute, back to a second once one
/// has run a while — and, after `maxFailures` in a row, it stops: no
/// storm of kubectls (each may run the context's exec plugin). Pure.
struct KubeForwardBackoff: Equatable, Sendable {
    static let delays: [TimeInterval] = [1, 2, 4, 8, 15, 30]
    /// A forward up this long counts as working: what ended it starts the count again.
    static let stableAfter: TimeInterval = 30
    static let maxFailures = 8

    private(set) var failures = 0

    /// The wait before the next start, after a forward that ran `ran`
    /// seconds (0: it never started); nil when it should stop.
    mutating func next(ran: TimeInterval) -> TimeInterval? {
        if ran >= Self.stableAfter { failures = 0 }
        failures += 1
        guard failures <= Self.maxFailures else { return nil }
        return Self.delays[min(failures - 1, Self.delays.count - 1)]
    }
}

/// The local port: one asked for, checked, or a free one picked at random
/// (a quick forward) — never one another forward has, or something on
/// this Mac holds (`ListeningPorts.isBound`). Pure over what it is given.
enum KubeForwardPortChoice {
    static let range = 30000...39999

    /// Why `port` can't be the local end; nil when it can.
    static func problem(_ port: Int, taken: Set<Int>, isBound: (Int) -> Bool) -> String? {
        guard (1...65535).contains(port) else { return "A port is 1 to 65535." }
        if port < 1024 { return "Ports under 1024 need root; pick one above." }
        if taken.contains(port) { return "Another forward listens on \(port)." }
        if isBound(port) { return "Something on this Mac listens on \(port) already." }
        return nil
    }

    /// `preferred` when it is free (the remote port, 8080 → 8080), else one
    /// at random in `range`; nil when none came free in 64 tries.
    static func free(preferred: Int? = nil, taken: Set<Int>, isBound: (Int) -> Bool, random: () -> Int = { Int.random(in: range) }) -> Int? {
        if let preferred, problem(preferred, taken: taken, isBound: isBound) == nil { return preferred }
        for _ in 0..<64 {
            let port = random()
            if problem(port, taken: taken, isBound: isBound) == nil { return port }
        }
        return nil
    }
}

/// The sheet's fields (`f`): the target, the ports it offers, the one
/// picked, the local port, the address and https — a forward asked for,
/// or one being edited. Pure.
struct KubeForwardDraft: Equatable {
    var context: String
    var namespace: String
    var target: KubeForwardTarget
    var offered: [KubeForwardPortOption]
    /// The remote port, as typed or picked.
    var remote: String
    var local: String
    var address = KubeForwardAddress.loopback
    var https = false
    /// The forward being edited: only the local end changes.
    var editing: UUID?
    /// Why it can't start yet: `kubectl auth can-i` not answered, or no.
    var unavailable: String?

    /// The spec it makes, or why not.
    func spec(taken: Set<Int>, isBound: (Int) -> Bool, tab: UUID?) -> Result<KubeForwardSpec, Failure> {
        guard let remotePort = Int(remote.trimmingCharacters(in: .whitespaces)), (1...65535).contains(remotePort) else {
            return .failure(Failure("The remote port is 1 to 65535."))
        }
        guard let localPort = Int(local.trimmingCharacters(in: .whitespaces)) else { return .failure(Failure("The local port is a number.")) }
        if let problem = KubeForwardPortChoice.problem(localPort, taken: taken, isBound: isBound) { return .failure(Failure(problem)) }
        if let problem = KubeForwardAddress.problem(address) { return .failure(Failure(problem)) }
        var spec = KubeForwardSpec(context: context, namespace: namespace, target: target, remotePort: remotePort, localPort: localPort, tab: tab)
        spec.address = address.trimmingCharacters(in: .whitespaces)
        spec.https = https
        if let editing { spec.id = editing }
        return .success(spec)
    }

    struct Failure: Error, Equatable, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }
}
