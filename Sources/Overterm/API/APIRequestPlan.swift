import Foundation
import UniformTypeIdentifiers

/// A request as it will go out: what the file says, the folders' and the
/// collection's headers and auth around it, every `{{variable}}` filled in,
/// the body made. Pure — nothing is sent, so tests and `Copy as cURL` see
/// exactly what Send would.
struct APIRequestPlan: Equatable, Sendable {
    var method: String
    var url: URL
    /// In order, names as written; a later one replaces an earlier one of
    /// the same name, case aside.
    var headers: [(name: String, value: String)]
    var body: Data?
    /// The parts of a multipart body, kept for display and cURL.
    var multipart: [MultipartPart] = []
    /// Variables the request uses that nothing defines.
    var unresolved: [String] = []

    static func == (a: APIRequestPlan, b: APIRequestPlan) -> Bool {
        a.method == b.method && a.url == b.url && a.headers.map(\.name) == b.headers.map(\.name)
            && a.headers.map(\.value) == b.headers.map(\.value) && a.body == b.body && a.multipart == b.multipart
            && a.unresolved == b.unresolved
    }

    struct MultipartPart: Equatable, Sendable {
        var name: String
        var value: String?
        var file: URL?
        var contentType: String?
    }

    enum Problem: LocalizedError, Equatable {
        case badURL(String)
        case unsupportedAuth(String)
        case missingFile(String)
        case badGraphQLVariables(String)

        var errorDescription: String? {
            switch self {
            case .badURL(let url): "“\(url)” isn't a URL."
            case .unsupportedAuth(let mode): "Overterm doesn't send \(mode) auth yet — run this request with bru."
            case .missingFile(let path): "The file \(path) isn't there."
            case .badGraphQLVariables(let detail): "The GraphQL variables aren't JSON: \(detail)"
            }
        }
    }

    func header(_ name: String) -> String? {
        headers.last { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Everything around a request file that decides how it is sent.
    struct Context: Sendable {
        var collectionRoot: URL?
        /// collection.bru, then each folder.bru from the outside in.
        var collectionFile: BruFile?
        var folderFiles: [BruFile] = []
        var variables = APIVariables()
        /// Headers a pre-request script deleted (lower case): gone even when
        /// the collection or a folder sets them.
        var removedHeaders: Set<String> = []
    }

    static func make(_ file: BruFile, context: Context) throws -> APIRequestPlan {
        // The context brings the environment, the runtime and process.env;
        // the files bring their own layers.
        var vars = context.variables
        vars.collection = APIVariables.map(context.collectionFile?.preRequestVars ?? [])
        vars.folders = context.folderFiles.map { APIVariables.map($0.preRequestVars) }
        vars.request = APIVariables.map(file.preRequestVars)
        let fill = { vars.interpolate($0) }

        // The URL: variables, then :path params, then the query.
        var address = fill(file.url).trimmingCharacters(in: .whitespaces)
        for param in file.pathParams where param.enabled {
            address = replacePathParam(param.key, with: fill(param.value), in: address)
        }
        if !address.isEmpty, !address.contains("://") { address = "http://" + address }

        // Headers: the collection's, each folder's, the request's — and
        // auth, which may add one or a query parameter.
        var headers: [(name: String, value: String)] = []
        func add(_ pairs: [BruPair]) {
            for pair in pairs where pair.enabled {
                headers.removeAll { $0.name.caseInsensitiveCompare(pair.key) == .orderedSame }
                headers.append((pair.key, fill(pair.value)))
            }
        }
        add(context.collectionFile?.headers ?? [])
        context.folderFiles.forEach { add($0.headers) }
        add(file.headers)
        headers.removeAll { context.removedHeaders.contains($0.name.lowercased()) }

        var extraQuery: [URLQueryItem] = []
        let (authFile, authMode) = effectiveAuth(file, context: context)
        switch authMode {
        case .none, .inherit: break
        case .bearer:
            let token = fill(authFile.value("token", in: "auth:bearer") ?? "")
            if !token.isEmpty { add([BruPair(key: "Authorization", value: "Bearer \(token)")]) }
        case .basic:
            let user = fill(authFile.value("username", in: "auth:basic") ?? "")
            let password = fill(authFile.value("password", in: "auth:basic") ?? "")
            add([BruPair(key: "Authorization", value: "Basic " + Data("\(user):\(password)".utf8).base64EncodedString())])
        case .apikey:
            let key = fill(authFile.value("key", in: "auth:apikey") ?? "")
            let value = fill(authFile.value("value", in: "auth:apikey") ?? "")
            if !key.isEmpty {
                if authFile.value("placement", in: "auth:apikey") == "queryparams" {
                    extraQuery.append(URLQueryItem(name: key, value: value))
                } else {
                    add([BruPair(key: key, value: value)])
                }
            }
        default:
            throw Problem.unsupportedAuth(authMode.title)
        }

        guard var url = makeURL(address, encode: file.encodesURL) else { throw Problem.badURL(address) }
        if !extraQuery.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = (components.queryItems ?? []) + extraQuery
            url = components.url ?? url
        }

        // The body.
        var body: Data?
        var parts: [MultipartPart] = []
        let mode = file.bodyMode
        switch mode {
        case .none: break
        case .json, .text, .xml, .sparql:
            body = Data(fill(file.body(mode) ?? "").utf8)
        case .graphql:
            var payload: [String: Any] = ["query": fill(file.body(.graphql) ?? "")]
            let variables = fill(file.graphQLVariables ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !variables.isEmpty {
                do {
                    payload["variables"] = try JSONSerialization.jsonObject(with: Data(variables.utf8), options: [.fragmentsAllowed])
                } catch {
                    throw Problem.badGraphQLVariables(error.localizedDescription)
                }
            }
            body = try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
        case .formUrlEncoded:
            body = Data(
                file.formFields.filter(\.enabled).map { "\(formEncode(fill($0.key)))=\(formEncode(fill($0.value)))" }.joined(
                    separator: "&"
                ).utf8)
        case .multipartForm:
            for field in file.multipartFields where field.enabled {
                let (value, type) = splitContentType(field.value)
                if let path = filePath(value) {
                    let fileURL = resolve(fill(path), against: context.collectionRoot)
                    guard FileManager.default.fileExists(atPath: fileURL.path) else { throw Problem.missingFile(fileURL.path) }
                    parts.append(MultipartPart(name: fill(field.key), file: fileURL, contentType: type ?? mimeType(of: fileURL)))
                } else {
                    parts.append(MultipartPart(name: fill(field.key), value: fill(value), contentType: type))
                }
            }
        case .file:
            if let chosen = file.pairs("body:file").first(where: \.enabled) {
                let (value, type) = splitContentType(chosen.value)
                if let path = filePath(value) {
                    let fileURL = resolve(fill(path), against: context.collectionRoot)
                    guard let data = try? Data(contentsOf: fileURL) else { throw Problem.missingFile(fileURL.path) }
                    body = data
                    if let type, !headers.contains(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
                        headers.append(("Content-Type", type))
                    }
                }
            }
        }

        if !parts.isEmpty || mode == .multipartForm {
            let boundary = "----OvertermBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            headers.removeAll { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }
            headers.append(("Content-Type", "multipart/form-data; boundary=\(boundary)"))
            body = try multipartBody(parts, boundary: boundary)
        } else if let type = mode.contentType,
            !headers.contains(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame })
        {
            headers.append(("Content-Type", type))
        }

        var unresolved = vars.unresolved(in: file.url)
        for pair in file.headers where pair.enabled {
            for name in vars.unresolved(in: pair.value) where !unresolved.contains(name) { unresolved.append(name) }
        }
        return APIRequestPlan(
            method: file.method, url: url, headers: headers, body: body, multipart: parts, unresolved: unresolved)
    }

    /// The request's auth, or — `inherit` — the nearest folder's that says
    /// one, else the collection's.
    static func effectiveAuth(_ file: BruFile, context: Context) -> (BruFile, BruFile.AuthMode) {
        guard file.authMode == .inherit else { return (file, file.authMode) }
        for folder in context.folderFiles.reversed() where folder.has("auth") {
            let mode = folder.defaultAuthMode
            if mode != .inherit { return (folder, mode) }
        }
        if let collection = context.collectionFile, collection.has("auth") { return (collection, collection.defaultAuthMode) }
        return (file, .none)
    }

    // MARK: Pieces

    /// `/users/:id` with `id` → `/users/42`; only whole path segments.
    static func replacePathParam(_ name: String, with value: String, in address: String) -> String {
        let queryStart = address.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? address.endIndex
        let path = address[..<queryStart]
        let rest = address[queryStart...]
        let segments = path.components(separatedBy: "/").map { $0 == ":\(name)" ? value : $0 }
        return segments.joined(separator: "/") + rest
    }

    /// Parsed as given when it already is a URL; else with what isn't
    /// allowed in one percent-encoded (spaces, non-ASCII), as Bruno's
    /// encodeUrl does — `%` already there is left alone.
    static func makeURL(_ address: String, encode: Bool) -> URL? {
        guard !address.isEmpty else { return nil }
        if let url = URL(string: address), url.scheme != nil, url.host != nil { return url }
        guard encode else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert("%")
        allowed.insert("#")
        return address.addingPercentEncoding(withAllowedCharacters: allowed).flatMap(URL.init(string:))
    }

    /// application/x-www-form-urlencoded, as Bruno's (qs) writes it.
    static func formEncode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// `@file(path)` → path.
    static func filePath(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("@file("), trimmed.hasSuffix(")") else { return nil }
        return String(trimmed.dropFirst(6).dropLast())
    }

    /// `value @contentType(type)` → (value, type).
    static func splitContentType(_ value: String) -> (String, String?) {
        guard let marker = value.range(of: " @contentType("), value.hasSuffix(")") else { return (value, nil) }
        let type = value[marker.upperBound..<value.index(before: value.endIndex)]
        return (String(value[..<marker.lowerBound]), String(type))
    }

    static func resolve(_ path: String, against root: URL?) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return (root ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).appendingPathComponent(expanded)
    }

    static func mimeType(of url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    static func multipartBody(_ parts: [MultipartPart], boundary: String) throws -> Data {
        var data = Data()
        for part in parts {
            data.append(Data("--\(boundary)\r\n".utf8))
            if let file = part.file {
                let name = part.name.replacingOccurrences(of: "\"", with: "%22")
                data.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(file.lastPathComponent)\"\r\n".utf8))
                data.append(Data("Content-Type: \(part.contentType ?? "application/octet-stream")\r\n\r\n".utf8))
                data.append(try Data(contentsOf: file))
            } else {
                data.append(Data("Content-Disposition: form-data; name=\"\(part.name.replacingOccurrences(of: "\"", with: "%22"))\"\r\n".utf8))
                if let type = part.contentType { data.append(Data("Content-Type: \(type)\r\n".utf8)) }
                data.append(Data("\r\n".utf8))
                data.append(Data((part.value ?? "").utf8))
            }
            data.append(Data("\r\n".utf8))
        }
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }

    // MARK: cURL

    /// The request as a cURL command, one option a line.
    var curl: String {
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var lines = ["curl -X \(method) \(quote(url.absoluteString))"]
        for header in headers where !(header.name.lowercased() == "content-type" && !multipart.isEmpty) {
            lines.append("-H \(quote("\(header.name): \(header.value)"))")
        }
        if !multipart.isEmpty {
            for part in multipart {
                if let file = part.file {
                    lines.append("-F \(quote("\(part.name)=@\(file.path)"))")
                } else {
                    lines.append("-F \(quote("\(part.name)=\(part.value ?? "")"))")
                }
            }
        } else if let body {
            let text = String(data: body, encoding: .utf8) ?? "<\(body.count) bytes>"
            lines.append("--data-raw \(quote(text))")
        }
        return lines.joined(separator: " \\\n  ")
    }
}
