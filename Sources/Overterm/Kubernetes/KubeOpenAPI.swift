import Foundation

// The cluster's own API docs (stage 4, analysis 3.15): `/openapi/v3`, the
// server's index of one document a group version, and those documents read
// into what `kubectl explain` says of a kind and a field — a manifest's
// hover and completion, its unknown fields marked, the explain view.
// Pure: what is read is the caller's (KubeAPIDocs), bounded here.

/// A kind as the documents name it (`x-kubernetes-group-version-kind`).
struct KubeGVK: Hashable, Sendable, CustomStringConvertible {
    /// "" for the core group.
    var group: String
    var version: String
    var kind: String

    var apiVersion: String { group.isEmpty ? version : "\(group)/\(version)" }
    var description: String { "\(kind) \(apiVersion)" }

    init(group: String, version: String, kind: String) {
        self.group = group
        self.version = version
        self.kind = kind
    }

    /// `apps/v1` and `Deployment`; nil when the apiVersion is empty or odd.
    init?(apiVersion: String, kind: String) {
        let parts = apiVersion.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !kind.isEmpty, (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        group = parts.count == 2 ? parts[0] : ""
        version = parts.last ?? ""
        self.kind = kind
    }
}

/// Why the docs couldn't be read or said — in plain words.
struct KubeOpenAPIProblem: Error, Equatable, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// `/openapi/v3`: each group version's document, by the path the server
/// names it with (`api/v1`, `apis/apps/v1`) and the URL it serves it at,
/// a hash in its query that changes with the document.
struct KubeOpenAPIIndex: Sendable, Equatable {
    var paths: [String: String]

    /// The index is a few hundred entries; one that isn't is refused.
    static let maxBytes = 4 << 20
    static let maxPaths = 4000

    static func key(group: String, version: String) -> String { group.isEmpty ? "api/\(version)" : "apis/\(group)/\(version)" }

    func url(for gvk: KubeGVK) -> String? { paths[Self.key(group: gvk.group, version: gvk.version)] }

    static func read(_ data: Data) throws -> KubeOpenAPIIndex {
        guard data.count <= maxBytes else { throw KubeOpenAPIProblem("The cluster's OpenAPI index is over \(maxBytes >> 20) MB: too much to read here.") }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let paths = root["paths"] as? [String: Any] else {
            throw KubeOpenAPIProblem("The cluster's /openapi/v3 isn't the index Kubernetes serves.")
        }
        var found: [String: String] = [:]
        for (path, value) in paths.prefix(maxPaths) {
            guard let entry = value as? [String: Any], let url = entry["serverRelativeURL"] as? String, let safe = safe(url) else { continue }
            found[path] = safe
        }
        return KubeOpenAPIIndex(paths: found)
    }

    /// Only a path under the server's own `/openapi/v3/` — the URL is the
    /// server's word, and it goes through Overterm's proxy: never another
    /// host, another path or a way out of it.
    static func safe(_ url: String) -> String? {
        guard url.hasPrefix("/openapi/v3/"), url.count <= 1024, !url.contains("//"), !url.contains("\\"), !url.contains("#") else { return nil }
        let path = url.split(separator: "?", maxSplits: 1).first.map(String.init) ?? url
        let decoded = path.removingPercentEncoding ?? path
        let segments = decoded.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains(where: { $0 == ".." || $0 == "." }), !decoded.contains("?"), url.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else {
            return nil
        }
        return url
    }
}

/// One schema of a document, as much of it as the docs say: its words,
/// its type, the schemas it is made of (`$ref`, `allOf`), its fields.
struct KubeSchema: Sendable, Equatable {
    var description: String?
    var type: String?
    var format: String?
    /// Component schemas this one is (`$ref`, each `allOf`'s).
    var refs: [String] = []
    var properties: [String: KubeSchema] = [:]
    var required: [String] = []
    /// An array's item, a map's value: none or one each.
    var itemsOf: [KubeSchema] = []
    var valuesOf: [KubeSchema] = []
    /// `additionalProperties: true`: any key.
    var anyKeys = false
    var enumValues: [String] = []
    /// `x-kubernetes-preserve-unknown-fields`: whatever is under it, unchecked.
    var preservesUnknown = false
    var intOrString = false
    var embedded = false
    var gvks: [KubeGVK] = []

    var items: KubeSchema? { itemsOf.first }
    var values: KubeSchema? { valuesOf.first }
}

/// A field's docs: `kubectl explain`'s FIELD part.
struct KubeFieldSummary: Equatable, Sendable, Identifiable {
    var name: String
    var type: String
    var required: Bool
    var description: String

    var id: String { name }
    /// The description's first sentence, for a list's row.
    var summary: String { KubeExplain.firstSentence(description) }
}

/// What the docs say of one field (or of the kind, for an empty path).
struct KubeFieldDoc: Equatable, Sendable {
    var gvk: KubeGVK
    var path: [String]
    var type: String
    var description: String
    var required: Bool
    var enumValues: [String]
    var fields: [KubeFieldSummary]
    /// Under it is anything: no field there is unknown.
    var opaque: Bool

    var name: String { path.last ?? gvk.kind }
    /// `Deployment.spec.replicas`.
    var spokenPath: String { ([gvk.kind] + path).joined(separator: ".") }
}

/// What a path through a kind's schema comes to.
enum KubeFieldLookup: Equatable {
    case found(KubeFieldDoc)
    /// The segment at `index` isn't a field of what holds it (`parent`, spoken).
    case unknown(index: Int, parent: String)
    /// Under a schema that says nothing of its fields (preserve-unknown, `Object`).
    case opaque
    /// The document has no such kind.
    case noKind
}

/// A group version's document, read: its component schemas and which of
/// them is which kind. Bounded as it is read.
struct KubeOpenAPIDocument: Sendable {
    var schemas: [String: KubeSchema]
    var kinds: [KubeGVK: String]
    /// Its size as read: what the cache counts.
    var bytes: Int

    static let maxBytes = 32 << 20
    static let maxSchemas = 20_000
    /// Every schema node read, inline ones too (a CRD's are all inline).
    static let maxNodes = 500_000
    static let maxDepth = 64
    /// How deep `$ref`s are followed: a schema that refers to itself
    /// (JSONSchemaProps) stops here.
    static let maxRefDepth = 32
    static let maxPath = 32

    static func read(_ data: Data) throws -> KubeOpenAPIDocument {
        guard data.count <= maxBytes else { throw KubeOpenAPIProblem("The cluster's document is over \(maxBytes >> 20) MB: too much to read here.") }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KubeOpenAPIProblem("The cluster's OpenAPI document isn't JSON Overterm can read.")
        }
        let components = (root["components"] as? [String: Any])?["schemas"] as? [String: Any] ?? [:]
        guard components.count <= maxSchemas else { throw KubeOpenAPIProblem("The document has \(components.count) schemas: more than Overterm reads (\(maxSchemas)).") }
        var budget = maxNodes
        var schemas: [String: KubeSchema] = [:]
        var kinds: [KubeGVK: String] = [:]
        for (name, value) in components {
            guard let map = value as? [String: Any] else { continue }
            let schema = try parse(map, depth: 0, budget: &budget)
            schemas[name] = schema
            for gvk in schema.gvks where kinds[gvk] == nil { kinds[gvk] = name }
        }
        return KubeOpenAPIDocument(schemas: schemas, kinds: kinds, bytes: data.count)
    }

    static func parse(_ map: [String: Any], depth: Int, budget: inout Int) throws -> KubeSchema {
        budget -= 1
        guard budget >= 0 else { throw KubeOpenAPIProblem("The document is larger than Overterm reads (\(maxNodes) schema nodes).") }
        var schema = KubeSchema()
        schema.description = map["description"] as? String
        schema.type = map["type"] as? String
        schema.format = map["format"] as? String
        schema.required = (map["required"] as? [Any])?.compactMap { $0 as? String } ?? []
        schema.enumValues = (map["enum"] as? [Any])?.prefix(100).compactMap { value in value as? String ?? (value as? NSNumber)?.stringValue } ?? []
        schema.preservesUnknown = map["x-kubernetes-preserve-unknown-fields"] as? Bool ?? false
        schema.intOrString = (map["x-kubernetes-int-or-string"] as? Bool ?? false) || schema.format == "int-or-string"
        schema.embedded = map["x-kubernetes-embedded-resource"] as? Bool ?? false
        schema.gvks =
            (map["x-kubernetes-group-version-kind"] as? [Any])?.compactMap { entry in
                guard let entry = entry as? [String: Any], let kind = entry["kind"] as? String, let version = entry["version"] as? String else { return nil }
                return KubeGVK(group: entry["group"] as? String ?? "", version: version, kind: kind)
            } ?? []
        if let ref = map["$ref"] as? String, let name = refName(ref) { schema.refs.append(name) }
        // Deeper than this, a schema is taken as saying nothing of its fields.
        guard depth < maxDepth else {
            schema.preservesUnknown = true
            return schema
        }
        for entry in (map["allOf"] as? [Any]) ?? [] {
            guard let entry = entry as? [String: Any] else { continue }
            let part = try parse(entry, depth: depth + 1, budget: &budget)
            merge(part, into: &schema)
        }
        if let properties = map["properties"] as? [String: Any] {
            for (name, value) in properties {
                guard let value = value as? [String: Any] else { continue }
                schema.properties[name] = try parse(value, depth: depth + 1, budget: &budget)
            }
        }
        if let items = map["items"] as? [String: Any] { schema.itemsOf = [try parse(items, depth: depth + 1, budget: &budget)] }
        if let values = map["additionalProperties"] as? [String: Any] {
            schema.valuesOf = [try parse(values, depth: depth + 1, budget: &budget)]
        } else if map["additionalProperties"] as? Bool == true {
            schema.anyKeys = true
        }
        return schema
    }

    /// An `allOf` part folded into the schema holding it: its refs and
    /// fields added, its words only where the holder has none.
    static func merge(_ part: KubeSchema, into schema: inout KubeSchema) {
        schema.refs += part.refs
        schema.properties.merge(part.properties) { mine, _ in mine }
        schema.required += part.required.filter { !schema.required.contains($0) }
        if schema.description == nil { schema.description = part.description }
        if schema.type == nil { schema.type = part.type }
        if schema.format == nil { schema.format = part.format }
        if schema.itemsOf.isEmpty { schema.itemsOf = part.itemsOf }
        if schema.valuesOf.isEmpty { schema.valuesOf = part.valuesOf }
        schema.anyKeys = schema.anyKeys || part.anyKeys
        schema.preservesUnknown = schema.preservesUnknown || part.preservesUnknown
        schema.intOrString = schema.intOrString || part.intOrString
        if schema.enumValues.isEmpty { schema.enumValues = part.enumValues }
    }

    /// `#/components/schemas/io.k8s.api.apps.v1.Deployment` → its name; a
    /// ref to anywhere else is not followed.
    static func refName(_ ref: String) -> String? {
        let prefix = "#/components/schemas/"
        guard ref.hasPrefix(prefix), ref.count > prefix.count else { return nil }
        return String(ref.dropFirst(prefix.count)).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
    }

    // MARK: Reading

    /// The kind's schema: the one naming it; nil when the document has none.
    func root(for gvk: KubeGVK) -> KubeSchema? { kinds[gvk].flatMap { schemas[$0] } }

    /// The kinds the document has, by name.
    var kindNames: [String] { Array(Set(kinds.keys.map(\.kind))).sorted() }

    /// A schema with what its refs say folded in, refs followed to `maxRefDepth`.
    func resolved(_ schema: KubeSchema, depth: Int = 0) -> KubeSchema {
        guard !schema.refs.isEmpty, depth < Self.maxRefDepth else { return schema }
        var whole = schema
        whole.refs = []
        for ref in schema.refs {
            guard let target = schemas[ref] else { continue }
            Self.merge(resolved(target, depth: depth + 1), into: &whole)
        }
        whole.refs = schema.refs
        return whole
    }

    /// Whether a schema says nothing of what is under it: any field passes.
    func isOpaque(_ schema: KubeSchema) -> Bool {
        if schema.preservesUnknown || schema.anyKeys || schema.embedded { return true }
        if !schema.properties.isEmpty || schema.values != nil || schema.items != nil { return false }
        return schema.type == nil || schema.type == "object"
    }

    /// What `path` (`spec`, `template`, `spec`, `containers`, `[]`,
    /// `image`) comes to in the kind: its docs, or where it stops. An array
    /// is stepped into by `[]` or by the next field's name (kubectl's
    /// `pod.spec.containers.image`); a map's key is any name.
    func lookup(_ gvk: KubeGVK, _ path: [String]) -> KubeFieldLookup {
        guard let root = root(for: gvk) else { return .noKind }
        guard path.count <= Self.maxPath else { return .opaque }
        var node = resolved(root)
        var field: KubeSchema = root
        var required = false
        var named: [String] = []
        var parent = gvk.kind
        for (index, segment) in path.enumerated() {
            if segment == "[]" {
                guard let items = node.items else { return isOpaque(node) ? .opaque : .unknown(index: index, parent: parent) }
                field = items
                node = resolved(items)
                continue
            }
            var steps = 0
            while node.type == "array", let items = node.items, steps < Self.maxPath {
                node = resolved(items)
                steps += 1
            }
            if let property = node.properties[segment] {
                required = node.required.contains(segment)
                field = property
                node = resolved(property)
            } else if let values = node.values {
                required = false
                field = values
                node = resolved(values)
            } else if isOpaque(node) {
                return .opaque
            } else {
                return .unknown(index: index, parent: parent)
            }
            named.append(segment)
            parent = ([gvk.kind] + named).joined(separator: ".")
        }
        var inner = node
        var steps = 0
        while inner.type == "array", let items = inner.items, steps < Self.maxPath {
            inner = resolved(items)
            steps += 1
        }
        return .found(
            KubeFieldDoc(
                gvk: gvk, path: path.filter { $0 != "[]" }, type: path.isEmpty ? "Object" : typeName(field),
                description: field.description ?? node.description ?? "", required: required, enumValues: node.enumValues.isEmpty ? field.enumValues : node.enumValues,
                fields: fields(of: inner), opaque: isOpaque(inner) && inner.properties.isEmpty))
    }

    /// An object's fields, by name, as `kubectl explain` lists them.
    func fields(of schema: KubeSchema, limit: Int = 500) -> [KubeFieldSummary] {
        schema.properties.keys.sorted().prefix(limit).map { name in
            let property = schema.properties[name] ?? KubeSchema()
            return KubeFieldSummary(
                name: name, type: typeName(property), required: schema.required.contains(name),
                description: property.description ?? resolved(property).description ?? "")
        }
    }

    /// kubectl's names for types: `integer`, `[]Container`,
    /// `map[string]string`, `PodTemplateSpec`, `IntOrString`, `Object`.
    func typeName(_ schema: KubeSchema, depth: Int = 0) -> String {
        if schema.intOrString { return "IntOrString" }
        if let ref = schema.refs.first, let target = schemas[ref] {
            let short = ref.split(separator: ".").last.map(String.init) ?? ref
            if target.intOrString { return "IntOrString" }
            if short == "Quantity" { return "Quantity" }
            if let type = target.type, type != "object", type != "array" { return type }
            if target.type == "array" || (target.type == "object" && target.properties.isEmpty && target.values != nil), depth < 8 {
                return typeName(target, depth: depth + 1)
            }
            return short
        }
        switch schema.type {
        case "array": return "[]" + (schema.items.map { depth < 8 ? typeName($0, depth: depth + 1) : "Object" } ?? "Object")
        case "object", nil:
            if let values = schema.values, schema.properties.isEmpty { return "map[string]" + (depth < 8 ? typeName(values, depth: depth + 1) : "Object") }
            return "Object"
        case let type?: return type
        }
    }
}

/// `kubectl explain`: its query read, its answer said.
enum KubeExplain {
    /// `deployment.spec.replicas` → `deployment` and `spec`, `replicas`.
    struct Query: Equatable {
        var resource: String
        var path: [String]
    }

    static func parse(_ text: String) throws -> Query {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KubeOpenAPIProblem("Type a kind, and a field path if you like: deployment.spec.replicas") }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0.count <= 253 && !$0.contains(where: \.isWhitespace) }) else {
            throw KubeOpenAPIProblem("\(trimmed) isn't a kind and a field path: deployment.spec.replicas, say.")
        }
        guard parts.count <= KubeOpenAPIDocument.maxPath + 1 else { throw KubeOpenAPIProblem("That path is deeper than Overterm follows.") }
        return Query(resource: parts[0], path: Array(parts.dropFirst()))
    }

    /// What `kubectl explain` prints, its layout kept (v1.27's plain text).
    static func text(_ doc: KubeFieldDoc) -> String {
        var lines = ["GROUP:      \(doc.gvk.group)", "KIND:       \(doc.gvk.kind)", "VERSION:    \(doc.gvk.version)", ""]
        if !doc.path.isEmpty {
            lines.append("FIELD: \(doc.name) <\(doc.type)>\(doc.required ? " -required-" : "")")
            lines.append("")
        }
        lines.append("DESCRIPTION:")
        lines += wrapped(doc.description.isEmpty ? "<empty>" : doc.description, indent: "    ")
        if !doc.enumValues.isEmpty {
            lines.append("    Possible enum values:")
            lines += doc.enumValues.map { "     - `\"\($0)\"`" }
        }
        if !doc.fields.isEmpty {
            lines.append("")
            lines.append("FIELDS:")
            for field in doc.fields {
                lines.append("  \(field.name)\t<\(field.type)>\(field.required ? " -required-" : "")")
                lines += wrapped(field.description.isEmpty ? "<no description>" : field.description, indent: "    ")
                lines.append("")
            }
            while lines.last == "" { lines.removeLast() }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A hover's words: the field, its type and where it is, its docs.
    static func hover(_ doc: KubeFieldDoc, source: String) -> String {
        var text = "**\(doc.name)** `<\(doc.type)>`\(doc.required ? " — required" : "")\n\(doc.spokenPath) · \(doc.gvk.apiVersion) · \(source)\n\n"
        text += String(doc.description.prefix(4000))
        if !doc.enumValues.isEmpty { text += "\n\nOne of: " + doc.enumValues.prefix(30).joined(separator: ", ") }
        if !doc.fields.isEmpty {
            let names = doc.fields.prefix(24).map { $0.name + ($0.required ? "*" : "") }
            text += "\n\nFields: " + names.joined(separator: ", ") + (doc.fields.count > 24 ? ", …" : "")
        }
        return text
    }

    /// `kubectl explain deployment.spec.replicas --context fake-dev`.
    static func kubectl(_ query: String, context: String, apiVersion: String?) -> String {
        var words = ["kubectl", "explain", KubectlLine.quoted(query), "--context", KubectlLine.quoted(context)]
        if let apiVersion, !apiVersion.isEmpty { words += ["--api-version", KubectlLine.quoted(apiVersion)] }
        return words.joined(separator: " ")
    }

    static func firstSentence(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        if let end = flat.range(of: ". ") { return String(flat[..<end.lowerBound]) + "." }
        return flat.count > 160 ? String(flat.prefix(160)) + "…" : flat
    }

    /// Words wrapped at 76 columns under `indent`, as kubectl wraps them.
    static func wrapped(_ text: String, indent: String, width: Int = 76) -> [String] {
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: true) {
                if !line.isEmpty, line.count + 1 + word.count > width {
                    lines.append(indent + line)
                    line = ""
                }
                line += (line.isEmpty ? "" : " ") + word
            }
            lines.append(line.isEmpty ? "" : indent + line)
        }
        while lines.last == "" { lines.removeLast() }
        return lines
    }
}
