import Foundation

/// A list's filter kept by name, per context (2.11, "Saved searches"):
/// the context, the kind and the namespace it was saved on, and the
/// filter's text — its `label:` and `field:` words are asked of the server
/// again when it is used. Offered as palette items and in the page's
/// filter menu. Kept in `Kubernetes/filters.json` under the support folder,
/// never in a setting. A filter is names and selectors, never a value read
/// from a cluster.
struct KubeSavedFilter: Codable, Equatable, Identifiable, Sendable {
    /// The kind as it was listed: enough to show it again before the
    /// context's discovery is read; the catalog's own kind once it is.
    struct Kind: Codable, Equatable, Sendable {
        var group: String
        var version: String
        var resource: String
        var kind: String
        var namespaced: Bool

        init(_ kind: KubeResourceKind) {
            group = kind.group
            version = kind.version
            resource = kind.resource
            self.kind = kind.kind
            namespaced = kind.namespaced
        }

        var fullName: String { group.isEmpty ? resource : "\(resource).\(group)" }

        var resourceKind: KubeResourceKind {
            KubeResourceKind(
                group: group, version: version, resource: resource, kind: kind, singular: kind.lowercased(), namespaced: namespaced,
                verbs: ["get", "list", "watch"])
        }
    }

    var id = UUID()
    var name: String
    var context: String
    var kind: Kind
    /// The namespace it was saved in — of several, the first, so an older
    /// build reads one it can list; nil, all of them.
    var namespace: String?
    var filter: String
    /// Every namespace it was saved in, when several; nil for one or all
    /// (an older build's file has no such field, and ignores it).
    var namespaces: [String]?

    /// Where it shows: its namespaces, else its one, else all of them.
    var scope: KubeScope {
        if let namespaces, !namespaces.isEmpty { return .of(namespaces) }
        return namespace.map { .namespace($0) } ?? .all
    }

    /// `Deployments · shop · fake-dev`; several, `shop +1`.
    var said: String {
        [kind.kind.isEmpty ? kind.resource : kind.kind, namespace == nil ? "all namespaces" : scope.title, context].joined(separator: " · ")
    }
}

extension KubeSavedFilter {
    /// Saved in `scope`: one namespace or several (the first as
    /// `namespace` too), none for all of them or a cluster-scoped kind.
    init(id: UUID = UUID(), name: String, context: String, kind: Kind, scope: KubeScope, filter: String) {
        let names = kind.namespaced ? scope.names : nil
        self.init(
            id: id, name: name, context: context, kind: kind, namespace: names?.first, filter: filter,
            namespaces: (names?.count ?? 0) > 1 ? names : nil)
    }
}

@MainActor
final class KubeSavedFilters: ObservableObject {
    static let shared = KubeSavedFilters(file: defaultFile)

    /// The support folder's — a unit test's own in the temporary directory.
    static var defaultFile: URL {
        let base =
            AppEnvironment.isUnitTest && !AppEnvironment.isIsolated
            ? FileManager.default.temporaryDirectory.appendingPathComponent("overterm-unit-test-\(getpid())", isDirectory: true)
            : AppEnvironment.supportDirectory
        return base.appendingPathComponent("Kubernetes/filters.json")
    }

    let file: URL
    @Published private(set) var filters: [KubeSavedFilter] = []
    /// What couldn't be written, said plainly.
    @Published private(set) var problem: String?

    /// Read here, once — a small file —, so reading the filters (a view's
    /// body, the palette's items) never publishes.
    init(file: URL) {
        self.file = file
        load()
    }

    var all: [KubeSavedFilter] { filters }

    /// A context's, by name.
    func filters(on context: String) -> [KubeSavedFilter] {
        all.filter { $0.context == context }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Kept — in place of one of the same name on the same context.
    @discardableResult
    func save(_ filter: KubeSavedFilter) -> Bool {
        var filter = filter
        filter.name = filter.name.trimmingCharacters(in: .whitespacesAndNewlines)
        filter.filter = filter.filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.name.isEmpty, !filter.filter.isEmpty, !filter.context.isEmpty else { return false }
        if let index = filters.firstIndex(where: { $0.context == filter.context && $0.name == filter.name }) {
            filter.id = filters[index].id
            filters[index] = filter
        } else {
            filters.append(filter)
        }
        write()
        return true
    }

    func remove(_ id: UUID) {
        guard filters.contains(where: { $0.id == id }) else { return }
        filters.removeAll { $0.id == id }
        write()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        if let data = try? Data(contentsOf: file), let read = try? JSONDecoder().decode([KubeSavedFilter].self, from: data) {
            filters = read
        } else {
            // Set aside: the next save would write over what was in it.
            UnreadableFile.setAside(file)
        }
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(filters).write(to: file, options: .atomic)
            problem = nil
        } catch {
            problem = "Couldn't save the filters to \(file.path): \(error.localizedDescription)"
        }
    }
}
