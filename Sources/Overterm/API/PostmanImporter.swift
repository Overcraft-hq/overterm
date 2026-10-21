import Foundation

/// A Postman collection (v2.0, v2.1) made into a Bruno one: folders,
/// requests, auth, collection variables, and scripts with Postman's `pm.`
/// calls turned into Bruno's — as Bruno's own importer turns them.
enum PostmanImporter {
    static func isPostman(_ document: [String: Any]) -> Bool {
        guard let info = document["info"] as? [String: Any] else { return false }
        return (info["schema"] as? String ?? "").contains("getpostman") || info["_postman_id"] != nil || document["item"] is [Any]
    }

    static func make(_ document: [String: Any]) throws -> APIImport {
        let info = document["info"] as? [String: Any] ?? [:]
        let name = (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Postman Collection"
        var notes: [String] = []
        var collectionFile = BruFile()
        if let auth = document["auth"] as? [String: Any], let (mode, fields) = Self.auth(auth) {
            collectionFile.setPairs("auth", [BruPair(key: "mode", value: mode.rawValue)])
            collectionFile.setAuth(mode, fields)
        }
        let variables = (document["variable"] as? [[String: Any]] ?? []).compactMap { variable -> BruPair? in
            guard let key = variable["key"] as? String else { return nil }
            return BruPair(key: key, value: stringValue(variable["value"]), enabled: variable["disabled"] as? Bool != true)
        }
        if !variables.isEmpty { collectionFile.preRequestVars = variables }
        applyEvents(document["event"], to: &collectionFile, notes: &notes, where: "the collection")
        if let description = describe(info["description"]) { collectionFile.docs = description }
        var root = folder(name: name, items: document["item"] as? [[String: Any]] ?? [], notes: &notes)
        root.name = name
        return APIImport(
            name: name, root: root, collectionFile: collectionFile.blocks.isEmpty ? nil : collectionFile, environments: [], notes: notes)
    }

    private static func folder(name: String, items: [[String: Any]], notes: inout [String]) -> APIImport.Folder {
        var folder = APIImport.Folder(name: name)
        for item in items {
            let itemName = item["name"] as? String ?? "Untitled"
            if let children = item["item"] as? [[String: Any]] {
                var child = Self.folder(name: itemName, items: children, notes: &notes)
                var settings = BruFile()
                if let auth = item["auth"] as? [String: Any] {
                    if let (mode, fields) = Self.auth(auth) {
                        settings.setPairs("auth", [BruPair(key: "mode", value: mode.rawValue)])
                        settings.setAuth(mode, fields)
                    } else if auth["type"] as? String == "noauth" {
                        // An explicit stop: what is above isn't sent from here down.
                        settings.setPairs("auth", [BruPair(key: "mode", value: "none")])
                    }
                }
                applyEvents(item["event"], to: &settings, notes: &notes, where: itemName)
                if let description = describe(item["description"]) { settings.docs = description }
                child.settings = settings.blocks.isEmpty ? nil : settings
                folder.folders.append(child)
            } else if let request = item["request"] {
                folder.requests.append(APIImport.Request(file: self.request(name: itemName, request, item: item, notes: &notes)))
            }
        }
        return folder
    }

    private static func request(name: String, _ raw: Any, item: [String: Any], notes: inout [String]) -> BruFile {
        let request = raw as? [String: Any] ?? ["url": raw]
        let method = (request["method"] as? String ?? "GET").lowercased()
        var file = BruFile.newRequest(name: name, method: BruFile.methods.contains(method) ? method : "get", seq: 1)

        // The URL: a string, or Postman's object with its raw form.
        let url = request["url"]
        let urlObject = url as? [String: Any]
        file.url = (url as? String) ?? (urlObject?["raw"] as? String) ?? ""
        if let query = urlObject?["query"] as? [[String: Any]] {
            file.queryParams = query.compactMap { param in
                guard let key = param["key"] as? String else { return nil }
                return BruPair(key: key, value: stringValue(param["value"]), enabled: param["disabled"] as? Bool != true)
            }
        } else {
            file.queryParams = APIRequestModel.queryPairs(of: file.url)
        }
        let pathVariables = (urlObject?["variable"] as? [[String: Any]] ?? []).compactMap { variable -> BruPair? in
            guard let key = variable["key"] as? String else { return nil }
            return BruPair(key: key, value: stringValue(variable["value"]))
        }
        let pathNames = APIRequestModel.pathParamNames(in: file.url)
        file.pathParams = pathNames.map { name in pathVariables.first { $0.key == name } ?? BruPair(key: name, value: "") }

        file.headers = (request["header"] as? [[String: Any]] ?? []).compactMap { header in
            guard let key = header["key"] as? String else { return nil }
            return BruPair(key: key, value: stringValue(header["value"]), enabled: header["disabled"] as? Bool != true)
        }

        if let body = request["body"] as? [String: Any] {
            switch body["mode"] as? String {
            case "raw":
                let text = body["raw"] as? String ?? ""
                let language = ((body["options"] as? [String: Any])?["raw"] as? [String: Any])?["language"] as? String
                let mode: BruFile.BodyMode =
                    switch language {
                    case "xml", "html": .xml
                    case "text", "javascript": .text
                    case "json": .json
                    default:
                        text.trimmingCharacters(in: .whitespacesAndNewlines).first.map { "{[".contains($0) } == true ? .json : .text
                    }
                file.bodyMode = mode
                file.setBody(mode, text)
            case "urlencoded":
                file.bodyMode = .formUrlEncoded
                file.formFields = pairs(body["urlencoded"])
            case "formdata":
                file.bodyMode = .multipartForm
                file.multipartFields = (body["formdata"] as? [[String: Any]] ?? []).compactMap { field in
                    guard let key = field["key"] as? String else { return nil }
                    let isFile = field["type"] as? String == "file"
                    let source = (field["src"] as? String) ?? (field["src"] as? [String])?.first ?? ""
                    return BruPair(key: key, value: isFile ? "@file(\(source))" : stringValue(field["value"]), enabled: field["disabled"] as? Bool != true)
                }
            case "graphql":
                let graphql = body["graphql"] as? [String: Any] ?? [:]
                file.bodyMode = .graphql
                file.setBody(.graphql, graphql["query"] as? String ?? "")
                if let variables = graphql["variables"] as? String, !variables.isEmpty { file.graphQLVariables = variables }
            case "file":
                if let source = (body["file"] as? [String: Any])?["src"] as? String {
                    file.bodyMode = .file
                    file.setPairs("body:file", [BruPair(key: "file", value: "@file(\(source))")])
                }
            default: break
            }
        }
        if let auth = request["auth"] as? [String: Any] {
            if let (mode, fields) = Self.auth(auth) {
                file.authMode = mode
                file.setAuth(mode, fields)
            } else if auth["type"] as? String == "noauth" {
                file.authMode = .none
            } else {
                notes.append("\(name): \(auth["type"] ?? "its") auth isn't carried over.")
            }
        }
        applyEvents(item["event"], to: &file, notes: &notes, where: name)
        if let description = describe(request["description"]) { file.docs = description }
        return file
    }

    /// Postman's auth blocks: `{type: bearer, bearer: [{key, value}]}`.
    private static func auth(_ auth: [String: Any]) -> (BruFile.AuthMode, [BruPair])? {
        let type = auth["type"] as? String ?? ""
        func value(_ key: String) -> String {
            let list = auth[type] as? [[String: Any]] ?? []
            return stringValue(list.first { $0["key"] as? String == key }?["value"])
        }
        switch type {
        case "bearer": return (.bearer, [BruPair(key: "token", value: value("token"))])
        case "basic": return (.basic, [BruPair(key: "username", value: value("username")), BruPair(key: "password", value: value("password"))])
        case "apikey":
            return (
                .apikey,
                [
                    BruPair(key: "key", value: value("key")), BruPair(key: "value", value: value("value")),
                    BruPair(key: "placement", value: value("in") == "query" ? "queryparams" : "header"),
                ]
            )
        default: return nil
        }
    }

    private static func applyEvents(_ events: Any?, to file: inout BruFile, notes: inout [String], where place: String) {
        for event in events as? [[String: Any]] ?? [] {
            let script = event["script"] as? [String: Any] ?? [:]
            let lines = (script["exec"] as? [String]) ?? (script["exec"] as? String).map { [$0] } ?? []
            let source = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { continue }
            let translated = translate(source)
            if translated.contains("pm.") || translated.contains("postman.") {
                notes.append("\(place): some Postman script calls have no Bruno equivalent — they are kept as they were.")
            }
            switch event["listen"] as? String {
            case "prerequest": file.preRequestScript = translated
            case "test": file.tests = translated
            default: break
            }
        }
    }

    /// Postman's script API, in Bruno's words.
    static func translate(_ script: String) -> String {
        var text = script
        let regexes: [(String, String)] = [
            // headers.add takes {key, value}; req.setHeader a name and a value.
            (#"pm\.request\.headers\.(?:add|upsert)\(\s*\{\s*key\s*:\s*([^,}]+?)\s*,\s*value\s*:\s*([^}]+?)\s*\}\s*\)"#, "req.setHeader($1, $2)"),
            (#"pm\.request\.headers\.(?:add|upsert)\(\s*([A-Za-z_$][\w$]*)\s*\)"#, "req.setHeader($1.key, $1.value)"),
            (#"pm\.response\.to\.have\.status\(\s*(\d+)\s*\)"#, "expect(res.getStatus()).to.equal($1)"),
            (#"pm\.response\.to\.be\.ok\b"#, "expect(res.getStatus()).to.be.within(200, 299)"),
        ]
        for (pattern, template) in regexes {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        let replacements: [(String, String)] = [
            ("pm.environment.get(", "bru.getEnvVar("), ("pm.environment.set(", "bru.setEnvVar("),
            ("pm.collectionVariables.get(", "bru.getVar("), ("pm.collectionVariables.set(", "bru.setVar("),
            ("pm.variables.get(", "bru.getVar("), ("pm.variables.set(", "bru.setVar("),
            ("pm.globals.get(", "bru.getVar("), ("pm.globals.set(", "bru.setVar("),
            ("postman.setEnvironmentVariable(", "bru.setEnvVar("), ("postman.getEnvironmentVariable(", "bru.getEnvVar("),
            ("postman.setNextRequest(", "bru.setNextRequest("), ("pm.setNextRequest(", "bru.setNextRequest("),
            ("pm.response.json()", "res.getBody()"), ("pm.response.text()", "JSON.stringify(res.getBody())"),
            ("pm.response.code", "res.getStatus()"), ("pm.response.responseTime", "res.getResponseTime()"),
            ("pm.response.headers.get(", "res.getHeader("),
            ("pm.test(", "test("), ("pm.expect(", "expect("),
        ]
        for (from, to) in replacements { text = text.replacingOccurrences(of: from, with: to) }
        return text
    }

    private static func pairs(_ value: Any?) -> [BruPair] {
        (value as? [[String: Any]] ?? []).compactMap { pair in
            guard let key = pair["key"] as? String else { return nil }
            return BruPair(key: key, value: stringValue(pair["value"]), enabled: pair["disabled"] as? Bool != true)
        }
    }

    private static func describe(_ value: Any?) -> String? {
        let text = (value as? String) ?? ((value as? [String: Any])?["content"] as? String)
        return text.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func stringValue(_ value: Any?) -> String {
        switch value {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        case nil, is NSNull: ""
        default: "\(value!)"
        }
    }
}
