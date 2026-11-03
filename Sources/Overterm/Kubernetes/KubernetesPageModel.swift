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
}

/// The Kubernetes lists' keys (`ResourceKey`), only while the list has the
/// keyboard. More join with their stages (docs/design/kubernetes/analysis.md,
/// Section 7); none of these changes a cluster. Pure.
enum KubernetesKey: String, ResourceKey {
    case pods, namespace, context, wide, allNamespaces, filter, help

    var section: KubernetesPageModel.Section? { self == .pods ? .pods : nil }

    var key: String {
        switch self {
        case .pods: "1"
        case .namespace: "n"
        case .context: "c"
        case .wide: "w"
        case .allNamespaces: "0"
        case .filter: "/"
        case .help: "?"
        }
    }

    var title: String {
        switch self {
        case .pods: "Pods"
        case .namespace: "Namespace — one listed, or a name typed"
        case .context: "Context"
        case .wide: "Wide columns — what kubectl get -o wide adds (IP, Node…)"
        case .allNamespaces: "All namespaces"
        case .filter: "Filter — web status:crashloopbackoff ns:shop -status:running label:app=web"
        case .help: "These keys"
        }
    }
}

/// One row of the Pods list: the server's row, and what its cells say of the pod.
struct KubePodListRow: ResourceTableRow {
    let row: KubeRow
    let summary: KubePodSummary?

    var id: String { row.id.description }
    var height: CGFloat { 26 }
}

/// A window's Kubernetes page: which section, what the filter says, what is
/// selected, how the list is sorted. The contexts and the pods are the app's
/// (`KubernetesModel`).
@MainActor
final class KubernetesPageModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case pods

        var id: String { rawValue }
        var title: String { "Pods" }
        var symbol: String { "cube.box" }
    }

    @Published var section: Section = .pods
    /// What the filter field says. Its `label:` words go to the server
    /// (`KubeLabelSelector`), a moment after the typing stops.
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
                model.releaseLabelSelector(for: self)
            }
        }
    }
    /// Whether its window is on screen at all.
    @Published var windowVisible = true
    var actions: KubernetesActions?

    let model: KubernetesModel
    /// How long the typing must stop before `label:` asks the server again.
    var selectorDelay: Duration = .milliseconds(350)
    private var selecting: Task<Void, Never>?
    private var pickerWatch: AnyCancellable?

    init(model: KubernetesModel = .shared) {
        self.model = model
        // A picker that shows follows what comes in: the namespaces listed
        // after it opened, the kubeconfig read again. The emitted values:
        // the model's properties aren't set yet.
        pickerWatch = model.$namespaces.map { _ in () }.merge(with: model.$namespacesRefused.map { _ in () }, model.$contexts.map { _ in () })
            .dropFirst()
            .sink { [weak self] in DispatchQueue.main.async { self?.refreshPicker() } }
    }

    // MARK: Keys

    /// A key down while the list has the keyboard: true when it meant something.
    func press(_ characters: String) -> Bool {
        guard let press = KubernetesKey.press(characters, sheetShowing: cheatSheet) else { return false }
        switch press {
        case .closeSheet: cheatSheet = false
        case .section(let section): self.section = section
        case .help: cheatSheet = true
        case .filter: focusFilter += 1
        case .key(let key):
            switch key {
            case .namespace: openPicker(.namespace)
            case .context: openPicker(.context)
            case .wide: wide.toggle()
            case .allNamespaces: model.setScope(.all)
            case .pods, .filter, .help: return false
            }
        }
        return true
    }

    func giveListTheKeyboard() { focusList += 1 }

    /// The keyboard to the list, unless something has it (the filter, the palette).
    func offerListTheKeyboard() { offerList += 1 }

    // MARK: The pickers

    /// `n` or `c`: the picker, on what shows now.
    func openPicker(_ kind: KubePicker.Kind) {
        cheatSheet = false
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
        model.setLabelSelector(labelReading.selector, for: self)
    }

    /// Whether the list is the one this page's filter asks for: false while
    /// another window's page, showing too, asked last with its own `label:`.
    var listIsOurs: Bool { model.isSelector(labelReading.selector, of: self) }

    // MARK: What the page says

    /// The red band over the whole page on a production context; nil elsewhere.
    var band: String? {
        guard let context = model.selected, context.isProduction else { return nil }
        return "PRODUCTION · \(context.displayName) · read-only: Overterm changes nothing here"
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
    /// Namespace column first, as `kubectl get -A` adds it.
    var columns: [ResourceColumn] {
        var columns = model.pods.columns.enumerated().filter { wide || $0.element.priority == 0 }.map { index, column in
            ResourceColumn(
                id: "c\(index)", title: column.name, width: Self.width(of: column.name), minWidth: 40,
                help: column.description.isEmpty ? nil : column.description)
        }
        if model.scope == .all, !columns.isEmpty {
            columns.insert(ResourceColumn(id: Self.namespaceColumn, title: "Namespace", width: 150), at: 0)
        }
        return columns
    }

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
        guard id.hasPrefix("c"), let index = Int(id.dropFirst()), model.pods.columns.indices.contains(index) else { return nil }
        return (index, model.pods.columns[index])
    }

    /// The rows the filter lets through, in the list's order. `label:` is
    /// the server's: the rows came filtered by it — or by another page's,
    /// which the page says (`listIsOurs`).
    var rows: [KubePodListRow] {
        let columns = model.pods.columns
        var filter = ResourceFilter<KubePodFilterKey>(self.filter)
        filter.terms.removeAll { $0.key == .label }
        let rows = model.pods.sorted.map { KubePodListRow(row: $0, summary: KubePodSummary(row: $0, columns: columns)) }
            .filter { Self.matches($0, filter) }
        guard let sort else { return rows }
        let now = Date()
        return sort.sorted(rows) { sortKey($0, sort.column, now: now) }
    }

    /// Every pod that fails, with why — whatever the filter shows.
    var failing: [KubePodSummary] {
        let columns = model.pods.columns
        return model.pods.sorted.compactMap { KubePodSummary(row: $0, columns: columns) }.filter(\.isFailing)
    }

    static func matches(_ row: KubePodListRow, _ filter: ResourceFilter<KubePodFilterKey>) -> Bool {
        filter.matches { term in
            let namespace = row.row.id.namespace?.lowercased() ?? ""
            let status = row.summary?.status.lowercased() ?? ""
            switch term.key {
            case .text: return row.row.id.name.lowercased().contains(term.value) || namespace.contains(term.value) || status.contains(term.value)
            case .namespace: return namespace == term.value
            case .status: return status.contains(term.value)
            case .label: return true
            }
        }
    }

    /// What a column sorts a row by: numbers as numbers, ages by age, text as text.
    enum SortKey: Comparable {
        case number(Double)
        case text(String)
    }

    func sortKey(_ row: KubePodListRow, _ id: String, now: Date) -> SortKey? {
        if id == Self.namespaceColumn { return row.row.id.namespace.map { .text($0) } }
        guard let (index, column) = column(id), index < row.row.cells.count else { return nil }
        switch column.name.lowercased() {
        case "age": return age(of: row.row.id, at: now).map { .number($0) }
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

    /// The right-click menu: only what reads — this page changes nothing.
    func verbs(for ids: Set<String>) -> [ResourceVerb] {
        let picked = model.pods.sorted.filter { ids.contains($0.id.description) }
        guard !picked.isEmpty else { return [] }
        let names = picked.map(\.id.name).joined(separator: "\n")
        let qualified = picked.map { $0.id.description }.joined(separator: "\n")
        return [
            ResourceVerb(title: picked.count == 1 ? "Copy Name" : "Copy Names", symbol: "doc.on.doc") { [weak self] in self?.actions?.copy(names) },
            ResourceVerb(title: "Copy Namespace/Name", symbol: "doc.on.doc") { [weak self] in self?.actions?.copy(qualified) },
        ]
    }
}
