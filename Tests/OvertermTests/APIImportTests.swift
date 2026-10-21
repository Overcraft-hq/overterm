import XCTest

@testable import Overterm

/// OpenAPI, Postman, .http and cURL made into Bruno's files — checked as
/// written to disk and read back as a collection, the way Bruno would.
final class APIImportTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: OpenAPI

    static let petstore = """
        openapi: 3.0.3
        info:
          title: Pet Store
          version: "1"
        servers:
          - url: https://{env}.example.com/v1
            variables:
              env: {default: api}
        security:
          - bearerAuth: []
        tags:
          - name: pets
          - name: store
        paths:
          /pets:
            get:
              summary: List pets
              tags: [pets]
              parameters:
                - $ref: '#/components/parameters/Limit'
                - name: status
                  in: query
                  required: true
                  schema: {type: string, enum: [available, sold]}
            post:
              summary: Add a pet
              tags: [pets]
              requestBody:
                content:
                  application/json:
                    schema: {$ref: '#/components/schemas/Pet'}
          /pets/{petId}:
            parameters:
              - name: petId
                in: path
                required: true
                schema: {type: integer, example: 7}
            delete:
              operationId: deletePet
              tags: [pets]
              security: []
          /store/upload:
            post:
              summary: Upload
              tags: [store]
              requestBody:
                content:
                  multipart/form-data:
                    schema:
                      type: object
                      properties:
                        file: {type: string, format: binary}
                        note: {type: string, example: hi}
          /health:
            get:
              summary: Health
        components:
          parameters:
            Limit:
              name: limit
              in: query
              schema: {type: integer, default: 20}
          securitySchemes:
            bearerAuth: {type: http, scheme: bearer}
          schemas:
            Pet:
              allOf:
                - $ref: '#/components/schemas/Base'
                - type: object
                  properties:
                    name: {type: string, example: Rex}
                    tags: {type: array, items: {type: string}}
                    born: {type: string, format: date}
            Base:
              type: object
              properties:
                id: {type: integer, readOnly: true}
                kind: {type: string, enum: [dog, cat]}
        """

    func testAnOpenAPIDocumentInYAMLBecomesACollection() throws {
        let document = try XCTUnwrap(APIImport.parseDocument(Data(Self.petstore.utf8)))
        let imported = try OpenAPIImporter.make(document)
        XCTAssertEqual(imported.name, "Pet Store")
        XCTAssertEqual(imported.root.folders.map(\.name), ["pets", "store"])
        XCTAssertEqual(imported.root.requests.map(\.file.name), ["Health"])
        let local = try XCTUnwrap(imported.environments.first)
        XCTAssertEqual(local.file.value("baseUrl", in: "vars"), "https://api.example.com/v1", "the server's variable filled in")
        XCTAssertEqual(local.file.secretNames, ["token"])
        XCTAssertEqual(imported.collectionFile?.defaultAuthMode, .bearer)
        XCTAssertEqual(imported.collectionFile?.auth(.bearer).first?.value, "{{token}}")

        let pets = imported.root.folders[0].requests.map(\.file)
        let list = try XCTUnwrap(pets.first { $0.name == "List pets" })
        XCTAssertEqual(list.url, "{{baseUrl}}/pets?status=available", "the required param on, in the URL")
        XCTAssertEqual(list.queryParams, [BruPair(key: "limit", value: "20", enabled: false), BruPair(key: "status", value: "available")])
        XCTAssertEqual(list.authMode, .inherit)

        let add = try XCTUnwrap(pets.first { $0.name == "Add a pet" })
        XCTAssertEqual(add.bodyMode, .json)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(XCTUnwrap(add.body(.json)).utf8)) as? [String: Any])
        XCTAssertEqual(body["name"] as? String, "Rex")
        XCTAssertEqual(body["kind"] as? String, "dog", "allOf's base merged in")
        XCTAssertNil(body["id"], "read-only left out")
        XCTAssertEqual(body["born"] as? String, "2024-01-01")
        XCTAssertTrue(add.body(.json)?.contains("\"name\": \"Rex\"") == true, "written as people write JSON")

        let delete = try XCTUnwrap(pets.first { $0.name == "deletePet" })
        XCTAssertEqual(delete.url, "{{baseUrl}}/pets/:petId")
        XCTAssertEqual(delete.pathParams, [BruPair(key: "petId", value: "7")])
        XCTAssertEqual(delete.authMode, .none, "security: [] is none")

        let upload = try XCTUnwrap(imported.root.folders[1].requests.first?.file)
        XCTAssertEqual(upload.bodyMode, .multipartForm)
        XCTAssertEqual(upload.multipartFields, [BruPair(key: "file", value: "@file()"), BruPair(key: "note", value: "hi")])
    }

    func testAnImportWrittenIsACollectionBrunoCanRead() throws {
        let imported = try OpenAPIImporter.make(try XCTUnwrap(APIImport.parseDocument(Data(Self.petstore.utf8))))
        let root = dir.appendingPathComponent("petstore")
        try imported.writeCollection(at: root)
        let collection = try XCTUnwrap(BrunoCollection.load(root))
        XCTAssertEqual(collection.name, "Pet Store")
        XCTAssertEqual(collection.tree.children?.map(\.name), ["pets", "store", "Health"])
        XCTAssertEqual(collection.tree.children?.first?.children?.map(\.name), ["List pets", "Add a pet", "deletePet"], "seq as listed")
        XCTAssertEqual(collection.environments.map(\.name), ["Local"])
        XCTAssertEqual(collection.collectionFile?.defaultAuthMode, .bearer)
        XCTAssertThrowsError(try imported.writeCollection(at: root), "never over a collection")
        // Again, as a folder of that collection: beside what is there.
        let folder = try imported.writeFolder(in: root)
        XCTAssertEqual(folder.lastPathComponent, "Pet Store")
        let again = try XCTUnwrap(BrunoCollection.load(root))
        XCTAssertEqual(again.requests.count, collection.requests.count * 2)
        XCTAssertEqual(BrunoCollection.folderFile(folder)?.defaultAuthMode, .bearer, "the collection's auth moves to the folder")
    }

    /// Into a collection whose Local environment exists: the variables it
    /// lacks are added, what it sets is kept — and the difference named.
    func testAnExistingEnvironmentGainsWhatItLacksAndKeepsWhatItHas() throws {
        let root = dir.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("environments"), withIntermediateDirectories: true)
        try #"{"version":"1","name":"Existing"}"#.write(to: root.appendingPathComponent("bruno.json"), atomically: true, encoding: .utf8)
        try "vars {\n  host: h\n}\n".write(to: root.appendingPathComponent("environments/Local.bru"), atomically: true, encoding: .utf8)
        let imported = try OpenAPIImporter.make(try XCTUnwrap(APIImport.parseDocument(Data(Self.petstore.utf8))))
        XCTAssertEqual(imported.environmentConflicts(in: root), [])
        _ = try imported.writeFolder(in: root)
        let local = BruFile(parsing: try String(contentsOf: root.appendingPathComponent("environments/Local.bru"), encoding: .utf8))
        XCTAssertEqual(local.variables.map(\.key), ["host", "baseUrl"])
        XCTAssertEqual(local.secretNames, ["token"])
        try "vars {\n  baseUrl: http://mine\n}\n".write(to: root.appendingPathComponent("environments/Local.bru"), atomically: true, encoding: .utf8)
        XCTAssertEqual(
            imported.environmentConflicts(in: root),
            ["Local already sets baseUrl to http://mine; the imported API's is https://api.example.com/v1. It was left as it is."])
    }

    /// YAML's .inf and .nan can't be JSON: an example of one is dropped,
    /// not a crash.
    func testAnInfiniteExampleDoesntCrashTheImport() throws {
        let yaml = """
            openapi: 3.0.0
            info: {title: Odd}
            paths:
              /x:
                post:
                  parameters:
                    - {name: q, in: query, schema: {type: number, default: [.nan]}}
                  requestBody:
                    content:
                      application/json:
                        example: {n: .inf}
            """
        let imported = try OpenAPIImporter.make(try XCTUnwrap(APIImport.parseDocument(Data(yaml.utf8))))
        XCTAssertEqual(imported.root.requests.count, 1)
    }

    func testSwagger2WithAHostAndABodyParameter() throws {
        let swagger: [String: Any] = [
            "swagger": "2.0", "info": ["title": "Old"], "host": "old.example.com", "basePath": "/api", "schemes": ["http"],
            "securityDefinitions": ["key": ["type": "apiKey", "name": "X-Key", "in": "header"]], "security": [["key": []]],
            "paths": [
                "/items": [
                    "post": [
                        "summary": "Create",
                        "parameters": [["in": "body", "name": "body", "schema": ["type": "object", "properties": ["n": ["type": "integer"]]]]],
                    ]
                ]
            ],
        ]
        let imported = try OpenAPIImporter.make(swagger)
        XCTAssertEqual(imported.environments.first?.file.value("baseUrl", in: "vars"), "http://old.example.com/api")
        XCTAssertEqual(imported.collectionFile?.defaultAuthMode, .apikey)
        XCTAssertEqual(imported.collectionFile?.value("key", in: "auth:apikey"), "X-Key")
        let create = try XCTUnwrap(imported.root.requests.first?.file)
        XCTAssertEqual(create.body(.json), "{\n  \"n\": 0\n}")
    }

    /// An operation asking for another scheme of the same kind as the
    /// document's — a key in the query, not the header — gets its own auth.
    func testAnOperationsOwnSchemeOfTheSameKindIsKept() throws {
        let document: [String: Any] = [
            "openapi": "3.0.0", "info": ["title": "Keys"], "servers": [["url": "http://x"]],
            "components": [
                "securitySchemes": [
                    "header": ["type": "apiKey", "in": "header", "name": "X-API-Key"],
                    "query": ["type": "apiKey", "in": "query", "name": "key"],
                ]
            ],
            "security": [["header": []]],
            "paths": [
                "/a": ["get": ["summary": "Header"]],
                "/b": ["get": ["summary": "Query", "security": [["query": []]]]],
            ],
        ]
        let imported = try OpenAPIImporter.make(document)
        let byName = Dictionary(uniqueKeysWithValues: imported.root.requests.map { ($0.file.name, $0.file) })
        XCTAssertEqual(byName["Header"]?.authMode, .inherit)
        XCTAssertEqual(byName["Query"]?.authMode, .apikey)
        XCTAssertEqual(byName["Query"]?.value("placement", in: "auth:apikey"), "queryparams")
        XCTAssertEqual(byName["Query"]?.value("key", in: "auth:apikey"), "key")
    }

    /// Found serving on a port, a relative server URL is that server's.
    func testARelativeServerIsTheOneItWasFoundOn() throws {
        let document = try XCTUnwrap(APIImport.parseDocument(Data(E2EEchoServer.openAPI.utf8)))
        let imported = try OpenAPIImporter.make(document, baseURL: "http://localhost:8000")
        XCTAssertEqual(imported.environments.first?.file.value("baseUrl", in: "vars"), "http://localhost:8000")
        XCTAssertTrue(imported.notes.isEmpty)
        // A document naming its production server, found on localhost: Local
        // is localhost, with the server's path.
        var production = document
        production["servers"] = [["url": "https://api.example.com/v2"]]
        XCTAssertEqual(
            try OpenAPIImporter.make(production, baseURL: "http://localhost:8000").environments.first?.file.value("baseUrl", in: "vars"),
            "http://localhost:8000/v2")
        let unknown = try OpenAPIImporter.make(document)
        XCTAssertEqual(unknown.environments.first?.file.value("baseUrl", in: "vars"), "http://localhost:3000")
        XCTAssertFalse(unknown.notes.isEmpty, "and says so")
    }

    // MARK: Postman

    func testAPostmanCollection() throws {
        let json = #"""
            {
              "info": {"name": "Shop", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},
              "auth": {"type": "bearer", "bearer": [{"key": "token", "value": "{{token}}"}]},
              "variable": [{"key": "baseUrl", "value": "http://localhost:3000"}],
              "item": [
                {"name": "Users", "item": [
                  {"name": "Get user",
                   "request": {"method": "GET", "header": [{"key": "Accept", "value": "application/json"}, {"key": "X-Off", "value": "1", "disabled": true}],
                     "url": {"raw": "{{baseUrl}}/users/:id?full=1", "query": [{"key": "full", "value": "1"}], "variable": [{"key": "id", "value": "42"}]}},
                   "event": [{"listen": "test", "script": {"exec": [
                     "pm.test(\"ok\", function () {",
                     "  pm.response.to.have.status(200);",
                     "  pm.environment.set(\"name\", pm.response.json().name);",
                     "});"]}}]}
                ]},
                {"name": "Login", "request": {"method": "POST", "url": "{{baseUrl}}/login",
                  "body": {"mode": "urlencoded", "urlencoded": [{"key": "user", "value": "ada"}]}, "auth": {"type": "noauth"}}}
              ]
            }
            """#
        let document = try XCTUnwrap(APIImport.parseDocument(Data(json.utf8)))
        XCTAssertTrue(PostmanImporter.isPostman(document))
        let imported = try PostmanImporter.make(document)
        XCTAssertEqual(imported.collectionFile?.defaultAuthMode, .bearer)
        XCTAssertEqual(imported.collectionFile?.preRequestVars, [BruPair(key: "baseUrl", value: "http://localhost:3000")])
        let get = try XCTUnwrap(imported.root.folders.first?.requests.first?.file)
        XCTAssertEqual(get.url, "{{baseUrl}}/users/:id?full=1")
        XCTAssertEqual(get.pathParams, [BruPair(key: "id", value: "42")])
        XCTAssertEqual(get.headers.map(\.enabled), [true, false])
        XCTAssertEqual(
            get.tests,
            "test(\"ok\", function () {\n  expect(res.getStatus()).to.equal(200);\n  bru.setEnvVar(\"name\", res.getBody().name);\n});")
        let login = try XCTUnwrap(imported.root.requests.first?.file)
        let open = try PostmanImporter.make(
            try XCTUnwrap(
                APIImport.parseDocument(
                    Data(
                        #"{"info": {"name": "X", "schema": "getpostman"}, "auth": {"type": "bearer", "bearer": [{"key": "token", "value": "t"}]}, "item": [{"name": "Public", "auth": {"type": "noauth"}, "item": [{"name": "Open", "request": {"method": "GET", "url": "http://x"}}]}]}"#
                            .utf8))))
        XCTAssertEqual(open.root.folders.first?.settings?.defaultAuthMode, BruFile.AuthMode.none, "noauth stops the collection's token")
        XCTAssertEqual(login.bodyMode, .formUrlEncoded)
        XCTAssertEqual(login.authMode, .none)
    }

    /// Imported into a checkout that has a collection, a Postman
    /// collection's own scripts and tests go to its folder, not away.
    func testAPostmanCollectionsScriptsSurviveImportAsAFolder() throws {
        let json = #"""
            {"info": {"name": "Scripted", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},
             "event": [{"listen": "prerequest", "script": {"exec": ["pm.variables.set(\"a\", 1);"]}},
                       {"listen": "test", "script": {"exec": ["pm.test(\"shared\", function () {});"]}}],
             "item": [{"name": "One", "request": {"method": "GET", "url": "http://x/1"}}]}
            """#
        let imported = try PostmanImporter.make(try XCTUnwrap(APIImport.parseDocument(Data(json.utf8))))
        let root = dir.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"{"version":"1","name":"Existing"}"#.write(to: root.appendingPathComponent("bruno.json"), atomically: true, encoding: .utf8)
        let folder = try imported.writeFolder(in: root)
        let settings = try XCTUnwrap(BrunoCollection.folderFile(folder))
        XCTAssertEqual(settings.preRequestScript, "bru.setVar(\"a\", 1);")
        XCTAssertEqual(settings.tests, "test(\"shared\", function () {});")
    }

    // MARK: .http

    func testAnHTTPFile() throws {
        let text = """
            @host = http://localhost:3000
            @token = abc

            # @name List
            GET {{host}}/items?page=1 HTTP/1.1
            Accept: application/json

            ###

            // Create one
            POST {{host}}/items
            Content-Type: application/json
            Authorization: Bearer {{token}}

            {
              "name": "x"
            }

            > {% client.global.set("id", response.body.id); %}
            """
        let imported = HTTPFileImporter.make(text, name: "requests")
        XCTAssertEqual(imported.root.requests.map(\.file.name), ["List", "POST /items"])
        XCTAssertEqual(imported.environments.first?.file.variables.map(\.key), ["host", "token"])
        let list = imported.root.requests[0].file
        XCTAssertEqual(list.url, "{{host}}/items?page=1")
        XCTAssertEqual(list.queryParams, [BruPair(key: "page", value: "1")])
        let create = imported.root.requests[1].file
        XCTAssertEqual(create.method, "POST")
        XCTAssertEqual(create.body(.json), "{\n  \"name\": \"x\"\n}")
        XCTAssertEqual(create.headers.count, 2)
        XCTAssertFalse(imported.notes.isEmpty, "the handler script is named as left behind")
    }

    /// Written on Windows, with its query on lines of its own.
    func testAnHTTPFileWithCRLFAndAQueryOverSeveralLines() {
        let text = "POST http://x/items\r\n    ?page=1\r\n    &size=10\r\nContent-Type: application/json\r\n\r\n{\"a\": 1}\r\n"
        let file = HTTPFileImporter.make(text, name: "win").root.requests[0].file
        XCTAssertEqual(file.url, "http://x/items?page=1&size=10")
        XCTAssertEqual(file.headers, [BruPair(key: "Content-Type", value: "application/json")])
        XCTAssertEqual(file.bodyMode, .json)
        XCTAssertEqual(file.body(.json), "{\"a\": 1}")
    }

    func testPostmansHeadersAddBecomesSetHeader() {
        XCTAssertEqual(
            PostmanImporter.translate("pm.request.headers.add({key: 'X-Test', value: 'yes'});"), "req.setHeader('X-Test', 'yes');")
        XCTAssertEqual(PostmanImporter.translate("pm.request.headers.add(header);"), "req.setHeader(header.key, header.value);")
    }

    // MARK: cURL

    func testCurlAsABrowserCopiesIt() throws {
        let file = try CurlParser.parse(
            """
            curl 'https://api.example.com/v1/users?page=2' \\
              -H 'accept: application/json' \\
              -H "Authorization: Bearer t0k" \\
              --data-raw '{"name":"Ada","tags":["a"]}' \\
              --compressed
            """)
        XCTAssertEqual(file.method, "POST")
        XCTAssertEqual(file.url, "https://api.example.com/v1/users?page=2")
        XCTAssertEqual(file.queryParams, [BruPair(key: "page", value: "2")])
        XCTAssertEqual(file.headers.map(\.key), ["accept", "Authorization"])
        XCTAssertEqual(file.bodyMode, .json)
        XCTAssertTrue(file.body(.json)?.contains("\"name\": \"Ada\"") == true)
        XCTAssertEqual(file.name, "POST users")
    }

    func testCurlFormsUsersAndMethods() throws {
        let form = try CurlParser.parse("curl -XPUT https://x.test/a -d 'a=1&b=two%20words' -u ada:secret")
        XCTAssertEqual(form.method, "PUT")
        XCTAssertEqual(form.bodyMode, .formUrlEncoded)
        XCTAssertEqual(form.formFields, [BruPair(key: "a", value: "1"), BruPair(key: "b", value: "two words")])
        XCTAssertEqual(form.authMode, .basic)
        XCTAssertEqual(form.value("password", in: "auth:basic"), "secret")
        let upload = try CurlParser.parse("curl https://x.test/up -F file=@./cat.png -F 'title=A cat'")
        XCTAssertEqual(upload.bodyMode, .multipartForm)
        XCTAssertEqual(upload.multipartFields, [BruPair(key: "file", value: "@file(./cat.png)"), BruPair(key: "title", value: "A cat")])
        let get = try CurlParser.parse("curl -G https://x.test/s --data-urlencode q=ok --url-query x")
        XCTAssertEqual(get.method, "GET")
        XCTAssertTrue(get.url.hasPrefix("https://x.test/s?q=ok"))
        XCTAssertThrowsError(try CurlParser.parse("wget https://x.test"))
        XCTAssertThrowsError(try CurlParser.parse("curl -H 'a: b'"))
    }

    /// --data-urlencode's value is unencoded: one field, its value whole.
    func testDataURLEncodeKeepsItsValueWhole() throws {
        let file = try CurlParser.parse("curl http://example.test --data-urlencode 'name=a+b&c' -d 'x=1'")
        XCTAssertEqual(file.formFields, [BruPair(key: "name", value: "a+b&c"), BruPair(key: "x", value: "1")])
    }

    func testTheShellWordsCurlCommandsUse() {
        XCTAssertEqual(CurlParser.tokenize(#"curl 'a b' "c \"d\"" $'e\nf' g\ h"#), ["curl", "a b", "c \"d\"", "e\nf", "g h"])
    }

    func testReadingAFileFindsItsFormat() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yaml = dir.appendingPathComponent("openapi.yaml")
        try Self.petstore.write(to: yaml, atomically: true, encoding: .utf8)
        XCTAssertEqual(try APIImport.read(yaml).name, "Pet Store")
        let http = dir.appendingPathComponent("api.http")
        try "GET http://x/a\n".write(to: http, atomically: true, encoding: .utf8)
        XCTAssertEqual(try APIImport.read(http).root.requests.count, 1)
        let other = dir.appendingPathComponent("package.json")
        try #"{"name": "x"}"#.write(to: other, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try APIImport.read(other))
    }
}
