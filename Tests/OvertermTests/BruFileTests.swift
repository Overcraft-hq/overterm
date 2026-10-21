import XCTest

@testable import Overterm

/// Bruno's file format, read and written — the promise being that the
/// same file opens in Bruno, in `bru run` and here, and that an edit made
/// here changes only what it changed.
final class BruFileTests: XCTestCase {
    /// A request as Bruno writes one, every kind of block in it.
    static let request = """
        meta {
          name: Create user
          type: http
          seq: 3
        }

        post {
          url: {{baseUrl}}/users?verbose=true
          body: json
          auth: bearer
        }

        params:query {
          verbose: true
          ~page: 2
        }

        headers {
          x-request-id: {{$guid}}
          ~x-debug: 1
        }

        auth:bearer {
          token: {{token}}
        }

        body:json {
          {
            "name": "Ada",
            "tags": ["a", "b"]
          }
        }

        vars:post-response {
          userId: res.body.id
        }

        assert {
          res.status: eq 201
          res.body.name: eq Ada
        }

        script:pre-request {
          bru.setVar("started", Date.now());
        }

        tests {
          test("created", function() {
            expect(res.getStatus()).to.equal(201);
          });
        }

        docs {
          Creates a user.

          Needs a token.
        }

        """

    func testAFileReadAndWrittenBackIsTheSameBytes() {
        XCTAssertEqual(BruFile(parsing: Self.request).text, Self.request)
    }

    /// Odd spacing, a comment-ish line between blocks, no final newline:
    /// none of it is Bruno's layout, all of it survives.
    func testWhatIsNotBrunosLayoutSurvivesTooUntilItsBlockChanges() {
        let odd = "meta {\n    name:   Odd  \n  seq: 1\n}\n\n\n# kept\nget {\n  url: http://x\n}"
        XCTAssertEqual(BruFile(parsing: odd).text, odd)
        var file = BruFile(parsing: odd)
        file.url = "http://y"
        XCTAssertEqual(file.text, "meta {\n    name:   Odd  \n  seq: 1\n}\n\n\n# kept\nget {\n  url: http://y\n}\n")
        XCTAssertEqual(file.name, "Odd")
    }

    /// Written on Windows: read the same, the bytes kept, and a block
    /// rewritten with the file's own line ending.
    func testACRLFFileIsARequestAndKeepsItsLineEndings() {
        let crlf = Self.request.replacingOccurrences(of: "\n", with: "\r\n")
        let file = BruFile(parsing: crlf)
        XCTAssertEqual(file.text, crlf)
        XCTAssertTrue(file.isRequest)
        XCTAssertEqual(file.url, "{{baseUrl}}/users?verbose=true")
        XCTAssertEqual(file.body(.json), BruFile(parsing: Self.request).body(.json))
        var changed = file
        changed.url = "http://x"
        XCTAssertFalse(changed.text.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "no bare LF in a CRLF file")
        XCTAssertTrue(changed.text.contains("  url: http://x\r\n"))
        changed.docs = nil
        changed.headers = [BruPair(key: "a", value: "1")]
        XCTAssertFalse(changed.text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    func testTheRequestReadsAsBrunoMeansIt() {
        let file = BruFile(parsing: Self.request)
        XCTAssertTrue(file.isRequest)
        XCTAssertEqual(file.name, "Create user")
        XCTAssertEqual(file.seq, 3)
        XCTAssertEqual(file.method, "POST")
        XCTAssertEqual(file.url, "{{baseUrl}}/users?verbose=true")
        XCTAssertEqual(file.bodyMode, .json)
        XCTAssertEqual(file.authMode, .bearer)
        XCTAssertEqual(file.queryParams, [BruPair(key: "verbose", value: "true"), BruPair(key: "page", value: "2", enabled: false)])
        XCTAssertEqual(file.headers.map(\.enabled), [true, false])
        XCTAssertEqual(file.auth(.bearer), [BruPair(key: "token", value: "{{token}}")])
        XCTAssertEqual(file.body(.json), "{\n  \"name\": \"Ada\",\n  \"tags\": [\"a\", \"b\"]\n}")
        XCTAssertEqual(file.postResponseVars, [BruPair(key: "userId", value: "res.body.id")])
        XCTAssertEqual(file.assertions.map(\.value), ["eq 201", "eq Ada"])
        XCTAssertEqual(file.preRequestScript, "bru.setVar(\"started\", Date.now());")
        XCTAssertEqual(file.tests?.components(separatedBy: "\n").count, 3)
        XCTAssertEqual(file.docs, "Creates a user.\n\nNeeds a token.")
    }

    /// One header changed: that block is rewritten, every other byte stays.
    func testAnEditRewritesOnlyItsBlock() {
        var file = BruFile(parsing: Self.request)
        var headers = file.headers
        headers[1].enabled = true
        file.headers = headers
        XCTAssertEqual(file.text, Self.request.replacingOccurrences(of: "  ~x-debug: 1", with: "  x-debug: 1"))
    }

    func testTheMethodRenamesItsBlockAndKeepsItsLines() {
        var file = BruFile(parsing: Self.request)
        file.method = "PUT"
        XCTAssertEqual(file.method, "PUT")
        XCTAssertEqual(file.url, "{{baseUrl}}/users?verbose=true")
        XCTAssertTrue(file.text.contains("put {\n  url: {{baseUrl}}/users?verbose=true\n  body: json\n  auth: bearer\n}\n"))
        XCTAssertFalse(file.text.contains("post {"))
    }

    /// A block the file didn't have goes where Bruno's writer puts it.
    func testANewBlockGoesWhereBrunoPutsIt() {
        var file = BruFile(parsing: "meta {\n  name: A\n}\n\nget {\n  url: http://x\n}\n\ntests {\n  test()\n}\n")
        file.headers = [BruPair(key: "accept", value: "application/json")]
        XCTAssertEqual(
            file.text, "meta {\n  name: A\n}\n\nget {\n  url: http://x\n}\n\nheaders {\n  accept: application/json\n}\n\ntests {\n  test()\n}\n")
        file.docs = "Hello"
        XCTAssertTrue(file.text.hasSuffix("tests {\n  test()\n}\n\ndocs {\n  Hello\n}\n"))
    }

    func testRemovingABlockTakesItsBlankLineWithIt() {
        var file = BruFile(parsing: Self.request)
        file.docs = nil
        file.tests = nil
        XCTAssertTrue(file.text.hasSuffix("\n\nscript:pre-request {\n  bru.setVar(\"started\", Date.now());\n}\n"))
        var first = BruFile(parsing: "meta {\n  name: A\n}\n\nget {\n  url: u\n}\n")
        first.remove("meta")
        XCTAssertEqual(first.text, "get {\n  url: u\n}\n")
    }

    /// Bruno's writer indents every line of a text block, the empty ones too.
    func testATextBlockIsWrittenAsBrunoWritesIt() {
        var file = BruFile(parsing: "get {\n  url: u\n}\n")
        file.setBody(.json, "{\n\n  \"a\": 1\n}")
        XCTAssertTrue(file.text.hasSuffix("body:json {\n  {\n  \n    \"a\": 1\n  }\n}\n"))
        XCTAssertEqual(BruFile(parsing: file.text).body(.json), "{\n\n  \"a\": 1\n}")
    }

    /// `}` inside a body is indented, so it never ends the block.
    func testABraceInsideATextBlockDoesNotEndIt() {
        let file = BruFile(parsing: "script:post-response {\n  if (x) {\n  }\n}\n\ntests {\n  t()\n}\n")
        XCTAssertEqual(file.postResponseScript, "if (x) {\n}")
        XCTAssertEqual(file.tests, "t()")
    }

    func testValuesKeepTheirColonsAndQuotedKeysTheirs() throws {
        let file = BruFile(parsing: "headers {\n  authorization: Basic a:b\n  \"x:y\": 1\n  empty: \n}\n")
        XCTAssertEqual(file.value("authorization", in: "headers"), "Basic a:b")
        XCTAssertEqual(file.value("x:y", in: "headers"), "1")
        XCTAssertEqual(file.value("empty", in: "headers"), "")
        var written = BruFile()
        written.headers = [BruPair(key: "x:y", value: "1")]
        XCTAssertEqual(written.text, "headers {\n  \"x:y\": 1\n}\n")
    }

    /// `key: '''` … `'''`: a value over several lines.
    func testAMultilineValueRoundTrips() {
        let text = "vars {\n  cert: '''\n    line one\n    line two\n  '''\n  next: 2\n}\n"
        let file = BruFile(parsing: text)
        XCTAssertEqual(file.variables, [BruPair(key: "cert", value: "line one\nline two"), BruPair(key: "next", value: "2")])
        var rewritten = BruFile()
        rewritten.variables = file.variables
        XCTAssertEqual(rewritten.text, text)
    }

    func testAnEnvironmentsVariablesAndSecretNames() {
        let text = "vars {\n  baseUrl: http://localhost:3000\n  ~old: x\n}\nvars:secret [\n  token,\n  apiKey\n]\n"
        let file = BruFile(parsing: text)
        XCTAssertEqual(file.text, text)
        XCTAssertEqual(file.variables.first?.value, "http://localhost:3000")
        XCTAssertEqual(file.secretNames, ["token", "apiKey"])
        var changed = file
        changed.secretNames = ["token"]
        XCTAssertTrue(changed.text.hasSuffix("vars:secret [\n  token\n]\n"))
    }

    func testFormBodiesAreDictionariesAndTheirModesBrunosCamelCase() {
        let file = BruFile(parsing: "post {\n  url: u\n  body: formUrlEncoded\n}\n\nbody:form-urlencoded {\n  a: 1\n  ~b: 2\n}\n")
        XCTAssertEqual(file.bodyMode, .formUrlEncoded)
        XCTAssertEqual(file.formFields.count, 2)
        var changed = file
        changed.bodyMode = .multipartForm
        XCTAssertTrue(changed.text.contains("body: multipartForm"))
    }

    func testANewRequestIsLaidOutAsBrunoMakesOne() {
        XCTAssertEqual(
            BruFile.newRequest(name: "List", url: "{{baseUrl}}/items", seq: 2).text,
            """
            meta {
              name: List
              type: http
              seq: 2
            }

            get {
              url: {{baseUrl}}/items
              body: none
              auth: inherit
            }

            settings {
              encodeUrl: true
            }

            """)
    }

    func testFolderAndCollectionFilesAreNotRequests() {
        let folder = BruFile(parsing: "meta {\n  name: Users\n  seq: 1\n}\n\nauth {\n  mode: bearer\n}\n\nauth:bearer {\n  token: t\n}\n")
        XCTAssertFalse(folder.isRequest)
        XCTAssertEqual(folder.defaultAuthMode, .bearer)
        XCTAssertEqual(folder.auth(.bearer).first?.value, "t")
    }
}
