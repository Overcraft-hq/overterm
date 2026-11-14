import Foundation

/// What the GitOps section says of the Argo CD apps read from the marks on
/// their objects (docs/design/kubernetes/gitops.md, 14.2): each app as a
/// row — its state Argo CD's built-in rules applied to what is here, its
/// worst member and why, its members counted by kind, its main image —;
/// beside Applications that are read, where each stands (14.3); the
/// header's lines and their hover, the count (a floor when the read wasn't
/// whole, none while reading); the empty sentences ("carries no marks" only
/// from a whole read); `k`'s argocd line (decision D-2); and the
/// placeholder detail's words — Sync, Refresh, Rollback and Diff are the
/// Application's, never here. Nothing in it reads, and no row it makes has
/// a kind of its own: no write can pair with one. Pure.
enum KubeMarkedSection {
    // MARK: Rows

    /// Where an app read from marks stands beside the Applications read
    /// (14.2.1, 14.3): "not in this cluster" only from a whole read.
    enum Beside: Equatable, Sendable {
        /// No Application of its instance name where they were read:
        /// `whole`, listed across the cluster; else in the namespaces read.
        case missing(whole: Bool)
        /// An Application of the same name lives in another namespace:
        /// listed, never said missing.
        case maybe(KubeRowID)
        /// Its marks carry an installation id, which no Application carries:
        /// whether it is this cluster's Argo CD can't be told.
        case otherInstallation(String)

        /// What its row's tag says, short.
        var tag: String {
            switch self {
            case .missing(whole: true): "not in this cluster"
            case .missing(whole: false): "not where Applications were read"
            case .maybe(let row): "may be \(row.description)"
            case .otherInstallation(let id): "installation \(id)"
            }
        }

        /// What its hover says, whole.
        var said: String {
            switch self {
            case .missing(whole: true): "Its Application isn't in this cluster."
            case .missing(whole: false): "Its Application wasn't found where Applications were read."
            case .maybe(let row): "An Application of the same name lives in \(row.namespace ?? "another namespace"): it may be \(row.description)."
            case .otherInstallation(let id): "Installation \(id): can't tell whether it is this cluster's Argo CD (an Application carries no installation id)."
            }
        }
    }

    /// The apps read from marks as the section's rows.
    struct Derived: Equatable, Sendable {
        /// Among the section's rows: every app when they are Argo CD's
        /// whole side (`.only`); beside Applications read, those with none here.
        var shown: [KubeGitOpsRow] = []
        /// Beside Applications read: those with none here, which their chip
        /// shows alone.
        var beside: [KubeGitOpsRow] = []
        /// Beside Applications read in some namespaces only: the marked
        /// apps whose Application's namespace wasn't read — counted.
        var unread = 0
    }

    /// The rows the mode shows: every app when derived apps are Argo CD's
    /// whole side; beside Applications read, only those with none here,
    /// among the Applications, each saying where it stands — their chip
    /// shows them alone; none when off.
    static func derived(_ apps: [KubeMarkedRanked], mode: KubeMarkedAppsMode, applications: KubeMarkedAppsMode.ApplicationsRead) -> Derived {
        switch mode {
        case .off:
            return Derived()
        case .only:
            let several = installations(apps.map(\.app)).count > 1
            return Derived(shown: apps.map { row($0, installations: several) })
        case .beside(let coexistence):
            var whole = false
            if case .acrossCluster = applications { whole = true }
            let listed = apps.filter { coexistence.listed.contains($0.app.key) }
            let several = installations(listed.map(\.app)).count > 1
            let rows = listed.map { ranked -> KubeGitOpsRow in
                let key = ranked.app.key
                let place: Beside
                if let same = coexistence.maybe[key] {
                    place = .maybe(same)
                } else if coexistence.otherInstallation.contains(key) {
                    place = .otherInstallation(key.installation)
                } else {
                    place = .missing(whole: whole)
                }
                return row(ranked, installations: several, beside: place)
            }
            return Derived(shown: rows, beside: rows, unread: coexistence.unknown.count)
        }
    }

    /// The prefix of a derived row's id: no kind's full name is it.
    static let idPrefix = "marks/"

    /// One app's row (14.2.2): its state ranked as decision D-7 says, its
    /// worst member's sentence and object, its members counted by kind
    /// ("label only", "probably", its installation id when several
    /// installations mark objects here — the header counts the apps with
    /// none —, where it stands beside Applications as tags), where its
    /// members live, no revision, its main image as its source, when its
    /// state began.
    static func row(_ ranked: KubeMarkedRanked, installations several: Bool, beside: Beside? = nil) -> KubeGitOpsRow {
        let app = ranked.app
        let health = ranked.health
        var tags: [KubeGitOpsTag] = []
        let counts = app.countsSaid
        if !counts.isEmpty { tags.append(.text(counts)) }
        switch app.mark {
        case .appInstance: tags.append(.text("probably: app.kubernetes.io/instance"))
        case .argoInstance: tags.append(.text("label only"))
        default: if app.labelOnly > 0 { tags.append(.text("\(app.labelOnly) label only")) }
        }
        if let beside {
            tags.append(.text(beside.tag))
        } else if several, let installation = app.installation {
            tags.append(.text("installation \(installation)"))
        }
        let images = app.images
        var grouping = KubeGitOpsGroupKeys()
        grouping.source = images.first.map(imageGroup)
        grouping.destination = KubeGitOpsGrouping.destination(namespaces: app.namespaces)
        return KubeGitOpsRow(
            id: idPrefix + app.id, key: KubeGitOpsObject.Key(kind: "Marks", namespace: nil, name: app.id), resource: "",
            ref: KubeRowID(namespace: app.appNamespace, name: app.appName), role: .markedApp, tool: .argo, state: health.state,
            why: KubeGitOpsMessage.oneLine(health.why, limit: KubeGitOpsMessage.rowLimit), tags: tags, into: app.into, revision: "",
            source: source(images), since: health.since, summarised: true, hover: hover(ranked, beside: beside), grouping: grouping,
            marked: KubeGitOpsRow.Marked(
                key: app.key, word: health.word, fromRows: health.fromRows, images: images, installation: app.installation, sinceSaid: health.sinceSaid))
    }

    /// The main image, its registry left out — the first container of the
    /// first workload — then how many more: `…/checkout-api:4.12.0 +1`.
    /// Not a git source: the header's hover says so.
    static func source(_ images: [String]) -> String {
        guard let first = images.first else { return "" }
        let main = shortImage(first)
        return images.count > 1 ? "\(main) +\(images.count - 1)" : main
    }

    /// `registry.acme.example/acme/checkout-api:4.12.0` → `…/checkout-api:4.12.0`;
    /// a name with no path as it is.
    static func shortImage(_ image: String) -> String {
        let capped = String(image.prefix(256))
        guard let slash = capped.lastIndex(of: "/") else { return capped }
        return "…/" + capped[capped.index(after: slash)...]
    }

    /// An image's repository, its tag and digest left out: what `G`'s
    /// source groups an app by.
    static func repository(_ image: String) -> String {
        var name = Substring(image.prefix(256))
        if let at = name.firstIndex(of: "@") { name = name[..<at] }
        // The tag is after the last ":" that follows the last "/": a registry's port is before one.
        if let colon = name.lastIndex(of: ":"), !name[name.index(after: colon)...].contains("/") { name = name[..<colon] }
        return String(name)
    }

    static func imageGroup(_ image: String) -> KubeGitOpsGroupKey {
        let repository = repository(image)
        return KubeGitOpsGroupKey(id: "\(KubeGitOpsGrouping.groupPrefix)source:image:\(repository)", title: repository, head: nil)
    }

    /// The row's hover: its word and why, Argo CD's own word, each cause
    /// with its condition's message (scrubbed and cut where it was read),
    /// every member as its app counts it — a Deployment its Rollout scales
    /// to 0 "scaled by its Rollout" —, its hooks, what its age is, where it
    /// stands beside Applications, and what isn't known here. At most 4 KB.
    static func hover(_ ranked: KubeMarkedRanked, beside: Beside?) -> String {
        let app = ranked.app
        let health = ranked.health
        var lines = ["\(health.word): \(health.why)"]
        lines += health.notes
        for cause in health.causes {
            lines.append("\(cause.said): \(cause.sentence)" + (cause.detail.map { " — \($0)" } ?? ""))
        }
        if health.more > 0 { lines.append("and \(health.more) more") }
        let causes = Set(health.causes.map(\.member))
        for member in app.members where !causes.contains(member.id) {
            guard let verdict = KubeMarkedHealth.member(member, in: app) else { continue }
            lines.append("\(member.said): \(verdict.sentence)\(verdict.fromRow ? " (from its row)" : "")")
        }
        for hook in app.hooks { lines.append("\(hook.said): a hook, not counted, as in Argo CD") }
        if app.appNamespace == nil { lines.append("\(app.appName): in Argo CD's own namespace") }
        if let sinceSaid = health.sinceSaid { lines.append("Age: \(sinceSaid)") }
        if let beside { lines.append(beside.said) }
        lines.append("No sync status, repository or revision here: those are in the Application (repo: matches nothing here).")
        return capped(lines.joined(separator: "\n"))
    }

    /// Text cut to `limit` bytes of UTF-8, "…" ending what was cut.
    static func capped(_ text: String, limit: Int = KubeGitOpsMessage.hoverLimit) -> String {
        guard text.utf8.count > limit else { return text }
        var kept = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > limit - 3 { break }
            kept.append(character)
            bytes += size
        }
        return kept + "…"
    }

    /// A phrase as a sentence begins: its first letter capitalised.
    private static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    // MARK: Installations

    /// The installations whose marks are here, the most apps first: "" for
    /// marks that carry no installation id.
    static func installations(_ apps: [KubeMarkedApp]) -> [(installation: String, apps: Int)] {
        var counts: [String: Int] = [:]
        for app in apps { counts[app.key.installation, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// `2 Argo CD installations mark objects here: hub-eu (812 apps),
    /// unnamed (82 apps)`; nil for one.
    static func installationsLine(_ apps: [KubeMarkedApp]) -> String? {
        let all = installations(apps)
        guard all.count > 1 else { return nil }
        let each = all.map { "\($0.installation.isEmpty ? "unnamed" : $0.installation) (\(counted($0.apps, "app")))" }
        return "\(all.count) Argo CD installations mark objects here: \(each.joined(separator: ", "))"
    }

    /// `1 app`, `1,024 apps`.
    static func counted(_ count: Int, _ noun: String) -> String { "\(count.formatted()) \(noun)\(count == 1 ? "" : "s")" }

    // MARK: The header

    /// The header's words while derived apps are Argo CD's whole side:
    /// `Argo CD: from marks · 894 apps · read 40s ago` — "at least" when
    /// the read wasn't whole, no count while the first rows come.
    static func header(apps: Int, reading: KubeMarkedReading, readAt: Date?, now: Date) -> String {
        var parts = ["Argo CD: from marks"]
        if !reading.isReading { parts.append(reading.isWhole ? counted(apps, "app") : "at least \(counted(apps, "app"))") }
        if let read = readSaid(readAt, now: now, reading: reading.isReading) { parts.append(read) }
        return parts.joined(separator: " · ")
    }

    /// The section header's words in every mode: the tools served and how
    /// old the summaries are (off); Argo CD from marks, Flux after it where
    /// it is served (`.only`); beside Applications read, when the marked
    /// apps were read.
    static func sectionHeader(
        mode: KubeMarkedAppsMode, argo: Int, flux: Int, summarisedAt: Date?, summarising: Bool, apps: Int, reading: KubeMarkedReading, readAt: Date?,
        now: Date
    ) -> String {
        switch mode {
        case .off:
            return KubeGitOpsSection.header(argo: argo, flux: flux, summarisedAt: summarisedAt, summarising: summarising, now: now)
        case .only:
            let marks = header(apps: apps, reading: reading, readAt: readAt, now: now)
            guard flux > 0 else { return marks }
            return "\(marks) · \(KubeGitOpsSection.header(argo: 0, flux: flux, summarisedAt: summarisedAt, summarising: summarising, now: now))"
        case .beside:
            let today = KubeGitOpsSection.header(argo: argo, flux: flux, summarisedAt: summarisedAt, summarising: summarising, now: now)
            return besideHeader(today, readAt: readAt, now: now, reading: reading.isReading)
        }
    }

    /// Beside Applications read, their chip: `12 marked apps with no Application here`.
    static func besideChip(_ count: Int) -> String {
        "\(counted(count, "marked app")) with no Application here"
    }

    /// The Revision column's hover on an app read from marks.
    static func revisionHover(_ mode: KubeMarkedAppsMode) -> String {
        mode == .only(.notServed)
            ? "Argo CD's revision is in the Application, in another cluster" : "Argo CD's revision is in the Application, which isn't read here"
    }

    /// Beside Applications read: today's words, and when the marked apps were read.
    static func besideHeader(_ header: String, readAt: Date?, now: Date, reading: Bool) -> String {
        guard let read = readSaid(readAt, now: now, reading: reading) else { return header }
        return [header, "marked apps \(read)"].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func readSaid(_ readAt: Date?, now: Date, reading: Bool) -> String? {
        if reading { return "reading marks…" }
        guard let readAt else { return nil }
        let age = now.timeIntervalSince(readAt)
        return age < 60 ? "read just now" : "read \(KubeAge.format(age)) ago"
    }

    /// What the header card says above its notes, in marks mode.
    struct Lines: Equatable, Sendable {
        /// Why the apps are read from marks, and how many: the mode's line,
        /// then the count — a floor when the read wasn't whole.
        var lead: String?
        /// Muted: what isn't known here, and what health is.
        var limits: String?
        /// The limits' hover.
        var hover = ""
        /// Several installations mark objects here.
        var installations: String?
        /// Beside Applications read in some namespaces only: those counted.
        var unread: String?
    }

    /// The lines for the mode (14.2.1): derived apps Argo CD's whole side —
    /// the mode's own sentence (only `.notServed` says "another cluster",
    /// `.noApplications` "aren't in this cluster", never "isn't
    /// installed"), then the count; beside Applications read, the marked
    /// apps whose Application's namespace wasn't read, counted. None until
    /// an app was read: the empty sentence says the rest.
    static func lines(
        mode: KubeMarkedAppsMode, context: String, apps: [KubeMarkedApp], reading: KubeMarkedReading, tally: KubeMarkedApps.Tally, kinds: [String],
        unread: Int
    ) -> Lines {
        var lines = Lines()
        switch mode {
        case .off:
            return lines
        case .only(let reason):
            guard !apps.isEmpty else { return lines }
            // Grouped by `app.kubernetes.io/instance` alone (D-5): no Argo CD
            // mark is here, so nothing is said of where Argo CD runs.
            let probable = apps.allSatisfy { $0.mark == .appInstance }
            lines.lead =
                probable
                ? probableSentence(apps: apps.count, reading: reading) : "\(reason.line(context: context)) \(countSentence(reason, apps: apps.count, reading: reading))"
            lines.limits = limits(reason)
        case .beside:
            if unread > 0 { lines.unread = "\(counted(unread, "marked app")) whose Application's namespace couldn't be read: not listed" }
            guard !apps.isEmpty else { return lines }
            lines.limits = limits(nil)
        }
        lines.hover = limitsHover(mode, kinds: kinds, rolloutsServed: reading.rolloutsServed, tally: tally)
        lines.installations = installationsLine(apps)
        return lines
    }

    /// The count after the mode's sentence: "These 894 apps are read from
    /// the marks Argo CD leaves on their objects."; "At least 12 apps, from
    /// what could be read: …"; while the first rows come, what is read.
    static func countSentence(_ reason: KubeMarkedAppsMode.Reason, apps: Int, reading: KubeMarkedReading) -> String {
        if reading.isReading { return "Reading the marks on \(reading.kinds.isEmpty ? "Deployments, StatefulSets and DaemonSets" : KubeMarkedReading.joined(reading.kinds))…" }
        guard reading.isWhole else { return "At least \(counted(apps, "app")), from what could be read: \(reading.unread.joined(separator: "; "))." }
        let argo = reason == .notServed || reason == .noApplications
        if apps == 1 { return argo ? "This app is read from the marks Argo CD leaves on its objects." : "This app is read from the marks on its objects." }
        return argo
            ? "These \(apps.formatted()) apps are read from the marks Argo CD leaves on their objects."
            : "These \(apps.formatted()) apps are read from the marks on their objects."
    }

    /// The lead when no object here carries Argo CD's own marks and the
    /// apps are grouped by `app.kubernetes.io/instance` alone (D-5): only
    /// "probably" Argo CD's — a label Helm and kustomize set too —, never
    /// that Argo CD runs in another cluster.
    static func probableSentence(apps: Int, reading: KubeMarkedReading) -> String {
        if reading.isReading { return countSentence(.notServed, apps: apps, reading: reading) }
        let what = "only probably Argo CD's, grouped by app.kubernetes.io/instance — a label Helm and kustomize set too."
        guard reading.isWhole else {
            return "No Argo CD tracking id in what could be read: at least \(counted(apps, "app")) \(apps == 1 ? "is" : "are") \(what) Not read: \(reading.unread.joined(separator: "; "))."
        }
        return "No Argo CD tracking id is here: \(apps == 1 ? "this app is" : "these \(apps.formatted()) apps are") \(what)"
    }

    /// The second line, muted: no sync status, repository or revision —
    /// they are the Application's — and health is Argo CD's built-in rules.
    static func limits(_ reason: KubeMarkedAppsMode.Reason?) -> String {
        let fields =
            switch reason {
            case .forbidden?: "No sync status, repository or revision: those are in the Application, which can't be read here."
            case .undiscovered?: "No sync status, repository or revision: those are in the Application, which couldn't be looked for here."
            default: "No sync status, repository or revision: those are in the Application, in Argo CD's cluster."
            }
        return fields + " Health is Argo CD's built-in rules applied to what is here."
    }

    /// The limits' hover: what else leaves the same marks, what isn't
    /// known, what is read here and what never is, Argo Rollouts read for
    /// health only, the marks counted and not shown.
    static func limitsHover(_ mode: KubeMarkedAppsMode, kinds: [String], rolloutsServed: Bool, tally: KubeMarkedApps.Tally) -> String {
        var lines: [String] = []
        if mode == .only(.notServed) {
            lines.append("“Argo CD runs in another cluster” is read from what is here: its marks, and no Application kind.")
        }
        lines.append(
            "An app deleted in Argo CD without deleting its resources leaves the same marks. So does an Argo CD uninstalled from this cluster, or objects restored from another cluster."
        )
        lines.append("Custom health checks configured in Argo CD aren't known here.")
        if !kinds.isEmpty {
            lines.append(
                "Read here: \(KubeMarkedReading.joined(kinds)). Custom resources aren't read, so their health isn't in an app's. ConfigMaps and Secrets are never listed, so an app made only of them isn't seen."
            )
        }
        if rolloutsServed {
            lines.append(
                "Argo Rollouts are read for their apps' health only: a Rollout's phase is its app's, the Deployment it runs said scaled by its Rollout. Promote and abort are Argo Rollouts' — not here."
            )
        }
        if tally.copied > 0 { lines.append("\(counted(tally.copied, "object")) carry another object's mark (copied by a controller or an operator): not members") }
        if tally.unparsed > 0 { lines.append("\(counted(tally.unparsed, "mark")) Argo CD wouldn't write: counted, never shown") }
        if tally.helm > 0 { lines.append("\(counted(tally.helm, "workload")) with Helm's instance label alone: not Argo CD's apps") }
        lines.append("A source here is an app's main image, not a repository; `repo:` matches no app read from marks, `image:` matches their images.")
        return capped(lines.joined(separator: "\n"))
    }

    // MARK: Empty

    /// The section's sentence when no app was read from marks and Argo CD's
    /// side is only theirs (14.2.1): while reading, what is read; a read
    /// that wasn't whole, what couldn't be read — never "carries no marks";
    /// a whole one, that none does, in the mode's words.
    static func empty(_ reason: KubeMarkedAppsMode.Reason, context: String, scope: KubeScope, reading: KubeMarkedReading) -> String {
        guard !reading.isReading, reading.isWhole else { return reading.empty(context: context, scope: scope, served: reason == .noApplications) }
        switch reason {
        case .notServed: return reading.empty(context: context, scope: scope, served: false)
        case .noApplications: return reading.empty(context: context, scope: scope, served: true)
        case .undiscovered, .forbidden: return "\(reason.line(context: context)) \(capitalized(reading.carriers(scope: scope)))"
        }
    }

    // MARK: k, the detail

    /// What `k` copies for an app read from marks (decision D-2): argocd's
    /// own `get`, against the person's Argo CD server — never `--core`,
    /// which would read this kubeconfig, nor `--kube-context`; the
    /// Application's namespace only for an `<appNamespace>_<name>` mark.
    /// Copied, never run.
    static func cliLine(_ row: KubeGitOpsRow) -> String? {
        guard let marked = row.marked else { return nil }
        let q = KubeCommands.quoted
        let instance = marked.key.instance
        guard let underscore = instance.firstIndex(of: "_") else { return "argocd app get \(q(instance))" }
        let name = String(instance[instance.index(after: underscore)...])
        return "argocd app get \(q(name)) --app-namespace \(q(String(instance[..<underscore])))"
    }

    /// Why Sync, Refresh, Rollback and Diff aren't offered (14.2.3): they
    /// act on the Application, which isn't here, in the mode's words.
    static func absentVerbs(_ mode: KubeMarkedAppsMode, context: String) -> String {
        let verbs = "Sync, Refresh, Rollback and Diff act on the Application"
        switch mode {
        case .only(.notServed): return "\(verbs), which is in Argo CD's cluster — not in your kubeconfig. Use Argo CD there."
        case .only(.noApplications): return "\(verbs), which isn't in this cluster. Use the Argo CD that deploys these."
        case .only(.forbidden): return "\(verbs), which can't be read in \(context) (forbidden)."
        case .only(.undiscovered): return "\(verbs), which couldn't be looked for in \(context): argoproj.io didn't answer discovery."
        case .beside, .off: return "\(verbs), which isn't among those read in \(context). Use the Argo CD that deploys it."
        }
    }

    /// The placeholder detail of one app (↩; its tree, its hints and what
    /// Argo CD alone knows come with D4): what the section read of it,
    /// nothing read for it.
    struct Detail: Equatable, Sendable {
        /// `payments/checkout-api`, or a bare name in Argo CD's namespace.
        var title: String
        /// Argo CD's word for it, ranked as its row is.
        var word: String
        var state: KubeGitOpsState
        var why: String
        /// The mode's sentence: why it is read from marks.
        var lead: String?
        /// Its installation, namespaces, images: one line each.
        var facts: [String]
        /// Each member and its health, as its app counts it.
        var members: [String]
        /// Its hooks: under the app, never in its health.
        var hooks: [String]
        /// Why the Application's verbs aren't here.
        var absent: String
        /// Promote and abort are Argo Rollouts' own.
        var rollouts: String?
    }

    static func detail(_ ranked: KubeMarkedRanked, mode: KubeMarkedAppsMode, context: String) -> Detail {
        let app = ranked.app
        let health = ranked.health
        var facts: [String] = []
        if let installation = app.installation { facts.append("Installation: \(installation)") }
        if app.appNamespace == nil { facts.append("Its Application: \(app.appName), in Argo CD's own namespace") }
        facts.append("Namespaces: \(app.namespaces.isEmpty ? "none read" : app.namespaces.joined(separator: ", "))")
        if !app.images.isEmpty { facts.append("Images: \(app.images.prefix(6).joined(separator: ", "))\(app.images.count > 6 ? " +\(app.images.count - 6)" : "")") }
        if app.mark == .appInstance { facts.append("Probably: read from app.kubernetes.io/instance alone, which Helm and kustomize set too") }
        let several = app.namespaces.count > 1
        let members = app.members.map { member -> String in
            let name = several ? "\(member.id.kind.kind) \(member.id.namespace.map { "\($0)/" } ?? "")\(member.id.name)" : member.said
            guard let verdict = KubeMarkedHealth.member(member, in: app) else { return "\(name) — no health rule here" }
            if member.marks.ignoreHealthcheck { return "\(name) — \(verdict.sentence) (ignore-healthcheck: not counted, as in Argo CD)" }
            let word = verdict.status?.word ?? "not read yet"
            return "\(name) — \(word): \(verdict.sentence)\(verdict.fromRow ? " (from its row)" : "")"
        }
        let hooks = app.hooks.map { "\($0.said) — a hook (\($0.marks.hook.map { $0.isEmpty ? "Argo CD" : $0 } ?? "")): not counted, as in Argo CD" }
        var lead: String?
        if case .only(let reason) = mode { lead = reason.line(context: context) }
        let rollouts =
            app.members.contains { $0.id.kind == .rollout }
            ? "Its Argo Rollout is read for its health only: promote and abort are Argo Rollouts' — not here." : nil
        return Detail(
            title: app.said, word: health.word, state: health.state, why: health.why, lead: lead, facts: facts, members: members, hooks: hooks,
            absent: absentVerbs(mode, context: context), rollouts: rollouts)
    }
}
