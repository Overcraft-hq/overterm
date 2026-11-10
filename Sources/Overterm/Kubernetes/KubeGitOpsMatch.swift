import Foundation

/// Which Argo CD and Flux objects deploy a checkout (docs/design/
/// kubernetes/gitops.md, 4.2), from what the rail read — pure, so every
/// rule is a test's:
///
/// - **(b) the checkout is the app repo:** a bound workload's marks
///   (`KubeRow.owners`, `KubeGitOpsOwner`) name its owner, read by one GET
///   — `owns`. Helm's own `app.kubernetes.io/instance` names "probably
///   Argo CD" only until that Application is read and names the workload
///   among what it manages. A tracking id naming an Application the
///   cluster doesn't have is said (`notInCluster`), never looked for in
///   another context. With no marks, an Application whose
///   `status.summary.images` holds a bound workload's image probably
///   deploys it (`sameImage`).
/// - **(a) the checkout is a source:** an Application's `source(s)[i]`, a
///   Kustomization's or HelmRelease's GitRepository (through `sourceRef`,
///   or a `chartRef`'s HelmChart), or an OCIRepository whose artifact names
///   the repository it was built from — when its URL is one of the
///   checkout's remotes (`GitRemoteURL`: normalised, never with its
///   credentials). Its path is checked in the checkout (`KubeGitOpsPath`:
///   a path out of it refused, one not on this branch said) — `repoAndPath`,
///   else `repoOnly` with why: values from this repository, an OCI
///   artifact, a path not here.
///
/// The branch it tracks: Argo CD's `targetRevision` (`HEAD` is the remote's
/// default branch, read locally), Flux's `spec.ref` (commit > name > semver
/// > tag > branch; `master` by default) — "tracks main; this branch is
/// fix/orders" when they differ. Nothing here runs git; every ref that
/// later reaches git goes through `KubeGitOpsGitArgs` first.
enum KubeGitOpsMatch {
    /// Why an object is said to deploy the checkout.
    enum Why: Equatable, Hashable, Sendable {
        /// Its marks name it as the owner of these bound workloads.
        case owns([KubeWorkloadRef])
        /// No marks, but its images are these workloads'.
        case sameImage([KubeWorkloadRef])
        /// It takes this path of the checkout (`""`: its root), at `source`.
        case repoAndPath(String, source: Int?)
        /// It takes from the checkout's repository, not from a path here: why.
        case repoOnly(String, source: Int?)
        /// A tracking id names it, and the cluster hasn't it.
        case notInCluster(String)

        /// In grey under the row: "apps/web", "owns Deployment/shop-api".
        var said: String {
            switch self {
            case .owns(let workloads): "owns " + workloads.map(Self.workload).joined(separator: ", ")
            case .sameImage(let workloads): "probably deploys " + workloads.map(\.name).joined(separator: ", ") + " (same image)"
            case .repoAndPath(let path, _): path.isEmpty ? "the repository's root" : path
            case .repoOnly(let why, _): why
            case .notInCluster(let said): said
            }
        }

        /// The source of a multi-source Application that matched.
        var source: Int? {
            switch self {
            case .repoAndPath(_, let source), .repoOnly(_, let source): source
            default: nil
            }
        }

        /// A case (a) match: the repository is this checkout's.
        var isRepository: Bool {
            switch self {
            case .repoAndPath, .repoOnly: true
            default: false
            }
        }

        /// `Deployment/shop-api`.
        static func workload(_ ref: KubeWorkloadRef) -> String { "\(ref.kind.kind.kind)/\(ref.name)" }
    }

    /// One of the checkout's remotes: its name and the repository it names.
    struct Remote: Equatable, Hashable, Sendable {
        var name: String
        var repo: GitRemoteURL
    }

    /// The checkout's side: its remotes normalised, its branch, each
    /// remote's default branch (`refs/remotes/<remote>/HEAD`) — read
    /// locally, nothing fetched.
    struct Checkout: Equatable, Sendable {
        var root: URL
        var remotes: [Remote]
        var branch: String?
        var defaults: [String: String] = [:]

        /// The remotes' repositories, what a source's URL is compared with.
        var repos: Set<GitRemoteURL> { Set(remotes.map(\.repo)) }

        /// Which remote names `repo`.
        func remote(for repo: GitRemoteURL) -> Remote? { remotes.first { $0.repo == repo } }

        /// The cache's key: the remotes' normalised set, sorted.
        var remotesKey: String { repos.map(\.key).sorted().joined(separator: ",") }
    }

    /// What a match says beyond its object: why, and the branch it tracks.
    struct Found: Equatable, Sendable {
        var key: KubeGitOpsObject.Key
        var whys: [Why]
        var tracks: String?
        /// The owner whose GET found nothing: no object, only what its marks said.
        var owner: KubeGitOpsOwner?
    }

    /// What an owner's GET said: its object there, not there (404, or its
    /// kind not served), or unreadable (refused, failed) — which says
    /// nothing about the cluster, only that it couldn't be read.
    enum OwnerRead: Equatable, Sendable {
        case present
        case absent
        case unreadable
    }

    // MARK: (b) the owners

    /// Each owner the bound workloads' marks name, with the workloads it
    /// owns, in a stable order; certain marks first.
    static func owners(_ workloads: [(ref: KubeWorkloadRef, owners: [KubeGitOpsOwner])]) -> [(owner: KubeGitOpsOwner, workloads: [KubeWorkloadRef])] {
        var found: [KubeGitOpsOwner: [KubeWorkloadRef]] = [:]
        for workload in workloads {
            for owner in workload.owners where !(found[owner]?.contains(workload.ref) ?? false) { found[owner, default: []].append(workload.ref) }
        }
        return found.map { ($0.key, $0.value) }.sorted {
            if $0.owner.isCertain != $1.owner.isCertain { return $0.owner.isCertain }
            return ($0.owner.tool.kind, $0.owner.namespace ?? "", $0.owner.name) < ($1.owner.tool.kind, $1.owner.namespace ?? "", $1.owner.name)
        }
    }

    /// The key an owner's object is read by: its own namespace when the
    /// marks say it, else its tool's (`argocd`, `flux-system`).
    static func key(of owner: KubeGitOpsOwner) -> KubeGitOpsObject.Key {
        let namespace = owner.namespace ?? (owner.tool == .argoCD ? KubeGitOps.argoDefaultNamespace : KubeGitOpsControllers.fluxNamespace)
        return KubeGitOpsObject.Key(kind: owner.tool.kind, namespace: namespace, name: owner.name)
    }

    /// "managed by Argo CD Application acme-shop (not in kind-fake)".
    static func notInCluster(_ owner: KubeGitOpsOwner, context: String) -> String {
        "managed by \(owner.tool == .argoCD ? "Argo CD" : "Flux") \(owner.tool.kind) \(owner.namespace.map { "\($0)/" } ?? "")\(owner.name) (not in \(context))"
    }

    /// Whether an Application's managed resources name the workload, in
    /// the binding's namespace (`KubeGitOpsWire.Managed`).
    static func manages(_ managed: [KubeGitOpsWire.ManagedEntry], _ workload: KubeWorkloadRef, namespace: String) -> Bool {
        let kind = workload.kind.kind
        return managed.contains { entry in
            entry.kind == kind.kind && entry.name == workload.name && (entry.namespace ?? "") == namespace && (entry.group ?? "") == kind.group
        }
    }

    /// No marks: the Applications whose images are a bound workload's.
    static func sameImage(_ application: KubeGitOpsObject, workloads: [(ref: KubeWorkloadRef, images: [String])]) -> [KubeWorkloadRef] {
        guard application.role == .application, !application.images.isEmpty else { return [] }
        let images = Set(application.images)
        return workloads.filter { !$0.images.isEmpty && $0.images.contains(where: images.contains) }.map(\.ref)
    }

    // MARK: (a) the sources

    /// How `object` takes from the checkout, if it does: the best of its
    /// sources (a path here before a repository alone). `objects`: every
    /// summary held — a Kustomization's GitRepository, a HelmRelease's chart.
    static func source(_ object: KubeGitOpsObject, in checkout: Checkout, objects: [KubeGitOpsObject.Key: KubeGitOpsObject]) -> Why? {
        let repos = checkout.repos
        guard !repos.isEmpty else { return nil }
        switch object.role {
        case .application:
            var best: Why?
            for (index, source) in object.sources.enumerated() {
                // A chart's source (`chart:`, an `oci://` or a Helm repository) names no git repository.
                guard let repo = source.repo, repos.contains(repo) else { continue }
                let at = object.sources.count > 1 ? index : nil
                let why: Why
                if source.isValuesRef {
                    why = .repoOnly("values from this repository", source: at)
                } else {
                    why = path(source.path ?? "", in: checkout.root, source: at)
                }
                if case .repoAndPath = why { return why }
                if best == nil { best = why }
            }
            return best
        case .kustomization:
            guard let reference = object.sourceRef, let upstream = objects[key(reference)] else { return nil }
            return fromSource(upstream, path: object.sources.first?.path ?? "", in: checkout)
        case .helmRelease:
            if let reference = object.sourceRef, let upstream = objects[key(reference)] {
                return fromSource(upstream, path: object.sources.first?.chart ?? "", in: checkout)
            }
            if let reference = object.chartRef, let chart = objects[key(reference)] {
                if chart.role == .source("HelmChart"), let reference = chart.sourceRef, let upstream = objects[key(reference)] {
                    return fromSource(upstream, path: chart.sources.first?.chart ?? "", in: checkout)
                }
                return fromSource(chart, path: "", in: checkout)
            }
            return nil
        case .applicationSet, .source:
            return nil
        }
    }

    /// Through a Flux source: a GitRepository's URL and the path; an
    /// OCIRepository's artifact origin (its path not checked).
    static func fromSource(_ source: KubeGitOpsObject, path: String, in checkout: Checkout) -> Why? {
        switch source.role {
        case .source("GitRepository"):
            guard let repo = source.sources.first?.repo, checkout.repos.contains(repo) else { return nil }
            return Self.path(path, in: checkout.root, source: nil)
        case .source("OCIRepository"):
            guard let origin = source.artifactOrigin, checkout.repos.contains(origin.repo) else { return nil }
            return .repoOnly("an OCI artifact built from this repository", source: nil)
        default:
            return nil
        }
    }

    /// A path the cluster wrote, checked in the checkout.
    static func path(_ path: String, in root: URL, source: Int?) -> Why {
        switch KubeGitOpsPath.resolve(path, in: root) {
        case .inCheckout(let found): .repoAndPath(found, source: source)
        case let other: .repoOnly(KubeGitOpsPath.said(other), source: source)
        }
    }

    /// Whether a Flux source of this kind could name the checkout: a GitRepository's URL, an OCIRepository's origin.
    static func sourceMatches(_ source: KubeGitOpsObject, in checkout: Checkout) -> Bool {
        fromSource(source, path: "", in: checkout) != nil
    }

    static func key(_ reference: KubeGitOps.FluxSource) -> KubeGitOpsObject.Key {
        KubeGitOpsObject.Key(kind: reference.kind, namespace: reference.namespace, name: reference.name)
    }

    // MARK: What it tracks

    /// "tracks main", or "tracks main; this branch is fix/orders"; nil when
    /// nothing says. `objects`: the summaries, for a Flux object's source.
    static func tracks(_ object: KubeGitOpsObject, why: Why?, in checkout: Checkout, objects: [KubeGitOpsObject.Key: KubeGitOpsObject]) -> String? {
        guard let tracked = tracked(object, why: why, in: checkout, objects: objects), !tracked.isEmpty else { return nil }
        let said = "tracks \(tracked)"
        guard let branch = checkout.branch, !branch.isEmpty, branch != tracked else { return said }
        return "\(said); this branch is \(branch)"
    }

    /// The ref it follows, as the cluster wrote it — `HEAD` read as the
    /// matched remote's default branch.
    static func tracked(_ object: KubeGitOpsObject, why: Why?, in checkout: Checkout, objects: [KubeGitOpsObject.Key: KubeGitOpsObject]) -> String? {
        switch object.role {
        case .application:
            let sources = object.sources
            let index = why?.source ?? sources.firstIndex { $0.repo.map(checkout.repos.contains) ?? false } ?? 0
            guard sources.indices.contains(index) else { return nil }
            let source = sources[index]
            let revision = source.targetRevision ?? "HEAD"
            guard revision == "HEAD" else { return revision }
            let remote = source.repo.flatMap(checkout.remote(for:))
            return remote.flatMap { checkout.defaults[$0.name] } ?? "the default branch"
        case .kustomization, .helmRelease:
            var reference = object.sourceRef
            if reference == nil, let chart = object.chartRef.flatMap({ objects[key($0)] }), chart.role == .source("HelmChart") { reference = chart.sourceRef }
            guard let reference, let source = objects[key(reference)] else { return nil }
            return source.tracks
        case .source:
            return object.tracks
        case .applicationSet:
            return nil
        }
    }

    // MARK: Putting it together

    /// Every match, owners first, then the sources, each object once with
    /// all its reasons; what tracks what. `owned`: each owner's key and
    /// what it owns, and what its GET said (absent: said "not in this
    /// cluster" for a sure mark, dropped for Helm's label; unreadable:
    /// nothing said here — the problem line says it couldn't be read).
    static func found(
        owned: [(owner: KubeGitOpsOwner, workloads: [KubeWorkloadRef], read: OwnerRead)], objects: [KubeGitOpsObject.Key: KubeGitOpsObject],
        workloads: [(ref: KubeWorkloadRef, images: [String])], checkout: Checkout, context: String
    ) -> [Found] {
        var order: [KubeGitOpsObject.Key] = []
        var whys: [KubeGitOpsObject.Key: [Why]] = [:]
        var owners: [KubeGitOpsObject.Key: KubeGitOpsOwner] = [:]
        func add(_ key: KubeGitOpsObject.Key, _ why: Why) {
            if whys[key] == nil { order.append(key) }
            if !(whys[key]?.contains(why) ?? false) { whys[key, default: []].append(why) }
        }
        for (owner, refs, read) in owned {
            let key = key(of: owner)
            if read == .present, objects[key] != nil {
                add(key, .owns(refs))
            } else if read == .absent, owner.isCertain {
                add(key, .notInCluster(notInCluster(owner, context: context)))
                owners[key] = owner
            }
        }
        let main = objects.values.filter { [.application, .kustomization, .helmRelease].contains($0.role) }.sorted { $0.key.description < $1.key.description }
        for object in main {
            if let why = source(object, in: checkout, objects: objects) { add(object.key, why) }
        }
        // No marks at all on a workload: an Application with its image.
        let unmarked = workloads.filter { workload in !owned.contains { $0.workloads.contains(workload.ref) } }
        for object in main where object.role == .application {
            let same = sameImage(object, workloads: unmarked)
            if !same.isEmpty { add(object.key, .sameImage(same)) }
        }
        return order.map { key in
            let reasons = whys[key] ?? []
            let object = objects[key]
            return Found(
                key: key, whys: reasons, tracks: object.flatMap { tracks($0, why: reasons.first(where: \.isRepository), in: checkout, objects: objects) },
                owner: owners[key])
        }
    }
}
