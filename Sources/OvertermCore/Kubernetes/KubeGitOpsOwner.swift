import Foundation

/// The Argo CD or Flux object an object's marks name as what deploys it
/// (docs/design/kubernetes/gitops.md, 1.1 and 4.2) — read from its labels
/// and annotations alone, never a field of theirs:
///
/// - Argo CD's `argocd.argoproj.io/tracking-id` annotation
///   (`<app>:<group>/<Kind>:<namespace>/<name>`; `<appNamespace>_<app>`
///   for an Application outside Argo CD's own namespace), checked by
///   `KubeTrackingID` and counted only on the object it names (14.1);
/// - its `argocd.argoproj.io/instance` label;
/// - `app.kubernetes.io/instance`, Argo CD 2.x's default tracking label
///   (`application.instanceLabelKey`) — "probably" Argo CD only, because
///   Helm charts set it too; never said when Helm's own release
///   annotation, Flux's labels or Argo's surer marks are there;
/// - Flux's `kustomize.toolkit.fluxcd.io/name|namespace` and
///   `helm.toolkit.fluxcd.io/name|namespace` labels.
///
/// Used by the rows that ask (`KubeListOptions.owners`), the apply's
/// warnings (`KubeFieldOwners.managedBy`), a GitOps object's delete and
/// its parent — each with the object's identity. Pure.
package struct KubeGitOpsOwner: Equatable, Hashable, Sendable {
    package enum Tool: String, Equatable, Hashable, Sendable {
        case argoCD, fluxKustomize, fluxHelm

        /// The kind of the object that deploys it.
        package var kind: String {
            switch self {
            case .argoCD: "Application"
            case .fluxKustomize: "Kustomization"
            case .fluxHelm: "HelmRelease"
            }
        }
    }

    /// Which mark said it.
    package enum Mark: String, Equatable, Hashable, Sendable {
        case trackingID, argoInstance, appInstance, fluxLabels
    }

    package var tool: Tool
    package var name: String
    /// The owner's own namespace, when the marks say it (Flux's namespace
    /// label; an Application's from `<namespace>_<app>`); nil means the
    /// tool's default namespace, unknown here.
    package var namespace: String?
    package var mark: Mark

    /// False only for `app.kubernetes.io/instance`: Helm sets it too.
    package var isCertain: Bool { mark != .appInstance }

    package static let trackingAnnotation = "argocd.argoproj.io/tracking-id"
    package static let argoInstanceLabel = "argocd.argoproj.io/instance"
    package static let appInstanceLabel = "app.kubernetes.io/instance"
    package static let kustomizeName = "kustomize.toolkit.fluxcd.io/name"
    package static let kustomizeNamespace = "kustomize.toolkit.fluxcd.io/namespace"
    package static let helmName = "helm.toolkit.fluxcd.io/name"
    package static let helmNamespace = "helm.toolkit.fluxcd.io/namespace"
    /// Helm's own install annotates this; Argo CD's rendering of a chart doesn't.
    package static let helmReleaseAnnotation = "meta.helm.sh/release-name"

    /// `Application argocd/acme-shop`, or `probably Argo CD Application acme-shop`.
    package var said: String {
        let place = namespace.map { "\($0)/\(name)" } ?? name
        return isCertain ? "\(tool.kind) \(place)" : "probably Argo CD \(tool.kind) \(place)"
    }

    /// Every owner the marks name: Argo CD's (the surest mark only), then
    /// Flux's. An object Flux deploys through Helm carries Helm's instance
    /// label too, which then names nobody.
    ///
    /// `self`: the object the marks sit on, when the caller knows it (a
    /// list's kind and row, an object's own kind and metadata). A tracking
    /// id that names another object is a copied mark — the Deployment
    /// controller copies a Deployment's annotations onto its ReplicaSets,
    /// operators their resource's onto what they make — and Argo CD tracks
    /// the object by none of its marks then (`isSelfReferencedObj`), so no
    /// Argo CD owner is said, from that mark or a label beside it. nil
    /// checks nothing: only a caller that can't know the object.
    package static func parse(labels: [String: String], annotations: [String: String], self object: KubeTrackingID.Identity?) -> [KubeGitOpsOwner] {
        var owners: [KubeGitOpsOwner] = []
        var copied = false
        if let value = annotations[trackingAnnotation], let id = KubeTrackingID.parse(value) {
            if let object, !id.isSelf(object) {
                copied = true
            } else {
                owners.append(KubeGitOpsOwner(tracking: id))
            }
        }
        // A tracking id that doesn't parse leaves the instance label to say who.
        if owners.isEmpty, !copied, let name = nonEmpty(labels[argoInstanceLabel]) {
            owners.append(KubeGitOpsOwner(tool: .argoCD, name: name, namespace: nil, mark: .argoInstance))
        }
        if let name = nonEmpty(labels[kustomizeName]) {
            owners.append(KubeGitOpsOwner(tool: .fluxKustomize, name: name, namespace: nonEmpty(labels[kustomizeNamespace]), mark: .fluxLabels))
        }
        if let name = nonEmpty(labels[helmName]) {
            owners.append(KubeGitOpsOwner(tool: .fluxHelm, name: name, namespace: nonEmpty(labels[helmNamespace]), mark: .fluxLabels))
        }
        if owners.isEmpty, !copied, annotations[helmReleaseAnnotation] == nil, let name = nonEmpty(labels[appInstanceLabel]) {
            owners.append(KubeGitOpsOwner(tool: .argoCD, name: name, namespace: nil, mark: .appInstance))
        }
        return owners
    }

    /// From an object's metadata, labels and annotations as JSON gives them.
    package static func parse(metadata: [String: Any]?, self object: KubeTrackingID.Identity?) -> [KubeGitOpsOwner] {
        parse(labels: strings(metadata?["labels"]), annotations: strings(metadata?["annotations"]), self: object)
    }

    /// `argocd.argoproj.io/tracking-id`'s Application, the value checked
    /// by `KubeTrackingID` (which object it names is the caller's to
    /// check: `parse(…self:)`); nil when it isn't one.
    package static func tracking(_ value: String) -> KubeGitOpsOwner? {
        KubeTrackingID.parse(value).map { KubeGitOpsOwner(tracking: $0) }
    }

    private static func strings(_ value: Any?) -> [String: String] {
        (value as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

extension KubeGitOpsOwner {
    /// The Application a tracking id names: `<appNamespace>_<app>` when it
    /// lives outside Argo CD's namespace (no Kubernetes name has a `_`).
    package init(tracking id: KubeTrackingID) {
        self.init(tool: .argoCD, name: id.appName, namespace: id.appNamespace, mark: .trackingID)
    }
}
