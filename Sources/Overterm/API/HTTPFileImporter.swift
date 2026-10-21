import Foundation

/// The REST Client / JetBrains `.http` format: requests apart by `###`, a
/// request line, its headers, a blank line, its body; `@name = value`
/// lines are variables; `# @name` names a request.
enum HTTPFileImporter {
    static func make(_ text: String, name: String) -> APIImport {
        var variables: [BruPair] = []
        var requests: [APIImport.Request] = []
        var notes: [String] = []
        // Written on Windows, each line ended in \r: no blank line was blank,
        // and the headers ran into the body.
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = text.components(separatedBy: "\n").split(omittingEmptySubsequences: false, whereSeparator: { $0.hasPrefix("###") })
        for block in blocks {
            var lines = Array(block)
            var title: String?
            // Variables and comments before the request line.
            while let line = lines.first {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("@"), let equals = trimmed.firstIndex(of: "=") {
                    let key = trimmed.dropFirst()[..<equals].trimmingCharacters(in: .whitespaces)
                    variables.append(BruPair(key: key, value: trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)))
                } else if trimmed.hasPrefix("#") || trimmed.hasPrefix("//") {
                    let comment = trimmed.drop { $0 == "#" || $0 == "/" }.trimmingCharacters(in: .whitespaces)
                    if comment.hasPrefix("@name ") { title = String(comment.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
                } else if !trimmed.isEmpty {
                    break
                }
                lines.removeFirst()
            }
            guard let requestLine = lines.first?.trimmingCharacters(in: .whitespaces), !requestLine.isEmpty else { continue }
            lines.removeFirst()
            var parts = requestLine.split(separator: " ").map(String.init)
            if parts.last?.hasPrefix("HTTP/") == true { parts.removeLast() }
            let method = parts.count > 1 && BruFile.methods.contains(parts[0].lowercased()) ? parts.removeFirst().lowercased() : "get"
            var url = parts.joined(separator: " ")
            var headers: [BruPair] = []
            while let line = lines.first, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeFirst()
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") || trimmed.hasPrefix("//") { continue }
                if trimmed.hasPrefix("?") || trimmed.hasPrefix("&") {
                    // A query continued on its own line belongs to the URL.
                    url += trimmed.hasPrefix("&") && !url.contains("?") ? "?" + trimmed.dropFirst() : trimmed
                    continue
                }
                if let colon = trimmed.firstIndex(of: ":") {
                    headers.append(
                        BruPair(
                            key: trimmed[..<colon].trimmingCharacters(in: .whitespaces),
                            value: trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
                }
            }
            var bodyLines = Array(lines.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            if let handler = bodyLines.firstIndex(where: { $0.hasPrefix("> {%") || $0.hasPrefix("> ") }) {
                notes.append("Response handler scripts (> {% … %}) aren't carried over.")
                bodyLines = Array(bodyLines[..<handler])
            }
            let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            var file = BruFile.newRequest(
                name: title ?? "\(method.uppercased()) \(displayPath(url))", method: method, url: url, seq: 1)
            file.headers = headers.filter { $0.key.lowercased() != "content-length" }
            file.queryParams = APIRequestModel.queryPairs(of: url)
            file.pathParams = APIRequestModel.pathParamNames(in: url).map { BruPair(key: $0, value: "") }
            if !body.isEmpty {
                let type = headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? ""
                if type.contains("x-www-form-urlencoded") {
                    file.bodyMode = .formUrlEncoded
                    file.formFields = CurlParser.formPairs(body)
                } else if type.contains("json") || body.first == "{" || body.first == "[" {
                    file.bodyMode = .json
                    file.setBody(.json, body)
                } else if type.contains("xml") {
                    file.bodyMode = .xml
                    file.setBody(.xml, body)
                } else {
                    file.bodyMode = .text
                    file.setBody(.text, body)
                }
            }
            requests.append(APIImport.Request(file: file))
        }
        var environment = BruFile()
        environment.variables = variables
        return APIImport(
            name: name, root: APIImport.Folder(name: name, requests: requests), collectionFile: nil,
            environments: variables.isEmpty ? [] : [APIImport.Environment(name: "Local", file: environment)], notes: Array(Set(notes)))
    }

    /// `{{host}}/items?x=1` or `https://h/items` → `/items`: a request's
    /// name when nothing names it.
    static func displayPath(_ url: String) -> String {
        var rest = Substring(url)
        if rest.hasPrefix("{{"), let close = rest.range(of: "}}") {
            rest = rest[close.upperBound...]
        } else if let scheme = rest.range(of: "://") {
            rest = rest[scheme.upperBound...]
            rest = rest.firstIndex(of: "/").map { rest[$0...] } ?? "/"
        }
        if let query = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = rest[..<query] }
        return rest.isEmpty ? "/" : String(rest)
    }
}
