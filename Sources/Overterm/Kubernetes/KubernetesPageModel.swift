import AppKit
import Combine
import Foundation

/// What the Kubernetes page asks the window to do.
struct KubernetesActions {
    /// A command typed into a new terminal tab (`aws sso login`): never a
    /// kubectl that changes a cluster.
    var run: (String) -> Void
    /// Settings ▸ Kubernetes.
    var settings: () -> Void
    var copy: (String) -> Void
    /// One Secret value, Copy pressed for it: marked concealed, so
    /// clipboard managers that honour the marker keep no history of it.
    var copySecret: (String) -> Void
    /// A file the user asked for (the list as CSV): a save panel, its name
    /// suggested — in a scenario, the run's own folder.
    var save: (_ name: String, _ text: String) -> Void = { _, _ in }
    /// Lines of a log, scrubbed, to an agent (⌘L): the Ask Agent sheet,
    /// with what they come from.
    var askAgent: (_ text: String, _ about: AskAgentModel.Part) -> Void = { _, _ in }
    /// Terminal in this context: a tab whose plain `kubectl` goes to the
    /// context, in the namespace (nil: the context's own). On production
    /// asked first, naming it.
    var openTerminal: (_ context: KubeContext, _ namespace: String?) -> Void = { _, _ in }
    /// A pod's command — a shell, attach, a log followed (`KubeCommands`) —
    /// typed into a new tab pinned to the context, in the namespace.
    var runInTab: (_ command: String, _ context: KubeContext, _ namespace: String) -> Void = { _, _, _ in }
    /// Asked first, with this button and Cancel (a shell on production).
    var confirm: (_ title: String, _ detail: String, _ button: String, _ then: @escaping () -> Void) -> Void = { _, _, _, _ in }
    /// One of these chosen, or Cancel: the index of the one chosen (a container).
    var choose: (_ title: String, _ detail: String, _ buttons: [String], _ then: @escaping (Int) -> Void) -> Void = { _, _, _, _ in }
    /// A forward's URL: the browser column (the page steps aside), or the
    /// default browser, as links open.
    var openURL: (URL) -> Void = { _ in }
    /// The tab under the page: a forward started now is its pill's.
    var currentTab: () -> UUID? = { nil }
    /// Where an Ingress is reached: the default browser — it is the
    /// cluster's front door, not a page of this Mac's.
    var openExternal: (URL) -> Void = { _ in }
    /// A database pod's connection through its forward, in the Database
    /// client's form, filled in: nothing is saved or connected until the
    /// user does (a password given goes to the keychain only then).
    var openDatabase: (DockerDatabaseGuess.Guess) -> Void = { _ in }
    /// A forward's OpenAPI document, imported into the API client on a press.
    var importAPI: (APIDiscovery.Source) -> Void = { _ in }
    /// Ask Why: a failing pod's or a stuck rollout's brief, scrubbed, in
    /// the Ask Agent sheet — the whole brief shown before it is sent.
    var askWhy: (KubeAgentBrief) -> Void = { _ in }
    /// A write asked first (rule 3), in the window: the context and
    /// namespace, the object, the kubectl it equals, a field for the name
    /// where rule 4 asks one; `then` gets what was typed, only when the
    /// button was pressed — the page checks it.
    var confirmWrite: (_ confirmation: KubeWriteConfirmation, _ then: @escaping (String) -> Void) -> Void = { _, _ in }
}

/// The Kubernetes lists' keys (`ResourceKey`), only while the list has the
/// keyboard. More join with their stages (docs/design/kubernetes/analysis.md,
/// Section 7); the writes (`r`, `+`, `-`, `=`, ⌫) each go through the
/// guard path — the access review, the confirmation, a typed name where
/// rule 4 says. Pure.
enum KubernetesKey: String, ResourceKey {
    case workloads, network, config, storage, access, cluster, custom, forwards
    case open, back, forward, close, logs, followInTab, shell, attach, portForward, openForward, database, askWhy
    case restart, scaleUp, scaleDown, scaleTo, delete
    case command, namespace, context, wide, allNamespaces, copyKubectl, filter, help

    var section: KubeSection? { KubeSection(rawValue: rawValue) }

    var key: String {
        if let section { return section.key }
        switch self {
        case .open: return "↩"
        case .back: return "["
        case .forward: return "]"
        case .close: return "Esc"
        case .logs: return "l"
        case .followInTab: return "t"
        case .shell: return "e"
        case .attach: return "A"
        case .portForward: return "f"
        case .openForward: return "o"
        case .database: return "d"
        case .askWhy: return "a"
        case .restart: return "r"
        case .scaleUp: return "+"
        case .scaleDown: return "-"
        case .scaleTo: return "="
        case .delete: return "⌫"
        case .command: return ":"
        case .namespace: return "n"
        case .context: return "c"
        case .wide: return "w"
        case .allNamespaces: return "0"
        case .copyKubectl: return "k"
        case .filter: return "/"
        default: return "?"
        }
    }

    var title: String {
        if let section { return section.title }
        switch self {
        case .open: return "The detail: overview, YAML, events — a pod's logs (a click opens it too)"
        case .logs: return "Logs: the pod's, followed — its containers, previous, since"
        case .followInTab: return "Follow the pod's log in a tab (kubectl logs -f), pinned to the context"
        case .shell: return "Shell in a tab (kubectl exec -it) — after kubectl auth can-i; asked first on production"
        case .attach: return "Attach in a tab (kubectl attach -it) — after kubectl auth can-i; asked first on production"
        case .portForward: return "Port-forward a pod, a Service or a Deployment — kubectl port-forward, started again on its next pod"
        case .openForward:
            return "Open a forward in the browser column — the selected object's, or the one picked in Forwards; an Ingress in your browser"
        case .database:
            return "Database client: a database pod (\(KubeDatabase.spoken)) forwarded, its connection form filled in"
        case .askWhy:
            return "Ask an agent why: a failing pod (CrashLoopBackOff, OOMKilled, ImagePullBackOff, Pending…) or a stuck rollout — its brief, scrubbed, shown before it is sent (⌘L too)"
        case .restart: return "Rollout restart a Deployment, StatefulSet or DaemonSet; on a pod, delete it so its controller makes it again — asked first"
        case .scaleUp: return "Scale up by one — asked first"
        case .scaleDown: return "Scale down by one — asked first; to 0 on production, the name typed"
        case .scaleTo: return "Scale to a number — asked first"
        case .delete: return "Delete — asked first; on production (and a namespace anywhere) the name typed"
        case .back: return "Back in the detail's history (⌘[ too)"
        case .forward: return "Forward in the detail's history (⌘] too)"
        case .close: return "Close the detail"
        case .command: return "A kind by name — :deploy, :po shop, :svc @fake-dev, :widgets /blue; :ctx, :ns"
        case .namespace: return "Namespace — one listed, or a name typed"
        case .context: return "Context"
        case .wide: return "Wide columns — what kubectl get -o wide adds (IP, Node…)"
        case .allNamespaces: return "All namespaces"
        case .copyKubectl: return "Copy as kubectl — the selected object's command, else the list's (its namespace and selectors)"
        case .filter: return "Filter — web status:crashloopbackoff ns:shop -status:running label:app=web field:status.phase=Running"
        default: return "These keys"
        }
    }
}

/// One row of a list: the server's row, and — for a pod — what its cells say of it.
struct KubeListRow: ResourceTableRow {
    let row: KubeRow
    let summary: KubePodSummary?
    /// A Deployment's state off its cells, where the Table has no Status.
    var hint: KubeDeploymentHint? = nil

    var id: String { row.id.description }
    var height: CGFloat { 26 }
}

/// A window's Kubernetes page: which section, what the filter says, what is
/// selected, how the list is sorted, the `:` bar. The contexts, the kind
/// shown and its rows are the app's (`KubernetesModel`).
@MainActor
final class KubernetesPageModel: ObservableObject {
    /// The section shown: the kind's, else one picked whose kinds aren't
    /// known yet (discovery not read) or that has none.
    @Published private(set) var section: KubeSection = .workloads
    /// `:`: the command bar over the page.
    @Published var command: KubeCommandBar?
    /// What the filter field says. Its `label:` and `field:` words go to
    /// the server (`KubeListSelectors`), a moment after the typing stops.
    @Published var filter = "" {
        didSet { if filter != oldValue { selectorChanged() } }
    }
    /// Rows by `namespace/name` (`KubeRowID.description`).
    @Published var selection: Set<String> = []
    /// Nil: by namespace, then name.
    @Published var sort: ResourceSort?
    /// Every column, `-o wide`'s too (`w`).
    @Published var wide = false
    @Published var cheatSheet = false
    /// `n` or `c`: the namespace or context picker over the page.
    @Published var picker: KubePicker?
    /// Bumped to give the list the keyboard (`focusPageList`), and the filter field.
    @Published private(set) var focusList = 0
    /// Bumped when the list may take the keyboard if nobody has it.
    @Published private(set) var offerList = 0
    @Published private(set) var focusFilter = 0
    /// Bumped to give a pod's Logs tab's filter the keyboard (⌘F there).
    @Published private(set) var focusLogFilter = 0
    /// Whether the page shows in its window. Shown, its filter's selector
    /// is the list's again — another window's page may have had its own;
    /// hidden, it gives the list back, so nothing is narrowed by a filter
    /// that isn't on screen (the ⌃⌘J switcher's pods, another page's).
    @Published var visible = false {
        didSet {
            guard visible != oldValue else { return }
            if visible {
                applySelector()
            } else {
                selecting?.cancel()
                selecting = nil
                model.releaseSelectors(for: self)
                // A Secret's values never outlive the page on screen.
                detail?.secret?.drop(.pageHidden)
            }
            updateLogsReading()
        }
    }
    /// Whether its window is on screen at all.
    @Published var windowVisible = true {
        didSet {
            if !windowVisible { detail?.secret?.drop(.pageHidden) }
            updateLogsReading()
        }
    }
    /// How a pod's log shows — wrap, timestamps, newest first, the search
    /// as a regular expression or marking matches — kept for the window.
    @Published var logOptions = LogViewOptions()
    /// How far back a pod's log goes, kept for the window.
    @Published var logSince: KubeLogSince = .all {
        didSet { if logSince != oldValue { updateLogsReading() } }
    }
    var actions: KubernetesActions?

    let model: KubernetesModel
    /// The app's port-forwards: the Forwards section, `f`, `o`.
    let forwards: KubeForwards
    /// How long the typing must stop before `label:` or `field:` asks the server again.
    var selectorDelay: Duration = .milliseconds(350)
    private var selecting: Task<Void, Never>?
    private var pickerWatch: AnyCancellable?
    private var kindWatch: AnyCancellable?
    /// The kind last shown in each section.
    private var lastKind: [KubeSection: String] = [:]
    private var selectionWatch: AnyCancellable?
    private var contextWatch: AnyCancellable?
    private var scopeWatch: AnyCancellable?

    /// `f`: the forward sheet over the page — a target's ports, the local
    /// port, the address, https — or one being edited.
    @Published var forwardDraft: KubeForwardDraft?
    /// Why the sheet's forward can't start as it stands.
    @Published var forwardProblem: String?
    /// The forward picked in the Forwards section (`o` opens it).
    @Published var forwardSelection: UUID?
    /// Whether something on this Mac listens on a port: a test's stands in.
    var isPortBound: (Int) -> Bool = { ListeningPorts.isBound($0) }

    /// The object Ask Why is reading a brief for, while it does.
    @Published var askingWhy: KubeObjectRef?

    /// The detail beside the list: one object, read once as it opens.
    /// How the last write stands: asked, sent, done or why not.
    @Published var writeStatus: KubeWriteStatus?
    /// `=`: the scale sheet, over the page.
    @Published var scaleDraft: KubeScaleDraft?
    /// What a write is stamped with (a rollout restart's `restartedAt`).
    var clock: () -> Date = { Date() }
    @Published private(set) var detail: KubeDetailSession?
    @Published var detailTab: KubeDetailTab = .overview
    /// Where the detail has been, back and forward: this page's, across
    /// kinds, in the context shown.
    @Published private(set) var history = KubeHistory()
    /// Why a link couldn't be followed (its kind isn't served).
    @Published private(set) var linkProblem: String?

    init(model: KubernetesModel = .shared, forwards: KubeForwards = .shared) {
        self.model = model
        self.forwards = forwards
        // A picker that shows follows what comes in: the namespaces listed
        // after it opened, the kubeconfig read again. The emitted values:
        // the model's properties aren't set yet.
        pickerWatch = model.$namespaces.map { _ in () }.merge(with: model.$namespacesRefused.map { _ in () }, model.$contexts.map { _ in () })
            .dropFirst()
            .sink { [weak self] in DispatchQueue.main.async { self?.refreshPicker() } }
        // The section follows the kind shown, whoever picked it (another
        // window's page, the switcher); a section picked before its kinds
        // were known shows its first once they are. Emitted values, again.
        kindWatch = model.$kind.combineLatest(model.$catalog)
            .dropFirst()
            .sink { [weak self] kind, catalog in self?.follow(kind, catalog) }
        section = model.catalog.section(of: model.kind) ?? .workloads
        // An open detail follows the list's one selected row (the arrows,
        // a click): the emitted value, the property isn't set yet.
        selectionWatch = $selection.dropFirst()
            .sink { [weak self] ids in
                // Why the last command didn't open was about the pod picked then.
                self?.commandProblem = nil
                self?.askAccess(for: ids)
                self?.askWriteAccess(for: ids)
                guard let self, self.detail != nil, ids.count == 1, let id = ids.first, let ref = self.ref(for: id) else { return }
                self.open(ref, from: .list)
            }
        // Another context: its objects aren't this one's — the detail and
        // its history go.
        // Another context or namespace: the last command's problem was
        // about the one before.
        scopeWatch = model.$selectedName.removeDuplicates().dropFirst().map { _ in () }
            .merge(with: model.$scope.removeDuplicates().dropFirst().map { _ in () })
            .sink { [weak self] in
                self?.commandProblem = nil
                self?.writeStatus = nil
            }
        contextWatch = model.$selectedName.dropFirst().removeDuplicates()
            .sink { [weak self] name in
                guard let self, let shown = self.history.current?.context ?? self.history.back.last?.context, shown != name else { return }
                // Said as the context's, before cancel() says navigation.
                self.detail?.secret?.drop(.contextChanged)
                self.detail?.cancel()
                self.detail = nil
                self.linkProblem = nil
                self.history.clear()
            }
    }

    private func follow(_ kind: KubeResourceKind, _ catalog: KubeKindCatalog) {
        // Forwards shows the app's forwards, whatever kind the list is on.
        if section == .forwards {
            if let shown = catalog.section(of: kind) { lastKind[shown] = kind.fullName }
            return
        }
        if waitingForSection {
            // A section picked with no kind to show: its first, once it has one.
            guard let first = catalog.kinds(in: section).first else { return }
            waitingForSection = false
            if catalog.section(of: kind) == section {
                lastKind[section] = kind.fullName
            } else {
                DispatchQueue.main.async { [weak self] in self?.showKind(first) }
            }
            return
        }
        if let shown = catalog.section(of: kind) {
            if section != shown { section = shown }
            lastKind[shown] = kind.fullName
        }
    }

    /// A section picked that has no kind to show: discovery not read yet,
    /// or none of its kinds served (no CRDs).
    @Published private(set) var waitingForSection = false

    /// A section's digit: its kind last shown, else its first — or, while
    /// it has none, the section alone until it has.
    func showSection(_ section: KubeSection) {
        guard section.listsKinds else {
            waitingForSection = false
            self.section = section
            return
        }
        let kinds = model.catalog.kinds(in: section)
        if let kind = lastKind[section].flatMap({ name in kinds.first { $0.fullName == name } }) ?? kinds.first {
            showKind(kind)
        } else if section == .workloads, model.catalog.isEmpty {
            // Before discovery: Pods, which every cluster serves.
            waitingForSection = false
            self.section = section
            showKind(.pods)
        } else {
            waitingForSection = true
            self.section = section
        }
    }

    /// The list on `kind`, its section with it.
    func showKind(_ kind: KubeResourceKind) {
        waitingForSection = false
        if let shown = model.catalog.section(of: kind) {
            section = shown
            lastKind[shown] = kind.fullName
        } else if !section.listsKinds {
            // Before discovery (Pods): off Forwards, onto the list.
            section = .workloads
        }
        if kind.fullName != model.kind.fullName {
            selection = []
            sort = nil
        }
        model.setKind(kind)
    }

    /// Whether the list shows the section's kind: false while a section is
    /// picked that has none to show.
    var showsSection: Bool { !waitingForSection && section.listsKinds }

    /// The list's title: the kind's, as the page calls it.
    var title: String { showsSection ? KubeKindCatalog.title(of: model.kind) : section.title }

    // MARK: Keys

    /// A key down while the list has the keyboard: true when it meant something.
    func press(_ characters: String) -> Bool {
        // The forward sheet's fields have the keys; Esc closes it.
        if forwardDraft != nil {
            guard characters == "\u{1B}" else { return false }
            closeForwardSheet()
            return true
        }
        // So do the scale sheet's.
        if scaleDraft != nil {
            guard characters == "\u{1B}" else { return false }
            closeScaleSheet()
            return true
        }
        guard let press = KubernetesKey.press(characters, sheetShowing: cheatSheet) else { return false }
        switch press {
        case .closeSheet: cheatSheet = false
        case .section(let section): showSection(section)
        case .help: cheatSheet = true
        case .filter: focusFilter += 1
        case .key(let key):
            switch key {
            case .open: return openSelected()
            case .back: goBack()
            case .forward: goForward()
            case .close:
                guard detail != nil else { return false }
                closeDetail()
            case .command: openCommand()
            case .namespace: openPicker(.namespace)
            case .context: openPicker(.context)
            case .wide: wide.toggle()
            case .allNamespaces: model.setScope(.all)
            case .copyKubectl: copyKubectl()
            case .logs: return openLogs()
            case .followInTab: return runPodCommand(.followLogs)
            case .shell: return runPodCommand(.shell)
            case .attach: return runPodCommand(.attach)
            case .portForward: return portForward()
            case .openForward: return openForward()
            case .database: return openInDatabase()
            case .askWhy: return askWhy()
            case .restart: return restartKey()
            case .scaleUp: return scaleKey(.by(1))
            case .scaleDown: return scaleKey(.by(-1))
            case .scaleTo: return scaleKey(nil)
            case .delete: return deleteKey()
            default: return false
            }
        }
        return true
    }

    // MARK: The detail

    /// The object a row of the list is: the kind shown, in the context shown.
    func ref(for id: String) -> KubeObjectRef? {
        guard let context = model.selectedName, let row = model.rows.sorted.first(where: { $0.id.description == id }) else { return nil }
        return KubeObjectRef(context: context, kind: model.kind, namespace: row.id.namespace, name: row.id.name)
    }

    /// ↩: the detail of the selected row (the first, of several, in the
    /// list's order).
    @discardableResult
    func openSelected() -> Bool {
        guard let row = rows.first(where: { selection.contains($0.id) }), let ref = ref(for: row.id) else { return false }
        // A pod's ↩ is its logs (docs/design/kubernetes/analysis.md, Section 7).
        if ref.isPod { detailTab = .logs }
        open(ref, from: .list)
        updateLogsReading()
        return true
    }

    /// `l`: the selected pod's logs; nothing for another kind.
    @discardableResult
    func openLogs() -> Bool {
        guard let row = rows.first(where: { selection.contains($0.id) }), let ref = ref(for: row.id), ref.isPod else { return false }
        detailTab = .logs
        open(ref, from: .list)
        updateLogsReading()
        return true
    }

    /// The Logs tab reads while it shows — the page on screen, in a window
    /// on screen — and closes its stream otherwise.
    func updateLogsReading() {
        guard let logs = detail?.logs else { return }
        if visible && windowVisible && detailTab == .logs { logs.show(since: logSince) } else { logs.hide() }
    }

    /// Lines picked out of a pod's log (⌘L, its right-click menu): scrubbed
    /// of what looks secret — the pod's own env values, tokens, keys — then
    /// to the Ask Agent sheet with the pod they come from.
    func askAboutLogLines(_ picked: String) {
        guard let detail, let logs = detail.logs else { return }
        let ref = detail.ref
        let command = KubectlLine.logs(
            context: ref.context, namespace: logs.namespace, pod: logs.pod, container: logs.container, previous: logs.previous, since: .all,
            timestamps: true)
        let about =
            "They come from the log of pod \(logs.namespace)/\(logs.pod)"
            + (logs.container.map { ", container \($0)" } ?? "") + (logs.previous ? " (its previous, terminated instance)" : "")
            + ", in Kubernetes context \(ref.context)"
            + ((model.contexts.context(named: ref.context)?.isProduction ?? true) ? " (production: read-only)" : "") + ".\nRead it with: \(command)"
        actions?.askAgent(logs.scrubbed(picked), AskAgentModel.Part(title: "pod/\(logs.pod)", text: logs.scrubbed(about)))
    }

    /// Save As… for a pod's log: the lines shown, under a timestamped name.
    func saveLogs(_ text: String) {
        guard let logs = detail?.logs else { return }
        actions?.save(logs.fileName, text)
    }

    /// A plain click on a row: its detail.
    func pressed(_ id: String) {
        guard let ref = ref(for: id) else { return }
        open(ref, from: .list)
    }

    /// The detail on `ref`: a visit in the history, one GET.
    func open(_ ref: KubeObjectRef, from origin: KubeHistory.Origin) {
        history.visit(ref, from: origin)
        show(ref)
    }

    /// A link in a detail (an owner, a node, a selected pod): its object,
    /// as the context serves its kind.
    @discardableResult
    func follow(_ link: KubeLink) -> Bool {
        guard let context = detail?.ref.context ?? model.selectedName else { return false }
        guard let discovery = model.knownDiscovery(of: context), let ref = link.resolve(in: discovery, context: context) else {
            linkProblem = "\(context) serves no \(link.kind) (\(link.apiVersion))."
            return false
        }
        open(ref, from: .link)
        return true
    }

    /// A pod of a detail's selected pods.
    func openPod(_ row: KubeListRow) {
        guard let context = detail?.ref.context ?? model.selectedName else { return }
        let kind = model.knownDiscovery(of: context)?.kind(apiVersion: "v1", kind: "Pod") ?? .pods
        open(KubeObjectRef(context: context, kind: kind, namespace: row.row.id.namespace, name: row.row.id.name), from: .link)
    }

    /// `[` or ⌘[: the object shown before.
    func goBack() {
        guard let ref = history.goBack() else { return }
        show(ref)
    }

    /// `]` or ⌘]: the one after.
    func goForward() {
        guard let ref = history.goForward() else { return }
        show(ref)
    }

    /// ⌘[ and ⌘] while the page shows: the detail's, when it has somewhere
    /// to go — else the menus' (the panes). ⌘F with a pod's Logs tab
    /// showing: its filter (`/` is the list's).
    func commandPress(_ characters: String) -> Bool {
        switch characters {
        case "f" where detailTab == .logs && detail?.logs != nil:
            focusLogFilter += 1
            return true
        case "[" where history.canGoBack:
            goBack()
            return true
        case "]" where history.canGoForward:
            goForward()
            return true
        default: return false
        }
    }

    /// Esc, or its ×: the detail goes — what it read with it — and the list
    /// has the keyboard. Back (`[`) shows it again.
    func closeDetail() {
        guard detail != nil else { return }
        detail?.cancel()
        detail = nil
        linkProblem = nil
        history.leave()
        giveListTheKeyboard()
    }

    private func show(_ ref: KubeObjectRef) {
        linkProblem = nil
        guard detail?.ref != ref else { return }
        commandProblem = nil
        detail?.cancel()
        let client = model.client(for: ref.context)
        let session = KubeDetailSession(ref: ref, client: client, secret: ref.isSecret ? secretSession(for: ref, client: client) : nil)
        detail = session
        // Logs are a pod's: another kind's detail opens on its Overview.
        if detailTab == .logs && !ref.isPod { detailTab = .overview }
        session.load()
        // Asked once the object is read, by its uid (the session waits).
        if detailTab == .events { session.loadEvents() }
        updateLogsReading()
    }

    /// A Secret's Show, with what its row says (Type, how many keys) and
    /// whether its context is production — unknown counts as production.
    private func secretSession(for ref: KubeObjectRef, client: KubeClient?) -> KubeSecretSession {
        let row = model.kind.fullName == ref.kind.fullName ? model.rows[KubeRowID(namespace: ref.namespace, name: ref.name)] : nil
        let type = row?.cell("Type", in: model.rows.columns)?.text
        let keys: Int? =
            switch row?.cell("Data", in: model.rows.columns) {
            case .integer(let count)?: count
            case .text(let text)?: Int(text)
            default: nil
            }
        let production = model.contexts.context(named: ref.context)?.isProduction ?? true
        return KubeSecretSession(
            ref: ref, client: client, consent: model.secretConsent, isProduction: production, listedType: type.flatMap { $0.isEmpty ? nil : $0 },
            listedKeys: keys)
    }

    /// Show, for the Secret the detail shows (its Overview's button, its YAML's).
    func showSecret() -> Bool {
        guard let secret = detail?.secret else { return false }
        secret.show()
        return true
    }

    /// Copy, for one value of the Secret shown: asked for by the user.
    func copySecretValue(_ key: String) {
        guard let text = detail?.secret?.copyValue(key) else { return }
        actions?.copySecret(text)
    }

    /// The detail's tab shown: what it reads is asked for then.
    func showTab(_ tab: KubeDetailTab) {
        detailTab = tab
        if tab == .events { detail?.loadEvents() }
        updateLogsReading()
    }

    // MARK: The command bar

    /// `:`: the bar, over the page, with what it completes from.
    func openCommand() {
        cheatSheet = false
        picker = nil
        command = KubeCommandBar(kinds: model.catalog.all, namespaces: model.namespaces, contexts: model.contexts.contexts.map(\.name))
    }

    /// Esc: closed, the list has the keyboard again.
    func closeCommand() {
        command = nil
        giveListTheKeyboard()
    }

    /// ↩: what the bar says, done — or, when it means nothing, why, the
    /// bar left open.
    func runCommand() {
        guard var bar = command else { return }
        guard let parsed = bar.command() else {
            bar.problem = bar.text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : "Not a command: \(bar.text)"
            command = bar
            return
        }
        if let problem = run(parsed) {
            bar.problem = problem
            command = bar
            return
        }
        command = nil
        giveListTheKeyboard()
    }

    /// A command done; why not, when it can't be. All of it is checked
    /// before anything changes: a typo (`:nope @fake-prod`) switches no
    /// context — its proxy isn't started, nothing is asked of it. The kind
    /// is read as the context named serves it, when that is known (read
    /// lately), else as the one shown does.
    @discardableResult
    func run(_ command: KubeCommand) -> String? {
        var target = model.selected
        if let wanted = command.context {
            guard let context = Self.context(wanted, in: model.contexts) else { return "No context called \(wanted)." }
            target = context
        }
        let targetName = target?.name ?? model.selectedName
        var scope: KubeScope?
        if command.allNamespaces {
            scope = .all
        } else if let namespace = command.namespace, command.action == .kind(command.target) {
            guard let typed = KubePicker.typedNamespace(namespace) else { return "Not a namespace's name: \(namespace)" }
            scope = .namespace(typed)
        }
        var kind: KubeResourceKind?
        switch command.action {
        case .context(let name):
            guard let name else {
                openPicker(.context)
                return nil
            }
            guard let context = Self.context(name, in: model.contexts) else { return "No context called \(name)." }
            model.select(context.name)
            return nil
        case .namespace(let name):
            switch name {
            case nil, "*": break
            case let name?:
                guard let typed = KubePicker.typedNamespace(name) else { return "Not a namespace's name: \(name)" }
                scope = .namespace(typed)
            }
        case .kind(let name):
            let served = targetName.flatMap(model.knownDiscovery(of:)) ?? model.discovery
            guard let discovery = served else { return "What \(targetName ?? "the context") serves isn't known yet." }
            guard let resolved = KubeKinds.resolve(name, in: discovery, catalog: KubeKindCatalog(discovery)) else {
                return "\(targetName ?? "The context") serves no kind called \(name)."
            }
            guard KubeKindCatalog.isOffered(resolved) else {
                return "\(resolved.fullName) can't be listed and watched (\(resolved.verbs.joined(separator: ", ")))."
            }
            kind = resolved
        }
        // Checked: now done.
        if let target, target.name != model.selectedName { model.select(target.name) }
        switch command.action {
        case .namespace(nil):
            openPicker(.namespace)
            return nil
        case .namespace("*"):
            model.setScope(.all)
            return nil
        case .namespace:
            if let scope { model.setScope(scope) }
            return nil
        default: break
        }
        if let kind { showKind(kind) }
        if let scope { model.setScope(scope) }
        if command.filter != nil || command.labels != nil {
            filter = [command.filter, command.labels.map { "label:\($0)" }].compactMap { $0 }.joined(separator: " ")
            applySelector()
        }
        return nil
    }

    /// A context by its name or the name its settings give it.
    private static func context(_ name: String, in list: KubeContextList) -> KubeContext? {
        list.contexts.first { $0.name == name || $0.displayName == name }
    }

    func giveListTheKeyboard() { focusList += 1 }

    /// The keyboard to the list, unless something has it (the filter, the palette).
    func offerListTheKeyboard() { offerList += 1 }

    // MARK: The pickers

    /// `n` or `c`: the picker, on what shows now.
    func openPicker(_ kind: KubePicker.Kind) {
        cheatSheet = false
        command = nil
        picker = makePicker(kind)
    }

    /// Esc: the list has the keyboard again.
    func closePicker() {
        picker = nil
        giveListTheKeyboard()
    }

    /// ↩: the namespace or context highlighted, or typed.
    func choosePicked() {
        guard let choice = picker?.chosen else { return }
        picker = nil
        switch choice {
        case .scope(let scope): model.setScope(scope)
        case .context(let name): model.select(name)
        }
        giveListTheKeyboard()
    }

    private func makePicker(_ kind: KubePicker.Kind) -> KubePicker? {
        switch kind {
        case .namespace:
            guard let context = model.selected else { return nil }
            let settings = context.settings
            return KubePicker.namespaces(
                listed: model.namespaces, favourites: settings.favouriteNamespaces, own: settings.defaultNamespace ?? context.namespace,
                current: model.scope, refused: model.namespacesRefused)
        case .context:
            guard !model.contexts.contexts.isEmpty else { return nil }
            return KubePicker.contexts(model.contexts, selected: model.selectedName)
        }
    }

    /// The picker showing made again from what the model has now, what is
    /// typed and highlighted kept.
    func refreshPicker() {
        guard let old = picker, var new = makePicker(old.kind) else { return }
        guard new.items != old.items || new.note != old.note else { return }
        let highlighted = old.selected?.id
        new.query = old.query
        if let highlighted, let at = new.results.firstIndex(where: { $0.id == highlighted }) { new.index = at }
        picker = new
    }

    // MARK: The selector

    /// What the filter's `label:` words say.
    var labelReading: KubeLabelSelector.Reading { KubeLabelSelector.read(filter) }

    /// What the filter's `label:` and `field:` words ask the server for,
    /// and the words that couldn't be read as either.
    var selectorReading: KubeListSelectors.Reading { KubeListSelectors.read(filter) }

    private func selectorChanged() {
        selecting?.cancel()
        let delay = selectorDelay
        selecting = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.applySelector()
        }
    }

    /// The list asked for with the filter's selector now — on ↩ in the
    /// field, once the typing stops, or when its window becomes key while it
    /// shows. A page that doesn't show asks for nothing.
    func applySelector() {
        selecting?.cancel()
        selecting = nil
        guard visible else { return }
        model.setSelectors(selectorReading.selectors, for: self)
    }

    /// Whether the list is the one this page's filter asks for: false while
    /// another window's page, showing too, asked last with its own `label:`
    /// or `field:`.
    var listIsOurs: Bool { model.isSelector(selectorReading.selectors, of: self) }

    // MARK: What the page says

    /// The red band over the whole page on a production context; nil elsewhere.
    var band: String? {
        guard let context = model.selected, context.isProduction else { return nil }
        guard context.sessionWrites else { return "PRODUCTION · \(context.displayName) · read-only: Overterm changes nothing here" }
        return "PRODUCTION · \(context.displayName) · writes on until quit: each one asked, a destructive one by its name"
    }

    /// The selected context's class and whether Overterm may write there.
    var classLabel: String? {
        guard let context = model.selected else { return nil }
        return "\(context.contextClass.title) · \(context.isWritable ? "writable" : "read-only")"
    }

    var scopeLabel: String {
        switch model.scope {
        case .all: "All namespaces"
        case .namespace(let name): name
        }
    }

    /// The columns the list shows: the server's (priority 0, or all of
    /// them wide), each by its index in the Table; across all namespaces a
    /// namespaced kind's Namespace column first, as `kubectl get -A` adds it.
    var columns: [ResourceColumn] {
        var columns = model.rows.columns.enumerated().filter { wide || $0.element.priority == 0 }.map { index, column in
            ResourceColumn(
                id: "c\(index)", title: column.name, width: Self.width(of: column.name), minWidth: 40,
                help: column.description.isEmpty ? nil : column.description)
        }
        if model.scope == .all, model.kind.namespaced, !columns.isEmpty,
            !model.rows.columns.contains(where: { $0.name.caseInsensitiveCompare("Namespace") == .orderedSame })
        {
            columns.insert(ResourceColumn(id: Self.namespaceColumn, title: "Namespace", width: 150), at: 0)
        }
        if hasStatusHint {
            // Before Age, where kubectl's other lists have their Status.
            let age = columns.firstIndex { $0.title.caseInsensitiveCompare("Age") == .orderedSame } ?? columns.count
            columns.insert(
                ResourceColumn(
                    id: KubeDeploymentHint.column, title: "Status", width: 150, minWidth: 40,
                    help: "Read off Ready, Up-to-date and Available — the server's Table has no Status. The detail's Rollout says why."), at: age)
        }
        return columns
    }

    /// Whether the list gets a Status column of the page's own: a
    /// Deployments list whose Table has none (`KubeDeploymentHint`).
    var hasStatusHint: Bool { KubeDeploymentHint.applies(to: model.kind, columns: model.rows.columns) }

    static let namespaceColumn = "namespace"

    static func width(of column: String) -> CGFloat {
        switch column.lowercased() {
        case "name": 280
        case "ready": 64
        case "status": 170
        case "restarts": 120
        case "age": 72
        case "ip": 120
        case "node": 170
        default: 130
        }
    }

    /// The server's column a list column shows; nil for the Namespace one.
    func column(_ id: String) -> (index: Int, column: KubeColumn)? {
        guard id.hasPrefix("c"), let index = Int(id.dropFirst()), model.rows.columns.indices.contains(index) else { return nil }
        return (index, model.rows.columns[index])
    }

    /// Whether the list is of pods: their Status read for failures.
    var isPods: Bool { model.kind.fullName == KubeResourceKind.pods.fullName }

    /// The rows the filter lets through, in the list's order. `label:` is
    /// the server's: the rows came filtered by it — or by another page's,
    /// which the page says (`listIsOurs`).
    var rows: [KubeListRow] {
        let columns = model.rows.columns
        var filter = ResourceFilter<KubeFilterKey>(self.filter)
        filter.terms.removeAll { $0.key.isServers }
        let pods = isPods
        let hints = hasStatusHint
        let rows = model.rows.sorted.map {
            KubeListRow(
                row: $0, summary: pods ? KubePodSummary(row: $0, columns: columns) : nil, hint: hints ? KubeDeploymentHint(row: $0, columns: columns) : nil)
        }
        .filter { Self.matches($0, filter, columns: columns) }
        guard let sort else { return rows }
        let now = Date()
        return sort.sorted(rows) { sortKey($0, sort.column, now: now) }
    }

    /// Every pod that fails, with why — whatever the filter shows.
    var failing: [KubePodSummary] {
        guard isPods else { return [] }
        let columns = model.rows.columns
        return model.rows.sorted.compactMap { KubePodSummary(row: $0, columns: columns) }.filter(\.isFailing)
    }

    /// Text matches the name, the namespace or the Status (a Deployment's
    /// read off its cells; for a kind with no Status, its Type: a Service's,
    /// a Secret's, an event's).
    static func matches(_ row: KubeListRow, _ filter: ResourceFilter<KubeFilterKey>, columns: [KubeColumn]) -> Bool {
        filter.matches { term in
            let namespace = row.row.id.namespace?.lowercased() ?? ""
            let status =
                (row.summary?.status ?? row.hint?.text ?? (row.row.cell("Status", in: columns) ?? row.row.cell("Type", in: columns))?.text ?? "")
                .lowercased()
            switch term.key {
            case .text: return row.row.id.name.lowercased().contains(term.value) || namespace.contains(term.value) || status.contains(term.value)
            case .namespace: return namespace == term.value
            case .status: return status.contains(term.value)
            case .label, .field: return true
            }
        }
    }

    /// What a column sorts a row by: numbers as numbers, ages by age, text as text.
    enum SortKey: Comparable {
        case number(Double)
        case text(String)
    }

    func sortKey(_ row: KubeListRow, _ id: String, now: Date) -> SortKey? {
        if id == Self.namespaceColumn { return row.row.id.namespace.map { .text($0) } }
        if id == KubeDeploymentHint.column { return row.hint.map { .text($0.text.lowercased()) } }
        guard let (index, column) = column(id), index < row.row.cells.count else { return nil }
        switch column.name.lowercased() {
        case "age", "created at": return age(of: row.row.id, at: now).map { .number($0) }
        case "restarts": return row.summary?.restarts.map { .number(Double($0)) }
        default: break
        }
        switch row.row.cells[index] {
        case .integer(let value): return .number(Double(value))
        case .number(let value): return .number(value)
        case .none: return nil
        case let cell: return .text(cell.text.lowercased())
        }
    }

    /// A row's age now, counted on from when it came.
    func age(of id: KubeRowID, at now: Date) -> TimeInterval? { model.anchors[id]?.age(at: now) }

    /// The selected rows' names, for ⌘C.
    var selectedNames: [String] {
        rows.filter { selection.contains($0.id) }.map(\.row.id.name)
    }

    /// The right-click menu: only what reads or copies — this page changes
    /// nothing — and a terminal pinned to the context (the user's own kubectl).
    func verbs(for ids: Set<String>) -> [ResourceVerb] {
        let picked = model.rows.sorted.filter { ids.contains($0.id.description) }
        guard !picked.isEmpty else { return [] }
        let names = picked.map(\.id.name).joined(separator: "\n")
        let qualified = picked.map { $0.id.description }.joined(separator: "\n")
        let commands = kubectl(for: Set(picked.map(\.id.description)))
        let list = listKubectl
        return [
            ResourceVerb(title: picked.count == 1 ? "Copy Name" : "Copy Names", symbol: "doc.on.doc") { [weak self] in self?.actions?.copy(names) },
            ResourceVerb(title: "Copy Namespace/Name", symbol: "doc.on.doc") { [weak self] in self?.actions?.copy(qualified) },
            ResourceVerb(title: "Copy as kubectl", symbol: "terminal", key: KubernetesKey.copyKubectl.key, group: 1) { [weak self] in
                self?.actions?.copy(commands)
            },
            ResourceVerb(title: "Copy List as kubectl", symbol: "terminal", unavailable: list == nil ? "No context" : nil, group: 1) { [weak self] in
                if let list { self?.actions?.copy(list) }
            },
            ResourceVerb(title: picked.count == 1 ? "Copy Row as TSV" : "Copy Rows as TSV", symbol: "tablecells", group: 2) { [weak self] in
                self?.copyRows(.tsv, ids: ids)
            },
            ResourceVerb(title: picked.count == 1 ? "Copy Row as CSV" : "Copy Rows as CSV", symbol: "tablecells", group: 2) { [weak self] in
                self?.copyRows(.csv, ids: ids)
            },
            ResourceVerb(title: "Export List as CSV…", symbol: "square.and.arrow.up", group: 2) { [weak self] in self?.exportCSV() },
        ] + [terminalVerb(for: picked)].compactMap { $0 } + askWhyVerbs(for: picked) + podVerbs(for: picked) + forwardVerbs(for: picked)
            + writeVerbs(for: picked)
    }

    /// A pod's tab verbs, for the one pod picked in the pod list.
    private func podVerbs(for picked: [KubeRow]) -> [ResourceVerb] {
        guard isPods, picked.count == 1, let row = picked.first, let ref = ref(for: row.id.description) else { return [] }
        return podVerbs(for: ref)
    }

    // MARK: Copy as kubectl

    /// The list's command: the kind, the namespace (or `-A`), the
    /// selectors sent to the server, `-o wide` when wide. The filter's text
    /// words have no kubectl twin and are left out. Nil with no context.
    var listKubectl: String? {
        guard let context = model.selectedName else { return nil }
        return KubectlLine.list(
            context: context, kind: model.kind, scope: model.scope, selectors: selectorReading.selectors, wide: wide,
            discovery: model.knownDiscovery(of: context))
    }

    /// Each row's own command, a line each.
    func kubectl(for ids: Set<String>) -> String {
        let discovery = model.selectedName.flatMap(model.knownDiscovery(of:))
        return rows.filter { ids.contains($0.id) }.compactMap { ref(for: $0.id) }.map { KubectlLine.object($0, discovery: discovery) }
            .joined(separator: "\n")
    }

    /// What the detail shows, as kubectl: its object, or on the Events tab
    /// its events.
    var detailKubectl: String? {
        guard let ref = detail?.ref else { return nil }
        let discovery = model.knownDiscovery(of: ref.context)
        if detailTab == .logs, let logs = detail?.logs {
            return KubectlLine.logs(
                context: ref.context, namespace: logs.namespace, pod: logs.pod, container: logs.container, previous: logs.previous, since: logSince,
                timestamps: logOptions.timestamps)
        }
        return detailTab == .events ? KubectlLine.events(for: ref, discovery: discovery) : KubectlLine.object(ref, discovery: discovery)
    }

    /// What `k` copies: the selected rows' commands, else the list's.
    var copyTarget: String? {
        let selected = kubectl(for: selection)
        return selected.isEmpty ? listKubectl : selected
    }

    /// `k`: `copyTarget`, on the pasteboard.
    @discardableResult
    func copyKubectl() -> String? {
        guard let text = copyTarget else { return nil }
        actions?.copy(text)
        return text
    }

    /// The detail's Copy as kubectl.
    func copyDetailKubectl() {
        guard let text = detailKubectl else { return }
        actions?.copy(text)
    }

    // MARK: CSV

    /// The list as the page shows it: its columns, the rows its filter lets
    /// through in its order, each cell as drawn — an age as it reads now.
    func csv(now: Date = Date()) -> String { rowsText(.csv, now: now) }

    /// The rows as `format`, the shown columns' titles first: those of
    /// `ids` that the filter shows, in the list's order — every shown row
    /// when `ids` is nil.
    func rowsText(_ format: ResultExport.Format, ids: Set<String>? = nil, now: Date = Date()) -> String {
        let columns = self.columns
        let picked = ids.map { ids in rows.filter { ids.contains($0.id) } } ?? rows
        let lines = picked.map { row in columns.map { cellText(row, $0, now: now) } }
        return KubeListExport.text(format, columns: columns.map(\.title), rows: lines)
    }

    /// Copy Rows as TSV or CSV: these rows, else the selected ones, else
    /// every row the filter shows.
    @discardableResult
    func copyRows(_ format: ResultExport.Format, ids: Set<String>? = nil) -> String? {
        guard canExport else { return nil }
        let chosen = ids ?? selection
        let shown = rows.contains { chosen.contains($0.id) }
        let text = rowsText(format, ids: shown ? chosen : nil)
        actions?.copy(text)
        return text
    }

    /// A cell's text, as the list draws it.
    func cellText(_ row: KubeListRow, _ column: ResourceColumn, now: Date) -> String {
        if column.id == Self.namespaceColumn { return row.row.id.namespace ?? "" }
        if column.id == KubeDeploymentHint.column { return row.hint?.text ?? "" }
        guard let (index, server) = self.column(column.id), index < row.row.cells.count else { return "" }
        let text = row.row.cells[index].text
        switch server.name.lowercased() {
        case "age", "created at": return age(of: row.row.id, at: now).map(KubeAge.format) ?? text
        case "status" where row.summary?.isFailing == true: return row.summary?.exitReason ?? text
        default: return text
        }
    }

    var csvFileName: String {
        KubeListExport.fileName(context: model.selectedName ?? "kubernetes", kind: model.kind, scope: model.scope)
    }

    /// Whether there is a list to export.
    var canExport: Bool { showsSection && !columns.isEmpty }

    /// Why the last export wrote no file (a read-only folder, a full
    /// disk), nil once one is written; the window says it too.
    var exportProblem: String?

    /// The list, saved where the user says.
    func exportCSV() {
        guard canExport else { return }
        actions?.save(csvFileName, csv())
    }

    // MARK: A pod's commands in a tab

    /// Why the last shell, attach or followed log didn't open (a refused
    /// `kubectl auth can-i`, the pod unread); nil once one did.
    @Published var commandProblem: String?

    /// What a pod offers, in this order.
    static let podCommands: [KubeProcessVerb] = [.shell, .attach, .followLogs]

    /// A pod's tab verbs — its detail's buttons and its right-click menu:
    /// each greyed with why while `kubectl auth can-i` hasn't said yes, or
    /// where the process check refuses it.
    func podVerbs(for ref: KubeObjectRef) -> [ResourceVerb] {
        guard ref.isPod, let context = model.contexts.context(named: ref.context), let namespace = ref.namespace else { return [] }
        return Self.podCommands.map { verb in
            let (title, label, symbol, key): (String, String, String, KubernetesKey) =
                switch verb {
                case .shell: ("Shell in a Tab", "Shell", "apple.terminal", .shell)
                case .attach: ("Attach in a Tab", "Attach", "link", .attach)
                default: ("Follow Logs in a Tab", "Follow", "text.line.last.and.arrowtriangle.forward", .followInTab)
                }
            return ResourceVerb(
                title: title, label: label, symbol: symbol, place: .button, key: key.key, unavailable: unavailable(verb, context, namespace), group: 4
            ) { [weak self] in self?.run(verb, on: ref) }
        }
    }

    /// Why `verb` can't be used on the context's namespace now; nil when it
    /// can. Asks `kubectl auth can-i` when its answer isn't known.
    func unavailable(_ verb: KubeProcessVerb, _ context: KubeContext, _ namespace: String) -> String? {
        let rule = KubeProcessCheck.rule(verb, for: context)
        if let refused = rule.refused { return refused }
        guard let access = rule.access else { return nil }
        let state = model.access.state(context.name, namespace: namespace, access)
        if state == .unknown { model.access.check(context, namespace: namespace, access) }
        return state.unavailable(access, namespace: namespace)
    }

    /// One pod picked in the pod list: what its verbs need asked before the
    /// menu or a key wants them.
    private func askAccess(for ids: Set<String>) {
        guard isPods, ids.count == 1, let id = ids.first, let ref = ref(for: id), let namespace = ref.namespace,
            let context = model.contexts.context(named: ref.context)
        else { return }
        for verb in Self.podCommands {
            let rule = KubeProcessCheck.rule(verb, for: context)
            if rule.allowed, let access = rule.access { model.access.check(context, namespace: namespace, access) }
        }
    }

    /// `e`, `A`, `t`: the pod the detail shows, while it shows one — a
    /// link followed, or back and forward, leaves the list's selection
    /// where it was — else the list's selected pod. A detail on another
    /// kind has no pod to run it in.
    @discardableResult
    func runPodCommand(_ verb: KubeProcessVerb) -> Bool {
        if let detail {
            guard detail.ref.isPod else { return false }
            run(verb, on: detail.ref)
            return true
        }
        guard isPods, let row = rows.first(where: { selection.contains($0.id) }), let ref = ref(for: row.id), ref.isPod else { return false }
        run(verb, on: ref)
        return true
    }

    /// `verb` on the pod: the process check, `kubectl auth can-i`, its
    /// containers read (one GET) and one chosen when there are several, on
    /// production a shell or attach asked first (once per pod and session),
    /// then the command typed into a tab pinned to the context.
    func run(_ verb: KubeProcessVerb, on ref: KubeObjectRef) {
        commandProblem = nil
        guard let context = model.contexts.context(named: ref.context), let namespace = ref.namespace else {
            commandProblem = "No context called \(ref.context)."
            return
        }
        let rule = KubeProcessCheck.rule(verb, for: context)
        if let refused = rule.refused {
            commandProblem = refused
            return
        }
        guard let client = model.client(for: ref.context) else {
            commandProblem = "Kubernetes is off, or the context is gone."
            return
        }
        Task { [weak self] in
            if let access = rule.access {
                let answer = await self?.model.access.answer(context, namespace: namespace, access) ?? .failed("")
                guard let self else { return }
                if let why = KubeAccessState.answered(answer).unavailable(access, namespace: namespace) {
                    self.commandProblem = why
                    return
                }
            }
            let pick: KubeContainerPick
            do {
                let object = try await client.object(ref.kind, namespace: namespace, name: ref.name)
                pick = KubeContainerPick.of(object.json, for: verb)
            } catch {
                self?.commandProblem = "Couldn't read pod \(namespace)/\(ref.name): \(KubernetesModel.said(error))"
                return
            }
            self?.choose(pick, verb, context: context, namespace: namespace, pod: ref.name) { container in
                self?.confirm(verb, rule, context: context, namespace: namespace, pod: ref.name, container: container)
            }
        }
    }

    private func choose(
        _ pick: KubeContainerPick, _ verb: KubeProcessVerb, context: KubeContext, namespace: String, pod: String,
        then: @escaping (String?) -> Void
    ) {
        switch pick {
        case .none: then(nil)
        case .one(let container): then(container)
        case .several(let containers, let chosen):
            actions?.choose(
                "Which container?", "\(verb.title) — pod \(namespace)/\(pod) in \(context.displayName).",
                containers.map { $0 == chosen ? "\($0) (default)" : $0 }
            ) { index in
                guard containers.indices.contains(index) else { return }
                then(containers[index])
            }
        }
    }

    private func confirm(
        _ verb: KubeProcessVerb, _ rule: KubeProcessRule, context: KubeContext, namespace: String, pod: String, container: String?
    ) {
        let open = { [weak self] in self?.open(verb, context: context, namespace: namespace, pod: pod, container: container) }
        // A followed log's tab is a pinned shell once the follow ends: asked
        // once per context, as Terminal in this context would be.
        let consent = verb == .followLogs ? (namespace: "", pod: "") : (namespace: namespace, pod: pod)
        guard rule.confirm, !model.shellConsent.isGranted(verb, context: context.name, namespace: consent.namespace, pod: consent.pod) else {
            open()
            return
        }
        if verb == .followLogs {
            actions?.confirm(
                "Follow a production pod's log in a pinned tab?",
                "PRODUCTION · \(context.name) · namespace \(namespace)\nThe tab follows pod \(namespace)/\(pod)'s log, and is pinned to "
                    + "\(context.displayName): once the follow ends, a plain kubectl, helm or k9s in it goes to \(context.name) — with your own "
                    + "credentials and rights. Overterm's read-only doesn't reach into a terminal. Your current context stays as it is. "
                    + "Asked once for this context this session.",
                "Follow in \(context.displayName)"
            ) { [weak self] in
                self?.model.shellConsent.grant(verb, context: context.name, namespace: consent.namespace, pod: consent.pod)
                open()
            }
            return
        }
        let what = verb == .attach ? "attach to" : "open a shell in"
        let target = "pod \(namespace)/\(pod)" + (container.map { ", container \($0)" } ?? "")
        actions?.confirm(
            "\(verb == .attach ? "Attach to" : "Open a shell in") a production pod?",
            "PRODUCTION · \(context.name) · namespace \(namespace)\nYou are about to \(what) \(target). Inside the container it can do anything "
                + "the container can, with your own credentials. The tab is pinned to \(context.displayName); a plain kubectl there goes to production. "
                + "Asked once per pod this session.",
            verb == .attach ? "Attach in \(context.displayName)" : "Open Shell in \(context.displayName)"
        ) { [weak self] in
            self?.model.shellConsent.grant(verb, context: context.name, namespace: namespace, pod: pod)
            open()
        }
    }

    private func open(_ verb: KubeProcessVerb, context: KubeContext, namespace: String, pod: String, container: String?) {
        do {
            let command = try KubeCommands.command(verb, in: context, namespace: namespace, pod: pod, container: container)
            commandProblem = nil
            actions?.runInTab(command, context, namespace)
        } catch {
            commandProblem = "\(error)"
        }
    }

    // MARK: Terminal in this context

    /// Why the last Terminal in this context didn't open; nil once one did.
    var terminalProblem: String?

    /// The namespace the page shows for the selected context: the tab's,
    /// unless it shows all of them (then the context's own).
    var shownNamespace: String? {
        if case .namespace(let name) = model.scope { return name }
        return nil
    }

    /// A tab pinned to the context shown, in the namespace shown.
    func openTerminal() {
        guard let context = model.selected else { return }
        openTerminal(in: context)
    }

    /// A context card's right-click: the namespace shown for the context
    /// shown, another context's own.
    func openTerminal(in context: KubeContext) {
        actions?.openTerminal(context, context.name == model.selectedName ? shownNamespace : nil)
    }

    /// From a row's menu: a namespace's own row pins that namespace; a
    /// namespaced object's, its namespace; a cluster-wide one's, the one shown.
    func terminalVerb(for picked: [KubeRow]) -> ResourceVerb? {
        guard let context = model.selected, picked.count == 1, let row = picked.first else { return nil }
        let isNamespace = model.kind.fullName == KubeResourceKind.namespaces.fullName
        let namespace = isNamespace ? row.id.name : row.id.namespace ?? shownNamespace
        let title = isNamespace ? "Terminal in This Namespace" : "Terminal in This Context"
        return ResourceVerb(title: title, symbol: "helm", group: 3) { [weak self] in self?.actions?.openTerminal(context, namespace) }
    }
}
