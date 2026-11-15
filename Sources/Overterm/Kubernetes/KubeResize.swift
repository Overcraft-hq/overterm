import Foundation

/// One container's cpu and memory, its requests and limits, as its pod's
/// spec says them (`"250m"`, `"512Mi"`; absent, nil). Pure.
struct KubeContainerResources: Equatable, Sendable {
    var name: String
    var cpuRequest: String?
    var cpuLimit: String?
    var memoryRequest: String?
    var memoryLimit: String?

    /// One of its four values, by place.
    subscript(_ field: KubeResize.Field) -> String? {
        get {
            switch field {
            case .cpuRequest: cpuRequest
            case .cpuLimit: cpuLimit
            case .memoryRequest: memoryRequest
            case .memoryLimit: memoryLimit
            }
        }
        set {
            switch field {
            case .cpuRequest: cpuRequest = newValue
            case .cpuLimit: cpuLimit = newValue
            case .memoryRequest: memoryRequest = newValue
            case .memoryLimit: memoryLimit = newValue
            }
        }
    }
}

/// In-place resize (stage 3b — docs/design/kubernetes/analysis.md, Section
/// 2.3): a running pod's containers given other cpu and memory requests and
/// limits through the `resize` subresource, without the pod being made
/// again — where discovery lists `pods/resize` (Kubernetes 1.33 and later);
/// elsewhere refused with why. Only regular containers' cpu and memory: the
/// subresource takes nothing else, and a value is changed, never removed —
/// nor so that the pod's QoS class changes (`qos`), which the server
/// refuses. The kubelet then applies it, or
/// says why not in the pod's `PodResizePending` condition. Pure.
enum KubeResize {
    /// The four values a container's row edits.
    enum Field: String, CaseIterable, Sendable {
        case cpuRequest, cpuLimit, memoryRequest, memoryLimit

        var resource: String {
            switch self {
            case .cpuRequest, .cpuLimit: "cpu"
            case .memoryRequest, .memoryLimit: "memory"
            }
        }

        /// `requests` or `limits`, as the spec groups them.
        var group: String {
            switch self {
            case .cpuRequest, .memoryRequest: "requests"
            case .cpuLimit, .memoryLimit: "limits"
            }
        }

        /// `cpu request`, `memory limit`.
        var spoken: String { resource + " " + (group == "requests" ? "request" : "limit") }

        /// What its field shows empty.
        var placeholder: String {
            switch self {
            case .cpuRequest: "cpu req"
            case .cpuLimit: "cpu limit"
            case .memoryRequest: "mem req"
            case .memoryLimit: "mem limit"
            }
        }
    }

    /// One value changed.
    struct Change: Equatable, Sendable {
        var container: String
        var field: Field
        /// What it is now; nil: unset.
        var from: String?
        var to: String

        /// `app: cpu request 100m → 250m`.
        var said: String { "\(container): \(field.spoken) \(from ?? "unset") → \(to)" }
    }

    /// Why a server can't: the subresource isn't served.
    static let unsupported =
        "This cluster doesn't serve in-place resize (pods/resize, Kubernetes 1.33 and later): change the controller's template, or delete the pod to have it made again."

    /// Whether `kind` is pods as a server that resizes in place serves them.
    static func supported(_ kind: KubeResourceKind) -> Bool { kind.subresources.contains("resize") }

    /// A pod's regular containers' values — not init or ephemeral ones.
    static func containers(of pod: [String: Any]) -> [KubeContainerResources] { resources(of: pod, "containers") }

    /// Its init containers' values: never resized, but counted in its QoS
    /// class, as the server counts them.
    static func initContainers(of pod: [String: Any]) -> [KubeContainerResources] { resources(of: pod, "initContainers") }

    private static func resources(of pod: [String: Any], _ key: String) -> [KubeContainerResources] {
        let spec = pod["spec"] as? [String: Any] ?? [:]
        return (spec[key] as? [[String: Any]] ?? []).compactMap { container in
            guard let name = container["name"] as? String else { return nil }
            let resources = container["resources"] as? [String: Any] ?? [:]
            let requests = resources["requests"] as? [String: Any] ?? [:]
            let limits = resources["limits"] as? [String: Any] ?? [:]
            func text(_ value: Any?) -> String? {
                switch value {
                case let string as String: string
                case let number as NSNumber: number.stringValue
                default: nil
                }
            }
            return KubeContainerResources(
                name: name, cpuRequest: text(requests["cpu"]), cpuLimit: text(limits["cpu"]), memoryRequest: text(requests["memory"]),
                memoryLimit: text(limits["memory"]))
        }
    }

    /// A pod's quality of service class, which a resize may not change.
    enum QoS: String, Sendable {
        case guaranteed = "Guaranteed"
        case burstable = "Burstable"
        case bestEffort = "BestEffort"
    }

    /// The class of a pod whose containers (regular and init) are these,
    /// by Kubernetes' rules (`GetPodQOS`): cpu and memory only, a value
    /// above zero counted, a missing request defaulted to its limit as the
    /// API server defaults it; BestEffort with none at all, Guaranteed when
    /// every container has both limits and the summed requests equal the
    /// summed limits, Burstable otherwise.
    static func qos(_ containers: [KubeContainerResources]) -> QoS {
        var requests: [String: Double] = [:]
        var limits: [String: Double] = [:]
        var guaranteed = true
        for container in containers {
            var limited: Set<String> = []
            for (request, limit) in [(Field.cpuRequest, Field.cpuLimit), (.memoryRequest, .memoryLimit)] {
                let l = container[limit].flatMap(KubeQuantity.value)
                if let r = container[request].flatMap(KubeQuantity.value) ?? l, r > 0 { requests[request.resource, default: 0] += r }
                if let l, l > 0 {
                    limits[limit.resource, default: 0] += l
                    limited.insert(limit.resource)
                }
            }
            if limited != ["cpu", "memory"] { guaranteed = false }
        }
        if requests.isEmpty && limits.isEmpty { return .bestEffort }
        if guaranteed {
            for (name, request) in requests {
                guard let limit = limits[name], abs(limit - request) <= max(abs(limit), abs(request)) * 1e-9 else {
                    guaranteed = false
                    break
                }
            }
        }
        return guaranteed && requests.count == limits.count ? .guaranteed : .burstable
    }

    /// Why a class can't go from one to the other in place.
    static func classChange(from before: QoS, to after: QoS) -> String {
        switch (before, after) {
        case (.guaranteed, _):
            "The pod is Guaranteed (each request equals its limit): change a request and its limit together — its QoS class can't change in place."
        case (.bestEffort, _):
            "The pod is BestEffort (no requests or limits): none can be given in place — its QoS class can't change."
        case (.burstable, .guaranteed):
            "Every request would equal its limit, making the pod Guaranteed: its QoS class (Burstable) can't change in place."
        case (.burstable, _):
            "The pod's QoS class would change from Burstable to \(after.rawValue): it can't in place."
        }
    }

    /// What is typed against what is there: the changes, or why it won't
    /// do — a value that isn't a quantity or is in the wrong unit, a value
    /// removed, a request over its limit, the pod's QoS class changed
    /// (`others`: its init containers, counted in it), nothing changed.
    static func plan(current: [KubeContainerResources], typed: [KubeContainerResources], others: [KubeContainerResources] = []) -> Result<
        [Change], KubeWriteRefused
    > {
        switch check(current: current, typed: typed, others: others) {
        case .success(let changes) where changes.isEmpty: .failure(KubeWriteRefused(reason: "Nothing changed."))
        case let result: result
        }
    }

    /// `plan`, an empty list for nothing changed.
    private static func check(current: [KubeContainerResources], typed: [KubeContainerResources], others: [KubeContainerResources]) -> Result<
        [Change], KubeWriteRefused
    > {
        var changes: [Change] = []
        var afterAll: [KubeContainerResources] = []
        for now in current {
            guard let wanted = typed.first(where: { $0.name == now.name }) else {
                afterAll.append(now)
                continue
            }
            var after = now
            for field in Field.allCases {
                let text = (wanted[field] ?? "").trimmingCharacters(in: .whitespaces)
                if text.isEmpty {
                    if let was = now[field] {
                        return .failure(KubeWriteRefused(reason: "\(now.name)'s \(field.spoken) (\(was)) can't be removed in place: its QoS class would change."))
                    }
                    continue
                }
                guard let value = KubeQuantity.value(text), value > 0 else {
                    return .failure(KubeWriteRefused(reason: "\(now.name)'s \(field.spoken): “\(text)” isn't a quantity (250m, 1, 512Mi, 2Gi)."))
                }
                if let wrong = wrongUnit(field, text) {
                    return .failure(KubeWriteRefused(reason: "\(now.name)'s \(field.spoken): \(wrong)"))
                }
                after[field] = text
                if let was = now[field], KubeQuantity.value(was) == value { continue }
                changes.append(Change(container: now.name, field: field, from: now[field], to: text))
            }
            for (request, limit) in [(Field.cpuRequest, Field.cpuLimit), (.memoryRequest, .memoryLimit)] {
                if let r = after[request].flatMap(KubeQuantity.value), let l = after[limit].flatMap(KubeQuantity.value), r > l {
                    return .failure(
                        KubeWriteRefused(reason: "\(now.name)'s \(request.spoken) (\(after[request] ?? "")) is over its limit (\(after[limit] ?? ""))."))
                }
            }
            afterAll.append(after)
        }
        let before = qos(current + others)
        let after = qos(afterAll + others)
        if before != after { return .failure(KubeWriteRefused(reason: classChange(from: before, to: after))) }
        return .success(changes)
    }

    /// Why a quantity is in the wrong unit for its resource: cpu in bytes
    /// or in thousands, millions… of cores (`1Gi`, `2G`, `500M`), memory in
    /// millibytes (`512m`, a slip for `512Mi`).
    static func wrongUnit(_ field: Field, _ text: String) -> String? {
        if field.resource == "cpu" {
            if text.hasSuffix("i") { return "cpu is in cores or millicores (500m, 2), not bytes." }
            if let last = text.last, "kMGTPE".contains(last) {
                return "cpu is in cores or millicores (500m, 2) — “\(text)” would be \(last == "k" ? "thousands" : "millions or more") of cores."
            }
        } else if text.hasSuffix("m") {
            return "“\(text)” is millibytes — memory is in bytes (512Mi, 2Gi, 512M)."
        }
        return nil
    }

    /// The changes against the pod as it is read now (`containers`, and its
    /// init containers in `others`): what they ask for typed over what it
    /// says, and planned again — each one's `from` what it says, those it
    /// says already dropped (none left: an empty list), refused for what
    /// the read makes wrong (a limit lowered under a request, a class
    /// changed); nil for a container no longer there.
    static func rebase(_ changes: [Change], on containers: [KubeContainerResources], others: [KubeContainerResources] = []) -> Result<
        [Change], KubeWriteRefused
    >? {
        var typed = containers
        for change in changes {
            guard let index = typed.firstIndex(where: { $0.name == change.container }) else { return nil }
            typed[index][change.field] = change.to
        }
        return check(current: containers, typed: typed, others: others)
    }

    /// The patch: each container by name (the strategic merge key), only
    /// what changed.
    static func patch(_ changes: [Change]) -> [String: Any] {
        var order: [String] = []
        var resources: [String: [String: [String: String]]] = [:]
        for change in changes {
            if resources[change.container] == nil { order.append(change.container) }
            resources[change.container, default: [:]][change.field.group, default: [:]][change.field.resource] = change.to
        }
        return ["spec": ["containers": order.map { ["name": $0, "resources": resources[$0] ?? [:]] as [String: Any] }]]
    }

    /// `PATCH …/pods/NAME/resize?fieldManager=overterm`, a strategic merge
    /// patch, as `kubectl patch --subresource resize` sends it (RBAC:
    /// `patch pods/resize`).
    static func request(_ ref: KubeObjectRef, _ changes: [Change]) -> KubeWriteRequest {
        KubeWriteRequest(
            method: .PATCH, path: KubePath.query(KubeWrites.path(ref) + "/resize", [("fieldManager", KubeWrites.fieldManager)]),
            body: KubeWrites.encode(patch(changes)), contentType: KubeWrites.strategicPatch)
    }

    /// The patch as kubectl's `-p` takes it.
    static func patchText(_ changes: [Change]) -> String { String(decoding: KubeWrites.encode(patch(changes)), as: UTF8.self) }

    /// What the confirmation lists, one line a change.
    static func said(_ changes: [Change]) -> String { changes.map(\.said).joined(separator: "\n") }
}

/// Resize…'s sheet: the pod's containers' values, before the write is asked for.
struct KubeResizeDraft: Equatable {
    var ref: KubeObjectRef
    /// What the pod says now; nil until read.
    var current: [KubeContainerResources]?
    /// What is typed, a row a container; filled from `current` once read.
    var typed: [KubeContainerResources] = []
    /// Its init containers' values: not edited, counted in its QoS class.
    var others: [KubeContainerResources] = []
    /// Why what is typed won't do, or why the pod couldn't be read.
    var problem: String?
}
