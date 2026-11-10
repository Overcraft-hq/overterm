import AppKit
import Foundation

/// Kubernetes' MCP tools (docs/design/kubernetes/analysis.md, 3.5; stage
/// 1e), beside the browser's, the API client's, the notes', the databases'
/// and Docker's on the same server (BrowserBridge), turned on by
/// `kubernetes.agentAccess`: an agent lists the contexts, reads a kind's
/// rows as `kubectl get` prints them, describes one object, reads a pod's
/// log and events, a rollout's status and history, and a failing pod's
/// brief (Ask Why's).
///
/// **Reads, and three confirmed writes.** Every request goes through the
/// context's `kubectl proxy` (`KubernetesModel.agentClient`) in a
/// background slot, under the proxies' rules — a stopped context answers
/// its problem and starts nothing, an oidc sign-in waits its turn; no tool
/// starts a process of its own. The reads are GETs. The writes —
/// `k8s_restart`, `k8s_scale`, `k8s_delete_pod` (stage 2a), `k8s_apply` (2b; `KubeAgentWrites`)
/// — are listed while `kubernetes.agentWrites` names a context (an agent
/// started before needs a restart to see them: the list isn't announced
/// again), work only on a context it names that is writable for Overterm
/// (a production one only with its writes on for the session), and each call is asked in the window, the context and
/// namespace in its title, through the page's checks: the class check, the
/// access review, the confirmation (the name typed where rule 4 says), the
/// class check again, then the request. A read-only context's socket
/// refuses writes anyway. **None reads a Secret's values**: a Secret is listed and described from its Table row
/// (name, type, how many keys), never GET whole — its one GET is every
/// value at once (rule 9) — and an env value from one is named, not valued.
///
/// **Where.** A tool works on the context the Kubernetes page has selected
/// and that page's namespace, unless the call names another; with no
/// selection the call must name one — never kubectl's current context,
/// which is often production. A context the kubeconfig doesn't have is an
/// error, never a fallback. A binding — the calling pane's checkout's
/// context and namespace (3.1) — comes before the page's (`defaultContext`).
/// Every answer says the context first, production as such.
///
/// **Scrubbed and bounded.** Every answer goes through `Secrets`: the
/// object's env values that look secret, every URL's password, then what
/// looks like a credential (tokens, keys, a kubeconfig's fields, base64
/// blobs); a log is filtered after it is scrubbed, as Docker's is. Rows,
/// lines, events and characters are bounded.
///
/// `k8s_top` (stage 2d) reads metrics.k8s.io: pods' and nodes' usage.
/// `k8s_metrics` (metrics.md 7, M11) an object's usage over a range, as
/// text, from the charts' own queries (`KubeMCP+Metrics`).
@MainActor
enum KubeMCP {
    static let prefix = "k8s_"
    /// The reads, always offered.
    static let reads: [String] = ["k8s_contexts", "k8s_get", "k8s_describe", "k8s_logs", "k8s_events", "k8s_why", "k8s_rollout", "k8s_top", "k8s_metrics"]
    /// The writes, listed only while `kubernetes.agentWrites` names a context (`KubeAgentWrites`).
    static let writes: [String] = KubeAgentWrites.tools

    /// How long one read may take: an oidc sign-in in the browser, a
    /// cluster that doesn't answer.
    static var readTimeout: Duration = .seconds(30)

    /// What the tools are bounded by.
    static let defaultRows = 100
    static let maxRows = 500
    static let defaultTail = 200
    static let maxTail = 2000
    static let defaultEvents = 50
    static let maxEvents = 200
    /// A namespace's events are read this many to a page, at most
    /// `eventPages` pages, before the newest are picked.
    static var eventsPage = 500
    static var eventPages = 4
    /// A log is read up to this many bytes (`limitBytes`), of which the
    /// last `logKeepBytes` are taken apart.
    static let logReadBytes = 1 << 20
    static let logKeepBytes = 512 << 10

    // MARK: Calls

    /// `pane`: the calling pane's tag — its checkout's binding (3.1) is
    /// the context and namespace a call doesn't name.
    static func call(
        _ name: String, _ arguments: [String: Any], kubernetes: KubernetesModel, pane: String? = nil, now: Date = Date()
    ) async throws -> [String: Any] {
        guard reads.contains(name) || writes.contains(name) else {
            throw BrowserMCP.ToolError(
                message: "Unknown tool: \(name). Agents read Kubernetes here, and restart, scale, delete a pod or apply a manifest where it is writable.")
        }
        let call = Call(name: name, arguments: arguments)
        guard let list = await kubernetes.contextsForAgents() else {
            return BrowserMCP.errorResult("Kubernetes is off in Overterm's settings (Settings ▸ Kubernetes).")
        }
        if name == "k8s_contexts" {
            return BrowserMCP.textResult(await contexts(list, kubernetes: kubernetes, pane: pane))
        }
        let target = try target(call, list: list, kubernetes: kubernetes, pane: pane)
        let text: String
        switch name {
        case "k8s_get": text = try await get(call, target, kubernetes: kubernetes)
        case "k8s_describe": text = try await describe(call, target, kubernetes: kubernetes, now: now)
        case "k8s_logs": text = try await logs(call, target, now: now)
        case "k8s_events": text = try await events(call, target, kubernetes: kubernetes, now: now)
        case "k8s_why": text = try await why(call, target, kubernetes: kubernetes, pane: pane, list: list, now: now)
        case "k8s_rollout": text = try await rollout(call, target, kubernetes: kubernetes, now: now)
        case "k8s_top": text = try await top(call, target, kubernetes: kubernetes, now: now)
        case "k8s_metrics": text = try await metrics(call, target, kubernetes: kubernetes, now: now)
        case "k8s_restart", "k8s_scale", "k8s_delete_pod": text = try await write(call, target, kubernetes: kubernetes, pane: pane)
        case "k8s_apply": text = try await apply(call, target, kubernetes: kubernetes, pane: pane)
        default: throw BrowserMCP.ToolError(message: "Unknown tool: \(name)")
        }
        return BrowserMCP.textResult(text)
    }

    /// One call's arguments, read.
    struct Call {
        let name: String
        let arguments: [String: Any]

        func string(_ key: String) -> String? {
            (arguments[key] as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }

        func bool(_ key: String) -> Bool { arguments[key] as? Bool ?? false }

        func int(_ key: String, default value: Int, in range: ClosedRange<Int>) -> Int {
            // A Double clamped before it is made an Int: `Int(1e300)` traps,
            // and an agent's JSON may hold any number.
            let given =
                (arguments[key] as? Int) ?? (arguments[key] as? Double).flatMap { Self.clamped($0, to: range) }
                ?? (arguments[key] as? String).flatMap { Int($0) }
            return min(max(given ?? value, range.lowerBound), range.upperBound)
        }

        /// `number` towards zero, within `range`: nil when it isn't a number at all (NaN, ±∞).
        static func clamped(_ number: Double, to range: ClosedRange<Int>) -> Int? {
            guard number.isFinite else { return nil }
            return Int(min(max(number.rounded(.towardZero), Double(range.lowerBound)), Double(range.upperBound)))
        }

        func required(_ key: String, _ hint: String) throws -> String {
            guard let value = string(key) else { throw BrowserMCP.ToolError(message: "\(name) needs “\(key)” — \(hint).") }
            return value
        }

        /// An object's name: one path segment, never a path.
        func objectName(_ key: String = "name", _ hint: String) throws -> String {
            let value = try required(key, hint)
            guard KubeMCPText.isName(value) else { throw BrowserMCP.ToolError(message: "“\(value)” isn't an object's name.") }
            return value
        }
    }

    // MARK: Where

    /// The context and namespace a call works on, with its client.
    struct Target {
        let context: KubeContext
        let client: KubeClient
        let scope: KubeScope

        var brief: KubeBriefContext { KubeBriefContext(name: context.name, production: context.isProduction, writable: context.isWritable) }
        /// One namespace, or nil for several or all of them.
        var namespace: String? { if case .namespace(let name) = scope { name } else { nil } }

        /// The first line of every answer.
        func header(_ scope: KubeScope? = nil, kind: KubeResourceKind? = nil) -> String {
            let said = brief.said
            var line = said.prefix(1).uppercased() + String(said.dropFirst())
            let shown = scope ?? self.scope
            if kind?.namespaced != false {
                line += ", " + shown.said
            }
            return line + "."
        }

        /// The one namespace a namespaced object is in.
        func oneNamespace(_ tool: String) throws -> String {
            guard let namespace else {
                throw BrowserMCP.ToolError(message: "\(tool) needs “namespace”: the Kubernetes page shows \(scope.said) of \(context.name).")
            }
            return namespace
        }
    }

    /// The checkout a pane's tab works in — the window answers (nil
    /// outside any window's tabs, and in tests that set none).
    static var paneCheckout: ((String) -> URL?)?
    /// Where bindings are kept (a test's own store).
    static var bindings: KubeBindingStore = .shared

    /// The calling pane's checkout's binding (3.1), when its context is
    /// one the kubeconfig has.
    static func binding(for pane: String?, in list: KubeContextList) -> KubeBinding? {
        guard let pane, let checkout = paneCheckout?(pane), let binding = bindings.binding(for: checkout),
            list.context(named: binding.context) != nil
        else { return nil }
        return binding
    }

    /// The context a call doesn't name: the calling pane's checkout's
    /// binding's, else the page's selected one.
    static func defaultContext(in list: KubeContextList, kubernetes: KubernetesModel, pane: String?) -> String? {
        binding(for: pane, in: list)?.context ?? kubernetes.agentDefaultContext(in: list)
    }

    /// The namespace a call doesn't name, on `context`: the binding's when
    /// the binding is on it, else the page's (`agentDefaultScope`).
    static func defaultScope(for context: KubeContext, list: KubeContextList, kubernetes: KubernetesModel, pane: String?) -> KubeScope {
        if let binding = binding(for: pane, in: list), binding.context == context.name { return .namespace(binding.namespace) }
        return kubernetes.agentDefaultScope(for: context)
    }

    static func target(_ call: Call, list: KubeContextList, kubernetes: KubernetesModel, pane: String?) throws -> Target {
        let names = list.contexts.map(\.name)
        guard !names.isEmpty else {
            throw BrowserMCP.ToolError(message: "The kubeconfig has no context." + (list.problems.isEmpty ? "" : " " + list.problems.joined(separator: " ")))
        }
        let name: String
        if let named = call.string("context") {
            guard list.context(named: named) != nil else {
                throw BrowserMCP.ToolError(message: "No context “\(named)” in the kubeconfig. It has: \(names.joined(separator: ", ")).")
            }
            name = named
        } else {
            guard let chosen = defaultContext(in: list, kubernetes: kubernetes, pane: pane) else {
                throw BrowserMCP.ToolError(message: "Name a “context”: \(names.joined(separator: ", ")).")
            }
            name = chosen
        }
        let context = list.context(named: name)!
        let scope: KubeScope
        if let namespace = call.string("namespace") {
            if ["all", "*", "-A", "--all-namespaces"].contains(namespace) {
                scope = .all
            } else if namespace.contains(",") {
                // `a,b`: several, as the page shows them.
                guard let names = KubePicker.typedNamespaces(namespace), names.allSatisfy(KubeMCPText.isName) else {
                    throw BrowserMCP.ToolError(message: "“\(namespace)” isn't a list of namespaces' names.")
                }
                scope = .of(names)
            } else {
                guard KubeMCPText.isName(namespace) else { throw BrowserMCP.ToolError(message: "“\(namespace)” isn't a namespace's name.") }
                scope = .namespace(namespace)
            }
        } else {
            scope = defaultScope(for: context, list: list, kubernetes: kubernetes, pane: pane)
        }
        return Target(context: context, client: kubernetes.agentClient(for: context), scope: scope)
    }

    // MARK: Discovery

    /// What each context serves, as the tools read it: kept a few minutes,
    /// for the same cluster and user only.
    private static var discoveries: [String: (key: String, discovery: KubeDiscovery, read: Date)] = [:]

    /// What the tools read is forgotten (a test's next fake server).
    static func forgetDiscoveries() { discoveries = [:] }

    /// Which cluster, as which user: what a kept discovery holds for.
    private static func key(_ context: KubeContext) -> String {
        [context.server ?? "", context.cluster, context.user].joined(separator: "\u{0}")
    }

    /// What is known of the target's cluster without asking it: the page's
    /// (only while its reading of the name is the same cluster), else what
    /// a tool read lately for the same cluster and user.
    private static func known(for target: Target, kubernetes: KubernetesModel) -> KubeDiscovery? {
        if let known = kubernetes.knownDiscovery(of: target.context) { return known }
        guard let kept = discoveries[target.context.name], kept.key == key(target.context), Date().timeIntervalSince(kept.read) < 300 else {
            return nil
        }
        return kept.discovery
    }

    static func discovery(for target: Target, kubernetes: KubernetesModel) async throws -> KubeDiscovery {
        if let known = known(for: target, kubernetes: kubernetes) { return known }
        let client = target.client
        let read = try await within { try await client.discover() }
        discoveries[target.context.name] = (key(target.context), read, Date())
        return read
    }

    private static func kind(_ call: Call, _ target: Target, kubernetes: KubernetesModel, default fallback: String? = nil) async throws -> KubeResourceKind {
        guard let wanted = call.string("kind") ?? fallback else {
            throw BrowserMCP.ToolError(message: "\(call.name) needs “kind” — pods, deploy, svc, a CRD's plural…")
        }
        let discovery = try await discovery(for: target, kubernetes: kubernetes)
        guard let kind = KubeKinds.resolve(wanted, in: discovery) else {
            throw BrowserMCP.ToolError(message: "\(target.context.name) serves no kind “\(wanted)”.")
        }
        return kind
    }

    // MARK: Reads

    /// One read, or an error once `readTimeout` has passed.
    static func within<T: Sendable>(_ read: @escaping @Sendable () async throws -> T) async throws -> T {
        do {
            return try await KubeBriefRace.run(limit: readTimeout, read)
        } catch is KubeBriefTimeout {
            throw BrowserMCP.ToolError(message: "The cluster didn't answer in \(readTimeout) (a sign-in in the browser may be waiting).")
        }
    }

    /// A read's failure, said scrubbed.
    static func said(_ error: Error) -> String {
        if let tool = error as? BrowserMCP.ToolError { return tool.message }
        return KubeMCPText.scrubbed(KubernetesModel.said(error))
    }

    /// A Secret's Table row: what may be said of it without its values.
    private static func secretRow(_ name: String, kind: KubeResourceKind, _ target: Target, namespace: String) async throws -> (KubeTable, KubeRow?) {
        let path = KubePath.query(
            kind.path(namespace: namespace), [("fieldSelector", "metadata.name=\(name)"), ("limit", "1"), ("includeObject", "None")])
        let client = target.client
        let body = try await within { try await client.get(path, accept: KubeClient.tableAccept).body }
        let table = try KubeTableReader.read(body, namespace: namespace)
        return (table, table.rows.first)
    }

    // MARK: k8s_contexts

    static func contexts(_ list: KubeContextList, kubernetes: KubernetesModel, pane: String?) async -> String {
        guard !list.contexts.isEmpty else {
            return "The kubeconfig has no context." + (list.problems.isEmpty ? "" : " " + list.problems.joined(separator: " "))
        }
        let chosen = defaultContext(in: list, kubernetes: kubernetes, pane: pane)
        var rows: [KubeMCPText.ContextRow] = []
        for context in list.contexts {
            let status = await kubernetes.agentProxyStatus(of: context.name)
            let namespace: String =
                switch defaultScope(for: context, list: list, kubernetes: kubernetes, pane: pane) {
                case .all: "all namespaces"
                case .namespace(let name): name
                case .namespaces(let names): names.sorted().joined(separator: ", ")
                }
            rows.append(
                KubeMCPText.ContextRow(
                    name: context.name, displayName: context.settings.displayName, contextClass: context.contextClass, writable: context.isWritable,
                    namespace: namespace, isDefault: context.name == chosen, isCurrent: context.name == list.current, problem: status.reason,
                    agentsWrite: KubeAgentWrites.refused(context, agentWrites: kubernetes.agentWrites) == nil))
        }
        return KubeMCPText.contexts(rows)
    }

    // MARK: k8s_get

    static func get(_ call: Call, _ target: Target, kubernetes: KubernetesModel) async throws -> String {
        let kind = try await kind(call, target, kubernetes: kubernetes)
        guard kind.canList else { throw BrowserMCP.ToolError(message: "\(kind.fullName) can't be listed.") }
        let name = call.string("name")
        if let name, !KubeMCPText.isName(name) { throw BrowserMCP.ToolError(message: "“\(name)” isn't an object's name.") }
        let limit = call.int("limit", default: defaultRows, in: 1...maxRows)
        let scope: KubeScope = kind.namespaced ? target.scope : .all
        let namespace = scope.namespace(for: kind)
        let fields = [call.string("field_selector"), name.map { "metadata.name=\($0)" }].compactMap { $0 }
        let labels = call.string("label_selector")
        let client = target.client
        let table: KubeTable
        if kind.namespaced, case .namespaces(let names) = scope {
            // The page's several namespaces: one at a time, up to the limit.
            table = try await inNamespaces(names.sorted(), target, kind: kind, limit: limit, labels: labels, fields: fields)
        } else if KubeMCPText.isSecret(kind) && namespace == nil {
            table = try await secretsAcrossNamespaces(target, kind: kind, limit: limit, labels: labels, fields: fields)
        } else {
            let path = KubePath.query(
                kind.path(namespace: namespace),
                [
                    ("limit", String(limit)), ("labelSelector", labels), ("fieldSelector", fields.isEmpty ? nil : fields.joined(separator: ",")),
                    ("includeObject", KubeClient.includeObject(kind, scope)),
                ])
            let body = try await within { try await client.get(path, accept: KubeClient.tableAccept).body }
            table = try KubeTableReader.read(body, namespace: namespace, kind: kind)
        }
        var lines = [target.header(scope, kind: kind)]
        lines.append(
            KubeMCPText.table(
                table, kind: kind, allNamespaces: kind.namespaced && namespace == nil, wide: call.bool("wide"), filter: call.string("filter"),
                selectors: [call.string("label_selector"), call.string("field_selector")].compactMap { $0 }, name: name))
        if KubeMCPText.isSecret(kind) {
            lines.append("A Secret's keys and values are never read for an agent; the user can Show one on the Kubernetes page.")
        }
        return KubeMCPText.finished(lines.joined(separator: "\n"))
    }

    /// How many namespaces an all-namespace Secret list goes through.
    static var secretNamespaces = 100

    /// Secrets across namespaces, one namespace at a time: a list across
    /// all of them carries each row's metadata (`includeObject=Metadata`,
    /// where its namespace is), and a Secret's metadata is its
    /// last-applied annotation — its data, for an applied one. In one
    /// namespace the rows carry nothing but their cells
    /// (`includeObject=None`); the namespace is the one asked.
    private static func secretsAcrossNamespaces(
        _ target: Target, kind: KubeResourceKind, limit: Int, labels: String?, fields: [String]
    ) async throws -> KubeTable {
        let client = target.client
        let listed: KubeTable
        do {
            listed = try await within { try await client.list(.namespaces, in: .all) }
        } catch let error as KubeAPIError where error.isForbidden {
            throw BrowserMCP.ToolError(
                message: "Secrets are listed for an agent one namespace at a time, and \(target.context.name) doesn't list its namespaces: name a “namespace”.")
        }
        let names = listed.rows.map(\.id.name).sorted()
        var table = try await inNamespaces(Array(names.prefix(secretNamespaces)), target, kind: kind, limit: limit, labels: labels, fields: fields)
        if names.count > secretNamespaces { table.continueToken = "" }
        return table
    }

    /// A kind's rows in `names`, one namespace at a time (rows only:
    /// `includeObject=None`, the namespace the one asked), up to `limit`;
    /// a namespace that refuses is left out. Cut short, the table says so
    /// (a `continue`).
    private static func inNamespaces(
        _ names: [String], _ target: Target, kind: KubeResourceKind, limit: Int, labels: String?, fields: [String]
    ) async throws -> KubeTable {
        let client = target.client
        var columns: [KubeColumn] = []
        var rows: [KubeRow] = []
        var more = false
        for namespace in names {
            guard rows.count < limit else {
                more = true
                break
            }
            let path = KubePath.query(
                kind.path(namespace: namespace),
                [
                    ("limit", String(limit - rows.count)), ("labelSelector", labels), ("fieldSelector", fields.isEmpty ? nil : fields.joined(separator: ",")),
                    ("includeObject", "None"),
                ])
            let table: KubeTable
            do {
                let body = try await within { try await client.get(path, accept: KubeClient.tableAccept).body }
                table = try KubeTableReader.read(body, namespace: namespace, kind: kind)
            } catch let error as KubeAPIError where error.isForbidden {
                continue  // Not this namespace's: the others' still.
            }
            if columns.isEmpty { columns = table.columns }
            rows += table.rows
            if table.continueToken != nil { more = true }
        }
        return KubeTable(columns: columns, rows: rows, continueToken: more ? "" : nil)
    }

    // MARK: k8s_describe

    static func describe(_ call: Call, _ target: Target, kubernetes: KubernetesModel, now: Date) async throws -> String {
        let kind = try await kind(call, target, kubernetes: kubernetes)
        let name = try call.objectName("name", "the object's name, from k8s_get")
        let namespace = try kind.namespaced ? target.oneNamespace(call.name) : nil
        let client = target.client
        let what = "\(kind.singular.isEmpty ? kind.resource : kind.singular) \(namespace.map { "\($0)/" } ?? "")\(name)"
        var lines = [target.header(kind: kind)]

        if KubeMCPText.isSecret(kind), let namespace {
            // Never its object: one GET is every value. Its row, its events.
            let (table, row) = try await secretRow(name, kind: kind, target, namespace: namespace)
            guard let row else { throw BrowserMCP.ToolError(message: "No \(what).") }
            lines.append(KubeMCPText.secret(row, columns: table.columns, namespace: namespace))
            if let events = try? await within({ try await client.events(kind: "Secret", name: name, namespace: namespace, uid: nil) }) {
                lines.append(KubeAgentText.events(events, about: "secret/\(name)", now: now) ?? "No events.")
            }
            return KubeMCPText.finished(lines.joined(separator: "\n"))
        }

        let object = try await within { try await client.object(kind, namespace: namespace, name: name) }
        let json = object.json
        guard !KubeObjectStrip.isSecret(json) else { throw BrowserMCP.ToolError(message: "A Secret is never read for an agent.") }
        let scrub = scrubber(for: json)
        // What the YAML tab would show: managed fields and the last-applied
        // annotation out, env values that look secret masked.
        let overview = KubeOverview.of(KubeObjectStrip.shown(json, full: false), now: now)
        lines.append(KubeMCPText.overview(overview, title: "\(object.kind) \(object.namespace.map { "\($0)/" } ?? "")\(object.name)"))

        if let pods = overview.pods {
            let options = KubeListOptions(labelSelector: pods.selector)
            if let table = try? await within({ try await client.list(.pods, in: .namespace(pods.namespace), options: options) }) {
                lines.append(KubeMCPText.pods(table, selector: pods.selector))
            }
        }
        do {
            let events = try await within { try await client.events(kind: object.kind, name: object.name, namespace: object.namespace, uid: object.uid) }
            lines.append(KubeAgentText.events(events, about: "\(object.kind.lowercased())/\(object.name)", now: now) ?? "No events.")
        } catch {
            lines.append("Its events couldn't be read: \(said(error))")
        }
        return KubeMCPText.finished(scrub(lines.joined(separator: "\n")))
    }

    /// What an object's text goes through: its own and its template's env
    /// values that look secret (but the names the answer says anyway),
    /// every URL's password, then credentials and blobs.
    private static func scrubber(for json: [String: Any]) -> (String) -> String {
        let template = KubeAgentText.map(KubeAgentText.map(json["spec"])["template"])
        let env = KubeLogScrub.env(of: json) + KubeLogScrub.env(of: template)
        return KubeAgentBriefing.scrubber(env: env, names: KubeAgentText.names(of: json))
    }

    // MARK: k8s_logs

    static func logs(_ call: Call, _ target: Target, now: Date) async throws -> String {
        let pod = try call.objectName("pod", "its name, from k8s_get pods")
        let namespace = try target.oneNamespace(call.name)
        let client = target.client
        let object = try await within { try await client.object(.pods, namespace: namespace, name: pod) }
        let json = object.json
        let containers = KubePodContainers.of(json).map(\.name)
        guard let container = call.string("container") ?? KubePodContainers.defaultContainer(json) else {
            throw BrowserMCP.ToolError(message: "pod/\(pod) has no container.")
        }
        guard containers.contains(container) else {
            throw BrowserMCP.ToolError(message: "pod/\(pod) has no container “\(container)”. It has: \(containers.joined(separator: ", ")).")
        }
        let tail = call.int("tail", default: defaultTail, in: 1...maxTail)
        let previous = call.bool("previous")
        var query = KubeLogQuery(container: container, previous: previous, tailLines: tail, limitBytes: logReadBytes)
        var sinceSaid: String?
        if let since = call.string("since") {
            guard let seconds = KubeMCPText.seconds(since) else {
                throw BrowserMCP.ToolError(message: "“since” is a duration — 30s, 10m, 2h, 1d.")
            }
            query.sinceTime = KubeMCPText.rfc3339(now.addingTimeInterval(-Double(seconds)))
            sinceSaid = since
        }
        let read = try await within { [query] in try await client.logTail(namespace: namespace, pod: pod, query: query, keep: logKeepBytes) }
        let scrub = KubeAgentBriefing.scrubber(env: KubeLogScrub.env(of: json), names: KubeAgentText.names(of: json))
        // Scrubbed before `grep` looks: matched against the raw text, it
        // would say whether a secret starts with "a", "ab"… a character at a time.
        let grep = call.string("grep")
        let lines = read.lines.map { scrub(KubeAgentText.bounded($0.plain)) }.filter { grep == nil || $0.localizedCaseInsensitiveContains(grep!) }
        var head = "Log of pod \(namespace)/\(pod), container \(container)"
        if previous { head += ", its previous instance" }
        head += ": the last \(tail) lines"
        if let sinceSaid { head += " of the last \(sinceSaid)" }
        if let grep { head += ", those with “\(KubeMCPText.scrubbed(grep))”" }
        var text = [target.header(), head + ":"].joined(separator: "\n") + "\n"
        text += lines.isEmpty ? "(no lines)" : lines.suffix(tail).joined(separator: "\n")
        if read.stopped { text += "\n… the server stopped at \(logReadBytes >> 10) KB: ask for fewer lines (tail) for the newest." }
        return KubeMCPText.bounded(text, keepEnd: true)
    }

    // MARK: k8s_events

    static func events(_ call: Call, _ target: Target, kubernetes: KubernetesModel, now: Date) async throws -> String {
        let limit = call.int("limit", default: defaultEvents, in: 1...maxEvents)
        let warnings = call.bool("warnings_only")
        let client = target.client
        if let name = call.string("name") {
            guard KubeMCPText.isName(name) else { throw BrowserMCP.ToolError(message: "“\(name)” isn't an object's name.") }
            let kind = try await kind(call, target, kubernetes: kubernetes, default: "pods")
            let namespace = try kind.namespaced ? target.oneNamespace(call.name) : nil
            var events = try await within { try await client.events(kind: kind.kind, name: name, namespace: namespace, uid: nil) }
            if warnings { events = events.filter(\.isWarning) }
            let about = "\(kind.kind.lowercased())/\(name)"
            let text = KubeMCPText.events(events.map { ($0, about) }, limit: limit, now: now, empty: "No \(warnings ? "warnings" : "events") about \(about).")
            return KubeMCPText.finished([target.header(kind: kind), text].joined(separator: "\n"))
        }
        // Several namespaces: their events a list each.
        let bases = (target.scope.names.map { $0.map(Optional.some) } ?? [nil]).map { (namespace: String?) in
            namespace.map { "/api/v1/namespaces/\(KubePath.segment($0))/events" } ?? "/api/v1/events"
        }
        // The server lists events in its keys' order, not by time: every
        // page (up to a bound) is read before the newest are picked, and a
        // list cut there says so.
        var raw: [[String: Any]] = []
        var token: String?
        var cut = false
        for base in bases {
            var pages = 0
            token = nil
            repeat {
                let path = KubePath.query(
                    base, [("fieldSelector", warnings ? "type=Warning" : nil), ("limit", String(eventsPage)), ("continue", token)])
                let body = try await within { try await client.get(path).body }
                raw += KubeAgentBriefing.items(body)
                token = KubeMCPText.continueToken(body)
                pages += 1
            } while token != nil && pages < eventPages
            if token != nil { cut = true }
        }
        token = cut ? "" : nil
        let items = raw.map { item -> (KubeEvent, String) in
            let involved = KubeAgentText.map(item["involvedObject"])
            let kind = (KubeAgentText.string(involved["kind"]) ?? "").lowercased()
            let name = KubeAgentText.string(involved["name"]) ?? "?"
            let namespace = target.namespace == nil ? KubeAgentText.string(involved["namespace"]).map { "\($0) " } ?? "" : ""
            return (KubeEvent(item: item), namespace + (kind.isEmpty ? name : "\(kind)/\(name)"))
        }
        let ordered = KubeEvent.newestFirst(items.map(\.0)).compactMap { event in items.first { $0.0.id == event.id } }
        let place = target.scope.names == nil ? "any namespace" : target.scope.said
        var text = KubeMCPText.events(ordered, limit: limit, now: now, empty: "No \(warnings ? "warnings" : "events") in \(place).")
        if token != nil {
            text +=
                "\n… only the first \(raw.count) events in \(place) were read (the server doesn't list them by time), so newer ones may be missing: narrow it with name (one object's events), warnings_only or a namespace."
        }
        return KubeMCPText.finished([target.header(), text].joined(separator: "\n"))
    }

    // MARK: k8s_why

    static func why(
        _ call: Call, _ target: Target, kubernetes: KubernetesModel, pane: String? = nil, list: KubeContextList = KubeContextList(), now: Date
    ) async throws -> String {
        let name = try call.objectName("name", "a failing pod's or Deployment's name, from k8s_get")
        let namespace = try target.oneNamespace(call.name)
        let wanted = (call.string("kind") ?? "pod").lowercased()
        let kind: KubeResourceKind
        switch wanted {
        case "pod", "pods", "po": kind = .pods
        case "deployment", "deployments", "deploy", "deployments.apps": kind = .deployments
        default: throw BrowserMCP.ToolError(message: "k8s_why is a pod's or a Deployment's: “kind” is pod or deployment.")
        }
        let ref = KubeObjectRef(context: target.context.name, kind: kind, namespace: namespace, name: name)
        let discovery = known(for: target, kubernetes: kubernetes)
        do {
            let read = try await KubeAgentBriefing.read(ref, client: target.client, context: target.brief, discovery: discovery, now: now)
            var brief = read.brief
            // The checkout bound there: the calling pane's, else any (3.2).
            if let bound = bindings.binding(on: target.context.name, namespace: namespace, preferring: binding(for: pane, in: list)) {
                brief = await KubeAgentBriefing.withDeployedCommit(brief, checkout: URL(fileURLWithPath: bound.checkout))
            }
            // Its usage over the last hour, where that is cheap (metrics.md 7): from what the brief read, within `usageLimit`.
            if let usage = await usagePart(for: ref, context: target.context, reads: read.reads, kubernetes: kubernetes, now: now) { brief.parts.append(usage) }
            return KubeMCPText.bounded(KubeMCPText.brief(brief))
        } catch let problem as KubeBriefProblem {
            if case .notFailing(let why) = problem { return [target.header(), why].joined(separator: "\n") }
            throw BrowserMCP.ToolError(message: problem.description)
        } catch is KubeBriefTimeout {
            throw BrowserMCP.ToolError(message: "The cluster didn't answer in \(KubeAgentBriefing.readTimeout).")
        }
    }

    // MARK: k8s_rollout

    static func rollout(_ call: Call, _ target: Target, kubernetes: KubernetesModel, now: Date) async throws -> String {
        let name = try call.objectName("name", "the workload's name, from k8s_get")
        let namespace = try target.oneNamespace(call.name)
        let kind = try await kind(call, target, kubernetes: kubernetes, default: "deployments")
        guard kind.group == "apps", ["Deployment", "StatefulSet", "DaemonSet"].contains(kind.kind) else {
            throw BrowserMCP.ToolError(message: "k8s_rollout is a Deployment's, a StatefulSet's or a DaemonSet's.")
        }
        let client = target.client
        let object = try await within { try await client.object(kind, namespace: namespace, name: name) }
        let json = object.json
        let scrub = scrubber(for: json)
        var lines = [target.header(kind: kind)]
        let what = "\(kind.kind.lowercased())/\(name)"
        if let rollout = KubeRollout.of(json) { lines.append(KubeMCPText.rollout(rollout, json, of: what)) }

        let selector = KubeForwardResolve.labelSelector(KubeAgentText.map(json["spec"])["selector"] as? [String: Any])
        let history: (kind: KubeResourceKind?, label: String)
        if kind.kind == "Deployment" {
            history = (.replicaSets, "ReplicaSets")
        } else {
            let discovery = try? await discovery(for: target, kubernetes: kubernetes)
            history = (discovery.flatMap { KubeKinds.resolve("controllerrevisions.apps", in: $0) }, "ControllerRevisions")
        }
        if let historyKind = history.kind, let selector {
            let path = KubePath.query(historyKind.path(namespace: namespace), [("labelSelector", selector), ("limit", "100")])
            do {
                let items = KubeAgentBriefing.items(try await within { try await client.get(path).body })
                let owned = items.filter { KubeMCPText.isOwned($0, by: object.uid, name: object.name, kind: kind.kind) }
                lines.append(
                    KubeMCPText.history(owned, of: json, kind: kind.kind, now: now)
                        ?? "No revisions kept (its \(history.label) carry none, or the list was refused).")
            } catch {
                lines.append("Its history couldn't be read (\(history.label)): \(said(error))")
            }
        } else {
            lines.append("Its history isn't served here (\(history.label)).")
        }
        return KubeMCPText.finished(scrub(lines.joined(separator: "\n")))
    }

    // MARK: Writes (stage 2a)

    /// Answers the confirmation in a test or a scenario: what was typed, nil to refuse.
    static var askOverride: ((KubeWriteConfirmation) -> String?)?

    /// `k8s_restart`, `k8s_scale`, `k8s_delete_pod`: on a context writable
    /// for agents only, through the page's checks — the class check, the
    /// access review, what the confirmation says read (the replicas), the
    /// confirmation in the window, the name typed where rule 4 says, the
    /// checks again against the context as it is now — then one request.
    /// Refused or declined, nothing is sent.
    static func write(_ call: Call, _ target: Target, kubernetes: KubernetesModel, pane: String? = nil) async throws -> String {
        if let refused = KubeAgentWrites.refused(target.context, agentWrites: kubernetes.agentWrites) {
            throw BrowserMCP.ToolError(message: "\(call.name) isn't offered on \(target.context.name): \(refused) Tell the user what to change instead.")
        }
        let namespace = try target.oneNamespace(call.name)
        let verb: KubeWriteVerb
        let kind: KubeResourceKind
        var replicas: Int?
        switch call.name {
        case "k8s_restart":
            verb = .restart
            kind = try await self.kind(call, target, kubernetes: kubernetes, default: "deployments")
        case "k8s_scale":
            verb = .scale
            kind = try await self.kind(call, target, kubernetes: kubernetes, default: "deployments")
            let given =
                (call.arguments["replicas"] as? Int) ?? (call.arguments["replicas"] as? Double).flatMap { Int(exactly: $0) }
                ?? (call.arguments["replicas"] as? String).flatMap { Int($0) }
            guard let given, (0...10_000).contains(given) else {
                throw BrowserMCP.ToolError(message: "k8s_scale needs “replicas”: a whole number, 0 to 10000.")
            }
            replicas = given
        default:
            verb = .delete
            let discovery = try await discovery(for: target, kubernetes: kubernetes)
            guard let pods = KubeKinds.resolve("pods", in: discovery) else { throw BrowserMCP.ToolError(message: "\(target.context.name) serves no pods.") }
            kind = pods
        }
        let name = try call.objectName("name", call.name == "k8s_delete_pod" ? "the pod's name, from k8s_get" : "the workload's name, from k8s_get")
        let ref = KubeObjectRef(context: target.context.name, kind: kind, namespace: namespace, name: name)
        let object = KubeWriteOutcome.spoken(ref)
        let first = KubeWriteCheck.rule(verb, for: target.context, kind: kind)
        if let refused = first.refused { throw BrowserMCP.ToolError(message: refused) }
        let client = target.client
        // The access review first: nothing is read or asked before it says yes.
        if let access = first.access {
            let answer = try await within { await client.review(access, namespace: namespace) }
            if let why = KubeAccessState.answered(answer).unavailable(access, namespace: namespace, review: true) {
                throw BrowserMCP.ToolError(message: KubeMCPText.scrubbed(why))
            }
        }
        var from: Int?
        if verb == .scale {
            do {
                from = try await within { try await client.replicas(ref) }
            } catch {
                throw BrowserMCP.ToolError(message: "Couldn't read \(object)'s replicas: \(said(error))")
            }
            if from == replicas { return KubeMCPText.finished(target.header(kind: kind) + "\n\(object) has \(replicas ?? 0) replicas already: nothing was changed.") }
        }
        let rule = KubeWriteCheck.rule(verb, for: target.context, kind: kind, replicas: replicas)
        let confirmation = KubeWriteConfirmation.make(
            verb, ref, context: target.context, rule: rule, from: from, to: replicas, discovery: known(for: target, kubernetes: kubernetes))
        guard let typed = await ask(confirmation, pane: pane) else {
            throw BrowserMCP.ToolError(message: "The user declined \(confirmation.kubectl ?? object): nothing was changed.")
        }
        guard confirmation.accepts(typed) else {
            throw BrowserMCP.ToolError(message: "The name typed wasn't \(confirmation.typedName ?? name): nothing was changed.")
        }
        // As the context is now: writes turned off, agentWrites changed, or
        // the kubeconfig pointing it elsewhere while it asked stop it here.
        guard let list = await kubernetes.contextsForAgents(), let now = list.context(named: target.context.name),
            KubernetesModel.sameAccess(target.context, now), KubeAgentWrites.refused(now, agentWrites: kubernetes.agentWrites) == nil,
            KubeWriteCheck.rule(verb, for: now, kind: kind, replicas: replicas).refused == nil
        else {
            throw BrowserMCP.ToolError(message: "\(target.context.name) changed while it was asked (its writes, or agents' access): nothing was changed.")
        }
        let request: KubeWriteRequest =
            switch verb {
            case .restart: KubeWrites.restart(ref, at: Date())
            case .scale: KubeWrites.scale(ref, replicas: replicas ?? 0)
            default: KubeWrites.delete(ref)
            }
        let writer = kubernetes.agentClient(for: now)
        do {
            _ = try await within { try await writer.write(request) }
        } catch let error as BrowserMCP.ToolError {
            throw error
        } catch {
            throw BrowserMCP.ToolError(message: KubeMCPText.scrubbed(KubeWriteOutcome.failed(verb, ref, error)))
        }
        return KubeMCPText.finished(target.header(kind: kind) + "\n" + KubeWriteOutcome.done(verb, ref, from: from, replicas: replicas))
    }

    /// The confirmation in the window — the context and namespace in its
    /// title, all of the detail shown, a field for the name where asked —
    /// or a test's answer: what was typed, nil when refused.
    static func ask(_ confirmation: KubeWriteConfirmation, pane: String? = nil) async -> String? {
        if let askOverride { return askOverride(confirmation) }
        let sheet = WriteConfirmation(
            title: KubeAgentWrites.title(confirmation), scope: confirmation.scope, production: confirmation.production,
            detail: DockerMCP.displayed(confirmation.detail), button: "Allow", cancel: "Don't", typedName: confirmation.typedName,
            critical: confirmation.production || confirmation.typedName != nil)
        let window = window(forPane: pane)
        // An isolated run never stops on a dialog of its own: no window, no.
        if window == nil, AppEnvironment.isIsolated { return nil }
        if window != nil { NSApp.activate(ignoringOtherApps: true) }
        return await sheet.ask(on: window)
    }

    /// The window of the pane that called, else the main one, else any
    /// terminal window on screen.
    static func window(forPane pane: String?) -> NSWindow? {
        let terminals = NSApp.windows.compactMap { $0.windowController as? TerminalWindowController }
        if let pane, let own = terminals.first(where: { $0.store.tabs.contains { $0.terminals.contains { $0.processTag == pane } } }) {
            return own.window
        }
        return NSApp.mainWindow ?? terminals.first { $0.window?.isVisible == true }?.window
    }

    // MARK: Tools

    /// What is offered: the reads, and the writes while `kubernetes.agentWrites` names a context.
    static func tools(writes: Bool) -> [[String: Any]] { writes ? tools + writeTools : tools }

    static var writeTools: [[String: Any]] {
        let context: [String: Any] = [
            "type": "string",
            "description": "A context k8s_contexts says agents may write in. Default: the one selected on the Kubernetes page; with none, name one.",
        ]
        let namespace: [String: Any] = ["type": "string", "description": "Its namespace. Default: the page's namespace on that context, else the context's own."]
        let asked =
            " Only on a context k8s_contexts says agents may write in; asked of the user in Overterm's window first, naming the context and namespace; declined, nothing changes."
        return [
            tool(
                "k8s_restart", "Restart a workload's rollout, as kubectl rollout restart does: its pods are replaced one by one." + asked,
                [
                    "name": ["type": "string", "description": "The workload's name."],
                    "kind": ["type": "string", "description": "deployment (default), statefulset or daemonset."],
                    "namespace": namespace, "context": context,
                ], required: ["name"]),
            tool(
                "k8s_scale", "Set a workload's replicas through its scale subresource, as kubectl scale does." + asked,
                [
                    "name": ["type": "string", "description": "The workload's name."],
                    "replicas": ["type": "integer", "description": "How many, 0 to 10000."],
                    "kind": ["type": "string", "description": "deployment (default), statefulset or replicaset."],
                    "namespace": namespace, "context": context,
                ], required: ["name", "replicas"]),
            tool(
                "k8s_delete_pod",
                "Delete one pod, in the background after its grace period — its controller, if it has one, makes it again." + asked,
                ["name": ["type": "string", "description": "The pod's name."], "namespace": namespace, "context": context], required: ["name"]),
            tool(
                "k8s_apply",
                "Server-side apply a manifest (kubectl apply --server-side, field manager overterm): a server-side dry run first, its diff (masked) and the fields other managers own (Helm, Argo CD, Flux) shown to the user, who allows or not. Never forced: a conflict is reported. On production only where the context's applyOnProduction is on. No Secret: there is no tool for Secrets."
                    + asked + " Answers the diff that was applied.",
                [
                    "manifest": ["type": "string", "description": "The objects as YAML (several documents with ---) or JSON. No masked value (••••••, ***)."],
                    "namespace": ["type": "string", "description": "Where an object that names none goes. Default: the page's namespace on that context."],
                    "context": context,
                ], required: ["manifest"]),
        ]
    }

    /// The reads.
    static var tools: [[String: Any]] {
        let context: [String: Any] = ["type": "string", "description": "A context's name from k8s_contexts. Default: the one selected on the Kubernetes page; with none, name one."]
        let namespace: [String: Any] = [
            "type": "string", "description": "A namespace, several as a,b, or all (k8s_get, k8s_events, k8s_top). Default: the page's namespaces on that context, else the context's own.",
        ]
        return [
            tool(
                "k8s_contexts",
                "The kubeconfig's contexts: each one's class (production, remote, local), whether Overterm may write there and whether agents may (k8s_restart, k8s_scale, k8s_delete_pod work only there), its namespace, and which one the tools use unless told another. No server address or credential.",
                [:]),
            tool(
                "k8s_get",
                "List a kind as `kubectl get` prints it — the server's own columns, CRDs' printer columns too. Bounded rows. A Secret's row says its type and how many keys, never them.",
                [
                    "kind": ["type": "string", "description": "pods, deploy, svc, nodes, events, a CRD's plural or kubectl short name."],
                    "name": ["type": "string", "description": "Only this object."],
                    "namespace": namespace, "context": context,
                    "label_selector": ["type": "string", "description": "app=web,tier!=cache — the server picks."],
                    "field_selector": ["type": "string", "description": "status.phase=Running, spec.nodeName=… — the server picks."],
                    "filter": ["type": "string", "description": "Only rows with this text."],
                    "wide": ["type": "boolean", "description": "The -o wide columns too."],
                    "limit": ["type": "integer", "description": "Rows (default 100, at most 500)."],
                ], required: ["kind"]),
            tool(
                "k8s_describe",
                "One object, as `kubectl describe` would sum it up: its state, a pod's containers (state, restarts, last end, image, probes), a workload's replicas and rollout, conditions, owners, labels, the pods it selects, and its events. Env values that look secret are masked; a Secret says only its type and key count.",
                [
                    "kind": ["type": "string", "description": "pod, deploy, svc, node, a CRD…"],
                    "name": ["type": "string", "description": "Its name."],
                    "namespace": namespace, "context": context,
                ], required: ["kind", "name"]),
            tool(
                "k8s_logs",
                "A pod's container's last log lines, read once (never followed); secrets taken out before grep looks.",
                [
                    "pod": ["type": "string", "description": "The pod's name."],
                    "container": ["type": "string", "description": "Default: kubectl's (the default-container annotation, else the first)."],
                    "namespace": namespace, "context": context,
                    "tail": ["type": "integer", "description": "Lines (default 200, at most 2000)."],
                    "since": ["type": "string", "description": "Only this recent: 30s, 10m, 2h, 1d."],
                    "grep": ["type": "string", "description": "Only lines with this text (case-insensitive)."],
                    "previous": ["type": "boolean", "description": "The container's previous instance — the one that crashed."],
                ], required: ["pod"]),
            tool(
                "k8s_events",
                "Events, newest first: a namespace's (or all), or one object's (name, with kind; default a pod).",
                [
                    "namespace": namespace, "context": context,
                    "kind": ["type": "string", "description": "The object's kind, with name (default pod)."],
                    "name": ["type": "string", "description": "Only this object's events."],
                    "warnings_only": ["type": "boolean", "description": "Only Warning events."],
                    "limit": ["type": "integer", "description": "Events (default 50, at most 200)."],
                ]),
            tool(
                "k8s_why",
                "Why a pod fails (CrashLoopBackOff, OOMKilled, ImagePullBackOff, CreateContainerConfigError, Pending) or a Deployment's rollout is stuck: its status and last end with what the exit code means, events, the previous container's last lines, its owner's pod template and what changed since the previous ReplicaSet, for Pending the scheduler's message against the nodes. Scrubbed; no Secret read.",
                [
                    "name": ["type": "string", "description": "The pod's or the Deployment's name."],
                    "kind": ["type": "string", "enum": ["pod", "deployment"], "description": "Default pod."],
                    "namespace": namespace, "context": context,
                ], required: ["name"]),
            tool(
                "k8s_rollout",
                "A workload's rollout as `kubectl rollout status` says it, its replicas, and its history: each revision with its images, when, and its change-cause.",
                [
                    "name": ["type": "string", "description": "Its name."],
                    "kind": ["type": "string", "description": "deployment (default), statefulset or daemonset."],
                    "namespace": namespace, "context": context,
                ], required: ["name"]),
            tool(
                "k8s_top",
                "CPU and memory used now, as `kubectl top` says it, from metrics-server (metrics.k8s.io): a namespace's pods (or all), one pod's containers, or the nodes with their share of allocatable. Sorted, bounded. Says so when the cluster has no metrics-server. Pods get %CPU/R %CPU/L %MEM/R %MEM/L (shares of their containers' requests and limits) where their specs are in hand: a named pod's own (one read each), or for a namespace (up to 10) kube-state-metrics' through Prometheus, where the context opts in to it.",
                [
                    "kind": ["type": "string", "enum": ["pods", "nodes"], "description": "pods (default) or nodes."],
                    "name": ["type": "string", "description": "Only this pod (its containers)."],
                    "containers": ["type": "boolean", "description": "Each pod's containers, a line each."],
                    "sort_by": ["type": "string", "enum": ["cpu", "memory"], "description": "Default cpu."],
                    "label_selector": ["type": "string", "description": "app=web — the server picks."],
                    "limit": ["type": "integer", "description": "Pods or nodes (default 20, at most 200)."],
                    "namespace": namespace, "context": context,
                ]),
            tool(
                "k8s_metrics",
                "An object's usage over a range, as text: per chart min, p50, p95, max and last with their times, the last against its request, limit, allocatable or quota, restarts and OOMKills, rollouts and scaling marked. From Prometheus where the context opts in to it (the charts' own queries; no free-form PromQL), else what Overterm sampled while the object was shown, else metrics-server now. Says where the numbers come from and what is missing. Bounded to about 4 KB.",
                [
                    "kind": [
                        "type": "string", "enum": ["pod", "container", "workload", "namespace", "node", "pvc", "hpa", "cluster"],
                        "description": "Default pod. deployment, statefulset, daemonset, replicaset or job also name a workload.",
                    ],
                    "name": ["type": "string", "description": "The object's name (a container's pod). A namespace's: default the one namespace named."],
                    "container": ["type": "string", "description": "One container of the pod."],
                    "workload_kind": ["type": "string", "description": "A workload's: deployment (default), statefulset, daemonset, replicaset or job."],
                    "range": ["type": "string", "enum": ["15m", "1h", "6h", "24h", "7d"], "description": "Default 1h."],
                    "measures": [
                        "type": "array", "items": ["type": "string", "enum": MetricsMeasure.allCases.map(\.rawValue)],
                        "description": "Default cpu, memory and restarts (a pod's, a workload's); replicas (an HPA's); volume (a claim's); cpu and memory otherwise.",
                    ],
                    "sizing": [
                        "type": "boolean",
                        "description": "A container's or a workload's: suggested requests from seven days of usage (per pod; CPU from p95, memory from the max). Prometheus only.",
                    ],
                    "top_pods": [
                        "type": "boolean",
                        "description": "A node's: its pods ranked by CPU and memory too (Prometheus; a series per pod on the node, so asked only when wanted).",
                    ],
                    "namespace": namespace, "context": context,
                ]),
        ]
    }

    static let instructions =
        "Kubernetes as the user's kubeconfig reaches it (Overterm's Kubernetes page): k8s_contexts lists the contexts — production ones are said so —, k8s_get lists a kind, k8s_describe and k8s_events say what an object is doing, k8s_logs reads a pod's last lines (previous: the crashed instance), k8s_why gathers why a pod fails or a rollout is stuck, k8s_rollout gives a rollout's status and history, k8s_top what pods and nodes use now (metrics-server's), k8s_metrics an object's usage over a range against its requests and limits. They use the context and namespace selected on the Kubernetes page unless you name others; with none selected, name a context (k8s_contexts). Where k8s_contexts says agents may write, k8s_restart, k8s_scale, k8s_delete_pod and k8s_apply change it — each call is asked of the user in Overterm's window first, and a declined one changes nothing; elsewhere tell the user what to run. No tool reads a Secret's values."

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        [
            "name": name, "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any],
        ]
    }
}

/// What the `k8s_` tools say: tables, an Overview, events, a rollout's
/// history, a brief — bounded and scrubbed. Pure.
enum KubeMCPText {
    /// How much of an answer an agent gets.
    static let maxCharacters = 60_000
    /// A cell this long is cut.
    static let maxCell = 200

    /// `text` scrubbed of what looks like a credential (`Secrets`), and of
    /// every URL's userinfo — a token alone has no `:` for `maskURLs`.
    static func scrubbed(_ text: String) -> String { Secrets.scrubCredentials(GitRemoteURL.stripUserinfo(inText: Secrets.maskURLs(in: text))) }

    /// Scrubbed and bounded: every answer's last step.
    static func finished(_ text: String) -> String { bounded(scrubbed(text)) }

    static func bounded(_ text: String, keepEnd: Bool = false, max: Int = maxCharacters) -> String {
        guard text.count > max else { return text }
        return keepEnd
            ? "… (the first \(text.count - max) characters left out)\n" + String(text.suffix(max))
            : String(text.prefix(max)) + "\n… (\(text.count - max) more characters left out)"
    }

    /// An object's or a namespace's name: one path segment, not a path.
    static func isName(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 253 && text != "." && text != ".." && !text.contains("/") && !text.contains { $0.isNewline || $0 == "\u{0}" }
    }

    static func isSecret(_ kind: KubeResourceKind) -> Bool { kind.group.isEmpty && kind.resource == "secrets" }

    // MARK: Contexts

    struct ContextRow: Equatable {
        var name: String
        var displayName: String?
        var contextClass: KubeContextClass
        var writable: Bool
        var namespace: String
        var isDefault: Bool
        var isCurrent: Bool
        /// Why its requests stop now, when they do.
        var problem: String?
        /// Whether the write tools work here (`KubeAgentWrites`).
        var agentsWrite = false
    }

    /// What the header says of writes.
    static func writesSaid(_ rows: [ContextRow]) -> String {
        rows.contains(where: \.agentsWrite)
            ? "Agents write only where a context says so (k8s_restart, k8s_scale, k8s_delete_pod, k8s_apply), each call asked of the user first."
            : "Agents only read: no context is writable for agents now."
    }

    static func contexts(_ rows: [ContextRow]) -> String {
        var lines = [
            rows.contains(where: \.isDefault)
                ? "The kubeconfig's contexts (* the one the tools use unless told another). \(writesSaid(rows))"
                : "The kubeconfig's contexts. None is selected on the Kubernetes page, so every call names its “context”. \(writesSaid(rows))"
        ]
        for row in rows {
            var line = "\(row.isDefault ? "*" : " ") \(row.name)"
            if let display = row.displayName, display != row.name { line += " (“\(display)”)" }
            line += row.contextClass == .production ? " — PRODUCTION" : " — \(row.contextClass.rawValue)"
            line +=
                !row.writable
                ? ", read-only for Overterm" : row.agentsWrite ? ", writable — agents may restart, scale and delete pods here, each asked first" : ", writable for Overterm (not for agents)"
            line += "; namespace \(row.namespace)"
            if row.isCurrent { line += "; kubectl's current context" }
            if let problem = row.problem { line += "; not answering now: \(problem)" }
            lines.append(line)
        }
        return finished(lines.joined(separator: "\n"))
    }

    // MARK: Tables

    /// A Table as `kubectl get` prints it: a NAMESPACE column first across
    /// namespaces, the default columns (or every one, `wide`), cells cut,
    /// columns padded; rows with `filter`'s text only; a cut list said.
    static func table(
        _ table: KubeTable, kind: KubeResourceKind, allNamespaces: Bool, wide: Bool, filter: String?, selectors: [String] = [], name: String? = nil
    ) -> String {
        let shown = table.columns.enumerated().filter { wide || $0.element.priority == 0 }
        var header = shown.map { $0.element.name.uppercased() }
        if allNamespaces { header.insert("NAMESPACE", at: 0) }
        // Scrubbed before `filter` looks: matched against the raw cells, a
        // row's being there would say whether a credential in a cell (a
        // CRD's printer column) has a guessed text, a character at a time.
        var rows: [[String]] = table.rows.map { row in
            var cells = shown.map { index, _ in index < row.cells.count ? cut(scrubbed(row.cells[index].text)) : "" }
            if allNamespaces { cells.insert(cut(scrubbed(row.id.namespace ?? "")), at: 0) }
            return cells
        }
        if let filter { rows = rows.filter { $0.joined(separator: " ").localizedCaseInsensitiveContains(filter) } }
        guard !rows.isEmpty else {
            var none = name.map { "No \(kind.singular.isEmpty ? kind.resource : kind.singular) “\($0)”" } ?? "No \(kind.resource)"
            if !selectors.isEmpty { none += " matching \(selectors.joined(separator: ", "))" }
            if let filter { none += " with “\(filter)”" }
            return none + "."
        }
        var widths = header.map(\.count)
        for row in rows { for (index, cell) in row.enumerated() where index < widths.count { widths[index] = max(widths[index], cell.count) } }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { index, cell in
                index == cells.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "   ").trimmingCharacters(in: .whitespaces)
        }
        var lines = [line(header)] + rows.map(line)
        if table.continueToken != nil {
            let more = table.remainingItemCount.map { "\($0) more" } ?? "More"
            lines.append("… \(more) not listed: narrow it (label_selector, field_selector, a namespace) or raise limit.")
        }
        return lines.joined(separator: "\n")
    }

    /// A list's `metadata.continue`: there when the server cut it.
    static func continueToken(_ body: Data) -> String? {
        let metadata = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["metadata"] as? [String: Any]
        return (metadata?["continue"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func cut(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > maxCell ? String(flat.prefix(maxCell)) + "…" : flat
    }

    /// A Secret, from its Table row: its type and how many keys — never
    /// their names or values, which only its GET has.
    static func secret(_ row: KubeRow, columns: [KubeColumn], namespace: String) -> String {
        let type = row.cell("Type", in: columns)?.text ?? "?"
        let keys = row.cell("Data", in: columns)?.text ?? "?"
        let age = row.cell("Age", in: columns)?.text
        var text = "Secret \(namespace)/\(row.id.name): type \(type), \(keys) \(keys == "1" ? "key" : "keys")"
        if let age, !age.isEmpty { text += ", made \(age) ago" }
        return text + ". Its keys and values are never read for an agent; the user can Show it on the Kubernetes page."
    }

    /// The pods a workload or a Service selects, as rows: bounded.
    static func pods(_ table: KubeTable, selector: String, max: Int = 30) -> String {
        let pods = table.rows.sorted { $0.id < $1.id }.compactMap { KubePodSummary(row: $0, columns: table.columns) }
        guard !pods.isEmpty else { return "Pods it selects (\(selector)): none." }
        var lines = ["Pods it selects (\(selector)):"]
        for pod in pods.prefix(max) {
            var line = "  \(pod.id.name): \(pod.status)"
            if let ready = pod.ready, let containers = pod.containers { line += ", \(ready)/\(containers) ready" }
            if let restarts = pod.restarts, restarts > 0 {
                line += ", \(restarts) restarts" + (pod.lastRestart.map { " (last \($0))" } ?? "")
            }
            lines.append(line)
        }
        if pods.count > max { lines.append("  … \(pods.count - max) more") }
        return lines.joined(separator: "\n")
    }

    // MARK: An Overview

    static func overview(_ overview: KubeOverview, title: String) -> String {
        var lines = [title]
        for item in overview.facts { lines.append(self.item(item, indent: "")) }
        if let rollout = overview.rollout, overview.item("Rollout") == nil { lines.append("Rollout: \(rollout.message)") }
        for section in overview.sections where !section.items.isEmpty {
            lines.append("\(section.title):")
            lines += section.items.map { self.item($0, indent: "  ") }
        }
        return lines.joined(separator: "\n")
    }

    private static func item(_ item: KubeOverview.Item, indent: String) -> String {
        var line = "\(indent)\(item.label): \(item.value)"
        if let detail = item.detail, !detail.isEmpty { line += " — \(detail.replacingOccurrences(of: "\n", with: "; "))" }
        return line
    }

    // MARK: Events

    static func events(_ events: [(KubeEvent, String)], limit: Int, now: Date, empty: String) -> String {
        guard !events.isEmpty else { return empty }
        var lines = ["Events, newest first:"]
        for (event, about) in events.prefix(limit) {
            var line = event.last.map { "\(KubeAge.format(max(0, now.timeIntervalSince($0)))) ago " } ?? ""
            line += "\(event.isWarning ? "Warning" : "Normal") \(event.reason) \(about)"
            if event.count > 1 { line += " ×\(event.count)" }
            line += ": " + KubeAgentText.short(event.message, 400)
            lines.append(line)
        }
        if events.count > limit { lines.append("… \(events.count - limit) older left out") }
        return lines.joined(separator: "\n")
    }

    // MARK: Rollouts

    static func rollout(_ rollout: KubeRollout, _ object: [String: Any], of what: String) -> String {
        let spec = KubeAgentText.map(object["spec"])
        let status = KubeAgentText.map(object["status"])
        func int(_ key: String) -> Int { KubeRollout.int(status[key]) ?? 0 }
        var lines = ["Rollout of \(what): \(rollout.message)" + (rollout.state == .stuck ? " — STUCK" : "")]
        if object["kind"] as? String == "DaemonSet" {
            lines.append(
                "Pods: \(int("desiredNumberScheduled")) wanted, \(int("updatedNumberScheduled")) updated, \(int("numberReady")) ready, \(int("numberAvailable")) available.")
        } else {
            let wanted = KubeRollout.int(spec["replicas"]) ?? 1
            lines.append(
                "Replicas: \(wanted) wanted, \(int("updatedReplicas")) updated, \(int("readyReplicas")) ready, \(int("availableReplicas")) available.")
        }
        return lines.joined(separator: "\n")
    }

    /// Whether a ReplicaSet or ControllerRevision is the workload's own.
    static func isOwned(_ item: [String: Any], by uid: String?, name: String, kind: String) -> Bool {
        KubeAgentText.list(KubeAgentText.map(item["metadata"])["ownerReferences"]).contains { owner in
            if let uid, let theirs = owner["uid"] as? String { return theirs == uid }
            return owner["kind"] as? String == kind && owner["name"] as? String == name
        }
    }

    /// Each revision — a Deployment's ReplicaSets, a StatefulSet's or a
    /// DaemonSet's ControllerRevisions — newest first: its images, its
    /// replicas, its age, its change-cause; nil with none.
    static func history(_ items: [[String: Any]], of object: [String: Any], kind: String, now: Date, limit: Int = 15) -> String? {
        let metadata = KubeAgentText.map(object["metadata"])
        let status = KubeAgentText.map(object["status"])
        let currentRevision = KubeAgentText.string(KubeAgentText.map(metadata["annotations"])["deployment.kubernetes.io/revision"]).flatMap { Int($0) }
        let currentNames = Set([status["currentRevision"], status["updateRevision"]].compactMap { $0 as? String })
        let revisions = items.compactMap { item -> (Int, [String: Any])? in
            let revision = kind == "Deployment" ? KubeAgentText.revision(item) : KubeRollout.int(item["revision"])
            return revision.map { ($0, item) }
        }.sorted { $0.0 > $1.0 }
        guard !revisions.isEmpty else { return nil }
        var lines = ["History, newest first:"]
        for (revision, item) in revisions.prefix(limit) {
            let itemMetadata = KubeAgentText.map(item["metadata"])
            let name = KubeAgentText.name(item)
            let template =
                kind == "Deployment"
                ? KubeAgentText.map(KubeAgentText.map(item["spec"])["template"])
                : KubeAgentText.map(KubeAgentText.map(KubeAgentText.map(item["data"])["spec"])["template"])
            let images = KubeAgentText.list(KubeAgentText.map(template["spec"])["containers"]).compactMap { $0["image"] as? String }
            var line = "  revision \(revision) \(name)"
            if revision == currentRevision || currentNames.contains(name) { line += " (current)" }
            if !images.isEmpty { line += ": \(images.joined(separator: ", "))" }
            if kind == "Deployment" {
                let spec = KubeAgentText.map(item["spec"])
                let itemStatus = KubeAgentText.map(item["status"])
                line += "; \(KubeRollout.int(itemStatus["readyReplicas"]) ?? 0)/\(KubeRollout.int(spec["replicas"]) ?? 0) ready"
            }
            if let created = (itemMetadata["creationTimestamp"] as? String).flatMap(KubeTime.date) {
                line += "; made \(KubeAge.format(max(0, now.timeIntervalSince(created)))) ago"
            }
            if let cause = KubeAgentText.string(KubeAgentText.map(itemMetadata["annotations"])["kubernetes.io/change-cause"]) {
                line += "; change-cause: \(KubeAgentText.short(cause, 300))"
            }
            lines.append(line)
        }
        if revisions.count > limit { lines.append("  … \(revisions.count - limit) older") }
        return lines.joined(separator: "\n")
    }

    // MARK: A brief

    /// Ask Why's brief as one text: the question, what is always sent, then each part.
    static func brief(_ brief: KubeAgentBrief) -> String {
        var text = "Question: \(brief.message)\n\n\(brief.text)"
        for part in brief.parts { text += "\n\n## \(part.title)\n\(part.text)" }
        return text
    }

    // MARK: Time

    /// `30s`, `10m`, `2h`, `1d`, `90` (seconds) as seconds; nil otherwise.
    static func seconds(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let plain = Int(trimmed) { return plain > 0 ? plain : nil }
        guard let unit = trimmed.last, let value = Int(trimmed.dropLast()), value > 0 else { return nil }
        let scale: Int
        switch unit {
        case "s": scale = 1
        case "m": scale = 60
        case "h": scale = 3600
        case "d": scale = 86400
        default: return nil
        }
        let (product, overflow) = value.multipliedReportingOverflow(by: scale)
        return overflow ? nil : product
    }

    /// RFC 3339 in whole seconds, UTC: what `sinceTime` takes.
    static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

/// Where agents' write tools work (3.5, rule 10): a context
/// `kubernetes.agentWrites` names (the default is none: agents read only)
/// **and** writable for Overterm — a local or remote one by its `writable`
/// setting, a production one only with its writes on for the session.
/// Nothing else turns them on. Pure.
enum KubeAgentWrites {
    static let tools = ["k8s_restart", "k8s_scale", "k8s_delete_pod", "k8s_apply"]

    /// Why agents may not write on `context`; nil when they may.
    static func refused(_ context: KubeContext, agentWrites: [String]) -> String? {
        guard context.isWritable else {
            return context.isProduction
                ? "\(context.name) is production, read-only: its writes aren't on for this session."
                : "\(context.name) is read-only for Overterm (its writable setting), so for agents too."
        }
        guard agentWrites.contains(context.name) else {
            return context.isProduction
                ? "\(context.name) is production: its writes are on for this session, but kubernetes.agentWrites doesn't name it."
                : "kubernetes.agentWrites doesn't name \(context.name): agents only read there."
        }
        return nil
    }

    /// The confirmation's title: who asks, the context and namespace, then
    /// what — `An agent asks, in kind-fake · namespace shop: Scale …?`.
    static func title(_ confirmation: KubeWriteConfirmation) -> String {
        "An agent asks, in \(confirmation.scope): \(confirmation.title)"
    }
}
