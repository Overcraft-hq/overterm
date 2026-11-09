import Foundation

// What a Metrics tab asks Prometheus (docs/design/kubernetes/metrics.md,
// 2.3–2.6, 2.8, 4.2, 4.3, 4.5, 4.6; stage M6): a pod's containers' CPU,
// memory and throttling, its network and restarts; a workload's pods
// (matched by name), its replicas and restarts; an HPA's replicas and
// metrics; a node's usage against what its active pods request, its pods,
// its conditions and its largest pods; and the OOMKills kube-state-metrics
// saw. Every series de-duplicated before it is summed (`max by` a gauge,
// `sum by` a counter's rate, kube-state-metrics' `max by` what identifies
// it), every literal escaped, every regex value escaped first. Pure.

/// Whose charts a tab's queries are.
enum KubeTabSubject: Hashable, Sendable {
    /// A pod: whether one of its containers has a CPU limit (throttling is
    /// asked only then), and whether it uses the node's network.
    case pod(namespace: String, name: String, cpuLimited: Bool, hostNetwork: Bool)
    /// A workload of `kind`, its pods matched by name; `hpa` the HPA that
    /// targets it. Nothing that moves with a scale (its replicas): the
    /// request is the monitor's key, and a new one is a new reading.
    case workload(namespace: String, kind: String, name: String, hpa: String?)
    case hpa(namespace: String, name: String)
    case node(String)

    /// The object it is, whatever its facts say: a request for the same
    /// object and span takes the last one's answers over while it is read
    /// (an HPA found, a limit added, a chart scrolled to).
    var object: String {
        switch self {
        case .pod(let namespace, let name, _, _): "pod/\(namespace)/\(name)"
        case .workload(let namespace, let kind, let name, _): "\(kind)/\(namespace)/\(name)"
        case .hpa(let namespace, let name): "hpa/\(namespace)/\(name)"
        case .node(let name): "node/\(name)"
        }
    }
}

/// A family of a tab's charts: what one or two queries answer.
enum KubeTabFamily: String, Hashable, Sendable, CaseIterable {
    case cpu, memory, throttling, network, restarts, oom, replicas, hpa, hpaMetrics, nodePods, conditions, topCPU, topMemory
    /// C1's peak band (24h and longer) and C2's RSS: a pod's, Prometheus' forms only.
    case cpuPeak, rss

    /// The families with no sampled form: read from Prometheus in Live too.
    static let prometheusOnly: Set<KubeTabFamily> = [.throttling, .network, .restarts, .oom]
}

/// What a tab wants of Prometheus: whose, over which range or window, which families.
struct KubeTabRequest: Hashable, Sendable {
    enum Span: Hashable, Sendable {
        /// A range ending now, refreshed.
        case range(KubeMetricsRange)
        /// A window: a zoom, Custom, a marker's ± 30 minutes — never refreshed.
        case window(KubeChartWindow)
    }

    var subject: KubeTabSubject
    var span: Span
    var families: Set<KubeTabFamily>

    /// Another request's answers stand for this one's until it is read:
    /// the same object over the same span, only its facts or families changed.
    func carries(from other: KubeTabRequest) -> Bool { other != self && other.subject.object == subject.object && other.span == span }

    /// Its span as Prometheus is asked it, the scrape the profile read.
    func resolve(scrape: TimeInterval, now: Date) -> KubePromSpan {
        switch span {
        case .range(let range): KubeMetricsSpan.of(range, scrape: scrape, now: now)
        case .window(let window): KubeMetricsSpan.of(window, scrape: scrape)
        }
    }

    /// What the cache keys its answers' range by.
    var cacheRange: String {
        switch span {
        case .range(let range): range.rawValue
        case .window(let window): "\(Int(window.start.timeIntervalSince1970))-\(Int(window.end.timeIntervalSince1970))"
        }
    }
}

/// One query of a tab: its id (what the builder reads its answer by),
/// its family, instant or over the span.
struct KubeTabQuery: Hashable, Sendable {
    var id: String
    var family: KubeTabFamily
    var promql: String
    var instant = false
}

/// A tab's queries for a span, and what isn't asked and why.
struct KubeTabPlan: Equatable, Sendable {
    var queries: [KubeTabQuery] = []
    /// A family not asked: why (its sentence).
    var refused: [KubeTabFamily: String] = [:]
    /// The form the usage lines are read in.
    var tier: KubePromTier = .raw
    /// The profile's footnotes (kube-state-metrics old or missing…).
    var notes: [String] = []
}

enum KubeTabQueries {
    /// The safe alphabet of a generated name's suffix (Kubernetes').
    static let alphabet = "[bcdfghjklmnpqrstvwxz2456789]"

    /// A workload's pods by name (§4.5's third tier, "pods matched by name"):
    /// a Deployment's `<name>-<hash>-<5>`, a StatefulSet's `<name>-<n>`, a
    /// DaemonSet's, a ReplicaSet's or a Job's `<name>-<5>`. Escaped as a regex.
    static func podPattern(kind: String, name: String) -> String {
        let base = KubePromQL.regexLiteral(name)
        switch kind {
        case "Deployment": return "\(base)-\(alphabet){1,10}-\(alphabet){5}"
        case "StatefulSet": return "\(base)-[0-9]+"
        default: return "\(base)-\(alphabet){5}"
        }
    }

    /// `pod=~"…"`, its value a PromQL string.
    static func podMatcher(kind: String, name: String) -> String {
        "pod=~\"" + KubePromQL.literal(podPattern(kind: kind, name: name)) + "\""
    }

    /// One arm of a union, tagged `overterm_s` (a label of Overterm's: `__`
    /// names are Prometheus' own, and front ends may drop them).
    static func tagged(_ query: String, _ tag: String) -> String {
        "label_replace(\(query),\"overterm_s\",\"\(tag)\",\"\",\"\")"
    }

    static func union(_ arms: [(String, String)]) -> String { arms.map { tagged($0.0, $0.1) }.joined(separator: " or ") }

    /// A `,`-joined list of matchers, empty parts left out.
    static func joined(_ parts: [String]) -> String { parts.filter { !$0.isEmpty }.joined(separator: ",") }

    /// The usage lines' tier: a pod's, a workload's raw cAdvisor over an
    /// hour or less (one object's series are cheap, and a 5-minute rule
    /// would smooth a spike away); the mixin's rules past it, where they are.
    static func tier(_ span: KubePromSpan, profile: KubePromProfile) -> KubePromTier {
        span.end.timeIntervalSince(span.start) > 3600 && profile.hasContainerRules ? .rules : .raw
    }

    static func plan(_ request: KubeTabRequest, span: KubePromSpan, profile: KubePromProfile) -> KubeTabPlan {
        var plan = KubeTabPlan()
        let window = KubePromQL.duration(KubeRateWindow.of(step: span.step, scrape: profile.scrapeInterval))
        let step = KubePromQL.duration(span.step)
        // A gauge keeps its peaks once a step holds several scrapes: the spike before an OOM survives.
        let peaks = span.step >= 300
        func gauge(_ selector: String) -> String { peaks ? "max_over_time(\(selector)[\(step)])" : selector }
        let ksm = profile.ksmMatcher
        let wanted = request.families
        func add(_ id: String, _ family: KubeTabFamily, _ promql: String, instant: Bool = false) {
            guard wanted.contains(family) else { return }
            plan.queries.append(KubeTabQuery(id: id, family: family, promql: promql, instant: instant))
        }
        func refuse(_ family: KubeTabFamily, _ why: String) {
            if wanted.contains(family) { plan.refused[family] = why }
        }
        if profile.ksmMissing {
            plan.notes.append(KubeChartEmpty.ksmMissing.sentence)
        } else if profile.ksmMajor == 1 {
            plan.notes.append(KubeChartEmpty.ksmOld.sentence)
        }
        let ksmFamilies: [KubeTabFamily] = [.restarts, .oom, .replicas, .hpa, .hpaMetrics, .nodePods, .conditions]
        if profile.ksmMissing { for family in ksmFamilies { refuse(family, KubeChartEmpty.ksmMissing.sentence) } }
        let usesKSM = !profile.ksmMissing

        let previous = "offset \(step)"
        /// What a counter of kube-state-metrics' rose by since the step
        /// before, a container's: its value against its own a step back —
        /// never a window one step wide, which since Prometheus 3 (windows
        /// left-open) holds one sample at a scrape-sized step and counts
        /// nothing, and at longer steps misses the rise across each
        /// boundary; nor a subquery, at the server's evaluation interval.
        func rose(_ selector: String) -> String {
            "clamp_min(max by (namespace,pod,container)(\(selector)) - max by (namespace,pod,container)(\(selector) \(previous)), 0)"
        }
        let restartsSelector = { (scope: String) in "kube_pod_container_status_restarts_total{\(joined([ksm, scope]))}" }
        /// Restarts per step, over every container of `scope`'s pods.
        func restarts(_ scope: String) -> String { "sum(\(rose(restartsSelector(scope))))" }
        /// The steps a container restarted after an OOMKill (kube-state-metrics
        /// says only the last reason, never when: a marker on the step), and
        /// cAdvisor's own OOM events where it has them — a counter a container
        /// instance, so its increase over the step and a scrape (a window
        /// that always holds two samples; a marker a run of steps, so the
        /// overlap marks nothing twice).
        func ooms(_ scope: String, by: String) -> String {
            var query =
                "max by (\(by))((\(rose(restartsSelector(scope))) > 0)"
                + " and on(namespace,pod,container) (kube_pod_container_status_last_terminated_reason{\(joined([ksm, "reason=\"OOMKilled\"", scope]))} == 1))"
            if profile.mayHave("container_oom_events_total") {
                let window = KubePromQL.duration(span.step + profile.scrapeInterval)
                query += " or max by (\(by))(increase(container_oom_events_total{\(joined([profile.cadvisorMatchers, scope]))}[\(window)]) > 0)"
            }
            return query
        }

        switch request.subject {
        case .pod(let namespace, let name, let cpuLimited, let hostNetwork):
            let scope = KubePromQL.matchers([("namespace", namespace), ("pod", name)])
            plan.tier = tier(span, profile: profile)
            if plan.tier == .rules, let rule = profile.containerCPURule {
                let rules = joined([scope, #"container!="""#, #"container!="POD""#])
                add("cpu", .cpu, "max by (container)(\(rule){\(rules)})")
                add("memory", .memory, "max by (container)(\(gauge("\(KubePromProfile.containerMemoryRule){\(rules)}")))")
            } else {
                add("cpu", .cpu, "sum by (container)(rate(container_cpu_usage_seconds_total{\(joined([profile.cadvisorMatchers, scope]))}[\(window)]))")
                add("memory", .memory, "max by (container)(\(gauge("container_memory_working_set_bytes{\(joined([profile.cadvisorMatchers, scope]))}")))")
            }
            // C1's peak band: a step's highest short rate, from 24h on — a 5-minute
            // average there smooths a spike away. One pod's subquery, at a
            // resolution of a scrape (a minute at least).
            if span.end.timeIntervalSince(span.start) >= 86400, KubeQueryCost.subquery(.pod, profile: profile).sentence == nil {
                let short = KubePromQL.duration(4 * profile.scrapeInterval)
                let resolution = KubePromQL.duration(max(profile.scrapeInterval, 60))
                add(
                    "cpuPeak", .cpuPeak,
                    "max_over_time(sum by (container)(rate(container_cpu_usage_seconds_total{\(joined([profile.cadvisorMatchers, scope]))}[\(short)]))[\(step):\(resolution)])")
            }
            // C2's RSS, a legend toggle off by default; one series a container.
            if profile.mayHave("container_memory_rss") {
                add("rss", .rss, "max by (container)(\(gauge("container_memory_rss{\(joined([profile.cadvisorMatchers, scope]))}")))")
            }
            if !profile.hasThrottling {
                refuse(.throttling, KubeChartEmpty.noThrottling.sentence)
            } else if cpuLimited {
                // Increases over at least 5 minutes: a period counter's few samples otherwise.
                let throttled = KubePromQL.duration(max(KubeRateWindow.of(step: span.step, scrape: profile.scrapeInterval), 300))
                let selector = joined([profile.cadvisorMatchers, scope])
                add(
                    "throttling", .throttling,
                    "sum by (container)(increase(container_cpu_cfs_throttled_periods_total{\(selector)}[\(throttled)]))"
                        + " / sum by (container)(increase(container_cpu_cfs_periods_total{\(selector)}[\(throttled)]))")
            }
            if hostNetwork {
                refuse(.network, "This pod uses the node's network; its traffic is the node's.")
            } else {
                // The sandbox's: no container filter (containerd labels it container="").
                let selector = joined([profile.cadvisorPins, scope])
                add(
                    "network", .network,
                    union([
                        ("sum(rate(container_network_receive_bytes_total{\(selector)}[\(window)]))", "rx"),
                        ("sum(rate(container_network_transmit_bytes_total{\(selector)}[\(window)]))", "tx"),
                        (
                            "sum(rate({\(joined([#"__name__=~"container_network_(receive|transmit)_packets_dropped_total""#, selector]))}[\(window)]))",
                            "drops"
                        ),
                    ]))
            }
            if usesKSM {
                add("restarts", .restarts, restarts(scope))
                add("oom", .oom, ooms(scope, by: "container"))
            }

        case .workload(let namespace, let kind, let name, let hpa):
            let scope = joined([KubePromQL.matchers([("namespace", namespace)]), podMatcher(kind: kind, name: name)])
            plan.tier = tier(span, profile: profile)
            if plan.tier == .rules, let rule = profile.containerCPURule {
                let rules = joined([scope, #"container!="""#, #"container!="POD""#])
                add("cpu", .cpu, "sum by (pod)(max by (pod,container)(\(rule){\(rules)}))")
                add("memory", .memory, "sum by (pod)(max by (pod,container)(\(gauge("\(KubePromProfile.containerMemoryRule){\(rules)}"))))")
            } else {
                let selector = joined([profile.cadvisorMatchers, scope])
                add("cpu", .cpu, "sum by (pod)(sum by (namespace,pod,container)(rate(container_cpu_usage_seconds_total{\(selector)}[\(window)])))")
                add("memory", .memory, "sum by (pod)(max by (namespace,pod,container)(\(gauge("container_memory_working_set_bytes{\(selector)}"))))")
            }
            if usesKSM {
                add("restarts", .restarts, restarts(scope))
                add("oom", .oom, ooms(scope, by: "pod,container"))
                if let replicas = replicas(kind: kind, namespace: namespace, name: name, ksm: ksm) { add("replicas", .replicas, replicas) }
                if let hpa { hpaQueries(namespace: namespace, name: hpa, profile: profile, add: add, refuse: refuse) }
            }

        case .hpa(let namespace, let name):
            if usesKSM { hpaQueries(namespace: namespace, name: name, profile: profile, add: add, refuse: refuse) }

        case .node(let node):
            let label: KubePromProfile.NodeLabel? = profile.known ? profile.nodeLabel : .node
            let request = KubePromQL.requestsOnNode(node, profile: profile)
            if let label {
                let selector = joined([profile.cadvisorMatchers, KubePromQL.matchers([(label.rawValue, node)])])
                let cpu = "sum(sum by (namespace,pod,container)(rate(container_cpu_usage_seconds_total{\(selector)}[\(window)])))"
                let memory = "sum(max by (namespace,pod,container)(\(gauge("container_memory_working_set_bytes{\(selector)}"))))"
                add("cpu", .cpu, request.map { union([(cpu, "usage"), ($0.cpu, "request")]) } ?? cpu)
                add("memory", .memory, request.map { union([(memory, "usage"), ($0.memory, "request")]) } ?? memory)
                add("topCPU", .topCPU, "sum by (namespace,pod)(rate(container_cpu_usage_seconds_total{\(selector)}[\(window)]))")
                add("topMemory", .topMemory, "sum by (namespace,pod)(max by (namespace,pod,container)(\(gauge("container_memory_working_set_bytes{\(selector)}"))))")
            } else {
                let why = "cAdvisor's series here name no node (neither node nor instance): a node's usage can't be told apart."
                for family in [KubeTabFamily.cpu, .memory, .topCPU, .topMemory] { refuse(family, why) }
            }
            if usesKSM {
                let pinned = joined([ksm, KubePromQL.matchers([("node", node)])])
                add("pods", .nodePods, "count(max by (namespace,pod)(kube_pod_info{\(pinned)}) * on(namespace,pod) group_left() \(KubePromQL.active(profile: profile)))")
                add(
                    "conditions", .conditions,
                    "max by (condition)(kube_node_status_condition{\(joined([pinned, #"condition=~"MemoryPressure|DiskPressure|PIDPressure""#, #"status="true""#]))}) == 1"
                        + " or label_replace(max(kube_node_spec_unschedulable{\(pinned)}) == 1,\"condition\",\"Unschedulable\",\"\",\"\")")
            }
        }
        return plan
    }

    /// A workload's replicas from kube-state-metrics, its kind's own names,
    /// each `max`ed (two replicas of it scrape the same).
    static func replicas(kind: String, namespace: String, name: String, ksm: String) -> String? {
        func of(_ metric: String, _ label: String) -> String {
            "max(\(metric){\(joined([ksm, KubePromQL.matchers([("namespace", namespace), (label, name)])]))})"
        }
        switch kind {
        case "Deployment":
            return union([
                (of("kube_deployment_spec_replicas", "deployment"), "desired"), (of("kube_deployment_status_replicas_available", "deployment"), "available"),
                (of("kube_deployment_status_replicas_unavailable", "deployment"), "unavailable"),
            ])
        case "StatefulSet":
            return union([(of("kube_statefulset_replicas", "statefulset"), "desired"), (of("kube_statefulset_status_replicas_ready", "statefulset"), "available")])
        case "DaemonSet":
            return union([
                (of("kube_daemonset_status_desired_number_scheduled", "daemonset"), "desired"), (of("kube_daemonset_status_number_available", "daemonset"), "available"),
                (of("kube_daemonset_status_number_unavailable", "daemonset"), "unavailable"),
            ])
        case "ReplicaSet":
            return union([(of("kube_replicaset_spec_replicas", "replicaset"), "desired"), (of("kube_replicaset_status_ready_replicas", "replicaset"), "available")])
        case "Job":
            return union([
                (of("kube_job_status_active", "job_name"), "active"), (of("kube_job_status_succeeded", "job_name"), "succeeded"),
                (of("kube_job_status_failed", "job_name"), "failed"),
            ])
        default:
            return nil
        }
    }

    /// An HPA's replicas and its metrics against their targets — the 1.x
    /// names (`kube_hpa_*`, label `hpa`) where kube-state-metrics is older.
    static func hpaQueries(
        namespace: String, name: String, profile: KubePromProfile, add: (String, KubeTabFamily, String, Bool) -> Void, refuse: (KubeTabFamily, String) -> Void
    ) {
        let old = profile.ksmMajor == 1
        let prefix = old ? "kube_hpa" : "kube_horizontalpodautoscaler"
        let selector = joined([profile.ksmMatcher, KubePromQL.matchers([("namespace", namespace), (old ? "hpa" : "horizontalpodautoscaler", name)])])
        func of(_ suffix: String) -> String { "max(\(prefix)_\(suffix){\(selector)})" }
        add(
            "hpa", .hpa,
            union([
                (of("status_current_replicas"), "current"), (of("status_desired_replicas"), "desired"), (of("spec_min_replicas"), "min"),
                (of("spec_max_replicas"), "max"),
            ]), false)
        if !old, profile.mayHave("kube_horizontalpodautoscaler_status_target_metric") {
            add(
                "hpaMetrics", .hpaMetrics,
                union([
                    ("max by (metric_name,metric_target_type)(kube_horizontalpodautoscaler_status_target_metric{\(selector)})", "current"),
                    ("max by (metric_name,metric_target_type)(kube_horizontalpodautoscaler_spec_target_metric{\(selector)})", "target"),
                ]), false)
        } else {
            refuse(.hpaMetrics, "kube-state-metrics before 2.10 doesn't report an HPA's metrics against their targets.")
        }
    }
}

extension KubePromQL {
    /// What a node's active pods request, CPU and memory — kube-state-metrics
    /// 2.x labels each request with its pod's node; nil without it.
    static func requestsOnNode(_ node: String, profile: KubePromProfile) -> (cpu: String, memory: String)? {
        guard !profile.ksmMissing else { return nil }
        let pinned = KubeTabQueries.joined([profile.ksmMatcher, matchers([("node", node)])])
        func of(_ resource: String) -> String {
            let selector =
                profile.ksmMajor == 1
                ? "kube_pod_container_resource_requests_\(resource == "cpu" ? "cpu_cores" : "memory_bytes"){\(pinned)}"
                : "kube_pod_container_resource_requests{\(KubeTabQueries.joined([pinned, matchers([("resource", resource)])]))}"
            return "sum(max by (namespace,pod,container,node)(\(selector)) * on(namespace,pod) group_left() \(active(profile: profile)))"
        }
        return (of("cpu"), of("memory"))
    }
}

extension KubePromProfile {
    /// cAdvisor's path and job pins alone, without the container filters —
    /// a pod's network belongs to its sandbox, labelled `container=""`.
    var cadvisorPins: String {
        var matchers: [String] = []
        if let cadvisorPath { matchers.append("metrics_path=\"\(KubePromQL.literal(cadvisorPath))\"") }
        if cadvisorJobPinned, let cadvisorJob { matchers.append("job=\"\(KubePromQL.literal(cadvisorJob))\"") }
        return matchers.joined(separator: ",")
    }
}
