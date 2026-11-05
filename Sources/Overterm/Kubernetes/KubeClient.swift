import Foundation
import NIOHTTP1

/// How a `KubeClient`'s requests reach a cluster: a context's proxy socket
/// (`KubeProxyConnection`, through `KubeProxies`), or any transport — a
/// test's fake API server (`KubeSocketConnection`).
///
/// Reads are GETs, with no method to pass. A write is a path of its own
/// (`write`), refused unless the connection's context is writable for
/// this session — and only the page's guard path sends one, after its
/// access review and confirmation (`KubernetesPageModel+Writes`); a
/// read-only context's socket refuses writes anyway.
protocol KubeConnection: Sendable {
    func get(_ path: String, headers: [(String, String)]) async throws -> HTTPResponse
    /// A response read as it arrives: a watch.
    func stream(_ path: String, headers: [(String, String)]) -> AsyncThrowingStream<Data, Error>
    /// How the context signs in: what a proxy's 500 means.
    var signIn: KubeSignIn { get }
    /// Whether the context may be written to now (its writable flag, or
    /// production's switch for the session). False, `write` sends nothing.
    var writable: Bool { get }
    /// One write: DELETE, PATCH, a POST to a subresource or an access review.
    func write(_ method: HTTPMethod, _ path: String, body: Data?, headers: [(String, String)]) async throws -> HTTPResponse
}

extension KubeConnection {
    var writable: Bool { false }

    func write(_ method: HTTPMethod, _ path: String, body: Data?, headers: [(String, String)]) async throws -> HTTPResponse {
        throw KubeWriteRefused(reason: "This connection reads only.")
    }
}

/// A socket (or any transport) spoken to directly.
struct KubeSocketConnection: KubeConnection {
    let transport: any HTTPTransport
    let signIn: KubeSignIn
    /// The context's writability, as the caller knows it (a test's, the
    /// scenario's stand-in): false, nothing but GETs leaves.
    let writable: Bool

    init(transport: any HTTPTransport, signIn: KubeSignIn = .none, writable: Bool = false) {
        self.transport = transport
        self.signIn = signIn
        self.writable = writable
    }

    /// A proxy's socket: `Host: localhost`, or it answers 403.
    init(socket: String, context: String, signIn: KubeSignIn = .none, writable: Bool = false) {
        self.init(transport: UnixHTTPTransport.kubernetes(socket: socket, context: context), signIn: signIn, writable: writable)
    }

    func get(_ path: String, headers: [(String, String)]) async throws -> HTTPResponse {
        try await transport.send(.GET, path, body: nil, headers: headers)
    }

    func stream(_ path: String, headers: [(String, String)]) -> AsyncThrowingStream<Data, Error> {
        transport.stream(.GET, path, body: nil, headers: headers)
    }

    func write(_ method: HTTPMethod, _ path: String, body: Data?, headers: [(String, String)]) async throws -> HTTPResponse {
        guard writable, method != .GET else { throw KubeWriteRefused(reason: "This context is read-only: Overterm changes nothing here.") }
        return try await transport.send(method, path, body: body, headers: headers)
    }
}

/// A context's requests through its `kubectl proxy`, started on first use.
struct KubeProxyConnection: KubeConnection {
    let proxies: KubeProxies
    let context: KubeContext
    var role: KubeProxies.Role = .page

    var signIn: KubeSignIn { KubeSignIn(context.auth) }
    var writable: Bool { context.isWritable }

    func get(_ path: String, headers: [(String, String)]) async throws -> HTTPResponse {
        try await proxies.send(context, role: role, .GET, path, headers: headers)
    }

    func stream(_ path: String, headers: [(String, String)]) -> AsyncThrowingStream<Data, Error> {
        proxies.stream(context, role: role, .GET, path, headers: headers)
    }

    /// Refused here unless this copy of the context is writable, and again
    /// by the proxies unless they know it so (`KubeProxies.sendWrite`).
    func write(_ method: HTTPMethod, _ path: String, body: Data?, headers: [(String, String)]) async throws -> HTTPResponse {
        guard writable else { throw KubeWriteRefused(reason: KubeWriteCheck.readOnly(context)) }
        return try await proxies.sendWrite(context, role: role, method, path, body: body, headers: headers)
    }
}

/// Where a list looks: one namespace, or all of them. A cluster-scoped
/// kind ignores it.
enum KubeScope: Hashable, Sendable {
    case all
    case namespace(String)

    /// The namespace in `kind`'s paths and its rows'.
    func namespace(for kind: KubeResourceKind) -> String? {
        guard kind.namespaced, case .namespace(let name) = self else { return nil }
        return name
    }
}

/// Selectors sent to the server (the filter's, later).
struct KubeListOptions: Hashable, Sendable {
    var labelSelector: String?
    var fieldSelector: String?

    init(labelSelector: String? = nil, fieldSelector: String? = nil) {
        self.labelSelector = labelSelector
        self.fieldSelector = fieldSelector
    }
}

/// `/version`'s answer.
struct KubeServerVersion: Equatable, Sendable, Decodable {
    var major: String
    var minor: String
    var gitVersion: String

    /// `"30+"` (EKS) is 30.
    var minorNumber: Int? { Int(minor.prefix { $0.isNumber }) }
}

/// One object, fetched whole when its detail opens: its JSON as the server
/// sent it, and what identifies it.
struct KubeObject: Sendable {
    let data: Data
    let kind: String
    let apiVersion: String
    let name: String
    let namespace: String?
    let uid: String?
    let resourceVersion: String?
    let creationTimestamp: String?

    init(data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let metadata = object["metadata"] as? [String: Any], let name = metadata["name"] as? String
        else { throw KubeTableReader.Malformed(detail: String(decoding: data.prefix(120), as: UTF8.self)) }
        self.data = data
        kind = object["kind"] as? String ?? ""
        apiVersion = object["apiVersion"] as? String ?? ""
        self.name = name
        namespace = metadata["namespace"] as? String
        uid = metadata["uid"] as? String
        resourceVersion = metadata["resourceVersion"] as? String
        creationTimestamp = metadata["creationTimestamp"] as? String
    }

    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }
}

/// What Overterm asks a cluster, over a `KubeConnection`: the server's
/// version, discovery, lists as Table rows, watches, one object. Reads
/// only — every request is a GET.
///
/// - **Lists are rows only** (`as=Table`, `includeObject=None`), paged
///   with `limit` and `continue`; an expired `continue` (410) lists again
///   from the start. Across all namespaces a namespaced kind's rows carry
///   their metadata too (`includeObject=Metadata`): the server's Tables
///   have no Namespace column — `kubectl get -A` adds it from the
///   metadata — so without it a row's namespace is unknown, and two pods
///   called `postgres-0` in two namespaces would be one row.
/// - **Following a list** is the informer's loop: list, then watch from
///   the list's resourceVersion with bookmarks; a watch the server ends
///   (its timeout, 30–60 minutes) is watched again from the last
///   resourceVersion without listing; a 410, in the stream or as the
///   watch's answer, lists again. A streaming list (`sendInitialEvents`)
///   replaces the first list where it's asked for and the server takes it;
///   it is the list once the bookmark marked `k8s.io/initial-events-end`
///   comes, and one cut before that is listed instead. A list without a
///   resourceVersion (metrics.k8s.io's) can't be watched from: it is
///   listed again every `unversionedPoll`.
/// - **Errors**: a proxy's own failure (a 500 in plain text) is a
///   `KubeProxyProblem`, the server's a `KubeAPIError`; a 429 is retried
///   after its `Retry-After`. A follow gets past a 429 or the server's
///   5xx — on its list, its watch's answer or in the stream — saying
///   `.retrying`, and tries again: after the `Retry-After`, or backing off.
struct KubeClient: Sendable {
    let connection: any KubeConnection
    /// Rows a page.
    var pageSize = 500
    /// A streaming list in place of the first list (1.32, 1.34+; behind
    /// the version, decided by the caller). Refused, the follow falls back.
    var streamingLists = false
    /// The watch's `timeoutSeconds`, client-go's way: 5 to 10 minutes, at
    /// random, so a cluster's watches don't all end at once.
    var watchTimeout: @Sendable () -> Int = { Int.random(in: 300...600) }
    /// 429s retried, each after its `Retry-After` (10 s at most).
    var throttleRetries = 3
    /// A watch that ends at once, again and again (a proxy closing it),
    /// waits longer each time before the next, up to this.
    var maxBackoff: Duration = .seconds(5)
    /// How often a list without a resourceVersion is listed again.
    var unversionedPoll: Duration = .seconds(30)

    init(_ connection: any KubeConnection) {
        self.connection = connection
    }

    static let tableAccept = "application/json;as=Table;v=v1;g=meta.k8s.io, application/json"
    static let discoveryAccept =
        "application/json;g=apidiscovery.k8s.io;v=v2;as=APIGroupDiscoveryList, application/json;g=apidiscovery.k8s.io;v=v2beta1;as=APIGroupDiscoveryList, application/json"

    /// Whether a server of this minor serves streaming lists by default:
    /// beta and on in 1.32, off in 1.33, on again from 1.34.
    static func servesStreamingLists(minor: Int) -> Bool { minor == 32 || minor >= 34 }

    // MARK: Requests

    /// One GET, its error said as what it is.
    func get(_ path: String, accept: String = "application/json") async throws -> HTTPResponse {
        var tries = 0
        while true {
            let response: HTTPResponse
            do {
                response = try await connection.get(path, headers: [("Accept", accept)])
            } catch {
                throw Self.mapped(error, signIn: connection.signIn)
            }
            if (200..<300).contains(response.status) { return response }
            if let problem = KubeProxyProblem.classify(
                status: response.status, contentType: response.header("Content-Type"), text: String(decoding: response.body.prefix(4096), as: UTF8.self),
                stderr: "", signIn: connection.signIn)
            {
                throw problem
            }
            let error = KubeAPIError.from(response)
            if error.status == 429, tries < throttleRetries {
                tries += 1
                try await Task.sleep(for: .seconds(min(max(error.retryAfter ?? 1, 0), 10)))
                continue
            }
            throw error
        }
    }

    /// A stream's failure said as `get` says a response's: from the answer
    /// whole when the transport kept it (its `Content-Type`, its Status,
    /// a 429's `Retry-After`).
    static func mapped(_ error: Error, signIn: KubeSignIn) -> Error {
        guard let http = error as? HTTPError, http.status != 0 else { return error }
        if let problem = KubeProxyProblem.classify(http, stderr: "", signIn: signIn) { return problem }
        if let response = http.response { return KubeAPIError.from(response) }
        return KubeAPIError(status: http.status, reason: nil, message: http.message)
    }

    /// What a list's or a watch's rows carry besides their cells: nothing
    /// in one namespace (or for a cluster-scoped kind), the metadata across
    /// all of them — where the namespace is only there.
    static func includeObject(_ kind: KubeResourceKind, _ scope: KubeScope) -> String {
        kind.namespaced && scope.namespace(for: kind) == nil ? "Metadata" : "None"
    }

    func version() async throws -> KubeServerVersion {
        let response = try await get("/version")
        do {
            return try JSONDecoder().decode(KubeServerVersion.self, from: response.body)
        } catch {
            throw KubeTableReader.Malformed(detail: String(decoding: response.body.prefix(120), as: UTF8.self))
        }
    }

    // MARK: Discovery

    /// Every kind the cluster serves. Aggregated discovery when the server
    /// has it (always since 1.33): two requests. Else the legacy walk: the
    /// core version's list, then every group's preferred version's, eight
    /// at a time. A group that is down is noted, not thrown: one the
    /// aggregated list marks `Stale`, one whose legacy list fails.
    func discover() async throws -> KubeDiscovery {
        async let coreAnswer = get("/api", accept: Self.discoveryAccept)
        async let groupsAnswer = get("/apis", accept: Self.discoveryAccept)
        let core = try await KubeDiscovery.answer(coreAnswer.body)
        let groups = try await KubeDiscovery.answer(groupsAnswer.body)
        var discovery = KubeDiscovery(kinds: [], aggregated: true)
        switch core {
        case .aggregated(let kinds, let stale):
            discovery.kinds += kinds
            discovery.failedGroups.merge(stale) { $1 }
        case .coreVersions(let versions):
            discovery.aggregated = false
            let version = versions.contains("v1") ? "v1" : versions.first ?? "v1"
            discovery.kinds += try KubeDiscovery.resourceList(try await get("/api/\(version)").body)
        case .groups: throw KubeTableReader.Malformed(detail: "/api answered a group list")
        }
        switch groups {
        case .aggregated(let kinds, let stale):
            discovery.kinds += kinds
            discovery.failedGroups.merge(stale) { $1 }
        case .groups(let groupVersions):
            discovery.aggregated = false
            let results = await groupLists(groupVersions)
            for (groupVersion, result) in zip(groupVersions, results) {
                switch result {
                case .success(let kinds): discovery.kinds += kinds
                case .failure(let error): discovery.failedGroups[groupVersion] = error.localizedDescription
                }
            }
        case .coreVersions: throw KubeTableReader.Malformed(detail: "/apis answered core versions")
        }
        return discovery
    }

    /// Each group version's resource list, in the order asked.
    private func groupLists(_ groupVersions: [String]) async -> [Result<[KubeResourceKind], Error>] {
        var results: [Result<[KubeResourceKind], Error>] = []
        for start in stride(from: 0, to: groupVersions.count, by: 8) {
            let batch = Array(groupVersions[start..<min(start + 8, groupVersions.count)])
            let answers = await withTaskGroup(of: (Int, Result<[KubeResourceKind], Error>).self) { group in
                for (index, groupVersion) in batch.enumerated() {
                    group.addTask {
                        do {
                            return (index, .success(try KubeDiscovery.resourceList(try await get("/apis/\(groupVersion)").body)))
                        } catch {
                            return (index, .failure(error))
                        }
                    }
                }
                var answers: [(Int, Result<[KubeResourceKind], Error>)] = []
                for await answer in group { answers.append(answer) }
                return answers.sorted { $0.0 < $1.0 }.map(\.1)
            }
            results += answers
        }
        return results
    }

    // MARK: Lists

    /// The whole list as Table rows, page by page. The collection's
    /// resourceVersion is the first page's (the same on every page).
    func list(_ kind: KubeResourceKind, in scope: KubeScope = .all, options: KubeListOptions = KubeListOptions()) async throws -> KubeTable {
        let namespace = scope.namespace(for: kind)
        var restarts = 0
        restart: while true {
            var whole: KubeTable?
            var token: String?
            repeat {
                let path = KubePath.query(
                    kind.path(namespace: namespace),
                    [
                        ("limit", String(pageSize)), ("continue", token), ("labelSelector", options.labelSelector), ("fieldSelector", options.fieldSelector),
                        ("includeObject", Self.includeObject(kind, scope)),
                    ])
                let page: KubeTable
                do {
                    page = try KubeTableReader.read(try await get(path, accept: Self.tableAccept).body, namespace: namespace, columns: whole?.columns)
                } catch let error as KubeAPIError where error.isGone && token != nil && restarts < 3 {
                    // The `continue` token expired (about 5 minutes): from the start.
                    restarts += 1
                    continue restart
                }
                if whole == nil {
                    whole = page
                } else {
                    whole!.rows += page.rows
                }
                token = page.continueToken
            } while token != nil
            whole!.continueToken = nil
            whole!.remainingItemCount = nil
            return whole!
        }
    }

    /// One object, whole, as JSON.
    func object(_ kind: KubeResourceKind, namespace: String?, name: String) async throws -> KubeObject {
        let response = try await get(kind.path(namespace: kind.namespaced ? namespace : nil, name: name))
        return try KubeObject(data: response.body)
    }

    /// A Secret, for Show alone (rule 9): its one GET, which carries every
    /// value, taken apart at once (`KubeSecret.read`) — the answer itself
    /// is not kept, and an answer that isn't a Secret is said without
    /// what it said.
    func secret(_ kind: KubeResourceKind, namespace: String?, name: String) async throws -> KubeSecretRead {
        let response = try await get(kind.path(namespace: kind.namespaced ? namespace : nil, name: name))
        return try KubeSecret.read(response.body)
    }

    /// An object's events, newest first: the core Events kubectl describe
    /// lists, picked by the server (`fieldSelector` on `involvedObject`) —
    /// in its namespace, or across them for a cluster-scoped object (a
    /// node's are recorded in `default`).
    func events(kind: String, name: String, namespace: String?, uid: String?) async throws -> [KubeEvent] {
        let base = namespace.map { "/api/v1/namespaces/\(KubePath.segment($0))/events" } ?? "/api/v1/events"
        let selector = KubeEvent.fieldSelector(kind: kind, name: name, namespace: namespace, uid: uid)
        return try KubeEvent.list(try await get(KubePath.query(base, [("fieldSelector", selector)])).body)
    }

    // MARK: Logs

    /// A pod's log, once (`follow` off): its lines, parsed here, off the
    /// main actor.
    func logLines(namespace: String, pod: String, query: KubeLogQuery) async throws -> [LogLine] {
        var query = query
        query.follow = false
        let response = try await get(query.path(namespace: namespace, pod: pod), accept: "text/plain, */*")
        return KubeLogText.lines(response.body)
    }

    /// A container's last lines for an agent, bounded in bytes twice: the
    /// server stops at `query.limitBytes`, and of what came only the last
    /// `keep` bytes are taken apart (and scrubbed after) — a line cut at
    /// either end left out to its whitespace (`KubeLogText.tail`).
    /// `stopped`: the server stopped at the limit, so newer lines may be
    /// past it.
    func logTail(namespace: String, pod: String, query: KubeLogQuery, keep: Int) async throws -> (lines: [LogLine], stopped: Bool) {
        var query = query
        query.follow = false
        let body = try await get(query.path(namespace: namespace, pod: pod), accept: "text/plain, */*").body
        let stopped = query.limitBytes.map { body.count >= $0 } ?? false
        return (KubeLogText.lines(KubeLogText.tail(body, keep: keep, stopped: stopped)), stopped)
    }

    /// A pod's log as it comes (`pods/{p}/log`, a GET like any other):
    /// its lines in batches, parsed on the cooperative pool. Ends when the
    /// server ends it — a follow ends at the kubelet's or the apiserver's
    /// timeout, a dropped connection, the container gone — or throws what
    /// the server said (`KubeAPIError`, a `KubeProxyProblem`). Its consumer
    /// leaving closes the request.
    func logs(namespace: String, pod: String, query: KubeLogQuery) -> AsyncThrowingStream<[LogLine], Error> {
        let source = connection.stream(query.path(namespace: namespace, pod: pod), headers: [("Accept", "text/plain, */*")])
        let signIn = connection.signIn
        return AsyncThrowingStream { continuation in
            let task = Task {
                var splitter = KubeLogText.Splitter()
                do {
                    for try await piece in source {
                        let lines = splitter.feed(piece)
                        if !lines.isEmpty { continuation.yield(lines) }
                    }
                    let rest = splitter.finish()
                    if !rest.isEmpty { continuation.yield(rest) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapped(error, signIn: signIn))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Watches

    private func watchPath(_ kind: KubeResourceKind, _ scope: KubeScope, _ options: KubeListOptions, from version: String?) -> String {
        var items: [(String, String?)] = [
            ("watch", "1"), ("allowWatchBookmarks", "true"), ("labelSelector", options.labelSelector), ("fieldSelector", options.fieldSelector),
            ("includeObject", Self.includeObject(kind, scope)), ("timeoutSeconds", String(watchTimeout())),
        ]
        if let version {
            items.insert(("resourceVersion", version), at: 1)
        } else {
            items += [("sendInitialEvents", "true"), ("resourceVersionMatch", "NotOlderThan")]
        }
        return KubePath.query(kind.path(namespace: scope.namespace(for: kind)), items)
    }

    /// One watch from `version`, its events decoded with `columns` (the
    /// list's) until the server ends it — or, with no version, a streaming
    /// list's: every object ADDED, then a bookmark, then the changes.
    func watch(
        _ kind: KubeResourceKind, in scope: KubeScope = .all, options: KubeListOptions = KubeListOptions(), from version: String?,
        columns: [KubeColumn]
    ) -> AsyncThrowingStream<KubeWatchEvent, Error> {
        let source = connection.stream(watchPath(kind, scope, options, from: version), headers: [("Accept", Self.tableAccept)])
        let signIn = connection.signIn
        let namespace = scope.namespace(for: kind)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var decoder = KubeWatchDecoder(columns: columns, namespace: namespace)
                do {
                    for try await piece in source {
                        for event in try decoder.feed(piece) { continuation.yield(event) }
                    }
                    for event in try decoder.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapped(error, signIn: signIn))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A list kept current: `.listed` first (and again after a 410), then
    /// the rows that change and how far the watch has got. Ends when the
    /// consumer stops, or throws what can't be got past (a credential
    /// failure, a 403, an unreachable cluster).
    func follow(_ kind: KubeResourceKind, in scope: KubeScope = .all, options: KubeListOptions = KubeListOptions()) -> AsyncThrowingStream<
        KubeFollowUpdate, Error
    > {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runFollow(kind, scope, options) { continuation.yield($0) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Why a watch ended.
    private enum Ending {
        /// The server ended it (its timeout): watch again from where it got.
        case ended
        /// 410: list again.
        case gone
        /// A streaming list the server refused: list and watch instead.
        case refused
        /// A 429 or the server's 5xx: the same again, after a wait.
        case busy(KubeAPIError)
    }

    /// How long to wait after a 429 (its `Retry-After`, 10 s at most) or
    /// the `attempt`th 5xx in a row (backing off to `maxBackoff`).
    private func wait(after error: KubeAPIError, attempt: Int) -> Duration {
        if error.status == 429 { return .seconds(min(max(error.retryAfter ?? 1, 0), 10)) }
        return min(Duration.milliseconds(100) * (1 << min(attempt, 10)), maxBackoff)
    }

    private func runFollow(
        _ kind: KubeResourceKind, _ scope: KubeScope, _ options: KubeListOptions, _ yield: @Sendable (KubeFollowUpdate) -> Void
    ) async throws {
        var streaming = streamingLists
        /// Where to watch from, with the headers; nil: list first.
        var start: (version: String, columns: [KubeColumn])?
        var quickEnds = 0
        var busyTries = 0
        while true {
            try Task.checkCancellation()
            if start == nil && !streaming {
                let table: KubeTable
                do {
                    table = try await list(kind, in: scope, options: options)
                } catch let error as KubeAPIError where error.isTransient {
                    yield(.retrying(error))
                    busyTries += 1
                    try await Task.sleep(for: wait(after: error, attempt: busyTries))
                    continue
                }
                busyTries = 0
                yield(.listed(table))
                guard let version = table.resourceVersion, !version.isEmpty else {
                    // Nothing to watch from: a watch from "" would be the
                    // objects there now, deletions before it never seen.
                    try await Task.sleep(for: unversionedPoll)
                    continue
                }
                start = (version, table.columns)
            }
            let began = ContinuousClock.now
            var progressed = false
            var columns = start?.columns ?? []
            var version = start?.version ?? ""
            // A streaming list's rows until its end's bookmark.
            var initial: [KubeRow]? = start == nil ? [] : nil
            let ending: Ending
            do {
                ending = try await watchUntilEnd(kind, scope, options, from: start?.version, columns: columns) { event, headers in
                    columns = headers
                    switch event {
                    case .error(let error):
                        throw error
                    case .bookmark(let at, let initialEventsEnd):
                        if !at.isEmpty { version = at }
                        if let rows = initial {
                            // Only the bookmark marked as the end ends the
                            // initial events: what they sent is the list.
                            // Another before it only moves the version on.
                            if initialEventsEnd {
                                yield(.listed(KubeTable(columns: headers, rows: rows, resourceVersion: version)))
                                initial = nil
                                progressed = true
                            }
                        } else {
                            yield(.bookmark(version))
                        }
                    case .added(let row, let at):
                        if let at { version = at }
                        progressed = true
                        if initial != nil { initial!.append(row) } else { yield(.changed([.added(row)], resourceVersion: at)) }
                    case .modified(let row, let at):
                        if let at { version = at }
                        progressed = true
                        if initial != nil {
                            initial!.removeAll { $0.id == row.id }
                            initial!.append(row)
                        } else {
                            yield(.changed([.modified(row)], resourceVersion: at))
                        }
                    case .deleted(let row, let at):
                        if let at { version = at }
                        progressed = true
                        if initial != nil { initial!.removeAll { $0.id == row.id } } else { yield(.changed([.deleted(row.id)], resourceVersion: at)) }
                    }
                }
            } catch let error as KubeAPIError where error.isGone {
                ending = .gone
            } catch let error as KubeAPIError where start == nil && [400, 422].contains(error.status) {
                ending = .refused
            } catch let error as KubeAPIError where error.isTransient {
                ending = .busy(error)
            }
            switch ending {
            case .refused:
                streaming = false
                start = nil
                continue
            case .gone:
                start = nil
            case .busy(let error):
                // From where it got; a streaming list not yet whole starts over.
                if initial == nil && start != nil { start = (version, columns) }
                yield(.retrying(error))
                busyTries += 1
                try await Task.sleep(for: wait(after: error, attempt: busyTries))
                continue
            case .ended:
                if initial != nil {
                    // A streaming list cut before its end: list and watch
                    // instead (also what a server whose Table bookmarks
                    // lost the end's annotation comes to).
                    streaming = false
                    start = nil
                } else {
                    start = (version, columns)
                }
            }
            busyTries = 0
            if progressed || ContinuousClock.now - began > .seconds(2) {
                quickEnds = 0
            } else {
                quickEnds += 1
                let wait = min(Duration.milliseconds(100) * (1 << min(quickEnds, 10)), maxBackoff)
                try await Task.sleep(for: wait)
            }
        }
    }

    /// One watch, each event handed to `handle` with the headers as they
    /// stand; how it ended. A 410 at the start is thrown, as one in the
    /// stream is by `handle`.
    private func watchUntilEnd(
        _ kind: KubeResourceKind, _ scope: KubeScope, _ options: KubeListOptions, from version: String?, columns: [KubeColumn],
        _ handle: (KubeWatchEvent, [KubeColumn]) throws -> Void
    ) async throws -> Ending {
        let source = connection.stream(watchPath(kind, scope, options, from: version), headers: [("Accept", Self.tableAccept)])
        var decoder = KubeWatchDecoder(columns: columns, namespace: scope.namespace(for: kind))
        do {
            for try await piece in source {
                for event in try decoder.feed(piece) { try handle(event, decoder.columns) }
            }
            for event in try decoder.finish() { try handle(event, decoder.columns) }
        } catch let error as HTTPError {
            throw Self.mapped(error, signIn: connection.signIn)
        }
        try Task.checkCancellation()
        return .ended
    }
}
