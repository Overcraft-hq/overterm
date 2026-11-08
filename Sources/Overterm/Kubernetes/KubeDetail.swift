import Foundation

/// One object a detail shows: which context, which kind, where, which.
struct KubeObjectRef: Hashable, Sendable, CustomStringConvertible {
    var context: String
    var kind: KubeResourceKind
    var namespace: String?
    var name: String

    init(context: String, kind: KubeResourceKind, namespace: String?, name: String) {
        self.context = context
        self.kind = kind
        self.namespace = kind.namespaced ? namespace : nil
        self.name = name
    }

    /// `pods shop/web-7d9`, `nodes fake-node-1`.
    var description: String { "\(kind.fullName) \(namespace.map { "\($0)/" } ?? "")\(name)" }

    /// A Secret: its object is every value at once, so a detail never GETs
    /// it — Show does, on purpose (docs/design/kubernetes/analysis.md, rule 9).
    var isSecret: Bool { kind.group.isEmpty && kind.resource == "secrets" }

    /// A pod: its detail has a Logs tab.
    var isPod: Bool { kind.group.isEmpty && kind.resource == "pods" && namespace != nil }

    /// A workload, a Job or a Service: it picks pods by a label selector,
    /// so its detail has a Logs tab too — theirs, merged (stage 2e).
    var selectsPods: Bool {
        guard namespace != nil else { return false }
        switch kind.group {
        case "apps": return ["deployments", "statefulsets", "daemonsets", "replicasets"].contains(kind.resource)
        case "batch": return kind.resource == "jobs"
        case "": return kind.resource == "services"
        default: return false
        }
    }

    /// Its detail has a Logs tab: a pod's own, or the pods it picks, merged.
    var hasLogs: Bool { isPod || selectsPods }

    /// A Deployment, StatefulSet or DaemonSet: its detail has a History tab
    /// (its change timeline, 3.6).
    var hasHistory: Bool { KubeTimeline.Source.of(self) != nil }

    /// Its detail has a Metrics tab (docs/design/kubernetes/metrics.md,
    /// 2.1): a pod's, sampled from metrics-server (M3a). Workloads, HPAs,
    /// namespaces and nodes come with M3b.
    var hasMetrics: Bool { isPod }

    static func == (lhs: KubeObjectRef, rhs: KubeObjectRef) -> Bool {
        lhs.context == rhs.context && lhs.kind.fullName == rhs.kind.fullName && lhs.namespace == rhs.namespace && lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(context)
        hasher.combine(kind.fullName)
        hasher.combine(namespace)
        hasher.combine(name)
    }
}

/// Another object an object names — an owner, its node, the pods its
/// selector picks, a Service a rule sends to — by `apiVersion` and Kind,
/// as references are written; discovery says where it is (`resolve`).
struct KubeLink: Hashable, Sendable {
    var apiVersion: String
    var kind: String
    var namespace: String?
    var name: String

    /// The kind as the context serves it — at the reference's version, else
    /// the group's preferred one — and the object's ref; nil when it serves
    /// no such kind.
    func resolve(in discovery: KubeDiscovery, context: String) -> KubeObjectRef? {
        guard let served = discovery.kind(apiVersion: apiVersion, kind: kind) else { return nil }
        return KubeObjectRef(context: context, kind: served, namespace: namespace, name: name)
    }
}

extension KubeDiscovery {
    /// The kind a reference means (`apps/v1` and `ReplicaSet`): its group's
    /// kind of that Kind, at the reference's version when served.
    func kind(apiVersion: String, kind: String) -> KubeResourceKind? {
        let parts = apiVersion.split(separator: "/", maxSplits: 1).map(String.init)
        let group = parts.count == 2 ? parts[0] : ""
        let version = parts.last ?? ""
        let same = kinds.filter { $0.group == group && $0.kind == kind }
        return same.first { $0.version == version } ?? same.first
    }
}

/// Where a page's detail has been: back and forward across resources and
/// kinds, as a browser keeps it. A visit from the list (a row picked, the
/// arrows moving down it) replaces one that came from the same kind's list
/// in the same context, so walking a list isn't a history of every row
/// passed; another kind's row, or a link followed, is a visit of its own.
/// Pure.
struct KubeHistory: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        /// A row of the list.
        case list
        /// A link in a detail, or a search's answer.
        case link
    }

    private(set) var back: [KubeObjectRef] = []
    private(set) var current: KubeObjectRef?
    private(set) var forward: [KubeObjectRef] = []
    private var currentOrigin: Origin = .link
    /// The most kept behind.
    var limit: Int

    init(limit: Int = 50) { self.limit = limit }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// `ref` shown. The one shown again is no visit; a new one drops what
    /// was ahead.
    mutating func visit(_ ref: KubeObjectRef, from origin: Origin) {
        guard ref != current else {
            currentOrigin = origin
            return
        }
        if let current {
            // Only walking one list collapses: a row of another kind's list,
            // or another context's, is a visit of its own.
            let walking =
                origin == .list && currentOrigin == .list && current.kind.fullName == ref.kind.fullName
                && current.context == ref.context
            if !walking {
                back.append(current)
                if back.count > limit { back.removeFirst(back.count - limit) }
            }
        } else if back.last == ref {
            // The one just closed, opened again: back goes past it.
            back.removeLast()
        }
        current = ref
        currentOrigin = origin
        forward = []
    }

    /// The one before, now current; nil when there is none.
    mutating func goBack() -> KubeObjectRef? {
        guard let previous = back.popLast() else { return nil }
        if let current { forward.append(current) }
        current = previous
        currentOrigin = .link
        return previous
    }

    mutating func goForward() -> KubeObjectRef? {
        guard let next = forward.popLast() else { return nil }
        if let current { back.append(current) }
        current = next
        currentOrigin = .link
        return next
    }

    /// The detail closed: what shows is nothing, the way back kept.
    mutating func leave() {
        if let current { back.append(current) }
        current = nil
        forward = []
        currentOrigin = .link
    }

    /// Everything forgotten: another context.
    mutating func clear() { self = KubeHistory(limit: limit) }
}

/// The detail's tabs.
enum KubeDetailTab: String, CaseIterable, Identifiable, Sendable {
    case overview, logs, yaml, events, history, metrics

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .logs: "Logs"
        case .yaml: "YAML"
        case .events: "Events"
        case .history: "History"
        case .metrics: "Metrics"
        }
    }

    /// The tabs an object's detail has: Logs a pod's, and a workload's
    /// (its pods', merged); History a Deployment's, StatefulSet's or
    /// DaemonSet's; Metrics a pod's.
    static func tabs(for ref: KubeObjectRef) -> [KubeDetailTab] {
        allCases.filter { tab in
            switch tab {
            case .logs: ref.hasLogs
            case .history: ref.hasHistory
            case .metrics: ref.hasMetrics
            default: true
            }
        }
    }
}

/// One of an object's events (core `v1` Event: what `kubectl describe`
/// lists), as the detail's Events tab shows it. Pure.
struct KubeEvent: Equatable, Sendable, Identifiable {
    var id: String
    /// `Normal` or `Warning`.
    var type: String
    var reason: String
    var message: String
    var count: Int
    var first: Date?
    /// When it was last seen: `lastTimestamp`, a series' last, `eventTime`, the first.
    var last: Date?
    /// Who said it: the reporting component, and its host.
    var source: String
    /// What it is about: `involvedObject`'s Kind and name.
    var objectKind = ""
    var object = ""

    var isWarning: Bool { type == "Warning" }

    /// The events of an object, as kubectl describe asks for them: by its
    /// name, namespace, Kind and — when known — uid (`involvedObject.*`).
    static func fieldSelector(kind: String, name: String, namespace: String?, uid: String?) -> String {
        var parts = ["involvedObject.name=\(name)"]
        if let namespace { parts.append("involvedObject.namespace=\(namespace)") }
        if !kind.isEmpty { parts.append("involvedObject.kind=\(kind)") }
        if let uid, !uid.isEmpty { parts.append("involvedObject.uid=\(uid)") }
        return parts.joined(separator: ",")
    }

    /// An EventList's events, newest first (last seen, else first).
    static func list(_ data: Data) throws -> [KubeEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KubeTableReader.Malformed(detail: String(decoding: data.prefix(120), as: UTF8.self))
        }
        let events = (object["items"] as? [[String: Any]] ?? []).map(Self.init(item:))
        return newestFirst(events)
    }

    static func newestFirst(_ events: [KubeEvent]) -> [KubeEvent] {
        events.enumerated()
            .sorted { a, b in
                switch (a.element.last ?? a.element.first, b.element.last ?? b.element.first) {
                case (let x?, let y?) where x != y: x > y
                case (.some, nil): true
                case (nil, .some): false
                default: a.offset < b.offset
                }
            }
            .map(\.element)
    }

    init(
        id: String, type: String, reason: String, message: String, count: Int = 1, first: Date? = nil, last: Date? = nil, source: String = "",
        objectKind: String = "", object: String = ""
    ) {
        self.objectKind = objectKind
        self.object = object
        self.id = id
        self.type = type
        self.reason = reason
        self.message = message
        self.count = count
        self.first = first
        self.last = last
        self.source = source
    }

    init(item: [String: Any]) {
        let metadata = item["metadata"] as? [String: Any] ?? [:]
        let series = item["series"] as? [String: Any]
        let source = item["source"] as? [String: Any]
        let time = { (key: String) in (item[key] as? String).flatMap(KubeTime.date) }
        let first = time("firstTimestamp") ?? time("eventTime") ?? (metadata["creationTimestamp"] as? String).flatMap(KubeTime.date)
        let last = time("lastTimestamp") ?? (series?["lastObservedTime"] as? String).flatMap(KubeTime.date) ?? time("eventTime") ?? first
        let component = (source?["component"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? item["reportingComponent"] as? String ?? ""
        let host = (source?["host"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? item["reportingInstance"] as? String
        let involved = item["involvedObject"] as? [String: Any] ?? [:]
        self.init(
            id: metadata["uid"] as? String ?? metadata["name"] as? String ?? UUID().uuidString, type: item["type"] as? String ?? "Normal",
            reason: item["reason"] as? String ?? "", message: (item["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            count: KubeRollout.int(item["count"]) ?? KubeRollout.int(series?["count"]) ?? 1, first: first, last: last,
            source: [component, host].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "),
            objectKind: involved["kind"] as? String ?? "", object: involved["name"] as? String ?? "")
    }
}

/// Kubernetes' times: RFC 3339, with or without fractions (`eventTime`'s
/// MicroTime has them). Pure.
enum KubeTime {
    static func date(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

/// A label selector as the API writes one (`matchLabels`,
/// `matchExpressions`) — or a Service's plain map — in the words a list's
/// `labelSelector` takes. Pure.
enum KubeSelector {
    /// `app=web,tier in (a,b),!legacy`; nil when there is no selector, or
    /// one of an operator the words can't say.
    static func text(_ selector: Any?) -> String? {
        guard let selector = selector as? [String: Any] else { return nil }
        let isStructured = selector["matchLabels"] != nil || selector["matchExpressions"] != nil
        let labels = (isStructured ? selector["matchLabels"] : selector) as? [String: Any] ?? [:]
        var parts = labels.keys.sorted().compactMap { key in (labels[key] as? String).map { "\(key)=\($0)" } }
        for expression in selector["matchExpressions"] as? [[String: Any]] ?? [] {
            guard let key = expression["key"] as? String else { return nil }
            let values = (expression["values"] as? [String] ?? []).sorted().joined(separator: ",")
            switch expression["operator"] as? String {
            case "In": parts.append("\(key) in (\(values))")
            case "NotIn": parts.append("\(key) notin (\(values))")
            case "Exists": parts.append(key)
            case "DoesNotExist": parts.append("!\(key)")
            default: return nil
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }
}
