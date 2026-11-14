import Foundation

/// What the GitOps section says of the Argo CD apps read from the marks on
/// their objects (docs/design/kubernetes/gitops.md, 14.2): each app as a
/// row — its state Argo CD's built-in rules applied to what is here, its
/// worst member and why, its members counted by kind, its main image —,
/// made off the main thread (`base`) and only tagged here for the mode;
/// beside Applications that are read, where each stands (14.3); the
/// header's lines and their hover, the count (a floor when the read wasn't
/// whole, none while reading), the notes once; the empty sentences
/// ("carries no marks" only from a whole read); `k`'s argocd line
/// (decision D-2); and why Sync, Refresh, Rollback and Diff are the
/// Application's, never here (the detail's, `KubeMarkedAppDetail`, too). Apps grouped by
/// `app.kubernetes.io/instance` alone are only "probably" Argo CD's in
/// every sentence: never "another cluster", never missing beside
/// Applications. Nothing in it reads, and no row it makes has a kind of
/// its own: no write can pair with one. Pure.
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
        derived(rows: apps.map(base), mode: mode, applications: applications)
    }

    /// The same from the apps' rows as `base` made them — off the main
    /// thread, by `KubeMarkedBook` (14.4.6): only tags and a hover line
    /// are added here. Beside Applications, an app grouped by
    /// `app.kubernetes.io/instance` alone is never listed (14.3).
    static func derived(rows: [KubeGitOpsRow], mode: KubeMarkedAppsMode, applications: KubeMarkedAppsMode.ApplicationsRead) -> Derived {
        switch mode {
        case .off:
            return Derived()
        case .only:
            // Several installations: a tag on each row that carries one id.
            let first = rows.first?.marked?.installation
            guard rows.contains(where: { $0.marked?.installation != first }) else { return Derived(shown: rows) }
            return Derived(shown: rows.map { decorated($0, installations: true, beside: nil) })
        case .beside(let coexistence):
            var whole = false
            if case .acrossCluster = applications { whole = true }
            let listed = coexistence.listed
            let shown = rows.compactMap { row -> KubeGitOpsRow? in
                guard let marked = row.marked, !marked.probable, listed.contains(marked.key) else { return nil }
                let place: Beside
                if let same = coexistence.maybe[marked.key] {
                    place = .maybe(same)
                } else if coexistence.otherInstallation.contains(marked.key) {
                    place = .otherInstallation(marked.key.installation)
                } else {
                    place = .missing(whole: whole)
                }
                return decorated(row, installations: false, beside: place)
            }
            return Derived(shown: shown, beside: shown, unread: coexistence.unknown.count)
        }
    }

    /// The prefix of a derived row's id: no kind's full name is it.
    static let idPrefix = "marks/"

    /// One app's row (14.2.2), where it stands beside Applications and
    /// its installation (when several mark objects here) as tags.
    static func row(_ ranked: KubeMarkedRanked, installations several: Bool, beside: Beside? = nil) -> KubeGitOpsRow {
        decorated(base(ranked), installations: several, beside: beside)
    }

    /// One app's row before the mode says anything of it: its state
    /// ranked as decision D-7 says, its worst member's sentence and
    /// object, its members counted by kind ("label only", "probably" as
    /// tags), where its members live, no revision, its main image as its
    /// source, when its state began. Made off the main thread.
    static func base(_ ranked: KubeMarkedRanked) -> KubeGitOpsRow {
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
        let images = app.images
        var grouping = KubeGitOpsGroupKeys()
        grouping.source = images.first.map(imageGroup)
        grouping.destination = KubeGitOpsGrouping.destination(namespaces: app.namespaces)
        return KubeGitOpsRow(
            id: idPrefix + app.id, key: KubeGitOpsObject.Key(kind: "Marks", namespace: nil, name: app.id), resource: "",
            ref: KubeRowID(namespace: app.appNamespace, name: app.appName), role: .markedApp, tool: .argo, state: health.state,
            why: KubeGitOpsMessage.oneLine(health.why, limit: KubeGitOpsMessage.rowLimit), tags: tags, into: app.into, revision: "",
            source: source(images), since: health.since, summarised: true, hover: hover(ranked), grouping: grouping,
            marked: KubeGitOpsRow.Marked(
                key: app.key, word: health.word, fromRows: health.fromRows, images: images, installation: app.installation, sinceSaid: health.sinceSaid,
                probable: app.mark == .appInstance))
    }

    /// What the mode adds to an app's row: where it stands beside the
    /// Applications read — its tag, and its sentence second in the hover,
    /// never the line a long hover loses —, else its installation id when
    /// several mark objects here (the header counts the apps with none).
    static func decorated(_ row: KubeGitOpsRow, installations several: Bool, beside: Beside?) -> KubeGitOpsRow {
        var row = row
        if let beside {
            row.tags.append(.text(beside.tag))
            let lines = row.hover.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            row.hover = capped(([lines[0], beside.said] + lines.dropFirst()).joined(separator: "\n"))
        } else if several, let installation = row.marked?.installation {
            row.tags.append(.text("installation \(installation)"))
        }
        return row
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
    /// to 0 "scaled by its Rollout" —, its hooks, what its age is, and
    /// what isn't known here (where it stands beside Applications is the
    /// mode's: `decorated`). At most 4 KB.
    static func hover(_ ranked: KubeMarkedRanked) -> String {
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
        if app.appNamespace == nil, app.mark != .appInstance { lines.append("\(app.appName): in Argo CD's own namespace") }
        if let sinceSaid = health.sinceSaid { lines.append("Age: \(sinceSaid)") }
        lines.append(
            app.mark == .appInstance
                ? "No sync status, repository or revision here: if Argo CD deploys it, those are in its Application (repo: matches nothing here)."
                : "No sync status, repository or revision here: those are in the Application (repo: matches nothing here).")
        return capped(lines.joined(separator: "\n"))
    }

    /// The Source column's hover on an app read from marks: its images
    /// (each capped where its member was made), at most 4 KB.
    static func sourceHover(_ images: [String]) -> String {
        capped("Images, not a repository: \(images.prefix(8).joined(separator: ", "))\(images.count > 8 ? " +\(images.count - 8)" : "")")
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

    /// The marks' part of the header: `Argo CD: from marks · 894 apps ·
    /// read 40s ago` — "at least" when the read wasn't whole, no count
    /// while the first rows come, "none found in what could be read" when
    /// a read that wasn't whole found none; nil when a whole read found
    /// none (the empty sentence says so) or nothing is read. Apps grouped
    /// by `app.kubernetes.io/instance` alone are said as only that.
    static func header(apps: Int, reading: KubeMarkedReading, readAt: Date?, now: Date, probable: Bool = false) -> String? {
        guard !reading.kinds.isEmpty else { return nil }
        var parts = [probable ? "Argo CD, probably: by app.kubernetes.io/instance" : "Argo CD: from marks"]
        if !reading.isReading {
            if reading.isWhole {
                guard apps > 0 else { return nil }
                parts.append(counted(apps, "app"))
            } else {
                parts.append(apps > 0 ? "at least \(counted(apps, "app"))" : "none found in what could be read")
            }
        }
        if let read = readSaid(readAt, now: now, reading: reading.isReading) { parts.append(read) }
        return parts.joined(separator: " · ")
    }

    /// The section header's words in every mode: the tools served and how
    /// old the summaries are (off); Argo CD from marks, Flux after it where
    /// it is served (`.only`) — the tools' alone again once a whole read
    /// found no mark; beside Applications read, when the marked apps were
    /// read.
    static func sectionHeader(
        mode: KubeMarkedAppsMode, argo: Int, flux: Int, summarisedAt: Date?, summarising: Bool, apps: Int, reading: KubeMarkedReading, readAt: Date?,
        now: Date, probable: Bool = false
    ) -> String {
        switch mode {
        case .off:
            return KubeGitOpsSection.header(argo: argo, flux: flux, summarisedAt: summarisedAt, summarising: summarising, now: now)
        case .only:
            guard let marks = header(apps: apps, reading: reading, readAt: readAt, now: now, probable: probable) else {
                // No mark here, read whole: what is served, as before the marks were read — nothing where nothing is.
                guard argo + flux > 0 else { return "" }
                return KubeGitOpsSection.header(argo: argo, flux: flux, summarisedAt: summarisedAt, summarising: summarising, now: now)
            }
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

    /// The Revision column's hover on an app read from marks: "another
    /// cluster" only where Argo CD's Applications aren't served and the app
    /// carries Argo CD's own marks.
    static func revisionHover(_ mode: KubeMarkedAppsMode, probable: Bool = false) -> String {
        if probable { return "Argo CD's revision, if Argo CD deploys it, is in its Application, which isn't read here" }
        return mode == .only(.notServed)
            ? "Argo CD's revision is in the Application, in another cluster" : "Argo CD's revision is in the Application, which isn't read here"
    }

    /// Beside Applications read: today's words, and when the marked apps were read.
    static func besideHeader(_ header: String, readAt: Date?, now: Date, reading: Bool) -> String {
        let marks: String
        if reading {
            marks = "reading marked apps…"
        } else if let read = readSaid(readAt, now: now, reading: false) {
            marks = "marked apps \(read)"
        } else {
            return header
        }
        return [header, marks].filter { !$0.isEmpty }.joined(separator: " · ")
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
        /// The lead names what couldn't be read: the notes needn't again.
        var saysUnread = false
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
    /// installed"; apps grouped by `app.kubernetes.io/instance` alone only
    /// "probably", never where Argo CD runs), then the count; beside
    /// Applications read, the muted line whenever marked apps are listed
    /// among them, and those whose Application's namespace wasn't read,
    /// counted. None until an app was read: the empty sentence says the
    /// rest.
    static func lines(
        mode: KubeMarkedAppsMode, context: String, apps: [KubeMarkedApp], reading: KubeMarkedReading, tally: KubeMarkedApps.Tally, kinds: [String],
        unread: Int
    ) -> Lines {
        var lines = Lines()
        // Grouped by `app.kubernetes.io/instance` alone (D-5): no Argo CD
        // mark is here, so nothing is said of where Argo CD runs.
        let probable = !apps.isEmpty && apps.allSatisfy { $0.mark == .appInstance }
        switch mode {
        case .off:
            return lines
        case .only(let reason):
            guard !apps.isEmpty else { return lines }
            lines.lead =
                probable
                ? probableSentence(apps: apps.count, reading: reading) : "\(reason.line(context: context)) \(countSentence(reason, apps: apps.count, reading: reading))"
            lines.saysUnread = !reading.isReading && !reading.isWhole
            lines.limits = limits(reason, probable: probable)
        case .beside(let coexistence):
            if unread > 0 { lines.unread = "\(counted(unread, "marked app")) whose Application's namespace couldn't be read: not listed" }
            // Always shown while marked apps are among the Applications (14.2.1).
            guard !probable, !coexistence.listed.isEmpty else { return lines }
            lines.limits = limits(nil)
        }
        lines.hover = limitsHover(mode, kinds: kinds, rolloutsServed: reading.rolloutsServed, tally: tally, probable: probable)
        lines.installations = installationsLine(apps)
        return lines
    }

    /// The marks' notes under the header: what was refused, cut or is
    /// being checked — less what the lead or the empty sentence drawn says
    /// already (`emptyDrawn`: the marks' empty sentence is on screen).
    static func notes(_ reading: KubeMarkedReading, mode: KubeMarkedAppsMode, lines: Lines, emptyDrawn: Bool) -> [String] {
        guard mode != .off else { return [] }
        let said = reading.said
        let above = lines.saysUnread || (emptyDrawn && !reading.isReading && !reading.isWhole)
        guard above else { return said }
        let unread = Set(reading.unread)
        return said.filter { !unread.contains($0) }
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

    /// What an app grouped by `app.kubernetes.io/instance` alone is.
    static let probablyArgos = "only probably Argo CD's, grouped by app.kubernetes.io/instance — a label Helm and kustomize set too."

    /// The lead when no object here carries Argo CD's own marks and the
    /// apps are grouped by `app.kubernetes.io/instance` alone (D-5): only
    /// "probably" Argo CD's — a label Helm and kustomize set too —, never
    /// that Argo CD runs in another cluster.
    static func probableSentence(apps: Int, reading: KubeMarkedReading) -> String {
        if reading.isReading { return countSentence(.notServed, apps: apps, reading: reading) }
        guard reading.isWhole else {
            return
                "No Argo CD tracking id in what could be read: at least \(counted(apps, "app")) \(apps == 1 ? "is" : "are") \(probablyArgos) Not read: \(reading.unread.joined(separator: "; "))."
        }
        return "No Argo CD tracking id is here: \(apps == 1 ? "this app is" : "these \(apps.formatted()) apps are") \(probablyArgos)"
    }

    /// The second line, muted: no sync status, repository or revision —
    /// they are the Application's — and health is Argo CD's built-in rules;
    /// "Argo CD's cluster" never for apps only probably Argo CD's.
    static func limits(_ reason: KubeMarkedAppsMode.Reason?, probable: Bool = false) -> String {
        let fields: String
        if probable {
            fields = "No sync status, repository or revision: if Argo CD deploys these, those are in its Application, which isn't read here."
        } else {
            switch reason {
            case .forbidden?: fields = "No sync status, repository or revision: those are in the Application, which can't be read here."
            case .undiscovered?: fields = "No sync status, repository or revision: those are in the Application, which couldn't be looked for here."
            default: fields = "No sync status, repository or revision: those are in the Application, in Argo CD's cluster."
            }
        }
        return fields + " Health is Argo CD's built-in rules applied to what is here."
    }

    /// The limits' hover: what else leaves the same marks, what isn't
    /// known, what is read here and what never is, Argo Rollouts read for
    /// health only, the marks counted and not shown. "Argo CD runs in
    /// another cluster" explained only where it is said.
    static func limitsHover(_ mode: KubeMarkedAppsMode, kinds: [String], rolloutsServed: Bool, tally: KubeMarkedApps.Tally, probable: Bool = false) -> String {
        var lines: [String] = []
        if probable {
            lines.append(
                "No object here carries Argo CD's tracking id or its instance label: app.kubernetes.io/instance is set by Helm, kustomize and many operators too, so an app grouped by it alone may be none of Argo CD's."
            )
        } else if mode == .only(.notServed) {
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
    /// Copied, never run. A name the marks' parser lets through starts
    /// with `[a-z0-9]` (`KubeTrackingID`); nil for any other, so no part of
    /// it is ever read as an option.
    static func cliLine(_ row: KubeGitOpsRow) -> String? {
        row.marked.flatMap { cliLine(key: $0.key) }
    }

    /// The same for an app by its key: the detail's Copy as argocd.
    static func cliLine(key: KubeTrackingID.AppKey) -> String? {
        let q = KubeCommands.quoted
        let instance = key.instance
        let parts = instance.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") }) else { return nil }
        guard parts.count == 2 else { return "argocd app get \(q(instance))" }
        return "argocd app get \(q(parts[1])) --app-namespace \(q(parts[0]))"
    }

    /// Why Sync, Refresh, Rollback and Diff aren't offered (14.2.3): they
    /// act on the Application, which isn't here, in the mode's words — for
    /// an app only probably Argo CD's, nothing said of where Argo CD runs.
    static func absentVerbs(_ mode: KubeMarkedAppsMode, context: String, probable: Bool = false) -> String {
        let verbs = "Sync, Refresh, Rollback and Diff act on the Application"
        if probable { return "\(verbs) — if Argo CD deploys this app at all: it is only probably Argo CD's, and no Application of it is read here." }
        switch mode {
        case .only(.notServed): return "\(verbs), which is in Argo CD's cluster — not in your kubeconfig. Use Argo CD there."
        case .only(.noApplications): return "\(verbs), which isn't in this cluster. Use the Argo CD that deploys these."
        case .only(.forbidden): return "\(verbs), which can't be read in \(context) (forbidden)."
        case .only(.undiscovered): return "\(verbs), which couldn't be looked for in \(context): argoproj.io didn't answer discovery."
        case .beside, .off: return "\(verbs), which isn't among those read in \(context). Use the Argo CD that deploys it."
        }
    }
}
