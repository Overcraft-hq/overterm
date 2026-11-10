import Foundation

/// An Argo CD or Flux object as its summary reads it (docs/design/
/// kubernetes/gitops.md, 2.4, decision 15): `Decodable` structs that
/// declare only what a summary needs, so the decode is the allow-list
/// itself — no `[String: Any]` tree is built, and no field outside it is
/// parsed into memory. Never declared: Helm values (`values`,
/// `valuesObject`, `parameters`, `fileParameters`), `plugin.env`, jsonnet's
/// `extVars` and `tlas`, every `patches`, `postBuild`, generator
/// `elements`, Argo's copies of the source in `status` (`comparedTo`,
/// `history[].source`, the operation's), `operation.sync.manifests`,
/// kubectl's last-applied copy, `history` past the entry wanted, inventory
/// and `status.resources` past their counts and namespaces. A URL loses its
/// userinfo as it is decoded. `KubeGitOpsWireTests` checks every struct's
/// keys against a reviewed list. Pure.
enum KubeGitOpsWire {
    /// What a struct here declares: its keys, for the reviewed list.
    protocol Declared {
        static var keys: [String] { get }
    }

    /// Every struct's declared keys, by name — what the test reviews.
    static var declared: [String: [String]] {
        let all: [(String, [String])] = [
            ("Object", Object.keys), ("List", List.keys), ("ListMetadata", ListMetadata.keys), ("Metadata", Metadata.keys), ("Labels", Labels.keys),
            ("Annotations", Annotations.keys), ("OwnerReference", OwnerReference.keys), ("ManagedField", ManagedField.keys),
            ("FieldsV1", FieldsV1.keys), ("Spec", Spec.keys), ("ArgoSource", ArgoSource.keys), ("Destination", Destination.keys),
            ("SyncPolicy", SyncPolicy.keys), ("Automated", Automated.keys), ("Retry", Retry.keys), ("Hydrator", Hydrator.keys),
            ("DrySource", DrySource.keys), ("Reference", Reference.keys), ("Chart", Chart.keys), ("ChartSpec", ChartSpec.keys),
            ("KubeConfig", KubeConfig.keys), ("Named", Named.keys), ("GitRef", GitRef.keys), ("Status", Status.keys), ("Sync", Sync.keys),
            ("Health", Health.keys), ("Condition", Condition.keys), ("OperationState", OperationState.keys), ("Operation", Operation.keys),
            ("InitiatedBy", InitiatedBy.keys), ("SyncResult", SyncResult.keys), ("SyncResource", SyncResource.keys),
            ("HistoryEntry", HistoryEntry.keys), ("ResourceEntry", ResourceEntry.keys), ("Summary", Summary.keys), ("Inventory", Inventory.keys),
            ("InventoryEntry", InventoryEntry.keys), ("Artifact", Artifact.keys), ("ArtifactMetadata", ArtifactMetadata.keys),
            ("Detail", Detail.keys), ("DetailStatus", DetailStatus.keys), ("DetailOperationState", DetailOperationState.keys),
            ("DetailSyncResult", DetailSyncResult.keys), ("DetailResource", DetailResource.keys),
        ]
        return Dictionary(uniqueKeysWithValues: all)
    }

    /// The most entries of `status.resources` and an inventory whose
    /// namespaces are kept (gitops.md, 2.4: 64).
    static let namespacesKept = 64
    /// `status.summary.images`, at most.
    static let imagesKept = 20

    // MARK: The object

    struct Object: Decodable, Sendable, Declared {
        var apiVersion: String?
        var kind: String?
        var metadata: Metadata?
        var spec: Spec?
        var status: Status?

        enum CodingKeys: String, CodingKey, CaseIterable { case apiVersion, kind, metadata, spec, status }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// A page of a list: its objects and where the next starts.
    struct List: Decodable, Sendable, Declared {
        var metadata: ListMetadata?
        var items: [Object]?

        enum CodingKeys: String, CodingKey, CaseIterable { case metadata, items }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    struct ListMetadata: Decodable, Sendable, Declared {
        var `continue`: String?
        var remainingItemCount: Int?
        var resourceVersion: String?

        enum CodingKeys: String, CodingKey, CaseIterable { case `continue`, remainingItemCount, resourceVersion }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    struct Metadata: Decodable, Sendable, Declared {
        var name: String?
        var namespace: String?
        var uid: String?
        var resourceVersion: String?
        var generation: Int?
        var creationTimestamp: String?
        var deletionTimestamp: String?
        var labels: Labels?
        var annotations: Annotations?
        var ownerReferences: [OwnerReference]?
        var managedFields: [ManagedField]?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case name, namespace, uid, resourceVersion, generation, creationTimestamp, deletionTimestamp, labels, annotations, ownerReferences
            case managedFields
        }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// The labels that name what deploys it (`KubeGitOpsOwner`), no other.
    struct Labels: Decodable, Sendable, Declared {
        var argoInstance: String?
        var appInstance: String?
        var kustomizeName: String?
        var kustomizeNamespace: String?
        var helmName: String?
        var helmNamespace: String?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case argoInstance = "argocd.argoproj.io/instance"
            case appInstance = "app.kubernetes.io/instance"
            case kustomizeName = "kustomize.toolkit.fluxcd.io/name"
            case kustomizeNamespace = "kustomize.toolkit.fluxcd.io/namespace"
            case helmName = "helm.toolkit.fluxcd.io/name"
            case helmNamespace = "helm.toolkit.fluxcd.io/namespace"
        }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        var marks: [String: String] {
            var marks: [String: String] = [:]
            marks[KubeGitOpsOwner.argoInstanceLabel] = argoInstance
            marks[KubeGitOpsOwner.appInstanceLabel] = appInstance
            marks[KubeGitOpsOwner.kustomizeName] = kustomizeName
            marks[KubeGitOpsOwner.kustomizeNamespace] = kustomizeNamespace
            marks[KubeGitOpsOwner.helmName] = helmName
            marks[KubeGitOpsOwner.helmNamespace] = helmNamespace
            return marks
        }
    }

    /// The annotations a summary reads: the tracking id, Helm's release
    /// name (whether `app.kubernetes.io/instance` is Helm's), Argo CD's
    /// `manifest-generate-paths`. Never kubectl's last-applied copy.
    struct Annotations: Decodable, Sendable, Declared {
        var trackingID: String?
        var helmRelease: String?
        var manifestGeneratePaths: String?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case trackingID = "argocd.argoproj.io/tracking-id"
            case helmRelease = "meta.helm.sh/release-name"
            case manifestGeneratePaths = "argocd.argoproj.io/manifest-generate-paths"
        }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        var marks: [String: String] {
            var marks: [String: String] = [:]
            marks[KubeGitOpsOwner.trackingAnnotation] = trackingID
            marks[KubeGitOpsOwner.helmReleaseAnnotation] = helmRelease
            return marks
        }
    }

    struct OwnerReference: Decodable, Sendable, Declared {
        var apiVersion: String?
        var kind: String?
        var name: String?
        var controller: Bool?

        enum CodingKeys: String, CodingKey, CaseIterable { case apiVersion, kind, name, controller }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// One managedFields entry: when, who, and only whether it owns
    /// `spec` and `spec.suspend` — the rest of `fieldsV1` is looked at by
    /// key, never decoded.
    struct ManagedField: Decodable, Sendable, Declared {
        var manager: String?
        var operation: String?
        var time: String?
        var fieldsV1: FieldsV1?

        enum CodingKeys: String, CodingKey, CaseIterable { case manager, operation, time, fieldsV1 }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    struct FieldsV1: Decodable, Sendable, Declared {
        var spec = false
        var suspend = false

        static var keys: [String] { ["f:spec", "f:suspend"] }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            let key = AnyKey("f:spec")
            guard container.contains(key) else { return }
            spec = true
            if let inner = try? container.nestedContainer(keyedBy: AnyKey.self, forKey: key) { suspend = inner.contains(AnyKey("f:suspend")) }
        }
    }

    // MARK: spec

    struct Spec: Decodable, Sendable, Declared {
        // Argo CD
        var source: ArgoSource?
        var sources: [ArgoSource]?
        var destination: Destination?
        var project: String?
        var syncPolicy: SyncPolicy?
        var sourceHydrator: Hydrator?
        // Flux
        var suspend: Bool?
        var interval: String?
        var retryInterval: String?
        var path: String?
        var prune: Bool?
        var targetNamespace: String?
        var sourceRef: Reference?
        var chartRef: Reference?
        var chart: Chart?
        var dependsOn: [Reference]?
        var kubeConfig: KubeConfig?
        // Flux's sources
        var url: String?
        var ref: GitRef?
        var endpoint: String?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case source, sources, destination, project, syncPolicy, sourceHydrator
            case suspend, interval, retryInterval, path, prune, targetNamespace, sourceRef, chartRef, chart, dependsOn, kubeConfig
            case url, ref, endpoint
        }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = try? c.decodeIfPresent(ArgoSource.self, forKey: .source)
            sources = try? c.decodeIfPresent([ArgoSource].self, forKey: .sources)
            destination = try? c.decodeIfPresent(Destination.self, forKey: .destination)
            project = try? c.decodeIfPresent(String.self, forKey: .project)
            syncPolicy = try? c.decodeIfPresent(SyncPolicy.self, forKey: .syncPolicy)
            sourceHydrator = try? c.decodeIfPresent(Hydrator.self, forKey: .sourceHydrator)
            suspend = try? c.decodeIfPresent(Bool.self, forKey: .suspend)
            interval = try? c.decodeIfPresent(String.self, forKey: .interval)
            retryInterval = try? c.decodeIfPresent(String.self, forKey: .retryInterval)
            path = try? c.decodeIfPresent(String.self, forKey: .path)
            prune = try? c.decodeIfPresent(Bool.self, forKey: .prune)
            targetNamespace = try? c.decodeIfPresent(String.self, forKey: .targetNamespace)
            sourceRef = try? c.decodeIfPresent(Reference.self, forKey: .sourceRef)
            chartRef = try? c.decodeIfPresent(Reference.self, forKey: .chartRef)
            chart = try? c.decodeIfPresent(Chart.self, forKey: .chart)
            dependsOn = try? c.decodeIfPresent([Reference].self, forKey: .dependsOn)
            kubeConfig = try? c.decodeIfPresent(KubeConfig.self, forKey: .kubeConfig)
            url = (try? c.decodeIfPresent(String.self, forKey: .url)).flatMap { $0.map(GitRemoteURL.withoutUserinfo) }
            // An Argo source's `ref` is a word; a GitRepository's an object.
            ref = try? c.decodeIfPresent(GitRef.self, forKey: .ref)
            endpoint = try? c.decodeIfPresent(String.self, forKey: .endpoint)
        }
    }

    /// One Argo CD source: where, never what it is rendered with (`helm`,
    /// `kustomize`, `directory`, `plugin` aren't declared).
    struct ArgoSource: Decodable, Sendable, Declared {
        var repoURL: String?
        var path: String?
        var chart: String?
        var targetRevision: String?
        var ref: String?

        enum CodingKeys: String, CodingKey, CaseIterable { case repoURL, path, chart, targetRevision, ref }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            repoURL = (try? c.decodeIfPresent(String.self, forKey: .repoURL)).flatMap { $0.map(GitRemoteURL.withoutUserinfo) }
            path = try? c.decodeIfPresent(String.self, forKey: .path)
            chart = try? c.decodeIfPresent(String.self, forKey: .chart)
            targetRevision = try? c.decodeIfPresent(String.self, forKey: .targetRevision)
            ref = try? c.decodeIfPresent(String.self, forKey: .ref)
        }

        var source: KubeGitOpsSource {
            KubeGitOpsSource(
                repoURL: repoURL ?? "", path: path.nonEmpty, chart: chart.nonEmpty, targetRevision: targetRevision.nonEmpty, ref: ref.nonEmpty)
        }
    }

    struct Destination: Decodable, Sendable, Declared {
        var server: String?
        var name: String?
        var namespace: String?

        enum CodingKeys: String, CodingKey, CaseIterable { case server, name, namespace }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        /// `server` without its userinfo, as every URL here (gitops.md, 5.2).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            server = (try? c.decodeIfPresent(String.self, forKey: .server)).flatMap { $0.map(GitRemoteURL.withoutUserinfo) }
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            namespace = try? c.decodeIfPresent(String.self, forKey: .namespace)
        }
    }

    struct SyncPolicy: Decodable, Sendable, Declared {
        var automated: Automated?
        var retry: Retry?

        enum CodingKeys: String, CodingKey, CaseIterable { case automated, retry }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// `automated` — `enabled` is Argo CD 3's (checked against its CRD, 8.5).
    struct Automated: Decodable, Sendable, Declared {
        var enabled: Bool?
        var prune: Bool?
        var selfHeal: Bool?

        enum CodingKeys: String, CodingKey, CaseIterable { case enabled, prune, selfHeal }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    struct Retry: Decodable, Sendable, Declared {
        var limit: Int?

        enum CodingKeys: String, CodingKey, CaseIterable { case limit }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// `sourceHydrator`, Argo CD 3's: its dry source is where the manifests come from.
    struct Hydrator: Decodable, Sendable, Declared {
        var drySource: DrySource?

        enum CodingKeys: String, CodingKey, CaseIterable { case drySource }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    struct DrySource: Decodable, Sendable, Declared {
        var repoURL: String?
        var path: String?
        var targetRevision: String?

        enum CodingKeys: String, CodingKey, CaseIterable { case repoURL, path, targetRevision }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            repoURL = (try? c.decodeIfPresent(String.self, forKey: .repoURL)).flatMap { $0.map(GitRemoteURL.withoutUserinfo) }
            path = try? c.decodeIfPresent(String.self, forKey: .path)
            targetRevision = try? c.decodeIfPresent(String.self, forKey: .targetRevision)
        }
    }

    /// A Flux reference: `sourceRef`, `chartRef`, a `dependsOn` entry.
    struct Reference: Decodable, Sendable, Declared {
        var apiVersion: String?
        var kind: String?
        var name: String?
        var namespace: String?

        enum CodingKeys: String, CodingKey, CaseIterable { case apiVersion, kind, name, namespace }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// A HelmRelease's chart template.
    struct Chart: Decodable, Sendable, Declared {
        var spec: ChartSpec?

        enum CodingKeys: String, CodingKey, CaseIterable { case spec }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    struct ChartSpec: Decodable, Sendable, Declared {
        var chart: String?
        var version: String?
        var sourceRef: Reference?

        enum CodingKeys: String, CodingKey, CaseIterable { case chart, version, sourceRef }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// `spec.kubeConfig`: the Secret's or ConfigMap's name, nothing in it.
    struct KubeConfig: Decodable, Sendable, Declared {
        var secretRef: Named?
        var configMapRef: Named?

        enum CodingKeys: String, CodingKey, CaseIterable { case secretRef, configMapRef }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        /// `spec.kubeConfig.secretRef acme-edge`, as the tree says it.
        var said: String {
            if let name = secretRef?.name { return "spec.kubeConfig.secretRef \(name)" }
            if let name = configMapRef?.name { return "spec.kubeConfig.configMapRef \(name)" }
            return "spec.kubeConfig"
        }
    }

    struct Named: Decodable, Sendable, Declared {
        var name: String?

        enum CodingKeys: String, CodingKey, CaseIterable { case name }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// A GitRepository's `spec.ref`.
    struct GitRef: Decodable, Sendable, Declared {
        var branch: String?
        var tag: String?
        var semver: String?
        var name: String?
        var commit: String?

        enum CodingKeys: String, CodingKey, CaseIterable { case branch, tag, semver, name, commit }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        /// What it tracks, by Flux's precedence: commit > name > semver > tag > branch.
        var tracks: String? { commit.nonEmpty ?? name.nonEmpty ?? semver.nonEmpty ?? tag.nonEmpty ?? branch.nonEmpty }
    }

    // MARK: status

    struct Status: Decodable, Sendable, Declared {
        // Argo CD
        var sync: Sync?
        var health: Health?
        var operationState: OperationState?
        /// `history`: Argo CD's last entry, Flux's first (a HelmRelease's newest).
        var historyFirst: HistoryEntry?
        var historyLast: HistoryEntry?
        var reconciledAt: String?
        var resourceHealthSource: String?
        var resources: ResourcesDigest?
        var summary: Summary?
        // Both
        var conditions: [Condition]?
        var observedGeneration: Int?
        // Flux
        var lastAppliedRevision: String?
        var lastAttemptedRevision: String?
        /// A HelmRelease's: the digest of the chart it last tried, from a `chartRef`'s OCIRepository.
        var lastAttemptedRevisionDigest: String?
        var inventory: Inventory?
        var artifact: Artifact?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case sync, health, operationState, history, reconciledAt, resourceHealthSource, resources, summary
            case conditions, observedGeneration
            case lastAppliedRevision, lastAttemptedRevision, lastAttemptedRevisionDigest, inventory, artifact
        }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sync = try? c.decodeIfPresent(Sync.self, forKey: .sync)
            health = try? c.decodeIfPresent(Health.self, forKey: .health)
            operationState = try? c.decodeIfPresent(OperationState.self, forKey: .operationState)
            if var history = try? c.nestedUnkeyedContainer(forKey: .history) {
                // Only the two ends: every entry in between is skipped, never decoded.
                let count = history.count ?? 0
                var index = 0
                while !history.isAtEnd {
                    if (try? history.decodeNil()) == true {
                        index += 1
                        continue
                    }
                    if index == 0 || index == count - 1, let entry = try? history.decode(HistoryEntry.self) {
                        if index == 0 { historyFirst = entry }
                        if index == count - 1 { historyLast = entry }
                    } else {
                        _ = try? history.decode(Skip.self)
                    }
                    index += 1
                }
            }
            reconciledAt = try? c.decodeIfPresent(String.self, forKey: .reconciledAt)
            resourceHealthSource = try? c.decodeIfPresent(String.self, forKey: .resourceHealthSource)
            resources = try? c.decodeIfPresent(ResourcesDigest.self, forKey: .resources)
            summary = try? c.decodeIfPresent(Summary.self, forKey: .summary)
            conditions = try? c.decodeIfPresent([Condition].self, forKey: .conditions)
            observedGeneration = try? c.decodeIfPresent(Int.self, forKey: .observedGeneration)
            lastAppliedRevision = try? c.decodeIfPresent(String.self, forKey: .lastAppliedRevision)
            lastAttemptedRevision = try? c.decodeIfPresent(String.self, forKey: .lastAttemptedRevision)
            lastAttemptedRevisionDigest = try? c.decodeIfPresent(String.self, forKey: .lastAttemptedRevisionDigest)
            inventory = try? c.decodeIfPresent(Inventory.self, forKey: .inventory)
            artifact = try? c.decodeIfPresent(Artifact.self, forKey: .artifact)
        }
    }

    /// `status.sync`: never `comparedTo` (the source's copy, values and all).
    struct Sync: Decodable, Sendable, Declared {
        var status: String?
        var revision: String?
        var revisions: [String]?

        enum CodingKeys: String, CodingKey, CaseIterable { case status, revision, revisions }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        /// `revisions[]` when it has any, else its `revision` (KubeGitOpsSource's rule).
        var said: [String] { Revisions.said(revision, revisions) }
    }

    struct Health: Decodable, Sendable, Declared {
        var status: String?
        var message: String?

        enum CodingKeys: String, CodingKey, CaseIterable { case status, message }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    struct Condition: Decodable, Sendable, Declared {
        var type: String?
        var status: String?
        var reason: String?
        var message: String?
        var lastTransitionTime: String?

        enum CodingKeys: String, CodingKey, CaseIterable { case type, status, reason, message, lastTransitionTime }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// `status.operationState`: never `operation.sync` (its source copy,
    /// its `manifests`) — who started it only.
    struct OperationState: Decodable, Sendable, Declared {
        var phase: String?
        var message: String?
        var startedAt: String?
        var finishedAt: String?
        var retryCount: Int?
        var operation: Operation?
        var syncResult: SyncResult?

        enum CodingKeys: String, CodingKey, CaseIterable { case phase, message, startedAt, finishedAt, retryCount, operation, syncResult }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    struct Operation: Decodable, Sendable, Declared {
        var initiatedBy: InitiatedBy?

        enum CodingKeys: String, CodingKey, CaseIterable { case initiatedBy }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    struct InitiatedBy: Decodable, Sendable, Declared {
        var username: String?
        var automated: Bool?

        enum CodingKeys: String, CodingKey, CaseIterable { case username, automated }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// The operation's result: its revision(s) and the first resource that
    /// failed — never its `source(s)` copy.
    struct SyncResult: Decodable, Sendable, Declared {
        var revision: String?
        var revisions: [String]?
        var resources: FailedResource?

        enum CodingKeys: String, CodingKey, CaseIterable { case revision, revisions, resources }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        var said: [String] { Revisions.said(revision, revisions) }
    }

    /// `syncResult.resources[]`: the first whose status is `SyncFailed`;
    /// the others skipped.
    struct FailedResource: Decodable, Sendable {
        var first: SyncResource?

        init(from decoder: Decoder) throws {
            var list = try decoder.unkeyedContainer()
            while !list.isAtEnd {
                if (try? list.decodeNil()) == true { continue }
                guard let resource = try? list.decode(SyncResource.self) else {
                    _ = try? list.decode(Skip.self)
                    continue
                }
                if first == nil, resource.status == "SyncFailed" { first = resource }
            }
        }
    }

    struct SyncResource: Decodable, Sendable, Declared {
        var kind: String?
        var name: String?
        var namespace: String?
        var status: String?
        var message: String?

        enum CodingKeys: String, CodingKey, CaseIterable { case kind, name, namespace, status, message }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// One `history` entry: Argo CD's revision(s) and when; a HelmRelease's
    /// chart version, status and when it was last deployed. Never its
    /// `source(s)`.
    struct HistoryEntry: Decodable, Sendable, Declared {
        var revision: String?
        var revisions: [String]?
        var deployedAt: String?
        var chartName: String?
        var chartVersion: String?
        var status: String?
        var lastDeployed: String?

        enum CodingKeys: String, CodingKey, CaseIterable { case revision, revisions, deployedAt, chartName, chartVersion, status, lastDeployed }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        var said: [String] { Revisions.said(revision, revisions) }
    }

    /// `status.resources`: the count, the namespaces (at most 64), how
    /// many need pruning. Each entry's sync and health aren't kept.
    struct ResourcesDigest: Decodable, Sendable {
        var count = 0
        var namespaces: Set<String> = []
        var pruneNeeded = 0
        var outOfSync = 0

        init(count: Int = 0) { self.count = count }

        init(from decoder: Decoder) throws {
            var list = try decoder.unkeyedContainer()
            while !list.isAtEnd {
                if (try? list.decodeNil()) == true { continue }
                guard let entry = try? list.decode(ResourceEntry.self) else {
                    _ = try? list.decode(Skip.self)
                    continue
                }
                count += 1
                if let namespace = entry.namespace, !namespace.isEmpty, namespaces.count < namespacesKept { namespaces.insert(namespace) }
                if entry.requiresPruning == true { pruneNeeded += 1 }
                if entry.status == "OutOfSync" { outOfSync += 1 }
            }
        }
    }

    struct ResourceEntry: Decodable, Sendable, Declared {
        var namespace: String?
        var status: String?
        var requiresPruning: Bool?

        enum CodingKeys: String, CodingKey, CaseIterable { case namespace, status, requiresPruning }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    struct Summary: Decodable, Sendable, Declared {
        var images: [String]?

        enum CodingKeys: String, CodingKey, CaseIterable { case images }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// A Kustomization's inventory: its count and namespaces, from the ids.
    struct Inventory: Decodable, Sendable, Declared {
        var count = 0
        var namespaces: Set<String> = []

        enum CodingKeys: String, CodingKey, CaseIterable { case entries }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard var list = try? c.nestedUnkeyedContainer(forKey: .entries) else { return }
            while !list.isAtEnd {
                if (try? list.decodeNil()) == true { continue }
                guard let entry = try? list.decode(InventoryEntry.self) else {
                    _ = try? list.decode(Skip.self)
                    continue
                }
                count += 1
                if let found = KubeGitOpsSource.inventoryEntry(entry.id ?? "", version: "v1"), let namespace = found.namespace,
                    namespaces.count < namespacesKept
                {
                    namespaces.insert(namespace)
                }
            }
        }
    }

    struct InventoryEntry: Decodable, Sendable, Declared {
        var id: String?

        enum CodingKeys: String, CodingKey, CaseIterable { case id }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// A Source's artifact: what it fetched and when; of its metadata, only
    /// an OCI artifact's git origin.
    struct Artifact: Decodable, Sendable, Declared {
        var revision: String?
        var lastUpdateTime: String?
        var metadata: ArtifactMetadata?

        enum CodingKeys: String, CodingKey, CaseIterable { case revision, lastUpdateTime, metadata }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    struct ArtifactMetadata: Decodable, Sendable, Declared {
        var source: String?
        var revision: String?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case source = "org.opencontainers.image.source"
            case revision = "org.opencontainers.image.revision"
        }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = (try? c.decodeIfPresent(String.self, forKey: .source)).flatMap { $0.map(GitRemoteURL.withoutUserinfo) }
            revision = try? c.decodeIfPresent(String.self, forKey: .revision)
        }
    }

    // MARK: The detail's (G3)

    /// What the detail's GitOps header reads beyond a summary (gitops.md,
    /// 2.9), from the same body: Argo CD's last 10 `history` entries (their
    /// revisions and when, never their `source(s)`), the resources out of
    /// sync or needing pruning and the operation's failed ones, at most 50
    /// each — counted past that, never decoded.
    struct Detail: Decodable, Sendable, Declared {
        var status: DetailStatus?

        enum CodingKeys: String, CodingKey, CaseIterable { case status }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    struct DetailStatus: Decodable, Sendable, Declared {
        /// Newest last, as Argo CD writes it: the last `historyKept`.
        var history: [HistoryEntry] = []
        var resources: [DetailResource] = []
        /// Out of sync or needing pruning, past the `listKept` kept.
        var resourcesPast = 0
        var operationState: DetailOperationState?

        enum CodingKeys: String, CodingKey, CaseIterable { case history, resources, operationState }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if var list = try? c.nestedUnkeyedContainer(forKey: .history) {
                while !list.isAtEnd {
                    if (try? list.decodeNil()) == true { continue }
                    guard let entry = try? list.decode(HistoryEntry.self) else {
                        _ = try? list.decode(Skip.self)
                        continue
                    }
                    history.append(entry)
                    if history.count > historyKept { history.removeFirst() }
                }
            }
            if var list = try? c.nestedUnkeyedContainer(forKey: .resources) {
                while !list.isAtEnd {
                    if (try? list.decodeNil()) == true { continue }
                    guard let entry = try? list.decode(DetailResource.self) else {
                        _ = try? list.decode(Skip.self)
                        continue
                    }
                    guard entry.status == "OutOfSync" || entry.requiresPruning == true else { continue }
                    if resources.count < listKept { resources.append(entry) } else { resourcesPast += 1 }
                }
            }
            operationState = try? c.decodeIfPresent(DetailOperationState.self, forKey: .operationState)
        }
    }

    struct DetailOperationState: Decodable, Sendable, Declared {
        var syncResult: DetailSyncResult?

        enum CodingKeys: String, CodingKey, CaseIterable { case syncResult }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// The operation's resources that failed: at most `listKept`, the rest
    /// counted; never its `source(s)` copy.
    struct DetailSyncResult: Decodable, Sendable, Declared {
        var failed: [SyncResource] = []
        var failedPast = 0

        enum CodingKeys: String, CodingKey, CaseIterable { case resources }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard var list = try? c.nestedUnkeyedContainer(forKey: .resources) else { return }
            while !list.isAtEnd {
                if (try? list.decodeNil()) == true { continue }
                guard let resource = try? list.decode(SyncResource.self) else {
                    _ = try? list.decode(Skip.self)
                    continue
                }
                guard resource.status == "SyncFailed" else { continue }
                if failed.count < listKept { failed.append(resource) } else { failedPast += 1 }
            }
        }
    }

    /// One `status.resources` entry, as the detail lists it: what it is,
    /// where, its sync and health status, whether it needs pruning.
    struct DetailResource: Decodable, Sendable, Declared {
        var group: String?
        var version: String?
        var kind: String?
        var namespace: String?
        var name: String?
        var status: String?
        var requiresPruning: Bool?
        var health: Health?

        enum CodingKeys: String, CodingKey, CaseIterable { case group, version, kind, namespace, name, status, requiresPruning, health }
        static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// The detail's history entries kept: the last 10.
    static let historyKept = 10
    /// The detail's resources (and failed ones) kept: 50.
    static let listKept = 50

    // MARK: Helpers

    /// Whatever is there, unread.
    struct Skip: Decodable, Sendable {
        init(from decoder: Decoder) throws {}
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    enum Revisions {
        /// `revisions[]` when it has any, else `revision`; nothing is `[]`.
        static func said(_ revision: String?, _ revisions: [String]?) -> [String] {
            if let revisions, !revisions.isEmpty { return revisions }
            if let revision, !revision.isEmpty { return [revision] }
            return []
        }
    }

    // MARK: Decoding

    /// One object, as a GET answers it.
    static func object(_ data: Data) throws -> Object { try JSONDecoder().decode(Object.self, from: data) }

    /// A page of a list.
    static func list(_ data: Data) throws -> List { try JSONDecoder().decode(List.self, from: data) }

    /// One GET's body as the detail reads it, parsed once: the summary's
    /// fields, and for an Application what only the detail shows. It
    /// declares no key of its own — both halves are the structs above.
    struct DetailRead: Decodable, Sendable {
        var object: Object
        var detail: Detail?

        init(from decoder: Decoder) throws {
            object = try Object(from: decoder)
            detail = object.kind == "Application" ? try? Detail(from: decoder) : nil
        }
    }

    static func detailRead(_ data: Data) throws -> DetailRead { try JSONDecoder().decode(DetailRead.self, from: data) }
}

extension Optional where Wrapped == String {
    /// nil for nil or "".
    fileprivate var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
