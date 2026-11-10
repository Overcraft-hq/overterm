import Foundation

/// How the GitOps section is looked at: its selection and order, the chip
/// pressed, Hide Ready, one tool (`:argo`, `:flux`), the rows "not placed".
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
}

/// The GitOps section (`g`; docs/design/kubernetes/gitops.md, 2): Argo CD's
/// and Flux's objects that live in or deploy into the scope, on one
/// screen, read while it shows on a page on screen (`KubeGitOpsSession`).
/// It summarises; it is no kind list: ↩ opens the object in its own
/// kind's list with the detail open, so `x`, the YAML and every verb are
/// the ones there. `r`, `p`, `s` and ⌫ act on the row picked through the
/// page's one guard path (`writeTarget`); `k` copies flux's or argocd's
/// own `get`, ⇧K kubectl's.
extension KubernetesPageModel {
    /// Whether the section is on screen.
    var gitOpsShows: Bool { section == .gitops && visible && windowVisible }

    /// Whether the context shown serves Argo CD's Applications or any Flux kind.
    var gitOpsServed: Bool { KubeGitOpsSummary.served(model.discovery) }

    /// Shown: read (the summaries kept five minutes on the page); another
    /// section: its follows end, the summaries stay; the page or its window
    /// hidden: everything goes.
    func updateGitOpsReading() {
        guard visible, windowVisible, model.enabled else { return gitOps.drop() }
        guard section == .gitops, let context = model.selectedName else {
            // Another context while another section shows: the summaries are
            // that context's no longer (gitops.md 3.1) — dropped, not kept.
            if let store = gitOps.store, store.context != model.selectedName { return gitOps.drop() }
            return gitOps.hide()
        }
        // One detail at a time: the kind's under the section goes.
        if detail != nil { closeDetail() }
        gitOps.show(
            context: context, scope: model.scope, discovery: model.discovery, client: model.client(for: context),
            accessible: model.selected?.settings.accessibleNamespaces ?? [])
    }

    /// Refresh: every kind summarised again.
    func refreshGitOps() {
        if gitOpsShows { gitOps.refresh() }
    }

    /// `g` on a context that serves neither: said, the section not shown.
    func gitOpsRefusal() -> String? {
        guard let discovery = model.discovery, !KubeGitOpsSummary.served(discovery) else { return nil }
        return "Neither Argo CD nor Flux is served by \(model.selectedName ?? "this context")."
    }

    // MARK: The rows

    /// What the table shows now: the chip, Hide Ready, the tool, the filter's words.
    var gitOpsVisibleRows: [KubeGitOpsRow] {
        let view = gitOpsView
        let rows = gitOps.rows
        var shown = KubeGitOpsSection.visible(
            rows, chip: view.chip, hideReady: gitOpsHidesReady, tool: view.tool, notPlaced: view.notPlaced, text: filter)
        if let sort = view.sort { shown = sort.sorted(shown) { Self.gitOpsSortKey($0, sort.column) } }
        return shown
    }

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
        gitOpsView.chip = gitOpsView.chip == state ? nil : state
    }

    /// The rows the summaries didn't place, or back.
    func toggleGitOpsNotPlaced() {
        gitOpsView.chip = nil
        gitOpsView.notPlaced.toggle()
    }

    /// The empty scope's button: the namespace the objects are in, added — never silently.
    func showGitOpsNamespace(_ namespace: String) {
        let names = (model.scope.names ?? []) + [namespace]
        model.setScope(.of(names))
    }

    /// The one row picked.
    var gitOpsPicked: KubeGitOpsRow? {
        let view = gitOpsView
        guard view.selection.count == 1, let id = view.selection.first else { return nil }
        return (gitOps.rows.shown + gitOps.rows.notPlaced).first { $0.id == id }
    }

    /// The object a row is, as the context shown serves its kind.
    /// None while the rows are another context's than the one shown (the
    /// session hears of a switch a moment later): a write never pairs one
    /// cluster's object with another's name.
    func gitOpsRef(_ row: KubeGitOpsRow) -> KubeObjectRef? {
        guard let context = gitOps.context, context == model.selectedName, let discovery = model.knownDiscovery(of: context) ?? model.discovery,
            let kind = discovery.kinds.first(where: { $0.fullName == row.resource })
        else { return nil }
        return KubeObjectRef(context: context, kind: kind, namespace: row.ref.namespace, name: row.ref.name)
    }

    /// What a write key acts on in the section: the one row picked.
    var gitOpsSelectedRef: KubeObjectRef? { gitOpsPicked.flatMap(gitOpsRef) }

    /// ↩: the object in its kind's list, its detail open; `[` comes back here.
    @discardableResult
    func openGitOps(_ row: KubeGitOpsRow) -> Bool {
        guard model.catalog.kind(fullName: row.resource) != nil else {
            commandProblem = "\(model.selectedName ?? "The context") doesn't list \(row.resource) as a kind kept live."
            return false
        }
        openFromOverview(kind: row.resource, row.ref, from: .gitops)
        return true
    }

    // MARK: Keys

    /// A key while the section shows: ↩ opens, `x` its tree, `k` and ⇧K
    /// copy, `s` syncs (Argo CD) or reconciles with its source (Flux) in a
    /// tab; `r`, `p` and ⌫ go on to the page's writes on the row picked
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
        case .open:
            guard let row = gitOpsPicked else { return false }
            return openGitOps(row)
        case .tree:
            guard let row = gitOpsPicked, openGitOps(row) else { return false }
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
    /// Copy only — no write on several.
    func gitOpsVerbs(for ids: Set<String>) -> [ResourceVerb] {
        let all = gitOps.rows.shown + gitOps.rows.notPlaced
        let picked = all.filter { ids.contains($0.id) }
        guard let first = picked.first else { return [] }
        let open = ResourceVerb(title: "Open", symbol: "arrow.up.right", place: .button, key: KubernetesKey.open.key) { [weak self] in
            self?.openGitOps(first)
        }
        let names = ResourceVerb(title: picked.count == 1 ? "Copy Name" : "Copy Names", symbol: "doc.on.doc", group: 9) { [weak self] in
            self?.actions?.copy(picked.map(\.ref.description).joined(separator: "\n"))
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
                id: "k.g.\(row.key.kind).\(row.ref.namespace ?? "").\(row.ref.name)", group: .kubernetes, title: row.ref.name,
                subtitle: [row.key.kind, row.state.word, row.ref.namespace, context].compactMap { $0 }.joined(separator: " · "),
                symbol: row.state.isProblem ? "exclamationmark.triangle" : "arrow.triangle.branch"
            ) { [weak self] _, _ in
                show()
                self?.openGitOps(row)
            }
        }
    }
}
