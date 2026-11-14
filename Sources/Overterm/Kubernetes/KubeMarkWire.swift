import Foundation

/// What a row keeps of its embedded metadata when its list asks for marks
/// (`KubeListOptions.marks`; docs/design/kubernetes/gitops.md, 14.4.3) —
/// Argo CD's marks and nothing else:
///
/// - `argocd.argoproj.io/tracking-id`, read by `KubeTrackingID` and
///   checked against the object it sits on (a copy names somebody else),
///   and `argocd.argoproj.io/installation-id`;
/// - the instance labels, `argocd.argoproj.io/instance` and
///   `app.kubernetes.io/instance` (with whether Helm's own release
///   annotation is beside it: then it is Helm's, not Argo CD's);
/// - the hints: a hook (`argocd.argoproj.io/hook`, else `helm.sh/hook`),
///   `ignore-healthcheck`, `sync-wave`, `sync-options`, `compare-options`,
///   and at most 5 `link.argocd.argoproj.io/*` — text, never opened;
/// - `metadata.generation`, `resourceVersion`, whether it is being deleted;
/// - from `managedFields`, two times only: the newest of Argo CD's own
///   managers (`argoManagers`) — when Argo CD last changed it, never a
///   person's `kubectl edit` or an HPA's write — and the newest of any.
///
/// kubectl's `last-applied-configuration`, every other annotation and
/// label, and `managedFields`' field sets are never kept. Every kept
/// string is the cluster's text: capped, without control characters.
/// Pure.
struct KubeMarkWire: Equatable, Hashable, Sendable {
    /// The tracking annotation as it reads against the object it sits on.
    enum Tracking: Equatable, Hashable, Sendable {
        case none
        /// It names this object: Argo CD tracks it.
        case own(KubeTrackingID)
        /// It names another object: a copy (a ReplicaSet's of its
        /// Deployment's, an operator's of its resource's) — nobody's member.
        case copied(KubeTrackingID)
        /// There, but not a value Argo CD writes (`KubeTrackingID.parse`):
        /// counted, never shown.
        case unparsed
    }

    /// One `link.argocd.argoproj.io/<name>` annotation: text to copy, never
    /// a URL opened (decision D-3).
    struct Link: Equatable, Hashable, Sendable {
        var name: String
        var value: String
    }

    var tracking: Tracking = .none
    /// `argocd.argoproj.io/installation-id`, checked; nil when none.
    var installation: String?
    /// The installation id was there but malformed: the mark is nobody's.
    var installationUnparsed = false
    /// `argocd.argoproj.io/instance`, checked as an app name.
    var argoInstance: String?
    /// `app.kubernetes.io/instance`, checked as an app name.
    var appInstance: String?
    /// Helm's own `meta.helm.sh/release-name` is there: `appInstance` is Helm's.
    var helmRelease = false
    /// Argo CD's hook type, else Helm's: a hook isn't in the app's health.
    var hook: String?
    /// `argocd.argoproj.io/ignore-healthcheck: "true"`.
    var ignoreHealthcheck = false
    var syncWave: String?
    var syncOptions: String?
    var compareOptions: String?
    var links: [Link] = []
    var generation: Int?
    var resourceVersion: String?
    /// `metadata.deletionTimestamp` is set.
    var deleting = false
    /// The newest `managedFields` time of one of Argo CD's own managers:
    /// "last change applied by Argo CD", never "last sync".
    var argoChanged: Date?
    /// The newest `managedFields` time of any manager: most recently
    /// changed first, for the settle's order.
    var lastChanged: Date?

    static let installationAnnotation = KubeTrackingID.installationAnnotation
    static let hookAnnotation = "argocd.argoproj.io/hook"
    static let helmHookAnnotation = "helm.sh/hook"
    static let ignoreHealthcheckAnnotation = "argocd.argoproj.io/ignore-healthcheck"
    static let syncWaveAnnotation = "argocd.argoproj.io/sync-wave"
    static let syncOptionsAnnotation = "argocd.argoproj.io/sync-options"
    static let compareOptionsAnnotation = "argocd.argoproj.io/compare-options"
    static let linkPrefix = "link.argocd.argoproj.io/"

    /// The field managers that are Argo CD's own: server-side apply's
    /// `argocd-controller`, and the controller's and the server's names.
    /// Nothing else is ever taken for Argo CD's change.
    static let argoManagers: Set<String> = ["argocd-controller", "argocd-application-controller", "argocd-server"]

    /// At most this many links are kept.
    static let linksKept = 5
    /// A hint's or a link name's length, at most.
    static let hintCap = 256
    /// A link's value, at most.
    static let linkCap = 512

    /// Whether Argo CD marked it: a tracking id of any kind, or its
    /// instance label. Helm's `app.kubernetes.io/instance` isn't one.
    var hasArgoMark: Bool { tracking != .none || argoInstance != nil }

    /// What the allow-list keeps of `metadata` (a row's embedded
    /// `PartialObjectMetadata`, an object's own), checked against `object`
    /// — the kind listed and the row's name and namespace, never what the
    /// embedded metadata says it is. nil without metadata.
    static func read(metadata: [String: Any]?, self object: KubeTrackingID.Identity) -> KubeMarkWire? {
        guard let metadata else { return nil }
        let annotations = metadata["annotations"] as? [String: Any] ?? [:]
        let labels = metadata["labels"] as? [String: Any] ?? [:]
        var wire = KubeMarkWire()
        if let value = annotations[KubeGitOpsOwner.trackingAnnotation] as? String {
            if let id = KubeTrackingID.parse(value) {
                wire.tracking = id.isSelf(object) ? .own(id) : .copied(id)
            } else {
                wire.tracking = .unparsed
            }
        }
        if let value = annotations[installationAnnotation] as? String, !value.isEmpty {
            if let checked = KubeTrackingID.installation(value) { wire.installation = checked } else { wire.installationUnparsed = true }
        }
        wire.argoInstance = (labels[KubeGitOpsOwner.argoInstanceLabel] as? String).flatMap(KubeTrackingID.instanceLabel)
        wire.appInstance = (labels[KubeGitOpsOwner.appInstanceLabel] as? String).flatMap(KubeTrackingID.instanceLabel)
        wire.helmRelease = annotations[KubeGitOpsOwner.helmReleaseAnnotation] != nil
        wire.hook = text(annotations[hookAnnotation], cap: hintCap) ?? text(annotations[helmHookAnnotation], cap: hintCap)
        wire.ignoreHealthcheck = (annotations[ignoreHealthcheckAnnotation] as? String)?.lowercased() == "true"
        wire.syncWave = text(annotations[syncWaveAnnotation], cap: hintCap)
        wire.syncOptions = text(annotations[syncOptionsAnnotation], cap: hintCap)
        wire.compareOptions = text(annotations[compareOptionsAnnotation], cap: hintCap)
        wire.links = annotations.keys.filter { $0.hasPrefix(linkPrefix) }.sorted().prefix(linksKept).compactMap { key in
            guard let name = text(String(key.dropFirst(linkPrefix.count)), cap: hintCap), let value = text(annotations[key], cap: linkCap) else { return nil }
            return Link(name: name, value: value)
        }
        wire.generation = (metadata["generation"] as? NSNumber)?.intValue
        wire.resourceVersion = text(metadata["resourceVersion"], cap: 64)
        wire.deleting = metadata["deletionTimestamp"] is String
        for field in metadata["managedFields"] as? [[String: Any]] ?? [] {
            guard let time = (field["time"] as? String).flatMap({ try? Date($0, strategy: .iso8601) }) else { continue }
            wire.lastChanged = max(wire.lastChanged ?? time, time)
            if let manager = field["manager"] as? String, argoManagers.contains(manager) { wire.argoChanged = max(wire.argoChanged ?? time, time) }
        }
        return wire
    }

    /// A cluster's string as kept: control characters out, at most `cap`
    /// characters; nil for nothing.
    static func text(_ value: Any?, cap: Int) -> String? {
        guard let value = value as? String else { return nil }
        var kept = String.UnicodeScalarView()
        var count = 0
        for scalar in value.unicodeScalars where scalar.properties.generalCategory != .control {
            kept.append(scalar)
            count += 1
            if count >= cap { break }
        }
        let out = String(kept).trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? nil : out
    }
}

/// One workload, CronJob, HPA or Argo Rollout as a GET answers it, for its
/// health by Argo CD's own rule (gitops.md, 14.4.3 and 14.5): a `Decodable`
/// that declares only what that rule reads, so the decode is the
/// allow-list — no field outside it is parsed into memory. It keeps:
///
/// - `metadata.name`, `namespace`, `resourceVersion`, `generation`, and
///   whether it is being deleted;
/// - `spec.paused`, `spec.replicas`, `spec.suspend`, the strategy's type
///   and `rollingUpdate.partition`, a Rollout's `workloadRef`, each
///   container's name and image (a CronJob's through its job template);
/// - `status`: generations and replica counts, a DaemonSet's scheduled
///   numbers, the revisions, a CronJob's last schedule and success and its
///   active jobs counted, a Rollout's phase and message, and the
///   conditions — type, status, reason, time, and a message scrubbed
///   (`Secrets.scrubCredentials`) and cut to 300 characters as it is read.
///
/// Never env, args, command, volumes, annotations, labels, kubectl's
/// last-applied copy, or the template beyond its images. Pure.
struct KubeMarkedWorkloadWire: Decodable, Equatable, Sendable {
    var apiVersion: String?
    var kind: String?
    var metadata: Metadata?
    var spec: Spec?
    var status: Status?

    /// A condition's or a Rollout's message, at most.
    static let messageCap = 300
    /// Containers kept, at most.
    static let containersKept = 20

    enum CodingKeys: String, CodingKey, CaseIterable { case apiVersion, kind, metadata, spec, status }

    /// One object's answer.
    static func decode(_ data: Data) throws -> KubeMarkedWorkloadWire {
        try JSONDecoder().decode(KubeMarkedWorkloadWire.self, from: data)
    }

    /// The group its `apiVersion` names, "" for the core group.
    var group: String {
        guard let apiVersion, let slash = apiVersion.firstIndex(of: "/") else { return "" }
        return String(apiVersion[..<slash])
    }

    struct Metadata: Decodable, Equatable, Sendable {
        var name: String?
        var namespace: String?
        var resourceVersion: String?
        var generation: Int?
        var deletionTimestamp: String?

        enum CodingKeys: String, CodingKey, CaseIterable { case name, namespace, resourceVersion, generation, deletionTimestamp }
    }

    struct Spec: Decodable, Equatable, Sendable {
        var paused: Bool?
        var replicas: Int?
        var suspend: Bool?
        /// A Deployment's.
        var strategy: Strategy?
        /// A StatefulSet's or a DaemonSet's.
        var updateStrategy: Strategy?
        var template: Template?
        /// A CronJob's.
        var jobTemplate: JobTemplate?
        /// An Argo Rollout's: the Deployment it runs instead of.
        var workloadRef: WorkloadRef?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case paused, replicas, suspend, strategy, updateStrategy, template, jobTemplate, workloadRef
        }
    }

    struct Strategy: Decodable, Equatable, Sendable {
        var type: String?
        var rollingUpdate: RollingUpdate?

        enum CodingKeys: String, CodingKey, CaseIterable { case type, rollingUpdate }
    }

    struct RollingUpdate: Decodable, Equatable, Sendable {
        var partition: Int?

        enum CodingKeys: String, CodingKey, CaseIterable { case partition }
    }

    struct Template: Decodable, Equatable, Sendable {
        var spec: PodSpec?

        enum CodingKeys: String, CodingKey, CaseIterable { case spec }
    }

    struct PodSpec: Decodable, Equatable, Sendable {
        var containers: [Container]?

        enum CodingKeys: String, CodingKey, CaseIterable { case containers }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            containers = try container.decodeIfPresent([Container].self, forKey: .containers).map { Array($0.prefix(KubeMarkedWorkloadWire.containersKept)) }
        }
    }

    struct Container: Decodable, Equatable, Sendable {
        var name: String?
        var image: String?

        enum CodingKeys: String, CodingKey, CaseIterable { case name, image }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = KubeMarkWire.text(try container.decodeIfPresent(String.self, forKey: .name), cap: 253)
            image = KubeMarkWire.text(try container.decodeIfPresent(String.self, forKey: .image), cap: KubeMarkWire.linkCap)
        }
    }

    struct JobTemplate: Decodable, Equatable, Sendable {
        var spec: JobSpec?

        enum CodingKeys: String, CodingKey, CaseIterable { case spec }
    }

    struct JobSpec: Decodable, Equatable, Sendable {
        var template: Template?

        enum CodingKeys: String, CodingKey, CaseIterable { case template }
    }

    struct WorkloadRef: Decodable, Equatable, Sendable {
        var apiVersion: String?
        var kind: String?
        var name: String?

        enum CodingKeys: String, CodingKey, CaseIterable { case apiVersion, kind, name }
    }

    struct Status: Decodable, Equatable, Sendable {
        /// An integer, or — an Argo Rollout's — the same as a string.
        var observedGeneration: Int?
        var replicas: Int?
        var updatedReplicas: Int?
        var readyReplicas: Int?
        var availableReplicas: Int?
        var desiredNumberScheduled: Int?
        var updatedNumberScheduled: Int?
        var numberAvailable: Int?
        var currentRevision: String?
        var updateRevision: String?
        var conditions: [Condition]?
        var lastScheduleTime: String?
        var lastSuccessfulTime: String?
        /// How many jobs a CronJob has running: the list counted, never read.
        var active: Int?
        /// An Argo Rollout's: Healthy, Progressing, Degraded, Paused.
        var phase: String?
        /// An Argo Rollout's, scrubbed and cut.
        var message: String?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case observedGeneration, replicas, updatedReplicas, readyReplicas, availableReplicas, desiredNumberScheduled, updatedNumberScheduled
            case numberAvailable, currentRevision, updateRevision, conditions, lastScheduleTime, lastSuccessfulTime, active, phase, message
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let number = try? container.decodeIfPresent(Int.self, forKey: .observedGeneration) {
                observedGeneration = number
            } else {
                observedGeneration = (try? container.decodeIfPresent(String.self, forKey: .observedGeneration)).flatMap { $0.flatMap { Int($0) } }
            }
            replicas = try container.decodeIfPresent(Int.self, forKey: .replicas)
            updatedReplicas = try container.decodeIfPresent(Int.self, forKey: .updatedReplicas)
            readyReplicas = try container.decodeIfPresent(Int.self, forKey: .readyReplicas)
            availableReplicas = try container.decodeIfPresent(Int.self, forKey: .availableReplicas)
            desiredNumberScheduled = try container.decodeIfPresent(Int.self, forKey: .desiredNumberScheduled)
            updatedNumberScheduled = try container.decodeIfPresent(Int.self, forKey: .updatedNumberScheduled)
            numberAvailable = try container.decodeIfPresent(Int.self, forKey: .numberAvailable)
            currentRevision = KubeMarkWire.text(try container.decodeIfPresent(String.self, forKey: .currentRevision), cap: 253)
            updateRevision = KubeMarkWire.text(try container.decodeIfPresent(String.self, forKey: .updateRevision), cap: 253)
            conditions = try container.decodeIfPresent([Condition].self, forKey: .conditions).map { Array($0.prefix(20)) }
            lastScheduleTime = KubeMarkWire.text(try container.decodeIfPresent(String.self, forKey: .lastScheduleTime), cap: 64)
            lastSuccessfulTime = KubeMarkWire.text(try container.decodeIfPresent(String.self, forKey: .lastSuccessfulTime), cap: 64)
            active = try container.decodeIfPresent([Skipped].self, forKey: .active)?.count
            phase = KubeMarkWire.text(try container.decodeIfPresent(String.self, forKey: .phase), cap: 64)
            message = KubeMarkedWorkloadWire.message(try container.decodeIfPresent(String.self, forKey: .message))
        }
    }

    struct Condition: Decodable, Equatable, Sendable {
        var type: String?
        var status: String?
        var reason: String?
        var lastTransitionTime: String?
        /// Scrubbed and cut to 300 characters as it is read: the hover's and
        /// the brief's, never a row's sentence.
        var message: String?

        enum CodingKeys: String, CodingKey, CaseIterable { case type, status, reason, lastTransitionTime, message }

        init(type: String?, status: String?, reason: String? = nil, lastTransitionTime: String? = nil, message: String? = nil) {
            self.type = type
            self.status = status
            self.reason = reason
            self.lastTransitionTime = lastTransitionTime
            self.message = message
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = KubeMarkWire.text(try container.decodeIfPresent(String.self, forKey: .type), cap: 128)
            status = KubeMarkWire.text(try container.decodeIfPresent(String.self, forKey: .status), cap: 16)
            reason = KubeMarkWire.text(try container.decodeIfPresent(String.self, forKey: .reason), cap: 128)
            lastTransitionTime = KubeMarkWire.text(try container.decodeIfPresent(String.self, forKey: .lastTransitionTime), cap: 64)
            message = KubeMarkedWorkloadWire.message(try container.decodeIfPresent(String.self, forKey: .message))
        }

        var since: Date? { lastTransitionTime.flatMap { try? Date($0, strategy: .iso8601) } }
    }

    /// An element read for its count alone: no key of it is decoded.
    private struct Skipped: Decodable {}

    /// A message as kept: scrubbed whole (a credential cut in half could
    /// slip past the patterns), then cut to `messageCap` characters. A
    /// message past 4,096 is cut to that before it is scrubbed.
    static func message(_ value: String?) -> String? {
        guard let bounded = KubeMarkWire.text(value, cap: 4096) else { return nil }
        return KubeMarkWire.text(Secrets.scrubCredentials(bounded), cap: messageCap)
    }

    /// Each container's image, in order.
    var images: [String] {
        let pod = spec?.template?.spec ?? spec?.jobTemplate?.spec?.template?.spec
        return (pod?.containers ?? []).compactMap(\.image)
    }

    func condition(_ type: String) -> Condition? { status?.conditions?.first { $0.type == type } }
}
