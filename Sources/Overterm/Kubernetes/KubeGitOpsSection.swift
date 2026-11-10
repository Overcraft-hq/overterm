import CoreGraphics
import Foundation

/// One row of the GitOps section (docs/design/kubernetes/gitops.md, 2.2):
/// an Argo CD or Flux object, summarised or — not yet, or past the
/// summaries' bound — as its live row's cells say it. Pure.
struct KubeGitOpsRow: ResourceTableRow, Identifiable, Sendable {
    /// `<resource>/<namespace>/<name>`: the selection's tag.
    var id: String
    var key: KubeGitOpsObject.Key
    /// The kind's full name: `applications.argoproj.io`.
    var resource: String
    var ref: KubeRowID
    var role: KubeGitOpsObject.Role
    var tool: KubeGitOpsObject.Tool
    var state: KubeGitOpsState
    /// One line, at most 300 characters, scrubbed (5.3).
    var why: String
    var tags: [KubeGitOpsTag] = []
    var into = ""
    var revision = ""
    var source = ""
    /// When its state began, read from the object; else when it was made.
    var since: Date?
    /// Whether a summary stands behind it (else its cells alone, "…").
    var summarised: Bool
    /// What the hover says: the why, the last error, the conditions — at most 4 KB, scrubbed.
    var hover = ""

    var height: CGFloat { 26 }

    static func id(resource: String, _ ref: KubeRowID) -> String { "\(resource)/\(ref.namespace ?? "")/\(ref.name)" }
}

/// What the GitOps section draws from what was read (gitops.md, 2.2–2.5):
/// the rows — summaries kept by the scope rule, live rows not summarised
/// "not placed" off All Namespaces — in display order, the chips, Hide
/// Ready, the header's words, the empty scope's hint, the columns and the
/// CLI lines `k` copies. The state of a row not yet summarised comes from
/// its cells alone. Pure.
enum KubeGitOpsSection {
    /// Above this many rows, Ready ones are hidden until their chip is pressed (decision 10).
    static let hideReadyAbove = 50

    /// The section's columns, in order (2.2's table).
    static let columns: [ResourceColumn] = [
        ResourceColumn(id: "state", title: "State", width: 104, minWidth: 80),
        ResourceColumn(id: "kind", title: "Kind", width: 58, minWidth: 40),
        ResourceColumn(id: "name", title: "Name", width: 220, minWidth: 100),
        ResourceColumn(id: "into", title: "Into", width: 90, minWidth: 50, help: "→ a destination field; a namespace it manages; ⇢ another cluster, said, never followed"),
        ResourceColumn(id: "why", title: "Why", width: 320, minWidth: 120),
        ResourceColumn(id: "revision", title: "Revision", width: 150, minWidth: 70, help: "Argo CD: live → target while OutOfSync; Flux: what is applied; a source: its artifact"),
        ResourceColumn(id: "source", title: "Source", width: 220, minWidth: 80),
        ResourceColumn(id: "age", title: "Age", width: 56, minWidth: 40, help: "Since the state began, read from the object"),
    ]

    /// The rows that live in or deploy into the scope, and those that can't
    /// be placed (not summarised, off All Namespaces).
    struct Rows: Equatable, Sendable {
        var shown: [KubeGitOpsRow] = []
        var notPlaced: [KubeGitOpsRow] = []
        /// Summaries anywhere (not only the scope's): where the empty scope's hint points.
        var everywhere: [String: Int] = [:]
        var everywhereTool: [String: KubeGitOpsObject.Tool] = [:]
    }

    // MARK: Rows

    /// The section's rows: every summary whose row is still listed (a kind
    /// not yet listed keeps its summaries), kept by the scope rule; every
    /// live row without a summary from its cells — shown on All
    /// Namespaces, else "not placed". In display order: state, then the
    /// oldest problem first.
    static func rows(
        summaries: [KubeGitOpsObject], live: [String: KubeRows], listed: Set<String>, scope: KubeScope, now: Date,
        unreadable: Set<KubeGitOpsObject.Key> = []
    ) -> Rows {
        var valid: [KubeGitOpsObject] = []
        var summarisedIDs: Set<String> = []
        for object in summaries {
            if listed.contains(object.resource), live[object.resource]?[object.ref] == nil { continue }
            valid.append(object)
            summarisedIDs.insert(KubeGitOpsRow.id(resource: object.resource, object.ref))
        }
        var peers: KubeGitOpsLadder.Peers = [:]
        for object in valid { peers[object.key] = object }
        var rows = Rows()
        for object in valid {
            let namespace = object.ref.namespace ?? ""
            rows.everywhere[namespace, default: 0] += 1
            if rows.everywhereTool[namespace] == nil || object.role == .application { rows.everywhereTool[namespace] = object.tool }
        }
        rows.shown = KubeGitOpsSummary.kept(valid, scope: scope).map { row($0, peers: peers, unreadable: unreadable.contains($0.key)) }
        for (resource, table) in live {
            for liveRow in table.sorted where !summarisedIDs.contains(KubeGitOpsRow.id(resource: resource, liveRow.id)) {
                guard let made = row(cells: liveRow, columns: table.columns, resource: resource, unreadable: unreadable) else { continue }
                if scope == .all { rows.shown.append(made) } else { rows.notPlaced.append(made) }
            }
        }
        rows.shown.sort(by: ordered)
        rows.notPlaced.sort(by: ordered)
        return rows
    }

    /// State in display order, then the oldest first, then by name.
    static func ordered(_ a: KubeGitOpsRow, _ b: KubeGitOpsRow) -> Bool {
        if a.state != b.state { return a.state < b.state }
        let at = a.since ?? .distantFuture
        let bt = b.since ?? .distantFuture
        if at != bt { return at < bt }
        if a.ref != b.ref { return a.ref < b.ref }
        return a.resource < b.resource
    }

    /// A summary's row.
    static func row(_ object: KubeGitOpsObject, peers: KubeGitOpsLadder.Peers, unreadable: Bool = false) -> KubeGitOpsRow {
        var why = object.why
        if unreadable { why = why.isEmpty ? "couldn't read why" : "\(why) · couldn't read it again" }
        return KubeGitOpsRow(
            id: KubeGitOpsRow.id(resource: object.resource, object.ref), key: object.key, resource: object.resource, ref: object.ref,
            role: object.role, tool: object.tool, state: object.state, why: why, tags: object.tags, into: into(object),
            revision: revision(object), source: source(object, peers: peers), since: object.stateSince ?? object.created, summarised: true,
            hover: hover(object))
    }

    /// A live row with no summary: its state from its cells alone, "…" for why.
    static func row(cells live: KubeRow, columns: [KubeColumn], resource: String, unreadable: Set<KubeGitOpsObject.Key> = []) -> KubeGitOpsRow? {
        guard let (role, tool, kind) = role(resource) else { return nil }
        let key = KubeGitOpsObject.Key(kind: kind, namespace: live.id.namespace, name: live.id.name)
        let (state, said) = cellState(resource: resource, live, columns: columns)
        let refused = unreadable.contains(key)
        var revision = ""
        if let text = live.cell("Revision", in: columns)?.text, !text.isEmpty { revision = KubeGitOpsRevision.shown(text) }
        var source = ""
        if let url = live.cell("URL", in: columns)?.text, !url.isEmpty { source = GitRemoteURL(url)?.path ?? GitRemoteURL.withoutUserinfo(url) }
        return KubeGitOpsRow(
            id: KubeGitOpsRow.id(resource: resource, live.id), key: key, resource: resource, ref: live.id, role: role, tool: tool, state: state,
            why: refused ? "\(said) · couldn't read why" : "\(said) …", revision: revision, source: source, since: live.created, summarised: false,
            hover: refused ? "Its summary couldn't be read (forbidden, or too large): what its row says." : "Not summarised yet: what its row says.")
    }

    /// The kinds the section shows, by full name: role, tool, Kind.
    static func role(_ resource: String) -> (KubeGitOpsObject.Role, KubeGitOpsObject.Tool, String)? {
        switch resource {
        case "applications.argoproj.io": (.application, .argo, "Application")
        case "applicationsets.argoproj.io": (.applicationSet, .argo, "ApplicationSet")
        case "kustomizations.kustomize.toolkit.fluxcd.io": (.kustomization, .flux, "Kustomization")
        case "helmreleases.helm.toolkit.fluxcd.io": (.helmRelease, .flux, "HelmRelease")
        default:
            KubeGitOps.sourceResources.first { $0.value == resource }.map { (.source($0.key), .flux, $0.key) }
        }
    }

    // MARK: Cells

    /// A row's cells as a summary compares them: date columns left out —
    /// the server renders them relative, so they change on every event.
    static func cellsKey(_ row: KubeRow, columns: [KubeColumn]) -> [String] {
        zip(columns, row.cells).compactMap { column, cell in column.type == "date" ? nil : cell.text }
    }

    /// Synced and Healthy (Argo CD), Ready True (Flux): a row whose events
    /// aren't refetched unless a cell changes. A row whose cells say
    /// neither (no columns) counts as healthy: only a cell change tells.
    static func healthy(resource: String, _ row: KubeRow, columns: [KubeColumn]) -> Bool {
        if resource == "applications.argoproj.io" {
            let sync = row.cell("Sync Status", in: columns)?.text ?? ""
            let health = row.cell("Health Status", in: columns)?.text ?? ""
            if sync.isEmpty, health.isEmpty { return true }
            return sync == "Synced" && health == "Healthy"
        }
        guard let ready = row.cell("Ready", in: columns)?.text, !ready.isEmpty else { return true }
        return ready == "True"
    }

    /// A state from the cells alone, said: Degraded Failed, Synced and
    /// Healthy Ready; Flux's Ready True, False or Unknown — never more
    /// than they say (an OutOfSync's auto-sync isn't in them).
    static func cellState(resource: String, _ row: KubeRow, columns: [KubeColumn]) -> (KubeGitOpsState, String) {
        if resource == "applications.argoproj.io" {
            let sync = row.cell("Sync Status", in: columns)?.text ?? ""
            let health = row.cell("Health Status", in: columns)?.text ?? ""
            let said = [sync, health].filter { !$0.isEmpty }.joined(separator: ", ")
            switch (sync, health) {
            case (_, "Degraded"): return (.failed, said)
            case ("Synced", "Healthy"), ("Synced", "Suspended"): return (.ready, said)
            case (_, "Progressing"), (_, "Missing"): return (.progressing, said)
            default: return (.unknown, said.isEmpty ? "no status yet" : said)
            }
        }
        let ready = row.cell("Ready", in: columns)?.text ?? ""
        let status = row.cell("Status", in: columns)?.text ?? ""
        let message = KubeGitOpsMessage.oneLine(KubeGitOpsMessage.scrubbed(status, limit: KubeGitOpsMessage.rowLimit), limit: KubeGitOpsMessage.rowLimit)
        switch ready {
        case "True": return (.ready, message.isEmpty ? "Ready" : message)
        case "False": return (.failed, message.isEmpty ? "not Ready" : message)
        case "Unknown": return (.progressing, message.isEmpty ? "reconciling" : message)
        default: return (.unknown, message.isEmpty ? "no status yet" : message)
        }
    }

    // MARK: Columns

    /// `→ shop` for a destination field, `shop` or `shop +2` for what it
    /// manages, `⇢ server` for another cluster — said, never followed.
    static func into(_ object: KubeGitOpsObject) -> String {
        if let remote = object.remote { return "⇢ \(GitRemoteURL.withoutUserinfo(remote))" }
        if let namespace = object.destination?.namespace { return "→ \(namespace)" }
        let managed = object.managedNamespaces.sorted()
        guard let first = managed.first else { return "" }
        return managed.count > 1 ? "\(first) +\(managed.count - 1)" : first
    }

    /// Argo CD: `live → target` while OutOfSync, else what is live; Flux:
    /// what is applied (a HelmRelease's chart version), a source its artifact.
    static func revision(_ object: KubeGitOpsObject) -> String {
        func said(_ revisions: [String]) -> String {
            let shown = revisions.filter { !$0.isEmpty }.map(KubeGitOpsRevision.shown)
            guard let first = shown.first else { return "" }
            return shown.count > 2 ? "\(first) +\(shown.count - 1)" : shown.joined(separator: ", ")
        }
        switch object.role {
        case .application:
            let live = said(object.revisions.applied)
            let target = said(object.revisions.wanted)
            if object.sync == "OutOfSync", !target.isEmpty, live != target { return live.isEmpty ? "→ \(target)" : "\(live) → \(target)" }
            return live.isEmpty ? target : live
        case .applicationSet: return ""
        case .kustomization: return said(object.revisions.applied)
        case .helmRelease: return object.revisions.helmHistory?.chartVersion ?? object.revisions.attempted.map(KubeGitOpsRevision.shown) ?? ""
        case .source: return object.artifact?.revision.map(KubeGitOpsRevision.shown) ?? ""
        }
    }

    /// Host-less `org/repo path @ref`, `chart@version`, or "3 sources"; a
    /// Flux object's through its source's summary.
    static func source(_ object: KubeGitOpsObject, peers: KubeGitOpsLadder.Peers) -> String {
        func repository(_ url: String) -> String { GitRemoteURL(url)?.path ?? GitRemoteURL.withoutUserinfo(url) }
        switch object.role {
        case .application:
            if object.sources.count > 1 { return "\(object.sources.count) sources" }
            return object.sources.first?.said ?? ""
        case .applicationSet: return ""
        case .kustomization:
            let path = object.sources.first?.path
            guard let reference = object.sourceRef else { return path ?? "" }
            let peer = peers[KubeGitOpsObject.Key(kind: reference.kind, namespace: reference.namespace, name: reference.name)]
            if let url = peer?.sources.first?.repoURL, !url.isEmpty {
                return [repository(url), path, peer?.tracks.map { "@\($0)" }].compactMap { $0 }.joined(separator: " ")
            }
            return [reference.kind.lowercased() + " " + reference.name, path].compactMap { $0 }.joined(separator: " ")
        case .helmRelease:
            if let said = object.sources.first?.said, !said.isEmpty { return said }
            guard let chart = object.chartRef else { return "" }
            let peer = peers[KubeGitOpsObject.Key(kind: chart.kind, namespace: chart.namespace, name: chart.name)]
            if let url = peer?.sources.first?.repoURL, !url.isEmpty { return repository(url) }
            return "\(chart.kind.lowercased()) \(chart.name)"
        case .source(let kind):
            if kind == "HelmChart" {
                let chart = object.sourceRef.map { "from \($0.kind.lowercased()) \($0.name)" }
                return chart ?? ""
            }
            guard let url = object.sources.first?.repoURL, !url.isEmpty else { return "" }
            return [repository(url), object.tracks.map { "@\($0)" }].compactMap { $0 }.joined(separator: " ")
        }
    }

    /// The hover: the why, the last error, its conditions — every message
    /// already through 5.3, the whole at most 4 KB.
    static func hover(_ object: KubeGitOpsObject) -> String {
        var lines = ["\(object.state.word): \(object.why)"]
        if let error = object.lastError, !error.isEmpty, !object.why.contains(error) { lines.append(error) }
        for condition in object.conditions {
            let words = [condition.reason, condition.message].compactMap { $0 }.joined(separator: ": ")
            lines.append("\(condition.type)=\(condition.status)" + (words.isEmpty ? "" : " — \(words)"))
        }
        let text = lines.joined(separator: "\n")
        guard text.utf8.count > KubeGitOpsMessage.hoverLimit else { return text }
        return String(text.prefix(KubeGitOpsMessage.hoverLimit - 1)) + "…"
    }

    // MARK: Chips, filters

    /// The chips in display order, with how many rows each state has.
    static func chips(_ rows: [KubeGitOpsRow]) -> [(state: KubeGitOpsState, count: Int)] {
        var counts: [KubeGitOpsState: Int] = [:]
        for row in rows { counts[row.state, default: 0] += 1 }
        return KubeGitOpsState.allCases.compactMap { state in counts[state].map { (state, $0) } }
    }

    /// A chip's words: `2 failing`, `41 ready`.
    static func chipText(_ state: KubeGitOpsState, _ count: Int) -> String {
        let word =
            switch state {
            case .failed: "failing"
            case .blocked: "blocked"
            case .stuck: "stuck"
            case .drift: "drift"
            case .progressing: "progressing"
            case .paused: "paused"
            case .ready: "ready"
            case .unknown: "unknown"
            }
        return "\(count) \(word)"
    }

    /// What the table shows: a chip's state alone; else Ready hidden when
    /// asked; one tool (`:argo`, `:flux`); the rows "not placed" after the
    /// rest when their chip is on; a text over name, why and source.
    static func visible(
        _ rows: Rows, chip: KubeGitOpsState?, hideReady: Bool, tool: KubeGitOpsObject.Tool?, notPlaced: Bool, text: String
    ) -> [KubeGitOpsRow] {
        var shown = notPlaced ? rows.notPlaced : rows.shown
        if let chip { shown = shown.filter { $0.state == chip } } else if hideReady, !notPlaced { shown = shown.filter { $0.state != .ready } }
        if let tool { shown = shown.filter { $0.tool == tool } }
        let words = text.lowercased().split(separator: " ").map(String.init).filter { !$0.contains(":") }
        if !words.isEmpty {
            shown = shown.filter { row in
                let haystack = "\(row.ref.description) \(row.why) \(row.source) \(row.role.short)".lowercased()
                return words.allSatisfy { haystack.contains($0) }
            }
        }
        return shown
    }

    // MARK: Words

    /// `Argo CD 2 kinds · Flux 6 kinds · summarised 3 min ago`.
    static func header(argo: Int, flux: Int, summarisedAt: Date?, summarising: Bool, now: Date) -> String {
        var parts: [String] = []
        if argo > 0 { parts.append("Argo CD \(argo) kind\(argo == 1 ? "" : "s")") }
        if flux > 0 { parts.append("Flux \(flux) kind\(flux == 1 ? "" : "s")") }
        if summarising {
            parts.append("summarising…")
        } else if let summarisedAt {
            let age = now.timeIntervalSince(summarisedAt)
            parts.append(age < 60 ? "summarised just now" : "summarised \(KubeAge.format(age)) ago")
        }
        return parts.joined(separator: " · ")
    }

    /// The empty scope: where the objects are, never the scope widened
    /// silently — "Show argocd" adds the namespace, as a chip would.
    static func emptyHint(_ rows: Rows, scope: KubeScope) -> (text: String, namespace: String?) {
        let place = scope.names?.joined(separator: ", ") ?? "the cluster"
        let lead = "No GitOps object lives in or deploys into \(place)."
        let elsewhere = rows.everywhere.filter { !scope.includes($0.key) && !$0.key.isEmpty }
        guard let (namespace, _) = elsewhere.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) else { return (lead, nil) }
        let what = rows.everywhereTool[namespace] == .flux ? "Flux's objects are" : "Argo CD's Applications are"
        return ("\(lead) \(what) in \(namespace).", namespace)
    }

    // MARK: k

    /// What `k` copies: flux's or argocd's own `get`, as Overterm always
    /// says it — the context named, the namespace too; nil for a kind
    /// neither CLI names (an ApplicationSet: kubectl's).
    static func cliLine(_ row: KubeGitOpsRow, context: String) -> String? {
        let q = KubeCommands.quoted
        let namespace = row.ref.namespace ?? ""
        if row.role == .application {
            return ["argocd", "app", "get", q(row.ref.name), "--app-namespace", q(namespace), "--core", "--kube-context", q(context)].joined(separator: " ")
        }
        guard let flux = KubeGitOps.fluxKinds[row.resource] else { return nil }
        return (["flux", "get"] + flux.words + [q(row.ref.name), "-n", q(namespace), "--context", q(context)]).joined(separator: " ")
    }
}

/// Which objects are read again, one GET each (R3, gitops.md 3.1): a row
/// added that has no summary; a row whose cells (date columns left out)
/// moved from its summary's; any change of a row that isn't healthy; every
/// 60 s an object summarised in progress. Each object at most once every
/// 15 s; at most 20 taken a flush — Failed, Blocked and Stuck first, the
/// periodic ones last; the rest wait for the next. Pure.
struct KubeGitOpsRefetch: Equatable, Sendable {
    static let perObject: TimeInterval = 15
    static let perFlush = 20
    static let inProgressEvery: TimeInterval = 60

    enum Priority: Int, Comparable, Sendable {
        case problem, other, periodic

        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private(set) var pending: [KubeGitOpsObject.Key: Priority] = [:]
    private(set) var lastAsked: [KubeGitOpsObject.Key: Date] = [:]

    var isEmpty: Bool { pending.isEmpty }

    mutating func ask(_ key: KubeGitOpsObject.Key, _ priority: Priority) {
        pending[key] = min(pending[key] ?? priority, priority)
    }

    /// Up to `limit` keys whose last GET is 15 s behind, problems first.
    mutating func take(now: Date, limit: Int = perFlush) -> [KubeGitOpsObject.Key] {
        let due = pending.filter { key, _ in lastAsked[key].map { now.timeIntervalSince($0) >= Self.perObject } ?? true }
        let taken = due.sorted { $0.value != $1.value ? $0.value < $1.value : $0.key.description < $1.key.description }.prefix(limit).map(\.key)
        for key in taken {
            pending[key] = nil
            lastAsked[key] = now
        }
        return taken
    }

    mutating func forget() {
        pending = [:]
        lastAsked = [:]
    }

    /// Why a change of a live row asks for its object again; nil when it doesn't.
    static func reason(
        added: Bool, resource: String, row: KubeRow, columns: [KubeColumn], summary: KubeGitOpsObject?
    ) -> Priority? {
        let healthy = KubeGitOpsSection.healthy(resource: resource, row, columns: columns)
        let priority: Priority = !healthy || (summary?.state.isProblem ?? false) ? .problem : .other
        guard let summary else { return added ? priority : nil }
        if !summary.cells.isEmpty, summary.cells != KubeGitOpsSection.cellsKey(row, columns: columns) { return priority }
        return healthy ? nil : .problem
    }

    /// Whether an object was summarised in progress (an operation running,
    /// reconciling, Stuck or Progressing) and is due its 60 s look.
    static func inProgress(_ object: KubeGitOpsObject, now: Date) -> Bool {
        guard now.timeIntervalSince(object.readAt) >= inProgressEvery else { return false }
        if object.state == .stuck || object.state == .progressing { return true }
        if object.operation?.phase == "Running" { return true }
        return object.condition("Reconciling")?.isTrue == true
    }
}

/// Argo CD's and Flux's controllers as R1c follows them (gitops.md 3.1,
/// 2.3): a controller not ready tags its tool's rows "may be stale" and
/// shows the banner; it never changes a row's state. Pure.
enum KubeGitOpsControllers {
    /// Flux's own namespace when nothing says otherwise.
    static let fluxNamespace = "flux-system"

    struct Controller: Equatable, Sendable {
        var name: String
        var namespace: String
        var tool: KubeGitOpsObject.Tool
        /// `0/1`, as its Ready cell says.
        var said: String
        var ready: Bool
    }

    /// Whether a workload in a controllers' namespace is one of the tool's
    /// controllers: Argo CD's application controller, repo server,
    /// ApplicationSet controller and server; any Flux `*-controller`.
    static func isController(_ name: String, tool: KubeGitOpsObject.Tool) -> Bool {
        switch tool {
        case .argo:
            ["application-controller", "repo-server", "applicationset-controller", "argocd-server"].contains { name.hasSuffix($0) || name == $0 }
        case .flux: name.hasSuffix("-controller")
        }
    }

    /// The controllers among a namespace's workloads' rows.
    static func controllers(_ rows: KubeRows, kind: String, namespace: String, tool: KubeGitOpsObject.Tool) -> [Controller] {
        rows.sorted.compactMap { row in
            guard isController(row.id.name, tool: tool) else { return nil }
            let ready = KubeWorkloadState.ready(row, columns: rows.columns, kind: kind) ?? true
            let said = row.cell("Ready", in: rows.columns)?.text ?? ""
            return Controller(name: row.id.name, namespace: namespace, tool: tool, said: said, ready: ready)
        }
    }

    /// `kustomize-controller 0/1 ready in flux-system — Flux's states below may be stale`.
    static func banner(_ controllers: [Controller]) -> String? {
        let down = controllers.filter { !$0.ready }
        guard let first = down.first else { return nil }
        let names = down.map { "\($0.name)\($0.said.isEmpty ? "" : " \($0.said)")" }.joined(separator: ", ")
        let tools = Set(down.map(\.tool))
        let whose = tools.count > 1 ? "Argo CD's and Flux's" : first.tool == .argo ? "Argo CD's" : "Flux's"
        return "\(names) ready in \(Set(down.map(\.namespace)).sorted().joined(separator: ", ")) — \(whose) states below may be stale"
    }

    /// The tools whose controllers aren't all ready.
    static func stale(_ controllers: [Controller]) -> Set<KubeGitOpsObject.Tool> { Set(controllers.filter { !$0.ready }.map(\.tool)) }

    /// Argo CD's namespace: the one most Applications live in, else `argocd`.
    static func argoNamespace(applications: [String?]) -> String {
        var counts: [String: Int] = [:]
        for namespace in applications.compactMap({ $0 }) { counts[namespace, default: 0] += 1 }
        return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? KubeGitOps.argoDefaultNamespace
    }
}
