import Combine
import Foundation

// MARK: A checkout tied to what it deploys (docs/design/kubernetes/analysis.md, 3.1)

/// A checkout bound to the context, namespace and workloads (or Helm
/// release) it deploys to: the scope the rail panel shows, the deployed
/// commit is read for, Ask Why's brief goes back to and the agents' tools
/// default to. Kept in Overterm's support folder (`KubeBindingStore`),
/// keyed by the checkout's root — never in the repository.
struct KubeBinding: Codable, Equatable, Sendable, Identifiable {
    /// The checkout's root, its real path: the key.
    var checkout: String
    var context: String
    var namespace: String
    /// A Helm release the checkout's chart is installed as.
    var release: String?
    /// A label selector narrowing the namespace to the checkout's own
    /// (`app.kubernetes.io/part-of=shop`); nil for every workload there.
    var selector: String?
    /// The workloads the checkout deploys (`deploy/web`, `sts/db`, `ds/agent`);
    /// empty for every one the selector picks.
    var workloads: [String] = []

    var id: String { checkout }

    /// `fake-dev · shop`, with the release when there is one.
    var said: String { "\(context) · \(namespace)" + (release.map { " · release \($0)" } ?? "") }

    /// Whether `kind`/`name` is one of the bound workloads.
    func includes(_ kind: KubeWorkloadKind, _ name: String) -> Bool {
        workloads.isEmpty || workloads.contains { KubeWorkloadRef(parsing: $0) == KubeWorkloadRef(kind: kind, name: name) }
    }

    /// The same binding with its fields trimmed and emptied ones nil; nil
    /// when no context or namespace is left.
    func cleaned() -> KubeBinding? {
        func trimmed(_ value: String?) -> String? {
            value.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let context = trimmed(context), let namespace = trimmed(namespace), KubeMCPText.isName(namespace) else { return nil }
        var seen = Set<String>()
        let workloads = self.workloads.compactMap { KubeWorkloadRef(parsing: $0)?.said }.filter { seen.insert($0).inserted }
        return KubeBinding(
            checkout: checkout, context: context, namespace: namespace, release: trimmed(release), selector: trimmed(selector), workloads: workloads)
    }
}

/// The workload kinds a binding names, by kubectl's short names.
enum KubeWorkloadKind: String, Codable, Sendable, CaseIterable {
    case deployment = "deploy"
    case statefulSet = "sts"
    case daemonSet = "ds"

    var kind: KubeResourceKind {
        switch self {
        case .deployment: .deployments
        case .statefulSet: .statefulSets
        case .daemonSet: .daemonSets
        }
    }

    /// From a manifest's `kind:`.
    init?(manifestKind: String) {
        switch manifestKind {
        case "Deployment": self = .deployment
        case "StatefulSet": self = .statefulSet
        case "DaemonSet": self = .daemonSet
        default: return nil
        }
    }

    /// From what a person types: `deploy`, `deployment`, `deployments`, `sts`…
    init?(typed: String) {
        switch typed.lowercased() {
        case "deploy", "deployment", "deployments", "deployments.apps": self = .deployment
        case "sts", "statefulset", "statefulsets", "statefulsets.apps": self = .statefulSet
        case "ds", "daemonset", "daemonsets", "daemonsets.apps": self = .daemonSet
        default: return nil
        }
    }
}

/// `deploy/web`: a workload a binding names.
struct KubeWorkloadRef: Hashable, Sendable {
    var kind: KubeWorkloadKind
    var name: String

    init(kind: KubeWorkloadKind, name: String) {
        self.kind = kind
        self.name = name
    }

    init?(parsing text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let kind = KubeWorkloadKind(typed: String(parts[0])), KubeMCPText.isName(String(parts[1])) else { return nil }
        self.init(kind: kind, name: String(parts[1]))
    }

    var said: String { "\(kind.rawValue)/\(name)" }
}

// MARK: Where they are kept

/// Every checkout's binding, in `Kubernetes/bindings.json` under
/// `AppEnvironment.supportDirectory` — an isolated run's own folder there
/// — keyed by the checkout's real path. Read once, on first use; written
/// whole on each change. Never anything in the repository, and no secret.
@MainActor
final class KubeBindingStore: ObservableObject {
    /// The app's: the support folder's (an isolated run's own); a unit
    /// test's, a temporary folder — never the user's bindings.
    static let shared = KubeBindingStore(file: defaultFile)

    nonisolated static var defaultFile: URL {
        let folder =
            AppEnvironment.isUnitTest && !AppEnvironment.isIsolated
            ? FileManager.default.temporaryDirectory.appendingPathComponent("overterm-unit-bindings-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            : AppEnvironment.supportDirectory.appendingPathComponent("Kubernetes", isDirectory: true)
        return folder.appendingPathComponent("bindings.json")
    }

    let file: URL
    @Published private(set) var bindings: [String: KubeBinding] = [:]
    /// What couldn't be read or written, said plainly.
    @Published private(set) var problem: String?
    private var loaded = false

    init(file: URL) {
        self.file = file
    }

    /// The key a checkout is kept under: its real path.
    nonisolated static func key(_ checkout: URL) -> String { FileTreeModel.realPath(checkout.standardizedFileURL) }

    func binding(for checkout: URL?) -> KubeBinding? {
        guard let checkout else { return nil }
        loadIfNeeded()
        return bindings[Self.key(checkout)]
    }

    /// Every checkout bound to `context` and `namespace`.
    func bindings(on context: String, namespace: String?) -> [KubeBinding] {
        loadIfNeeded()
        return bindings.values.filter { $0.context == context && (namespace == nil || $0.namespace == namespace) }.sorted { $0.checkout < $1.checkout }
    }

    /// The checkout bound to `context`/`namespace` that a brief speaks
    /// for: `preferred` (the selected tab's, the calling pane's) when it
    /// is bound there — several worktrees of one repository are often
    /// bound to one namespace — else the first.
    func binding(on context: String, namespace: String, preferring preferred: KubeBinding?) -> KubeBinding? {
        if let preferred, preferred.context == context, preferred.namespace == namespace { return preferred }
        return bindings(on: context, namespace: namespace).first
    }

    /// Binds (or binds again) a checkout; a binding without a context or
    /// namespace is refused.
    @discardableResult
    func set(_ binding: KubeBinding) -> Bool {
        loadIfNeeded()
        guard var cleaned = binding.cleaned() else {
            problem = "A binding needs a context and a namespace."
            return false
        }
        cleaned.checkout = Self.key(URL(fileURLWithPath: binding.checkout))
        bindings[cleaned.checkout] = cleaned
        save()
        return true
    }

    func remove(_ checkout: URL) {
        loadIfNeeded()
        guard bindings.removeValue(forKey: Self.key(checkout)) != nil else { return }
        save()
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: file) else { return }
        do {
            let list = try JSONDecoder().decode(Saved.self, from: data)
            bindings = Dictionary(list.bindings.map { ($0.checkout, $0) }, uniquingKeysWith: { _, last in last })
        } catch {
            problem = "\(file.lastPathComponent) couldn't be read: \(error.localizedDescription)"
        }
    }

    /// Read again from the file (a test's, a scenario's).
    func reload() {
        loaded = false
        bindings = [:]
        loadIfNeeded()
    }

    private struct Saved: Codable {
        var version = 1
        var bindings: [KubeBinding]
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(Saved(bindings: bindings.values.sorted { $0.checkout < $1.checkout }))
            try data.write(to: file, options: .atomic)
            problem = nil
        } catch {
            problem = "\(file.lastPathComponent) couldn't be written: \(error.localizedDescription)"
        }
    }
}

// MARK: What the checkout says (pure)

/// A Kubernetes file found in a checkout, by what it is.
enum KubeCheckoutFileKind: String, Sendable, Equatable, CaseIterable {
    case chart = "Chart.yaml"
    case kustomization = "kustomization.yaml"
    case manifest
    case skaffold = "skaffold.yaml"
    case tiltfile = "Tiltfile"
    case helmfile = "helmfile.yaml"

    /// What a file's name says it is; nil for one that isn't any (a plain
    /// YAML is a manifest only once its text says `apiVersion` and `kind`).
    static func named(_ name: String) -> KubeCheckoutFileKind? {
        switch name {
        case "Chart.yaml", "Chart.yml": .chart
        case "kustomization.yaml", "kustomization.yml", "Kustomization": .kustomization
        case "skaffold.yaml", "skaffold.yml": .skaffold
        case "Tiltfile": .tiltfile
        case "helmfile.yaml", "helmfile.yml", "helmfile.yaml.gotmpl": .helmfile
        default: nil
        }
    }
}

/// One file read: its path in the checkout and its text.
struct KubeCheckoutFile: Equatable, Sendable {
    var path: String
    var kind: KubeCheckoutFileKind
    var text: String
}

/// What Overterm guesses a checkout deploys, from its files (3.1): the
/// chart's name as the release, the kustomization's `namespace:`, the
/// manifests' `metadata.namespace`, their workloads, and a label such as
/// `app.kubernetes.io/part-of`. A guess — the user confirms it and picks
/// the context.
struct KubeBindingGuess: Equatable, Sendable {
    /// The files that told something, by path in the checkout.
    var files: [String] = []
    var kinds: Set<KubeCheckoutFileKind> = []
    var release: String?
    var namespace: String?
    var selector: String?
    var workloads: [String] = []

    var isEmpty: Bool { files.isEmpty }

    /// The files' words: `Chart.yaml, 2 manifests`.
    var said: String {
        var words: [String] = []
        for kind in KubeCheckoutFileKind.allCases where kinds.contains(kind) {
            let count = filesOf(kind)
            switch kind {
            case .manifest: words.append("\(count) manifest" + (count == 1 ? "" : "s"))
            default: words.append(kind.rawValue)
            }
        }
        return words.joined(separator: ", ")
    }

    private var counts: [KubeCheckoutFileKind: Int] = [:]
    private func filesOf(_ kind: KubeCheckoutFileKind) -> Int { counts[kind] ?? 0 }

    /// The guess from the files read, in the order they came (the nearest
    /// the checkout's top first).
    static func from(_ files: [KubeCheckoutFile]) -> KubeBindingGuess {
        var guess = KubeBindingGuess()
        var namespaces: [String: Int] = [:]
        var partOf: [String: Int] = [:]
        var kustomized: String?
        var workloads: [String] = []
        for file in files {
            switch file.kind {
            case .chart:
                guard let chart = YAMLReader.parse(file.text) as? [String: Any], let name = chart["name"] as? String, KubeMCPText.isName(name) else { continue }
                if guess.release == nil { guess.release = name }
                guess.note(file)
            case .kustomization:
                let object = YAMLReader.parse(file.text) as? [String: Any]
                if kustomized == nil, let namespace = object?["namespace"] as? String, KubeMCPText.isName(namespace) { kustomized = namespace }
                guess.note(file)
            case .manifest:
                var told = false
                for case let object as [String: Any] in YAMLReader.documents(file.text) ?? [] {
                    guard object["apiVersion"] is String, let kind = object["kind"] as? String else { continue }
                    told = true
                    let metadata = object["metadata"] as? [String: Any] ?? [:]
                    if let namespace = metadata["namespace"] as? String, KubeMCPText.isName(namespace) { namespaces[namespace, default: 0] += 1 }
                    let labels = metadata["labels"] as? [String: Any] ?? [:]
                    if let part = labels["app.kubernetes.io/part-of"] as? String, !part.isEmpty { partOf[part, default: 0] += 1 }
                    if let workload = KubeWorkloadKind(manifestKind: kind), let name = metadata["name"] as? String, KubeMCPText.isName(name) {
                        workloads.append(KubeWorkloadRef(kind: workload, name: name).said)
                    }
                }
                if told { guess.note(file) }
            case .skaffold, .tiltfile, .helmfile:
                guess.note(file)
            }
        }
        func most(_ counts: [String: Int]) -> String? { counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key }
        guess.namespace = kustomized ?? most(namespaces)
        if let part = most(partOf) {
            guess.selector = "app.kubernetes.io/part-of=\(part)"
        } else if let release = guess.release {
            // Helm's own convention: a release's objects carry its name.
            guess.selector = "app.kubernetes.io/instance=\(release)"
        }
        var seen = Set<String>()
        guess.workloads = workloads.filter { seen.insert($0).inserted }
        return guess
    }

    private mutating func note(_ file: KubeCheckoutFile) {
        files.append(file.path)
        kinds.insert(file.kind)
        counts[file.kind, default: 0] += 1
    }

    /// The guess as a binding of `checkout` to `context`.
    func binding(checkout: URL, context: String) -> KubeBinding {
        KubeBinding(
            checkout: KubeBindingStore.key(checkout), context: context, namespace: namespace ?? "default", release: release, selector: selector,
            workloads: workloads)
    }
}

// MARK: Reading the checkout (bounded)

/// The checkout's Kubernetes files, found by a bounded walk down from its
/// root: hidden folders, `node_modules`, `vendor` and the like passed over,
/// at most `maxDepth` folders deep and `maxEntries` entries looked at, at
/// most `maxFiles` files read, each up to `maxBytes`. A YAML inside a
/// chart (its walk up finds the chart's `Chart.yaml`) is a template, not
/// a manifest, and isn't read. Runs off the main thread.
enum KubeCheckoutScan {
    static let maxDepth = 5
    static let maxEntries = 5000
    static let maxFiles = 120
    static let maxBytes = 256 << 10
    static let skipped: Set<String> = [
        "node_modules", "vendor", "target", "build", "dist", "Pods", "DerivedData", "venv", "__pycache__", "Library",
    ]

    /// Whether `folder` is a checkout the guess may read: a git
    /// repository's root (its `.git`, a folder or a worktree's file) —
    /// never the home folder or `/`, whatever they hold. Any other folder
    /// a tab sits in is not walked: from `~` the walk would reach
    /// Desktop, Documents and Downloads (privacy prompts), other apps'
    /// containers and iCloud's placeholders, and read what manifests it
    /// found there.
    nonisolated static func isRepositoryRoot(
        _ folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        let real = URL(fileURLWithPath: FileTreeModel.realPath(folder.standardizedFileURL))
        guard real.pathComponents.count > 1 else { return false }
        let homes = [home.standardizedFileURL.path, FileTreeModel.realPath(home.standardizedFileURL)]
        guard !homes.contains(real.path), !homes.contains(folder.standardizedFileURL.path) else { return false }
        return exists(real.appendingPathComponent(".git").path)
    }

    nonisolated static func files(in root: URL) -> [KubeCheckoutFile] {
        let manager = FileManager.default
        let base = root.standardizedFileURL
        var found: [KubeCheckoutFile] = []
        var entries = 0
        // Breadth first: the files nearest the top come first.
        var folders: [(URL, Int)] = [(base, 0)]
        while !folders.isEmpty, found.count < maxFiles, entries < maxEntries {
            let (folder, depth) = folders.removeFirst()
            guard
                let names = try? manager.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles])
            else { continue }
            for url in names.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                entries += 1
                guard entries < maxEntries, found.count < maxFiles else { break }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                if values?.isSymbolicLink == true { continue }
                let name = url.lastPathComponent
                if values?.isDirectory == true {
                    if depth + 1 <= maxDepth, !skipped.contains(name) { folders.append((url, depth + 1)) }
                    continue
                }
                guard (values?.fileSize ?? 0) <= maxBytes else { continue }
                let named = KubeCheckoutFileKind.named(name)
                let isYAML = name.hasSuffix(".yaml") || name.hasSuffix(".yml")
                guard named != nil || isYAML else { continue }
                // A chart's templates are Go templates, not manifests.
                if named == nil, chartRoot(of: url, within: base) != nil { continue }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let kind = named ?? .manifest
                if kind == .manifest, !(text.contains("apiVersion:") && text.contains("kind:")) { continue }
                let relative = String(url.standardizedFileURL.path.dropFirst(base.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                found.append(KubeCheckoutFile(path: relative, kind: kind, text: text))
            }
        }
        return found
    }

    /// The chart a file is part of: the nearest folder above it (up to the
    /// checkout's root) holding a `Chart.yaml`. The walk stops at the root,
    /// at `pathComponents.count <= 1`, and after `maxDepth * 4` steps
    /// (CLAUDE.md: never walk up comparing with "/").
    nonisolated static func chartRoot(
        of file: URL, within root: URL, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        let top = root.standardizedFileURL.pathComponents
        var folder = file.standardizedFileURL.deletingLastPathComponent()
        for _ in 0..<(maxDepth * 4) {
            let components = folder.pathComponents
            guard components.count > 1, components.count >= top.count, Array(components.prefix(top.count)) == top else { return nil }
            if exists(folder.appendingPathComponent("Chart.yaml").path) { return folder }
            guard components.count > top.count else { return nil }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }

    /// The guess for a checkout, read now (off the main thread); nothing
    /// read, and nothing guessed, for a folder that isn't a repository's
    /// root (`isRepositoryRoot`).
    static func guess(_ root: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> KubeBindingGuess {
        await KubeBlocking.run { isRepositoryRoot(root, home: home) ? KubeBindingGuess.from(files(in: root)) : KubeBindingGuess() }
    }
}
