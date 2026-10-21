import XCTest

@testable import Overterm

/// Bruno's scripts and tests in JavaScriptCore: what `bru`, `req`, `res`,
/// `test` and `expect` do, the assert block, and a whole request run
/// against a server on this machine.
final class APIScriptTests: XCTestCase {
    private let runtime = APIScriptRuntime()

    private func response(_ json: String, status: Int = 200) -> APIResponse {
        APIResponse(
            status: status, headers: [.init(name: "Content-Type", value: "application/json"), .init(name: "X-Id", value: "42")],
            body: Data(json.utf8), duration: 12, url: URL(string: "http://x/y"))
    }

    private func tests(_ script: String, _ json: String = #"{"id": 7, "name": "Ada", "tags": ["a", "b"], "nested": {"ok": true}}"#)
        async -> APIScriptOutcome
    {
        var input = APIScriptInput()
        input.response = response(json)
        return await runtime.run(.tests(script), input: input)
    }

    // MARK: test and expect

    func testPassingAndFailingTestsAreReportedWithTheirMessages() async {
        let outcome = await tests(
            """
            test("status", function() { expect(res.getStatus()).to.equal(200); });
            test("name", function() { expect(res.body.name).to.equal("Grace"); });
            test("throws", function() { throw new Error("boom"); });
            """)
        XCTAssertEqual(outcome.tests.map(\.name), ["status", "name", "throws"])
        XCTAssertEqual(outcome.tests.map(\.passed), [true, false, false])
        XCTAssertEqual(outcome.tests[1].error, #"expected "Ada" to equal "Grace""#)
        XCTAssertEqual(outcome.tests[2].error, "boom")
        XCTAssertNil(outcome.failure)
    }

    /// The chains Bruno collections use, each one expected to pass.
    func testTheExpectChainsCollectionsUse() async {
        let lines = [
            "expect(res.status).to.equal(200)", "expect(res.body).to.be.an('object')", "expect(res.body.tags).to.be.an('array')",
            "expect(res.body).to.have.property('id', 7)", "expect(res.body).to.have.property('nested').that.has.property('ok')",
            "expect(res.body).to.have.deep.property('nested.ok', true)", "expect(res.body.tags).to.include('b')",
            "expect(res.body.tags).to.have.lengthOf(2)", "expect(res.body.tags).to.have.length(2)", "expect(res.body.id).to.be.above(5)",
            "expect(res.body.id).to.be.below(10)", "expect(res.body.id).to.be.within(1, 10)", "expect(res.body.name).to.match(/^A/)",
            "expect(res.body.missing).to.be.undefined", "expect(res.body.nested.ok).to.be.true", "expect(null).to.be.null",
            "expect(res.body.tags).to.eql(['a', 'b'])", "expect(res.body.tags).to.deep.equal(['a', 'b'])", "expect(res.body.id).to.not.equal(8)",
            "expect(res.body.name).to.be.oneOf(['Ada', 'Grace'])", "expect(res.body).to.have.keys('id', 'name')", "expect([]).to.be.empty",
            "expect(res.body).to.include({name: 'Ada'})", "expect(res.getHeader('x-id')).to.equal('42')", "expect(res('nested.ok')).to.be.ok",
            "expect(res('tags[1]')).to.equal('b')", "expect(res.getResponseTime()).to.equal(12)", "expect('x').to.exist",
            "assert.equal(res.body.id, 7)", "expect(res).to.have.status(200)",
        ]
        let script = lines.enumerated().map { "test(\"\($0.offset)\", function() { \($0.element); });" }.joined(separator: "\n")
        let outcome = await tests(script)
        XCTAssertEqual(outcome.tests.count, lines.count)
        for (line, result) in zip(lines, outcome.tests) {
            XCTAssertTrue(result.passed, "\(line): \(result.error ?? "")")
        }
    }

    func testAnAsyncTestIsAwaited() async {
        let outcome = await tests(
            """
            test("later", async function() { await bru.sleep(10); expect(1).to.equal(1); });
            test("rejects", async function() { await Promise.resolve(); expect(1).to.equal(2); });
            """)
        XCTAssertEqual(outcome.tests.map(\.passed), [true, false])
    }

    // MARK: bru and req

    func testAPreRequestScriptSetsVariablesAndChangesTheRequest() async {
        var input = APIScriptInput()
        input.request = APIScriptRequest(url: "{{base}}/a", method: "GET", headers: ["X-Old": "1"], body: nil)
        input.variables = ["base": "http://x"]
        let outcome = await runtime.run(
            .preRequest(
                """
                bru.setVar("token", "t-" + bru.getVar("base").length);
                req.setHeader("Authorization", "Bearer " + bru.getVar("token"));
                req.deleteHeader("x-old");
                req.setUrl(req.getUrl() + "?debug=1");
                req.setMethod("post");
                req.setBody({ hello: "world" });
                console.log("set", { n: 1 });
                """),
            input: input)
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(outcome.runtime, ["token": "t-8"])
        XCTAssertEqual(outcome.request?.headers, ["Authorization": "Bearer t-8"])
        XCTAssertEqual(outcome.request?.url, "{{base}}/a?debug=1")
        XCTAssertEqual(outcome.request?.method, "POST")
        XCTAssertEqual(outcome.request?.body?.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: ""), #"{"hello":"world"}"#)
        XCTAssertEqual(outcome.logs, [APILogLine(level: .log, text: #"set {"n":1}"#)])
    }

    /// A scalar body — a number, a boolean — is a body, not a crash: the
    /// app died writing it back.
    func testAScalarBodyFromAScriptDoesntCrash() async {
        for body in ["42", "true", "null", "\"text\"", "[1, 2]"] {
            let outcome = await runtime.run(.preRequest("req.setBody(\(body));"), input: APIScriptInput())
            XCTAssertNil(outcome.failure, body)
            if body != "null" { XCTAssertNotNil(outcome.request?.body, body) }
        }
        var input = APIScriptInput()
        input.response = response("{}")
        let after = await runtime.run(.postResponse("res.setBody(7); bru.setVar(\"n\", NaN);"), input: input)
        XCTAssertNil(after.failure)
        XCTAssertEqual(after.responseBody, "7")
    }

    /// Deleted then set: the setting came last, so it stands.
    func testAVariableSetAfterItsDeletionStands() async {
        let outcome = await runtime.run(.postResponse("bru.deleteVar('t'); bru.setVar('t', 'new');"), input: APIScriptInput())
        XCTAssertEqual(outcome.runtime, ["t": "new"])
        XCTAssertEqual(outcome.deleted, [])
    }

    /// req.setBody(null) sends no body, not the one it replaced.
    func testABodySetToNullSendsNone() async throws {
        let server = E2EEchoServer()
        try server.start()
        defer { server.stop() }
        let file = BruFile(
            parsing: "post {\n  url: \(server.baseURL)/a\n  body: json\n}\n\nbody:json {\n  {\"secret\": 1}\n}\n\nscript:pre-request {\n  req.setBody(null);\n}\n")
        let result = await APIExecution.run(APIExecution.Setup(file: file), client: APIClient(), scripts: runtime)
        XCTAssertEqual((result.response?.json as? [String: Any])?["body"] as? String, "")
    }

    func testRequireSaysWhatToDoAndAThrowIsAFailure() async {
        let outcome = await runtime.run(.preRequest("const axios = require('axios');"), input: APIScriptInput())
        XCTAssertEqual(outcome.failure?.contains("run this collection with bru"), true)
    }

    func testALoopThatNeverEndsIsStopped() async {
        let quick = APIScriptRuntime()
        quick.timeLimit = 0.5
        let started = Date()
        let outcome = await quick.run(.preRequest("while (true) {}"), input: APIScriptInput())
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertNotNil(outcome.failure)
    }

    func testTheRunnerInstructions() async {
        let next = await runtime.run(.postResponse("bru.setNextRequest('Login');"), input: APIScriptInput())
        XCTAssertEqual(next.nextRequest, "Login")
        let stop = await runtime.run(.postResponse("bru.setNextRequest(null);"), input: APIScriptInput())
        XCTAssertTrue(stop.stop)
        let skip = await runtime.run(.preRequest("bru.runner.skipRequest();"), input: APIScriptInput())
        XCTAssertTrue(skip.skip)
    }

    // MARK: assert and vars:post-response

    func testTheAssertBlocksOperators() async {
        var input = APIScriptInput()
        input.response = response(#"{"id": 7, "name": "Ada", "tags": ["a"], "none": null, "empty": ""}"#)
        let rules: [(String, String, Bool)] = [
            ("res.status", "eq 200", true), ("res.status", "200", true), ("res.status", "neq 200", false), ("res.body.id", "gt 5", true),
            ("res.body.id", "lte 6", false), ("res.body.name", "eq Ada", true), ("res.body.name", "eq \"Ada\"", true),
            ("res.body.name", "startsWith A", true), ("res.body.name", "matches ^A.a$", true), ("res.body.tags", "contains a", true),
            ("res.body.tags", "length 1", true), ("res.body.none", "isNull", true), ("res.body.empty", "isEmpty", true),
            ("res.body.id", "isNumber", true), ("res.body", "isJson", true), ("res.body.missing", "isUndefined", true),
            ("res.body.id", "between 1, 10", true), ("res.body.id", "in 1, 7, 9", true), ("res.headers.x-id", "eq 42", true),
            ("res.responseTime", "lt 1000", true),
        ]
        let outcome = await runtime.run(.assertions(rules.map { BruPair(key: $0.0, value: $0.1) }), input: input)
        XCTAssertEqual(outcome.tests.count, rules.count)
        for (rule, result) in zip(rules, outcome.tests) {
            XCTAssertEqual(result.passed, rule.2, "\(rule.0): \(rule.1) — \(result.error ?? "")")
            XCTAssertTrue(result.isAssertion)
        }
    }

    func testPostResponseVarsCaptureFromTheResponse() async {
        var input = APIScriptInput()
        input.response = response(#"{"token": "abc", "user": {"id": 3}}"#)
        let outcome = await runtime.run(
            .capture([BruPair(key: "token", value: "res.body.token"), BruPair(key: "userId", value: "res('user.id')")]), input: input)
        XCTAssertEqual(outcome.runtime, ["token": "abc", "userId": "3"])
    }

    // MARK: A whole run

    func testARunSendsWhatThePreRequestScriptMadeAndRunsEverythingAfter() async throws {
        let server = E2EEchoServer()
        try server.start()
        defer { server.stop() }
        let file = BruFile(
            parsing: """
                meta {
                  name: Echo
                  seq: 1
                }

                post {
                  url: {{base}}/echo
                  body: json
                  auth: none
                }

                body:json {
                  {"who": "{{who}}"}
                }

                vars:post-response {
                  method: res.body.method
                }

                assert {
                  res.status: eq 200
                }

                script:pre-request {
                  bru.setVar("who", "request");
                  req.setHeader("X-Step", "request");
                }

                script:post-response {
                  console.log("request post");
                }

                tests {
                  test("echoed", function() {
                    expect(JSON.parse(res.body.body).who).to.equal("request");
                    expect(res.body.headers["x-step"]).to.equal("request");
                    expect(res.body.headers["x-folder"]).to.equal("yes");
                  });
                }

                """)
        var setup = APIExecution.Setup(file: file)
        setup.environment = ["base": server.baseURL]
        setup.collectionFile = BruFile(parsing: "script:post-response {\n  console.log(\"collection post\");\n}\n")
        setup.folderFiles = [
            BruFile(
                parsing: "headers {\n  X-Folder: yes\n}\n\nscript:pre-request {\n  bru.setVar(\"who\", \"folder\");\n}\n\nscript:post-response {\n  console.log(\"folder post\");\n}\n")
        ]
        let result = await APIExecution.run(setup, client: APIClient(), scripts: runtime)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.response?.status, 200)
        XCTAssertEqual(result.runtime["method"], "POST")
        XCTAssertEqual(result.runtime["who"], "request", "the request's script runs after its folder's")
        XCTAssertEqual(result.logs.map(\.text), ["request post", "folder post", "collection post"], "sandwich: inside out after the response")
        XCTAssertEqual(result.tests.map(\.passed), [true, true], "\(result.tests)")
        XCTAssertTrue(result.succeeded)
    }

    /// One test passed, then the script threw: the rest never ran, so
    /// the request didn't pass — and a post-response script that throws
    /// fails it too.
    func testAScriptThatThrowsAfterTheResponseFailsTheRequest() async throws {
        let server = E2EEchoServer()
        try server.start()
        defer { server.stop() }
        let tests = BruFile(
            parsing: "get {\n  url: \(server.baseURL)/a\n}\n\ntests {\n  test(\"first\", function() {});\n  nope();\n  test(\"never\", function() {});\n}\n")
        let result = await APIExecution.run(APIExecution.Setup(file: tests), client: APIClient(), scripts: runtime)
        XCTAssertEqual(result.tests.map(\.name), ["first", "Tests"])
        XCTAssertEqual(result.tests.map(\.passed), [true, false])
        XCTAssertFalse(result.succeeded)
        let post = BruFile(parsing: "get {\n  url: \(server.baseURL)/a\n}\n\nscript:post-response {\n  nope();\n}\n")
        let posted = await APIExecution.run(APIExecution.Setup(file: post), client: APIClient(), scripts: runtime)
        XCTAssertEqual(posted.response?.status, 200)
        XCTAssertFalse(posted.succeeded)
    }

    /// A pre-request script's changes all reach what is sent: an inherited
    /// header deleted, headers and body changed in place, a form's fields.
    func testWhatAPreRequestScriptChangesIsWhatIsSent() async throws {
        let server = E2EEchoServer()
        try server.start()
        defer { server.stop() }
        var setup = APIExecution.Setup(
            file: BruFile(
                parsing: """
                    post {
                      url: \(server.baseURL)/a
                      body: json
                    }

                    body:json {
                      {"a": 1}
                    }

                    script:pre-request {
                      req.deleteHeader("X-Secret");
                      req.headers["X-Direct"] = "yes";
                      req.body.b = 2;
                    }

                    """))
        setup.collectionFile = BruFile(parsing: "headers {\n  X-Secret: s\n  X-Kept: k\n}\n")
        let result = await APIExecution.run(setup, client: APIClient(), scripts: runtime)
        let echoed = try XCTUnwrap(result.response?.json as? [String: Any])
        let headers = try XCTUnwrap(echoed["headers"] as? [String: String])
        XCTAssertNil(headers["x-secret"], "an inherited header deleted stays deleted")
        XCTAssertEqual(headers["x-kept"], "k")
        XCTAssertEqual(headers["x-direct"], "yes", "set in place")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data((echoed["body"] as? String ?? "").utf8)) as? [String: Int])
        XCTAssertEqual(body, ["a": 1, "b": 2], "changed in place")

        let form = BruFile(
            parsing: "post {\n  url: \(server.baseURL)/f\n  body: formUrlEncoded\n}\n\nbody:form-urlencoded {\n  old: 1\n}\n\nscript:pre-request {\n  req.setBody({ fresh: \"v\" });\n}\n")
        let sent = await APIExecution.run(APIExecution.Setup(file: form), client: APIClient(), scripts: runtime)
        XCTAssertEqual((sent.response?.json as? [String: Any])?["body"] as? String, "fresh=v", "a form's fields, not an empty body")
    }

    /// A form's fields reach a script as an object it can read and extend.
    func testAFormsFieldsAreAnObjectToAScript() async throws {
        let server = E2EEchoServer()
        try server.start()
        defer { server.stop() }
        let form = BruFile(
            parsing:
                "post {\n  url: \(server.baseURL)/f\n  body: formUrlEncoded\n}\n\nbody:form-urlencoded {\n  user: ada\n  ~off: 1\n}\n\nscript:pre-request {\n  var body = req.getBody();\n  body.seen = body.user;\n  req.setBody(body);\n}\n"
        )
        let sent = await APIExecution.run(APIExecution.Setup(file: form), client: APIClient(), scripts: runtime)
        XCTAssertEqual((sent.response?.json as? [String: Any])?["body"] as? String, "seen=ada&user=ada")
        let untouched = BruFile(
            parsing: "post {\n  url: \(server.baseURL)/f\n  body: formUrlEncoded\n}\n\nbody:form-urlencoded {\n  z: 1\n  a: 2\n}\n\nscript:pre-request {\n  bru.setVar(\"x\", req.getBody().z);\n}\n")
        let kept = await APIExecution.run(APIExecution.Setup(file: untouched), client: APIClient(), scripts: runtime)
        XCTAssertEqual((kept.response?.json as? [String: Any])?["body"] as? String, "z=1&a=2", "read, not rewritten: the fields' order kept")
        XCTAssertEqual(kept.runtime["x"], "1")
    }

    /// Untouched, a JSON body isn't rewritten from the script's copy.
    func testAnUntouchedBodyIsSentAsWritten() async throws {
        let server = E2EEchoServer()
        try server.start()
        defer { server.stop() }
        let file = BruFile(
            parsing: "post {\n  url: \(server.baseURL)/a\n  body: json\n}\n\nbody:json {\n  {\"z\":1,\"a\":2}\n}\n\nscript:pre-request {\n  bru.setVar(\"x\", 1);\n}\n")
        let result = await APIExecution.run(APIExecution.Setup(file: file), client: APIClient(), scripts: runtime)
        XCTAssertEqual((result.response?.json as? [String: Any])?["body"] as? String, #"{"z":1,"a":2}"#)
    }

    func testAScriptThatThrowsBeforeTheRequestStopsIt() async {
        var setup = APIExecution.Setup(file: BruFile(parsing: "get {\n  url: http://127.0.0.1:1/\n}\n\nscript:pre-request {\n  nope();\n}\n"))
        setup.options.timeout = 2
        let result = await APIExecution.run(setup, client: APIClient(), scripts: runtime)
        XCTAssertNil(result.plan)
        XCTAssertNotNil(result.error)
        XCTAssertFalse(result.succeeded)
    }
}
