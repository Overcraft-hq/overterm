import Foundation

/// Which Argo CD apps read from marks deploy a checkout (docs/design/
/// kubernetes/gitops.md, 14.2.5) — where Argo CD's Applications aren't read
/// here, or a bound workload's isn't. By precision:
///
/// - **A**, the binding's own workloads: their own tracking ids name the
///   app — `owns`, the only answer that may say so (the person bound the
///   namespace and the selector);
/// - **B**, the checkout's committed manifests (`KubeCheckoutManifests`): a
///   document naming the group, Kind, namespace and name an app member's
///   tracking id names — `describes` N of its objects, never `owns`:
///   identity isn't provenance (a fork, an old copy, a rendered dump, an
///   app repository beside its config repository describe the same
///   objects). A document naming no namespace is compared only in the
///   binding's namespace, and only "probably": kustomize or Argo CD's
///   destination gives it one, which can't be read here;
/// - **C**, the app's name, its `<env>-<ns>-` and a trailing `-service`
///   left out (14.12's fourth consequence: on the surveyed clusters an
///   app's name never equals its objects'), equal to the repository's
///   name, a folder under `apps/`, `deploy/`, `k8s/`, `charts/` or
///   `manifests/`, or a manifest's name — "probably";
/// - **D**, an image's repository: `…/<org>/<repo>` the remote's
///   `org/repo`, or its last part the repository's — "probably".
///
/// C and D (and B with no namespace) are said only when A and B found
/// nothing, and none of them past three apps: "too many to tell". A Helm
/// chart's name is never used. Nothing found is never "not deployed": what
/// was compared, and what couldn't be, is said. A mark's text is compared
/// as a string in memory, never handed to git, a shell or a URL. Pure.
extension KubeGitOpsMatch {
    typealias AppKey = KubeTrackingID.AppKey

    /// What B, C and D found among a cluster's marked apps, made once as
    /// they were listed (B's rows across the cluster, or the GitOps
    /// section's apps) and kept with the rail's listing; A is set beside it
    /// as the bound workloads come (`marked(bound:listing:)`).
    struct MarkedListing: Equatable, Sendable {
        /// Why the rail reads from marks there.
        var reason: KubeMarkedAppsMode.Reason
        /// Each app's members listed: what A's "more elsewhere" counts.
        var members: [AppKey: [KubeMarkedMember.ID]] = [:]
        /// The apps B, C or D matched, as listed: their health from their rows.
        var apps: [AppKey: KubeMarkedApp] = [:]
        /// B: of each app, the objects the checkout's manifests name.
        var described: [AppKey: Set<KubeMarkedMember.ID>] = [:]
        /// B without a namespace (in the binding's only), C, D: each app's words.
        var probably: [AppKey: [String]] = [:]
        var manifests = KubeCheckoutManifests.Read()
        /// What listing couldn't read: refused, cut — said, its counts kept as numbers.
        var notes: [KubeCountedText] = []
        /// Every workload kind's rows read whole across the cluster: an
        /// app's members elsewhere are all counted, not a floor.
        var whole = true
        /// Whether its Argo Rollouts were read whole (14.12's second
        /// consequence): a Deployment scaled to 0 may be one a Rollout runs.
        var rollouts = RolloutsRead.notServed
        /// Read from the GitOps section's apps, ranked then: no request.
        var fromSection: Date?
    }

    /// B, C and D against `apps`, the cluster's marked apps as listed.
    /// `namespace`: the binding's, the only one a manifest without a
    /// namespace is compared in.
    static func markedListing(
        _ apps: [KubeMarkedApp], manifests: KubeCheckoutManifests.Read, checkout: Checkout, namespace: String, reason: KubeMarkedAppsMode.Reason,
        notes: [KubeCountedText] = [], whole: Bool = true, rollouts: RolloutsRead = .notServed, fromSection: Date? = nil
    ) -> MarkedListing {
        var listing = MarkedListing(reason: reason, manifests: manifests, notes: notes, whole: whole, rollouts: rollouts, fromSection: fromSection)
        // Each member by the object its own tracking id names.
        var byObject: [KubeCheckoutManifests.Identity: (key: AppKey, id: KubeMarkedMember.ID)] = [:]
        var byKey: [AppKey: KubeMarkedApp] = [:]
        for app in apps {
            byKey[app.key] = app
            listing.members[app.key] = app.members.map(\.id)
            for member in app.members {
                guard case .own(let id) = member.marks.tracking else { continue }
                byObject[KubeCheckoutManifests.Identity(group: id.group, kind: id.kind, namespace: member.id.namespace, name: id.name)] = (app.key, member.id)
            }
        }
        var matched = Set<AppKey>()
        for identity in manifests.identities.sorted() {
            if identity.namespace != nil {
                guard let found = byObject[identity] else { continue }
                listing.described[found.key, default: []].insert(found.id)
                matched.insert(found.key)
            } else {
                var placed = identity
                placed.namespace = namespace
                guard let found = byObject[placed] else { continue }
                listing.probably[found.key, default: []].append(
                    "a manifest names \(identity.kind) \(identity.name) without a namespace; this app's is in \(namespace), the bound one")
                matched.insert(found.key)
            }
        }
        // C and D, for the apps B didn't find whole: said only if A and B find
        // nothing. A manifest's name counts in the namespace it names — one
        // naming none in the binding's alone, where B said it already.
        for app in apps where listing.described[app.key] == nil {
            var words: [String] = []
            var names = Set(app.namespaces.flatMap { manifests.names[$0] ?? [] })
            if listing.probably[app.key] == nil, app.namespaces.contains(namespace) { names.formUnion(manifests.names[""] ?? []) }
            if let byName = byName(app, checkout: checkout, folders: manifests.folders, names: names) { words.append(byName) }
            if let byImage = byImage(app, checkout: checkout) { words.append(byImage) }
            guard !words.isEmpty else { continue }
            listing.probably[app.key, default: []] += words
            matched.insert(app.key)
        }
        for key in matched { listing.apps[key] = byKey[key] }
        return listing
    }

    // MARK: C: the app's name

    /// The app's name as the checkout would call it: its `<env>-<ns>-` left
    /// out where one of its namespaces sits in it with something before,
    /// then a trailing `-service` — `prod-payments-checkout-api-service`,
    /// in payments, is `checkout-api`. Lowercased.
    static func stem(_ app: KubeMarkedApp) -> String {
        var name = app.appName.lowercased()
        for namespace in app.namespaces.sorted(by: { $0.count > $1.count }) {
            if let range = name.range(of: "-\(namespace.lowercased())-"), range.lowerBound > name.startIndex, range.upperBound < name.endIndex {
                name = String(name[range.upperBound...])
                break
            }
        }
        let suffix = "-service"
        if name.hasSuffix(suffix), name.count > suffix.count { name.removeLast(suffix.count) }
        return name
    }

    /// The repository names of the checkout's remotes: each path's last part, lowercased.
    static func repositoryNames(_ checkout: Checkout) -> Set<String> {
        Set(checkout.remotes.compactMap { $0.repo.path.split(separator: "/").last.map { $0.lowercased() } })
    }

    /// Whether the app's name, as the checkout would call it, is the
    /// repository's, a folder's or a manifest's: the words, else nil.
    static func byName(_ app: KubeMarkedApp, checkout: Checkout, folders: Set<String>, names: Set<String>) -> String? {
        let stem = stem(app)
        let full = app.appName.lowercased()
        guard stem.count >= 2 else { return nil }
        let read = stem == full ? "its name" : "its name, read as \(stem),"
        let candidates = stem == full ? [stem] : [stem, full]
        if candidates.contains(where: repositoryNames(checkout).contains) { return "\(read) is the repository's" }
        if candidates.contains(where: folders.contains) { return "\(read) is a folder's under apps/, deploy/, k8s/, charts/ or manifests/" }
        if candidates.contains(where: names.contains) { return "\(read) is a manifest's here" }
        return nil
    }

    // MARK: D: an image's repository

    /// An image's repository as path parts, lowercased: its registry, tag
    /// and digest left out — `registry.acme.example/acme/api:4.1@sha256:…`
    /// is `acme`, `api`.
    static func imageParts(_ image: String) -> [String] {
        var text = image
        if let at = text.firstIndex(of: "@") { text = String(text[..<at]) }
        var parts = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let last = parts.last else { return [] }
        if let colon = last.lastIndex(of: ":") { parts[parts.count - 1] = String(last[..<colon]) }
        if parts.count > 1, let first = parts.first, first.contains(".") || first.contains(":") || first == "localhost" { parts.removeFirst() }
        return parts.map { $0.lowercased() }.filter { !$0.isEmpty }
    }

    /// Whether a member's image names the checkout's repository: the words, else nil.
    static func byImage(_ app: KubeMarkedApp, checkout: Checkout) -> String? {
        let remotes = checkout.remotes.map { $0.repo.path.split(separator: "/").map { $0.lowercased() } }.filter { !$0.isEmpty }
        for image in app.images {
            let parts = imageParts(image)
            guard let last = parts.last else { continue }
            for remote in remotes {
                let sameRepository = parts.count >= 2 && remote.count >= 2 && Array(parts.suffix(2)) == Array(remote.suffix(2))
                if sameRepository || last == remote.last { return "its image \(KubeMarkedSection.shortImage(image)) is named as this repository" }
            }
        }
        return nil
    }

    // MARK: A, B, C and D together

    /// One app read from marks that deploys the checkout, or probably does.
    struct MarkedFound: Equatable, Sendable {
        var app: KubeMarkedApp
        var whys: [Why]
        /// By name, image or a manifest with no namespace: never found.
        var probable: Bool
        /// Its bound workloads are among its members (A).
        var bound: Bool
    }

    /// What the rail says of the apps read from marks.
    struct MarkedAnswer: Equatable, Sendable {
        /// A and B.
        var found: [MarkedFound] = []
        /// C, D and B with no namespace, when A and B found nothing.
        var probably: [MarkedFound] = []
        /// More than three of those: none listed.
        var tooMany: String?
        /// A to D found nothing, B having compared: what was, and what couldn't be.
        var nothing: String?
        /// What B's compare couldn't do, said under what it found.
        var caveats: [String] = []
    }

    /// A — `bound`, each app the bound workloads' own marks name, with
    /// those workloads — beside what the listing found (nil: B not run).
    /// `plain`: what was compared said with an agent's plain counts.
    static func marked(bound: [(app: KubeMarkedApp, workloads: [KubeWorkloadRef])], listing: MarkedListing?, plain: Bool = false) -> MarkedAnswer {
        var answer = MarkedAnswer()
        var order: [AppKey] = []
        var found: [AppKey: MarkedFound] = [:]
        for (app, workloads) in bound where found[app.key] == nil {
            found[app.key] = MarkedFound(app: app, whys: [.owns(workloads)], probable: false, bound: true)
            order.append(app.key)
        }
        guard let listing else {
            answer.found = order.compactMap { found[$0] }
            return answer
        }
        for key in listing.described.keys.sorted() {
            guard let ids = listing.described[key] else { continue }
            let why = Why.describes(ids.count, of: max(listing.members[key]?.count ?? 0, ids.count))
            if var existing = found[key] {
                existing.whys.append(why)
                found[key] = existing
            } else if let app = listing.apps[key] {
                found[key] = MarkedFound(app: app, whys: [why], probable: false, bound: false)
                order.append(key)
            }
        }
        answer.found = order.compactMap { found[$0] }
        if answer.found.isEmpty {
            let probable = listing.probably.keys.sorted().compactMap { key -> MarkedFound? in
                guard let app = listing.apps[key], let words = listing.probably[key], !words.isEmpty else { return nil }
                return MarkedFound(app: app, whys: words.map(Why.probably), probable: true, bound: false)
            }
            if probable.count > maxProbable {
                answer.tooMany = "\(probable.count) apps by name or image: too many to tell"
            } else {
                answer.probably = probable
            }
        }
        if answer.found.isEmpty, answer.probably.isEmpty, answer.tooMany == nil {
            answer.nothing = nothingFound(listing, plain: plain)
        } else {
            answer.caveats = caveats(listing, plain: plain)
        }
        return answer
    }

    /// More than this many apps by name or image: too many to tell.
    static let maxProbable = 3

    /// "No marked app matched: 412 manifests compared, 37 Helm templates
    /// not rendered, …" — never that nothing deploys it (`plain`: an
    /// agent's counts, never the locale's `1.412`).
    static func nothingFound(_ listing: MarkedListing, plain: Bool = false) -> String {
        let manifests = listing.manifests
        var parts: [String] = []
        if let failed = manifests.failed {
            parts.append(failed)
        } else if manifests.files == 0 {
            parts.append("no committed manifest in this checkout")
        } else {
            parts.append("\(KubeCountedText.number(manifests.documents, plain: plain)) \(manifests.documents == 1 ? "manifest" : "manifests") compared")
        }
        return "No marked app matched: " + (parts + caveats(listing, plain: plain)).joined(separator: ", ")
    }

    /// What B's compare couldn't do: templates not rendered, a
    /// kustomization's prefix, folders skipped, links not followed, the
    /// bound, what listing couldn't read.
    static func caveats(_ listing: MarkedListing, plain: Bool = false) -> [String] {
        let manifests = listing.manifests
        var said: [String] = []
        func count(_ number: Int, _ one: String, _ many: String) -> String { "\(KubeCountedText.number(number, plain: plain)) \(number == 1 ? one : many)" }
        if manifests.templates > 0 { said.append(count(manifests.templates, "Helm template", "Helm templates") + " not rendered") }
        if manifests.prefixed > 0 {
            said.append(count(manifests.prefixed, "kustomization's", "kustomizations'") + " namePrefix or nameSuffix not applied")
        }
        if manifests.skipped > 0 { said.append(count(manifests.skipped, "file", "files") + " under test or example folders skipped") }
        if manifests.links > 0 { said.append(count(manifests.links, "link", "links") + " not followed") }
        if manifests.unreadable > 0 { said.append(count(manifests.unreadable, "file", "files") + " not read as YAML") }
        if let cut = manifests.cut { said.append(cut.said(plain: plain)) }
        return said + listing.notes.map { $0.said(plain: plain) }
    }

    // MARK: Where it stands, whose health

    /// Where an app read from marks stands against its Application, as the
    /// rail can say it — "another cluster" only where Applications aren't
    /// served and argoproj.io answered discovery.
    enum MarkedPlace: Equatable, Sendable {
        case reason(KubeMarkedAppsMode.Reason)
        /// Served and read: not at its place.
        case absent
        /// A plain name's 404 in argocd, this context's Applications not
        /// seen there: Argo CD's namespace here unknown.
        case notFound
        /// Refused (403).
        case refused
        /// Couldn't be read: the problem line says why.
        case unread

        func said(context: String) -> String {
            switch self {
            case .reason(.notServed): "Argo CD runs in another cluster — not in your kubeconfig"
            case .reason(.undiscovered): "where Argo CD runs can't be told: argoproj.io didn't answer discovery"
            case .reason(.noApplications), .absent: "its Application isn't in \(context)"
            case .reason(.forbidden), .refused: "its Application can't be read in \(context) (forbidden)"
            case .notFound: "its Application wasn't found in argocd; Argo CD's namespace here is unknown"
            case .unread: "its Application couldn't be read in \(context)"
            }
        }

        /// Where what only the Application knows is, in the place's words
        /// (`KubeMarkedAppDetail.whereTheApplicationIs`): "Argo CD's cluster"
        /// only where Applications aren't served and argoproj.io answered.
        func whereApplication(probable: Bool = false) -> String {
            switch self {
            case .reason(let reason): KubeMarkedAppDetail.whereTheApplicationIs(.only(reason), probable: probable)
            case .absent: KubeMarkedAppDetail.whereTheApplicationIs(.only(.noApplications), probable: probable)
            case .refused: KubeMarkedAppDetail.whereTheApplicationIs(.only(.forbidden), probable: probable)
            case .notFound, .unread: KubeMarkedAppDetail.whereTheApplicationIs(.off, probable: probable)
            }
        }
    }

    /// The rail's line where it reads Argo CD's apps from marks across the
    /// cluster (14.2.5): Argo CD isn't here — only where argoproj.io
    /// answered discovery —, couldn't tell, none here, or refused; read
    /// from the marks on the bound namespace's workloads (`namespace`), or
    /// — only option B's, C's or D's — on the cluster's.
    static func marksLine(_ reason: KubeMarkedAppsMode.Reason, context: String, namespace: String?) -> String {
        let read = "read from the marks on \(namespace.map { "\($0)'s" } ?? "the cluster's") workloads"
        switch reason {
        case .notServed: return "Argo CD isn't in \(context); \(read)"
        case .undiscovered: return "Couldn't tell whether Argo CD runs in \(context): argoproj.io didn't answer discovery"
        case .noApplications: return "Argo CD's Applications aren't in \(context); \(read)"
        case .forbidden: return "Argo CD's Applications can't be read in \(context) (forbidden); \(read)"
        }
    }

    /// Whose health the rail says of an app read from marks.
    enum MarkedScope: Equatable, Sendable {
        /// The bound workloads, with `rollouts` of their app's Argo
        /// Rollouts in the binding's namespace (each the workload of a
        /// Deployment it scales to 0); `elsewhere`, its other members as
        /// option B listed them, by namespace — nil when nothing listed the
        /// app —, `whole` when that listing read every kind whole.
        case bound(Int, rollouts: Int = 0, elsewhere: [String: Int]?, whole: Bool = true)
        /// Its workloads as listed across the cluster, from their rows.
        case listed(Int)
        /// The GitOps section's verdict, as it ranked it then.
        case section(Date)

        func said(now: Date) -> String {
            switch self {
            case .bound(let count, let rollouts, let elsewhere, let whole):
                var objects = "health of the \(count) \(count == 1 ? "object" : "objects") bound here"
                if rollouts > 0 { objects += rollouts == 1 ? " with its app's Argo Rollout" : " with its app's \(rollouts) Argo Rollouts" }
                guard let elsewhere else { return objects + "; other namespaces not read" }
                // A listing cut or refused somewhere: what it counted is a floor.
                let rest = whole ? "" : "; other namespaces not all read"
                guard !elsewhere.isEmpty else { return objects + rest }
                let places = elsewhere.sorted { $0.key < $1.key }.enumerated().map { index, entry in
                    index == 0 ? "\(entry.value) more in \(entry.key)" : "\(entry.value) in \(entry.key)"
                }
                return objects + "; " + KubeMarkedReading.joined(places) + " not counted" + rest
            case .listed(let count):
                return "health of its \(count) \(count == 1 ? "workload" : "workloads"), from their rows"
            case .section(let at):
                return "as the GitOps section read it \(KubeAge.format(max(0, now.timeIntervalSince(at)))) ago"
            }
        }
    }

    /// What was read of Argo Rollouts where the rail says an app's health
    /// (14.12's second consequence): a Deployment scaled to 0 may be the one
    /// a Rollout runs by `workloadRef` — the Rollout then the app's
    /// workload, the Deployment "scaled by its Rollout".
    enum RolloutsRead: Equatable, Sendable {
        /// Argo Rollouts aren't served: a Deployment's 0 is its own.
        case notServed
        /// Read whole where they would be: an app's Rollout is among its members.
        case read
        /// Not read yet, or not whole — refused, cut, failed —, said:
        /// whether a Rollout runs a Deployment scaled to 0 can't be told.
        case unread(String)
    }

    /// An app's health as the rail says it: Argo CD's built-in rules over
    /// its members (`KubeMarkedHealth.app`: a Deployment its Rollout scales
    /// to 0 "scaled by its Rollout"), save that where Argo Rollouts are
    /// served and weren't read whole, a Deployment scaled to 0 with no
    /// Rollout of the app read is Unknown as a member — a Rollout may run
    /// it, and its 0 says nothing of the app —, ranked with the others by
    /// `app`: a Degraded sibling still ranks the app with Failed and is
    /// named first (decision D-7), never hidden behind it.
    static func health(_ app: KubeMarkedApp, rollouts: RolloutsRead) -> KubeMarkedHealth.AppVerdict {
        guard case .unread(let why) = rollouts, !app.members.contains(where: { $0.id.kind == .rollout }) else { return app.health }
        var unknown = app
        var changed = false
        for index in unknown.members.indices where unknown.members[index].id.kind == .deployment && unknown.members[index].health?.scaledToZero == true {
            unknown.members[index].health = KubeMarkedHealth.Verdict(status: .unknown, sentence: "scaled to 0; an Argo Rollout may run it (\(why))")
            changed = true
        }
        return changed ? unknown.health : app.health
    }
}
