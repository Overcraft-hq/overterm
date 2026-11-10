import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// A Kubernetes API server played on a unix socket of its own (and on
/// 127.0.0.1, for a real `kubectl proxy` in front of it), for the tests
/// and the `kubernetes` scenario: never one of the user's clusters — this
/// Mac's current context is production.
///
/// It holds objects of any kind it serves as values — namespaces and pods,
/// and deployments, services, configmaps, secrets, nodes, events, CRDs and
/// their custom resources, each with the columns `kubectl get` shows —
/// versioned as the server versions them; a change sends the watch events
/// the server would. A CRD added (`addCRD`) is a kind it serves from then
/// on, in discovery and in paths, until it is removed (one version a group:
/// a group's kinds are served at its first kind's). It answers:
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
///   as a server with the gate off refuses it (`streamingLists`), its
///   end unmarked on a Table where `streamingTables` is off;
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
        /// Its init containers' names (each terminated, Completed) and
        /// ephemeral ones' (running).
        var initContainers: [String] = []
        var ephemeralContainers: [String] = []
        /// The first container ended (`Completed`, `Error`): its state
        /// `terminated` with `exitCode`.
        var terminatedReason: String?
        var exitCode = 0
        /// The first container's env, as plain values.
        var env: [String: String] = [:]
        /// The first container's env taken from Secrets: name → the Secret and its key.
        var secretEnv: [String: SecretKeyRef] = [:]
        /// The first container's declared ports (TCP).
        var ports: [ContainerPort] = []
        /// Its `Ready` condition, when one is reported (nil: none, readiness
        /// read off its containers): a readiness probe failing turns it False.
        var readyCondition: Bool?
        /// Each container's resources by name (`requests`/`limits` → `cpu`/`memory` → a quantity), as its spec says
        /// them; the `resize` subresource changes them.
        var resources: [String: [String: [String: String]]] = [:]
        /// With restarts, how the first container last ended (`lastState.terminated`): its reason, exit code and when.
        var lastReason = "Error"
        var lastExitCode = 1
        var lastFinished: Date?

        /// Its containers' names: `app`, then `sidecar-1`…
        var containerNames: [String] { (0..<containers).map { $0 == 0 ? "app" : "sidecar-\($0)" } }
    }

    /// An env value a container takes from a Secret's key (`valueFrom.secretKeyRef`).
    struct SecretKeyRef: Equatable, Sendable {
        var name: String
        var key: String
    }

    /// A port a container declares: `containerPort`, and its name.
    struct ContainerPort: Equatable, Sendable {
        var name: String?
        var port: Int

        init(_ port: Int, name: String? = nil) {
            self.port = port
            self.name = name
        }
    }

    /// One line of a container's log, as the kubelet keeps it.
    struct LogEntry: Sendable {
        var time: Date
        var text: String

        /// RFC 3339 with nine digits of fraction, as the kubelet writes it.
        var stamp: String { FakeKubeAPI.nanoStamp(time) }
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
        /// Cells by column name, for a kind other than pods: what the
        /// Table shows besides Name and the ages.
        var values: [String: Value] = [:]
        var annotations: [String: String] = [:]
        /// A Secret's or a ConfigMap's keys and values (a Secret's are
        /// base64 in the object, as the server sends them). Only a plain GET
        /// of the object carries them; its Table row says how many.
        var data: [String: String] = [:]
        /// The rest of the object as a plain GET answers it — `spec`,
        /// `status`, an Event's `involvedObject` — as JSON; its `metadata`
        /// is merged into the metadata (`ownerReferences`, `generation`).
        var body: Data? = nil
        /// `metadata.managedFields` as JSON (`setManagedFields`, a server-side
        /// apply's); nil: one kubectl-client-side-apply entry, as before.
        var managedFields: Data? = nil
    }

    /// A self-signed certificate for a fake TLS Secret's `tls.crt`: public
    /// only — its key was thrown away when it was made, and none is in the
    /// repository. `C=US, O=Acme Fake, CN=web.acme.example`, for
    /// `web.acme.example`, `*.shop.acme.example`, 10.0.0.12 and
    /// ops@acme.example, good from 2026-11-04 03:59:47 to 2036-11-01
    /// 03:59:47 UTC, a CA (P-256).
    static let testCertificatePEM = """
        -----BEGIN CERTIFICATE-----
        MIICGTCCAb+gAwIBAgIUJhdJjT3JRkmt3Ptvm5KGC5ktqgYwCgYIKoZIzj0EAwIw
        PDELMAkGA1UEBhMCVVMxEjAQBgNVBAoMCUFjbWUgRmFrZTEZMBcGA1UEAwwQd2Vi
        LmFjbWUuZXhhbXBsZTAeFw0yNjExMDQwMzU5NDdaFw0zNjExMDEwMzU5NDdaMDwx
        CzAJBgNVBAYTAlVTMRIwEAYDVQQKDAlBY21lIEZha2UxGTAXBgNVBAMMEHdlYi5h
        Y21lLmV4YW1wbGUwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAS+sg4g9TeelMKQ
        5TsV7bm+CGcViCc8Zp4iHTnaaExp3A8XFUpRRiYjOTxunT1ROQihet1wPSTn4KaC
        VmNiJh04o4GeMIGbMB0GA1UdDgQWBBQIO2LTdUNYOLEhEeFhXYcw6j6pFzAfBgNV
        HSMEGDAWgBQIO2LTdUNYOLEhEeFhXYcw6j6pFzAPBgNVHRMBAf8EBTADAQH/MEgG
        A1UdEQRBMD+CEHdlYi5hY21lLmV4YW1wbGWCEyouc2hvcC5hY21lLmV4YW1wbGWH
        BAoAAAyBEG9wc0BhY21lLmV4YW1wbGUwCgYIKoZIzj0EAwIDSAAwRQIgTdkQUGPx
        IKDVcSsBMMBmV2BZA2VsweDm6YyBBnk14R8CIQCeYx7kKaXmavjhGtUWcP0uaS20
        rxE1/4N2qamc5VVWgg==
        -----END CERTIFICATE-----

        """

    /// One cell's value as the server types it.
    enum Value: Equatable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
        case text(String)
        case integer(Int)

        init(stringLiteral value: String) { self = .text(value) }
        init(integerLiteral value: Int) { self = .integer(value) }

        var json: Any {
            switch self {
            case .text(let text): text
            case .integer(let value): value
            }
        }
    }

    /// One of a kind's Table columns: `kubectl get`'s, or a CRD's
    /// `additionalPrinterColumns`.
    struct Column: Equatable, Sendable {
        var name: String
        var type = "string"
        var format = ""
        var priority = 0
        var description = ""
    }

    struct Request: Equatable, Sendable, CustomStringConvertible {
        var method: String
        var path: String
        var query: [String: String]
        var accept: String
        /// A write's body, and how it says it is encoded.
        var body = Data()
        var contentType = ""

        var description: String { "\(method) \(path)" }

        /// The body read back, for the tests.
        var json: Any? { try? JSONSerialization.jsonObject(with: body) }
        /// An access review (SelfSubjectAccessReview): a POST, but no write.
        var isAccessReview: Bool { path == FakeKubeAPI.accessReviewPath }
        /// A subresource: `pods/p/exec`, `services/s:80/proxy`, `pods/p/log`.
        var isSubresource: Bool { FakeKubeAPI.route(path)?.subresource != nil }
        /// A pod's log: the one subresource Overterm reads (a GET).
        var isLog: Bool { FakeKubeAPI.route(path).map { $0.resource == "pods" && $0.subresource == "log" } ?? false }
        /// A watch's request.
        var isWatch: Bool { query["watch"] == "1" || query["watch"] == "true" }
        /// A Prometheus query through a Service's proxy (`…/proxy/api/v1/query`, `query_range`).
        var isPrometheusQuery: Bool { path.contains("/proxy/api/v1/query") }
        /// Discovery: `/api`, `/apis`, a group's or a version's list of kinds, `/version`, OpenAPI.
        var isDiscovery: Bool {
            let parts = path.split(separator: "/")
            if parts.first == "api" { return parts.count <= 2 }
            if parts.first == "apis" { return parts.count <= 3 }
            return parts.first == "version" || parts.first == "openapi"
        }
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
        /// A CRD's printer columns; nil: the built-in kind's own.
        var columns: [Column]? = nil
        /// A CRD's kind: it takes no strategic merge patch, as the server's don't.
        var custom = false

        var groupVersion: String { group.isEmpty ? version : "\(group)/\(version)" }
        var fullName: String { group.isEmpty ? resource : "\(resource).\(group)" }
    }

    /// The kinds every fake serves; `addCRD` adds more to one.
    static let builtinKinds: [Kind] = [
        Kind(group: "", version: "v1", resource: "namespaces", kind: "Namespace", namespaced: false, shortNames: ["ns"], subresources: ["finalize", "status"]),
        Kind(
            group: "", version: "v1", resource: "pods", kind: "Pod", namespaced: true, shortNames: ["po"], categories: ["all"],
            subresources: ["attach", "binding", "ephemeralcontainers", "eviction", "exec", "log", "portforward", "proxy", "resize", "status"]),
        Kind(group: "", version: "v1", resource: "services", kind: "Service", namespaced: true, shortNames: ["svc"], categories: ["all"], subresources: ["proxy", "status"]),
        Kind(group: "", version: "v1", resource: "configmaps", kind: "ConfigMap", namespaced: true, shortNames: ["cm"]),
        Kind(group: "", version: "v1", resource: "secrets", kind: "Secret", namespaced: true),
        Kind(group: "", version: "v1", resource: "events", kind: "Event", namespaced: true, shortNames: ["ev"]),
        Kind(group: "", version: "v1", resource: "nodes", kind: "Node", namespaced: false, shortNames: ["no"], subresources: ["proxy", "status"]),
        Kind(group: "", version: "v1", resource: "serviceaccounts", kind: "ServiceAccount", namespaced: true, shortNames: ["sa"], subresources: ["token"]),
        Kind(group: "", version: "v1", resource: "resourcequotas", kind: "ResourceQuota", namespaced: true, shortNames: ["quota"], subresources: ["status"]),
        Kind(
            group: "", version: "v1", resource: "persistentvolumeclaims", kind: "PersistentVolumeClaim", namespaced: true, shortNames: ["pvc"],
            subresources: ["status"]),
        Kind(group: "", version: "v1", resource: "componentstatuses", kind: "ComponentStatus", namespaced: false, shortNames: ["cs"], verbs: ["get", "list"]),
        Kind(group: "", version: "v1", resource: "bindings", kind: "Binding", namespaced: true, verbs: ["create"]),
        Kind(group: "apps", version: "v1", resource: "deployments", kind: "Deployment", namespaced: true, shortNames: ["deploy"], categories: ["all"], subresources: ["scale", "status"]),
        Kind(group: "apps", version: "v1", resource: "replicasets", kind: "ReplicaSet", namespaced: true, shortNames: ["rs"], categories: ["all"], subresources: ["scale", "status"]),
        Kind(group: "apps", version: "v1", resource: "statefulsets", kind: "StatefulSet", namespaced: true, shortNames: ["sts"], categories: ["all"], subresources: ["scale", "status"]),
        Kind(group: "apps", version: "v1", resource: "daemonsets", kind: "DaemonSet", namespaced: true, shortNames: ["ds"], categories: ["all"], subresources: ["status"]),
        Kind(group: "apps", version: "v1", resource: "controllerrevisions", kind: "ControllerRevision", namespaced: true),
        Kind(group: "batch", version: "v1", resource: "jobs", kind: "Job", namespaced: true, categories: ["all"], subresources: ["status"]),
        Kind(group: "batch", version: "v1", resource: "cronjobs", kind: "CronJob", namespaced: true, shortNames: ["cj"], categories: ["all"], subresources: ["status"]),
        Kind(group: "events.k8s.io", version: "v1", resource: "events", kind: "Event", namespaced: true, shortNames: ["ev"]),
        Kind(
            group: "apiextensions.k8s.io", version: "v1", resource: "customresourcedefinitions", kind: "CustomResourceDefinition", namespaced: false,
            shortNames: ["crd", "crds"], categories: ["api-extensions"], subresources: ["status"]),
        Kind(group: "rbac.authorization.k8s.io", version: "v1", resource: "roles", kind: "Role", namespaced: true),
        Kind(group: "discovery.k8s.io", version: "v1", resource: "endpointslices", kind: "EndpointSlice", namespaced: true),
        Kind(group: "networking.k8s.io", version: "v1", resource: "ingresses", kind: "Ingress", namespaced: true, shortNames: ["ing"], subresources: ["status"]),
        Kind(group: "policy", version: "v1", resource: "poddisruptionbudgets", kind: "PodDisruptionBudget", namespaced: true, shortNames: ["pdb"], subresources: ["status"]),
        Kind(
            group: "autoscaling", version: "v2", resource: "horizontalpodautoscalers", kind: "HorizontalPodAutoscaler", namespaced: true, shortNames: ["hpa"],
            categories: ["all"], subresources: ["status"]),
        Kind(group: "metrics.k8s.io", version: "v1beta1", resource: "pods", kind: "PodMetrics", namespaced: true, verbs: ["get", "list"]),
        Kind(group: "metrics.k8s.io", version: "v1beta1", resource: "nodes", kind: "NodeMetrics", namespaced: false, verbs: ["get", "list"]),
    ]

    let socket: String?
    private let lock = NSLock()
    /// What it serves now: the built-in kinds and the CRDs added.
    private var kinds = FakeKubeAPI.builtinKinds
    /// CRDs' `spec` schemas, by full name: what their `/openapi/v3` document says.
    private var crdSchemas: [String: [String: Any]] = [:]
    private var objects: [String: Object] = [:]
    /// The Prometheus behind a Service's proxy, and its series.
    private var prometheus: (namespace: String, service: String, port: String)?
    private var prometheusSeries: [(metric: String, labels: [String: String], value: Double)] = []
    /// What the fake Prometheus answers instead of its queries (`failPrometheus`).
    private var prometheusFailure: (status: Int, text: String)?
    /// The apiserver's own answer for the Service's proxy instead (`refusePrometheusProxy`).
    private var prometheusRefusal: (status: Int, retryAfter: Int?)?
    /// Fixtures matched by a fragment of the query, newest first (`setPrometheusMatrix`).
    private var prometheusFixtures: [FakePromFixture] = []
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
    /// Paths whose answers are held this many milliseconds (`answerSlowly`).
    private var slowPaths: [String: Int] = [:]
    private var heldNow = 0
    private var dropped: [String] = []
    private var throttleAfter = 0
    /// The next watches' answer: a status, its `Retry-After`.
    private var failedWatches: (count: Int, status: Int, retryAfter: Int?) = (0, 0, nil)
    private var settings = Settings()
    /// Containers' logs, by `namespace|pod|container|previous`.
    private var logs: [String: [LogEntry]] = [:]
    /// Follows open now: their pod and container, and whether they asked for timestamps.
    private var logFollowers: [ObjectIdentifier: (channel: Channel, key: String, timestamps: Bool)] = [:]

    /// What a test sets, read on the event loops' threads: behind the lock.
    private struct Settings {
        var minor = "34"
        var aggregatedDiscovery = true
        var streamingLists = true
        var goneAsAnswer = false
        var failingGroups: Set<String> = []
        var interimBookmarks = false
        var streamingTables = true
        var bookmarkColumns = true
        var unversionedLists = false
        var forbidden: Set<String> = []
        var failingResources: Set<String> = []
        var endFollowsAtOnce = false
        var ignoresTables: Set<String> = []
        var deniedAccess: Set<String> = []
        var evictionBlock: String?
        var nextWriteFailure: (status: Int, reason: String, message: String)?
        var servesOpenAPI = true
        var openAPIPadding = 0
    }

    /// Whether it serves `/openapi/v3` (an old server's 404 when not).
    var servesOpenAPI: Bool {
        get { locked { settings.servesOpenAPI } }
        set { locked { settings.servesOpenAPI = newValue } }
    }

    /// Bytes of whitespace before each `/openapi/v3/…` document: an
    /// aggregated server's oversized one, for the read's bound.
    var openAPIPadding: Int {
        get { locked { settings.openAPIPadding } }
        set { locked { settings.openAPIPadding = newValue } }
    }

    /// What the access review refuses, as `KubeAccess` says it: `delete
    /// pods`, `patch deployments.apps/scale`, `create pods/eviction`.
    /// Everything else is allowed.
    var deniedAccess: Set<String> {
        get { locked { settings.deniedAccess } }
        set { locked { settings.deniedAccess = newValue } }
    }

    /// A PodDisruptionBudget that allows no eviction now: every eviction is
    /// a 429 saying so, this its cause.
    var evictionBlock: String? {
        get { locked { settings.evictionBlock } }
        set { locked { settings.evictionBlock = newValue } }
    }

    /// The next write (not an access review) is answered with this Status:
    /// a 403 RBAC changed meanwhile, a 409, a 422.
    func failNextWrite(_ status: Int, reason: String, message: String) {
        locked { settings.nextWriteFailure = (status, reason, message) }
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
    /// Whether a streaming list asked for as a Table ends as one should:
    /// off, its end's bookmark carries no `k8s.io/initial-events-end` — a
    /// server that doesn't combine the two (the spike's open question).
    var streamingTables: Bool {
        get { locked { settings.streamingTables } }
        set { locked { settings.streamingTables = newValue } }
    }
    /// Whether a Table bookmark that is a stream's first Table carries the
    /// columns, as kind's 1.37 does: off, an empty streaming list ends
    /// without them (a server that leaves them out).
    var bookmarkColumns: Bool {
        get { locked { settings.bookmarkColumns } }
        set { locked { settings.bookmarkColumns = newValue } }
    }
    /// Whether metrics-server is there: metrics.k8s.io served (pods and
    /// nodes, `get` and `list`, as metrics-server serves them). Off, a
    /// cluster without one — EKS's by default: neither discovery names it
    /// nor its paths answer but 404.
    var metricsServer: Bool {
        get { locked { kinds.contains { $0.group == "metrics.k8s.io" } } }
        set {
            locked {
                kinds.removeAll { $0.group == "metrics.k8s.io" }
                if newValue { kinds += Self.builtinKinds.filter { $0.group == "metrics.k8s.io" } }
            }
        }
    }

    /// A pod's sample, as metrics-server writes one: each container's cpu
    /// and memory (`"12m"`, `"48Mi"`, `"1234567n"`), stamped `at` — nil,
    /// stamped as it is served, so the stamp advances as metrics-server's
    /// does (metrics.md 8).
    /// `labels`: the pod's, as metrics-server copies them (a revision's hash, the selector's).
    func setPodMetrics(
        _ pod: String, namespace: String, _ containers: [(name: String, cpu: String, memory: String)], at time: Date? = nil, labels: [String: String] = [:]
    ) {
        var fields: [String: Any] = [
            "window": "15s", "containers": containers.map { ["name": $0.name, "usage": ["cpu": $0.cpu, "memory": $0.memory]] },
        ]
        if let time { fields["timestamp"] = Self.time(time) }
        add("pods.metrics.k8s.io", pod, namespace: namespace, labels: labels, fields: fields)
    }

    /// A node's sample, stamped as a pod's is.
    func setNodeMetrics(_ node: String, cpu: String, memory: String, at time: Date? = nil) {
        var fields: [String: Any] = ["window": "15s", "usage": ["cpu": cpu, "memory": memory]]
        if let time { fields["timestamp"] = Self.time(time) }
        add("nodes.metrics.k8s.io", node, fields: fields)
    }

    /// A Prometheus answers at `namespace/service:port`'s proxy — its
    /// `api/v1/query` and `api/v1/query_range`, as the apiserver's service
    /// proxy would reach it; every other proxy path (another Service's,
    /// another path of this one's) is a 403, as the metrics proxy's flags
    /// would answer. The Service itself is the test's to add (`add`).
    func servePrometheus(namespace: String, service: String, port: String) {
        locked { prometheus = (namespace, service, port) }
    }

    /// The fake Prometheus answers its queries with this plain text and
    /// status instead — a process in the cluster, saying what it likes; nil, its queries again.
    func failPrometheus(_ status: Int?, _ text: String = "") {
        locked { prometheusFailure = status.map { ($0, text) } }
    }

    /// The apiserver answers the Service's proxy itself with a Status of
    /// `status` — a 403 (`get services/proxy` refused), a 429 or 503 with
    /// its `Retry-After` — nil, Prometheus answers again.
    func refusePrometheusProxy(_ status: Int?, retryAfter: Int? = nil) {
        locked { prometheusRefusal = status.map { ($0, retryAfter) } }
    }

    /// A series Prometheus holds: its metric's name, labels and value now —
    /// what a query (`FakePromQL`: `sum`/`max` by, `rate` taken as the
    /// value, `== n`, `* on(…) group_left()`, `or`, `and on(…)`,
    /// `label_replace`) adds up. A range answers it rising to the value
    /// over the range.
    func setPrometheusSeries(_ metric: String, labels: [String: String] = [:], value: Double) {
        locked {
            prometheusSeries.removeAll { $0.metric == metric && $0.labels == labels }
            prometheusSeries.append((metric, labels, value))
        }
    }

    /// The series of `metric` whose labels include `labels` removed.
    func clearPrometheusSeries(_ metric: String, matching labels: [String: String] = [:]) {
        locked { prometheusSeries.removeAll { item in item.metric == metric && labels.allSatisfy { item.labels[$0.key] == $0.value } } }
    }

    /// A query containing `fragment` (whitespace aside) is answered by
    /// these lines — each a function of t, nil a gap — rather than
    /// evaluated (metrics.md §8); without lines, `FakePromQL` evaluates it
    /// and the warnings are added; with a failure, that is the answer. The
    /// fixture set last for a fragment wins.
    func setPrometheusMatrix(
        _ fragment: String, _ lines: [FakePromFixture.Line]? = nil, warnings: [String] = [], failure: FakePromFixture.Failure? = nil
    ) {
        locked {
            prometheusFixtures.removeAll { $0.fragment == fragment }
            prometheusFixtures.insert(FakePromFixture(fragment: fragment, lines: lines, warnings: warnings, failure: failure), at: 0)
        }
    }

    /// The fixture set for `fragment` removed.
    func clearPrometheusMatrix(_ fragment: String) {
        locked { prometheusFixtures.removeAll { $0.fragment == fragment } }
    }

    /// Lists answer without a resourceVersion, as metrics.k8s.io's do.
    var unversionedLists: Bool {
        get { locked { settings.unversionedLists } }
        set { locked { settings.unversionedLists = newValue } }
    }
    /// Resources (`namespaces`, `pods`…) the user may not read: every
    /// request for one is a 403, as RBAC refuses it — a context limited to
    /// its namespace can't list the others. `pods@cluster`: refused only across the
    /// cluster; `pods@locked`: only in that namespace.
    var forbidden: Set<String> {
        get { locked { settings.forbidden } }
        set { locked { settings.forbidden = newValue } }
    }

    /// Resources whose every list or GET the server fails: a 500, as an
    /// overloaded server or a broken etcd answers. `pods@payments`: in that namespace only.
    var failingResources: Set<String> {
        get { locked { settings.failingResources } }
        set { locked { settings.failingResources = newValue } }
    }

    /// A followed log is answered with what it has and ended at once, as a
    /// proxy or server that closes every follow as it opens.
    var endFollowsAtOnce: Bool {
        get { locked { settings.endFollowsAtOnce } }
        set { locked { settings.endFollowsAtOnce = newValue } }
    }

    /// Resources whose lists ignore the Accept's Table, as a proxy that
    /// doesn't negotiate one: the whole objects, a Secret's data with them.
    var ignoresTables: Set<String> {
        get { locked { settings.ignoresTables } }
        set { locked { settings.ignoresTables = newValue } }
    }

    /// One open watch.
    private struct Watcher {
        var channel: Channel
        var resource: String
        var namespace: String?
        var table: Bool
        var includeObject: String
        var bookmarks: Bool
        var labels: LabelSelector
        /// Its `fieldSelector`, read against the object as a GET answers it.
        var fields = FieldSelector(nil)
        var kind: Kind? = nil
        var sentColumns = false

        func matches(_ object: Object) -> Bool {
            FakeKubeAPI.matches(object, resource, namespace, labels) && (fields.isEmpty || kind.map { fields.matches(FakeKubeAPI.full(object, $0)) } ?? true)
        }
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
    /// The kinds watched now, by full name, one entry a watch.
    var watched: [String] { locked { watchers.values.map(\.resource).sorted() } }
    func forgetRequests() { locked { asked = [] } }

    // MARK: State, as a test sets it

    var resourceVersion: Int { locked { current } }

    func addNamespace(_ name: String, labels: [String: String] = [:]) {
        change("ADDED") {
            Object(resource: "namespaces", namespace: nil, name: name, uid: UUID().uuidString.lowercased(), resourceVersion: 0, created: Date(), labels: labels)
        }
    }

    func addPod(
        _ name: String, namespace: String, _ pod: Pod = Pod(), labels: [String: String] = [:], annotations: [String: String] = [:], created: Date = Date()
    ) {
        change("ADDED") {
            Object(
                resource: "pods", namespace: namespace, name: name, uid: UUID().uuidString.lowercased(), resourceVersion: 0, created: created, labels: labels,
                pod: pod, annotations: annotations)
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
        // Its logs' follows end, as the kubelet ends them.
        endLogStreams(of: name, namespace: namespace)
    }

    // MARK: Logs, as a test writes them

    private static func logKey(_ namespace: String, _ pod: String, _ container: String, previous: Bool) -> String {
        "\(namespace)|\(pod)|\(container)|\(previous ? "previous" : "current")"
    }

    /// A line in a container's log (the pod's first, unless named) — in
    /// its last terminated instance's, `previous` — written at `at`, and
    /// to every follow of it open now.
    func appendLog(_ pod: String, namespace: String, container: String? = nil, _ text: String, at time: Date = Date(), previous: Bool = false) {
        let followers = locked { () -> [(Channel, Bool)] in
            let name = container ?? objects[Self.key("pods", namespace, pod)]?.pod?.containerNames.first ?? "app"
            let key = Self.logKey(namespace, pod, name, previous: previous)
            logs[key, default: []].append(LogEntry(time: time, text: text))
            return previous ? [] : logFollowers.values.filter { $0.key == key }.map { ($0.channel, $0.timestamps) }
        }
        let entry = LogEntry(time: time, text: text)
        for (channel, timestamps) in followers { Self.write(Data(((timestamps ? entry.stamp + " " : "") + text + "\n").utf8), to: channel) }
    }

    /// Several lines, a second apart and ending now (or `until`).
    func setLog(_ pod: String, namespace: String, container: String? = nil, _ lines: [String], previous: Bool = false, until end: Date = Date()) {
        for (index, line) in lines.enumerated() {
            appendLog(pod, namespace: namespace, container: container, line, at: end.addingTimeInterval(Double(index - lines.count + 1)), previous: previous)
        }
    }

    /// Follows of a log open now.
    var openLogStreams: Int { locked { logFollowers.count } }

    /// Whose they are: `namespace/pod/container`, sorted.
    var openLogFollows: [String] {
        locked { logFollowers.values.map { $0.key.split(separator: "|").prefix(3).joined(separator: "/") }.sorted() }
    }

    /// Every follow dropped mid-stream — its connection closed, no end
    /// chunk: a network blip, the proxy restarting. How many there were.
    @discardableResult
    func dropLogStreams() -> Int {
        let open = locked {
            defer { logFollowers = [:] }
            return logFollowers.values.map(\.channel)
        }
        open.forEach { $0.close(promise: nil) }
        return open.count
    }

    /// A pod's follows ended as the server ends them (its timeout, the pod gone).
    func endLogStreams(of pod: String? = nil, namespace: String? = nil) {
        let ending = locked { () -> [Channel] in
            let prefix = pod.map { "\(namespace ?? "")|\($0)|" }
            let picked = logFollowers.filter { prefix == nil || $0.value.key.hasPrefix(prefix!) }
            for id in picked.keys { logFollowers[id] = nil }
            return picked.values.map(\.channel)
        }
        ending.forEach(Self.end)
    }

    func pod(_ name: String, namespace: String) -> Pod? { locked { objects[Self.key("pods", namespace, name)]?.pod } }

    /// An object of any kind served (`deployments.apps`, `secrets`,
    /// `widgets.example.com`), its cells by column name; a namespaced
    /// kind's in `namespace`. `fields`: the rest of it, as a GET answers
    /// it (`spec`, `status`, `metadata.ownerReferences`…).
    func add(
        _ resource: String, _ name: String, namespace: String? = nil, values: [String: Value] = [:], labels: [String: String] = [:],
        annotations: [String: String] = [:], data: [String: String] = [:], created: Date = Date(), fields: [String: Any] = [:]
    ) {
        let body = fields.isEmpty ? nil : Self.encode(fields)
        change("ADDED") {
            Object(
                resource: resource, namespace: namespace, name: name, uid: UUID().uuidString.lowercased(), resourceVersion: 0, created: created, labels: labels,
                values: values, annotations: annotations, data: data, body: body)
        }
    }

    /// An object's own fields (`spec`, `status`, `metadata.ownerReferences`)
    /// set — a pod's too, over what its `Pod` makes: a MODIFIED event.
    func setFields(_ resource: String, _ name: String, namespace: String? = nil, _ fields: [String: Any]) {
        let key = Self.key(resource, namespace, name)
        let body = Self.encode(fields)
        change("MODIFIED") {
            guard var object = objects[key] else { return nil }
            object.body = body
            return object
        }
    }

    /// An object's fields and cells changed together — one MODIFIED, as a
    /// controller's status write is: `fields` gets the body as it is now
    /// (`spec`, `status`, `metadata`'s own) to change in place.
    func modify(_ resource: String, _ name: String, namespace: String? = nil, values: [String: Value] = [:], _ fields: (inout [String: Any]) -> Void) {
        let key = Self.key(resource, namespace, name)
        change("MODIFIED") {
            guard var object = objects[key] else { return nil }
            var body = object.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            fields(&body)
            object.body = Self.encode(body)
            object.values.merge(values) { $1 }
            return object
        }
    }

    /// An object's managedFields, as a GET answers them: who owns which
    /// fields (`manager`, `operation`, `fieldsV1`) — a server-side apply's
    /// conflicts come from them. A MODIFIED event.
    func setManagedFields(_ resource: String, _ name: String, namespace: String? = nil, _ entries: [[String: Any]]) {
        let key = Self.key(resource, namespace, name)
        let data = Self.encode(entries)
        change("MODIFIED") {
            guard var object = objects[key] else { return nil }
            object.managedFields = data
            return object
        }
    }

    /// The object whole, as a GET answers it now (a test's look).
    func object(_ resource: String, _ name: String, namespace: String? = nil) -> [String: Any]? {
        let (object, kind) = locked { (objects[Self.key(resource, namespace, name)], kinds.first { $0.fullName == resource }) }
        guard let object, let kind else { return nil }
        return Self.full(object, kind)
    }

    /// An object's uid, as its metadata says it.
    func uid(_ resource: String, _ name: String, namespace: String? = nil) -> String? {
        locked { objects[Self.key(resource, namespace, name)]?.uid }
    }

    /// A core Event about an object (`pods`, `deployments.apps`…), as the
    /// kubelet or a controller records one: its `involvedObject` with the
    /// object's Kind and uid, in the object's namespace (a cluster-scoped
    /// one's in `default`), last seen `last`.
    func addEvent(
        about resource: String, _ objectName: String, namespace: String? = nil, type: String = "Normal", reason: String, message: String, count: Int = 1,
        last: Date = Date(), component: String = "kubelet"
    ) {
        let kind = locked { kinds.first { $0.fullName == resource } }
        let uid = uid(resource, objectName, namespace: namespace) ?? ""
        let time = Self.time(last)
        var involved: [String: Any] = ["kind": kind?.kind ?? "", "name": objectName, "uid": uid, "apiVersion": kind?.groupVersion ?? "v1"]
        if let namespace { involved["namespace"] = namespace }
        add(
            "events", "\(objectName).\(UUID().uuidString.prefix(8).lowercased())", namespace: namespace ?? "default",
            values: [
                "Last Seen": .text(Self.age(since: last)), "Type": .text(type), "Reason": .text(reason),
                "Object": .text("\((kind?.kind ?? resource).lowercased())/\(objectName)"), "Message": .text(message),
                "Count": .integer(count),
            ], created: last,
            fields: [
                "involvedObject": involved, "type": type, "reason": reason, "message": message, "count": count, "firstTimestamp": time,
                "lastTimestamp": time, "source": ["component": component],
            ])
    }

    /// An object's cells change: a MODIFIED event.
    func update(_ resource: String, _ name: String, namespace: String? = nil, values: [String: Value]) {
        let key = Self.key(resource, namespace, name)
        change("MODIFIED") {
            guard var object = objects[key] else { return nil }
            object.values.merge(values) { $1 }
            return object
        }
    }

    func delete(_ resource: String, _ name: String, namespace: String? = nil) {
        let key = Self.key(resource, namespace, name)
        change("DELETED") { objects[key] }
    }

    /// A Helm release's record, as Helm 3 and 4 store it: a Secret of type
    /// `helm.sh/release.v1` named `sh.helm.release.v1.<name>.v<revision>`,
    /// labelled `owner=helm`, `name`, `status`, `version` and `modifiedAt`,
    /// its one key `release` the release as JSON, gzipped and base64'd
    /// (`KubeHelm.encode`; the API base64s it again) — or with `configMap`,
    /// the same in a ConfigMap. `config` is the user's values, `values` the
    /// chart's defaults.
    func addHelmRelease(
        _ name: String, namespace: String, revision: Int = 1, status: String = "deployed", chart: String = "web", version: String = "1.0.0",
        appVersion: String = "1.27", description: String = "Install complete", config: [String: Any] = [:], values: [String: Any] = [:],
        manifest: String = "", notes: String = "", configMap: Bool = false, modified: Date = Date()
    ) {
        let stamp = FakeKubeAPI.time(modified)
        let release: [String: Any] = [
            "name": name, "namespace": namespace, "version": revision, "config": config, "manifest": manifest,
            "info": [
                "status": status, "description": description, "notes": notes, "first_deployed": stamp, "last_deployed": stamp,
            ],
            "chart": [
                "metadata": ["name": chart, "version": version, "appVersion": appVersion, "apiVersion": "v2"], "values": values,
                "templates": [["name": "templates/deployment.yaml", "data": Data("kind: Deployment".utf8).base64EncodedString()]],
            ],
        ]
        let labels = [
            "owner": "helm", "name": name, "status": status, "version": String(revision), "modifiedAt": String(Int(modified.timeIntervalSince1970)),
        ]
        let object = "sh.helm.release.v1.\(name).v\(revision)"
        if configMap {
            add("configmaps", object, namespace: namespace, labels: labels, data: ["release": KubeHelm.encode(release)], created: modified)
        } else {
            add(
                "secrets", object, namespace: namespace, values: ["Type": .text(KubeHelm.secretType)], labels: labels,
                data: ["release": KubeHelm.encode(release)], created: modified)
        }
    }

    /// One revision of a workload's pod template, as its controller keeps
    /// it: a Deployment's ReplicaSet (`deployment.kubernetes.io/revision`,
    /// the template's `pod-template-hash`), or with `controllerRevision` a
    /// StatefulSet's or DaemonSet's ControllerRevision (`revision`, the
    /// template in `data`) — owned by the workload (`owner`, its resource),
    /// labelled `labels`, its one container `image` with `env`.
    func addRevision(
        of owner: String, _ ownerResource: String = "deployments.apps", namespace: String, name: String, revision: Int, image: String,
        env: [String: String] = [:], restartedAt: String? = nil, history: [Int] = [], labels: [String: String], replicas: Int = 1, created: Date = Date(),
        controllerRevision: Bool = false
    ) {
        let kind = locked { kinds.first { $0.fullName == ownerResource } }
        let reference: [String: Any] = [
            "apiVersion": kind?.groupVersion ?? "apps/v1", "kind": kind?.kind ?? "Deployment", "name": owner,
            "uid": uid(ownerResource, owner, namespace: namespace) ?? "", "controller": true,
        ]
        var container: [String: Any] = ["name": "app", "image": image]
        if !env.isEmpty { container["env"] = env.keys.sorted().map { ["name": $0, "value": env[$0]!] } }
        var templateLabels: [String: Any] = labels
        if !controllerRevision { templateLabels["pod-template-hash"] = name.split(separator: "-").last.map(String.init) ?? name }
        var templateMetadata: [String: Any] = ["labels": templateLabels]
        if let restartedAt { templateMetadata["annotations"] = ["kubectl.kubernetes.io/restartedAt": restartedAt] }
        let template: [String: Any] = ["metadata": templateMetadata, "spec": ["containers": [container]]]
        if controllerRevision {
            add(
                "controllerrevisions.apps", name, namespace: namespace, labels: labels, created: created,
                fields: [
                    "metadata": ["ownerReferences": [reference]], "revision": revision,
                    "data": ["spec": ["template": template.merging(["$patch": "replace"]) { $1 }]],
                ])
            return
        }
        var annotations = ["deployment.kubernetes.io/revision": String(revision)]
        if !history.isEmpty { annotations["deployment.kubernetes.io/revision-history"] = history.map(String.init).joined(separator: ",") }
        add(
            "replicasets.apps", name, namespace: namespace, values: ["Desired": .integer(replicas), "Current": .integer(replicas)], labels: labels,
            annotations: annotations, created: created,
            fields: ["metadata": ["ownerReferences": [reference]], "spec": ["replicas": replicas, "template": template]])
    }

    /// The names of the objects of a kind it holds.
    func names(_ resource: String) -> [String] { locked { objects.values.filter { $0.resource == resource }.map(\.name).sorted() } }

    /// A CustomResourceDefinition: its kind served from now on — in
    /// discovery and in paths — and the CRD itself an object, ADDED to the
    /// watches of CRDs, as the server has it once the CRD is established.
    /// `columns`: its `additionalPrinterColumns` (Name and Age come with them);
    /// `schema`: its `spec`'s OpenAPI schema, as `/openapi/v3` says it (nil: anything).
    func addCRD(
        group: String, version: String, plural: String, kind: String, namespaced: Bool = true, shortNames: [String] = [], columns: [Column] = [],
        schema: [String: Any]? = nil
    ) {
        let served = Kind(
            group: group, version: version, resource: plural, kind: kind, namespaced: namespaced, shortNames: shortNames, categories: [],
            subresources: ["status"], columns: columns, custom: true)
        locked {
            kinds.append(served)
            if let schema { crdSchemas[served.fullName] = schema }
        }
        add("customresourcedefinitions.apiextensions.k8s.io", "\(plural).\(group)", values: [:], labels: [:])
    }

    /// A kind served at another version too (a CRD's older one,
    /// `autoscaling/v1`): its own path and resource list, the objects the
    /// same; discovery's preferred version stays the first one served.
    func serve(_ fullName: String, alsoAt version: String) {
        locked {
            guard var kind = kinds.first(where: { $0.fullName == fullName }), !kinds.contains(where: { $0.fullName == fullName && $0.version == version })
            else { return }
            kind.version = version
            kinds.append(kind)
        }
    }

    /// A CRD deleted: its kind no longer served (a request for it is 404),
    /// its objects gone with it and its watches ended, the CRD DELETED to
    /// the watches of CRDs.
    func removeCRD(_ name: String) {
        let ended = locked { () -> [Channel] in
            kinds.removeAll { $0.fullName == name }
            crdSchemas[name] = nil
            objects = objects.filter { $0.value.resource != name }
            let ids = watchers.filter { $0.value.resource == name }.map(\.key)
            defer { ids.forEach { watchers[$0] = nil } }
            return ids.compactMap { watchers[$0]?.channel }
        }
        ended.forEach(Self.end)
        delete("customresourcedefinitions.apiextensions.k8s.io", name)
    }

    /// A built-in kind not served, as a smaller cluster's (before discovery
    /// is read: a section with nothing in it).
    func unserve(_ fullName: String) { locked { kinds.removeAll { $0.fullName == fullName } } }

    /// The kinds it serves now.
    var servedKinds: [Kind] { locked { kinds } }

    /// Applies one change under the lock and sends its event.
    private func change(_ type: String, _ make: () -> Object?) {
        let sends = locked { () -> [(Channel, Data)] in
            guard var object = make() else { return [] }
            current += 1
            object.resourceVersion = current
            let key = Self.key(object.resource, object.namespace, object.name)
            let old = objects[key]
            if type == "DELETED" { objects[key] = nil } else { objects[key] = object }
            history.append((current, type, object))
            return watchers.keys.compactMap { id in
                guard let watcher = watchers[id] else { return nil }
                let now = watcher.matches(object)
                let was = old.map(watcher.matches) ?? false
                // As the server's watch cache says a change to a watch with
                // a selector: one that stops matching is DELETED from it,
                // one that starts is ADDED.
                let sent: String? = type == "MODIFIED" ? (was && now ? type : was ? "DELETED" : now ? "ADDED" : nil) : (now ? type : nil)
                guard let sent else { return nil }
                return (watcher.channel, eventLine(sent, object, for: id))
            }
        }
        for (channel, line) in sends { Self.write(line, to: channel) }
    }

    /// A BOOKMARK at the current version, to every watch that allows them.
    func bookmark() {
        let sends = locked { () -> [(Channel, Data)] in
            watchers.filter(\.value.bookmarks).map { id, watcher in (watcher.channel, bookmarkLine(current, table: watcher.table, initialEnd: false, for: id)) }
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

    /// Every answer to `path` (a whole one, not a watch's or a log's) held
    /// `milliseconds` after it is asked — recorded when it arrives, as any
    /// request; nil answers it at once again.
    func answerSlowly(_ path: String, milliseconds: Int?) { locked { slowPaths[path] = milliseconds } }
    /// Answers held now.
    var heldAnswers: Int { locked { heldNow } }
    /// The paths of held answers whose client closed before they went.
    var droppedAnswers: [String] { locked { dropped } }

    fileprivate func slowness(_ path: String) -> Int? { locked { slowPaths[path] } }
    fileprivate func holding(_ change: Int, dropped path: String? = nil) {
        locked {
            heldNow += change
            if let path { dropped.append(path) }
        }
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
    /// `/version`, discovery's roots and anything else. `kinds`: those
    /// served, for the route's kind.
    static func route(_ path: String, kinds: [Kind] = builtinKinds) -> Route? {
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

    fileprivate static func matches(_ object: Object, _ resource: String, _ namespace: String?, _ labels: LabelSelector) -> Bool {
        object.resource == resource && (namespace == nil || object.namespace == namespace) && labels.matches(object.labels)
    }

    /// A label selector as far as the fake reads one: `a=b`, `a==b`,
    /// `a!=b`, `a` (has it) and `!a` (hasn't), comma-separated — no sets.
    struct LabelSelector: Sendable {
        enum Requirement: Sendable {
            case equals(String, String)
            case notEquals(String, String)
            case exists(String)
            case missing(String)
        }

        var requirements: [Requirement] = []

        init(_ text: String?) {
            for part in (text ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
                if let range = part.range(of: "!=") {
                    requirements.append(.notEquals(String(part[..<range.lowerBound]), String(part[range.upperBound...])))
                } else if let range = part.range(of: "==") ?? part.range(of: "=") {
                    requirements.append(.equals(String(part[..<range.lowerBound]), String(part[range.upperBound...])))
                } else if part.hasPrefix("!") {
                    requirements.append(.missing(String(part.dropFirst())))
                } else {
                    requirements.append(.exists(part))
                }
            }
        }

        func matches(_ labels: [String: String]) -> Bool {
            requirements.allSatisfy { requirement in
                switch requirement {
                case .equals(let key, let value): labels[key] == value
                case .notEquals(let key, let value): labels[key] != value
                case .exists(let key): labels[key] != nil
                case .missing(let key): labels[key] == nil
                }
            }
        }
    }

    private static func selector(_ text: String?) -> LabelSelector { LabelSelector(text) }

    /// A field selector as the fake reads one: `a.b=c`, `a.b==c`, `a.b!=c`,
    /// comma-separated, each a dotted path into the object as a GET answers it.
    struct FieldSelector: Sendable {
        var requirements: [(path: [String], value: String, equal: Bool)] = []
        var isEmpty: Bool { requirements.isEmpty }

        init(_ text: String?) {
            for part in (text ?? "").split(separator: ",").map(String.init) where !part.isEmpty {
                let (key, value, equal): (String, String, Bool)
                if let range = part.range(of: "!=") {
                    (key, value, equal) = (String(part[..<range.lowerBound]), String(part[range.upperBound...]), false)
                } else if let range = part.range(of: "==") ?? part.range(of: "=") {
                    (key, value, equal) = (String(part[..<range.lowerBound]), String(part[range.upperBound...]), true)
                } else {
                    continue
                }
                requirements.append((key.split(separator: ".").map(String.init), value, equal))
            }
        }

        func matches(_ object: [String: Any]) -> Bool {
            requirements.allSatisfy { requirement in
                var value: Any? = object
                for key in requirement.path { value = (value as? [String: Any])?[key] }
                let text = value.map { "\($0)" } ?? ""
                return (text == requirement.value) == requirement.equal
            }
        }
    }

    // MARK: Answers

    enum Answer {
        case json(Int, Data)
        case text(Int, String)
        case raw(Int, Data, [(String, String)])
        /// A watch's head now, then its lines; ended after `timeout` seconds.
        case watch(lines: [Data], end: Bool, timeout: Int?)
        /// A followed log's head and its lines now, plain text; more as they come.
        case log(lines: [Data])
    }

    func answer(_ method: HTTPMethod, _ uri: String, accept: String, body: Data = Data(), contentType: String = "", on channel: Channel) -> Answer {
        let components = URLComponents(string: "http://localhost" + uri)
        let path = components?.percentEncodedPath ?? uri
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        let isWatch = query["watch"] == "1" || query["watch"] == "true"
        let (failure, throttle, failedWatch, settings) = locked { () -> (String?, Int?, (status: Int, retryAfter: Int?)?, Settings) in
            asked.append(Request(method: method.rawValue, path: path, query: query, accept: accept, body: body, contentType: contentType))
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
        guard method == .GET else { return write(method, path: path, query: query, body: body, contentType: contentType) }
        switch path {
        case "/version":
            return .json(200, Self.encode(["major": "1", "minor": settings.minor, "gitVersion": "v1.\(settings.minor.prefix { $0.isNumber }).1", "platform": "linux/arm64"]))
        case "/openapi/v3":
            guard settings.servesOpenAPI else { return .json(404, Self.status(404, "NotFound", "the server could not find the requested resource")) }
            let (served, schemas) = locked { (kinds, crdSchemas) }
            return .json(200, Self.openAPIIndex(served, crdSchemas: schemas))
        case "/api", "/apis":
            if settings.aggregatedDiscovery && accept.contains("as=APIGroupDiscoveryList") {
                return .json(200, Self.aggregated(locked { kinds }, core: path == "/api", stale: settings.failingGroups))
            }
            return .json(200, path == "/api" ? Self.encode(["kind": "APIVersions", "versions": ["v1"]]) : groupList())
        default: break
        }
        if path.hasPrefix("/openapi/v3/") {
            let (served, schemas) = locked { (kinds, crdSchemas) }
            guard settings.servesOpenAPI, let document = Self.openAPIDocument(String(path.dropFirst("/openapi/v3/".count)), kinds: served, crdSchemas: schemas)
            else { return .json(404, Self.status(404, "NotFound", "the server could not find the requested resource")) }
            return .json(200, settings.openAPIPadding > 0 ? Data(repeating: 0x20, count: settings.openAPIPadding) + document : document)
        }
        guard let route = Self.route(path, kinds: locked { kinds }) else { return .json(404, Self.status(404, "NotFound", "the server could not find the requested resource")) }
        guard let resource = route.resource else {
            if settings.failingGroups.contains(route.groupVersion) { return .json(503, Self.status(503, "ServiceUnavailable", "the server is currently unable to handle the request")) }
            guard locked({ kinds.contains { $0.groupVersion == route.groupVersion } }) else {
                return .json(404, Self.status(404, "NotFound", "the server could not find the requested resource"))
            }
            return .json(200, resourceList(route.groupVersion))
        }
        if route.groupVersion == "v1", resource == "pods", route.subresource == "log", let namespace = route.namespace, let name = route.name {
            if settings.forbidden.contains("pods") {
                return .json(
                    403, Self.status(403, "Forbidden", "pods \"\(name)\" is forbidden: User \"system:anonymous\" cannot get resource \"pods/log\" in API group \"\""))
            }
            return log(namespace: namespace, pod: name, query: query, channel: channel)
        }
        if route.groupVersion == "v1", resource == "services", route.subresource?.hasPrefix("proxy") == true {
            return prometheusAnswer(route, query: query)
        }
        if let kind = route.kind, route.subresource == "scale", kind.subresources.contains("scale"), let name = route.name {
            guard let object = locked({ objects[Self.key(kind.fullName, route.namespace, name)] }) else {
                return .json(404, Self.status(404, "NotFound", "\(resource) \"\(name)\" not found"))
            }
            return .json(200, Self.encode(Self.scale(of: object, kind)))
        }
        guard let kind = route.kind, route.subresource == nil else {
            return .json(404, Self.status(404, "NotFound", "the server could not find the requested resource"))
        }
        if kind.namespaced == false && route.namespace != nil { return .json(404, Self.status(404, "NotFound", "the server could not find the requested resource")) }
        // `pods@cluster`: refused only across the cluster, each namespace's
        // allowed; `pods@locked`: refused in that namespace alone.
        // `pods.metrics.k8s.io`: refused in that group alone; with `@locked`
        // or `@cluster`, in that group and that namespace or scope alone.
        let refusedHere = [resource, kind.fullName].contains { name in
            settings.forbidden.contains(name) || (route.namespace == nil && settings.forbidden.contains(name + "@cluster"))
                || route.namespace.map({ settings.forbidden.contains(name + "@" + $0) }) == true
        }
        if refusedHere {
            let scope = route.namespace.map { "in the namespace \"\($0)\"" } ?? "at the cluster scope"
            return .json(
                403,
                Self.status(
                    403, "Forbidden",
                    "\(resource) is forbidden: User \"system:anonymous\" cannot list resource \"\(resource)\" in API group \"\(kind.group)\" \(scope)"))
        }
        // `pods@payments`: failing in that namespace alone.
        if settings.failingResources.contains(resource) || route.namespace.map({ settings.failingResources.contains(resource + "@" + $0) }) == true {
            return .json(500, Self.status(500, "InternalError", "an error on the server (\"etcdserver: request timed out\") has prevented the request from succeeding"))
        }
        if let name = route.name {
            guard let object = locked({ objects[Self.key(kind.fullName, route.namespace, name)] }) else {
                return .json(404, Self.status(404, "NotFound", "\(resource) \"\(name)\" not found"))
            }
            if accept.contains("as=PartialObjectMetadata") {
                var metadata = Self.full(object, kind)["metadata"] as? [String: Any] ?? [:]
                metadata["managedFields"] = nil
                return .json(200, Self.encode(["kind": "PartialObjectMetadata", "apiVersion": "meta.k8s.io/v1", "metadata": metadata]))
            }
            return .json(200, Self.encode(Self.full(object, kind)))
        }
        let table = accept.contains("as=Table") && !settings.ignoresTables.contains(resource)
        let includeObject = query["includeObject"] ?? "Metadata"
        let labels = Self.selector(query["labelSelector"])
        if isWatch {
            return watch(kind, namespace: route.namespace, query: query, table: table, includeObject: includeObject, labels: labels, channel: channel)
        }
        return list(
            kind, namespace: route.namespace, query: query, table: table, includeObject: includeObject, labels: labels,
            metadataOnly: !table && accept.contains("as=PartialObjectMetadataList"))
    }

    /// A Service's proxy: the fake Prometheus's two query paths, else 403.
    private func prometheusAnswer(_ route: Route, query: [String: String]) -> Answer {
        let (served, series, failure, fixtures, refusal) = locked {
            (prometheus, prometheusSeries, prometheusFailure, prometheusFixtures, prometheusRefusal)
        }
        guard let served, route.namespace == served.namespace, route.name == "\(served.service):\(served.port)",
            let sub = route.subresource, sub == "proxy/api/v1/query" || sub == "proxy/api/v1/query_range"
        else { return .text(403, "Forbidden") }
        if let refusal {
            var headers = [("Content-Type", "application/json")]
            if let after = refusal.retryAfter { headers.append(("Retry-After", String(after))) }
            let message =
                refusal.status == 403
                ? "services \"\(served.service):\(served.port)\" is forbidden: User \"fake\" cannot get resource \"services/proxy\" in API group \"\" in the namespace \"\(served.namespace)\""
                : "the server is busy (HTTP \(refusal.status))"
            return .raw(refusal.status, Self.status(refusal.status, refusal.status == 403 ? "Forbidden" : "TooManyRequests", message), headers)
        }
        if let failure { return .text(failure.status, failure.text) }
        let promql = query["query"] ?? ""
        let fixture = fixtures.first { $0.matches(promql) }
        if let failure = fixture?.failure {
            return .json(failure.status, Self.encode(["status": "error", "errorType": failure.errorType, "error": failure.error]))
        }
        // A fixture's lines, else what FakePromQL evaluates: (labels, the value at t).
        let groups: [([String: String], @Sendable (Double) -> Double?)]
        if let lines = fixture?.lines {
            groups = lines.map { ($0.labels, $0.value) }
        } else {
            guard let evaluated = FakePromQL.evaluate(promql, series) else {
                return .json(400, Self.encode(["status": "error", "errorType": "bad_data", "error": "1:1: parse error: the fake Prometheus can't read \(promql)"]))
            }
            groups = evaluated.map { sample in (sample.labels, { _ in sample.value }) }
        }
        var answer: [String: Any] = ["status": "success"]
        if let warnings = fixture?.warnings, !warnings.isEmpty { answer["warnings"] = warnings }
        let result: [[String: Any]]
        if sub.hasSuffix("query_range") {
            guard let start = Double(query["start"] ?? ""), let end = Double(query["end"] ?? ""), let step = Self.seconds(query["step"] ?? ""), step > 0, end >= start
            else {
                return .json(400, Self.encode(["status": "error", "errorType": "bad_data", "error": "invalid parameter: start, end and step are needed"]))
            }
            let count = min(11_000, Int((end - start) / step) + 1)
            let scripted = fixture?.lines != nil
            result = groups.map { labels, value in
                let values: [[Any]] = (0..<count).compactMap { index in
                    let time = start + Double(index) * step
                    // An evaluated series rises to its value over the range; a fixture's line is its own.
                    let share = scripted || count <= 1 ? 1 : 0.8 + 0.2 * Double(index) / Double(count - 1)
                    return value(time).map { [time, Self.number($0 * share)] }
                }
                return ["metric": labels, "values": values]
            }
            answer["data"] = ["resultType": "matrix", "result": result]
            return .json(200, Self.encode(answer))
        }
        let now = Double(query["time"] ?? "") ?? Date().timeIntervalSince1970
        result = groups.compactMap { labels, value in value(now).map { ["metric": labels, "value": [now, Self.number($0)]] } }
        answer["data"] = ["resultType": "vector", "result": result]
        return .json(200, Self.encode(answer))
    }

    /// As Prometheus writes a sample: a whole number without its point (EFS's 8 EiB past Int's range as a Double).
    private static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 9e18 ? String(Int(value)) : String(value)
    }

    /// `30s`, `3m`, `1h`, or plain seconds.
    private static func seconds(_ text: String) -> Double? {
        if let plain = Double(text) { return plain }
        guard let unit = text.last, let number = Double(text.dropLast()) else { return nil }
        switch unit {
        case "s": return number
        case "m": return number * 60
        case "h": return number * 3600
        case "d": return number * 86400
        default: return nil
        }
    }

    /// `pods/{p}/log`: a container's log (`container` needed with several),
    /// its last terminated instance's (`previous`, a 400 when it never
    /// restarted), with `timestamps`, from `sinceSeconds` or `sinceTime`
    /// (whole seconds, as the API takes it), its last `tailLines`, at most
    /// `limitBytes` of it (not followed); with `follow`, kept open and
    /// written to as lines are appended.
    private func log(namespace: String, pod name: String, query: [String: String], channel: Channel) -> Answer {
        locked {
            guard let object = objects[Self.key("pods", namespace, name)], let pod = object.pod else {
                return .json(404, Self.status(404, "NotFound", "pods \"\(name)\" not found"))
            }
            let names = pod.containerNames
            let all = names + pod.initContainers + pod.ephemeralContainers
            let container: String
            if let asked = query["container"], !asked.isEmpty {
                guard all.contains(asked) else {
                    return .json(400, Self.status(400, "BadRequest", "container \(asked) is not valid for pod \(name)"))
                }
                container = asked
            } else if names.count == 1 {
                container = names[0]
            } else {
                let initial = pod.initContainers.isEmpty ? "" : " or one of the init containers: [\(pod.initContainers.joined(separator: " "))]"
                return .json(
                    400,
                    Self.status(
                        400, "BadRequest", "a container name must be specified for pod \(name), choose one of: [\(names.joined(separator: " "))]\(initial)"))
            }
            let previous = query["previous"] == "true"
            let restarts = container == names.first ? pod.restarts : 0
            if previous && restarts == 0 && logs[Self.logKey(namespace, name, container, previous: true)] == nil {
                return .json(400, Self.status(400, "BadRequest", "previous terminated container \"\(container)\" in pod \"\(name)\" not found"))
            }
            let key = Self.logKey(namespace, name, container, previous: previous)
            var entries = logs[key] ?? []
            if let seconds = Int(query["sinceSeconds"] ?? "") {
                let from = Date().addingTimeInterval(-Double(seconds))
                entries = entries.filter { $0.time >= from }
            } else if let text = query["sinceTime"], let from = try? Date(text, strategy: .iso8601) {
                // Whole seconds: that second's lines come again.
                let second = from.timeIntervalSince1970.rounded(.down)
                entries = entries.filter { $0.time.timeIntervalSince1970.rounded(.down) >= second }
            }
            if let tail = Int(query["tailLines"] ?? ""), tail >= 0 { entries = Array(entries.suffix(tail)) }
            let timestamps = query["timestamps"] == "true"
            let lines = entries.map { Data(((timestamps ? $0.stamp + " " : "") + $0.text + "\n").utf8) }
            // A container ended for good (the pod Succeeded or Failed): its
            // log answered whole and the follow ended, as the kubelet does.
            let endedForGood = container == names.first && pod.terminatedReason != nil && (pod.phase == "Succeeded" || pod.phase == "Failed")
            guard query["follow"] == "true", !previous, !settings.endFollowsAtOnce, !endedForGood else {
                var body = lines.reduce(Data(), +)
                // The API's limitBytes: it stops there, mid-line or not.
                if let limit = Int(query["limitBytes"] ?? ""), limit > 0, body.count > limit { body = body.prefix(limit) }
                return .raw(200, body, [("Content-Type", "text/plain")])
            }
            logFollowers[ObjectIdentifier(channel)] = (channel, key, timestamps)
            return .log(lines: lines)
        }
    }

    /// `2026-11-04T10:00:00.123456789Z`.
    static func nanoStamp(_ date: Date) -> String {
        let seconds = date.timeIntervalSince1970.rounded(.down)
        let nanos = min(999_999_999, max(0, Int(((date.timeIntervalSince1970 - seconds) * 1e9).rounded())))
        let whole = Date(timeIntervalSince1970: seconds).formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.colon))
        return whole + "." + String(format: "%09d", nanos) + "Z"
    }

    private func list(
        _ kind: Kind, namespace: String?, query: [String: String], table: Bool, includeObject: String, labels: LabelSelector, metadataOnly: Bool = false
    ) -> Answer {
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
            let fields = FieldSelector(query["fieldSelector"])
            var matching = objects.values.filter { Self.matches($0, kind.fullName, namespace, labels) && fields.matches(Self.full($0, kind)) }.sorted {
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
            if metadataOnly {
                // `as=PartialObjectMetadataList`: each item's metadata alone —
                // a Secret's data never comes this way.
                return .json(
                    200,
                    Self.encode([
                        "kind": "PartialObjectMetadataList", "apiVersion": "meta.k8s.io/v1", "metadata": metadata,
                        "items": matching.map {
                            ["kind": "PartialObjectMetadata", "apiVersion": "meta.k8s.io/v1", "metadata": Self.metadata($0, managedFields: false)]
                        },
                    ]))
            }
            return .json(
                200, Self.encode(["kind": kind.kind + "List", "apiVersion": kind.groupVersion, "metadata": metadata, "items": matching.map { Self.full($0, kind) }]))
        }
    }

    private func watch(
        _ kind: Kind, namespace: String?, query: [String: String], table: Bool, includeObject: String, labels: LabelSelector, channel: Channel
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
            let watcher = Watcher(
                channel: channel, resource: kind.fullName, namespace: namespace, table: table, includeObject: includeObject, bookmarks: bookmarks, labels: labels,
                fields: FieldSelector(query["fieldSelector"]), kind: kind)
            watchers[id] = watcher
            let matching = { (object: Object) in watcher.matches(object) }
            let version = query["resourceVersion"] ?? ""
            if initialEvents || version.isEmpty || version == "0" {
                // Every object there now, ADDED; a streaming list ends with a bookmark.
                var lines = objects.values.filter(matching).sorted { ($0.namespace ?? "", $0.name) < ($1.namespace ?? "", $1.name) }.map {
                    eventLine("ADDED", $0, for: id)
                }
                if initialEvents && settings.interimBookmarks && bookmarks {
                    // One before the end: it moves the version on, it isn't the list.
                    lines.insert(bookmarkLine(current, table: table, initialEnd: false, for: id), at: min(1, lines.count))
                }
                if initialEvents { lines.append(bookmarkLine(current, table: table, initialEnd: !table || settings.streamingTables, for: id)) }
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
    fileprivate func forget(_ channel: Channel) {
        locked {
            watchers[ObjectIdentifier(channel)] = nil
            logFollowers[ObjectIdentifier(channel)] = nil
        }
    }

    // MARK: Objects as the server writes them

    /// One event, its object as the watch asked for it. Under the lock.
    private func eventLine(_ type: String, _ object: Object, for id: ObjectIdentifier) -> Data {
        guard var watcher = watchers[id], let kind = kinds.first(where: { $0.fullName == object.resource }) else { return Data() }
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

    /// A bookmark as kind's 1.37 sends one: a plain object with the
    /// version (and the end's annotation) in its metadata — or, for a
    /// Table, a Table whose own metadata has only the version and whose
    /// one row, its cells empty, carries the annotation on its object,
    /// whatever `includeObject` asked; the columns when it is the stream's
    /// first Table (an empty list's end).
    private func bookmarkLine(_ version: Int, table: Bool, initialEnd: Bool, for id: ObjectIdentifier) -> Data {
        var metadata: [String: Any] = ["resourceVersion": String(version)]
        if initialEnd { metadata["annotations"] = ["k8s.io/initial-events-end": "true"] }
        guard table, var watcher = watchers[id] else { return Self.line(["type": "BOOKMARK", "object": ["kind": "Pod", "apiVersion": "v1", "metadata": metadata]]) }
        var object: [String: Any] = [
            "kind": "Table", "apiVersion": "meta.k8s.io/v1", "metadata": ["resourceVersion": String(version)],
            "rows": [["cells": [""], "object": ["kind": "PartialObjectMetadata", "apiVersion": "meta.k8s.io/v1", "metadata": metadata]]],
        ]
        if !watcher.sentColumns, settings.bookmarkColumns, let kind = kinds.first(where: { $0.fullName == watcher.resource }) {
            object["columnDefinitions"] = Self.tableObject([], kind, includeObject: "None", columns: true)["columnDefinitions"]
            watcher.sentColumns = true
            watchers[id] = watcher
        }
        return Self.line(["type": "BOOKMARK", "object": object])
    }

    private static func goneLine(_ version: String = "", _ oldest: Int = 0) -> Data {
        line(["type": "ERROR", "object": statusObject(410, "Expired", "too old resource version: \(version) (\(oldest))")])
    }

    /// A kind's Table columns: a CRD's printer columns (Name first, Age
    /// last, as the server adds them), else `kubectl get`'s for the kind.
    static func columns(for kind: Kind) -> [Column] {
        let name = Column(name: "Name", format: "name", description: "Name must be unique within a namespace.")
        let age = Column(name: "Age", description: "CreationTimestamp is a timestamp representing the server time when this object was created.")
        // A CRD's own Age (Flux's: a date column) stands for the server's.
        if let columns = kind.columns { return [name] + columns + (columns.contains { $0.name == "Age" } ? [] : [age]) }
        func column(_ name: String, _ type: String = "string", priority: Int = 0, _ description: String = "") -> Column {
            Column(name: name, type: type, priority: priority, description: description)
        }
        switch kind.fullName {
        case "pods":
            return [
                name, column("Ready", "The aggregate readiness state of this pod for accepting traffic."),
                column("Status", "The aggregate status of the containers in this pod."),
                column("Restarts", "The number of times the containers in this pod have been restarted and when the last container in this pod has restarted."),
                age, column("IP", priority: 1, "IP address allocated to the pod. Routable at least within the cluster. Empty if not yet allocated."),
                column("Node", priority: 1, "NodeName is a request to schedule this pod onto a specific node."),
                column("Nominated Node", priority: 1, "nominatedNodeName is set only when this pod preempts other pods on the node."),
                column("Readiness Gates", priority: 1, "If specified, all readiness gates will be evaluated for pod readiness."),
            ]
        case "namespaces":
            return [name, column("Status", "The status of the namespace"), age]
        case "deployments.apps":
            return [
                name, column("Ready", "Number of the pod with ready state"),
                column("Up-to-date", "integer", "Total number of non-terminated pods targeted by this deployment that have the desired template spec."),
                column("Available", "integer", "Total number of available pods (ready for at least minReadySeconds) targeted by this deployment."), age,
                column("Containers", priority: 1, "Names of each container in the template."), column("Images", priority: 1, "Images referenced by each container in the template."),
                column("Selector", priority: 1, "Label selector for pods. Existing ReplicaSets whose pods are selected by this will be the ones affected by this deployment."),
            ]
        case "services":
            return [
                name, column("Type", "type determines how the Service is exposed."), column("Cluster-IP", "clusterIP is the IP address of the service."),
                column("External-IP", "externalIPs is a list of IP addresses for which nodes in the cluster will also accept traffic for this service."),
                column("Port(s)", "The list of ports that are exposed by this service."), age,
                column("Selector", priority: 1, "Route service traffic to pods with label keys and values matching this selector."),
            ]
        case "configmaps":
            return [name, column("Data", "integer", "Data contains the configuration data."), age]
        case "horizontalpodautoscalers.autoscaling":
            return [
                name, column("Reference", "The scale target."), column("Targets", "The metrics against their targets."),
                column("MinPods", "integer", "The lower limit for the number of replicas."), column("MaxPods", "integer", "The upper limit for the number of replicas."),
                column("Replicas", "integer", "The current number of replicas."), age,
            ]
        case "persistentvolumeclaims":
            return [
                name, column("Status", "Status is the current state of the claim."), column("Volume", "The volume bound to it."),
                column("Capacity", "The actual resources of the underlying volume."), column("Access Modes", "The access modes the volume has."),
                column("StorageClass", "The name of the StorageClass it asks for."), age,
            ]
        case "secrets":
            return [name, column("Type", "Used to facilitate programmatic handling of secret data."), column("Data", "integer", "Data contains the secret data."), age]
        case "nodes":
            return [
                name, column("Status", "The status of the node"), column("Roles", "The roles of the node"), age,
                column("Version", "Kubelet Version reported by the node."), column("Internal-IP", priority: 1, "List of addresses reachable to the node."),
                column("OS-Image", priority: 1, "OS Image reported by the node from /etc/os-release (e.g. Debian GNU/Linux 7 (wheezy))."),
                column("Container-Runtime", priority: 1, "Container runtime version reported by the node through runtime remote API (e.g. containerd://1.4.2)."),
            ]
        case "events", "events.events.k8s.io":
            // Count and Name are wide columns, as the server has them: `format: name` says which.
            return [
                column("Last Seen"), column("Type"), column("Reason"), column("Object"), column("Message"),
                column("Count", "integer", priority: 1, "The number of times this event has occurred."),
                Column(name: "Name", format: "name", priority: 1, description: "Name must be unique within a namespace."),
            ]
        case "statefulsets.apps":
            return [
                name, column("Ready", "Number of the pod with ready state"), age,
                column("Containers", priority: 1, "Names of each container in the template."), column("Images", priority: 1, "Images referenced by each container in the template."),
            ]
        case "daemonsets.apps":
            return [
                name, column("Desired", "integer", "The desired number of pods."), column("Current", "integer", "The current number of pods."),
                column("Ready", "integer", "The number of pods ready."), column("Up-to-date", "integer", "The number of pods updated."),
                column("Available", "integer", "The number of pods available."), column("Node Selector", "The node selector."), age,
                column("Containers", priority: 1, "Names of each container in the template."), column("Images", priority: 1, "Images referenced by each container in the template."),
                column("Selector", priority: 1, "Label selector for pods."),
            ]
        case "jobs.batch":
            return [
                name, column("Status", "Status of the job."), column("Completions", "The completion status of the job."),
                column("Duration", "Time required to complete the job."), age,
                column("Containers", priority: 1, "Names of each container in the template."), column("Images", priority: 1, "Images referenced by each container in the template."),
            ]
        case "cronjobs.batch":
            return [
                name, column("Schedule", "The schedule in Cron format."), column("Timezone", "The time zone the schedule is in."),
                column("Suspend", "boolean", "Whether further executions are suspended."), column("Active", "integer", "The number of running jobs."),
                column("Last Schedule", "The last time the job was successfully scheduled."), age,
                column("Containers", priority: 1, "Names of each container in the template."), column("Images", priority: 1, "Images referenced by each container in the template."),
            ]
        case "customresourcedefinitions.apiextensions.k8s.io":
            return [name, Column(name: "Created At", type: "date", description: "CreationTimestamp is a timestamp representing the server time when this object was created.")]
        default:
            return [name, age]
        }
    }

    /// A row's cells, in its kind's columns.
    static func cells(_ object: Object, _ kind: Kind) -> [Any] {
        let age = age(since: object.created)
        if let pod = object.pod {
            let restarts: Any = pod.restarts > 0 && pod.lastRestart != nil ? "\(pod.restarts) (\(pod.lastRestart!) ago)" : pod.restarts
            return [object.name, "\(pod.ready)/\(pod.containers)", pod.status, restarts, age, pod.ip, pod.node, "<none>", "<none>"]
        }
        // What the spec says that kubectl's columns show: a node's
        // SchedulingDisabled, a CronJob's Suspend.
        let spec: [String: Any]? =
            ["nodes", "cronjobs.batch"].contains(object.resource)
            ? (object.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["spec"] as? [String: Any]) : nil
        return columns(for: kind).map { column -> Any in
            if object.resource == "nodes", column.name == "Status" {
                let base = object.values["Status"].map { "\($0.json)" } ?? "Ready"
                let conditions = base.split(separator: ",").filter { $0 != "SchedulingDisabled" }.map(String.init)
                return (conditions + (spec?["unschedulable"] as? Bool == true ? ["SchedulingDisabled"] : [])).joined(separator: ",")
            }
            if object.resource == "cronjobs.batch", column.name == "Suspend", object.values["Suspend"] == nil {
                // kubectl's printer says it as a word.
                return spec?["suspend"] as? Bool == true ? "True" : "False"
            }
            if let value = object.values[column.name] { return value.json }
            switch column.name {
            case "Name": return object.name
            case "Age", "Last Seen": return age
            case "Created At": return time(object.created)
            case "Status" where object.resource == "namespaces": return "Active"
            case "Data": return object.data.count
            default: return column.type == "integer" ? 0 : "<none>"
            }
        }
    }

    private static func tableObject(_ objects: [Object], _ kind: Kind, includeObject: String, columns: Bool) -> [String: Any] {
        let rows: [[String: Any]] = objects.map { object in
            var row: [String: Any] = ["cells": cells(object, kind)]
            switch includeObject {
            case "None": break
            case "Object": row["object"] = full(object, kind)
            default:
                row["object"] = ["kind": "PartialObjectMetadata", "apiVersion": "meta.k8s.io/v1", "metadata": metadata(object, managedFields: false)]
            }
            return row
        }
        var table: [String: Any] = ["kind": "Table", "apiVersion": "meta.k8s.io/v1", "rows": rows]
        if columns {
            table["columnDefinitions"] = Self.columns(for: kind).map {
                ["name": $0.name, "type": $0.type, "format": $0.format, "description": $0.description, "priority": $0.priority] as [String: Any]
            }
        }
        return table
    }

    static func time(_ date: Date) -> String { date.formatted(.iso8601) }

    private static func metadata(_ object: Object, managedFields: Bool) -> [String: Any] {
        var metadata: [String: Any] = [
            "name": object.name, "uid": object.uid, "resourceVersion": String(object.resourceVersion), "creationTimestamp": time(object.created),
        ]
        if let namespace = object.namespace { metadata["namespace"] = namespace }
        if !object.labels.isEmpty { metadata["labels"] = object.labels }
        if !object.annotations.isEmpty { metadata["annotations"] = object.annotations }
        if managedFields, let own = object.managedFields, let entries = try? JSONSerialization.jsonObject(with: own) {
            metadata["managedFields"] = entries
        } else if managedFields {
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
            let names = pod.containerNames
            let env =
                pod.env.keys.sorted().map { ["name": $0, "value": pod.env[$0]!] as [String: Any] }
                + pod.secretEnv.keys.sorted().map { name -> [String: Any] in
                    let ref = pod.secretEnv[name]!
                    return ["name": name, "valueFrom": ["secretKeyRef": ["name": ref.name, "key": ref.key]]]
                }
            var spec: [String: Any] = [
                "containers": names.enumerated().map { index, name -> [String: Any] in
                    var container: [String: Any] = ["name": name, "image": pod.image]
                    if let resources = pod.resources[name], !resources.isEmpty { container["resources"] = resources }
                    if index == 0, !env.isEmpty { container["env"] = env }
                    if index == 0, !pod.ports.isEmpty {
                        container["ports"] = pod.ports.map { port -> [String: Any] in
                            var declared: [String: Any] = ["containerPort": port.port, "protocol": "TCP"]
                            if let name = port.name { declared["name"] = name }
                            return declared
                        }
                    }
                    return container
                },
                "nodeName": pod.node, "restartPolicy": "Always",
            ]
            if !pod.initContainers.isEmpty { spec["initContainers"] = pod.initContainers.map { ["name": $0, "image": "busybox:1.36"] } }
            if !pod.ephemeralContainers.isEmpty { spec["ephemeralContainers"] = pod.ephemeralContainers.map { ["name": $0, "image": "busybox:1.36"] } }
            full["spec"] = spec
            var status: [String: Any] = [
                "phase": pod.phase, "podIP": pod.ip,
                "containerStatuses": names.enumerated().map { index, name in
                    var item: [String: Any] = [
                        "name": name, "image": pod.image, "ready": index < pod.ready, "restartCount": index == 0 ? pod.restarts : 0,
                        "state": index < pod.ready ? ["running": ["startedAt": time(object.created)]] : ["waiting": ["reason": pod.status]],
                    ]
                    if index == 0, let reason = pod.terminatedReason {
                        item["state"] = ["terminated": ["reason": reason, "exitCode": pod.exitCode]]
                        item["ready"] = false
                    }
                    if index == 0, pod.restarts > 0 {
                        var terminated: [String: Any] = ["reason": pod.lastReason, "exitCode": pod.lastExitCode]
                        if let finished = pod.lastFinished {
                            terminated["finishedAt"] = time(finished)
                            terminated["startedAt"] = time(finished.addingTimeInterval(-600))
                        }
                        item["lastState"] = ["terminated": terminated]
                    }
                    return item
                },
            ]
            if let ready = pod.readyCondition { status["conditions"] = [["type": "Ready", "status": ready ? "True" : "False"]] }
            if !pod.initContainers.isEmpty {
                status["initContainerStatuses"] = pod.initContainers.map {
                    ["name": $0, "image": "busybox:1.36", "ready": true, "restartCount": 0, "state": ["terminated": ["reason": "Completed", "exitCode": 0]]] as [String: Any]
                }
            }
            if !pod.ephemeralContainers.isEmpty {
                status["ephemeralContainerStatuses"] = pod.ephemeralContainers.map {
                    ["name": $0, "image": "busybox:1.36", "ready": false, "restartCount": 0, "state": ["running": ["startedAt": time(object.created)]]] as [String: Any]
                }
            }
            full["status"] = status
        } else if object.resource == "namespaces" {
            full["spec"] = ["finalizers": ["kubernetes"]]
            full["status"] = ["phase": "Active"]
        } else if object.resource == "secrets" {
            full["type"] = object.values["Type"].map { "\($0.json)" } ?? "Opaque"
            full["data"] = object.data.mapValues { Data($0.utf8).base64EncodedString() }
        } else if object.resource == "configmaps" {
            full["data"] = object.data
        }
        if let body = object.body, let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            for (key, value) in fields {
                if key == "metadata", let more = value as? [String: Any], var metadata = full["metadata"] as? [String: Any] {
                    metadata.merge(more) { $1 }
                    full["metadata"] = metadata
                } else {
                    full[key] = value
                }
            }
        }
        // A sample with no stamp of its own: taken now, as metrics-server's are.
        if kind.group == "metrics.k8s.io", full["timestamp"] == nil { full["timestamp"] = time(Date()) }
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

    private static func aggregated(_ kinds: [Kind], core: Bool, stale: Set<String>) -> Data {
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
            // Each version its own entry, the preferred (first served) first, as the server lists them.
            var versions: [String] = []
            for kind in kinds where !versions.contains(kind.version) { versions.append(kind.version) }
            let entries: [[String: Any]] = versions.map { version in
                let groupVersion = group.isEmpty ? version : "\(group)/\(version)"
                if stale.contains(groupVersion) { return ["version": version, "resources": [Any](), "freshness": "Stale"] }
                let served = zip(kinds, resources).filter { $0.0.version == version }.map(\.1)
                return ["version": version, "resources": served, "freshness": "Current"]
            }
            return ["metadata": ["name": group], "versions": entries]
        }
        return encode(["kind": "APIGroupDiscoveryList", "apiVersion": "apidiscovery.k8s.io/v2", "metadata": [String: Any](), "items": items])
    }

    private func groupList() -> Data {
        var groups: [(String, String)] = []
        for kind in locked({ kinds }) where !kind.group.isEmpty && !groups.contains(where: { $0.0 == kind.group }) { groups.append((kind.group, kind.version)) }
        let list: [[String: Any]] = groups.map { group, version in
            let preferred = ["groupVersion": "\(group)/\(version)", "version": version]
            return ["name": group, "versions": [preferred], "preferredVersion": preferred]
        }
        return Self.encode(["kind": "APIGroupList", "apiVersion": "v1", "groups": list])
    }

    private func resourceList(_ groupVersion: String) -> Data {
        var resources: [[String: Any]] = []
        for kind in locked({ kinds }) where kind.groupVersion == groupVersion {
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

    // MARK: Writes

    static let accessReviewPath = "/apis/authorization.k8s.io/v1/selfsubjectaccessreviews"

    /// A write, applied to the objects as the server applies it — and sent
    /// to the watches as the change it is: an access review answered from
    /// `deniedAccess`; a DELETE (an object with finalizers only marked
    /// deleting); a merge, strategic (as a merge) or JSON patch; the
    /// `scale` subresource's PATCH; a pod's eviction (`evictionBlock`, a
    /// PodDisruptionBudget's 429); a POST to a collection made (a Job, a
    /// namespace); a namespace's DELETE taking what it holds.
    private func write(_ method: HTTPMethod, path: String, query: [String: String], body: Data, contentType: String) -> Answer {
        if method == .POST, path == Self.accessReviewPath { return review(body) }
        if let failure = locked({ () -> (status: Int, reason: String, message: String)? in
            defer { settings.nextWriteFailure = nil }
            return settings.nextWriteFailure
        }) {
            return .json(failure.status, Self.status(failure.status, failure.reason, failure.message))
        }
        let notAllowed = Answer.json(405, Self.status(405, "MethodNotAllowed", "the server does not allow this method on the requested resource"))
        guard let route = Self.route(path, kinds: locked { kinds }), let kind = route.kind else { return notAllowed }
        if method == .POST, route.name == nil, route.subresource == nil { return create(kind, namespace: route.namespace, body) }
        guard let name = route.name else { return notAllowed }
        let key = Self.key(kind.fullName, kind.namespaced ? route.namespace : nil, name)
        if method == .PATCH, route.subresource == nil, contentType.hasPrefix("application/apply-patch+yaml") {
            return apply(kind, key: key, namespace: kind.namespaced ? route.namespace : nil, name: name, query: query, body: body)
        }
        guard locked({ objects[key] }) != nil else { return .json(404, Self.status(404, "NotFound", "\(kind.resource) \"\(name)\" not found")) }
        switch (method, route.subresource) {
        case (.DELETE, nil) where kind.fullName == "namespaces":
            let answer = delete(key, kind, options: [:])
            emptyNamespace(name)
            return answer
        case (.DELETE, nil): return delete(key, kind, options: (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
        case (.PATCH, nil): return patch(key, kind, body, contentType)
        case (.PATCH, "scale") where kind.subresources.contains("scale"): return patchScale(key, kind, body)
        case (.PATCH, "resize") where kind.fullName == "pods" && kind.subresources.contains("resize"): return patchResize(key, kind, body, contentType)
        case (.POST, "eviction") where kind.fullName == "pods": return evict(key, kind)
        default: return notAllowed
        }
    }

    /// A SelfSubjectAccessReview, answered: allowed unless `deniedAccess` names it.
    private func review(_ body: Data) -> Answer {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let attributes = ((object["spec"] as? [String: Any])?["resourceAttributes"] as? [String: Any]) ?? [:]
        let group = attributes["group"] as? String ?? ""
        let subresource = attributes["subresource"] as? String ?? ""
        let said =
            "\(attributes["verb"] as? String ?? "") \(attributes["resource"] as? String ?? "")" + (group.isEmpty ? "" : ".\(group)")
            + (subresource.isEmpty ? "" : "/\(subresource)")
        let allowed = !locked { settings.deniedAccess }.contains(said)
        var status: [String: Any] = ["allowed": allowed]
        if !allowed { status["reason"] = "RBAC: \(said) is not allowed" }
        return .json(
            201,
            Self.encode([
                "kind": "SelfSubjectAccessReview", "apiVersion": "authorization.k8s.io/v1", "metadata": [String: Any](), "spec": object["spec"] ?? [:],
                "status": status,
            ]))
    }

    /// A POST to a collection: the object made from its body — a
    /// namespace (its name a DNS label), a Job (Running, 0/1) — or 409
    /// when its name is taken, 404 when its namespace isn't there.
    private func create(_ kind: Kind, namespace: String?, _ body: Data) -> Answer {
        guard kind.verbs.contains("create") else {
            return .json(405, Self.status(405, "MethodNotAllowed", "the server does not allow this method on the requested resource"))
        }
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        var metadata = object["metadata"] as? [String: Any] ?? [:]
        guard let name = metadata["name"] as? String, !name.isEmpty else {
            return .json(422, Self.status(422, "Invalid", "\(kind.kind) \"\" is invalid: metadata.name: Required value: name or generateName is required"))
        }
        if kind.fullName == "namespaces", KubeNamespaceName.problem(name) != nil {
            return .json(
                422,
                Self.status(
                    422, "Invalid",
                    "Namespace \"\(name)\" is invalid: metadata.name: Invalid value: \"\(name)\": a lowercase RFC 1123 label must consist of lower case alphanumeric characters or '-'"))
        }
        let scope = kind.namespaced ? namespace : nil
        if kind.namespaced {
            guard let namespace, locked({ objects[Self.key("namespaces", nil, namespace)] }) != nil else {
                return .json(404, Self.status(404, "NotFound", "namespaces \"\(namespace ?? "")\" not found"))
            }
        }
        let key = Self.key(kind.fullName, scope, name)
        guard locked({ objects[key] }) == nil else {
            return .json(409, Self.status(409, "AlreadyExists", "\(kind.resource) \"\(name)\" already exists"))
        }
        let labels = metadata["labels"] as? [String: String] ?? [:]
        let annotations = metadata["annotations"] as? [String: String] ?? [:]
        for generated in ["name", "namespace", "uid", "resourceVersion", "creationTimestamp", "labels", "annotations"] { metadata[generated] = nil }
        var fields = object.filter { !["kind", "apiVersion", "metadata"].contains($0.key) }
        if !metadata.isEmpty { fields["metadata"] = metadata }
        let values: [String: Value] =
            kind.fullName == "jobs.batch" ? ["Status": .text("Running"), "Completions": .text("0/1"), "Duration": .text("0s")] : [:]
        var made: [String: Any] = [:]
        change("ADDED") {
            let object = Object(
                resource: kind.fullName, namespace: scope, name: name, uid: UUID().uuidString.lowercased(), resourceVersion: 0, created: Date(),
                labels: labels, values: values, annotations: annotations, body: fields.isEmpty ? nil : Self.encode(fields))
            made = Self.full(object, kind)
            return object
        }
        return .json(201, Self.encode(made))
    }

    /// A namespace deleted: everything in it goes too (the namespace
    /// controller's work, done at once).
    private func emptyNamespace(_ name: String) {
        let keys = locked { objects.filter { $0.value.namespace == name }.map(\.key) }
        for key in keys { change("DELETED") { objects[key] } }
    }

    /// DELETE: gone, or — with finalizers — marked deleting until they're removed.
    private func delete(_ key: String, _ kind: Kind, options: [String: Any]) -> Answer {
        var answer = Answer.json(404, Self.status(404, "NotFound", "not found"))
        var deleted = false
        var podName: (String, String)?
        change(locked({ (objects[key].map { Self.full($0, kind) }?["metadata"] as? [String: Any])?["finalizers"] as? [String] ?? [] }).isEmpty ? "DELETED" : "MODIFIED") {
            guard var object = objects[key] else { return nil }
            let full = Self.full(object, kind)
            let finalizers = (full["metadata"] as? [String: Any])?["finalizers"] as? [String] ?? []
            if finalizers.isEmpty {
                deleted = true
                if object.pod != nil { podName = (object.name, object.namespace ?? "") }
                answer = .json(200, Self.encode(full))
                return object
            }
            var metadata = full["metadata"] as? [String: Any] ?? [:]
            metadata["deletionTimestamp"] = Self.time(Date())
            metadata["deletionGracePeriodSeconds"] = (options["gracePeriodSeconds"] as? NSNumber)?.intValue ?? 30
            var changed = full
            changed["metadata"] = metadata
            Self.store(changed, in: &object)
            answer = .json(200, Self.encode(Self.full(object, kind)))
            return object
        }
        if deleted, let (name, namespace) = podName { endLogStreams(of: name, namespace: namespace) }
        return answer
    }

    /// A PATCH of the object: merge and strategic (as a merge, which is
    /// what Overterm's patches need), or JSON patch. Finalizers removed
    /// from an object being deleted delete it.
    private func patch(_ key: String, _ kind: Kind, _ body: Data, _ contentType: String) -> Answer {
        guard let patch = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
            return .json(400, Self.status(400, "BadRequest", "the body of the request was in an unknown format"))
        }
        guard let object = locked({ objects[key] }) else { return .json(404, Self.status(404, "NotFound", "not found")) }
        if kind.custom, contentType.hasPrefix("application/strategic-merge-patch+json") {
            return .json(
                415,
                Self.status(
                    415, "UnsupportedMediaType",
                    "the body of the request was in an unknown format - accepted media types include: application/json-patch+json, "
                        + "application/merge-patch+json, application/apply-patch+yaml"))
        }
        let full = Self.full(object, kind)
        let result: [String: Any]?
        if contentType.hasPrefix("application/json-patch+json") {
            guard let ops = patch as? [[String: Any]] else { return .json(400, Self.status(400, "BadRequest", "a JSON patch is a list of operations")) }
            result = Self.jsonPatch(full, ops)
        } else if contentType.hasPrefix("application/merge-patch+json") || contentType.hasPrefix("application/strategic-merge-patch+json") {
            result = Self.mergePatch(full, patch) as? [String: Any]
        } else {
            return .json(415, Self.status(415, "UnsupportedMediaType", "the body of the request was in an unknown format: \(contentType)"))
        }
        guard let result else {
            return .json(422, Self.status(422, "Invalid", "the server rejected our request due to an error in our request"))
        }
        let metadata = result["metadata"] as? [String: Any] ?? [:]
        let gone = metadata["deletionTimestamp"] != nil && (metadata["finalizers"] as? [String] ?? []).isEmpty
        var answer = Answer.json(200, Data())
        change(gone ? "DELETED" : "MODIFIED") {
            guard var object = objects[key] else { return nil }
            Self.store(result, in: &object)
            answer = .json(200, Self.encode(Self.full(object, kind)))
            return object
        }
        return answer
    }

    /// A server-side apply (`application/apply-patch+yaml`, its body JSON —
    /// which is YAML): `fieldManager` required; the object made when it
    /// isn't there; a `resourceVersion` in the body that isn't the object's
    /// a 409 (the object changed); a field another manager owns set to
    /// another value a 409 naming it (`FieldManagerConflict`), unless
    /// `force=true` — which takes the field from it; else merged (maps
    /// merged, the rest replaced) and the applier made the owner of what it
    /// sent. `dryRun=All` answers the result and keeps nothing.
    private func apply(_ kind: Kind, key: String, namespace: String?, name: String, query: [String: String], body: Data) -> Answer {
        guard let manager = query["fieldManager"], !manager.isEmpty else {
            return .json(422, Self.status(422, "Invalid", "PatchOptions.meta.k8s.io \"\" is invalid: fieldManager: Required value: is required for apply patch"))
        }
        guard kind.verbs.contains("patch") else {
            return .json(405, Self.status(405, "MethodNotAllowed", "the server does not allow this method on the requested resource"))
        }
        guard let patch = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return .json(400, Self.status(400, "BadRequest", "error decoding YAML: the body of the request was in an unknown format"))
        }
        var metadata = patch["metadata"] as? [String: Any] ?? [:]
        guard metadata["name"] as? String == name else {
            return .json(400, Self.status(400, "BadRequest", "the name of the object (\(metadata["name"] ?? "")) does not match the name on the URL (\(name))"))
        }
        let dryRun = query["dryRun"] == "All"
        let force = query["force"] == "true"
        let sentVersion = metadata["resourceVersion"] as? String
        metadata["resourceVersion"] = nil
        var sent = patch
        sent["metadata"] = metadata
        let own: [String: Any] = ["manager": manager, "operation": "Apply", "apiVersion": kind.groupVersion, "time": Self.time(Date()), "fieldsType": "FieldsV1", "fieldsV1": Self.fieldsV1(sent)]
        guard let existing = locked({ objects[key] }) else {
            if sentVersion != nil { return .json(404, Self.status(404, "NotFound", "\(kind.resource) \"\(name)\" not found")) }
            if dryRun {
                var made = sent
                var madeMetadata = metadata
                madeMetadata["uid"] = UUID().uuidString.lowercased()
                madeMetadata["creationTimestamp"] = Self.time(Date())
                madeMetadata["managedFields"] = [own]
                if let namespace { madeMetadata["namespace"] = namespace }
                made["metadata"] = madeMetadata
                return .json(201, Self.encode(made))
            }
            let answer = create(kind, namespace: namespace, Self.encode(sent))
            locked { objects[key]?.managedFields = Self.encode([own]) }
            if let made = locked({ objects[key] }) { return .json(201, Self.encode(Self.full(made, kind))) }
            return answer
        }
        if let sentVersion, sentVersion != String(existing.resourceVersion) {
            return .json(
                409,
                Self.status(
                    409, "Conflict",
                    "Operation cannot be fulfilled on \(kind.fullName) \"\(name)\": the object has been modified; please apply your changes to the latest version and try again"
                ))
        }
        let full = Self.full(existing, kind)
        var managers = ((full["metadata"] as? [String: Any])?["managedFields"] as? [[String: Any]]) ?? []
        var conflicts: [(manager: String, field: String)] = []
        for (index, entry) in managers.enumerated() {
            guard let other = entry["manager"] as? String, other != manager, let fields = entry["fieldsV1"] as? [String: Any] else { continue }
            var owned = Self.ownedPaths(fields)
            let taken = owned.filter { path in
                guard let wanted = Self.value(at: path, in: sent) else { return false }
                return !(wanted as AnyObject).isEqual(Self.value(at: path, in: full) as AnyObject?)
            }
            for path in taken { conflicts.append((other, "." + path.joined(separator: "."))) }
            if force, !taken.isEmpty {
                owned.removeAll { taken.contains($0) }
                managers[index]["fieldsV1"] = Self.fieldsV1(paths: owned)
            }
        }
        if !conflicts.isEmpty, !force {
            let said = conflicts.map { "conflict with \"\($0.manager)\" using \(kind.groupVersion): \($0.field)" }
            var status = Self.statusObject(409, "Conflict", "Apply failed with \(conflicts.count) conflict\(conflicts.count == 1 ? "" : "s"): " + said.joined(separator: "\n"))
            status["details"] = [
                "name": name, "kind": kind.resource,
                "causes": conflicts.map { ["reason": "FieldManagerConflict", "message": "conflict with \"\($0.manager)\" using \(kind.groupVersion)", "field": $0.field] },
            ]
            return .raw(409, Self.encode(status), [("Content-Type", "application/json")])
        }
        managers.removeAll { $0["manager"] as? String == manager }
        managers.append(own)
        var result = (Self.mergePatch(full, sent) as? [String: Any]) ?? full
        if var merged = result["metadata"] as? [String: Any] {
            merged["managedFields"] = managers
            result["metadata"] = merged
        }
        if existing.resource == "secrets", let plain = result["stringData"] as? [String: Any] {
            var data = result["data"] as? [String: Any] ?? [:]
            for (field, value) in plain { data[field] = Data("\(value)".utf8).base64EncodedString() }
            result["data"] = data
            result["stringData"] = nil
        }
        if dryRun { return .json(200, Self.encode(result)) }
        var answer = Answer.json(200, Data())
        let kept = managers
        change("MODIFIED") {
            guard var object = objects[key] else { return nil }
            Self.store(result, in: &object)
            object.managedFields = Self.encode(kept)
            if object.resource == "secrets" {
                object.data = (result["data"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? String).flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) } }
            } else if object.resource == "configmaps" {
                object.data = (result["data"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            }
            if let replicas = ((result["spec"] as? [String: Any])?["replicas"] as? NSNumber)?.intValue, object.values["Ready"] != nil {
                object.values["Ready"] = .text("\(replicas)/\(replicas)")
                for cell in ["Up-to-date", "Available"] where object.values[cell] != nil { object.values[cell] = .integer(replicas) }
            }
            answer = .json(200, Self.encode(Self.full(object, kind)))
            return object
        }
        return answer
    }

    /// What an apply's body owns, as managedFields says it: a map's keys
    /// `f:`, anything else a leaf.
    static func fieldsV1(_ value: Any) -> [String: Any] {
        guard let map = value as? [String: Any] else { return [:] }
        var out: [String: Any] = [:]
        for (key, inner) in map where !["apiVersion", "kind"].contains(key) {
            if key == "metadata", let metadata = inner as? [String: Any] {
                let kept = metadata.filter { !["name", "namespace", "resourceVersion", "uid", "creationTimestamp", "managedFields"].contains($0.key) }
                if !kept.isEmpty { out["f:metadata"] = fieldsV1(kept) }
                continue
            }
            if let nested = inner as? [String: Any], !nested.isEmpty { out["f:" + key] = fieldsV1(nested) } else { out["f:" + key] = [String: Any]() }
        }
        return out
    }

    /// `fieldsV1`'s owned paths, each a list of keys: a list's items
    /// (`k:`, `v:`, `i:`) the list's own path, `.` the node's.
    static func ownedPaths(_ fields: [String: Any], _ path: [String] = []) -> [[String]] {
        var out: [[String]] = []
        for (key, inner) in fields {
            if key.hasPrefix("f:") {
                let next = path + [String(key.dropFirst(2))]
                let nested = inner as? [String: Any] ?? [:]
                if nested.isEmpty || nested.keys.contains(where: { $0.hasPrefix("k:") || $0.hasPrefix("v:") || $0.hasPrefix("i:") }) {
                    out.append(next)
                } else {
                    out += ownedPaths(nested.filter { $0.key != "." }, next)
                }
            }
        }
        return out
    }

    /// Paths as fieldsV1 again.
    static func fieldsV1(paths: [[String]]) -> [String: Any] {
        var out: [String: Any] = [:]
        for path in paths {
            guard let first = path.first else { continue }
            let rest = Array(path.dropFirst())
            var inner = out["f:" + first] as? [String: Any] ?? [:]
            if !rest.isEmpty { inner = (mergePatch(inner, fieldsV1(paths: [rest])) as? [String: Any]) ?? inner }
            out["f:" + first] = inner
        }
        return out
    }

    /// The `scale` subresource's PATCH: the replicas set, the rollout done at once.
    private func patchScale(_ key: String, _ kind: Kind, _ body: Data) -> Answer {
        let patch = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        guard let replicas = ((patch["spec"] as? [String: Any])?["replicas"] as? NSNumber)?.intValue, replicas >= 0 else {
            return .json(422, Self.status(422, "Invalid", "Scale.autoscaling \"\" is invalid: spec.replicas: Invalid value: must be greater than or equal to 0"))
        }
        var answer = Answer.json(200, Data())
        change("MODIFIED") {
            guard var object = objects[key] else { return nil }
            var full = Self.full(object, kind)
            var spec = full["spec"] as? [String: Any] ?? [:]
            spec["replicas"] = replicas
            full["spec"] = spec
            var status = full["status"] as? [String: Any] ?? [:]
            for field in ["replicas", "readyReplicas", "availableReplicas", "updatedReplicas"] { status[field] = replicas }
            full["status"] = status
            Self.store(full, in: &object)
            if object.values["Ready"] != nil { object.values["Ready"] = .text("\(replicas)/\(replicas)") }
            for cell in ["Up-to-date", "Available", "Current", "Desired"] where object.values[cell] != nil { object.values[cell] = .integer(replicas) }
            answer = .json(200, Self.encode(Self.scale(of: object, kind)))
            return object
        }
        return answer
    }

    /// A pod's `resize` subresource's PATCH (a strategic merge patch): each
    /// container named gets the requests and limits sent, merged into its
    /// own; only cpu and memory, and only regular containers, as the API
    /// server allows — anything else 422, and so is a change of the pod's
    /// QoS class (`ValidatePodResize`). Applied at once (no kubelet).
    private func patchResize(_ key: String, _ kind: Kind, _ body: Data, _ contentType: String) -> Answer {
        guard contentType.hasPrefix("application/strategic-merge-patch+json") || contentType.hasPrefix("application/merge-patch+json") else {
            return .json(415, Self.status(415, "UnsupportedMediaType", "the body of the request was in an unknown format: \(contentType)"))
        }
        let patch = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let spec = patch["spec"] as? [String: Any] ?? [:]
        let invalid = Answer.json(422, Self.status(422, "Invalid", "Pod \"\" is invalid: spec: Forbidden: only cpu and memory resources are mutable"))
        guard spec.keys.allSatisfy({ $0 == "containers" }), let containers = spec["containers"] as? [[String: Any]] else { return invalid }
        var answer = Answer.json(200, Data())
        var refused: Answer?
        change("MODIFIED") {
            guard var object = objects[key], var pod = object.pod else { return nil }
            let before = KubeResize.qos(Self.resources(pod))
            for container in containers {
                guard let name = container["name"] as? String, pod.containerNames.contains(name),
                    container.keys.allSatisfy({ ["name", "resources"].contains($0) })
                else {
                    refused = invalid
                    return nil
                }
                let resources = container["resources"] as? [String: Any] ?? [:]
                for (group, values) in resources {
                    guard ["requests", "limits"].contains(group), let values = values as? [String: Any],
                        values.keys.allSatisfy({ ["cpu", "memory"].contains($0) })
                    else {
                        refused = invalid
                        return nil
                    }
                    for (resource, value) in values {
                        pod.resources[name, default: [:]][group, default: [:]][resource] = "\(value)"
                    }
                }
            }
            let after = KubeResize.qos(Self.resources(pod))
            guard after == before else {
                refused = .json(
                    422,
                    Self.status(
                        422, "Invalid", "Pod \"\(object.name)\" is invalid: spec: Invalid value: \"\(after.rawValue)\": Pod QOS Class may not change as a result of resizing"
                    ))
                return nil
            }
            object.pod = pod
            answer = .json(200, Self.encode(Self.full(object, kind)))
            return object
        }
        return refused ?? answer
    }

    /// A pod's containers' (regular and init) requests and limits, as its
    /// QoS class reads them.
    private static func resources(_ pod: Pod) -> [KubeContainerResources] {
        (pod.containerNames + pod.initContainers).map { name in
            let values = pod.resources[name] ?? [:]
            return KubeContainerResources(
                name: name, cpuRequest: values["requests"]?["cpu"], cpuLimit: values["limits"]?["cpu"], memoryRequest: values["requests"]?["memory"],
                memoryLimit: values["limits"]?["memory"])
        }
    }

    /// Whether pods' `resize` subresource is served (Kubernetes 1.33 and
    /// later); off, an older server: discovery lists none, its PATCH 404s.
    var servesResize: Bool {
        get { locked { kinds.first { $0.group.isEmpty && $0.resource == "pods" }?.subresources.contains("resize") ?? false } }
        set {
            locked {
                guard let index = kinds.firstIndex(where: { $0.group.isEmpty && $0.resource == "pods" }) else { return }
                kinds[index].subresources.removeAll { $0 == "resize" }
                if newValue { kinds[index].subresources.append("resize"); kinds[index].subresources.sort() }
            }
        }
    }

    /// A pod's eviction: refused while `evictionBlock` says a
    /// PodDisruptionBudget allows none, else the pod deleted.
    private func evict(_ key: String, _ kind: Kind) -> Answer {
        if let block = locked({ settings.evictionBlock }) {
            var status = Self.statusObject(429, "TooManyRequests", "Cannot evict pod as it would violate the pod's disruption budget.")
            status["details"] = ["causes": [["reason": "DisruptionBudget", "message": block]]]
            return .raw(429, Self.encode(status), [("Content-Type", "application/json")])
        }
        var podName: (String, String)?
        change("DELETED") {
            guard let object = objects[key] else { return nil }
            podName = (object.name, object.namespace ?? "")
            return object
        }
        if let (name, namespace) = podName { endLogStreams(of: name, namespace: namespace) }
        var success = Self.statusObject(201, "", "")
        success["status"] = "Success"
        return .json(201, Self.encode(success))
    }

    /// A Scale, as the subresource answers it.
    static func scale(of object: Object, _ kind: Kind) -> [String: Any] {
        let full = full(object, kind)
        let replicas = ((full["spec"] as? [String: Any])?["replicas"] as? NSNumber)?.intValue ?? 1
        let current = ((full["status"] as? [String: Any])?["replicas"] as? NSNumber)?.intValue ?? replicas
        var metadata: [String: Any] = ["name": object.name, "uid": object.uid, "resourceVersion": String(object.resourceVersion)]
        if let namespace = object.namespace { metadata["namespace"] = namespace }
        return ["kind": "Scale", "apiVersion": "autoscaling/v1", "metadata": metadata, "spec": ["replicas": replicas], "status": ["replicas": current]]
    }

    /// The object as a GET would now answer it, kept: labels and
    /// annotations as its own, the rest of its metadata and — for a kind
    /// the fake doesn't make from values (not a pod, Secret, ConfigMap or
    /// Namespace) — its spec and status as its fields.
    private static func store(_ full: [String: Any], in object: inout Object) {
        var metadata = full["metadata"] as? [String: Any] ?? [:]
        object.labels = metadata["labels"] as? [String: String] ?? [:]
        object.annotations = metadata["annotations"] as? [String: String] ?? [:]
        for generated in ["name", "namespace", "uid", "resourceVersion", "creationTimestamp", "managedFields", "labels", "annotations"] {
            metadata[generated] = nil
        }
        let made = object.pod != nil || ["secrets", "configmaps", "namespaces"].contains(object.resource)
        var fields = (object.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        if !made {
            for (key, value) in full where !["kind", "apiVersion", "metadata"].contains(key) { fields[key] = value }
        }
        fields["metadata"] = metadata
        object.body = encode(fields)
    }

    /// RFC 7386: maps merged, `null` removing a key, anything else replaced.
    static func mergePatch(_ target: Any?, _ patch: Any) -> Any {
        guard let patch = patch as? [String: Any] else { return patch }
        var result = target as? [String: Any] ?? [:]
        for (key, value) in patch {
            if value is NSNull { result[key] = nil } else { result[key] = mergePatch(result[key], value) }
        }
        return result
    }

    /// RFC 6902's `test`, `remove`, `add` and `replace`; nil when one fails.
    static func jsonPatch(_ document: [String: Any], _ operations: [[String: Any]]) -> [String: Any]? {
        var document: Any = document
        for operation in operations {
            guard let op = operation["op"] as? String, let pointer = operation["path"] as? String, pointer.hasPrefix("/") else { return nil }
            let path = pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
                $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            }
            switch op {
            case "test":
                guard let found = value(at: path, in: document), let expected = operation["value"], (found as AnyObject).isEqual(expected) else { return nil }
            case "remove":
                guard let changed = changing(document, at: path, to: nil, mustExist: true) else { return nil }
                document = changed
            case "add", "replace":
                guard let new = operation["value"], let changed = changing(document, at: path, to: new, mustExist: op == "replace") else { return nil }
                document = changed
            default: return nil
            }
        }
        return document as? [String: Any]
    }

    private static func value(at path: [String], in document: Any) -> Any? {
        guard let first = path.first else { return document }
        if let map = document as? [String: Any] { return map[first].flatMap { value(at: Array(path.dropFirst()), in: $0) } }
        if let list = document as? [Any], let index = Int(first), list.indices.contains(index) { return value(at: Array(path.dropFirst()), in: list[index]) }
        return nil
    }

    /// `document` with the value at `path` set (`new`) or removed (nil).
    private static func changing(_ document: Any, at path: [String], to new: Any?, mustExist: Bool) -> Any? {
        guard let first = path.first else { return new }
        let rest = Array(path.dropFirst())
        if var map = document as? [String: Any] {
            if rest.isEmpty {
                if mustExist && map[first] == nil { return nil }
                map[first] = new
                return map
            }
            guard let inner = map[first], let changed = changing(inner, at: rest, to: new, mustExist: mustExist) else { return nil }
            map[first] = changed
            return map
        }
        if var list = document as? [Any], let index = Int(first) {
            if rest.isEmpty {
                guard list.indices.contains(index) || (!mustExist && index == list.count) else { return nil }
                if let new { if index == list.count { list.append(new) } else { list[index] = new } } else { list.remove(at: index) }
                return list
            }
            guard list.indices.contains(index), let changed = changing(list[index], at: rest, to: new, mustExist: mustExist) else { return nil }
            list[index] = changed
            return list
        }
        return nil
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
    private var body = Data()
    private var timeout: Scheduled<Void>?
    /// The path of the answer held now (`answerSlowly`); its event loop's.
    private var held: String?

    init(api: FakeKubeAPI) {
        self.api = api
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body = Data()
        case .body(let buffer): body.append(contentsOf: buffer.readableBytesView)
        case .end:
            guard let head else { return }
            respond(context, head)
        }
    }

    private func respond(_ context: ChannelHandlerContext, _ request: HTTPRequestHead) {
        let channel = context.channel
        let answer = api.answer(
            request.method, request.uri, accept: request.headers["Accept"].joined(separator: ", "), body: body,
            contentType: request.headers["Content-Type"].first ?? "", on: channel)
        func whole(_ status: Int, _ data: Data, _ headers: [(String, String)]) {
            let path = URLComponents(string: "http://localhost" + request.uri)?.percentEncodedPath ?? request.uri
            if let delay = api.slowness(path) {
                held = path
                api.holding(1)
                channel.eventLoop.scheduleTask(in: .milliseconds(Int64(delay))) {
                    // Closed by its client meanwhile: said so then (`channelInactive`).
                    guard self.held != nil else { return }
                    self.held = nil
                    self.api.holding(-1)
                    Self.send(channel, request.version, status, data, headers)
                }
                return
            }
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
        case .log(let lines):
            var head = HTTPResponseHead(version: request.version, status: .ok, headers: HTTPHeaders([("Content-Type", "text/plain")]))
            head.headers.add(name: "Transfer-Encoding", value: "chunked")
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            for line in lines { context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: line)))), promise: nil) }
            context.flush()
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

    /// A held answer, written on the channel itself: the handler's context
    /// may be gone by then.
    private static func send(_ channel: Channel, _ version: HTTPVersion, _ status: Int, _ data: Data, _ headers: [(String, String)]) {
        var head = HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: status), headers: HTTPHeaders(headers))
        head.headers.add(name: "Content-Length", value: "\(data.count)")
        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        if !data.isEmpty { channel.write(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: data))), promise: nil) }
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let held {
            self.held = nil
            api.holding(-1, dropped: held)
        }
        timeout?.cancel()
        api.forget(context.channel)
    }
}
