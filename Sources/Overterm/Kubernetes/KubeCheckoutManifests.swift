import Darwin
import Foundation
import TreeSitterKit

/// What a checkout's committed manifests name (docs/design/kubernetes/
/// gitops.md, 14.2.5, option B): each document's `apiVersion`, `kind`,
/// `metadata.name` and `metadata.namespace` — nothing else of it is read —
/// to set beside the tracking ids on a cluster's objects, which say the
/// same four things of the object they sit on.
///
/// The files are the tracked `*.yaml` and `*.yml` (`git ls-files`, through
/// the rail's isolated git), at most 2,000 of them, each at most 256 KB and
/// 32 MB in all. Each is opened `O_NOFOLLOW` — a committed link is never
/// followed — and must be inside the checkout once opened (`F_GETPATH`), so
/// a folder linked out can't make it read elsewhere; a FIFO or anything but
/// a plain file isn't read. Files under `test/`, `tests/`, `testdata/`,
/// `examples/`, `fixtures/` and `vendor/` are skipped and counted. A file
/// holding `{{` that the grammar can't read is a Helm template, counted:
/// what it names is only known rendered; in one it reads, only a document
/// whose four keys hold `{{` is left out (its file counted a template) —
/// a PrometheusRule's quoted `{{ $labels.pod }}`, a dashboard's or an
/// ApplicationSet's, beside a Deployment leaves both compared.
///
/// A document is read by the YAML grammar's tree, its top-level keys and
/// `metadata`'s alone — never walked deeper, so no file's nesting or
/// aliases cost more than its parse; an alias where one of the four should
/// be leaves the document out. A kustomization's `namePrefix` or
/// `nameSuffix` is counted: the names it builds aren't the files'. The
/// cluster's strings this is compared with are compared in memory only;
/// nothing here reaches git but `ls-files`' own patterns. Blocking: run
/// off the main thread (`KubeBlocking.run`).
enum KubeCheckoutManifests {
    struct Bounds: Sendable {
        var files = 2_000
        var fileBytes = 256 << 10
        var totalBytes = 32 << 20
    }

    /// One object a document names.
    struct Identity: Hashable, Sendable, Comparable {
        /// "" for the core group.
        var group: String
        var kind: String
        /// nil: the document names none — kustomize's or Argo CD's
        /// destination gives it one, which can't be read here.
        var namespace: String?
        var name: String

        /// `Deployment shop/api`, or `Deployment api` without a namespace.
        var said: String { "\(kind) \(namespace.map { "\($0)/" } ?? "")\(name)" }

        static func < (a: Identity, b: Identity) -> Bool {
            (a.group, a.kind, a.namespace ?? "", a.name) < (b.group, b.kind, b.namespace ?? "", b.name)
        }
    }

    /// What was read, and what couldn't be.
    struct Read: Equatable, Sendable {
        var identities: Set<Identity> = []
        /// Every document's `metadata.name`, lowercased, by the namespace it
        /// names ("" for none): what an app's name is compared with (option
        /// C) — one with no namespace only in the binding's, as option B.
        var names: [String: Set<String>] = [:]
        /// The folders right under `apps/`, `deploy/`, `k8s/`, `charts/` and
        /// `manifests/`, lowercased (option C).
        var folders: Set<String> = []
        /// Tracked `.yaml` and `.yml` files.
        var files = 0
        /// Files read whole.
        var read = 0
        /// Documents that named an object: compared.
        var documents = 0
        /// Helm templates, not rendered: files holding `{{` the grammar
        /// can't read, and those it reads with a document whose four keys
        /// hold `{{` (left out).
        var templates = 0
        /// Kustomizations with a `namePrefix` or `nameSuffix`.
        var prefixed = 0
        /// Under a test, example, fixture or vendored folder.
        var skipped = 0
        /// A link, or a path that led out of the checkout once opened.
        var links = 0
        /// Not a plain file, over 256 KB, or not YAML the grammar reads whole.
        var unreadable = 0
        /// The bound that stopped the read, said.
        var cut: String?
        /// `git ls-files` couldn't say.
        var failed: String?
    }

    static let skippedFolders: Set<String> = ["test", "tests", "testdata", "examples", "fixtures", "vendor"]
    static let nameFolders: Set<String> = ["apps", "deploy", "k8s", "charts", "manifests"]

    /// `git ls-files`' arguments: the tracked YAML, NUL-separated.
    static let listArguments = ["ls-files", "-z", "--", "*.yaml", "*.yml"]

    /// The checkout's manifests: listed by its git, read off the main thread.
    static func read(_ root: URL, git: @escaping KubeGitOpsCheckouts.Runner, bounds: Bounds = Bounds()) async -> Read {
        let listed: String
        do {
            listed = try await git(listArguments, root, [0])
        } catch {
            var read = Read()
            read.failed = "the checkout's files couldn't be listed"
            return read
        }
        let paths = listed.split(separator: "\u{0}", omittingEmptySubsequences: true).map(String.init)
        return await KubeBlocking.run { read(root, paths: paths, bounds: bounds) }
    }

    /// The files given read, in their order, within `bounds`. Blocking.
    static func read(_ root: URL, paths: [String], bounds: Bounds = Bounds()) -> Read {
        var read = Read()
        read.files = paths.count
        guard let top = real(root.path) else {
            read.failed = "the checkout can't be read"
            return read
        }
        var total = 0
        var taken = 0
        for path in paths {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !parts.isEmpty, !parts.contains(".."), !path.hasPrefix("/") else {
                read.unreadable += 1
                continue
            }
            if parts.dropLast().contains(where: { skippedFolders.contains($0.lowercased()) }) {
                read.skipped += 1
                continue
            }
            guard taken < bounds.files else {
                read.cut = "\(bounds.files.formatted()) of \(paths.count.formatted()) manifest files read"
                break
            }
            guard total < bounds.totalBytes else {
                read.cut = "\(bounds.totalBytes >> 20) MB of the checkout's manifests read"
                break
            }
            taken += 1
            for (index, part) in parts.dropLast().enumerated() where nameFolders.contains(part.lowercased()) && index + 1 < parts.count - 1 {
                read.folders.insert(parts[index + 1].lowercased())
            }
            switch file(top, path, limit: bounds.fileBytes, left: bounds.totalBytes - total) {
            case .link:
                read.links += 1
            case .unreadable:
                read.unreadable += 1
            case .past:
                read.cut = "\(bounds.totalBytes >> 20) MB of the checkout's manifests read"
                return read
            case .read(let data):
                total += data.count
                read.read += 1
                let text = String(decoding: data, as: UTF8.self)
                // Parsed first: `{{` in a quoted string (an alert's
                // description, a dashboard's legend) leaves the file YAML.
                guard let documents = documents(text) else {
                    if text.contains("{{") { read.templates += 1 } else { read.unreadable += 1 }
                    continue
                }
                // kustomize's own file, its apiVersion and kind often left out.
                let kustomization = ["kustomization.yaml", "kustomization.yml"].contains(parts[parts.count - 1].lowercased())
                for document in documents where !document.templated { take(document, kustomization: kustomization, into: &read) }
                if documents.contains(where: \.templated) { read.templates += 1 }
            }
        }
        return read
    }

    private static func take(_ document: Document, kustomization: Bool, into read: inout Read) {
        let kustomize = document.apiVersion?.hasPrefix("kustomize.config.k8s.io/") == true && (document.kind == "Kustomization" || document.kind == "Component")
        if kustomization || kustomize {
            if document.prefixed { read.prefixed += 1 }
            return
        }
        guard let kind = document.kind, let apiVersion = document.apiVersion else { return }
        guard kind != "List", let name = document.name, KubeTrackingID.isSubdomain(name), isKind(kind) else { return }
        let group = apiVersion.contains("/") ? String(apiVersion.split(separator: "/", omittingEmptySubsequences: false)[0]) : ""
        guard group.isEmpty || KubeTrackingID.isSubdomain(group) else { return }
        var namespace: String?
        if let named = document.namespace {
            guard KubeTrackingID.isLabel(named) else { return }
            namespace = named
        }
        read.identities.insert(Identity(group: group, kind: kind, namespace: namespace, name: name))
        read.names[namespace ?? "", default: []].insert(name.lowercased())
        read.documents += 1
    }

    private static func isKind(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 63 && text.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }

    // MARK: One file

    private enum File {
        case read(Data)
        case link
        case unreadable
        /// Within its own bound, past what is left of the whole's.
        case past
    }

    /// `path` under `top` opened without following a link, inside `top`
    /// once open, a plain file of at most `limit` bytes and `left` of the
    /// whole read.
    private static func file(_ top: String, _ path: String, limit: Int, left: Int) -> File {
        let full = top + "/" + path
        let fd = open(full, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return errno == ELOOP ? .link : .unreadable }
        defer { close(fd) }
        guard let opened = KubeCheckoutManifests.path(of: fd), opened.hasPrefix(top + "/") else { return .link }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return .unreadable }
        guard info.st_size <= off_t(limit) else { return .unreadable }
        guard info.st_size <= off_t(left) else { return .past }
        var data = Data(count: Int(info.st_size))
        var got = 0
        let size = data.count
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return size == 0 }
            while got < size {
                let n = Darwin.read(fd, base.advanced(by: got), size - got)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return false }
                got += n
            }
            return true
        }
        return ok ? .read(data) : .unreadable
    }

    /// The path an open descriptor names now.
    private static func path(of fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func real(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: The four keys of each document

    /// What a document says of the object it is — those four, whether a
    /// kustomization builds its names with a prefix or suffix, and whether
    /// one of the four is a template's (`{{` in its value, or a `metadata`
    /// that is one): what it names is only known rendered.
    struct Document: Equatable, Sendable {
        var apiVersion: String?
        var kind: String?
        var name: String?
        var namespace: String?
        var prefixed = false
        var templated = false
    }

    /// Each document of a YAML stream, its top-level keys and `metadata`'s
    /// read off the grammar's tree; nil when the grammar can't read the
    /// text whole (as `YAMLReader`).
    static func documents(_ text: String) -> [Document]? {
        guard let language = EditorLanguage.named("yaml") else { return nil }
        let parser = ts_parser_new()
        defer { ts_parser_delete(parser) }
        ts_parser_set_language(parser, language.grammar)
        let bytes = Array(text.utf8)
        guard
            let tree = bytes.withUnsafeBufferPointer({ buffer in
                buffer.baseAddress.flatMap { base in
                    base.withMemoryRebound(to: CChar.self, capacity: buffer.count) { ts_parser_parse_string(parser, nil, $0, UInt32(buffer.count)) }
                }
            })
        else { return nil }
        defer { ts_tree_delete(tree) }
        let root = ts_tree_root_node(tree)
        guard !ts_node_has_error(root) else { return nil }
        let reader = Reader(bytes: bytes)
        var found: [Document] = []
        for document in reader.named(root) where reader.type(document) == "document" {
            guard let mapping = reader.mapping(in: document) else { continue }
            var read = Document()
            // A value of the four holding `{{`: a template's, whatever it parsed as.
            func templated(_ value: TSNode) -> Bool { reader.text(value).contains("{{") }
            for (key, value) in reader.pairs(mapping) {
                switch key {
                case "apiVersion":
                    read.apiVersion = reader.scalar(value)
                    if templated(value) { read.templated = true }
                case "kind":
                    read.kind = reader.scalar(value)
                    if templated(value) { read.templated = true }
                case "namePrefix", "nameSuffix": read.prefixed = true
                case "metadata":
                    for (field, item) in reader.mapping(in: value).map(reader.pairs) ?? [] where field == "name" || field == "namespace" {
                        if field == "name" { read.name = reader.scalar(item) } else { read.namespace = reader.scalar(item) }
                        if templated(item) { read.templated = true }
                    }
                    // `metadata: {{ include … }}`: no name of its own — the template's.
                    if read.name == nil, templated(value) { read.templated = true }
                default: continue
                }
            }
            // A document naming nothing of its own that holds `{{` — a whole
            // `{{ toYaml .Values.extraObjects }}`, read as a flow mapping — is one.
            if read.apiVersion == nil, read.kind == nil, read.name == nil, templated(document) { read.templated = true }
            found.append(read)
        }
        return found
    }

    /// The grammar's nodes, read no deeper than asked.
    private struct Reader {
        let bytes: [UInt8]

        func type(_ node: TSNode) -> String { String(cString: ts_node_type(node)) }

        func text(_ node: TSNode) -> String {
            let start = Int(ts_node_start_byte(node))
            let end = min(Int(ts_node_end_byte(node)), bytes.count)
            guard start < end else { return "" }
            return String(decoding: bytes[start..<end], as: UTF8.self)
        }

        func named(_ node: TSNode) -> [TSNode] { (0..<ts_node_named_child_count(node)).map { ts_node_named_child(node, $0) } }

        func field(_ node: TSNode, _ name: String) -> TSNode? {
            let child = name.withCString { ts_node_child_by_field_name(node, $0, UInt32(name.utf8.count)) }
            return ts_node_is_null(child) ? nil : child
        }

        /// The mapping a document or a value holds, through its node.
        func mapping(in node: TSNode) -> TSNode? {
            var current = node
            for _ in 0..<3 {
                switch type(current) {
                case "block_mapping", "flow_mapping": return current
                case "document", "block_node", "flow_node":
                    guard let next = named(current).first(where: { !["anchor", "tag", "comment"].contains(type($0)) }) else { return nil }
                    current = next
                default: return nil
                }
            }
            return nil
        }

        /// A mapping's pairs whose key is a plain or quoted scalar.
        func pairs(_ mapping: TSNode) -> [(String, TSNode)] {
            named(mapping).compactMap { pair in
                guard ["block_mapping_pair", "flow_pair"].contains(type(pair)), let key = field(pair, "key").flatMap(scalar), let value = field(pair, "value") else {
                    return nil
                }
                return (key, value)
            }
        }

        /// A scalar's text; nil for anything else (a mapping, a sequence, an alias).
        func scalar(_ node: TSNode) -> String? {
            var current = node
            for _ in 0..<3 {
                switch type(current) {
                case "block_node", "flow_node":
                    let children = named(current).filter { !["anchor", "tag", "comment"].contains(type($0)) }
                    guard children.count == 1, let only = children.first else { return nil }
                    current = only
                case "plain_scalar":
                    return text(current).trimmingCharacters(in: .whitespaces)
                case "double_quote_scalar":
                    return YAMLReader.unescapeDouble(String(text(current).dropFirst().dropLast()))
                case "single_quote_scalar":
                    return String(text(current).dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
                default:
                    return nil
                }
            }
            return nil
        }
    }
}
