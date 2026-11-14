import Foundation

/// `k8s_top` (3.5; stage 2d): `kubectl top`'s answer from metrics.k8s.io —
/// a namespace's (or every) pod's CPU and memory, a pod's containers', or
/// the nodes' with their share of allocatable — through the context's
/// proxy, a GET each, sorted and bounded, scrubbed. Without metrics-server
/// (discovery says so) it answers that, asking nothing more; a context
/// whose `metrics` is `none` isn't asked at all.
extension KubeMCP {
    static let defaultTop = 20
    static let maxTop = 200

    static func top(_ call: Call, _ target: Target, kubernetes: KubernetesModel, now: Date) async throws -> String {
        let nodes: Bool
        switch (call.string("kind") ?? "pods").lowercased() {
        case "pods", "pod", "po": nodes = false
        case "nodes", "node", "no": nodes = true
        default: throw BrowserMCP.ToolError(message: "k8s_top reads pods or nodes: “kind” is pods (default) or nodes.")
        }
        let sortBy = (call.string("sort_by") ?? "cpu").lowercased()
        guard ["cpu", "memory"].contains(sortBy) else { throw BrowserMCP.ToolError(message: "“sort_by” is cpu or memory.") }
        let limit = call.int("limit", default: defaultTop, in: 1...maxTop)
        let labels = call.string("label_selector")
        let source = target.context.settings.metrics ?? .auto
        // Whether metrics-server is there, as discovery says it: asked
        // nothing at all when the context's metrics are none.
        let discovery = source == .none ? nil : try await discovery(for: target, kubernetes: kubernetes)
        var header = nodes ? target.header(.all, kind: KubeResourceKind.namespaces) : target.header(kind: .pods)
        let availability = KubeMetricsAvailability.of(discovery, source: source)
        guard availability == .served else { return KubeMCPText.finished([header, availability.reason ?? ""].joined(separator: "\n")) }
        let client = target.client
        if nodes {
            let body = try await within { try await client.get(KubeMetricsTarget.nodes.path).body }
            let samples = try KubeMetricsReader.nodes(body)
            let allocatable = (try? await within { try await KubeMetricsMonitor.allocatable(client) }) ?? [:]
            return KubeMCPText.finished(
                [header, KubeMCPText.topNodes(samples, allocatable: allocatable, sortBy: sortBy, limit: limit, now: now)].joined(separator: "\n"))
        }
        let podsTarget = KubeMetricsTarget.pods(target.scope, labels: labels)
        let read = try await within { try await podsTarget.pods(client) }
        var samples = read.pods
        // A namespace refused is left out, and said.
        if !read.refused.isEmpty { header += "\n" + KubeMetricsTarget.podsRefusal(read.refused) + " Its pods are left out." }
        if let name = call.string("name") {
            guard KubeMCPText.isName(name) else { throw BrowserMCP.ToolError(message: "“\(name)” isn't a pod's name.") }
            samples = samples.filter { $0.id.name == name }
            guard !samples.isEmpty else { return KubeMCPText.finished([header, "metrics-server has no sample of pod \(name) (it samples running pods)."].joined(separator: "\n")) }
        }
        let (specs, said) = await shareSpecs(for: samples, named: call.string("name") != nil, target, kubernetes: kubernetes)
        let text = KubeMCPText.topPods(
            samples, allNamespaces: target.namespace == nil, containers: call.bool("containers") || call.string("name") != nil, sortBy: sortBy, limit: limit,
            now: now, specs: specs)
        return KubeMCPText.finished([header, text, said].compactMap { $0 }.joined(separator: "\n"))
    }

    /// At most this many named pods are read for their specs.
    static let maxShareReads = 10

    /// The pods' requests and limits, for their shares (metrics.md 7): a
    /// named pod's own object, one GET each (at most `maxShareReads`),
    /// decoded to its containers' resources and dropped. A namespace's —
    /// one, or up to `KubeScope.watchCap`, none across every one — from
    /// kube-state-metrics where the context's Prometheus is opted in: the
    /// list's query, asked for the call (`KubePrometheusMonitor.agentShares`);
    /// where that fails, what the Pods list last read whole for those
    /// namespaces. Nothing else is read for them; without either, the raw
    /// usage only, and why.
    static func shareSpecs(
        for samples: [KubePodMetrics], named: Bool, _ target: Target, kubernetes: KubernetesModel
    ) async -> (specs: [KubeRowID: KubePodShares.Spec], said: String?) {
        guard !samples.isEmpty else { return ([:], nil) }
        if named {
            var specs: [KubeRowID: KubePodShares.Spec] = [:]
            var failures: [String] = []
            let client = target.client
            for sample in samples.prefix(maxShareReads) {
                guard let namespace = sample.id.namespace else { continue }
                let name = sample.id.name
                do {
                    let body = try await within { try await client.object(.pods, namespace: namespace, name: name).data }
                    guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                        failures.append("\(name) (not a pod's object)")
                        continue
                    }
                    specs[sample.id] = KubePodShares.spec(ofPod: object)
                } catch {
                    failures.append("\(name) (\(said(error)))")
                }
            }
            guard !failures.isEmpty else { return (specs, nil) }
            return (specs, "Shares of request and limit need the pod's own object, which couldn't be read for " + failures.joined(separator: "; ") + ".")
        }
        let namespaces = Set(samples.compactMap(\.id.namespace))
        let cached = kubernetes.prometheus.shares(for: target.context.name).flatMap { reading -> KubeShareReading? in
            reading.unavailable == nil && namespaces.isSubset(of: reading.whole) ? reading : nil
        }
        let fallback = "Shares from kube-state-metrics (Prometheus), as the Pods list last read them."
        guard KubePrometheusUse.of(target.context.settings).isOn else {
            if let cached { return (cached.pods, fallback) }
            return ([:], KubeChartEmpty.topSharesNeedSpecs.sentence)
        }
        guard let names = target.scope.names, names.count <= KubeScope.watchCap else {
            return ([:], KubeChartEmpty.topSharesNeedNamespaces.sentence)
        }
        let context = target.context
        let answer = await kubernetes.prometheus.agentShares(
            context, namespaces: names.filter(namespaces.contains).sorted(), client: target.client,
            transport: { kubernetes.agentPrometheusTransport(for: context, $0) })
        let why: String
        switch answer {
        case .off:
            why = KubeChartEmpty.topSharesNeedSpecs.sentence
        case .unavailable(let reason):
            why = "Shares couldn't be read from kube-state-metrics: \(reason)"
        case .read(let reading):
            var notes = reading.cut.sorted().map { KubeChartEmpty.sharesCut($0).sentence }
            notes += reading.problems.sorted { $0.key < $1.key }.map { "\($0.key)'s shares couldn't be read: \($0.value)" }
            let whole = reading.whole
            if !whole.isEmpty {
                let pods = reading.pods.filter { whole.contains($0.key.namespace ?? "") }
                return (pods, (["Shares from kube-state-metrics (Prometheus), read now."] + notes).joined(separator: " "))
            }
            why = notes.isEmpty ? KubeChartEmpty.topSharesNeedSpecs.sentence : notes.joined(separator: " ")
        }
        if let cached { return (cached.pods, why + " " + fallback) }
        return ([:], why)
    }
}

extension KubeMCPText {
    /// Rows padded into columns, the header first.
    static func columns(_ header: [String], _ rows: [[String]]) -> String {
        var widths = header.map(\.count)
        for row in rows { for (index, cell) in row.enumerated() where index < widths.count { widths[index] = max(widths[index], cell.count) } }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { index, cell in
                index == cells.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "   ").trimmingCharacters(in: .whitespaces)
        }
        return ([line(header)] + rows.map(line)).joined(separator: "\n")
    }

    /// When metrics-server took the samples, said once.
    static func sampled(_ stamps: [Date?], window: String?, now: Date) -> String {
        guard let oldest = stamps.compactMap({ $0 }).min() else { return "" }
        return "Sampled by metrics-server \(KubeMetricsFormat.age(now.timeIntervalSince(oldest))) ago" + (window.map { " over \($0)" } ?? "") + "."
    }

    static func topPods(
        _ samples: [KubePodMetrics], allNamespaces: Bool, containers: Bool, sortBy: String, limit: Int, now: Date,
        specs: [KubeRowID: KubePodShares.Spec] = [:]
    ) -> String {
        guard !samples.isEmpty else { return "No pod samples: metrics-server samples running pods only." }
        let key: (KubeUsage) -> Double = sortBy == "memory" ? { $0.memory } : { $0.cpu }
        let sorted = samples.sorted { (key($0.total), $1.id) > (key($1.total), $0.id) }
        var header = ["NAME"]
        if containers { header.append("CONTAINER") }
        header += ["CPU(cores)", "MEMORY(bytes)"]
        let shares = !specs.isEmpty
        if shares { header += KubePodShares.Column.allCases.map(\.title) }
        if allNamespaces { header.insert("NAMESPACE", at: 0) }
        var rows: [[String]] = []
        for pod in sorted.prefix(limit) {
            let spec = specs[pod.id]
            let names = pod.containers.keys.sorted()
            // Containers listed: the pod's own line first where its shares are in hand and it has more than one.
            var lines: [(String?, KubeUsage)] = containers ? names.map { ($0, pod.containers[$0]!) } : [(nil, pod.total)]
            if containers, shares, spec != nil, names.count > 1 { lines.insert(("(pod)", pod.total), at: 0) }
            for (container, usage) in lines {
                var row = [cut(pod.id.name)]
                if containers { row.append(cut(container ?? "")) }
                row += [KubeMetricsFormat.cpu(usage.cpu), KubeMetricsFormat.memory(usage.memory)]
                if shares {
                    // The pod's line its shares; a container's its own where its spec is in hand (a lone container's, the pod's).
                    let whole = container == nil || container == "(pod)" || (spec?.containers == 1 && names.count == 1 && spec?.byContainer.isEmpty == true)
                    let own = whole ? spec : container.flatMap { spec?.containers(named: $0) }
                    row += KubePodShares.Column.allCases.map { column in
                        guard let own, case .value(let text, _, _) = KubePodShares.cell(column, used: usage, spec: own, sampled: whole ? names.count : nil)
                        else { return "-" }
                        return text
                    }
                }
                if allNamespaces { row.insert(cut(pod.id.namespace ?? ""), at: 0) }
                rows.append(row)
            }
        }
        var text = columns(header, rows)
        if sorted.count > limit { text += "\n… \(sorted.count - limit) more pods, using less (sorted by \(sortBy)): raise limit, or name a namespace." }
        let said = sampled(samples.map(\.timestamp), window: samples.first?.window, now: now)
        return said.isEmpty ? text : text + "\n" + said
    }

    static func topNodes(_ samples: [KubeNodeMetrics], allocatable: [String: KubeUsage], sortBy: String, limit: Int, now: Date) -> String {
        guard !samples.isEmpty else { return "No node samples." }
        let key: (KubeUsage) -> Double = sortBy == "memory" ? { $0.memory } : { $0.cpu }
        let sorted = samples.sorted { (key($0.usage), $1.name) > (key($1.usage), $0.name) }
        let rows = sorted.prefix(limit).map { node -> [String] in
            let total = allocatable[node.name]
            let cpu = KubeMetricsFormat.percent(node.usage.cpu, of: total?.cpu).map { "\($0)%" } ?? "?"
            let memory = KubeMetricsFormat.percent(node.usage.memory, of: total?.memory).map { "\($0)%" } ?? "?"
            return [cut(node.name), KubeMetricsFormat.cpu(node.usage.cpu), cpu, KubeMetricsFormat.memory(node.usage.memory), memory]
        }
        var text = columns(["NAME", "CPU(cores)", "CPU(%)", "MEMORY(bytes)", "MEMORY(%)"], Array(rows))
        if sorted.count > limit { text += "\n… \(sorted.count - limit) more nodes: raise limit." }
        let said = sampled(samples.map(\.timestamp), window: samples.first?.window, now: now)
        return said.isEmpty ? text : text + "\n" + said
    }
}
