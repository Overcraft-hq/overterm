import Foundation

/// Flux's and Argo CD's verbs (stage 4 — docs/design/kubernetes/analysis.md,
/// 2.23, decision 24): what their own CLIs set, as patches of Overterm's
/// through the page's one guard path — Flux's suspend, resume and
/// reconcile on Kustomizations, HelmReleases and Sources; Argo CD's
/// refresh on an Application. Each a merge patch (a custom resource takes
/// no strategic one), `fieldManager=overterm`. A sync is Argo CD's own:
/// `argocd` in a tab (`KubeTabWrite.argoSync`), as a reconcile with its
/// source is `flux` in one. Pure.
enum KubeGitOps {
    /// What `flux reconcile` and `flux resume` set to now: the controller
    /// reconciles at once, and says it did in `status.lastHandledReconcileAt`.
    static let requestedAt = "reconcile.fluxcd.io/requestedAt"
    /// What `argocd app get --refresh` sets: Argo CD compares the
    /// Application with its source again, then takes the annotation away.
    static let refresh = "argocd.argoproj.io/refresh"

    /// A Flux kind: what `flux` calls it, and whether `--with-source` is
    /// one of its reconcile's flags.
    struct Flux: Equatable, Sendable {
        /// `kustomization`, `helmrelease`, `source git`.
        var words: [String]
        var withSource: Bool

        var isSource: Bool { words.first == "source" }
    }

    /// The Flux kinds the verbs take, by group and resource.
    static let fluxKinds: [String: Flux] = [
        "kustomizations.kustomize.toolkit.fluxcd.io": Flux(words: ["kustomization"], withSource: true),
        "helmreleases.helm.toolkit.fluxcd.io": Flux(words: ["helmrelease"], withSource: true),
        "gitrepositories.source.toolkit.fluxcd.io": Flux(words: ["source", "git"], withSource: false),
        "helmrepositories.source.toolkit.fluxcd.io": Flux(words: ["source", "helm"], withSource: false),
        "helmcharts.source.toolkit.fluxcd.io": Flux(words: ["source", "chart"], withSource: false),
        "ocirepositories.source.toolkit.fluxcd.io": Flux(words: ["source", "oci"], withSource: false),
        "buckets.source.toolkit.fluxcd.io": Flux(words: ["source", "bucket"], withSource: false),
    ]

    static func flux(_ kind: KubeResourceKind) -> Flux? { fluxKinds[kind.fullName] }

    /// Flux's sources (GitRepository, OCIRepository, HelmRepository,
    /// Bucket, HelmChart): their `spec.url` can carry credentials.
    static func isFluxSource(_ kind: KubeResourceKind) -> Bool { kind.group == "source.toolkit.fluxcd.io" }

    static func isArgoApplication(_ kind: KubeResourceKind) -> Bool { kind.group == "argoproj.io" && kind.resource == "applications" }

    // MARK: Requests

    /// `flux suspend`: `spec.suspend` true.
    static func suspend(_ ref: KubeObjectRef) -> KubeWriteRequest { patch(ref, ["spec": ["suspend": true]]) }

    /// `flux resume`: `spec.suspend` false and a reconcile asked at once.
    static func resume(_ ref: KubeObjectRef, at date: Date) -> KubeWriteRequest {
        patch(ref, ["metadata": ["annotations": [requestedAt: KubeWrites.stamp(date)]], "spec": ["suspend": false]])
    }

    /// `flux reconcile`, without waiting: the annotation set to now.
    static func reconcile(_ ref: KubeObjectRef, at date: Date) -> KubeWriteRequest {
        patch(ref, ["metadata": ["annotations": [requestedAt: KubeWrites.stamp(date)]]])
    }

    /// Argo CD's normal refresh: the Application compared with its source again (no sync).
    static func refresh(_ ref: KubeObjectRef) -> KubeWriteRequest { patch(ref, ["metadata": ["annotations": [refresh: "normal"]]]) }

    private static func patch(_ ref: KubeObjectRef, _ body: [String: Any]) -> KubeWriteRequest {
        KubeWriteRequest(method: .PATCH, path: KubeWrites.managed(KubeWrites.path(ref)), body: KubeWrites.encode(body), contentType: KubeWrites.mergePatch)
    }

    // MARK: What each equals

    /// `flux suspend kustomization web --context C -n NS`: the Flux CLI's
    /// command that sets the same fields. Nil for a kind Flux's CLI doesn't name.
    static func fluxLine(_ action: String, _ ref: KubeObjectRef) -> String? {
        guard let flux = flux(ref.kind) else { return nil }
        var words = ["flux", action] + flux.words + [KubectlLine.quoted(ref.name), "--context", KubectlLine.quoted(ref.context)]
        if let namespace = ref.namespace { words += ["-n", KubectlLine.quoted(namespace)] }
        return words.joined(separator: " ")
    }

    /// The annotation Argo CD's refresh is, as kubectl would set it.
    static func refreshLine(_ ref: KubeObjectRef, discovery: KubeDiscovery?) -> String {
        var words = [
            "kubectl", "annotate", KubectlLine.quoted(KubectlLine.resource(ref.kind, in: discovery)), KubectlLine.quoted(ref.name),
            "\(refresh)=normal", "--overwrite", "--context", KubectlLine.quoted(ref.context),
        ]
        if let namespace = ref.namespace { words += ["-n", KubectlLine.quoted(namespace)] }
        return words.joined(separator: " ")
    }

    /// Why a reconcile isn't asked of a suspended one.
    static func suspended(_ object: String) -> String {
        "\(object) is suspended: Flux reconciles nothing until it is resumed — Resume Reconciliation asks for one at once."
    }

    // MARK: argocd and flux in a tab

    /// argocd's settings from the shell that would send a sync to an Argo
    /// CD server rather than the cluster the confirmation named — taken off
    /// for the one command, as helm's are (`KubeHelmWrite.unsetForWrites`).
    static let argoUnset = ["ARGOCD_SERVER", "ARGOCD_AUTH_TOKEN", "ARGOCD_OPTS"]

    /// `env -u ARGOCD_SERVER … argocd app sync 'web' --app-namespace 'team-a' --core --kube-context 'C'`:
    /// core mode, so argocd reaches the cluster by the context — not an
    /// Argo CD server it may be logged in to. Core mode takes Argo CD's own
    /// namespace (argocd-cm, argocd-secret, the repositories' and clusters'
    /// secrets) from the context's, so the tab is pinned to that one
    /// (`argoNamespace`); the Application's is `--app-namespace`.
    static func argoSyncLine(app: String, namespace: String, context: String) -> String {
        let q = KubeCommands.quoted
        return
            (["env"] + argoUnset.flatMap { ["-u", $0] } + [
                "argocd", "app", "sync", q(app), "--app-namespace", q(namespace), "--core", "--kube-context", q(context),
            ]).joined(separator: " ")
    }

    // MARK: Argo CD's own namespace

    /// Where Argo CD keeps its settings when nothing says otherwise.
    static let argoDefaultNamespace = "argocd"
    /// The ConfigMap an Argo CD install keeps its settings in: its namespace is the install's.
    static let argoConfigMap = "argocd-cm"

    /// Argo CD's control-plane namespace for an Application in
    /// `application`, from the namespaces an `argocd-cm` was found in:
    /// the Application's own when it holds one (Argo CD's usual layout),
    /// else the one install, else `argocd` among several, else the first;
    /// `argocd` when none was found (the list refused, or none there).
    static func argoNamespace(installs: [String], application: String) -> String {
        let found = Array(Set(installs.filter { !$0.isEmpty })).sorted()
        if found.contains(application) { return application }
        if found.contains(argoDefaultNamespace) || found.isEmpty { return argoDefaultNamespace }
        return found[0]
    }

    // MARK: Flux's sources

    /// The source `flux reconcile … --with-source` annotates before the
    /// object itself: its kind, as the access review names it, and where.
    struct FluxSource: Equatable, Sendable {
        var kind: String
        /// `gitrepositories.source.toolkit.fluxcd.io`.
        var resource: String
        var name: String
        var namespace: String

        /// `gitrepository flux-system/acme-shop`.
        var spoken: String { "\(kind.lowercased()) \(namespace)/\(name)" }
    }

    /// Flux's source kinds, by `kind`.
    static let sourceResources: [String: String] = [
        "GitRepository": "gitrepositories.source.toolkit.fluxcd.io",
        "OCIRepository": "ocirepositories.source.toolkit.fluxcd.io",
        "Bucket": "buckets.source.toolkit.fluxcd.io",
        "HelmRepository": "helmrepositories.source.toolkit.fluxcd.io",
        "HelmChart": "helmcharts.source.toolkit.fluxcd.io",
    ]

    /// A `sourceRef` (`kind`, `name`, `namespace` — the referrer's when
    /// none): nil without a name, or for a kind Flux's sources don't have.
    static func source(_ reference: Any?, in namespace: String) -> FluxSource? {
        guard let reference = reference as? [String: Any], let kind = reference["kind"] as? String, let name = reference["name"] as? String,
            !name.isEmpty, let resource = sourceResources[kind]
        else { return nil }
        let place = (reference["namespace"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? namespace
        return FluxSource(kind: kind, resource: resource, name: name, namespace: place)
    }

    /// What `flux reconcile … --with-source` annotates first, in its order,
    /// as far as the object says — as flux finds it: a Kustomization's
    /// `spec.sourceRef`; a HelmRelease's `spec.chartRef` (an OCIRepository,
    /// or a HelmChart, whose own source is that chart's to say —
    /// `chartSources`), else the HelmChart its chart template makes
    /// (`<namespace>-<name>`, in the template's source's namespace) and
    /// that source. Nil when it names none flux could fetch.
    static func sources(of object: [String: Any], resource: String) -> [FluxSource]? {
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let namespace = metadata["namespace"] as? String ?? ""
        let name = metadata["name"] as? String ?? ""
        let spec = object["spec"] as? [String: Any] ?? [:]
        switch resource {
        case "kustomizations.kustomize.toolkit.fluxcd.io":
            return source(spec["sourceRef"], in: namespace).map { [$0] }
        case "helmreleases.helm.toolkit.fluxcd.io":
            if spec["chartRef"] != nil {
                guard let chart = source(spec["chartRef"], in: namespace), ["OCIRepository", "HelmChart"].contains(chart.kind) else { return nil }
                return [chart]
            }
            let template = ((spec["chart"] as? [String: Any])?["spec"] as? [String: Any]) ?? [:]
            guard let origin = source(template["sourceRef"], in: namespace) else { return nil }
            let chart = FluxSource(kind: "HelmChart", resource: sourceResources["HelmChart"]!, name: "\(namespace)-\(name)", namespace: origin.namespace)
            return [chart, origin]
        default:
            return nil
        }
    }

    /// A HelmChart's own source, which flux fetches after annotating the
    /// chart (`spec.sourceRef`, in the chart's namespace).
    static func chartSources(of chart: [String: Any], at namespace: String) -> [FluxSource] {
        source((chart["spec"] as? [String: Any])?["sourceRef"], in: namespace).map { [$0] } ?? []
    }

    /// `flux reconcile kustomization 'web' --with-source --context 'C' -n 'NS'`:
    /// its source fetched first, then it, flux waiting for each.
    static func fluxReconcileLine(words: [String], name: String, namespace: String, context: String) -> String {
        let q = KubeCommands.quoted
        return (["flux", "reconcile"] + words + [q(name), "--with-source", "--context", q(context), "-n", q(namespace)]).joined(separator: " ")
    }
}
