import Foundation

/// What a request file says, read and written through its blocks — so
/// every edit made here is one Bruno makes the same way.
extension BruFile {
    static let methods = ["get", "post", "put", "patch", "delete", "options", "head", "connect", "trace"]

    /// The body kinds Bruno knows, as `body:` says them, and their blocks.
    enum BodyMode: String, CaseIterable, Sendable {
        case none, json, text, xml, sparql, formUrlEncoded, multipartForm, file, graphql

        init(bru: String) {
            switch bru {
            case "formUrlEncoded", "form-urlencoded": self = .formUrlEncoded
            case "multipartForm", "multipart-form": self = .multipartForm
            default: self = BodyMode(rawValue: bru) ?? .none
            }
        }

        var block: String? {
            switch self {
            case .none: nil
            case .formUrlEncoded: "body:form-urlencoded"
            case .multipartForm: "body:multipart-form"
            default: "body:\(rawValue)"
            }
        }

        var title: String {
            switch self {
            case .none: "No Body"
            case .json: "JSON"
            case .text: "Text"
            case .xml: "XML"
            case .sparql: "SPARQL"
            case .formUrlEncoded: "Form URL Encoded"
            case .multipartForm: "Multipart Form"
            case .file: "File"
            case .graphql: "GraphQL"
            }
        }

        /// The Content-Type Bruno sends for it unless a header says otherwise.
        var contentType: String? {
            switch self {
            case .json, .graphql: "application/json"
            case .text: "text/plain"
            case .xml: "application/xml"
            case .sparql: "application/sparql-query"
            case .formUrlEncoded: "application/x-www-form-urlencoded"
            case .none, .multipartForm, .file: nil
            }
        }
    }

    /// The auth kinds of `auth:`; `inherit` takes the folder's or the collection's.
    enum AuthMode: String, CaseIterable, Sendable {
        case none, inherit, bearer, basic, apikey, digest, oauth2, awsv4, ntlm, wsse

        var title: String {
            switch self {
            case .none: "No Auth"
            case .inherit: "Inherit"
            case .bearer: "Bearer Token"
            case .basic: "Basic Auth"
            case .apikey: "API Key"
            case .digest: "Digest Auth"
            case .oauth2: "OAuth 2.0"
            case .awsv4: "AWS Sig v4"
            case .ntlm: "NTLM"
            case .wsse: "WSSE"
            }
        }

        /// Sent by Overterm; the rest are kept in the file and run by `bru`.
        var isSupported: Bool { [.none, .inherit, .bearer, .basic, .apikey].contains(self) }
    }

    // MARK: meta

    var name: String {
        get { value("name", in: "meta") ?? "" }
        set { setValue(newValue, for: "name", in: "meta") }
    }

    /// `http` or `graphql`.
    var requestType: String {
        get { value("type", in: "meta") ?? "http" }
        set { setValue(newValue, for: "type", in: "meta") }
    }

    var seq: Int? {
        get { value("seq", in: "meta").flatMap(Int.init) }
        set { newValue.map { setValue(String($0), for: "seq", in: "meta") } ?? removeValue("seq", in: "meta") }
    }

    /// A request file has a method block; folder.bru, collection.bru and
    /// environments don't.
    var isRequest: Bool { methodBlock != nil }

    // MARK: The method block

    private var methodBlock: String? { blocks.first { Self.methods.contains($0.name) }?.name }

    /// Upper case, as shown; the block is named in lower case.
    var method: String {
        get { (methodBlock ?? "get").uppercased() }
        set {
            let new = newValue.lowercased()
            guard Self.methods.contains(new) else { return }
            if let old = methodBlock { rename(old, to: new) } else { setPairs(new, [BruPair(key: "url", value: "")], keepEmpty: true) }
        }
    }

    private var methodName: String { methodBlock ?? "get" }

    var url: String {
        get { value("url", in: methodName) ?? "" }
        set { setValue(newValue, for: "url", in: methodName) }
    }

    var bodyMode: BodyMode {
        get { BodyMode(bru: value("body", in: methodName) ?? "none") }
        set { setValue(newValue.rawValue, for: "body", in: methodName) }
    }

    var authMode: AuthMode {
        get { AuthMode(rawValue: value("auth", in: methodName) ?? "none") ?? .none }
        set { setValue(newValue.rawValue, for: "auth", in: methodName) }
    }

    /// Folder and collection files keep their auth mode in `auth { mode: }`.
    var defaultAuthMode: AuthMode {
        get { AuthMode(rawValue: value("mode", in: "auth") ?? "none") ?? .none }
        set { setValue(newValue.rawValue, for: "mode", in: "auth") }
    }

    // MARK: Parts

    var queryParams: [BruPair] {
        get { pairs("params:query") }
        set { setPairs("params:query", newValue) }
    }

    var pathParams: [BruPair] {
        get { pairs("params:path") }
        set { setPairs("params:path", newValue) }
    }

    var headers: [BruPair] {
        get { pairs("headers") }
        set { setPairs("headers", newValue) }
    }

    /// The fields of `auth:<mode>`: token; username, password; key, value, placement.
    func auth(_ mode: AuthMode) -> [BruPair] { pairs("auth:\(mode.rawValue)") }

    mutating func setAuth(_ mode: AuthMode, _ fields: [BruPair]) { setPairs("auth:\(mode.rawValue)", fields) }

    /// The text of the body block for `mode` (JSON, text, XML, the GraphQL query).
    func body(_ mode: BodyMode) -> String? { mode.block.flatMap(textBlock) }

    mutating func setBody(_ mode: BodyMode, _ text: String?) {
        guard let block = mode.block else { return }
        setText(block, text)
    }

    var formFields: [BruPair] {
        get { pairs("body:form-urlencoded") }
        set { setPairs("body:form-urlencoded", newValue) }
    }

    var multipartFields: [BruPair] {
        get { pairs("body:multipart-form") }
        set { setPairs("body:multipart-form", newValue) }
    }

    var graphQLVariables: String? {
        get { textBlock("body:graphql:vars") }
        set { setText("body:graphql:vars", newValue) }
    }

    var preRequestVars: [BruPair] {
        get { pairs("vars:pre-request") }
        set { setPairs("vars:pre-request", newValue) }
    }

    var postResponseVars: [BruPair] {
        get { pairs("vars:post-response") }
        set { setPairs("vars:post-response", newValue) }
    }

    var assertions: [BruPair] {
        get { pairs("assert") }
        set { setPairs("assert", newValue) }
    }

    var preRequestScript: String? {
        get { textBlock("script:pre-request") }
        set { setText("script:pre-request", newValue.flatMap { $0.isEmpty ? nil : $0 }) }
    }

    var postResponseScript: String? {
        get { textBlock("script:post-response") }
        set { setText("script:post-response", newValue.flatMap { $0.isEmpty ? nil : $0 }) }
    }

    var tests: String? {
        get { textBlock("tests") }
        set { setText("tests", newValue.flatMap { $0.isEmpty ? nil : $0 }) }
    }

    var docs: String? {
        get { textBlock("docs") }
        set { setText("docs", newValue.flatMap { $0.isEmpty ? nil : $0 }) }
    }

    /// `settings { encodeUrl: … }`: whether the URL is percent-encoded
    /// before it is sent. Bruno's default for new requests is true.
    var encodesURL: Bool {
        get { value("encodeUrl", in: "settings").map { $0 == "true" } ?? true }
        set { setValue(newValue ? "true" : "false", for: "encodeUrl", in: "settings") }
    }

    // MARK: Environments

    /// An environment file's `vars { }`.
    var variables: [BruPair] {
        get { pairs("vars") }
        set { setPairs("vars", newValue) }
    }

    /// `vars:secret [ … ]`: names whose values live outside the file.
    var secretNames: [String] {
        get { list("vars:secret") }
        set { setList("vars:secret", newValue) }
    }

    // MARK: New files

    /// A new request file, laid out as Bruno writes one.
    static func newRequest(name: String, method: String = "get", url: String = "", seq: Int) -> BruFile {
        var file = BruFile()
        file.setPairs(
            "meta", [BruPair(key: "name", value: name), BruPair(key: "type", value: "http"), BruPair(key: "seq", value: String(seq))])
        file.setPairs(
            method.lowercased(), [BruPair(key: "url", value: url), BruPair(key: "body", value: "none"), BruPair(key: "auth", value: "inherit")],
            keepEmpty: true)
        file.setPairs("settings", [BruPair(key: "encodeUrl", value: "true")])
        return file
    }
}
