import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// A Kubernetes API server played on a unix socket of its own (and on
/// 127.0.0.1, for a real `kubectl proxy` in front of it), for the tests
/// and the `kubernetes` scenario: never one of the user's clusters — this
/// Mac's current context is production.
///
/// It holds namespaces and pods (and serves empty lists of the other kinds
/// it discovers) as values, versioned as the server versions them; a change
/// sends the watch events the server would. It answers:
/// - `/version`; discovery, aggregated (`APIGroupDiscoveryList`) or the
///   legacy walk (`/api`, `/apis`, each group version's resource list);
/// - lists as Tables (`as=Table;v=v1;g=meta.k8s.io`, `includeObject`
///   honoured: None, Metadata, Object) or plain JSON, paged with `limit`
///   and `continue` (an expired `continue` is 410), with the collection's
///   resourceVersion;
/// - a plain GET of one object;
/// - watches (`watch=1`): ADDED, MODIFIED, DELETED from a resourceVersion,
///   BOOKMARK with `allowWatchBookmarks`, a 410 for one compacted away —
///   as an in-stream ERROR event, or as the answer (`goneAsAnswer`) — and
///   `timeoutSeconds`; the streaming list (`sendInitialEvents`), refused
///   as a server with the gate off refuses it (`streamingLists`);
/// - a credential failure: every answer the proxy's 500 in plain text, as
///   the spike saw an expired AWS session (`failCredentials`); 429s.
///
/// It records every request (method, path, query, Accept), so a test or
/// the scenario can show that no write method and no subresource reached
/// it. It has no exec, attach or port-forward: those are 404, recorded.
final class FakeKubeAPI: @unchecked Sendable {
    struct Pod: Equatable, Sendable {
        /// kubectl's Status column: `Running`, `CrashLoopBackOff`, `Init:0/1`…
        var status = "Running"
        var phase = "Running"
        var ready = 1
        var containers = 1
        var restarts = 0
        /// When the last restart was, as the row says it ("2m").
        var lastRestart: String?
        var ip = "10.0.0.10"
        var node = "fake-node-1"
        var image = "nginx:1.27"
    }

    struct Object: Sendable {
        /// The kind's full name: `pods`, `namespaces`, `deployments.apps`.
        var resource: String
        var namespace: String?
        var name: String
        var uid: String
        var resourceVersion: Int
        var created: Date
        var labels: [String: String] = [:]
        var pod: Pod?
    }

    struct Request: Equatable, Sendable, CustomStringConvertible {
        var method: String
        var path: String
        var query: [String: String]
        var accept: String

        var description: String { "\(method) \(path)" }
        /// A subresource: `pods/p/exec`, `services/s:80/proxy`, `pods/p/log`.
        var isSubresource: Bool { FakeKubeAPI.route(path)?.subresource != nil }
    }

    /// A kind it serves, as discovery says it.
    struct Kind: Sendable {
        var group: String
        var version: String
        var resource: String
        var kind: String
        var namespaced: Bool
        var shortNames: [String] = []
        var categories: [String] = []
        var subresources: [String] = []
        var verbs = ["create", "delete", "deletecollection", "get", "list", "patch", "update", "watch"]

        var groupVersion: String { group.isEmpty ? version : "\(group)/\(version)" }
        var fullName: String { group.isEmpty ? resource : "\(resource).\(group)" }
    }

    static let kinds: [Kind] = [
        Kind(group: "", version: "v1", resource: "namespaces", kind: "Namespace", namespaced: false, shortNames: ["ns"], subresources: ["finalize", "status"]),
        Kind(
            group: "", version: "v1", resource: "pods", kind: "Pod", namespaced: true, shortNames: ["po"], categories: ["all"],
            subresources: ["attach", "binding", "ephemeralcontainers", "eviction", "exec", "log", "portforward", "proxy", "status"]),
        Kind(group: "", version: "v1", resource: "services", kind: "Service", namespaced: true, shortNames: ["svc"], categories: ["all"], subresources: ["proxy", "status"]),
        Kind(group: "", version: "v1", resource: "configmaps", kind: "ConfigMap", namespaced: true, shortNames: ["cm"]),
        Kind(group: "", version: "v1", resource: "secrets", kind: "Secret", namespaced: true),
        Kind(group: "", version: "v1", resource: "events", kind: "Event", namespaced: true, shortNames: ["ev"]),
        Kind(group: "", version: "v1", resource: "nodes", kind: "Node", namespaced: false, shortNames: ["no"], subresources: ["proxy", "status"]),
        Kind(group: "apps", version: "v1", resource: "deployments", kind: "Deployment", namespaced: true, shortNames: ["deploy"], categories: ["all"], subresources: ["scale", "status"]),
        Kind(group: "apps", version: "v1", resource: "replicasets", kind: "ReplicaSet", namespaced: true, shortNames: ["rs"], categories: ["all"], subresources: ["scale", "status"]),
        Kind(group: "apps", version: "v1", resource: "statefulsets", kind: "StatefulSet", namespaced: true, shortNames: ["sts"], categories: ["all"], subresources: ["scale", "status"]),
        Kind(group: "batch", version: "v1", resource: "jobs", kind: "Job", namespaced: true, categories: ["all"], subresources: ["status"]),
        Kind(group: "batch", version: "v1", resource: "cronjobs", kind: "CronJob", namespaced: true, shortNames: ["cj"], categories: ["all"], subresources: ["status"]),
        Kind(group: "events.k8s.io", version: "v1", resource: "events", kind: "Event", namespaced: true, shortNames: ["ev"]),
        Kind(group: "metrics.k8s.io", version: "v1beta1", resource: "pods", kind: "PodMetrics", namespaced: true, verbs: ["get", "list"]),
        Kind(group: "metrics.k8s.io", version: "v1beta1", resource: "nodes", kind: "NodeMetrics", namespaced: false, verbs: ["get", "list"]),
    ]

    let socket: String?
    private let lock = NSLock()
    private var objects: [String: Object] = [:]
    private var history: [(version: Int, type: String, object: Object)] = []
    private var current = 1000
    /// Events up to this are gone: a watch from a version before it is 410.
    private var compacted = 0
    /// Continue tokens are only good in their generation.
    private var generation = 0
    private var watchers: [ObjectIdentifier: Watcher] = [:]
    private var asked: [Request] = []
    private var channels: [Channel] = []
    private var credentialFailure: String?
    private var throttled = 0
    private var throttleAfter = 0
    /// The next watches' answer: a status, its `Retry-After`.
    private var failedWatches: (count: Int, status: Int, retryAfter: Int?) = (0, 0, nil)
    private var settings = Settings()

    /// What a test sets, read on the event loops' threads: behind the lock.
    private struct Settings {
        var minor = "34"
        var aggregatedDiscovery = true
        var streamingLists = true
        var goneAsAnswer = false
        var failingGroups: Set<String> = []
        var interimBookmarks = false
        var unversionedLists = false
    }

    /// What `/version` says: a minor of 34 serves streaming lists.
    var minor: String {
        get { locked { settings.minor } }
        set { locked { settings.minor = newValue } }
    }
    /// Whether discovery answers aggregated when asked; off, only the legacy walk.
    var aggregatedDiscovery: Bool {
        get { locked { settings.aggregatedDiscovery } }
        set { locked { settings.aggregatedDiscovery = newValue } }
    }
    /// Whether a watch takes `sendInitialEvents` (the WatchList gate);
    /// off, it is refused with a 422, as such a server refuses it.
    var streamingLists: Bool {
        get { locked { settings.streamingLists } }
        set { locked { settings.streamingLists = newValue } }
    }
    /// A watch from a compacted version is answered 410 rather than sent an
    /// in-stream ERROR event: both happen.
    var goneAsAnswer: Bool {
        get { locked { settings.goneAsAnswer } }
        set { locked { settings.goneAsAnswer = newValue } }
    }
    /// Group versions that are down, as an aggregated API that is: their
    /// legacy resource list answers 503, aggregated discovery marks them
    /// `Stale` with no resources.
    var failingGroups: Set<String> {
        get { locked { settings.failingGroups } }
        set { locked { settings.failingGroups = newValue } }
    }
    /// A streaming list sends a plain bookmark among its initial events,
    /// before the one marked as their end.
    var interimBookmarks: Bool {
        get { locked { settings.interimBookmarks } }
        set { locked { settings.interimBookmarks = newValue } }
    }
    /// Lists answer without a resourceVersion, as metrics.k8s.io's do.
    var unversionedLists: Bool {
        get { locked { settings.unversionedLists } }
        set { locked { settings.unversionedLists = newValue } }
    }

    /// One open watch.
    private struct Watcher {
        var channel: Channel
        var resource: String
        var namespace: String?
        var table: Bool
        var includeObject: String
        var bookmarks: Bool
        var labels: [String: String]
        var sentColumns = false
    }

    /// `socket` nil: TCP only (`listenTCP`).
    init(socket: String?) {
        self.socket = socket
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func bootstrap() -> ServerBootstrap {
        ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    // No pipelining help: it stops reading while a response
                    // is open, and an idle watch would never see its client
                    // leave.
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withPipeliningAssistance: false, withErrorHandling: true)
                    try channel.pipeline.syncOperations.addHandler(FakeKubeHandler(api: self))
                }
            }
    }

    func start() throws {
        guard let socket else { return }
        try? FileManager.default.removeItem(atPath: socket)
        let bound = try bootstrap().bind(unixDomainSocketPath: socket).wait()
        locked { channels.append(bound) }
    }

    /// The same answers on 127.0.0.1, at a port of the system's: what a
    /// kubeconfig's `server: http://127.0.0.1:<port>` reaches.
    func listenTCP() throws -> Int {
        let bound = try bootstrap().bind(host: "127.0.0.1", port: 0).wait()
        locked { channels.append(bound) }
        return bound.localAddress?.port ?? 0
    }

    func stop() {
        let (open, listening) = locked {
            defer {
                watchers = [:]
                channels = []
            }
            return (watchers.values.map(\.channel), channels)
        }
        open.forEach { $0.close(promise: nil) }
        for channel in listening { try? channel.close().wait() }
        if let socket { try? FileManager.default.removeItem(atPath: socket) }
    }

    // MARK: What it was asked

    var requests: [Request] { locked { asked } }
    /// Anything but a GET.
    var writes: [Request] { requests.filter { $0.method != "GET" } }
    /// Requests that reached a subresource.
    var subresourceRequests: [Request] { requests.filter(\.isSubresource) }
    /// Watches open now.
    var openWatches: Int { locked { watchers.count } }
    func forgetRequests() { locked { asked = [] } }

    // MARK: State, as a test sets it

    var resourceVersion: Int { locked { current } }

    func addNamespace(_ name: String, labels: [String: String] = [:]) {
        change("ADDED") {
            Object(resource: "namespaces", namespace: nil, name: name, uid: UUID().uuidString.lowercased(), resourceVersion: 0, created: Date(), labels: labels)
        }
    }

    func addPod(_ name: String, namespace: String, _ pod: Pod = Pod(), labels: [String: String] = [:], created: Date = Date()) {
        change("ADDED") {
            Object(
                resource: "pods", namespace: namespace, name: name, uid: UUID().uuidString.lowercased(), resourceVersion: 0, created: created, labels: labels,
                pod: pod)
        }
    }

    /// A pod changes, as if by itself: a MODIFIED event.
    func updatePod(_ name: String, namespace: String, _ update: (inout Pod) -> Void) {
        let key = Self.key("pods", namespace, name)
        change("MODIFIED") {
            guard var object = objects[key], var pod = object.pod else { return nil }
            update(&pod)
            object.pod = pod
            return object
        }
    }

    func deletePod(_ name: String, namespace: String) {
        let key = Self.key("pods", namespace, name)
        change("DELETED") { objects[key] }
    }

    func pod(_ name: String, namespace: String) -> Pod? { locked { objects[Self.key("pods", namespace, name)]?.pod } }

    /// Applies one change under the lock and sends its event.
    private func change(_ type: String, _ make: () -> Object?) {
        let sends = locked { () -> [(Channel, Data)] in
            guard var object = make() else { return [] }
            current += 1
            object.resourceVersion = current
            let key = Self.key(object.resource, object.namespace, object.name)
            if type == "DELETED" { objects[key] = nil } else { objects[key] = object }
            history.append((current, type, object))
            return watchers.keys.compactMap { id in
                guard let watcher = watchers[id], Self.matches(object, watcher.resource, watcher.namespace, watcher.labels) else { return nil }
                return (watcher.channel, eventLine(type, object, for: id))
            }
        }
        for (channel, line) in sends { Self.write(line, to: channel) }
    }

    /// A BOOKMARK at the current version, to every watch that allows them.
    func bookmark() {
        let sends = locked { () -> [(Channel, Data)] in
            watchers.values.filter(\.bookmarks).map { ($0.channel, Self.bookmarkLine(current, table: $0.table, initialEnd: false)) }
        }
        for (channel, line) in sends { Self.write(line, to: channel) }
    }

    /// Every event up to now is gone, as etcd's compaction leaves it: a
    /// watch from a version before now is 410 (from now still works).
    func compact() { locked { compacted = current } }

    /// Every open watch is told its version is too old (an in-stream 410)
    /// and ended.
    func expireWatches() {
        let open = locked { () -> [Channel] in
            defer { watchers = [:] }
            return watchers.values.map(\.channel)
        }
        for channel in open {
            Self.write(Self.goneLine(), to: channel)
            Self.end(channel)
        }
    }

    /// Every open watch ends, as the server's timeout ends one.
    func endWatches() {
        let open = locked { () -> [Channel] in
            defer { watchers = [:] }
            return watchers.values.map(\.channel)
        }
        open.forEach(Self.end)
    }

    /// The `continue` tokens given so far expire (about 5 minutes on a server).
    func expireContinueTokens() { locked { generation += 1 } }

    /// Every answer from now on is the proxy's own 500 in plain text — an
    /// exec plugin that failed — until `nil`.
    func failCredentials(_ text: String? = "getting credentials: exec: executable aws failed with exit code 255") {
        locked { credentialFailure = text }
    }

    /// The next `count` requests are 429, `Retry-After` said.
    func throttle(_ count: Int, retryAfter: Int = 0) {
        locked {
            throttled = count
            throttleAfter = retryAfter
        }
    }

    /// The next `count` watch requests are answered `status` (a JSON
    /// Status; a 429's `Retry-After` said), lists left alone.
    func failWatches(_ count: Int, status: Int, retryAfter: Int? = nil) {
        locked { failedWatches = (count, status, retryAfter) }
    }

    // MARK: Paths

    struct Route {
        var kind: Kind?
        var groupVersion: String
        var namespace: String?
        var resource: String?
        var name: String?
        var subresource: String?
    }

    /// A resource path read: `/api/v1/namespaces/ns/pods/p/log`. Nil for
    /// `/version`, discovery's roots and anything else.
    static func route(_ path: String) -> Route? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map { $0.removingPercentEncoding ?? String($0) }
        let groupVersion: String
        var rest: ArraySlice<String>
        if parts.first == "api", parts.count >= 2 {
            groupVersion = parts[1]
            rest = parts.dropFirst(2)
        } else if parts.first == "apis", parts.count >= 3 {
            groupVersion = parts[1] + "/" + parts[2]
            rest = parts.dropFirst(3)
        } else {
            return nil
        }
        var route = Route(groupVersion: groupVersion)
        if rest.first == "namespaces", rest.count >= 3 {
            let third = rest[rest.startIndex + 2]
            if groupVersion == "v1", !kinds.contains(where: { $0.groupVersion == "v1" && $0.resource == third }) {
                // `namespaces/shop/finalize`, `/status`: the Namespace's own
                // subresource, not a resource in it.
                route.resource = "namespaces"
                route.name = rest[rest.startIndex + 1]
                route.subresource = rest.dropFirst(2).joined(separator: "/")
                route.kind = kinds.first { $0.groupVersion == "v1" && $0.resource == "namespaces" }
                return route
            }
            route.namespace = rest[rest.startIndex + 1]
            rest = rest.dropFirst(2)
        }
        guard let resource = rest.first else { return route }
        route.resource = resource
        rest = rest.dropFirst()
        route.name = rest.first
        if rest.count > 1 { route.subresource = rest.dropFirst().joined(separator: "/") }
        route.kind = kinds.first { $0.groupVersion == groupVersion && $0.resource == resource }
        return route
    }

    private static func key(_ resource: String, _ namespace: String?, _ name: String) -> String { "\(resource)|\(namespace ?? "")|\(name)" }

    /// Where a page ended, ordered as the list is (namespace, then name).
    private static func pageKey(_ object: Object) -> String { (object.namespace ?? "") + "\u{0}" + object.name }

    private static func matches(_ object: Object, _ resource: String, _ namespace: String?, _ labels: [String: String]) -> Bool {
        object.resource == resource && (namespace == nil || object.namespace == namespace) && labels.allSatisfy { object.labels[$0.key] == $0.value }
    }

    /// `a=b,c=d` — equality only, as far as the fake reads selectors.
    private static func selector(_ text: String?) -> [String: String] {
        var labels: [String: String] = [:]
        for part in (text ?? "").split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { labels[pair[0].trimmingCharacters(in: CharacterSet(charactersIn: "= "))] = pair[1] }
        }
        return labels
    }

    // MARK: Answers

    enum Answer {
        case json(Int, Data)
        case text(Int, String)
        case raw(Int, Data, [(String, String)])
        /// A watch's head now, then its lines; ended after `timeout` seconds.
        case watch(lines: [Data], end: Bool, timeout: Int?)
    }

    func answer(_ method: HTTPMethod, _ uri: String, accept: String, on channel: Channel) -> Answer {
        let components = URLComponents(string: "http://localhost" + uri)
        let path = components?.percentEncodedPath ?? uri
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        let isWatch = query["watch"] == "1" || query["watch"] == "true"
        let (failure, throttle, failedWatch, settings) = locked { () -> (String?, Int?, (status: Int, retryAfter: Int?)?, Settings) in
            asked.append(Request(method: method.rawValue, path: path, query: query, accept: accept))
            var failedWatch: (status: Int, retryAfter: Int?)?
            if isWatch && failedWatches.count > 0 {
                failedWatches.count -= 1
                failedWatch = (failedWatches.status, failedWatches.retryAfter)
            }
            if throttled > 0 {
                throttled -= 1
                return (credentialFailure, throttleAfter, failedWatch, self.settings)
            }
            return (credentialFailure, nil, failedWatch, self.settings)
        }
        if let failure { return .text(500, failure) }
        if let throttle {
            return .raw(
                429, Self.status(429, "TooManyRequests", "Too many requests, please try again later."),
                [("Content-Type", "application/json"), ("Retry-After", String(throttle))])
        }
        if let failedWatch {
            var headers = [("Content-Type", "application/json")]
            if let after = failedWatch.retryAfter { headers.append(("Retry-After", String(after))) }
            let reason = failedWatch.status == 429 ? "TooManyRequests" : failedWatch.status == 503 ? "ServiceUnavailable" : "InternalError"
            return .raw(failedWatch.status, Self.status(failedWatch.status, reason, "the server is busy (HTTP \(failedWatch.status))"), headers)
        }
        guard method == .GET else { return .json(405, Self.status(405, "MethodNotAllowed", "the server does not allow this method on the requested resource")) }
        switch path {
        case "/version":
            return .json(200, Self.encode(["major": "1", "minor": settings.minor, "gitVersion": "v1.\(settings.minor.prefix { $0.isNumber }).1", "platform": "linux/arm64"]))
        case "/api", "/apis":
            if settings.aggregatedDiscovery && accept.contains("as=APIGroupDiscoveryList") {
                return .json(200, Self.aggregated(core: path == "/api", stale: settings.failingGroups))
            }
            return .json(200, path == "/api" ? Self.encode(["kind": "APIVersions", "versions": ["v1"]]) : groupList())
        default: break
        }
        guard let route = Self.route(path) else { return .json(404, Self.status(404, "NotFound", "the server could not find the requested resource")) }
        guard let resource = route.resource else {
            if settings.failingGroups.contains(route.groupVersion) { return .json(503, Self.status(503, "ServiceUnavailable", "the server is currently unable to handle the request")) }
            return .json(200, resourceList(route.groupVersion))
        }
        guard let kind = route.kind, route.subresource == nil else {
            return .json(404, Self.status(404, "NotFound", "the server could not find the requested resource"))
        }
        if kind.namespaced == false && route.namespace != nil { return .json(404, Self.status(404, "NotFound", "the server could not find the requested resource")) }
        if let name = route.name {
            guard let object = locked({ objects[Self.key(kind.fullName, route.namespace, name)] }) else {
                return .json(404, Self.status(404, "NotFound", "\(resource) \"\(name)\" not found"))
            }
            return .json(200, Self.encode(Self.full(object, kind)))
        }
        let table = accept.contains("as=Table")
        let includeObject = query["includeObject"] ?? "Metadata"
        let labels = Self.selector(query["labelSelector"])
        if isWatch {
            return watch(kind, namespace: route.namespace, query: query, table: table, includeObject: includeObject, labels: labels, channel: channel)
        }
        return list(kind, namespace: route.namespace, query: query, table: table, includeObject: includeObject, labels: labels)
    }

    private func list(_ kind: Kind, namespace: String?, query: [String: String], table: Bool, includeObject: String, labels: [String: String]) -> Answer {
        locked {
            var version = current
            var after: String?
            if let token = query["continue"], !token.isEmpty {
                guard let decoded = Data(base64Encoded: token).map({ String(decoding: $0, as: UTF8.self) }),
                    case let parts = decoded.split(separator: "|", maxSplits: 2).map(String.init), parts.count == 3, Int(parts[0]) == generation,
                    let at = Int(parts[1])
                else {
                    return .json(
                        410,
                        Self.status(
                            410, "Expired",
                            "The provided continue parameter is too old to display a consistent list result. You can start a new list without the continue parameter."))
                }
                version = at
                after = parts[2]
            }
            var matching = objects.values.filter { Self.matches($0, kind.fullName, namespace, labels) }.sorted {
                ($0.namespace ?? "", $0.name) < ($1.namespace ?? "", $1.name)
            }
            if let after { matching = matching.filter { Self.pageKey($0) > after } }
            var token: String?
            var remaining: Int?
            if let limit = Int(query["limit"] ?? ""), limit > 0, matching.count > limit {
                remaining = matching.count - limit
                matching = Array(matching.prefix(limit))
                let last = matching.last!
                token = Data("\(generation)|\(version)|\(Self.pageKey(last))".utf8).base64EncodedString()
            }
            var metadata: [String: Any] = settings.unversionedLists ? [:] : ["resourceVersion": String(version)]
            if let token { metadata["continue"] = token }
            if let remaining { metadata["remainingItemCount"] = remaining }
            if table {
                var object = Self.tableObject(matching, kind, includeObject: includeObject, columns: true)
                object["metadata"] = metadata
                return .json(200, Self.encode(object))
            }
            return .json(
                200, Self.encode(["kind": kind.kind + "List", "apiVersion": kind.groupVersion, "metadata": metadata, "items": matching.map { Self.full($0, kind) }]))
        }
    }

    private func watch(
        _ kind: Kind, namespace: String?, query: [String: String], table: Bool, includeObject: String, labels: [String: String], channel: Channel
    ) -> Answer {
        let timeout = Int(query["timeoutSeconds"] ?? "")
        let bookmarks = query["allowWatchBookmarks"] == "true"
        let initialEvents = query["sendInitialEvents"] == "true"
        if initialEvents && !locked({ settings.streamingLists }) {
            return .json(
                422,
                Self.status(
                    422, "Invalid", "ListOptions.meta.k8s.io \"\" is invalid: sendInitialEvents: Forbidden: sendInitialEvents is forbidden for watch unless the WatchList feature gate is enabled"))
        }
        return locked {
            let id = ObjectIdentifier(channel)
            watchers[id] = Watcher(
                channel: channel, resource: kind.fullName, namespace: namespace, table: table, includeObject: includeObject, bookmarks: bookmarks, labels: labels)
            let matching = { (object: Object) in Self.matches(object, kind.fullName, namespace, labels) }
            let version = query["resourceVersion"] ?? ""
            if initialEvents || version.isEmpty || version == "0" {
                // Every object there now, ADDED; a streaming list ends with a bookmark.
                var lines = objects.values.filter(matching).sorted { ($0.namespace ?? "", $0.name) < ($1.namespace ?? "", $1.name) }.map {
                    eventLine("ADDED", $0, for: id)
                }
                if initialEvents && settings.interimBookmarks && bookmarks {
                    // One before the end: it moves the version on, it isn't the list.
                    lines.insert(Self.bookmarkLine(current, table: table, initialEnd: false), at: min(1, lines.count))
                }
                if initialEvents { lines.append(Self.bookmarkLine(current, table: table, initialEnd: true)) }
                return .watch(lines: lines, end: false, timeout: timeout)
            }
            guard let from = Int(version), from >= compacted else {
                watchers[id] = nil
                if settings.goneAsAnswer { return .json(410, Self.status(410, "Expired", "too old resource version: \(version) (\(compacted))")) }
                return .watch(lines: [Self.goneLine(version, compacted)], end: true, timeout: nil)
            }
            let lines = history.filter { $0.version > from && matching($0.object) }.map { eventLine($0.type, $0.object, for: id) }
            return .watch(lines: lines, end: false, timeout: timeout)
        }
    }

    /// Called when a watch's connection goes.
    fileprivate func forget(_ channel: Channel) { locked { watchers[ObjectIdentifier(channel)] = nil } }

    // MARK: Objects as the server writes them

    /// One event, its object as the watch asked for it. Under the lock.
    private func eventLine(_ type: String, _ object: Object, for id: ObjectIdentifier) -> Data {
        guard var watcher = watchers[id], let kind = Self.kinds.first(where: { $0.fullName == object.resource }) else { return Data() }
        var rendered: [String: Any]
        if watcher.table {
            rendered = Self.tableObject([object], kind, includeObject: watcher.includeObject, columns: !watcher.sentColumns)
            rendered["metadata"] = ["resourceVersion": String(object.resourceVersion)]
            watcher.sentColumns = true
            watchers[id] = watcher
        } else {
            rendered = Self.full(object, kind)
        }
        return Self.line(["type": type, "object": rendered])
    }

    private static func bookmarkLine(_ version: Int, table: Bool, initialEnd: Bool) -> Data {
        var metadata: [String: Any] = ["resourceVersion": String(version)]
        if initialEnd { metadata["annotations"] = ["k8s.io/initial-events-end": "true"] }
        let object: [String: Any] =
            table ? ["kind": "Table", "apiVersion": "meta.k8s.io/v1", "metadata": metadata, "rows": [Any]()] : ["kind": "Pod", "apiVersion": "v1", "metadata": metadata]
        return line(["type": "BOOKMARK", "object": object])
    }

    private static func goneLine(_ version: String = "", _ oldest: Int = 0) -> Data {
        line(["type": "ERROR", "object": statusObject(410, "Expired", "too old resource version: \(version) (\(oldest))")])
    }

    static func columns(for kind: Kind) -> [[String: Any]] {
        func column(_ name: String, _ type: String = "string", format: String = "", priority: Int = 0, _ description: String = "") -> [String: Any] {
            ["name": name, "type": type, "format": format, "description": description, "priority": priority]
        }
        let name = column("Name", format: "name", "Name must be unique within a namespace.")
        switch kind.fullName {
        case "pods":
            return [
                name, column("Ready", "The aggregate readiness state of this pod for accepting traffic."),
                column("Status", "The aggregate status of the containers in this pod."),
                column("Restarts", "The number of times the containers in this pod have been restarted and when the last container in this pod has restarted."),
                column("Age", "CreationTimestamp is a timestamp representing the server time when this object was created."),
                column("IP", priority: 1, "IP address allocated to the pod. Routable at least within the cluster. Empty if not yet allocated."),
                column("Node", priority: 1, "NodeName is a request to schedule this pod onto a specific node."),
                column("Nominated Node", priority: 1, "nominatedNodeName is set only when this pod preempts other pods on the node."),
                column("Readiness Gates", priority: 1, "If specified, all readiness gates will be evaluated for pod readiness."),
            ]
        case "namespaces":
            return [name, column("Status", "The status of the namespace"), column("Age")]
        default:
            return [name, column("Age")]
        }
    }

    static func cells(_ object: Object) -> [Any] {
        let age = age(since: object.created)
        if let pod = object.pod {
            let restarts: Any = pod.restarts > 0 && pod.lastRestart != nil ? "\(pod.restarts) (\(pod.lastRestart!) ago)" : pod.restarts
            return [object.name, "\(pod.ready)/\(pod.containers)", pod.status, restarts, age, pod.ip, pod.node, "<none>", "<none>"]
        }
        if object.resource == "namespaces" { return [object.name, "Active", age] }
        return [object.name, age]
    }

    private static func tableObject(_ objects: [Object], _ kind: Kind, includeObject: String, columns: Bool) -> [String: Any] {
        let rows: [[String: Any]] = objects.map { object in
            var row: [String: Any] = ["cells": cells(object)]
            switch includeObject {
            case "None": break
            case "Object": row["object"] = full(object, kind)
            default:
                row["object"] = ["kind": "PartialObjectMetadata", "apiVersion": "meta.k8s.io/v1", "metadata": metadata(object, managedFields: false)]
            }
            return row
        }
        var table: [String: Any] = ["kind": "Table", "apiVersion": "meta.k8s.io/v1", "rows": rows]
        if columns { table["columnDefinitions"] = Self.columns(for: kind) }
        return table
    }

    private static func time(_ date: Date) -> String { date.formatted(.iso8601) }

    private static func metadata(_ object: Object, managedFields: Bool) -> [String: Any] {
        var metadata: [String: Any] = [
            "name": object.name, "uid": object.uid, "resourceVersion": String(object.resourceVersion), "creationTimestamp": time(object.created),
        ]
        if let namespace = object.namespace { metadata["namespace"] = namespace }
        if !object.labels.isEmpty { metadata["labels"] = object.labels }
        if managedFields {
            metadata["managedFields"] = [
                [
                    "manager": "kubectl-client-side-apply", "operation": "Update", "apiVersion": "v1", "time": time(object.created),
                    "fieldsType": "FieldsV1", "fieldsV1": ["f:metadata": ["f:labels": [".": [String: Any]()]], "f:spec": ["f:containers": [String: Any]()]],
                ]
            ]
        }
        return metadata
    }

    /// The object whole, as a plain GET answers it.
    static func full(_ object: Object, _ kind: Kind) -> [String: Any] {
        var full: [String: Any] = ["kind": kind.kind, "apiVersion": kind.groupVersion, "metadata": metadata(object, managedFields: true)]
        if let pod = object.pod {
            let names = (0..<pod.containers).map { $0 == 0 ? "app" : "sidecar-\($0)" }
            full["spec"] = ["containers": names.map { ["name": $0, "image": pod.image] }, "nodeName": pod.node, "restartPolicy": "Always"]
            full["status"] = [
                "phase": pod.phase, "podIP": pod.ip,
                "containerStatuses": names.enumerated().map { index, name in
                    [
                        "name": name, "image": pod.image, "ready": index < pod.ready, "restartCount": index == 0 ? pod.restarts : 0,
                        "state": index < pod.ready ? ["running": ["startedAt": time(object.created)]] : ["waiting": ["reason": pod.status]],
                    ] as [String: Any]
                },
            ]
        } else if object.resource == "namespaces" {
            full["spec"] = ["finalizers": ["kubernetes"]]
            full["status"] = ["phase": "Active"]
        }
        return full
    }

    /// kubectl's short ages: `45s`, `3m12s`, `40m`, `5h`, `3d`.
    static func age(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 120 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 10 { return "\(minutes)m\(seconds % 60)s" }
        if minutes < 180 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    // MARK: Discovery

    private static func aggregated(core: Bool, stale: Set<String>) -> Data {
        let served = kinds.filter { $0.group.isEmpty == core }
        var groups: [String] = []
        for kind in served where !groups.contains(kind.group) { groups.append(kind.group) }
        let items: [[String: Any]] = groups.map { group in
            let kinds = served.filter { $0.group == group }
            let resources: [[String: Any]] = kinds.map { kind in
                [
                    "resource": kind.resource, "responseKind": ["group": kind.group, "version": kind.version, "kind": kind.kind],
                    "scope": kind.namespaced ? "Namespaced" : "Cluster", "singularResource": kind.kind.lowercased(), "verbs": kind.verbs,
                    "shortNames": kind.shortNames, "categories": kind.categories,
                    "subresources": kind.subresources.map { ["subresource": $0, "verbs": ["get"]] },
                ]
            }
            if stale.contains(kinds[0].groupVersion) {
                return ["metadata": ["name": group], "versions": [["version": kinds[0].version, "resources": [Any](), "freshness": "Stale"]]]
            }
            return ["metadata": ["name": group], "versions": [["version": kinds[0].version, "resources": resources, "freshness": "Current"]]]
        }
        return encode(["kind": "APIGroupDiscoveryList", "apiVersion": "apidiscovery.k8s.io/v2", "metadata": [String: Any](), "items": items])
    }

    private func groupList() -> Data {
        var groups: [(String, String)] = []
        for kind in Self.kinds where !kind.group.isEmpty && !groups.contains(where: { $0.0 == kind.group }) { groups.append((kind.group, kind.version)) }
        let list: [[String: Any]] = groups.map { group, version in
            let preferred = ["groupVersion": "\(group)/\(version)", "version": version]
            return ["name": group, "versions": [preferred], "preferredVersion": preferred]
        }
        return Self.encode(["kind": "APIGroupList", "apiVersion": "v1", "groups": list])
    }

    private func resourceList(_ groupVersion: String) -> Data {
        var resources: [[String: Any]] = []
        for kind in Self.kinds where kind.groupVersion == groupVersion {
            resources.append([
                "name": kind.resource, "singularName": kind.kind.lowercased(), "namespaced": kind.namespaced, "kind": kind.kind, "verbs": kind.verbs,
                "shortNames": kind.shortNames, "categories": kind.categories,
            ])
            for subresource in kind.subresources {
                resources.append(["name": "\(kind.resource)/\(subresource)", "singularName": "", "namespaced": kind.namespaced, "kind": kind.kind, "verbs": ["get"]])
            }
        }
        return Self.encode(["kind": "APIResourceList", "apiVersion": "v1", "groupVersion": groupVersion, "resources": resources])
    }

    // MARK: Bytes

    static func statusObject(_ code: Int, _ reason: String, _ message: String) -> [String: Any] {
        ["kind": "Status", "apiVersion": "v1", "metadata": [String: Any](), "status": "Failure", "message": message, "reason": reason, "code": code]
    }

    static func status(_ code: Int, _ reason: String, _ message: String) -> Data { encode(statusObject(code, reason, message)) }

    static func encode(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data() }

    private static func line(_ object: Any) -> Data {
        var data = encode(object)
        data.append(0x0A)
        return data
    }

    fileprivate static func write(_ line: Data, to channel: Channel) {
        guard !line.isEmpty else { return }
        channel.eventLoop.execute {
            channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: line))), promise: nil)
        }
    }

    /// A watch's response ended, as the server ends one.
    fileprivate static func end(_ channel: Channel) {
        channel.eventLoop.execute {
            channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) }
        }
    }
}

/// One request a connection: its head, its body passed over, then the
/// answer — or, for a watch, a head now and the events as they come.
private final class FakeKubeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let api: FakeKubeAPI
    private var head: HTTPRequestHead?
    private var timeout: Scheduled<Void>?

    init(api: FakeKubeAPI) {
        self.api = api
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): self.head = head
        case .body: break
        case .end:
            guard let head else { return }
            respond(context, head)
        }
    }

    private func respond(_ context: ChannelHandlerContext, _ request: HTTPRequestHead) {
        let channel = context.channel
        let answer = api.answer(request.method, request.uri, accept: request.headers["Accept"].joined(separator: ", "), on: channel)
        func whole(_ status: Int, _ data: Data, _ headers: [(String, String)]) {
            var head = HTTPResponseHead(version: request.version, status: HTTPResponseStatus(statusCode: status), headers: HTTPHeaders(headers))
            head.headers.add(name: "Content-Length", value: "\(data.count)")
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            if !data.isEmpty { context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: data)))), promise: nil) }
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
        }
        switch answer {
        case .json(let status, let data): whole(status, data, [("Content-Type", "application/json")])
        case .text(let status, let text): whole(status, Data(text.utf8), [("Content-Type", "text/plain; charset=utf-8")])
        case .raw(let status, let data, let headers): whole(status, data, headers)
        case .watch(let lines, let end, let seconds):
            var head = HTTPResponseHead(version: request.version, status: .ok, headers: HTTPHeaders([("Content-Type", "application/json")]))
            head.headers.add(name: "Transfer-Encoding", value: "chunked")
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            for line in lines { context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: line)))), promise: nil) }
            context.flush()
            if end {
                context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
            } else if let seconds, seconds > 0 {
                let api = api
                timeout = channel.eventLoop.scheduleTask(in: .seconds(Int64(seconds))) {
                    api.forget(channel)
                    FakeKubeAPI.end(channel)
                }
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        timeout?.cancel()
        api.forget(context.channel)
    }
}
