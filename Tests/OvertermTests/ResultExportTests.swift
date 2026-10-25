import XCTest

@testable import Overterm

/// A result's rows as the formats people paste and save.
final class ResultExportTests: XCTestCase {
    private let columns = ["id", "note"]
    private let rows: [[String?]] = [["1", "a, \"b\""], ["2", nil], ["10", "it's"]]

    func testEachFormat() {
        XCTAssertEqual(ResultExport.text(.tsv, columns: columns, rows: rows), "id\tnote\n1\ta, \"b\"\n2\t\n10\tit's")
        XCTAssertEqual(ResultExport.text(.csv, columns: columns, rows: rows), "id,note\n1,\"a, \"\"b\"\"\"\n2,\n10,it's\n")
        XCTAssertEqual(
            ResultExport.text(.insert, columns: columns, rows: rows, table: "orders"),
            "INSERT INTO orders (id, note) VALUES (1, 'a, \"b\"');\nINSERT INTO orders (id, note) VALUES (2, NULL);\nINSERT INTO orders (id, note) VALUES (10, 'it''s');")
        XCTAssertEqual(ResultExport.text(.markdown, columns: columns, rows: [["1", "a|b"]]), "| id | note |\n| --- | --- |\n| 1 | a\\|b |")
        let json = ResultExport.text(.json, columns: columns, rows: [["1", nil]])
        XCTAssertTrue(json.contains("\"id\" : \"1\"") && json.contains("\"note\" : null"), json)
        XCTAssertEqual(
            ResultExport.text(.insert, columns: ["zip"], rows: [["01234"]], table: "t"), "INSERT INTO t (zip) VALUES ('01234');",
            "a leading zero is text")
    }

    func testSortingTakesNumbersAsNumbersAndNullsLast() {
        XCTAssertEqual(ResultExport.sorted(rows, by: 0, ascending: true).map { $0[0] }, ["1", "2", "10"])
        XCTAssertEqual(ResultExport.sorted(rows, by: 0, ascending: false).map { $0[0] }, ["10", "2", "1"])
        XCTAssertEqual(ResultExport.sorted(rows, by: 1, ascending: true).last?[1] as String??, .some(nil))
    }
}
