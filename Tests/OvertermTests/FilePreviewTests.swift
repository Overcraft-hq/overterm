import XCTest

@testable import Overterm

/// A stored file's preview, from its name and first bytes.
final class FilePreviewTests: XCTestCase {
    func testCSVWithQuotesNewlinesAndDoubledQuotes() {
        let csv = "id,note\n1,\"a, b\"\n2,\"say \"\"hi\"\"\"\n3,\"two\nlines\"\n"
        guard case .table(let result) = FilePreview.make(name: "x.csv", data: Data(csv.utf8), truncated: false) else { return XCTFail() }
        XCTAssertEqual(result.columns, ["id", "note"])
        XCTAssertEqual(result.rows, [["1", "a, b"], ["2", "say \"hi\""], ["3", "two\nlines"]])
        XCTAssertFalse(result.truncated)
    }

    func testACutFileDropsItsHalfLineAndSaysSo() {
        guard case .table(let result) = FilePreview.make(name: "x.tsv", data: Data("a\tb\n1\t2\n3\t4\n5\t".utf8), truncated: true) else {
            return XCTFail()
        }
        XCTAssertEqual(result.rows, [["1", "2"], ["3", "4"]])
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(FilePreview.delimited("a\n1\n2\n3\n", separator: ",", limit: 2).rows.count, 2)
        XCTAssertTrue(FilePreview.delimited("a\n1\n2\n3\n", separator: ",", limit: 2).truncated)
    }

    func testJSONLinesTakeEveryKeyAsAColumn() {
        guard case .table(let result) = FilePreview.make(name: "e.jsonl", data: Data("{\"a\":1}\n{\"b\":\"x\",\"a\":2}\n".utf8), truncated: false)
        else { return XCTFail() }
        XCTAssertEqual(result.columns, ["a", "b"])
        XCTAssertEqual(result.rows, [["1", nil], ["2", "x"]])
    }

    func testOtherKinds() {
        XCTAssertEqual(FilePreview.make(name: "a.json", data: Data("{\"b\":1,\"a\":[1]}".utf8), truncated: false), .text("{\n  \"a\" : [\n    1\n  ],\n  \"b\" : 1\n}", truncated: false))
        XCTAssertEqual(FilePreview.make(name: "photo.PNG", data: Data(), truncated: false), .image)
        XCTAssertEqual(FilePreview.make(name: "doc.pdf", data: Data(), truncated: false), .pdf)
        XCTAssertEqual(FilePreview.make(name: "blob.bin", data: Data([0, 1, 2]), truncated: false), .none)
        XCTAssertEqual(FilePreview.make(name: "notes.weird", data: Data("plain".utf8), truncated: false), .text("plain", truncated: false))
        XCTAssertEqual(FilePreview.contentType(of: "a.CSV"), "text/csv")
    }
}
