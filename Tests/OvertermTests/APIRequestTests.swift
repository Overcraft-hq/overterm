import XCTest

@testable import Overterm

/// A request file made into what goes out, and sent to a server on this
/// machine that answers with what it got.
final class APIRequestTests: XCTestCase {
    private func file(_ text: String) -> BruFile { BruFile(parsing: text) }

    private func plan(_ text: String, context: APIRequestPlan.Context = .init()) throws -> APIRequestPlan {
        try APIRequestPlan.make(file(text), context: context)
    }

    // MARK: Planning

    func testVariablesPathParamsAndTheQueryMakeTheURL() throws {
        var context = APIRequestPlan.Context()
        context.variables.environment = ["baseUrl": "http://localhost:3000", "id": "7"]
        let made = try plan(
            "get {\n  url: {{baseUrl}}/users/:id/posts?draft=true\n}\n\nparams:path {\n  id: {{id}}\n}\n", context: context)
        XCTAssertEqual(made.url.absoluteString, "http://localhost:3000/users/7/posts?draft=true")
        XCTAssertEqual(made.method, "GET")
    }

    func testAnAddressWithoutASchemeIsHTTPAndSpacesAreEncoded() throws {
        XCTAssertEqual(try plan("get {\n  url: localhost:8080/a b?q=x y\n}\n").url.absoluteString, "http://localhost:8080/a%20b?q=x%20y")
        XCTAssertThrowsError(try plan("get {\n  url: \n}\n"))
    }

    /// The collection's headers, a folder's, the request's: the nearest wins, case aside.
    func testHeadersLayerAndTheNearestWins() throws {
        var context = APIRequestPlan.Context()
        context.collectionFile = file("headers {\n  X-App: overterm\n  Accept: text/plain\n}\n")
        context.folderFiles = [file("headers {\n  accept: application/xml\n  X-Folder: 1\n}\n")]
        let made = try plan("get {\n  url: http://x\n}\n\nheaders {\n  ACCEPT: application/json\n  ~X-Off: 1\n}\n", context: context)
        XCTAssertEqual(made.headers.map(\.name), ["X-App", "X-Folder", "ACCEPT"])
        XCTAssertEqual(made.header("accept"), "application/json")
        XCTAssertNil(made.header("X-Off"))
    }

    func testAuthIsTheRequestsOrInheritedFromTheNearestFolderThenTheCollection() throws {
        var context = APIRequestPlan.Context()
        context.variables.environment = ["token": "abc"]
        context.collectionFile = file("auth {\n  mode: basic\n}\n\nauth:basic {\n  username: u\n  password: p\n}\n")
        let inherit = "get {\n  url: http://x\n  auth: inherit\n}\n"
        XCTAssertEqual(try plan(inherit, context: context).header("Authorization"), "Basic dTpw")
        context.folderFiles = [
            file("auth {\n  mode: bearer\n}\n\nauth:bearer {\n  token: {{token}}\n}\n"), file("auth {\n  mode: inherit\n}\n"),
        ]
        XCTAssertEqual(try plan(inherit, context: context).header("Authorization"), "Bearer abc")
        let own = "get {\n  url: http://x\n  auth: apikey\n}\n\nauth:apikey {\n  key: api_key\n  value: k\n  placement: queryparams\n}\n"
        let keyed = try plan(own, context: context)
        XCTAssertEqual(keyed.url.absoluteString, "http://x?api_key=k")
        XCTAssertNil(keyed.header("Authorization"))
        XCTAssertNil(try plan("get {\n  url: http://x\n  auth: none\n}\n", context: context).header("Authorization"))
        XCTAssertThrowsError(try plan("get {\n  url: http://x\n  auth: awsv4\n}\n")) { error in
            XCTAssertEqual(error as? APIRequestPlan.Problem, .unsupportedAuth("AWS Sig v4"))
        }
    }

    func testAJSONBodyIsFilledInAndGetsItsContentType() throws {
        var context = APIRequestPlan.Context()
        context.variables.environment = ["name": "Ada"]
        let made = try plan("post {\n  url: http://x\n  body: json\n}\n\nbody:json {\n  {\"name\": \"{{name}}\"}\n}\n", context: context)
        XCTAssertEqual(made.body.map { String(decoding: $0, as: UTF8.self) }, "{\"name\": \"Ada\"}")
        XCTAssertEqual(made.header("Content-Type"), "application/json")
        let typed = try plan(
            "post {\n  url: http://x\n  body: json\n}\n\nheaders {\n  content-type: application/vnd.api+json\n}\n\nbody:json {\n  {}\n}\n")
        XCTAssertEqual(typed.headers.filter { $0.name.lowercased() == "content-type" }.map(\.value), ["application/vnd.api+json"])
    }

    func testAFormIsURLEncodedTheWayBrunoEncodesIt() throws {
        let made = try plan(
            "post {\n  url: http://x\n  body: formUrlEncoded\n}\n\nbody:form-urlencoded {\n  q: a b&c\n  ~off: 1\n  n: é\n}\n")
        XCTAssertEqual(made.body.map { String(decoding: $0, as: UTF8.self) }, "q=a%20b%26c&n=%C3%A9")
        XCTAssertEqual(made.header("Content-Type"), "application/x-www-form-urlencoded")
    }

    func testGraphQLIsAJSONQueryWithItsVariables() throws {
        let made = try plan(
            "post {\n  url: http://x/graphql\n  body: graphql\n}\n\nbody:graphql {\n  query { me { id } }\n}\n\nbody:graphql:vars {\n  {\"a\": 1}\n}\n")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(made.body)) as? [String: Any])
        XCTAssertEqual(json["query"] as? String, "query { me { id } }")
        XCTAssertEqual((json["variables"] as? [String: Int])?["a"], 1)
        XCTAssertThrowsError(
            try plan("post {\n  url: http://x\n  body: graphql\n}\n\nbody:graphql {\n  q\n}\n\nbody:graphql:vars {\n  {nope\n}\n"))
    }

    func testAMultipartFormCarriesFieldsAndFilesFromTheCollection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("multipart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("hello".utf8).write(to: root.appendingPathComponent("note.txt"))
        var context = APIRequestPlan.Context()
        context.collectionRoot = root
        let made = try plan(
            "post {\n  url: http://x\n  body: multipartForm\n}\n\nbody:multipart-form {\n  title: Hi\n  doc: @file(note.txt)\n  meta: {} @contentType(application/json)\n}\n",
            context: context)
        let type = try XCTUnwrap(made.header("Content-Type"))
        XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: try XCTUnwrap(made.body), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"title\"\r\n\r\nHi\r\n"))
        XCTAssertTrue(body.contains("name=\"doc\"; filename=\"note.txt\"\r\nContent-Type: text/plain\r\n\r\nhello\r\n"))
        XCTAssertTrue(body.contains("name=\"meta\"\r\nContent-Type: application/json\r\n\r\n{}\r\n"))
        XCTAssertTrue(body.hasSuffix("--\(type.components(separatedBy: "boundary=")[1])--\r\n"))
        XCTAssertThrowsError(
            try plan("post {\n  url: http://x\n  body: multipartForm\n}\n\nbody:multipart-form {\n  f: @file(gone.bin)\n}\n", context: context))
    }

    func testRequestAndFolderVariablesAreLayered() throws {
        var context = APIRequestPlan.Context()
        context.collectionFile = file("vars:pre-request {\n  host: collection\n  path: c\n}\n")
        context.folderFiles = [file("vars:pre-request {\n  path: folder\n}\n")]
        context.variables.environment = ["host": "env"]
        let made = try plan("get {\n  url: http://{{host}}/{{path}}/{{leaf}}\n}\n\nvars:pre-request {\n  leaf: request\n}\n", context: context)
        XCTAssertEqual(made.url.absoluteString, "http://env/folder/request")
    }

    func testUnresolvedVariablesAreNamed() throws {
        XCTAssertEqual(try plan("get {\n  url: http://x/{{id}}\n}\n\nheaders {\n  a: {{token}}\n}\n").unresolved, ["id", "token"])
    }

    func testCurlSaysWhatSendWould() throws {
        let made = try plan("post {\n  url: http://x/a\n  body: json\n}\n\nheaders {\n  X-Q: it's\n}\n\nbody:json {\n  {\"a\":1}\n}\n")
        XCTAssertEqual(
            made.curl,
            "curl -X POST 'http://x/a' \\\n  -H 'X-Q: it'\\''s' \\\n  -H 'Content-Type: application/json' \\\n  --data-raw '{\"a\":1}'")
    }

    /// Only the whitespace changes: keys stay in the server's order, and
    /// what is inside strings — braces, escapes, unicode — stays as sent.
    func testJSONIsIndentedWithoutBeingReEncoded() {
        let sent = #"{"z":1,"a":{"b":[1,2,{}],"c":[]},"s":"a{b}[c],d:\"e\" \u00e9","t":true}"#
        XCTAssertEqual(
            APIResponse.indentJSON(sent),
            """
            {
              "z": 1,
              "a": {
                "b": [
                  1,
                  2,
                  {}
                ],
                "c": []
              },
              "s": "a{b}[c],d:\\"e\\" \\u00e9",
              "t": true
            }
            """)
        XCTAssertEqual(APIResponse.indentJSON("[]"), "[]")
        XCTAssertEqual(APIResponse.indentJSON(" 42 "), "42")
    }

    /// A body is formatted once, when it is set — and a huge one is cut
    /// for the pane, the whole kept for Copy.
    func testABodyIsFormattedWhenSetAndAHugeOneCutForThePane() {
        var response = APIResponse(status: 200, headers: [], body: Data(#"{"a":1}"#.utf8), duration: 1)
        XCTAssertTrue(response.isJSON)
        XCTAssertEqual(response.display, "{\n  \"a\": 1\n}")
        response.body = Data("plain".utf8)
        XCTAssertFalse(response.isJSON)
        XCTAssertEqual(response.display, "plain")
        let huge = Data(repeating: UInt8(ascii: "x"), count: APIResponse.displayLimit + 10)
        let big = APIResponse(status: 200, headers: [], body: huge, duration: 1)
        XCTAssertLessThan(big.display.utf8.count, APIResponse.displayLimit + 200)
        XCTAssertTrue(big.display.hasSuffix("Copy takes the whole body."))
        XCTAssertEqual(big.prettyText.utf8.count, huge.count)
    }

    /// A param's value holding & or # stays one param, both ways round.
    func testQueryDelimitersInAParamStayInIt() {
        let url = APIRequestModel.url("{{base}}/s#top", withQuery: [BruPair(key: "q", value: "a&b#c"), BruPair(key: "k=1", value: "")])
        XCTAssertEqual(url, "{{base}}/s?q=a%26b%23c&k%3D1=#top")
        XCTAssertEqual(APIRequestModel.queryPairs(of: url), [BruPair(key: "q", value: "a&b#c"), BruPair(key: "k=1", value: "")])
        XCTAssertEqual(APIRequestModel.queryPairs(of: "http://x/?a=1&b=%2F"), [BruPair(key: "a", value: "1"), BruPair(key: "b", value: "%2F")])
    }

    // MARK: Sending

    private var server: E2EEchoServer!

    override func setUpWithError() throws {
        server = E2EEchoServer()
        try server.start()
    }

    override func tearDown() {
        server.stop()
    }

    private func echo(_ response: APIResponse) throws -> [String: Any] {
        try XCTUnwrap(response.json as? [String: Any])
    }

    func testARequestReachesTheServerAsPlanned() async throws {
        var context = APIRequestPlan.Context()
        context.variables.environment = ["base": server.baseURL]
        let made = try plan(
            "put {\n  url: {{base}}/things?x=1\n  body: json\n}\n\nheaders {\n  X-Test: yes\n}\n\nbody:json {\n  {\"ok\": true}\n}\n", context: context)
        let response = try await APIClient().send(made)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.header("x-echo"), "1")
        let echoed = try echo(response)
        XCTAssertEqual(echoed["method"] as? String, "PUT")
        XCTAssertEqual(echoed["path"] as? String, "/things")
        XCTAssertEqual((echoed["query"] as? [String: String])?["x"], "1")
        XCTAssertEqual((echoed["headers"] as? [String: String])?["x-test"], "yes")
        XCTAssertEqual(echoed["body"] as? String, "{\"ok\": true}")
        XCTAssertGreaterThan(response.duration, 0)
        XCTAssertNotNil(response.timeline)
        XCTAssertTrue(response.prettyText.contains("\n  \"method\": \"PUT\""), response.prettyText)
        XCTAssertEqual(response.statusText, "OK")
    }

    func testAnErrorStatusIsAResponseNotAFailure() async throws {
        let response = try await APIClient().send(try plan("get {\n  url: \(server.baseURL)/status/404\n}\n"))
        XCTAssertEqual(response.status, 404)
        XCTAssertEqual(response.statusText, "Not Found")
    }

    func testRedirectsAreFollowedUnlessTheOptionsSayNot() async throws {
        let made = try plan("get {\n  url: \(server.baseURL)/redirect\n}\n")
        let followed = try await APIClient().send(made)
        XCTAssertEqual(followed.status, 200)
        XCTAssertEqual(followed.url?.path, "/echo")
        let stopped = try await APIClient().send(made, options: .init(followRedirects: false))
        XCTAssertEqual(stopped.status, 302)
        XCTAssertEqual(stopped.header("Location"), "/echo")
    }

    /// A collection's client keeps its cookies; another client has none.
    func testCookiesStayWithTheirClient() async throws {
        let client = APIClient()
        _ = try await client.send(try plan("get {\n  url: \(server.baseURL)/cookie/set?session=s1\n}\n"))
        let back = try await client.send(try plan("get {\n  url: \(server.baseURL)/cookie/get\n}\n"))
        XCTAssertEqual(back.text, "session=s1")
        XCTAssertEqual(client.cookies.map(\.name), ["session"])
        let other = try await APIClient().send(try plan("get {\n  url: \(server.baseURL)/cookie/get\n}\n"))
        XCTAssertEqual(other.text, "")
        client.clearCookies()
        XCTAssertEqual(client.cookies, [])
    }

    func testANetworkErrorIsThrown() async throws {
        let closed = E2EEchoServer()
        try closed.start()
        let port = closed.port
        closed.stop()
        do {
            _ = try await APIClient().send(try plan("get {\n  url: http://127.0.0.1:\(port)/\n}\n"), options: .init(timeout: 3))
            XCTFail("a closed port answered")
        } catch {
            XCTAssertTrue(error is URLError)
        }
    }
}
