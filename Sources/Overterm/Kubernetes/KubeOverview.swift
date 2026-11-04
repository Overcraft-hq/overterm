import Foundation

/// What a detail's Overview says of one object: the facts at the top, then
/// sections — a pod's containers, a workload's replicas and rollout, a
/// Service's ports, a node's capacity and taints… (`KubeOverview.of`) —
/// and, for any kind, its owners, conditions, labels and annotations.
/// References are links (`KubeLink`); a selector names the pods to list
/// beside it (`pods`). Read from the object's JSON alone. Pure.
struct KubeOverview: Equatable {
    enum Tone: Equatable, Sendable {
        case plain, good, waiting, bad, dim
    }

    struct Item: Equatable, Identifiable {
        var label: String
        var value: String
        var tone: Tone = .plain
        var link: KubeLink? = nil
        /// Code-like (an image, an IP, a selector): monospaced, selectable.
        var mono = false
        /// A second line under the value.
        var detail: String? = nil
        /// The second line is code-like (a container's image).
        var detailMono = false

        var id: String { label + "\u{0}" + value }
    }

    struct Section: Equatable, Identifiable {
        var title: String
        var items: [Item]

        var id: String { title }
    }

    /// The first lines: what it is now.
    var facts: [Item] = []
    var sections: [Section] = []
    /// A workload's rollout, as `kubectl rollout status` reads it.
    var rollout: KubeRollout?
    /// The pods its selector picks, in its namespace: a workload's, a
    /// Service's, a Job's. Nil for a kind that picks none.
    var pods: (namespace: String, selector: String)?

    static func == (lhs: KubeOverview, rhs: KubeOverview) -> Bool {
        lhs.facts == rhs.facts && lhs.sections == rhs.sections && lhs.rollout == rhs.rollout && lhs.pods?.namespace == rhs.pods?.namespace
            && lhs.pods?.selector == rhs.pods?.selector
    }

    /// A section by its title.
    func section(_ title: String) -> Section? { sections.first { $0.title == title } }

    /// A fact or a section's item by its label.
    func item(_ label: String) -> Item? { (facts + sections.flatMap(\.items)).first { $0.label == label } }

    // MARK: Reading

    /// The Overview of `object` (a GET's JSON): tailored for the kinds that
    /// have one (by `kind` and group), the generic sections for all.
    static func of(_ object: [String: Any], now: Date = Date()) -> KubeOverview {
        var overview = KubeOverview()
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let kind = object["kind"] as? String ?? ""
        let group = (object["apiVersion"] as? String ?? "").split(separator: "/").dropLast().first.map(String.init) ?? ""
        switch (group, kind) {
        case ("", "Pod"): pod(object, into: &overview)
        case ("apps", "Deployment"), ("apps", "StatefulSet"), ("apps", "DaemonSet"), ("apps", "ReplicaSet"): workload(object, kind: kind, into: &overview)
        case ("", "Service"): service(object, into: &overview)
        case ("", "Node"): node(object, into: &overview)
        case ("batch", "Job"): job(object, now: now, into: &overview)
        case ("batch", "CronJob"): cronJob(object, into: &overview)
        case ("networking.k8s.io", "Ingress"): ingress(object, into: &overview)
        case ("", "ConfigMap"): configMap(object, into: &overview)
        case ("", "PersistentVolumeClaim"): claim(object, into: &overview)
        case ("", "PersistentVolume"): volume(object, into: &overview)
        case ("", "Namespace"): namespace(object, into: &overview)
        default: break
        }
        generic(object, metadata: metadata, now: now, into: &overview)
        return overview
    }

    // MARK: Every kind

    /// Created, owners, status conditions (if it has them), labels,
    /// annotations — the last-applied one left out: it is the whole object
    /// again (the YAML tab's toggle shows it).
    private static func generic(_ object: [String: Any], metadata: [String: Any], now: Date, into overview: inout KubeOverview) {
        var about: [Item] = []
        if let namespace = metadata["namespace"] as? String { about.append(Item(label: "Namespace", value: namespace)) }
        if let created = (metadata["creationTimestamp"] as? String).flatMap(KubeTime.date) {
            about.append(Item(label: "Created", value: "\(KubeAge.format(now.timeIntervalSince(created))) ago", detail: created.formatted(.iso8601)))
        }
        if let deleted = metadata["deletionTimestamp"] as? String {
            about.append(Item(label: "Deleting", value: "since \(deleted)", tone: .waiting))
        }
        if let finalizers = metadata["finalizers"] as? [String], !finalizers.isEmpty {
            about.append(Item(label: "Finalizers", value: finalizers.joined(separator: ", "), mono: true))
        }
        if let uid = metadata["uid"] as? String { about.append(Item(label: "UID", value: uid, tone: .dim, mono: true)) }
        overview.sections.insert(Section(title: "Object", items: about), at: 0)

        let owners = (metadata["ownerReferences"] as? [[String: Any]] ?? []).compactMap { owner -> Item? in
            guard let kind = owner["kind"] as? String, let name = owner["name"] as? String else { return nil }
            let link = KubeLink(
                apiVersion: owner["apiVersion"] as? String ?? "", kind: kind, namespace: metadata["namespace"] as? String, name: name)
            return Item(label: kind, value: name, link: link, detail: owner["controller"] as? Bool == true ? "controller" : nil)
        }
        if !owners.isEmpty { overview.sections.insert(Section(title: "Owned by", items: owners), at: 1) }

        let conditions = conditionItems((object["status"] as? [String: Any])?["conditions"], kind: object["kind"] as? String ?? "", now: now)
        if !conditions.isEmpty, overview.section("Conditions") == nil { overview.sections.append(Section(title: "Conditions", items: conditions)) }

        let labels = metadata["labels"] as? [String: Any] ?? [:]
        if !labels.isEmpty { overview.sections.append(Section(title: "Labels", items: pairs(labels))) }
        var annotations = metadata["annotations"] as? [String: Any] ?? [:]
        annotations[KubeObjectStrip.lastApplied] = nil
        if !annotations.isEmpty { overview.sections.append(Section(title: "Annotations", items: pairs(annotations, limit: 400))) }
    }

    private static func pairs(_ map: [String: Any], limit: Int = 2000) -> [Item] {
        map.keys.sorted().map { key in Item(label: key, value: clipped(string(map[key]), limit), mono: true) }
    }

    static func clipped(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "… (\(text.count) characters; the YAML tab has it all)" : text
    }

    /// A condition: True is good for most types and bad for a node's
    /// pressure conditions (`MemoryPressure`, `DiskPressure`…).
    static func conditionItems(_ value: Any?, kind: String, now: Date) -> [Item] {
        (value as? [[String: Any]] ?? []).compactMap { condition -> Item? in
            guard let type = condition["type"] as? String else { return nil }
            let status = condition["status"] as? String ?? "Unknown"
            let reason = condition["reason"] as? String
            let message = (condition["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let healthyWhenTrue = !(kind == "Node" && type != "Ready") && !["Failed", "ReplicaFailure", "Stalled"].contains(type)
            let tone: Tone
            switch status {
            case "True": tone = healthyWhenTrue ? .good : .bad
            case "False": tone = healthyWhenTrue ? (type == "Progressing" && reason == "ProgressDeadlineExceeded" ? .bad : .waiting) : .good
            default: tone = .waiting
            }
            let since = (condition["lastTransitionTime"] as? String).flatMap(KubeTime.date).map { " · \(KubeAge.format(now.timeIntervalSince($0))) ago" } ?? ""
            return Item(
                label: type, value: status + (reason.map { " · \($0)" } ?? "") + since, tone: tone,
                detail: message.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    static func string(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: ""
        case let text as String: text
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): number.boolValue ? "true" : "false"
        case let number as NSNumber: number.stringValue
        case let value?: KubeYAML.text(value).trimmingCharacters(in: .newlines)
        }
    }

    private static func int(_ value: Any?) -> Int? { KubeRollout.int(value) }

    // MARK: Pods

    private static func pod(_ object: [String: Any], into overview: inout KubeOverview) {
        let spec = object["spec"] as? [String: Any] ?? [:]
        let status = object["status"] as? [String: Any] ?? [:]
        let phase = status["phase"] as? String ?? "Unknown"
        let tone: Tone =
            switch phase {
            case "Running", "Succeeded": .good
            case "Failed": .bad
            default: .waiting
            }
        overview.facts.append(Item(label: "Phase", value: phase, tone: tone))
        if let reason = status["reason"] as? String {
            overview.facts.append(Item(label: "Reason", value: reason, tone: .bad, detail: status["message"] as? String))
        }
        if let node = spec["nodeName"] as? String {
            overview.facts.append(Item(label: "Node", value: node, link: KubeLink(apiVersion: "v1", kind: "Node", namespace: nil, name: node)))
        } else {
            overview.facts.append(Item(label: "Node", value: "not scheduled yet", tone: .waiting))
        }
        let ips = (status["podIPs"] as? [[String: Any]])?.compactMap { $0["ip"] as? String } ?? (status["podIP"] as? String).map { [$0] } ?? []
        if !ips.isEmpty { overview.facts.append(Item(label: ips.count > 1 ? "Pod IPs" : "Pod IP", value: ips.joined(separator: ", "), mono: true)) }
        if let host = status["hostIP"] as? String { overview.facts.append(Item(label: "Host IP", value: host, mono: true)) }
        if let qos = status["qosClass"] as? String { overview.facts.append(Item(label: "QoS", value: qos)) }
        if let account = spec["serviceAccountName"] as? String { overview.facts.append(Item(label: "Service account", value: account)) }
        if let priority = spec["priorityClassName"] as? String { overview.facts.append(Item(label: "Priority class", value: priority)) }
        if let restart = spec["restartPolicy"] as? String { overview.facts.append(Item(label: "Restart policy", value: restart)) }

        let statuses = Dictionary(
            ((status["initContainerStatuses"] as? [[String: Any]] ?? []) + (status["containerStatuses"] as? [[String: Any]] ?? [])
                + (status["ephemeralContainerStatuses"] as? [[String: Any]] ?? [])).compactMap { item in
                    (item["name"] as? String).map { ($0, item) }
                }, uniquingKeysWith: { first, _ in first })
        for (title, key) in [("Init containers", "initContainers"), ("Containers", "containers"), ("Ephemeral containers", "ephemeralContainers")] {
            let containers = spec[key] as? [[String: Any]] ?? []
            guard !containers.isEmpty else { continue }
            overview.sections.append(Section(title: title, items: containers.map { container(name: $0["name"] as? String ?? "", spec: $0, status: statuses[$0["name"] as? String ?? ""]) }))
        }
    }

    /// One container: its image, its state now, its restarts, how it last ended.
    static func container(name: String, spec: [String: Any], status: [String: Any]?) -> Item {
        let image = spec["image"] as? String ?? status?["image"] as? String ?? ""
        guard let status else { return Item(label: name, value: "no status yet", tone: .waiting, detail: image, detailMono: true) }
        var parts: [String] = []
        var tone: Tone = .waiting
        let state = status["state"] as? [String: Any] ?? [:]
        if let waiting = state["waiting"] as? [String: Any] {
            let reason = waiting["reason"] as? String ?? "Waiting"
            parts.append(reason)
            tone =
                ["CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "CreateContainerConfigError", "InvalidImageName", "RunContainerError"]
                    .contains(reason) ? .bad : .waiting
        } else if let terminated = state["terminated"] as? [String: Any] {
            let code = int(terminated["exitCode"]) ?? 0
            parts.append("Terminated: \(terminated["reason"] as? String ?? "exit") (exit \(code))")
            tone = code == 0 ? .dim : .bad
        } else if state["running"] != nil {
            let ready = status["ready"] as? Bool ?? false
            parts.append(ready ? "Running, ready" : "Running, not ready")
            tone = ready ? .good : .waiting
        }
        let restarts = int(status["restartCount"]) ?? 0
        if restarts > 0 { parts.append("\(restarts) restart\(restarts == 1 ? "" : "s")") }
        if let last = (status["lastState"] as? [String: Any])?["terminated"] as? [String: Any] {
            let code = int(last["exitCode"]).map { " (exit \($0))" } ?? ""
            parts.append("last: \(last["reason"] as? String ?? "exited")\(code)")
            if tone == .good, restarts > 0 { tone = .waiting }
        }
        return Item(label: name, value: parts.joined(separator: " · "), tone: tone, detail: image, detailMono: true)
    }

    // MARK: Workloads

    private static func workload(_ object: [String: Any], kind: String, into overview: inout KubeOverview) {
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let spec = object["spec"] as? [String: Any] ?? [:]
        let status = object["status"] as? [String: Any] ?? [:]
        var replicas: [Item] = []
        let wanted: Int
        let readyCount: Int
        switch kind {
        case "DaemonSet":
            let desired = int(status["desiredNumberScheduled"]) ?? 0
            (wanted, readyCount) = (desired, int(status["numberReady"]) ?? 0)
            replicas = [
                Item(label: "Desired", value: "\(desired)"),
                Item(label: "Current", value: "\(int(status["currentNumberScheduled"]) ?? 0)"),
                Item(label: "Ready", value: "\(int(status["numberReady"]) ?? 0)", tone: (int(status["numberReady"]) ?? 0) < desired ? .waiting : .good),
                Item(label: "Updated", value: "\(int(status["updatedNumberScheduled"]) ?? 0)"),
                Item(label: "Available", value: "\(int(status["numberAvailable"]) ?? 0)"),
            ]
            if let misscheduled = int(status["numberMisscheduled"]), misscheduled > 0 {
                replicas.append(Item(label: "Misscheduled", value: "\(misscheduled)", tone: .bad))
            }
        default:
            let desired = int(spec["replicas"]) ?? 1
            let ready = int(status["readyReplicas"]) ?? 0
            (wanted, readyCount) = (desired, ready)
            replicas = [
                Item(label: "Desired", value: "\(desired)"),
                Item(label: "Ready", value: "\(ready)", tone: ready < desired ? .waiting : .good),
            ]
            if kind != "ReplicaSet" { replicas.append(Item(label: "Updated", value: "\(int(status["updatedReplicas"]) ?? 0)")) }
            if kind == "StatefulSet" { replicas.append(Item(label: "Current", value: "\(int(status["currentReplicas"]) ?? 0)")) }
            replicas.append(Item(label: "Available", value: "\(int(status["availableReplicas"]) ?? 0)"))
            if let unavailable = int(status["unavailableReplicas"]), unavailable > 0 {
                replicas.append(Item(label: "Unavailable", value: "\(unavailable)", tone: .waiting))
            }
        }
        overview.facts.append(Item(label: "Replicas", value: "\(readyCount)/\(wanted) ready", tone: readyCount < wanted ? .waiting : .good))
        overview.sections.append(Section(title: "Replicas", items: replicas))

        if let rollout = KubeRollout.of(object) {
            overview.rollout = rollout
            let tone: Tone =
                switch rollout.state {
                case .complete: .good
                case .stuck: .bad
                case .notTracked: .dim
                default: .waiting
                }
            overview.facts.append(Item(label: "Rollout", value: rollout.message, tone: tone))
        }
        if let revision = (metadata["annotations"] as? [String: Any])?["deployment.kubernetes.io/revision"] as? String {
            overview.facts.append(Item(label: "Revision", value: revision))
        }
        var shape: [Item] = []
        let strategy = (spec["strategy"] ?? spec["updateStrategy"]) as? [String: Any]
        if let type = strategy?["type"] as? String {
            let rolling = strategy?["rollingUpdate"] as? [String: Any] ?? [:]
            let knobs = ["maxSurge", "maxUnavailable", "partition"].compactMap { key in rolling[key].map { "\(key) \(string($0))" } }
            shape.append(Item(label: "Strategy", value: ([type] + knobs).joined(separator: " · ")))
        }
        if let paused = spec["paused"] as? Bool, paused { shape.append(Item(label: "Paused", value: "yes", tone: .waiting)) }
        if let service = spec["serviceName"] as? String, !service.isEmpty {
            shape.append(
                Item(label: "Service", value: service, link: KubeLink(apiVersion: "v1", kind: "Service", namespace: metadata["namespace"] as? String, name: service)))
        }
        if let policy = spec["podManagementPolicy"] as? String { shape.append(Item(label: "Pod management", value: policy)) }
        if let deadline = int(spec["progressDeadlineSeconds"]) { shape.append(Item(label: "Progress deadline", value: "\(deadline) s")) }
        if let minReady = int(spec["minReadySeconds"]), minReady > 0 { shape.append(Item(label: "Min ready", value: "\(minReady) s")) }
        if let history = int(spec["revisionHistoryLimit"]) { shape.append(Item(label: "Revisions kept", value: "\(history)")) }
        let selector = KubeSelector.text(spec["selector"])
        if let selector { shape.append(Item(label: "Selector", value: selector, mono: true)) }
        let images = ((spec["template"] as? [String: Any])?["spec"] as? [String: Any])?["containers"] as? [[String: Any]] ?? []
        for container in images {
            shape.append(Item(label: "Image", value: container["image"] as? String ?? "", mono: true, detail: container["name"] as? String))
        }
        overview.sections.append(Section(title: "Spec", items: shape))
        if let selector, let namespace = metadata["namespace"] as? String { overview.pods = (namespace, selector) }
    }

    // MARK: Network

    private static func service(_ object: [String: Any], into overview: inout KubeOverview) {
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let spec = object["spec"] as? [String: Any] ?? [:]
        let status = object["status"] as? [String: Any] ?? [:]
        let type = spec["type"] as? String ?? "ClusterIP"
        overview.facts.append(Item(label: "Type", value: type))
        let clusterIPs = spec["clusterIPs"] as? [String] ?? (spec["clusterIP"] as? String).map { [$0] } ?? []
        if !clusterIPs.isEmpty { overview.facts.append(Item(label: "Cluster IP", value: clusterIPs.joined(separator: ", "), mono: true)) }
        if let name = spec["externalName"] as? String { overview.facts.append(Item(label: "External name", value: name, mono: true)) }
        let external =
            (spec["externalIPs"] as? [String] ?? [])
            + ((status["loadBalancer"] as? [String: Any])?["ingress"] as? [[String: Any]] ?? []).compactMap { ($0["hostname"] ?? $0["ip"]) as? String }
        if !external.isEmpty {
            overview.facts.append(Item(label: "External", value: external.joined(separator: ", "), mono: true))
        } else if type == "LoadBalancer" {
            overview.facts.append(Item(label: "External", value: "pending", tone: .waiting))
        }
        if let affinity = spec["sessionAffinity"] as? String, affinity != "None" { overview.facts.append(Item(label: "Session affinity", value: affinity)) }
        let ports = (spec["ports"] as? [[String: Any]] ?? []).map { port -> Item in
            let number = int(port["port"]).map(String.init) ?? "?"
            let proto = port["protocol"] as? String ?? "TCP"
            var value = "\(number)/\(proto)"
            if let target = port["targetPort"] { value += " → \(string(target))" }
            if let node = int(port["nodePort"]) { value += " · node port \(node)" }
            return Item(label: port["name"] as? String ?? "port", value: value, mono: true)
        }
        if !ports.isEmpty { overview.sections.append(Section(title: "Ports", items: ports)) }
        if let selector = KubeSelector.text(spec["selector"]) {
            overview.sections.append(Section(title: "Selector", items: [Item(label: "Selector", value: selector, mono: true)]))
            if let namespace = metadata["namespace"] as? String { overview.pods = (namespace, selector) }
        } else if type != "ExternalName" {
            overview.facts.append(Item(label: "Selector", value: "none: its endpoints are kept by hand", tone: .dim))
        }
    }

    private static func ingress(_ object: [String: Any], into overview: inout KubeOverview) {
        let namespace = (object["metadata"] as? [String: Any])?["namespace"] as? String
        let spec = object["spec"] as? [String: Any] ?? [:]
        let status = object["status"] as? [String: Any] ?? [:]
        if let ingressClass = spec["ingressClassName"] as? String { overview.facts.append(Item(label: "Class", value: ingressClass)) }
        let addresses = ((status["loadBalancer"] as? [String: Any])?["ingress"] as? [[String: Any]] ?? []).compactMap { ($0["hostname"] ?? $0["ip"]) as? String }
        overview.facts.append(
            addresses.isEmpty
                ? Item(label: "Address", value: "none yet", tone: .waiting) : Item(label: "Address", value: addresses.joined(separator: ", "), mono: true))
        func backend(_ value: Any?) -> (String, KubeLink?) {
            guard let backend = value as? [String: Any] else { return ("", nil) }
            if let service = backend["service"] as? [String: Any], let name = service["name"] as? String {
                let port = (service["port"] as? [String: Any]).map { ($0["name"] as? String) ?? int($0["number"]).map(String.init) ?? "" } ?? ""
                return ("\(name)\(port.isEmpty ? "" : ":\(port)")", KubeLink(apiVersion: "v1", kind: "Service", namespace: namespace, name: name))
            }
            if let resource = backend["resource"] as? [String: Any] { return ("\(resource["kind"] as? String ?? "")/\(resource["name"] as? String ?? "")", nil) }
            return ("", nil)
        }
        var rules: [Item] = []
        for rule in spec["rules"] as? [[String: Any]] ?? [] {
            let host = rule["host"] as? String ?? "*"
            for path in ((rule["http"] as? [String: Any])?["paths"] as? [[String: Any]] ?? []) {
                let (target, link) = backend(path["backend"])
                rules.append(Item(label: host + (path["path"] as? String ?? "/"), value: target, link: link, mono: true, detail: path["pathType"] as? String))
            }
        }
        if let fallback = spec["defaultBackend"] {
            let (target, link) = backend(fallback)
            rules.append(Item(label: "default", value: target, link: link, mono: true))
        }
        if !rules.isEmpty { overview.sections.append(Section(title: "Rules", items: rules)) }
        let tls = (spec["tls"] as? [[String: Any]] ?? []).map { entry in
            Item(label: entry["secretName"] as? String ?? "TLS", value: (entry["hosts"] as? [String] ?? []).joined(separator: ", "), mono: true)
        }
        if !tls.isEmpty { overview.sections.append(Section(title: "TLS", items: tls)) }
    }

    // MARK: Cluster

    private static func node(_ object: [String: Any], into overview: inout KubeOverview) {
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let spec = object["spec"] as? [String: Any] ?? [:]
        let status = object["status"] as? [String: Any] ?? [:]
        let labels = metadata["labels"] as? [String: Any] ?? [:]
        let ready = (status["conditions"] as? [[String: Any]] ?? []).first { $0["type"] as? String == "Ready" }?["status"] as? String
        overview.facts.append(Item(label: "Ready", value: ready ?? "Unknown", tone: ready == "True" ? .good : .bad))
        if spec["unschedulable"] as? Bool == true { overview.facts.append(Item(label: "Scheduling", value: "cordoned", tone: .waiting)) }
        let roles = labels.keys.filter { $0.hasPrefix("node-role.kubernetes.io/") }.map { String($0.dropFirst("node-role.kubernetes.io/".count)) }.sorted()
        overview.facts.append(Item(label: "Roles", value: roles.isEmpty ? "<none>" : roles.joined(separator: ", ")))
        let info = status["nodeInfo"] as? [String: Any] ?? [:]
        if let version = info["kubeletVersion"] as? String { overview.facts.append(Item(label: "Version", value: version)) }
        if let type = (labels["node.kubernetes.io/instance-type"] ?? labels["beta.kubernetes.io/instance-type"]) as? String {
            overview.facts.append(Item(label: "Instance type", value: type))
        }
        if let group = (labels["eks.amazonaws.com/nodegroup"] ?? labels["karpenter.sh/nodepool"]) as? String {
            overview.facts.append(Item(label: "Node group", value: group))
        }
        var system: [Item] = []
        for (label, key) in [("OS image", "osImage"), ("Kernel", "kernelVersion"), ("Runtime", "containerRuntimeVersion"), ("Architecture", "architecture")] {
            if let value = info[key] as? String { system.append(Item(label: label, value: value)) }
        }
        for address in status["addresses"] as? [[String: Any]] ?? [] {
            if let type = address["type"] as? String, let value = address["address"] as? String { system.append(Item(label: type, value: value, mono: true)) }
        }
        if let provider = spec["providerID"] as? String { system.append(Item(label: "Provider ID", value: provider, tone: .dim, mono: true)) }
        if !system.isEmpty { overview.sections.append(Section(title: "System", items: system)) }
        let capacity = status["capacity"] as? [String: Any] ?? [:]
        let allocatable = status["allocatable"] as? [String: Any] ?? [:]
        let resources = Set(capacity.keys).union(allocatable.keys).sorted { a, b in
            let order = ["cpu", "memory", "pods", "ephemeral-storage"]
            return (order.firstIndex(of: a) ?? order.count, a) < (order.firstIndex(of: b) ?? order.count, b)
        }
        if !resources.isEmpty {
            overview.sections.append(
                Section(
                    title: "Capacity · allocatable",
                    items: resources.map { Item(label: $0, value: "\(string(capacity[$0])) · \(string(allocatable[$0]))", mono: true) }))
        }
        let taints = (spec["taints"] as? [[String: Any]] ?? []).map { taint -> Item in
            let key = taint["key"] as? String ?? ""
            let value = (taint["value"] as? String).map { "=\($0)" } ?? ""
            return Item(label: key + value, value: taint["effect"] as? String ?? "", tone: .waiting, mono: true)
        }
        if !taints.isEmpty { overview.sections.append(Section(title: "Taints", items: taints)) }
    }

    private static func namespace(_ object: [String: Any], into overview: inout KubeOverview) {
        let phase = (object["status"] as? [String: Any])?["phase"] as? String ?? "Active"
        overview.facts.append(Item(label: "Status", value: phase, tone: phase == "Active" ? .good : .waiting))
    }

    // MARK: Jobs

    private static func job(_ object: [String: Any], now: Date, into overview: inout KubeOverview) {
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let spec = object["spec"] as? [String: Any] ?? [:]
        let status = object["status"] as? [String: Any] ?? [:]
        let conditions = status["conditions"] as? [[String: Any]] ?? []
        let finished = conditions.first { ["Complete", "Failed"].contains($0["type"] as? String) && $0["status"] as? String == "True" }
        let state = finished?["type"] as? String ?? (spec["suspend"] as? Bool == true ? "Suspended" : "Running")
        overview.facts.append(Item(label: "Status", value: state, tone: state == "Complete" ? .good : state == "Failed" ? .bad : .waiting))
        let completions = int(spec["completions"]).map(String.init) ?? "1"
        overview.facts.append(Item(label: "Completions", value: "\(int(status["succeeded"]) ?? 0)/\(completions)"))
        var counts = [
            Item(label: "Active", value: "\(int(status["active"]) ?? 0)"),
            Item(label: "Succeeded", value: "\(int(status["succeeded"]) ?? 0)"),
            Item(label: "Failed", value: "\(int(status["failed"]) ?? 0)", tone: (int(status["failed"]) ?? 0) > 0 ? .bad : .plain),
        ]
        if let parallelism = int(spec["parallelism"]) { counts.append(Item(label: "Parallelism", value: "\(parallelism)")) }
        if let backoff = int(spec["backoffLimit"]) { counts.append(Item(label: "Backoff limit", value: "\(backoff)")) }
        let start = (status["startTime"] as? String).flatMap(KubeTime.date)
        let end = (status["completionTime"] as? String).flatMap(KubeTime.date)
        if let start {
            counts.append(Item(label: "Started", value: "\(KubeAge.format(now.timeIntervalSince(start))) ago"))
            counts.append(Item(label: "Duration", value: KubeAge.format((end ?? now).timeIntervalSince(start)) + (end == nil ? " so far" : "")))
        }
        overview.sections.append(Section(title: "Pods", items: counts))
        if let selector = KubeSelector.text(spec["selector"]), let namespace = metadata["namespace"] as? String { overview.pods = (namespace, selector) }
    }

    private static func cronJob(_ object: [String: Any], into overview: inout KubeOverview) {
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let spec = object["spec"] as? [String: Any] ?? [:]
        let status = object["status"] as? [String: Any] ?? [:]
        overview.facts.append(Item(label: "Schedule", value: spec["schedule"] as? String ?? "", mono: true, detail: spec["timeZone"] as? String))
        if spec["suspend"] as? Bool == true { overview.facts.append(Item(label: "Suspended", value: "yes", tone: .waiting)) }
        if let policy = spec["concurrencyPolicy"] as? String { overview.facts.append(Item(label: "Concurrency", value: policy)) }
        if let last = status["lastScheduleTime"] as? String { overview.facts.append(Item(label: "Last scheduled", value: last, mono: true)) }
        if let last = status["lastSuccessfulTime"] as? String { overview.facts.append(Item(label: "Last succeeded", value: last, mono: true)) }
        let active = (status["active"] as? [[String: Any]] ?? []).compactMap { reference -> Item? in
            guard let name = reference["name"] as? String else { return nil }
            return Item(
                label: "Job", value: name,
                link: KubeLink(
                    apiVersion: reference["apiVersion"] as? String ?? "batch/v1", kind: reference["kind"] as? String ?? "Job",
                    namespace: reference["namespace"] as? String ?? metadata["namespace"] as? String, name: name))
        }
        overview.sections.append(Section(title: "Active jobs", items: active.isEmpty ? [Item(label: "None", value: "", tone: .dim)] : active))
    }

    // MARK: Config and storage

    /// Its keys and values: a ConfigMap's are not secret.
    private static func configMap(_ object: [String: Any], into overview: inout KubeOverview) {
        let data = object["data"] as? [String: Any] ?? [:]
        let binary = object["binaryData"] as? [String: Any] ?? [:]
        overview.facts.append(Item(label: "Keys", value: "\(data.count + binary.count)"))
        if object["immutable"] as? Bool == true { overview.facts.append(Item(label: "Immutable", value: "yes")) }
        var items = pairs(data, limit: 4000)
        items += binary.keys.sorted().map { key in
            Item(label: key, value: "binary, \(Data(base64Encoded: string(binary[key]))?.count ?? 0) bytes", tone: .dim)
        }
        if !items.isEmpty { overview.sections.append(Section(title: "Data", items: items)) }
    }

    private static func claim(_ object: [String: Any], into overview: inout KubeOverview) {
        let spec = object["spec"] as? [String: Any] ?? [:]
        let status = object["status"] as? [String: Any] ?? [:]
        let phase = status["phase"] as? String ?? "Pending"
        overview.facts.append(Item(label: "Status", value: phase, tone: phase == "Bound" ? .good : phase == "Lost" ? .bad : .waiting))
        if let volume = spec["volumeName"] as? String {
            overview.facts.append(
                Item(label: "Volume", value: volume, link: KubeLink(apiVersion: "v1", kind: "PersistentVolume", namespace: nil, name: volume)))
        }
        if let storageClass = spec["storageClassName"] as? String { overview.facts.append(Item(label: "Storage class", value: storageClass)) }
        let requested = ((spec["resources"] as? [String: Any])?["requests"] as? [String: Any])?["storage"]
        if let requested { overview.facts.append(Item(label: "Requested", value: string(requested), mono: true)) }
        if let capacity = (status["capacity"] as? [String: Any])?["storage"] { overview.facts.append(Item(label: "Capacity", value: string(capacity), mono: true)) }
        if let modes = (status["accessModes"] ?? spec["accessModes"]) as? [String] { overview.facts.append(Item(label: "Access", value: modes.joined(separator: ", "))) }
        if let mode = spec["volumeMode"] as? String { overview.facts.append(Item(label: "Volume mode", value: mode)) }
    }

    private static func volume(_ object: [String: Any], into overview: inout KubeOverview) {
        let spec = object["spec"] as? [String: Any] ?? [:]
        let status = object["status"] as? [String: Any] ?? [:]
        let phase = status["phase"] as? String ?? "Pending"
        overview.facts.append(Item(label: "Status", value: phase, tone: ["Bound", "Available"].contains(phase) ? .good : phase == "Failed" ? .bad : .waiting))
        if let capacity = (spec["capacity"] as? [String: Any])?["storage"] { overview.facts.append(Item(label: "Capacity", value: string(capacity), mono: true)) }
        if let modes = spec["accessModes"] as? [String] { overview.facts.append(Item(label: "Access", value: modes.joined(separator: ", "))) }
        if let policy = spec["persistentVolumeReclaimPolicy"] as? String { overview.facts.append(Item(label: "Reclaim policy", value: policy)) }
        if let storageClass = spec["storageClassName"] as? String { overview.facts.append(Item(label: "Storage class", value: storageClass)) }
        if let claim = spec["claimRef"] as? [String: Any], let name = claim["name"] as? String {
            overview.facts.append(
                Item(
                    label: "Claim", value: "\(claim["namespace"] as? String ?? "")/\(name)",
                    link: KubeLink(apiVersion: "v1", kind: "PersistentVolumeClaim", namespace: claim["namespace"] as? String, name: name)))
        }
        if let csi = spec["csi"] as? [String: Any] {
            overview.facts.append(Item(label: "Source", value: "CSI · \(csi["driver"] as? String ?? "")", mono: true))
        } else if let source = ["hostPath", "nfs", "local", "awsElasticBlockStore", "gcePersistentDisk", "azureDisk"].first(where: { spec[$0] != nil }) {
            overview.facts.append(Item(label: "Source", value: source))
        }
    }
}
