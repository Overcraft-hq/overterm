import Foundation

/// An OpenAPI 3 or Swagger 2 document made into a Bruno collection: a
/// folder per tag, a request per operation — its path params as Bruno's
/// `:name`, its query and header params (the required ones on), a body
/// from the example or one made from the schema — the servers' first URL
/// as `{{baseUrl}}` in a Local environment, and the security scheme as the
/// collection's auth with its secret in that environment's secrets.
enum OpenAPIImporter {
    static func isOpenAPI(_ document: [String: Any]) -> Bool {
        document["openapi"] != nil || document["swagger"] != nil
    }

    static let methods = ["get", "post", "put", "patch", "delete", "head", "options", "trace"]

    /// - Parameter baseURL: where the API is, when it was found serving
    ///   (overrides `servers`, and makes a relative server URL absolute).
    static func make(_ document: [String: Any], baseURL: String? = nil) throws -> APIImport {
        let info = document["info"] as? [String: Any] ?? [:]
        let name = (info["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "API"
        var notes: [String] = []
        let resolver = Resolver(document: document)

        // {{baseUrl}}
        var base = serverURL(document) ?? ""
        if let baseURL {
            // Found serving here, it is here: a production server named in the
            // document keeps only its path — Local must not point elsewhere.
            let path = base.contains("://") ? (URL(string: base)?.path ?? "") : base
            base = baseURL.trimmingSuffix("/") + (path.hasPrefix("/") ? path : "")
        } else if base.isEmpty || base.hasPrefix("/") {
            notes.append("The document names no server: baseUrl in the Local environment is http://localhost:3000 — set it to where the API runs.")
            base = "http://localhost:3000" + (base == "/" ? "" : base)
        }
        base = base.trimmingSuffix("/")

        // Auth, from the document's security (the first scheme it asks for).
        var collectionFile = BruFile()
        var environment = BruFile()
        environment.variables = [BruPair(key: "baseUrl", value: base)]
        var secrets: [String] = []
        let schemes =
            (document["components"] as? [String: Any])?["securitySchemes"] as? [String: Any]
            ?? document["securityDefinitions"] as? [String: Any] ?? [:]
        func auth(for requirement: [[String: Any]]?) -> (BruFile.AuthMode, [BruPair])? {
            guard let requirement, let first = requirement.first?.keys.sorted().first,
                let scheme = resolver.resolve(schemes[first]) as? [String: Any]
            else { return nil }
            let type = (scheme["type"] as? String ?? "").lowercased()
            switch type {
            case "http" where (scheme["scheme"] as? String ?? "").lowercased() == "basic", "basic":
                if !secrets.contains("password") { secrets.append("password") }
                return (.basic, [BruPair(key: "username", value: "{{username}}"), BruPair(key: "password", value: "{{password}}")])
            case "http", "oauth2", "openidconnect":
                if type != "http" { notes.append("\(first) is \(scheme["type"] ?? type): sent as a bearer token — get one and put it in token.") }
                if !secrets.contains("token") { secrets.append("token") }
                return (.bearer, [BruPair(key: "token", value: "{{token}}")])
            case "apikey":
                let place = (scheme["in"] as? String ?? "header").lowercased()
                if place == "cookie" { notes.append("\(first) is a cookie: sent as a header named after it.") }
                if !secrets.contains("apiKey") { secrets.append("apiKey") }
                return (
                    .apikey,
                    [
                        BruPair(key: "key", value: scheme["name"] as? String ?? "X-API-Key"), BruPair(key: "value", value: "{{apiKey}}"),
                        BruPair(key: "placement", value: place == "query" ? "queryparams" : "header"),
                    ]
                )
            default:
                return nil
            }
        }
        let documentAuth = auth(for: document["security"] as? [[String: Any]])
        if let (mode, fields) = documentAuth {
            collectionFile.setPairs("auth", [BruPair(key: "mode", value: mode.rawValue)])
            collectionFile.setAuth(mode, fields)
        }

        // A folder per tag, in the document's order of tags, then the rest.
        var folders: [String: APIImport.Folder] = [:]
        var rootRequests: [APIImport.Request] = []
        let paths = document["paths"] as? [String: Any] ?? [:]
        for path in paths.keys.sorted() {
            guard let item = resolver.resolve(paths[path]) as? [String: Any] else { continue }
            let shared = item["parameters"] as? [Any] ?? []
            for method in methods {
                guard let operation = item[method] as? [String: Any] else { continue }
                var file = request(
                    method: method, path: path, operation: operation, shared: shared, document: document, resolver: resolver, notes: &notes)
                // An operation's own security over the document's; [] is none.
                if let own = operation["security"] as? [[String: Any]] {
                    if own.isEmpty || own.allSatisfy(\.isEmpty) {
                        file.authMode = .none
                    } else if let (mode, fields) = auth(for: own), mode != documentAuth?.0 || fields != documentAuth?.1 {
                        // Another scheme of the same kind — a key in the query
                        // where the document's is a header — is its own too.
                        file.authMode = mode
                        file.setAuth(mode, fields)
                    }
                }
                if let tag = (operation["tags"] as? [String])?.first {
                    folders[tag, default: APIImport.Folder(name: tag)].requests.append(APIImport.Request(file: file))
                } else {
                    rootRequests.append(APIImport.Request(file: file))
                }
            }
        }
        let tagOrder = (document["tags"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let ordered = tagOrder.filter { folders[$0] != nil } + folders.keys.filter { !tagOrder.contains($0) }.sorted()
        var root = APIImport.Folder(name: name)
        root.folders = ordered.compactMap { folders[$0] }
        root.requests = rootRequests
        if !secrets.isEmpty { environment.secretNames = secrets }
        if secrets.contains("password") { environment.variables += [BruPair(key: "username", value: "")] }
        if let description = info["description"] as? String, !description.isEmpty { collectionFile.docs = description }
        return APIImport(
            name: name, root: root, collectionFile: collectionFile.blocks.isEmpty ? nil : collectionFile,
            environments: [APIImport.Environment(name: "Local", file: environment)], notes: notes)
    }

    /// `servers[0].url` with its variables' defaults; Swagger 2's scheme, host and basePath.
    static func serverURL(_ document: [String: Any]) -> String? {
        if let server = (document["servers"] as? [[String: Any]])?.first, var url = server["url"] as? String {
            for (name, variable) in server["variables"] as? [String: [String: Any]] ?? [:] {
                url = url.replacingOccurrences(of: "{\(name)}", with: "\(variable["default"] ?? "")")
            }
            return url
        }
        guard let host = document["host"] as? String else { return document["basePath"] as? String }
        let scheme = (document["schemes"] as? [String])?.first ?? "https"
        return "\(scheme)://\(host)\(document["basePath"] as? String ?? "")"
    }

    private static func request(
        method: String, path: String, operation: [String: Any], shared: [Any], document: [String: Any], resolver: Resolver,
        notes: inout [String]
    ) -> BruFile {
        let title =
            (operation["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (operation["operationId"] as? String)
            ?? "\(method.uppercased()) \(path)"
        // `{id}` → `:id`, Bruno's path params.
        let brunoPath = path.replacingOccurrences(of: #"\{([^}/]+)\}"#, with: ":$1", options: .regularExpression)
        var file = BruFile.newRequest(name: String(title.prefix(120)), method: method, url: "{{baseUrl}}" + brunoPath, seq: 1)

        // Parameters: the path item's, replaced by the operation's of the same name and place.
        var parameters: [[String: Any]] = []
        for raw in shared + (operation["parameters"] as? [Any] ?? []) {
            guard let parameter = resolver.resolve(raw) as? [String: Any] else { continue }
            parameters.removeAll { $0["name"] as? String == parameter["name"] as? String && $0["in"] as? String == parameter["in"] as? String }
            parameters.append(parameter)
        }
        var query: [BruPair] = []
        var pathParams: [BruPair] = []
        var headers: [BruPair] = []
        var formFields: [BruPair] = []
        var bodySchema: Any?
        for parameter in parameters {
            let name = parameter["name"] as? String ?? ""
            let value = sampleValue(parameter, resolver: resolver)
            let required = parameter["required"] as? Bool ?? false
            switch parameter["in"] as? String {
            case "query": query.append(BruPair(key: name, value: value, enabled: required))
            case "path": pathParams.append(BruPair(key: name, value: value))
            case "header" where !["content-type", "accept", "authorization"].contains(name.lowercased()):
                headers.append(BruPair(key: name, value: value, enabled: required))
            case "cookie": notes.append("\(method.uppercased()) \(path): the cookie parameter \(name) isn't carried over.")
            case "body": bodySchema = parameter["schema"]
            case "formData": formFields.append(BruPair(key: name, value: parameter["type"] as? String == "file" ? "@file()" : value, enabled: required))
            default: break
            }
        }
        file.queryParams = query
        file.pathParams = pathParams
        file.headers = headers
        if !query.filter(\.enabled).isEmpty {
            file.url = APIRequestModel.url(file.url, withQuery: query.filter(\.enabled))
        }

        // The body.
        if let body = resolver.resolve(operation["requestBody"]) as? [String: Any], let content = body["content"] as? [String: Any] {
            let types = content.keys.sorted()
            if let json = types.first(where: { $0.contains("json") }), let media = content[json] as? [String: Any] {
                file.bodyMode = .json
                file.setBody(.json, APIImport.prettyJSON(example(media, resolver: resolver) ?? [String: Any]()))
            } else if let form = types.first(where: { $0.contains("x-www-form-urlencoded") || $0.contains("multipart") }),
                let media = content[form] as? [String: Any]
            {
                let fields = properties(of: resolver.resolve(media["schema"]), resolver: resolver).map { name, schema -> BruPair in
                    let binary = (schema["format"] as? String) == "binary"
                    return BruPair(key: name, value: binary ? "@file()" : sampleString(sample(schema, resolver: resolver)))
                }
                if form.contains("multipart") {
                    file.bodyMode = .multipartForm
                    file.multipartFields = fields
                } else {
                    file.bodyMode = .formUrlEncoded
                    file.formFields = fields
                }
            } else if let xml = types.first(where: { $0.contains("xml") }) {
                file.bodyMode = .xml
                file.setBody(.xml, ((content[xml] as? [String: Any])?["example"] as? String) ?? "")
            } else if let text = types.first(where: { $0.hasPrefix("text/") }) {
                file.bodyMode = .text
                file.setBody(.text, ((content[text] as? [String: Any])?["example"] as? String) ?? "")
            }
        } else if let bodySchema {
            file.bodyMode = .json
            file.setBody(.json, APIImport.prettyJSON(sample(resolver.resolve(bodySchema), resolver: resolver) ?? [String: Any]()))
        } else if !formFields.isEmpty {
            let consumes = (operation["consumes"] as? [String] ?? document["consumes"] as? [String] ?? []).joined()
            if consumes.contains("multipart") || formFields.contains(where: { $0.value == "@file()" }) {
                file.bodyMode = .multipartForm
                file.multipartFields = formFields
            } else {
                file.bodyMode = .formUrlEncoded
                file.formFields = formFields
            }
        }

        var docs: [String] = []
        if let description = operation["description"] as? String, !description.isEmpty { docs.append(description) }
        if operation["deprecated"] as? Bool == true { docs.append("Deprecated.") }
        if !docs.isEmpty { file.docs = docs.joined(separator: "\n\n") }
        return file
    }

    // MARK: Examples

    private static func example(_ media: [String: Any], resolver: Resolver) -> Any? {
        if let example = media["example"] { return example }
        if let examples = media["examples"] as? [String: Any], let first = examples.keys.sorted().first,
            let value = (resolver.resolve(examples[first]) as? [String: Any])?["value"]
        {
            return value
        }
        return sample(resolver.resolve(media["schema"]), resolver: resolver)
    }

    private static func sampleValue(_ parameter: [String: Any], resolver: Resolver) -> String {
        if let example = parameter["example"] { return sampleString(example) }
        let schema = resolver.resolve(parameter["schema"]) as? [String: Any] ?? parameter
        if let example = schema["example"] { return sampleString(example) }
        if let value = schema["default"] { return sampleString(value) }
        if let first = (schema["enum"] as? [Any])?.first { return sampleString(first) }
        return ""
    }

    private static func sampleString(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: ""
        case let string as String: string
        case let number as NSNumber:
            CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        default:
            APIScriptRuntime.jsonText(value!) ?? ""
        }
    }

    private static func properties(of schema: Any?, resolver: Resolver) -> [(String, [String: Any])] {
        let merged = flatten(schema, resolver: resolver)
        let properties = merged["properties"] as? [String: Any] ?? [:]
        return properties.keys.sorted().map { ($0, resolver.resolve(properties[$0]) as? [String: Any] ?? [:]) }
    }

    /// allOf merged, oneOf/anyOf's first taken, $refs followed.
    private static func flatten(_ schema: Any?, resolver: Resolver, depth: Int = 0) -> [String: Any] {
        guard depth < 8, var schema = resolver.resolve(schema) as? [String: Any] else { return [:] }
        if let all = schema["allOf"] as? [Any] {
            var properties = schema["properties"] as? [String: Any] ?? [:]
            for part in all {
                let flat = flatten(part, resolver: resolver, depth: depth + 1)
                properties.merge(flat["properties"] as? [String: Any] ?? [:]) { current, _ in current }
                if schema["type"] == nil { schema["type"] = flat["type"] }
            }
            schema["properties"] = properties
            schema["allOf"] = nil
        }
        for key in ["oneOf", "anyOf"] {
            if let first = (schema[key] as? [Any])?.first {
                let flat = flatten(first, resolver: resolver, depth: depth + 1)
                schema.merge(flat) { current, _ in current }
                schema[key] = nil
            }
        }
        return schema
    }

    /// A value the schema allows, for a body to start from.
    static func sample(_ schema: Any?, resolver: Resolver, depth: Int = 0) -> Any? {
        guard depth < 6 else { return nil }
        let schema = flatten(schema, resolver: resolver)
        guard !schema.isEmpty else { return nil }
        if let example = schema["example"] { return example }
        if let value = schema["default"] { return value }
        if let first = (schema["enum"] as? [Any])?.first { return first }
        let type = schema["type"] as? String ?? (schema["properties"] != nil ? "object" : schema["items"] != nil ? "array" : "string")
        switch type {
        case "object":
            var object: [String: Any] = [:]
            for (name, property) in properties(of: schema, resolver: resolver) {
                if property["readOnly"] as? Bool == true { continue }
                object[name] = sample(property, resolver: resolver, depth: depth + 1) ?? NSNull()
            }
            return object
        case "array":
            return [sample(schema["items"], resolver: resolver, depth: depth + 1)].compactMap { $0 }
        case "integer": return 0
        case "number": return 0
        case "boolean": return true
        default:
            switch schema["format"] as? String {
            case "date-time": return "2024-01-01T00:00:00Z"
            case "date": return "2024-01-01"
            case "email": return "user@example.com"
            case "uuid": return "00000000-0000-0000-0000-000000000000"
            case "uri", "url": return "https://example.com"
            default: return "string"
            }
        }
    }

    /// `$ref: '#/components/schemas/Pet'` followed, within the document.
    struct Resolver {
        let document: [String: Any]

        func resolve(_ value: Any?, depth: Int = 0) -> Any? {
            guard let map = value as? [String: Any], let ref = map["$ref"] as? String else { return value }
            guard depth < 16, ref.hasPrefix("#/") else { return nil }
            var node: Any? = document
            for part in ref.dropFirst(2).split(separator: "/") {
                let key = part.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                node = (node as? [String: Any])?[key]
            }
            return resolve(node, depth: depth + 1)
        }
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var text = self
        while text.hasSuffix(suffix) && text != suffix { text.removeLast(suffix.count) }
        return text
    }
}
