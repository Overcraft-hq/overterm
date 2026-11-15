import Foundation

/// `k8s_metrics` (docs/design/kubernetes/metrics.md, 7; stage M11): an
/// object's usage over a range as text an agent reads — never a matrix —
/// from the charts' own queries and builders (`KubeMetricsText` says each
/// chart). Where the numbers come from, in order:
///
/// - **Prometheus**, where the context opts in to it: the Metrics tab's
///   queries (`KubeTabQueries`; the Overview's for the cluster and a
///   claim), asked for the call (`KubePrometheusMonitor.agentPrepare` —
///   §6.4's one exception to "only while a chart shows": the metrics proxy
///   in a background slot, the context's queue as an agent, below the
///   page and at most two of its four places, the proxy closed when idle);
/// - else **what was sampled while shown** (`KubeUsageRing`), where the
///   page sampled this object on this context ("since 14:02");
/// - else **one metrics.k8s.io read now** ("now only").
///
/// Agents always get an answer: what couldn't be read is said, and the
/// next source tried. No free-form PromQL: the queries are the design's,
/// under its caps. `sizing` runs R1 once (`KubeSizing`). Reads only, GETs,
/// bounded to about 4 KB and scrubbed (`KubeMCPText.finished`), names cut
/// to 253 characters, Prometheus' notes quoted as data.
extension KubeMCP {
    /// What an object is, as `kind` says it.
    enum MetricsKind: String, CaseIterable, Sendable {
        case pod, container, workload, namespace, node, pvc, hpa, cluster

        var namespaced: Bool { [.pod, .container, .workload, .pvc, .hpa].contains(self) }
        var named: Bool { self != .cluster && self != .namespace }
    }

    /// What can be asked of it.
    enum MetricsMeasure: String, CaseIterable, Sendable {
        case cpu, memory, throttling, network, restarts, replicas, volume, fs

        /// The Metrics tab's query families it asks. Never a node's top
        /// pods (a series a pod on it, asked by the page only while their
        /// group shows): those only on `top_pods`.
        var families: Set<KubeTabFamily> {
            switch self {
            case .cpu: [.cpu, .revisions]
            case .memory: [.memory, .oom]
            case .throttling: [.throttling]
            case .network: [.network, .nodeNetwork]
            case .restarts: [.restarts, .oom]
            case .replicas: [.replicas, .hpa, .hpaMetrics, .nodePods, .phases]
            case .volume: []
            case .fs: [.fs, .disks]
            }
        }

        /// A chart's measure by its identifier's last part; nil, none asked here.
        static func of(chart id: String) -> MetricsMeasure? {
            let parts = id.split(separator: ".")
            if parts.contains("disk") { return .fs }
            switch parts.last.map(String.init) ?? "" {
            case "cpu", "revisions": return .cpu
            case "memory": return .memory
            case "throttling": return .throttling
            case "network": return .network
            case "restarts": return .restarts
            case "replicas", "pods", "phases": return .replicas
            case "fs": return .fs
            case "used": return .volume
            default: return nil
            }
        }
    }

    /// One `k8s_metrics` question.
    struct MetricsQuestion: Sendable {
        var kind: MetricsKind
        var namespace: String?
        var name: String?
        var container: String?
        /// A workload's Kind: Deployment, StatefulSet, DaemonSet, ReplicaSet, Job.
        var workloadKind = "Deployment"
        var range: KubeMetricsRange = .hour
        var measures: Set<MetricsMeasure>
        var sizing = false
        /// A node's pods ranked by CPU and memory too (`top_pods`): one series a pod on it.
        var topPods = false

        /// What it is about: `container app of pod shop/api-1`.
        var said: String {
            let place = namespace.map { "\($0)/" } ?? ""
            switch kind {
            case .pod: return "pod \(place)\(name ?? "")"
            case .container: return "container \(container ?? "") of pod \(place)\(name ?? "")"
            case .workload: return "\(workloadKind) \(place)\(name ?? "")"
            case .namespace: return "namespace \(namespace ?? "")"
            case .node: return "node \(name ?? "")"
            case .pvc: return "claim \(place)\(name ?? "")"
            case .hpa: return "HPA \(place)\(name ?? "")"
            case .cluster: return "the cluster"
            }
        }

        /// The range as the answer says it.
        var rangeSaid: String { range == .live ? "15m" : range.title }
    }

    static let metricsRanges: [String: KubeMetricsRange] = [
        "15m": .live, "live": .live, "1h": .hour, "6h": .sixHours, "24h": .day, "1d": .day, "7d": .week, "1w": .week,
    ]

    static let workloadKinds: [String: String] = [
        "deployment": "Deployment", "deployments": "Deployment", "deploy": "Deployment", "statefulset": "StatefulSet", "statefulsets": "StatefulSet",
        "sts": "StatefulSet", "daemonset": "DaemonSet", "daemonsets": "DaemonSet", "ds": "DaemonSet", "replicaset": "ReplicaSet", "replicasets": "ReplicaSet",
        "rs": "ReplicaSet", "job": "Job", "jobs": "Job",
    ]

    /// What a call asks: its kind, object, range and measures — every name one path segment.
    static func metricsQuestion(_ call: Call, _ target: Target) throws -> MetricsQuestion {
        let wanted = (call.string("kind") ?? "pod").lowercased()
        var workloadKind = workloadKinds[(call.string("workload_kind") ?? "deployment").lowercased()]
        guard workloadKind != nil else {
            throw BrowserMCP.ToolError(message: "“workload_kind” is deployment, statefulset, daemonset, replicaset or job.")
        }
        let kind: MetricsKind
        switch wanted {
        case "pod", "pods", "po": kind = .pod
        case "container", "containers": kind = .container
        case "workload", "workloads": kind = .workload
        case "namespace", "namespaces", "ns": kind = .namespace
        case "node", "nodes", "no": kind = .node
        case "pvc", "pvcs", "persistentvolumeclaim", "persistentvolumeclaims", "claim": kind = .pvc
        case "hpa", "hpas", "horizontalpodautoscaler", "horizontalpodautoscalers": kind = .hpa
        case "cluster": kind = .cluster
        default:
            guard let named = workloadKinds[wanted] else {
                throw BrowserMCP.ToolError(message: "“kind” is pod, container, workload, namespace, node, pvc, hpa or cluster (or a workload's: deployment, statefulset…).")
            }
            kind = .workload
            workloadKind = named
        }
        var question = MetricsQuestion(kind: kind, workloadKind: workloadKind ?? "Deployment", measures: [])
        if kind.named {
            question.name = try call.objectName("name", "the \(kind.rawValue == "container" ? "pod" : kind.rawValue)'s name, from k8s_get")
        }
        if kind.namespaced { question.namespace = try target.oneNamespace(call.name) }
        if kind == .namespace {
            let name = call.string("name") ?? target.namespace
            guard let name, KubeMCPText.isName(name) else {
                throw BrowserMCP.ToolError(message: "k8s_metrics of a namespace needs “name” (or one “namespace”).")
            }
            question.namespace = name
        }
        if let container = call.string("container") {
            guard KubeMCPText.isName(container) else { throw BrowserMCP.ToolError(message: "“\(container)” isn't a container's name.") }
            guard kind == .pod || kind == .container else { throw BrowserMCP.ToolError(message: "“container” is a pod's: kind pod or container.") }
            question.container = container
            question.kind = .container
        } else if kind == .container {
            throw BrowserMCP.ToolError(message: "k8s_metrics of a container needs “container” and its pod's “name”.")
        }
        if let range = call.string("range") {
            guard let picked = metricsRanges[range.lowercased()] else { throw BrowserMCP.ToolError(message: "“range” is 15m, 1h, 6h, 24h or 7d.") }
            question.range = picked
        }
        var named: [String] = []
        if let list = call.arguments["measures"] as? [Any] {
            named = list.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces).lowercased() }
        } else if let text = call.string("measures") {
            named = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        }
        for one in named where !one.isEmpty {
            guard let measure = MetricsMeasure(rawValue: one) else {
                throw BrowserMCP.ToolError(message: "“\(one)” isn't a measure: \(MetricsMeasure.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            question.measures.insert(measure)
        }
        if question.measures.isEmpty { question.measures = defaultMeasures(question.kind) }
        question.sizing = call.bool("sizing")
        if question.sizing, ![.container, .workload, .pod].contains(question.kind) {
            throw BrowserMCP.ToolError(message: "“sizing” is a container's or a workload's.")
        }
        question.topPods = call.bool("top_pods")
        if question.topPods, question.kind != .node { throw BrowserMCP.ToolError(message: "“top_pods” is a node's.") }
        return question
    }

    /// What is asked when the call names no measure.
    static func defaultMeasures(_ kind: MetricsKind) -> Set<MetricsMeasure> {
        switch kind {
        case .pod, .container, .workload: [.cpu, .memory, .restarts]
        case .hpa: [.replicas]
        case .pvc: [.volume]
        case .namespace, .node, .cluster: [.cpu, .memory]
        }
    }

    // MARK: The call

    static func metrics(_ call: Call, _ target: Target, kubernetes: KubernetesModel, now: Date) async throws -> String {
        let question = try metricsQuestion(call, target)
        let header = target.header(question.kind.namespaced || question.kind == .namespace ? .namespace(question.namespace ?? "") : nil, kind: question.kind.namespaced ? .pods : .namespaces)
        let lines = try await usage(question, target, kubernetes: kubernetes, now: now).lines
        return KubeMCPText.finished(KubeMetricsText.bounded([header] + lines))
    }

    /// Where an answer's numbers came from.
    enum MetricsSource: Sendable {
        case prometheus, sampled, now
        /// Nothing to say a number from (no metrics-server, a claim without Prometheus).
        case none
    }

    /// The answer's lines: what it is about, where the numbers come from,
    /// each chart's figures, the notes; sizing's figures when asked.
    /// `known`: what Ask Why's brief read already (the object, its events,
    /// a Deployment's ReplicaSets) — not read again.
    static func usage(
        _ question: MetricsQuestion, _ target: Target, kubernetes: KubernetesModel, now: Date, known: KubeBriefReads? = nil
    ) async throws -> (lines: [String], source: MetricsSource) {
        let client = target.client
        let context = target.context
        var notes: [String] = []
        // The object the charts' references and markers are read from: one GET.
        var object: [String: Any]?
        switch question.kind {
        case .pod, .container:
            guard let namespace = question.namespace, let name = question.name else { break }
            let read: [String: Any]
            if let known {
                read = known.object
            } else {
                read = try await objectJSON(client, KubeResourceKind.pods.path(namespace: namespace, name: name), what: question.said)
            }
            if let container = question.container, !KubePodCharts.containers(of: read).contains(where: { $0.name == container }) {
                let names = KubePodCharts.containers(of: read).map(\.name).joined(separator: ", ")
                throw BrowserMCP.ToolError(message: "Pod \(name) has no container “\(container)”: it has \(names).")
            }
            object = read
        case .workload:
            guard let namespace = question.namespace, let name = question.name, let kind = workloadResource(question.workloadKind) else { break }
            if let known { object = known.object } else { object = try await objectJSON(client, kind.path(namespace: namespace, name: name), what: question.said) }
        case .node:
            guard let name = question.name else { break }
            object = try await objectJSON(client, "/api/v1/nodes/\(KubePath.segment(name))", what: question.said)
        case .namespace, .pvc, .hpa, .cluster:
            break
        }
        let changes = await chartChanges(question, object: object, client: client, now: now, known: known, notes: &notes)

        // Prometheus first, where the context opts in to it.
        var prepared: KubePrometheusMonitor.AgentRead?
        // Opted in and tried: whatever came of it, its note says.
        var prometheusTried = false
        if KubePrometheusUse.of(context.settings).isOn {
            switch await kubernetes.prometheus.agentPrepare(context, client: client, transport: { kubernetes.agentPrometheusTransport(for: context, $0) }) {
            case .off: break
            case .unavailable(let why):
                notes.append("Prometheus couldn't be asked: \(why)")
                prometheusTried = true
            case .ready(let read):
                prepared = read
                prometheusTried = true
            }
        }
        var lines: [String] = []
        var answered = false
        var source = MetricsSource.none
        if let prepared {
            let drawn = await prometheusCharts(question, prepared, object: object, changes: changes, kubernetes: kubernetes, context: context.name, now: now)
            if Task.isCancelled { throw CancellationError() }
            if drawn.charts.contains(where: { $0.data.usage.contains { !$0.points.isEmpty } }) {
                lines = said(question, drawn, now: now)
                answered = true
                source = .prometheus
            } else {
                notes.append(drawn.problem.map { "Prometheus couldn't be read: \($0)" } ?? "Prometheus has nothing of \(question.said) over \(question.rangeSaid).")
            }
        }
        if !answered, let sampled = sampledCharts(question, object: object, changes: changes, kubernetes: kubernetes, context: context, now: now) {
            lines = said(question, sampled, now: now)
            if question.range != .live, question.range != .sixHours {
                notes.append("Without Prometheus there is no \(question.rangeSaid): what was sampled while shown, up to 6h.")
            }
            answered = true
            source = .sampled
        }
        if !answered {
            let read = try await sampledNow(question, object: object, target, kubernetes: kubernetes, now: now, prometheusAsked: prometheusTried)
            lines = read.lines
            if read.sampled { source = .now }
        }
        if question.sizing {
            lines += await sizing(question, prepared, object: object, changes: changes, kubernetes: kubernetes, context: context.name, now: now)
        }
        return (lines + notes.map(KubeMetricsText.note), source)
    }

    /// One object's JSON, its failure said as the tool's error.
    private static func objectJSON(_ client: KubeClient, _ path: String, what: String) async throws -> [String: Any] {
        let body: Data
        do {
            body = try await within { try await client.get(path).body }
        } catch {
            throw BrowserMCP.ToolError(message: "\(what) couldn't be read: \(said(error))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw BrowserMCP.ToolError(message: "\(what): the answer isn't an object.")
        }
        guard !KubeObjectStrip.isSecret(json) else { throw BrowserMCP.ToolError(message: "A Secret has no usage.") }
        return json
    }

    static func workloadResource(_ kind: String) -> KubeResourceKind? {
        switch kind {
        case "Deployment": .deployments
        case "StatefulSet": .statefulSets
        case "DaemonSet": .daemonSets
        case "ReplicaSet": .replicaSets
        case "Job": .jobs
        default: nil
        }
    }

    /// What the markers are joined from, as the tab joins them: a pod's
    /// last terminations (its object, read already) and its events; a
    /// workload's History (its ReplicaSets or ControllerRevisions, one
    /// list) and its events; a node's or an HPA's events. A read that
    /// fails is said, the rest goes on. What Ask Why's brief read
    /// (`known`: the events, a Deployment's ReplicaSets) isn't read again.
    private static func chartChanges(
        _ question: MetricsQuestion, object: [String: Any]?, client: KubeClient, now: Date, known: KubeBriefReads? = nil, notes: inout [String]
    ) async -> KubeChartChanges {
        var changes = KubeChartChanges()
        let metadata = object?["metadata"] as? [String: Any] ?? [:]
        let uid = metadata["uid"] as? String
        let eventKind: String?
        switch question.kind {
        case .pod, .container:
            if let object, let pod = KubePodStates.pod(object) { changes.restarts = KubeRestartLog(KubePodStates(pods: [pod], read: now)) }
            eventKind = "Pod"
        case .workload: eventKind = question.workloadKind
        case .node: eventKind = "Node"
        case .hpa: eventKind = "HorizontalPodAutoscaler"
        case .namespace, .pvc, .cluster: eventKind = nil
        }
        guard let eventKind, let name = question.name else { return changes }
        let namespace = question.kind == .node ? nil : question.namespace
        if let known {
            // The brief's own read: said there when it failed.
            if let events = known.events {
                changes.events = events
                changes.eventsJoined = true
            }
        } else {
            do {
                changes.events = try await within { try await client.events(kind: eventKind, name: name, namespace: namespace, uid: uid) }
                changes.eventsJoined = true
            } catch {
                notes.append("Its events couldn't be read: \(said(error))")
            }
        }
        // A Deployment's, StatefulSet's or DaemonSet's History: its rollouts marked.
        if question.kind == .workload, let namespace, let object {
            let ref = KubeObjectRef(context: "", kind: workloadResource(question.workloadKind) ?? .deployments, namespace: namespace, name: name)
            if let source = KubeTimeline.Source.of(ref), source == .replicaSets, let sets = known?.replicaSets {
                let revisions = KubeTimeline.revisions(items: sets, source: source, owner: uid ?? "")
                changes.timeline = KubeTimeline.entries(revisions: revisions, helm: [], events: changes.events, kind: question.workloadKind).entries
            } else if known == nil, let source = KubeTimeline.Source.of(ref) {
                let selector = KubeSelector.text((object["spec"] as? [String: Any])?["selector"])
                let path = KubePath.query(source.path(namespace: namespace), [("labelSelector", selector ?? ""), ("limit", String(KubeTimeline.revisionLimit))])
                do {
                    let body = try await within { try await client.get(path).body }
                    let revisions = KubeTimeline.revisions(body, source: source, owner: uid ?? "").revisions
                    changes.timeline = KubeTimeline.entries(revisions: revisions, helm: [], events: changes.events, kind: question.workloadKind).entries
                } catch {
                    notes.append("Its rollouts couldn't be read: \(said(error))")
                }
            }
        }
        return changes
    }

    // MARK: Where the numbers come from

    /// Charts as an object's tab draws them: where from and over what (the
    /// caption), the charts with what they are called, the notes beneath.
    struct DrawnCharts {
        var caption: String
        var charts: [(label: String, data: KubeChartData, seriesToo: Bool)]
        var notes: [String] = []
        var problem: String?
    }

    /// The tab's (or the Overview's) queries asked for the call, drawn by
    /// the tab's own builders.
    private static func prometheusCharts(
        _ question: MetricsQuestion, _ read: KubePrometheusMonitor.AgentRead, object: [String: Any]?, changes: KubeChartChanges, kubernetes: KubernetesModel,
        context: String, now: Date
    ) async -> DrawnCharts {
        let monitor = kubernetes.prometheus
        var families = question.measures.reduce(into: Set<KubeTabFamily>()) { $0.formUnion($1.families) }
        if question.topPods {
            if question.measures.contains(.cpu) { families.insert(.topCPU) }
            if question.measures.contains(.memory) { families.insert(.topMemory) }
        }
        func tab(_ subject: KubeTabSubject) async -> KubeTabReading {
            await monitor.agentTab(KubeTabRequest(subject: subject, span: .range(question.range), families: families), read, context: context)
        }
        let chartRange: KubeChartRange =
            switch question.range {
            case .live, .hour: .hour
            case .sixHours: .sixHours
            case .day: .day
            case .week: .week
            }
        switch question.kind {
        case .pod, .container:
            guard let namespace = question.namespace, let name = question.name, let object else { return DrawnCharts(caption: "", charts: []) }
            let spec = object["spec"] as? [String: Any] ?? [:]
            let limited = KubePodCharts.containers(of: object).contains { $0.cpuLimit != nil }
            let reading = await tab(.pod(namespace: namespace, name: name, cpuLimited: limited, hostNetwork: spec["hostNetwork"] as? Bool ?? false))
            let charts = KubePromTabCharts.pod(namespace: namespace, pod: name, object: object, reading: reading, changes: changes, window: nil)
            return DrawnCharts(caption: charts.caption, charts: podCharts(charts, question), notes: charts.notes, problem: reading.read == nil ? reading.problem : nil)
        case .workload:
            guard let namespace = question.namespace, let name = question.name, let object else { return DrawnCharts(caption: "", charts: []) }
            let reading = await tab(.workload(namespace: namespace, kind: question.workloadKind, name: name, hpa: nil))
            let input = KubeWorkloadCharts.Input(
                namespace: namespace, kind: question.workloadKind, name: name, object: object, ring: KubeUsageRing(), statuses: KubeStatusHistory(), pods: [],
                range: question.range, now: now, interval: 15, changes: changes)
            return drawn(KubePromTabCharts.workload(input, reading: reading), question, problem: reading.read == nil ? reading.problem : nil)
        case .hpa:
            guard let namespace = question.namespace, let name = question.name else { return DrawnCharts(caption: "", charts: []) }
            let reading = await tab(.hpa(namespace: namespace, name: name))
            return drawn(
                KubePromTabCharts.hpa(namespace: namespace, name: name, reading: reading, changes: changes, window: nil), question,
                problem: reading.read == nil ? reading.problem : nil)
        case .node:
            guard let name = question.name else { return DrawnCharts(caption: "", charts: []) }
            let reading = await tab(.node(name))
            let facts = KubeNodeFacts.of(object ?? [:])
            return drawn(
                KubePromTabCharts.node(node: name, facts: facts, reading: reading, changes: changes, window: nil), question,
                problem: reading.read == nil ? reading.problem : nil)
        case .namespace:
            guard let namespace = question.namespace else { return DrawnCharts(caption: "", charts: []) }
            let reading = await tab(.namespace(namespace))
            return drawn(
                KubePromTabCharts.namespace(namespace: namespace, reading: reading, quota: nil, changes: changes, window: nil), question,
                problem: reading.read == nil ? reading.problem : nil)
        case .pvc:
            guard let namespace = question.namespace, let name = question.name, question.measures.contains(.volume) else {
                return DrawnCharts(caption: "", charts: [])
            }
            let chart = KubeChart.volume(namespace: namespace, claim: name)
            let reading = await monitor.agentChart(chart, range: chartRange, read, context: context)
            return overview(reading, [KubeChartData.of(reading, chart: chart, measure: .volumeUsed)], question, label: { _ in "Used" })
        case .cluster:
            guard !question.measures.isDisjoint(with: [.cpu, .memory]) else { return DrawnCharts(caption: "", charts: []) }
            let reading = await monitor.agentChart(.cluster, range: chartRange, read, context: context)
            return overview(reading, KubeClusterCharts.prometheus(reading).map(\.data), question, label: { $0.title })
        }
    }

    /// An Overview chart's reading as drawn charts, those of the measures asked.
    private static func overview(
        _ reading: KubeChartReading, _ charts: [KubeChartData], _ question: MetricsQuestion, label: (KubeChartData) -> String
    ) -> DrawnCharts {
        var notes = reading.notes
        if let refused = reading.refused { notes.insert(refused, at: 0) }
        if question.range == .live { notes.append("The cluster's and a claim's charts start at 1h.") }
        let caption = ["Prometheus", reading.caption].compactMap { $0 }.joined(separator: " · ")
        let wanted = charts.filter { MetricsMeasure.of(chart: $0.id).map(question.measures.contains) == true }
        return DrawnCharts(
            caption: caption, charts: reading.read == nil ? [] : wanted.map { (label($0), $0, true) }, notes: notes,
            problem: reading.read == nil ? reading.unavailable ?? reading.problem : nil)
    }

    /// A workload's, an HPA's, a node's or a namespace's charts, those of the measures asked.
    private static func drawn(_ charts: KubeObjectCharts, _ question: MetricsQuestion, problem: String? = nil) -> DrawnCharts {
        var picked: [(label: String, data: KubeChartData, seriesToo: Bool)] = []
        for group in charts.groups {
            for chart in group.charts {
                guard question.kind == .hpa || MetricsMeasure.of(chart: chart.data.id).map(question.measures.contains) == true else { continue }
                let label = group.charts.count == charts.charts.count ? chart.data.title : "\(group.title) · \(chart.data.title)"
                picked.append((label, chart.data, true))
            }
        }
        return DrawnCharts(caption: charts.caption, charts: picked, notes: charts.notes, problem: problem)
    }

    /// A pod's charts, those of the measures asked: each container's (a
    /// container's own when one is named), the pod's total where it has
    /// several, and what only the pod has (its network, its restarts).
    private static func podCharts(_ charts: KubePodCharts, _ question: MetricsQuestion) -> [(label: String, data: KubeChartData, seriesToo: Bool)] {
        func wanted(_ data: KubeChartData) -> Bool { MetricsMeasure.of(chart: data.id).map(question.measures.contains) == true }
        var picked: [(label: String, data: KubeChartData, seriesToo: Bool)] = []
        let sections = charts.sections.filter { question.container == nil || $0.container == question.container }
        for chart in charts.pod where wanted(chart.data) {
            let usage = chart.data.id.hasSuffix(".cpu") || chart.data.id.hasSuffix(".memory")
            if usage, question.container != nil || charts.sections.count < 2 { continue }
            picked.append(("pod · \(chart.data.title)", chart.data, !usage))
        }
        for section in sections {
            for chart in section.charts where wanted(chart.data) {
                picked.append(("\(KubeMetricsText.name(section.container)) · \(chart.data.title)", chart.data, true))
            }
        }
        return picked
    }

    /// What the page sampled of the object while it showed it, on this
    /// context only: nil where nothing was (`KubeUsageRing`).
    private static func sampledCharts(
        _ question: MetricsQuestion, object: [String: Any]?, changes: KubeChartChanges, kubernetes: KubernetesModel, context: KubeContext, now: Date
    ) -> DrawnCharts? {
        let monitor = kubernetes.metrics
        // The same context name may since point at another cluster or user: its server, cluster and user must match.
        guard monitor.ringHolds(context) else { return nil }
        let ring = monitor.ring
        let range: KubeMetricsRange = question.range == .live ? .live : .sixHours
        let interval = max(15, Double(monitor.interval.components.seconds))
        func held(_ key: KubeUsageKey) -> Bool { !ring.points(key, now: now).isEmpty || !ring.folded(key, now: now).isEmpty }
        switch question.kind {
        case .pod, .container:
            guard let namespace = question.namespace, let name = question.name, let object, held(.pod(namespace: namespace, name: name)) else { return nil }
            let charts = KubePodCharts.build(
                namespace: namespace, pod: name, object: object, ring: ring, range: range, now: now, interval: interval, changes: changes)
            guard charts.hasSamples else { return nil }
            return DrawnCharts(caption: charts.caption, charts: podCharts(charts, question), notes: charts.notes)
        case .workload:
            guard let namespace = question.namespace, let name = question.name, let object,
                held(.workload(namespace: namespace, kind: question.workloadKind, name: name))
            else { return nil }
            let charts = KubeWorkloadCharts.build(
                KubeWorkloadCharts.Input(
                    namespace: namespace, kind: question.workloadKind, name: name, object: object, ring: ring, statuses: monitor.statuses, pods: [],
                    range: range, now: now, interval: interval, changes: changes))
            return charts.hasSamples ? drawn(charts, question) : nil
        case .node:
            guard let name = question.name, held(.node(name)) else { return nil }
            let charts = KubeNodeCharts.build(
                KubeNodeCharts.Input(
                    node: name, facts: KubeNodeFacts.of(object ?? [:]), ring: ring, statuses: monitor.statuses, pods: nil, top: nil, range: range, now: now,
                    interval: interval, changes: changes))
            return charts.hasSamples ? drawn(charts, question) : nil
        case .namespace:
            guard let namespace = question.namespace, held(.namespace(namespace)) else { return nil }
            let charts = KubeNamespaceCharts.build(
                KubeNamespaceCharts.Input(
                    namespace: namespace, ring: ring, statuses: monitor.statuses, quota: nil, byOwner: true, range: range, now: now, interval: interval,
                    changes: changes))
            return charts.hasSamples ? drawn(charts, question) : nil
        case .hpa:
            guard let namespace = question.namespace, let name = question.name else { return nil }
            let charts = KubeHPACharts.build(
                namespace: namespace, name: name, status: nil, statuses: monitor.statuses, range: range, now: now, interval: interval, changes: changes)
            return charts.hasSamples ? drawn(charts, question) : nil
        case .cluster:
            let points = ring.points(.cluster, now: now)
            guard !points.isEmpty else { return nil }
            let charts = KubeClusterCharts.sampled(points, allocatable: nil, capacity: nil, interval: interval, now: now)
            return DrawnCharts(
                caption: "Sampled from metrics-server while the Overview showed",
                charts: charts.filter { MetricsMeasure.of(chart: $0.data.id).map(question.measures.contains) == true }.map { ($0.data.title, $0.data, true) })
        case .pvc:
            return nil
        }
    }

    /// Drawn charts said: what, where from, each chart, the notes.
    private static func said(_ question: MetricsQuestion, _ drawn: DrawnCharts, now: Date) -> [String] {
        var lines = ["\(question.said), \(question.rangeSaid): \(drawn.caption)"]
        if let first = drawn.charts.first?.data { lines.append(KubeMetricsText.window(first, now: now)) }
        for chart in drawn.charts {
            var said = KubeMetricsText.chart(chart.data, label: chart.label, now: now)
            if !chart.seriesToo, said.count > 1 { said = said.filter { !$0.hasPrefix("  ") || $0.hasPrefix("  marked:") } }
            lines += said
        }
        if drawn.charts.isEmpty { lines.append("No chart of \(question.measures.map(\.rawValue).sorted().joined(separator: ", ")) here.") }
        return lines + drawn.notes.map(KubeMetricsText.note)
    }

    // MARK: Now only

    /// No Prometheus (or none that answered: `prometheusAsked`, its note
    /// says why), nothing sampled while shown: one metrics.k8s.io read
    /// now, against the spec's request and limit, a node's allocatable.
    private static func sampledNow(
        _ question: MetricsQuestion, object: [String: Any]?, _ target: Target, kubernetes: KubernetesModel, now: Date, prometheusAsked: Bool
    ) async throws -> (lines: [String], sampled: Bool) {
        let why = prometheusAsked ? "Prometheus gave no history (see the note)" : "no history without Prometheus"
        var lines = ["\(question.said), now only: \(why), and nothing was sampled while shown."]
        if question.kind == .pvc {
            return (lines + ["A claim's usage is kubelet's volume stats, which only Prometheus has: metrics-server has none."], false)
        }
        if question.kind == .hpa {
            guard let namespace = question.namespace, let name = question.name else { return (lines, false) }
            let client = target.client
            let path = "/apis/autoscaling/v2/namespaces/\(KubePath.segment(namespace))/horizontalpodautoscalers/\(KubePath.segment(name))"
            let status = try KubeMetricsReader.hpa(try await within { try await client.get(path).body })
            var said = "replicas \(status.current) (desired \(status.desired), \(status.min)–\(status.max))"
            if status.scalingLimited { said += ", scaling limited" }
            for metric in status.metrics.prefix(6) { said += "; \(KubeMetricsText.name(metric.name)) \(metric.current ?? "?") of target \(metric.target ?? "?")" }
            return (lines + [said + "."], true)
        }
        let source = target.context.settings.metrics ?? .auto
        let discovery = source == .none ? nil : try await discovery(for: target, kubernetes: kubernetes)
        let availability = KubeMetricsAvailability.of(discovery, source: source)
        guard availability == .served else { return (lines + [availability.reason ?? "metrics-server doesn't answer."], false) }
        let client = target.client
        func share(_ used: Double, _ total: Double?, _ what: String, _ format: (Double) -> String) -> String? {
            KubeMetricsFormat.percent(used, of: total).map { "\($0)% of \(what) \(format(total ?? 0))" }
        }
        func usage(_ used: KubeUsage, spec: KubePodCharts.Container?) -> String {
            let cpu = [share(used.cpu, spec?.cpuRequest, "request", KubeMetricsFormat.cpu), share(used.cpu, spec?.cpuLimit, "limit", KubeMetricsFormat.cpu)]
                .compactMap { $0 }
            let memory = [
                share(used.memory, spec?.memoryRequest, "request", KubeMetricsFormat.memory), share(used.memory, spec?.memoryLimit, "limit", KubeMetricsFormat.memory),
            ].compactMap { $0 }
            return "CPU \(KubeMetricsFormat.cpu(used.cpu))" + (cpu.isEmpty ? "" : " (\(cpu.joined(separator: ", ")))") + ", memory \(KubeMetricsFormat.memory(used.memory))"
                + (memory.isEmpty ? "" : " (\(memory.joined(separator: ", ")))")
        }
        func pods(_ scope: KubeScope, labels: String?, top: Int) async throws -> [String] {
            let read = try await within { try await KubeMetricsTarget.pods(scope, labels: labels).pods(client) }
            guard !read.pods.isEmpty else { return ["No pod samples: metrics-server samples running pods only."] }
            let total = read.pods.reduce(KubeUsage(cpu: 0, memory: 0)) { $0 + $1.total }
            var out = ["\(read.pods.count) pods: " + usage(total, spec: nil)]
            for pod in read.pods.sorted(by: { ($0.total.cpu, $1.id) > ($1.total.cpu, $0.id) }).prefix(top) {
                out.append("  \(KubeMetricsText.name(pod.id.name)): " + usage(pod.total, spec: nil))
            }
            if read.pods.count > top { out.append("  … \(read.pods.count - top) more pods, using less CPU.") }
            out.append(KubeMCPText.sampled(read.pods.map(\.timestamp), window: read.pods.first?.window, now: now))
            return out
        }
        switch question.kind {
        case .pod, .container:
            guard let namespace = question.namespace, let name = question.name else { return (lines, false) }
            let sample = try KubeMetricsReader.pod(
                try await within { try await client.get(KubeMetricsTarget.pod(namespace: namespace, name: name).path).body })
            let specs = KubePodCharts.containers(of: object ?? [:])
            for container in sample.containers.keys.sorted() where question.container == nil || question.container == container {
                let used = sample.containers[container] ?? KubeUsage(cpu: 0, memory: 0)
                lines.append("\(KubeMetricsText.name(container)): " + usage(used, spec: specs.first { $0.name == container }))
            }
            lines.append(KubeMCPText.sampled([sample.timestamp], window: sample.window, now: now))
        case .workload:
            guard let namespace = question.namespace else { return (lines, false) }
            let selector = KubeSelector.text((object?["spec"] as? [String: Any])?["selector"])
            guard let selector, !selector.isEmpty else { return (lines + ["Its selector can't be read: its pods can't be told."], false) }
            lines += try await pods(.namespace(namespace), labels: selector, top: 5)
        case .namespace:
            guard let namespace = question.namespace else { return (lines, false) }
            lines += try await pods(.namespace(namespace), labels: nil, top: 5)
        case .node:
            guard let name = question.name else { return (lines, false) }
            let sample = try KubeMetricsReader.node(try await within { try await client.get(KubeMetricsTarget.node(name).path).body })
            let facts = KubeNodeFacts.of(object ?? [:])
            let allocatable = KubePodCharts.Container(
                name: name, cpuRequest: nil, cpuLimit: facts.allocatable?.cpu, memoryRequest: nil, memoryLimit: facts.allocatable?.memory)
            lines.append(usage(sample.usage, spec: allocatable).replacingOccurrences(of: "% of limit", with: "% of allocatable"))
            lines.append(KubeMCPText.sampled([sample.timestamp], window: sample.window, now: now))
        case .cluster:
            let samples = try KubeMetricsReader.nodes(try await within { try await client.get(KubeMetricsTarget.nodes.path).body })
            let allocatable = (try? await within { try await KubeMetricsMonitor.allocatable(client) }) ?? [:]
            let used = samples.reduce(KubeUsage(cpu: 0, memory: 0)) { $0 + $1.usage }
            let total = allocatable.values.reduce(KubeUsage(cpu: 0, memory: 0), +)
            let spec = KubePodCharts.Container(
                name: "cluster", cpuLimit: allocatable.isEmpty ? nil : total.cpu, memoryLimit: allocatable.isEmpty ? nil : total.memory)
            lines.append("\(samples.count) nodes: " + usage(used, spec: spec).replacingOccurrences(of: "% of limit", with: "% of allocatable"))
            lines.append(KubeMCPText.sampled(samples.map(\.timestamp), window: samples.first?.window, now: now))
        case .pvc, .hpa:
            return (lines, false)
        }
        return (lines, true)
    }

    // MARK: Ask Why's usage

    /// How long Ask Why waits for its usage part before going without it
    /// (metrics.md 7: included when it is cheap) — a slow or paused
    /// Prometheus never holds the brief.
    static var usageLimit: Duration = .seconds(8)

    /// Ask Why's Usage part (metrics.md 7): a failing pod's failing
    /// container's CPU and memory over the last hour — or what was sampled
    /// while shown, or now — against its request and limit, its OOMKills
    /// marked (the whole pod's where no container is named); a
    /// Deployment's only where it is cheap (the context's Prometheus has
    /// the mixin's recording rules, or the page sampled it). Read as
    /// `k8s_metrics` reads (an agent's read, the background slot), from
    /// what the brief read already (`reads`: the object, its events), its
    /// words through `Secrets`. Nil where there is no number to give, or
    /// none within `usageLimit` — the read cancelled.
    static func usagePart(
        for ref: KubeObjectRef, context known: KubeContext? = nil, reads: KubeBriefReads? = nil, kubernetes: KubernetesModel, now: Date = Date()
    ) async -> AskAgentModel.Part? {
        guard let context = known ?? kubernetes.contexts.context(named: ref.context) else { return nil }
        let text = try? await KubeBriefRace.run(limit: usageLimit) { @MainActor in
            await usageText(for: ref, context: context, reads: reads, kubernetes: kubernetes, now: now)
        }
        return (text ?? nil).map { AskAgentModel.Part(title: "usage", text: $0) }
    }

    private static func usageText(for ref: KubeObjectRef, context: KubeContext, reads: KubeBriefReads?, kubernetes: KubernetesModel, now: Date) async -> String? {
        guard let namespace = ref.namespace else { return nil }
        var question = MetricsQuestion(kind: .pod, namespace: namespace, name: ref.name, range: .hour, measures: [.cpu, .memory])
        if ref.isPod {
            // The failing container's own lines: a sidecar's never crowd them out.
            if let failing = reads?.failingContainer, let object = reads?.object, KubePodCharts.containers(of: object).contains(where: { $0.name == failing }) {
                question.kind = .container
                question.container = failing
            }
        } else {
            guard ref.kind.group == "apps", ref.kind.kind == "Deployment" else { return nil }
            let rules = kubernetes.prometheus.agentProfile(for: ref.context)?.hasContainerRules == true && KubePrometheusUse.of(context.settings).isOn
            let sampled =
                kubernetes.metrics.ringHolds(context)
                && !kubernetes.metrics.ring.points(.workload(namespace: namespace, kind: "Deployment", name: ref.name), now: now).isEmpty
            guard rules || sampled else { return nil }
            question.kind = .workload
        }
        let target = Target(context: context, client: kubernetes.agentClient(for: context), scope: .namespace(namespace))
        guard let answer = try? await usage(question, target, kubernetes: kubernetes, now: now, known: reads), answer.source != .none else { return nil }
        return KubeMCPText.scrubbed(KubeMetricsText.bounded(answer.lines, budget: 2048))
    }

    // MARK: Sizing

    /// R1 once (metrics.md 2.10): seven days of usage, per pod, against the
    /// spec or the template — under its bounds. Prometheus only.
    private static func sizing(
        _ question: MetricsQuestion, _ read: KubePrometheusMonitor.AgentRead?, object: [String: Any]?, changes: KubeChartChanges,
        kubernetes: KubernetesModel, context: String, now: Date
    ) async -> [String] {
        guard let read else { return ["Sizing needs Prometheus: seven days of usage, which metrics-server doesn't keep."] }
        guard let namespace = question.namespace, let name = question.name else { return [] }
        let subject: KubeSizingSubject =
            question.kind == .workload ? .workload(namespace: namespace, kind: question.workloadKind, name: name) : .pod(namespace: namespace, name: name)
        let reading = await kubernetes.prometheus.agentSizing(KubeSizingRequest(context: context, subject: subject, asked: now), read)
        if let unavailable = reading.unavailable { return ["Sizing: \(unavailable)"] }
        if let refused = reading.refused { return ["Sizing isn't asked: \(refused)"] }
        var containers: [KubePodCharts.Container] = []
        var killed: [String: Date] = [:]
        if let object {
            if question.kind == .workload {
                let template = ((object["spec"] as? [String: Any])?["template"] as? [String: Any]) ?? [:]
                containers = KubePodCharts.containers(of: ["spec": template["spec"] ?? [:]])
            } else {
                containers = KubePodCharts.containers(of: object)
            }
        }
        for container in containers {
            if let last = container.lastTerminated, last.reason == "OOMKilled", let at = last.finishedAt { killed[container.name] = at }
        }
        for pod in changes.restarts.states?.pods ?? [] {
            for container in pod.containers where container.last?.reason == "OOMKilled" {
                if let at = container.last?.finishedAt { killed[container.name] = max(killed[container.name] ?? at, at) }
            }
        }
        let card = KubeSizingCard.of(reading, containers: containers, oomKilled: killed, now: now)
        var lines = [card.title + ". " + KubeSizingCard.advice]
        lines += card.summary.filter { question.container == nil || $0.hasPrefix("\(question.container ?? ""):") }.map { "  " + KubeMetricsText.name($0) }
        if card.rows.isEmpty { lines.append("  Nothing to size: Prometheus has no usage of it over the window.") }
        if let problem = reading.problem { lines.append("  Sizing couldn't be read whole: \(problem)") }
        return lines + reading.notes.map { "  " + KubeMetricsText.note($0) }
    }
}
