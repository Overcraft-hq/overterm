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

/// An app read from marks whose detail shows beside the GitOps section
/// (gitops.md 14.2.3): its context and its key.
struct KubeMarkedDetailRef: Equatable, Sendable {
    var context: String
    var key: KubeTrackingID.AppKey
}

/// An object opened from an app's detail (gitops.md 14.2.3): the app `[`
/// comes back to, the object, and what a write on it adds — Argo CD may
/// undo it, whether it does being the Application's, in the mode's words —
/// only on one of the app's own (`Node.mayBeUndone`): a pod, a ReplicaSet,
/// a CronJob's Job, a hook or a copy of a mark adds nothing.
struct KubeMarkedOrigin: Equatable {
    var app: KubeMarkedDetailRef
    var object: KubeObjectRef
    var undone: String?
    /// The tree's node the keyboard opened it from: the keyboard is on it
    /// again after `[`.
    var node: String?
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
/// no object of its own — ↩ opens its detail beside the section (its
/// objects as Argo CD would draw them, each opening in its own list: Tab
/// into its tree, ↑ ↓ along it, ↩ on a node), `k` copies argocd's `get`
/// against the person's own server, and every write key and ⇧K do nothing
/// (no ref, so `writeTarget` is nil).
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
            markedRead.drop()
            return gitOps.drop()
        }
        guard section == .gitops, let context = model.selectedName else {
            closeMarkedApp()
            // Another context while another section shows: the summaries are
            // that context's no longer (gitops.md 3.1) — dropped, not kept.
            if let store = gitOps.store, store.context != model.selectedName {
                markedRead.drop()
                return gitOps.drop()
            }
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

    /// Refresh: every kind summarised again; an app's detail read again.
    func refreshGitOps() {
        guard gitOpsShows else { return }
        gitOps.refresh()
        updateMarkedDetailReading(again: true)
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
    /// here. An app read from marks: its detail beside the section — there
    /// is no kind list to open it in.
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

    /// An app read from marks, its detail shown beside the section and its
    /// objects read (M4); another detail closed first — one at a time.
    /// Another app's: the keyboard leaves the tree of the one before.
    func openMarkedApp(_ ref: KubeMarkedDetailRef) {
        if detail != nil { closeDetail() }
        commandProblem = nil
        if markedDetail != ref {
            if markedNode != nil { markedNode = nil }
            markedDetail = ref
        }
        updateMarkedDetailReading()
    }

    /// The detail closed: its reads stop, the keyboard leaves its tree. Esc
    /// or its × give the section's table the keyboard
    /// (`giveListTheKeyboard`); the page or the section going takes
    /// nothing from whoever has it.
    func closeMarkedApp() {
        markedRead.hide()
        if markedNode != nil { markedNode = nil }
        guard markedDetail != nil else { return }
        markedDetail = nil
    }

    /// What the detail shows read (M4): its members' objects and what is
    /// under its workloads, while it shows on a page on screen — again when
    /// its members change, or on Refresh (`again`).
    func updateMarkedDetailReading(again: Bool = false) {
        guard let ref = markedDetail, gitOpsShows, let ranked = markedDetailApp else {
            if markedDetail == nil || !gitOpsShows { markedRead.hide() }
            return
        }
        if markedRead.ref.map({ $0.context != ref.context }) == true { markedRead.drop() }
        markedRead.show(
            ref, app: ranked.app, discovery: model.knownDiscovery(of: ref.context) ?? model.discovery, client: model.client(for: ref.context),
            store: gitOps.marked.store?.settled ?? [:], again: again)
    }

    /// The detail as it reads now: the app as the section ranks it, its
    /// objects as the detail read them — or as the section read them
    /// since (its M2 after a rollout began, its tick), whichever is newer.
    var markedDetailShown: KubeMarkedAppDetail.Detail? {
        guard let ranked = markedDetailApp, let ref = markedDetail else { return nil }
        var read = markedRead.ref == ref ? markedRead.read : KubeMarkedAppDetail.Read()
        if let store = gitOps.marked.store?.settled {
            for (id, kept) in read.objects {
                if let newer = store[id], newer.at > kept.at { read.objects[id] = newer }
            }
        }
        return KubeMarkedAppDetail.make(ranked, read: read, mode: gitOps.marksMode, context: ref.context)
    }

    /// A node of the detail's tree pressed (↩ on it, or its name): its
    /// object in its own kind's list, its detail open — the verbs it has
    /// there; `[` comes back to the app's detail (the keyboard on the node
    /// again when it opened it: `keyboard`). A write's confirmation says
    /// Argo CD may undo it only on one of the app's own objects
    /// (`Node.mayBeUndone`, 14.2.3: the detail knows it is a member) —
    /// never a pod, a ReplicaSet, a CronJob's Job, a hook or a copy of a
    /// mark. Nothing for a kind the context doesn't serve.
    @discardableResult
    func openMarkedNode(_ node: KubeMarkedAppDetail.Node, keyboard: Bool = false) -> Bool {
        guard let app = markedDetail, app.context == model.selectedName, let discovery = model.knownDiscovery(of: app.context) ?? model.discovery,
            let ref = node.link.resolve(in: discovery, context: app.context)
        else {
            commandProblem = "\(model.selectedName ?? "The context") serves no \(node.kind)."
            return false
        }
        guard model.catalog.kind(fullName: ref.kind.fullName) != nil || ref.kind.fullName == KubeResourceKind.pods.fullName else {
            commandProblem = "\(app.context) doesn't list \(ref.kind.fullName) as a kind kept live."
            return false
        }
        let probable = markedDetailApp?.app.mark == .appInstance
        let undone = node.mayBeUndone ? KubeMarkedAppDetail.undone(gitOps.marksMode, probable: probable) : nil
        openFromOverview(kind: ref.kind.fullName, KubeRowID(namespace: ref.namespace, name: ref.name), from: .gitops)
        guard let opened = detail?.ref, Self.sameObject(opened, ref) else { return false }
        markedOrigin = KubeMarkedOrigin(app: app, object: opened, undone: undone, node: keyboard ? node.id : nil)
        return true
    }

    /// The same object, whichever version of its kind each names.
    static func sameObject(_ a: KubeObjectRef, _ b: KubeObjectRef) -> Bool {
        a.context == b.context && a.kind.fullName == b.kind.fullName && a.namespace == b.namespace && a.name == b.name
    }

    /// A node's right-click menu: Open, Copy as kubectl, Copy Name — never
    /// a write (its own list has those) nor a verb that needs the
    /// Application.
    func markedNodeVerbs(_ node: KubeMarkedAppDetail.Node) -> [ResourceVerb] {
        guard let app = markedDetail, let discovery = model.knownDiscovery(of: app.context) ?? model.discovery,
            let ref = node.link.resolve(in: discovery, context: app.context)
        else {
            return [ResourceVerb(title: "Open", symbol: "arrow.up.right", place: .button, unavailable: "\(markedDetail?.context ?? "The context") serves no \(node.kind).")]
        }
        let name = "\(node.namespace.map { "\($0)/" } ?? "")\(node.name)"
        return [
            ResourceVerb(title: "Open", symbol: "arrow.up.right", place: .button, key: KubernetesKey.open.key) { [weak self] in self?.openMarkedNode(node) },
            ResourceVerb(title: "Copy as kubectl", symbol: "terminal", group: 9) { [weak self] in
                guard let self else { return }
                self.actions?.copy(KubectlLine.object(ref, discovery: self.model.knownDiscovery(of: ref.context)))
            },
            ResourceVerb(title: "Copy Name", symbol: "doc.on.doc", group: 9) { [weak self] in self?.actions?.copy(name) },
        ]
    }

    /// Copy Names: each of the app's objects, one a line.
    func copyMarkedNames() {
        guard let ranked = markedDetailApp else { return }
        actions?.copy(KubeMarkedAppDetail.names(ranked.app))
    }

    /// What a write's confirmation adds on one of an app's own objects
    /// opened from its detail: Argo CD may undo it (14.2.3) — said, never a
    /// guard; nothing on anything else opened from there.
    func markedUndone(_ verb: KubeWriteVerb, on ref: KubeObjectRef) -> String? {
        guard let origin = markedOrigin, Self.sameObject(origin.object, ref), KubeMarkedAppDetail.undoneVerbs.contains(verb) else { return nil }
        return origin.undone
    }

    // MARK: The tree, from the keyboard

    /// The nodes of the detail shown, as the keyboard walks them: the tree
    /// depth first, then the hooks.
    var markedNodes: [KubeMarkedAppDetail.Node] { markedDetailShown.map(KubeMarkedAppDetail.walk) ?? [] }

    /// A key while an app's detail shows (14.2.3, ↩ on a node): Tab (⇧Tab)
    /// into its tree — on its first node — and back out to the section's
    /// rows; on a node, ↑ ↓ along the tree and ↩ opens its object in its
    /// own list. Nil: not the tree's — the arrows the rows', ↩ the row's,
    /// Esc closes the detail as ever.
    func markedTreePress(_ characters: String) -> Bool? {
        guard markedDetail != nil else { return nil }
        switch characters {
        case "\t", "\u{19}":
            if markedNode != nil {
                markedNode = nil
                return true
            }
            guard let first = KubeMarkedAppDetail.step(markedNodes, from: nil, by: 0) else { return false }
            markedNode = first
            return true
        case "\u{F700}", "\u{F701}":
            guard markedNode != nil else { return nil }
            // Its tree not drawn yet (shown again, its app still being made): the keyboard stays where it is.
            guard let next = KubeMarkedAppDetail.step(markedNodes, from: markedNode, by: characters == "\u{F701}" ? 1 : -1) else { return true }
            if next != markedNode { markedNode = next }
            return true
        case "\r":
            guard let id = markedNode else { return nil }
            // Gone since (read again): nothing opens, the keyboard stays.
            guard let node = markedNodes.first(where: { $0.id == id }) else { return true }
            openMarkedNode(node, keyboard: true)
            return true
        default:
            return nil
        }
    }

    /// The app the detail shows, as the section ranks it now;
    /// nil when the section no longer shows it as an app read from marks —
    /// its marks gone, another mode, or, beside Applications, its
    /// Application read here now (the marks' apps hold every marked app
    /// then, those with an Application too: only the section's rows say
    /// which are derived).
    var markedDetailApp: KubeMarkedRanked? {
        guard let ref = markedDetail, gitOps.context == ref.context, gitOps.rows.shown.contains(where: { $0.marked?.key == ref.key }) else { return nil }
        return gitOps.marked.apps.first { $0.app.key == ref.key }
    }

    // MARK: Keys

    /// A key while the section shows: ↩ opens (a group's row folds), `x`
    /// its tree, `k` and ⇧K copy, `G` groups the rows another way, `s`
    /// syncs (Argo CD) or reconciles with its source (Flux) in a tab; `r`, `p` and ⌫ go on to the page's writes on the row picked
    /// (`writeTarget`), `a` to Ask Why on it (`askWhyRef`); the page's own
    /// keys as ever. A pod's verbs would
    /// act on the kind under the section: refused. With an app's detail
    /// read from marks beside it, Tab, ↑ ↓ and ↩ walk its tree first
    /// (`markedTreePress`). Nil: the page's to decide, the arrows the
    /// table's.
    func gitOpsPress(_ characters: String) -> Bool? {
        if cheatSheet { return nil }
        if let handled = markedTreePress(characters) { return handled }
        if characters == "K" {
            guard let ref = gitOpsSelectedRef else { return false }
            actions?.copy(KubectlLine.object(ref, discovery: model.knownDiscovery(of: ref.context)))
            return true
        }
        guard case .key(let key) = KubernetesKey.press(characters, sheetShowing: cheatSheet) else { return nil }
        switch key {
        case .close:
            // Esc: an app's detail goes; the table keeps the keyboard.
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
