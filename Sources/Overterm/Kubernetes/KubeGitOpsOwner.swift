import Foundation

/// The Argo CD or Flux object an object's marks name as what deploys it
/// (docs/design/kubernetes/gitops.md, 1.1 and 4.2) — read from its labels
/// and annotations alone, never a field of theirs:
///
/// - Argo CD's `argocd.argoproj.io/tracking-id` annotation
///   (`<app>:<group>/<Kind>:<namespace>/<name>`; `<appNamespace>_<app>`
///   for an Application outside Argo CD's own namespace);
/// - its `argocd.argoproj.io/instance` label;
/// - `app.kubernetes.io/instance`, Argo CD 2.x's default tracking label
///   (`application.instanceLabelKey`) — "probably" Argo CD only, because
///   Helm charts set it too; never said when Helm's own release
///   annotation, Flux's labels or Argo's surer marks are there;
/// - Flux's `kustomize.toolkit.fluxcd.io/name|namespace` and
///   `helm.toolkit.fluxcd.io/name|namespace` labels.
///
/// Used by the apply's warnings (`KubeFieldOwners.managedBy`), and by what
/// later reads who deploys a workload. Pure.
struct KubeGitOpsOwner: Equatable, Hashable, Sendable {
    enum Tool: String, Equatable, Hashable, Sendable {
        case argoCD, fluxKustomize, fluxHelm

        /// The kind of the object that deploys it.
        var kind: String {
            switch self {
            case .argoCD: "Application"
            case .fluxKustomize: "Kustomization"
            case .fluxHelm: "HelmRelease"
            }
        }
    }

    /// Which mark said it.
    enum Mark: String, Equatable, Hashable, Sendable {
        case trackingID, argoInstance, appInstance, fluxLabels
    }

    var tool: Tool
    var name: String
    /// The owner's own namespace, when the marks say it (Flux's namespace
    /// label; an Application's from `<namespace>_<app>`); nil means the
    /// tool's default namespace, unknown here.
    var namespace: String?
    var mark: Mark

    /// False only for `app.kubernetes.io/instance`: Helm sets it too.
    var isCertain: Bool { mark != .appInstance }

    static let trackingAnnotation = "argocd.argoproj.io/tracking-id"
    static let argoInstanceLabel = "argocd.argoproj.io/instance"
    static let appInstanceLabel = "app.kubernetes.io/instance"
    static let kustomizeName = "kustomize.toolkit.fluxcd.io/name"
    static let kustomizeNamespace = "kustomize.toolkit.fluxcd.io/namespace"
    static let helmName = "helm.toolkit.fluxcd.io/name"
    static let helmNamespace = "helm.toolkit.fluxcd.io/namespace"
    /// Helm's own install annotates this; Argo CD's rendering of a chart doesn't.
    static let helmReleaseAnnotation = "meta.helm.sh/release-name"

    /// `Application argocd/acme-shop`, or `probably Argo CD Application acme-shop`.
    var said: String {
        let place = namespace.map { "\($0)/\(name)" } ?? name
        return isCertain ? "\(tool.kind) \(place)" : "probably Argo CD \(tool.kind) \(place)"
    }

    /// Every owner the marks name: Argo CD's (the surest mark only), then
    /// Flux's. An object Flux deploys through Helm carries Helm's instance
    /// label too, which then names nobody.
    static func parse(labels: [String: String], annotations: [String: String]) -> [KubeGitOpsOwner] {
        var owners: [KubeGitOpsOwner] = []
        if let value = annotations[trackingAnnotation], let owner = tracking(value) {
            owners.append(owner)
        }
        // A tracking id that doesn't parse leaves the instance label to say who.
        if owners.isEmpty, let name = nonEmpty(labels[argoInstanceLabel]) {
            owners.append(KubeGitOpsOwner(tool: .argoCD, name: name, namespace: nil, mark: .argoInstance))
        }
        if let name = nonEmpty(labels[kustomizeName]) {
            owners.append(KubeGitOpsOwner(tool: .fluxKustomize, name: name, namespace: nonEmpty(labels[kustomizeNamespace]), mark: .fluxLabels))
        }
        if let name = nonEmpty(labels[helmName]) {
            owners.append(KubeGitOpsOwner(tool: .fluxHelm, name: name, namespace: nonEmpty(labels[helmNamespace]), mark: .fluxLabels))
        }
        if owners.isEmpty, annotations[helmReleaseAnnotation] == nil, let name = nonEmpty(labels[appInstanceLabel]) {
            owners.append(KubeGitOpsOwner(tool: .argoCD, name: name, namespace: nil, mark: .appInstance))
        }
        return owners
    }

    /// From an object's metadata, labels and annotations as JSON gives them.
    static func parse(metadata: [String: Any]?) -> [KubeGitOpsOwner] {
        parse(labels: strings(metadata?["labels"]), annotations: strings(metadata?["annotations"]))
    }

    /// `argocd.argoproj.io/tracking-id`: `<app>:<group>/<Kind>:<ns>/<name>`
    /// — the Application before the first `:`; `<appNamespace>_<app>` when
    /// it lives outside Argo CD's namespace (no Kubernetes name has a `_`).
    static func tracking(_ value: String) -> KubeGitOpsOwner? {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let app = String(value[..<colon])
        guard !app.isEmpty else { return nil }
        if let underscore = app.firstIndex(of: "_") {
            let namespace = String(app[..<underscore])
            let name = String(app[app.index(after: underscore)...])
            guard !namespace.isEmpty, !name.isEmpty else { return nil }
            return KubeGitOpsOwner(tool: .argoCD, name: name, namespace: namespace, mark: .trackingID)
        }
        return KubeGitOpsOwner(tool: .argoCD, name: app, namespace: nil, mark: .trackingID)
    }

    private static func strings(_ value: Any?) -> [String: String] {
        (value as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
