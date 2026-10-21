import Foundation

/// A cURL command — as a browser's "Copy as cURL" writes it, or a README —
/// made into a request.
enum CurlParser {
    enum Problem: LocalizedError, Equatable {
        case notCurl
        case noURL
        var errorDescription: String? {
            switch self {
            case .notCurl: "That isn't a curl command."
            case .noURL: "The curl command has no URL."
            }
        }
    }

    static func parse(_ command: String) throws -> BruFile {
        let words = tokenize(command)
        guard words.first.map({ $0 == "curl" || $0.hasSuffix("/curl") }) == true else { throw Problem.notCurl }
        var method: String?
        var url: String?
        var headers: [BruPair] = []
        var data: [String] = []
        var form: [BruPair] = []
        var user: String?
        var asQuery = false
        let takesValue: Set<String> = [
            "-X", "--request", "-H", "--header", "-d", "--data", "--data-raw", "--data-binary", "--data-ascii", "--data-urlencode", "-F",
            "--form", "-u", "--user", "-A", "--user-agent", "-e", "--referer", "-b", "--cookie", "--url", "-o", "--output", "-m",
            "--max-time", "--connect-timeout", "-x", "--proxy", "-w", "--write-out",
        ]
        var index = 1
        while index < words.count {
            var word = words[index]
            var value: String?
            if word.hasPrefix("--"), let equals = word.firstIndex(of: "=") {
                value = String(word[word.index(after: equals)...])
                word = String(word[..<equals])
            } else if word.count > 2, word.hasPrefix("-"), !word.hasPrefix("--"), takesValue.contains(String(word.prefix(2))) {
                // -XPOST, -HAccept:…
                value = String(word.dropFirst(2))
                word = String(word.prefix(2))
            }
            if takesValue.contains(word), value == nil {
                index += 1
                value = index < words.count ? words[index] : ""
            }
            switch word {
            case "-X", "--request": method = value?.lowercased()
            case "-H", "--header":
                if let value, let colon = value.firstIndex(of: ":") {
                    headers.append(
                        BruPair(
                            key: value[..<colon].trimmingCharacters(in: .whitespaces),
                            value: value[value.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
                }
            case "-d", "--data", "--data-raw", "--data-binary", "--data-ascii": data.append(value ?? "")
            case "--data-urlencode":
                // Its value is given unencoded: `name=a+b&c` is one field
                // whose value is "a+b&c". Encoded here, so it reads back so.
                let raw = value ?? ""
                if let equals = raw.firstIndex(of: "=") {
                    data.append(String(raw[..<equals]) + "=" + APIRequestPlan.formEncode(String(raw[raw.index(after: equals)...])))
                } else {
                    data.append(APIRequestPlan.formEncode(raw))
                }
            case "-F", "--form":
                if let value, let equals = value.firstIndex(of: "=") {
                    let key = String(value[..<equals])
                    var field = String(value[value.index(after: equals)...])
                    if field.hasPrefix("@") { field = "@file(\(field.dropFirst()))" }
                    form.append(BruPair(key: key, value: field))
                }
            case "-u", "--user": user = value
            case "-A", "--user-agent": headers.append(BruPair(key: "User-Agent", value: value ?? ""))
            case "-e", "--referer": headers.append(BruPair(key: "Referer", value: value ?? ""))
            case "-b", "--cookie": headers.append(BruPair(key: "Cookie", value: value ?? ""))
            case "--url": url = value
            case "-G", "--get": asQuery = true
            case "-I", "--head": method = "head"
            default:
                if !word.hasPrefix("-"), url == nil { url = word }
            }
            index += 1
        }
        guard var address = url, !address.isEmpty else { throw Problem.noURL }
        let joined = data.joined(separator: "&")
        if asQuery, !joined.isEmpty {
            address += (address.contains("?") ? "&" : "?") + joined
        }
        let verb = method ?? ((!data.isEmpty && !asQuery) || !form.isEmpty ? "post" : "get")
        let path = URL(string: address)?.path ?? ""
        let title = "\(verb.uppercased()) \(path.split(separator: "/").last.map(String.init) ?? (URL(string: address)?.host ?? "request"))"
        var file = BruFile.newRequest(name: title, method: BruFile.methods.contains(verb) ? verb : "get", url: address, seq: 1)
        file.queryParams = APIRequestModel.queryPairs(of: address)
        file.pathParams = []
        file.authMode = .none
        if let user {
            let parts = user.split(separator: ":", maxSplits: 1).map(String.init)
            file.authMode = .basic
            file.setAuth(.basic, [BruPair(key: "username", value: parts.first ?? ""), BruPair(key: "password", value: parts.count > 1 ? parts[1] : "")])
        }
        let type = headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? ""
        if !form.isEmpty {
            file.bodyMode = .multipartForm
            file.multipartFields = form
        } else if !joined.isEmpty, !asQuery {
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            if type.contains("json") || trimmed.first == "{" || trimmed.first == "[" {
                file.bodyMode = .json
                file.setBody(.json, prettyIfJSON(trimmed))
                headers.removeAll { $0.key.lowercased() == "content-type" && $0.value.lowercased() == "application/json" }
            } else if type.isEmpty || type.contains("x-www-form-urlencoded"), trimmed.contains("=") {
                file.bodyMode = .formUrlEncoded
                file.formFields = formPairs(trimmed)
                headers.removeAll { $0.key.lowercased() == "content-type" }
            } else if type.contains("xml") {
                file.bodyMode = .xml
                file.setBody(.xml, trimmed)
            } else {
                file.bodyMode = .text
                file.setBody(.text, trimmed)
            }
        }
        file.headers = headers
        return file
    }

    private static func prettyIfJSON(_ text: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return text }
        let pretty = APIImport.prettyJSON(object)
        return pretty.isEmpty ? text : pretty
    }

    /// `a=1&b=x%20y` → pairs, decoded.
    static func formPairs(_ text: String) -> [BruPair] {
        text.split(separator: "&").map { part in
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            return BruPair(key: pieces[0], value: pieces.count > 1 ? pieces[1] : "")
        }
    }

    /// Words as a POSIX shell splits them: quotes, backslashes, `$'…'`,
    /// line continuations.
    static func tokenize(_ command: String) -> [String] {
        var words: [String] = []
        var word = ""
        var inWord = false
        var chars = Array(command.replacingOccurrences(of: "\\\r\n", with: " ").replacingOccurrences(of: "\\\n", with: " "))
        var index = 0
        func flush() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }
        while index < chars.count {
            let char = chars[index]
            switch char {
            case " ", "\t", "\n", "\r":
                flush()
            case "'":
                inWord = true
                index += 1
                while index < chars.count, chars[index] != "'" {
                    word.append(chars[index])
                    index += 1
                }
            case "\"":
                inWord = true
                index += 1
                while index < chars.count, chars[index] != "\"" {
                    if chars[index] == "\\", index + 1 < chars.count, "\"\\$`\n".contains(chars[index + 1]) {
                        index += 1
                    }
                    word.append(chars[index])
                    index += 1
                }
            case "$" where index + 1 < chars.count && chars[index + 1] == "'":
                inWord = true
                index += 2
                while index < chars.count, chars[index] != "'" {
                    if chars[index] == "\\", index + 1 < chars.count {
                        index += 1
                        switch chars[index] {
                        case "n": word.append("\n")
                        case "t": word.append("\t")
                        case "r": word.append("\r")
                        default: word.append(chars[index])
                        }
                    } else {
                        word.append(chars[index])
                    }
                    index += 1
                }
            case "\\":
                inWord = true
                if index + 1 < chars.count {
                    index += 1
                    word.append(chars[index])
                }
            default:
                inWord = true
                word.append(char)
            }
            index += 1
        }
        flush()
        chars.removeAll()
        return words
    }
}
