import Foundation

// What a Metrics tab asks Prometheus (docs/design/kubernetes/metrics.md,
// 2.3–2.8, 4.2, 4.3, 4.5, 4.6; stages M6, M7): a pod's containers' CPU,
// memory and throttling, its network and restarts; a workload's pods —
// chosen by owner (the mixin's workload rule, else kube-state-metrics'
// owners, else their names) — in total, its top five (ranked first, one
// instant query a measure) and by revision, its replicas and restarts; an
// HPA's replicas and metrics; a node's usage against what its active pods
// request, its pods, its conditions and its largest pods; a namespace's
// usage in total and its top eight workloads, its pods by phase, its quota
// and what it requests but leaves idle; and the OOMKills kube-state-metrics
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
    /// A namespace: its workloads' usage, its pods by phase, its quota.
    case namespace(String)

    /// The object it is, whatever its facts say: a request for the same
    /// object and span takes the last one's answers over while it is read
    /// (an HPA found, a limit added, a chart scrolled to).
    var object: String {
        switch self {
        case .pod(let namespace, let name, _, _): "pod/\(namespace)/\(name)"
        case .workload(let namespace, let kind, let name, _): "\(kind)/\(namespace)/\(name)"
        case .hpa(let namespace, let name): "hpa/\(namespace)/\(name)"
        case .node(let name): "node/\(name)"
        case .namespace(let name): "namespace/\(name)"
        }
    }
}

/// A family of a tab's charts: what one or two queries answer.
enum KubeTabFamily: String, Hashable, Sendable, CaseIterable {
    case cpu, memory, throttling, network, restarts, oom, replicas, hpa, hpaMetrics, nodePods, conditions, topCPU, topMemory
    /// C1's peak band (24h and longer) and C2's RSS: a pod's, Prometheus' forms only.
    case cpuPeak, rss
    /// W3 over Prometheus (a Deployment's ReplicaSets); a namespace's pods by
    /// phase (N4), its ResourceQuota over time, what it requests but leaves idle (N3).
    case revisions, phases, quota, idle
    /// C4: a container's ephemeral storage (cAdvisor's filesystem use) against its limit (M8).
    case fs
    /// K6 and K7: a node's disks, used against size a mount, and its
    /// network — node-exporter's, mapped to the node by `node_uname_info` (M8b).
    case disks, nodeNetwork
    /// G1–G3: the GPUs' utilisation, framebuffer memory, power and
    /// temperature — DCGM exporter's (M8c); asked only of an object with GPUs.
    case gpu

    /// The families with no sampled form: read from Prometheus in Live too.
    static let prometheusOnly: Set<KubeTabFamily> = [.throttling, .network, .restarts, .oom, .fs, .disks, .nodeNetwork, .gpu]
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
    /// An instant query's time: the span's end (a window's, not now).
    var at: Date?
}

/// How a workload's pods — a namespace's pods' workloads — are told
/// (metrics.md 4.5, in tier order): the mixin's workload rule,
/// kube-state-metrics' owners (a Deployment's through its ReplicaSets), or
/// the pods' names.
enum KubeTabSelection: String, Equatable, Sendable {
    case rule, owner, name

    var title: String {
        switch self {
        case .rule: "by owner (recording rules)"
        case .owner: "by owner"
        case .name: "pods matched by name"
        }
    }
}

/// A tab's top N, ranked by one instant query a measure over the span
/// (metrics.md 4.5: `topk` inside a range query wanders from step to
/// step), the range queries then asked for those names alone. Kept with
/// what it ranked; ranked again on another span, another tier or
/// selection, and every 10 refreshes.
struct KubeTabRanking: Equatable, Sendable {
    /// What it ranked: the object, the span, the selection and the tier.
    var key: String
    /// Each measure's (`cpu`, `memory`) names, largest first: a workload's
    /// pods, a namespace's workloads as `Kind/name`.
    var names: [String: [String]] = [:]
    /// How many readings have used it since it was ranked.
    var refreshes = 0
    /// What it says of itself ("ranked by the last 24h").
    var notes: [String] = []
    /// The measures it settled: ranked, or not to be (too costly) — one
    /// that failed is in neither, and asked again next time.
    var covered: Set<String> = []

    static let kept = 10

    var isStale: Bool { refreshes >= Self.kept }
}

/// The instant queries a ranking asks: ids `cpu` and `memory`.
struct KubeTabRankPlan: Equatable, Sendable {
    var key: String
    var queries: [KubeTabQuery]
    var notes: [String] = []
    /// A raw workload's pods to count first (`KubeTabCount`): the queries
    /// then are what an allowed count would ask.
    var count: KubeTabQuery?
    /// The measures not ranked, on purpose: too costly.
    var skipped: Set<String> = []
}

/// A raw workload's cAdvisor CPU series and its pods, counted before it is
/// ranked (`count by (pod)`): the CPU ranking's samples estimate, the memory
/// ranking's subquery gate. Nil fields: the count failed.
struct KubeTabCount: Equatable, Sendable {
    var series: Int?
    var pods: Int?

    static let failed = KubeTabCount()

    /// The count's answer: a series a pod, its value that pod's series.
    static func of(_ answer: [KubeSeries]) -> KubeTabCount {
        let values = answer.compactMap { $0.points.last?.value }.filter(\.isFinite)
        return KubeTabCount(series: Int(values.reduce(0, +).rounded()), pods: answer.count)
    }
}

/// A tab's queries for a span, and what isn't asked and why.
struct KubeTabPlan: Equatable, Sendable {
    var queries: [KubeTabQuery] = []
    /// A family not asked: why (its sentence).
    var refused: [KubeTabFamily: String] = [:]
    /// The form the usage lines are read in.
    var tier: KubePromTier = .raw
    /// How a workload's (a namespace's) pods were told; nil, not asked.
    var selection: KubeTabSelection?
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

    /// The longest prefix of a generated name Kubernetes keeps (63 less its 5 random).
    static let generatedPrefix = 58

    /// `pod=~"<name>-.+"`: a cheap prefilter beside an owner join, so a raw
    /// read covers the workload's pods' series, not the whole namespace's.
    /// Every pod a workload makes starts with its name and a dash — a
    /// Deployment's through its ReplicaSet's — cut where Kubernetes cuts a
    /// generated name. A neighbour that extends the name (db, db-extra)
    /// passes it; the join leaves it out.
    static func podPrefixMatcher(name: String) -> String {
        let prefix = String((name + "-").prefix(generatedPrefix))
        return "pod=~\"" + KubePromQL.literal(KubePromQL.regexLiteral(prefix) + ".+") + "\""
    }

    /// A workload's raw scope: its namespace and its pods' names — the
    /// pattern where names are the selection, else the prefix before the join.
    static func workloadScope(namespace: String, kind: String, name: String, selection: KubeTabSelection) -> String {
        joined([KubePromQL.matchers([("namespace", namespace)]), selection == .name ? podMatcher(kind: kind, name: name) : podPrefixMatcher(name: name)])
    }

    /// Why raw cAdvisor across `namespace` isn't read over `span`: too many
    /// series (`KubeQueryCost`), or a count that failed this time; nil, read.
    static func namespaceRawRefusal(_ namespace: String, span: TimeInterval, profile: KubePromProfile) -> String? {
        if profile.uncounted.contains(namespace) {
            return "\(namespace)'s container series couldn't be counted, so its raw usage isn't read: counted again at the next refresh."
        }
        return KubeQueryCost.raw(.namespace(namespace, series: profile.namespaceSeries[namespace]), span: span, profile: profile).sentence
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

    /// A tab's queries over `span`; a workload's and a namespace's top N
    /// for the names `ranking` holds (none yet: totals only).
    static func plan(_ request: KubeTabRequest, span: KubePromSpan, profile: KubePromProfile, ranking: KubeTabRanking? = nil) -> KubeTabPlan {
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
            plan.queries.append(KubeTabQuery(id: id, family: family, promql: promql, instant: instant, at: instant ? span.end : nil))
        }
        func refuse(_ family: KubeTabFamily, _ why: String) {
            if wanted.contains(family) { plan.refused[family] = why }
        }
        if profile.ksmMissing {
            plan.notes.append(KubeChartEmpty.ksmMissing.sentence)
        } else if profile.ksmMajor == 1 {
            plan.notes.append(KubeChartEmpty.ksmOld.sentence)
        }
        let ksmFamilies: [KubeTabFamily] = [.restarts, .oom, .replicas, .hpa, .hpaMetrics, .nodePods, .conditions, .phases, .quota, .idle]
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
        /// Restarts per step, over every container of `scope`'s pods (`owned`: of a workload's).
        func restarts(_ scope: String, owned: (String) -> String = { $0 }) -> String { "sum(\(owned(rose(restartsSelector(scope)))))" }
        /// The steps a container restarted after an OOMKill (kube-state-metrics
        /// says only the last reason, never when: a marker on the step), and
        /// cAdvisor's own OOM events where it has them — a counter a container
        /// instance, so its increase over the step and a scrape (a window
        /// that always holds two samples; a marker a run of steps, so the
        /// overlap marks nothing twice).
        func ooms(_ scope: String, by: String, owned: (String) -> String = { $0 }) -> String {
            let restarted = "(\(rose(restartsSelector(scope))) > 0)"
            let reason = "kube_pod_container_status_last_terminated_reason{\(joined([ksm, "reason=\"OOMKilled\"", scope]))} == 1"
            var query = "max by (\(by))(\(owned("\(restarted) and on(namespace,pod,container) (\(reason))")))"
            if profile.mayHave("container_oom_events_total") {
                let window = KubePromQL.duration(span.step + profile.scrapeInterval)
                let events = "increase(container_oom_events_total{\(joined([profile.cadvisorMatchers, scope]))}[\(window)]) > 0"
                query += " or max by (\(by))(\(owned(events)))"
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
            // C4, only where the probe found cAdvisor's filesystem use (containerd's
            // kubelet usually has none): each container's, a device each once,
            // against its ephemeral-storage limit.
            if profile.known, !profile.has("container_fs_usage_bytes") {
                refuse(.fs, KubeChartEmpty.noContainerFS.sentence)
            } else {
                let selector = joined([profile.cadvisorMatchers, scope])
                var arms = [("sum by (container)(max by (container,device)(\(gauge("container_fs_usage_bytes{\(selector)}"))))", "usage")]
                if usesKSM, profile.ksmMajor != 1 {
                    arms.append(
                        ("max by (container)(kube_pod_container_resource_limits{\(joined([ksm, scope, #"resource="ephemeral_storage""#]))})", "limit"))
                }
                add("fs", .fs, union(arms))
            }
            if usesKSM {
                add("restarts", .restarts, restarts(scope))
                add("oom", .oom, ooms(scope, by: "container"))
            }
            if wanted.contains(.gpu), let dcgm = gpuLabels(profile, needsPods: true, refuse: refuse) {
                let scope = KubePromQL.matchers([(dcgm.namespace, namespace), (dcgm.pod, name)])
                add("gpu", .gpu, KubePromQL.gpus(scope, by: dcgm.container, profile: profile, gauge: gauge))
            }

        case .workload(let namespace, let kind, let name, let hpa):
            let selection = workloadSelection(kind: kind, profile: profile)
            plan.selection = selection
            let inNamespace = KubePromQL.matchers([("namespace", namespace)])
            let scope = workloadScope(namespace: namespace, kind: kind, name: name, selection: selection)
            let owner = ownerOf(kind: kind, namespace: namespace, name: name, selection: selection, profile: profile)
            /// `expression`'s series (by namespace, pod, …) of the workload's pods alone.
            func owned(_ expression: String, keeping labels: String = "") -> String {
                owner.map { "(\(expression)) * on(namespace,pod) group_left(\(labels)) \($0)" } ?? expression
            }
            plan.tier = tier(span, profile: profile)
            let usage = containerUsage(scope, tier: plan.tier, window: window, gauge: gauge, profile: profile)
            add("cpu", .cpu, "sum(\(owned(usage.cpu)))")
            add("memory", .memory, "sum(\(owned(usage.memory)))")
            // The top five by the ranking, asked by name: chosen by owner already.
            for (id, family) in [("cpu", KubeTabFamily.cpu), ("memory", .memory)] {
                guard let top = ranking?.names[id], !top.isEmpty else { continue }
                let named = containerUsage(joined([inNamespace, podsMatcher(top)]), tier: plan.tier, window: window, gauge: gauge, profile: profile)
                add(id + "Top", family, "sum by (pod)(\(id == "cpu" ? named.cpu : named.memory))")
            }
            // W3: a Deployment's ReplicaSets — kube-state-metrics' own where it
            // is the owner join, else read off the pods' names (`<replicaset>-<5>`).
            if kind == "Deployment" {
                if selection == .owner {
                    add("revisions", .revisions, "sum by (replicaset)(\(owned(usage.cpu, keeping: "replicaset")))")
                } else {
                    add("revisions", .revisions, "sum by (replicaset)(label_replace(\(owned(usage.cpu)),\"replicaset\",\"$1\",\"pod\",\"(.+)-\(alphabet){5}\"))")
                }
            }
            if usesKSM {
                add("restarts", .restarts, restarts(scope, owned: { owned($0) }))
                add("oom", .oom, ooms(scope, by: "pod,container", owned: { owned($0) }))
                if let replicas = replicas(kind: kind, namespace: namespace, name: name, ksm: ksm) { add("replicas", .replicas, replicas) }
                if let hpa { hpaQueries(namespace: namespace, name: hpa, profile: profile, add: add, refuse: refuse) }
            }
            // A workload's GPUs by pod: DCGM exporter's pod label is its own
            // (`exported_pod` past honor_labels), never kube-state-metrics',
            // so its pods are told by their names.
            if wanted.contains(.gpu), let dcgm = gpuLabels(profile, needsPods: true, refuse: refuse) {
                let scope = joined([
                    KubePromQL.matchers([(dcgm.namespace, namespace)]), "\(dcgm.pod)=~\"" + KubePromQL.literal(podPattern(kind: kind, name: name)) + "\"",
                ])
                add("gpu", .gpu, KubePromQL.gpus(scope, by: dcgm.pod, profile: profile, gauge: gauge))
            }

        case .namespace(let namespace):
            let inNamespace = KubePromQL.matchers([("namespace", namespace)])
            let selection = namespaceSelection(profile)
            plan.selection = selection
            plan.tier = profile.hasContainerRules ? .rules : .raw
            let length = span.end.timeIntervalSince(span.start)
            let rawRefusal = plan.tier == .raw ? namespaceRawRefusal(namespace, span: length, profile: profile) : nil
            if let why = rawRefusal {
                refuse(.cpu, why)
                refuse(.memory, why)
            } else {
                let usage = containerUsage(inNamespace, tier: plan.tier, window: window, gauge: gauge, profile: profile)
                add("cpu", .cpu, "sum(\(usage.cpu))")
                add("memory", .memory, "sum(\(usage.memory))")
                if let selection {
                    for (id, family) in [("cpu", KubeTabFamily.cpu), ("memory", .memory)] {
                        guard let top = ranking?.names[id], !top.isEmpty else { continue }
                        let owners = ownersIn(namespace: namespace, selection: selection, names: top, profile: profile)
                        add(id + "Top", family, "sum by (workload_type,workload)((\(id == "cpu" ? usage.cpu : usage.memory)) * on(namespace,pod) group_left(workload,workload_type) \(owners))")
                    }
                } else if usesKSM, wanted.contains(.cpu) || wanted.contains(.memory) {
                    plan.notes.append("kube-state-metrics has no pod owners here: the namespace's total, not by workload.")
                }
            }
            if usesKSM {
                let scoped = joined([ksm, inNamespace])
                add("phases", .phases, "sum by (phase)(max by (namespace,pod,phase)(kube_pod_status_phase{\(scoped)}) == 1)")
                if profile.mayHave("kube_resourcequota") {
                    add(
                        "quota", .quota,
                        "min by (resource,type)(max by (resourcequota,resource,type)(kube_resourcequota{\(joined([scoped, #"resource=~"requests.cpu|cpu|requests.memory|memory""#, #"type=~"hard|used""#]))}))"
                    )
                }
                // N3's chip: requested less used, its average over the range —
                // a subquery, so without recording rules only up to 24h, and
                // never where the raw usage it subtracts is refused.
                if let why = rawRefusal {
                    refuse(.idle, why)
                } else if plan.tier == .rules || length <= 86400 {
                    let usage = containerUsage(inNamespace, tier: plan.tier, window: window, gauge: { $0 }, profile: profile)
                    func idle(_ resource: String, _ used: String) -> String {
                        "avg_over_time((\(KubePromQL.requests(resource, namespace: namespace, profile: profile)) - sum(\(used)))[\(KubePromQL.duration(length)):\(step)])"
                    }
                    add("idle", .idle, union([(idle("cpu", usage.cpu), "cpu"), (idle("memory", usage.memory), "memory")]), instant: true)
                } else {
                    refuse(.idle, "What's requested but idle needs recording rules past 24h: pick 24h or less.")
                }
            }

        case .hpa(let namespace, let name):
            if usesKSM { hpaQueries(namespace: namespace, name: name, profile: profile, add: add, refuse: refuse) }

        case .node(let node):
            let label = nodeLabel(profile)
            let request = KubePromQL.requestsOnNode(node, profile: profile)
            if let label {
                let selector = joined([profile.cadvisorMatchers, KubePromQL.matchers([(label.rawValue, node)])])
                let cpu = "sum(sum by (namespace,pod,container)(rate(container_cpu_usage_seconds_total{\(selector)}[\(window)])))"
                let memory = "sum(max by (namespace,pod,container)(\(gauge("container_memory_working_set_bytes{\(selector)}"))))"
                add("cpu", .cpu, request.map { union([(cpu, "usage"), ($0.cpu, "request")]) } ?? cpu)
                // K2's node total (MemTotal − MemAvailable) where node-exporter maps to nodes.
                var memoryArms = [(memory, "usage")]
                if let request { memoryArms.append((request.memory, "request")) }
                if profile.nodeExporterMapped { memoryArms.append((KubePromQL.nodeTotalMemory(node), "total")) }
                add("memory", .memory, memoryArms.count > 1 ? union(memoryArms) : memory)
                add("topCPU", .topCPU, "sum by (namespace,pod)(rate(container_cpu_usage_seconds_total{\(selector)}[\(window)]))")
                add("topMemory", .topMemory, "sum by (namespace,pod)(max by (namespace,pod,container)(\(gauge("container_memory_working_set_bytes{\(selector)}"))))")
            } else {
                let why = "cAdvisor's series here name no node (neither node nor instance): a node's usage can't be told apart."
                for family in [KubeTabFamily.cpu, .memory, .topCPU, .topMemory] { refuse(family, why) }
            }
            if profile.known, !profile.nodeExporterMapped, wanted.contains(.memory) {
                plan.notes.append(KubeChartEmpty.nodeExporterUnmapped.sentence)
            }
            // K6, K7: node-exporter's, its instance mapped to the node by
            // `node_uname_info` (metrics.md decision 6) — never by host IP.
            if profile.known, !profile.nodeExporterMapped {
                refuse(.disks, KubeChartEmpty.nodeExporterUnmapped.sentence)
                refuse(.nodeNetwork, KubeChartEmpty.nodeExporterUnmapped.sentence)
            } else {
                if profile.mayHave(KubePromQL.nodeFilesystemMetric) {
                    add("disks", .disks, KubePromQL.nodeDisks(node))
                } else {
                    refuse(.disks, KubeChartEmpty.nodeExporterNoFilesystems.sentence)
                }
                if profile.mayHave(KubePromQL.nodeNetworkMetric) {
                    add("nodeNetwork", .nodeNetwork, KubePromQL.nodeNetwork(node, window: window))
                } else {
                    refuse(.nodeNetwork, KubeChartEmpty.nodeExporterNoNetwork.sentence)
                }
            }
            if wanted.contains(.gpu), let dcgm = gpuLabels(profile, needsPods: false, refuse: refuse) {
                if let label = dcgm.nodeLabel {
                    add("gpu", .gpu, KubePromQL.gpus(KubePromQL.matchers([(label, node)]), by: "\(dcgm.namespace),\(dcgm.pod)", profile: profile, gauge: gauge))
                } else {
                    refuse(.gpu, KubeChartEmpty.dcgmNoNode.sentence)
                }
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

    /// DCGM exporter's labels, where the GPUs can be asked of it: nil, not
    /// (said, unless nothing is known yet — then nothing is asked).
    static func gpuLabels(_ profile: KubePromProfile, needsPods: Bool, refuse: (KubeTabFamily, String) -> Void) -> KubePromProfile.DCGM? {
        guard profile.known else { return nil }
        guard profile.hasDCGM else {
            refuse(.gpu, KubeChartEmpty.noDCGM.sentence)
            return nil
        }
        guard let dcgm = profile.dcgm else {
            refuse(.gpu, KubeChartEmpty.dcgmUnread.sentence)
            return nil
        }
        if needsPods, !dcgm.namesPods {
            refuse(.gpu, KubeChartEmpty.dcgmNoPods.sentence)
            return nil
        }
        return dcgm
    }

    /// The label a node's cAdvisor series name it by: `node` until the
    /// profile says otherwise; none where they name no node (a node's
    /// usage, its top pods, refused). The charts ask this too, so that
    /// whether a group exists never hangs on what was read.
    static func nodeLabel(_ profile: KubePromProfile) -> KubePromProfile.NodeLabel? { profile.known ? profile.nodeLabel : .node }

    // MARK: Whose pods

    /// How a workload's pods are told: the mixin's rule (a Deployment's, a
    /// StatefulSet's, a DaemonSet's), else kube-state-metrics' owners, else names.
    static func workloadSelection(kind: String, profile: KubePromProfile) -> KubeTabSelection {
        if ["Deployment", "StatefulSet", "DaemonSet"].contains(kind), profile.has(KubePromProfile.workloadRule) { return .rule }
        if !profile.ksmMissing, profile.mayHave("kube_pod_owner"), kind != "Deployment" || profile.mayHave("kube_replicaset_owner") { return .owner }
        return .name
    }

    /// How a namespace's pods' workloads are told: the rule, the owners; nil, not at all.
    static func namespaceSelection(_ profile: KubePromProfile) -> KubeTabSelection? {
        if profile.has(KubePromProfile.workloadRule) { return .rule }
        if !profile.ksmMissing, profile.mayHave("kube_pod_owner"), profile.mayHave("kube_replicaset_owner") { return .owner }
        return nil
    }

    /// A workload's pods, 1 each by `(namespace, pod)` — a Deployment's
    /// raw join keeps each pod's `replicaset` (W3); nil by name (the
    /// selector's regex is the selection).
    static func ownerOf(kind: String, namespace: String, name: String, selection: KubeTabSelection, profile: KubePromProfile) -> String? {
        let ksm = profile.ksmMatcher
        switch selection {
        case .name:
            return nil
        case .rule:
            let matchers = KubePromQL.matchers([("namespace", namespace), ("workload", name), ("workload_type", kind.lowercased())])
            return "max by (namespace,pod)(\(KubePromProfile.workloadRule){\(matchers)})"
        case .owner where kind == "Deployment":
            let pods = joined([ksm, KubePromQL.matchers([("namespace", namespace), ("owner_kind", "ReplicaSet")])])
            let sets = joined([ksm, KubePromQL.matchers([("namespace", namespace), ("owner_kind", "Deployment"), ("owner_name", name)])])
            return "max by (namespace,pod,replicaset)(label_replace(kube_pod_owner{\(pods)},\"replicaset\",\"$1\",\"owner_name\",\"(.*)\")"
                + " * on(namespace,replicaset) group_left() max by (namespace,replicaset)(kube_replicaset_owner{\(sets)}))"
        case .owner:
            let pods = joined([ksm, KubePromQL.matchers([("namespace", namespace), ("owner_kind", kind), ("owner_name", name)])])
            return "max by (namespace,pod)(kube_pod_owner{\(pods)})"
        }
    }

    /// A namespace's pods, 1 each with their `workload` and `workload_type`
    /// (`names`: only those workloads, `Kind/name`) — the rule's, or
    /// kube-state-metrics' owners: a ReplicaSet's pods its Deployment's, a
    /// StatefulSet's, a DaemonSet's, a Job's their own. A pod of nothing is in "other".
    static func ownersIn(namespace: String, selection: KubeTabSelection, names: [String]? = nil, profile: KubePromProfile) -> String {
        let ksm = profile.ksmMatcher
        let inNamespace = KubePromQL.matchers([("namespace", namespace)])
        let picked = names.map { list -> String in
            let bare = Array(Set(list.map { $0.split(separator: "/", maxSplits: 1).last.map(String.init) ?? $0 })).sorted()
            return KubePromQL.literal(bare.map(KubePromQL.regexLiteral).joined(separator: "|"))
        }
        if selection == .rule {
            let filter = picked.map { "workload=~\"\($0)\"" } ?? ""
            return "max by (namespace,pod,workload,workload_type)(\(KubePromProfile.workloadRule){\(joined([inNamespace, filter]))})"
        }
        let filter = picked.map { "owner_name=~\"\($0)\"" } ?? ""
        let replicaSets = joined([ksm, inNamespace, #"owner_kind="ReplicaSet""#])
        let deployments = joined([ksm, inNamespace, #"owner_kind="Deployment""#, filter])
        let others = joined([ksm, inNamespace, #"owner_kind=~"StatefulSet|DaemonSet|Job""#, filter])
        let viaReplicaSets =
            "label_replace(label_replace(label_replace(kube_pod_owner{\(replicaSets)},\"replicaset\",\"$1\",\"owner_name\",\"(.*)\")"
            + " * on(namespace,replicaset) group_left(owner_name) max by (namespace,replicaset,owner_name)(kube_replicaset_owner{\(deployments)}),"
            + "\"workload\",\"$1\",\"owner_name\",\"(.*)\"),\"workload_type\",\"deployment\",\"\",\"\")"
        let direct = "label_replace(label_replace(kube_pod_owner{\(others)},\"workload\",\"$1\",\"owner_name\",\"(.*)\"),\"workload_type\",\"$1\",\"owner_kind\",\"(.*)\")"
        return "max by (namespace,pod,workload,workload_type)(\(viaReplicaSets) or \(direct))"
    }

    /// `workload_type` as a Kind: the rule writes it lower case.
    static func kindTitle(_ type: String) -> String {
        let kinds = ["deployment": "Deployment", "statefulset": "StatefulSet", "daemonset": "DaemonSet", "replicaset": "ReplicaSet", "job": "Job", "cronjob": "CronJob"]
        return kinds[type.lowercased()] ?? type
    }

    /// `pod=~"a|b"`: these pods exactly, each escaped as a regex, then as a string.
    static func podsMatcher(_ names: [String]) -> String {
        "pod=~\"" + KubePromQL.literal(names.map(KubePromQL.regexLiteral).joined(separator: "|")) + "\""
    }

    /// The containers' CPU and memory under `scope`, one series a container
    /// (by namespace, pod, container): the mixin's rules, or raw cAdvisor —
    /// a counter's rates summed, a gauge's highest.
    static func containerUsage(
        _ scope: String, tier: KubePromTier, window: String, gauge: (String) -> String, profile: KubePromProfile
    ) -> (cpu: String, memory: String) {
        if tier == .rules, let rule = profile.containerCPURule {
            let rules = joined([scope, #"container!="""#, #"container!="POD""#])
            return (
                "max by (namespace,pod,container)(\(rule){\(rules)})",
                "max by (namespace,pod,container)(\(gauge("\(KubePromProfile.containerMemoryRule){\(rules)}")))"
            )
        }
        let selector = joined([profile.cadvisorMatchers, scope])
        return (
            "sum by (namespace,pod,container)(rate(container_cpu_usage_seconds_total{\(selector)}[\(window)]))",
            "max by (namespace,pod,container)(\(gauge("container_memory_working_set_bytes{\(selector)}")))"
        )
    }

    // MARK: The top N

    /// A workload's top five pods, a namespace's top eight workloads.
    static func top(_ subject: KubeTabSubject) -> Int {
        if case .namespace = subject { return 8 }
        return 5
    }

    /// What a tab's ranking asks (metrics.md 4.5's first read): per measure,
    /// one instant `topk` at the span's end over the whole span — CPU the
    /// counter's rate over it (its increase: no subquery; at least four
    /// scrapes, or a short window holds one sample and ranks nothing), read
    /// raw only under `KubeQueryCost.rankingSamples` and else over the last
    /// 24h; memory the rules' average, or raw de-duplicated in a subquery,
    /// only over 24h at most and, for a workload, over at most 50 pods
    /// (`KubeQueryCost.subquery`). A raw workload's pods are counted first
    /// (`counted` nil: not yet — the plan's `count`, its queries as an
    /// allowed count would ask). Nil: the subject ranks nothing (or its usage isn't asked).
    static func ranking(_ request: KubeTabRequest, span: KubePromSpan, profile: KubePromProfile, counted: KubeTabCount? = nil) -> KubeTabRankPlan? {
        let length = span.end.timeIntervalSince(span.start)
        let step = KubePromQL.duration(span.step)
        let namespace: String
        let tier: KubePromTier
        let scope: String
        let by: String
        let joinedTo: String?
        let selection: KubeTabSelection
        let workload: Bool
        switch request.subject {
        case .workload(let ns, let kind, let name, _):
            namespace = ns
            selection = workloadSelection(kind: kind, profile: profile)
            tier = Self.tier(span, profile: profile)
            scope = workloadScope(namespace: ns, kind: kind, name: name, selection: selection)
            by = "pod"
            joinedTo = ownerOf(kind: kind, namespace: ns, name: name, selection: selection, profile: profile).map { "* on(namespace,pod) group_left() \($0)" }
            workload = true
        case .namespace(let ns):
            guard let picked = namespaceSelection(profile) else { return nil }
            namespace = ns
            selection = picked
            tier = profile.hasContainerRules ? .rules : .raw
            if tier == .raw, namespaceRawRefusal(ns, span: length, profile: profile) != nil { return nil }
            scope = KubePromQL.matchers([("namespace", ns)])
            by = "workload_type,workload"
            joinedTo = "* on(namespace,pod) group_left(workload,workload_type) \(ownersIn(namespace: ns, selection: picked, profile: profile))"
            workload = false
        default:
            return nil
        }
        let n = top(request.subject)
        var plan = KubeTabRankPlan(key: [request.subject.object, request.cacheRange, selection.rawValue, tier.rawValue].joined(separator: "|"), queries: [])
        func ranked(_ id: String, _ family: KubeTabFamily, _ byContainer: String) {
            guard request.families.contains(family) else { return }
            let owned = joinedTo.map { "(\(byContainer)) \($0)" } ?? byContainer
            plan.queries.append(KubeTabQuery(id: id, family: family, promql: "topk(\(n), sum by (\(by))(\(owned)))", instant: true, at: span.end))
        }
        if tier == .rules, let rule = profile.containerCPURule {
            let rules = joined([scope, #"container!="""#, #"container!="POD""#])
            let over = KubePromQL.duration(length)
            ranked("cpu", .cpu, "max by (namespace,pod,container)(avg_over_time(\(rule){\(rules)}[\(over)]))")
            ranked("memory", .memory, "max by (namespace,pod,container)(avg_over_time(\(KubePromProfile.containerMemoryRule){\(rules)}[\(over)]))")
        } else {
            let selector = joined([profile.cadvisorMatchers, scope])
            if workload, counted == nil, request.families.contains(.cpu) || request.families.contains(.memory) {
                plan.count = KubeTabQuery(id: "count", family: .cpu, promql: "count by (pod)(container_cpu_usage_seconds_total{\(selector)})", instant: true, at: span.end)
            }
            let series = (workload ? counted?.series : nil) ?? profile.namespaceSeries[namespace] ?? profile.count(KubePromProfile.cpuMetric) ?? 0
            let (cpuSpan, cpuNote) = KubeQueryCost.rankingSpan(series: series, span: length, scrape: profile.scrapeInterval)
            let cpuWindow = max(cpuSpan, 4 * profile.scrapeInterval)
            ranked("cpu", .cpu, "sum by (namespace,pod,container)(rate(container_cpu_usage_seconds_total{\(selector)}[\(KubePromQL.duration(cpuWindow))]))")
            if let cpuNote, request.families.contains(.cpu) { plan.notes.append("CPU \(cpuNote).") }
            // Raw memory is de-duplicated before it is averaged: a subquery,
            // 24h at most — a workload's over at most 50 pods, counted.
            var memoryWhy: String?
            if workload, let counted {
                if let pods = counted.pods {
                    if !KubeQueryCost.subquery(.workload(pods: pods), profile: profile).isAllowed {
                        memoryWhy = "Memory's top five need recording rules past \(KubeQueryCost.maxSubqueryPods) pods: the total alone."
                    }
                } else {
                    memoryWhy = "Memory's top five weren't ranked: the pods couldn't be counted."
                }
            }
            if let memoryWhy {
                if request.families.contains(.memory) {
                    plan.notes.append(memoryWhy)
                    plan.skipped.insert("memory")
                }
            } else {
                let memorySpan = min(length, KubeQueryCost.rankingFallback)
                ranked(
                    "memory", .memory,
                    "avg_over_time(max by (namespace,pod,container)(container_memory_working_set_bytes{\(selector)})[\(KubePromQL.duration(memorySpan)):\(step)])")
                if memorySpan < length, request.families.contains(.memory) { plan.notes.append("Memory ranked by the last \(KubePromQL.duration(memorySpan)).") }
            }
        }
        return plan.queries.isEmpty && plan.skipped.isEmpty ? nil : plan
    }

    /// A ranking query's answer: its names, largest first — a pod, or a
    /// namespace's workload as `Kind/name`.
    static func rankNames(_ series: [KubeSeries], subject: KubeTabSubject) -> [String] {
        let named = series.compactMap { one -> (String, Double)? in
            guard let value = one.points.last?.value, value.isFinite else { return nil }
            switch subject {
            case .namespace:
                guard let workload = one.labels["workload"], !workload.isEmpty else { return nil }
                return (kindTitle(one.labels["workload_type"] ?? "") + "/" + workload, value)
            default:
                guard let pod = one.labels["pod"], !pod.isEmpty else { return nil }
                return (pod, value)
            }
        }
        var seen = Set<String>()
        return named.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.map(\.0).filter { seen.insert($0).inserted }.prefix(top(subject)).map { $0 }
    }

    /// A namespace's cAdvisor CPU series counted (metrics.md 4.4), where a
    /// namespace's tab needs it and the profile hasn't it: raw across the
    /// namespace only below 2,000 of them. Nil: nothing to count.
    static func namespaceCount(_ request: KubeTabRequest, profile: KubePromProfile) -> (namespace: String, promql: String)? {
        guard case .namespace(let namespace) = request.subject, profile.known, !profile.hasContainerRules, profile.namespaceSeries[namespace] == nil,
            request.families.contains(.cpu) || request.families.contains(.memory)
        else { return nil }
        return (namespace, "count(container_cpu_usage_seconds_total{\(KubePromQL.matchers([("namespace", namespace)])),container!=\"\"})")
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
    /// What identifies a GPU on DCGM exporter's series: its index, and a MIG
    /// instance's profile and id; its model, for its name.
    static let gpuIdentity = "gpu,GPU_I_PROFILE,GPU_I_ID,modelName"

    /// G1–G3 under `scope`, one union tagged `overterm_s`, each a series a
    /// GPU (and `by`: its container, its pod) taken once (`max by`: two
    /// scrapes of one exporter): utilisation as a fraction (`util`, the
    /// device's; `engine`, the graphics engine's activity where profiling
    /// metrics are on — a MIG instance's only one), framebuffer used and
    /// its total (used + free at one sample) in bytes (DCGM says MiB),
    /// power and temperature where reported. A gauge keeps its peaks past
    /// 5-minute steps, as the others do; the total doesn't.
    static func gpus(_ scope: String, by: String, profile: KubePromProfile, gauge: (String) -> String) -> String {
        let grouping = "\(gpuIdentity),\(by)"
        func of(_ metric: String, peaks: Bool = true) -> String {
            "max by (\(grouping))(\(peaks ? gauge("\(metric){\(scope)}") : "\(metric){\(scope)}"))"
        }
        var arms: [(String, String)] = []
        if profile.has(KubePromProfile.dcgmUtilisation) { arms.append(("\(of(KubePromProfile.dcgmUtilisation)) / 100", "util")) }
        if profile.has(KubePromProfile.dcgmEngineActive) { arms.append((of(KubePromProfile.dcgmEngineActive), "engine")) }
        arms.append(("\(of(KubePromProfile.dcgmMemoryUsed)) * 1048576", "used"))
        // The total from used and free at the same sample, never peaked: a
        // peaked used beside a plain free overstated it wherever use moved.
        if profile.has(KubePromProfile.dcgmMemoryFree) {
            arms.append(("max by (\(grouping))(\(KubePromProfile.dcgmMemoryUsed){\(scope)} + \(KubePromProfile.dcgmMemoryFree){\(scope)}) * 1048576", "total"))
        }
        if profile.has(KubePromProfile.dcgmPower) { arms.append((of(KubePromProfile.dcgmPower), "power")) }
        if profile.has(KubePromProfile.dcgmTemperature) { arms.append((of(KubePromProfile.dcgmTemperature), "temp")) }
        return KubeTabQueries.union(arms)
    }

    /// node-exporter's series mapped to `node`: its instance, by
    /// `node_uname_info`'s nodename (on EKS the node's hostname, which is
    /// its name) — one `node_uname_info` an instance, two jobs scraping it or not.
    static func onNode(_ node: String) -> String {
        "on(instance) group_left(nodename) max by (instance,nodename)(node_uname_info{\(matchers([("nodename", node)]))})"
    }

    static let nodeFilesystemMetric = "node_filesystem_avail_bytes"
    static let nodeNetworkMetric = "node_network_receive_bytes_total"
    /// K6's mounts: the root and Bottlerocket's `/local`, never tmpfs, overlay or squashfs.
    static let nodeFilesystems = #"fstype!~"tmpfs|overlay|squashfs",mountpoint=~"/|/local""#
    /// K7's interfaces: the node's own, never loopback, a pod's veth or
    /// VPC CNI's eni, Calico's, Docker's or a CNI bridge.
    static let nodeDevices = #"device!~"lo|veth.*|eni.*|cali.*|docker.*|cni.*""#

    /// K6: each mount's used bytes (size less available) and its size, one
    /// union tagged `overterm_s` — every series taken once an instance and
    /// mount first, so two jobs scraping one node-exporter don't double it.
    static func nodeDisks(_ node: String) -> String {
        func fs(_ metric: String) -> String { "max by (instance,mountpoint)(\(metric){\(nodeFilesystems)})" }
        return KubeTabQueries.union([
            ("max by (mountpoint)((\(fs("node_filesystem_size_bytes")) - \(fs(nodeFilesystemMetric))) * \(onNode(node)))", "used"),
            ("max by (mountpoint)(\(fs("node_filesystem_size_bytes")) * \(onNode(node)))", "size"),
        ])
    }

    /// K7: the node's received and sent bytes a second over its own
    /// interfaces, each device's rate once an instance.
    static func nodeNetwork(_ node: String, window: String) -> String {
        func rate(_ metric: String) -> String {
            "sum(max by (instance,device)(rate(\(metric){\(nodeDevices)}[\(window)])) * \(onNode(node)))"
        }
        return KubeTabQueries.union([(rate(nodeNetworkMetric), "rx"), (rate("node_network_transmit_bytes_total"), "tx")])
    }

    /// A node's own memory in use, node-exporter's MemTotal − MemAvailable
    /// (K2's "node total": the system's and the kubelet's too), its
    /// instance mapped to the node by `node_uname_info`'s nodename (on EKS
    /// the node's hostname, which is its name) — both sides taken once an
    /// instance (metrics.md 1.1), two jobs scraping it or not: summed by
    /// job, a node scraped twice read twice its memory.
    static func nodeTotalMemory(_ node: String) -> String {
        "sum(max by (instance)(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) * \(onNode(node)))"
    }

    /// What a namespace's active pods request (N3's chip): the mixin's
    /// active-pod rule where it is, else kube-state-metrics' requests of
    /// the Pending and Running pods — its 1.x names on 1.x.
    static func requests(_ resource: String, namespace: String, profile: KubePromProfile) -> String {
        let inNamespace = matchers([("namespace", namespace)])
        if profile.hasActiveRules {
            return "sum(max by (namespace,pod,container,node)(cluster:namespace:pod_\(resource == "cpu" ? "cpu" : "memory"):active:kube_pod_container_resource_requests{\(inNamespace)}))"
        }
        let pinned = KubeTabQueries.joined([profile.ksmMatcher, inNamespace])
        let selector =
            profile.ksmMajor == 1
            ? "kube_pod_container_resource_requests_\(resource == "cpu" ? "cpu_cores" : "memory_bytes"){\(pinned)}"
            : "kube_pod_container_resource_requests{\(KubeTabQueries.joined([pinned, matchers([("resource", resource)])]))}"
        let active = "max by (namespace,pod)(kube_pod_status_phase{\(KubeTabQueries.joined([pinned, #"phase=~"Pending|Running""#]))} == 1)"
        return "sum(max by (namespace,pod,container,node)(\(selector)) * on(namespace,pod) group_left() \(active))"
    }

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
