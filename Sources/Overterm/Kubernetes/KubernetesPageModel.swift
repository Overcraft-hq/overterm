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
    case pods, wide, allNamespaces, filter, help

    var section: KubernetesPageModel.Section? { self == .pods ? .pods : nil }

    var key: String {
        switch self {
        case .pods: "1"
        case .wide: "w"
        case .allNamespaces: "0"
        case .filter: "/"
        case .help: "?"
        }
    }

    var title: String {
        switch self {
        case .pods: "Pods"
        case .wide: "Wide columns — what kubectl get -o wide adds (IP, Node…)"
        case .allNamespaces: "All namespaces"
        case .filter: "Filter — web status:crashloopbackoff ns:shop -status:running"
        case .help: "These keys"
        }
    }
}

/// What the Pods filter knows besides text.
enum KubePodFilterKey: ResourceFilterKey {
    case text, namespace, status

    static let names: [String: KubePodFilterKey] = ["ns": .namespace, "namespace": .namespace, "status": .status, "s": .status]
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
    @Published var filter = ""
    /// Rows by `namespace/name` (`KubeRowID.description`).
    @Published var selection: Set<String> = []
    /// Nil: by namespace, then name.
    @Published var sort: ResourceSort?
    /// Every column, `-o wide`'s too (`w`).
    @Published var wide = false
    @Published var cheatSheet = false
    /// The namespace field shows: a name typed, where listing them is refused.
    @Published var typingNamespace = false
    /// Bumped to give the list the keyboard (`focusPageList`), and the filter field.
    @Published private(set) var focusList = 0
    @Published private(set) var focusFilter = 0
    /// Whether the page shows in its window.
    @Published var visible = false
    /// Whether its window is on screen at all.
    @Published var windowVisible = true
    var actions: KubernetesActions?

    let model: KubernetesModel

    init(model: KubernetesModel = .shared) {
        self.model = model
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
            case .wide: wide.toggle()
            case .allNamespaces: model.setScope(.all)
            case .pods, .filter, .help: return false
            }
        }
        return true
    }

    func giveListTheKeyboard() { focusList += 1 }

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

    /// The rows the filter lets through, in the list's order.
    var rows: [KubePodListRow] {
        let columns = model.pods.columns
        let filter = ResourceFilter<KubePodFilterKey>(self.filter)
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
