import XCTest

@testable import Overterm

/// YAML through tree-sitter's grammar, into JSONSerialization's shapes —
/// what an OpenAPI document in YAML needs.
final class YAMLReaderTests: XCTestCase {
    func testAnOpenAPIDocument() throws {
        let yaml = """
            openapi: 3.0.3
            info:
              title: "Pet Store"
              version: '1.0'
              description: |
                Line one
                Line two
            servers:
              - url: https://api.example.com/v1
            paths:
              /pets/{id}:
                get:
                  summary: Find a pet
                  tags: [pets, read]
                  parameters:
                    - name: id
                      in: path
                      required: true
                      schema: {type: integer, minimum: 1}
                  responses:
                    '200':
                      description: OK
            components:
              securitySchemes:
                bearer: {type: http, scheme: bearer}
            """
        let doc = try XCTUnwrap(YAMLReader.parse(yaml) as? [String: Any])
        XCTAssertEqual(doc["openapi"] as? String, "3.0.3", "a version string stays a string")
        let info = try XCTUnwrap(doc["info"] as? [String: Any])
        XCTAssertEqual(info["title"] as? String, "Pet Store")
        XCTAssertEqual(info["version"] as? String, "1.0")
        XCTAssertEqual(info["description"] as? String, "Line one\nLine two\n")
        XCTAssertEqual(((doc["servers"] as? [[String: Any]])?.first?["url"]) as? String, "https://api.example.com/v1")
        let get = try XCTUnwrap(((doc["paths"] as? [String: Any])?["/pets/{id}"] as? [String: Any])?["get"] as? [String: Any])
        XCTAssertEqual(get["tags"] as? [String], ["pets", "read"])
        let parameter = try XCTUnwrap((get["parameters"] as? [[String: Any]])?.first)
        XCTAssertEqual(parameter["required"] as? Bool, true)
        XCTAssertEqual((parameter["schema"] as? [String: Any])?["minimum"] as? Int, 1)
        XCTAssertNotNil((get["responses"] as? [String: Any])?["200"], "a quoted numeric key")
    }

    func testScalarsAnchorsAndFolding() throws {
        let yaml = """
            int: 42
            float: 1.5
            yes: true
            nothing: null
            tilde: ~
            quoted: "a\\tb \\u00e9"
            single: 'it''s'
            folded: >
              one
              two

              three
            stripped: |-
              keep
            base: &base
              a: 1
              b: 2
            derived:
              <<: *base
              b: 3
            list:
              - *base
              - plain words here
            """
        let doc = try XCTUnwrap(YAMLReader.parse(yaml) as? [String: Any])
        XCTAssertEqual(doc["int"] as? Int, 42)
        XCTAssertEqual(doc["float"] as? Double, 1.5)
        XCTAssertEqual(doc["yes"] as? Bool, true)
        XCTAssertTrue(doc["nothing"] is NSNull)
        XCTAssertTrue(doc["tilde"] is NSNull)
        XCTAssertEqual(doc["quoted"] as? String, "a\tb é")
        XCTAssertEqual(doc["single"] as? String, "it's")
        XCTAssertEqual(doc["folded"] as? String, "one two\nthree\n")
        XCTAssertEqual(doc["stripped"] as? String, "keep")
        XCTAssertEqual(doc["derived"] as? [String: Int], ["a": 1, "b": 3])
        XCTAssertEqual((doc["list"] as? [Any])?.first as? [String: Int], ["a": 1, "b": 2])
        XCTAssertEqual((doc["list"] as? [Any])?.last as? String, "plain words here")
    }

    func testBrokenYAMLIsNotGuessedAt() {
        XCTAssertNil(YAMLReader.parse("a: [1, 2\nb: }"))
    }
}
