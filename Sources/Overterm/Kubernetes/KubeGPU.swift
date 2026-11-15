import Foundation

// GPUs from the objects alone (docs/design/kubernetes/metrics.md, decision
// 12; stage M8c): which GPU resources a node offers — its capacity and
// allocatable `nvidia.com/gpu`, `amd.com/gpu`, a MIG profile's
// `nvidia.com/mig-<profile>` — and which of its pods hold how many (its
// pods as objects, the read its charts already make); what a pod's
// containers are given; what a workload's template gives a pod, times its
// replicas. No Prometheus and no metrics-server needed: whether a GPU is
// busy is DCGM exporter's to say (`KubeGPUCharts`), and without it every
// allocation is shown, none hidden as idle. Pure.

enum KubeGPU {
    /// A GPU resource's name: NVIDIA's (whole, time-sliced, a MIG profile's) or AMD's.
    static func isGPU(_ resource: String) -> Bool {
        resource == "nvidia.com/gpu" || resource == "nvidia.com/gpu.shared" || resource.hasPrefix("nvidia.com/mig-") || resource == "amd.com/gpu"
    }

    /// A container's GPUs from its resources: an extended resource is given
    /// as its limit (its request, where set, must equal it).
    static func counts(requests: [String: Any], limits: [String: Any]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (key, value) in limits.merging(requests, uniquingKeysWith: { limit, _ in limit }) where isGPU(key) {
            guard let count = number(value), count > 0 else { continue }
            out[key] = count
        }
        return out
    }

    /// A node's `status.capacity` or `allocatable`, its GPU resources alone.
    static func resources(_ map: Any?) -> [String: Double] {
        var out: [String: Double] = [:]
        for (key, value) in map as? [String: Any] ?? [:] where isGPU(key) {
            if let count = number(value) { out[key] = count }
        }
        return out
    }

    static func number(_ value: Any?) -> Double? {
        (value as? String).flatMap(KubeQuantity.value) ?? (value as? NSNumber)?.doubleValue
    }

    /// `nvidia.com/mig-1g.5gb` → `MIG 1g.5gb`; `nvidia.com/gpu` → `nvidia.com/gpu`.
    static func title(_ resource: String) -> String {
        resource.hasPrefix("nvidia.com/mig-") ? "MIG " + resource.dropFirst("nvidia.com/mig-".count) : resource
    }

    /// How the scheduler gives a GPU resource, said under a pod's: a whole
    /// device (`nvidia.com/gpu`, `amd.com/gpu`), a time slice of one shared
    /// with other pods (`nvidia.com/gpu.shared`), a MIG instance — a slice
    /// of one, its own memory and engines (`nvidia.com/mig-*`).
    static func given(_ resource: String) -> String {
        if resource == "nvidia.com/gpu.shared" {
            return "\(resource): a time slice of a device, shared with the other pods given one: not the pod's alone, and others' work shows in its numbers."
        }
        if resource.hasPrefix("nvidia.com/mig-") {
            return "\(title(resource)): a MIG instance, a slice of a device with its own memory and engines: the pod's own while it runs, busy or not."
        }
        return "\(resource): given by the scheduler as whole devices: a pod's GPUs are its own while it runs, busy or not."
    }

    /// `1`, `2.5` — a count as said.
    static func count(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value) }
}

/// What the objects say of an object's GPUs: a node's resources and who
/// holds them, a pod's containers', a workload's template's. Nil from the
/// builders where there are none. Pure.
struct KubeGPUAllocation: Equatable, Sendable {
    /// A node's GPU resource: what it has, what it offers, what its active pods hold.
    struct Resource: Equatable, Sendable, Identifiable {
        var name: String
        var capacity: Double?
        var allocatable: Double?
        /// Held by its active pods; nil where the node's pods aren't read.
        var allocated: Double?
        var id: String { name }
    }

    /// Who holds GPUs: a pod (a node's, a workload's), or a container of the pod shown.
    struct Holder: Equatable, Sendable, Identifiable {
        var name: String
        var gpus: [String: Double]
        /// The pod to open (a node's holders).
        var pod: KubeRowID?
        var id: String { name }
    }

    var resources: [Resource] = []
    var holders: [Holder] = []
    /// What is said under it: how the numbers were read, what they leave out.
    var notes: [String] = []

    /// The lines the tab shows, in order.
    var lines: [String] {
        var out: [String] = []
        for resource in resources {
            var parts: [String] = []
            if let allocated = resource.allocated, let allocatable = resource.allocatable {
                parts.append("\(KubeGPU.count(allocated)) of \(KubeGPU.count(allocatable)) allocated")
                let free = allocatable - allocated
                parts.append(free > 0 ? "\(KubeGPU.count(free)) free" : "none free")
            } else if let allocated = resource.allocated {
                parts.append("\(KubeGPU.count(allocated)) given")
            } else if let allocatable = resource.allocatable {
                parts.append("\(KubeGPU.count(allocatable)) allocatable")
            }
            if let capacity = resource.capacity, capacity != resource.allocatable { parts.append("capacity \(KubeGPU.count(capacity))") }
            out.append(KubeGPU.title(resource.name) + ": " + parts.joined(separator: " · "))
        }
        for holder in holders {
            let held = holder.gpus.sorted { $0.key < $1.key }.map { "\(KubeGPU.count($0.value)) \(KubeGPU.title($0.key))" }.joined(separator: ", ")
            out.append("\(holder.name) holds \(held)")
        }
        return out
    }

    /// What the view's identifier and a scenario read: every line and note.
    var text: String { (lines + notes).joined(separator: "\n") }

    // MARK: Building

    /// A pod's: each container's GPUs; nil, none.
    static func pod(_ object: [String: Any]) -> KubeGPUAllocation? {
        let containers = KubePodCharts.containers(of: object).filter { !$0.gpus.isEmpty }
        guard !containers.isEmpty else { return nil }
        var totals: [String: Double] = [:]
        for container in containers { totals.merge(container.gpus, uniquingKeysWith: +) }
        return KubeGPUAllocation(
            resources: totals.keys.sorted().map { Resource(name: $0, allocated: totals[$0]) },
            holders: containers.map { Holder(name: "Container \($0.name)", gpus: $0.gpus) },
            notes: totals.keys.sorted().map(KubeGPU.given))
    }

    /// A node's: its GPU resources' capacity and allocatable, and — its
    /// pods read as objects — who holds them, the active pods only (the
    /// scheduler's count); nil where it offers none and none are held.
    static func node(_ object: [String: Any], pods: KubeNodePods?) -> KubeGPUAllocation? {
        let status = object["status"] as? [String: Any] ?? [:]
        let capacity = KubeGPU.resources(status["capacity"])
        let allocatable = KubeGPU.resources(status["allocatable"])
        let active = pods?.active.filter { !$0.gpus.isEmpty } ?? []
        var held: [String: Double] = [:]
        for pod in active { held.merge(pod.gpus, uniquingKeysWith: +) }
        let names = Set(capacity.keys).union(allocatable.keys).union(held.keys).sorted()
        guard !names.isEmpty else { return nil }
        var notes: [String] = []
        if pods == nil {
            notes.append("Who holds them is read with the node's pods (as objects, every 5 min while shown).")
        } else if pods?.more == true {
            notes.append("This node runs more than \(KubeNodePods.limit) pods: the pods past them aren't counted.")
        }
        return KubeGPUAllocation(
            resources: names.map { Resource(name: $0, capacity: capacity[$0], allocatable: allocatable[$0], allocated: pods == nil ? nil : held[$0] ?? 0) },
            holders: active.sorted { $0.id < $1.id }.map { Holder(name: $0.id.description, gpus: $0.gpus, pod: $0.id) }, notes: notes)
    }

    /// A workload's: what its template gives a pod, times the pods it runs now.
    static func workload(_ object: [String: Any], kind: String) -> KubeGPUAllocation? {
        let template = ((object["spec"] as? [String: Any])?["template"] as? [String: Any]) ?? [:]
        let containers = KubePodCharts.containers(of: ["spec": template["spec"] ?? [:]]).filter { !$0.gpus.isEmpty }
        guard !containers.isEmpty else { return nil }
        var perPod: [String: Double] = [:]
        for container in containers { perPod.merge(container.gpus, uniquingKeysWith: +) }
        let replicas = KubeWorkloadCharts.template(object, kind: kind).replicas
        return KubeGPUAllocation(
            resources: perPod.keys.sorted().map { Resource(name: $0, allocated: (perPod[$0] ?? 0) * Double(replicas)) },
            holders: [Holder(name: "Each pod (the template)", gpus: perPod)],
            notes: ["\(replicas) pod\(replicas == 1 ? "" : "s") now: what the template gives one, times them."])
    }

    /// The object's, by its subject; nil, none (or not a kind with GPUs).
    static func of(_ subject: KubeMetricsSubject, object: [String: Any], nodePods: KubeNodePods?) -> KubeGPUAllocation? {
        switch subject {
        case .pod: pod(object)
        case .node: node(object, pods: nodePods)
        case .workload(let kind): workload(object, kind: kind)
        case .hpa, .namespace: nil
        }
    }
}
