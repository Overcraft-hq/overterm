import Foundation

/// How the GitOps section is looked at: its selection and order, the chip
/// pressed, Hide Ready, one tool (`:argo`, `:flux`), the rows "not placed",
/// the grouping (`G`) and the groups folded.
/// A window's, in memory.
struct KubeGitOpsViewState: Equatable {
    var selection: Set<String> = []
    var sort: ResourceSort?
    /// A chip pressed: its state alone; pressed again, none.
    var chip: KubeGitOpsState?
    /// Nil: on above 50 rows (decision 10).
    var hideReady: Bool?
    var tool: KubeGitOpsObject.Tool?
    /// "N not placed" pressed: those rows instead.
    var notPlaced = false
    /// Beside Applications read: "N marked apps with no Application here"
    /// pressed — those apps' rows instead (gitops.md 14.2.1).
    var beside = false
    /// `G`: what the rows are grouped by (2.8), kept for the page.
    var groupBy: KubeGitOpsGroupBy = .none
    /// The groups folded, by id.
    var folded: Set<String> = []
}

/// An app read from marks whose placeholder detail shows beside the
/// GitOps section (gitops.md 14.2.3): its context and its key.
struct KubeMarkedDetailRef: Equatable, Sendable {
    var context: String
    var key: KubeTrackingID.AppKey
}

/// The GitOps section (`g`; docs/design/kubernetes/gitops.md, 2): Argo CD's
/// and Flux's objects that live in or deploy into the scope, on one
/// screen, read while it shows on a page on screen (`KubeGitOpsSession`).
/// It summarises; it is no kind list: ↩ opens the object in its own
/// kind's list with the detail open, so `x`, the YAML and every verb are
/// the ones there. `r`, `p`, `s` and ⌫ act on the row picked through the
/// page's one guard path (`writeTarget`); `k` copies flux's or argocd's
/// own `get`, ⇧K kubectl's. Where no Application here deploys them, Argo
/// CD's apps are read from the marks on their objects (14): such a row has
/// no object of its own — ↩ opens its placeholder detail beside the
/// section, `k` copies argocd's `get` against the person's own server, and
/// every write key and ⇧K do nothing (no ref, so `writeTarget` is nil).
extension KubernetesPageModel {
    /// Whether the section is on screen.
    var gitOpsShows: Bool { section == .gitops && visible && windowVisible }

    /// Whether the context shown serves Argo CD's Applications or any Flux kind.
    var gitOpsServed: Bool { KubeGitOpsSummary.served(model.discovery) }

    /// Whether the GitOps row shows among the sections: where Argo CD or
    /// Flux is served, where the context's rows have shown one of Argo
    /// CD's marks (`KubernetesModel.marksSeen`, no request of its own), or
    /// while the section shows (14.2.1). `g` opens it everywhere.
    var gitOpsListed: Bool {
        gitOpsServed || section == .gitops || model.selectedName.map { model.marksSeen.contains($0) } == true
    }

    /// Shown: read (the summaries kept five minutes on the page); another
    /// section: its follows end, the summaries stay; the page or its window
    /// hidden: everything goes.
    func updateGitOpsReading() {
        guard visible, windowVisible, model.enabled else {
            closeMarkedApp()
            return gitOps.drop()
        }
        guard section == .gitops, let context = model.selectedName else {
            closeMarkedApp()
            // Another context while another section shows: the summaries are
            // that context's no longer (gitops.md 3.1) — dropped, not kept.
            if let store = gitOps.store, store.context != model.selectedName { return gitOps.drop() }
            return gitOps.hide()
        }
        // One detail at a time: the kind's under the section goes; an app
        // of another context's, too.
        if detail != nil { closeDetail() }
        if let marked = markedDetail, marked.context != context { closeMarkedApp() }
        gitOps.show(
            context: context, scope: model.scope, discovery: model.discovery, client: model.client(for: context),
            accessible: model.selected?.settings.accessibleNamespaces ?? [])
    }

    /// Refresh: every kind summarised again.
    func refreshGitOps() {
        if gitOpsShows { gitOps.refresh() }
    }

    /// `:flux` on a context that serves no Flux kind: said, the section not
    /// shown. `g`, `:gitops` and `:argo` always open it — where Argo CD
    /// isn't served, its apps are read from the marks on their objects, and
    /// the section says what it found (14.2.1).
    static func gitOpsRefusal(tool: KubeGitOpsObject.Tool?, discovery: KubeDiscovery?, context: String?) -> String? {
        guard tool == .flux, let discovery, KubeGitOpsSummary.tools(discovery).flux == 0 else { return nil }
        return "Flux isn't served by \(context ?? "this context")."
    }

    // MARK: The rows

    /// What the table shows now: the chip, Hide Ready, the tool, the filter's words.
    var gitOpsVisibleRows: [KubeGitOpsRow] {
        let view = gitOpsView
        let rows = gitOps.rows
        var shown = KubeGitOpsSection.visible(
            rows, chip: view.chip, hideReady: gitOpsHidesReady, tool: view.tool, notPlaced: view.notPlaced, beside: view.beside && !rows.beside.isEmpty,
            text: filter)
        if let sort = view.sort { shown = sort.sorted(shown) { Self.gitOpsSortKey($0, sort.column) } }
        return shown
    }

    /// The table's rows: the visible ones (`gitOpsVisibleRows`, computed
    /// once by the caller — it filters and sorts every row), grouped as `G`
    /// says — each group's own row, then its members unless folded.
    func gitOpsListRows(_ shown: [KubeGitOpsRow]) -> [KubeGitOpsListRow] {
        guard gitOpsView.groupBy != .none else { return shown.map { .object($0) } }
        return KubeGitOpsGrouping.rows(gitOpsGroups(shown), folded: gitOpsView.folded)
    }

    /// The visible rows' groups, as `G` says; none when not grouped.
    func gitOpsGroups(_ shown: [KubeGitOpsRow]? = nil) -> [KubeGitOpsGroup] {
        KubeGitOpsGrouping.groups(shown ?? gitOpsVisibleRows, by: gitOpsView.groupBy, all: gitOps.rows.shown + gitOps.rows.notPlaced)
    }

    /// Whether more than one Argo CD installation marks the objects the
    /// section's apps are read from: `G` then offers the installation.
    var gitOpsInstallations: Bool {
        Set(gitOps.rows.shown.compactMap { $0.marked.map { $0.installation ?? "" } }).count > 1
    }

    /// `G`: the next grouping, the folds forgotten (another grouping's ids).
    func cycleGitOpsGrouping() {
        gitOpsView.groupBy = gitOpsView.groupBy.next(installations: gitOpsInstallations)
        gitOpsView.folded = []
        gitOpsView.selection = gitOpsView.selection.filter { !KubeGitOpsGrouping.isGroup($0) }
    }

    /// A grouping picked from the section's menu.
    func groupGitOps(by groupBy: KubeGitOpsGroupBy) {
        guard groupBy != gitOpsView.groupBy else { return }
        gitOpsView.groupBy = groupBy
        gitOpsView.folded = []
        gitOpsView.selection = gitOpsView.selection.filter { !KubeGitOpsGrouping.isGroup($0) }
    }

    /// A group folded, or unfolded.
    func toggleGitOpsGroup(_ id: String) {
        if gitOpsView.folded.contains(id) { gitOpsView.folded.remove(id) } else { gitOpsView.folded.insert(id) }
    }

    /// The filter's words this section couldn't read, said beside the chips.
    var gitOpsFilterRefusal: String? { KubeGitOpsFilter(filter).refusal }

    /// Hide Ready: as set, else on above 50 rows.
    var gitOpsHidesReady: Bool { gitOpsView.hideReady ?? (gitOps.rows.shown.count > KubeGitOpsSection.hideReadyAbove) }

    static func gitOpsSortKey(_ row: KubeGitOpsRow, _ column: String) -> String? {
        switch column {
        case "state": String(format: "%02d", row.state.rawValue)
        case "kind": row.role.short
        case "name": row.ref.description
        case "into": row.into
        case "why": row.why
        case "revision": row.revision
        case "source": row.source
        case "age": row.since.map { String(format: "%020.0f", $0.timeIntervalSince1970) }
        default: nil
        }
    }

    /// A chip pressed: its state alone, or none when it was.
    func pressGitOpsChip(_ state: KubeGitOpsState) {
        gitOpsView.notPlaced = false
        gitOpsView.beside = false
        gitOpsView.chip = gitOpsView.chip == state ? nil : state
    }

    /// The rows the summaries didn't place, or back.
    func toggleGitOpsNotPlaced() {
        gitOpsView.chip = nil
        gitOpsView.beside = false
        gitOpsView.notPlaced.toggle()
    }

    /// Beside Applications read: the marked apps with no Application here
    /// alone, or every row again (14.2.1).
    func toggleGitOpsBeside() {
        gitOpsView.chip = nil
        gitOpsView.notPlaced = false
        gitOpsView.beside.toggle()
    }

    /// The empty scope's button: the namespace the objects are in, added — never silently.
    func showGitOpsNamespace(_ namespace: String) {
        let names = (model.scope.names ?? []) + [namespace]
        model.setScope(.of(names))
    }

    /// Every row the section holds: shown (the marked apps beside
    /// Applications among them), not placed.
    var gitOpsAllRows: [KubeGitOpsRow] { gitOps.rows.shown + gitOps.rows.notPlaced }

    /// The one row picked.
    var gitOpsPicked: KubeGitOpsRow? {
        let view = gitOpsView
        guard view.selection.count == 1, let id = view.selection.first else { return nil }
        return gitOpsAllRows.first { $0.id == id }
    }

    /// The object a row is, as the context shown serves its kind.
    /// None while the rows are another context's than the one shown (the
    /// session hears of a switch a moment later): a write never pairs one
    /// cluster's object with another's name. None for an app read from
    /// marks: it has no object of its own, so nothing writes to it.
    func gitOpsRef(_ row: KubeGitOpsRow) -> KubeObjectRef? {
        guard !row.isMarked, let context = gitOps.context, context == model.selectedName,
            let discovery = model.knownDiscovery(of: context) ?? model.discovery, let kind = discovery.kinds.first(where: { $0.fullName == row.resource })
        else { return nil }
        return KubeObjectRef(context: context, kind: kind, namespace: row.ref.namespace, name: row.ref.name)
    }

    /// What a write key acts on in the section: the one row picked.
    var gitOpsSelectedRef: KubeObjectRef? { gitOpsPicked.flatMap(gitOpsRef) }

    /// ↩: the object in its kind's list, its detail open; `[` comes back
    /// here. An app read from marks: its placeholder detail beside the
    /// section — there is no kind list to open it in.
    @discardableResult
    func openGitOps(_ row: KubeGitOpsRow) -> Bool {
        if let marked = row.marked {
            guard let context = gitOps.context, context == model.selectedName else { return false }
            openMarkedApp(KubeMarkedDetailRef(context: context, key: marked.key))
            return true
        }
        guard model.catalog.kind(fullName: row.resource) != nil else {
            commandProblem = "\(model.selectedName ?? "The context") doesn't list \(row.resource) as a kind kept live."
            return false
        }
        openFromOverview(kind: row.resource, row.ref, from: .gitops)
        return true
    }

    /// An app read from marks, its placeholder detail shown beside the
    /// section; another detail closed first — one at a time.
    func openMarkedApp(_ ref: KubeMarkedDetailRef) {
        if detail != nil { closeDetail() }
        commandProblem = nil
        if markedDetail != ref { markedDetail = ref }
    }

    /// The placeholder detail closed. Esc or its × give the section's
    /// table the keyboard (`giveListTheKeyboard`); the page or the section
    /// going takes nothing from whoever has it.
    func closeMarkedApp() {
        guard markedDetail != nil else { return }
        markedDetail = nil
    }

    /// The app the placeholder detail shows, as the section ranks it now;
    /// nil when it is no longer read (gone, another mode).
    var markedDetailApp: KubeMarkedRanked? {
        guard let ref = markedDetail, gitOps.context == ref.context else { return nil }
        return gitOps.marked.apps.first { $0.app.key == ref.key }
    }

    // MARK: Keys

    /// A key while the section shows: ↩ opens (a group's row folds), `x`
    /// its tree, `k` and ⇧K copy, `G` groups the rows another way, `s`
    /// syncs (Argo CD) or reconciles with its source (Flux) in a tab; `r`, `p` and ⌫ go on to the page's writes on the row picked
    /// (`writeTarget`), `a` to Ask Why on it (`askWhyRef`); the page's own
    /// keys as ever. A pod's verbs would
    /// act on the kind under the section: refused. Nil: the page's to
    /// decide, the arrows the table's.
    func gitOpsPress(_ characters: String) -> Bool? {
        if cheatSheet { return nil }
        if characters == "K" {
            guard let ref = gitOpsSelectedRef else { return false }
            actions?.copy(KubectlLine.object(ref, discovery: model.knownDiscovery(of: ref.context)))
            return true
        }
        guard case .key(let key) = KubernetesKey.press(characters, sheetShowing: cheatSheet) else { return nil }
        switch key {
        case .close:
            // Esc: an app's placeholder detail goes; the table keeps the keyboard.
            guard markedDetail != nil else { return false }
            closeMarkedApp()
            giveListTheKeyboard()
            return true
        case .open:
            // A group's row: folded, or unfolded.
            if gitOpsView.selection.count == 1, let id = gitOpsView.selection.first, KubeGitOpsGrouping.isGroup(id) {
                toggleGitOpsGroup(id)
                return true
            }
            guard let row = gitOpsPicked else { return false }
            return openGitOps(row)
        case .groupBy:
            cycleGitOpsGrouping()
            return true
        case .tree:
            guard let row = gitOpsPicked, openGitOps(row) else { return false }
            // An app read from marks: its detail is where its objects are (14.7).
            if row.isMarked { return true }
            return openTree()
        case .copyKubectl:
            guard let row = gitOpsPicked, let context = model.selectedName else { return false }
            if let line = KubeGitOpsSection.cliLine(row, context: context) {
                actions?.copy(line)
            } else if let ref = gitOpsRef(row) {
                actions?.copy(KubectlLine.object(ref, discovery: model.knownDiscovery(of: ref.context)))
            }
            return true
        case .trigger:
            guard let ref = gitOpsSelectedRef else { return false }
            if KubeTabWrite.offered(.argoSync, on: ref.kind) {
                runTabWrite(.argoSync, on: ref)
            } else if KubeTabWrite.offered(.fluxReconcile, on: ref.kind) {
                runTabWrite(.fluxReconcile, on: ref)
            } else {
                return false
            }
            return true
        case .restart, .pause, .delete, .askWhy, .command, .namespace, .context, .allNamespaces: return nil
        default: return false
        }
    }

    // MARK: Verbs

    /// A row's right-click menu, made as it opens: Open, the detail's own
    /// verbs (the writes, each with its guard; Delete with G0b's), then
    /// Copy as kubectl and flux's or argocd's line. Several rows: Open and
    /// Copy only — no write on several. An app read from marks: Open, Copy
    /// as argocd (against the person's own Argo CD server) and Copy Name —
    /// never a write, nor a verb that needs the Application (14.2.3).
    func gitOpsVerbs(for ids: Set<String>) -> [ResourceVerb] {
        let picked = gitOpsAllRows.filter { ids.contains($0.id) }
        guard let first = picked.first else {
            // A group's row: fold it, or unfold it.
            guard ids.count == 1, let id = ids.first, KubeGitOpsGrouping.isGroup(id) else { return [] }
            let folded = gitOpsView.folded.contains(id)
            return [
                ResourceVerb(title: folded ? "Unfold" : "Fold", symbol: folded ? "chevron.down" : "chevron.right", place: .button, key: KubernetesKey.open.key) {
                    [weak self] in self?.toggleGitOpsGroup(id)
                }
            ]
        }
        let open = ResourceVerb(title: "Open", symbol: "arrow.up.right", place: .button, key: KubernetesKey.open.key) { [weak self] in
            self?.openGitOps(first)
        }
        let names = ResourceVerb(title: picked.count == 1 ? "Copy Name" : "Copy Names", symbol: "doc.on.doc", group: 9) { [weak self] in
            self?.actions?.copy(picked.map(\.ref.description).joined(separator: "\n"))
        }
        if picked.count == 1, first.isMarked, let line = KubeMarkedSection.cliLine(first) {
            let argocd = ResourceVerb(title: "Copy as argocd (against your Argo CD server)", symbol: "terminal", key: KubernetesKey.copyKubectl.key, group: 9) {
                [weak self] in self?.actions?.copy(line)
            }
            return [open, argocd, names]
        }
        guard picked.count == 1, let ref = gitOpsRef(first) else { return [open, names] }
        var verbs = [open] + detailVerbs(for: ref)
        verbs.append(
            ResourceVerb(title: "Copy as kubectl", symbol: "terminal", group: 9) { [weak self] in
                guard let self else { return }
                self.actions?.copy(KubectlLine.object(ref, discovery: self.model.knownDiscovery(of: ref.context)))
            })
        if let line = KubeGitOpsSection.cliLine(first, context: ref.context) {
            verbs.append(
                ResourceVerb(title: first.tool == .argo ? "Copy as argocd" : "Copy as flux", symbol: "terminal", key: KubernetesKey.copyKubectl.key, group: 9) {
                    [weak self] in self?.actions?.copy(line)
                })
        }
        return verbs + [names]
    }

    /// The palette's items while the section shows: each row shown, by its name.
    func gitOpsPaletteItems(_ show: @escaping @MainActor () -> Void) -> [PaletteItem] {
        guard section == .gitops, let context = model.selectedName else { return [] }
        return gitOps.rows.shown.map { row in
            PaletteItem(
                id: row.isMarked ? "k.g.\(row.id)" : "k.g.\(row.key.kind).\(row.ref.namespace ?? "").\(row.ref.name)", group: .kubernetes, title: row.ref.name,
                subtitle: [row.isMarked ? "Argo CD app from marks" : row.key.kind, row.marked?.word ?? row.state.word, row.ref.namespace, context]
                    .compactMap { $0 }.joined(separator: " · "),
                symbol: row.state.isProblem ? "exclamationmark.triangle" : "arrow.triangle.branch"
            ) { [weak self] _, _ in
                show()
                self?.openGitOps(row)
            }
        }
    }
}
