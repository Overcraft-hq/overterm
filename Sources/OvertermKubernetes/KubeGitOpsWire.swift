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
package enum KubeGitOpsWire {
    /// What a struct here declares: its keys, for the reviewed list.
    package protocol Declared {
        static var keys: [String] { get }
    }

    /// Every struct's declared keys, by name — what the test reviews.
    package static var declared: [String: [String]] {
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
            ("DetailSyncResult", DetailSyncResult.keys), ("DetailResource", DetailResource.keys), ("Managed", Managed.keys),
            ("ManagedStatus", ManagedStatus.keys), ("ManagedEntry", ManagedEntry.keys),
        ]
        return Dictionary(uniqueKeysWithValues: all)
    }

    /// The most entries of `status.resources` and an inventory whose
    /// namespaces are kept (gitops.md, 2.4: 64).
    package static let namespacesKept = 64
    /// `status.summary.images`, at most.
    package static let imagesKept = 20

    // MARK: The object

    package struct Object: Decodable, Sendable, Declared {
        package var apiVersion: String?
        package var kind: String?
        package var metadata: Metadata?
        package var spec: Spec?
        package var status: Status?

        package enum CodingKeys: String, CodingKey, CaseIterable { case apiVersion, kind, metadata, spec, status }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// A page of a list: its objects and where the next starts.
    package struct List: Decodable, Sendable, Declared {
        package var metadata: ListMetadata?
        package var items: [Object]?

        package enum CodingKeys: String, CodingKey, CaseIterable { case metadata, items }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    package struct ListMetadata: Decodable, Sendable, Declared {
        package var `continue`: String?
        package var remainingItemCount: Int?
        package var resourceVersion: String?

        package enum CodingKeys: String, CodingKey, CaseIterable { case `continue`, remainingItemCount, resourceVersion }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    package struct Metadata: Decodable, Sendable, Declared {
        package var name: String?
        package var namespace: String?
        package var uid: String?
        package var resourceVersion: String?
        package var generation: Int?
        package var creationTimestamp: String?
        package var deletionTimestamp: String?
        package var labels: Labels?
        package var annotations: Annotations?
        package var ownerReferences: [OwnerReference]?
        package var managedFields: [ManagedField]?

        package enum CodingKeys: String, CodingKey, CaseIterable {
            case name, namespace, uid, resourceVersion, generation, creationTimestamp, deletionTimestamp, labels, annotations, ownerReferences
            case managedFields
        }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// The labels that name what deploys it (`KubeGitOpsOwner`), no other.
    package struct Labels: Decodable, Sendable, Declared {
        package var argoInstance: String?
        package var appInstance: String?
        package var kustomizeName: String?
        package var kustomizeNamespace: String?
        package var helmName: String?
        package var helmNamespace: String?

        package enum CodingKeys: String, CodingKey, CaseIterable {
            case argoInstance = "argocd.argoproj.io/instance"
            case appInstance = "app.kubernetes.io/instance"
            case kustomizeName = "kustomize.toolkit.fluxcd.io/name"
            case kustomizeNamespace = "kustomize.toolkit.fluxcd.io/namespace"
            case helmName = "helm.toolkit.fluxcd.io/name"
            case helmNamespace = "helm.toolkit.fluxcd.io/namespace"
        }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        package var marks: [String: String] {
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
    package struct Annotations: Decodable, Sendable, Declared {
        package var trackingID: String?
        package var helmRelease: String?
        package var manifestGeneratePaths: String?

        package enum CodingKeys: String, CodingKey, CaseIterable {
            case trackingID = "argocd.argoproj.io/tracking-id"
            case helmRelease = "meta.helm.sh/release-name"
            case manifestGeneratePaths = "argocd.argoproj.io/manifest-generate-paths"
        }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        package var marks: [String: String] {
            var marks: [String: String] = [:]
            marks[KubeGitOpsOwner.trackingAnnotation] = trackingID
            marks[KubeGitOpsOwner.helmReleaseAnnotation] = helmRelease
            return marks
        }
    }

    package struct OwnerReference: Decodable, Sendable, Declared {
        package var apiVersion: String?
        package var kind: String?
        package var name: String?
        package var controller: Bool?

        package enum CodingKeys: String, CodingKey, CaseIterable { case apiVersion, kind, name, controller }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// One managedFields entry: when, who, and only whether it owns
    /// `spec` and `spec.suspend` — the rest of `fieldsV1` is looked at by
    /// key, never decoded.
    package struct ManagedField: Decodable, Sendable, Declared {
        package var manager: String?
        package var operation: String?
        package var time: String?
        package var fieldsV1: FieldsV1?

        package enum CodingKeys: String, CodingKey, CaseIterable { case manager, operation, time, fieldsV1 }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    package struct FieldsV1: Decodable, Sendable, Declared {
        package var spec = false
        package var suspend = false

        package static var keys: [String] { ["f:spec", "f:suspend"] }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            let key = AnyKey("f:spec")
            guard container.contains(key) else { return }
            spec = true
            if let inner = try? container.nestedContainer(keyedBy: AnyKey.self, forKey: key) { suspend = inner.contains(AnyKey("f:suspend")) }
        }
    }

    // MARK: spec

    package struct Spec: Decodable, Sendable, Declared {
        // Argo CD
        package var source: ArgoSource?
        package var sources: [ArgoSource]?
        package var destination: Destination?
        package var project: String?
        package var syncPolicy: SyncPolicy?
        package var sourceHydrator: Hydrator?
        // Flux
        package var suspend: Bool?
        package var interval: String?
        package var retryInterval: String?
        package var path: String?
        package var prune: Bool?
        package var targetNamespace: String?
        package var sourceRef: Reference?
        package var chartRef: Reference?
        package var chart: Chart?
        /// A HelmChart's `spec.chart`, a word: the chart's path in a GitRepository.
        package var chartName: String?
        package var dependsOn: [Reference]?
        package var kubeConfig: KubeConfig?
        // Flux's sources
        package var url: String?
        package var ref: GitRef?
        package var endpoint: String?

        package enum CodingKeys: String, CodingKey, CaseIterable {
            case source, sources, destination, project, syncPolicy, sourceHydrator
            case suspend, interval, retryInterval, path, prune, targetNamespace, sourceRef, chartRef, chart, dependsOn, kubeConfig
            case url, ref, endpoint
        }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        package init(from decoder: Decoder) throws {
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
            if chart == nil { chartName = try? c.decodeIfPresent(String.self, forKey: .chart) }
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
    package struct ArgoSource: Decodable, Sendable, Declared {
        package var repoURL: String?
        package var path: String?
        package var chart: String?
        package var targetRevision: String?
        package var ref: String?

        package enum CodingKeys: String, CodingKey, CaseIterable { case repoURL, path, chart, targetRevision, ref }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            repoURL = (try? c.decodeIfPresent(String.self, forKey: .repoURL)).flatMap { $0.map(GitRemoteURL.withoutUserinfo) }
            path = try? c.decodeIfPresent(String.self, forKey: .path)
            chart = try? c.decodeIfPresent(String.self, forKey: .chart)
            targetRevision = try? c.decodeIfPresent(String.self, forKey: .targetRevision)
            ref = try? c.decodeIfPresent(String.self, forKey: .ref)
        }

        package var source: KubeGitOpsSource {
            KubeGitOpsSource(
                repoURL: repoURL ?? "", path: path.nonEmpty, chart: chart.nonEmpty, targetRevision: targetRevision.nonEmpty, ref: ref.nonEmpty)
        }
    }

    package struct Destination: Decodable, Sendable, Declared {
        package var server: String?
        package var name: String?
        package var namespace: String?

        package enum CodingKeys: String, CodingKey, CaseIterable { case server, name, namespace }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        /// `server` without its userinfo, as every URL here (gitops.md, 5.2).
        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            server = (try? c.decodeIfPresent(String.self, forKey: .server)).flatMap { $0.map(GitRemoteURL.withoutUserinfo) }
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            namespace = try? c.decodeIfPresent(String.self, forKey: .namespace)
        }
    }

    package struct SyncPolicy: Decodable, Sendable, Declared {
        package var automated: Automated?
        package var retry: Retry?

        package enum CodingKeys: String, CodingKey, CaseIterable { case automated, retry }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// `automated` — `enabled` is Argo CD 3's (checked against its CRD, 8.5).
    package struct Automated: Decodable, Sendable, Declared {
        package var enabled: Bool?
        package var prune: Bool?
        package var selfHeal: Bool?

        package enum CodingKeys: String, CodingKey, CaseIterable { case enabled, prune, selfHeal }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    package struct Retry: Decodable, Sendable, Declared {
        package var limit: Int?

        package enum CodingKeys: String, CodingKey, CaseIterable { case limit }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// `sourceHydrator`, Argo CD 3's: its dry source is where the manifests come from.
    package struct Hydrator: Decodable, Sendable, Declared {
        package var drySource: DrySource?

        package enum CodingKeys: String, CodingKey, CaseIterable { case drySource }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    package struct DrySource: Decodable, Sendable, Declared {
        package var repoURL: String?
        package var path: String?
        package var targetRevision: String?

        package enum CodingKeys: String, CodingKey, CaseIterable { case repoURL, path, targetRevision }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            repoURL = (try? c.decodeIfPresent(String.self, forKey: .repoURL)).flatMap { $0.map(GitRemoteURL.withoutUserinfo) }
            path = try? c.decodeIfPresent(String.self, forKey: .path)
            targetRevision = try? c.decodeIfPresent(String.self, forKey: .targetRevision)
        }
    }

    /// A Flux reference: `sourceRef`, `chartRef`, a `dependsOn` entry.
    package struct Reference: Decodable, Sendable, Declared {
        package var apiVersion: String?
        package var kind: String?
        package var name: String?
        package var namespace: String?

        package enum CodingKeys: String, CodingKey, CaseIterable { case apiVersion, kind, name, namespace }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// A HelmRelease's chart template.
    package struct Chart: Decodable, Sendable, Declared {
        package var spec: ChartSpec?

        package enum CodingKeys: String, CodingKey, CaseIterable { case spec }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    package struct ChartSpec: Decodable, Sendable, Declared {
        package var chart: String?
        package var version: String?
        package var sourceRef: Reference?

        package enum CodingKeys: String, CodingKey, CaseIterable { case chart, version, sourceRef }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// `spec.kubeConfig`: the Secret's or ConfigMap's name, nothing in it.
    package struct KubeConfig: Decodable, Sendable, Declared {
        package var secretRef: Named?
        package var configMapRef: Named?

        package enum CodingKeys: String, CodingKey, CaseIterable { case secretRef, configMapRef }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        /// `spec.kubeConfig.secretRef acme-edge`, as the tree says it.
        package var said: String {
            if let name = secretRef?.name { return "spec.kubeConfig.secretRef \(name)" }
            if let name = configMapRef?.name { return "spec.kubeConfig.configMapRef \(name)" }
            return "spec.kubeConfig"
        }
    }

    package struct Named: Decodable, Sendable, Declared {
        package var name: String?

        package enum CodingKeys: String, CodingKey, CaseIterable { case name }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// A GitRepository's `spec.ref`.
    package struct GitRef: Decodable, Sendable, Declared {
        package var branch: String?
        package var tag: String?
        package var semver: String?
        package var name: String?
        package var commit: String?

        package enum CodingKeys: String, CodingKey, CaseIterable { case branch, tag, semver, name, commit }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        /// What it tracks, by Flux's precedence: commit > name > semver > tag > branch.
        package var tracks: String? { commit.nonEmpty ?? name.nonEmpty ?? semver.nonEmpty ?? tag.nonEmpty ?? branch.nonEmpty }
    }

    // MARK: status

    package struct Status: Decodable, Sendable, Declared {
        // Argo CD
        package var sync: Sync?
        package var health: Health?
        package var operationState: OperationState?
        /// `history`: Argo CD's last entry, Flux's first (a HelmRelease's newest).
        package var historyFirst: HistoryEntry?
        package var historyLast: HistoryEntry?
        package var reconciledAt: String?
        package var resourceHealthSource: String?
        package var resources: ResourcesDigest?
        package var summary: Summary?
        // Both
        package var conditions: [Condition]?
        package var observedGeneration: Int?
        // Flux
        package var lastAppliedRevision: String?
        package var lastAttemptedRevision: String?
        /// A HelmRelease's: the digest of the chart it last tried, from a `chartRef`'s OCIRepository.
        package var lastAttemptedRevisionDigest: String?
        package var inventory: Inventory?
        package var artifact: Artifact?

        package enum CodingKeys: String, CodingKey, CaseIterable {
            case sync, health, operationState, history, reconciledAt, resourceHealthSource, resources, summary
            case conditions, observedGeneration
            case lastAppliedRevision, lastAttemptedRevision, lastAttemptedRevisionDigest, inventory, artifact
        }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        package init(from decoder: Decoder) throws {
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
    package struct Sync: Decodable, Sendable, Declared {
        package var status: String?
        package var revision: String?
        package var revisions: [String]?

        package enum CodingKeys: String, CodingKey, CaseIterable { case status, revision, revisions }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        /// `revisions[]` when it has any, else its `revision` (KubeGitOpsSource's rule).
        package var said: [String] { Revisions.said(revision, revisions) }
    }

    package struct Health: Decodable, Sendable, Declared {
        package var status: String?
        package var message: String?

        package enum CodingKeys: String, CodingKey, CaseIterable { case status, message }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    package struct Condition: Decodable, Sendable, Declared {
        package var type: String?
        package var status: String?
        package var reason: String?
        package var message: String?
        package var lastTransitionTime: String?

        package enum CodingKeys: String, CodingKey, CaseIterable { case type, status, reason, message, lastTransitionTime }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// `status.operationState`: never `operation.sync` (its source copy,
    /// its `manifests`) — who started it only.
    package struct OperationState: Decodable, Sendable, Declared {
        package var phase: String?
        package var message: String?
        package var startedAt: String?
        package var finishedAt: String?
        package var retryCount: Int?
        package var operation: Operation?
        package var syncResult: SyncResult?

        package enum CodingKeys: String, CodingKey, CaseIterable { case phase, message, startedAt, finishedAt, retryCount, operation, syncResult }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    package struct Operation: Decodable, Sendable, Declared {
        package var initiatedBy: InitiatedBy?

        package enum CodingKeys: String, CodingKey, CaseIterable { case initiatedBy }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    package struct InitiatedBy: Decodable, Sendable, Declared {
        package var username: String?
        package var automated: Bool?

        package enum CodingKeys: String, CodingKey, CaseIterable { case username, automated }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// The operation's result: its revision(s) and the first resource that
    /// failed — never its `source(s)` copy.
    package struct SyncResult: Decodable, Sendable, Declared {
        package var revision: String?
        package var revisions: [String]?
        package var resources: FailedResource?

        package enum CodingKeys: String, CodingKey, CaseIterable { case revision, revisions, resources }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        package var said: [String] { Revisions.said(revision, revisions) }
    }

    /// `syncResult.resources[]`: the first whose status is `SyncFailed`;
    /// the others skipped.
    package struct FailedResource: Decodable, Sendable {
        package var first: SyncResource?

        package init(from decoder: Decoder) throws {
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

    package struct SyncResource: Decodable, Sendable, Declared {
        package var kind: String?
        package var name: String?
        package var namespace: String?
        package var status: String?
        package var message: String?

        package enum CodingKeys: String, CodingKey, CaseIterable { case kind, name, namespace, status, message }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// One `history` entry: Argo CD's revision(s) and when; a HelmRelease's
    /// chart version, status and when it was last deployed. Never its
    /// `source(s)`.
    package struct HistoryEntry: Decodable, Sendable, Declared {
        package var revision: String?
        package var revisions: [String]?
        package var deployedAt: String?
        package var chartName: String?
        package var chartVersion: String?
        package var status: String?
        package var lastDeployed: String?

        package enum CodingKeys: String, CodingKey, CaseIterable { case revision, revisions, deployedAt, chartName, chartVersion, status, lastDeployed }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        package var said: [String] { Revisions.said(revision, revisions) }
    }

    /// `status.resources`: the count, the namespaces (at most 64), how
    /// many need pruning. Each entry's sync and health aren't kept.
    package struct ResourcesDigest: Decodable, Sendable {
        package var count = 0
        package var namespaces: Set<String> = []
        package var pruneNeeded = 0
        package var outOfSync = 0

        package init(count: Int = 0) { self.count = count }

        package init(from decoder: Decoder) throws {
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

    package struct ResourceEntry: Decodable, Sendable, Declared {
        package var namespace: String?
        package var status: String?
        package var requiresPruning: Bool?

        package enum CodingKeys: String, CodingKey, CaseIterable { case namespace, status, requiresPruning }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    package struct Summary: Decodable, Sendable, Declared {
        package var images: [String]?

        package enum CodingKeys: String, CodingKey, CaseIterable { case images }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// A Kustomization's inventory: its count and namespaces, from the ids.
    package struct Inventory: Decodable, Sendable, Declared {
        package var count = 0
        package var namespaces: Set<String> = []

        package enum CodingKeys: String, CodingKey, CaseIterable { case entries }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        package init(from decoder: Decoder) throws {
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

    package struct InventoryEntry: Decodable, Sendable, Declared {
        package var id: String?

        package enum CodingKeys: String, CodingKey, CaseIterable { case id }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// A Source's artifact: what it fetched and when; of its metadata, only
    /// an OCI artifact's git origin.
    package struct Artifact: Decodable, Sendable, Declared {
        package var revision: String?
        package var lastUpdateTime: String?
        package var metadata: ArtifactMetadata?

        package enum CodingKeys: String, CodingKey, CaseIterable { case revision, lastUpdateTime, metadata }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    package struct ArtifactMetadata: Decodable, Sendable, Declared {
        package var source: String?
        package var revision: String?

        package enum CodingKeys: String, CodingKey, CaseIterable {
            case source = "org.opencontainers.image.source"
            case revision = "org.opencontainers.image.revision"
        }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        package init(from decoder: Decoder) throws {
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
    package struct Detail: Decodable, Sendable, Declared {
        package var status: DetailStatus?

        package enum CodingKeys: String, CodingKey, CaseIterable { case status }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    package struct DetailStatus: Decodable, Sendable, Declared {
        /// Newest last, as Argo CD writes it: the last `historyKept`.
        package var history: [HistoryEntry] = []
        package var resources: [DetailResource] = []
        /// Out of sync or needing pruning, past the `listKept` kept.
        package var resourcesPast = 0
        package var operationState: DetailOperationState?

        package enum CodingKeys: String, CodingKey, CaseIterable { case history, resources, operationState }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        package init(from decoder: Decoder) throws {
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

    package struct DetailOperationState: Decodable, Sendable, Declared {
        package var syncResult: DetailSyncResult?

        package enum CodingKeys: String, CodingKey, CaseIterable { case syncResult }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// The operation's resources that failed: at most `listKept`, the rest
    /// counted; never its `source(s)` copy.
    package struct DetailSyncResult: Decodable, Sendable, Declared {
        package var failed: [SyncResource] = []
        package var failedPast = 0

        package enum CodingKeys: String, CodingKey, CaseIterable { case resources }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        package init(from decoder: Decoder) throws {
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
    package struct DetailResource: Decodable, Sendable, Declared {
        package var group: String?
        package var version: String?
        package var kind: String?
        package var namespace: String?
        package var name: String?
        package var status: String?
        package var requiresPruning: Bool?
        package var health: Health?

        package enum CodingKeys: String, CodingKey, CaseIterable { case group, version, kind, namespace, name, status, requiresPruning, health }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    // MARK: The rail's (G5)

    /// What an Application manages, by name only — the rail asks whether it
    /// names a bound workload, where only Helm's own instance label said so
    /// (gitops.md 4.2): `status.resources[]`'s group, kind, namespace and
    /// name, at most `managedKept`; their sync, health and the rest never.
    package struct Managed: Decodable, Sendable, Declared {
        package var status: ManagedStatus?

        package enum CodingKeys: String, CodingKey, CaseIterable { case status }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    package struct ManagedStatus: Decodable, Sendable, Declared {
        package var resources: [ManagedEntry] = []

        package enum CodingKeys: String, CodingKey, CaseIterable { case resources }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard var list = try? c.nestedUnkeyedContainer(forKey: .resources) else { return }
            while !list.isAtEnd {
                if (try? list.decodeNil()) == true { continue }
                guard resources.count < managedKept, let entry = try? list.decode(ManagedEntry.self) else {
                    _ = try? list.decode(Skip.self)
                    continue
                }
                resources.append(entry)
            }
        }
    }

    package struct ManagedEntry: Decodable, Sendable, Declared, Hashable {
        package var group: String?
        package var kind: String?
        package var namespace: String?
        package var name: String?

        package enum CodingKeys: String, CodingKey, CaseIterable { case group, kind, namespace, name }
        package static var keys: [String] { CodingKeys.allCases.map(\.stringValue) }
    }

    /// The most of an Application's managed resources the rail looks at.
    package static let managedKept = 2000

    package static func managed(_ data: Data) throws -> Managed { try JSONDecoder().decode(Managed.self, from: data) }

    /// The detail's history entries kept: the last 10.
    package static let historyKept = 10
    /// The detail's resources (and failed ones) kept: 50.
    package static let listKept = 50

    // MARK: Helpers

    /// Whatever is there, unread.
    package struct Skip: Decodable, Sendable {
        package init(from decoder: Decoder) throws {}
    }

    package struct AnyKey: CodingKey {
        package var stringValue: String
        package var intValue: Int? { nil }
        package init(_ string: String) { stringValue = string }
        package init?(stringValue: String) { self.stringValue = stringValue }
        package init?(intValue: Int) { nil }
    }

    package enum Revisions {
        /// `revisions[]` when it has any, else `revision`; nothing is `[]`.
        package static func said(_ revision: String?, _ revisions: [String]?) -> [String] {
            if let revisions, !revisions.isEmpty { return revisions }
            if let revision, !revision.isEmpty { return [revision] }
            return []
        }
    }

    // MARK: Decoding

    /// One object, as a GET answers it.
    package static func object(_ data: Data) throws -> Object { try JSONDecoder().decode(Object.self, from: data) }

    /// A page of a list.
    package static func list(_ data: Data) throws -> List { try JSONDecoder().decode(List.self, from: data) }

    /// One GET's body as the detail reads it, parsed once: the summary's
    /// fields, and for an Application what only the detail shows. It
    /// declares no key of its own — both halves are the structs above.
    package struct DetailRead: Decodable, Sendable {
        package var object: Object
        package var detail: Detail?

        package init(from decoder: Decoder) throws {
            object = try Object(from: decoder)
            detail = object.kind == "Application" ? try? Detail(from: decoder) : nil
        }
    }

    package static func detailRead(_ data: Data) throws -> DetailRead { try JSONDecoder().decode(DetailRead.self, from: data) }
}

extension Optional where Wrapped == String {
    /// nil for nil or "".
    fileprivate var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
